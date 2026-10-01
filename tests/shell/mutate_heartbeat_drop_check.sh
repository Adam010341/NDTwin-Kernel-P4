#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_heartbeat_drop_check.py -- tools/test_workflow/
# heartbeat_drop_check.py, the offline check that decides whether the heartbeat may start on an
# external control plane (Adam, 09-28: default-safe, not default-on).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation takes away one thing the check must do and names the check(s) that must go red for
# it. A mutation that will not apply, whose anchor is not unique, that does not compile, or whose
# named check stays green is a SURVIVOR. And every check of the suite must go red under at least
# one mutation, the controls named below excepted: the gate keeps each mutant's whole run and
# names, by position, any check no mutation turned red.
# The tool is never written: mutants are copies in a repo-shaped directory (the tool finds
# p4_proxy/mininet beside itself), reached through CHECK_UNDER_TEST, and its sha256 is compared at
# the end; the N-E mutants are copies of ndt, reached through NDT_UNDER_TEST (section 9 of the
# suite sources it). Every mutant run launches the real stock simple_switch, as the suite does
# (NDT_HB_CHECK_BMV2 and NDT_HB_CHECK_FABRIC_BMV2 pass through).
#
# [Co-developed with claude code -- Adam] 🔴 NO MUTANT LAUNCHES A SWITCH THAT BREAKS THE
# ORCHESTRATOR'S CONDITIONS (the round-4 review's M-4: D16/D16b/D17/D18 launched 64 of them). The
# suite asserts argv on a recorder and sends every launch through its guard, which refuses one
# that breaks a condition; the gates' wrapper refuses it again and the tripwire gate fails on it.
#
# [Co-developed with claude code -- Adam] A mutant whose suite run did not end in its summary line
# (a traceback, a timeout -- D10's ProcessLookupError in round 4) keeps its whole output in
# $HBDROP_KEEP (default ${TMPDIR:-/tmp}/hbdrop-mutate-kept-<time>), and the path is printed.
#
# Run:  bash tests/shell/mutate_heartbeat_drop_check.sh
# Exit: 0 every mutation caught and every non-control check seen red; 1 a survivor, or a check no
#       mutation turned red; 2 refused (baseline red); 3 the tool or ndt changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/tools/test_workflow/heartbeat_drop_check.py"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_heartbeat_drop_check.py"
[[ -r "$TOOL" && -r "$TEST" && -r "$NDT" ]] || { echo "refused: the tool, ndt or the suite is missing"; exit 2; }
BK="$(mktemp -d "${TMPDIR:-/tmp}/hbdrop-mutate-XXXXXX")"
KEEP="${HBDROP_KEEP:-${TMPDIR:-/tmp}/hbdrop-mutate-kept-$(date -u +%Y%m%dT%H%M%SZ)}"
trap 'rm -rf "$BK"' EXIT
BASE_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
NDT_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

