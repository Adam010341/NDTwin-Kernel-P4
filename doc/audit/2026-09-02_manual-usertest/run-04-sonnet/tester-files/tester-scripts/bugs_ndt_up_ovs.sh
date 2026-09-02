#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

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
EOF
echo APPENDED
