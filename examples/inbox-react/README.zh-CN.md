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

默认使用内存，最多保存 1000 个待登录请求和 1000 个宿主会话，重启后需重新登录。待登录请求五分钟到期；宿主会话最多一小时，且不超过 ID token 有效期。到期或关闭后立即拒绝登录，每进程后台撤销最多八个并发，失败至少间隔十秒重试。外部 IdP 撤销通过宿主失效或会话到期生效，不宣称持续向 IdP 内省。远程退出失败会明确显示撤销未确认，本地私有状态仍被清空。

## PostgreSQL 共享宿主存储

多 Node 实例部署时，各实例的私有环境设置 `HOST_STORE_DATABASE_URL`、相同的 `HOST_STORE_KEY`（32 个随机字节的 base64url 编码）、`HOST_STORE_NAMESPACE` 和 `HOST_INSTANCES=2`。可用 `node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"` 生成密钥，不要提交。所有实例的公开源、Fyrlet 端点／项目、OIDC provider 名称／issuer／client ID 必须一致。先用有建表权限的账号运行一次 `npm --prefix examples/inbox-react run migrate:store`，再以普通表访问权限启动宿主。不同宿主端口可置于同一 HTTPS 源后，不需要依赖粘性路由。

使用直接 PostgreSQL 连接或 session-affine 连接池，**不能使用 transaction/statement pooling**：单宿主会话串行化依赖会话级 advisory lock。每进程最多八条池连接、64 个等待或活跃宿主变更，建连、查询、锁等待均有上限；连接预算与 Fyrlet 自身及通知监听器分开预留。state 和令牌载荷以 AES-256-GCM 认证加密，数据库只保存宿主 Cookie 的哈希标识。命名空间、公开源、端点、项目和 provider 身份共同隔离数据；每个 scope 全局最多 1000 个待登录请求、1000 个宿主会话。过期登录 state 在新请求入场时清除；关闭／到期的宿主由请求及定时器触发有界撤销和清理。

最多七条连接持有宿主锁，为退出／控制查询保留一条连接；变更回调内的查询复用已持有的连接。认证／会话请求最多接纳 64 个普通请求，另为退出／撤销保留八个入口。这些是单进程安全边界，不是吞吐保证。已知凭据若持久化宿主失败，会尽力撤销，并将对应宿主标为关闭。

登录 state 跨实例原子消费一次，续期按宿主会话串行化；退出不必等待签发锁即可写关闭标记，迟到的签发在返回前检查它。持锁进程被杀后数据库锁释放，共享存储宿主正常退出不会把其他实例的用户登出。存储错误按失败关闭处理。若远程已签发而响应或持久化丢失，可能存在未返回浏览器的凭据：已知凭据尽力撤销，未知凭据受请求有效期限制（最多十分钟）。这不是跨服务原子签发。密钥备份／轮换需单独处理：密钥丢失或直接替换后不能解密、清理旧行，删除旧状态前先对账／撤销会话。生产环境需验证数据库 TLS，并使用密钥管理设施。

## 验证

生产部署前，在仓库根目录执行 `node --env-file-if-exists=examples/inbox-react/.env examples/inbox-react/server/check.mjs`，检查 HTTPS 配置、discovery、已配置存储的表访问和数据库就绪，不签发会话。多实例要求 PostgreSQL 存储与合法加密密钥。预检查不能替代真实 IdP 生命周期验收，见[发布检查](../../docs/zh/RELEASE_CHECKLIST.md)。`bash scripts/host_store.sh` 使用独立本地 PostgreSQL，覆盖两套独立宿主池、重启、续期／退出竞态和进程死亡，不联系外部 IdP。

```sh
npm --prefix sdks/react test
npm --prefix examples/inbox-react test
npm --prefix examples/inbox-react run test:coverage
(cd examples/inbox-react && npx playwright install chromium)
bash scripts/react.sh
```

最后一个命令创建独立 PostgreSQL 项目，运行真实 API、生产构建和带签名的本地测试 IdP。覆盖查询复用、提交后丢响应而不重复写入、视图确认、双标签、参数切换、API 重启、续期、退出、撤销、用户与 issuer 隔离，以及桌面和移动布局。模拟身份服务仅供测试；生产 IdP 凭证、实体设备、多主机部署和正式包发布不计入本轮本地验收。