#: Checks exempt from "seen red", each for a reason:
#:   * CONTROLS -- each proves its cell reached what it is about, and goes red only when something
#:     with nothing to do with the check breaks: "(the run under observation still judged)",
#:     "(that scan's rule, as the kernel has it)" (a pin on the kernel's source), "and it is still
#:     rc 0";
#:   * facts of the machine no mutation of the tool can change: "it runs as the caller, not root";
#:   * held by the EXECUTABLE's name, not by anything in the tool a mutant could flip without
#:     putting a process that other sessions' ndt count on this machine (comm `simple_switch_g`):
#:     "ndt's bmv2_count does not count it" -- and p4_testbed_topo's whole identity rule, which
#:     also needs the manifest's gRPC port ("nor does its identity rule take it for a switch");
#:     its argv[0] half is D16b's red.
#:   * [Co-developed with claude code -- Adam] round 5: "(the switch was found running before the
#:     signal)" and "(section 9's topo-start probe sees a running throwaway switch)" are each a
#:     cell's proof that it observed something, like the first one; "and its switch is gone" after
#:     a SIGTERM is held by TWO guards no single mutation removes -- check_program's `finally` and
#:     PR_SET_PDEATHSIG (D20 and D19 each take one away; the SIGKILL cell is PDEATHSIG's alone).
CONTROLS="  (the run under observation still judged)
  (that scan's rule, as the kernel has it)
  and it is still rc 0
🔴 it runs as the caller, not root
🔴 ndt's bmv2_count does not count it
  nor does its identity rule take it for a switch
  (the switch was found running before the signal)
  (section 9's topo-start probe sees a running throwaway switch)
🔴 and its switch is gone"

run_test() { CHECK_UNDER_TEST="$1" NDT_UNDER_TEST="${2:-$NDT}" timeout 900 python3 "$TEST" 2>&1; }
# keep_if_cut <label> <out> -- a suite run that did not reach its summary line is kept whole.
keep_if_cut() {
    tail -1 <<<"$2" | /usr/bin/grep -qE '^Ran [0-9]+ checks, [0-9]+ failed$' && return 0
    mkdir -p "$KEEP" && printf '%s\n' "$2" > "$KEEP/$(printf '%s' "$1" | cut -d: -f1).out"
    printf '           (its run did not reach the summary line -- kept: %s)\n' "$KEEP/$(printf '%s' "$1" | cut -d: -f1).out"
}

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$TOOL")"; BASE_RC=$?
printf '%s\n' "$BASE_OUT" > "$BK/base.out"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0
mutate() {   # mutate <old> <new> <label> <check that must go red>...
    # (the anchor first: tests/shell/check_gate_anchors.py reads a mutate()'s first argument as
    # its anchor, in the file the function body names)
    local old="$1" new="$2" label="$3" d out missing=()
    shift 3
    d="$BK/$(printf '%s' "$label" | cut -d: -f1)"; mkdir -p "$d/tools/test_workflow"
    ln -s "$REPO/p4_proxy" "$d/p4_proxy"
    if ! python3 - "$TOOL" "$d/tools/test_workflow/heartbeat_drop_check.py" "$old" "$new" <<'PY'
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src).read()
if a == b or s.count(a) != 1:
    print(f"ANCHOR:{s.count(a)}"); sys.exit(1)
open(dst, "w").write(s.replace(a, b))
PY
    then
        printf '  SURVIVED %-62s (anchor not unique or identity)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if ! python3 -m py_compile "$d/tools/test_workflow/heartbeat_drop_check.py" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not compile)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d/tools/test_workflow/heartbeat_drop_check.py")"
    printf '%s\n' "$out" > "$d/suite.out"
    keep_if_cut "$label" "$out"
    local want
    for want in "$@"; do
        /usr/bin/grep -qF -- "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%s)\n' "$label" "$(tail -1 <<<"$out")"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$label" "${missing[0]}"; SURVIVED=$((SURVIVED+1))
    fi
}

# mutate_ndt <old> <new> <label> <check>... -- the same, on a copy of ndt (section 9 sources it);
# the tool under test is the real one.
mutate_ndt() {
    local old="$1" new="$2" label="$3" d out missing=() want
    shift 3
    d="$BK/$(printf '%s' "$label" | cut -d: -f1)"; mkdir -p "$d"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    [[ -r "$REPO/tools/test_workflow/components.env" ]] && cp "$REPO/tools/test_workflow/components.env" "$d/"
    if ! python3 - "$NDT" "$d/ndt" "$old" "$new" <<'PY'
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src).read()
if a == b or s.count(a) != 1:
    print(f"ANCHOR:{s.count(a)}"); sys.exit(1)
open(dst, "w").write(s.replace(a, b))
PY
    then
        printf '  SURVIVED %-62s (anchor not unique or identity)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    if ! bash -n "$d/ndt" 2>/dev/null; then
        printf '  SURVIVED %-62s (the mutant does not parse)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$TOOL" "$d/ndt")"
    printf '%s\n' "$out" > "$d/suite.out"
    keep_if_cut "$label" "$out"
    for want in "$@"; do
        /usr/bin/grep -qF -- "  FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-62s (%s)\n' "$label" "$(tail -1 <<<"$out")"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-62s still green: %s\n' "$label" "${missing[0]}"; SURVIVED=$((SURVIVED+1))
    fi
}

