# A P4/BMv2 demo VM, built to sit beside the existing pre-P4 one

**2026-08-31.** Adam: *"直接把有P4的VM做出來，然後跟現有的VM共存"* — build the P4 VM, and have it
coexist with the existing one rather than replace it.

**This artefact has been superseded three times in one day. Only this table is current:**

| | |
|---|---|
| file | `NDTwin-P4-demo.ova` |
| bytes | **2 757 157 888** |
| sha256 | `af1d373093b6493c56f40d5e2740d4c7c2d2db642189a9689196ad1d5d853ee4` |
| md5 | `b56c588275f13651fc343639f13a6ec7` |
| packed by | **ovftool 5.1.0 (build-25410048)** — not the hand-written descriptor |
| declares | `<Name>NDTwin-P4-demo`, `vmx-14`, 4 vCPU, 6144 MB, SATA/AHCI, E1000 |
| lives at | `nslab:/home/nslab/NDTwin-P4-demo.ova` (mode 600). **Not in the repo, and no longer on this machine** — the last build was produced on nslab and never came back over the VPN. |

**The three superseded builds, and why each died:**

1. `4965d003…` / 2 592 010 240 B — **shipped the EuroP4 poster submission package.** Kept only
   as `NDTwin-P4-demo-CONTAMINATED-DO-NOT-SHIP.ova`, alongside `ndtwin-p4-demo-work.qcow2`,
   which has the same defect. Neither may be distributed. See *"The image shipped the
   submission package"*.
2. `c832c91a…` / 2 513 469 440 B — clean, but **VMware cannot import it**: the hand-written
   manifest is rejected on the conversion path. Still at
   `/media/adam/Windows-SSD/ndtwin-vm/NDTwin-P4-demo.ova`, and 🔴 **still the file on Google
   Drive**. See *"What ovftool caught"*.
3. `b7f0f7fb…` / 2 757 157 888 B — importable, but declared **`vmx-99`**, a hardware version no
   VMware product implements, and named the VM **`x`**. Same section.

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

1. **The image contains the private repo.** `/home/tester/Desktop/NDTwin-Kernel` is the working
   tree of `ndtwin-lab/NDTwin-Kernel-P4` (**PRIVATE** — `gh repo view` says PRIVATE and an
   unauthenticated `curl` returns 404; both were run, because either alone is a weaker claim).
   **Publishing this VM publishes that source.** Git metadata has been removed, so the commit is
   now recorded in `/home/tester/Desktop/NDTwin-Kernel/PROVENANCE.txt` inside the image:
   **`main` @ `20cd80b6`, 2026-08-28 10:46:57**.

   🔴 **This line previously said `fix/flow-rate-divide-by-zero` @ `059a92c`, 2026-08-27. Both
   the branch and the commit were wrong, and the mechanism matters more than the values:**
   `059a92c` is the head of `ndtwin-kernel.bundle` — the *channel* the source travelled through —
   and I recorded it as the *content of the image*. The image had been updated after that
   transfer and its checked-out tree was three days newer. The correct value was obtained by
   booting the image and asking it, which is the only thing that could have produced it.
   Same family as the "a page is a pointer" error two sections down, and the second instance in
   one session. **Executable form of the rule: to record what is inside X, read X — never read
   the thing that points at X.**
2. **A draft of the page edits exists but is not published** — `NDTwin-Website` `84d0318`,
   local, not pushed. Both download points sit in one table on the Download page; the P4 row
   deliberately has no link, because a placeholder URL would be worse than an honest gap.
3. ~~**Untested on real VMware.**~~ **Closed 2026-08-31 evening** — ovftool 5.1.0 was obtained
   and run, and it refuted the artefact. See *"What ovftool caught"*. The one path still not
   exercised is VMware's LSI Logic Parallel, and it never will be here: qemu's LSI device is
   driven by `sym53c8xx`, VMware's by `mptspi`. The OVF declares AHCI, which is what was tested.
4. 🔴 **The file on Google Drive is build 2, not this one.** `1x7XhKiU7SQUclg4sOGRbDZ_1iy7mp-em`
   serves `NDTwin-P4-demo.ova` at **2.3G** to an unauthenticated client — measured, not
   inferred, by fetching the download page with no credentials. That is the size of build 2,
   the one whose manifest VMware rejects. **Every download so far has been of an archive that
   cannot be imported.** Replacing it is Adam's action; the file to upload is on nslab.

## What ovftool caught

Adam obtained **ovftool 5.1.0** on nslab. It is free of charge but gated behind a Broadcom
account, which is why it could not be fetched here. Three findings, in increasing order of how
badly they would have shipped.

