#!/bin/bash
# =================================================================================================
# lib.sh -- shared instrument for the T-4 full-stack round (PREREG 2026-08-30).
#
# WRITTEN, NOT RUN. Syntax-checked with `bash -n` only. Every gate below is unexecuted.
#
# This file exists because the last round's four headline findings were all defects in the
# harness, not the system (FINDINGS-section6-and-T2.md, "Harness defects found (mine, not the
# system's)"). Each helper here answers one of H-17..H-24 by construction, so a script that uses
# the helper cannot re-commit the defect by forgetting.
#
# H-CORRESPONDENCE FOR THIS FILE
#   H-17  `kill -0` cannot tell "gone" from "not yours" (EPERM on root-owned procs).
#         -> `alive()` reads /proc/<pid>, which is readable regardless of owner. `kill -0`
#            appears nowhere in this harness. `proc_cmdline()` additionally proves the pid is
#            still the process we spawned and not a recycled one.
#   H-18  grep for the manual's word instead of the software's emitted text.
#         -> PATTERN REGISTRY below. Every regex is declared with the verbatim line it MUST
#            match (copied from the emitting source file, cited) and a line it MUST NOT match.
#            `pattern_selftest` runs the whole registry before any measurement. A pattern that
#            cannot match real output fails at startup, not at conclusion time.
#   H-19  a 404 IS the service answering; "no answer" is a different observation.
#         -> `http_probe()` records curl's exit status and the HTTP status in SEPARATE files and
#            returns both. No caller may collapse them.
#   H-20  stale root-owned artefacts from a previous run get read as this run's result.
#         -> `artifact_signature()` / `require_absent_or_fresh()`. If the file cannot be removed
#            or invalidated, the caller ABORTS. It never falls through to "assume it is ours".
#   H-21  `... | tail -1 || bad` can never fail; a pipeline's status is its last stage's.
#         -> `set -o pipefail` is set here for every sourcing script, and `gate()` takes an
#            already-computed VALUE plus a predicate. No gate in this harness ends in a pipe.
#   H-22  `$!` after `( ... ) &` names the subshell, not the process inside it.
#         -> `spawn_exec()` uses `( cd D && exec ... ) &`, where every step execs rather than
#            forks, so `$!` is the program's own pid -- and then PROVES it by reading
#            /proc/<pid>/cmdline and matching it against the command requested. A spawn whose
#            cmdline does not match is a hard abort, because the pid we would later kill is
#            then the wrong process. `pkill -f` / `pgrep -f` are used NOWHERE.
#   H-23  a backwards grep (`link (add|up|discover)` against `Discovered link`).
#         -> same PATTERN REGISTRY. The must-match sample for each pattern is a real line, so a
#            reversed pattern is caught by the self-test.
#   H-24  block-buffered stdout read as a complete log.
#         -> `PYTHONUNBUFFERED=1` and `PYTHONIOENCODING=utf-8` exported here; `wait_for_line()`
#            polls for a sentinel instead of reading once and concluding from absence.
#
# ADDITIONAL TRAPS THIS FILE ENCODES (each has drawn blood in this project)
#   * `ndt up` / `ndt down` kill the shell that calls them (exit 144, teardown itself succeeds).
#     -> `ndt_up()` / `ndt_down()` run under `setsid`, redirect to a log, and are judged on the
#        log's own success line, never on rc. See memory: ndt-one-command-lab-lifecycle.
#   * the kernel binary is interactive; it prompts for three answers when given no flags.
#     -> nothing here launches it bare. `ndt up` supplies `--mode mininet --topology ... --no-ai`
#        (stack.sh:756). If you launch it by hand, supply all three.
#   * an action that did not report an error is not an action that happened.
#     -> `assert_effect()` requires a positive, independently-observed consequence, and is the
#        only sanctioned way to conclude that an injection landed.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================

set -Eeuo pipefail

export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=utf-8
export LC_ALL=C

