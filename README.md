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

### 插件配置

`jwt-redis-validator` 插件通过连接到一个外部配置服务来获取其所需的 Redis 连接信息。这种方法实现了配置的集中管理和动态更新。

#### 启用插件和配置服务

在您的 `docker-compose.yml` 或其他部署环境中，为Kong设置以下环境变量来启用插件并指定配置源：

```yaml
KONG_PLUGINS: bundled,jwt-redis-validator
KONG_PLUGINS_JWT-REDIS-VALIDATOR_CONFIG_SERVICE_URL: http://kong-plugins-configs:8080/config
```

*   `KONG_PLUGINS_JWT-REDIS-VALIDATOR_CONFIG_SERVICE_URL` **（必需）**: 指向您的配置服务。项目中提供了一个示例服务 `kong-plugins-configs`，其用法可参考 `devops/docker-compose.yml`。

#### 配置服务规范

配置服务必须提供一个GET接口（例如 `/config`），该接口返回一个包含以下键的JSON对象：

```json
{
  "KONG_JWT_REDIS_HOST": "your-redis-host",
  "KONG_JWT_REDIS_PORT": 6379,
  "KONG_JWT_REDIS_PASSWORD": "your-redis-password",
  "KONG_JWT_REDIS_DATABASE": 0,
  "KONG_JWT_REDIS_TIMEOUT": 2000
}
```
该JSON对象中的所有字段都是必需的，插件将使用这些值来连接到Redis。

### jwt-redis-validator 插件

通过Redis验证JWT令牌的有效性，不需要consumer，只依赖Redis验证结果。

#### 配置参数

| 参数名 | 类型 | 默认值 | 描述 |
|--------|------|--------|------|
| uri_param_names | set of string | ["jwt"] | JWT令牌在查询参数中的名称列表 |
| cookie_names | set of string | [] | JWT令牌在Cookie中的名称列表 |
| header_names | set of string | ["authorization"] | JWT令牌在HTTP头中的名称列表 |
| key_claim_name | string | "iss" | JWT声明中用于构造Redis键的字段名称，例如`user_id` |
| token_key_prefix | string | "jwt_token:" | Redis中存储令牌的键前缀 |
| run_on_preflight | boolean | true | 是否在OPTIONS预检请求上运行插件 |
| realm | string | 可选 | 认证失败时发送的WWW-Authenticate头中的realm属性值 |
| config_service_url | string | **必填** | 第三方配置服务的URL，用于动态获取Redis配置。 |

#### 使用示例

启用此插件时，无需通过Admin API传递Redis配置，因为所有配置都来自配置服务。您只需启用插件即可：
```
curl -X POST http://localhost:8001/services/{service}/plugins \
  --data "name=jwt-redis-validator" \
  --data "config.key_claim_name=user_id" \
  --data "config.token_key_prefix=jwt_token:"
```

#### Redis中的令牌存储格式

在Redis中，令牌应该以 `key -> value` 的形式存储，其中 `key` 由前缀和JWT声明中的值组成，`value` 是完整的JWT字符串。

**格式**:
```
{token_key_prefix}{claim_value} = {jwt_string}
```

例如，如果 `token_key_prefix` 为 `"jwt_token:"`，插件配置的 `key_claim_name` 为 `"user_id"`，并且请求中的JWT解码后得到的 `user_id` 为 `"f2fa5fe4-7634-4bdd-bad0-9d314cb7c26d"`，则插件会在Redis中查找以下键：

```
jwt_token:f2fa5fe4-7634-4bdd-bad0-9d314cb7c26d
```

Redis应返回与请求中完全相同的JWT字符串作为值。可以为这个键设置过期时间，以便令牌自动失效：

```
redis-cli> SET "jwt_token:f2fa5fe4-7634-4bdd-bad0-9d314cb7c26d" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." EX 3600
```

#### 处理逻辑

1. 从请求中提取JWT令牌（查询参数、Cookie或HTTP头）。
2. 解码JWT令牌，并根据 `key_claim_name` 配置提取对应声明的值（例如 `user_id` 的值）。
3. 从插件配置的 `config_service_url` 获取Redis连接信息。
4. 连接到Redis。
5. 使用 `token_key_prefix` 和提取的声明值构造Redis键。
6. 从Redis中获取该键对应的值（即期望的JWT）。
7. 比较从Redis获取的JWT与请求中的JWT是否完全一致。
8. 如果Redis连接失败、键不存在或JWT不匹配，直接返回401未授权错误。
9. 如果令牌有效，设置`X-JWT-Claim-*`头部，以便后续服务使用。

#### 特点说明

*   对JWT令牌进行基础格式验证，并根据指定声明（claim）从Redis中检索验证。
*   不需要consumer关联，适用于微服务架构。
*   在Redis处理失败、令牌不存在或不匹配时直接返回未授权，保证安全性。
*   通过外部服务动态配置Redis，实现配置和代码分离。

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