# FIX E-20 — the startup residue sweep reads the whole fabric, and says whose each finding is

[Co-developed with claude code -- Adam]

**Branch** `fix/e20-startup-sweep-all-interfaces`, base
`fix/w8b-withdrawal-needs-observed-failure`@`8a3f71d1` (the W8b tip after E-22).
Not merged, not pushed, no lab touched.

**Ruling.** `scratch/overnight-2026-09-05/DECISIONS.md`, grill §4E, fifth round:

> E-20 啟動掃描範圍：**另開小單擴到全部 Mininet 介面，不動本分支**。

The question that produced it is `fix/R2-W8b-SUMMARY.md` §7-4, which is the self-disclosure the
W8b agent wrote about its own deliverable.

---

## 1. The defect

W8-4 (the W8b branch) added a startup sweep: on MININET, read the qdisc tree and WARN about netem
that is already attached, because a declaration lives in the kernel process and the netem lives in
the machine, so a kernel restart separates them and the graph's clean `down_reason` then says
nothing at all about whether packets are flowing.

Its scope was **both ends of every switch-to-switch link**, chosen deliberately: exactly the set
`/ndt/inject_link_failure` can write to, on the reasoning that residue anywhere else has no owner
the kernel can name.

🔴 **But that is not where this repository's faults are actually attached, and the evidence is in
the tree** (🟢 read, not inferred):

| file:line | what it says |
|---|---|
| `testbed_topo.py:92-96` | hosts attach to `s1`..`s4` at **ports 3, 4, 5, …** — `s1-eth1` and `s1-eth2` are the switch-to-switch links, and **everything from `s1-eth3` up is host-facing** |
| `doc/audit/2026-08-28_chaos-harness/harness/chaos.py:487` | `--iface` help text: *"veth to use as wire truth for INV-04, e.g. **s1-eth3**"* |
| `doc/audit/2026-08-28_chaos-harness/harness/chaos.py:544` | `A.link_blackhole(args.iface or "**s1-eth3**")` — the **default** target when `--iface` is not given |

⇒ **the chaos harness's default netem interface is a host-facing port**, and the pre-E-20 sweep did
not read it. `tools/test_workflow/faults.sh` takes whatever `--iface` names, so it lands wherever
the operator points it — including there, and including a host's own `h<N>-eth0` inside the host
namespace. For those faults the sweep read nothing, found nothing and said nothing.

And silence from this sweep is not neutral. The sweep exists so that "the log said nothing" can be
read as "the fabric is clean". A scope that cannot see a whole class of faults makes that reading
**false for that class**, which is worse than not having the sweep: it is a clean bill of health
issued by an instrument that never pointed at the patient.

## 2. What changed

| | before (W8b) | after (E-20) |
|---|---|---|
| how it reads | `tc qdisc show dev <iface>`, once per link interface, through `sudo -n` | **one bare `tc qdisc show`**, whole root namespace, **no sudo** |
| what it can see | only names already in the graph | every `s<N>-eth<M>` on the machine |
| what it says | interfaces + count | interfaces + **`(link)` / `(host-facing)` / `(unknown)`** + count of each |
| what it does | reports, never clears, never declares | unchanged |

### 2.1 The read: one call, no `dev`, no sudo

`utils::netem::showAllQdiscs()` issues `{"qdisc","show"}` and `netemInterfacesInTree()` parses the
whole-machine form, in which each line names its own device:

```
qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 0x1 ...
qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%
```

That `dev <name>` pair is absent from the per-device form, which is why `findExistingNetem()` could
not be reused: it reads `w[3]` as `root`/`parent`, and there `w[3]` is the word `dev`.

🔴 **`readOnlyTcRunner()`, not `realTcRunner()`.** Three facts, and the third is the one that
matters:

1. reading the qdisc tree needs **no privilege at all** — `tools/test_workflow/qdisc_snapshot.sh`
   has taken whole-machine snapshots with a bare `tc qdisc show` since 2026-08-13;
2. the NOPASSWD grant on this machine is `tc qdisc show dev s[0-9]*-eth[0-9]*` — the **bare form is
   not in it**, so `sudo -n` would refuse it;
3. **a `sudo -n` refusal with stderr dropped is indistinguishable from "no netem anywhere".** That
   exact misread scored a live rep INVALID on 2026-08-21 while the injector was simultaneously
   printing "netem verified present at every check" — the comment recording it is at
   `doc/audit/2026-08-21_p4-beacon-sweep/beacon_sweep.sh:89`.

