/*
 * spdlog Log Levels:
 *   trace     - Very detailed logs, typically only of interest when diagnosing problems.
 *   debug     - Debugging information, helpful during development.
 *   info      - Informational messages that highlight the progress of the application.
 *   warn      - Potentially harmful situations which still allow the application to continue
 * running. err       - Error events that might still allow the application to continue running.
 *   critical  - Serious errors that lead the application to abort.
 *   off       - Disables logging.
 */

#pragma once

#include <spdlog/spdlog.h>

#include <memory>
#include <string>

/**
 * @brief Runtime logging configuration options for the global logger.
 *
 * filePath selects the file logs are ALSO written to. Empty means console only.
 * level selects the minimum log severity that will be emitted.
 *
 * [Co-developed with claude code -- Adam]
 * This used to be `bool enableFile` beside a hard-coded "netdt.log" inside Logger::init, and the
 * two could disagree: `--logfile /where/i/want.log` set the bool, the path was dropped on the
 * floor, and the run wrote to a file the operator had not named while the one they had named
 * stayed 0 bytes with nothing on stderr. One field cannot contradict itself -- there is no
 * "logging to a file is on" state that does not carry the file it is on.
 */
struct LogConfig
{
    std::string filePath;
    spdlog::level::level_enum level = spdlog::level::info;
};

/**
 * @brief Centralized spdlog wrapper providing a process-wide logger instance.
 *
 * Logger encapsulates initialization and access to a single shared spdlog logger
 * used across the codebase (via Logger::instance()).
 *
 * Responsibilities:
 *  - Parse log level names (e.g., "info", "debug") into spdlog enums.
 *  - Parse CLI arguments into LogConfig (if your binary supports it).
 *  - Initialize spdlog sinks/formatters and set the global log level.
 *  - Provide access to the initialized logger.
 *
 * Usage:
 *  - Call Logger::init(cfg) once at program startup.
 *  - Use Logger::instance() anywhere to log via SPDLOG_LOGGER_* macros.
 *
 * Threading:
 *  - spdlog is thread-safe; Logger::instance() returns a shared logger.
 *  - init() should be called once during startup before concurrent logging.
 */
class Logger
{
  public:
    /**
     * @brief Convert a textual log level into a spdlog level enum.
     *
     * @param name Log level name (e.g., "trace", "debug", "info", "warn", "err", "critical",
     * "off").
     * @return Corresponding spdlog level. Unknown values typically default to info.
     */
    static spdlog::level::level_enum parse_level(const std::string& name);
    /**
     * @brief Parse command-line arguments into LogConfig.
     *
     * Intended for configuring log sinks/levels from CLI flags.
     *
     * @param argc Argument count.
     * @param argv Argument vector.
     * @return Parsed LogConfig.
     */
    static LogConfig parse_cli_args(int argc, char* argv[]);
    /**
     * @brief The logging options block, exactly as it is printed to a user.
     *
     * [Co-developed with claude code -- Adam]
     * One string, two printers. `ndtwin_kernel --help` is answered by src/main.cpp's own parser,
     * which runs first and exits before Logger::parse_cli_args is ever reached -- so the help text
     * below this class used to be unreachable from the kernel, and main.cpp's usage merely pointed
     * at it ("Logging options are also accepted; see --logfile / --loglevel"). Two texts, one of
     * them invisible, is how a help text and a behaviour drift apart. Both callers print this.
     *
     * @return A newline-terminated, two-space-indented option block. Never null.
     */
    static const char* cli_usage();
    /**
     * @brief Initialize the global logger instance.
     *
     * Creates spdlog sinks (console and optional file), sets formatting and log level,
     * and stores the logger for later retrieval via instance().
     *
     * @param cfg Logging configuration.
     */
    static void init(const LogConfig& cfg);
    /**
     * @brief Access the global logger instance.
     *
     * @return Shared pointer to the initialized spdlog logger.
     * @note Logger::init() should be called before first use.
     */
    static std::shared_ptr<spdlog::logger> instance();

  private:
    static std::shared_ptr<spdlog::logger> m_logger;
};