#include "ndt_core/application_management/ApplicationManager.hpp"
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <regex>
#include <sys/types.h>
#include <sys/wait.h> // for WIFEXITED/WEXITSTATUS, used to decode std::system()'s wait status

namespace fs = std::filesystem;

ApplicationManager::ApplicationManager(const std::string& nfsExportDir,
                                       const std::string& nfsMountPoint)
    : m_nextAppId(1),
      m_nfsExportDir(nfsExportDir),
      m_nfsMountPoint(nfsMountPoint)
{
    cleanupStaleEntries();
}

ApplicationManager::~ApplicationManager()
{
    cleanupNFS();
}

int
ApplicationManager::registerApplication(const std::string& appName,
                                        const std::string& simulationCompletedUrl)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    int appId = m_nextAppId++;
    m_registeredApps[appId] = {appName, simulationCompletedUrl};

    SPDLOG_LOGGER_INFO(Logger::instance(), "Registered app ' {} ' with App ID: {}", appName, appId);

    if (!setupNFSForApp(appId))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Failed to set up NFS for App ID {}", appId);
    }

    return appId;
}

bool
ApplicationManager::setupNFSForApp(int appId)
{
    std::string appDir = m_nfsExportDir + "/" + std::to_string(appId);

    // [Co-developed with claude code -- Adam]
    // create_directories answers "did I create anything", not "does it exist now": it returns
    // false both when creation failed and when the directory was already there. Those two need
    // opposite handling, so the error_code overload is what separates them.
    //
    // Reuse is not an exotic case. m_nextAppId lives in memory and restarts at 1, and
    // cleanupStaleEntries() only removes a previous run's folder when fs::remove_all succeeds --
    // which is exactly what fails once a squashed NFS client has left root-owned files in there.
    // Treating reuse as failure returned before openUpAppDirPermissions, so the permissions that
    // would let the *next* cleanup succeed were never applied: the condition kept itself alive
    // across restarts and only cleared by deleting the folder by hand. Observed 2026-08-17 on a
    // live run (app id 1 reused: warning + permissions skipped; id 2 fresh: clean).
    //
    // The error_code overload also closes a second hole the throwing one left open: with a
    // regular file sitting on the path, create_directories(appDir) *throws* filesystem_error,
    // and nothing between here and the HTTP layer catches it -- reverting this block turns that
    // test from a false return into an uncaught exception out of registerApplication.
    //
    // Present in baseline 28b8b13 unchanged, and `8b61cdc` (the lab's current main) touches only
    // FlowLinkUsageCollector, so this file is byte-identical there too.
    std::error_code ec;
    const bool created = fs::create_directories(appDir, ec);
    if (ec)
    {
        SPDLOG_LOGGER_WARN(
            Logger::instance(), "Failed to create directory {}: {}", appDir, ec.message());
        return false;
    }
    if (!created && !fs::is_directory(appDir, ec))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} exists but is not a directory, so it cannot serve as an app "
                           "workspace",
                           appDir);
        return false;
    }
    if (!created)
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "App directory {} already existed -- a previous run's folder that "
                           "cleanup could not remove. Reusing it and re-applying permissions.",
                           appDir);
    }
    // Recorded either way: this process now serves the app out of that directory, so the
    // destructor owns it. App ids are unique within a process, so this cannot double-add.
    m_registeredFolders.push_back(appDir);

    if (!openUpAppDirPermissions(appDir))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Failed to open up permissions on {}; squashed NFS clients will not "
                           "be able to write their workspace",
                           appDir);
        return false;
    }

    // The per-app export line and the reload need root. Their failure is survivable on any
    // deployment where a parent export already covers m_nfsExportDir (this machine exports
    // /srv/nfs/sim itself, and clients mount the subdirectory through it), so it must not
    // fail the registration -- but it is reported truthfully instead of as a blanket
    // "Failed to set up NFS". [Co-developed with claude code -- Adam]
    if (!updateNFSConfig(appId, appDir) || !reloadNFSServer())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Per-app export line for {} is not active (writing /etc/exports "
                           "needs root); clients can still mount it through a parent export "
                           "of {} if one is configured",
                           appDir,
                           m_nfsExportDir);
    }

    return true;
}

