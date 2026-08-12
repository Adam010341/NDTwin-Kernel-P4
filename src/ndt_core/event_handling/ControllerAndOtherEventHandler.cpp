#include "ndt_core/event_handling/ControllerAndOtherEventHandler.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "nlohmann/json.hpp" // for json
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include "ndt_core/lock_management/LockManager.hpp"
#include <algorithm> // for max
#include <boost/asio/basic_socket_acceptor.hpp>
#include <boost/asio/basic_stream_socket.hpp>
#include <boost/asio/detail/impl/reactive_socket_service_base.ipp>
#include <boost/asio/detail/impl/scheduler.ipp>
#include <boost/asio/detail/impl/service_registry.hpp>
#include <boost/asio/error.hpp>
#include <boost/asio/execution/context_as.hpp>
#include <boost/asio/execution/prefer_only.hpp>
#include <boost/asio/impl/any_io_executor.ipp>
#include <boost/asio/impl/io_context.hpp>
#include <boost/asio/impl/io_context.ipp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/address.hpp>
#include <boost/asio/ip/detail/impl/endpoint.ipp>
#include <boost/asio/ip/impl/address.hpp>
#include <boost/asio/ip/tcp.hpp> // for tcp
#include <boost/system/detail/error_code.hpp>
#include <exception>
#include <mutex>
#include <new>
#include <thread>
#include <unordered_set>
#include <utility> // for move
#include <vector>

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;
using namespace std;
using json = nlohmann::json;

ControllerAndOtherEventHandler::ControllerAndOtherEventHandler(
    boost::asio::io_context& ioc,
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
    std::shared_ptr<FlowRoutingManager> flowRoutingManager,
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowerManager,
    std::shared_ptr<EventBus> eventBus,
    std::shared_ptr<ApplicationManager> applicationManager,
    std::shared_ptr<SimulationRequestManager> simManager,
    std::shared_ptr<IntentTranslator> intentTranslator,
    std::shared_ptr<HistoricalDataManager> historicalDataManager,
    std::shared_ptr<Controller> ctrl,
    std::shared_ptr<LockManager> lockManager,
    int mode,
    std::string api_url)
    : m_ioContext(ioc),
      m_topologyAndFlowMonitor(std::move(topologyAndFlowMonitor)),
      m_flowLinkUsageCollector(std::move(collector)),
      m_flowRoutingManager(std::move(flowRoutingManager)),
      m_deviceConfigurationAndPowerManager(std::move(deviceConfigurationAndPowerManager)),
      m_eventBus(std::move(eventBus)),
      m_applicationManager(std::move(applicationManager)),
      m_simulationRequestManager(std::move(simManager)),
      m_intentTranslator(std::move(intentTranslator)),
      // [Co-developed with claude code -- Adam]
      // This was missing. The constructor took the parameter and the initialiser list ended at
      // m_lockManager, so the member stayed null, doAccept handed null to every HttpSession, and
      // the guard in handleSetHistoricalLoggingState answered a permanent 500 "Historical data
      // manager not available" -- even though main.cpp had built a real instance and passed it.
      // Ordered here to match the declaration order in the header; initialising out of order is
      // a -Wreorder warning and this build treats warnings as errors.
      m_historicalDataManager(std::move(historicalDataManager)),
      m_controller(std::move(ctrl)),
      m_mode(static_cast<utils::DeploymentMode>(mode)),
      m_apiUrl(std::move(api_url)),
      m_lockManager(std::move(lockManager))
{
}

ControllerAndOtherEventHandler::~ControllerAndOtherEventHandler()
{
    stop();
}

void
ControllerAndOtherEventHandler::start()
{
    this->m_serverRunning.store(true);

    m_serverAcceptor = make_unique<tcp::acceptor>(m_ioContext, tcp::endpoint{tcp::v4(), NDT_PORT});

    this->m_serverThread = thread(&ControllerAndOtherEventHandler::runServer, this);
}

