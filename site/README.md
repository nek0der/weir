# Weir site

The landing page and the documents, published at `weir.nekoder.com`. The site describes the released app, so it goes out with a release and not with each merge to `main`.

| Path | What it holds |
| --- | --- |
| `src/site.ts` | The addresses, the languages, and every word of the landing page and the top bar |
| `src/components/Landing.astro` | The landing page's head and markup. `/` and `/ja/` both render it |
| `src/styles/landing.css`, `src/scripts/landing.js` | The landing page's look and behavior |
| `src/components/SiteNav.astro`, `src/styles/nav.css` | The top bar that every page shares |
| `src/components/NotFound.astro` | The 404 page in each language |
| `src/icons/*.svg` | The top bar's icons, one file each |
| `src/assets/captures/` | The captures of the app, with the documents' under `docs/`. The build converts them to WebP in the sizes the page uses |
| `src/styles/tokens.css` | The colors of every page, one set for each look |
| `src/styles/docs.css` | The documents' look in Starlight |
| `public/_headers` | The security and caching headers Cloudflare Pages sends |
| `src/content/docs/docs/` | The documents in English, the source for every language |
| `src/content/docs/ja/docs/` | The documents in Japanese. A page with no translation shows the English one |
| `astro.config.mjs` | The site's languages, sidebar, sitemap, and address |

## Run it

Use the Node named in `.node-version` and the pnpm named by `packageManager` in `package.json`. Node 26 no longer ships Corepack, so install that pnpm yourself.

```bash
pnpm install
pnpm dev
```

`pnpm build` writes the site to `dist/`.

## Change the landing page

- Words are in `src/site.ts`, and the markup in `src/components/Landing.astro`. Write the Japanese as Japanese rather than translating the English, and break it with `<wbr>` between phrases.
- The look is in `src/styles/landing.css`: one part of the page at a time, then Japanese, then the narrow screens, which override what comes before them.
- To change the scroll's steps, edit the `steps` list in `src/scripts/landing.js` and `captions` in `src/site.ts`, which stay in the same order.
- The top bar is one component for the whole site, so a change to it reaches the documents too.

Check a change at 2000x1000, 1400x850, 390x844, and 320x640, in both languages and both looks. The header has the least room at 320 in Japanese.

## Change the captures

From the repository's root:

```bash
make site-images
```

This builds the app and takes every capture from demo mode, whose data and time of day are fixed: four in each look for the landing page, and four in the dark look in English and Japanese for the documents, under `src/assets/captures/docs/`. It needs the same Screen Recording grant as `make screenshot`. Stay off the keyboard and mouse while it runs: the app takes what you type, and a run stops if another app comes to the front. No image changes until every capture has succeeded.

The documents' captures crop to the surface they are about, which the app reports, so a change of layout needs no new coordinates. The fixture's own text, such as prompts and terminal output, stays English in the Japanese captures.

## Add a document

Add a Markdown file under `src/content/docs/docs/`, and its translation at the same path under `ja/docs/`. The sidebar picks it up. A page marked `noindex` in its frontmatter stays out of search and the sitemap. Use the names the app's `Localizable.xcstrings` uses for its parts.

## Write the documents

- Update a page in every language when a change alters what it describes: a label, a step, a shortcut, or a limit.
- Check the steps in the running app, not only in the code. Use the labels and order you see there.
- Keep each language's content the same as the English, and write it as a native speaker would rather than as a translation.
- Add an image only where words cannot show the thing clearly: the window's layout, the review, Needs Attention, the approval card. Install, shortcuts, troubleshooting, and privacy need none.
- Images come from `make site-images`, never by hand. Run it before a release when a pictured screen changed.
- Write a key as `<kbd>⌘N</kbd>`.

## Add a language

1. Add a row to `LANGS` and its words to `STRINGS` in `src/site.ts`.
2. Add it to `locales` in `astro.config.mjs`, in both Starlight's and the sitemap's.
3. Add `index.astro` and `404.astro` under `src/pages/<code>/`, as `src/pages/ja/` has them, and rename its 404 in `notFoundInEachFolder` in `astro.config.mjs`.
4. To send readers there from `/`, change `nonDefaultLang` in `src/components/Landing.astro`, which handles one language today, and the choice of language in `src/components/DocsHeader.astro`.
5. If the language needs its own font or spacing, add them beside the Japanese ones in `src/styles/landing.css`.

## Publish

`.github/workflows/site-deploy.yml` deploys the Latest release to Cloudflare Pages when the Release workflow finishes. To deploy a fix between releases, run the workflow by hand with a tag or branch.

Do not give the repository's GitHub Pages a custom domain. It serves the update feed that shipped apps read at `nek0der.github.io/weir/appcast.xml`.

## Update the dependencies

Versions are exact and locked. Choose releases at least two weeks old, then run `pnpm install` and `pnpm build`.
