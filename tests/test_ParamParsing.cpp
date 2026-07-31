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
