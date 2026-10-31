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
#    NDT_UNDER_TEST; no source file is written, and the sha256 of each is compared at the end.
#    A copy is a small tree in the repo's layout: tools/test_workflow/ carries ndt and the three
#    files it sources from beside itself (ports.sh, sudo_surface.sh, components.env), and
#    p4_proxy/mininet/ carries ntg_config.py and the bridge, which the suite takes from the tree
#    the ndt under test sits in.
# 🔴 The suite runs with the mutant's tree as its cwd, so a mutant that resolves a path against
#    the cwd finds the temp tree and never a real NTG checkout the gate happened to be run from.
# 🔴 A mutation that will not apply, a non-unique anchor, or the wrong case going red counts as a
#    SURVIVOR. A comment-only edit is the control and must stay green.
# 🔴 Touches no lab and writes to no real NTG checkout: the suite redirects LAB_CONF and both
#    defaults into a temp dir, and the one checkout it reads -- section 14's shipped-files case,
#    through `git show 6e3f388:<path>` -- it only reads (see its header).
#
# Env:  MUTANT_EVIDENCE=<dir>  keeps each mutant as <label>.patch (diff -u against the source)
#       and the suite's output on it as <label>.log.
#
# Exit: 0 every mutation caught and the control stayed green, 1 a mutation survived (or the
#       control went red), 2 refused (baseline red / harness), 3 ndt, ntg_config.py or the
#       bridge changed while the gate ran.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NDT="$REPO/tools/test_workflow/ndt"
MOD="$REPO/p4_proxy/mininet/ntg_config.py"
BRIDGE="$REPO/p4_proxy/mininet/ntg_bmv2_topo.py"
SH_TEST="$HERE/test_ndt_ntg_mode.sh"
BK=$(mktemp -d "${TMPDIR:-/tmp}/ntg-mode-mutate-XXXXXX")
trap 'rm -rf "${BK:?}"' EXIT
BASE_NDT=$(sha256sum "$NDT" "$MOD" "$BRIDGE" | cut -d' ' -f1 | tr '\n' ' ')

command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$NDT" && -f "$MOD" && -f "$BRIDGE" && -f "$SH_TEST" ]] || {
    echo "🔴 missing $NDT, $MOD, $BRIDGE or $SH_TEST" >&2; exit 2; }

SURVIVORS=0
MUTATIONS=0

run_sh() { (cd "$1" && NDT_UNDER_TEST="$1/tools/test_workflow/ndt" timeout 600 bash "$SH_TEST" 2>&1); }

tree() {   # <dir> -- the files the suite reads, in the repo's layout
    mkdir -p "$1/tools/test_workflow" "$1/p4_proxy/mininet"
    cp "$NDT" "$REPO/tools/test_workflow/ports.sh" "$REPO/tools/test_workflow/sudo_surface.sh" \
       "$REPO/tools/test_workflow/components.env" "$1/tools/test_workflow/"
    cp "$MOD" "$BRIDGE" "$1/p4_proxy/mininet/"
    chmod +x "$1/tools/test_workflow/ndt"
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ ! -f "$2/tools/test_workflow/ndt" ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (the mutant was not built)\n' "$1"; return
    fi
    out=$(run_sh "$2"); rc=$?
    if [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        { printf '%s\nthe case that must fail: %s\n\n' "$1" "$3"; printf '%s\n' "$out"; echo "exit code: $rc"; } \
            > "$MUTANT_EVIDENCE/$(basename "$2").log"
    fi
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
    if [[ -f "$2/tools/test_workflow/ndt" && "$rc" -eq 0 ]]; then
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
    tree "$d"
    local target="$d/${file#"$REPO"/}"
    if ! python3 - "$target" "$old" "$new" <<'PY' >&2
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    then
        rm -f "$d/tools/test_workflow/ndt"     # not built: `report` counts it as a survivor
    elif [[ -n "${MUTANT_EVIDENCE:-}" ]]; then
        mkdir -p "$MUTANT_EVIDENCE"
        diff -u --label "a/${file#"$REPO"/}" --label "b/${file#"$REPO"/}" "$file" "$target" \
            > "$MUTANT_EVIDENCE/$label.patch"
    fi
    echo "$d"
}

echo "baseline (the suite must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"; tree "$base"
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
    '            err "  NTG_DIR=$ntg_dir ($src)"' \
    '            :')
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

