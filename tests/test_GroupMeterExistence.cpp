/**
 * doc/KNOWN-ISSUES.md F-13 -- the six group/meter endpoints.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Two defects, one of them the reason the other was invisible.
 *
 *  1. A modify or delete naming a group or meter that does not exist answered
 *     200 {"status":"Group entry deleted"} and changed nothing. The 200 was relayed rather than
 *     invented -- Ryu's ofctl_rest builds an OFPGroupMod, calls send_msg with no barrier and no
 *     reply awaited (ryu/lib/ofctl_v1_3.py:1151), then answers 200 with an empty body
 *     (ryu/app/ofctl_rest.py:275-277) before the switch has seen the message. The switch's own
 *     OFPGMFC_UNKNOWN_GROUP comes back asynchronously and is correlated to nothing. For DELETE
 *     there is not even that: OpenFlow 1.3 makes deleting a group that is not there a silent
 *     no-op at the switch, so no amount of listening would find it. Asking first is the only
 *     way to tell "deleted" from "there was nothing to delete".
 *
 *     The row says "modify/delete". It understates the defect: ADD on an id that already exists
 *     is wrong too, and worse -- OFPGMFC_GROUP_EXISTS keeps the entry that is already there, so
 *     the caller is told 200 "installed" while the buckets forwarding its traffic belong to
 *     somebody else.
 *
 *  2. The six endpoints had routes registered in the contract suite
 *     (tools/contract_test/components.py:40-45) and no assertion anywhere about what they
 *     answer. That is why (1) could sit behind a green suite: a registered route proves the
 *     handler is reachable, not that its reply means anything.
 *
 * So this file asserts both halves, and it asserts them at both levels: the strategy decides
 * the outcome, and HttpSession is what a caller actually meets.
 *
 * The refusals are the easy half. Two things here exist to stop a guard that just refuses
 * everything from passing:
 *
 *   * every refusal case has an accept twin -- the entry IS there, the mod goes through, and
 *     the POST is asserted to have been issued;
 *   * an existence check that cannot be answered must NOT become a 404. A controller that has
 *     gone away would otherwise make the kernel report every group in the fabric as
 *     nonexistent, which is the instrument publishing its own failure as a finding. Those are
 *     the Unknown cases, and they are the ones worth keeping if anything here is ever trimmed.
 */

#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "ndt_core/routing_management/OpResult.hpp"
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

/**
 * @brief Drives HttpSession::buildResponse() with a FlowRoutingManager the test scripts.
 *
 * Global scope to match `friend class HttpSessionGroupMeterTestPeer`.
 */
class HttpSessionGroupMeterTestPeer
{
  public:
    HttpSessionGroupMeterTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                                  std::shared_ptr<FlowRoutingManager> routing)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  nullptr,        // EventBus
                                                  utils::MININET, // mode
                                                  nullptr,        // FlowLinkUsageCollector
                                                  std::move(routing),
                                                  nullptr, // DeviceConfig...PowerManager
                                                  nullptr, // ApplicationManager
                                                  nullptr, // SimulationRequestManager
                                                  nullptr, // IntentTranslator
                                                  nullptr, // HistoricalDataManager
                                                  nullptr, // Controller
                                                  nullptr))                       // LockManager
    {
    }

    const http::response<http::string_body>&
    send(const std::string& target, const std::string& body)
    {
        m_session->m_req = {};
        m_session->m_req.version(11);
        m_session->m_req.method(http::verb::post);
        m_session->m_req.target(target);
        m_session->m_req.body() = body;
        m_session->m_req.prepare_payload();

        m_response = m_session->buildResponse();
        return *m_response;
    }

  private:
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

// =====================================================================================
// Level 1: the strategy, with a scripted controller
// =====================================================================================

/**
 * Records every curl command and answers GET and POST separately.
 *
 * The two have to be separable because the whole fix is "read, then decide, then maybe write":
 * a recorder with one canned reply could not express "the group is not there" without also
 * saying it about the mod.
 */
class ScriptedRyu : public OpenFlowRoutingStrategy
{
  public:
    ScriptedRyu() : OpenFlowRoutingStrategy("localhost:8080") {}

    /// Reply to the existence check. Body then newline then status, as curl -w produces.
    std::string getReply = "\n200";
    /// Reply to the mod itself. Ryu's real answer here is an empty 200.
    std::string postReply = "\n200";

