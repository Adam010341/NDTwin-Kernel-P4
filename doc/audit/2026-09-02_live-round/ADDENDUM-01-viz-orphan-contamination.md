# Addendum 01 — an orphaned viz JVM was running beside most of this round

Written 2026-09-03 00:40 by the auditor. **This changes how parts of the round's evidence must
be read**, so it is filed beside CHECKPOINT.md rather than inside it.

## What was found

At 23:38, while the round was already over, two `java` processes were still running:

```
pid 893609  ppid 2859    elapsed 01:54:08   1.2% cpu    9.5 MB   java   (wrapper)
pid 893799  ppid 893609  elapsed 01:54:07   111% cpu   247 MB    java   (the viz JVM)
```

They had been alive since **21:44**, i.e. from step C27 onward. The viz app was in a redraw loop
logging every frame at DEBUG:

```
[DEBUG] TopologyCanvas.draw() - nodes: 14, links: 40, flows: 0
[TOP-K] drawRealtimeFlows: Processed=0, Filtered=0, Shown=0
```

`.test_run/logs/app_viz.log` had reached **875,463,322 bytes (835 MB)** and was still growing;
the filesystem is at 85% (15 GB free). Stopped by the auditor with `kill -TERM` on the exact
pids (893799 then 893609); both exited, and the log stopped growing.

The log was afterwards compressed in place to `.test_run/logs/app_viz.log.gz` (875,463,322 ->
23,695,327 bytes) because the filesystem was at 85%. Nothing was deleted; the first 2 KB is also
kept separately as a sample. If you are looking for `app_viz.log`, that is where it went.

## Why nothing noticed

`ndt apps stop viz` sends TERM to a single pid — the bash wrapper — and `app_spawn` does not put
the app in its own process group or use `setsid`, so the JVM it launched survives and is
reparented. Afterwards **every liveness channel agreed that viz was not running**:
`ndt status`, `ndt apps orphans`, and `raw/D1_teardown.log` (which records
`viz not running (no live instance found by pid or by scan)`).

This is the same false-ok family as finding 1 in CHECKPOINT.md §(c), but the more dangerous
direction: there, a tool claimed to have stopped something that was never started; here, a tool
claimed to have stopped something that kept running for two hours at over one core.

## What it means for this round's evidence

- **Anything measured from C27 (21:44) onward was measured beside a >100% CPU load**, including
  `C47_cpu_under_load.log` and `cpu/cpu_under_load.jsonl`. Those are not invalid — but the
  baseline they should be compared against is `B21_cpu_probe_idle.log`, taken at 21:1x, i.e.
  **before** the orphan existed. Any conclusion of the form "the fabric costs N% CPU" that
  subtracts B21 from a post-C27 measurement is overstated by roughly one core.
- Timing-sensitive steps after C27 (the fault rounds, the R-5 runs, the A-4c windows) ran on a
  machine with one core permanently occupied. Nothing observed there should be treated as a
  clean-machine timing.
- The three bmv2 switches that disappeared mid-round (C30) were traced to the Energy-Saving-App
  and that attribution is unaffected — it was confirmed from the app's own actions, not from
  resource pressure.

## Two defects to register

1. **`ndt apps stop` does not stop the app** — it stops the wrapper. The child survives, is
   reparented, and every liveness channel then reports it as gone. Fix direction: launch apps in
   their own process group / session and signal the group, or record the real child pid.
2. **The viz app burns a full core while idle and logs every frame at DEBUG** — 875 MB in
   1h54m on an idle 14-node topology with zero flows. On a machine at 85% disk this is a
   disk-filler as well as a load source.

Both are separate from the `ndt apps start`/`stop` false-ok already recorded as G-6.
