# Sub2API

## 项目概述

Sub2API 是一个 AI API 网关平台，用于分发和管理 AI 产品订阅的 API 配额。用户通过平台生成的 API Key 调用上游 AI 服务，平台负责鉴权、计费、负载均衡和请求转发。

## 核心功能

- **多账号管理** - 支持多种上游账号类型（OAuth、API Key）
- **API Key 分发** - 为用户生成和管理 API Key
- **精确计费** - Token 级别的用量追踪和成本计算
- **智能调度** - 智能账号选择，支持粘性会话
- **并发控制** - 用户级和账号级并发限制
- **速率限制** - 可配置的请求和 Token 速率限制
- **内置支付系统** - 支持 EasyPay 易支付、支付宝官方、微信官方、Stripe，用户自助充值，无需独立部署支付服务（[配置指南](docs/PAYMENT_CN.md)）
- **管理后台** - Web 界面进行监控和管理
- **外部系统集成** - 支持通过 iframe 嵌入外部系统（如工单等），扩展管理后台功能

## 技术栈

| 组件 | 技术 |
|------|------|
| 后端 | Go 1.25.7, Gin, Ent |
| 前端 | Vue 3.4+, Vite 5+, TailwindCSS |
| 数据库 | PostgreSQL 15+ |
| 缓存/队列 | Redis 7+ |

---

## Heroku 部署

README 仅保留 Heroku 容器部署主线。运行时配置通过 Heroku Config Vars 注入，业务配置不要在镜像构建阶段烘焙。

#### 前置条件

- 已安装并登录 Heroku CLI
- 已安装 Podman
- 已安装 curl
- 已创建 Heroku 应用，并设置为 Container stack

```bash
heroku login
heroku create <APP_NAME>
heroku stack:set container -a <APP_NAME>
```

#### 准备运行时配置

Heroku 文件系统是临时的，容器重启后不会保留 `/app/data` 中手工写入的配置。`config.yaml` 需要通过环境变量注入：

```bash
# 必需
heroku config:set SUB2API_CONFIG_YAML_B64="$(base64 < config.yaml | tr -d '\n')" -a <APP_NAME>
heroku config:set SUB2API_INSTALLED=true -a <APP_NAME>

# 可选
heroku config:set SUB2API_REDIS_CONF_B64="$(base64 < deploy/redis.conf | tr -d '\n')" -a <APP_NAME>
heroku config:set SERVER_HOST=0.0.0.0 -a <APP_NAME>
```

如需简易模式，可额外设置：

```bash
heroku config:set RUN_MODE=simple -a <APP_NAME>
```

#### 端口规则

- `PORT` 由 Heroku 在运行时自动提供，应用会优先使用它。
- **不要** 在 Heroku Config Vars 中手动设置 `SERVER_PORT`。
- `config.yaml` 中即使保留 `server.port: 8080`，运行时也会被 `PORT` 覆盖。

#### 发布

在项目根目录执行：

```bash
bash deploy/heroku-deploy-from-config.sh <APP_NAME>
```

该脚本会自动完成以下动作：

1. 校验 Heroku 应用存在
2. 清理遗留 `SERVER_PORT`
3. 读取并校验必要的 Heroku Config Vars
4. 使用 `Dockerfile.heroku` 执行无缓存容器构建
5. 推送到 `registry.heroku.com/<APP_NAME>/web`
6. 执行 `heroku container:release`
7. 轮询 `/health` 直到返回 `200 OK`

#### 发布后检查

```bash
heroku ps -a <APP_NAME>
heroku logs --tail -a <APP_NAME>

WEB_URL="$(heroku info -s -a <APP_NAME> | awk -F= '$1==\"web_url\"{print $2}')"
curl -i "${WEB_URL%/}/health"
```

#### 关键文件

- `Dockerfile.heroku`：Heroku 容器镜像构建文件
- `deploy/heroku-deploy-from-config.sh`：正式发布脚本
- `deploy/docker-entrypoint.sh`：容器启动时恢复 `config.yaml`、`.installed`、`redis.conf`


**网关防御纵深建议（重点）**

- `gateway.upstream_response_read_max_bytes`：限制非流式上游响应读取大小（默认 `8MB`），用于防止异常响应导致内存放大。
- `gateway.proxy_probe_response_read_max_bytes`：限制代理探测响应读取大小（默认 `1MB`）。
- `gateway.gemini_debug_response_headers`：默认 `false`，仅在排障时短时开启，避免高频请求日志开销。
- `/auth/register`、`/auth/login`、`/auth/login/2fa`、`/auth/send-verify-code` 已提供服务端兜底限流（Redis 故障时 fail-close）。
- 推荐将 WAF/CDN 作为第一层防护，服务端限流与响应读取上限作为第二层兜底；两层同时保留，避免旁路流量与误配置风险。

**⚠️ 安全警告：HTTP URL 配置**

