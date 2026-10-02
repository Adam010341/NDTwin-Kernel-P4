// [Co-developed with claude code -- Adam]
// The log of the job Adam opened, read again every 2 s while it runs -- file reads on the server,
// never an ndt call. v1's three stop conditions (the orchestrator's condition, 09-27 15:4x), each
// written out once below and pinned by SourceLint:
//
//   1. the job ended:           job.state !== "running"  -> stop
//   2. the view was closed:     watching.current !== mine -> stop (Close, or the job opened again:
//                               every opening has its own token, and only the newest one reads)
//   3. the page is hidden:      await whileHidden()      -> nothing is read until it is shown again
import { useLayoutEffect, useRef, useState } from "react";
import { get } from "../api/client";
import type { Job, JobAnswer } from "../types";
import { errText } from "../lib/format";

export const JOB_LOG_INTERVAL_MS = 2_000;

// One opening of the job view. A new object per opening, even of the same job.
export interface JobOpening {
  id: string;
}

export interface JobLog {
  job: Job | null;
  stdout: string;
  stderr: string;
  error: string | null;
  following: boolean;
}

const EMPTY: JobLog = { job: null, stdout: "", stderr: "", error: null, following: false };

const sleep = (ms: number) => new Promise<void>((ok) => window.setTimeout(ok, ms));

// Resolves at once on a shown page; on a hidden one, when it is shown again.
function whileHidden(): Promise<void> {
  if (document.visibilityState !== "hidden") return Promise.resolve();
  return new Promise((ok) => {
    const shown = () => {
      if (document.visibilityState === "hidden") return;
      document.removeEventListener("visibilitychange", shown);
      ok();
    };
    document.addEventListener("visibilitychange", shown);
  });
}

export function useJobLog(opening: JobOpening | null, onEnded: (job: Job) => void): JobLog {
  const [log, setLog] = useState<JobLog>(EMPTY);
  const watching = useRef<object | null>(null); // the opening whose log is being followed
  const ended = useRef(onEnded);
  ended.current = onEnded;

  // A layout effect: a new opening clears the previous job's rows and log before the browser paints.
  useLayoutEffect(() => {
    if (opening === null) {
      watching.current = null;
      setLog(EMPTY);
      return;
    }
    const mine = {}; // this opening: closing the view, or opening a job again, replaces it
    watching.current = mine;
    setLog({ ...EMPTY, following: true });
    const id = encodeURIComponent(opening.id);
    const off = { stdout: 0, stderr: 0 };

    void (async () => {
      for (;;) {
        const r = await get<JobAnswer>("/jobs/" + id);
        if (watching.current !== mine) return; // stop 2: closed, or opened again
        if (r.status !== 200 || !r.json) {
          setLog((l) => ({ ...l, error: errText(r), following: false }));
          return;
        }
        const job = r.json.job;
        setLog((l) => ({ ...l, job }));
        for (const s of ["stdout", "stderr"] as const) {
          const lr = await get("/jobs/" + id + "/log/" + s + "?offset=" + off[s]);
          if (watching.current !== mine) return; // stop 2
          if (lr.status === 200) {
            const text = lr.text;
            setLog((l) => (s === "stdout" ? { ...l, stdout: l.stdout + text } : { ...l, stderr: l.stderr + text }));
            off[s] = Number(lr.headers.get("X-NDT-Log-Next-Offset") || off[s]);
          }
        }
        if (job.state !== "running") {
          // stop 1: the job ended
          setLog((l) => ({ ...l, following: false }));
          ended.current(job);
          return;
        }
        await sleep(JOB_LOG_INTERVAL_MS);
        await whileHidden(); // stop 3: nothing is read while the page is hidden
        if (watching.current !== mine) return; // stop 2
      }
    })();

    return () => {
      if (watching.current === mine) watching.current = null;
    };
  }, [opening]);

  return log;
}
