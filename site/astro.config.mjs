// astro.config.mjs
// Weir — the site: the landing page in src/components/Landing.astro, and the documents under /docs.
import sitemap from "@astrojs/sitemap";
import starlight from "@astrojs/starlight";
import { readFileSync } from "node:fs";
import { rename, rm } from "node:fs/promises";
import { defineConfig } from "astro/config";

function isNoindex(page) {
  const file = new URL(`./dist${new URL(page).pathname}index.html`, import.meta.url);
  return readFileSync(file, "utf8").includes('name="robots" content="noindex"');
}

// Cloudflare Pages serves the nearest `404.html`, and Astro writes a page under a folder as `404/index.html`.
const notFoundInEachFolder = {
  name: "weir-not-found-pages",
  hooks: {
    "astro:build:done": async ({ dir }) => {
      await rename(new URL("ja/404/index.html", dir), new URL("ja/404.html", dir));
      await rm(new URL("ja/404", dir), { recursive: true });
    },
  },
};

export default defineConfig({
  site: "https://weir.nekoder.com",
  integrations: [
    starlight({
      title: "Weir",
      disable404Route: true,
      favicon: "/favicon.png",
      customCss: ["./src/styles/tokens.css", "./src/styles/nav.css", "./src/styles/docs.css"],
      head: [
        {
          tag: "link",
          attrs: {
            rel: "stylesheet",
            href: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&family=IBM+Plex+Sans+JP:wght@400;500;600&display=swap",
          },
        },
      ],
      defaultLocale: "root",
      locales: {
        root: { label: "English", lang: "en" },
        ja: { label: "日本語", lang: "ja" },
      },
      components: {
        Header: "./src/components/DocsHeader.astro",
        MobileMenuFooter: "./src/components/DocsMobileMenuFooter.astro",
      },
      sidebar: [{ label: "Documents", translations: { ja: "ドキュメント" }, items: [{ autogenerate: { directory: "docs" } }] }],
    }),
    // Ours rather than the one Starlight adds: a page marked `noindex` is left out, so the sitemap needs no list of them.
    sitemap({
      filter: (page) => !isNoindex(page),
      i18n: { defaultLocale: "en", locales: { en: "en", ja: "ja" } },
    }),
    notFoundInEachFolder,
  ],
});
