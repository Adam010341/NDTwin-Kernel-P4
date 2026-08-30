#!/bin/bash
# =================================================================================================
# guest_ntg_journey.sh -- follow the Network Traffic Generator documentation, install page then
# usage page, inside the clean-room VM.
#
# Same two-pass shape as guest_nsr_journey.sh, and for the same reason: pass 1 runs the commands
# exactly as printed so failures are findings about the documents; pass 2 works the documented
# defects around so "the documentation is wrong" can be told apart from "the software is broken".
#
# 🔑 One correction carried over from the NSR run: a liveness gate that reports PASS when the
# subject is absent is vacuous (REC-6 there). Every gate below that asserts a stop or an absence
# first asserts that there was something present.
#
# Pages:
#   Installation Manual / NDTwin Tool / NetworkTrafficGenerator(NTG)/index.md   (4 bash blocks)
#   User Manual        / NDTwin Tools / NetworkTrafficGenerator(NTG)/index.md   (block 7 only;
#       the rest need Ryu, a fabric and a kernel, which this run does not have)
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
set -uo pipefail

OUT="${OUT:-$HOME/ntg-results}"
mkdir -p "$OUT"
RESULTS="$OUT/verdicts.tsv"; : > "$RESULTS"
LOG="$OUT/run.log"

