# §1–§5 clean-room replay — the host-side scripts

Rescued into the repo 2026-08-29 ~23:05, **before** being run, because they had been living
only on an unmounted disk. This is the second time in one day that evidence failed to outlive a
handoff; the first was the chaos round's binary provenance, which survived only in a transcript.

## Identity of these files

These are the **exact bytes** written on 08-28/08-29 and described in `../COVERAGE.md` as
"designed, written, syntax-checked, dry-tested". They were **not** reconstructed from memory.
Verified by `sha256sum -c` against the originals at copy time:

| file | sha256 | bytes | lines |
| :--- | :--- | ---: | ---: |
| `guest_sections_1_5.sh` | `71940ceb0a5e175e10e4accb7c7cc2db7b97c932779df4d0669f2fb5e5bab6f0` | 14949 | 232 |
| `test_sections_1_5.sh`  | `6fdd922b6a85e3093986fa9a04e1578f2e55e1bfe718d9c587c14f4cfb2f25f2` | 4418 | 83 |
| `vm.sh`                 | see `git log` for this file's arrival | 12484 | — |
| `wait_ssh.sh`           | — | 686 | — |

`bash -n` passes on both §1–§5 scripts as committed.

`vm.sh` and `wait_ssh.sh` are here because `test_sections_1_5.sh` calls both; committing only
the two scripts named in the handoff would have preserved a driver with two missing limbs.

## What this does NOT preserve

🔴 **The VM itself is not in the repo and cannot be.** `disk.qcow2` is **17.8 GB** and carries
six snapshots, of which only `fresh` (ID 1, 2026-08-27 12:41:45) answers the question these
scripts exist to ask. So what is committed here is the **procedure**, not a reproducible run:
someone with these files but without that qcow2 can read exactly what was going to be done, and
cannot redo it.

The snippets pushed to the guest come from `~/NDTwin-Website/assets/snippet/` — a **different
repo**, and deliberately so (see `../SNIPPET-CANONICAL.md`). They are not vendored here.

## Where the originals live

`/media/adam/Windows-SSD/ndtwin-vm/` — the Windows partition (`/dev/nvme0n1p3`), which is **not
in `/etc/fstab` and is not mounted at boot**. Mount it with:

```bash
udisksctl mount -b /dev/nvme0n1p3 --no-user-interaction
```

That needs no password (polkit allows it for the desktop user); `sudo mount` would prompt, as
`mount` is not in this host's NOPASSWD set.

⚠️ **`../COVERAGE.md` and `harness/STATUS.md` both said `/mnt/win/ndtwin-vm/`. That path is
wrong** — `/mnt/win` is an empty directory, not a mount point, and udisks mounts under
`/media/`. The paths in `COVERAGE.md` have been corrected to point here.

## The guard in vm.sh — do not override it

`vm.sh` reads `exclusive_cpu` from `.test_run/lab.claim` and refuses to boot when a claim
declares it. **Do not set `VM_ACK_EXCLUSIVE_CPU=yes`** without the claim holder's actual
agreement. A 4-vCPU build is invisible to `ndt status`'s `measuring` column while competing for
the same cores, so it lines its load up with whatever the claim holder is timing — the same
failure family as the other invisible load sources.

[Co-developed with claude code -- Adam]
