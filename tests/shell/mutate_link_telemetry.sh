#!/usr/bin/env bash
#
# Mutation gate for link-level telemetry: which veth gets a sampling filter and in which
# direction, the sixteen bits psample reports an ifindex in, the netns the emitter must be in,
# what a dead emitter means, the three layers of the telemetry knob, TCLink's on/off condition,
# the units bandwidth is expressed in, the direction a sample carries onto the wire, the length
# the kernel multiplies by the sampling rate, and the teardown that takes the filters off.
# TICKET-P3 section 4.3 (M-B1 .. M-B11), plus thirteen the ticket does not list -- six of them
# added in the live-fix round for section 9 ruling 19(1), the one defect only a real fabric
# could show -- -- four of them
# added in round 2 for the three claims the judge found were made in prose only (F1's abort
# path, F2's pre-flight, the attach/start/write ordering) -- and the reason each is here is
# written beside it. M-B11 is split: M-B11a is the coarse "the whole teardown call goes" and
# M-B11b is the ticket's literal "it does not detach".
#
# Five more on 2026-09-28, M-B49 .. M-B53: the root emitter's read, a manifest write that fails,
# a second hard link, and the teardown's `tc` half. Then M-B54 .. M-B56: a root reader facing
# another user's file, a document that does not parse, and a switch manifest never written; and
# M-B57, the same root reader one layer up, where `load_manifest` asks whose manifest it may use.
# Nine more for Adam's ruling K (2026-09-27), M-B29 .. M-B37: the pid the manifest names is ONE
# process -- the argv the launcher recorded, word for word, and the start time /proc gave it --
# not any process whose cmdline contains the emitter's file name. Eleven for the judge's KJL B2
# round on an intermediate revision of this change, M-B38 .. M-B48: the launcher's shape always,
# the identity all-or-nothing, the pid an int above 1, and a manifest only from root or the
# reader's own user.
# [Co-developed with claude code -- Adam]
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
BRIDGE="$REPO/p4_proxy/mininet/ntg_bmv2_topo.py"
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
BASE_BRIDGE=$(sha256sum "$BRIDGE" | cut -d' ' -f1)
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
#
# 🔴 BOTH LINES, and the first version of this mutant taught me why. Removing only the
# `read_telemetry_knob()` call left the pre-flight still refusing, because the very next line
# resolves every switch's source and `telemetry_source()` reads the knob itself: the named cell
# stayed green and the gate called it a survivor, correctly. What the pre-flight buys is that
# EITHER of these runs before `reset_for_bring_up`; the mutant has to take the whole block.
m=$(mutant m_b19 "$TESTBED" \
    '    telemetry_knob = app_package.read_telemetry_knob()
    telemetry_sources = {dpid: app_package.telemetry_source(package, dpid) for dpid in dpids}' \
    '    telemetry_knob = None  # MUTANT: nothing reads the knob until bring_up does
    telemetry_sources = {}')
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
        # 🔴 THE IDENTITY IS TAKEN HERE, BEFORE ANYTHING POLLS `proc` (Adam 2026-09-27, ruling
        # K). Until it is waited on, the emitter is an unreaped child of this process, so its
        # pid cannot belong to anything else -- and this is the one read of its start time no
        # pid reuse can race. Every later reader compares against what is recorded here.
        # [Co-developed with claude code -- Adam]
        link_telemetry.write_manifest(plan, getattr(proc, "pid", None), path=manifest_path,
                                      identity=link_telemetry.emitter_identity(proc))' \
    '        link_telemetry.write_manifest(plan, None, path=manifest_path)  # MUTANT: first
        proc = link_telemetry.start_emitter(manifest_path, popen=emitter_popen)')
# (Re-anchored 2026-09-27: ruling K put the identity, and the comment saying why, between the
# two lines this mutant swaps. The mutant is the same one as before.)
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
        if not is_emitter(pid, **identity):' \
    '    _deadline = grace_s  # MUTANT: float subtraction, whose trip count nobody can state
    while _deadline > 0:
        _deadline -= EMITTER_POLL_INTERVAL_S
        if not is_emitter(pid, **identity):')
report "M-B21: the SIGTERM grace loop counts by subtracting floats" "$m" \
       "test_one_that_will_not_go_is_killed_after_the_grace_period"

# --- ruling 19(1): the only defect live found -------------------------------------------------
#
# `ndt down` reported "residue: /tmp/ndtwin_link_telemetry.json is still there and the pid it
# names (2386073) is gone" after every live run on 2026-09-19. `ndtwin-lab topo-stop` sends C-c
# to the tmux pane, waits ten seconds, then `kill-session`; Mininet's CLI catches
# KeyboardInterrupt and carries on by design, so the C-c did nothing, and the SIGHUP landed on
# a process whose `main()` was a bare `CLI(net)` followed by `tear_down(net)`. Python died
# between the two lines, `link_telemetry.shut_down` never ran, and the emitter -- in the same
# process group -- died of the same SIGHUP. The manifest outlived the process it names.

m=$(mutant m_b23 "$TESTBED" \
    '        CLI(net)
    finally:
        tear_down(net)' \
    '        CLI(net)
        tear_down(net)  # MUTANT: not a finally -- exactly the pre-2026-09-19 shape
    finally:
        pass')
report "M-B23 (19(1)): the teardown is not a finally, so a shutdown signal skips it" "$m" \
       "test_the_topology_script_tears_down_when_the_cli_is_cut_short"

m=$(mutant m_b24 "$TESTBED" \
    '    install_teardown_signal_handlers()
    try:' \
    '    pass  # MUTANT: SIGHUP keeps its default disposition and kills python outright
    try:')
report "M-B24 (19(1)): the topology script arms no handler, so the finally is never reached" "$m" \
       "test_the_handlers_are_armed_before_the_cli_is_entered"

m=$(mutant m_b25 "$BRIDGE" \
    '    testbed.install_teardown_signal_handlers()' \
    '    pass  # MUTANT: the entry point topo-start actually launches arms nothing')
report "M-B25 (19(1)): the bridge -- the main that really runs -- arms no handler" "$m" \
       "test_the_bridge_arms_them_too"

# `topo-stop` sends C-c and then SIGHUP ten seconds later, so the second one can land while the
# teardown the first asked for is still running. Re-raising there aborts it halfway and leaves
# exactly the residue this exists to remove.
m=$(mutant m_b26 "$TESTBED" \
    '        if fired:' \
    '        if False:  # MUTANT: every signal re-raises, including into the teardown')
report "M-B26: a second shutdown signal aborts the teardown the first one asked for" "$m" \
       "test_the_second_signal_does_not_interrupt_the_teardown_the_first_asked_for"

# 🔴 THIS ONE SURVIVED ONCE, AND THE GATE WAS RIGHT. With SIGHUP back at SIG_DFL, the cell
# that raises it at itself TERMINATED the test runner -- and unittest prints its failures at
# the END, so the run produced no output at all and the mutant scored a survivor of nothing.
# The cells now assert the disposition before raising (`raise_guarded`), so a missing handler
# is a red cell rather than a dead process. A test that can kill its own runner is not a test.
m=$(mutant m_b27 "$TESTBED" \
    'TEARDOWN_SIGNALS = ("SIGINT", "SIGTERM", "SIGHUP")' \
    'TEARDOWN_SIGNALS = ("SIGINT",)  # MUTANT: the one signal that was never the problem')
report "M-B27: only SIGINT is handled, and SIGINT is the one Mininet already swallows" "$m" \
       "test_all_three_signals_are_installed"

# The emitter is in the same tmux pane process group, so `kill-session`'s SIGHUP reaches it
# directly. With the default disposition it died mid-datagram with no last statistics line.
m=$(mutant m_b28 "$EMITTER" \
    'STOP_SIGNALS = ("SIGTERM", "SIGINT", "SIGHUP")' \
    'STOP_SIGNALS = ("SIGTERM", "SIGINT")  # MUTANT: SIGHUP kills it where it stands')
report "M-B28: the emitter does not handle the signal that actually kills it" "$m" \
       "test_all_three_stop_signals_are_installed"

# --- three the ticket does not list ----------------------------------------------------------

# Linux recycles pids and this teardown runs as root. `pkill -f` is forbidden in this repo, and a
# bare `os.kill` on a number recorded minutes ago is no better -- it is the same mistake with a
# smaller blast radius only by luck.
m=$(mutant m_b13 "$LINKTEL" \
    '    if not _is_a_signallable_pid(pid) or not is_emitter(pid, **identity):' \
    '    if not _is_a_signallable_pid(pid):  # MUTANT: signal the number, whatever holds it now')
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

# --- ruling K (Adam 2026-09-27): the pid the manifest names is ONE process, not a resemblance ----
#
# [Co-developed with claude code -- Adam]
# `stop_emitter` SIGTERMs and then SIGKILLs, as root, whatever `process_is_the_emitter` says yes
# to. It used to say yes to any process whose cmdline CONTAINED "psample_sflow_emitter.py" -- an
# editor, a grep, a tail, a test runner -- holding a recycled pid. The cells that kill these run
# REAL unprivileged processes this suite starts and reaps by their own Popen, with a kill that
# only records; the one real signal goes to the suite's own child, through a kill that refuses
# any other number.
#
# Judge KJL B2 (on an intermediate revision of this change): a recorded argv had REPLACED the
# launcher-shape check, and nothing looked at who wrote the manifest -- a file any local user can
# create in /tmp -- so a forged one carrying any process's argv and start time (both readable in
# /proc, which is not mounted hidepid by default) had root signal that process.
# M-B38 .. M-B48 are that round: the shape always, identity all-or-nothing, the pid check, and a
# manifest only from root or the reader's own user, mode without group/other write, no symlink.
#
# Equivalence, corrected (judge K-N2; the first version of this note was wrong -- `True == 1` and
# `list("ab") == ["a", "b"]` in Python):
#   * accepting a BOOL start time is NOT equivalent: it matches a process whose start time is 1.
#     It is M-B40, killed by test_a_bool_start_time_is_not_the_number_it_equals.
#   * accepting a STR start time is equivalent: a str never equals the int /proc gives.
#   * accepting a STR argv is equivalent ONLY because the launcher's shape is now required first:
#     list(<str>) is one character per word, and the shape's second word, a path ending in
#     psample_sflow_emitter.py, is never one character. test_a_string_argv_is_not_the_list_of_its_
#     characters holds the refusal without being able to say which check made it.

m=$(mutant m_b29 "$LINKTEL" \
    '    if not cmdline or not _is_the_launchers_shape(cmdline):' \
    '    if not cmdline or not any(os.path.basename(EMITTER_PATH) in w for w in cmdline):  # MUTANT')
report "M-B29 (K): the pre-ruling substring check is back, so a decoy is the emitter" "$m" \
       "test_a_process_that_only_mentions_the_emitter_is_not_the_emitter"

m=$(mutant m_b30 "$LINKTEL" \
    '    return (_is_an_argv(argv) and cmdline == list(argv)' \
    '    return (_is_an_argv(argv)  # MUTANT: any argv is the one the launcher recorded')
report "M-B30 (K): the recorded argv is never compared, so a same-named file elsewhere passes" "$m" \
       "test_the_same_file_name_at_another_path_is_not_the_recorded_emitter"

m=$(mutant m_b31 "$LINKTEL" \
    '            and _is_an_int(start_time) and process_start_time(pid, proc_root) == start_time)' \
    '            and _is_an_int(start_time))  # MUTANT: whenever it started, it is the one we launched')
report "M-B31 (K): the start time is never compared, so a reused pid is the emitter" "$m" \
       "test_a_pid_now_held_by_a_process_that_started_later_is_not_signalled"

m=$(mutant m_b32 "$LINKTEL" \
    '    fate = stop_emitter(document.get("pid"), kill=kill, is_emitter=is_emitter, sleep=sleep,
                        argv=document.get("argv"), start_time=document.get("start_time"))' \
    '    fate = stop_emitter(document.get("pid"), kill=kill, is_emitter=is_emitter, sleep=sleep)')
report "M-B32 (K): the teardown reads the pid and drops the identity recorded beside it" "$m" \
       "test_a_pid_now_held_by_a_process_that_started_later_is_not_signalled"

m=$(mutant m_b33 "$LINKTEL" \
    '        if not is_emitter(pid, **identity):
            return "term"' \
    '        if not is_emitter(pid):  # MUTANT: the grace loop judges some other process
            return "term"')
report "M-B33 (K): the grace loop asks without the identity the first question carried" "$m" \
       "test_every_question_it_asks_carries_the_recorded_identity"

m=$(mutant m_b34 "$TESTBED" \
    '                                      identity=link_telemetry.emitter_identity(proc))' \
    '                                      identity=None)  # MUTANT: a pid and nothing else')
report "M-B34 (K): the bring-up records a pid and no identity, so nothing can check it" "$m" \
       "test_the_manifest_records_the_emitters_argv_and_its_start_time"

m=$(mutant m_b35 "$LINKTEL" \
    '    _comm, closing, rest = raw.rpartition(b")")' \
    '    _comm, closing, rest = raw.partition(b")")  # MUTANT: the first ")", which may be in comm')
report "M-B35 (K): the start time is counted from a ')' inside the process name" "$m" \
       "test_the_start_time_is_field_twenty_two_even_after_a_comm_with_parentheses"

m=$(mutant m_b36 "$LINKTEL" \
    '    return process_is_the_emitter(document.get("pid"), proc_root=proc_root,
                                  argv=document.get("argv"),
                                  start_time=document.get("start_time"))' \
    '    return process_is_the_emitter(document.get("pid"), proc_root=proc_root)  # MUTANT')
report "M-B36 (K): ndt's and the proxy's reader compare less than the teardown does" "$m" \
       "test_the_document_reader_passes_the_recorded_identity"

m=$(mutant m_b37 "$LINKTEL" \
    '    if argv is None and start_time is None:
        return True' \
    '    if argv is None and start_time is None:
        return False  # MUTANT: no recorded identity, no emitter')
report "M-B37 (K): a manifest written before the ruling orphans the emitter it names" "$m" \
       "test_a_manifest_that_records_no_identity_still_stops_an_emitter_of_the_launchers_shape"

# --- judge KJL B2 (2026-09-27, an intermediate revision of this change) ----------------------

m=$(mutant m_b38 "$LINKTEL" \
    '    if not cmdline or not _is_the_launchers_shape(cmdline):' \
    '    if not cmdline or (argv is None and not _is_the_launchers_shape(cmdline)):  # MUTANT: the intermediate revision')
report "M-B38 (B2): a recorded argv replaces the shape check, so a forged manifest names anything" "$m" \
       "test_a_forged_manifest_holding_a_live_non_emitters_full_identity_sends_no_signal"

m=$(mutant m_b39 "$LINKTEL" \
    '            and _is_an_int(start_time) and process_start_time(pid, proc_root) == start_time)' \
    '            and (start_time is None or (_is_an_int(start_time)
                                        and process_start_time(pid, proc_root) == start_time)))  # MUTANT')
report "M-B39 (K-N7): an argv with no start time is checked against the half that is there" "$m" \
       "test_half_an_identity_is_never_a_match"

m=$(mutant m_b40 "$LINKTEL" \
    '            and _is_an_int(start_time) and process_start_time(pid, proc_root) == start_time)' \
    '            and isinstance(start_time, int) and process_start_time(pid, proc_root) == start_time)  # MUTANT')
report "M-B40 (K-N2): a recorded start time of true matches a process that started at tick 1" "$m" \
       "test_a_bool_start_time_is_not_the_number_it_equals"

m=$(mutant m_b41 "$LINKTEL" \
    '    if not _is_a_signallable_pid(pid) or not is_emitter(pid, **identity):' \
    '    if not pid or not is_emitter(pid, **identity):  # MUTANT: "pid": true is pid 1')
report "M-B41 (B2): stop_emitter signals int(True), which is init, when the predicate says yes" "$m" \
       "test_pid_true_is_never_signalled_even_when_the_predicate_says_yes"

m=$(mutant m_b42 "$LINKTEL" \
    '    if not _is_a_signallable_pid(pid):
        return False
    cmdline = _read_cmdline(pid, proc_root)' \
    '    cmdline = _read_cmdline(pid, proc_root)  # MUTANT: a bool, 0 or 1 is looked up')
report "M-B42 (B2): the predicate looks up /proc/1 for a pid of true, 1 or 0" "$m" \
       "test_init_a_bool_and_a_process_group_are_never_the_emitter"

m=$(mutant m_b43 "$LINKTEL" \
    '    if st.st_uid not in (0, euid):' \
    '    if False:  # MUTANT: a manifest anybody created is acted on')
report "M-B43 (B2): a manifest owned by another uid is acted on" "$m" \
       "test_a_manifest_owned_by_another_uid_is_refused"

m=$(mutant m_b44 "$LINKTEL" \
    '    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):' \
    '    if False:  # MUTANT: anybody may have written its contents')
report "M-B44 (B2): a group- or other-writable manifest is acted on" "$m" \
       "test_a_group_or_other_writable_manifest_is_refused"

m=$(mutant m_b45 "$LINKTEL" \
    '        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)' \
    '        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)  # MUTANT: follow links')
report "M-B45 (B2): a symlink at the manifest's name is followed to whatever it points at" "$m" \
       "test_a_symlinked_manifest_is_refused"

m=$(mutant m_b46 "$LINKTEL" \
    '        if report:
            report(f"link telemetry: {problem} -- nothing was signalled, no filter was removed, "' \
    '        if False:  # MUTANT: refused in silence
            report(f"link telemetry: {problem} -- nothing was signalled, no filter was removed, "')
report "M-B46 (B2): the teardown refuses a manifest and does not say why" "$m" \
       "test_a_group_or_other_writable_manifest_is_refused"

m=$(mutant m_b47 "$LINKTEL" \
    '    if not stat.S_ISREG(st.st_mode):' \
    '    if False:  # MUTANT: a FIFO or a directory is read as a manifest')
report "M-B47 (B2): something that is not a regular file is read as a manifest" "$m" \
       "test_a_fifo_at_the_name_is_refused_and_does_not_hang_the_reader"

m=$(mutant m_b48 "$LINKTEL" \
    '    if argv is None or started is None:
        return {"argv": None, "start_time": None}' \
    '    if argv is None and started is None:  # MUTANT: half an identity is recorded
        return {"argv": None, "start_time": None}')
report "M-B48 (K-N7): a launch whose start time is unreadable records half an identity" "$m" \
       "test_a_launch_whose_start_time_cannot_be_read_records_no_identity_at_all"

# NOT here, and why: dropping O_NONBLOCK would make the FIFO cell block in open() -- the gate
# would score that HUNG, a survivor of nothing -- so O_NONBLOCK is held by that cell's own
# termination (it returns) rather than by a mutant.

# --- the other readers of the file, and the write (2026-09-28) ---------------------------------
#
# [Co-developed with claude code -- Adam]
# The root emitter starts BEFORE write_manifest replaces whatever is at the name, and a file the
# teardown refused is left there on purpose -- so the emitter must refuse it too. A manifest that
# could not be written is fatal, and the emitter already launched for it is stopped. A second
# hard link is refused. And the teardown's `tc qdisc del` half: an untrusted file detaches nothing.

m=$(mutant m_b49 "$EMITTER" \
    '            document, problem = loader(path)' \
    '            document, problem = json.load(open(path)), None  # MUTANT: the plain open it was')
report "M-B49: the root emitter reads whatever is at the manifest's name" "$m" \
       "test_a_group_writable_file_at_the_name_is_refused_with_the_reason"

m=$(mutant m_b50 "$LINKTEL" \
    '        raise LinkTelemetryError(
            f"could not write the link telemetry manifest to {path}: {e}. The emitter reads its "' \
    '        print(f"WARNING: could not write the link telemetry manifest to {path}: {e}")
        return document  # MUTANT: a warning, and the bring-up carries on
        raise LinkTelemetryError(
            f"could not write the link telemetry manifest to {path}: {e}. The emitter reads its "')
report "M-B50: a link manifest that could not be written is a warning again" "$m" \
       "test_the_bring_up_is_fatal_and_says_why"

m=$(mutant m_b51 "$TESTBED" \
    '        if proc is not None:
            link_telemetry.stop_launched_emitter(proc)' \
    '        if False:  # MUTANT: the emitter no manifest names is left running
            link_telemetry.stop_launched_emitter(proc)')
report "M-B51: a bring-up that fails after the launch leaves the emitter running" "$m" \
       "test_the_emitter_it_launched_is_stopped_and_the_filters_come_off"

m=$(mutant m_b52 "$LINKTEL" \
    '    if st.st_nlink != 1:' \
    '    if False:  # MUTANT: a second hard link is the manifest too')
report "M-B52: a hard link to a root-owned file is trusted as the manifest" "$m" \
       "test_a_hard_link_to_the_manifest_is_not_the_manifest"

m=$(mutant m_b54 "$LINKTEL" \
    '    if st.st_uid not in (0, euid):' \
    '    if euid and st.st_uid not in (0, euid):  # MUTANT: a root reader trusts any owner')
report "M-B54: root -- the reader this check exists for -- trusts a file any user owns" "$m" \
       "test_a_root_reader_refuses_a_file_another_user_owns"

# M-B54 one layer up: `manifest_distrust` intact, and `load_manifest` skipping it for euid 0. The
# cell above calls `manifest_distrust` directly and cannot see this; the one that does puts euid
# 0 in front of a whole teardown through `_geteuid`. [Co-developed with claude code -- Adam]
m=$(mutant m_b57 "$LINKTEL" \
    '        why = manifest_distrust(_fstat(fd), _geteuid())' \
    '        why = manifest_distrust(_fstat(fd), _geteuid()) if _geteuid() else None  # MUTANT: root trusts any owner')
report "M-B57: a root teardown acts on a manifest any user owns (load_manifest skips the check)" "$m" \
       "test_a_root_teardown_refuses_a_manifest_another_user_owns"

m=$(mutant m_b55 "$LINKTEL" \
    '    except (OSError, ValueError) as exc:
        return None, f"{path} cannot be read: {exc}"' \
    '    except OSError as exc:  # MUTANT: a document that does not parse escapes as an exception
        return None, f"{path} cannot be read: {exc}"')
report "M-B55: a manifest that does not parse raises out of every reader" "$m" \
       "test_reading_a_corrupt_manifest_is_not_an_error_either"

m=$(mutant m_b56 "$TESTBED" \
    '    if manifest_problem:
        # Fatal, like a link-telemetry manifest' \
    '    if False:  # MUTANT: a switch manifest that was not written is a warning again
        # Fatal, like a link-telemetry manifest')
report "M-B56: a switch manifest that could not be written leaves the bring-up healthy" "$m" \
       "test_a_switch_manifest_that_cannot_be_written_is_fatal"

m=$(mutant m_b53 "$LINKTEL" \
    '    document, problem = load_manifest(path)' \
    '    document, problem = (json.load(open(path)) if os.path.lexists(path) else None), None  # MUTANT')
report "M-B53: the teardown reads an untrusted manifest and detaches what it lists" "$m" \
       "test_an_untrusted_manifest_detaches_nothing"

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
[[ "$(sha256sum "$BRIDGE" | cut -d' ' -f1)" == "$BASE_BRIDGE" ]] || { echo "🔴 baseline CHANGED -- ntg_bmv2_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_LINKTEL" | cut -d' ' -f1)" == "$BASE_TEST_LINKTEL" ]] || { echo "🔴 baseline CHANGED -- test_link_telemetry.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_EMITTER" | cut -d' ' -f1)" == "$BASE_TEST_EMITTER" ]] || { echo "🔴 baseline CHANGED -- test_psample_sflow_emitter.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_BRINGUP" | cut -d' ' -f1)" == "$BASE_TEST_BRINGUP" ]] || { echo "🔴 baseline CHANGED -- test_fabric_bring_up.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PKG" | cut -d' ' -f1)" == "$BASE_TEST_PKG" ]] || { echo "🔴 baseline CHANGED -- test_app_package.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (5 sources, 4 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
