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
 *
 * -------------------------------------------------------------------------------------------
 * FINDINGS #70 (added on fix/logger-cli-refuses-unknown) -- THE SAME SHAPE, ONE FLAG WIDER.
 *
 * `--logfle /tmp/x.log` was accepted, did nothing and printed nothing, exit 0. Both parsers
 * ignored what they did not recognise, and neither was in a position to do otherwise: each walks
 * the whole argv and must tolerate the other's flags. So the refusal cannot live inside either
 * parser -- it is one pass over the UNION of the two tables, Logger::reject_unknown_flags, and the
 * cases below are as much about what it must still ACCEPT as about what it must refuse. A check
 * that refused everything would satisfy every "is it refused?" case in this file.
 *
 * The gate for the new cases is tests/shell/mutate_logger_cli.sh, which also drives the real
 * ndtwin_kernel binary: src/main.cpp is not linked into this test binary, so main's half of the
 * union cannot be observed from here at all.
 */

#include "utils/Logger.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <iostream>
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

/// The kernel's deployment table, spelled out again because src/main.cpp has a main() of its own
/// and is not linked into this binary. This copy is a STAND-IN, not evidence: it cannot go stale
/// against the real table in a way any case here would notice. tests/shell/mutate_logger_cli.sh
/// deletes an entry from the REAL table and catches it on the REAL binary; that is where main's
/// half is actually pinned, and saying so here is the only thing that stops this stand-in from
/// being read as coverage it does not provide.
const std::vector<CliFlag>&
deploymentFlagsAsMainDeclaresThem()
{
    static const std::vector<CliFlag> flags = {
        {"--mode", 1}, {"--topology", 1}, {"--ai", 0}, {"--no-ai", 0}, {"--help", 0}, {"-h", 0},
    };
    return flags;
}

std::vector<std::string>
splitWords(const std::string& line)
{
    std::vector<std::string> words;
    std::istringstream in(line);
    for (std::string w; in >> w;)
    {
        words.push_back(w);
    }
    return words;
}

/// Runs the union check over a command line with the deployment flags declared, then exits 0 if
/// the check ACCEPTED it. Takes one string for the same preprocessor reason
/// parseThenExitZeroIfAccepted does: a braced list inside a macro argument is split on its commas.
[[noreturn]] void
checkThenExitZeroIfAccepted(const std::string& commandLine)
{
    std::vector<std::string> words = splitWords(commandLine);
    std::vector<char*> argv;
    for (auto& w : words)
    {
        argv.push_back(w.data());
    }
    argv.push_back(nullptr);
    Logger::reject_unknown_flags(static_cast<int>(words.size()), argv.data(),
                                 deploymentFlagsAsMainDeclaresThem());
    std::exit(0);
}

/// The same check with NO caller flags at all, so only what Logger owns is known. This is how the
/// union is shown to be a union: the answer to `--mode mininet` depends on who is asking.
[[noreturn]] void
checkLoggingOnlyThenExitZeroIfAccepted(const std::string& commandLine)
{
    std::vector<std::string> words = splitWords(commandLine);
    std::vector<char*> argv;
    for (auto& w : words)
    {
        argv.push_back(w.data());
    }
    argv.push_back(nullptr);
    Logger::reject_unknown_flags(static_cast<int>(words.size()), argv.data(), {});
    std::exit(0);
}

/// Drives Logger::parse_cli_args far enough to reach its --help branch, with stdout redirected
/// into stderr because a death test's matcher reads the CHILD'S STDERR and that branch prints to
/// stdout. Exits 3 -- a code the branch itself never produces -- when the branch did not run, so
/// "the help never printed" and "the help printed the wrong thing" are different failures.
[[noreturn]] void
helpBranchThenExitThreeIfItDidNotRun(const std::string& commandLine)
{
    std::cout.rdbuf(std::cerr.rdbuf());
    // unitbuf as well as the rdbuf swap. std::exit does flush cout on the way out, so this is
    // belt and braces -- but the failure it insures against is a case that goes red for a reason
    // that has nothing to do with the code under test, and a flaky death test is worse than none.
    std::cout.setf(std::ios::unitbuf);
    std::vector<std::string> words = splitWords(commandLine);
    std::vector<char*> argv;
    for (auto& w : words)
    {
        argv.push_back(w.data());
    }
    argv.push_back(nullptr);
    Logger::parse_cli_args(static_cast<int>(words.size()), argv.data());
    std::exit(3);
}

