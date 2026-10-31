#!/usr/bin/env bash
#
# `ndt ntg` edits the YAML of the NTG checkout the P4 bridge uses -- the lab helper's NTG_DIR.
#
# [Co-developed with claude code -- Adam]
#
# `ndt ntg cli|custom_command` flips one line in the NTG checkout's config. The checkout's path
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
# A run on a real fabric found four more ways the verb missed (sections 6-9), and the cases
# around them are in sections 10-14:
#
#   * NTG does not read setting/Mininet.yaml by name. It reads NTG.yaml, whose
#     inventory.options.host_file names the hosts file -- and the NTG checkout used there named
#     setting/Hardware.yaml, which has no Mininet_Testbed entry and so no mode line at all.
#     `ndt ntg cli` edited a file NTG never opened and said it had worked.
#   * the old edit was `s/mode: "?[a-z]*"?/mode: "cli"/`, which stops at the underscore of
#     "custom_command" and wrote `mode: "cli"_command"`. The value is now replaced whole, the
#     rest of the file stays byte-identical, and a mode line that cannot be parsed is refused.
#   * NTG knows `cli` and `custom_command`; `ndt ntg` offered `prompt` and wrote it as a value.
#     `prompt` stays as another name for custom_command, because the manuals use it.
#   * the `up. ready` footer said "Mininet CLI" whatever the topology pane held.
#   * the bridge always hands NTG a Mininet net, so a hosts file without Mininet_Testbed is
#     never right under it: the bridge now hands NTG a temp copy of NTG.yaml naming
#     setting/Mininet.yaml, and `ndt ntg` and the footer read the same answer from the same
#     module (p4_proxy/mininet/ntg_config.py). Section 13 drives the bridge's own functions.
#   * a mode NTG would read that is not one plain line, a value NTG does not know, a reused
#     fabric, a hosts file that also lists a hardware testbed, and a file that cannot be read or
#     written each used to produce a confident wrong answer (sections 9-12). Section 14 compares
#     the reading with nornir's own loader where nornir is installed, and runs the module on
#     copies of the two files NTG ships at 6e3f388 where that checkout is here.
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
#    covers the gate itself. Section 14's shipped-files case READS one NTG checkout's git
#    history (`git show 6e3f388:<path>` into the temp dir) and writes nothing there.
#
# Run:  bash tests/shell/test_ndt_ntg_mode.sh
# Env:  NDT_UNDER_TEST=<path>  NDTWIN_LAB_UNDER_TEST=<path>   (a mutation gate points these at copies)
#       The module and the bridge are taken from the tree NDT_UNDER_TEST sits in
#       (<tree>/tools/test_workflow/ndt -> <tree>/p4_proxy/mininet/).
#       NTG_TEST_PY=<python with nornir> for section 14; without one that part is skipped and
#       says so. NTG_CHECKOUT=<NTG git checkout> for the shipped-files case (default: ndt's
#       default NTG_DIR); without commit 6e3f388 there, that case is skipped and says so.
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="${NDT_UNDER_TEST:-$REPO/tools/test_workflow/ndt}"
LAB="${NDTWIN_LAB_UNDER_TEST:-$REPO/tools/test_workflow/ndtwin-lab}"
[[ -r "$NDT" ]] || { echo "no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 2; }
[[ -r "$LAB" ]] || { echo "no ndtwin-lab at $LAB"; echo "Ran 1 checks, 1 failed"; exit 2; }
# [Co-developed with claude code -- Adam]
TREE="$(cd "$(dirname "$NDT")/../.." && pwd)"
MOD="$TREE/p4_proxy/mininet/ntg_config.py"
BRIDGE="$TREE/p4_proxy/mininet/ntg_bmv2_topo.py"

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
hasnt() { if [[ "$3" != *"$2"* ]]; then echo "  ok       $1"; PASS=$((PASS+1)); else echo "  FAILED   $1"; echo "             unwanted: $2"; FAIL=$((FAIL+1)); fi; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d /tmp/ndt-ntgmode-XXXXXX)"
cleanup_all() { [[ -n "${FIX:-}" && "$FIX" == /tmp/ndt-ntgmode-* ]] && rm -rf "${FIX:?}"; return 0; }
trap cleanup_all EXIT INT TERM

mk_kernel() { mkdir -p "$1/p4_proxy/mininet" && : > "$1/p4_proxy/mininet/ntg_bmv2_topo.py"; }
# The three files in the shapes NTG ships them: NTG.yaml naming a hosts file, a Mininet.yaml whose
# comment line mentions both words and whose value carries a trailing blank, and a Hardware.yaml
# with no Mininet_Testbed entry.
mininet_yaml() {   # <mode>
    printf -- '---\nMininet_Testbed:\n  data:\n    # options: cli(Mininet'"'"'s cli) or custom_command(Our own cli)\n    ndtwin_kernel: "http://127.0.0.1:8000"\n    mode: "%s" \n    log_level: "DEBUG"  # TRACE, DEBUG\n' "$1"
}
ntg_yaml() {       # <host_file value>
    printf -- '---\n# From nornir\ninventory:\n  plugin: SimpleInventory\n  options:\n    host_file: "%s"\n    group_file: "./setting/API_server_startup.yaml"\n\nrunner:\n  plugin: threaded\n' "$1"
}
mk_ntg() {    # <dir> <mode> [host_file value, default ./setting/Mininet.yaml]
    mkdir -p "$1/setting"
    : > "$1/network_traffic_generator.py"
    ntg_yaml "${3:-./setting/Mininet.yaml}" > "$1/NTG.yaml"
    mininet_yaml "$2" > "$1/setting/Mininet.yaml"
    printf -- '---\nHardware_Testbed:\n  data:\n    ndtwin_kernel: "http://10.0.0.2:8000"\n    log_level: "DEBUG"\n\nworker_node1:\n  hostname: 10.0.0.5\n  data:\n    worker_node_server: "http://10.0.0.5:8000"\n' \
        > "$1/setting/Hardware.yaml"
}
# The value on the mode line, quotes included, trailing blanks dropped: `"cli"`, or the broken
# `"cli"_command"` the old edit wrote, which a reader that stops at [a-z]* would call `cli`.
mode_in() { sed -n 's/^ *mode:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "${2:-$1/setting/Mininet.yaml}" | head -1; }

mkdir -p "$FIX/conf"
mk_kernel "$FIX/kernel"          # stands in for the helper's default KERNEL_DIR
mk_kernel "$FIX/otherkernel"
mkdir -p "$FIX/nobridge"
mk_ntg "$FIX/defntg" cli         # stands in for the helper's default NTG_DIR
mk_ntg "$FIX/ntg" custom_command # the checkout a config file names

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
check "  default NTG_DIR = the checkout ndt used before (unchanged where nothing is configured)" \
      "/home/adam/Network-Traffic-Generator" "$NDT_DEFAULT"

# ==============================================================================================
section "2. ndt ntg reads and edits the YAML under the NTG_DIR in force"
check "🔴 no config file -> the default checkout's mode is reported" \
      "NTG mode: cli" "$(inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"

printf 'KERNEL_DIR=%s\nNTG_DIR=%s\n' "$FIX/otherkernel" "$FIX/ntg" > "$FIX/conf/both.conf"
chmod 644 "$FIX/conf/both.conf"
check "🔴 a trusted config's NTG_DIR -> that checkout's mode is reported" \
      "NTG mode: custom_command" "$(FX_TRUST=1 FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"
mk_ntg "$FIX/defntg" custom_command   # so that an edit of the wrong checkout would show
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 ndt ntg cli edits THAT checkout's YAML"    '"cli"'    "$(mode_in "$FIX/ntg")"
check "  and leaves the default checkout alone"     '"custom_command"' "$(mode_in "$FIX/defntg")"
mk_ntg "$FIX/defntg" cli
has   "  and says which file it edited"             "edited $FIX/ntg/setting/Mininet.yaml" "$out"
check "  rc 0"                                      "RC=0"   "$(grep -m1 '^RC=' <<<"$out")"
check "  the rest of the YAML is untouched" \
      "$(mininet_yaml cli | od -c)" "$(od -c < "$FIX/ntg/setting/Mininet.yaml")"
mk_ntg "$FIX/ntg" custom_command

# 🔴 The real trust gate, not stubbed: a config this user owns is the helper's REFUSED case, so
# the helper runs on its default NTG_DIR and ndt must edit that one, not the one the file names.
check "🔴 a config this user owns is refused -> the default checkout, as in the helper" \
      "NTG mode: cli" "$(FX_CONF="$FIX/conf/both.conf" inner 'cmd_ntg' | grep -m1 'NTG mode:' | sed 's/^[^N]*//')"

# ==============================================================================================
section "3. a missing YAML is named together with where its NTG_DIR came from"
out="$(FX_DEFAULT_NTG_DIR="$FIX/nowhere" inner 'cmd_ntg; echo RC=$?')"
has   "🔴 the missing file is named"                 "$FIX/nowhere/NTG.yaml" "$out"
has   "  NTG_DIR and its source: the built-in default" "NTG_DIR=$FIX/nowhere (built-in default" "$out"
check "  rc 1"                                       "RC=1" "$(grep -m1 '^RC=' <<<"$out")"

printf 'NTG_DIR=%s\n' "$FIX/ntg-gone" > "$FIX/conf/gone.conf"
out="$(FX_TRUST=1 FX_CONF="$FIX/conf/gone.conf" inner 'cmd_ntg custom_command; echo RC=$?')"
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
mk_ntg "$FIX/defntg" custom_command   # so that falling back to the default and editing it would show
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

# ==============================================================================================
section "6. the file NTG reads is the one NTG.yaml's host_file names -- or, under the bridge, setting/Mininet.yaml"
# 🔴 The shipped shape: NTG.yaml names setting/Hardware.yaml, which has no Mininet_Testbed entry.
# Under the bridge that left NTG in its hardware-testbed mode on a Mininet net -- the failure
# measured on a real fabric. The bridge now hands NTG setting/Mininet.yaml instead (section 13),
# so that is the file `ndt ntg` must report and edit; NTG.yaml and Hardware.yaml stay as they were.
H="$FIX/hw"; mk_ntg "$H" custom_command ./setting/Hardware.yaml
sums() { sha256sum "$1/NTG.yaml" "$1/setting/Mininet.yaml" "$1/setting/Hardware.yaml" | cut -c1-64 | tr '\n' ' '; }
sums2() { sha256sum "$1/NTG.yaml" "$1/setting/Hardware.yaml" | cut -c1-64 | tr '\n' ' '; }
before="$(sums2 "$H")"
out="$(FX_DEFAULT_NTG_DIR="$H" inner 'cmd_ntg; echo RC=$?')"
check "🔴 shipped shape: plain ndt ntg reports setting/Mininet.yaml's mode" \
      "NTG mode: custom_command" "$(grep -m1 'NTG mode:' <<<"$out" | sed 's/^[^N]*//')"
has   "  read from setting/Mininet.yaml"              "read from $H/setting/Mininet.yaml" "$out"
has   "  and it says why: NTG.yaml names Hardware.yaml" "NTG.yaml names $H/setting/Hardware.yaml" "$out"
out="$(FX_DEFAULT_NTG_DIR="$H" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 shipped shape: ndt ntg cli edits setting/Mininet.yaml (rc 0)" '"cli" RC=0' \
      "$(mode_in "$H") $(grep -m1 '^RC=' <<<"$out")"
check "  and NTG.yaml and Hardware.yaml are byte-identical" "$before" "$(sums2 "$H")"
has   "  and it names the file it edited"            "edited $H/setting/Mininet.yaml" "$out"

# Without a setting/Mininet.yaml to fall back on there is no mode line anywhere: refuse.
H2="$FIX/hwonly"; mk_ntg "$H2" custom_command ./setting/Hardware.yaml; rm -f "$H2/setting/Mininet.yaml"
before="$(sums2 "$H2")"
out="$(FX_DEFAULT_NTG_DIR="$H2" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 no Mininet_Testbed anywhere -> ndt ntg cli refuses (rc 1)" "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
check "  and no file in the checkout was edited, none created" "$before no" \
      "$(sums2 "$H2") $([[ -e "$H2/setting/Mininet.yaml" ]] && echo yes || echo no)"
has   "  and it names NTG.yaml"                      "$H2/NTG.yaml" "$out"
has   "  and the file NTG.yaml points at"            "$H2/setting/Hardware.yaml" "$out"
hasnt "  and it does not say it edited anything"     "edited $H2" "$out"
out="$(FX_DEFAULT_NTG_DIR="$H2" inner 'cmd_ntg; echo RC=$?')"
has   "  plain ndt ntg says NTG reads Hardware.yaml, not a mode"  "$H2/setting/Hardware.yaml" "$out"
hasnt "  and does not report a mode"                               "NTG mode: c" "$out"
hasnt "  and does not offer a change that would be refused"       "change it with" "$out"

# A host_file elsewhere: the edit goes there and setting/Mininet.yaml stays as it was.
E="$FIX/elsewhere"; mk_ntg "$E" custom_command "$FIX/elsewhere-hosts.yaml"
mininet_yaml custom_command > "$FIX/elsewhere-hosts.yaml"
out="$(FX_DEFAULT_NTG_DIR="$E" inner 'cmd_ntg cli; echo RC=$?')"
check "🔴 an absolute host_file is the file edited"  '"cli"' "$(mode_in x "$FIX/elsewhere-hosts.yaml")"
check "  and setting/Mininet.yaml is left alone"     '"custom_command"' "$(mode_in "$E")"
has   "  and the message names the file edited"      "edited $FIX/elsewhere-hosts.yaml" "$out"
hasnt "  and does not call it a sibling repo's"      "sibling repo" "$out"

# Relative host_file: relative to the NTG checkout, which is the bridge's cwd when NTG starts.
R="$FIX/rel"; mk_ntg "$R" custom_command setting/other.yaml
mininet_yaml custom_command > "$R/setting/other.yaml"
FX_DEFAULT_NTG_DIR="$R" inner 'cmd_ntg cli' >/dev/null
check "  a relative host_file resolves under the NTG checkout" '"cli" "custom_command"' \
      "$(mode_in x "$R/setting/other.yaml") $(mode_in "$R")"

# The spellings of the host_file line NTG accepts, each naming setting/other.yaml (in cli) while
# setting/Mininet.yaml says custom_command: the report says cli only if the line was read.
for shape in single bare comment crlf nofinal; do
    Q="$FIX/hf-$shape"; mk_ntg "$Q" custom_command
    mininet_yaml cli > "$Q/setting/other.yaml"
    case "$shape" in
        single)  ntg_yaml x | sed "s|host_file: \"x\"|host_file: './setting/other.yaml'|" > "$Q/NTG.yaml" ;;
        bare)    ntg_yaml x | sed 's|host_file: "x"|host_file: setting/other.yaml|' > "$Q/NTG.yaml" ;;
        comment) ntg_yaml x | sed 's|host_file: "x"|host_file: "./setting/other.yaml"   # the hosts|' > "$Q/NTG.yaml" ;;
        crlf)    ntg_yaml ./setting/other.yaml | sed 's/$/\r/' > "$Q/NTG.yaml" ;;
        nofinal) ntg_yaml ./setting/other.yaml | head -c -1 > "$Q/NTG.yaml"
                 mininet_yaml cli | head -c -1 > "$Q/setting/other.yaml" ;;
    esac
    out="$(FX_DEFAULT_NTG_DIR="$Q" inner 'cmd_ntg; echo RC=$?')"
    check "  host_file $shape -> the file it names is read" "NTG mode: cli $Q/setting/other.yaml" \
          "$(grep -m1 'NTG mode:' <<<"$out" | sed 's/^[^N]*//') $(grep -o "$Q/setting/other.yaml" <<<"$out" | head -1)"
