/**
 * @file test_KernelStopIsBounded.cpp
 * @brief FINDINGS #27 and #76 -- "said it would stop, hasn't".
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECTS WERE
 *
 *   #27  DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker reads its stop flag once
 *        per round. One round is fetchOpenFlowTablesInternal(), which walks every up switch and
 *        runs `curl -s --max-time 8` for each, serially, with nothing in the walk reading the
 *        flag. A stop arriving at the first switch is therefore answered after the last one.
 *        Measured after B-5 restored the third join: SIGINT on the 10-switch bmv2 fabric took
 *        2.40/2.40/2.53/2.40/3.00/6.40 s idle -- and **81.09 s** with the proxy not answering,
 *        ~72 s of it inside that join. 9 remaining switches x 8 s = 72 s, to the second.
 *
 *   #76  TopologyAndFlowMonitor's poll thread has the same shape three times per round (switches,
 *        hosts, links) at `--connect-timeout 2 --max-time 5`. With the proxy wedged, a kernel
 *        whose sFlow bind had failed printed `Exiting` and was still running 8 s later, because
 *        main.cpp prints that line and *then* calls the stop that waits the curl out.
 *
 * WHY THESE TWO ARE ONE FILE
 *
 * They are not two bugs that resemble each other; they are one property that neither class has.
 * Filing the invariant under a class's name is what let A-2 outlive tests/test_RequestDeadlines.cpp
 * by two weeks, and that file says so in its own scope note. The property is: **after stop() is
 * requested, the process is not still doing work whose duration is set by a remote party.**
 *
 * WHAT IS ASSERTED, AND WHAT IS DELIBERATELY NOT
 *
 * Not "the loop checks the flag between switches" -- that is the fix restated, and it would go
 * green for an implementation that checked the flag and then still waited out the curl it had
 * already started, which is 8 of the 8 seconds. What is asserted is the elapsed wall time from
 * "stop was requested" to "stop returned", against a control plane that accepts connections and
 * never answers. That is the number the finding measured and the number an operator experiences.
 *
 * THE FAKE CONTROL PLANE
 *
 * A listener that accepts and never writes. This is not a stand-in for a wedged proxy, it is the
 * same condition: FIX-CLOEXEC.md's §2.3 measurements record that with nothing listening at all
 * every poll's curl fails in ~0 ms and the defect does not reproduce -- "refused" is fast, and it
 * is "accepted, then silent" that costs the full deadline. WedgedControlPlane is therefore the
 * instrument, and TheInstrumentReallyWedgesACurl is the control that proves it works before any
 * timing assertion below is read.
 */

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
#include "utils/StopSignal.hpp"
#include "utils/Utils.hpp"

