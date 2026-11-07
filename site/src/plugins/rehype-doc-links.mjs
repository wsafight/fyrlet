// Rewrites the relative links of the repository documents so they work on the site:
//   - a registered document                 -> its localized page on this site
//   - any other file or folder of the repo   -> its page on GitHub
// External links, in-page anchors and absolute paths are left alone.
//
// A Sätteri HAST plugin: the factory runs once per document and receives its file URL.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { documentForSource } from "../documents.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

export function docLinks({ base = "", repo, branch = "main" } = {}) {
  return (factory) => {
    const from = factory.fileURL ? fileURLToPath(factory.fileURL) : undefined;
    if (!from) return { name: "doc-links" };
    const rewrite = (href) => {
      if (/^([a-z][a-z0-9+.-]*:|#|\/)/i.test(href)) return href;
      const [relative, ...rest] = href.split("#");
      const hash = rest.length ? `#${rest.join("#")}` : "";
      const target = path.resolve(path.dirname(from), relative);

      const document = documentForSource(path.relative(repoRoot, target));
      if (document) {
        const prefix = `${base}${document.lang === "zh" ? "/zh" : ""}`;
        return document.slug === "readme"
          ? `${prefix}/#documentation`
          : `${prefix}/docs/${document.slug}/${hash}`;
      }
      if (target.startsWith(repoRoot + path.sep)) {
        const kind = fs.existsSync(target) && fs.statSync(target).isDirectory() ? "tree" : "blob";
        return `https://github.com/${repo}/${kind}/${branch}/${path.relative(repoRoot, target)}${hash}`;
      }
      return href;
    };

    return {
      name: "doc-links",
      element: {
        filter: ["a", "p"],
        visit(node, ctx) {
          if (node.tagName === "p") {
            if (/^(English\s*\|\s*简体中文|简体中文\s*\|\s*English)$/.test(ctx.textContent(node).trim())) {
              ctx.removeNode(node);
            }
            return;
          }
          const href = node.properties?.href;
          if (typeof href !== "string") return;
          const next = rewrite(href);
          if (next !== href) ctx.setProperty(node, "href", next);
        },
      },
    };
  };
}
