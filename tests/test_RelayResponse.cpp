/**
 * Tests for reading the smart-plug gateway's reply to a power request.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `setSwitchPowerState` scraped a status string out of the gateway's HTML, **logged it, and then
 * updated the graph to whatever state the caller had asked for** -- so the twin reported the request
 * rather than the outcome. The curl had no `--fail`, no `%{http_code}` and no `--max-time`, so an
 * unreachable gateway returned an empty string and the code went on to mark the switch powered off.
 * It returned `true` in every case except an exception.
 *
 * This is TESTBED-only, which is the reason it matters rather than a reason it does not: TESTBED is
 * where the switches are real. A twin saying a switch is off while it is still forwarding is the
 * failure mode this whole codebase keeps circling back to.
 *
 * The verdict is keyed on the HTTP status, not on the HTML, because the status is a contract and the
 * page is a design. The extracted text is still reported -- it is what a human needs when the status
 * is 200 and the plug still did not move.
 *
 * A 200 does not prove the plug switched, and the code does not claim it does. It proves the gateway
 * accepted the request, which is the strongest claim available, and `pingWorker` corrects the graph
 * within a second if the plug did not actually operate. Acting on a *failed* request is what had no
 * recovery path.
 */

#include <string>

#include <gtest/gtest.h>

#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

namespace
{

/// Reaches the protected static without constructing the manager, which would need a topology
/// monitor, a classifier and background threads. Same pattern as LivenessProbe.
class RelayReader : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::buildRelayPowerCommand;
    using DeviceConfigurationAndPowerManager::interpretRelayResponse;
    using DeviceConfigurationAndPowerManager::RelayResult;
};

/// A plug mapping of the shape switchSmartPlugTable holds.
SwitchInfo plug()
{
    SwitchInfo si;
    si.switchIp = "192.168.123.11";
    si.plugIp = "172.25.166.135";
    si.plugIdx = 3;
    return si;
}

/// What curl produces: body, newline, status. Mirrors `-w '\n%{http_code}'`.
std::string
reply(const std::string& body, const std::string& status)
{
    return body + "\n" + status;
}

/// A realistic gateway page. The status text sits between the second '>' and the next '<'.
const char* const kOnPage = "<html><body>Relay switched ON</body></html>";

} // namespace

TEST(RelayResponseTest, A200IsAcceptedAndTheStatusTextIsReported)
{
    const auto result = RelayReader::interpretRelayResponse(reply(kOnPage, "200"));
    EXPECT_TRUE(result.ok);
    EXPECT_EQ(result.detail, "Relay switched ON")
        << "the text a human reads when the status is 200 and the plug did not move";
}

TEST(RelayResponseTest, AnyTwoHundredSeriesStatusIsAccepted)
{
    for (const std::string code : {"200", "201", "202", "204"})
    {
        EXPECT_TRUE(RelayReader::interpretRelayResponse(reply(kOnPage, code)).ok) << code;
    }
}

TEST(RelayResponseTest, NoResponseAtAllIsRefusedRatherThanTreatedAsSuccess)
{
    // The measured case. Bare `curl -s` against an unreachable gateway prints nothing, and the old
    // code went straight on to setVertexDown -- so the twin reported a switch powered off that
    // nobody had touched.
    const auto result = RelayReader::interpretRelayResponse("");
    EXPECT_FALSE(result.ok);
    EXPECT_NE(result.detail.find("gateway"), std::string::npos) << result.detail;
}

TEST(RelayResponseTest, CurlsOwnNoResponseCodeIsRefused)
{
    // curl reports 000 for connection refused, DNS failure and timeout. Numerically it is not a 2xx,
    // but it deserves its own message: "HTTP 000" would send someone looking at the gateway's logs
    // for a request that never arrived.
    const auto result = RelayReader::interpretRelayResponse(reply("", "000"));
    EXPECT_FALSE(result.ok);
    EXPECT_NE(result.detail.find("could not reach"), std::string::npos) << result.detail;
    EXPECT_EQ(result.detail.find("HTTP 000"), std::string::npos)
        << "reported as an HTTP status when no HTTP response happened: " << result.detail;
}

