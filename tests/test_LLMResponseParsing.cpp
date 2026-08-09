/**
 * Tests for the deserialiser that turns an LLM's reply into Tasks the kernel then executes.
 *
 * [Co-developed with claude code -- Adam]
 *
 * LLMResponseTypes.hpp is 2458 lines and had no tests at all. It is also the least trustworthy
 * input surface in the system: every other parser in this codebase reads bytes produced by a
 * program (Ryu, the P4 proxy, an sFlow agent), which are wrong only when something is broken.
 * This one reads bytes produced by a language model, which are wrong as a matter of routine --
 * a renamed field, a number sent as a string, an enum spelled with different capitalisation, an
 * empty array where an object was asked for. And what comes out the other end is not a display
 * string: `IntentTranslator::performTask` switches on it and powers switches off, installs flow
 * entries and blocks hosts.
 *
 * The entry point tested here is the one production actually uses. `LLMAgent::callOpenAIApi`
 * does, verbatim:
 *
 *     resultJson = json::parse(result);
 *     resPtr = resultJson;              // ADL from_json into unique_ptr<LLMResponse>
 *
 * inside a try block that catches `std::exception` and returns nullptr. So "throws" is a
 * *supported* outcome here -- it is how a malformed reply gets rejected -- and the tests below
 * are careful to distinguish it from the outcome that actually costs something: a reply that
 * parses into a Task holding a quietly wrong value. `uint16_t` fields taking a wrapped value
 * and `valid` being read with `get<int>()` are both in that second category.
 *
 * Two tests are named ...DocumentsCurrentBehaviour. They pin bugs, not intentions; see the
 * report accompanying this file. They are written so that fixing the bug fails the test, which
 * is the point.
 */

#include <memory>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/intent_translator/LLMResponseTypes.hpp"

using json = nlohmann::json;

namespace
{

using llmResponse::Answer;
using llmResponse::LLMResponse;
using llmResponse::Task;
using llmResponse::TaskType;

/// A whole reply in the shape the answer agent is prompted to emit, holding the given tasks.
json
answerWith(json tasks)
{
    return json{{"state", "answer"},
                {"explanation", "because you asked"},
                {"valid", true},
                {"tasks", std::move(tasks)}};
}

/// One task object. `order` and `type` are required of every task by task_from_json.
json
aTask(const std::string& type, json parameters, int order = 1)
{
    return json{{"type", type}, {"order", order}, {"parameters", std::move(parameters)}};
}

/// The production call shape: an implicit conversion, exactly as LLMAgent.cpp does it.
std::unique_ptr<LLMResponse>
parseReply(const json& j)
{
    std::unique_ptr<LLMResponse> p = j;
    return p;
}

/// Parses a reply carrying exactly one task and hands back that task.
std::unique_ptr<Task>
parseOneTask(const json& taskJson)
{
    auto reply = parseReply(answerWith(json::array({taskJson})));
    auto* ans = dynamic_cast<Answer*>(reply.get());
    if (ans == nullptr || ans->tasks.size() != 1)
    {
        throw std::runtime_error("fixture did not produce exactly one task");
    }
    return std::move(ans->tasks[0]);
}

} // namespace

// --- The enum tables. These are the only place a task name is written down, and a task the
//     kernel cannot name is a task it cannot dispatch.

TEST(LLMResponseEnumsTest, EveryTaskTypeSurvivesARoundTripThroughItsWireName)
{
    // Walks the enumerators rather than a hand-written list, so adding a TaskType without adding
    // it to *both* tables fails here. That is the failure mode worth catching: taskTypeToString
    // answers "Unknown" for an unmapped enumerator, taskTypeFromString then throws on "Unknown",
    // and the only visible symptom in production is an LLM reply that is rejected for no stated
    // reason -- with the same wording as a genuinely malformed one.
    for (int raw = llmResponse::DISABLE_SWITCH; raw <= llmResponse::REQUEST_UI_FORM; ++raw)
    {
        const auto t = static_cast<TaskType>(raw);
        const std::string name = llmResponse::taskTypeToString(t);
        ASSERT_NE(name, "Unknown") << "TaskType " << raw << " has no wire name";
        ASSERT_NO_THROW(llmResponse::taskTypeFromString(name)) << name;
        EXPECT_EQ(llmResponse::taskTypeFromString(name), t)
            << "'" << name << "' does not map back to the enumerator that produced it";
    }
}

TEST(LLMResponseEnumsTest, AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger)
{
    // taskTypeToString's default arm. It is reached by the enum being extended, and it is used in
    // IntentTranslator's error log ("Failed to perform task: {}"), so it must not be empty.
    EXPECT_STREQ(llmResponse::taskTypeToString(static_cast<TaskType>(9999)), "Unknown");
}

TEST(LLMResponseEnumsTest, AnUnknownTaskNameIsRejectedRatherThanDefaultingToATask)
{
    // The dangerous alternative is a silent default. DISABLE_SWITCH and POWEROFF_SWITCH are the
    // first two enumerators, so "fall back to the first one" would turn a typo into a switch
    // being turned off.
    EXPECT_THROW(llmResponse::taskTypeFromString("NotATask"), std::runtime_error);
    EXPECT_THROW(llmResponse::taskTypeFromString(""), std::runtime_error);
}

