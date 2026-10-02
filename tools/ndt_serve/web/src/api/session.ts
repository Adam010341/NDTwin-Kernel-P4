// [Co-developed with claude code -- Adam]
// Getting in (SCOPE section 3 of the GUI cut, unchanged in v2). The URL the server prints carries a
// ONE-TIME key in its #fragment -- never the token. The fragment leaves the address bar FIRST, before
// anything else happens; then the key is traded for the token, exactly once, and the token goes to
// api/client.ts's one variable. Reloading the page ends the session.

import { call, holdToken } from "./client";
import type { ApiResult } from "./client";
import { hook } from "../testhooks";

export type SessionOutcome =
  | { state: "ok" }
  | { state: "no-key" }
  | { state: "refused"; answer: ApiResult<unknown> };

const KEY_RE = /^#k=([A-Za-z0-9_-]{16,64})$/;

let opening: Promise<SessionOutcome> | null = null;

// However many times it is called, the key is traded at most once: a second call gets the first
// call's answer, and the address bar is wiped before anything else.
export function openSession(): Promise<SessionOutcome> {
  if (opening !== null) return opening;
  const hash = location.hash;
  history.replaceState(null, "", location.pathname + location.search); // the key leaves the address bar first
  hook("href", location.href); // for the browser tests: the address as it is now, with no key
  const m = KEY_RE.exec(hash);
  opening = m ? trade(m[1]) : Promise.resolve<SessionOutcome>({ state: "no-key" });
  return opening;
}

async function trade(nonce: string): Promise<SessionOutcome> {
  const r = await call("POST", "/session", { nonce });
  const j = r.json as { token?: unknown } | null;
  if (r.status !== 200 || !j || typeof j.token !== "string") {
    return { state: "refused", answer: r };
  }
  holdToken(j.token);
  return { state: "ok" };
}