    /**
     * What the stats query answers AFTER a mod has been forwarded, when that differs.
     *
     * [Co-developed with claude code -- Adam] Finding #1.
     * Empty means "the same as before", and that is not a shortcut -- it is the finding.
     * A fake whose only setting is one fixed stats reply cannot express the difference
     * between a switch that carried the delete out and one that ignored it, so a test written
     * against it asserts "deleted" in both worlds. That is precisely what the delete path did
     * on ovs4, and precisely why the accept twin below passed while the endpoint was a no-op:
     * the instrument could not represent the defect. Setting this makes the fake a switch with
     * state rather than a constant.
     */
    std::string getReplyAfterPost;

    std::vector<std::string> commands;

    /// How many times the guard paused to re-read an entry. Asserted so the bounded retry
    /// cannot silently become an unbounded wait, or vanish.
    int pauses = 0;

    bool issued(const std::string& fragment) const
    {
        for (const auto& c : commands)
        {
            if (c.find(fragment) != std::string::npos)
            {
                return true;
            }
        }
        return false;
    }

    /// Index of the first command containing @p fragment, or -1.
    int indexOf(const std::string& fragment) const
    {
        for (size_t i = 0; i < commands.size(); ++i)
        {
            if (commands[i].find(fragment) != std::string::npos)
            {
                return static_cast<int>(i);
            }
        }
        return -1;
    }

  protected:
    /// [Co-developed with claude code -- Adam]
    /// The seam is executeArgv() since doc/KNOWN-ISSUES.md B-2b removed the shell-string one.
    /// `commands` keeps holding a flat string so the request-shape assertions above read
    /// unchanged, but note what it now is: utils::describeArgv's rendering of the vector, for
    /// humans -- not a command line. Nothing here is ever handed back to a shell.
    utils::CommandOutcome executeArgv(const std::vector<std::string>& argv) override
    {
        commands.push_back(utils::describeArgv(argv));
        const bool isGet = commands.back().find("-X GET") != std::string::npos;
        if (!isGet)
        {
            m_posted = true;
            return utils::CommandOutcome{postReply, true, 0};
        }
        const bool afterPost = m_posted && !getReplyAfterPost.empty();
        return utils::CommandOutcome{afterPost ? getReplyAfterPost : getReply, true, 0};
    }

    /// [Co-developed with claude code -- Adam] Finding #1. Counted, not slept: the guard's
    /// decisions are what these tests are about, and real milliseconds would only make the
    /// suite slower without making any assertion stronger.
    void pauseBeforeReVerify() override { ++pauses; }

  private:
    bool m_posted = false;
};

/// A groupdesc reply in Ryu's shape: {"<dpid>": [ {group_id, type, buckets}, ... ]}.
std::string
groupDescReply(uint64_t dpid, const std::vector<int>& groupIds)
{
    json entries = json::array();
    for (int id : groupIds)
    {
        entries.push_back(json{{"group_id", id}, {"type", "ALL"}, {"buckets", json::array()}});
    }
    return json{{std::to_string(dpid), entries}}.dump() + "\n200";
}

/// A meterconfig reply in Ryu's shape.
std::string
meterConfigReply(uint64_t dpid, const std::vector<int>& meterIds)
{
    json entries = json::array();
    for (int id : meterIds)
    {
        entries.push_back(
            json{{"meter_id", id}, {"flags", json::array({"KBPS"})}, {"bands", json::array()}});
    }
    return json{{std::to_string(dpid), entries}}.dump() + "\n200";
}

json
groupPayload(int groupId)
{
    return json{{"dpid", 1},
                {"type", "ALL"},
                {"group_id", groupId},
                {"buckets", json::array({json{{"actions", json::array()}}})}};
}

json
meterPayload(int meterId)
{
    return json{{"dpid", 1},
                {"meter_id", meterId},
                {"flags", "KBPS"},
                {"bands", json::array({json{{"type", "DROP"}, {"rate", 1000}}})}};
}

class GroupMeterFixture : public ::testing::Test
{
  protected:
    // Logger::instance() is a null shared_ptr until init runs, and the code under test logs on
    // every refusal path -- so without this the refusal tests segfault when this suite runs
    // alone. Idempotent; see the longer note in test_SwitchKindDispatch.cpp.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

} // namespace

// --- the defect, at the strategy ---------------------------------------------------------------

/**
 * The F-13 headline. RED before the fix at HttpRoutingStrategyBase.cpp's old
 * `deleteAGroupEntry`, whose entire body was `return post("/stats/groupentry/delete", j, ...)`:
 * with no GET the empty 200 was a success and this asserted 404 against ok == true.
 */
TEST_F(GroupMeterFixture, DeletingAGroupThatIsNotThereIsRefusedRatherThanReportedDeleted)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {5, 6}); // 9 is not among them

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_FALSE(r.ok) << "answered success for a group that is not on the switch";
    EXPECT_EQ(r.httpStatus, 404) << r.message;
    EXPECT_EQ(r.outcome, "no_such_group");
    EXPECT_FALSE(ryu.issued("/stats/groupentry/delete"))
        << "the mod was forwarded anyway; the status line was the only thing that changed";
}

