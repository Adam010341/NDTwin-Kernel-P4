// [Co-developed with claude code -- Adam]
// Text the page builds from an answer. Every word of it comes from the string table; what the
// server or ndt said is put in as it came.
import i18n from "../i18n";
import type { ApiResult } from "../api/client";
import type { ErrorBody, Job } from "../types";

export function errText(r: ApiResult<unknown>): string {
  if (r.status === 0) return i18n.t("ndtServe.err.noAnswer", { detail: r.text });
  const j = r.json as ErrorBody | null;
  if (j && typeof j.error === "string") return r.status + " " + j.error + (j.note ? " -- " + j.note : "");
  return r.status + " " + r.text.slice(0, 300);
}

export function busyText(busy: Job | null): string {
  return busy
    ? i18n.t("ndtServe.busy.held", { id: busy.id, kind: busy.kind, state: busy.state })
    : i18n.t("ndtServe.busy.free");
}

// stdout, then stderr under a marker when there is any: as the old page showed a read.
export function readText(stdout: string, stderr: string): string {
  return stdout + (stderr ? "\n" + i18n.t("ndtServe.lab.stderrMarker") + "\n" + stderr : "");
}
