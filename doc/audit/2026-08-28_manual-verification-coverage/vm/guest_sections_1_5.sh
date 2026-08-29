#!/bin/bash
# ============================================================================================
# Installation Manual sections 1-5, replayed as a literal reader in ONE terminal.
#
# WHY THIS EXISTS
#   b41b9e4 rewrote 2.1 (conda init), 2.5 (Ctrl-C note), 3.3 (systemctl is-active) and 5
#   (full paths). Every section-6 test to date starts from the `v8-installed` snapshot, whose
#   sections 1-5 were performed against the OLD text. So this is the only part of the document
#   that was edited and has never been executed.
#
# THE DESIGN CONSTRAINT THAT MATTERS
#   b41b9e4 exists because a human inherits the working directory and a script does not. My
#   previous harness gave every command an absolute path or its own cd, so it structurally
#   could not see the defect two external readers found in minutes. Therefore:
#
#     * this whole file is ONE bash process -- cwd carries from step to step exactly as it
#       does for someone typing into one terminal;
#     * NO command below adds a cd, a pushd or an absolute path that the page does not print;
#     * cwd is logged before and after every step, because the working-directory chain IS the
#       thing under test, not a detail of how the test is run.
#
#   `set -e` is deliberately NOT used. Step 2.6's `cd ~/Desktop/NDTwin-Kernel` is EXPECTED to
#   fail on a fresh machine -- the repository is not cloned until 4.1, and the page says so in
#   a callout. Aborting there would hide the rest.
#
# SUBSTITUTIONS -- three, each announced in the log rather than hidden
#   S1  Miniconda install. Section 2 names it as a prerequisite ("Ensure Miniconda ... is
#       installed") and links out, but prints no commands. Supplied here; NOT a test of the
#       page, and marked so.
#   S2  `nano <file>` (2.6 and 5). An editor cannot be driven from a script. The file is
#       written instead -- FROM THE WEBSITE'S assets/snippet/ COPY, which is what the page
#       tells the reader to paste. This is the one substitution that makes the test MORE
#       faithful, not less: every previous harness read the repo copy, which is 1360 lines
#       ahead and which no reader following this page ever obtains. See SNIPPET-CANONICAL.md.
#   S3  `ryu-manager` (2.5) blocks forever, which the page now says is the success case. Run
#       in the background, checked for the loaded-app banner, then SIGINT -- the page's Ctrl-C.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/s1-5.log
exec > >(tee -a "$LOG") 2>&1
step_n=0
fail_n=0

banner() { echo; echo "############ $* ############"; }
# Run one command exactly as printed, recording cwd on both sides of it.
say() {
    local desc="$1"; shift
    step_n=$((step_n+1))
    echo
    echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"
    echo "    \$ $*"
    "$@"
    local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}
# Same, for a shell one-liner that needs the shell (pipes, redirections, globs).
sayc() {
    local desc="$1"; shift
    step_n=$((step_n+1))
    echo
    echo "--- [$step_n] $desc"
    echo "    cwd-before: $PWD"
    echo "    \$ $*"
    eval "$@"
    local rc=$?
    echo "    rc=$rc   cwd-after: $PWD"
    [ $rc -ne 0 ] && { fail_n=$((fail_n+1)); echo "    ^^ NON-ZERO"; }
    return $rc
}

echo "=== sections 1-5 replay, started $(date -Is) ==="
echo "shell pid $$ -- every step below runs in THIS process, so cwd is inherited"
echo "starting cwd: $PWD   (a fresh login lands in \$HOME, same as a reader opening a terminal)"

# --------------------------------------------------------------------------------------------
banner "SECTION 1 -- System Requirements (nothing to run; recording what the page asserts)"
sayc "OS is Ubuntu 24.04 LTS as the page requires" "grep PRETTY_NAME /etc/os-release"
sayc "x86_64 kernel"                               "uname -srm"
sayc "sudo available (the page requires root for Mininet/OVS)" "sudo -n true && echo 'passwordless sudo ok'"

# --------------------------------------------------------------------------------------------
banner "S1 SUBSTITUTION -- Miniconda (prerequisite the page names but does not provide)"
echo "The page says: 'Prerequisite: Ensure Miniconda or Anaconda is installed.' with a link and"
echo "no commands. A reader must go and do this themselves. Anything that goes wrong HERE is"
echo "not a finding about the page."
if [ ! -d "$HOME/miniconda3" ]; then
    sayc "download Miniconda" "curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/mc.sh"
    sayc "install to the default location the page's 2.1 assumes" "bash /tmp/mc.sh -b -p \$HOME/miniconda3"
else
    echo "    (already present)"
fi

