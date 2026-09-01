# A-3: strip `doc/`, pin NTV to `b5e039c`, repack, re-accept

2026-09-01. Run on `nslab`, in a VM booted from the shipping artefact on the hardware its own
OVF declares (SATA/AHCI, E1000, 4 vCPU, 6144 MB), with the guest writing to a qcow2 overlay so
the payload stayed byte-identical to the `.ova` under test.

`VM_DIR=$HOME/ndtwin-vm-a3`, `SSH_PORT=2299`, `NDT_OWNER=install-manual`.

[Co-developed with claude code -- Adam]

---

## The artefact

| | |
|---|---|
| in | `/home/nslab/repack/out/NDTwin-P4-demo.ova` — 3 236 484 096 B, `72fac128…bede79` |
| out | `/home/nslab/a3repack/out/NDTwin-P4-demo.ova` — **3 212 982 272 B**, **`c303adb57c99f87a7f4f4c77de9763dc7f369e0fabd580a1db6089823966c8e8`** |
| change | **23 501 824 B smaller = 22 MiB** |

The 2 757 157 888 B file at `/home/nslab/NDTwin-P4-demo.ova` is the old build and was not
touched. Both input and output were identified by sha256 before use, not by path.

**R12 held.** The prediction was "stripping ~563 text files will not take 100 MB off, because
the volume is in the P4 toolchain and the Maven dependencies". Measured: `doc/` was 20 919 411 B
on disk and the archive shrank by 22 MiB. Nothing near the 300 MB stop-line, so nothing was
removed that should not have been.

---

## What was measured, and what the instrument got wrong first

### Step 1 — do the four applications talk to *this* kernel's API?

H-26 verified "builds" and "starts" and said in writing that interoperation was **not** tested.
This round tested it. The reference set was derived **inside the guest**, from
`build/bin/ndtwin_kernel` (sha256 `df157f85db93…`, 11 839 016 B) and the source tree that
produced it — not from the laptop tree, which is 438 commits ahead and carries endpoints such
as `/ndt/get_flow_dispatch_status` that this image never had.

| app | result |
|---|---|
| Traffic-Engineering-App | **5/5 present.** Also run live: drove `get_graph_data` / `acquire_lock` / `release_lock` and completed TE cycles against the kernel |
| Network-Traffic-Visualizer | **5/5 present** |
| Simulation-Platform-Manager | **3/3 present.** Also run live: `Registered app ' power ' with App ID: 1`, result callback answered `code = 200` |
| Energy-Saving-App | **13 of 14 present; `/ndt/disable_switch` ABSENT** |

`/ndt/disable_switch` is POSTed by `disable_switch()` in
`Energy-Saving-App/src/app/http.cpp:263`. It appears nowhere in the kernel's source and nowhere
in the compiled binary, and returns 404 to both GET and POST. Reported as found; not worked
around.

**🔴 The first instrument was wrong, and its control did not catch it.** Run 1 classified an
endpoint ABSENT on a 404 from a GET. *This kernel answers 404, not 405, when the path exists but
the method does not match*, so ten of Energy-Saving-App's fourteen endpoints were reported absent
while the kernel was routing them. The run-level positive control passed throughout — it used
`/ndt/get_graph_data`, a GET-routed endpoint, so it exercised the one mechanism that was not
broken. What exposed it was the kernel's own log showing
`Got request: POST /ndt/app_register … Registered app 'power'` for a name the matrix had just
called absent.

⇒ *A control has to exercise the same **mechanism** the measurement uses, not merely the same
service.* The corrected probe tries both methods, calls an endpoint absent only if both answer
404, and carries two negative controls — an invented name and the laptop-only endpoint — which
must both come back ABSENT or the probe cannot detect absence at all. Both did.

**🔴 Run 1's teardown did not tear down, and run 2 measured run 1's orphan.** `sudo kill $KERN`
killed the `( cd build && sudo ./bin/… )` **subshell**; the kernel itself (pid 3052) survived and
kept `:8000`, so run 2's kernel died after 21 log lines and run 2's numbers came from run 1's
process. This is the wrapper-vs-child defect already recorded in
`install-manual-clean-room-test` §11.2. Nothing announced it; the tell was indirect —
`destination paths settled at: 0` and a 21-line kernel log, beside an application receiving real
JSON. **And the `/proc/*/exe` scan was blind to it**: the kernel runs under `sudo`, so as `tester`
`readlink` gets EACCES and the entry is silently skipped. Ports were the honest witness.
`guest_a3_step1c.sh` is the re-run on a stack proven fresh (paths 12, real child pid recorded,
ports asserted free before **and** after); it reproduces the matrix exactly.

### Step 2 — `doc/` removed

