#include "ndt_core/application_management/ApplicationManager.hpp"
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <grp.h>
#include <iostream>
#include <optional>
#include <pwd.h>
#include <regex>
#include <sys/types.h>
#include <sys/wait.h> // for WIFEXITED/WEXITSTATUS, used to decode std::system()'s wait status
#include <unistd.h>

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

    // Create directory for this application
    if (!fs::create_directories(appDir))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Failed to create directory: {}", appDir);
        return false;
    }
    else
    {
        // Record it so destructor knows what to clean
        m_registeredFolders.push_back(appDir);
    }

    if( !chownRecursive(appDir, "nobody", "nogroup") ) {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Failed to re‑own directory");
        return false;
    }

    if (!updateNFSConfig(appId, appDir))
    {
        return false;
    }

    return reloadNFSServer();
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

    for (const auto& folder : m_registeredFolders)
    {
        cleanupAppFolder(folder); // Call the new reusable method
    }

    // Reload NFS exports to apply all changes
    if (const auto why = describeCommandFailure(std::system("sudo exportfs -ra")); !why.empty())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "'sudo exportfs -ra' failed after cleanup ({}). Stale exports may "
                           "still be live.",
                           why);
    }
}

bool
ApplicationManager::chownRecursive(const fs::path& root,
                                   const std::string& user,
                                   const std::string& group)
{
    // 1. lookup user -> uid
    struct passwd* pw = getpwnam(user.c_str());
    if (!pw)
    {
        // errno saved before the stream write, which can itself set it: the operands of a
        // << chain are sequenced left to right, so strerror(errno) is evaluated after the
        // earlier writes have already run. [Co-developed with claude code -- Adam]
        const int savedErrno = errno;
        std::cerr << "User lookup failed (" << user << "): " << std::strerror(savedErrno) << "\n";
        return false;
    }
    uid_t uid = pw->pw_uid;

    // 2. lookup group -> gid
    struct group* gr = getgrnam(group.c_str());
    if (!gr)
    {
        // errno saved before the stream write, which can itself set it: the operands of a
        // << chain are sequenced left to right, so strerror(errno) is evaluated after the
        // earlier writes have already run. [Co-developed with claude code -- Adam]
        const int savedErrno = errno;
        std::cerr << "Group lookup failed (" << group << "): " << std::strerror(savedErrno) << "\n";
        return false;
    }
    gid_t gid = gr->gr_gid;

    // 3. walk tree and chown()
    std::error_code ec;
    for (auto& entry : fs::recursive_directory_iterator(root, ec))
    {
        if (ec)
        {
            std::cerr << "Directory iteration error: " << ec.message() << "\n";
            return false;
        }
        const auto& p = entry.path();
        if (::chown(p.c_str(), uid, gid) != 0)
        {
            // errno saved before the stream write, which can itself set it: the operands of a
            // << chain are sequenced left to right, so strerror(errno) is evaluated after the
            // earlier writes have already run. [Co-developed with claude code -- Adam]
            const int savedErrno = errno;
            std::cerr << "chown failed for " << p << ": " << std::strerror(savedErrno) << "\n";
            return false;
        }
    }
    // finally, chown the root itself
    if (::chown(root.c_str(), uid, gid) != 0)
    {
        // errno saved before the stream write, which can itself set it: the operands of a
        // << chain are sequenced left to right, so strerror(errno) is evaluated after the
        // earlier writes have already run. [Co-developed with claude code -- Adam]
        const int savedErrno = errno;
        std::cerr << "chown failed for " << root << ": " << std::strerror(savedErrno) << "\n";
        return false;
    }

    return true;
}

// In ApplicationManager.cpp

void ApplicationManager::cleanupAppFolder(const std::string& folder)
{
    try
    {
        if (fs::exists(folder))
        {
            // Unexport folder
            std::string cmd = buildUnexportCommand(folder);
            const auto unexportWhy = describeCommandFailure(std::system(cmd.c_str()));
            if (!unexportWhy.empty())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "'sudo exportfs -u {}' failed ({}). The export is still live.",
                                   folder,
                                   unexportWhy);
            }

            // Remove from /etc/exports
            std::string sedCmd = buildExportsPurgeCommand(folder, "/etc/exports");
            const auto sedWhy = describeCommandFailure(std::system(sedCmd.c_str()));
            if (!sedWhy.empty())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "'sudo sed -i' failed to remove {} from /etc/exports ({}). "
                                   "The entry will be re-exported on the next reload.",
                                   folder,
                                   sedWhy);
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
}

void ApplicationManager::cleanupStaleEntries()
{
    SPDLOG_INFO("Checking for stale NFS entries in {}", m_nfsExportDir);
    if (!fs::exists(m_nfsExportDir)) {
        return; // Nothing to clean if the base directory doesn't exist
    }

    // This regex will match directory names that are composed only of digits
    const std::regex number_pattern("^[0-9]+$");

    for (const auto& entry : fs::directory_iterator(m_nfsExportDir))
    {
        if (entry.is_directory())
        {
            std::string filename = entry.path().filename().string();
            if (std::regex_match(filename, number_pattern))
            {
                SPDLOG_WARN("Found stale application folder from a previous run: {}", entry.path().string());
                cleanupAppFolder(entry.path().string());
            }
        }
    }

    // Reload NFS server to make sure all stale entries are fully removed
    if (const auto why = describeCommandFailure(std::system("sudo exportfs -ra")); !why.empty())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "'sudo exportfs -ra' failed while clearing stale entries ({}). Stale "
                           "exports from a previous run may still be live.",
                           why);
    }
}