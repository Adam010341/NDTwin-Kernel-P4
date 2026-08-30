# Finding 02 — the R-3 convergence table mostly measures the harness, not the stack

**Status: CONFIRMED, first live run of the harness, 2026-08-30 15:06–15:18.** Two independent
defects in `20_apps_lifecycle.sh`, both found by reading the artefacts the run produced.
Class: **defects in the instrument**, per the harness README's own instruction —
*"Treat the first run's disagreements as findings about the harness until shown otherwise."*

🔑 This is `memory: new-tools-are-the-first-thing-under-test` landing again: the chaos harness's
first live run produced thirteen defects, all in the harness. This one produced two before it
produced a single statement about NDTwin.

---

## The table as printed

```
T0 (ndt up invoked)   1788073422
sim    DID NOT SERVE         -        -
nsr    first served at   1788073646   (+224 s)
viz    first served at   1788073427   (+5 s)
te     first served at   1788073423   (+1 s)
apps serving: 3 of 4
FAIL  R-3 BREAK CONDITION MET: 3 of 4 apps converged.
```

**Three of these four rows are wrong, in two different ways, and both errors flatter the
result.**

---

## Defect A — a loop counter used as a clock, added to an unrelated epoch

`20_apps_lifecycle.sh:198-204` (viz), `:245-252` (te), `:141-147` (sim):

```bash
for i in $(seq 1 300); do
    if [[ -s "$VIZ_LOG" ]] && grep -qiE 'topolog|graph|node|edge' "$VIZ_LOG"; then
        VIZ_T=$(( T0 + i )); break
    fi
    sleep 1
done
```

`i` is **which iteration of this loop matched**. `T0` is when `ndt up` was invoked. The loop
does not start at `T0` — it starts when the script reaches the viz section, which is minutes
later. `T0 + i` adds two quantities with no common origin.

Only `nsr` escapes: `:165` uses `first_serve_epoch "$NSR_DIR/recorded_info" "$T0"`, which reads
real file times. **The one row computed from a clock is the one that produced a large,
plausible number.**

### What the numbers should have been

Recoverable from the harness's own H-20 artefact signatures, which record each log's mtime at
the moment of the check:

| app | printed | log signature the harness recorded | true, from that mtime | error |
|---|---|---|---|---|
| viz | **+5 s** | `1788073651` | **≈ +229 s** | ~46× |
| te | **+1 s** | `1788073653` | **≈ +231 s** | ~231× |
| nsr | +224 s | — | +224 s (unchanged) | correct |

🔑 **All three real numbers cluster at ≈ +224…231 s, and that is the finding underneath the
finding.** `20_apps_lifecycle.sh` began at `T0+158 s` and spends its first ~60 s in sim's wait
loop, so it does not reach nsr, viz and te until ≈ `T0+220 s`. What the table measures is
**when the harness got round to starting each app** — the harness's own sequencing dominates
every row.

⇒ PREREG §3's R-3 — *"convergence time from `ndt up` to all five apps serving"* — is **not what
this table contains**, even after Defect A is fixed. The registered break condition (failure to
converge) is still answerable; the seconds are not attributable to the stack.

⚠️ And per AMENDMENT-1 the 08-18 references (69 s OVS / 2 s P4) are `T_stack`, so they were
never comparable to this column anyway. `T_stack` this round = **16 s**, derived separately.

## Defect B — `port_holder` is blind to root-owned listeners, and sim is started as root

`lib.sh:358-363`:

```bash
port_holder() {
    out="$(ss -lptnH "sport = :$port" 2>/dev/null || true)"
    [[ -n "$out" ]] || { printf ''; return 0; }
    printf '%s' "$out" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}
```

Run unprivileged, `ss` prints the LISTEN line for a socket owned by another user but **omits
the `users:(("…",pid=N,…))` field**. So `out` is non-empty (no early return) and the `pid=`
grep finds nothing: the function returns empty **while something is listening**.

`20_apps_lifecycle.sh:142` tests `[[ -n "$(port_holder 9000)" ]]`, so the sim loop cannot
succeed for a root-owned listener no matter how promptly sim binds. sim is started through
`ndtwin-lab`'s NOPASSWD verb, in a **root** tmux session.

### Demonstrated live, with a positive control

```
ss -ltnH 'sport = :9000'      -> [LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:*]   (a listener exists)
port_holder 9000              -> []                                        (the harness sees none)
port_holder 8000              -> [284117]                                  (positive control)
```

The control is the load-bearing half: `port_holder` **works** for a socket this uid owns (my own
kernel on :8000), so the empty result on :9000 is about ownership, not about a broken function.

### Consequence, stated as strictly as the evidence allows

`sim  DID NOT SERVE` is **uninformative**. It is not evidence that sim failed to serve, and it
is not evidence that it did.

What is established:

* `:9000` had **no** listener at preflight (14:53, `PASS :9000 is free`);
* `:9000` **has** a listener now, answering `HTTP 400` to `GET /`;
* everything that could have created it happened inside this round.

**When sim bound is unknown**, and no number should be written for it.

🔴 **This retracts my own correction to the auditor**, sent 15:16, which said sim bound "late,
somewhere in (15:07:20, 15:14]". That interval was derived from the 60 s window having expired
— i.e. from the very check now shown to be incapable of closing. The interval is withdrawn;
only the two bullets above survive.
🔑 *A bound inferred from a blind instrument is not a bound.*

## Both errors point the same way

| | direction |
|---|---|
| Defect A | convergence looks **faster** (+1 s, +5 s instead of ≈ +230 s) |
| Defect B | a failure looks **attributable to the app** rather than to the instrument |

`memory: the-clean-version-is-the-one-to-recheck` — the error direction is again "the version
that is easier to report".

## Two things that came out clean, recorded so the report is not one-sided

**1. viz's un-calibrated pattern did *not* produce a false positive.** The harness warned that
`'topolog|graph|node|edge'` was reconstructed rather than copied and that a viz PASS is weak
evidence. Checked against the real log: the match is viz's own runtime output
(`[DEBUG] TopologyCanvas.draw() - nodes: 14, links: 40, flows: 0`), not Maven boilerplate, and
viz drew the correct topology — **27 262** draws at `nodes: 14, links: 40` (= 10 switches +
4 hosts, 40 links, matching the kernel graph) against **24** at zero, all at startup.
The warning was right to exist and the pattern happened to be sound. A real line is saved to
`raw/20260830-t4-p4/viz_real_output_for_pattern_calibration.log` for the post-round fix.

⚠️ I first read the log's Maven tail and concluded the PASS was Maven-matched. **Wrong, and
withdrawn** — checking the actual matching lines took one grep and reversed it.

**2. viz exits on its own.** `mvn` reports `BUILD SUCCESS / Total time: 05:30 min / Finished at
2026-08-30T15:12:58`, and `app_viz.pid` (286486) has no `/proc` entry. viz ran ~5.5 min from
15:07:31 and stopped. Later phases must not assume it is still up.

## Not fixed during the round

Both defects are in the instrument, and the instrument is mid-measurement. Changing `lib.sh`
between phases would mean earlier and later phases were measured with different rulers — the
same reason `ndt` was left alone in FINDING-01. The repairs, for afterwards:

* **A** — take a wall-clock reading (`date +%s`) at the match, not `T0 + i`; and record a
  per-app `t_start` so the app's own convergence can be separated from the harness's sequencing.
* **B** — decide "is anything listening" from the LISTEN line's presence (which is visible), and
  treat the pid as optional metadata. A pid-less line is *a listener whose owner is not visible*,
  which is a third state the current code collapses into "nothing there".

[Co-developed with claude code -- Adam]
