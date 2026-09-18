# bring_up_replay — the byte-identity evidence for TICKET-P1D, regenerable

[Co-developed with claude code -- Adam]

## What it answers

P1-D merged two copies of the bmv2 bring-up into one function that both entry points call.
The claim that has to survive that merge is:

> with no app package, `p4_testbed_topo.main()` and `ntg_bmv2_topo.main()` ask the fabric for
> exactly what they asked for before — the same bmv2 argv, the same static-ARP commands, the
> same switch order, the same `net.get` sequence, the same switch manifest.

That claim was originally checked in a session scratchpad, which is the same as not checking
it: a number nobody else can reproduce is a sentence, not a measurement. This directory is the
check, in the repo, runnable.

```
bash p4_proxy/tests/fixtures/bring_up_replay/replay_ab.sh          # defaults to base 41d7950f
bash p4_proxy/tests/fixtures/bring_up_replay/replay_ab.sh <rev>    # any other pre-change rev
```

`VERDICT.txt` is the output of that command at the commit its header names. Re-run it and the
four comparison lines should read the same; if they do not, either the bring-up changed or the
rev did, and the diff says which key moved.

## What it does NOT start

Nothing. `replay.py` replaces `os.system` (so `sudo mn -c` never runs), `time.sleep`, Mininet's
`CLI`, NTG's `command_line`, the orphan reap, the held-port refusal and — see below —
`write_manifest`, all before either `main()` is entered. No sudo, no Mininet, no bmv2, no root.
It is safe to run while a fabric is up, and it has to be.

🔴 **`write_manifest` is forced to a temp file, not merely pointed at one.** The pre-change
`main()` calls `write_manifest(switches)` with no path, and that default was bound at `def`
time to the real `/tmp/ndtwin_p4_switches.json` — so patching the module's `MANIFEST_PATH` does
not reach it. The first version of this harness therefore overwrote the machine's own switch
manifest (2026-09-18 11:40; nothing was live at the time and the file was removed). The wrapper
in `replay.py` is why that cannot happen again.

## Two things it is not

* **Not a test.** `tools/test_workflow/l1_unit_tests.sh` globs `p4_proxy/tests/test_*.py`; this
  lives under `fixtures/` and is never collected. The assertions that run on every gate are in
  `p4_proxy/tests/test_fabric_bring_up.py`, which drives both `main()`s over one recording net
  and compares them to each other. This harness adds the axis that suite cannot have: the
  comparison against code that is no longer in the tree.
* **Not live.** Every switch, host and process is a recording object. What it proves is what
  the code would ask for, not what a fabric would then do.

## Reading the verdict

At **4 hosts** all four recordings are identical, which is the ticket's requirement.

At **128 hosts** one line differs, deliberately, and it is the merge of a disagreement rather
than a new decision: the two copies batched the all-pairs ARP differently.
`p4_testbed_topo.main()` put all 127 entries in ONE `cmd()` — 4717 bytes, which Mininet
truncates, measured to leave h1 holding entries for h2..h112 and nothing after — while
`ntg_bmv2_topo.py`, the copy `ndtwin-lab topo-start` actually runs, chunked them in 32s. The
chunked form survived the merge, so `ntg_bmv2_topo.main()` is identical before and after and
`p4_testbed_topo.main()` picks up the fix.

## A finding the harness produced on its own

`replay_ab.sh` has to write `host_count_override` into the pre-change tree before each arm.
That is not bookkeeping: the pre-change bridge built its host list from
`_host_count_override()` — the **file** — while the fabric was built from the **model**. Give
it a file saying 128 and a model with 4 hosts and it dies `KeyError: 'h5'`, which is the same
shape, on the same line of reasoning, as the `net.get('s5')` that ended the live round on
2026-09-18. `ndt up p4` keeps the two in step, which is why it stayed latent. The post-change
`bring_up` reads the model only, so it has no second answer left to disagree with.