# The trust gate is skipped: a config this user owns is believed, while the helper refuses it.
m=$(mutant n9 "$NDT" \
    '        if lab_conf_trusted "$LAB_CONF"; then' \
    '        if :; then')
report "N9: ndt ntg believes a config the helper refuses" "$m" \
       "🔴 a config this user owns is refused -> the default checkout, as in the helper"

# An accepted file without the key is reported as a refused one: the operator is told to fix a
# file that is fine.
m=$(mutant n10 "$NDT" \
    '            LAB_NTG_DIR_SOURCE="built-in default ($LAB_CONF sets no NTG_DIR)"' \
    '            LAB_NTG_DIR_SOURCE="built-in default ($LAB_CONF was REFUSED)"')
report "N10: an accepted config without NTG_DIR is called refused" "$m" \
       "🔴 an accepted config without NTG_DIR is named as such, not as refused"

# [Co-developed with claude code -- Adam]
# --- the file NTG reads, the value whole, the words, the footer ---------------------------------
# N11 is the defect measured on a real fabric: NTG.yaml named setting/Hardware.yaml and the edit
# went to setting/Mininet.yaml by name, reporting success.
m=$(mutant n11 "$MOD" \
    '    host = val if os.path.isabs(val) else os.path.join(ntg, val)' \
    '    host = os.path.join(ntg, "setting/Mininet.yaml")')
report "N11: the hosts file NTG.yaml names is ignored" "$m" \
       "🔴 an absolute host_file is the file edited"

# N12 mutates the same line as N11 (two wrong answers to one question), so check_gate_anchors.py,
# which counts DISTINCT anchors, reports one anchor fewer than this gate has mutations.
m=$(mutant n12 "$MOD" \
    '    host = val if os.path.isabs(val) else os.path.join(ntg, val)' \
    '    host = os.path.abspath(val)')
report "N12: a relative host_file is taken from ndt's cwd, not NTG's" "$m" \
       "  a relative host_file resolves under the NTG checkout"

# N13: the old reader's shape -- a prefix match, so `mode: "cli"_command"` reads as cli.
m=$(mutant n13 "$MOD" \
    '    m = MODE.fullmatch(text)' \
    '    m = MODE.match(text)')
report "N13: a mode line is accepted on a prefix match" "$m" \
       "🔴 an unparseable mode line is refused (rc 1) and the file is unchanged"

m=$(mutant n14 "$MOD" \
    'lines[i] = m.group(1) + q + word + q + m.group(5) + cr' \
    'lines[i] = m.group(1) + q + word + q + cr')
report "N14: the rest of the mode line is not written back" "$m" \
       "  and the file is the shipped file with that one value changed"

m=$(mutant n15 "$NDT" \
    '        custom_command|prompt) want=custom_command ;;' \
    '        custom_command) want=custom_command ;;
        prompt) want=prompt ;;')
report "N15: prompt is written as a value NTG does not know" "$m" \
       "🔴 ndt ntg prompt writes custom_command, not \"prompt\""

m=$(mutant n16 "$NDT" \
    '             info "proxy :8081   kernel :8000   $NTG_PANE_LABEL: $(lab_attach_cmd)"' \
    '             info "proxy :8081   kernel :8000   Mininet CLI: $(lab_attach_cmd)"')
report "N16: the ready line says Mininet CLI whatever the pane holds" "$m" \
       "🔴 custom_command -> the footer does not say Mininet CLI"

