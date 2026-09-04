# A-12: does NDTwin actually run under VirtualBox, and does the boot manual work?

**Machine:** nslab, VirtualBox 7.1.18r173720
**Guest:** `a12-manual`, imported from the published `.ova`, 4 vCPU / 6144 MB (OVF-declared, unchanged)
**Ledger row:** A-12 in `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`
**Date:** 2026-09-04, 00:32-00:47 CST (Part A), 01:0x-01:1x (Part B), 01:2x-02:3x (Part C)
**Evidence:** `evidence/` (Parts A+B, sha256 verified at all three hops, `09eb1f90...` / `5d221a68...`)
and `evidence-a12c/` (Part C, `7e6e7064b115b3a3d222ab60c2af5c693cf89d8b73dc2b8b290c71f861f2f496`).

> ⚠️ `evidence-a12c/STATE-A12C.txt` was captured **while two deliberate test flows were still
> present** (`s3` reads 3 and `s6` reads 131 instead of 2 and 130). They were removed
> afterwards and the removal verified by `dump-flows`. Every other table in this report uses
> the clean counts.

## Why this round exists

A-9 answered "does the image boot under VirtualBox" and recorded, in its own words, what it
had **not** answered:

> **NDTwin itself was never started under VirtualBox.** `ndtwin_kernel` was not run, no BMv2
> fabric was brought up, the P4 proxy was not exercised, none of the six applications were
> started, no web GUI was opened, and not one procedure from the User Manual was followed.
> `p4c` [...] Mininet 2.3.0 were only asked for their versions -- **which is exactly the kind
> of evidence this campaign tells testers not to accept**.

This round closes that gap and tests the boot manual itself.

## The object under test

`~/a9pack/out/NDTwin-P4-demo.ova`, `sha256 5ed8dcb942d5fa7ecde4f019b95125084e9c9e6fb221927d15e8e7f9c03fefab`.
That hash is **character-for-character the value published on the Download page**, so what was
tested is what a user downloads. Verified before the import, not after.

---

## Answer

**NDTwin runs under VirtualBox, end to end, and forwards traffic.** The stack came up in about
90 seconds from a cold boot with no intervention at all.

**The boot manual does not.** Its three-terminal procedure names a home directory, a script and
a conda environment that do not exist on this image; a user following it verbatim stops at the
first command.

---

## What was measured working

| | Evidence |
| :--- | :--- |
| Import | `VBoxManage import` rc=0; OVF `vmx-14`, E1000, AHCI, 4 vCPU / 6144 MB |
| Boot + network, **zero intervention** | SSH banner `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.18`; `enp0s17 10.0.2.15/24`, default route, DNS 10.0.2.3 |
| Login | `tester`/`tester`; installation at `/home/tester/Desktop/NDTwin-Kernel`; `sudo -iu tester` works |
| BMv2 fabric | 10 switches, gRPC 50051-50060, **manifest lists 10/10**, 10 ports listening. Topology `StaticNetworkTopologyP4_10Switches_4Hosts.json` |
| P4 proxy | listening on 8081 6 s after launch; `/p4/switch_state` → **10 switches, 10 `probe_ok: true`** |
| Convergence | `all_destination_paths` = **12** -- the exact value the manual predicts for the 4-host fabric |
| Kernel | `Server Listening on port 8000`; `Data plane: bmv2 (10 switch(es))`; `topology from the control plane: 10 switches, 4 hosts, 40 edges up`; all ten `inform_switch_entered` |
| **Data plane forwards** | `mininet> pingall` → **`0% dropped (12/12 received)`** |
| Applications | `ndtwin-esa` / `ndtwin-spm` / `ndtwin-reqmgr` all `active`; **8001 / 8002 / 9000 listening**, exactly the README's port table |
| `energy_saving_simulator` | prints its usage with no arguments, as documented |
| Image claims | `.git` removed from every tree ✓; units installed-but-disabled ✓; fresh boot listens on nothing but `sshd` ✓; `/dev/kvm` absent ✓ (fabric does not need it) |
| Headroom | peak guest memory **751 MB used of 5925** -- the 6 GB the OVF asks for is ample |

**The "ten-switch" and "4-host" descriptions are both correct** and I was wrong to suspect a
contradiction: the shipped topology is 10 switches *and* 4 hosts. They are different dimensions.

---

## Defects

### 🔴 D1 -- `PROVENANCE.txt` asserts something false, and labels it verified

The image's own `~/Desktop/NDTwin-Kernel/PROVENANCE.txt`, explaining the removal of `doc/`:

> Nothing the software READS at run time lived under doc/. **Checked, not assumed:** no source
> file, script, config or systemd unit in this image opens a path under doc/.

`src/ndt_core/http/HttpSession.cpp:1749`:

```cpp
std::ifstream file("../doc/2026-01-02_OpenflowCapacity.json");
```

The kernel's cwd is `/home/tester/Desktop/NDTwin-Kernel/build` (read from `/proc/3895/cwd`), so
`../doc/` resolves to the directory the packaging step deleted. The file is not anywhere on the
image. Runtime log:

```
[error] [HttpSession.cpp:1752 handleGetOpenflowCapacity] Cannot open 2026-01-02_OpenflowCapacity.json
```

This is the **only** such site: grepping `src/` and `include/` for `ifstream|ofstream|fopen|open(`
against `../doc/` or `"doc/` returns exactly one hit. Every other `doc/` mention in the tree is a
comment. So the code fix is one line -- but **the sentence is the more serious half**, because
"Checked, not assumed" is the phrase that stops the next reader from checking.

### 🔴 D2 -- a documented endpoint returns 200 on a read failure