# --- where things live ---------------------------------------------------------------------------
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUND_DIR="$(dirname "$HARNESS_DIR")"
# The kernel checkout **under test**, which is not necessarily the one this file lives in.
#
# The derived form below assumes the tree that ships the harness is the tree being measured.
# That is false for any round pinned to a baseline, and T-4 is exactly that: its ruling builds
# from 89c1754 in a separate `git worktree`, because dff87f9 (the T-7 acquire_lock and P-1
# fixes) lands between 89c1754 and HEAD and rewrites five of the files under test. Left
# underivable, every `$REPO` use below would have read the wrong tree *and said nothing*:
# 00_preflight would have sha256'd a binary the fabric was not running and written it into
# binary-provenance.txt, and 40_/50_'s F-1 and F-4 source checks would have been answered from
# post-fix source. A provenance record that names the wrong binary is worse than none.
# (memory: benchmark-must-name-the-binary-it-measured)
#
# KERNEL_DIR is reused rather than a new name invented: components.env already means exactly
# this by it and already honours it from the environment, so one export makes ndt, stack.sh and
# this harness agree. A second name could be set half-way; this one cannot.
REPO="${KERNEL_DIR:-$(cd "$HARNESS_DIR/../../../.." && pwd)}"

# Every artefact of a run lands under one timestamped directory so a second run cannot be read
# as the first. RUN_TAG is settable so a re-run can be labelled by hand.
: "${RUN_TAG:=$(date -u +%Y%m%dT%H%M%SZ)}"
: "${OUT:=$ROUND_DIR/raw/$RUN_TAG}"

: "${NDT_URL:=http://localhost:8000}"
: "${RYU_URL:=http://localhost:8080}"
: "${P4_PROXY_URL:=http://localhost:8081}"
: "${NDT_BIN:=$HOME/.local/bin/ndt}"
: "${LOG_DIR:=$REPO/.test_run/logs}"
: "${PID_DIR:=$REPO/.test_run/pids}"
: "${P4_MANIFEST:=/tmp/ndtwin_p4_switches.json}"

FAILS=0
CHECKS=0

# --- output --------------------------------------------------------------------------------------
_ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
say()   { printf '\n===== %s =====\n' "$*"; }
info()  { printf '      %s\n' "$*"; }
ok()    { CHECKS=$((CHECKS+1)); printf '  PASS  %s\n' "$*"; _jrec pass "$*"; }
bad()   { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf '  FAIL  %s\n' "$*"; _jrec fail "$*"; }
# UNTESTABLE is a first-class verdict, not a soft pass. PREREG §3 R-1 and §3 R-5 both require a
# third branch so that "we could not reach it" is never scored as "it is fine".
skip()  { CHECKS=$((CHECKS+1)); printf '  N/A   %s\n' "$*"; _jrec untestable "$*"; }
die()   { printf '\n  ABORT %s\n' "$*" >&2; _jrec abort "$*"; exit 3; }

_jrec() {
    mkdir -p "$OUT"
    printf '{"t":"%s","verdict":"%s","script":"%s","text":%s}\n' \
        "$(_ts)" "$1" "${SCRIPT_NAME:-?}" \
        "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        >> "$OUT/verdicts.jsonl"
}

# gate <name> <predicate-result-as-0/1> <observed-text>
#
# H-21: the caller computes the value first and passes it in. There is deliberately no form of
# this function that accepts a pipeline, because a pipeline's exit status is its last stage's and
# `grep X | tail -1 || bad` therefore can never go red.
gate() {
    local name="$1" result="$2" observed="${3:-}"
    if [[ "$result" == "0" ]]; then ok "$name${observed:+  [$observed]}"
    else bad "$name${observed:+  [observed: $observed]}"; fi
}

summary() {
    printf '\n===== %s: %d check(s), %d FAIL =====\n' "${SCRIPT_NAME:-run}" "$CHECKS" "$FAILS"
    printf 'artefacts: %s\n' "$OUT"
    return 0
}