TEST_F(GroupMeterFixture, ModifyingAGroupThatIsNotThereIsRefusedRatherThanReportedModified)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {5});

    const OpResult r = ryu.modifyAGroupEntry(groupPayload(9));

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 404) << r.message;
    EXPECT_EQ(r.outcome, "no_such_group");
    EXPECT_FALSE(ryu.issued("/stats/groupentry/modify"));
}

/**
 * The case the F-13 row does not mention, and the dangerous one: the switch answers
 * OFPGMFC_GROUP_EXISTS and KEEPS THE ENTRY IT ALREADY HAS, so a 200 here tells the caller it
 * owns buckets that are somebody else's.
 */
TEST_F(GroupMeterFixture, AddingAGroupThatAlreadyExistsIsAConflictNotAnInstall)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {7});

    const OpResult r = ryu.installAGroupEntry(groupPayload(7));

    EXPECT_FALSE(r.ok) << "reported an install that the switch would reject";
    EXPECT_EQ(r.httpStatus, 409) << r.message;
    EXPECT_EQ(r.outcome, "no_change_group_exists");
    EXPECT_FALSE(ryu.issued("/stats/groupentry/add"));
}

TEST_F(GroupMeterFixture, DeletingAMeterThatIsNotThereIsRefused)
{
    ScriptedRyu ryu;
    ryu.getReply = meterConfigReply(1, {});

    const OpResult r = ryu.deleteAMeterEntry(meterPayload(3));

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 404) << r.message;
    EXPECT_EQ(r.outcome, "no_such_meter");
    EXPECT_FALSE(ryu.issued("/stats/meterentry/delete"));
}

TEST_F(GroupMeterFixture, ModifyingAMeterThatIsNotThereIsRefused)
{
    ScriptedRyu ryu;
    ryu.getReply = meterConfigReply(1, {});

    const OpResult r = ryu.modifyAMeterEntry(meterPayload(3));

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 404) << r.message;
    EXPECT_EQ(r.outcome, "no_such_meter");
    EXPECT_FALSE(ryu.issued("/stats/meterentry/modify"));
}

TEST_F(GroupMeterFixture, AddingAMeterThatAlreadyExistsIsAConflict)
{
    ScriptedRyu ryu;
    ryu.getReply = meterConfigReply(1, {3});

    const OpResult r = ryu.installAMeterEntry(meterPayload(3));

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 409) << r.message;
    EXPECT_EQ(r.outcome, "no_change_meter_exists");
    EXPECT_FALSE(ryu.issued("/stats/meterentry/add"));
}

// --- the accept twins ---------------------------------------------------------------------------
//
// Without these, "refuse everything" passes every test above.

TEST_F(GroupMeterFixture, DeletingAGroupThatIsThereGoesThroughAndSaysItWasDeleted)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    // [Co-developed with claude code -- Adam] Finding #1. This line is the whole difference
    // between a switch and a constant: the group is there when asked before, and gone when
    // asked after. Until it existed, this test passed against an endpoint that deleted nothing.
    ryu.getReplyAfterPost = groupDescReply(1, {});

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "deleted");
    EXPECT_TRUE(ryu.issued("/stats/groupentry/delete")) << "the mod was never forwarded";
}

TEST_F(GroupMeterFixture, ModifyingAGroupThatIsThereGoesThrough)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});

    const OpResult r = ryu.modifyAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "modified");
    EXPECT_TRUE(ryu.issued("/stats/groupentry/modify"));
}

TEST_F(GroupMeterFixture, AddingAGroupThatIsNotThereGoesThrough)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {5});

    const OpResult r = ryu.installAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "installed");
    EXPECT_TRUE(ryu.issued("/stats/groupentry/add"));
}

TEST_F(GroupMeterFixture, TheMeterAcceptPathsGoThrough)
{
    {
        ScriptedRyu ryu;
        ryu.getReply = meterConfigReply(1, {3});
        ryu.getReplyAfterPost = meterConfigReply(1, {}); // the switch really removed it
        const OpResult r = ryu.deleteAMeterEntry(meterPayload(3));
        EXPECT_TRUE(r.ok) << r.message;
        EXPECT_EQ(r.outcome, "deleted");
        EXPECT_TRUE(ryu.issued("/stats/meterentry/delete"));
    }
    {
        ScriptedRyu ryu;
        ryu.getReply = meterConfigReply(1, {3});
        const OpResult r = ryu.modifyAMeterEntry(meterPayload(3));
        EXPECT_TRUE(r.ok) << r.message;
        EXPECT_EQ(r.outcome, "modified");
        EXPECT_TRUE(ryu.issued("/stats/meterentry/modify"));
    }
    {
        ScriptedRyu ryu;
        ryu.getReply = meterConfigReply(1, {});
        const OpResult r = ryu.installAMeterEntry(meterPayload(3));
        EXPECT_TRUE(r.ok) << r.message;
        EXPECT_EQ(r.outcome, "installed");
        EXPECT_TRUE(ryu.issued("/stats/meterentry/add"));
    }
}