So the sweep's failure mode had to be "could not read", never "clean". It is: an unreadable tree
gets its own WARN and no findings.

### 2.2 The classification is the deliverable

Widening the scope without classifying would have replaced one bad answer with another: an operator
told "netem on s1-eth9" and pointed at `/ndt/inject_link_recovery` would be pointed at an endpoint
that **refuses that payload** (dpid 0, W8-7). So each finding carries whose it is:

* `(link)` — in `mininetLinkInterfaces()`. §2b wrote it or could have; §2c takes it back.
* `(host-facing)` — in `mininetHostFacingInterfaces()` (new). `faults.sh` or the chaos harness owns
  it; no link endpoint can address it at all.
* `(unknown)` — `s<N>-eth<M>`-shaped and in neither set. **The loudest of the three**: the fabric
  running on this machine is not the fabric in the topology file.

The WARN stays **one line**, and ends with a count per class.

### 2.3 What it still does not do, unchanged from W8-4

It does **not** clear anything, and it does **not** turn a reading into a declaration. Both of those
got *more* important with the wider scope, not less: the sweep now sees residue it definitely does
not own, so a sweep that cleaned up would be deleting somebody else's experiment.

## 3. The boundary, stated on purpose

Two things this sweep does **not** report, both by design:

* **netem outside the `s<N>-eth<M>` shape** — `docker0`, veths, the operator's wifi. A startup
  warning that fires on a developer laptop is a startup warning nobody reads, and the link-end
  finding underneath it would be lost with it.
* **netem inside a host's own namespace (`h<N>-eth0`)** — invisible from the root namespace.
  Reaching it needs `mnexec -a <topology pid>`: a different privilege, a different failure mode,
  and a dependency on finding the Mininet process. The ticket ruled it out explicitly.

⇒ **A quiet sweep means the root namespace is clean. It does not mean the fabric is.** That sentence
is in the API manual §2b and in `doc/KNOWN-ISSUES.md` B-6, because a boundary that only the code
knows about is a boundary that will be read as a guarantee.

## 4. Files

| file | what |
|---|---|
| `include/utils/NetemLinkFault.hpp` | `netemInterfacesInTree()` (whole-machine parser), `showAllQdiscs()`, `readOnlyTcRunner()` |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | `SweptInterface` enum, `ResidualNetem`, `mininetHostFacingInterfaces()`, new `warnAboutResidualNetem` signature and its two 🔴 doc blocks |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | the host-facing walk, `describeSweptInterface()`, the rewritten sweep |
| `src/main.cpp` | passes `readOnlyTcRunner()` and says why |
| `tests/test_NetemLinkFault.cpp` | `FakeMachineTc` replaces `FakeTcByInterface`; 8 sweep cases rewritten, 6 added, 2 parser cases added |
| `tests/shell/mutate_withdrawal_needs_observed_failure.sh` | six sweep anchors re-pointed, M8/M9/M10/M16/M17/M18 updated, M21–M25 and W5/W6 added |
| `doc/2026-01-02_ndt_api.md` | §2b: how it reads, what it reports, where it stops |
| `doc/KNOWN-ISSUES.md` | B-6: the W8-4 caveat, plus the E-20 entry |

## 5. Why the mutations went into the W8b gate rather than a new one

