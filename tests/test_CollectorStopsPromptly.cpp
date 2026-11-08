/**
 * @file test_CollectorStopsPromptly.cpp
 * @brief The sFlow collector's stop() returns promptly, and its queue, sleeps, fetch and drain
 *        cannot hang or abort a shutdown.
 *
 * [Co-developed with claude code -- Adam]
 *
 * One wait is still outside this: the first sample on an OVS fabric makes a worker run
 * `sudo ovs-vsctl list interface` once (populateIfIndexToOfportMap), and ovs-vsctl waits for ovsdb
 * with no timeout of its own. A stop while that is blocked waits for it. These tests send no
 * samples, so they do not reach it.
 *
 * `ndt down` sends the kernel SIGTERM, main() stops each subsystem in turn, and stack.sh KILLs the
 * kernel if it is still running 10 s later -- which also makes `ndt down` fail. Three things in
 * FlowLinkUsageCollector could spend that window or end the process instead of stopping it:
 *
 *   1. A lost wakeup in the worker queue. The stop flag was stored and the queue notified without
 *      the queue's mutex, so a worker between its check of the flag and its wait could miss the
 *      notification and sleep for good. run() joins the workers, stop() joins run(): a hang.
 *   2. Waits nothing could end. The destination-path fetch is `curl --max-time 10`, run through the
 *      plain executor, so a control plane that accepts and never answers held stop() for up to
 *      10 s. The periodic threads slept in 1 s slices or for a random 0.5-2 s, and only re-read the
 *      flag in between, so even an idle stop took one to two seconds.
 *   3. The drain after the stop called the packet handler outside the try/catch the main loop has,
 *      so a packet that threw while the queues emptied would end the process (std::terminate).
 *
 * WHAT IS ASSERTED
 *
 * For 2, the elapsed time from stop() being called to it returning, against kStopBound -- once with
 * the collector idle and once with a fetch in flight against a listener that accepts and never
 * writes. The bound is the receive thread's poll timeout (100 ms) plus margin for a loaded Debug
 * build; before the fix both cases take a second or more (the idle case at least the 0.8 s left of a
 * 1 s sleep, the fetch case up to 10 s), so the bound separates them by a wide factor.
 *
 * For 1 and 3, the queue and the worker loop directly (SPSCQueue.hpp), because both are about an
 * interleaving or an input a running collector cannot be made to produce on demand. The lost-wakeup
 * case does not hope to hit the race: its stop flag stalls inside the queue's own check, so the
 * notification is sent exactly in the gap the race needs, every run.
 *
 * Nothing here binds a fixed port: the collector binds an ephemeral sFlow port through its test seam,
 * and the fake control plane listens on an ephemeral TCP port.
 */

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/SPSCQueue.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <memory>
#include <netinet/in.h>
#include <random>
#include <shared_mutex>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace
{

using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;

/// What a stop may take. The receive thread polls with a 100 ms timeout, so ~100 ms is the floor of
/// a correct stop; 500 ms leaves room for a loaded Debug build. Before the fix an idle stop took at
/// least 0.8 s here and a stop with a fetch in flight took close to 10 s.
constexpr auto kStopBound = 500ms;

double
seconds(Clock::duration d)
{
    return std::chrono::duration<double>(d).count();
}

/**
 * @brief A TCP listener on an ephemeral loopback port that completes the handshake and then never
 *        writes. Connections are held open until it dies, so a curl against it waits out its own
 *        --max-time instead of finishing early on a closed connection.
 */
class SilentListener
{
  public:
    SilentListener()
    {
        m_fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (m_fd < 0)
        {
            return;
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        socklen_t len = sizeof(addr);
        if (::bind(m_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0
            || ::listen(m_fd, 16) != 0
            || ::getsockname(m_fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0)
        {
            ::close(m_fd);
            m_fd = -1;
            return;
        }
        m_port = ::ntohs(addr.sin_port);
        m_accepting.store(true);
        m_thread = std::thread([this] { acceptLoop(); });
    }

    ~SilentListener()
    {
        m_accepting.store(false);
        if (m_fd >= 0)
        {
            ::shutdown(m_fd, SHUT_RDWR); // wakes the accept()
        }
        if (m_thread.joinable())
        {
            m_thread.join();
        }
        if (m_fd >= 0)
        {
            ::close(m_fd);
        }
        for (const int fd : m_held)
        {
            ::close(fd);
        }
    }

    SilentListener(const SilentListener&) = delete;
    SilentListener& operator=(const SilentListener&) = delete;

    bool bound() const { return m_port != 0; }
    std::string hostAndPort() const { return "127.0.0.1:" + std::to_string(m_port); }

    bool waitForConnections(int n, Clock::duration limit)
    {
        const auto deadline = Clock::now() + limit;
        while (Clock::now() < deadline && m_accepted.load() < n)
        {
            std::this_thread::sleep_for(20ms);
        }
        return m_accepted.load() >= n;
    }

  private:
    void acceptLoop()
    {
        while (m_accepting.load())
        {
            const int fd = ::accept(m_fd, nullptr, nullptr);
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

    int m_fd = -1;
    uint16_t m_port = 0;
    std::atomic<bool> m_accepting{false};
    std::atomic<int> m_accepted{0};
    std::thread m_thread;
    std::vector<int> m_held;
};

/// The real collector, with its sFlow socket on an ephemeral port. The power manager is never used
/// by the collector's threads, so it is null; the monitor is real and never started.
class PromptCollector : public sflow::FlowLinkUsageCollector
{
  public:
    PromptCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                    std::shared_ptr<EventBus> bus,
                    std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
        setReceivePortForTesting(0);
    }

    using sflow::FlowLinkUsageCollector::receiveSocketForTesting;
    using sflow::FlowLinkUsageCollector::setControlPlaneForTesting;
};

std::unique_ptr<PromptCollector>
makeCollector()
{
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            bus,
                                                            utils::DeploymentMode::MININET);
    return std::make_unique<PromptCollector>(monitor,
                                             bus,
                                             std::make_shared<ndtClassifier::Classifier>());
}

/// Ends the process if a step does not finish in time. A lost wakeup is a hang, and a hung test
/// binary says nothing until ctest's own timeout; this says which step and exits non-zero at once.
class Watchdog
{
  public:
    Watchdog(Clock::duration limit, std::string what) : m_what(std::move(what))
    {
        m_thread = std::thread(
            [this, limit]
            {
                const auto deadline = Clock::now() + limit;
                while (!m_done.load())
                {
                    if (Clock::now() >= deadline)
                    {
                        std::fprintf(stderr,
                                     "WATCHDOG: %s did not finish in time -- the stop is hung\n",
                                     m_what.c_str());
                        std::fflush(stderr);
                        std::_Exit(3);
                    }
                    std::this_thread::sleep_for(10ms);
                }
            });
    }
    ~Watchdog()
    {
        m_done.store(true);
        m_thread.join();
    }
    Watchdog(const Watchdog&) = delete;
    Watchdog& operator=(const Watchdog&) = delete;

  private:
    std::string m_what;
    std::atomic<bool> m_done{false};
    std::thread m_thread;
};

/**
 * @brief A stop flag whose first check stalls while it reads "still running".
 *
 * pop() evaluates `running.load()` with the queue's mutex held, as the last thing before it waits.
 * Stalling there holds the worker in exactly the gap the lost wakeup needs -- checked, not yet
 * waiting -- for long enough that a stop sent during the stall lands in it every time.
 */
class StallingStopFlag
{
  public:
    bool load() const
    {
        const bool running = m_running.load();
        if (running && m_stallNextCheck.exchange(false))
        {
            m_stalling.store(true);
            std::this_thread::sleep_for(100ms);
        }
        return running;
    }

    void store(bool running) { m_running.store(running); }
    void stallNextCheck() { m_stallNextCheck.store(true); }
    bool stalling() const { return m_stalling.load(); }

  private:
    std::atomic<bool> m_running{true};
    mutable std::atomic<bool> m_stallNextCheck{false};
    mutable std::atomic<bool> m_stalling{false};
};

/// Threads in this process right now. The collector's threads have no names to look for, so a test
/// counts before start() and waits for the count to come back.
std::size_t
threadCount()
{
    std::size_t n = 0;
    for ([[maybe_unused]] const auto& entry : std::filesystem::directory_iterator("/proc/self/task"))
    {
        ++n;
    }
    return n;
}

bool
waitUntil(const std::atomic<bool>& flag, Clock::duration limit)
{
    const auto deadline = Clock::now() + limit;
    while (!flag.load() && Clock::now() < deadline)
    {
        std::this_thread::sleep_for(1ms);
    }
    return flag.load();
}

class CollectorStopsPromptlyTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

} // namespace

// ================================================================================================
// 1. The lost wakeup, at the queue: a worker that has checked the flag but is not yet waiting.
// ================================================================================================
TEST_F(CollectorStopsPromptlyTest, AWorkerBetweenItsCheckAndItsWaitIsStillWokenByTheStop)
{
    sflow::SPSCQueue<int> queue(4);
    StallingStopFlag running;
    running.stallNextCheck();

    std::atomic<bool> returned{false};
    bool popped = true;
    std::thread worker(
        [&]
        {
            int item = 0;
            popped = queue.pop(item, running);
            returned.store(true);
        });

    const auto deadline = Clock::now() + 5s;
    while (!running.stalling() && Clock::now() < deadline)
    {
        std::this_thread::sleep_for(1ms);
    }
    ASSERT_TRUE(running.stalling()) << "the worker never reached the queue's check of the flag";

    // What the collector's stop does to every queue: store the flag, then notify.
    running.store(false);
    queue.notify_all();

    const bool wokeByTheStop = waitUntil(returned, 2s);
    if (!wokeByTheStop)
    {
        // The worker is waiting by now, so a second notification reaches it; without this the
        // test would hang instead of failing.
        queue.notify_all();
    }
    worker.join();

    EXPECT_TRUE(wokeByTheStop)
        << "the stop's notification reached the queue while the worker was between its check of "
           "the flag and its wait, and the worker then slept through it: the collector's join of "
           "this worker would never return";
    EXPECT_FALSE(popped) << "a stopped, empty queue must report that it is drained";
}

// The same race left to the scheduler: many workers entering pop() while the stop arrives. A
// lost wakeup leaves one of them asleep; it is woken again afterwards so the case fails instead
// of hanging.
TEST_F(CollectorStopsPromptlyTest, StopsRacingWorkersIntoTheirWaitNeverLoseOne)
{
    constexpr int kRounds = 2000;
    constexpr int kWorkers = 8;
    std::mt19937 gen(4242);
    std::uniform_int_distribution<int> spin(0, 20000);

    int lost = 0;
    for (int round = 0; round < kRounds; ++round)
    {
        sflow::SPSCQueue<int> queue(4);
        std::atomic_bool running{true};
        std::atomic<int> returned{0};
        std::vector<std::thread> workers;
        workers.reserve(kWorkers);
        for (int i = 0; i < kWorkers; ++i)
        {
            workers.emplace_back(
                [&]
                {
                    int item = 0;
                    (void)queue.pop(item, running);
                    returned.fetch_add(1);
                });
        }
        const auto spinUntil = Clock::now() + std::chrono::nanoseconds(spin(gen));
        while (Clock::now() < spinUntil)
        {
        }
        running.store(false);
        queue.notify_all();

        const auto deadline = Clock::now() + 1s;
        while (returned.load() < kWorkers && Clock::now() < deadline)
        {
            std::this_thread::yield();
        }
        if (returned.load() < kWorkers)
        {
            ++lost;
            queue.notify_all();
        }
        for (auto& w : workers)
        {
            w.join();
        }
    }
    EXPECT_EQ(lost, 0) << lost << " of " << kRounds << " stops left a worker asleep";
}

// ================================================================================================
// 3. The drain: an item that throws after the stop is reported, and the rest are still handled.
// ================================================================================================
TEST_F(CollectorStopsPromptlyTest, AnItemThatThrowsDuringTheDrainIsReportedAndTheRestAreHandled)
{
    sflow::SPSCQueue<int> queue(16);
    std::atomic_bool running{true};
    for (int i = 1; i <= 5; ++i)
    {
        ASSERT_TRUE(queue.tryPush(int(i), running));
    }
    // Stopped with five items queued: everything below happens in the drain.
    running.store(false);

    std::vector<int> handled;
    std::vector<std::string> reports;
    EXPECT_NO_THROW(sflow::serveUntilDrained(
        queue,
        running,
        [&](int& item)
        {
            handled.push_back(item);
            if (item == 2)
            {
                throw std::runtime_error("malformed datagram");
            }
            if (item == 4)
            {
                throw 4; // not a std::exception
            }
        },
        [&](const std::exception* e) { reports.push_back(e ? e->what() : "unknown"); }))
        << "an exception left the drain; on a worker thread that is std::terminate";

    EXPECT_EQ(handled, (std::vector<int>{1, 2, 3, 4, 5}))
        << "the items after the one that threw must still be handled";
    EXPECT_EQ(reports, (std::vector<std::string>{"malformed datagram", "unknown"}));
}

// The control for the case above: the same handler while running, where the catch always was.
TEST_F(CollectorStopsPromptlyTest, AnItemThatThrowsWhileRunningIsReportedAndTheRestAreHandled)
{
    sflow::SPSCQueue<int> queue(16);
    std::atomic_bool running{true};
    for (int i = 1; i <= 3; ++i)
    {
        ASSERT_TRUE(queue.tryPush(int(i), running));
    }

    std::vector<int> handled;
    std::vector<std::string> reports;
    sflow::serveUntilDrained(
        queue,
        running,
        [&](int& item)
        {
            handled.push_back(item);
            if (item == 1)
            {
                throw std::runtime_error("malformed datagram");
            }
            if (item == 3)
            {
                running.store(false); // the last one: stop, and let pop() see the empty queue
            }
        },
        [&](const std::exception* e) { reports.push_back(e ? e->what() : "unknown"); });

    EXPECT_EQ(handled, (std::vector<int>{1, 2, 3}));
    EXPECT_EQ(reports, (std::vector<std::string>{"malformed datagram"}));
}

// ================================================================================================
// 2. The collector's own threads: an idle stop, and a stop with a destination-path fetch in flight.
// ================================================================================================
TEST_F(CollectorStopsPromptlyTest, AnIdleCollectorStopsWithinTheBound)
{
    auto collector = makeCollector();
    collector->start(2, 64);
    // Long enough for every thread to be in its first sleep, so this times a stop and not a start.
    std::this_thread::sleep_for(200ms);

    Watchdog watchdog(30s, "stop() of an idle collector");
    const auto requestedAt = Clock::now();
    collector->stop();
    const auto elapsed = Clock::now() - requestedAt;

    std::printf("idle stop took %.3f s\n", seconds(elapsed));
    EXPECT_LT(elapsed, kStopBound)
        << "stop() took " << seconds(elapsed) << " s with nothing in flight: the periodic threads "
           "sleep out their current interval instead of waking on the stop";
}

TEST_F(CollectorStopsPromptlyTest, ADestinationPathFetchInFlightIsCancelledByStop)
{
    SilentListener controlPlane;
    ASSERT_TRUE(controlPlane.bound()) << "could not bind an ephemeral port for the fake control plane";

    auto collector = makeCollector();
    collector->setControlPlaneForTesting(controlPlane.hostAndPort());
    collector->start(2, 64);

    // The refresh thread sleeps 5 s before its first fetch. Mid-request is the point: a stop that
    // lands while it sleeps has no fetch to cancel.
    ASSERT_TRUE(controlPlane.waitForConnections(1, 15s))
        << "the destination-path fetch never reached the fake control plane, so nothing was in "
           "flight and this case could not measure anything";

    Watchdog watchdog(30s, "stop() with a destination-path fetch in flight");
    const auto requestedAt = Clock::now();
    collector->stop();
    const auto elapsed = Clock::now() - requestedAt;

    std::printf("stop with a fetch in flight took %.3f s\n", seconds(elapsed));
    EXPECT_LT(elapsed, kStopBound)
        << "stop() took " << seconds(elapsed) << " s while the destination-path fetch was waiting "
           "on a control plane that accepted and never answered: the fetch's curl was waited out "
           "(--max-time 10) instead of being killed";
}

// Many stops racing the workers into their first wait. A hang here is the lost wakeup reached
// through the real collector; the watchdog turns it into a failure with a message.
TEST_F(CollectorStopsPromptlyTest, RepeatedStartAndStopNeverHangsAndStaysWithinTheBound)
{
    constexpr int kRounds = 20;
    std::mt19937 gen(12345);
    std::uniform_int_distribution<int> delayMs(0, 50);

    Clock::duration slowest{};
    for (int round = 0; round < kRounds; ++round)
    {
        auto collector = makeCollector();
        collector->start(4, 64);
        std::this_thread::sleep_for(std::chrono::milliseconds(delayMs(gen)));

        Watchdog watchdog(30s, "stop() in round " + std::to_string(round));
        const auto requestedAt = Clock::now();
        collector->stop();
        const auto elapsed = Clock::now() - requestedAt;
        slowest = std::max(slowest, elapsed);
        EXPECT_LT(elapsed, kStopBound) << "round " << round << ": stop() took " << seconds(elapsed) << " s";
    }
    std::printf("slowest of %d stops: %.3f s\n", kRounds, seconds(slowest));
}

// [Co-developed with claude code -- Adam]
// One collector, stopped and started again: the second run must work (here: it asks the control
// plane for destination paths again) and stop within the bound too. start() has to re-arm the stop
// signal for that; without it the restarted threads see the old stop and quit at once.
TEST_F(CollectorStopsPromptlyTest, AStoppedCollectorStartedAgainWorksAndStopsWithinTheBound)
{
    SilentListener controlPlane;
    ASSERT_TRUE(controlPlane.bound()) << "could not bind an ephemeral port for the fake control plane";

    auto collector = makeCollector();
    collector->setControlPlaneForTesting(controlPlane.hostAndPort());
    for (int run = 1; run <= 2; ++run)
    {
        collector->start(2, 64);
        ASSERT_TRUE(controlPlane.waitForConnections(run, 15s))
            << "after start number " << run << " the destination-path refresh never asked the "
               "control plane: a restarted collector is not doing its work";

        Watchdog watchdog(30s, "stop() number " + std::to_string(run));
        const auto requestedAt = Clock::now();
        collector->stop();
        const auto elapsed = Clock::now() - requestedAt;
        std::printf("stop number %d took %.3f s\n", run, seconds(elapsed));
        EXPECT_LT(elapsed, kStopBound) << "stop number " << run << " took " << seconds(elapsed) << " s";
    }
}

// [Co-developed with claude code -- Adam]
// The receive loop also ends on its own, on a socket error. The collector has then stopped
// collecting, and its periodic threads must end with it rather than at their next wake -- the
// destination-path refresh sleeps 60 s once it has paths. The socket is replaced with /dev/null,
// so the loop's next poll returns at once and recvmmsg() fails (ENOTSOCK), as on a real error.
TEST_F(CollectorStopsPromptlyTest, AReceiveLoopThatFailsOnItsOwnTakesThePeriodicThreadsWithIt)
{
    auto collector = makeCollector();
    // Paths already known, so the refresh thread sleeps its long interval, not the 5 s retry.
    collector->setAllPaths({sflow::Path{{0x0100000Au, 0u}, {1u, 1u}, {0x0200000Au, 0u}}});

    const std::size_t before = threadCount();
    collector->start(2, 64);
    std::this_thread::sleep_for(200ms);
    ASSERT_GT(threadCount(), before) << "start() started no thread this test can count";

    const int fd = collector->receiveSocketForTesting();
    ASSERT_GE(fd, 0) << "the collector has no receive socket";
    const int devNull = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
    ASSERT_GE(devNull, 0);
    ASSERT_GE(::dup2(devNull, fd), 0);
    ::close(devNull);

    const auto failedAt = Clock::now();
    while (threadCount() > before && Clock::now() - failedAt < 5s)
    {
        std::this_thread::sleep_for(10ms);
    }
    const auto elapsed = Clock::now() - failedAt;
    const std::size_t left = threadCount() - std::min(threadCount(), before);
    std::printf("threads ended %.3f s after the receive loop failed (%zu left)\n", seconds(elapsed), left);
    EXPECT_LT(elapsed, 1s) << left << " collector thread(s) still running " << seconds(elapsed)
                           << " s after the receive loop ended on its own: they sleep out their "
                              "interval (60 s for the destination-path refresh) instead of waking";

    Watchdog watchdog(30s, "stop() after the receive loop failed");
    collector->stop();
}
