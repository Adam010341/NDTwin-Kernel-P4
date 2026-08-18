#pragma once

#include "common_types/AppTypes.hpp"
#include <filesystem>
#include <mutex>
#include <system_error> // std::error_code, in isSquashedClientContentFailure's signature
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

  protected:
    /**
     * @brief The exact line updateNFSConfig appends to the exports file for one app directory.
     *
     * [Co-developed with claude code -- Adam]
     * One definition shared by the writer (updateNFSConfig) and the eraser
     * (buildExportsPurgeCommand), so the two cannot drift: a purge pattern that stops matching
     * what the writer writes leaves dead exports accumulating with nothing failing.
     */
    static std::string exportsLineFor(const std::string& appDir);

    /**
     * @brief `sudo exportfs -u <folder>`, extracted for the reason set out at
     * DeviceConfigurationAndPowerManager::buildRelayPowerCommand: the method around it needs
     * root and a live NFS server, so the only assertable thing is the command itself.
     * Quoting of `folder` is deliberately unchanged from the inline original -- shell quoting
     * across every southbound command is the deferred debt tracked in issue #2, and fixing one
     * call site here would misrepresent the rest as safe.
     */
    static std::string buildUnexportCommand(const std::string& folder);

    /**
     * @brief The sed invocation that removes exactly one app directory's line from an exports
     * file -- and nothing else's.
     *
     * [Co-developed with claude code -- Adam]
     * The inline original escaped only '/' and anchored nothing, so its address was a
     * substring match: purging /srv/nfs/1 also deleted the lines for /srv/nfs/10, 11 and 100
     * (every registered app whose id extends the purged one), and a '.' in the configured
     * export root matched any character. The address is now anchored to the start of the line
     * and to the space that separates the directory from its options in exportsLineFor, with
     * BRE metacharacters escaped. `exportsFile` is a parameter so the sed semantics are
     * testable against a temp file; production passes /etc/exports.
     */
    static std::string buildExportsPurgeCommand(const std::string& folder,
                                                const std::string& exportsFile);

    /**
     * @brief Make one app directory writable through an all_squash NFS export: chmod 0777.
     *
     * [Co-developed with claude code -- Adam]
     * Replaces chownRecursive(appDir, "nobody", "nogroup"), which required root and made
     * non-root kernels fail here on every registration (live 2026-08-15: the Energy app's
     * squashed-to-nobody writes were then denied on the 775 adam-owned directory, its first
     * simulation case never got written, and its decision loop wedged permanently). chmod by
     * the owner needs no privilege and reaches the same goal under BOTH deployments: squashed
     * anonymous clients can write the workspace. The directory is freshly created and empty,
     * so nothing recursive is needed.
     */
    static bool openUpAppDirPermissions(const fs::path& appDir);

    /**
     * @brief Does this exports file carry a line for exactly this folder?
     *
     * [Co-developed with claude code -- Adam]
     * The cleanup path used to run `sudo exportfs -u` + `sudo sed -i` unconditionally and then
     * warn when they failed -- which they always do for a non-root kernel, three misleading
     * warnings per start, for lines that were never written (the non-root register path cannot
     * append to /etc/exports in the first place). Checking first makes cleanup silent when
     * there is nothing to clean. Matching mirrors buildExportsPurgeCommand's anchor: the line
     * must START with `folder + ' '`, so /srv/nfs/sim/1 does not claim /srv/nfs/sim/10's line.
     * An unreadable exports file returns true: when we cannot know, fall back to attempting
     * the old cleanup rather than silently skipping it.
     */
    static bool exportsFileHasEntry(const std::string& folder, const std::string& exportsFile);

    /**
     * @brief Is this remove_all failure the expected one -- a squashed client owning the contents?
     *
     * [Co-developed with claude code -- Adam]
     *
     * @details The export is `all_squash`, so everything an application writes into its workspace
     * is owned by nobody:nogroup, and `remove_all` needs write permission on the *parent* of each
     * entry it deletes. openUpAppDirPermissions opens up the top level only -- it replaced a
     * `chownRecursive` that needed root -- so the client's own subdirectories are not ours to
     * delete and will not become so. Observed on this machine 2026-08-18:
     * `cannot remove all: Permission denied [/srv/nfs/sim/1]
     * [/srv/nfs/sim/1/energy_saving_simulator/1.0/case4/input]`.
     *
     * That is a real consequence -- the folder survives and the next registration reuses it, see
     * setupNFSForApp -- but nothing is broken, so it must not be filed at ERROR alongside failures
     * that are. Extracted as a decision rather than written inline because the alternative is a
     * test that has to create a directory it cannot delete, which needs root to set up.
     *
     * @param ec         The failure's error code.
     * @param folder     The app folder cleanup was asked to remove.
     * @param offending  The path the failure names as blocking it (filesystem_error::path2).
     * @return true only for permission-denied on something strictly *below* @p folder.
     */
    static bool isSquashedClientContentFailure(const std::error_code& ec,
                                               const std::filesystem::path& folder,
                                               const std::filesystem::path& offending);

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
    // Returns whether the folder had an export line to clean (callers reload NFS only if any
    // folder did -- a start with nothing to clean stays silent). [Co-developed with claude code -- Adam]
    bool cleanupAppFolder(const std::string& folderPath);
    void cleanupStaleEntries();
    
};
