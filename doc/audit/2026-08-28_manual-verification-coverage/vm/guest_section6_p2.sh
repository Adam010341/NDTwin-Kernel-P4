#!/bin/bash
# ============================================================================================
# Installation Manual sections 6.2 - 6.6, replayed as a literal reader in ONE terminal.
#
# Runs on the machine left behind by guest_section6_p1.sh, i.e. one that has just completed
# 6.0/6.1. Same design constraint as the other guest scripts: one bash process, cwd carried,
# no cd or absolute path the page does not print, cwd logged on both sides of every step,
# `set -e` deliberately not used.
#
# SUBSTITUTION -- one, announced
#   S5  Fabric size 4 rather than 128. 6.5 offers both and ships
#       StaticNetworkTopologyP4_10Switches_4Hosts.json for exactly this; this VM has 4 vCPU,
#       where a 128-host BMv2 fabric is neither representative nor startable. The manual's
#       own instruction ("if you use it, put 4 in host_count_override") is followed.
#
# WHAT 6.6 IS FOR, AND WHY IT GETS FOUR CASES
#   f00d69f changed 6.6 to say that commenting the override out is a REFUSAL, not a fall back
#   to a default -- and that commit has never been executed. The page states four outcomes in
#   a table. Three of them are refusals and are tested here, each by running the real topology
#   script a reader would run and capturing what it actually prints.
#
#   The fourth row -- "Write /usr/local/bin/simple_switch_grpc -> Starts" -- is NOT tested
#   here, because "starts" means a fabric actually comes up, which is T-2's job on this same
#   machine. Testing only the refusals would leave the accept path unverified, which is the
#   failure mode where a guard refuses everything including what it should permit. It is
#   deferred, not skipped, and this script says so in its own output.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/s6p2.log
exec > >(tee -a "$LOG") 2>&1
step_n=0
fail_n=0

banner() { echo; echo "############ $* ############"; }
say() {
    local desc="$1"; shift
    step_n=$((step_n+1)); echo; echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"; echo "    \$ $*"
    "$@"; local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}
sayc() {
    local desc="$1"; shift
    step_n=$((step_n+1)); echo; echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"; echo "    \$ $*"
    eval "$@"; local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}

echo "=== sections 6.2-6.6 replay, started $(date -Is) ==="
echo "shell pid $$   starting cwd: $PWD"
source ~/p4setup.bash 2>/dev/null && echo "(sourced ~/p4setup.bash, as 6.1's installer instructs)"

# --------------------------------------------------------------------------------------------
banner "SECTION 6.2 -- Compile the NDTwin P4 pipeline"
say  "6.2 cd to the project root" cd "$HOME/Desktop/NDTwin-Kernel"
sayc "6.2 make the build directory" "mkdir -p p4_proxy/p4_src/build"
sayc "6.2 compile the pipeline" "p4c-bm2-ss --arch v1model \
    -o p4_proxy/p4_src/build/ndtwin_switch.json \
    --p4runtime-files p4_proxy/p4_src/build/ndtwin_switch.p4info.txt \
    p4_proxy/p4_src/ndtwin_switch.p4"

echo
echo "--- ACCEPTANCE 6.2: both outputs must EXIST and be NON-EMPTY."
echo "    'the command exited 0' is not the criterion -- an empty file would pass that."
sayc "6.2 ndtwin_switch.json is non-empty" \
     "test -s p4_proxy/p4_src/build/ndtwin_switch.json && wc -c p4_proxy/p4_src/build/ndtwin_switch.json"
sayc "6.2 ndtwin_switch.p4info.txt is non-empty" \
     "test -s p4_proxy/p4_src/build/ndtwin_switch.p4info.txt && wc -c p4_proxy/p4_src/build/ndtwin_switch.p4info.txt"
sayc "6.2 the JSON actually parses and declares tables (not just bytes on disk)" \
     "python3 -c \"import json;d=json.load(open('p4_proxy/p4_src/build/ndtwin_switch.json'));print('pipelines:',len(d.get('pipelines',[])),' tables:',sum(len(p.get('tables',[])) for p in d.get('pipelines',[])))\""

# --------------------------------------------------------------------------------------------
banner "SECTION 6.3 -- Create the P4 proxy agent's Python environment"
sayc "6.3 create the venv" "python3 -m venv p4_proxy/venv"
sayc "6.3 install requirements" "p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt"

echo
echo "--- ACCEPTANCE 6.3: the page's protobuf claim is that 3.20.3 is REQUIRED because"
echo "    p4runtime's _pb2 modules refuse to import under 4.21+. Test by importing, not by"
echo "    reading the pin: a satisfied pin that cannot import is the failure being guarded."
sayc "6.3 protobuf version actually installed" \
     "p4_proxy/venv/bin/pip show protobuf | grep -i '^version'"
sayc "6.3 p4runtime imports (this is what the pin exists to protect)" \
     "p4_proxy/venv/bin/python -c \"import p4.v1.p4runtime_pb2 as m; print('p4runtime_pb2 imported OK')\""

# --------------------------------------------------------------------------------------------
banner "SECTION 6.4 -- Point the kernel at the P4 proxy agent"
echo "The page shows two settings and says AppConfig.hpp is compile-time. 6.0's callout warns"
echo "that on the WRONG repo this file exists but lacks these settings, which reads as 'I have"
echo "the wrong version'. So check for the settings, not for the file."
sayc "6.4 P4_PROXY_IP_AND_PORT present?" \
     "grep -n 'P4_PROXY_IP_AND_PORT' setting/AppConfig.hpp"
