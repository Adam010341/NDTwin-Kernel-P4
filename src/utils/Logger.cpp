#include "utils/Logger.hpp"
#include <iostream>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <vector>

std::shared_ptr<spdlog::logger> Logger::m_logger = nullptr;

spdlog::level::level_enum
Logger::parse_level(const std::string& name)
{
    try
    {
        return spdlog::level::from_str(name);
    }
    catch (const spdlog::spdlog_ex&)
    {
        std::cerr << "Unknown log level: " << name << "\n"
                  << "Valid levels: trace, debug, info, warn, err, critical, off\n";
        std::exit(1);
    }
}

LogConfig
Logger::parse_cli_args(int argc, char* argv[])
{
    LogConfig cfg;
    for (int i = 1; i < argc; ++i)
    {
        std::string arg(argv[i]);
        if (arg == "--logfile" || arg == "-f")
        {
            cfg.enableFile = true;
        }
        else if ((arg == "--loglevel" || arg == "-l") && i + 1 < argc)
        {
            cfg.level = parse_level(argv[++i]);
        }
        else if (arg == "--help" || arg == "-h")
        {
            std::cout << "Usage: " << argv[0]
                      << " [--logfile|-f] [--loglevel|-l <level>]\n"
                         "  --logfile, -f       also write logs to netdt.log\n"
                         "  --loglevel, -l lvl  set log level: trace, debug, info, "
                         "warn, err, critical, off\n";
            std::exit(0);
        }
    }
    return cfg;
}

void
Logger::init(const LogConfig& cfg)
{
    auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
    console_sink->set_level(cfg.level);

    std::vector<spdlog::sink_ptr> sinks{console_sink};
    if (cfg.enableFile)
    {
        auto file_sink =
            std::make_shared<spdlog::sinks::basic_file_sink_mt>("netdt.log", /*truncate=*/false);
        file_sink->set_level(cfg.level);
        sinks.push_back(file_sink);
    }

    // [Co-developed with claude code -- Adam]
    // Make init idempotent: register_logger throws if "netdt" already exists, which
    // aborts the second test suite in a shared test binary (and any re-configuration).
    spdlog::drop("netdt");

    m_logger = std::make_shared<spdlog::logger>("netdt", sinks.begin(), sinks.end());
    spdlog::register_logger(m_logger);
    spdlog::set_default_logger(m_logger);
    spdlog::set_level(cfg.level);
    spdlog::flush_on(spdlog::level::info);

    m_logger->set_pattern("[%Y-%m-%d %H:%M:%S.%e] " // timestamp
                          "[%^%l%$] "               // level (colored by spdlog)
                          // now our colored caller block:
                          "[\033[94m%s\033[0m:" // file
                          "\033[95m%#\033[0m "  // line
                          "\033[96m%!\033[0m] " // function
                          "%v"                  // message
    );
}

std::shared_ptr<spdlog::logger>
Logger::instance()
{
    return m_logger;
}
