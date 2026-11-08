# 真实 staging OIDC 验收

[English](../STAGING.md) | 简体中文

`scripts/staging_acceptance.mjs` 是针对已部署 `examples/inbox-react` 应用的**显式 opt-in** 验收器。它补充 `scripts/acceptance.mjs`：本地测试和签名测试 IdP 不能作为外部 IdP 或 staging 部署的证据。

验收器执行真实浏览器登录、应用操作和 SDK 检查。它不会启动或代替部署、伪造身份、模拟 HTTP/WebSocket 流量、关闭 TLS，也不会把无法执行的场景转换为通过。

## 安全边界与结果语义

共有三个入口：

```sh
# 只读取本地文件和 Git；不访问网络。
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json

# 只执行真实 discovery、PostgreSQL/schema 和 readiness；不登录。
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json \
  --preflight --confirm inbox-staging

# 预检查后执行真实浏览器／应用验收。
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json \
  --execute --confirm inbox-staging
```

`--preflight` 和 `--execute` 都要求 `--confirm` 与配置的 `deployment.id` 完全一致。除精确匹配 `deployment.sourceRevision` 外，还要求 checkout 中不存在已跟踪或未忽略的未跟踪变更；仅配置模式允许在 dirty checkout 中运行。缺少配置、凭证、浏览器步骤、storage state、不可变元数据或确认值时，在相应网络动作之前失败。默认模式不会调用部署检查器、启动浏览器、重建 SDK 或连接 IdP／API／宿主。

每个场景都记录 `passed`、`failed` 或 `not-run`，并附原因。执行报告的 `status: "passed"` 要求每项必需应用检查恰好有一条通过记录，且没有失败记录。必需记录缺失、重复、失败或为 `not-run` 时，会生成失败的 `application-completeness` 证据。可选 `not-run` 场景仍然可见，绝不会转换成通过。只有全部已记录执行场景通过时，`complete` 才为 true。特别地：

- 预检查报告为 `kind: "staging-preflight"` 和 `acceptance.status: "not-run"`；discovery/readiness 不等于登录验收。
- storage state 认证会把 `interactive-idp-login` 保留为 `not-run`。
- 单宿主会把 `multi-host-shared-store` 保留为 `not-run`；未配置第二账号时，账号切换／隔离为 `not-run`。
- 这个通用工具始终把 `external-idp-revocation` 保留为 `not-run`。它验证有界宿主／会话到期和应用退出／撤销，不猜测 IdP 专用禁用用户 API，也不宣称持续 introspection。
- 缺少必需结果记录、执行期间源码变化都属于失败，不是部分通过。

报告默认原子写入 `.local/staging-acceptance/` 下的唯一目录，也可用 `--out` 指定。应使用被 Git 忽略的目录：在仓库内更新未忽略报告会故意触发冻结源码检查失败。输出必须是由当前用户拥有的非符号链接目录，group/other 无访问权限；文件权限为 `0600`。每次更新使用安全随机的排他临时文件再 rename。不保存截图、trace 或新的 storage state。

报告包含源码洁净状态／revision／指纹、声明的部署元数据、检查名称／状态／原因、公开／直连及允许的浏览器 origin、脱敏的 SDK／Phoenix 运行时 digest 和浏览器版本；不包含密码、client/service key、数据库 URL/key、cookie、token、subject 标识、用户名、OIDC 回调参数、响应 body、原始浏览器错误或 storage state。终端和报告都会抑制意外错误详情。因此，JSON 配置中的 release 名、artifact digest、origin 和 provider 名属于公开报告元数据，不应放入秘密。

## 前置条件

