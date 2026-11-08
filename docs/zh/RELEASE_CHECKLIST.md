# 发布与部署检查

[English](../RELEASE_CHECKLIST.md) | 简体中文

更新：2026-11-08。本地交付、外部验收和正式发布分别判断。本地通过不表示生产容量或正式发布已验收。

## 可重复的本地验收

```sh
node scripts/acceptance.mjs
node scripts/acceptance.mjs --groups core,client,host,bench,contract,integration,restore,browser
node scripts/acceptance.mjs --groups package,site
```

先安装依赖、启动本地 PostgreSQL 并安装浏览器。入口顺序执行已有检查，失败即停；报告和各步骤日志保存在 `.local/readiness/`。目录为私有权限，日志为 0600，不覆盖已有报告。指纹覆盖 Git 已跟踪及未被忽略的新文件，包含 React、宿主代码和测试，每步之间核对，每步最多 30 分钟。外部检查明确保留为未执行，不发布包、不发送真实邮件。`bench` 分组还运行 staging、多主机与发布辅助逻辑的离线测试，不接触真实端点或执行故障钩子。package 分组只构建四份本地归档并在仓库外消费者目录验证安装。

Core CI 增加压测／验收工具及打包／仓库外安装测试，并支持手动触发。PR 任务检出精确的 PR head SHA，而不是合成 merge 提交。PR #10 的托管检查已通过，并以 `c03e7e72bd8383f876590a6c081ebbfca5ade075` 合并；这只是本分支基线，不证明后续提交。当前分支提交并推送后，仍须要求该精确提交的两组 Elixir／OTP 任务全部通过，并把对应 Core PR 运行交给发布预检查。

## 外部身份服务预检查

```sh
node --env-file-if-exists=examples/inbox-react/.env examples/inbox-react/server/check.mjs
```

先加载 React 宿主部署环境。检查要求显式 HTTPS 源、项目／服务配置、安全 OIDC discovery，以及就绪返回 200。仅输出检查名，不含配置值和错误细节；只请求 discovery 和就绪端点，不发送服务凭据，不签发或撤销会话。成功不等于登录验收通过。

`HOST_INSTANCES` 默认 1。多宿主要求 `HOST_STORE_DATABASE_URL` 与共享的 32 字节 base64url 密钥 `HOST_STORE_KEY`，先运行 `npm --prefix examples/inbox-react run migrate:store`。可选的加密 PostgreSQL 存储提供 state 原子消费、scope 容量、到期、串行续期、退出／签发竞态处理和重启恢复；要求直接／session-affine 连接，不能使用 transaction pooling，见[宿主示例](../../examples/inbox-react/README.zh-CN.md)。本地连接池／进程死亡测试不等于真实 IdP 或生产部署验收。仍需在实际部署跨实例验证登录、续期、退出、换号、issuer 隔离、重启与密钥恢复。IdP 撤销采用**短会话到期边界、不做逐请求 introspection**：宿主登录在 ID token 到期与登录后一小时之间取较早者到期；每个 Fyrlet 会话至多十分钟，且绝不越过宿主到期时间。因此，若没有宿主退出／失效，IdP 侧撤销只保证最迟在记录的宿主到期时间失效（另计入时钟偏差与请求延迟），并非立即生效。staging 验收报告必须声明并验证该边界，不能宣称持续 introspection。

## 本地恢复、长时与发布工具

```sh
bash scripts/host_store.sh
node scripts/restore_smoke.mjs
node scripts/stability.mjs --seconds 30 --clients 4 --sample-ms 5000
node scripts/stability.mjs --seconds 86400 --clients 20
node scripts/release_check.mjs --ci-run RUN_ID
```

`host`、`restore` 验收分组也用于 CI，恢复在集成测试之后执行。恢复工具只接受 loopback 上独立的 `*_integration`、`*_react`、`*_cluster` 数据库，导出一致的只读快照，比较所有 public 表的行数／内容指纹，重复运行两次所选应用的迁移（`--app inbox|notify|flow|agent|chat`，默认 `inbox`），只删除本次新建的随机目标数据库。两种演练 URL 都拒绝查询参数／片段，包括 `?host=...` 重定向。私有 dump 会删除；这不是生产恢复或跨版本升级证明。CI 使用 PostgreSQL 17 Docker 客户端（`RESTORE_DOCKER=1`）；本地需与服务端兼容的 `pg_dump`／`pg_restore`，以及宿主示例已安装的 Node 依赖。

