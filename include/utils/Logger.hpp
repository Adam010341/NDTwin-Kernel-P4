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
#include <vector>

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
 * @brief One command-line option, and how many argv tokens it consumes.
 *
 * [Co-developed with claude code -- Adam]
 * FINDINGS #70. `ndtwin_kernel --logfle /tmp/x.log` used to be ACCEPTED: it did nothing, printed
 * nothing, and exited 0. Neither of the two parsers could catch it on its own, and that is the
 * whole shape of the defect rather than an implementation accident:
 *
 *   - `cli::parse` (src/main.cpp) walks the whole argv and ignores `--logfile`, because that one
 *     belongs to Logger;
 *   - `Logger::parse_cli_args` walks the SAME argv and ignores `--mode`, because that one belongs
 *     to main.
 *
 * So "I do not recognise this option" is not a statement either parser is entitled to make. It is
 * only true of the UNION of the two tables, and it therefore has to be decided in one pass that
 * can see both -- Logger::reject_unknown_flags. Making each parser refuse what it did not
 * recognise would have made `--mode mininet` an error in one of them and `--logfile x` an error
 * in the other.
 *
 * `arity` is the number of argv tokens the flag consumes AFTER its own: 0 for a switch such as
 * `--no-ai`, 1 for a flag that takes a value such as `--topology <path>`. It exists so the check
 * can step over a VALUE rather than scanning it: `--topology -weird-but-a-real-path` must not be
 * read as the option `-weird-but-a-real-path`.
 */
struct CliFlag
{
    const char* name;
    int arity;
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
     * @brief The options Logger::parse_cli_args recognises, with the argv each one consumes.
     *
     * [Co-developed with claude code -- Adam]
     * This table and the branch chain inside parse_cli_args are two statements of the same fact,
     * and a table that drifted from the parser would be worse than no table at all: a flag the
     * parser honours but the table forgets becomes "unknown option" and the program refuses a
     * command line it understands. tests/test_LoggerCliArgs.cpp walks this table and drives every
     * entry through parse_cli_args for exactly that reason.
     *
     * `--help`/`-h` are in here because parse_cli_args branches on them. In the kernel that branch
     * is unreachable -- src/main.cpp's parser answers --help first and returns 0 -- but a binary
     * whose only options are logging options (see doc/audit/2026-09-01_esa-power-off-injection/
     * driver.cpp) reaches it, and the union check must not refuse a flag this parser accepts.
     *
     * @return A table that outlives the call. Never empty.
     */
    static const std::vector<CliFlag>& logging_flags();
    /**
     * @brief Refuse the first option-shaped argv token that no parser in this program owns.
     *
     * [Co-developed with claude code -- Adam]
     * FINDINGS #70, the half that is not about --help: BOTH parsers silently ignored anything they
     * did not recognise, so a typo was indistinguishable from a flag that had been honoured. The
     * operator's evidence that `--logfle /tmp/x.log` worked was the absence of an error message,
     * and the absence of an error message is what the defect produced.
     *
     * Call this ONCE, before either parser runs, with the flags the caller owns; the logging flags
     * are added for you. On the first unrecognised option this prints the token and the accepted
     * option names to stderr and `std::exit(2)`. It exits rather than returning a status because
     * every alternative -- carrying on, or returning a config that says "nothing was asked for" --
     * is the defect again in a different costume.
     *
     * WHAT IT DOES NOT OWN. A token that does not begin with '-' is a positional and is left to
     * the caller; a bare "-" is a value by convention. `--topology=/x.json` IS refused, because
     * neither parser honours the equals form and accepting it silently would be the same lie.
     *
     * @param argc argv count, as main() received it.
     * @param argv argv, as main() received it. argv[0] is never examined.
     * @param also_known The caller's own flags. May be empty.
     */
    static void reject_unknown_flags(int argc, char* argv[],
                                     const std::vector<CliFlag>& also_known);
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