# --------------------------------------------------------------------------------------------
banner "SECTION 2.1 -- Create the Ryu Conda Environment"
echo "The page offers two ways to make conda usable. A script is one shell, so option B is the"
echo "one that can be exercised inline; option A is checked separately at the end."
sayc "2.1 option B: enable conda for this shell only" "source ~/miniconda3/etc/profile.d/conda.sh"
sayc "2.1 confirm -- the page says if this prints nothing, nothing below works" "conda --version"
sayc "2.1 accept TOS (pkgs/main) -- page moved this BEFORE conda create" "conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main"
sayc "2.1 accept TOS (pkgs/r)"                                            "conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r"
sayc "2.1 create the environment" "conda create -n ryu-env python=3.8 -y"
sayc "2.1 activate"               "conda activate ryu-env"
sayc "2.1 verify -- page says this should print Python 3.8.x" "python --version"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.2 -- Install System Build Dependencies"
sayc "2.2 apt update"  "sudo apt update"
sayc "2.2 apt install" "sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential python3-dev libssl-dev libffi-dev libxml2-dev libxslt1-dev"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.3 -- Install Ryu + Compatible Python Libraries"
sayc "2.3.1 upgrade pip/setuptools/wheel" "pip install --upgrade 'pip<24' 'setuptools<68' wheel"
sayc "2.3.2 install ryu"                  "pip install ryu"
sayc "2.3.3 eventlet"                     "pip install eventlet==0.30.2"
sayc "2.3.3 greenlet"                     "pip install 'greenlet<3'"
sayc "2.3.3 dnspython"                    "pip install 'dnspython<2.3'"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.4 -- Verify Installation"
echo "The page prints four expected lines. b41b9e4's message records a REJECTED external"
echo "finding here: DeepSeek argued 'dnspython<2.3' cannot yield the 1.16.0 the page expects,"
echo "since <2.3 selects 2.2.1. It was rejected because eventlet==0.30.2 pulls 1.16.0 in first,"
echo "so the later pin reports 'already satisfied'. This run re-tests that rejection live."
sayc "2.4 verify" "pip list | grep -E 'eventlet|greenlet|dnspython|ryu'"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.5 -- Test Ryu  (S3 substitution: blocking command)"
echo "The page now says this command does not return and that IS the success case, then to"
echo "press Ctrl-C. Backgrounded, checked for the banner, then SIGINT."
ryu-manager ryu.app.simple_switch_13 > ~/ryu25.log 2>&1 &
RYU=$!
sleep 12
if kill -0 $RYU 2>/dev/null; then
    echo "    still running after 12s -- which is what the page says success looks like"
    grep -qi 'instantiating app ryu.app.simple_switch_13' ~/ryu25.log \
        && echo "    PASS: app loaded (banner found)" \
        || { echo "    FAIL: process alive but app never loaded:"; sed 's/^/      /' ~/ryu25.log; fail_n=$((fail_n+1)); }
    kill -INT $RYU 2>/dev/null; sleep 3
    kill -0 $RYU 2>/dev/null && { echo "    NOTE: survived Ctrl-C (SIGINT); page tells the reader to stop it this way"; kill -9 $RYU 2>/dev/null; }
else
    echo "    FAIL: exited on its own -- the page says it should not"; sed 's/^/      /' ~/ryu25.log; fail_n=$((fail_n+1))
fi

# --------------------------------------------------------------------------------------------
banner "SECTION 2.6 -- Prepare the Customized Ryu Controller App"
echo "The page prints 'cd ~/Desktop/NDTwin-Kernel' here, and the repository is not cloned"
echo "until 4.1. The page acknowledges this in a callout. Running it anyway -- a FAILURE HERE"
echo "IS THE EXPECTED RESULT and is what the callout is for."
say "2.6 cd to the project root (expected to fail: not cloned yet)" cd "$HOME/Desktop/NDTwin-Kernel"
echo "    -> following the page's callout: create it somewhere convenient and move it after 4.1"
mkdir -p ~/staged
cp ~/snippets/intelligent_router.py ~/staged/intelligent_router.py
echo "    S2: wrote intelligent_router.py from the WEBSITE snippet ($(wc -l < ~/staged/intelligent_router.py) lines)"
sayc "2.6.3 apply the three documented parameters" "
  sed -i \"s#^static_topology_file_path = .*#static_topology_file_path = Path(\\\"/home/\$(whoami)/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json\\\")#\" ~/staged/intelligent_router.py
  grep -nE '^(static_topology_file_path|is_mininet|switch_num)' ~/staged/intelligent_router.py"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.7 -- Install required Python libraries for the customized app"
sayc "2.7 networkx"       "pip install -U networkx"
sayc "2.7 requests/urllib3" "pip install -U 'requests<2.29' 'urllib3<2'"

# --------------------------------------------------------------------------------------------
banner "SECTION 3.1 -- Update & Install Build Tools"
sayc "3.1 apt update" "sudo apt update"
sayc "3.1 apt install (DEBIAN_FRONTEND is required per the page, not a convenience)" \
     "sudo DEBIAN_FRONTEND=noninteractive apt install -y build-essential cmake g++ make git ninja-build xterm curl wireshark iperf3"

