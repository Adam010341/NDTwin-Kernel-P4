/**
 * @file test_CloseOnExecSockets.cpp
 * @brief FINDINGS #47: the listening sockets this kernel hands to the shells it forks.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 * The kernel runs `curl` through popen(), which is fork() + exec("/bin/sh"). Both of its
 * listening sockets were created without SOCK_CLOEXEC -- the sFlow UDP socket by a bare
 * ::socket(), the API acceptor by Boost.Asio, which also uses a bare ::socket() and a bare
 * ::accept(). Every `sh` and every `curl` therefore inherited them. Measured 2026-09-03
 * (doc/audit/2026-09-03_night-rounds/round3-restart-concurrency, step 03): with the kernel's own
 * pid gone, `ss -ltnp` still showed :8000 LISTEN with `curl` and `sh` as its users, for
 * 2.01-2.22 s in 48 of 48 trials, and 6 of 6 restarts inside that window failed. The message the
 * failed restart printed said another NDTwin kernel was almost certainly running. There was none.
 *
 * WHAT THESE TESTS ASSERT, AND WHY EACH ONE IS HERE
 *   1. The two production socket-opening functions return a close-on-exec descriptor. Not a copy
 *      of them: FlowLinkUsageCollector::openSflowSocket and
 *      ControllerAndOtherEventHandler::openApiAcceptor are the functions the kernel itself calls,
 *      parameterised by port so a test can use an ephemeral one.
 *   2. A REAL CHILD PROCESS cannot see them. FD_CLOEXEC is the mechanism; "the child does not
 *      have the socket" is the property, and only the second one is what the finding is about.
 *   3. 🔴 THE POSITIVE CONTROL. Every "the child cannot see it" assertion is paired with an
 *      identical probe against a socket deliberately created WITHOUT CLOEXEC, which the child
 *      MUST see. Without that pair the probe could be looking in the wrong place, or at nothing,
 *      and would pass for a reason that has nothing to do with the fix.
 *   4. The wiring, not just the parts. A handler that is actually start()ed must end up with a
 *      close-on-exec acceptor -- this repository's most-repeated defect is a correct function
 *      with no caller, and "openApiAcceptor does the right thing" says nothing about whether
 *      start() calls it.
 *   5. The message. The old sentence was a claim made without looking. These cases drive the
 *      renderer over the four states /proc can actually be in, including the two where saying
 *      "another kernel is running" would be false.
 *
 * 🔴 NOTHING HERE BINDS A FIXED PORT. Every socket is bound to port 0. A test that needed :6343
 * or :8000 would fail whenever a kernel was running on this machine, and a test that cannot run
 * is not evidence.
 */

#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/event_handling/ControllerAndOtherEventHandler.hpp"
#include "utils/FdHygiene.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <gtest/gtest.h>
#include <spdlog/sinks/ringbuffer_sink.h>

#include <array>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

extern char** environ;

namespace
{

/// Closes a descriptor however the test leaves scope, including on a failed assertion.
class Fd
{
  public:
    explicit Fd(int fd) : m_fd(fd) {}
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    ~Fd()
    {
        if (m_fd >= 0)
        {
            ::close(m_fd);
        }
    }
    int get() const { return m_fd; }

  private:
    int m_fd;
};

/// The inode a socket descriptor names. This is the identity a child's /proc/self/fd shows.
ino_t
inodeOf(int fd)
{
    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        return 0;
    }
    return st.st_ino;
}

/**
 * @brief Runs `ls -l /proc/self/fd` in a real child through posix_spawn and returns its stdout.
 *
 * posix_spawn rather than fork/exec so that the probe does not share this fix's own code path:
 * if execArgv's descriptor handling were broken, a probe built on execArgv would hide it.
 */
