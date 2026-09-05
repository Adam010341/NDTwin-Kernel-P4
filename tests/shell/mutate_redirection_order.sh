#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_redirection_order.sh.
#
# [Co-developed with claude code -- Adam]
#
# M1-M14 (eighteen mutations: M2b and M3b-M3d are sites later merges added) put the defect back
# one site at a time: every one of the lines the fix touched gets its silencer moved back behind
# the input redirection, and must turn its named case red. A site whose mutation survives is a
# site the test does not actually cover.
#
# 🔴 M15 and M16 are the half that matters more. The gate has to forbid the two ways of being
# green that are WORSE than the bug:
#   M15  `exec 2>/dev/null` at the top of pid_is_app -- silences the leak and every other
#        diagnostic the function could ever raise. Every "is it silent" case goes green.
#   M16  delete the read entirely -- nothing is opened, so nothing can leak.
# Both are caught only by cases that assert something OTHER than silence. If either survived,
# this gate would be rewarding the fixes it exists to forbid.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES under a temp tree and the test is
# pointed at them with REPO_UNDER_TEST / NDT_UNDER_TEST. Nothing under the real tools/ or
# tests/ is written, and the sha256 of all eight source files is compared before and after --
# another session may be executing them right now.
#
# Offline: the test it drives starts no lab, no build and no listener. See its header.
#
# Run:  bash tests/shell/mutate_redirection_order.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST="$HERE/test_redirection_order.sh"
BK="$(mktemp -d /tmp/redir-mutate-XXXXXX)"; trap 'rm -rf "$BK"' EXIT

# Every file the test reads. A mutant is a tree containing exactly these, at these paths.
#
# Named one per variable as well as collected in FILES, on purpose: tests/shell/
# check_gate_anchors.py pins an anchor to its file through a DECLARED path variable at the call
# site, and a bare literal path argument gives it nothing to resolve. Repo-relative, because
# make_tree and the applier both join them onto a root.
NDT=tools/test_workflow/ndt
GUARDS=tools/test_workflow/test_teardown_guards.sh
ORPHANS=tests/shell/test_ndt_app_orphans.sh
EP4=tests/shell/test_ep4_gate_and_abort_evidence.sh
PREFLIGHT=tests/shell/test_preflight_instrument_self_failures.sh
WITNESS=tools/remote-lab/host_witness.sh
VM=tools/remote-lab/ndtwin-vm.sh
P4PRE=tools/remote-lab/p4_patch_preflight.sh
FILES=(
  "$NDT"
  "$GUARDS"
  "$ORPHANS"
  "$EP4"
  "$PREFLIGHT"
  "$WITNESS"
  "$VM"
  "$P4PRE"
)

BASE_SUMS="$(cd "$REPO" && sha256sum "${FILES[@]}")"

SURVIVORS=0; MUTATIONS=0

make_tree() {   # $1 = dir
    local rel
    for rel in "${FILES[@]}"; do
        mkdir -p "$1/$(dirname "$rel")"
        cp "$REPO/$rel" "$1/$rel"
    done
    chmod +x "$1/tools/test_workflow/ndt"
}

