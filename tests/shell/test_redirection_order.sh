#!/usr/bin/env bash
#
# Tests for the redirection ORDER in the /proc readers -- finding #50.
#
# [Co-developed with claude code -- Adam]
#
# The defect: redirections are applied LEFT TO RIGHT, so
#
#     mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
#
# opens the file while fd 2 is still the inherited stderr. bash writes
# "No such file or directory" and only THEN points fd 2 at /dev/null. The silencer suppressed
# every message except the one it was put there to suppress -- and "that pid is already gone"
# is the entire reason the read is allowed to fail. It leaked into an audit log on 2026-09-02.
#
# 🔴 WHY THIS DOES NOT TEST pid_is_app THROUGH ITS FRONT DOOR. pid_is_app returns early on
# `[[ -d "/proc/$pid" ]]`, so a pid that certainly does not exist never reaches the read: the
# earlier check masks the one under test, and a front-door test would be green against the
# broken code. At the real call site the leak needs the pid to die BETWEEN the -d test and the
# read -- a race a test cannot schedule. So section 2 re-binds /proc to a fixture directory and
# calls the function with a pid whose directory exists and whose cmdline does not. That is the
# same state the race produces, made reachable on purpose.
#
# 🔴 TWO-SIDED. An implementation that throws ALL stderr away (`exec 2>/dev/null` at the top of
# the function) satisfies every "is it silent" case and is strictly worse than the bug. Section
# 4 is the half that forbids it: an unrelated real error raised inside the same function must
# still reach the caller. A one-sided gate here would reward the worse fix.
#
# No lab contact, no build, no port: every case reads a fixture directory under $TMP or a pid
# above /proc/sys/kernel/pid_max. ndt:894 (`bash "$STACK" up ovs > "$out" 2>&1 < "$fifo"`) is
# the one fixed site NOT executed here -- running it would bring the stack up. It is covered by
# the static ordering guard in section 5 and says so there.
#
# Run:  bash tests/shell/test_redirection_order.sh
# Env:  NDT_UNDER_TEST=<path>  REPO_UNDER_TEST=<dir>   (the mutation gate sets both)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO_UNDER_TEST:-$(cd "$HERE/../.." && pwd)}"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
[[ -f "$NDT" ]] || { echo "  FAILED   no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }

T="$(mktemp -d /tmp/redir-order-XXXXXX)"; trap 'rm -rf "$T"' EXIT
GONE=4194305                       # > /proc/sys/kernel/pid_max: never a live pid
MISSING="$T/no-such-dir/no-such-file"

# Run a snippet with stdout and stderr kept APART, and print what landed on stderr.
# The snippet's own stdout is thrown away; only fd 2 is the measurement.
stderr_of() { ( eval "$1" ) >"$T/.out" 2>"$T/.err"; cat "$T/.err"; }

# ================================================================================================
echo "1. the mechanism, on nothing but bash"
# ================================================================================================
# Injection check first: if the broken order did NOT leak on this bash, every case below would
# be green for the wrong reason and this file would be an instrument with no discriminating
# power. So assert the bug is reproducible here before asserting it is absent from the repo.
leak="$(stderr_of 'cat < "$MISSING" 2>/dev/null')"
[[ -n "$leak" ]] \
    && t_ok "injection check: '< missing 2>/dev/null' really does leak on this bash" \
    || t_bad "injection check: '< missing 2>/dev/null' really does leak on this bash" \
             "it printed nothing, so nothing below can discriminate"

check "the fixed order is silent (external command)" "" "$(stderr_of 'cat 2>/dev/null < "$MISSING"')"
check "the fixed order is silent (builtin: mapfile)" "" \
      "$(stderr_of 'mapfile -d "" -t z 2>/dev/null < "$MISSING"')"
check "the fixed order is silent inside \$( )" "" \
      "$(stderr_of 'v="$(tr "\0" " " 2>/dev/null < "$MISSING")"')"

# Silencing the open must not silence the command. A snippet that suppressed everything would
# pass the three cases above; this one is what tells them apart.
saw="$(stderr_of 'printf "%s\n" x > "$T/ok.txt"; cat 2>/dev/null < "$T/ok.txt"; ls "$MISSING"')"
[[ -n "$saw" ]] \
    && t_ok "an unrelated real error is still visible next to a fixed-order read" \
    || t_bad "an unrelated real error is still visible next to a fixed-order read" "stderr was empty"

# ================================================================================================
echo
echo "2. ndt's pid_is_app, with /proc re-bound to a fixture"
# ================================================================================================
# The function is lifted out of the real ndt by text, so a mutation to the real line travels
# into the copy. The rebind count is asserted: a silently-unrebound copy would read the real
# /proc, find nothing, and look exactly like a pass.
fn="$(awk '/^pid_is_app\(\) \{/{s=1} s{print} s&&/^\}/{exit}' "$NDT")"
rebound="${fn//\"\/proc\//\"\$FIXPROC\/}"
n_after="$(grep -c '"\$FIXPROC/' <<<"$rebound")"
n_left="$(grep -c '"/proc/' <<<"$rebound")"
check "pid_is_app was lifted out of ndt (non-empty)" "yes" "$([[ -n "$fn" ]] && echo yes || echo no)"
# Both halves matter: at least three reads must have moved to the fixture, and NOTHING may
# still point at the real /proc. A copy that quietly kept reading /proc would find nothing
# there either, and "found nothing" is indistinguishable from "passed".
check "every /proc read was re-bound to the fixture (>=3 moved, 0 left)" "yes 0" \
      "$([[ "$n_after" -ge 3 ]] && echo yes || echo "only-$n_after") $n_left"

FIXPROC="$T/proc"; mkdir -p "$FIXPROC/700" "$FIXPROC/701" "$FIXPROC/702"
# 700: directory exists, NO cmdline -- the state the race produces.
# 701: cmdline names the app; comm names something else, so a rc of 0 can only have come from
#      reading cmdline. Without that read the comm fallback answers "not this app".
# 702: cmdline names a DIFFERENT app -- the control that forbids "always return 0".
printf 'network_state_recorder.py\0--flag\0' > "$FIXPROC/701/cmdline"
printf 'unrelated-binary\n'                  > "$FIXPROC/701/comm"
printf 'some-other-app.py\0--flag\0'         > "$FIXPROC/702/cmdline"
printf 'unrelated-binary\n'                  > "$FIXPROC/702/comm"

# app_sig is stubbed, not lifted: it is an upstream check, and leaving the real one in would let
# it decide the outcome before the line under test runs.
harness() {   # $1 = extra shell to inject into the function's environment
    cat > "$T/h.sh" <<HEOF
set -uo pipefail
FIXPROC="$FIXPROC"
app_sig() { echo "network_state_recorder.py"; }
${1:-}
$rebound
pid_is_app "\$1" nsr; echo "rc=\$?" >&3
HEOF
    bash "$T/h.sh" "$2" 3>"$T/.rc" >"$T/.out" 2>"$T/.err"
}

harness "" 700
check "🔑 pid_is_app is SILENT when /proc/<pid>/cmdline is gone" "" "$(cat "$T/.err")"
# rc 0, not 1, and that is the documented contract: with an empty cmdline the function asserts
# EXISTENCE only ("a zombie has one, and reporting 'not running' for a pid that plainly exists
# would be inventing a second false negative"). Asserted so the fix cannot quietly change it.
check "   ... and still answers with the documented rc (existence only)" "rc=0" "$(cat "$T/.rc")"

harness "" 701
check "pid_is_app MATCHES from cmdline when comm says otherwise (rc 0)" "rc=0" "$(cat "$T/.rc")"
check "   ... and that path is silent too" "" "$(cat "$T/.err")"

harness "" 702
check "pid_is_app REFUSES a pid whose cmdline is a different app (rc 1)" "rc=1" "$(cat "$T/.rc")"

# ================================================================================================
echo
echo "3. the two report paths that print an argv (ndt app_stop / apps_orphans)"
# ================================================================================================
# These need no rebind: the pid is above pid_max, so /proc/<pid>/cmdline cannot exist and the
# real path is exercised verbatim.
#
# 🔴 UNIQUENESS IS ASSERTED, not assumed. The first draft anchored one site on "vCPU / " and
# `grep -m1` handed back a COMMENT 790 lines earlier -- a case that reads as green while
# testing a line of prose. An anchor that matches 0 or 2+ lines is a failure, never a fallback.
unique_line() {   # <file> <fixed anchor> -- the one matching line, or nothing (+ reason on fd 3)
    local n
    n="$(grep -cF -- "$2" "$1")"
    [[ "$n" == 1 ]] || { echo "anchor '$2' matches $n lines in ${1##*/} (want exactly 1)" >&3; return 1; }
    grep -F -m1 -- "$2" "$1"
}
# 2026-09-03 merge note: fix/g6-ndt-apps-liveness added a second `cut -c1-90` site
# (app_wait_stopped), so that anchor stopped being unique -- which this loop is built to refuse.
# Each site now carries its own unique anchor, and the new site is covered rather than ignored.
#
# 2026-09-03, again: fix/apps-stop-kills-the-group added two more argv-printing sites -- the
# survivor list in app_verify_stopped, and the second branch of apps_orphans (children with no
# pidfile and no signature). `cut -c1-80` stopped being unique for exactly the reason above, so
# the apps_orphans row now anchors on its own prefix and the two new sites are covered rather
# than swept under a broadened anchor. Every one of the five reads a /proc file that will not
# exist, which is the whole point of this section.
#
# The anchors carry no `|`: this loop splits each spec on it. That is also why each site's own
# prefix (its indentation and leading words) has to be distinct in ndt -- two sites that differ
# only after a pipe cannot both be named here.
for spec in "app_stop's argv line|info \"  pid \$pid: \$(tr|info" \
            "app_wait_stopped's argv line (g6)|err \"   pid \$pid: \$(tr|err" \
            "apps_orphans' argv line|err \"    pid \$pid  \$(tr|err" \
            "apps_orphans' orphaned-children argv line|err \"      \$(tr|err" \
            "app_verify_stopped's survivor argv line|err \"      it is \$(tr|err" \
            "app_kill_by_existence's argv line|err \"   it is \$(tr|err"; do
    IFS='|' read -r label anchor stub <<<"$spec"
    if ! src="$(unique_line "$NDT" "$anchor" 3>"$T/.why")"; then
        t_bad "$label is silent for a pid that cannot exist" "$(cat "$T/.why")"
        continue
    fi
    got="$(stderr_of "$stub() { printf '%s\n' \"\$*\"; }; pid=$GONE; $src")"
    check "$label is silent for a pid that cannot exist" "" "$got"
done

# ================================================================================================
echo
echo "4. the half that forbids 'throw all stderr away'"
# ================================================================================================
# A mutant that opens the function with `exec 2>/dev/null` passes every case above. This case is
# the one it cannot pass: a real error raised by an unrelated command in the same function must
# still reach the caller.
harness 'app_sig() { echo "THE-SIGNATURE-CANNOT-BE-COMPUTED" >&2; echo "network_state_recorder.py"; }' 700
noisy="$(cat "$T/.err")"
[[ "$noisy" == *THE-SIGNATURE-CANNOT-BE-COMPUTED* ]] \
    && t_ok "🔑 a REAL error inside pid_is_app still reaches the caller" \
    || t_bad "🔑 a REAL error inside pid_is_app still reaches the caller" \
             "stderr was [$noisy] -- a blanket silencer would look identical to the fix"

# ================================================================================================
echo
echo "5. the rest of the family"
# ================================================================================================
# Behavioural where the line can be run offline: the site's own source line is lifted from its
# own file, given a path that cannot be opened, and executed. `bash -n` decides whether the line
# stands alone; a line that does not (a pipeline whose awk script continues below it) is run
# through its first $( ) instead. A site that yields neither FAILS -- it is never skipped
# quietly, because an instrument that gives up looks exactly like a site that passed.
# 🔴 `bash -n` is NOT the mode selector. A continuation line like
#     "$q" "?" "$(tr ... < "/proc/$q/cmdline" | cut -c1-200)"
# parses perfectly AND runs the pid as a command -- syntactic validity is not the same question
# as "is this a whole command". The table below says which mode each site takes, and the mode is
# checked with `bash -n` afterwards rather than chosen by it.
runnable() {   # <file> <anchor> <line|subst> -- prints a runnable snippet, or nothing
    local src frag
    src="$(unique_line "$1" "$2")" || return 1
    [[ -n "$src" ]] || return 1
    if [[ "$3" == line ]]; then
        bash -n <<<"$src" 2>/dev/null && printf '%s\n' "$src"
        return
    fi
    frag="$(python3 - "$src" <<'PY'
import sys
s = sys.argv[1]; i = s.find('$(')
if i < 0: sys.exit(1)
d, j = 0, i + 1
while j < len(s):
    if s[j] == '(': d += 1
    elif s[j] == ')':
        d -= 1
        if d == 0: break
    j += 1
print(s[i + 2:j])
PY
)" || return 1
    bash -n <<<"$frag" 2>/dev/null && printf '%s\n' "$frag"
}

