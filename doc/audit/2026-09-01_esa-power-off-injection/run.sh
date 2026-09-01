#!/usr/bin/env bash
# ESA power-off injection round -- 2026-09-01
#
# [Co-developed with claude code -- Adam]
#
# Usage:  ./run.sh            run every arm, then the checks
#         ./run.sh <arm>...   run only those arms, then the checks
#         ./run.sh checks     run only the checks, against logs already on disk
#
# CLAIM UNDER TEST
#   When the kernel answers /ndt/set_switches_power_state with a non-2xx, Energy-Saving-App's
#   power-OFF path does not notice: the status code is discarded at
#   energy_saving_app.cpp:247, and -- unlike the power-ON side, which is gated by
#   wait_until_powered_on_switches_are_up() and its `if (!waiting_result) return;` -- nothing
#   downstream verifies that the switches actually went off.
#
# HOW THE ARMS DISCRIMINATE
#   control      stub answers 200 everywhere        -> the arm the finding is compared against
#   inject404    404 on set_switches_power_state
#   inject500    500 on set_switches_power_state    (shows it is not 404-specific)
#   injectrules  404 on the flow-entry endpoint     -> the OTHER unchecked write in the same
#                                                      function (energy_saving_app.cpp:225,241),
#                                                      the one that reroutes traffic BEFORE the
#                                                      switches go off
#   guard        200 everywhere, but the app is asked to wait for a switch the graph never
#                reports up  -> the discriminating-power control: proves this read-out CAN
#                print "the app noticed". Without it, silence in the injection arms is
#                compatible with "this driver is silent no matter what".
#
#   The finding is NOT "arm inject404 completes". The finding is "arm inject404's output is the
#   same as control's except for lines that do not say anything went wrong". So the read-out is
#   the DIFF between arms; a bare pass/fail would throw away the thing worth reporting.
#
# WHY PHASE 0 EXISTS
#   The driver recompiles the shipped translation unit rather than running the shipped binary.
#   Phase 0 measures whether that recompilation produced the same machine code for the two
#   functions under test. If it did not, every arm below is testing something other than what
#   ships, and the round is void -- so this is a gate, not a note.
#
# WHY THE INJECTION ASSERTS ITSELF
#   "The app reported no error" and "the app never sent the request" produce the same silence.
#   Phase 2 reads the stub's own request log and fails unless the requests actually arrived and
#   were actually answered with the injected status.
#   (2026-09-01: this phase earned its keep by failing -- the guard arm's expectation was
#   written as "zero POSTs to set_switches_power_state", which is wrong: the power-ON loop at
#   :201 fires BEFORE the wait, so there is one, with action=on. The assertion below now
#   distinguishes action=on from action=off, which is what the arm is actually claiming.)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ESA=/home/adam/Energy-Saving-App
SHIPPED_BIN="$ESA/energy_saving_app"
PORT=8000
STUB_PID=""