Same endpoint, separate defect. `GET /ndt/get_openflow_capacity` answers **`http=200`, `bytes=0`**
(`evidence/openflow_capacity.meta`, and the zero-length `evidence/openflow_capacity.body` kept as
the artefact). Kernel API §37 documents it as returning the capability catalogue JSON. The error
is written to the log and **not** to the status code, so a client sees success and an empty body.

### 🔴 D3 -- the boot manual's Terminal 1 cannot run on this image

*User Manual → Operate an Emulated (Software) Network → VM-Linux Based Execution Environment*,
Terminal 1 step 4:

```bash
ryu-manager '/home/ndtwin/Desktop/intelligent_router_static_topo.py' ...
```

* `/home/ndtwin/` contains four dotfiles and a `README`. **There is no `Desktop/`.**
* `intelligent_router_static_topo.py` **does not exist anywhere on the image** (`find /` as root).
* `/home/ndtwin` is `drwxr-x--- ndtwin ndtwin`, so `tester` -- the account the Installation
  Manual tells you to use -- cannot even read the path.

What exists is `/home/tester/Desktop/NDTwin-Kernel/intelligent_router.py`.

### 🔴 D4 -- Terminal 2's directory and script are both wrong for this image

```bash
cd ~/Desktop/Network-Traffic-Generator/
sudo $(which python) example_topology.py
```

* NTG is at **`/home/tester/Network-Traffic-Generator`**, not under `Desktop/`.
* `example_topology.py` **does not exist anywhere on the image**. NTG ships `testbed_topo.py`.

### 🔴 D5 -- `conda activate ntg_env` names an environment that is not there

`conda env list` on the image: `base` and `ryu-env`. No `ntg_env`. (The Native-Linux page
separately mentions `ntg-env`, with a hyphen; neither spelling exists here.)

⚠️ Distinguishing instrument from finding: `conda` is absent from a **non-interactive** shell's
`PATH`, but `~/.bashrc` does carry the `conda initialize` block and an interactive login shell
resolves it. So "conda is not on PATH" is *my* shell, not a defect. The missing env is real.

### ⚠️ D6 -- the Installation Manual contradicts the Download page

Installation Manual §1 still says the P4/BMv2 image is **"*(not yet published)*"** and
**"Requires VMware"**. The Download page (working tree, uncommitted) carries the Drive link and
says **"Runs on VMware or VirtualBox."** The Download-page edit was mine and I did not propagate
it; whichever way it is resolved, the two pages must agree before publication.

### ⚠️ D7 -- the Download page names a commit that is not in the repository it links to

"Individual Components" lists **NDTwin Kernel — P4/BMv2 | snapshot `20cd80b`**, linked to
`NDTwin-Kernel-P4-public`. Checked over **unauthenticated HTTPS** (the only method that can
answer a publicity question):

| ref | GitHub API on `NDTwin-Kernel-P4-public` |
| :--- | :--- |
| `20cd80b62948e316646dd24f302f5278fee544ee` | **422 — not in this repository** |
| `936f8c6` | 200 |
| `9e6cc307` | 200 |

`20cd80b` is the private `NDTwin-Kernel-P4` commit the image was built from -- the image's own
PROVENANCE says so, and adds that the public snapshot `936f8c6` is *close to but not identical
to* the tree in the image (6 non-doc files differ). The page therefore labels a public download
with a private commit id.

### ⚠️ D8 -- "the commit each tree corresponds to" points at a file covering three of seven

Installation Manual: *"The commit each tree corresponds to is recorded in
`/home/tester/Desktop/NDTwin-Kernel/PROVENANCE.txt`."* That file records the kernel, NTG and NSR.
The four application trees are in the **other** `PROVENANCE.txt`, at `~/Desktop/`. Both files
exist -- my prediction that at most one could be right was wrong -- but the sentence overclaims.

### ⚠️ D9 -- WebGUI installation page: the GPG key is written to one filename and chmod'ed on another

```bash
curl -fsSL ... | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.asc      # <- never created
```

🔴 **Read, not run.** Docker is not installed on the image and installing it would have changed
the artefact under test, so this is a static reading of the page and is not backed by a
reproduction. It is listed because the mismatch is unambiguous, not because it was measured.

### ⚠️ D10 -- the OVF ships a **bridged** adapter, and the passwords are published

`VBoxManage import -n` reports `Network adapter: orig bridged`. The credentials
(`tester`/`tester`, `ndtwin`/`ndtwin`, root `ndtwin`) are on the public Download page and in the
OVF annotation, which itself says *"Change all three before putting this VM on a network."*
With a bridged default the VM **is** on the user's network at first boot, before that advice can
be acted on. This round used NAT with a forwarded port instead, deliberately, and that deviation
is recorded in the ledger.

### ℹ️ D11 -- the image README's "six programs" and the website's six applications are different sets

README: `energy_saving_app`, `simulation_platform_manager`, `request_manager`,
`Network-Traffic-Visualizer`, `Traffic-Engineering-App`, `energy_saving_simulator`.
Website: NTG, NSR, ESA, TEA, NTV, SPM. Overlap is four. NTG and NSR are on the image, at
`~/`, and are mentioned in neither the README nor the Desktop.

### ℹ️ D12 -- `p4_testbed_topo.py` cleans up with `pkill -f simple_switch_grpc`

Documented in the manual as a convenience. Observed consequence: starting a second instance
tears down the first one's switches. That happened to me during this round and I restarted from
`mn -c` -- recorded because it is the product's behaviour under a second user, not just mine.

---

## Observation, not yet a finding

`get_cpu_utilization` and `get_memory_utilization` returned **the same numbers** for the same
five keys (`192.168.123.11..15` → 14, 54, 36, 44, 39), and both bodies are 201 bytes.
All three of `get_cpu_utilization` / `get_memory_utilization` / `get_temperature` are keyed by
**physical-testbed management addresses** that have no counterpart in this BMv2 fabric.
⚠️ I compared only the first ~110 bytes of each body, so "identical" is not established --
it needs a full-body diff before it is worth calling anything.

