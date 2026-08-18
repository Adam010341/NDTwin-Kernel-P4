// Tests for ApplicationManager's command layer: what std::system()'s return value is taken to
// mean, and the exact commands composed against the exports file.
//
// [Co-developed with claude code -- Adam]
//
// First tests this class has ever had (HANDOFF 1i listed it as the last untested manager).
// They stop at the command layer on purpose: everything past it needs root, an NFS server and
// /etc/exports, which is why the builders exist as seams at all -- the same reasoning as
// test_RequestDeadlines.cpp. The sed tests run the real sed against a temp file, because the
// defect they pin down lives in sed's address semantics, not in string assembly: the inline
// original was an unanchored substring match, so purging /srv/nfs/1 also deleted the lines for
// /srv/nfs/10 and /srv/nfs/100 -- every app whose id extends the purged one, silently, at every
// kernel start (cleanupStaleEntries runs from the constructor).

#include "ndt_core/application_management/ApplicationManager.hpp"

#include <gtest/gtest.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h> // geteuid: the reuse tests refuse to run as root, see their comment
#include <vector>

namespace fs = std::filesystem;

/// Reaches the protected statics without constructing the manager, whose constructor walks the
/// export directory and shells out to sudo exportfs (cleanupStaleEntries).
struct Seams : ApplicationManager
{
    using ApplicationManager::buildExportsPurgeCommand;
    using ApplicationManager::buildUnexportCommand;
    using ApplicationManager::exportsFileHasEntry;
    using ApplicationManager::isSquashedClientContentFailure;
    using ApplicationManager::exportsLineFor;
    using ApplicationManager::openUpAppDirPermissions;
};

// --- describeCommandFailure: decoding std::system()'s wait status ---------------------------

TEST(DescribeCommandFailure, SuccessIsTheEmptyString)
{
    // The call sites branch on emptiness; a non-empty "ok" would warn on every success.
    EXPECT_EQ("", ApplicationManager::describeCommandFailure(0));
}

TEST(DescribeCommandFailure, MinusOneMeansTheChildWasNeverCreated)
{
    const auto why = ApplicationManager::describeCommandFailure(-1);
    EXPECT_NE(why.find("could not be created"), std::string::npos) << why;
}

TEST(DescribeCommandFailure, AWaitStatusIsDecodedNotEchoed)
{
    // status is a wait status: the exit code lives in the high byte. Reporting 768 for
    // "exit 3" is the mistake the decoder exists to prevent.
    const auto why = ApplicationManager::describeCommandFailure(3 << 8);
    EXPECT_NE(why.find("exit status 3"), std::string::npos) << why;
    EXPECT_EQ(why.find("768"), std::string::npos) << why;
}

TEST(DescribeCommandFailure, OneTwoSevenNamesTheShellNotTheCommand)
{
    // 127 is "the shell could not execute it" -- on this machine, almost always sudo
    // refusing a detached process. The wording is what makes the log actionable.
    const auto why = ApplicationManager::describeCommandFailure(127 << 8);
    EXPECT_NE(why.find("127"), std::string::npos) << why;
    EXPECT_NE(why.find("sudo"), std::string::npos) << why;
}

TEST(DescribeCommandFailure, ASignalIsReportedAsASignal)
{
    // Raw wait status 9: WIFSIGNALED, WTERMSIG == 9 (SIGKILL). An OOM-killed exportfs must
    // not read as an exit code.
    const auto why = ApplicationManager::describeCommandFailure(9);
    EXPECT_NE(why.find("signal 9"), std::string::npos) << why;
}

// --- the composed commands ------------------------------------------------------------------

TEST(UnexportCommand, NamesExportfsAndTheFolder)
{
    const auto cmd = Seams::buildUnexportCommand("/srv/nfs/sim/7");
    EXPECT_EQ(cmd.rfind("sudo ", 0), 0u) << cmd;
    EXPECT_NE(cmd.find("exportfs -u"), std::string::npos) << cmd;
    EXPECT_NE(cmd.find("/srv/nfs/sim/7"), std::string::npos) << cmd;
}

TEST(ExportsLine, StartsWithTheDirectoryAndASpace)
{
    // The purge address anchors on exactly this shape: line start, directory, one space.
    const auto line = Seams::exportsLineFor("/srv/nfs/sim/7");
    EXPECT_EQ(line.rfind("/srv/nfs/sim/7 ", 0), 0u) << line;
    EXPECT_NE(line.find("*("), std::string::npos) << line;
}