# =================================================================================================
# PATTERN REGISTRY  (H-18, H-23)
#
# Format:  <key>|<extended-regex>|<MUST-match sample>|<MUST-NOT-match sample>|<source citation>
#
# The MUST-match sample is a line the software actually emits, reconstructed from the format
# string in the cited source file. Do not invent one from a manual: M-3 in the T-2 findings is
# exactly the case where the User Manual names `ECONNREFUSED` and the software emits
# `Connection refused`, and a check written from the page printed PASS over ten dead switches.
#
# The MUST-NOT-match sample is chosen to be the nearest plausible wrong hit, so that a pattern
# loosened until it "works" is caught too.
#
# CALIBRATION RULE FOR WHOEVER RUNS THIS: after the first live run, re-derive each MUST-match
# sample from the actual log on disk and replace the reconstructed one. A sample copied from a
# source-code format string is one step better than a sample copied from a manual, but it is
# still not the emitted text.
# =================================================================================================
# 🔑 THE REGISTRY IS A FLAT ARRAY READ FIVE AT A TIME, WITH NO FIELD DELIMITER.
#
# The first version of this file packed the five fields into one string separated by `|` and
# split them with `cut -d'|'`. Every regex that used alternation -- `(install|modify|delete)`,
# `\[(error|critical)\]` -- was therefore torn in half by its own delimiter, and four of the
# eleven patterns were silently mangled into invalid regexes.
#
# The self-test caught it on its first execution, which is the entire argument for having one:
# an instrument whose own registry was broken would have reported "0 matches" for the kernel's
# dispatch-failure line and that would have been written up as "the kernel no longer logs
# rejected rules" -- a system-shaped finding manufactured by a delimiter.
# [Co-developed with claude code -- Adam]
#
# Order within each group of five: key, regex, MUST-match, MUST-NOT-match, source citation.
PATTERNS=(

 "kernel_dispatch_failed"
 'dispatched (install|modify|delete) failed for dpid [0-9]+ \(priority [0-9]+\): HTTP [0-9]+ --'
 '[error] [Controller.cpp:55 operator()] dispatched install failed for dpid 1 (priority 901): HTTP 200 -- P4 proxy agent reported an error in a 200 response'
 'dispatched install succeeded for dpid 1 (priority 901)'
 'src/ndt_core/routing_management/Controller.cpp:55-62 (format string; the literal runtime phrase does NOT appear in src/)'

 "kernel_edge_not_found"
 'edge not found by dpid/port [0-9]+:[0-9]+; the topology file has no link there'
 'edge not found by dpid/port 5:4294967293; the topology file has no link there, so paths through it stay empty'
 'no edge was found for dpid 5 port 4'
 'src/ndt_core/collection/FlowLinkUsageCollector.cpp:2898'

 "kernel_reserved_port_out"
 'edge not found by dpid/port [0-9]+:4294967(0[4-9][0-9]|[12][0-9][0-9])'
 'edge not found by dpid/port 5:4294967293; the topology file has no link there'
 'edge not found by dpid/port 5:4'
 'OFPP reserved range 0xFFFFFF00-0xFFFFFFFF = 4294967040-4294967295; OFPP_CONTROLLER=4294967293. See live-findings-2026-08-18-ovs.md F-1'

 "kernel_get_graph_ok"
 'get_graph_data success'
 '[info] [HttpSession.cpp:571 handleGetGraphData] get_graph_data success'
 'get_graph_data failed'
 'src/ndt_core/http/HttpSession.cpp:571'

 "kernel_error_line"
 '\[(error|critical)\]'
 '[2026-08-18 17:49:18.574] [error] [Controller.cpp:55 operator()] dispatched install failed'
 '[2026-08-18 17:49:18.574] [warning] [Controller.cpp:55 operator()] something harmless'
 'spdlog level tag as written into kernel.log'

 "proxy_link_discovered"
 'Discovered link'
 'INFO:topology_manager:Discovered link s1-eth3 <-> s3-eth1'
 'link discovered between s1 and s3'
 'H-23: the 08-30 harness grepped "link (add|up|discover)", which requires "link" BEFORE the verb, and got zero hits against this line'

 "proxy_bind_failed"
 'error while attempting to bind on address .*address already in use'
 "ERROR:    [Errno 98] error while attempting to bind on address ('0.0.0.0', 8081): address already in use"
 'ERROR: could not bind to port 8081'
 'uvicorn 0.51.0; quoted verbatim in FINDINGS-section6-and-T2.md P-1'

 "conn_refused_real"
 '(Connection refused|\[Errno 111\])'
 'Failed to connect to remote host: Connection refused'
 'ECONNREFUSED against :50051'
 'M-3: the User Manual names ECONNREFUSED; the software never emits that word. A check written from the page printed PASS over ten dead switches.'

 "ndt_up_ready"
 'up\. .*ready'
 '===== up. ready ====='
 '===== up, but not verified -- do not measure on this ====='
 'tools/test_workflow/ndt:740 and :929'

 "ndt_up_unverified"
 'up, .*but not verified'
 '===== up, but not verified -- do not measure on this ====='
 '===== up. ready ====='
 'tools/test_workflow/ndt:929'

 "te_eof_crash"
 'EOFError'
 'EOFError: EOF when reading a line'
 'KeyboardInterrupt'
 'Traffic-engineering-App.py:599/:605 -- ask_mode() calls input() and only enter_listener() at :591 catches EOFError'
)

