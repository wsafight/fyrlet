# 追加订阅（Stream）

可选能力 `append`。适用于**不可变的追加记录**：消息事件、日志、Run 事件。订阅的数据是“最新的至多 N 条”这个窗口；新记录以批次追加，旧记录按窗口淘汰。线上格式见 [PROTOCOL.md](PROTOCOL.md#追加订阅能力-append)，业务侧写法见 [SERVER.md](SERVER.md#追加订阅与-fyrletfeaturesstream)。

## 适用范围

- 只支持**追加**。增量事件不包含 `update` / `delete` / 任意 JSON Patch。
- 不满足追加语义的查询保持普通快照订阅。已发布记录需要更正或删除时，服务端必须重置流（见下文），不能让客户端继续把旧记录当作不可变事实。
- 快照是当前窗口的权威状态，不是完整历史。需要完整日志的业务自行提供历史分页、游标有效期、保留期和“历史已截断”标记。
- 与普通订阅的字段级增量（`delivery: "delta-v1"`，针对已有记录的字段变化）是两回事，互不影响。

## 契约与定义

订阅在契约里声明 `mode: "append"`、`max_items`（1–500）和 `capability: "append"`；定义实现 `stream/3`，返回 `Fyrlet.Features.Stream` 的流名（在 `authorize/3` 之后调用）。校验在注册表加载时完成，缺少任何一项，应用启动即失败。服务端需开启 `capabilities: %{"append" => 1}`。

## 流与位置

流由两张表保存：`fyrlet_streams`（每流一行：`head`、`epoch`、`trimmed_before`）和 `fyrlet_stream_entries`。

- `Fyrlet.Features.Stream.append/3` **必须在事务内调用**。它在流行上取号并持锁到提交，同一流的追加者按取号顺序提交，回滚归还位置。
- 读者看到 `head = H`，就保证位置不大于 `H` 的条目都已提交。位置是持久化的流内位置，不是源记录的自增 ID、时间戳或 PubSub 通知的到达顺序，**不能互相换算**。
- 游标是服务端生成的不透明字符串。客户端只比较是否相等，不解析、不用间隔判断是否丢消息。

## 衔接与确认

- 初始快照、窗口元数据和位置来自一致的数据视图。服务端**先建立变更监听，再读取**快照与位置，补齐该位置之后的记录，避免快照和增量之间出现缺口。
- 服务端必须保证每批覆盖 `base_cursor` 与 `cursor` 之间的**全部**可见追加记录，不能只靠 PubSub 通知拼出历史。
- 客户端仅在 `generation` 有效、`seq` 恰好是当前值加一、且 `base_cursor` 等于本地游标时应用整批 items；重复包不重复应用；不连续则停止合并并发送 `refresh`。
- `ack` 携带 `{g, s, c}`（generation、累计 seq、对应游标），三者必须与服务端记录一致，否则忽略。`seq` 是订阅内的发送序号，不是数据库位置。
- 每订阅最多一份待确认快照，确认前不发送增量。后续增量可累计确认，但未确认窗口默认最多 200 个批次或 256 KiB（`config :fyrlet, :streams, window_batches:, window_bytes:`），任一超限就停止增量，并发送同一 generation、更高 `seq` 的 `snapshot` 重置视图与位置。旧确认不能覆盖新基线。
- 确认超时（`snapshot_ack_timeout`）关闭订阅，不会为慢客户端无限积压内存；单包大小、发送节流与每连接的总队列同样有界。

## 窗口与历史

- 客户端追加后按 `max_items` 淘汰最旧项，有界快照不会变成无界的本地列表。
- 游标无法续接时（`epoch` 变化、位置超过 `head`、已被 `Fyrlet.Features.Stream.prune/2` 裁掉）一律回退到快照。SDK 不声称补齐了离线期间的历史。
- 已发布条目的更正或删除必须调用 `Fyrlet.Features.Stream.reset/2`（新 `epoch`），让所有旧游标失效。
- 保留：`mix fyrlet.prune` 的定时任务按 `retention_items`（默认 10 000）裁剪每个流。

## 授权与共享读取

- 所有成员看到**相同**的条目，没有按成员裁剪。授权按订阅整体（`authorize/3`），并在**每次发送前**复核会话与授权。
- 同一节点内，`Stream.Reader` 用有界缓存合并相同项目 / 流 / 游标 / 选项的读取，缓存不可用时回退为各自独立读取。缓存里没有授权结论，每个连接仍独立复核。
- 各节点使用自己的缓存，不实现跨节点的全局缓存；跨节点靠 PubSub 传播失效。需要按成员过滤的数据请用私有快照订阅。

## 遥测

- `fyrlet.delta.snapshot_fallback`：回退为快照，`reason` 为 `gap`、`overflow` 或 `refresh`。
- `fyrlet.subscription.append`：每批的字节数与条目数。

本机端到端数据见 [PERFORMANCE.md](PERFORMANCE.md#共享房间与追加流端到端对照2026-11-07)，双节点验证见 [ACCEPTANCE.md](ACCEPTANCE.md#双节点故障切换与持续流量)。