TEST(LLMResponseEnumsTest, TaskNamesAreCaseSensitiveSoNearMissesAreRejected)
{
    // An LLM producing `getPath` or `GETPATH` instead of `GetPath` is an everyday occurrence. The
    // right answer is a rejected reply -- which LLMAgent turns into a retry -- and not a
    // best-effort match, because the near-miss neighbours here include PowerOffSwitch.
    for (const char* const near : {"getPath", "GETPATH", "Getpath", " GetPath", "GetPath "})
    {
        EXPECT_THROW(llmResponse::taskTypeFromString(near), std::runtime_error) << near;
    }
    EXPECT_EQ(llmResponse::taskTypeFromString("GetPath"), llmResponse::GET_PATH);
}

TEST(LLMResponseEnumsTest, EveryStateSurvivesARoundTripAndUnknownOnesAreRejected)
{
    for (const auto s : {llmResponse::DISCUSSION, llmResponse::ANSWER, llmResponse::VALIDATION})
    {
        EXPECT_EQ(llmResponse::stateFromString(llmResponse::stateToString(s)), s)
            << llmResponse::stateToString(s);
    }
    // The states are lower case on the wire and the task names are CamelCase; mixing them up is
    // the mistake this guards.
    EXPECT_THROW(llmResponse::stateFromString("Answer"), std::runtime_error);
    EXPECT_THROW(llmResponse::stateFromString("done"), std::runtime_error);
    EXPECT_THROW(llmResponse::stateFromString(""), std::runtime_error);
}

// --- Top-level dispatch on `state`.

TEST(LLMResponseParsingTest, ADiscussionReplyBecomesADiscussionCarryingItsPrompt)
{
    const auto p = parseReply(json{{"state", "discussion"}, {"prompt", "which switch?"}});
    auto* d = dynamic_cast<llmResponse::Discussion*>(p.get());
    ASSERT_NE(d, nullptr) << "a discussion reply must not deserialise into another state";
    EXPECT_EQ(d->state, llmResponse::DISCUSSION);
    EXPECT_EQ(d->prompt, "which switch?");
}

TEST(LLMResponseParsingTest, AValidationReplyCarriesItsErrorMessageFromTheErrorField)
{
    // The field is named "error" on the wire and errorMsg in C++, and performAgentsNegotiation
    // treats an empty errorMsg as "validation passed" -- so a rename on either side turns a
    // rejection into an approval.
    const auto p = parseReply(json{{"state", "validation"}, {"error", "port 99 does not exist"}});
    auto* v = dynamic_cast<llmResponse::Validation*>(p.get());
    ASSERT_NE(v, nullptr);
    EXPECT_EQ(v->errorMsg, "port 99 does not exist");
}

TEST(LLMResponseParsingTest, AReplyWithNoStateIsRejectedRatherThanAssumedToBeAnAnswer)
{
    // Assuming "answer" would mean a reply the model never intended as an instruction gets
    // executed. LLMAgent catches the throw and returns nullptr, which retries.
    EXPECT_THROW(parseReply(json{{"prompt", "hello"}}), json::exception);
    EXPECT_THROW(parseReply(json{{"state", nullptr}, {"prompt", "hello"}}), json::exception);
    EXPECT_THROW(parseReply(json{{"state", 1}, {"prompt", "hello"}}), json::exception);
    EXPECT_THROW(parseReply(json::object()), json::exception);

    // The four above do not actually prove what this test is named for. Every one of them is also
    // missing `explanation`, which from_json(Answer&) reads before anything consults `state`, so
    // they would keep throwing with the state requirement removed entirely -- which is exactly
    // what happened when the removal was attempted. This case is the discriminating one: complete
    // except for `state`, with `valid` false so the tasks array is not required either. It is the
    // only assertion here that fails if a missing state stops being refused.
    EXPECT_THROW(parseReply(json{{"explanation", ""}, {"valid", false}}), json::exception)
        << "a reply complete except for `state` was accepted";
}

TEST(LLMResponseParsingTest, ANullResponsePointerSerialisesToJsonNullRatherThanAnEmptyObject)
{
    // `json j = resPtr` is how a reply is logged and how it is stored in the session history that
    // performAgentsNegotiation reads back with ["msg"]["state"]. An empty object there would be
    // indistinguishable from a real reply whose fields all went missing.
    const std::unique_ptr<LLMResponse> nothing;
    json j = nothing;
    EXPECT_TRUE(j.is_null()) << j.dump();
}

TEST(LLMResponseParsingTest, ANullTaskPointerSerialisesToJsonNullRatherThanAnEmptyObject)
{
    const std::unique_ptr<Task> nothing;
    json j = nothing;
    EXPECT_TRUE(j.is_null()) << j.dump();
}

// --- `valid`, which decides whether the tasks are read at all.

TEST(LLMResponseParsingTest, AnAnswerMarkedInvalidDiscardsTheTasksItStillCarries)
{
    // Deliberate in the code and worth pinning: from_json only walks "tasks" when valid is truthy.
    // So an LLM that fills in tasks *and* says valid:false gets its tasks dropped rather than
    // executed. That is the safe direction, and the test exists so it cannot be "tidied" into the
    // unsafe one -- the tasks in this fixture power switches off.
    json reply = answerWith(json::array({aTask("PowerOffSwitch", {{"device_name", "s1"}}),
                                         aTask("PowerOffSwitch", {{"device_name", "s2"}}, 2)}));
    reply["valid"] = false;

    const auto p = parseReply(reply);
    auto* ans = dynamic_cast<Answer*>(p.get());
    ASSERT_NE(ans, nullptr);
    EXPECT_FALSE(ans->valid);
    EXPECT_TRUE(ans->tasks.empty()) << "tasks were kept for an answer the model called invalid";
}

