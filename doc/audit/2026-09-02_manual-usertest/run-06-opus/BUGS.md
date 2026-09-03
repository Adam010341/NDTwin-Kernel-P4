# BUGS.md - things that did not match the manual

Format per entry: feature | manual page+section | exact steps | expected (quoted) | observed
(verbatim) | reproduced? | severity guess.

---
### BUG-01 (doc) - cloned README points at a demo VM the download page says is not published
* **Feature:** getting the P4 build without building it
* **Manual page / section:** Download page ("Quick Start (Recommended)") vs
  `README.md` at the root of `NDTwin-Kernel-P4-public` (which the Installation Manual Step 4.1
  tells you to clone)
* **Steps:**
  ```
  cd ~/Desktop && git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4-public.git NDTwin-Kernel
  cat ~/Desktop/NDTwin-Kernel/README.md
  ```
* **Expected (repo README, verbatim):** "If you would rather not build at all, the P4/BMv2 demo
  VM on the [download page](https://ndtwin.org/docs/download/) already has this installed and
  working."
* **Observed:** the Download page's own table row for that image reads
  `*(not yet published — see note)*`, and the installation manual's table reads
  `*(not yet published)*`. The image the README sends you to fetch cannot be fetched.
  Evidence: `~/ndtwin-docs/Download/_index.md`,
  `~/ndtwin-docs/NDTwin Installation Manual/.../Use the Demo VM for a Quick Start/index.md`.
* **Reproduced?** It is a static contradiction between two shipped documents; re-read both, same.
* **Severity:** low (doc), but it costs a reader the entire decision "build or download" --
  and the download page's prose ("Take the P4/BMv2 image if ... you want the application set")
  reads as though it were available.
* **Consequence for me:** the Section 6 source build is the only route to P4, so I must budget
  the 1-2 hour toolchain build rather than downloading.
---
### BUG-02 (friction, install) - the manual's own detached form of Step 6.1 blocks on a sudo password prompt, and the manual's own way of checking on it cannot see that
* **Feature:** Step 6.1, "⏱ **Run it detached.**"
* **Manual page / section:** Installation Manual > Native-Linux Excution Environment >
  Step 6.1: Install BMv2 and p4c
* **Steps (verbatim, exactly the manual's block):**
  ```
  cd ~
  git clone https://github.com/jafingerhut/p4-guide
  tmux new-session -d -s p4 \
    'cd ~ && ./p4-guide/bin/install-p4dev-v8.sh 2>&1 | tee log.txt; \
     echo "SCRIPT_EXIT=${PIPESTATUS[0]}" >> log.txt'
  ```
* **Expected (manual, verbatim):** "Come back to it with either of these — the log is the same
  `log.txt` the foreground form writes: ... `tail -3 ~/log.txt`  # or just read the tail".
  The clear implication is that the run proceeds unattended for one to two hours.
* **Observed:** 90 seconds in, the run is stopped dead. `tmux capture-pane` shows
  (`~/logs/p4-pane-check1.txt`):
  ```
  + '[' ubuntu = ubuntu ']'
  + sudo apt-get --yes update
  [sudo] password for ndt:
  ```
  and the manual's recommended check shows **no sign of it**, because sudo writes the prompt to
  the terminal and not to the pipe that `tee` is capturing (`~/logs/p4-pane-check1.txt` vs
  `tail -5 ~/log.txt`):
  ```
  === tail log.txt ===
  + '[' ubuntu = ubuntu ']'
  + sudo apt-get --yes update
  === wc log ===
  90 /home/ndt/log.txt
  ```
  So `tail -3 ~/log.txt` shows a plausible last line and a run that will never finish.
  `grep SCRIPT_EXIT ~/log.txt` -- the manual's "written only when the script has actually
  finished" check -- is empty, which is the same thing it prints during a healthy two-hour
  build. **Neither of the two documented checks distinguishes "compiling" from "waiting for a
  password since 10:31".**
* **Reproduced?** Not re-run from scratch (it is a two-hour build and the manual warns the
  script is not resumable and that a bare retry can exit 0 on a broken tree). The mechanism is
  not in doubt: the prompt is in the pane, `sudo -n true` fails for this user, and the run
  resumed the instant the password was supplied.
* **Workaround I applied (a workaround, not a fix -- the manual has a gap here):**
  `tmux send-keys -t p4 'ndt' Enter`, i.e. what a person who attached to the session would do.
  Run resumed at 10:32:26 and `log.txt` went from 90 to 456 lines within 25 seconds
  (`~/logs/unblock.log`, `~/logs/p4-pane-after-passwd.txt`).
* **What the manual would have needed to say:** warm the credential before detaching
  (`sudo -v`, or run one throwaway `sudo true`), or "attach once with `tmux attach -t p4`
  right after launching and answer the password prompt". It already tells you to detach *and*
  tells you the two ways to check on it; the missing sentence is the one that makes those two
  checks meaningful.
* **Severity:** medium. It does not corrupt anything, but it silently converts a 2-hour
  unattended build into an infinite wait, and the manual's own monitoring advice conceals it.
  Cost to me: ~1.5 minutes because I looked at the pane; cost to someone following the manual
  literally and coming back in two hours: two hours.
---
### BUG-03 🔴 (product) - `acquire_lock` with no `type` still silently acquires `routing_lock`, exactly the behaviour the API doc says was fixed on 2026-08-30
* **Feature:** `POST /ndt/acquire_lock`
* **Manual page / section:** Developer Manual > NDTwin Kernel API > §27 `POST /ndt/acquire_lock`
* **Expected (manual, verbatim):**
  > "**`type` is required.** There is no default. Until 2026-08-30 a missing, malformed or
  > unknown `type` silently acquired `routing_lock` — the lock that serialises writes to real
  > switches — and answered `200 {"status":"locked","type":"routing_lock"}`, so a caller could
  > hold that lock without ever having named it. **All three now return `400` and acquire
  > nothing.**"
  and, in the table: "Absent, non-string, or any other value → `400`, and no lock is touched."
  and, in the error section: "**No lock is acquired in any of these cases.** `detail` quotes
  what the caller sent, never a value the server substituted."
* **Steps (verbatim, from a state where nothing is held — `~/logs/api-locks-round2.log`):**
  ```
  curl -s -X POST -H 'Content-Type: application/json' -d '{"type":"routing_lock"}' \
       http://localhost:8000/ndt/release_lock            # -> 200 {"status":"released",...}
  curl -s -X POST -H 'Content-Type: application/json' -d '{"ttl":30}' \
       http://localhost:8000/ndt/acquire_lock
  ```
* **Observed (verbatim):**
  ```
  ===== 1) acquire_lock, body {"ttl":30}, NO type =====
  HTTP 200
  {"status":"locked","ttl":30,"type":"routing_lock"}
  ```
  That is the old response the doc quotes, character for character. It is not merely a wrong
  status code — **the lock is really taken.** The very next request, which does name the lock
  properly, is refused because it is held:
  ```
  ===== 2) proof it really took routing_lock: ask for routing_lock =====
  HTTP 423
  {"detail":"System busy or invalid lock type: routing_lock","error":"Lock acquisition failed"}
  ```
  All four "should be 400, should acquire nothing" cases behave the same way:
  ```
  ===== 4) acquire_lock with EMPTY body {} from clean state =====
  HTTP 200
  {"status":"locked","ttl":5,"type":"routing_lock"}
  ===== 6) acquire_lock with NON-STRING type 123 from clean state =====
  HTTP 200
  {"status":"locked","ttl":5,"type":"routing_lock"}
  ===== 8) acquire_lock with NO BODY AT ALL =====
  HTTP 200
  {"status":"locked","ttl":5,"type":"routing_lock"}
  ```
  The only malformed input that is refused is an **unknown string** type, and even that answers
  `423`, not the documented `400` (`~/logs/api-locks-clean.log`):
  ```
  ===== C) acquire_lock with UNKNOWN type, nothing held (doc: 400) =====
  HTTP 423
  {"detail":"System busy or invalid lock type: not_a_lock","error":"Lock acquisition failed"}
  ```
  A second documented promise is broken alongside it: for the empty-body and non-string cases
  the `detail` string names `routing_lock`, **a value the caller never sent**, which the doc
  says explicitly never happens.
* **Reproduced?** Yes. Twice, in two separate runs, from a verified-clean lock state each time
  (`~/logs/api-locks-clean.log` test A, then `~/logs/api-locks-round2.log` tests 1/4/6/8).
  Between every case I released the lock and confirmed the release returned
  `200 {"status":"released"}`.
* **Severity: high.** The doc itself states the stakes: `routing_lock` "serialises writes to
  real switches". An application with a typo in its request body takes that lock, gets a `200`
  that looks like success, and every other application's flow write is then serialised behind a
  lock nobody knows is held. The failure is invisible from the caller's side, and the
  documentation actively tells a reader this cannot happen any more.
* **Confusing extra:** the refusal message conflates two different conditions —
  `"System busy or invalid lock type: X"` is returned both when the lock is legitimately held
  by someone else and when the type is bogus. With `423` for both, a caller cannot tell "retry
  later" from "your request is malformed".
---
### BUG-04 (doc) - `install/modify/delete_flow_entry` return a different body from the one documented
* **Feature:** `POST /ndt/install_flow_entry`, `/ndt/modify_flow_entry`, `/ndt/delete_flow_entry`
* **Manual page / section:** Developer Manual > NDTwin Kernel API §9-§11
* **Expected (verbatim):** `{ "status": "Flows installed, modified and deleted" }`
* **Observed (all three, verbatim, `~/logs/d9-d11-flow-mutation.log`):**
  ```
  {"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}
  ```
* **Reproduced?** Yes, identical body on all three calls.
* **Severity: low.** The doc pre-emptively disclaims the wording ("its wording is not part of
  the contract and changes between releases, so do not parse it"), so a careful reader is
  warned. But the *shape* differs too (two extra fields, and `status` is now a state word
  rather than a sentence), and the new body is arguably more honest than the doc: `"queued"`
  plus "per-entry outcomes are reported in the kernel log, not in this response" tells you the
  200 is not a completion. **The rules themselves were verified on the switch and were correct**
  — see the coverage table, D9/D10/D11 all WORKS.

---
### BUG-05 (doc) - `get_cpu_utilization` and `get_memory_utilization` return byte-identical maps; the API page's examples imply they differ
* **Feature:** `GET /ndt/get_cpu_utilization`, `GET /ndt/get_memory_utilization`
* **Manual page / section:** Developer Manual > NDTwin Kernel API §12 and §13
* **Expected:** §12 says "In MININET mode, dummy values are generated for demonstration
  purposes" and shows `{"10.10.10.10":1,"10.10.10.3":1,...}`; §13 says the same and shows
  `{"10.10.10.10":28,"10.10.10.3":27,...}` — two different value sets.
* **Observed (verbatim, `~/logs/api-get-sweep.txt`):**
  ```
  ===== D12-get_cpu_utilization  GET /ndt/get_cpu_utilization =====
  {"192.168.123.11":14,"192.168.123.12":54,"192.168.123.13":36,"192.168.123.14":44,"192.168.123.15":39,"192.168.123.16":56,"192.168.123.17":25,"192.168.123.18":28,"192.168.123.19":52,"192.168.123.20":26}
  ===== D13-get_memory_utilization  GET /ndt/get_memory_utilization =====
  {"192.168.123.11":14,"192.168.123.12":54,"192.168.123.13":36,"192.168.123.14":44,"192.168.123.15":39,"192.168.123.16":56,"192.168.123.17":25,"192.168.123.18":28,"192.168.123.19":52,"192.168.123.20":26}
  ```
  Identical, field for field. (`get_temperature` returns a genuinely different map, so this is
  specific to these two.)
* **Note:** the **Web GUI** and **Visualizer** user-manual pages *do* warn about this
  ("Both are the same constant function of the switch's IP address, so the two fields always
  agree with each other"). The **API reference does not**, and the API reference is the page a
  developer reads. `ndt status` also warns
  ("/ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py").
* **Reproduced?** Yes, on every call in the sweep.
* **Severity: low-medium.** Nothing breaks, but an application author reading only §12/§13
  would reasonably build a memory-pressure heuristic on a number that is a hash of an IP
  address, and the examples actively suggest the two are independent measurements.

---
### BUG-06 (doc) - `get_nickname` with no identifier answers 400, documented as 404
* **Feature:** `GET /ndt/get_nickname`
* **Manual page / section:** Developer Manual > NDTwin Kernel API §19
* **Expected (verbatim):** "Returned if no identifier parameter (`dpid`, `mac`, or `name`) is
  provided in the URL. * Status: **404 Not Found** ... `{"error": "Missing dpid, mac, or name parameter"}`"
* **Observed (`~/logs/api-name-link.log`):**
  ```
  ===== D19 get_nickname with no identifier (doc: 404 'Missing dpid, mac, or name parameter') =====
  HTTP 400
  {"error":"Missing dpid, mac, or name parameter"}
  ```
  Body matches exactly; status code does not. (The genuine not-found case, `?dpid=99999`, does
  return the documented `404 {"error":"Device not found"}`.)
* **Reproduced?** Yes.
* **Severity: low.** The observed behaviour is arguably the more correct one — a malformed
  request is a 400 — so this reads as the doc being stale rather than the code being wrong.

---
### BUG-07 (doc, minor) - `set_switches_power_state` 400 message differs from the documented one
* **Feature:** `POST /ndt/set_switches_power_state`
* **Manual page / section:** Developer Manual > NDTwin Kernel API §8
* **Expected (verbatim):** `{ "error": "Missing or malformed query parameters" }`
* **Observed (`~/logs/d8-power.log`, request with `?ip=...` and no `action`):**
  `HTTP 400 {"error":"Missing or invalid ip/action"}`
* **Reproduced?** Yes. **Severity: very low** — same class of error, different wording.
  The endpoint's real behaviour was verified end to end and is correct (see D8 in coverage).

---
### BUG-08 (friction) - `POST /ndt/modify_device_name` edits a git-tracked file in your checkout, and nothing warns you
* **Feature:** `POST /ndt/modify_device_name`
* **Manual page / section:** Developer Manual > NDTwin Kernel API §15 ("Updates the name of a
  switch or host in the NDTwin topology **and StaticNetworkTopology.json**")
* **Steps:**
  ```
  curl -X POST -H 'Content-Type: application/json' \
       -d '{"vertex_type":0,"dpid":3,"new_name":"sX"}' \
       http://localhost:8000/ndt/modify_device_name
  cd ~/Desktop/NDTwin-Kernel && git status --short setting/
  ```
* **Observed (`~/logs/api-oftable-purge.log`):**
  ```
  3811:      "device_name": "sX",
    git status of the setting dir:
   M setting/StaticNetworkTopologyMininet_10Switches.json
  ```
* **Expected:** the doc does say it writes the JSON, so the write itself is documented. What is
  not said anywhere is that the file it writes is **the tracked file in the repository you just
  cloned** — so an ordinary API call (one the Web GUI exposes as a rename box) leaves your
  working tree dirty and will conflict on the next `git pull`.
* **Reproduced?** Single occurrence, but the file diff is the evidence and it persists.
* **Severity: low.** The Installation Manual takes care to warn about exactly this for a much
  smaller case — Step 6.6 says "Editing this file leaves your working tree dirty ... That is
  expected; do not revert it" for `bmv2_binary_override`. The same sentence is missing here,
  where the edit happens without the user touching a file at all.
---
### BUG-09 🔴 (product + doc) - `start_network_state_recorder.sh` exits 0, starts nothing, and still edits your config; the manual describes an interpreter path the script does not contain
* **Feature:** Network State Recorder, "Starting NSR - Option 1: Background Mode (Recommended)"
* **Manual pages:**
  - User Manual > Network State Recorder > 2. Usage Guide > Starting NSR (Option 1)
  - Installation Manual > NDTwin Tool > Network State Recorder > 1. Prerequisites & Setup
* **Steps (verbatim, after the install page's own venv setup):**
  ```
  cd ~/Network-State-Recorder
  chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh
  ./start_network_state_recorder.sh
  pgrep -af network_state_recorder.py
  ```
* **Expected:** the User Manual presents this as the recommended way to run NSR and says
  "It runs NSR in the background using `nohup`", then "To verify if NSR is currently running:
  `pgrep -af network_state_recorder.py`. *If a line with a process ID (PID) is returned, NSR is
  running.*" The Installation Manual adds:
  > "Note the interpreter path (`~/nsr-env/bin/python`, or the Conda equivalent) —
  > `start_network_state_recorder.sh` launches the recorder with an interpreter path written
  > **inside the script**, so open it once and check that path points at the environment you
  > just created."
* **Observed (verbatim, `~/logs/f4-nsr-start-attempt1.log`):**
  ```
  === ... What is actually in the script: ===
  9:nohup python3 network_state_recorder.py &

  === F4 attempt 1: run it exactly as the User Manual says, no environment activated ===
  SCRIPT_EXIT=0
  Traceback (most recent call last):
    File "/home/ndt/Network-State-Recorder/network_state_recorder.py", line 6, in <module>
      from nornir import InitNornir
  ModuleNotFoundError: No module named 'nornir'
  --- did anything start?  (User Manual's own status check) ---
    NOTHING RUNNING
  --- did it create recorded_info/ or logs/ ? ---
  ls: cannot access 'recorded_info/': No such file or directory
  ls: cannot access 'logs/': No such file or directory
  --- did the script still flip display_on_console to false? ---
      display_on_console: false
  ```
* **Three separate problems, in order of how much they cost:**
  1. **There is no interpreter path in the script.** Line 9 is a bare `python3`. The
     Installation Manual tells you to open the file and check a path that does not exist, so
     the one instruction that would have prevented this failure cannot be carried out. A reader
     who does open the file sees `python3`, has no reason to think anything is wrong, and runs it.
  2. **A bare `python3` is exactly the interpreter that cannot work.** The same install page
     says Ubuntu 24.04 forces you to install NSR's dependencies into a venv (PEP 668), so the
     system `python3` is guaranteed not to have `nornir`. The script therefore fails on a
     correctly-followed installation, every time.
  3. **The script exits 0 having started nothing, and has already modified your config.**
     `SCRIPT_EXIT=0`, no `recorded_info/`, no `logs/`, no process — but
     `display_on_console` has been flipped to `false`. So the one place a user would look for
     the error next (the console, in foreground mode) has just been turned off by the failed
     run. The traceback goes to the terminal and there is no `nohup.out`, so in a real
     background use it is easy to miss entirely.
* **Reproduced?** Yes — re-ran it, same result (see BUG-09b note in the coverage table line F4).
* **Workaround I applied (a workaround, not a fix):** activate the venv first, so the bare
  `python3` resolves to the environment's interpreter:
  `source ~/nsr-env/bin/activate && ./start_network_state_recorder.sh`.
  Neither manual page mentions doing this.
* **Severity: high for a first-time user.** The recommended start path for a shipped tool
  fails silently on a machine set up exactly as the installation manual prescribes, and the
  manual's own status check ("if a line with a PID is returned") is the only thing that reveals
  it.

---
### BUG-10 (product) - the shipped `stop_network_state_recorder.sh` contains the exact command its own User Manual tells you never to write
* **Feature:** Network State Recorder, "Stopping NSR - Option 1: Using the Stop Script"
* **Manual page:** User Manual > Network State Recorder > Stopping NSR
* **Expected (verbatim, from the same page, about Option 2):**
  > "**Do not pipe the search straight into `kill`.** Writing
  > `sudo kill -15 $(pgrep -f network_state_recorder.py)` looks shorter, but it fails in three
  > ways and all three are silent: ... With **no match**, the command substitution is empty and
  > the line becomes `sudo kill -15` with no argument. With **several matches** it signals *all*
  > of them — including the editor, `tail` or wrapper shell that only happened to have the
  > filename on its command line. It is run under `sudo`, so a wrong match is terminated with
  > full privileges."
* **Observed** — `cat stop_network_state_recorder.sh` (`/tmp/.../nsr.txt`, captured verbatim):
  ```
  #!/bin/bash
  echo $(pgrep -f network_state_recorder.py)
  sudo kill -15 $(pgrep -f network_state_recorder.py)
  ```
  That is character-for-character the line the manual says not to write, in the script the same
  manual recommends as **Option 1** for stopping the tool.
* **Reproduced?** It is the shipped file; re-reading it gives the same content.
* **Severity: medium.** The manual's warning is good and specific; the tool does not follow it.
  A user who stops NSR the recommended way gets all three failure modes the manual describes,
  under `sudo`, and the manual's careful advice only protects the users who chose Option 2.
---
### BUG-11 (product) - `stop_network_state_recorder.sh` exits 0 when it has not stopped anything, and flips the config either way
* **Feature:** Network State Recorder, "Stopping NSR - Option 1: Using the Stop Script"
* **Manual page:** User Manual > Network State Recorder > Stopping NSR; and §4 Troubleshooting
  ("Cannot Stop NSR | Permission restrictions | Use `sudo ./stop_network_state_recorder.sh`")
* **Steps:**
  ```
  cd ~/Network-State-Recorder
  ./stop_network_state_recorder.sh          # as an ordinary user, as the manual shows first
  echo "STOP_EXIT=$?"
  pgrep -af network_state_recorder.py
  grep display_on_console setting/recorder_setting.yaml
  ```
* **Expected:** the manual presents this as Option 1 for stopping the tool, and separately notes
  "*this script will change the value of `display_on_console` in config file to `true`*" — i.e.
  the config change is a consequence of having stopped it.
* **Observed (verbatim, `~/logs/f9-nsr-stop.log`):**
  ```
  === F9: stop with the shipped stop script ===
      display_on_console: false
  144093
  sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
  sudo: a password is required
  STOP_EXIT=0
  --- still running? ---
  144093 python3 network_state_recorder.py
  --- did it flip display_on_console back to true? ---
      display_on_console: true
  ```
  So: the recorder is **still running**, the script reported **exit 0**, and it has already
  rewritten the config as though the stop had happened. The exit status is meaningless because
  the last statement in the script is the `sed`, not the `kill` — so it reports on the config
  edit, never on whether anything was stopped.
* **Is the remedy in the manual enough?** Partly. The documented remedy does work — I ran
  `sudo ./stop_network_state_recorder.sh` and NSR shut down gracefully
  (`~/logs/f9-f10-nsr-stop-sudo.log`, and the tool's own log `logs/NSR_2026-09-03.log`):
  ```
  2026-09-03 11:08:16 | INFO : Zipping Stopped.
  2026-09-03 11:08:18 | INFO : NSR stopped.
  ```
  **Correction to my own first reading:** immediately after the sudo run I checked at +5 s and
  saw the pid still alive and concluded it had failed. It had not — the graceful shutdown
  (flush + zip) takes about six seconds. `/proc/144093` was gone by 11:09:06. I record the
  mistake because "checked too early" and "did not work" look identical.
* **Reproduced?** The non-sudo exit-0-without-stopping behaviour: yes, and it is structural
  (the script's last statement is the `sed`).
* **Severity: medium.** Nothing is lost, but the two states "NSR stopped" and "NSR still
  running, config now says otherwise" are indistinguishable from the script's output and exit
  code. The config flip is the worse half: `display_on_console` is now `true` while a running
  recorder is still logging to file only, so the next person to read the config is told
  something false about the process that is running.

---
### BUG-12 (doc, cosmetic) - the NSR JSON structure examples are not valid JSON
* **Feature:** Network State Recorder output format
* **Manual page:** User Manual > Network State Recorder > 3. Output Data & Logs > JSON Structure
* **Expected (verbatim):**
  ```
  {"timestamp": 1704067200000, "flowinfo":{[...]}}
  {"timestamp": 1704067200000, "edges":{[...]}, "nodes":[{...}]}
  ```
  `{[...]}` is not valid JSON in either place.
* **Observed (verbatim, `~/logs/f9-nsr-stop.log` and `~/logs/f4-f8-nsr-working.log`):**
  ```
  {"timestamp":1788433636300,"flowinfo":[{"dst_ip":1073741834,"dst_port":37224,...
  {"timestamp":1788433271307,"edges":[{"admin_disabled":false,"dst_dpid":5,...
  ```
  Both are plain arrays: `"flowinfo":[...]`, `"edges":[...]`.
* **Severity: very low**, but it is the field a consumer writes a parser against, and the doc's
  notation would not tell you whether to expect an object or an array. Everything else on that
  page was exactly right: the file naming (`2026_09_03_11-01-11_flowinfo.json`,
  `..._flowinfo_json.zip`), the log name (`logs/NSR_2026-09-03.log`), and the newline-delimited
  record framing all matched.
---
### BUG-13 (product) - the combined flow endpoint answers `200 ... "status":"queued"` to a body whose top-level keys it does not recognise
* **Feature:** `POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries`
* **Manual page:** Developer Manual > NDTwin Kernel API §23
* **What I did wrong first, honestly:** I guessed the top-level keys as `install` / `modify` /
  `delete`. The documented names are `install_flow_entries` / `modify_flow_entries` /
  `delete_flow_entries`. **The endpoint works correctly with the documented names** - I re-ran
  it and the rule landed on s2 and was then deleted, both verified with `ovs-ofctl`
  (`~/logs/api-d23-d30.log`).
* **The finding is what happened with the wrong names** (`~/logs/api-combined-group-meter.log`):
  ```
  ===== D23 combined (install one rule on s2) =====
  HTTP 200
  {"accepted":0,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}
  -- read back from s2 --
    NOT ON SWITCH
  ```
* **Expected:** neighbouring endpoints in the same API reject unusable bodies loudly and
  helpfully - `received_a_simulation_case` answers
  `400 {"details":"missing required field(s): simulator, version, app_id, case_id, inputfile"}`
  and `inform_all_destination_paths` answers `400` naming the missing key. This one does not.
* **Observed:** `200`, the word `"queued"`, and `"accepted":0` - which is the only signal that
  anything was wrong, and it is a number a caller has to know to look at. The `detail` string
  actively points the reader away from the response ("per-entry outcomes are reported in the
  kernel log"), which is reasonable for genuine per-entry failures but here there were no
  entries at all.
* **Reproduced?** Yes - both the install-shaped and delete-shaped wrong-key bodies returned
  `accepted:0` with `200`.
* **Severity: medium.** A typo in a top-level key is silent: the caller gets a success status
  and a plausible-sounding "queued", and nothing reaches any switch. `"accepted":0` alongside a
  non-empty request is enough information to return a 400, so the endpoint knows.

---
### BUG-14 (product, low) - `app_register` creates an NFS export folder on a machine with no NFS, and only says so at kernel shutdown
* **Feature:** `POST /ndt/app_register`
* **Manual page:** Developer Manual > NDTwin Kernel API §16 ("Creates a dedicated folder for the
  application in the NFS export directory (e.g., /srv/nfs/sim/<app_id>)")
* **Steps:** with the kernel running and **no** `nfs-kernel-server` installed (I had not done the
  Simulation Platform section of the installation manual):
  ```
  curl -X POST -H 'Content-Type: application/json' \
       -d '{"app_name":"MyApp","simulation_completed_url":"http://127.0.0.1:9000/simulation_completed"}' \
       http://localhost:8000/ndt/app_register     # -> 200 {"app_id":1,...}
  ls -la /srv/nfs/sim/                            # -> drwxrwxrwx 2 root root 4096 Sep 3 10:51 1
  ```
* **Observed at kernel shutdown** (`~/logs/b17-kernel-shutdown.txt`, verbatim):
  ```
  [info] [ApplicationManager.cpp:266 cleanupNFS] Cleaning up registered NFS folders in /srv/nfs/sim
  sudo: exportfs: command not found
  [warning] [ApplicationManager.cpp:312 cleanupAppFolder] 'sudo exportfs -u /srv/nfs/sim/1' failed (exit status 1). The export may still be live.
  [warning] [ApplicationManager.cpp:345 cleanupAppFolder] Deleted NFS folder /srv/nfs/sim/1 but its export configuration was not fully removed.
  sudo: exportfs: command not found
  [warning] [ApplicationManager.cpp:281 cleanupNFS] 'sudo exportfs -ra' failed after cleanup (exit status 1). Stale exports may still be live.
  ```
* **Expected:** nothing in the API page says NFS must exist before `app_register` is usable, and
  the call returns a clean `200` with an `app_id`. The registration is presented as the normal
  first thing an application does (§16, and the architecture page says "Each NDTwin application
  process should register with this module to get its unique run-time ID").
* **Assessment:** the shutdown warnings are honest and well worded - they say exactly what did
  and did not happen. The gap is that the **success path** never checks: `app_register` happily
  reports success and creates a world-writable directory under `/srv/nfs/` on a machine with no
  NFS server, and the only mention of a problem arrives when the kernel exits, in a log the user
  is about to close.
* **Reproduced?** Single occurrence (one registration, one shutdown), but the shutdown log is
  unambiguous and `/srv/nfs/sim/1` existed.
* **Severity: low.** Nothing broke. Worth a sentence in §16 saying the Simulation Platform's
  NFS setup (Installation Manual > NDTwin Tool > Simulation Platform §3) is a prerequisite.
---
### BUG-15 (doc) - `get_detected_top_k_flow_data` silently caps at K=50 and there is no documented way to set K
* **Feature:** `GET /ndt/get_detected_top_k_flow_data`
* **Manual page:** Developer Manual > NDTwin Kernel API §30. The Web GUI page separately
  describes a K box: "Enter the desired **K value** (e.g., 50)."
* **Expected:** §30's Request section is one line - "* Method: **GET**" - with no query
  parameters at all, and the description never states a default K. A developer reading only
  that page has no way to know what K is, or how the Web GUI sets it.
* **Observed (verbatim, `~/logs/f16-ntg-flow-live.log`), while NTG generated a burst:**
  ```
    t+3s : flow_data=173  top_k=50  avg_link_usage=0.08157330780000001
    t+6s : flow_data=206  top_k=50  avg_link_usage=0.01853196542
    t+9s : flow_data=206  top_k=50  avg_link_usage=0.01677507483
    t+12s : flow_data=206  top_k=50  avg_link_usage=0.014156675366666663
    t+15s : flow_data=213  top_k=50  avg_link_usage=0.010310383341666668
    t+18s : flow_data=44  top_k=44  avg_link_usage=0.0013147112
    t+21s : flow_data=28  top_k=28  avg_link_usage=0.0
    t+30s : flow_data=14  top_k=14  avg_link_usage=0.0
  ```
  The endpoint returns **exactly 50** whenever more than 50 flows exist, and tracks
  `get_detected_flow_data` exactly below that. So K is 50, hard-wired as far as the API surface
  shows. Neither `?k=1` nor `?top_k=1` changes it (`~/logs/api-combined-group-meter.log`).
* **Reproduced?** Yes - four consecutive samples at 50 while the true count was 173-213.
* **Severity: low-medium.** The sorting behaviour §30 documents is correct (I verified
  descending order by `estimated_packet_rate_in_the_proceeding_1sec_timeslot`). But an
  application author cannot tell from the documentation that this endpoint truncates, nor at
  what point. On this fabric a single NTG run put the flow count four times over the cap, so
  "top-K" quietly became "the 50 biggest" with nothing in the response saying so.
---
### BUG-16 (doc) - the Installation Manual prints NTG's config files with contents the repository does not ship
* **Feature:** NTG configuration
* **Manual page:** Installation Manual > NDTwin Tool > Network Traffic Generator >
  "Network Traffic Generator Configuration"
* **Expected:** the page prints `NTG.yaml` as
  ```
  inventory:
    plugin: SimpleInventory
    options:
      host_file: "./setting/Mininet.yaml"
  ```
  and `setting/Mininet.yaml` as
  ```
  Mininet_Testbed:
    hostname: "mininet_testbed"
    data:
      ndtwin_kernel: "http://127.0.0.1:8000"
      mode: "cli"
  ```
* **Observed after `git clone` (`/tmp/.../ntg.txt`, `~/logs/f19-ntg-prep.log`):**
  ```
  === NTG.yaml ===
      host_file: "./setting/Hardware.yaml"
  === setting/Mininet.yaml ===
  Mininet_Testbed:
    data:
      ndtwin_kernel: "http://127.0.0.1:8000"
      mode: "custom_command"
  ```
  Three differences: `host_file` points at `Hardware.yaml`, `mode` is `custom_command` not
  `cli`, and there is **no `hostname:` key at all** in the shipped file.
* **Mitigating:** the page's own Notes line does say "If you want to use `Mininet`, please
  change the path of `host_file` to `./setting/Mininet.yaml`", and the User Manual's
  pre-requisites repeat it. So the *instruction* is right; it is the *printed file content*
  that does not match what you get, which is confusing because the page reads as "here is what
  this file contains".
* **Reproduced?** Static file contents; re-read after cloning, same.
* **Severity: low.** I made the documented edit and NTG worked. But the same page has already
  been burned once by printing a copy of a file that drifted (Step 2.6 and Section 5 of the
  Kernel manual both stopped printing source for exactly this reason), and this is the same
  shape of problem in a different manual.

---
### BUG-17 (doc) - three pages describe the mixed OVS+BMv2 refusal three different ways, and only the weakest one is true
* **Feature:** mixed data-plane topology handling
* **Manual pages:**
  - `architecture.md` > The P4 proxy agent: "**A topology may not mix the two.** ... The kernel
    **refuses to load** a mixed topology unless it is explicitly built to allow one."
  - Installation Manual Section 6 intro: "A topology mixing OVS and BMv2 switches is **not
    supported** ... The kernel **logs an error naming the mixture when it loads** such a
    topology, so check your startup log if results look wrong."
  - Installation Step 6.4 code comment: "setting it true **only suppresses the startup error**,
    it does not make the mixture work."
* **Steps:** I built my own mixed model in `/tmp` (I did not modify anything in the repository)
  by copying `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` and changing one switch's
  `brand_name` from `BMv2` to `OVS`, then:
  ```
  sudo ./bin/ndtwin_kernel --mode mininet --topology /tmp/MixedTopology.json --no-ai --loglevel info
  ```
* **Observed (verbatim, `~/logs/e14-mixed.txt` unwrapped):**
  ```
  validateDataPlaneHomogeneity] Topology mixes data planes (ovs=[1]; bmv2=[2,3,4,5,6,7,8,9,10]).
  A single run must be all-OVS or all-BMv2: the flow dispatch is per-DPID and would cope, but the
  telemetry and liveness paths assume one kind. Fix the topology file, or set
  AppConfig::ALLOW_MIXED_DATAPLANE to override.
  ```
  **The message is excellent** - it names the mixture, lists both DPID sets, explains why, and
  says how to override. But the kernel then **carried on and served the API from the mixed
  model**:
  ```
  === did it keep running or refuse? ===
  LISTEN 0      4096         0.0.0.0:8000       0.0.0.0:*
    :8000 open -- it did NOT refuse
  === is the kernel actually answering the API with the mixed model loaded? ===
   nodes 14 edges 40
   switch brands: ['BMv2', 'OVS']
   switches up: 0
  ```
* **So which page is right?** Step 6.4's comment is exactly right, Section 6's "logs an error
  ... when it loads such a topology" is right, and **`architecture.md`'s "refuses to load" is
  wrong** - it loads it and answers queries from it.
* **Reproduced?** Single run, but the evidence is unambiguous: the log line and a live `:8000`
  serving a 14-node mixed graph at the same time.
* **Severity: low-medium.** Nothing crashed and the log message is one of the best in the
  product. The risk is entirely in the architecture page: a reader who believes there is a hard
  refusal has no reason to check the startup log, which is precisely what Section 6 tells them
  to do. Two of the three pages assume the reader will look; the third tells them they do not
  need to.
