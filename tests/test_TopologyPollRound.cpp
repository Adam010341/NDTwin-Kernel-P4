/**
 * A control-plane poll round must say how complete it was.
 *
 * [Co-developed with claude code -- Adam]
 *
 * doc/KNOWN-ISSUES.md A-2, the third of the three items that entry explicitly lists as uncovered,
 * and the question doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md §6.3 left open:
 * a round where switches answers and links does not still applies the half it got, because
 * updateSwitches/updateHosts/updateLinks each return early on an empty body.
 *
 * The adjudication these tests pin is that applying the half is RIGHT and stays. All three writers
 * are monotone-up -- they set isUp/isEnabled true and never false -- so a partial round cannot
 * manufacture a "down", it can only fail to lift one. Discarding a good switches reply because
 * links did not answer would move the twin in the pessimistic direction, and pessimistic-and-
 * silent is precisely the failure A-2 is about. What was missing was not a different policy but a
 * way to tell the two kinds of round apart afterwards.
 *
 * So what is pinned here is the classification, the edge-trigger, and one distinction that is easy
 * to get backwards and expensive when you do:
 *
 *   🔴 "" and "[]" are different answers. utils::execCommand hands back curl's stdout and throws
 *   its exit status away, so a request that timed out yields an empty string -- while a fabric
 *   that genuinely has no links yields "[]", two bytes, a perfectly good reply. Every OVS boot
 *   reports exactly that until LLDP finishes discovering. A rule keyed on "links has no entries"
 *   rather than on `empty()` turns that normal state into a reported wedge, which is the same
 *   shape of mistake this repo has recorded before: an unexpected case made to underestimate a
 *   deliberate one. AnEmptyJsonListIsAnAnswerNotSilence fails if anyone tightens it that way.
 *
 * Every assertion that a line is ABSENT is followed by driving a round that must produce it, so a
 * broken capture rig cannot make those tests pass by recording nothing at all.
 *
 * Not covered here, and said out loud rather than left to be discovered: that
 * pollControlPlaneTopology actually calls noteAndAnnouncePollRound. That call sits between three
 * live curls and cannot be reached without a control plane, which is the same reason
 * buildTopologyFetchCommand was extracted rather than tested in place. It is carried as a declared
 * survivor in tests/shell/mutate_a2_poll_round.sh, with the live recipe that closes it.
 */

#include <cstddef>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

/**
 * The token as a runbook, a log scraper and a grep would spell it, written out rather than taken
 * from the header.
 *
 * A test that only compared the log against TopologyAndFlowMonitor::kPartialRoundToken would
 * follow a rename of that constant and stay green while every scraper already deployed against the
 * old spelling broke silently. The constant is checked against this literal separately.
 */
constexpr const char* kExpectedToken = "topology-round-partial";

/// Occurrences of @p needle in @p haystack. Counting, not merely finding: the property under test
/// is "once per episode", and a `find() != npos` cannot tell one line from forty.
std::size_t
countOccurrences(const std::string& haystack, const std::string& needle)
{
    std::size_t total = 0;
    for (std::size_t at = haystack.find(needle); at != std::string::npos;
         at = haystack.find(needle, at + needle.size()))
    {
        ++total;
    }
    return total;
}

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Restores the logger's previous level and sink list on destruction, so the rest of the suite runs
 * against the `off` level test_LoggerEnvironment installed. Same helper as
 * tests/test_ApiKeyNotLogged.cpp; duplicated rather than shared because hoisting it would create a
 * test-support header that several files then have to agree on.
 */
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
    {
        m_logger->set_level(m_savedLevel);
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
    }

    LogCapture(const LogCapture&) = delete;
    LogCapture& operator=(const LogCapture&) = delete;

    /// Every formatted record captured so far, concatenated.
    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

    /// How many times the partial-round token has been written so far.
    std::size_t tokenCount() const { return countOccurrences(text(), kExpectedToken); }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/**
 * Reaches the protected round-classification members. Constructing one is cheap and starts no
 * threads -- the constructor only sets the three URLs, and the poll threads begin at start(),
 * which nothing here calls. Same seam as tests/test_AdministrativeDisable.cpp.
 */
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    using Kind = TopologyAndFlowMonitor::PollRoundKind;

    using TopologyAndFlowMonitor::classifyPollRound;
    using TopologyAndFlowMonitor::kPartialRoundToken;
    using TopologyAndFlowMonitor::lastPollRoundKind;
    using TopologyAndFlowMonitor::noteAndAnnouncePollRound;
    using TopologyAndFlowMonitor::shouldAnnouncePartialRound;
};