std::string
listChildDescriptors()
{
    int fds[2];
    if (::pipe(fds) != 0)
    {
        return "<pipe failed>";
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    char arg0[] = "sh";
    char arg1[] = "-c";
    char arg2[] = "ls -l /proc/self/fd";
    char* argv[] = {arg0, arg1, arg2, nullptr};
    pid_t pid = -1;
    const int rc = ::posix_spawnp(&pid, "sh", &actions, nullptr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    ::close(fds[1]);
    if (rc != 0)
    {
        ::close(fds[0]);
        return std::string("<posix_spawnp failed: ") + std::strerror(rc) + ">";
    }

    std::string out;
    std::array<char, 512> buffer{};
    for (;;)
    {
        const ssize_t n = ::read(fds[0], buffer.data(), buffer.size());
        if (n > 0)
        {
            out.append(buffer.data(), static_cast<size_t>(n));
            continue;
        }
        if (n < 0 && errno == EINTR)
        {
            continue;
        }
        break;
    }
    ::close(fds[0]);
    int status = 0;
    ::waitpid(pid, &status, 0);
    return out;
}

/// The text a socket's inode takes in `ls -l /proc/<pid>/fd`.
std::string
socketToken(int fd)
{
    return "socket:[" + std::to_string(static_cast<unsigned long long>(inodeOf(fd))) + "]";
}

/// A UDP socket created the way the kernel used to create them: inheritable. The control.
int
inheritableUdpSocket()
{
    const int fd = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0)
    {
        return -1;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
    {
        ::close(fd);
        return -1;
    }
    return fd;
}

/**
 * @brief Which of this process's own descriptors is a TCP socket whose local port is @p port.
 *
 * The wiring tests can see the handler's port but not its private acceptor, so they find the
 * descriptor the same way an operator would: through /proc.
 *
 * @param connected false selects the listening socket (no peer), true the accepted connection
 *        (has one). Both have the same local port, which is why this distinction is needed.
 */
int
findOwnTcpFd(unsigned short port, bool connected)
{
    DIR* dir = ::opendir("/proc/self/fd");
    if (dir == nullptr)
    {
        return -1;
    }
    int found = -1;
    while (const dirent* entry = ::readdir(dir))
    {
        if (entry->d_name[0] == '.')
        {
            continue;
        }
        const int fd = std::atoi(entry->d_name);
        sockaddr_in addr{};
        socklen_t len = sizeof(addr);
        if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0)
        {
            continue;
        }
        if (addr.sin_family != AF_INET || ntohs(addr.sin_port) != port)
        {
            continue;
        }
        int type = 0;
        socklen_t typeLen = sizeof(type);
        if (::getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLen) != 0 || type != SOCK_STREAM)
        {
            continue;
        }
        sockaddr_in peer{};
        socklen_t peerLen = sizeof(peer);
        const bool hasPeer = ::getpeername(fd, reinterpret_cast<sockaddr*>(&peer), &peerLen) == 0;
        if (hasPeer == connected)
        {
            found = fd;
            break;
        }
    }
    ::closedir(dir);
    return found;
}

/// Waits up to ~2 s for the accept to land on an io_context thread. Returns -1 on timeout.
int
awaitOwnAcceptedFd(unsigned short port)
{
    for (int attempt = 0; attempt < 200; ++attempt)
    {
        const int fd = findOwnTcpFd(port, /*connected=*/true);
        if (fd >= 0)
        {
            return fd;
        }
        ::usleep(10 * 1000);
    }
    return -1;
}

/// Captures what the kernel logged, so a message can be asserted on rather than eyeballed.
/// Named for this file: two other suites define their own LogCapture.
class CloexecLogCapture
{
  public:
    CloexecLogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~CloexecLogCapture()
    {
        m_logger->set_level(m_savedLevel);
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
    }

    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

utils::PortHolder holder(int pid, std::string comm)
{
    utils::PortHolder h;
    h.pid = pid;
    h.comm = std::move(comm);
    return h;
}

} // namespace

// =================================================================================================
// 1. the sFlow receive socket -- the UDP half of the finding
// =================================================================================================

TEST(CloseOnExecSocketsTest, TheSflowReceiveSocketIsCloseOnExec)
{
    const Fd sock(sflow::FlowLinkUsageCollector::openSflowSocket(0));
    ASSERT_GE(sock.get(), 0) << "openSflowSocket(0) did not return a descriptor";

    const int flags = ::fcntl(sock.get(), F_GETFD);
    ASSERT_GE(flags, 0) << "F_GETFD failed: " << std::strerror(errno);
    EXPECT_TRUE((flags & FD_CLOEXEC) != 0)
        << "the sFlow socket survives an exec, so every sh and curl this kernel forks inherits "
           "it and holds UDP 6343 after the kernel is gone";
}

