#pragma once

#include "utils/Utils.hpp"                // for DeploymentMode
#include <atomic>                         // for atomic
#include <boost/asio/ip/tcp.hpp>          // for tcp
#include <boost/beast/http/error.hpp>     // for http
#include <memory>                         // for shared_ptr, allocator, enable_...
#include <mutex>                          // for mutex
#include <nlohmann/json.hpp>              // for json
#include <string>                         // for string
#include <thread>                         // for thread
#include <unordered_set>                  // for unordered_set
class DeviceConfigurationAndPowerManager; // lines 61-61
class EventBus;                           // lines 59-59
class FlowRoutingManager;                 // lines 58-58
class TopologyAndFlowMonitor;             // lines 51-51
class ApplicationManager;
class SimulationRequestManager;
class IntentTranslator;
class HistoricalDataManager;
class Controller;
class LockManager;

namespace boost
{
namespace asio
{
class io_context;
}
} // namespace boost

namespace sflow
{
class FlowLinkUsageCollector;
} // namespace sflow

#define NDT_PORT 8000

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;
using json = nlohmann::json;

/**
 * @brief HTTP event/API server that bridges external requests to NDTwin managers.
 *
 * ControllerAndOtherEventHandler owns a small HTTP server (Boost.Asio/Beast) that:
 *  - accepts inbound API/event requests on NDT_PORT,
 *  - dispatches requests to core components (topology monitor, sFlow collector,
 *    routing manager, device power manager, etc.),
 *  - integrates with higher-level services (simulation request manager, intent translator,
 *    historical data manager), and
 *  - publishes/consumes internal events via EventBus.
 *
 * The server runs on a dedicated thread and tracks active sockets so it can stop
 * gracefully. Behavior may differ based on deployment mode (e.g., MININET vs TESTBED).
 *
 * Threading:
 *  - runServer()/start() launch the accept loop in m_serverThread.
 *  - stop() requests shutdown, closes acceptor/sockets, and joins the server thread.
 */
class ControllerAndOtherEventHandler
    : public std::enable_shared_from_this<ControllerAndOtherEventHandler>
{
  public:
    explicit ControllerAndOtherEventHandler(
        boost::asio::io_context& ioc,
        std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
        std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
        std::shared_ptr<FlowRoutingManager> flowRoutingManager,
        std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowermanager,
        std::shared_ptr<EventBus> eventBus,
        std::shared_ptr<ApplicationManager> applicationManager,
        std::shared_ptr<SimulationRequestManager> simManager,
        std::shared_ptr<IntentTranslator> intentTranslator,
        std::shared_ptr<HistoricalDataManager> historicalDataManager,
        std::shared_ptr<Controller> ctrl,
        std::shared_ptr<LockManager> lockManager,
        int mode,
        std::string api_url = "http://localhost:8000/ndt");
    ~ControllerAndOtherEventHandler();

    /**
     * @brief Run the HTTP server accept loop.
     *
     * Creates/binds the TCP acceptor to NDT_PORT and begins accepting connections.
     * Typically invoked by start() and executed on m_serverThread.
     */
    void runServer();

    /**
     * @brief Start the HTTP server in a background thread.
     *
     * Sets m_serverRunning=true, launches m_serverThread, and begins accepting
     * incoming connections.
     */
    void start();
    /**
     * @brief Stop the HTTP server and close active connections.
     *
     * Signals shutdown, closes the acceptor, closes tracked active sockets, and joins
     * the server thread. Safe to call multiple times.
     */
    void stop();

    json parseFlowStatsText(const std::string& responseText);

  private:
    void doAccept();

    std::atomic<bool> m_serverRunning{false};
    net::io_context& m_ioContext;

    std::unique_ptr<tcp::acceptor> m_serverAcceptor;
    std::thread m_serverThread;

    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;
    std::shared_ptr<FlowRoutingManager> m_flowRoutingManager;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_deviceConfigurationAndPowerManager;
    std::shared_ptr<EventBus> m_eventBus;
    std::shared_ptr<ApplicationManager> m_applicationManager;
    std::shared_ptr<SimulationRequestManager> m_simulationRequestManager;
    // [Co-developed with claude code -- Adam]
    // Test seam. tests/test_HistoricalLogging.cpp asserts the constructor actually stores the
    // HistoricalDataManager it is given: it did not, and nothing downstream could tell, because
    // the only symptom was an endpoint answering 500 several layers away.
    friend class ControllerAndOtherEventHandlerTestPeer;

    std::shared_ptr<IntentTranslator> m_intentTranslator;
    std::shared_ptr<HistoricalDataManager> m_historicalDataManager;
    std::shared_ptr<Controller> m_controller;

    utils::DeploymentMode m_mode;
    std::string m_apiUrl;

    std::mutex m_socketsMutex;
    std::unordered_set<std::shared_ptr<tcp::socket>> m_activeSockets;

    std::shared_ptr<LockManager> m_lockManager;
};