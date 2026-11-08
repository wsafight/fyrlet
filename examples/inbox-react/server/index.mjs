import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createSessionService } from "@fyrlet/client/server";
import { createAuth } from "./auth.mjs";
import { storeFromEnvironment } from "./store.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.env.WEB_PORT || 5173);
const publicOrigin = process.env.PUBLIC_ORIGIN || `http://127.0.0.1:${port}`;
const endpoint = process.env.FYRLET_ENDPOINT || "http://127.0.0.1:4000";
let store;
let auth;
try {
  const providers = JSON.parse(process.env.OIDC_PROVIDERS || "[]");
  store = await storeFromEnvironment(process.env);
  auth = await createAuth({ publicOrigin, endpoint, projectId: process.env.FYRLET_PROJECT_ID, providers, store,
    allowLocal: process.env.ALLOW_INSECURE_OIDC === "1", sessions: createSessionService({ endpoint, serviceKey: process.env.FYRLET_SERVICE_KEY || "" }) });
} catch { await store?.close(); throw new Error("Host authentication startup failed; verify identity and storage configuration"); }
const production = process.argv.includes("--production");
let vite;
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml" };
const server = createServer(async (incoming, outgoing) => {
  try {
    const request = new Request(new URL(incoming.url, publicOrigin), { method: incoming.method, headers: incoming.headers });
    const response = await auth.handle(request);
    if (response) {
      const headers = Object.fromEntries([...response.headers].filter(([key]) => key !== "set-cookie"));
      if (response.headers.getSetCookie().length) headers["set-cookie"] = response.headers.getSetCookie();
      outgoing.writeHead(response.status, headers);
      outgoing.end(Buffer.from(await response.arrayBuffer()));
    } else if (vite) vite.middlewares(incoming, outgoing);
    else {
      if (incoming.method !== "GET" && incoming.method !== "HEAD") { outgoing.writeHead(405); outgoing.end(); return; }
      const path = decodeURIComponent(new URL(request.url).pathname);
      const file = path === "/" ? resolve(root, "dist/index.html") : resolve(root, "dist", `.${path}`);
      if (!file.startsWith(resolve(root, "dist") + sep)) { outgoing.writeHead(404); outgoing.end(); return; }
      const data = await readFile(file);
      outgoing.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
      outgoing.end(incoming.method === "HEAD" ? undefined : data);
    }
  } catch { outgoing.writeHead(404); outgoing.end("Page unavailable"); }
});
server.requestTimeout = 15_000;
server.headersTimeout = 10_000;
if (!production) {
  const { createServer: createViteServer } = await import("vite");
  vite = await createViteServer({ root, server: { middlewareMode: true, hmr: { server } }, appType: "spa" });
}
server.listen(port, "127.0.0.1", () => console.log(`随记: ${publicOrigin}`));
async function close() {
  server.close();
  server.closeIdleConnections();
  await vite?.close();
  await auth.close();
}
process.once("SIGTERM", close);
process.once("SIGINT", close);
