#!/usr/bin/env bash
#
# Mutation gate for tests/browser/test_ndt_serve_page.py -- the ndt serve page, v2 (React, built
# from tools/ndt_serve/web into tools/ndt_serve/static), in headless Chrome
# (doc/audit/2026-09-27_ndt-serve-gui/SCOPE-v2.md section 5).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way the page, or the server behind it, could break a guarantee of
# section 5 -- the token somewhere it can be read back, a second key trade, a key left in the
# address bar, a poll that does not stop, a write on load, a dialog that asks less than the server
# says, a write without its dry run, an inline script -- and must turn the ONE browser case it
# names red, for the reason it names (a fixed text of that case's failure message).
#
# Three kinds of mutant, each a COPY in a temp dir; the worktree is never written:
#   * page (web/src/**.ts, .tsx): web/ is copied without node_modules/ and dist/, node_modules is
#     a symlink to the worktree's, the edit is made in the copy, and `npm run build` (tsc, vite,
#     the manual, BUILD.json) writes the copy's own static/ via NDT_SERVE_STATIC_OUT;
#   * server (serve.py): the copy is edited, nothing is rebuilt;
#   * bundle (static/index.html): the built file in the copy is edited -- the CSP positive control.
# The suite is pointed at the copy with NDT_SERVE_UNDER_TEST (and NDT_UNDER_TEST, as the main gate
# does). A mutant carries the whole layout -- tools/ndt_serve/*.py, README.md, static/, beside
# tools/test_workflow/ndt with what it sources -- because serve.py reads the page from $HERE/static.
#
# 🔴 Every build and every Chrome run goes through tools/build_guard/guarded_build.sh with JOBS=1
# and LOCK_WAIT=10800, one guard call per step (the guard is re-entrant, so this gate may itself
# run under one). Before each of them the gate stops (exit 2) when / or its temp dir's file system
# has less than 2 GB free. Each mutant's directory is removed once its case has run.
#
# 🔴 Leftovers: the suite prints "chrome leftovers (<class>): N" when a class's Chrome is closed,
# and every case's temp dirs -- servers, stubs, Chrome profiles -- live under the mutant's own
# tmp/ (TMPDIR). After every run the gate reads /proc for any process whose command line still
# names that directory (detection only: nothing is signalled, nothing is looked up by name).
# A leftover in any run makes the gate exit 2, whatever the verdicts.
#
# 🔴 A mutation that will not apply (its anchor is not there the number of times the gate says),
# a mutant that does not build, the named case staying green, or the named case going red for
# another reason than the one named, counts as SURVIVED -- never as skipped.
#
# 🔴 A mutation documented as EQUIVALENT (another part of the page still holds the guarantee, so no
# case can see it) is run as well and must stay green; one that goes red makes the gate exit 1,
# because then the comment that calls it equivalent is wrong.
#
# Provenance: the gate prints its own header first (date, git HEAD, uncommitted path count, python,
# node, its own sha256) and its last line is rc=N, however it ends.
#
# 🔴 Guards its own baseline, before any mutation:
#   1. the whole suite on the committed page, through the same layout: green, nothing skipped,
#      every case a mutation names run ok, and no leftover;
#   2. the copy-and-build pipeline the page mutants go through, with no edit, must reproduce the
#      committed static/ byte for byte (BUILD.json included) -- so a page mutant differs from the
#      page the baseline ran on by its one edit and nothing else.
# At the end, the sha256 of every file under test must be what it was at the start (node_modules
# excluded; baseline 2 is what vouches for it).
#
#     tests/shell/mutate_ndt_serve_page.sh               # ~7 min; calls the guard per step
#     JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh tests/shell/mutate_ndt_serve_page.sh
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (no space / baseline red,
#       skipped or incomplete / the build pipeline does not reproduce the bundle / a leftover /
#       harness), 3 a file under test changed while the gate ran.
# The whole body is one { ... } block, so bash has parsed all of it before running any: an edit to
# this file while it runs (it takes minutes) cannot shift what the running copy reads next.
{
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NODE_BIN="${NODE_BIN:-$HOME/.local/node/bin}"
BK=""
# The last line is always rc=N, whichever way this ends (a refusal included).
# [Co-developed with claude code -- Adam] How a run ENDS is part of its record. A run stopped by a
# signal, or one that ends before its verdict line, says INCOMPLETE and never exits 0: the EXIT trap
# alone printed rc=0 for a page gate killed with SIGTERM (10-01), which reads as a pass.
# the end lines go to the stdout this gate STARTED with (fd 7): a trap that fires while a command
# redirected to a file is running prints into that file -- the rebuild gate's went into ci.log
exec 7>&1
GATE_SIGNAL=""
GATE_VERDICT=0
trap 'GATE_SIGNAL=TERM; exit 143' TERM
trap 'GATE_SIGNAL=INT; exit 130' INT
trap 'GATE_SIGNAL=HUP; exit 129' HUP
gate_end() {   # the EXIT trap; $1 = the status the shell is exiting with
    local rc="$1"
    [[ -n "$BK" ]] && rm -rf "$BK"
    if [[ -n "$GATE_SIGNAL" ]]; then
        echo "INCOMPLETE: stopped by SIG$GATE_SIGNAL before its verdict -- not a verdict" >&7
    elif (( ! GATE_VERDICT )); then
        echo "INCOMPLETE: ended before its verdict line -- not a verdict" >&7
        (( rc != 0 )) || rc=2
    fi
    echo "rc=$rc" >&7
    exit "$rc"
}
trap 'gate_end $?' EXIT
# This gate's own provenance, before anything else.
echo "# date -Is: $(date -Is)"
echo "# argv: $0 $*"
# A git that fails prints "?" -- never an empty head or "0", which would read as a clean tree.
head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null) || head="?"
if porcelain=$(git -C "$REPO" status --porcelain 2>/dev/null); then
    porcelain=$(grep -c . <<<"$porcelain")
else
    porcelain="?"
fi
echo "# git rev-parse HEAD: $head"
echo "# git status --porcelain | wc -l: $porcelain"
echo "# python3: $(command -v python3) $(python3 -c 'import sys; print(sys.version.replace(chr(10), " "))')"
echo "# node -v: $("$NODE_BIN/node" -v 2>&1)   npm -v: $(PATH="$NODE_BIN:$PATH" "$NODE_BIN/npm" -v 2>&1)"
echo "# this gate: $(sha256sum "${BASH_SOURCE[0]}" | cut -c1-64)"
# ONLY="label label ..." (or comma-separated) runs only the named mutations -- with both baselines,
# this header and the same verdict lines -- and says so in the header and the totals. A label that
# names no mutation refuses (exit 2), so a typo cannot pass as a clean partial run.
ONLY="${ONLY:-}"
ONLY="${ONLY//,/ }"
ONLY_SEEN=" "
for l in $ONLY; do
    grep -qE "^mutant $l " "${BASH_SOURCE[0]}" || { echo "REFUSED: ONLY names $l, which is no mutation of this gate"; exit 2; }
done
[[ -z "$ONLY" ]] || echo "# ONLY=$ONLY -- a PARTIAL run of the named mutation(s): not this gate's verdict on the page"
TEST="$REPO/tests/browser/test_ndt_serve_page.py"
DRIVER="$REPO/tests/browser/cdp_pipe.py"
HARNESS=("$REPO/tests/python/test_ndt_serve.py" "$REPO/tests/python/test_ndt_serve_gui.py"
         "$REPO/tests/python/test_ndt_serve_cells.py")
SERVE_DIR="$REPO/tools/ndt_serve"
WEB="$SERVE_DIR/web"
GUARD="$REPO/tools/build_guard/guarded_build.sh"
MIN_FREE_KB=$((2 * 1024 * 1024))
README_MD="$SERVE_DIR/README.md"
NDT="$REPO/tools/test_workflow/ndt"
NDT_SIDE=("$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh"
          "$REPO/tools/test_workflow/components.env")
# the files the mutations below edit (in a copy)
SERVE_PY="$SERVE_DIR/serve.py"
INDEX_HTML="$SERVE_DIR/static/index.html"
SESSION_TS="$WEB/src/api/session.ts"
DIALOG_TSX="$WEB/src/components/ConfirmDialog.tsx"
REFRESH_TS="$WEB/src/hooks/useAutoRefresh.ts"
JOBLOG_TS="$WEB/src/hooks/useJobLog.ts"
TABBAR_TSX="$WEB/src/components/TabBar.tsx"
APPSTAB_TSX="$WEB/src/components/tabs/AppsTab.tsx"
ACTIONSTAB_TSX="$WEB/src/components/tabs/ActionsTab.tsx"
APP_TSX="$WEB/src/NdtServeApp.tsx"
MAIN_TSX="$WEB/src/main.tsx"

refuse() { echo "REFUSED: $*"; exit 2; }

shopt -s nullglob
PYS=("$SERVE_DIR"/*.py)
STATICS=()
for f in "$SERVE_DIR"/static/*; do [[ -f "$f" ]] && STATICS+=("$f"); done
shopt -u nullglob
(( ${#PYS[@]} > 0 && ${#STATICS[@]} > 0 )) && [[ -f "$TEST" && -f "$DRIVER" && -f "$INDEX_HTML" ]] \
    || refuse "the layout is not there (tools/ndt_serve/*.py, static/, the suite, its driver)"
[[ -x "$GUARD" ]] || refuse "no $GUARD"
[[ -x "$NODE_BIN/node" && -x "$NODE_BIN/npm" ]] || refuse "no node/npm in $NODE_BIN (set NODE_BIN)"
[[ -d "$WEB/node_modules" ]] || refuse "no $WEB/node_modules: the page mutants are built against it"
mapfile -t WEB_SRC < <(find "$WEB" -path "$WEB/node_modules" -prune -o -path "$WEB/dist" -prune -o -type f -print \
                       | LC_ALL=C sort)
# The files under test, the suite and what it imports: a change to any while this runs means the
# results are about two versions.
SUBJECTS=("${PYS[@]}" "$README_MD" "${STATICS[@]}" "${WEB_SRC[@]}" "$NDT" "${NDT_SIDE[@]}" "$TEST" "$DRIVER"
          "${HARNESS[@]}")
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-page-gate-XXXXXX")   # short: Chrome's socket lives under it
BASE_SHA=$(sha256sum "${SUBJECTS[@]}")
T0=$SECONDS

SURVIVORS=0
MUTATIONS=0
LEFTOVER_RUNS=0
CASES=(Load.test_the_key_leaves_the_address_bar
       Load.test_the_key_is_traded_exactly_once
       Load.test_the_token_is_not_in_the_dom
       Load.test_the_token_is_not_in_browser_storage
       Load.test_loading_the_page_writes_nothing
       Load.test_a_used_key_opens_nothing
       Load.test_a_url_without_a_key_opens_nothing
       Load.test_the_page_sees_no_csp_violation
       Profile.test_the_token_is_in_no_file_of_the_profile
       Confirm.test_up_asks_for_the_typed_word
       Confirm.test_no_claim_puts_claim_first
       Confirm.test_an_app_start_shows_the_dry_run_and_claim_first
       Confirm.test_a_claim_not_yours_puts_claim_first
       Confirm.test_measuring_or_declared_makes_it_typed
       Confirm.test_claim_asks_for_no_typed_word
       Confirm.test_the_focus_starts_on_cancel
       Confirm.test_enter_on_confirm_does_not_confirm
       Confirm.test_a_double_click_posts_once
       Confirm.test_the_dialog_shows_the_argv_the_dry_run_answered
       Confirm.test_the_write_is_posted_after_its_dry_run
       Refresh.test_refresh_reads_while_shown_and_idle
       Refresh.test_refresh_stops_while_measuring
       Refresh.test_refresh_stops_while_declared
       Refresh.test_refresh_stops_while_hidden_and_resumes_when_shown
       Refresh.test_a_measuring_pause_probes_measuring_alone
       Refresh.test_a_measuring_pause_reads_nothing_while_hidden
       Refresh.test_shown_again_while_measuring_probes_once_60_s_later
       Refresh.test_a_declared_pause_is_resumed_by_the_probe
       ProbeTimeout.test_a_probe_that_times_out_keeps_the_pause_and_the_next_one_ends_it
       JobLog.test_job_log_stops_on_close
       JobLog.test_job_log_stops_when_the_job_ends
       JobLog.test_job_log_stops_while_hidden_and_resumes)

free_enough() {   # exit 2 under 2 GB free on / or on the file system of this gate's temp dir
    local kb
    kb=$(df -Pk / "$BK" | awk 'NR > 1 {print $4}' | sort -n | head -1)
    (( kb >= MIN_FREE_KB )) || refuse "$((kb / 1024)) MB free; this gate wants 2048 MB before every build and run"
}

guarded() {   # $1 = dir to run in, $2... = the command: one guard lock per call
    local d="$1"; shift
    (cd "$d" && JOBS=1 LOCK_WAIT="${LOCK_WAIT:-10800}" "$GUARD" env PATH="$NODE_BIN:$PATH" "$@")
}

layout() {   # $1 = dir -- the service with its committed page, and ndt with what it sources
    local d="$1"
    mkdir -p "$d/tools/ndt_serve" "$d/tools/test_workflow" "$d/tmp"
    cp "${PYS[@]}" "$README_MD" "$d/tools/ndt_serve/"
    cp -r "$SERVE_DIR/static" "$d/tools/ndt_serve/static"
    cp "$NDT" "${NDT_SIDE[@]}" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/ndt"
}

with_web() {   # $1 = dir -- a copy of web/ in its tools/ndt_serve, node_modules a link to the worktree's
    tar -C "$SERVE_DIR" --exclude=web/node_modules --exclude=web/dist -cf - web | tar -C "$1/tools/ndt_serve" -xf - \
        || refuse "could not copy web/"
    ln -s "$WEB/node_modules" "$1/tools/ndt_serve/web/node_modules"
}

build() {   # $1 = dir -- its web/ built into its own static/ (emptied first); the log is $1/build.log
    local d="$1"
    free_enough
    rm -f "$d/tools/ndt_serve/static/"*
    guarded "$d/tools/ndt_serve/web" env NDT_SERVE_STATIC_OUT="$d/tools/ndt_serve/static" npm run build \
        > "$d/build.log" 2>&1
}

run_against() {   # $1 = dir, $2... = unittest ids (none = the whole file); every temp dir under $1/tmp
    local d="$1"; shift
    guarded "$d" env TMPDIR="$d/tmp" PYTHONDONTWRITEBYTECODE=1 NDT_SERVE_UNDER_TEST="$d/tools/ndt_serve" \
        NDT_UNDER_TEST="$d/tools/test_workflow/ndt" timeout 900 python3 "$TEST" "$@" 2>&1
}

stray() {   # $1 = dir -- pids of processes whose command line names it, from /proc (detection only)
    python3 - "$1/" <<'PY'
import os, sys
mark, me = sys.argv[1].encode(), os.getpid()
hits = []
for d in os.listdir("/proc"):
    if d.isdigit() and int(d) != me:
        try:
            with open("/proc/%s/cmdline" % d, "rb") as f:
                if mark in f.read():
                    hits.append(d)
        except OSError:
            pass
print(" ".join(hits))
PY
}

leftovers() {   # $1 = dir, $2 = the run's output -- prints what was left; counts a run that left anything
    local d="$1" out="$2" pids chrome i
    chrome=$(grep -E '^chrome leftovers \(' <<<"$out" | tr '\n' ' ')
    pids=$(stray "$d")
    for i in 1 2 3 4 5 6 7 8 9 10; do       # a job's stub on its way out gets 5 s
        [[ -z "$pids" ]] && break
        sleep 0.5
        pids=$(stray "$d")
    done
    printf '             leftovers: %s/proc after the run: %s\n' "${chrome:-no chrome line } " "${pids:-none}"
    if [[ -n "$pids" ]] || grep -qE '^chrome leftovers \([^)]*\): [1-9]' <<<"$out" \
            || ! grep -qE '^chrome leftovers \(' <<<"$out"; then
        LEFTOVER_RUNS=$((LEFTOVER_RUNS+1))
        echo "             ^^^ LEFTOVER (or no leftover line at all): this gate will exit 2"
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from the function's
# own `local ... file="$2" old="$3"` line, and the expected count from the argument after the new text.
MUT_DIR=""
MUT_STATE=""
MUT_WEB=0
MUT_N=0
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement, $5 = anchor count (1)
    local label="$1" file="$2" old="$3" new="$4" want="${5:-1}"
    if [[ -n "$ONLY" && " $ONLY " != *" $label "* ]]; then
        MUT_STATE=skip
        return 0
    fi
    ONLY_SEEN+="$label "
    MUT_N=$((MUT_N+1))
    MUT_DIR="$BK/$(printf '%02d' "$MUT_N")"   # numbered, not $label: Chrome's socket path lives under it
    MUT_STATE=ready
    MUT_WEB=0
    layout "$MUT_DIR"
    echo "$label" > "$MUT_DIR/label"
    also "$file" "$old" "$new" "$want"
}

also() {   # $1 = file to mutate, $2 = the anchor, $3 = its replacement, $4 = anchor count (1): one more edit
    local file="$1" old="$2" new="$3" want="${4:-1}"
    [[ "$MUT_STATE" == ready ]] || return 0
    if [[ "$file" == "$WEB"/* ]] && (( MUT_WEB == 0 )); then
        with_web "$MUT_DIR"
        MUT_WEB=1
    fi
    python3 - "$MUT_DIR/${file#$REPO/}" "$old" "$new" "$want" <<'PY' || MUT_STATE=noapply
import sys
p, a, b, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
s = open(p, encoding="utf-8").read()
if s.count(a) != want:
    sys.stderr.write("anchor found %d time(s), the gate wants %d: %s\n" % (s.count(a), want, a[:70]))
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

report() {   # $1 = mutation name, $2 = Class.test_case that must go red, $3 = why (fixed text in its failure)
    local out rc id="$2" why="$3" t=$SECONDS
    local name="${id##*.}"
    [[ "$MUT_STATE" == skip ]] && return 0
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$MUT_STATE" == noapply ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (the mutation did not apply -- the anchor moved)\n' "$1"
        rm -rf "$MUT_DIR"
        return
    fi
    if (( MUT_WEB )) && ! build "$MUT_DIR"; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (the mutant does not build)\n' "$1"
        tail -15 "$MUT_DIR/build.log" | cut -c1-220 | sed 's/^/             /'
        rm -rf "$MUT_DIR"
        return
    fi
    free_enough
    out=$(run_against "$MUT_DIR" "$id"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $name \(" <<<"$out" && grep -qF -- "$why" <<<"$out"; then
        printf '  caught   %-70s (%s went red, %d s)\n' "$1" "$name" $((SECONDS - t))
        { grep -m1 -E '^[A-Za-z_.]*Error: ' <<<"$out"; grep -m1 -F -- "$why" <<<"$out"; } | awk '!seen[$0]++' \
            | cut -c1-240 | sed 's/^[[:space:]]*/             /'
    elif ! grep -qE "^$name \(" <<<"$out"; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s did not run at all)\n' "$1" "$name"
        grep -E '^(FAIL|ERROR):|Error:|^Ran |^OK|^FAILED' <<<"$out" | cut -c1-240 | sed 's/^/             /'
    elif [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $name \(" <<<"$out"; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s went red, but not with "%s")\n' "$1" "$name" "$why"
        grep -E '^(FAIL|ERROR):|Error:|^Ran |^OK|^FAILED' <<<"$out" | cut -c1-240 | sed 's/^/             /'
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s stayed green -- that case proves nothing)\n' "$1" "$name"
        grep -E '^(FAIL|ERROR):|^Ran |^OK|^FAILED|skipped' <<<"$out" | cut -c1-240 | sed 's/^/             /'
    fi
    leftovers "$MUT_DIR" "$out"
    rm -rf "$MUT_DIR"
}

# A mutation this gate documents as EQUIVALENT -- the case cannot see it because another part of the
# page still holds the guarantee -- is run too, and must stay GREEN. If it goes red, the claim in the
# comment above it is wrong, which counts like a survivor (exit 1): the documentation is.
EQUIVALENTS=0
BROKEN_CLAIMS=0
equivalent() {   # $1 = mutation name, $2 = Class.test_case that must stay green, $3 = what still holds it
    local out rc id="$2" t=$SECONDS
    local name="${id##*.}"
    [[ "$MUT_STATE" == skip ]] && return 0
    EQUIVALENTS=$((EQUIVALENTS+1))
    if [[ "$MUT_STATE" == noapply ]] || { (( MUT_WEB )) && ! build "$MUT_DIR"; }; then
        BROKEN_CLAIMS=$((BROKEN_CLAIMS+1))
        printf '  CLAIM?   %-70s (did not apply or build: nothing was shown)\n' "$1"
        rm -rf "$MUT_DIR"
        return
    fi
    free_enough
    out=$(run_against "$MUT_DIR" "$id"); rc=$?
    if [[ "$rc" -eq 0 ]] && grep -qE "^$name \(.*\) \.\.\. ok$" <<<"$out"; then
        printf '  equiv.   %-70s (%s stayed green, %d s: %s)\n' "$1" "$name" $((SECONDS - t)) "$3"
    else
        BROKEN_CLAIMS=$((BROKEN_CLAIMS+1))
        printf '  CLAIM?   %-70s (%s did NOT stay green -- the equivalence claim is wrong)\n' "$1" "$name"
        grep -E '^(FAIL|ERROR):|Error:|^Ran |^OK|^FAILED' <<<"$out" | cut -c1-240 | sed 's/^/             /'
    fi
    leftovers "$MUT_DIR" "$out"
    rm -rf "$MUT_DIR"
}

if changed=$(git -C "$REPO" status --porcelain -- "$TEST" "$DRIVER" "$SERVE_DIR" 2>/dev/null); then
    changed=$(grep -c . <<<"$changed")
else
    changed="?"
fi
echo "# changed paths under test vs HEAD: $changed"
df -h / "$BK" | sed 's/^/  /'
echo
echo "baseline 1 -- the whole suite on the committed page (green, every case run ok, none skipped, no leftover):"
layout "$BK/base"
free_enough
t=$SECONDS
out=$(run_against "$BK/base"); brc=$?
grep -E ' \.\.\. ' <<<"$out" | sed 's/ (__main__\.[^)]*)//; s/^/  /'
printf '  %s: %s / %s (%d s)\n' "$(basename "$TEST")" "$(grep -E '^Ran ' <<<"$out" | tail -1)" \
       "$(grep -E '^(OK|FAILED)' <<<"$out" | tail -1)" $((SECONDS - t))
leftovers "$BK/base" "$out"
if (( brc != 0 )); then
    echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"
    grep -E '^(FAIL|ERROR):|Error:' <<<"$out" | cut -c1-240 | sed 's/^/    /'
    exit 2
fi
if grep -qE '\.\.\. skipped' <<<"$out" || [[ "$(grep -E '^(OK|FAILED)' <<<"$out" | tail -1)" != "OK" ]]; then
    echo "  a baseline case was SKIPPED or the run did not end OK -- a skipped page case proves nothing"
    exit 2
fi
for c in "${CASES[@]}"; do
    if ! grep -qE "^${c##*.} \(.*\) \.\.\. ok$" <<<"$out"; then
        echo "  the baseline did not run $c ok -- a mutation naming it would prove nothing"
        exit 2
    fi
done
(( LEFTOVER_RUNS == 0 )) || refuse "the baseline run left processes behind"
rm -rf "$BK/base"
echo
echo "baseline 2 -- web/ copied and built the way every page mutant is, with no edit, is the committed static/:"
mkdir -p "$BK/rebuild/tools/ndt_serve/static"
with_web "$BK/rebuild"
t=$SECONDS
build "$BK/rebuild" || { tail -20 "$BK/rebuild/build.log"; refuse "the unmutated copy of web/ does not build"; }
built=$(cd "$BK/rebuild/tools/ndt_serve/static" && ls -A | LC_ALL=C sort)
committed=$(cd "$SERVE_DIR/static" && ls -A | LC_ALL=C sort)
[[ "$built" == "$committed" ]] || refuse "the build writes other files than are committed: $(echo $built) vs $(echo $committed)"
for f in $built; do
    cmp -s "$BK/rebuild/tools/ndt_serve/static/$f" "$SERVE_DIR/static/$f" \
        || refuse "the copy-and-build pipeline does not reproduce static/$f -- a page mutant would differ by more than its edit"
    printf '  same     %-12s %s\n' "$f" "$(sha256sum < "$SERVE_DIR/static/$f" | cut -c1-16)"
done
echo "  (built in $((SECONDS - t)) s)"
rm -rf "$BK/rebuild"
echo

# === the token: not in the DOM, not in storage, not in the profile ================================

mutant t1-dom "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  document.body.dataset.t = j.token;'
report "T1: the token is written into a data-* attribute of <body> (DOM)" \
       Load.test_the_token_is_not_in_the_dom "the token is in the page's DOM"

# The judge's G-N8 positive control for the profile scan: a value in an IndexedDB store of an
# innocuously named database. indexedDB.databases() lists the name, not the value, so only the
# scan of the profile's files can see the token itself.
mutant t2-indexeddb "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  const tok = j.token;
  const rq = indexedDB.open("ndt-page");
  rq.onupgradeneeded = () => rq.result.createObjectStore("kv");
  rq.onsuccess = () => rq.result.transaction("kv", "readwrite").objectStore("kv").put(tok, "t");'
report "T2: the token is put in IndexedDB (only the profile's files hold it; G-N8)" \
       Profile.test_the_token_is_in_no_file_of_the_profile "the token is in a file of the browser profile"

# v1's G13, in TS: spelled so that no static lint of the word sees it.
mutant t3-session-storage "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  (window as unknown as Record<string, Storage>)["session" + "Storage"].setItem("t", j.token);'
report "T3: the token is also put in sessionStorage (spelled past a static lint)" \
       Load.test_the_token_is_not_in_browser_storage "the token is in browser storage"

# Not the token: the page keeping ANYTHING in storage (here, which tab is open -- TabBar.tsx says it
# lives in React state only) is red too. The positive control for the case's stricter half.
mutant t4-tab-in-storage "$TABBAR_TSX" \
    'onClick={() => onChange(id)}' \
    'onClick={() => { localStorage.setItem("ndt-serve-tab", id); onChange(id); }}'
report "T4: the page remembers its open tab in localStorage (no token in it)" \
       Load.test_the_token_is_not_in_browser_storage "the page left something in browser storage"

mutant t5-cookie "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  document.cookie = "t=" + j.token;'
report "T5: the token is written into a cookie" \
       Load.test_the_token_is_not_in_browser_storage "the token is in browser storage"

mutant t6-indexeddb-database "$APP_TSX" \
    '  const firstRead = useCallback(() => {' \
    '  const firstRead = useCallback(() => {
    void indexedDB.open("ndt-page-cache");'
report "T6: the page opens an IndexedDB database (no token in it): indexedDB.databases() must see it" \
       Load.test_the_token_is_not_in_browser_storage "the page left something in browser storage"

# === the key: traded once, gone from the address bar, a used key and no key open nothing ===========

mutant s1-second-trade "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  void call("POST", "/session", { nonce });'
report "S1: the session module trades the key a second time (G-N10)" \
       Load.test_the_key_is_traded_exactly_once "not exactly one answered 200"

mutant f1-no-replacestate "$SESSION_TS" \
    '  history.replaceState(null, "", location.pathname + location.search); // the key leaves the address bar first' \
    '  // F1: the key stays in the address bar'
report "F1: history.replaceState is gone (the key stays in the address bar)" \
       Load.test_the_key_leaves_the_address_bar "the key is still in the address bar"

mutant p1-key-kept "$SERVE_PY" \
    '                    del self.book[i]' \
    '                    pass'
report "P1: the server keeps a used key (serve.py Nonces.take)" \
       Load.test_a_used_key_opens_nothing "the second load of a used key opened a session"

mutant p2-empty-key "$SESSION_TS" \
    'const KEY_RE = /^#k=([A-Za-z0-9_-]{16,64})$/;' \
    'const KEY_RE = /^(?:#k=)?([A-Za-z0-9_-]{0,64})$/;'
report "P2: the page trades a key it does not have (an empty hash)" \
       Load.test_a_url_without_a_key_opens_nothing "a URL with no key"

# === loading writes nothing; CSP ===================================================================

mutant l1-release-on-load "$SESSION_TS" \
    '  holdToken(j.token);' \
    '  holdToken(j.token);
  void call("POST", "/release", {});'
report "L1: the page releases the lab the moment it has the token (v1 G14)" \
       Load.test_loading_the_page_writes_nothing "loading the page wrote"

# The CSP positive control: the built index.html gets an inline script, which the server's CSP
# ('self' only) blocks -- data-csp-violations must count it, which is also the proof the counter works.
mutant x1-inline-script "$INDEX_HTML" \
    '    <div id="root"></div>' \
    '    <div id="root"></div>
    <script>document.title = "inline";</script>'
report "X1: an inline <script> in the built index.html (CSP positive control)" \
       Load.test_the_page_sees_no_csp_violation "CSP violation(s) (data-csp-violations)"

# X1 is caught by the buffered ReportingObserver (the inline script is blocked before main.tsx runs).
# X2 proves the other counter: the observer is switched off and the page makes a violation AFTER the
# listener is registered -- a style attribute, which style-src 'self' blocks -- so only the
# securitypolicyviolation listener can count it.
mutant x2-listener-only "$MAIN_TSX" \
    'if (typeof ReportingObserver === "function") {' \
    'document.body.setAttribute("style", "color: red"); // X2: a violation after load
if (document.body.dataset.x2Never === "on") { // X2: the observer never starts'
report "X2: no ReportingObserver, and a style attribute set at run time (the listener's positive control)" \
       Load.test_the_page_sees_no_csp_violation "CSP violation(s) (data-csp-violations)"

# === how hard the dialog asks: the server's confirm_policy, the page's measuring rule ==============

mutant c1-up-plain "$SERVE_PY" \
    '        return "typed", True' \
    '        return "plain", True'
report "C1: serve.py confirm_policy says plain for up/down" \
       Confirm.test_up_asks_for_the_typed_word "the Up dialog asks for no typed word"

mutant c5-page-ignores-confirm "$DIALOG_TSX" \
    'const typed = (D !== null && D.confirm === "typed") || ' \
    'const typed = '
report "C5: the page ignores the server's confirm === \"typed\"" \
       Confirm.test_up_asks_for_the_typed_word "the Up dialog asks for no typed word"

mutant c2-page-ignores-own-claim "$DIALOG_TSX" \
    'if (D.needs_own_claim && !(L && L.claim_is_yours))' \
    'if (D.needs_own_claim && !L)'
report "C2: the page ignores needs_own_claim (blocks only when /lab did not answer)" \
       Confirm.test_a_claim_not_yours_puts_claim_first 'no "claim first" blocker'

mutant c2b-server-no-own-claim "$SERVE_PY" \
    '        return "typed", True' \
    '        return "typed", False'
report "C2b: serve.py confirm_policy says up/down need no claim of your own" \
       Confirm.test_a_claim_not_yours_puts_claim_first 'no "claim first" blocker'

# Adam 09-28: no claim at all is not yours either.
mutant cf1-blocks-only-a-claim-row "$DIALOG_TSX" \
    'if (D.needs_own_claim && !(L && L.claim_is_yours))' \
    'if (D.needs_own_claim && L && L.claim !== null && !L.claim_is_yours)'
report "CF1: the page puts claim first only when there is a claim row" \
       Confirm.test_no_claim_puts_claim_first "blocker for up with no claim row"

mutant cf2-blocks-only-a-foreign-claim "$DIALOG_TSX" \
    'if (D.needs_own_claim && !(L && L.claim_is_yours))' \
    'if (D.needs_own_claim && L && L.claim !== null && L.claim !== "none" && !L.claim_is_yours)'
report "CF2: the page puts claim first only under somebody else's claim (not none, not missing)" \
       Confirm.test_no_claim_puts_claim_first 'blocker for up with `claim none`'

# Down was never seen red in the no-claim case (Up runs first there): Down alone loses its dry run.
mutant cf3-down-no-preview "$ACTIONSTAB_TSX" \
    '      word: "down",
      preview: true,' \
    '      word: "down",
      preview: false,'
report "CF3: Down asks the server for no dry run (ActionsTab), so no claim-first check for it" \
       Confirm.test_no_claim_puts_claim_first 'blocker for down with `claim none`'

# The blocker is shown, but Confirm does not wait for it: only the typed word enables it.
mutant cf4-blocker-does-not-disable "$DIALOG_TSX" \
    '        blockers.length === 0 &&' \
    '        blockers.length >= 0 &&'
report "CF4: a claim-first blocker is shown but does not keep Confirm off" \
       Confirm.test_no_claim_puts_claim_first "Confirm is on for up with \`claim none\`"

# The apps case's claim-first half: the page skips the own-claim check for apps only (the dry run and
# its argv are untouched, so the argv half stays green); and the same from the server's side.
mutant a2-apps-skip-own-claim "$DIALOG_TSX" \
    'if (D.needs_own_claim && !(L && L.claim_is_yours))' \
    'if (D.needs_own_claim && !(L && L.claim_is_yours) && !a.path.startsWith("/apps/"))'
report "A2: the page skips the claim-first check for an app start or stop" \
       Confirm.test_an_app_start_shows_the_dry_run_and_claim_first \
       "no \"claim first\" blocker for an app start under somebody else's claim"

mutant a2b-server-apps-no-own-claim "$SERVE_PY" \
    '        return "plain", True' \
    '        return "plain", False'
report "A2b: serve.py confirm_policy says an app start or stop needs no claim of your own" \
       Confirm.test_an_app_start_shows_the_dry_run_and_claim_first \
       "no \"claim first\" blocker for an app start under somebody else's claim"

mutant a1-app-no-preview "$APPSTAB_TSX" \
    '      preview: true,' \
    '      preview: false,'
report "A1: an app start or stop asks the server for no dry run (AppsTab preview: false)" \
       Confirm.test_an_app_start_shows_the_dry_run_and_claim_first "dry-run answer(s) to POST /apps/energy/start, not 1"

mutant w1-any-text "$DIALOG_TSX" \
    'typedRef.current?.value === a.word' \
    '(typedRef.current?.value ?? "") !== ""'
report "W1: any non-empty text in the typed box turns Confirm on" \
       Confirm.test_up_asks_for_the_typed_word "Confirm is on after typing only \`u\`"

mutant w2-a-prefix "$DIALOG_TSX" \
    'typedRef.current?.value === a.word' \
    '((v: string) => v !== "" && a.word.startsWith(v))(typedRef.current?.value ?? "")'
report "W2: a non-empty prefix of the word turns Confirm on" \
       Confirm.test_up_asks_for_the_typed_word "Confirm is on after typing only \`u\`"

mutant w3-starts-with-the-word "$DIALOG_TSX" \
    'typedRef.current?.value === a.word' \
    'typedRef.current?.value.startsWith(a.word) === true'
report "W3: any text that starts with the word turns Confirm on" \
       Confirm.test_up_asks_for_the_typed_word "Confirm is on after typing \`upx\`"

mutant c3-no-measuring-upgrade "$DIALOG_TSX" \
    ' || !(L && L.measuring_is_nothing)' \
    ''
report "C3: the page does not upgrade to typed while measuring" \
       Confirm.test_measuring_or_declared_makes_it_typed "no typed word for Claim while measuring"

mutant c3b-no-declared-upgrade "$DIALOG_TSX" \
    ' || (L !== null && L.declared !== null)' \
    ''
report "C3b: the page does not upgrade to typed while a measurement is declared" \
       Confirm.test_measuring_or_declared_makes_it_typed "no typed word for Claim while a measurement is declared"

mutant c4-claim-typed "$SERVE_PY" \
    '    return "plain", False   # claim, release' \
    '    return "typed", False   # C4: claim, release'
report "C4: serve.py confirm_policy says typed for claim" \
       Confirm.test_claim_asks_for_no_typed_word "the Claim dialog asks for a typed word"

# === the dialog's keyboard and mouse ===============================================================

mutant c6-focus-on-confirm "$DIALOG_TSX" \
    '      setInputsOk(ready.current());
    })();' \
    '      setInputsOk(ready.current());
      window.setTimeout(() => goRef.current?.focus(), 100);
    })();'