/// In-process: the check must RETURN. The failure mode these cases look for is the process
/// exiting, so there is nothing to EXPECT_ -- reaching the next line is the assertion.
void
runCheck(const std::string& commandLine, const std::vector<CliFlag>& alsoKnown)
{
    std::vector<std::string> words = splitWords(commandLine);
    std::vector<char*> argv;
    for (auto& w : words)
    {
        argv.push_back(w.data());
    }
    argv.push_back(nullptr);
    Logger::reject_unknown_flags(static_cast<int>(words.size()), argv.data(), alsoKnown);
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

// =================================================================================================
// FINDINGS #70 -- an option nobody owns is an ERROR, and an option somebody owns is not
//
// Half of this block asserts a refusal and half asserts an acceptance, and the second half is the
// one that gives the first half its meaning. `reject_unknown_flags` returning void and exiting on
// failure means "refuse everything" would pass every refusal case here; only the acceptance cases
// can tell a check that reads the tables from a check that does not.
// =================================================================================================

TEST(LoggerCliArgsDeathTest, AnUnknownOptionIsRefusedRatherThanSilentlyIgnored)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    // The finding, verbatim. Before the fix this exited 0, wrote nothing, and left the operator
    // with a run that had silently not been given a log file.
    EXPECT_EXIT(checkThenExitZeroIfAccepted("ndtwin_kernel --logfle /tmp/x.log"),
                ::testing::ExitedWithCode(2),
                "unknown option '--logfle'");
}

/// A refusal that does not say what WOULD have been accepted just moves the guessing one step
/// along, and the accepted list is built from the same tables the check consults -- so this also
/// pins that the message cannot advertise a flag the check would go on to reject.
TEST(LoggerCliArgsDeathTest, TheRefusalNamesTheOptionsThatWouldHaveBeenAccepted)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(checkThenExitZeroIfAccepted("ndtwin_kernel --logfle /tmp/x.log"),
                ::testing::ExitedWithCode(2),
                "Accepted options:.*--loglevel");
}

TEST(LoggerCliArgsDeathTest, AMistypedShortOptionIsRefusedToo)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(checkThenExitZeroIfAccepted("ndtwin_kernel -x"), ::testing::ExitedWithCode(2),
                "unknown option '-x'");
}

/// `--loglevel=debug` is the shape every operator tries at least once, and NEITHER parser honours
/// the equals form -- both branch on the whole token. Accepting it silently would be the original
/// defect with a different spelling: a request taken and dropped.
TEST(LoggerCliArgsDeathTest, TheEqualsFormIsRefusedBecauseNeitherParserHonoursIt)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(checkThenExitZeroIfAccepted("ndtwin_kernel --loglevel=debug"),
                ::testing::ExitedWithCode(2),
                "unknown option '--loglevel=debug'");
}

/// The union is a union. `--mode` is fine in the kernel and unknown in a binary that has no
/// deployment flags, and the check answers from the tables it was given rather than from a
/// hard-coded idea of what a command line looks like.
TEST(LoggerCliArgsDeathTest, AFlagTheCallerDidNotDeclareIsUnknownEvenThoughTheKernelOwnsIt)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(checkLoggingOnlyThenExitZeroIfAccepted("standalone --mode mininet"),
                ::testing::ExitedWithCode(2),
                "unknown option '--mode'");
}

// ---- the other direction: what must still be accepted -------------------------------------------

