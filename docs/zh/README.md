# Fyrlet 文档

[English](../README.md) | 简体中文

Fyrlet 是基于 Phoenix 的实时应用框架：在服务端定义业务操作、数据订阅和访问权限，客户端通过统一协议与 SDK 调用业务并获得实时、已授权的数据。项目介绍和快速开始见[根目录 README](../../README.zh-CN.md)。

## 了解产品

| 文档 | 内容 |
| --- | --- |
| [PRODUCT.md](PRODUCT.md) | 产品定位、适用场景、范围与非目标、功能需求、一致性承诺、风险与成功判据 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 基础模型、可选模块、三层结构（核心 / 能力包 / 领域包）、鉴权分层与硬规则 |

## 接入与使用

| 文档 | 内容 |
| --- | --- |
| [TUTORIAL.md](TUTORIAL.md) | 串起 Inbox 定义、生成类型、后端会话接口和浏览器订阅 |
| [INSTALL.md](INSTALL.md) | 安装步骤、必需配置、环境变量、公共接口清单、协议版本与能力、自动化验证覆盖、打包与示例应用 |
| [AUTH.md](AUTH.md) | 身份分层、接入流程、授权与隔离、匿名主体、执行授权、数据保护 |
| [PROTOCOL.md](PROTOCOL.md) | HTTP 与 Socket 协议、订阅与 ACK、增量、能力协商，以及各能力的线上格式 |
| [SDK 总览](../../sdks/README.zh-CN.md)、[TypeScript SDK](../../sdks/typescript/README.zh-CN.md) | 多语言 SDK 约定，TypeScript SDK 的调用、订阅、乐观写入、在线状态 |
| [示例应用](../../examples/README.zh-CN.md) | 公共准备、登录、验证与应用边界 |

## 示例应用

| 文档 | 内容 |
| --- | --- |
| [Inbox](../../examples/inbox/README.zh-CN.md) | 最小 Mix 宿主、私有收件箱、Node CLI 与实时更新 |
| [Notify](../../examples/notify/README.zh-CN.md) | 通知、邮件 Effect 与投递对账 |
| [Flow](../../examples/flow/README.zh-CN.md) | 顺序 HTTP / 等待节点、信号与恢复 |
| [Agent](../../examples/agent/README.zh-CN.md) | 有限工具、owner 审批、拒绝与取消 |
| [Chat](../../examples/chat/README.zh-CN.md) | 邀请、共享房间状态、追加消息与历史 |

## 开发业务

| 文档 | 内容 |
| --- | --- |
| [SERVER.md](SERVER.md) | 注册定义、查询与授权、Observer、事务与失效通知、可选回调、代码组织 |
| [RUNS.md](RUNS.md) | 持久 Run：状态机、等待与信号、取消、租约、外部执行器、执行身份 |
| [EFFECTS.md](EFFECTS.md) | 外部副作用与 Outbox：模型、适配器协议、未知结果的处置 |
| [STREAMS.md](STREAMS.md) | 追加订阅：位置、衔接、窗口、历史与重置 |
| [SHARING.md](SHARING.md) | 共享订阅与声明式数据范围 |
| [PLUGINS.md](PLUGINS.md) | 能力包、插件 API 与一致性套件、领域包 |

## 部署与运维

| 文档 | 内容 |
| --- | --- |
| [DATABASE.md](DATABASE.md) | 表结构设计：约定、约束与索引的作用、清理与保留、宿主表的约定 |
| [OPERATIONS.md](OPERATIONS.md) | 运维命令、数据保留与容量、项目配额、遥测与 Prometheus 指标、双节点部署 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 排查启动、Origin、登录、订阅、冲突和外部 Effect |
| [PERFORMANCE.md](PERFORMANCE.md) | 与 Meteor 的同资源对照，单核剖析，共享房间与追加流的端到端对照 |
| [OPTIMIZATIONS.md](OPTIMIZATIONS.md) | 优化记录：做法、证据、回退的试验与决定不做的方向 |
| [基准测试](../../bench/README.zh-CN.md)、[同等条件规范](../../bench/FAIRNESS.md) | 基准工具与对照的公平性规则 |

## 状态与验收

| 文档 | 内容 |
| --- | --- |
| [STATUS.md](STATUS.md) | 各能力的实现状态，基础验收与能力验收矩阵 |
| [ACCEPTANCE.md](ACCEPTANCE.md) | 验证记录：环境、命令、浏览器与双节点的证据，尚未验收的部分 |
