#!/usr/bin/env bash
#
# Mutation gate for tests/browser/test_ndt_serve_page.py -- the ndt serve page in headless Chrome
# (doc/audit/2026-09-27_ndt-serve-gui/SCOPE.md section 6, the page rows G12-G14).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way the PAGE could break the token flow Adam ruled (Q3, 09-27) -- a
# key left in the address bar, a token put in browser storage, a write the moment the page loads --
# and must turn the ONE case it names red, for the reason it names. Only a browser sees these: G13
# is spelled window["session" + "Storage"] so that no static lint of the word can see it.
# P1 and P2 go beyond the ticket's three: they are the red-first proof of the two refusal cases
# (a used key, a URL with no key), which G12-G14 do not touch.
#
# 🔴 Runs only inside tools/build_guard/guarded_build.sh (NDTWIN_GUARD_HELD set), and refuses
# otherwise: every case starts a headless Chrome, and systemd-oomd on this laptop has twice killed
# Adam's own application under memory pressure.
#
#     JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh tests/shell/mutate_ndt_serve_page.sh
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir, and the suite is
# pointed at them with NDT_SERVE_UNDER_TEST (and NDT_UNDER_TEST, as the main gate does).
# tools/ndt_serve/ is never written, and the sha256 lines at the end say so.
#
# 🔴 A mutant carries the WHOLE layout -- tools/ndt_serve/*.py, README.md and the whole static/
# dir, beside tools/test_workflow/ndt with ports.sh, sudo_surface.sh and components.env, as
# tests/shell/mutate_ndt_serve.sh's layout() does -- because serve.py reads the page from
# $HERE/static at start and `ndt serve` execs $HERE/../ndt_serve/serve.py.
#
# 🔴 A mutation that will not apply, a non-unique anchor, the named case staying green, or the
# named case going red for another reason than the one named, counts as SURVIVOR -- never as
# skipped. The reason matters here more than in a server gate: a Chrome that crashed or timed out
# also turns a case red, and would otherwise read as "caught".
#
# 🔴 The baseline is refused (exit 2) when it is red, when ANY case was skipped, and when a case
# this gate names did not run ok -- a skipped page case proves nothing, and a case name that no
# longer exists ERRORs under every mutant and would read as caught.
#
# Each mutation runs only the case it names; the baseline is the whole suite. ~2-4 s a mutation.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (no guard / baseline red,
#       skipped or incomplete / harness), 3 a file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST="$REPO/tests/browser/test_ndt_serve_page.py"
HARNESS="$REPO/tests/python/test_ndt_serve.py"
SERVE_DIR="$REPO/tools/ndt_serve"
APP_JS="$REPO/tools/ndt_serve/static/app.js"
SERVE_PY="$REPO/tools/ndt_serve/serve.py"
README_MD="$REPO/tools/ndt_serve/README.md"
NDT="$REPO/tools/test_workflow/ndt"
NDT_SIDE=("$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh"
          "$REPO/tools/test_workflow/components.env")

if [[ -z "${NDTWIN_GUARD_HELD:-}" ]]; then
    echo "refused: not inside tools/build_guard/guarded_build.sh -- every case starts a headless Chrome"
    echo "  JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh tests/shell/mutate_ndt_serve_page.sh"
    exit 2
fi

