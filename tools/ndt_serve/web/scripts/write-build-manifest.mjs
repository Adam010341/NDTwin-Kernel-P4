// [Co-developed with claude code -- Adam]
// The last step of `npm run build`: <static>/BUILD.json, which binds the committed bundle to the
// source it was built from (SCOPE-v2 section 2).
//
//   toolchain  the node and npm that ran this build
//   command    how to rebuild it
//   source     sha256 of EVERY file under tools/ndt_serve/web/ but node_modules/ and dist/ --
//              package-lock.json included -- keyed by its path from the repo root
//   bundle     sha256 of the four files the server serves from static/
//
// It also refuses a static directory that holds anything but those four and BUILD.json: the build
// writes there with emptyOutDir false, so a stray file would otherwise ride along unnoticed.
// Deterministic: keys sorted at every level, two-space indent, one trailing newline.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.NDT_SERVE_STATIC_OUT
  ? path.resolve(process.env.NDT_SERVE_STATIC_OUT)
  : path.resolve(web, '../static');
const SOURCE_PREFIX = 'tools/ndt_serve/web/';
const SKIP = new Set(['node_modules', 'dist']);
const BUNDLE = ['app.css', 'app.js', 'index.html', 'manual.html'];
const MANIFEST = 'BUILD.json';

const sha256 = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');

function walk(dir, rel, acc) {
  for (const name of readdirSync(dir).sort()) {
    if (rel === '' && SKIP.has(name)) continue;
    const abs = path.join(dir, name);
    const r = rel === '' ? name : rel + '/' + name;
    const st = lstatSync(abs);
    if (st.isDirectory()) walk(abs, r, acc);
    else if (st.isFile()) acc[SOURCE_PREFIX + r] = sha256(abs);
    else throw new Error('write-build-manifest: ' + abs + ' is neither a file nor a directory');
  }
  return acc;
}

function npmVersion() {
  const m = /(?:^|\s)npm\/(\S+)/.exec(process.env.npm_config_user_agent || '');
  if (m) return m[1];
  return execFileSync('npm', ['--version'], { encoding: 'utf8' }).trim();
}

function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v !== null && typeof v === 'object') {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])]));
  }
  return v;
}

const present = readdirSync(out).sort();
const extra = present.filter((f) => f !== MANIFEST && !BUNDLE.includes(f));
const missing = BUNDLE.filter((f) => !present.includes(f));
if (extra.length || missing.length) {
  throw new Error(
    'write-build-manifest: ' + out + ' must hold exactly ' + BUNDLE.join(', ') + ' and ' + MANIFEST +
      (extra.length ? '; it also holds: ' + extra.join(', ') : '') +
      (missing.length ? '; it lacks: ' + missing.join(', ') : ''),
  );
}

const manifest = sorted({
  toolchain: { node: process.version, npm: npmVersion() },
  command: 'npm ci --ignore-scripts && npm run build',
  source: walk(web, '', {}),
  bundle: Object.fromEntries(BUNDLE.map((f) => [f, sha256(path.join(out, f))])),
});
writeFileSync(path.join(out, MANIFEST), JSON.stringify(manifest, null, 2) + '\n');
console.log(
  'write-build-manifest: ' + path.join(out, MANIFEST) + ' (' + Object.keys(manifest.source).length +
    ' source files, ' + BUNDLE.length + ' bundle files)',
);