WANTED=("$@")
want_arm() {
    [[ ${#WANTED[@]} -eq 0 ]] && return 0
    [[ " ${WANTED[*]} " == *" checks "* ]] && return 1
    [[ " ${WANTED[*]} " == *" $1 "* ]]
}

RC=0
fail() { echo "  ✗ FAIL: $*"; RC=1; }
pass() { echo "  ✓ $*"; }

stop_stub() {
    if [[ -n "$STUB_PID" ]] && kill -0 "$STUB_PID" 2>/dev/null; then
        kill "$STUB_PID" 2>/dev/null
        wait "$STUB_PID" 2>/dev/null
    fi
    STUB_PID=""
}
# The stub binds a port. An interrupted run that leaves it bound makes the NEXT run's arms fail
# for a reason that has nothing to do with the claim.
trap stop_stub EXIT INT TERM

start_stub() {
    local status="$1" log="$2" target="$3"
    : > "$log"
    STUB_LOG="$log" INJECT_STATUS="$status" INJECT_TARGET="$target" \
        GRAPH_FIXTURE="$HERE/fixture_graph.json" STUB_PORT="$PORT" \
        python3 "$HERE/stub_kernel.py" 2>"${log%.jsonl}.stub.err" &
    STUB_PID=$!
    for _ in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then exec 3>&- 2>/dev/null; return 0; fi
        sleep 0.1
    done
    echo "stub failed to come up on :$PORT" >&2
    return 1
}

echo "================ Phase 0: is what we run what ships? ================"
echo "shipped binary : $(sha256sum "$SHIPPED_BIN" | cut -d' ' -f1)"
echo "               : built $(stat -c '%y' "$SHIPPED_BIN" | cut -d. -f1)"
echo "driver binary  : $(sha256sum "$HERE/driver" | cut -d' ' -f1)"

sym_asm() { # $1=binary $2=mangled symbol -> normalised instruction stream on stdout
    objdump -d --no-show-raw-insn "$1" 2>/dev/null \
      | awk -v s="$2" 'index($0,"<"s">:"){f=1;next} f&&/^$/{exit} f{print}' \
      | sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//; s/0x[0-9a-f]+/HEX/g; s/\b[0-9a-f]{4,}\b/ADDR/g'
}

for pretty in \
    "setSwitchesPowerState|_Z21setSwitchesPowerStateRKNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEERKSt6vectorIN5sflow8FlowDiffESaIS9_EE" \
    "http::set_switches_power_state|_Z24set_switches_power_statemb" \
    "http::install_modify_delete_flow_entries|_Z34install_modify_delete_flow_entriesRKSt6vectorIN5sflow8FlowDiffESaIS1_EE"
do
    name="${pretty%%|*}"; mangled="${pretty##*|}"
    sym_asm "$HERE/driver" "$mangled" > "sym.driver.$name.asm"
    sym_asm "$SHIPPED_BIN" "$mangled" > "sym.shipped.$name.asm"
    n_drv=$(wc -l < "sym.driver.$name.asm"); n_shp=$(wc -l < "sym.shipped.$name.asm")
    if [[ "$n_drv" -eq 0 || "$n_shp" -eq 0 ]]; then
        fail "$name: symbol not found (driver=$n_drv insns, shipped=$n_shp insns)"
    elif cmp -s "sym.driver.$name.asm" "sym.shipped.$name.asm"; then
        pass "$name: $n_drv instructions, identical in driver and shipped binary"
    else
        fail "$name: instruction streams DIFFER (driver=$n_drv, shipped=$n_shp) -- round is void"
    fi
done

if [[ $RC -ne 0 ]]; then
    echo; echo "Phase 0 failed: the driver is not running the shipped code. Stopping."; exit 1
fi

POWER_EP=/ndt/set_switches_power_state
RULES_EP=/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries

run_arm() {   # $1=arm  $2=status  $3=target  $4=seconds  [$5=DRIVER_POWERON_DPID]
    local arm="$1" status="$2" target="$3" secs="$4" ondpid="${5:-}"
    want_arm "$arm" || return 0
    local applog="arm_${arm}.app.log" stublog="arm_${arm}.stub.jsonl"
    echo
    echo "================ Arm $arm ($target -> ${status}) ================"
    start_stub "$status" "$stublog" "$target" || { fail "arm $arm: stub would not start"; return; }

    # cwd matters: get_graph_data() writes Graph.json into the working directory. Running from
    # here rather than from the ESA tree keeps that write out of a repo somebody else is using.
    if [[ -n "$ondpid" ]]; then
        DRIVER_POWERON_DPID="$ondpid" timeout "$secs" ./driver > "$applog" 2>&1
    else
        timeout "$secs" ./driver > "$applog" 2>&1
    fi
    echo "  driver exit: $?"

    stop_stub
}

run_arm control     200 "$POWER_EP" 120
run_arm inject404   404 "$POWER_EP" 120
run_arm inject500   500 "$POWER_EP" 120
run_arm injectrules 404 "$RULES_EP" 120
# 420 s because the shipped wait budget is 360 s.
run_arm guard       200 "$POWER_EP" 420 99

echo
echo "================ Phase 2: did the injection actually fire? ================"
python3 - <<'PY'
import json, sys
rc = 0

def load(arm):
    return [json.loads(l) for l in open(f"arm_{arm}.stub.jsonl") if l.strip()]

def power(rows, action):
    return [r for r in rows
            if r["target"].startswith("/ndt/set_switches_power_state")
            and f"action={action}" in r["target"]]

def rules(rows):
    return [r for r in rows if "install_flow_entries_modify" in r["target"]]

# arm -> (n power-off POSTs, status they were answered with)
for arm, n, status in [("control", 2, 200), ("inject404", 2, 404), ("inject500", 2, 500)]:
    got = [r["status"] for r in power(load(arm), "off")]
    if len(got) == n and all(s == status for s in got):
        print(f"  ✓ {arm}: {n} power-OFF POSTs, all answered {status}")
    else:
        print(f"  ✗ FAIL {arm}: expected {n} power-OFF POSTs answered {status}, got {got}")
        rc = 1

# injectrules: the flow-entry endpoint is the one that must have been refused, and the
# power-OFF POSTs must still have gone out afterwards -- that pairing IS the finding.
rows = load("injectrules")
r_got = [r["status"] for r in rules(rows)]
p_got = [r["status"] for r in power(rows, "off")]
if r_got and all(s == 404 for s in r_got) and len(p_got) == 2:
    print(f"  ✓ injectrules: {len(r_got)} flow-entry POSTs all answered 404, "
          f"and {len(p_got)} power-OFF POSTs still went out")
else:
    print(f"  ✗ FAIL injectrules: flow-entry statuses {r_got}, power-off statuses {p_got}")
    rc = 1

# guard: the power-ON loop (energy_saving_app.cpp:201) fires BEFORE the wait, so one POST with
# action=on is expected. The claim of this arm is that it never reached the power-OFF loop.
rows = load("guard")
on, off = power(rows, "on"), power(rows, "off")
if len(on) == 1 and len(off) == 0:
    print(f"  ✓ guard: 1 power-ON POST, 0 power-OFF POSTs "
          f"({len(rows)} requests total, so the stub was alive throughout)")
else:
    print(f"  ✗ FAIL guard: expected 1 power-ON and 0 power-OFF POSTs, got {len(on)} and {len(off)}")
    rc = 1

sys.exit(rc)
PY
[[ $? -ne 0 ]] && RC=1

echo
echo "================ Phase 3: what did the app say? ================"
for arm in control inject404 inject500 injectrules guard; do
    log="arm_${arm}.app.log"
    [[ -f "$log" ]] || { printf '  %-12s (no log)\n' "$arm"; continue; }
    printf '  %-12s lines=%-4s completion-line=%s  driver-returned=%s  error/warn/critical=%s\n' \
        "$arm" "$(wc -l < "$log")" \
        "$(grep -c 'Power On/Off Task Complete' "$log")" \
        "$(grep -c 'DRIVER-RETURN' "$log")" \
        "$(grep -cE '\[error\]|\[warning\]|\[critical\]' "$log")"
done

strip() { sed -E 's/^\[[0-9][^]]*\]//; s/\x1b\[[0-9;]*m//g' "$1"; }
for arm in inject404 inject500 injectrules; do
    [[ -f "arm_${arm}.app.log" ]] || continue
    echo
    echo "---- diff: control vs $arm (timestamps and colour stripped) ----"
    diff <(strip arm_control.app.log) <(strip "arm_${arm}.app.log") || true
done

echo
echo "================ Result ================"
if [[ $RC -eq 0 ]]; then echo "harness OK (see Phase 3 for the finding)"; else echo "harness had failures"; fi
exit $RC