TEST(RelayResponseTest, AnErrorStatusIsRefusedAndNamed)
{
    for (const std::string code : {"400", "401", "403", "404", "500", "502", "503"})
    {
        const auto result = RelayReader::interpretRelayResponse(reply("<html>oops</html>", code));
        EXPECT_FALSE(result.ok) << code;
        EXPECT_NE(result.detail.find(code), std::string::npos)
            << "did not say which status: " << result.detail;
    }
}

TEST(RelayResponseTest, AThreeHundredIsNotSuccess)
{
    // A redirect means the request was not serviced where we sent it. Worth its own test because
    // `statusCode[0] != '2'` is the kind of check that gets loosened to `< '4'`.
    EXPECT_FALSE(RelayReader::interpretRelayResponse(reply("", "302")).ok);
    EXPECT_FALSE(RelayReader::interpretRelayResponse(reply("", "301")).ok);
}

TEST(RelayResponseTest, AResponseWithNoStatusLineIsRefused)
{
    // Cannot happen from the command we build, so if it happens the output came from something else
    // -- which is exactly when guessing is worst.
    const auto result = RelayReader::interpretRelayResponse("<html>no status appended</html>");
    EXPECT_FALSE(result.ok);
    EXPECT_NE(result.detail.find("status line"), std::string::npos) << result.detail;
}

TEST(RelayResponseTest, AnEmptyBodyWithA200IsStillAccepted)
{
    // Some gateways answer 204 or an empty 200. The status is the contract; an empty page is not a
    // failure, and refusing it would break a working deployment.
    const auto result = RelayReader::interpretRelayResponse(reply("", "200"));
    EXPECT_TRUE(result.ok);
}

TEST(RelayResponseTest, HtmlWithoutTheExpectedShapeStillSucceedsWithTheWholeBody)
{
    // The text extraction is a convenience. If the page is redesigned the verdict must not change,
    // and the log should carry whatever there is rather than an empty string.
    const auto result = RelayReader::interpretRelayResponse(reply("switched on", "200"));
    EXPECT_TRUE(result.ok);
    EXPECT_EQ(result.detail, "switched on");
}

TEST(RelayResponseTest, AMultiLineBodyKeepsItsStatusAtTheEnd)
{
    // Real HTML has newlines, and the status is appended after all of them -- so the split must be on
    // the LAST newline. Splitting on the first would read a chunk of HTML as the status code.
    const std::string body = "<html>\n<body>\nRelay switched OFF\n</body>\n</html>";
    const auto result = RelayReader::interpretRelayResponse(reply(body, "200"));
    EXPECT_TRUE(result.ok) << "read part of the HTML as the status code: " << result.detail;
}

TEST(RelayResponseTest, ANonNumericStatusIsRefused)
{
    for (const std::string junk : {"OK", "2", "20", "2000", "abc", " 200"})
    {
        EXPECT_FALSE(RelayReader::interpretRelayResponse(reply(kOnPage, junk)).ok)
            << "accepted '" << junk << "' as a status";
    }
}

TEST(RelayResponseTest, NeverThrowsOnAnythingTheGatewayCouldSend)
{
    // It runs inside a request handler. The handler does catch, but an exception here would answer
    // 500 for a gateway problem the caller can do nothing about.
    const std::vector<std::string> nasty = {"",
                                            "\n",
                                            "\n\n",
                                            "200",
                                            "\n200",
                                            std::string("\xff\xfe") + "\n200",
                                            std::string(64 * 1024, 'x') + "\n200",
                                            "<html><body></body></html>\n200",
                                            "><\n200",
                                            ">><\n200"};
    for (const std::string& response : nasty)
    {
        EXPECT_NO_THROW(RelayReader::interpretRelayResponse(response))
            << "threw on: '" << response.substr(0, 32) << "'";
    }
}

