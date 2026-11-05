# Fyrlet TypeScript SDK

SDK 核心提供业务调用与实时订阅，不依赖 React、浏览器存储或 Cookie 登录。当前包为本地 private 包，构建产物在 dist。

本 SDK 位于 `sdks/typescript/`，供 JavaScript / TypeScript 应用使用；多语言布局和新增 SDK 的要求见 [SDK 总览](../README.md)。React 适配包后续基于本 SDK 实现，React Native 的运行时适配也属于 TypeScript 生态。

## 入口

- `@fyrlet/client`：createClient、ApiError 与公开类型。
- `@fyrlet/client/server`：受信后端的 createSessionService。
- `@fyrlet/client/example-contract`：从收件箱服务端契约生成的类型。

## 后端交换会话

```ts
import { createSessionService } from "@fyrlet/client/server";

const sessions = createSessionService({
  endpoint: process.env.FYRLET_ENDPOINT!,
  serviceKey: process.env.FYRLET_SERVICE_KEY!,
});

const session = await sessions.issueSession({
  external_subject: authenticatedUser.id,
  issuer: "my-product",
  ttl_seconds: 600,
});
```

authenticatedUser 必须来自客户应用已验证的登录态。把 session.token 返回给对应用户；不要把服务密钥返回客户端。`revokeSession(session_id)` 可以撤销本项目单个会话。

## 调用与重试

`createClient<Contract>({endpoint,projectId,getToken})` 使用宿主应用提供的短期用户令牌。首次认证读取 identity 并绑定 Subject，拒绝在同一个 client 中切换账号。getToken 收到 forceRefresh=true 时应重新验证宿主登录态并获取会话。

```ts
const item = await client.call("inbox.add", { text: "Hello" }, {
  idempotencyKey: stableRequestId,
  signal: controller.signal,
});
await client.call("inbox.update", {
  id: item.id,
  text: "Updated",
  expected_version: item.version,
});
```

SDK 为每次 call 自动生成幂等键，HTTP 401 最多刷新一次并复用该键。网络中断后的业务重试由调用者决定，需要显式复用同一键。CONFLICT 不自动重试。宿主登录失效时，getToken 应抛出 code 为 UNAUTHENTICATED 的 ApiError，结束自动恢复并清空订阅数据。

ApiError 包含 code、message、details、retryable、status、requestId。HTTP 与调用等待默认 10 秒超时，可用 timeoutMs 调整；AbortSignal 和 close 可以取消客户端等待。取消或超时不表示服务端一定未提交，重试写入仍应复用幂等键。

## 订阅状态

```ts
const recent = client.subscribe("inbox.recent", { limit: 20 });
const stop = recent.onChange(({ status, data, error }) => {
  renderInbox({ status, data, error });
});
await recent.refresh();
stop();
recent.unsubscribe();
client.close();
```

onChange 立即发出当前状态，之后在状态更新时通知。connecting 是初次建立；ready 表示收到当前订阅快照；recovering 保留旧数据并标记正在恢复；error 和 closed 清空数据。generation 与 seq 用于排除旧订阅或旧消息。

refresh 返回 Promise<void>，只表示服务端接受刷新请求；观察之后的状态更新取得数据。SDK 自动确认快照、重建断线订阅，并在重连初始快照后进入 ready。业务和权限错误终止对应订阅；reconnect 可以显式重新尝试所有仍保留的订阅。

unsubscribe 结束一个订阅，最后一个订阅结束时释放连接。close 释放所有订阅、定时器和请求，并禁止再次使用这个 client。账号切换时先 close，再创建新的 client。

## 运行时适配

ClientOptions 支持注入 fetch、WebSocket、createId、retryDelayMs 与 onListenerError。默认 createId 使用 crypto.randomUUID；缺少该 API 的运行时必须提供安全随机 UUID 生成函数。

Node 已通过真实集成测试。浏览器与 React Native 不需要导入 server 入口；React Native 还需宿主处理前后台切换、网络恢复和安全令牌存储，真机行为尚未验收。没有移动端推送或离线写入。

## 契约与验证

```sh
mix fyrlet.contract priv/contract.json
npm --prefix sdks/typescript run generate
npm --prefix sdks/typescript run build
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run typecheck
bash scripts/integration.sh
```

命令从仓库根目录执行。生成器支持当前受限契约，拒绝不支持的 schema；输入默认字段生成可选属性，输出按 required 字段生成。生成类型提供编译期约束，服务端仍对所有输入输出进行运行时校验。
