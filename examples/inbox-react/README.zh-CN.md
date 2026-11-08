# 随记：带 OIDC 登录的 React 记录应用

[English](README.md) | 简体中文

「随记」用于保存待办、灵感和文字片段。本示例组合已有的 Inbox Mix 宿主、独立 React 适配包和 Node 宿主后端，展示查询复用、selector、参数切换、乐观写入、分别可观察的提交与视图确认、可选重试，以及经过身份验证的登录桥接。密码和账号管理由现有 OpenID Connect 服务负责。

## 启动

按 [Inbox 宿主](../inbox/README.zh-CN.md)准备 PostgreSQL 和 Mix 依赖，在仓库根目录运行：

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react run build
npm --prefix examples/inbox-react ci
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/inbox-react-project.json "随记"
PHX_SERVER=true PORT=4180 mix phx.server
```

另开终端，将 `examples/inbox-react/.env.example` 复制为同目录的 `.env`。从忽略目录的项目文件填写 `FYRLET_PROJECT_ID` 和 `FYRLET_SERVICE_KEY`，服务密钥只留在后端。填写身份服务的准确 issuer、client ID 和 client secret；公开 PKCE 客户端省略 `clientSecret`。在身份服务中登记回调地址 `http://127.0.0.1:5173/auth/callback`，并确认支持 S256 PKCE，以及 `client_secret_basic` 或 `none` 令牌端点认证。

```sh
npm --prefix examples/inbox-react run dev
```

访问 `http://127.0.0.1:5173`，API 宿主默认允许此源。若修改地址，同时更新 `PUBLIC_ORIGIN`、IdP 回调和 API 宿主的 `CORS_ORIGINS` / `ALLOWED_ORIGINS`。`npm --prefix examples/inbox-react run build` 生成构建产物，`npm --prefix examples/inbox-react start` 提供构建后的页面。

`ALLOW_INSECURE_OIDC=1` 只允许开发时使用 loopback HTTP。生产 TLS 网关后应使用 HTTPS 源和端点，并移除此变量。`OIDC_PROVIDERS` 最多配置八个身份服务；身份按已验证的 issuer 与 subject 对映射，不同 issuer 下同名用户互相独立。

## 登录与清理

后端只发现已配置的 issuer，验证发现文档的 issuer、端点和 PKCE 支持。登录检查与 HttpOnly Cookie 绑定的一次性 state、PKCE、ID token 签名、issuer、audience、authorized party、nonce 和有效期。浏览器不能提供可信 subject。宿主 Cookie 使用 HttpOnly、SameSite=Lax，HTTPS 下附加 Secure。会话交换、退出和撤销要求准确的同源 Origin；会话接口不接受身份参数请求体。

`POST /api/fyrlet/session` 重新验证宿主登录，合并并发交换，只返回短期 Fyrlet 令牌；`x-fyrlet-refresh: 1` 轮换令牌并撤销旧令牌。`POST /auth/logout` 和 `/auth/revoke` 关闭宿主登录并撤销对应 Fyrlet 会话。退出与签发并发时，迟到的令牌会在返回前撤销。切换账号会关闭旧宿主会话。浏览器退出时关闭 client 和令牌请求；BroadcastChannel 通知其他标签页，窗口重新聚焦时检查身份 revision。

本示例在单进程内最多保存 1000 个待登录请求和 1000 个宿主会话。待登录请求五分钟到期；宿主会话最多一小时，且不超过 ID token 有效期。到期后立即拒绝本地登录，后台撤销最多八个并发，失败至少间隔十秒重试。重启进程后需重新登录；多实例宿主需接入自己的共享会话存储。外部 IdP 撤销通过宿主失效或会话到期生效，示例不宣称持续向 IdP 内省。远程退出失败会明确显示撤销未确认，本地私有状态仍被清空。

## 验证

```sh
npm --prefix sdks/react test
npm --prefix examples/inbox-react test
npm --prefix examples/inbox-react run test:coverage
(cd examples/inbox-react && npx playwright install chromium)
bash scripts/react.sh
```

最后一个命令创建独立 PostgreSQL 项目，运行真实 API、生产构建和带签名的本地测试 IdP。覆盖查询复用、提交后丢响应而不重复写入、视图确认、双标签、参数切换、API 重启、续期、退出、撤销、用户与 issuer 隔离，以及桌面和移动布局。模拟身份服务仅供测试；生产 IdP 凭证、实体设备、多主机部署和正式包发布不计入本轮本地验收。
