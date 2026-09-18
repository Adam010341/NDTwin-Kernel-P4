#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_app_package.sh -- the offline drive of
# `ndt up p4 --app <dir>` and the app-package knob's life.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THREE DIRECTIONS, and this gate needs all three.
#   * FIRES: the feature stops doing its job. M1 accepts a package the pre-flight failed; M3
#     and M4 stop clearing the knob, which is how a baseline round silently builds somebody
#     else's exercise; M6 leaves SWITCHES at 10 under a four-switch package; M7 puts the
#     `h1 10.0.0.2` literal back; M8 makes an external package's empty fabric report a routing
#     failure; M10 lets a package and NDT_TOPO name two different models.
#   * WIDENS: M9 makes a rolled-back bring-up delete a knob it never wrote -- every "the knob
#     is gone" cell passes and another session's state is destroyed by a command that failed.
#     M2 removes the exemption a package needs and refuses three-host fabrics.
#   * THE INSTRUMENT: M5 takes away the one `sudo` call a proceeding bring-up makes. Nothing in
#     the refusal half notices -- `sudo=0 stack=0` is what those want -- so what catches it is
#     the positive reading on the proceeding path, which is there precisely so "nothing was
#     touched" cannot be a sentence this harness always says.
#
# 🔴 A mutation that will not apply, a non-unique anchor, a mutant that does not PARSE, or the
# WRONG check going red counts as SURVIVOR -- never as skipped. A control that goes red makes
# the whole round void: a harness that reports red for any edit says nothing when it reports
# red for a mutation.
#
# 🔴 `bash -n` ON EVERY MUTANT, before it is run. `ndt` is sourced by the suite with its output
# discarded, so a mutant with a syntax error defines no functions at all and EVERY cell goes
# red -- which looks exactly like a mutation the suite caught, and would let a badly written
# anchor be scored as evidence. The compile-fail rule the mutation-gate convention already
# carries for the python gates, applied to the one language this gate mutates.
#
# Bare, not wrapped: nothing here compiles anything. tools/test_workflow/ndt is never written
# -- mutants are whole copies in a temp dir, reached through NDT_UNDER_TEST -- and the sha256
# line at the end says so.
#
# Run:  bash tests/shell/mutate_ndt_app_package.sh
# Exit: 0 every mutation caught and the controls survived; 1 a mutation survived or a control
#       went red; 2 refused (baseline red, or the harness could not set up); 3 ndt changed
#       under it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
TEST="$HERE/test_ndt_app_package.sh"
[[ -r "$NDT" && -r "$TEST" ]] || { echo "refused: ndt or test missing"; exit 2; }

BK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-app-pkg-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
A="$BK/anchors"; mkdir -p "$A"
BASE_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"

# mutant <name> -- a copy of ndt with A/<name>.old replaced by A/<name>.new. The anchors travel
# as FILES so that a shell word never has to survive two levels of quoting; the applier refuses
# a non-unique anchor, which is how check_gate_anchors.py's DUP verdict is enforced at run time.
#
# 🔴 ndt sources ports.sh and sudo_surface.sh from BESIDE ITSELF, so a copy without them exits
# at source time -- silently, because the suite sources it with output discarded -- and every
# case then goes red for a reason that has nothing to do with the mutation.
mutant() {
    local name="$1" d="$BK/$name"
    mkdir -p "$d"
    cp "$NDT" "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" "$d/"
    [[ -r "$REPO/tools/test_workflow/components.env" ]] &&
        cp "$REPO/tools/test_workflow/components.env" "$d/"
    python3 - "$d/ndt" "$A/$name.old" "$A/$name.new" <<'PY'
import sys, io
target, oldf, newf = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(target, encoding='utf-8').read()
o = io.open(oldf, encoding='utf-8').read()
n = io.open(newf, encoding='utf-8').read()
c = s.count(o)
if c != 1:
    print("ANCHOR:%d" % c); sys.exit(0)
io.open(target, 'w', encoding='utf-8').write(s.replace(o, n, 1))
print(target)
PY
}

run_test() { NDT_UNDER_TEST="$1" timeout 600 bash "$TEST" 2>&1; }

echo "baseline (must be green before any mutation):"
BASE_OUT="$(run_test "$NDT")"; BASE_RC=$?
BASE_RAN="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$BASE_OUT" | tail -1)"
tail -1 <<<"$BASE_OUT" | sed 's/^/  /'
[[ $BASE_RC -eq 0 ]] || { echo "refused: baseline is not green -- mutations would prove nothing"; exit 2; }
echo

CAUGHT=0; SURVIVED=0; CONTROLS=0; CONTROLS_RED=0

