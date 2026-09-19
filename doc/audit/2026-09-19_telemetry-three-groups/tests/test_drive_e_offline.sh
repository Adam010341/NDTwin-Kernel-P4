#!/usr/bin/env bash
#
# Offline test: drive_e.sh through ONE WHOLE ROUND with a stubbed `ndt` and stubbed arm scripts.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS FILE EXISTS. The dry-run tested the PLAN; it never enters a generation, so it
# could not see either of the two defects that killed the first real run (TICKET-P3 ruling 21):
#
#   (1) `ndt verify_p4` is not a subcommand -- it printed ndt's usage text and exited 2, and the
#       rc was never read. A check that cannot fail is not a check.
#   (2) `local id="$1" frame="$2" payload=$((frame - 42)) ...` -- under `set -u`, `frame` is
#       still unset when the third right-hand side is expanded. The driver died there.
#
# ...and a third the same raw showed, which nobody had named:
#
#   (3) `ndt down` REFUSES (rc 5) while the claim declares `measuring=`, and this driver is what
#       declares one. raw/2026-09-19T062206Z_full/90_down.txt is that refusal: the round that was
#       supposed to leave the lab clean left the fabric up.
#
# So the test runs the real code path, offline: a sandbox repo, a stub `ndt` that answers the
# five subcommands the driver may use and prints usage + rc 2 for anything else (exactly like the
# real one), stub arm scripts, and PATH shims for `sudo` and `ps`. NO sudo, NO lab, NO Mininet.
#
# 🔴 AND IT PROVES ITSELF: two cells re-introduce each defect into the copy and assert that the
# corresponding check goes RED. Without them, "green" would not distinguish "the bug is fixed"
# from "the test cannot see the bug" -- which is the whole of why the first run happened.
#
# Run:  doc/audit/2026-09-19_telemetry-three-groups/tests/test_drive_e_offline.sh
# Exit: 0 all cells passed; 1 a cell failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND="$(cd "$HERE/.." && pwd)"
# E_DRIVER lets this same file be pointed at an OLD drive_e.sh, so "these cells go red on the
# pre-fix code" is a command anyone can re-run rather than a claim in a summary:
#   E_DRIVER=$(git show <sha>:doc/audit/.../drive_e.sh > /tmp/old.sh; echo /tmp/old.sh) \
#     tests/test_drive_e_offline.sh
REAL_DRIVER="${E_DRIVER:-$ROUND/drive_e.sh}"
SCAN="$HERE/hazard_scan.py"

PASS=0; FAIL=0
check() {   # check <name> <want> <got>
    if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
    else printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}
