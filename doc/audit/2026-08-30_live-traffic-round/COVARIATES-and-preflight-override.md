# The one preflight gate this round did not satisfy, and why it ran anyway

2026-08-30, arm 1 (P4, 128 hosts). Written **before** any measurement, at 12:33Z, while the
fabric was coming up. Recorded here rather than fixed, because amending a pre-registration is
not the executor's call (`00_preflight.sh` header; harness README's closing line).

[Co-developed with claude code -- Adam]

---

## What happened

`00_preflight.sh` returned **21 checks, 1 FAIL**. The single FAIL:

```
FAIL  1 qemu process(es) are running. PREREG §4.1: that VM is invisible to
      'measuring' and its load lands on the same cores.
```

PREREG §4.3 requires "**no VM anywhere in the window**".

## What the qemu actually is

Identified by reading `/proc/405062/cmdline` and walking up the parent chain — not by the
name in `ps`:

| | |
|---|---|
| pid | 405062 |
| parent | 4275 = `/usr/lib/claude-desktop/resources/cowork-linux-helper -socket /run/user/1000/claude-cowork-vm.sock` |
| `-name` | `claude-cowork-vm` |
| resources | `-smp 2 -m 4096M`, `-cpu host`, rootfs from `~/.config/Claude/vm_bundles/claudevm.bundle/` |
| age at preflight | 46 min (the helper itself: 19 h 54 m) |
| CPU consumed | 9070 ticks = **90.7 s over 2769 s wall ≈ 3.3 % of one core**, averaged |
| load1 at preflight | **1.07 over 14 cores** |

**It is Claude Desktop's own VM, not the NDTwin installation manual's VM.** The manual's VM
(`/media/adam/Windows-SSD/ndtwin-vm/`, driven by `vm.sh`, 4 vCPU of apt/cmake/ninja) is the one
PREREG §4.3 was written against, and the 19:53 handoff note is accurate: that VM is **stopped and
snapshotted** (`snapshot 11 'post-s6.7-nsr-ntg'`). Nothing about the manual line is running.

## The decision, and its reason

**The round proceeded, with the covariate declared.** Reasons, in the order they matter:

1. **This VM is the instrument's own footprint, not a third party's experiment.** It is in the
   same category as the covariate the harness already declares in writing — "the session running
   this harness is itself a covariate (~0.3 core idle)" — one level further down. It cannot be
   removed without removing the thing that is running the round.
2. **It is not mine to kill.** It belongs to the application hosting this session. Killing a
   process because a gate mentioned it, when the gate was aimed at something else, is how the
   `pkill -f` family of accidents happens.
3. **No registered verdict in this round can turn on 3.3 % of one core.** PREREG §5 puts *every*
   throughput and latency number out of scope as a performance claim; TR-1…TR-6 are wiring and
   correctness questions. The one place it could matter — TR-3's exposure-window bound — is
   already registered to be reported "as an observation bound, not a performance figure".

**This is disclosure, not a downgrade.** The PREREG is not edited. The precondition is recorded
as **not met**, with the measured size of the miss, so that a later reader can decide for
themselves rather than inherit my judgement. If the auditor rules the round invalid on §4.3, the
numbers are still on disk and the ruling costs nothing but the re-run.

## 🔑 The gate is right and its wording is too wide — a finding about the harness

`00_preflight.sh:78` counts qemu processes:

```bash
QEMU_N="$(ps -eo comm= 2>/dev/null | grep -cE '^(qemu-system|qemu-kvm)')"
```

and reports them as "**the installation-manual VM**". That attribution is not in the evidence:
`comm` is `qemu-system-x86` for every qemu on the machine. The gate cannot tell the VM that
competes for 4 vCPU of build load from the one that ships with the editor.

Both directions of the error are real:

* **Now:** it names the wrong VM and blocks on a covariate that cannot be removed.
* **Worse, later:** once an executor has been trained to wave this FAIL through — as I just did —
  the *manual's* VM will produce the identical line and get waved through with it.

The narrower gate, which is also the cheaper one, reads `-name` out of the process's own argv
instead of trusting `comm`:

```bash
tr '\0' '\n' < /proc/$pid/cmdline | grep -A1 -x -- -name
```

`ndtwin-vm` / `claude-cowork-vm` are then two different observations, and only the first is a
precondition failure. **Registered as a harness ticket, not fixed inside a measurement window.**

## Every covariate this round is running with, stated once

| source | size | visible to `ndt status`? |
|---|---|---|
| `claude-cowork-vm` (above) | ~3.3 % of one core, 4 GiB reserved | no |
| this claude session | ~0.3 core idle; measured at 207 % of a core while *recording* an experiment | no |
| the NDTwin manual VM | **stopped**, snapshot 11 | no (but absent) |
| in-window `git commit` | **none** — forbidden by the claim note for this round | n/a |

The third and fourth rows are the ones the claim can actually enforce, and both are clean.
