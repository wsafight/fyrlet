# Fyrlet documentation site

English | [简体中文](README.zh-CN.md)

An Astro static site with a bilingual landing page and documentation. English pages live under `/docs/`; Chinese pages live under `/zh/docs/`. The default deployment adds the `/fyrlet` base path.

The homepage introduces the framework and links to the guides. The header's Docs link opens the integration tutorial directly. The former `/docs/` and `/zh/docs/` indexes redirect to the homepage's documentation section. Document navigation preserves the sidebar's scroll position separately for each language.

## Local development

Use Node ≥ 22.23.4. From the repository root:

```sh
cd site
npm ci
npm run dev
```

Open the address printed by Astro, normally `http://localhost:4321/fyrlet/`. The Chinese homepage is `/fyrlet/zh/`. Astro can choose a different port if 4321 is occupied. Source edits update the development server.

## Build and verify

From `site/`:

```sh
npm run build
npm run check
npm run preview
```

Build output is `site/dist/`. The link check requires a completed build. It checks generated internal pages and anchors, and verifies links into the configured GitHub repository against local source paths. Preview serves the production artifact; inspect both languages and the layout at desktop and mobile widths before publishing.

## Content sources and translations

- English documents are `docs/*.md`; ordinary Chinese documents are `docs/zh/*.md`.
- SDK and example guides use English `README.md` and Chinese `README.zh-CN.md` files in the same directory. [`src/documents.mjs`](src/documents.mjs) maps each pair to a stable document ID such as `sdk` or `example-chat`.
- [`src/content.config.ts`](src/content.config.ts) loads both languages directly from those files. Edit each source once; do not copy README bodies into `docs/` or `docs/zh/`.
- [`src/plugins/rehype-doc-links.mjs`](src/plugins/rehype-doc-links.mjs) maps registered document links to local site pages and removes standalone Markdown language switches from the rendered body. The site header provides language switching, while the source Markdown keeps its switch for repository readers. Other repository files and directories link to GitHub. Relative links must first be correct relative to the source Markdown file.
- [`src/components/DocPage.astro`](src/components/DocPage.astro) renders the article, sidebar and table of contents without GitHub edit links. Keep technical identifiers, commands, error codes and verification boundaries consistent between languages; translate surrounding explanations and illustrative comments.

To add a document, create the English and Chinese sources with matching IDs and add its group and descriptions to [`src/i18n/index.ts`](src/i18n/index.ts). Update [`src/components/Landing.astro`](src/components/Landing.astro) when the new guide needs a homepage entry. For a README pair, register its English `README.md` path in `repositoryDocuments`; the Chinese source is the adjacent `README.zh-CN.md`. Update both [English](../docs/README.md) and [Chinese](../docs/zh/README.md) repository indexes. Build and check all links, especially section anchors and the header language switch.

## Deployment configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `SITE_URL` | `https://wsafight.github.io` | Canonical origin, without the project base path |
| `SITE_BASE` | `/fyrlet` | Deployment prefix; use `/` for a domain root |
| `SITE_REPO` | `wsafight/fyrlet` | GitHub source links |
| `SITE_BRANCH` | `main` | GitHub branch for source links |

For the default GitHub Pages path, run the normal build and publish the contents of `site/dist/` at `/fyrlet/`. For a custom domain root:

```sh
SITE_URL=https://example.com SITE_BASE=/ npm run build
SITE_BASE=/ npm run check
SITE_URL=https://example.com SITE_BASE=/ npm run preview
```

Use the same `SITE_BASE` for build, link checking and preview. These are build-time settings; changing environment variables after publishing does not rewrite the generated pages. Publish `dist/` with your chosen static hosting workflow. No application server or database is needed for the documentation artifact.

### GitHub Actions

The [Site workflow](../.github/workflows/site.yml) runs on pushes to `main` and pull requests targeting `main` when `site/`, `docs/` or a Markdown file changes. Both events install dependencies with `npm ci`, build the site and check links. Successful pushes to `main` also deploy `site/dist/` to GitHub Pages.

In the repository's **Settings → Pages → Build and deployment**, select **GitHub Actions** as the source. The workflow uses Node 24, caches npm downloads and grants Pages deployment permissions only to the deployment job. The default public address is `https://wsafight.github.io/fyrlet/`.

For a custom domain or deployment prefix, set the repository Actions variables `SITE_URL` and `SITE_BASE` before running the workflow. Their defaults match the table above; use `SITE_BASE=/` for a domain root. `SITE_REPO` and `SITE_BRANCH` come from the current repository and its default branch. Configure the custom domain separately in Pages settings.

## Common maintenance issues

| Symptom | Check |
| --- | --- |
| Links or styles are missing after deployment | Hosting prefix matches `SITE_BASE`, and the complete `dist/` artifact was uploaded |
| A source document is missing from the site | Collection patterns, stable document ID and navigation group |
| The language switch points to a missing page | Both language collections contain the same document ID |
| A section link breaks after translation | The fragment matches the heading in the target language |
| A repository link opens the wrong file | Source-relative paths and `SITE_REPO` / `SITE_BRANCH` |

Application connection and runtime issues are covered in [troubleshooting](../docs/TROUBLESHOOTING.md), separate from this site's maintenance.
