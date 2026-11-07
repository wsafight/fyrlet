# Inbox：最小实时收件箱

[English](README.md) | 简体中文

独立 Mix 宿主应用，通过路径依赖接入 Fyrlet。`InboxExample.Inbox` 定义收件箱的契约、授权、读写和订阅，`Item` 模型与迁移属于宿主。通过 Node CLI 观察同一用户的实时更新和不同用户的数据隔离。

## 启动服务

先按[示例总览](../README.zh-CN.md)在仓库根目录准备 PostgreSQL、Elixir 依赖和 SDK，再运行：

```sh
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/inbox-project.json "Inbox demo"
PHX_SERVER=true PORT=4180 mix phx.server
```

默认数据库是本机 55432 上的 `inbox_example_dev`。若使用 `DATABASE_URL`，迁移、项目创建和服务必须指向同一个数据库。项目文件包含服务密钥，只供可信本地程序使用。

## 验证实时更新与隔离

另开终端，在仓库根目录运行：

```sh
FYRLET_ENDPOINT=http://127.0.0.1:4180 FYRLET_PROJECT_FILE=.local/inbox-project.json node sdks/typescript/examples/inbox.mjs
```

输入文字并回车即可调用 `inbox.add`，实时窗口由 `inbox.recent` 提供。用相同命令打开第二个终端，两边会看到同一用户的更新；输入 `/quit` 退出。

在另一个终端使用不同主体：

```sh
FYRLET_SUBJECT=bob FYRLET_ENDPOINT=http://127.0.0.1:4180 FYRLET_PROJECT_FILE=.local/inbox-project.json node sdks/typescript/examples/inbox.mjs
```

Bob 的收件箱与默认用户隔离。独立签发的会话仍可以接收相同主体的数据，但 `shared: true` 的同会话优化只有在复用同一会话时才适用，见[共享订阅](../../docs/zh/SHARING.md)。

## 业务定义与类型

业务代码在 [`lib/inbox_example/inbox.ex`](lib/inbox_example/inbox.ex)，注册和运行参数在 [`config/config.exs`](config/config.exs)。私有查询通过 Actor 的 project 与 subject 约束 SQL；更新通过 `expected_version` 检查冲突。

完整的定义注册、契约导出、类型生成、后端会话接口与浏览器接入见[接入教程](../../docs/zh/TUTORIAL.md)。

## 测试与边界

在本目录运行 `mix test`，测试使用 SQL Sandbox 与手动 Oban。Node 交互用于本地验证；浏览器页面见 [Chat](../chat/README.zh-CN.md) 等领域应用。生产登录、TLS、网关限流和备份由宿主提供，详见[安装](../../docs/zh/INSTALL.md)与[鉴权](../../docs/zh/AUTH.md)。