sayc "6.4 ALLOW_MIXED_DATAPLANE present, and false as the page says?" \
     "grep -n 'ALLOW_MIXED_DATAPLANE' setting/AppConfig.hpp"

# --------------------------------------------------------------------------------------------
banner "SECTION 6.5 -- Choose the fabric size  (S5: 4 hosts, the variant the page provides)"
echo "S5 SUBSTITUTION: the page's example is 128 hosts and it also ships a 4-host model,"
echo "saying 'if you use it, put 4 in host_count_override'. This VM has 4 vCPU. Following the"
echo "page's own 4-host branch -- not inventing a size."
sayc "6.5 write the host count" "echo 4 > p4_proxy/mininet/host_count_override && cat p4_proxy/mininet/host_count_override"
sayc "6.5 the 4-host topology model the page names exists" \
     "ls -l setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"
sayc "6.5 the topology script the page names exists (page: already in the repo, you do not create it)" \
     "ls -l p4_proxy/mininet/p4_testbed_topo.py"

# --------------------------------------------------------------------------------------------
banner "SECTION 6.6 -- Check the BMv2 binary override  (f00d69f, never yet executed)"
echo "The page's table lists four outcomes. Rows 1-3 are refusals and are exercised below by"
echo "running the topology script a reader runs. Row 4 ('Starts') is deferred to T-2, where a"
echo "fabric is actually brought up -- see this script's header."
cp p4_proxy/mininet/bmv2_binary_override /tmp/override.pristine
echo "    (pristine override saved to /tmp/override.pristine and restored at the end)"

echo
echo "--- the page's OWN verification snippet, run verbatim, on the shipped file"
sayc "6.6 page snippet: which binary is selected?" \
     "p=\$(grep -vE '^[[:space:]]*(#|\$)' p4_proxy/mininet/bmv2_binary_override | head -1); \
      echo \"selected: \${p:-<none -- the fabric will refuse to start>}\"; \
      [ -x \"\$p\" ] && echo 'OK: exists and is executable' || echo 'PROBLEM: not an executable on this machine'"

run_topo () {   # run the topology script far enough to hit the override check
    sudo timeout 90 python3 p4_proxy/mininet/p4_testbed_topo.py 2>&1 | tail -6
}

echo
echo "--- ROW 1: leave the bmv2-fast path you did not build"
echo "    page predicts: bmv2 binary override names no executable: '/usr/local/bmv2-fast/...'"
step_n=$((step_n+1)); echo "--- [$step_n] 6.6 row 1 -- shipped override, fast build absent"
run_topo | sed 's/^/      /'

echo
echo "--- ROW 2: comment the line out"
echo "    page predicts: ... has no directive line (every line is blank or a #-comment)"
sed -i 's#^/usr/local/bmv2-fast#\##' p4_proxy/mininet/bmv2_binary_override
echo "      (every non-comment line now commented; grep -c of directive lines: $(grep -cvE '^[[:space:]]*(#|$)' p4_proxy/mininet/bmv2_binary_override))"
step_n=$((step_n+1)); echo "--- [$step_n] 6.6 row 2 -- commented out"
run_topo | sed 's/^/      /'

echo
echo "--- ROW 3: delete the file"
echo "    page predicts: no bmv2 binary override at ... there is no default to fall back to on purpose"
rm -f p4_proxy/mininet/bmv2_binary_override
step_n=$((step_n+1)); echo "--- [$step_n] 6.6 row 3 -- file deleted"
run_topo | sed 's/^/      /'

echo
echo "--- ROW 4: write the stock path -- the page says this STARTS."
echo "    NOT exercised here. 'Starts' means a fabric comes up, which is T-2 on this machine."
echo "    Recorded as DEFERRED so it is not mistaken for tested: a guard that refuses"
echo "    everything, including what it should permit, passes rows 1-3 perfectly."
cp /tmp/override.pristine p4_proxy/mininet/bmv2_binary_override
sayc "6.6 restore pristine, then set the stock path as the page instructs" \
     "printf '/usr/local/bin/simple_switch_grpc\n' >> p4_proxy/mininet/bmv2_binary_override; \
      sed -i 's#^/usr/local/bmv2-fast#\\##' p4_proxy/mininet/bmv2_binary_override; \
      grep -vE '^[[:space:]]*(#|\$)' p4_proxy/mininet/bmv2_binary_override"
sayc "6.6 and that path is a real executable on this machine" \
     "p=\$(grep -vE '^[[:space:]]*(#|\$)' p4_proxy/mininet/bmv2_binary_override | head -1); test -x \"\$p\" && echo \"OK: \$p\""

# --------------------------------------------------------------------------------------------
banner "RESULT (6.2-6.6)"
echo "steps run: $step_n    non-zero exits: $fail_n"
echo "NOTE: 6.6 rows 1-3 are EXPECTED to make the topology script fail. Their failures are the"
echo "      result, not a problem -- read the messages against the page's table."
echo "git status of the tracked override (page says dirty is expected, do not revert):"
git status --short p4_proxy/mininet/bmv2_binary_override 2>/dev/null | sed 's/^/  /'
echo "finished $(date -Is)"
