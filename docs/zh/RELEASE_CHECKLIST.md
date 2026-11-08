# 发布与部署检查

[English](../RELEASE_CHECKLIST.md) | 简体中文

更新：2026-11-08。本地交付、外部验收和正式发布分别判断。本地通过不表示生产容量或正式发布已验收。

## 可重复的本地验收

```sh
node scripts/acceptance.mjs
node scripts/acceptance.mjs --groups core,client,host,bench,contract,integration,restore,browser
node scripts/acceptance.mjs --groups package,site
```

先安装依赖、启动本地 PostgreSQL 并安装浏览器。入口顺序执行已有检查，失败即停；报告和各步骤日志保存在 `.local/readiness/`。目录为私有权限，日志为 0600，不覆盖已有报告。指纹覆盖 Git 已跟踪及未被忽略的新文件，包含 React、宿主代码和测试，每步之间核对，每步最多 30 分钟。外部检查明确保留为未执行，不发布包、不发送真实邮件。package 分组只构建本地归档并在仓库外消费者目录验证安装。

Core CI 增加压测／验收工具测试，并支持手动触发。2026-11-08 上游 main 运行 `42451376341`，提交 `7f97e40005b901fa11fd16ca4020210af94f6862`，因两项批量会话测试收到了无关后台遥测事件而失败。本分支隔离 worker 测量，并在测试进程内检查直接查询；仍需新的远程运行确认。此前 PR 的成功运行 `42450925475` 不能证明 main 已通过。

## 外部身份服务预检查

```sh
node --env-file-if-exists=examples/inbox-react/.env examples/inbox-react/server/check.mjs
```

先加载 React 宿主部署环境。检查要求显式 HTTPS 源、项目／服务配置、安全 OIDC discovery，以及就绪返回 200。仅输出检查名，不含配置值和错误细节；只请求 discovery 和就绪端点，不发送服务凭据，不签发或撤销会话。成功不等于登录验收通过。

`HOST_INSTANCES` 默认 1。多宿主要求 `HOST_STORE_DATABASE_URL` 与共享的 32 字节 base64url 密钥 `HOST_STORE_KEY`，先运行 `npm --prefix examples/inbox-react run migrate:store`。可选的加密 PostgreSQL 存储提供 state 原子消费、scope 容量、到期、串行续期、退出／签发竞态处理和重启恢复；要求直接／session-affine 连接，不能使用 transaction pooling，见[宿主示例](../../examples/inbox-react/README.zh-CN.md)。本地连接池／进程死亡测试不等于真实 IdP 或生产部署验收。仍需在实际部署跨实例验证登录、续期、退出、换号、issuer 隔离、重启与密钥恢复；IdP 侧撤销仍需明确宿主失效策略或到期边界。

## 本地恢复、长时与发布工具

```sh
bash scripts/host_store.sh
node scripts/restore_smoke.mjs
node scripts/stability.mjs --seconds 30 --clients 4 --sample-ms 5000
node scripts/stability.mjs --seconds 86400 --clients 20
node scripts/release_check.mjs
```

`host`、`restore` 验收分组也用于 CI，恢复在集成测试之后执行。恢复工具只接受 loopback 上独立的 `*_integration`、`*_react`、`*_cluster` 数据库，导出一致的只读快照，比较所有 public 表的行数／内容指纹，重复运行两次所选应用的迁移（`--app inbox|notify|flow|agent|chat`，默认 `inbox`），只删除本次新建的随机目标数据库。两种演练 URL 都拒绝查询参数／片段，包括 `?host=...` 重定向。私有 dump 会删除；这不是生产恢复或跨版本升级证明。CI 使用 PostgreSQL 17 Docker 客户端（`RESTORE_DOCKER=1`）；本地需与服务端兼容的 `pg_dump`／`pg_restore`，以及宿主示例已安装的 Node 依赖。

长时包装器使用默认本地 Chat／Agent 集群数据库，端口默认 4250–4254，可用 `--base-port` 修改；保留独立报告、校验源码指纹，采样数据库增长、会话／幂等／作业量、积压年龄、未解决 Effect、锁等待，并在集群样本中保留节点内存、清理与连接池排队遥测。它拒绝 `CLUSTER_DATABASE_URL` 覆盖。短演练绝不会标为 24 小时通过，也不隐含生产资源 SLO；多主机故障仍需另一环境。

发布预检查从不发布包。它检查源码是否干净且已提交、产物是否匹配当前源码和校验和、服务端／SDK 版本是否一致、维护者策略／许可证，以及可选的精确提交 CI（`--ci-run RUN_ID`）。不自动选择许可证或策略。经维护者决定后才提供 `deploy/release-policy.json`（或 `--policy FILE`）：`maintainerApproved: true`、根目录名为 `LICENSE` 或 `LICENSE.<suffix>` 的 `licenseFile`，以及非空字符串 `license`、`compatibility`、`deprecation`、`registries`。文件存在不代表法律或生产批准，外部验收仍需人工复核。提交后应重建分发包，清单会记录完整源码指纹、提交和干净／脏状态。

## 升级与失败恢复

1. 一起固定服务端、SDK、宿主产物，保留校验和、导出契约、旧配置与旧产物。
2. 备份数据库并恢复到隔离环境，生产变更前确认可启动且 Run／Effect 事实仍存在。
3. 对恢复库执行 `mix fyrlet.migrate` 或 release 迁移入口，验证契约、HTTP／Socket 集成和宿主登录；再次迁移应无新增变更。
4. 以 `/ready` 为流量门槛，观察连接池等待、积压年龄、对账及未知 mutation，验证业务写入和视图确认。
5. 只有预先验证过旧产物与迁移后 schema 的组合才可回退；不能为启动而反向迁移或删除 Run、Effect、回执、幂等事实。若不兼容，停止新写入后向前修复，或按明确恢复点恢复备份并对账外部副作用。

这是操作流程，不表示生产恢复或升级已验证。当前没有声明支持版本矩阵或兼容性承诺，正式发布前须按发布范围确定。

## 仍需外部环境的验收

| 方向 | 所需证据 |
| --- | --- |
| 远程 CI | 精确到发布提交的两组 Elixir／OTP 通过记录 |
| 身份服务 | 真实 IdP 生命周期和隔离，多宿主时另验共享存储 |
| 负载与故障 | 明确拓扑、负载、SLO，完成速率扫描、混合操作、多主机故障与恢复正确性验证 |
| 稳定性 | 完成长期运行并采样表增长、内存、连接池、积压、清理；短测不等于 24 小时稳定性 |
| 设备与邮件 | 在发布范围涉及相应场景时补实体设备和真实送达、退信、中断验证 |
| 分发 | 维护者确定许可证、注册表、版本和弃用规则；Hex／npm 正式发布继续暂缓 |

性能工具见 [bench/fair/README.md](../../bench/fair/README.md)，运行限制和告警见 [OPERATIONS.md](OPERATIONS.md)。实际结果、失败与未验证边界记入 [ACCEPTANCE.md](ACCEPTANCE.md)。
