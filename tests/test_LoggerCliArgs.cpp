/**
 * @file test_LoggerCliArgs.cpp
 * @brief FINDINGS #63 -- `--logfile` was documented as taking a path and was in fact a boolean.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 *
 *     if (arg == "--logfile" || arg == "-f") { cfg.enableFile = true; }
 *
 * The next argv was never consumed. `ndtwin_kernel --logfile /where/i/want.log` therefore did
 * three things at once, all of them quiet: it turned file logging on, it dropped the path as a
 * stray positional, and it wrote to a hard-coded `netdt.log` in the process's cwd. The file the
 * operator named stayed 0 bytes and stderr said nothing. Measured live on 2026-09-03
 * (doc/audit/2026-09-03_night-rounds/round5-topology-repro/26_logfile_option_check.log):
 * build/netdt.log = 74 942 bytes, the named file = 0.
 *
 * WHY IT IS WORTH A SUITE OF ITS OWN
 *
 * Every round that says "I have the log" rests on this flag. A request that is accepted and has
 * no effect is the worst shape a defect can take, because the operator's evidence that it worked
 * is the absence of an error message -- and the absence of an error message is exactly what the
 * bug produces.
 *
 * WHAT IS ASSERTED, AND THE TWO HALVES
 *
 * The positive half: the path is consumed, it reaches LogConfig, and Logger::init opens THAT
 * file -- not a default one. Asserted end to end, by reading the bytes back out of the file the
 * config named, because "the string arrived in a struct" is not the claim anybody makes about
 * this flag.
 *
 * The negative half, which is why several cases here look like they assert nothing: a run that
 * did NOT ask for a file must be unchanged, and the neighbouring options must not be eaten. A
 * fix that consumed one argv too many, or that opened a file whenever the struct existed, would
 * pass every positive case above.
 *
 * WHY SOME OF THESE ARE DEATH TESTS
 *
 * "Refuse" here means `std::exit(2)` with a message, because the alternative -- returning a
 * config that says "no file" after the user asked for one -- reintroduces the defect in a new
 * costume. A process that exits cannot be observed from inside itself, so those cases fork
 * (threadsafe style: re-exec) and read the child's status and stderr, in the same shape as
 * tests/test_PowerManagerShutdown.cpp.
 *
 * Gate: tests/shell/mutate_logfile_takes_a_path.sh -- each mutation names the one test that must
 * be the one to go red, and two mutations are widenings that must leave every test GREEN.
 */

