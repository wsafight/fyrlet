# 真实多主机故障验收

`scripts/multihost_acceptance.mjs` 是一个**显式选择启用的真实部署 Chat 验收器**。它通过真实 HTTP/WebSocket 使用 TypeScript SDK，并调用运维提供的可执行文件读取部署元数据、选择恢复路由、停止实例及重新启动实例。它不启动本机集群、不替换为进程内传输、不模拟网络故障，也不会把同一台机器上的两个端口当作多主机证据。

内置 Chat 工作负载检查：

- 跨主机并发写入幂等，且持久层恰好提交一次；
- 同项目另一用户的读、写和订阅隔离；
- 被选定的受害实例不可用后，同一个路由 SDK 订阅以新 generation 恢复；
- 故障前提交仍保留，其幂等键在幸存实例重放不产生新写入，并能在故障后完成新写入；
- 恢复订阅、幸存实例订阅及持久化演练历史精确收敛为顺序一致的两条预期写入，无空洞、重复、乱序或意外消息；
- 受害实例启动／重入、直连 readiness 恢复，以及其实例／release／schema／数据库元数据再次匹配。

本文及这些文件的新增**不宣称执行过任何真实外部演练**。随工具提供的实际执行仅是离线单元测试。

## 信任与证据边界

报告通过只表示该部署当时通过了所配置的检查，**不独立证明物理拓扑**：

- `physicalHostId`、`expectedInstanceId` 和四个 attestation 布尔值是运维断言。
- 运行器将它们与可信控制钩子返回的允许列出的元数据逐一比对。错误或误导性的钩子会产生错误证据。
- URL、DNS 名、IP、负载均衡行为和不同端口都不能证明实例位于不同物理主机。
- `deployment.database` 是 `postgresql-cluster-a/fyrlet_chat` 之类的非机密规范标签，不是 DSN。标签和钩子元数据一致，不独立证明 PostgreSQL 主库、数据库或持久化语义相同。
- release 和 schema 检查是与运维给出的预期标识做精确比较；运行器不会从应用 URL 推导实际 schema 或 release。
- 运行器源码指纹与部署 release 身份分开记录。真实执行拒绝脏工作区，从该 checkout 重建 SDK 并哈希运行时产物清单，还要求修订、干净状态、源码指纹和运行时摘要在执行前后保持不变。

此演练是受控停止／启动检查，本身不是网络分区、断电、可用区故障、脑裂、容量、24 小时稳定性或生产 SLO 证明，这些结论需要单独设计的证据。路由移动由钩子观测；它是负载均衡自动切换还是运维主动引流，必须写入外部变更记录。

## 外部前置条件

启用执行前必须全部准备好：

1. **运行器主机**
   - Node.js 22 或更新版本。
   - 包含本运行器及适配器的**干净**源码 checkout，并已安装 TypeScript SDK 依赖。私有配置和报告应放在已忽略或仓库外路径，避免弄脏工作区。
   - 本地 Git 和 npm。在导入适配器或发起网络／控制调用前，运行器先记录精确修订和源码指纹，删除 `sdks/typescript/dist`，再执行 `npm --prefix sdks/typescript run build`；脏工作区或干净构建失败都会失败关闭。
   - 生成的 SDK `dist`、已安装的 Phoenix 运行时、配置的工作负载／控制适配器入口模块和控制可执行文件会在执行前哈希，并在结束后复查。自定义适配器的传递依赖仍属于可信运维代码，不会被该摘要递归清点。

2. **至少两个物理主机上的至少两个真实应用实例**
   - 发布运维已在变更／拓扑记录中断言不同物理主机及唯一实例身份。
   - 配置的 victim 和 survivor 位于不同的已断言物理主机。
   - 每个直连节点端点的 `/health`、`/ready` 都成功，且所有直连端点互不相同。
   - 实例使用预期的 Erlang distribution／集群配置及可信分布网络。`start` 钩子只有在应用 readiness 和运维定义的集群重入检查都完成后才能返回成功。

3. **共享持久化与一致部署预期**
   - 所有实例预期使用同一 PostgreSQL 集群／数据库，以及相同且兼容的 release 和已应用 schema／migration 集合。
   - 在 `deployment` 中记录不可变 release 标识、明确的 schema／migration 标识或摘要，以及非机密数据库规范标签。
   - 控制钩子必须从各实例或可信部署控制面读取对应实际值，不能只是回显 JSON 配置。