// --- the purge, run against a real sed ------------------------------------------------------

namespace
{

/// Writes `lines` to a temp exports file, runs the purge command for `folder` against it
/// (with the leading "sudo " stripped: the semantics under test are sed's, and a unit test
/// must not prompt), and returns the lines that survived.
std::vector<std::string> purgeSurvivors(const std::string& folder,
                                        const std::vector<std::string>& lines)
{
    static int unique = 0;
    const fs::path file = fs::temp_directory_path() /
                          ("ndtwin_exports_purge_" + std::to_string(::getpid()) + "_" +
                           std::to_string(unique++));
    {
        std::ofstream out(file);
        for (const auto& line : lines)
        {
            out << line << "\n";
        }
    }

    const std::string cmd = Seams::buildExportsPurgeCommand(folder, file.string());
    EXPECT_EQ(cmd.rfind("sudo ", 0), 0u) << cmd;
    EXPECT_EQ(std::system(cmd.substr(5).c_str()), 0) << cmd;

    std::vector<std::string> survivors;
    std::ifstream in(file);
    for (std::string line; std::getline(in, line);)
    {
        survivors.push_back(line);
    }
    fs::remove(file);
    return survivors;
}

} // namespace

TEST(ExportsPurge, RemovesExactlyTheLineTheWriterWrote)
{
    // Writer and eraser share exportsLineFor, so this is the round trip: what
    // updateNFSConfig appends, cleanupAppFolder can remove.
    const auto survivors = purgeSurvivors("/srv/nfs/sim/1",
                                          {Seams::exportsLineFor("/srv/nfs/sim/1")});
    EXPECT_TRUE(survivors.empty()) << survivors.size() << " line(s) survived";
}

TEST(ExportsPurge, APrefixSiblingSurvives)
{
    // The defect this file exists for: /srv/nfs/sim/1 is a prefix of /srv/nfs/sim/10 and
    // /srv/nfs/sim/100, and the unanchored original deleted all three lines. App ids are
    // sequential integers, so every long-running deployment has these siblings.
    const auto ten = Seams::exportsLineFor("/srv/nfs/sim/10");
    const auto hundred = Seams::exportsLineFor("/srv/nfs/sim/100");
    const auto survivors =
        purgeSurvivors("/srv/nfs/sim/1",
                       {Seams::exportsLineFor("/srv/nfs/sim/1"), ten, hundred});
    EXPECT_EQ(survivors, (std::vector<std::string>{ten, hundred}));
}

TEST(ExportsPurge, ADotInTheExportRootIsNotAWildcard)
{
    // The configured export root is operator input; a '.' in it must match a dot, not any
    // character. The original escaped only '/'.
    const auto other = Seams::exportsLineFor("/srv/nfsXd/1");
    const auto survivors =
        purgeSurvivors("/srv/nfs.d/1", {Seams::exportsLineFor("/srv/nfs.d/1"), other});
    EXPECT_EQ(survivors, (std::vector<std::string>{other}));
}

TEST(ExportsPurge, AMidlineMentionOfTheFolderIsNotItsLine)
{
    // '^' does the work here: an unrelated export whose options happen to mention the purged
    // path (a bind-mount comment, a hand-edited line) is not that folder's export line. The
    // mention sits mid-line with text after it, so only the anchor separates the two cases --
    // a pattern that merely requires "<folder><space>" matches this line too.
    const std::string bystander = "/srv/other *(rw) # mirrors /srv/nfs/sim/1 nightly";
    const auto survivors =
        purgeSurvivors("/srv/nfs/sim/1",
                       {Seams::exportsLineFor("/srv/nfs/sim/1"), bystander});
    EXPECT_EQ(survivors, (std::vector<std::string>{bystander}));
}

// --- the non-root registration path (2026-08-15) --------------------------------------------
//
// [Co-developed with claude code -- Adam]
// Live 2026-08-15: a non-root kernel chown'd nothing, the app directory stayed 775, the NFS
// export's all_squash then denied the (root-run, squashed-to-nobody) Energy app its first
// case-input write, and its decision loop wedged permanently on a stuck flag. The fix makes
// chmod-by-owner do chown's job and turns the whole non-root lifecycle into something a unit
// test can hold: no sudo, no NFS server, no root anywhere below.

