import { StrictMode, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { createRoot } from "react-dom/client";
import { ApiError, OutcomeUnknownError } from "@fyrlet/client";
import type { Mutation, MutationState } from "@fyrlet/client";
import type { AppContract } from "@fyrlet/client/example-contract";
import { FyrletProvider, useFyrletClient, useQuery } from "@fyrlet/react";
import { connect, hostConfig } from "./session.js";
import type { Connection, HostConfig } from "./session.js";
import "./style.css";

type Item = AppContract["operations"]["inbox.add"]["output"];
type Params = AppContract["subscriptions"]["inbox.recent"]["input"];
const countItems = (items: Item[]) => items.length;
const statusText = { connecting: "正在连接", recovering: "正在重新连接", ready: "实时同步中", error: "连接中断", closed: "连接已关闭" };

function InboxCount({ params }: { params: Params }) {
  const client = useFyrletClient<AppContract>();
  const state = useQuery(client, "inbox.recent", params, { select: countItems });
  return <span className="count" aria-label="当前记录数量">{state.data ?? "—"}</span>;
}

function Inbox({ user, signOut }: { user: NonNullable<HostConfig["user"]>; signOut: () => Promise<void> }) {
  const client = useFyrletClient<AppContract>();
  const [limit, setLimit] = useState(20);
  const [archived, setArchived] = useState(false);
  const params = { limit, include_archived: archived };
  const query = useQuery(client, "inbox.recent", params);
  const [text, setText] = useState("");
  const [retry, setRetry] = useState(false);
  const [task, setTask] = useState<Mutation<Item>>();
  const [outcome, setOutcome] = useState<MutationState<Item>>();
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => task?.onChange(setOutcome), [task]);

  function describe(error: unknown) {
    if (error instanceof OutcomeUnknownError) return "保存结果暂未确认。可查询本次结果，避免重复添加。";
    if (error instanceof ApiError && error.code === "CONFLICT") return "内容已在其他窗口更新，请刷新后重试。";
    return error instanceof Error ? error.message : "操作未完成，请稍后重试。";
  }

  async function add(event: FormEvent) {
    event.preventDefault();
    if (!text.trim() || !query.subscription || busy) return;
    const value = text.trim();
    const timestamp = new Date().toISOString();
    const local: Item = { id: crypto.randomUUID(), text: value, content_type: "text", archived: false, version: 1, inserted_at: timestamp, updated_at: timestamp };
    setBusy(true);
    setMessage("正在保存…");
    try {
      const mutation = client.mutate("inbox.add", { text: value }, {
        retry: retry ? { maxAttempts: 3, maxElapsedMs: 15_000 } : false,
        optimistic: [{ subscription: query.subscription, update: (items: Item[]) => [local, ...items.filter((item) => item.id !== local.id)].slice(0, limit) }],
      });
      setTask(mutation);
      await mutation.result;
      setText("");
      setMessage("已保存，正在同步列表…");
      const views = await mutation.views;
      setMessage(views.every((view) => view.status === "confirmed") ? "已保存并同步" : "已保存。列表尚未确认更新，可点击刷新。");
    } catch (error) { setMessage(describe(error)); }
    finally { setBusy(false); }
  }

  async function recover() {
    if (!task || busy) return;
    setBusy(true);
    try {
      const result = await task.recover();
      if (result.status === "unknown") setMessage("仍未查到保存回执。请稍后查询，暂勿重复添加。");
      else {
        setText("");
        setMessage("已查到保存结果，正在刷新列表…");
        await query.subscription?.confirm();
        setMessage("已保存并同步");
      }
    } catch (error) { setMessage(describe(error)); }
    finally { setBusy(false); }
  }

  async function archive(item: Item) {
    try {
      await client.call("inbox.archive", { id: item.id, expected_version: item.version, archived: !item.archived }, {
        ...(query.subscription ? { confirm: [query.subscription] } : {}),
      });
      setMessage(item.archived ? "已取消归档" : "已归档");
    } catch (error) { setMessage(describe(error)); }
  }

  async function refresh() {
    try { await query.subscription?.confirm(); setMessage("列表已更新"); }
    catch (error) { setMessage(describe(error)); }
  }

  return <div className="workspace">
    <aside className="sidebar">
      <a className="brand" href="/" aria-label="Fyrlet 随记"><span className="brand-mark">f</span> Fyrlet</a>
      <div className="folder"><span aria-hidden="true">▤</span> 我的随记 <InboxCount params={params} /></div>
      <p className="sidebar-note">随手记下，稍后处理。<br />你的内容会在登录的窗口间同步。</p>
      <div className="account"><span className="avatar">{user.name.slice(0, 1)}</span><div><strong>{user.name}</strong><button onClick={() => void signOut()}>退出 / 切换账号</button></div></div>
    </aside>
    <main className="main">
      <header className="page-header"><div><h1>随记</h1><p>给下一步留个位置。</p></div><span className={`connection ${query.status}`} role="status"><i />{statusText[query.status]}</span></header>
      <form className="composer" onSubmit={(event) => void add(event)}>
        <label htmlFor="new-message">有什么需要记下来？</label>
        <textarea id="new-message" placeholder="记下此刻的想法…" maxLength={16384} value={text} onChange={(event) => setText(event.target.value)} disabled={busy} />
        <div className="composer-footer"><label className="check"><input type="checkbox" checked={retry} onChange={(event) => setRetry(event.target.checked)} />自动恢复短暂失败</label><button className="primary" disabled={busy || !text.trim() || query.status !== "ready"}>{busy ? "正在保存…" : "记下来"}</button></div>
      </form>
      <div className="feedback" aria-live="polite"><span>{outcome?.status === "pending" && outcome.retry?.phase === "recover" ? "正在查询保存结果…" : message}</span>{outcome?.status === "unknown" && <button onClick={() => void recover()} disabled={busy}>查询保存结果</button>}</div>
      <div className="list-toolbar"><h2>最近记录</h2><div><label className="check"><input type="checkbox" checked={archived} onChange={(event) => setArchived(event.target.checked)} />包含归档</label><select aria-label="显示数量" value={limit} onChange={(event) => setLimit(Number(event.target.value))}><option value={20}>最近 20 条</option><option value={50}>最近 50 条</option></select><button onClick={() => void refresh()}>刷新</button></div></div>
      {query.error && <div className="error" role="alert">{describe(query.error)} <button onClick={() => void client.reconnect().catch((error) => setMessage(describe(error)))}>重新连接</button></div>}
      <ul className="messages" aria-label="随记列表" aria-busy={query.status === "connecting"}>
        {query.data?.map((item) => <li className={item.archived ? "archived" : ""} key={item.id}><span className="item-mark" aria-hidden="true" /><div className="message-body"><p>{item.text}</p><time dateTime={item.inserted_at}>{new Date(item.inserted_at).toLocaleString("zh-CN", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</time></div><button onClick={() => void archive(item)}>{item.archived ? "移回" : "归档"}</button></li>)}
        {query.status === "ready" && query.data?.length === 0 && <li className="empty"><span aria-hidden="true">▤</span><h3>这里还没有记录</h3><p>在上方写下第一条，打开另一个窗口也能看到它。</p></li>}
        {!query.data && query.status !== "error" && <li className="empty"><p>正在打开你的随记…</p></li>}
      </ul>
      <p className="list-note">显示最近 {limit} 条{archived ? "记录，含归档内容" : "未归档记录"}。</p>
    </main>
  </div>;
}

function App() {
  const [config, setConfig] = useState<HostConfig>();
  const [connection, setConnection] = useState<Connection>();
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const channel = typeof BroadcastChannel === "undefined" ? undefined : new BroadcastChannel("fyrlet-inbox-login");
    let active: Connection | undefined;
    let revision: string | undefined;
    let request = 0;
    const refresh = async () => {
      const generation = ++request;
      try {
        const next = await hostConfig(controller.signal);
        if (controller.signal.aborted || generation !== request) return;
        if (next.user?.revision !== revision || (!active && next.user)) {
          active?.close();
          revision = next.user?.revision;
          active = next.user ? connect(next, () => { active?.close(); setConnection(undefined); setConfig({ ...next, user: null }); setError("登录已到期，请重新登录。"); }) : undefined;
          setConnection(active);
        }
        setConfig(next);
      } catch (failure) { if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : "无法连接"); }
    };
    const focus = () => { void refresh(); };
    window.addEventListener("focus", focus);
    if (channel) channel.onmessage = (event) => {
      active?.close(); active = undefined; revision = undefined; request++;
      setConnection(undefined);
      setConfig((previous) => previous ? { ...previous, user: null } : previous);
      if (event.data !== "logout") void refresh();
    };
    void refresh().then(() => channel?.postMessage("changed"));
    return () => { controller.abort(); active?.close(); channel?.close(); window.removeEventListener("focus", focus); };
  }, []);

  async function signOut() {
    connection?.close();
    setConnection(undefined);
    if (config) setConfig({ ...config, user: null });
    const channel = typeof BroadcastChannel === "undefined" ? undefined : new BroadcastChannel("fyrlet-inbox-login");
    channel?.postMessage("logout");
    try {
      const response = await fetch("/auth/logout", { method: "POST" });
      if (!response.ok) setError("已退出当前页面。远程会话撤销尚未确认，请稍后重试退出。");
      else setError("");
    } catch { setError("已退出当前页面。网络恢复后请刷新并重试退出。"); }
    finally { channel?.postMessage("changed"); channel?.close(); }
  }

  if (connection && config?.user) return <FyrletProvider client={connection.client}><Inbox key={config.user.revision} user={config.user} signOut={signOut} /></FyrletProvider>;
  return <main className="login"><a className="brand" href="/"><span className="brand-mark">f</span> Fyrlet</a><div className="login-body"><span className="login-symbol" aria-hidden="true">▤</span><h1>打开你的随记。</h1><p>保存待办与灵感，在每个窗口接着记录。</p>{error && <p className="error" role="alert">{error}</p>}{config ? config.providers.map((provider) => <a className="primary login-button" href={`/auth/login?provider=${encodeURIComponent(provider.name)}`} key={provider.name}>使用 {provider.label} 登录</a>) : <p role="status">正在读取登录状态…</p>}<small>登录由你已有的身份服务提供。</small></div></main>;
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
