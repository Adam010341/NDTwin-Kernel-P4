# `tools/remote-lab/`: claims on remote lab machines, and the VM life cycle

Tools for sharing a remote lab machine between several sessions without them overwriting each
other's work. This README describes the tools. Whether you may use a given machine, and when and
what to register, is decided by the people who run it; register **before** you start, because the
claim record is the only record of who is using the machine.

## Why there are two layers

There are two units of contention, and the machine layer alone is not enough:

| Layer | Tool | Unit |
|---|---|---|
| Machine | `rlab` | One physical machine (`~/RLAB-CLAIM` on that machine is the source of truth) |
| **VM** | `ndtwin-vm.sh` | **One VM** |

Two sessions can share one machine safely (Mininet network namespaces and OVS datapaths collide
per kernel, not per machine) and still land in the **same `disk.qcow2`**: `VM_DIR` and `SSH_PORT`
have independent defaults, so a second session that changes only one of them lands on top of the
first, and no layer reports an error. The VM layer exists to make that collision visible and to
refuse it.

## Files

| File | Runs where | Purpose |
|---|---|---|
| `rlab` | The operator's machine | Machine-level claim: `list`, `status`, `claim`, `note`, `release`, `suspended` |
| `ndtwin-vm.sh` | The remote host (**no root needed**) | VM life cycle, the coordination guards, and the `vms` view across sessions |
| `ndtwin-virt-root.sh` | The remote host (**the only step that needs root**) | Installs `qemu-system-x86`, `qemu-utils` and `cloud-image-utils` and adds the account to the `kvm` group. It does not touch sudoers and adds no `NOPASSWD` entry |
| `vm-install-stack.sh` | **Inside the guest VM** | Installs the apt packages from the Installation Manual (steps 3.1 and 3.2) and runs p4-guide's `install-p4dev-v8.sh`. Acceptance is read from build artifacts, not from exit codes |
| `p4_patch_preflight.sh` | Any machine with network access | A dry run of about two minutes: do p4-guide's patches still apply to the current behavioral-model? (v10 is included as a control that is expected to fail) |
| `host_witness.sh` | The machine to be witnessed (host or guest) | Continuous accounting of what runs on a host during a measurement window; see below |
| `test_vm_coordination.sh` | The local machine; touches no lab machine | The mutation gate for all the guards described below |
| `test_claim_guard_identity.sh` | The local machine | Checks how `claim_guard` compares owner names; it exits 1 on purpose until the owner comparison is fixed and `test_vm_coordination.sh` gets a multi-word owner fixture. See "Owner names" |

## `rlab`: machine claims

```
rlab list                              every machine: claim and load, one line each
rlab status <machine>                  claim and occupancy detail
rlab claim <machine> <owner> <note>    refuse if already claimed
rlab note <machine> <text>             amend a live claim (terms changed, no handoff)
rlab release <machine>                 archive the claim to the handoff log, then free it
rlab suspended <machine>               is the machine off limits? Answers without connecting
```

- `~/RLAB-CLAIM` on the machine is the single source of truth for "who owns it". A claim says who
  owns the machine, **not** whether an experiment is running: read `rlab status <machine>`
  (load, processes) before touching a machine that looks free.
- `release` appends the claim to `~/RLAB-HANDOFF.log`, so the history survives.
- A machine can be marked suspended in the `suspended()` table in `rlab`. A suspended machine is
  refused **before any packet is sent**, and the refusal says who stopped it, when, and what lifts
  it. There is deliberately no environment-variable bypass: lifting a suspension means editing the
  table, which leaves a diff.
- The VM host, the control box and the jump hosts are known to `rlab` as ssh aliases only; their
  addresses live in the operator's `~/.ssh/config`, not in this repository.
- No tool here holds a password or a key. The only step that needs a password is
  `ndtwin-virt-root.sh`, which a person runs with `sudo`.