done

# Cannot be resolved: refuse, name NTG.yaml, edit nothing. Not a guess at setting/Mininet.yaml.
U="$FIX/unres"
for shape in missing twice tilde plugin empty; do
    rm -rf "$U"; mk_ntg "$U" custom_command
    mininet_yaml custom_command > "$U/setting/other.yaml"
    case "$shape" in
        missing) printf -- '---\ninventory:\n  plugin: SimpleInventory\n' > "$U/NTG.yaml" ;;
        # The first names a file with no Mininet_Testbed, the last an editable one: a reader that
        # keeps the last line would edit setting/other.yaml and say it worked.
        twice)   printf -- '---\ninventory:\n  options:\n    host_file: "./setting/Hardware.yaml"\n    host_file: "./setting/other.yaml"\n' > "$U/NTG.yaml" ;;
        # ~ is root's home under the bridge. A file at <checkout>/~/hosts.yaml is there so that a
        # reader that does not stop at ~ finds something to edit.
        tilde)   ntg_yaml '~/hosts.yaml' > "$U/NTG.yaml"
                 mkdir -p "$U/~"; mininet_yaml custom_command > "$U/~/hosts.yaml" ;;
        plugin)  ntg_yaml ./setting/Mininet.yaml | sed 's/SimpleInventory/SomeOtherInventory/' > "$U/NTG.yaml" ;;
        empty)   ntg_yaml x | sed 's|host_file: "x"|host_file:|' > "$U/NTG.yaml" ;;
    esac
    usums() { sums "$U"; sha256sum "$U/setting/other.yaml" | cut -c1-64; [[ -f "$U/~/hosts.yaml" ]] && sha256sum "$U/~/hosts.yaml" | cut -c1-64; }
    before="$(usums)"
    out="$(FX_DEFAULT_NTG_DIR="$U" inner 'cmd_ntg cli; echo RC=$?')"
    check "🔴 NTG.yaml host_file $shape -> refused, nothing edited" "RC=1 $before" \
          "$(grep -m1 '^RC=' <<<"$out") $(usums)"
    has   "  ($shape) and the refusal names NTG.yaml" "$U/NTG.yaml" "$out"
    hasnt "  ($shape) and no python traceback reaches the operator" "Traceback" "$out"
    case "$shape" in
        twice) has "  (twice) and says there are two host_file lines" "2 inventory.options.host_file lines" "$out" ;;
        tilde) has "  (tilde) and says why: it starts with ~"         "starts with ~" "$out" ;;
        empty) has "  (empty) and names the line it cannot read"      "line 6: its host_file value cannot be read" "$out" ;;
    esac
