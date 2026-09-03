#pragma once

/**
 * @file FdHygiene.hpp
 * @brief Descriptors this process must not hand to the programs it runs, and an honest answer to
 *        "who is holding that port?".
 *
 * [Co-developed with claude code -- Adam]
 *
 * FINDINGS #47. The kernel runs `curl` through popen()/std::system(), which is fork() + exec()
 * of `/bin/sh`. Every descriptor without FD_CLOEXEC survives that exec, so both listening
 * sockets -- TCP :8000 and UDP :6343 -- were inherited by every `sh` and every `curl` the kernel
 * had ever started. Measured 2026-09-03 (round3 step 03): after the kernel's own pid was gone,
 * `ss -ltnp` still listed the port, with `curl` and `sh` as its users, for 2.01-2.22 s in 48 of
 * 48 trials. A restart inside that window failed 6 times out of 6.
 *
 * Two halves, and they are separate defects:
 *
 *  1. THE PORT OUTLIVES THE PROCESS. Fixed at the socket, not at the spawn site: a socket created
 *     with SOCK_CLOEXEC (or marked with FD_CLOEXEC the moment a library hands it to us) cannot be
 *     inherited by anything, however it is spawned -- popen, std::system, fork/execvp, or whatever
 *     the next call site uses. Fixing the spawn sites instead would have needed every one of them
 *     found, and would have to be re-done for the next one somebody adds.
 *
 *  2. THE MESSAGE WAS WRONG. The kernel said "Another NDTwin kernel is almost certainly still
 *     running and holding it". There was no other kernel; the holder was its own orphaned curl.
 *     An operator who believes that message goes looking for a process that does not exist. So
 *     the diagnosis is now read out of /proc -- the holder's pid and comm -- and the sentence is
 *     built from what was actually found. describePortOwnership() names another kernel only when
 *     a process named like this one is genuinely among the holders.
 */

#include <cstdint>
#include <string>
#include <vector>

namespace utils
{

/// Which of /proc/net/{tcp,tcp6} or /proc/net/{udp,udp6} to read.
enum class PortProtocol
{
    Tcp,
    Udp
};

/// One process that has the port's socket open, as attributed through /proc/<pid>/fd.
struct PortHolder
{
    int pid = -1;
    /// /proc/<pid>/comm -- "ndtwin_kernel", "curl", "sh". Empty when it could not be read.
    std::string comm;
};

/**
 * @brief What /proc says about a local port.
 *
 * @note The three fields answer three different questions and must not be collapsed.
 *       @c socketFound says a socket is bound at all; @c holders says which processes this user
 *       can see holding it (an empty list with socketFound true is the "somebody else's, or
 *       already gone" case, not "nobody"); @c uid says who owns the socket even when no pid could
 *       be attributed.
 */
struct PortOwnership
{
    /// True when /proc/net/* has an entry for this local port.
    bool socketFound = false;
    /// Owner uid from /proc/net/*, or -1 when unknown.
    long uid = -1;
    /// Processes whose /proc/<pid>/fd could be read and matched the socket's inode.
    std::vector<PortHolder> holders;
};

/**
 * @brief Marks an existing descriptor close-on-exec.
 *
 * For descriptors this process did not create itself -- a Boost.Asio acceptor's native handle,
 * an accepted connection -- where SOCK_CLOEXEC was not ours to pass.
 *
 * @return true when the descriptor is close-on-exec afterwards.
 * @note Read-modify-write on the flags, so an FD_ flag added by something else is preserved.
 */
bool setCloseOnExec(int fd) noexcept;

/// @return true when @p fd carries FD_CLOEXEC. False for an invalid descriptor.
bool isCloseOnExec(int fd) noexcept;

/**
 * @brief ::socket() with SOCK_CLOEXEC folded into @p type.
 *
 * One call, not socket()+fcntl(): between those two a concurrent fork/exec on another thread
 * inherits the descriptor anyway, and this kernel forks from its poll threads.
 */
int cloexecSocket(int domain, int type, int protocol) noexcept;

/**
 * @brief Reads /proc to find out who holds @p port. Best effort, never throws.
 *
 * @note Only processes this user can read are attributable: /proc/<pid>/fd of another user's
 *       process is not readable, and the scan then reports socketFound with an empty holder list.
 *       That distinction is the whole point -- see describePortOwnership().
 */
PortOwnership findPortOwnership(std::uint16_t port, PortProtocol proto);

/**
 * @brief Renders @p ownership as a sentence an operator can act on. Pure; no I/O.
 *
 * @param selfProgramName What this program's own /proc/<pid>/comm looks like, e.g.
 *        "ndtwin_kernel". A holder is called "another kernel" only if it is named this.
 *
 * @warning The one thing this must never do is what the old hard-coded message did: assert that
 *          another kernel is running when the evidence does not say so.
 */
std::string describePortOwnership(std::uint16_t port,
                                  PortProtocol proto,
                                  const PortOwnership& ownership,
                                  const std::string& selfProgramName);

/// Convenience: findPortOwnership() then describePortOwnership().
std::string diagnosePortInUse(std::uint16_t port,
                              PortProtocol proto,
                              const std::string& selfProgramName);

} // namespace utils