## Reconciling with earlier rounds

* **A-9's open scope is closed.** Everything A-9 listed as untested was exercised here, and the
  answer is positive: the stack runs and forwards.
* **A-9's netplan fix holds through the repack.** Banner at T+5s of polling, zero intervention,
  on an image byte-identical to the published one. The most serious possible outcome of this
  round -- "the image users are downloading is broken" -- is excluded.
* **BUG-04 is settled on the shipped artefact.** `POST /ndt/install_flow_entry` on this image
  returns
  `{"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}`,
  **not** the `{"status": "Flows installed, modified and deleted"}` the Kernel API page prints in
  four places. The page's own caveat ("its wording is not part of the contract ... do not parse
  it") softens the consequence but does not make the example correct for the image the Download
  page hands people.
* **VMware is still untested.** nslab has `ovftool` but no VMware hypervisor. "Runs on VMware or
  VirtualBox" is half measured.

## R14: estimate vs actual

Registered **+25-40 GB** of disk, deliberately padded because A-9 (25→39) and H-18 (40-55→106)
had both under-estimated in the same direction. Actual: **+9.7 GB**. Padding in the direction of
the last two errors over-corrected; the honest lesson is that the estimate was not derived from
`populatedSize` (9.66 GB), which was sitting in the OVF descriptor the whole time.

[Co-developed with claude code -- Adam]

---

# Part B: the OVS three-terminal path (added after the P4 run)

Part A tested the **P4/BMv2** path, which is the one the Download page advertises. The demo VM's
own manual page describes the **OVS** path instead, and D3/D4/D5 say its commands do not exist on
the image. Writing corrected commands without running them would be the exact mistake this
campaign is about, so the corrected path was run.

## What was substituted, and why that matters

| The manual says | On the image | Used here |
| :--- | :--- | :--- |
| `ryu-manager '/home/ndtwin/Desktop/intelligent_router_static_topo.py'` | **absent, image-wide** | `intelligent_router.py` (the only Ryu app the image has) |
| `cd ~/Desktop/Network-Traffic-Generator/ && sudo $(which python) example_topology.py` | **absent, image-wide** | `python3 testbed_topo.py` from the kernel tree |
| `conda activate ntg_env` | **absent** | not needed for the above |

**The documented configuration therefore cannot be run at all.** What follows is the nearest
configuration the image can actually express.

## What came up

* Ryu started in **4 s**: OF listener on 6633, WSGI on 8080, `intelligent_router.py` loaded.
* The topology built **10 switches and 128 hosts**; the kernel's menu label "OVS Environment
  (128 Hosts)" is accurate, and `AppConfig::TOPOLOGY_FILE_MININET` →
  `StaticNetworkTopologyMininet_10Switches.json` **exists** (I had suspected a missing file; wrong).
* Kernel: `Data plane: ovs (10 switch(es))`, `Server Listening on port 8000`,
  `Pulled 16256 paths` = 128 × 127.
* Ryu's REST API, stable over 60 s: **switches 10, hosts 128, links 32**.

## 🔴 D13 -- 7 of 10 switches never receive their flow rules, and nothing ever repairs it

> **Rewritten a second time, 2026-09-04 (A-12f): this is a publishing defect, not a code defect.**
> The fix has been in the source since **2026-07-31** and is in the public repository the Download
> page links to. Only the shipped VM image predates it. Everything below the next section still
> stands as the description of what the image does; what changed is what should be done about it.

### The fix already exists, and users of the repo already have it

`2c81b26b` (2026-07-31, Adam) carries a comment that states the root cause in the same terms this
round re-derived from scratch a month later:

> `install_all_pair_paths` ran exactly once per process, because
> `install_initial_openflow_entries_completed` is set on the line immediately before the call.

Verified **by content, at each ref**:

| ref | `intelligent_router.py` | the one-shot flag |
| :--- | :--- | :--- |
| `trunk` | 2084 lines | fixed -- `:721` *"Deliberately does NOT set ... itself"* |
| `20cd80b` (internal source of the snapshot) | 2084 lines | fixed |
| **`936f8c6` (the public repo the Download page links to)** | 2084 lines | **fixed** |
| **the published VM image** | the old structure: flag set on the line before the call | **not fixed** |

So the two artefacts offered on the same Download page disagree: **clone the repository and you get
the fix; download the VM image and you get the bug.**

⚠️ **Instrument error worth recording.** I first asked whether the five fix commits were ancestors
of `936f8c6`, with `git merge-base --is-ancestor`, and got "none of them". That answer was wrong.
`936f8c6` is an **orphan snapshot** with no parents, so ancestry returns false for every commit in
existence. **Ancestry is not the question to ask of an orphan snapshot; content is.**
`git show 936f8c6:intelligent_router.py` shows the fix plainly.

✅ **Answered, and it became D18.** The image's `PROVENANCE.txt` does name a kernel commit --
`20cd80b62948e316646dd24f302f5278fee544ee`, which matches this repository exactly -- and states
that the tree is that commit minus `doc/`. It is not: five files differ, and
`intelligent_router.py` is one of them. See **D18**.

### What the image does, as measured (unchanged from A-12c)

> **Rewritten 2026-09-04 by run A-12c.** The A-12b heading read *"inter-switch forwarding does
> not work on the OVS path"*. **That was wrong, and A-12c falsified it with a measurement:**
> inter-switch forwarding works fine between two switches that hold rules. The defect is that
> most switches never get rules. The original A-12b text is preserved below under
> "What A-12b said, and which parts A-12c overturned".

### The run that settled it

One change from A-12b: **Ryu's stdout went to a file instead of a tmux pane.** A-12b could not
read the startup window because `tmux history-limit` is 2000 and the pane already held 1883
lines. Everything below comes from that file (`evidence-a12c/ryu-run1.log`, `ryu.log`).

