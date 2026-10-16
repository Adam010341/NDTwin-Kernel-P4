#!/usr/bin/env bash
#
# Mutation gate for tools/p4_exercise (TICKET-P1 §3).
#
# [Co-developed with claude code -- Adam]
#
# TICKET-P2 section 3.7 appended M-A4, M-A5 and M-A6 as 8, 9 and 10 (G4, the per-switch
# pipeline). The header below was written for the first seven and still describes them.
# Adam's ruling J (2026-09-27) appended 23-28, the fixture-provenance rule, and with them a
# fourth subject: tools/p4_exercise/tests/test_convert.py, where that rule lives.
# The paper-apps work (int-v1, 2026-10-16) appended 38-65 and a fifth subject,
# tools/p4_exercise/thrift_cli.py, the bmv2 CLI -> P4Runtime entry translator.
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies ten mutations to the
# three tools, re-runs the whole suite after each, and records WHICH test went red -- not merely
# that something did. Same shape as tests/shell/mutate_ryu_rest_topology_bounded.sh, with one
# difference: the subject is a different file per mutation, because the work item is three tools
# and a gate that only ever mutated one of them would be evidence about one of them.
#
# The seven, and why each is worth a line:
#
#   1. convert.py stops writing the reverse direction of an access link. Nothing raises: the
#      model still loads and `host_links()` still finds every host, because it reads whichever
#      direction it can. The half that is gone is the half the OTHER readers use.
#   2. convert.py puts a real dpid on the host side of an access edge. `host_links()` identifies
#      an access link by a FALSY dpid on one side (topo_from_json.py:127-133), so the link stops
#      being a host attachment and becomes an inter-switch cable that does not exist.
#   3. preflight.py accepts an entry naming a table the p4info does not have. This is the
#      mutation that matters most: a typo'd table name is valid JSON, installs nothing, and
#      leaves a switch forwarding nothing while the twin reports it healthy. If nothing goes red
#      here, pre-flight is a progress bar.
#   4. run_external_controller.py moves the address and leaves the device id. The connection
#      then succeeds and every request on it returns NOT_FOUND -- "the switch is up but the
#      rules did not take", which is a whole afternoon.
#   5. preflight.py stops checking an lpm prefix length against the field's width. bmv2 takes
#      the mask from that number; out of range it is either refused at install time or silently
#      truncated into a route that matches the wrong traffic.
#   6. preflight.py goes back to a hand-typed MatchType table. Not hypothetical: that table was
#      written, shipped for the length of one run, and made the first real pre-flight of
#      exercises/basic report every lpm entry as an unsupported TERNARY -- i.e. a pre-flight
#      that refuses the one package stage one exists to bring up. p4info.proto skips 1.
#   7. preflight.py stops enforcing the h<last octet> host naming rule. The proxy does not read
#      a host's device_name, it derives the name from the address (topo_from_json.py:86), so a
#      package that fails this rule builds hosts nobody in it can address.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any
# exit, and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not
# HEAD, so this runs against an uncommitted edit.
#
# One deliberate rule, the same as the gate this is modelled on: a mutant that does not parse,
# an anchor that has moved, or the wrong test going red all count as SURVIVORS -- never a
# warning, never a discount. A mutation that never reached the interpreter established nothing.
# None of the three aborts the remaining mutations.
#
# Usage:  tests/shell/mutate_p4_exercise_tools.sh
#         PYTHON=... tests/shell/mutate_p4_exercise_tools.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_p4_exercise_tools.sh   # NOT a gate result
# Assumes: cwd is the repo root (or this worktree's root).
# Exit:    0 all mutations caught, 1 a mutation survived, 2 refused (baseline red / not restored /
#          anchor-check mode, which never produces a verdict).
set -uo pipefail

# 🔴 NO BYTECODE CACHE. A .pyc is revalidated against the source's (mtime-in-SECONDS, size), and
# a mutation that keeps the file the same length -- #4 and #5 both nearly do -- applied within
# the same wall-clock second can be shadowed by the previous mutant's cache. The verdict would
# then describe a file that was never on disk. Both halves are needed: this stops new caches
# being written, and red_tests() removes any that already existed.
export PYTHONDONTWRITEBYTECODE=1

PYTHON="${PYTHON:-p4_proxy/venv/bin/python}"
PKG=tools/p4_exercise
TESTS="$PKG/tests"
CONVERT="$PKG/convert.py"
PREFLIGHT="$PKG/preflight.py"
ADAPTER="$PKG/run_external_controller.py"
# Ruling J (2026-09-27): the fixture-provenance RULE lives in the suite's own file -- it is what
# decides which fixture is byte-compared and which carries a compile command -- so that file is
# a subject too, snapshotted and restored with the three tools. [Co-developed with claude code -- Adam]
TESTCONV="$PKG/tests/test_convert.py"
# The bmv2 CLI translator (38-43). [Co-developed with claude code -- Adam]
THRIFT="$PKG/thrift_cli.py"

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

