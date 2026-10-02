#!/usr/bin/env bash
#
# Tests for `ndt status --measuring`: the light read of "is anyone measuring".
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS. While a measurement runs, ndt serve's page pauses its 10 s refresh and probes
# once a minute. Until 2026-10-01 the probe was a plain `ndt status`: measured on this laptop with
# a P4 fabric up and iperf3 running, 564 tasks, 6 sudo calls and one get_graph_data request to the
# kernel under measurement, per probe (logs/ndt-serve-gui-v2/live-probe-cost/RESULTS.md). Adam
# ruled the probe must ask only "is anyone measuring": the claim's measuring= and the process
# table, with no sudo, no request to the kernel and no OVS or bmv2 query.
#
# Two things are pinned here, and each is half of the ruling:
#   1. THE SAME ANSWER. `--measuring` prints the rows plain `ndt status` prints for the question
#      -- `declared`, `measuring`, or `orphaned` -- line for line, in every fixture state below,
#      and each state's rows are also checked against what they must say (two copies that agree
#      on a wrong answer would pass the first check alone).
#   2. NOTHING HEAVY, in four layers, because a PATH denylist alone is not a pin (the round-3
#      review): ndt's own port_open is bash /dev/tcp, ndt already fetches with python3 urllib, and an
#      absolute path never looks at PATH.
#        a. every command the ruling names is a recording shim on PATH, and `--measuring` calls none
#           of them; plain `ndt status` through the same shims does (the control);
#        b. `--measuring` also runs on an ALLOWLIST-only PATH, with an exported
#           command_not_found_handle recording anything else it asks for -- python3, curl, ip, git,
#           anything; plain status on the same PATH asks for plenty (the control);
#        c. in a network namespace of its own (`unshare -rn`, or the host when that is not possible
#           and the ports are free), listeners on 127.0.0.1:8000, :8080 and :8081 count every
#           connection while `--measuring` runs: it must make none, whatever the means; a bash
#           /dev/tcp connect and a python3 urllib GET made the same way are counted (the control);
#        d. statically: the functions `--measuring` reaches from status_measuring_rows are exactly
#           the five that read a file or `ps`, and none of them names /dev/tcp, /dev/udp or runs a
#           command by absolute path.
#      A layer that cannot run (no unshare and a port taken) is a FAILED check, never a pass.
#
# The process table is a fixture: a `ps` shim answers the three listings ndt's scans read
# (in_flight: pid,comm,args; mn_count and the host count: args; bmv2_count: comm) from a file, and
# anything else goes to the real ps. The real in_flight and mn_count parse it -- only their input
# is fixed, so no iperf3 or Mininet of this machine's decides a verdict.
#
# Driven against the real script in a copy shaped like the repo (REPO resolves to the sandbox), so
# the claim file is the sandbox's and the shared .test_run is never touched.
#
# Env:  NDT_UNDER_TEST=<path>   (tests/shell/mutate_ndt_status_measuring.sh points this at a copy)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT_SRC="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

[[ -f "$NDT_SRC" ]] || { echo "  FAILED   no ndt at $NDT_SRC"; echo "Ran 1 checks, 1 failed"; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-status-measuring-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/tools/test_workflow" "$SANDBOX/.test_run" "$SANDBOX/shim"
cp "$NDT_SRC" "$SANDBOX/tools/test_workflow/ndt"
# ndt sources these from beside itself; without them it exits 2 before any subcommand
for sib in ports.sh sudo_surface.sh components.env; do
    cp "$(dirname "$NDT_SRC")/$sib" "$SANDBOX/tools/test_workflow/$sib" \
        || { echo "  FAILED   $sib is not beside $NDT_SRC"; echo "Ran 1 checks, 1 failed"; exit 1; }
done
NDT="$SANDBOX/tools/test_workflow/ndt"
CLAIM="$SANDBOX/.test_run/lab.claim"
FIXTURE="$SANDBOX/ps.fixture"
LIGHT_CALLS="$SANDBOX/light.calls"
FULL_CALLS="$SANDBOX/full.calls"
: > "$LIGHT_CALLS"; : > "$FULL_CALLS"

# --- the shims -------------------------------------------------------------------------------
REAL_PS="$(type -P ps)"; REAL_AWK="$(type -P awk)"; REAL_CUT="$(type -P cut)"; REAL_BASH="$(type -P bash)"
[[ -n "$REAL_PS" && -n "$REAL_AWK" && -n "$REAL_CUT" && -n "$REAL_BASH" ]] \
    || { echo "  FAILED   no ps, awk, cut or bash on PATH"; echo "Ran 1 checks, 1 failed"; exit 1; }
# (absolute paths inside the shim: it also runs on the allowlist-only PATH below)
cat > "$SANDBOX/shim/ps" <<EOF
#!$REAL_BASH
# the process table of the fixture, for the three listings ndt's scans read; the rest is real
if [[ -f '$FIXTURE' ]]; then
    case "\$*" in
        "-eo pid=,comm=,args=") '$REAL_AWK' -F'\t' '{ printf "%7s %s %s\n", \$1, \$2, \$3 }' '$FIXTURE'; exit 0 ;;
        "-eo args=")            '$REAL_CUT' -f3 '$FIXTURE'; exit 0 ;;
        "-eo comm=")            '$REAL_CUT' -f2 '$FIXTURE'; exit 0 ;;
    esac