report "C6: Confirm takes the focus once the dialog is ready" \
       Confirm.test_the_focus_starts_on_cancel "the focus is not on Cancel"

mutant c7-enter-confirms "$DIALOG_TSX" \
    'if (e.key === "Enter") e.preventDefault(); // Enter never confirms' \
    'if (e.key === "Escape") e.preventDefault(); // C7: Enter confirms'
report "C7: Enter on Confirm is not stopped (it clicks Confirm)" \
       Confirm.test_enter_on_confirm_does_not_confirm "Enter on Confirm confirmed the write"

# All three of go()'s once-only guards: the fired ref, the button disabled in the DOM at once, and
# `sent` in its disabled= -- any one of them alone stops a second click.
mutant c8-double-post "$DIALOG_TSX" \
    'if (a === null || fired.current || view.phase !== "ready" || !ready.current()) return;' \
    'if (a === null || view.phase !== "ready" || !ready.current()) return;'
also "$DIALOG_TSX" \
    '    if (goRef.current) goRef.current.disabled = true;
' \
    ''
also "$DIALOG_TSX" \
    'disabled={view.phase !== "ready" || !inputsOk || sent}' \
    'disabled={view.phase !== "ready" || !inputsOk}'
report "C8: Confirm works twice (no fired ref, no disabled at once, no sent)" \
       Confirm.test_a_double_click_posts_once "a double click on Confirm posted more than the one write"

