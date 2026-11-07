export type Lang = "en" | "zh";
export const repo = process.env.SITE_REPO ?? "wsafight/fyrlet";
export const branch = process.env.SITE_BRANCH ?? "main";
export const base = (process.env.SITE_BASE ?? "/fyrlet").replace(/\/$/, "");
export const gh = `https://github.com/${repo}`;
export const href = (lang: Lang, path = "") => `${base}${lang === "zh" ? "/zh" : ""}${path}` || "/";

export const groups: { id: string; en: string; zh: string; slugs: string[] }[] = [
  { id: "start", en: "Start here", zh: "入门", slugs: ["product", "roadmap", "tutorial", "install", "status"] },
  { id: "build", en: "Build", zh: "开发", slugs: ["server", "sdk", "sdk-overview", "protocol", "auth", "database"] },
  { id: "examples", en: "Examples", zh: "示例应用", slugs: ["examples", "example-inbox", "example-notify", "example-flow", "example-agent", "example-chat"] },
  { id: "caps", en: "Capabilities", zh: "能力", slugs: ["runs", "effects", "streams", "sharing", "plugins"] },
  { id: "ops", en: "Run & verify", zh: "运维与验证", slugs: ["operations", "troubleshooting", "architecture", "acceptance", "performance", "optimizations"] },
];

export const desc: Record<string, { en: string; zh: string }> = {
  product: { en: "What Fyrlet is, who it is for, and the product model.", zh: "Fyrlet 是什么、适合谁、产品模型。" },
  roadmap: { en: "Planned milestones, priorities, dependencies and completion criteria.", zh: "后续阶段、优先级、依赖与完成条件。" },
  install: { en: "Install the server and SDK, and the public interface.", zh: "安装服务端与 SDK，以及对外接口。" },
  tutorial: { en: "Connect a business definition, session endpoint and browser client.", zh: "串起业务定义、会话接口与浏览器客户端。" },
  sdk: { en: "Typed calls, subscriptions, recovery, optimistic writes and presence.", zh: "类型化调用、订阅、恢复、乐观写入与在线状态。" },
  "sdk-overview": { en: "SDK layout, shared protocol and requirements for new languages.", zh: "SDK 目录、共享协议与新增语言的验收要求。" },
  examples: { en: "Start the example applications and understand their boundaries.", zh: "启动示例应用，了解演示流程与功能边界。" },
  "example-inbox": { en: "A minimal host application with a private live inbox.", zh: "带私有实时收件箱的最小宿主应用。" },
  "example-notify": { en: "Live notifications, email Effects and delivery reconciliation.", zh: "实时通知、邮件 Effect 与投递对账。" },
  "example-flow": { en: "Sequential HTTP and wait nodes with durable Runs.", zh: "用持久 Run 执行顺序 HTTP 与等待节点。" },
  "example-agent": { en: "Bounded tools, explicit approval and durable task state.", zh: "有限工具、显式审批与持久任务状态。" },
  "example-chat": { en: "Invitations, shared room state, append messages and history.", zh: "邀请、共享房间状态、追加消息与历史记录。" },
  troubleshooting: { en: "Diagnose connection, authorization, recovery and migration failures.", zh: "排查连接、鉴权、恢复与迁移问题。" },
  status: { en: "Implementation status and the acceptance matrix.", zh: "实现状态与验收矩阵。" },
  server: { en: "Define operations, subscriptions and permissions in Elixir.", zh: "用 Elixir 定义操作、订阅与权限。" },
  protocol: { en: "The business and subscription protocol, versions and capabilities.", zh: "业务与订阅协议、版本与能力协商。" },
  auth: { en: "Authentication and project/user isolation.", zh: "认证与项目、用户隔离。" },
  database: { en: "Schema, migrations, retention and data model.", zh: "表结构、迁移、保留策略与数据模型。" },
  runs: { en: "Durable long-running work with external executors.", zh: "可持久化的长任务与外部执行器。" },
  effects: { en: "Effects and the transactional outbox.", zh: "Effect 与事务性 Outbox。" },
  streams: { en: "Append-only subscriptions for logs and messages.", zh: "面向日志与消息的追加订阅。" },
  sharing: { en: "Data scope and shared subscriptions.", zh: "数据范围与共享订阅。" },
  plugins: { en: "Capability packages, plugins and domain packages.", zh: "能力包、插件与领域包。" },
  operations: { en: "Operating the service and sizing capacity.", zh: "服务运维与容量规划。" },
  architecture: { en: "Architecture and extension principles.", zh: "架构与扩展原则。" },
  acceptance: { en: "The local acceptance record.", zh: "本地验收记录。" },
  performance: { en: "Same-resource performance comparison.", zh: "同资源性能对比。" },
  optimizations: { en: "Optimization log and what was not worth doing.", zh: "优化记录与不值得做的项。" },
};

export const ui = {
  en: {
    docs: "Docs", features: "Features", examples: "Examples", mainNav: "Main navigation", footerNav: "Footer navigation", github: "GitHub", other: "中文", skip: "Skip to content", onThis: "On this page",
    menu: "Documentation menu", back: "← Back to home", rights: "Fyrlet — realtime sync framework on Phoenix.",
  },
  zh: {
    docs: "文档", features: "功能", examples: "示例", mainNav: "主导航", footerNav: "页脚导航", github: "GitHub", other: "English", skip: "跳到正文", onThis: "本页目录",
    menu: "文档目录", back: "← 返回首页", rights: "Fyrlet — 基于 Phoenix 的实时同步框架。",
  },
};
