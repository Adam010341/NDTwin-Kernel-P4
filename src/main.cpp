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
#include <optional>
#include <shared_mutex>
#include <string>
#include <thread>
#include <cstdio>
#include <cstdlib>
#include <unistd.h> // for isatty

std::string SIM_SERVER_URL = AppConfig::SIM_SERVER_URL;
std::string GW_IP = AppConfig::GW_IP;

static std::atomic<bool> gShutdownRequested{false};

struct DeploymentConfig {
    int mode;
    bool useToken;
};

// [Co-developed with claude code -- Adam]
//
// Startup used to be interactive-only: three std::cin prompts with no non-interactive
// path, so a headless run (CI, a test script, nohup) blocked forever on stdin. The test
// orchestration had to pipe "1\n2\n2\n" in, which silently loads the wrong topology the
// moment the prompt order changes.
//
// CLI flags now take precedence; prompting is the fallback and only when stdin is a TTY.
// A non-TTY run with missing flags fails with a usage message instead of hanging.
namespace cli
{

struct Options
{
    std::optional<int> mode;          // 1 = mininet, 2 = testbed
    std::optional<std::string> topology;
    std::optional<bool> useAi;
    bool showHelp = false;
};

void
printUsage(const char* argv0)
{
    std::cout
        << "Usage: " << argv0 << " [options]\n"
           "\n"
           "Deployment options (prompted interactively if omitted and stdin is a TTY):\n"
           "  --mode <mininet|testbed>   deployment environment\n"
           "  --topology <path>          topology JSON to load. Defaults to the mode's\n"
           "                             configured file; for mininet, pick a P4 topology\n"
           "                             here to run against bmv2\n"
           "  --ai / --no-ai             enable or disable the Intent Translator\n"
           "                             (--ai needs an OpenAI token)\n"
           "  -h, --help                 show this message\n"
           "\n"
           "Logging options are also accepted; see --logfile / --loglevel.\n"
           "\n"
           "Examples:\n"
           "  " << argv0 << " --mode mininet --no-ai\n"
           "  " << argv0 << " --mode mininet --no-ai \\\n"
           "      --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json\n";
}

// Parses only the flags we own; anything else (including Logger's) is ignored here and
// handled by Logger::parse_cli_args.
Options
parse(int argc, char* argv[])
{
    Options opts;
    auto needsValue = [&](int& i, const std::string& flag) -> std::string {
        if (i + 1 >= argc)
        {
            std::cerr << flag << " requires a value\n";
            std::exit(2);
        }
        return argv[++i];
    };

    for (int i = 1; i < argc; ++i)
    {
        const std::string arg = argv[i];
        if (arg == "-h" || arg == "--help")
        {
            opts.showHelp = true;
        }
        else if (arg == "--mode")
        {
            const std::string value = needsValue(i, arg);
            if (value == "mininet" || value == "1")
            {
                opts.mode = 1;
            }
            else if (value == "testbed" || value == "2")
            {
                opts.mode = 2;
            }
            else
            {
                std::cerr << "--mode expects 'mininet' or 'testbed', got '" << value << "'\n";
                std::exit(2);
            }
        }
        else if (arg == "--topology")
        {
            opts.topology = needsValue(i, arg);
        }
        else if (arg == "--ai")
        {
            opts.useAi = true;
        }
        else if (arg == "--no-ai")
        {
            opts.useAi = false;
        }
    }
    return opts;
}

bool
stdinIsInteractive()
{
    return ::isatty(fileno(stdin)) != 0;
}

} // namespace cli

void
handleSigint(int)
{
    gShutdownRequested.store(true);
}

