#!/usr/bin/env bash
#
# Does the reader of `ndt apps orphans` read the TALLY, or does it read the exit code?
#
# [Co-developed with claude code -- Adam]
#
# `tools/test_workflow/orphans_verdict.sh` exists because the exit code moved twice inside one
# merge window while the fabric under it did not change (measured live on `integrate-0910`,
# 2026-09-10, R4-LIVE §4-A7 and §4-A9):
#
#     clean OVS4 fabric      rc 0  ->  rc 5     the tally gained `1 question(s) not answerable`
#     P4 4 with a sim up     rc 5  ->  rc 2     /proc/<pid>/fd of a root process is unreadable
#
# `ndt`'s rc table is the spec and is not touched; tests/shell/test_ndt_app_orphans.sh and
# tests/shell/test_apps_residue.sh pin it. This suite pins the READER, and its four load-bearing
# cases are the ones Adam named on 2026-09-10:
#
#     GREEN    a clean report                      -> CLEAN
#     RED 1    the process half says one is running -> NOT CLEAN
#     RED 2    the tally says 1 dated rule          -> NOT CLEAN
#     CONTROL  1 question(s) not answerable, rc 5,  -> CLEAN, with a NOTE
#              everything else clean
#
# and, added 2026-09-11 (R5-ORPHANS-RC-2), the three cells for a report taken AFTER `ndt down`:
#
#     KERNEL DOWN, clean processes    -> CLEAN, with `NOTE: network half not checkable: kernel down`
#     KERNEL DOWN, a process running  -> NOT CLEAN (the half that COULD be read still decides)
#     no tally and no kernel-down     -> UNUSABLE (that is a report nobody can read)
#
# and, added 2026-09-11 (FIX-NDT-2, from F-OFFLINE-1 §1.11), the floor under the NOTE rule:
#
#     kernel UP, a tally, ALL THREE lock probes `NOT CHECKED (http 500)`  -> NOT CHECKED (rc 3)
#     the same, but one probe answered                                    -> CLEAN, with the NOTE
#     the same, but the failure text ends in the word "free"              -> NOT CHECKED (rc 3)
#
# That first cell used to read `VERDICT: CLEAN` rc 0 -- measured 2026-09-11 -- while `ndt` itself
# answered 5 for the same report (residue_verdict, ndt:5349). `network=0/0/0` there is three
# counters nothing ever incremented, not three findings of nothing: `0 lock(s) held` after three
# failed probes is not a measurement. Partial blindness IS the normal state of this lab (the
# CONTROL below is exactly that) and stays a NOTE; total blindness with a live kernel is not.
#
# 🔴 ALL-BLIND 4/4 pins the asymmetry that makes both rulings true at once: after `ndt down`
# nothing read a lock either, and that report is still `CLEAN -- the process half only` (Adam
# 2026-09-10). The operator closed :8000 on purpose as the last step of the round; a kernel that
# is UP and returns http 500 to an acquire probe is a malfunction, and the question is askable
# again this second. Delete either cell and the other stops meaning anything.
#
# `ndt down` closes :8000, so residue_report (ndt:5415) returns before it prints a tally. Measured
# on the merge tree, 2026-09-10 23:59 (`logs/lv-p4128-94-orphans.log`, R5-P4-128 §5 / §7-2): every
# other instrument said the machine was clean and this reader said UNUSABLE, because "no tally" and
# "the kernel that owns the tally is switched off" were the same answer here. They are not the same
# answer: one is a report nobody can read, the other is `ndt` saying in words which half it could
# not read. The verdict now comes from the half that WAS read, and the other half is named as
# missing -- never silently counted as zero.
#
# The CONTROL case is the reason the helper exists, so its fixture is not synthetic: it is the
# verbatim report from the live run that found the shift (`logs/lv-a7-a-orphans.log`, OVS4 on
# `integrate-0910`, 2026-09-10 16:1x). That run's own probe called it a FAIL. It was not one.
#
# 🔴 The discriminating case is RC_IS_NOT_CONSULTED below: the same report body is fed with rc 0
# and with rc 5 and must produce the same verdict, and the RED 2 body is fed with rc 0 and must
# still be NOT CLEAN. A reader that quietly went back to reading the rc passes every other case
# here and fails those.
#
# Offline. Nothing is started, no port is opened, no lab is touched: every fixture is a text
# report on disk.
#
# Env:  ORPHANS_VERDICT_UNDER_TEST=<path>   (point it at a copy to see this suite go red)
# Run:  bash tests/shell/test_orphans_verdict.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="${ORPHANS_VERDICT_UNDER_TEST:-$HERE/../../tools/test_workflow/orphans_verdict.sh}"
[[ -r "$V" ]] || { echo "no orphans_verdict.sh at $V"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2'"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in the output" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-orphverdict-$$-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# verdict <fixture-file> [rc]  -> the helper's stdout with a trailing "RC=<n>" line
verdict() { local out rc; out="$(bash "$V" "$@" 2>&1)"; rc=$?; printf '%s\nRC=%s\n' "$out" "$rc"; }
rc_of()   { sed -n 's/^RC=//p' <<<"$1"; }

# --- fixtures -------------------------------------------------------------------------------
# The shapes `ndt` actually prints. The process half comes from apps_orphans, the network half
# from residue_report's tally line.
#
# 🔴 Two kinds of fixture live here and the difference decides whether one may be edited:
#   SYNTHETIC  typed out to stand for what `ndt` prints. They have to keep up with `ndt` -- the
#              flow-table half was renamed `residue` -> `rules-in-window` on 2026-09-12 and these
#              carried the retired word for a day without anything going red. The section
#              "the synthetic fixtures are QUOTATIONS" at the end is what notices next time.
#   CAPTURED   copied verbatim out of a dated live log, named in the block's own comment
#              (live_a7, kernel_down, kernel_down_running, no_residue_half). They are evidence of
#              what `ndt` printed THEN and are never reworded -- `kernel_down` in particular is
#              the exact report this reader once answered UNUSABLE over.
mk() { cat > "$FIX/$1"; }   # mk <name> <<'EOF' ... EOF

mk clean <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    sim    window 2026-09-10 16:48:24 -> now (22s)
  ok        no flow entry arrived during that window

    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

mk running <<'EOF'
  XX  te: RUNNING as pid(s) 1185971, and these belong to it with nothing naming them -- te
  XX      pid 1185972  (process group 1185971)
  XX    stop it with:  ndt apps stop te
  XX  1 app(s) are running with nothing tracking them

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

mk one_rule <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    sim    window 2026-09-10 16:48:24 -> now (22s)
  XX      rule  dpid=1 table=0 pri=97 match={"dl_type": 2048, "nw_dst": "10.0.0.77"} actions=["OUTPUT:1"]  installed 14s ago
  XX      1 rule(s) listed: 1 dated inside the window, 0 with age=UNKNOWN.
    NOT deleted, and nothing here deletes them.
    tally: 1 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

mk one_lock <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  XX    lock  routing_lock HELD -- held_by_lease=4, frees itself in 30s (TTL)
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 1 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# `ndt` rc 2: found nothing, but could not look everywhere. E-7 -- still not a pass.
mk blind_channel <<'EOF'
  !!  no untracked app processes found, but a channel was blind: sim: fd channel: CANNOT READ /proc/884317/fd (root process) -- not checked

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# 🔴 C10-8 (2026-09-12). The column `ndt` prints for processes that carry an app signature and
# belong to ANOTHER checkout on this machine. Copied from a run of `ndt apps orphans` over two
# fixtures in a foreign tree (scratch/overnight-2026-09-05/logs/ndt10-0912/green-1-orphans-fixed.log),
# with the paths shortened. The process half of the report is CLEAN: these lines carry neither of
# the two sentences it is read from, which is what makes the column a NOTE rather than a verdict.
mk elsewhere_only <<'EOF'
  !!  seen elsewhere (not this checkout): 2 process(es)
  !!      te  pid 1159780  python3 /nonexistent/NDT-TEST-FIXTURE/Traffic-engineering-App.py
  !!          nothing ties it to /home/adam/Desktop/NDTwin-Kernel (it runs in /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt7-0912)
  !!      sim  pid 1166836  /nonexistent/NDT-TEST-FIXTURE/simulation_platform_manager 120
  !!          nothing ties it to /home/adam/Desktop/NDTwin-Kernel (it runs in /tmp/ndt-helper-window-oyNBmC)
  !!      they carry an app signature and nothing ties them to this checkout, so they are
  !!      NOT in the verdict and 'ndt down' here does not stop them. Whoever owns that
  !!      tree stops them. (C10-8, 2026-09-12)
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# The discriminating pair: the same column, in a report that ALSO has an orphan of our own.
mk elsewhere_and_ours <<'EOF'
  !!  seen elsewhere (not this checkout): 1 process(es)
  !!      sim  pid 1166836  /nonexistent/NDT-TEST-FIXTURE/simulation_platform_manager 120
  !!          nothing ties it to /home/adam/Desktop/NDTwin-Kernel (it runs in /tmp/ndt-helper-window-oyNBmC)
  !!      they carry an app signature and nothing ties them to this checkout, so they are
  !!      NOT in the verdict and 'ndt down' here does not stop them. Whoever owns that
  !!      tree stops them. (C10-8, 2026-09-12)
  XX  te: pidfile-lost-but-alive -- Traffic-Engineering-App    (CHANGES the network: installs flow rules)
  XX      pid 1185971  python3 Traffic-engineering-App.py
  XX      stop it with:  ndt apps stop te
  XX  1 app(s) are running with nothing tracking them

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# The fail-closed side of the same question: a root-owned process this user may not look inside.
# `ndt` counts it as OURS and says that it could not tell, which is the sentence this reader has
# to carry (E-7).
mk attrib_blind <<'EOF'
  !!  who owns these could NOT be established, so they are counted as this checkout's: sim pid 884317: cannot read /proc/884317/cwd or /proc/884317/fd (uid 0, you are 1000) -- who owns it was NOT established
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# Every P4 fabric, every run: the flow stats carry no clock, so no rule can be placed (W16-3).
mk p4_undated <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    sim    window 2026-09-10 16:35:02 -> now (31s)
  !!      CANNOT WINDOW -- the P4 plane synthesises flow stats (proxy_agent/ryu_flow_stats.py) and they carry NO install time.
  XX      40 rule(s) listed: 0 dated inside the window, 40 with age=UNKNOWN.
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 40 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# 🔴 THE CONTROL. Verbatim from the live run that found the rc shift: OVS4 on `integrate-0910`,
# 2026-09-10, `scratch/overnight-2026-09-05/logs/lv-a7-a-orphans.log`. `ndt` answered rc 5 and the
# night's probe recorded a FAIL for it. Nothing was running and nothing was on the network.
mk live_a7 <<'EOF'
  ok  no untracked app processes

network residue (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
          field (LockManager.hpp), and the kernel has no lock-status endpoint, so the
          three lines above come from an acquire probe with ttl 0, which excludes nobody.
    energy: no pidfile and no live process -- no window, so no rule can be dated
        against it. NOT 'this app left nothing'. (G-12)
  !!        and whether it ran here CANNOT BE ASKED: the helper keeps no log for energy
  !!        ('/usr/local/sbin/ndtwin-lab energy-start' gives it no 'script -f', so its output only ever
  !!        exists in a tmux pane). That is 'nobody could ask', not 'it never ran'.
    sim: no pidfile and no live process -- no window, so no rule can be dated
        against it. NOT 'this app left nothing'. (G-12)
  !!        and its log is NOT empty, so it did run here: the window is LOST,
  !!        not absent. rules it installed cannot be found by this tool.
        (log read: /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/app_sim.log)
    nsr: no pidfile and no live process -- no window, so no rule can be dated
        against it. NOT 'this app left nothing'. (G-12)
        (its log is empty or absent too -- no sign it ever ran here)

    NOT deleted, and nothing here deletes them.
    (no app had a datable window in this run)
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 1 question(s) not answerable
    and 1 app(s) could not be asked whether they ran here at all: energy (no log channel exists for them -- see above)
  !!  NOT CHECKED: the residue question could not be answered -- rc 5.
  !!    this is not 'the network is clean'. see the lines above for which
  !!    reading failed. (KNOWN-ISSUES G-12)
EOF

# 🔴 KERNEL DOWN. Verbatim from `scratch/overnight-2026-09-05/logs/lv-p4128-94-orphans.log` --
# restore check 2/3 of the `lv-p4128` round, taken seconds after `ndt down` on 2026-09-10 23:59.
# `ndt` returned 5. Every other instrument in that round said the machine was clean (`ndt clean`
# rc 0, `procs:` empty, `mininet nodes left: 0`, `ovs bridges:` empty, `listeners:` empty,
# `tc qdisc` diff 0) and this reader answered `UNUSABLE -- no 'tally:' line`.
#
# There is no tally because residue_report (ndt:5415) returns before printing one when :8000 is
# closed, which is exactly what `ndt down` does. The two `!!` lines are `ndt` naming the half it
# could not read, and they are the difference between this and the `no_tally` fixture below.
mk kernel_down <<'EOF'
  ok  no untracked app processes

network residue (nothing below is deleted)
  !!  the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.
  !!  this is not 'the lab is clean'. it is 'nobody asked'. (KNOWN-ISSUES G-12)
  !!  NOT CHECKED: the residue question could not be answered -- rc 5.
  !!    this is not 'the network is clean'. see the lines above for which
  !!    reading failed. (KNOWN-ISSUES G-12)
EOF

# A COMPOSITE, and the only fixture in this file that is: the network half is the verbatim
# `lv-p4128` kernel-down half above, the process half is the verbatim `running` half from the
# fixture higher up (apps_orphans, ndt:5627/5650). No live round has produced both at once --
# it needs an untracked app still up after `ndt down` -- and that is precisely the case a
# kernel-down NOTE must not swallow: the half that could be read found something.
mk kernel_down_running <<'EOF'
  XX  te: RUNNING as pid(s) 1185971, and these belong to it with nothing naming them -- te
  XX      pid 1185972  (process group 1185971)
  XX    stop it with:  ndt apps stop te
  XX  1 app(s) are running with nothing tracking them

network residue (nothing below is deleted)
  !!  the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.
  !!  this is not 'the lab is clean'. it is 'nobody asked'. (KNOWN-ISSUES G-12)
  !!  NOT CHECKED: the residue question could not be answered -- rc 5.
  !!    this is not 'the network is clean'. see the lines above for which
  !!    reading failed. (KNOWN-ISSUES G-12)
EOF

# Half a report: the residue half started and stopped, and NOTHING says why. No tally, and no
# sentence from `ndt` naming a half it could not read. Must not be read as a pass.
#
# 🔴 Until 2026-09-11 this fixture held the kernel-down text now in `kernel_down` above, so the
# one cell in this file that pinned "an unreadable report is UNUSABLE" was pinned by a report that
# `ndt` had in fact explained. The negative control has to be the case with no explanation in it,
# or the two cannot be told apart -- which is the bug R5-ORPHANS-RC-2 fixes.
mk no_tally <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
EOF

# The same negative control, real rather than cut by hand, and the SECOND cause of a missing
# tally: an older `ndt` whose `orphans` had no network half at all. Verbatim
# `scratch/overnight-2026-09-05/logs/lv-a7-94-orphans.log`. One line, whole, complete -- and it
# answers nothing about the network. An older `ndt` is not a checked network.
#
# 🔴 68 of the 89 `logs/*orphans*.log` reports in that scratch directory have no tally and no
# kernel-down sentence, and all 68 are BYTE-IDENTICAL to this one line -- among them 8 named
# `*-04-orphans.log`, taken at the START of a round with the kernel UP, and the rest `*-94-`,
# taken after the down. The same text, from both sides of a kernel. That is the reason the
# kernel-down mode keys on `ndt`'s sentence and not on the absence of a tally: the absence of a
# tally cannot tell those two apart, so a reader that inferred "kernel down" from it would be
# calling a kernel-up report clean on no evidence at all.
mk no_residue_half <<'EOF'
  ok  no untracked app processes
EOF

# 🔴 ALL-BLIND. Kernel UP -- there IS a tally, which residue_report only reaches after :8000
# answered `port_open` (ndt:5415) -- and every one of the three lock probes came back
# `NOT CHECKED (http 500)` (ndt:5550). Built from `ndt`'s own two print sites for
# F-OFFLINE-1 §1.11, which measured this exact report reading `VERDICT: CLEAN` rc 0 while `ndt`
# itself answered 5 for it (residue_verdict, ndt:5349).
#
# 🔴 The three zeros in its tally are the initial values of counters (ndt:5405-5409) that nothing
# ever incremented, because nothing was ever successfully asked. `0 lock(s) held` after three
# failed probes is not a measurement of zero, and this is the cell that says so.
mk all_blind <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  !!    lock  routing_lock NOT CHECKED (http 500)
  !!    lock  graph_lock NOT CHECKED (http 500)
  !!    lock  power_lock NOT CHECKED (http 500)
          field (LockManager.hpp), and the kernel has no lock-status endpoint, so the
          three lines above come from an acquire probe with ttl 0, which excludes nobody.
    energy: no pidfile and no live process -- no window, so no rule can be dated
        against it. NOT 'this app left nothing'. (G-12)
        (its log is empty or absent too -- no sign it ever ran here)

    NOT deleted, and nothing here deletes them.
    (no app had a datable window in this run)
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 3 question(s) not answerable
  !!  NOT CHECKED: the rules-in-window question could not be answered -- rc 5.
  !!    this is not 'the network is clean'. see the lines above for which
  !!    reading failed. (KNOWN-ISSUES G-12)
EOF

# The other side of the floor: ONE of the three probes answered. Partial blindness is the normal
# state of this lab -- it is what the CONTROL fixture above is -- and it stays CLEAN with a NOTE.
mk partial_blind <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
    lock  routing_lock free
  !!    lock  graph_lock NOT CHECKED (http 500)
  !!    lock  power_lock NOT CHECKED (http 500)
    NOT deleted, and nothing here deletes them.
    (no app had a datable window in this run)
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 2 question(s) not answerable
EOF

# 🔴 THE ANCHORING CONTROL for the all-blind discriminator. The probe's failure text is
# `NOT CHECKED (${lock#unknown })` (ndt:5550) -- whatever the kernel said, verbatim -- so it can
# end in any word at all, including the word this reader looks for. A discriminator that searched
# for a bare ` free` instead of the whole `lock <name> free` line at end-of-line would read this
# report, in which NOTHING was answered, as answered. Same tally as all_blind; same verdict
# required.
mk all_blind_says_free <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  !!    lock  routing_lock NOT CHECKED (http 500 -- no lease was free
  !!    lock  graph_lock NOT CHECKED (http 500 -- no lease was free
  !!    lock  power_lock NOT CHECKED (http 500 -- no lease was free
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 3 question(s) not answerable
EOF

# All three locks blind, but an app HAD a datable window and the flow table WAS read for it
# (ndt:5632). Under the 2026-09-11 rule -- "one positive answer is enough" -- that is partial
# blindness and stays CLEAN with a NOTE. Pinned rather than left implicit because it is the
# weakest cell on the CLEAN side of the floor: `0 lock(s) held` in it still rests on three failed
# probes. Whether the lock half should have to answer on its own is FIX-NDT-2 SUMMARY §7-1, for
# Adam; until he rules, this is the behaviour and this cell is what would have to change.
mk locks_blind_window_read <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  !!    lock  routing_lock NOT CHECKED (http 500)
  !!    lock  graph_lock NOT CHECKED (http 500)
  !!    lock  power_lock NOT CHECKED (http 500)
    sim    window 2026-09-10 16:48:24 -> now (22s)
  ok        no flow entry arrived during that window
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 3 question(s) not answerable
EOF

# 🔴 H2. The three live reports from ROLE-2's cycles, with the `stack:` line `ndt apps orphans`
# prints from 2026-09-11 on. Everything else in them is clean -- and all three read CLEAN.
mk half_kernel_only <<'EOF'
  ok  no untracked app processes

stack
    stack: kernel=up dataplane=none bmv2=0 mininet=0 proxy=up verdict=HALF
  !!  HALF A STACK. the two halves disagree: one of the kernel and the data plane
  !!  is there and the other is not.

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# cycle-07 / cycle-12: a fabric still standing with the kernel down. The network half is n/a
# (no tally, kernel-down mode), so this is also the cell that says the kernel-down CLEAN does
# not cover a data plane the PROCESS side could see all along.
mk half_fabric_only <<'EOF'
  ok  no untracked app processes

stack
    stack: kernel=down dataplane=p4 bmv2=10 mininet=14 proxy=up verdict=HALF
  !!  HALF A STACK. the two halves disagree: one of the kernel and the data plane
  !!  is there and the other is not.

rules-in-window (nothing below is deleted)
  !!  the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.
  !!  this is not 'the lab is clean'. it is 'nobody asked'. (KNOWN-ISSUES G-12)
EOF

# 🔴 THE CONTROL for H2: `apps orphans` is asked BEFORE a teardown too, and a healthy fabric
# must pass. Whole-up is not residue.
mk whole_up <<'EOF'
  ok  no untracked app processes

stack
    stack: kernel=up dataplane=p4 bmv2=10 mininet=14 proxy=up verdict=whole-up
          the stack is up. that is not residue -- 'apps orphans' is asked before a
          teardown as well as after it.

rules-in-window (nothing below is deleted)
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# And the state a finished round should be in.
mk whole_down <<'EOF'
  ok  no untracked app processes

stack
    stack: kernel=down dataplane=none bmv2=0 mininet=0 proxy=down verdict=whole-down
          no kernel and no data plane: nothing of the stack is up.

rules-in-window (nothing below is deleted)
  !!  the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked.
  !!  this is not 'the lab is clean'. it is 'nobody asked'. (KNOWN-ISSUES G-12)
EOF

# What a caller who forgot `2>&1` collects when an orphan IS running: err() writes to fd 2.
mk no_process_half <<'EOF'
rules-in-window (nothing below is deleted)
    lock  routing_lock free
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF

# The same clean report, captured with `ndt`'s colours on.
printf '\033[32m  ok\033[0m  no untracked app processes\n\033[2m  tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable\033[0m\n' > "$FIX/coloured"

# =================================================================================================
section "GREEN -- a clean fabric"
# =================================================================================================
OUT="$(verdict "$FIX/clean" 0)"
check "  rc 0"                                            "0"  "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  processes=clean"                                 "processes=clean" "$OUT"
has   "  network=0/0/0"                                   "network=0/0/0" "$OUT"
has   "  not_answerable=0"                                "not_answerable=0" "$OUT"
hasnt "  and nothing to NOTE"                             "NOTE" "$OUT"

# =================================================================================================
section "RED 1 -- the process half says an untracked process is running"
# =================================================================================================
OUT="$(verdict "$FIX/running" 1)"
check "  rc 1"                                            "1"  "$(rc_of "$OUT")"
has   "  processes=running"                               "processes=running" "$OUT"
has   "  VERDICT: NOT CLEAN"                              "VERDICT: NOT CLEAN" "$OUT"
has   "  and names the remedy"                            "ndt apps stop <name>" "$OUT"

# =================================================================================================
section "RED 2 -- the tally says a dated rule sits in a window"
# =================================================================================================
OUT="$(verdict "$FIX/one_rule" 4)"
check "  rc 1"                                            "1"  "$(rc_of "$OUT")"
has   "  network=1/0/0"                                   "network=1/0/0" "$OUT"
has   "  VERDICT: NOT CLEAN"                              "VERDICT: NOT CLEAN" "$OUT"
has   "  and says which"                                  "1 dated rule(s) in a window" "$OUT"

# =================================================================================================
section "🔴 CONTROL -- 1 question(s) not answerable, rc 5, everything else clean"
# =================================================================================================
OUT="$(verdict "$FIX/live_a7" 5)"
check "  🔴 rc 0 -- the case this reader exists for"      "0"  "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  processes=clean"                                 "processes=clean" "$OUT"
has   "  network=0/0/0"                                   "network=0/0/0" "$OUT"
has   "  not_answerable=1"                                "not_answerable=1" "$OUT"
has   "  the NOTE is printed, not swallowed"              "NOTE: 1 question(s) not answerable" "$OUT"
has   "  and says it is a NOTE and not a FAIL"            "A NOTE and not a FAIL" "$OUT"
has   "  ndt's own rc is recorded"                        "ndt_rc=5 (recorded, NOT used for the verdict)" "$OUT"
has   "  the tool's own sentence is quoted"               "the window is LOST" "$OUT"
has   "  and so is the app nobody can ask about"          "could not be asked whether they ran here at all: energy" "$OUT"

# =================================================================================================
section "🔴 RC_IS_NOT_CONSULTED -- the discriminating control"
# =================================================================================================
A="$(verdict "$FIX/live_a7" 5)"; B="$(verdict "$FIX/live_a7" 0)"
check "  the same report with rc 5 and rc 0 gives the same verdict" \
      "$(grep -F 'VERDICT:' <<<"$A")" "$(grep -F 'VERDICT:' <<<"$B")"
OUT="$(verdict "$FIX/one_rule" 0)"
check "  🔴 a dated rule is NOT CLEAN even when ndt returned 0" "1" "$(rc_of "$OUT")"
OUT="$(verdict "$FIX/clean")"
check "  and no rc at all is fine -- the report is the input"    "0" "$(rc_of "$OUT")"
hasnt "  with no ndt_rc line to invent"                          "ndt_rc=" "$OUT"

# =================================================================================================
section "A held lock is residue -- rc 4's other half"
# =================================================================================================
OUT="$(verdict "$FIX/one_lock" 4)"
check "  rc 1"                                            "1"  "$(rc_of "$OUT")"
has   "  network=0/1/0"                                   "network=0/1/0" "$OUT"
has   "  and says a lock heals at its TTL"                "a lock frees itself at its TTL" "$OUT"

# =================================================================================================
section "A blind liveness channel is NOT a pass (E-7)"
# =================================================================================================
OUT="$(verdict "$FIX/blind_channel" 2)"
check "  rc 1"                                            "1"  "$(rc_of "$OUT")"
has   "  processes=unknown"                               "processes=unknown" "$OUT"
has   "  and the verdict says which of the two it was"    "a liveness channel was blind" "$OUT"
hasnt "  🔴 and it is not reported as a running orphan"   "processes=running" "$OUT"

# =================================================================================================
section "Undated rules are a NOTE -- every P4 fabric, every run (W16-3)"
# =================================================================================================
OUT="$(verdict "$FIX/p4_undated" 5)"
check "  🔴 rc 0 -- a P4 fabric must be able to pass"     "0"  "$(rc_of "$OUT")"
has   "  network=0/0/40"                                  "network=0/0/40" "$OUT"
has   "  and the 40 are noted"                            "NOTE: 40 rule(s) could not be dated" "$OUT"
has   "  with ndt's sentence for why"                     "CANNOT WINDOW" "$OUT"

# =================================================================================================
section "🔴 KERNEL DOWN 1/3 -- after 'ndt down' the network half cannot be checked, and says so"
# =================================================================================================
OUT="$(verdict "$FIX/kernel_down" 5)"
check "  🔴 rc 0 -- the process half was read and it was clean" "0" "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  processes=clean"                                 "processes=clean" "$OUT"
has   "  🔴 the NOTE this cell exists for"                "NOTE: network half not checkable: kernel down" "$OUT"
has   "  network=n/a -- named as missing"                 "network=n/a" "$OUT"
has   "  not_answerable=n/a -- likewise"                  "not_answerable=n/a" "$OUT"
hasnt "  🔴 and NOT counted as zero"                      "network=0/0/0" "$OUT"
hasnt "  🔴 nor is not_answerable"                        "not_answerable=0" "$OUT"
has   "  ndt's own sentence is quoted"                    "the kernel is not up (:8000 closed)" "$OUT"
has   "  and so is its 'nobody asked'"                    "NOT CHECKED: the residue question could not be answered" "$OUT"
has   "  ndt's rc is recorded, not consulted"             "ndt_rc=5 (recorded, NOT used for the verdict)" "$OUT"
hasnt "  🔴 and it is not UNUSABLE"                       "VERDICT: UNUSABLE" "$OUT"
# 🔴 The field is slash-separated and `n/a` contains a slash, so a caller that splits it the way
# the round probes do (`IFS=/ read -r RULES LOCKS UNDATED`) gets `n` and `a`, not `0` and `0`.
# Those probes compare as STRINGS on purpose (R5-PROBES-INPLACE §3-B), so this fails safe -- but
# only because of that choice, which is why it is pinned here rather than left to be rediscovered.
NETF="$(sed -n 's/^network=//p' <<<"$OUT")"
IFS=/ read -r KD_RULES KD_LOCKS KD_UNDATED <<<"$NETF"
check "  🔴 split as the probes split it, neither half reads as 0" \
      "not-0/not-0" "$([[ "$KD_RULES" == 0 ]] && printf 0 || printf not-0)/$([[ "${KD_LOCKS:-}" == 0 ]] && printf 0 || printf not-0)"

# =================================================================================================
section "🔴 KERNEL DOWN 2/3 -- the half that COULD be read still decides"
# =================================================================================================
OUT="$(verdict "$FIX/kernel_down_running" 1)"
check "  🔴 rc 1 -- a kernel-down NOTE does not excuse a running orphan" "1" "$(rc_of "$OUT")"
has   "  processes=running"                               "processes=running" "$OUT"
has   "  VERDICT: NOT CLEAN"                              "VERDICT: NOT CLEAN" "$OUT"
has   "  and names the remedy"                            "ndt apps stop <name>" "$OUT"
has   "  the kernel-down NOTE is still printed"           "NOTE: network half not checkable: kernel down" "$OUT"
hasnt "  🔴 and never says CLEAN"                         "VERDICT: CLEAN" "$OUT"

# =================================================================================================
section "🔴 KERNEL DOWN 3/3 -- the OTHER two causes of a missing tally are still UNUSABLE"
# =================================================================================================
# Cause 1: the residue half ran and stopped part-way, saying nothing about why.
OUT="$(verdict "$FIX/no_tally" 5)"
check "  🔴 rc 2 -- nothing in the report says why the tally is missing" "2" "$(rc_of "$OUT")"
has   "  and says so"                                     "VERDICT: UNUSABLE" "$OUT"
hasnt "  🔴 and never says CLEAN"                         "VERDICT: CLEAN" "$OUT"
hasnt "  🔴 and does not invent a kernel-down NOTE"       "kernel down" "$OUT"
# Cause 2: an older `ndt` whose `orphans` printed no network half at all. 68 real reports have
# this exact one line, 8 of them taken with the kernel UP (`logs/*-04-orphans.log`) -- so the
# absence of a tally is NOT evidence of a down, and must not be read as one.
OUT="$(verdict "$FIX/no_residue_half" 0)"
check "  🔴 rc 2 -- a real one-line report from an older ndt"           "2" "$(rc_of "$OUT")"
has   "  processes=clean is still reported"               "processes=clean" "$OUT"
hasnt "  🔴 but the verdict is not CLEAN"                 "VERDICT: CLEAN" "$OUT"
hasnt "  🔴 and a kernel-down NOTE is not invented from a missing tally" "kernel down" "$OUT"
has   "  and it names what is missing"                    "no 'tally:' line in the report" "$OUT"

# =================================================================================================
section "🔴 ALL-BLIND 1/4 -- kernel UP, a tally, and not one network question answered"
# =================================================================================================
# F-OFFLINE-1 §1.11, measured 2026-09-11: this report read `VERDICT: CLEAN` rc 0 while `ndt`
# answered 5 for the same observation. The tally's zeros were never measured.
OUT="$(verdict "$FIX/all_blind" 5)"
check "  🔴 rc 3 -- zeros nobody could measure are not a clean network" "3" "$(rc_of "$OUT")"
has   "  VERDICT: NOT CHECKED"                            "VERDICT: NOT CHECKED" "$OUT"
hasnt "  🔴 and NOT the token CLEAN -- a grep gate must not pass it" "VERDICT: CLEAN" "$OUT"
hasnt "  🔴 nor NOT CLEAN -- nothing was found, so nothing is to be deleted" "VERDICT: NOT CLEAN" "$OUT"
has   "  processes=clean is still reported"               "processes=clean" "$OUT"
has   "  and it says what the zeros mean"                 "'nobody got an answer', NOT 'nothing is there'" "$OUT"
has   "  and names the remedy: ask again"                 "ask again" "$OUT"
has   "  ndt's own sentence is quoted"                    "lock  routing_lock NOT CHECKED (http 500)" "$OUT"
has   "  ndt's rc is recorded, not consulted"             "ndt_rc=5 (recorded, NOT used for the verdict)" "$OUT"

# =================================================================================================
section "🔴 ALL-BLIND 2/4 -- one answer out of three is still CLEAN, with the NOTE"
# =================================================================================================
OUT="$(verdict "$FIX/partial_blind" 5)"
check "  🔴 rc 0 -- partial blindness is this lab's normal state" "0" "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  with the NOTE, not swallowed"                    "NOTE: 2 question(s) not answerable" "$OUT"
hasnt "  🔴 and never NOT CHECKED"                        "VERDICT: NOT CHECKED" "$OUT"
# The CONTROL fixture is the live form of the same rule: three locks free, one lost window.
OUT="$(verdict "$FIX/live_a7" 5)"
check "  🔴 the live CONTROL is untouched by the floor"   "0" "$(rc_of "$OUT")"
hasnt "  and still not NOT CHECKED"                       "VERDICT: NOT CHECKED" "$OUT"
# So is a fabric where everything answered and every answer was empty.
OUT="$(verdict "$FIX/clean" 0)"
check "  and a wholly answered clean fabric is still rc 0" "0" "$(rc_of "$OUT")"
hasnt "  with no floor NOTE invented for it"              "VERDICT: NOT CHECKED" "$OUT"
# not_answerable=0 is the tool saying every question came back. The floor must not fire there.
OUT="$(verdict "$FIX/p4_undated" 5)"
check "  🔴 and a P4 fabric (40 undated, 0 unanswerable) can still pass" "0" "$(rc_of "$OUT")"

# =================================================================================================
section "🔴 ALL-BLIND 3/4 -- the discriminator reads the LINE, not the word 'free'"
# =================================================================================================
# `NOT CHECKED (${lock#unknown })` carries the kernel's own error text (ndt:5550), so the failure
# line can end in any word, this one included. Nothing in this report was answered.
OUT="$(verdict "$FIX/all_blind_says_free" 5)"
check "  🔴 rc 3 -- an error message containing 'free' is not a lock that was read" "3" "$(rc_of "$OUT")"
has   "  VERDICT: NOT CHECKED"                            "VERDICT: NOT CHECKED" "$OUT"
hasnt "  🔴 and never CLEAN"                              "VERDICT: CLEAN" "$OUT"

# =================================================================================================
section "🔴 ALL-BLIND 4/4 -- the asymmetry with kernel-down is deliberate"
# =================================================================================================
# Neither report read a lock. One is CLEAN and one is NOT CHECKED, and the difference is whether
# the kernel was there to answer: `ndt down` closing :8000 is a state the operator created as the
# last step of the round, and Adam ruled on 2026-09-10 that the process half still answers for it.
# An http 500 from a kernel that is UP is a malfunction, and the question is askable this second.
A="$(verdict "$FIX/kernel_down" 5)"; B="$(verdict "$FIX/all_blind" 5)"
check "  🔴 kernel down  -> rc 0"                         "0" "$(rc_of "$A")"
has   "  🔴 and Adam's 09-10 wording is unchanged"        "CLEAN -- the process half only" "$A"
check "  🔴 kernel up, all probes blind -> rc 3"          "3" "$(rc_of "$B")"
check "  🔴 the two verdicts are not the same line"       "differ" \
      "$([[ "$(grep -F 'VERDICT:' <<<"$A")" == "$(grep -F 'VERDICT:' <<<"$B")" ]] && printf same || printf differ)"
# A window that WAS read is an answer, so this stays CLEAN under the 2026-09-11 rule. See the
# fixture's own header and FIX-NDT-2 SUMMARY §7-1: this is the cell that changes if Adam rules
# that the lock half must answer on its own.
OUT="$(verdict "$FIX/locks_blind_window_read" 5)"
check "  one window read, three locks blind -> rc 0 (§7-1 is open)" "0" "$(rc_of "$OUT")"
has   "  with the NOTE"                                   "NOTE: 3 question(s) not answerable" "$OUT"

# =================================================================================================
section "🔴 H2 1/3 -- a stack the report calls HALF is not a clean lab"
# =================================================================================================
# Measured live 2026-09-11: this reader answered CLEAN over a kernel serving a 14-node graph
# with zero bmv2 and zero mininet processes, and over a 10-switch fabric with the kernel down.
# Both verdicts were right about what they had been given: nothing in `ndt apps orphans` used to
# mention the kernel, the fabric or the proxy.
OUT="$(verdict "$FIX/half_kernel_only" 0)"
check "  🔴 rc 1 -- a kernel with no fabric is not clean"  "1" "$(rc_of "$OUT")"
has   "  VERDICT: NOT CLEAN"                              "VERDICT: NOT CLEAN" "$OUT"
hasnt "  🔴 and never CLEAN"                              "VERDICT: CLEAN" "$OUT"
has   "  the field is reported"                           "stack=HALF" "$OUT"
has   "  and the reason says which way round"             "one of the kernel and the data plane" "$OUT"
has   "  and names the remedy"                            "'ndt down'" "$OUT"
has   "  processes=clean is still reported"               "processes=clean" "$OUT"
has   "  and the network half still is too"               "network=0/0/0" "$OUT"

# 🔴 The kernel-down case, which is where Adam's 09-10 ruling lives: the network half is n/a and
# unaskable, but a 10-switch fabric standing after a teardown is something the PROCESS side
# could see all along. It is a finding, not an unanswerable question.
OUT="$(verdict "$FIX/half_fabric_only" 5)"
check "  🔴 rc 1 -- a fabric with no kernel is not clean either" "1" "$(rc_of "$OUT")"
has   "  VERDICT: NOT CLEAN"                              "VERDICT: NOT CLEAN" "$OUT"
hasnt "  🔴 and the kernel-down CLEAN does not cover it"  "VERDICT: CLEAN" "$OUT"
has   "  network=n/a is still named as missing"           "network=n/a" "$OUT"
has   "  and the kernel-down NOTE is still printed"       "NOTE: network half not checkable: kernel down" "$OUT"

# =================================================================================================
section "🔴 H2 2/3 -- whole-up and whole-down are both CLEAN"
# =================================================================================================
# "Anything is up" is not the rule: `apps orphans` is asked at the START of a round as well, and
# a reader that failed on a live fabric would fail every mid-round check.
OUT="$(verdict "$FIX/whole_up" 0)"
check "  🔴 rc 0 -- a healthy fabric is not residue"      "0" "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  and the field says so"                           "stack=whole-up" "$OUT"
hasnt "  🔴 with no HALF reason invented"                 "the stack is HALF up" "$OUT"
OUT="$(verdict "$FIX/whole_down" 5)"
check "  rc 0 -- and so is a finished round"              "0" "$(rc_of "$OUT")"
has   "  VERDICT: CLEAN"                                  "VERDICT: CLEAN" "$OUT"
has   "  Adam's 09-10 wording is intact"                  "CLEAN -- the process half only" "$OUT"
has   "  and the field says so"                           "stack=whole-down" "$OUT"

# =================================================================================================
section "🔴 H2 3/3 -- a report that says nothing about the stack changes nothing"
# =================================================================================================
# Every `ndt` before 2026-09-11, and every fixture above written before it. "No answer" is named
# and never read as "nothing was up" (E-7) -- and never as a failure either, or this reader would
# reject 89 of the reports already on disk.
OUT="$(verdict "$FIX/clean" 0)"
check "  rc 0 -- an older report is unaffected"           "0" "$(rc_of "$OUT")"
has   "  🔴 and the missing half is NAMED"                "stack=not-reported" "$OUT"
hasnt "  not counted as whole-down"                       "stack=whole-down" "$OUT"
OUT="$(verdict "$FIX/kernel_down" 5)"
check "  and so is the kernel-down fixture"               "0" "$(rc_of "$OUT")"
has   "  still Adam's 09-10 verdict"                      "CLEAN -- the process half only" "$OUT"
has   "  with the stack half named as unreported"         "stack=not-reported" "$OUT"
OUT="$(verdict "$FIX/running" 1)"
check "  a running orphan is still rc 1 with no stack line" "1" "$(rc_of "$OUT")"
OUT="$(verdict "$FIX/all_blind" 5)"
check "  and the all-blind floor still answers 3"         "3" "$(rc_of "$OUT")"

# =================================================================================================
section "🔴 C10-8 -- another checkout's processes are a NOTE, and ours are still a FAIL"
# =================================================================================================
# Measured 2026-09-12 15:05:14 (CELLS-2 window 1). Another worktree of this repo was running
# tests/shell/test_ndt_helper_apps_window.sh; its fixtures wear an app's argv, `ndt apps orphans`
# scanned the whole machine, and THIS reader answered NOT CLEAN over a lab that was down and
# clean. `ndt` now prints those in a column of its own, and the two cells below are the two
# halves that have to hold at once: the foreign column does not fail the verdict, and a real
# orphan in the same report still does.
OUT="$(verdict "$FIX/elsewhere_only" 5)"
check "  another tree's processes -> rc 0"                "0" "$(rc_of "$OUT")"
has   "  🔴 and the verdict is CLEAN"                     "VERDICT: CLEAN" "$OUT"
has   "  the count is carried as a field"                 "elsewhere=2" "$OUT"
has   "  and as a NOTE, so CLEAN is not read as 'nothing was there'" "belong to ANOTHER checkout" "$OUT"
OUT="$(verdict "$FIX/elsewhere_and_ours" 1)"
check "  🔴 ours in the same report -> rc 1"              "1" "$(rc_of "$OUT")"
has   "  NOT CLEAN, from the process half"                "VERDICT: NOT CLEAN" "$OUT"
has   "  and theirs is still counted in the field"        "elsewhere=1" "$OUT"
OUT="$(verdict "$FIX/clean" 0)"
hasnt "  🔴 a report with no such line gets no field"     "elsewhere=" "$OUT"
OUT="$(verdict "$FIX/attrib_blind" 5)"
check "  a pid nobody could attribute -> still rc 0"      "0" "$(rc_of "$OUT")"
has   "  🔴 and the sentence is carried (E-7)"            "who owns these could NOT be established" "$OUT"

# =================================================================================================
section "An unreadable report is UNUSABLE, never CLEAN"
# =================================================================================================
OUT="$(verdict "$FIX/no_tally" 5)"
check "  no tally line -> rc 2"                           "2"  "$(rc_of "$OUT")"
has   "  and says so"                                     "VERDICT: UNUSABLE" "$OUT"
hasnt "  🔴 and never says CLEAN"                         "VERDICT: CLEAN" "$OUT"
OUT="$(verdict "$FIX/no_process_half" 0)"
check "  no process half -> rc 2"                         "2"  "$(rc_of "$OUT")"
has   "  and names the cause (stderr was not captured)"   "did the caller capture stderr?" "$OUT"
OUT="$(verdict "$FIX/does-not-exist" 0)"
check "  a missing file -> rc 2"                          "2"  "$(rc_of "$OUT")"
OUT="$(printf '' | verdict - )"
check "  an empty report -> rc 2"                         "2"  "$(rc_of "$OUT")"

# =================================================================================================
section "G-55 -- a report taken over an EMPTY flow table is quoted, and is still CLEAN"
# =================================================================================================
# [Co-developed with claude code -- Adam]
# FIX-NDT-11 ①. `ndt` now says, once, at the top of the network half, that the table it read was
# empty -- because `no flow entry arrived during that window` is the same sentence whether the
# window excluded sixty rules or the plane had none (CELLS-2 cell 1, 2026-09-12 15:00:47: a
# converged `ndt up ovs 4` whose table still read `[]` ten seconds later).
#
# 🔴 A NOTE, NEVER A FAIL, and the two cells below are the pair that says so. An empty table is
# the normal reading on every idle lab with a kernel up and no fabric, so failing on it would put
# this reader in the red every night -- the shape that made G-12's own green checks unreadable.
# But a CLEAN that does not QUOTE it is a CLEAN a round log cannot tell from one taken over a
# fabric whose rules had not been programmed yet, which is the whole of G-55 one layer up.
mk empty_table <<'EOF'
  ok  no untracked app processes

rules-in-window (nothing below is deleted)
  !!    flow table read empty -- a window over an empty table frames nothing.
    lock  routing_lock free
    lock  graph_lock free
    lock  power_lock free
    te     window 2026-09-12 15:00:23 -> now (24s)
  ok        no flow entry arrived during that window
    NOT deleted, and nothing here deletes them.
    tally: 0 dated rule(s) in a window, 0 lock(s) held, 0 rule(s) that could not be dated, 0 question(s) not answerable
EOF
OUT="$(verdict "$FIX/empty_table" 0)"
check "  an empty table is still rc 0"                    "0"  "$(rc_of "$OUT")"
has   "  and still CLEAN"                                 "VERDICT: CLEAN" "$OUT"
has   "🔴 but the sentence is carried into the report"    "NOTE-WHY: !!    flow table read empty" "$OUT"
has   "  with what it means for the window"               "a window over an empty table frames nothing" "$OUT"
has   "  and the network half still reads 0/0/0"          "network=0/0/0" "$OUT"
# 🔴 THE CONTROL. `clean` is the same report with rules on the wire and none in the window: the
# NOTE must be absent there, or "quote it always" would pass the cell above and the note would
# say nothing.
OUT="$(verdict "$FIX/clean" 0)"
hasnt "🔴 and a report with no such line gets no NOTE"    "flow table read empty" "$OUT"

# =================================================================================================
section "🔴 the synthetic fixtures are QUOTATIONS, and this is what keeps them true"
# =================================================================================================
# [Co-developed with claude code -- Adam]
# Every `mk` block above that is not marked "verbatim from a live log" is a report somebody typed
# out to stand for what `ndt apps orphans` prints. Their headers say "the shapes `ndt` actually
# prints" -- and on 2026-09-12 that had stopped being true without anything going red: FIX-NDT-9
# renamed the flow-table half from `residue` to `rules-in-window` (Adam, RESIDUE-1 §7-5), and
# twenty-odd fixtures here still opened with `network residue (nothing below is deleted)` and
# quoted `NOT CHECKED: the residue question could not be answered`. It was harmless -- this
# reader keys on `tally:` and on the process half's two sentences, none of which moved -- and
# that is exactly why nobody noticed. A fixture that lies about its source is a test that
# measures a report shape which no longer exists.
#
# 🔴 What this can and cannot do. It checks that the sentences these fixtures put in `ndt`'s
# mouth still EXIST in tools/test_workflow/ndt; it cannot check that `ndt` prints them in this
# arrangement, and no offline reader could. The live cells are what run the real tool. So this is
# a drift alarm on the wording, and the next rename goes red HERE rather than three weeks later.
NDT_SRC="$HERE/../../tools/test_workflow/ndt"
if [[ ! -r "$NDT_SRC" ]]; then
    t_bad "the fixtures can be checked against ndt" "no readable ndt at $NDT_SRC"
else
    # quoted_in_ndt <what> <sentence> -- the sentence has to appear in ndt's source, verbatim.
    quoted_in_ndt() {
        if grep -qF -- "$2" "$NDT_SRC"; then t_ok "$1"
        else t_bad "$1" "not in tools/test_workflow/ndt: [$2]"; fi
    }

    # 🔴 THE CAPTURES ARE EXEMPT, and the exemption is the point rather than a loophole. These
    # four fixtures are dated reports copied out of live logs (their `mk` blocks name the log and
    # the timestamp); they are EVIDENCE of what `ndt` printed on 2026-09-10, not quotations of
    # what it prints today. Rewording them would destroy the only thing they are for -- and would
    # make `kernel_down` stop being the report this reader was measured as UNUSABLE over. The
    # list is spelled out here so that "which fixtures may carry retired wording" is a decision
    # somebody made rather than a side effect of a pattern.
    CAPTURED_FIXTURES=(live_a7 kernel_down kernel_down_running no_residue_half)
    is_captured() { local c; for c in "${CAPTURED_FIXTURES[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }
    MISSING_CAPTURE=0
    for c in "${CAPTURED_FIXTURES[@]}"; do [[ -f "$FIX/$c" ]] || MISSING_CAPTURE=$((MISSING_CAPTURE+1)); done
    check "every exempted fixture still exists" "0" "$MISSING_CAPTURE"

    # (a) Automatic, over every synthetic fixture on disk: the two line shapes that carry the
    # half's NAME. These are the lines the 09-12 rename moved, and reading them out of the
    # fixtures rather than listing them here means a fixture added tomorrow is covered the day it
    # is added.
    STALE=0
    declare -A SEEN_SENTENCE=()
    for f in "$FIX"/*; do
        [[ -f "$f" ]] || continue
        is_captured "${f##*/}" && continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            s="${line#"${line%%[![:space:]]*}"}"          # leading whitespace
            case "$s" in
                'ok '*|'XX '*|'!! '*) s="${s:3}"; s="${s#"${s%%[![:space:]]*}"}" ;;
            esac
            case "$s" in
                *'(nothing below is deleted)') ;;
                'NOT CHECKED: the '*'question could not be answered'*) ;;
                *) continue ;;
            esac
            [[ -n "${SEEN_SENTENCE[$s]:-}" ]] && continue
            SEEN_SENTENCE[$s]="${f##*/}"
            grep -qF -- "$s" "$NDT_SRC" || STALE=$((STALE+1))
        done < "$f"
    done
    for s in "${!SEEN_SENTENCE[@]}"; do
        quoted_in_ndt "fixture sentence is still ndt's (${SEEN_SENTENCE[$s]}): ${s:0:46}" "$s"
    done
    check "🔴 no fixture quotes a sentence ndt no longer prints" "0" "$STALE"

    # (b) The sentences this reader is BUILT on, listed rather than scanned: if one of them stops
    # being ndt's, the fixtures are not the only thing that has to change -- the reader's needles
    # have to change with them, and a green suite over a renamed tool would be the loudest
    # possible silence. Fragments, not whole lines, wherever ndt interpolates.
    quoted_in_ndt "ndt still says: no untracked app processes"      "no untracked app processes"
    quoted_in_ndt "ndt still says: ...are running with nothing tracking them" "app(s) are running with nothing tracking them"
    quoted_in_ndt "ndt still says: pidfile-lost-but-alive"          "pidfile-lost-but-alive"
    quoted_in_ndt "ndt still says: ...but a channel was blind"      "no untracked app processes found, but a channel was blind"
    quoted_in_ndt "ndt still prints the tally's first field"        "dated rule(s) in a window,"
    quoted_in_ndt "ndt still prints the tally's lock field"         "lock(s) held,"
    quoted_in_ndt "ndt still prints the tally's undated field"      "rule(s) that could not be dated,"
    quoted_in_ndt "ndt still prints the tally's unanswerable field" "question(s) not answerable"
    quoted_in_ndt "ndt still says: no flow entry arrived..."        "no flow entry arrived during that window"
    quoted_in_ndt "ndt still says: N rule(s) listed:"               "rule(s) listed:"
    quoted_in_ndt "ndt still says: the kernel is not up (:8000 closed)" "the kernel is not up (:8000 closed) -- rules and locks CANNOT be checked."
    quoted_in_ndt "ndt still says: NOT CHECKED -- :8000 is closed"  "NOT CHECKED -- :8000 is closed, so no rule and no lock was read"
    quoted_in_ndt "ndt still says: CANNOT WINDOW"                   "CANNOT WINDOW -- "
    quoted_in_ndt "ndt still explains WHY a P4 table cannot be windowed" "the P4 plane synthesises flow stats (proxy_agent/ryu_flow_stats.py) and they"
    quoted_in_ndt "ndt still says: NOT CHECKED (<the kernel's own words>)" "NOT CHECKED ("
    quoted_in_ndt "ndt still says: ...could not be asked whether they ran here at all" "could not be asked whether they ran here at all"
    quoted_in_ndt "ndt still says: the window is LOST"              "the window is LOST,"
    quoted_in_ndt "ndt still prints a stack: line with a verdict"   "stack: kernel="
    quoted_in_ndt "ndt still says: HALF A STACK"                    "HALF A STACK. the two halves disagree"
    quoted_in_ndt "ndt still says: seen elsewhere (not this checkout)" "seen elsewhere (not this checkout)"
    quoted_in_ndt "ndt still says: flow table read empty (G-55)"  "flow table read empty -- a window over an empty table frames nothing"

    # 🔴 The control. Every check above is a grep for something that IS there; a `quoted_in_ndt`
    # broken into always passing would look identical. This sentence is built to be absent.
    if grep -qF -- "no untracked app processes were harmed in the making of this fixture" "$NDT_SRC"; then
        t_bad "the control: a sentence ndt does not print is reported missing" "it matched -- every check above is worthless"
    else
        t_ok "the control: a sentence ndt does not print is reported missing"
    fi
fi

# =================================================================================================
section "Plumbing: stdin, and a report captured with colours on"
# =================================================================================================
OUT="$(bash "$V" - 0 < "$FIX/clean" 2>&1; echo "RC=$?")"
check "  '-' reads the report from stdin"                 "0"  "$(rc_of "$OUT")"
has   "  and answers the same"                            "VERDICT: CLEAN" "$OUT"
OUT="$(verdict "$FIX/coloured" 0)"
check "  SGR sequences do not hide the tally"             "0"  "$(rc_of "$OUT")"
has   "  network=0/0/0"                                   "network=0/0/0" "$OUT"

printf '\n%s\n' "-----------------------------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
