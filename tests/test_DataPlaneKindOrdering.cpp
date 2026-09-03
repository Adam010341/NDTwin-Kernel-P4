/**
 * @file test_DataPlaneKindOrdering.cpp
 * @brief D15: the startup race that switched bmv2 liveness off for the whole process lifetime.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 *
 * TopologyAndFlowMonitor::start() only *spawned* the thread that parses the topology JSON, and
 * returned. main.cpp then ran on -- collector, historical data, event handler -- and about a
 * millisecond later called DeviceConfigurationAndPowerManager::start(), which asked
 * getSwitchKindGroups() whether the fabric is all-bmv2 and cached the answer for the life of the
 * process. Nothing sequenced the two. An empty switch-kind index is not "not bmv2", but it
 * answered like one, so `m_dataPlaneIsBmv2` latched false, `fetchP4SwitchState()` was never
 * called, p4LivenessFor always got nullopt -> Unknown, and the graph's switch liveness was never
 * written from evidence again.
 *
 * WHY A "DOES IT WORK" TEST IS NOT ENOUGH
 *
 * It is a genuine race and its outcome is decided by how long `file >> j` takes. Measured over 60
 * cold starts (doc/audit/2026-09-03_night-rounds/round3-restart-concurrency/SUMMARY.md, lead C):
 * the power manager WON 5/8 at a 310-byte topology and 5/8 at 587 bytes, and lost 44 of 44 at
 * 7.8 KB and above -- 0/20 on the shipped 4-host P4 model. So a test that merely checks the
 * liveness poll eventually happens would pass today and pass again the day someone puts the load
 * back on the spawned thread, as long as the topology in front of it is small enough. It would go
 * red only for whoever runs the real fabric.
 *
 * WHAT THESE ASSERT INSTEAD
 *
 * The ordering, in two forms that do not depend on parse speed:
 *
 *   1. WHO loaded the topology. start() must do it on the caller's thread, before it returns.
 *      A default-constructed id (nobody loaded it yet) and the poll thread's id (loaded, but
 *      concurrently with the caller) both fail, at any file size.
 *   2. That a verdict taken before the topology existed is NOT LATCHED. Even with the ordering
 *      reintroduced and won by luck, an answer derived from an empty index must be re-derived at
 *      the point of use rather than believed forever.
 *
 * Deliberately broader than the one line that was wrong: neither assertion mentions
 * refreshDataPlaneKind or where main.cpp puts its calls, so moving that code around cannot make
 * them vacuously green.
 */

#include <unistd.h> // getpid, for the per-process fixture path

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <thread>

namespace
{

/// The smallest topology that is unambiguously all-bmv2: one switch, brand BMv2, no edges.
/// Small on purpose. The defect's own measurements say a small file is where a racy
/// implementation gets away with it, so if any of these assertions can be satisfied by luck,
/// this is the file that would let it happen -- and none of them can.
constexpr const char* kOneBmv2Switch =
    R"({"nodes":[{"brand_name":"BMv2","bridge_name":"s1","device_layer":2,"device_name":"s1",)"
    R"("nickname":"s1","dpid":1,"ip":["192.168.123.11"],"mac":0,"smart_plug_ip":"",)"
    R"("smart_plug_outlet":0,"vertex_type":0}],"edges":[],"links":[]})";

class DataPlaneKindOrderingTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        // [Co-developed with claude code -- Adam]
        // Per process and per case, for the reason spelled out in test_PollDoesNotResurrect.cpp:
        // ctest runs one process per case, this suite has four of them, and a single fixed name
        // means two of them write and std::remove() the same file. Same defect, found by the
        // same grep; this one has not been observed failing, which is timing, not safety.
        m_topoPath = std::string(::testing::TempDir()) + "d15_one_bmv2_switch_" +
                     ::testing::UnitTest::GetInstance()->current_test_info()->name() + "_" +
                     std::to_string(static_cast<long>(::getpid())) + ".json";
        std::ofstream out(m_topoPath);
        ASSERT_TRUE(out.is_open()) << "cannot write the fixture topology to " << m_topoPath;
        out << kOneBmv2Switch;
        out.close();

        // activeTopologyPath() honours this, so start() loads the fixture rather than the
        // shipped model -- and nothing here touches a file under version control.
        ::setenv("NDTWIN_TOPO_FILE", m_topoPath.c_str(), 1);

