默认配置

cat kong.conf.example | grep -v "#" | grep -v "^$"  >> kong.conf


cp .env-example .env