/// The property, not the flag. A child spawned while the socket is open must not have it.
TEST(CloseOnExecSocketsTest, AChildCannotSeeTheSflowReceiveSocket)
{
    const Fd sock(sflow::FlowLinkUsageCollector::openSflowSocket(0));
    ASSERT_GE(sock.get(), 0);
    const std::string token = socketToken(sock.get());

    const std::string childFds = listChildDescriptors();
    ASSERT_FALSE(childFds.empty()) << "the probe child produced no output, so it proves nothing";

    EXPECT_EQ(childFds.find(token), std::string::npos)
        << "a child process inherited the sFlow socket (" << token << ").\nchild fds:\n"
        << childFds;
}

/**
 * 🔴 THE CONTROL FOR THE TEST ABOVE. An identical socket, created the old way, MUST be visible to
 * the child. If this ever goes green-by-absence, the probe is looking at nothing and the case
 * above is worth nothing either.
 */
TEST(CloseOnExecSocketsTest, TheProbeSeesASocketThatWasNotMarked)
{
    const Fd sock(inheritableUdpSocket());
    ASSERT_GE(sock.get(), 0) << "could not create the control socket";
    const std::string token = socketToken(sock.get());

    const std::string childFds = listChildDescriptors();
    EXPECT_NE(childFds.find(token), std::string::npos)
        << "the probe could not see a deliberately inheritable socket (" << token
        << "), so it cannot see an inherited one either.\nchild fds:\n"
        << childFds;
}

// =================================================================================================
// 2. the API acceptor -- the TCP half
// =================================================================================================

TEST(CloseOnExecSocketsTest, TheApiAcceptorIsCloseOnExec)
{
    boost::asio::io_context ioc;
    auto acceptor = ControllerAndOtherEventHandler::openApiAcceptor(ioc, 0);
    ASSERT_TRUE(acceptor != nullptr);
    ASSERT_TRUE(acceptor->is_open());

    EXPECT_TRUE(utils::isCloseOnExec(acceptor->native_handle()))
        << "Boost.Asio creates acceptors with a bare ::socket(); nothing marked this one, so "
           "every child this kernel forks inherits TCP 8000";
}

TEST(CloseOnExecSocketsTest, AChildCannotSeeTheApiAcceptor)
{
    boost::asio::io_context ioc;
    auto acceptor = ControllerAndOtherEventHandler::openApiAcceptor(ioc, 0);
    ASSERT_TRUE(acceptor != nullptr);
    const std::string token = socketToken(acceptor->native_handle());

    const std::string childFds = listChildDescriptors();
    ASSERT_FALSE(childFds.empty());
    EXPECT_EQ(childFds.find(token), std::string::npos)
        << "a child process inherited the API listening socket (" << token << ").\nchild fds:\n"
        << childFds;
}

/// Accepted connections, not just the acceptor. Handlers on this server shell out while the
/// connection is open, so an inherited connection is a request that never completes.
TEST(CloseOnExecSocketsTest, AnAcceptedConnectionIsMarkedCloseOnExec)
{
    boost::asio::io_context ioc;
    auto acceptor = ControllerAndOtherEventHandler::openApiAcceptor(ioc, 0);
    ASSERT_TRUE(acceptor != nullptr);

    boost::asio::ip::tcp::socket client(ioc);
    boost::system::error_code ec;
    client.connect(acceptor->local_endpoint(), ec);
    ASSERT_FALSE(ec) << "loopback connect failed: " << ec.message();

    boost::asio::ip::tcp::socket accepted(ioc);
    acceptor->accept(accepted, ec);
    ASSERT_FALSE(ec) << "accept failed: " << ec.message();

    // Asio accepts with ::accept(), so this is inheritable until the handler says otherwise.
    // Asserting that first is what makes the assertion after it mean something.
    ASSERT_FALSE(utils::isCloseOnExec(accepted.native_handle()))
        << "this Boost.Asio build already marks accepted sockets; the case below would pass "
           "without adoptAcceptedSocket() doing anything";

    ControllerAndOtherEventHandler::adoptAcceptedSocket(accepted);
    EXPECT_TRUE(utils::isCloseOnExec(accepted.native_handle()))
        << "an accepted connection is still inheritable, so a curl started inside a request "
           "handler holds the client's connection open for as long as it runs";
}

