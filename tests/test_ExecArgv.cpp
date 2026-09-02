/**
 * Tests for utils::execArgv -- the shell-free executor introduced for doc/KNOWN-ISSUES.md B-2b/B-4.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ## What is being pinned, and why it is not "quoting"
 *
 * The family of defects these tests exist for is not "the kernel forgot to escape a quote". It is
 * "the kernel handed a structured value to a shell, which reads structure as syntax". Three call
 * sites built `curl ... -d '<json>'` and passed it to popen(); popen() means `/bin/sh -c`; a `'`
 * inside the JSON therefore ended the quoting and the rest was read as commands. json::dump() had
 * done its job correctly -- `'` is not a JSON metacharacter -- which is why the bug survived
 * review three times.
 *
 * So the property under test is **absence of interpretation**, not correctness of escaping. There
 * is no character table here to check, and a test that fed it a list of dangerous characters would
 * be testing the wrong thing: it would pass for an implementation that escaped those characters
 * and no others. What is asserted instead is that a byte sequence goes in as one argument and
 * comes out unchanged, whatever bytes it is -- including a complete shell command, which is the
 * strongest single case because it is what an attacker actually sends.
 *
 * ## These tests run real processes
 *
 * Deliberately. execArgv's whole content is fork/exec/wait; a fake would be asserting that the
 * test double does not use a shell. They use /bin/echo, /bin/sh and /bin/false -- POSIX-standard
 * paths present on any machine that can build this kernel -- and none of them touch the network,
 * the lab, or any file. `sh -c` appears in one test as the *subject* (proving the escape hatch is
 * only taken when a caller explicitly asks for it), never as the executor.
 */

#include <gtest/gtest.h>

#include "utils/Utils.hpp"

#include <string>
#include <vector>

namespace
{

/// One would-be shell command, used as a payload rather than executed. If execArgv ever handed its
/// arguments to a shell, this is the value that would make it obvious -- and it is close to what
/// KNOWN-ISSUES B-2b describes an attacker sending through the northbound API.
const char* const kHostileValue = R"(x'; touch /tmp/ndtwin-pwned; echo ')";

} // namespace

TEST(ExecArgvTest, PassesAnArgumentThroughUnchangedNoMatterWhatIsInIt)
{
    // echo writes its arguments back, so what comes out is what the child was actually given. A
    // shell in the path would have split this on the quote and the semicolons; execvp cannot.
    const utils::CommandOutcome outcome = utils::execArgv({"/bin/echo", kHostileValue});

    EXPECT_TRUE(outcome.ran);
    EXPECT_TRUE(outcome.succeeded());
    EXPECT_EQ(outcome.output, std::string(kHostileValue) + "\n")
        << "the argument must arrive byte-for-byte; anything else means something parsed it";
}

TEST(ExecArgvTest, KeepsArgumentsSeparateEvenWhenTheyContainSpacesAndQuotes)
{
    // The property a joined command line loses. `-H` and its value are two arguments; if they were
    // ever flattened and re-split, this header would become several arguments and curl would see a
    // different request. Same shape as the `-d <body>` pair that B-2b/B-4 turned into shell source.
    const utils::CommandOutcome outcome =
        utils::execArgv({"/bin/echo", "Content-Type: application/json", "second 'arg'"});

    EXPECT_TRUE(outcome.succeeded());
    EXPECT_EQ(outcome.output, "Content-Type: application/json second 'arg'\n");
}

TEST(ExecArgvTest, DoesNotInterpretShellMetacharactersInAnyPosition)
{
    // Not a blacklist of characters this implementation handles -- a demonstration that the
    // question does not arise. Command substitution is included because it is the form that needs
    // no quote at all, and therefore the form a quote-rejecting filter would have missed: that is
    // exactly how app_register's simulation_completed_url stayed exploitable in the original
    // analysis, which framed the whole family as "the single-quote bug".
    for (const std::string& payload : {std::string("$(id)"),
                                       std::string("`id`"),
                                       std::string("a && b"),
                                       std::string("a | b"),
                                       std::string("> /tmp/ndtwin-should-not-exist"),
                                       std::string("line\nbreak"),
                                       std::string("$HOME"),
                                       std::string("*")})
    {
        const utils::CommandOutcome outcome = utils::execArgv({"/bin/echo", payload});
        EXPECT_TRUE(outcome.succeeded()) << payload;
        EXPECT_EQ(outcome.output, payload + "\n")
            << "something expanded, globbed or split this: " << payload;
    }
}