done
rm -rf "$U"; mk_ntg "$U" custom_command; rm -f "$U/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$U" inner 'cmd_ntg cli; echo RC=$?')"
check "  host_file names a file that is not there -> rc 1" "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
has   "  and both files are named"                 "$U/setting/Mininet.yaml" "$out"
has   "  (NTG.yaml too)"                           "$U/NTG.yaml" "$out"

# ==============================================================================================
section "7. the value is replaced whole; everything else stays byte-identical"
V="$FIX/val"
mk_ntg "$V" custom_command
FX_DEFAULT_NTG_DIR="$V" inner 'cmd_ntg cli' >/dev/null
check "🔴 custom_command -> cli writes \"cli\", not \"cli\"_command\"" '"cli"' "$(mode_in "$V")"
check "  and the file is the shipped file with that one value changed" \
      "$(mininet_yaml cli | od -c)" "$(od -c < "$V/setting/Mininet.yaml")"

# Single quotes, a trailing comment and CRLF line ends: the quote style and every other byte stay.
printf -- "---\r\nMininet_Testbed:\r\n  data:\r\n    mode: 'custom_command'   # pick one\r\n    log_level: \"DEBUG\"\r\n" > "$V/setting/Mininet.yaml"
FX_DEFAULT_NTG_DIR="$V" inner 'cmd_ntg cli' >/dev/null
check "🔴 quote style, comment and CRLF survive the edit" \
      "$(printf -- "---\r\nMininet_Testbed:\r\n  data:\r\n    mode: 'cli'   # pick one\r\n    log_level: \"DEBUG\"\r\n" | od -c)" \
      "$(od -c < "$V/setting/Mininet.yaml")"

# The line the old edit left behind cannot be parsed: refuse and leave it for a person.
mininet_yaml cli > "$V/setting/Mininet.yaml"
sed -i 's/mode: "cli" /mode: "cli"_command" /' "$V/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$V" inner 'cmd_ntg; echo RC=$?')"
hasnt "  plain ndt ntg does not read the broken line as cli" "NTG mode: cli" "$out"
before="$(sha256sum < "$V/setting/Mininet.yaml")"
out="$(FX_DEFAULT_NTG_DIR="$V" inner 'cmd_ntg prompt; echo RC=$?')"
check "🔴 an unparseable mode line is refused (rc 1) and the file is unchanged" "RC=1 $before" \
      "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$V/setting/Mininet.yaml")"
has   "  and the refusal names the file"           "$V/setting/Mininet.yaml" "$out"
hasnt "  and does not say it edited it"            "edited $V" "$out"

# Two mode lines under Mininet_Testbed: which one NTG keeps is the YAML loader's business; refuse.
{ mininet_yaml custom_command; printf '    mode: "cli"\n'; } > "$V/setting/Mininet.yaml"
before="$(sha256sum < "$V/setting/Mininet.yaml")"
out="$(FX_DEFAULT_NTG_DIR="$V" inner 'cmd_ntg cli; echo RC=$?')"
check "  two mode lines -> refused, file unchanged" "RC=1 $before" \
      "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$V/setting/Mininet.yaml")"

# ==============================================================================================
section "8. the words: cli and custom_command, with prompt kept as custom_command's other name"
W="$FIX/words"
mk_ntg "$W" cli
out="$(FX_DEFAULT_NTG_DIR="$W" inner 'cmd_ntg custom_command; echo RC=$?')"
check "🔴 ndt ntg custom_command writes NTG's own word" '"custom_command" RC=0' \
      "$(mode_in "$W") $(grep -m1 '^RC=' <<<"$out")"