# Equivalent today: showModal() runs the dialog focusing steps, and at that moment Cancel is the first
# focusable element (the typed row and the checkbox are hidden, Confirm is disabled).
mutant e1-no-cancel-focus "$DIALOG_TSX" \
    '    cancelRef.current?.focus();
' \
    ''
equivalent "E1: the explicit focus() on Cancel is removed" \
       Confirm.test_the_focus_starts_on_cancel "showModal() focuses Cancel itself"

# === the dry run ===================================================================================

mutant d1-own-argv "$DIALOG_TSX" \
    '(D.argv ?? []).map((arg, i) => (' \
    '[(request?.path ?? "").slice(1), ...Object.values(request?.body ?? {}).map(String)].map((arg, i) => ('
report "D1: the dialog shows an argv the page built (path and body), not the dry run's" \
       Confirm.test_the_dialog_shows_the_argv_the_dry_run_answered "the dialog's argv is not the argv the dry run answered"

mutant d2-no-dry-run "$DIALOG_TSX" \
    'const dry = a.preview ? await post(a.path, { ...a.body, dry_run: true }) : null;' \
    'const dry = null as ApiResult<unknown> | null; // D2: no dry run'
report "D2: the page sends the write without its dry run first" \
       Confirm.test_the_write_is_posted_after_its_dry_run "the write was posted with no dry run before it"

