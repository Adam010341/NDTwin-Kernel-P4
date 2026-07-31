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
