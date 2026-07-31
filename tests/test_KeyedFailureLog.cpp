/**
 * Tests for the edge-triggered, keyed failure log.
 *
 * [Co-developed with claude code -- Adam]
 *
 * This exists because of a measured cost, not a style preference. The path-walk loop re-checks
 * every tracked flow every millisecond and warned on each failure, so one misconfigured port
 * produced 270,991 copies of `edge not found by dpid/port 4:3` and a 41 MB kernel log. That
 * warning named the exact port at fault -- it was the answer to a real bug -- and it was
 * unreadable precisely because it was repeated a quarter of a million times.
 */

#include <string>

#include <gtest/gtest.h>

#include "utils/KeyedFailureLog.hpp"

using utils::KeyedFailureLog;

TEST(KeyedFailureLogTest, AFailureIsReportedOnceThenStaysQuiet)
{
    KeyedFailureLog log;

    log.record("4:3", "edge not found by dpid/port 4:3");
    auto first = log.endPass();
    ASSERT_EQ(first.newFailures.size(), 1u);
    EXPECT_EQ(first.newFailures[0].first, "4:3");
    EXPECT_EQ(first.newFailures[0].second, "edge not found by dpid/port 4:3");

    // The loop runs at ~1 kHz. Everything after the first pass must be silent, or we are back to
    // 270,991 lines.
    for (int pass = 0; pass < 1000; ++pass)
    {
        log.record("4:3", "edge not found by dpid/port 4:3");
        const auto report = log.endPass();
        EXPECT_TRUE(report.newFailures.empty()) << "re-reported on pass " << pass;
        EXPECT_TRUE(report.recovered.empty()) << "spurious recovery on pass " << pass;
    }
}

TEST(KeyedFailureLogTest, RecoveryIsReportedWithHowLongItLasted)
{
    KeyedFailureLog log;

    for (int pass = 0; pass < 5; ++pass)
    {
        log.record("4:3", "msg");
        log.endPass();
    }

    // A pass with no record() for that key means it stopped failing.
    const auto report = log.endPass();
    ASSERT_EQ(report.recovered.size(), 1u);
    EXPECT_EQ(report.recovered[0].first, "4:3");
    EXPECT_EQ(report.recovered[0].second, 5u) << "the duration is the only reason to count";
    EXPECT_EQ(log.openCount(), 0u);
}

TEST(KeyedFailureLogTest, RecoveryIsReportedOnlyOnce)
{
    KeyedFailureLog log;
    log.record("4:3", "msg");
    log.endPass();

    EXPECT_EQ(log.endPass().recovered.size(), 1u);
    EXPECT_TRUE(log.endPass().recovered.empty()) << "recovery must not repeat every quiet pass";
}

TEST(KeyedFailureLogTest, AFailureThatReturnsIsReportedAgain)
{
    // The same one-way-door mistake as the OVS liveness bug: if the key is not cleared on
    // recovery, a second fault is silent forever.
    KeyedFailureLog log;

    log.record("4:3", "msg");
    log.endPass();
    log.endPass(); // recovers

    log.record("4:3", "msg");
    const auto again = log.endPass();
    ASSERT_EQ(again.newFailures.size(), 1u) << "a returning fault must be reported, not swallowed";
}

TEST(KeyedFailureLogTest, DistinctFailuresAreTrackedIndependently)
{
    // The walk fails for several unrelated reasons at once -- a missing host edge, a missing
    // inter-switch edge, a hop-count blowout. Collapsing them into one flag would report the
    // first and hide the rest, which is how the misconfigured port could have stayed hidden
    // behind an unrelated warning.
    KeyedFailureLog log;

    log.record("4:3", "edge not found by dpid/port 4:3");
    log.record("hostedge:10.0.0.9", "edge not found for host 10.0.0.9");
    const auto first = log.endPass();
    EXPECT_EQ(first.newFailures.size(), 2u);
    EXPECT_EQ(log.openCount(), 2u);

    // One recovers, the other does not: exactly one report, and the survivor stays quiet.
    log.record("4:3", "edge not found by dpid/port 4:3");
    const auto second = log.endPass();
    EXPECT_TRUE(second.newFailures.empty());
    ASSERT_EQ(second.recovered.size(), 1u);
    EXPECT_EQ(second.recovered[0].first, "hostedge:10.0.0.9");
    EXPECT_EQ(log.openCount(), 1u);
}

TEST(KeyedFailureLogTest, RepeatsWithinOnePassCountAsOne)
{
    // Several flows can hit the same broken port in a single pass. That is one fault, not N.
    KeyedFailureLog log;
    log.record("4:3", "msg");
    log.record("4:3", "msg");
    log.record("4:3", "msg");

    EXPECT_EQ(log.endPass().newFailures.size(), 1u);

    log.endPass(); // recovers
    // Three records in one pass must not inflate the duration either.
    KeyedFailureLog other;
    other.record("k", "m");
    other.record("k", "m");
    other.endPass();
    EXPECT_EQ(other.endPass().recovered[0].second, 1u);
}

