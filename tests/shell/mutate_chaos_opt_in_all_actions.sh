#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_chaos_opt_in_all_actions.py (E-4).
#
# [Co-developed with claude code -- Adam]
#
# `Action.needs_opt_in` was declared in actions.py and enforced in ONE branch of ONE loop in
# chaos.py -- the positive controls, live path only. Every other action could carry the field
# and run ungated, and `link_blackhole` (destructive, `tc netem loss 100%` on a live link, undo
# dependent on a sudo grant this machine has never been seen to accept) carried nothing at all.
# The fix puts the decision in `actions.opt_in_refusal` and asks it at BOTH entry points.
#
# Two directions, because this fix can go wrong both ways:
#
#   W1-W9  take a piece of the gate back out                -> a named case must go red
#   X1-X5  change something the contract leaves free        -> every case must stay GREEN
#   U1     an inert edit that cannot change behaviour       -> must SURVIVE
#
# The X block is the one that is easy to skip and the reason this gate is worth running twice.
# The contract is: one decision, asked before anything is applied, at both entry points, in
# every mode including a dry run; default-deny; the refusal names its flag; and the blackhole is
# gated but stays out of CHAOS_ACTIONS. Wording, evidence keys, notes and the rest of the
# CHAOS_ACTIONS list are free.
#
# U1 is the scorer's own control. A gate that has never printed SURVIVED cannot be trusted to
# print it: if the baseline were red every line would read "caught" and the tally would be a
# decoration.
#
# 🔴 An UNAPPLICABLE mutation is scored a SURVIVOR, never a catch. If an anchor has been
# reworded away this gate has proved nothing about that mutation and says so on the tally line.
#
# 🔴 Guards its own baseline. Mutations go into a COPY of the harness in a temp dir and the test
# is pointed at the copy with NDT_CHAOS_HARNESS; the files under
# doc/audit/2026-08-28_chaos-harness/harness/ are never written -- other sessions are reading
# this worktree right now. Anchor counts are taken from the REAL files, so a reworded source
# reports a missing anchor here and in tests/shell/check_gate_anchors.py.
#
# NDT_KERNEL_REPO pins the repo the harness is read against, so a mutation to the harness never
# also mutates the authority it is checked against.
#
# Usage:  bash tests/shell/mutate_chaos_opt_in_all_actions.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

HARNESS_DIR=doc/audit/2026-08-28_chaos-harness/harness
ACTIONS="$HARNESS_DIR/actions.py"
CHAOS="$HARNESS_DIR/chaos.py"
TEST=tests/python/test_chaos_opt_in_all_actions.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/chaos-optin-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_ACTIONS="$(sha256sum "$ACTIONS" | cut -d' ' -f1)"
BASE_CHAOS="$(sha256sum "$CHAOS" | cut -d' ' -f1)"

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

# must_survive <label> <copy dir> -- the other direction. A change the contract permits, or an
# edit that cannot change behaviour, must leave the whole suite GREEN. Red here means the suite
# is pinned to something that is not the contract.
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

# --- W: the gate, taken back out one piece at a time --------------------------------------------

d="$(fresh_copy w1)"
apply_exact "$CHAOS" \
  '    refusal = A.opt_in_refusal(action, opt_ins)' \
  '    refusal = None' "$d" || d=""
report "W1: only the controls ask again (E-4 itself)" "$d" \
       "test_a_gated_action_is_refused_before_anything_is_applied"

d="$(fresh_copy w2)"
apply_exact "$ACTIONS" \
  '                  needs_opt_in="allow-link-blackhole",' \
  '                  needs_opt_in=None,' "$d" || d=""
report "W2: the blackhole loses its opt-in flag" "$d" \
       "test_the_blackhole_carries_an_opt_in_flag"