4. **独立的稳定恢复端点**
   - 支持 WebSocket 的负载均衡可路由到每个配置节点，并提供 `/health`、`/ready`。
   - 它必须不同于每个直连节点端点。
   - 钩子可查询实际当前路由并选择初始 victim。victim 停止后，路由必须移动到配置的 survivor，使同一个 SDK 订阅在幸存实例恢复。
   - 现有客户端连接必须能重连，不能依赖已停止节点上的 sticky-session 状态。

5. **TLS 与网络**
   - 所有非 loopback 直连和路由端点必须 HTTPS。URL 中的凭据、query 和 fragment 会被拒绝。
   - loopback 端点默认拒绝。`execution.allowLoopbackEndpoints=true` 只用于连接真实已断言部署的运维隧道；它仍不证明拓扑，不能用来把本机模拟重新标记成多主机验收。
   - 运行器主机必须能访问所有直连端点、恢复端点，以及控制可执行文件自身依赖的控制面。

6. **专用验收项目与凭据**
   - 使用隔离／可废弃项目并安排故障窗口。演练会创建用户、会话、房间、成员关系和消息，并有意中断一个实例。
   - 项目 ID 和后端 service key 只能通过 `project.projectIdEnv`、`project.serviceKeyEnv` 所命名的环境变量提供。
   - service key 必须有签发和撤销会话权限。它绝不写入 JSON 配置或报告。会话 token、续期会话、房间邀请码和 SDK 错误载荷均不进入报告。

7. **可信运维控制可执行文件**
   - 安装在绝对路径，并事先独立验证其鉴权与目标选择。
   - 它必须按各节点 ID 对应的唯一实例执行，不能从 URL 猜测物理身份。
   - 钩子凭据应放在可执行文件自己的受保护配置或其直接访问的密钥管理器中，绝不放进 `fixedArgs`、适配器路径、节点元数据、报告、命令字符串或继承的凭据环境变量。适配器启动钩子前会移除配置的项目变量及常见疑似凭据环境变量。

## 配置

从 [`deploy/multihost/chat.example.json`](../../deploy/multihost/chat.example.json) 开始，复制到私有本地工作文件并替换所有占位值。仓库内示例明确设置：

```json
"realMultiHostOptIn": false
```

校验是严格的：未知或缺失字段、重复节点 ID／端点／实例身份、少于两个已断言物理主机、victim／survivor 无法解析或位于同一主机、恢复端点等于直连端点、疑似凭据值、DSN、相对钩子路径，以及保留或带凭据的 fixed arguments，都会失败关闭。

适配器路径相对于配置文件解析。示例与内置适配器放在一起；若把配置复制到其他位置，必须保持相同相对布局，或改成正确指向 `executable_control.mjs`、`chat_workload.mjs` 的相对路径。

内置 Chat 不提供 Agent Runs 工作流，因此 `workload.runs` 为 `false`，Runs 记录为可选 `not-run`。若设为 `true`，Runs 成为必需场景，适配器必须声明 `supportsRuns: true` 并实现 `runs()`，否则前置条件失败。不能由 Chat 检查推断任何 Runs 结果。

## 控制钩子契约

内置 `deploy/multihost/executable_control.mjs` 使用 `execFile`、`shell: false`、超时和 64 KiB 输出上限直接调用配置的可执行文件，没有 shell 插值。参数数组为：

```text
[...fixedArgs, ACTION, ...ACTION_ARGUMENTS]
```

节点 ID 必须匹配 `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`，并作为独立参数传递。`fixedArgs` 不能覆盖 `--node` 或 action。钩子接收过滤后的进程环境副本：配置的项目 ID／service key 变量及匹配常见凭据模式的变量名会被移除。这是防止秘密外泄的纵深防御，不是完整的秘密分类器。适配器不记录环境、原始 stdout／stderr 或原始钩子错误消息。

