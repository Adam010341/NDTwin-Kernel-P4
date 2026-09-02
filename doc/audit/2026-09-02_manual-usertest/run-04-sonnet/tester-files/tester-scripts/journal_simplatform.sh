#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Simulation Platform Manager + Energy-Saving-App: install + partial use   started 16:38   ended 16:44   friction: 1
what I did: cloned both repos, apt deps were already satisfied from the Kernel section, NFS
server+client installed and configured (`/srv/nfs/sim` exported to `localhost`, mount points
`/mnt/nfs/sim` and `/mnt/nfs/app` created). The two `settings.hpp.example` templates already
default to the same-machine-demo values the manual describes (`localhost` everywhere), so I
just copied them to `settings.hpp` rather than hand-editing anything. `make all` (not bare
`make`, per the manual's own warning) built Energy-Saving-App cleanly and correctly copied
`energy_saving_simulator` into `Simulation-Platform-Manager/registered/.../executable`; `make
all` on Simulation-Platform-Manager also succeeded. Checked `NDTwin-Kernel/setting/
AppConfig.hpp`'s `SIM_SERVER_URL` before touching anything: it already read
`http://localhost:9000/submit`, which is correct -- but the manual's own worked example for
this exact setting shows port **8003**, not 9000. Recorded as a doc bug rather than acted on,
since the shipped default was already right.
Tried `sudo ./simulation_platform_manager` standalone, out of curiosity, without first
bringing up Ryu/Mininet/Kernel (the manual's documented order puts it fourth in the sequence,
but nothing on this page says it *requires* the earlier three to already be running just to
start). It came up cleanly: real `mount -t nfs localhost:/srv/nfs/sim /mnt/nfs/sim` (verified
independently with `mount | grep nfs`, not just trusting its own log line), "Server started at
http://localhost:9000" (verified with `ss -tlnp`, genuinely listening). Then tried `sudo
./energy_saving_app` the same way, also standalone: it failed at its own NFS mount step
(`mount.nfs: ... /srv/nfs/sim/power ... No such file or directory`) after a connection-refused
error trying to reach the (not-yet-running) kernel first. My guess -- not confirmed by reading
source -- is that the app-specific NFS subdirectory only gets created once a kernel
registration succeeds, which this isolated test never triggered.
Stopped both cleanly (Ctrl-C) and confirmed the NFS mount released.
verdict: 1 confusing but worked -- the install steps themselves were friction-free; the one
real gap is the SIM_SERVER_URL port in the manual's own example, and the undocumented
dependency the application layer (as opposed to the manager) has on a kernel already having
registered it. Did not pursue the full four-terminal-plus-app end-to-end run given remaining
time in this session; recorded as NOT-TRIED rather than BROKEN since I did not actually
attempt it in the documented order.
EOF
echo APPENDED
