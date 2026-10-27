#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ndt_ntg_mode.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation puts back one way `ndt ntg` can edit a different NTG checkout from the one the
# lab helper hands the P4 bridge, and must turn its NAMED case red. A mutation caught by some
# other case says nothing about the case that was supposed to own it.
#
# 🔴 Mutations are applied to COPIES in a temp dir and the suite is pointed at them with
#    NDT_UNDER_TEST; tools/test_workflow/ndt is never written, and its sha256 is compared at the
#    end. A copy carries ports.sh, sudo_surface.sh and components.env, which ndt sources from
#    beside itself.
# 🔴 A mutation that will not apply, a non-unique anchor, or the wrong case going red counts as a
#    SURVIVOR. A comment-only edit is the control and must stay green.
# 🔴 Touches no lab and no real NTG checkout: the suite redirects LAB_CONF and both defaults into
#    a temp dir (see its header).
#
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived (or the
#       control went red), 2 refused (baseline red / harness), 3 ndt changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
SH_TEST="$HERE/test_ndt_ntg_mode.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ntg-mode-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$SH_TEST" ]] || { echo "🔴 missing $NDT or $SH_TEST" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 600 bash "$SH_TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -f "$2/ndt" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (the mutant was not built)\n' "$1"; return
    fi
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

control() {   # $1 = name, $2 = mutant dir -- must NOT turn the suite red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ -f "$2/ndt" && "$rc" -eq 0 ]]; then
        printf '  survived %-58s (control, as required)\n' "$1"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1"
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$NDT" "$d/ndt.src"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    cp "$REPO/tools/test_workflow/components.env" "$d/components.env"
    if python3 - "$d/ndt.src" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        mv "$d/ndt.src" "$d/$(basename "$file")"; chmod +x "$d/ndt"
    fi
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
cp "$REPO/tools/test_workflow/components.env" "$base/components.env"
run_sh "$base" | tail -1
run_sh "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- mutations prove nothing"; exit 2; }
echo

# The defect itself: `ndt ntg` edits the built-in default whatever the helper is configured with.
m=$(mutant n1 "$NDT" \
    '    both="$(lab_ntg_dir; printf '\''\t%s'\'' "$LAB_NTG_DIR_SOURCE")"' \
    '    both="$LAB_DEFAULT_NTG_DIR"$'\''\t'\''"built-in default"')
report "N1: ndt ntg ignores the config file" "$m" \
       "🔴 a trusted config's NTG_DIR -> that checkout's mode is reported"

# A per-key reader: the helper's post-condition on KERNEL_DIR is applied only when KERNEL_DIR is
# the key asked for, so a file the helper refuses whole still sets NTG_DIR here.
m=$(mutant n2 "$NDT" \
    '    [[ -d "$kdir" ]] || return 1
    [[ -f "$kdir/p4_proxy/mininet/ntg_bmv2_topo.py" ]] || return 1' \
    '    if [[ "$want" == KERNEL_DIR ]]; then
        [[ -d "$kdir" ]] || return 1
        [[ -f "$kdir/p4_proxy/mininet/ntg_bmv2_topo.py" ]] || return 1
    fi')
report "N2: the KERNEL_DIR post-condition is skipped for NTG_DIR" "$m" \
       "🔴 NTG_DIR only, default KERNEL_DIR missing -> the helper refuses the file, so does ndt"

m=$(mutant n3 "$NDT" \
    '        err "  NTG_DIR=$ntg_dir ($src)"' \
    '        :')
report "N3: the missing-file error does not say where NTG_DIR came from" "$m" \
       "  NTG_DIR and its source: the built-in default"

# The copy drifts from the helper -- the one failure a copied rule is guaranteed to have.
m=$(mutant n4 "$NDT" \
    'LAB_DEFAULT_NTG_DIR=/home/adam/Network-Traffic-Generator' \
    'LAB_DEFAULT_NTG_DIR=/home/adam/NTG')
report "N4: ndt's default NTG_DIR drifts from the helper's" "$m" \
       "🔴 ndt's default NTG_DIR is the helper's default"

m=$(mutant n5 "$NDT" \
    '        case "$key" in
            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR|NTG_DIR) ;;
            *) return 1 ;;
        esac' \
    '        case "$key" in
            KERNEL_DIR|NTG_PY|ENERGY_DIR|SIM_DIR|NTG_DIR) ;;
            *) continue ;;
        esac')
report "N5: an unknown key is skipped instead of refusing the file" "$m" \
       "  badkey.conf"

m=$(mutant n6 "$NDT" \
    '        [[ "$key" == "$want" ]] && found="$val"' \
    '        [[ "$key" == "$want" && -z "$found" ]] && found="$val"')
report "N6: the first of two NTG_DIR lines wins (the helper keeps the last)" "$m" \
       "  twice.conf"

m=$(mutant n7 "$NDT" \
    '            LAB_NTG_DIR_SOURCE="built-in default ($LAB_CONF was REFUSED)"' \
    '            LAB_NTG_DIR_SOURCE="built-in default"')
report "N7: a refused config is reported as plain default" "$m" \
       "🔴 a refused config is named as refused, not silently replaced"

# --- the control -------------------------------------------------------------------------------
m=$(mutant n8 "$NDT" \
    '# lab_ntg_dir -- the NTG checkout `sudo ndtwin-lab` hands the P4 bridge. Sets LAB_NTG_DIR_SOURCE.' \
    '# lab_ntg_dir -- the NTG checkout `sudo ndtwin-lab` hands the P4 bridge (x). Sets LAB_NTG_DIR_SOURCE.')
control "N8: a comment-only edit" "$m"

echo
NOW_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- tools/test_workflow/ndt was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  tools/test_workflow/ndt  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
