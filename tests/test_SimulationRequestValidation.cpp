/**
 * Tests for the simulation-request body check.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `POST /ndt/received_a_simulation_case` answered **202 Accepted** to anything at all -- including
 * the literal string `{not json` -- because the body was never parsed: it went straight into a curl
 * command line and whatever the simulator server replied (including nothing, when the body was
 * rubbish and it refused) was wrapped as `{"status": "..."}`. Two of the L2 contract failures were
 * exactly this. An application had no way to learn it had sent a malformed request.
 *
 * The five required fields are not this kernel's invention. Simulation-Platform-Manager's
 * `from_json(SimulationTask)` calls `j.at(f).get_to(std::string)` on each of them, so a body that
 * fails this check would have thrown over there -- in a process with no way to answer the caller.
 *
 * What this file does *not* test is escaping, because there is none: the body still reaches a shell
 * unescaped. That is deliberately deferred and covers every southbound curl call, not just this one.
 * A test asserting a dangerous body is rejected would be worse than no test, because it would read
 * as a claim that the injection is handled. So there is one test in the other direction, pinning
 * that validation is shape-only, with the reason written down.
 */

#include <limits>
#include <optional>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/application_management/SimulationRequestManager.hpp"
#include "utils/Utils.hpp"

using nlohmann::json;

namespace
{

/// The body Energy-Saving-App actually sends (`to_json(SimulationRequest)` in its types.hpp).
json
validBody()
{
    return json{{"simulator", "MySimulator"},
                {"version", "1.0.0"},
                {"app_id", "1"},
                {"case_id", "case_123"},
                {"inputfile", "/srv/nfs/sim/1/case_123.json"}};
}

} // namespace

TEST(SimulationRequestValidationTest, AcceptsTheBodyTheRealCallerSends)
{
    // If this fails, Energy-Saving-App's simulation requests start being rejected -- the one
    // outcome worse than the bug being fixed.
    EXPECT_FALSE(SimulationRequestManager::validateRequestBody(validBody().dump()).has_value())
        << "rejected the documented request shape";
}

TEST(SimulationRequestValidationTest, RejectsTheBodyThatUsedToReturn202)
{
    // The L2 failure received_a_simulation_case__malformed, verbatim.
    const auto problem = SimulationRequestManager::validateRequestBody("{not json");
    ASSERT_TRUE(problem.has_value());
    EXPECT_NE(problem->find("not valid JSON"), std::string::npos) << *problem;
}

TEST(SimulationRequestValidationTest, TheRequiredFieldListIsExactlyWhatTheSimulatorNeeds)
{
    // Spelled out literally, because the two tests below derive their expectations *from*
    // requiredRequestFields(): if a field were dropped from that list they would both still pass
    // while the endpoint quietly stopped checking it. Verified against
    // Simulation-Platform-Manager's from_json(SimulationTask) and section 17 of doc/2026-01-02_ndt_api.md.
    const std::vector<std::string> expected = {"simulator", "version", "app_id", "case_id",
                                               "inputfile"};
    EXPECT_EQ(SimulationRequestManager::requiredRequestFields(), expected);
}

TEST(SimulationRequestValidationTest, RejectsAnEmptyObjectAndNamesEveryMissingField)
{
    // The L2 failure received_a_simulation_case__missing_fields. Naming all five matters: an
    // application with three mistakes should not need three round trips to find them.
    const auto problem = SimulationRequestManager::validateRequestBody("{}");
    ASSERT_TRUE(problem.has_value());
    for (const std::string& field : SimulationRequestManager::requiredRequestFields())
    {
        EXPECT_NE(problem->find(field), std::string::npos)
            << "did not mention missing field '" << field << "': " << *problem;
    }
}

TEST(SimulationRequestValidationTest, EachRequiredFieldIsIndividuallyRequired)
{
    // A single check of `{}` would pass even if only one field were actually enforced.
    for (const std::string& omitted : SimulationRequestManager::requiredRequestFields())
    {
        json body = validBody();
        body.erase(omitted);
        const auto problem = SimulationRequestManager::validateRequestBody(body.dump());
        ASSERT_TRUE(problem.has_value()) << "accepted a body with no '" << omitted << "'";
        EXPECT_NE(problem->find(omitted), std::string::npos)
            << "rejected but blamed the wrong field: " << *problem;
    }
}