check_fires() {   # <label> <name> <check text that MUST go red> [<more check texts>...]
    #
    # 🔴 MORE THAN ONE `want` WHERE ONE WOULD NOT DO. M19, M20 and M23 each break a rule that
    # is asserted twice: once on the function that decides it (section 14) and once on the
    # whole `cmd_status --check` report (section 15). A mutation that reddened only the unit
    # cell would leave "and cmd_status actually calls it" untested, and the two halves of the
    # package-pipeline rule cover for each other -- with the row's early return gone the rate
    # comes back, with the predicate's exemption gone the PROBLEM comes back under a row that
    # still says n/a. Both named, both required.
    local label="$1" name="$2"; shift 2
    local wants=("$@") want missing=() d out rc ran
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  SURVIVED %-56s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  SURVIVED %-56s (the mutant does not PARSE -- a bash -n failure is not a catch)\n' "$label"
        SURVIVED=$((SURVIVED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    # 🔴 "the named check went red" is not enough by itself: a mutation that made the suite
    # ABORT after that check would look identical. The trailing count is the only evidence the
    # run reached the end, and it must match the baseline or the mutation removed checks
    # instead of failing them.
    ran="$(/usr/bin/grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        printf '  SURVIVED %-56s (the run did not finish: "%s" vs baseline "%s")\n' "$label" "$ran" "$BASE_RAN"
        SURVIVED=$((SURVIVED+1)); return
    fi
    if [[ $rc -eq 0 ]]; then
        printf '  SURVIVED %-56s (suite still green)\n' "$label"; SURVIVED=$((SURVIVED+1)); return
    fi
    for want in "${wants[@]}"; do
        /usr/bin/grep -qF "FAILED   $want" <<<"$out" || missing+=("$want")
    done
    if (( ${#missing[@]} == 0 )); then
        printf '  caught   %-56s (%d named check(s) went red)\n' "$label" "${#wants[@]}"
        printf '             red: %s\n' "${wants[@]}"
        # Every OTHER cell this mutation reddened, so "which test kills which mutation" can be
        # rebuilt from the log rather than from memory -- mutate_drive_exercise.sh's own line,
        # for the same reason (P2-C SUMMARY §8.2-5).
        /usr/bin/grep '^  FAILED' <<<"$out" | sed 's/^  FAILED   /             also red: /'
        CAUGHT=$((CAUGHT+1))
    else
        printf '  SURVIVED %-56s (red, but NOT on every named check)\n' "$label"
        printf '             still green: %s\n' "${missing[@]}"
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        SURVIVED=$((SURVIVED+1))
    fi
}

check_control() {   # <label> <name> -- a behaviour-preserving edit; the suite must stay GREEN
    local label="$1" name="$2" d out rc
    CONTROLS=$((CONTROLS+1))
    d="$(mutant "$name")"
    if [[ "$d" == ANCHOR:* ]]; then
        printf '  🔴 CONTROL %-53s (anchor occurrences: %s, expected 1)\n' "$label" "${d#ANCHOR:}"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    if ! bash -n "$d" 2>/dev/null; then
        printf '  🔴 CONTROL %-53s (the control does not PARSE -- it is not behaviour-preserving)\n' "$label"
        CONTROLS_RED=$((CONTROLS_RED+1)); return
    fi
    out="$(run_test "$d")"; rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '  control  %-56s (stayed green, as it must)\n' "$label"
    else
        printf '  🔴 CONTROL %-53s (went RED -- this harness reddens for any edit)\n' "$label"
        /usr/bin/grep 'FAILED' <<<"$out" | head -3 | sed 's/^/             /'
        CONTROLS_RED=$((CONTROLS_RED+1))
    fi
}

# --- M1: a package the pre-flight failed is built anyway ----------------------------------
# The whole point of running somebody else's package through preflight.py is that a red row
# means nothing is built. This is that guard turned off, and its cost is the knob: the file
# that points the next proxy at a package now points it at one that does not parse.
cat > "$A/m1.old" <<'EOF'
        if ! app_preflight "$app_dir"; then
EOF
cat > "$A/m1.new" <<'EOF'
        if app_preflight "$app_dir"; false; then
EOF
check_fires "M1: a FAILED pre-flight is built anyway" m1 "🔴 the knob was NOT written"

# --- M2 (widening): the layout rule a package replaces is applied to it -------------------
# host_count_buildable is a statement about ntg_bmv2_topo.py's four-way splitter. Applied to a
# package, it refuses exercises/p4runtime -- three hosts on three switches -- for violating a
# layout rule that fabric does not use. Every four-host cell in the suite stays green.
cat > "$A/m2.old" <<'EOF'
    [[ "$layout" == package ]] || host_count_buildable "$n" || return 1
EOF
cat > "$A/m2.new" <<'EOF'
    host_count_buildable "$n" || return 1
EOF
check_fires "M2 (widening): the splitter rule is applied to packages" m2 \
            "🔴 a three-host package is built, not refused"

# --- M3: `ndt up` without --app stops clearing the knob -----------------------------------
# The quiet half of the feature. A knob left over from an earlier `--app` run is read by the
# proxy and by p4_testbed_topo.py, so `ndt up p4 4` would build the exercise fabric under a
# banner that says baseline -- and every topology view would read correct.
cat > "$A/m3.old" <<'EOF'
        app_knob_clear "this 'ndt up' asked for the baseline fabric" || return 1
EOF
cat > "$A/m3.new" <<'EOF'
        :
EOF
check_fires "M3: a baseline 'ndt up p4' keeps somebody's package" m3 \
            "🔴 'ndt up p4 4' with no --app clears it"

# --- M4: the teardown side stops clearing it ------------------------------------------------
# 🔴 THIS MUTATION FOUND A REAL DEFECT AND THE FIX IS IN `ndt`, NOT HERE. The first draft
# cleared the knob in BOTH cmd_down (before the teardown) and cmd_clean (`verify clean`, its
# last step). M4 deleted cmd_down's call and the whole suite stayed green -- cmd_clean was
# doing the same job, and there is no path between the teardown starting and that call that
# returns early. Two guards over one fact, where deleting either is invisible: P1-A's M19 in
# startup(), the same week. cmd_down's call is gone; this mutation now points at the one that
# remains, and it takes BOTH verbs' cells down with it, which is the evidence that one call is
# what serves both.
cat > "$A/m4.old" <<'EOF'
    app_knob_clear "this checkout is being put back" || rc=1
EOF
cat > "$A/m4.new" <<'EOF'
    :
EOF
check_fires "M4: the teardown side leaves the knob behind" m4 "🔴 'ndt down' clears it"

# --- M5: the instrument ---------------------------------------------------------------------
# 🔴 INVISIBLE TO EVERY REFUSAL CELL. It takes away the one `sudo -n $LAB topo-start` a
# proceeding bring-up makes, and a refusal wants `sudo=0`. It exists to prove touched() reads
# the machine rather than printing a constant -- which is what would make every
# `sudo=0 stack=0` cell pass over a guard somebody had deleted.
cat > "$A/m5.old" <<'EOF'
        tsout="$(sudo -n "$LAB" topo-start 2>&1)"; tsrc=$?
EOF
cat > "$A/m5.new" <<'EOF'
        tsout=""; tsrc=0
EOF
check_fires "M5: the bring-up stops calling sudo (the instrument)" m5 \
            "🔴 and the machine WAS reached -- the instrument can read non-zero"

# --- M6: SWITCHES stays at the literal 10 under a package ---------------------------------
# Every topology in setting/ has ten switches, which is why 10 could be a constant.
# exercises/basic's pod-topo has four: with this line gone, `[1/3]` waits 180 s for six
# switches that are never coming and then calls the fabric dead.
cat > "$A/m6.old" <<'EOF'
        SWITCHES="$app_sw"
EOF
cat > "$A/m6.new" <<'EOF'
        :
EOF
check_fires "M6: the switch count stays at the literal 10" m6 \
            "  the switch count came from the model too"

# --- M7: the `h1 10.0.0.2` literal, put back ----------------------------------------------
# It is true of the two baseline models and of nothing else. Under exercises/basic it names an
# address no host in that fabric holds, and the ping fails for that reason under a message
# claiming the fabric is up but not forwarding -- a specific claim about routing, manufactured
# from a wrong destination. Exactly the shape verify_dataplane's own header warns about.
cat > "$A/m7.old" <<'EOF'
        verify_dataplane "$src" "$dst" \
EOF
cat > "$A/m7.new" <<'EOF'
        verify_dataplane h1 10.0.0.2 \
EOF
check_fires "M7: the hardcoded ping pair comes back" m7 \
            "ndtwin mode pings the pair the model names"

# --- M8: an external control plane's empty fabric is reported as a fault -------------------
# `mode: external` means the proxy installs no routes: 0 destination paths and no forwarding
# are the DESIGN, not readings. Reporting them as failures makes every p4runtime bring-up end
# `up, but not verified`, and the operator's next move is to debug a fabric that is correct.
cat > "$A/m8.old" <<'EOF'
    if [[ "$mode" == external ]]; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
cat > "$A/m8.new" <<'EOF'
    if false; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
check_fires "M8: external mode is judged by NDTwin's own routes" m8 \
            "🔴 and NAMES the path count as not checked"

# --- M9 (widening): a rollback deletes a knob it never wrote -------------------------------
# Every "the knob is gone" cell passes, and a bring-up that failed has destroyed a file that
# belongs to whatever is still running. APP_KNOB_WRITTEN is the whole difference, and only the
# control cell for it can see this.
cat > "$A/m9.old" <<'EOF'
    if [[ -n "$APP_KNOB_WRITTEN" ]]; then
        app_knob_clear "this bring-up was rolled back" || rc=1
    fi
EOF
cat > "$A/m9.new" <<'EOF'
    app_knob_clear "this bring-up was rolled back" || rc=1
EOF
check_fires "M9 (widening): rollback clears any knob it finds" m9 \
            "🔴 but NOT one this run did not write"

# --- M10: a package and NDT_TOPO may name two different models -----------------------------
# One of them builds the fabric, the other is handed to the kernel, and every topology view
# reads correct either way. That is the 2026-08-21 defect; this is the check for it removed.
cat > "$A/m10.old" <<'EOF'
            if [[ "$(readlink -f "$cur" 2>/dev/null)" != "$(readlink -f "$app_model" 2>/dev/null)" ]]; then
EOF
cat > "$A/m10.new" <<'EOF'
            if false; then
EOF
check_fires "M10: NDT_TOPO may disagree with the package" m10 \
            "🔴 NDT_TOPO naming another model is refused"

# --- M11: `status --check` stops going red on a knob whose package is gone -----------------
# The row still prints. Only the problem list -- the thing `--check` exits on, and the thing an
# end-of-round script reads -- goes quiet, which is the "red text with a green exit code" shape
# Adam ruled against when E-9 was decided.
cat > "$A/m11.old" <<'EOF'
        STATUS_APP_PROBLEMS+=("the app package knob ($rel) names $state, which does not exist -- the next 'ndt up p4' cannot start its proxy")
EOF
cat > "$A/m11.new" <<'EOF'
        :
EOF
check_fires "M11: a missing package directory is no longer a problem" m11 \
            "  and --check has a problem to exit 1 on"

# --- M12: the OVS plane stops clearing the knob ----------------------------------------------
# The quiet half of M3, on the plane where a stale knob is least likely to be noticed: nothing
# on an OVS fabric reads it, so it survives the whole round and decides the NEXT `ndt up p4`.
# up_ovs's own rollback cannot cover for this -- APP_KNOB_WRITTEN is empty on this plane.
cat > "$A/m12.old" <<'EOF'
    app_knob_clear "this 'ndt up ovs' does not use one" || { rm -f "$fifo" "$out"; return 1; }
EOF
cat > "$A/m12.new" <<'EOF'
    :
EOF
check_fires "M12: 'ndt up ovs 4' keeps somebody's package" m12 \
            "🔴 'ndt up ovs 4' clears it as well"

# --- M13: --app with an empty value falls through to the baseline -----------------------------
# `--app=` and `--app ""` both leave NDT_APP_DIR empty. Read as "no package", the command builds
# the BASELINE fabric and CLEARS the knob -- under an argv that says --app. A flag given with no
# value is a typo, not a request for the default.
cat > "$A/m13.old" <<'EOF'
    if (( seen )) && [[ -z "$NDT_APP_DIR" ]]; then
EOF
cat > "$A/m13.new" <<'EOF'
    if false; then
EOF
check_fires "M13: an empty --app value silently means baseline" m13 \
            "🔴 --app= with an empty value is a usage error"

# --- M14: a proxy that will not start says nothing about why ----------------------------------
# P1-A §4-11 makes proxy_agent/main.py raise AT IMPORT when a package will not load, and
# stack.sh can then only report `proxy did not open :8081`, which under a package is true of
# every possible cause. This puts the silence back.
cat > "$A/m14.old" <<'EOF'
        proxy_log_tail 10
EOF
cat > "$A/m14.new" <<'EOF'
        :
EOF
check_fires "M14: the proxy's own last words are not printed" m14 \
            "🔴 the PROXY's own last words are printed"

# --- M15: a fabric that never came up says nothing about why (TICKET-P1D) ---------------------
# The 2026-09-18 live round: `0/4 switches, manifest missing`, `look at the pane` -- and no
# pane, because the bridge had already exited and tmux reaps the session with the process. This
# puts that silence back.
# 🔴 The anchor carries the line BELOW it, and that is not decoration: `topo_log_tail 30` now
# appears twice in `ndt` (this branch and the topo-start-failed one, M17), so the bare call is
# no longer unique and the mutation would land in whichever copy came first.
# tests/shell/check_gate_anchors.py is what said so -- `count : 2 (want 1)` -- which is the
# whole reason that instrument exists.
cat > "$A/m15.old" <<'EOF'
            topo_log_tail 30
            rollback_up "the fabric never came up, and a half-built one holds :3005x/:909x"
EOF
cat > "$A/m15.new" <<'EOF'
            :
            rollback_up "the fabric never came up, and a half-built one holds :3005x/:909x"
EOF
check_fires "M15: the bridge's own last words are not printed" m15 \
            "🔴 the BRIDGE's own last words are printed"

# --- M16: they are printed, but underneath the rollback ---------------------------------------
# 🔴 A DIFFERENT DEFECT FROM M15 AND THE ONE THAT SURVIVES REVIEW. rollback_up runs `ndtwin-lab
# cleanup` and prints a screen of its own; a cause underneath that is a cause nobody reads, and
# "the tail is printed" would be satisfied either way.
cat > "$A/m16.old" <<'EOF'
            topo_log_tail 30
            rollback_up "the fabric never came up, and a half-built one holds :3005x/:909x"
EOF
cat > "$A/m16.new" <<'EOF'
            rollback_up "the fabric never came up, and a half-built one holds :3005x/:909x"
            topo_log_tail 30
EOF
check_fires "M16: the cause is printed underneath the rollback" m16 \
            "🔴 the cause is printed ABOVE the rollback"

# --- M17: the OTHER way the fabric step fails says nothing ------------------------------------
# `ndtwin-lab topo-start` can refuse on its own (a topo session already up, an untrusted config).
# The bridge may then never have run -- which is exactly why the tail is LABELLED as possibly the
# previous round's rather than dropped: the other likely cause is a bridge that died before tmux
# could report it, and for that one this is the only record there is.
cat > "$A/m17.old" <<'EOF'
            err "topo.log may be the PREVIOUS round's -- the bridge may not have started:"
            topo_log_tail 30
EOF
cat > "$A/m17.new" <<'EOF'
            :
EOF
check_fires "M17: a refused topo-start says nothing about the bridge" m17 \
            "🔴 the topology log is printed here too"

# --- M18: the verdict's denominator goes back to the global ten -------------------------------
# Exactly the live red of 2026-09-18: a four-switch package came up correctly and verify_p4_graph
# printed `kernel: 4 switches, 4 up (want 10/10)` and `is_enabled=4/10`, reporting a healthy
# fabric as two faults, because the want came off SWITCHES -- the literal 10 -- rather than off
# the model it was handed.
cat > "$A/m18.old" <<'EOF'
    local want_sw; want_sw="$(topo_model_switches "$topo")"
EOF
cat > "$A/m18.new" <<'EOF'
    local want_sw; want_sw="$SWITCHES"
EOF
check_fires "M18: the switch count comes off the global ten again" m18 \
            "🔴 a 4-switch package makes the want 4, not 10"

# --- M19-M23: TICKET-P2 §5.5, the package pipeline and the sampling rate ---------------------
#
# The whole family is one shape: a number decoded from p4_proxy/p4_src/build/ndtwin_switch.json
# printed for a fabric that never loaded that file. That is X-2 with a different plane in it --
# for months `status` printed `1/256` on an OVS fabric out of the same artefact and the two
# agreed only by coincidence -- and the package pipeline is the third way to reach it.

# M19: the rate rows stop having a foreign branch, so the built json's number is printed for a
# switch running the exercise's own program.
cat > "$A/m19.old" <<'EOF'
        foreign:*)
            printf '  %-14s %s\n' "sample rate" "n/a (package pipeline)"
EOF
cat > "$A/m19.new" <<'EOF'
        never-taken:*)
            printf '  %-14s %s\n' "sample rate" "n/a (package pipeline)"
EOF
check_fires "M19: a package pipeline is given the built json's rate" m19 \
            "🔴 a package pipeline has no rate here" \
            "🔴 the whole report says the rate is n/a"

# M20: the predicate the ROW and the --check problem both read stops exempting a foreign
# pipeline. The row still says n/a (it returns before the stale branch), so what this costs is
# a `--check` that exits 1 over a file this fabric never read, with the row beside it saying
# so -- a yellow problem under a green row, which is the shape E-9 was decided against.
cat > "$A/m20.old" <<'EOF'
    case "$kind" in foreign:*) return 1 ;; esac
EOF
cat > "$A/m20.new" <<'EOF'
    :
EOF
check_fires "M20: a foreign pipeline is judged stale after all" m20 \
            "🔴 a foreign pipeline is never stale" \
            "🔴 --check does not raise the stale-pipeline problem"

# M21: a package that will not load is reported as NDTwin's pipeline. The silent substitution
# app_package_row exists to remove, one row further down.
cat > "$A/m21.old" <<'EOF'
except Exception:
    print("unreadable")
EOF
cat > "$A/m21.new" <<'EOF'
except Exception:
    print("ndtwin")
EOF
check_fires "M21: an unparsable package reads as NDTwin's own pipeline" m21 \
            "🔴 a package that will not load is 'unreadable', NOT 'ndtwin'"

# M22: the per-switch pipelines are never consulted, so every package looks like NDTwin's --
# exactly what `ndt` said before G4 landed, and now a wrong answer rather than an old one.
cat > "$A/m22.old" <<'EOF'
    foreign = [s.dpid for s in pkg.switches if not pkg.pipeline_is_ndtwin(s.dpid, base)]
EOF
cat > "$A/m22.new" <<'EOF'
    foreign = []
EOF
check_fires "M22: per-switch pipelines are not consulted at all" m22 \
            "🔴 one switch on somebody else's program names the dpid"

# M23: the rate's own --check problems come back under a foreign pipeline.
cat > "$A/m23.old" <<'EOF'
    case "$kind" in foreign:*) return 0 ;; esac
EOF
cat > "$A/m23.new" <<'EOF'
    :
EOF
check_fires "M23: a foreign pipeline raises the built json's rate problems" m23 \
            "🔴 a foreign pipeline raises none of the rate problems" \
            "  nor any problem about the compiled rate"

# --- M24-M33: TICKET-P2-D, `verify_p4` over a fabric running the package's own program --------
#
# The family this time is one live defect and the three ways of over-correcting it. On
# 2026-09-18 `ndt up p4 --app <exercises/basic>` waited out CONVERGE_WAIT for twelve destination
# paths, read four, and ended `up, but not verified` over a fabric whose twelve ordered pairs all
# pinged at 0% loss -- because the proxy skips LLDP on a foreign pipeline by design. The
# over-corrections are: stop counting without checking that the proxy really did skip it (M24),
# stop gating on the entries too (M25, M30, M31), and turn the forwarding verdict into silence
# (M27) or keep it as a gate (M26).

# M24: the path count is abandoned on the strength of the KNOB, without reading what the proxy
# says -- the endpoint is not consulted and the answer is assumed. The same sentence would then
# be printed over a proxy that WAS discovering links and had found four of twelve, which is the
# fault the count exists to catch wearing this message as a disguise.
cat > "$A/m24.old" <<'EOF'
        skipped="$(switch_state_skipped <<<"$state")"; sk_rc=$?
EOF
cat > "$A/m24.new" <<'EOF'
        skipped="lldp_discovery"; sk_rc=0
EOF
check_fires "M24: 'NOT CHECKED' without asking the proxy at all" m24 \
            "🔴 a proxy that did NOT skip discovery is red" \
            "🔴 an endpoint with no control_plane is red too" \
            "🔴 'skipped: null' is NOT 'nothing was skipped'" \
            "  saying which question went unanswered"

# M24c: the unreadable case borrows the readable one's sentence. Still red -- the empty list has
# no lldp_discovery in it either -- but the report now says `control_plane.skipped is []`, i.e.
# quotes an answer as if the proxy had given one. "I could not ask" and "it answered nothing" are
# the two states this whole disclosure exists to keep apart, one layer up from the endpoint.
cat > "$A/m24c.old" <<'EOF'
        if (( sk_rc != 0 )); then
EOF
cat > "$A/m24c.new" <<'EOF'
        if false; then
EOF
check_fires "M24c: an unanswerable endpoint is quoted as having answered" m24c \
            "  and says the proxy gave no skipped list"

# M24b: the membership test goes, so ANY skip list satisfies it. A proxy reporting that it
# skipped `sflow_telemetry` while beaconing normally would have its path count dropped.
cat > "$A/m24b.old" <<'EOF'
        elif [[ ",$skipped," != *,lldp_discovery,* ]]; then
EOF
cat > "$A/m24b.new" <<'EOF'
        elif false; then
EOF
check_fires "M24b (widening): any skip list at all is enough" m24b \
            "🔴 a proxy that did NOT skip discovery is red"

# M25: a refused table entry stops failing the bring-up. That is the one thing NDTwin IS
# responsible for on this fabric -- the pipeline and the rules are both the package's, and
# applying them is the whole of NDTwin's job -- so `up. ready` over refused writes is a fabric
# reported healthy while carrying a hole the operator's next ping will find.
cat > "$A/m25.old" <<'EOF'
        if (( fail != 0 )); then
EOF
cat > "$A/m25.new" <<'EOF'
        if false; then
EOF
# 🔴 The named check is the fixture where the counts ADD UP and the proxy still reports refusals:
# with `applied != recorded` still in place, a 5-recorded/4-applied/1-failed switch is caught by
# the other branch printing word for word the same sentence, so the first draft of this mutation
# left the whole suite green. Two guards over one fact, where deleting either is invisible --
# P1-A's M19 again, and the fixture is the fix.
check_fires "M25: refused table entries no longer fail the bring-up" m25 \
            "🔴 refusals are red even when the counts add up" \
            "🔴 and not the counts-disagree sentence, which is a different fault"

# M26: forwarding is a gate again. `ndt up` then exits 1 on every skeleton arm and on
# source_routing's solution (whose own answer to a plain ping is silence -- audit-raw 7af2f352
# measured that arm with send.py/receive.py and a ttl), so drive_exercise.py never sees a red
# arm or a green one, only ERROR for both. This is the exact shape TICKET-P2 §7-10 decided
# against, restored.
cat > "$A/m26.old" <<'EOF'
            verify_dataplane_reading "$src" "$dst" "$(switch_state_p4info_shas <<<"$state")"
EOF
cat > "$A/m26.new" <<'EOF'
            verify_dataplane "$src" "$dst" "the package's own program" || rc=1
EOF
check_fires "M26: a package fabric is failed for not forwarding" m26 \
            "🔴 a silent data plane does NOT fail a package fabric"

# M27: a package pipeline falls into the external branch. Both print `destination paths NOT
# CHECKED`, so the headline survives -- what is lost is the dpids, the proxy's own reason, and
# the entries gate entirely. An external plane has nothing on it; this one has the package's
# rules on it, and they are the thing worth checking.
cat > "$A/m27.old" <<'EOF'
    if [[ "$mode" == external ]]; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
cat > "$A/m27.new" <<'EOF'
    if [[ "$mode" == external || -n "$foreign" ]]; then
        warn "proxy: destination paths NOT CHECKED -- this package declares an external control"
EOF
check_fires "M27: a package pipeline is reported as an external plane" m27 \
            "  naming the dpids the package's program is on" \
            "🔴 the entries the proxy applied are reported"

# M28: `ndt status --check` goes back to wanting `hosts * (hosts - 1)` destination paths on a
# fabric where nobody installed any. Every reading of the report on a package fabric exits 1,
# and the operator's next move is to debug a control plane that is behaving as designed.
cat > "$A/m28.old" <<'EOF'
            foreign:*)
                echo "  ${paths:-?} destination paths reported; none expected -- the package's program on dpid ${pkgpipe#foreign:}, proxy skipped lldp_discovery"
