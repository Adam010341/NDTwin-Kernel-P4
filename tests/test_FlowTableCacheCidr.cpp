/**
 * CIDR destinations on the kernel's flow-batch path: the table cache and the pre-queue check.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Since 2026-10-23 a destination such as 10.0.1.0/24 is accepted on the P4 proxy's
 * Ryu-compatible path (a /32 stays the bare address), and Ryu always took one. The kernel sits in
 * front of both: HttpSession::processFlowBatch queues the jobs and only then hands the same body
 * to DeviceConfigurationAndPowerManager::updateOpenFlowTables, which looks up the cached row a
 * modify or delete names. That lookup read `ipv4_dst` with inet_pton, so "10.0.1.0/24" threw
 * after the switch had been written and the reply became an error; it never read `nw_dst`, so
 * the same prefix spelled that way became 0.0.0.0 and matched rows it is not.
 *
 * What is pinned here, all through the real class and the real admission check:
 *   - a /24 on either spelling neither throws nor matches anything but itself, in the request
 *     and in a cached row, including Ryu's a.b.c.d/m.m.m.m spelling of the same prefix;
 *   - the served view keeps the prefix as the prefix it is;
 *   - a /32 matches exactly as it did on ipv4_dst; on nw_dst it now matches its own address
 *     rather than every same-priority row with no ipv4_dst (NwDst32... below);
 *   - an unreadable address (including "" and null) is refused by describeFlowEntryShapeProblem,
 *     which processFlowBatch runs before anything is queued, and so are the two spellings of one
 *     field (ipv4_dst / nw_dst, ipv4_src / nw_src) when they name different addresses.
 *
 * Neither function branches on the switch's plane (the OVS and P4 strategies share
 * HttpRoutingStrategyBase, which forwards `match` as sent), so one cache covers both.
 */

#include <memory>
#include <shared_mutex>
#include <string>
#include <utility>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/routing_management/FlowJob.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

namespace
{

// Same construction as test_FlowTableCacheOptionalFields.cpp: dpid 1 must be a SWITCH vertex or
// the cache refuses to hold anything for it, and every test below would pass vacuously.
std::shared_ptr<DeviceConfigurationAndPowerManager>
makeCache()
{
    auto graph = std::make_shared<Graph>();
    const auto v = boost::add_vertex(*graph);
    (*graph)[v].vertexType = VertexType::SWITCH;
    (*graph)[v].dpid = 1;
    (*graph)[v].ip.push_back(utils::ipStringToUint32("192.168.123.11"));

    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    return std::make_shared<DeviceConfigurationAndPowerManager>(monitor, utils::TESTBED,
                                                                "localhost", nullptr);
}

json
batch(json ins, json mods, json dels)
{
    return json{{"install_flow_entries", std::move(ins)},
                {"modify_flow_entries", std::move(mods)},
                {"delete_flow_entries", std::move(dels)}};
}

json
arrayOf(std::initializer_list<json> rules)
{
    json a = json::array();
    for (const auto& r : rules)
    {
        a.push_back(r);
    }
    return a;
}

json
installs(std::initializer_list<json> rules)
{
    return batch(arrayOf(rules), json::array(), json::array());
}

json
modifies(std::initializer_list<json> rules)
{
    return batch(json::array(), arrayOf(rules), json::array());
}

json
deletes(std::initializer_list<json> rules)
{
    return batch(json::array(), json::array(), arrayOf(rules));
}

// One destination rule as the routing apps send it. Same priority throughout on purpose: the
// destination is then the only thing that tells two rows apart.
json
rule(const std::string& field, const json& dst, int port = 1)
{
    return json{{"dpid", 1},
                {"priority", 10},
                {"match", {{"eth_type", 2048}, {field, dst}}},
                {"actions", json::array({{{"type", "OUTPUT"}, {"port", port}}})}};
}

std::vector<json>
rowsOnSwitch1(DeviceConfigurationAndPowerManager& cache)
{
    std::vector<json> rows;
    for (const auto& sw : cache.getOpenFlowTables())
    {
        if (sw.value("dpid", 0ULL) != 1)
        {
            continue;
        }
        for (const auto& [_, flows] : sw.at("flows").items())
        {
            for (const auto& f : flows)
            {
                rows.push_back(f);
            }
        }
    }
    return rows;
}

// The destinations the served view holds on switch 1, as text, in row order.
std::vector<std::string>
destinations(DeviceConfigurationAndPowerManager& cache, const std::string& field)
{
    std::vector<std::string> out;
    for (const auto& f : rowsOnSwitch1(cache))
    {
        const json m = f.value("match", json::object());
        out.push_back(m.contains(field) ? m.at(field).dump() : "<none>");
    }
    return out;
}

int
outputPortOf(DeviceConfigurationAndPowerManager& cache, const std::string& field,
             const std::string& dst)
{
    for (const auto& f : rowsOnSwitch1(cache))
    {
        const json m = f.value("match", json::object());
        if (m.value(field, std::string{}) == dst)
        {
            return f.at("actions").at(0).value("port", -1);
        }
    }
    return -1;
}

std::string
q(const std::string& s)
{
    return json(s).dump();
}

// --- the cache, on both spellings ------------------------------------------------------------

class CidrDestinationCache : public ::testing::TestWithParam<std::string>
{
  protected:
    void SetUp() override { cache = makeCache(); }
    std::string field() const { return GetParam(); }

