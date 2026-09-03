# nslab without you in the room — what breaks, what doesn't

Measured 2026-09-03 ~20:10 CST, on the machine, not from memory.
Adam loses physical access to the lab from 2026-09-05.

## TL;DR — one thing must be done before you go

**VirtualBox will stop working the next time that machine reboots**, and only root
can fix it. Everything else survives unattended.

---

## 🔴 The one real time bomb

| measured | value |
|---|---|
| running kernel | `7.0.0-28-generic` |
| kernels installed | `7.0.0-28-generic`, **`7.0.0-30-generic`** |
| `vboxdrv.ko` built for | **`7.0.0-28-generic` only** |
| `/lib/modules/7.0.0-30-generic/misc/` | **does not exist** |
| `dkms status` | **empty — `vboxhost` is not registered** |
| `/usr/src/vboxhost-7.1.18` | present (so a rebuild has everything it needs) |
| `linux-headers-7.0.0-30` | installed |
| `unattended-upgrades` | **enabled** (more kernels will keep arriving) |
| `Automatic-Reboot` | off (so it will not reboot itself) |

The modules are loaded right now only because the machine has been up 3 days on
the old kernel. **The next reboot boots `-30`, finds no `vboxdrv`, and VirtualBox
is dead** — no import, no boot, nothing. `VBoxManage` the file still exists, which
is exactly how this was misread once before.

### Fix — one command, needs your password, ~1 minute

```bash
ssh -t nslab 'sudo dkms add -m vboxhost -v 7.1.18 && sudo dkms autoinstall && dkms status'
```

Acceptance is **not** "apt printed no error". It is:

```bash
ssh -n nslab 'dkms status; ls /lib/modules/7.0.0-30-generic/misc/vboxdrv.ko'
```

`dkms status` must name `vboxhost/7.1.18` against **both** kernels, and that
`vboxdrv.ko` must exist. Registering it with DKMS also means **future** kernel
updates rebuild the modules by themselves, which is the part that matters once
nobody can reach the machine.

---

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
| `vboxdrv` unit | `enabled` (it will try — it just has nothing to load after a kernel change) |

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

1. **Run the DKMS command above.** This is the only item that silently breaks
   later and cannot be repaired without root.
2. **Ask the lab for a DHCP reservation** on `60:cf:84:bf:1f:59`.
3. Decide whether **VM-1** (boot the shipped `.ova` on a real VMware hypervisor)
   happens before you lose access — it needs a Broadcom account *and* a machine
   with VMware on it, and it is currently the only untested claim on the Download
   page. See `doc/audit/2026-09-03_virtualbox-demo-vm/REPORT.md`.
4. Nothing else needs doing. The machine comes back from a reboot by itself.

[Co-developed with claude code -- Adam]
