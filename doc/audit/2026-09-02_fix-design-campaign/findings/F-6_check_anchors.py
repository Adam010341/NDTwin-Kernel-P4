"""F-6: count each mutation anchor of tests/shell/mutate_f6_stale_table_carry_forward.sh in its
target file. Every one must occur exactly once.

Lives beside the F-6 findings, not in the shared session scratchpad: a sibling session overwrote
the first copy there on 2026-09-02 (same filename, different ticket).

Run from the repo root:
    python3 <this file> ; echo rc=$?
"""
import pathlib
import sys

HDR_PATH = "include/ndt_core/power_management/StaleTableCarryForward.hpp"
SRC_PATH = "src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp"
HDR = pathlib.Path(HDR_PATH).read_text()
SRC = pathlib.Path(SRC_PATH).read_text()

anchors = [
    ("1 carry-forward disabled", "SRC",
     "                                                         fetched.unread,"),
    ("2 stale_since never set", "HDR",
     "        entry[kStaleSinceField] = staleSince;"),
    ("3 down switch polled", "SRC",
     "    return props.vertexType == VertexType::SWITCH && props.isUp;"),
    ("4 stale_polls flat", "HDR",
     "        entry[kStalePollsField] = priorPolls + 1;"),
    ("5 never-read omitted", "HDR",
     '            entry = nlohmann::json{{"dpid", u.dpid}, {"flows", nlohmann::json::object()}};\n'
     "            entry[kNeverReadField] = true;"),
    ("6 stale beats fresh", "HDR",
     "        if (ndt_detail::findSwitchIndex(fresh, u.dpid) != fresh.size())"),
    ("7 T-11 eats markers", "SRC",
     "    stripUnprogrammedEntries(out, m_isProgrammed);"),
    ("8 merge outside lock", "SRC",
     "    std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);\n\n"
     "    const std::size_t carried = carryForwardUnreadTables(fetched.tables,\n"
     "                                                         m_cachedOpenFlowTables,"),
    ("NEG control", "HDR", "    std::size_t carried = 0;"),
]

bad = 0
for name, where, a in anchors:
    n = (HDR if where == "HDR" else SRC).count(a)
    if n != 1:
        bad += 1
    print(f"  {'ok ' if n == 1 else 'BAD'} {n}  {name}  [{where}]")

# The reason the script itself does not use `grep -c -F`: grep splits a multi-line -F pattern into
# separate patterns and counts matching LINES, so a unique two-line anchor reports 2.
m5 = anchors[4][2]
print(f"\n  (multi-line anchor 5 occurs {HDR.count(m5)}x by substring; "
      f"grep -c -F would say {sum(1 for line in HDR.splitlines() if any(l in line for l in m5.splitlines()))})")

print("ALL ANCHORS UNIQUE" if not bad else f"{bad} ANCHOR(S) NOT UNIQUE")
sys.exit(1 if bad else 0)
