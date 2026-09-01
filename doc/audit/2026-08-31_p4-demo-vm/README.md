# A P4/BMv2 demo VM, built to sit beside the existing pre-P4 one

**2026-08-31.** Adam: *"直接把有P4的VM做出來，然後跟現有的VM共存"* — build the P4 VM, and have it
coexist with the existing one rather than replace it.

**This artefact has been superseded four times in one day. Only this table is current:**

| | |
|---|---|
| file | `NDTwin-P4-demo.ova` |
| bytes | **3 236 484 096** |
| sha256 | `72fac12806416869dc91037d6dd310dd6d2d9690d6294f0b36fe22f3ffbede79` |
| md5 | `ecfc603bbd40f5aeb54ec0320c4dd82b` |
| packed by | **ovftool 5.1.0 (build-25410048)** — not the hand-written descriptor |
| declares | `<Name>NDTwin-P4-demo`, `vmx-14`, 4 vCPU, 6144 MB, SATA/AHCI, E1000 |
| carries | the four application repositories, built and start-tested — see *"The applications went in"* |
| lives at | `nslab:/home/nslab/repack/out/NDTwin-P4-demo.ova`. **Not in the repo, and not on this machine** — every build since 19:00 was produced on nslab and none came back over the VPN. |

**The four superseded builds, and why each died:**

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
4. `af1d3730…` / 2 757 157 888 B — correct in every respect that had been checked, and it
   **carried three of the seven NDTwin source trees**. Adam: *"舊的VM應該有？確認一下，如果舊的也有
   tools，那新的也要有"*. The standard image has six; this one had three; each had trees the
   other lacked. See *"The applications went in"*.

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
| the abstract itself | `~/Desktop/NDTwin slide material/paper/abstract/` — `abstract.tex`, `refs.bib`, `NOTES.md`, `make_figs.py`, `figs/` |
| review data | `~/Desktop/NDTwin slide material/paper/review/` |
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

## The applications went in

Adam: *"新的VM有包含tool嗎？舊的VM應該有？確認一下，如果舊的也有tools，那新的也要有"*, then, asked
what "have them" should mean: **要能跑** — install the dependencies, build them, and start each
one once. That is a self-contained acceptance standard, and it is deliberately *not* "match the
old image", which matters because the old image's own inventory was never completed (the Google
Drive download was blocked by a quota all evening).

Six programs across four repositories, all built on the image and each started once:

| program | needs | verified by |
|---|---|---|
| `energy_saving_app` | **root**; mounts NFS at startup | serves `:8001` |
| `energy_saving_simulator` | — | runs to completion on an input file |
| `simulation_platform_manager` | **root**; mounts NFS at startup | serves `:9000` |
| `request_manager` | — | serves `:8002` |
| `Traffic-engineering-App.py` | `networkx`, `loguru` (both in apt) | reaches its menu and enters `run_te` |
| Network-Traffic-Visualizer | JDK 21, JavaFX on the module path | window opens and stays up |

### Four things that would have been recorded as passes

**A binary existed because the repository shipped it.** The first pass checked "is there an
executable at this path" and reported `energy_saving_app` built. It was *committed in the repo*.
That criterion cannot separate "I compiled this" from "the clone brought it", which is the same
shape as a test that passes because the fixture already contained the answer. Fixed by deleting
every binary first — which also means no unknown-glibc binary compiled by a stranger ships in
the image.

**`make` succeeded and built nothing.** Both C++ Makefiles define their settings-header rule
before `all`, and GNU make's default goal is the first non-special target in the file. Bare
`make` generates a header and exits 0.

**A keyword classifier matched a survivable error and hid the fatal one.** `energy_saving_app`'s
output contained `refused` — the kernel is deliberately absent — so it was filed as "started,
could not reach the kernel". It had actually died four lines later on `Mount NFS Failed`. Read
the last error, not the first.

**The jar that was tested was not the jar that runs.** `find target -name '*.jar' | head -1`
picked `original-NDTanimation-…jar`, the pre-shade artefact, which has no `Main-Class`; the
start check then failed and was recorded against the build. Replaced by selecting on the
property that matters — read `Main-Class` out of the manifest — with the rejected jar kept as
the control.

### The Visualizer is patched, and the reason is not ours

Upstream `main` (`9b56b30`) does not compile. `WindowStateRestore` is called from four places
(`SideBar.java` ×3, `InfoDialog.java` ×1) and is **declared nowhere in the repository** — it
never existed in its 13-commit history. The regression arrived in `9ef655f` (2026-03-31); `main`
is 2026-04-20. Adam's own working copy is that same commit and also lacks the class: it runs
only because of four uncommitted edits dated **2026-06-09 15:03** that comment the calls out. So
"works on my machine" and "the public tip is broken" have both been true since March.

The image ships `main` with **that exact patch, copied byte for byte** rather than retyped, and
`NDTwin-local-changes.patch` sits beside it so a recipient can `git apply -R` and see upstream.
The four sites are not the same edit — two need the wrapped call restored, one needs `}));`
turned into `});`, one needs its closing brace commented too — which is precisely why it was
copied and not reconstructed.