mk_ntg "$W" cli
FX_DEFAULT_NTG_DIR="$W" inner 'cmd_ntg prompt' >/dev/null
check "🔴 ndt ntg prompt writes custom_command, not \"prompt\"" '"custom_command"' "$(mode_in "$W")"
out="$(FX_DEFAULT_NTG_DIR="$W" inner 'cmd_ntg prompt; echo RC=$?')"
has   "  and asking again says it is already set"  "already custom_command" "$out"
out="$(FX_DEFAULT_NTG_DIR="$W" inner 'cmd_ntg')"
check "  plain ndt ntg reports the word whole"      "NTG mode: custom_command" \
      "$(grep -m1 'NTG mode:' <<<"$out" | sed 's/^[^N]*//')"
has   "  and offers the word NTG knows"             "ndt ntg cli|custom_command" "$out"
has   "  and says which file it read"               "$W/setting/Mininet.yaml" "$out"
out="$(FX_DEFAULT_NTG_DIR="$W" inner 'cmd_ntg bogus; echo RC=$?')"
check "  an unknown word is a usage error (rc 2)"   "RC=2" "$(grep -m1 '^RC=' <<<"$out")"
has   "  whose usage line names both words"         "cli|custom_command" "$out"
check "  ndt help names both words"                 "1" "$(grep -c '^  ntg \[cli|custom_command\]' "$NDT")"

# ==============================================================================================
section "9. the 'up. ready' footer names what the topology pane holds"
ATT='sudo tmux -L ndtwinlab attach -t topo'
F="$FIX/foot"
mk_ntg "$F" cli
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 fresh')"
has   "  cli -> Mininet CLI, as before"             "proxy :8081   kernel :8000   Mininet CLI: $ATT" "$out"
check "  and nothing more"                          "1" "$(grep -c . <<<"$out")"
mk_ntg "$F" custom_command
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 fresh')"
hasnt "🔴 custom_command -> the footer does not say Mininet CLI" "Mininet CLI" "$out"
has   "  it says NTG's prompt is there"             "NTG prompt" "$out"
has   "  and still gives the attach command"        "$ATT" "$out"
# The way back to mininet> needs a NEW fabric: `ndt up p4` on a running one of the same size
# reuses it. The hint says so, on its own line under the attach command.
check "🔴 the hint is its own line, and says 'ndt down' before up" \
      "for Mininet's CLI: 'ndt ntg cli', then 'ndt down' and up again" \
      "$(sed -n '2p' <<<"$out" | sed 's/^[^f]*//')"
hasnt "  and the attach line carries no hint"       "ndt ntg" "$(head -1 <<<"$out")"
mk_ntg "$F" custom_command ./setting/Hardware.yaml
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 fresh')"
has   "🔴 shipped shape -> the bridge's file decides: NTG prompt" "NTG prompt" "$out"
rm -f "$F/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 fresh')"
hasnt "🔴 no Mininet_Testbed anywhere -> not Mininet CLI either" "Mininet CLI" "$out"
has   "  and it says there is no mininet>"          "no mininet>" "$out"
printf -- '---\ninventory:\n  plugin: SimpleInventory\n' > "$F/NTG.yaml"
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 fresh')"
has   "  unresolvable -> says it does not know"     "NTG mode unknown" "$out"
# 🔴 A REUSED FABRIC: its pane holds what NTG read when it started, not what the config says now.
mk_ntg "$F" cli
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4 reused')"
hasnt "🔴 a reused fabric -> no mode is claimed, not even cli's" "Mininet CLI" "$out"
has   "  it says the fabric was reused"             "reused a running fabric" "$out"
has   "  and still gives the attach command"        "$ATT" "$out"
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points p4')"
hasnt "  no second word -> no claim either"         "Mininet CLI" "$out"
check "🔴 the ready line passes on whether up_p4 started the fabric" "1" \
      "$(grep -c 'lab_entry_points p4 "${UP_P4_FABRIC:-}"' "$NDT")"
out="$(FX_DEFAULT_NTG_DIR="$F" inner 'lab_entry_points ovs')"
has   "  the OVS line is unchanged (no NTG there)"  "Ryu :8080   kernel :8000   Mininet CLI: $ATT" "$out"

# 🔴 EVERY label but `Mininet CLI` has a second line that says why, state by state -- the P4 app
# guide tells the reader that line is there.
RS="$FIX/reasons"
reason_of() {   # <ntg_dir> [fresh|reused] -- the second line, trimmed
    FX_DEFAULT_NTG_DIR="$1" inner "lab_entry_points p4 ${2:-fresh}" | sed -n '2s/^ *//p'
}
for st in custom_command unknown hardware nomininet badmode unresolved nohostfile reused; do
    rm -rf "$RS"; mk_ntg "$RS" custom_command
    case "$st" in
        unknown)    mk_ntg "$RS" prompt ;;
        hardware)   printf -- 'Hardware_Testbed:\n  data: {}\n' >> "$RS/setting/Mininet.yaml" ;;
        nomininet)  mk_ntg "$RS" cli ./setting/Hardware.yaml; rm -f "$RS/setting/Mininet.yaml" ;;
        badmode)    printf -- '---\nMininet_Testbed:\n  data: {mode: cli}\n' > "$RS/setting/Mininet.yaml" ;;
        unresolved) printf -- '---\ninventory:\n  plugin: SimpleInventory\n' > "$RS/NTG.yaml" ;;
        nohostfile) rm -f "$RS/setting/Mininet.yaml" ;;
    esac
    when=fresh; [[ "$st" == reused ]] && when=reused
    r="$(reason_of "$RS" "$when")"
    check "🔴 ($st) the footer has a reason line" "yes" "$([[ -n "$r" ]] && echo yes || echo "no (empty)")"
done
# The default: which NTG checkout the lab uses is not known (a trusted config this user cannot read).
printf 'NTG_DIR=%s\n' "$FIX/ntg" > "$FIX/conf/unreadable2.conf"; chmod 000 "$FIX/conf/unreadable2.conf"
r="$(FX_TRUST=1 FX_CONF="$FIX/conf/unreadable2.conf" inner 'lab_entry_points p4 fresh' | sed -n '2s/^ *//p')"
if [[ "$(id -u)" == 0 ]]; then echo "  skipped: running as root, so the config is readable"
else check "🔴 (no NTG checkout known) the footer has a reason line" "yes" "$([[ -n "$r" ]] && echo yes || echo "no (empty)")"; fi
chmod 644 "$FIX/conf/unreadable2.conf"

# ==============================================================================================
section "10. a mode NTG would read that is not one plain line is not 'no mode line'"
# NTG reads data.mode through nornir's YAML loader. A mode key with a space before the colon, in
# flow style, quoted, or arriving through a merge key or an alias is read by NTG and missed by a
# line reader -- which then reported NTG's default, cli, and said "already cli" (rc 0).
NM="$FIX/nomode"
for shape in spacecolon flow quotedkey merge alias; do
    mk_ntg "$NM" cli
    case "$shape" in
        spacecolon) printf -- '---\nMininet_Testbed:\n  data:\n    mode : "custom_command"\n    log_level: "DEBUG"\n' ;;
        flow)       printf -- '---\nMininet_Testbed:\n  data: {mode: custom_command, log_level: DEBUG}\n' ;;
        quotedkey)  printf -- '---\nMininet_Testbed:\n  data:\n    "mode": custom_command\n' ;;
        merge)      printf -- '---\nshared: &s\n  mode: custom_command\nMininet_Testbed:\n  data:\n    <<: *s\n    log_level: "DEBUG"\n' ;;
        alias)      printf -- '---\nshared: &s\n  mode: custom_command\nMininet_Testbed:\n  data: *s\n' ;;
    esac > "$NM/setting/Mininet.yaml"
    before="$(sha256sum < "$NM/setting/Mininet.yaml")"
    out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'cmd_ntg; echo RC=$?')"
    check "🔴 ($shape) plain ndt ntg does not report cli, and is rc 1" "RC=1" \
          "$(grep -m1 '^RC=' <<<"$out")$(grep -q 'NTG mode: cli' <<<"$out" && echo ' and said cli')"
    has   "  ($shape) and names the line"            "line " "$out"
    out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'cmd_ntg cli; echo RC=$?')"
    check "🔴 ($shape) ndt ntg cli refuses, file unchanged" "RC=1 $before" \
          "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$NM/setting/Mininet.yaml")"
    hasnt "  ($shape) and does not say already cli"  "already cli" "$out"
    out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'lab_entry_points p4 fresh')"
    hasnt "🔴 ($shape) the footer does not say Mininet CLI" "Mininet CLI" "$out"
