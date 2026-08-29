# Installation Manual §1–§5 — first clean-room replay

**2026-08-29 23:35 – 2026-08-30 00:42.** Run on the `fresh` snapshot, the only one whose §1–§5
had not already been performed against the pre-`b41b9e4` text. Scripts: `vm/guest_sections_1_5.sh`
(guest, one shell) and `vm/test_sections_1_5.sh` (host driver). Raw: `ab-results/sections1-5/`
on the VM disk, `s1-5.log` (234 KB).

Criterion, per the standing instruction: **what is under test is whether a person following the
page can get there — not whether a script exits clean.**

**Run 2** (2026-08-30 00:50–01:04) followed, with an announced `mkdir -p ~/Desktop` (S4) so the
sections M-1 hid could be reached. Both runs are reported here.

| | run 1 | run 2 (with S4) |
| :--- | ---: | ---: |
| steps run | 47 | 48 |
| non-zero exits | **13** | **2** |
| kernel binary built | **NO** | **yes** — 11.8 MB, 90 ninja targets |
| wall clock | 6 m 26 s | 13 m 56 s |

Run 2's two non-zero exits are both accounted for: step 21 is the failure §2.6's callout
documents as expected, and step 48 is harness defect H-14 below. **Nothing in run 2 is an
unexplained failure.**

### ✏️ Correction — my own, in the first version of this file

The first version of this document called run 1's 6-minute wall clock "the headline", on the
grounds that "the manual says the build takes one to two hours". **That was wrong.** The "one to
two hours" in the manual is the callout at §6's `install-p4dev-v8.sh` — the **P4 toolchain**
build. **§4.2 gives no time estimate at all.** Run 2 measured the real §4.2 build: **90 ninja
targets, about 7 minutes** on 2 cores.

So "six minutes is suspiciously fast" was never a valid inference; a complete §1–§5 takes about
fourteen. The way run 1's build was proven not to have run is the cmake error and the absent
binary, quoted below — evidence that never needed the timing argument. I reached for a number
that made the finding sound bigger and misattributed it in the process. M-1 itself is unaffected.

---

## M-1 🔴 `~/Desktop` does not exist, and the failure does not stop the reader

**§1 System Requirements asks for "Ubuntu 24.04 LTS".** It does not say *Desktop* edition. The
manual then uses `~/Desktop` **13 times** and never once tells the reader to create it. On
Ubuntu Server — the ordinary choice for a network-emulation host, and what §1 as written
permits — `~/Desktop` is absent.

What a reader following §4.1 gets, verbatim from the log:

```
--- [31] 4.1 cd ~/Desktop
    $ cd /home/tester/Desktop
    cd: /home/tester/Desktop: No such file or directory
    rc=1   cwd-after: /home/tester          <-- still in $HOME

--- [32] 4.1 clone
    $ git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4.git NDTwin-Kernel
    Cloning into 'NDTwin-Kernel'...
    rc=0                                     <-- SUCCEEDS, into the wrong directory
```

**The `cd` failing is not what makes this bad. The next command succeeding is.** The clone lands
in `$HOME/NDTwin-Kernel`, reports success, and the reader has no signal anything is wrong. Then:

| step | command | what actually happened |
| :--- | :--- | :--- |
| 4.2.1 | `cd ~/Desktop/NDTwin-Kernel` | fails, cwd stays `$HOME` |
| 4.2.2 | `rm -rf build` | **runs in `$HOME`** — here it hit nothing; on a reader's machine it deletes any `~/build` they own |
| 4.2.2 | `mkdir build && cd build` | creates a stray **`~/build`** |
| 4.2.3 | `cmake -GNinja ..` | `CMake Error: The source directory "/home/tester" does not appear to contain CMakeLists.txt` |

The error the reader finally sees points at the **source tree**, five steps after the actual
cause, and says nothing about `~/Desktop`. The obvious reading — "my clone is broken" — is wrong.

### 🔑 Why no previous pass caught it: the documented failure masks the undocumented one

§2.6 also runs `cd ~/Desktop/NDTwin-Kernel`, at step **[21]**, and the page carries a callout
saying that failure is **expected** ("You have not cloned the repository yet — that is Step 4.1").

That callout is correct, and on this machine it is also **wrong about the reason**. At step 21
the `cd` fails for *two* independent causes — the repo is not cloned *and* `~/Desktop` does not
exist — which produce the **same message and the same rc**. A reader reads the callout, correctly
concludes "expected, carry on", and the real defect stays invisible for another twenty steps.

An expected failure and an unexpected one sharing a signature, with the expected one arriving
first, is the same shape as the harness defects in `../2026-08-28_chaos-harness/05_first-live-run.md`.

### Fix — either is one line

* §1: state **Ubuntu Desktop**; or
* §4.1: `mkdir -p ~/Desktop && cd ~/Desktop`

§4.1 already reasons carefully about paths — "note the trailing `NDTwin-Kernel` … so every path
printed later in this manual works unchanged". The gap is not carelessness about location; it is
an assumption about the *machine* that §1 never states.

---

## M-2 ✅ §2.4 — the rejected external finding was rejected correctly

`b41b9e4` records a DeepSeek finding, **rejected**: that `pip install 'dnspython<2.3'` cannot
produce the 1.16.0 the page prints, because `<2.3` selects 2.2.1. The rejection reasoning was
that `eventlet==0.30.2` pulls 1.16.0 in first, so the later pin reports "already satisfied".

**Live, all four expected lines match:**

```
dnspython          1.16.0
eventlet           0.30.2
greenlet           2.0.2
ryu                4.34
```