# === the auto-refresh: reads while shown and idle, and stops on each pause condition ===============

mutant r0-no-timer "$REFRESH_TS" \
    '    timer.current = window.setTimeout(tick, REFRESH_INTERVAL_MS);' \
    '    timer.current = null;'
report "R0: the auto-refresh timer is never armed (the load's read only)" \
       Refresh.test_refresh_reads_while_shown_and_idle "timer read(s) of /lab"

mutant r1-not-hidden "$REFRESH_TS" \
    'if (document.visibilityState === "hidden") {' \
    'if ((document.visibilityState as string) === "never") {' 4
report "R1: the auto-refresh never sees the page hidden (all four === checks)" \
       Refresh.test_refresh_stops_while_hidden_and_resumes_when_shown "while the page was hidden"

mutant r1b-no-read-when-shown "$REFRESH_TS" \
    '      void tick();
    };' \
    '    };'
report "R1b: shown again, the page does not read and re-arm" \
       Refresh.test_refresh_stops_while_hidden_and_resumes_when_shown "no read of /lab after the page was shown again"

mutant r2-no-measuring-pause "$REFRESH_TS" \
    '    if (!live.current) return;
    if (measuring.current) {
      setState("paused-measuring");
      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);
      return;
    }
' \
    '    if (!live.current) return;
