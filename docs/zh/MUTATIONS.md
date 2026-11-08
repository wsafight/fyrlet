# 操作结果与恢复

[English](../MUTATIONS.md) | 简体中文

路线图 1A 已实现。`call` 继续直接返回业务结果；`mutate` 立即发起相同调用，并提供生命周期、幂等键和恢复方法。HTTP 与 Socket RPC 使用相同语义。

| 状态 | 含义 |
| --- | --- |
| `pending` | 正在认证、发送或等待响应 |
| `completed` | `read` 操作已返回结果 |
| `committed` | `write` 操作的数据库事务已提交 |
| `accepted` | `run` 或 `ingest` 请求已持久受理，执行或处理可能尚未完成 |
| `failed` | 尚未开始发送，或服务端返回了带结构化错误的 4xx 拒绝响应 |
| `unknown` | 已开始发送，但客户端无法确定结果 |

`committed` 不表示订阅已经追平。`accepted` 不表示 Run 已完成、Effect 已送达或每条摄取项都处理成功；这些结果需要读取 Run 或批次视图。

## 跟踪调用

```ts
import { OutcomeUnknownError } from "@fyrlet/client";

const mutation = client.mutate("inbox.add", { text: "Hello" });
const stop = mutation.onChange((state) => renderSaveState(state));
try {
  const item = await mutation.result;
  renderSavedItem(item);
} catch (error) {
  if (error instanceof OutcomeUnknownError) {
    renderSaveState(await mutation.recover());
  } else {
    reportSaveError(error);
  }
} finally {
  stop();
}
```

`onChange` 立即通知当前状态；没有状态转换时，`getState()` 保持同一引用。监听器异常交给 `onListenerError`，不会改变操作结果。界面不再需要监听时，调用返回的清理函数。

SDK 在调用入口只序列化一次输入。之后修改调用方的对象，不会改变请求、认证重试或恢复查询。序列化失败、无效乐观更新目标等本地错误可以从 `mutate` 同步抛出；`call` 对这些错误返回拒绝的 Promise。

## 结果未知

开始发送后，断网、超时、取消等待、非法响应或 5xx 响应会产生 `OutcomeUnknownError`。它保留 `operation`、`idempotencyKey`、`outcome: "unknown"` 和原始 `cause`。`code` 描述底层原因；`retryable` 为 false，因为结果未知本身不能作为重放依据。发送前的失败保留原错误或取消原因。收到明确的认证拒绝时，SDK 可刷新一次凭证，并复用序列化输入和幂等键。

`AbortSignal` 和 `close()` 只停止客户端等待，不会撤销已经提交给服务端的事务。中断的业务调用不会自动重放。Run 的 signal/cancel 与服务端会话接口暂不使用这套 mutation 生命周期。

## 恢复结果

`mutation.recover({ signal? })` 只查询保存的回执。同一句柄上并发的恢复调用共用当前查询，采用首个调用者的 signal。恢复有新的超时期限，不复用原调用的取消信号。已终结的句柄直接返回原状态，不再查询。恢复查询出错时，Promise 拒绝，原来的未知状态保留。

页面刷新或更换 client 后，可以使用原操作、输入和幂等键：

```ts
const result = await client.recover("inbox.add", originalInput, {
  idempotencyKey: savedKey,
});
```

恢复要求相同项目和主体、有效会话、当前业务权限，以及该操作要求的能力。未过期且输入匹配的回执返回 `{status: "committed" | "accepted", data}`；查不到可见回执时返回 `{status: "unknown"}`。规范化输入不同会冲突。只有 `write` 与 `run` 提供操作级回执；摄取通过逐项 key 和批次视图判断结果。

查不到回执可能是事务仍在执行、已经回滚、回执过期或已清理，不能据此判定失败。恢复不会执行业务逻辑、删除过期回执、创建第二个 Run 或插入新的失效通知任务。回执默认保留 24 小时；超过保留期后重新调用业务操作，即使复用原键也可能再次执行。

如果需要跨页面或进程退出恢复，应在发起前持久化操作、输入、身份和幂等键，并通过 `idempotencyKey` 传入保存的键。SDK 没有持久队列。恢复成功会更新句柄状态，原来的 `result` Promise 仍保持拒绝状态。

## 预测与视图确认

确定失败时立即撤销本次调用的乐观预测。成功后，SDK 为预测涉及的快照或 append 订阅发起带关联标识的重新加载，只有匹配快照才移除对应预测；无关快照和 delta 不会提前结束预测。`optimisticTtlMs`（默认 5000 毫秒）仍是显示层兜底，不表示视图已确认。结果未知时保留预测直到 TTL，不发起确认请求。Presence 继续按 roster 更新处理预测。

`CallOptions.confirm` 可指定没有预测、但仍需确认的订阅。`mutation.result` 返回业务结果，不等待视图；`mutation.views` 为每个目标句柄返回 `{subscription, status: "confirmed" | "unconfirmed", error?}`，并自动包含预测涉及的快照与 append 订阅。超时、取消、权限撤销、能力不支持、退订或重连均产生明确的未确认结果，不改变已提交操作的状态，也不重放业务。没有目标时返回空数组。

```ts
const mutation = client.mutate("inbox.add", { text: "Hello" }, { confirm: [recent] });
await mutation.result;
const views = await mutation.views;
```

`subscription.confirm({signal?})` 可单独等待一次新请求的权威快照；`subscription.refresh()` 仍只等待 accepted 回执。确认使用 `timeoutMs`，绑定当前 generation，每个 Entry 最多保留 32 个待确认请求。未知回执恢复后，可显式调用各订阅的 `confirm()`。空结果、记录被过滤或删除、查询结果不变，都可以确认；确认针对查询结果，不保证特定记录存在，也不表示后台工作完成。

## 可运行示例

Inbox CLI 已使用这套生命周期，遇到未知结果时查询一次回执：

```sh
npm --prefix sdks/typescript run build
node sdks/typescript/examples/inbox.mjs 'Hello'
FYRLET_RECOVER_KEY=original-key node sdks/typescript/examples/inbox.mjs 'Hello'
```

按 [SDK README](../../sdks/typescript/README.zh-CN.md) 启动 Inbox 服务端并准备 `.local/project.json`。带 `FYRLET_RECOVER_KEY` 的命令只查询回执。测试覆盖真实提交后丢失 HTTP / Socket 响应、取消、响应体停滞、过期、输入冲突、权限与身份隔离。命令和数量记录在 [ACCEPTANCE.md](ACCEPTANCE.md)。
