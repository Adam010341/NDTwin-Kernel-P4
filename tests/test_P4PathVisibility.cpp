/**
 * @file test_P4PathVisibility.cpp
 * @brief The pure half of `flow_stats` and `path_unconfirmed_at` (P4PathVisibility.hpp).
 *
 * [Co-developed with claude code -- Adam]
 *
 * THE CONTRACT (doc/2026-01-02_ndt_api.md sections 3, 4 and 30):
 *
 *   - a switch node MAY carry `flow_stats`, the proxy's per-switch object from
 *     GET /p4/switch_state, verbatim;
 *   - a flow row whose path has a switch on it, while the proxy has a record for some switch,
 *     carries `path_unconfirmed_at`: in path order, each switch on the path whose
 *     `unrendered_entries` is not 0 (null included), as {"dpid", "unrendered_entries"}, and a
 *     switch with no record while others have one, with a null count; `[]` when every switch on
 *     the path had a record and said 0;
 *   - when the proxy has no record for any switch, or the path is empty, there is no such key;
 *   - the first path element is the source host when its node is the row's src_ip, the last is
 *     the destination host when its node is the row's dst_ip and its interface is 0; hosts are
 *     never looked up, and any other element is scanned like a switch, the last included.
 *
 * The numbers in the first case are the ones a live firewall run read (switch 1 hiding 8 rows of
 * its ACL table, switches 2-4 hiding none, the path h3 -> s2 -> s3 -> s1 -> h1). The wiring --
 * the 1 Hz poll and the three endpoints -- is in test_P4Capabilities.cpp, which owns the peer
 * that drives HttpSession.
 */

#include <cstdint>
#include <optional>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "ndt_core/power_management/P4PathVisibility.hpp"

using json = nlohmann::json;

namespace
{

/// Host addresses as the path carries them: network-byte-order integers (10.0.3.3, 10.0.1.1).
constexpr std::uint64_t kH3 = 50528266;
constexpr std::uint64_t kH1 = 16842762;

json
hop(std::uint64_t node, std::uint32_t interface)
{
    return json{{"node", node}, {"interface", interface}};
}

/// One flow row in the shape getFlowInfoJson emits it, trimmed to the keys this code reads and a
/// few it must leave alone.
json
row(const json& path, std::uint64_t srcIp = kH3, std::uint64_t dstIp = kH1)
{
    return json{{"src_ip", srcIp},
                {"dst_ip", dstIp},
                {"src_port", 40000},
                {"dst_port", 5001},
                {"protocol_id", 6},
                {"liveness", "active"},
                {"path", path}};
}

/// h3 -> s2:4 -> s3:1 -> s1:1 -> h1, the path the twin served for the firewall's flows.
json
firewallPath()
{
    return json::array({hop(kH3, 1), hop(2, 4), hop(3, 1), hop(1, 1), hop(kH1, 0)});
}

json
count(json n)
{
    return json{{"unrendered_entries", std::move(n)}};
}

/// The firewall run's `flow_stats`: s1 hides 8 rows, s2-s4 none.
p4paths::FlowStatsByDpid
firewallStats()
{
    return {{1, count(8)}, {2, count(0)}, {3, count(0)}, {4, count(0)}};
}

json
annotatedOne(const json& path,
             const p4paths::FlowStatsByDpid& stats,
             std::uint64_t srcIp = kH3,
             std::uint64_t dstIp = kH1)
{
    json rows = json::array({row(path, srcIp, dstIp)});
    p4paths::annotateFlowRows(rows, stats);
    return rows.at(0);
}

VertexProperties
vertexOf(VertexType type, std::uint64_t dpid)
{
    VertexProperties v;
    v.vertexType = type;
    v.dpid = dpid;
    v.mac = 0x020000000000ULL + dpid;
    v.deviceName = (type == VertexType::SWITCH ? "s" : "h") + std::to_string(dpid);
    v.nickName = v.deviceName;
    return v;
}

json
entryWithFlowStats(const json& flowStats)
{
    return json{{"probe_ok", true}, {"stream_alive", true}, {"flow_stats", flowStats}};
}

} // namespace

// === `flow_stats` from GET /p4/switch_state ===================================================

