/**
 * Regression tests for rules that have no output port.
 *
 * [Co-developed with claude code -- Adam]
 *
 * These exist because of a real crash. Loading Ryu's flow tables segfaulted the running
 * kernel: `ndtwin_kernel[694884]: segfault at 0`, resolved to Classifier.cpp's
 * `pr.effect.outputPorts.front()` inside a SPDLOG_LOGGER_TRACE. Ryu reports a table-miss
 * drop as `"actions": []`, which parses to an empty outputPorts, and front() on that is a
 * null dereference.
 *
 * Two things made it hide for a long time:
 *
 *  - The call sites are all TRACE. spdlog's macros pass their arguments as ordinary
 *    function arguments and filter by level *inside* log(), so the arguments are evaluated
 *    even at INFO -- a trace line that looks switched off still crashed the process.
 *  - Nothing ever reached them. The harness started Ryu without ryu.app.ofctl_rest, so
 *    GET /stats/flow/<dpid> returned a 404 HTML page, JSON parsing failed, and no rule was
 *    ever ingested. Fixing that one missing app is what exposed this.
 *
 * Exactly 1 of the 1300 flows in the live 10-switch topology triggers it, which is why the
 * fixture below is deliberately mostly-normal with a single drop rule in it.
 */

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/collection/Classifier.hpp"
#include "utils/Logger.hpp"

using json = nlohmann::json;
using ndtClassifier::Classifier;
using ndtClassifier::FlowKey;

/**
 * @brief Fixture that initialises the logger.
 *
 * Required, not incidental: the code under test logs, Logger::instance() is a null
 * shared_ptr until Logger::init runs, and spdlog dereferences it inside should_log -- so
 * these tests segfault in spdlog rather than in the code they are checking. Every suite
 * must do this for itself because ctest gives each test its own process (see the longer
 * note in test_SwitchKindDispatch.cpp). Logger::init is idempotent.
 *
 * Level `off` matters for what these tests prove: spdlog still *evaluates* the arguments of
 * a disabled TRACE call, because they are ordinary function arguments. So running with
 * logging off is exactly the production-like condition that used to crash.
 */
class ClassifierDropRule : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

namespace
{

/// One switch object in the shape Ryu's /stats/flow/<dpid> returns, as the kernel reassembles
/// it for updateFromQueriedTables: {"dpid": N, "flows": {"N": [ ... ]}}.
json
aSwitch(uint64_t dpid, json flows)
{
    return json{{"dpid", dpid}, {"flows", {{std::to_string(dpid), std::move(flows)}}}};
}

json
anIpv4Rule(const std::string& dst, int outPort, int priority = 10)
{
    return json{{"priority", priority},
                {"table_id", 0},
                {"match", {{"dl_type", 2048}, {"nw_dst", dst}}},
                {"actions", json::array({"OUTPUT:" + std::to_string(outPort)})}};
}

/// The table-miss drop, verbatim in the shape that crashed: no match, no actions.
json
aDropRule()
{
    return json{{"priority", 0},
                {"table_id", 0},
                {"match", json::object()},
                {"actions", json::array()}};
}

} // namespace

TEST_F(ClassifierDropRule, IngestingARuleWithNoActionsDoesNotCrash)
{
    // Reproduces the segfault directly: before the fix this died inside the TRACE call in
    // upsertRule, regardless of the configured log level.
    Classifier classifier;
    const json tables = json::array({aSwitch(1, json::array({aDropRule()}))});

    EXPECT_NO_FATAL_FAILURE(classifier.updateFromQueriedTables(tables));
    EXPECT_EQ(classifier.getRuleCount(1), 1u) << "the drop rule must still be stored";
}

TEST_F(ClassifierDropRule, ADropRuleAmongNormalOnesDoesNotCrash)
{
    // The live shape: 1 drop rule among many real ones. A guard that only handled the
    // all-empty case would pass the test above and still crash here.
    Classifier classifier;
    json flows = json::array();
    for (int i = 1; i <= 8; ++i)
    {
        flows.push_back(anIpv4Rule("10.0.0." + std::to_string(i), i + 2));
    }
    flows.push_back(aDropRule());

    const json tables = json::array({aSwitch(1, flows)});
    EXPECT_NO_FATAL_FAILURE(classifier.updateFromQueriedTables(tables));
    EXPECT_EQ(classifier.getRuleCount(1), 9u);
}