TEST(ExportsFileHasEntry, FindsExactlyTheFoldersOwnLine)
{
    const std::string file = testing::TempDir() + "has_entry_exact.exports";
    {
        std::ofstream f(file);
        f << Seams::exportsLineFor("/srv/nfs/sim/1") << "\n";
        f << Seams::exportsLineFor("/srv/nfs/sim/10") << "\n";
    }
    EXPECT_TRUE(Seams::exportsFileHasEntry("/srv/nfs/sim/1", file));
    EXPECT_FALSE(Seams::exportsFileHasEntry("/srv/nfs/sim/2", file));
    fs::remove(file);
}

TEST(ExportsFileHasEntry, AMidlineMentionIsNotTheFoldersLine)
{
    // Same rule as the purge address: the line must START with the folder. An unrelated
    // export whose options mention the path must not make cleanup think a line exists.
    const std::string file = testing::TempDir() + "has_entry_midline.exports";
    {
        std::ofstream f(file);
        f << "/srv/other *(rw) # mirrors /srv/nfs/sim/1 nightly\n";
    }
    EXPECT_FALSE(Seams::exportsFileHasEntry("/srv/nfs/sim/1", file));
    fs::remove(file);
}

TEST(ExportsFileHasEntry, AFolderWhoseIdExtendsTheQueriedOneIsNotAMatch)
{
    // The same trap the sed anchor exists for: with only /srv/nfs/sim/10 in the file,
    // asking about /srv/nfs/sim/1 must say no -- the space after the directory is the
    // separator that keeps prefixes from claiming each other's lines.
    const std::string file = testing::TempDir() + "has_entry_prefix.exports";
    {
        std::ofstream f(file);
        f << Seams::exportsLineFor("/srv/nfs/sim/10") << "\n";
    }
    EXPECT_FALSE(Seams::exportsFileHasEntry("/srv/nfs/sim/1", file));
    fs::remove(file);
}

TEST(ExportsFileHasEntry, AnUnreadableFileMeansAttemptCleanupAnyway)
{
    // When the exports file cannot be read there is no way to know; the safe fallback is the
    // old always-attempt behaviour, not a silent skip that could leave a real export live.
    EXPECT_TRUE(Seams::exportsFileHasEntry("/srv/nfs/sim/1",
                                           testing::TempDir() + "does_not_exist.exports"));
}

TEST(OpenUpAppDirPermissions, MakesTheDirectoryWritableForSquashedClients)
{
    const fs::path dir = fs::path(testing::TempDir()) / "appmgr_perms_test_dir";
    fs::create_directories(dir);
    fs::permissions(dir, fs::perms::owner_all); // start at 700: the failing shape, owner-only
    ASSERT_TRUE(Seams::openUpAppDirPermissions(dir));
    const auto p = fs::status(dir).permissions();
    // all_squash maps every client to nobody; nobody writes through the 'others' bits.
    EXPECT_EQ(p & fs::perms::others_write, fs::perms::others_write);
    EXPECT_EQ(p & fs::perms::all, fs::perms::all);
    fs::remove_all(dir);
}

TEST(OpenUpAppDirPermissions, AMissingPathReportsFalseNotSuccess)
{
    EXPECT_FALSE(Seams::openUpAppDirPermissions(fs::path(testing::TempDir()) / "no_such_dir_x"));
}

TEST(NonRootLifecycle, RegistrationProvisionsAWritableWorkspaceWithoutRoot)
{
    const fs::path exportDir = fs::path(testing::TempDir()) / "appmgr_lifecycle_export";
    const fs::path mountDir = fs::path(testing::TempDir()) / "appmgr_lifecycle_mount";
    fs::remove_all(exportDir);
    fs::create_directories(exportDir);

    fs::path appDir;
    {
        ApplicationManager mgr(exportDir.string(), mountDir.string());
        const int id = mgr.registerApplication("power", "http://localhost:8001/result");
        EXPECT_GE(id, 1);
        appDir = exportDir / std::to_string(id);
        ASSERT_TRUE(fs::exists(appDir)) << appDir;
        // The functional core of the fix: without root, the workspace must still end up
        // writable through an all_squash export.
        const auto p = fs::status(appDir).permissions();
        EXPECT_EQ(p & fs::perms::all, fs::perms::all);
        // The per-app export line is best-effort; the setup itself must not report failure
        // just because /etc/exports is not writable here.
        EXPECT_TRUE(mgr.setupNFSForApp(id + 1));
    }
    // Destructor cleanup: folders go away without sudo ever being involved (their lines were
    // never in /etc/exports, so cleanup has nothing to unexport and stays silent).
    EXPECT_FALSE(fs::exists(appDir));
    fs::remove_all(exportDir);
}

