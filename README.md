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

先以 [deploy/config.example.yaml](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/config.example.yaml) 为基础生成一份本地 `config.heroku.yaml`，填好 PostgreSQL、管理员账户、上游账号等业务配置。

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

- [Dockerfile.heroku](https://github.com/colloq168/Sub2api_Heroku/blob/main/Dockerfile.heroku)：Heroku 容器镜像构建文件
- [deploy/heroku-deploy-from-config.sh](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/heroku-deploy-from-config.sh)：正式发布脚本
- [deploy/docker-entrypoint.sh](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/docker-entrypoint.sh)：容器启动时恢复 `config.yaml`、`.installed`、`redis.conf`
- [deploy/config.example.yaml](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/config.example.yaml)：Heroku 运行时配置样例
- [deploy/README.md](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/README.md)：Heroku 部署补充说明

### 6. Heroku PORT 问题修复涉及文件

以下清单不包含 `backend/` 下把 `github.com/Wei-Shaw/sub2api` 统一替换为 `github.com/colloq168/Sub2api_Heroku` 的 import 路径迁移；这里只列解决 Heroku 端口与运行时配置边界问题时修改过的核心文件：

- [backend/internal/config/config.go](https://github.com/colloq168/Sub2api_Heroku/blob/main/backend/internal/config/config.go#L1205)
  - 在加载配置前执行 `applyHerokuEnvCompatibility()`
  - 发现 Heroku `PORT` 时，先同步到 `SERVER_PORT`
  - 监听地址解析时把 `PORT` 的优先级放在 `SERVER_PORT` 之前，避免继续固定监听 `8080`

- [backend/internal/config/config_test.go](https://github.com/colloq168/Sub2api_Heroku/blob/main/backend/internal/config/config_test.go#L769)
  - 新增 Heroku 回归测试：
  - `TestLoadForBootstrapUsesHerokuPortEnv`
  - `TestLoadForBootstrapHerokuPortOverridesPresetServerPort`
  - `TestLoadForBootstrapUsesBindHostEnvCompatibility`

- [deploy/heroku-deploy-from-config.sh](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/heroku-deploy-from-config.sh#L4)
  - 删除了把 `SERVER_PORT` 当 build-time 参数处理的旧思路
  - 发布前自动清理 Heroku 上残留的 `SERVER_PORT`
  - 如存在遗留 `BIND_HOST`，迁移到 `SERVER_HOST` 后再自动清理
  - 统一走无缓存构建、发布、健康检查链路，避免继续依赖手工热修

- [Dockerfile.heroku](https://github.com/colloq168/Sub2api_Heroku/blob/main/Dockerfile.heroku#L118)
  - 移除了运行时业务配置在镜像构建阶段的烘焙逻辑
  - 只保留容器默认值，把实际监听端口交给 Heroku 运行时 `PORT`
  - `HEALTHCHECK` 改为使用 `http://localhost:${PORT:-8080}/health`

- [deploy/docker-entrypoint.sh](https://github.com/colloq168/Sub2api_Heroku/blob/main/deploy/docker-entrypoint.sh#L1)
  - 虽然不直接决定监听端口，但它是 Heroku 运行时链路的一部分
  - 容器启动时从 Config Vars 恢复 `config.yaml`、`.installed`、`redis.conf`
  - 这样可以保证端口适配修复后的容器仍按 Heroku 运行时配置启动，而不是依赖容器内手工残留文件

## 许可证

本项目基于 [GNU 宽通用公共许可证 v3.0](LICENSE)（或更高版本）授权。