void
ControllerAndOtherEventHandler::stop()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "ControllerAndOtherEventHandler Stop Start");
    // Exchange returns the old value, so we check if it *was* true
    if (!m_serverRunning.exchange(false))
    {
        SPDLOG_LOGGER_INFO(Logger::instance(), "ControllerAndOtherEventHandler already stopped.");
        return; // already stopped or stopping
    }

    // 1. Call io_context::stop()
    m_ioContext.stop();
    SPDLOG_LOGGER_INFO(Logger::instance(), "io_context stopped");

    // 2. Close the acceptor
    if (m_serverAcceptor)
    {
        boost::system::error_code ec;
        m_serverAcceptor->close(ec); // This is the intended way to unblock accept()
        SPDLOG_LOGGER_INFO(Logger::instance(), "acceptor_ close");
        if (ec && ec != net::error::operation_aborted && ec != boost::asio::error::bad_descriptor)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "acceptor_.close() error: {}", ec.message());
        }
    }

    // 3. Close the socket - This is crucial for aborting read/write on an
    // *already accepted* connection. If the thread was stuck in accept(), this
    // socket_ might not be connected yet, but close it defensively.
    {
        lock_guard<mutex> lock(m_socketsMutex);
        for (auto& sock : m_activeSockets)
        {
            boost::system::error_code ec;
            sock->shutdown(tcp::socket::shutdown_both, ec);
            sock->close(ec);
        }
        m_activeSockets.clear();
    }

    try
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "Attempting to poke the server socket to unblock accept.");

        net::io_context pokeIoContext;
        tcp::socket poke_socket(pokeIoContext);
        tcp::endpoint endPoint(net::ip::address::from_string("127.0.0.1"), NDT_PORT);
        boost::system::error_code ecPoke;

        poke_socket.connect(endPoint, ecPoke);

        if (!ecPoke)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "Poke connection successful. Closing poke socket.");

            poke_socket.close();
        }
        else if (ecPoke == boost::asio::error::connection_refused)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "Poke connection refused (port likely already fully closed).");
        }
        else if (ecPoke == boost::asio::error::operation_aborted)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(), "Poke connection aborted.");
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Poke connection failed with unexpected error: {}",
                               ecPoke.message());
        }
    }
    catch (const exception& e)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Exception during poke attempt: {}", e.what());
    }

    // 4. Wait for the server thread to finish

    if (m_serverThread.joinable())
    {
        SPDLOG_LOGGER_INFO(Logger::instance(), "Waiting for server thread to join...");
        m_serverThread.join();
        SPDLOG_LOGGER_INFO(Logger::instance(), "m_serverThread joined.");
    }
    else
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Server thread was not joinable.");
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "ControllerAndOtherEventHandler stopped.");
}

void
ControllerAndOtherEventHandler::runServer()
{
    const short port = NDT_PORT;
    SPDLOG_LOGGER_INFO(Logger::instance(), "Server Listening on port {}", port);

    doAccept(); // start async accept loop

    // Run io_context (this can be in multiple threads)
    std::vector<std::thread> threadPool;
    int threadCount = std::thread::hardware_concurrency();
    for (int i = 0; i < threadCount; ++i)
    {
        threadPool.emplace_back([this]() { m_ioContext.run(); });
    }

    for (auto& t : threadPool)
    {
        t.join();
    }

    // This line is printed only when the while(m_running) loop is exited
    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting Loop of run event server");
}

json
ControllerAndOtherEventHandler::parseFlowStatsText(const std::string& responseText)
{
    try
    {
        return json::parse(responseText);
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "JSON parsing failed: {}", e.what());
        return json::array(); // Return empty array on failure
    }
}

void
ControllerAndOtherEventHandler::doAccept()
{
    auto sock = std::make_shared<tcp::socket>(m_ioContext);

    m_serverAcceptor->async_accept(*sock, [this, sock](boost::system::error_code ec) {
        if (!ec && m_serverRunning.load())
        {
            SPDLOG_LOGGER_INFO(Logger::instance(), "Accepted new connection");

            std::make_shared<HttpSession>(std::move(*sock),
                                          m_topologyAndFlowMonitor,
                                          m_eventBus,
                                          m_mode,
                                          m_flowLinkUsageCollector,
                                          m_flowRoutingManager,
                                          m_deviceConfigurationAndPowerManager,
                                          m_applicationManager,
                                          m_simulationRequestManager,
                                          m_intentTranslator,
                                          m_historicalDataManager,
                                          m_controller,
                                          m_lockManager)
                ->start();
        }

        if (m_serverRunning.load())
        {
            doAccept(); // keep accepting
        }
    });
}