// --- setupNFSForApp on a directory that already exists ---------------------------------------
//
// [Co-developed with claude code -- Adam]
// create_directories returns false for two opposite reasons -- "creation failed" and "it was
// already there" -- and the original treated both as failure, returning before the permissions
// were applied. Reuse is the normal case rather than the exotic one: m_nextAppId lives in memory
// and restarts at 1, while cleanupStaleEntries only removes a previous run's folder when
// fs::remove_all succeeds, and that is exactly what fails when a squashed client left
// root-owned files behind. So the failure kept itself alive across restarts: the permissions
// that would let the next cleanup succeed were the ones being skipped.
//
// Found on a live run 2026-08-17 (app id 1 reused: warning plus no permissions; id 2 fresh:
// clean). Present unchanged in baseline 28b8b13.
//
// These construct the manager, so they must not run as root: updateNFSConfig would then really
// append to /etc/exports. As a normal user its ofstream open fails, which short-circuits
// reloadNFSServer, so nothing shells out at all.

namespace
{
/// A previous run's leftover: the directory exists, owner-only, before setup is asked for it.
fs::path seedLeftoverAppDir(const fs::path& exportDir, int appId)
{
    const fs::path appDir = exportDir / std::to_string(appId);
    fs::create_directories(appDir);
    fs::permissions(appDir, fs::perms::owner_all); // 700 -- squashed clients cannot write
    return appDir;
}
} // namespace

TEST(SetupNFSForApp, AnAlreadyExistingDirectoryIsReusedAndItsPermissionsReapplied)
{
    if (geteuid() == 0)
    {
        GTEST_SKIP() << "would append to the real /etc/exports as root";
    }
    const fs::path exportDir = fs::path(testing::TempDir()) / "appmgr_reuse_export";
    const fs::path mountDir = fs::path(testing::TempDir()) / "appmgr_reuse_mount";
    fs::remove_all(exportDir);
    fs::create_directories(exportDir);

    ApplicationManager mgr(exportDir.string(), mountDir.string());
    // Seeded after construction: cleanupStaleEntries() runs from the constructor and deletes
    // every all-digits folder it finds, which would remove the very condition under test.
    const fs::path appDir = seedLeftoverAppDir(exportDir, 7);
    ASSERT_EQ(fs::status(appDir).permissions() & fs::perms::others_write, fs::perms::none)
        << "seed must start unwritable, or the assertion below proves nothing";

    // The defect: this returned false and left the directory at 700.
    EXPECT_TRUE(mgr.setupNFSForApp(7));
    EXPECT_EQ(fs::status(appDir).permissions() & fs::perms::all, fs::perms::all)
        << "reuse must still open up permissions -- skipping them is what made the condition "
           "survive every restart";

    fs::remove_all(exportDir);
}

TEST(SetupNFSForApp, AFreshDirectoryIsStillCreatedAndOpenedUp)
{
    if (geteuid() == 0)
    {
        GTEST_SKIP() << "would append to the real /etc/exports as root";
    }
    const fs::path exportDir = fs::path(testing::TempDir()) / "appmgr_fresh_export";
    const fs::path mountDir = fs::path(testing::TempDir()) / "appmgr_fresh_mount";
    fs::remove_all(exportDir);
    fs::create_directories(exportDir);

    ApplicationManager mgr(exportDir.string(), mountDir.string());
    const fs::path appDir = exportDir / "3";
    ASSERT_FALSE(fs::exists(appDir));

    EXPECT_TRUE(mgr.setupNFSForApp(3));
    ASSERT_TRUE(fs::is_directory(appDir));
    EXPECT_EQ(fs::status(appDir).permissions() & fs::perms::all, fs::perms::all);

    fs::remove_all(exportDir);
}

