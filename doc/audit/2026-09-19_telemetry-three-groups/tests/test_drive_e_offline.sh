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
build_sandbox() {   # build_sandbox <dir> <driver source> [down_rc] [telemetry word to assert]
    local dir="$1"
    local driver="$2"
    local down_rc="${3:-0}"
    local force_word="${4:-}"
    mkdir -p "$dir/round" "$dir/repo/tools/test_workflow" "$dir/repo/p4_proxy/mininet" \
             "$dir/repo/.test_run/pids" "$dir/bin"
    cp "$driver" "$dir/round/drive_e.sh"
    chmod +x "$dir/round/drive_e.sh"
    printf '4\n' > "$dir/repo/p4_proxy/mininet/host_count_override"

    # --- the stub ndt. It answers the five subcommands the driver is allowed to use and, for
    # anything else, does what the real one does: prints the usage text and exits 2. That is
    # what makes `ndt verify_p4` visible instead of silently ignored.
    cat > "$dir/repo/tools/test_workflow/ndt" <<NDTEOF
#!/usr/bin/env bash
set -uo pipefail
CALLS="$dir/ndt_calls.txt"
# 🔴 the presence or absence of NDT_MEASURING in THIS command's environment is recorded, because
# the retraction is exactly "a claim issued without it".
printf '%s | measuring=%s\n' "\$*" "\${NDT_MEASURING:-<unset>}" >> "\$CALLS"
FORCE_WORD="$force_word"
DOWN_RC=$down_rc
case "\${1:-}" in
  claim)   echo "ok  lab claimed"; exit 0 ;;
  release) echo "ok  released"; exit 0 ;;
  status)
    if [[ "\${2:-}" == "--check" ]]; then
      echo "  ok  data plane kind: p4"; echo "  ok  host count: 4"; echo "  ok  model sha256 matches"
      exit 0
    fi
    echo "  running: stub"; exit 0 ;;
  up)
    group="none"
    while (( \$# )); do [[ "\$1" == "--telemetry" ]] && { group="\${2:-none}"; }; shift; done
    [[ -n "\$FORCE_WORD" ]] && group="\$FORCE_WORD"
    cat <<UPEOF
[1/3] bmv2 fabric
  ok  10 switches up after 5s, manifest written
[2/3] proxy + kernel
  ok  proxy :8081   kernel :8000
[3/3] verify
  ok  kernel: 10 switches, 10 up, 40 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  telemetry: \$group -- 0 cooperative, 0 link, 10 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.0.2 forwards

up. ready
UPEOF
    exit 0 ;;
  down)
    if (( DOWN_RC == 5 )); then
      echo "refusing to tear down: this claim DECLARES a measurement in progress." >&2
      exit 5
    fi
    echo "  ok  verified clean"; exit 0 ;;
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
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/sudo"
    printf '#!/usr/bin/env bash\necho "  12345 mininet:h1"\n' > "$dir/bin/ps"
    chmod +x "$dir/bin/sudo" "$dir/bin/ps"
}

# 🔴 LT_MANIFEST IS POINTED INTO THE SANDBOX. The driver refuses to start when
# /tmp/ndtwin_link_telemetry.json exists -- which is correct, and which really fired in the
# middle of writing this file, because something on this machine created one. A test whose
# result depends on whether another session is running is not a test of this driver, so the
# path is made hermetic here and the refusal gets its own cell below instead.
run_driver() {   # run_driver <dir> -- stdout+stderr of a whole round
    ( cd "$1/round" && PATH="$1/bin:$PATH" NDT_REPO="$1/repo" NDT_OWNER=p3-E-offline \
        LT_MANIFEST="$1/repo/no-such-link-manifest.json" \
        FABRIC_SETTLE_S=0 SETTLE_S=0 WINDOW_GAP_S=0 CTRL_RATES="1 2" CLAIM_MINUTES=5 \
        timeout 300 ./drive_e.sh 2>&1 )
}

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
SB2="$SB/wrong-group"; build_sandbox "$SB2" "$REAL_DRIVER" 0 "cooperative"
OUT2="$(run_driver "$SB2")"
has   "🔴 a bring-up asserting the wrong telemetry source is caught" \
      "asserted a telemetry source that is not 'none'" "$OUT2"
SB3="$SB/down-refuses"; build_sandbox "$SB3" "$REAL_DRIVER" 5
OUT3="$(run_driver "$SB3")"
has   "🔴 a down that still refuses after the retraction is a reported failure" \
      "refused (rc 5)" "$OUT3"
hasnt "  and it is still not forced" "down --force" "$(cat "$SB3/ndt_calls.txt")"

if [[ -n "${E_DRIVER:-}" ]]; then
printf '\n=== 7. pre-fix controls SKIPPED -- E_DRIVER is set, so the driver under test is already old\n'
else
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
check "🔴 no cross-referencing \`local\` in any of the three scripts" "" "$SCAN_OUT"
[[ -n "$SCAN_OUT" ]] && printf '%s\n' "$SCAN_OUT" | sed 's/^/          /'
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
has   "  positive control: the \$name form is found" "log reads \$ex" \
      "$(python3 "$SCAN" "$SB/ctl/dollar.sh")"
has   "🔴 positive control: the ARITHMETIC form is found (D's scanner misses this one)" \
      "payload reads \$frame" "$(python3 "$SCAN" "$SB/ctl/arith.sh")"
check "  negative control: split declarations are not flagged" "" \
      "$(python3 "$SCAN" "$SB/ctl/ok.sh")"

printf '\n%s\n' "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) || exit 1
exit 0