当 `security.url_allowlist.enabled=false` 时，系统默认执行最小 URL 校验，**拒绝 HTTP URL**，仅允许 HTTPS。要允许 HTTP URL（例如用于开发或内网测试），必须显式设置：

```yaml
security:
  url_allowlist:
    enabled: false                # 禁用白名单检查
    allow_insecure_http: true     # 允许 HTTP URL（⚠️ 不安全）
```

**或通过环境变量：**

```bash
SECURITY_URL_ALLOWLIST_ENABLED=false
SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=true
```

**允许 HTTP 的风险：**
- API 密钥和数据以**明文传输**（可被截获）
- 易受**中间人攻击 (MITM)**
- **不适合生产环境**

**适用场景：**
- ✅ 开发/测试环境的本地服务器（http://localhost）
- ✅ 内网可信端点
- ✅ 获取 HTTPS 前测试账号连通性
- ❌ 生产环境（仅使用 HTTPS）

**未设置此项时的错误示例：**
```
Invalid base URL: invalid url scheme: http
```

如关闭 URL 校验或响应头过滤，请加强网络层防护：
- 出站访问白名单限制上游域名/IP
- 阻断私网/回环/链路本地地址
- 强制仅允许 TLS 出站
- 在反向代理层移除敏感响应头

```bash
# 6. 运行应用
./sub2api
```
---

## 简易模式

简易模式适合个人开发者或内部团队快速使用，不依赖完整 SaaS 功能。

- 启用方式：设置环境变量 `RUN_MODE=simple`
- 功能差异：隐藏 SaaS 相关功能，跳过计费流程
- 安全注意事项：生产环境需同时设置 `SIMPLE_MODE_CONFIRM=true` 才允许启动

---

## Antigravity 使用说明

Sub2API 支持 [Antigravity](https://antigravity.so/) 账户，授权后可通过专用端点访问 Claude 和 Gemini 模型。

### 专用端点

| 端点 | 模型 |
|------|------|
| `/antigravity/v1/messages` | Claude 模型 |
| `/antigravity/v1beta/` | Gemini 模型 |

### Claude Code 配置示例

```bash
export ANTHROPIC_BASE_URL="http://localhost:8080/antigravity"
export ANTHROPIC_AUTH_TOKEN="sk-xxx"
```

### 混合调度模式

Antigravity 账户支持可选的**混合调度**功能。开启后，通用端点 `/v1/messages` 和 `/v1beta/` 也会调度该账户。

> **⚠️ 注意**：Anthropic Claude 和 Antigravity Claude **不能在同一上下文中混合使用**，请通过分组功能做好隔离。


### 已知问题
在 Claude Code 中，无法自动退出Plan Mode。（正常使用原生Claude Api时，Plan 完成后，Claude Code会弹出弹出选项让用户同意或拒绝Plan。） 
解决办法：shift + Tab，手动退出Plan mode，然后输入内容 告诉 Claude Code 同意或拒绝 Plan
---

## 项目结构

```
sub2api/
├── backend/                  # Go 后端服务
│   ├── cmd/server/           # 应用入口
│   ├── internal/             # 内部模块
│   │   ├── config/           # 配置管理
│   │   ├── model/            # 数据模型
│   │   ├── service/          # 业务逻辑
│   │   ├── handler/          # HTTP 处理器
│   │   └── gateway/          # API 网关核心
│   └── resources/            # 静态资源
│
├── frontend/                 # Vue 3 前端
│   └── src/
│       ├── api/              # API 调用
│       ├── stores/           # 状态管理
│       ├── views/            # 页面组件
│       └── components/       # 通用组件
│
└── deploy/                   # 部署文件
    ├── heroku-deploy-from-config.sh  # Heroku 发布脚本
    ├── docker-entrypoint.sh  # Heroku 容器入口脚本
    ├── config.example.yaml   # 二进制部署完整配置文件
    └── redis.conf            # 默认 Redis 配置
```

## 免责声明

> **使用本项目前请仔细阅读：**
>
> :rotating_light: **服务条款风险**: 使用本项目可能违反 Anthropic 的服务条款。请在使用前仔细阅读 Anthropic 的用户协议，使用本项目的一切风险由用户自行承担。
>
> :book: **免责声明**: 本项目仅供技术学习和研究使用，作者不对因使用本项目导致的账户封禁、服务中断或其他损失承担任何责任。

---

## Star History

<a href="https://star-history.com/#Wei-Shaw/sub2api&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Wei-Shaw/sub2api&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Wei-Shaw/sub2api&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Wei-Shaw/sub2api&type=Date" />
 </picture>
</a>

---

## 许可证

本项目基于 [GNU 宽通用公共许可证 v3.0](LICENSE)（或更高版本）授权。

Copyright (c) 2026 Wesley Liddick

---

<div align="center">

**如果觉得有用，请给个 Star 支持一下！**

</div>