shopt -s nullglob
PYS=("$SERVE_DIR"/*.py)
STATICS=()
for f in "$SERVE_DIR"/static/*; do [[ -f "$f" ]] && STATICS+=("$f"); done
shopt -u nullglob
if (( ${#PYS[@]} == 0 || ${#STATICS[@]} == 0 )) || [[ ! -f "$APP_JS" || ! -f "$TEST" ]]; then
    echo "refused: the layout is not there (tools/ndt_serve/*.py, static/, app.js, the suite)"
    exit 2
fi
# The files under test, and the two test files: a change to any while this runs means the results
# are about two versions.
SUBJECTS=("${PYS[@]}" "$README_MD" "${STATICS[@]}" "$NDT" "${NDT_SIDE[@]}" "$TEST" "$HARNESS")
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-serve-page-gate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "${SUBJECTS[@]}")

SURVIVORS=0
MUTATIONS=0
CASES=(PageSession.test_the_key_leaves_the_address_bar_and_is_traded
       PageSession.test_the_token_is_only_in_memory
       PageSession.test_loading_the_page_writes_nothing
       PageSession.test_a_used_key_opens_nothing
       PageSession.test_a_url_without_a_key_opens_nothing)

layout() {   # $1 = dir -- a copy of the service with its page, and of ndt with what it sources
    local d="$1"
    mkdir -p "$d/tools/ndt_serve" "$d/tools/test_workflow"
    cp "${PYS[@]}" "$README_MD" "$d/tools/ndt_serve/"
    cp -r "$SERVE_DIR/static" "$d/tools/ndt_serve/static"
    cp "$NDT" "${NDT_SIDE[@]}" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/ndt"
}

run_against() {   # $1 = dir, $2... = unittest ids (none = the whole file)
    local d="$1"; shift
    NDT_SERVE_UNDER_TEST="$d/tools/ndt_serve" NDT_UNDER_TEST="$d/tools/test_workflow/ndt" \
        timeout 600 python3 "$TEST" "$@" 2>&1
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"
    layout "$d"
    if ! python3 - "$d/${file#$REPO/}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
    then
        echo "NOAPPLY"
        return
    fi
    echo "$d"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = Class.test_case that must fail, $4 = why (fixed text)
    local out rc id="$3" why="$4"
    local name="${id##*.}"
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == NOAPPLY ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (the mutation did not apply -- the anchor moved)\n' "$1"
        return
    fi
    out=$(run_against "$2" "$id"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $name \(" <<<"$out" && grep -qF -- "$why" <<<"$out"; then
        printf '  caught   %-66s (%s went red)\n' "$1" "$name"
        grep -m1 -F -- "$why" <<<"$out" | cut -c1-220 | sed 's/^[[:space:]]*/             /'
    elif [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $name \(" <<<"$out"; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s went red, but not with "%s")\n' "$1" "$name" "$why"
        grep -E '^(FAIL|ERROR):|Error:|^Ran |^OK|^FAILED' <<<"$out" | cut -c1-220 | sed 's/^/             /'
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-66s (%s stayed green -- that case proves nothing)\n' "$1" "$name"
        grep -E '^(FAIL|ERROR):|^Ran |^OK|^FAILED|skipped' <<<"$out" | cut -c1-220 | sed 's/^/             /'
    fi
}

echo "baseline (must be green, every case run and none skipped, before any mutation):"
layout "$BK/base"
out=$(run_against "$BK/base"); brc=$?
printf '  %s: %s / %s\n' "$(basename "$TEST")" "$(grep -E '^Ran ' <<<"$out" | tail -1)" "$(tail -1 <<<"$out")"
if (( brc != 0 )); then
    echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"
    grep -E '^(FAIL|ERROR):|Error:' <<<"$out" | cut -c1-220 | sed 's/^/    /'
    exit 2
fi
if grep -qE '\.\.\. skipped' <<<"$out" || [[ "$(tail -1 <<<"$out")" != "OK" ]]; then
    echo "  a baseline case was SKIPPED -- a skipped page case proves nothing:"
    grep -E '\.\.\. skipped' <<<"$out" | cut -c1-220 | sed 's/^/    /'
    exit 2
fi
for c in "${CASES[@]}"; do
    if ! grep -qE "^${c##*.} \(.*\) \.\.\. ok$" <<<"$out"; then
        echo "  the baseline did not run $c ok -- a mutation naming it would prove nothing"
        exit 2
    fi
done
echo

# --- G12: the key leaves the address bar ------------------------------------------------------

# The key is still read from the hash and traded; only the wipe goes. The session opens as before
# -- only location.href after the page ran says the key is still in the address bar.
m=$(mutant g12 "$APP_JS" \
    '    history.replaceState(null, "", location.pathname + location.search);   // the key leaves the address bar first' \
    '    // G12: the key stays in the address bar')
report "G12: history.replaceState is gone (the key stays in the address bar)" "$m" \
       PageSession.test_the_key_leaves_the_address_bar_and_is_traded \
       "the key is still in the address bar"

# --- G13: the token only in memory ------------------------------------------------------------

m=$(mutant g13 "$APP_JS" \
    '    token = r.json.token;' \
    '    token = r.json.token;
    window["session" + "Storage"].setItem("t", token);')
report "G13: the token is also put in sessionStorage (spelled past a static lint)" "$m" \
       PageSession.test_the_token_is_only_in_memory \
       "the page left something in browser storage"

# --- G14: loading the page writes nothing -----------------------------------------------------

m=$(mutant g14 "$APP_JS" \
    '    token = r.json.token;' \
    '    token = r.json.token;
    call("POST", API + "/release", {});')
report "G14: the page releases the lab the moment it has the token" "$m" \
       PageSession.test_loading_the_page_writes_nothing \
       "loading the page writes"

# --- beyond the ticket: red first for the two refusal cases -----------------------------------

# The server keeps a used key: the second load of the same URL opens a session and reads the lab.
m=$(mutant p1 "$SERVE_PY" \
    '                    del self.book[i]' \
    '                    pass')
report "P1: a used key is not forgotten (serve.py Nonces.take)" "$m" \
       PageSession.test_a_used_key_opens_nothing \
       "the second load of a used key opened a session"

# The page trades whatever the address bar holds, an empty key included: a URL with no key
# sends a trade (refused by the server) instead of stopping at "no key".
m=$(mutant p2 "$APP_JS" \
    '    const m = /^#k=([A-Za-z0-9_-]{16,64})$/.exec(location.hash);' \
    '    const m = /^(?:#k=)?([A-Za-z0-9_-]{0,64})$/.exec(location.hash);')
report "P2: the page trades a key it does not have (an empty hash)" "$m" \
       PageSession.test_a_url_without_a_key_opens_nothing \
       "a URL with no key"

echo
if [[ "$(sha256sum "${SUBJECTS[@]}")" != "$BASE_SHA" ]]; then
    echo "a file under test CHANGED while this gate ran -- the results above are about two versions"
    exit 3
fi
echo "files under test unchanged by this gate:"
sha256sum "${SUBJECTS[@]}" | sed "s|$REPO/||; s/^/  /"
echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s)"
(( SURVIVORS == 0 ))
