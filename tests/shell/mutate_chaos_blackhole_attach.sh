#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_chaos_link_blackhole_attach.py (W8-8).
#
# [Co-developed with claude code -- Adam]
#
# The chaos harness's `link_blackhole` attached netem with an unconditional `root`. On a
# Mininet TCLink interface that REPLACES htb rather than stacking on it, `del ... root` then
# restores the kernel default instead of htb, and the NOPASSWD grants on this machine cannot
# put htb back -- measured verbatim on 2026-08-13
# (doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md, P1). The fix reads the live
# qdisc tree and attaches under the shaper, exactly as tools/test_workflow/faults.sh does.
#
# Two directions, because this fix can go wrong both ways:
#
#   W1-W8  take a piece of the rule back out              -> a named case must go red
#   X1-X4  WIDEN it without breaking the contract         -> every case must stay GREEN
#   U1     an inert edit that cannot change behaviour     -> must SURVIVE
#
# The X block is the one that is easy to skip, and it is the reason this gate is worth running
# twice. The contract is: the attach point comes from the tree, a shaper that is not a kernel
# default must still be standing afterwards, the undo removes exactly the netem it finds, and
# an unshaped interface still gets `root`. Wording, evidence keys and the note are free.
#
# U1 is the scorer's own control. A gate that has never printed SURVIVED cannot be trusted to
# print it: if the baseline were red, every line would read "caught" and the tally would be a
# decoration. U1 changes a comment, so the suite MUST stay green.
#
# 🔴 An UNAPPLICABLE mutation is scored a SURVIVOR, never a catch. If an anchor has been
# reworded away this gate has proved nothing about that mutation and says so on the tally line.
#
# 🔴 Guards its own baseline. Mutations are applied to a COPY of the harness in a temp dir and
# the test is pointed at the copy with NDT_CHAOS_HARNESS; the files under
# doc/audit/2026-08-28_chaos-harness/harness/ are never written -- other sessions are reading
# this worktree right now. Anchor counts are taken from the REAL file, so a reworded source
# reports a missing anchor here and in tests/shell/check_gate_anchors.py.
#
# NDT_KERNEL_REPO pins the repo the harness is read against, so a mutation to the harness never
# also mutates the authority it is checked against -- and one case in the suite asks
# faults.sh itself, in this worktree, for its answer on the same trees.
#
# Usage:  bash tests/shell/mutate_chaos_blackhole_attach.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

HARNESS_DIR=doc/audit/2026-08-28_chaos-harness/harness
ACTIONS="$HARNESS_DIR/actions.py"
TEST=tests/python/test_chaos_link_blackhole_attach.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/chaos-blackhole-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_ACTIONS="$(sha256sum "$ACTIONS" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
WIDENINGS=0
BROKEN_WIDENINGS=0
UNAPPLICABLE=0

# fresh_copy -- an unmutated copy of the harness in $BK/<tag>, and echo its path.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$HARNESS_DIR"/*.py "$dst"/
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> <copy dir> -- assert the anchor is unique in the
# REAL file, then write the replacement into the copy. Never writes the real file. A
# substitution that matched nothing would leave the copy unmutated and score a green as
# "caught", which is the one result a gate must never produce by accident -- so a missing or
# duplicated anchor is reported UNAPPLICABLE and counted as a survivor.
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n base
    base="$(basename "$file")"
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 UNAPPLICABLE: anchor appears $n time(s) in $file, expected 1 -- counted as a"
        echo "     SURVIVOR, because this gate has proved nothing about that mutation."
        echo "     anchor: $from"
        UNAPPLICABLE=$((UNAPPLICABLE + 1))
        return 1
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst/$base"
}

# report <label> <copy dir> <test case that must go red>
report() {
    local label="$1" dir="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ ! -d "$dir" ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (never applied)\n' "$label"
        return
    fi
    out="$(NDT_CHAOS_HARNESS="$dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

# must_survive <label> <copy dir> -- the other direction. A widening, or an edit that cannot
# change behaviour, must leave the whole suite GREEN. Red here means the suite is pinned to
# something that is not the contract.
must_survive() {
    local label="$1" dir="$2" out rc
    WIDENINGS=$((WIDENINGS + 1))
    out="$(NDT_CHAOS_HARNESS="$dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  survived %-58s (all green, as required)\n' "$label"
    else
        BROKEN_WIDENINGS=$((BROKEN_WIDENINGS + 1))
        printf '  🔴 KILLED %-57s (the suite went red on a change the contract permits)\n' "$label"
        grep -E "^(FAIL|ERROR)" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

# --- W: the rule, taken back out one piece at a time --------------------------------------------

d="$(fresh_copy w1)"
apply_exact "$ACTIONS" \
  '    if kind == "htb":' \
  '    if False:' "$d" || d=""
report "W1: a shaped interface gets root again (W8-8 itself)" "$d" \
       "test_a_shaped_interface_attaches_under_htb_and_never_at_root"

d="$(fresh_copy w2)"
apply_exact "$ACTIONS" \
  '        if len(words) > _QDISC_KIND and words[0] == "qdisc" and words[_QDISC_KIND] == "netem":' \
  '        if False:' "$d" || d=""
report "W2: netem residue is stacked onto instead of refused" "$d" \
       "test_a_netem_already_present_is_refused_rather_than_stacked"

d="$(fresh_copy w3)"
apply_exact "$ACTIONS" \
  '        if (was_kind is not None and now_kind != was_kind
                and was_kind not in _KERNEL_DEFAULT_ROOT_QDISCS):' \
  '        if False:' "$d" || d=""
report "W3: verify stops checking that the shaper survived" "$d" \
       "test_a_netem_that_replaced_the_shaper_is_not_a_successful_injection"

d="$(fresh_copy w4)"
apply_exact "$ACTIONS" \
  '_KERNEL_DEFAULT_ROOT_QDISCS = ("noqueue", "pfifo_fast", "pfifo", "fq_codel", "fq", "mq")' \
  '_KERNEL_DEFAULT_ROOT_QDISCS = ("noqueue", "pfifo_fast", "pfifo", "fq_codel", "fq", "mq",
                                  "htb", "tbf")' "$d" || d=""