        m_graph = std::make_shared<Graph>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_manager = std::make_shared<DeviceConfigurationAndPowerManager>(m_monitor,
                                                                         utils::MININET,
                                                                         "127.0.0.1",
                                                                         nullptr);
    }

    void TearDown() override
    {
        if (m_started)
        {
            // Reverse of the start order below. The manager's stop() joins all three of its
            // threads only since fix/b5-kernel-shutdown; before that this would have aborted.
            m_manager->stop();
            m_monitor->stop();
        }
        ::unsetenv("NDTWIN_TOPO_FILE");
        std::remove(m_topoPath.c_str());
    }

    /// The start sequence main.cpp uses -- monitor (main.cpp:409) then power manager
    /// (main.cpp:432) -- plus the bookkeeping that makes TearDown join both. The first
    /// draft started only the monitor, and TheStartupSequenceMainUsesYieldsABmv2Verdict was
    /// red for that reason alone: the manager's verdict is taken in its own start(), so a
    /// fixture that never calls it can only observe the lazy re-derive, not the sequence
    /// the test is named for.
    void startMonitor()
    {
        m_monitor->start();
        m_manager->start();
        m_started = true;
    }

    std::string m_topoPath;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_manager;
    bool m_started = false;
};

} // namespace

// --- 1. the ordering, asserted without timing anything -------------------------------------

/**
 * The postcondition every caller sequenced after start() in main.cpp silently assumed, and which
 * a comment in DeviceConfigurationAndPowerManager::start() used to assert outright ("the
 * switch-kind index is populated by now").
 */
TEST_F(DataPlaneKindOrderingTest, StartLoadsTheStaticTopologyBeforeItReturns)
{
    ASSERT_FALSE(m_monitor->isStaticTopologyLoaded())
        << "nothing should be loaded before start() is called";

    startMonitor();

    EXPECT_TRUE(m_monitor->isStaticTopologyLoaded())
        << "start() returned while the static topology was still being parsed; every consumer "
           "main.cpp sequences after it is now racing that parse";
    EXPECT_FALSE(m_monitor->getSwitchKindGroups().empty())
        << "the switch-kind index is empty after start() returned, which is indistinguishable "
           "from a fabric with no bmv2 switches in it";
}

/**
 * The speed-independent form. Whether a racy load *happens* to finish first depends on the size
 * of the topology file; which thread ran it does not.
 */
TEST_F(DataPlaneKindOrderingTest, TheLoadRunsOnTheCallersThreadNotOnTheSpawnedPollThread)
{
    const auto caller = std::this_thread::get_id();

    startMonitor();

    EXPECT_EQ(m_monitor->staticTopologyLoadedOnThread(), caller)
        << "the static topology was not loaded by start() itself. Loading it on the spawned poll "
           "thread leaves the load racing everything sequenced after start(), and that race is "
           "lost on every shipped topology file -- 0 wins in 44 cold starts at >= 7.8 KB";
}

// --- 2. the verdict, which must not be latched before it can be known ----------------------

/**
 * The half that survives someone reintroducing the race on a small file. Asking too early must
 * produce "not yet known", never a cached "not bmv2" -- those were the same value, and that is
 * the whole defect.
 */
TEST_F(DataPlaneKindOrderingTest, AVerdictTakenBeforeTheTopologyExistsIsNotCached)
{
    // Asked while nothing is loaded -- exactly what the old start() ordering did.
    EXPECT_FALSE(m_manager->dataPlaneIsBmv2());
    EXPECT_FALSE(m_manager->dataPlaneKindDetermined())
        << "an answer derived from an empty switch-kind index was recorded as determined; "
           "'no switches have been read yet' is not 'these switches are not bmv2'";

    // The topology arrives, exactly as it does in production -- just late.
    startMonitor();

    EXPECT_TRUE(m_manager->dataPlaneIsBmv2())
        << "the early verdict was believed forever. This is what switched the bmv2 liveness poll "
           "off for the whole process lifetime: 0 GET /p4/switch_state against 108 topology polls";
    EXPECT_TRUE(m_manager->dataPlaneKindDetermined());
}

/**
 * The outcome, in the order main.cpp actually uses: monitor first, power manager second. Kept
 * separate from the assertions above so that a green here can never stand in for them.
 */
TEST_F(DataPlaneKindOrderingTest, TheStartupSequenceMainUsesYieldsABmv2Verdict)
{
    startMonitor();

    EXPECT_TRUE(m_manager->dataPlaneKindDetermined())
        << "the data-plane kind is still undetermined after the topology was loaded";
    EXPECT_TRUE(m_manager->dataPlaneIsBmv2())
        << "an all-bmv2 topology was not recognised as one, so fetchP4SwitchState() will never "
           "be called and no switch will ever be marked down from evidence";
}
