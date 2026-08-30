# §6 (P4 / BMv2) and T-2 "does it actually run" — first clean-room replay

**2026-08-30 01:17 – 03:53.** Started from `post-s5-run2`, the snapshot taken when the §1–§5
replay finished by following the page — i.e. the machine a reader arriving at §6 is actually on.

Raw: `raw/section6/` on `audit-raw`. Harness: `vm/guest_section6_p1.sh`, `vm/guest_section6_p2.sh`,
`vm/guest_t2_run.sh`, all committed **before** they ran.

| phase | steps | non-zero | verdict |
| :--- | ---: | ---: | :--- |
| §6.0–§6.1 (2 h 14 m) | 10 | **0** | pass |
| §6.2–§6.6 | 21 | **0** | pass |
| T-2 run the system | — | 1 | ✅ **fabric forwards** — 12/12 pingall, paths=12 |

---

## ✅ §6.1 — the pinned toolchain installs, and the page's recorded values are exact

`install-p4dev-v8.sh` completed in **2 h 14 m** (page says one to two hours; slightly over).

| page records | measured |
| :--- | :--- |
| `simple_switch_grpc --version` → `1.15.5-fdd3b893` | **`1.15.5-fdd3b893`** — including the commit hash the page argues from |
| `p4c-bm2-ss --version` → `1.2.5.16` | **`Version 1.2.5.16 (SHA: c55ca45b1f)`** |
| toolchain ≈ 12 GB | qcow2 grew 19 → 30.1 GB |

Judged **by use, not presence**, as the page demands: `p4c-bm2-ss` compiled a real `v1model`
program to 4368 bytes of valid BMv2 JSON. Nothing landed in `build/` — §4.2.4's cwd fix held
through §6.1's `cd ~`, which is the trap that step's headline warning is about.

## ⚠️ M-2 (minor) — §6.1 over-lists what the installer creates

The page says the script creates `grpc/`, `PI/`, `behavioral-model/` and `p4c/`, and its retry
advice names "six components" including two bundled autotools. Measured on Ubuntu 24.04 + v8:

| listed | created |
| :--- | :--- |
| `PI`, `behavioral-model`, `p4c` | **yes** |
| `grpc` | **no** — v8 installs gRPC from apt (`libgrpc-dev`, `libgrpc++-dev`) |
| `automake-1.16.5`, `autoconf-2.71` | **no** |

Three of six. Consequence is small — `rm -rf` on absent directories is harmless, and the
"toolchain lands in the wrong directory" warning is still substantively true, since the three
that do get created are nearly all of the 12 GB. But a reader who checks the list will not find
what it names.

## ✅ §6.6 — `f00d69f`'s claim is now executed, and all three refusals are word-for-word

This is the commit the ticket flagged as never having been run. The page's table predicts four
outcomes; the three refusals were exercised by running the topology script a reader runs:

| page predicts | actually printed |
| :--- | :--- |
| `names no executable: '/usr/local/bmv2-fast/...'` | ✅ exact |
| **`has no directive line (every line is blank or a #-comment)`** | ✅ exact — **this is `f00d69f`** |
| `no default to fall back to on purpose` | ✅ exact |

Row 4 ("Starts") was **not** claimed by that script, deliberately: a guard that refuses
everything, including what it should permit, passes all three refusals. It is supplied instead
by T-2 below, where the fabric does come up with the stock binary named — so row 4 holds too.

## ✅ §6.2–§6.5

Pipeline compiled; **both** outputs non-empty and the JSON parses into declared tables (an empty
file exits 0 just as happily). `p4runtime_pb2` **imports** under the pinned `protobuf 3.20.3` —
tested by importing rather than by reading the pin, since a satisfied pin that cannot import is
exactly what the pin guards against. §6.4's two settings are present in `AppConfig.hpp`.

---

# T-2 — the system a reader just installed, actually run

Startup order per the User Manual (**Mininet → Proxy → wait → Kernel**), 4-host fabric (S5,
the variant §6.5 ships and this 4-vCPU VM can run).

## What works

* **Fabric comes up.** All 10 BMv2 switches verified listening on gRPC 50051–50060, and the
  **manifest lists 10** — judged on the manifest, which contains only switches that passed
  verification, not the reassuring console line above it.
* **Proxy connects.** Zero connection refusals. It discovers all **10 switches** and **4 hosts**,
  and installs proactive routes.
* **Kernel starts and answers.** `GET /ndt/get_graph_data` → **HTTP 200**, reporting **40 edges**
  — exactly the figure the User Manual gives for the 4-host fabric.

