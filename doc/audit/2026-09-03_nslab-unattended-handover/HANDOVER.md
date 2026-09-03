# nslab without you in the room — what breaks, what doesn't

Measured 2026-09-03 ~20:10 CST, on the machine, not from memory.
Adam loses physical access to the lab from 2026-09-05.

## TL;DR — one request to make, nothing to install

Everything on that machine survives unattended, including VirtualBox across a
kernel change. The single thing worth doing is **asking the lab to reserve the
address**, because that is the only failure nobody outside the lab can recover
from.

*(An earlier version of this file led with a VirtualBox "time bomb" and a command
to run. Both were wrong — see the retraction below. The command would not even
have run.)*

---

## ~~The one real time bomb~~ — RETRACTED, it self-heals

An earlier version of this file said VirtualBox would break at the next reboot
and that only root could repair it, and gave a `dkms add` command to run first.
**Both halves were wrong.** The command would also have failed outright:
`/usr/src/vboxhost-7.1.18/` has no `dkms.conf`, because Oracle's `virtualbox-7.1`
package does not use DKMS.

The facts that made it look like a bomb are real:

| measured | value |
|---|---|
| running kernel | `7.0.0-28-generic` |
| kernels installed | `7.0.0-28`, **`7.0.0-30`** |
| `vboxdrv.ko` built for | `7.0.0-28` only |
| `/lib/modules/7.0.0-30-generic/misc/` | does not exist |
| `dkms status` | empty |

What I had not read is what the already-enabled `vboxdrv.service` does at boot.
`/usr/lib/virtualbox/vboxdrv.sh`:

```sh
if ! running vboxdrv; then
    # Check if system already has matching modules installed.
    [ "$(setup_complete)" = "1" ] || setup
```

`setup_complete()` just asks whether the three modules are available for the
running kernel; if they are not, `setup` **rebuilds them**. The service runs as
root at boot, and everything the rebuild needs is present:

| precondition | state |
|---|---|
| `gcc`, `make` | present |
| headers for `-28` and `-30` | both present |
| `linux-headers-generic-hwe-24.04` meta | **installed** ⇒ future kernels bring their own headers |
| Secure Boot | **disabled** ⇒ no module signing step to get stuck on |

⇒ **After a reboot onto a new kernel, VirtualBox repairs itself. Nothing to do,
before leaving or after.**

🔑 The lesson worth keeping: *"the module is built for the running kernel only"*
is a true observation that says nothing on its own about whether anything breaks.
The question is what runs at boot, and that meant reading the init script instead
of inferring from the file listing. I inferred, and told Adam to run a command
that could not have worked.

## 🟡 The one risk that cannot be fixed from here

**The address is DHCP.** `nmcli` reports `ipv4.method:auto` with no static
address; `enp4s0` currently holds `172.25.197.100/24`. My `~/.ssh/config` pins
`HostName 172.25.197.100`, so **if the lease moves, `ssh nslab` simply stops
resolving to that machine** and there is no way to find it again from outside.

The usual fallback does not work here: `avahi-daemon` is running on nslab, but
mDNS is link-local multicast and the VPN is routed, so
`nslab-System-Product-Name.local` does not resolve across it.

Options, best first:

1. **Ask the lab for a DHCP reservation** on `enp4s0`'s MAC `60:cf:84:bf:1f:59`.
   Durable, costs nothing, and is a request rather than a change.
2. Set a static address in NetworkManager. **Do not do this remotely.** A wrong
   address locks everyone out permanently, and that is precisely the failure
   nobody could recover from. If it is done at all, it must be done while
   somebody is still standing at the machine.
3. Accept it: if the address moves, someone at the lab has to read the new one
   off the screen.

---

## 🟢 What survives a reboot on its own — verified, not assumed

| | |
|---|---|
| root filesystem encrypted? | **no**, `/etc/crypttab` empty ⇒ no passphrase at boot |
| desktop login | `AutomaticLoginEnable=true`, `AutomaticLogin=nslab` ⇒ comes back by itself |
| ssh at boot | `ssh.socket` **enabled** (`ssh.service` disabled is normal on 24.04 — socket activation) |
| `/dev/kvm` access | `nslab` **is in the `kvm` group** ⇒ durable. The `user:nslab:rw-` ACL from the desktop session is also there, but nothing depends on it |
| self-reboot | `Automatic-Reboot` off ⇒ it will not reboot itself |
| `vboxdrv` unit | `enabled`, and its `start` path **rebuilds the modules** when they are missing for the running kernel ⇒ survives a kernel change on its own |

The `/dev/kvm` point is worth stating plainly because it was the thing most
likely to bite: the ACL is granted by logind because someone is logged in at
seat0, and it goes away when they log out. **The group membership is what makes
it survive**, and that is already in place.

Running qemu VMs do not survive a reboot. That is fine — they are all
re-creatable from `ndtwin-vm.sh`, except the disks marked `keep`, which are
files and do survive.

---

## Does downloading things need hands-on? Mostly no

Physical presence is needed for almost nothing. Sort the work by what it
actually requires:

| needs | example | reachable over ssh? |
|---|---|---|
| nothing special | `git clone`, `curl`, public Google Drive links, GitHub | ✅ yes — and that machine pulls at ~64 MB/s |
| **root** | `apt install`, `dkms`, kernel modules, anything under `/etc` | ✅ yes, `ssh -t nslab 'sudo …'` — you type the password, no travel |
| **an account login** | VMware / ovftool from the Broadcom portal; anything behind 2FA or a licence click-through | ⚠️ needs **you**, but from any browser — then `scp` the file over. I do not create accounts or enter credentials, so this class never becomes automatic |
| **physical presence** | machine powered off, address changed, BIOS, cabling | 🔴 nobody remote can do it |

So: **downloads are not the problem; identity and root are.** Both of those you
can still do from anywhere, as long as the address still points at the machine —
which loops back to the DHCP item above.

Disk is not a constraint: **596 G free** of 915 G.

---

## Before you go — the short list

1. ~~Run the DKMS command.~~ **Retracted — see above. VirtualBox repairs itself at boot; there is nothing to do.**

2. **Ask the lab for a DHCP reservation** on `60:cf:84:bf:1f:59`.
3. Nothing else needs doing. The machine comes back from a reboot by itself.

## Not on this list, and an earlier draft wrongly put it here

**VM-1** — boot the shipped `.ova` on a real VMware hypervisor — **has no nslab
dependency at all.** The image is on a public Drive link now, so any machine can
fetch it. Adam pointed this out; the deadline does not apply to it.

Worth recording where it should run, though, because the two candidates are not
equally cheap:

* **Windows** — VMware Workstation Pro ships a hypervisor that needs no kernel
  module compiled on the spot.
* **Linux** — Workstation Pro has to build `vmmon` and `vmnet` against the
  running kernel. That is **the same failure class that cost this project a day
  already**: VirtualBox 7.0.16 could not build `vboxdrv` against 7.0.0-28, and
  the kernel on Adam's laptop is newer still (`7.0.0-30`). Testing there risks
  measuring the module build rather than the image.

Adam's laptop is a poor host for it on a second count: 15.4 GB of RAM, already
killed once today by `systemd-oomd`, against an OVA that declares 4 vCPU and
6144 MB.

⇒ **Windows is the low-risk place to run VM-1.** It still needs a Broadcom
account for the download, which is a human step either way.

[Co-developed with claude code -- Adam]