TEST(LLMResponseParsingTest, ValidIsReadNumericallySoOneAndZeroBothWork)
{
    // The field is declared `bool` but read with `get<int>()`. That is what makes a numeric 1
    // acceptable, and models do emit 1/0 for booleans. Pinned because "fixing" the type to
    // get<bool>() would make nlohmann throw on a numeric 1 and reject replies that work today.
    json numericTrue = answerWith(json::array({aTask("GetAllHosts", json::object())}));
    numericTrue["valid"] = 1;
    // [Co-developed with claude code -- Adam]
    // The owning unique_ptr is held in a named variable. It used to be
    //     auto* yes = dynamic_cast<Answer*>(parseReply(numericTrue).get());
    // where parseReply returns a temporary unique_ptr that is destroyed at the end of that
    // full-expression -- so `yes` dangled immediately and the EXPECT below read freed memory. The
    // test passed anyway, on every ordinary run, because the freed bytes still held the old value.
    // TSan's heap-use-after-free report was the only thing that saw it, and the correct pattern was
    // already three lines further down in this same test.
    const auto yesOwner = parseReply(numericTrue);
    auto* yes = dynamic_cast<Answer*>(yesOwner.get());
    ASSERT_NE(yes, nullptr);
    EXPECT_TRUE(yes->valid);

    json numericFalse = numericTrue;
    numericFalse["valid"] = 0;
    const auto no = parseReply(numericFalse);
    auto* noAns = dynamic_cast<Answer*>(no.get());
    ASSERT_NE(noAns, nullptr);
    EXPECT_FALSE(noAns->valid);
}

TEST(LLMResponseParsingTest, AStringlyTypedValidIsRejectedRatherThanReadAsTruthy)
{
    // `"valid": "false"` is a string, and every string is truthy in the language the prompt is
    // written for. Accepting it would execute the tasks of a reply that says it is invalid, which
    // is the exact inversion the previous test guards from the other side.
    json reply = answerWith(json::array({aTask("PowerOffSwitch", {{"device_name", "s1"}})}));
    for (const json& bad : {json("false"), json("true"), json("1"), json::array(), json::object()})
    {
        reply["valid"] = bad;
        EXPECT_THROW(parseReply(reply), json::exception) << "valid " << bad.dump();
    }
}

TEST(LLMResponseParsingTest, AnEmptyTaskListIsAcceptedButAMissingOneIsNot)
{
    // Both halves in one test because the distinction is the whole point, and a test that asserted
    // only one of them would pass under a change that collapsed them.
    //
    // valid:true is the model asserting there is something to do, so a *missing* "tasks" is a
    // contradiction: treating it as zero tasks would report success for an intent nobody carried
    // out. Present-but-empty is a coherent statement, and rejecting that would burn all five
    // retries on a reply that was fine.
    //
    // The guard is narrower than it looks, and deliberately not overstated here: only the *absent*
    // key is caught. `"tasks": null` and `"tasks": {}` are present, so they slip through into the
    // silent-zero-tasks case -- now rejected; see AnAnswerClaimingValidWithNullTasksIsRejected.
    EXPECT_THROW(parseReply(json{{"state", "answer"},
                                 {"explanation", ""},
                                 {"valid", true}}),
                 json::exception);

    const auto p = parseReply(answerWith(json::array()));
    auto* ans = dynamic_cast<Answer*>(p.get());
    ASSERT_NE(ans, nullptr);
    EXPECT_TRUE(ans->valid);
    EXPECT_TRUE(ans->tasks.empty());
}

// --- Task-level dispatch and the shared Task fields.

TEST(LLMResponseParsingTest, EachTaskNameProducesItsOwnConcreteType)
{
    // performTask switches on Task::type, but every field it reads lives on the derived class and
    // is reached by a static_cast. Dispatching to the wrong class therefore reads another class's
    // memory rather than failing, so the mapping from name to type needs its own test.
    const auto path = parseOneTask(aTask("GetPath", {{"src", "h1"}, {"dst", "h7"}}));
    ASSERT_NE(dynamic_cast<llmResponse::GetPathTask*>(path.get()), nullptr);
    EXPECT_EQ(path->type, llmResponse::GET_PATH);

    const auto count = parseOneTask(aTask("GetPathSwitchCount", {{"src", "h1"}, {"dst", "h7"}}));
    ASSERT_NE(dynamic_cast<llmResponse::GetPathSwitchCountTask*>(count.get()), nullptr);
    EXPECT_EQ(count->type, llmResponse::GET_PATH_SWITCH_COUNT);

    const auto block = parseOneTask(aTask("BlockHost", {{"host_id", "h3"}}));
    ASSERT_NE(dynamic_cast<llmResponse::BlockHostTask*>(block.get()), nullptr);

    const auto off = parseOneTask(aTask("PowerOffSwitch", {{"device_name", "s4"}}));
    ASSERT_NE(dynamic_cast<llmResponse::PowerOffSwitchTask*>(off.get()), nullptr);
    EXPECT_EQ(dynamic_cast<llmResponse::PowerOffSwitchTask*>(off.get())->deviceName, "s4");
}

TEST(LLMResponseParsingTest, ATaskWithNoOrderIsRejectedBecauseTheOrderDecidesWhatRunsFirst)
{
    // Tasks are executed in the sequence they arrive in and `order` is the model's statement about
    // sequence. Defaulting it to 0 would make "power the switch off" and "install the route"
    // indistinguishable in ordering, on a list where that matters.
    EXPECT_THROW(parseOneTask(json{{"type", "GetAllHosts"}, {"parameters", json::object()}}),
                 json::exception);
    EXPECT_THROW(parseOneTask(json{{"type", "GetAllHosts"},
                                   {"order", nullptr},
                                   {"parameters", json::object()}}),
                 json::exception);
}

