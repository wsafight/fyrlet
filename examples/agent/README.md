# Agent：有限工具审批助手

独立审批应用，包含 `Task` 模型、迁移与中文网页。`agent.start` 按 prepare → approval → finish 顺序执行，工具结果与任务记录受管提交，owner 必须明确批准或拒绝，超时失败。`agent.tasks` 实时列出本人任务，并反映取消或失败状态。

按 [公共启动步骤](../README.md) 准备依赖，在当前目录运行：

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

打开 `http://127.0.0.1:4180/`，输入项目与用户会话。填写文本，选择 `word_count`（按空白统计词数及字符数）或 `excerpt`（截取前 160 个字符），创建任务后在详情中批准或拒绝；等待期间也可取消。其他用户不能查看、批准或取消这份任务，审批信号 schema 要求显式布尔决策。

`mix test` 运行 2 个领域测试；根目录执行 `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh agent`，验证有限工具白名单、owner 审批与拒绝结果持久化。仓库外安装验收也运行本应用测试。目前没有 LLM、模型调用 Effect、RAG 或任意工具执行，应用用于验证持久 Run 和人工介入。