// [Co-developed with claude code -- Adam]
// Resolves the deployment config from CLI flags, prompting only for what was not given and
// only when stdin is a TTY. A non-interactive run with missing flags exits with usage
// rather than blocking on stdin forever.
DeploymentConfig
resolveDeploymentConfig(const cli::Options& opts, const char* argv0)
{
    DeploymentConfig config = {-1, false};
    const bool interactive = cli::stdinIsInteractive();

    auto askChoice = [&](const char* prompt) -> int {
        int choice = 0;
        while (true)
        {
            std::cout << prompt;
            std::cin >> choice;
            if (!std::cin.fail() && (choice == 1 || choice == 2))
            {
                return choice;
            }
            if (std::cin.eof())
            {
                std::cerr << "\nstdin closed while waiting for input\n";
                std::exit(2);
            }
            std::cin.clear();
            std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
            std::cout << "Invalid input. ";
        }
    };

    auto requireFlag = [&](const char* flag) {
        std::cerr << "stdin is not a TTY, so " << flag << " must be given explicitly.\n\n";
        cli::printUsage(argv0);
        std::exit(2);
    };

    // --- mode ---
    if (opts.mode.has_value())
    {
        config.mode = *opts.mode;
    }
    else if (interactive)
    {
        std::cout << "Select your deployment environment:\n";
        std::cout << "  [1] Local Mininet (simulated testbed)\n";
        std::cout << "  [2] Remote Testbed (physical or virtual deployment)\n";
        config.mode = askChoice("Enter environment choice (1-2): ");
    }
    else
    {
        requireFlag("--mode");
    }

    // --- topology ---
    // An explicit --topology wins for either mode. Otherwise, Mininet asks which fabric to
    // use and TESTBED falls through to its configured file.
    if (opts.topology.has_value())
    {
        // overwrite=0 so an operator-supplied NDTWIN_TOPO_FILE is respected; the previous
        // code passed 1 and silently clobbered it even though the loader treats it as a knob.
        setenv("NDTWIN_TOPO_FILE", opts.topology->c_str(), 0);
        if (std::string(std::getenv("NDTWIN_TOPO_FILE")) != *opts.topology)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "NDTWIN_TOPO_FILE was already set to '{}'; ignoring "
                               "--topology '{}'",
                               std::getenv("NDTWIN_TOPO_FILE"),
                               *opts.topology);
        }
    }
    else if (config.mode == 1)
    {
        if (interactive)
        {
            std::cout << "\nSelect your Mininet Topology:\n";
            std::cout << "  [1] OVS Environment (128 Hosts)\n";
            std::cout << "  [2] P4 / BMv2 Environment (4 Hosts)\n";
            const int topoChoice = askChoice("Enter topology choice (1-2): ");
            setenv("NDTWIN_TOPO_FILE",
                   topoChoice == 2 ? AppConfig::TOPOLOGY_FILE_MININET_P4.c_str()
                                   : AppConfig::TOPOLOGY_FILE_MININET.c_str(),
                   0);
        }
        else
        {
            requireFlag("--topology");
        }
    }

    // --- AI ---
    if (opts.useAi.has_value())
    {
        config.useToken = *opts.useAi;
    }
    else if (interactive)
    {
        std::cout << "\nDo you want to enable Intent Translator (requires OpenAI Token)?\n";
        std::cout << "  [1] Yes (Enable AI features)\n";
        std::cout << "  [2] No  (Disable AI features)\n";
        config.useToken = (askChoice("Enter choice (1-2): ") == 1);
    }
    else
    {
        requireFlag("--ai or --no-ai");
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
    // [Co-developed with claude code -- Adam]
    // Logger first: resolveDeploymentConfig logs, and the old ordering left every message
    // emitted during startup configuration with no logger to go to.
    const cli::Options cliOpts = cli::parse(argc, argv);
    if (cliOpts.showHelp)
    {
        cli::printUsage(argv[0]);
        return 0;
    }

    auto cfg = Logger::parse_cli_args(argc, argv);
    Logger::init(cfg);
    SPDLOG_LOGGER_INFO(Logger::instance(), "Logger Loads Successfully! level");

    DeploymentConfig config = resolveDeploymentConfig(cliOpts, argv[0]);
    int mode = config.mode;

    if (mode == 1) {
        std::cout << "Running in Mininet environment.\n";
    } else {
        std::cout << "Running in Remote Testbed environment.\n";
    }
    if (const char* topo = std::getenv("NDTWIN_TOPO_FILE"))
    {
        SPDLOG_LOGGER_INFO(Logger::instance(), "Topology file: {}", topo);
    }

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
                                                        deviceConfigurationAndPowerManager,
                                                        eventBus,
                                                        mode,
                                                        classifier);

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

    // [Co-developed with claude code -- Adam]
    // One instance, deliberately. There used to be two: a unique_ptr built earlier that was the
    // one actually start()ed and stop()ped, and this shared_ptr, which was the one handed to the
    // event handler and therefore to every HttpSession. The REST toggle set the logging flag on
    // an object whose recording thread had never been started, while the object doing the
    // recording could not be reached from any endpoint.
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

    // [Co-developed with claude code -- Adam]
    // The collector owns the sFlow socket, and a twin with no telemetry is not a degraded twin --
    // every flow rate and every link utilisation it reports would be zero, indistinguishable from
    // a genuinely idle network. So a bind failure ends the process here, with a message naming the
    // cause, rather than leaving a kernel running that answers every query confidently and wrongly.
    try
    {
        collector->start(20, 4096);
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_CRITICAL(Logger::instance(),
                               "cannot start telemetry collection: {}. Exiting -- see the error "
                               "above for which resource was unavailable.",
                               e.what());
        topologyAndFlowMonitor->stop();
        return EXIT_FAILURE;
    }

    historicalDataManager->start();
    handler->start();
    deviceConfigurationAndPowerManager->start();

    while (!gShutdownRequested.load())
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "Shutdown requested. Cleaning up…");

    topologyAndFlowMonitor->stop();
    collector->stop();
    historicalDataManager->stop();
    handler->stop();
    deviceConfigurationAndPowerManager->stop();

    SPDLOG_LOGGER_INFO(Logger::instance(), "All subsystems stopped. Exiting.");

    return 0;
}