## ❌ T2-1 — RETRACTED 2026-08-30 04:05. The fabric works. The instrument did not.

**Everything in the struck-through section below is wrong.** A clean re-run from the
`post-s6-t2` snapshot, with the instrumentation faults fixed, gives:

| | previously reported | actual |
| :--- | ---: | ---: |
| `/v1.0/topology/links` | 0 | **32** |
| `all_destination_paths` | 0 | **12** — exactly the manual's figure for the 4-host fabric |
| `pingall` | mostly `X` | **`*** Results: 0% dropped (12/12 received)`** |
| link failures | — | 0 |

Discovery settles in **under 5 seconds**, as the User Manual says. **A reader who follows the
Installation Manual gets a fabric that forwards.** On the question Adam asked — is this a
blocker for the demo — the answer is **no**.

### How I manufactured it, in four steps

1. **H-17.** `kill -0` on the root-owned topology returned EPERM, which run 1 read as "died".
   It started the proxy ~2 s in, before any switch was listening, so **run 1's proxy genuinely
   discovered 0 links** — the only true "0" in the whole affair.
2. **H-22 🔴 `$!` after `( … ) &` is the subshell, not the process inside it.** Run 1's
   shutdown ran `kill $PROXY` and killed the subshell; **the python process survived** and kept
   port 8081.
3. **Run 2's proxy therefore never bound.** Its log says so, and I did not read it:
   `ERROR: [Errno 98] error while attempting to bind on address ('0.0.0.0', 8081): address
   already in use`. Every API sample I took was answered by **run 1's orphan**, which correctly
   reported 0 links, because it had none.
4. **Two proxies then drove the same switches over P4Runtime**, which is why run 2's `pingall`
   was broken. The datapath damage was real; I caused it.

🔑 The tell was in my own data the whole time: the log recorded 15 `Discovered link` lines while
the API reported 0. I wrote that down as "beacons arrive but no link is added" — inventing a
mechanism to reconcile two numbers instead of asking why one instrument disagreed with the
other. **A disagreement between two of your own readings is not a finding about the system; it
is a finding about your instruments, until you have shown otherwise.**

A second error compounded it: I grepped for `link (add|up|discover)` — which requires "link"
*before* the verb — against a log that says `Discovered link`. Zero hits, read as zero links.
The pattern was backwards and I treated its output as an observation.

<details>
<summary><b>Retracted text, kept for the record</b></summary>

### ~~no links are ever discovered, so no paths exist, and most of the fabric cannot ping~~

Converged and stable, sampled over four minutes after the switch count stopped moving:

```
sw=10  links=0  hosts=4  paths=0
sw=10  links=0  hosts=4  paths=0
sw=10  links=0  hosts=4  paths=0
```

The User Manual says **"The 4-host fabric settles at `12`, in a couple of seconds."** It is
`0` after four minutes. Switches climbed 0 → 8 → 9 → 10 and stopped; links never left 0, so
this is not a convergence-in-progress reading.

LLDP is the mechanism and it is running: the proxy logs `Started LLDP Discovery...` and
`Started LLDP link watchdog...`, the P4 pipeline handles `TYPE_LLDP = 0x88CC` and punts
beacons, and **24 packet-ins arrived**. But **zero links were added**.

And the datapath shows it — `pingall`, verbatim:

```
h1 -> X X X
h2 -> X h3 X
h3 -> X h2 h4
h4 -> X
```

⚠️ **I have not established the mechanism.** Beacons are punted and packet-ins arrive, but
nothing becomes a link. Whether that is the pipeline, the proxy's LLDP handler, or something
about a 10-switch fabric on 4 vCPU is **not determined by this run**, and I am not guessing.

### ~~The part that matters most: the twin looks healthy anyway~~

~~The kernel reported 40 edges while the proxy had discovered zero links.~~ **Also retracted.**
The observation that `--topology` feeds the kernel a static JSON is true, but the conclusion
drawn from it rested on the false "zero links", so it is withdrawn rather than kept. Whether the
twin's edge count can mask a genuinely broken data plane is a real question and **it has not
been tested** — it would need a fabric broken on purpose, which is a chaos-harness job, not this
one.

</details>

---

## 🔴 P-1 — the proxy survives a failed port bind and keeps writing to the data plane

This one is the system's, and it is what made the retraction above expensive.

When a second proxy is launched while one is running, the new instance fails to bind 8081 and
uvicorn shuts the HTTP server down — and **the process keeps going**. After
`INFO: Application shutdown complete` at line 646 of a 706-line log there are **29 further
link-discovery and rule-installation actions**, including `Installing initial routes
proactively...` and `Proactive Rule: DPID 1: 10.0.0.1/32 -> Port 3`, plus
`ValueError: Cannot invoke RPC on closed channel!` from threads still calling into channels
shutdown had closed.

