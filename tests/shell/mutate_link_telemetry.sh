#!/usr/bin/env bash
#
# Mutation gate for link-level telemetry: which veth gets a sampling filter and in which
# direction, the sixteen bits psample reports an ifindex in, the netns the emitter must be in,
# what a dead emitter means, the three layers of the telemetry knob, TCLink's on/off condition,
# the units bandwidth is expressed in, the direction a sample carries onto the wire, the length
# the kernel multiplies by the sampling rate, and the teardown that takes the filters off.
# TICKET-P3 section 4.3 (M-B1 .. M-B11), plus seven the ticket does not list -- four of them
# added in round 2 for the three claims the judge found were made in prose only (F1's abort
# path, F2's pre-flight, the attach/start/write ordering) -- and the reason each is here is
# written beside it. M-B11 is split: M-B11a is the coarse "the whole teardown call goes" and
# M-B11b is the ticket's literal "it does not detach".
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. The claims below are all of the shape
# that stays green whatever the code does -- "the filters went on", "a datagram was sent" -- so
# each of them is made to fail on purpose here, and each names the ONE test case that must go
# red. A mutation whose named case stays green is a survivor and fails this gate.
#
# 🔴 THE MUTANT IS A COPY. Every mutation is applied to a copy of p4_proxy under a temp dir and
# the tests run there. Nothing under p4_proxy/ is written -- another session may be executing
# those files right now -- and all four sources plus four test files are re-hashed at the end.
# `setting/` and `tools/` are LINKED rather than copied: the models are several megabytes, the
# converter is read (test_app_package reads `DEFAULT_LINK_BPS` out of it, which is the point of
# that cell), and nothing here mutates either.
#
# 🔴 TWO MUTATIONS DELIBERATELY NOT HERE, because each would be EQUIVALENT in this tree and a
# gate that reports a survivor for an unkillable mutant teaches people to ignore it:
#
#   * "one psample group per switch instead of one for the fabric". Direction already arrives in
#     which attribute the kernel set (IIFINDEX vs OIFINDEX, measured 2026-09-17), and the ifindex
#     already names the switch -- so a per-switch group carries nothing the sample does not carry
#     already, and every assertion in the suite would hold either way. What IS asserted is that a
#     sample from a group this fabric did not plan is dropped and COUNTED (M-B14).
#   * "LINK_SUB_AGENT_ID back to 0". The kernel keys on AgentKey{agentIP, port} and does not read
#     the sub-agent id at all, so nothing downstream can tell. The constant is pinned by a plain
#     assertion (test_this_path_says_it_is_sub_agent_one) rather than by a mutation, because what
#     it buys is an operator reading a capture, not a behaviour.
#
# Usage:  tests/shell/mutate_link_telemetry.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_link_telemetry.sh
# Assumes: nothing about the cwd.
# Exit:    0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#          baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LINKTEL="$REPO/p4_proxy/mininet/link_telemetry.py"
EMITTER="$REPO/p4_proxy/mininet/psample_sflow_emitter.py"
PKG="$REPO/p4_proxy/mininet/app_package.py"
TESTBED="$REPO/p4_proxy/mininet/p4_testbed_topo.py"
TEST_LINKTEL="$REPO/p4_proxy/tests/test_link_telemetry.py"
TEST_EMITTER="$REPO/p4_proxy/tests/test_psample_sflow_emitter.py"
TEST_BRINGUP="$REPO/p4_proxy/tests/test_fabric_bring_up.py"
TEST_PKG="$REPO/p4_proxy/tests/test_app_package.py"

MODULES="tests.test_link_telemetry tests.test_psample_sflow_emitter \
tests.test_fabric_bring_up tests.test_app_package"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory. Override with PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-linktel-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
ln -s "$REPO/setting" "$BK/setting"
ln -s "$REPO/tools" "$BK/tools"

