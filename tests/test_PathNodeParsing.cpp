/**
 * Tests for sflow::tryParsePathNode -- the guard on both all_destination_paths ingests.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Two copies of the same loop parsed `all_destination_paths`: the background poll in
 * FlowLinkUsageCollector::fetchAllDestinationPaths and the POST handler in
 * HttpSession::handleInformAllDestinationPaths. Both indexed `nodeJson[0]` and `nodeJson[1]` on a
 * const json with no size or type check.
 *
 * That is not the same defect as an unchecked object key, and it is worse. nlohmann's two const
 * `operator[]` overloads are asymmetric:
 *
 *     // object key -- bounds-checked
 *     auto it = m_data.m_value.object->find(key);
 *     JSON_ASSERT(it != m_data.m_value.object->end());
 *
 *     // array index -- not checked at all
 *     if (JSON_HEDLEY_LIKELY(is_array())) { return m_data.m_value.array->operator[](idx); }
 *
 * So a missing object key aborts loudly in a Debug build, while a hop array shorter than two
 * elements is a heap read past the end in *every* build type -- and the enclosing
 * `catch (const std::exception&)` cannot see it, because it is not an exception. ASan reports it
 * as a heap-buffer-overflow. The HTTP copy takes its input from the sibling apps over the network.
 *
 * Found by an independent review of the commit that fixed the sibling ingests; that commit
 * claimed "the individual parses are all guarded now", and this was the path it had not reached.
 *
 * Both directions are covered. A guard that refused every hop would satisfy every rejection case
 * below and leave the twin with no destination paths at all -- which, in a component whose failure
 * mode is silence, would look exactly like a quiet network.
 */

#include <cstdint>
#include <optional>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/SFlowType.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

namespace
{

/// Parses a JSON literal as one hop.
std::optional<std::pair<uint64_t, uint32_t>>
hop(const char* text)
{
    return sflow::tryParsePathNode(json::parse(text));
}

} // namespace

// ---------------------------------------------------------------------------
// The shapes that used to read past the end of the array.
// ---------------------------------------------------------------------------

TEST(PathNodeParsingTest, AHopWithOnlyOneElementIsRefusedRatherThanReadPastTheEnd)
{
    // The exact trigger: `{"all_destination_paths": [[["10.0.0.1"]]]}`. Reaching for element 1
    // of a one-element array is a heap-buffer-overflow, not an exception.
    EXPECT_FALSE(hop(R"(["10.0.0.1"])").has_value());
    EXPECT_FALSE(hop(R"([5])").has_value());
}

TEST(PathNodeParsingTest, AnEmptyHopIsRefused)
{
    EXPECT_FALSE(hop("[]").has_value());
}

TEST(PathNodeParsingTest, AHopThatIsNotAnArrayIsRefused)
{
    EXPECT_FALSE(hop(R"("10.0.0.1")").has_value()) << "a bare string";
    EXPECT_FALSE(hop("5").has_value()) << "a bare number";
    EXPECT_FALSE(hop("{}").has_value()) << "an object";
    EXPECT_FALSE(hop("null").has_value());
}

// ---------------------------------------------------------------------------
// The accept path. Without these, refusing everything would pass this whole file.
// ---------------------------------------------------------------------------

TEST(PathNodeParsingTest, AHostHopCarriesADottedAddress)
{
    const auto parsed = hop(R"(["10.0.0.1", 3])");
    ASSERT_TRUE(parsed.has_value()) << "the guard refuses the shape it exists to accept";
    // Compared against the project's own converter rather than a literal, so this asserts the
    // value and not my belief about byte order.
    EXPECT_EQ(parsed->first, utils::ipStringToUint32("10.0.0.1"));
    EXPECT_EQ(parsed->second, 3u);
}

TEST(PathNodeParsingTest, ASwitchHopCarriesANumericId)
{
    const auto parsed = hop("[5, 3]");
    ASSERT_TRUE(parsed.has_value());
    EXPECT_EQ(parsed->first, 5u);
    EXPECT_EQ(parsed->second, 3u);
}

TEST(PathNodeParsingTest, AnInterfaceMayArriveAsAStringOrANumber)
{
    // Both spellings are in use across the two producers, which is why both copies of the old
    // loop had a string branch.
    const auto asNumber = hop("[5, 3]");
    const auto asString = hop(R"([5, "3"])");
    ASSERT_TRUE(asNumber.has_value());
    ASSERT_TRUE(asString.has_value());
    EXPECT_EQ(asNumber->second, asString->second);
}

TEST(PathNodeParsingTest, ExtraElementsBeyondTheFirstTwoAreIgnored)
{
    // Tolerated deliberately: a producer that grows a third field must not blank the topology.
    const auto parsed = hop(R"([5, 3, "whatever"])");
    ASSERT_TRUE(parsed.has_value());
    EXPECT_EQ(parsed->first, 5u);
    EXPECT_EQ(parsed->second, 3u);
}

// ---------------------------------------------------------------------------
// Values that used to throw, costing every path behind them.
// ---------------------------------------------------------------------------

TEST(PathNodeParsingTest, AnAddressThatIsNotAnAddressIsRefusedRatherThanThrown)
{
    // ipStringToUint32 threw std::invalid_argument here.
    EXPECT_FALSE(hop(R"(["not.an.ip", 3])").has_value());
    EXPECT_FALSE(hop(R"(["", 3])").has_value());
    EXPECT_FALSE(hop(R"(["10.0.0.999", 3])").has_value());
}

TEST(PathNodeParsingTest, AnInterfaceStringThatIsNotANumberIsRefusedRatherThanThrown)
{
    // std::stoi threw std::invalid_argument on "abc", and in the HTTP handler that surfaced as a
    // 500 -- the "you sent rubbish" reported as "I am broken" this codebase has removed twice
    // already.
    EXPECT_FALSE(hop(R"([5, "abc"])").has_value());
    EXPECT_FALSE(hop(R"([5, ""])").has_value());
}

TEST(PathNodeParsingTest, AnInterfaceStringWithTrailingJunkIsRefused)
{
    // stoi would have accepted "3x" as 3, silently attributing the hop to a different port.
    EXPECT_FALSE(hop(R"([5, "3x"])").has_value());
    EXPECT_FALSE(hop(R"([5, " 3"])").has_value());
}

TEST(PathNodeParsingTest, NegativeIdentifiersAreRefusedRatherThanWrapped)
{
    // Both fields are unsigned downstream; a negative would become an enormous dpid or port.
    EXPECT_FALSE(hop("[-1, 3]").has_value());
    EXPECT_FALSE(hop("[5, -1]").has_value());
}

TEST(PathNodeParsingTest, AHopFieldOfTheWrongTypeIsRefused)
{
    EXPECT_FALSE(hop("[null, 3]").has_value());
    EXPECT_FALSE(hop("[5, null]").has_value());
    EXPECT_FALSE(hop(R"([{"dpid": 5}, 3])").has_value());
    EXPECT_FALSE(hop("[5, [3]]").has_value());
}