/// RELAXING-DIRECTION CONTROL. A check written as `std::exit(2)` on every option-shaped token
/// would pass all five cases above. Every flag Logger owns is driven through it here; if the
/// process dies inside this case, the check has stopped reading its own table.
TEST(LoggerCliArgsTest, EveryFlagTheLoggingParserOwnsSurvivesTheCheck)
{
    for (const CliFlag& f : Logger::logging_flags())
    {
        const std::string line =
            std::string("ndtwin_kernel ") + f.name + (f.arity == 1 ? " avalue" : "");
        runCheck(line, deploymentFlagsAsMainDeclaresThem());
        SUCCEED() << f.name << " accepted";
    }
}

/// RELAXING-DIRECTION CONTROL, the caller's half. This is the stand-in table, not main's -- see
/// deploymentFlagsAsMainDeclaresThem. What it pins is that a flag the CALLER declares is honoured
/// at all; that main declares the right ones is pinned by the gate, on the real binary.
TEST(LoggerCliArgsTest, EveryFlagTheCallerDeclaresSurvivesTheCheck)
{
    for (const CliFlag& f : deploymentFlagsAsMainDeclaresThem())
    {
        const std::string line =
            std::string("ndtwin_kernel ") + f.name + (f.arity == 1 ? " avalue" : "");
        runCheck(line, deploymentFlagsAsMainDeclaresThem());
        SUCCEED() << f.name << " accepted";
    }
}

/// A whole realistic command line, both parsers' flags interleaved. This is the case that would
/// go red if the check ever forgot that the two tables are consulted together.
TEST(LoggerCliArgsTest, ACommandLineUsingBothParsersFlagsIsAccepted)
{
    runCheck("ndtwin_kernel --mode mininet --topology /etc/topo.json --no-ai "
             "--logfile /tmp/a.log --loglevel debug",
             deploymentFlagsAsMainDeclaresThem());
    SUCCEED();
}

/// The VALUE of a value-taking flag is stepped over, not scanned. A path that begins with '-' is
/// unusual and legal, and the parser that owns the flag is the one entitled to judge its value --
/// this check must not start refusing command lines on the strength of a filename.
TEST(LoggerCliArgsTest, TheValueOfAValueTakingFlagIsNotScannedAsAnOption)
{
    runCheck("ndtwin_kernel --topology -weird-but-a-real-path.json",
             deploymentFlagsAsMainDeclaresThem());
    SUCCEED();
}

/// NEGATIVE, and a documented limit rather than an accident: this check owns option-shaped tokens
/// only. A positional is somebody else's business, and a bare "-" is a value by the same
/// convention require_value is written to.
TEST(LoggerCliArgsTest, APositionalAndABareDashAreNotOptions)
{
    runCheck("ndtwin_kernel somefile - ", deploymentFlagsAsMainDeclaresThem());
    SUCCEED();
}

// ---- the table and the parser are two statements of one fact -------------------------------------

/// DRIFT GUARD. Logger::logging_flags() is what the check believes the parser accepts; the branch
/// chain in parse_cli_args is what it actually accepts. A flag in the parser but not the table is
/// refused even though the program understands it, and a flag in the table but not the parser is
/// accepted and does nothing -- which is the defect this file exists for. Every arity-1 entry is
/// driven through the real parser here and must change the config it returns.
///
/// 🔴 ONE PROBE VALUE, NOT A PER-FLAG LOOKUP, AND THE GATE IS WHY. The first version of this case
/// carried a name -> value map and failed on any table entry it did not recognise. That reads like
/// diligence and is the opposite: it made this case pin the table's CONTENTS, so
/// tests/shell/mutate_logger_cli.sh's W2 widening -- adding a third legitimate spelling of an
/// existing flag -- turned it red, and a suite that cannot tell a widening from a break cannot
/// give its catches any meaning. "debug" is a valid level name AND a usable file path, so it is a
/// legal value for every value-taking logging flag there is; the table drives the loop and the
/// test knows nothing about which flag is which.
TEST(LoggerCliArgsTest, EveryValueTakingFlagInTheTableIsHonouredByTheParser)
{
    const LogConfig defaults;
    for (const CliFlag& f : Logger::logging_flags())
    {
        if (f.arity == 0)
        {
            continue; // --help/-h exit the process; they have death tests of their own below.
        }
        Argv a{"ndtwin_kernel", f.name, "debug"};
        const LogConfig cfg = Logger::parse_cli_args(a.argc(), a.argv());
        EXPECT_TRUE(cfg.filePath != defaults.filePath || cfg.level != defaults.level)
            << f.name << " is in the table, so the check accepts it -- but the parser did nothing "
                         "with it, which is the 'accepted and had no effect' shape exactly";
    }
}