BASE_LINKTEL=$(sha256sum "$LINKTEL" | cut -d' ' -f1)
BASE_EMITTER=$(sha256sum "$EMITTER" | cut -d' ' -f1)
BASE_PKG=$(sha256sum "$PKG" | cut -d' ' -f1)
BASE_TESTBED=$(sha256sum "$TESTBED" | cut -d' ' -f1)
BASE_TEST_LINKTEL=$(sha256sum "$TEST_LINKTEL" | cut -d' ' -f1)
BASE_TEST_EMITTER=$(sha256sum "$TEST_EMITTER" | cut -d' ' -f1)
BASE_TEST_BRINGUP=$(sha256sum "$TEST_BRINGUP" | cut -d' ' -f1)
BASE_TEST_PKG=$(sha256sum "$TEST_PKG" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self -- a .pyc
# is revalidated against (mtime-in-SECONDS, size), and two same-size mutants written in one
# second are exactly that trap.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    # 🔴 A SUITE THAT DID NOT FINISH IS NOT A VERDICT, in either direction. `timeout 300`
    # returns 124, and unittest prints its `FAIL: <name>` section at the END -- so a mutant that
    # hangs the run produces no named failure and would be scored a survivor of nothing.
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-70s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-70s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is
# not checking (finding #28).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    mkdir -p "$d/p4_src"
    cp -r "$REPO/p4_proxy/p4_src/build" "$d/p4_src/" 2>/dev/null
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
mkdir -p "$base/p4_src"; cp -r "$REPO/p4_proxy/p4_src/build" "$base/p4_src/" 2>/dev/null
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | /usr/bin/grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- section 2.2: which port, which direction ------------------------------------------------

# The kernel credits a link from the RECEIVING switch's ingress samples, so an egress filter on
# an inter-switch port double-counts that cable. The one direction with no receiving switch is
# switch->host, which is paid out of the egress bank.
m=$(mutant m_b1 "$LINKTEL" \
    '                                  ingress=True, egress=(dpid, port) in host_facing))' \
    '                                  ingress=True, egress=True))')
report "M-B1: every port gets an egress filter, so every inter-switch link is double-counted" "$m" \
       "test_ingress_on_every_port_and_egress_on_host_facing_ports_only"

# MEASURED 2026-09-17: psample writes IIFINDEX/OIFINDEX with nla_put_u16(). A map keyed on the
# full ifindex works on a freshly booted machine and stops working on one that has been up long
# enough to pass 65535 -- and the collision check that protects the map stops checking anything.
m=$(mutant m_b2 "$LINKTEL" \
    '            key = ifindex & IFINDEX_MASK' \
    '            key = ifindex  # MUTANT: all 32 bits, so nothing can ever collide')
report "M-B2: the ifindex map keeps all 32 bits, so the aliasing check never fires" "$m" \
       "test_the_map_is_keyed_on_the_low_sixteen_bits_psample_reports"

# psample multicasts per network namespace. A switch in its own one is a fabric that brings up
# clean and reports zero link usage for ever, which is indistinguishable from an idle network.
m=$(mutant m_b3 "$LINKTEL" \
    '        if getattr(switch, "inNamespace", False):' \
    '        if False:  # MUTANT: a switch in its own netns is accepted')
report "M-B3: the namespace check is gone, so a silent fabric passes bring-up" "$m" \
       "test_a_switch_in_its_own_namespace_is_refused"

# --- section 2.5: the emitter's life ---------------------------------------------------------

# The filters are ON. The kernel is sampling one packet in 256 off every switch veth and
# multicasting it to a group nobody joined; every other line of the bring-up reads success.
m=$(mutant m_b4 "$TESTBED" \
    '            plan=plan, proc=proc, fatal=True,' \
    '            plan=plan, proc=proc, fatal=False,  # MUTANT: a dead emitter is a warning')
report "M-B4: an emitter that died is not fatal, so a silent fabric reports success" "$m" \
       "test_a_fabric_whose_emitter_exited_is_refused"

# `net.stop()` deletes the veths, so a teardown that skips the detach leaves the qdiscs to be
# removed only by accident -- and leaves the manifest naming a pid nothing will signal.
#
# 🔴 TWO MUTANTS, BECAUSE THE FIRST IS COARSER THAN THE TICKET'S. M-B11a removes the WHOLE
# call -- emitter, filters and manifest together -- which a suite could catch on any one of the
# three; the ticket's M-B11 is "tear_down does not detach" alone. M-B11b is that one, at the
# line that actually detaches, with the emitter still being stopped and the manifest still
# removed, so only the detach can be what redders it.
m=$(mutant m_b11a "$TESTBED" \
    '    link_telemetry.shut_down(link_manifest_path, report=report)' \
    '    pass  # MUTANT: the emitter and the filters are left behind')
report "M-B11a (coarse): tear_down neither stops the emitter nor removes the filters" "$m" \
       "test_the_qdiscs_come_off_before_the_net_is_stopped"

m=$(mutant m_b11b "$LINKTEL" \
    '    removed = detach(interfaces, run=run, report=report)' \
    '    removed = []  # MUTANT: the emitter is stopped, the filters stay on')
report "M-B11b (ticket-literal): teardown stops the emitter but never detaches" "$m" \
       "test_it_stops_the_pid_the_manifest_names_and_detaches_every_interface"

# --- section 2.1: the three layers of the knob -----------------------------------------------

m=$(mutant m_b5 "$PKG" \
    '    if knob is not None and knob != TELEMETRY_AUTO:' \
    '    if False:  # MUTANT: the knob is read and then ignored')
report "M-B5: --telemetry writes a knob nothing reads" "$m" \
       "test_the_knob_outranks_the_packages_own_declaration"

# A tutorials program has no packet_in header and no clone session, so cooperative telemetry on
# it produces nothing at all -- not an error, an empty twin.
m=$(mutant m_b6 "$PKG" \
    '    return (TELEMETRY_COOPERATIVE if package.pipeline_is_ndtwin(dpid, base_dir)
            else TELEMETRY_LINK)' \
    '    return TELEMETRY_COOPERATIVE  # MUTANT: auto never reaches the link path')
report "M-B6: auto answers cooperative for a foreign pipeline, which measures nothing" "$m" \
       "test_auto_sends_a_foreign_pipeline_down_the_link_path"

# --- section 2.4: G2-C -----------------------------------------------------------------------

# TCLink puts an htb qdisc on every interface it builds and a netem behind it. Every reading ever
# taken on this fabric was taken without them.
m=$(mutant m_b7 "$TESTBED" \
    '    if app_package.shaped_links(package):' \
    '    if True:  # MUTANT: every fabric is built with TCLink')
report "M-B7: TCLink is used for a fabric nobody asked to shape" "$m" \
       "test_a_package_that_shapes_nothing_is_also_the_call_it_has_always_been"

# Mininet's `bw` is megabits per second. Handing it 500000 asks for a 500 Gbit/s link on a cable
# whose whole purpose is to be a 0.5 Mbit/s bottleneck -- and ecn/mri then read green forever.
m=$(mutant m_b8 "$PKG" \
    '        bw_mbps = None if bps == DEFAULT_LINK_BPS else bps / 1e6' \
    '        bw_mbps = None if bps == DEFAULT_LINK_BPS else bps  # MUTANT: bps, not Mbit/s')
report "M-B8: bandwidth reaches Mininet in bits per second, so no bottleneck is built" "$m" \
       "test_a_bottleneck_is_reported_in_megabit_with_its_endpoints"

# --- section 2.2: the sample the emitter synthesises -----------------------------------------

# The kernel banks a sample with inputPort 0 and a non-zero outputPort as egress-only and credits
# it to the switch->host edge. A port number here books the same bytes against host->switch.
m=$(mutant m_b9 "$EMITTER" \
    '        ingress_port=port if ingress else 0,' \
    '        ingress_port=port,  # MUTANT: an egress sample carries an ingress port')
report "M-B9: an egress sample is credited to the reverse edge" "$m" \
       "test_an_egress_sample_fills_the_egress_port_and_leaves_ingress_zero"

# `trunc 128` caps DATA whatever the packet was, and the kernel multiplies frameLength by the
# sampling rate. The captured length under-reports a 1500-byte packet by ~12x, plausibly.
m=$(mutant m_b10 "$EMITTER" \
    '        frame_length=int(origsize),' \
    '        frame_length=len(decoded.get("data") or b""),  # MUTANT: the captured length')
report "M-B10: link usage is computed from the truncated length, so the whole fabric reads low" "$m" \
       "test_the_frame_length_is_origsize_and_not_the_captured_length"

# --- round 2: the three claims the judge found were made in prose only ------------------------

# 🔴 F1. `bring_up` is not inside either main's `except ValueError` -- only `plan_fabric` is --
# and by the time this fires the net has been built and STARTED. A bare raise unwinds past a
# `tear_down` that is only ever reached through the `fatal` return: a running fabric, no
# manifest, whatever filters got attached, and the traceback in a tmux pane that stops existing
# when the process does.
m=$(mutant m_b18 "$TESTBED" \
    '    except ValueError as exc:
        # 🔴 A REFUSAL HERE IS AN ABORT PATH' \
    '    except KeyError as exc:  # MUTANT: the refusal unwinds out of bring_up
        # 🔴 A REFUSAL HERE IS AN ABORT PATH')
report "M-B18 (F1): a refused link telemetry plan unwinds instead of becoming a verdict" "$m" \
       "test_the_bridge_stops_the_net_it_started"

# 🔴 F2. TICKET-P3 section 2.1 says a word outside the domain refuses the START. Read for the
# first time inside `bring_up`, that refusal lands after `reset_for_bring_up` has destroyed the
# fabric that was running and after `net.start()` has built its replacement.
m=$(mutant m_b19 "$TESTBED" \
    '    telemetry_knob = app_package.read_telemetry_knob()' \
    '    telemetry_knob = None  # MUTANT: the knob is not validated in the pre-flight')
report "M-B19 (F2): a bad telemetry knob is discovered only after the old fabric is destroyed" "$m" \
       "test_a_telemetry_knob_outside_the_domain_is_refused_in_the_pre_flight"

# Attach first because a `tc` that fails is then a failure with no process to clean up: the
# recovery detaches, and it cannot stop an emitter whose pid was never written down. Start the
# emitter first and a mid-way attach failure leaves a process holding a psample group that
# nothing -- not this teardown, not the next bring-up -- can address.
m=$(mutant m_b17 "$TESTBED" \
    '        link_telemetry.attach(plan, run=tc_run)
        proc = link_telemetry.start_emitter(manifest_path, popen=emitter_popen)' \
    '        proc = link_telemetry.start_emitter(manifest_path, popen=emitter_popen)
        link_telemetry.attach(plan, run=tc_run)  # MUTANT: after the emitter')
report "M-B17: the emitter is started before the filters, so a failed attach orphans it" "$m" \
       "test_the_filters_are_on_before_the_emitter_is_started"

# The manifest carries the pid, and the pid is the only handle anything downstream ever gets on
# that process. Written first it records None, and `ndt status`, `verify_p4`, teardown and the
# next bring-up all have nothing to address.
m=$(mutant m_b22 "$TESTBED" \
    '        proc = link_telemetry.start_emitter(manifest_path, popen=emitter_popen)
        link_telemetry.write_manifest(plan, getattr(proc, "pid", None), path=manifest_path)' \
    '        link_telemetry.write_manifest(plan, None, path=manifest_path)  # MUTANT: first
        proc = link_telemetry.start_emitter(manifest_path, popen=emitter_popen)')
report "M-B22: the manifest is written before the emitter exists, so it records no pid" "$m" \
       "test_the_manifest_is_written_after_the_emitter_so_it_can_carry_its_pid"

# Everything else `reset_for_bring_up` reaps is announced -- the switch reap prints what it
# took, the port check names the holder -- because "something killed my process" is exactly the
# kind of fact that is unanswerable afterwards.
m=$(mutant m_b20 "$TESTBED" \
    '    link_telemetry.shut_down(report=print)' \
    '    link_telemetry.shut_down()  # MUTANT: kill the stale emitter in silence')
report "M-B20: a previous run's emitter is killed without a word" "$m" \
       "test_a_previous_runs_emitter_is_stopped_before_a_new_fabric_is_built"

# The float-subtraction pattern `p4_testbed_topo` carries a warning about beside its own grace
# loop: 0.5 s in 0.1 s steps is six iterations, not five, so the wait is longer than it says.
m=$(mutant m_b21 "$LINKTEL" \
    '    for _step in range(int(math.ceil(grace_s / EMITTER_POLL_INTERVAL_S))):
        if not is_emitter(pid):' \
    '    _deadline = grace_s  # MUTANT: float subtraction, whose trip count nobody can state
    while _deadline > 0:
        _deadline -= EMITTER_POLL_INTERVAL_S
        if not is_emitter(pid):')
report "M-B21: the SIGTERM grace loop counts by subtracting floats" "$m" \
       "test_one_that_will_not_go_is_killed_after_the_grace_period"

# --- three the ticket does not list ----------------------------------------------------------

# Linux recycles pids and this teardown runs as root. `pkill -f` is forbidden in this repo, and a
# bare `os.kill` on a number recorded minutes ago is no better -- it is the same mistake with a
# smaller blast radius only by luck.
m=$(mutant m_b13 "$LINKTEL" \
    '    if not pid or not is_emitter(pid):' \
    '    if not pid:  # MUTANT: signal the number, whatever holds it now')
report "M-B13: the emitter pid is signalled without checking it is still the emitter" "$m" \
       "test_a_pid_that_is_no_longer_the_emitter_is_not_signalled"

# Somebody else's `action sample` filter on this machine reporting into the same group. Its
# ifindex is not in this fabric's map either -- this is the first of two nets, and which counter
# caught it is the difference between "a stray filter" and "our map is wrong".
m=$(mutant m_b14 "$EMITTER" \
    '                if ports.group is not None and decoded.get("group") != ports.group:' \
    '                if False:  # MUTANT: every group is this fabric\x27s')
report "M-B14: samples from another filter's group are counted as this fabric's" "$m" \
       "test_a_sample_from_another_groups_filter_is_dropped_and_counted"

# A fabric with half its filters attached measures part of itself and reports the rest as zero,
# which is the same picture as a half-dead fabric and is not distinguishable from one afterwards.
m=$(mutant m_b15 "$LINKTEL" \
    '        if rc:' \
    '        if False:  # MUTANT: a tc that failed is a tc that worked')
report "M-B15: a tc command that failed is ignored, so the fabric measures half of itself" "$m" \
       "test_a_tc_that_failed_stops_the_bring_up_rather_than_half_measuring"

# `topo_log.Tee` is an FD-level tee whose `stop()` ends its pump by letting the LAST write end
# of the pipe go, and whose own comment states the invariant: this process owns them all. An
# emitter inheriting fd 2 makes that false -- `stop()` burns its five-second join on every
# bring-up and the statistics line lands on the operator's NTG prompt for the life of the fabric.
m=$(mutant m_b16 "$LINKTEL" \
    '    handle = (opener or open)(log_path or LINK_TELEMETRY_LOG, "wb")' \
    '    return popen(argv)  # MUTANT: inherit the topology'"'"'s descriptors
    handle = (opener or open)(log_path or LINK_TELEMETRY_LOG, "wb")')
report "M-B16: the emitter inherits fds 1 and 2, so it holds the tee's pipe open" "$m" \
       "test_it_is_launched_onto_its_own_file_and_this_process_keeps_no_descriptor"

# --- negative controls -----------------------------------------------------------------------
#
# A gate that reddens on anything is not a gate. These are edits that change no behaviour these
# suites specify, and each must leave the whole run GREEN -- which `report` would score as a
# SURVIVOR, so they are run separately and the survivor count is not touched.

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-70s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-70s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
}

m=$(mutant n1 "$LINKTEL" \
    'def _commands(planned):' \
    '# MUTANT: a comment, and nothing else.
def _commands(planned):')
control "N1 (control): a comment-only edit where the tc commands are composed" "$m" \
        "the whole suite stays green"

m=$(mutant n2 "$EMITTER" \
    '    iif, oif = decoded.get("iifindex"), decoded.get("oifindex")' \
    '    # MUTANT: a comment, and nothing else.
    iif, oif = decoded.get("iifindex"), decoded.get("oifindex")')
control "N2 (control): a comment-only edit where a sample direction is decided" "$m" \
        "the whole suite stays green"

echo
[[ "$(sha256sum "$LINKTEL" | cut -d' ' -f1)" == "$BASE_LINKTEL" ]] || { echo "🔴 baseline CHANGED -- link_telemetry.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$EMITTER" | cut -d' ' -f1)" == "$BASE_EMITTER" ]] || { echo "🔴 baseline CHANGED -- psample_sflow_emitter.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$PKG" | cut -d' ' -f1)" == "$BASE_PKG" ]] || { echo "🔴 baseline CHANGED -- app_package.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TESTBED" | cut -d' ' -f1)" == "$BASE_TESTBED" ]] || { echo "🔴 baseline CHANGED -- p4_testbed_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_LINKTEL" | cut -d' ' -f1)" == "$BASE_TEST_LINKTEL" ]] || { echo "🔴 baseline CHANGED -- test_link_telemetry.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_EMITTER" | cut -d' ' -f1)" == "$BASE_TEST_EMITTER" ]] || { echo "🔴 baseline CHANGED -- test_psample_sflow_emitter.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_BRINGUP" | cut -d' ' -f1)" == "$BASE_TEST_BRINGUP" ]] || { echo "🔴 baseline CHANGED -- test_fabric_bring_up.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PKG" | cut -d' ' -f1)" == "$BASE_TEST_PKG" ]] || { echo "🔴 baseline CHANGED -- test_app_package.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (4 sources, 4 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