TEST(SetupNFSForApp, APathBlockedByARegularFileStillReportsFailure)
{
    if (geteuid() == 0)
    {
        GTEST_SKIP() << "would append to the real /etc/exports as root";
    }
    // The half the fix must not lose: distinguishing "already there" from "could not create"
    // has to keep answering false for the second. A regular file sitting on the path is the
    // cheapest reachable form of it.
    const fs::path exportDir = fs::path(testing::TempDir()) / "appmgr_blocked_export";
    const fs::path mountDir = fs::path(testing::TempDir()) / "appmgr_blocked_mount";
    fs::remove_all(exportDir);
    fs::create_directories(exportDir);

    ApplicationManager mgr(exportDir.string(), mountDir.string());
    { std::ofstream blocker(exportDir / "5"); blocker << "not a directory\n"; }
    ASSERT_TRUE(fs::is_regular_file(exportDir / "5"));

    EXPECT_FALSE(mgr.setupNFSForApp(5));

    fs::remove_all(exportDir);
}

// --- isSquashedClientContentFailure: which remove_all failure is the expected one --------------
//
// [Co-developed with claude code -- Adam]
// cleanupStaleEntries logged every filesystem_error at ERROR, including the one that happens on
// every start of this deployment and is not fixable without root: the export is all_squash, so an
// application's workspace contents belong to nobody:nogroup, and remove_all needs write permission
// on the parent of each entry. The real 2026-08-18 line was
//   cannot remove all: Permission denied [/srv/nfs/sim/1]
//                                        [/srv/nfs/sim/1/energy_saving_simulator/1.0/case4/input]
// An ERROR that fires every start for something nobody can act on is how a log stops being read.
//
// Tested through the decision rather than the call site, because reproducing the condition needs a
// directory the test process cannot delete, and creating one needs root.

namespace
{
const std::error_code kDenied = std::make_error_code(std::errc::permission_denied);
}

TEST(SquashedClientContentFailure, TheRealObservedFailureIsRecognised)
{
    EXPECT_TRUE(Seams::isSquashedClientContentFailure(
        kDenied, "/srv/nfs/sim/1", "/srv/nfs/sim/1/energy_saving_simulator/1.0/case4/input"));
}

TEST(SquashedClientContentFailure, DeniedOnTheFolderItselfStaysAnError)
{
    // A different condition -- the folder's own parent is not writable -- and unlike the contents
    // that is something this code was supposed to control, so it must keep its ERROR.
    EXPECT_FALSE(Seams::isSquashedClientContentFailure(kDenied, "/srv/nfs/sim/1", "/srv/nfs/sim/1"));
}

TEST(SquashedClientContentFailure, AnotherAppsFolderIsNotThisOnesContents)
{
    // The prefix test must compare path components, not characters: /srv/nfs/sim/10 starts with
    // the string "/srv/nfs/sim/1" but is a different app's workspace. Same trap the exports-file
    // matching above already had to solve.
    EXPECT_FALSE(
        Seams::isSquashedClientContentFailure(kDenied, "/srv/nfs/sim/1", "/srv/nfs/sim/10/input"));
}

TEST(SquashedClientContentFailure, ADifferentErrorOnTheSamePathIsNotExcused)
{
    // Only permission-denied is the expected one. Anything else below the folder is a real
    // failure and must not be filed under this.
    EXPECT_FALSE(Seams::isSquashedClientContentFailure(
        std::make_error_code(std::errc::device_or_resource_busy),
        "/srv/nfs/sim/1",
        "/srv/nfs/sim/1/energy_saving_simulator"));
    EXPECT_FALSE(Seams::isSquashedClientContentFailure(
        std::make_error_code(std::errc::read_only_file_system),
        "/srv/nfs/sim/1",
        "/srv/nfs/sim/1/energy_saving_simulator"));
}

TEST(SquashedClientContentFailure, AnEmptySecondPathIsNotEnoughToExcuseIt)
{
    // Not every filesystem_error carries a second path. With nothing naming what blocked the
    // removal there is no evidence for the benign reading, so it keeps ERROR.
    EXPECT_FALSE(Seams::isSquashedClientContentFailure(kDenied, "/srv/nfs/sim/1", ""));
}

TEST(SquashedClientContentFailure, TrailingSlashesAndDotsDoNotChangeTheAnswer)
{
    EXPECT_TRUE(Seams::isSquashedClientContentFailure(
        kDenied, "/srv/nfs/sim/1/", "/srv/nfs/sim/1/./energy_saving_simulator/case1"));
}
