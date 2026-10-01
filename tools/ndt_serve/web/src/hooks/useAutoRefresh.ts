// [Co-developed with claude code -- Adam]
// Every 10 s, one read of /lab, /apps, /health and /jobs (Adam's R2, 09-27; SCOPE-v2 section 6):
// at most 24 requests and 12 ndt calls a minute while the page is shown and idle.
//
//   * No overlap: the next tick is armed only after the previous read has finished.
//   * paused-measuring: the last read said measuring_is_nothing === false, or declared !== null.
//     While it lasts, a probe reads /measuring and nothing else once every 60 s (Adam's Q6, 09-28:
//     an automatic probe after a measuring pause, read-only and light; and 10-01: it asks only "is
//     anyone measuring" -- `ndt status --measuring`, the claim's measuring= and the process table,
//     no sudo and no request to the kernel under measurement). No /lab, /apps, /health or /jobs.
//     The probe that reads nothing measuring and nothing declared brings the 10 s tick back.
//     立即更新 reads everything at once, paused or not.
//   * paused-hidden: while document.visibilityState === "hidden" nothing is read, tick or probe.
//     Shown again, the page reads once at once and re-arms the timer -- unless the last read was
//     measuring: then only the probe is armed again, and it reads 60 s later, not at once.
//   * What pauses it is a field the server computed; no ndt text is parsed here.
import { useCallback, useEffect, useRef, useState } from "react";
import type { MeasuringAnswer } from "../types";

export const REFRESH_INTERVAL_MS = 10_000;
export const PROBE_INTERVAL_MS = 60_000;

export type RefreshState = "running" | "paused-measuring" | "paused-hidden";

// A read, and the measuring reading it got (null when it did not answer 200): readAll is what the
// tick and 立即更新 read (its /lab answer), readProbe is the probe's /measuring alone. Both answers
// carry the server's one reading of ndt's measuring rows (serve.py measuring_fields).
export type Measuring = Pick<MeasuringAnswer, "measuring_is_nothing" | "declared">;
export type Read = () => Promise<Measuring | null>;

function isMeasuring(lab: Measuring): boolean {
  return lab.measuring_is_nothing === false || lab.declared !== null;
}

export function useAutoRefresh(enabled: boolean, readAll: Read, readProbe: Read, onFirstRead: () => void) {
  const [state, setState] = useState<RefreshState>("running");
  const [reading, setReading] = useState(false);
  const timer = useRef<number | null>(null);
  const inFlight = useRef(false);
  const measuring = useRef(false); // what the last read that answered said
  const live = useRef(false); // mounted and enabled
  const readRef = useRef(readAll);
  readRef.current = readAll;
  const probeRef = useRef(readProbe);
  probeRef.current = readProbe;

  const disarm = () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
  };

  const readOnce = async (read: Read): Promise<void> => {
    inFlight.current = true;
    setReading(true);
    try {
      const lab = await read();
      if (lab !== null) measuring.current = isMeasuring(lab);
    } finally {
      inFlight.current = false;
      setReading(false);
    }
  };

  // After a read: arm the next tick, or the probe, or nothing. The only place a timer is armed.
  const arm = () => {
    disarm();
    if (!live.current) return;
    if (measuring.current) {
      setState("paused-measuring");
      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);
      return;
    }
    if (document.visibilityState === "hidden") {
      setState("paused-hidden");
      return;
    }
    setState("running");
    timer.current = window.setTimeout(tick, REFRESH_INTERVAL_MS);
  };

  const tick = async () => {
    timer.current = null;
    if (!live.current || inFlight.current) return;
    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(readRef.current);
    arm();
  };

  // While paused-measuring: /measuring alone. arm() then brings the tick back or arms the next probe.
  const probe = async () => {
    timer.current = null;
    if (!live.current || inFlight.current) return;
    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(probeRef.current);
    arm();
  };

  // 立即更新: always available, also while paused. One read of everything; arm() then decides
  // between the tick and the probe. Every callee reads refs only, so [] is enough.
  const refreshNow = useCallback(async () => {
    if (!live.current || inFlight.current) return;
    disarm();
    await readOnce(readRef.current);
    arm();
  }, []);

  useEffect(() => {
    if (!enabled) return;
    live.current = true;
    const onVisibility = () => {
      if (document.visibilityState === "hidden") {
        disarm();
        if (!measuring.current) setState("paused-hidden");
        return;
      }
      // shown again: while the last read was measuring, the probe again (in 60 s, not now);
      // otherwise read now, then re-arm
      if (timer.current !== null || inFlight.current) return;
      if (measuring.current) {
        arm();
        return;
      }
      void tick();
    };
    document.addEventListener("visibilitychange", onVisibility);
    // the load: one read whatever the page's visibility (it is what the page shows), then the timer
    void (async () => {
      await readOnce(readRef.current);
      if (!live.current) return;
      onFirstRead();
      arm();
    })();
    return () => {
      live.current = false;
      disarm();
      document.removeEventListener("visibilitychange", onVisibility);
    };
    // onFirstRead is called once, from the load; the rest reads refs
  }, [enabled]);

  return { state, reading, refreshNow };
}
