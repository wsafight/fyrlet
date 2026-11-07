// Verifies internal links and #anchors in dist/.
import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
const dist = new URL("../dist/", import.meta.url).pathname;
const root = fileURLToPath(new URL("../../", import.meta.url));
const base = (process.env.SITE_BASE ?? "/fyrlet").replace(/\/$/, "");
const repo = process.env.SITE_REPO ?? "wsafight/fyrlet";
const branch = process.env.SITE_BRANCH ?? "main";
const sourceLinks = new Set();
const files = [];
(function walk(d) { for (const f of readdirSync(d)) { const p = join(d, f); statSync(p).isDirectory() ? walk(p) : p.endsWith(".html") && files.push(p); } })(dist);
const ids = new Map();
const html = new Map(files.map((f) => [f, readFileSync(f, "utf8")]));
for (const [f, s] of html) ids.set(f, new Set([...s.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])));
let bad = 0, n = 0;
for (const [f, s] of html) for (const m of s.matchAll(/<a [^>]*href="([^"]+)"/g)) {
  const h = m[1];
  if (/^(https?:|mailto:)/.test(h)) {
    for (const kind of ["blob", "tree", "edit"]) {
      const prefix = `https://github.com/${repo}/${kind}/${branch}/`;
      if (!h.startsWith(prefix)) continue;
      const relative = decodeURIComponent(new URL(h).pathname.slice(new URL(prefix).pathname.length));
      const target = join(root, relative);
      sourceLinks.add(h);
      if (!existsSync(target) || (kind === "tree") !== statSync(target).isDirectory()) {
        console.log(`${f}: missing repository target ${h}`); bad++;
      }
    }
    continue;
  }
  n++;
  let [path, hash] = h.split("#");
  let target = f;
  if (path) {
    if (!path.startsWith(base + "/")) { console.log(`${f}: outside base ${h}`); bad++; continue; }
    const rel = path.slice(base.length);
    target = join(dist, rel, rel.endsWith("/") ? "index.html" : "");
    if (!existsSync(target) || statSync(target).isDirectory()) { console.log(`${f}: missing ${h}`); bad++; continue; }
  }
  if (hash && !ids.get(target)?.has(decodeURIComponent(hash))) { console.log(`${f}: missing anchor ${h}`); bad++; }
}
console.log(`${n} internal links and ${sourceLinks.size} repository targets checked, ${bad} broken`);
process.exit(bad ? 1 : 0);
