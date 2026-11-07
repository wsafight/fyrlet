# Fyrlet 文档站

[English](README.md) | 简体中文

使用 Astro 构建的静态站点，包含双语首页与文档。英文页面在 `/docs/`，中文页面在 `/zh/docs/`；默认部署会增加 `/fyrlet` 路径前缀。

首页介绍框架并提供指南入口，页头的「文档」直接进入接入教程。原 `/docs/` 与 `/zh/docs/` 索引地址跳转到首页的文档区域。切换文档时，侧栏按语言保留滚动位置。

## 本地开发

需要 Node ≥ 22.23.4。在仓库根目录运行：

```sh
cd site
npm ci
npm run dev
```

打开 Astro 输出的地址，通常是 `http://localhost:4321/fyrlet/`；中文首页为 `/fyrlet/zh/`。4321 被占用时 Astro 可能选择其他端口。修改源文件后开发服务器会更新页面。

## 构建与检查

在 `site/` 中运行：

```sh
npm run build
npm run check
npm run preview
```

产物为 `site/dist/`，链接检查需要先完成构建。它检查生成页面的站内路径、锚点，并用本地源文件核对指向配置中 GitHub 仓库的链接。Preview 预览生产产物；发布前检查两种语言和桌面、移动宽度的布局。

## 内容来源与翻译

- 英文文档位于 `docs/*.md`，普通中文文档位于 `docs/zh/*.md`。
- SDK 和示例指南在各自目录中使用英文 `README.md` 与中文 `README.zh-CN.md`。[`src/documents.mjs`](src/documents.mjs)将每对文件映射成 `sdk`、`example-chat` 等稳定 ID。
- [`src/content.config.ts`](src/content.config.ts)直接读取两种语言的 README，每份源文件只维护一次，不要再把正文复制到 `docs/` 或 `docs/zh/`。
- [`src/plugins/rehype-doc-links.mjs`](src/plugins/rehype-doc-links.mjs)将已登记文档转为站内页面，并移除正文中独立的 Markdown 语言切换行。站点统一使用页头切换语言，源 Markdown 仍保留仓库阅读所需的语言链接。其他仓库文件与目录转向 GitHub。相对链接首先应在源 Markdown 的目录下正确。
- [`src/components/DocPage.astro`](src/components/DocPage.astro)呈现正文、侧栏和目录，不展示 GitHub 编辑入口。两种语言保持技术标识、命令、错误码和验证边界一致，翻译周围说明与示例注释。

新增文档时，创建 ID 相同的中英文源文件，在 [`src/i18n/index.ts`](src/i18n/index.ts)加入分组和简介。需要在首页推荐时，再更新 [`src/components/Landing.astro`](src/components/Landing.astro)。README 文档在 `repositoryDocuments` 中登记英文 `README.md` 路径，中文来源自动对应同目录的 `README.zh-CN.md`。同时更新仓库的[英文索引](../docs/README.md)和[中文索引](../docs/zh/README.md)，构建并检查全部链接，尤其是章节锚点和页头语言切换。

## 部署配置

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `SITE_URL` | `https://wsafight.github.io` | 规范来源地址，不含项目路径前缀 |
| `SITE_BASE` | `/fyrlet` | 部署前缀；独立域名根目录用 `/` |
| `SITE_REPO` | `wsafight/fyrlet` | GitHub 源码链接 |
| `SITE_BRANCH` | `main` | GitHub 源码分支 |

默认 GitHub Pages 路径直接使用普通构建，将 `site/dist/` 的内容发布到 `/fyrlet/`。独立域名根目录示例：

```sh
SITE_URL=https://example.com SITE_BASE=/ npm run build
SITE_BASE=/ npm run check
SITE_URL=https://example.com SITE_BASE=/ npm run preview
```

构建、链接检查和预览使用相同 `SITE_BASE`。这些配置在构建时生效，发布后单独改环境变量不会重写页面。通过选用的静态托管流程发布 `dist/`；文档产物无需应用服务或数据库。

### GitHub Actions

[Site 工作流](../.github/workflows/site.yml)会在推送到 `main`，或 PR 的目标分支为 `main` 时，针对 `site/`、`docs/` 或 Markdown 文件的变更触发。两种情况都会执行 `npm ci`、构建和链接检查；推送到 `main` 且全部检查通过后，还会将 `site/dist/` 发布到 GitHub Pages。

在仓库的 **Settings → Pages → Build and deployment** 中，将 Source 设为 **GitHub Actions**。工作流使用 Node 24 并缓存 npm 下载，只有部署任务拥有 Pages 发布权限。默认公开地址为 `https://wsafight.github.io/fyrlet/`。

使用独立域名或其他部署前缀时，先在仓库的 Actions variables 中设置 `SITE_URL` 和 `SITE_BASE`。默认值与上表一致，独立域名根目录使用 `SITE_BASE=/`。`SITE_REPO` 和 `SITE_BRANCH` 自动取当前仓库及其默认分支；独立域名还需在 Pages 设置中配置。

## 常见维护问题

| 现象 | 检查 |
| --- | --- |
| 部署后链接或样式缺失 | 托管前缀与 `SITE_BASE` 一致，且上传了完整 `dist/` |
| 源文档没有出现在站点 | Collection 匹配规则、稳定文档 ID 与导航分组 |
| 语言切换指向不存在的页面 | 两个语言集合包含相同文档 ID |
| 翻译后章节链接失效 | 锚点与目标语言的标题匹配 |
| 仓库链接打开了错误文件 | 源文件相对路径与 `SITE_REPO` / `SITE_BRANCH` |

应用连接与运行问题见[常见问题与排查](../docs/zh/TROUBLESHOOTING.md)，与文档站自身的维护分开处理。
