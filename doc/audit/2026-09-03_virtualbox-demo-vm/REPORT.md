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