# --- the three the orchestrator named (09-28): skip the check, punt as drop, ignore a flood --------
mutate '                answer = check_program(entry["json"], entry["ports"], entry["cpu_port"])' \
    '                answer = {"program": entry["json"], "program_sha256": entry["sha256"],
                          "verdict": "dropped", "reason": "not checked"}' \
    "D1: the check is skipped and every program passes" \
    "🔴 a package whose program floods it: rc 1"
mutate '                        bad.append(f"PUNTED to the CPU port {out}")' \
    '                        outcomes.append(f"PUNTED to the CPU port {out}")' \
    "D2: a frame punted to the CPU port counts as dropped" \
    "🔴 sent to the CPU port (not a data port): punted, NOT dropped"
mutate '                        bad.append(f"FORWARDED out of fabric port {out}")' \
    '                        outcomes.append(f"FORWARDED out of fabric port {out}")' \
    "D3: a frame forwarded out of a fabric port (a flood) counts as dropped" \
    "🔴 sent back out of a fabric port: NOT dropped"
# --- the second witness, and the rest of what does not drop it ----------------------------------
mutate '    leaked = {p: n for p, n in out_frames.items() if n}' \
    '    leaked = {}' \
    "D4: a frame in an output pcap is ignored" \
    "🔴 the log says dropped, the CPU port's pcap holds a frame: NOT dropped" "  a flood is seen in the pcaps too"
mutate 'REPORTING_PRIMITIVES = {"generate_digest": "a digest to the controller",' \
    'REPORTING_PRIMITIVES = {"generate_digest_never": "a digest to the controller",' \
    "D5: a digest to the controller is ignored" \
    "🔴 hb_digest: not_dropped" "🔴 dropped after a digest: NOT dropped"
mutate '                        "clone_ingress_pkt_to_egress": "a clone to a mirror session",' \
    '                        "clone_ingress_pkt_to_egress_never": "a clone to a mirror session",' \
    "D6: a clone's primitive is ignored" \
    "  said as 'A CLONE TO A MIRROR SESSION'"
mutate '                elif e.startswith("Cloning packet"):' \
    '                elif e.startswith("Cloning packet never"):' \
    "D6b: bmv2's own clone line is ignored" \
    "  a clone is seen in bmv2's own log too"
mutate '                elif e == "Multicast requested for packet":' \
    '                elif e == "Multicast requested for packet never":' \
    "D7: a multicast request is ignored" \
    "🔴 hb_mcast: not_dropped"
# --- unknown is never a drop ---------------------------------------------------------------------
mutate '            unknown.append(f"the frame injected on port {port} was never processed")' \
    '            pass' \
    "D8: a frame never processed is taken as dropped" \
    "🔴 a frame never processed: unknown, not dropped"
mutate '                unknown.append(f"the frame injected on port {port} has no logged fate "' \
    '                (f"the frame injected on port {port} has no logged fate "' \
    "D9: a copy of the frame with no logged fate is taken as dropped" \
    "🔴 a copy of the frame with no logged fate: unknown, though the original dropped"
mutate '        unknown.append("no output pcap for port(s) " + ", ".join(map(str, sorted(unreadable))))' \
    '        pass' \
    "D10: a missing output pcap is taken as empty" \
    "🔴 an output pcap that is not there: unknown"
mutate '        if exited_early and verdict != "not_dropped":' \
    '        if False:' \
    "D11: a switch that exited early is judged as if it had run" \
    "  saying the switch exited"
mutate '    rc = 1 if "not_dropped" in verdicts else 2 if "unknown" in verdicts else 0' \
    '    rc = 1 if "not_dropped" in verdicts else 0' \
    "D11b: could-not-tell exits 0" \
    "🔴 a package whose program bmv2 will not load: rc 2"
mutate '        out(f"heartbeat drop check: could not read the package ({type(exc).__name__}: {exc})")
        return 2, []' \
    '        out(f"heartbeat drop check: could not read the package ({type(exc).__name__}: {exc})")
        return 0, []' \
    "D11c: an unreadable package exits 0" \
    "🔴 an unreadable package: rc 2"
# --- the cache ------------------------------------------------------------------------------------
mutate '    if answer.get("verdict") not in ("dropped", "not_dropped"):
        return' \
    '    if False:
        return' \
    "D12: an UNKNOWN answer is cached" \
    "🔴 an UNKNOWN answer is not kept"
