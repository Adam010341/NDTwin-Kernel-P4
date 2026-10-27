#!/usr/bin/env bash
#
# `ndt ntg` edits the YAML of the NTG checkout the P4 bridge uses -- the lab helper's NTG_DIR.
#
# [Co-developed with claude code -- Adam]
#
# `ndt ntg cli|prompt` flips one line in Network-Traffic-Generator/setting/Mininet.yaml. The path
# was a literal under one person's home, while the helper (tools/test_workflow/ndtwin-lab) takes
# NTG_DIR from /etc/ndtwin-lab.conf. On a machine whose NTG checkout is elsewhere the two named
# different checkouts: `ndt ntg` said "not found" about a file nobody uses, or -- worse, on a
# machine that happened to have both -- edited the one the bridge does not read.
#
# `ndt` now resolves NTG_DIR READ-ONLY by the helper's own rule (the same copy that already
# resolves KERNEL_DIR, see lab_kernel_dir), so this suite asks two things:
#
#   * does `ndt ntg` read and edit the YAML under that NTG_DIR, and say where the path came from
#     when it is missing;
#   * does the copy agree with the helper on every config file -- asked by running the helper's
#     own parser on the same fixtures, not by comparing against strings written out here.
#
# 🔴 NOTHING HERE WRITES /etc OR TOUCHES A REAL NTG CHECKOUT. ndt's LAB_CONF and both defaults
#    are redirected into a temp dir; the pre-fix global NTG_YAML is pointed at a path that cannot
#    exist, so a `ndt` that still edits a fixed path can only fail, never touch somebody's
#    checkout. Sourcing the HELPER does run its top-level lab_config_load, which reads the real
#    /etc/ndtwin-lab.conf if there is one (read-only); every helper answer below resets
#    KERNEL_DIR and NTG_DIR by hand before parsing a fixture, so that file decides none of them.
#    `lab_version_problem` is stubbed, so the installed helper is not compared either. The trust
#    gate (root-owned file in a root-owned directory) cannot be satisfied off a root shell; it is
#    exercised for REFUSAL against a real user-owned file, and replaced by `return 0` only in the
#    cases that are about what a trusted file says. tests/shell/test_ndt_helper_apps_window.sh
#    covers the gate itself.
#
# Run:  bash tests/shell/test_ndt_ntg_mode.sh
# Env:  NDT_UNDER_TEST=<path>  NDTWIN_LAB_UNDER_TEST=<path>   (a mutation gate points these at copies)
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
LAB="${NDTWIN_LAB_UNDER_TEST:-$REPO/tools/test_workflow/ndtwin-lab}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }
[[ -r "$LAB" ]] || { echo "no ndtwin-lab at $LAB"; echo "Ran 1 checks, 1 failed"; exit 2; }

PASS=0; FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             expected: $expected"; echo "             actual:   $actual"; FAIL=$((FAIL+1)); fi
}
has() {
    local what="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then echo "  ok       $what"; PASS=$((PASS+1))
    else echo "  FAILED   $what"; echo "             wanted:   $needle"; echo "             in:       ${hay//$'\n'/$'\n'                       }"; FAIL=$((FAIL+1)); fi
}
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d /tmp/ndt-ntgmode-XXXXXX)"
cleanup_all() { [[ -n "${FIX:-}" && "$FIX" == /tmp/ndt-ntgmode-* ]] && rm -rf "${FIX:?}"; return 0; }
trap cleanup_all EXIT INT TERM

mk_kernel() { mkdir -p "$1/p4_proxy/mininet" && : > "$1/p4_proxy/mininet/ntg_bmv2_topo.py"; }
mk_ntg() {    # <dir> <mode>
    mkdir -p "$1/setting"
    : > "$1/network_traffic_generator.py"
    printf 'Mininet:\n  cli:\n    mode: "%s" \n  other: 1\n' "$2" > "$1/setting/Mininet.yaml"
}
mode_in() { sed -n 's/.*mode:[[:space:]]*"\?\([a-z]*\)"\?.*/\1/p' "$1/setting/Mininet.yaml" | head -1; }

