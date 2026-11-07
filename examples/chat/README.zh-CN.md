# Chat：协作会话

[English](README.md) | 简体中文

独立网页聊天应用，包含 `Room`、`Member`、`Message` 表和迁移。登录用户创建会话，通过随机邀请码加入同项目的会话，每房间最多 50 成员。支持消息、分配负责人、人工接管、关闭与离开；访问均检查项目与成员身份。

## 启动

按 [公共启动步骤](../README.zh-CN.md) 准备 SDK，在当前目录运行：

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## 邀请与演示流程

打开 `http://127.0.0.1:4180/` 并填入项目和用户会话。创建会话后复制邀请码，再运行 `PHX_SERVER=false mix run ../../scripts/example_session.exs bob`，在另一个窗口用 Bob 的会话登录并输入邀请码。加入后可互发消息，点击“刷新成员”更新负责人候选，或由当前用户“人工接管”。关闭后页面禁用发送，离开会话会撤销该用户的房间与消息订阅并清空详情。

## 数据与历史

`chat.room` 是逐成员授权的共享公共投影，不含邀请码；`chat.messages` 使用 append，实时窗口为最近 100 条。`chat.history` 从持久消息表按游标分页，不依赖 append 保留窗口；页面最多显示 500 条，避免无限堆积。`chat.rooms` 列表只含本人加入的会话，邀请码由成员调用 `chat.get` 获取。

## 验证与边界

`mix test` 运行 2 个领域测试；根目录可执行 `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh chat`，覆盖真实共享 / append、邀请、跨项目隔离、历史、接管与离开撤销。`bash scripts/shared_bench.sh` 在独立数据库和 4185/4186 端口比较普通与共享快照、全量消息与 append，结果和限制见 [PERFORMANCE.md](../../docs/zh/PERFORMANCE.md#共享房间与追加流端到端对照2026-11-07)。对照操作 `chat.room.private`、`chat.messages.snapshot`、`chat.rename` 也遵守同样的成员授权。

当前不包含匿名可写聊天、搜索、附件、通知或完整客服后台。源码包可独立安装，尚未发布为注册表产品。