// --- finding #1: a delete is claimed only after the switch is asked ------------------------------
//
// [Co-developed with claude code -- Adam]
// Measured on ovs4 2026-09-03 (doc/audit/2026-09-03_night-rounds/round1-ovs/
// 21_delete_group_meter_says_deleted_but_persists.log): /ndt/delete_group_entry answered
// 200 {"outcome":"deleted"} five times while all five groups stayed on the switch with
// duration_sec still climbing, re-installing the id answered 409 "already exists" -- so the id
// was gone for the life of the switch -- and the kernel log held not one line about any of it.
// The pre-check from F-13 could not catch this: it establishes that the entry was there BEFORE,
// which is the precondition for deleting it, not evidence that it left.

TEST_F(GroupMeterFixture, AGroupTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted)
{
    ScriptedRyu ryu;
    // Present before AND after: the switch acknowledged the mod and did not carry it out.
    ryu.getReply = groupDescReply(1, {9});

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_TRUE(ryu.issued("/stats/groupentry/delete")) << "the mod was never forwarded";
    EXPECT_FALSE(r.ok) << "reported a deletion the switch did not perform";
    EXPECT_GE(r.httpStatus, 400) << "a no-op must not answer 2xx: " << r.message;
    EXPECT_EQ(r.outcome, "still_present");
    EXPECT_NE(r.message.find("still on the switch"), std::string::npos)
        << "the reason must name what is wrong, not just fail: " << r.message;
}

TEST_F(GroupMeterFixture, AMeterTheSwitchStillHasAfterTheDeleteIsNotReportedAsDeleted)
{
    ScriptedRyu ryu;
    ryu.getReply = meterConfigReply(1, {3});

    const OpResult r = ryu.deleteAMeterEntry(meterPayload(3));

    EXPECT_TRUE(ryu.issued("/stats/meterentry/delete"));
    EXPECT_FALSE(r.ok) << "reported a deletion the switch did not perform";
    EXPECT_GE(r.httpStatus, 400) << r.message;
    EXPECT_EQ(r.outcome, "still_present");
}

/**
 * The id leak, stated as the caller experiences it.
 *
 * A verified delete has to make the id usable again -- that is what "deleted" is FOR. On ovs4
 * the reply said deleted and the next install of the same id answered 409, so the 200 cost the
 * caller an id rather than returning one.
 */
TEST_F(GroupMeterFixture, AGroupIdCanBeInstalledAgainAfterAVerifiedDelete)
{
    ScriptedRyu del;
    del.getReply = groupDescReply(1, {9});
    del.getReplyAfterPost = groupDescReply(1, {});

    const OpResult deleted = del.deleteAGroupEntry(groupPayload(9));
    ASSERT_TRUE(deleted.ok) << deleted.message;
    ASSERT_EQ(deleted.outcome, "deleted");

    // A fresh strategy against the switch state the delete left behind: 9 is gone.
    ScriptedRyu add;
    add.getReply = groupDescReply(1, {});

    const OpResult reinstalled = add.installAGroupEntry(groupPayload(9));

    EXPECT_TRUE(reinstalled.ok) << "the id did not come back after a successful delete: "
                                << reinstalled.message;
    EXPECT_EQ(reinstalled.outcome, "installed");
    EXPECT_TRUE(add.issued("/stats/groupentry/add"));
}

/**
 * What is actually put on the wire for a delete.
 *
 * OpenFlow 1.3 gives ofp_group_mod's bucket list no meaning for OFPGC_DELETE, and Ryu packs
 * whatever `buckets` the body carries into the message it builds (ofctl_v1_3.py:1134-1150).
 * groupPayload() is an install-shaped body -- type, buckets and all -- because that is what a
 * caller who reuses its install body sends, and the API doc's own delete example is the
 * addressing pair alone. Forwarding the definition with the delete is the request-side half of
 * this finding, and it is invisible in the response either way, so it is asserted here.
 */