has() {     # has <name> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
    else printf '  FAIL  %s\n        expected to contain: %s\n        got: %s\n' "$1" "$2" "$(printf '%s' "$3" | tail -3)"; FAIL=$((FAIL + 1)); fi
}
hasnt() {   # hasnt <name> <needle> <haystack>
    if [[ "$3" != *"$2"* ]]; then printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
    else printf '  FAIL  %s\n        must NOT contain: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}

SB="$(mktemp -d "${TMPDIR:-/tmp}/ndt-e-offline-XXXXXX")"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

# --- the sandbox --------------------------------------------------------------------------
# 🔴 THE STUB IS STATEFUL, BECAUSE THE BUGS ARE ABOUT STATE (ruling 22(2)). A stub that
# answered every command with canned text could not have shown that `ndt claim` rewrites the
# round baseline, nor that `ndt release` refuses when the knob no longer matches it -- and it was
# a stateless stub that let M-E19 be killed by an assertion about the CALL LOG rather than by
# behaviour. This one keeps the two pieces of state the real ndt keeps and that this driver
# actually collides with:
#
#   * `claim`  runs record_round_baseline unconditionally, which snapshots the knob AS IT IS NOW
#              (ndt:844 -> :442-455), and records NDT_MEASURING.
#   * `up p4 N` REWRITES the knob to N, exactly as the real one does.
#   * `down`   refuses rc 5 while measuring is non-empty (ndt:4618-4628), and clears it on a
#              successful teardown (ndt:1137).
#   * `release` refuses rc 1 when the knob differs from the recorded baseline (ndt:885-894).
#
# Environment knobs of the stub itself: STATUS_CHECK_RC, FORCE_DOWN_RC, FORCE_TELEMETRY_WORD.
build_sandbox() {   # build_sandbox <dir> <driver source> [entry host_count]
    local dir="$1"
    local driver="$2"
    local entry_hosts="${3:-4}"
    mkdir -p "$dir/round" "$dir/repo/tools/test_workflow" "$dir/repo/p4_proxy/mininet" \
             "$dir/repo/.test_run/pids" "$dir/bin"
    cp "$driver" "$dir/round/drive_e.sh"
    chmod +x "$dir/round/drive_e.sh"
    printf '%s\n' "$entry_hosts" > "$dir/repo/p4_proxy/mininet/host_count_override"

    cat > "$dir/repo/tools/test_workflow/ndt" <<'NDTEOF'
#!/usr/bin/env bash
set -uo pipefail
HERE_NDT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"       # = <dir>/repo
SBOX="$(cd "$HERE_NDT/.." && pwd)"                                    # = <dir>
CALLS="$SBOX/ndt_calls.txt"
STATE="$SBOX/ndt_state"
KNOB="$HERE_NDT/p4_proxy/mininet/host_count_override"
printf '%s | measuring=%s\n' "$*" "${NDT_MEASURING:-<unset>}" >> "$CALLS"

knob_now()  { tr -d '[:space:]' < "$KNOB" 2>/dev/null; }
state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
state_put() {   # state_put <key> <value>
    local key="$1"
    local value="$2"
    local tmp="$STATE.tmp"
    { /usr/bin/grep -v "^$key=" "$STATE" 2>/dev/null; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
    mv -f "$tmp" "$STATE"
}

case "${1:-}" in
  claim)
    # record_round_baseline: the knob as it is AT THIS MOMENT, plus the declaration
    state_put measuring "${NDT_MEASURING:-}"
    state_put baseline_host_count "$(knob_now)"
    echo "ok  lab claimed (round baseline host_count=$(knob_now))"
    exit 0 ;;
  release)
    if (( ${FORCE_RELEASE_RC:-0} != 0 )); then
      echo "refusing (stub FORCE_RELEASE_RC=${FORCE_RELEASE_RC})" >&2
      exit "${FORCE_RELEASE_RC}"
    fi
    base="$(state_get baseline_host_count)"
    now="$(knob_now)"
    if [[ -n "$base" && "$base" != "$now" ]]; then
      echo "refusing: the P4 host knob is $now" >&2
      echo "this round started at $base, and the claim is not released with it moved" >&2
      exit 1
    fi
    echo "ok  released"
    exit 0 ;;
  status)
    if [[ "${2:-}" == "--check" ]]; then
      case "${STATUS_CHECK_RC:-0}" in
        1) echo "check: 2 problem(s)"
           echo "  - data plane: h1 -> 10.0.0.2 does NOT forward"
           echo "  - model sha256 differs from the one the last 'ndt up' used"
           exit 1 ;;
        3) echo "check: nothing was compared -- .test_run/up.target is absent"; exit 3 ;;
        *) echo "  ok  check: ok"
           echo "  compared against the last 'ndt up': dataplane, fabric hosts, kernel graph, topology file"
           exit 0 ;;
      esac
    fi
    echo "  running: stub"; exit 0 ;;
  up)
    group="none"; hosts=""
    shift
    while (( $# )); do
      case "$1" in
        --telemetry) group="${2:-none}"; shift 2 ;;
        p4) shift ;;
        [0-9]*) hosts="$1"; shift ;;
        *) shift ;;
      esac
    done
    # the real `ndt up p4 N` rewrites the knob; so does this one, because that rewrite is what
    # the round baseline then gets recorded from.
    [[ -n "$hosts" ]] && printf '%s\n' "$hosts" > "$KNOB"
    [[ -n "${FORCE_TELEMETRY_WORD:-}" ]] && group="$FORCE_TELEMETRY_WORD"
    cat <<UPEOF
[1/3] bmv2 fabric
  ok  10 switches up after 5s, manifest written
[2/3] proxy + kernel
  ok  proxy :8081   kernel :8000
[3/3] verify
  ok  kernel: 10 switches, 10 up, 40 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  telemetry: $group -- 0 cooperative, 0 link, 10 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.0.2 forwards

up. ready
UPEOF
    exit 0 ;;
  down)
    meas="$(state_get measuring)"
    if [[ -n "$meas" ]]; then
      echo "refusing to tear down: this claim DECLARES a measurement in progress." >&2
      echo "    measuring=$meas" >&2
      echo "when that run is over:  ndt claim <mins> to redeclare, or  ndt down --force" >&2
      exit 5
    fi
    if (( ${FORCE_DOWN_RC:-0} != 0 )); then
      echo "refusing to tear down (stub FORCE_DOWN_RC=${FORCE_DOWN_RC})" >&2
      exit "${FORCE_DOWN_RC}"
    fi
    state_put measuring ""
    echo "  ok  verified clean"
    exit 0 ;;
esac
cat <<USAGEEOF
usage: ndt <command>

  up [what]     bring the whole lab up and verify it
  down [--deep] take it all down and prove the machine is clean
  status [--check]     what is running, who has the lab
  claim [min] [note]   reserve the lab
  release              give it back
USAGEEOF
exit 2
NDTEOF
    chmod +x "$dir/repo/tools/test_workflow/ndt"

    # --- stub arm scripts. They write only what the driver reads back.
    cat > "$dir/round/run_group_arm.sh" <<'ARMEOF'
#!/usr/bin/env bash
set -uo pipefail
GROUP=""; FRAME=""; ARM=""; OUT=""
while (( $# )); do
    case "$1" in
        --group) GROUP="$2"; shift 2 ;;
        --frame) FRAME="$2"; shift 2 ;;
        --arm)   ARM="$2";   shift 2 ;;
        --out)   OUT="$2";   shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$OUT"
