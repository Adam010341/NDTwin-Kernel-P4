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
# the end. Every mutant run launches the real stock simple_switch, as the suite does
# (NDT_HB_CHECK_BMV2 passes through).
#
# Run:  bash tests/shell/mutate_heartbeat_drop_check.sh
# Exit: 0 every mutation caught and every non-control check seen red; 1 a survivor, or a check no
#       mutation turned red; 2 refused (baseline red); 3 the tool changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/tools/test_workflow/heartbeat_drop_check.py"
TEST="$HERE/test_heartbeat_drop_check.py"
[[ -r "$TOOL" && -r "$TEST" ]] || { echo "refused: the tool or its suite is missing"; exit 2; }
BK="$(mktemp -d "${TMPDIR:-/tmp}/hbdrop-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"

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
CONTROLS="  (the run under observation still judged)
  (that scan's rule, as the kernel has it)
  and it is still rc 0
🔴 it runs as the caller, not root
🔴 ndt's bmv2_count does not count it
  nor does its identity rule take it for a switch"

run_test() { CHECK_UNDER_TEST="$1" timeout 600 python3 "$TEST" 2>&1; }

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
mutate '        answer = cached(entry, version)' \
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
    "🔴 argv[0] is not a switch's name" "🔴 the kernel's capacity scan does not either (argv[0] does not start simple_switch)"
mutate 'ARGV0 = "ndt-hbdrop-bmv2"' \
    'ARGV0 = "/usr/local/bmv2-fast/bin/simple_switch_grpc"' \
    "D16b: argv[0] is the fabric's own binary" \
    "🔴 the helper's sweep does not match it" "🔴 p4_testbed_topo's switch name is not its argv[0]" \
    "🔴 no argv element names simple_switch_grpc (ndt's running-binary line)"
mutate '                      "--notifications-addr", "ipc://notif.ipc",' \
    '' \
    "D17: its nanomsg socket goes where the fabric's do" \
    "🔴 its nanomsg socket is in its own directory" "  named relative to it"
mutate '        device_id = DEVICE_ID_BASE + os.getpid() % 90000' \
    '        device_id = 1' \
    "D18: its device id can be a fabric's" \
    "🔴 its device id is no fabric's (above 512)"
mutate '                                         preexec_fn=_die_with_parent, start_new_session=True)' \
    '                                         start_new_session=True)' \
    "D19: the switch outlives a checker killed outright" \
    "🔴 a checker killed outright takes its switch with it"
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

echo
NOW_SUM="$(sha256sum "$TOOL" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 heartbeat_drop_check.py CHANGED during the gate"; exit 3
fi
echo "source byte-identical: yes  heartbeat_drop_check.py  sha256 $BASE_SUM"
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
