# BUGS.md — run-04

Format per entry: feature · manual page/section · exact steps · expected (quoted) ·
observed (verbatim, trimmed) · reproduced on 2nd try? · severity guess.


## BUG-1: `ndt up ovs` never starts a topology -- reproduces the manual's own documented G-7 limitation
- **Feature:** `ndt up ovs` (the "short way" one-shot launcher for Ryu+OVS+kernel)
- **Manual page/section:** User Manual > NDTwin Kernel > Operate an Emulated (Software)
  Network > Native-Linux Execution Environment > "The short way: `ndt up`" -- the manual's own
  "Known limitation" red box on this exact page predicts this failure before I ever ran the
  command, and names it "G-7".
- **Exact steps (verbatim):**
  ```
  cd ~/Desktop/NDTwin-Kernel
  mkdir -p ~/.local/bin
  ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
  sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
  echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab" | sudo tee /etc/sudoers.d/ndtwin-lab
  bash -l -c "ndt up ovs"     # bash -l because a non-login shell does not see ~/.local/bin -- see BUG-2
  ```
- **Expected (quoted from the manual):** "`ndt up ovs` | Ryu + Open vSwitch fabric + kernel,
  converged and verified". The known-limitation box separately says: "the topology it starts
  dies immediately (`No such file or directory`, exit 127, inside a root `tmux` session you
  never see) and `ndt up` waits out its timeout before reporting `XX fabric has 0 hosts,
  expected 128`."
- **Observed (verbatim, trimmed):** Phase 1/4 (Ryu) came up fine (`ok  Ryu up, prompt
  reached`). Phase 2/4 ("data plane (OVS fabric)") then sat for 5m08s
  (16:00:09 -> 16:05:17 by the VM clock) before printing:
  ```
  [2/4] data plane (OVS fabric)
    XX  fabric has 0 hosts, expected 128
  NDT_UP_OVS_EXIT=1
  ```
  While it was stuck I checked underneath it directly: `ps auxf` on the VM showed Ryu running,
  but **no** `testbed_topo.py`/mininet/OVS-building process anywhere, and no root-owned tmux
  session at all (`sudo tmux ls` -> "no server running"). `sudo ovs-vsctl show` printed only
  the version line the whole time -- zero bridges were ever created. I then read (not edited)
  `/usr/local/sbin/ndtwin-lab`, the exact file the manual's own box names, and confirmed the
  hardcoded paths it warns about are real and unconditional:
  ```
  KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
  NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
  ENERGY_DIR=/home/adam/Energy-Saving-App
  SIM_DIR=/home/adam/Simulation-Platform-Manager
  ...
  $TMUX new-session -d -s topo -c /home/adam/Network-Traffic-Generator \
      "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py
  ```
  This machine's user is `ndt`, not `adam`, so `/home/adam/...` names nothing here -- exactly
  the condition the manual's box describes ("On any machine where those paths do not exist").
- **Reproduced on a second try?** Not re-run a second time on purpose: this is a hardcoded
  absolute path compared against `$USER`, not a timing- or load-sensitive condition, so a
  second identical run has no mechanism to behave differently, and the manual already
  independently diagnoses the same root cause I found by reading the one file it named. Ran
  `ndt down` afterward instead (see below) and confirmed the fallback path (the manual
  3-terminal procedure) *does* converge on this same machine, which is the more useful second
  data point.