### What actually happens

```
ryu-run1.log:59    install_all_pair_paths            <- runs
ryu-run1.log:489   Static topology initialized, all-destination paths installed.
ryu-run1.log:630+  seven switches disconnect and reconnect
```

`install_all_pair_paths` **runs exactly once, completes, and logs success.**
`Failed to load static topology` = 0. `Traceback` = 0. No exception at all.

And yet, per switch (`evidence-a12c/STATE-A12C.txt`):

| run | switches that received all 128 rules | switches left with only the 2 defaults |
| :--- | :--- | :--- |
| run 1 (fresh boot) | s1, s2, s4 | s3, s5, s6, s7, s8, s9, s10 |
| run 2 (Ryu restarted, fabric untouched) | *newly* s6, s7, s8 | s3, s5, s9, s10 |

Three facts pin the shape:

1. **All-or-nothing per switch.** Counts are 130 or 2, never in between. So this is not "the
   install was cut off part-way"; it is a per-switch decision.
2. **The set changes between runs.** s1/s2/s4, then s6/s7/s8. So it is not iteration order --
   it is a race. (A-12b's three 60-s samples were identical *within* one run, which is what made
   it look deterministic.)
3. **The one-shot flag guarantees no repair.** `intelligent_router.py:280` sets
   `install_initial_openflow_entries_completed = True` **before** calling the installer on the
   next line, and `:174` gates the whole static-topology load behind
   `if not self.install_initial_openflow_entries_completed:`. It is never reset. So a switch that
   comes up empty stays empty for the life of the controller -- through reconnects, through
   topology changes, through everything.

### The control that says it is the app, not the channel

Ryu itself reports all ten datapaths connected:

```
$ curl -s http://localhost:8080/stats/switches
[6, 10, 5, 3, 8, 2, 7, 9, 1, 4]
```

So I pushed one flow through **Ryu's own** `ofctl_rest` to `s3` -- a switch the app had left
empty -- and to `s6` as a positive control:

```
POST /stats/flowentry/add  dpid=3  ->  http 200
s3 flows: 2 -> 3, and dump-flows shows  priority=1,ip,nw_dst=10.99.99.99 actions=output:1
POST /stats/flowentry/add  dpid=6  ->  http 200   (control: same result)
```

**The OpenFlow channel to the "broken" switch is perfectly usable.** The rules the app believes
it installed were simply never delivered. (Both test flows were removed afterwards and the
removal verified by `dump-flows`, not by the 200 -- the first `delete_strict` returned 200 and
deleted nothing, because strict deletion also matches on priority and I had omitted it. My
omission, not a product defect, but it is the same "200 means nothing happened" shape as D2.)

### Forwarding, re-measured

| probe | switches involved | result |
| :--- | :--- | :--- |
| `h1 → h2` | both on a switch **with** rules | **3/3** |
| `h5 → h64` | **different switches**, both **with** rules | **3/3** |
| `h1 → h128` | far end on a switch **without** rules | **0/3** |

`h5 → h64` is the measurement that overturns the A-12b heading: **inter-switch forwarding
works.** What fails is any path that has to traverse a switch the installer skipped.

### What is established, and what is not

**Established:** the installer reports success after programming 3 of 10 switches; the survivors
vary run to run; the channel to the skipped switches is live; nothing ever re-provisions them.

**Not re-tested in Part C:** the `Ryu 128 hosts` vs `kernel 96 hosts` mismatch A-12b recorded.
The kernel was never started in this run, so that observation is untouched -- see
"Corrected notes to Part A", which explains the 96 as a control-plane poll, not a model defect.

**Not established:** *why* the flow-mods for the other seven are dropped inside the app. The
leading candidate is that `self.switches` (rebuilt only in the topology-update handler at
`:140`, `{sw.dp.id: sw.dp for sw in switch_list}`) holds **datapath objects whose sockets have
since been replaced by a reconnect** -- a stale object is not `None`, so `.get()` succeeds,
`send_msg()` writes into a dead socket, and nothing is raised. That would explain the
all-or-nothing shape exactly. **I did not prove it**, and it is recorded here as a candidate,
not a finding.

Also latent but **not** what happened here: `:400-401`

```python
datapath = self.switches.get(current_switch)
parser = datapath.ofproto_parser        # no None guard
```

would crash on a genuinely absent dpid. There was no traceback in either run, so this line did
not fire -- A-12b listed it as a possible explanation and A-12c rules it out.

### Why this is worth more than a routing bug

`Static topology initialized, all-destination paths installed.` is printed after 70% of the
fabric was left unprogrammed. That is the same shape as D1 and D2 on the P4 side: **the system
states success for work it did not do.** A user following the manual sees a clean controller
log, a full topology in the GUI, and a network that silently drops most traffic.

### What A-12b said, and which parts A-12c overturned

| A-12b claim | A-12c |
| :--- | :--- |
| "inter-switch forwarding does not work" | ❌ **overturned** -- `h5 → h64` crosses switches, 3/3 |
| rules land on exactly s1/s3/s5 | ⚠️ **narrowed** -- exactly three, but *which* three varies |
| "identical across 3 samples ⇒ stalled, not slow" | ✅ holds, and now explained: nothing retries |
| `:400` missing None guard could be the cause | ❌ **ruled out** -- zero tracebacks |
| `:173` switch-count gate could be the cause | ❌ **ruled out** -- `len(self.switches) 10`, gate passed |
| directed-graph traversal | ✅ stays falsified |
| startup race with the kernel | ✅ stays falsified |

### Why D13 still does not read as "OVS is broken"

The Ryu app the manual names -- `intelligent_router_static_topo.py` -- **is not on the image**.
The honest statement is unchanged:

> With the only Ryu app this image ships, 7 of 10 switches are left unprogrammed and the
> controller reports success. The application the manual tells you to run is absent, so the
> documented configuration was never testable.

## ⚠️ D14 -- the topology asks for 10 Gbit links and Mininet refuses

Repeated during topology construction:

```
Bandwidth limit 10000 is outside supported range 0..1000 - ignoring
```

`tc class show dev s5-eth1` on the running fabric: **`rate 1Gbit ceil 1Gbit`**. So inter-switch
links declared at 10 Gbit are not realised at 10 Gbit. Anyone taking a throughput number off this
fabric is measuring a link an order of magnitude below the one the topology describes.
⚠️ One interface sampled, not all 32 -- the per-link picture is not established.

## Corrected notes to Part A

* The `96 hosts` figure is what the kernel **polls from the control plane**. Its own served model
  is complete: `GET /ndt/get_graph_data` returns **138 nodes / 288 edges**, matching the static
  file exactly. An earlier reading of mine that found "0 host IPs" in that response was a **bad
  parser** -- `dst_ip` holds integers, not dotted strings -- not missing data.
* Part A's suspicion that `setting/` lacked an OVS 128-host topology was wrong; choice [1] loads
  `StaticNetworkTopologyMininet_10Switches.json`, which is present.

---

# Part D -- the two Tutorials pages, run (A-12e)

Adam's instruction after Part C was: fix the page you ran, then **go run the pages you have
not run**, and if there really is a problem, fix those too. Parts A-C covered the User Manual's
Quick Start page. `TrafficEngineeringApp.md` and `EnergySavingApp.md` had never been run; between
them they carry about 30 commands, and only four of those had ever been checked.

**Evidence:** `evidence-a12e/` (`STATE-A12E.txt`, `apps.txt`, `te.txt`),
`sha256 4499aea73c957346acf13da15f26a682d1b1ba759a99113602dcf9b41fb6cc96`, equal at all three hops.

## What is on the image, measured

| Named on the pages | On the image |
| :--- | :--- |
| `~/Desktop/{Traffic-Engineering-App, Energy-Saving-App, Network-Traffic-Visualizer, Simulation-Platform-Manager}` | **all four present** |
| `energy_saving_app`, `simulation_platform_manager`, `network_traffic_visualizer.sh`, `Traffic-engineering-App.py` | **all four present, at the documented paths** |
| `~/Desktop/Network-Traffic-Generator` | **absent** -- NTG is at `~/Network-Traffic-Generator` |
| `intelligent_router_static_topo.py`, `intelligent_router_static_topo2.py` | **neither is on the image** |
| `example_topology.py` | **absent** -- NTG ships `testbed_topo.py` |
| `ntg_env`, `te-env` | **absent** -- `conda env list` is `base` and `ryu-env` |
| `config_template.json`, `config_template2.json` | **absent** -- NTG ships `flow_template.json` and `dist_template.json` |

The router row is worth a note on **instruments**. Earlier rounds searched for
`intelligent_router_static_topo.py` by exact name, which says nothing about `_topo2.py`. This
round used `find / -name 'intelligent_router*'`, and the whole image holds exactly one Ryu
application: `intelligent_router.py`. Until that wildcard was run, `_topo2.py` was a genuine
unknown, not a settled absence.

## 🔴 D15 -- the two NFS applications block; the Installation Manual says they abort

The Installation Manual states that `energy_saving_app` and `simulation_platform_manager`
*"mount NFS as their first action and abort with `Mount NFS Failed` if it does not succeed."*

Run as the Tutorials pages instruct, on a fresh boot where `nfs-server` is inactive:

```
[info] energy_saving_app.cpp:977 main] Mount NFS
[info] energy_saving_app.cpp:978 main] mount -t nfs localhost:/srv/nfs/sim/power /mnt/nfs/app
[rc=124]                                        <- still blocked when killed at 25 s
mount.nfs: Connection refused for localhost:/srv/nfs/sim/power on /mnt/nfs/app
```

**`Mount NFS Failed` never appeared.** The `mount.nfs` error surfaced only *after* the parent was
killed. A user gets a program that sits there silently, not one that aborts with a message.
⚠️ Bound, not a limit: the 25 s window is mine. It may abort eventually; it does not abort promptly.

`energy_saving_app` also prints a raw Boost internal string when its first connection is refused
-- `Error: connect: Connection refused [system:111 at /usr/include/boost/asio/detail/
reactive_socket_service.hpp:589:5 ...]` -- and then continues anyway.

**The documented systemd path does work**, and was verified rather than assumed:

| | result |
| :--- | :--- |
| `sudo systemctl start ndtwin-spm` | `active`, listening on **:9000** |
| `sudo systemctl start ndtwin-esa` | `active`, listening on **:8001** |
| mechanism | `After=nfs-server.service`, `ExecStartPre=/usr/local/sbin/ndtwin-nfs-up` |
| `nfs-server` after | `inactive` -> **`active`**, both exports mounted |

## 🔴 D16 -- both pages name a traffic-generator config file that does not exist

`flow --config` -> `config_template.json` (TE page) and `config_template2.json` (ESA page).
Neither is on the image. NTG's own README documents `flow_template.json` (intervals and flow mix)
and `dist_template.json` (the same with parameters drawn from distribution files).

## 🔴 D17 -- `te-env` is not merely missing, it is unnecessary

The TE page says to `conda activate te-env` and adds that `$(which python)` is needed *"to force
`sudo` to use the Conda environment's Python instead of the system Python."* Run under the image's
plain `python3`, the application starts and reaches its own prompt:

```
Select TE mode:
  1) Execute run_te() when you press Enter
  2) Execute run_te() periodically (e.g., every 5 seconds)
Enter 1 or 2 [default 1]:
```