**🔴 `--verifyOnly` does not verify the disk.** Two negative controls were run against it: an
archive truncated to 200 MB, and one with a byte flipped in the middle of the disk. **It
returned 0 on both.** Without those controls this file would now be recording "verified with
VMware's own tool" for an archive VMware refuses. The name of a check is not its contract, and
the controls are what caught it — not suspicion, because the tool did not look suspicious.

**🔴 The hand-written manifest is rejected on the path a user actually takes.** `ovftool x.ova
out.vmx` — the conversion an import performs — fails with `Error: SHA digest of file
NDTwin-P4-demo-disk1.vmdk does not match manifest`, even though `sha256sum` recomputes the
manifest's own value exactly. **The mechanism was not chased.** The fix was to stop hand-writing
the descriptor and let ovftool pack the archive, which removes the whole class rather than the
instance. *If anyone hand-writes an OVA here again, that hole is still open.*

**🔴 The rebuild that fixed it introduced a defect its own check could not see.** Converting
through an intermediate `.vmx` with `--lax` prints *"Hardware compatibility check is disabled"*
and writes `virtualhw.version = "99"`; the `.ova` built from it declared
`<vssd:VirtualSystemType>vmx-99` — a hardware version that does not exist — and took the
intermediate's filename as the VM's display name, `<Name>x`. The archive passed
`The manifest validates` → `Completed successfully`, and passed a working negative control,
**because that control tested the disk hash and the defect was in the hardware declaration.**

