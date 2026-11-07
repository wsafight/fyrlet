# Fyrlet SDKs

[English](README.md) | 简体中文

`sdks/` 收纳 Fyrlet 的客户端 SDK，按语言建立子目录，每个 SDK 独立构建、测试和发布。[TypeScript SDK](typescript/README.zh-CN.md)（本地包名 `@fyrlet/client`）最完整；[Python](python/README.zh-CN.md)（`fyrlet`）、[Go](go/README.zh-CN.md)（`github.com/wsafight/fyrlet/sdks/go`）、[Swift](swift/README.zh-CN.md)（`Fyrlet`）、[.NET](dotnet/README.zh-CN.md)（`Fyrlet`）、[Rust](rust/README.zh-CN.md)（`fyrlet`）、[Java](java/README.zh-CN.md)（`com.fyrlet:fyrlet`）和 [Kotlin](kotlin/README.zh-CN.md)（`com.fyrlet:fyrlet-kotlin`）SDK 覆盖会话交换、带幂等与恢复的业务调用和可恢复订阅，Run、append、presence、乐观写入和 Socket RPC 暂时只有 TypeScript 提供。所有包均未发布，npm scope 可用性尚未确认。

## 目录约定

```text
sdks/
  README.md
  typescript/
    src/
    scripts/
    examples/
    test/
    package.json
  python/        pyproject.toml、src/、tests/、examples/
  go/            go.mod、*.go、examples/
  swift/         Package.swift、Sources/、Tests/、Examples/
  dotnet/        Fyrlet.sln、src/、tests/、examples/
  rust/          Cargo.toml、src/、tests/、examples/
  java/          pom.xml、src/、examples/
  kotlin/        pom.xml、src/、examples/
```

未来实际实现某种语言时，再增加 `dart/`、`flutter/` 等目录。当前不创建空 SDK，也不承诺这些语言的交付顺序。每个语言目录拥有自己的依赖、版本和包管理方式，服务端继续位于仓库根目录。

React 适配基于 TypeScript 核心；需要独立发布时可在 `typescript/packages/` 下拆包。React Native 同样复用 TypeScript 核心，并补充前后台、网络恢复与令牌存储适配。Flutter、原生 iOS 和原生 Android 的 SDK 则分别在相应语言目录实现。

## 共享约定

各 SDK 共同遵守 [业务与订阅协议](../docs/zh/PROTOCOL.md)，并消费同一份 [业务契约](../priv/contract.json)：

- HTTP 操作、身份校验、会话交换与撤销使用同一组服务端接口。服务密钥只用于受信后端；客户端使用短期用户令牌。
- 实时订阅遵守 Phoenix Channels 传输和 Fyrlet 应用协议，包括完整快照、确认、generation、seq、重新订阅和终止错误。
- 写入遵守相同的幂等键、冲突和重试语义；未知提交结果不能被 SDK 当成确定失败。
- SDK 绑定项目与用户，账号切换、会话撤销和终止错误必须正确释放资源并清理私有数据。
- API 形式符合各自语言习惯，语义保持一致。业务类型从契约生成或映射，不逐语言维护另一份业务定义。

协议、业务契约与 SDK 包分别管理版本。协议兼容性由 `protocol_version` 和契约方言判断，包版本可独立演进；已发布 SDK 的兼容范围需要在各自文档中明确记录。

## 新 SDK 的验收

新增 SDK 时，应为它提供安装说明、示例、单元测试以及连接真实 Fyrlet 服务的集成测试。至少验证操作与错误、幂等重试、鉴权隔离、快照确认、断线恢复、令牌更新与撤销、旧消息丢弃、取消订阅和关闭后的资源释放。

新增第二种语言前，计划从现有测试中整理可跨语言复用的协议输入输出样例和验收场景。各语言运行自己的测试，不要求共享同一套测试框架。

## 近期顺序

先完善 TypeScript 核心的浏览器验证和契约生成，再根据实际界面开发需要补充 React 适配、共享订阅和 React Native 生命周期验证。其他语言由真实应用需求驱动，避免同时维护多个未验证的客户端。
