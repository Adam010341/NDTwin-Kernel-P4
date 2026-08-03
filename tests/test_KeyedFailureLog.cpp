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

    // It is still *remembered* here, for forgetAfter (30 s, twice the hold-off). This assertion used
    // to be openCount() == 0, which encoded "erased the moment it goes missing" -- and that was the
    // bug: it made the hold-off measure consecutive presence, so an intermittent fault reported
    // never. See ARepeatedlyInterruptedFailureIsStillReported below.
    EXPECT_EQ(log.openCount(), 1u) << "forgotten immediately, so a gap would restart the hold-off";

    // Once the forget window passes it is gone, and still silent in both directions -- a genuine
    // startup transient must cost nothing at all.
    for (int s = 9; s <= 40; ++s)
    {
        const auto report = log.endPass(t0 + std::chrono::seconds(s));
        EXPECT_TRUE(report.newFailures.empty()) << "reported at " << s << "s";
        EXPECT_TRUE(report.recovered.empty()) << "recovery reported at " << s << "s";
    }
    EXPECT_EQ(log.openCount(), 0u) << "still remembered long after it stopped";
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
    KeyedFailureLog log{std::chrono::seconds(10)}; // forgetAfter is therefore 20 s
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("k", "m");
    log.endPass(t0);
    log.record("k", "m");
    ASSERT_EQ(log.endPass(t0 + std::chrono::seconds(10)).newFailures.size(), 1u);

    // Recovery waits out the forget window, because until it expires we do not yet know the failure
    // has stopped rather than paused. Declaring recovery on the first quiet pass is what made a
    // flapping fault look like a series of resolved ones.
    EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(11)).recovered.empty())
        << "declared recovered one pass after the last failure";
    EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(29)).recovered.empty())
        << "declared recovered before the forget window elapsed";

    const auto recovered = log.endPass(t0 + std::chrono::seconds(30));
    ASSERT_EQ(recovered.recovered.size(), 1u) << "never reported recovered at all";
    EXPECT_EQ(recovered.recovered[0].second, 2u) << "the pass count spans the whole failure";
    EXPECT_EQ(log.openCount(), 0u);
}

// --- The gap this suite did not cover, and which let the bug ship.
//
// The hold-off measured *consecutive* presence, so any single absent pass erased an unreported key
// and restarted its clock. Every test above drives either an uninterrupted failure or one that stops
// for good, so none of them could see it. Measured on the real header at the path-walk loop's 1 kHz
// cadence: a failure present in 99% of 600,000 passes over ten minutes was reported **zero** times,
// and so were 10-second bursts of a permanently broken flow.
//
// That matters because the keys are derived from flows in m_flowInfoTable, which purgeIdleFlows
// removes and handlePacket re-creates -- so their presence tracks traffic and is not monotonic. The
// warning being rationed here is the one that answered the P4 host-port bug. Rationed to zero it is
// worse than the 270,991 copies it replaced: a flood can be grepped, silence cannot.

TEST(KeyedFailureLogForgetWindowTest, ARepeatedlyInterruptedFailureIsStillReported)
{
    // One absent pass in a hundred, at the real cadence. This is the measured case.
    KeyedFailureLog log{std::chrono::seconds(15)};
    const auto t0 = KeyedFailureLog::Clock::now();

    int reported = 0;
    for (int pass = 0; pass < 60000; ++pass) // 60 s at 1 kHz
    {
        if (pass % 100 != 37)
        {
            log.record("dpid-port:4:3", "edge not found by dpid/port 4:3");
        }
        reported += static_cast<int>(
            log.endPass(t0 + std::chrono::milliseconds(pass)).newFailures.size());
    }

    EXPECT_EQ(reported, 1) << "a fault present 99% of the time was reported " << reported
                           << " times; it must be reported exactly once";
}

TEST(KeyedFailureLogForgetWindowTest, AFlappingFailureAccumulatesTowardsTheHoldOff)
{
    // Bursty traffic: the flow appears for 5 s, vanishes for 5 s, repeats. No single burst reaches
    // the 15 s hold-off, so under consecutive-presence rules this reported nothing, forever.
    KeyedFailureLog log{std::chrono::seconds(15)};
    const auto t0 = KeyedFailureLog::Clock::now();

    int reported = 0;
    for (int s = 0; s < 120; ++s)
    {
        if ((s / 5) % 2 == 0)
        {
            log.record("k", "m");
        }
        reported += static_cast<int>(log.endPass(t0 + std::chrono::seconds(s)).newFailures.size());
    }

    EXPECT_EQ(reported, 1) << "reported " << reported << " times over two minutes of flapping";
}

