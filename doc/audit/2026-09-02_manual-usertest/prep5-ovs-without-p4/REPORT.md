# A-8 — Does the OVS path work on a machine where Installation Manual §6 was never done?

**Machine:** nslab VM `ndtwin-vm-prep5`, ssh port 2301, 4 vCPU / 6144 MB, affinity 16-19.
**Run by:** orchestrator by hand (no tester agent), 2026-09-03 CST.
**VM window:** start `2026-09-02T19:11:26Z`, stop `2026-09-02T19:28:01Z` — **16 min 35 s**.
**Kernel commit on the guest:** `936f8c6c9d050f32c0ee22be58e48a7e98905ee0`
("Snapshot of the P4/BMv2 kernel tree at 20cd80b, published for the manual").
**Manual followed:** website `2612b0a`, page last touched by `f671631`
(`raw/MANUAL_user-manual_native-linux_2612b0a.md`, sha256 `d5c2e713…`).

---

## The answer

**Yes. Section 6 is genuinely optional for the OVS path.** Nothing on the OVS path
touched, needed, or mentioned P4/BMv2. On a machine with **no** `simple_switch_grpc`, **no**
`p4c-bm2-ss`, **no** `~/p4-guide` / `~/behavioral-model` / `~/p4c`, **no** `p4dev-python-venv`,
**no** `p4_proxy/venv` and **no** compiled `ndtwin_switch.json`, the full three-terminal
procedure came up on the first attempt and produced every number the manual promises:

| What the manual promises | What we measured | |
|---|---|---|
| Ryu listening, switches dial in | listening on `:6633` **3 s** after launch; all 10 switches `tcp:127.0.0.1:6633` | ✅ |
| `130` flows per switch | **130 on all ten**, three samples 10 s apart, total **1300** | ✅ |
| `10 switches, 128 hosts, 288 edges up` | `topology from the control plane: 10 switches, 128 hosts, 288 edges up` | ✅ |
| two flow records, one per direction, naming your hosts | **2 records**, `10.0.0.1` ↔ `10.0.0.2`, `src_port 5201` on one and `dst_port 5201` on the other | ✅ |
| graph of the fabric | `get_graph_data`: **138 nodes, 288 edges**, `brand_name: "OVS"` | ✅ |
| clean shutdown | every port released, 0 bridges, 0 surviving processes | ✅ |

Kernel `[error]`/`[critical]` lines for the whole run: **0**.
Kernel log lines mentioning `p4`, `bmv2`, `grpc`, `proxy`, `8081` or `5005x`: **0**.

The two decisive pieces of evidence, both effects rather than messages:

1. **`ldd build/bin/ndtwin_kernel`** links exactly seven libraries — `libcrypto`, `libssl`,
   `libboost_url`, `libstdc++`, `libgcc_s`, `libc`, `libm`. Grepping that output for
   `grpc|protobuf|bm2|bmv2|p4|libpi` returns **nothing**. The built artefact cannot depend on
   Section 6, because it is not linked against anything Section 6 installs.
   (`raw/04_preflight.log`)
2. **The kernel classifies the data plane itself**:
   `validateDataPlaneHomogeneity] Data plane: ovs (10 switch(es))` — it takes the OVS branch and
   never looks for a proxy. (`raw/08_terminal3_kernel.log`)

This corroborates, on a machine built for the purpose, what run-02 only showed incidentally.
It also matches the source-level expectation: `CMakeLists.txt` has `find_package` for
**libssh, OpenSSL and Boost 1.83 only**, and **zero** occurrences of
`protobuf|grpc|PI|p4runtime|bmv2`. (`raw/02_section6_absent.log`)

---

## The three pre-registered predictions, quoted verbatim and ruled on

From `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`, A-8 row,
registered 2026-09-02 21:13, before the VM was started:

> 📌 **R12 預期（跑之前寫）**：①三終端全起、128 hosts、kernel 對著活 fabric、iperf 後 ≤30 s
> 出現雙向流、圖 138 節點／288 邊——即 **OVS 路徑不依賴 §6**；②`~/miniconda3/envs/ntg-env`
> 在 prep5 **不存在**（NTG 的環境是 NTG 頁裝的、不在 §1–5），手冊 Terminal 2 原句
> `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py` 失敗，`sudo python3
> testbed_topo.py`（apt 的 mininet）可用——這是 §1–5 與 User Manual 之間的一個接縫，要記；
> ③`ndt up ovs` 仍在 ③（無 `/usr/local/sbin/ndtwin-lab`）失敗，與 §6 無關，不重測 ④。