## `ndtwin-vm.sh`: VM life cycle

```
ndtwin-vm.sh create           fetch the cloud image, build the seed, make the disk
ndtwin-vm.sh start            boot it (daemonised, survives an ssh disconnect)
ndtwin-vm.sh stop             graceful shutdown, wait for the process to go
ndtwin-vm.sh status           pid / port / disk / snapshots / guest reachability
ndtwin-vm.sh ssh [cmd...]     run a command in the guest (or open a shell)
ndtwin-vm.sh snap <name>      stop if needed, snapshot, restore the previous run state
ndtwin-vm.sh restore <name>   roll back to a snapshot
ndtwin-vm.sh snaps            list snapshots
ndtwin-vm.sh vms              every lab VM on this host: dir / owner / port / pid
ndtwin-vm.sh keep "<why>"     mark this disk as must-not-delete (--clear to lift)
ndtwin-vm.sh adopt [pid]      register a running VM this tool did not start
ndtwin-vm.sh destroy          delete the disk (asks for a confirmation word)
```

It uses plain qemu (no libvirt, so no extra root daemon) with user-mode (SLIRP) networking: the
guest gets outbound NAT and no layer-2 presence on the lab subnet, and no tap device is needed.
`/dev/kvm` is `root:kvm`, so being in the `kvm` group is what lets a non-root account start a VM
(a new login is needed after `ndtwin-virt-root.sh` adds the group).

One VM per session: `VM_DIR` and `SSH_PORT` are both environment variables and **both must differ**
between sessions (the defaults are `$HOME/ndtwin-vm` and 2222).

Working point: `VM_CPUS`, `VM_MEM`, `VM_DISK` and `SSH_PORT` come from the environment first, then
from the `CONFIG` file in the VM directory, then from built-in defaults. Because of that, a
`stop`, `snap`, `start` cycle that forgets to repeat the variables brings the VM back with the
working point it last ran with.

Acceptance is read from state (pid alive, ssh answers, snapshot listed), never from an exit code:
`qemu -daemonize` returns 0 long before the guest is usable.

### The guards

