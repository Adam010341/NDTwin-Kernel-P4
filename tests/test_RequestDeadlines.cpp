/**
 * Every outbound request the kernel's polling loops make must be bounded in time.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Scope note, 2026-08-30: this file was written about DeviceConfigurationAndPowerManager alone.
 * It now also covers TopologyAndFlowMonitor's control-plane poll (doc/KNOWN-ISSUES.md A-2), which
 * was the same defect in a second class and outlived this file by two weeks precisely because the
 * invariant was filed under one class's name rather than under the property. The requests are
 * enumerated here together for the reason the paragraph below already gives.
 *
 * This file exists because of a measured outage on 2026-08-13. The flow-table request was a bare
 * `curl -s` with no deadline -- the last unbounded request in that file. Against a bmv2 that was
 * alive but not answering gRPC (SIGSTOP), the P4 proxy never replied at all, and because the sweep
 * is serial over every switch, one unresponsive dpid stalled every later dpid's table too.
 *
 * The reason a *file* rather than one more assertion: all three of these requests run on loops or
 * request handlers where an unbounded wait is not "slow", it is a wedge, and the failure is silent
 * in the same way each time -- `curl -s` prints nothing, so a hung request and a switch with no
 * rules produce the same empty string. Two of the three already carried a deadline; the third did
 * not, and nothing in the build noticed for months. Enumerating them together makes the invariant
 * checkable instead of a habit.
 *
 * These are the *wire format* only. Whether a bounded reply is then interpreted correctly is
 * test_FlowStatsTimeout.cpp (the latency verdict) and test_RelayResponse.cpp (the status line).
 */

#include <cstdint>
#include <string>

#include <gtest/gtest.h>

#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

namespace
{

/// Reaches the protected statics without constructing the manager, which would need a topology
/// monitor, a classifier and background threads. Same pattern as RelayReader and FlowStatsReader.
class RequestBuilder : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::buildFlowStatsCommand;
    using DeviceConfigurationAndPowerManager::buildRelayPowerCommand;
    using DeviceConfigurationAndPowerManager::buildSwitchStateCommand;
};

/// Same trick for the topology poll's builder. Never instantiated -- the static is the whole
/// point, and constructing a monitor would start threads.
class TopologyRequestBuilder : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::buildTopologyFetchCommand;
};

SwitchInfo plug()
{
    SwitchInfo si;
    si.switchIp = "192.168.123.11";
    si.plugIp = "172.25.166.135";
    si.plugIdx = 3;
    return si;
}

/// The seconds given to --max-time, or -1 when the flag is absent entirely.
double
deadlineOf(const std::string& cmd)
{
    const auto at = cmd.find("--max-time ");
    if (at == std::string::npos)
    {
        return -1.0;
    }
    return std::stod(cmd.substr(at + 11));
}

/// The seconds given to --connect-timeout, or -1 when the flag is absent entirely.
/// [Co-developed with claude code -- Adam]
double
connectDeadlineOf(const std::string& cmd)
{
    const std::string flag = "--connect-timeout ";
    const auto at = cmd.find(flag);
    if (at == std::string::npos)
    {
        return -1.0;
    }
    return std::stod(cmd.substr(at + flag.size()));
}

TEST(RequestDeadlines, TheFlowTableRequestIsBounded)
{
    // The regression. Unbounded, this request never returns against a switch that is alive but not
    // answering, and it is polled once per switch per sweep.
    const std::string cmd = RequestBuilder::buildFlowStatsCommand("127.0.0.1:8081", 5);

    EXPECT_NE(cmd.find("--max-time"), std::string::npos) << cmd;
    EXPECT_GT(deadlineOf(cmd), 0.0) << cmd;
}

TEST(RequestDeadlines, TheLivenessRequestIsBounded)
{
    // Runs inside the 1 Hz ping loop, so an unbounded request stalls liveness for every switch at
    // once -- not just the one being asked about.
    const std::string cmd = RequestBuilder::buildSwitchStateCommand("127.0.0.1:8081");

    EXPECT_NE(cmd.find("--max-time"), std::string::npos) << cmd;
    EXPECT_GT(deadlineOf(cmd), 0.0) << cmd;
}

TEST(RequestDeadlines, TheRelayRequestIsBounded)
{
    // Runs inside a request handler; an unresponsive gateway would hold the caller open.
    const std::string cmd = utils::describeArgv(RequestBuilder::buildRelayPowerCommand("localhost", plug(), "on"));

    EXPECT_NE(cmd.find("--max-time"), std::string::npos) << cmd;
    EXPECT_GT(deadlineOf(cmd), 0.0) << cmd;
}

TEST(RequestDeadlines, TheFlowTableDeadlineOutlivesTheProxysOwnGrpcDeadline)
{
    // The P4 proxy caps its own table read at 5 s and then answers {"error": ...} naming the
    // switch. Cutting at or before 5 s would usually win the race and leave curl with an empty
    // body, which fetchOpenFlowTablesInternal can only report as "switch N and possibly others".
    // Both outcomes are safe -- an empty body keeps the previous tables -- so this is about
    // whether the log can name the broken switch.
    const std::string cmd = RequestBuilder::buildFlowStatsCommand("127.0.0.1:8081", 5);

    EXPECT_GT(deadlineOf(cmd), 5.0) << cmd;
}