### ① — **HIT, on every clause.**

| clause | measured |
|---|---|
| 三終端全起 | T1 19:18:07Z, T2 19:18:39Z, T3 19:21:13Z — all three came up, all three still alive at shutdown |
| 128 hosts | `128 hosts` in the kernel's convergence line; Mininet stopped 128 hosts / 10 switches / 144 links at teardown |
| kernel 對著活 fabric | 130 rules on each of ten live OVS bridges *before* the kernel started; kernel then read 10/128/288 off that same fabric |
| iperf 後 ≤30 s 出現雙向流 | iperf3 started `19:22:32Z`; the records' `first_sampled_time` is `19:22:36` — **4 s**, and both directions were present in the first sample taken |
| 圖 138 節點／288 邊 | `get_graph_data` → **`nodes: 138`, `edges: 288`** — exact |
| OVS 路徑不依賴 §6 | see "The answer" above |

Nothing in ① was off, including the two exact integers written down two hours in advance.

### ② — **SPLIT: the fact is right, the premise about the manual is wrong.**

- **Right:** `~/miniconda3/envs/ntg-env` does **not** exist on prep5. Verified:
  `ls: cannot access '/home/ndt/miniconda3/envs/ntg-env'`. The only conda env is `ryu-env`.
  (`raw/02_section6_absent.log`, `raw/03_state_of_1to5.log`)
- **Right:** `sudo python3 testbed_topo.py` works, on the apt Mininet 2.3.0. That is what we ran,
  and it built the fabric.
- 🔴 **Wrong:** *"手冊 Terminal 2 原句 `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py`"*
  — **the User Manual's OVS page has never said that.** Its Terminal 2 block has read
  `sudo python3 testbed_topo.py` since `e3b7479` (2026-01-04), the commit that first added the
  guide; `git log -S "ntg-env/bin/python testbed_topo.py"` on that file returns **no commits at
  all**. So the predicted failure could not occur, and **the seam ② was written to catch does
  not exist on this page.**

  Where the string actually lives, for the record:
  - `NDTwin User Manual/NDTwin Tools/NetworkTrafficGenerator(NTG)/index.md:138` —
    `sudo ~/ntg-env/bin/python testbed_topo.py`. Note this is `~/ntg-env`, a **plain venv**, not
    `~/miniconda3/envs/ntg-env`. That is the NTG page, not the OVS page.
  - The OVS page's only `/home/adam/miniconda3/envs/ntg-env/bin/python` is inside the **G-7
    known-limitation note**, quoting `ndtwin-lab`'s hardcoded paths — i.e. it is describing a
    defect, not instructing anyone.

  Ruling: **the ntg-env absence is confirmed; the manual seam is disconfirmed.** ② was
  half-right about the world and wrong about the document.

### ③ — **NOT RULED: premise confirmed, consequent never executed.**

- **Premise confirmed:** `/usr/local/sbin/ndtwin-lab` does not exist on prep5. Neither does
  `/usr/local/bin/ndt`, nor `~/.local/bin/ndt` — `command -v ndt` finds nothing.
  So `ndt up ovs` could not even be reached; **both** halves of the launcher are absent, not
  just the root-side one the prediction names.
- **Consequent not tested:** the A-8 step list does not include running `ndt up ovs`, and the
  prediction itself says `不重測 ④`. I did not run it. Given run-04's BUG-3 — `ndt up`'s failure
  path leaking a live `stack.sh` that later starts a kernel onto somebody else's fabric — running
  it unsupervised on a shared host to confirm a failure we already understand was not worth the
  risk. **This is a deliberate omission, not an oversight.**
- The part of ③ that *is* load-bearing for A-8 — *"與 §6 無關"* — holds: the launcher's absence
  is a §1–§5/G-7 matter and has nothing to do with P4.

---

## What we ran, verbatim

Three tmux sessions inside the guest, each with a real pty, each captured with
`tmux pipe-pane` (raw panes in `raw/T{1,2,3}_*_pane.log`).

