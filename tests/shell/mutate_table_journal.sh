#!/usr/bin/env bash
#
# Mutation gate for the table-entry journal: `rule_journal.TableEntryJournal` / `TableJournals` /
# `fold_records`, what `POST /p4/table_entry` and `switch_state` say about it, and the identity a
# default entry gets. DESIGN.md sections 5.1-5.3, 5.6 and 6.3 (Cut B: M-J1-M-J3, M-J12-M-J14).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 WHAT THE TESTS HERE HOLD THE CODE TO IS "RECORDED", NEVER "JOURNALED". Nothing replays the
# journal yet, so the claim that an entry survives a restart is false and every surface says so:
# `journaled` is False in the POST response and in switch_state, and `journal.recorded` says what
# is true. M-J30 (the replay constant flipped), M-J30b (the claim ignoring whether this write was
# recorded) and M-J30c (switch_state's claim ignoring the replay constant) are the mutations that
# would turn the health check's T8 green on a record nothing reads back, and each has a killer.
#
# 🔴 THE MUTANT IS A COPY, as in mutate_table_entry.sh: every mutation is applied to a copy of
# p4_proxy under a temp dir, nothing under p4_proxy/ is written, and all sources and test files are
# re-hashed at the end. `setting/`, `tools/` and `p4_proxy/` are linked in as INPUTS.
#
# Numbering is the design's where it has one (M-J1, M-J2, M-J3, M-J12, M-J13a-c, M-J14, M-J23);
# the rest are this cut's own, M-J30 upward, and say what they break.
#
# Mutations that cannot be seen by any test, and are therefore NOT here, on purpose:
#   * the fsync calls (a test cannot tell a flushed page from one still in the cache);
#   * `_fsync_directory` for the same reason.
#
# Usage:  tests/shell/mutate_table_journal.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_table_journal.sh
# Exit:   0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#         baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
JOURNAL="$REPO/p4_proxy/proxy_agent/rule_journal.py"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
INSTALL="$REPO/p4_proxy/proxy_agent/rule_install_times.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
TEST_JOURNAL="$REPO/p4_proxy/tests/test_table_entry_journal.py"
TEST_ROUTE="$REPO/p4_proxy/tests/test_table_entry_route.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TEST_INSTALL="$REPO/p4_proxy/tests/test_rule_install_times.py"
TEST_PROXY="$REPO/p4_proxy/tests/test_app_package_proxy.py"

MODULES="tests.test_table_entry_journal tests.test_table_entry_route tests.test_p4_client_writes \
tests.test_rule_install_times tests.test_app_package_proxy"

MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-tablejournal-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
ln -s "$REPO/setting" "$BK/setting"
ln -s "$REPO/tools" "$BK/tools"
ln -s "$REPO/p4_proxy" "$BK/p4_proxy"

BASE_JOURNAL=$(sha256sum "$JOURNAL" | cut -d' ' -f1)
BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_INSTALL=$(sha256sum "$INSTALL" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_TEST_JOURNAL=$(sha256sum "$TEST_JOURNAL" | cut -d' ' -f1)
BASE_TEST_ROUTE=$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TEST_INSTALL=$(sha256sum "$TEST_INSTALL" | cut -d' ' -f1)
BASE_TEST_PROXY=$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    # 🔴 A SUITE THAT DID NOT FINISH IS NOT A VERDICT, in either direction. `timeout 300`
    # returns 124, and unittest prints its `FAIL: <name>` section at the END -- so a mutant
    # that hangs the run produces no named failure and would be scored a survivor of nothing.
    # Named, and it fails the gate. (mutate_app_package.sh carries the same branch, and the
    # 2026-09-18 incident that put it there.)
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-72s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-72s (%s went red)\n' "$1" "$3"
        # 🔴 EVERY test that reddened, not only the one this mutation is named for.
        # [Co-developed with claude code -- Adam]
        # A gate that records one name per mutation cannot answer the question an auditor
        # actually asks -- "which of these tests has ever been seen to fail?" -- for any test
        # that is not somebody's named killer. M-B24 reddens
        # test_the_default_action_row_every_runtime_file_carries_is_a_modify as well as its own
        # named case, and round 2's log said nothing about it, so that test read as unproven
        # when it was not. Printed, not counted: the verdict is still the named one.
        /usr/bin/grep -E '^(FAIL|ERROR): ' <<<"$out" \
            | sed -E 's/^(FAIL|ERROR): [^(]*\(([^)]*)\).*/             also red: \2/' \
            | sort -u
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-72s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    mkdir -p "$d/p4_src"
    cp -r "$REPO/p4_proxy/p4_src/build" "$d/p4_src/" 2>/dev/null
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}


echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
mkdir -p "$base/p4_src"; cp -r "$REPO/p4_proxy/p4_src/build" "$base/p4_src/" 2>/dev/null
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | /usr/bin/grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the write: switch first, journal second, one lock around both -----------------------------

m=$(mutant j1 "$JOURNAL" \
    '            try:
                written = client.write_table_entry(spec, op)
            except Exception as exc:  # noqa: BLE001 -- inspected, then re-raised unchanged' \
    '            if self.enabled:
                self._record(journal, op, spec, key_digest(client.table_entry_key(spec)), "ok")
            try:
                written = client.write_table_entry(spec, op)
            except Exception as exc:  # noqa: BLE001 -- inspected, then re-raised unchanged')
report 'M-J1: the journal is written BEFORE the switch, so a refused entry sits in it' "$m" \
       'test_a_write_the_switch_refuses_is_not_recorded'

m=$(mutant j1b "$JOURNAL" \
    '                raise
            if not self.enabled:' \
    '                return None, False
            if not self.enabled:')
report 'M-J1b: a refused write is swallowed instead of raised, so the route answers 200 for it' "$m" \
       'test_a_write_the_switch_refuses_is_not_recorded'

m=$(mutant j2a "$JOURNAL" \
    '        with journal.lock:
            client = get_client()' \
    '        if True:
            client = get_client()')
report 'M-J2: no lock around the write and the record' "$m" \
       'test_two_writes_to_one_switch_never_interleave_with_each_others_record'

m=$(mutant j2b "$JOURNAL" \
    '            recorded = self._record(journal, written["op"], spec,
                                    key_digest(written["entry_key"]), "ok")
            return written, recorded' \
    '            journal.lock.release()
            try:
                recorded = self._record(journal, written["op"], spec,
                                        key_digest(written["entry_key"]), "ok")
            finally:
                journal.lock.acquire()
            return written, recorded')
report 'M-J2b: the lock covers the switch write but not the record, so two writes land in one order and are journaled in the other' "$m" \
       'test_two_writes_to_one_switch_never_interleave_with_each_others_record'

m=$(mutant j23 "$JOURNAL" \
    '        with journal.lock:
            client = get_client()' \
    '        client = get_client()
        with journal.lock:')
report 'M-J23: the client is looked up before the lock, so a readopt'\''s new client is missed' "$m" \
       'test_the_client_is_looked_up_inside_the_lock'

m=$(mutant j3 "$JOURNAL" \
    'key_digest(written["entry_key"]), "ok")' \
    'key_digest(spec), "ok")')
report 'M-J3: the journal key is the spelling of the request, not the entry'\''s identity' "$m" \
       'test_the_key_is_the_normalised_identity_not_the_way_the_request_spelled_it'

m=$(mutant j16 "$JOURNAL" \
    '            if client is None:
                raise SwitchGone(' \
    '            if False:
                raise SwitchGone(')
report 'M-J31: a switch that left the table is written through anyway (an AttributeError)' "$m" \
       'test_a_switch_that_is_gone_is_a_SwitchGone_and_nothing_is_recorded'

m=$(mutant j17 "$JOURNAL" \
    '            if not self.enabled:
                return written, False' \
    '            if False:
                return written, False')
report 'M-J32: a journal that is switched off records anyway' "$m" \
       'test_a_recording_that_is_switched_off_still_writes_and_records_nothing'

m=$(mutant j18a "$JOURNAL" \
    '                if (self.enabled and op == "delete" and refusal_is_not_found is not None
                        and refusal_is_not_found(exc)):' \
    '                if False:')
report 'M-J33: a delete the switch answered NOT_FOUND is not recorded' "$m" \
       'test_a_delete_the_switch_answered_NOT_FOUND_is_recorded_as_not_found_and_still_raised'

m=$(mutant j18b "$JOURNAL" \
    '                        and refusal_is_not_found(exc)):' \
    '                        and True):')
report 'M-J33b: any refused delete is recorded as not_found, whatever the switch said' "$m" \
       'test_no_other_refusal_is_recorded'

m=$(mutant j18c "$JOURNAL" \
    '                if (self.enabled and op == "delete" and refusal_is_not_found is not None' \
    '                if (self.enabled and refusal_is_not_found is not None')
report 'M-J33c: a modify the switch answered NOT_FOUND is recorded as well' "$m" \
       'test_no_other_refusal_is_recorded'

m=$(mutant j18d "$JOURNAL" \
    '                if (self.enabled and op == "delete" and refusal_is_not_found is not None' \
    '                if (True and op == "delete" and refusal_is_not_found is not None')
report 'M-J33d: a NOT_FOUND delete is recorded even with the journal off' "$m" \
       'test_a_journal_that_is_off_does_not_record_a_not_found_delete_either'

# --- record, and what it says when it cannot ---------------------------------------------------

m=$(mutant j12 "$JOURNAL" \
    '        except (OSError, TypeError, ValueError):
            return False

    def write_snapshot' \
    '        except (OSError, TypeError, ValueError):
            return True

    def write_snapshot')
report 'M-J12: a record that never reached the disk still answers True' "$m" \
       'test_record_never_raises_and_says_false_when_the_disk_will_not_take_it'

m=$(mutant j12b "$JOURNAL" \
    '        key = str(journal.dpid)
        if ok:' \
    '        key = str(journal.dpid)
        if True:')
report 'M-J12b: a failed record is counted as a success, so `failures` never moves' "$m" \
       'test_each_failure_is_counted_and_a_success_does_not_hide_it'

m=$(mutant j13a "$JOURNAL" \
    '        return (self.enabled and not self._read_only()
                and self._failures.get(key, 0) == 0)' \
    '        return (not self._read_only()
                and self._failures.get(key, 0) == 0)')
report 'M-J13a: a journal that is switched off still counts as complete' "$m" \
       'test_recording_off_is_not_complete'

m=$(mutant j13b "$JOURNAL" \
    '        return (self.enabled and not self._read_only()
                and self._failures.get(key, 0) == 0)' \
    '        return (self.enabled
                and self._failures.get(key, 0) == 0)')
report 'M-J13b: a switch on an external control plane still counts as complete' "$m" \
       'test_an_external_control_plane_is_not_complete'

m=$(mutant j13c "$JOURNAL" \
    '        return (self.enabled and not self._read_only()
                and self._failures.get(key, 0) == 0)' \
    '        return (self.enabled and not self._read_only())')
report 'M-J13c: a journal that lost a record still counts as complete' "$m" \
       'test_a_failed_record_is_not_complete'

m=$(mutant j20 "$JOURNAL" \
    '                if size == 0:' \
    '                if True:')
report 'M-J34: the header is written before every record, not once' "$m" \
       'test_the_header_is_written_once_not_per_record'

m=$(mutant j21 "$JOURNAL" \
    '                    if fh.read(1) != b"\n":' \
    '                    if False:')
report 'M-J35: a record appended after a torn last line is glued onto it and both are lost' "$m" \
       'test_a_torn_last_line_does_not_swallow_the_next_record'

m=$(mutant j22 "$JOURNAL" \
    '                    elif parsed.get("header"):' \
    '                    elif False:')
report 'M-J36: the header line is read as a record' "$m" \
       'test_read_gives_the_header_the_records_and_the_count_of_lines_it_could_not_read'

# --- the fold ----------------------------------------------------------------------------------

m=$(mutant j14 "$JOURNAL" \
    '    return net


def records_from_net' \
    '    return []


def records_from_net')
report 'M-J14: the fold returns nothing, so a snapshot would drop every entry' "$m" \
       'test_not_there_then_there_is_an_insert_of_the_last_spec'

m=$(mutant f1 "$JOURNAL" \
    '        before = f.get("op") != "insert"' \
    '        before = True')
report 'M-J37a: an entry the API created is folded as though it was already there, so it is modified, not inserted' "$m" \
       'test_not_there_then_there_is_an_insert_of_the_last_spec'

m=$(mutant f2 "$JOURNAL" \
    '        after = l.get("op") != "delete"' \
    '        after = True')
report 'M-J37b: a deleted entry is folded as still there, so a restart would resurrect it' "$m" \
       'test_there_then_gone_is_a_delete'

m=$(mutant f3 "$JOURNAL" \
    '        if spec.get("default_action"):' \
    '        if False:')
report 'M-J37c: a default entry is folded like any other, so an insert of one would be replayed as an insert' "$m" \
       'test_a_default_entry_is_never_an_insert'

m=$(mutant f4 "$JOURNAL" \
    '            if l.get("op") != "delete":' \
    '            if True:')
report 'M-J37d: a default whose last record is a delete is replayed as a modify' "$m" \
       'test_a_default_entry_whose_last_record_is_a_delete_nets_to_nothing'

m=$(mutant f5 "$JOURNAL" \
    '        last[key] = rec' \
    '        last.setdefault(key, rec)')
report 'M-J37e: the fold keeps the FIRST spec of an entry, so a later modify is lost' "$m" \
       'test_there_then_there_is_a_modify_of_the_last_spec'

m=$(mutant f6 "$JOURNAL" \
    '            order.append(key)' \
    '            order.insert(0, key)')
report 'M-J37f: entries come out in reverse order of first appearance' "$m" \
       'test_each_entry_folds_on_its_own_and_in_the_order_it_first_appeared'

m=$(mutant f7 "$JOURNAL" \
    '        if not isinstance(rec, dict) or rec.get("header") or "key" not in rec:' \
    '        if not isinstance(rec, dict) or rec.get("header"):')
report 'M-J37g: a line with no key is folded, so one torn record breaks the whole fold' "$m" \
       'test_the_header_and_a_line_that_is_not_a_record_are_not_folded'

m=$(mutant f8 "$JOURNAL" \
    '"op": item["op"], "key": item["key"], "spec": item["spec"],' \
    '"op": "insert", "key": item["key"], "spec": item["spec"],')
report 'M-J38: a snapshot writes every net entry as an insert, so the next fold reads a modify as new' "$m" \
       'test_a_folded_journal_folds_to_itself'

# --- the snapshot ------------------------------------------------------------------------------

m=$(mutant s1 "$JOURNAL" \
    '            os.replace(tmp, self.path)
            tmp = None' \
    '            with open(tmp, "rb") as src, open(self.path, "wb") as dst:
                dst.write(src.read())
            tmp = None')
report 'M-J11: the snapshot overwrites the live file in place, so a crash in it leaves a half-written journal' "$m" \
       'test_a_crash_before_the_replace_leaves_the_old_file_whole'

m=$(mutant s2 "$JOURNAL" \
    '                os.link(self.path, quarantined)' \
    '                os.rename(self.path, quarantined)')
report 'M-J11b: the old file is renamed away before the replace, so a crash between the two leaves no live journal' "$m" \
       'test_a_crash_before_the_replace_leaves_the_old_file_whole'

m=$(mutant s3 "$JOURNAL" \
    '                os.link(self.path, quarantined)' \
    '                pass')
report 'M-J39: the old generation is not kept anywhere' "$m" \
       'test_the_old_file_is_kept_byte_for_byte_under_another_name'

m=$(mutant s4 "$JOURNAL" \
    '        for name in names[:max(0, len(names) - keep)]:' \
    '        for name in []:')
report 'M-J40a: set-aside generations are never pruned' "$m" \
       'test_only_the_most_recent_generations_are_kept'

m=$(mutant s5 "$JOURNAL" \
    '        for name in names[:max(0, len(names) - keep)]:' \
    '        for name in names[keep:]:')
report 'M-J40b: the pruning keeps the OLDEST generations' "$m" \
       'test_only_the_most_recent_generations_are_kept'

m=$(mutant s6 "$JOURNAL" \
    '            if tmp is not None:
                try:' \
    '            if False:
                try:')
report 'M-J41: a failed snapshot leaves its temp file behind' "$m" \
       'test_a_crash_before_the_replace_leaves_the_old_file_whole'

m=$(mutant s7 "$JOURNAL" \
    '                head.update({"v": 1, "header": True, "dpid": self.dpid})' \
    '                head.update({"v": 1, "dpid": self.dpid})')
report 'M-J42: the snapshot'\''s first line is not marked as a header' "$m" \
       'test_the_new_file_is_the_header_and_the_given_records'

# --- what is claimed: recorded, never journaled, until something replays -----------------------

m=$(mutant c1 "$JOURNAL" \
    '
TABLE_JOURNAL_REPLAYS = False
' \
    '
TABLE_JOURNAL_REPLAYS = True
')
report 'M-J30: the replay constant is flipped with no replay behind it, so every `journaled` turns true' "$m" \
       'test_the_constant_is_false_in_this_cut'

m=$(mutant c2 "$JOURNAL" \
    '    return bool(recorded) and TABLE_JOURNAL_REPLAYS' \
    '    return bool(recorded)')
report 'M-J30a: a recorded write claims to be journaled whether or not anything replays it' "$m" \
       'test_with_replay_a_recorded_write_is_journaled_and_without_it_is_not'

m=$(mutant c3 "$JOURNAL" \
    '    return bool(recorded) and TABLE_JOURNAL_REPLAYS' \
    '    return TABLE_JOURNAL_REPLAYS')
report 'M-J30b: a write that was NOT recorded claims to be journaled once something replays' "$m" \
       'test_a_write_that_was_not_recorded_is_never_journaled_whatever_replays'

m=$(mutant c4 "$JOURNAL" \
    '        return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS' \
    '        return self.record_complete(dpid)')
report 'M-J30c: switch_state claims the switch is journaled because its records are complete' "$m" \
       'test_a_recorded_write_shows_under_journal_and_journaled_stays_false'

m=$(mutant c5 "$JOURNAL" \
    '"replay": REPLAY_NOT_IMPLEMENTED if not TABLE_JOURNAL_REPLAYS else "implemented"}' \
    '"replay": "implemented"}')
report 'M-J30d: switch_state'\''s journal block says replay is implemented' "$m" \
       'test_a_recorded_write_shows_under_journal_and_journaled_stays_false'

m=$(mutant c6 "$JOURNAL" \
    '    return str(env.get(TABLE_JOURNAL_ENV_VAR, "")).strip().lower() not in ("off", "0", "false", "no")' \
    '    return str(env.get(TABLE_JOURNAL_ENV_VAR, "")).strip().lower() not in ("off",)')
report 'M-J43: only the word `off` turns recording off, so `0` and `false` leave it on' "$m" \
       'test_only_off_switches_it_off'

m=$(mutant c7 "$JOURNAL" \
    '.hexdigest()[:32]' \
    '.hexdigest()[:8]')
report 'M-J44: the key digest is eight characters' "$m" \
       'test_the_digest_is_a_short_hex_string'

m=$(mutant c8 "$ROUTES" \
    '            "journaled": journaled, "journal": journal}' \
    '            "journaled": True, "journal": journal}')
report 'M-B20b: the response claims the entry is journaled, next to a journal block that says nothing replays it' "$m" \
       'test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal'

m=$(mutant c9 "$ROUTES" \
    '    journaled = rule_journal.journaled_claim(recorded)' \
    '    journaled = bool(recorded)')
report 'M-J30e: the response'\''s `journaled` ignores whether anything replays' "$m" \
       'test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal'

m=$(mutant c10 "$MAIN" \
    '                     "journaled": table_journals.journaled(dpid),' \
    '                     "journaled": True,')
report 'M-B14b: switch_state claims these entries survive a proxy restart' "$m" \
       'test_a_recorded_write_shows_under_journal_and_journaled_stays_false'

# --- what the route says -----------------------------------------------------------------------

m=$(mutant r1 "$ROUTES" \
    '    if note is not None:
        body["note"] = note' \
    '    if False:
        body["note"] = note')
report 'M-J45: a response that is not journaled carries no note saying what that costs' "$m" \
       'test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal'

m=$(mutant r2 "$ROUTES" \
    '        if table_journals is None:
            written = await run_in_threadpool(client.write_table_entry, spec, op)' \
    '        if True:
            written = await run_in_threadpool(client.write_table_entry, spec, op)')
report 'M-J46: the route never goes through the journal' "$m" \
       'test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal'

m=$(mutant r3 "$ROUTES" \
    '    if recorded:
        return journaled, journal, TABLE_ENTRY_RECORDED_NOT_REPLAYED' \
    '    if True:
        return journaled, journal, TABLE_ENTRY_RECORDED_NOT_REPLAYED')
report 'M-J47: a write the journal could not take says it was recorded' "$m" \
       'test_a_journal_that_cannot_be_written_is_still_a_200_that_says_so'

m=$(mutant r4 "$ROUTES" \
    '    if not enabled:
        return journaled, journal, TABLE_ENTRY_NOT_JOURNALED' \
    '    if False:
        return journaled, journal, TABLE_ENTRY_NOT_JOURNALED')
report 'M-J48: a journal that is off is reported as a failed write' "$m" \
       'test_a_journal_that_is_switched_off_says_so_and_is_not_called_a_failure'

m=$(mutant r5 "$ROUTES" \
    '    enabled = table_journals is not None and table_journals.enabled' \
    '    enabled = True')
report 'M-J49: a proxy with no journal at all says its journal is enabled' "$m" \
       'test_a_proxy_with_no_journal_at_all_still_writes_and_says_the_journal_is_off'

m=$(mutant r6 "$ROUTES" \
    '    return p4rt is not None and p4rt.get("code") == "NOT_FOUND"' \
    '    return p4rt is not None')
report 'M-J50: any per-update refusal of a delete is treated as NOT_FOUND' "$m" \
       'test_a_delete_refused_for_another_reason_is_not_recorded'

m=$(mutant r7 "$ROUTES" \
    'lambda: topology.switches.get(raw_dpid), raw_dpid, spec, op, _is_not_found)' \
    'lambda: topology.switches.get(raw_dpid), raw_dpid, spec, op, None)')
report 'M-J51: the route does not tell the journal how to recognise NOT_FOUND' "$m" \
       'test_a_delete_that_the_switch_answers_NOT_FOUND_is_a_502_with_a_not_found_record'

m=$(mutant r8 "$ROUTES" \
    '    except SwitchGone:' \
    '    except KeyboardInterrupt:')
report 'M-J52: a switch that left between the check and the lock is a 500' "$m" \
       'test_a_switch_that_left_between_the_check_and_the_lock_is_a_404'

m=$(mutant r9 "$ROUTES" \
    '                            "journaled": False,
                            "journal": (table_journals.report(dpid)' \
    '                            "journaled": False,
                            "journal_gone": (table_journals.report(dpid)')
report 'M-J53: switch_state'\''s entry for a switch nobody reported on has no journal block' "$m" \
       'test_every_switch_reports_what_was_written_and_that_none_of_it_is_journaled'

# --- what main builds and reports --------------------------------------------------------------

m=$(mutant m1 "$MAIN" \
    'api_routes.inject_table_journals(table_journals)' \
    'pass')
report 'M-J54: main builds the journals and never hands them to the route (finding #71'\''s shape)' "$m" \
       'test_main_handed_the_route_the_journals_it_built'

m=$(mutant m2 "$MAIN" \
    '                     "journal": table_journals.report(dpid)}' \
    '                     "journal_gone": table_journals.report(dpid)}')
report 'M-J55: the table-entries report carries no journal block' "$m" \
       'test_the_report_in_main_carries_the_same_two_fields'

m=$(mutant m3 "$MAIN" \
    ' | table_journals.known_dpids(),' \
    ',')
report 'M-J56: a switch that was only ever written through the API has no entry in the report' "$m" \
       'test_the_report_in_main_carries_the_same_two_fields'

m=$(mutant m4 "$MAIN" \
    '    directory = (str(env.get(TABLE_JOURNAL_DIR_ENV_VAR, "")).strip()
                 or os.path.join(proxy_root(), DEFAULT_TABLE_JOURNAL_RELPATH))' \
    '    directory = os.path.join(proxy_root(), DEFAULT_TABLE_JOURNAL_RELPATH)')
report 'M-J57: the directory override is ignored' "$m" \
       'test_the_directory_can_be_overridden_and_recording_can_be_switched_off'

m=$(mutant m5 "$MAIN" \
    '    return TableJournals(directory, enabled=table_journal_enabled(env),' \
    '    return TableJournals(directory, enabled=True,')
report 'M-J58: the off switch is ignored' "$m" \
       'test_the_directory_can_be_overridden_and_recording_can_be_switched_off'

m=$(mutant m6 "$MAIN" \
    '                         read_only=lambda: profile.current().read_only,' \
    '                         read_only=lambda: False,')
report 'M-J59: an external control plane'\''s fabric is reported as one whose journal is complete' "$m" \
       'test_the_journals_main_builds_ask_the_package_whether_the_fabric_is_external'

m=$(mutant m7 "$MAIN" \
    '    out = {"boot_id": boot_identity.BOOT_ID}' \
    '    out = {"boot_id": None}')
report 'M-J60: the header does not say which boot wrote it' "$m" \
       'test_the_header_main_supplies_names_this_boot'

m=$(mutant m8 "$MAIN" \
    '        out["p4info_sha256"] = _p4info_fingerprint(p4info_path)' \
    '        out["p4info_sha256"] = None')
report 'M-J61: the header does not say which p4info it was made against' "$m" \
       'test_the_header_digests_are_those_of_the_files_the_package_names'

m=$(mutant m9 "$MAIN" \
    '        out["entries_sha256"] = _p4info_fingerprint(entries) if entries else None' \
    '        out["entries_sha256"] = None')
report 'M-J62: the header does not say which entries file it was made against' "$m" \
       'test_the_header_digests_are_those_of_the_files_the_package_names'

m=$(mutant m10 "$MAIN" \
    'DEFAULT_TABLE_JOURNAL_RELPATH = os.path.join(".run", "table_entry_journal")' \
    'DEFAULT_TABLE_JOURNAL_RELPATH = os.path.join("table_entry_journal")')
report 'M-J63: the journals are written beside the sources instead of under .run/' "$m" \
       'test_the_default_directory_is_absolute_inside_this_checkout_and_stable'

# --- the identity of an entry, in the writer and the install-time record -----------------------

m=$(mutant w1 "$CLIENT" \
    '            self.rule_install_times.record(self.device_id, table_name, entry.priority,
                                           recorded_match, entry.is_default_action)' \
    '            self.rule_install_times.record(self.device_id, table_name, entry.priority,
                                           recorded_match, False)')
report 'M-J64: a default entry is stamped under the key of a catch-all' "$m" \
       'test_deleting_a_catch_all_does_not_forget_the_defaults_install_time'

m=$(mutant w2 "$CLIENT" \
    '            self.rule_install_times.forget(self.device_id, table_name, entry.priority,
                                           recorded_match, entry.is_default_action)' \
    '            self.rule_install_times.forget(self.device_id, table_name, entry.priority,
                                           recorded_match, False)')
report 'M-J65: deleting a default forgets a catch-all'\''s install time' "$m" \
       'test_deleting_the_default_does_not_forget_a_catch_alls_install_time'

m=$(mutant w3 "$CLIENT" \
    '            "entry_key": entry_key(' \
    '            "entry_key": (lambda *a: None)(')
report 'M-J66: the writer reports no identity, so every journal record has the same key' "$m" \
       'test_two_different_entries_have_two_keys'

m=$(mutant w4 "$CLIENT" \
    '        except Exception:  # noqa: BLE001 -- a spec that does not build has no identity' \
    '        except KeyboardInterrupt:  # noqa: BLE001 -- a spec that does not build has no identity')
report 'M-J67: a delete the switch refused, whose spec does not build, raises out of the journal' "$m" \
       'test_a_spec_that_does_not_build_has_no_key_and_raises_nothing'

m=$(mutant w5 "$CLIENT" \
    '            self.device_id, table_name, entry.priority, self._built_entry_match(entry),
            entry.is_default_action)' \
    '            self.device_id, table_name, entry.priority, self._built_entry_match(entry),
            False)')
report 'M-J68: a default entry'\''s spec has the key of a catch-all when asked for without writing' "$m" \
       'test_and_so_does_a_default_entry_spec'

m=$(mutant k1 "$INSTALL" \
    '    if default:
        return (str(dpid), str(table), "default")' \
    '    if False:
        return (str(dpid), str(table), "default")')
report 'M-J69: the default entry has no key of its own' "$m" \
       'test_the_default_and_a_catch_all_are_two_keys'

m=$(mutant k2 "$INSTALL" \
    '        key = entry_key(dpid, table, priority, match, default)
        with self._lock:
            if key not in self._at:' \
    '        key = entry_key(dpid, table, priority, match)
        with self._lock:
            if key not in self._at:')
report 'M-J70: the install-time record ignores that an entry is a default' "$m" \
       'test_deleting_a_catch_all_does_not_forget_the_defaults_install_time'

m=$(mutant k3 "$INSTALL" \
    '        key = entry_key(dpid, table, priority, match, default)
        with self._lock:
            return self._at.pop(key, None) is not None' \
    '        key = entry_key(dpid, table, priority, match)
        with self._lock:
            return self._at.pop(key, None) is not None')
report 'M-J71: forgetting ignores that an entry is a default' "$m" \
       'test_deleting_the_default_does_not_forget_a_catch_alls_install_time'

m=$(mutant k4 "$INSTALL" \
    '        key = entry_key(dpid, table, priority, match, default)
        with self._lock:
            installed_at = self._at.get(key)' \
    '        key = entry_key(dpid, table, priority, match)
        with self._lock:
            installed_at = self._at.get(key)')
report 'M-J72: an age lookup ignores that an entry is a default' "$m" \
       'test_deleting_a_catch_all_does_not_forget_the_defaults_install_time'

# --- negative controls ------------------------------------------------------------
#
# Edits that change no behaviour these suites specify; each must leave the suite GREEN.

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-72s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-72s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
}

m=$(mutant n1 "$JOURNAL" \
    '    now = time.time() if now is None else now
    return [{"v": 1,' \
    '    # MUTANT: a comment, and nothing else.
    now = time.time() if now is None else now
    return [{"v": 1,')
control 'N1 (control): a comment-only edit in records_from_net' "$m" "the whole suite stays green"

m=$(mutant n2 "$JOURNAL" \
    '    return bool(recorded) and TABLE_JOURNAL_REPLAYS' \
    '    return TABLE_JOURNAL_REPLAYS and bool(recorded)')
control 'N2 (control): the same claim with its operands the other way round' "$m" "the whole suite stays green"

m=$(mutant n3 "$ROUTES" \
    '    journaled = rule_journal.journaled_claim(recorded)' \
    '    # MUTANT: a comment, and nothing else.
    journaled = rule_journal.journaled_claim(recorded)')
control 'N3 (control): a comment-only edit in the response view' "$m" "the whole suite stays green"

m=$(mutant n4 "$MAIN" \
    '    out = {"boot_id": boot_identity.BOOT_ID}' \
    '    # MUTANT: a comment, and nothing else.
    out = {"boot_id": boot_identity.BOOT_ID}')
control 'N4 (control): a comment-only edit in the header builder' "$m" "the whole suite stays green"

m=$(mutant n5 "$CLIENT" \
    '        table_name = self._table_name(entry.table_id)
        return entry_key(' \
    '        # MUTANT: a comment, and nothing else.
        table_name = self._table_name(entry.table_id)
        return entry_key(')
control 'N5 (control): a comment-only edit in table_entry_key' "$m" "the whole suite stays green"

m=$(mutant n6 "$INSTALL" \
    '    if default:
        return (str(dpid), str(table), "default")' \
    '    # MUTANT: a comment, and nothing else.
    if default:
        return (str(dpid), str(table), "default")')
control 'N6 (control): a comment-only edit beside the default key' "$m" "the whole suite stays green"

echo
[[ "$(sha256sum "$JOURNAL" | cut -d' ' -f1)" == "$BASE_JOURNAL" ]] || { echo "🔴 baseline CHANGED -- rule_journal.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$INSTALL" | cut -d' ' -f1)" == "$BASE_INSTALL" ]] || { echo "🔴 baseline CHANGED -- rule_install_times.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_JOURNAL" | cut -d' ' -f1)" == "$BASE_TEST_JOURNAL" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_journal.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_ROUTE" | cut -d' ' -f1)" == "$BASE_TEST_ROUTE" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_route.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_INSTALL" | cut -d' ' -f1)" == "$BASE_TEST_INSTALL" ]] || { echo "🔴 baseline CHANGED -- test_rule_install_times.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)" == "$BASE_TEST_PROXY" ]] || { echo "🔴 baseline CHANGED -- test_app_package_proxy.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (5 sources, 5 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