    std::shared_ptr<DeviceConfigurationAndPowerManager> cache;
};

TEST_P(CidrDestinationCache, ModifyingA24DoesNotThrow)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installs({rule(field(), "10.0.1.0/24")})));
    EXPECT_NO_THROW(cache->updateOpenFlowTables(modifies({rule(field(), "10.0.1.0/24", 2)})));
}

// The poisoned-switch shape: the /24 was installed fine, and from then on every modify or delete
// on that switch compared against the cached /24 row and threw -- after its own jobs were queued.
TEST_P(CidrDestinationCache, ACached24DoesNotBreakALaterDeleteOnTheSameSwitch)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule(field(), "10.0.1.0/24"), rule(field(), "10.0.0.7")})));
    EXPECT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.0.7")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("10.0.1.0/24")});
}

TEST_P(CidrDestinationCache, DeletingA24RemovesThatPrefixOnly)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installs(
        {rule(field(), "10.0.1.0"), rule(field(), "10.0.1.0/24"), rule(field(), "10.0.2.0/24")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.1.0/24")})));
    // Neither the /32 at the same address nor the other /24 is that rule.
    EXPECT_EQ(destinations(*cache, field()),
              (std::vector<std::string>{q("10.0.1.0"), q("10.0.2.0/24")}));
}

// The twin's record of a /24: after a modify, the row it serves still says 10.0.1.0/24 and
// carries the new action, and the /32 at the same address is untouched. Installed /32 first, so a
// key that cannot tell them apart modifies the wrong row.
TEST_P(CidrDestinationCache, TheViewRecordsTheModified24AsThePrefixItIs)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installs(
        {rule(field(), "10.0.1.0", 1), rule(field(), "10.0.1.0/24", 1),
         rule(field(), "10.0.2.0/24", 1)})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(modifies({rule(field(), "10.0.1.0/24", 3)})));

    EXPECT_EQ(destinations(*cache, field()),
              (std::vector<std::string>{q("10.0.1.0"), q("10.0.1.0/24"), q("10.0.2.0/24")}));
    EXPECT_EQ(outputPortOf(*cache, field(), "10.0.1.0/24"), 3);
    EXPECT_EQ(outputPortOf(*cache, field(), "10.0.1.0"), 1);
    EXPECT_EQ(outputPortOf(*cache, field(), "10.0.2.0/24"), 1);
}

// Ryu's flow stats spell a masked destination a.b.c.d/m.m.m.m. A delete sent as /24 is the same
// rule as the row a poll brought back.
TEST_P(CidrDestinationCache, TheMaskSpellingOfAPrefixIsTheSamePrefix)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule(field(), "10.0.1.0/255.255.255.0"), rule(field(), "10.0.2.0/24")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.1.0/24")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("10.0.2.0/24")});
}

TEST_P(CidrDestinationCache, ASlash32IsTheBareAddress)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule(field(), "10.0.0.1"), rule(field(), "10.0.0.2")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.0.1/32")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("10.0.0.2")});
}

// A poll is not checked by describeFlowEntryShapeProblem, so a value nobody can read may still
// reach the cache that way. It must neither throw nor match a real address.
TEST_P(CidrDestinationCache, AnUnreadableCachedValueNeitherThrowsNorMatchesAnythingElse)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule(field(), "not-an-address"), rule(field(), "10.0.0.2")})));
    EXPECT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.0.2")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("not-an-address")});

    // Kept as its own text: another unreadable value is not it, the same text is.
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "something-else")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("not-an-address")});
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "not-an-address")})));
    EXPECT_TRUE(destinations(*cache, field()).empty());
}

