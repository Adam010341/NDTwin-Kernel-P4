/**
 * Tests for the bmv2 liveness policy.
 *
 * [Co-developed with claude code -- Adam]
 *
 * What this replaces was not a weak signal, it was no signal: `pingWorker` called `setVertexUp` for
 * every bmv2 switch once a second, unconditionally. A switch that had been killed reported healthy
 * again within one second, so the twin could never show a fault -- and since `is_up` gates the
 * power, CPU and temperature reports and `getAvgLinkUsage`, one fabricated field made several
 * others meaningless.
 *
 * The policy is deliberately the same three-state shape as `ovsLivenessFor`, because the mistake to
 * avoid is the same one and it has already been made once on the OVS side: conflating "the query
 * failed" with "the switch is dead" marked an entire fabric down from a single dropped `ovs-vsctl`
 * call. Here it would be worse -- there is one proxy for all ten switches, so one unreachable proxy
 * would take the whole fabric down at once. **Most of the tests below exist to pin that Unknown
 * stays Unknown.**
 *
 * The evidence itself is produced by the proxy (`GET /p4/switch_state`) and tested on that side in
 * p4_proxy/tests/test_switch_state.py. This file is only about the verdict, which is where the
 * damage would be done.
 */

#include <optional>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

using json = nlohmann::json;

namespace
{

/// p4LivenessFor is protected, like the OVS one, so the test reaches it through a subclass rather
/// than by widening the class's interface for testing.
class LivenessPolicy : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::kLldpFreshSeconds;
    using DeviceConfigurationAndPowerManager::kProbeStaleSeconds;
    using DeviceConfigurationAndPowerManager::OvsLiveness;
    using DeviceConfigurationAndPowerManager::p4LivenessFor;
};

using Liveness = LivenessPolicy::OvsLiveness;

/// One switch's entry, in the shape TopologyManager.switch_liveness() emits.
json
entry(const json& fields)
{
    json e = json{{"probe_ok", nullptr},
                  {"probe_detail", ""},
                  {"probe_age_s", nullptr},
                  {"last_packet_in_age_s", nullptr},
                  {"last_lldp_age_s", nullptr},
                  {"stream_alive", true},
                  {"grpc_addr", "127.0.0.1:50051"}};
    e.update(fields);
    return e;
}

/// A whole payload holding one switch.
json
payloadFor(uint64_t dpid, const json& fields)
{
    return json{{"status", "success"},
                {"probe_interval_s", 2.0},
                {"switches", {{std::to_string(dpid), entry(fields)}}}};
}

} // namespace

// --- Up: the switch answered.

