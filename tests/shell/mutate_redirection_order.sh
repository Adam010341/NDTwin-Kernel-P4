#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_redirection_order.sh.
#
# [Co-developed with claude code -- Adam]
#
# M1-M15 put the defect back one site at a time: every one of the fifteen lines the fix touched
# gets its silencer moved back behind the input redirection, and must turn its named case red.
# A site whose mutation survives is a site the test does not actually cover.
#
# 🔴 M16 and M17 are the half that matters more. The gate has to forbid the two ways of being
# green that are WORSE than the bug:
#   M16  `exec 2>/dev/null` at the top of pid_is_app -- silences the leak and every other
#        diagnostic the function could ever raise. Every "is it silent" case goes green.
#   M17  delete the read entirely -- nothing is opened, so nothing can leak.
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
FILES=(
  tools/test_workflow/ndt
  tools/test_workflow/test_teardown_guards.sh
  tests/shell/test_ndt_app_orphans.sh
  tests/shell/test_ep4_gate_and_abort_evidence.sh
  tests/shell/test_preflight_instrument_self_failures.sh
  tools/remote-lab/host_witness.sh
  tools/remote-lab/ndtwin-vm.sh
  tools/remote-lab/p4_patch_preflight.sh
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

# $1 name, $2 relative file, $3 "old<US>new", $4 expected number of hits (default 1)
mutant() {
    local d="$BK/$1"; mkdir -p "$d"; make_tree "$d"
    python3 - "$d/$2" "$3" "${4:-1}" <<'PY'
import sys
p, spec, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
a, b = spec.split("\x1f")
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
m=$(mutant m1 tools/test_workflow/ndt "$(printf 'mapfile -d '"''"' -t argv 2>/dev/null < "/proc/$pid/cmdline"\x1fmapfile -d '"''"' -t argv < "/proc/$pid/cmdline" 2>/dev/null')")
report "M1: ndt pid_is_app -- silencer back behind the read" "$m" \
       "🔑 pid_is_app is SILENT when /proc/<pid>/cmdline is gone"

m=$(mutant m2 tools/test_workflow/ndt "$(printf 'tr '"'"'\\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-90\x1ftr '"'"'\\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90')")
report "M2: ndt app_stop argv line -- order reverted" "$m" \
       "app_stop's argv line is silent for a pid that cannot exist"

m=$(mutant m3 tools/test_workflow/ndt "$(printf 'tr '"'"'\\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-80\x1ftr '"'"'\\0'"'"' '"'"' '"'"' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-80')")
report "M3: ndt apps_orphans argv line -- order reverted" "$m" \
       "apps_orphans' argv line is silent for a pid that cannot exist"

# --- the rest of the family, one mutation per fixed site ----------------------------------------
m=$(mutant m4 tools/test_workflow/test_teardown_guards.sh "$(printf 'tr '"'"'\\0'"'"' '"'"' '"'"' 2>/dev/null < "$d/cmdline"\x1ftr '"'"'\\0'"'"' '"'"' '"'"' < "$d/cmdline" 2>/dev/null')")
report "M4: test_teardown_guards /proc sweep -- order reverted" "$m" \
       'test_teardown_guards.sh (args="$(tr) is silent'

m=$(mutant m5 tests/shell/test_ndt_app_orphans.sh "$(printf 'mapfile -d '"''"' -t argv 2>/dev/null < "/proc/$pid/cmdline"\x1fmapfile -d '"''"' -t argv < "/proc/$pid/cmdline" 2>/dev/null')")
report "M5: test_ndt_app_orphans retry loop -- order reverted" "$m" \
       "test_ndt_app_orphans.sh (mapfile -d '' -t argv) is silent"

m=$(mutant m6 tests/shell/test_ep4_gate_and_abort_evidence.sh "$(printf 'wc -c 2>/dev/null <"$empty_file"\x1fwc -c <"$empty_file" 2>/dev/null')")
report "M6: test_ep4 header size probe -- order reverted" "$m" \
       'test_ep4_gate_and_abort_evidence.sh (hdr=$(wc -c) is silent'

m=$(mutant m7 tests/shell/test_preflight_instrument_self_failures.sh "$(printf 'read -r LPORT LPARENT LCHILD 2>/dev/null < "$T/listener.out"\x1fread -r LPORT LPARENT LCHILD < "$T/listener.out" 2>/dev/null')")
report "M7: test_preflight listener read -- order reverted" "$m" \
       "test_preflight_instrument_self_failures.sh (read -r LPORT) is silent"

m=$(mutant m8 tools/remote-lab/host_witness.sh "$(printf 'read -r -d '"''"' cmd 2>/dev/null < "$PROCFS/$pid/cmdline"\x1fread -r -d '"''"' cmd < "$PROCFS/$pid/cmdline" 2>/dev/null')")
report "M8: host_witness kernel-thread probe -- order reverted" "$m" \
       "host_witness.sh (IFS= read -r -d '' cmd) is silent"

m=$(mutant m9 tools/remote-lab/ndtwin-vm.sh "$(printf 'read -r -d '"''"' a0 2>/dev/null < "$d/cmdline"\x1fread -r -d '"''"' a0 < "$d/cmdline" 2>/dev/null')")
report "M9: ndtwin-vm /proc sweep -- order reverted" "$m" \
       'ndtwin-vm.sh (a0=""; IFS= read) is silent'

m=$(mutant m10 tools/remote-lab/ndtwin-vm.sh "$(printf 'tr '"'"'\\0'"'"' '"'"' '"'"' 2>/dev/null < "/proc/$q/cmdline" | cut -c1-200\x1ftr '"'"'\\0'"'"' '"'"' '"'"' < "/proc/$q/cmdline" 2>/dev/null | cut -c1-200')")
report "M10: ndtwin-vm unparseable-disk report -- order reverted" "$m" \
       "ndtwin-vm.sh (cut -c1-200) is silent"

m=$(mutant m11 tools/remote-lab/ndtwin-vm.sh "$(printf 'tr '"'"'\\0'"'"' '"'"'\\n'"'"' 2>/dev/null < "/proc/$q/cmdline" | awk\x1ftr '"'"'\\0'"'"' '"'"'\\n'"'"' < "/proc/$q/cmdline" 2>/dev/null | awk')")
report "M11: ndtwin-vm no-CONFIG work point -- order reverted" "$m" \
       'ndtwin-vm.sh (/^-m$/{getline;m=$0}) is silent'

m=$(mutant m12 tools/remote-lab/p4_patch_preflight.sh "$(printf 'patch -p1 --dry-run --force >/dev/null 2>&1 < "../$f"\x1fpatch -p1 --dry-run --force < "../$f" >/dev/null 2>&1')")
report "M12: p4_patch_preflight dry-run -- order reverted" "$m" \
       "p4_patch_preflight.sh (patch -p1 --dry-run) is silent"

# --- the three sites the test guards statically (multi-line commands; two of them would need a
#     lab to run). The static guard is weaker than the cases above, so it gets its own mutations
#     rather than being taken on trust. -----------------------------------------------------------
m=$(mutant m13 tools/remote-lab/ndtwin-vm.sh "$(printf 'tr '"'"'\\0'"'"' '"'"'\\n'"'"' 2>/dev/null < "/proc/$1/cmdline" | awk\x1ftr '"'"'\\0'"'"' '"'"'\\n'"'"' < "/proc/$1/cmdline" 2>/dev/null | awk')" 2)
report "M13: ndtwin-vm's two multi-line awk readers -- order reverted" "$m" \
       "static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)"

m=$(mutant m14 tools/test_workflow/ndt "$(printf 'bash "$STACK" up ovs > "$out" 2>&1 < "$fifo"\x1fbash "$STACK" up ovs < "$fifo" > "$out" 2>&1')")
report "M14: ndt up-ovs capture -- order reverted (fifo failure escapes the log)" "$m" \
       "static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)"

# --- 🔴 the two ways of being green that are worse than the bug ----------------------------------
m=$(mutant m15 tools/test_workflow/ndt "$(printf 'local pid="$1" name="$2" sig comm el\x1flocal pid="$1" name="$2" sig comm el; exec 2>/dev/null')")
report "M15: 'exec 2>/dev/null' at the top of pid_is_app (silences EVERYTHING)" "$m" \
       "🔑 a REAL error inside pid_is_app still reaches the caller"

m=$(mutant m16 tools/test_workflow/ndt "$(printf 'mapfile -d '"''"' -t argv 2>/dev/null < "/proc/$pid/cmdline"\x1f: no read at all')")
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
