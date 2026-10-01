// [Co-developed with claude code -- Adam]
// The page's build (SCOPE-v2 section 2 and 4). Output: EXACTLY index.html, app.js and app.css in the
// static directory ndt serve reads at start; scripts/build-manual.mjs adds manual.html and
// scripts/write-build-manifest.mjs adds BUILD.json and refuses any other file there.
//
//   * base './': the page refers to ./app.js and ./app.css and assumes nothing about where it is
//     mounted (section 10).
//   * one chunk, one stylesheet, fixed names: the server looks a path up in a table, it never joins
//     one onto a directory, so the file set must not depend on the build.
//   * no modulepreload polyfill and no sourcemap: nothing inline, nothing extra.
//
// NDT_SERVE_STATIC_OUT moves the output (the rebuild gate builds into a scratch directory and
// compares); by default it is ../static beside this directory.
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = process.env.NDT_SERVE_STATIC_OUT
  ? path.resolve(process.env.NDT_SERVE_STATIC_OUT)
  : path.resolve(here, '../static');

export default defineConfig({
  root: here,
  base: './',
  publicDir: false,
  plugins: [react()],
  build: {
    outDir,
    // The static directory also holds manual.html and BUILD.json, written after this step, and
    // nothing else: write-build-manifest.mjs fails the build on any other file it finds there.
    emptyOutDir: false,
    sourcemap: false,
    cssCodeSplit: false,
    modulePreload: { polyfill: false },
    assetsInlineLimit: 0,
    reportCompressedSize: false,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        chunkFileNames: 'app.js',
        assetFileNames: 'app.css',
        inlineDynamicImports: true,
      },
    },
  },
});
