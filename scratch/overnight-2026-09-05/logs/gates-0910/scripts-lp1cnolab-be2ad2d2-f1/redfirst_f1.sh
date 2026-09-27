#!/usr/bin/env bash
# redfirst_f1.sh <worktree> <redfirst_lib.sh> -- the judge's F1 on c03130fe, red first, with a DECOY
# host instead of a fabric: one unprivileged process whose argv ends mininet:h2 -- the only thing
# host_pid (ndt:6055-6061) looks at -- started by this script and reaped by its own pid after each run.
#   1. c03130fe's suite (fake rows AFTER the real table), decoy up: section 14's control
#      "host_pid sees the fake fabric" goes red -- host_pid h2 is the decoy.
#   2. HEAD's suite (fake rows FIRST), decoy up: every check ok.
#   3. 124a7f3c's suite (5e still on h1..h3): as committed (old ps) the guard's sudo is handed the
#      DECOY's pid; with HEAD's ps put into it, the FAKE one (4194392) -- never a live host's.
# Earlier versions run as copies beside the real file (tests/shell/.redfirst-f1-*), removed on exit.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; source "$2"; bad=0
T=$(mktemp -d "${TMPDIR:-/tmp}/f1-red-XXXXXX"); COPIES=(); DECOY=""
cleanup() { [[ -n "$DECOY" ]] && { kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null; }; rm -f "${COPIES[@]}"; rm -rf "$T"; }
trap cleanup EXIT
export KEEP="${KEEP:-$T/kept-not-saved}"
ok()  { echo "  ok    $*"; }
nok() { echo "  BAD   $*"; bad=1; }
cd "$WT" || exit 2
echo "HEAD $(git rev-parse HEAD); F1 base c03130fe; 5e red-first 124a7f3c"
# The decoy: `exec -a` gives it a Mininet-like argv0, and its LAST argv word is the tag host_pid
# matches (`sleep 120` would end in 120 and match nothing). Unprivileged; one process; 120 s cap.
decoy_up() {
    ( exec -a "bash --norc -is" /usr/bin/python3 -I -c 'import time; time.sleep(120)' mininet:h2 ) &
    DECOY=$!
    local i; for i in $(seq 1 50); do
        [[ "$(tr '\0' ' ' < "/proc/$DECOY/cmdline" 2>/dev/null)" == *" mininet:h2 " ]] && return 0; sleep 0.1
    done; return 1
}
decoy_down() { kill "$DECOY" 2>/dev/null; wait "$DECOY" 2>/dev/null; DECOY=""; }
run_suite() {   # run_suite <file> <label> -- with a decoy up for exactly this run
    decoy_up || { nok "the decoy did not come up"; return; }
    local seen; seen="$( set +eu; source tools/test_workflow/ndt >/dev/null 2>&1; host_pid h2 )"
    echo "    (decoy pid $DECOY; the real ps's host_pid h2 = $seen)"
    [[ "$seen" == "$DECOY" ]] || nok "the decoy is not what a real host_pid finds ($seen)"
    echo "$DECOY" > "$T/$2.decoy"
    timeout 900 bash "$1" < /dev/null > "$T/$2.out" 2>&1; echo $? > "$T/$2.rc"
    decoy_down
}
copy_at() {   # copy_at <rev> <label> -- sets F to the copy's path (NOT in a $( ): COPIES must reach the trap)
    F="tests/shell/.redfirst-f1-$2-test_live_p1_common.sh"; COPIES+=("$WT/$F")
    git show "$1:tests/shell/test_live_p1_common.sh" > "$F"
}
calls_of() { sed -n '/FAILED   🔴 NOTHING reached for sudo/,+2p' "$1" | sed -n 's/^ *actual: *\[\(.*\)\]$/\1/p'; }