TEST(P4LivenessTest, ASwitchThatAnsweredAProbeIsUp)
{
    // A round-tripped P4Runtime RPC is the only signal that proves a bmv2 process is serving.
    const auto p = payloadFor(1, {{"probe_ok", true}, {"probe_age_s", 0.4}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Up);
}

TEST(P4LivenessTest, AFreshSuccessfulProbeOutweighsSilenceOnTheDataPlane)
{
    // No beacon has ever arrived, but the switch answers RPCs. That is a forwarding problem, not a
    // dead switch, and reporting it down would be wrong: the twin would show a switch as absent
    // while its control plane is demonstrably alive.
    const auto p = payloadFor(3, {{"probe_ok", true},
                                  {"probe_age_s", 1.0},
                                  {"last_lldp_age_s", nullptr},
                                  {"last_packet_in_age_s", nullptr}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(3, p), Liveness::Up);
}

// --- Down: we asked, and nothing suggests otherwise.

TEST(P4LivenessTest, AFailedProbeWithNoRecentBeaconIsDown)
{
    // The case the whole change exists to make possible. Before this, it read Up.
    const auto p = payloadFor(1, {{"probe_ok", false},
                                  {"probe_detail", "UNAVAILABLE: failed to connect"},
                                  {"probe_age_s", 0.2},
                                  {"last_lldp_age_s", 60.0}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Down);
}

TEST(P4LivenessTest, AFailedProbeForASwitchThatWasNeverSeenForwardingIsDown)
{
    // A switch killed before it ever beaconed, or one that never came up at all. No evidence in its
    // favour, so the failed probe stands.
    const auto p = payloadFor(7, {{"probe_ok", false},
                                  {"probe_age_s", 0.5},
                                  {"last_lldp_age_s", nullptr}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(7, p), Liveness::Down);
}

// --- Unknown. These are the tests that matter most: every one of them is a case where reporting
//     Down would be a lie about the network, and the OVS side has already shipped that bug once.

TEST(P4LivenessTest, AnUnreachableProxyLeavesEveryStateUnknown)
{
    // THE case. nullopt means the proxy could not be reached, its reply was not 200, or the body did
    // not parse. There is one proxy for ten switches, so answering Down here would black out the
    // entire fabric on a single missed HTTP call -- exactly what a dropped `ovs-vsctl` did to the
    // OVS graph, only ten times at once.
    const std::optional<json> nothing;
    for (uint64_t dpid = 1; dpid <= 10; ++dpid)
    {
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(dpid, nothing), Liveness::Unknown)
            << "dpid " << dpid << " reported a verdict with no evidence";
    }
}

TEST(P4LivenessTest, ASwitchTheProxyHasNeverHeardOfIsUnknown)
{
    // A disagreement between the topology file and the proxy's switch table -- a configuration
    // problem, not a dead switch. Marking it down would send someone looking at the wrong thing.
    const auto p = payloadFor(1, {{"probe_ok", true}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(9, p), Liveness::Unknown);
}

TEST(P4LivenessTest, ASwitchNotYetProbedIsUnknownRatherThanDown)
{
    // probe_ok is null until the proxy's first probe of that switch completes. Treating null as
    // false would report the whole fabric dead for the first seconds of every single run, which is
    // both wrong and the kind of routine false alarm that trains people to ignore the field.
    const auto p = payloadFor(1, {{"probe_ok", nullptr}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Unknown);
}

TEST(P4LivenessTest, AStaleFailedProbeIsUnknownBecauseItDescribesTheProxyNotTheSwitch)
{
    // The proxy's poller has stopped running. Its last verdict is about a moment that has passed,
    // and a switch cannot be declared dead on the strength of a measurement nobody is taking.
    const auto p = payloadFor(1, {{"probe_ok", false},
                                  {"probe_age_s", LivenessPolicy::kProbeStaleSeconds + 1.0},
                                  {"last_lldp_age_s", 90.0}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Unknown);

    // And the boundary is not stale: exactly at the limit the result still counts.
    const auto atLimit = payloadFor(1, {{"probe_ok", false},
                                        {"probe_age_s", LivenessPolicy::kProbeStaleSeconds},
                                        {"last_lldp_age_s", 90.0}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, atLimit), Liveness::Down);
}

TEST(P4LivenessTest, ConflictingEvidenceIsUnknownRatherThanADecision)
{
    // The probe failed but the switch beaconed a second ago. bmv2 answers control-plane RPCs whether
    // or not its pipeline forwards, and a loaded switch can miss a 1.5 s RPC deadline while
    // forwarding perfectly well -- so this is a disagreement between two signals, not a verdict.
    // Acting on it either way would produce a switch that flaps between up and down under load.
    const auto p = payloadFor(1, {{"probe_ok", false},
                                  {"probe_age_s", 0.3},
                                  {"last_lldp_age_s", 1.0}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Unknown);
}

TEST(P4LivenessTest, TheBeaconFreshnessBoundaryIsWhereTheDocumentedThresholdSays)
{
    // The proxy beacons every 5 s, so the threshold allows one missed round. Pinned at the boundary
    // in both directions, because a threshold nothing tests is a threshold that can drift to zero
    // or to infinity without a single test noticing.
    const auto fresh = payloadFor(1, {{"probe_ok", false},
                                      {"probe_age_s", 0.1},
                                      {"last_lldp_age_s", LivenessPolicy::kLldpFreshSeconds}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, fresh), Liveness::Unknown)
        << "a beacon exactly at the limit still counts as corroboration";

    const auto stale =
        payloadFor(1, {{"probe_ok", false},
                       {"probe_age_s", 0.1},
                       {"last_lldp_age_s", LivenessPolicy::kLldpFreshSeconds + 0.001}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, stale), Liveness::Down)
        << "a beacon past the limit is not evidence and must not block the Down verdict";
}

// --- Malformed input. This payload comes over HTTP from another process, so every one of these is
//     reachable by that process being upgraded, misconfigured, or replaced by something else
//     listening on the port.

TEST(P4LivenessTest, APayloadWithoutASwitchesObjectIsUnknown)
{
    for (const json& bad : {json::object(),
                            json{{"status", "success"}},
                            json{{"switches", nullptr}},
                            json{{"switches", json::array()}},
                            json{{"switches", "not an object"}},
                            json::array(),
                            json(42)})
    {
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, bad), Liveness::Unknown)
            << "reached a verdict from " << bad.dump();
    }
}

TEST(P4LivenessTest, AnEntryOfTheWrongShapeIsUnknown)
{
    for (const json& bad : {json(nullptr), json(true), json("up"), json::array(), json(1)})
    {
        const json p = json{{"switches", {{"1", bad}}}};
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Unknown)
            << "entry " << bad.dump();
    }
}

TEST(P4LivenessTest, ANonBooleanProbeOkIsUnknownRatherThanTruthy)
{
    // "true", 1 and "ok" are all truthy in the language the proxy is written in. Accepting them
    // would let a shape change on that side silently restore the old always-up behaviour, which is
    // the exact bug being removed here.
    for (const json& bad : {json("true"), json(1), json(0), json("ok"), json::array()})
    {
        const auto p = payloadFor(1, {{"probe_ok", bad}});
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Unknown)
            << "probe_ok " << bad.dump() << " was not treated as missing";
    }
}

TEST(P4LivenessTest, MissingAgesDoNotPreventAVerdict)
{
    // probe_age_s and last_lldp_age_s are null when the proxy has nothing to report. Both absent
    // with a failed probe still has to reach Down, or a switch could never be reported dead until it
    // had first been seen alive.
    const auto p = payloadFor(1, {{"probe_ok", false}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, p), Liveness::Down);

    // Explicitly null is the same statement as absent, and must read the same way.
    const auto nulls = payloadFor(1, {{"probe_ok", false},
                                      {"probe_age_s", nullptr},
                                      {"last_lldp_age_s", nullptr}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, nulls), Liveness::Down);
}

TEST(P4LivenessTest, AMalformedAgeIsUnknownWhileAnAbsentOneIsNot)
{
    // This distinction was added because a test caught the code getting it wrong, and it is worth
    // stating plainly: "nothing to report" and "I cannot read what you sent" are different claims.
    //
    // A string where a number belongs means the two processes disagree about the schema -- a field
    // renamed or retyped on the proxy side. Answering Down on the strength of a payload we have just
    // failed to parse would black out the entire fabric on a proxy upgrade, which is the precise
    // failure this whole three-state policy exists to prevent. An absent field, by contrast, is a
    // normal statement the proxy makes constantly and must not veto a clear failed probe.
    for (const json& malformed : {json("ages"), json("12s"), json(""), json::array({1}),
                                  json::object(), json(true)})
    {
        const auto lldp = payloadFor(1, {{"probe_ok", false},
                                         {"probe_age_s", 0.2},
                                         {"last_lldp_age_s", malformed}});
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, lldp), Liveness::Unknown)
            << "last_lldp_age_s " << malformed.dump() << " was treated as no evidence rather than "
                                                         "as an unreadable payload";

        const auto probe = payloadFor(1, {{"probe_ok", false}, {"probe_age_s", malformed}});
        EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, probe), Liveness::Unknown)
            << "probe_age_s " << malformed.dump();
    }

    // The contrast, in one place, so the two cases cannot silently converge.
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(1, payloadFor(1, {{"probe_ok", false}})),
              Liveness::Down)
        << "an absent age must still allow Down";
}