/// FINDINGS #70's first half, executed. This branch has never run in the kernel: src/main.cpp's
/// parser answers --help first and returns 0, so `ndtwin_kernel --help` is main's text, not this
/// one. It is still the only --help a logging-only binary has (see
/// doc/audit/2026-09-01_esa-power-off-injection/driver.cpp), and an unexecuted branch is how a
/// help text and a behaviour drift apart -- so it is run here rather than left to be assumed.
TEST(LoggerCliArgsDeathTest, TheHelpBranchOfTheLoggingParserRunsAndPrintsTheOptionBlock)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(helpBranchThenExitThreeIfItDidNotRun("standalone --help"),
                ::testing::ExitedWithCode(0),
                "--logfile, -f <path>");
}

TEST(LoggerCliArgsDeathTest, TheShortHelpBranchRunsToo)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    EXPECT_EXIT(helpBranchThenExitThreeIfItDidNotRun("standalone -h"),
                ::testing::ExitedWithCode(0),
                "--loglevel, -l <level>");
}

// =================================================================================================
// FINDINGS #69 -- the level names, from the other direction
//
// EveryLevelNameTheHelpAdvertisesIsAccepted (above) reads a list written out in this file. This
// one reads the list out of the HELP TEXT ITSELF, so a name added to the usage that parse_level
// does not accept is caught -- the direction the hard-coded case cannot see.
// =================================================================================================

TEST(LoggerUsageTextTest, EveryLevelNameTheUsageActuallyPrintsIsAcceptedByTheParser)
{
    const std::string usage = Logger::cli_usage();
    const std::string marker = "--loglevel, -l <level>";
    const std::size_t at = usage.find(marker);
    ASSERT_NE(at, std::string::npos) << usage;
    const std::size_t eol = usage.find('\n', at);
    ASSERT_NE(eol, std::string::npos) << usage;

    std::string names = usage.substr(at + marker.size(), eol - at - marker.size());
    std::size_t start = 0;
    std::vector<std::string> listed;
    while (start <= names.size())
    {
        const std::size_t comma = names.find(',', start);
        std::string one = names.substr(start, comma == std::string::npos ? std::string::npos
                                                                        : comma - start);
        const std::size_t b = one.find_first_not_of(" \t");
        const std::size_t e = one.find_last_not_of(" \t");
        if (b != std::string::npos)
        {
            listed.push_back(one.substr(b, e - b + 1));
        }
        if (comma == std::string::npos)
        {
            break;
        }
        start = comma + 1;
    }

    ASSERT_GE(listed.size(), 5u) << "the usage line was not parsed as a list of levels: " << names;
    for (const std::string& name : listed)
    {
        // parse_level exits 2 on a name it does not accept, so a failure here ends the process
        // inside this case rather than printing a FAILED line. The gate reads that as a red for
        // this case by name; see run_tests in tests/shell/mutate_logger_cli.sh.
        const spdlog::level::level_enum got = Logger::parse_level(name);
        EXPECT_TRUE(got != spdlog::level::off || name == "off")
            << "the usage advertises '" << name << "', which the parser turns into off";
    }
}

} // namespace