TEST(LLMResponseParsingTest, OrderIsCarriedThroughForValuesBeyondASingleByte)
{
    // order is uint16_t. 300 is chosen because it is the smallest value that a narrower type would
    // silently mangle rather than reject.
    EXPECT_EQ(parseOneTask(aTask("GetAllHosts", json::object(), 7))->order, 7);
    EXPECT_EQ(parseOneTask(aTask("GetAllHosts", json::object(), 300))->order, 300);
    EXPECT_EQ(parseOneTask(aTask("GetAllHosts", json::object(), 65535))->order, 65535);
}

TEST(LLMResponseParsingTest, ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour)
{
    // Documents a bug rather than an intention. `order` is uint16_t and nlohmann narrows rather
    // than refusing, so `"order": -1` arrives as 65535 -- the largest possible order, i.e. the
    // exact opposite of what a model emitting -1 to mean "first" would expect. No exception, no
    // log line. Fixing this makes the test fail, which is intended.
    EXPECT_EQ(parseOneTask(aTask("GetAllHosts", json::object(), -1))->order, 65535);
    EXPECT_EQ(parseOneTask(aTask("GetAllHosts", json::object(), -2))->order, 65534);
}

TEST(LLMResponseParsingTest, AResultSuppliedByTheModelIsDiscardedRatherThanTrusted)
{
    // `result` is an output field: performTask fills it in with what the kernel actually observed,
    // and the web GUI displays it. A model that pre-fills it is describing a measurement nobody
    // took, so task_from_json clears it unconditionally. Pinned because the clear happens *after*
    // the derived from_json runs, which is easy to reorder away.
    const auto t = parseOneTask(json{{"type", "GetActiveFlowCount"},
                                     {"order", 1},
                                     {"result", "there are 42 flows"},
                                     {"parameters", json::object()}});
    EXPECT_EQ(t->result, "") << "a fabricated result reached the caller";
}

TEST(LLMResponseParsingTest, ATaskThatTakesNoParametersDoesNotRequireAParametersObject)
{
    // Models omit empty objects. These tasks read nothing out of "parameters", so demanding the
    // key would reject replies that are complete.
    EXPECT_NO_THROW(parseOneTask(json{{"type", "GetTotalPowerConsumption"}, {"order", 1}}));
    EXPECT_NO_THROW(parseOneTask(json{{"type", "GetNetworkTopology"}, {"order", 1}}));
    EXPECT_NO_THROW(parseOneTask(json{{"type", "GetActiveFlowCount"}, {"order", 1}}));
}

TEST(LLMResponseParsingTest, ATaskThatNeedsAParameterIsRejectedWhenItIsMissingOrNull)
{
    // The opposite of the case above. DisableSwitch with no device_name must not resolve to the
    // empty device name, because further down the stack an empty bridge name is a wildcard.
    EXPECT_THROW(parseOneTask(json{{"type", "DisableSwitch"}, {"order", 1}}), json::exception);
    EXPECT_THROW(parseOneTask(aTask("DisableSwitch", json::object())), json::exception);
    EXPECT_THROW(parseOneTask(aTask("DisableSwitch", {{"device_name", nullptr}})),
                 json::exception);
    EXPECT_THROW(parseOneTask(aTask("DisableSwitch", {{"device_name", 4}})), json::exception);
    EXPECT_THROW(parseOneTask(aTask("DisableSwitch", {{"switch", "s1"}})), json::exception);
}

TEST(LLMResponseParsingTest, ADeviceNameGivenAsANumberIsRejectedRatherThanStringified)
{
    // `"device_name": 4` is a natural thing for a model to emit for "switch 4", and the kernel
    // looks devices up by their Mininet bridge name ("s4"). Coercing 4 to "4" would look up a
    // device that does not exist and report a clean "not found" for a request that was really a
    // schema disagreement.
    EXPECT_THROW(parseOneTask(aTask("GetASwitchCpuUtilization", {{"device_name", 4}})),
                 json::exception);
    EXPECT_THROW(parseOneTask(aTask("SetSwitchPowerState",
                                    {{"device_name", "s4"}, {"state", 1}})),
                 json::exception);
}

// --- Flow-entry tasks. These are the ones that write to the network.

TEST(LLMResponseParsingTest, AnInstallFlowEntryCarriesItsDeviceMatchPriorityAndAction)
{
    const json expectedMatch = {{"nw_dst", "10.0.0.4"}};
    const auto t = parseOneTask(aTask("InstallFlowEntry",
                                      {{"device_name", "s3"},
                                       {"priority", 100},
                                       {"match", {{"nw_dst", "10.0.0.4"}}},
                                       {"actions", json::array({{{"type", "OUTPUT"},
                                                                 {"port", 2}}})}}));
    auto* install = dynamic_cast<llmResponse::InstallFlowEntryTask*>(t.get());
    ASSERT_NE(install, nullptr);
    EXPECT_EQ(install->deviceName, "s3");
    EXPECT_EQ(install->priority, 100);
    EXPECT_EQ(install->match, expectedMatch);
    EXPECT_EQ(install->actionType, "OUTPUT");
    EXPECT_EQ(install->actionOutPort, 2);
}

TEST(LLMResponseParsingTest, AnEmptyActionsArrayMeansDropAndIsSignalledByPortMinusOne)
{
    // -1 is the sentinel for "no output port", and it has to be distinguishable from port 0 --
    // which is a real thing to send to. An action-less flow entry is how a drop rule is expressed.
    const auto t = parseOneTask(aTask("InstallFlowEntry",
                                      {{"device_name", "s3"},
                                       {"priority", 1},
                                       {"match", json::object()},
                                       {"actions", json::array()}}));
    auto* install = dynamic_cast<llmResponse::InstallFlowEntryTask*>(t.get());
    ASSERT_NE(install, nullptr);
    EXPECT_EQ(install->actionType, "");
    EXPECT_EQ(install->actionOutPort, -1);
}

