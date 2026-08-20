/**
 * The historical link-data feature, which was dead in five independent places.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Every layer of /ndt/set_historical_logging_state was broken, and each break alone was enough
 * to make the feature inert, so fixing any one of them would have changed nothing observable:
 *
 *  1. ControllerAndOtherEventHandler took a HistoricalDataManager and never stored it -- the
 *     initialiser list ended at m_lockManager. The member stayed null, doAccept handed null to
 *     every HttpSession, and the endpoint's guard answered a permanent 500 "Historical data
 *     manager not available", even though main.cpp had built a real instance and passed it.
 *  2. main.cpp built *two separate* HistoricalDataManagers. The one that was start()ed was not
 *     the one handed to the session layer, so even with (1) fixed the toggle would have set a
 *     flag on an object whose recording thread had never run.
 *  3. m_loggingEnabled was stored by setLoggingState and read by nothing at all, so even with
 *     (1) and (2) fixed the toggle still gated nothing.
 *  4. The constructor called create_directories with the *throwing* overload, unconditionally,
 *     in both deployment modes -- so an uncreatable directory killed the kernel at startup from
 *     a data-logging nicety.
 *  5. The write path opened an ofstream per edge and never checked is_open() or the stream
 *     state. On this machine the output directory is root-owned and the kernel runs
 *     unprivileged, so every TESTBED run appended into dead streams and wrote nothing, with no
 *     log line ever.
 *
 * The output path itself is deliberately NOT changed -- it is an absolute path into another
 * user's home directory, which is a real defect, but something outside this repository is
 * understood to read from there. writeSnapshot takes the directory as a parameter purely so a
 * test can point it somewhere writable; production passes HistoricalDataManager::OUTPUT_DIR and
 * the path is unchanged.
 */

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "ndt_core/event_handling/ControllerAndOtherEventHandler.hpp"
#include "utils/Utils.hpp"

/// Reads back the member the constructor was supposed to store. Global scope: friend declaration.
class ControllerAndOtherEventHandlerTestPeer
{
  public:
    static std::shared_ptr<HistoricalDataManager>
    historicalDataManagerOf(const ControllerAndOtherEventHandler& handler)
    {
        return handler.m_historicalDataManager;
    }
};

namespace
{

/// A writable scratch directory that cleans itself up.
class TempDir
{
  public:
    explicit TempDir(const std::string& name)
        : m_path(std::filesystem::temp_directory_path() / name)
    {
        std::filesystem::remove_all(m_path);
        std::filesystem::create_directories(m_path);
    }

    ~TempDir()
    {
        std::error_code ec;
        std::filesystem::permissions(m_path,
                                     std::filesystem::perms::owner_all,
                                     std::filesystem::perm_options::add,
                                     ec);
        std::filesystem::remove_all(m_path, ec);
    }

    std::string str() const { return m_path.string(); }
    const std::filesystem::path& path() const { return m_path; }

    std::size_t fileCount() const
    {
        std::size_t n = 0;
        std::error_code ec;
        for (auto it = std::filesystem::directory_iterator(m_path, ec);
             it != std::filesystem::directory_iterator();
             ++it)
        {
            ++n;
        }
        return n;
    }

  private:
    std::filesystem::path m_path;
};

class HistoricalLoggingTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_manager = std::make_shared<HistoricalDataManager>(m_monitor, utils::MININET);
    }

    /// One switch-to-switch edge, which is one CSV row.
    void addEdge(uint64_t srcDpid, uint64_t dstDpid)
    {
        const auto u = boost::add_vertex(*m_graph);
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[u].vertexType = VertexType::SWITCH;
        (*m_graph)[u].dpid = srcDpid;
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dstDpid;

        EdgeProperties ep;
        ep.srcDpid = srcDpid;
        ep.dstDpid = dstDpid;
        ep.linkBandwidth = 1000;
        ep.linkBandwidthUsage = 42;
        boost::add_edge(u, v, ep, *m_graph);
    }

    static std::time_t fixedTime() { return 1755000000; }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<HistoricalDataManager> m_manager;
};

} // namespace

