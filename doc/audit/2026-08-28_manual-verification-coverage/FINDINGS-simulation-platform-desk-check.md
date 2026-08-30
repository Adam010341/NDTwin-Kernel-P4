# Simulation Platform — desk check of both pages, against the source

2026-08-30 ~19:57. **Desk check only**; the live run needs the app built in the guest and a
fabric, and is registered for tomorrow. Every claim below is checked against
`/home/adam/Simulation-Platform-Manager` and `/home/adam/Energy-Saving-App`, not inferred from
the pages.

**Scope correction:** the dispatch scoped this as "the UM Simulation Platform page, 1 bash
block". That is the *usage* page. The **install** page carries **nine** blocks, including an
entire NFS server/client setup. Same shape as NSR: the journey is bigger than the page it is
named after.

---

## S-1 — `/mnt/nfs/sim` is never created, and the two roles are never named

The usage page, explaining why `sudo` is needed:

> The server requires root privileges to mount the NFS directory **`/mnt/nfs/sim`** during
> operation.

The install page creates:

| path | where |
|---|---|
| `/srv/nfs/sim` | the **export**, blocks 4–5 |
| **`/mnt/nfs/app`** | the **mount point**, block 7 |
| `/mnt/nfs/sim` | **nowhere** |

⚠️ **My first reading was "one of the two pages is wrong". That is withdrawn.** The source has
*both* paths, and they belong to two different roles:

```
include/settings/app.hpp:27         nfs_mnt_dir = "/mnt/nfs/app"    <- the app side
include/settings/app.hpp:33         mount -t nfs <ip>:/srv/nfs/sim  …
include/settings/sim_server.hpp:18  nfs_mnt_dir = "/mnt/nfs/sim"    <- the sim-server side
```

So the real defect is narrower and more useful:

1. **The install page never creates `/mnt/nfs/sim`**, the directory the usage page says the
   manager mounts. A reader who follows the install page has `/mnt/nfs/app` and nothing else.
2. **Neither page says there are two roles.** `app.hpp` and `sim_server.hpp` describe an app
   machine and a sim-server machine with different mount points; the pages present a single
   linear procedure with no hint that the reader is configuring two sides.

🔑 Fifth time tonight that reading the service side before asserting changed the finding. "One
page is wrong" would have sent someone to correct a value that is correct.

## S-2 — a comment and its command contradict each other, two lines apart

Install page, the recommended Makefile route:

```bash
# From the source root of Energy-Saving-App
cd Energy-Saving-App
make all
```

If the reader is already at the source root, `cd Energy-Saving-App` has nothing to enter. The
comment and the command cannot both be followed.

## S-3 — §5.3's `cd` assumes a directory the previous step moved away from

```bash
cd Simulation-Platform-Manager
make all
```

§5.2 leaves the reader in Energy-Saving-App's source root (its own `cp` example says so
explicitly: `cp ./energy_saving_simulator ../Simulation-Platform-Manager/…`). From there the
sibling is `../Simulation-Platform-Manager`.

⇒ **Third and fourth `cd` defects of the night**, after M-1 and NSR's install page. All four have
the same shape: *a path that is correct from one place, printed where the reader is somewhere
else, failing quietly.* This is now a pattern across four pages and worth one systematic pass
rather than four spot fixes.

## Checked and correct

* **ESA's Makefile really does automate registration**, as the page claims: `all: … app sim`
  and a `sim:` target exist, and the path it writes —
  `registered/energy_saving_simulator/1.0/executable` — matches the page exactly.
* The `/srv/nfs/sim` export path in blocks 4–5 matches `sim_server.hpp:17`
  (`nfs_server_dir = "/srv/nfs/sim"`).
* The usage page's startup order (Ryu → Mininet → NDTwin Kernel → Simulation Platform Manager)
  matches what T-4 observed: the manager needs the kernel serving before it does anything.

## Not covered — registered for the live run

Nine install blocks (apt dependencies, an NFS server *and* client, config edits, two builds) and
the single usage block. It needs the app compiled in the guest and a fabric for the manager to
talk to. **Note also that `sudo ./simulation_platform_manager` will attempt a real `mount -t
nfs`** — the first block on this line that changes system state beyond a package install, so the
guest snapshot matters before it runs.

[Co-developed with claude code -- Adam]