'
report "R2: arm() does not pause on measuring/declared" \
       Refresh.test_refresh_stops_while_measuring "while ndt status said measuring"

mutant r2a-measuring-half "$REFRESH_TS" \
    '  return lab.measuring_is_nothing === false || lab.declared !== null;' \
    '  return lab.declared !== null;'
report "R2a: only a declared measurement pauses (measuring_is_nothing ignored)" \
       Refresh.test_refresh_stops_while_measuring "while ndt status said measuring"

mutant r2b-declared-half "$REFRESH_TS" \
    '  return lab.measuring_is_nothing === false || lab.declared !== null;' \
    '  return lab.measuring_is_nothing === false;'
report "R2b: a declared measurement does not pause" \
       Refresh.test_refresh_stops_while_declared "while a measurement was declared"

mutant r6-refresh-now-resumes "$REFRESH_TS" \
    '    await readOnce(readRef.current);
    arm();
  }, []);' \
    '    await readOnce(readRef.current);
    measuring.current = false; // R6
    arm();
  }, []);'
report "R6: 立即更新 always brings the 10 s tick back, even while still measuring" \
       Refresh.test_refresh_stops_while_measuring "while still measuring brought the 10 s tick back"

# --- the probe during a measuring pause (Adam's Q6, 09-28; /measuring alone since 10-01) ---

