// [Co-developed with claude code -- Adam]
// FINDINGS #47. See include/utils/FdHygiene.hpp for what this exists to prevent.

#include "utils/FdHygiene.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <string_view>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace utils
{
namespace
{

/// "0A" / "18C7" -> 10 / 6343. Returns false on anything that is not hex.
bool
parseHex(std::string_view text, unsigned long& out)
{
    if (text.empty())
    {
        return false;
    }
    unsigned long value = 0;
    const auto* first = text.data();
    const auto* last = first + text.size();
    const auto result = std::from_chars(first, last, value, 16);
    if (result.ec != std::errc() || result.ptr != last)
    {
        return false;
    }
    out = value;
    return true;
}

/// Splits on runs of spaces. /proc/net/* is column-aligned, so empty fields never occur.
std::vector<std::string_view>
fields(std::string_view line)
{
    std::vector<std::string_view> out;
    size_t i = 0;
    while (i < line.size())
    {
        while (i < line.size() && line[i] == ' ')
        {
            ++i;
        }
        const size_t start = i;
        while (i < line.size() && line[i] != ' ')
        {
            ++i;
        }
        if (i > start)
        {
            out.push_back(line.substr(start, i - start));
        }
    }
    return out;
}

/**
 * @brief Collects the inodes and uid of every /proc/net/<file> row whose local port is @p port.
 *
 * Column layout is the same for tcp, tcp6, udp and udp6:
 *   0 sl  1 local_address  2 rem_address  3 st  4 tx:rx  5 tr:when  6 retrnsmt  7 uid
 *   8 timeout  9 inode
 * local_address is "<hex address>:<hex port>"; the address half is 8 hex digits for v4 and 32
 * for v6, which is why only the half after the colon is parsed here.
 */
void
scanProcNet(const char* file, std::uint16_t port, PortOwnership& out, std::vector<ino_t>& inodes)
{
    std::ifstream in(file);
    if (!in)
    {
        return;
    }
    std::string line;
    std::getline(in, line); // header
    while (std::getline(in, line))
    {
        const auto f = fields(line);
        if (f.size() < 10)
        {
            continue;
        }
        const auto colon = f[1].rfind(':');
        if (colon == std::string_view::npos)
        {
            continue;
        }
        unsigned long localPort = 0;
        if (!parseHex(f[1].substr(colon + 1), localPort) || localPort != port)
        {
            continue;
        }
        out.socketFound = true;

        unsigned long uid = 0;
        const auto uidText = f[7];
        if (std::from_chars(uidText.data(), uidText.data() + uidText.size(), uid).ec == std::errc())
        {
            out.uid = static_cast<long>(uid);
        }
        unsigned long inode = 0;
        const auto inodeText = f[9];
        if (std::from_chars(inodeText.data(), inodeText.data() + inodeText.size(), inode).ec ==
            std::errc())
        {
            inodes.push_back(static_cast<ino_t>(inode));
        }
    }
}

/// /proc/<pid>/comm, trimmed of its newline. Empty when unreadable.
std::string
readComm(const std::string& pidDir)
{
    std::ifstream in(pidDir + "/comm");
    std::string comm;
    if (in && std::getline(in, comm))
    {
        return comm;
    }
    return {};
}

/// True when @p pid has any of @p inodes open. Unreadable /proc/<pid>/fd is "cannot tell", i.e.
/// false -- an answer this scan deliberately reports as "no attributable holder" rather than
/// guessing.
bool
processHoldsAnyInode(const std::string& pidDir, const std::vector<ino_t>& inodes)
{
    const std::string fdDir = pidDir + "/fd";
    DIR* dir = ::opendir(fdDir.c_str());
    if (dir == nullptr)
    {
        return false;
    }
    bool found = false;
    while (const dirent* entry = ::readdir(dir))
    {
        if (entry->d_name[0] == '.')
        {
            continue;
        }
        struct stat st{};
        // stat() through the symlink: the target of a socket fd is "socket:[<inode>]", and
        // stat'ing it yields the socket's inode without any string parsing.
        if (::fstatat(::dirfd(dir), entry->d_name, &st, 0) != 0)
        {
            continue;
        }
        if (!S_ISSOCK(st.st_mode))
        {
            continue;
        }
        if (std::find(inodes.begin(), inodes.end(), st.st_ino) != inodes.end())
        {
            found = true;
            break;
        }
    }
    ::closedir(dir);
    return found;
}

bool
allDigits(const char* s)
{
    if (*s == '\0')
    {
        return false;
    }
    for (const char* p = s; *p != '\0'; ++p)
    {
        if (*p < '0' || *p > '9')
        {
            return false;
        }
    }
    return true;
}

std::string
protocolName(PortProtocol proto)
{
    return proto == PortProtocol::Tcp ? "TCP" : "UDP";
}

} // namespace

bool
setCloseOnExec(int fd) noexcept
{
    if (fd < 0)
    {
        return false;
    }
    const int flags = ::fcntl(fd, F_GETFD);
    if (flags < 0)
    {
        return false;
    }
    if ((flags & FD_CLOEXEC) != 0)
    {
        return true;
    }
    return ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

bool
isCloseOnExec(int fd) noexcept
{
    if (fd < 0)
    {
        return false;
    }
    const int flags = ::fcntl(fd, F_GETFD);
    return flags >= 0 && (flags & FD_CLOEXEC) != 0;
}

int
cloexecSocket(int domain, int type, int protocol) noexcept
{
    return ::socket(domain, type | SOCK_CLOEXEC, protocol);
}

PortOwnership
findPortOwnership(std::uint16_t port, PortProtocol proto)
{
    PortOwnership out;
    std::vector<ino_t> inodes;

    if (proto == PortProtocol::Tcp)
    {
        scanProcNet("/proc/net/tcp", port, out, inodes);
        scanProcNet("/proc/net/tcp6", port, out, inodes);
    }
    else
    {
        scanProcNet("/proc/net/udp", port, out, inodes);
        scanProcNet("/proc/net/udp6", port, out, inodes);
    }

    if (inodes.empty())
    {
        return out;
    }

    DIR* procDir = ::opendir("/proc");
    if (procDir == nullptr)
    {
        return out;
    }
    while (const dirent* entry = ::readdir(procDir))
    {
        if (!allDigits(entry->d_name))
        {
            continue;
        }
        const std::string pidDir = std::string("/proc/") + entry->d_name;
        if (!processHoldsAnyInode(pidDir, inodes))
        {
            continue;
        }
        PortHolder holder;
        holder.pid = std::atoi(entry->d_name);
        holder.comm = readComm(pidDir);
        out.holders.push_back(holder);
    }
    ::closedir(procDir);

    std::sort(out.holders.begin(),
              out.holders.end(),
              [](const PortHolder& a, const PortHolder& b) { return a.pid < b.pid; });
    return out;
}

std::string
describePortOwnership(std::uint16_t port,
                      PortProtocol proto,
                      const PortOwnership& ownership,
                      const std::string& selfProgramName)
{
    std::ostringstream out;
    const std::string proto_name = protocolName(proto);

    // 1. Nothing is bound. The bind failed for a reason this scan cannot see -- or the holder let
    //    go between the two calls. Either way, naming a culprit here would be inventing one.
    if (!ownership.socketFound)
    {
        out << "No socket is bound to " << proto_name << " port " << port
            << " in /proc right now, so the cause is not visible here: either it was released "
               "between the failed bind and this check, or the address was refused for some other "
               "reason.";
        return out.str();
    }

    // 2. Bound, but nothing this user can see holds it. Says so, rather than guessing.
    if (ownership.holders.empty())
    {
        out << proto_name << " port " << port << " is held by a socket";
        if (ownership.uid >= 0)
        {
            out << " owned by uid " << ownership.uid;
        }
        out << ", but no process readable by this user has it open. It may belong to another "
               "user, or to a process that exited between the failed bind and this check. This is "
               "NOT evidence that another "
            << selfProgramName << " is running.";
        return out.str();
    }

    // 3./4. Named holders. Which of the two sentences gets printed is decided by the evidence.
    const bool selfAmongThem =
        std::any_of(ownership.holders.begin(),
                    ownership.holders.end(),
                    [&](const PortHolder& h) { return h.comm == selfProgramName; });

    out << proto_name << " port " << port << " is held by ";
    for (size_t i = 0; i < ownership.holders.size(); ++i)
    {
        if (i != 0)
        {
            out << ", ";
        }
        out << "pid " << ownership.holders[i].pid << " ("
            << (ownership.holders[i].comm.empty() ? std::string("unknown")
                                                  : ownership.holders[i].comm)
            << ")";
    }
    out << ". ";

    if (selfAmongThem)
    {
        out << "One of them is another " << selfProgramName
            << ": stop it before starting this one.";
    }
    else
    {
        out << "None of them is a " << selfProgramName
            << ", so this is not another kernel to go and stop. A process holding a socket it "
               "never opened inherited it across an exec -- typically a child this or a previous "
               "kernel spawned. Killing the listed pids, or waiting for them to exit, frees the "
               "port.";
    }
    return out.str();
}

std::string
diagnosePortInUse(std::uint16_t port, PortProtocol proto, const std::string& selfProgramName)
{
    return describePortOwnership(port, proto, findPortOwnership(port, proto), selfProgramName);
}

} // namespace utils
