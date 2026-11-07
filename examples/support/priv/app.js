import { createClient } from "/sdk/index.js";

const domain = document.body.dataset.domain;
const titles = { notify: ["通知中心", "创建通知并跟踪外部投递回执。"], flow: ["流程工作台", "保存顺序流程，观察调用进度并处理等待事件。"], agent: ["审批助手", "运行有限工具，在人工批准后保存结果。"], chat: ["协作会话", "通过邀请加入会话，分配负责人并实时交流。"] };
const element = (id) => document.getElementById(id);
const text = (tag, value) => { const node = document.createElement(tag); node.textContent = value; return node; };
const button = (label, callback) => { const node = text("button", label); node.type = "button"; node.addEventListener("click", () => perform(callback)); return node; };
let client;
let detailSubscription;
let metadataSubscription;
let oldestMessage;
let historyComplete = false;
const historyIds = new Set();
element("title").textContent = titles[domain][0];
element("intro").textContent = titles[domain][1];
element("action-title").textContent = { notify: "发送通知", flow: "编排流程", agent: "新建任务", chat: "开启会话" }[domain];

function field(name, label, value = "", multiline = false) {
  const wrapper = text("label", label);
  const input = document.createElement(multiline ? "textarea" : "input");
  input.name = name;
  input.value = value;
  input.required = true;
  wrapper.append(input);
  element("action").append(wrapper);
}
if (domain === "notify") { field("recipient", "收件邮箱"); field("title", "标题"); field("body", "正文", "", true); }
if (domain === "flow") { field("flow_id", "流程名称", "review"); field("nodes", "节点 JSON", JSON.stringify([{ type: "wait", name: "approval", signal: "go", timeout_seconds: 3600 }], null, 2), true); }
if (domain === "agent") { field("goal", "需要审核的文本", "", true); field("tool", "工具：word_count 或 excerpt", "word_count"); }
if (domain === "chat") { field("title", "会话主题"); }
const submit = text("button", domain === "flow" ? "保存并运行" : "创建");
element("action").append(submit);

async function perform(callback) {
  element("error").textContent = "";
  try { await callback(); } catch (error) { element("error").textContent = `${error.code ?? "请求失败"}：${error.message}`; }
}

function watch(subscription, render) {
  subscription.onChange(() => {
    const state = subscription.getState();
    element("status").textContent = { ready: "已连接", recovering: "重连中", connecting: "连接中", error: "连接异常", closed: "已断开" }[state.status] ?? state.status;
    if (state.error) element("error").textContent = state.error.message;
    if (state.data !== undefined) render(state.data);
    else if (state.status === "error" || state.status === "closed") {
      render([]);
      element("detail").replaceChildren();
      element("controls").replaceChildren();
      element("detail-title").textContent = "详情";
      historyIds.clear();
    }
  });
}

element("connection").addEventListener("submit", (event) => {
  event.preventDefault();
  perform(async () => {
    client?.close();
    const token = element("token").value.trim();
    client = createClient({ endpoint: location.origin, projectId: element("project").value.trim(), getToken: () => token, capabilities: { runs: 1, append: 1 } });
    element("token").value = "";
    element("workspace").hidden = false;
    const subscription = client.subscribe({ notify: "notify.inbox", flow: "flow.saved", agent: "agent.tasks", chat: "chat.rooms" }[domain], {});
    watch(subscription, renderList);
    if (domain === "chat") chatActions();
  });
});

element("action").addEventListener("submit", (event) => {
  event.preventDefault();
  perform(async () => {
    const input = Object.fromEntries(new FormData(event.currentTarget));
    if (domain === "notify") await showRun((await client.startRun("notify.send", { ...input, event_id: crypto.randomUUID() })).run_id);
    if (domain === "flow") {
      const nodes = JSON.parse(input.nodes);
      await client.call("flow.save", { flow_id: input.flow_id, nodes });
      await showRun((await client.startRun("flow.start", { flow_id: input.flow_id, nodes })).run_id);
    }
    if (domain === "agent") await showRun((await client.startRun("agent.start", input)).run_id);
    if (domain === "chat") await showRoom((await client.call("chat.create", input)).id);
  });
});

function renderList(rows) {
  element("list").replaceChildren();
  if (!rows.length) element("list").append(text("p", "暂无记录。"));
  for (const row of rows) {
    const entry = document.createElement("article");
    entry.className = "entry";
    entry.append(text("strong", row.title ?? row.goal ?? row.flow_id));
    if (row.body) entry.append(text("p", row.body));
    entry.append(text("small", row.delivery ?? row.status ?? "已保存"));
    if (row.run_id) entry.append(button("查看运行", () => showRun(row.run_id)));
    if (domain === "flow") entry.append(button("运行", async () => showRun((await client.startRun("flow.start", { flow_id: row.flow_id, nodes: JSON.parse(row.nodes_json) })).run_id)));
    if (domain === "chat") entry.append(button("打开会话", () => showRoom(row.id)));
    element("list").append(entry);
  }
}