TEST(KeyedFailureLogTest, AQuietLoopReportsNothingAtAll)
{
    // The healthy path, which is the overwhelmingly common one.
    KeyedFailureLog log;
    for (int pass = 0; pass < 100; ++pass)
    {
        const auto report = log.endPass();
        EXPECT_TRUE(report.newFailures.empty());
        EXPECT_TRUE(report.recovered.empty());
    }
    EXPECT_EQ(log.openCount(), 0u);
}

// --- The hold-off: only report failures that outlast it.
//
// The path-walk loop needs this. For the first seconds after startup the flow tables are still
// being fetched one switch at a time, so "no table for dpid 10" is true and transient -- measured
// at 7454, 37 and 29 passes on one real start. Reporting those put three warnings in every clean
// startup, and the alternative to a hold-off was allowlisting them, which is exactly how the
// previous version of this warning became unread.
//
// `now` is injected so these are deterministic rather than sleeping.

TEST(KeyedFailureLogHoldOffTest, AFailureShorterThanTheHoldOffIsNeverReported)
{
    KeyedFailureLog log{std::chrono::seconds(15)};
    const auto t0 = KeyedFailureLog::Clock::now();

    // Fails for 7 seconds -- the observed startup case -- then clears.
    for (int s = 0; s < 7; ++s)
    {
        log.record("no-table:10", "no flow table for dpid 10");
        const auto report = log.endPass(t0 + std::chrono::seconds(s));
        EXPECT_TRUE(report.newFailures.empty()) << "reported at " << s << "s";
    }

    const auto after = log.endPass(t0 + std::chrono::seconds(8));
    EXPECT_TRUE(after.newFailures.empty());
    EXPECT_TRUE(after.recovered.empty())
        << "a failure that was never reported must not report a recovery either, or the hold-off "
           "just moves the noise to the recovery line";
    EXPECT_EQ(log.openCount(), 0u);
}

TEST(KeyedFailureLogHoldOffTest, AFailureThatOutlastsTheHoldOffIsReportedOnce)
{
    KeyedFailureLog log{std::chrono::seconds(15)};
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("dpid-port:4:3", "edge not found by dpid/port 4:3");
    EXPECT_TRUE(log.endPass(t0).newFailures.empty()) << "reported immediately despite the hold-off";

    log.record("dpid-port:4:3", "edge not found by dpid/port 4:3");
    const auto atLimit = log.endPass(t0 + std::chrono::seconds(15));
    ASSERT_EQ(atLimit.newFailures.size(), 1u) << "not reported once the hold-off elapsed";
    EXPECT_EQ(atLimit.newFailures[0].first, "dpid-port:4:3");

    // And still only once, however long it persists.
    for (int s = 16; s < 40; ++s)
    {
        log.record("dpid-port:4:3", "edge not found by dpid/port 4:3");
        EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(s)).newFailures.empty())
            << "re-reported at " << s << "s";
    }
}

TEST(KeyedFailureLogHoldOffTest, RecoveryIsReportedOnlyForAFailureThatWasReported)
{
    KeyedFailureLog log{std::chrono::seconds(10)};
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("k", "m");
    log.endPass(t0);
    log.record("k", "m");
    ASSERT_EQ(log.endPass(t0 + std::chrono::seconds(10)).newFailures.size(), 1u);

    const auto recovered = log.endPass(t0 + std::chrono::seconds(11));
    ASSERT_EQ(recovered.recovered.size(), 1u);
    EXPECT_EQ(recovered.recovered[0].second, 2u) << "the pass count spans the whole failure";
}

TEST(KeyedFailureLogHoldOffTest, TheHoldOffIsPerKeyNotGlobal)
{
    // A transient startup miss must not delay reporting of a genuine fault that started earlier,
    // and a long-running fault must not drag a transient one into being reported.
    KeyedFailureLog log{std::chrono::seconds(10)};
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("old", "started at t0");
    log.endPass(t0);

    // "new" appears at t0+9s; "old" crosses its hold-off at t0+10s.
    log.record("old", "started at t0");
    log.record("new", "started at t0+9s");
    EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(9)).newFailures.empty());

    log.record("old", "started at t0");
    log.record("new", "started at t0+9s");
    const auto atTen = log.endPass(t0 + std::chrono::seconds(10));
    ASSERT_EQ(atTen.newFailures.size(), 1u) << "only the older key has outlasted its hold-off";
    EXPECT_EQ(atTen.newFailures[0].first, "old");
}

TEST(KeyedFailureLogHoldOffTest, ZeroHoldOffKeepsTheImmediateBehaviour)
{
    // The default, for a caller that is not running at 1 kHz.
    KeyedFailureLog log;
    log.record("k", "m");
    EXPECT_EQ(log.endPass().newFailures.size(), 1u);
}