EOF
cat > "$A/m28.new" <<'EOF'
            never-taken:*)
                echo "  ${paths:-?} destination paths reported; none expected -- the package's program on dpid ${pkgpipe#foreign:}, proxy skipped lldp_discovery"
EOF
check_fires "M28: status wants paths nobody was ever going to install" m28 \
            "🔴 a package fabric is told none were expected" \
            "🔴 and the shortfall is NOT a --check problem"

# M29: `up_p4` stops telling verify_p4 whose program is on the switches. Every branch above is
# then unreachable from the command that matters, while the functions themselves stay perfect --
# the P1-A M19 shape (a decision that is right and never consulted).
cat > "$A/m29.old" <<'EOF'
    verify_p4 "$topo" "$want_paths" "$app_mode" "$app_pipe"
EOF
cat > "$A/m29.new" <<'EOF'
    verify_p4 "$topo" "$want_paths" "$app_mode"
EOF
check_fires "M29: the bring-up stops passing the pipeline kind on" m29 \
            "🔴 up_p4 passes the package's pipeline kind on"

# M30: applied < recorded with nothing reported as failed is accepted. "The proxy wrote four of
# five and called none of them a failure" is a count that disagrees with itself, and reading it
# as success is the "report zero rather than report an error" shape this project keeps finding.
cat > "$A/m30.old" <<'EOF'
        elif (( app != rec )); then
