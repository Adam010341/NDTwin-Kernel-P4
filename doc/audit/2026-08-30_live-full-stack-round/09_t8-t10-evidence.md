# 09 — T-8 and T-10 acceptance evidence

Every fix below is demonstrated in **both** directions: forced RED (the gate fires when the
defect's condition is present) and forced GREEN (the gate passes when it should). The
two-direction rule is FINDING-04's lesson: *an un-greenable gate is the mirror of an
un-reddable one*, and the harness README's old force-red table only exercised one side.

**Predictions were written into this file before any fix was run.** They are in §0 and are not
edited afterwards; §2 records what actually happened, verbatim, including where a prediction was
wrong.

Base: `09c9b03` ("Three manifest rows learn what the R2 bib round verified"), branch
`t8-t10-fixes`, isolated worktree. No fabric was started; `ndt up` / `ndt down` were never run.
All evidence is from `bash -n`, from library functions driven against fixtures, and from
extracted-logic harnesses that run the real code path with the surrounding script stubbed.

[Co-developed with claude code -- Adam]

---

## §0 PREDICTIONS — written 2026-08-30, before implementing or running anything

| # | fix | forced-RED prediction | forced-GREEN prediction |
|---|---|---|---|
| P1 | `ndt` model-matches-fabric reads the fabric | with model=4 and a fabric-side count of 128, the check prints `model/fabric mismatch` and sets rc=1 | with model=4 and fabric-side 4, prints `ok model matches fabric: 4 hosts` |
| P1b | same check when the fabric reading is **unobtainable** | fabric count 0 while the model wants 4 ⇒ must go RED with a message naming the reading as unobtainable, **not** pass | (n/a — the unobtainable case has no green; a green here would be the bug) |
| P2 | `ndt:759-760` stale comment | n/a (comment) — verified by reading that the corrected text no longer claims the check catches what it demonstrably did not | n/a |
| P3 | `app_running` via `/proc` instead of `kill -0` | a pidfile naming a live pid whose `comm` is NOT the app ⇒ `app_running` false (`kill -0` would say true) | a pidfile naming a live pid whose `comm` matches ⇒ true |
| P3b | same, root-owned pid | pidfile naming a live **root** pid of another program ⇒ false (today `kill -0` returns EPERM ⇒ false *for the wrong reason*; a root pid whose comm matches must read true) | pid 1 fixture whose comm is recorded ⇒ decided on comm, not on signal permission |
| P4 | `ndtwin-lab` KERNEL_DIR | n/a (documentation) | env override, if added, must not change behaviour when unset |
| P5 | sim disk log | after `sim-start`, `.test_run/logs/app_sim.log` exists and grows | if the tee path is unwritable the start must still proceed (log is evidence, not a gate) |
| P6 | `20_apps_lifecycle.sh` real epochs | a fixture where the app serves 200 s after `T0` but only 3 s into the wait loop ⇒ old code prints `+3 s`, new code prints `+200 s` | an app that serves 2 s after its own start ⇒ per-app `t_start` shows +2 s and the T0-relative column shows the true offset |
| P7 | `port_holder` three states | a LISTEN line with **no** `pid=` ⇒ must return the sentinel, and the caller must read "bound" | a LISTEN line with `pid=N` ⇒ returns `N`; no LISTEN line ⇒ returns empty ("free") |
| P8 | `lib.sh ndt_down` channel split | with a simulated 2 leftover processes, `REMAIN` is exactly `2` and the caller takes the `bad` branch | with 0 leftover, `REMAIN` is exactly `0` and the caller takes the `ok` branch — **this is the direction that is unreachable today** |
| P9 | `90_restore.sh` does not strand | a failed teardown check must still leave a recovery attempt or an explicit instruction; the script must not `exit 1` with the fabric down and nothing said | the success path reaches `ndt_up` as before |
| P10 | `40_r5_p4.sh` manifest count | a dict manifest keyed `s1..s10` ⇒ **10**, not 0; an unrecognised shape ⇒ raises, gate goes RED | a 10-key dict against 10 bmv2 procs ⇒ gate GREEN |
| P11 | `35_r2_r3_analyse.py` `find_paths` | a body keyed `all_destination_paths` ⇒ old code finds nothing, new code finds it and records the key used | a body keyed `path` ⇒ still found (no regression) |
| P12 | `25_apps_energy.sh` degraded banner | `POWERED_OFF=3` ⇒ banner printed | `POWERED_OFF=0` ⇒ banner **not** printed, and a "nothing to restore" line printed instead |
| P13 | `25_apps_energy.sh` watch window | a slow fixture (10 s of query time per iteration) ⇒ deadline loop still spans ~`WATCH_S`, and the script reports the span it actually achieved | a fast fixture ⇒ the loop does not exit early at fewer than `WATCH_S` seconds |

### Predictions that were expected to be uncomfortable

* **P8-green is the one that has never been observed.** FINDING-04 shows the `== "0"` branch is
  unreachable, so "the caller takes the `ok` branch" has no prior instance in this repo. If it
  does not go green after the fix, the fix is wrong.
* **P1b** has no green half by construction, and that asymmetry is deliberate: the requirement is
  "fail loudly when the fabric-side reading is unobtainable", so a green there would be the
  defect returning in a new shape.

---

## §1 What was NOT verified (stated before the results, so it is not a post-hoc excuse)

* **No live fabric.** Nothing here proves the fixed `ndt` check behaves correctly against a real
  128-host fabric; it proves the comparison now consumes a fabric-side quantity and fails when
  that quantity disagrees or is unobtainable. Live proof is deferred to the traffic round's
  preflight.
* **`port_holder`'s root case is fixture-verified, live proof deferred to the traffic round's
  preflight.** Producing a genuinely root-owned listener needs sudo and a fabric; the three-state
  logic is driven against recorded `ss` output instead.
* **The installed `/usr/local/sbin/ndtwin-lab` is untouched** (root owned). Every fix here lands
  in the repo copies only. See §3 for what that means for when each fix takes effect.

---

## §2.1 — T-8 (1): `model matches fabric` now reads the fabric (FINDING-01)

`tools/test_workflow/ndt`, `verify_p4()`. The fabric-side reading chosen is
**`fabric_host_count()`** — host namespaces counted out of `ps`. Justification is in the code
comment; in short: it is the quantity FINDING-01 counted by hand to establish the defect (128),
it is already the reader that decides fabric reuse and gates the OVS build so the fix adds no
third opinion, the manifest is keyed by switch and cannot answer a host question at all, and
veth count needs a per-topology constant to interpret.

**Unobtainable is RED.** `fabric_host_count` returns 0 when `ps` yields nothing or when the
`mininet:h<N>` argv convention changes; a fabric this function just built always has ≥1 host, so
0 means the reading failed, and a failed reading must not print `ok`.

### Method

The comparison block is extracted **verbatim from the shipped file by `sed`** and `eval`'d with
`fabric_host_count` stubbed — that stub is the seam, since the whole finding is that the real
function was never called. Harness:
`scratchpad/t8_check.sh`.

⚠️ The first extraction anchored on `local live_hosts; live_hosts="$(fabric_host_count)"`, which
is **not unique** — `up_p4` has a byte-identical line — and it pulled the reuse block instead.
It failed loudly (`topo_session: command not found`, `n: unbound variable`) rather than testing
the wrong code and reporting green. Re-anchored on the comment sentence above the block.

### Forced RED and GREEN — verbatim

```
### FORCE-RED   model 4 vs fabric 128 (the exact 08-30 false pass)   (fabric=128 kernel_graph=4 topo_file=4)
  XX  model/fabric mismatch: kernel graph has 4 hosts, topology file has 4, the FABRIC has 128 host namespaces
    -> rc=1

### FORCE-RED   fabric reading unobtainable (count 0)   (fabric=0 kernel_graph=4 topo_file=4)
  XX  model/fabric UNCHECKED: no fabric-side host count obtainable (fabric_host_count gave '0').
  XX    the kernel graph says 4 hosts and the topology file says 4, but neither is the fabric.
  XX    this is reported as a failure on purpose: an unverifiable check must not print ok.
    -> rc=1

### FORCE-RED   fabric reading not a number   (fabric= kernel_graph=4 topo_file=4)
  XX  model/fabric UNCHECKED: no fabric-side host count obtainable (fabric_host_count gave '<empty>').
  XX    the kernel graph says 4 hosts and the topology file says 4, but neither is the fabric.
  XX    this is reported as a failure on purpose: an unverifiable check must not print ok.
    -> rc=1

### FORCE-GREEN model 4, fabric 4, topo 4   (fabric=4 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
    -> rc=0

### FORCE-RED   kernel graph disagrees with topo file   (fabric=4 kernel_graph=4 topo_file=8)
  XX  model/fabric mismatch: kernel graph has 4 hosts, topology file has 8, the FABRIC has 4 host namespaces
    -> rc=1
```

### The control that makes the RED mean something

"It goes red now" is not evidence unless it could not go red before. The pre-fix block, copied
verbatim from `09c9b03:tools/test_workflow/ndt:722-727`, against the same three inputs:

```
### OLD CODE, model 4 vs fabric 128 (the 08-30 false pass)   (fabric=128 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0

### OLD CODE, fabric reading unobtainable (count 0)   (fabric=0 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0

### OLD CODE, fabric 4 (correct)   (fabric=4 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0
```

🔑 **Three different fabrics, one identical line.** That is the finding restated as a
measurement: the old check's output is independent of its subject.

Predictions P1 and P1b: **both held**, 5/5 cases.

### T-8 (2) — the stale comment at `ndt:759-760` (now :786-808)

Corrected in the same commit. The old text recorded the 08-21 measurement
(`ndt up ovs 16` → `"model matches fabric: 16 hosts"` over a 128-host fabric) purely as a reason
to refuse odd sizes, which reads as though the check worked for the sizes that *are* allowed.
It did not. The correction says plainly that the recorded line is evidence about the **check**,
not only about the size argument, and points at the two repairs (`verify_p4` now reads
`fabric_host_count`; `verify_ovs`'s equivalent was already renamed to *"kernel graph matches the
model file"* because for host count it is close to tautological).

The contradiction named in the ticket is confirmed by reading: `verify_ovs`'s comment
(`ndt:940-945` pre-fix) already said the name *"claimed a guarantee it does not give"* — while
`verify_p4` four hundred lines earlier still claimed it was *"the check that would have caught a
wrong TOPO_P4"*. The OVS arm was corrected on 08-21 and the P4 arm was not.

`ndt:1141`'s historical sentence (*"the kernel's graph, Ryu's topology view and 'model matches
fabric' were all correct and every host pair was 100% loss"*) was **left alone**: it is a
statement about what happened on 08-21 under the name the check had then, and it remains true.