🔑 The general shape: *I verified the mechanism (does ovftool accept this) and reported it as
the purpose (will a user's VMware import this).* A control only covers the dimension it varies.
Fixed with `--maxVirtualHardwareVersion=14` plus a correctly-named `.vmx` round trip; the
product declares `vmx-14`, the conversion now completes **without `--lax`**, and a flipped byte
still fails on the same path.

### One check that failed by printing an answer

Before running the fabric acceptance again, the cheaper substitute was tried: hash both
decompressed disks and show they match. `qemu-img convert -f vmdk -O raw disk.vmdk /dev/stdout
| sha256sum` **cannot resize a pipe**, so it converted nothing — and the pipeline still printed
`e3b0c442…`, the sha256 of zero bytes. It ran identically on both machines and would have
"proved" the two images identical no matter what they contained. Abandoned in favour of running
T-2 on the artefact itself.

### The fabric acceptance now exists on the artefact that ships

Everything in the table at the top of this file is an ovftool repack of the disk T-2 originally
ran on, and the only check any repacked disk had was a boot confirming three binaries are on
`$PATH`. *"The binaries are there"* is not *"the fabric forwards"*, and the download page makes
the second claim. So T-2 was re-run on the final archive, booted on the hardware the OVF
declares — SATA/AHCI, 4 vCPU, 6144 MB — rather than on convenient virtio:

| | |
|---|---|
| booted from | `/dev/sda1` (AHCI), `ens3` up (E1000) |
| switches | 10 passed verification |
| paths | 12, two consecutive agreeing samples |
| data plane | **`Results: 0% dropped (12/12 received)`** |
| `failures` | 1 — *twin reports 14 switches, expected 10*, plus the known `M-3` proxy refusal |

The PASS/FAIL list is identical to the runs on the earlier disks, including both known
failures, so the repacking changed nothing T-2 can measure.

## The image shipped the submission package

The auditor asked one question before the upload: *was the source in the image cloned, or was a
working tree packaged?* The answer turned out to be neither — **the working tree's `.git` went in
whole**, and with it the EuroP4 poster submission bundle that `.git/info/exclude` keeps out of
sight.

| | |
|---|---|
| objects matching the submission package | **77** (60 blobs, 17 trees) |
| the abstract itself | `doc/2026-08-29_europ4-poster-abstract/` — `abstract.tex`, `refs.bib`, `NOTES.md`, `make_figs.py`, `figs/` |
| review data | `doc/audit/2026-08-29_europ4-poster-review/` |
| reachable from | `refs/remotes/origin/fix/flow-rate-divide-by-zero` @ `c745f216` (2026-08-30) |
| checked out in the tree? | **no** |
| retrievable? | **yes** — `git cat-file -s` returned 1147 bytes of `MACHINE-ENV.md` |

🔑 **Every ordinary check said clean.** `ls`, `find`, `grep -r` and `git status` all reported
nothing, because the files were never checked out. Only `git rev-list --objects --all` saw them.
Proving *retrievability* rather than mere presence is what closed the argument that this was a
theoretical risk.

`ndtwin-kernel.bundle` is clean — 0 matches, tip `059a92c` dated 2026-08-27, which predates the
poster work entirely. **So the contamination arrived through a channel that was never recorded**,
after the transfer this file documented. Checking the intended channel would have returned "clean"
and been wrong; only the artefact could answer.

### How it was removed, and why each step is not the obvious one

Adam's ruling was to delete `.git` outright rather than rewrite history: the acceptance criterion
for "no `.git` exists" is checkable, whereas "the filter caught everything" has to be trusted.

* **`rm` was not trusted.** Unlink is not overwrite, and `qemu-img convert` copies allocated
  blocks — a deleted packfile would have been copied into the `.ova` and stayed recoverable. So
  before deleting, eleven 64-byte samples were taken at fixed *fractions of the packfile*, from
  inside the guest.
* **The first sampling method was wrong and was caught.** Sampling the qcow2 at offsets near a
  confirmed hit returned a window reading `t-Using: rust-hyper-rustls (= 0.24.2-2)` — apt
  metadata. A qcow2 offset does not stay inside one file, so "bytes near the packfile" is not
  "packfile bytes". `scan_packfile_residue.py` samples the file, not the image.
* **Deletion → `fstrim` (49 GiB) → zero-fill → `fstrim` (14 GiB).** The first pass alone left
  residue; "mostly overwritten" is not a property worth shipping.
* **Result: control 12/12 samples findable, product 11/11 gone.** A search that returns zero
  because it is broken looks exactly like one that returns zero because the data is gone, so the
  control is what makes the zero mean anything.
* **Residue, reported rather than rounded off:** the first ~200 bytes of `packed-refs` survive,
  lodged in the slack of a live file where neither zero-fill nor discard reaches. Its entire
  content is three branch names (`main`, `audit-raw`, `fix/flow-rate-divide-by-zero`) and their
  SHAs. No EuroP4 string, no submission content, no poster path. The SHAs are not retrieval keys:
  all three, plus the commit that introduced the package, return **422** from the public repo's
  API while a known-public commit returns **200**. And they disclose nothing the image does not
  state on purpose — `PROVENANCE.txt`, the MOTD and the OVF annotation all name the project.

### Acceptance after the rebuild

Run on the disk unpacked from the finished archive: 0 `.git` directories, 0 keyword matches by
path and by content (with a non-empty control), `PROVENANCE.txt` present, all three P4 binaries
resolving, and T-2 giving **0% dropped (12/12)**.

T-2 also reported `failures: 1` — *twin reports 14 switches, expected 10*. **That was not assumed
to be pre-existing.** The same driver was run against the image with `.git` still present, and the
full PASS/FAIL list is identical line for line, including the known `M-3` proxy refusal. Deleting
`.git` changed nothing that T-2 measures.

## What the published demo VM actually is — and how I got this wrong once

**Corrected 2026-08-31.** This file first said the existing image was "the pre-P4 one from
February". That was reasoned from the *pointer*, not the artefact: the page's component list
(Kernel/Ryu/Mininet) and the fact that `1efc7b1 Update vm image link` (xxxPatty, 2026-02-13)
was the last commit to touch the URL. Both describe the link, not the file behind it.

Measured instead, by fetching the first 1 MB of the download and reading the OVF that the OVA
spec puts first in the archive:

| | |
|---|---|
| served as | `NDTwin.ova`, **17 900 278 784 bytes** |
| last modified | **2026-08-31 11:29:12 CST** |
| internal name | `NDTwin-Testbed-20260831` |
| generated by | `VMware ovftool 5.0.0 (build-25296333)`, **11:18:39 CST the same day** |
| hardware | 16 vCPU, 16384 MB, `vmx-21`, disk on SCSI lsilogic, E1000, plus a 1.47 MB floppy and a 99.9 MB ISO |

So the public image was replaced hours before this VM was built, and **the website needed no
change for that to happen** — the link is a Drive file ID, so replacing the content at that ID
leaves every page untouched. That is why the page still describes the old contents.

**Adam confirms the replacement image does not contain P4**, so this VM fills a real gap rather
than duplicating it. It also establishes that someone in this project has ovftool 5.0.0 and was
using it that morning, which is the shortest route to the VMware verification item above.

🔑 The general shape, and it is the second time in one session: *a page is a pointer, and a
pointer cannot tell you its target changed.* Same family as
`memory: local-git-refs-cannot-tell-you-what-is-public` — `git log` on the line containing a URL
answers "when did we last edit this link", never "what is at the other end now".

## Files here

| script | what it does |
|---|---|
| `p4demo.sh` | boots the product image — separate from `vm.sh` on purpose, and with `-cpu host` and no seed disk |
| `guest_prepare_demo.sh` | accounts, README/MOTD, first cleanup pass |
| `guest_prepare_demo_p2.sh` | second pass; exists because the first was decided from a truncated `ls` |
| `guest_fix_sscli.sh` | repairs `simple_switch_CLI` and verifies it against a live switch |
| `package_ova.sh` | OVF descriptor, manifest, and the tar, without `ovftool` |