fi
exec '$REAL_PS' "\$@"
EOF
# What the ruling names -- sudo, a request to the kernel, an OVS or bmv2 query -- plus the lab's own
# helpers. Each records its argv in \$CALLS_LOG and refuses: sudo in sudo's own words (ndt reads
# that as a refused grant, tests/shell/lib_probe_stub.sh), the rest with rc 1. None answers, so a
# plain `ndt status` here never sees a lab.
FORBIDDEN=(sudo curl wget nc ncat ovs-vsctl ovs-ofctl ovs-appctl ovs-dpctl simple_switch
           simple_switch_grpc simple_switch_CLI mnexec ndtwin-lab tc)
for c in "${FORBIDDEN[@]}"; do
    cat > "$SANDBOX/shim/$c" <<EOF
#!/bin/bash
printf '%s %s\n' '$c' "\$*" >> "\${CALLS_LOG:-/dev/null}"
[[ '$c' == sudo ]] && echo "sudo: a password is required" >&2
exit 1
EOF
done
chmod +x "$SANDBOX/shim"/*
SHIMMED_PATH="$SANDBOX/shim:$PATH"

# b. the allowlist: what `--measuring` needs and nothing else (found by running it on an empty
# PATH, 10-02: ndt's preamble needs dirname and readlink, the sourced files cat, the claim reader
# sed, head and date, the rows cut and wc; ps is the fixture's). Anything else it asks for lands in
# STRICT_LOG through command_not_found_handle, exported into the bash that runs ndt.
ALLOW_DIR="$SANDBOX/allow"; mkdir -p "$ALLOW_DIR"
for c in cat cut date dirname head readlink sed wc; do
    t="$(type -P "$c")" || { echo "  FAILED   no $c on PATH"; echo "Ran 1 checks, 1 failed"; exit 1; }
    ln -s "$t" "$ALLOW_DIR/$c"
done
ln -s "$SANDBOX/shim/ps" "$ALLOW_DIR/ps"
STRICT_LOG="$SANDBOX/strict.calls"; STRICT_CONTROL_LOG="$SANDBOX/strict-control.calls"
: > "$STRICT_LOG"; : > "$STRICT_CONTROL_LOG"
command_not_found_handle() { printf '%s\n' "$1" >> "${STRICT_CALLS:-/dev/null}"; return 127; }
export -f command_not_found_handle

# c. the listeners. One python3 process, run by absolute path, accepting on the three ports and
# writing "port:count ..." after every accept; started and stopped around ONE command, in a network
# namespace of its own when `unshare -rn` works (nothing else on the machine sees the ports), else
# on the host if all three ports are free, else not at all (NET_MODE none: the checks fail).
REAL_PY="$(type -P python3)"
LISTENER="$SANDBOX/listener.py"
cat > "$LISTENER" <<'EOF'
import os, select, socket, sys
out, ready = sys.argv[1], sys.argv[2]
ports = (8000, 8080, 8081)
socks, counts = [], {p: 0 for p in ports}
for p in ports:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", p))
    s.listen(16)
    socks.append(s)
def dump():
    with open(out + ".tmp", "w") as f:
        f.write(" ".join("%d:%d" % (p, counts[p]) for p in ports))
    os.replace(out + ".tmp", out)
dump()
open(ready, "w").write("ok")
while True:
    for s in select.select(socks, [], [])[0]:
        c, _ = s.accept()
        counts[s.getsockname()[1]] += 1
        c.close()
        dump()
EOF
NET_RUN="$SANDBOX/net-run.sh"
cat > "$NET_RUN" <<EOF
#!$REAL_BASH
# net-run.sh <counts file> <stdout file> <command...> -- the listeners up, the command, the listeners down
counts="\$1" out="\$2"; shift 2
if [[ "\${NET_IN_NS:-}" == 1 ]]; then ip link set lo up || exit 97; fi
rm -f "\$counts" "\$counts.ready"
'$REAL_PY' '$LISTENER' "\$counts" "\$counts.ready" 2>/dev/null &
lp=\$!
for i in \$(seq 1 100); do [[ -f "\$counts.ready" ]] && break; sleep 0.05; done
[[ -f "\$counts.ready" ]] || { kill \$lp 2>/dev/null; exit 98; }
"\$@" > "\$out" 2>/dev/null
sleep 0.2
kill \$lp 2>/dev/null; wait \$lp 2>/dev/null
exit 0
EOF
chmod +x "$NET_RUN"
NET_MODE=none
if command -v unshare >/dev/null && command -v ip >/dev/null \
        && NET_IN_NS=1 unshare -rn "$REAL_BASH" -c 'ip link set lo up' 2>/dev/null; then
    NET_MODE=netns
elif "$REAL_PY" -c '
import socket
for p in (8000, 8080, 8081):
    s = socket.socket(); s.bind(("127.0.0.1", p)); s.close()' 2>/dev/null; then
    NET_MODE=host
fi
net() {   # <counts file> <stdout file> <command...>
    case "$NET_MODE" in
        netns) NET_IN_NS=1 unshare -rn "$NET_RUN" "$@" ;;
        host)  "$NET_RUN" "$@" ;;
        *)     echo "8000:? 8080:? 8081:?" > "$1"; return 99 ;;
    esac
}
NET_COUNTS_ALL=""

export NDT_OWNER=fixture-me
light_strict() { (cd "$SANDBOX" && STRICT_CALLS="$STRICT_LOG" PATH="$ALLOW_DIR" NO_COLOR=1 "$REAL_BASH" "$NDT" status --measuring 2>/dev/null); }
light_net() {   # <counts file> -- the light call, through the listeners
    (cd "$SANDBOX" && net "$1" "$SANDBOX/net.out" env CALLS_LOG="$LIGHT_CALLS" PATH="$SHIMMED_PATH" NO_COLOR=1 \
        "$REAL_BASH" "$NDT" status --measuring) && cat "$SANDBOX/net.out"
}
light() { (cd "$SANDBOX" && CALLS_LOG="$LIGHT_CALLS" PATH="$SHIMMED_PATH" NO_COLOR=1 bash "$NDT" status --measuring 2>/dev/null); }
full()  { (cd "$SANDBOX" && CALLS_LOG="$FULL_CALLS" PATH="$SHIMMED_PATH" NO_COLOR=1 bash "$NDT" status 2>/dev/null); }

# The value of a row as ndt serve reads it (serve.py MEASURING_LINE / DECLARED_LINE): the first
# `  <name>  <value>` line, trailing blanks dropped; "-" when there is no such row.
row() {   # <name> <text>
    local v
    v="$(printf '%s\n' "$2" | sed -n "s/^  $1  *//p" | head -1 | sed 's/[[:space:]]*$//')"
    printf '%s' "${v:--}"
}