/// A monitor plus the three shared objects it needs. No topology is loaded: nothing here touches
/// the graph, only the round bookkeeping in front of it.
struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::TESTBED};
};

/// Shorthand for the enumerators below. Kept inside the anonymous namespace so a name this short
/// cannot collide with anything in the forty other translation units linked into this binary.
using Kind = TestableMonitor::Kind;

} // namespace

// --- the rule: how a round is classified --------------------------------------------------------

TEST(TopologyPollRound, AllThreeAnsweredIsComplete)
{
    EXPECT_EQ(TestableMonitor::classifyPollRound(true, true, true), Kind::Complete);
}

TEST(TopologyPollRound, NoneAnsweredIsSilent)
{
    // Distinct from Partial on purpose. "the control plane is gone" and "the control plane is
    // half-gone" want different remedies, and the warning beside m_topologyFetchFailures already
    // owns the first one -- reporting it as partial as well would double-report one fault.
    EXPECT_EQ(TestableMonitor::classifyPollRound(false, false, false), Kind::Silent);
}

TEST(TopologyPollRound, OneSilentEndpointIsPartial)
{
    // The observed shape of the Ryu wedge: the link read blocks while the others answer.
    EXPECT_EQ(TestableMonitor::classifyPollRound(true, true, false), Kind::Partial) << "links";
    EXPECT_EQ(TestableMonitor::classifyPollRound(true, false, true), Kind::Partial) << "hosts";
    EXPECT_EQ(TestableMonitor::classifyPollRound(false, true, true), Kind::Partial) << "switches";
}

TEST(TopologyPollRound, OnlyOneAnsweredIsStillPartial)
{
    // One reply out of three is not silence. The graph still receives that reply, so the round
    // still produced a mixed-age graph and still has to say so.
    EXPECT_EQ(TestableMonitor::classifyPollRound(true, false, false), Kind::Partial) << "switches";
    EXPECT_EQ(TestableMonitor::classifyPollRound(false, true, false), Kind::Partial) << "hosts";
    EXPECT_EQ(TestableMonitor::classifyPollRound(false, false, true), Kind::Partial) << "links";
}

TEST(TopologyPollRound, TheStableTokenIsTheOneTheRunbookGreps)
{
    EXPECT_STREQ(TestableMonitor::kPartialRoundToken, kExpectedToken)
        << "renaming this breaks every deployed scraper; the rename is the change to justify, "
           "not this assertion";
}

// --- the rule: when a round earns a line --------------------------------------------------------

TEST(TopologyPollRound, APartialRoundIsAnnouncedOnlyWhenItBecomesPartial)
{
    // Entering the state, from each of the three ways in.
    EXPECT_TRUE(TestableMonitor::shouldAnnouncePartialRound(Kind::NotYetPolled, Kind::Partial))
        << "the very first round being partial is still an episode starting";
    EXPECT_TRUE(TestableMonitor::shouldAnnouncePartialRound(Kind::Complete, Kind::Partial));
    EXPECT_TRUE(TestableMonitor::shouldAnnouncePartialRound(Kind::Silent, Kind::Partial))
        << "coming back from fully silent to half-answering is when the mixed-age graph starts";

    // Staying in it. This poll repeats every 5-30s forever; a control plane that stays half-wedged
    // must not write a line per poll until the disk fills.
    EXPECT_FALSE(TestableMonitor::shouldAnnouncePartialRound(Kind::Partial, Kind::Partial));
}

