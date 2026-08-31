# A P4/BMv2 demo VM, built to sit beside the existing pre-P4 one

**2026-08-31.** Adam: *"直接把有P4的VM做出來，然後跟現有的VM共存"* — build the P4 VM, and have it
coexist with the existing one rather than replace it.

The artefact is **`NDTwin-P4-demo.ova`**, 2 592 010 240 bytes,
sha256 `4965d003b544f239bc3d4ba20aa627c71235d3eb12b0741ce2a9723a6c251838`.
It is **not in the repo and has not been uploaded anywhere** — see "before this ships" below.
It lives at `/media/adam/Windows-SSD/ndtwin-vm/` with the scripts in this directory.

[Co-developed with claude code -- Adam]

---

## What it is

Not a fresh install. It is the `post-s6.7-nsr-ntg` snapshot of the clean-room image — the state
in which §1–§6.7 of the installation manual had already been executed and T-2 had shown the
fabric forwarding — flattened into a standalone disk, stripped of scaffolding, and packaged.

| | |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| P4 | `p4c-bm2-ss` 1.2.5.16, BMv2 `1.15.5-fdd3b893` (stock **and** the §6.7 fast build) |
| stack | NDTwin Kernel (built), `p4_proxy`, Ryu in the `ryu-env` conda env, Mininet, OVS |
| logins | `tester`/`tester` (owns the install), `ndtwin`/`ndtwin`, root `ndtwin` |
| hardware | 4 vCPU, 6144 MB, SATA/AHCI, E1000 |

## What was verified, and how

The fabric acceptance below is the proven T-2 driver
(`doc/audit/2026-08-28_manual-verification-coverage/`), not a new script.

| run | when | result |
|---|---|---|
| 1 | flattened image, before cleanup | 32 links / 12 paths / **pingall 12/12** |
| 2 | after removing 5.3 GB (source trees, caches) | identical |
| 3 | after removing a further 3.3 GB | **FAILED — 0 links, 100% dropped** |
| 3′ | same image, orphaned proxy cleared | identical to 1 and 2 |
| 4 | **the disk unpacked from the finished `.ova`** | identical to 1 and 2 |

Run 3 is the reason this table exists. It was not the deletions: an orphaned proxy from run 2
still held `:8081`, so run 3's proxy refused to start — the P-1 guard working exactly as
designed. The wrapper-vs-child pid defect that orphans it is already recorded in
`install-manual-clean-room-test` §11.2. **Deleting 8.5 GB and then re-running is what
distinguished "safe removal" from "I broke it", and both answers appeared.**

Also verified, each on the accept path rather than by reading config:

* **Password login works** — `tester` and `ndtwin` both log in with the published passwords,
  and a wrong password is refused. This matters more than usual: the `.ova` ships one disk with
  no cloud-init seed, so a password is the only way in. Testing only the refusal would have
  proved nothing.
* **Boots without virtio** — root came up on `/dev/sda1` via AHCI and `ens3` took a DHCP lease
  on E1000. VMware offers neither virtio-blk nor virtio-net, so this was the single largest
  risk in the whole conversion. The OVF therefore declares the controller and NIC that were
  actually tested, not the conventional LSI Logic.
* **`ndtwin_switch.json` is a faithful compile of the shipped `.p4`** — recompiling differs
  byte-wise but is *semantically identical* once `source_info` is stripped; only the `program`
  filename field differs. A reader who follows §6.2 gets the same pipeline.
* **The OVA's own manifest verifies**, and the OVF parses with `capacity=64424509440`.

## Changes made to the image

* Added the `ndtwin` account (sudo) so the login table matches the page the website already
  publishes for the existing demo VM. **The install was not moved.** `p4_proxy/venv` has
  absolute interpreter paths in 11 console scripts and conda lives at `/home/tester/miniconda3`,
  so the tree is bound to `/home/tester`; `ndtwin` is an additional login and a README plus MOTD
  say so on sight rather than leaving a reader in an empty home.
* Removed ~8.5 GB of build scaffolding (`bmv2-fast-src`, `PI`, `behavioral-model`, `p4c`,
  `p4-guide`, `p4dev-python-venv`, `tutorials`, `mininet`, `ptf`, `p4runtime-shell`) and all
  harness output. Safe because every installed tool resolves outside those trees — `mn` is
  `/usr/bin/mn` against the apt package, the P4 binaries are in `/usr/local/bin`, and the fast
  build carries `RUNPATH=/usr/local/bmv2-fast/lib`.
* **Repaired `simple_switch_CLI`, which the above broke.** Removing `p4dev-python-venv` left the
  wrapper present and importing nothing — the worst state, because it looks installed. The
  bindings themselves were never deleted (`/usr/local/bmv2-fast/lib/python3.12/site-packages`),
  so a `.pth` plus `python3-thrift` restores it, and it now works from a plain login instead of
  requiring a 111 MB venv and a sourced `p4setup.bash`.
* Removed the `adam@ndtwin` automation key and shell history.

**Deliberately not done:** SSH host keys were left in place. Regenerating them is the usual
hardening for a distributed image, but cloud-init is disabled here and nothing else would
regenerate them, so sshd would fail to start and the shipped VM would have no SSH at all.

## 🔴 Before this ships

1. **The image contains the private repo.** `/home/tester/Desktop/NDTwin-Kernel` is the full
   source of `ndtwin-lab/NDTwin-Kernel-P4`, restored from `ndtwin-kernel.bundle`
   (`fix/flow-rate-divide-by-zero` @ `059a92c`, 2026-08-27). **Publishing this VM publishes that
   source.** The standing ruling is that the repo stays private until after review, so this
   cannot be uploaded until that ruling changes. It is also a *branch from 27 August*, not
   current `main` — if the demo should carry current code, the tree needs refreshing first.
2. **Nothing on the website has been changed.** Making the two VMs coexist needs page edits
   that have not been made: the existing Demo VM page documents a Kernel/Ryu/Mininet image with
   no P4, and this one would need its own entry, its own weight, and a note distinguishing them.
3. **Untested on real VMware.** AHCI + E1000 were verified under qemu, and the manifest and OVF
   parse, but no VMware product was involved at any point.

## Files here

| script | what it does |
|---|---|
| `p4demo.sh` | boots the product image — separate from `vm.sh` on purpose, and with `-cpu host` and no seed disk |
| `guest_prepare_demo.sh` | accounts, README/MOTD, first cleanup pass |
| `guest_prepare_demo_p2.sh` | second pass; exists because the first was decided from a truncated `ls` |
| `guest_fix_sscli.sh` | repairs `simple_switch_CLI` and verifies it against a live switch |
| `package_ova.sh` | OVF descriptor, manifest, and the tar, without `ovftool` |