EOF
cat > "$A/m30.new" <<'EOF'
        elif false; then
EOF
check_fires "M30: entries that vanished between recorded and applied are fine" m30 \
            "🔴 applied < recorded with 0 failed is red too"

# M31: a switch that reports no `table_entries` at all is read as zero entries. An ABSENT count
# is not a zero -- the gate then passes every fabric whose proxy forgot to report, which is an
# unchecked gate printing `ok`.
cat > "$A/m31.old" <<'EOF'
    te = (sw[dpid] or {}).get("table_entries")
    if not isinstance(te, dict):
        raise SystemExit(1)
EOF
cat > "$A/m31.new" <<'EOF'
    te = (sw[dpid] or {}).get("table_entries") or {"recorded": 0, "applied": 0, "failed": 0}
EOF
check_fires "M31: a missing entry count is read as zero entries" m31 \
            "🔴 a switch that reports no table_entries is red"

# M32: the caveat under `ready` goes. The verdict word is unchanged and correct; what is lost is
# the paragraph saying NDTwin discovered no links, installed no routes, and quotes no sample
# rate for this fabric -- so `ready` means two different things depending on the package and
# nothing on the screen says which.
cat > "$A/m32.old" <<'EOF'
            warn "package pipeline: NDTwin discovered no links and installed no routes on this"