TEST_F(GroupMeterFixture, ADeleteNamesTheEntryAndDoesNotCarryADefinitionOfIt)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    ryu.getReplyAfterPost = groupDescReply(1, {});

    ASSERT_TRUE(ryu.deleteAGroupEntry(groupPayload(9)).ok);

    const int at = ryu.indexOf("/stats/groupentry/delete");
    ASSERT_GE(at, 0) << "the delete was never forwarded";
    const std::string& sent = ryu.commands[static_cast<size_t>(at)];

    EXPECT_EQ(sent.find("buckets"), std::string::npos)
        << "the delete carried a bucket list, which OFPGC_DELETE gives no meaning and a switch "
           "may reject asynchronously -- after Ryu has already answered 200: "
        << sent;
    EXPECT_NE(sent.find("\"group_id\":9"), std::string::npos)
        << "the delete must still name the entry it removes: " << sent;
    EXPECT_NE(sent.find("\"dpid\":1"), std::string::npos) << sent;
}

/**
 * The Unknown rule, applied to the new check. A read-back that could not be performed is not
 * evidence that the delete failed. Inventing a 502 out of it would be the mirror image of the
 * defect -- the kernel publishing its own reach as a finding about the fabric -- and it is the
 * failure mode a guard like this one is most likely to grow.
 */
TEST_F(GroupMeterFixture, ADeleteThatCannotBeReadBackIsUnverifiedRatherThanFailed)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});    // present before: the delete is allowed to proceed
    ryu.getReplyAfterPost = "\n000";          // and then the controller stops answering

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << "an unanswerable read-back was reported as a failed delete: "
                      << r.message;
    EXPECT_EQ(r.outcome, "unverified")
        << "a caller must be able to tell a verified delete from an unverifiable one";
}

/**
 * The re-check is bounded and it is a re-check.
 *
 * Ryu answers 200 before the switch has seen the message, so one immediate read is not enough
 * to call a delete failed; but "keep asking" would wedge a FlowDispatcher worker on a switch
 * that really did refuse. Both halves are asserted here because a mutation to either -- one
 * attempt, or unbounded ones -- changes behaviour that no other test in this file can see.
 */
TEST_F(GroupMeterFixture, TheDeleteReCheckIsRetriedAndBounded)
{
    ScriptedRyu persistent;
    persistent.getReply = groupDescReply(1, {9});
    ASSERT_FALSE(persistent.deleteAGroupEntry(groupPayload(9)).ok);
    EXPECT_GT(persistent.pauses, 0) << "the switch was asked only once, so a delete still in "
                                       "flight would be reported as a failure";
    EXPECT_LE(persistent.pauses, 8) << "the re-check is not bounded";

    // And when the switch did carry it out, the answer is taken the first time: no delay is
    // paid on the path that every successful delete takes.
    ScriptedRyu prompt;
    prompt.getReply = groupDescReply(1, {9});
    prompt.getReplyAfterPost = groupDescReply(1, {});
    ASSERT_TRUE(prompt.deleteAGroupEntry(groupPayload(9)).ok);
    EXPECT_EQ(prompt.pauses, 0) << "a delete that landed still waited";
}

// --- Unknown must not become Absent -------------------------------------------------------------
//
// These are the tests worth keeping if any are ever dropped. A 404 asserts something about the
// switch; a failed query asserts something about the kernel's own reach, and confusing the two
// is how an instrument publishes its own failure as a finding.

TEST_F(GroupMeterFixture, AnUnreachableControllerDoesNotTurnEveryGroupIntoA404)
{
    ScriptedRyu ryu;
    ryu.getReply = "\n000"; // curl reports 000 when it cannot connect at all
    ryu.postReply = "\n200";

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << "a failed existence check was reported as 'the group is not there': "
                      << r.message;
    EXPECT_EQ(r.outcome, "unverified")
        << "the caller must be able to tell a checked success from an unchecked one";
    EXPECT_TRUE(ryu.issued("/stats/groupentry/delete"))
        << "the request was dropped because the kernel could not look first";
}

TEST_F(GroupMeterFixture, AStatsReplyInAnUnexpectedShapeIsUnknownNotAbsent)
{
    ScriptedRyu ryu;
    // 200, valid JSON, and nothing the reader recognises -- e.g. a proxy in front of Ryu.
    ryu.getReply = R"({"detail":"forbidden"})"
                   "\n200";

    const OpResult r = ryu.modifyAGroupEntry(groupPayload(9));

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "unverified");
    EXPECT_TRUE(ryu.issued("/stats/groupentry/modify"));
}

TEST_F(GroupMeterFixture, AnUnparseableStatsReplyIsUnknownNotAbsent)
{
    ScriptedRyu ryu;
    ryu.getReply = "<html>404 not found</html>\n200"; // ofctl_rest not loaded: a known failure here

    const OpResult r = ryu.deleteAMeterEntry(meterPayload(3));

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "unverified");
    EXPECT_TRUE(ryu.issued("/stats/meterentry/delete"));
}