TEST(LLMResponseParsingTest, OnlyTheFirstActionIsReadAndTheRestAreSilentlyIgnored)
{
    // The class holds one actionType and one actionOutPort, so a multi-action rule cannot be
    // represented. Pinned as the real contract: a model asked to mirror traffic to two ports gets
    // one of them installed, and the test says which one.
    const auto t = parseOneTask(aTask("InstallFlowEntry",
                                      {{"device_name", "s3"},
                                       {"priority", 1},
                                       {"match", json::object()},
                                       {"actions", json::array({{{"type", "OUTPUT"}, {"port", 2}},
                                                                {{"type", "OUTPUT"},
                                                                 {"port", 5}}})}}));
    auto* install = dynamic_cast<llmResponse::InstallFlowEntryTask*>(t.get());
    ASSERT_NE(install, nullptr);
    EXPECT_EQ(install->actionOutPort, 2) << "the first action must be the one that is kept";
}

TEST(LLMResponseParsingTest, TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour)
{
    // The two action parsers in this repo disagree, and this test states which is which so the
    // disagreement cannot be discovered again by accident:
    //
    //   Classifier.cpp parseActionsArrayIntoEffect  accepts ONLY "OUTPUT:2" and ignores objects
    //   LLMResponseTypes.hpp InstallFlowEntryTask   accepts ONLY {"type":..,"port":..}
    //
    // Both are internally consistent -- one reads Ryu's ofctl_rest output, the other reads the
    // LLM's -- but a prompt or a fixture written against the wrong one fails at the far end, and
    // this side fails with a raw nlohmann type_error that names neither field.
    EXPECT_THROW(parseOneTask(aTask("InstallFlowEntry",
                                    {{"device_name", "s3"},
                                     {"priority", 1},
                                     {"match", json::object()},
                                     {"actions", json::array({"OUTPUT:2"})}})),
                 json::exception);
}

TEST(LLMResponseParsingTest, AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero)
{
    // Port 0 is a valid OpenFlow port number, so a defaulted 0 would install a rule that forwards
    // somewhere real. Rejecting is the only safe reading of "OUTPUT with no port".
    EXPECT_THROW(parseOneTask(aTask("InstallFlowEntry",
                                    {{"device_name", "s3"},
                                     {"priority", 1},
                                     {"match", json::object()},
                                     {"actions", json::array({{{"type", "OUTPUT"}}})}})),
                 json::exception);
    EXPECT_THROW(parseOneTask(aTask("InstallFlowEntry",
                                    {{"device_name", "s3"},
                                     {"priority", 1},
                                     {"match", json::object()},
                                     {"actions", json::array({{{"port", 2}}})}})),
                 json::exception);
}

TEST(LLMResponseParsingTest, APriorityAboveSixteenBitsWrapsDocumentsCurrentBehaviour)
{
    // priority is uint16_t, which matches OpenFlow, but nlohmann narrows silently instead of
    // refusing. 70000 becomes 4464, so a rule the model intended to win against everything is
    // installed below a default priority-10 rule -- and nothing in the pipeline says so. Fixing
    // this (by rejecting, or by widening the field) fails this test, which is intended.
    const auto t = parseOneTask(aTask("InstallFlowEntry",
                                      {{"device_name", "s3"},
                                       {"priority", 70000},
                                       {"match", json::object()},
                                       {"actions", json::array()}}));
    auto* install = dynamic_cast<llmResponse::InstallFlowEntryTask*>(t.get());
    ASSERT_NE(install, nullptr);
    EXPECT_EQ(install->priority, 4464u) << "70000 mod 65536";
}

TEST(LLMResponseParsingTest, AMatchIsCarriedThroughVerbatimWithoutBeingValidated)
{
    // `match` is a raw json, deliberately: it is forwarded to Ryu, which owns the field
    // vocabulary. So the contract is that nothing is dropped or renamed on the way through --
    // including keys this kernel has never heard of.
    const json match = {{"nw_src", "10.0.0.1"},
                        {"nw_dst", "10.0.0.4"},
                        {"tp_dst", 80},
                        {"some_future_field", json::array({1, 2})}};
    const auto t = parseOneTask(aTask("DeleteFlowEntry",
                                      {{"device_name", "s3"}, {"match", match}}));
    auto* del = dynamic_cast<llmResponse::DeleteFlowEntryTask*>(t.get());
    ASSERT_NE(del, nullptr);
    EXPECT_EQ(del->match, match);
}

// [Co-developed with claude code -- Adam]
// AModifyFlowEntryTaskConstructsItselfAsAnInstallDocumentsCurrentBehaviour used to be here. It
// pinned the defect where ModifyFlowEntryTask's constructor set type = INSTALL_FLOW_ENTRY. The
// defect is fixed, so the test was retired rather than inverted -- the correct behaviour is now
// asserted by AModifyFlowEntryTaskConstructsItselfAsAModify, which was derived from the task-type
// semantics rather than from the implementation. Recorded rather than silently deleted so the
// history of the pin is visible.


// --- Collection-valued parameters.

