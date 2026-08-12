/**
 * Tests for the non-throwing query-parameter parsers.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The REST layer had no unit tests at all -- an audit of the HTTP entry point called it "naked",
 * and this is the part of it most exposed to malformed input. Two of the L2 contract failures were
 * exactly this: `?src_ip=not.an.ip` threw out of ipStringToUint32 and `?dpid=abc` threw out of
 * std::stoull, and HttpSession's outermost catch turned both into 500 Internal Server Error. A
 * caller who mistyped a parameter was told the kernel had broken.
 *
 * The parsing is where the interesting cases live, so it is what is tested; the handlers then only
 * have to choose a status code.
 */

#include <optional>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "utils/Utils.hpp"

TEST(TryIpStringToUint32Test, ParsesDottedQuads)
{
    // Round-tripped rather than compared against a hand-computed constant, so the test cannot
    // disagree with ipToString about byte order without one of them being wrong.
    const std::vector<std::string> valid = {"10.0.0.1", "10.0.0.97", "192.168.123.20", "127.0.0.1",
                                            "0.0.0.0", "255.255.255.255"};
    for (const std::string& text : valid)
    {
        const auto parsed = utils::tryIpStringToUint32(text);
        ASSERT_TRUE(parsed.has_value()) << text;
        EXPECT_EQ(utils::ipToString(*parsed), text);
    }
}

TEST(TryIpStringToUint32Test, RejectsTheStringThatUsedToProduceA500)
{
    // The L2 failure get_path_switch_count__bad_ip, verbatim.
    EXPECT_FALSE(utils::tryIpStringToUint32("not.an.ip").has_value());
}

TEST(TryIpStringToUint32Test, RejectsEmptyRatherThanTreatingItAsZero)
{
    // An absent parameter arrives as "". inet_aton("") fails, but relying on that is fragile and
    // "" must never become 0.0.0.0 -- a query for a missing IP would then match host 0.
    EXPECT_FALSE(utils::tryIpStringToUint32("").has_value());
}

TEST(TryIpStringToUint32Test, RejectsOutOfRangeOctetsAndGarbage)
{
    const std::vector<std::string> invalid = {"256.0.0.1", "10.0.0.999", "10.0.0.-1",
                                              "hello", "10.0.0.1;rm -rf /", " 10.0.0.1"};
    for (const std::string& text : invalid)
    {
        EXPECT_FALSE(utils::tryIpStringToUint32(text).has_value()) << "accepted: '" << text << "'";
    }
}

TEST(TryIpStringToUint32Test, TheShortFormsInetAtonAcceptsAreDocumentedNotAssumed)
{
    // inet_aton deliberately accepts "10.1" as 10.0.0.1 and a bare "1" as 0.0.0.1. That is
    // surprising for an API parameter, but it is long-standing behaviour that callers may rely on,
    // so the test records it rather than pretending otherwise. If it ever needs tightening, this is
    // the line that will fail and say so.
    EXPECT_TRUE(utils::tryIpStringToUint32("10.1").has_value());
    EXPECT_TRUE(utils::tryIpStringToUint32("1").has_value());
}

TEST(TryParseUint64Test, ParsesPlainDigits)
{
    EXPECT_EQ(utils::tryParseUint64("0"), std::optional<uint64_t>(0));
    EXPECT_EQ(utils::tryParseUint64("1"), std::optional<uint64_t>(1));
    EXPECT_EQ(utils::tryParseUint64("10"), std::optional<uint64_t>(10));
    EXPECT_EQ(utils::tryParseUint64("999999999999"), std::optional<uint64_t>(999999999999ULL));
    EXPECT_EQ(utils::tryParseUint64("18446744073709551615"),
              std::optional<uint64_t>(18446744073709551615ULL));
}

TEST(TryParseUint64Test, RejectsTheStringThatUsedToProduceA500)
{
    // The L2 failure inform_switch_entered__bad_dpid.
    EXPECT_FALSE(utils::tryParseUint64("abc").has_value());
}

TEST(TryParseUint64Test, IsStricterThanStoullSoAMistypedDpidIsRefused)
{
    // std::stoull would read all of these as a number, which is worse than throwing: "12abc"
    // becomes 12 and "-1" wraps to 18446744073709551615, so a typo silently addresses a different
    // switch -- or every switch, since 2^64-1 is not one.
    EXPECT_FALSE(utils::tryParseUint64("12abc").has_value()) << "trailing junk accepted";
    EXPECT_FALSE(utils::tryParseUint64("-1").has_value()) << "negative accepted and wrapped";
    EXPECT_FALSE(utils::tryParseUint64("+1").has_value()) << "leading sign accepted";
    EXPECT_FALSE(utils::tryParseUint64(" 1").has_value()) << "leading whitespace accepted";
    EXPECT_FALSE(utils::tryParseUint64("1 ").has_value()) << "trailing whitespace accepted";
    EXPECT_FALSE(utils::tryParseUint64("0x1").has_value()) << "hex accepted";
    EXPECT_FALSE(utils::tryParseUint64("1.0").has_value()) << "decimal point accepted";
}