**Terminal 1 — Ryu** (manual: `conda activate ryu-env` then the `ryu-manager` line):

```bash
cd ~/Desktop/NDTwin-Kernel && source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env \
  && ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest \
     --ofp-tcp-listen-port 6633 --observe-link
```

The `source …/conda.sh` is **not** an invention: plain `conda activate ryu-env` fails on this
guest with `conda: command not found` (see F1 below), and the Installation Manual's Step 2.1
offers exactly two remedies — `conda init bash` **or**
`source ~/miniconda3/etc/profile.d/conda.sh`. We used the second. Everything after it is the
User Manual's line unchanged.

**Terminal 2 — Mininet** (manual verbatim, only prefixed by the `cd` the pre-flight assumes):

```bash
cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py
```

**Convergence check** (manual verbatim):

```bash
for i in $(seq 1 10); do
  printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"
done
```

**Terminal 3 — Kernel** (manual verbatim):

```bash
cd ~/Desktop/NDTwin-Kernel/build && sudo bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info
```

**Traffic and read-back** (manual verbatim):

```
mininet> h1 iperf3 -s &
mininet> h2 iperf3 -c h1 -t 300 &
curl -X GET http://localhost:8000/ndt/get_detected_flow_data
```

**Shutdown** (manual's OVS Safe Shutdown): `exit` in Terminal 2 → `sudo mn -c` → Ctrl-C the
kernel.

### Where the guest's manual differs from the website

**It does not differ — because there is no copy on the guest.** `~/ndtwin-docs` is **absent**
on prep5, and a filesystem-wide `find / -maxdepth 5 -type d -name ndtwin-docs` returns nothing.
prep5 was cloned from the A-2 clean-room disk, which predates the run-01…run-04 dispatch tooling
that stages `~/ndtwin-docs` into the guest. So the brief's premise — *"the guest's snapshot is
older than run-04's `2612b0a`"* — is **false for this machine**: there is no snapshot at all.
We therefore followed the current website HEAD `2612b0a`, and archived the exact page we
followed at `raw/MANUAL_user-manual_native-linux_2612b0a.md` so the text is reproducible.

---

## Timeline

| UTC | event |
|---|---|
| 19:10:39 | RAM gate: 1 qemu (Adam's `182232`), 23853 MB available. Ledger appended. |
| 19:11:26 | `ndtwin-vm.sh start`, qemu **404441**, pinned 16-19 |
| 19:12:12 | guest ssh reachable (first try) |
| 19:12:48 | §6-absence evidence collected |
| 19:18:07 | **T1** Ryu; listening on `:6633` after 3 s; wsgi on `:8080` (pid 2241) |
| 19:18:39 | **T2** `sudo python3 testbed_topo.py` |
| 19:19:49 | `Static topology initialized, all-destination paths installed.` (**+70 s**) |
| 19:20:17-19:20:37 | flow counts: **130 × 10**, three samples |
| 19:21:13 | **T3** kernel; convergence line at 19:21:13.636 — **same second** |
| 19:22:32 | iperf3 `h1 -s` / `h2 -c h1 -t 300` |
| 19:22:36 | kernel's `first_sampled_time` for both flow records (**+4 s**) |
| 19:23:01 / :13 / :25 | three `get_detected_flow_data` samples, 2 records each |
| 19:24:16 | shutdown step 1 — `exit` |
| 19:24:46 | shutdown step 3 — `sudo mn -c` |
| 19:25:21 | shutdown step 4 — Ctrl-C kernel; `All subsystems stopped. Exiting.` at 19:25:23.812 |
| 19:28:01 | `ndtwin-vm.sh stop`, graceful, 2 s |

---

## Everything that did not go perfectly, and whether §6 caused it

**None of the seven was caused by Section 6's absence.** Stated plainly because that
distinction is the whole experiment.

### F1 — `conda activate ryu-env` → `conda: command not found`
**§6? No.** Cause: conda was never `conda init`-ed into this image's `~/.bashrc` (which is the
stock Ubuntu 24.04 file, 3771 bytes exactly; no conda block in `~/.bashrc` or `~/.profile`).
This is a **prep5 provisioning artefact** — the A-2 clean-room automation created `ryu-env`
without persisting shell initialisation. **The manual already covers it**: Installation Manual
Step 2.1 says in as many words that "Installing Miniconda does not by itself put `conda` on your
`PATH`, and `conda activate` fails … until the shell is initialised", and offers `conda init
bash` or `source ~/miniconda3/etc/profile.d/conda.sh`. Our workaround is the manual's own second
option. **Not a manual defect and not a project defect.** A human following §1–§5 by hand would
not hit it.

### F2 — the manual's documented Ryu line `install_all_pair_paths done: … rules=1280` never appeared
**§6? No.** Cause: **prep5's `intelligent_router.py` is not the published one.** Its working tree
carries a 724-line / 28333-byte version (sha256 `e8ca8236…`) while its own `HEAD` (`936f8c6`) has
the ~2084-line one. Proved directly: the published snapshot `20cd80b` **does** contain
`"install_all_pair_paths done: hosts=%d pairs=%d rules=%d paths=%d "`, and that string appears in
the guest's `git diff` **only on the `-` side** — i.e. HEAD has it, the working tree deleted it.
So the log line is missing because this machine runs older controller code, not because the
manual is wrong. A user cloning the public repo would see the line.
⚠️ **This is a real confound and is recorded as one** — see "Caveats".

### F3 — `testbed_topo.py`'s own ping test reports 100% packet loss on all 128 pairs, then prints `Host internet: OK | sFlow reachability: OK | Switch identification: OK`
**§6? No.** This is **run-04 BUG-2 reproducing exactly** — the banner's three `OK`s are string
literals with no relation to the ping results, and the pings run during path installation. Our
own pings *after* convergence were **4/4, 0% loss** both within a switch (`h1→h2`,
avg 0.155 ms) and across the fabric (`h1→h100`, avg 0.387 ms). Independent reproduction of a
known defect on a machine that has never seen P4.

### F4 — the convergence message appears in **Terminal 1**, not Terminal 2
**§6? No.** `Static topology initialized, all-destination paths installed.` landed in the Ryu
pane; the Mininet pane never contained it (`grep -c` → T1: 1, T2: 0). The manual puts the "wait
for this message" note under **Terminal 2**, without saying which terminal prints it. Minor
documentation ambiguity, cheap to fix, entirely unrelated to §6. The manual's own
ask-the-switches check is unaffected and is what we relied on.

### F5 — no manual on the machine (`~/ndtwin-docs` absent)
**§6? No.** Instrumentation gap in how prep5 was built, described above. Not a project defect.

### F6 — the OVS Safe Shutdown says "in reverse order" and then lists Terminal 2 first
**§6? No.** True reverse order is T3 → T2 → T1; the OVS list starts at Terminal 2 and only reaches
the kernel at step 4 ("close all other terminal windows"), while the **P4** section on the same
page correctly starts with Ctrl-C on the kernel. Documentation inconsistency. We followed the OVS
text as written and it worked, but a reader who takes "reverse order" literally and a reader who
follows the numbered list will do two different things.

### F7 — iperf3's own throughput summary was not captured
**§6? No.** The manual's `&` backgrounds the client inside the Mininet CLI, and the CLI does not
relay a background job's stdout to the pane — `grep -c 'bits/sec'` on the Terminal 2 pane is
**0**. What we do have is the **kernel's** sFlow-derived estimate, which is a different quantity
and is labelled as such below. Not a defect; a limit of the manual's own procedure worth knowing
if you wanted iperf3's number.

### Not failures — two documented behaviours reproduced exactly
- `sudo mn -c` killed Ryu, as the manual warns: `:6633` and `:8080` both gone afterwards, and the
  T1 pane ends in `Terminated`.
- The kernel's last line was `terminate called without an active exception` / `Aborted`, **after**
  `All subsystems stopped. Exiting.` — exactly one occurrence of each, exactly as documented.

---

## Numbers, with their provenance

Every figure below was written to a file at the moment it was read; the file is named.

| figure | value | file |
|---|---|---|
| flows per switch | 130 on s1…s10, ×3 samples; total 1300 | `raw/07_convergence_flows.log` |
| `nw_dst=10.0.0.x` rules on s1 | 128 | `raw/07_convergence_flows.log` |
| kernel convergence | `10 switches, 128 hosts, 288 edges up` | `raw/08_terminal3_kernel.log`, `raw/T3_kernel_pane.log` |
| data-plane classification | `Data plane: ovs (10 switch(es))` | `raw/08_terminal3_kernel.log` |
| ping h1→h2 | 4 tx / 4 rx, 0% loss, rtt 0.139/0.155/0.199 ms | `raw/ping_h1_h2.log` |
| ping h1→h100 | 4 tx / 4 rx, 0% loss, rtt 0.040/0.387/1.261 ms | `raw/ping_h1_h100.log` |
| flow records | 2, `10.0.0.1`↔`10.0.0.2`, ports 5201 / 38622, proto 6 | `raw/get_detected_flow_data_{1,2,3}.json`, `raw/flow_decode.log` |
| kernel-estimated rate, h2→h1 | 413478912 / 1392771072 / 1125408768 bps across the three samples (**sFlow-derived estimate, not iperf3's own figure**) | same |
| graph | `nodes: 138`, `edges: 288`; `brand_name: "OVS"` | `raw/get_graph_data.json`, `raw/graph_decode.log` |
| paths pulled from controller | `Pulled 16256 paths` | `raw/T3_kernel_pane.log` |
| kernel error/critical lines | 0 | `raw/10_safe_shutdown.log` |
| ports after shutdown | 8000, 8080, 6633, 6653, 8081, udp/6343 all released | `raw/10_safe_shutdown.log` |
| bridges after shutdown | 0 | `raw/10_safe_shutdown.log` |
| survivors after shutdown | ndtwin_kernel 0, ryu-manager 0, iperf3 0, mn 0 | `raw/10_safe_shutdown.log` |
| §6 still absent after the run | all four binaries absent, all three trees absent | `raw/10_safe_shutdown.log` |

Process discovery throughout used `/proc/*/comm` + `/proc/*/cmdline` and `ss -tlnpH`.
**No `pgrep -f` or `pkill -f` was used anywhere**, on host or guest.

---

## Caveats and things I am not certain about

1. **prep5 is not a pristine copy of what a user gets.** Its working tree carries older versions
   of the two files the OVS path actually executes:
   - `testbed_topo.py` (240 lines, sha256 `d842cfd2…`) matches the file **as of `6f32bcae`**
     (2026-07-23, "Add P4 switch support via routing/power strategy pattern") — found by hashing
     every historical version of that path across all local refs.
   - `intelligent_router.py` (724 lines, sha256 `e8ca8236…`) matches **no version in our local
     history** (31 commits scanned). Its origin is unresolved.

   Both were last modified 2026-09-01 05:57, four minutes after the 05:53 clone, so this was done
   deliberately when the A-2 clean room was built — but I do not know by what or why, and I did
   not find the provenance of the router file. **This weakens generalisation, not the result:**
   neither file has any P4 dependency, and the §6 question is orthogonal to which revision of
   them runs. Still, "the OVS path works" here is demonstrated on *these* revisions, and F2 is a
   direct consequence.

2. **③ is unruled by choice.** I did not run `ndt up ovs`. If Adam wants ③ ruled rather than
   noted, it needs its own supervised window — and BUG-3 says a failed `ndt up` can leave a live
   `stack.sh` behind, so it should not be run unattended.

3. **One run, one machine.** Convergence at +70 s and the kernel reading the fabric within the
   same second are single observations. The 130-per-switch figure was sampled three times and is
   solid; the timings are not.

4. **"§1–§5 done" was asserted, not audited by me.** I verified the *outputs* §1–§5 should leave
   (built binary at `build/bin/ndtwin_kernel`, `ryu-env`, apt Mininet 2.3.0, OVS 3.3.9) and that
   §6's outputs are absent. I did not re-walk §1–§5 to confirm each step was performed as written.

5. `~/logs/` on the guest holds a **previous** three-terminal run from 2026-09-01 06:08-06:33
   (the A-2 clean room's own). It is prior evidence, not mine; every number in this report comes
   from `~/a8-logs/`, created fresh this run. Do not conflate them.

---

## Files

- `raw/` — 30 files, unedited, pulled guest → nslab → here. Includes the three raw tmux pane
  captures, the three API samples, and the archived manual page.
- `scripts/` — the 12 scripts sent (`00`…`11`, plus the two nslab-side helpers `a8-run.sh` and
  `a8-pull.sh`).

[Co-developed with claude code -- Adam]