mkdir -p "$FIX/conf"
mk_kernel "$FIX/kernel"          # stands in for the helper's default KERNEL_DIR
mk_kernel "$FIX/otherkernel"
mkdir -p "$FIX/nobridge"
mk_ntg "$FIX/defntg" cli         # stands in for the helper's default NTG_DIR
mk_ntg "$FIX/ntg" prompt         # the checkout a config file names

# --- the seam ----------------------------------------------------------------------------------
STUBS='
LAB_CONF="${FX_CONF:-'"$FIX"'/conf/none.conf}"
LAB_DEFAULT_KERNEL_DIR="${FX_DEFAULT_KERNEL_DIR:-'"$FIX"'/kernel}"
LAB_DEFAULT_NTG_DIR="${FX_DEFAULT_NTG_DIR:-'"$FIX"'/defntg}"
NTG_YAML=/nonexistent/NDT-TEST-FIXTURE/fixed-path/setting/Mininet.yaml
[[ "${FX_TRUST:-0}" == 1 ]] && lab_conf_trusted() { return 0; }
lab_version_problem() { :; }
'
inner() {   # inner <shell code> -- run it with ndt sourced and the seam in place
    bash -c "source '$NDT' >/dev/null 2>&1
set +e
$STUBS
$1" 2>&1
}
# helper_ntg_dir <conf> <default KERNEL_DIR> <default NTG_DIR> -- what the HELPER would run with,
# from its own parser: lab_config_parse on the file, and lab_config_load's restore when it refuses.
helper_ntg_dir() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e
        KERNEL_DIR="$3"; NTG_PY=/x; ENERGY_DIR=/x; SIM_DIR=/x; NTG_DIR="$4"
        if lab_config_parse "$2" >/dev/null 2>&1; then printf "%s" "$NTG_DIR"; else printf "%s" "$4"; fi' \
        _ "$LAB" "$1" "$2" "$3"
}
ndt_ntg_dir() {   # same arguments, ndt's copy of the rule with the trust gate passed
    FX_TRUST=1 FX_CONF="$1" FX_DEFAULT_KERNEL_DIR="$2" FX_DEFAULT_NTG_DIR="$3" inner 'lab_ntg_dir'
}

# ==============================================================================================
section "1. the default is the helper's, and it is the path ndt always edited"
HELPER_DEFAULT="$(sed -n 's/^LAB_DEFAULT_NTG_DIR=//p' "$LAB" | head -1)"
NDT_DEFAULT="$(sed -n 's/^LAB_DEFAULT_NTG_DIR=//p' "$NDT" | head -1)"
check "🔴 ndt's default NTG_DIR is the helper's default"        "$HELPER_DEFAULT" "$NDT_DEFAULT"
check "  and it is not empty"                                    "yes" "$([[ -n "$HELPER_DEFAULT" ]] && echo yes || echo no)"
check "  default YAML = the literal ndt used before (unchanged where nothing is configured)" \
      "/home/adam/Network-Traffic-Generator/setting/Mininet.yaml" "$NDT_DEFAULT/setting/Mininet.yaml"

# ==============================================================================================
section "2. ndt ntg reads and edits the YAML under the NTG_DIR in force"
check "🔴 no config file -> the default checkout's mode is reported" \
      "NTG mode: cli" "$(inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"

printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/otherkernel" "$FIX/ntg" > "$FIX/conf/both.conf"
chmod 644 "$FIX/conf/both.conf"
check "🔴 a trusted config's NTG_DIR -> that checkout's mode is reported" \
      "NTG mode: prompt" "$(FX_TRUST=1 FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"