// The switch matches the network, not the bits a caller left set below the mask: OVS stores
// 10.0.1.5/24 as 10.0.1.0/24, and its poll comes back that way.
TEST_P(CidrDestinationCache, HostBitsBelowTheMaskDoNotMakeADifferentPrefix)
{
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule(field(), "10.0.1.0/255.255.255.0"), rule(field(), "10.0.2.0/24")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule(field(), "10.0.1.5/24")})));
    EXPECT_EQ(destinations(*cache, field()), std::vector<std::string>{q("10.0.2.0/24")});
}

INSTANTIATE_TEST_SUITE_P(BothSpellings, CidrDestinationCache,
                         ::testing::Values(std::string("ipv4_dst"), std::string("nw_dst")),
                         [](const auto& info) { return info.param; });

// --- a /32, as before ------------------------------------------------------------------------

TEST(CidrDestinationCache32, AnIpv4Dst32IsMatchedExactlyAsBefore)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule("ipv4_dst", "10.0.0.1"), rule("ipv4_dst", "10.0.0.2")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(modifies({rule("ipv4_dst", "10.0.0.1", 4)})));
    EXPECT_EQ(outputPortOf(*cache, "ipv4_dst", "10.0.0.1"), 4);
    EXPECT_EQ(outputPortOf(*cache, "ipv4_dst", "10.0.0.2"), 1);

    // The numeric form (host order) was accepted before and names the same rule.
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule("ipv4_dst", 167772161)})));
    EXPECT_EQ(destinations(*cache, "ipv4_dst"), std::vector<std::string>{q("10.0.0.2")});
}

TEST(CidrDestinationCache32, AnInstalled32IsServedAsSent)
{
    for (const std::string field : {"ipv4_dst", "nw_dst"})
    {
        auto cache = makeCache();
        ASSERT_NO_THROW(cache->updateOpenFlowTables(installs({rule(field, "10.0.0.1")})));
        EXPECT_EQ(destinations(*cache, field), std::vector<std::string>{q("10.0.0.1")}) << field;
    }
}

TEST(CidrDestinationCache32, AnNwDst32DeleteRemovesItsRow)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installs({rule("nw_dst", "10.0.0.1")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule("nw_dst", "10.0.0.1")})));
    EXPECT_TRUE(destinations(*cache, "nw_dst").empty());
}

// The source was read before (ipv4_src, as a /32) and still tells two rules apart.
TEST(CidrDestinationCache32, ASourceStillTellsTwoRulesApart)
{
    auto cache = makeCache();
    json a = rule("ipv4_dst", "10.0.0.9");
    json b = a;
    a["match"]["ipv4_src"] = "10.0.0.1";
    b["match"]["ipv4_src"] = "10.0.0.2";
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installs({a, b})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({a})));
    ASSERT_EQ(rowsOnSwitch1(*cache).size(), 1u);
    EXPECT_EQ(rowsOnSwitch1(*cache)[0].at("match").value("ipv4_src", std::string{}), "10.0.0.2");
}

// The one place a /32 changes: nw_dst used to be unread, so its key was 0.0.0.0 and a delete of
// one host's nw_dst rule removed every same-priority row without an ipv4_dst from the view.
TEST(CidrDestinationCache32, AnNwDst32DeleteNoLongerRemovesOtherHostsRows)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(
        installs({rule("nw_dst", "10.0.0.1"), rule("nw_dst", "10.0.0.2")})));
    ASSERT_NO_THROW(cache->updateOpenFlowTables(deletes({rule("nw_dst", "10.0.0.1")})));
    EXPECT_EQ(destinations(*cache, "nw_dst"), std::vector<std::string>{q("10.0.0.2")});
}

// --- refused before queueing -------------------------------------------------------------------

class CidrDestinationAdmission : public ::testing::TestWithParam<std::string>
{
};

const FlowOp kOps[] = {FlowOp::Install, FlowOp::Modify, FlowOp::Delete};

TEST_P(CidrDestinationAdmission, AMalformedAddressIsRefusedBeforeQueueing)
{
    const std::vector<json> bad = {"10.0.1.0/33", "10.0.1/24",  "10.0.1.0/",  "10.0.1.0/24/8",
                                   "10.0.1.0/2a", "10.0.1.0/-1", "10.0.1.0/255.255.255.256",
                                   "not-an-ip",  "",           "/24",        nullptr,
                                   true,          -1,           4294967296ULL, 1.5,
                                   // an embedded NUL: inet_pton would stop at it
                                   std::string("10.0.0.4\0x", 10), std::string("10.0.0.4\0", 9),
                                   std::string("10.0.1.0/255.255.255.0\0x", 24),
                                   std::string("10.0.1.0/24\0", 12)};
    for (const auto& v : bad)
    {
        for (const FlowOp op : kOps)
        {
            const std::string why = describeFlowEntryShapeProblem(rule(GetParam(), v), op);
            EXPECT_NE(why, "") << GetParam() << " = " << v.dump() << " was let through";
            EXPECT_NE(why.find(GetParam()), std::string::npos)
                << "the refusal does not name the field: " << why;
        }
    }
}