// =================================================================================================
// 3. the wiring -- a handler that was actually started
// =================================================================================================

/**
 * A correct openApiAcceptor() with a start() that does not call it would leave the defect exactly
 * where it was, and every case above would still be green. This one starts a real server on an
 * ephemeral port and asks a real child what it can see.
 */
TEST(CloseOnExecSocketsTest, AStartedServerHasACloseOnExecAcceptor)
{
    boost::asio::io_context ioc;
    ControllerAndOtherEventHandler handler(ioc,
                                           nullptr, // topologyAndFlowMonitor
                                           nullptr, // collector
                                           nullptr, // flowRoutingManager
                                           nullptr, // deviceConfigurationAndPowerManager
                                           nullptr, // eventBus
                                           nullptr, // applicationManager
                                           nullptr, // simManager
                                           nullptr, // intentTranslator
                                           nullptr, // historicalDataManager
                                           nullptr, // controller
                                           nullptr, // lockManager
                                           utils::MININET,
                                           "");

    handler.start(0);
    const unsigned short port = handler.boundPort();
    ASSERT_NE(port, 0) << "start(0) did not report the port it bound";

    const int acceptorFd = findOwnTcpFd(port, /*connected=*/false);
    ASSERT_GE(acceptorFd, 0) << "could not find this process's own listening socket on " << port;
    const std::string token = socketToken(acceptorFd);

    EXPECT_TRUE(utils::isCloseOnExec(acceptorFd))
        << "start() produced an inheritable listening socket: whatever openApiAcceptor() does, "
           "the running server is not getting it";

    const std::string childFds = listChildDescriptors();
    EXPECT_EQ(childFds.find(token), std::string::npos)
        << "a child spawned while the server was running inherited its listening socket ("
        << token << ").\nchild fds:\n"
        << childFds;

    handler.stop();
}

/**
 * The other wiring: doAccept() must mark what it accepted. Same shape of hole -- a correct
 * adoptAcceptedSocket() that the accept path never calls -- and it matters because the handlers
 * this server dispatches to fork a shell while the connection is open.
 *
 * The client connects and sends nothing, so the session stays in async_read and never reaches a
 * handler; with null managers, reaching one would be a crash rather than a test.
 */
TEST(CloseOnExecSocketsTest, AConnectionAcceptedByTheRunningServerIsCloseOnExec)
{
    boost::asio::io_context ioc;
    ControllerAndOtherEventHandler handler(ioc,
                                           nullptr, // topologyAndFlowMonitor
                                           nullptr, // collector
                                           nullptr, // flowRoutingManager
                                           nullptr, // deviceConfigurationAndPowerManager
                                           nullptr, // eventBus
                                           nullptr, // applicationManager
                                           nullptr, // simManager
                                           nullptr, // intentTranslator
                                           nullptr, // historicalDataManager
                                           nullptr, // controller
                                           nullptr, // lockManager
                                           utils::MININET,
                                           "");

    handler.start(0);
    const unsigned short port = handler.boundPort();
    ASSERT_NE(port, 0);

    boost::asio::io_context clientIoc;
    boost::asio::ip::tcp::socket client(clientIoc);
    boost::system::error_code ec;
    client.connect({boost::asio::ip::make_address("127.0.0.1"), port}, ec);
    ASSERT_FALSE(ec) << "loopback connect to the started server failed: " << ec.message();

    const int acceptedFd = awaitOwnAcceptedFd(port);
    ASSERT_GE(acceptedFd, 0) << "the server never accepted the connection";

    // 🔴 POLL, DO NOT SAMPLE. The descriptor exists the moment ::accept() returns inside Asio's
    // reactor, which is strictly BEFORE the completion handler that adopts it gets to run. A
    // single read here is a race: on a loaded machine this case went red against a mutation that
    // was only a comment (mutate_cloexec_listening_sockets.sh W1, 2026-09-03), which is a flaky
    // test reporting itself as a defect. Waiting up to 2 s costs nothing when the adoption
    // happens -- and a mutation that removes it still goes red, 2 s later.
    bool marked = false;
    for (int attempt = 0; attempt < 200 && !marked; ++attempt)
    {
        marked = utils::isCloseOnExec(acceptedFd);
        if (!marked)
        {
            ::usleep(10 * 1000);
        }
    }
    EXPECT_TRUE(marked)
        << "the accept path handed the session an inheritable connection: a curl started inside "
           "a request handler holds this client's connection open for as long as it runs";

    client.close(ec);
    handler.stop();
}

