local typedefs = require "kong.db.schema.typedefs"

return {
  name = "jwt-http-validator",
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
          { http_endpoint = {
              description = "验证JWT令牌的HTTP端点",
              type = "string",
              required = true,
          }, },
          { http_method = {
              description = "HTTP请求方法",
              type = "string",
              default = "POST",
              one_of = { "GET", "POST" },
          }, },
          { timeout = {
              description = "HTTP请求超时（毫秒）",
              type = "number",
              default = 10000,
          }, },
          { keepalive = {
              description = "HTTP连接保持活动时间（毫秒）",
              type = "number",
              default = 60000,
          }, },
          { http_headers = {
              description = "要添加到HTTP请求的头部",
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              default = {
                ["Content-Type"] = "application/json"
              },
          }, },
          { run_on_preflight = { 
              description = "是否在OPTIONS预检请求上运行插件", 
              type = "boolean", 
              required = true, 
              default = true 
          }, },
          { anonymous = { 
              description = "如果认证失败，可选的匿名消费者ID或用户名", 
              type = "string" 
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