mkdir -p "$T/behavioral-model"
# file | anchor | mode | prelude that makes the path unopenable
FAMILY=(
  "tools/test_workflow/test_teardown_guards.sh|args=\"\$(tr|line|d=$T/no-such-proc-dir"
  "tests/shell/test_ndt_app_orphans.sh|mapfile -d '' -t argv|line|pid=$GONE; argv=()"
  "tests/shell/test_ep4_gate_and_abort_evidence.sh|hdr=\$(wc -c|line|empty_file="
  "tests/shell/test_preflight_instrument_self_failures.sh|read -r LPORT|line|T=$T/no-such-dir"
  "tools/remote-lab/host_witness.sh|IFS= read -r -d '' cmd|line|PROCFS=$T/no-such-proc; pid=$GONE"
  "tools/remote-lab/ndtwin-vm.sh|a0=\"\"; IFS= read|line|d=$T/no-such-proc-dir"
  "tools/remote-lab/ndtwin-vm.sh|cut -c1-200|subst|q=$GONE"
  "tools/remote-lab/ndtwin-vm.sh|/^-m\$/{getline;m=\$0}|subst|q=$GONE"
  "tools/remote-lab/p4_patch_preflight.sh|patch -p1 --dry-run|line|cd $T; f=no-such.patch"
)
for row in "${FAMILY[@]}"; do
    IFS='|' read -r rel anchor mode prelude <<<"$row"
    f="$REPO/$rel"
    name="${rel##*/} ($anchor)"
    if [[ ! -f "$f" ]]; then t_bad "$name is silent" "no such file: $f"; continue; fi
    snip="$(runnable "$f" "$anchor" "$mode" 3>"$T/.why")"
    if [[ -z "$snip" ]]; then t_bad "$name is silent" "no runnable snippet ($mode): $(cat "$T/.why" 2>/dev/null)"; continue; fi
    check "$name is silent" "" "$(stderr_of "$prelude; $snip")"
