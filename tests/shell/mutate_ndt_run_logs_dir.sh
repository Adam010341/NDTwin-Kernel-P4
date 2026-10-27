#!/usr/bin/env bash
#
# Mutation gate for who makes .test_run/logs: tests/shell/test_ndt_run_logs_dir.sh (ndt's side)
# and p4_proxy/tests/test_topo_log.py's TheLogDirectoryRootCreatesIsTheCheckoutOwnersTest (the
# root-run bridge's side).
#
# [Co-developed with claude code -- Adam]
#
# TWO SUBJECTS, because the fix is two layers and either alone leaves a path open:
#
#   tools/test_workflow/ndt          makes the directory as the user before topo-start, and
#                                    refuses one it cannot write before anything is built.
#   p4_proxy/mininet/topo_log.py     a directory the root bridge still has to create (it was
#                                    started by hand, or by an older ndt) goes to the owner of
#                                    the directory it was made in.
#
# A mutant is a copy: ndt is reached through NDT_UNDER_TEST, topo_log.py through a shadow tree
# that holds it and its test file (the test imports it relative to itself). Neither real file is
# written; byte-identity of both is asserted at the end.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the WRONG check going red counts as
# SURVIVOR -- never as skipped.
#
# Exit: 0 every mutant caught; 1 something survived; 2 refused (harness fault); 3 a subject
# changed underneath the gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TOPO_LOG="$REPO/p4_proxy/mininet/topo_log.py"
SH_TEST="$REPO/tests/shell/test_ndt_run_logs_dir.sh"
PY_TEST="$REPO/p4_proxy/tests/test_topo_log.py"
PY_CLASS=TheLogDirectoryRootCreatesIsTheCheckoutOwnersTest
PY="${PYTHON:-python3}"
[[ -r "$NDT" && -r "$TOPO_LOG" && -r "$SH_TEST" && -r "$PY_TEST" ]] || { echo "refused: a subject or a suite is missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-runlogs-mutate-XXXXXX")"
trap 'chmod -R u+w "$BK" 2>/dev/null; rm -rf "$BK"' EXIT
BASE_NDT="$(sha256sum "$NDT" | cut -d' ' -f1)"
BASE_TOPO_LOG="$(sha256sum "$TOPO_LOG" | cut -d' ' -f1)"

CAUGHT=0; SURVIVORS=0

shadow_of() {   # <label> -- ndt with its two tables, and topo_log.py with its test, side by side
    local d="$BK/$1"
    mkdir -p "$d/tools/test_workflow" "$d/p4_proxy/mininet" "$d/p4_proxy/tests"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/tools/test_workflow/"
    cp "$TOPO_LOG" "$d/p4_proxy/mininet/"
    cp "$PY_TEST" "$d/p4_proxy/tests/"
    echo "$d"
}

run_suite() {   # <shadow> -- both suites; each line of the output says which one it came from
    NDT_UNDER_TEST="$1/tools/test_workflow/ndt" timeout 300 bash "$SH_TEST" 2>&1 | sed 's/^/sh| /'
    local shrc=${PIPESTATUS[0]}
    (cd "$1" && timeout 300 "$PY" p4_proxy/tests/test_topo_log.py "$PY_CLASS" 2>&1) | sed 's/^/py| /'
    local pyrc=${PIPESTATUS[0]}
    (( shrc == 0 && pyrc == 0 ))
}

mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d target
    d="$(shadow_of "$label")"
    case "${file##*/}" in
        ndt)         target="$d/tools/test_workflow/ndt" ;;
        topo_log.py) target="$d/p4_proxy/mininet/topo_log.py" ;;
        *)           echo "ANCHOR-FAILED"; return 0 ;;
    esac
    python3 - "$target" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(3)
open(p, "w").write(s.replace(a, b, 1))
PY
    [[ $? -eq 0 ]] || { echo "ANCHOR-FAILED"; return 0; }
    echo "$d"
}

report() {   # $1 = label, $2 = shadow dir, $3 = the line that MUST appear (a FAILED check or a FAIL: test)
    local out
    if [[ "$2" == ANCHOR-FAILED ]]; then
        printf '  SURVIVED %-60s (anchor did not apply -- not a skip)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    if out="$(run_suite "$2")"; then
        printf '  SURVIVED %-60s (both suites stayed green)\n' "$1"
        SURVIVORS=$((SURVIVORS+1)); return
    fi
    if grep -qF -- "$3" <<<"$out"; then
        printf '  caught   %-60s (%s)\n' "$1" "$3"; CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-60s (red, but NOT on the named check)\n' "$1"
        grep -E 'FAILED|FAIL:|ERROR:' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS+1))
    fi
}