async function showRun(id) {
  detailSubscription?.unsubscribe();
  detailSubscription = client.subscribeRun(id);
  watch(detailSubscription, (run) => {
    element("detail").textContent = JSON.stringify(run, null, 2);
    element("controls").replaceChildren();
    if (!["completed", "failed", "cancelled", "expired"].includes(run.status)) element("controls").append(button("取消运行", () => client.cancelRun(id)));
    const wait = run.steps?.find((step) => step.type === "wait" && step.status === "waiting");
    if (wait) {
      if (domain === "agent") {
        for (const approved of [true, false]) element("controls").append(button(approved ? "批准" : "拒绝", () => client.signalRun(id, { wait_id: wait.id, name: "approval", payload: { approved } })));
      } else {
        const label = text("label", "等待的信号名称");
        const input = document.createElement("input");
        input.value = "ngo";
        label.append(input);
        element("controls").append(label, button("发送信号", () => client.signalRun(id, { wait_id: wait.id, name: input.value, payload: {} })));
      }
    }
  });
}

function chatActions() {
  const input = document.createElement("input");
  input.placeholder = "粘贴会话邀请码";
  input.setAttribute("aria-label", "会话邀请码");
  element("extra").replaceChildren(text("h2", "加入已有会话"), input, button("加入", async () => showRoom((await client.call("chat.join", { code: input.value.trim() })).id)));
}

async function showRoom(id) {
  oldestMessage = undefined;
  historyComplete = false;
  historyIds.clear();
  detailSubscription?.unsubscribe();
  metadataSubscription?.unsubscribe();
  element("detail").textContent = "";
  const room = await client.call("chat.get", { room_id: id });
  element("detail-title").textContent = room.title;
  const controls = element("controls");
  const message = document.createElement("textarea");
  message.placeholder = "输入消息";
  message.setAttribute("aria-label", "消息正文");
  const assignee = document.createElement("select");
  assignee.setAttribute("aria-label", "负责人");
  function renderMembers(current) {
    assignee.replaceChildren();
    for (const member of current.members) { const option = text("option", member.subject_id); option.value = member.subject_id; assignee.append(option); }
    if (current.assigned_subject_id) assignee.value = current.assigned_subject_id;
  }
  renderMembers(room);
  const send = button("发送", async () => { await client.call("chat.post", { room_id: id, text: message.value }); message.value = ""; });
  controls.replaceChildren(text("p", `邀请码：${room.code}`), assignee,
    button("刷新成员", async () => renderMembers(await client.call("chat.get", { room_id: id }))),
    button("分配负责人", () => client.call("chat.assign", { room_id: id, subject_id: assignee.value })),
    button("人工接管", () => client.call("chat.handoff", { room_id: id })),
    button("关闭会话", () => client.call("chat.close", { room_id: id })),
    button("离开会话", () => client.call("chat.leave", { room_id: id })),
    button("加载更早消息", async () => {
      if (historyComplete) { element("error").textContent = "已到达历史起点。"; return; }
      const page = await client.call("chat.history", { room_id: id, ...(oldestMessage ? { cursor: oldestMessage } : {}) });
      for (const item of [...page.items].reverse()) addMessage(item, true);
      oldestMessage = page.next_cursor;
      historyComplete = oldestMessage === null;
      if (historyComplete) element("error").textContent = "已到达历史起点。";
    }), message, send);
  metadataSubscription = client.subscribe("chat.room", { room_id: id });
  watch(metadataSubscription, (current) => {
    if (!current.id) return;
    const state = { open: "进行中", human: "人工处理中", closed: "已关闭" }[current.status] ?? current.status;
    element("detail-title").textContent = `${current.title} · ${state}`;
    if (current.assigned_subject_id) assignee.value = current.assigned_subject_id;
    message.disabled = send.disabled = current.status === "closed";
  });
  detailSubscription = client.subscribeAppend("chat.messages", { room_id: id });
  watch(detailSubscription, (messages) => {
    if (oldestMessage === undefined && messages.length) oldestMessage = messages[0].id;
    for (const item of messages) addMessage(item);
  });
}

function addMessage(item, prepend = false) {
  if (historyIds.has(item.id)) return;
  historyIds.add(item.id);
  const line = text("div", `${item.author}: ${item.text}`);
  line.dataset.messageId = item.id;
  if (prepend) element("detail").prepend(line); else element("detail").append(line);
  while (element("detail").childElementCount > 500) {
    const removed = prepend ? element("detail").lastElementChild : element("detail").firstElementChild;
    historyIds.delete(removed.dataset.messageId);
    removed.remove();
  }
}
