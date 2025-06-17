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

local cached_redis_config

--- 从请求中获取JWT令牌
-- 检查URI参数、Cookie和配置的header_names中的JWT
-- @param conf 插件配置
-- @return token JWT令牌（可能是表）或nil
-- @return err 错误信息
local function retrieve_tokens(conf)
  local token_set = {}
  local args = kong.request.get_query()
  for _, v in ipairs(conf.uri_param_names or {}) do
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
  for _, v in ipairs(conf.cookie_names or {}) do
    local cookie = var["cookie_" .. v]
    if cookie and cookie ~= "" then
      token_set[cookie] = true
    end
  end

  local request_headers = kong.request.get_headers()
  for _, v in ipairs(conf.header_names or {}) do
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

-- 获取Kong配置中的Redis设置
local function get_redis_config()
  if cached_redis_config then
    return cached_redis_config
  end

  local config = kong.configuration
  
  -- 检查Kong配置中是否有jwt-redis_前缀的Redis配置
  if not config["jwt-redis_host"] then
    kong.log.err("Kong配置中缺少Redis配置，请设置 jwt-redis_host 配置")
    return nil, "Kong配置中缺少Redis配置"
  end
  
  -- 使用jwt-redis_前缀的配置
  cached_redis_config = {
    host = config["jwt-redis_host"] or "127.0.0.1",
    port = tonumber(config["jwt-redis_port"] or 6379),
    password = config["jwt-redis_password"],
    database = tonumber(config["jwt-redis_database"] or 0),
    timeout = tonumber(config["jwt-redis_timeout"] or 2000)
  }
  return cached_redis_config
end

-- 连接到Redis
local function connect_to_redis()
  local red = redis:new()
  
  -- 获取Redis配置
  local redis_config, err = get_redis_config()
  if not redis_config then
    return nil, err
  end
  
  red:set_timeout(redis_config.timeout)
  
  local ok, err = red:connect(redis_config.host, redis_config.port)
  if not ok then
    kong.log.err("无法连接到Redis: ", err)
    return nil, err
  end
  
  -- 如果提供了密码，则进行认证
  if redis_config.password and redis_config.password ~= "" then
    local ok, err = red:auth(redis_config.password)
    if not ok then
      kong.log.err("Redis认证失败: ", err)
      return nil, err
    end
  end
  
  -- 选择数据库
  if redis_config.database > 0 then
    local ok, err = red:select(redis_config.database)
    if not ok then
      kong.log.err("无法选择Redis数据库: ", err)
      return nil, err
    end
  end
  
  return red
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

  -- 解码令牌以验证其格式
  local jwt, err = jwt_decoder:new(token)
  if err then
    return false, unauthorized("无效令牌: " .. tostring(err), www_authenticate_with_error)
  end

  local claims = jwt.claims
  local header = jwt.header

  -- 基础格式验证，检查key_claim_name字段
  local claim_value = claims[conf.key_claim_name] or header[conf.key_claim_name]
  if not claim_value then
    return false, unauthorized("声明中没有必需的 '" .. conf.key_claim_name .. "' 字段", www_authenticate_with_error)
  elseif claim_value == "" then
    return false, unauthorized("声明中 '" .. conf.key_claim_name .. "' 字段无效", www_authenticate_with_error)
  end

  -- 连接到Redis
  local red, err = connect_to_redis()
  if not red then
    return false, unauthorized("无法验证令牌: Redis连接失败", www_authenticate_with_error)
  end

  -- 在Redis中检查令牌是否有效
  local token_key = conf.token_key_prefix .. claim_value
  local redis_token, err = red:get(token_key)

  -- 无论成功与否，都尝试将连接放回连接池
  local ok, keepalive_err = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("无法将Redis连接放回连接池: ", keepalive_err)
  end

  -- 现在处理 get 命令的结果
  if err then
    kong.log.err("Redis查询错误: ", err)
    return false, unauthorized("无法验证令牌: Redis查询失败", www_authenticate_with_error)
  end

  -- 如果令牌在Redis中不存在，或者与请求的令牌不匹配，则认为无效
  if not redis_token or redis_token ~= token then
    return false, unauthorized("令牌已失效或不存在", www_authenticate_with_error)
  end

  -- 设置一些有用的头部
  local set_header = kong.service.request.set_header
  set_header("X-JWT-Claim-Sub", claims.sub or "")
  if claims.name then
    set_header("X-JWT-Claim-Name", claims.name)
  end
  
  -- 存储已验证的令牌以供后续使用
  kong.ctx.shared.authenticated_jwt_token = token
  
  return true
end

function JwtRedisValidatorHandler:access(conf)
  -- 检查是否为预检请求以及是否应该进行认证
  if not conf.run_on_preflight and kong.request.get_method() == "OPTIONS" then
    return
  end

  local ok, err = do_authentication(conf)
  if not ok then
    return kong.response.exit(err.status, err.errors or { message = err.message }, err.headers)
  end
end

return JwtRedisValidatorHandler 