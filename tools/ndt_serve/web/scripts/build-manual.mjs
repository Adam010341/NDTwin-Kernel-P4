// [Co-developed with claude code -- Adam]
// manual/zh.md -> <static>/manual.html (SCOPE-v2 section 7), with marked. The page it makes has no
// script, no inline style and no handler, and links ./app.css only: the server's CSP applies to it
// as to the page, and the classes it uses (manual/style.json) are in app.css because Tailwind's
// `content` scans that file. Any of those in the output fails the build instead of shipping.
//
// Run by `npm run build` after `vite build`. NDT_SERVE_STATIC_OUT moves the output, as in
// vite.config.ts.
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { marked } from 'marked';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.NDT_SERVE_STATIC_OUT
  ? path.resolve(process.env.NDT_SERVE_STATIC_OUT)
  : path.resolve(web, '../static');

const md = readFileSync(path.join(web, 'manual', 'zh.md'), 'utf8');
const style = JSON.parse(readFileSync(path.join(web, 'manual', 'style.json'), 'utf8'));

// The manual is ours and carries no HTML of its own: any raw HTML token is refused, so what reaches
// the page is only what marked renders from Markdown.
const tokens = marked.lexer(md, { gfm: true });
marked.walkTokens(tokens, (tok) => {
  if (tok.type === 'html') throw new Error('build-manual: raw HTML in manual/zh.md: ' + JSON.stringify(tok.raw));
});
const body = marked.parser(tokens, { gfm: true });

const attr = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;');
const html =
  '<!doctype html>\n' +
  '<!-- ndt serve: the manual. Built from tools/ndt_serve/web/manual/zh.md by scripts/build-manual.mjs; do not edit. -->\n' +
  '<html lang="zh-Hant">\n' +
  '<head>\n' +
  '<meta charset="utf-8">\n' +
  '<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
  '<title>ndt serve 使用手冊</title>\n' +
  '<link rel="stylesheet" href="./app.css">\n' +
  '</head>\n' +
  '<body class="' + attr(style.body) + '">\n' +
  '<main class="' + attr(style.main) + '">\n' +
  body +
  '</main>\n' +
  '</body>\n' +
  '</html>\n';

const refused = [
  [/<script\b/i, 'a <script> element'],
  [/<style\b/i, 'a <style> element'],
  [/\sstyle\s*=/i, 'a style attribute'],
  [/\son[a-z]+\s*=/i, 'an on* handler attribute'],
  [/javascript:/i, 'a javascript: URL'],
];
for (const [re, what] of refused) {
  if (re.test(html)) throw new Error('build-manual: the manual would carry ' + what);
}

writeFileSync(path.join(out, 'manual.html'), html);
console.log('build-manual: ' + path.join(out, 'manual.html') + ' (' + Buffer.byteLength(html) + ' bytes)');
