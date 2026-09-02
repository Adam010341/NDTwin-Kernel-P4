#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## BUG-4: `start_network_state_recorder.sh` does not use the environment the Installation Manual has you build, and crashes immediately when followed literally
- **Feature:** Network State Recorder, "Option 1: Background Mode (Recommended)"
- **Manual page/section:** User Manual > NDTwin Tools > Network State Recorder > "Starting
  NSR" > Option 1. Cross-referenced against Installation Manual > NDTwin Tool > Network State
  Recorder, whose own warning box reads: "`start_network_state_recorder.sh` launches the
  recorder with an interpreter path written **inside the script**, so open it once and check
  that path points at the environment you just created."
- **Exact steps (verbatim, exactly as the User Manual's Option 1 shows -- no environment
  activation mentioned on that page):**
  ```
  cd ~/Network-State-Recorder
  ./start_network_state_recorder.sh
  ```
- **Expected:** NSR starts in the background (the page's whole framing -- "Recommended" -- is
  that this is the normal way to start it).
- **Observed (verbatim):**
  ```
  Traceback (most recent call last):
    File "/home/ndt/Network-State-Recorder/network_state_recorder.py", line 6, in <module>
      from nornir import InitNornir
  ModuleNotFoundError: No module named 'nornir'
  ```
  `cat start_network_state_recorder.sh` shows why: the line that starts the recorder is
  `nohup python3 network_state_recorder.py &` -- a **bare** `python3`, no venv path at all.
  This contradicts the Installation Manual's own description of the script (quoted above) --
  there is no interpreter path inside it to check, because there is no interpreter path inside
  it. `nornir`/`loguru`/`orjson` were installed exactly where the Installation Manual says to
  put them, `~/nsr-env` (`python3 -m venv ~/nsr-env && source ~/nsr-env/bin/activate && pip
  install nornir loguru orjson requests`) -- the script simply never activates or references
  that venv.
- **Workaround (not a fix -- friction, not resolution):** `source ~/nsr-env/bin/activate` in
  the same shell immediately before `./start_network_state_recorder.sh` works, because the
  script's bare `python3` then resolves to the venv's interpreter via `$PATH`. This is not
  written anywhere on the User Manual's NSR page for Option 1 (only implied for Option 2, and
  only if the reader already infers it from Section 2's own general PEP-668 warning many pages
  earlier).
- **Second, independent finding in the same two files:** `stop_network_state_recorder.sh`
  itself does exactly what the **User Manual's own NSR page**, a few lines further down,
  explicitly tells the reader never to do:
  ```
  # stop_network_state_recorder.sh, verbatim:
  sudo kill -15 $(pgrep -f network_state_recorder.py)
  ```
  compare the manual's own words on the same feature: *"Do not pipe the search straight into
  `kill`. Writing `sudo kill -15 $(pgrep -f network_state_recorder.py)` looks shorter, but it
  fails in three ways and all three are silent... Listing first and naming one PID costs one
  extra line and removes all three."* The shipped stop script is a working example of the
  exact anti-pattern the prose two sections earlier warns against. (I did not need this script
  to reproduce the failure mode myself -- the point stands regardless of whether it happens to
  misfire on this particular machine today.)
- **Reproduced on a second try?** Ran `./start_network_state_recorder.sh` a second time after
  activating `~/nsr-env` first; it then started cleanly (`pgrep -af network_state_recorder.py`
  showed a real PID, `./recorded_info/` began filling with `*_flowinfo.json` /
  `*_graphinfo.json`). The bare-`python3` failure itself was not re-run a second time since it
  is a static property of the script's one line, not a timing-dependent fault.
- **Severity (my guess):** Medium. "Recommended" + fails on the first try for anyone who has
  not separately read and remembered the Installation Manual's interpreter-path warning (which,
  per this bug, is itself describing a script that does not match) is a bad combination for a
  first-time user; the fix is one line (`source ~/nsr-env/bin/activate` first) once you know to
  look for it.
EOF
echo APPENDED
wc -l ~/BUGS.md