// [Co-developed with claude code -- Adam]
bool
ApplicationManager::openUpAppDirPermissions(const fs::path& appDir)
{
    std::error_code ec;
    fs::permissions(appDir, fs::perms::all, ec);
    return !ec;
}

// [Co-developed with claude code -- Adam]
bool
ApplicationManager::exportsFileHasEntry(const std::string& folder, const std::string& exportsFile)
{
    std::ifstream f(exportsFile);
    if (!f)
    {
        // Cannot know; keep the old always-attempt-cleanup behaviour rather than skipping.
        return true;
    }
    const std::string prefix = folder + " ";
    std::string line;
    while (std::getline(f, line))
    {
        if (line.rfind(prefix, 0) == 0)
        {
            return true;
        }
    }
    return false;
}

std::optional<std::string>
ApplicationManager::getSimulationCompletedUrl(int appId) const
{
    if (!m_registeredApps.count(appId))
    {
        return std::nullopt;
    }
    return m_registeredApps.at(appId).simulationCompletedUrl;
}

bool
ApplicationManager::updateNFSConfig(int appId, const std::string& appDir)
{
    std::ofstream exportsFile("/etc/exports", std::ios::app);
    if (!exportsFile)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Could not open /etc/exports for writing.");
        return false;
    }

    // Example: Allow all clients (rw, sync)
    exportsFile << exportsLineFor(appDir) << "\n";
    exportsFile.close();

    SPDLOG_LOGGER_INFO(Logger::instance(), "Updated /etc/exports for App ID {}", appId);
    return true;
}

// [Co-developed with claude code -- Adam]
std::string
ApplicationManager::exportsLineFor(const std::string& appDir)
{
    return appDir + " *(rw,sync,no_subtree_check,root_squash,all_squash)";
}

// [Co-developed with claude code -- Adam]
std::string
ApplicationManager::buildUnexportCommand(const std::string& folder)
{
    return "sudo exportfs -u " + folder;
}

// [Co-developed with claude code -- Adam]
std::string
ApplicationManager::buildExportsPurgeCommand(const std::string& folder,
                                             const std::string& exportsFile)
{
    // BRE-escape the folder, then anchor both ends of the directory field: '^' pins the line
    // start and the trailing space is the separator exportsLineFor writes before the options,
    // so /srv/nfs/1 cannot claim /srv/nfs/10's line. The '/' must be escaped because it is
    // also the address delimiter.
    std::string escaped;
    escaped.reserve(folder.size());
    for (const char c : folder)
    {
        if (std::strchr(".*[]^$\\/", c) != nullptr)
        {
            escaped += '\\';
        }
        escaped += c;
    }
    return "sudo sed -i '/^" + escaped + " /d' " + exportsFile;
}

// [Co-developed with claude code -- Adam]
std::string
ApplicationManager::describeCommandFailure(int status)
{
    if (status == -1)
    {
        return "the child process could not be created";
    }
    if (WIFSIGNALED(status))
    {
        return "terminated by signal " + std::to_string(WTERMSIG(status));
    }
    if (!WIFEXITED(status))
    {
        return "did not exit normally (raw status " + std::to_string(status) + ")";
    }
    const int code = WEXITSTATUS(status);
    if (code == 0)
    {
        return "";
    }
    if (code == 127)
    {
        return "the shell could not execute it (exit 127; command not found, or sudo refused)";
    }
    return "exit status " + std::to_string(code);
}

bool
ApplicationManager::reloadNFSServer()
{
    int ret = std::system("exportfs -ra && systemctl reload nfs-server");
    const std::string why = describeCommandFailure(ret);
    if (!why.empty())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Failed to reload NFS server: {}", why);
        return false;
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "NFS server reloaded.");
    return true;
}