[[ -f "$CONVERT" ]]   || { echo "REFUSE: $CONVERT not found -- run from the repo root." >&2; exit 2; }
[[ -f "$PREFLIGHT" ]] || { echo "REFUSE: $PREFLIGHT not found -- run from the repo root." >&2; exit 2; }
[[ -f "$ADAPTER" ]]   || { echo "REFUSE: $ADAPTER not found -- run from the repo root." >&2; exit 2; }
[[ -f "$TESTCONV" ]]  || { echo "REFUSE: $TESTCONV not found -- run from the repo root." >&2; exit 2; }
[[ -f "$THRIFT" ]]    || { echo "REFUSE: $THRIFT not found -- run from the repo root." >&2; exit 2; }
[[ -d "$TESTS" ]]     || { echo "REFUSE: $TESTS not found -- run from the repo root." >&2; exit 2; }
[[ -x "$PYTHON" ]]    || { echo "REFUSE: no interpreter at $PYTHON (override with PYTHON=)." >&2; exit 2; }

# The venv interpreter is not optional: preflight.py parses p4info through the `p4` protobuf
# package, which only that environment has. Checked here rather than discovered as an ERROR in
# every test, which would look like a mutation being caught.
if ! "$PYTHON" -c 'from p4.config.v1 import p4info_pb2' >/dev/null 2>&1; then
    echo "REFUSE: $PYTHON cannot import p4.config.v1.p4info_pb2 -- use p4_proxy/venv/bin/python." >&2
    exit 2
fi

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- how many times the literal occurs. Shown for every mutation:
# an anchor matching twice silently mutates the wrong site, and one matching zero times makes
# the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a multi-line anchor would report the wrong number.
anchor_count() {
    ANCHOR="$2" "$PYTHON" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table -------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.

MUT_LABEL=(); MUT_SRC=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() { MUT_LABEL+=("$1"); MUT_SRC+=("$2"); MUT_ANCHOR+=("$3"); MUT_REPL+=("$4"); MUT_EXPECT+=("$5"); }

add "1. convert drops the reverse direction of every access link" \
    "$CONVERT" \
    '            edges.append(_edge(b_dpid, b_port, b_ip, 0, a[2], host["ip"], bps))' \
    '            pass  # MUTANT: the reverse direction is never written' \
    'test_every_link_is_stored_in_both_directions'

add "2. the host side of an access edge carries a real dpid instead of 0" \
    "$CONVERT" \
    '            edges.append(_edge(0, a[2], host["ip"], b_dpid, b_port, b_ip, bps))' \
    '            edges.append(_edge(b_dpid, a[2], host["ip"], b_dpid, b_port, b_ip, bps))' \
    'test_host_edges_carry_dpid_zero_on_the_host_side'

add "3. pre-flight accepts an entry naming a table the p4info does not have" \
    "$PREFLIGHT" \
    '    if table is None:
        known = ", ".join(index.table_names()[:6]) or "(none)"
        return [f"{where}: table {table_name!r} is not in the p4info (it has: {known})"]' \
    '    if table is None:
        return []  # MUTANT: an unknown table name is not a problem' \
    'test_a_bad_table_name_fails'

add "4. the adapter moves the address and leaves the device id behind" \
    "$ADAPTER" \
    '    return (f"localhost:{grpc_base + index}", index, index)' \
    '    return (f"localhost:{grpc_base + index}", device_id, index)  # MUTANT' \
    'test_device_id_moves_with_the_address'

add "5. pre-flight stops checking an lpm prefix length against the field width" \
    "$PREFLIGHT" \
    '            elif not 0 <= prefix <= field.bitwidth:' \
    '            elif False:  # MUTANT: the prefix length is never out of range' \
    'test_an_lpm_prefix_longer_than_the_field_fails'

# 6 and 7 are the two the judge asked for after the first delivery. Both are regressions of a
# defect that was actually made and actually shipped for the length of one run -- #6 is the
# hand-typed enum table, verbatim, that made the first real pre-flight of exercises/basic report
# every lpm entry as an unsupported TERNARY.
add "6. match_type_name goes back to the hand-typed (and wrong) enum table" \
    "$PREFLIGHT" \
    '    enum = p4info_pb2.MatchField.MatchType
    try:
        return enum.Name(int(value))
    except ValueError:
        return f"match_type {value}"' \
    '    del p4info_pb2  # MUTANT: transcribed instead of read, and p4info.proto skips 1
    return {0: "UNSPECIFIED", 1: "EXACT", 2: "LPM", 3: "TERNARY",
            4: "RANGE", 5: "OPTIONAL"}.get(int(value), f"match_type {value}")' \
    'test_the_match_type_names_come_out_of_the_enum'

add "7. pre-flight stops enforcing the h<last octet> host naming rule" \
    "$PREFLIGHT" \
    '        if name != expected:
            wrong.append(f"{name} on {ip} would be built as {expected}")' \
    '        if False:  # MUTANT: a host may be named anything
            wrong.append(f"{name} on {ip} would be built as {expected}")' \
    'test_a_host_whose_name_does_not_match_its_address_fails'

# 8, 9 and 10 are TICKET-P2 section 3.7's M-A4, M-A5 and M-A6 -- the converter and pre-flight
# halves of G4, the per-switch pipeline. All three describe a package that pre-flights green and
# brings a fabric up that runs the wrong program: nothing crashes, every switch forwards, and the
# twin reports health throughout. `firewall` is the discriminating exercise and the only one
# there is -- its pod-topo topology.json is the single shipped use of tutorials' per-switch
# `program` override (s1 build/firewall.json, s2-s4 the Makefile's DEFAULT_PROG basic.p4).
add "8. convert drops the per-switch 'program', so every switch runs the default" \
    "$CONVERT" \
    '        p4info_rel, json_rel = (artefacts_for_program(declared[dpid], exercise_dir)
                                if declared[dpid] else default)' \
    '        p4info_rel, json_rel = default  # MUTANT: the program override is ignored' \
    'test_the_switch_that_names_a_program_gets_it_and_the_others_get_the_default'