#include "utils/Logger.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace
{

namespace fs = std::filesystem;

/// argv the way a C main() receives it: mutable, NULL-terminated, argc counted separately.
/// The strings are built first and the pointers taken afterwards, so no reallocation can
/// invalidate them.
class Argv
{
  public:
    Argv(std::initializer_list<const char*> args)
    {
        for (const char* a : args)
        {
            m_storage.emplace_back(a);
        }
        for (auto& s : m_storage)
        {
            m_argv.push_back(s.data());
        }
        m_argv.push_back(nullptr);
    }

    int argc() const
    {
        return static_cast<int>(m_storage.size());
    }
    char** argv()
    {
        return m_argv.data();
    }

  private:
    std::vector<std::string> m_storage;
    std::vector<char*> m_argv;
};

/// Parses a whitespace-separated command line, then exits 0 if the parser ACCEPTED it.
///
/// Takes one argument on purpose. EXPECT_EXIT is a macro, and a braced initialiser list written
/// inside a macro argument hands its commas straight to the preprocessor -- `EXPECT_EXIT` passed
/// 6 arguments, but takes just 3. Commas inside parentheses are safe; commas inside braces are
/// not.
[[noreturn]] void
parseThenExitZeroIfAccepted(const std::string& commandLine)
{
    std::vector<std::string> words;
    std::istringstream in(commandLine);
    for (std::string w; in >> w;)
    {
        words.push_back(w);
    }
    std::vector<char*> argv;
    for (auto& w : words)
    {
        argv.push_back(w.data());
    }
    argv.push_back(nullptr);
    Logger::parse_cli_args(static_cast<int>(words.size()), argv.data());
    // Reached only when the parser accepted the line. That IS the failure these cases look for:
    // the defect was a request being accepted and doing nothing.
    std::exit(0);
}

/// The same shape one layer down: initialise with this path, then exit 0 if init came back.
[[noreturn]] void
initThenExitZeroIfAccepted(const std::string& path)
{
    LogConfig cfg;
    cfg.level = spdlog::level::info;
    cfg.filePath = path;
    Logger::init(cfg);
    std::exit(0);
}

std::string
readAll(const fs::path& p)
{
    std::ifstream in(p);
    std::ostringstream buf;
    buf << in.rdbuf();
    return buf.str();
}

/// A directory nobody else writes to, removed however the test leaves.
class TempDir
{
  public:
    TempDir()
    {
        m_path = fs::temp_directory_path() /
                 ("ndtwin_logfile_test_" + std::to_string(::getpid()) + "_" +
                  std::to_string(++s_counter));
        fs::create_directories(m_path);
    }
    ~TempDir()
    {
        std::error_code ec;
        fs::remove_all(m_path, ec);
    }
    TempDir(const TempDir&) = delete;
    TempDir& operator=(const TempDir&) = delete;

    const fs::path& path() const
    {
        return m_path;
    }

  private:
    fs::path m_path;
    static int s_counter;
};
int TempDir::s_counter = 0;

// =================================================================================================
// The parser: what each flag consumes
// =================================================================================================

TEST(LoggerCliArgsTest, LogfileConsumesThePathThatFollowsIt)
{
    Argv a{"ndtwin_kernel", "--logfile", "/tmp/chosen-by-the-operator.log"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    // The whole finding in one line: before the fix this was "" and the log went to netdt.log.
    EXPECT_EQ(cfg.filePath, "/tmp/chosen-by-the-operator.log");
}

TEST(LoggerCliArgsTest, TheShortFormConsumesAPathToo)
{
    Argv a{"ndtwin_kernel", "-f", "/tmp/short-form.log"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_EQ(cfg.filePath, "/tmp/short-form.log");
}

/// Consuming the path must advance the index by exactly one. A parser that forgot to advance
/// would then read the path itself as the next flag (harmless, it matches nothing) -- but one
/// that advanced twice would eat --loglevel, and the run would come back at the default level
/// with no complaint. Both directions are visible here and in nothing above.
TEST(LoggerCliArgsTest, TheOptionAfterTheLogfilePathIsStillParsed)
{
    Argv a{"ndtwin_kernel", "--logfile", "/tmp/a.log", "--loglevel", "debug"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_EQ(cfg.filePath, "/tmp/a.log");
    EXPECT_EQ(cfg.level, spdlog::level::debug);
}

TEST(LoggerCliArgsTest, LoglevelStillTakesItsValue)
{
    Argv a{"ndtwin_kernel", "--loglevel", "warn"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_EQ(cfg.level, spdlog::level::warn);
    EXPECT_TRUE(cfg.filePath.empty());
}

/// NEGATIVE. A command line with no --logfile must be exactly what it was before this change.
TEST(LoggerCliArgsTest, WithoutTheFlagNoFileIsRequestedAtAll)
{
    Argv a{"ndtwin_kernel", "--mode", "mininet", "--no-ai", "--loglevel", "info"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_TRUE(cfg.filePath.empty()) << "requested: " << cfg.filePath;
    EXPECT_EQ(cfg.level, spdlog::level::info);
}

/// NEGATIVE. Nothing that merely looks like a path may turn file logging on. `--topology <path>`
/// puts a real path on this argv, and Logger walks the same argv main.cpp's parser does.
TEST(LoggerCliArgsTest, ATopologyPathIsNotMistakenForALogPath)
{
    Argv a{"ndtwin_kernel", "--mode", "mininet", "--topology", "/etc/topo.json", "--no-ai"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_TRUE(cfg.filePath.empty()) << "requested: " << cfg.filePath;
}

// =================================================================================================
// The level name. Found by searching the same family rather than by tripping over it: the old
// parse_level wrapped spdlog::level::from_str in a try/catch, and from_str is SPDLOG_NOEXCEPT and
// answers `off` for anything it does not recognise -- so the catch never ran and a mistyped level
// silently DISABLED logging. `off` is a legal request, so these two cases have to be told apart.
// =================================================================================================

TEST(LoggerCliArgsTest, EveryLevelNameTheHelpAdvertisesIsAccepted)
{
    const struct
    {
        const char* name;
        spdlog::level::level_enum expected;
    } cases[] = {
        {"trace", spdlog::level::trace},
        {"debug", spdlog::level::debug},
        {"info", spdlog::level::info},
        {"warn", spdlog::level::warn},
        {"err", spdlog::level::err},
        {"critical", spdlog::level::critical},
        {"off", spdlog::level::off},
    };
    for (const auto& c : cases)
    {
        Argv a{"ndtwin_kernel", "--loglevel", c.name};
        const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
        EXPECT_EQ(cfg.level, c.expected) << "level name: " << c.name;
    }
}

/// `off` must survive the typo check: it is the one name whose correct answer is also the answer
/// spdlog gives to every wrong one. A guard written as "reject anything that came back off" would
/// pass every other case in this file and refuse a legitimate request.
TEST(LoggerCliArgsTest, AskingForOffIsARequestAndNotATypo)
{
    Argv a{"ndtwin_kernel", "--loglevel", "off"};
    const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
    EXPECT_EQ(cfg.level, spdlog::level::off);
}

TEST(LoggerCliArgsDeathTest, AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    // "inf" is the realistic typo for "info", and before the fix it produced a process that
    // logged nothing at all and exited 0.
    EXPECT_EXIT(parseThenExitZeroIfAccepted("ndtwin_kernel --loglevel inf"),
                ::testing::ExitedWithCode(2),
                "Unknown log level: inf");
}

// =================================================================================================
// The parser: what it refuses. "Mistyped" and "not typed" must not be the same event.
// =================================================================================================

TEST(LoggerCliArgsDeathTest, LogfileWithNoPathIsRefusedRatherThanDefaulted)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(parseThenExitZeroIfAccepted("ndtwin_kernel --logfile"),
                ::testing::ExitedWithCode(2),
                "requires a value, and none was given");
}

/// `--logfile --no-ai` is a typo, and it must not become "log to a file called --no-ai".
/// src/main.cpp's parser walks this same argv and would claim --no-ai for itself; the two
/// parsers disagreeing about what the command line said is worse than refusing it.
TEST(LoggerCliArgsDeathTest, LogfileFollowedByAnotherOptionIsRefused)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(parseThenExitZeroIfAccepted("ndtwin_kernel --logfile --no-ai"),
                ::testing::ExitedWithCode(2),
                "which is another option");
}

/// Same family, found by looking for it rather than by tripping over it: `--loglevel` used to
/// carry its own `i + 1 < argc` inside the branch condition, so a trailing `--loglevel` matched
/// nothing, fell out of the chain, and the run continued at the default level in silence.
TEST(LoggerCliArgsDeathTest, LoglevelWithNoValueIsRefusedRatherThanIgnored)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(parseThenExitZeroIfAccepted("ndtwin_kernel --loglevel"),
                ::testing::ExitedWithCode(2),
                "requires a value, and none was given");
}

TEST(LoggerCliArgsDeathTest, LoglevelFollowedByAnotherOptionIsRefused)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(parseThenExitZeroIfAccepted("ndtwin_kernel --loglevel --logfile /tmp/x.log"),
                ::testing::ExitedWithCode(2),
                "which is another option");
}

// =================================================================================================
// The sink: the bytes have to land in the file the config named
// =================================================================================================

/// Runs inside a directory of its own. The defect was a file appearing at a HARD-CODED name in
/// the process's cwd, so a test that cannot see its own cwd cannot see the defect -- and a repo
/// root that already happens to hold a netdt.log would make the check pass by accident.
class LoggerFileSinkTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_originalCwd = fs::current_path();
        fs::current_path(m_dir.path());
    }

    void TearDown() override
    {
        fs::current_path(m_originalCwd);
        // Put the process-wide logger back the way tests/test_LoggerEnvironment.cpp left it, so a
        // suite that runs after this one is not logging at info into a file that is about to be
        // deleted.
        LogConfig quiet;
        quiet.level = spdlog::level::off;
        Logger::init(quiet);
    }

    TempDir m_dir;
    fs::path m_originalCwd;
};

TEST_F(LoggerFileSinkTest, InitWritesToThePathTheConfigNamesAndToNoOther)
{
    const fs::path named = m_dir.path() / "operator-chose-this.log";
    const fs::path hardcoded = m_dir.path() / "netdt.log";

    LogConfig cfg;
    cfg.level = spdlog::level::info;
    cfg.filePath = named.string();
    Logger::init(cfg);
    SPDLOG_LOGGER_INFO(Logger::instance(), "MARKER-ndtwin-logfile-takes-a-path");
    Logger::instance()->flush();

    ASSERT_TRUE(fs::exists(named)) << named.string() << " was never created";
    EXPECT_NE(readAll(named).find("MARKER-ndtwin-logfile-takes-a-path"), std::string::npos)
        << "the file the operator named exists but the log line is not in it";

    // The other half of the original finding: the log used to go to a hard-coded netdt.log in the
    // process's cwd while the named file stayed 0 bytes. Nothing may create that file now.
    EXPECT_FALSE(fs::exists(hardcoded))
        << "a log file appeared at the old hard-coded name " << hardcoded.string();
}

/// NEGATIVE. An empty path means console only, and must open nothing at all. A fix that opened a
/// file "just in case" would satisfy every positive case above and quietly resurrect the default.
TEST_F(LoggerFileSinkTest, AnEmptyPathOpensNoFile)
{
    LogConfig cfg;
    cfg.level = spdlog::level::info;
    Logger::init(cfg);
    SPDLOG_LOGGER_INFO(Logger::instance(), "MARKER-no-file-was-requested");
    Logger::instance()->flush();

    EXPECT_TRUE(fs::is_empty(m_dir.path()))
        << "a file was created in the cwd without one being asked for";
}

/// A log file that cannot be opened ends the run, with the path and the reason named. Carrying on
/// with a console logger would put the process back in the state this whole fix is about: an
/// operator who asked for a file, got no error, and has no file.
TEST(LoggerFileSinkDeathTest, ALogFileThatCannotBeOpenedEndsTheRun)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(
        initThenExitZeroIfAccepted("/nonexistent-directory-ndtwin-test/deeper/still/x.log"),
        ::testing::ExitedWithCode(2),
        "cannot open the log file");
}

// =================================================================================================
// The help text. The half of this defect that is not code: a usage string that describes a
// behaviour the program does not have is a defect in the same way a wrong return value is.
// =================================================================================================

TEST(LoggerUsageTextTest, TheUsageShowsLogfileTakingAPath)
{
    const std::string usage = Logger::cli_usage();
    EXPECT_NE(usage.find("--logfile, -f <path>"), std::string::npos) << usage;
}

TEST(LoggerUsageTextTest, TheUsageNoLongerPromisesAHardCodedFilename)
{
    const std::string usage = Logger::cli_usage();
    EXPECT_EQ(usage.find("netdt.log"), std::string::npos)
        << "the help still names a default file the program no longer writes:\n"
        << usage;
}

TEST(LoggerUsageTextTest, TheUsageShowsLoglevelTakingAValue)
{
    const std::string usage = Logger::cli_usage();
    EXPECT_NE(usage.find("--loglevel, -l <level>"), std::string::npos) << usage;
}

} // namespace