done

# The two `tr ... | awk '` sites in ndtwin-vm.sh and ndt:894 are multi-line commands: 209/263
# open an awk program that continues below, and 894 would start the stack. They get a static
# ordering guard instead -- weaker than the cases above, and named as such.
# 2026-09-03 merge note: this guard used to read the three sites BY LINE NUMBER (ndt:894). Five
# branches merged above that line moved it to 954; the guard kept reading 894 -- a comment --
# and stayed green while M14 mutated the real line. Sites are now found by an order-agnostic
# content anchor, every occurrence is checked, and the count is asserted: a moved line still
# gets read, a reverted line is flagged by the regex rather than by vanishing, and a fourth
# site turns the count red instead of going unread.
static_bad=0; static_seen=0
while IFS=$'\t' read -r rel anchor want; do
    [[ -z "$rel" ]] && continue
    f="$REPO/$rel"
    n="$(grep -cF -- "$anchor" "$f")"
    [[ "$n" == "$want" ]] || echo "             $rel: anchor '$anchor' matches $n lines (want $want)"
    while IFS= read -r src; do
        static_seen=$((static_seen+1))
        # an input redirection from a path, textually ahead of a stderr redirection, on one line
        [[ "$src" =~ \<[[:space:]]*\"[^\"]*\"[^\|]*(2\>|\&\>) ]] && { static_bad=$((static_bad+1)); echo "             $rel: $src"; }
    done < <(grep -F -- "$anchor" "$f")
done <<'EOF'
tools/remote-lab/ndtwin-vm.sh	"/proc/$1/cmdline"	2
tools/test_workflow/ndt	bash "$STACK" up ovs	1
EOF
check "static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)" "3 0" "$static_seen $static_bad"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