ts()  { date -Is; }
say() { echo; echo "=== $* ==="; }
verdict() { printf '%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" >> "$RESULTS"; printf '  %-12s %-4s %s\n' "$1" "$2" "$3"; }

echo "guest_ntg_journey.sh starting $(ts)  ($(lsb_release -ds 2>/dev/null))" | tee -a "$LOG"

# =================================================================================================
say "PASS 1 -- LITERAL: Installation Manual / NDTwin Tool / NetworkTrafficGenerator(NTG)"
# =================================================================================================

# --- block 1: sudo apt update / sudo apt install -y python3 python3-pip / versions -------------
( cd "$HOME" && sudo apt update && sudo apt install -y python3 python3-pip && python3 --version && pip3 --version ) >> "$LOG" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict NTG-I1 PASS "apt block works as printed ($( python3 --version 2>&1 ), $(pip3 --version 2>&1 | cut -d' ' -f1-2))"
else
    verdict NTG-I1 FAIL "the apt block exited rc=$rc -- see $LOG"
fi

# --- block 2: pip install --upgrade pip / pip install <nine packages> --------------------------
( cd "$HOME" && pip install --upgrade pip && pip install loguru prompt_toolkit nornir nornir-utils pyyaml numpy pandas paramiko requests pydantic ) >> "$LOG" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict NTG-I2 PASS "the page's pip block worked as printed"
elif grep -q "externally-managed-environment" "$LOG"; then
    verdict NTG-I2 FAIL "pip refused: externally-managed-environment (PEP 668). Second page with this defect -- the NSR install page has it too, and neither Requirements section mentions a virtualenv."
else
    verdict NTG-I2 FAIL "pip block exited rc=$rc -- see $LOG"
fi

# --- block 3: git clone -----------------------------------------------------------------------
( cd "$HOME" && git clone https://github.com/ndtwin-lab/Network-Traffic-Generator.git ) >> "$LOG" 2>&1
rc=$?
if [[ $rc -eq 0 && -d "$HOME/Network-Traffic-Generator" ]]; then
    verdict NTG-I3 PASS "clone succeeded into \$HOME/Network-Traffic-Generator"
else
    verdict NTG-I3 FAIL "clone failed rc=$rc -- see $LOG"
fi

# --- block 4: the worker-node dependencies ----------------------------------------------------
( cd "$HOME" && pip install --upgrade pip && pip install fastapi "uvicorn[standard]" pydantic loguru orjson ) >> "$LOG" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
    verdict NTG-I4 PASS "worker-node pip block worked as printed"
else
    verdict NTG-I4 FAIL "worker-node pip block failed rc=$rc (same PEP 668 refusal as block 2 -- this page carries the defect twice)"
fi

# =================================================================================================
say "PASS 1 -- LITERAL: User Manual block 7"
# =================================================================================================
NTG="$HOME/Network-Traffic-Generator"
# The UM page says:  python network_traffic_generator.py
# Block 2 of the same page spells out ~/miniconda3/envs/ntg-env/bin/python, so the page knows the
# interpreter is special; block 7 then says a bare `python`, with no activation step printed
# between them. Run it from inside the checkout -- the friendliest reading of the page.
if [[ -d "$NTG" ]]; then
    ( cd "$NTG" && timeout 20 python network_traffic_generator.py ) >> "$LOG" 2>&1
    rc=$?
    if [[ $rc -eq 127 ]]; then
        verdict NTG-U7 FAIL "'python network_traffic_generator.py' -> rc=127, command not found. The clean guest has python3 only; python-is-python3 is not installed. Block 2 of the same page uses a full interpreter path, and no activation step is printed between them."
    elif [[ $rc -eq 0 || $rc -eq 124 ]]; then
        verdict NTG-U7 PASS "'python …' started (rc=$rc; 124 = still running at the 20 s timeout, which is what a generator should do)"
    else
        verdict NTG-U7 "N/A" "'python …' exited rc=$rc -- read $LOG before calling this a defect"
    fi
else
    verdict NTG-U7 "N/A" "no checkout; block 7 not reachable"
fi

# =================================================================================================
say "PASS 2 -- RECOVERED: venv, and the interpreter the page's own block 2 names"
# =================================================================================================
if [[ ! -d "$NTG" ]]; then
    verdict NTG-R0 FAIL "no checkout at $NTG -- pass 2 cannot run"
else
    python3 -m venv "$OUT/venv" >> "$LOG" 2>&1
    "$OUT/venv/bin/pip" install -q --upgrade pip >> "$LOG" 2>&1
    "$OUT/venv/bin/pip" install -q loguru prompt_toolkit nornir nornir-utils pyyaml numpy pandas paramiko requests pydantic >> "$LOG" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        verdict NTG-R1 PASS "all ten dependencies install cleanly into a venv -- so NTG-I2 is a documentation defect, not a broken dependency set"
    else
        verdict NTG-R1 FAIL "dependencies do NOT install even in a venv (rc=$rc) -- a real dependency problem, not just a missing virtualenv instruction"
    fi

    "$OUT/venv/bin/pip" install -q fastapi "uvicorn[standard]" pydantic loguru orjson >> "$LOG" 2>&1
    rc=$?
    [[ $rc -eq 0 ]] && verdict NTG-R2 PASS "worker-node dependencies also install cleanly in a venv" \
                    || verdict NTG-R2 FAIL "worker-node dependencies fail even in a venv (rc=$rc)"

    # Run the entry point with a real interpreter. A generator with no Ryu, no fabric and no
    # kernel should refuse and say why -- that is the NSR shape, and it is the good shape.
    ( cd "$NTG" && timeout 25 "$OUT/venv/bin/python" network_traffic_generator.py ) >> "$LOG" 2>&1
    rc=$?
    case $rc in
        124) verdict NTG-R3 "N/A" "entry point still running at 25 s -- it did not refuse, so it either waits for input or runs without its preconditions. Read $LOG." ;;
        0)   verdict NTG-R3 "N/A" "entry point exited 0 with no fabric present -- read $LOG to see whether it did anything" ;;
        *)   verdict NTG-R3 "N/A" "entry point exited rc=$rc without a fabric. Whether that is a clean refusal (good, NSR-shaped) or a crash is a question for $LOG, not for this gate." ;;
    esac
    tail -25 "$LOG" > "$OUT/entrypoint_tail.txt" 2>/dev/null

    # The page's Files Overview names files; check they are actually in the clone.
    miss=0
    for f in network_traffic_generator.py network_traffic_generator_worker_node.py NTG.yaml; do
        [[ -e "$NTG/$f" ]] || { miss=$((miss+1)); echo "  missing: $f" >> "$LOG"; }
    done
    if [[ $miss -eq 0 ]]; then
        verdict NTG-R4 PASS "the three files the page names by hand are all present in the clone"
    else
        verdict NTG-R4 FAIL "$miss of 3 files the page names are not in the clone -- see $LOG"
    fi
fi

say "SUMMARY"
awk -F'\t' '{printf "  %-12s %-4s %s\n", $2, $3, $4}' "$RESULTS"
echo
echo "  PASS=$(awk -F'\t' '$3=="PASS"' "$RESULTS" | wc -l)  FAIL=$(awk -F'\t' '$3=="FAIL"' "$RESULTS" | wc -l)  N/A=$(awk -F'\t' '$3=="N/A"' "$RESULTS" | wc -l)"
echo "  verdicts: $RESULTS    log: $LOG"
echo "guest_ntg_journey.sh done $(ts)"