TEST(KeyedFailureLogForgetWindowTest, AGapLongerThanTheForgetWindowDoesRestartTheHoldOff)
{
    // The other side of the trade. A fault that stops for longer than the forget window is a
    // different episode, and its hold-off starts again -- otherwise two unrelated transients hours
    // apart would add up to a report.
    KeyedFailureLog log{std::chrono::seconds(10)}; // forget after 20 s
    const auto t0 = KeyedFailureLog::Clock::now();

    // Two 5-second episodes, 60 seconds apart. Neither reaches the hold-off on its own.
    for (int s = 0; s < 5; ++s)
    {
        log.record("k", "m");
        ASSERT_TRUE(log.endPass(t0 + std::chrono::seconds(s)).newFailures.empty());
    }
    for (int s = 5; s < 65; ++s)
    {
        log.endPass(t0 + std::chrono::seconds(s));
    }
    ASSERT_EQ(log.openCount(), 0u) << "the first episode was never forgotten";

    for (int s = 65; s < 70; ++s)
    {
        log.record("k", "m");
        EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(s)).newFailures.empty())
            << "the second episode inherited the first one's age and reported at " << s << "s";
    }
}

TEST(KeyedFailureLogForgetWindowTest, TheForgetWindowCanBeSetIndependently)
{
    // Defaulted to twice the hold-off, but a caller whose loop is bursty on a different timescale
    // needs to say so. Pinned because the default is the kind of thing that gets "simplified" away.
    KeyedFailureLog log{std::chrono::seconds(10), std::chrono::seconds(60)};
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("k", "m");
    log.endPass(t0);

    // Absent for 40 s -- past twice the hold-off, but inside the explicit window, so still
    // remembered and still accumulating.
    for (int s = 1; s <= 40; ++s)
    {
        EXPECT_TRUE(log.endPass(t0 + std::chrono::seconds(s)).recovered.empty()) << s;
    }
    EXPECT_EQ(log.openCount(), 1u) << "the explicit forget window was ignored";
}

TEST(KeyedFailureLogForgetWindowTest, AStaleEntryIsForgottenEvenIfNoPassRanDuringTheGap)
{
    // The gap case that AGapLongerThanTheForgetWindowDoesRestartTheHoldOff does NOT cover, and the
    // difference is the whole point: that test calls endPass() every second throughout the gap, so
    // the prune loop cleans up and the hold-off restarts correctly. Here **no pass runs during the
    // gap at all**.
    //
    // With the prune loop running after the record loop, the record loop refreshed lastSeen first,
    // so `now - lastSeen` was already 0 when the prune loop looked; the entry survived carrying its
    // hundred-second-old firstSeen, and `now - firstSeen >= reportAfter` fired on that very first
    // pass. A fault seen once, then once again much later, was reported immediately -- the hold-off
    // bypassed entirely. Found by review, not by this suite.
    //
    // Reachable for any caller that closes a pass only when it has something to report. The 1 kHz
    // path-walk loop closes every pass, which is why it never saw this.
    // [Co-developed with claude code -- Adam]
    KeyedFailureLog log{std::chrono::seconds(10)}; // forget after 20s
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("k", "m");
    ASSERT_TRUE(log.endPass(t0).newFailures.empty()) << "reported before the hold-off elapsed";

    // 100 seconds pass with NO endPass call, then the fault reappears once.
    log.record("k", "m");
    const auto reappeared = log.endPass(t0 + std::chrono::seconds(100));

    EXPECT_TRUE(reappeared.newFailures.empty())
        << "inherited a firstSeen from 100s ago and bypassed the hold-off: two isolated occurrences "
           "far apart are exactly what the hold-off exists to suppress";
    EXPECT_TRUE(reappeared.recovered.empty())
        << "the first occurrence was never reported, so it must not report a recovery either";
}

TEST(KeyedFailureLogForgetWindowTest, AReportedFailureThatVanishesWithNoFurtherPassesStillRecovers)
{
    // The other half of moving the prune loop first: a *reported* failure that goes away must still
    // produce its recovery line on the next pass, however long afterwards that pass is.
    KeyedFailureLog log{std::chrono::seconds(10)};
    const auto t0 = KeyedFailureLog::Clock::now();

    log.record("k", "m");
    log.endPass(t0);
    log.record("k", "m");
    ASSERT_EQ(log.endPass(t0 + std::chrono::seconds(10)).newFailures.size(), 1u);

    // One pass, much later, with the key absent.
    const auto later = log.endPass(t0 + std::chrono::seconds(500));
    ASSERT_EQ(later.recovered.size(), 1u) << "a reported failure vanished without a recovery line";
    EXPECT_EQ(log.openCount(), 0u);
}

TEST(KeyedFailureLogForgetWindowTest, AZeroHoldOffForgetsImmediatelyAsBefore)
{
    // The default construction, used by every caller that is not the 1 kHz path-walk loop. A zero
    // hold-off implies a zero forget window, so this behaviour is unchanged: report on sight,
    // recover on the first quiet pass.
    KeyedFailureLog log;
    log.record("k", "m");
    EXPECT_EQ(log.endPass().newFailures.size(), 1u);
    EXPECT_EQ(log.endPass().recovered.size(), 1u);
    EXPECT_EQ(log.openCount(), 0u);
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
