# Notify：通知中心

[English](README.md) | 简体中文

独立通知应用，包含 `Notification` 模型、迁移、中文网页与真实 SDK。`notify.send` 先用受管提交保存站内通知，再通过邮件 Effect 派发；`notify.inbox` 按项目和用户隔离，投递完成、失败、取消与运行状态实时更新。同一用户的 `event_id` 去重，不同用户可以使用相同事件 ID。

## 启动

按 [公共启动步骤](../README.zh-CN.md) 准备 SDK，在当前目录迁移并签发开发会话。发送真实邮件时配置：

```sh
export RESEND_API_KEY='你的 Resend API key'
export MAIL_FROM='已验证域名的发件地址'
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## 演示与投递状态

打开 `http://127.0.0.1:4180/`，输入项目 ID 与用户令牌，填写收件人、标题和正文，查看运行及投递状态。密钥只用于服务端适配器。默认供应商是 `FyrletEffectEmail.Resend`，以稳定幂等键调用发送接口，再查询供应商 ID 对账；`accepted` 表示受理，`delivered` 才表示供应商报告投递。超时或无法确认的结果保留为 `unknown`。

## 验证与边界

`mix test` 运行 8 个领域测试；仓库根目录可执行 `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh notify`，验证站内实时更新、邮件适配器和接受后对账；`bash scripts/browser.sh notify` 另外验证桌面和两种移动视口。Email 包另有 12 个测试，含本地 HTTP 供应商协议验证。

真实投递工具为 `bash scripts/mail_live.sh --check`（仅检查配置）及 `bash scripts/mail_live.sh`（实际发一封邮件）。必须显式设置 `RESEND_API_KEY`、已验证的 `MAIL_FROM` 与 `MAIL_TO`。工具通过真实 Notify Run 提交，重复请求使用同一幂等键，等待供应商查询确认投递与站内状态完成，报告写到 `.local/mail-live/result.json`；超时后先检查报告里的 Run，避免盲目再次发送。目前缺少这些配置，尚未验证真实投递和退信。多渠道、模板与用户偏好未实现。
