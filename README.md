# Sub2API

Sub2API 是一个 AI API 网关平台。本仓库的 README 仅保留已经验证过的 Heroku 容器部署主线，避免再混入口径不一致的部署说明。

## Heroku 部署

### 前置条件

- 已安装并登录 Heroku CLI
- 已安装 Podman
- 已安装 curl
- 已创建 Heroku 应用，并切换为 Container stack

```bash
heroku login
heroku create <APP_NAME>
heroku stack:set container -a <APP_NAME>
```

### 1. 准备运行时配置

先以 [deploy/config.example.yaml](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/deploy/config.example.yaml) 为基础生成一份本地 `config.heroku.yaml`，填好 PostgreSQL、管理员账户、上游账号等业务配置。

Heroku 文件系统是临时的，`config.yaml` 不能依赖手工写入容器。运行时配置需要通过 Config Vars 注入：

```bash
heroku config:set SUB2API_CONFIG_YAML_B64="$(base64 < config.heroku.yaml | tr -d '\n')" -a <APP_NAME>
heroku config:set SUB2API_INSTALLED=true -a <APP_NAME>
heroku config:set SERVER_HOST=0.0.0.0 -a <APP_NAME>
heroku config:set SKIP_BUILTIN_POSTGRES=true -a <APP_NAME>

# 当前已验证链路：Heroku dyno 内置 Redis
heroku config:set SKIP_BUILTIN_REDIS=false -a <APP_NAME>
heroku config:set SUB2API_REDIS_CONF_B64="$(base64 < deploy/redis.conf | tr -d '\n')" -a <APP_NAME>

# 建议的 Go 运行时限制
heroku config:set GOGC=50 -a <APP_NAME>
heroku config:set GOMEMLIMIT=300MiB -a <APP_NAME>

# 如需简易模式，可额外开启
heroku config:set RUN_MODE=simple -a <APP_NAME>
```

### 2. 端口规则

- Heroku 会在运行时自动注入 `PORT`。
- 不要手工设置 `SERVER_PORT`。
- 不需要再为 Heroku 单独设置 `BIND_HOST`；如残留旧值，发布脚本会迁移到 `SERVER_HOST` 并自动清理 `BIND_HOST`。
- `config.heroku.yaml` 里的 `server.port: 8080` 只作为容器默认值，运行时会被 Heroku 的 `PORT` 覆盖。

### 3. 发布

在项目根目录执行：

```bash
bash deploy/heroku-deploy-from-config.sh <APP_NAME>
```

该脚本会自动完成：

1. 校验 Heroku 应用存在
2. 清理遗留 `SERVER_PORT`
3. 校验关键运行时 Config Vars
4. 使用 `Dockerfile.heroku` 做无缓存构建
5. 在容器内执行 `/app/sub2api --version`
6. 推送到 `registry.heroku.com/<APP_NAME>/web`
7. 执行 `heroku container:release`
8. 轮询 `/health`，直到返回 `200 OK`

### 4. 发布后检查

```bash
heroku ps -a <APP_NAME>
heroku logs --tail -a <APP_NAME>

WEB_URL="$(heroku info -s -a <APP_NAME> | awk -F= '$1==\"web_url\"{print $2}')"
curl -i "${WEB_URL%/}/health"
```

### 5. 关键文件

- [Dockerfile.heroku](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/Dockerfile.heroku)：Heroku 容器镜像构建文件
- [deploy/heroku-deploy-from-config.sh](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/deploy/heroku-deploy-from-config.sh)：正式发布脚本
- [deploy/docker-entrypoint.sh](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/deploy/docker-entrypoint.sh)：容器启动时恢复 `config.yaml`、`.installed`、`redis.conf`
- [deploy/config.example.yaml](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/deploy/config.example.yaml)：Heroku 运行时配置样例
- [deploy/README.md](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/deploy/README.md)：Heroku 部署补充说明

## 许可证

本项目基于 [GNU 宽通用公共许可证 v3.0](LICENSE)（或更高版本）授权。
