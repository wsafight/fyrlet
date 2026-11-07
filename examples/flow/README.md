# Flow：顺序流程工作台

独立流程应用，包含 owner 私有的 `Flow` 表、迁移与中文网页。`flow.save` 按用户和流程 ID 保存或更新定义，`flow.saved` 实时列出最近 50 项；`flow.start` 创建 Run，活动流程拒绝重复启动，结束后可再次运行。

按 [公共启动步骤](../README.md) 准备依赖，在当前目录运行：

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

打开 `http://127.0.0.1:4180/` 并连接项目与用户会话。网页默认提供一个等待审批的流程，点击“保存并运行”后查看 Run，发送 `ngo` 信号继续。节点名和信号名会转小写，将不支持的字符替换为 `-` 并加 `n` 前缀，例如原始 `go` 对应协议信号 `ngo`；转换后名称最长 63 个字符。

节点 JSON 支持 `http` 和 `wait`，每个流程 1–20 个节点。HTTP 节点必须提供 URL，`body` 是 JSON 对象的字符串；无效 JSON 在保存或启动前拒绝，不创建运行。调用外部目标前，在本应用配置中设置 `config :fyrlet_effect_http, allowed_hosts: ["api.example.com"]`。明文 HTTP 仅在显式设置 `allow_http: true` 时允许；测试会自行设置本地目标。等待节点包含 `signal`、`timeout_seconds`，可用 `continue_on_timeout` 决定超时后是否继续。

`mix test` 运行 5 个测试，覆盖 HTTP / 等待 / HTTP、超时、拒绝、取消与非法输入。根目录执行 `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh flow` 验证保存更新、真实服务重启和信号后续跑。流程使用核心 Effect 保留未知外部结果，不实现分支、循环、跨节点数据传递、调度触发器或画布。