长时包装器使用默认本地 Chat／Agent 集群数据库，端口默认 4250–4254，可用 `--base-port` 修改；保留独立报告、校验源码指纹，分别采样两个数据库的增长、会话／幂等／作业量、积压年龄、未解决 Effect、锁等待，并保留 Chat 节点内存、清理与连接池排队遥测。它拒绝 `CLUSTER_DATABASE_URL` 覆盖。带版本的 `--profile` 可执行显式阈值与采样频率门禁，见[稳定性说明](STABILITY.md)。短演练绝不会标为 24 小时通过，也不隐含生产资源 SLO；多主机故障仍需另一环境。

发布预检查从不发布包。它检查源码是否干净且已提交、产物是否匹配当前源码和校验和、服务端／SDK 版本是否一致、维护者策略／许可证，以及通过 `--ci-run RUN_ID` 提供的精确提交 Core PR CI。CI／API 检查结束后会再次比对源码指纹、`HEAD` 与干净状态；任何 checkout 变化都会使 `source-stability` 变为 unverified 并阻止就绪。Apache-2.0 与发布策略是记录在 `deploy/release-policy.json` 中的维护者决定；文件存在不代表法律或生产批准，外部验收仍需人工复核。提交后应重建分发包：打包会先删除被忽略的 SDK 构建输出再重建，清单记录完整源码指纹、提交和干净／脏状态。

## 真实 staging 与多主机验收工具

```sh
# 仅校验 staging 配置，不访问网络。
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json
# 显式执行真实 discovery／就绪检查或浏览器／SDK 验收。
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json --preflight --confirm DEPLOYMENT_ID
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json --execute --confirm DEPLOYMENT_ID

# 离线多主机配置校验；真实演练需要配置与 CLI 双重启用。
node scripts/multihost_acceptance.mjs --config .local/multihost/chat.real.json
node scripts/multihost_acceptance.mjs --config .local/multihost/chat.real.json --execute-real-multihost
```

从 `deploy/staging/` 或 `deploy/multihost/` 准备私有配置，并遵循 [STAGING.md](STAGING.md) 与 [MULTIHOST.md](MULTIHOST.md)。这些命令只是入口，不表示本分支已执行。真实 staging 需要精确且干净的源码提交、部署产物声明、真实 IdP 账号和 HTTPS 端点；真实故障演练还需要操作方声明的不同物理主机、共享持久化、可信控制可执行文件和隔离项目。本地配置检查、测试 IdP、同机节点和模拟钩子都不能满足这些外部门槛。

## 升级与失败恢复

1. 一起固定服务端、SDK、宿主产物，保留校验和、导出契约、旧配置与旧产物。
2. 备份数据库并恢复到隔离环境，生产变更前确认可启动且 Run／Effect 事实仍存在。
3. 对恢复库执行 `mix fyrlet.migrate` 或 release 迁移入口，验证契约、HTTP／Socket 集成和宿主登录；再次迁移应无新增变更。
4. 以 `/ready` 为流量门槛，观察连接池等待、积压年龄、对账及未知 mutation，验证业务写入和视图确认。
5. 只有预先验证过旧产物与迁移后 schema 的组合才可回退；不能为启动而反向迁移或删除 Run、Effect、回执、幂等事实。若不兼容，停止新写入后向前修复，或按明确恢复点恢复备份并对账外部副作用。

这是操作流程，不表示生产恢复或升级已验证。预发布合并核心基线不提供从早期开发迁移原地升级的路径，相关开发／测试库必须重建。支持版本矩阵只从首个正式发布开始适用，并须在发布前确定。

## 仍需外部环境的验收

| 方向 | 所需证据 |
| --- | --- |
| 远程 CI | 精确到发布提交的两组 Elixir／OTP 通过记录 |
| 身份服务 | 真实 IdP 生命周期和隔离，多宿主时另验共享存储 |
| 负载与故障 | 明确拓扑、负载、SLO，完成速率扫描、混合操作、多主机故障与恢复正确性验证 |
| 稳定性 | 完成长期运行并采样表增长、内存、连接池、积压、清理；短测不等于 24 小时稳定性 |
| 设备与邮件 | 在发布范围涉及相应场景时补实体设备和真实送达、退信、中断验证 |
| 分发 | 已确定 Apache-2.0 与首发 Fyrlet + TypeScript + React 范围；注册表所有者／凭据及真实 Hex／npm 发布仍是外部门槛 |

性能工具见 [bench/fair/README.md](../../bench/fair/README.md)，运行限制和告警见 [OPERATIONS.md](OPERATIONS.md)。实际结果、失败与未验证边界记入 [ACCEPTANCE.md](ACCEPTANCE.md)。
