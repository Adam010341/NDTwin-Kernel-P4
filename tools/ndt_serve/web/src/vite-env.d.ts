// [Co-developed with claude code -- Adam]
/// <reference types="vite/client" />

interface ImportMetaEnv {
  // Where the API is, relative to the page. Set at build time only; the default is ./api/v1, the
  // server's own origin (SCOPE-v2 section 10: the one thing to change when the page moves).
  readonly VITE_NDT_SERVE_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