report "W4: htb is listed as a qdisc the kernel puts back" "$d" \
       "test_a_netem_that_replaced_the_shaper_is_not_a_successful_injection"

d="$(fresh_copy w5)"
apply_exact "$ACTIONS" \
  '                return ["parent", words[i + 1]], ""' \
  '                return ["root"], ""' "$d" || d=""
report "W5: the undo goes back to deleting the root qdisc" "$d" \
       "test_the_netem_is_removed_at_the_parent_it_is_on_never_at_root"

d="$(fresh_copy w6)"
apply_exact "$ACTIONS" \
  '        self.before = tree' \
  '        self.before = ""' "$d" || d=""
report "W6: apply stops recording the pre-injection tree" "$d" \
       "test_a_netem_under_the_shaper_verifies_and_says_the_shaper_survived"

d="$(fresh_copy w7)"
apply_exact "$ACTIONS" \
  '    return None, "no netem qdisc is attached to this interface"' \
  '    return ["root"], ""' "$d" || d=""
report "W7: an undo with nothing to undo deletes root anyway" "$d" \
       "test_nothing_to_remove_means_no_tc_at_all"

d="$(fresh_copy w8)"
apply_exact "$ACTIONS" \
  "            return _dry(f\"would run: {' '.join(argv)}\", iface=self.iface," \
  '            return _dry(f"would run: tc qdisc add dev {self.iface} root netem loss 100%", iface=self.iface,' \
  "$d" || d=""
report "W8: the dry run quotes root netem again, whatever it read" "$d" \
       "test_the_dry_run_reports_the_attach_point_it_read_and_touches_nothing"

echo

# --- 🔴 X: widenings the contract permits. Every one of these must stay GREEN --------------------

d="$(fresh_copy x1)"
apply_exact "$ACTIONS" \
  '                            {"iface": self.iface, "attach_point": " ".join(where),' \
  '                            {"iface": self.iface, "harness_note": "extra evidence",
                             "attach_point": " ".join(where),' "$d"
must_survive "X1 (widening): an extra evidence key is added" "$d"

d="$(fresh_copy x2)"
apply_exact "$ACTIONS" \
  '                  note="the attach point is read from the live qdisc tree: under htb when the "' \
  '                  note="REWORDED: the attach point is read from the live qdisc tree, under htb when the "' "$d"
must_survive "X2 (widening): the action note is reworded" "$d"

d="$(fresh_copy x3)"
apply_exact "$ACTIONS" \
  '_KERNEL_DEFAULT_ROOT_QDISCS = ("noqueue", "pfifo_fast", "pfifo", "fq_codel", "fq", "mq")' \
  '_KERNEL_DEFAULT_ROOT_QDISCS = ("noqueue", "pfifo_fast", "pfifo", "fq_codel", "fq", "mq",
                                  "clsact")' "$d"
must_survive "X3 (widening): another kernel default joins the list" "$d"

d="$(fresh_copy x4)"
apply_exact "$ACTIONS" \
  '                                f"the injection REPLACED the root qdisc on {self.iface}: it was "' \
  '                                f"REWORDED -- the injection replaced the root qdisc on {self.iface}: it was "' "$d"
must_survive "X4 (widening): the refusal text is rewritten" "$d"

d="$(fresh_copy u1)"
apply_exact "$ACTIONS" \
  '# 🔴 W8-8, 2026-09-07. `tc qdisc add dev X root netem loss 100%` does not stack a layer on a' \
  '# Reworded comment, no behaviour change at all (the scorer control).' "$d"
must_survive "U1 (control): an inert edit -- a survivor must be reportable" "$d"

echo
[[ "$(sha256sum "$ACTIONS" | cut -d' ' -f1)" == "$BASE_ACTIONS" ]] || {
    echo "🔴 baseline CHANGED -- $ACTIONS was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (actions.py)"
echo "widening controls: $WIDENINGS, $BROKEN_WIDENINGS killed (a kill here means the suite is pinned to prose, not behaviour)"
[[ "$UNAPPLICABLE" -eq 0 ]] || echo "unapplicable mutations: $UNAPPLICABLE (each counted as a survivor)"
if [[ "$SURVIVORS" -eq 0 && "$BROKEN_WIDENINGS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