# --- the fixture states ----------------------------------------------------------------------
no_claim() { rm -f "$CLAIM"; }
claim() {   # <owner> <expires epoch> <measuring=>
    printf 'owner=%s\nexpires=%s\nnote=fixture note\nexclusive_cpu=no\nmeasuring=%s\n' "$1" "$2" "$3" > "$CLAIM"
}
LIVE="$(( $(date +%s) + 3600 ))"
IPERF=$'4242\tiperf3\tiperf3 -c 10.0.0.2 -p 5201 -t 480 -i 30'
MEASURE_SH=$'4243\tbash\tbash tools/test_workflow/measure.sh cell-3'
FABRIC=$'4300\tbash\tbash --norc -is mininet:h1'
OTHER=$'4400\tbash\tbash -c sleep 600'
procs() { if (( $# )); then printf '%s\n' "$@" > "$FIXTURE"; else : > "$FIXTURE"; fi; }

# state <label> <declared row> <measuring row> <orphaned row> -- runs both and compares
state() {
    local label="$1" want_decl="$2" want_meas="$3" want_orph="$4" L F rc bad
    L="$(light)"; rc=$?
    F="$(full)"
    check "$label: --measuring answers rc 0" "0" "$rc"
    # 1. the same answer: a block plain status prints, line for line, and the same rows
    if [[ -n "$L" && $'\n'"$F"$'\n' == *$'\n'"$L"$'\n'* ]]; then
        check "$label: --measuring's rows are plain status's, line for line" "yes" "yes"
    else
        check "$label: --measuring's rows are plain status's, line for line" "$L" "(not a block of plain status: $F)"
    fi
    check "$label: the same declared row as plain status"  "$(row declared "$F")"  "$(row declared "$L")"
    check "$label: the same measuring row as plain status" "$(row measuring "$F")" "$(row measuring "$L")"
    check "$label: the same orphaned row as plain status"  "$(row orphaned "$F")"  "$(row orphaned "$L")"
    # ... and what they must say
    check "$label: the declared row"  "$want_decl" "$(row declared "$L")"
    check "$label: the measuring row" "$want_meas" "$(row measuring "$L")"
    check "$label: the orphaned row"  "$want_orph" "$(row orphaned "$L")"
    # 2. the measuring rows and nothing else (17 blanks: a row's continuation, printf "  %-14s %s" with an empty name)
    bad="$(printf '%s\n' "$L" | grep -vE '^  (declared|measuring|orphaned) |^ {17}[^ ]' || true)"
    check "$label: --measuring prints the measuring rows and nothing else" "" "$bad"
    # 3. the same answer on the allowlist-only PATH, and through the listeners
    check "$label: the allowlist-only PATH gives the same rows" "$L" "$(light_strict)"
    check "$label: the run through the listeners gives the same rows" "$L" "$(light_net "$SANDBOX/net.counts")"
    NET_COUNTS_ALL+="$(cat "$SANDBOX/net.counts" 2>/dev/null || echo '?')|"
    LAST_LIGHT="$L"; LAST_FULL="$F"
}

DECL_TAIL="   (claim measuring=; 'ndt check' refuses while set)"
IPERF_ROW="iperf3 -c 10.0.0.2 -p 5201 -t 480 -i 30"

echo "ndt status --measuring: the same answer as plain status"

no_claim; procs "$OTHER"
state "nothing" "-" "nothing" "-"

claim fixture-me "$LIVE" "matrix cell 3/8"; procs "$OTHER"
state "declared only" "matrix cell 3/8$DECL_TAIL" "nothing" "-"

no_claim; procs "$OTHER" "$IPERF" "$FABRIC"
state "in_flight only" "-" "$IPERF_ROW" "-"

claim fixture-me "$LIVE" "matrix cell 3/8"; procs "$IPERF" "$FABRIC"
state "declared and in_flight" "matrix cell 3/8$DECL_TAIL" "$IPERF_ROW" "-"

# an expired claim declares nothing, as it holds nothing (measuring_declared)
claim fixture-me 1 "a declaration past its lease"; procs "$OTHER"
state "expired claim" "-" "nothing" "-"

# somebody else's live claim: what it declares is declared all the same
claim someone-else "$LIVE" "their sampling matrix"; procs "$IPERF" "$FABRIC"
state "somebody else's claim" "their sampling matrix$DECL_TAIL" "$IPERF_ROW" "-"

# a driver with no fabric is a leftover, not a measurement: no measuring row at all
no_claim; procs "$IPERF"
state "orphaned (no fabric)" "-" "-" "$IPERF_ROW"
check "orphaned (no fabric): says they are leftovers" "yes" \
      "$(grep -q 'no fabric is running, so these are leftovers' <<<"$LAST_LIGHT" && echo yes || echo no)"

no_claim; procs "$IPERF" "$MEASURE_SH" "$FABRIC"
state "two drivers" "-" "$IPERF_ROW" "-"
check "two drivers: the '+ 1 more' row, as plain status prints it" "yes" \
      "$(grep -q '^ \{17\}+ 1 more process(es)$' <<<"$LAST_LIGHT" && echo yes || echo no)"

echo
echo "ndt status --measuring: no sudo, no kernel request, no OVS or bmv2 query"
check "🔴 --measuring ran no sudo, curl, OVS or bmv2 command (8 states)" "" "$(sort -u "$LIGHT_CALLS")"
# the control: the same shims, the same states, plain status -- they are on PATH and recording
check "  control: plain status, through the same shims, calls sudo" "yes" \
      "$(grep -q '^sudo ' "$FULL_CALLS" && echo yes || echo no)"
check "  control: the process table both read is the fixture" "$IPERF_ROW" "$(row measuring "$LAST_FULL")"

echo
echo "ndt status --measuring: nothing outside its allowlist, no connection, no absolute path"
check "🔴 --measuring ran nothing outside its allowlist on PATH (8 states)" "" "$(sort -u "$STRICT_LOG" | tr '\n' ' ')"
# the control: plain status on the same PATH asks for commands the allowlist does not have
(cd "$SANDBOX" && STRICT_CALLS="$STRICT_CONTROL_LOG" PATH="$ALLOW_DIR" NO_COLOR=1 timeout 60 "$REAL_BASH" "$NDT" status >/dev/null 2>&1)
check "  control: plain status on the same PATH is recorded asking for more" "yes" \
      "$([[ -s "$STRICT_CONTROL_LOG" ]] && echo yes || echo no)"

check "the listeners ran (in a namespace of their own, or on free host ports)" "yes" \
      "$([[ "$NET_MODE" != none ]] && echo yes || echo "no: no unshare -rn and a port of 8000/8080/8081 is taken -- NOT CHECKED")"
want_net="$(printf '8000:0 8080:0 8081:0|%.0s' 1 2 3 4 5 6 7 8)"
check "🔴 --measuring opened no TCP connection to the lab's ports (8 states, $NET_MODE)" "$want_net" "$NET_COUNTS_ALL"
# the control: the two idioms ndt itself has, run the same way, are counted
net "$SANDBOX/ctl.counts" "$SANDBOX/ctl.out" "$REAL_BASH" -c \
    '(exec 3<>/dev/tcp/127.0.0.1/8000) 2>/dev/null; '"'$REAL_PY'"' -c "import urllib.request
try: urllib.request.urlopen(\"http://127.0.0.1:8081/\", timeout=2)
except Exception: pass"'
check "  control: a bash /dev/tcp connect and a python3 urllib GET are counted" "8000:1 8080:0 8081:1" \
      "$(cat "$SANDBOX/ctl.counts" 2>/dev/null)"

# d. statically, from ndt itself: the functions --measuring reaches, and what they contain
CLOSURE_DIR="$SANDBOX/closure"; mkdir -p "$CLOSURE_DIR"
closure="$("$REAL_BASH" -c '
    source "$1" >/dev/null 2>&1 || true
    declare -F | awk "{print \$3}" | sort > "$2/all"
    todo=(status_measuring_rows); seen=" "
    while (( ${#todo[@]} )); do
        f=${todo[0]}; todo=("${todo[@]:1}")
        [[ "$seen" == *" $f "* ]] && continue
        seen+="$f "
        declare -f "$f" > "$2/fn.$f"
        for w in $(tail -n +2 "$2/fn.$f" | grep -oE "[A-Za-z_][A-Za-z0-9_]*" | sort -u); do
            grep -qx "$w" "$2/all" && todo+=("$w")
        done
    done
    printf "%s\n" $seen | sort | tr "\n" " "' _ "$NDT" "$CLOSURE_DIR")"
check "🔴 --measuring reaches only the five functions that read a file or ps" \
      "claim_field in_flight measuring_declared mn_count status_measuring_rows " "$closure"
# a word in command position that starts with "/" (declare -f puts each command on its line), or
# /dev/tcp and /dev/udp anywhere
abs="$("$REAL_PY" - "$CLOSURE_DIR" <<'EOF'
import glob, re, sys
bad = []
sep = re.compile(r"\$\(|<\(|>\(|`|&&|\|\||[;|&]")
skip = {"if", "then", "else", "elif", "do", "while", "until", "for", "case", "!", "{", "}", "(", "((", "time",
        "exec", "command", "builtin", "env", "nohup", "timeout"}
for p in sorted(glob.glob(sys.argv[1] + "/fn.*")):
    fn = p.rsplit("fn.", 1)[1]
    for n, line in enumerate(open(p), 1):
        if re.search(r"/dev/(tcp|udp)/", line):
            bad.append("%s:%d /dev/tcp|udp: %s" % (fn, n, line.strip()))
        for part in sep.split(line):
            words = part.split()
            while words and (words[0] in skip or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
                words = words[1:]
            if words and words[0].startswith("/"):
                bad.append("%s:%d absolute path: %s" % (fn, n, line.strip()))
print("; ".join(sorted(set(bad))))
EOF
)"
check "🔴 no absolute-path command and no /dev/tcp on --measuring's path" "" "$abs"

echo
echo "ndt help"
HELP="$(bash "$NDT" help 2>&1)"
check "ndt help names status --measuring" "yes" \
      "$(grep -qF 'status [--check | --measuring]' <<<"$HELP" && echo yes || echo no)"
check "  and says what it reads and what it does not" "yes" \
      "$(tr -s ' \n' ' ' <<<"$HELP" | grep -qF 'It reads the claim file and the process table and nothing else: no sudo, no kernel request, no OVS or bmv2 query.' && echo yes || echo no)"

echo
echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
(( FAIL == 0 ))
