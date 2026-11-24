#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_topo_network_diff.py -- the comparison `ndt up p4` runs between
# NDT_TOPO and the model the P4 fabric is built from (p4_proxy/mininet/topo_from_json.py).
#
# [Co-developed with claude code -- Adam]
#
# Each mutant leaves one part of the comparison out (or breaks the command line `ndt` asks through) and
# must turn the NAMED test red -- a FAIL or ERROR line of that test, not just a non-zero exit, so a
# mutant that merely breaks the module cannot count as caught by accident.
#
#   cables-dropped, host-names-dropped, brand-dropped, host-mac-dropped, host-attachment-dropped,
#   switch-ip-dropped, switch-name-dropped, bridge-name-dropped   one compared field each
#   one-way-cables-ignored      a cable stored in one direction only reads as the same network
#   one-sided-switch-branch-deleted   a switch present in one model only is not said
#   switch-union-first-only, cable-union-first-only   only the first model's switches / cable ends are walked
#   one-way-in-either-model-is-a-difference, not-json-not-caught, bridge-name-read-raw
#   host-only-side-swapped      a host present in one model only is attributed to the other model
#   limit-ignored, refused-model-not-reported, cli-diff-rc-always-0, cli-fabric-model-env-leaks
#
# Several mutants share the anchor `if fa[i] != fb[i]:`; each is applied to its own copy.
#
# 🔴 Guards its own baseline: every mutant is a copy in a temp dir, the test is pointed at it with
# TOPO_FROM_JSON_DIR, and p4_proxy/mininet/topo_from_json.py is never written (the sha256 at the end
# says so).
#
# Exit: 0 all mutants caught; 1 a mutant survived; 2 baseline red or an anchor did not apply; 3 the
# module changed during the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOOL="$REPO/p4_proxy/mininet/topo_from_json.py"
TEST="$REPO/tests/python/test_topo_network_diff.py"
PY="${PY:-python3}"
BK="$(mktemp -d "${TMPDIR:-/tmp}/topo-diff-mutate-XXXXXX")"
trap 'rm -rf "$BK"' EXIT
BASE_SHA="$(sha256sum "$TOOL" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
UNAPPLIED=0
run_against() { TOPO_FROM_JSON_DIR="$1" "$PY" -B "$TEST" -v 2>&1; }

