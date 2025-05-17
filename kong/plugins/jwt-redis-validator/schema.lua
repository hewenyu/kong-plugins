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
          { redis_host = {
              description = "Redis服务器主机",
              type = "string",
              required = true,
          }, },
          { redis_port = {
              description = "Redis服务器端口",
              type = "number",
              default = 6379,
          }, },
          { redis_password = {
              description = "Redis服务器密码（可选）",
              type = "string",
              required = false,
          }, },
          { redis_database = {
              description = "Redis数据库索引",
              type = "number",
              default = 0,
          }, },
          { redis_timeout = {
              description = "Redis连接超时（毫秒）",
              type = "number",
              default = 2000,
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
        },
      },
    },
  },
} 