echo "== 1. c03130fe's suite, decoy up"
copy_at c03130fe base; f="$F"; run_suite "$f" base
/usr/bin/grep '^  FAILED' -A2 "$T/base.out" | cut -c1-200 | sed 's/^/    /'
[[ "$(cat "$T/base.rc")" != 0 ]] && /usr/bin/grep '^  FAILED ' "$T/base.out" | /usr/bin/grep -qF 'and the fake fabric is what host_pid sees' \
    && ok "c03130fe: section 14's control goes red -- host_pid h2 is the decoy, not the fake 4194392" \
    || nok "c03130fe: the control did not go red (rc $(cat "$T/base.rc"))"
[[ "$(/usr/bin/grep -c '^  FAILED' "$T/base.out")" == 1 ]] && ok "  and only that check" || nok "  $(/usr/bin/grep -c '^  FAILED' "$T/base.out") checks red"

echo "== 2. HEAD's suite, decoy up"
run_suite tests/shell/test_live_p1_common.sh head
[[ "$(cat "$T/head.rc")" == 0 && "$(tail -1 "$T/head.out")" == *", 0 failed" ]] && ok "HEAD: $(tail -1 "$T/head.out")" \
    || { nok "HEAD: rc $(cat "$T/head.rc"), $(tail -1 "$T/head.out")"; /usr/bin/grep '^  FAILED' -A2 "$T/head.out" | cut -c1-200 | sed 's/^/    /'; echo "    (kept: $(_rf_keep head "$T/head.out"))"; }
/usr/bin/grep '^  ok ' "$T/head.out" | /usr/bin/grep -qF 'and the fake fabric is what host_pid sees' \
    && ok "  the control is ok with a real-looking h2 up" || nok "  the control is not ok"

echo "== 3. 124a7f3c's suite (5e on h1..h3), decoy up"
copy_at 124a7f3c old; f="$F"; run_suite "$f" old
c="$(calls_of "$T/old.out")"; echo "    recorded: $c" | cut -c1-230
[[ "$c" == *"sudo -n mnexec -a $(cat "$T/old.decoy") iperf -s -u"* && "$c" != *"-a 4194392 iperf -s -u"* ]] \
    && ok "as committed (old ps): the guard's sudo was handed the DECOY's pid ($(cat "$T/old.decoy")) for h2, not the fake one" \
    || nok "as committed: the recorded server call is not the decoy's"
g="tests/shell/.redfirst-f1-oldfix-test_live_p1_common.sh"; COPIES+=("$WT/$g")
python3 - "$f" tests/shell/test_live_p1_common.sh "$g" <<'PY'
import sys
old = open(sys.argv[1]).read(); head = open(sys.argv[2]).read()
cut = lambda s: s[s.index('cat > "$NOLAB/bin/ps" <<\'PSEOF\'\n'):s.index('PSEOF\n', s.index('cat > "$NOLAB/bin/ps"') + 40) + 6]
open(sys.argv[3], "w").write(old.replace(cut(old), cut(head)))
PY
run_suite "$g" oldfix
c="$(calls_of "$T/oldfix.out")"; echo "    recorded: $c" | cut -c1-230
[[ "$c" == *"sudo -n mnexec -a 4194392 iperf -s -u"* && "$c" == *"sudo -n mnexec -a 4194391 iperf -c 10.0.2.2"* ]] \
    && ok "with HEAD's ps: the guard's sudo is handed the FAKE hosts (4194392, 4194391)" \
    || nok "with HEAD's ps: the recorded calls do not name the fake hosts"
[[ "$c" != *"-a $(cat "$T/oldfix.decoy") "* ]] && ok "  and never the decoy ($(cat "$T/oldfix.decoy"))" || nok "  the decoy's pid was handed to the sudo"
left="$(ls "$WT"/tests/shell/.redfirst-f1-* 2>/dev/null)"; rm -f "${COPIES[@]}"
[[ -z "$(ls "$WT"/tests/shell/.redfirst-f1-* 2>/dev/null)" ]] && ok "the copies are gone ($(wc -w <<<"$left") removed)" || nok "copies left behind"
echo "F1-RED-FIRST: $([[ $bad == 0 ]] && echo 'the old ps lets a real h2 win, the new one never does' || echo BROKEN)"
exit $bad
