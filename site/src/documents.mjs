export const repositoryDocuments = {
  "sdk-overview": "sdks/README.md",
  sdk: "sdks/typescript/README.md",
  examples: "examples/README.md",
  "example-inbox": "examples/inbox/README.md",
  "example-notify": "examples/notify/README.md",
  "example-flow": "examples/flow/README.md",
  "example-agent": "examples/agent/README.md",
  "example-chat": "examples/chat/README.md",
};

export function documentForSource(source) {
  const relative = source.replaceAll("\\", "/");
  for (const [slug, file] of Object.entries(repositoryDocuments)) {
    if (file === relative) return { lang: "en", slug };
    if (sourceForDocument("zh", slug) === relative) return { lang: "zh", slug };
  }
  const match = /^docs\/(?:(zh)\/)?([^/]+)\.md$/.exec(relative);
  if (match) return { lang: match[1] ? "zh" : "en", slug: match[2].toLowerCase() };
}

export function sourceForDocument(lang, slug) {
  return repositoryDocuments[slug]
    ? repositoryDocuments[slug].replace(/\.md$/, lang === "zh" ? ".zh-CN.md" : ".md")
    : `docs/${lang === "zh" ? "zh/" : ""}${slug.toUpperCase()}.md`;
}