TEST(RequestDeadlines, TheLivenessDeadlineFitsInsideItsOwnPollInterval)
{
    // fetchP4SwitchState runs once a second. A deadline longer than the interval would let
    // requests pile up on a slow proxy instead of one failing and the next trying again.
    const std::string cmd = RequestBuilder::buildSwitchStateCommand("127.0.0.1:8081");

    EXPECT_LE(deadlineOf(cmd), 3.0) << cmd;
}

TEST(RequestDeadlines, TheFlowTableRequestStillAddressesTheRightSwitch)
{
    // Extracting the command into a builder must not change what it asks for. The dpid is
    // interpolated, and the host differs per switch kind -- Ryu for OVS, the proxy for bmv2.
    const std::string cmd = RequestBuilder::buildFlowStatsCommand("10.0.0.9:8080", 7);

    EXPECT_NE(cmd.find("http://10.0.0.9:8080/stats/flow/7"), std::string::npos) << cmd;
}

TEST(RequestDeadlines, TheLivenessRequestStillAsksForTheStatusLine)
{
    // fetchP4SwitchState splits the reply on the last newline to read the status. Losing -w would
    // make every reply look like a body with no status, and the extraction must not drop it.
    const std::string cmd = RequestBuilder::buildSwitchStateCommand("10.0.0.9:8081");

    EXPECT_NE(cmd.find("%{http_code}"), std::string::npos) << cmd;
    EXPECT_NE(cmd.find("http://10.0.0.9:8081/p4/switch_state"), std::string::npos) << cmd;
}

// --- The control-plane topology poll (doc/KNOWN-ISSUES.md A-2).

TEST(RequestDeadlines, TheTopologyPollIsBounded)
{
    // The regression, and the worst of the three: unbounded, this one does not merely stall a
    // sweep, it ends the polling thread for the lifetime of the process. Measured at 733s and
    // still running, with the twin showing 40 links down against a fabric at 0% loss.
    const std::string cmd =
        TopologyRequestBuilder::buildTopologyFetchCommand("http://127.0.0.1:8080/v1.0/topology/switches");

    EXPECT_NE(cmd.find("--max-time"), std::string::npos) << cmd;
    EXPECT_GT(deadlineOf(cmd), 0.0) << cmd;
}

TEST(RequestDeadlines, TheTopologyPollBoundsTheConnectAndNotJustTheTransfer)
{
    // --max-time alone would not have covered the failure that was actually measured elsewhere in
    // this repo: a curl at a `localhost` resolving to an unattended IPv6 loopback sat for 131
    // seconds because the SYNs were dropped rather than refused. These URLs are built from
    // AppConfig::RYU_IP_AND_PORT, so that spelling is reachable here too.
    const std::string cmd =
        TopologyRequestBuilder::buildTopologyFetchCommand("http://localhost:8080/v1.0/topology/links");

    EXPECT_NE(cmd.find("--connect-timeout"), std::string::npos)
        << "a dropped SYN is not covered by --max-time alone: " << cmd;
    EXPECT_GT(connectDeadlineOf(cmd), 0.0) << cmd;
    EXPECT_LE(connectDeadlineOf(cmd), deadlineOf(cmd))
        << "a connect deadline longer than the total deadline is not a deadline: " << cmd;
}

TEST(RequestDeadlines, TheWholeTopologyPassFitsInsideItsOwnPollInterval)
{
    // One pass makes three of these in sequence, and run() polls every 5s while converging. A
    // per-request bound that let a wedged pass outlast the interval would queue passes behind each
    // other rather than letting one fail and the next try again.
    const std::string cmd =
        TopologyRequestBuilder::buildTopologyFetchCommand("http://127.0.0.1:8080/v1.0/topology/hosts");

    constexpr int kRequestsPerPass = 3;
    constexpr double kSteadyPollIntervalSeconds = 30.0;
    EXPECT_LE(deadlineOf(cmd) * kRequestsPerPass, kSteadyPollIntervalSeconds) << cmd;
}

TEST(RequestDeadlines, TheTopologyRequestStillFetchesTheUrlItWasGiven)
{
    // Extracting the command into a builder must not change what it asks for. The URL is the whole
    // argument -- the same three endpoints are served by Ryu on OVS and by the P4 proxy on an
    // all-bmv2 fabric, and configureTopologyApiUrls is what chooses.
    const std::string cmd =
        TopologyRequestBuilder::buildTopologyFetchCommand("http://10.0.0.9:8080/v1.0/topology/switches");

    EXPECT_NE(cmd.find("http://10.0.0.9:8080/v1.0/topology/switches"), std::string::npos) << cmd;
    EXPECT_NE(cmd.find("-X GET"), std::string::npos) << cmd;
}

TEST(RequestDeadlines, TheTopologyRequestKeepsCurlsOwnDiagnosisOnStderr)
{
    // -s silences errors as well as the progress meter, which is half of why the wedge produced
    // no output at all. -S puts the "(28) Operation timed out" line back without turning the
    // progress meter on. execCommand captures stdout only, so this cannot corrupt the reply.
    const std::string cmd =
        TopologyRequestBuilder::buildTopologyFetchCommand("http://127.0.0.1:8080/v1.0/topology/hosts");

    EXPECT_NE(cmd.find("-sS"), std::string::npos)
        << "a silent curl and a silent poll were the same bug twice: " << cmd;
}

} // namespace
