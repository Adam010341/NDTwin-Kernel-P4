# Who owns the 291 seconds? Re-adjudicating the unidirectional-link failure

**2026-08-19.** The record carried a striking claim: a unidirectional link failure blackholed
for **291 s with zero self-heal**, filed as the strongest item in the "baseline defects fixed"
section of the progress report. This round asks whether that attribution is correct, and
measures what the inherited router actually does.

**In one line:** the crashing line is inherited, but it was **unreachable** until a commit of
our own made it reachable — so the 291 s was measured on our own intermediate code, not on the
baseline. The inherited router has a different and simpler failure: it never reroutes at all,
now measured for the first time.

[Co-developed with claude code -- Adam]

---

## 1. Why this was re-opened

Adam raised it directly: *"I remember we measured that halfway through changing the code —
maybe the 291 s is our own problem."* The adjudication table (template §A2) had it as a
baseline defect on the grounds that `intelligent_router.py` is the lab's pre-existing Ryu
control program. That reasoning is about the **file**, not about the **defect**.

## 2. What the evidence shows

### 2.1 The file is inherited, but it never entered the baseline tree

`intelligent_router.py` is **not in `28b8b13`** (`git ls-tree 28b8b13` → no match). It arrived
with `6f32bca`, Adam's first commit. Between `6f32bca` and the fix `034da18` it was modified
**six times**, all by Adam.

### 2.2 The crashing line IS inherited

At `6f32bca`, `install_all_pair_paths` already contained:

```python
out_port = net[current_switch][prev_switch]["port"]
```

The BFS reaches `current_switch` from `prev_switch`, then looks up the **reverse** edge for the
output port. **This assumes the DiGraph is symmetric.** That line is unmodified inherited code.

### 2.3 …but nothing could reach it

Two conditions must both hold for that lookup to raise `KeyError`: the graph must become
asymmetric, and a recompute must run. Neither existed in the inherited code:

| | `6f32bca` (inherited) | `2c81b26^` (just before our change) |
|---|---|---|
| occurrences of `remove_edge` | **0** | **0** |
| recompute | `install_all_pair_paths` guarded by `install_initial_openflow_entries_completed`, set on the line before the call — **runs once per process** | same |

**`2c81b26` introduced both**, and it is our own commit. Its message says so plainly:

> on_link_delete logged the event and POSTed to the twin, and **there was no remove_edge
> anywhere in the file** … And **install_all_pair_paths runs exactly once per process** … The
> rules installed ~60s after startup were the final state for the life of the run.

`2c81b26` is an ancestor of `034da18` with **192 commits** between them; at `034da18^`,
`remove_edge` appears twice. So the code that produced the 291 s had our change in it.

### 2.4 So the honest chain is three states, not two

1. **Inherited**: link fails → no edge removal, no recompute → rules never change → traffic
   never reroutes.
2. **After `2c81b26`** (our fix for state 1): now removes edges and recomputes — which makes
   the inherited symmetry assumption reachable, so the recompute dies on `KeyError` and no rule
   is updated. **This is the state the 291 s was measured on.**
3. **After `034da18`** (our fix for state 2): BFS only walks links present in both directions;
   traffic routes around the dead direction.

States 1 and 2 look identical from outside — traffic never comes back — which is exactly why
the attribution slipped.

## 3. What the inherited router actually does, measured

`intelligent_router.py` was reverted to `2c81b26^` (a Python file — no rebuild) and the same
`measure_failover.sh` was run on the same OVS 128-host cell, with the fault held for **180 s**,
3.6× the current recovery time.

**Control first:** before any fault, `h1 → 10.0.0.33` ran at **0% loss**, and the bridges are
`fail-mode=secure` (with no rules installed, packets are dropped, not flooded). So the cell was
genuinely forwarding through installed rules before each run.

| run | replies | outage | recovered while the fault was present? |
|---|---|---|---|
| 1 | 97 | **180.75 s** | **no** |
| 2 | 97 | **180.75 s** | **no** |
| 3 | 70 | **180.75 s** | **no** |

All three are identical to two decimal places, which is what a fault-duration-limited outage
looks like: the number is set by how long the fault was held, not by anything the control plane
did. Hold the fault longer and the outage gets longer.

`measure_failover.sh` reported *"netem verified present at every check"* on every run, so the
outage is not a silently-reverted fault.

**The outage equals the fault duration.** Traffic returned only when the fault was removed, not
because anything rerouted. Against the current code on the identical cell — **47.0 / 49.5 /
53.7 s, recovering while the fault was still present** — this is a categorical difference, not
a slower one.

## 4. Consequences

- **The 291 s number does not describe the baseline** and is not going in the deck
  (Adam, 2026-08-19). It describes our own intermediate state.
- **The A2 adjudication for `034da18` is withdrawn.** By the deck's own rule — bug pages carry
  only inherited defects, not ones we introduced and fixed — it follows the precedent already
  set for `a72a168` (readopt) and `8c25dbc` (OpResult) and moves to the robustness page.
- **A real inherited defect remains, and now it has a number**: the inherited router never
  reroutes, measured at 180 s and still not recovering. That is the claim the baseline section
  can carry.
- **The better story is the one the evidence supports**: fixing a real inherited defect exposed
  a second inherited assumption one layer down, and a live run caught it. Both fixes are ours;
  so is the regression in between.

## 5. Limitations

- **n=3, one fault, one host pair, one cell.** Enough because the outcome is categorical
  (reroutes / does not), not a continuous quantity — see the ranges in §3.
- **The reverted file is `2c81b26^`, not `28b8b13`.** `intelligent_router.py` never existed in
  `28b8b13`, so `2c81b26^` is the closest thing to "the inherited router as we received it"
  — it includes the five earlier changes we made to the file before `2c81b26`.
- **Kernel and Ryu are at current HEAD**; only the router file was reverted. That isolates the
  router change, which is the variable under test, but it is not a full baseline stack.
- **The historical 291 s was never re-measured.** It is not needed: what mattered was whether
  it describes the baseline, and it does not.

## 6. Reproducing

```bash
git show 2c81b26^:intelligent_router.py > intelligent_router.py
bash tools/test_workflow/stack.sh up ovs     # Ryu first
sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-start
# control: this must pass before any run
sudo -n mnexec -a $(pgrep -f 'mininet:h1$') ping -c 4 10.0.0.33
bash doc/audit/2026-08-17_p4-vs-ovs-matched-topology/measure_failover.sh ovs 10.0.0.33 180 run.log
git checkout intelligent_router.py           # restore
```
