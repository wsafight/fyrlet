# Fyrlet React 适配包

[English](README.md) | 简体中文

`@fyrlet/react` 是首发正式范围内的独立 React 18.3 / 19 适配包，目前尚未发布；核心 TypeScript SDK 保持框架无关。先构建核心，再构建本包：

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react test
npm --prefix sdks/react run typecheck
npm --prefix sdks/react run test:coverage
```

## 查询 Hook

```tsx
import { FyrletProvider, useFyrletClient, useQuery } from "@fyrlet/react";
import type { AppContract } from "@fyrlet/client/example-contract";

function Inbox() {
  const client = useFyrletClient<AppContract>();
  const recent = useQuery(client, "inbox.recent", { limit: 20 });
  return <ul>{recent.data?.map((item) => <li key={item.id}>{item.text}</li>)}</ul>;
}

function Application({ client }: { client: import("@fyrlet/client").Client<AppContract> }) {
  return <FyrletProvider client={client}><Inbox /></FyrletProvider>;
}
```

`useQuery(client, name, params, options?)` 从 client 契约推导输入与结果。选项包括 `mode: "snapshot" | "append"`、纯函数 `select(data)` 和用于复用相等结果的 `isEqual(left, right)`。append 仍须声明服务端的 `append` 能力。返回值包含 SDK 的订阅状态和 `subscription`；句柄在组件提交后才可用，可作为 mutation 的 `optimistic` 或 `confirm` 目标。句柄生命周期由 Hook 管理，请勿手动调用其 `unsubscribe()`。

同一 client 下，相同查询名、规范化 JSON 参数和模式共用一份订阅，核心 SDK 未启用 `shareSubscriptions` 时也有效。适配包限制每个 client 最多 100 个活跃查询，参数沿用核心的 64 KiB 上限。组件独立释放引用，最后一个释放后立即退订并删除条目，不保留无引用缓存。混用 Hook 与直接 SDK 订阅时，可同时启用核心查询复用。

`useFyrletClient<Contract>()` 读取 Provider；也可以直接向 `useQuery` 传入 client，不使用 Provider。Provider 不创建或关闭 client。应用负责在退出和身份切换时关闭旧实例，并为新身份创建实例。Presence 继续通过独立的 SDK 句柄管理。

## SSR 与生命周期

适配包使用 `useSyncExternalStore`。渲染阶段不创建订阅，放弃或挂起的渲染也不会占用资源。无变化时 snapshot 引用稳定；Strict Mode、参数切换和卸载均释放对应引用。

服务端渲染与首次水合都采用确定的空 `connecting` 状态，没有私有数据和活跃订阅；首版不提供预加载服务端数据的 API。服务端按请求创建 client，浏览器按登录身份创建 client，禁止跨用户复用服务端实例。查询条目只在活跃期间保留，并按 client 对象隔离。

[带 OIDC 登录的 随记](../../examples/inbox-react/README.zh-CN.md) 展示相同查询的两个消费者、参数切换、乐观写入、权威视图确认、可选重试和账号清理。`bash scripts/package.sh` 会生成 client 与 React 两份 tgz；在仓库外使用时，将两份包与 React 一起安装。TypeScript 消费者还必须安装 `@types/react` 与 `@types/phoenix`，以提供打包类型声明引用的 React 和 Phoenix 类型。
