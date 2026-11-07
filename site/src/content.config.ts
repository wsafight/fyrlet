import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { documentForSource, repositoryDocuments, sourceForDocument } from "./documents.mjs";

const documents = (lang: "en" | "zh") => defineCollection({ loader: glob({
  pattern: [
    `docs/${lang === "zh" ? "zh/" : ""}*.md`,
    ...Object.keys(repositoryDocuments).map((slug) => sourceForDocument(lang, slug)),
  ],
  base: "..",
  generateId: ({ entry }) => documentForSource(entry)?.slug ?? entry,
}) });

export const collections = { docsEn: documents("en"), docsZh: documents("zh") };