It then raised `EOFError` -- **because I fed it no stdin**, which is my harness, not a defect.

## ⚠️ Not a finding: the visualizer -- and a limitation I asserted without checking

`./network_traffic_visualizer.sh` failed here with `java.lang.UnsupportedOperationException:
Unable to open DISPLAY`. That is this headless SSH environment, not the script, and nothing on
that step was changed.

> 🔴 **Correction (A-12f).** A-12e went further and said this step could *never* be verified
> headlessly. **Wrong, and wrong for the worst reason: I never checked whether the image has a
> virtual framebuffer.** It does -- `xvfb-run`, `Xvfb` and `xdpyinfo` are all installed. Re-run as
> `xvfb-run -a ./network_traffic_visualizer.sh`, the DISPLAY error count is **0** and the
> application runs its render loop normally (`TopologyCanvas.draw() ... Canvas size: 1198.0x900.0`),
> drawing zero nodes only because the kernel was not up in that run. **The script is fine, and the
> limitation was mine and imaginary.** A stated limitation is a claim like any other; this one had
> no evidence behind it.

## What was changed on the website, and on what evidence

Three commits on branch `docs/p4-bmv2-environment`, **not pushed**. Each commit message separates
what was *executed*, what is *documentation-sourced*, and what was *left alone deliberately*. Two
lines carry explicit, visible uncertainty rather than a silent guess:

* `config_template.json` -> `flow_template.json` rests on NTG's README; the NTG interface itself
  was never driven.
* `intelligent_router_static_topo2.py` -> `intelligent_router.py` carries a note **on the page**
  saying the substitution brings the fabric up but has **not** been verified to reproduce the
  energy-saving behaviour the page demonstrates.

## 🔴 D18 -- the image's `PROVENANCE.txt` names a commit the image does not contain

`~/Desktop/NDTwin-Kernel/PROVENANCE.txt` states:

> The kernel tree here is 20cd80b MINUS its doc/ directory, removed 2026-09-01 before ...

The commit id it gives, `20cd80b62948e316646dd24f302f5278fee544ee`, resolves in this repository and
is exactly right. The claim about the tree is not.

Every tracked file of `20cd80b` outside `doc/` -- 405 of them -- was hashed on the image with
`git hash-object` (git 2.43.0 is installed) and compared against `git ls-tree -r 20cd80b`:

```
相符 400   不符 5   缺檔 0   （總 405）
```

| file | image | `20cd80b` |
| :--- | :--- | :--- |
| `intelligent_router.py` | 724 lines, `sha256 c994bf5c...` | 2084 lines, `sha256 1a3937bb...` |
| `p4_proxy/proxy_agent/main.py` | 405 lines | 358 lines -- **the image's copy is longer** |
| `testbed_topo.py` | 240 lines | 257 lines |
| `p4_proxy/mininet/host_count_override` | `4` | `128` |
| `p4_proxy/mininet/bmv2_binary_override` | bare path, comments stripped | same path, with its rationale |

The divergence does not point one way. One file is far older *and* carries a machine-specific
hardcode (`static_topology_file_path = Path("/home/tester/Desktop/NDTwin-Kernel/setting/...")`),
one is **longer** than the commit's, one differs by 17 lines, and one override has a different
value. That is the signature of an image built from **a working directory somebody had edited**,
not from a checkout of the commit it names.

### Why this is the heaviest item in this report

**D13 is a consequence of D18.** The switch-programming defect exists on the image *because*
`intelligent_router.py` is not the file `20cd80b` contains. The commit's own version has carried
the fix since 2026-07-31. A reader who trusts `PROVENANCE.txt` -- and it is written to be trusted
-- would reasonably conclude that reading `20cd80b` tells them what the image runs. For this file
it does not, and the difference is the difference between a working fabric and a silently broken one.

It is also the **second** false claim in this same file. The first is D1's *"Nothing the software
READS at run time lived under doc/. **Checked, not assumed**"*, contradicted by
`HttpSession.cpp:1749`. Two independent, confidently-worded, false assertions in the one document
whose entire purpose is to be the thing you do not have to verify yourself.

**What would fix it:** rebuild the image from a clean checkout, or -- if those five files are
deliberate -- say so in `PROVENANCE.txt`, file by file, with the reason. `host_count_override`
being `4` rather than `128` looks deliberate; `intelligent_router.py` being a year-older file with
a hardcoded path does not.

## 🔴 D19 -- two of the six applications cannot start at all, and the manual says all six were started

The Installation Manual's Quick Start page states:

> **Applications:** Network-Traffic-Generator, Network-State-Recorder, Energy-Saving-App,
> Traffic-Engineering-App, Network-Traffic-Visualizer and Simulation-Platform-Manager -- all built
> on the image and **each one started once to confirm it comes up**

Each of the six was started on the image. Four do. Two cannot:

| application | started? | how |
| :--- | :--- | :--- |
| Energy-Saving-App | ✅ | `systemctl start ndtwin-esa`, listening on `:8001` |
| Simulation-Platform-Manager | ✅ | `systemctl start ndtwin-spm`, listening on `:9000` |
| Network-Traffic-Visualizer | ✅ | `xvfb-run ./network_traffic_visualizer.sh`, render loop runs |
| Traffic-Engineering-App | ✅ | `sudo python3`, and `run_te()` executes against the kernel |
| **Network-Traffic-Generator** | ❌ | `ModuleNotFoundError: No module named 'pandas'`, **rc 1** |
| **Network-State-Recorder** | ❌ | `ModuleNotFoundError: No module named 'nornir'`, **rc 1** |

Neither module is anywhere on the image: not in the system `python3`, not in `base`, not in
`ryu-env`, and `find / -type d -name pandas` (and `-name nornir`) returns nothing. The manual's own
remedy for NTG -- `conda activate ntg_env` -- names an environment that does not exist either
(D5), so there is no documented or undocumented path to starting it.