done
# The control: a Mininet_Testbed with truly no mode key IS NTG's default.
printf -- '---\nMininet_Testbed:\n  data:\n    log_level: "DEBUG"   # no mode here\n' > "$NM/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'cmd_ntg; echo RC=$?')"
has   "  control: no mode key at all -> cli, NTG's default" "NTG mode: cli (no mode line" "$out"
out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'cmd_ntg cli; echo RC=$?')"
check "  control: and ndt ntg cli says already cli (rc 0)" "1 RC=0" \
      "$(grep -c 'already cli' <<<"$out") $(grep -m1 '^RC=' <<<"$out")"
out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'lab_entry_points p4 fresh')"
has   "  control: and the footer says Mininet CLI"  "Mininet CLI" "$out"
# A commented-out mode line is not a mode: YAML ignores it, and so must this.
printf -- '---\nMininet_Testbed:\n  data:\n    # mode: "custom_command"\n    ndtwin_kernel: "http://127.0.0.1:8000"   # mode: custom_command\n' > "$NM/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$NM" inner 'cmd_ntg; echo RC=$?')"
check "🔴 a commented mode line is not a mode: cli, NTG's default (rc 0)" "1 RC=0" \
      "$(grep -c 'NTG mode: cli (no mode line' <<<"$out") $(grep -m1 '^RC=' <<<"$out")"

# ==============================================================================================
section "11. a value NTG does not know is reported, and ndt ntg custom_command fixes it"
# An older ndt wrote `mode: "prompt"`. NTG knows cli and custom_command; with any other value it
# raises "configuration is invalid" and the bridge gives up after five tries.
P="$FIX/prompt"; mk_ntg "$P" prompt
out="$(FX_DEFAULT_NTG_DIR="$P" inner 'cmd_ntg; echo RC=$?')"
has   "🔴 mode \"prompt\" is reported as one NTG does not know" "not a mode NTG knows" "$out"
check "  rc 1"                                      "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
has   "  and the fix is named"                      "ndt ntg custom_command" "$out"
out="$(FX_DEFAULT_NTG_DIR="$P" inner 'lab_entry_points p4 fresh')"
check "🔴 the footer claims neither CLI nor prompt" "" \
      "$(grep -oE 'Mininet CLI|NTG prompt' <<<"$out")"
has   "  it says the mode is unknown"               "NTG mode unknown" "$out"
has   "  and how to fix it"                         "'ndt ntg custom_command'" "$out"
out="$(FX_DEFAULT_NTG_DIR="$P" inner 'cmd_ntg custom_command; echo RC=$?')"
check "🔴 ndt ntg custom_command rewrites it (rc 0)" '"custom_command" RC=0' \
      "$(mode_in "$P") $(grep -m1 '^RC=' <<<"$out")"
check "  the file is the shipped file with that one value changed" \
      "$(mininet_yaml custom_command | od -c)" "$(od -c < "$P/setting/Mininet.yaml")"
mk_ntg "$P" prompt
FX_DEFAULT_NTG_DIR="$P" inner 'cmd_ntg prompt' >/dev/null
check "  and ndt ntg prompt does the same"          '"custom_command"' "$(mode_in "$P")"

# NTG reads Mininet_Testbed first: cli enters Mininet's CLI at once, but any other mode goes on,
# and a Hardware_Testbed entry in the same file then makes NTG drive that hardware testbed.
HB="$FIX/both"; mk_ntg "$HB" custom_command
printf -- 'Hardware_Testbed:\n  data:\n    ndtwin_kernel: "http://10.0.0.2:8000"\n' >> "$HB/setting/Mininet.yaml"
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'lab_entry_points p4 fresh')"
has   "🔴 Mininet_Testbed in custom_command plus Hardware_Testbed -> the hardware label" \
      "NTG hardware-testbed mode, no mininet>" "$out"
hasnt "  not NTG's prompt"                          "NTG prompt" "$out"
has   "  and the line under it says why"            "also has a Hardware_Testbed entry" "$out"
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'cmd_ntg; echo RC=$?')"
has   "  plain ndt ntg says NTG leaves Mininet mode" "but NTG leaves Mininet mode for its hardware-testbed mode" "$out"
before="$(sha256sum < "$HB/setting/Mininet.yaml")"
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'cmd_ntg custom_command; echo RC=$?')"
check "  ndt ntg custom_command does not claim it is already set (rc 1, unchanged)" "RC=1 $before" \
      "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$HB/setting/Mininet.yaml")"
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'cmd_ntg cli; echo RC=$?')"
check "  ndt ntg cli writes cli (rc 0)"             '"cli" RC=0' "$(mode_in "$HB") $(grep -m1 '^RC=' <<<"$out")"
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'lab_entry_points p4 fresh')"
has   "  and in cli the pane is Mininet's CLI, Hardware_Testbed or not" "Mininet CLI" "$out"
# A value NTG does not know, beside Hardware_Testbed: writing custom_command there would leave NTG
# out of Mininet mode just the same, so it is refused like the word that is already there.
for w in custom_command prompt; do
    mk_ntg "$HB" prompt
    printf -- 'Hardware_Testbed:\n  data:\n    ndtwin_kernel: "http://10.0.0.2:8000"\n' >> "$HB/setting/Mininet.yaml"
    before="$(sha256sum < "$HB/setting/Mininet.yaml")"
    out="$(FX_DEFAULT_NTG_DIR="$HB" inner "cmd_ntg $w; echo RC=\$?")"
    check "🔴 prompt plus Hardware_Testbed: ndt ntg $w refuses (rc 1), file unchanged" "RC=1 $before" \
          "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$HB/setting/Mininet.yaml")"
    hasnt "  ($w) and does not say it edited anything" "edited $HB" "$out"
    has   "  ($w) and says why"                     "would still leave" "$out"
done
out="$(FX_DEFAULT_NTG_DIR="$HB" inner 'cmd_ntg cli; echo RC=$?')"
check "  prompt plus Hardware_Testbed: ndt ntg cli writes cli (rc 0)" '"cli" RC=0' \
      "$(mode_in "$HB") $(grep -m1 '^RC=' <<<"$out")"

# ==============================================================================================
section "12. a file that cannot be read or written is named, with the errno"
A="$FIX/perm"
if [[ "$(id -u)" == 0 ]]; then
    echo "  skipped: running as root, so file modes do not refuse anything"
