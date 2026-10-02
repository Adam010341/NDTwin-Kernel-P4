// [Co-developed with claude code -- Adam]
// The only way out of this page (SCOPE-v2 section 10). What SourceLint holds this file to:
//
//   * fetch is called here and nowhere else, and the token header is set here and nowhere else.
//   * The token lives in ONE module-level variable: never in storage, a cookie, the DOM or a URL.
//     The only code that hands it in is api/session.ts, after trading the one-time key.
//   * get reads; post writes, and post is called only from components/ConfirmDialog.tsx --
//     a fresh GET /lab, the server's own dry run, and a dialog Adam confirms.
//   * The base is set at build time (VITE_NDT_SERVE_API_BASE); by default it is ./api/v1, the
//     server's own origin, relative to wherever the page is mounted.

export interface ApiResult<T = unknown> {
  status: number; // 0: no answer at all
  json: T | null;
  text: string;
  headers: Headers;
}

const BASE: string = import.meta.env.VITE_NDT_SERVE_API_BASE ?? "./api/v1";

let token: string | null = null; // the only copy the page has

// Called once, by api/session.ts, with what POST /session answered.
export function holdToken(t: string): void {
  token = t;
}

// Internal: get and post below, and api/session.ts's one trade of the key.
export async function call<T = unknown>(
  method: "GET" | "POST",
  path: string,
  body?: Record<string, unknown>,
): Promise<ApiResult<T>> {
  const headers: Record<string, string> = {};
  if (token !== null) headers["X-NDT-Token"] = token;
  const init: RequestInit = {
    method,
    headers,
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
  };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  let r: Response;
  try {
    r = await fetch(BASE + path, init);
  } catch (e) {
    return { status: 0, json: null, text: String(e), headers: new Headers() };
  }
  const text = await r.text();
  let json: T | null = null;
  if ((r.headers.get("Content-Type") || "").startsWith("application/json")) {
    try {
      json = JSON.parse(text) as T;
    } catch {
      json = null;
    }
  }
  return { status: r.status, json, text, headers: r.headers };
}

export function get<T = unknown>(path: string): Promise<ApiResult<T>> {
  return call<T>("GET", path);
}

export function post<T = unknown>(path: string, body: Record<string, unknown>): Promise<ApiResult<T>> {
  return call<T>("POST", path, body);
}