// =================================================================================================
// 4. the fork/exec executor -- defence in depth, and the line that must not be widened
// =================================================================================================

TEST(CloseOnExecSocketsTest, ExecArgvChildDoesNotInheritAnUnmarkedDescriptor)
{
    const Fd sock(inheritableUdpSocket());
    ASSERT_GE(sock.get(), 0);
    const std::string token = socketToken(sock.get());

    const utils::CommandOutcome outcome = utils::execArgv({"sh", "-c", "ls -l /proc/self/fd"});
    ASSERT_TRUE(outcome.ran) << "execArgv could not run the probe";
    EXPECT_EQ(outcome.output.find(token), std::string::npos)
        << "execArgv handed the child a descriptor nobody marked (" << token
        << ").\nchild fds:\n"
        << outcome.output;
}

/**
 * 🔴 THE WIDENING CATCHER. "Close everything" is a fix that passes the case above and breaks the
 * program: a child with no stdout returns nothing, and every caller of execArgv reads the child's
 * stdout for its answer -- curl's HTTP status, snmpget's value, ovs-vsctl's port list. This case
 * is red for close_range(0, ...) and for any other over-broad close, and it is the reason the
 * production line starts at 3.
 */
TEST(CloseOnExecSocketsTest, ExecArgvChildKeepsTheDescriptorsItNeeds)
{
    const utils::CommandOutcome outcome = utils::execArgv({"sh", "-c", "echo alive"});
    ASSERT_TRUE(outcome.ran);
    EXPECT_NE(outcome.output.find("alive"), std::string::npos)
        << "the child produced no stdout: whatever closed its descriptors closed too many, and "
           "every execArgv caller now reads an empty answer.\ngot: [" << outcome.output << "]";
}

// =================================================================================================
// 5. the message -- what the kernel tells an operator when a port is taken
// =================================================================================================

/// The measured case: the holders exist, and not one of them is a kernel.
TEST(PortOwnershipMessageTest, OrphanedChildrenAreNotReportedAsAnotherKernel)
{
    utils::PortOwnership own;
    own.socketFound = true;
    own.uid = 1000;
    own.holders = {holder(1282318, "curl"), holder(1282317, "sh")};

    const std::string msg =
        utils::describePortOwnership(6343, utils::PortProtocol::Udp, own, "ndtwin_kernel");

    EXPECT_NE(msg.find("1282318"), std::string::npos) << msg;
    EXPECT_NE(msg.find("curl"), std::string::npos) << msg;
    EXPECT_NE(msg.find("None of them is a ndtwin_kernel"), std::string::npos)
        << "the message must say the holders are not another kernel; this is the sentence the "
           "operator acts on, and the old one sent them looking for a process that did not "
           "exist.\ngot: "
        << msg;
}

/// The case the old message was written for. It must still be sayable -- a fix that can never
/// name another kernel is as wrong as one that always does.
TEST(PortOwnershipMessageTest, AnotherKernelIsNamedWhenOneIsActuallyHoldingThePort)
{
    utils::PortOwnership own;
    own.socketFound = true;
    own.uid = 1000;
    own.holders = {holder(4242, "ndtwin_kernel")};

    const std::string msg =
        utils::describePortOwnership(8000, utils::PortProtocol::Tcp, own, "ndtwin_kernel");

    EXPECT_NE(msg.find("4242"), std::string::npos) << msg;
    EXPECT_NE(msg.find("another ndtwin_kernel"), std::string::npos)
        << "a real second kernel must still be named as one.\ngot: " << msg;
}