mutate '    same = (old.get("check_version") == CHECK_VERSION and old.get("ports") == entry["ports"]' \
    '    same = (old.get("check_version") == CHECK_VERSION and True' \
    "D13: a cached answer is reused for other ports" \
    "🔴 other ports are not the same question"
mutate '        answer = None if mismatch else cached(entry, version)' \
    '        answer = None' \
    "D13b: the cache is never read" \
    "🔴 the second run reads the first one's answer"
# --- not the lab ----------------------------------------------------------------------------------
mutate 'THRIFT_CANDIDATES = range(29400, 29500)' \
    'THRIFT_CANDIDATES = range(9091, 9191)' \
    "D14: the Thrift port is chosen inside the lab's" \
    "  and no candidate is one of them" "🔴 its Thrift port is outside the lab's"
mutate '                   (6343, 6344), (6633, 6634), (6653, 6654), (8000, 8001), (8080, 8082),' \
    '                   (6343, 6344), (6633, 6634), (6653, 6654), (8000, 8001), (8080, 8081),' \
    "D14b: the lab's port list leaves out the proxy's 8081" \
    "🔴 every port ports.sh names is one the check treats as the lab's"
mutate '        if outside_lab_ports(port) and is_free(port):' \
    '        if outside_lab_ports(port):' \
    "D15: a held port is chosen anyway" \
    "🔴 a candidate somebody holds is skipped"
mutate '        if not port_is_free(port):' \
    '        if False:' \
    "D15b: the port is not checked again right before the launch" \
    "🔴 checked free again right before the launch: taken there is UNKNOWN"
mutate 'ARGV0 = "ndt-hbdrop-bmv2"' \
    'ARGV0 = "simple_switch"' \
    "D16: the throwaway switch is named like a fabric switch" \
    "🔴 argv[0] is not a switch's name" "🔴 the kernel's capacity scan does not either (argv[0] does not start simple_switch)" \
    "🔴 every launch this suite asked for met the orchestrator's conditions"
mutate 'ARGV0 = "ndt-hbdrop-bmv2"' \
    'ARGV0 = "/usr/local/bmv2-fast/bin/simple_switch_grpc"' \
    "D16b: argv[0] is the fabric's own binary" \
    "🔴 the helper's sweep does not match it" "🔴 p4_testbed_topo's switch name is not its argv[0]" \
    "🔴 no argv element names simple_switch_grpc (ndt's running-binary line)"
mutate '                      "--notifications-addr", "ipc://notif.ipc",' \
    '' \
    "D17: its nanomsg socket goes where the fabric's do" \
    "🔴 its nanomsg socket is named relative to its own directory" "🔴 its nanomsg socket is in its own directory" \
    "🔴 every condition the gates' tripwire enforces holds for it"
mutate '        device_id = DEVICE_ID_BASE + os.getpid() % 90000' \
    '        device_id = 1' \
    "D18: its device id can be a fabric's" \
    "🔴 its device id is no fabric's (900000 and above)" "🔴 every launch this suite asked for met the orchestrator's conditions"
mutate '                                         preexec_fn=_die_with_parent, start_new_session=True)' \
    '                                         start_new_session=True)' \
    "D19: the switch outlives a checker killed outright" \
    "🔴 a checker killed outright takes its RUNNING switch with it"
mutate '        if self.proc.poll() is None:
            try:
                self.proc.terminate()' \
    '        if False:
            try:
                self.proc.terminate()' \
    "D20: the switch is never stopped" \
    "🔴 stopped by the time the check returns"
mutate '        shutil.rmtree(workdir, ignore_errors=True)' \
    '        pass' \
    "D21: its directory is left behind" \
    "  and its directory is gone"
# --- what is injected and what is planned -------------------------------------------------------------
mutate 'ETHERTYPE = 0x88B5' \
    'ETHERTYPE = 0x88B6' \
    "D22: the injected frame is not the daemon's" \
    "🔴 byte for byte the daemon's encode()" "  its ethertype, destination and length" \
    "  and the daemon decodes it as one of its own"
