/**
 * Tests for the OVS switch-liveness policy in pingWorker.
 *
 * [Co-developed with claude code -- Adam]
 *
 * These exist because the policy was wrong in two independent ways at once, and the symptom was
 * every node showing red in the Web GUI with `is_up: 0` for all ten switches while the fabric was
 * demonstrably fine (traffic flowing, 5.9M packets through s1-eth3):
 *
 *  1. `ovs-vsctl list-br` failing was indistinguishable from it reporting no bridges -- both
 *     produced an empty vector, and the loop read that as every switch being down. A single
 *     dropped call marked the whole fabric dead. Two real causes were seen: sudo needing a
 *     password on a process started with setsid (no controlling terminal), and the command
 *     slowing down under a 100 Mbps flood. The exit status was never checked either.
 *  2. The branch only ever called setVertexDown. A switch found present was logged and left
 *     alone, so nothing here could bring one back up -- "down" was permanent until Ryu happened
 *     to re-announce the switch, which only happens when it reconnects.
 *
 * Together those meant one blip took the graph down for the rest of the run. The fix separates
 * "absent" from "cannot tell" and makes the transition symmetric.
 */

#include <csignal>
#include <optional>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

namespace
{

/// Reaches the protected policy without constructing the manager, which would need a topology
/// monitor, a classifier and background threads. Same test-seam pattern as ProbeCollector in
/// test_SFlowEmitterRoundtrip.cpp.
class LivenessProbe : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::describeCommandStatus;
    using DeviceConfigurationAndPowerManager::OvsLiveness;
    using DeviceConfigurationAndPowerManager::ovsLivenessFor;
};

using Liveness = LivenessProbe::OvsLiveness;

const std::vector<std::string> kTenBridges = {"s1", "s2", "s3", "s4", "s5",
                                              "s6", "s7", "s8", "s9", "s10"};

} // namespace

TEST(OvsLivenessTest, APresentBridgeIsUp)
{
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s1", kTenBridges), Liveness::Up);
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s10", kTenBridges), Liveness::Up);
}

TEST(OvsLivenessTest, AnAbsentBridgeIsDown)
{
    // A genuinely missing bridge, with the list read successfully, is the one case where
    // reporting "down" is correct.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s11", kTenBridges), Liveness::Down);
}

TEST(OvsLivenessTest, AFailedQueryIsUnknownRatherThanDown)
{
    // The bug. nullopt means the query failed, which says nothing about the switch -- reporting
    // it as dead is what turned one dropped ovs-vsctl call into a fabric-wide outage in the
    // twin's view.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s1", std::nullopt), Liveness::Unknown);
}

TEST(OvsLivenessTest, AnEmptyButSuccessfulQueryStillMeansDown)
{
    // The distinction that did not exist before: an empty *list* is a real answer (no bridges
    // exist), while an empty *result* used to also mean "the command failed". Only the former
    // may conclude Down.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s1", std::vector<std::string>{}), Liveness::Down);
}

TEST(OvsLivenessTest, TheDecisionIsSymmetricSoASwitchCanRecover)
{
    // Down must not be a one-way door. The same bridge name over a failing then recovering
    // query has to come back Up, or a transient blip is permanent -- which is exactly what
    // happened: switches were up at startup, went down mid-run, and never returned.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s3", kTenBridges), Liveness::Up);
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s3", std::vector<std::string>{"s1"}),
              Liveness::Down);
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s3", kTenBridges), Liveness::Up)
        << "a switch that reappears must be reported Up again";
}

TEST(OvsLivenessTest, MatchingIsExactSoSimilarNamesDoNotSatisfyEachOther)
{
    // "s1" must not be satisfied by "s10" being present. A substring match would report every
    // switch up whenever s10 exists.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s1", std::vector<std::string>{"s10"}),
              Liveness::Down);
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("s10", std::vector<std::string>{"s1"}),
              Liveness::Down);
}

TEST(OvsLivenessTest, AnEmptyBridgeNameIsNotMatchedByAccident)
{
    // A switch with no bridge_name in the topology should not come out Up because some entry
    // happens to be empty. Reported Down, which is honest: there is nothing to look for.
    EXPECT_EQ(LivenessProbe::ovsLivenessFor("", kTenBridges), Liveness::Down);
}

