#include "../setting/AppConfig.hpp"
#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/application_management/ApplicationManager.hpp"
#include "ndt_core/application_management/SimulationRequestManager.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "ndt_core/event_handling/ControllerAndOtherEventHandler.hpp"
#include "ndt_core/intent_translator/IntentTranslator.hpp"
#include "ndt_core/lock_management/LockManager.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include <atomic>
#include <boost/asio/impl/io_context.ipp>
#include <boost/asio/io_context.hpp>
#include <chrono>
#include <csignal>
#include <iostream>
#include <limits>
#include <memory>
#include <shared_mutex>
#include <string>
#include <thread>
#include <cstdlib>

std::string SIM_SERVER_URL = AppConfig::SIM_SERVER_URL;
std::string GW_IP = AppConfig::GW_IP;

static std::atomic<bool> gShutdownRequested{false};

struct DeploymentConfig {
    int mode;       
    bool useToken;  
};

void
handleSigint(int)
{
    gShutdownRequested.store(true);
}

DeploymentConfig promptDeploymentConfig() {
    DeploymentConfig config = {-1, false};
    int aiChoice = -1;

    std::cout << "Select your deployment environment:\n";
    std::cout << "  [1] Local Mininet (simulated testbed)\n";
    std::cout << "  [2] Remote Testbed (physical or virtual deployment)\n";
    
    while (true) {
        std::cout << "Enter environment choice (1-2): ";
        std::cin >> config.mode;
        if (!std::cin.fail() && (config.mode == 1 || config.mode == 2)) break;
        std::cin.clear();
        std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
        std::cout << "Invalid input. ";
    }

    if (config.mode == 1) {
        std::cout << "\nSelect your Mininet Topology:\n";
        std::cout << "  [1] OVS Environment (128 Hosts)\n";
        std::cout << "  [2] P4 / BMv2 Environment (4 Hosts)\n";
        int topoChoice = 0;
        while (true) {
            std::cout << "Enter topology choice (1-2): ";
            std::cin >> topoChoice;
            if (!std::cin.fail() && (topoChoice == 1 || topoChoice == 2)) break;
            std::cin.clear();
            std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
            std::cout << "Invalid input. ";
        }
        if (topoChoice == 2) {
            setenv("NDTWIN_TOPO_FILE", "../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json", 1);
        } else {
            setenv("NDTWIN_TOPO_FILE", "../setting/StaticNetworkTopologyMininet_10Switches.json", 1);
        }
    }

    std::cout << "\nDo you want to enable Intent Translator (requires OpenAI Token)?\n";
    std::cout << "  [1] Yes (Enable AI features)\n";
    std::cout << "  [2] No  (Disable AI features)\n";

    while (true) {
        std::cout << "Enter choice (1-2): ";
        std::cin >> aiChoice;
        if (!std::cin.fail() && (aiChoice == 1 || aiChoice == 2)) {
            config.useToken = (aiChoice == 1);
            break;
        }
        std::cin.clear();
        std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
        std::cout << "Invalid input. ";
    }

    return config;
}



std::string
promptOpenAIModel()
{
    std::string model;
    // std::cout << "Enter the OpenAI model you want to use (e.g., gpt-4.1-mini): ";
    // std::cin >> model;

    // if (model.empty())
    // {
    //     std::cerr << "Model name cannot be empty. Using default: o4-mini." << std::endl;
    //     model = "o4-mini";
    // }

    return model;
}

int
main(int argc, char* argv[])
{
    // Temporarily use command line prompt to configure running mode.
    DeploymentConfig config = promptDeploymentConfig();
    int mode = config.mode; 

    if (mode == 1) {
        std::cout << "Running in Mininet environment.\n";
    } else {
        std::cout << "Running in Remote Testbed environment.\n";
    }

    auto cfg = Logger::parse_cli_args(argc, argv);
    Logger::init(cfg);
    SPDLOG_LOGGER_INFO(Logger::instance(), "Logger Loads Successfully! level");

    std::signal(SIGINT, handleSigint);

    net::io_context ioc{1};

    auto graph = std::make_shared<Graph>();
    auto graphMutex = std::make_shared<std::shared_mutex>();
    auto eventBus = std::make_shared<EventBus>();
    std::shared_ptr<FlowRoutingManager> flowRoutingManager;
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowerManager;
    auto classifier = std::make_shared<ndtClassifier::Classifier>();

    auto topologyAndFlowMonitor =
        std::make_shared<TopologyAndFlowMonitor>(graph, graphMutex, eventBus, mode);

    deviceConfigurationAndPowerManager =
        std::make_shared<DeviceConfigurationAndPowerManager>(topologyAndFlowMonitor, mode, GW_IP, classifier);

    auto collector =
        std::make_shared<sflow::FlowLinkUsageCollector>(topologyAndFlowMonitor,
                                                        flowRoutingManager,
                                                        deviceConfigurationAndPowerManager,
                                                        eventBus,
                                                        mode,
                                                        classifier);

    auto dataManager = std::make_unique<HistoricalDataManager>(topologyAndFlowMonitor, mode);

    flowRoutingManager =
        std::make_shared<FlowRoutingManager>(topologyAndFlowMonitor, collector, eventBus);



    std::shared_ptr<IntentTranslator> intentTranslator = nullptr;
    if (config.useToken) {
        std::string openaiModel = promptOpenAIModel();
        if (openaiModel.empty()) openaiModel = "gpt-5-nano";

        SPDLOG_LOGGER_INFO(Logger::instance(), "Initializing IntentTranslator with model: {}", openaiModel);
        
        intentTranslator = std::make_shared<IntentTranslator>(
            deviceConfigurationAndPowerManager,
            topologyAndFlowMonitor,
            flowRoutingManager,
            collector,
            openaiModel
        );
    } else {
        SPDLOG_LOGGER_INFO(Logger::instance(), "IntentTranslator is disabled by user.");
    }

    auto appManager = std::make_shared<ApplicationManager>("/srv/nfs/sim", "/mnt");

    auto simManager = std::make_shared<SimulationRequestManager>(appManager, SIM_SERVER_URL);

    auto historicalDataManager =
        std::make_shared<HistoricalDataManager>(topologyAndFlowMonitor, mode);

    auto controller = std::make_shared<Controller>(flowRoutingManager);

    auto lockManager = std::make_shared<LockManager>();

    auto handler =
        std::make_shared<ControllerAndOtherEventHandler>(ioc,
                                                         topologyAndFlowMonitor,
                                                         collector,
                                                         flowRoutingManager,
                                                         deviceConfigurationAndPowerManager,
                                                         eventBus,
                                                         appManager,
                                                         simManager,
                                                         intentTranslator,
                                                         historicalDataManager,
                                                         controller,
                                                         lockManager,
                                                         mode);

    topologyAndFlowMonitor->start();
    collector->start(20, 4096);
    dataManager->start();
    handler->start();
    deviceConfigurationAndPowerManager->start();

    while (!gShutdownRequested.load())
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "Shutdown requested. Cleaning up…");

    topologyAndFlowMonitor->stop();
    collector->stop();
    dataManager->stop();
    handler->stop();
    deviceConfigurationAndPowerManager->stop();

    SPDLOG_LOGGER_INFO(Logger::instance(), "All subsystems stopped. Exiting.");

    return 0;
}