PATTERN_STRIDE=5

pattern_of() {
    local key="$1" i
    for (( i = 0; i < ${#PATTERNS[@]}; i += PATTERN_STRIDE )); do
        if [[ "${PATTERNS[$i]}" == "$key" ]]; then
            printf '%s' "${PATTERNS[$((i+1))]}"
            return 0
        fi
    done
    die "pattern_of: no pattern registered under key '$key'"
}

# Run every registered pattern against its two samples. This is the check that would have caught
# H-23 (backwards regex) and H-18 (grepping the manual's word) before either produced a finding.
#
# HOW TO FORCE IT RED: edit any regex in PATTERNS to something that cannot match its own
# must-match sample -- e.g. change `Discovered link` to `link discovered`, which is precisely the
# H-23 defect. The self-test must fail and every script must refuse to start.
pattern_selftest() {
    local i key rx yes no src rc=0 n=0
    (( ${#PATTERNS[@]} % PATTERN_STRIDE == 0 )) \
        || die "PATTERN REGISTRY is malformed: ${#PATTERNS[@]} entries is not a multiple of $PATTERN_STRIDE. Someone added a pattern and forgot a field, which would silently shift every later pattern's regex onto the wrong key."
    for (( i = 0; i < ${#PATTERNS[@]}; i += PATTERN_STRIDE )); do
        key="${PATTERNS[$i]}"
        rx="${PATTERNS[$((i+1))]}"
        yes="${PATTERNS[$((i+2))]}"
        no="${PATTERNS[$((i+3))]}"
        src="${PATTERNS[$((i+4))]}"
        n=$(( n + 1 ))
        if ! printf '%s\n' "$yes" | grep -qE -- "$rx"; then
            printf '  SELFTEST FAIL  %s: does not match its own sample\n    rx: %s\n    ln: %s\n    src: %s\n' \
                   "$key" "$rx" "$yes" "$src" >&2
            rc=1
        fi
        if printf '%s\n' "$no" | grep -qE -- "$rx"; then
            printf '  SELFTEST FAIL  %s: matches the line it must NOT match\n    rx: %s\n    ln: %s\n' \
                   "$key" "$rx" "$no" >&2
            rc=1
        fi
    done
    (( rc == 0 )) || die "pattern self-test failed -- refusing to measure with an instrument that cannot read its own subject"
    ok "pattern self-test: $n pattern(s), each matched its sample and rejected its near-miss"
}

# grep a file with a registered pattern; prints the match count on stdout, never in a pipeline
# whose status is consumed as the verdict (H-21).
count_matches() {
    local key="$1" file="$2" rx n
    rx="$(pattern_of "$key")"
    [[ -f "$file" ]] || { printf '%s' "-1"; return 0; }   # -1 means "no such file", NOT "zero hits"
    n="$(grep -cE -- "$rx" "$file" || true)"
    printf '%s' "${n:-0}"
}

# =================================================================================================
# process liveness and spawning  (H-17, H-22)
# =================================================================================================

# H-17. /proc is readable no matter who owns the process. `kill -0` returns EPERM for a live
# root-owned process, which is indistinguishable by exit status from ESRCH, and that one
# confusion produced the whole retracted T2-1.
alive() { [[ -n "${1:-}" && -d "/proc/$1" ]]; }

proc_cmdline() {
    [[ -r "/proc/${1:-}/cmdline" ]] || { printf ''; return 0; }
    tr '\0' ' ' < "/proc/$1/cmdline"
}

# spawn_exec <name> <workdir> <logfile> <cmd> [args...]
#
# H-22. `( cd D && exec nohup CMD ) &` keeps ONE pid from the subshell through nohup into CMD,
# because each step execs instead of forking, so `$!` is the program. This is the same idiom
# ndt's own app_spawn uses (tools/test_workflow/ndt:1538-1554) and for the same recorded reason.
# We then verify it: the pid must be alive AND its cmdline must contain the program we asked for.
# Without that verification we would only have swapped one unchecked assumption for another.
spawn_exec() {
    local name="$1" dir="$2" log="$3"; shift 3
    mkdir -p "$(dirname "$log")" "$OUT/pids"
    : > "$log"
    ( cd "$dir" && exec nohup "$@" >"$log" 2>&1 ) &
    local pid=$!
    sleep 1
    if ! alive "$pid"; then
        bad "$name exited within 1s -- see $log"
        tail -5 "$log" 2>/dev/null | sed 's/^/        /' || true
        return 1
    fi
    local cl base
    cl="$(proc_cmdline "$pid")"
    base="$(basename "$1")"
    if [[ "$cl" != *"$base"* ]]; then
        die "$name: pid $pid is alive but its cmdline does not contain '$base' -- this is the H-22 shape (we would later kill the wrong process). cmdline: $cl"
    fi
    printf '%s\n' "$pid" > "$OUT/pids/$name.pid"
    ok "$name spawned as pid $pid, cmdline verified"
    printf '%s' "$pid"
}

# stop_pid <name> <pid> -- TERM, wait, KILL, then PROVE it is gone.
# No pkill/pgrep by pattern, ever: this project has killed the wrong thing seven times that way.
stop_pid() {
    local name="$1" pid="${2:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || { info "$name: no usable pid ('${pid}'), nothing killed"; return 0; }
    (( pid > 1 )) || { bad "$name: refusing to signal pid $pid"; return 1; }
    alive "$pid" || { info "$name (pid $pid) already gone"; return 0; }
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do alive "$pid" || break; sleep 0.5; done
    if alive "$pid"; then kill -KILL "$pid" 2>/dev/null || true; sleep 1; fi
    if alive "$pid"; then
        bad "$name (pid $pid) STILL RUNNING after TERM and KILL"
        return 1
    fi
    ok "$name (pid $pid) stopped, absence verified via /proc"
}

# Who actually holds a TCP port. P-1 (FINDINGS-section6-and-T2.md) is the reason this exists:
# a proxy whose bind failed still ran its lifespan startup and wrote to the data plane, and
# every sample taken over the port was answered by a DIFFERENT process from the one just
# started. "Something answers on :8081" is not "the thing I started answers on :8081".
port_holder() {
    local port="$1" out
    out="$(ss -lptnH "sport = :$port" 2>/dev/null || true)"
    [[ -n "$out" ]] || { printf ''; return 0; }
    printf '%s' "$out" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}

# assert_port_is <label> <port> <expected-pid>
assert_port_is() {
    local label="$1" port="$2" want="$3" got
    got="$(port_holder "$port")"
    if [[ -z "$got" ]]; then
        bad "$label: nothing is listening on :$port"
    elif [[ -z "$want" ]]; then
        info "$label: :$port held by pid $got ($(proc_cmdline "$got" | cut -c1-80))"
    elif [[ "$got" == "$want" ]]; then
        ok "$label: :$port held by the pid we started ($got)"
    else
        bad "$label: :$port is held by pid $got, NOT the pid we started ($want) -- P-1 orphan; every sample over this port would be another process's answer"
    fi
}

# =================================================================================================
# HTTP  (H-19)
# =================================================================================================

# http_probe <slug> <METHOD> <url> [json-body]
# Prints "<curl_rc> <http_code>" and leaves the body at $OUT/http/<slug>.body.
#
# H-19. curl's exit status and the HTTP status are two different observations and are kept in two
# different variables. "The kernel did not answer" was concluded on 08-30 from a 404, which is
# the kernel answering. A caller that wants "did anything answer" must test curl_rc; a caller
# that wants "did the route exist" must test http_code.
http_probe() {
    local slug="$1" method="$2" url="$3" body="${4:-}"
    mkdir -p "$OUT/http"
    local bodyf="$OUT/http/$slug.body" code rc
    set +e
    if [[ -n "$body" ]]; then
        code="$(curl -s -o "$bodyf" -w '%{http_code}' --max-time 15 \
                     -X "$method" -H 'Content-Type: application/json' --data-binary "$body" "$url")"
    else
        code="$(curl -s -o "$bodyf" -w '%{http_code}' --max-time 15 -X "$method" "$url")"
    fi
    rc=$?
    set -e
    printf '%s\n' "$rc"   > "$OUT/http/$slug.curlrc"
    printf '%s\n' "$code" > "$OUT/http/$slug.code"
    printf '%s %s' "$rc" "${code:-000}"
}

# =================================================================================================
# stale artefacts  (H-20)
# =================================================================================================

artifact_signature() {
    local p="$1"
    if [[ ! -e "$p" ]]; then printf 'ABSENT'; return 0; fi
    printf '%s %s %s' \
        "$(stat -c %Y "$p" 2>/dev/null || echo '?')" \
        "$(stat -c %s "$p" 2>/dev/null || echo '?')" \
        "$(sha256sum "$p" 2>/dev/null | cut -c1-16 || echo '?')"
}

# require_absent_or_fresh <path> <baseline-signature>
#
# H-20. `rm -f /tmp/ndtwin_p4_switches.json` fails with "Operation not permitted" when the
# previous run created it as root. On 08-30 the run happened to overwrite it, so the check
# passed -- but had the fabric failed, the check would have read the PREVIOUS run's manifest and
# reported success. There is no safe fall-through here: if the artefact still carries the old
# signature, we abort.
require_absent_or_fresh() {
    local p="$1" baseline="$2" now
    now="$(artifact_signature "$p")"
    if [[ "$now" == "ABSENT" ]]; then ok "artefact $p is absent (nothing stale to inherit)"; return 0; fi
    if [[ "$now" == "$baseline" ]]; then
        die "artefact $p is byte-identical to the pre-run baseline ($baseline). It was NOT rewritten by this run, so anything read from it belongs to a previous run. Remove it (it may be root-owned: 'sudo rm -f $p') and start again."
    fi
    ok "artefact $p was rewritten by this run (was: $baseline / now: $now)"
}

# =================================================================================================
# waiting, and asserting that things happened
# =================================================================================================

# wait_for_line <file> <pattern-key> <timeout-s> -- H-24: poll, do not read once and conclude.
wait_for_line() {
    local file="$1" key="$2" timeout="${3:-120}" rx i
    rx="$(pattern_of "$key")"
    for i in $(seq 1 "$timeout"); do
        if [[ -f "$file" ]] && grep -qE -- "$rx" "$file"; then printf '%s' "$i"; return 0; fi
        sleep 1
    done
    printf '%s' "-1"; return 0
}

# assert_effect <what-was-done> <observed-consequence> <expected>
#
# "The command returned 0" is not evidence that the command did anything. Every injection in
# this round must name an independently-observed consequence. See
# memory: injections-must-assert-their-own-success -- deletion leaves a loud hole, renaming
# leaves a quiet wrong answer.
assert_effect() {
    local what="$1" observed="$2" expected="$3"
    if [[ "$observed" == "$expected" ]]; then
        ok "effect asserted: $what -> $observed (expected $expected)"
    else
        bad "effect NOT asserted: $what -> observed '$observed', expected '$expected'. Anything downstream of this is measuring a no-op."
    fi
}

# =================================================================================================
# ndt lifecycle wrappers
#
# `ndt up` and `ndt down` kill the shell that calls them (exit 144) while the teardown itself
# succeeds. Judging them on rc therefore reports failure for a successful teardown and, worse,
# takes this script down with them. setsid + judge the log.
# =================================================================================================

ndt_up() {
    local args="$*" log="$OUT/ndt_up.log"
    info "ndt up $args   (setsid; rc is NOT the verdict, the log's own success line is)"
    set +e
    setsid "$NDT_BIN" up $args > "$log" 2>&1
    local rc=$?
    set -e
    info "ndt up exited rc=$rc (144 is the known shell-kill; ignored on purpose)"
    local n_ready n_unver
    n_ready="$(count_matches ndt_up_ready "$log")"
    n_unver="$(count_matches ndt_up_unverified "$log")"
    if [[ "$n_unver" != "0" && "$n_unver" != "-1" ]]; then
        bad "ndt up finished 'up, but not verified' -- do not measure on this fabric (see $log)"
        return 1
    fi
    if [[ "$n_ready" == "0" || "$n_ready" == "-1" ]]; then
        bad "ndt up never printed its ready line (see $log)"
        return 1
    fi
    ok "ndt up reached 'up. ready' (verified from the log, not from rc)"
}

ndt_down() {
    local log="$OUT/ndt_down.log"
    info "ndt down   (setsid; rc is NOT the verdict)"
    set +e
    setsid "$NDT_BIN" down > "$log" 2>&1
    set -e
    # Teardown is judged on the state of the machine, not on the word "down".
    local n
    n="$(ps -eo comm= 2>/dev/null | grep -cx 'simple_switch_g' || true)"
    info "bmv2 processes remaining: ${n:-0}"
    printf '%s' "${n:-0}"
}

ndt_status() {
    local slug="${1:-status}"
    mkdir -p "$OUT"
    set +e
    "$NDT_BIN" status > "$OUT/ndt_status_$slug.txt" 2>&1
    set -e
    printf '%s' "$OUT/ndt_status_$slug.txt"
}

# =================================================================================================
# R-5's three-valued verdict
#
# PREREG §3 R-5: "Each gets one of: still present / fixed / no longer reachable (the third
# branch is registered on purpose so a finding that merely became untestable is not scored as
# fixed)." The third branch is the whole point: a check that cannot reach its subject must not
# be able to produce a green result. `verdict5` refuses any value outside the three.
#
# EVIDENCE is mandatory and free text, and it must name what was OBSERVED, not what was
# concluded. "spec.py:502 reads Num(min=-1, max=100)" is evidence; "the schema is fixed" is not.
# =================================================================================================
verdict5() {
    local finding="$1" v="$2" evidence="${3:-}"
    case "$v" in
        present)     printf '  R-5 %-6s %-22s %s\n' "$finding" "STILL PRESENT"      "$evidence" ;;
        fixed)       printf '  R-5 %-6s %-22s %s\n' "$finding" "FIXED"              "$evidence" ;;
        unreachable) printf '  R-5 %-6s %-22s %s\n' "$finding" "NO LONGER REACHABLE" "$evidence" ;;
        *) die "verdict5: '$v' is not one of present|fixed|unreachable. There is no fourth branch, and 'probably fine' is not a verdict." ;;
    esac
    CHECKS=$((CHECKS+1))
    mkdir -p "$OUT"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(_ts)" "${SCRIPT_NAME:-?}" "$finding" "$v" "$evidence" \
        >> "$OUT/r5_verdicts.tsv"
}

# =================================================================================================
# common entry
# =================================================================================================
harness_begin() {
    SCRIPT_NAME="${1:?harness_begin needs a script name}"
    mkdir -p "$OUT"
    say "$SCRIPT_NAME  ($(_ts))"
    info "repo:      $REPO"
    info "artefacts: $OUT"
    info "WRITTEN, NOT RUN by its author -- this is its first execution unless a prior RUN_TAG exists"
    pattern_selftest
}