TEST(SimulationRequestValidationTest, RejectsNullAsAbsentRatherThanForwardingTheWordNull)
{
    // json::contains() and find() both locate a null, so a presence-only check would pass it
    // through and Simulation-Platform-Manager's get_to(std::string) would throw on it.
    json body = validBody();
    body["case_id"] = nullptr;
    const auto problem = SimulationRequestManager::validateRequestBody(body.dump());
    ASSERT_TRUE(problem.has_value());
    EXPECT_NE(problem->find("case_id"), std::string::npos) << *problem;

    // Reported as *missing*, not as a type error. Asserting the bucket rather than just the
    // rejection, because dropping the is_null() check leaves null falling through to the
    // is_string() branch -- which still rejects, so a rejection-only assertion cannot see the
    // difference (it survived that mutation). And the bucket is the whole diagnostic here:
    // `"case_id": null` means the caller supplied no value, so "missing required field" is what
    // they need to read, not "wrong type: case_id (null, expected string)".
    EXPECT_NE(problem->find("missing"), std::string::npos)
        << "a null field should be reported as missing: " << *problem;
}

TEST(SimulationRequestValidationTest, RejectsAFieldOfTheWrongTypeAndSaysWhatItGot)
{
    // app_id: "1" is documented, but 1 is the mistake a caller actually makes. SPM's
    // get_to(std::string) throws on a number, so accepting it here only relocates the failure.
    json body = validBody();
    body["app_id"] = 1;
    const auto problem = SimulationRequestManager::validateRequestBody(body.dump());
    ASSERT_TRUE(problem.has_value());
    EXPECT_NE(problem->find("app_id"), std::string::npos) << *problem;
    EXPECT_NE(problem->find("number"), std::string::npos)
        << "the type it got is the whole diagnostic: " << *problem;
    EXPECT_NE(problem->find("string"), std::string::npos)
        << "should say what was expected: " << *problem;
}

TEST(SimulationRequestValidationTest, ReportsMissingAndWrongTypedFieldsTogether)
{
    json body = validBody();
    body.erase("inputfile");
    body["version"] = 3;
    const auto problem = SimulationRequestManager::validateRequestBody(body.dump());
    ASSERT_TRUE(problem.has_value());
    EXPECT_NE(problem->find("inputfile"), std::string::npos) << *problem;
    EXPECT_NE(problem->find("version"), std::string::npos) << *problem;
}

TEST(SimulationRequestValidationTest, RejectsValidJsonThatIsNotAnObject)
{
    // These parse, so a parse-only check accepts them, and then find() on a non-object throws
    // inside the handler -- turning a 400 into a 500. The array case is the plausible one: a caller
    // batching several cases.
    const std::vector<std::string> notObjects = {"[]", R"([{"simulator":"x"}])", R"("a string")",
                                                 "42", "null", "true"};
    for (const std::string& body : notObjects)
    {
        const auto problem = SimulationRequestManager::validateRequestBody(body);
        ASSERT_TRUE(problem.has_value()) << "accepted: " << body;
        EXPECT_NE(problem->find("object"), std::string::npos)
            << "for " << body << " the reason should say an object was expected: " << *problem;
    }
}

TEST(SimulationRequestValidationTest, IgnoresExtraFields)
{
    // The kernel forwards the body verbatim; deciding what SPM may accept is not its job, and
    // rejecting unknown keys would break the next field anyone adds there.
    json body = validBody();
    body["priority"] = "high";
    body["nested"] = json{{"a", 1}};
    EXPECT_FALSE(SimulationRequestManager::validateRequestBody(body.dump()).has_value());
}

TEST(SimulationRequestValidationTest, NeverThrowsWhateverItIsGiven)
{
    // It runs inside a request handler whose non-json outer catch answers 500. A validator that
    // throws for some inputs would reintroduce the bug it exists to fix.
    const std::vector<std::string> nasty = {"",
                                            "{",
                                            "}",
                                            "{not json",
                                            "\xff\xfe",
                                            std::string("{\"simulator\":\"") + std::string(4096, 'a')
                                                + "\"}",
                                            R"({"simulator":{"deep":{"deeper":[1,2,3]}}})",
                                            std::string(200, '[')};
    for (const std::string& body : nasty)
    {
        EXPECT_NO_THROW({
            const auto problem = SimulationRequestManager::validateRequestBody(body);
            EXPECT_TRUE(problem.has_value()) << "accepted: '" << body.substr(0, 40) << "'";
        }) << "threw on: '"
           << body.substr(0, 40) << "'";
    }
}