mk_ntg "$FIX/defntg" prompt     # so that an edit of the wrong checkout would show
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 ndt ntg cli edits THAT checkout's YAML"    "cli"    "$(mode_in "$FIX/ntg")"
check "  and leaves the default checkout alone"     "prompt" "$(mode_in "$FIX/defntg")"
mk_ntg "$FIX/defntg" cli
has   "  and says which file it edited"             "edited $FIX/ntg/setting/Mininet.yaml" "$out"
check "  rc 0"                                      "RC=0"   "$(grep -m1 '^RC=' <<<"$out")"
check "  the rest of the YAML is untouched" \
      "$(printf 'Mininet:\n  cli:\n    mode: "cli" \n  other: 1')" "$(cat "$FIX/ntg/setting/Mininet.yaml")"
mk_ntg "$FIX/ntg" prompt

# 🔴 The real trust gate, not stubbed: a config this user owns is the helper's REFUSED case, so
# the helper runs on its default NTG_DIR and ndt must edit that one, not the one the file names.
check "🔴 a config this user owns is refused -> the default checkout, as in the helper" \
      "NTG mode: cli" "$(FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"

# ==============================================================================================
section "3. a missing YAML is named together with where its NTG_DIR came from"
out="$(FX_DEFAULT_NTG_DIR="$FIX/nowhere" inner 'cmd_ntg; echo RC=$?')"
has   "🔴 the missing file is named"                 "$FIX/nowhere/setting/Mininet.yaml" "$out"
has   "  NTG_DIR and its source: the built-in default" "NTG_DIR=$FIX/nowhere (built-in default" "$out"
check "  rc 1"                                       "RC=1" "$(grep -m1 '^RC=' <<<"$out")"

printf 'NTG_DIR=%s\n' "$FIX/ntg-gone" > "$FIX/conf/gone.conf"
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/gone.conf" inner 'cmd_ntg prompt; echo RC=$?')"
has   "🔴 a config-chosen NTG_DIR names the config file" "NTG_DIR=$FIX/ntg-gone (from $FIX/conf/gone.conf)" "$out"
check "  rc 1, and nothing was created"             "RC=1 no" \
      "$(grep -m1 '^RC=' <<<"$out") $([[ -e "$FIX/ntg-gone" ]] && echo yes || echo no)"

out="$(FX_CONF="$FIX/conf/gone.conf" FX_DEFAULT_NTG_DIR="$FIX/nowhere" inner 'cmd_ntg; echo RC=$?')"
has   "🔴 a refused config is named as refused, not silently replaced" "was REFUSED" "$out"

printf 'KERNEL_DIR=%s\n' "$FIX/otherkernel" > "$FIX/conf/kernel_only.conf"
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/kernel_only.conf" FX_DEFAULT_NTG_DIR="$FIX/nowhere" inner 'cmd_ntg; echo RC=$?')"
has   "🔴 an accepted config without NTG_DIR is named as such, not as refused" "sets no NTG_DIR" "$out"

# 🔴 The helper reads the file as root and ndt as the operator. A root-owned 0600 file passes the
#    trust gate on both sides, the helper uses its NTG_DIR, and ndt cannot read it: that is an
#    answer nobody here has, so the verb refuses before it touches any checkout.
printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/otherkernel" "$FIX/ntg" > "$FIX/conf/unreadable.conf"
chmod 000 "$FIX/conf/unreadable.conf"
mk_ntg "$FIX/defntg" prompt     # so that falling back to the default and editing it would show
before="$(mode_in "$FIX/ntg") $(mode_in "$FIX/defntg")"
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/unreadable.conf" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 a trusted config this user cannot read -> rc 1"  "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
check "  and neither checkout was edited"                  "$before" "$(mode_in "$FIX/ntg") $(mode_in "$FIX/defntg")"
has   "  and it says the file is not readable"             "not readable" "$out"
chmod 644 "$FIX/conf/unreadable.conf"
mk_ntg "$FIX/defntg" cli