TEST(TopologyPollRound, NoRoundOtherThanPartialIsAnnounced)
{
    EXPECT_FALSE(TestableMonitor::shouldAnnouncePartialRound(Kind::Partial, Kind::Complete));
    EXPECT_FALSE(TestableMonitor::shouldAnnouncePartialRound(Kind::Partial, Kind::Silent))
        << "a fully silent round belongs to the other warning, not to this line";
    EXPECT_FALSE(TestableMonitor::shouldAnnouncePartialRound(Kind::Complete, Kind::Silent));
    EXPECT_FALSE(TestableMonitor::shouldAnnouncePartialRound(Kind::Complete, Kind::Complete));
}

// --- the wiring: what a monitor records and writes -----------------------------------------------

TEST(TopologyPollRoundWiring, TheRoundKindIsRecordedForReading)
{
    Fixture f;

    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::NotYetPolled)
        << "before any round has run, reporting Silent would announce a wedge that has not been "
           "looked for yet";

    f.monitor.noteAndAnnouncePollRound("[{\"dpid\":\"1\"}]", "[]", "[]");
    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::Complete);

    f.monitor.noteAndAnnouncePollRound("[{\"dpid\":\"1\"}]", "[]", "");
    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::Partial);

    f.monitor.noteAndAnnouncePollRound("", "", "");
    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::Silent);
}

TEST(TopologyPollRoundWiring, AnEmptyJsonListIsAnAnswerNotSilence)
{
    // 🔴 The one that must never be "fixed" into strictness. An OVS fabric answers "[]" on all
    // three endpoints for as long as LLDP has not finished, which is every boot. Calling that a
    // partial round would put a wedge warning into the log of a control plane doing its job.
    LogCapture capture;
    Fixture f;

    f.monitor.noteAndAnnouncePollRound("[]", "[]", "[]");

    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::Complete)
        << "\"[]\" is two bytes of a perfectly good answer; only \"\" means the request did not "
           "come back";
    EXPECT_EQ(capture.tokenCount(), 0u)
        << "a zero-link fabric must not be reported as a half-wedged one:\n"
        << capture.text();

    // The rig can see the token when there is one to see, so the zero above is a finding rather
    // than a capture that recorded nothing at all.
    f.monitor.noteAndAnnouncePollRound("[]", "[]", "");
    EXPECT_EQ(capture.tokenCount(), 1u) << "capture rig is not recording:\n" << capture.text();
}

TEST(TopologyPollRoundWiring, APartialRoundWritesTheStableTokenOncePerEpisode)
{
    LogCapture capture;
    Fixture f;

    f.monitor.noteAndAnnouncePollRound("[]", "[]", "");
    EXPECT_EQ(capture.tokenCount(), 1u) << "the first partial round must say so:\n"
                                        << capture.text();

    f.monitor.noteAndAnnouncePollRound("[]", "[]", "");
    f.monitor.noteAndAnnouncePollRound("[]", "", "");
    EXPECT_EQ(capture.tokenCount(), 1u)
        << "a control plane that stays partial is one episode, not one line per poll:\n"
        << capture.text();

    // A complete round ends the episode; the next partial round is a new one.
    f.monitor.noteAndAnnouncePollRound("[]", "[]", "[]");
    f.monitor.noteAndAnnouncePollRound("[]", "[]", "");
    EXPECT_EQ(capture.tokenCount(), 2u)
        << "a second episode is a second line, or a recurring fault reads as a single incident:\n"
        << capture.text();
}

TEST(TopologyPollRoundWiring, ASilentRoundDoesNotWriteThePartialToken)
{
    LogCapture capture;
    Fixture f;

    f.monitor.noteAndAnnouncePollRound("", "", "");

    EXPECT_EQ(f.monitor.lastPollRoundKind(), Kind::Silent);
    EXPECT_EQ(capture.tokenCount(), 0u)
        << "the fully-silent case is the other warning's; two lines for one fault make the two "
           "faults harder to tell apart, not easier:\n"
        << capture.text();

    // Same rig, same monitor: coming back to half-answering does write the line, so the zero above
    // is about the silent round rather than about a capture that sees nothing.
    f.monitor.noteAndAnnouncePollRound("[]", "", "");
    EXPECT_EQ(capture.tokenCount(), 1u) << "capture rig is not recording:\n" << capture.text();
}