TEST(P4LivenessTest, NeverThrowsOnAnythingTheProxyCouldSend)
{
    // It runs inside the 1 Hz ping loop, in a thread with no handler of its own: an exception here
    // ends the loop, and whatever that loop last did to the graph becomes permanent.
    //
    // Only the absence of a throw is asserted. The first version of this test also demanded Unknown
    // for every input, which was wrong -- one of them legitimately resolves to Down -- and bundling
    // the two claims made a passing test that would have been read as covering both. Verdicts are
    // asserted in the tests above, where each input has one right answer for a stated reason.
    const std::vector<json> nasty = {json(nullptr),
                                     json::object(),
                                     json::array({1, 2, 3}),
                                     json(42),
                                     json("switches"),
                                     json{{"switches", {{"1", {{"probe_age_s", "soon"}}}}}},
                                     json{{"switches", {{"1", {{"probe_ok", false},
                                                               {"last_lldp_age_s", "ages"}}}}}},
                                     json{{"switches", {{"", json::object()}}}},
                                     json{{"switches", {{"-1", json::object()}}}},
                                     json{{"switches", {{"1", {{"probe_ok", false},
                                                               {"probe_age_s", 1e308}}}}}}};
    for (const json& bad : nasty)
    {
        EXPECT_NO_THROW(LivenessPolicy::p4LivenessFor(1, bad)) << "threw on " << bad.dump();
    }
}

TEST(P4LivenessTest, ADpidBeyondThirtyTwoBitsIsLookedUpCorrectly)
{
    // dpids are uint64_t and the JSON key is a decimal string, so a narrowing conversion anywhere in
    // the lookup would silently read another switch's entry -- or none.
    const uint64_t big = 0x00'00'FF'FF'FF'FF'FF'FFULL;
    const auto p = payloadFor(big, {{"probe_ok", true}, {"probe_age_s", 0.1}});
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(big, p), Liveness::Up);
    EXPECT_EQ(LivenessPolicy::p4LivenessFor(big - 1, p), Liveness::Unknown);
}