mutate '    for _host, dpid, port in topo_from_json.host_links(model):
        ports.setdefault(dpid, set()).add(port)' \
    '    for _host, dpid, port in ():
        ports.setdefault(dpid, set()).add(port)' \
    "D23: the hosts' ports are left out of the ports a frame could leave by" \
    "  one program, on all three switches"
mutate '    out(f"  limit: {LIMITS}")' \
    '    pass' \
    "D24: the limit is not said with the answer" \
    "  and the limit is said with the answer"
mutate '                        outcomes.append(f"sent to port {out}, which no switch of this fabric has "' \
    '                        bad.append(f"sent to port {out}, which no switch of this fabric has "' \
    "D25: a frame sent to a port no switch has is called not dropped" \
    "🔴 advanced_tunnel (p4runtime skeleton and solution): DROPPED" \
    "  sent to a port no switch of the fabric has: dropped"
mutate '                        outcomes.append(f"sent to port {out}, which no switch of this fabric has "' \
    '                        outcomes.append(f"sent to port {out} "' \
    "D25b: where a frame was sent to is not said" \
    "  sent to port 0, which no switch of the fabric has"
mutate '                elif e.startswith("Dropping packet at the end of"):
                    outcomes.append("dropped")' \
    '                elif e.startswith("Dropping packet at the end of"):
                    outcomes.append("")' \
    "D26: a drop is not said as one" \
    "  dropped by the program itself" "  said as 'port 1: dropped'"
mutate '    return ("dropped", "every injected frame was dropped: "' \
    '    return ("unknown", "every injected frame was dropped: "' \
    "D27: nothing is ever proven dropped" \
    "🔴 flowcache's solution: DROPPED" "🔴 the converted p4runtime package: rc 0" \
    "  the control: a program that drops it: dropped" \
    "  a dropped frame and empty pcaps: dropped"
mutate '        raise NotApplicable(f"{package_dir}: every switch runs NDTwin'"'"'s own pipeline")' \
    '        return []' \
    "D28: a package on NDTwin's pipeline is checked as if it ran its own" \
    "  a package on NDTwin's own pipeline: rc 3"
mutate '            problems.append(f"port {port}: {per_port[port]}")' \
    '            pass' \
    "D29: what bmv2 logged a program doing with it is not held against it" \
    "🔴 hb_digest: not_dropped" "🔴 hb_clone: not_dropped" "🔴 hb_mcast: not_dropped"
mutate '        return "not_dropped", "; ".join(problems), per_port' \
    '        return "dropped", "; ".join(problems), per_port' \
    "D30: what does not drop it passes anyway" \
    "🔴 hb_flood: not_dropped" "🔴 hb_punt: not_dropped" "🔴 a package whose program floods it: rc 1"
mutate '        answer.update(verdict=verdict, reason=reason, per_port={str(k): v for k, v in' \
    '        answer.update(verdict="dropped" if verdict == "unknown" else verdict, reason=reason, per_port={str(k): v for k, v in' \
    "D31: whatever the check could not tell is reported as dropped" \
    "🔴 a program bmv2 will not load: unknown"
# --- [Co-developed with claude code -- Adam] round 5 (the round-4 review's M-4, S-4, S-6) --------
mutate '        if verdict == "dropped" and not settled(packets, ports, other):' \
    '        if False:' \
    "D32: a run that did not settle can still be DROPPED" \
    "🔴 a run that never settles: unknown, though every frame it logged was dropped" "  saying it did not settle"
mutate '    if not any("end of all input files" in line for line in other):
        return False' \
    '    if False:
        return False' \
    "D33: settled before bmv2 has read its input to the end" \
    "🔴 not settled before bmv2 says its input files ended"
mutate '    if not set(injected) <= got:
        return False' \
    '    if False:
        return False' \
    "D33b: settled with an injected frame unread" \
    "🔴 not settled while an injected frame is unread"
mutate '    return all(fate(ev) for ev in packets.values())' \
    '    return True' \
    "D33c: settled with a copy that has no fate" \
    "🔴 not settled while a copy has no fate"
mutate '    return all(fate(ev) for ev in packets.values())' \
    '    return False' \
    "D33d: nothing ever settles" \
    "  settled: every frame read, every copy with a fate, the input at its end"