TEST(P4FlowStats, AReportIsCopiedVerbatimAndNullIsKept)
{
    json withoutCount = json::object();
    const json body = {{"status", "success"},
                       {"switches",
                        {{"1", entryWithFlowStats(count(8))},
                         {"2", entryWithFlowStats(count(nullptr))},
                         {"3", entryWithFlowStats(withoutCount)},
                         {"4", entryWithFlowStats(nullptr)},
                         {"5", json{{"probe_ok", true}}}}}};

    const p4paths::FlowStatsByDpid got = p4paths::fromSwitchState(body);

    const p4paths::FlowStatsByDpid expected = {
        {1, count(8)}, {2, count(nullptr)}, {3, withoutCount}};
    EXPECT_EQ(got, expected) << "a null count is the proxy saying 'not rendered yet' and must "
                                "survive; a record that is not an object is no record";
    EXPECT_TRUE(p4paths::fromSwitchState(std::nullopt).empty());
}

TEST(P4FlowStats, AttachPutsTheRecordOnItsSwitchOnly)
{
    const p4paths::FlowStatsByDpid stats = {{3, count(8)}};
    json s3 = json::object(), s2 = json::object(), host = json::object();
    p4paths::attachToNode(s3, vertexOf(VertexType::SWITCH, 3), stats);
    p4paths::attachToNode(s2, vertexOf(VertexType::SWITCH, 2), stats);
    p4paths::attachToNode(host, vertexOf(VertexType::HOST, 3), stats);
    EXPECT_EQ(s3, (json{{"flow_stats", count(8)}}));
    EXPECT_EQ(s2, json::object()) << "a switch the proxy said nothing of carries nothing";
    EXPECT_EQ(host, json::object()) << "a host has no tables, whatever its dpid field holds";
}

// === `path_unconfirmed_at` on a flow row ======================================================

TEST(P4PathVisibility, APathThroughASwitchHidingRowsNamesIt)
{
    const json got = annotatedOne(firewallPath(), firewallStats());
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 1}, {"unrendered_entries", 8}}}));
}

TEST(P4PathVisibility, TheSwitchesAreListedInPathOrderSoTheFirstIsWhereConfirmationStops)
{
    // s2 is the first switch on the path and hides 5; s1 is the last and hides 8. Listed by
    // position on the path, not by dpid: the first element answers "from where on is this path
    // not confirmed".
    p4paths::FlowStatsByDpid stats = firewallStats();
    stats[2] = count(5);
    const json got = annotatedOne(firewallPath(), stats);
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 2}, {"unrendered_entries", 5}},
                           {{"dpid", 1}, {"unrendered_entries", 8}}}));
}

TEST(P4PathVisibility, APathWhoseSwitchesHideNothingIsAnEmptyList)
{
    // NDTwin's own pipeline: every switch left out no row it counts. `[]` is an answer -- every
    // switch on the path had a record and said 0 -- and it must not be confused with "nobody
    // said" (no key).
    const json got = annotatedOne(firewallPath(),
                                  {{1, count(0)}, {2, count(0)}, {3, count(0)}, {4, count(0)}});
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"), json::array());
}

TEST(P4PathVisibility, ANullCountIsListed)
{
    // null is "this switch has not been rendered yet", which is not "it hides nothing". A record
    // with no count at all reads the same way.
    p4paths::FlowStatsByDpid stats = firewallStats();
    stats[1] = count(nullptr);
    stats[3] = json::object();
    const json got = annotatedOne(firewallPath(), stats);
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 3}, {"unrendered_entries", nullptr}},
                           {{"dpid", 1}, {"unrendered_entries", nullptr}}}));
}

