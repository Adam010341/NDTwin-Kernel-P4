#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_ndt_serve.py (TICKET-ndt-serve, 09-24), its cells suite,
# tests/python/test_ndt_serve_gui.py (the GUI cut, 09-27: the G series at the end) and
# tests/python/test_ndt_serve_web.py (the page rebuilt on React, v2: its manifest, bundle and
# source lints). The page cases that need a browser have their own gate,
# tests/shell/mutate_ndt_serve_page.sh (headless Chrome, a rebuild per mutant, under the build guard).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way ndt serve could break a red line of TICKET section 3 -- a
# socket on every interface, a Host header nobody reads, a CORS header, a write without the
# token, a shell, an rc 5 folded into 1, a job that dies with the server -- and must turn the ONE
# case it names red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir, and the suite is
# pointed at them with NDT_SERVE_UNDER_TEST (the service) and NDT_UNDER_TEST (ndt, for the help
# and `ndt serve` cases). tools/ndt_serve/ and tools/test_workflow/ndt are never written -- the
# main checkout's ndt may be running right now -- and the sha256 lines at the end say so.
#
# 🔴 A mutant carries the WHOLE layout: tools/ndt_serve/*.py beside tools/test_workflow/ndt with
# ports.sh, sudo_surface.sh and components.env, because `ndt serve` execs
# $HERE/../ndt_serve/serve.py and ndt sources the other three from beside itself.
#
# 🔴 A mutation that will not apply, a non-unique anchor, or the named case staying green counts
# as SURVIVOR -- never as skipped.
#
# Each mutation runs only the case it names (python3 test_ndt_serve.py Class.test_case): the
# baseline below is the whole suite, green, and the question each mutation asks is "does THIS
# case see it". ~2 s a mutation instead of ~25.
#
# PYTHON picks the interpreter the suites run under (default python3); the first lines say which
# one, and which commit and tree the run is about, and the last line is the gate's exit code.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 a file under test changed while the gate ran.
set -uo pipefail
PY="${PYTHON:-python3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST="$REPO/tests/python/test_ndt_serve.py"
TEST_CELLS="$REPO/tests/python/test_ndt_serve_cells.py"
TEST_GUI="$REPO/tests/python/test_ndt_serve_gui.py"
TEST_WEB="$REPO/tests/python/test_ndt_serve_web.py"
SERVE_PY="$REPO/tools/ndt_serve/serve.py"
VERBS_PY="$REPO/tools/ndt_serve/verbs.py"
JOBS_PY="$REPO/tools/ndt_serve/jobs.py"
RUNNER_PY="$REPO/tools/ndt_serve/runner.py"
CELLS_PY="$REPO/tools/ndt_serve/cells.py"
DEMO_PY="$REPO/tools/ndt_serve/demo_sequence.py"
# [Co-developed with claude code -- Adam] the README is prose the suite now holds to ndt (its lock
# probe citation, RcProvenance), so a mutant tree carries it and the gate watches it too
README_MD="$REPO/tools/ndt_serve/README.md"
NDT="$REPO/tools/test_workflow/ndt"
# [Co-developed with claude code -- Adam] the page (v2): its sources under web/ and what they build
# into static/. A mutant tree carries all of both but web/node_modules and web/dist; the G mutations
# on the page edit the copies' TS sources or built files and need no Node.
WEB_DIR="$REPO/tools/ndt_serve/web"
STATIC_DIR="$REPO/tools/ndt_serve/static"
CLIENT_TS="$REPO/tools/ndt_serve/web/src/api/client.ts"
SESSION_TS="$REPO/tools/ndt_serve/web/src/api/session.ts"
TESTHOOKS_TS="$REPO/tools/ndt_serve/web/src/testhooks.ts"
MAIN_TSX="$REPO/tools/ndt_serve/web/src/main.tsx"
APP_TSX="$REPO/tools/ndt_serve/web/src/NdtServeApp.tsx"
CONFIRM_TSX="$REPO/tools/ndt_serve/web/src/components/ConfirmDialog.tsx"
JOBLOG_TS="$REPO/tools/ndt_serve/web/src/hooks/useJobLog.ts"
REFRESH_TS="$REPO/tools/ndt_serve/web/src/hooks/useAutoRefresh.ts"
FORMAT_TS="$REPO/tools/ndt_serve/web/src/lib/format.ts"
APPS_TSX="$REPO/tools/ndt_serve/web/src/components/tabs/AppsTab.tsx"
CELLS_TSX="$REPO/tools/ndt_serve/web/src/components/tabs/CellsTab.tsx"
ACTIONS_TSX="$REPO/tools/ndt_serve/web/src/components/tabs/ActionsTab.tsx"
INDEX_HTML="$REPO/tools/ndt_serve/static/index.html"
APP_JS="$REPO/tools/ndt_serve/static/app.js"
APP_CSS="$REPO/tools/ndt_serve/static/app.css"
MANUAL_HTML="$REPO/tools/ndt_serve/static/manual.html"
BUILD_JSON="$REPO/tools/ndt_serve/static/BUILD.json"
SUBJECTS=("$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$CELLS_PY" "$DEMO_PY" "$README_MD" "$NDT")
# a while loop, not mapfile: check_gate_anchors.py reads any command but a few it knows (while, find)
# whose path argument is followed by a quoted one as a mutation call
PAGE_FILES=()
while IFS= read -r f; do PAGE_FILES+=("$f"); done < <(find "$REPO/tools/ndt_serve/web" "$REPO/tools/ndt_serve/static" \
    \( -path "$WEB_DIR/node_modules" -o -path "$WEB_DIR/dist" \) -prune -o -type f -print | LC_ALL=C sort)
SUBJECTS+=("${PAGE_FILES[@]}")
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-serve-mutate-XXXXXX")
trap 'rc=$?; rm -rf "$BK"; echo "rc=$rc"' EXIT
# [Co-developed with claude code -- Adam] what this run is about, printed by the gate itself
echo "head $(git -C "$REPO" rev-parse HEAD)"
echo "porcelain $(git -C "$REPO" status --porcelain --untracked-files=no | wc -l) tracked file(s) differ from HEAD"
echo "date $(date -Is)"
echo "python $(command -v "$PY") $("$PY" -c 'import sys; print(sys.version.split()[0])')"
BASE_SHA=$(sha256sum "${SUBJECTS[@]}")

SURVIVORS=0
MUTATIONS=0

layout() {   # $1 = dir -- a copy of the service and of ndt with what it sources
    local d="$1"
    mkdir -p "$d/tools/ndt_serve" "$d/tools/test_workflow"
    cp "$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$CELLS_PY" "$DEMO_PY" "$README_MD" "$d/tools/ndt_serve/"
    tar -C "$REPO/tools/ndt_serve" --exclude=web/node_modules --exclude=web/dist -cf - web static \
        | tar -C "$d/tools/ndt_serve" -xf -
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/ndt"
}

run_against() {   # $1 = dir, $2 = test file, $3... = unittest ids (none = the whole file)
    local d="$1" t="$2"; shift 2
    NDT_SERVE_UNDER_TEST="$d/tools/ndt_serve" NDT_UNDER_TEST="$d/tools/test_workflow/ndt" \
        timeout 600 "$PY" "$t" "$@" 2>&1
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
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.stderr.write("anchor not unique (%d hits): %s\n" % (s.count(a), a[:70]))
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
    then
        echo "NOAPPLY"
        return
    fi
    echo "$d"
}