mutant q1-no-probe "$REFRESH_TS" \
    '      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);' \
    '      // Q1: no probe'
report "Q1: the probe is never armed" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "not /measuring alone once"

mutant q2-probe-reads-everything "$REFRESH_TS" \
    'await readOnce(probeRef.current);' \
    'await readOnce(readRef.current);'
report "Q2: the probe reads everything (readRef, not probeRef)" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "not /measuring alone once"

mutant q3-probe-every-20-s "$REFRESH_TS" \
    'export const PROBE_INTERVAL_MS = 60_000;' \
    'export const PROBE_INTERVAL_MS = 20_000;'
report "Q3: the probe interval is 20 s, not 60 s" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "not /measuring alone once"

mutant q4-probe-reads-apps "$APP_TSX" \
    '    const m = await get<MeasuringAnswer>("/measuring");' \
    '    const m = await get<MeasuringAnswer>("/measuring");
    await get<AppsAnswer>("/apps");'
report "Q4: readProbe also GETs /apps" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "not /measuring alone once"

mutant q5-probe-result-ignored "$REFRESH_TS" \
    'await readOnce(probeRef.current);' \
    'await probeRef.current();'
report "Q5: the probe reads /measuring but its answer never ends the pause" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "the refresh did not resume"

# 10-01: the probe is /measuring, `ndt status --measuring` -- not plain status's /lab again
mutant q4b-probe-reads-lab "$APP_TSX" \
    '    const m = await get<MeasuringAnswer>("/measuring");' \
    '    const m = await get<MeasuringAnswer>("/lab");'