report() {   # $1 = name, $2 = mutant dir (empty when the anchor did not apply), $3 = test that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    if [[ -z "$2" ]]; then
        UNAPPLIED=$((UNAPPLIED+1))
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        return
    fi
    out="$(run_against "$2")"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-54s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-54s (%s stayed green -- that test proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR):|^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

mutant() {   # $1 = name, $2 = the anchor, $3 = its replacement; prints the mutant's directory, or nothing
    local name="$1" old="$2" new="$3"
    local d="$BK/$name"
    mkdir -p "$d"
    cp "$TOOL" "$d/topo_from_json.py"
    python3 - "$d/topo_from_json.py" "$old" "$new" >&2 <<'PY' || { echo ""; return; }
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor is not unique (%d hits): %r" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$(mutant base '        for i, field in enumerate(("name", "bridge name", "brand", "ip")):' \
                    '        for i, field in enumerate(("name", "bridge name", "brand", "ip")):')"
run_against "$base" | tail -1
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

m=$(mutant cables-dropped \
    '        ends[(a_dpid, a_port)] = (b_dpid, b_port)
        ends[(b_dpid, b_port)] = (a_dpid, a_port)
' \
    '        pass
')
report "cables-dropped: network() leaves the cable ends out" "$m" "test_cable_missing_names_the_switch_and_port"

m=$(mutant host-names-dropped '        if ha[0] != hb[0]:
' '        if False:
')
report "host-names-dropped: a host's device_name is not compared" "$m" "test_host_named_another_way"

m=$(mutant brand-dropped '            if fa[i] != fb[i]:
' '            if fa[i] != fb[i] and field != "brand":
')
report "brand-dropped: a switch's brand_name is not compared" "$m" "test_ovs_4_differs_from_p4_4_only_in_brand"

m=$(mutant host-mac-dropped '        if _mac_value(ha[1]) != _mac_value(hb[1]):
' '        if False:
')
report "host-mac-dropped" "$m" "test_host_mac_is_compared"

m=$(mutant host-attachment-dropped '        if ha[2] != hb[2]:
' '        if False:
')
report "host-attachment-dropped" "$m" "test_host_on_another_switch_port"

m=$(mutant switch-ip-dropped '            if fa[i] != fb[i]:
' '            if fa[i] != fb[i] and field != "ip":
')
report "switch-ip-dropped" "$m" "test_switch_agent_address_is_compared"

m=$(mutant switch-name-dropped '            if fa[i] != fb[i]:
' '            if fa[i] != fb[i] and field != "name":
')
report "switch-name-dropped" "$m" "test_switch_name_is_compared"

m=$(mutant bridge-name-dropped '            if fa[i] != fb[i]:
' '            if fa[i] != fb[i] and field != "bridge name":
')
report "bridge-name-dropped: the name switches() gives a switch is not compared" "$m" \
       "test_bridge_name_swap_between_two_switches_is_a_difference"

m=$(mutant one-way-cables-ignored '"one_way": _one_way_cables(model),' '"one_way": {},')
report "one-way-cables-ignored: a cable stored once reads as the same network" "$m" \
       "test_cable_stored_in_one_direction_only_is_a_difference"

m=$(mutant one-sided-switch-branch-deleted '        if only[side]:
' '        if False:
')
report "one-sided-switch-branch-deleted: a switch in one model only is not said" "$m" \
       "test_switch_present_only_in_the_first_model"

m=$(mutant host-only-side-swapped 'only in {la if hb is None else lb}' 'only in {lb if hb is None else la}')
report "host-only-side-swapped: a host in one model only names the other model" "$m" \
       "test_host_present_only_in_the_second_model"

m=$(mutant limit-ignored '    lines = [t[2] for t in found[:limit]]
    if len(found) > limit:
        lines.append(f"(+{len(found) - limit} more)")
' '    lines = [t[2] for t in found]
')
report "limit-ignored: every difference is returned" "$m" "test_a_different_size_is_cut_at_the_limit_with_the_rest_counted"

m=$(mutant refused-model-not-reported '    if bad:
        return bad
' '    if bad:
        return []
')
report "refused-model-not-reported: a model the fabric refuses reads as no difference" "$m" \
       "test_two_cables_on_one_port_is_not_a_model_the_fabric_could_build"

m=$(mutant switch-union-first-only '    for dpid in sorted(set(na["switches"]) | set(nb["switches"])):
' '    for dpid in sorted(set(na["switches"])):
')
report "switch-union-first-only: only the first model's switches are walked" "$m" \
       "test_switch_present_only_in_the_second_model"

m=$(mutant cable-union-first-only '    for end in sorted(set(na["ends"]) | set(nb["ends"])):
' '    for end in sorted(set(na["ends"])):
')
report "cable-union-first-only: only the first model's cable ends are walked" "$m" \
       "test_cable_present_only_in_the_second_model"

m=$(mutant one-way-in-either-model-is-a-difference '        if wa != wb:
' '        if wa is not None or wb is not None:
')
report "one-way-in-either-model-is-a-difference: a copy of a one-way model is refused" "$m" \
       "test_cable_stored_one_way_in_both_models_is_the_same"

m=$(mutant not-json-not-caught '        except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as exc:
' '        except (OSError, KeyError, TypeError, AttributeError, IndexError) as exc:
')
report "not-json-not-caught: text that is not JSON ends in a traceback" "$m" \
       "test_text_that_is_not_json_is_named_not_a_traceback"

m=$(mutant bridge-name-read-raw 'bridge[int(node["dpid"])]' 'node.get("bridge_name")')
report "bridge-name-read-raw: a missing bridge_name is not the name the fabric gives" "$m" \
       "test_bridge_name_left_out_is_the_name_the_fabric_gives_not_a_difference"

m=$(mutant cli-diff-rc-always-0 '        return 1 if lines else 0
' '        return 0
')
report "cli-diff-rc-always-0" "$m" "test_diff_says_rc_1_and_where_for_a_different_network"

m=$(mutant cli-fabric-model-env-leaks 'print(model_path(int(argv[3]), setting_dir=argv[2], env={}))' \
    'print(model_path(int(argv[3]), setting_dir=argv[2]))')
report "cli-fabric-model-env-leaks: the lookup reads the caller's environment" "$m" \
       "test_fabric_model_does_not_read_the_callers_ndtwin_p4_topo_file"

echo
if [[ "$(sha256sum "$TOOL" | cut -d' ' -f1)" != "$BASE_SHA" ]]; then
    echo "🔴 baseline CHANGED -- p4_proxy/mininet/topo_from_json.py was written during the gate"; exit 3
fi
echo "baseline byte-identical: yes  p4_proxy/mininet/topo_from_json.py  sha256 $BASE_SHA"
if [[ "$UNAPPLIED" -gt 0 ]]; then echo "🔴 REFUSED: $UNAPPLIED anchor(s) did not apply"; exit 2; fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
[[ "$SURVIVORS" -eq 0 ]]