TEST(LLMResponseParsingTest, ARerouteCarriesEveryHopInTheOrderTheModelGaveThem)
{
    // The order *is* the route. A container change that sorted or deduplicated these would produce
    // a path that is still plausible and still installable, and wrong.
    const auto t = parseOneTask(aTask("RerouteFlow",
                                      {{"match", {{"nw_dst", "10.0.0.4"}}},
                                       {"new_path", json::array({"s3", "s1", "s2", "s1"})}}));
    auto* reroute = dynamic_cast<llmResponse::RerouteFlowTask*>(t.get());
    ASSERT_NE(reroute, nullptr);
    const std::vector<std::string> expected = {"s3", "s1", "s2", "s1"};
    EXPECT_EQ(reroute->newPath, expected);
}

TEST(LLMResponseParsingTest, ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed)
{
    // `"new_path": ["s1", 2]` is a mixed array, which is the shape a model produces when it starts
    // naming switches and finishes numbering them. Half a route is worse than none.
    EXPECT_THROW(parseOneTask(aTask("RerouteFlow",
                                    {{"match", json::object()},
                                     {"new_path", json::array({"s1", 2})}})),
                 json::exception);
    EXPECT_THROW(parseOneTask(aTask("RerouteFlow",
                                    {{"match", json::object()}, {"new_path", "s1,s2"}})),
                 json::exception);
}

TEST(LLMResponseParsingTest, AGroupEntrysBucketsAreCarriedThroughVerbatim)
{
    // Same argument as `match`: buckets are Ryu's vocabulary, not this kernel's, so they pass
    // through untouched -- including an empty list, which is a legal group with no members.
    const json buckets = json::array({{{"weight", 1}, {"actions", json::array({"OUTPUT:2"})}}});
    const auto t = parseOneTask(aTask("InstallGroupEntry",
                                      {{"device_name", "s1"},
                                       {"group_type", "SELECT"},
                                       {"group_id", 10},
                                       {"buckets", buckets}}));
    auto* group = dynamic_cast<llmResponse::InstallGroupEntryTask*>(t.get());
    ASSERT_NE(group, nullptr);
    EXPECT_EQ(group->group_id, 10);
    EXPECT_EQ(group->group_type, "SELECT");
    EXPECT_EQ(group->buckets, buckets);
}

TEST(LLMResponseParsingTest, AMeterEntrysFlagsListIsCarriedThroughInOrder)
{
    const auto t = parseOneTask(aTask("InstallMeterEntry",
                                      {{"device_name", "s1"},
                                       {"meter_id", 3},
                                       {"flags", json::array({"KBPS", "BURST"})},
                                       {"bands", json::array()}}));
    auto* meter = dynamic_cast<llmResponse::InstallMeterEntryTask*>(t.get());
    ASSERT_NE(meter, nullptr);
    EXPECT_EQ(meter->meter_id, 3);
    const std::vector<std::string> expected = {"KBPS", "BURST"};
    EXPECT_EQ(meter->flags, expected);
}

TEST(LLMResponseParsingTest, AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText)
{
    // "top 3 flows" arriving as `"k": "3"` is the single most common shape error a model makes on
    // a numeric field. Rejecting it retries; coercing it would work here and stop working the
    // moment the model writes "three".
    EXPECT_THROW(parseOneTask(aTask("GetTopKFlows", {{"k", "3"}})), json::exception);
    EXPECT_THROW(parseOneTask(aTask("GetTopKCongestedLinks", {{"k", "3"}})), json::exception);
    EXPECT_EQ(dynamic_cast<llmResponse::GetTopKFlowsTask*>(
                  parseOneTask(aTask("GetTopKFlows", {{"k", 3}})).get())
                  ->k,
              3);
}

TEST(LLMResponseParsingTest, ANegativeKIsCarriedThroughForTheCallerToDealWith)
{
    // `k` is a plain int and nothing here clamps it, so a negative or zero k reaches
    // getTopKFlowInfoJson. Stated explicitly because it is the boundary the caller has to own --
    // this layer is not where it gets checked.
    EXPECT_EQ(dynamic_cast<llmResponse::GetTopKFlowsTask*>(
                  parseOneTask(aTask("GetTopKFlows", {{"k", -5}})).get())
                  ->k,
              -5);
    EXPECT_EQ(dynamic_cast<llmResponse::GetTopKBandwidthUsersTask*>(
                  parseOneTask(aTask("GetTopKBandwidthUsers", {{"k", 0}})).get())
                  ->k,
              0);
}

// --- Whole-reply behaviour.

TEST(LLMResponseParsingTest, SeveralTasksArriveInTheOrderTheyWereListed)
{
    // performTask is called in vector order, so the vector order is a behaviour. Two of these
    // three tasks change the network, and running them backwards is a different outcome.
    const auto p = parseReply(answerWith(json::array({
        aTask("DisableSwitch", {{"device_name", "s1"}}, 1),
        aTask("GetPath", {{"src", "h1"}, {"dst", "h7"}}, 2),
        aTask("EnableSwitch", {{"device_name", "s1"}}, 3),
    })));
    auto* ans = dynamic_cast<Answer*>(p.get());
    ASSERT_NE(ans, nullptr);
    ASSERT_EQ(ans->tasks.size(), 3u);
    EXPECT_EQ(ans->tasks[0]->type, llmResponse::DISABLE_SWITCH);
    EXPECT_EQ(ans->tasks[1]->type, llmResponse::GET_PATH);
    EXPECT_EQ(ans->tasks[2]->type, llmResponse::ENABLE_SWITCH);
}