# --------------------------------------------------------------------------------------------
banner "SECTION 3.2 -- Install Required Libraries & Mininet"
sayc "3.2 apt install" "sudo DEBIAN_FRONTEND=noninteractive apt install -y libboost-all-dev libfmt-dev libspdlog-dev libssh-dev nlohmann-json3-dev python3-venv mininet openvswitch-switch"

# --------------------------------------------------------------------------------------------
banner "SECTION 3.3 -- Verify Network Components  (rewritten by b41b9e4)"
echo "Was 'ovs-vsctl --version', which passes whether or not the daemon runs. Now two commands"
echo "that talk to the daemon, plus an instruction to read pingall's Results line BY NAME."
sayc "3.3 daemon active?" "sudo systemctl is-active openvswitch-switch"
sayc "3.3 ovs-vsctl show" "sudo ovs-vsctl show"
sayc "3.3 pingall"        "sudo mn --test pingall > ~/pingall.log 2>&1; tail -25 ~/pingall.log"
echo "    reading the Results line by name, as the page now instructs:"
grep -n '\*\*\* Results:' ~/pingall.log | sed 's/^/      /' || { echo "      NOT FOUND -- the page's named line is absent"; fail_n=$((fail_n+1)); }
echo "    (for contrast, the LAST line, which the page warns is not the answer:)"
tail -1 ~/pingall.log | sed 's/^/      /'

# --------------------------------------------------------------------------------------------
banner "SECTION 4.1 -- Download Source Code (P4 variant, per the page's 'if unsure, clone the P4 one')"
say  "4.1 cd ~/Desktop"  cd "$HOME/Desktop"
sayc "4.1 clone"         "git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4.git NDTwin-Kernel"

# --------------------------------------------------------------------------------------------
banner "SECTION 4.2 -- Compile with Ninja"
say  "4.2.1 cd project"     cd "$HOME/Desktop/NDTwin-Kernel"
sayc "4.2.2 rm -rf build"   "rm -rf build"
sayc "4.2.2 mkdir && cd"    "mkdir build && cd build"
sayc "4.2.3 cmake"          "cmake -GNinja .."
sayc "4.2.3 ninja clean"    "ninja clean"
sayc "4.2.3 ninja"          "ninja -j \$(( \$(nproc) / 2 ))"
echo
echo "    >>> cwd at the end of 4.2.3 is: $PWD"
echo "    >>> THIS is the defect b41b9e4 fixed. Without 4.2 step 4, a reader is inside build/"
echo "    >>> when section 5 says 'nano testbed_topo.py', and 6.4 later runs 'rm -rf build'."
say  "4.2.4 return to the project root (the step b41b9e4 added)" cd "$HOME/Desktop/NDTwin-Kernel"

# --------------------------------------------------------------------------------------------
banner "SECTION 2.6 (deferred half) -- move the controller in, now that the clone exists"
sayc "move intelligent_router.py to the project root" "mv ~/staged/intelligent_router.py ~/Desktop/NDTwin-Kernel/intelligent_router.py && ls -l ~/Desktop/NDTwin-Kernel/intelligent_router.py"
sayc "does the topology JSON 2.6 names actually exist in the clone?" "ls -l ~/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"
sayc "b41b9e4 claims that JSON holds exactly 138 dpid nodes -- counting" \
     "python3 -c \"import json;d=json.load(open('$HOME/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json'));import sys;n=json.dumps(d).count('dpid');print('dpid occurrences:',n)\""

# --------------------------------------------------------------------------------------------
banner "SECTION 5 -- Prepare Network Topology Script"
say  "5.1 cd project root, using the full path the page now gives" cd "$HOME/Desktop/NDTwin-Kernel"
cp ~/snippets/testbed_topo.py ./testbed_topo.py
echo "    S2: wrote testbed_topo.py from the WEBSITE snippet ($(wc -l < ./testbed_topo.py) lines)"
sayc "5 -- landed at the project root, not inside build/?" "ls -l \$HOME/Desktop/NDTwin-Kernel/testbed_topo.py && test ! -e \$HOME/Desktop/NDTwin-Kernel/build/testbed_topo.py && echo 'correct: not in build/'"
sayc "5 -- page says this script builds 10 switches and 128 hosts" "grep -nE 'HOST_NUM|s1|range' ./testbed_topo.py | head -8"

# --------------------------------------------------------------------------------------------
banner "2.1 option A -- does 'conda init bash' work for a NEW shell? (the other documented branch)"
sayc "run conda init bash" "conda init bash"
sayc "a NEW login shell can then use conda" "bash -lc 'conda --version && conda activate ryu-env && python --version'"

# --------------------------------------------------------------------------------------------
banner "RESULT"
echo "steps run: $step_n    non-zero exits: $fail_n"
echo "kernel binary present? $(ls -l ~/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel 2>/dev/null || echo 'NO')"
echo "finished $(date -Is)"