else
    mk_ntg "$A" custom_command; chmod 000 "$A/setting/Mininet.yaml"
    out="$(FX_DEFAULT_NTG_DIR="$A" inner 'cmd_ntg cli; echo RC=$?')"
    check "🔴 an unreadable hosts file -> rc 1"     "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
    has   "  (unreadable) naming the file and the errno" "$A/setting/Mininet.yaml: cannot read it: [Errno 13]" "$out"
    hasnt "  (unreadable) and no python traceback"  "Traceback" "$out"
    out="$(FX_DEFAULT_NTG_DIR="$A" inner 'lab_entry_points p4 fresh')"
    has   "  and the footer says it does not know"  "NTG mode unknown" "$out"
    chmod 644 "$A/setting/Mininet.yaml"
    chmod 444 "$A/setting/Mininet.yaml"
    before="$(sha256sum < "$A/setting/Mininet.yaml")"
    out="$(FX_DEFAULT_NTG_DIR="$A" inner 'cmd_ntg cli; echo RC=$?')"
    check "🔴 an unwritable hosts file -> rc 1, unchanged" "RC=1 $before" \
          "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$A/setting/Mininet.yaml")"
    has   "  (unwritable) naming the file and the errno" "could not edit $A/setting/Mininet.yaml: cannot write it: [Errno 13]" "$out"
    hasnt "  (unwritable) and no python traceback"  "Traceback" "$out"
    hasnt "  and no edit claimed"                   "edited $A" "$out"
    chmod 644 "$A/setting/Mininet.yaml"
    # The substitute file the bridge uses, unreadable to this user: the bridge reads it as root,
    # so "no Mininet testbed, hardware mode" would be a guess, and a wrong one.
    rm -rf "$A"; mk_ntg "$A" custom_command ./setting/Hardware.yaml; chmod 000 "$A/setting/Mininet.yaml"
    out="$(FX_DEFAULT_NTG_DIR="$A" inner 'cmd_ntg; echo RC=$?')"
    check "🔴 an unreadable setting/Mininet.yaml under the shipped shape -> rc 1" "RC=1" "$(grep -m1 '^RC=' <<<"$out")"
    has   "  (fallback) naming the file and the errno"  "$A/setting/Mininet.yaml: cannot read it: [Errno 13]" "$out"
    has   "  (fallback) and why it is that file"        "names $A/setting/Hardware.yaml" "$out"
    hasnt "  (fallback) and not hardware mode"           "hardware" "$out"
    out="$(FX_DEFAULT_NTG_DIR="$A" inner 'lab_entry_points p4 fresh')"
    check "🔴 (fallback) the footer claims no mode, and says it cannot read the file" \
          "topology pane (NTG mode unknown) ndt cannot read NTG's hosts file: see 'ndt ntg'" \
          "$(grep -o 'topology pane (NTG mode unknown)' <<<"$out") $(sed -n '2p' <<<"$out" | sed 's/^ *//')"
    chmod 644 "$A/setting/Mininet.yaml"
fi
# `set` re-reads at write time and writes only from a state it may write from: called directly
# on a file whose mode it cannot read whole, it exits 3 and leaves the file alone.
mk_ntg "$A" custom_command
printf '    other: {mode: cli}\n' >> "$A/setting/Mininet.yaml"
before="$(sha256sum < "$A/setting/Mininet.yaml")"
out="$(python3 "$MOD" set "$A" cli 2>&1; echo "RC=$?")"
check "🔴 the module's set refuses from bad-mode (rc 3), file unchanged" "RC=3 $before" \
      "$(grep -m1 '^RC=' <<<"$out") $(sha256sum < "$A/setting/Mininet.yaml")"
check "  and prints the state it refused from"     "bad-mode" "$(grep -m1 -o '^bad-mode' <<<"$out")"

