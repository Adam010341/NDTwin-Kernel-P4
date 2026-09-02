#!/bin/bash
exec > ~/logs/journal_append.log 2>&1
cat >> ~/JOURNAL.md << 'EOF'

## Install Manual choice points (before Section 1)   noted 15:39
what I did: Installation Manual root page offers Emulated (Mininet) vs Physical Hardware --
chose Emulated, no physical switches available. Its sub-page then offers "Use the Demo VM"
(download a .ova, import into VMware) vs "Native-Linux Execution Environment" (install
directly onto the machine you have). My machine is a fresh Ubuntu 24.04 VM already reachable
over ssh, not a VMware host, and I was told not to re-image it -- so Native-Linux is the only
path that fits. Also chose to clone `NDtwin-Kernel-P4-public` (the superset repo) rather than
plain `NDTwin-Kernel`, per the manual's own "If you are not sure, clone the P4 one" -- this
keeps the optional P4/BMv2 section (Installation Section 6) open to me later without recloning.
verdict: 1 confusing but worked -- two nested either/or choices before Section 1 even starts,
neither one signposted as "pick based on what machine you already have"; I had to read the
Demo VM page's prerequisites (VMware) to realize it did not apply to me.

## Section 1: System Requirements   started 15:39   ended 15:39   friction: 0
what I did: checked `lsb_release -d` (Ubuntu 24.04.4 LTS, manual verifies on 24.04.3 -- close
enough), `uname -m` (x86_64), confirmed no ~/Desktop (this is Server-shaped, not Desktop --
manual's own Step 4.1 note about `mkdir -p ~/Desktop` being needed is exactly this case),
confirmed passwordless sudo.
verdict: 0 smooth -- pure verification, nothing to install yet.

## Section 2: Python Environment Setup for Ryu   started 15:39   ended 15:45   friction: 0
what I did: installed Miniconda (2.1) via the exact curl/bash/rm commands -- conda 26.7.1 in
under a minute. Sourced conda.sh, ran the two `conda tos accept` commands, `conda create -n
ryu-env python=3.8 -y`, activated it -- `python --version` printed exactly `Python 3.8.20` as
promised. Step 2.2 apt build deps installed cleanly (gcc 13.3.0 present after). Step 2.3: pip
install ryu, pinned eventlet/greenlet/dnspython -- Step 2.4's verification block matched the
manual's expected output *exactly*: dnspython 1.16.0, eventlet 0.30.2, greenlet 2.0.2, ryu
4.34. Step 2.5: `ryu-manager ryu.app.simple_switch_13` in a tmux session -- it loaded
SimpleSwitch13 and OFPHandler and hung, as the manual says is the success case; Ctrl-C
stopped it (and closed the tmux session/server since the pane's only process was ryu-manager
itself, not a shell -- expected tmux behaviour, not an NDTwin issue). Step 2.7: networkx 3.1,
requests 2.28.2, urllib3 1.26.20 installed as pinned. Deferred Step 2.6 (customized Ryu
controller app) because the manual itself says "Do Step 4.1 first, then come back" -- will
close this out right after Section 4's clone.
surprised by: nothing -- this section is the one place so far where every single verification
command printed exactly what the manual said it would.
verdict: 0 smooth.
EOF
echo JOURNAL_APPENDED
cat ~/logs/journal_append.log