在仓库根目录准备现有依赖和浏览器（这些安装命令不属于离线单元测试）：

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react run build
npm --prefix examples/inbox-react ci
(cd examples/inbox-react && npx playwright install chromium)
```

验收器从 `examples/inbox-react` 解析 Playwright 和 `@fyrlet/client`，不会再实现一套协议。

staging 操作人员必须提供：

1. 精确部署 Git revision、不可变宿主／API release 名及 SHA-256 artifact digest。本地 checkout 的 `HEAD` 必须等于 `deployment.sourceRevision`。真实网络模式还会拒绝任何已跟踪或未忽略的未跟踪 checkout 变更；编辑期间请单独运行仅配置验证。artifact 字段是精确的**操作方声明**；通用验收器不会 introspect Kubernetes、容器 registry 或其他编排器。
2. 使用同一项目／配置的生产构建 Inbox 宿主和 API。源码指纹覆盖 Git 已跟踪和未忽略的未跟踪文件，并在执行结束后再次核对。真实 CLI 执行会使用现有本地依赖，通过 `npm --offline run build` 删除并重建 `sdks/typescript/dist`，验证 Inbox 解析到该 SDK，并哈希构建运行时、package lock／元数据及实际解析的 Phoenix ESM 入口。digest 会写入报告并在结束时再次核对；preflight 和注入的离线测试 runner 不执行该构建。
3. 公开 API／直连宿主和 IdP 均使用 HTTPS。只有明确 loopback URL 可使用 HTTP；现有部署预检查仍严格执行安全部署要求。携带凭证的重定向会被拒绝。
4. 每个 IdP 的精确 issuer、client ID、S256 PKCE，以及宿主实际使用的 public-client（`none`）或 `client_secret_basic` token 认证。只登记真实公开回调，例如 `https://staging.inbox.example.com/auth/callback`。API 的 CORS/allowed origins 也必须配置同一公开 origin。
5. 数据已知且不包含生产信息的专用 staging 账号。配置同 issuer 的两个账号可验证账号切换和 subject 隔离；配置两个 issuer 的账号可验证 issuer/subject 对隔离。最强的跨 issuer 检查应使用不同 issuer 下相同外部用户名／subject 的两个身份。交互流程必须能在不绕过 CAPTCHA 或其他 IdP 策略的前提下自动执行。
6. 验收器到 IdP discovery/authorization/token/JWKS、每个直连宿主、API HTTP/WebSocket 的出站访问。预检查还会连接配置的 PostgreSQL 宿主存储和 API readiness，因此数据库／网络策略必须允许。
7. 多宿主时，每个实例使用不同的直连 HTTPS origin，并共享公开 origin、项目、endpoint、provider 身份、`HOST_STORE_NAMESPACE` 和 32 字节 base64url `HOST_STORE_KEY`。`hosts.length` 必须等于 `HOST_INSTANCES`。使用 direct 或 session-affine PostgreSQL，禁止使用 transaction/statement pooling；每宿主 advisory lock 绑定数据库 session。验收前先运行现有 store migration。

直连 origin 必须唯一。用两个 ID 重复同一个负载均衡 URL 会被拒绝，因为这不构成双宿主行为证据。直连 origin 仅用于宿主 session／元数据请求；浏览器登录始终使用公开 origin。

## 私有配置

把安全示例复制到忽略目录：

```sh
mkdir -p .local/staging
chmod 700 .local/staging
cp deploy/staging/acceptance.example.json .local/staging/acceptance.json
cp deploy/staging/inbox-react.env.example .local/staging/inbox-react.env
chmod 600 .local/staging/inbox-react.env
```

编辑两个副本。`environmentFile` 相对 JSON 文件解析。环境文件和 storage-state 文件必须是非符号链接普通文件，group/other 无权限。JSON 本身不含凭证，可纳入源码指纹。

必须替换全零 digest 和 Git revision；占位值会被明确拒绝。`deployment.hostRelease` 和 `apiRelease` 必须是不可变标识，不能使用 `latest`。

环境文件提供精确宿主部署配置（`PUBLIC_ORIGIN`、`FYRLET_ENDPOINT`、项目／service 配置、`OIDC_PROVIDERS` 和宿主存储配置）。`ALLOW_INSECURE_OIDC=1` 会被拒绝。账号值可放入该私有文件，或由 secret manager 注入验收器进程。不要把密码或 token 放进命令行参数、shell history、JSON 步骤或报告。

### 可配置交互 IdP 流程

每个账号选择 `OIDC_PROVIDERS` 中的一个 provider，并且只能选择一种认证方式。`steps` 支持：

- `fill`：`selector` 加 `valueFromEnv`；值只在内存中解析。
- `click`、`check`、`uncheck`：Playwright CSS selector。
- `press`：selector 和 `Enter` 等按键。
- `wait`：等待 selector 可见。