- **Severity (my guess):** Low-to-medium as a bug in NDTwin itself -- it is already known,
  already named (G-7), and the manual gives a working documented fallback ("use the
  three-terminal procedure below, which does not go through `ndtwin-lab` at all") that I
  confirmed works (see the Section B checklist entries). Medium as a *documentation* matter
  only in the sense that a first-time reader who trusts "the short way" heading and skips the
  red box below it (easy to do -- it is the very first code block on the page) burns 5+
  minutes on a launcher whose failure message ("fabric has 0 hosts, expected 128") does not
  itself point at the cause; the manual's own diagnosis is what makes this findable at all.
- **Side effect noted while cleaning up:** `bash -l -c "ndt down"` worked correctly and
  reported a fully clean state (`ok bmv2 switches: 0`, `ok host/switch processes: 0`, `ok no
  topo session`, `ok no switch manifest`, `ok ports 8000/8080/8081 closed`) despite the
  fabric-side half never having started -- so `ndt down` / `ndt status` are trustworthy even
  after this particular failure mode, which matters because they are the tools I used to
  confirm the machine was clean before falling back to the 3-terminal procedure.

## Friction: `~/.local/bin` not on PATH for any of my non-interactive sessions
- **Feature:** `ndt` launcher installation, PATH setup
- **Manual page/section:** same page, same "The short way" section, its own callout box.
- **Exact steps:** `mkdir -p ~/.local/bin && ln -sf .../ndt ~/.local/bin/ndt`, then in a fresh
  `ssh host 'ndt --help'` (no `-l`, no `-i`).
- **Expected (quoted):** "Open a new login shell before calling `ndt`. ... Log out and back
  in, or start one with `bash -l`."
- **Observed:** `ssh ... 'echo $PATH'` right after installing showed `~/.local/bin` absent
  and `ndt: command not found`; `ssh ... 'bash -l -c "echo \$PATH; which ndt"'` showed it
  present and resolved. The manual's own suggested fix (`bash -l`) works exactly as written.
  Not filing this as a defect -- the manual anticipates it and gives a working fix -- recording
  it because every `ndt` invocation for the rest of this test run needed the `bash -l -c "..."`
  wrapper, which is friction a plain `ssh user@host 'ndt status'` one-liner does not survive
  without that reminder.
- **Reproduced:** yes, every single non-`-l` ssh invocation of `ndt` failed the same way;
  every `-l` one succeeded.
- **Severity:** Cosmetic/environmental -- documented, with a working fix.

## BUG-2: `testbed_topo.py`'s own built-in connectivity self-test reports 100% packet loss on pairs that work fine moments later, and its final banner ignores the failure entirely
- **Feature:** Terminal 2 (Mininet topology), `testbed_topo.py`'s internal self-test that runs
  automatically between "Adding links" and the `mininet>` prompt -- not something I invoked,
  it runs unattended as part of bringing the topology up.
- **Manual page/section:** User Manual > NDTwin Kernel > Operate an Emulated (Software)
  Network > Native-Linux Execution Environment > "Terminal 2: Mininet Topology". The manual
  documents waiting for the *Ryu* controller to print "all-destination paths installed" and
  gives an OVS-flow-count recipe to confirm that independently -- it says nothing about this
  script running its own ping self-test before the CLI appears, so this behaviour and its
  banner are both undocumented.
- **Exact steps (verbatim), run twice independently:**
  ```
  # Terminal 1
  conda activate ryu-env
  export NDTWIN_RYU_TOPO_FILE=~/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json
  ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link
  # Terminal 2, after Ryu is up
  cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py
  ```
- **Expected:** nothing in the manual predicts a failure here; by extension, a script that
  performs its own connectivity check and then prints "Final Configuration Active" /
  "Host internet: OK | sFlow reachability: OK | Switch identification: OK" is implicitly
  claiming the network it just verified is up, matching the spirit of the manual's own emphasis
  on checking real effects rather than trusting a success message.
- **Observed (verbatim, trimmed), run 1 (16:00-16:09):** the script printed 128 `Pinging from
  hN to 10.0.0.M...` announcements, then 128 `Result from ... :` blocks -- **all 128 of them
  `1 packets transmitted, 0 received, 100% packet loss`** (`grep -c "100% packet loss"` = 128,
  `grep -c "0% packet loss"` = 0, out of 128 `Result from` lines total). This was at a point
  where `sudo ovs-ofctl dump-flows sN | grep -c actions=` already read **130 on all ten
  switches** -- the manual's own documented "converged" figure -- so the flow tables were not
  empty when the self-test ran.
  Run 2 (16:11-16:13, fresh Ryu + fresh topology, see note on methodology below): identical
  result, 128/128 pings in the self-test at **100% packet loss**, again with flow tables
  already at 130/switch beforehand (checked directly with `ovs-ofctl dump-flows` seconds before
  the self-test's results appeared). Both runs ended with the same banner regardless:
  ```
  --- Final Configuration Active ---
  Host internet: OK | sFlow reachability: OK | Switch identification: OK
  ```
  Immediately after reaching the `mininet>` prompt in run 2, I typed the *exact* failing pair
  from the self-test by hand:
  ```
  mininet> h1 ping -c 3 10.0.0.65
  PING 10.0.0.65 (10.0.0.65) 56(84) bytes of data.
  64 bytes from 10.0.0.65: icmp_seq=1 ttl=64 time=0.696 ms
  64 bytes from 10.0.0.65: icmp_seq=2 ttl=64 time=0.058 ms
  64 bytes from 10.0.0.65: icmp_seq=3 ttl=64 time=0.045 ms
  --- 10.0.0.65 ping statistics ---
  3 packets transmitted, 3 received, 0% packet loss, time 2033ms
  ```
  0% packet loss, seconds after the self-test logged that same destination as 100% loss. A
  same-switch pair (`h1 ping -c 3 h2`) also passed cleanly (0% loss). So the fabric the
  self-test was reporting as unreachable was, in fact, fully reachable by the time (and almost
  certainly already was reachable when) the self-test ran.
- **Reproduced on a second try?** Yes -- the 128/128 self-test failure reproduced identically
  across two independent full stack restarts (fresh `ryu-manager`, fresh `testbed_topo.py`).
  The "actually works when tested by hand" half was checked once in run 2, on both a near pair
  and the exact far pair the self-test flagged; I did not feel a need to re-run that half a
  third time since both pairs it was asked to explain (near and far) passed cleanly.
- **My methodology note, not a bug:** run 1's Mininet CLI later crashed
  (`OSError: [Errno 5] Input/output error` inside `cmd.cmdloop()` -> `input()`) a few seconds
  after reaching `mininet>`, tearing the whole fabric down. I do not believe this is an NDTwin
  defect: I had launched Terminal 2 as `sudo python3 testbed_topo.py 2>&1 | tee ~/logs/...log`
  to capture a log, and run 2 (identical otherwise, launched *without* the `| tee`, logged via
  `tmux capture-pane` instead as my own instructions actually specify) reached and stayed at
  `mininet>` without incident. Recorded here only so the CLI crash is not mistaken for part of
  this bug -- BUG-2 is specifically about the self-test's false-failure report and its banner,
  both of which reproduced independently of the tee/no-tee difference.
- **Severity (my guess):** Medium. The actual data plane is fine on the evidence above, so this
  is not "the network is broken" -- it is "the project's own built-in health check cannot be
  trusted, and its summary line asserts health regardless of what the check underneath it just
  found." That is precisely the failure mode this test run was briefed to watch for (a
  success-looking message that is not evidence of anything), and it is bad specifically because
  a reader who *does* look at the pings (rather than only the final "OK" line) would reasonably
  conclude the network is broken and go looking for a problem that, on this machine, does not
  exist -- likely costing exactly the kind of debugging time the manual's other install-time
  warnings are otherwise careful to save.

## BUG-3: an `ndtwin_kernel` process I never started was already running, invisible to `ndt down`'s "verify clean", and blocked my own Terminal-3 launch
- **Feature:** Terminal 3 (NDTwin Kernel) startup; also `ndt down`'s "verify clean" claim.
- **Manual page/section:** User Manual > Native-Linux Execution Environment > "Terminal 3:
  NDTwin Kernel", and the "Short way" page's `ndt down` description ("take it all down and
  prove the machine is clean").
- **Exact steps:** after BUG-1 (`ndt up ovs` failed, 16:00-16:05) and a clean `bash -l -c "ndt
  down"` (16:05:54, reported `ok bmv2 switches: 0`, `ok host/switch processes: 0`, `ok no topo
  session`, `ok no switch manifest`, `ok ports 8000/8080/8081 closed`), I started the manual
  3-terminal procedure fresh: Terminal 1 (`ryu-manager ...`, 16:07:21 and again 16:11:37 after
  an `mn -c`), Terminal 2 (`sudo python3 testbed_topo.py`, 16:08:19 then 16:11:51). At 16:15:08
  I ran my own **first-ever** Terminal 3 in this session:
  ```
  cd ~/Desktop/NDTwin-Kernel/build
  sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info
  ```
- **Expected (quoted):** the manual gives no indication anything but my own three terminals,
  started by me, would be running the kernel.
- **Observed (verbatim, trimmed):** my own kernel refused to start:
  ```
  [error] [FlowLinkUsageCollector.cpp:690] bind() to sFlow port 6343 failed: Address already
  in use. Another NDTwin kernel is almost certainly still running and holding it; without
  telemetry this twin would report every flow rate as zero, so it will not start.
  [critical] [main.cpp:406] cannot start telemetry collection: Failed to bind UDP socket. Exiting
  ```
  (the kernel's own error message is honest and specific here -- credit where due.) I went
  looking for what actually held the port:
  ```
  $ sudo ss -ulnp | grep 6343
  UNCONN 0 0 0.0.0.0:6343 0.0.0.0:* users:(("ndtwin_kernel",pid=59174,fd=3))
  $ ps -o pid,lstart,cmd -p 59174
    PID                  STARTED CMD
   59174 Wed Sep  2 16:08:38 2026 ./bin/ndtwin_kernel --mode mininet --topology
   /home/ndt/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json --no-ai
  ```
  `bash -l -c "ndt status"` at that point described this process's world as a normal, healthy,
  converged run -- `:8000 kernel open`, `switches 10 up, 10 enabled`, `links 288 total, 0
  down`, `kernel graph 10 switches (10 up, 10 enabled), 128 hosts, 288 edges` -- with **nothing
  in the output distinguishing "a run you started" from "a run nobody currently owns."**
  `lab > claim` still correctly read `none`, so the *ownership* bookkeeping and the *process*
  bookkeeping disagree with each other.
  I cannot pin down with certainty which of my own actions produced PID 59174 -- I never
  typed a command to start a kernel before 16:15:08 -- but the timing narrows it to one of two
  candidates, both concerning in their own way: **(a)** a detached child of the *failed*
  `ndt up ovs` run (16:00:09-16:05:17) that kept polling for a fabric on its own after the
  parent script had already reported failure and exited, and fired once my manual Terminal
  1+2 produced a real one around 16:08; or **(b)** `testbed_topo.py` (Terminal 2) itself
  starting a kernel as a side effect once its own setup finishes -- 59174's start time
  (16:08:38) sits right at the point my *first* `testbed_topo.py` run (16:08:19, the one that
  later crashed per my methodology note under BUG-2) would have been finishing its self-test
  and reaching "Final Configuration Active." I have deliberately not opened either script to
  settle this, per this test's own ground rules -- recording both candidates rather than
  guessing.
  Killing the one PID I had confirmed (`sudo kill -TERM 59174`, not a pattern-matched kill)
  ended it in under 3 seconds and released both `:6343` and `:8000` cleanly; my own Terminal 3
  then started normally.
- **Reproduced on a second try?** Not deliberately re-run a third time from scratch (that would
  mean redoing the ~15-minute BUG-1/BUG-2 sequence that originally produced it, for a process
  whose exact trigger I already can't isolate without the source-reading this test avoids) --
  but the process's *existence* was independently confirmed by two different tools agreeing
  with each other (`ss -ulnp` and `ps`), and its *effect* (blocking a legitimate Terminal 3)
  reproduced exactly once and was directly observed, not inferred.
- **Severity (my guess):** Medium-high. However it started, the practical failure mode is bad:
  `ndt down` reported a fully clean machine while a kernel process it did not know about kept
  running for at least 9 minutes (16:08:38 until I killed it at 16:18:44), `ndt status`
  described that process's state as an ordinary healthy run with no ownership attached, and the
  first symptom a user gets is an unrelated-looking bind failure on a port (`6343`, sFlow) that
  neither `ndt down`'s three checked ports (`8000`/`8080`/`8081`) nor its process-count check
  cover. A user who trusts "clean" after `ndt down` and then starts their own Terminal 3 by
  hand, as the manual instructs, hits exactly what I hit.

## Addendum to BUG-1: the hardcoded `/home/adam` assumption is not limited to `ndt up`
- **Feature:** `ndt apps nsr`, `ndt ntg`
- **Manual page/section:** same User Manual page, "The rest of the interface" table.
- **Exact steps:**
  ```
  bash -l -c "ndt apps nsr"     # after `git clone .../Network-State-Recorder` into ~ per its
                                 # own Installation Manual page, then symlinked to
                                 # ~/Desktop/Network-State-Recorder once the first attempt named
                                 # that exact path
  bash -l -c "ndt ntg"
  ```
- **Expected:** the manual's table just says these start the NSR reader / hand control to
  NTG's prompt; nothing suggests either depends on paths outside what their own Installation
  Manual pages tell you to create.
- **Observed (verbatim):**
  ```
  $ ndt apps nsr
    XX  NSR not found at /home/ndt/Desktop/Network-State-Recorder
  ```
  -- correctly non-zero exit (1, verified directly, not through a pipe). After symlinking
  `~/Network-State-Recorder` (where its own Installation Manual page's `cd ~ && git clone ...`
  actually puts it) to the path above:
  ```
    XX  nsr exited immediately -- see .test_run/logs/app_nsr.log
    nohup: failed to run command '/home/ndt/miniconda3/envs/ntg-env/bin/python': No such file
    or directory
  ```
  So `ndt apps nsr` wants a **conda** environment at `~/miniconda3/envs/ntg-env`, but NTG's own
  Installation Manual page (which I followed literally) builds a plain **venv** at `~/ntg-env`
  with `python3 -m venv --system-site-packages ~/ntg-env` -- conda is never mentioned on that
  page at all. Separately:
  ```
  $ ndt ntg
    XX  not found: /home/adam/Network-Traffic-Generator/setting/Mininet.yaml
  ```
  the same `/home/adam` (not this machine's `/home/ndt`) assumption BUG-1 already found in
  `ndtwin-lab`, this time surfacing directly from `ndt` itself rather than through the root
  helper.
- **Reproduced:** each shown once; not repeated a second time for the same reason as BUG-1's
  root cause (a hardcoded string compared against this machine's actual paths -- deterministic,
  not timing-sensitive).
- **Severity (my guess):** Low-medium, same family as BUG-1 -- both are honestly and clearly
  reported (`XX ...`, non-zero exit, no silent success), so a reader is not misled, just
  blocked. I did not chase a fix: the manual gives no path-override instructions for `ndt
  apps`/`ndt ntg`, and inventing a `~/miniconda3/envs/ntg-env` conda environment purely to
  satisfy an undocumented internal expectation would be exactly the kind of unsupported
  workaround this test is supposed to flag rather than quietly perform.

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

## Minor doc slip: Web GUI's Docker-install block chmods a file it never creates
- **Feature:** Web GUI installation, Step 2 ("Install Docker")
- **Manual page/section:** Installation Manual > NDTwin Tool > Web GUI > "Add Docker official
  GPG key".
- **Exact steps (verbatim):**
  ```
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  ```
- **Expected:** all three lines succeed; the `.asc` file the third line names implies the
  second line was supposed to produce it.
- **Observed:** the second line writes `docker.gpg` (the name every later step in the same
  page actually references, e.g. `signed-by=/etc/apt/keyrings/docker.gpg`), so
  `chmod a+r .../docker.asc` fails: `chmod: cannot access '/etc/apt/keyrings/docker.asc': No
  such file or directory` (exit 1). Harmless here only because `gpg --dearmor -o` already
  wrote `docker.gpg` as `644 root:root` (world-readable) by default -- confirmed with `stat`
  before and after the failed chmod, no change either way -- so apt could read the keyring
  regardless and the rest of the install (`docker --version` -> `Docker version 29.7.2`;
  `docker compose version` -> `Docker Compose version v5.5.0`) succeeded. On a system where
  the default `umask` made the dearmored key non-world-readable, this typo would not be
  harmless.
- **Also noticed in the same section:** `sudo groupadd docker`, run (per the manual's own
  order) *after* `apt install docker-ce ...`, always reports `groupadd: group 'docker'
  already exists` on a stock Ubuntu 24.04 install, because the `docker-ce` package itself
  creates that group during its postinst. Not a failure that blocks anything (the following
  `usermod -aG docker $USER` still succeeds), just a step that -- in this order -- can never
  do the thing its own name says.
- **Severity (my guess):** Cosmetic. Neither slip stopped the install; recording them because
  a reader who *does* check each command's exit status (as this whole test is about doing)
  would see two unexplained non-zero exits in a section that otherwise reads as "just run
  these."

## Update to BUG-4: the `pgrep -f` anti-pattern in `stop_network_state_recorder.sh` actually reproduced, live
Earlier I only inspected this script's source and called out that it uses the exact pattern
the User Manual's own NSR page tells you not to use. I then ran it for real, to stop the NSR
instance started under the documented workaround (`source ~/nsr-env/bin/activate` first):
```
$ pgrep -af network_state_recorder.py
184273 python3 network_state_recorder.py
$ ./stop_network_state_recorder.sh
184273 190740
```
`190740` was **not NSR** -- it was the PID of the very shell that was running my *previous*
command, whose command-line text happened to contain the literal string
`network_state_recorder.py` (because it had `pgrep -af network_state_recorder.py` in its own
`-c` argument). `pgrep -f` doesn't distinguish "the program I mean" from "any process whose
command line mentions the same string," which is precisely what the manual's prose warns
about two sections earlier -- and the shipped script's `sudo kill -15
$(pgrep -f network_state_recorder.py)` signalled both PIDs it found. That earlier command's
own SSH connection terminated immediately (exit code 255) as a direct result. NSR itself
(184273) did also stop -- the script's primary job still happened -- but it took an unrelated
process down as collateral damage, from a completely ordinary way of invoking it (a scripted
shell rather than someone's raw interactive terminal).
This was not a contrived test: it is what "run the stop script" looks like from anything
other than a bare interactive terminal -- a cron job, a CI step, or (as here) any wrapper
shell whose own invocation happens to mention the target script's name.
**Reproduced:** yes, on the one deliberate run -- did not repeat it a second time given what
the first run had just done to my own session; the mechanism (unfiltered `pgrep -f` catching
whatever is running it) is deterministic, not a fluke.
**Revised severity:** Medium, up from the "not yet reproduced" note earlier in this file --
this is no longer a theoretical reading of the source, it is an observed side effect that
reached outside the process NSR itself started.

## BUG-5: Web GUI's own deploy script cannot build the frontend image -- `pnpm` (unpinned) now refuses non-interactive installs
- **Feature:** Web GUI, Step 3 ("Execute Deployment Script")
- **Manual page/section:** Installation Manual > NDTwin Tool > Web GUI > "Starting
  Application Deployment" > Step 3.
- **Exact steps (verbatim):**
  ```
  git clone https://github.com/ndtwin-lab/Web-GUI.git
  cd Web-GUI
  cp .env.example .env
  # edited NDT_API_BASE_URL to http://127.0.0.1:8000, the running kernel from this same test
  sudo chmod +x web_gui_deploy.sh
  ./web_gui_deploy.sh
  ```
- **Expected (quoted):** "After deployment completes, you should see ... Frontend:
  http://localhost:3000 / Database: localhost:5433."
- **Observed (verbatim, trimmed):** the frontend image build fails outright, before any
  container starts:
  ```
  #17 [frontend builder 5/7] RUN pnpm install --frozen-lockfile
  #17 2.412 + vite 6.3.5
  #17 2.425 Error: ERR_PNPM_IGNORED_BUILDS
  #17 2.425   x installing dependencies
  #17 2.425   |-> Ignored build scripts: esbuild@0.25.5
  #17 2.425   help: Run "pnpm approve-builds" to pick which dependencies should be allowed
  #17 2.425         to run scripts.
  #17 ERROR: process "/bin/sh -c pnpm install --frozen-lockfile" did not complete successfully:
  exit code: 1
  target frontend: failed to solve: process "/bin/sh -c pnpm install --frozen-lockfile" did
  not complete successfully: exit code: 1
  Failed to start containers.
  ```
  The frontend Dockerfile installs pnpm with a bare `npm install -g pnpm` (visible a few lines
  earlier in the same build log: `RUN npm install -g pnpm`), which pulled **pnpm v12.3.0** on
  2026-09-02 -- no version is pinned anywhere I can see in the repo's own build steps. Recent
  pnpm refuses to run a dependency's install/build script during a `--frozen-lockfile` install
  unless it has been explicitly approved (normally via the interactive `pnpm approve-builds`),
  and a `docker build` has no interactive session to approve it in, so the install -- and the
  whole deploy script -- fails before a single container comes up. `docker-compose ps` /
  `curl localhost:3000` were therefore not reachable to test (Docker itself works: `docker
  --version` -> 29.7.2, `docker compose version` -> v5.5.0, both confirmed separately).
- **Reproduced on a second try?** Not re-run a second time: the failure is deterministic given
  today's pnpm release and an unpinned install line, not a flaky/timing issue, and re-running
  the identical script would rebuild from the same Dockerfile against the same current pnpm
  release.
- **My own workaround attempted:** none. The manual gives no indication this class of failure
  exists (contrast the Installation Manual's P4/BMv2 section, which explicitly discusses
  upstream version drift and pins a script version for exactly this reason) and I did not
  patch the Dockerfile to pin an older `pnpm` or add an approval flag -- that would be fixing
  the project rather than testing it as shipped.
- **Severity (my guess):** High for this specific tool on a from-scratch install today: the
  documented one-command deploy path (`./web_gui_deploy.sh`) cannot produce a running Web GUI
  at all, and there is no alternative deploy path documented on this page.

## Note: BUG-2's self-test false-failure also reproduces in NTG's own copy of testbed_topo.py
Running NTG's Terminal 2 (`sudo ~/ntg-env/bin/python testbed_topo.py` from the
Network-Traffic-Generator repo -- a different script from NDTwin-Kernel's own testbed_topo.py,
but evidently sharing the same lineage) produced the identical pattern already logged as
BUG-2: 128 pings, all "100% packet loss", followed immediately by "Host internet: OK | sFlow
reachability: OK | Switch identification: OK" and a working CLI/fabric afterward (confirmed
working by the `flow`/`dist` commands both successfully driving real iperf3 traffic and the
kernel independently reporting 29 detected flow records during the `flow --config
flow_template.json` run). Not filing as a fourth separate bug -- same root symptom, different
copy of the same script -- but recording because it shows the false-failure is not particular
to one repository's checkout of the file.

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

## BUG-6: `ndt apps energy` / `ndt apps sim` print "ok ... started" for apps that are already dead
- **Feature:** `ndt apps [names]` -- "start readers/apps: energy sim nsr viz te"
- **Manual page/section:** User Manual > NDTwin Kernel > Native-Linux Execution Environment >
  "The rest of the interface" table: `ndt apps [names] start readers/apps ... No arguments on
  a terminal gives an interactive picker`.
- **Exact steps (verbatim), tried twice under different conditions:**
  ```
  bash -l -c "ndt apps energy"     # attempt 1: no Ryu/Mininet/Kernel running at all
  bash -l -c "ndt apps sim"        # same conditions
  # ... later, with a converged Ryu+Mininet+Kernel OVS fabric fully up (confirmed via
  # ovs-ofctl flow counts and the kernel's own "topology from the control plane" line) ...
  bash -l -c "ndt apps energy"     # attempt 2: dependencies actually satisfied this time
  ```
- **Expected:** "ok ... started" should mean the app is running (that is what "started" means
  anywhere else in this tool's own output -- compare `ndt up`'s per-phase `ok` lines, which
  only appear once a check actually passed).
- **Observed (verbatim):**
  ```
  $ ndt apps energy
    ok  energy started (tmux: energy)
  $ tmux list-sessions | grep energy
  (nothing)
  $ ndt apps sim
    ok  sim started (tmux: sim)
  $ tmux list-sessions | grep sim
  (nothing)
  ```
  Both tmux sessions were already gone by the time I checked -- including on an immediate,
  zero-delay recheck right after the "ok" line printed. `ndt status`'s own `apps` field agreed
  afterward (`apps  none running`), so the tool's own status view is not fooled -- only the
  `ndt apps` command's own success message is. No log file was created anywhere I could find
  (`.test_run/logs/app_energy.log` and `app_sim.log` both do not exist), unlike NSR's own
  failure earlier in this run, which logged a specific, useful error. Repeated the `energy`
  case a second time with a real, converged OVS fabric and kernel already running (the
  dependency I initially assumed was missing) -- identical result: "ok ... started", tmux
  session already gone. This matches what a standalone `sudo ./energy_saving_app` showed
  directly (see the Simulation Platform Manager section of this file): it needs an NFS
  subdirectory that only gets created by a prior successful kernel registration, so it likely
  crashes near-instantly here too -- but that root cause is beside the point of this bug, which
  is that `ndt apps` never checks whether the process it just launched is still alive before
  reporting success.
- **Reproduced on a second try?** Yes, deliberately, under two different starting conditions
  (no stack running; full converged stack running) -- both times "ok" and both times the
  session was already gone.
- **Severity (my guess):** Medium-high. This is the exact failure shape this whole test run
  was briefed to catch: a command that reports success and is not itself evidence anything
  happened. It is worse than BUG-3's silent leftover process in one respect -- there the tool
  under-reported (said nothing about a process that *was* there); here it over-reports (says
  something started that already was not there), which is the more dangerous direction to be
  wrong in for anyone scripting against `ndt apps`'s exit code or message.

## Note: Web GUI's .env names a GitHub token the Installation Manual never mentions
Reading the generated `.env` (from `.env.example`) for unrelated reasons, its last field is
`VITE_GITHUB_TOKEN` ("Required only if using LLM features that need GitHub API access"). The
Installation Manual's Web GUI page never mentions this variable, and the User Manual's
"NDTwin Assistant" feature description (natural-language prompts for congested links, heavy
flows, flow-entry install/modify/delete) does not say it depends on a GitHub token either --
if anything, "LLM" plus the Kernel's own `--ai`/`OPENAI_API_KEY` elsewhere in this project
would suggest OpenAI, not GitHub. Not tested further (D3/BUG-5 blocks the frontend from
building at all, so the Assistant feature was never reachable), recording only because a
reader who does get the frontend to build would hit an undocumented credential requirement
for that one feature.

## Addendum to BUG-1: `ndt up` (bare, P4 default) fails the same way, with a better message
- **Feature:** `ndt up` with no argument -- the manual's own table: "p4 at the current host
  count (default)".
- **Exact steps:** ran it after Section 6 install finished for real (both `simple_switch_grpc`
  and `p4c-bm2-ss` confirmed working, `bmv2_binary_override` pointed at the stock build).
- **Observed (verbatim):**
  ```
  ndt up p4
    hosts        128        (p4_proxy/mininet/host_count_override)
    topology     setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
    bmv2         /usr/local/bin/simple_switch_grpc
  [1/3] bmv2 fabric
    waiting for 10 switches and the manifest
    XX  fabric did not come up: 0/10 switches, manifest missing
    XX  look at the pane:  sudo -n /usr/local/sbin/ndtwin-lab topo-out 40
  ```
  Took 3m06s to give up (18:13:23 -> 18:16:29) -- faster than `ndt up ovs`'s 5m08s, so the two
  paths apparently use different timeout values. Followed its own suggested diagnostic:
  `sudo -n /usr/local/sbin/ndtwin-lab topo-out 40` -> `ndtwin-lab: no topo session` (exit 1) --
  consistent with BUG-1's root cause (the hardcoded `/home/adam` paths mean `ndtwin-lab` never
  starts a topology session at all for this fabric either). `ndt down` afterward reported the
  machine fully clean.
- **Reproduced:** this is the P4 counterpart of the already-reproduced OVS case, and the root
  cause is identical (verified once by reading the one file the manual names) -- not repeated a
  third time.
- **Severity:** same as BUG-1. Noted here mainly because the failure message is *better* on
  this path -- it names a concrete diagnostic command, even though following it only confirms
  "nothing started" rather than explaining why.