TEST_F(ClassifierDropRule, AnUnparseableOutputTargetAlsoYieldsNoOutputPort)
{
    // parseActionsArrayIntoEffect `continue`s on an OUTPUT target it cannot parse, which is
    // the other way outputPorts ends up empty -- so it must be equally safe.
    Classifier classifier;
    json rule = aDropRule();
    rule["actions"] = json::array({"OUTPUT:not_a_port"});

    const json tables = json::array({aSwitch(1, json::array({rule}))});
    EXPECT_NO_FATAL_FAILURE(classifier.updateFromQueriedTables(tables));
}

TEST_F(ClassifierDropRule, LookupOnATableWhoseOnlyRuleDropsDoesNotCrash)
{
    // lookup() has its own unguarded front() in a TRACE line (the "lookup for ..." message),
    // reached only when a rule actually matches. A drop rule with an empty match matches
    // everything, so this is the path to it.
    Classifier classifier;
    classifier.updateFromQueriedTables(json::array({aSwitch(1, json::array({aDropRule()}))}));

    FlowKey key{};
    key.ethType = 0x0800;
    key.ipProto = 6;
    key.ipv4Src = 0x0A000001;
    key.ipv4Dst = 0x0A000004;
    key.tpSrc = 1234;
    key.tpDst = 80;

    std::optional<ndtClassifier::RuleEffect> effect;
    ASSERT_NO_FATAL_FAILURE(effect = classifier.lookup(1, key));
    if (effect)
    {
        EXPECT_TRUE(effect->outputPorts.empty())
            << "a drop rule must not invent an output port";
    }
}

TEST_F(ClassifierDropRule, ANegativePriorityDoesNotCrashTheLookup)
{
    // lookupInTableNoLock starts with `best = nullptr` and `bestPriority = -1`, so a rule whose
    // priority is <= -1 never satisfies `cand->priority > bestPriority` and leaves `best` null
    // -- while the trace line that dereferenced it ran anyway, because spdlog evaluates its
    // arguments whatever the level. parseI32 accepts negative numbers, and -1 is already a
    // meaningful priority in this codebase (the non-strict delete sentinel), so a control plane
    // reporting "priority": -1 was enough to segfault the kernel.
    Classifier classifier;
    json rule = anIpv4Rule("10.0.0.4", 6);
    rule["priority"] = -1;

    classifier.updateFromQueriedTables(json::array({aSwitch(1, json::array({rule}))}));

    FlowKey key{};
    key.ethType = 0x0800;
    key.ipv4Dst = 0x0A000004;

    std::optional<ndtClassifier::RuleEffect> effect;
    ASSERT_NO_FATAL_FAILURE(effect = classifier.lookup(1, key));
}

TEST_F(ClassifierDropRule, TheHighestPriorityRuleStillWinsAcrossSubtables)
{
    // Guards the fix from being "simplified" by moving the trace back out, or by changing the
    // comparison: overlapping rules with different masks land in different subtables, and the
    // higher priority must still be chosen.
    Classifier classifier;
    json low = anIpv4Rule("10.0.0.4", 6, /*priority=*/10);
    json high = json{{"priority", 100},
                     {"table_id", 0},
                     {"match", {{"dl_type", 2048}, {"nw_dst", "10.0.0.4"}, {"nw_src", "10.0.0.1"}}},
                     {"actions", json::array({"OUTPUT:9"})}};

    classifier.updateFromQueriedTables(json::array({aSwitch(1, json::array({low, high}))}));

    FlowKey key{};
    key.ethType = 0x0800;
    key.ipv4Src = 0x0A000001;
    key.ipv4Dst = 0x0A000004;

    const auto effect = classifier.lookup(1, key);
    ASSERT_TRUE(effect.has_value());
    ASSERT_FALSE(effect->outputPorts.empty());
    EXPECT_EQ(effect->outputPorts.front(), 9u) << "the priority-100 rule must win";
}

TEST_F(ClassifierDropRule, ANormalRuleStillReportsItsOutputPort)
{
    // Guard against "fixing" the crash by dropping the port from the effect entirely.
    Classifier classifier;
    classifier.updateFromQueriedTables(
        json::array({aSwitch(1, json::array({anIpv4Rule("10.0.0.4", 6)}))}));

    FlowKey key{};
    key.ethType = 0x0800;
    key.ipv4Dst = 0x0A000004;

    const auto effect = classifier.lookup(1, key);
    ASSERT_TRUE(effect.has_value());
    ASSERT_FALSE(effect->outputPorts.empty());
    EXPECT_EQ(effect->outputPorts.front(), 6u);
}