So the second instance:

* **serves nothing** — every operator check goes to the first instance,
* **writes to the switches anyway**, fighting the first instance for P4Runtime state,
* and **reports its own failure only once**, in a line nobody is watching, before continuing.

"Is the proxy up?" (`curl :8081`) answers **yes**, from the wrong process. The manual's own
workflow makes this reachable: three terminals, plus advice like "go back to Terminal 1" that
invites relaunching a component while another is live.

Severity is bounded by needing two instances, so it is not a demo blocker — but it is a real
instance of the house pattern: **a component that fails, says so once, and carries on mutating
shared state.**

---

## 🔴 M-3 — the User Manual tells you to grep for a string the software never emits

> "If the proxy log shows `ECONNREFUSED` against `:5005x`, the BMv2 switches are not up"

Occurrences of `ECONNREFUSED` in a proxy log with **30 failed connections**: **0**. What is
actually written is `Failed to connect to remote host: Connection refused`, and from `requests`,
`[Errno 111] Connection refused`. Errno 111 *is* ECONNREFUSED, so the page is semantically right
and literally wrong.

This is not hypothetical: the first T-2 run grepped for exactly the word the manual names,
found nothing, and **printed PASS while all ten switches were unreachable.**

---

## Harness defects found (mine, not the system's)

Run 1 of T-2 reported *fabric did not verify, paths never settled, kernel did not answer, twin
sees 0 switches*. **All four were mine**, and each was individually convincing.

* **H-17 🔴 `kill -0` cannot tell "gone" from "not yours".** The topology runs under `sudo`;
  `kill -0` from the unprivileged shell returns **EPERM**, indistinguishable from ESRCH by exit
  status. The script called a live root-owned fabric dead, bailed out of its wait after ~2 s,
  and started the proxy before any switch was listening — manufacturing 30 connection failures,
  0 paths and 0 switches. Now uses `/proc/<pid>`, readable regardless of owner.
* **H-18 — the ECONNREFUSED grep**, above. The check searched for the manual's word rather than
  the emitted text, so it passed on a completely broken fabric.
* **H-22 🔴 `$!` after `( … ) &` names the subshell, not the process in it.** `kill $PROXY`
  killed the wrapper and left the proxy holding port 8081, so the next run's proxy could not
  bind and every API sample I took was answered by an orphan from the previous run. This is the
  single defect that produced the retracted T2-1.
* **H-23 — a backwards grep.** `link (add|up|discover)` cannot match `Discovered link`. Zero
  hits were read as zero links.
* **H-24 — block-buffered stdout.** The proxy's log was read while incomplete: a 706-line file
  with no HTTP access lines at all, though the server had served requests. `PYTHONUNBUFFERED=1`
  now, so the log is a record of what has happened rather than of what happened to be flushed.
* **H-19 — `/ndt/get_network_topology` does not exist**; the endpoint is `/ndt/get_graph_data`.
  A 404 *is* the kernel answering, so "kernel did not answer" was a wrong conclusion from a
  correct observation.
* **H-20 — stale-artifact hazard.** `rm -f /tmp/ndtwin_p4_switches.json` fails with *Operation
  not permitted* (root-owned from the previous run). This run overwrote it, but had the fabric
  failed, the check would have read **the previous run's manifest and passed.**
* **H-21 — `grep … | tail -1 || bad` can never fail**, because the pipeline's status is `tail`'s.
  The pingall assertion could not go red; the matrix above was read by hand.

🔑 Three of these produced *system-shaped* failures. What exposed them was not review but
looking at what the fabric actually did — the manifest existed, the switches were running, the
mininet prompt was there — none of which the harness's own output would ever have shown.

---

## What is NOT established

| | |
| :--- | :--- |
| §6.7 (fast BMv2 build) | **not run** — another full behavioral-model build at `-O3`; behavioral-model alone took 22 min at `-O2` |
| bmv2 binary identification (sha256 + EventLogger 24/0) | **not done** — depends on §6.7 |
| 128-host fabric | **not run** — 4-vCPU VM; all figures above are the 4-host variant |
| whether a static `--topology` can mask a broken data plane | **not tested** — needs a deliberately broken fabric |
| User Manual / Developer Manual (T-3) | **not started** |
| T-4 full-stack round | **not started** — requires this VM to be down first |

[Co-developed with claude code -- Adam]