# $1 name, $2 repo-relative file, $3 old text, $4 new text, $5 expected hits (default 1)
#
# 2026-09-05: $3/$4 used to be ONE argument, "old<US>new", packed at RUNTIME by each call
# site's own "$(printf '...\x1f...')" -- and the two that could not be written that way
# (M2/M2b) were held in A2/B2 shell variables instead. Nothing under tools/ or tests/ changed
# then and nothing changes now; only how this gate SPELLS the anchor it passes down.
# check_gate_anchors.py deliberately never evaluates a command substitution ("what the
# substitution EVALUATES to is not something this tool can know" -- its own words), so ALL
# twenty anchors were invisible to it: the gate extracted ZERO anchors and its cell read
# UNPARSED. The 2026-09-04 write-up read that cell as "eighteen checked, two not"; it was
# none of them. Split into two plain arguments -- named here so the checker's existing
# role-based reading applies -- with every old/new pair captured from the ORIGINAL call sites
# and compared byte-for-byte (base64) against the rewritten ones before this change was kept.
# The same rewrite tests/shell/mutate_ports_that_block_restart.sh took on 2026-09-04, for the
# same reason.
mutant() {
    local name="$1" rel="$2" old="$3" new="$4" want="${5:-1}"
    local d="$BK/$name"; mkdir -p "$d"; make_tree "$d"
    python3 - "$d/$rel" "$old" "$new" "$want" <<'PY'
import sys
p, a, b, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
s = open(p).read()
n = s.count(a)
assert n == want, "anchor hit %d times, wanted %d: %s" % (n, want, a[:80])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

run_against() { REPO_UNDER_TEST="$1" NDT_UNDER_TEST="$1/tools/test_workflow/ndt" \
                timeout 300 bash "$TEST" 2>&1; }

report() {   # $1 mutation name, $2 mutant dir, $3 case that must go red
    local out rc ran
    MUTATIONS=$((MUTATIONS+1))
    out="$(run_against "$2")"; rc=$?
    # 🔴 "the named case went red" is not enough on its own: a mutation that makes the test
    # ABORT after that case would look identical. The trailing "Ran N checks" line is the only
    # evidence the run reached the end, so it is required -- and N must match the baseline, or
    # the mutation quietly removed checks instead of failing them.
    ran="$(grep -oE 'Ran [0-9]+ checks' <<<"$out" | tail -1)"
    if [[ "$ran" != "$BASE_RAN" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (run did not finish the same way: [%s] vs baseline [%s])\n' \
               "$1" "$ran" "$BASE_RAN"
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; make_tree "$base"
base_out="$(run_against "$base")"; base_rc=$?
BASE_RAN="$(grep -oE 'Ran [0-9]+ checks' <<<"$base_out" | tail -1)"
tail -1 <<<"$base_out"
[[ "$base_rc" -eq 0 && -n "$BASE_RAN" ]] \
  || { echo "  baseline is RED or did not finish -- fix that first; mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the reported three -------------------------------------------------------------------------
m=$(mutant m1 "$NDT" \
    'mapfile -d '"'"''"'"' -t argv 2>/dev/null < "/proc/$pid/cmdline"' \
    'mapfile -d '"'"''"'"' -t argv < "/proc/$pid/cmdline" 2>/dev/null')
report "M1: ndt pid_is_app -- silencer back behind the read" "$m" \
       "🔑 pid_is_app is SILENT when /proc/<pid>/cmdline is gone"

m=$(mutant m2 "$NDT" \
    'info "  pid $pid: $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-90)"' \
    'info "  pid $pid: $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"')
report "M2: ndt app_stop argv line -- order reverted" "$m" \
       "app_stop's argv line is silent for a pid that cannot exist"

m=$(mutant m2b "$NDT" \
    'err "   pid $pid: $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-90)"' \
    'err "   pid $pid: $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"')
report "M2b: ndt app_wait_stopped argv line (g6) -- order reverted" "$m" \
       "app_wait_stopped's argv line (g6) is silent for a pid that cannot exist"

# --- the rest of the family: each site anchors on its own full line -----------------------------
# 2026-09-03 merge note: `cut -c1-90` stopped being a unique anchor when fix/g6-ndt-apps-liveness
# added a second site (app_wait_stopped), and `cut -c1-80` stopped being one when
# fix/apps-stop-kills-the-group added three more (apps_orphans' second branch,
# app_verify_stopped's survivor list, app_kill_by_existence). Each site now anchors on its own
# full line and gets its own mutation -- a merge that reintroduces the shape at any of them must
# be caught, not reported as a non-unique anchor.
m=$(mutant m3 "$NDT" \
    'err "    pid $pid  $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-80)"' \
    'err "    pid $pid  $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)"')
report "M3: ndt apps_orphans argv line -- order reverted" "$m" \
       "apps_orphans' argv line is silent for a pid that cannot exist"

m=$(mutant m3b "$NDT" \
    'err "      $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-80)"' \
    'err "      $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80)"')
report "M3b: ndt apps_orphans orphaned-children argv line -- order reverted" "$m" \
       "apps_orphans' orphaned-children argv line is silent for a pid that cannot exist"

m=$(mutant m3c "$NDT" \
    'err "      it is $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-90)"' \
    'err "      it is $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"')
report "M3c: ndt app_verify_stopped survivor argv line -- order reverted" "$m" \
       "app_verify_stopped's survivor argv line is silent for a pid that cannot exist"

m=$(mutant m3d "$NDT" \
    'err "   it is $(tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-90)"' \
    'err "   it is $(tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"')
report "M3d: ndt app_kill_by_existence argv line -- order reverted" "$m" \
       "app_kill_by_existence's argv line is silent for a pid that cannot exist"

# --- one mutation per fixed site, outside ndt ----------------------------------------------------
m=$(mutant m4 "$GUARDS" \
    'tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "$d/cmdline"' \
    'tr '"'"'\0'"'"' '"'"' '"'"' < "$d/cmdline" 2>/dev/null')
report "M4: test_teardown_guards /proc sweep -- order reverted" "$m" \
       'test_teardown_guards.sh (args="$(tr) is silent'

m=$(mutant m5 "$ORPHANS" \
    'mapfile -d '"'"''"'"' -t argv 2>/dev/null < "/proc/$pid/cmdline"' \
    'mapfile -d '"'"''"'"' -t argv < "/proc/$pid/cmdline" 2>/dev/null')
report "M5: test_ndt_app_orphans retry loop -- order reverted" "$m" \
       "test_ndt_app_orphans.sh (mapfile -d '' -t argv) is silent"

m=$(mutant m6 "$EP4" \
    'wc -c 2>/dev/null <"$empty_file"' \
    'wc -c <"$empty_file" 2>/dev/null')
report "M6: test_ep4 header size probe -- order reverted" "$m" \
       'test_ep4_gate_and_abort_evidence.sh (hdr=$(wc -c) is silent'

m=$(mutant m7 "$PREFLIGHT" \
    'read -r LPORT LPARENT LCHILD 2>/dev/null < "$T/listener.out"' \
    'read -r LPORT LPARENT LCHILD < "$T/listener.out" 2>/dev/null')
report "M7: test_preflight listener read -- order reverted" "$m" \
       "test_preflight_instrument_self_failures.sh (read -r LPORT) is silent"

m=$(mutant m8 "$WITNESS" \
    'read -r -d '"'"''"'"' cmd 2>/dev/null < "$PROCFS/$pid/cmdline"' \
    'read -r -d '"'"''"'"' cmd < "$PROCFS/$pid/cmdline" 2>/dev/null')
report "M8: host_witness kernel-thread probe -- order reverted" "$m" \
       "host_witness.sh (IFS= read -r -d '' cmd) is silent"

m=$(mutant m9 "$VM" \
    'read -r -d '"'"''"'"' a0 2>/dev/null < "$d/cmdline"' \
    'read -r -d '"'"''"'"' a0 < "$d/cmdline" 2>/dev/null')
report "M9: ndtwin-vm /proc sweep -- order reverted" "$m" \
       'ndtwin-vm.sh (a0=""; IFS= read) is silent'

m=$(mutant m10 "$VM" \
    'tr '"'"'\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$q/cmdline" | cut -c1-200' \
    'tr '"'"'\0'"'"' '"'"' '"'"' < "/proc/$q/cmdline" 2>/dev/null | cut -c1-200')
report "M10: ndtwin-vm unparseable-disk report -- order reverted" "$m" \
       "ndtwin-vm.sh (cut -c1-200) is silent"

m=$(mutant m11 "$VM" \
    'tr '"'"'\0'"'"' '"'"'\n'"'"' 2>/dev/null < "/proc/$q/cmdline" | awk' \
    'tr '"'"'\0'"'"' '"'"'\n'"'"' < "/proc/$q/cmdline" 2>/dev/null | awk')
report "M11: ndtwin-vm no-CONFIG work point -- order reverted" "$m" \
       'ndtwin-vm.sh (/^-m$/{getline;m=$0}) is silent'

m=$(mutant m12 "$P4PRE" \
    'patch -p1 --dry-run --force >/dev/null 2>&1 < "../$f"' \
    'patch -p1 --dry-run --force < "../$f" >/dev/null 2>&1')
report "M12: p4_patch_preflight dry-run -- order reverted" "$m" \
       "p4_patch_preflight.sh (patch -p1 --dry-run) is silent"

# --- the three sites the test guards statically (multi-line commands; two of them would need a
#     lab to run). The static guard is weaker than the cases above, so it gets its own mutations
#     rather than being taken on trust. -----------------------------------------------------------
m=$(mutant m13 "$VM" \
    'tr '"'"'\0'"'"' '"'"'\n'"'"' 2>/dev/null < "/proc/$1/cmdline" | awk' \
    'tr '"'"'\0'"'"' '"'"'\n'"'"' < "/proc/$1/cmdline" 2>/dev/null | awk' 2)
report "M13: ndtwin-vm's two multi-line awk readers -- order reverted" "$m" \
       "static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)"

m=$(mutant m14 "$NDT" \
    'bash "$STACK" up ovs > "$out" 2>&1 < "$fifo"' \
    'bash "$STACK" up ovs < "$fifo" > "$out" 2>&1')
report "M14: ndt up-ovs capture -- order reverted (fifo failure escapes the log)" "$m" \
       "static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)"

# --- 🔴 the two ways of being green that are worse than the bug ----------------------------------
m=$(mutant m15 "$NDT" \
    'local pid="$1" name="$2" sig comm el' \
    'local pid="$1" name="$2" sig comm el; exec 2>/dev/null')
report "M15: 'exec 2>/dev/null' at the top of pid_is_app (silences EVERYTHING)" "$m" \
       "🔑 a REAL error inside pid_is_app still reaches the caller"

m=$(mutant m16 "$NDT" \
    'mapfile -d '"'"''"'"' -t argv 2>/dev/null < "/proc/$pid/cmdline"' \
    ': no read at all')
report "M16: delete the read entirely (nothing opened, nothing leaks)" "$m" \
       "pid_is_app MATCHES from cmdline when comm says otherwise (rc 0)"

echo
if [[ "$BASE_SUMS" == "$(cd "$REPO" && sha256sum "${FILES[@]}")" ]]; then
    echo "baseline byte-identical: yes (all ${#FILES[@]} source files)"
else
    echo "🔴 baseline CHANGED -- a source file was written during the gate"; exit 3
fi
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