# ==============================================================================================
section "13. the bridge hands NTG the file ndt reads"
# The bridge's own functions, with Mininet, the topology module and NTG replaced by stubs: what
# config_file_path does NTG's command_line receive, which hosts file does it name, what is in the
# NTG checkout while NTG runs, and what is left afterwards. <mode> says what the stubs do.
bridge_run() {   # <ntg_dir> <mode> [python] -- prints KEY=value lines
    NTG_DIR="$1" "${3:-python3}" - "$BRIDGE" "$2" <<'PY' 2>&1
import importlib.util, io, os, re, sys, types
bridge, mode = sys.argv[1], sys.argv[2]
ntg = os.environ["NTG_DIR"]
for name in ("mininet", "mininet.log", "p4_testbed_topo", "topo_log", "network_traffic_generator",
             "nornir"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["mininet.log"].setLogLevel = lambda *a, **k: None

def tree():
    out = set()
    for d, dirs, files in os.walk(ntg):
        for n in dirs + files:
            out.add(os.path.relpath(os.path.join(d, n), ntg))
    return out

before = tree()
calls = []
def command_line(net, config_file_path="NTG.yaml"):
    exists = os.path.isfile(config_file_path)
    text = open(config_file_path).read() if exists else ""
    calls.append((config_file_path, exists, text, sorted(tree() - before)))
    if mode == "crash-once" and len(calls) == 1:
        raise RuntimeError("a bad flow")
    if mode in ("sysexit", "main-sysexit"):
        raise SystemExit(0)
sys.modules["network_traffic_generator"].command_line = command_line

events = []
class Out(io.TextIOBase):
    def write(self, t):
        if t.strip():
            events.append("print:" + t.strip().splitlines()[0])
            if mode == "print-raises" and t.startswith("[ntg_bmv2_topo]"):
                raise OSError(5, "Input/output error")
        return len(t)

spec = importlib.util.spec_from_file_location("bridge_under_test", bridge)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.time.sleep = lambda s: None
# Every directory the bridge makes, so "gone" is checked on the directory, not only its file.
made = []
real_mkdtemp = m.tempfile.mkdtemp
def recording_mkdtemp(*a, **k):
    d = real_mkdtemp(*a, **k)
    made.append(d)
    return d
m.tempfile.mkdtemp = recording_mkdtemp
if mode == "cfg-raises":
    def boom(*a, **k):
        raise ValueError("a config this cannot read")
    m.ntg_config.config_for_bridge = boom
if mode == "mkdtemp-fails":
    def nodir(*a, **k):
        raise OSError(28, "No space left on device")
    m.tempfile.mkdtemp = nodir

real = sys.stdout
sys.stdout = Out()
try:
    if mode in ("main", "main-sysexit", "print-raises"):
        class Tee:
            path = "topo.log"
            def note(self, t): events.append("tee.note")
            def stop(self): events.append("tee.stop")
            def start(self): events.append("tee.start")
        class Plan:
            ports, package, model, bmv2_host = [1], None, None, None
        tb = m.testbed
        tb.plan_fabric = lambda: Plan()
        tb.reset_for_bring_up = lambda ports: None
        tb.bring_up = lambda *a, **k: (object(), [1], False, "", None)
        tb.MANIFEST_PATH = "manifest"
        tb.install_teardown_signal_handlers = lambda: None
        tb.tear_down = lambda net: events.append("tear_down")
        m.main(tee=Tee())
    else:
        m.run_ntg_cli(object())
except SystemExit:
    events.append("SystemExit")
except Exception as e:
    events.append("raised:%s" % type(e).__name__)
finally:
    sys.stdout = real

path, exists, text, new = calls[0] if calls else ("", False, "", [])
hf = re.search(r'host_file:[ \t]*"?([^"\n]*)"?', text)
hf = hf.group(1) if hf else ""
if hf and not os.path.isabs(hf):
    hf = os.path.join(ntg, re.sub(r"^(\./)+", "", hf))
print("CALLS=%d" % len(calls))
print("CONFIG=" + path)
print("HOSTFILE=" + hf)
print("SAMECONFIG=%s" % all(c[0] == path for c in calls))
print("EXISTED=%s" % all(c[1] for c in calls))
print("NEWFILES=%s" % " ".join(sorted({f for c in calls for f in c[3]})))
print("AFTER=%s" % " ".join(sorted(tree() - before)))
print("MADE=%d" % len(made))
print("TMPGONE=%s" % (not any(os.path.exists(d) for d in made)))
print("RAISED=%s" % ",".join(e for e in events if e.startswith("raised:") or e == "SystemExit"))
print("NOTE=%s" % next((e[6:] for e in events if e.startswith("print:[ntg_bmv2_topo]")), ""))
print("ORDER=%s" % ",".join("note" if e.startswith("print:[ntg_bmv2_topo]") else e
                            for e in events
                            if not e.startswith("print:") or e.startswith("print:[ntg_bmv2_topo]")))
PY
}
B="$FIX/bridge"; mk_ntg "$B" custom_command ./setting/Hardware.yaml
before="$(sums "$B")"
out="$(bridge_run "$B" run)"
check "🔴 shipped shape: NTG gets a config naming setting/Mininet.yaml" \
      "HOSTFILE=$B/setting/Mininet.yaml" "$(grep -m1 '^HOSTFILE=' <<<"$out")"
hasnt "  and it is not NTG.yaml itself"             "CONFIG=$B/NTG.yaml" "$out"
check "  and the checkout's three files are byte-identical" "$before" "$(sums "$B")"
check "🔴 no new file or dir in the NTG checkout while NTG runs, nor after" "NEWFILES= AFTER=" \
      "$(grep -m1 '^NEWFILES=' <<<"$out") $(grep -m1 '^AFTER=' <<<"$out")"
check "  and the temp copy is gone after NTG returns" "TMPGONE=True" "$(grep -m1 '^TMPGONE=' <<<"$out")"
has   "🔴 the bridge prints its note: which file NTG gets and why" \
      "NOTE=[ntg_bmv2_topo] $B/NTG.yaml names $B/setting/Hardware.yaml, which has no Mininet_Testbed entry" "$out"
ndt_host="$(FX_DEFAULT_NTG_DIR="$B" inner 'ntg_config probe "$LAB_DEFAULT_NTG_DIR"; printf "HOST=%s\n" "$NTG_HOST"' | grep -m1 '^HOST=')"
hf="$(grep -m1 '^HOSTFILE=' <<<"$out")"
check "🔴 ndt reads the file the bridge hands NTG"   "HOST=${hf#HOSTFILE=}" "$ndt_host"

out="$(bridge_run "$B" crash-once)"
check "🔴 crash re-entry: NTG is entered again with the same temp config, still there" \
      "CALLS=2 SAMECONFIG=True EXISTED=True TMPGONE=True" \
      "$(grep -m1 '^CALLS=' <<<"$out") $(grep -m1 '^SAMECONFIG=' <<<"$out") $(grep -m1 '^EXISTED=' <<<"$out") $(grep -m1 '^TMPGONE=' <<<"$out")"
out="$(bridge_run "$B" sysexit)"
check "🔴 SystemExit out of NTG (the teardown signal) still removes the temp dir" \
      "TMPGONE=True" "$(grep -m1 '^TMPGONE=' <<<"$out")"
hasnt "  (and NTG did get the temp config)"         "CONFIG=$B/NTG.yaml" "$out"
out="$(bridge_run "$B" cfg-raises)"
check "🔴 config_for_bridge raising: NTG still starts, on NTG.yaml as it is" \
      "CALLS=1 CONFIG=$B/NTG.yaml" "$(grep -m1 '^CALLS=' <<<"$out") $(grep -m1 '^CONFIG=' <<<"$out")"
has   "  and the note says ntg_config failed"      "NOTE=[ntg_bmv2_topo] ntg_config failed (ValueError" "$out"
# The teardown signal reaches main as SystemExit while NTG runs: main made the temp dir, and
# main's own finally must remove the DIRECTORY, not leave an empty one behind.
out="$(bridge_run "$B" main-sysexit)"
check "🔴 SystemExit through main: NTG had the temp config, and its directory is gone" \
      "MADE=1 TMPGONE=True RAISED=SystemExit" \
      "$(grep -m1 '^MADE=' <<<"$out") $(grep -m1 '^TMPGONE=' <<<"$out") $(grep -m1 '^RAISED=' <<<"$out")"
hasnt "  (NTG.yaml was not what it got)"           "CONFIG=$B/NTG.yaml" "$out"
# A note that cannot be printed (a broken stdout) ends the bridge -- and takes the temp dir with it.
out="$(bridge_run "$B" print-raises)"
check "🔴 a note that cannot be printed: the error surfaces and the temp dir is gone" \
      "MADE=1 TMPGONE=True RAISED=raised:OSError" \
      "$(grep -m1 '^MADE=' <<<"$out") $(grep -m1 '^TMPGONE=' <<<"$out") $(grep -m1 '^RAISED=' <<<"$out")"
out="$(bridge_run "$B" mkdtemp-fails)"
check "🔴 a temp dir that cannot be made: NTG still starts, on NTG.yaml as it is" \
      "CALLS=1 CONFIG=$B/NTG.yaml" "$(grep -m1 '^CALLS=' <<<"$out") $(grep -m1 '^CONFIG=' <<<"$out")"
has   "  and the note names the error"             "NOTE=[ntg_bmv2_topo] ntg_config failed (OSError(28" "$out"
out="$(bridge_run "$B" main)"
check "🔴 main prints the note while the tee still runs, so topo.log records it" \
      "ORDER=note,tee.note,tee.stop,tee.start,tear_down" "$(grep -m1 '^ORDER=' <<<"$out")"
check "  and NTG got the temp config, which main removes" "TMPGONE=True" "$(grep -m1 '^TMPGONE=' <<<"$out")"
hasnt "  (NTG.yaml was not what it got)"           "CONFIG=$B/NTG.yaml" "$out"

mk_ntg "$B" cli
out="$(bridge_run "$B" run)"
check "  a Mininet hosts file named -> NTG.yaml as it is" "CONFIG=$B/NTG.yaml" "$(grep -m1 '^CONFIG=' <<<"$out")"
check "  and no note"                               "NOTE=" "$(grep -m1 '^NOTE=' <<<"$out")"
ndt_host="$(FX_DEFAULT_NTG_DIR="$B" inner 'ntg_config probe "$LAB_DEFAULT_NTG_DIR"; printf "HOST=%s\n" "$NTG_HOST"' | grep -m1 '^HOST=')"
check "  and ndt reads the same file"               "HOST=$B/setting/Mininet.yaml" "$ndt_host"

# ==============================================================================================
section "14. ndt's reading agrees with NTG's own loader (nornir), fixture by fixture"
NPY=""
for c in "${NTG_TEST_PY:-}" "$REPO/p4_proxy/venv/bin/python" "${HOME:-/nonexistent}/miniconda3/envs/ntg-env/bin/python"; do
    [[ -n "$c" && -x "$c" ]] && "$c" -c 'import nornir' >/dev/null 2>&1 && { NPY="$c"; break; }
done
if [[ -z "$NPY" ]]; then
    echo "  skipped: no python with nornir here (set NTG_TEST_PY=<NTG's interpreter> to run it)"
else
    echo "  NTG's loader from: $NPY"
    D="$FIX/diff"; mkdir -p "$D"
    dfix() {   # <name> <host_file value> <hosts-file content> -- a checkout whose NTG.yaml names it
        mk_ntg "$D/$1" custom_command "$2"
        [[ -n "$3" ]] && printf -- "$3" > "$D/$1/setting/hosts.yaml"
    }
    dfix shipped     ./setting/Hardware.yaml ''
    dfix plain       ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    mode: "cli"\n'
    dfix single      ./setting/hosts.yaml "---\nMininet_Testbed:\n  data:\n    mode: 'custom_command'  # x\n"
    dfix barevalue   ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    mode: cli\n'
    dfix crlfhosts   ./setting/hosts.yaml '---\r\nMininet_Testbed:\r\n  data:\r\n    mode: "cli"\r\n'
    dfix nomode      ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    log_level: "DEBUG"\n'
    dfix prompt      ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    mode: "prompt"\n'
    dfix absolute    "$D/absolute/setting/hosts.yaml" '---\nMininet_Testbed:\n  data:\n    mode: "cli"\n'
    dfix spacecolon  ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    mode : "custom_command"\n'
    dfix flow        ./setting/hosts.yaml '---\nMininet_Testbed:\n  data: {mode: custom_command}\n'
    dfix quotedkey   ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    "mode": custom_command\n'
    dfix merge       ./setting/hosts.yaml '---\nshared: &s\n  mode: custom_command\nMininet_Testbed:\n  data:\n    <<: *s\n'
    dfix commented   ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    # mode: "custom_command"\n    log_level: "DEBUG"\n'
    dfix both        ./setting/hosts.yaml '---\nMininet_Testbed:\n  data:\n    mode: "custom_command"\nHardware_Testbed:\n  data:\n    log_level: "DEBUG"\n'
    for q in single bare comment crlf nofinal; do cp -r "$FIX/hf-$q" "$D/hf-$q"; done
    claimed=0
    for d in "$D"/*/; do
        d="${d%/}"; name="${d##*/}"
        r="$(FX_DEFAULT_NTG_DIR="$d" inner 'ntg_config probe "$LAB_DEFAULT_NTG_DIR"; printf "R=%s %s\n" "$NTG_ST" "$NTG_MODE"' | grep -m1 '^R=')"
        cfg="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ntg_config as n; print(n.config_for_bridge(sys.argv[2], sys.argv[3])[0])' \
               "$(dirname "$MOD")" "$d" "$d.out" 2>&1)"
        ntg="$(cd "$d" && "$NPY" -c 'import sys