# STUB_ARM_SLEEP makes an arm take long enough that a signal can be delivered WHILE the round is
# inside one, which is the only way to test an interrupted round without a race. STUB_ARM_SKIP
# names arms that produce no arm.meta at all -- an arm that did not happen, the shape a round
# ends up in when something eats one.
[[ -n "${STUB_ARM_SLEEP:-}" ]] && sleep "$STUB_ARM_SLEEP"
if [[ ",${STUB_ARM_SKIP:-}," == *",$ARM,"* ]]; then
    echo "### stub arm $ARM left no reading behind"
    exit 0
fi
EXT=0.0500
[[ "$ARM" == c3a_noburn ]] && EXT=0.0178
[[ "$ARM" == c3b_burn ]]   && EXT=0.2959
{
  echo "arm=$ARM"; echo "group=$GROUP"; echo "frame_bytes=$FRAME"
  echo "highest_clean_kpps=20"; echo "external=$EXT"; echo "invalid=no"
} > "$OUT/arm.meta"
echo "### stub arm $ARM"
exit 0
ARMEOF
    cat > "$dir/round/sample_error.sh" <<'SEEOF'
#!/usr/bin/env bash
set -uo pipefail
OUT=""
while (( $# )); do [[ "$1" == "--out" ]] && OUT="$2"; shift; done
mkdir -p "$OUT"; printf '{"invalid": null}\n' > "$OUT/window.json"
exit 0
SEEOF
    chmod +x "$dir/round/run_group_arm.sh" "$dir/round/sample_error.sh"

    # --- PATH shims. `sudo` swallows the mnexec/iperf3 calls the sender control makes (there is
    # no lab here and there must be no sudo); `ps` answers with a host namespace so the control
    # is REACHED rather than skipped -- being reached is the whole point of cell B.
    # 🔴 A REAL-SHAPED SWITCH MANIFEST. The stub used to write `argv` as a LIST, which is
    # the shape run_group_arm.sh assumed -- so this suite was green while the arm script could
    # never have worked against the lab, and the first real campaign marked every arm invalid.
    # It is the manifest the lab really wrote -- all ten switches, byte for byte. (Ruling 27.)
    cp "$HERE/fixtures/ndtwin_p4_switches.real.json" "$dir/ndtwin_p4_switches.json"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/sudo"
    printf '#!/usr/bin/env bash\necho "  12345 mininet:h1"\n' > "$dir/bin/ps"
    # 🔴 A `cp` THAT FAILS ONLY ON THE KNOB RESTORE. NDT_BREAK_RESTORE=1 makes
    # `cp -p <entry copy> <host_count_override>` fail the way a full disk would (this machine hit
    # ENOSPC once today), and leaves every other cp -- including the driver's own snapshot of the
    # entry bytes, whose destination is the .entry file -- working. Deterministic: no chmod race
    # against a run that is already going.
    cat > "$dir/bin/cp" <<'CPEOF'
#!/usr/bin/env bash
dest="${!#}"
if [[ "${NDT_BREAK_RESTORE:-0}" == "1" && "$dest" == */host_count_override ]]; then
    echo "cp: cannot create regular file '$dest': No space left on device (stubbed)" >&2
    exit 1
fi
exec /usr/bin/cp "$@"
CPEOF
    chmod +x "$dir/bin/sudo" "$dir/bin/ps" "$dir/bin/cp"
}

run_driver() {   # run_driver <dir> [VAR=VALUE ...] -- stdout+stderr of a whole round
    local dir="$1"
    shift
    ( cd "$dir/round" && env "$@" PATH="$dir/bin:$PATH" NDT_REPO="$dir/repo" \
        NDT_OWNER=p3-E-offline LT_MANIFEST="$dir/repo/no-such-link-manifest.json" \
        FABRIC_SETTLE_S=0 SETTLE_S=0 WINDOW_GAP_S=0 CTRL_RATES="1 2" CLAIM_MINUTES=5 \
        timeout 300 ./drive_e.sh 2>&1 )
}

knob_of() { tr -d '[:space:]' < "$1/repo/p4_proxy/mininet/host_count_override" 2>/dev/null; }

printf '=== 1. the copy under test IS the real drive_e.sh\n'
SB1="$SB/fixed"; build_sandbox "$SB1" "$REAL_DRIVER"
check "  byte-identical to $REAL_DRIVER" \
      "$(sha256sum "$REAL_DRIVER" | cut -d' ' -f1)" \
      "$(sha256sum "$SB1/round/drive_e.sh" | cut -d' ' -f1)"

printf '\n=== 2. a whole round, offline\n'
OUT1="$(run_driver "$SB1")"; RC1=$?
CALLS1="$(cat "$SB1/ndt_calls.txt" 2>/dev/null)"
check "  the driver finished (not killed by timeout)" "0" "$(( RC1 == 124 ? 124 : 0 ))"
has   "  it reached its own verdict, and it is a PASS" "PASS P3-E" "$OUT1"
check "  six generations were brought up" "6" "$(/usr/bin/grep -c '^up p4 4 --telemetry' <<<"$CALLS1")"
check "  every generation was torn down, plus the final one" "7" "$(/usr/bin/grep -c '^down' <<<"$CALLS1")"
check "  the lab was released exactly once" "1" "$(/usr/bin/grep -c '^release' <<<"$CALLS1")"

printf '\n=== 3. ruling 21(1): no call to a word that is not an ndt subcommand\n'
UNKNOWN="$(awk -F' \\| ' '{print $1}' <<<"$CALLS1" | awk '{print $1}' | sort -u \
          | /usr/bin/grep -vxE 'claim|release|status|up|down' || true)"
check "🔴 every ndt call names a real subcommand" "" "$UNKNOWN"
hasnt "🔴 verify_p4 is never invoked" "verify_p4" "$CALLS1"
has   "  the standalone re-check that does exist is used" "status --check" "$CALLS1"
has   "  and the bring-up's own telemetry assertion was read" "telemetry: none --" "$OUT1"

printf '\n=== 4. ruling 21(2): the sender control is REACHED and does not abort the driver\n'
has   "🔴 C1 ran (the set -u local hazard would have killed the shell here)" \
      "C1: generator ceiling at 64B frames" "$OUT1"
has   "  C2 ran too" "C2: generator ceiling at 1024B frames" "$OUT1"
has   "  and the gate's positive control ran after them" "C3: the external gate" "$OUT1"

printf '\n=== 5. the third defect the same raw showed: down refuses while measuring= is declared\n'
# Each `down` must be immediately preceded by a `claim` issued WITHOUT NDT_MEASURING.
#
# 🔴 THE `^claim` IS LOAD-BEARING AND WAS MISSING. The first version of this line only asked
# whether the PREVIOUS call carried `measuring=<unset>` -- and `up` carries that too, because
# NDT_MEASURING is a prefix assignment on the claim alone. So the cell was green whether or not
# the retraction happened, and the mutation gate said so: M-E19 SURVIVED on the first run. This
# is M-E10's lesson in a second place -- an assertion that cannot distinguish the two worlds is
# not an assertion.
RETRACTED="$(awk -F' \\| ' '$1 ~ /^down/ { print prev } { prev = $0 }' <<<"$CALLS1" \
            | /usr/bin/grep -cE '^claim .*measuring=<unset>' || true)"
check "🔴 every teardown is preceded by a claim that retracts measuring=" "7" "$RETRACTED"
hasnt "🔴 and the guard is never overridden with --force" "down --force" "$CALLS1"
has   "  the round re-declares it at the next bring-up" \
      "measuring=P3-E three-group telemetry round" "$CALLS1"

printf '\n=== 6. negative controls: the new checks can fail\n'
SB2="$SB/wrong-group"; build_sandbox "$SB2" "$REAL_DRIVER"
OUT2="$(run_driver "$SB2" FORCE_TELEMETRY_WORD=cooperative)"
has   "🔴 a bring-up asserting the wrong telemetry source is caught" \
      "asserted a telemetry source that is not 'none'" "$OUT2"
SB3="$SB/down-refuses"; build_sandbox "$SB3" "$REAL_DRIVER"
OUT3="$(run_driver "$SB3" FORCE_DOWN_RC=5)"
has   "🔴 a down that still refuses after the retraction is a reported failure" \
      "refused (rc 5)" "$OUT3"
hasnt "  and it is still not forced" "down --force" "$(cat "$SB3/ndt_calls.txt")"

printf '\n=== 6b. ruling 22(1): `ndt status --check` rc 1 is a verdict and cannot coexist with PASS\n'
SB7="$SB/check-rc1"; build_sandbox "$SB7" "$REAL_DRIVER"
OUT7="$(run_driver "$SB7" STATUS_CHECK_RC=1)"
hasnt "🔴 a generation whose status --check said rc 1 does NOT end in PASS" "PASS P3-E" "$OUT7"
has   "  the failure names the generation and the rc" \
      "G1: 'ndt status --check' rc=1" "$OUT7"
has   "  and it says the arms of that generation ran under it" \
      "the arms of this generation ran under it" "$OUT7"
# 🔴 rc 1 must NOT skip the generation: a cell measured under a named problem is evidence about
# that problem. What is forbidden is calling the round a pass over it.
check "  the arms still ran (12 of them, as in a clean round)" "12" \
      "$(find "$SB7/round/raw" -name arm.meta -not -path '*/controls/*' 2>/dev/null | wc -l)"
check "  and all six generations were still brought up" "6" \
      "$(/usr/bin/grep -c '^up p4 4 --telemetry' "$SB7/ndt_calls.txt")"

SB8="$SB/check-rc3"; build_sandbox "$SB8" "$REAL_DRIVER"
OUT8="$(run_driver "$SB8" STATUS_CHECK_RC=3)"
has   "🔴 rc 3 is recorded as NOTHING compared, and stays out of the verdict" \
      "NOTHING was compared" "$OUT8"
has   "  so the round can still pass on it" "PASS P3-E" "$OUT8"

printf '\n=== 6c. ruling 22(2): the round baseline the release compares against\n'
# 🔴 THE ENTRY KNOB IS 128 HERE, AND THAT IS THE WHOLE CELL. `ndt up p4 4` rewrites the knob to
# 4; every `ndt claim` re-records the round baseline from the knob AS IT IS THEN; finish()
# restores 128 and releases. Without a re-claim after the restore, the baseline still says 4,
# cmd_release refuses rc 1 and KEEPS THE CLAIM -- and on 8d04e130 the driver only `bad`s, so the
# round says PASS with the lab still claimed. It is dormant at entry=4 and lit at anything else.
SB9="$SB/knob-128"; build_sandbox "$SB9" "$REAL_DRIVER" 128
OUT9="$(run_driver "$SB9")"
check "  the entry knob was 128 and is 128 again at the end" "128" "$(knob_of "$SB9")"
has   "🔴 the release is not refused, so the lab is actually given back" "ok  released" "$OUT9"
hasnt "🔴 and the round does not report a release refusal" "THE LAB IS STILL CLAIMED" "$OUT9"
has   "  the round passes" "PASS P3-E" "$OUT9"
check "  the final claim re-recorded the baseline from the RESTORED value" "128" \
      "$(sed -n 's/^baseline_host_count=//p' "$SB9/ndt_state" | tail -1)"

# 🔴 THE OTHER HALF OF 22(2): the release's rc has to REACH THE VERDICT.
#
# The mechanism, corrected (ruling 24(1)): the old line was
#     "$NDT" release 2>&1 | sed 's/^/   /' || bad "'ndt release' did not take ..."
# and `set -uo pipefail` is in force, so the pipeline's status IS release's and the `||` DID
# fire. `bad` printed. What it did NOT do is touch FAILURES -- bad() only writes to stderr --
# and FAILURES is what decides the verdict. Cell 7c below pins that on the old driver: the
# message is printed AND the round still says PASS.
SB11="$SB/release-refuses"; build_sandbox "$SB11" "$REAL_DRIVER"
OUT11="$(run_driver "$SB11" FORCE_RELEASE_RC=1)"
hasnt "🔴 a refused release means the round does NOT pass" "PASS P3-E" "$OUT11"
has   "  and it says the lab is still claimed" "THE LAB IS STILL CLAIMED" "$OUT11"
has   "  in the failure list, not only on the way past" \
      "final: 'ndt release' refused (rc 1)" "$OUT11"

printf '\n=== 6g. ruling 32(3): a round that was CUT DOWN does not print PASS over what it never measured\n'
# 🔴 THE THIRD CAMPAIGN START, AS A CELL. It was stopped with SIGTERM before a single arm
# existed and its last line was `PASS P3-E -- every selected arm produced a reading`
# (scratch/overnight-2026-09-05/logs/orchestrator-0919/drive_e-1854.log:67), because FAILURES was
# empty -- nothing had gone wrong, nothing had happened at all. The signal is delivered for real
# here, to a real background round, in the middle of a real arm: STUB_ARM_SLEEP holds the arm
# open long enough that the kill lands inside it rather than in a gap between commands.
SB14="$SB/interrupted"; build_sandbox "$SB14" "$REAL_DRIVER"
OUT14_FILE="$SB14/round.out"
( cd "$SB14/round" && exec env PATH="$SB14/bin:$PATH" NDT_REPO="$SB14/repo" \
    NDT_OWNER=p3-E-offline LT_MANIFEST="$SB14/repo/no-such-link-manifest.json" \
    FABRIC_SETTLE_S=0 SETTLE_S=0 WINDOW_GAP_S=0 CTRL_RATES="1 2" CLAIM_MINUTES=5 \
    STUB_ARM_SLEEP=2 ./drive_e.sh ) > "$OUT14_FILE" 2>&1 &
DRIVER_PID=$!
# 🔴 ITS OWN CHILD'S PID, NEVER A PATTERN. `pkill -f`/`pgrep -f` are forbidden project-wide and
# would be wrong here anyway: this waits for the round to reach its first ladder arm and signals
# the one process it started.
for _ in $(seq 1 200); do
    /usr/bin/grep -q 'ladder arm none_f64_a' "$OUT14_FILE" 2>/dev/null && break
    sleep 0.1
done
kill -TERM "$DRIVER_PID" 2>/dev/null
wait "$DRIVER_PID"; RC14=$?
OUT14="$(cat "$OUT14_FILE" 2>/dev/null)"
hasnt "🔴 an interrupted round does NOT print PASS" "PASS P3-E" "$OUT14"
has   "🔴 an interrupted round says it was interrupted, and by which signal" \
      "INTERRUPTED (SIGTERM)" "$OUT14"
has   "  and it says how many arms of the selection it had measured" \
      "arms produced a reading" "$OUT14"
check "  and it exits 1, not 0" "1" "$RC14"
has   "  the teardown still ran (the lab is given back on the signal path too)" "teardown" "$OUT14"

printf '\n=== 6h. ruling 32(3): fewer arms than the selection is not a PASS either\n'
# The same hole without a signal: every generation runs, nothing reports a failure, and one arm
# simply never writes a reading. FAILURES stays empty and the old verdict is a PASS over 13 arms
# of 14 -- "every selected arm produced a reading" said about an arm that produced nothing.
SB15="$SB/short-round"; build_sandbox "$SB15" "$REAL_DRIVER"
OUT15="$(run_driver "$SB15" STUB_ARM_SKIP=none_f1024_b)"; RC15=$?
check "  the round really is one arm short (13 readings on disk, not 14)" "13" \
      "$(find "$SB15/round/raw" -name arm.meta 2>/dev/null | wc -l)"
hasnt "🔴 a round that measured fewer arms than it selected does NOT pass" "PASS P3-E" "$OUT15"
has   "🔴 and the verdict says how many of how many" "13 of 14 arms produced a reading" "$OUT15"
check "  and it exits 1, not 0" "1" "$RC15"

if [[ -n "${E_DRIVER:-}" ]]; then
printf '\n=== 7. pre-fix controls SKIPPED -- E_DRIVER is set, so the driver under test is already old\n'
else
printf '\n=== 6d. ruling 24(3): a knob that did not go back cannot end in PASS\n'
# 🔴 THE RE-CLAIM MADE cmd_release's KNOB GUARD VACUOUS. If restore_host_knob's cp fails -- this
# machine hit ENOSPC once today -- the knob is still 4; the final re-claim would then record the
# round baseline as 4, the release would compare 4 == 4 and pass, and the round would print PASS
# with the knob left where `ndt up p4 4` put it. NDT_BREAK_RESTORE makes the restore's cp fail
# for real (a PATH shim, only on that destination) rather than by a mocked return value.
SB12="$SB/knob-not-restored"; build_sandbox "$SB12" "$REAL_DRIVER" 128
OUT12="$(run_driver "$SB12" NDT_BREAK_RESTORE=1)"
check "  the knob really did not go back (still what 'ndt up p4 4' wrote)" "4" "$(knob_of "$SB12")"
hasnt "🔴 a round whose knob did not go back does NOT pass" "PASS P3-E" "$OUT12"
has   "  and it says so in the failure list" "host_count_override was NOT put back" "$OUT12"
has   "  naming the value the next 'ndt up p4' would read" \
      "the next 'ndt up p4' reads it" "$OUT12"
# 🔴 HYGIENE, NOT PROTECTION -- and the cell says which it is. teardown_fabric's own
# retraction has already recorded the baseline from the PRE-restore knob, so cmd_release will
# compare 4 against 4 and pass whatever happens here; FAILURES above is what makes the round
# fail. This asserts only that the round stops re-asserting a baseline it knows is wrong.
has   "  hygiene: it does not re-claim over a knob it knows is wrong" \
      "not re-claiming: the knob is not back" "$OUT12"

printf '\n=== 6e. ruling 25(4): the last claim before the release is a SHORT one\n'
# 🔴 A REFUSED RELEASE MUST NOT LOCK THE LAB FOR THE WHOLE CLAIM. The final retraction is
# also a renewal, and it used to renew by CLAIM_MINUTES (600) -- ten hours with nothing running
# if the release then refuses. The stub records each call's argv, so this reads the real call.
LASTCLAIM="$(/usr/bin/grep -E '^claim ' "$SB9/ndt_calls.txt" | tail -1)"
has   "  the final claim renews for FINAL_CLAIM_MINUTES, not CLAIM_MINUTES" \
      "claim 10 " "$LASTCLAIM"
check "  and it is the last ndt call before the release" "release" \
      "$(awk -F' \\| ' '{print $1}' "$SB9/ndt_calls.txt" | awk '{print $1}' | tail -1)"

printf '\n=== 6f. ruling 27: the arm script can name the binary the lab is actually running\n'
# 🔴 THE CAMPAIGN-STOPPING BUG, as a cell. The manifest's `argv` is ONE STRING; iterating
# it yields characters, so the old reader found no binary and every arm was marked
# `invalid=no simple_switch binary ... this arm cannot name what it measured` -- after
# none_f64_a had already measured a confirmed 30 kpps ceiling that then could not be used.
# This runs the REAL reader against the manifest the lab really wrote.
MANI="$HERE/fixtures/ndtwin_p4_switches.real.json"
check "  the fixture is the shape that broke it (argv is a string)" "str" \
      "$(python3 -c 'import json,sys;print(type(json.load(open(sys.argv[1]))["s1"]["argv"]).__name__)' "$MANI")"
check "🔴 the binary is found in a string argv" "/usr/local/bmv2-fast/bin/simple_switch_grpc" \
      "$(python3 "$ROUND/manifest.py" binary "$MANI")"
check "  and all ten switches give a pid and a device id" "10" \
      "$(python3 "$ROUND/manifest.py" rows "$MANI" | wc -l)"
# and the shape the OLD reader needed must not be what makes it pass
check "  the old iterate-the-argv reader finds nothing here (that was the bug)" "" \
      "$(python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
for e in d.values():
    for t in (e or {}).get("argv") or []:
        if os.path.basename(str(t)).startswith("simple_switch"):
            print(t); raise SystemExit(0)
' "$MANI")"

printf '\n=== 7. THE PRE-FIX CONTROLS -- each defect put back, each check must go RED\n'
# (a) ndt verify_p4
SB4="$SB/prefix-verify"
mkdir -p "$SB4"
sed 's|    verify_generation "$group" "$gen"|    "$NDT" verify_p4 > "$RUN/$gen/11_verify.txt" 2>\&1|' \
    "$REAL_DRIVER" > "$SB4/driver.sh"
check "  the pre-fix verify shape was re-introduced (code, not the comments about it)" "1" \
      "$(/usr/bin/grep -cE '^[[:space:]]*"\$NDT" verify_p4' "$SB4/driver.sh")"
build_sandbox "$SB4" "$SB4/driver.sh"
run_driver "$SB4" >/dev/null 2>&1
CALLS4="$(cat "$SB4/ndt_calls.txt" 2>/dev/null)"
UNKNOWN4="$(awk -F' \\| ' '{print $1}' <<<"$CALLS4" | awk '{print $1}' | sort -u \
           | /usr/bin/grep -vxE 'claim|release|status|up|down' || true)"
has   "🔴 cell 3 goes RED on the pre-fix code" "verify_p4" "$UNKNOWN4"

# (b) the set -u local hazard
SB5="$SB/prefix-local"
mkdir -p "$SB5"
python3 - "$REAL_DRIVER" "$SB5/driver.sh" <<'PYRE'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
fixed = '''    local id="$1"
    local frame="$2"
    local payload
    local out
    payload=$((frame - 42))
    out="$RUN/controls/$id"
'''
prefix = '''    local id="$1" frame="$2" payload=$((frame - 42)) out="$RUN/controls/$id"
'''
assert s.count(fixed) == 1, "the fixed shape is not where the control expects it"
open(dst, "w").write(s.replace(fixed, prefix))
PYRE
check "  the pre-fix local shape was re-introduced (code, not the comment quoting it)" "1" \
      "$(/usr/bin/grep -cE '^[[:space:]]{4}local id="\$1" frame="\$2" payload=' "$SB5/driver.sh")"
build_sandbox "$SB5" "$SB5/driver.sh"
OUT5="$(run_driver "$SB5")"
hasnt "🔴 cell 4 goes RED on the pre-fix code (C1 never runs)" \
      "C1: generator ceiling at 64B frames" "$OUT5"
hasnt "🔴 and cell 2 goes RED with it (the round never passes)" "PASS P3-E" "$OUT5"
has   "  because the shell died of it" "unbound variable" "$OUT5"
# 🔴 Worth writing down: the EXIT trap DOES still fire on the broken code, so a verdict line is
# printed either way. "Did it print a verdict" would have been green on the round that died.
# What separates them is whether the verdict is a PASS and whether any control ever ran.
has   "  the teardown still ran (the EXIT trap fires even on the dead shell)" \
      "teardown" "$OUT5"

# (c) ruling 24(1): the OLD release line, and what it really did
SB13="$SB/prefix-release"
mkdir -p "$SB13"
python3 - "$REAL_DRIVER" "$SB13/driver.sh" <<'PYREL'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
start = s.index("        # Only re-claim when the knob really went back.")
end = s.index('        if (( release_rc != 0 )); then')
# 🔴 THE END OF THE RELEASE BLOCK, NOT WHATEVER FOLLOWS IT. This used to look for
# `        fi\n    fi\n    printf ` -- it took the next statement after the block as part of
# its own landmark, and ruling 32(3) then inserted the two verdict guards exactly there. The
# slice stopped matching, this cell's driver was never written, and three cells failed with
# `cp: cannot stat .../driver.sh` -- a HARNESS error that looks exactly like a defect red.
# The two `fi` are the shape being cut out; what comes after them is not this cell's business.
#
# That pattern is NOT unique in the file (it closes gate_control's nesting too), which is fine
# because the search starts at `end` -- but "fine because of where the search starts" is exactly
# the kind of reasoning that was wrong last time, so the cut is ASSERTED rather than trusted:
# what comes out must be the release block (it must contain the FAILURES line this control
# exists to remove) and must not have swallowed anything after it (the verdict guards).
tail_end = s.index('        fi\n    fi\n', end)
cut = s[start:tail_end]
assert 'FAILURES+=("final: \'ndt release\' refused' in cut, \
    "the slice missed the release block: the FAILURES line it removes is not inside it"
assert 'arms_seen != arms_expected' not in cut, \
    "the slice ran past the release block and swallowed the arm-count guard"
old_shape = ('        "$NDT" release 2>&1 | sed \'s/^/   /\' '
             '|| bad "\'ndt release\' did not take -- run it by hand"\n')
open(dst, "w").write(s[:start] + old_shape + s[tail_end + len("        fi\n"):])
PYREL
check "  the pre-fix release shape was re-introduced" "1" \
      "$(/usr/bin/grep -cE "^[[:space:]]*\"\\\$NDT\" release 2>&1 \| sed" "$SB13/driver.sh")"
