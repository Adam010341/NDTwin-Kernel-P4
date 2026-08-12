#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "common_types/GraphTypes.hpp"                    // for VertexProp...
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp" // for TopologyAn...
#include "spdlog/spdlog.h"                                // for SPDLOG_LOG...
#include "utils/Logger.hpp"                               // for Logger
#include "utils/Utils.hpp"                                // for macToString
#include <boost/graph/adjacency_list.hpp>                 // for source
#include <boost/graph/detail/adj_list_edge_iterator.hpp>  // for adj_list_e...
#include <boost/graph/detail/adjacency_list.hpp>          // for edges
#include <boost/graph/detail/edge.hpp>                    // for edge_desc_...
#include <boost/iterator/iterator_facade.hpp>             // for operator!=
#include <boost/move/utility_core.hpp>                    // for move
#include <ctime>                                          // for strftime
#include <filesystem>                                     // for create_dir...
#include <fstream>                                        // for char_traits
#include <string>                                         // for operator+
#include <utility>                                        // for move

    HistoricalDataManager::HistoricalDataManager(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                                             int mode,
                                             std::chrono::minutes interval)
    : m_topologyAndFlowMonitor(std::move(monitor)),
      m_mode(static_cast<utils::DeploymentMode>(mode)),
      m_interval(interval)
{
    // [Co-developed with claude code -- Adam]
    // error_code overload, not the throwing one. main.cpp constructs this unconditionally in both
    // deployment modes, so the throwing overload meant a directory that could not be created --
    // a permissions problem in a data-logging nicety -- killed the whole kernel at startup before
    // anything else had a chance to run.
    std::error_code ec;
    std::filesystem::create_directories(OUTPUT_DIR, ec);
    if (ec)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "HistoricalDataManager: cannot create {}: {}. Historical link data "
                           "will not be recorded.",
                           OUTPUT_DIR,
                           ec.message());
    }
}

HistoricalDataManager::~HistoricalDataManager()
{
    stop();
}

void
HistoricalDataManager::start()
{
    if (m_running.exchange(true) or m_mode == utils::DeploymentMode::MININET)
    {
        // Already running
        return;
    }
    m_thread = std::thread(&HistoricalDataManager::run, this);
    SPDLOG_LOGGER_INFO(Logger::instance(), "HistoricalDataManager started.");
}

void
HistoricalDataManager::stop()
{
    m_running.store(false);
    if (m_thread.joinable())
    {
        m_thread.join();
        SPDLOG_LOGGER_INFO(Logger::instance(), "HistoricalDataManager stopped.");
    }
}

std::size_t
HistoricalDataManager::writeSnapshot(const Graph& graph,
                                     const std::string& outDir,
                                     std::time_t when)
{
    // [Co-developed with claude code -- Adam]
    // The gate the REST endpoint sets. It was previously stored and never read, so
    // /ndt/set_historical_logging_state changed nothing even where it was reachable.
    if (!m_loggingEnabled.load())
    {
        return 0;
    }

    std::tm local_tm = *std::localtime(&when);

    char dateBuf[9]; // YYYYMMDD
    std::strftime(dateBuf, sizeof(dateBuf), "%Y%m%d", &local_tm);

    char dateTimeBuf[20]; // YYYY-MM-DD HH:MM:SS
    std::strftime(dateTimeBuf, sizeof(dateTimeBuf), "%Y-%m-%d %H:%M:%S", &local_tm);

    const std::string dir = outDir.empty() || outDir.back() == '/' ? outDir : outDir + "/";

    std::size_t rowsWritten = 0;
    std::size_t failures = 0;
    std::string firstFailurePath;

    auto [ei, ei_end] = boost::edges(graph);
    for (; ei != ei_end; ++ei)
    {
        auto u = boost::source(*ei, graph);
        auto v = boost::target(*ei, graph);
        const auto& eprop = graph[*ei];
        const auto& up = graph[u];
        const auto& vp = graph[v];

        const char* srcType = (up.vertexType == VertexType::SWITCH ? "switch" : "host");
        const char* dstType = (vp.vertexType == VertexType::SWITCH ? "switch" : "host");

        auto srcId = (up.vertexType == VertexType::SWITCH ? std::to_string(up.dpid)
                                                          : utils::macToString(up.mac));
        auto dstId = (vp.vertexType == VertexType::SWITCH ? std::to_string(vp.dpid)
                                                          : utils::macToString(vp.mac));

        // base filename: YYYYMMDD_srcDpid_dstDpid.csv
        std::string fullPath = dir + std::string(dateBuf) + "_" + srcId + "_" + dstId + ".csv";

        std::error_code existsEc;
        const bool exists = std::filesystem::exists(fullPath, existsEc);

        std::ofstream ofs(fullPath, std::ios::app);
        if (!exists)
        {
            ofs << "date-time,srcType,srcId,dstType,dstId,link_bw,link_bw_usage\n";
        }
        ofs << dateTimeBuf << "," << srcType << "," << srcId << "," << dstType << "," << dstId
            << "," << eprop.linkBandwidth << "," << eprop.linkBandwidthUsage << "\n";
        ofs.flush();

        // One check, deliberately, and placed *after* the write. It covers both "never opened"
        // and "opened but the write failed": streaming into an ofstream that failed to open sets
        // failbit, so good() is already false in that case, and a full or read-only filesystem
        // only shows up here rather than at open() anyway. An additional is_open() branch was
        // written first and removed -- no input could reach it that this does not already
        // reject, so deleting it left every test green, which is the definition of dead code.
        if (!ofs.good())
        {
            if (failures++ == 0)
            {
                firstFailurePath = fullPath;
            }
            continue;
        }
        ++rowsWritten;
    }

    // Reported once per unbroken run of failures, not once per edge per interval: a root-owned
    // output directory fails for every edge every time, and an every-row ERROR would bury the log
    // rather than inform it.
    if (failures > 0)
    {
        if (!m_writeFailureActive.exchange(true))
        {
            m_writeFailureReports.fetch_add(1);
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "HistoricalDataManager: {} of {} link rows could not be written "
                                "(first: {}). Historical data is being lost. This is reported "
                                "once until a write succeeds.",
                                failures,
                                failures + rowsWritten,
                                firstFailurePath);
        }
    }
    else if (rowsWritten > 0)
    {
        m_writeFailureActive.store(false);
    }

    return rowsWritten;
}

void
HistoricalDataManager::run()
{
    while (m_running.load())
    {
        // 1. Fetch a snapshot clone of the graph
        Graph graph = m_topologyAndFlowMonitor->getGraph();

        // 2. Append one row per edge
        writeSnapshot(graph, OUTPUT_DIR, std::chrono::system_clock::to_time_t(
                                             std::chrono::system_clock::now()));

        // TODO[OPTIMIZW]: Change below methods to condition_variable (more efficient)
        // 3) Sleep until next interval (or until stop() is called)
        for (int i = 0; i < m_interval.count() * 60 && m_running.load(); ++i)
        {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }

}

void 
HistoricalDataManager::setLoggingState(bool enable)
{
    m_loggingEnabled.store(enable);
    SPDLOG_LOGGER_INFO(Logger::instance(), "Historical data logging has been {}.", (enable ? "ENABLED" : "DISABLED"));
}