TEST(P4PathVisibility, ASwitchWithNoRecordBesideSwitchesThatHaveOneIsListedAsNull)
{
    // The proxy describes switches 1, 2 and 4 and says each hides nothing; it has no record for
    // switch 3, which is on the path. Nobody said s3 hides nothing, so it is listed as
    // unconfirmed with a null count rather than passed over as if it had said 0.
    const json got = annotatedOne(firewallPath(), {{1, count(0)}, {2, count(0)}, {4, count(0)}});
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 3}, {"unrendered_entries", nullptr}}}));

    // The proxy describes switches 7 and 8, neither of which is on this path: every switch on the
    // path is then one nobody described.
    const json none = annotatedOne(firewallPath(), {{7, count(3)}, {8, count(0)}});
    ASSERT_TRUE(none.contains("path_unconfirmed_at")) << none.dump();
    EXPECT_EQ(none.at("path_unconfirmed_at"),
              json::array({{{"dpid", 2}, {"unrendered_entries", nullptr}},
                           {{"dpid", 3}, {"unrendered_entries", nullptr}},
                           {{"dpid", 1}, {"unrendered_entries", nullptr}}}));
}

TEST(P4PathVisibility, NoRecordForAnySwitchOnTheFabricMeansNoKey)
{
    // The proxy described no switch at all: an OVS fabric, a proxy too old to report, or one the
    // kernel could not read. Nobody said anything, so the row says nothing either.
    json rows = json::array({row(firewallPath())});
    p4paths::annotateFlowRows(rows, {});
    EXPECT_FALSE(rows.at(0).contains("path_unconfirmed_at")) << rows.dump();
}

TEST(P4PathVisibility, TheEndpointsAreHostsAndAreNeverLookedUp)
{
    // Hosts whose address integers are also dpids with records, as on a small fabric where 1 is
    // a dpid and a reading of 1.0.0.0. Only s2 is a switch on this path and it hides nothing.
    const json path = json::array({hop(5, 1), hop(2, 3), hop(6, 0)});
    const json got = annotatedOne(path, {{5, count(4)}, {2, count(0)}, {6, count(9)}}, 5, 6);
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"), json::array())
        << "a host's address was looked up as a dpid";
}

TEST(P4PathVisibility, APathThatEndsAtASwitchIsScannedToItsEnd)
{
    // The walk reached a host that does not own the destination address, stopped without a
    // destination element, and committed h3 -> s2 -> s1. s1 is the last element and hides 8.
    const json path = json::array({hop(kH3, 1), hop(2, 4), hop(1, 1)});
    const json got = annotatedOne(path, firewallStats());
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 1}, {"unrendered_entries", 8}}}))
        << "the last switch of a path that has no destination host was skipped";
}

TEST(P4PathVisibility, ALastElementWithAnEgressPortIsASwitchEvenIfItsNodeIsTheDestination)
{
    // The destination host is written with interface 0. An element whose node equals dst_ip but
    // that has an egress port is not that host: here dpid 5 is also the destination address.
    const json path = json::array({hop(kH3, 1), hop(2, 4), hop(5, 3)});
    const json got = annotatedOne(path, {{2, count(0)}, {5, count(7)}}, kH3, 5);
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 5}, {"unrendered_entries", 7}}}));
}

TEST(P4PathVisibility, APathThatDoesNotStartAtItsSourceHostIsScannedFromItsFirstElement)
{
    // The first element is not the row's source host (src_ip is h3): it is a switch, dpid 1.
    const json path = json::array({hop(1, 3), hop(2, 4), hop(kH1, 0)});
    const json got = annotatedOne(path, firewallStats());
    ASSERT_TRUE(got.contains("path_unconfirmed_at")) << got.dump();
    EXPECT_EQ(got.at("path_unconfirmed_at"),
              json::array({{{"dpid", 1}, {"unrendered_entries", 8}}}))
        << "the first element was skipped without asking whose address it is";
}

TEST(P4PathVisibility, AnEmptyPathGetsNoKey)
{
    // The walk could not trace the flow. There is no path to confirm or not.
    const json got = annotatedOne(json::array(), firewallStats());
    EXPECT_FALSE(got.contains("path_unconfirmed_at")) << got.dump();
}

TEST(P4PathVisibility, EveryOtherKeyOfTheRowIsLeftAsItWas)
{
    const json before = row(firewallPath());
    json after = annotatedOne(firewallPath(), firewallStats());
    after.erase("path_unconfirmed_at");
    EXPECT_EQ(after, before);

    // And with nothing known, the rows are not touched at all.
    json rows = json::array({row(firewallPath()), row(json::array())});
    const json untouched = rows;
    p4paths::annotateFlowRows(rows, {});
    EXPECT_EQ(rows, untouched);
}
