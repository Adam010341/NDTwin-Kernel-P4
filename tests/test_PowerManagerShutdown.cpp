/**
 * @file test_PowerManagerShutdown.cpp
 * @brief KNOWN-ISSUES B-5: the kernel aborts on its own shutdown path.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 *
 * DeviceConfigurationAndPowerManager::start() launches three workers -- m_pingThread,
 * m_statusUpdateThread and m_openflowTablesUpdateThread -- and stop() joined the first two.
 * The class declared no destructor, so the implicit one destroyed a std::thread that was still
 * joinable, which is std::terminate: "terminate called without an active exception", SIGABRT,
 * exit status 134. Reproduced 7/7 against build/bin/ndtwin_kernel on SIGINT (idle, with requests
 * in flight, 1s and 20s after startup); gdb put the abort at
 * std::thread::~thread <- ~DeviceConfigurationAndPowerManager, and the thread object's offset
 * inside the manager (104) is m_openflowTablesUpdateThread's.
 *
 * WHY NOBODY SAW IT
 *
 * main() registers a handler for SIGINT only (src/main.cpp:314). `ndt down` sends SIGTERM, whose
 * default action kills the process on the spot: no destructors, no abort, exit status 143. The
 * crash is reachable only from the shutdown a human performs by hand -- Ctrl-C in a terminal --
 * which is the manual usertest and nothing else.
 *
 * WHY THESE ARE DEATH TESTS
 *
 * The failure IS process death, so it cannot be observed from inside the process that suffers it:
 * an EXPECT in this binary would never run. EXPECT_EXIT forks (threadsafe style: re-execs), runs
 * the lifecycle in the child and reads the child's exit status, which is the same evidence the
 * live reproduction collects -- 134 vs 0.
 *
 * WHAT THEY ASSERT, DELIBERATELY BROADER THAN THE ONE BUG
 *
 * Not "m_openflowTablesUpdateThread is joined" -- that is the fix restated, and a fourth worker
 * added tomorrow would compile, run and re-open exactly this hole without reddening anything.
 * The assertion is the shape: after the manager is destroyed, no thread it owns may still be
 * joinable, whether or not stop() was called first. The mutation gate proves the difference by
 * adding a NEW unjoined worker; both cases below must go red for it.
 */

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <gtest/gtest.h>

#include <csignal>
#include <cstdlib>
#include <memory>
#include <shared_mutex>
#include <thread>

namespace
{

/// A manager over an EMPTY topology: every worker loop iterates over zero switches, so the
/// three threads start, find nothing to poll and sleep -- no controller, no fabric and no
/// network traffic are needed to reproduce B-5, which is a property of the object's own
/// lifetime. MININET mode also skips the smart-plug file read in start().
std::shared_ptr<DeviceConfigurationAndPowerManager>
makeManagerOverAnEmptyTopology()
{
    auto graph = std::make_shared<Graph>();
    auto graphMutex = std::make_shared<std::shared_mutex>();
    auto eventBus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, graphMutex, eventBus,
                                                            utils::MININET);
    // The monitor is NOT start()ed: pingWorker only reads its graph, and a poll loop of its own
    // would add a second lifetime to this test without adding a question.
    return std::make_shared<DeviceConfigurationAndPowerManager>(monitor,
                                                                utils::MININET,
                                                                "127.0.0.1",
                                                                nullptr);
}

} // namespace

class PowerManagerShutdownDeathTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        // The code under test logs on every path exercised here and Logger::instance() is a null
        // shared_ptr until init runs. Level off, so a green run stays quiet.
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        // Re-exec rather than fork: this binary runs other suites' background threads in the same
        // process, and forking a multi-threaded process to then take spdlog's mutex is how a
        // death test deadlocks instead of answering.
        GTEST_FLAG_SET(death_test_style, "threadsafe");
    }
};

// The instrument control, first on purpose.
//
// Every other case here passes by NOT observing an abort, and a harness that could not see one
// would pass them all. This destroys a joinable std::thread deliberately: if the child does not
// die by SIGABRT with the message from the B-5 report, the two assertions below are worthless and
// this test says so before they are read.
TEST_F(PowerManagerShutdownDeathTest, DestroyingAJoinableThreadIsVisibleToThisHarness)
{
    EXPECT_EXIT(
        {
            {
                std::thread neverJoined([] {});
            } // destroyed while joinable -> std::terminate
            std::exit(0);
        },
        ::testing::KilledBySignal(SIGABRT),
        "terminate called without an active exception");
}

// The path the kernel takes: main stops every subsystem, then the shared_ptrs go away.
// Pre-fix this child died with signal 6 and printed the B-5 message; post-fix it exits 0.
TEST_F(PowerManagerShutdownDeathTest, AStoppedManagerIsDestroyedWithoutAborting)
{
    EXPECT_EXIT(
        {
            {
                auto manager = makeManagerOverAnEmptyTopology();
                manager->start();
                manager->stop();
            } // destructor
            std::exit(0);
        },
        ::testing::ExitedWithCode(0),
        "");
}

// The path nobody writes down: started, then dropped without a stop() -- an early return, a
// throw on a startup path, or any owner that simply lets go. The destructor has to be enough on
// its own, which is why it exists rather than relying on main's call ordering.
TEST_F(PowerManagerShutdownDeathTest, AManagerNeverStoppedIsDestroyedWithoutAborting)
{
    EXPECT_EXIT(
        {
            {
                auto manager = makeManagerOverAnEmptyTopology();
                manager->start();
            } // destructor, with no stop() in front of it
            std::exit(0);
        },
        ::testing::ExitedWithCode(0),
        "");
}
