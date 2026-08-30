# Finding 01 — `ndt up`'s "model matches fabric" check never reads the fabric

**Status: CONFIRMED, observed live 2026-08-30 14:55–15:02, with the failure and the fix both
reproduced.** Round: T-4 (`PREREG.md`). Class: R-4 ("the unknowns" — no prediction registered).

---

## The one-line version

```
ok  model matches fabric: 4 hosts
```

was printed over a fabric with **128 host namespaces**, by a check whose own comment says it is
*"the check that would have caught a wrong TOPO_P4 — a 4-host model against a 128-host fabric."*

## What was observed

`ndt up p4 4` completed with every structural check green and one red:

| line | value |
|---|---|
| `ok  kernel: 10 switches, 10 up, 40 edges, 4 hosts` | model side |
| `ok  model matches fabric: 4 hosts` | **the false pass** |
| `XX  data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding` | the only red |

Counted from the namespaces themselves — the quantity the check never consults:

```
$ ps -eo pid=,args= | (count args ending in "mininet:h*")
128
```

`h1 … h128`, each `10.0.0.<n>/24`. Raw evidence:
`raw/20260830-t4-p4/mismatch-evidence/{ndt_up_p4_4.log,ndt_status_during_mismatch.txt,fabric_host_namespaces.txt}`.

## Why it cannot fail — read from source, not inferred

`tools/test_workflow/ndt:709-723`:

```bash
want_hosts="$(python3 -c '
import json,sys; t=json.load(open(sys.argv[1]))
print(sum(1 for n in t["nodes"] if n.get("vertex_type")==1))' "$topo")"
...
if [[ "$hosts" == "$want_hosts" ]]; then
    ok "model matches fabric: $hosts hosts"
```

`$hosts` comes from the kernel's graph. `$want_hosts` comes from `$topo`, the topology JSON the
kernel was handed. **Both sides are the model.** No fabric-side quantity — not a namespace
count, not a veth count, not the manifest — appears anywhere in the comparison.

🔑 The criterion this fails is the project's own: *if the thing it checks were completely
broken, would this line go red?* It cannot, because a fabric of any size is invisible to it.
The name "model matches fabric" describes an intent the code does not implement.

### This was already measured once, in the same file, and the comment was not corrected

`ndt:759-760`, about the OVS path:

> measured 2026-08-21, `ndt up ovs 16` gave "model matches fabric: 16 hosts" over a 128-host
> fabric with 160 veths.

So the identical false pass was observed on the OVS arm eleven days ago and written down four
lines away from the P4-side check that still claims to catch it.
🔑 *A defect recorded next to the code is not a defect fixed*, and a comment asserting a
capability outlives the measurement refuting it unless someone edits the comment.

### `ndt status` had the answer five lines apart and said nothing

```
configuration
  hosts          4          <- model
running
  host/switch    138        <- fabric: 128 hosts + 10 switches
```

The two numbers are in one output, in one screen, and nothing correlates them. The fabric-side
quantity **exists and is already being collected**; it is simply never compared to the model.

## What produced the mismatch here — my configuration, stated plainly

This round pins the kernel to `89c1754` in a separate worktree (`BASELINE-PROVENANCE.md`), with
`KERNEL_DIR` exported so `ndt`, `stack.sh`, `components.env` and the harness all read it.

That is not sufficient, and my commit `7dbda34` says it is. **Correction:**

> `/usr/local/sbin/ndtwin-lab` — root-owned, installed 2026-08-17, byte-identical to
> `tools/test_workflow/ndtwin-lab` (`3aaa849e…`) — **hardcodes** `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`
> at line 25. It is outside the reach of the environment variable of the same name.

So `topo-start` ran the **main tree's** `ntg_bmv2_topo.py`, which read the **main tree's**
`host_count_override` = `128`; while `ndt up p4 4` wrote `4` into the **worktree's** copy, and
the worktree kernel was handed the 4-host model. Fabric 128, model 4.

⚠️ **The guard that exists for this is single-tree by construction.** `p4_testbed_topo.py:99-117`
was added on 2026-08-21 for exactly this mismatch and refuses when the explicit topology
override disagrees with the host count — but *"both sides read that count separately"* means
both sides read it **from the same checkout**. Two checkouts is a case it was never shaped to
see. The guard is not wrong; its scope is narrower than its subject.

## The fix, and the proof that it was the fix

`host_count_override` set to `4` in **both** trees, `ndt down`, `ndt up p4 4` again:

| | run 1 (128 vs 4) | run 2 (4 vs 4) |
|---|---|---|
| switches up | 10, after **36 s** | 10, after **5 s** |
| host namespaces | **128** | **4** |
| `model matches fabric` | `ok` (false) | `ok` (true) |
| data plane h1→10.0.0.2 | **cannot reach** | **forwards** |
| verdict line | `up, but not verified -- do not measure on this` | `up. ready` |

The forwarding failure is fully accounted for. Nothing about bmv2, the P4 pipeline or the
proxy was at fault.

🔑 **Only one line in that table changed for the right reason.** `data plane` went red and then
green because it moves a packet; `model matches fabric` said `ok` in both columns and carried
no information in either. The one honest check in `ndt up` is the one the file itself describes
as *"the only assertion in this script that moves a packet"*.

## Before believing the red, the instrument was controlled

The forwarding failure looked exactly like **T2-1**, retracted on 08-29 after it turned out to
be three of my own defects (H-17 `kill -0` EPERM, H-22 `$!` naming a subshell and leaving an
orphan proxy on :8081, H-23 a backwards grep). So it was not reported until:

1. **retried** — 5 attempts over 13 s, all failed ⇒ not a warm-up window
   (`memory: punt-window-host-learning` would predict one);
2. **positive control** — `ping` from h1 to h1's own `10.0.0.1` **succeeded** ⇒ the `mnexec`
   instrument works;
3. **the target was shown to exist** — `10.0.0.2` is h2, present, with a `PERMANENT` static ARP
   entry in h1's table ⇒ not an H-19 "404 for the wrong reason";
4. only then was the fabric-side count taken, which is what actually explained it.

Steps 1–3 cost about ninety seconds and are the difference between this finding and the
retracted one.

## Suggested repair — not applied, because `ndt` is not this round's subject

Compare against something the fabric produces. All three are already on hand at that point:
the host-namespace count (`ndt status` computes it as `host/switch`), the switch manifest
`/tmp/ndtwin_p4_switches.json`, or the veth count. Any one of them makes the line able to fail.

Second, weaker but free: `ndt status` should refuse to print `hosts N` beside
`host/switch M` without checking `M - switches == N`.

**Both are `ndt` changes and `ndt` is the instrument, not the subject, of T-4.** Filed here for
whoever owns the tooling; not fixed mid-round, because changing the instrument during the run
it is instrumenting is how a round loses its own baseline.

## Bookkeeping

- Main-tree `p4_proxy/mininet/host_count_override` was `128` before this round and is a
  **tracked** file. It now reads `4`. **Restore to `128` at round end** — recorded in
  `scratchpad/host_count_override.restore` and in the restore step of this round.
- `7dbda34`'s claim that one export makes everything agree is corrected above and must not be
  quoted without this file.

[Co-developed with claude code -- Adam]