The rejection stands, now on evidence rather than argument.

## M-3 ✅ §3.3 — the `b41b9e4` rewrite does what it was written to do

The section was changed from `ovs-vsctl --version` (which passes whether or not the daemon runs)
to commands that talk to the daemon, plus an instruction to read pingall's **Results line by name**.
Both halves worked:

```
*** Results: 0% dropped (2/2 received)      <-- the named line
completed in 0.165 seconds                  <-- the LAST line, which the page warns is not the answer
```

The contrast is a live demonstration of why the rewrite was needed: the last line contains no
pass/fail information at all.

## M-4 ✅ §2.5 — Ryu behaves as the rewritten text claims

Still running after 12 s (which the page says *is* success), and the loaded-app banner is present.

---

## Two "failures" that are the harness's, not the manual's

Recording these as harness defects so they are not read as findings.

### H-14 — `bash -lc` cannot test "open a new terminal" (step 47)

Step 47 checks §2.1 **option A** (`conda init bash`) by running
`bash -lc 'conda --version && conda activate ryu-env'`, which returned:

```
CondaError: Run 'conda init' before 'conda activate'
```

after `conda init bash` had just reported `modified /home/tester/.bashrc`.

This is **the harness's fault.** Ubuntu's stock `.bashrc` begins:

```bash
# If not running interactively, don't do anything
case $- in *i*) ;; *) return;; esac
```

`bash -lc` is **non-interactive**, so `.bashrc` returns before ever reaching conda's block.
Verified directly: `bash -lc` on this host does not source `.bashrc` at all. The page tells the
reader to "close and re-open your current shell" — i.e. a new **interactive** terminal, which is
precisely what this check does not create.

🔑 The check has **no discriminating power**: it fails identically whether option A works or not.
Testing it needs `bash -i` with a pty, or a fresh ssh session.
**§2.1 option A is therefore still untested.**

### H-15 — `kill -INT <pid>` is not Ctrl-C (§2.5)

The log notes ryu-manager "survived Ctrl-C (SIGINT)". It did not receive one. Ctrl-C delivers
SIGINT to the foreground **process group**; the harness backgrounded ryu-manager and signalled a
single pid, then waited 3 s. Not evidence about the page's stop instruction either way.

### H-16 🔴 — the dpid check prints a number that contradicts the claim, and passes anyway

Step 43 says it is testing `b41b9e4`'s claim that the topology JSON holds **exactly 138 dpid
nodes**. Run 2 printed:

```
dpid occurrences: 714
    rc=0
```

A reader of that log concludes the claim is refuted by a factor of five. **It is not.** The check
counts the *substring* `dpid` in `json.dumps(d)`, and each node carries it about five times over
its nested port entries. Counting objects that actually hold a `dpid` key:

```
objects that HAVE a dpid key: 138
nodes: list of 138          edges: list of 288
```

**`b41b9e4`'s claim is correct.** Two separate faults in one step: the instrument measures
something other than what it names, and it **asserts nothing** — it prints and returns 0, so it
would "pass" for any value whatsoever. Fix is `len(d["nodes"])` plus an actual comparison to 138.

🔑 This is the same shape as H-14: a check with no discriminating power, whose green result was
never evidence. The difference is that this one also printed a number **loud enough to look like
a finding**, which is worse — a quiet useless check wastes a slot; a loud one manufactures a
false result.

---

## ✅ What run 2 established — including the thing this replay was commissioned for

**§4.2.4, the step `b41b9e4` added, does what it was added to do.** Run 2, verbatim:

```
--- [39] 4.2.3 ninja           rc=0   cwd-after: .../NDTwin-Kernel/build
--- [40] 4.2.4 return to the project root (the step b41b9e4 added)
                               rc=0   cwd-after: .../NDTwin-Kernel     <-- out of build/
```

and §5 then lands where the page says it should, with the negative half of the assertion holding:

```
--- [45] 5 -- landed at the project root, not inside build/?
    -rwxrwxr-x 1 tester tester 9362 .../NDTwin-Kernel/testbed_topo.py
    correct: not in build/
    rc=0
```

The cwd chain — a reader inside `build/` when §5 says to edit `testbed_topo.py`, with §6.4 later
running `rm -rf build` — **is fixed, and is now verified by execution rather than by reading.**

The build is real: **90 ninja targets**, `bin/ndtwin_kernel` at 11,839,016 bytes.

## 🔴 What is still NOT tested

Overstating coverage here would be worse than the defect found.

| section | status |
| :--- | :--- |
| §1, §2.1(B), §2.2–§2.7, §3.1–§3.3, §4.1, §4.2, §5 | **exercised, pass** (run 2) |
| §2.1 **option A** | 🔴 **still untested** — H-14; the check has no discriminating power |
| §2.6 §3 "138 dpid nodes" | claim **verified separately** and holds; the in-run check does not test it (H-16) |
| §4.1 on a machine **without** `~/Desktop` | 🔴 **fails** — M-1, unfixed in the manual. Run 2 only passes because S4 works around it |

🔴 **Run 2 does not retire M-1.** It was run with the workaround in place; a reader on Ubuntu
Server still hits exactly what run 1 hit. M-1 stays open until the page changes.

---

## Reproducing

```bash
udisksctl mount -b /dev/nvme0n1p3 --no-user-interaction
```

Then `vm/test_sections_1_5.sh`. It restores `fresh` itself and refuses to run on any other
snapshot. Do not override `vm.sh`'s `exclusive_cpu` guard; claim the lab first and say in the
note that a VM is starting, because it is invisible to `ndt status`'s `measuring` column.

[Co-developed with claude code -- Adam]
