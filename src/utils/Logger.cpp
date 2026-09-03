#include "utils/Logger.hpp"
#include <cstdlib>
#include <iostream>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <vector>

std::shared_ptr<spdlog::logger> Logger::m_logger = nullptr;

// [Co-developed with claude code -- Adam]
// FINDINGS #63, second instance of the same shape as --logfile. This used to be a try/catch
// around spdlog::level::from_str, and the catch was UNREACHABLE: from_str is declared
// SPDLOG_NOEXCEPT and answers `level::off` for every name it does not recognise
// (libs/spdlog/common-inl.h, spdlog 1.15.2). So `--loglevel inf` did not fail and did not fall
// back to info -- it turned logging OFF, silently, with status 0. That is worse than the
// --logfile defect it was found beside: the operator asks for more logging and gets none, and
// the run still says nothing is wrong.
//
// `off` is itself a legal level, so the ANSWER cannot distinguish a typo from a request. The
// NAME is what gets checked. Accepted spellings are spdlog's own: trace, debug, info, warning,
// warn, error, err, critical, off.
spdlog::level::level_enum
Logger::parse_level(const std::string& name)
{
    const spdlog::level::level_enum level = spdlog::level::from_str(name);
    if (level == spdlog::level::off && name != "off")
    {
        std::cerr << "Unknown log level: " << name << "\n"
                  << "Valid levels: trace, debug, info, warn, err, critical, off\n";
        std::exit(2);
    }
    return level;
}

// [Co-developed with claude code -- Adam]
// A value that was never given and a value that is in fact the NEXT OPTION are both refused
// here, by name, with a non-zero status -- and neither is allowed to become "the flag was
// accepted and quietly did nothing", which is the defect this replaces. `--logfile --no-ai`
// is a user error and must not be read as "log to a file called --no-ai": src/main.cpp's
// parser walks the same argv and would consume that token as its own flag, so the two parsers
// would disagree about what the command line said.
//
// A single "-" is left alone (it is a value by convention, not an option), so a path really
// called "-foo" is still reachable as "./-foo".
static std::string
require_value(const std::string& flag, int& i, int argc, char* argv[])
{
    if (i + 1 >= argc)
    {
        std::cerr << flag << " requires a value, and none was given.\n\n"
                  << Logger::cli_usage();
        std::exit(2);
    }
    const std::string value(argv[i + 1]);
    if (value.size() > 1 && value[0] == '-')
    {
        std::cerr << flag << " requires a value, but the next argument is '" << value
                  << "', which is another option.\n\n"
                  << Logger::cli_usage();
        std::exit(2);
    }
    ++i;
    return value;
}

const char*
Logger::cli_usage()
{
    // Column 30, to line up with the deployment options in src/main.cpp's usage block.
    return "  --logfile, -f <path>       also write every log line to <path>. The path is\n"
           "                             REQUIRED: a run asked to log to a file it cannot name\n"
           "                             is refused, never silently sent to a default file.\n"
           "  --loglevel, -l <level>     trace, debug, info, warn, err, critical, off\n";
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
            cfg.filePath = require_value(arg, i, argc, argv);
        }
        else if (arg == "--loglevel" || arg == "-l")
        {
            cfg.level = parse_level(require_value(arg, i, argc, argv));
        }
        else if (arg == "--help" || arg == "-h")
        {
            std::cout << "Usage: " << argv[0]
                      << " [--logfile|-f <path>] [--loglevel|-l <level>]\n"
                      << cli_usage();
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
    // [Co-developed with claude code -- Adam]
    // The file is the one the caller named. There is no default filename any more: the old
    // hard-coded "netdt.log" in the process's cwd is what let `--logfile /path/i/chose.log`
    // look like it had worked.
    if (!cfg.filePath.empty())
    {
        try
        {
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(
                cfg.filePath, /*truncate=*/false);
            file_sink->set_level(cfg.level);
            sinks.push_back(file_sink);
        }
        catch (const spdlog::spdlog_ex& e)
        {
            // A run that was asked for a log file and cannot open one must not carry on with a
            // console logger: every later "I have the log" would be about a file that does not
            // exist. Same reasoning as main.cpp's telemetry-bind failure.
            std::cerr << "cannot open the log file '" << cfg.filePath << "': " << e.what() << "\n";
            std::exit(2);
        }
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