# ==============================================================================================
section "4. ndt's copy of the rule agrees with the helper's parser, file by file"
# 🔴 Each fixture is handed to BOTH: the helper's lab_config_parse (sourced, never run) and ndt's
# lab_ntg_dir. A copy that drifts is guaranteed eventually; this is where it shows.
DK="$FIX/kernel"; DN="$FIX/defntg"
printf 'NTG_DIR=%s\n' "$FIX/ntg"                                            > "$FIX/conf/ntg_only.conf"
printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/otherkernel" "$FIX/ntg"         > "$FIX/conf/both.conf"
printf 'NTG_DIR=%s\nWHAT=1\n' "$FIX/ntg"                                     > "$FIX/conf/badkey.conf"
printf 'NTG_DIR=relative/ntg\n'                                              > "$FIX/conf/relative.conf"
printf 'NTG_DIR=%s/../ntg\n' "$FIX/kernel"                                   > "$FIX/conf/dots.conf"
printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/nosuchkernel" "$FIX/ntg"          > "$FIX/conf/kernel_gone.conf"
printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/nobridge" "$FIX/ntg"              > "$FIX/conf/kernel_nobridge.conf"
printf 'NTG_DIR=%s\nNTG_DIR=%s\n' "$FIX/defntg" "$FIX/ntg"                   > "$FIX/conf/twice.conf"
printf '  NTG_DIR = %s  \r\n' "$FIX/ntg"                                     > "$FIX/conf/spaces_crlf.conf"
printf '# a comment\n\nNTG_DIR=%s\n' "$FIX/ntg"                              > "$FIX/conf/comment.conf"
printf 'KERNEL_DIR=%s\n' "$FIX/otherkernel"                                  > "$FIX/conf/kernel_only.conf"
printf 'NTG_DIR %s\n' "$FIX/ntg"                                             > "$FIX/conf/no_equals.conf"
printf 'NTG_DIR=%s\n' "$FIX/nobridge"                                        > "$FIX/conf/not_a_checkout.conf"
: > "$FIX/conf/empty.conf"
for c in ntg_only both badkey relative dots kernel_gone kernel_nobridge twice spaces_crlf \
         comment kernel_only no_equals not_a_checkout empty; do
    check "  $c.conf" "$(helper_ntg_dir "$FIX/conf/$c.conf" "$DK" "$DN")" \
          "$(ndt_ntg_dir "$FIX/conf/$c.conf" "$DK" "$DN")"
done
# 🔴 The case a per-key reader gets wrong: the file sets only NTG_DIR, and the helper's
# post-condition is on the DEFAULT KERNEL_DIR -- where that tree is not there, the whole file is
# refused and NTG_DIR stays the default.
check "🔴 NTG_DIR only, default KERNEL_DIR missing -> the helper refuses the file, so does ndt" \
      "$(helper_ntg_dir "$FIX/conf/ntg_only.conf" "$FIX/nosuchkernel" "$DN")" \
      "$(ndt_ntg_dir "$FIX/conf/ntg_only.conf" "$FIX/nosuchkernel" "$DN")"
# Controls: the comparison above is not two copies of "always the default" agreeing.
check "  control: the helper adopts a well-formed NTG_DIR"  "$FIX/ntg" "$(helper_ntg_dir "$FIX/conf/ntg_only.conf" "$DK" "$DN")"
check "  control: the helper refuses an unknown key"        "$DN"      "$(helper_ntg_dir "$FIX/conf/badkey.conf" "$DK" "$DN")"
check "  control: the helper refuses when its default KERNEL_DIR is missing" \
      "$DN" "$(helper_ntg_dir "$FIX/conf/ntg_only.conf" "$FIX/nosuchkernel" "$DN")"

# ==============================================================================================
section "5. KERNEL_DIR's answer is unchanged by the shared parser"
check "  lab_conf_kernel_dir on a two-key file"      "$FIX/otherkernel" "$(inner "lab_conf_kernel_dir '$FIX/conf/both.conf'")"
check "  lab_conf_kernel_dir on an NTG_DIR-only file sets nothing" "" "$(inner "lab_conf_kernel_dir '$FIX/conf/ntg_only.conf'")"
check "  lab_conf_kernel_dir refuses an unknown key" "" "$(inner "lab_conf_kernel_dir '$FIX/conf/badkey.conf'")"

printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
(( FAIL == 0 ))
