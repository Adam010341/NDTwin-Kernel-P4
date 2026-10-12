#!/usr/bin/env bash
#
# Mutation gate for the table-entry journal: `rule_journal.TableEntryJournal` / `TableJournals` /
# `fold_records`, what `POST /p4/table_entry` and `switch_state` say about it, the identity a
# default entry gets, and the replay: the pipeline cookie, step 0, startup's and readopt's callers,
# pending/503. DESIGN.md sections 5 and 6.3 (Cut B: M-J1-M-J3, M-J12-M-J14; Cut C: M-J4-M-J6,
# M-J10, M-J15-M-J20, M-J22, M-J25-M-J28).
#
# [Co-developed with claude code -- Adam]
#
# 🔴 `journaled` IS A CLAIM THAT AN ENTRY SURVIVES A RESTART, and since Cut C it is true for a
# recorded write: startup and readopt replay the journal (tests/test_table_entry_replay.py runs
# the real startup and readopt against a stub that behaves like the bmv2 ternary-a0 measured).
# M-J30 sets the constant back to False; M-J30b claims it for a write that was not recorded;
# M-B14b and M-B20b claim it where a record was lost. Cut B's M-J30a and M-J30e are gone: with the
# constant True each was the code it mutated, not a mutation of it. M-J30c stays, rewritten (the
# switch's claim ignoring its records).
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
TEST_REPLAY="$REPO/p4_proxy/tests/test_table_entry_replay.py"

MODULES="tests.test_table_entry_journal tests.test_table_entry_route tests.test_p4_client_writes \
tests.test_rule_install_times tests.test_app_package_proxy tests.test_table_entry_replay"

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
BASE_TEST_REPLAY=$(sha256sum "$TEST_REPLAY" | cut -d' ' -f1)

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
mutant2() {  # $1 = label, $2 = file, $3/$4 = first anchor and its replacement, $5/$6 = second
    local d
    d=$(mutant "$1" "$2" "$3" "$4") || return 1
    python3 - "$d/${2#"$REPO/p4_proxy/"}" "$5" "$6" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "second anchor not unique (%d hits): %s" % (s.count(a), a[:70])
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
report 'M-J1b: a refused write is swallowed instead of raised (the route would then fail with a 500 on the empty result)' "$m" \
       'test_a_write_the_switch_refuses_is_not_recorded'

m=$(mutant j2a "$JOURNAL" \
    '        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)
            client = get_client()' \
    '        if True:
            self._refuse_pending(dpid)
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
    '        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)
            client = get_client()' \
    '        client = get_client()
        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)')
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
    '        elif ok:
            self._recorded[key]' \
    '        elif True:
            self._recorded[key]')
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
    '        before = f.get("op") != "insert" and not (unknown and after)' \
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
    '        out.append({"v": 1, "t": now, "op": item["op"], "key": item["key"],' \
    '        out.append({"v": 1, "t": now, "op": "insert", "key": item["key"],')
report 'M-J38: a snapshot writes every net entry as an insert, so the next fold reads a modify as new' "$m" \
       'test_a_folded_journal_folds_to_itself'

# --- the snapshot ------------------------------------------------------------------------------

m=$(mutant s1 "$JOURNAL" \
    '            os.replace(tmp, self.path)
            tmp = None' \
    '            with open(tmp, "rb") as src, open(self.path, "wb") as dst:
                dst.write(src.read())
            tmp = None')
report 'M-J11: the snapshot copies over the live file in place, so the os.replace fault hook never fires and the old content is gone' "$m" \
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
    '        header = {"v": 1, "header": True, "dpid": self.dpid, "fabric_cookie": None,' \
    '        header = {"v": 1, "dpid": self.dpid, "fabric_cookie": None,')
report 'M-J42: the snapshot'\''s first line is not marked as a header' "$m" \
       'test_the_new_file_is_the_header_and_the_given_records'

# --- what is claimed: recorded, never journaled, until something replays -----------------------