add "9. pre-flight stops checking that the p4info is a subset of the bmv2 json" \
    "$PREFLIGHT" \
    '        if stray_tables or stray_actions:' \
    '        if False:  # MUTANT: two halves of two different compiles are fine' \
    'test_a_p4info_naming_a_table_the_bmv2_json_does_not_have_fails'

add "10. pre-flight accepts entries written against a program the switch does not run" \
    "$PREFLIGHT" \
    '    wrong = [(k, used_p4info[k], pipeline_p4info[k]) for k in shared
             if used_p4info[k] != pipeline_p4info[k]]' \
    '    wrong = []  # MUTANT: whichever p4info the entries name is fine' \
    'test_entries_written_for_another_program_fail'

# 11-16 close the gaps the P2-A judge found: 53 new tests against 10 named mutations. Each of
# these is a green pre-flight or a green conversion in front of a package that cannot be brought
# up, or can be brought up running the wrong thing.
add "11. --ndtwin-pipeline stops meaning anything, so the phase-1 cell runs the exercise's programs" \
    "$CONVERT" \
    '    if ndtwin_pipeline:' \
    '    if False:  # MUTANT: the flag is accepted and ignored' \
    'test_the_ndtwin_pipeline_flag_nulls_every_switch_including_the_one_with_a_program'

add "12. a declared per-switch program with no --p4 is silently ignored instead of refused" \
    "$CONVERT" \
    '        named = sorted(dpid for dpid, prog in declared.items() if prog)' \
    '        named = []  # MUTANT: nobody declared a program, so nothing to refuse' \
    'test_a_program_without_p4_is_refused_rather_than_half_applied'

# 13: the sha is the ONLY stable identifier either half of a pipeline has -- the bmv2 json's own
# sha moves with the directory it was compiled in (TICKET-P1 B measured it). Without it printed,
# "is this the program those entries were written for" has no answer an operator can quote.
add "13. the per-switch INFO row stops printing the p4info sha256" \
    "$PREFLIGHT" \
    '        sha = _sha16(paths["p4info"])' \
    '        sha = "not printed"  # MUTANT: no stable identifier in the report' \
    'test_the_printed_sha_is_the_p4infos_own'

# 14 and 15 are the two halves of one sentence: PRE-FLIGHT MUST REFUSE EXACTLY WHAT THE LOADER
# REFUSES. A pre-flight that is more permissive hands the operator a green table and then dies
# inside app_package.load at `ndt up p4 --app`, with `mn -c` possibly already run, over a package
# this tool approved. Both cells assert the loader's refusal too, so neither can be made green by
# relaxing only this file.
add "14. a pipeline may resolve outside the package directory" \
    "$PREFLIGHT" \
    '    if not (real == root or real.startswith(root + os.sep)):' \
    '    if False:  # MUTANT: outside the package is fine here, and fatal at bring-up' \
    'test_a_pipeline_escaping_the_package_directory_fails_here_and_not_only_at_bring_up'

add "15. an absolute pipeline path is accepted here and refused by the loader" \
    "$PREFLIGHT" \
    '    if os.path.isabs(str(rel)):' \
    '    if False:  # MUTANT: absolute is fine here, and fatal at bring-up' \
    'test_an_absolute_pipeline_path_fails_here_and_not_only_at_bring_up'

add "16. a p4info that exists but does not parse is skipped instead of reported" \
    "$PREFLIGHT" \
    '        except Exception as exc:  # noqa: BLE001 -- an unreadable p4info is a FAIL, not a crash' \
    '        except Exception as exc:  # MUTANT: the file is there, so the file is fine
            continue
        except Exception as exc:  # unreachable once the mutant above catches everything' \
    'test_a_p4info_that_exists_but_does_not_parse_fails_by_name'

# 17-22 are TICKET-P3 2.6's convert / pre-flight half: the exercise's own CPU port (G9b), the
# telemetry word, and the PRE entries a runtime file declares (G8/G9a). The proxy-side mutations
# of the same ticket are in tests/shell/mutate_telemetry_by_name.sh -- split on the file that is
# mutated rather than on the ticket, so each gate's baseline check still means something.
#
# Every one of these is a package that pre-flights green and then produces a fabric where the
# failure is a host that does not receive: a switch launched on the wrong CPU port drops every
# controller packet, a group replicating into a port the fabric does not build delivers to
# nobody, and two replicas sharing an instance id are one replica inside the PRE.
add "17. two switches may ask for two different CPU ports, and one is silently given the other's" \
    "$CONVERT" \
    '    values = sorted(set(declared.values()))
    if len(values) > 1:' \
    '    values = sorted(set(declared.values()))
    if False:  # MUTANT: whichever one sorts first wins, for every switch' \
    'test_switches_that_disagree_are_refused_and_both_are_named'