EOF
cat > "$A/m32.new" <<'EOF'
            warn "package pipeline:"
EOF
check_fires "M32: the ready line loses the paragraph that qualifies it" m32 \
            "🔴 and the caveat says what NDTwin did not do"

# M33: `unreadable` is treated as a foreign pipeline. A package this script could not parse is
# not evidence that the pipeline moved -- and this way round the consequence is worse than M21's,
# because an unparsable package would have its path count and its forwarding verdict both
# withdrawn on the strength of a file nobody could read.
cat > "$A/m33.old" <<'EOF'
    if [[ "$mode" != external && "$pipe" == foreign:* ]]; then
EOF
cat > "$A/m33.new" <<'EOF'
    if [[ "$mode" != external && "$pipe" != ndtwin && -n "$pipe" ]]; then
EOF
check_fires "M33: an unreadable package is treated as somebody else's pipeline" m33 \
            "  pipeline kind 'unreadable' still counts paths"

# --- M34: THE LIVE DEFECT ITSELF, in the form it shipped in ----------------------------------
#
# 🔴 THE ONE MUTATION THIS WHOLE TICKET IS ABOUT, and the first round did not have it. Every
# other mutation here attacks a piece of the new branch; this one deletes the branch and puts
# `365c60e1` back. A foreign fabric falls into the counting loop, polls forty times for twelve
# destination paths the proxy has said it will never install, reads four, and ends
# `up, but not verified -- do not measure on this` -- which is exactly what
# `live-p1/runs/2026-09-18T095025Z_02_app_basic/20_up.txt` says, over a fabric whose twelve
# ordered pairs then pinged at 0% loss. The entries gate goes with it (it lives in the same
# branch), so the one thing NDTwin IS responsible for on that fabric stops being checked at the
# same moment the thing it is not responsible for starts failing the bring-up.
#
# 🔴 THE ANCHOR CARRIES THE LINE ABOVE IT. `    elif [[ -n "$foreign" ]]; then` occurs three
# times in verify_p4 -- the paths branch, the data-plane branch and the caveat -- so the elif
# alone would be a DUP and this mutation would be scored as a survivor rather than applied.
# The external branch's last warn is unique, and it is the line this elif hangs off.
# 🔴 THE ANCHOR MOVED IN ROUND 4: TICKET-P2-F put the external plane's own probe gate between
# that warn and this elif, so the old pair no longer occurs and the mutation scored ANCHOR:0 --
# a survivor, correctly, because a mutation that cannot be applied has proved nothing. The line
# above the elif is now the probes call, which is equally unique.
cat > "$A/m34.old" <<'EOF'
        verify_p4_probes "$topo" || rc=1
    elif [[ -n "$foreign" ]]; then