build_sandbox "$SB13" "$SB13/driver.sh"
OUT13="$(run_driver "$SB13" FORCE_RELEASE_RC=1)"
# 🔴 THE MECHANISM, PINNED. `set -uo pipefail` means the `||` saw RELEASE's rc, not sed's, so
# the old code DID print this line. My first account of the defect said the opposite; ruling
# 24(1) corrected it, and this cell is what makes the correction checkable rather than a claim.
has   "🔴 the old code DID print the refusal (the \`||\` fired -- pipefail)" \
      "'ndt release' did not take" "$OUT13"
has   "🔴 ... and said PASS in the same breath, because bad() never touched FAILURES" \
      "PASS P3-E" "$OUT13"

fi

printf '\n=== 7b. and the refusals still refuse: a leftover link-telemetry manifest starts nothing\n'
SB6="$SB/leftover"; build_sandbox "$SB6" "$REAL_DRIVER"
: > "$SB6/repo/leftover-manifest.json"
OUT6="$( cd "$SB6/round" && PATH="$SB6/bin:$PATH" NDT_REPO="$SB6/repo" NDT_OWNER=p3-E-offline \
         LT_MANIFEST="$SB6/repo/leftover-manifest.json" FABRIC_SETTLE_S=0 SETTLE_S=0 \
         WINDOW_GAP_S=0 timeout 60 ./drive_e.sh 2>&1 )"; RC6=$?