mutate '    return os.environ.get("NDT_HB_CHECK_BMV2") or DEFAULT_BMV2' \
    '    return DEFAULT_BMV2' \
    "D34: NDT_HB_CHECK_BMV2 is ignored (the gates' wrapper with it)" \
    "🔴 NDT_HB_CHECK_BMV2 names the switch it runs"
mutate 'DEFAULT_BMV2 = "/usr/local/bin/simple_switch"' \
    'DEFAULT_BMV2 = "/usr/local/bin/simple_switch_grpc"' \
    "D34b: the default is the gRPC build" \
    "  and the stock build is the default"
mutate '        self.attached = sorted(set(self.ports) | {cpu_port})' \
    '        self.attached = sorted(set(self.ports))' \
    "D35: the CPU port is not attached" \
    "🔴 the CPU port is attached as well (a punt has a port to leave by)"
mutate '    try:
        return _main(argv)
    except SystemExit:
        raise' \
    '    if True:
        return _main(argv)
    try:
        pass
    except SystemExit:
        raise' \
    "D36: a crash is Python's own traceback and rc 1" \
    "🔴 a crash of the check is rc 2" "  saying it crashed"
mutate '    if os.geteuid() == 0:
        # [Co-developed with claude code -- Adam] The orchestrator'"'"'s first condition (09-28): the' \
    '    if False:
        # [Co-developed with claude code -- Adam] The orchestrator'"'"'s first condition (09-28): the' \
    "D37: the command runs as root" \
    "🔴 run as root (euid 0): rc 2" "  saying it refuses"
mutate '        if os.geteuid() == 0:
            # [Co-developed with claude code -- Adam] The orchestrator'"'"'s first condition (09-28).' \
    '        if False:
            # [Co-developed with claude code -- Adam] The orchestrator'"'"'s first condition (09-28).' \
    "D37b: a switch is launched as root" \
    "🔴 and a launch as root is refused"
mutate '    if IMPORT_ERROR is not None:' \
    '    if False:' \
    "D38: modules it could not load are not said" \
    "  saying what it could not load"
mutate 'except Exception as _exc:  # noqa: BLE001 -- main() answers rc 2 with it, never a traceback'"'"'s rc 1
    IMPORT_ERROR = _exc' \
    'except ImportError as _exc:
    raise' \
    "D38b: a module it cannot load is a traceback" \
    "🔴 its own modules missing: rc 2"
mutate '        if not entry["ports"]:' \
    '        if False:' \
    "D39: a program with no port to inject on is planned anyway" \
    "🔴 a package whose switches the model gives no port: rc 3" "  saying there is no frame to inject"
mutate '    if not ports:
        answer.update(verdict="unknown", reason="no data port to inject a frame on: nothing was asked")' \
    '    if False:
        answer.update(verdict="unknown", reason="no data port to inject a frame on: nothing was asked")' \
    "D39b: no frame injected is a drop (vacuous)" \
    "🔴 a program with no data port to inject on: not dropped-by-default" "  saying nothing was asked"
mutate '    if version is None or fabric_version is None or version != fabric_version:' \
    '    if False:' \
    "D40: another bmv2 version than the fabric's is fine" \
    "🔴 a fabric on another bmv2 version: rc 2" "  saying the two are not the same switch" \
    "🔴 a fabric binary that answers no version: rc 2"
mutate '                    return line if os.path.isabs(line) else None' \
    '                    return None' \
    "D40b: the fabric's binary is not read from p4_testbed_topo's override" \
    "🔴 the fabric's binary is p4_testbed_topo's override when nothing overrides it"
mutate '    env = os.environ.get("NDT_HB_CHECK_FABRIC_BMV2")
    if env:
        return env' \
    '    env = None
    if env:
        return env' \
    "D40c: NDT_HB_CHECK_FABRIC_BMV2 is ignored" \
    "  naming both versions"
mutate '    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _raise_on_signal)' \
    '    for sig in ():
        signal.signal(sig, _raise_on_signal)' \
    "D41: a signal kills the check without its finally" \
    "🔴 main() SIGTERM'd mid-check: rc 143" "  and so is its directory"
