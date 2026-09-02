#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## Minor doc slip: Simulation Platform Manager's worked example gives the wrong port
- **Feature:** NDTwin Integration Check (Section 5.4 of the Simulation Platform install page)
- **Manual page/section:** Installation Manual > NDTwin Tool > Simulation Platform Manager >
  "5.4 NDTwin Integration Check".
- **Exact text (quoted):**
  ```cpp
  std::string SIM_SERVER_URL = "http://<YOUR_SIM_IP>:8003/submit";
  ```
  with the note "If ... run on the same machine, you can set `<YOUR_SIM_IP>` to `localhost`."
- **Expected:** substituting `localhost` for `<YOUR_SIM_IP>` in the example gives a URL that
  matches where the Simulation Platform Manager actually listens.
- **Observed:** `NDTwin-Kernel/setting/AppConfig.hpp` (and `.hpp.example`, both) already ship
  with `SIM_SERVER_URL = "http://localhost:9000/submit"` -- **port 9000**, not 8003 --
  and that is genuinely correct: `Simulation-Platform-Manager/include/settings/sim_server.hpp`
  declares `sim_server_port = 9000`, and running `sudo ./simulation_platform_manager` for real
  confirmed it: `Server started at http://localhost:9000`, with `sudo ss -tlnp` showing it
  listening on `0.0.0.0:9000`. A reader who trusted the manual's own worked example over the
  shipped default and typed `:8003` would have silently pointed the kernel at a port nothing is
  listening on.
- **Severity (my guess):** Low -- the shipped default is already right, so nothing broke for
  me; only a reader who edits `AppConfig.hpp` by hand using the manual's literal example text
  would be affected, and only in a way that fails quietly (no error at kernel build or start
  time, just a submission that never arrives).

## Note: Energy-Saving-App's NFS mount depends on state nothing in this page creates on its own
- **Feature:** `sudo ./energy_saving_app`, tried standalone (no Ryu/Mininet/Kernel running)
- **Manual page/section:** Simulation Platform Manager pages do not show a startup command for
  this binary directly -- the closest is the shared "Startup Sequence" (Ryu, Mininet, Kernel,
  Simulation Platform Manager), which does not name the application layer at all.
- **Observed (verbatim):**
  ```
  Error: connect: Connection refused [...] (attempting to reach the kernel, not running yet)
  [info] Mount NFS
  [info] mount -t nfs localhost:/srv/nfs/sim/power /mnt/nfs/app
  mount.nfs: mounting localhost:/srv/nfs/sim/power failed, reason given by server: No such
  file or directory
  [critical] Mount NFS Failed
  ```
  (exit 1). `/srv/nfs/sim/power` (an app-specific subdirectory of the shared export) does not
  exist, and nothing in the Installation Manual's NFS section creates per-app subdirectories --
  only the top-level `/srv/nfs/sim` (Section 3.1) and the two mount *points* (Section 3.2).
  My best guess, not confirmed by reading source, is that this subdirectory is created as a
  side effect of a successful `/ndt/app_register` call against a running kernel, which never
  happened here because the kernel was not up in this isolated test. Recording as a dependency
  gap rather than a bug: I did not attempt the full Ryu -> Mininet -> Kernel -> app sequence
  for this component given the remaining time in this run, so I cannot say whether starting it
  in the documented order avoids this. `simulation_platform_manager` itself, by contrast,
  mounted its own NFS directory (the top-level one, which *does* exist from Section 3.1) and
  started cleanly standalone, with no kernel required first.
EOF
echo APPENDED
wc -l ~/BUGS.md