/// Bound, but by nobody this user can see. Saying "another kernel" here is a guess.
TEST(PortOwnershipMessageTest, AnUnattributableHolderIsNotCalledAKernel)
{
    utils::PortOwnership own;
    own.socketFound = true;
    own.uid = 0;
    own.holders = {};

    const std::string msg =
        utils::describePortOwnership(6343, utils::PortProtocol::Udp, own, "ndtwin_kernel");

    EXPECT_NE(msg.find("NOT evidence"), std::string::npos)
        << "with no attributable holder the message must refuse to name a culprit.\ngot: " << msg;
    // Not a substring search for "another ndtwin_kernel": the correct message contains that
    // phrase, inside "This is NOT evidence that another ndtwin_kernel is running." What must be
    // absent is the CLAIM -- the clause the renderer only reaches when it has found one.
    EXPECT_EQ(msg.find("One of them is another"), std::string::npos)
        << "the message named a second kernel with nothing to name it from.\ngot: " << msg;
    EXPECT_EQ(msg.find("almost certainly"), std::string::npos)
        << "the old, unfounded sentence is back.\ngot: " << msg;
}

/// Nothing bound at all: the bind failed for a reason this scan cannot see.
TEST(PortOwnershipMessageTest, NoSocketFoundSaysSoInsteadOfInventingAHolder)
{
    utils::PortOwnership own; // socketFound stays false

    const std::string msg =
        utils::describePortOwnership(6343, utils::PortProtocol::Udp, own, "ndtwin_kernel");

    EXPECT_NE(msg.find("No socket is bound"), std::string::npos) << msg;
    EXPECT_EQ(msg.find("One of them is another"), std::string::npos) << msg;
    EXPECT_EQ(msg.find("almost certainly"), std::string::npos) << msg;
}

/// The scan itself, against a socket this test is holding. Proves the /proc walk finds a real
/// holder -- the renderer cases above are pure and would pass over a scan that always found none.
TEST(PortOwnershipMessageTest, TheProcScanFindsThisProcessHoldingItsOwnPort)
{
    boost::asio::io_context ioc;
    auto acceptor = ControllerAndOtherEventHandler::openApiAcceptor(ioc, 0);
    ASSERT_TRUE(acceptor != nullptr);
    const unsigned short port = acceptor->local_endpoint().port();

    const utils::PortOwnership own = utils::findPortOwnership(port, utils::PortProtocol::Tcp);
    ASSERT_TRUE(own.socketFound) << "the /proc/net scan did not find a socket on port " << port
                                 << " that this process is listening on";

    bool sawSelf = false;
    for (const utils::PortHolder& h : own.holders)
    {
        if (h.pid == ::getpid())
        {
            sawSelf = true;
        }
    }
    EXPECT_TRUE(sawSelf) << "the /proc/<pid>/fd walk did not attribute the port to this process, "
                            "so it would not attribute an orphaned curl either";
}

/**
 * The message the kernel actually prints, end to end: this test holds the port, so the holder the
 * scan finds is this test binary -- which is emphatically not an ndtwin_kernel. The old code
 * printed "Another NDTwin kernel is almost certainly still running and holding it" here, in the
 * exact situation where that sentence is false.
 */
TEST(PortOwnershipMessageTest, TheSflowBindFailureNamesTheRealHolderRatherThanBlamingAKernel)
{
    const Fd taken(inheritableUdpSocket());
    ASSERT_GE(taken.get(), 0);
    sockaddr_in addr{};
    socklen_t len = sizeof(addr);
    ASSERT_EQ(::getsockname(taken.get(), reinterpret_cast<sockaddr*>(&addr), &len), 0);
    const unsigned short port = ntohs(addr.sin_port);

    CloexecLogCapture log;
    EXPECT_THROW(sflow::FlowLinkUsageCollector::openSflowSocket(port), std::runtime_error);

    const std::string text = log.text();
    EXPECT_NE(text.find("None of them is a ndtwin_kernel"), std::string::npos)
        << "the bind failure blamed something the evidence does not support.\nlogged: " << text;
    EXPECT_NE(text.find(std::to_string(::getpid())), std::string::npos)
        << "the message did not name the pid that actually holds the port.\nlogged: " << text;
    EXPECT_EQ(text.find("almost certainly still running"), std::string::npos)
        << "the old, unfounded sentence is back.\nlogged: " << text;
}
