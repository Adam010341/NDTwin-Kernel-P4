# R-5 re-run checklist — F-1 … F-5b, with each finding's own third branch

PREREG §3 R-5: each 08-18 finding gets **still present / fixed / no longer reachable**, and the
third branch is registered on purpose *"so a finding that merely became untestable is not scored
as fixed"*. Written before the round from the 08-18 write-ups; nothing here has been run.

🔑 The trap this list exists to avoid: **"I did not see it" is not "it is fixed".** Every row
below therefore carries a positive control — the thing that must be observable for a
"not present" verdict to mean anything.

---

## F-1 — a punt-to-controller rule diagnosed as a missing topology link

**Claim.** `FlowLinkUsageCollector.cpp:2753` warns `edge not found by dpid/port 5:4294967293`.
`4294967293` = `0xFFFFFFFD` = `OFPP_CONTROLLER`, a **reserved** port, not a real one.

**Re-run.** Grep the round's `kernel.log` for `edge not found by dpid/port` and for `429496729`.

| verdict | evidence required |
| :--- | :--- |
| still present | the warning appears with a reserved port number |
| fixed | reserved ports are excluded — **and** the log shows the collector ran at all |
| **not reachable** | no flow was ever punted to controller this round ⇒ untestable |

**Positive control.** The warning can only appear if `calFlowPathByQueried` executed. If that
function logged nothing at all, a clean log is a silent collector, not a fixed bug.

## F-2 — the contract suite cannot coexist with the Energy-Saving-App

**Claim.** `run_layers.sh api ovs --traffic` reports `BROKEN /ndt/get_graph_data — switches not
up, 20 edges down`. **Nothing was broken**: Energy-App had correctly powered three idle switches
down and the twin reported it accurately (135/138 nodes, 268/288 edges).

**Re-run.** Run the contract suite **twice**: once before `energy` starts, once after it has
made a shutdown decision.

| verdict | evidence required |
| :--- | :--- |
| still present | suite reports BROKEN *and* the down switches match Energy-App's decision |
| fixed | suite distinguishes "administratively down" from "broken" |
| **not reachable** | Energy-App powers nothing down this round ⇒ the collision cannot occur |

⚠️ This one is **ordering-sensitive and interacts with the `energy` authorisation**: `energy`
runs last, so the "after" pass has to be scheduled inside that final stage or it cannot happen.

## F-3 — the contract schema contradicts the documented `-1` sentinel

**Claim.** `get_cpu_utilization` / `get_memory_utilization` return `-1` for a down switch;
the doc and the Web-GUI treat `-1` as "unavailable", but the contract schema demands `>= 0`.

**Re-run.** Needs a **down** switch to exist — same dependency as F-2.

| verdict | evidence required |
| :--- | :--- |
| still present | schema still rejects `-1` while doc/GUI accept it |
| fixed | schema admits the sentinel |
| **not reachable** | no switch is down ⇒ `-1` is never emitted |

🔴 **In MININET mode `/ndt/get_cpu_utilization` is fabricated** (`10 + hash(ip) % 50`) — the
`ndt status` note says so. So a `>= 0` here is **not** evidence the sentinel path works; it is
evidence the fabricated path ran. Only the down-switch case tests anything.

## F-4 — stale comment left by `04b8933` (self-inflicted)

**Claim.** `tools/contract_test/spec.py:459` still says values may be an int **or** an
explanatory string; `04b8933` replaced the string with `-1`, so the `Str()` branch of the
`OneOf` is dead. It passes, so nothing catches it.

**Re-run.** Pure source check — **no fabric needed**, and it can be done before the round.

| verdict | evidence required |
| :--- | :--- |
| still present | the comment and the `Str()` branch are both still there |
| fixed | either updated |

**No third branch**: a source fact is always reachable.

### ✅ RESULT — **FIXED**, determined before the round (source only, no fabric, no load)

`tools/contract_test/spec.py:510-513` no longer carries the stale comment. It now reads:

> *Values are numeric; a down switch reads `-1`, the same sentinel as the two endpoints above.
> `Str()` is retained only for kernels older than `04b8933`, which returned the literal
> "The switch is down." here — that string is no longer emitted and the branch is dead against
> any current build.*

The `Str()` branch **is still in the schema**, which on its own looks like the finding
surviving. It is not: the branch is now *documented as deliberately retained* for
older kernels, with an explicit statement that it is dead against current builds. F-4's
complaint was that the comment *described behaviour that no longer exists*; the comment now
describes exactly what exists and why the dead branch is kept.

Kernel side confirms the other half —
`DeviceConfigurationAndPowerManager.cpp:1596-1603` returns `-1` for `!vp.isUp` and records why
the string was dropped (three sibling endpoints saying the same thing three ways, and an int
and a string sharing one JSON key).

⚠️ Verified by **reading both sides**, not by the suite passing. F-4's original sting was that
it *passed* while being wrong, so "the contract suite is green" is not evidence here and was
not used as such.

## F-5 — a rejected flow rule is reported as installed for ~8 s, then vanishes (OVS)

**Claim.** `POST /ndt/install_flow_entry` with a bad rule → `200 {"accepted":1,
"status":"queued"}`; the kernel's own table view shows a **phantom** entry for ~8 s; the switch
never has it; **0 errors in 16k log lines**.

**Re-run.** The 08-18 method: quiet network, POST one invalid rule, poll three sources every
2 s from t=0 — `ovs-ofctl` (the switch), Ryu `/stats/flow/1`, and
`/ndt/get_switch_openflow_table_entries` (the twin).

| verdict | evidence required |
| :--- | :--- |
| still present | twin count exceeds switch count for a window, then converges |
| fixed | twin never shows the entry, **or** the kernel logs the rejection |
| **not reachable** | the endpoint refuses the request outright ⇒ nothing to observe |

**Positive control — mandatory.** Also POST a **valid** rule. If the valid one does not appear
in all three views, the instrument is not reading the tables and the invalid-rule result means
nothing. This is the row most likely to produce a false "fixed".

## F-5b — the differential: the write path catches rejections on P4, is structurally blind on OVS

**Claim.** Same kernel, same endpoint, same request, same 200 — opposite behaviour.
`Controller.cpp:55` detects failure by finding an error **inside** a 200 body. The P4 proxy does
a synchronous P4Runtime write and reports `{"status":"error"}` in its 200, so the check finds
it. Ryu's `/stats/flowentry/add` is fire-and-forget: 200 arrives before the switch has ruled,
and the rejection comes back later as an async `OFPErrorMsg` nothing listens for.

**Re-run.** F-5 on **both** fabrics and compare. The finding is the *difference*, so one fabric
alone cannot confirm or refute it.

| verdict | evidence required |
| :--- | :--- |
| still present | P4 logs `dispatched install failed`, OVS logs nothing, both return 200 |
| fixed | OVS also surfaces the rejection |
| **not reachable** | only one fabric is run this round ⇒ **the differential is untestable** |

🔴 **Likely outcome, stated in advance:** this round is scoped to one fabric at a time. If both
are not run, F-5b must be recorded **untestable**, not "still present" on the strength of the
OVS half alone — the OVS half is the part that was already known.

---

## Ordering consequence

F-2 and F-3 both need a **powered-down switch**, which only `energy` produces, and `energy` is
authorised **only in the final stage**. So both are scheduled inside that stage, and if `energy`
declines to power anything down, both are **not reachable** — not "fixed".

[Co-developed with claude code -- Adam]