report "Q4b: the probe is /lab again (plain ndt status: sudo and the kernel graph)" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "not /measuring alone once"

mutant q12-probe-sets-last-read "$APP_TSX" \
    '    setProbeAt(clock());
    return m.status === 200' \
    '    setProbeAt(clock());
    setLabAt(clock());
    return m.status === 200'
report "Q12: the probe moves the full read's time (the tabs would read fresher than they are)" \
       Refresh.test_a_measuring_pause_probes_measuring_alone "the probe changed the full read's time"

# the r2 review's tests 4-6, against the probe: shown again, a declared pause, a probe timeout
mutant q8-shown-probes-at-once "$REFRESH_TS" \
    '      if (measuring.current) {
        arm();
        return;
      }
      void tick();' \
    '      if (measuring.current) {
        void probe();
        return;
      }
      void tick();'
report "Q8: shown again while measuring, the probe reads at once (not 60 s later)" \
       Refresh.test_shown_again_while_measuring_probes_once_60_s_later "read before its 60 s probe"

mutant q8b-shown-arms-nothing "$REFRESH_TS" \
    '      if (measuring.current) {
        arm();
        return;
      }
      void tick();' \
    '      if (measuring.current) {
        return;
      }
      void tick();'
report "Q8b: shown again while measuring, no probe is armed again" \
       Refresh.test_shown_again_while_measuring_probes_once_60_s_later "no probe within"

