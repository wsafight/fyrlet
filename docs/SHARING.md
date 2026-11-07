# 数据范围与共享订阅

默认情况下每个 Actor 独立查询、独立授权、独立收到快照。本文有两个相互独立的可选机制：

- **共享订阅范围**：成员看到的结果逐字节相同时，合并相同的查询与序列化。
- **声明式数据范围**：用受管查询构造器减少遗漏过滤。

另有一种更窄的共享：契约里声明 `"shared": true` 的订阅，只在**同一 session 的多设备**之间共用一个 Observer，见 [SERVER.md](SERVER.md#observer-与共享边界)。它与下文的 `sharing: "identical"` 互斥。

## 共享订阅范围

现状：每个 Actor 独立查询、生成并接收快照。共享优化的目标是合并相同查询与正文序列化；逐成员授权和网络发送仍然存在。

共享订阅是**显式声明**的，且仅限“成员结果相同”的场景：

```elixir
# 契约中的订阅声明（"identical" 与 "shared" 互斥）
"room.recent" => %{"sharing" => "identical", "input" => ..., "output" => ...}

# 定义需实现：
def shared_query(name, %{project_id: _, scope: _}, params)  # 不接收 Actor
def membership(name, actor, params)                          # :member | :not_member
def policy_version(name)                                     # 可选：授权策略变化时递增
```

缓存键为 项目、定义模块、订阅名、规范化参数、Scope、投影版本（`definition_version/1`）、授权策略版本（`policy_version/1`）。共享的 Observer 不持有 Actor。每个成员在**加入时**、**每次发送数据前**、**定时对账时**以及收到 `:membership_changed` 消息时，都重新执行会话复核、`authorize/3` 与 `membership/3`；未通过者立即以 `FORBIDDEN` 终止订阅，缓存命中不赋予任何读取权限。成员关系变化后，向对应 Observer 发送 `:membership_changed` 可立即复核，否则最迟在下一次对账或下一次发送时被发现。遥测 `fyrlet.scope.shared` 报告成员数。`sharing: "masked"` 未提供。

默认 `sharing: :private`。启用 `:identical` 时必须使用独立的 `shared_query/3` 公共投影路径，而不是缓存某个成员的私有查询结果：

- 查询仅接收订阅名、规范化参数与受信的 Scope 上下文，不接收个人 Actor；同一共享键的结果对所有接收者逐字节相同；
- 成员关系由 `membership/3` 回调给出：`:member | :not_member`；
- 结果不包含成员私有字段；公共字段白名单与项目过滤由领域定义明确提供；
- 共享是可信业务声明，不是框架对任意业务逻辑的自动等价证明。一致性测试覆盖成员差异和越权反例。

此处公共投影指 Scope 内成员共同可见的结果；匿名访问仍由独立入口与授权策略决定。

执行方式：

1. 缓存键至少包含 project、订阅名、规范化参数、Scope、数据版本、投影版本与授权策略版本；同键并发查询合并，缓存容量与生命周期有界。
2. 发送前逐成员执行会话复核、`authorize` 和 `membership/3`；未通过者终止订阅。共享命中不赋予读取权限，也不跳过周期复核。
3. 成员、权限或数据变化均触发失效；周期检查补偿遗漏通知。成员移除与缓存命中竞争必须有验收用例。

不提供按成员裁剪共享正文的 `sharing: :masked`。存在成员级差异时使用私有订阅。容量结论分别报告数据库查询数、序列化次数、成员检查数和网络字节；不宣称发送份数随 Scope 而非成员数增长。

## 声明式数据范围

该能力先作为受管数据访问工具交付，减少遗漏过滤；不承诺约束进程内任意 Repo/SQL 调用。新增可选策略回调：

```elixir
@callback data_scope(action :: :read | :write, actor, input) ::
            {:ok, keyword()} | :unsupported
```

配合框架提供的查询构造器：

```elixir
Fyrlet.Scope.apply(query, actor, module, action, input)
```

保证边界：

1. 受管路径必须注入不可由输入覆盖的 project 约束，以及策略声明的 subject 或成员约束。策略返回 `:unsupported` 时拒绝该受管操作，不能退回无过滤查询。
2. 受管读取、更新、删除与插入分别定义约束；项目归属字段由可信上下文写入。只支持可验证的查询形态，不支持的 Join、原始 SQL 或查询片段显式拒绝。
3. 直接使用 `Repo` 的路径不受约束，业务仍负责数据库过滤。仅调用 `Scope.apply` 的辅助函数不能被描述为所有数据库访问都已强制隔离。
4. 需要数据库级租户隔离时，另行设计 RLS、数据库角色与连接上下文；未交付这些机制前，不使用“任意查询无法越权”的承诺。
