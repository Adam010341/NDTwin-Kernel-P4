# Live full-stack round, 2026-08-18 — P4/bmv2, 10 switches / 4 hosts

Stack: `ndtwin-lab topo-start` (ntg_bmv2_topo.py, **bmv2-fast** binary via
`p4_proxy/mininet/bmv2_binary_override`) → proxy :8081 → kernel :8000 (`04b8933`) →
NSR + Visualizer + Sim-Manager + Energy-App + TE-App. Converged in 2s.

[Co-developed with claude code -- Adam]

---

## F-5b. THE DIFFERENTIAL: the write path catches rejected rules on P4 and is
## structurally blind on OVS

Same kernel, same endpoint, same request shape, same HTTP response — opposite behaviour.

| | OVS/Ryu | P4/bmv2 |
|---|---|---|
| response to an invalid rule | `200 {"accepted":1,"status":"queued"}` | **identical** |
| rule reaches the switch | no | no |
| kernel logs the failure | **no — 0 errors in 16k lines** | **yes** |
| kernel's own table view | **shows a phantom for ~8s** | never shows it |

P4, invalid rule (`OUTPUT:999`, no such port):

```
[2026-08-18 17:49:18.574] [error] [Controller.cpp:55 operator()]
dispatched install failed for dpid 1 (priority 901): HTTP 200
-- P4 proxy agent reported an error in a 200 response:
   {"status":"error","message":"Failed to add route"}
```

kernel=4 proxy=4 at t=2,4,8,16,30s — no phantom, ever.
Control (valid rule, `OUTPUT:2`): kernel=5 proxy=5, installs and persists. Delete returns
it to 4.

**Why the two differ — the mechanism, not a guess.** `Controller.cpp:55` detects failure by
looking for an error *inside* a 200 response body. The P4 proxy performs a synchronous
P4Runtime write and puts `{"status":"error"}` in its 200. Ryu's `/stats/flowentry/add` is
fire-and-forget: it returns 200 before the switch has ruled on the rule, and the rejection
arrives later as an asynchronous OFPErrorMsg that nothing is listening for. So the check
has nothing to find on OVS.

**This was predicted and never acted on.** `doc/2026-07-28_test_coverage_gaps.md` §8 待辦 4,
quoted in the 08-13 fault catalogue's C-1 row:

> 殺掉控制器後下規則，kernel 要回報失敗而不是回 200 …
> 路由策略是 curl fire-and-forget，很可能真的回 200

The catalogue calls this step 「最有價值也最容易做」. It was never done. Today's round
reached the same defect without killing anything — an ordinary invalid rule is enough.

**Status:** not fixed. The P4 half already works, so the fix is a shape that exists in-repo.

---

## N-4. F-7 does not apply to P4 — and the reason is worth stating

The OVS round found that a power cycle strips TCLink htb shaping from both ends of every
affected link. On P4: **0 of 36 switch interfaces have htb at all**, including ones never
touched. `ntg_bmv2_topo.py` does not shape its veths.

So there is nothing to lose, and F-7 is OVS-specific. The related P4 property is already
documented in `bmv2_binary_override`'s own header: links are declared 1 Gbps while the
switches top out ~22 Mbps on the stock build, which is why the fast build exists.

## N-5. Telemetry sentinel generalises

`04b8933` behaves identically on both fabrics: all three endpoints return 10 keys with
`-1` for exactly the powered-off switches (here s9, then s5/s7 as the app continued).

## N-6. A snapshot discipline note

I read "kernel omits dpids 5,7,9 but only s9 is off" and nearly filed it. Taking all four
sources in one snapshot showed bmv2 procs, twin, kernel flow tables and proxy probes
**all** saying `[1,2,3,4,6,8,10]` — the Energy app had powered off s7 and s5 between my two
queries. Same trap as the OVS round's 10/10 reading. Two states from two moments is not a
comparison.

---

## F-8. twin_audit silently runs at 2-of-3 quorum on every P4 round

The lie-detector's `paths` channel defaults to Ryu's port and there is no P4 mode:

```
$ p4_proxy/venv/bin/python tools/twin_audit/twin_audit.py audit
    paths     unknown  all_destination_paths unreadable at http://localhost:8080
    ...
4 pair(s) audited, 0 contradiction(s)          <- exit 0

$ PATHS_URL=http://localhost:8081 ... twin_audit.py audit
    paths     moving   forward=1 reverse=1 (of 12 advertised)
    ...
4 pair(s) audited, 0 contradiction(s)          <- exit 0
```