### What this costs the two tutorials

Both application tutorials end with a traffic-generation step performed *inside the NTG interface*.
That step cannot be reached, so **neither demonstration can be completed on this image**. The
Traffic Engineering application itself is fine -- it acquires the routing lock, polls
`get_graph_data` every 5 s and runs its loop -- but it reports `0 entries are added` forever,
because nothing can generate the traffic it is supposed to react to.

That also demotes D16 from a defect to a detail: the config file the pages name does not exist, but
the program that would read it cannot start.

### A third false verification claim, from a third document

D1 is `PROVENANCE.txt` asserting *"Checked, not assumed"* about a path the software does read.
D18 is the same file naming a commit the image does not contain. D19 is the Installation Manual
asserting that each application was started once to confirm it comes up, when two of them exit
immediately with an import error. **Three separate documents each claim a verification that was
not performed, and each is written in the register that makes a reader skip checking.**

### One detail, measured

NTG's own source documents its command as `flow --config <file>` -- one line, the file as an
argument (`network_traffic_generator.py:287`, `:436`). Both tutorial pages show it as two steps,
`flow --config` and then the filename on its own line. **Untested**: the interface could not be
reached, so whether the two-step form would also work is unknown.

---

# Part E -- all 41 documented API endpoints, called (A-12g)

`NDTwin Developer Manual / NDTwin Application / NDTwin Kernel API.md` is 3060 lines and documents
**41 endpoints** (15 GET, 26 POST; 23 of the POSTs carry an example request body, three carry
none). It is the most mechanically checkable page in the manual, and BUG-04 came from it. Every
endpoint was extracted by parser and called against a running kernel.

**Evidence:** `evidence-a12g/` (`STATE-A12G.txt`, `api.txt`, `api2.txt`),
`sha256 e617042951e1f37435a05034d3eb0ba2953b57d94410b66dfe4b0e865cb5d372`, equal at all three hops.

**Two known defects were used as positive controls**, so that a clean sweep would have meant a
broken harness rather than a correct API. Both reproduced.

## ✅ What works, verified by state rather than by the response

The write path is genuinely sound. Each of these was checked in the switch, not in the reply:

| call | response | switch state afterwards |
| :--- | :--- | :--- |
| `install_flow_entry` (dpid 1, `10.77.77.77`) | 200 `queued` | `dump-flows s1` shows the rule |
| `delete_flow_entry` (same match) | 200 `queued` | rule gone, count 0 |
| `install_group_entry` | 200 | `dump-groups s1`: `group_id=1,type=all,bucket=actions=output:2` |
| `install_meter_entry` | 200 | `dump-meters s1`: `meter=1 kbps bands=type=drop rate=1000` |

Locks behave: `acquire_lock` → `{"status":"locked","ttl":30}`, `renew_lock` → `renewed`,
`release_lock` → `released`. `app_register` returns an app id. **No path-level 404s: all 41
documented endpoints exist.**

## 🔴 D20 -- `get_cpu_utilization` and `get_memory_utilization` return the same numbers, and they never change

```
cpu:    {"192.168.123.11":14,"192.168.123.12":54,...,"192.168.123.20":26}
memory: {"192.168.123.11":14,"192.168.123.12":54,...,"192.168.123.20":26}
```

**Byte-identical.** Sampled again six seconds later: identical again, both of them.
`get_temperature` returns a different series that also does not move.

All three report on `192.168.123.11`-`.20`. Those addresses come from
`setting/StaticNetworkTopologyMininet_10Switches.json` -- the **physical testbed's management
addresses**. The switches actually running are `s1`-`s10` in Mininet. So three "health" endpoints
answer with static numbers about hosts that are not present, and two of them answer with the *same*
static numbers. A consumer polling them sees a plausible, stable, entirely fictional dashboard.

## 🔴 D21 -- the page's own example bodies do not work against the setup the manual tells you to run

The examples use physical-testbed dpids such as `106225808380928`. In the emulated topology the
User Manual walks you through, the dpids are `1`-`10`. Pasting the documented body in returns:

```
404  {"detail":"these dpids are not switches in the loaded topology; check the dpid, or that
     the topology file matches the running network","error":"unknown dpid"}
```

**14 of the 23 documented POST examples returned 404** on the documented setup. Substituting a
dpid that exists turns them into 200 -- verified for seven of them (`install`/`modify`/
`delete_flow_entry`, `install_group_entry`, `install_meter_entry`, `link_failure_detected`,
`link_recovery_detected`). The remaining six are the same shape and were **not** retested.

The kernel's error text is, to its credit, excellent -- it names the likely cause. The defect is
that the page ships examples that cannot be run as written.

## 🔴 BUG-04, confirmed on the shipped image for three endpoints

| endpoint | documented | actual |
| :--- | :--- | :--- |
| `install_flow_entry` | `{"status":"Flows installed, modified and deleted"}` | `{"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}` |
| `modify_flow_entry` | same | same as above |
| `delete_flow_entry` | same | same as above |

The real response is the more honest of the two -- it says outcomes are in the log. The page
promises a completed action that the API does not claim to have performed.

## ⚠️ D22 -- `intent_translator` is documented but not there

`POST /ndt/intent_translator` returns `404 {"error":"Not Found"}` -- a different shape from the
topology 404s above, and it does not change with the request body. Documented as endpoint 41 of 41.

## ℹ️ Smaller things, recorded not chased

* `received_a_simulation_case` returns **202** with `{"status":""}` -- an empty status string.
* Three documented POSTs carry **no example body at all** (`set_switches_power_state`,
  `modify_meter_entry`, `historical_logging`). Sent `{}`, each returns a 400 that names the
  missing field, which is good behaviour and a documentation gap.
