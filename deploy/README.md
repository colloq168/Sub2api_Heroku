# Heroku 部署补充说明

本目录现在只服务于 Heroku 容器部署，避免和实际可用链路混用。

## 文件说明

- `heroku-deploy-from-config.sh`：正式发布脚本，负责构建、推送、发布和健康检查
- `docker-entrypoint.sh`：容器入口，负责从 Heroku Config Vars 恢复 `config.yaml`、`.installed`、`redis.conf`
- `config.example.yaml`：Heroku 运行时 `config.yaml` 样例
- `redis.conf`：内置 Redis 配置样例

根目录中的 [Dockerfile.heroku](/Users/mer/go/src/project/Git/sub2api-deploy/sub2api/Dockerfile.heroku) 是这条链路的唯一镜像构建入口。

## 当前已验证的 Heroku 运行模式

当前已经实际验证通过的链路是：

- Web dyno 使用 `Dockerfile.heroku`
- PostgreSQL 使用外部实例
- Redis 使用 dyno 内置 Redis
- `config.yaml` 通过 `SUB2API_CONFIG_YAML_B64` 注入
- 应用监听端口由 Heroku 运行时 `PORT` 决定

如需切到外部 Redis，可以自行调整，但那已经不属于当前已验证主线。

## 必要 Config Vars

| 变量 | 必需 | 说明 |
|------|------|------|
| `SUB2API_CONFIG_YAML_B64` | 是 | base64 编码后的 `config.yaml` |
| `SUB2API_INSTALLED` | 是 | 设为 `true`，启动时写入 `.installed` |
| `SERVER_HOST` | 是 | 固定为 `0.0.0.0` |
| `SKIP_BUILTIN_POSTGRES` | 是 | Heroku 上固定为 `true` |
| `SKIP_BUILTIN_REDIS` | 是 | 当前已验证链路固定为 `false` |
| `SUB2API_REDIS_CONF_B64` | 建议 | 内置 Redis 的 `redis.conf` |
| `GOGC` | 建议 | 当前建议值 `50` |
| `GOMEMLIMIT` | 建议 | 当前建议值 `300MiB` |
| `RUN_MODE` | 可选 | 需要简易模式时设为 `simple` |

配置示例：

```bash
heroku config:set SUB2API_CONFIG_YAML_B64="$(base64 < config.heroku.yaml | tr -d '\n')" -a <APP_NAME>
heroku config:set SUB2API_INSTALLED=true -a <APP_NAME>
heroku config:set SERVER_HOST=0.0.0.0 -a <APP_NAME>
heroku config:set SKIP_BUILTIN_POSTGRES=true -a <APP_NAME>
heroku config:set SKIP_BUILTIN_REDIS=false -a <APP_NAME>
heroku config:set SUB2API_REDIS_CONF_B64="$(base64 < deploy/redis.conf | tr -d '\n')" -a <APP_NAME>
heroku config:set GOGC=50 -a <APP_NAME>
heroku config:set GOMEMLIMIT=300MiB -a <APP_NAME>
```

## 端口与配置边界

- `PORT` 由 Heroku 在运行时注入，应用会优先使用它。
- 不要在 Heroku Config Vars 中设置 `SERVER_PORT`。
- 不要在 Heroku Config Vars 中继续保留 `BIND_HOST`；发布脚本会把旧值迁移到 `SERVER_HOST` 后清理掉。
- 不要再把运行时业务配置作为 `podman build --build-arg` 传入镜像。
- `server.port: 8080` 仅作为容器默认值保留，不代表 Heroku 最终监听端口。

## 发布命令

```bash
bash deploy/heroku-deploy-from-config.sh <APP_NAME>
```

脚本会自动做这些事：

1. 校验 Heroku 应用存在
2. 补齐 `SERVER_HOST`
3. 清理遗留 `SERVER_PORT`
4. 使用 `Dockerfile.heroku` 执行无缓存构建
5. 在镜像内执行 `/app/sub2api --version`
6. 推送并发布到 Heroku Container Registry
7. 轮询 `https://<app>.herokuapp.com/health`

## 故障排查

### 1. 看 dyno 状态

```bash
heroku ps -a <APP_NAME>
```

### 2. 持续看日志

```bash
heroku logs --tail -a <APP_NAME>
```

### 3. 校验应用地址和健康检查

```bash
WEB_URL="$(heroku info -s -a <APP_NAME> | awk -F= '$1==\"web_url\"{print $2}')"
curl -i "${WEB_URL%/}/health"
```

### 4. 查关键配置

```bash
heroku config:get SERVER_HOST -a <APP_NAME>
heroku config:get SERVER_PORT -a <APP_NAME>
heroku config:get SKIP_BUILTIN_REDIS -a <APP_NAME>
heroku config:get SUB2API_INSTALLED -a <APP_NAME>
```

`SERVER_PORT` 在正确状态下应为空。

## 当前仍需注意的运行风险

- 内置 Redis 跟应用同处一个 dyno，资源竞争会直接影响请求延迟和稳定性。
- `config.yaml` 通过环境变量注入，更新配置后需要重新发布或重启 dyno 才会生效。
- 如果后续切换到外部 Redis 或调整 `RUN_MODE`，需要同步更新 `config.yaml` 和 Heroku Config Vars，不能只改一侧。