TEST(ExecArgvTest, ReportsThatItRanEvenWhenTheProgramFailed)
{
    // The distinction doc/KNOWN-ISSUES.md B-2b's message collapsed. `ran` is not `succeeded`:
    // /bin/false ran perfectly well and exited 1, exactly as curl exits 22 on an HTTP 404. A
    // caller that treated a non-zero exit as "the request never left" would misreport the far end
    // in the other direction.
    const utils::CommandOutcome outcome = utils::execArgv({"/bin/false"});

    EXPECT_TRUE(outcome.ran) << "the program was reached and reaped, so it ran";
    EXPECT_FALSE(outcome.succeeded());
    EXPECT_NE(outcome.status, 0);
}

TEST(ExecArgvTest, ReportsExitOneTwentySevenWhenTheProgramIsNotThere)
{
    // The case that must NOT be reported as "the component did not answer". A missing curl is a
    // fact about this host, and HttpRoutingStrategyBase turns this status into a verdict that says
    // so instead of naming the controller.
    const utils::CommandOutcome outcome =
        utils::execArgv({"/nonexistent/ndtwin-no-such-program-a6f9"});

    EXPECT_TRUE(WIFEXITED(outcome.status));
    EXPECT_EQ(WEXITSTATUS(outcome.status), 127);
    EXPECT_FALSE(outcome.succeeded());
    EXPECT_NE(utils::describeCommandStatus(outcome.status, "curl").find("not found"),
              std::string::npos)
        << "the operator has to be told what is missing";
}

TEST(ExecArgvTest, RefusesAnEmptyArgv)
{
    // There is no program to run and no sensible exit status to invent. Throwing here is safe
    // because it can only be a programming error: argv[0] is a literal at every call site.
    EXPECT_THROW(utils::execArgv({}), std::invalid_argument);
}

TEST(ExecArgvTest, CapturesLargeOutputWithoutTruncatingOrDeadlocking)
{
    // The read loop is hand-written, so its two classic failure modes are worth pinning: stopping
    // at the first partial read, and filling the pipe buffer while the parent waits on waitpid.
    // 200 kB is comfortably past the 64 kB pipe capacity on Linux. Measured cost: milliseconds.
    const std::string chunk(1000, 'x');
    std::vector<std::string> argv = {"/bin/echo", "-n"};
    for (int i = 0; i < 200; ++i)
    {
        argv.push_back(chunk);
    }

    const utils::CommandOutcome outcome = utils::execArgv(argv);

    EXPECT_TRUE(outcome.succeeded());
    // 200 chunks of 1000, separated by 199 spaces.
    EXPECT_EQ(outcome.output.size(), static_cast<size_t>(200 * 1000 + 199));
}

TEST(ExecArgvTest, RunsAShellOnlyWhenTheCallerNamesOneAsTheProgram)
{
    // The escape hatch, pinned so that its existence is a decision rather than a discovery. A
    // caller that genuinely needs a pipeline has to write /bin/sh in argv[0], where a reviewer
    // will see it -- as opposed to the old execCommand, where every caller got a shell whether or
    // not it wanted one, and no call site looked like it was asking for a shell.
    const utils::CommandOutcome outcome = utils::execArgv({"/bin/sh", "-c", "echo from-a-shell"});

    EXPECT_TRUE(outcome.succeeded());
    EXPECT_EQ(outcome.output, "from-a-shell\n");
}

TEST(DescribeArgvTest, RendersForHumansAndIsNotAShellQuoter)
{
    // Named "describe" rather than "join" for this reason, and tested so nobody feeds it back to a
    // shell: the rendering of an argument containing a space is indistinguishable from two
    // arguments. Reintroducing that ambiguity into an execution path would be B-2b again.
    EXPECT_EQ(utils::describeArgv({"curl", "-d", "a b"}), "curl -d a b");
    EXPECT_EQ(utils::describeArgv({"curl", "-d", "a", "b"}), "curl -d a b");
    EXPECT_EQ(utils::describeArgv({}), "");
}