| `fixedArgs` 后的调用 | 必需行为 | stdout 契约 |
| --- | --- | --- |
| `get-route` | 返回稳定恢复端点的实际当前目标，不能只返回期望值。 | `{"nodeId":"node-a"}` |
| `inspect --node NODE` | 从目标实例或可信控制面读取实际实例和部署元数据。 | 下方 JSON |
| `select --node NODE` | 把恢复端点路由到所选配置节点并等待生效。出现歧义或部分失败必须非零退出。 | 忽略并丢弃 |
| `stop --node NODE` | 受控停止或隔离该唯一实例，不能操作 survivor 或无关资源。操作生效后才返回；运行器还会独立要求直连 readiness 消失且路由移动。 | 忽略并丢弃 |
| `start --node NODE` | 启动／解除隔离同一实例，等待应用和运维定义的集群重入，只有可供检查时才零退出。 | 忽略并丢弃 |

`inspect` 必须返回以下字符串字段：

```json
{
  "instanceId": "provider-instance-a",
  "physicalHostId": "physical-host-a",
  "release": "chat@sha256:actual-immutable-release",
  "schema": "migrations-sha256:actual-schema",
  "database": "postgresql-cluster-a/fyrlet_chat"
}
```

额外钩子字段会被忽略，不复制进报告。缺失、格式错误、超大、疑似凭据或有歧义的值会使场景失败。非零退出、超时或无效 JSON 同样失败。运行器只记录 action、配置节点 ID、时间／耗时、通过／失败，以及可用时的数值退出码。

setup 前会读取原始路由。即使场景失败，cleanup 也会尝试启动尚未重入的 victim 并恢复原始路由。钩子必须能安全重试部分完成的 stop／start／select。

## 运行

### 离线配置检查

使用全新报告目录；已有报告绝不覆盖：

```sh
node scripts/multihost_acceptance.mjs \
  --config deploy/multihost/chat.example.json \
  --out .local/readiness/multihost-config-check
```

此模式不读取凭据值、不导入 SDK／适配器、不访问端点、不读取部署元数据，也不调用钩子。有效配置的整体结果为 `not-run`，绝不会是 `passed`，退出码为 **2**；无效配置退出 **1**。`configuration` 场景通过只表示配置有效，不表示多主机验收通过。

### 真实演练（仅供外部运维）

完成所有前置条件、替换占位值、审查钩子，并在私有副本中把 `execution.realMultiHostOptIn` 设为 `true` 后：

```sh
export FYRLET_MULTIHOST_PROJECT_ID='专用项目的项目-ID'
export FYRLET_MULTIHOST_SERVICE_KEY='来自密钥管理器的后端-service-key'

node scripts/multihost_acceptance.mjs \
  --config .local/multihost/chat.real.json \
  --out .local/readiness/multihost-real-001 \
  --execute-real-multihost
```

CLI 标志和 JSON 选择启用二者缺一不可。缺少任意一个，都不会发起真实网络请求或控制动作，结果为未完成。两者都启用后，先检查凭据是否存在，再要求干净 checkout，之后才允许 SDK 重建、产物哈希和适配器导入。以上命令是运维示例，**不是本次仓库变更的执行记录**。

## 状态与退出码

每个场景都有 `passed`、`failed` 或 `not-run` 及原因。必需场景包括配置、运行前置条件、运行器源码、拓扑、setup、幂等、跨用户隔离、路由订阅恢复、故障后写入、节点重入、清理和运行器源码／运行时产物不变。Runs 仅在配置且支持时必需。

| 整体状态 | 含义 | 退出码 |
| --- | --- | ---: |
| `passed` | 所有必需场景通过，且没有已尝试的可选场景失败。未请求／不支持的可选 Runs 可为 `not-run`。 | 0 |
| `failed` | 任一场景失败，包括 cleanup 或源码稳定性失败。 | 1 |
| `not-run` | 没有失败，但至少一个必需场景未完成，或未启用真实执行。 | 2 |

本地预检查绝不会产生整体验收 `passed`。通过状态也不是容量或物理拓扑认证。

## 私有报告与源码元数据

报告目录权限强制为 `0700`；`result.json` 为 `0600`，不覆盖已有报告，并通过私有临时文件替换。配置及各场景后会保存检查点。最终汇总前，中断留下的检查点仍为 `not-run`，不隐含通过。