/**
 * A group_id Ryu accepts as a name ("ALL") is not something the kernel can look up, so the
 * answer is Unknown -- not Absent, and not a refusal. Ryu's ofp_group_from_user resolves those;
 * this file does not, and must not pretend to.
 */
TEST_F(GroupMeterFixture, ANonNumericGroupIdIsUnknownRatherThanRefused)
{
    ScriptedRyu ryu;
    json payload = groupPayload(0);
    payload["group_id"] = "ALL";

    const OpResult r = ryu.deleteAGroupEntry(payload);

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_EQ(r.outcome, "unverified");
    EXPECT_FALSE(ryu.issued("-X GET")) << "an id it cannot read must not be looked up as 0";
    EXPECT_TRUE(ryu.issued("/stats/groupentry/delete"));
}

// --- what the check actually asks for -----------------------------------------------------------

/**
 * ⚠️ /stats/groupdesc/<dpid>/<group_id> IS a registered Ryu route and it IGNORES the group_id on
 * OpenFlow 1.3 -- ofctl_rest.py:400-401 forwards it only from OF1.5 on, and
 * ofctl_v1_3.get_group_desc (:968) has no id parameter. Asking for the filtered URL would return
 * the whole table and every id would look present. The group query therefore asks for the list
 * and filters in the kernel; the meter query may filter server-side because get_meter_config
 * does take the id (:796).
 */
TEST_F(GroupMeterFixture, TheGroupCheckAsksForTheWholeListBecauseRyuIgnoresTheIdOnOf13)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_TRUE(ryu.issued("/stats/groupdesc/1")) << "no existence check was issued at all";
    EXPECT_FALSE(ryu.issued("/stats/groupdesc/1/9"))
        << "asked Ryu to filter by group_id; on OF1.3 it ignores that and answers the whole "
           "table, so every id would read as present";
}

TEST_F(GroupMeterFixture, TheMeterCheckNamesTheMeterItIsAskingAbout)
{
    ScriptedRyu ryu;
    ryu.getReply = meterConfigReply(1, {3});
    ryu.deleteAMeterEntry(meterPayload(3));

    EXPECT_TRUE(ryu.issued("/stats/meterconfig/1/3")) << "no existence check was issued";
}

/// Order matters: a check after the mod would be measuring the state the mod produced.
TEST_F(GroupMeterFixture, TheCheckHappensBeforeTheModNotAfterIt)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    ryu.deleteAGroupEntry(groupPayload(9));

    const int check = ryu.indexOf("/stats/groupdesc/1");
    const int mod = ryu.indexOf("/stats/groupentry/delete");
    ASSERT_GE(check, 0);
    ASSERT_GE(mod, 0);
    EXPECT_LT(check, mod) << "the existence check ran after the mod, so it measured the mod";
}

/// Every request the guard makes must still be bounded and still ask for the status code.
TEST_F(GroupMeterFixture, TheExistenceCheckAsksForTheStatusCodeAndBoundsItsTime)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    ryu.deleteAGroupEntry(groupPayload(9));

    const int check = ryu.indexOf("-X GET");
    ASSERT_GE(check, 0);
    EXPECT_NE(ryu.commands[check].find("%{http_code}"), std::string::npos) << ryu.commands[check];
    EXPECT_NE(ryu.commands[check].find("--max-time"), std::string::npos) << ryu.commands[check];
}

/// A controller error on the mod itself is still relayed, not overwritten by the guard.
TEST_F(GroupMeterFixture, AControllerRefusalOfTheModIsStillReported)
{
    ScriptedRyu ryu;
    ryu.getReply = groupDescReply(1, {9});
    ryu.postReply = "bad request\n400";

    const OpResult r = ryu.deleteAGroupEntry(groupPayload(9));

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 400) << r.message;
    EXPECT_TRUE(r.outcome.empty()) << "a relayed controller failure must not be relabelled";
}

// =====================================================================================
// Level 2: the six /ndt/ endpoints, and the shape of what they answer
// =====================================================================================
//
// tools/contract_test/components.py:40-45 registers all six routes and nothing anywhere asserts
// what comes back. These are those assertions. They are deliberately per-endpoint rather than
// one loop over six names: the failure they have to catch is a route wired to the wrong handler,
// and a loop that checks "some group sentence came back" cannot see install answering delete's.

namespace
{

/// A FlowRoutingManager whose six group/meter results the test chooses.
class ScriptedGroupMeterManager : public FlowRoutingManager
{
  public:
    ScriptedGroupMeterManager() : FlowRoutingManager(nullptr, nullptr, nullptr) {}

    OpResult next = OpResult::success(200);
    std::string lastCalled;

