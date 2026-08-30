# T-4 baseline — what was built, and how it is identified *backwards*

Written 2026-08-30 14:52, **before** the round produced a single observation.

The ruling for this round pins the kernel to `89c1754`, whose source is byte-identical to the
PREREG's registered `faffdbe` across `src/`, `include/`, `p4_proxy/` and `tests/`. This file
records how that pin was realised and — the part that matters — how the binary is identified
from *itself* rather than from the story of how it was made.

🔑 `memory: benchmark-must-name-the-binary-it-measured`. Naming a commit is not provenance if
the only link between the commit and the binary is the sentence claiming they are related.

---

## Why a worktree was necessary, stated as a measurement

Not a precaution. The main checkout **cannot** serve as the baseline:

```
$ git diff --stat 89c1754 HEAD -- src include p4_proxy tests
 include/ndt_core/lock_management/LockManager.hpp |  73 +++++++++++-
 p4_proxy/proxy_agent/main.py                     |  49 ++++++++-
 p4_proxy/tests/test_port_guard.py                | 134 +++++++++++++++++++++++
 src/ndt_core/http/HttpSession.cpp                |  66 +++++++----
 tests/test_LockManager.cpp                       |  75 +++++++++++
 5 files changed, 373 insertions(+), 24 deletions(-)
```

`dff87f9` (T-7: the `acquire_lock` and P-1 fixes) sits between them and rewrites **exactly the
files under test**. PREREG §5 records `acquire_lock`'s three defects as out of scope and
present in the code under test — which is only true of the pre-fix build. Building from the
main tree would have silently tested the fixed code against a pre-registration describing the
broken one.

Everything else in `89c1754..HEAD` is doc-only: `git diff 89c1754 HEAD -- tools/ setting/
intelligent_router.py testbed_topo.py` is **empty**, so the tooling, topologies, Ryu app and
`spec.py` are common to both trees and nothing about them is ambiguous.

## The tree

| | |
|---|---|
| path | `/home/adam/Desktop/NDTwin-Kernel-t4-baseline` (`git worktree add --detach`) |
| HEAD | `89c17542775f87570278011eaf395ccaa34d160f` |
| `git status --porcelain -- src include p4_proxy/proxy_agent tests` | **empty** |
| build | `cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build -j6`, `nice -n19`, 14:46:35 → 14:52:00, rc=0, 100 % |
| build type | Debug — **matched** to the main tree's `CMakeCache.txt`, not chosen |

Four gitignored artefacts do not exist in a fresh worktree. Three are **symlinked** to the main
tree and one is built:

| artefact | disposition | why this is honest |
|---|---|---|
| `build/` | **built fresh** | the one thing that must be from `89c1754` |
| `p4_proxy/p4_src/build/` | symlink → main tree | `ndtwin_switch.p4` last changed in `f64897b` (08-25), *before* the baseline; the compiled JSON (08-27 12:48) **is** the baseline's pipeline |
| `p4_proxy/venv/` | symlink → main tree | `89c1754..HEAD` touches no `requirements.txt`; checked for editable installs pointing back at the main tree — only `protobuf-3.20.3-nspkg.pth`, no path injection |
| `.test_run/` | symlink → main tree | **required**, not a convenience — see below |

### `.test_run` must be shared, or the claim protocol silently disappears

`ndt` computes `CLAIM="$REPO/.test_run/lab.claim"` and `PID_DIR="$REPO/.test_run/pids"` from
its own location. Run from an unlinked worktree it would write a claim **no other session can
see** and register pids `ndt down` cannot find — the failure would look like a working lab.

Verified rather than assumed: a probe file written into the main tree's `.test_run/` reads back
through the worktree path (`probe-237575`), and no agent worktree on this machine has a
`.test_run` of its own, so every session's claim resolves to one file.

⚠️ **A near-miss worth recording.** The worktree's first `ndt status` said `claim none` while
the main tree said `t7b-release-renew`, and the obvious reading was "the symlink does not
work". It was not: `t7b` had released the claim in the intervening seven minutes and `release`
does `rm -f "$CLAIM"`. The disagreement was real and the diagnosis would have been wrong.
🔑 *Two of my own readings disagreeing is a finding about the instrument only after I have
looked at the thing itself* — here, `find … -name lab.claim`, which returned nothing anywhere.

## Reverse identification — three independent axes

"Built from `89c1754`" is a claim about the past. These are checks on the artefact in hand.

**1. Compilation directory, baked into the binary by the Debug build.**