TEST(TryParseUint64Test, RefusesSomethingTooLargeRatherThanWrapping)
{
    // All digits, so the character check passes and stoull's out_of_range is what has to be caught.
    EXPECT_FALSE(utils::tryParseUint64("18446744073709551616").has_value()) << "2^64";
    EXPECT_FALSE(utils::tryParseUint64(std::string(40, '9')).has_value()) << "forty nines";
}

TEST(TryParseUint64Test, RejectsEmpty)
{
    // An absent parameter. Must not become dpid 0, which is the value hosts carry in the topology.
    EXPECT_FALSE(utils::tryParseUint64("").has_value());
}

TEST(TryParseUint64Test, DoesNotThrowOnAnythingItRejects)
{
    // The whole point: these run inside a request handler whose outer catch turns any escape into
    // 500. A parser that throws for some inputs and returns nullopt for others would leave the bug
    // half-fixed.
    const std::vector<std::string> nasty = {"",          "abc",   "-1",    "+1",
                                            "0x1",       "1.0",   "  ",    "\t9",
                                            "99999999999999999999999999", "12abc", "1e5"};
    for (const std::string& text : nasty)
    {
        EXPECT_NO_THROW({
            const auto parsed = utils::tryParseUint64(text);
            EXPECT_FALSE(parsed.has_value()) << "accepted: '" << text << "'";
        }) << "threw on: '"
           << text << "'";
    }
}

// --- utils::queryParam: the splitter that feeds every parser above.

/**
 * [Co-developed with claude code -- Adam]
 * This had no tests, which is the real finding behind the http-routing review's M3. It was a lambda
 * written out five times inside HttpSession, so there was nowhere to point a test at; the value
 * parsers above were covered and the thing that extracts their input was not, despite handling
 * untrusted URLs. These pin the behaviours the handlers actually depend on.
 */
TEST(QueryParamTest, ReadsAValueByName)
{
    EXPECT_EQ(utils::queryParam("/ndt/get_nickname?dpid=3", "dpid"), "3");
}

TEST(QueryParamTest, ReadsAValueThatIsNotTheFirstOrTheLast)
{
    const std::string_view t = "/ndt/x?a=1&dpid=42&z=9";
    EXPECT_EQ(utils::queryParam(t, "a"), "1");
    EXPECT_EQ(utils::queryParam(t, "dpid"), "42");
    EXPECT_EQ(utils::queryParam(t, "z"), "9");
}

TEST(QueryParamTest, AnAbsentKeyAndAnAbsentQueryStringBothGiveEmpty)
{
    EXPECT_EQ(utils::queryParam("/ndt/x?a=1", "dpid"), "");
    EXPECT_EQ(utils::queryParam("/ndt/x", "dpid"), "");
    EXPECT_EQ(utils::queryParam("", "dpid"), "");
}

TEST(QueryParamTest, AnEmptyValueIsIndistinguishableFromAMissingOne)
{
    // Deliberate, and depended upon: the handlers treat "missing" and "empty" alike, answering
    // "missing parameter" for both. If that ever needs to change this test is the place it breaks.
    EXPECT_EQ(utils::queryParam("/ndt/x?dpid=", "dpid"), "");
    EXPECT_EQ(utils::queryParam("/ndt/x?dpid=&a=1", "dpid"), "");
}

TEST(QueryParamTest, TheValueStopsAtTheNextAmpersand)
{
    // Without this a handler would receive "3&mac=aa:bb" and hand it to tryParseUint64, which
    // rejects it -- a valid request reported as malformed.
    EXPECT_EQ(utils::queryParam("/ndt/x?dpid=3&mac=aa:bb:cc:dd:ee:ff", "dpid"), "3");
}

TEST(QueryParamTest, KeysAreComparedExactlyAndPrefixesDoNotMatch)
{
    // "dpid" must not be answered by "dpid_str", nor by a key that merely ends with it.
    EXPECT_EQ(utils::queryParam("/ndt/x?dpid_str=7", "dpid"), "");
    EXPECT_EQ(utils::queryParam("/ndt/x?xdpid=7", "dpid"), "");
    EXPECT_EQ(utils::queryParam("/ndt/x?DPID=7", "dpid"), "") << "no case folding";
}