    OpResult installAGroupEntry(const json&) override { return record("install_group"); }
    OpResult deleteAGroupEntry(const json&) override { return record("delete_group"); }
    OpResult modifyAGroupEntry(const json&) override { return record("modify_group"); }
    OpResult installAMeterEntry(const json&) override { return record("install_meter"); }
    OpResult deleteAMeterEntry(const json&) override { return record("delete_meter"); }
    OpResult modifyAMeterEntry(const json&) override { return record("modify_meter"); }

  private:
    OpResult record(const char* which)
    {
        lastCalled = which;
        return next;
    }
};

class GroupMeterEndpointTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        m_routing = std::make_shared<ScriptedGroupMeterManager>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                             std::make_shared<std::shared_mutex>(),
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_peer = std::make_unique<HttpSessionGroupMeterTestPeer>(m_monitor, m_routing);
    }

    std::shared_ptr<ScriptedGroupMeterManager> m_routing;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::unique_ptr<HttpSessionGroupMeterTestPeer> m_peer;
};

const char* const kGroupBody = R"({"dpid":1,"group_id":9,"type":"ALL","buckets":[]})";
const char* const kMeterBody = R"({"dpid":1,"meter_id":3,"flags":"KBPS","bands":[]})";

} // namespace

// --- the refusal shape, for each of the six -----------------------------------------------------

/**
 * RED on today's code at HttpSession.cpp's `respondToOpResult`, whose failure body was a fixed
 * three-key object -- there was no `outcome` key to find, so `body.contains("outcome")` fails
 * even once the strategy has an opinion to report.
 */
TEST_F(GroupMeterEndpointTest, DeleteGroupRelaysA404WithAnOutcomeNamingWhatWasNotFound)
{
    m_routing->next = OpResult::failure(404, "no such group 9 on dpid 1; nothing was deleted")
                          .withOutcome("no_such_group");

    const auto& res = m_peer->send("/ndt/delete_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 404u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "delete_group") << "the route reached the wrong handler";
    const auto body = json::parse(res.body());
    EXPECT_EQ(body.value("status", ""), "error");
    EXPECT_EQ(body.value("outcome", ""), "no_such_group");
    EXPECT_EQ(body.value("controller_status", 0), 404);
    EXPECT_FALSE(body.value("error", "").empty()) << "the reason must survive to the caller";
}

TEST_F(GroupMeterEndpointTest, ModifyGroupRelaysA404WithItsOutcome)
{
    m_routing->next =
        OpResult::failure(404, "no such group 9 on dpid 1").withOutcome("no_such_group");

    const auto& res = m_peer->send("/ndt/modify_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 404u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "modify_group");
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "no_such_group");
}

TEST_F(GroupMeterEndpointTest, InstallGroupRelaysA409WithItsOutcome)
{
    m_routing->next = OpResult::failure(409, "group 9 on dpid 1 already exists")
                          .withOutcome("no_change_group_exists");

    const auto& res = m_peer->send("/ndt/install_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 409u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "install_group");
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "no_change_group_exists");
}

TEST_F(GroupMeterEndpointTest, DeleteMeterRelaysA404WithItsOutcome)
{
    m_routing->next =
        OpResult::failure(404, "no such meter 3 on dpid 1").withOutcome("no_such_meter");

    const auto& res = m_peer->send("/ndt/delete_meter_entry", kMeterBody);

    EXPECT_EQ(res.result_int(), 404u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "delete_meter");
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "no_such_meter");
}

TEST_F(GroupMeterEndpointTest, ModifyMeterRelaysA404WithItsOutcome)
{
    m_routing->next =
        OpResult::failure(404, "no such meter 3 on dpid 1").withOutcome("no_such_meter");

    const auto& res = m_peer->send("/ndt/modify_meter_entry", kMeterBody);

    EXPECT_EQ(res.result_int(), 404u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "modify_meter");
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "no_such_meter");
}

TEST_F(GroupMeterEndpointTest, InstallMeterRelaysA409WithItsOutcome)
{
    m_routing->next = OpResult::failure(409, "meter 3 on dpid 1 already exists")
                          .withOutcome("no_change_meter_exists");

    const auto& res = m_peer->send("/ndt/install_meter_entry", kMeterBody);

    EXPECT_EQ(res.result_int(), 409u) << res.body();
    EXPECT_EQ(m_routing->lastCalled, "install_meter");
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "no_change_meter_exists");
}

// --- the success shape, for each of the six -----------------------------------------------------
//
// Six separate sentences, asserted verbatim, because a copy-pasted handler is the failure this
// catches and it is invisible to a status-code-only check. The sentences themselves are the
// pre-existing cross-repo contract (doc/2026-01-02_ndt_api.md §31-36) and must not have moved.