mutant q9-declared-sticks "$REFRESH_TS" \
    '  return lab.measuring_is_nothing === false || lab.declared !== null;' \
    '  return lab.measuring_is_nothing === false || (lab.declared as unknown) !== undefined;'
report "Q9: a declared pause never ends (null read as a declaration)" \
       Refresh.test_a_declared_pause_is_resumed_by_the_probe "did not resume by the probe"

mutant q10-probe-parses-the-row "$APP_TSX" \
    '    return m.status === 200 && m.json ? m.json : null;' \
    '    return m.status === 200 && m.json ? { ...m.json, measuring_is_nothing: m.json.measuring === "nothing" } : null;'
report "Q10: the page reads the row itself, so a timed-out probe reads as nothing measuring" \
       ProbeTimeout.test_a_probe_that_times_out_keeps_the_pause_and_the_next_one_ends_it "a probe that timed out brought the 10 s tick back"

mutant q6-shown-reads-at-once "$REFRESH_TS" \
    '      if (measuring.current) {
        arm();
        return;
      }
      void tick();' \
    '      void tick();'
report "Q6: shown again while measuring, the page reads at once" \
       Refresh.test_a_measuring_pause_reads_nothing_while_hidden "read at once when shown again while measuring"

# The two hidden checks of the probe hold each other up: arm() arms no probe while hidden, and
# probe() reads nothing while hidden. Each alone is equivalent (Q7a, Q7b below, run and seen green);
# both gone (Q7) is a probe that reads while the page is hidden.
mutant q7-probe-while-hidden "$REFRESH_TS" \
    '      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);' \
    '      timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS); // Q7'
also "$REFRESH_TS" \
    '    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(probeRef.current);' \
    '    await readOnce(probeRef.current);'
report "Q7: the probe is armed while hidden AND reads while hidden" \
       Refresh.test_a_measuring_pause_reads_nothing_while_hidden "while measuring and hidden"

mutant q7a-armed-while-hidden "$REFRESH_TS" \
    '      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);' \
    '      timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS); // Q7a'
equivalent "Q7a: the probe is armed while hidden (probe() still checks)" \
       Refresh.test_a_measuring_pause_reads_nothing_while_hidden "probe() reads nothing while hidden"

mutant q7b-reads-while-hidden "$REFRESH_TS" \
    '    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(probeRef.current);' \
    '    await readOnce(probeRef.current);'
equivalent "Q7b: probe() has no hidden check (arm() still arms none while hidden)" \
       Refresh.test_a_measuring_pause_reads_nothing_while_hidden "arm() arms no probe while hidden"

# === the job log: stops on Close, at the job's end, while hidden ===================================

mutant r3-close-does-not-stop "$JOBLOG_TS" \
    'if (watching.current !== mine) return;' \
    'if (watching.current !== mine && watching.current !== null) return;' 3
report "R3: Close does not stop the log (only opening another job does)" \
       JobLog.test_job_log_stops_on_close "after the job panel was closed"

mutant r4-end-does-not-stop "$JOBLOG_TS" \
    'if (job.state !== "running") {' \
    'if (job.state === "never-ends") {'
report "R4: the job's end does not stop the log" \
       JobLog.test_job_log_stops_when_the_job_ends "after the job ended"

mutant r5-hidden-does-not-stop "$JOBLOG_TS" \
    '        await whileHidden(); // stop 3: nothing is read while the page is hidden' \
    '        // R5: read on while hidden'
report "R5: the job log reads on while the page is hidden" \
       JobLog.test_job_log_stops_while_hidden_and_resumes "job log while the page was hidden"

echo
if [[ "$(sha256sum "${SUBJECTS[@]}")" != "$BASE_SHA" ]]; then
    echo "a file under test CHANGED while this gate ran -- the results above are about two versions"
    exit 3
fi
echo "files under test unchanged by this gate (${#SUBJECTS[@]} files; node_modules excluded, see baseline 2):"
sha256sum "${SUBJECTS[@]}" | sha256sum | sed 's/ .*//; s/^/  sha256 of their sha256sum lines: /'
echo "  total $((SECONDS - T0)) s"
echo
for l in $ONLY; do
    [[ "$ONLY_SEEN" == *" $l "* ]] || refuse "ONLY names $l, which is no mutation of this gate"
done
GATE_VERDICT=1
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s); $EQUIVALENTS documented equivalent(s), $BROKEN_CLAIMS broken${ONLY:+ (ONLY: a partial run)}"
if (( LEFTOVER_RUNS > 0 )); then
    echo "REFUSED: $LEFTOVER_RUNS run(s) left processes behind (see 'leftovers:' above)"
    exit 2
fi
(( SURVIVORS == 0 && BROKEN_CLAIMS == 0 ))
exit
}
