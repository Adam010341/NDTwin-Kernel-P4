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
TEST_CELLS="$REPO/tests/python/test_ndt_serve_cells.py"
SERVE_PY="$REPO/tools/ndt_serve/serve.py"
VERBS_PY="$REPO/tools/ndt_serve/verbs.py"
JOBS_PY="$REPO/tools/ndt_serve/jobs.py"
RUNNER_PY="$REPO/tools/ndt_serve/runner.py"
CELLS_PY="$REPO/tools/ndt_serve/cells.py"
DEMO_PY="$REPO/tools/ndt_serve/demo_sequence.py"
NDT="$REPO/tools/test_workflow/ndt"
SUBJECTS=("$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$CELLS_PY" "$DEMO_PY" "$NDT")
BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-serve-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "${SUBJECTS[@]}")

SURVIVORS=0
MUTATIONS=0

layout() {   # $1 = dir -- a copy of the service and of ndt with what it sources
    local d="$1"
    mkdir -p "$d/tools/ndt_serve" "$d/tools/test_workflow"
    cp "$SERVE_PY" "$VERBS_PY" "$JOBS_PY" "$RUNNER_PY" "$CELLS_PY" "$DEMO_PY" "$d/tools/ndt_serve/"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$d/tools/test_workflow/"
    chmod +x "$d/tools/test_workflow/ndt"
}

run_against() {   # $1 = dir, $2 = test file, $3... = unittest ids (none = the whole file)
    local d="$1" t="$2"; shift 2
    NDT_SERVE_UNDER_TEST="$d/tools/ndt_serve" NDT_UNDER_TEST="$d/tools/test_workflow/ndt" \
        timeout 600 python3 "$t" "$@" 2>&1
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

report() {   # $1 = mutation name, $2 = mutant dir, $3 = [cells:]Class.test_case that must fail
    local out rc id="$3" t="$TEST"
    [[ "$id" == cells:* ]] && { t="$TEST_CELLS"; id="${id#cells:}"; }
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
for t in "$TEST" "$TEST_CELLS"; do
    out=$(run_against "$BK/base" "$t"); brc=$?
    printf '  %s: %s\n' "$(basename "$t")" "$(tail -1 <<<"$out")"
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
       Entry.test_root_is_reserved_for_the_gui

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
    '        job_id = self._spawn(kind, [self.cfg.ndt_real] + argv_tail, body)' \
    '        job_id = self._spawn(kind, [self.cfg.ndt] + argv_tail, body)')
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
    '    "apps.status": {"code": [(9747, 0, "return 0")]},' \
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
    '        if not (line or "").startswith("yours"):' \
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


m=$(mutant m62 "$SERVE_PY" \
    '    request_queue_size = 64' \
    '    request_queue_size = 5')
report "M62: the listen backlog is socketserver's 5 (a burst of 20 gets a reset)" "$m" \
       Bounded.test_listen_backlog_holds_a_burst

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