add "18. a cpu_port written as a string stays a string" \
    "$CONVERT" \
    '    elif isinstance(raw, str) and raw.strip():
        try:
            value = int(raw.strip(), 0)' \
    '    elif isinstance(raw, str) and raw.strip():
        try:
            value = raw.strip()  # MUTANT: flowcache asks for "510" and gets "510"' \
    'test_a_string_cpu_port_becomes_an_integer'

add "19. pre-flight accepts a telemetry source outside the value domain" \
    "$PREFLIGHT" \
    '        if source in TELEMETRY_WORDS:' \
    '        if True:  # MUTANT: any word is a telemetry source' \
    'test_a_word_outside_the_domain_fails'

add "20. pre-flight lets a program with no controller header be asked for cooperative telemetry" \
    "$PREFLIGHT" \
    '        absent = [name for name in PACKET_IN_FIELDS
                  if name not in packet_in_fields(index.p4info)]' \
    '        absent = []  # MUTANT: every program can clone to the CPU port' \
    'test_cooperative_on_a_program_with_no_controller_header_fails'

add "21. a multicast replica may name a port the fabric does not build" \
    "$PREFLIGHT" \
    '                if known and port not in known and port != cpu_port:
                    problems.append(
                        f"{where} replica {j}: egress_port {port} is not a port s{dpid} has -- "' \
    '                if False:  # MUTANT: the PRE will take it, so it must be fine
                    problems.append(
                        f"{where} replica {j}: egress_port {port} is not a port s{dpid} has -- "' \
    'test_a_replica_on_a_port_the_model_does_not_build_fails'

add "22. the same (port, instance) twice is accepted, and the group is quietly smaller" \
    "$PREFLIGHT" \
    '                if (port, instance) in seen:' \
    '                if False:  # MUTANT: the PRE holds both. It does not.' \
    'test_the_same_replica_twice_fails'

# 23-28 are Adam's ruling J (2026-09-27), the P3-C precedent (c) made a rule: a build ARTIFACT
# (a compiler output under build/) leaves byte provenance and carries the command that made it;
# every SOURCE -- the .p4 files, the topology and runtime files, mycontroller.py -- stays
# byte-compared with ~/tutorials. The live runs recompile ~/tutorials/*/build, so an artifact
# compared by bytes turned the suite red on whatever program was compiled last; a source that
# slipped out of the comparison would turn nothing red at all. These are killed by
# TheProvenanceRule's cells, which write their own trees and so run on a machine with no
# ~/tutorials -- CI included. [Co-developed with claude code -- Adam]
add "23. build artifacts are byte-compared again, so every live run's recompile is a red suite" \
    "$TESTCONV" \
    '    return "build" in parts[:-1] and parts[-1].endswith(BUILD_OUTPUT_SUFFIXES)' \
    '    return False  # MUTANT: nothing is an artifact; every build output is compared by bytes' \
    'test_a_rebuilt_build_artifact_is_not_a_provenance_failure'

add "24. whatever sits under build/ is an artifact, so a .p4 copied there is never compared" \
    "$TESTCONV" \
    '    return "build" in parts[:-1] and parts[-1].endswith(BUILD_OUTPUT_SUFFIXES)' \
    '    return "build" in parts[:-1]  # MUTANT: the directory alone decides' \
    'test_a_p4_source_inside_a_build_directory_is_still_compared'

add "25. a .p4 source leaves byte provenance with the artifacts compiled from it" \
    "$TESTCONV" \
    '            if is_build_artifact(rel) or rel in authored:' \
    '            if is_build_artifact(rel) or rel in authored or rel.endswith(".p4"):  # MUTANT' \
    'test_a_changed_p4_source_is_still_a_provenance_failure'

add "26. a build artifact with no recorded command is exempt from everything" \
    "$TESTCONV" \
    '    unrecorded = sorted(in_tree - set(recorded))' \
    '    unrecorded = []  # MUTANT: the record is optional' \
    'test_an_unrecorded_build_artifact_is_named'

add "27. a source can be exempted by listing it as a build artifact" \
    "$TESTCONV" \
    '    not_artifacts = sorted(set(recorded) - in_tree)' \
    '    not_artifacts = []  # MUTANT: whatever is listed is exempt' \
    'test_a_source_listed_as_a_build_artifact_is_named'

add "28. a recorded command names a source the artifact was not compiled from" \
    "$TESTCONV" \
    '         _p4c(f"{_TUT}/basic/basic.p4", f"{_TUT}/basic/build", "basic")),' \
    '         _p4c(f"{_TUT}/basic/solution/basic.p4", f"{_TUT}/basic/build", "basic")),  # MUTANT' \
    'test_the_generated_fixtures_are_all_there_and_are_the_only_exemptions'

# 29-35 are the ternary writer's pre-flight half (G5): the "G5 not done" refusal is gone, and in
# its place pre-flight runs the PROXY'S OWN shape check (p4_proxy/proxy_agent/match_shape.py,
# imported by path, never copied) on ternary, range and optional fields, plus the priority rule,
# the omitted-exact-field rule and the lpm /0 and host-bit rules. The shape rules themselves are
# mutated in tests/shell/mutate_table_entry.sh, where match_shape.py is the subject; what is
# mutated HERE is that this file still ASKS. A pre-flight that stopped asking would be green in
# front of a package the proxy refuses entry by entry after the fabric is up.
# [Co-developed with claude code -- Adam]
add "29. pre-flight treats a ternary, range or optional field as an exact one, and refuses the right shape" \
    "$PREFLIGHT" \
    '        if kind not in _EXACT_OR_LPM:' \
    '        if False:  # MUTANT: every match type is checked as an exact one' \
    'test_ternary_entries_with_a_mask_and_a_priority_pass'

add "30. pre-flight swallows the shape check's refusal, so a value outside its mask passes" \
    "$PREFLIGHT" \
    '            except (match_shape.TableEntryInvalid, match_shape.TableEntryUnsupported) as exc:
                problems.append(f"{where}: {exc}")' \
    '            except (match_shape.TableEntryInvalid, match_shape.TableEntryUnsupported) as exc:
                pass  # MUTANT: the refusal is dropped' \
    'test_a_ternary_value_with_a_bit_outside_its_mask_fails'

add "31. pre-flight stops asking for a priority on a table that has a priority column" \
    "$PREFLIGHT" \
    '        match_shape.shape_priority(table_name, kinds, entry.get("priority"), is_default)' \
    '        pass  # MUTANT: the priority is never checked' \
    'test_a_ternary_entry_with_no_priority_fails_saying_it_needs_one'

add "32. pre-flight lets an exact field be left out of an entry" \
    "$PREFLIGHT" \
    '    if exact_missing and not is_default and (match or match_shape.table_has_priority_column(kinds)):' \
    '    if False:  # MUTANT: an omitted exact field is fine' \
    'test_an_exact_field_left_out_of_a_match_fails'

add "33. pre-flight refuses an entry with no match even where that is a legal catch-all" \
    "$PREFLIGHT" \
    '    if not is_default and not match and not match_shape.table_has_priority_column(kinds):' \
    '    if not is_default and not match:  # MUTANT: the priority column no longer excuses it' \
    'test_a_ternary_entry_with_no_match_at_all_passes_when_it_has_a_priority'

add "34. pre-flight drops the lpm host-bit and /0 refusals" \
    "$PREFLIGHT" \
    '                    if exc.rule in ("V5", "V9"):' \
    '                    if False:  # MUTANT: the writer refuses these and pre-flight does not' \
    'test_an_lpm_value_with_host_bits_fails'

add "35. pre-flight accepts a non-zero priority on a table that has no priority column" \
    "$PREFLIGHT" \
    '        match_shape.shape_priority(table_name, kinds, entry.get("priority"), is_default)' \
    '        match_shape.shape_priority(table_name, ["TERNARY"], entry.get("priority"), is_default)  # MUTANT' \
    'test_a_non_zero_priority_on_a_table_with_no_priority_column_fails'

add "36. pre-flight holds a default entry to the non-default priority rule" \
    "$PREFLIGHT" \
    '        match_shape.shape_priority(table_name, kinds, entry.get("priority"), is_default)' \
    '        match_shape.shape_priority(table_name, kinds, entry.get("priority"), False)  # MUTANT' \
    'test_a_default_entry_with_a_priority_fails_on_a_table_with_a_priority_column'

# [Co-developed with claude code -- Adam] 37: the refusal that G5 removed, put back. Test 398 of
# test_preflight.py asserts the sentence is gone, and no earlier mutation ever brought it back, so
# that test had never been seen red.
add "37. pre-flight refuses a ternary, range or optional field again with the old 'G5 not done' sentence" \
    "$PREFLIGHT" \
    '                match_shape.shape_field(f"{table_name}.{field_name}", kind, field.bitwidth, value)' \
    '                problems.append(f"{where}: {kind} match is not supported (G5 not done)")  # MUTANT' \
    'test_the_old_g5_sentence_is_gone_from_a_ternary_package'

# 38-47: the paper-apps work (int-v1 @84a3ebe8, MIT). int-v1 installs its INT source rules with
# `simple_switch_CLI <<< "table_add ..."` and builds its p4info under the pre-2024 tutorials name,
# so `--thrift-commands` translates CLI commands into the switch's runtime file and the converter
# finds `<stem>.p4.p4info.txt` as well as `.txtpb`. Every one of these is a package that converts
# and then installs a rule the app did not ask for, or misses one it did: the INT source table is
# where the app's whole effect lives, and a fabric without it forwards everything and reports
# healthy. Killed by tools/p4_exercise/tests/test_thrift_cli.py. [Co-developed with claude code -- Adam]
add "38. a ternary value is copied as the CLI wrote it, and P4Runtime refuses it after bring-up" \
    "$THRIFT" \
    '        masked = value & mask' \
    '        masked = value  # MUTANT: the CLI value is copied, not masked' \
    'test_a_ternary_value_is_masked_the_way_thrift_masks_it'

add "39. a zero-mask ternary field is written as a field instead of omitted" \
    "$THRIFT" \
    '        if mask == 0:' \
    '        if False:  # MUTANT: a zero mask goes on the wire' \
    'test_a_zero_mask_field_is_omitted_and_said'

add "40. the CLI priority keeps its own direction, so the order inside a table is reversed" \
    "$THRIFT" \
    '        p4rt = PRIORITY_MAX - prio' \
    '        p4rt = prio + 1  # MUTANT: lower CLI priority stays lower' \
    'test_the_lower_thrift_priority_is_the_higher_p4runtime_priority'

add "41. an ambiguous short name picks the first candidate" \
    "$THRIFT" \
    '        if len(hits) == 1:
            return hits[0]' \
    '        if hits:
            return hits[0]  # MUTANT: the first one sorted wins' \
    'test_an_ambiguous_short_name_is_refused_naming_both'

add "42. a script line that is not a CLI call is skipped instead of refused" \
    "$THRIFT" \
    '        if m is None:
            raise Untranslatable(' \
    '        if m is None:
            continue  # MUTANT: what cannot be read is not there
            raise Untranslatable(' \
    'test_a_shell_line_that_is_not_a_cli_call_is_refused'

add "43. a CLI command that is not translated is skipped instead of refused" \
    "$THRIFT" \
    '            else:
                raise Untranslatable(
                    f"line {number}: {verb!r} is not translated -- only "' \
    '            else:
                continue  # MUTANT: an unknown command is dropped
                raise Untranslatable(
                    f"line {number}: {verb!r} is not translated -- only "' \
    'test_an_unsupported_cli_command_is_refused_by_name'

add "44. convert stops finding the pre-2024 tutorials p4info name (.p4.p4info.txt)" \
    "$CONVERT" \
    'P4INFO_SUFFIXES = (".p4.p4info.txtpb", ".p4.p4info.txt")' \
    'P4INFO_SUFFIXES = (".p4.p4info.txtpb",)  # MUTANT: only the current name' \
    'test_a_pre_2024_tutorials_p4info_named_txt_is_found'

add "45. two p4infos for one program: the first name is taken instead of refused" \
    "$CONVERT" \
    '    if len(present) > 1:' \
    '    if False:  # MUTANT: whichever suffix is listed first wins' \
    'test_both_spellings_present_is_refused_naming_both'

add "46. the translated entries are not written into the runtime file" \
    "$CONVERT" \
    '        doc["table_entries"] = list(existing) + entries' \
    '        doc["table_entries"] = list(existing)  # MUTANT: translated, then dropped' \
    'test_the_commands_are_appended_to_the_switchs_runtime_file'

add "47. the route role re-reads the app file and loses the translated entries" \
    "$CONVERT" \
    '        doc = (json.loads(rewrites[rel]) if rel in rewrites
               else common.load_json(os.path.join(exercise_dir, rel)))' \
    '        doc = common.load_json(os.path.join(exercise_dir, rel))  # MUTANT' \
    'test_the_route_role_keeps_the_translated_entries'

# 48-49: found on int-v1 itself -- its int.p4 is five quoted includes, and a package carrying only
# the top file fails pre-flight's recompile (p4c-bm2-ss rc=1), so `ndt up p4 --app` refuses it.
add "48. convert carries the .p4 but not the files it includes" \
    "$CONVERT" \
    '        copies.extend(_local_includes(exercise_dir, p4_rel))' \
    '        pass  # MUTANT: only the top file is carried' \
    'test_a_p4_with_local_includes_carries_them_transitively'

add "49. an include outside the app directory is carried instead of refused" \
    "$CONVERT" \
    '            if not real.startswith(root + os.sep):' \
    '            if False:  # MUTANT: any file the program names is the app'"'"'s' \
    'test_an_include_that_leaves_the_app_directory_is_refused'

# 50-65: round 2 of the paper-apps work (review r1 of e77e35c5). The translator's own refusals that
# had been seen red only against an API stub, and the rules added in that round: one address per
# script, shell metacharacters in a flag, runtime_CLI's decimal IPv4 parts, the CLI priority bound
# of the exact inverse, an lpm /0 on a table with no priority column, a script outside the app, a
# runtime file two switches share, and the include walk's resolved-path guard. Killed by
# tools/p4_exercise/tests/test_thrift_cli.py. [Co-developed with claude code -- Adam]
add "50. a script whose calls name two thrift addresses is put on one switch" \
    "$THRIFT" \
    '    if len(distinct) > 1:' \
    '    if False:  # MUTANT: every call reaches the same switch' \
    'test_two_cli_addresses_in_one_script_are_refused'

add "51. an address variable assigned twice is accepted" \
    "$THRIFT" \
    '        if assigned.get(name, 0) > 1:' \
    '        if False:  # MUTANT: the last assignment is the only one' \
    'test_an_address_variable_assigned_twice_is_refused'

add "52. a flag carrying a shell metacharacter is read as an address" \
    "$THRIFT" \
    '        if bad:
            raise Untranslatable(' \
    '        if False:  # MUTANT: 9090;true is a port
            raise Untranslatable(' \
    'test_a_flag_with_a_shell_metacharacter_is_refused'

add "53. a command that needs the shell to expand it is translated as written" \
    "$THRIFT" \
    '        if "$" in command or "`" in command:' \
    '        if False:  # MUTANT: $X is a value' \
    'test_a_command_that_needs_the_shell_to_expand_it_is_refused'

add "54. any CLI flag is skipped as if it named the address" \
    "$THRIFT" \
    '            if flags[i] in _ADDRESS_FLAGS and i + 1 < len(flags):' \
    '            if i + 1 < len(flags):  # MUTANT: --json other.json is an address' \
    'test_a_cli_flag_other_than_the_thrift_address_is_refused'

add "55. a value wider than its field is passed on" \
    "$THRIFT" \
    '    if value >= (1 << bitwidth):' \
    '    if False:  # MUTANT: the writer can sort it out' \
    'test_a_value_too_wide_for_its_field_is_refused'

add "56. an lpm value with host bits is passed on" \
    "$THRIFT" \
    '        if value & host:' \
    '        if False:  # MUTANT: host bits are fine' \
    'test_an_lpm_value_with_host_bits_is_refused_not_masked'

add "57. a range that runs backwards is passed on" \
    "$THRIFT" \
    '        if low > high:' \
    '        if False:  # MUTANT: 200->100 is a range' \
    'test_a_range_running_backwards_is_refused'

add "58. a CLI priority above 2^31-2 is accepted and maps outside P4Runtime" \
    "$THRIFT" \
    '        if not 0 <= priority <= PRIORITY_MAX - 1:' \
    '        if priority < 0:  # MUTANT: no upper bound' \
    'test_a_cli_priority_of_two_to_the_31_minus_one_or_more_is_refused'

add "59. --thrift-commands on an external control plane is accepted" \
    "$CONVERT" \
    '    if mode == "external":
        raise ConversionError(
            "--thrift-commands on an external control plane' \
    '    if False:  # MUTANT: the app controller will not mind
        raise ConversionError(
            "--thrift-commands on an external control plane' \
    'test_an_external_control_plane_is_refused'

add "60. IPv4 parts are read as inet_aton reads them (010 is octal)" \
    "$THRIFT" \
    '            octets = [int(p) for p in parts]' \
    '            octets = list(socket.inet_aton(text))  # MUTANT: not the CLI reading' \
    'test_a_leading_zero_in_an_ipv4_part_is_decimal_as_in_the_cli'

add "61. an lpm /0 on a table with no priority column becomes an empty match" \
    "$THRIFT" \
    '    if not match and not needs_priority:' \
    '    if False:  # MUTANT: pre-flight can refuse it later' \
    'test_an_lpm_slash_zero_on_a_table_with_no_priority_column_is_refused'

add "62. a CLI script outside the app directory is carried" \
    "$CONVERT" \
    '        if os.path.isabs(rel) or not real.startswith(root + os.sep):' \
    '        if os.path.isabs(rel):  # MUTANT: ../ is inside enough' \
    'test_a_script_outside_the_app_directory_is_refused'

add "63. entries translated for one switch go into a runtime file another switch reads" \
    "$CONVERT" \
    '        if len(sharing) > 1:' \
    '        if False:  # MUTANT: one file, one switch' \
    'test_a_runtime_file_two_switches_share_is_refused'

add "64. the include walk keys what it has seen by the lexical path" \
    "$CONVERT" \
    '            if real in seen:' \
    '            if cand in seen:  # MUTANT: a symlinked directory is a new place' \
    'test_a_directory_symlink_to_an_ancestor_does_not_grow_the_walk'

add "65. an include that cannot be read escapes as a raw OSError" \
    "$CONVERT" \
    '        except OSError as exc:
            raise ConversionError(f"{rel} (an included file of' \
    '        except FileNotFoundError as exc:  # MUTANT
            raise ConversionError(f"{rel} (an included file of' \
    'test_an_include_that_cannot_be_read_is_a_named_refusal'

CTRL_SRC="$CONVERT"
CTRL_ANCHOR='def build_model(hosts, switches, links):'
CTRL_REPL='# MUTANT: a comment, and nothing else.
def build_model(hosts, switches, links):'
# The fourth subject gets its own control (judge K-N12): six mutants there go red, and without a
# comment-only edit of the same file staying green, "test_convert.py reddens for anything" would
# print the same six lines. [Co-developed with claude code -- Adam]
CTRL2_SRC="$TESTCONV"
CTRL2_ANCHOR='def is_build_artifact(rel):'
CTRL2_REPL='# MUTANT: a comment, and nothing else.
def is_build_artifact(rel):'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " No mutation was applied and no test was run. The exit code is 2"
    echo " on purpose so this can never be mistaken for a passing gate."
    echo " Run without ANCHOR_CHECK/--dry-run for a verdict."
    echo "================================================================"
    broken=0
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches  (%s)\n' "$n" "${MUT_LABEL[$i]}"; broken=$((broken + 1))
        fi
    done
    n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR")
    if [[ "$n" -eq 1 ]]; then
        printf '  ok    %s  (negative control)\n' "$n"
    else
        printf '  🔴 %s matches  (negative control)\n' "$n"; broken=$((broken + 1))
    fi
    n=$(anchor_count "$CTRL2_SRC" "$CTRL2_ANCHOR")
    if [[ "$n" -eq 1 ]]; then
        printf '  ok    %s  (negative control 2, test_convert.py)\n' "$n"
    else
        printf '  🔴 %s matches  (negative control 2, test_convert.py)\n' "$n"; broken=$((broken + 1))
    fi
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all ${#MUT_LABEL[@]} mutations plus the control resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- baseline snapshot --------------------------------------------------------------------------

BK=$(mktemp -d)
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER" "$TESTCONV" "$THRIFT"; do
    cp -p "$f" "$BK/$(basename "$f")"
done
restore() {
    for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER" "$TESTCONV" "$THRIFT"; do
        cp -p "$BK/$(basename "$f")" "$f"
        # cp -p puts the ORIGINAL mtime back. Nothing here is compiled, so no build system can
        # be fooled -- but __pycache__ is keyed on mtime and size, and an unlucky pair would let
        # a stale .pyc be imported. touch removes that possibility for the cost of a syscall.
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK" "$PKG/__pycache__" "$TESTS/__pycache__"' EXIT

MUTATIONS=0
SURVIVORS=0

# red_tests -- the space-separated names of the test methods that failed or errored.
red_tests() {
    local out rc
    rm -rf "$PKG/__pycache__" "$TESTS/__pycache__"
    out=$("$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <src> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" src="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$src" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  subject           : %s\n' "$src"
    printf '  anchor occurrences: %s\n' "$n"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" "$PYTHON" - "$src" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    # A mutant that does not parse never reached the tests, so it establishes nothing about them.
    if ! "$PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$src" >/dev/null 2>&1; then
        echo "  🔴 MUTANT DOES NOT PARSE -- the behaviour it was aimed at is still untested."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif /usr/bin/grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline -----------------------------------------------------------------------------------

echo "TICKET-P1 §3 p4_exercise tools mutation gate"
echo "  interpreter : $PYTHON"
echo "  subjects    : $CONVERT"
echo "                $PREFLIGHT"
echo "                $ADAPTER"
echo "                $TESTCONV (the fixture-provenance rule, ruling J)"
echo "                $THRIFT (the bmv2 CLI translator, 38-43)"
echo "  suite       : $TESTS"
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER" "$TESTCONV" "$THRIFT"; do
    printf '  baseline    : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"
done
echo
echo "baseline (unmutated) must be green:"
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
"$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- mutations ----------------------------------------------------------------------------------

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

# --- negative control ---------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave the suite green;
# if this goes red the suite is a change detector, not a specification.

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR")
printf '  subject           : %s\n' "$CTRL_SRC"
printf '  anchor occurrences: %s\n' "$n"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" "$PYTHON" - "$CTRL_SRC" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    ctrl_red=$(red_tests)
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        echo "     These tests are change detectors, not a specification."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
fi

printf '\n=== NEGATIVE CONTROL 2: comment-only edit of test_convert.py must stay GREEN ===\n'
n=$(anchor_count "$CTRL2_SRC" "$CTRL2_ANCHOR")
printf '  subject           : %s\n' "$CTRL2_SRC"
printf '  anchor occurrences: %s\n' "$n"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL2_ANCHOR" REPL="$CTRL2_REPL" "$PYTHON" - "$CTRL2_SRC" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    ctrl_red=$(red_tests)
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment in test_convert.py"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
fi

# --- byte-identity and verdict ------------------------------------------------------------------

restore
printf '\n--- baseline restored? ---\n'
bad_restore=0
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER" "$TESTCONV" "$THRIFT"; do
    if cmp -s "$BK/$(basename "$f")" "$f"; then
        printf '  byte-identical  %s\n' "$f"
    else
        printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$f"; bad_restore=1
    fi
done
[[ "$bad_restore" -eq 0 ]] || exit 2

after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    printf '🔴 THE SUITE IS RED AFTER RESTORE: %s\n' "$after_red"
    echo "   A mutant is still on disk. Do NOT commit."; exit 2
fi
echo "  suite green again after restore"

# Said out loud rather than left to be noticed: the tests no mutation above is expected to
# redden are not evidence about these seven behaviours. The reproducibility test
# (test_two_conversions_are_byte_identical) and the p4c rows are regression guards -- green
# against a tool that does the wrong thing consistently -- and the read-back tests would also
# go red under #2, which is why #2 names the dpid test and not one of them.
printf '\nnot reddened by design: test_two_conversions_are_byte_identical and the p4c rows\n'
printf '(regression guards; they discriminate nothing about the %d behaviours above)\n' "${#MUT_LABEL[@]}"

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