m=$(mutant c1 "$JOURNAL" \
    '
TABLE_JOURNAL_REPLAYS = True
' \
    '
TABLE_JOURNAL_REPLAYS = False
')
report 'M-J30: the replay constant is False, so nothing claims the entries the replay restores' "$m" \
       'test_the_constant_is_true_now_that_startup_and_readopt_replay'

m=$(mutant c3 "$JOURNAL" \
    '    return bool(recorded) and TABLE_JOURNAL_REPLAYS' \
    '    return TABLE_JOURNAL_REPLAYS')
report 'M-J30b: a write that was NOT recorded claims to be journaled once something replays' "$m" \
       'test_a_write_that_was_not_recorded_is_never_journaled_whatever_replays'

m=$(mutant c4 "$JOURNAL" \
    '        return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS' \
    '        return TABLE_JOURNAL_REPLAYS')
report 'M-J30c: switch_state claims a switch is journaled whatever its records say' "$m" \
       'test_a_failed_record_shows_on_the_switch_that_had_it'

m=$(mutant c5 "$JOURNAL" \
    '"replay": (dict(self._replays[key]) if key in self._replays else None)}' \
    '"replay": None}')
report 'M-J30d: switch_state'\''s journal block never says what the replay put back' "$m" \
       'test_switch_state_names_what_came_back'

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
report 'M-B20b: the response claims an entry the journal could not take is journaled (was M-B20 in mutate_table_entry.sh)' "$m" \
       'test_a_journal_that_cannot_be_written_is_still_a_200_that_says_so'

m=$(mutant c10 "$MAIN" \
    '                     "journaled": table_journals.journaled(dpid),' \
    '                     "journaled": True,')
report 'M-B14b: switch_state claims a switch whose journal lost a record is journaled (was M-B14 in mutate_table_entry.sh)' "$m" \
       'test_a_failed_record_shows_on_the_switch_that_had_it'

# --- what the route says -----------------------------------------------------------------------

m=$(mutant r1 "$ROUTES" \
    '    if note is not None:
        body["note"] = note' \
    '    if False:
        body["note"] = note')
report 'M-J45: a response that is not journaled carries no note saying what that costs' "$m" \
       'test_a_journal_that_cannot_be_written_is_still_a_200_that_says_so'

m=$(mutant r2 "$ROUTES" \
    '        if table_journals is None:
            written = await run_in_threadpool(client.write_table_entry, spec, op)' \
    '        if True:
            written = await run_in_threadpool(client.write_table_entry, spec, op)')
report 'M-J46: the route never goes through the journal' "$m" \
       'test_an_accepted_write_is_recorded_and_the_response_says_so_under_journal'

m=$(mutant r3 "$ROUTES" \
    '    journal = {"recorded": bool(recorded), "enabled": enabled,' \
    '    journal = {"recorded": True, "enabled": enabled,')
report 'M-J47: a write the journal could not take says it was recorded' "$m" \
       'test_a_journal_that_cannot_be_written_is_still_a_200_that_says_so'

m=$(mutant r4 "$ROUTES" \
    '    if not enabled:
        # Off, or none injected at all' \
    '    if False:
        # Off, or none injected at all')
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
    'lambda: topology.switches.get(raw_dpid), raw_dpid, spec, op, _is_not_found,' \
    'lambda: topology.switches.get(raw_dpid), raw_dpid, spec, op, None,')
report 'M-J51: the route does not tell the journal how to recognise NOT_FOUND' "$m" \
       'test_a_delete_that_the_switch_answers_NOT_FOUND_is_a_502_with_a_not_found_record'

m=$(mutant r8 "$ROUTES" \
    '    except SwitchGone:' \
    '    except KeyboardInterrupt:')
report 'M-J52: a switch that left between the check and the lock is a 500' "$m" \
       'test_a_switch_that_left_between_the_check_and_the_lock_is_a_404'

m=$(mutant r9 "$ROUTES" \
    '                                          if table_journals is not None else False),
                            "journal": (table_journals.report(dpid)' \
    '                                          if table_journals is not None else False),
                            "journal_gone": (table_journals.report(dpid)')
report 'M-J53: switch_state'\''s entry for a switch nobody reported on has no journal block' "$m" \
       'test_every_switch_reports_what_was_written_and_whether_it_is_journaled'

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
report 'M-J56: a switch known only to the journals has no entry in the report (a guard of the union; an accepted write is also in api_writes)' "$m" \
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
    '    out = {"boot_id": boot_identity.BOOT_ID,' \
    '    out = {"boot_id": None,')
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

# --- tests that guard the plain case, so that a break in it is seen ----------------------------

m=$(mutant x1 "$INSTALL" \
    '    return (str(dpid), str(table), int(priority or 0), normalise_match(match))' \
    '    return (dpid, str(table), int(priority or 0), normalise_match(match))')
report 'M-J73: a non-default entry'\''s key is spelled differently from what it always was' "$m" \
       'test_a_non_default_entry_keeps_the_key_it_always_had'

m=$(mutant x2 "$INSTALL" \
    '        return (str(dpid), str(table), "default")' \
    '        return (str(dpid), "default")')
report 'M-J74: every table'\''s default entry has the same key' "$m" \
       'test_the_default_of_one_table_is_not_the_default_of_another'

m=$(mutant x3 "$JOURNAL" \
    '            except Exception:  # noqa: BLE001 -- a header that cannot be built must not lose the record' \
    '            except KeyboardInterrupt:  # noqa: BLE001 -- a header that cannot be built must not lose the record')
report 'M-J75: a header that cannot be built loses the record that triggered it' "$m" \
       'test_a_header_that_cannot_be_built_does_not_lose_the_record'

m=$(mutant x4 "$JOURNAL" \
    '        except FileNotFoundError:
            pass
        except OSError:
            unreadable += 1
        self._unreadable = unreadable
        return header, records, unreadable' \
    '        except FileNotFoundError:
            unreadable += 1
        except OSError:
            unreadable += 1
        self._unreadable = unreadable
        return header, records, unreadable')
report 'M-J76: a switch with no journal file yet is reported as having an unreadable one' "$m" \
       'test_a_missing_file_reads_as_empty_and_not_as_an_error'

m=$(mutant x5 "$JOURNAL" \
    '        last[key] = rec' \
    '        rec["seen"] = True
        last[key] = rec')
report 'M-J77: the fold writes into the records it was given' "$m" \
       'test_folding_does_not_change_its_input'

m=$(mutant x6 "$JOURNAL" \
    'os.path.join(self.directory, f"s{key}.jsonl")' \
    'os.path.join(self.directory, f"{key}.jsonl")')
report 'M-J78: a switch'\''s file is named by its number alone' "$m" \
       'test_a_file_is_named_for_its_switch'

m=$(mutant x7 "$ROUTES" \
    'TABLE_ENTRY_JOURNAL_WRITE_FAILED = (' \
    'TABLE_ENTRY_JOURNAL_WRITE_FAILED = TABLE_ENTRY_NOT_JOURNALED
_UNUSED = (')
report 'M-J79: a table entry the journal could not take carries the multicast group'\''s sentence' "$m" \
       'test_the_constants_the_two_surfaces_disagree_on_are_split'

m=$(mutant x8 "$MAIN" \
    '                     "journal": table_journals.report(dpid)}' \
    '                     "journal": dict(table_journals.report(dpid), replay="implemented")}')
report 'M-J80: the real report says a replay happened before any has run' "$m" \
       'test_the_real_report_has_no_replay_before_one_has_run'

m=$(mutant x9 "$JOURNAL" \
    'hashlib.sha256(repr(key).encode("utf-8"))' \
    'hashlib.sha256(b"one key for every entry")')
report 'M-J81: every entry has the same digest' "$m" \
       'test_equal_keys_have_equal_digests_and_different_keys_do_not'

m=$(mutant x10 "$JOURNAL" \
    '            if os.path.exists(self.path):
                quarantined' \
    '            if True:
                quarantined')
report 'M-J82: a first snapshot tries to set aside a file that is not there' "$m" \
       'test_a_first_snapshot_with_no_live_file_quarantines_nothing'

m=$(mutant x11 "$JOURNAL" \
    '                and self._failures.get(key, 0) == 0)' \
    '                and self._failures.get(key, 0) == 1)')
report 'M-J83: a journal with no failures is not complete' "$m" \
       'test_all_three_true_is_complete'

# --- review fixes: the fallback's claim, the op's spelling, the header's wiring, what recorded counts, the lock's bound ----

m=$(mutant y1 "$ROUTES" \
    '"journaled": (table_journals.journaled(dpid)
                                          if table_journals is not None else False),' \
    '"journaled": False,')
report 'M-J84: switch_state'\''s fallback says journaled false whatever the replay constant is' "$m" \
       'test_a_switch_the_report_does_not_list_gets_its_journaled_through_the_constant'

m=$(mutant y1b "$ROUTES" \
    '"journaled": (table_journals.journaled(dpid)
                                          if table_journals is not None else False),' \
    '"journaled": (table_journals.journaled(dpid)
                                          if True else False),')
report 'M-J84b: the fallback asks journals that do not exist' "$m" \
       'test_the_fallback_still_says_false_when_there_are_no_journals_at_all'

m=$(mutant y2 "$ROUTES" \
    '    op = str(data.get("op", "insert") or "insert").strip().lower()' \
    '    op = data.get("op", "insert")')
report 'M-J85: the route passes the op as the caller spelled it, so an upper-case DELETE answered NOT_FOUND is not recorded' "$m" \
       'test_an_upper_case_delete_the_switch_answers_NOT_FOUND_is_recorded_too'

m=$(mutant y3 "$MAIN" \
    '                         header_for=table_journal_header)' \
    '                         header_for=None)')
report 'M-J86: main does not hand the journals a header provider, so every header is all null' "$m" \
       'test_the_headers_main_builds_are_written_with_this_boot_and_the_p4info_digest'

m=$(mutant y3b "$JOURNAL" \
    '                if self._header_for is not None:' \
    '                if False:')
report 'M-J87: TableJournals drops the header provider before the journal gets it' "$m" \
       'test_the_headers_main_builds_are_written_with_this_boot_and_the_p4info_digest'

m=$(mutant y4 "$JOURNAL" \
    '        if ok and outcome == "not_found":' \
    '        if False:')
report 'M-J88: a not_found record is counted as an accepted write, so `recorded` disagrees with `api_writes`' "$m" \
       'test_a_delete_the_switch_answered_NOT_FOUND_is_recorded_as_not_found_and_still_raised'

m=$(mutant y4b "$JOURNAL" \
    '            self._not_found[key] = self._not_found.get(key, 0) + 1' \
    '            pass')
report 'M-J88b: a not_found record is not counted anywhere' "$m" \
       'test_an_accepted_write_and_a_not_found_delete_are_counted_apart'

m=$(mutant y5 "$JOURNAL" \
    '    if not lock.acquire(timeout=-1 if timeout is None else timeout):' \
    '    if not lock.acquire():')
report 'M-J89: the lock wait has no timeout, so a write behind a hung switch waits for ever' "$m" \
       'test_a_write_behind_a_write_that_does_not_return_is_SwitchBusy_and_writes_nothing'

m=$(mutant y5b "$ROUTES" \
    '                TABLE_ENTRY_LOCK_TIMEOUT_S)
    except ReplayPending as err:' \
    '                None)
    except ReplayPending as err:')
report 'M-J89b: the route does not pass the timeout, so every POST waits for ever for a busy switch' "$m" \
       'test_the_second_post_to_a_switch_that_does_not_answer_is_503_and_writes_nothing'

m=$(mutant y5c "$ROUTES" \
    'TABLE_ENTRY_LOCK_TIMEOUT_S = RPC_TIMEOUT_S' \
    'TABLE_ENTRY_LOCK_TIMEOUT_S = 0.0')
report 'M-J89c: the wait is not one gRPC deadline' "$m" \
       'test_the_wait_is_bounded_by_one_grpc_deadline'

m=$(mutant y5d "$ROUTES" \
    '    except SwitchBusy as err:' \
    '    except KeyboardInterrupt as err:')
report 'M-J89d: a busy switch is a 500, not a 503' "$m" \
       'test_the_second_post_to_a_switch_that_does_not_answer_is_503_and_writes_nothing'

m=$(mutant y5f "$JOURNAL" \
    '    if not lock.acquire(timeout=-1 if timeout is None else timeout):' \
    '    if timeout is not None or not lock.acquire():')
report 'M-J89f: a write that names a timeout is refused even when the lock is free' "$m" \
       'test_a_write_that_is_not_blocked_ignores_the_timeout'

m=$(mutant y5e "$JOURNAL" \
    '        raise SwitchBusy(f"{what} is busy: another write to it held the lock for {timeout}s")' \
    '        pass')
report 'M-J89e: a lock that timed out is used anyway, so the write goes out unprotected' "$m" \
       'test_a_write_behind_a_write_that_does_not_return_is_SwitchBusy_and_writes_nothing'

# --- the owner check runs inside the write the journal wraps (DESIGN 5.7) --------------------
# [Co-developed with claude code -- Adam] Not a journal line: the owner check's own gate is
# mutate_table_entry_owner.sh. Here it says that the journal sees nothing of a write into a table
# NDTwin owns only because that refusal comes first -- without it the delete is answered
# NOT_FOUND by the switch and recorded as `not_found`.

m=$(mutant v7 "$CLIENT" \
    '        self._refuse_owned_table(spec, op, source)' \
    '        pass  # MUTANT: no owner check')
report 'M-J90: the owner check is skipped, so a write into a table NDTwin owns reaches the switch and the journal' "$m" \
       'test_a_write_into_a_table_ndtwin_owns_is_a_409_and_leaves_no_record'

# =============================================================================================
# Cut C: the replay. [Co-developed with claude code -- Adam]
# Killers are in tests/test_table_entry_replay.py (the real startup and readopt against a bmv2-like
# stub) unless they name a test of test_table_entry_journal.py.
# =============================================================================================

# --- M1 as amended (2026-10-12): a first delete answered NOT_FOUND leaves "before" unknown --------

m=$(mutant m1a "$JOURNAL" \
    '        before = f.get("op") != "insert" and not (unknown and after)' \
    '        before = f.get("op") != "insert"')
report 'M-J91: a key that began with a NOT_FOUND delete folds as present, so its insert is replayed as a modify' "$m" \
       'test_a_not_found_delete_then_an_insert_is_an_insert'

m=$(mutant m1e "$JOURNAL" \
    '        before = f.get("op") != "insert" and not (unknown and after)' \
    '        before = f.get("op") != "insert" and not unknown')
report 'M-J91e (half 1): a first NOT_FOUND delete is "absent" again, so a lone one folds to nothing and a boot entry deleted with a lost answer comes back' "$m" \
       'test_a_lone_not_found_delete_is_a_net_delete'

m=$(mutant m1f "$JOURNAL" \
    '                    if not (item.get("unknown_before") and is_already_exists is not None
                            and is_already_exists(exc)):
                        raise' \
    '                    raise')
report 'M-J91f (half 2): an unknown-start insert that meets the boot entry is not retried as a modify, so the user'\''s spec is lost' "$m" \
       'test_a_boot_entry_deleted_with_a_lost_answer_then_inserted_ends_as_the_insert'

m=$(mutant m1g "$JOURNAL" \
    '                    if not (item.get("unknown_before") and is_already_exists is not None
                            and is_already_exists(exc)):' \
    '                    if not (is_already_exists is not None
                            and is_already_exists(exc)):')
report 'M-J91g: every insert that meets ALREADY_EXISTS is retried as a modify, not only an unknown-start one' "$m" \
       'test_an_ordinary_insert_that_meets_an_entry_is_not_retried_as_a_modify'

m=$(mutant m1h "$JOURNAL" \
    '        if item.get("unknown_before"):
            out.append(' \
    '        if False:
            out.append(')
report 'M-J91h: a snapshot forgets an insert began unknown, so the next boot'\''s replay meets the boot entry and fails' "$m" \
       'test_a_snapshot_of_a_fold_with_not_found_deletes_folds_to_the_same'

m=$(mutant m1i "$MAIN" \
    '                             when, describe=_refusal_reason, is_already_exists=_already_exists,' \
    '                             when, describe=_refusal_reason, is_already_exists=None,')
report 'M-J91i: main does not tell the replay how to recognise ALREADY_EXISTS' "$m" \
       'test_a_boot_entry_deleted_with_a_lost_answer_then_inserted_ends_as_the_insert'

m=$(mutant m1j "$MAIN" \
    '    return p4rt is not None and p4rt.get("code") == "ALREADY_EXISTS"' \
    '    return p4rt is not None')
report 'M-J91j: any per-update refusal of an unknown-start insert is taken for ALREADY_EXISTS' "$m" \
       'test_an_unknown_start_insert_refused_for_another_reason_is_not_retried'

m=$(mutant k1b "$JOURNAL" \
    '    return rec.get("op") == "delete" and rec.get("outcome") == "not_found"' \
    '    return rec.get("op") == "delete"')
report 'M-J91b: an accepted first delete leaves "before" unknown too, so a deleted-then-reinserted boot entry is replayed as an insert' "$m" \
       'test_an_accepted_delete_then_an_insert_is_still_a_modify'

# M-J91c (a snapshot writing a net delete as a NOT_FOUND one) is retired with the M1 amendment:
# a lone NOT_FOUND delete now folds to a net delete too, so that mutant changes nothing.

m=$(mutant k1d "$JOURNAL" \
    '        unknown = _was_absent(f)' \
    '        unknown = _was_absent(l)')
report 'M-J91d: the LAST record decides what was there before' "$m" \
       'test_a_not_found_delete_then_an_insert_is_an_insert'

# --- m2 (round 3): the priority is part of the key on both paths -------------------------------

m=$(mutant k2 "$CLIENT" \
    '            "entry_key": entry_key(
                self.device_id, table_name, entry.priority, recorded_match,' \
    '            "entry_key": entry_key(
                self.device_id, table_name, 0, recorded_match,')
report 'M-J92: the key a write returns drops the priority, so two priorities of one match are one entry' "$m" \
       'test_a_ternary_entry_is_recorded_under_its_priority'

m=$(mutant k2b "$CLIENT" \
    '            self.device_id, table_name, entry.priority, self._built_entry_match(entry),' \
    '            self.device_id, table_name, 0, self._built_entry_match(entry),')
report 'M-J92b: the key of a delete the switch answered NOT_FOUND drops the priority' "$m" \
       'test_and_so_does_a_ternary_spec_with_its_priority'

# --- the pipeline cookie and step 0 (ruling Q1 (a); DESIGN 5.4 step 0) -------------------------

m=$(mutant g1 "$CLIENT" \
    '        if self.pipeline_cookie is not None:
            req.config.cookie.cookie = int(self.pipeline_cookie)' \
    '        if False:
            req.config.cookie.cookie = int(self.pipeline_cookie)')
report 'M-J25: a push carries no cookie, so it clears the generation on the switch' "$m" \
       'test_every_push_carries_this_boots_generation'

m=$(mutant g1b "$MAIN" \
    '        client.pipeline_cookie = generation' \
    '        pass')
report 'M-J25b: startup never gives its clients the generation it chose' "$m" \
       'test_every_push_carries_this_boots_generation'

m=$(mutant g2 "$MAIN" \
    '    if not read_only:
        confirm_fabric(clients, journals, package)' \
    '    if False:
        confirm_fabric(clients, journals, package)')
report 'M-J95: startup never runs step 0, so a fresh bmv2 is given yesterday'\''s entries' "$m" \
       'test_a_fresh_bmv2_is_a_fresh_fabric'

m=$(mutant2 g2b "$MAIN" \
    '    if not read_only:
        confirm_fabric(clients, journals, package)

' \
    '' \
    '    if broken:
        # Loud and explicit about the consequence' \
    '    if not read_only:
        confirm_fabric(clients, journals, package)
    if broken:
        # Loud and explicit about the consequence')
report 'M-J95b: step 0 runs after the push, so it reads back the cookie this boot just pushed' "$m" \
       'test_the_restored_entries_go_back_after_the_push_that_emptied_the_switch'

m=$(mutant g3 "$JOURNAL" \
    '    kind, value = seen
    if kind != "cookie":' \
    '    kind, value = seen
    return {"confirmed": True, "cookie": value if kind == "cookie" else None, "reason": "confirmed"}
    if kind != "cookie":')
report 'M-J22: no cookie check: every switch confirms its journal' "$m" \
       'test_a_fresh_bmv2_is_a_fresh_fabric'

m=$(mutant g3b "$JOURNAL" \
    '    elif cookie_value(header.get("fabric_cookie")) != switch:' \
    '    elif False:')
report 'M-J22b: another cookie confirms the journal' "$m" \
       'test_another_cookie_is_a_fresh_fabric'

m=$(mutant g3c "$JOURNAL" \
    '    elif cookie_value(header.get("fabric_cookie")) is None:
        reason = "the journal header names no fabric cookie"' \
    '    elif cookie_value(header.get("fabric_cookie")) is None:
        return {"confirmed": True, "cookie": switch, "reason": "confirmed"}')
report 'M-J22c: a header with no cookie (a Cut B file) confirms the journal' "$m" \
       'test_a_cut_b_file_with_no_cookie_in_its_header_is_set_aside_and_not_replayed'

m=$(mutant g3d "$JOURNAL" \
    '    if value is None:
        return {"confirmed": False, "cookie": None,' \
    '    if value is None:
        return {"confirmed": True, "cookie": None,')
report 'M-J22d: a pipeline with no cookie confirms the journal' "$m" \
       'test_a_switch_whose_pipeline_carries_no_cookie_is_a_fresh_fabric'

m=$(mutant g3e "$JOURNAL" \
    '    if kind != "cookie":
        return {"confirmed": False, "cookie": None,' \
    '    if kind != "cookie":
        return {"confirmed": True, "cookie": None,')
report 'M-J22e: a switch that answered COOKIE_ONLY with an error (a fresh bmv2) confirms the journal' "$m" \
       'test_a_fresh_bmv2_is_a_fresh_fabric'

m=$(mutant g4 "$JOURNAL" \
    '    if len(values) > 1:' \
    '    if False:')
report 'M-J97: confirmed switches that disagree on the cookie stay confirmed' "$m" \
       'test_confirmed_switches_that_disagree_are_all_unconfirmed_and_a_new_generation_is_minted'

m=$(mutant g4b "$JOURNAL" \
    '    if len(values) == 1:
        return values.pop(), dict(verdicts)' \
    '    if False:
        return values.pop(), dict(verdicts)')
report 'M-J97b: a confirmed fabric is given a new generation every start' "$m" \
       'test_a_warm_switch_keeps_its_generation_across_restarts'

m=$(mutant g5 "$MAIN" \
    '        with journals.journal_for(dpid).lock:
            journals.settle(dpid, verdict, table_journal_header(dpid, package))' \
    '        if "UNAVAILABLE" in verdict["reason"]:
            continue
        with journals.journal_for(dpid).lock:
            journals.settle(dpid, verdict, table_journal_header(dpid, package))')
report 'M-J26: step 0 leaves a switch that does not answer alone (r2'\''s non-broken-only step)' "$m" \
       'test_its_journal_is_set_aside_at_step_0_and_its_readopt_replays_nothing'

m=$(mutant g6 "$JOURNAL" \
    '            return journal.write_snapshot(header_now, [])
        except OSError as exc:' \
    '            return journal.reheader(header_now)
        except OSError as exc:')
report 'M-J102: an unconfirmed journal keeps its records under this boot'\''s header' "$m" \
       'test_a_fresh_bmv2_is_a_fresh_fabric'

m=$(mutant g7 "$JOURNAL" \
    '                return journal.reheader(kept)' \
    '                return journal.write_snapshot(kept, journal.read()[1])')
report 'M-J101: step 0 rewrites a confirmed journal from what it could parse, so a torn line stops counting' "$m" \
       'test_a_torn_line_is_kept_through_step_0_and_keeps_the_replay_from_claiming_complete'

m=$(mutant g7b "$JOURNAL" \
    '                kept.update(boot_id=header_now.get("boot_id"),' \
    '                kept.update(boot_id=kept.get("boot_id"),')
report 'M-J101b: step 0 leaves a confirmed header naming the boot that wrote it, so the replay refuses it' "$m" \
       'test_a_journal_another_proxy_process_wrote_is_replayed_when_the_cookie_confirms_it'

m=$(mutant g8 "$MAIN" \
    '        with journals.journal_for(dpid).lock:
            journals.settle(dpid, verdict, table_journal_header(dpid, package))' \
    '        if True:
            journals.settle(dpid, verdict, table_journal_header(dpid, package))')
report 'M-J104: step 0 sets a journal aside without its lock' "$m" \
       'test_entries_posted_before_a_restart_are_on_the_warm_switch_after_it'

m=$(mutant g9 "$MAIN" \
    '           "fabric_cookie": rule_journal.cookie_hex(_generation["cookie"])}' \
    '           "fabric_cookie": None}')
report 'M-J113: the headers main builds name no fabric generation, so no later start can confirm them' "$m" \
       'test_the_headers_main_builds_name_this_boots_fabric_generation'

# --- steps 1, 3-6: the replay ----------------------------------------------------------------

m=$(mutant h1 "$MAIN" \
    '            with journals.journal_for(i).lock:
                replay_table_journal(client, i, journals, package, "startup")' \
    '            pass')
report 'M-J94: startup never replays (the startup caller of fold and snapshot is gone)' "$m" \
       'test_entries_posted_before_a_restart_are_on_the_warm_switch_after_it'

m=$(mutant h1b "$MAIN" \
    '            with journals.journal_for(i).lock:
                replay_table_journal(client, i, journals, package, "startup")' \
    '            replay_table_journal(client, i, journals, package, "startup")')
report 'M-J94b: startup replays without the switch'\''s lock, so its snapshot is refused' "$m" \
       'test_entries_posted_before_a_restart_are_on_the_warm_switch_after_it'

m=$(mutant h2 "$JOURNAL" \
    '                try:
                    apply(item["spec"], item["op"])' \
    '                try:
                    pass')
report 'M-J15: the replay writes nothing back' "$m" \
       'test_entries_posted_before_a_restart_are_on_the_warm_switch_after_it'

m=$(mutant h3 "$JOURNAL" \
    '                continue
            restored.append(item)
        report["succeeded"] = len(restored)' \
    '                continue
            restored.append(item)
            journal.record(item["op"], item["spec"], item["key"])
        report["succeeded"] = len(restored)')
report 'M-J4: the replay appends what it writes to the journal it is replaying' "$m" \
       'test_the_set_aside_files_are_the_old_journal_and_nothing_was_appended_to_it'

m=$(mutant h4 "$JOURNAL" \
    '        pipeline_changed = (header.get("p4info_sha256") is None
                            or header.get("p4info_sha256") != header_now.get("p4info_sha256"))' \
    '        pipeline_changed = False')
report 'M-J5: the p4info digest is not checked' "$m" \
       'test_a_changed_p4info_replays_nothing'

m=$(mutant h5 "$JOURNAL" \
    '        entries_changed = header.get("entries_sha256") != header_now.get("entries_sha256")' \
    '        entries_changed = False')
report 'M-J16: the entries-file digest is not checked' "$m" \
       'test_a_changed_entries_file_replays_the_inserts_and_not_what_was_aimed_at_its_entries'

m=$(mutant h5b "$JOURNAL" \
    '            if entries_changed and item["op"] != "insert":' \
    '            if entries_changed:')
report 'M-J16b: a changed entries file stops the inserts too' "$m" \
       'test_a_changed_entries_file_replays_the_inserts_and_not_what_was_aimed_at_its_entries'

m=$(mutant h6 "$JOURNAL" \
    '                if (item["op"] == "delete" and is_not_found is not None
                        and is_not_found(exc)):' \
    '                if False:')
report 'M-J98: a net delete whose entry is already gone is counted as a failure and leaves the journal' "$m" \
       'test_a_net_delete_the_switch_answers_not_found_has_reached_its_goal'

m=$(mutant h6b "$MAIN" \
    '                             table_journal_header(dpid, package), api_routes._is_not_found,' \
    '                             table_journal_header(dpid, package), None,')
report 'M-J98b: main does not tell the replay how to recognise NOT_FOUND' "$m" \
       'test_a_net_delete_the_switch_answers_not_found_has_reached_its_goal'

m=$(mutant h7 "$JOURNAL" \
    '        kept = [i for i in net if i["key"] in keep]' \
    '        kept = list(net)')
report 'M-J99: what did not go back stays in the live journal' "$m" \
       'test_a_write_the_switch_refuses_at_replay_is_reported_and_leaves_the_journal'

m=$(mutant h8 "$MAIN" \
    '                             when, describe=_refusal_reason, is_already_exists=_already_exists,' \
    '                             when, is_already_exists=_already_exists,')
report 'M-J100: a refusal at replay is reported as the bare exception, not the switch'\''s reason' "$m" \
       'test_a_write_the_switch_refuses_at_replay_is_reported_and_leaves_the_journal'

m=$(mutant h9 "$JOURNAL" \
    '            report["snapshot_error"] = f"{type(exc).__name__}: {exc}"
            with self._registry_lock:' \
    '            report["snapshot_error"] = f"{type(exc).__name__}: {exc}"
            return
            with self._registry_lock:')
report 'M-J108: a snapshot that failed does not withdraw the claim' "$m" \
       'test_a_snapshot_that_fails_is_reported_and_the_switch_is_not_journaled'

m=$(mutant h10 "$MAIN" \
    '    if not journals.enabled:
        return journals.note_skipped(dpid, "the table-entry journal is off", when)' \
    '    if False:
        return journals.note_skipped(dpid, "the table-entry journal is off", when)')
report 'M-J109: a journal that is off is replayed anyway' "$m" \
       'test_a_journal_that_is_off_replays_nothing_and_says_so'

m=$(mutant h11 "$MAIN" \
    '        if read_only:
            journals.note_skipped(i, "external control plane")' \
    '        if False:
            journals.note_skipped(i, "external control plane")')
report 'M-J6: an external control plane'\''s journal is replayed' "$m" \
       'test_nothing_is_read_replayed_or_written_on_an_external_fabric'

m=$(mutant h11b "$MAIN" \
    '    if not read_only:
        confirm_fabric(clients, journals, package)' \
    '    if True:
        confirm_fabric(clients, journals, package)')
report 'M-J6b: step 0 reads and rewrites an external control plane'\''s journal' "$m" \
       'test_nothing_is_read_replayed_or_written_on_an_external_fabric'

m=$(mutant h12 "$MAIN" \
    '        elif i in broken:
            journals.note_skipped(' \
    '        elif False:
            journals.note_skipped(')
report 'M-J110: a switch whose push failed is replayed into' "$m" \
       'test_its_journal_is_set_aside_at_step_0_and_its_readopt_replays_nothing'

m=$(mutant h13 "$JOURNAL" \
    '        if header is None or header.get("boot_id") != header_now.get("boot_id"):' \
    '        if header is None:')
report 'M-J27: the replay does not check that this boot confirmed the file' "$m" \
       'test_a_readopt_replays_nothing_from_a_file_this_boot_did_not_confirm'

m=$(mutant h14 "$JOURNAL" \
    '        header, records, unreadable = journal.read()
        report["unreadable"] = unreadable' \
    '        cache = self.__dict__.setdefault("_mutant_first_read", {})
        if key not in cache:
            cache[key] = journal.read()
        header, records, unreadable = cache[key]
        report["unreadable"] = unreadable')
report 'M-J17: a readopt replays the list startup read, not the file' "$m" \
       'test_an_entry_posted_after_startup_is_back_after_a_readopt'

m=$(mutant h15 "$JOURNAL" \
    '        report = dict(report, status=status)
        self._replays[key] = report' \
    '        report = dict(report, status=status)
        prev = self._replays.get(key)
        if prev:
            report["attempted"] += prev["attempted"]
            report["succeeded"] += prev["succeeded"]
        self._replays[key] = report')
report 'M-J10: a readopt adds its replay to the last one instead of replacing it' "$m" \
       'test_two_readopts_report_the_same_replay'

# --- readopt: pending, the lock, the caller, the cookie (DESIGN 5.5) ----------------------------

m=$(mutant p1 "$JOURNAL" \
    '    def _refuse_pending(self, dpid):
        if self.pending(dpid):' \
    '    def _refuse_pending(self, dpid):
        if False:')
report 'M-J18: no pending flag, so a POST during a readopt waits for the lock and is a busy 503 at best' "$m" \
       'test_a_post_while_the_switch_is_being_readopted_is_503_and_writes_nothing'

m=$(mutant p1b "$JOURNAL" \
    '        journal = self.journal_for(dpid)
        self._refuse_pending(dpid)
        with _held(' \
    '        journal = self.journal_for(dpid)
        with _held(')
report 'M-J18b: pending is only checked once the lock is held, so the POST queues behind the readopt' "$m" \
       'test_on_a_switch_being_readopted_it_is_replay_pending_at_once'

m=$(mutant p1c "$JOURNAL" \
    '            self._refuse_pending(dpid)
            client = get_client()' \
    '            client = get_client()')
report 'M-J18c: a write that got past the first check is not checked again inside the lock' "$m" \
       'test_a_write_that_got_past_the_first_check_meets_the_second_inside_the_lock'

m=$(mutant p1d "$ROUTES" \
    '    except ReplayPending as err:' \
    '    except KeyboardInterrupt as err:')
report 'M-J18d: a switch being readopted is a 500, not a 503' "$m" \
       'test_a_switch_being_readopted_is_503_replay_pending_and_writes_nothing'

m=$(mutant2 p1e "$JOURNAL" \
    '                try:
                    yield journal
                finally:
                    drop()' \
    '                yield journal
                drop()' \
    '        finally:
            drop()

    # --- step 0' \
    '        finally:
            pass

    # --- step 0')
report 'M-J18e: a readopt that failed leaves the switch pending for ever' "$m" \
       'test_the_pending_flag_comes_down_after_a_readopt_and_after_one_that_failed'

m=$(mutant2 p2 "$MAIN" \
    '    with journals.replaying(dpid):
        return _readopt_switch_locked(topology, dpid, client_factory, sample_callback, package,
                                      journals)' \
    '    return _readopt_switch_locked(topology, dpid, client_factory, sample_callback, package,
                                  journals)' \
    '    result["table_entries"]["replay"] = replay_table_journal(
        topology.switches.get(dpid), dpid, journals, package, "readopt")' \
    '    with journals.replaying(dpid):
        result["table_entries"]["replay"] = replay_table_journal(
            topology.switches.get(dpid), dpid, journals, package, "readopt")')
report 'M-J20: the lock is taken after the new client is swapped in, so a POST lands in between' "$m" \
       'test_a_post_between_the_new_clients_swap_and_the_replay_is_503'

m=$(mutant p2b "$MAIN" \
    '    with journals.replaying(dpid):
        return _readopt_switch_locked(' \
    '    if True:
        return _readopt_switch_locked(')
report 'M-J20b: a readopt takes no lock at all, so its snapshot is refused' "$m" \
       'test_an_entry_posted_after_startup_is_back_after_a_readopt'

m=$(mutant p3 "$MAIN" \
    '    result["table_entries"]["replay"] = replay_table_journal(
        topology.switches.get(dpid), dpid, journals, package, "readopt")' \
    '    result["table_entries"]["replay"] = None')
report 'M-J93: a readopt never replays (the readopt caller of fold and snapshot is gone)' "$m" \
       'test_an_entry_posted_after_startup_is_back_after_a_readopt'

m=$(mutant p4 "$MAIN" \
    '        client.pipeline_cookie = _generation["cookie"]' \
    '        client.pipeline_cookie = rule_journal.cookie_value(
            (table_journals.journal_for(dpid).read()[0] or {}).get("fabric_cookie"))')
report 'M-J28: a readopt pushes the cookie its journal header names, not this boot'\''s' "$m" \
       'test_a_readopt_pushes_this_boots_generation_not_the_one_a_header_names'

m=$(mutant p4b "$MAIN" \
    '        client.pipeline_cookie = _generation["cookie"]' \
    '        pass')
report 'M-J28b: a readopt pushes no cookie' "$m" \
       'test_the_readopts_push_carries_this_boots_generation'

m=$(mutant p5 "$JOURNAL" \
    '                    os.path.join(self.directory, f"s{key}.jsonl"), dpid, header=header)' \
    '                    os.path.join(self.directory, "all.jsonl"), dpid, header=header)')
report 'M-J19: one file for every switch, each with its own lock: a readopt'\''s snapshot sets the others'\'' records aside' "$m" \
       'test_a_readopt_of_one_switch_leaves_the_others_record_in_its_own_file'

# --- m6: the snapshot's lock, header shape, temp files and mode ---------------------------------

m=$(mutant q1 "$JOURNAL" \
    '        if not self.lock.locked():
            raise RuntimeError(' \
    '        if False:
            raise RuntimeError(')
report 'M-J103: a snapshot is taken with nobody holding the lock' "$m" \
       'test_a_snapshot_nobody_holds_the_lock_for_is_refused'

m=$(mutant q2 "$JOURNAL" \
    '        self._sweep_temp(directory)
        fd, tmp' \
    '        fd, tmp')
report 'M-J105: a temp file a dead snapshot left is never removed' "$m" \
       'test_a_temp_file_a_dead_snapshot_left_is_removed_by_the_next'

m=$(mutant q2b "$JOURNAL" \
    '            names = [n for n in os.listdir(directory) if n.startswith(prefix)]
        except OSError:
            return
        for name in names:' \
    '            names = [n for n in os.listdir(directory) if ".tmp." in n]
        except OSError:
            return
        for name in names:')
report 'M-J105b: the sweep removes another switch'\''s temp file' "$m" \
       'test_a_temp_file_a_dead_snapshot_left_is_removed_by_the_next'

m=$(mutant q3 "$JOURNAL" \
    '            os.chmod(tmp, _created_mode(self.path))' \
    '            pass')
report 'M-J106: a snapshot leaves the journal 0600' "$m" \
       'test_the_live_file_keeps_its_mode_through_a_snapshot'

m=$(mutant q4 "$JOURNAL" \
    '        header.update({k: v for k, v in dict(fields or {}).items()
                       if k in header and k not in ("v", "header", "dpid")})' \
    '        header.update(dict(fields or {}))')
report 'M-J107: a snapshot header takes whatever keys it is given, the dpid included' "$m" \
       'test_a_snapshot_header_has_the_shape_a_recorded_header_has'

m=$(mutant q5 "$JOURNAL" \
    'QUARANTINE_KEEP = 10' \
    'QUARANTINE_KEEP = 3')
report 'M-J40c: fewer than ten set-aside generations are kept' "$m" \
       'test_ten_generations_are_kept_by_default'

# --- round 2 of Cut C (2026-10-12) ------------------------------------------------------------
# [Co-developed with claude code -- Adam]

m=$(mutant q6 "$MAIN" \
    '    if not journals.enabled:
        # DESIGN 5.4 step 0 as amended' \
    '    if False:
        # DESIGN 5.4 step 0 as amended')
report 'M-J114 (§7-1 (b)): a boot with the journal off confirms its switches, so the next start undoes what was deleted while it was off' "$m" \
       'test_an_entry_deleted_while_the_journal_was_off_stays_deleted'

m=$(mutant q7 "$MAIN" \
    '        elif not client.json_path:' \
    '        elif False:')
report 'M-J115 (§7-2): a switch that was not pushed is replayed into, and every insert meets its entry' "$m" \
       'test_a_switch_that_was_not_pushed_is_not_replayed_into'

m=$(mutant q8 "$CLIENT" \
    '    def read_pipeline_cookie(self, timeout_s: float = RPC_TIMEOUT_S):' \
    '    def read_pipeline_cookie(self, timeout_s: float = 2.0):')
report 'M-J116 (§2-3): COOKIE_ONLY waits the probe'\''s 2 s, not one write deadline' "$m" \
       'test_cookie_only_is_given_rpc_timeout_s'

m=$(mutant q9 "$JOURNAL" \
    '            with open(self.path, "rb") as fh:
                for raw in fh:
                    raw = raw.strip()' \
    '            with open(self.path, "r", encoding="utf-8") as fh:
                for raw in fh:
                    raw = raw.strip().encode("utf-8")')
report 'M-J117 (m-1): the journal is decoded as text outside the per-line try, so one bad byte stops startup' "$m" \
       'test_a_line_that_is_not_utf8_is_one_unreadable_line_not_an_exception'

m=$(mutant q10 "$JOURNAL" \
    '            self._fabric[key]["error"] = f"{type(exc).__name__}: {exc}"
            with self._registry_lock:
                self._failures[key] = self._failures.get(key, 0) + 1
            return None' \
    '            self._fabric[key]["error"] = f"{type(exc).__name__}: {exc}"
            return None')
report 'M-J118 (m-2): a failed step 0 is not counted, so the switch still claims journaled' "$m" \
       'test_a_header_rewrite_that_fails_is_in_the_report_and_withdraws_the_claim'

m=$(mutant q11 "$JOURNAL" \
    '"step0_error": fabric.get("error"),' \
    '"step0_error": None,')
report 'M-J119 (m-2): the replay never says step 0 failed' "$m" \
       'test_a_header_rewrite_that_fails_is_in_the_report_and_withdraws_the_claim'

m=$(mutant q12 "$JOURNAL" \
    '                if unknown_outcome:
                    kept_unknown.append(item)' \
    '                if False:
                    kept_unknown.append(item)')
report 'M-J120 (m-5): a replayed write that timed out is dropped from the journal although it may have landed' "$m" \
       'test_an_insert_that_timed_out_stays_in_the_journal_and_comes_back_next_start'

m=$(mutant q13 "$MAIN" \
    '    return api_routes._grpc_status_name(exc) is not None and api_routes._p4rt_error(exc) is None' \
    '    return api_routes._grpc_status_name(exc) is not None')
report 'M-J121 (m-5): a write the switch refused per update is kept too, so it is retried for ever' "$m" \
       'test_a_write_the_switch_refused_per_update_is_still_dropped'

m=$(mutant q14 "$MAIN" \
    '                             outcome_unknown=_outcome_unknown)' \
    '                             outcome_unknown=None)')
report 'M-J122 (m-5): main does not tell the replay which failures have no answer' "$m" \
       'test_an_insert_that_timed_out_stays_in_the_journal_and_comes_back_next_start'

m=$(mutant q15 "$JOURNAL" \
    '                    if left > 0:
                        self._pending[key] = left
                    else:
                        self._pending.pop(key, None)' \
    '                    self._pending.pop(key, None)')
report 'M-J123: pending is a flag, so the first of two overlapping readopts clears the second'\''s' "$m" \
       'test_two_overlapping_readopts_keep_the_switch_pending_until_the_second_ends'

m=$(mutant q16 "$ROUTES" \
    '    "the switch took this write but the journal did not record it: a later restart or readopt "' \
    '    "the entry is on the switch but the journal write failed: it is lost when the proxy restarts "')
report 'M-J124 (M-2): the unrecorded-write note says "lost when the proxy restarts", true of an insert only' "$m" \
       'test_the_note_for_an_unrecorded_write_says_what_each_op_turns_into'

m=$(mutant q17 "$ROUTES" \
    'TABLE_ENTRY_JOURNAL_OFF = (' \
    'TABLE_ENTRY_JOURNAL_OFF = TABLE_ENTRY_NOT_JOURNALED
_UNUSED_OFF = (')
report 'M-J125 (M-2): a journal that is off answers with the multicast sentence again' "$m" \
       'test_the_note_for_a_journal_that_is_off_says_what_each_op_turns_into'

# --- n3 (round 3): only the per-update reason says NOT_FOUND --------------------------------------

m=$(mutant k3 "$ROUTES" \
    '    return p4rt is not None and p4rt.get("code") == "NOT_FOUND"' \
    '    return p4rt is None or p4rt.get("code") == "NOT_FOUND"')
report 'M-J112: a refusal with no per-update reason is taken for NOT_FOUND and recorded' "$m" \
       'test_a_top_level_not_found_with_no_per_update_reason_is_not_recorded'

# --- m3 (round 3) ------------------------------------------------------------------------------

m=$(mutant r10 "$JOURNAL" \
    '        journal = self.journal_for(dpid)
        self._refuse_pending(dpid)
        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)
            client = get_client()' \
    '        journal = self.journal_for(dpid)
        self._refuse_pending(dpid)
        early = get_client()
        if early is not None:
            early._refuse_owned_table(spec, op, "api")
        with _held(journal.lock, lock_timeout, f"switch {dpid}"):
            self._refuse_pending(dpid)
            client = get_client()')
report 'M-J111: the owner check runs before the lock, so a write behind a busy switch is a 409 instead of a 503' "$m" \
       'test_behind_a_held_lock_it_is_switch_busy_and_the_owner_check_never_ran'

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
    out = []' \
    '    # MUTANT: a comment, and nothing else.
    now = time.time() if now is None else now
    out = []')
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
    '    out = {"boot_id": boot_identity.BOOT_ID,' \
    '    # MUTANT: a comment, and nothing else.
    out = {"boot_id": boot_identity.BOOT_ID,')
control 'N4 (control): a comment-only edit in the header builder' "$m" "the whole suite stays green"

m=$(mutant n5 "$CLIENT" \
    '        table_name = self._table_name(entry.table_id)
        return entry_key(' \
    '        # MUTANT: a comment, and nothing else.
        table_name = self._table_name(entry.table_id)
        return entry_key(')
control 'N5 (control): a comment-only edit in table_entry_key' "$m" "the whole suite stays green"

m=$(mutant n7 "$JOURNAL" \
    '        net = fold_records(records)
        report["attempted"] = len(net)' \
    '        # MUTANT: a comment, and nothing else.
        net = fold_records(records)
        report["attempted"] = len(net)')
control 'N7 (control): a comment-only edit in the replay' "$m" "the whole suite stays green"

m=$(mutant n8 "$MAIN" \
    '    mint = mint_fabric_cookie if mint is None else mint' \
    '    # MUTANT: a comment, and nothing else.
    mint = mint_fabric_cookie if mint is None else mint')
control 'N8 (control): a comment-only edit in step 0' "$m" "the whole suite stays green"

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
[[ "$(sha256sum "$TEST_REPLAY" | cut -d' ' -f1)" == "$BASE_TEST_REPLAY" ]] || { echo "🔴 baseline CHANGED -- test_table_entry_replay.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (5 sources, 6 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
