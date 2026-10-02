// [Co-developed with claude code -- Adam]
// The page reports to the browser tests (tests/browser) through data-* attributes on <body>, and
// nowhere else. Never the token, never the one-time key.
//
//   data-href             location.href after the key was wiped from it
//   data-session          ok | refused | no-key
//   data-storage          {"local":N,"session":N,"cookie":"..."}
//   data-loaded           yes | no-session | no-meta
//   data-csp-violations   how many CSP violations the page saw ("0" from the start)
//   data-refresh          running | paused-measuring | paused-hidden
//
// This file is the ONLY code that touches localStorage, sessionStorage or document.cookie, and it
// only reads how much is there: the page itself keeps nothing in any of them.

export type HookName = "href" | "session" | "storage" | "loaded" | "cspViolations" | "refresh";

export function hook(name: HookName, value: string): void {
  document.body.dataset[name] = value;
}

export function storageHook(): void {
  hook(
    "storage",
    JSON.stringify({
      local: localStorage.length,
      session: sessionStorage.length,
      cookie: document.cookie,
    }),
  );
}