mutant_add() {   # $1 = label, $2 = a file the layout does not have, $3 = what goes in it
    local label="$1" path="$2" text="$3"
    local d="$BK/$label"
    layout "$d"
    if [[ -e "$d/${path#$REPO/}" ]]; then
        echo "NOAPPLY"
        return
    fi
    printf '%s\n' "$text" > "$d/${path#$REPO/}"
    echo "$d"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = [cells:|gui:|web:]Class.test_case that must fail
    local out rc id="$3" t="$TEST"
    [[ "$id" == cells:* ]] && { t="$TEST_CELLS"; id="${id#cells:}"; }
    [[ "$id" == gui:* ]] && { t="$TEST_GUI"; id="${id#gui:}"; }
    [[ "$id" == web:* ]] && { t="$TEST_WEB"; id="${id#web:}"; }
    local name="${id##*.}"
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == NOAPPLY ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (the mutation did not apply -- the anchor moved)\n' "$1"
        return
    fi
    out=$(run_against "$2" "$t" "$id"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $name \(" <<<"$out"; then
        printf '  caught   %-62s (%s went red)\n' "$1" "$name"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (%s stayed green -- that case proves nothing)\n' "$1" "$name"
        grep -E '^(FAIL|ERROR):|^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
layout "$BK/base"
for t in "$TEST" "$TEST_CELLS" "$TEST_GUI" "$TEST_WEB"; do
    out=$(run_against "$BK/base" "$t"); brc=$?
    printf '  %s: %s, %s\n' "$(basename "$t")" "$(grep -E '^Ran [0-9]+ test' <<<"$out" | tail -1)" "$(tail -1 <<<"$out")"
    (( brc == 0 )) || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
done
echo

# --- 1. loopback only -------------------------------------------------------------------------

# The announced address stays 127.0.0.1; only the socket moves. A test that read the banner or
# /health would stay green -- the case reads /proc/net/tcp.
m=$(mutant m1 "$SERVE_PY" \
    '        httpd = Server((BIND, a.port), Handler)' \
    '        httpd = Server(("0.0.0.0", a.port), Handler)')
report "M1: the socket binds every interface" "$m" \
       LoopbackOnly.test_listens_on_127_0_0_1_only

m=$(mutant m2 "$SERVE_PY" \
    '        if len(hosts) != 1 or hosts[0].strip().lower() not in allowed:' \
    '        if False:')
report "M2: the Host header is not read (DNS rebinding)" "$m" \
       LoopbackOnly.test_foreign_host_header_is_refused

m=$(mutant m3 "$SERVE_PY" \
    '        if len(hosts) != 1 or hosts[0].strip().lower() not in allowed:' \
    '        if len(hosts) != 1 or hosts[0].strip().lower().rsplit(":", 1)[0] not in ("127.0.0.1", "localhost"):')
report "M3: the Host header's port is not compared" "$m" \
       LoopbackOnly.test_host_with_another_port_is_refused

m=$(mutant m4 "$SERVE_PY" \
    '        if len(hosts) != 1 or hosts[0].strip().lower() not in allowed:' \
    '        if hosts and (len(hosts) != 1 or hosts[0].strip().lower() not in allowed):')
report "M4: a request with no Host header is served" "$m" \
       LoopbackOnly.test_missing_host_header_is_refused

m=$(mutant m5 "$SERVE_PY" \
    '        self.send_header("X-Content-Type-Options", "nosniff")' \
    '        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Content-Type-Options", "nosniff")')
report "M5: a CORS header is sent" "$m" \
       LoopbackOnly.test_no_cors_header_anywhere

# --- 2. CSRF ----------------------------------------------------------------------------------

m=$(mutant m6 "$SERVE_PY" \
    '        if not hmac.compare_digest(sent.encode(), self.cfg.token.encode()):' \
    '        if False:')
report "M6: a write needs no token" "$m" \
       Csrf.test_write_without_token_runs_nothing

m=$(mutant m7 "$SERVE_PY" \
    '        sent = self.headers.get(TOKEN_HEADER, "")' \
    '        sent = self.headers.get(TOKEN_HEADER, "") or urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("token", [""])[-1]')
report "M7: the token is also taken from the query string" "$m" \
       Csrf.test_token_in_query_is_not_accepted

m=$(mutant m8 "$SERVE_PY" \
    '        os.fchmod(fd, 0o600)' \
    '        os.fchmod(fd, 0o644)')
report "M8: the token file is world-readable" "$m" \
       Csrf.test_token_file_is_private

m=$(mutant m9 "$SERVE_PY" \
    '    token = secrets.token_urlsafe(32)' \
    '    token = open(path).read().strip() if os.path.exists(path) else secrets.token_urlsafe(32)')
report "M9: the token survives a restart" "$m" \
       Csrf.test_token_is_new_on_every_start

m=$(mutant m10 "$SERVE_PY" \
    '        if origin is not None and origin.lower() not in (' \
    '        if False and origin.lower() not in (')
report "M10: a cross-origin write with the token is accepted" "$m" \
       Csrf.test_cross_origin_write_is_refused_with_token

m=$(mutant m11 "$SERVE_PY" \
    '        if ctype != "application/json":' \
    '        if False:')
report "M11: a form-shaped (simple-request) write is accepted" "$m" \
       Csrf.test_form_shaped_write_is_refused

m=$(mutant m12 "$SERVE_PY" \
    '    ("POST", re.compile(r"/down"), Handler.w_down),' \
    '    ("GET", re.compile(r"/down"), Handler.w_down),
    ("POST", re.compile(r"/down"), Handler.w_down),')
report "M12: a GET route reaches a writer" "$m" \
       Csrf.test_get_runs_only_read_verbs

# --- 3. whitelist -----------------------------------------------------------------------------

m=$(mutant m13 "$VERBS_PY" \
    '        if os.path.commonpath([root_real, real]) == root_real and real != root_real:' \
    '        if True:')
report "M13: --app is not confined to the root" "$m" \
       Whitelist.test_app_dir_outside_the_root_is_refused

m=$(mutant m14 "$VERBS_PY" \
    '    real = os.path.realpath(raw)' \
    '    real = os.path.abspath(raw)')
report "M14: abspath instead of realpath (a symlink escapes the root)" "$m" \
       Whitelist.test_app_dir_symlink_out_of_the_root_is_refused

m=$(mutant m15 "$VERBS_PY" \
    '    if not isinstance(name, str) or not APP_NAME_RE.match(name) or name not in known_apps:' \
    '    if not isinstance(name, str) or not APP_NAME_RE.match(name):')
report "M15: an app name ndt does not know is passed on" "$m" \
       Whitelist.test_app_name_must_be_one_of_ndts

m=$(mutant m16 "$SERVE_PY" \
    '    cfg.apps = app_names_of(ndt_real)' \
    '    cfg.apps = ["energy", "sim", "nsr", "viz", "te"]')
report "M16: the app list is this file's, not ndt's" "$m" \
       Whitelist.test_app_names_come_from_ndt_itself

m=$(mutant m17 "$RUNNER_PY" \
    '            p = subprocess.Popen(req["argv"], stdin=subprocess.DEVNULL, stdout=out, stderr=err,' \
    '            p = subprocess.Popen(" ".join(req["argv"]), shell=True, stdin=subprocess.DEVNULL, stdout=out, stderr=err,')
report "M17: the argv goes through a shell" "$m" \
       Whitelist.test_claim_note_reaches_ndt_as_one_argv_element

m=$(mutant m18 "$VERBS_PY" \
    '    if not _NOTE_OK.match(note):' \
    '    if False:')
report "M18: a newline in a claim note is passed on" "$m" \
       Whitelist.test_claim_note_with_a_newline_is_refused

m=$(mutant m19 "$VERBS_PY" \
    '    extra = sorted(set(body) - set(allowed))' \
    '    extra = []')
report "M19: unknown fields (deep, force) are ignored instead of refused" "$m" \
       Whitelist.test_up_refuses_unknown_fields

m=$(mutant m20 "$VERBS_PY" \
    '    "p4": (None, 4, 128),' \
    '    "p4": (None, 4, 5, 128, 256),')
report "M20: the P4 host enum is widened" "$m" \
       Whitelist.test_up_refuses_values_outside_the_enums

m=$(mutant m21 "$VERBS_PY" \
    '    if not _is_int(minutes) or not 1 <= minutes <= MAX_CLAIM_MINUTES:' \
    '    if not 1 <= minutes <= MAX_CLAIM_MINUTES:')
report "M21: claim minutes are not type-checked" "$m" \
       Whitelist.test_claim_minutes_are_bounded

# --- 4. thin shell ----------------------------------------------------------------------------

m=$(mutant m22 "$VERBS_PY" \
    '        5: ("refused", "a GUARD REFUSED and nothing was built (claimed by somebody else, a "' \
    '        5: ("dirty", "a GUARD REFUSED and nothing was built (claimed by somebody else, a "')
report "M22: rc 5 is folded into 'dirty'" "$m" \
       ThinShell.test_rc5_is_refused_and_not_dirty

m=$(mutant m23 "$VERBS_PY" \
    '    row = RC_TABLE.get(kind, {}).get(rc)' \
    '    row = RC_TABLE["up"].get(rc)')
report "M23: one rc table for every verb" "$m" \
       ThinShell.test_each_verb_reads_its_own_rc_table

m=$(mutant m24 "$VERBS_PY" \
    '        return ("unknown", "rc %d is not in' \
    '        return ("dirty", "rc %d is not in')
report "M24: an rc the table does not know is called dirty" "$m" \
       ThinShell.test_unknown_rc_is_not_folded

m=$(mutant m25 "$SERVE_PY" \
    '        self._send(200, raw=data, ctype="text/plain; charset=utf-8", headers={' \
    '        self._send(200, raw=data.decode("utf-8", "replace").encode(), ctype="text/plain; charset=utf-8", headers={')
report "M25: the log is decoded and re-encoded" "$m" \
       ThinShell.test_output_is_kept_byte_for_byte

m=$(mutant m41 "$SERVE_PY" \
    '        self._read_verb("status.check" if check else "status", verbs.argv_status(check))' \
    '        self._read_verb("status.check", verbs.argv_status(check))')
report "M41: plain status is read with --check's table (live, 09-24 22:01)" "$m" \
       ThinShell.test_plain_status_is_not_a_verdict

# --- 5. long jobs -----------------------------------------------------------------------------

m=$(mutant m26 "$SERVE_PY" \
    '        self._send(202, {"job": cfg.store.view(job_id), "links": _links(job_id)})' \
    '        self._send(202, {"job": cfg.store.wait(job_id, 60), "links": _links(job_id)})')
report "M26: a write waits for its job" "$m" \
       Jobs.test_write_returns_before_the_job_ends

m=$(mutant m27 "$SERVE_PY" \
    '            busy = cfg.store.holding_the_slot()
            if busy is not None:' \
    '            busy = None
            if busy is not None:')
report "M27: no mutation slot" "$m" \
       Jobs.test_second_write_is_refused_while_one_runs

m=$(mutant m28 "$JOBS_PY" \
    '                                 close_fds=True, start_new_session=True)' \
    '                                 close_fds=True, start_new_session=False)')
report "M28: the runner shares the server's process group" "$m" \
       Jobs.test_job_outlives_the_server

m=$(mutant m29 "$JOBS_PY" \
    '        elif alive(runner_pid, runner_st):' \
    '        elif job_id in self._children:')
report "M29: liveness is this process's memory, not /proc" "$m" \
       Jobs.test_restarted_server_still_honours_a_running_job

m=$(mutant m30 "$RUNNER_PY" \
    '                                 cwd=req["cwd"], close_fds=True, start_new_session=True)' \
    '                                 cwd=req["cwd"], close_fds=True, start_new_session=False)')
report "M30: ndt shares the runner's session" "$m" \
       Jobs.test_ndt_runs_in_a_session_of_its_own

m=$(mutant m31 "$JOBS_PY" \
    'HOLDS_THE_SLOT = ("running", "orphaned")' \
    'HOLDS_THE_SLOT = ("running",)')
report "M31: an orphaned ndt frees the slot" "$m" \
       Jobs.test_an_orphaned_ndt_still_holds_the_slot

m=$(mutant m32 "$JOBS_PY" \
    '            state, rc = "lost", None' \
    '            state, rc, ex = "finished", 0, {}')
report "M32: a job with no recorded rc is called finished" "$m" \
       Jobs.test_a_job_nobody_recorded_is_lost_not_finished

m=$(mutant m42 "$JOBS_PY" \
    '        out.sort(key=lambda v: (v.get("created_at") or 0, v["id"]), reverse=True)' \
    '        pass')
report "M42: jobs listed by id, not by when they were created (live, 09-24 22:01)" "$m" \
       Jobs.test_jobs_are_listed_newest_first_within_one_second

# --- 6. no pattern kills ----------------------------------------------------------------------

m=$(mutant m33 "$SERVE_PY" \
    '                os.killpg(p.pid, signal.SIGKILL)' \
    '                subprocess.run(["pkill", "-f", "ndt status"])')
report "M33: the read timeout kills by name" "$m" \
       NoPatternKill.test_no_process_is_found_or_signalled_by_name

# --- 7. identity ------------------------------------------------------------------------------

m=$(mutant m34 "$SERVE_PY" \
    '    env["NDT_OWNER"] = owner' \
    '    pass')
report "M34: NDT_OWNER is not set" "$m" \
       Identity.test_every_ndt_call_carries_the_owner

m=$(mutant m35 "$SERVE_PY" \
    '    env = {k: v for k, v in os.environ.items() if not k.startswith("NDT_")}' \
    '    env = dict(os.environ)')
report "M35: inherited NDT_* variables are passed on" "$m" \
       Identity.test_inherited_ndt_variables_are_not_passed

m=$(mutant m36 "$SERVE_PY" \
    '    if not a.owner or not OWNER_RE.match(a.owner):' \
    '    if False:')
report "M36: the server starts with no owner" "$m" \
       Identity.test_server_refuses_to_start_without_an_owner

# --- 8. entry and routes ----------------------------------------------------------------------

m=$(mutant m37 "$NDT" \
    '  serve [--owner N] [--port P]   a local HTTP API over up/down/status/claim/release' \
    '  srv   [--owner N] [--port P]   a local HTTP API over up/down/status/claim/release')
report "M37: 'ndt help' does not list serve" "$m" \
       Entry.test_ndt_help_lists_serve

m=$(mutant m38 "$NDT" \
    '    serve)   shift; exec python3 "$HERE/../ndt_serve/serve.py" --ndt "$HERE/ndt" "$@" ;;' \
    '    serve)   shift; echo "usage: ndt serve (not wired)"; exit 2 ;;')
report "M38: 'ndt serve' is not wired to the server" "$m" \
       Entry.test_ndt_serve_execs_this_server

m=$(mutant m39 "$SERVE_PY" \
    '            if path != API and not path.startswith(API + "/"):' \
    '            if False:')
report "M39: paths outside /api/ are not reserved" "$m" \
       Entry.test_outside_the_api_there_is_only_the_page

m=$(mutant m40 "$SERVE_PY" \
    '    locks = [hold_lock(os.path.join(cfg.state_dir, "serve.lock")), hold_lock(cfg.token_file + ".lock")]' \
    '    locks = []')
report "M40: two servers can share one state directory and token" "$m" \
       Entry.test_second_server_on_the_same_state_refuses


# --- the judge's fixes (opus-judge on e4589399, 09-24; orchestrator's ruling) ------------------

m=$(mutant m43 "$SERVE_PY" \
    '            if method == "GET" and route is not Handler.r_health:
                self._check_read()' \
    '            if method == "GET" and route is not Handler.r_health:
                pass')
report "M43: a GET needs no token (an <img> runs ndt status --check)" "$m" \
       Csrf.test_status_check_without_token_runs_nothing

m=$(mutant m44 "$SERVE_PY" \
    '        """Every GET but /health: the token and the Origin, exactly as a write."""
        self._check_token()
        self._check_origin()' \
    '        """Every GET but /health: the token and the Origin, exactly as a write."""
        self._check_token()')
report "M44: a cross-origin read with the token is served" "$m" \
       Csrf.test_cross_origin_read_is_refused

m=$(mutant m45 "$SERVE_PY" \
    'MAX_WAIT_S = 300           # ?wait= on a job, per request' \
    'MAX_WAIT_S = 100000       # ?wait= on a job, per request')
report "M45: ?wait= has no cap" "$m" \
       Csrf.test_wait_is_capped

m=$(mutant m46 "$SERVE_PY" \
    '    httpd.waiters = threading.BoundedSemaphore(a.max_waiters)' \
    '    httpd.waiters = threading.BoundedSemaphore(100000)')
report "M46: long-polls are not bounded" "$m" \
       Bounded.test_waiters_are_bounded

m=$(mutant m47 "$SERVE_PY" \
    '    httpd.conn_slots = threading.BoundedSemaphore(a.max_connections)' \
    '    httpd.conn_slots = threading.BoundedSemaphore(100000)')
report "M47: connections are not bounded" "$m" \
       Bounded.test_connections_are_bounded

m=$(mutant m48 "$JOBS_PY" \
    '        with open(os.path.join(d, "stdout"), "wb") as f:
            f.write(out)' \
    '        with open(os.path.join(d, "stdout"), "wb") as f:
            f.write(out.decode("utf-8", "replace").encode())')
report "M48: a read's output is kept decoded, not as bytes" "$m" \
       ThinShell.test_read_output_is_kept_byte_for_byte

m=$(mutant m49 "$SERVE_PY" \
    '        job_id = self._spawn(kind, [self.cfg.ndt_real] + argv_tail, body, precheck=precheck)' \
    '        job_id = self._spawn(kind, [self.cfg.ndt] + argv_tail, body, precheck=precheck)')
report "M49: a job runs the symlink, not what it resolved to at start" "$m" \
       Identity.test_jobs_run_the_ndt_resolved_at_start

m=$(mutant m50 "$SERVE_PY" \
    '                out, err = p.communicate(timeout=PIPE_GRACE_S)' \
    '                out, err = p.communicate()')
report "M50: after the timeout the read waits on the pipe without bound" "$m" \
       ReadTimeout.test_a_pipe_held_outside_the_group_does_not_hang_the_read

m=$(mutant m51 "$SERVE_PY" \
    '                os.killpg(p.pid, signal.SIGKILL)' \
    '                pass')
report "M51: a timed-out read is not stopped" "$m" \
       ReadTimeout.test_a_read_past_its_timeout_is_stopped_and_frees_its_slot

m=$(mutant m52 "$SERVE_PY" \
    '    if not READ_SLOTS.acquire(timeout=cfg.read_queue_wait):' \
    '    if not READ_SLOTS.acquire(timeout=60):')
report "M52: a third read waits past --read-queue-wait" "$m" \
       ReadTimeout.test_reads_beyond_the_slots_wait_then_503

m=$(mutant m53 "$SERVE_PY" \
    '        with SLOT:
            busy = cfg.store.holding_the_slot()' \
    '        if True:
            busy = cfg.store.holding_the_slot()')
report "M53: 'is the slot free' and 'take it' are not one step" "$m" \
       Jobs.test_concurrent_writes_get_exactly_one_slot

m=$(mutant m54 "$SERVE_PY" \
    '    os.chmod(d, 0o700)' \
    '    pass')
report "M54: an existing 0777 state/token directory is left open" "$m" \
       Csrf.test_open_directories_left_by_someone_else_are_tightened

m=$(mutant m55 "$VERBS_PY" \
    '        if os.path.commonpath([root_real, real]) == root_real and real != root_real:' \
    '        if real.startswith(root_real) and real != root_real:')
report "M55: the app root is a string prefix (packages2/ passes)" "$m" \
       Whitelist.test_app_root_is_a_directory_not_a_prefix

m=$(mutant m56 "$JOBS_PY" \
    '    return st == starttime and state not in ("Z", "X")' \
    '    return st == starttime')
report "M56: a zombie counts as alive" "$m" \
       Jobs.test_a_zombie_is_not_alive

m=$(mutant m57 "$VERBS_PY" \
    '        1: ("refused", "the lab is claimed by somebody else, or another writer beat this claim"),' \
    '        4: ("refused", "the lab is claimed by somebody else, or another writer beat this claim"),')
report "M57: a code-sourced rc table drifts from the lines it cites" "$m" \
       RcProvenance.test_code_sourced_tables_are_in_ndt

m=$(mutant m58 "$VERBS_PY" \
    '                    5: "5 a GUARD REFUSED and nothing was built"}},' \
    '                    5: "5 a guard declined and did nothing"}},')
report "M58: a help-sourced rc phrase ndt help does not print" "$m" \
       RcProvenance.test_help_sourced_tables_are_in_ndt_help

m=$(mutant m59 "$VERBS_PY" \
    '        1: ("dirty", "ndt reported at least one problem -- a compared field that does not match, a claim "' \
    '        1: ("dirty", "a compared field does not match -- a compared field that does not match, a claim "')
report "M59: status --check rc 1 names one cause of many" "$m" \
       RcProvenance.test_status_check_rc1_names_any_problem

m=$(mutant m60 "$DEMO_PY" \
    '        d.call("probe-slot-while-up", "GET", "/api/v1/health", token=False)' \
    '        d.call("probe-busy-while-up", "POST", "/api/v1/down", {})')
report "M60: the demo's slot probe is a real POST /down with the token" "$m" \
       DemoProbes.test_demo_probes_cannot_touch_the_lab

m=$(mutant m61 "$VERBS_PY" \
    '    "apps.status": {"code": [(10346, 0, "return 0", "cmd_apps")]},' \
    '')
report "M61: an rc table with no source" "$m" \
       RcProvenance.test_every_table_names_its_source


# --- the live_cells entry and the guided walk (second ticket, Adam 09-24 21:4x) -------------

m=$(mutant c1 "$CELLS_PY" \
    '        for c in self.list():
            if c["name"] == name:
                return c
        raise KeyError(name)' \
    '        return {"name": name, "tag": "?", "requires": "ovs4"}')
report "C1: a cell name the grid does not list is accepted" "$m" \
       cells:CellsCatalog.test_unknown_cell_is_refused_and_runs_nothing

m=$(mutant c2 "$CELLS_PY" \
    '        argv = [os.path.join(self.dir, name + ".sh"), "judge", d]' \
    '        argv = [os.path.join(self.dir, name + ".sh"), "observe", d]')
report "C2: showing old/ drives the lab (observe, not judge)" "$m" \
       cells:CellsCatalog.test_old_is_judged_read_only_and_shows_the_red

m=$(mutant c3 "$CELLS_PY" \
    '    p = os.path.realpath(os.path.join(root_real, rel))' \
    '    p = os.path.normpath(os.path.join(root_real, rel))')
report "C3: a raw file is read through a symlink out of its fixture" "$m" \
       cells:CellsCatalog.test_fixture_raw_cannot_leave_the_fixture

m=$(mutant c4 "$SERVE_PY" \
    '        return self._spawn("cells.run", cfg.grid.run_argv(cell["name"], raw_root), body,' \
    '        return cfg.store.start("cells.run", cfg.grid.run_argv(cell["name"], raw_root), cfg.repo, cfg.grid.env, {"cell": cell["name"], "raw_root": raw_root}) if True else self._spawn("cells.run", cfg.grid.run_argv(cell["name"], raw_root), body,')
report "C4: a cell run bypasses the one slot" "$m" \
       cells:CellsRun.test_cell_run_holds_the_slot

m=$(mutant c5 "$SERVE_PY" \
    '{"PASS": "pass", "SKIP": "skip"}' \
    '{"PASS": "pass", "SKIP": "pass"}')
report "C5: a SKIPPED cell is shown as a pass" "$m" \
       cells:CellsRun.test_cell_run_skip_is_not_a_pass

m=$(mutant c6 "$SERVE_PY" \
    '        body = self._check_write()
        confirmed = _whitelisted(verbs.cell_run_body, body)
        job_id = self._spawn_cell_run(' \
    '        body = {}
        confirmed = _whitelisted(verbs.cell_run_body, body)
        job_id = self._spawn_cell_run(')
report "C6: a cell run needs no token" "$m" \
       cells:CellsRun.test_cell_run_needs_the_token

m=$(mutant c7 "$CELLS_PY" \
    '        self.env["NDT_ROOT"] = repo' \
    '        pass')
report "C7: the grid is not told which checkout to drive (NDT_ROOT)" "$m" \
       cells:CellsRun.test_cell_run_is_a_job_with_the_grids_own_argv

m=$(mutant c8 "$VERBS_PY" \
    '        2: ("harness", "the harness could not run the cell, or the RESTORE after it failed -- "' \
    '        2: ("fail", "the harness could not run the cell, or the RESTORE after it failed -- "')
report "C8: a failed restore is reported as a red cell" "$m" \
       cells:CellsRun.test_cell_run_restore_failure_is_harness

m=$(mutant c9 "$CELLS_PY" \
    '"red_to_green": bool(o is not None and not o["ok"] and a["ok"]),' \
    '"red_to_green": bool(a["ok"]),')
report "C9: every green row is called red-to-green" "$m" \
       cells:CellsRun.test_cell_run_marks_red_to_green

m=$(mutant c10 "$SERVE_PY" \
    '    return v.get("rc") == 0


def _block_reason(st):' \
    '    return True


def _block_reason(st):')
report "C10: the walk goes on after a refused claim" "$m" \
       cells:GuidedWalk.test_refused_claim_blocks_the_run

m=$(mutant c11 "$SERVE_PY" \
    '        return v.get("rc") in (0, 1) and bool(v.get("cell_verdict"))' \
    '        return True')
report "C11: the walk releases after a failed restore" "$m" \
       cells:GuidedWalk.test_failed_restore_blocks_and_never_releases

m=$(mutant c12 "$SERVE_PY" \
    '        return v.get("rc") in (0, 1) and bool(v.get("cell_verdict"))' \
    '        return v.get("rc") in (0, 1)')
report "C12: a run that printed no verdict counts as done" "$m" \
       cells:GuidedWalk.test_a_run_with_no_verdict_line_blocks

m=$(mutant c13 "$SERVE_PY" \
    '                raise HttpError(409, "yours", note="this step is Adam'"'"'s: POST %s/guided/%s/verdict" % (API, gid), walk=walk)' \
    '                walk["verdict"] = {"verdict": "green", "note": "auto"}; g.save(walk); return self._send(200, {"walk": self._walk_view(walk)})')
report "C13: the service calls the verdict itself" "$m" \
       cells:GuidedWalk.test_the_verdict_is_adams

m=$(mutant c14 "$SERVE_PY" \
    '            self._send(200, {"walk": self._walk_view(self.cfg.guided.load(gid))})' \
    '            w = self._walk_view(self.cfg.guided.load(gid)); w["seen_at"] = time.time(); self.cfg.guided.save(w); self._send(200, {"walk": w})')
report "C14: a GET writes the walk" "$m" \
       cells:GuidedWalk.test_get_does_not_move_a_walk

m=$(mutant c15 "$SERVE_PY" \
    '            ok = state == ("FAIL" if st["step"] == "old" else "PASS")' \
    '            ok = state in ("FAIL", "PASS")')
report "C15: an old/ that no longer fails is shown as the red" "$m" \
       cells:GuidedWalk.test_old_that_no_longer_fails_blocks_the_walk
m=$(mutant c16 "$CELLS_PY" \
    '        + ["run"] + (["release"] if lab else []) + ["compare", "verdict"]' \
    '        + ["run", "compare", "verdict"] + (["release"] if lab else [])')
report "C16: the walk holds the shared lab while it waits on Adam's verdict" "$m" \
       cells:GuidedWalk.test_the_lab_is_released_before_the_verdict

# --- the judge's second round (opus-judge on e4589399..e28bcfe4, 09-24; orchestrator's rulings) --

m=$(mutant c17 "$SERVE_PY" \
    '            if precheck is not None:
                precheck()' \
    '            pass')
report "C17: a lab cell runs without reading the claim" "$m" \
       cells:CellsRun.test_lab_cell_run_needs_your_claim

m=$(mutant c18 "$SERVE_PY" \
    '        if not OWN_CLAIM.fullmatch(line or ""):' \
    '        if line is None:')
report "C18: any claim line -- none, a foreign one, an expired one -- lets a lab cell run" "$m" \
       cells:CellsRun.test_lab_cell_run_needs_your_claim

m=$(mutant c19 "$SERVE_PY" \
    '                st["result"] = {"ok": False, "why": "claim: the run was not started -- %s (claim line: %s)" % (' \
    '                st["result"] = {"ok": True, "why": "claim: the run was not started -- %s (claim line: %s)" % (')
report "C19: the walk goes past a run the claim re-check refused" "$m" \
       cells:GuidedWalk.test_walk_run_rechecks_the_claim

m=$(mutant c20 "$SERVE_PY" \
    '        if cell.get("writes_shared_state") and confirmed is not True:' \
    '        if False:')
report "C20: a cell that writes host_count_override runs unconfirmed" "$m" \
       cells:CellsRun.test_a_cell_that_writes_shared_state_needs_confirmation

m=$(mutant c21 "$SERVE_PY" \
    '        self._need_confirmation(cell, confirmed)
        self._send(201, {"walk": self._walk_view(self.cfg.guided.create(cell, confirmed))})' \
    '        self._send(201, {"walk": self._walk_view(self.cfg.guided.create(cell, confirmed))})')
report "C21: a walk over a shared-state cell starts unconfirmed" "$m" \
       cells:GuidedWalk.test_walk_for_a_shared_state_cell_needs_confirmation

m=$(mutant c22 "$CELLS_PY" \
    '    "up_refuses_a_model_of_another_network": (' \
    '    "not_a_cell_of_this_grid": (')
report "C22: the shared-state registry drifts from the real grid" "$m" \
       cells:SharedStateRegistry.test_the_registry_matches_the_real_grid

m=$(mutant c23 "$CELLS_PY" \
    '                os.killpg(p.pid, signal.SIGKILL)' \
    '                pass')
report "C23: a timed-out judge is not stopped" "$m" \
       cells:CellsRun.test_a_judge_past_its_timeout_is_stopped

m=$(mutant c24 "$CELLS_PY" \
    '        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,' \
    '        subprocess.run(["true"], timeout=self.timeout)
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,')
report "C24: an implicit child-only kill (subprocess.run timeout=) comes back" "$m" \
       NoPatternKill.test_the_only_signal_sent_is_to_a_group_this_service_created


# --- the intake judge (opus-judge on the merge 48209682, 09-26; the orchestrator's selection) -----
# [Co-developed with claude code -- Adam]

m=$(mutant c25 "$SERVE_PY" \
    '        if not OWN_CLAIM.fullmatch(line or ""):' \
    '        if not (line or "").startswith("yours"):')
report "C25: the claim check is a prefix again (a foreign owner yours-x is yours)" "$m" \
       cells:CellsRun.test_only_ndts_own_claim_form_is_yours

m=$(mutant c26 "$SERVE_PY" \
    '        if not OWN_CLAIM.fullmatch(line or ""):' \
    '        if not (line or "").startswith("yours -- "):')
report "C26: the claim check is the own form's prefix (an owner named to contain it passes)" "$m" \
       cells:CellsRun.test_only_ndts_own_claim_form_is_yours

m=$(mutant c27 "$SERVE_PY" \
    '        if r is None:
            raise HttpError(409, "claim", note="the claim was not read: no read slot' \
    '        if False:
            raise HttpError(409, "claim", note="the claim was not read: no read slot')
report "C27: no read slot for the claim read is not caught (a 500, not a 409 claim)" "$m" \
       cells:CellsRun.test_no_read_slot_is_not_a_claim_and_says_so

m=$(mutant c28 "$SERVE_PY" \
    '        if r["rc_class"] == "timeout":
            raise HttpError(409, "claim",' \
    '        if False:
            raise HttpError(409, "claim",')
report "C28: a claim read stopped at its timeout is trusted (its partial yours runs the cell)" "$m" \
       cells:CellsRun.test_a_status_past_its_timeout_is_not_a_claim

m=$(mutant m63 "$VERBS_PY" \
    '(8899, 1, "return 1", "app_start")' \
    '(8439, 1, "return 1", "app_start")')
report "M63: apps.start rc 1 cites proc_checkout's return 1 (09-24's line 8315, 8439 since segment W)" "$m" \
       RcProvenance.test_code_sourced_tables_are_in_ndt


# [Co-developed with claude code -- Adam] The opus judge's N1-1 (09-27): the README's lock probe
# citation was left at its pre-segment-W lines; the suite now holds every such citation to ndt.
m=$(mutant m64 "$README_MD" \
    'lock probes to the kernel (ndt:9416-9431)' \
    'lock probes to the kernel (ndt:9292-9307)')
report "M64: the README cites the lock probes where they were before segment W (ndt:9292-9307)" "$m" \
       RcProvenance.test_lock_probe_citations_are_lock_probe
m=$(mutant m65 "$SERVE_PY" \
    'probes to the kernel (ndt:9416-9431)' \
    'probes to the kernel (ndt:9416-9420)')
report "M65: serve.py's docstring cites lock_probe's comment but not its POST" "$m" \
       RcProvenance.test_lock_probe_citations_are_lock_probe

m=$(mutant m62 "$SERVE_PY" \
    '    request_queue_size = 64' \
    '    request_queue_size = 5')
report "M62: the listen backlog is socketserver's 5 (a burst of 20 gets a reset)" "$m" \
       Bounded.test_listen_backlog_holds_a_burst

# --- the GUI cut (09-27, SCOPE bfffefa0 as the orchestrator approved it): the G series ------------
# [Co-developed with claude code -- Adam]

# the page's files: no token, nothing run, the Host check, the CSP
m=$(mutant g1 "$SERVE_PY" \
    '                # the page: after the Host check, before any token -- it runs nothing' \
    '                # the page: after the Host check, before any token -- it runs nothing
                run_read(self.cfg, "status", verbs.argv_status(False), 5)')
report "G1: serving the page runs ndt status" "$m" \
       gui:Page.test_page_files_need_no_token_and_run_nothing

m=$(mutant g2 "$SERVE_PY" \
    '    ("Content-Security-Policy", "default-src' \
    '    ("X-Not-A-CSP", "default-src')
report "G2: no Content-Security-Policy" "$m" \
       gui:Page.test_every_answer_carries_a_csp_with_no_inline_script_and_no_other_origin

m=$(mutant g2b "$SERVE_PY" \
    "script-src 'self'; style-src" \
    "script-src 'self' 'unsafe-inline'; style-src")
report "G2b: the CSP allows inline script" "$m" \
       gui:Page.test_every_answer_carries_a_csp_with_no_inline_script_and_no_other_origin

m=$(mutant g3 "$SERVE_PY" \
    "form-action 'none'; frame-ancestors 'none'\")," \
    "form-action 'none'\"),")
report "G3: the CSP has no frame-ancestors" "$m" \
       gui:Page.test_the_page_cannot_be_framed

m=$(mutant g3b "$SERVE_PY" \
    '    ("X-Frame-Options", "DENY"),' \
    '')
report "G3b: no X-Frame-Options" "$m" \
       gui:Page.test_the_page_cannot_be_framed

m=$(mutant g4 "$SERVE_PY" \
    '            self._check_host()
            url = urllib.parse.urlsplit(self.path)
            path, query = url.path, urllib.parse.parse_qs(url.query)
            if path in STATIC:' \
    '            url = urllib.parse.urlsplit(self.path)
            path, query = url.path, urllib.parse.parse_qs(url.query)
            if path not in STATIC:
                self._check_host()
            if path in STATIC:')
report "G4: the page is served before the Host check (DNS rebinding)" "$m" \
       gui:Page.test_the_page_obeys_the_host_check

m=$(mutant g30 "$SERVE_PY" \
    '                if method != "GET":
                    raise HttpError(405, "method not allowed", allowed=["GET"])' \
    '                if False:
                    raise HttpError(405, "method not allowed", allowed=["GET"])')
report "G30: the page answers any method" "$m" \
       gui:Page.test_the_page_is_get_only

# the start-up URL
m=$(mutant g5 "$SERVE_PY" \
    '    url = page_url(port, cfg.nonces.mint())' \
    '    url = page_url(port, cfg.token)')
report "G5: the start-up URL carries the token itself" "$m" \
       gui:StartupUrl.test_the_url_goes_to_a_0600_file_when_stdout_is_not_a_terminal

m=$(mutant g19 "$SERVE_PY" \
    '        os.fchmod(fd, 0o600)' \
    '        os.fchmod(fd, 0o644)')
report "G19: the URL file and serve.json are world-readable" "$m" \
       gui:StartupUrl.test_the_url_goes_to_a_0600_file_when_stdout_is_not_a_terminal

m=$(mutant g31 "$SERVE_PY" \
    '    if sys.stdout.isatty():' \
    '    if False:')
report "G31: a terminal does not get the URL (it goes to the file)" "$m" \
       gui:StartupUrl.test_the_url_is_printed_to_a_terminal_and_written_nowhere

# trading the key
m=$(mutant g6 "$SERVE_PY" \
    '                    del self.book[i]
                    return t > now' \
    '                    return t > now')
report "G6: a key is not spent when traded" "$m" \
       gui:Session.test_a_key_is_good_once

m=$(mutant g7 "$SERVE_PY" \
    '                    return t > now' \
    '                    return True')
report "G7: a key never expires" "$m" \
       gui:Session.test_a_key_expires

m=$(mutant g8 "$SERVE_PY" \
    '        if origin != "http://" + self.headers["Host"].strip().lower():' \
    '        if False:')
report "G8: the key is traded without an Origin, or from any" "$m" \
       gui:Session.test_the_key_is_traded_only_from_this_very_origin

m=$(mutant g8b "$SERVE_PY" \
    '        if origin != "http://" + self.headers["Host"].strip().lower():' \
    '        if origin not in ("http://127.0.0.1:%d" % self.server.server_address[1], "http://localhost:%d" % self.server.server_address[1]):')
report "G8b: the key is traded from either loopback name, not this very origin" "$m" \
       gui:Session.test_the_key_is_traded_only_from_this_very_origin

m=$(mutant g8c "$SERVE_PY" \
    '        if query:
            raise HttpError(400, "refused", note="the key goes in the JSON body, never in the URL")' \
    '        if False:
            raise HttpError(400, "refused", note="the key goes in the JSON body, never in the URL")')
report "G8c: a key in the query string is taken" "$m" \
       gui:Session.test_the_key_is_traded_only_from_this_very_origin

m=$(mutant g20 "$SERVE_PY" \
    '        _whitelisted(verbs.no_fields, self._check_write())' \
    '        _whitelisted(verbs.no_fields, self._json_body())')
report "G20: a new key needs no token" "$m" \
       gui:Session.test_a_new_key_needs_the_token

m=$(mutant g32 "$SERVE_PY" \
    '            self.book = [(k, t) for k, t in self.book if t > now][-(MAX_NONCES - 1):]' \
    '            self.book = [(k, t) for k, t in self.book if t > now]')
report "G32: keys are never forgotten (no cap on the outstanding ones)" "$m" \
       gui:Session.test_only_the_newest_keys_are_kept

# serve.py url / ndt serve url
m=$(mutant g18 "$SERVE_PY" \
    '    if not listener_owned_by(pid, port):' \
    '    if False:')
report "G18: url sends the token to whoever holds the port serve.json names" "$m" \
       gui:UrlCommand.test_url_sends_the_token_only_to_the_pid_that_holds_the_port

m=$(mutant g35 "$SERVE_PY" \
    '    if a.command == "url":' \
    '    if False:')
report "G35: serve.py url is not a command" "$m" \
       gui:UrlCommand.test_url_prints_a_new_key_of_the_running_server

m=$(mutant g34 "$NDT" \
    "  serve url     a new one-time URL of the running server's page -- each opens it once" \
    '')
report "G34: ndt help does not list serve url" "$m" \
       gui:UrlCommand.test_ndt_help_lists_serve_url

# GET /lab and GET /meta
m=$(mutant g9 "$SERVE_PY" \
    'A read stopped at its timeout is not a reading: both are false."""
        r = run_read(self.cfg, "status", verbs.argv_status(False), self.cfg.read_timeout)' \
    'A read stopped at its timeout is not a reading: both are false."""
        r = run_read(self.cfg, "status", verbs.argv_status(True), self.cfg.read_timeout)')
report "G9: /lab runs status --check (it POSTs lock probes)" "$m" \
       gui:Lab.test_lab_is_plain_status_with_its_rows_verbatim

m=$(mutant g11 "$SERVE_PY" \
    '                 claim_is_yours=read and bool(OWN_CLAIM.fullmatch(claim or "")),' \
    '                 claim_is_yours=read and (claim or "").startswith("yours"),')
report "G11: /lab calls a claim yours by its prefix (owner yours-x)" "$m" \
       gui:Lab.test_lab_claim_is_yours_only_in_ndts_own_form_whole

m=$(mutant g11b "$SERVE_PY" \
    '                 claim_is_yours=read and bool(OWN_CLAIM.fullmatch(claim or "")),' \
    '                 claim_is_yours=read and bool(OWN_CLAIM.match(claim or "")),')
report "G11b: /lab matches the own form at the start only, not whole" "$m" \
       gui:Lab.test_lab_claim_is_yours_only_in_ndts_own_form_whole

m=$(mutant g24 "$SERVE_PY" \
    '                 measuring_is_nothing=read and measuring == "nothing",' \
    '                 measuring_is_nothing=read and measuring in ("nothing", None),')
report "G24: no measuring row (orphaned) reads as nothing measuring" "$m" \
       gui:Lab.test_measuring_is_nothing_only_when_ndt_says_nothing

m=$(mutant g25 "$SERVE_PY" \
    '        read = r["rc_class"] != "timeout"' \
    '        read = True')
report "G25: a status stopped at its timeout is read as a reading" "$m" \
       gui:Lab.test_a_stopped_read_is_not_a_reading

m=$(mutant g33 "$SERVE_PY" \
    '                 busy=self.cfg.store.holding_the_slot())' \
    '                 busy=None)')
report "G33: /lab does not say which job holds the slot" "$m" \
       gui:Lab.test_lab_names_the_job_holding_the_slot

m=$(mutant g36 "$SERVE_PY" \
    '            if method == "GET" and route is not Handler.r_health:
                self._check_read()' \
    '            if method == "GET" and route is not Handler.r_health:
                pass')
report "G36: /lab and /meta need no token" "$m" \
       gui:Lab.test_lab_and_meta_need_the_token

m=$(mutant g26 "$SERVE_PY" \
    '                         "up_hosts": {k: list(v) for k, v in verbs.UP_HOSTS.items()},' \
    '                         "up_hosts": {k: [h for h in v if h] for k, v in verbs.UP_HOSTS.items()},')
report "G26: /meta is not verbs' own table (ndt's default size dropped)" "$m" \
       gui:Lab.test_meta_is_the_servers_own_tables

m=$(mutant g26b "$VERBS_PY" \
    '    minutes = body.get("minutes", DEFAULT_CLAIM_MINUTES)' \
    '    minutes = body.get("minutes", 60)')
report "G26b: the default the page offers is not the default a claim gets" "$m" \
       gui:Lab.test_meta_is_the_servers_own_tables

# dry_run
m=$(mutant g10 "$SERVE_PY" \
    '        if self.dry_run:
            raise DryRun(kind, argv)' \
    '        if False:
            raise DryRun(kind, argv)')
report "G10: a dry run spawns the job" "$m" \
       gui:DryRun.test_a_dry_run_runs_nothing_and_answers_the_argv_that_would_run

m=$(mutant g27 "$SERVE_PY" \
    '    if kind in ("up", "down"):
        return "typed", True' \
    '    if kind in ("up", "down"):
        return "plain", True')
report "G27: up and down ask for a plain confirm" "$m" \
       gui:DryRun.test_the_dialogs_strength_is_the_servers

m=$(mutant g27b "$SERVE_PY" \
    '    if kind in ("apps.start", "apps.stop"):
        return "plain", True' \
    '    if kind in ("apps.start", "apps.stop"):
        return "plain", False')
report "G27b: apps do not wait for your claim" "$m" \
       gui:DryRun.test_the_dialogs_strength_is_the_servers

m=$(mutant g28 "$SERVE_PY" \
    '            if not isinstance(self.dry_run, bool):' \
    '            if False:')
report "G28: dry_run \"yes\" is a dry run" "$m" \
       gui:DryRun.test_dry_run_is_true_or_false

m=$(mutant g21 "$SERVE_PY" \
    '        if self.route in DRY_RUN_OK and "dry_run" in body:' \
    '        if "dry_run" in body:')
report "G21: every POST takes dry_run, and the ones that spawn nothing just write" "$m" \
       gui:DryRunCells.test_the_dry_run_is_refused_where_it_is_not_offered

m=$(mutant g22 "$SERVE_PY" \
    '        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        if self.dry_run:' \
    '        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        os.makedirs(raw_root, mode=0o700)
        if self.dry_run:')
report "G22: a cell dry run makes its raw directory" "$m" \
       gui:DryRunCells.test_a_cell_dry_run_makes_nothing_and_asks_nothing

m=$(mutant g22b "$SERVE_PY" \
    '        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        if self.dry_run:' \
    '        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        self._need_confirmation(cell, confirmed)
        if self.dry_run:')
report "G22b: a shared-state cell's preview demands the confirmation it is there to show" "$m" \
       gui:DryRunCells.test_a_cell_dry_run_makes_nothing_and_asks_nothing

m=$(mutant g23 "$SERVE_PY" \
    '            if self.dry_run and st["step"] in READ_STEPS:' \
    '            if False:')
report "G23: a walk's dry run does its read-only step" "$m" \
       gui:DryRunCells.test_a_walks_dry_run_moves_nothing

# the page's sources (SourceLint, test_ndt_serve_web.py): v2 rebuilt the page on React, so v1's
# PageLint mutations now edit the TS sources. Same names where the rule is the same. The Close
# button (v1's G37b/G37c) is a click, not a spelling: tests/shell/mutate_ndt_serve_page.sh has it.
# [Co-developed with claude code -- Adam]
m=$(mutant g15 "$CLIENT_TS" \
    '  token = t;' \
    '  token = t;
  sessionStorage.setItem("t", t);')
report "G15: the token goes into sessionStorage" "$m" \
       web:SourceLint.test_nothing_is_kept_outside_memory

m=$(mutant g15b "$CLIENT_TS" \
    '  token = t;' \
    '  token = t;
  document.cookie = "t=" + t;')
report "G15b: the token goes into a cookie" "$m" \
       web:SourceLint.test_nothing_is_kept_outside_memory

m=$(mutant g15d "$CLIENT_TS" \
    '  token = t;' \
    '  token = t;
  indexedDB.open("ndt").onsuccess = () => undefined;')
report "G15d: the page opens IndexedDB (judge G-N8: only the profile would show it)" "$m" \
       web:SourceLint.test_nothing_is_kept_outside_memory

m=$(mutant g15e "$TESTHOOKS_TS" \
    '      local: localStorage.length,' \
    '      local: (localStorage.setItem("seen", "1"), localStorage.length),')
report "G15e: the test hook writes to storage instead of only counting it" "$m" \
       web:SourceLint.test_nothing_is_kept_outside_memory

m=$(mutant g15c "$CONFIRM_TSX" \
    '      <p id="c-note" className="mb-3 text-sm text-gray-500">
        {D ? D.note : ""}
      </p>' \
    '      <p id="c-note" className="mb-3 text-sm text-gray-500" dangerouslySetInnerHTML={{ __html: D ? D.note : "" }} />')
report "G15c: the server's text goes in as HTML" "$m" \
       web:SourceLint.test_no_html_from_strings_no_eval_no_inline_style

m=$(mutant g15f "$CONFIRM_TSX" \
    '      <ul id="c-blockers" className={"mb-3 list-disc pl-5 text-sm " + WARN_TEXT}>' \
    '      <ul id="c-blockers" style={{ color: "red" }}>')
report "G15f: an inline style instead of a class" "$m" \
       web:SourceLint.test_no_html_from_strings_no_eval_no_inline_style

m=$(mutant g16 "$APP_TSX" \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {' \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {
    void fetch("./api/v1/status", { headers: { "X-NDT-Token": "x" } });')
report "G16: a second fetch, with its own token header" "$m" \
       web:SourceLint.test_there_is_one_door_out_and_the_token_is_set_at_it

m=$(mutant g16b "$APP_TSX" \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {' \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {
    void call("POST", "/down", {});')
report "G16b: a write through call() itself, past post()" "$m" \
       web:SourceLint.test_there_is_one_door_out_and_the_token_is_set_at_it

m=$(mutant g16c "$APP_TSX" \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {' \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {
    navigator.sendBeacon("./api/v1/release");')
report "G16c: a beacon out of the page" "$m" \
       web:SourceLint.test_there_is_one_door_out_and_the_token_is_set_at_it

m=$(mutant g17 "$APP_TSX" \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {' \
    '  const readAll = useCallback(async (): Promise<LabAnswer | null> => {
    void post("/release", {});')
report "G17: a write outside the confirm dialog" "$m" \
       web:SourceLint.test_every_write_goes_through_the_confirm_dialog

m=$(mutant g51 "$SESSION_TS" \
    '  const r = await call("POST", "/session", { nonce });' \
    '  const r = await call("POST", "/session", { nonce });
  await call("POST", "/claim", {});')
report "G51: the session module posts something besides the key (judge G-N10)" "$m" \
       web:SourceLint.test_every_write_goes_through_the_confirm_dialog

m=$(mutant g52 "$SESSION_TS" \
    '  history.replaceState(null, "", location.pathname + location.search); // the key leaves the address bar first' \
    '')
report "G52: the key stays in the address bar" "$m" \
       web:SourceLint.test_the_key_leaves_the_address_bar_before_it_is_traded

m=$(mutant g52b "$SESSION_TS" \
    '  history.replaceState(null, "", location.pathname + location.search); // the key leaves the address bar first
  hook("href", location.href); // for the browser tests: the address as it is now, with no key
  const m = KEY_RE.exec(hash);
  opening = m ? trade(m[1]) : Promise.resolve<SessionOutcome>({ state: "no-key" });' \
    '  const m = KEY_RE.exec(hash);
  opening = m ? trade(m[1]) : Promise.resolve<SessionOutcome>({ state: "no-key" });
  history.replaceState(null, "", location.pathname + location.search);
  hook("href", location.href);')
report "G52b: the key is traded before it leaves the address bar" "$m" \
       web:SourceLint.test_the_key_leaves_the_address_bar_before_it_is_traded

# the log re-read of an opened job stops when the job ends, when the view closes and while the page
# is hidden (the orchestrator's condition, 09-27 15:4x)
m=$(mutant g37 "$JOBLOG_TS" \
    '        if (watching.current !== mine) return; // stop 2: closed, or opened again' \
    '')
report "G37: the log loop does not look whether its view was closed" "$m" \
       web:SourceLint.test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides

m=$(mutant g38 "$JOBLOG_TS" \
    '        await whileHidden(); // stop 3: nothing is read while the page is hidden' \
    '')
report "G38: the log loop reads on while the page is hidden" "$m" \
       web:SourceLint.test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides

m=$(mutant g38b "$JOBLOG_TS" \
    '  if (document.visibilityState !== "hidden") return Promise.resolve();' \
    '  return Promise.resolve();')
report "G38b: whileHidden() never waits" "$m" \
       web:SourceLint.test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides

m=$(mutant g39 "$JOBLOG_TS" \
    '    const mine = {}; // this opening: closing the view, or opening a job again, replaces it' \
    '    const mine = opening.id;')
report "G39: the loop is keyed by job id (close and reopen leaves two loops)" "$m" \
       web:SourceLint.test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides

# the 10 s refresh (Adam's R2, 09-27) pauses while measuring and while hidden
m=$(mutant g53 "$REFRESH_TS" \
    '  return lab.measuring_is_nothing === false || lab.declared !== null;' \
    '  return lab.declared !== null;')
report "G53: the refresh reads on while ndt is measuring" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g53b "$REFRESH_TS" \
    '  return lab.measuring_is_nothing === false || lab.declared !== null;' \
    '  return lab.measuring_is_nothing === false;')
report "G53b: the refresh reads on while a measurement is declared" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g54 "$REFRESH_TS" \
    '    if (document.visibilityState === "hidden") {
      setState("paused-hidden");
      return;
    }
' \
    '')
report "G54: the next tick is armed while the page is hidden" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g54b "$REFRESH_TS" \
    '    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(readRef.current);' \
    '    await readOnce(readRef.current);')
report "G54b: a tick that fires while hidden reads" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g54c "$REFRESH_TS" \
    '      if (measuring.current) {
        arm();
        return;
      }
      void tick();' \
    '      void tick();')
report "G54c: shown again, the refresh resumes although the last read was measuring" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g54d "$REFRESH_TS" \
    '    timer.current = window.setTimeout(tick, REFRESH_INTERVAL_MS);' \
    '    timer.current = window.setInterval(tick, REFRESH_INTERVAL_MS);')
report "G54d: a free-running interval (reads overlap, a pause leaves it running)" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g54e "$REFRESH_TS" \
    'export const REFRESH_INTERVAL_MS = 10_000;' \
    'export const REFRESH_INTERVAL_MS = 2_000;')
report "G54e: the refresh reads every 2 s (five times R2's load)" "$m" \
       web:SourceLint.test_the_refresh_pauses_while_measuring_and_while_hidden

m=$(mutant g55 "$MAIN_TSX" \
    'document.addEventListener("securitypolicyviolation", () => {' \
    'document.addEventListener("x-unused", () => {')
report "G55: CSP violations go uncounted (the browser tests would read 0 anyway)" "$m" \
       web:SourceLint.test_csp_violations_are_counted_for_the_browser_tests

m=$(mutant g56 "$CONFIRM_TSX" \
    '          {t("ndtServe.confirm.cancel")}' \
    '          取消')
report "G56: a UI string written into a component, past the string table" "$m" \
       web:SourceLint.test_every_ui_string_is_in_the_string_table

# the probe during a measuring pause (Adam's Q6, 09-28): /lab alone, once a minute, never hidden
m=$(mutant g59 "$REFRESH_TS" \
    '      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);' \
    '')
report "G59: a measuring pause arms no probe (nothing but 立即更新 resumes it)" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

m=$(mutant g59b "$REFRESH_TS" \
    '    await readOnce(labRef.current);' \
    '    await readOnce(readRef.current);')
report "G59b: the probe reads /apps, /health and /jobs too" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

m=$(mutant g59c "$REFRESH_TS" \
    '      if (document.visibilityState !== "hidden") timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);' \
    '      timer.current = window.setTimeout(probe, PROBE_INTERVAL_MS);')
report "G59c: the probe is armed while the page is hidden" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

m=$(mutant g59d "$REFRESH_TS" \
    '    if (document.visibilityState === "hidden") {
      arm(); // nothing is read while hidden
      return;
    }
    await readOnce(labRef.current);' \
    '    await readOnce(labRef.current);')
report "G59d: a probe that fires while hidden reads" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

m=$(mutant g59e "$REFRESH_TS" \
    'export const PROBE_INTERVAL_MS = 60_000;' \
    'export const PROBE_INTERVAL_MS = 20_000;')
report "G59e: the probe reads every 20 s (three times Q6's load)" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

m=$(mutant g59f "$APP_TSX" \
    '    const l = await get<LabAnswer>("/lab");
    setLab(l);' \
    '    const l = await get<LabAnswer>("/lab");
    setApps(await get<AppsAnswer>("/apps"));
    setLab(l);')
report "G59f: readLab, the probe's read, also runs ndt apps status" "$m" \
       web:SourceLint.test_a_measuring_pause_probes_lab_alone_once_a_minute

# every write the server can dry-run asks for it: preview false drops the argv and "claim first"
m=$(mutant g60 "$APPS_TSX" \
    '      word: action,
      preview: true,' \
    '      word: action,
      preview: false,')
report "G60: an app start/stop skips the dry run (no argv shown, no claim-first check)" "$m" \
       web:SourceLint.test_every_write_the_server_can_preview_is_previewed

m=$(mutant g60b "$CELLS_TSX" \
    '                        word: "run",
                        preview: true,' \
    '                        word: "run",
                        preview: false,')
report "G60b: a cell run skips the dry run" "$m" \
       web:SourceLint.test_every_write_the_server_can_preview_is_previewed

m=$(mutant g60c "$ACTIONS_TSX" \
    '      word: "down",
      preview: true,' \
    '      word: "down",')
report "G60c: down's request names no preview at all (the dialog's default is no dry run)" "$m" \
       web:SourceLint.test_every_write_the_server_can_preview_is_previewed

# the built files (BundleLint) and the manifest that ties them to their sources (BuildManifest)
m=$(mutant g29 "$INDEX_HTML" \
    '<div id="root"></div>' \
    '<div id="root" onclick="location.reload()"></div>')
report "G29: an inline handler in the page (the CSP would block it)" "$m" \
       web:BundleLint.test_the_page_html_loads_only_its_own_two_files

m=$(mutant g29b "$INDEX_HTML" \
    '<div id="root"></div>' \
    '<div id="root"></div>
    <script>window.x = 1;</script>')
report "G29b: an inline script in the page" "$m" \
       web:BundleLint.test_the_page_html_loads_only_its_own_two_files

m=$(mutant g29c "$INDEX_HTML" \
    '<link rel="stylesheet" crossorigin href="./app.css">' \
    '<link rel="stylesheet" crossorigin href="./app.css">
    <link rel="stylesheet" href="https://cdn.example.org/x.css">')
report "G29c: the page loads a file from another origin" "$m" \
       web:BundleLint.test_the_page_html_loads_only_its_own_two_files

m=$(mutant g57 "$APP_JS" \
    '/^#k=([A-Za-z0-9_-]{16,64})$/' \
    '(eval("0"),/^#k=([A-Za-z0-9_-]{16,64})$/)')
report "G57: the bundle calls eval" "$m" \
       web:BundleLint.test_the_script_calls_no_eval

m=$(mutant g57b "$APP_CSS" \
    '*,:before,:after{--tw-border-spacing-x: 0;' \
    '@import url("https://cdn.example.org/x.css");*,:before,:after{--tw-border-spacing-x: 0;')
report "G57b: the stylesheet loads another" "$m" \
       web:BundleLint.test_the_styles_load_nothing

m=$(mutant g57c "$MANUAL_HTML" \
    '<link rel="stylesheet" href="./app.css">' \
    '<link rel="stylesheet" href="./app.css">
<script src="./app.js"></script>')
report "G57c: the manual runs a script" "$m" \
       web:BundleLint.test_the_manual_is_a_page_without_script_or_inline_style

m=$(mutant g58 "$FORMAT_TS" \
    'export function errText(r: ApiResult<unknown>): string {' \
    'export function errText(r: ApiResult<unknown>): string {
  if (r.status === 418) return "teapot";')
report "G58: a source changed and the bundle was not rebuilt" "$m" \
       web:BuildManifest.test_every_source_file_is_in_the_manifest_with_its_hash

m=$(mutant g58b "$APP_JS" \
    '/^#k=([A-Za-z0-9_-]{16,64})$/' \
    '/^#k=([A-Za-z0-9_-]{8,64})$/')
report "G58b: the bundle was edited by hand" "$m" \
       web:BuildManifest.test_the_bundle_is_the_one_the_manifest_names

m=$(mutant g58c "$BUILD_JSON" \
    '"command": "npm ci --ignore-scripts && npm run build"' \
    '"command": "npm install && npm run build"')
report "G58c: the manifest names another build command (one without --ignore-scripts)" "$m" \
       web:BuildManifest.test_the_manifest_says_how_it_was_built

m=$(mutant_add g58d "$STATIC_DIR/extra.js" 'x=1')
report "G58d: a file in static/ that the build did not write" "$m" \
       web:BuildManifest.test_the_bundle_is_the_one_the_manifest_names

m=$(mutant_add g58e "$WEB_DIR/src/extra.ts" 'x=1')
report "G58e: a source file the manifest does not name" "$m" \
       web:BuildManifest.test_every_source_file_is_in_the_manifest_with_its_hash

# --- the intake judge on fcd4f69a (opus-judge, 09-27; the orchestrator's selection) -------------
# [Co-developed with claude code -- Adam]

m=$(mutant g41 "$SERVE_PY" \
    '        self._start("apps." + action, _whitelisted(verbs.argv_app, name, action, body, self.cfg.apps), body,
                    precheck=self._require_own_claim)' \
    '        self._start("apps." + action, _whitelisted(verbs.argv_app, name, action, body, self.cfg.apps), body)')
report "G41: an app start/stop runs under somebody else's claim (B1: the page was the only guard)" "$m" \
       gui:AppsNeedYourClaim.test_apps_start_and_stop_run_only_under_your_claim

m=$(mutant g40 "$JOBLOG_TS" \
    '        if (job.state !== "running") {' \
    '        if (false) {')
report "G40: the log loop does not stop when the job ends (G-N1)" "$m" \
       web:SourceLint.test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides

m=$(mutant g43 "$SERVE_PY" \
    'if len(cols) > 9 and cols[1] == want and cols[3] == "0A":' \
    'if len(cols) > 9 and cols[3] == "0A":')
report "G43: the listener check ignores which address and port (G-N7)" "$m" \
       gui:UrlCommand.test_url_sends_the_token_only_to_the_pid_that_holds_the_port

m=$(mutant g44 "$SERVE_PY" \
    '        fds = os.listdir("/proc/%d/fd" % pid)
    except OSError:
        return False' \
    '        fds = os.listdir("/proc/%d/fd" % pid) if os.path.isdir("/proc/%d" % pid) else None
    except OSError:
        return False
    if fds is None:
        return bool(inodes)')
report "G44: serve.json's pid is gone, and whatever listens on its port is trusted (G-N7)" "$m" \
       gui:UrlCommand.test_url_refuses_a_serve_json_whose_pid_is_gone

m=$(mutant g45 "$NDT" \
    '    serve)   shift; exec python3 "$HERE/../ndt_serve/serve.py" --ndt "$HERE/ndt" "$@" ;;' \
    '    serve)   shift; [[ "${1:-}" == url ]] && { echo "ndt serve: no such subcommand: url" >&2; exit 2; }; exec python3 "$HERE/../ndt_serve/serve.py" --ndt "$HERE/ndt" "$@" ;;')
report "G45: ndt serve does not pass url through (G-N8)" "$m" \
       gui:UrlCommand.test_ndt_serve_url_is_the_same_command

m=$(mutant g46 "$SERVE_PY" \
    '        raise SystemExit("ndt serve url: no running server'"'"'s files in %s (%s)" % (conf, e))' \
    '        info, token = {"port": 8765, "pid": 1}, ""')
report "G46: a missing serve.json is guessed at, port 8765 (G-N8)" "$m" \
       gui:UrlCommand.test_url_with_no_server_says_so

# --- GUI v2: the server side (the Web-GUI button, the url command's connection, the claim form) ---
# [Co-developed with claude code -- Adam]

m=$(mutant g47 "$SERVE_PY" \
    '    if u.scheme not in ("http", "https") or not u.hostname or re.search(r"[\x00-\x20\x7f]", raw):' \
    '    if False:')
report "G47: any --webgui-url is taken, javascript: included (it becomes an <a href>)" "$m" \
       gui:WebGuiUrl.test_a_web_gui_url_that_is_not_http_is_refused_at_start

m=$(mutant g48 "$SERVE_PY" \
    '    if not peer_owned_by(pid, port, sock.getsockname()[1]):' \
    '    if False:')
report "G48: url sends the token over a connection another process accepted" "$m" \
       gui:UrlCommand.test_url_sends_the_token_only_over_a_connection_the_pid_accepted

m=$(mutant g49 "$NDT" \
    "        printf 'yours -- %dm left (until %s)\n' \"\$left\"" \
    "        printf 'yours -- %d min left (until %s)\n' \"\$left\"")
report "G49: ndt's own-claim form changes and OWN_CLAIM no longer reads it" "$m" \
       ClaimFormProvenance.test_own_claim_is_what_claim_line_prints_for_yours_and_nothing_else

m=$(mutant g50 "$SERVE_PY" \
    'OWN_CLAIM = re.compile(r"yours -- [0-9]+m left \(until [0-9]{2}:[0-9]{2}:[0-9]{2}\)")' \
    'OWN_CLAIM = re.compile(r"yours -- [0-9]{1,2}m left \(until [0-9]{2}:[0-9]{2}:[0-9]{2}\)")')
report "G50: OWN_CLAIM is narrower than claim_line (a 240-minute claim is not yours)" "$m" \
       ClaimFormProvenance.test_own_claim_is_what_claim_line_prints_for_yours_and_nothing_else

m=$(mutant g50b "$SERVE_PY" \
    'OWN_CLAIM = re.compile(r"yours -- [0-9]+m left \(until [0-9]{2}:[0-9]{2}:[0-9]{2}\)")' \
    'OWN_CLAIM = re.compile(r"yours -- [0-9]+m left \(until .*\)")')
report "G50b: OWN_CLAIM is wider than claim_line (an owner that spells the own form is yours)" "$m" \
       ClaimFormProvenance.test_own_claim_is_what_claim_line_prints_for_yours_and_nothing_else

m=$(mutant g61 "$SERVE_PY" \
    '        self.send_header("X-Content-Type-Options", "nosniff")' \
    '        self.send_header("Set-Cookie", "ndt=1; HttpOnly; SameSite=Strict")
        self.send_header("X-Content-Type-Options", "nosniff")')
report "G61: an answer sets a cookie (Chrome keeps it encrypted, out of the profile scan's sight)" "$m" \
       gui:Page.test_no_answer_sets_a_cookie

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
