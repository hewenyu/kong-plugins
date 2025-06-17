local typedefs = require "kong.db.schema.typedefs"

return {
  name = "jwt-redis-validator",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { uri_param_names = {
              description = "JWT令牌在查询参数中的名称列表",
              type = "set",
              elements = { type = "string" },
              default = { "jwt" },
          }, },
          { cookie_names = {
              description = "JWT令牌在Cookie中的名称列表",
              type = "set",
              elements = { type = "string" },
              default = {}
          }, },
          { header_names = {
              description = "JWT令牌在HTTP头中的名称列表",
              type = "set",
              elements = { type = "string" },
              default = { "authorization" },
          }, },
          { key_claim_name = { 
              description = "JWT声明中包含密钥标识符的字段名称",
              type = "string", 
              default = "iss" 
          }, },
          { token_key_prefix = {
              description = "Redis中存储令牌的键前缀",
              type = "string",
              default = "jwt_token:",
          }, },
          { run_on_preflight = { 
              description = "是否在OPTIONS预检请求上运行插件", 
              type = "boolean", 
              required = true, 
              default = true 
          }, },
          { realm = { 
              description = "认证失败时发送的WWW-Authenticate头中的realm属性值", 
              type = "string", 
              required = false 
          }, },
          { config_service_url = {
              description = "第三方配置服务的URL",
              type = "string",
              required = true
          }, },
        },
      },
    },
  },
} 