// --- FailureRun: the edge-triggered logging that keeps a persistent fault from flooding the log.

TEST(FailureRunTest, OnlyTheFirstFailureOfARunReports)
{
    // The query runs at 1 Hz. Reporting every failure is what produced 3596 log lines in one run
    // and buried the rest of the log, so everything after the first must be silent.
    FailureRun run;
    EXPECT_TRUE(run.recordFailure()) << "the first failure must be visible";
    for (int i = 0; i < 100; ++i)
    {
        EXPECT_FALSE(run.recordFailure()) << "failure " << i + 2 << " must stay quiet";
    }
}

TEST(FailureRunTest, SuccessWithNoOpenRunSaysNothing)
{
    // The healthy path, which is the common one: a successful query must not log "recovered" on
    // every single tick.
    FailureRun run;
    EXPECT_FALSE(run.recordSuccess().has_value());
    EXPECT_FALSE(run.recordSuccess().has_value());
}

TEST(FailureRunTest, RecoveryReportsTheRunLengthExactlyOnce)
{
    FailureRun run;
    run.recordFailure();
    run.recordFailure();
    run.recordFailure();

    const auto recovered = run.recordSuccess();
    ASSERT_TRUE(recovered.has_value());
    EXPECT_EQ(*recovered, 3u) << "the duration is the only reason to count at all";

    EXPECT_FALSE(run.recordSuccess().has_value()) << "recovery must not be reported twice";
}

TEST(FailureRunTest, ASecondRunReportsAgainRatherThanStayingQuietForever)
{
    // The counter has to reset on recovery, or a later fault is silent -- the same class of bug as
    // the liveness one above, where "down" was a one-way door.
    FailureRun run;
    run.recordFailure();
    EXPECT_EQ(run.recordSuccess().value_or(0), 1u);

    EXPECT_TRUE(run.recordFailure()) << "a new fault must be reported, not swallowed";
    EXPECT_EQ(run.recordSuccess().value_or(0), 1u);
}

// --- describeCommandStatus: pclose returns a wait status, not an exit code.

TEST(CommandStatusTest, AnExitCodeIsReportedAsAnExitCodeNotAWaitStatus)
{
    // The bug this replaces: pclose()'s return value was logged raw, so exit code 1 printed as
    // "status 256" and 127 as "status 32512" -- numbers with no meaning to whoever reads the log.
    EXPECT_EQ(LivenessProbe::describeCommandStatus(1 << 8),
              "exit code 1 (ovs-vsctl refused; a sudo password prompt does this on a process "
              "with no controlling terminal)");
    EXPECT_EQ(LivenessProbe::describeCommandStatus(3 << 8), "exit code 3");
}

TEST(CommandStatusTest, TheTwoStatusesThisCommandActuallyProducesAreExplained)
{
    // 127 and 1 send an operator to completely different places -- a missing binary versus sudo
    // refusing -- and the second is the original cause of the whole fabric reading as dead, so
    // the log should not make the reader look it up.
    EXPECT_NE(LivenessProbe::describeCommandStatus(127 << 8).find("command not found"),
              std::string::npos);
    EXPECT_NE(LivenessProbe::describeCommandStatus(1 << 8).find("sudo password prompt"),
              std::string::npos);
}

TEST(CommandStatusTest, ASignalledCommandIsNotReportedAsAnExitCode)
{
    // WIFEXITED is false here, so decoding with WEXITSTATUS would invent an exit code the child
    // never returned. A killed ovs-vsctl (SIGKILL under memory pressure, say) must say so.
    EXPECT_EQ(LivenessProbe::describeCommandStatus(SIGKILL), "killed by signal 9");
}

TEST(CommandStatusTest, MinusOneIsReportedAsAFailureToReapRatherThanAsSuccess)
{
    // pclose returns -1 when it could not wait for the child at all. That is not a status to
    // decode, and it must not be silently treated as some exit code.
    const std::string described = LivenessProbe::describeCommandStatus(-1);
    EXPECT_NE(described.find("could not be reaped"), std::string::npos) << described;
    EXPECT_EQ(described.find("exit code"), std::string::npos)
        << "-1 is not an exit status: " << described;
}