```
DW_AT_comp_dir : /home/adam/Desktop/NDTwin-Kernel-t4-baseline/build
DW_AT_comp_dir : /home/adam/Desktop/NDTwin-Kernel-t4-baseline/build/src/utils
DW_AT_comp_dir : /home/adam/Desktop/NDTwin-Kernel-t4-baseline/build/src/ndt_core/collection
```

Rules out a binary copied in from elsewhere and relabelled. It does **not** by itself say which
commit — that is axis 3's job.

**2. Hashes.**

| artefact | sha256 |
|---|---|
| baseline kernel | `eb78019d89f161eb384bd9e0961a3c664dc9322149ed1e61a3b8796d52caa829` |
| main-tree kernel (**not** under test) | `2e969618f0695c404b27d52d59a7040bf5e55b5b1242eb4904f13c445ae38dc2` |
| baseline `proxy_agent/main.py` | `28c6b3e8f7ef85d7799f9ca66899d706fe2419f6fbaf66bc84f8d0cddb9d9486` |
| main-tree `proxy_agent/main.py` (**not** under test) | `db86706ed10c45a6738cf5fdbb62e16f69ef555dde4b80523b83a2d55e5b5a7d` |
| `simple_switch_grpc` | `3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a` (`/usr/local/bmv2-fast/`, root, 08-15 15:11) |

The two kernels also differ in size — 72 311 176 vs 72 312 168 bytes — so this was a live
mis-identification hazard, not a hypothetical one.

**3. 🔑 The strongest axis: identify the binary by the behaviour under test.**

A path proves where it was compiled; a hash proves it has not changed since. Neither says the
code under test is the code the PREREG describes. The T-7 fix introduced a 423 body that the
pre-fix kernel cannot emit, so its absence is a content-level statement about `acquire_lock`
itself:

| binary | `strings … \| grep -c "is held by another client"` |
|---|---|
| baseline (`89c1754`) | **0** |
| main tree (`c37abea`) | 1 |

Same on the proxy side for P-1, where the file is Python and needs no build:

| tree | `claim_listen_socket` | `REFUSING to start` |
|---|---|---|
| baseline (`89c1754`) | **0** | **0** |
| main tree (`c37abea`) | 2 | 1 |

⇒ kernel **and** proxy are both the pre-fix code, as the ruling requires, and the evidence for
that is the absence of the fix rather than the presence of a commit id.

**Axis 4, to be discharged during the round:** `sha256sum /proc/<kernel pid>/exe` must equal
`eb78019d…`. Axes 1–3 identify a file; only that one identifies the *running process*. Until it
is taken, nothing here proves the fabric ran this binary.

## What still points at the main tree, on purpose

| thing | tree | why |
|---|---|---|
| the harness (`harness/`) | main | it did not exist at `89c1754`; it is the instrument, not the subject |
| `.test_run/` claim, pids, logs | main (via symlink) | cross-session coordination must be single-file |
| sibling apps | `/home/adam` | `components.env` walks up for `Energy-Saving-App`; **verified to resolve identically from both trees** |

## Harness change this forced — `7dbda34`

`lib.sh:68` derived `REPO` from the harness's own location, i.e. it assumed the tree shipping
the harness is the tree under test. Under this round's pin that is false, and **nothing would
have gone red**: `00_preflight` would have hashed `2e969618…` into `binary-provenance.txt` as
the binary under test, and `40_`/`50_` would have answered F-1's and F-4's source checks from
post-fix source.

Now `REPO="${KERNEL_DIR:-…}"`, reusing the name `components.env` already means this by, so one
export makes `ndt`, `stack.sh` and the harness agree and no half-set state exists. Gate,
measured both ways:

```
KERNEL_DIR=<unset>      HEAD=c37abea  binary_sha=2e969618f0695c40
KERNEL_DIR=<worktree>   HEAD=89c1754  binary_sha=eb78019d89f161eb
```

## Run configuration for every step of this round

```bash
export KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel-t4-baseline
export NDT_BIN=$KERNEL_DIR/tools/test_workflow/ndt
```

`ndt`/`stack.sh`/`components.env` and the harness then all read the baseline tree, while
`.test_run` resolves to the shared one. `tools/` is byte-identical between the two commits, so
which copy of `ndt` runs is not a variable.

## Fabric state this round starts from

The stack up at 14:42 was the **poster round's shaped OVS** (htb 1 G) with kernel and Ryu still
running. Nothing from it is reused. Torn down at 14:51 and verified rather than assumed:
`bmv2 switches 0`, `host/switch processes 0`, `no topo session`, `no switch manifest`,
`ports 8000/8080/8081 closed`.

Lab claimed 14:49:45 → 16:18:45, `exclusive_cpu=yes`, owner `T-4 full-stack round`.

[Co-developed with claude code -- Adam]
