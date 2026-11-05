import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline/promises";
import { createClient } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";

const path = process.env.FYRLET_PROJECT_FILE ?? new URL("../../../.local/project.json", import.meta.url);
const project = JSON.parse(await readFile(path, "utf8"));
const endpoint = process.env.FYRLET_ENDPOINT ?? "http://127.0.0.1:4000";
const sessions = createSessionService({ endpoint, serviceKey: project.service_key });
let current;
const client = createClient({ endpoint, projectId: project.project_id, getToken: async ({ forceRefresh }) => {
  if (forceRefresh || !current || Date.parse(current.expires_at) - Date.now() < 30_000) {
    current = await sessions.issueSession({ external_subject: process.env.FYRLET_SUBJECT ?? "local-demo", issuer: "local-cli" });
  }
  return current.token;
} });

const text = process.argv.slice(2).join(" ");
if (text) {
  try {
    const item = await client.call("inbox.add", { text });
    console.log(JSON.stringify(item, null, 2));
  } finally { client.close(); }
} else {
  const subscription = client.subscribe("inbox.recent", { limit: 20 });
  subscription.onChange((state) => {
    console.log(`\n[${state.status}]`);
    if (state.error) console.error(`${state.error.code}: ${state.error.message}`);
    for (const item of state.data ?? []) console.log(`${item.id.slice(0, 8)} v${item.version} ${item.text}`);
  });
  const input = createInterface({ input: process.stdin, output: process.stdout });
  const shutdown = () => { input.close(); client.close(); };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  console.log("输入文字保存到收件箱；/quit 退出。另开终端可查看实时变化。");
  try {
    for await (const line of input) {
      if (line === "/quit") break;
      if (line.trim()) {
        try { await client.call("inbox.add", { text: line }); }
        catch (error) { console.error(`${error.code ?? "ERROR"}: ${error.message}`); }
      }
    }
  } finally { shutdown(); }
}