Cost of the patch, measured rather than assumed: **zero features.** `b5e039c..main` adds
window-state wrapping around dialogs that already existed, `getPrimaryStage()`, and a licence
header. Adam's ruling on reporting this upstream: **不回報，只記在我們自己的 audit 裡.**

### Two holes opened by this round, both closed

**The image would have booted an NFS server.** Phase D ran `systemctl enable --now nfs-server`;
the `enable` was reflex and nothing needed it. The README written in the same round says the
image "does not open ports without you saying so".

🔑 *How it surfaced is the reusable part.* The cold-boot check asked "are 8001, 8002 and 9000
closed?" — the three ports I had been thinking about — and they were. `nfs-server: active`
appeared only because it happened to be printed alongside. The question with discriminating
power was **"what is this image listening on at all"**, and it had not been asked. It is asked
now: a cold boot listens on `sshd` and the local DNS stub, nothing else, and `111`, `2049`,
`8001`, `8002`, `9000`, `20048` are all zero. `ndtwin-nfs-up` still brings NFS up on demand, so
the units still work with autostart off.

**The OVF annotation still described the old image.** It survived the repack unchanged, listing
only the kernel and toolchain, and pointing at `~/Desktop/NDTwin-Kernel/PROVENANCE.txt` for the
provenance of the stripped trees — a file that mentions **zero** of the four trees whose `.git`
was deleted tonight (measured: `grep -c` = 0). The front door was describing a different image
and indexing an index that did not cover it. Rewritten, and a third control added — *does the
declaration describe the contents* — alongside the existing hardware and integrity ones.

### The acceptance is two claims, not one

**T-2 has zero discriminating power for what changed.** It exercises mininet, ryu, bmv2 and the
kernel — none of which this round touched — so it would pass identically on the old artefact.
Running it alone and calling the image accepted is the arm that measured a switch that was
powered off. So both were checked on the booted shipping artefact:

* **regression** — 10 switches, 12 paths (two agreeing samples), 40 edges,
  `Results: 0% dropped (12/12 received)`, `failures: 1` (the known twin-reports-14 and the known
  `M-3` proxy refusal). Line for line the 19:23 baseline.
* **delivery** — four trees present with no `.git`, five build products present *after having
  been deleted pre-build*, `README-NDTwin-tools.md` (139 lines), `PROVENANCE.txt` (72 lines),
  the patch file, three units installed and disabled, cold boot listening on nothing, and each
  unit starting its port on demand.

### Two status lines that asserted what they had not measured

**`ndtwin-vm.sh adopt` reported `port=2222`** for a VM whose argv says `hostfwd=tcp::2296-:22`,
under a banner reading *"Read out of its argv, not typed in"*. Three of its four fields are
genuinely from argv; the fourth is a built-in default wearing the same label. Its regex requires
`hostfwd=tcp:127.0.0.1:`, the form that tool's own scripts emit.

🔴 **And chasing that turned up something of mine.** qemu documents the host address in
`hostfwd` as optional and binds **all interfaces** when it is omitted. Every VM in this round
used `hostfwd=tcp::<port>-:22`, so what was actually listening was `0.0.0.0:<port>` forwarding
to a guest whose password is `tester/tester` — measured, not inferred:
`ss -tlnH "( sport = :2297 )"` → `LISTEN 0 1 0.0.0.0:2297`. Exposure lasted the life of each VM,
on the lab network. The scripts in `tools-round/` are corrected to `tcp:127.0.0.1:`. *A parser
that only understands its own output cannot warn you about the input it does not recognise —
and that is exactly the input worth warning about.*

**My own harness printed an elapsed time it had not measured.** Two T-2 runs reported "reached
its summary after 20s" — not a plausible duration for starting mininet, ryu, ten BMv2 switches
and a kernel. The guest's own file timestamps settle it: `t2run.log` born `14:59:38.922`, last
written `15:01:48.234` — **130 seconds** — and `t2.log`, which the driver appends to, carries two
distinct start banners with different refusal counts (18 and 19). The run is real; the printed
figure is wrong. **I did not find the cause and am not inventing one.** The useful part is that
this is the control for the 19:23 run, which printed the same wrong figure: *"prints 20s" is not
evidence of "did not run"*.

## Files here

| script | what it does |
|---|---|
| `tools-round/` | the F–L phases that added the applications: build, start-test, strip, repack, and the three controls |
| `p4demo.sh` | boots the product image — separate from `vm.sh` on purpose, and with `-cpu host` and no seed disk |
| `guest_prepare_demo.sh` | accounts, README/MOTD, first cleanup pass |
| `guest_prepare_demo_p2.sh` | second pass; exists because the first was decided from a truncated `ls` |
| `guest_fix_sscli.sh` | repairs `simple_switch_CLI` and verifies it against a live switch |
| `package_ova.sh` | OVF descriptor, manifest, and the tar, without `ovftool` |