TEST(SimulationRequestValidationTest, ChecksShapeOnlyAndIsNotAnInjectionDefence)
{
    // Deliberate, and the reason it is a test rather than a comment: the body still reaches a shell
    // unescaped in requestSimulation(), and a future reader must not mistake the 400 for
    // sanitisation. A shell metacharacter inside a well-formed string field is accepted here.
    //
    // If the deferred injection work ever lands, this test SHOULD fail. Change it then -- do not
    // "fix" it by rejecting quotes here, which would break legitimate paths and leave the other 22
    // call sites exposed anyway.
    json body = validBody();
    body["case_id"] = R"(case'; touch /tmp/pwned; #)";
    EXPECT_FALSE(SimulationRequestManager::validateRequestBody(body.dump()).has_value())
        << "validation now rejects shell metacharacters -- see the comment above before changing "
           "this expectation";
}

// --- app_id parsing for POST /ndt/simulation_completed.
//
// The handler does std::stoi(j.at("app_id").get<string>()). Malformed JSON and a missing or
// non-string app_id already answer 400 through the json::exception handler, but std::stoi("abc")
// throws std::invalid_argument, which does not -- so a mistyped app_id was reported as 500 Internal
// Server Error. Same defect as `?dpid=abc`, same fix.
//
// ⚠️ WHAT THESE DO NOT COVER, stated because the suite name invites the wrong conclusion. These
// exercise `utils::tryParseUint64` only. **Nothing here reaches HttpSession::handleSimulationCompleted,
// so the fix itself is untested**: a review reintroduced the original
// `const int appId = std::stoi(appIdText);` and all 207 tests stayed green, and deleting just the
// INT_MAX bound also survived. What is pinned below is that the parser rejects the values that used
// to produce a 500 or a silent truncation -- necessary, and not sufficient.
//
// Closing the gap needs a way to drive a handler, which HttpSession has none of: it is constructed
// from a live socket and eleven collaborators. That is a seam to design, tracked as its own item,
// and inventing a shortcut for this one endpoint would leave the other forty untested while looking
// finished. [Co-developed with claude code -- Adam]

TEST(SimulationCompletedAppIdTest, RejectsWhatStoiWouldHaveThrownOn)
{
    EXPECT_FALSE(utils::tryParseUint64("abc").has_value());
    EXPECT_FALSE(utils::tryParseUint64("").has_value());
}

TEST(SimulationCompletedAppIdTest, RejectsWhatStoiWouldHaveSilentlyTruncated)
{
    // Worse than the throw: stoi("1abc") is 1 and stoi("-1") is -1, so a typo forwards the result
    // to a different application, or to none, with a 200 OK.
    EXPECT_FALSE(utils::tryParseUint64("1abc").has_value());
    EXPECT_FALSE(utils::tryParseUint64("-1").has_value());
    EXPECT_FALSE(utils::tryParseUint64(" 1").has_value());
}

TEST(SimulationCompletedAppIdTest, AcceptsTheDocumentedForm)
{
    // app_id is documented as a string holding a number, and that is what app_register returns.
    EXPECT_EQ(utils::tryParseUint64("1"), std::optional<uint64_t>(1));
    EXPECT_EQ(utils::tryParseUint64("42"), std::optional<uint64_t>(42));
}

TEST(SimulationCompletedAppIdTest, SomethingTooBigForIntParsesSoTheRangeCheckIsWhatMustRejectIt)
{
    // The parser's half of the contract: 2^32 is a perfectly good uint64, so tryParseUint64 accepts
    // it and the handler's INT_MAX bound is the only thing standing between it and a static_cast
    // that wraps to a negative id and looks up the wrong application.
    //
    // An earlier version of this test then asserted `4294967296 > INT_MAX`, which is arithmetic on
    // two literals -- true for any implementation of anything, and green with the bound deleted.
    // Removed rather than reworded: the bound lives in the handler and cannot be reached from here,
    // and an assertion that looks like it covers something it cannot is worse than an admitted gap.
    // See the note above this suite. [Co-developed with claude code -- Adam]
    EXPECT_EQ(utils::tryParseUint64("4294967296"), std::optional<uint64_t>(4294967296ULL));
    EXPECT_EQ(utils::tryParseUint64("2147483648"), std::optional<uint64_t>(2147483648ULL))
        << "INT_MAX + 1 must still parse; rejecting it here would hide the handler's own bound";
}
