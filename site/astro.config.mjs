import { defineConfig } from "astro/config";
import { satteri } from "@astrojs/markdown-satteri";
import { docLinks } from "./src/plugins/rehype-doc-links.mjs";

// Served from https://wsafight.github.io/fyrlet/ by default. For a custom domain set
// SITE_URL=https://example.com and SITE_BASE=/ when building.
const site = process.env.SITE_URL ?? "https://wsafight.github.io";
const base = (process.env.SITE_BASE ?? "/fyrlet").replace(/\/$/, "");
const repo = process.env.SITE_REPO ?? "wsafight/fyrlet";
const branch = process.env.SITE_BRANCH ?? "main";

export default defineConfig({
  site,
  base: base || "/",
  trailingSlash: "always",
  build: { format: "directory" },
  markdown: {
    shikiConfig: { themes: { light: "github-light", dark: "github-dark" } },
    processor: satteri({ hastPlugins: [docLinks({ base, repo, branch })] }),
  },
});