EOF
cat > "$A/m34.new" <<'EOF'
        verify_p4_probes "$topo" || rc=1
    elif false; then
EOF
check_fires "M34: the live defect -- a package fabric is counted after all" m34 \
            "🔴 a package pipeline ends ready, not 'never settled'" \
            "🔴 it does NOT count paths and call four of twelve a failure" \
            "🔴 and NAMES the package fabric's path count as not checked" \
            "🔴 the entries the proxy applied are reported"

# --- M35: the entries gate runs and its answer is thrown away ---------------------------------
# The `ok` and the three `err` lines still print, the dpid is still named, and the bring-up
# still ends `up. ready`. A gate whose verdict nobody reads is a gate that is not there -- and
# this is the shape that survives a reading of the output, because the output is right.
cat > "$A/m35.old" <<'EOF'
        verify_p4_package_entries "$state" || rc=1
EOF
cat > "$A/m35.new" <<'EOF'
        verify_p4_package_entries "$state"
EOF
check_fires "M35: the entries gate's verdict is ignored" m35 \
            "🔴 one refused entry fails the bring-up" \
            "🔴 applied < recorded with 0 failed is red too" \
            "🔴 a switch that reports no table_entries is red" \
            "🔴 refusals are red even when the counts add up"

# --- M36-M42: TICKET-P2-F, external liveness is a reading and the probe is the gate ----------
#
# The family is one live measurement: live-p1/03 printed `kernel: 3 switches, 3 up` and its own
# `ndt status` one second later read `0 up, 3 enabled`. Nothing about the fabric changed in that
# second -- `3 up` was one read landing between two races (a background retry that writes isUp
# true, a 1 Hz pingWorker that writes it back false), over a fabric where no pipeline is loaded
# and the twin's own policy therefore calls every switch Down. So `up` stops being the gate and
# a question with a mechanical answer takes its place.