void ApplicationManager::cleanupNFS()
{
    SPDLOG_INFO("Cleaning up registered NFS folders in {}", m_nfsExportDir);

    bool anyExportWork = false;
    for (const auto& folder : m_registeredFolders)
    {
        anyExportWork |= cleanupAppFolder(folder);
    }

    // Reload NFS exports only when some folder actually had export configuration to remove;
    // otherwise there is nothing to apply and (for a non-root kernel) nothing to warn about.
    // [Co-developed with claude code -- Adam]
    if (anyExportWork)
    {
        if (const auto why = describeCommandFailure(std::system("sudo exportfs -ra")); !why.empty())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "'sudo exportfs -ra' failed after cleanup ({}). Stale exports may "
                               "still be live.",
                               why);
        }
    }
}

// In ApplicationManager.cpp

bool ApplicationManager::cleanupAppFolder(const std::string& folder)
{
    bool hadExportLine = false;
    try
    {
        if (fs::exists(folder))
        {
            // Only touch exportfs and /etc/exports when this folder actually has a line
            // there. A non-root register path never manages to write one, so for it this
            // whole block is a silent skip instead of two doomed sudo calls and their
            // warnings at every start. [Co-developed with claude code -- Adam]
            hadExportLine = exportsFileHasEntry(folder, "/etc/exports");
            std::string unexportWhy;
            std::string sedWhy;
            if (hadExportLine)
            {
                // Unexport folder
                std::string cmd = buildUnexportCommand(folder);
                unexportWhy = describeCommandFailure(std::system(cmd.c_str()));
                if (!unexportWhy.empty())
                {
                    SPDLOG_LOGGER_WARN(
                        Logger::instance(),
                        "'sudo exportfs -u {}' failed ({}). The export may still be live.",
                        folder,
                        unexportWhy);
                }

                // Remove from /etc/exports
                std::string sedCmd = buildExportsPurgeCommand(folder, "/etc/exports");
                sedWhy = describeCommandFailure(std::system(sedCmd.c_str()));
                if (!sedWhy.empty())
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "'sudo sed -i' failed to remove {} from /etc/exports ({}). "
                                       "The entry will be re-exported on the next reload.",
                                       folder,
                                       sedWhy);
                }
            }

            // Delete folder
            fs::remove_all(folder);
            // [Co-developed with claude code -- Adam]
            // Reports what happened rather than announcing success unconditionally: the two
            // commands above can both fail -- a detached process that cannot prompt for a sudo
            // password is the documented failure mode on this machine -- and this line used to
            // claim the cleanup had worked either way.
            if (unexportWhy.empty() && sedWhy.empty())
            {
                SPDLOG_INFO("Cleaned and deleted NFS folder: {}", folder);
            }
            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Deleted NFS folder {} but its export configuration was not "
                                   "fully removed.",
                                   folder);
            }
        }
    }
    catch (const fs::filesystem_error& e)
    {
        SPDLOG_ERROR("Failed during cleanup for '{}': {}", folder, e.what());
    }
    return hadExportLine;
}

void ApplicationManager::cleanupStaleEntries()
{
    SPDLOG_INFO("Checking for stale NFS entries in {}", m_nfsExportDir);
    if (!fs::exists(m_nfsExportDir)) {
        return; // Nothing to clean if the base directory doesn't exist
    }

    // This regex will match directory names that are composed only of digits
    const std::regex number_pattern("^[0-9]+$");

    bool anyExportWork = false;
    for (const auto& entry : fs::directory_iterator(m_nfsExportDir))
    {
        if (entry.is_directory())
        {
            std::string filename = entry.path().filename().string();
            if (std::regex_match(filename, number_pattern))
            {
                SPDLOG_WARN("Found stale application folder from a previous run: {}", entry.path().string());
                anyExportWork |= cleanupAppFolder(entry.path().string());
            }
        }
    }

    // Reload only when a stale folder actually had export configuration removed; a start with
    // nothing to clean stays silent. [Co-developed with claude code -- Adam]
    if (anyExportWork)
    {
        if (const auto why = describeCommandFailure(std::system("sudo exportfs -ra")); !why.empty())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "'sudo exportfs -ra' failed while clearing stale entries ({}). Stale "
                               "exports from a previous run may still be live.",
                               why);
        }
    }
}