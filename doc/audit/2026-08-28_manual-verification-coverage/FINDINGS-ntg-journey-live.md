# NTG documentation journey — run live, plus a limit of the clean room itself

2026-08-30 19:46–19:49. Harness `vm/guest_ntg_journey.sh` (`649006c`), committed before it ran.
Raw: `~/ntg-results/`. Scope: the install page's four blocks and the usage page's block 7; the
rest of the usage page needs Ryu, a fabric and a kernel, so it was **not attempted** rather than
attempted and excused.

**5 PASS · 3 FAIL · 1 N/A.** All three failures are documentation, and all three were predicted
from reading before the run.

---

## The three defects, now measured

| id | block, as printed | result |
|---|---|---|
| **NTG-I2** | `pip install --upgrade pip` / `pip install loguru prompt_toolkit nornir …` | 🔴 `externally-managed-environment` |
| **NTG-I4** | `pip install --upgrade pip` / `pip install fastapi "uvicorn[standard]" …` | 🔴 same refusal — **the same page carries the defect twice** |
| **NTG-U7** | `python network_traffic_generator.py` | 🔴 **rc=127, command not found** |

Working as printed: **NTG-I1** (the `apt` block — Python 3.12.3, pip 24.0) and **NTG-I3** (the
clone).

### Pass 2 settles whose fault they are

**NTG-R1 and NTG-R2 both PASS** — all ten runtime dependencies *and* the five worker-node ones
install cleanly into a venv. ⇒ **I2 and I4 are documentation defects, not broken dependency
sets.** That is the entire purpose of the second pass.

**NTG-R4 PASS** — the three files the page names by hand (`network_traffic_generator.py`,
`network_traffic_generator_worker_node.py`, `NTG.yaml`) are all in the clone.

### U7 is an internal inconsistency, which is what makes it a defect

Block 2 of the same page writes the interpreter out in full —
`sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py`, with a comment about using the
environment from the Installation Manual — and block 7 then says a bare `python`, **with no
activation step printed between them**. The page knows the interpreter is special and then stops
saying so. On a clean 24.04 guest there is no `python` at all.

**PEP 668 now has four instances across the Tools line** — NSR install ×1, NTG install ×2, NTG
usage ×1 — and **not one of the Requirements sections mentions a virtualenv**, while the Kernel
manual mandates the OS on which it is the default. This is one fix repeated, not four fixes.

## 🔴 A limit of the clean room, not of NTG — and it would have been a false finding

`NTG-R3` was deliberately left `N/A`: "entry point exited rc=1 without a fabric; whether that is
a clean refusal or a crash is a question for the log, not for this gate." Reading the log:

```
RuntimeError: NumPy was built with baseline optimizations:
(X86_V2) but your machine doesn't support:
(X86_V2).
```

Cause, measured on both sides:

| | `sse4_2` | `popcnt` | `ssse3` | `sse4_1` | `cx16` |
|---|---|---|---|---|---|
| **guest** (`QEMU Virtual CPU version 2.5+`) | ✗ | ✗ | ✗ | ✗ | ✓ |
| **host** | ✓ | ✓ | ✓ | ✓ | ✓ |

The VM runs QEMU's default `qemu64` CPU model, which predates **x86-64-v2**. PyPI's NumPy wheels
are built to that baseline, so `import pandas` cannot succeed in this guest **whatever NTG or
the manual say**.

🔑 **Written up as an instrument limit because that is what it is.** "NTG crashes on import"
would have been a false finding about the software, and the gate that produced it was written to
be `N/A` precisely so it could not be read that way before someone looked.

### What this costs the VM verification programme

The clean room exists to model **a reader's machine**. On this axis it models a machine no
reader has: any dependency with an x86-64-v2 baseline — NumPy, pandas, and a growing share of
scientific wheels — **cannot be exercised in it at all**.

That bounds every VM result to date. It does not invalidate any of them: §1–§6.7, NSR and NTG's
install journeys are `apt`, `git`, `pip`, `cmake` and shell, none of which need v2. But **NTG's
runtime, and anything else numpy-shaped, is outside what this instrument can reach.**

**Repair, not applied tonight:** give the guest `-cpu host` (or any v2-capable model) in
`vm/vm.sh`. It is a one-line change to a tool three sessions share, and changing a shared
instrument at the end of a working night — with results from it already committed — is how a
programme loses track of which results came from which instrument. Registered instead.

## Still not covered

The usage page's blocks 1–6 and 8: Ryu, the topology script, the kernel, and the worker-node
`uvicorn`. All need a fabric. Note also that block 8's `--port 8000` is the kernel's port, safe
only because the surrounding prose puts worker nodes on other machines — see
`FINDINGS-tools-pages-desk-check.md` N-7, where my first reading of that was withdrawn.

[Co-developed with claude code -- Adam]
