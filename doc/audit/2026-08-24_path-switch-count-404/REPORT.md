# P1-3: the 404 reproduces, and it is a startup transient — plus a worse finding underneath it

[Co-developed with claude code -- Adam]

Run 2026-08-24 at `a327d5a`. Raw: `repro_404.txt`, `raw/`. Driver: `repro_404.sh`.

Note the recorded series was sampled at **12 s** (`GAP=12` on the invocation); the driver's
in-file default is 15 s, so a bare re-run will not line up with these timestamps.

## The 404 reproduces

It was last recorded as "did not reproduce, n=1". It reproduces:

| sample | HTTP | note |
|---|---|---|
| 1 | **404** | first query after boot |
| 2–10 | 200 | every subsequent query |

**One 404, and it is the first sample after the fabric came up.** Nine consecutive successes
followed at 12-second intervals. That is a different shape from the theory it was filed under.

The suspected cause was the non-monotonic `all_destination_paths` fetch — a snapshot taken in a
trough missing pairs, which would produce 404s scattered anywhere in the series. What actually
happens is a single failure at the front, then nothing. The kernel populates its path map from a
control-plane fetch on a timer; immediately after boot that map is empty or partial, and the
first query arrives before it is filled. This also explains the original 2026-08-21 observation
without needing the trough at all: the contract harness runs right after bring-up, so it queries
in exactly the window where the map is not yet there.

**Not yet proven**, and the honest gap: I did not catch the map mid-fill and watch it populate.
The evidence is the position of the failure in the series, which is strong but circumstantial.

### The column that was supposed to discriminate measured nothing

`repro_404.sh` records `paths_known` beside each sample, specifically so a 404 could be checked
against the path count at that instant. It reported **2** on every row, including the 404 and all
nine successes. Two paths on a 128-host fabric is not a number anyone should accept: the
extractor takes `len()` of the endpoint's JSON, which counts top-level keys rather than paths.

So the discriminator this run was designed around produced a constant, and the shape conclusion
above rests entirely on *where* the 404 fell in the series. The column is left in the raw output
rather than quietly dropped, because a plausible-looking constant in an evidence table is the
failure mode worth being able to point at later.

## 🔴 The finding that matters more: default OVS bring-up is failing often

Of the boots attempted across the two P1-3 runs, with **no** environment overrides at all:

| run | boot 1 | boot 2 | boot 3 |
|---|---|---|---|
| first | up | **FAILED** | (killed mid-run) |
| second | **FAILED** | up | **FAILED** |

⚠️ **The first run's rows exist only in prose** (review correction C-1b). `repro_404.sh`
reused per-boot filenames, so re-running it overwrote the first round's transcripts — including
the one a correction block in the loaded-fp report had cited as evidence, which briefly left
that citation pointing at a *successful* boot. The driver now archives each run under a sequence
number. The second run's rows are on disk; the first run's are not.

Three of five boots with a known outcome did not converge, every one with the same signature:

```
XX  kernel: 10 switches, 0 up, 0 enabled (want 10)
ok  kernel graph matches the model file: 128 hosts, 288 edges
XX  data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding
```

Two things follow, and they point in opposite directions from what has already been written down:

1. **It is not the LLDP backoff.** `2026-08-22_loaded-fp-study/REPORT.md` blamed exactly this
   signature on `NDTWIN_RYU_LLDP_BACKOFF=10`, from one failure in the cell that carried the knob
   and no defaults control. That report is corrected in place. The failure happens with no knobs
   set.
2. **`settle=40` may be marginal, and the bisection that chose it was n=1 per cell.**
   `settle_bisect.txt` tested 15/20/30/40/55/90 with a single boot each and 40 three times, all
   green, and the default was set on that. Today's rate is far worse than that curve implies.
   Either something else changed, or one boot per cell was not enough to see a failure mode that
   shows up at roughly half. The bisection cannot distinguish those, because it never repeated a
   cell enough times to measure a rate.

**This is an open defect, not a closed one**, and it is upstream of several conclusions from this
week: the settle default, the OVS boot time quoted for the 8/27 deck (52 s — measured only on
boots that succeeded), and any L4 baseline captured at the default.

Recommended next step, in this order: repeat a single configuration ~10 times to get an actual
failure rate before trusting any per-cell result; then diff a failing boot's `ryu.log` against a
succeeding one, since "0 up, 0 enabled" with a complete model graph says the switches connected
and the topology loaded but link discovery did not.

## Status

P1-3's question — "is the 404 real?" — is answered: **yes, reproducibly, as a first-query-after-boot
transient.** Whether to fix it or allowlist it is now a smaller decision than the bring-up
instability sitting underneath it, and I would not spend the fix on the 404 first.
