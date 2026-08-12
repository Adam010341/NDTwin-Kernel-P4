#pragma once

#include "common_types/AppTypes.hpp"
#include <filesystem>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;


/**
 * @brief Manages per-application registration and NFS-backed workspace setup.
 *
 * ApplicationManager assigns a unique application ID to each registered client,
 * maintains metadata such as the simulation-completed callback URL, and
 * provisions an isolated per-app directory under the configured NFS export
 * directory (e.g., /srv/nfs/sim/<appId>/).
 *
 * It updates NFS server configuration to export/mount the per-app directory,
 * reloads the NFS server when required, and performs cleanup of application
 * folders and stale NFS entries. All public APIs are thread-safe via an
 * internal mutex.
 *
 * Typical usage:
 *  - registerApplication() to obtain an appId and store the callback URL
 *  - setupNFSForApp(appId) to create/export/mount the app workspace
 *  - getSimulationCompletedUrl(appId) to retrieve the callback URL later
 */
class ApplicationManager
{
  public:
    ApplicationManager(const std::string& nfsExportDir,
                       const std::string& nfsMountPoint); // nfsExportDir -> /srv/nfs/sim
    ~ApplicationManager();

    // Register a new application and get its App ID
    int registerApplication(const std::string& appName, const std::string& simulationCompletedUrl);

    // Set up NFS configuration for the application
    bool setupNFSForApp(int appId);

    std::optional<std::string> getSimulationCompletedUrl(int appId) const;

    /**
     * @brief What std::system()'s return value actually means.
     *
     * @param status The value std::system() returned.
     * @return Empty when the command ran and exited 0; otherwise a human-readable reason.
     *
     * [Co-developed with claude code -- Adam]
     * A pure function, extracted rather than inlined, for the reason set out in
     * DeviceConfigurationAndPowerManager.hpp for interpretRelayResponse and ovsLivenessFor: the
     * decision is the thing worth asserting, and it cannot be asserted through a call site that
     * shells out to sudo.
     *
     * Four call sites in this file discarded this value entirely -- two `sudo exportfs -ra`, one
     * `sudo exportfs -u <folder>` and one `sudo sed -i '/<folder>/d' /etc/exports` -- while
     * reloadNFSServer directly above them checked and warned. A failed sudo (the documented
     * failure mode on this machine for a detached process that cannot prompt) therefore left
     * stale exports live and /etc/exports unedited while the log said cleanup had succeeded, and
     * cleanupStaleEntries runs from the constructor at every kernel start in both modes.
     *
     * `status` is not an exit code. -1 means the child could not be created at all, 127 means the
     * shell could not execute the command, and otherwise it is a wait status that has to be
     * decoded -- so `!= 0` is right by accident rather than by construction, and says nothing
     * useful in a log.
     */
    static std::string describeCommandFailure(int status);

  private:
    std::mutex m_mutex;
    int m_nextAppId;
    std::unordered_map<int, RegisteredApp> m_registeredApps;

    std::string m_nfsExportDir;
    std::string m_nfsMountPoint;

    std::vector<std::string> m_registeredFolders;

    bool updateNFSConfig(int appId, const std::string& appDir);
    bool reloadNFSServer();
    void cleanupNFS();
    bool chownRecursive(const fs::path& root, const std::string& user, const std::string& group);
    void cleanupAppFolder(const std::string& folderPath);
    void cleanupStaleEntries();
    
};