mutate '    link = os.path.join(directory, ARGV0)
    if not os.path.lexists(link):
        os.symlink(os.path.abspath(target), link)
    return link' \
    '    return os.path.abspath(target)' \
    "D42: executed by its own name: comm simple_switch(_g)" \
    "🔴 its comm is not a switch's either" "🔴 a --version run's comm is ndt-hbdrop-bmv2 too (bmv2_count counts comm)"
mutate '                      "--log-file", "bmv2", "--log-level", "debug", "--log-flush",' \
    '                      "--log-file", os.path.join(workdir, "bmv2"), "--log-level", "debug", "--log-flush",' \
    "D43: its log is named outside its own directory's terms" \
    "🔴 its pcaps and its log are relative to it too"
mutate '    workdir = tempfile.mkdtemp(prefix="ndt-hbdrop-", dir=tmp_parent)' \
    '    workdir = tempfile.mkdtemp(prefix="hbdrop-", dir=tmp_parent)' \
    "D44: its directory is not named as its own" \
    "🔴 and that directory is its own, under the caller's temporary directory"
# --- end to end, through ndt (section 9): ndt's side of it -------------------------------------
mutate_ndt '    out="$(hb_drop_check_run "$1" 2>&1)"; rc=$?' \
    '    ( hb_drop_check_run "$1" > /dev/null 2>&1 & ); out="heartbeat drop check (checked): advanced_tunnel.json (assumed): DROPPED -- assumed"; rc=0' \
    "NE1: ndt does not wait for the check: its switch runs when the fabric starts" \
    "🔴 no throwaway switch is left when the fabric starts" "  no throwaway switch is left there either"
mutate_ndt '    python3 "$REPO/tools/test_workflow/heartbeat_drop_check.py" "$1"' \
    '    echo "heartbeat drop check (checked): advanced_tunnel.json (assumed): DROPPED -- assumed"' \
    "NE2: ndt's step does not run the checker" \
    "  the whole answer is in the bring-up's own log, named on the line" \
    "🔴 end to end: a package whose program floods it -- NOT dropped, said"
mutate_ndt '    HB_CHECK_RC="$rc"' \
    '    HB_CHECK_RC="$rc"; printf '"'"'%s\n'"'"' "$out"' \
    "NE3: ndt prints the checker's whole answer" \
    "  and it is one short line (06 keeps 6000 characters of \`ndt up\`)"

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 heartbeat_drop_check.py CHANGED during the gate"; exit 3
fi
if [[ "$(sha256sum "$NDT" | cut -d' ' -f1)" != "$NDT_SUM" ]]; then
    echo "🔴 ndt CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  heartbeat_drop_check.py  sha256 $BASE_SUM; ndt sha256 $NDT_SUM"
[[ -d "$KEEP" ]] && echo "mutant runs that did not reach their summary line: $(ls "$KEEP" | wc -l), kept in $KEEP" \
    || echo "mutant runs that did not reach their summary line: 0"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived"
COV="$(python3 - "$BK" "$CONTROLS" <<'COVERAGE'
import glob, re, sys
rx = re.compile(r"^  (ok|FAILED) +(.*)$")
def checks(path):
    lines = open(path, errors="replace").read().splitlines()
    return [(m.group(1), m.group(2).rstrip()) for m in map(rx.match, lines) if m]
controls = {c.strip() for c in sys.argv[2].splitlines() if c.strip()}
base = checks(sys.argv[1] + "/base.out")
runs = [checks(p) for p in glob.glob(sys.argv[1] + "/*/suite.out")]
never = [f"#{i + 1} {name}" for i, (_, name) in enumerate(base) if name not in controls
         and not any(len(r) == len(base) and r[i] == ("FAILED", name) for r in runs)]
reds = [name for i, (_, name) in enumerate(base) if name in controls
        and any(len(r) == len(base) and r[i] == ("FAILED", name) for r in runs)]
print(f"every non-control check seen red: {len(base) - len(controls) - len(never)}/"
      f"{len(base) - len(controls)} (over {len(runs)} mutant runs); {len(controls)} control(s)"
      + (f", {len(reds)} of them red too: {reds}" if reds else ", none of them red"))
for n in never:
    print(f"  NEVER RED under any mutation: {n}")
COVERAGE
)"
echo "$COV"
(( SURVIVED == 0 )) && ! /usr/bin/grep -q 'NEVER RED' <<<"$COV"
