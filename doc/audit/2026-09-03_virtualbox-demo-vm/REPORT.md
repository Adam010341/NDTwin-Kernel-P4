# A-9: does the packaged demo VM run under VirtualBox on Ubuntu?

**Machine:** nslab (28 cores, Ubuntu 24.04.2, kernel 7.0.0-28-generic)
**VirtualBox:** Oracle 7.1.18r173720, installed by Adam himself on 2026-09-03
**Ledger row:** A-9 in `doc/audit/2026-08-31_completeness-experiments/NSLAB-USAGE-RULES.md`
**Date:** 2026-09-03, 15:42–16:0x CST

## Answer

**Yes** -- with one defect that stops the image dead until it is worked around.

`VBoxManage import` of our packaged `.ova` succeeds, the guest boots to a login
prompt, and once the defect below is worked around the whole stack runs: the
kernel binary, `p4c` 1.2.5.16, BMv2 1.15.5-fdd3b893, Open vSwitch 3.3.9 and
Mininet 2.3.0 all answer, and a Mininet/OVS `pingall` returns
**`0% dropped (6/6 received)`**.

## What was actually tested

🔴 **Not the image on the Download page.** The object under test was
`/home/nslab/a3repack/out/NDTwin-P4-demo.ova` (3 212 982 272 B, `sha256
c303adb5...`), the P4/BMv2 image produced by A-3 and **not yet published**.
It was chosen because it was already on the machine and therefore cost no
download quota. The published 17.9 GB `NDTwin-Testbed-20260831` was **not**
downloaded -- see "The cost that stopped this round" below.

## 🔴 Finding: the image has no network on any hypervisor that is not our qemu

`/etc/netplan/50-cloud-init.yaml` inside the image:

```yaml
network:
  version: 2
  ethernets:
    ens3:
      match:
        macaddress: "52:54:00:12:34:56"
      dhcp4: true
      dhcp6: true
      set-name: "ens3"
```

`52:54:00` is the **QEMU** OUI. cloud-init wrote this when the image was built
inside our qemu VM on nslab, where `ndtwin-vm.sh` pins that exact MAC.

Under VirtualBox the NIC comes up as `enp0s17` with MAC **`08:00:27:f7:bf:92`**
(the VirtualBox OUI). The match fails, `systemd-networkd` never configures the
interface, and it sits `DOWN` with no address.

**Red / green pair, both measured:**

| | NAT-forwarded SSH banner on the host |
|---|---|
| as shipped | *(nothing -- interface DOWN, no address)* |
| after `netplan set ethernets.enp0s17.dhcp4=true; netplan apply` | `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.1` |

After the fix: `enp0s17 UP 10.0.2.15/24`, and `ping 8.8.8.8` gets 2/2 back.
**The MAC match was the entire cause.** Nothing else about the image needed
touching.

### Why this matters more than "VirtualBox is unsupported anyway"

The manual tells users to run this on **VMware**, whose OUIs are `00:0c:29` /
`00:50:56` -- also not `52:54:00`. So the failure is not specific to
VirtualBox: **it should reproduce on the hypervisor we actually document.**
That has not been measured yet and is the obvious next check.

Everything a first-time user does needs the network: `git clone`, `apt`, the
Ryu controller, every API call in the User Manual. A VM that boots with no
network fails at step one.

### Why our own acceptance tests did not catch it

Every boot test of this image ran under `ndtwin-vm.sh`, i.e. qemu with that MAC
pinned -- **the one environment in which the bug is invisible.** The acceptance
test and the defect were produced by the same tool.

### Suggested fix (in the image, not in the manual)

Drop the `match:` / `set-name:` stanza so the config binds to any ethernet
device, e.g. `match: {name: "en*"}`. `dhclient` is **not** installed on 24.04,
so a user cannot fall back to it by hand; the only recovery paths are editing
netplan or setting the NIC's MAC in the hypervisor.

## The cost that stopped this round

Testing the **published** 17.9 GB image needs it downloaded to nslab. A 4 KB
range probe confirms the link is serving again today (`206`, tar magic, first
member `NDTwin-Testbed-20260831.ovf`), so the 08-31 exhaustion has cleared.