TEST_F(GroupMeterEndpointTest, EachEndpointKeepsItsOwnSuccessSentenceAndCarriesTheOutcome)
{
    struct Case
    {
        const char* target;
        const char* body;
        const char* handler;
        const char* sentence;
        const char* outcome;
    };
    const Case cases[] = {
        {"/ndt/install_group_entry", kGroupBody, "install_group", "Group entry installed",
         "installed"},
        {"/ndt/modify_group_entry", kGroupBody, "modify_group", "Group entry modified", "modified"},
        {"/ndt/delete_group_entry", kGroupBody, "delete_group", "Group entry deleted", "deleted"},
        {"/ndt/install_meter_entry", kMeterBody, "install_meter", "Meter entry installed",
         "installed"},
        {"/ndt/modify_meter_entry", kMeterBody, "modify_meter", "Meter entry modified", "modified"},
        {"/ndt/delete_meter_entry", kMeterBody, "delete_meter", "Meter entry deleted", "deleted"},
    };

    for (const auto& c : cases)
    {
        m_routing->next = OpResult::success(200).withOutcome(c.outcome);
        const auto& res = m_peer->send(c.target, c.body);

        EXPECT_EQ(res.result_int(), 200u) << c.target << ": " << res.body();
        EXPECT_EQ(m_routing->lastCalled, c.handler) << c.target << " reached the wrong handler";
        const auto body = json::parse(res.body());
        EXPECT_EQ(body.value("status", ""), c.sentence) << c.target;
        EXPECT_EQ(body.value("outcome", ""), c.outcome) << c.target;
        EXPECT_EQ(body.size(), 2u) << c.target << " gained or lost a field: " << res.body();
    }
}

/**
 * The unverified success, end to end. This is the one a caller most needs to be able to see: the
 * kernel forwarded the request and does not know whether the entry was ever there.
 */
TEST_F(GroupMeterEndpointTest, AnUnverifiedSuccessSaysSoRatherThanClaimingItWasDeleted)
{
    m_routing->next = OpResult::success(200).withOutcome("unverified");

    const auto& res = m_peer->send("/ndt/delete_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 200u) << res.body();
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "unverified");
}

/**
 * A layer with nothing to add must not grow a key. /ndt/ is a cross-repo contract and an extra
 * field is as much a break as a renamed one for a client that counts them -- the assertion that
 * stops `outcome` from being emitted as "" everywhere.
 */
TEST_F(GroupMeterEndpointTest, AResultWithNoOutcomeStillAnswersTheOriginalThreeFieldFailureBody)
{
    m_routing->next = OpResult::unreachable("no response from Ryu controller at localhost:8080");

    const auto& res = m_peer->send("/ndt/delete_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 502u) << res.body();
    const auto body = json::parse(res.body());
    EXPECT_FALSE(body.contains("outcome")) << "an empty outcome was emitted anyway: " << res.body();
    EXPECT_EQ(body.size(), 3u) << res.body();
}

/// The P4 refusal keeps its 501 and gains a name for it. Pins that F-13's fix did not
/// accidentally turn "this data plane cannot do groups" into "this group does not exist".
TEST_F(GroupMeterEndpointTest, AP4RefusalIsStill501AndNamesItself)
{
    m_routing->next = OpResult::unsupported("group entry delete is not supported on a P4/bmv2 "
                                            "data plane")
                          .withOutcome("unsupported_on_p4");

    const auto& res = m_peer->send("/ndt/delete_group_entry", kGroupBody);

    EXPECT_EQ(res.result_int(), 501u) << res.body();
    EXPECT_EQ(json::parse(res.body()).value("outcome", ""), "unsupported_on_p4");
}

/// "No such switch" and "no such group" are both 404. The body is what tells them apart.
TEST_F(GroupMeterEndpointTest, TheTwoDifferentNotFoundsAreDistinguishableInTheBody)
{
    m_routing->next =
        OpResult::failure(404, "no routing strategy for dpid 1").withOutcome("no_such_switch");
    const auto& unknownSwitch = m_peer->send("/ndt/delete_group_entry", kGroupBody);
    EXPECT_EQ(unknownSwitch.result_int(), 404u);
    EXPECT_EQ(json::parse(unknownSwitch.body()).value("outcome", ""), "no_such_switch");

    m_routing->next =
        OpResult::failure(404, "no such group 9 on dpid 1").withOutcome("no_such_group");
    const auto& unknownGroup = m_peer->send("/ndt/delete_group_entry", kGroupBody);
    EXPECT_EQ(unknownGroup.result_int(), 404u);
    EXPECT_EQ(json::parse(unknownGroup.body()).value("outcome", ""), "no_such_group");
}