echo "baseline (the shadow copies, unmutated -- must be green before any mutation):"
base="$(shadow_of base)"
run_suite "$base" | grep -E '^(sh|py)\| (Ran |OK|FAILED)' | sed 's/^/  /'
run_suite "$base" >/dev/null 2>&1 || { echo "  refused: the shadow baseline is RED"; exit 2; }
echo

echo "mutants -- the old behaviour must not come back:"

# ndt's half.
m=$(mutant m1 "$NDT" \
    '    guard_run_logs_writable || bad=1' \
    '    :')
report "M1: preflight no longer prepares .test_run/logs" "$m" \
       "sh|   FAILED   🔴 logs/ existed when topo-start was called, writable by this user"

m=$(mutant m2 "$NDT" \
    '    mkdir -p "$d" 2>/dev/null
    [[ -d "$d" && -w "$d" && -x "$d" ]] && return 0' \
    '    [[ -d "$d" && -w "$d" && -x "$d" ]] && return 0')
report "M2: the guard checks the directory but never makes it" "$m" \
       "sh|   FAILED   🔴 logs/ existed when topo-start was called, writable by this user"

m=$(mutant m3 "$NDT" \
    '    [[ -d "$d" && -w "$d" && -x "$d" ]] && return 0' \
    '    [[ -d "$d" ]] && return 0')
# Named on the launch, not on the rc: with the check gone the bring-up still ends rc 1, later,
# when stack.sh cannot write -- which is the defect, arriving after the fabric is built.
report "M3: a directory this user cannot write is accepted" "$m" \
       "sh|   FAILED   🔴 topo-start was never called"

# The bridge's half.
m=$(mutant m4 "$TOPO_LOG" \
    '                make_log_dir(directory, report=self._report)' \
    '                os.makedirs(directory, exist_ok=True)')
report "M4: the bridge's log makes its directory with a bare makedirs again" "$m" \
       "py| FAIL: test_root_gives_every_directory_it_creates_to_the_checkouts_owner"

m=$(mutant m5 "$TOPO_LOG" \
    '                chown(path, st.st_uid, st.st_gid, follow_symlinks=False)' \
    '                chown(path, st.st_uid, st.st_gid)')
report "M5: the chown follows a symlink swapped in for the new directory" "$m" \
       "py| FAIL: test_root_gives_every_directory_it_creates_to_the_checkouts_owner"

m=$(mutant m6 "$TOPO_LOG" \
    '                chown(path, st.st_uid, st.st_gid, follow_symlinks=False)' \
    '                chown(path, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"]), follow_symlinks=False)')
report "M6: the owner comes from SUDO_UID instead of the parent" "$m" \
       "py| FAIL: test_root_gives_every_directory_it_creates_to_the_checkouts_owner"

m=$(mutant m7 "$TOPO_LOG" \
    '    for path in reversed(created):' \
    '    for path in reversed(created[:1]):')
report "M7: only the innermost new directory is handed over" "$m" \
       "py| FAIL: test_root_gives_every_directory_it_creates_to_the_checkouts_owner"

m=$(mutant m8 "$TOPO_LOG" \
    'os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW' \
    'os.O_WRONLY | os.O_APPEND | os.O_CREAT')
report "M8: root opens topo.log through a symlink the user planted" "$m" \
       "py| FAIL: test_a_topo_log_that_is_a_symlink_is_not_followed"

# The message's two halves: a hint that names a directory that is not there is a wrong hint.
m=$(mutant m9 "$NDT" \
    '        err "  it does not exist and could not be created: $qp must be a directory you can write."' \
    '        err "  it does not exist and could not be created: $qp must be a directory you can write."
        err "    mv $qd $qd.root-owned"')
report "M9: the mv hint is offered for a directory that could not be created" "$m" \
       "sh|   FAILED       and offers no mv for a directory that is not there"

echo
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]] || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPO_LOG" | cut -d' ' -f1)" == "$BASE_TOPO_LOG" ]] || { echo "🔴 baseline CHANGED -- topo_log.py was written during the gate"; exit 3; }
echo "baselines byte-identical: yes (tools/test_workflow/ndt, p4_proxy/mininet/topo_log.py)"
echo "mutation gate: $((CAUGHT+SURVIVORS)) mutations, $CAUGHT caught, $SURVIVORS survived"
[[ $SURVIVORS -eq 0 ]]