🔴 **But one full download takes that public link offline for roughly 24 hours
for everyone.** H-18 did exactly that on 08-31 for a read-only check, and H-24
then found `Quota exceeded` on the link the website's Download page points at.
No copy survives on nslab, and Adam's laptop has 8.7 G free -- it cannot hold
one. So this is Adam's call, not a step-level judgement.

## Instrument notes

- **VirtualBox 7.1.18 fixes the 08-31 blocker.** Real `VBoxManage import` then
  failed with `VBOX_E_INVALID_OBJECT_STATE`, and the cause was left open
  ("most likely the half-configured install, but I could not prove it"). It now
  succeeds in **26.7 s, rc=0** on the same machine. That open attribution is
  closed: the broken 7.0.16 install was the cause, not the OVA.
- **The first `VBoxManage` call after install fails** with "COM server is not
  running or failed to start"; the second succeeds. A VBoxSVC cold-start race,
  not a broken install. Judged on one attempt it looks like a dead install.
- **The OVA declares bridged networking.** Imported as-is on nslab that would
  put the guest on the lab L2 alongside the smart PDUs at 172.25.197.120/.121.
  Forced to NAT before first boot, with the SSH forward bound to `127.0.0.1`.
- **VirtualBox silently drops the `vmci` device** -- it is not even listed as a
  unit in `--dry-run`, so no `--ignore` is needed.
- **No `sshpass` or `expect` on nslab**, and no root to install them. The guest
  was driven through `VBoxManage controlvm keyboardputstring` at the console
  until a public key could be injected. That path needs no Guest Additions.

[Co-developed with claude code -- Adam]

---

# Step 5 (Adam's ruling): fixed and repacked

Adam ruled **not** to download the 17.9 GB published image -- it is the old
standard build (kernel tip 2026-01-29) and the Download page still marks the P4
row "not yet published", so the artefact that matters is this one; the download
quota gets spent once, when the repacked image is uploaded. He ruled the fix and
repack happen on nslab.

## The change

`/etc/netplan/50-cloud-init.yaml`, in the image:

```yaml
network:
  version: 2
  ethernets:
    all-ethernets:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
```

Plus `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` =
`network: {config: disabled}`, so cloud-init cannot rewrite the file on a later
boot and reintroduce the pin. Nothing else in the image was touched.

