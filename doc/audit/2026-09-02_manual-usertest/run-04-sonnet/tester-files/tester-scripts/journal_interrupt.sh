#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Tooling note: a stop in my own harness, not the project   15:51 -> caught ~15:57
what happened: I launched the Section 4.2 `ninja` build inside the VM (detached via
setsid/nohup, PID 12329) at 15:51, then incorrectly assumed my own tooling would push me a
notification when a *VM-side* detached process finished, the way it does for a background
task started directly by my own shell tool. It does not: the build kept compiling on the VM
the whole time (confirmed via `ps aux` still showing live `cc1plus` processes and a growing
ninja log at 15:56), but nothing was watching it from my side, and I stopped acting. An
external check caught this and told me to resume. This is friction in my own tooling/process,
not anything NDTwin did -- recorded here only so it is not mistaken for the project hanging.
Corrected going forward: actively re-check VM-side background work myself on a timer instead
of assuming a push notification will arrive for it.
EOF
echo APPENDED
tail -15 ~/JOURNAL.md