| Guard | Behaviour |
|---|---|
| `NDT_OWNER` is required | Any verb that mutates a VM refuses to run without it (fail closed) |
| `$VM_DIR/OWNER` | Another session's VM is refused with **`rc=3`**, which prints that session's claim and the full command to create your own VM |
| `SSH_PORT` in use | Refused with **`rc=4`**, listing who holds the port |
| `CONFIG` | Working point precedence is env, then `CONFIG`, then built-in default; `start` prints which source it used, and warns loudly when it falls back to the built-in defaults although a disk already exists |
| Snapshot names | Generic names (`fresh`, `base`, `clean`, `test`, `tmp`, `snap`, `backup`) are refused, and so is a tag that already exists, because `qemu-img` silently allows duplicate tags |
| Snapshot listing | Read with `-U`; "could not read" and "there are none" are printed as different things |
| `NDTVM_FORCE=1` | Overrides a foreign claim, and **writes the override into the `OWNER` file of the VM it took** |
| `vms` | Read-only and needs no `NDT_OWNER`: looking up who holds what must not require already holding something |
| `stop`, `ssh` | Guarded like the other mutating verbs (`ssh <cmd>` can change a VM, and `stop` takes down someone else's running work) |
| `keep` | Marks the disk as must-not-delete; `vms`, `status` and `destroy` all show it. `destroy` then lists the snapshot tags and wants `DESTROY <directory name>` instead of the bare word |
| `adopt` | Registers an already-running VM: writes `OWNER` and `CONFIG` with the working point read **from the process's own argv** (`/proc/<pid>/cmdline`), not from input. With a pid, the VM directory is read from argv too, so it works for a VM that was not laid out by this script. It prints a loud warning when the ssh forward is not on loopback |

`claim_guard` refuses (under `NDTVM_FORCE=1` it appends a `FORCED:` line to `OWNER` instead),
and `claim_write` is what writes the claim; only `create`, `start` and `adopt` call the latter.
So `ssh` is guarded, but you can still look inside an unowned VM without taking it over.

`vms` identifies a qemu process by `/proc/<pid>/exe`, not by command-line text: `exe` is kept by
the kernel and a process cannot set it, whereas a grep, an editor or a shell that merely mentions
`qemu-system` has it in its argv. When `exe` cannot be read (another user's process) but argv[0]
looks like qemu, the row is listed and marked **unverified**, on the line where it is used. It also
marks listeners on the VM's forwarded ports: a port bound outside loopback is flagged, a local
sshd is a neutral note. The classification is a pure function of the address string
(`addr_is_loopback`, `listener_level`; all of `127.0.0.0/8` and `::1`, with or without a `%scope`
suffix, count as loopback).

### Owner names

`NDT_OWNER` must be a **single word**: a name containing spaces is refused by its own VM.

## `host_witness.sh`: what is running on this host

```
host_witness.sh [interval_sec] [count]      # count 0 = run until killed
host_witness.sh --self-test                 # pure: a fake procfs, no processes
```

It writes one line every interval for the length of a measurement window, so that a later reader
can tell whether a VM or other heavy process was present on the host. Things to know:

- **Every line carries `host=`.** A record of what is on a machine must say which machine; a log
  with no hostname can be read as describing the wrong one.
- A VM is identified by `/proc/<pid>/exe`. Each process is classified three ways: `vm`, `other`,
  or `unreadable` (could not be read). A `vms=` count therefore means "VMs I could read"; a
  process running as another user may be missing from it.
- It samples cheaply (one `find` and shell `read`, no fork per pid) because an instrument that
  accounts for load must not be a significant source of it. Its real cadence is
  `interval + sampling cost`.
- Unrecognised options are rejected rather than treated as an interval (`--help` prints usage).
- The log ends with a `# end ... reason=...` line on normal exit, on a signal, on a failing
  `sleep`, or when the cadence collapses. **A log with no `# end` line was truncated** (a SIGKILL
  cannot write one). To check whether a witness died mid-window, read the line count twice a few
  seconds apart.
- The log's own cadence is its version stamp: if you change sampling cost or cadence, tell
  whoever is comparing runs against it.

## Tests

```bash
bash tools/remote-lab/test_vm_coordination.sh
```

It runs entirely on the local machine and touches no lab machine. Every gate is checked both
ways (forced red and forced green), and assertions compare the message text as well as the exit
code, because several different failures share `rc=1`. Paths inside the test are relative to the
script, so it tests the copy you checked out rather than some other copy on the machine.

What the gate is built to cover:

- **The surface, not the guards that happen to exist.** `MUTATING` and `READONLY` are two written
  lists of verbs, and a structural check (G10) asserts them against the dispatch of `ndtwin-vm.sh`
  itself. The population is derived by parsing the `case` labels of the real script (G10a), so a
  new verb is red until someone decides which list it belongs to; the parser has its own control
  (it must find the known `destroy` and `vms`).
- **`keep` and `adopt`** (G13, G14, G15): the `KEEP` marker is written by hand in the test rather
  than by `keep`, so a broken writer cannot make the reader's test green. `adopt` derives its
  working point and directory from a real process's argv, and the stand-in processes include a
  form of `-drive`/`hostfwd` that the tool itself never produces.
- **Port and exposure classification** (G16): table-driven tests of the loopback classifier,
  without opening any socket.
- **`destroy`** takes the registry entry with it, and `vms` shows a directory without a disk as
  "leftover files only, not a VM" instead of as an occupancy (G11, G12).
- **Process identity** (G17): a VM is recognised by `exe`; the test keeps one process whose argv merely
  says `qemu-system-x86_64` as a negative control, which must not be counted.

[Co-developed with claude code -- Adam]