Same tool, same network, one environment variable apart. **Both report success identically.**
Nothing in the summary, the exit code, or the per-pair verdict says a third of the evidence
was missing.

`tools/twin_audit/criteria.py:57` documents the requirement and `:200` sets the wrong default
for P4:

```
  PATHS_URL   all_destination_paths host. OVS: Ryu :8080. P4: proxy :8081.
              (default: http://localhost:8080)
```

`doc/2026-08-17_testing-manual.md` §4 carries the warning — but **only for `faults.sh`**:

> **P4 stack 要 `export PATHS_URL=http://localhost:8081`**，否則 `criteria.py` 預設打 Ryu 的
> :8080，paths 通道整輪回 unknown，三通道法定人數**靜默**降成兩通道。

`twin_audit` imports the same `criteria.py` and has the same defect, and is not mentioned.
Every P4 twin_audit run recorded in this repo that did not set the variable was a 2-channel
run reported as a 3-channel pass.

**Suggested shape.** The tool can detect its own mode — it already reads the kernel graph,
and `brand_name` distinguishes OVS from bmv2. Failing that, `unknown` on a channel should
degrade the exit status or at minimum print a one-line banner, so a degraded run cannot be
mistaken for a clean one.

**Status:** not fixed. Contained (the tool is honest about the channel in its per-pair output);
the defect is that the summary is not.

## N-7. P4 warnings this round were all healthy

11 warnings, 1 error (mine). Notable positives: the powered-off switches produced
`localhost:N reported a read failure for switch N ... -- keeping the previous table rather
than treating it as a switch with no rules` — the replace-vs-add guard doing its job — and
`no sFlow datagram has arrived in Ns ... indistinguishable from an idle network`, which is
the correct warning for a quiet fabric.

## N-8. Power-on verified a third time

`set_switches_power_state action=on` for s5/s7/s9 → 10/10 bmv2 processes, device-ids 1..10,
`nodes up 14/14`, `edges up 40/40` within 45 s.

---

## F-6b. The settle mis-calibration is not topology-specific — it fails on both fabrics

The OVS round found `faults.sh`'s default `FAULTS_SETTLE_S=5` shorter than the recovery time
its own catalogue documents. P4 confirms it is universal:

| fabric | `FAULTS_SETTLE_S=5` (shipped default) | longer settle |
|---|---|---|
| OVS, 128-host, L-2 | **FAIL** `during=still` | PASS @ 70 s |
| P4, 4-host, L-2 | **FAIL** `during=disputed` | **PASS @ 40 s** |

Catalogue's own measured recovery times, from the 08-17 round of 23 live runs:
P4 **13.7 s**, OVS 4-host **15.7 s**, OVS 128-host **50.1 s**. Every one exceeds the 5 s
default. There is no topology on this machine where the shipped default can pass.

(P4 returns `disputed` rather than `still` — the three channels disagree with each other at
5 s, rather than agreeing traffic has stopped. Different symptom, same cause.)

Also confirms N-4's shaping note from the other direction: the injector logged
`injected 100% loss on s1-eth1 (root)` — the `root` form, because there is no htb on the P4
fabric to hang a `parent` off.

---

## N-9. Contract suite result inverts between the two rounds, and that is the proof for F-2

| | OVS round | P4 round |
|---|---|---|
| Energy-Saving-App | running, 3 switches off | stopped, all 10 on |
| L2 API contract | **FAIL** | **PASS** |
| L3 component contract | **FAIL** | **PASS** |
| log allowlist | FAIL | FAIL |

Same suite, same kernel binary, same endpoints. The only material difference is whether the
power app had powered anything down. That is the cleanest possible demonstration of F-2:
the suite does not tolerate a correctly degraded network.

The log allowlist check fails in both, and on P4 the un-allowlisted warnings include
`localhost:8081 reported a read failure for switch 5 ... keeping the previous table` — the
warning the kernel emits *because it is handling a powered-off switch correctly*. So the
allowlist is a **third** tool that turns red when the Energy-Saving-App does its job, after
the L2 and L3 contracts.

(The remaining allowlist entries were the two NFS `/etc/exports` lines, the correct
`no sFlow datagram has arrived in 60s` during the quiet window, and my own test rule 901.)