TEST(LLMResponseParsingTest, OneUnparseableTaskRejectsTheWholeReplyRatherThanPartOfIt)
{
    // There is no per-task recovery, and that is the right shape: the tasks in a reply are one
    // plan. Executing the prefix of a plan whose remainder was rejected is how a switch gets
    // powered off and never powered back on.
    EXPECT_THROW(parseReply(answerWith(json::array({
                     aTask("PowerOffSwitch", {{"device_name", "s1"}}, 1),
                     aTask("PowerOnSwitch", json::object(), 2),
                 }))),
                 json::exception);
}

TEST(LLMResponseParsingTest, ATasksEntryThatIsNotATaskObjectIsRejected)
{
    // Every one of these is a shape a model has some reason to produce: a stringified list, a task
    // named but not described, a null placeholder inside the list.
    for (const json& bad : {json("[]"),
                            json(0),
                            json::array({json(nullptr)}),
                            json::array({json("PowerOffSwitch")}),
                            json::array({json::array()})})
    {
        json reply = json{{"state", "answer"}, {"explanation", ""}, {"valid", true}};
        reply["tasks"] = bad;
        EXPECT_THROW(parseReply(reply), json::exception) << "tasks " << bad.dump();
    }
}

// [Co-developed with claude code -- Adam]
// ANullTasksFieldYieldsNoTasksAndNoErrorDocumentsCurrentBehaviour used to be here, pinning the
// defect where `valid: true` with `tasks: null` was accepted as a well-formed answer that did
// nothing. Now rejected with a json::type_error (so it answers 400, not 500); the replacement is
// AnAnswerClaimingValidWithNullTasksIsRejected.


// [Co-developed with claude code -- Adam]
// DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour used to be here, pinning the
// fourth instance of "should replace, can only add": from_json appended to an Answer's existing
// tasks. Replaced by DeserialisingAnAnswerReplacesExistingTasks.


TEST(LLMResponseParsingTest, AnAnswerRoundTripsThroughJsonWithItsTasksIntact)
{
    // The round trip is a real path: performAgentsNegotiation serialises the answer agent's reply
    // and feeds it to the validation agent, then reads the result back. A field that survives
    // parsing but is dropped on the way out is invisible until the second agent contradicts the
    // first for no reason.
    const json original = answerWith(json::array({
        aTask("InstallFlowEntry",
              {{"device_name", "s3"},
               {"priority", 100},
               {"match", {{"nw_dst", "10.0.0.4"}}},
               {"actions", json::array({{{"type", "OUTPUT"}, {"port", 2}}})}},
              1),
        aTask("GetPath", {{"src", "h1"}, {"dst", "h7"}}, 2),
    }));

    const auto parsed = parseReply(original);
    json out = parsed;
    const json expectedMatch = {{"nw_dst", "10.0.0.4"}};

    EXPECT_EQ(out.at("state"), "answer");
    EXPECT_EQ(out.at("explanation"), "because you asked");
    ASSERT_TRUE(out.at("tasks").is_array());
    ASSERT_EQ(out.at("tasks").size(), 2u);
    EXPECT_EQ(out.at("tasks")[0].at("type"), "InstallFlowEntry");
    EXPECT_EQ(out.at("tasks")[0].at("order"), 1);
    EXPECT_EQ(out.at("tasks")[0].at("parameters").at("priority"), 100);
    EXPECT_EQ(out.at("tasks")[0].at("parameters").at("match"), expectedMatch);
    EXPECT_EQ(out.at("tasks")[0].at("parameters").at("actions")[0].at("port"), 2);
    EXPECT_EQ(out.at("tasks")[1].at("type"), "GetPath");
    EXPECT_EQ(out.at("tasks")[1].at("parameters").at("src"), "h1");

    // And the whole thing parses again, which is what the validation agent's reply has to do.
    EXPECT_NO_THROW(parseReply(out));
}