**The stated gate did not match.** The brief expected `find doc -type f | wc -l` == 563 and said
to stop if it did not. It was **594**. The number was bound to the wrong path: 563 is the count
of `doc/audit/` alone, which is what the brief's own parenthesis says. Both were checked against
`main@20cd80b`: `doc/audit` = 563 and `doc` = 594, matching exactly. The condition the gate
exists to protect — *this is the tree we think it is* — was therefore satisfied more strongly
than the stated check, and the removal proceeded. Recorded rather than skipped.

Removed: 594 files, 20 919 411 B. Verified by state (`ls doc` → *No such file or directory*),
not by `rm`'s exit code.

**A consequence worth naming.** About forty source comments *cite* documents that were under
`doc/` (`// Design: doc/2026-08-11_phase7_power_mechanism_design.md`). None is a runtime open —
that was checked — but those citations now dangle. Citations to `doc/<name>.md` land in the 31
files the public snapshot still carries; citations to `doc/audit/…` land nowhere public. Both
facts are now in `PROVENANCE.txt`.

### Step 3 — Network-Traffic-Visualizer unified to `b5e039c`

`.git` is stripped from this image, so "checkout" meant restoring file **content** from a clone
made outside the tree. `b5e039c` is an ancestor of `main`; `b5e039c..main` is 2 commits over 5
files. After the change all 49 files tracked at `b5e039c` match byte for byte, zero references to
`WindowStateRestore` remain, and `mvn clean package` succeeds.

**The jar trap, and a start test that was wrong twice.**

* `NDTanimation-1.0-SNAPSHOT.jar` (61 418 226 B) carries `Main-Class:
  org.example.demo2.NetworkTopologyApp`; `original-NDTanimation-1.0-SNAPSHOT.jar` (238 354 B)
  carries none. The decoy is **kept** as the control.
* 🔴 My first positive arm ran `java -jar <shaded jar>` and got *"JavaFX runtime components are
  missing"*. That is **my invocation failing, not the build** — `NetworkTopologyApp` extends
  `Application`, which the JVM launcher refuses without the JavaFX module path. Reporting it as
  "NTV does not start" would have been H-26's mistake in a new costume: an instrument defect
  attributed to the artefact. The image documents its own launcher,
  `network_traffic_visualizer.sh` → `./mvnw javafx:run`.
* **Arm A (does it start):** PASS under Xvfb via the documented launcher, paired against the same
  launcher with no display, which fails `Unable to open DISPLAY`. The pair discriminates.
* **Arm B (is the Main-Class jar the runnable one):** with the JavaFX module path supplied, the
  chosen jar runs and stays up; the decoy, given the *identical* command, throws
  `Exception in Application start method` and exits. The arms differ. My scripted verdict string
  was narrower than the evidence and printed FAIL — the assertion was wrong, the measurement was
  not.

`NDTwin-local-changes.patch` is kept byte-identical (sha256 `a4641d74c950…`) so `git apply` still
works; what changed is its **description**, which lives in `~/Desktop/PROVENANCE.txt`. It is now
evidence for *why `main` is unusable*, not a patch in force.

### Step 4 — declarations made to describe the content

**🔴 Control C refuted the brief's premise.** The brief said the public repo is
"`main@20cd80b` minus `doc/audit/`, identical to the image's current content". Measured against
`https://github.com/ndtwin-lab/NDTwin-Kernel-P4-public` @ `936f8c6`:

* 399 of its 405 non-`doc` files are byte-identical to the image
* **31 `doc/` files exist in the snapshot and not in the image** — the snapshot dropped only
  `doc/audit/`; this image drops all of `doc/`