# M36: `up` is a gate on the external plane again -- the round-1 lottery restored. Every
# external bring-up is then green or red depending on which second `ndt` read the graph in.
cat > "$A/m36.old" <<'EOF'
    elif [[ "$mode" == external ]]; then
        # 🔴 THE SWITCH COUNT IS STILL A GATE; `up` AND `enabled` ARE A READING. TICKET-P2-F
EOF
cat > "$A/m36.new" <<'EOF'
    elif false; then
        # 🔴 THE SWITCH COUNT IS STILL A GATE; `up` AND `enabled` ARE A READING. TICKET-P2-F
EOF
check_fires "M36: external is judged on 'N up' again (the lottery)" m36 \
            "🔴 an external fabric with 0 up is GREEN" \
            "🔴 verify_p4_graph under external is green at 0 up" \
            "🔴 and up/enabled are named a READING"

# M37: the check that REPLACED it is not a gate -- the errors still print, the bring-up is still
# green. A switch nobody could reach is then reported and passed in the same breath, which is
# strictly worse than the state before this ticket: it looks like it was checked.
cat > "$A/m37.old" <<'EOF'
        verify_p4_probes "$topo" || rc=1
EOF
cat > "$A/m37.new" <<'EOF'
        verify_p4_probes "$topo" || true