* `get_openflow_capacity` reproduced **200 with 0 bytes** (D2), as predicted.
* `get_static_topology_json` carries `link_bandwidth_bps` of 10 Gbit, consistent with D14.

## R12 for this round

| prediction | outcome |
| :--- | :--- |
| P1 `get_openflow_capacity` 200/0 bytes | ✅ reproduced -- harness proven |
| P2 `install_flow_entry` returns `queued`, not the documented text | ✅ **but only on the second pass** -- with the page's own example body it 404s first, which is D21 |
| P3 at least three more endpoints disagree with the page | ✅ D20, D21, D22 |
| P4 the three body-less POSTs 400 or 500 on `{}` | ✅ all three 400 with a named field |
| P5 no path-level 404s | ✅ all 41 exist |

The interesting one is P2. My prediction was right about the response and wrong about how to
reach it: the harness used the documented body, and the documented body is itself broken. **A
prediction can be correct and still not be what the first measurement tests.**

---

# Part F -- everything that was left (A-12h)

A parser over the whole `docs/` tree found **14 pages and 387 commands** still untested after
Parts A-E. Two of those pages (78 commands) are `Operate a Physical (Hardware) Network`.

## 🚫 Not tested, because not permitted

The physical-testbed pages were **not run**. The standing rules for this project forbid touching
the power-strip API, the switches and the physical NICs, and nothing in that section can be
exercised without at least one of them. They were read, not run, and **nothing in this report
makes any claim about them**. That is a permission boundary, not an instrument limit and not a
verdict on the pages.

## ⚪ Not applicable to this image -- checked before being called a defect

Three of the remaining pages describe a **different installation**, and reporting their missing
files as image defects would be the framing error this campaign exists to avoid. Each was checked
against its own stated audience first:

| page | states | on this image | verdict |
| :--- | :--- | :--- | :--- |
| `WebGUI.md` | *"deploy ... on Ubuntu systems ... containerized using Docker"* | no `docker`, no `docker-compose`, no `web_gui_deploy.sh`; Web-GUI is not among the repositories the Download page says the image carries | **not applicable** -- a separate deployment |
| `AI Model Training and Inference.md` | conceptual, names PyTorch/scikit-learn as examples | `torch` absent | **not applicable** -- it claims nothing about the image |
| `Native-Linux Excution Environment.md` ×2 (164 commands) | building NDTwin from source on a Linux server | `autogen.sh`/`configure` etc. absent from any NDTwin tree | **not applicable** -- a from-source path, not the demo VM |

## ✅ A negative result worth recording

Every `git clone` URL in the manual was checked unauthenticated: **all ten resolve and are
public** (`jafingerhut/p4-guide`, `p4lang/behavioral-model`, and the eight `ndtwin-lab` repos
including `Web-GUI` and `NDTwin-Kernel-P4-public`). I predicted at least one would 404, on this
campaign's track record. **Wrong, and it is worth saying so** -- the repository references are in
good shape.

## 🔴 D24 -- the Simulation Platform page sends you to a directory that is not there

```bash
cd ~/Simulation-Platform-Manager
```

| path | on the image |
| :--- | :--- |
| `~/Simulation-Platform-Manager` (as documented) | **MISSING** |
| `~/Desktop/Simulation-Platform-Manager` | present |

Same shape as D4. The binary inside it is fine and, started through `ndtwin-spm`, listens on
`:9000` (Part D).

## 🔴 D25 / D26 -- the Network State Recorder's start and stop scripts both exit 0 having done nothing

These are the two failure shapes this project has recorded from a tester's run of the upstream
repository. **They are confirmed here on the published VM image.**

`start_network_state_recorder.sh` is, in full, a `sed` on a settings file and then:

```bash
nohup python3 network_state_recorder.py &
```

The Python exits immediately -- `ModuleNotFoundError: No module named 'nornir'`, true rc 1 when
run in the foreground -- but it is backgrounded, so the script returns:

```
start true rc = 0
NSR processes alive afterwards = 0        (walked /proc, not pgrep)
```

**D25: reports success, started nothing.**

`stop_network_state_recorder.sh`:

```bash
echo $(pgrep -f network_state_recorder.py)
sudo kill -15 $(pgrep -f network_state_recorder.py)
# ... then a sed on the settings file
```

With nothing running, the command substitution is empty, `kill` is called with no pid and prints
its usage, and the script's exit status comes from the trailing block:

```
stop true rc = 0
```

**D26: reports success, stopped nothing, and leaks `kill`'s usage text at the user.**

Both true exit codes were taken **without a pipe in the way** -- a pipeline would have handed me
the exit status of `head` instead, which is how this pair can look fine.

## ⚠️ An instrument error, caught mid-round

My first pass answered "is this package present?" with `command -v X || dpkg -s X`. That is the
wrong question for a **Python** package: it reported `loguru`, `eventlet` and `ryu` as MISSING
when all three are importable -- `loguru` from the system interpreter (the TE app uses it), and
`eventlet` and `ryu` from inside `ryu-env`. Re-asked with the interpreter itself:

| module | system `python3` | `base` | `ryu-env` |
| :--- | :--- | :--- | :--- |
| `pandas` | MISSING | MISSING | MISSING |
| `nornir` | MISSING | MISSING | MISSING |
| `loguru` | **ok** | MISSING | MISSING |
| `eventlet` | MISSING | MISSING | **ok** |
| `ryu` | MISSING | MISSING | **ok** |
| `requests` | ok | ok | ok |
| `networkx` | ok | MISSING | ok |
| `fastapi`, `uvicorn`, `torch` | MISSING | MISSING | MISSING |

**D19 survives the better instrument**: `pandas` and `nornir` are genuinely absent from all three
interpreters, which is why NTG and NSR cannot start.

[Co-developed with claude code -- Adam]
