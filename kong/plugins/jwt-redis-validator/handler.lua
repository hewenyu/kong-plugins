local constants = require "kong.constants"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local kong_meta = require "kong.meta"
local redis = require "resty.redis"

local fmt = string.format
local kong = kong
local type = type
local error = error
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local re_gmatch = ngx.re.gmatch

local JwtRedisValidatorHandler = {
  VERSION = kong_meta.version,
  PRIORITY = 1450, -- 与官方JWT插件相同的优先级
}

--- 从请求中获取JWT令牌
-- 检查URI参数、Cookie和配置的header_names中的JWT
-- @param conf 插件配置
-- @return token JWT令牌（可能是表）或nil
-- @return err 错误信息
local function retrieve_tokens(conf)
  local token_set = {}
  local args = kong.request.get_query()
  for _, v in ipairs(conf.uri_param_names) do
    local token = args[v] -- 可能是表
    if token then
      if type(token) == "table" then
        for _, t in ipairs(token) do
          if t ~= "" then
            token_set[t] = true
          end
        end
      elseif token ~= "" then
        token_set[token] = true
      end
    end
  end

  local var = ngx.var
  for _, v in ipairs(conf.cookie_names) do
    local cookie = var["cookie_" .. v]
    if cookie and cookie ~= "" then
      token_set[cookie] = true
    end
  end

  local request_headers = kong.request.get_headers()
  for _, v in ipairs(conf.header_names) do
    local token_header = request_headers[v]
    if token_header then
      if type(token_header) == "table" then
        token_header = token_header[1]
      end
      local iterator, iter_err = re_gmatch(token_header, "\\s*[Bb]earer\\s+(.+)", "jo")
      if not iterator then
        kong.log.err(iter_err)
        break
      end

      local m, err = iterator()
      if err then
        kong.log.err(err)
        break
      end

      if m and #m > 0 then
        if m[1] ~= "" then
          token_set[m[1]] = true
        end
      end
    end
  end

  local tokens_n = 0
  local tokens = {}
  for token, _ in pairs(token_set) do
    tokens_n = tokens_n + 1
    tokens[tokens_n] = token
  end

  if tokens_n == 0 then
    return nil
  end

  if tokens_n == 1 then
    return tokens[1]
  end

  return tokens
end

-- 连接到Redis
local function connect_to_redis(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)
  
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    kong.log.err("无法连接到Redis: ", err)
    return nil, err
  end
  
  -- 如果提供了密码，则进行认证
  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if not ok then
      kong.log.err("Redis认证失败: ", err)
      return nil, err
    end
  end
  
  -- 选择数据库
  if conf.redis_database > 0 then
    local ok, err = red:select(conf.redis_database)
    if not ok then
      kong.log.err("无法选择Redis数据库: ", err)
      return nil, err
    end
  end
  
  return red
end

-- 设置消费者信息
local function set_consumer(consumer, credential, token)
  -- 确保 consumer 和 credential 都不为 nil
  if not consumer or not credential then
    kong.log.err("Either consumer or credential is nil. Consumer: ", consumer, ", Credential: ", credential)
    return nil, "either credential or consumer must be provided"
  end
  
  kong.client.authenticate(consumer, credential)

  local set_header = kong.service.request.set_header
  local clear_header = kong.service.request.clear_header

  if consumer and consumer.id then
    set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
  else
    clear_header(constants.HEADERS.CONSUMER_ID)
  end

  if consumer and consumer.custom_id then
    set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
  else
    clear_header(constants.HEADERS.CONSUMER_CUSTOM_ID)
  end

  if consumer and consumer.username then
    set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
  else
    clear_header(constants.HEADERS.CONSUMER_USERNAME)
  end

  if credential and credential.key then
    set_header(constants.HEADERS.CREDENTIAL_IDENTIFIER, credential.key)
  else
    clear_header(constants.HEADERS.CREDENTIAL_IDENTIFIER)
  end

  if credential then
    clear_header(constants.HEADERS.ANONYMOUS)
  else
    set_header(constants.HEADERS.ANONYMOUS, true)
  end

  kong.ctx.shared.authenticated_jwt_token = token
  return true
end

local function unauthorized(message, www_auth_content, errors)
  return { status = 401, message = message, headers = { ["WWW-Authenticate"] = www_auth_content }, errors = errors }
end