// ---------------------------------------------------------------------------
// The request itself.
//
// [Co-developed with claude code -- Adam]
// interpretRelayResponse can only be right about a reply that was produced by the request it
// expects. Until now nothing asserted the request: the reachable TESTBED path built its own with
// `curl -s` and no status at all, and read nothing back -- so these tests, and the honest
// implementation they cover, were pinning an overload with zero call sites while the live path
// answered `rc == 0`. These cases are the other half of that contract.
// ---------------------------------------------------------------------------

TEST(RelayPowerCommandTest, CarriesTheThreeParametersTheGatewayIsKnownToAccept)
{
    const std::string cmd = RelayReader::buildRelayPowerCommand("localhost", plug(), "off");

    EXPECT_NE(cmd.find("ip=172.25.166.135"), std::string::npos) << cmd;
    EXPECT_NE(cmd.find("index=3"), std::string::npos) << cmd;
    EXPECT_NE(cmd.find("method=off"), std::string::npos) << cmd;
    // The power report sends resource=outlet to this same endpoint. The unreachable overload
    // whose logic this replaced had dropped it, so adopting that code unchanged would have
    // altered the request the testbed's gateway receives -- silently, because `curl -s` prints
    // nothing and a reply to a malformed request looks like a reply to a refused one.
    EXPECT_NE(cmd.find("resource=outlet"), std::string::npos)
        << "the parameter the working call to this gateway sends is missing: " << cmd;
    EXPECT_NE(cmd.find("http://localhost:8000/relay"), std::string::npos) << cmd;
    // The method. Added after a review pointed out it was the one wire attribute nothing pinned:
    // changing -X POST to -X GET left all of these green, and the gateway's relay endpoint is a
    // POST. [Co-developed with claude code -- Adam]
    EXPECT_NE(cmd.find("-X POST"), std::string::npos)
        << "the request method is not pinned, so a change to GET would pass silently: " << cmd;
}

TEST(RelayPowerCommandTest, AsksForTheHttpStatusInterpretRelayResponseReadsItsVerdictFrom)
{
    const std::string cmd = RelayReader::buildRelayPowerCommand("localhost", plug(), "on");

    // Without -w there is no status line, and interpretRelayResponse answers
    // "response carried no HTTP status line" for every reply, including the successful ones.
    EXPECT_NE(cmd.find("%{http_code}"), std::string::npos)
        << "no status requested, so every verdict below is decided on the wrong evidence: " << cmd;
    EXPECT_NE(cmd.find("-w"), std::string::npos) << cmd;
    // On its own line, because that is where interpretRelayResponse splits.
    EXPECT_NE(cmd.find("\\n%{http_code}"), std::string::npos) << cmd;
}

TEST(RelayPowerCommandTest, IsBoundedInTimeBecauseItRunsInsideARequestHandler)
{
    const std::string cmd = RelayReader::buildRelayPowerCommand("localhost", plug(), "on");
    EXPECT_NE(cmd.find("--max-time"), std::string::npos)
        << "an unresponsive gateway stalls the HTTP handler indefinitely: " << cmd;
}

TEST(RelayPowerCommandTest, TheStatusLineSurvivesTheRoundTripIntoAVerdict)
{
    // The two halves have to agree, and nothing else checks that they do: build the command,
    // then feed interpretRelayResponse what curl would produce under it.
    const std::string cmd = RelayReader::buildRelayPowerCommand("localhost", plug(), "on");
    ASSERT_NE(cmd.find("\\n%{http_code}"), std::string::npos);

    EXPECT_TRUE(RelayReader::interpretRelayResponse(reply(kOnPage, "200")).ok);
    EXPECT_FALSE(RelayReader::interpretRelayResponse(reply(kOnPage, "500")).ok)
        << "a gateway error read as success is exactly what `return rc == 0` did";
}