验收器点击现有 Inbox provider 链接后，在同一标签页按顺序执行步骤。根据用户名、密码、确定性 MFA 和 consent 页面调整 selector。最多 30 步，所有 Playwright 等待都有界。拒绝字面量 `value`、`text` 和 `password` 字段。浏览器降级到非 loopback HTTP 的请求会被阻止。

随后验证 `/auth/me` 返回的 issuer 与配置完全一致，复用现有 Inbox selector，检查有界 Secure/HttpOnly/SameSite=Lax 宿主 cookie，并等待真实订阅 ready。流程无法完成就是失败，不会用合成登录替代。

### 已有真实登录的 storage state

账号可以不用 `steps`，改为：

```json
{ "provider": "first", "storageStateFromEnv": "STAGING_PRIMARY_STATE" }
```

把 `STAGING_PRIMARY_STATE` 指向新生成的 Playwright storage-state JSON；相对路径相对验收配置解析。只能在对同一 staging 部署真实登录后生成，权限保持 `0600`，不再需要时删除。文件含等价于 bearer 凭证的 cookie。验收器只接受 cookie（不接受 local-storage origin），限制文件大小／数量，拒绝不安全 cookie，并且不保存或打印内容。

storage state 能证明所给登录态可用于真实应用，不能证明完成了一次新的交互 IdP 授权。账号切换后返回主账号需要新的交互主账号登录，因此主账号使用 storage state 时，该场景保持 `not-run`。

## 实际应用覆盖

完整配置的执行会检查：

1. 每个直连宿主的匿名 `/auth/me` 元数据一致。这不宣称已验证编排器 artifact digest。
2. 真实交互 IdP 流程或提供的真实登录 storage state 完成主账号认证。
3. 宿主 cookie 和签发 session 的到期时间符合 `revocation.maxHostSessionSeconds`（60–3600 秒）与 `revocation.maxTokenSeconds`（60–600 秒），允许有界时钟误差。策略必须为 `bounded-host-expiry`。
4. 现有 Inbox UI 新建唯一笔记并到达 `已保存并同步`。第二个浏览器页面和真实 SDK `inbox.recent` 查询独立看到该笔记。这同时覆盖 mutation 提交和**权威视图确认**，不只看乐观文本。示例没有删除操作，因此笔记会留在 staging（部分失败后也是如此）。
5. 强制 session 续期撤销旧凭证，保持稳定的 SDK subject 身份和已确认视图。配置两个以上宿主时，使用第一个宿主的 cookie 向第二个直连宿主续期；旧凭证必须以 `UNAUTHENTICATED` 失败，新凭证必须完成真实 SDK 查询。
6. 现有退出按钮清除私有 UI 状态。旧宿主 cookie 不能再签发 session（包括通过最后一个直连宿主），旧 API 凭证也会被真实 SDK 查询拒绝。
7. 配置第二账号且主账号为交互流程时，切换账号，确认主账号笔记／subject 不可访问，再切回并验证稳定主 subject 和恢复的数据。精确 issuer 和 SDK subject 标识只在内存中比较，不写入报告。交互账号之间清除浏览器 cookie，避免 SSO 静默回到上一账号；这不宣称全局 IdP 退出。
8. 浏览器 JavaScript 错误会使运行检查失败；可能含敏感信息的错误消息不会保留。最后尽力执行应用退出清理，但不改变任何场景结果。

不会猜测外部 IdP 禁用／撤销传播。当前宿主通过宿主失效或宿主／session 到期为其效果设定上界。观察到 TTL 上界不代表存在外部撤销 webhook，也不代表实际触发过外部撤销。需要该证据时，应另做 IdP 专用撤销演练。

## 仍需外部证据

本验收器不证明生产容量、24 小时稳定性、实体设备行为、宿主 kill／网络分区恢复、全局 IdP 退出、外部 IdP 撤销、registry 发布或生产批准。artifact 身份以及秘密／配置是否统一投递仍需部署系统证据。staging 通过报告必须连同其中 `not-run` 原因和现有发布检查单一起审查。

## 离线专项测试

```sh
node --check scripts/staging_acceptance.mjs
node --test scripts/staging_acceptance.test.mjs
```

测试只使用临时本地 fixture 和注入故障，不启动浏览器、不绑定端口、不连接 PostgreSQL、不执行 OIDC discovery，也不发任何真实网络请求。