check "🔴 it refuses before anything is started" "2" "$RC6"
has   "  and says which file decided it" "leftover-manifest.json exists" "$OUT6"
check "  nothing was claimed" "0" "$(/usr/bin/grep -c . "$SB6/ndt_calls.txt" 2>/dev/null || echo 0)"

printf '\n=== 8. the hazard scanner over the three scripts, with both positive controls\n'
SCAN_OUT="$(python3 "$SCAN" "$ROUND/drive_e.sh" "$ROUND/run_group_arm.sh" "$ROUND/sample_error.sh")"
SCAN_RC=$?
# 🔴 THE rc IS THE ASSERTION NOW. The scanner used to exit 0 unconditionally, so a saved `rc=0`
# said nothing about whether the tree was clean -- a log recording that rc recorded nothing
# (ruling 22(3)). 0 = scanned and clean, 1 = scanned and FOUND something, 2 = nothing to scan.
check "🔴 no cross-referencing \`local\` in any of the three scripts (scanner rc)" "0" "$SCAN_RC"
printf '%s\n' "$SCAN_OUT" | sed 's/^/          /' 
mkdir -p "$SB/ctl"
cat > "$SB/ctl/dollar.sh" <<'CTL1'
f() {
    local ex="$1" which="$2" log="$RUN/${ex}_${which}.log" rc
}
CTL1
cat > "$SB/ctl/arith.sh" <<'CTL2'
g() {
    local id="$1" frame="$2" payload=$((frame - 42)) out="$RUN/$id"
}
CTL2
cat > "$SB/ctl/ok.sh" <<'CTL3'
h() {
    local id="$1"
    local frame="$2"
    local payload
    payload=$((frame - 42))
}
CTL3
DOLLAR_OUT="$(python3 "$SCAN" "$SB/ctl/dollar.sh")"; DOLLAR_RC=$?
has   "  positive control: the \$name form is found" "log reads \$ex" "$DOLLAR_OUT"
check "  ... and the scanner exits non-zero for it" "1" "$DOLLAR_RC"
ARITH_OUT="$(python3 "$SCAN" "$SB/ctl/arith.sh")"; ARITH_RC=$?
has   "🔴 positive control: the ARITHMETIC form is found (D's scanner misses this one)" \
      "payload reads \$frame" "$ARITH_OUT"