// The other half: what the planes accept must not be refused here.
TEST_P(CidrDestinationAdmission, AWellFormedAddressIsNotRefused)
{
    const std::vector<json> good = {"10.0.0.1",    "10.0.0.1/32",           "10.0.1.0/24",
                                    "10.0.0.0/8",  "10.0.1.0/255.255.255.0", "0.0.0.0/0",
                                    167772161,     0};
    for (const auto& v : good)
    {
        for (const FlowOp op : kOps)
        {
            EXPECT_EQ(describeFlowEntryShapeProblem(rule(GetParam(), v), op), "")
                << GetParam() << " = " << v.dump();
        }
    }
}

INSTANTIATE_TEST_SUITE_P(AllFourAddressFields, CidrDestinationAdmission,
                         ::testing::Values(std::string("ipv4_dst"), std::string("nw_dst"),
                                           std::string("ipv4_src"), std::string("nw_src")),
                         [](const auto& info) { return info.param; });

// --- the two spellings of one field must agree ----------------------------------------------------
// The cache reads ipv4_dst first and the P4 proxy nw_dst first, so a request with both and
// different values would mean one thing to each. [Co-developed with claude code -- Adam]

namespace
{

json
ruleWith(const std::string& first, const json& a, const std::string& second, const json& b)
{
    json r = rule(first, a);
    r["match"][second] = b;
    return r;
}

const char* const kPairs[][2] = {{"ipv4_dst", "nw_dst"}, {"ipv4_src", "nw_src"}};

} // namespace

TEST(CidrDestinationSpellings, DifferentAddressesInBothSpellingsAreRefused)
{
    const std::vector<std::pair<json, json>> different = {
        {"10.0.0.4", "10.0.0.5"},          {"10.0.1.0/24", "10.0.2.0/24"},
        {"10.0.0.4", "10.0.0.4/24"},       {"10.0.1.0/24", "10.0.1.0/25"},
        {"10.0.1.0/24", "10.0.1.0/255.255.254.0"}, {167772164, 167772165}};
    for (const auto& pair : kPairs)
    {
        for (const auto& [a, b] : different)
        {
            for (const FlowOp op : kOps)
            {
                const std::string why =
                    describeFlowEntryShapeProblem(ruleWith(pair[0], a, pair[1], b), op);
                EXPECT_NE(why, "") << pair[0] << "=" << a.dump() << " " << pair[1] << "="
                                   << b.dump() << " was let through";
                EXPECT_NE(why.find(pair[0]), std::string::npos) << why;
                EXPECT_NE(why.find(pair[1]), std::string::npos) << why;
                EXPECT_NE(why.find("different addresses"), std::string::npos) << why;
            }
        }
    }
}

TEST(CidrDestinationSpellings, TheSameAddressInBothSpellingsIsNotRefused)
{
    // Equal once normalised: host bits below the mask ignored, /32 the bare address, the mask
    // and length spellings of one prefix, a number and its dotted quad.
    const std::vector<std::pair<json, json>> same = {
        {"10.0.0.4", "10.0.0.4"},           {"10.0.0.4", "10.0.0.4/32"},
        {"10.0.1.0/24", "10.0.1.77/24"},    {"10.0.1.0/24", "10.0.1.0/255.255.255.0"},
        {167772164, "10.0.0.4"}};
    for (const auto& pair : kPairs)
    {
        for (const auto& [a, b] : same)
        {
            for (const FlowOp op : kOps)
            {
                EXPECT_EQ(describeFlowEntryShapeProblem(ruleWith(pair[0], a, pair[1], b), op), "")
                    << pair[0] << "=" << a.dump() << " " << pair[1] << "=" << b.dump();
                EXPECT_EQ(describeFlowEntryShapeProblem(ruleWith(pair[1], b, pair[0], a), op), "")
                    << pair[1] << "=" << b.dump() << " " << pair[0] << "=" << a.dump();
            }
        }
    }
}

// The destination and the source are separate fields: different addresses across them are not
// a conflict.
TEST(CidrDestinationSpellings, ADestinationAndASourceMayDiffer)
{
    json r = rule("ipv4_dst", "10.0.0.4");
    r["match"]["nw_src"] = "10.0.0.9";
    for (const FlowOp op : kOps)
    {
        EXPECT_EQ(describeFlowEntryShapeProblem(r, op), "");
    }
}

} // namespace