d="$(fresh_copy w3)"
apply_exact "$ACTIONS" \
  'CHAOS_ACTIONS: list[Action] = [
    Action("H5", "INV-06", "acquire_lock with a malformed body", destructive=False,' \
  'CHAOS_ACTIONS: list[Action] = [
    link_blackhole("s1-eth3"),
    Action("H5", "INV-06", "acquire_lock with a malformed body", destructive=False,' "$d" || d=""
report "W3: the blackhole joins what --full runs (against E-4)" "$d" \
       "test_the_blackhole_is_not_in_the_list_full_runs"

d="$(fresh_copy w4)"
apply_exact "$ACTIONS" \
  '    return f"needs --{flag}; {action.note}"' \
  '    return f"this action is not enabled; {action.note}"' "$d" || d=""
report "W4: the refusal stops naming the flag" "$d" \
       "test_the_refusal_names_the_flag_that_would_allow_it"

d="$(fresh_copy w5)"
apply_exact "$ACTIONS" \
  '    if (opt_ins or {}).get(flag):' \
  '    if opt_ins is None or opt_ins.get(flag):' "$d" || d=""
report "W5: no flags at all becomes permission (fail-open)" "$d" \
       "test_a_caller_that_passes_no_flags_at_all_is_refused"

d="$(fresh_copy w6)"
apply_exact "$CHAOS" \
  '        refusal = A.opt_in_refusal(ctl, opt_ins)' \
  '        refusal = None' "$d" || d=""
report "W6: the controls loop stops asking" "$d" \
       "test_a_gated_control_is_not_run_and_is_not_applied"

d="$(fresh_copy w7)"
apply_exact "$CHAOS" \
  '    opt_ins = {"allow-poweroff": args.allow_poweroff,
               "allow-link-blackhole": args.allow_link_blackhole}' \
  '    opt_ins = {"allow-poweroff": args.allow_poweroff}' "$d" || d=""
report "W7: the flag is parsed but never reaches the action" "$d" \
       "test_the_flag_lets_the_dry_run_plan_its_attach_point"

d="$(fresh_copy w8)"
apply_exact "$CHAOS" \
  '    refusal = A.opt_in_refusal(action, opt_ins)
    if refusal:' \
  '    refusal = A.opt_in_refusal(action, opt_ins)
    if refusal and not dry_run:' "$d" || d=""
report "W8: dry runs are exempted, so the only path there is ungated" "$d" \
       "test_a_dry_run_of_a_gated_action_is_refused_and_reads_nothing"

d="$(fresh_copy w9)"
apply_exact "$CHAOS" \
  '        refusal = A.opt_in_refusal(ctl, opt_ins)' \
  '        refusal = None if dry_run else A.opt_in_refusal(ctl, opt_ins)' "$d" || d=""
report "W9: a dry control previews itself before the flag is asked for" "$d" \
       "test_a_dry_run_no_longer_previews_a_gated_control_without_its_flag"

echo

# --- 🔴 X: changes the contract permits. Every one of these must stay GREEN ----------------------

d="$(fresh_copy x1)"
apply_exact "$CHAOS" \
  '                "verdict_detail": "no invariant was evaluated", "detail": refusal,' \
  '                "verdict_detail": "no invariant was evaluated", "detail": refusal,
                "harness_note": "extra evidence",' "$d"
must_survive "X1 (widening): an extra key on the refused round" "$d"

d="$(fresh_copy x2)"
apply_exact "$ACTIONS" \
  '    return f"needs --{flag}; {action.note}"' \
  '    return f"this run needs --{flag} before it may go ahead; {action.note}"' "$d"
must_survive "X2 (widening): the refusal sentence is rewritten around the flag" "$d"

d="$(fresh_copy x3)"
apply_exact "$CHAOS" \
  '                "why": ("this action is behind an opt-in flag that was not given, so nothing "' \
  '                "why": ("REWORDED -- an opt-in flag this run did not carry, so nothing "' "$d"
must_survive "X3 (widening): the refused round's prose is rewritten" "$d"

d="$(fresh_copy x4)"
apply_exact "$ACTIONS" \
  '           note="destructive and its undo is UNPROVEN. Until 2026-08-29 this control was inert "' \
  '           note="REWORDED -- destructive, and its undo has never been proven. "' "$d"
must_survive "X4 (widening): a gated action's note is reworded" "$d"

d="$(fresh_copy x5)"
apply_exact "$ACTIONS" \
  'CHAOS_ACTIONS: list[Action] = [
    Action("H5", "INV-06", "acquire_lock with a malformed body", destructive=False,' \
  'CHAOS_ACTIONS: list[Action] = [
    Action("X-noop", "", "a harmless extra injection", destructive=False,
           apply=lambda dry: ActionResult(True, "noop"),
           verify=lambda: ActionResult(True, "ok")),
    Action("H5", "INV-06", "acquire_lock with a malformed body", destructive=False,' "$d"
must_survive "X5 (widening): another safe action joins CHAOS_ACTIONS" "$d"

d="$(fresh_copy u1)"
apply_exact "$ACTIONS" \
  '# 🔴 E-4, 2026-09-07. THE ONE PLACE that decides whether an action may run, and it lives here,' \
  '# Reworded comment, no behaviour change at all (the scorer control).' "$d"
must_survive "U1 (control): an inert edit -- a survivor must be reportable" "$d"

echo
ok=1
[[ "$(sha256sum "$ACTIONS" | cut -d' ' -f1)" == "$BASE_ACTIONS" ]] || { echo "🔴 baseline CHANGED -- $ACTIONS was written during the gate"; ok=0; }
[[ "$(sha256sum "$CHAOS"   | cut -d' ' -f1)" == "$BASE_CHAOS"   ]] || { echo "🔴 baseline CHANGED -- $CHAOS was written during the gate"; ok=0; }
[[ "$ok" == 1 ]] || exit 3
echo "baseline byte-identical: yes (actions.py, chaos.py)"
echo "widening controls: $WIDENINGS, $BROKEN_WIDENINGS killed (a kill here means the suite is pinned to prose, not behaviour)"
[[ "$UNAPPLICABLE" -eq 0 ]] || echo "unapplicable mutations: $UNAPPLICABLE (each counted as a survivor)"
if [[ "$SURVIVORS" -eq 0 && "$BROKEN_WIDENINGS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