check "  ... and the scanner exits non-zero for it too" "1" "$ARITH_RC"
python3 "$SCAN" "$SB/ctl/ok.sh" >/dev/null 2>&1
check "  negative control: split declarations are not flagged (rc 0)" "0" "$?"
python3 "$SCAN" >/dev/null 2>&1
check "  and nothing to scan is rc 2, not a pass" "2" "$?"
# 🔴 A FILE THAT COULD NOT BE READ IS NOT A CLEAN FILE. `except OSError: continue` counted it as
# scanned and exited 0, so `hazard_scan.py /nonexistent.sh` reported "1 file(s) scanned, 0
# finding(s)" rc 0 -- against this scanner's own contract that 0 means scanned and clean. An
# incomplete sweep cannot support "found nothing", the same way an absent counter is not a zero.
# (Ruling 24(4).)
NOFILE_OUT="$(python3 "$SCAN" /nonexistent-hazard-target.sh 2>&1)"; NOFILE_RC=$?
check "🔴 a path that cannot be read is rc 2, not rc 0" "2" "$NOFILE_RC"
has   "  and the name is printed" "/nonexistent-hazard-target.sh" "$NOFILE_OUT"
has   "  and it is counted as unreadable, not as scanned" "0 scanned, 1 unreadable" "$NOFILE_OUT"
python3 "$SCAN" "$SB/ctl/arith.sh" /nonexistent-hazard-target.sh >/dev/null 2>&1
check "  an incomplete sweep outranks a finding (2, not 1)" "2" "$?"

printf '\n%s\n' "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) || exit 1
exit 0
