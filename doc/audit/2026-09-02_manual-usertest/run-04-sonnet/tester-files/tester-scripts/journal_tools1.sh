#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Network State Recorder: install + use   started 16:04   ended 16:31   friction: 2
what I did: Installation Manual steps (clone to `~`, `python3 -m venv ~/nsr-env`, pip install
nornir/loguru/orjson/requests, chmod +x the two scripts) all worked cleanly. User Manual's
"Option 1: Background Mode (Recommended)" -- literally `./start_network_state_recorder.sh`,
no environment activation mentioned on that page -- crashed immediately with
`ModuleNotFoundError: No module named 'nornir'`, because the script runs bare `python3`, not
an interpreter path pointing at `~/nsr-env` the way the Installation Manual's own warning box
implies it does. Workaround: `source ~/nsr-env/bin/activate` first, then it started cleanly,
logged correctly, and (confirmed by generating iperf3 traffic on the live OVS fabric and
checking the rotated `.zip`, not just the open `.json`, which reads 0 bytes until rotation)
recorded real flow and graph data in the documented newline-delimited JSON format. Then tested
the stop script and it did something worse than the failed start: `stop_network_state_recorder.sh`
runs `sudo kill -15 $(pgrep -f network_state_recorder.py)` -- exactly the pattern the User
Manual's own NSR page, a few lines further down the same document, explicitly warns not to
use. It reproduced live: `pgrep -f` matched both the real NSR process *and* the unrelated
shell that had run my previous command (because that shell's own command-line text happened
to contain the string "network_state_recorder.py"), and the stop script killed both --
terminating that earlier SSH connection as a side effect. Full detail: BUGS.md BUG-4.
surprised by: a shipped script contradicting a warning on the very same page of the manual it
ships with.
verdict: 2 needed a workaround -- for the start-script gap (activate the venv first); the
stop-script issue has no workaround I am willing to invent (that would mean rewriting the
project's own script), so I just stopped NSR by hand afterward via a single confirmed PID.

## Web GUI: install (Docker) + deploy attempt   started 16:26   ended 16:32   friction: 3
what I did: Docker/Compose install per the manual -- `sudo apt install ... docker-ce ...`
etc. -- worked (`docker --version` 29.7.2, `docker compose version` v5.5.0). Two harmless doc
slips noticed and recorded (a `chmod` on `docker.asc`, a file the preceding line never creates
-- it creates `docker.gpg`; and a redundant `groupadd docker` that always reports "already
exists" in this step order on 24.04). Cloned `Web-GUI`, `cp .env.example .env`, set
`NDT_API_BASE_URL=http://127.0.0.1:8000` (this session's own live kernel), ran
`./web_gui_deploy.sh`. The frontend Docker image failed to build: `pnpm install
--frozen-lockfile` inside the Dockerfile hit `ERR_PNPM_IGNORED_BUILDS` on `esbuild@0.25.5`,
because the Dockerfile installs pnpm with a bare, unpinned `npm install -g pnpm` and today
that resolves to pnpm v12.3.0, whose newer default policy refuses to run a dependency's
install/build script without interactive approval -- which a `docker build` cannot give. The
whole `docker compose`/bake run then aborts: zero containers ever start (`docker compose ps -a`
is empty), so `localhost:3000` was never reachable and none of the GUI-feature checklist items
under this tool could be attempted even in principle. Did not patch the Dockerfile to pin an
older pnpm -- that would be fixing the project, not testing it. Full detail: BUGS.md BUG-5.
verdict: 3 blocked: the documented one-command deploy path cannot produce a running Web GUI on
a from-scratch Ubuntu 24.04 install today; no alternative deploy path is documented on this
page, so this tool's GUI features are recorded as NOT-TRIED (blocked), not BROKEN individually
-- I never got far enough to try them.
EOF
echo APPENDED