// --- layer 1: the constructor actually stores what it is given ---------------------------------

TEST(HistoricalLoggingWiringTest, TheEventHandlerStoresTheHistoricalDataManagerItIsGiven)
{
    boost::asio::io_context ioc;
    auto graph = std::make_shared<Graph>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph,
                                                            std::make_shared<std::shared_mutex>(),
                                                            std::make_shared<EventBus>(),
                                                            utils::MININET);
    auto historical = std::make_shared<HistoricalDataManager>(monitor, utils::MININET);

    ControllerAndOtherEventHandler handler(ioc,
                                           monitor,
                                           nullptr, // collector
                                           nullptr, // flowRoutingManager
                                           nullptr, // deviceConfigurationAndPowerManager
                                           nullptr, // eventBus
                                           nullptr, // applicationManager
                                           nullptr, // simManager
                                           nullptr, // intentTranslator
                                           historical,
                                           nullptr, // controller
                                           nullptr, // lockManager
                                           utils::MININET,
                                           "");

    EXPECT_EQ(ControllerAndOtherEventHandlerTestPeer::historicalDataManagerOf(handler).get(),
              historical.get())
        << "the constructor dropped the HistoricalDataManager, so every HttpSession gets null "
           "and /ndt/set_historical_logging_state answers a permanent 500";
}

// --- layer 3: the toggle gates the writer ------------------------------------------------------

TEST_F(HistoricalLoggingTest, DisablingLoggingStopsRowsBeingWritten)
{
    TempDir dir("ndtwin_test_historical_disabled");
    addEdge(1, 2);

    m_manager->setLoggingState(false);
    const auto rows = m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());

    EXPECT_EQ(rows, 0u);
    EXPECT_EQ(dir.fileCount(), 0u) << "a file was created even though logging was disabled";
}

/// The accept path. "Never writes anything" would pass the test above.
TEST_F(HistoricalLoggingTest, LoggingEnabledWritesOneRowPerEdge)
{
    TempDir dir("ndtwin_test_historical_enabled");
    addEdge(1, 2);
    addEdge(2, 3);

    const auto rows = m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());

    EXPECT_EQ(rows, 2u);
    EXPECT_EQ(dir.fileCount(), 2u) << "one CSV per link";
}

TEST_F(HistoricalLoggingTest, ReEnablingLoggingResumesWriting)
{
    TempDir dir("ndtwin_test_historical_reenabled");
    addEdge(1, 2);

    m_manager->setLoggingState(false);
    ASSERT_EQ(m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime()), 0u);
    EXPECT_FALSE(m_manager->isLoggingEnabled());

    m_manager->setLoggingState(true);
    EXPECT_TRUE(m_manager->isLoggingEnabled());
    EXPECT_EQ(m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime()), 1u);
}

TEST_F(HistoricalLoggingTest, TheWrittenRowCarriesTheEdgesBandwidthFigures)
{
    TempDir dir("ndtwin_test_historical_content");
    addEdge(1, 2);

    ASSERT_EQ(m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime()), 1u);

    std::string contents;
    for (const auto& entry : std::filesystem::directory_iterator(dir.path()))
    {
        std::ifstream in(entry.path());
        contents.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    }

    EXPECT_NE(contents.find("date-time,srcType,srcId,dstType,dstId,link_bw,link_bw_usage"),
              std::string::npos)
        << contents;
    EXPECT_NE(contents.find(",1000,42"), std::string::npos) << contents;
}

// --- layer 5: an unwritable directory is loud, and loud once -----------------------------------

TEST_F(HistoricalLoggingTest, AnUnwritableDirectoryIsReportedRatherThanSilentlyLosingData)
{
    TempDir dir("ndtwin_test_historical_unwritable");
    addEdge(1, 2);
    addEdge(2, 3);
    addEdge(3, 4);

    // Read+execute only: the paths resolve, but the files cannot be created. This is the shape of
    // the real failure, where the directory is root-owned and the kernel is unprivileged.
    std::filesystem::permissions(dir.path(),
                                 std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::remove);

    const auto rows = m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());

    EXPECT_EQ(rows, 0u) << "writeSnapshot claimed to have written rows into an unwritable "
                           "directory";
    EXPECT_EQ(m_manager->writeFailureReports(), 1u)
        << "three edges failed and the failure must be reported, exactly once";
}

