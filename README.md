# Kong自定义插件开发

[kong3.9.0](https://github.com/Kong/kong/archive/refs/tags/3.9.0.zip)


```bash
unzip kong-3.9.0.zip
mv kong-3.9.0/kong kong
rm -rf kong-3.9.0*
```

## 自定义JWT验证插件

本项目包含两个自定义JWT验证插件：

1. **jwt-redis-validator**：通过Redis判断token是否有效
2. **jwt-http-validator**：通过HTTP调用后端服务判断token是否有效

这两个插件都基于Kong官方的JWT插件，但提供了不同的验证方式。

### 插件安装

1. 将插件目录复制到Kong的插件目录中
2. 在Kong配置文件中启用插件：

```
plugins = bundled,jwt-redis-validator,jwt-http-validator
```

3. 重启Kong服务

### Docker构建

本项目提供了Dockerfile和docker-compose.yml，可以快速构建和部署包含自定义插件的Kong容器：

```bash
# 构建并启动Kong容器
docker-compose up -d

# 查看容器状态
docker-compose ps

# 停止并删除容器
docker-compose down
```

### jwt-redis-validator 插件

通过Redis验证JWT令牌的有效性。

#### 配置参数

| 参数名 | 类型 | 默认值 | 描述 |
|--------|------|--------|------|
| uri_param_names | set of string | ["jwt"] | JWT令牌在查询参数中的名称列表 |
| cookie_names | set of string | [] | JWT令牌在Cookie中的名称列表 |
| header_names | set of string | ["authorization"] | JWT令牌在HTTP头中的名称列表 |
| key_claim_name | string | "iss" | JWT声明中包含密钥标识符的字段名称 |
| redis_host | string | 必填 | Redis服务器主机 |
| redis_port | number | 6379 | Redis服务器端口 |
| redis_password | string | 可选 | Redis服务器密码 |
| redis_database | number | 0 | Redis数据库索引 |
| redis_timeout | number | 2000 | Redis连接超时（毫秒） |
| token_key_prefix | string | "jwt_token:" | Redis中存储令牌的键前缀 |
| run_on_preflight | boolean | true | 是否在OPTIONS预检请求上运行插件 |
| anonymous | string | 可选 | 如果认证失败，可选的匿名消费者ID或用户名 |
| realm | string | 可选 | 认证失败时发送的WWW-Authenticate头中的realm属性值 |

#### 使用示例

```
curl -X POST http://localhost:8001/services/{service}/plugins \
  --data "name=jwt-redis-validator" \
  --data "config.redis_host=127.0.0.1" \
  --data "config.redis_port=6379" \
  --data "config.token_key_prefix=jwt_token:"
```

#### Redis中的令牌存储格式

在Redis中，令牌应该以以下格式存储：

```
{token_key_prefix}{token} = 1
```

例如，如果token_key_prefix为"jwt_token:"，JWT令牌为"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."，
则在Redis中应该存在以下键：

```
jwt_token:eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9... = 1
```

可以设置过期时间，以便令牌自动失效：

```
redis-cli> SET jwt_token:eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9... 1 EX 3600
```

### jwt-http-validator 插件

通过HTTP调用后端服务验证JWT令牌的有效性。

#### 配置参数

| 参数名 | 类型 | 默认值 | 描述 |
|--------|------|--------|------|
| uri_param_names | set of string | ["jwt"] | JWT令牌在查询参数中的名称列表 |
| cookie_names | set of string | [] | JWT令牌在Cookie中的名称列表 |
| header_names | set of string | ["authorization"] | JWT令牌在HTTP头中的名称列表 |
| key_claim_name | string | "iss" | JWT声明中包含密钥标识符的字段名称 |
| http_endpoint | string | 必填 | 验证JWT令牌的HTTP端点 |
| http_method | string | "POST" | HTTP请求方法（"GET"或"POST"） |
| timeout | number | 10000 | HTTP请求超时（毫秒） |
| keepalive | number | 60000 | HTTP连接保持活动时间（毫秒） |
| http_headers | map | {"Content-Type":"application/json"} | 要添加到HTTP请求的头部 |
| run_on_preflight | boolean | true | 是否在OPTIONS预检请求上运行插件 |
| anonymous | string | 可选 | 如果认证失败，可选的匿名消费者ID或用户名 |
| realm | string | 可选 | 认证失败时发送的WWW-Authenticate头中的realm属性值 |

#### 使用示例

```
curl -X POST http://localhost:8001/services/{service}/plugins \
  --data "name=jwt-http-validator" \
  --data "config.http_endpoint=http://auth-service/validate-token" \
  --data "config.http_method=POST" \
  --data "config.timeout=5000"
```

#### HTTP验证服务请求格式

当http_method为"POST"时，插件会向HTTP端点发送以下JSON格式：

```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "jwt": {
    "header": {
      "alg": "HS256",
      "typ": "JWT"
    },
    "claims": {
      "sub": "1234567890",
      "name": "John Doe",
      "iat": 1516239022
    },
    "signature": "...",
    "key_claim_name": "iss",
    "key_claim_value": "your-service"
  }
}
```

当http_method为"GET"时，插件会将令牌作为查询参数发送：

```
GET http://auth-service/validate-token?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

#### HTTP验证服务响应格式

HTTP验证服务应返回以下JSON格式：

```json
{
  "valid": true,  // 令牌是否有效
  "message": "可选的消息",
  "consumer": {   // 可选的消费者信息
    "id": "consumer-id",
    "username": "consumer-username",
    "custom_id": "custom-id"
  }
}
```

如果`valid`为`false`，则认证失败，并返回`message`中的错误信息。