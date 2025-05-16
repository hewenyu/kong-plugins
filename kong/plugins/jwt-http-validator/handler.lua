local constants = require "kong.constants"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local kong_meta = require "kong.meta"
local http = require "resty.http"
local cjson = require "cjson.safe"

local fmt = string.format
local kong = kong
local type = type
local error = error
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local re_gmatch = ngx.re.gmatch

local JwtHttpValidatorHandler = {
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

-- 通过HTTP调用验证JWT令牌
local function validate_token_via_http(conf, token, jwt_data)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  local request_body
  local request_headers = conf.http_headers or {}
  local request_params

  if conf.http_method == "POST" then
    request_body = cjson.encode({
      token = token,
      jwt = jwt_data
    })
  else -- GET
    request_params = {
      token = token
    }
  end

  local res, err = httpc:request_uri(conf.http_endpoint, {
    method = conf.http_method,
    body = request_body,
    headers = request_headers,
    query = request_params,
    keepalive_timeout = conf.keepalive
  })

  if not res then
    kong.log.err("HTTP请求失败: ", err)
    return false, "HTTP请求失败: " .. tostring(err)
  end

  if res.status ~= 200 then
    kong.log.err("HTTP验证服务返回非200状态码: ", res.status)
    return false, "令牌验证失败，状态码: " .. tostring(res.status)
  end

  local body, err = cjson.decode(res.body)
  if not body then
    kong.log.err("无法解析HTTP响应: ", err)
    return false, "无法解析HTTP响应: " .. tostring(err)
  end

  if not body.valid then
    return false, body.message or "令牌验证失败"
  end

  return true, body
end

-- 设置消费者信息
local function set_consumer(consumer, credential, token)
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

  -- 通过HTTP调用验证令牌
  local jwt_data = {
    header = header,
    claims = claims,
    signature = jwt.signature,
    key_claim_name = conf.key_claim_name,
    key_claim_value = jwt_secret_key
  }

  local valid, result = validate_token_via_http(conf, token, jwt_data)
  if not valid then
    return false, unauthorized(result, www_authenticate_with_error)
  end

  -- 获取消费者信息，优先使用HTTP响应中的消费者信息
  local consumer
  if type(result) == "table" and result.consumer then
    consumer = result.consumer
  else
    -- 如果HTTP响应中没有消费者信息，则使用JWT中的信息
    local consumer_id = claims.sub or jwt_secret_key
    consumer = {
      id = consumer_id,
      username = claims.name or consumer_id,
      custom_id = claims.custom_id
    }
  end

  -- 如果无法找到消费者
  if not consumer then
    return false, {
      status = 401,
      message = fmt("找不到与 '%s=%s' 相关的消费者", conf.key_claim_name, jwt_secret_key)
    }
  end

  local credential = {
    key = jwt_secret_key
  }

  set_consumer(consumer, credential, token)

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

  set_consumer(consumer)
end

-- 当conf.anonymous启用时，我们处于"逻辑OR"认证流程中
local function logical_OR_authentication(conf)
  if kong.client.get_credential() then
    -- 我们已经通过认证，并且在认证方法之间处于"逻辑OR"关系 -- 提前退出
    return
  end

  local ok, _ = do_authentication(conf)
  if not ok then
    set_anonymous_consumer(conf.anonymous)
  end
end

-- 当conf.anonymous未设置时，我们处于"逻辑AND"认证流程中
local function logical_AND_authentication(conf)
  local ok, err = do_authentication(conf)
  if not ok then
    return kong.response.exit(err.status, err.errors or { message = err.message }, err.headers)
  end
end

function JwtHttpValidatorHandler:access(conf)
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

return JwtHttpValidatorHandler 