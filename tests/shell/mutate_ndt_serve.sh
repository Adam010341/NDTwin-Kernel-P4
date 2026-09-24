#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_ndt_serve.py (TICKET-ndt-serve, 09-24).
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
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (baseline red / harness),
#       3 a file under test changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST="$REPO/tests/python/test_ndt_serve.py"
SERVE_PY="$REPO/tools/ndt_serve/serve.py"
VERBS_PY="$REPO/tools/ndt_serve/verbs.py"
JOBS_PY="$REPO/tools/ndt_serve/jobs.py"
RUNNER_PY="$REPO/tools/ndt_serve/runner.py"
NDT="$REPO/tools/test_workflow/ndt"
SUBJECTS=("$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$NDT")
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-serve-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "${SUBJECTS[@]}")

SURVIVORS=0
MUTATIONS=0

layout() {   # $1 = dir -- a copy of the service and of ndt with what it sources
    local d="$1"
    mkdir -p "$d/tools/ndt_serve" "$d/tools/test_workflow"
    cp "$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$d/tools/ndt_serve/"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/ndt"
}

run_against() {   # $1 = dir, $2... = unittest ids (none = the whole suite)
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

report() {   # $1 = mutation name, $2 = mutant dir, $3 = Class.test_case that must fail
    local out rc name="${3##*.}"
    MUTATIONS=$((MUTATIONS+1))
    if [[ "$2" == NOAPPLY ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (the mutation did not apply -- the anchor moved)\n' "$1"
        return
    fi
    out=$(run_against "$2" "$3"); rc=$?
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
run_against "$BK/base" | tail -1
run_against "$BK/base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
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
       Entry.test_root_is_reserved_for_the_gui

m=$(mutant m40 "$SERVE_PY" \
    '    locks = [hold_lock(os.path.join(cfg.state_dir, "serve.lock")), hold_lock(cfg.token_file + ".lock")]' \
    '    locks = []')
report "M40: two servers can share one state directory and token" "$m" \
       Entry.test_second_server_on_the_same_state_refuses

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