local function do_authentication(conf)
  local token, err = retrieve_tokens(conf)
  if err then
    return error(err)
  end

  local www_authenticate_base = conf.realm and fmt('Bearer realm="%s"', conf.realm) or 'Bearer'
  local www_authenticate_with_error = www_authenticate_base .. ' error="invalid_token"'
  local token_type = type(token)
  if token_type ~= "string" then
    if token_type == "nil" then
      return false, unauthorized("未授权", www_authenticate_base)
    elseif token_type == "table" then
      return false, unauthorized("提供了多个令牌", www_authenticate_with_error)
    else
      return false, unauthorized("无法识别的令牌", www_authenticate_with_error)
    end
  end

  -- 解码令牌以获取消费者信息
  local jwt, err = jwt_decoder:new(token)
  if err then
    return false, unauthorized("无效令牌: " .. tostring(err), www_authenticate_with_error)
  end

  local claims = jwt.claims
  local header = jwt.header

  local jwt_secret_key = claims[conf.key_claim_name] or header[conf.key_claim_name]
  if not jwt_secret_key then
    return false, unauthorized("声明中没有必需的 '" .. conf.key_claim_name .. "' 字段", www_authenticate_with_error)
  elseif jwt_secret_key == "" then
    return false, unauthorized("声明中 '" .. conf.key_claim_name .. "' 字段无效", www_authenticate_with_error)
  end

  -- 连接到Redis
  local red, err = connect_to_redis(conf)
  if not red then
    return false, unauthorized("无法验证令牌: " .. tostring(err), www_authenticate_with_error)
  end

  -- 在Redis中检查令牌是否有效
  local token_key = conf.token_key_prefix .. token
  local exists, err = red:exists(token_key)
  if err then
    kong.log.err("Redis查询错误: ", err)
    return false, unauthorized("无法验证令牌: " .. tostring(err), www_authenticate_with_error)
  end

  -- 将连接放回连接池
  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("无法将Redis连接放回连接池: ", err)
  end

  -- 如果令牌在Redis中不存在，则认为无效
  if exists == 0 then
    return false, unauthorized("令牌已失效或不存在", www_authenticate_with_error)
  end

  -- 获取消费者信息
  local consumer_cache_key = "redis_jwt_consumer:" .. jwt_secret_key
  local consumer, err = kong.cache:get(consumer_cache_key, nil, function()
    -- 这里可以实现从数据库获取消费者信息的逻辑
    -- 简化起见，我们直接使用JWT中的信息
    local consumer_id = claims.sub or jwt_secret_key
    return {
      id = consumer_id,
      username = claims.name or consumer_id,
      custom_id = claims.custom_id
    }
  end)

  if err then
    return error(err)
  end

  -- 如果无法找到消费者
  if not consumer then
    return false, {
      status = 401,
      message = fmt("找不到与 '%s=%s' 相关的消费者", conf.key_claim_name, jwt_secret_key)
    }
  end

  -- 确保credential包含必要的信息
  local credential = {
    key = jwt_secret_key,
    id = jwt_secret_key -- 添加id字段，确保credential有效
  }

  -- 设置消费者并检查错误
  local ok, err = set_consumer(consumer, credential, token)
  if not ok then
    return false, unauthorized("认证失败: " .. tostring(err), www_authenticate_with_error)
  end

  return true
end

local function set_anonymous_consumer(anonymous)
  local consumer_cache_key = kong.db.consumers:cache_key(anonymous)
  local consumer, err = kong.cache:get(consumer_cache_key, nil,
                                        kong.client.load_consumer,
                                        anonymous, true)
  if err then
    return error(err)
  end

  if not consumer then
    kong.log.err("未找到匿名消费者: ", anonymous)
    return nil, "未找到匿名消费者"
  end

  -- 为匿名消费者创建一个空的credential
  local credential = {
    id = "anonymous",
    key = "anonymous"
  }

  local ok, err = set_consumer(consumer, credential, nil)
  if not ok then
    kong.log.err("设置匿名消费者失败: ", err)
    return nil, err
  end
  
  return true
end

-- 当conf.anonymous启用时，我们处于"逻辑OR"认证流程中
local function logical_OR_authentication(conf)
  if kong.client.get_credential() then
    -- 我们已经通过认证，并且在认证方法之间处于"逻辑OR"关系 -- 提前退出
    return
  end

  local ok, _ = do_authentication(conf)
  if not ok then
    local ok, err = set_anonymous_consumer(conf.anonymous)
    if not ok then
      kong.log.err("无法设置匿名消费者: ", err)
      return kong.response.exit(401, { message = "未授权" })
    end
  end
end

-- 当conf.anonymous未设置时，我们处于"逻辑AND"认证流程中
local function logical_AND_authentication(conf)
  local ok, err = do_authentication(conf)
  if not ok then
    return kong.response.exit(err.status, err.errors or { message = err.message }, err.headers)
  end
end

function JwtRedisValidatorHandler:access(conf)
  -- 检查是否为预检请求以及是否应该进行认证
  if not conf.run_on_preflight and kong.request.get_method() == "OPTIONS" then
    return
  end

  if conf.anonymous then
    return logical_OR_authentication(conf)
  else
    return logical_AND_authentication(conf)
  end
end

return JwtRedisValidatorHandler 