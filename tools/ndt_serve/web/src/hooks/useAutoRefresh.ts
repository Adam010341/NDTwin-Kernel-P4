// [Co-developed with claude code -- Adam]
// Every 10 s, one read of /lab, /apps, /health and /jobs (Adam's R2, 09-27; SCOPE-v2 section 6):
// 24 requests and 12 ndt calls a minute while the page is shown and idle, and none while paused.
//
//   * No overlap: the next tick is armed only after the previous read has finished.
//   * paused-measuring: the last /lab said measuring_is_nothing === false, or declared !== null.
//     Only the manual 立即更新 resumes it: that does one read, and the timer comes back only if that
//     read shows nothing measuring (orchestrator's ruling on section 11, decision 2).
//   * paused-hidden: while document.visibilityState === "hidden". Shown again, the page reads once
//     at once and re-arms the timer -- unless the last read was measuring, which stays paused.
//   * What pauses it is a field the server computed; no ndt text is parsed here.
import { useCallback, useEffect, useRef, useState } from "react";
import type { LabAnswer } from "../types";

export const REFRESH_INTERVAL_MS = 10_000;

export type RefreshState = "running" | "paused-measuring" | "paused-hidden";

// The read: whatever the tick reads, and the /lab answer it got (null when /lab did not answer 200).
export type ReadAll = () => Promise<LabAnswer | null>;

function isMeasuring(lab: LabAnswer): boolean {
  return lab.measuring_is_nothing === false || lab.declared !== null;
}

export function useAutoRefresh(enabled: boolean, readAll: ReadAll, onFirstRead: () => void) {
  const [state, setState] = useState<RefreshState>("running");
  const [reading, setReading] = useState(false);
  const timer = useRef<number | null>(null);
  const inFlight = useRef(false);
  const measuring = useRef(false); // what the last /lab that answered said
  const live = useRef(false); // mounted and enabled
  const readRef = useRef(readAll);
  readRef.current = readAll;

  const disarm = () => {
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
  };

  const readOnce = async (): Promise<void> => {
    inFlight.current = true;
    setReading(true);
    try {
      const lab = await readRef.current();
      if (lab !== null) measuring.current = isMeasuring(lab);
    } finally {
      inFlight.current = false;
      setReading(false);
    }
  };

  // After a read: pause, or arm the next tick. The only place a timer is armed.
  const arm = () => {
    disarm();
    if (!live.current) return;
    if (measuring.current) {
      setState("paused-measuring");
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
    await readOnce();
    arm();
  };

  // 立即更新: always available, also while paused. One read; the timer comes back only if that read
  // shows nothing measuring (arm() decides). Every callee reads refs only, so [] is enough.
  const refreshNow = useCallback(async () => {
    if (!live.current || inFlight.current) return;
    disarm();
    await readOnce();
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
      // shown again: stay paused while the last read was measuring; otherwise read now, then re-arm
      if (measuring.current) {
        setState("paused-measuring");
        return;
      }
      if (timer.current === null && !inFlight.current) void tick();
    };
    document.addEventListener("visibilitychange", onVisibility);
    // the load: one read whatever the page's visibility (it is what the page shows), then the timer
    void (async () => {
      await readOnce();
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