The ticket allowed either. One gate, because **E-20 rewrote the function the W8b gate already
mutates**: six of its anchors (`sweep-mode`, `sweep-detect`, `sweep-comment`, `sweep-found`,
`unread-warn`, and the widening's comment) point into `warnAboutResidualNetem`, and M8/M9/M10/
M16/M17/M18 are sweep mutations. A second gate would have had to anchor into the same function from
another file — two scripts that must agree on the same text, which is the anchor-drift trap the
`check_gate_anchors.py` checker exists to catch. "Easy to drop later" was the argument for
splitting, and it does not apply here: dropping E-20 means putting the old sweep back, at which
point those six anchors have to move anyway.

🔴 **M16 changed meaning and kept its number.** It used to be a direction-2 mutation ("the sweep
widens to host-facing interfaces") because `mininetLinkInterfaces()` *was* the sweep's scope. It is
now the sweep's `link` **classifier**, so the same edit now means "the classifier cannot tell a
host-facing port from a link end" — still a real defect, still caught, but a different sentence.
The number was kept so that `RED-GREEN.md` and the R2/R3 summaries keep meaning what they say; the
gate header records the switch.

**E-20's M2 as written on the ticket ("the sweep runs `tc qdisc del`") is M17**, re-anchored rather
than duplicated.

## 6. Red before green 🟢 ran

`JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh
./tests/shell/mutate_withdrawal_needs_observed_failure.sh`

```
  ok       baseline green (46 cases in DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*:ResidualNetemSweepTest.*)

=== verdict ===
  25 mutations, 0 survived
  6 widenings, 0 wrongly caught
```

(46 = the W8b tip's 40 + the 6 sweep cases E-20 adds. 25 = 20 + M21..M25. 6 = 4 + W5/W6.)

### 6.1 🔴 The first run was `25 mutations, 1 survived`, and the survivor was my own test fake

M17 -- "the startup sweep clears the netem it finds", the over-correction Adam ruled against **by
name** -- went green. The reason is worth writing down, because the instrument, not the fix, was
what failed:

* the mutant calls `utils::netem::restoreInterface(iface, run)`;
* that function issues `tc qdisc show dev <iface>` and parses the **per-device** form;
* `FakeMachineTc` answered every `show` with the **whole-machine** tree;
* `findExistingNetem()` cannot read an attach point out of that form (its `w[3]` is the word `dev`),
  so `restoreInterface` returned a no-op and **issued no tc write at all**;
* `TheSweepNeverRunsACommandThatChangesTheTree` asserts "no write was issued" -- and no write was
  issued. Green.

So the fake made a real defect look harmless. The fix is `FakeMachineTc::perDevice()`: a `show dev X`
now returns the lines naming X with the `dev X` words removed, which is what real tc prints.
`TheFakesPerDeviceViewIsTheFormRestoreInterfaceCanRead` pins it, so the next person cannot regress
it silently. **The whole gate was re-run** (not that one mutation) ⇒ 0 survived.

🔴 The general shape, and it is the second time this gate has caught it (the first was M16 on the
R2 run): **a mutation gate scores its own instrument too.** M17 was not "a test that needed
loosening"; it was the gate reporting that one of these cases could not see the damage it claims to.

### 6.2 The four E-20 mutations, verbatim

**M21 -- the sweep reports link ends only (the pre-E-20 shape, i.e. the defect):**

```
tests/test_NetemLinkFault.cpp:759: Failure
Expected equality of these values:
  found.size()
    Which is: 0
  1u
netem on the port a host hangs off was not reported at all. faults.sh puts it there, and a sweep that only reads link ends calls that fabric clean
[  FAILED  ] ResidualNetemSweepTest.NetemOnAHostFacingPortIsFoundAndSaidToBeHostFacing
```

**M23 -- everything is classified as a link end** (the list and the count are right; every word of
advice attached to them is wrong):

```
tests/test_NetemLinkFault.cpp:768: Failure
Expected: (text.find("s1-eth9 (host-facing)")) != (std::string::npos), actual: 18446744073709551615 vs 18446744073709551615
the warning did not say whose the interface is, so an operator cannot tell a link this kernel could take back from a fault only its own tool can:
[…] netem is already attached to 1 of this fabric's interfaces […]: s1-eth9 (link) -- 1 link end(s), 0 host-facing port(s), 0 not named by this topology. […]
```

**M24 -- the read goes back to the per-device form.** The findings are byte-for-byte identical
under this mutant, because the fake answers any `show`; only the argv assertion can see it:

```
tests/test_NetemLinkFault.cpp:710: Failure
Expected equality of these values:
  tc.calls[0]
    Which is: { "qdisc", "show", "dev", "s1-eth1" }
  (std::vector<std::string>{"qdisc", "show"})
    Which is: { "qdisc", "show" }
the sweep asked tc about a specific device: qdisc show dev s1-eth1. The `dev` form answers only for names already in the graph
```

**M25 -- direction 2: the name filter is gone**, so the operator's own machine is reported:

```
tests/test_NetemLinkFault.cpp:840: Failure
Value of: found.empty()
  Actual: false
Expected: true
the sweep reported netem on an interface that is not this fabric's shape. A warning that fires on the operator's wifi is a warning nobody reads
[…] netem is already attached to 3 of this fabric's interfaces […]: docker0 (unknown), wlp0s20f3 (unknown), h1-eth0 (unknown) -- 0 link end(s), 0 host-facing port(s), 3 not named by this topology. […]
```

Both runs restored the tree byte-identically and rebuilt the same test binary
(`6aaa1d790e260949`); the sweep suite is 14 cases and green after restore.