收到 SIGINT／SIGTERM 后，运行器不再开始新的验收场景，会等待当前有超时的操作，同时仍允许 victim 重入、清理和源码最终检查。中断演练即使清理通过也不能汇总为 `passed`。第二次信号或外部强制终止仍可能直接结束进程，因此任何中断后运维都必须独立检查部署状态。

报告包含：

- 随机 drill ID、时间、场景原因／断言事实和有上限的控制事件；
- 配置 SHA-256 和非机密适配器摘要，而不是复制可能带密配置；
- 运行器 Git 修订、干净／脏状态、源码指纹、Node 版本、最终修订／指纹／状态比对，以及运行时产物首尾 SHA-256 摘要和文件数；
- 预期部署 release／schema／数据库标签、运维 attestation、直连／路由端点及允许列出的观测节点元数据；
- 明确的拓扑边界说明。

递归脱敏覆盖常见凭据键及 token／DSN／Bearer 形式。原始 SDK 响应、token、service key、邀请码、会话 ID、subject、消息内容和钩子输出都不是报告字段。不要把私有报告直接粘贴到公开 issue；脱敏是纵深防御，不代替人工审查。

## 清理与失败处理

运行器只跟踪本次演练创建的用户／会话／资源，不枚举或删除既有房间或用户。尽力清理顺序为：

1. 若 victim 仍停止，启动并验证它；
2. 关闭演练房间并移除演练 owner／colleague 成员关系；
3. 恢复原始恢复路由；
4. 关闭每个 SDK 客户端，并通过稳定端点撤销演练签发的所有会话（包括续期会话）。

会话签发与撤销调用分别有超时和中止信号。失败、超时或格式错误的签发响应都按**签发结果未知**处理，而不是据此认定会话不存在。如果这类调用随后成功，运行器会尝试撤销晚期返回的会话，但 cleanup 仍然失败，绝不宣称所有会话均已撤销。cleanup 还会先停止新签发，再关闭客户端，等待有界的在途签发操作，并撤销每个已知会话 ID。

Chat 没有删除房间操作，因此会保留一个空的已关闭房间。房间标题包含报告中的 drill ID，供运维核对。若房间创建结果未知，或重入／路由／房间／成员关系／会话清理失败，cleanup 和整体验收都会失败。运维必须根据 drill ID 和私有控制面记录检查并调和部署；此时运行器不宣称清理完整。

## 自定义工作负载适配器

自定义适配器是可信本地代码，只在双重真实执行选择启用后加载。import 和工厂创建不应有网络或控制副作用；真实工作应放在场景方法中。模块导出：

```js
export function createWorkload(context) {
  return {
    kind: "chat",                 // 必须等于 workload.kind。
    supportsRuns: false,
    async setup() {},
    async idempotency() {},
    async crossUserIsolation() {},
    async crossHostSubscriptionRecovery() {},
    async writesAfterFailure() {},
    async runs() {},              // 仅配置且支持时调用。
    recoveryRequired() { return false; },
    async rejoin() {},
    async cleanup() {},
  };
}
```

`context` 提供已校验配置、drill ID、`control`、有界 `waitFor`、直连节点 `isReady`、`verifyNode` 和 `createUser`。`createUser({nodeId})` 创建直连 SDK 用户；`createUser({routed:true})` 使用恢复端点；传入先前的 `subject` 会为同一用户再建会话／客户端。客户端和所有会话由运行器集中跟踪。适配器返回值只能包含非机密断言事实，不能包含原始服务响应或凭据。

Runs 适配器必须真正调用配置的 Runs API 并检查所有权／持久性。只声明 `supportsRuns` 而未实现必需方法会失败关闭。

## 离线测试

开发运行器时只运行离线套件：

```sh
node --test scripts/multihost_acceptance.test.mjs
```

测试使用临时文件、打桩会话服务、订阅夹具和打桩控制执行器，覆盖严格校验、规范化 loopback 形式、拓扑元数据、脱敏、状态／退出码、报告权限、双重选择启用、前置条件失败关闭、固定 argv、过滤后的钩子环境、输出脱敏、确定性运行时哈希、精确流／历史收敛、仅限授权错误的订阅拒绝，以及会话超时／刷新／撤销、晚期或畸形签发结果。测试不打开真实端点，也不执行真实控制钩子。