from nornir import InitNornir
try:
    h = InitNornir(config_file=sys.argv[1]).inventory.hosts.get("Mininet_Testbed")
    print("NONE" if h is None else h.data.get("mode", "cli"))
except Exception as e:
    print("ERROR %s" % type(e).__name__)' "$cfg" 2>/dev/null | tail -1)"
        read -r _ st mode <<<"${r/R=/R= }"
        case "$st" in
            ok|no-mode|unknown-mode|hardware-mode)
                claimed=$((claimed+1))
                check "  $name: ndt says $mode, NTG reads it" "$mode" "$ntg" ;;
            *)
                check "  $name: ndt claims no mode ($st); NTG reads ${ntg:-?}" "refused" \
                      "$([[ "$st" == bad-mode || "$st" == unresolved ]] && echo refused || echo "$st")" ;;
        esac
    done
    # The four refused fixtures say custom_command, so a reader that misses their mode and falls
    # back to NTG's default would disagree with NTG here as well as in section 10.
    # The control: the comparison above is not every fixture refused and nothing compared.
    check "  control: ndt claimed a mode for the 15 readable fixtures" "15" "$claimed"
fi

# 🔴 THE FILES NTG SHIPS, byte for byte, from NTG's own history at 6e3f388: NTG.yaml names
# ./setting/Hardware.yaml, and setting/Mininet.yaml says custom_command. What the module answers
# there is what a newcomer's first bring-up gets, and the label is the one the P4 app guide quotes.
# Run under every interpreter at hand: the bridge runs the module under NTG's (3.10), ndt under
# the system one.
NC="${NTG_CHECKOUT:-$NDT_DEFAULT}"
SH="$FIX/shipped"
if ! git -C "$NC" cat-file -e 6e3f388:NTG.yaml 2>/dev/null; then
    echo "  skipped: no NTG checkout with commit 6e3f388 at $NC (set NTG_CHECKOUT=<NTG git checkout>)"
else
    mkdir -p "$SH/setting"
    for f in NTG.yaml setting/Mininet.yaml setting/Hardware.yaml setting/API_server_startup.yaml; do
        git -C "$NC" show "6e3f388:$f" > "$SH/$f"
    done
    : > "$SH/network_traffic_generator.py"
    check "  (the copies are NTG's: host_file names Hardware.yaml, Mininet.yaml says custom_command)" \
          'host_file: "./setting/Hardware.yaml" mode: "custom_command"' \
          "$(grep -o 'host_file: "[^"]*"' "$SH/NTG.yaml") $(grep -o 'mode: "[^"]*"' "$SH/setting/Mininet.yaml")"
    PYS="python3"
    for c in "${NTG_TEST_PY:-}" "${HOME:-/nonexistent}/miniconda3/envs/ntg-env/bin/python"; do
        [[ -n "$c" && -x "$c" ]] && { PYS="$PYS $c"; break; }
    done
    for py in $PYS; do
        v="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
        r="$("$py" "$MOD" probe "$SH" | tr '\037' '|')"
        check "🔴 (python $v) shipped files: ok, custom_command, read from setting/Mininet.yaml via Hardware.yaml" \
              "ok|$SH/NTG.yaml|$SH/setting/Mininet.yaml|custom_command|line 6|$SH/setting/Hardware.yaml" "$r"
        out="$(bridge_run "$SH" run "$py")"
        check "🔴 (python $v) shipped files: the bridge hands NTG setting/Mininet.yaml" \
              "HOSTFILE=$SH/setting/Mininet.yaml TMPGONE=True NEWFILES=" \
              "$(grep -m1 '^HOSTFILE=' <<<"$out") $(grep -m1 '^TMPGONE=' <<<"$out") $(grep -m1 '^NEWFILES=' <<<"$out")"
        if [[ -n "$NPY" ]]; then
            cfg="$("$py" -c 'import sys; sys.path.insert(0, sys.argv[1]); import ntg_config as n; print(n.config_for_bridge(sys.argv[2], sys.argv[3])[0])' \
                   "$(dirname "$MOD")" "$SH" "$SH.out.$v")"
            ntg="$(cd "$SH" && "$NPY" -c 'import sys
from nornir import InitNornir
nr = InitNornir(config_file=sys.argv[1])
h = nr.inventory.hosts.get("Mininet_Testbed")
print("NONE" if h is None else h.data.get("mode", "cli"), "Hardware_Testbed" in nr.inventory.hosts)' "$cfg" 2>&1 | tail -1)"
            check "  (python $v) and nornir reads that config as Mininet in custom_command, no hardware" \
                  "custom_command False" "$ntg"
        fi
    done
    out="$(FX_DEFAULT_NTG_DIR="$SH" inner 'lab_entry_points p4 fresh')"
    check "🔴 shipped files: the ready line the P4 app guide quotes" \
          "  proxy :8081   kernel :8000   NTG prompt, no mininet>: sudo tmux -L ndtwinlab attach -t topo
    for Mininet's CLI: 'ndt ntg cli', then 'ndt down' and up again" "$out"
fi

printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
(( FAIL == 0 ))