Repacked with A-3's exact recipe, not a new one -- `qemu-img convert -O vmdk -o
subformat=monolithicSparse` then `ovftool --maxVirtualHardwareVersion=14
--annotation="$(cat annotation.txt)"`. The edit was made in qcow2 and converted
back, so qemu never wrote into the vmdk ovftool reads.

## Result

| | |
|---|---|
| artefact | `nslab:/home/nslab/a9pack/out/NDTwin-P4-demo.ova` |
| size | **3 213 910 528 B** (was 3 212 982 272 -- **+0.029%**) |
| sha256 | `5ed8dcb942d5fa7ecde4f019b95125084e9c9e6fb221927d15e8e7f9c03fefab` |
| supersedes | `c303adb57c99f87a7f4f4c77de9763dc7f369e0fabd580a1db6089823966c8e8` |

## Acceptance -- both directions, because a fix that only works in the new place is a fix that moved the bug

**Old environment must not break** (qemu, the NIC named `ens3`): after the
change, `ens3 UP 10.0.2.15/24`, `ping` 2/2. Unchanged from before the change.

**New environment must now work, with zero intervention** (VirtualBox, the NIC
named `enp0s17`): imported the repacked `.ova` fresh and booted it without
touching anything inside.

| check | result |
|---|---|
| `<Name>` / `VirtualSystemType` | `NDTwin-P4-demo` / `vmx-14` |
| declared hardware | `E1000`, `vmware.sata.ahci`, `vmware.vmci` |
| annotation names all four apps | yes, all four |
| **SSH banner through the NAT forward** | **✅ ~25 s, `SSH-2.0-OpenSSH_9.6p1`** |
| interface | `enp0s17 UP 10.0.2.15/24` |
| netplan actually shipped | the `en*` form above |
| **no key of mine left in the image** | **✅ no `authorized_keys`** |
| internet | `rtt min/avg/max 2.192/2.487/2.782 ms` |
| dataplane | `*** Results: 0% dropped (6/6 received)` |
| stack | `p4c 1.2.5.16`, BMv2 `1.15.5-fdd3b893` |

## 🔴 Reconciliation: what this overturns

`doc/audit/2026-08-31_p4-demo-vm/README.md` records, under "Also verified, each
on the accept path rather than by reading config":

> **Boots without virtio** -- root came up on `/dev/sda1` via AHCI and `ens3`
> took a DHCP lease on E1000. VMware offers neither virtio-blk nor virtio-net,
> so this was the single largest risk in the whole conversion.

**The observation is true. The inference drawn from it was too broad.** That
test named the right risk -- "will this work on hardware VMware actually
offers" -- and varied the **device model** (virtio → E1000, virtio-blk → AHCI)
while holding the **MAC address** fixed at qemu's `52:54:00:12:34:56`. The MAC
was the variable that decided the outcome, and it was the one held constant.
`ens3` did take a DHCP lease, and it did so *because netplan still matched*.

So the A-3 line should not be read as "the NIC works on a foreign hypervisor".
It establishes that E1000 and AHCI work **under qemu**. Nothing in that round
could have caught this, because the whole round ran under the tool that pins
the MAC.

## Still open

- 🔴 **VMware is not tested.** nslab has `ovftool` but no VMware hypervisor, so
  "the `en*` form also fixes VMware" is **inferred from the OUI, not measured**.
  It is written here as inference deliberately. VMware's OUIs (`00:0c:29`,
  `00:50:56`) are not `52:54:00`, so the *old* image should have failed there
  too -- also not measured.
- 🔴 **The published 17.9 GB standard image was not examined**, by Adam's
  ruling. Whether it carries the same pin is unknown. It has separate
  provenance (its OVF declares `lsilogic` and `vmx-21`, unlike this one), so
  the defect does not transfer by assumption either way.
- The repacked `.ova` has **not been uploaded**. Nothing on the website points
  at it yet.

## Registered vs actual, recorded because the gap keeps going the same way

Registered peak disk **+25 GB**; measured **+39 GB** (258 G used → 297 G).
Underestimated again, in the same direction as H-18 (registered 40–55 GB,
actual 106 GB) and against H-20 (registered ~8 GB, actual ~7 GB). Released
state, verified as state rather than exit codes: no VirtualBox VM registered or
running, the only qemu on the host is Adam's `ndtwin-lab-vm` (182232), ports
2350/2351/2352 not listening, available 21 370 MB, disk back to 600 G free.

[Co-developed with claude code -- Adam]

---

## Adam's ruling on the Download page wording (2026-09-03)

Keep **"Runs on VMware or VirtualBox."** His reasoning is a design principle for
the whole manual, not a one-off: **nothing goes public until testing is
complete**, so the site describes the state at publication, and VMware will have
been tested by then.

That is not the failure mode this repo has recorded before. The API-page defect
was a **dated claim about the past** that was false for the build the reader
actually had. This is a forward-looking product statement whose truth is gated
on a release process. The distinction is real, and the wording stands.

🔴 **But the gate only protects the claim if the work is actually on someone's
list, and right now it is not.** `doc/audit/2026-08-31_p4-demo-vm/README.md`
records "Untested on real VMware" as **struck through and closed**, closed on
the strength of an `ovftool` conversion. So the outstanding item does not read
as outstanding — it reads as done. And an `ovftool` conversion structurally
cannot touch `/etc/netplan/`, which is exactly where the defect this round found
was hiding.

**Therefore, as a tracked debt rather than an assumption:**

> **VM-1 — boot the shipped `.ova` on a real VMware hypervisor and confirm the
> guest gets an address.** Blocks publication of the Download page's P4/BMv2
> row, because that row will claim VMware support.
>
> Not startable by this line: nslab has `ovftool` but no VMware hypervisor, and
> Workstation/Fusion downloads require a Broadcom account, which this line does
> not create and does not sign into. **Adam or another human must run it.**
> Acceptance is the same shape used here: import, boot untouched, and check the
> interface takes an address — not that the import returned 0.

The 08-31 "closed" mark should be reopened, or annotated to say what it was
closed on. It is cited in #72 as a supporting record, and it does not support
what its strike-through implies.
