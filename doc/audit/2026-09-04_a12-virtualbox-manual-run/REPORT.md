# A-12: does NDTwin actually run under VirtualBox, and does the boot manual work?

**Machine:** nslab, VirtualBox 7.1.18r173720
**Guest:** `a12-manual`, imported from the published `.ova`, 4 vCPU / 6144 MB (OVF-declared, unchanged)
**Ledger row:** A-12 in `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`
**Date:** 2026-09-04, 00:32-00:47 CST
**Evidence:** `evidence/` (harvested with sha256 verified at all three hops, `09eb1f90...`)

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