EOF
check_fires "M37: the probe gate's verdict is ignored" m37 \
            "🔴 a switch that could not be reached is red" \
            "🔴 a dpid the proxy never built a client for is red" \
            "🔴 a probe that never completes is red, not green"

# M38: FAILED_PRECONDITION is treated as silence. It is the designed answer of every switch on
# an external fabric, so this makes the ONLY state that plane is ever in a failure -- `ndt up`
# would never again report an external package as ready.
cat > "$A/m38.old" <<'EOF'
                if [[ "$detail" == FAILED_PRECONDITION* ]]; then
EOF
cat > "$A/m38.new" <<'EOF'
                if false; then
EOF
check_fires "M38: a switch with no program counts as unreachable" m38 \
            "🔴 an external fabric with 0 up is GREEN" \
            "🔴 because the probe is what was gated"

# M39 (widening): the switch COUNT stops being a gate on the external plane too. Then nothing at
# all about the kernel graph is asserted there -- a graph with two of three switches in it reads
# exactly like a healthy one, which is what "up is a reading" must not be allowed to become.
cat > "$A/m39.old" <<'EOF'
        if [[ "$total" == "$want_sw" ]]; then
EOF
cat > "$A/m39.new" <<'EOF'
        if true; then
EOF
check_fires "M39 (widening): external asserts nothing about the graph" m39 \
            "🔴 two switches under a three-switch model still FAILS"

# M40: the bounded re-read collapses to one look. `probe_ok: null` is "no probe has completed
# yet", which on a fabric one second old is the ordinary case -- so every external bring-up
# would race the proxy's first probe and lose about a fifth of the time.
cat > "$A/m40.old" <<'EOF'
    for i in 1 2 3 4 5; do
        state="$(proxy_switch_state)"
EOF
cat > "$A/m40.new" <<'EOF'
    for i in 1; do
        state="$(proxy_switch_state)"
EOF
check_fires "M40: the probe is read once, not up to five times" m40 \
            "🔴 a probe that lands on the third read is GREEN" \
            "🔴 which took exactly three reads"

# M41 (widening): a probe that never completed counts as answered. "Nobody has asked yet" and
# "it answered" become the same reading -- the exact substitution proxy_agent keeps `probe_ok`
# nullable to prevent, reproduced one layer up.
cat > "$A/m41.old" <<'EOF'
            *)
                err "proxy: switch $dpid did not answer the liveness probe: ${detail:-no probe yet}"
                rc=1 ;;
EOF
cat > "$A/m41.new" <<'EOF'
            *)
                answered=$(( answered + 1 )) ;;
EOF
check_fires "M41 (widening): an unanswered probe counts as answered" m41 \
            "🔴 a probe that never completes is red, not green" \
            "  and says which question went unanswered"

# M42: `ndt status --check` calls an external fabric broken again. Every reading of the report
# between `ndt up` and the exercise's controller exits 1 over "3 switch(es) are down", about a
# fabric doing exactly what its package asked for.
cat > "$A/m42.old" <<'EOF'
        if [[ "$statmode" == external ]]; then
EOF
cat > "$A/m42.new" <<'EOF'
        if false; then
EOF
check_fires "M42: --check reports an external fabric as down" m42 \
            "🔴 and --check does NOT call the fabric broken" \
            "🔴 and says they are a reading"

# --- the controls: two behaviour-preserving rewrites -----------------------------------------
# 🔴 Without these the round says nothing. A harness that reported red for ANY edit would print
# `11 caught, 0 survived` above while catching nothing at all, and these are the edits that tell
# the two apart: same branch, same message, same file, written the long way.
cat > "$A/c1.old" <<'EOF'
    [[ "$state" == absent ]] && return 0
EOF
cat > "$A/c1.new" <<'EOF'
    if [[ "$state" == absent ]]; then
        return 0
    fi
EOF
check_control "C1: app_knob_clear's early return, written the long way" c1

cat > "$A/c2.old" <<'EOF'
            --app=*) NDT_APP_DIR="${a#--app=}"; seen=1 ;;
EOF
cat > "$A/c2.new" <<'EOF'
            --app=*) NDT_APP_DIR="${a:6}"; seen=1 ;;
EOF
check_control "C2: --app=<dir> stripped by offset instead of prefix" c2

echo
NOW_SUM="$(sha256sum "$NDT" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_SUM"
    echo "   after:  $NOW_SUM"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_SUM"
echo "mutation gate: $((CAUGHT+SURVIVED)) mutations, $SURVIVED survived; $CONTROLS control(s), $CONTROLS_RED went red"
(( SURVIVED == 0 && CONTROLS_RED == 0 ))