#include <gtest/gtest.h>
#include <spdlog/sinks/ringbuffer_sink.h>

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <memory>
#include <netinet/in.h>
#include <shared_mutex>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace
{

using namespace std::chrono_literals;

/// The bound this branch commits to: stop() returns within 3 s of the stop request, whatever the
/// control plane is doing. Chosen in the fix doc from the two deadlines it has to beat (8 s per
/// switch, 5 s per topology endpoint) and from the pre-existing idle shutdown cost, which was
/// already 2.40-3.00 s before either defect was involved.
constexpr auto kStopBound = 3s;

/// Four, not the fabric's ten. On trunk this is 4 x 8 s = 32 s against a 3 s bound -- an
/// unambiguous red -- while keeping a mutation gate that runs the suite a dozen times finite.
constexpr int kSwitchesInFabric = 4;

/// The P4 proxy's port is a compile-time constant (AppConfig::P4_PROXY_IP_AND_PORT), so the flow
/// table test cannot be pointed at an ephemeral one. It binds this and skips if it cannot.
constexpr uint16_t kP4ProxyPort = 8081;

/**
 * @brief A TCP listener that completes the handshake and then says nothing, ever.
 *
 * Accepted connections are held open until this object dies: closing them would let curl finish
 * early with an empty body, which is a *different* failure (fast) and would make every timing
 * assertion below pass for the wrong reason.
 */
class WedgedControlPlane
{
  public:
    /// @param port 0 for an ephemeral port. bound() says whether it worked.
    explicit WedgedControlPlane(uint16_t port)
    {
        m_listenFd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (m_listenFd < 0)
        {
            return;
        }
        int one = 1;
        // Without this a gate that runs this suite a dozen times fails to rebind :8081 while the
        // previous run's sockets are in TIME_WAIT, and "could not bind" would be read as a skip.
        ::setsockopt(m_listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
        addr.sin_port = ::htons(port);
        if (::bind(m_listenFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
        {
            ::close(m_listenFd);
            m_listenFd = -1;
            return;
        }
        // A backlog deep enough that the poll's three requests and the fabric's switches all get
        // *accepted* rather than queued: a connection sitting in the backlog is indistinguishable
        // from a slow one, and the test needs to know the worker really is mid-request.
        if (::listen(m_listenFd, 64) != 0)
        {
            ::close(m_listenFd);
            m_listenFd = -1;
            return;
        }

        socklen_t len = sizeof(addr);
        if (::getsockname(m_listenFd, reinterpret_cast<sockaddr*>(&addr), &len) == 0)
        {
            m_port = ::ntohs(addr.sin_port);
        }

        m_accepting.store(true);
        m_thread = std::thread([this] { acceptLoop(); });
    }

    ~WedgedControlPlane()
    {
        m_accepting.store(false);
        if (m_listenFd >= 0)
        {
            // Closing the listening fd is what wakes the accept(): this suite may not kill threads
            // by name and must not leave one behind for the next test file's cases to trip over.
            ::shutdown(m_listenFd, SHUT_RDWR);
            ::close(m_listenFd);
            m_listenFd = -1;
        }
        if (m_thread.joinable())
        {
            m_thread.join();
        }
        for (const int fd : m_held)
        {
            ::close(fd);
        }
    }

    bool bound() const { return m_port != 0; }
    uint16_t port() const { return m_port; }

    /// How many connections it has taken. The test uses this to know a worker is really mid-request
    /// rather than still asleep -- timing a stop that never started is the classic zero-power test.
    int accepted() const { return m_accepted.load(); }

    /// Blocks until at least @p n connections have been accepted, or @p limit elapses.
    bool waitForConnections(int n, std::chrono::milliseconds limit)
    {
        const auto deadline = std::chrono::steady_clock::now() + limit;
        while (std::chrono::steady_clock::now() < deadline)
        {
            if (m_accepted.load() >= n)
            {
                return true;
            }
            std::this_thread::sleep_for(20ms);
        }
        return m_accepted.load() >= n;
    }

    WedgedControlPlane(const WedgedControlPlane&) = delete;
    WedgedControlPlane& operator=(const WedgedControlPlane&) = delete;

  private:
    void acceptLoop()
    {
        while (m_accepting.load())
        {
            const int fd = ::accept(m_listenFd, nullptr, nullptr);
            if (fd < 0)
            {
                if (!m_accepting.load())
                {
                    return;
                }
                continue;
            }
            m_held.push_back(fd); // held open, never written to
            m_accepted.fetch_add(1);
        }
    }

    int m_listenFd = -1;
    uint16_t m_port = 0;
    std::atomic<bool> m_accepting{false};
    std::atomic<int> m_accepted{0};
    std::thread m_thread;
    std::vector<int> m_held;
};

/// Captures what the kernel logged, so the "what am I waiting on" line can be asserted on the
/// records rather than on the source. Same rig as tests/test_ApiKeyNotLogged.cpp.
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_previousLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(512))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
    {
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
        m_logger->set_level(m_previousLevel);
    }

    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

    std::size_t recordCount() const { return m_sink->last_formatted().size(); }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_previousLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// A graph of @p count bmv2 switches, all up -- which is what isPollableForFlowTable asks for, and
/// therefore what makes the worker spend one `curl --max-time 8` on each of them.
std::shared_ptr<Graph>
fabricOfUpBmv2Switches(int count)
{
    auto graph = std::make_shared<Graph>();
    for (int i = 0; i < count; ++i)
    {
        VertexProperties props;
        props.vertexType = VertexType::SWITCH;
        props.switchKind = SwitchKind::BMV2;
        props.dpid = static_cast<uint64_t>(i + 1);
        props.isUp = true;
        props.isEnabled = true;
        // 🔴 An address, and NOT because this test needs one. fetchCpuReportInternal does
        // `utils::ipToString(vp.ip.front())` on every SWITCH vertex with no empty check
        // (DeviceConfigurationAndPowerManager.cpp:1689), so a switch carrying no IP segfaults the
        // status worker -- confirmed here under gdb before this line existed: SIGSEGV on thread 4
        // in fetchCpuReportInternal <- statusUpdateWorker. That is a defect in its own right and
        // it is NOT what this file is about, so the fixture stays on the realistic side of it and
        // the finding is reported separately rather than being fixed in passing.
        props.ip.push_back(0x0A000001u + static_cast<uint32_t>(i)); // 10.0.0.1 upward
        boost::add_vertex(props, *graph);
    }
    return graph;
}

class KernelStopIsBoundedTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

// ================================================================================================
// The instrument control, first on purpose.
//
// Every timing assertion below passes if the fake control plane answers quickly, and a listener
// that is not actually wedged answers quickly. This case fails loudly in that situation, so the
// three after it are worth reading.
// ================================================================================================
TEST_F(KernelStopIsBoundedTest, TheInstrumentReallyWedgesACurl)
{
    WedgedControlPlane wedged(0);
    ASSERT_TRUE(wedged.bound()) << "could not bind an ephemeral port for the fake control plane";

    const std::string cmd = "curl -s --max-time 1 http://127.0.0.1:" + std::to_string(wedged.port())
                            + "/v1.0/topology/switches";
    const auto started = std::chrono::steady_clock::now();
    const std::string body = utils::execCommand(cmd);
    const auto elapsed = std::chrono::steady_clock::now() - started;

    EXPECT_TRUE(body.empty()) << "a wedged control plane must not produce a body; got: " << body;
    EXPECT_GE(elapsed, 900ms)
        << "curl came back in " << std::chrono::duration<double>(elapsed).count()
        << " s, so this listener is NOT wedged -- it is refusing or answering. Every timing "
           "assertion in this file would then pass without testing anything.";
    EXPECT_EQ(wedged.accepted(), 1) << "the listener did not accept the connection at all";
}

// ================================================================================================
// FINDINGS #27. The measured one: ~72 s inside DeviceConfigurationAndPowerManager::stop().
// ================================================================================================
TEST_F(KernelStopIsBoundedTest, AFlowTablePollCaughtMidRoundStopsWithinTheBound)
{
    WedgedControlPlane wedged(kP4ProxyPort);
    if (!wedged.bound())
    {
        GTEST_SKIP() << "port " << kP4ProxyPort << " is in use, so this test cannot control what "
                     << "the flow-table poll talks to. AppConfig::P4_PROXY_IP_AND_PORT is a "
                     << "compile-time constant; there is no seam to point it elsewhere.";
    }

    auto graph = fabricOfUpBmv2Switches(kSwitchesInFabric);
    auto graphMutex = std::make_shared<std::shared_mutex>();
    auto eventBus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, graphMutex, eventBus,
                                                            utils::MININET);
    // The monitor is never start()ed: this case is about the manager's own worker, and a second
    // poll loop would add a lifetime without adding a question.
    // A real Classifier, not nullptr. fetchOpenFlowTablesInternal ends in
    // m_classifier->updateFromQueriedTables(result), which the empty-topology fixture in
    // test_PowerManagerShutdown.cpp never reaches because its walk polls nothing -- a fabric with
    // switches in it does, and nullptr there is a segfault, not a test failure. main.cpp has
    // always passed one.
    auto classifier = std::make_shared<ndtClassifier::Classifier>();
    auto manager = std::make_shared<DeviceConfigurationAndPowerManager>(monitor, utils::MININET,
                                                                        "127.0.0.1", classifier);
    manager->start();

    // Mid-round is the whole point. Without this wait the stop could land during the 10 s sleep,
    // where trunk is already fast and the test would have no power to detect the defect.
    ASSERT_TRUE(wedged.waitForConnections(1, 10s))
        << "the flow-table worker never reached the fake proxy, so nothing was mid-round and this "
           "case measured a stop that had no in-flight request to wait for";

    const auto requestedAt = std::chrono::steady_clock::now();
    manager->stop();
    const auto elapsed = std::chrono::steady_clock::now() - requestedAt;

    EXPECT_LT(elapsed, kStopBound)
        << "stop() took " << std::chrono::duration<double>(elapsed).count()
        << " s with " << kSwitchesInFabric << " switches against a control plane that accepts and "
           "never answers. FINDINGS #27: the worker only reads its stop flag between rounds, so "
           "the stop waits out one `curl --max-time 8` per remaining switch.";
}

// ================================================================================================
// FINDINGS #76. The poll thread, blocked in the HTTP call main.cpp has already printed `Exiting`
// about.
// ================================================================================================
TEST_F(KernelStopIsBoundedTest, ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound)
{
    WedgedControlPlane wedged(0);
    ASSERT_TRUE(wedged.bound()) << "could not bind an ephemeral port for the fake control plane";

    auto graph = std::make_shared<Graph>();
    auto graphMutex = std::make_shared<std::shared_mutex>();
    auto eventBus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, graphMutex, eventBus,
                                                            utils::MININET);

    // Consume the one-shot static load BEFORE aiming the poll: start() calls loadStaticTopology(),
    // which ends in configureTopologyApiUrls(), which would re-point an all-bmv2 topology at the
    // proxy and undo the line below. Over this empty graph it returns without touching the URLs --
    // but ordering it this way means the test does not depend on that.
    (void)monitor->loadStaticTopology();
    monitor->setTopologyApiUrls("http://127.0.0.1:" + std::to_string(wedged.port())
                                + "/v1.0/topology");

    monitor->start();
    ASSERT_TRUE(wedged.waitForConnections(1, 10s))
        << "the poll thread never reached the fake control plane, so it was not blocked in an HTTP "
           "call and this case had no defect to detect";

    const auto requestedAt = std::chrono::steady_clock::now();
    monitor->stop();
    const auto elapsed = std::chrono::steady_clock::now() - requestedAt;

    EXPECT_LT(elapsed, kStopBound)
        << "stop() took " << std::chrono::duration<double>(elapsed).count()
        << " s while the poll was inside `curl --connect-timeout 2 --max-time 5`. FINDINGS #76: "
           "the kernel prints `Exiting` and then blocks here, so a restart script reading that "
           "line as 'it has exited' finds the port still held.";
}

// ================================================================================================
// The report. A bounded stop that is somehow still NOT bounded must say what it is waiting on --
// once, naming the worker and the subsystem, with the elapsed time -- rather than looking like a
// hang.
//
// 🔴 THESE TWO CASES USED TO BE INTEGRATION TESTS, AND THAT WAS THE BUG IN THEM.
//
// They started a real manager against the wedged control plane, set the report bound to 0, called
// stop(), and asserted the report appeared in the log. That form contains a race, and the mutation
// gate found it: two behaviour-PRESERVING widenings (the walk's top-of-loop stop check removed,
// and the between-endpoint checks removed) both turned AStopThatExceedsItsBoundSaysWhatItIsWaitingOn
// red, which is a gate reporting that its own suite cannot tell an edit from a behaviour change.
//
// The race: stop() runs m_running=false, then request() -- which kills the in-flight curl AND
// notify_all()s every sleeper -- and only then reportIfWorkersOutlastTheBound, whose
// waitForWorkers(0ms) samples the worker set ONCE. Between request()'s notify and that sample,
// the three woken workers are racing to break out of their loops and destroy their WorkerScopes.
// If they all win, the set is empty, the report correctly does not fire, and the assertion fails.
// Nothing about that is a property of the code under test: it is a property of which of four
// threads the scheduler ran first, and any edit that moves a few instructions on the worker's exit
// path -- which is exactly what a widening does -- reshuffles it.
//
// So the report is now exercised where it actually lives: a StopSignal the TEST owns, with a
// WorkerScope the TEST keeps alive for the duration of the call. The straggler is then a fact of
// the fixture rather than an outcome of a scheduling race, and the assertion is about what
// reportIfWorkersOutlastTheBound does with a straggler -- which is the whole of its behaviour.
//
// What this deliberately gives up is stated in FIX-KERNEL-STOP-BOUNDED.md §8.3: nothing here pins
// that DeviceConfigurationAndPowerManager::stop() still CALLS the report. That call site is
// defended by review, not by this suite, and saying so is better than a test that pretends to
// defend it two runs out of three.
// ================================================================================================
TEST_F(KernelStopIsBoundedTest, TheOverBoundReportNamesTheWorkerAndTheSubsystem)
{
    utils::StopSignal signal;
    // Held for the whole call, so "a worker is still running" is a fact of this fixture and not a
    // race the scheduler decides. This is the straggler the report exists to describe.
    utils::StopSignal::WorkerScope straggler(signal, "openflow-tables");
    signal.request();

    LogCapture captured;
    const bool reported =
        utils::reportIfWorkersOutlastTheBound(signal, std::chrono::milliseconds(0), "power manager");

    EXPECT_TRUE(reported) << "a worker was still registered and the bound had expired, so the "
                             "report had to fire";
    const std::string log = captured.text();
    ASSERT_GT(captured.recordCount(), 0u)
        << "the capture sink recorded nothing at all, so the assertions below would pass vacuously";
    // Deliberately NOT asserting the sentence. The wording is a diagnostic, not the behaviour, and
    // the gate's W2 rewords it precisely to prove this suite does not pin prose. What is asserted
    // is the two identifiers the report exists to carry.
    EXPECT_NE(log.find("openflow-tables"), std::string::npos)
        << "the report did not name the worker it is waiting on, which is the only part an "
           "operator can act on. Captured log:\n" << log;
    EXPECT_NE(log.find("power manager"), std::string::npos)
        << "the report did not name the subsystem whose stop passed its bound. Captured log:\n"
        << log;
}

// The monitor's names, same shape. Two cases rather than one parameterised case because what is
// being pinned is that each subsystem passes ITS OWN name and ITS OWN worker label.
TEST_F(KernelStopIsBoundedTest, TheMonitorsOverBoundReportNamesItsOwnWorker)
{
    utils::StopSignal signal;
    utils::StopSignal::WorkerScope straggler(signal, "topology-poll");
    signal.request();

    LogCapture captured;
    const bool reported = utils::reportIfWorkersOutlastTheBound(
        signal, std::chrono::milliseconds(0), "topology monitor");

    EXPECT_TRUE(reported);
    const std::string log = captured.text();
    EXPECT_NE(log.find("topology-poll"), std::string::npos)
        << "the report did not name the poll thread. Captured log:\n" << log;
    EXPECT_NE(log.find("topology monitor"), std::string::npos)
        << "the report did not name the subsystem. Captured log:\n" << log;
}

// 🔴 The zero-discrimination guard, and the reason the two cases above are worth reading.
//
// A report that fires unconditionally would satisfy every assertion above while telling an operator
// that a healthy shutdown is stuck. This is the same trap the gate's direction-2 mutations exist
// for: "it printed something" is not the property, "it printed something WHEN THERE WAS SOMETHING
// TO SAY" is.
TEST_F(KernelStopIsBoundedTest, TheReportSaysNothingWhenEveryWorkerHasAlreadyFinished)
{
    utils::StopSignal signal;
    {
        utils::StopSignal::WorkerScope finished(signal, "openflow-tables");
    } // gone before the report runs, which is what a healthy stop looks like
    signal.request();

    LogCapture captured;
    const bool reported =
        utils::reportIfWorkersOutlastTheBound(signal, std::chrono::milliseconds(0), "power manager");

    EXPECT_FALSE(reported) << "no worker was left, so there was nothing to report";
    EXPECT_EQ(captured.text().find("openflow-tables"), std::string::npos)
        << "the report named a worker that had already finished. Captured log:\n"
        << captured.text();
}

// Stopping twice, and stopping something that was never started, must both be free. main.cpp calls
// stop() explicitly and the destructors call it again; a bound that only holds the first time is
// not a bound.
TEST_F(KernelStopIsBoundedTest, StoppingTwiceAndStoppingWhatNeverRanAreBothImmediate)
{
    auto graph = std::make_shared<Graph>();
    auto graphMutex = std::make_shared<std::shared_mutex>();
    auto eventBus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, graphMutex, eventBus,
                                                            utils::MININET);
    // A real Classifier, not nullptr. fetchOpenFlowTablesInternal ends in
    // m_classifier->updateFromQueriedTables(result), which the empty-topology fixture in
    // test_PowerManagerShutdown.cpp never reaches because its walk polls nothing -- a fabric with
    // switches in it does, and nullptr there is a segfault, not a test failure. main.cpp has
    // always passed one.
    auto classifier = std::make_shared<ndtClassifier::Classifier>();
    auto manager = std::make_shared<DeviceConfigurationAndPowerManager>(monitor, utils::MININET,
                                                                        "127.0.0.1", classifier);

    const auto neverStartedAt = std::chrono::steady_clock::now();
    manager->stop();
    monitor->stop();
    EXPECT_LT(std::chrono::steady_clock::now() - neverStartedAt, kStopBound);

    manager->start();
    monitor->start();
    manager->stop();
    monitor->stop();

    const auto secondStopAt = std::chrono::steady_clock::now();
    manager->stop();
    monitor->stop();
    EXPECT_LT(std::chrono::steady_clock::now() - secondStopAt, kStopBound);
}

} // namespace
