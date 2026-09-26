#!/usr/bin/env bash
# redfirst_lp1c.sh <worktree> <shim dir> -- test_live_p1_common.sh's 5e defect, red first, with NO
# fabric anywhere: every run below sees only a FAKE one (Mininet host shells listed by a ps shim,
# pids above pid_max) and every lab command goes to a shim that records and refuses it.
#   1. trunk 3f8c2abf's suite (before any change), under the external shims with the fake fabric:
#      it WOULD run sudo mnexec iperf in the fabric's hosts -- the external shim records those calls.
#   2. 124a7f3c's suite (its own guard, 5e not yet fixed): the suite itself goes red in section 14,
#      naming those calls; its two controls are ok.
#   3. HEAD's suite: every check ok, and under the external fake fabric it records nothing.
# Each earlier version runs as a copy BESIDE the real file (tests/shell/.redfirst-*), so it resolves
# the same tree; the copies are removed on exit. [Co-developed with claude code -- Adam]
# (b: the ok-line checks match the label anywhere in an ok line -- the first version required it
# right after the ok column, and the two controls' labels start with two spaces.)
set -u
WT="$1"; SHIMS="$2"; bad=0
T=$(mktemp -d "${TMPDIR:-/tmp}/lp1c-red-XXXXXX")
COPIES=()
trap 'rm -rf "$T"; rm -f "${COPIES[@]}"' EXIT
cd "$WT" || exit 2
echo "HEAD $(git rev-parse HEAD); trunk base 3f8c2abf; red-first 124a7f3c"
at() {   # at <rev> <label> <fake fabric 0|1> -> $T/<label>.out, $T/<label>.calls
    local f="tests/shell/.redfirst-$2-test_live_p1_common.sh"
    if [[ "$1" == HEAD ]]; then f=tests/shell/test_live_p1_common.sh
    else git show "$1:tests/shell/test_live_p1_common.sh" > "$f"; COPIES+=("$WT/$f"); fi
    : > "$T/$2.calls"
    env -u SELFTEST_PROBE_SUDO PATH="$SHIMS:$PATH" NOLAB_LOG="$T/$2.calls" NOLAB_SUITE="$2" NOLAB_PASS=red \
        NOLAB_FAKE_FABRIC="$3" timeout 900 bash "$f" < /dev/null > "$T/$2.out" 2>&1
    echo $? > "$T/$2.rc"
}
lab_calls() { /usr/bin/grep -E ' (sudo|mnexec|iperf|iperf3|ping) ' "$1" | cut -d' ' -f3- ; }
ok()  { echo "  ok    $*"; }
bad() { echo "  BAD   $*"; bad=1; }

echo "== 1. trunk's suite, fake fabric, external shims"
at 3f8c2abf trunk 1
lab_calls "$T/trunk.calls" | sort | uniq -c | sed 's/^/    /'
for want in "sudo -n mnexec -a 4194392 iperf -s -u" "sudo -n mnexec -a 4194391 iperf -c 10.0.2.2" \
            "sudo -n mnexec -a 4194393 iperf -s -u" "sudo -n mnexec -a 4194391 iperf -c 10.0.3.3"; do
    /usr/bin/grep -qF -- "$want" "$T/trunk.calls" && ok "trunk's suite reached for: $want" || bad "trunk's suite did not reach for: $want"
done
echo "  --    trunk's suite itself said: $(tail -1 "$T/trunk.out") (rc $(cat "$T/trunk.rc")) -- it has no way to see it"

echo "== 2. the red-first suite (its own guard, 5e unfixed)"
at 124a7f3c red 0
[[ "$(cat "$T/red.rc")" != 0 ]] && ok "red-first suite: rc $(cat "$T/red.rc"), '$(tail -1 "$T/red.out")'" || bad "red-first suite passed"
fails="$(/usr/bin/grep -c '^  FAILED' "$T/red.out")"
/usr/bin/grep '^  FAILED' -A2 "$T/red.out" | cut -c1-230 | sed 's/^/    /'
[[ "$fails" == 1 ]] && /usr/bin/grep -q '^  FAILED   🔴 NOTHING reached for sudo, mnexec or iperf past a stub' "$T/red.out" \
    && ok "exactly one check failed, and it is section 14's" || bad "$fails check(s) failed, not exactly section 14's one"
/usr/bin/grep -A2 '^  FAILED   🔴 NOTHING reached' "$T/red.out" | /usr/bin/grep -qF 'sudo -n mnexec -a 4194392 iperf -s -u' \
    && ok "and it names the calls (sudo -n mnexec -a <fake h2> iperf -s -u ...)" || bad "section 14 does not name the calls"
for c in "the guard's sudo is the one on PATH" "and the fake fabric is what host_pid sees"; do
    /usr/bin/grep -qF -- "$c" <(/usr/bin/grep '^  ok ' "$T/red.out") && ok "control ok: $c" || bad "control not ok: $c"
done
[[ -z "$(lab_calls "$T/red.calls")" ]] && ok "no call got past the suite's own shims to the external ones" || bad "calls reached the external shims: $(lab_calls "$T/red.calls" | head -3)"

echo "== 3. HEAD's suite"
at HEAD head 1
[[ "$(cat "$T/head.rc")" == 0 && "$(tail -1 "$T/head.out")" == *", 0 failed" ]] && ok "HEAD: $(tail -1 "$T/head.out")" \
    || { bad "HEAD: rc $(cat "$T/head.rc"), '$(tail -1 "$T/head.out")'"; /usr/bin/grep '^  FAILED' -A2 "$T/head.out" | cut -c1-230 | sed 's/^/    /'; }
for c in "🔴 NOTHING reached for sudo, mnexec or iperf past a stub" "🔴 and no cell reached the shared stubs either (no flow was attempted)" \
         "  and, zz2 having no namespace, it stopped there (rc 2)" "  stopping at the same refusal (rc 2)"; do
    /usr/bin/grep -qF -- "$c" <(/usr/bin/grep '^  ok ' "$T/head.out") && ok "HEAD ok: $c" || bad "HEAD not ok: $c"
done
[[ -z "$(lab_calls "$T/head.calls")" ]] && ok "HEAD under the external fake fabric: no lab command recorded" || bad "HEAD reached: $(lab_calls "$T/head.calls" | head -3)"
echo "LP1C-RED-FIRST: $([[ $bad == 0 ]] && echo 'trunk reaches for sudo, the red-first suite says so, HEAD neither' || echo BROKEN)"
exit $bad