TEST_F(HistoricalLoggingTest, RepeatedFailuresAreReportedOnceNotOncePerInterval)
{
    TempDir dir("ndtwin_test_historical_repeat");
    addEdge(1, 2);
    std::filesystem::permissions(dir.path(),
                                 std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::remove);

    for (int i = 0; i < 5; ++i)
    {
        m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());
    }

    EXPECT_EQ(m_manager->writeFailureReports(), 1u)
        << "five failing intervals must not produce five ERROR lines";
}

/// ...but a directory that becomes writable again must be able to report a *later* failure.
TEST_F(HistoricalLoggingTest, AFailureAfterARecoveryIsReportedAgain)
{
    TempDir dir("ndtwin_test_historical_recover");
    addEdge(1, 2);

    std::filesystem::permissions(dir.path(),
                                 std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::remove);
    m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());
    ASSERT_EQ(m_manager->writeFailureReports(), 1u);

    std::filesystem::permissions(dir.path(),
                                 std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::add);
    ASSERT_EQ(m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime()), 1u) << "recovered";

    // The CSV the recovery wrote has to go before the directory is locked again. Appending to an
    // *existing* file needs no write permission on its directory -- only creating one does -- so
    // leaving it in place makes the third snapshot succeed and tests nothing. (This test failed
    // for exactly that reason when first written.)
    for (const auto& entry : std::filesystem::directory_iterator(dir.path()))
    {
        std::filesystem::remove(entry.path());
    }
    std::filesystem::permissions(dir.path(),
                                 std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::remove);
    m_manager->writeSnapshot(*m_graph, dir.str(), fixedTime());

    EXPECT_EQ(m_manager->writeFailureReports(), 2u)
        << "the report latch must clear on a successful write, or a second outage is invisible";
}

// --- layer 4: an uncreatable output directory must not kill the kernel --------------------------

TEST(HistoricalLoggingStartupTest, ConstructionDoesNotThrowWhenTheOutputDirectoryCannotBeMade)
{
    // OUTPUT_DIR is an absolute path into another user's home. On this machine it either exists
    // and is root-owned or cannot be created at all; either way the constructor must survive it,
    // because main.cpp runs it unconditionally in both deployment modes before anything else.
    auto graph = std::make_shared<Graph>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph,
                                                            std::make_shared<std::shared_mutex>(),
                                                            std::make_shared<EventBus>(),
                                                            utils::MININET);

    EXPECT_NO_THROW({ HistoricalDataManager manager(monitor, utils::MININET); });
}

TEST(HistoricalLoggingModeGateTest, MininetReportsThatItCannotRecordRatherThanImplyingItDid)
{
    // start() returns early in MININET, so the recorder thread is never spawned and no row is
    // ever written -- but setLoggingState() still flipped the flag and the endpoint still
    // answered 200 {"status":"success","Historical data logging has been enabled."}. Both lab
    // stacks run MININET, so that success message was false on every deployment this project has
    // measured on. Anyone who enabled logging and then went looking for the CSV found nothing,
    // with no way to tell a broken recorder from one that was never going to run.
    //
    // canRecord() is what lets the handler say so. The flag really is set, which is why the
    // endpoint stays 200 -- the request was honoured; it is the consequence that needed stating.
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();

    auto mininetMonitor =
        std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    HistoricalDataManager mininet(mininetMonitor, utils::MININET);
    EXPECT_FALSE(mininet.canRecord())
        << "MININET cannot record: start() returns before spawning the recorder thread";

    auto testbedMonitor =
        std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::TESTBED);
    HistoricalDataManager testbed(testbedMonitor, utils::TESTBED);
    EXPECT_TRUE(testbed.canRecord())
        << "TESTBED is the mode that does start the recorder, so it must not be reported as "
           "incapable -- a gate that says no to everything is as useless as one that says yes";
}