# --- the cases around them ---------------------------------------------------------------------
# N17: two host_file lines, and the last one is believed (the YAML loader NTG uses refuses both).
m=$(mutant n17 "$MOD" \
    '    if len(hf) != 1:' \
    '    hf = hf[-1:]
    if len(hf) != 1:')
report "N17: the last of two host_file lines wins" "$m" \
       "🔴 NTG.yaml host_file twice -> refused, nothing edited"

# N18: a host_file under ~ is resolved under the checkout instead of refused.
m=$(mutant n18 "$MOD" \
    '    if val.startswith("~"):' \
    '    if False:')
report "N18: the ~ branch is dropped" "$m" \
       "🔴 NTG.yaml host_file tilde -> refused, nothing edited"

# N19: `set` writes without re-reading the state it may write from.
m=$(mutant n19 "$MOD" \
    '    if rec.state not in SETTABLE:
        return rec, 3
' \
    '')
report "N19: the set-time re-check is dropped" "$m" \
       "🔴 the module's set refuses from bad-mode (rc 3), file unchanged"

# N20: a mode in a shape the line reader misses is taken for "no mode line", i.e. cli.
m=$(mutant n20 "$MOD" \
    '        if tokens or indirect:' \
    '        if False:')
report "N20: a flow-style mode reads as NTG's default" "$m" \
       "🔴 (flow) plain ndt ntg does not report cli, and is rc 1"

# N21: a value NTG does not know is reported as fine.
m=$(mutant n21 "$MOD" \
    '    if word not in KNOWN_MODES:' \
    '    if False:')
report "N21: mode \"prompt\" is accepted" "$m" \
       "🔴 mode \"prompt\" is reported as one NTG does not know"

# N22: a write that fails surfaces as a traceback, not as the file and the errno.
m=$(mutant n22 "$MOD" \
    '    except OSError as e:
        return Record("write-failed",' \
    '    except KeyError as e:
        return Record("write-failed",')
report "N22: an unwritable hosts file is not caught" "$m" \
       "  (unwritable) naming the file and the errno"

# N23: an unreadable hosts file is read outside the try.
m=$(mutant n23 "$MOD" \
    '    try:
        lines = lines_of(host)
    except OSError as e:
        return None, "cannot read it: %s" % oserror(e)' \
    '    lines = lines_of(host)')
report "N23: an unreadable hosts file is not caught" "$m" \
       "  (unreadable) naming the file and the errno"

# N24: the bridge hands NTG its NTG.yaml whatever it names -- the shipped shape then runs NTG's
# hardware-testbed mode on a Mininet net.
m=$(mutant n24 "$BRIDGE" \
    '        _ntg_loop(net, command_line, config)' \
    '        _ntg_loop(net, command_line, os.path.join(NTG_DIR, "NTG.yaml"))')
report "N24: the bridge passes NTG.yaml as it is" "$m" \
       "🔴 shipped shape: NTG gets a config naming setting/Mininet.yaml"

# N25: the reader stops looking at setting/Mininet.yaml, so ndt and the bridge disagree.
m=$(mutant n25 "$MOD" \
    '    got, why = read_hosts(fallback)' \
    '    got, why = None, "no-host-file"')
report "N25: ndt does not follow the bridge to setting/Mininet.yaml" "$m" \
       "🔴 shipped shape: plain ndt ntg reports setting/Mininet.yaml's mode"

# N26: a reused fabric is described from the config, as if this run had started it.
m=$(mutant n26 "$NDT" \
    '        p4)  ntg_pane "${2:-}"' \
    '        p4)  ntg_pane fresh')
report "N26: a reused fabric gets the config's mode" "$m" \
       "🔴 a reused fabric -> no mode is claimed, not even cli's"

# N27-N30: the spellings of the host_file line NTG accepts. One not read leaves `ndt ntg` refusing
# a config NTG starts on.
m=$(mutant n27 "$MOD" \
    "r\"'([^']*)'(?:[ \t]+#.*)?\"," \
    "")
report "N27: a single-quoted host_file is not read" "$m" \
       "  host_file single -> the file it names is read"

m=$(mutant n28 "$MOD" \
    '        line = bare(raw)' \
    '        line = raw')
report "N28: CRLF line ends are not stripped" "$m" \
       "  host_file crlf -> the file it names is read"

m=$(mutant n29 "$MOD" \
    'r"\"([^\"\\]*)\"(?:[ \t]+#.*)?", ' \
    'r"\"([^\"\\]*)\"", ')
report "N29: a trailing comment after a quoted host_file is not allowed" "$m" \
       "  host_file comment -> the file it names is read"

m=$(mutant n30 "$MOD" \
    'r"([A-Za-z0-9_./~+-]+)(?:[ \t]+#.*)?"' \
    'r"(?!)"')
report "N30: a bare host_file is not read" "$m" \
       "  host_file bare -> the file it names is read"

# N31-N39: the bridge. Nothing it does may write into the NTG checkout, lose the note, or keep
# NTG from starting; and the config it prepared must outlive a crash and not outlive an exit.
m=$(mutant n31 "$BRIDGE" \
    '        tmp = tempfile.mkdtemp(prefix="ndtwin-ntg-")' \
    '        tmp = tempfile.mkdtemp(prefix="ndtwin-ntg-", dir=NTG_DIR)')
report "N31: the temp config is made inside the NTG checkout" "$m" \
       "🔴 no new file or dir in the NTG checkout while NTG runs, nor after"

m=$(mutant n32 "$MOD" \
    '            text = [uncomment(bare(lines[j])) for j in range(i, end)]' \
    '            text = [bare(lines[j]) for j in range(i, end)]')
report "N32: a commented mode line is read as a mode" "$m" \
       "🔴 a commented mode line is not a mode: cli, NTG's default (rc 0)"

m=$(mutant n33 "$BRIDGE" \
    '    except Exception as e:   # the bridge must still reach NTG' \
    '    except OSError as e:   # the bridge must still reach NTG')
report "N33: the bridge's fallback catches only OSError" "$m" \
       "🔴 config_for_bridge raising: NTG still starts, on NTG.yaml as it is"

m=$(mutant n34 "$BRIDGE" \
    '        if note:
            print(note)' \
    '        if note:
            pass')
report "N34: the bridge's note is not printed" "$m" \
       "🔴 the bridge prints its note: which file NTG gets and why"

m=$(mutant n35 "$BRIDGE" \
    '            crashes += 1' \
    '            crashes += 1
            config = os.path.join(NTG_DIR, "NTG.yaml")')
report "N35: a crash re-entry loses the temp config" "$m" \
       "🔴 crash re-entry: NTG is entered again with the same temp config, still there"

m=$(mutant n36 "$BRIDGE" \
    '    finally:
        drop_ntg_config(tmp)


#: The config main prepared' \
    '    finally:
        pass


#: The config main prepared')
report "N36: an exit out of NTG leaves the temp dir behind" "$m" \
       "🔴 SystemExit out of NTG (the teardown signal) still removes the temp dir"

m=$(mutant n37 "$BRIDGE" \
    'note = f"[ntg_bmv2_topo] ntg_config failed ({e!r}); NTG gets {config} as it is."' \
    'note = ""')
report "N37: the fallback says nothing" "$m" \
       "  and the note says ntg_config failed"

m=$(mutant n38 "$BRIDGE" \
    '    tmp = None
    try:
        try:
            tmp = tempfile.mkdtemp(prefix="ndtwin-ntg-")' \
    '    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix="ndtwin-ntg-")
        try:')
report "N38: a temp dir that cannot be made stops NTG" "$m" \
       "🔴 a temp dir that cannot be made: NTG still starts, on NTG.yaml as it is"

m=$(mutant n39 "$BRIDGE" \
    '            tmp, PREPARED_CONFIG = prepare_ntg_config()' \
    '            pass')
report "N39: the note is printed after the tee stops (topo.log never has it)" "$m" \
       "🔴 main prints the note while the tee still runs, so topo.log records it"

# N40-N42: what ndt says about the file the bridge reads as root, a hosts file that also lists a
# hardware testbed, and the footer's reason for not knowing.
m=$(mutant n40 "$MOD" \
    '    if got is None and why != "no-host-file":' \
    '    if False:')
report "N40: an unreadable setting/Mininet.yaml reads as no Mininet testbed" "$m" \
       "🔴 an unreadable setting/Mininet.yaml under the shipped shape -> rc 1"

m=$(mutant n41 "$MOD" \
    '    if word != "cli" and "Hardware_Testbed" in' \
    '    if False and "Hardware_Testbed" in')
report "N41: a Hardware_Testbed beside Mininet_Testbed is ignored" "$m" \
       "🔴 Mininet_Testbed in custom_command plus Hardware_Testbed -> the hardware label"

m=$(mutant n42 "$NDT" \
    '        unreadable:*)' \
    '        unreadable-not:*)')
report "N42: the footer does not say it cannot read the file" "$m" \
       "🔴 (fallback) the footer claims no mode, and says it cannot read the file"

# N43: main's removal of the temp dir runs only when NTG returns, not on the way out of an exit.
m=$(mutant n43 "$BRIDGE" \
    '        PREPARED_CONFIG = None
        drop_ntg_config(tmp)
        if tee is not None:
            tee.start()
        # p4_testbed_topo'"'"'s teardown, which is now literally p4_testbed_topo'"'"'s teardown: stop
        # the net, then reap any switch the power helper restarted (net.stop cannot address
        # those) before the manifest goes.
        testbed.tear_down(net)
' \
    '        PREPARED_CONFIG = None
        if tee is not None:
            tee.start()
        # p4_testbed_topo'"'"'s teardown, which is now literally p4_testbed_topo'"'"'s teardown: stop
        # the net, then reap any switch the power helper restarted (net.stop cannot address
        # those) before the manifest goes.
        testbed.tear_down(net)
    drop_ntg_config(tmp)
')
report "N43: main removes the temp dir only after a normal return" "$m" \
       "🔴 SystemExit through main: NTG had the temp config, and its directory is gone"

# N44: in hardware-mode only the word already there is refused; another one NTG would still leave
# Mininet mode with is written and called a success.
m=$(mutant n44 "$NDT" \
    '            if [[ "$want" != cli ]]; then' \
    '            if [[ "$NTG_MODE" == "$want" ]]; then')
report "N44: hardware-mode accepts any word but the current one" "$m" \
       "🔴 prompt plus Hardware_Testbed: ndt ntg custom_command refuses (rc 1), file unchanged"

# N45-N47: a label with no reason line under it.
m=$(mutant n45 "$NDT" \
    '            NTG_PANE_HINT="the mode line in NTG'"'"'s hosts file is not one ndt can read: see '"'"'ndt ntg'"'"'" ;;' \
    '            NTG_PANE_HINT="" ;;')
report "N45: bad-mode has no reason line" "$m" \
       "🔴 (badmode) the footer has a reason line"

m=$(mutant n46 "$NDT" \
    '            NTG_PANE_HINT="NTG has no Mininet testbed file to read: see '"'"'ndt ntg'"'"'" ;;' \
    '            NTG_PANE_HINT="" ;;')
report "N46: no-mininet has no reason line" "$m" \
       "🔴 (nomininet) the footer has a reason line"

m=$(mutant n47 "$NDT" \
    '    NTG_PANE_HINT="ndt cannot work out which file NTG reads its mode from: see '"'"'ndt ntg'"'"'"' \
    '    NTG_PANE_HINT=""')
report "N47: an unresolved config has no reason line" "$m" \
       "🔴 (unresolved) the footer has a reason line"

# N48: an exception after mkdtemp inside prepare_ntg_config (a broken stdout, the teardown
# signal) leaves the temp dir behind.
m=$(mutant n48 "$BRIDGE" \
    '        drop_ntg_config(tmp)
        raise' \
    '        raise')
report "N48: prepare_ntg_config does not clean up when it is interrupted" "$m" \
       "🔴 a note that cannot be printed: the error surfaces and the temp dir is gone"

# --- the control -------------------------------------------------------------------------------
m=$(mutant n8 "$NDT" \
    '# lab_ntg_dir -- the NTG checkout `sudo ndtwin-lab` hands the P4 bridge. Sets LAB_NTG_DIR_SOURCE.' \
    '# lab_ntg_dir -- the NTG checkout `sudo ndtwin-lab` hands the P4 bridge (x). Sets LAB_NTG_DIR_SOURCE.')
control "N8: a comment-only edit" "$m"

echo
NOW_NDT=$(sha256sum "$NDT" "$MOD" "$BRIDGE" | cut -d' ' -f1 | tr '\n' ' ')
if [[ "$NOW_NDT" != "$BASE_NDT" ]]; then
    echo "🔴 baseline CHANGED during the gate -- ndt, ntg_config.py or the bridge was written"
    echo "   before: $BASE_NDT"
    echo "   after:  $NOW_NDT"
    exit 3
fi
echo "baseline byte-identical: yes  ndt, ntg_config.py, ntg_bmv2_topo.py  sha256 $BASE_NDT"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