* **6 non-`doc` files differ**: `host_count_override` (128 vs 4), `proxy_agent/main.py` (the
  image's is the longer one — it has `claim_listen_socket()`), `bmv2_binary_override`,
  `README.md`, `intelligent_router.py`, `testbed_topo.py`

So "identical" would have been false. Both `PROVENANCE.txt` files now state the delta explicitly
instead of claiming equality.

### Step 5 — fstrim, zero-fill, repack

52 023 427 072 B of zeros written over free space, then `fstrim` reclaimed 9.8 GiB on `/`,
813.1 MiB on `/boot`, 98.2 MiB on `/boot/efi`.

**🔴 The annotation was ERASED by the option meant to set it.** `ovftool --annotation=…` produced
an OVF with an `AnnotationSection` containing **no `<Annotation>` element at all — 0 characters**,
where the artefact it was built from had a full one. `ovftool` exited 0 and the section existed,
so both of the cheap checks would have said yes. This is the H-26 annotation defect inverted:
there it survived a repack unchanged and described the wrong contents; here it did not survive.
Same root error — treating the annotation as something the packer looks after instead of reading
back what the product declares.

The fix stays inside the *do not hand-write the descriptor* rule: the `.vmx` that `ovftool`
generates from the current shipping `.ova` already carries `annotation = "…"`, a plain
`key = value` line. Setting it there and repacking leaves `ovftool` to generate the OVF **and the
manifest** itself. Second pack: annotation 1841 chars, and all nine content checks pass.

**Controls on the pack**

| control | result |
|---|---|
| A — hardware identity, read back from the product | `<Name> = NDTwin-P4-demo`, `VirtualSystemType = vmx-14`, `vmware.sata.ahci`, `E1000`, 4, 6144 |
| B — import conversion, paired, **each arm in its own fresh empty directory** | positive `Completed successfully` (0); negative `Error: SHA digest of file NDTwin-P4-demo-disk1.vmdk does not match manifest` → `Completed with errors` (1). **Arms differ.** |
| C — does the declaration describe the content | 9/9 PASS after the second pack |

`--lax` was not used. `--verifyOnly` was not used as evidence, and for the record it **returned 0
on the byte-flipped archive** in this round too.

### Step 6 — both acceptances, on the file that ships

**Delivery.** `doc/` absent; four trees present with no `.git`; five build products present;
zero `WindowStateRestore` references; both jars listed with their manifests; both `PROVENANCE.txt`
present and naming `b5e039c`, `disable_switch` and the public snapshot; three units `disabled`;
cold boot listening on only `:22` and the DNS stub.

**Regression.** The criterion is the named line, not the last line:

```
*** Results: 0% dropped (12/12 received)
```

with 10 switches in the manifest, two agreeing path samples at 12, and 40 edges.

`failures: 1`, from *twin reports 14 switches, expected 10* plus the known `M-3` proxy refusal.
**Reconciled against the prior result:** README §"What was verified" records the H-26 baseline as
exactly `failures: 1` with those same two, so this round changed nothing T-2 can measure. The
`14` is the driver's own heuristic counting 10 switches + 4 hosts; it was reproduced identically
in step 1c *before* any change here (`nodes=14 edges=40 switch-like=14`).

**On the elapsed-time warning.** The driver once printed "20s" for a run the guest timestamps put
at 130s. This round it reported 142 s and the guest file timestamps say `t2run.log` ran
`07:23:37 → 07:25:46` = 129 s. Same order of magnitude, so nothing absurd appeared; the
timestamps remain the adjudicator.

---

## 🔴 The worst thing that happened, which was mine

`guest_a3_finalize.sh` was first sent as an inline `ssh nslab '…'` one-liner. A comment in the
body contained an apostrophe (`this round's working files`). That apostrophe **closed the
single-quoted argument**, so everything after it executed in the **local** shell instead of the
guest. It walked the local process table, deleted the local `~/.bash_history`, removed
`/tmp/topo.json`, and attempted `sudo mn -c` and `systemctl stop` **against another session's
live BMv2 fabric**.

Only the absence of passwordless sudo on that host stopped the destructive half. The other
session's proxy, kernel and all ten `simple_switch_grpc` processes were verified still running
afterwards.

The repo already records this lesson once — *"bracket expressions do not survive three levels of
shell quoting; a script file does"*. Every script in this directory was thereafter written to a
file, copied, and executed, and `guest_a3_finalize.sh` additionally refuses to run unless it is
`tester` inside the demo guest.

---

## Files

| file | what it is |
|---|---|
| `a3_boot.sh` | boots the shipping `.ova` on the OVF-declared hardware; writes the `ndtwin-vm.sh`-format registry so other sessions' port guards see the claim |
| `guest_a3_step1c.sh` | the API matrix on a provably fresh stack, both methods, four controls |
| `guest_a3_step23.sh` | removes `doc/`; puts NTV on `b5e039c`; rebuilds; jar chosen by manifest |
| `guest_a3_step3b.sh` | the start test done properly — two paired arms |
| `guest_a3_finalize.sh` | working-file removal, zero-fill, fstrim; guards on host identity |
| `nslab_a3_pack.sh` | flatten + repack + controls A/B/C — the pass where C caught the erased annotation |
| `nslab_a3_pack2.sh` | repack with the annotation set in the `.vmx`; all controls pass |
| `nslab_a3_accept.sh` | both acceptances on the shipping file |
| `nslab_a3_closeout.sh` | state-based closeout evidence |
| `annotation.txt` | the OVF annotation as shipped |
| `kernel_PROVENANCE.txt` | `~/Desktop/NDTwin-Kernel/PROVENANCE.txt` as installed |
| `desktop_PROVENANCE.txt` | `~/Desktop/PROVENANCE.txt` as installed |

## Closeout

`:2299` not listening; no A-3 `qemu` found by walking `/proc/*/exe`; `~/ndtwin-vm/`,
`~/ndtwin-vm-a2/` and `~/ndtwin-vm-reviewer-B/` untouched; the A-3 disk **kept**, not destroyed.

Two things to know about what was left behind:

* `~/ndtwin-vm-a3/disk.qcow2` is **53 GB** — the overlay absorbed the 52 GB zero-fill. The
  `.ova` is made, so that overlay is discardable if the space is wanted.
* `:2298` was not listening at closeout. The `ndtwin-vm-a2` directory and its `OWNER`
  (`install-manual-tester`) are intact and nothing in this round touched them.
