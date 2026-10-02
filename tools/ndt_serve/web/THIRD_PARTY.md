# Third-party material in tools/ndt_serve/web/

[Co-developed with claude code -- Adam]

## Web-GUI

- **Source**: ndtwin-lab/Web-GUI (`https://github.com/ndtwin-lab/Web-GUI`), read from the local
  checkout `~/Web-GUI` at commit `f63a55ce7d3a75736e23aca202606f3a1fd447b1` (2026-04-20). Read only:
  nothing there was modified, built or installed.
- **License**: Apache License 2.0 — Web-GUI's `LICENSE` (sha256
  `306500a8132930e2b1df74727945644dd787f6b3d80379142a38d6df64da592f`), the standard text:
  <https://www.apache.org/licenses/LICENSE-2.0>. Web-GUI has no NOTICE file, and its
  `ndtwin-license-header.txt` is applied to none of its files, so there is no notice text to carry;
  attribution is kept here and in the header of every copied file (Apache-2.0 section 4(c)), and the
  one modified file says what was changed (section 4(b)).
- This directory is also Apache-2.0, as the rest of NDTwin-Kernel.

### Files copied

| here | from (Web-GUI @ f63a55ce) | source sha256 | changes |
|---|---|---|---|
| `src/components/common/LoadingSpinner.tsx` | `src/components/common/LoadingSpinner.tsx` | `698fee7bf28c8e0156e703bcf3265957ebafcb824f06c6ea0b6ce70a6ca1c83a` | none: a three-line header naming the source, then the file byte for byte |
| `src/components/common/ErrorBoundary.tsx` | `src/components/common/ErrorBoundary.tsx` | `c26432baaf8640228585ec47a62f60fac6711b5512ffc591fbd31c0218cc67ae` | **modified**, as its header says: its four English strings go through the string table (`i18n.t`, keys `ndtServe.err.boundary*`); `process.env.NODE_ENV === 'development'` became `import.meta.env.DEV` (this build has no `@types/node`); the i18n import |

### Patterns followed (written here, not copied)

Class names and shapes taken from these places; the code around them is this directory's own.

| here | Web-GUI @ f63a55ce | what was taken |
|---|---|---|
| `src/components/TabBar.tsx` | `src/components/LinkFlowInformation.tsx:463-482` | the segmented row of buttons that switches a view |
| `src/components/TabBar.tsx` | `src/components/Sidebar.tsx:132-171` (active branch `:146`) | the chosen item's look, `border-[#1976d2] bg-[#fff] text-[#1976d2]`, and the idle one's `hover:text-[#1976d2]` |
| `src/components/StatusRows.tsx`, `src/lib/ui.ts` (`CARD`) | `src/components/DeviceInformation.tsx:226-305` (card `:252`, rows `:253-254`) | the white card `rounded-lg border border-[#e0e0e0] bg-white p-6`; label-left / value-right rows, `flex items-center justify-between`, label `font-medium text-[#1976d2]`, value `text-[#222]` |
| `src/lib/ui.ts` (`INPUT`) | `src/components/DeviceInformation.tsx:275` | the input's blue focus border |
| `src/components/DataTable.tsx` | `src/components/FlowTablePanel.tsx:186-212` (header `:186`, row `:208`) | sticky white `thead`, `px-3 py-2 text-left text-xs font-semibold tracking-wider text-gray-700` headers, rows `border-b border-gray-100 transition last:border-b-0 hover:bg-blue-50` |
| `src/components/ConfirmDialog.tsx`, `src/lib/ui.ts` (`BTN_SECONDARY`, `BTN_DANGER`) | `src/pages/SwitchFlowTable.tsx:623-657` (`DeleteDialog`; Cancel `:642`, Delete `:649`) | the dialog box `rounded-lg border border-gray-200 bg-white p-8 shadow-xl`, its dimmed backdrop, its heading, and its two buttons. Here it is a native `<dialog>` with a typed-confirmation field added |
| `src/components/Badge.tsx`, `src/components/TopBar.tsx` | `src/pages/AvailabilityStatus.tsx:246` | the pill `inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium` (green `bg-green-100 text-green-800`) |
| `src/components/TopBar.tsx`, `src/lib/ui.ts` (`BTN_GHOST`) | `src/pages/AvailabilityStatus.tsx:236-260` (h1 `:242`, ghost button `:255`) | the header bar: `text-2xl font-semibold text-gray-900` title, a badge, ghost buttons |
| `src/lib/ui.ts` (`BTN_SMALL`) | `src/components/LinkFlowInformation.tsx:465` | the small bordered blue button, inactive state |
| `src/NdtServeApp.tsx` | `src/App.tsx:36` | the `bg-gray-100` page background |
| `src/i18n/index.ts` | `src/i18n.ts:1-28` | i18next + react-i18next with bundled resources, one forced language, `escapeValue: false`, `useSuspense: false` (here the language is zh and every key is under `ndtServe.`) |
| `src/index.css` | `src/index.css:1-3` | Tailwind's three layers and nothing else |
| `tailwind.config.js` | `tailwind.config.js:1-8` | `theme.extend: {}`, no plugins; colours as arbitrary values |
| `postcss.config.js` | `postcss.config.js:1-6` | Tailwind, then autoprefixer |
| `tsconfig.json` | `tsconfig.app.json:1-28` | the compiler options (bundler resolution, `verbatimModuleSyntax`, `jsx: react-jsx`, strict, unused locals and parameters off), minus `types: ["node"]` and the build-info file |
| `src/components/ShortId.tsx` | 58 `title=` tooltips across Web-GUI's `src/` | the whole id on hover is the native `title`, as Web-GUI shows its tooltips |

Palette, from the same files: primary `#1976d2`, accent `#FF7F50`, page `bg-gray-100`, cards white
with `#e0e0e0` borders, text `#222`/`#333`, system fonts (Tailwind's default stack), no dark mode.

### Not taken, and why

- `react-draggable` (DeviceInformation and others): it inserts a `<style>` element while dragging,
  which the server's CSP (`style-src 'self'`) blocks.
- `i18next-browser-languagedetector` and `src/hooks/useLanguage.ts`: they write localStorage; this
  page keeps nothing in the browser.
- `src/utils/LLM.ts`, `axios`, `react-router(-dom)`, `react-icons`, `zod`, `echarts`, `cytoscape`,
  `openai`, `dotenv`: not needed here (SCOPE-v2 section 3).
- Web-GUI's API base: a cross-origin URL from its `.env`; here the API is the page's own origin
  (`./api/v1`).

## npm packages

The exact versions, with their sha512 integrity, are in `package-lock.json` (lockfileVersion 3,
resolved against `registry.npmjs.org`); every package's own license file is in its directory under
`node_modules/` after `npm ci`.

Only the runtime closure can end up in `../static/app.js` -- all MIT:

| package | version |
|---|---|
| react | 19.1.0 |
| react-dom | 19.1.0 |
| scheduler | 0.26.0 |
| i18next | 25.3.2 |
| @babel/runtime | 7.29.7 |
| react-i18next | 15.6.1 |
| html-parse-stringify | 3.1.0 |
| void-elements | 3.1.0 |

The rest (vite, @vitejs/plugin-react, typescript, tailwindcss, postcss, autoprefixer, marked,
@types/react, @types/react-dom and what they pull in) run at build time only. Tailwind's preflight
(tailwindcss, MIT; derived from modern-normalize, MIT) is in `../static/app.css`.