TEST(LLMResponseParsingTest, NothingAModelCouldSendCausesAnythingWorseThanAnException)
{
    // LLMAgent wraps the parse in `catch (const std::exception&)`, so an exception is handled and
    // anything else is not: a terminate, a segfault, or -- worst -- a successful parse of
    // nonsense. This is the catch-all for shapes the tests above do not enumerate.
    const std::vector<json> nasty = {
        json(nullptr),
        json::object(),
        json::array(),
        json(42),
        json("answer"),
        json{{"state", "answer"}},
        json{{"state", "answer"}, {"valid", true}, {"tasks", json::array()}},
        json{{"state", "answer"}, {"explanation", nullptr}, {"valid", true},
             {"tasks", json::array()}},
        json{{"state", "discussion"}},
        json{{"state", "discussion"}, {"prompt", json::array()}},
        json{{"state", "validation"}},
        json{{"state", "validation"}, {"error", 500}},
        answerWith(json::array({json::object()})),
        answerWith(json::array({json{{"type", "GetAllHosts"}}})),
        answerWith(json::array({json{{"order", 1}}})),
        answerWith(json::array({aTask("Unknown", json::object())})),
        answerWith(json::array({aTask("InstallFlowEntry", json::object())})),
        answerWith(json::array({aTask("InstallFlowEntry",
                                      {{"device_name", "s1"},
                                       {"priority", 1},
                                       {"match", "not an object"},
                                       {"actions", "not an array"}})})),
        answerWith(json::array({aTask("InstallFlowEntry",
                                      {{"device_name", "s1"},
                                       {"priority", 1},
                                       {"match", json::object()},
                                       {"actions", json::object()}})})),
        answerWith(json::array({aTask("RerouteFlow",
                                      {{"match", json::object()}, {"new_path", nullptr}})})),
        answerWith(json::array({aTask("InstallMeterEntry",
                                      {{"device_name", "s1"},
                                       {"meter_id", 1e300},
                                       {"flags", json::array()},
                                       {"bands", json::array()}})})),
    };

    for (const json& bad : nasty)
    {
        try
        {
            const auto p = parseReply(bad);
            // A successful parse is allowed, but it must produce a usable object rather than a
            // null one that the caller will dereference.
            EXPECT_NE(p, nullptr) << "parsed to a null pointer without throwing: " << bad.dump();
        }
        catch (const std::exception&)
        {
            // The supported rejection path.
        }
        catch (...)
        {
            ADD_FAILURE() << "threw something LLMAgent's catch cannot see: " << bad.dump();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests that assert SPEC behaviour for the four known Answer/Task defects.
// These are expected to FAIL until the corresponding implementation bugs are fixed.
// ---------------------------------------------------------------------------

TEST(LLMResponseParsingTest, AModifyFlowEntryTaskConstructsItselfAsAModify)
{
    // Per LLMResponseTypes.hpp:62, MODIFY_FLOW_ENTRY is a distinct TaskType enumerator.
    // A ModifyFlowEntryTask is semantically a modification of an existing flow entry,
    // not an installation of a new one. Its constructor must set type = MODIFY_FLOW_ENTRY.
    //
    // Currently the constructor sets type = INSTALL_FLOW_ENTRY (line 664), which means
    // a C++-constructed ModifyFlowEntryTask serialises as "InstallFlowEntry" on the wire
    // and is dispatched to the wrong handler. This test is EXPECTED TO FAIL until
    // LLMResponseTypes.hpp:664 is corrected from INSTALL_FLOW_ENTRY to MODIFY_FLOW_ENTRY.

    llmResponse::ModifyFlowEntryTask built;
    EXPECT_EQ(built.type, llmResponse::MODIFY_FLOW_ENTRY)
        << "ModifyFlowEntryTask constructor must set type = MODIFY_FLOW_ENTRY, "
        << "not INSTALL_FLOW_ENTRY. Fix: change LLMResponseTypes.hpp:664";
}

TEST(LLMResponseParsingTest, DeserialisingAnAnswerReplacesExistingTasks)
{
    // The universal contract of a from_json deserialiser: parsing new data REPLACES the
    // object's state, it does not append to it. Answer::from_json currently push_backs
    // into `tasks` without clearing it first (LLMResponseTypes.hpp:2346-2351), which
    // means deserialising twice into the same Answer doubles the task list.
    //
    // Production never hits this because make_llm_from_json always allocates a fresh
    // Answer. But the type is public, its from_json is public, and reusing an Answer
    // object (e.g. in a retry loop) would silently execute every task twice.
    //
    // This test is EXPECTED TO FAIL until LLMResponseTypes.hpp:2344 adds
    // `ans.tasks.clear()` before the push_back loop.

    const json reply = answerWith(json::array({aTask("GetAllHosts", json::object())}));
    Answer ans;
    from_json(reply, ans);
    EXPECT_EQ(ans.tasks.size(), 1u) << "first parse should produce 1 task";

    // Parse the SAME reply again into the SAME Answer object.
    // The correct behaviour: the second parse REPLACES the first, so we still have 1 task.
    // The current behaviour: the second parse APPENDS, so we have 2 tasks.
    from_json(reply, ans);
    EXPECT_EQ(ans.tasks.size(), 1u)
        << "parsing the same reply twice must replace, not append. "
        << "Fix: add ans.tasks.clear() at LLMResponseTypes.hpp before the push_back loop";
}

TEST(LLMResponseParsingTest, AnAnswerClaimingValidWithNullTasksIsRejected)
{
    // When an Answer says "valid: true", it is asserting that there is actionable work.
    // A `tasks` field that is JSON null or a JSON object is not a list of tasks --
    // it is a contradiction. The kernel must reject this rather than silently treating
    // it as zero tasks (which reports success for work nobody carried out).
    //
    // The current code (LLMResponseTypes.hpp:2344-2351) iterates `j.at("tasks")` with a
    // range-for, and nlohmann yields an empty range for both `null` and `{}`. So both
    // parse successfully into an Answer with zero tasks, which is then executed as a
    // valid, successful, do-nothing plan.
    //
    // The spec does not explicitly enumerate every malformed input, but the combination
    // `valid:true` + non-array `tasks` is a contradiction by the plain meaning of the
    // fields. The absent-key case is already caught (AnEmptyTaskListIsAcceptedButAMissingOneIsNot);
    // the present-but-wrong-type case should be caught too.
    //
    // This test is EXPECTED TO FAIL until LLMResponseTypes.hpp:2344 validates that
    // `j.at("tasks")` is an array before iterating it.

    for (const json& empty : {json(nullptr), json::object()})
    {
        json reply = json{{"state", "answer"}, {"explanation", "I did the thing"}, {"valid", true}};
        reply["tasks"] = empty;

        // The correct behaviour: this should throw, because "valid: true" with a non-array
        // "tasks" is a malformed reply. The LLMAgent caller catches std::exception and retries.
        EXPECT_THROW(
            {
                std::unique_ptr<LLMResponse> p;
                p = parseReply(reply);
                // If it didn't throw, also verify the result is not silently accepted as valid.
                auto* ans = dynamic_cast<Answer*>(p.get());
                ASSERT_NE(ans, nullptr);
                ADD_FAILURE()
                    << "Answer with valid:true and tasks: " << empty.dump()
                    << " was accepted. It has " << ans->tasks.size() << " task(s)."
                    << " Fix: validate that tasks is an array before iterating.";
            },
            std::exception)
            << "tasks: " << empty.dump();
    }
}
