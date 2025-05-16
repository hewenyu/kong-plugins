FROM kong:3.9.0-ubuntu

# 复制自定义插件到Kong的Lua模块目录
COPY kong/plugins/jwt-redis-validator /usr/local/share/lua/5.1/kong/plugins/jwt-redis-validator/
COPY kong/plugins/jwt-http-validator /usr/local/share/lua/5.1/kong/plugins/jwt-http-validator/

# 复制修改后的constants.lua文件
COPY kong/constants.lua /usr/local/share/lua/5.1/kong/constants.lua