TEST(QueryParamTest, APairWithNoEqualsIsSkippedAndOnlyStopsTheScanWhenNoEqualsRemains)
{
    // [Co-developed with claude code -- Adam]
    // I first asserted the opposite here -- that a malformed pair ends the search -- and wrote that
    // into the function's own documentation. It is wrong, and this test said so immediately. The
    // scan's find('=') looks past "broken" to the '=' in "dpid=3", the key compares as
    // "broken&dpid" and fails, then find('&') steps over the malformed pair and the next round
    // matches. So it is skipped.
    EXPECT_EQ(utils::queryParam("/ndt/x?broken&dpid=3", "dpid"), "3");
    EXPECT_EQ(utils::queryParam("/ndt/x?dpid=3&broken", "dpid"), "3")
        << "a malformed pair after the match must not affect it";

    // What does end the scan: no '=' anywhere in the remainder.
    EXPECT_EQ(utils::queryParam("/ndt/x?broken", "dpid"), "");
    EXPECT_EQ(utils::queryParam("/ndt/x?a=1&broken", "dpid"), "");
}

TEST(QueryParamTest, NoPercentDecodingAndNoPlusAsSpace)
{
    // Stated so a caller cannot assume otherwise: the value is handed back raw.
    EXPECT_EQ(utils::queryParam("/ndt/x?name=a%20b", "name"), "a%20b");
    EXPECT_EQ(utils::queryParam("/ndt/x?name=a+b", "name"), "a+b");
}

TEST(QueryParamTest, AQuestionMarkInsideAValueDoesNotRestartParsing)
{
    EXPECT_EQ(utils::queryParam("/ndt/x?a=1?2&dpid=3", "dpid"), "3");
    EXPECT_EQ(utils::queryParam("/ndt/x?a=1?2&dpid=3", "a"), "1?2");
}

// ---------------------------------------------------------------------------
// tryParseHexUint64 -- the base-16 twin, for dpids as the control plane writes them.
//
// [Co-developed with claude code -- Adam]
// Added with the fix for the poll path terminating the kernel: updateSwitches used
// `stoull(dpidStr, nullptr, 16)`, and stoull throws std::invalid_argument on an empty or
// non-hex string. That is not a json::exception, so it escaped every catch between there and
// the run() thread's entry point. These cases are the contract that replaced it.
// ---------------------------------------------------------------------------

TEST(TryParseHexUint64Test, ParsesHexDigitsInEitherCase)
{
    EXPECT_EQ(utils::tryParseHexUint64("0"), std::optional<uint64_t>(0));
    EXPECT_EQ(utils::tryParseHexUint64("1"), std::optional<uint64_t>(1));
    EXPECT_EQ(utils::tryParseHexUint64("a"), std::optional<uint64_t>(10));
    EXPECT_EQ(utils::tryParseHexUint64("A"), std::optional<uint64_t>(10));
    EXPECT_EQ(utils::tryParseHexUint64("ff"), std::optional<uint64_t>(255));
    // The shape Ryu actually sends: a 16-digit zero-padded dpid.
    EXPECT_EQ(utils::tryParseHexUint64("0000000000000001"), std::optional<uint64_t>(1));
    EXPECT_EQ(utils::tryParseHexUint64("000000000000000a"), std::optional<uint64_t>(10));
    EXPECT_EQ(utils::tryParseHexUint64("ffffffffffffffff"),
              std::optional<uint64_t>(18446744073709551615ULL));
}

TEST(TryParseHexUint64Test, RejectsTheStringsThatUsedToTerminateTheKernel)
{
    // `switchInfoJson.value("dpid", "")` yields "" for an entry with no dpid, and stoull("")
    // throws std::invalid_argument on the poll thread.
    EXPECT_FALSE(utils::tryParseHexUint64("").has_value());
    EXPECT_FALSE(utils::tryParseHexUint64("not-a-dpid").has_value());
}

TEST(TryParseHexUint64Test, IsStricterThanStoullSoAMistypedDpidIsRefused)
{
    // Each of these is something stoull(s, nullptr, 16) accepts, silently producing a
    // *different switch* than the string names.
    EXPECT_FALSE(utils::tryParseHexUint64("1z").has_value()) << "trailing junk accepted";
    EXPECT_FALSE(utils::tryParseHexUint64("-1").has_value()) << "negative accepted and wrapped";
    EXPECT_FALSE(utils::tryParseHexUint64("+1").has_value()) << "leading sign accepted";
    EXPECT_FALSE(utils::tryParseHexUint64(" 1").has_value()) << "leading whitespace accepted";
    EXPECT_FALSE(utils::tryParseHexUint64("1 ").has_value()) << "trailing whitespace accepted";
    // No 0x prefix: the control plane does not send one, and accepting it would make the bare
    // string "0x" parse as zero.
    EXPECT_FALSE(utils::tryParseHexUint64("0x1").has_value()) << "0x prefix accepted";
}

TEST(TryParseHexUint64Test, RefusesRatherThanWrappingOnOverflow)
{
    EXPECT_FALSE(utils::tryParseHexUint64("10000000000000000").has_value())
        << "17 hex digits is more than 64 bits; wrapping would name a real switch";
}
