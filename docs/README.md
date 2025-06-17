# kong-plugins-configs
一个简易的服务处理组建，支持 Kong 插件从这个服务里读取以 `KONG_` 为前缀的环境变量作为配置。

## 功能

*   通过 HTTP GET 请求 `/config` 接口获取配置。
*   只返回以 `KONG_` (不区分大小写) 为前缀的环境变量。
*   服务监听的端口可以通过 `PORT` 环境变量配置，默认为 `8080`。

## 运行

### 本地运行 (使用 Go)

1.  确保你已经安装了 Go (版本 1.24+ 推荐)。
2.  克隆或下载本项目。
3.  进入项目根目录。
4.  下载依赖:
    ```bash
    go mod download
    ```
5.  运行服务:
    ```bash
    # 默认运行在 8080 端口
    go run main.go

    # 指定端口和 KONG_ 配置
    PORT=9090 KONG_MY_PLUGIN_SETTING="hello" go run main.go
    ```
6.  访问配置接口:
    ```bash
    curl http://localhost:8080/config
    # 或者，如果指定了端口
    curl http://localhost:9090/config
    ```

### 使用 Docker 运行

项目包含一个 `Dockerfile` 用于构建和运行服务。

1.  **构建 Docker 镜像:**
    在项目根目录下执行:
    ```bash
    docker pull hewenyulucky/kong-configs
    ```

2.  **运行 Docker 容器:**
    ```bash
    # 运行在 8080 端口，并设置一个 KONG_ 环境变量
    docker run -p 8080:8080 -e KONG_MY_PLUGIN_SETTING="docker_value" hewenyulucky/kong-configs:latest

    # 运行在 9090 端口
    docker run -p 9090:9090 -e PORT=9090 -e KONG_ANOTHER_SETTING="another_docker_value" kong-plugins-configs:latest
    ```
    容器内的服务会读取传递给 `docker run -e` 的以 `KONG_` 开头的环境变量。

## 配置

服务通过环境变量进行配置：

*   `PORT`: 服务监听的 HTTP 端口。默认为 `8080`。
*   `KONG_*`: 任何以 `KONG_` (不区分大小写) 为前缀的环境变量都将通过 `/config` 接口暴露。例如，`KONG_TIMEOUT=500` 将在配置中显示为 `{"KONG_TIMEOUT": "500"}`。
