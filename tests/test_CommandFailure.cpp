/**
 * ApplicationManager's NFS cleanup must not report success it did not get.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Four std::system() calls discarded their exit status entirely -- two `sudo exportfs -ra`, one
 * `sudo exportfs -u <folder>`, and one `sudo sed -i '/<folder>/d' /etc/exports` -- while
 * reloadNFSServer directly above them checked and warned. A failed sudo (the documented failure
 * mode on this machine for a detached process that cannot prompt) left stale exports live and
 * /etc/exports unedited, while "Cleaned and deleted NFS folder" went into the log regardless.
 * cleanupStaleEntries runs from the constructor at every kernel start, in both modes.
 *
 * The seam is describeCommandFailure: a pure function over std::system()'s return value, in the
 * manner of interpretRelayResponse and ovsLivenessFor. The call sites cannot be tested directly
 * -- they shell out to sudo -- but the decision they were missing can be, and the tests below
 * drive the *real* function against the *real* std::system() using /bin/true and /bin/false
 * rather than against hand-built integers, so a wrong decoding of the wait status shows up.
 *
 * That distinction matters here: std::system() does not return an exit code. It returns a wait
 * status, so a command exiting 1 returns 256 on this platform. `status != 0` happens to be
 * right, but nothing about it is right *by construction*, and it cannot say why.
 */

#include <cstdlib>
#include <string>

#include <gtest/gtest.h>

#include "ndt_core/application_management/ApplicationManager.hpp"

namespace
{

/// The real thing: run a command and decode what std::system() actually gave back.
std::string outcomeOf(const char* command)
{
    return ApplicationManager::describeCommandFailure(std::system(command));
}

} // namespace

TEST(CommandFailureTest, ACommandThatSucceedsIsReportedAsSuccess)
{
    EXPECT_EQ(outcomeOf("/bin/true"), "")
        << "a successful command must produce no failure description, or every cleanup would "
           "warn on every kernel start";
}

TEST(CommandFailureTest, ACommandThatFailsIsReportedAsAFailure)
{
    const auto why = outcomeOf("/bin/false");

    EXPECT_NE(why, "") << "/bin/false exited 1 and was reported as success";
    EXPECT_NE(why.find("exit status 1"), std::string::npos)
        << "the description should name the exit code; got: " << why;
}

/**
 * The wait-status decoding, specifically. std::system("/bin/false") returns 256, not 1, so a
 * naive `WEXITSTATUS`-less implementation that printed the raw value would say "exit status 256".
 */
TEST(CommandFailureTest, TheExitCodeIsDecodedFromTheWaitStatusNotPrintedRaw)
{
    const int raw = std::system("/bin/false");
    ASSERT_NE(raw, -1) << "could not run /bin/false at all";

    EXPECT_EQ(ApplicationManager::describeCommandFailure(raw), "exit status 1")
        << "raw std::system() value was " << raw;
}

TEST(CommandFailureTest, ACommandTheShellCannotRunIsNamedAsSuch)
{
    const auto why = outcomeOf("/nonexistent/definitely-not-a-real-command-8f2a1c");

    EXPECT_NE(why, "");
    EXPECT_NE(why.find("127"), std::string::npos)
        << "a command the shell cannot execute exits 127 and should be distinguishable from a "
           "command that ran and refused; got: "
        << why;
}

TEST(CommandFailureTest, AChildThatCouldNotBeCreatedIsDistinguishedFromANonZeroExit)
{
    EXPECT_NE(ApplicationManager::describeCommandFailure(-1), "");
    EXPECT_NE(ApplicationManager::describeCommandFailure(-1).find("could not be created"),
              std::string::npos);
}

TEST(CommandFailureTest, ASignalledCommandIsReportedAsSignalledRatherThanAsAnExitCode)
{
    // 'kill -TERM $$' makes the shell terminate itself, so the wait status carries a signal and
    // WIFEXITED is false. An implementation that only looked at WEXITSTATUS would read garbage.
    const auto why = outcomeOf("kill -TERM $$");

    EXPECT_NE(why, "");
    EXPECT_NE(why.find("signal"), std::string::npos) << "got: " << why;
}
