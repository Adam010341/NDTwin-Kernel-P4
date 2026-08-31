# The NDTwin tools on this image

Six programs ship here. Four of them start with no ceremony. **Two of them will exit
immediately if you run them the obvious way**, and this file exists because that failure
looks like a broken build and is not one.

`PROVENANCE.txt`, next to this file, records which commit of each tool you have.

---

## The two that need root

`energy_saving_app` and `simulation_platform_manager` **mount NFS as their first action and
abort if the mount fails.** Run either as an ordinary user and you get:

```
Mount NFS Failed
```

and the process is gone. Nothing is wrong with the binary.

### The supported way

systemd units are installed for both. They do the mount first, then start the program:

```bash
sudo systemctl start ndtwin-esa      # Energy-Saving-App        -> listens on :8001
sudo systemctl start ndtwin-spm      # Simulation-Platform-Mgr  -> listens on :9000
sudo systemctl start ndtwin-reqmgr   # request_manager          -> listens on :8002
```

```bash
sudo systemctl stop ndtwin-esa ndtwin-spm ndtwin-reqmgr
```

**The units are installed but deliberately not enabled.** Enabling them would make this image
boot with three services listening and an NFS server running, on whatever network you put it
on. That is your decision, not ours, so it is left unmade:

```bash
sudo systemctl enable --now ndtwin-esa
```

### The manual way, if you would rather see it happen

```bash
sudo /usr/local/sbin/ndtwin-nfs-up
cd ~/Desktop/Energy-Saving-App && sudo ./energy_saving_app
```

`ndtwin-nfs-up` creates `/srv/nfs/sim`, starts `nfs-server`, and mounts `/mnt/nfs/sim` and
`/mnt/nfs/app`. It is safe to run twice.

### About the exports

`/etc/exports` on this image binds both shares to **localhost only**.

The upstream Simulation-Platform-Manager repository ships an `etc.exports` pinned to
`192.168.50.21`. That is an address on the lab network the tool was written for. Copied into an
image that gets handed to other people, it would export a writable share to whoever happens to
hold that address on *their* network. If you are rebuilding the lab setup and want the original
behaviour, that file is still in the repository — the change is ours and it is deliberate, not
an accident of packaging.

---

## The one that is patched

`Network-Traffic-Visualizer` is checked out at `main` (`9b56b30`) **with a local patch applied**,
`NDTwin-local-changes.patch`, sitting in that directory.

Upstream `main` does not compile. `WindowStateRestore` is called from four places and declared
nowhere in the repository. The patch comments out those four calls and restores the work each
one was wrapping. It is a byte-for-byte copy of the workaround the NDTwin author uses locally.

To go back to untouched upstream:

```bash
cd ~/Desktop/Network-Traffic-Visualizer && git apply -R NDTwin-local-changes.patch
```

(and it will then not build, which is the point.)

You lose no functionality by keeping the patch. See `PROVENANCE.txt` for why.

### Starting it

It is a JavaFX application, and JavaFX is not inside the jar:

```bash
cd ~/Desktop/Network-Traffic-Visualizer
java --module-path /usr/share/openjfx/lib \
     --add-modules javafx.controls,javafx.fxml,javafx.swing,javafx.media,javafx.web \
     -jar target/NDTanimation-1.0-SNAPSHOT.jar
```

Without `--module-path` you get `JavaFX runtime components are missing`, which also looks like a
broken build and also is not one.

---

## The three that just run

```bash
cd ~/Desktop/Traffic-Engineering-App && python3 Traffic-engineering-App.py   # interactive menu
cd ~/Desktop/Energy-Saving-App && ./energy_saving_simulator <in.json> <out.json>
cd ~/Desktop/Simulation-Platform-Manager && ./request_manager               # :8002
```

`energy_saving_simulator` is a command-line converter, not a server. Run it with no arguments
and it prints its usage — that is it working.

---

## Rebuilding any of them

```bash
make -C ~/Desktop/Energy-Saving-App all
make -C ~/Desktop/Simulation-Platform-Manager all
cd ~/Desktop/Network-Traffic-Visualizer && ./mvnw -DskipTests package
```

**`make` on its own is not enough for the two C++ trees.** Both Makefiles define their
settings-header rule before `all`, and GNU make's default goal is the first non-special target
in the file — so bare `make` generates a header and stops, successfully, having built nothing.
Say `make all`.

---

## Ports, in one place

| port | program | root? |
|------|---------|-------|
| 8000 | NDTwin kernel | no |
| 8001 | `energy_saving_app` | **yes** |
| 8002 | `request_manager` | no |
| 9000 | `simulation_platform_manager` | **yes** |

[Co-developed with claude code -- Adam]
