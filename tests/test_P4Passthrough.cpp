/**
 * @file test_P4Passthrough.cpp
 * @brief The kernel's /ndt/p4/... routes relay to the P4 proxy, and relay nothing else.
 *
 * [Co-developed with claude code -- Adam]
 *
 * An app is meant to do everything through the kernel on :8000, and the P4 reads and writes live
 * on the proxy (:8081). The kernel relays five of them and must hand back exactly what the proxy
 * said -- a 409 `owned by NDTwin` read by the app has to be the proxy's own 409 -- while never
 * turning into a general relay to :8081, and while never holding up the rest of the kernel.
 *
 * Every case runs against a FAKE proxy: an HTTP server on an ephemeral loopback port, started by
 * this file, that records each request it receives and answers what the case scripted. No real
 * proxy, no bmv2. "Was it relayed" is read off that server's record, so a refusal is checked on
 * the wire and not by trusting the kernel's own reply.
 *
 * Two levels:
 *   - p4passthrough::respond, for the relay itself;
 *   - a kernel on a loopback port, served the way the real one is (HttpSession over an
 *     io_context with concurrency hint 1, run by several threads, as ControllerAndOtherEventHandler
 *     runs it) and called over a socket, for what only the request path decides: that the relay
 *     does not block, the headers, CORS, OPTIONS and HEAD, and the lab claim.
 */

#include <algorithm>
#include <cerrno>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <iostream>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <regex>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <thread>
#include <tuple>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include <boost/asio.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "ndt_core/http/P4Passthrough.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

namespace
{

using json = nlohmann::json;
using std::chrono::milliseconds;

/// What the fake proxy saw of one request.
struct SeenRequest
{
    std::string method;
    std::string target;
    std::string body;
    std::optional<std::string> contentType;
};

/// What the fake proxy answers.
struct Script
{
    unsigned status = 200;
    std::optional<std::string> contentType = std::string("application/json");
    std::string body = R"({"status":"success"})";
    /// Read the request and never answer.
    bool hang = false;
    /// Read the request and close the connection without a byte.
    bool closeAfterRead = false;
    /// Read the request, write these bytes as they are, and close.
    std::optional<std::string> raw;
};

Script
hangs()
{
    Script s;
    s.hang = true;
    return s;
}

Script
answers(unsigned status, std::optional<std::string> contentType, std::string body)
{
    Script s;
    s.status = status;
    s.contentType = std::move(contentType);
    s.body = std::move(body);
    return s;
}

/**
 * An HTTP server on 127.0.0.1:<ephemeral>, on its own thread. Ephemeral because a fixed port could
 * collide with a real proxy on :8081 -- and then "nothing was relayed" would be measured against
 * the wrong server.
 */
class FakeProxy
{
  public:
    FakeProxy()
        : m_acceptor(m_ioc, tcp::endpoint(net::ip::address_v4::loopback(), 0))
    {
        m_port = m_acceptor.local_endpoint().port();
        doAccept();
        m_thread = std::thread([this] { m_ioc.run(); });
    }

    ~FakeProxy()
    {
        net::post(m_ioc, [this] {
            beast::error_code ec;
            m_acceptor.close(ec);
            for (auto& conn : m_conns)
            {
                conn->socket.close(ec);
            }
        });
        m_thread.join();
    }

    FakeProxy(const FakeProxy&) = delete;
    FakeProxy& operator=(const FakeProxy&) = delete;

    std::string hostAndPort() const { return "127.0.0.1:" + std::to_string(m_port); }
    unsigned short port() const { return m_port; }

    void script(Script s)
    {
        std::lock_guard<std::mutex> lock(m_mu);
        m_script = std::move(s);
    }

    std::vector<SeenRequest> seen() const
    {
        std::lock_guard<std::mutex> lock(m_mu);
        return m_seen;
    }

    /// Connections accepted, whether or not a whole request arrived on them.
    int accepted() const
    {
        std::lock_guard<std::mutex> lock(m_mu);
        return m_accepted;
    }

  private:
    struct Conn
    {
        explicit Conn(tcp::socket s)
            : socket(std::move(s))
        {
        }
        tcp::socket socket;
        beast::flat_buffer buffer;
        http::request<http::string_body> req;
        http::response<http::string_body> res;
        std::string raw;
    };

    void doAccept()
    {
        m_acceptor.async_accept([this](beast::error_code ec, tcp::socket socket) {
            if (ec)
            {
                return;
            }
            {
                std::lock_guard<std::mutex> lock(m_mu);
                ++m_accepted;
            }
            auto conn = std::make_shared<Conn>(std::move(socket));
            // Every connection is kept until the destructor closes it, so a client that connects
            // and never finishes its request cannot keep this thread's io_context running.
            m_conns.push_back(conn);
            http::async_read(conn->socket,
                             conn->buffer,
                             conn->req,
                             [this, conn](beast::error_code readEc, std::size_t) {
                                 onRequest(conn, readEc);
                             });
            doAccept();
        });
    }

    void onRequest(const std::shared_ptr<Conn>& conn, beast::error_code ec)
    {
        if (ec)
        {
            return;
        }
        Script script;
        {
            std::lock_guard<std::mutex> lock(m_mu);
            SeenRequest seen;
            seen.method = std::string(conn->req.method_string());
            seen.target = std::string(conn->req.target());
            seen.body = conn->req.body();
            const auto ct = conn->req.find(http::field::content_type);
            if (ct != conn->req.end())
            {
                seen.contentType = std::string(ct->value());
            }
            m_seen.push_back(std::move(seen));
            script = m_script;
        }
        beast::error_code ignored;
        if (script.hang)
        {
            // Left open, with no operation pending, until the destructor closes it.
            return;
        }
        if (script.closeAfterRead)
        {
            conn->socket.shutdown(tcp::socket::shutdown_both, ignored);
            conn->socket.close(ignored);
            return;
        }
        if (script.raw)
        {
            conn->raw = *script.raw;
            net::async_write(conn->socket,
                             net::buffer(conn->raw),
                             [conn](beast::error_code, std::size_t) {
                                 beast::error_code e;
                                 conn->socket.shutdown(tcp::socket::shutdown_both, e);
                                 conn->socket.close(e);
                             });
            return;
        }
        conn->res.version(11);
        conn->res.result(script.status);
        if (script.contentType)
        {
            conn->res.set(http::field::content_type, *script.contentType);
        }
        conn->res.body() = script.body;
        conn->res.keep_alive(false);
        conn->res.prepare_payload();
        http::async_write(conn->socket, conn->res, [conn](beast::error_code, std::size_t) {
            beast::error_code e;
            conn->socket.shutdown(tcp::socket::shutdown_both, e);
        });
    }

    net::io_context m_ioc;
    tcp::acceptor m_acceptor;
    unsigned short m_port = 0;
    std::thread m_thread;
    mutable std::mutex m_mu;
    Script m_script;
    std::vector<SeenRequest> m_seen;
    int m_accepted = 0;
    std::vector<std::shared_ptr<Conn>> m_conns; // touched only on m_ioc's thread
};

/// A loopback port nothing listens on: bound to learn a free number, then closed.
std::string
refusingHostAndPort()
{
    net::io_context ioc;
    tcp::acceptor acceptor(ioc, tcp::endpoint(net::ip::address_v4::loopback(), 0));
    const auto port = acceptor.local_endpoint().port();
    acceptor.close();
    return "127.0.0.1:" + std::to_string(port);
}

constexpr milliseconds kShortTimeout{400};

p4passthrough::Deadlines
deadlines(milliseconds both)
{
    p4passthrough::Deadlines d;
    d.twoRpc = both;
    d.oneRpc = both;
    return d;
}

p4passthrough::Reply
relayTo(const std::string& address,
        http::verb method,
        const std::string& target,
        const std::string& body = "",
        std::optional<std::string> contentType = std::nullopt,
        const p4passthrough::Deadlines& d = deadlines(milliseconds(5000)))
{
    return p4passthrough::respond(method, target, body, contentType, true, address, d);
}

p4passthrough::Reply
relay(FakeProxy& proxy,
      http::verb method,
      const std::string& target,
      const std::string& body = "",
      std::optional<std::string> contentType = std::nullopt)
{
    return relayTo(proxy.hostAndPort(), method, target, body, std::move(contentType));
}

/**
 * A GET relayed to a proxy that may never answer, bounded: if no reply has come within `bound`,
 * the fake proxy is closed -- which ends the relay's connection and so the relay -- and nullopt
 * comes back. A relay that ignored its deadline would otherwise hang the suite, and a std::async
 * future's destructor would wait for it.
 */
std::optional<p4passthrough::Reply>
boundedRelay(std::unique_ptr<FakeProxy>& proxy,
             const std::string& target,
             const p4passthrough::Deadlines& d,
             milliseconds bound)
{
    const std::string address = proxy->hostAndPort();
    auto pending = std::async(std::launch::async, [address, target, d] {
        return relayTo(address, http::verb::get, target, "", std::nullopt, d);
    });
    if (pending.wait_for(bound) != std::future_status::ready)
    {
        proxy.reset();
        pending.wait();
        return std::nullopt;
    }
    return pending.get();
}

/// The descriptors of this process whose TCP peer is 127.0.0.1:`port` -- the client side of a
/// connection to that port, never the listener's own accepted side.
std::vector<int>
socketsConnectedTo(unsigned short port)
{
    std::vector<int> fds;
    for (const auto& entry : std::filesystem::directory_iterator("/proc/self/fd"))
    {
        int fd = -1;
        try
        {
            fd = std::stoi(entry.path().filename().string());
        }
        catch (const std::exception&)
        {
            continue;
        }
        sockaddr_in peer{};
        socklen_t len = sizeof(peer);
        if (::getpeername(fd, reinterpret_cast<sockaddr*>(&peer), &len) == 0 &&
            peer.sin_family == AF_INET && ntohs(peer.sin_port) == port)
        {
            fds.push_back(fd);
        }
    }
    return fds;
}

/// The descriptors of this process bound to local port `port`, apart from the listener itself:
/// the sockets a listener on that port accepted. Matched on the local address alone, because a
/// socket whose peer answered with RST is in TCP_CLOSE, where getpeername() fails -- and that is
/// exactly the state of a session socket left behind after writing to a departed client.
std::vector<int>
socketsAcceptedOn(unsigned short port)
{
    std::vector<int> fds;
    for (const auto& entry : std::filesystem::directory_iterator("/proc/self/fd"))
    {
        int fd = -1;
        try
        {
            fd = std::stoi(entry.path().filename().string());
        }
        catch (const std::exception&)
        {
            continue;
        }
        sockaddr_in local{};
        socklen_t llen = sizeof(local);
        int listening = 0;
        socklen_t alen = sizeof(listening);
        if (::getsockname(fd, reinterpret_cast<sockaddr*>(&local), &llen) == 0 &&
            local.sin_family == AF_INET && ntohs(local.sin_port) == port &&
            ::getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &alen) == 0 && listening == 0)
        {
            fds.push_back(fd);
        }
    }
    return fds;
}

/**
 * A loopback listener whose accept queue is full and stays full: listen() with a backlog of 0, and
 * connections made to it that nobody accepts. A further SYN is dropped, so a connect to it neither
 * completes nor fails until the caller's own deadline -- a proxy host that does not answer.
 */
class FullListener
{
  public:
    FullListener()
    {
        m_fd = ::socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        socklen_t len = sizeof(addr);
        if (m_fd < 0 || ::bind(m_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
            ::getsockname(m_fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0 ||
            ::listen(m_fd, 0) != 0)
        {
            m_error = "could not set up the listener";
            return;
        }
        m_port = ntohs(addr.sin_port);
        for (int i = 0; i < 4; ++i)
        {
            const int c = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
            if (c < 0)
            {
                m_error = "could not open a filler socket";
                return;
            }
            m_fillers.push_back(c);
            if (::connect(c, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 &&
                errno != EINPROGRESS)
            {
                m_error = "a filler connect failed outright";
                return;
            }
        }
        // The first filler must hold the one queue slot before anyone else connects; wait for its
        // handshake rather than for a fixed time.
        pollfd first{m_fillers.front(), POLLOUT, 0};
        if (::poll(&first, 1, 2000) != 1)
        {
            m_error = "the first filler never connected";
        }
    }

    /// Empty when the queue is full as intended; otherwise what went wrong.
    const std::string& error() const { return m_error; }
    ~FullListener()
    {
        for (const int c : m_fillers)
        {
            ::close(c);
        }
        ::close(m_fd);
    }
    FullListener(const FullListener&) = delete;
    FullListener& operator=(const FullListener&) = delete;

    std::string hostAndPort() const { return "127.0.0.1:" + std::to_string(m_port); }

  private:
    int m_fd = -1;
    unsigned short m_port = 0;
    std::vector<int> m_fillers;
    std::string m_error;
};

/// The first number assigned to `name` at the start of a line of `path`, as in
/// `RPC_TIMEOUT_S = 5.0`.
std::optional<double>
pythonConstant(const std::string& path, const std::string& name)
{
    std::ifstream in(path);
    std::string line;
    const std::regex pattern("^" + name + R"(\s*=\s*([0-9]+(\.[0-9]+)?)\s*(#.*)?$)");
    while (std::getline(in, line))
    {
        std::smatch m;
        if (std::regex_match(line, m, pattern))
        {
            return std::stod(m[1].str());
        }
    }
    return std::nullopt;
}

/// A repository file, from whichever directory the test binary was started in.
std::string
repoFile(const std::string& relative)
{
    for (const std::string prefix : {"", "../", "../../", "../../../"})
    {
        if (std::filesystem::exists(prefix + relative))
        {
            return prefix + relative;
        }
    }
    return {};
}

} // namespace

// ---------------------------------------------------------------------------------------------
// The five routes are relayed with method, query and body intact.
// ---------------------------------------------------------------------------------------------

TEST(P4PassthroughRelay, TableEntryWriteGoesOutAsAPostWithItsBodyAndContentType)
{
    FakeProxy proxy;
    const std::string body = R"({"dpid":2,"op":"insert","table":"PkgIngress.acl",)"
                             R"("match":{"hdr.ip4.src":["10.0.1.1",32]},)"
                             R"("action_name":"PkgIngress.permit","action_params":{"port":1}})";
    const auto reply =
        relay(proxy, http::verb::post, "/ndt/p4/table_entry", body, "application/json");

    const auto seen = proxy.seen();
    ASSERT_EQ(seen.size(), 1u);
    EXPECT_EQ(seen[0].method, "POST");
    EXPECT_EQ(seen[0].target, "/p4/table_entry");
    EXPECT_EQ(seen[0].body, body) << "the body must reach the proxy byte for byte";
    EXPECT_EQ(seen[0].contentType.value_or("<none>"), "application/json");
    EXPECT_EQ(reply.origin, "proxy");
    EXPECT_TRUE(reply.labClaimBearing) << "the write route carries the lab claim";
}

TEST(P4PassthroughRelay, TableEntryReadGoesOutAsAGetWithItsQuery)
{
    FakeProxy proxy;
    const auto reply =
        relay(proxy, http::verb::get, "/ndt/p4/table_entry?dpid=2&table=PkgIngress.acl");

    const auto seen = proxy.seen();
    ASSERT_EQ(seen.size(), 1u);
    EXPECT_EQ(seen[0].method, "GET");
    EXPECT_EQ(seen[0].target, "/p4/table_entry?dpid=2&table=PkgIngress.acl");
    EXPECT_EQ(seen[0].body, "");
    EXPECT_FALSE(reply.labClaimBearing) << "a read does not carry the lab claim";
}

TEST(P4PassthroughRelay, EachNamedReadGoesOutUnderItsOwnPathWithItsQuery)
{
    const std::vector<std::pair<std::string, std::string>> cases = {
        {"/ndt/p4/counter/MyIngress.c_port?dpid=3&index=1",
         "/p4/counter/MyIngress.c_port?dpid=3&index=1"},
        {"/ndt/p4/direct_counter/HcIngress.dc_k2?dpid=2",
         "/p4/direct_counter/HcIngress.dc_k2?dpid=2"},
        {"/ndt/p4/register/HcIngress.r_mark?dpid=2&start=4&count=8",
         "/p4/register/HcIngress.r_mark?dpid=2&start=4&count=8"},
    };
    for (const auto& [kernelTarget, proxyTarget] : cases)
    {
        FakeProxy proxy;
        const auto reply = relay(proxy, http::verb::get, kernelTarget);
        const auto seen = proxy.seen();
        ASSERT_EQ(seen.size(), 1u) << kernelTarget;
        EXPECT_EQ(seen[0].method, "GET") << kernelTarget;
        EXPECT_EQ(seen[0].target, proxyTarget) << kernelTarget;
        EXPECT_EQ(reply.origin, "proxy") << kernelTarget;
        EXPECT_FALSE(reply.labClaimBearing) << kernelTarget;
    }
}

TEST(P4PassthroughRelay, AQueryIsRelayedEvenWhenTheKernelCouldNotReadIt)
{
    // The kernel does not interpret the query: a name the proxy will refuse, a repeated key and an
    // encoded character all go out as they came in, and the proxy says what it makes of them.
    FakeProxy proxy;
    relay(proxy, http::verb::get, "/ndt/p4/register/r?dpid=abc&dpid=2&x=%20y");
    const auto seen = proxy.seen();
    ASSERT_EQ(seen.size(), 1u);
    EXPECT_EQ(seen[0].target, "/p4/register/r?dpid=abc&dpid=2&x=%20y");
}

TEST(P4PassthroughRelay, TheAddressIsResolvedAsAHostNameTheWayItIsConfigured)
{
    // AppConfig::P4_PROXY_IP_AND_PORT is "localhost:8081": a name, not a literal address.
    FakeProxy proxy;
    const auto reply = relayTo("localhost:" + std::to_string(proxy.port()),
                               http::verb::get,
                               "/ndt/p4/counter/c?dpid=1");
    EXPECT_EQ(reply.origin, "proxy") << reply.body;
    EXPECT_EQ(reply.status, 200u) << reply.body;
    EXPECT_EQ(proxy.seen().size(), 1u);
}

// ---------------------------------------------------------------------------------------------
// The proxy's status, content type and body come back unchanged.
// ---------------------------------------------------------------------------------------------

TEST(P4PassthroughRelay, TheProxysStatusAndBodyComeBackUnchanged)
{
    // The bodies are the proxy's own shapes (FastAPI's {"detail": ...}), including one whose
    // detail is a plain string, so a relay that re-parsed and re-dumped JSON would show up as a
    // changed byte sequence.
    const std::vector<std::pair<unsigned, std::string>> cases = {
        {200, R"({"status": "success", "dpid": 2, "op": "insert", "priority": 0})"},
        {400, R"({"detail":{"error":"invalid table entry","dpid":2,"message":"value too wide"}})"},
        {404, R"({"detail":{"error":"unknown switch","message":"switch 9 is not connected"}})"},
        {409, R"({"detail":{"error":"owned by NDTwin","outcome":"owned_by_ndtwin"}})"},
        {501, R"({"detail":{"error":"match type not supported"}})"},
        {502, R"({"detail":{"error":"the switch refused the write","grpc_status":"UNKNOWN"}})"},
        {503, R"({"detail":"proxy has no topology yet"})"},
    };
    for (const auto& [status, body] : cases)
    {
        FakeProxy proxy;
        proxy.script(answers(status, std::string("application/json"), body));
        const auto reply = relay(
            proxy, http::verb::post, "/ndt/p4/table_entry", R"({"dpid":2})", "application/json");
        EXPECT_EQ(reply.status, status);
        EXPECT_EQ(reply.body, body) << status;
        EXPECT_EQ(reply.contentType.value_or("<none>"), "application/json") << status;
        EXPECT_EQ(reply.origin, "proxy") << status;
    }
}

TEST(P4PassthroughRelay, TheProxysContentTypeComesBackEvenWhenItIsNotJson)
{
    FakeProxy proxy;
    proxy.script(answers(500, std::string("text/plain; charset=utf-8"), "Internal Server Error"));
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/counter/c?dpid=1");
    EXPECT_EQ(reply.status, 500u);
    EXPECT_EQ(reply.contentType.value_or("<none>"), "text/plain; charset=utf-8");
    EXPECT_EQ(reply.body, "Internal Server Error");
}

TEST(P4PassthroughRelay, AReplyWithNoContentTypeComesBackWithNone)
{
    FakeProxy proxy;
    proxy.script(answers(200, std::nullopt, "raw"));
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/counter/c?dpid=1");
    EXPECT_FALSE(reply.contentType.has_value()) << *reply.contentType;
    EXPECT_EQ(reply.body, "raw");
}

// ---------------------------------------------------------------------------------------------
// Proxy down, slow, or answering nonsense: the kernel's own answer, told apart from the proxy's.
// ---------------------------------------------------------------------------------------------

TEST(P4PassthroughUnreachable, NothingListeningIsAKernel502ThatSaysTheProxyWasNotReached)
{
    const std::string address = refusingHostAndPort();
    const auto started = std::chrono::steady_clock::now();
    const auto reply = relayTo(
        address, http::verb::post, "/ndt/p4/table_entry", R"({"dpid":2})", "application/json");
    const auto took = std::chrono::steady_clock::now() - started;

    EXPECT_EQ(reply.status, 502u);
    EXPECT_EQ(reply.origin, "kernel");
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("origin", ""), "kernel") << reply.body;
    EXPECT_EQ(body.value("error", ""), "P4 proxy unreachable") << reply.body;
    EXPECT_EQ(body.value("proxy", ""), address) << reply.body;
    EXPECT_EQ(body.value("request_sent", true), false) << reply.body;
    EXPECT_FALSE(body.contains("detail")) << "the proxy's error shape, on a kernel answer";
    EXPECT_LT(took, std::chrono::seconds(2)) << "a refusal must not wait out the deadline";
    EXPECT_TRUE(reply.labClaimBearing);
}

TEST(P4PassthroughUnreachable, AProxyThatNeverAnswersIsAKernel504WithinTheDeadline)
{
    auto proxy = std::make_unique<FakeProxy>();
    proxy->script(hangs());
    const std::string address = proxy->hostAndPort();

    const auto started = std::chrono::steady_clock::now();
    const auto relayed = boundedRelay(
        proxy, "/ndt/p4/register/r?dpid=1", deadlines(kShortTimeout), std::chrono::seconds(5));
    ASSERT_TRUE(relayed.has_value()) << "no answer 5 s after a " << kShortTimeout.count()
                                     << " ms deadline: the relay does not honour its timeout";
    const auto& reply = *relayed;
    const auto took = std::chrono::steady_clock::now() - started;

    EXPECT_EQ(reply.status, 504u);
    EXPECT_EQ(reply.origin, "kernel");
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("origin", ""), "kernel") << reply.body;
    EXPECT_EQ(body.value("error", ""), "P4 proxy timed out") << reply.body;
    EXPECT_EQ(body.value("request_sent", false), true) << reply.body;
    EXPECT_EQ(body.value("timeout_ms", 0), kShortTimeout.count()) << reply.body;
    EXPECT_GE(took, kShortTimeout - milliseconds(50));
    // The deadline plus 1 s: room for a loaded machine to schedule the timer, not for a second
    // wait of any kind.
    EXPECT_LT(took, kShortTimeout + std::chrono::seconds(1));
    EXPECT_EQ(proxy->seen().size(), 1u) << "the request did reach the proxy";
}

TEST(P4PassthroughUnreachable, AProxyThatClosesAfterReadingIsA502ThatSaysTheRequestWasSent)
{
    FakeProxy proxy;
    Script s;
    s.closeAfterRead = true;
    proxy.script(s);
    const auto reply = relay(proxy, http::verb::post, "/ndt/p4/table_entry", R"({"dpid":1})");

    EXPECT_EQ(proxy.seen().size(), 1u);
    EXPECT_EQ(reply.status, 502u) << reply.body;
    EXPECT_EQ(reply.origin, "kernel");
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("error", ""), "no reply from P4 proxy") << reply.body;
    EXPECT_EQ(body.value("request_sent", false), true)
        << "the whole request had left the kernel, so the write may have landed: " << reply.body;
}

TEST(P4PassthroughUnreachable, AHalfSentReplyIsA502NotTheProxysAnswer)
{
    FakeProxy proxy;
    Script s;
    s.raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"st";
    proxy.script(s);
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/counter/c?dpid=1");

    EXPECT_EQ(reply.status, 502u) << reply.body;
    EXPECT_EQ(reply.origin, "kernel");
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("error", ""), "no reply from P4 proxy") << reply.body;
    EXPECT_EQ(body.value("request_sent", false), true) << reply.body;
}

TEST(P4PassthroughUnreachable, AMalformedReplyIsUnreadableNotUnreachable)
{
    FakeProxy proxy;
    Script s;
    s.raw = "this is not HTTP at all\r\n\r\n";
    proxy.script(s);
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/counter/c?dpid=1");

    EXPECT_EQ(reply.status, 502u) << reply.body;
    EXPECT_EQ(reply.origin, "kernel");
    EXPECT_EQ(json::parse(reply.body).value("error", ""), "P4 proxy reply unreadable")
        << reply.body;
}

TEST(P4PassthroughUnreachable, AReplyOverTheSizeLimitIsUnreadableNotUnreachable)
{
    // The limit is checked against Content-Length when the header arrives, so no 64 MiB body has
    // to cross the loopback for this.
    FakeProxy proxy;
    Script s;
    s.raw = "HTTP/1.1 200 OK\r\nContent-Length: " +
            std::to_string(p4passthrough::kMaxReplyBytes + 1) + "\r\n\r\n{}";
    proxy.script(s);
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/direct_counter/d?dpid=1");

    EXPECT_EQ(reply.status, 502u) << reply.body;
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("error", ""), "P4 proxy reply unreadable") << reply.body;
    EXPECT_NE(body.value("message", "").find("64 MiB"), std::string::npos) << reply.body;
}

TEST(P4PassthroughUnreachable, TheDeadlinesCoverTheProxysOwnSlowestAnswers)
{
    // Read from the proxy's source, so a change to its deadline is seen here.
    const std::string client = repoFile("p4_proxy/proxy_agent/p4_client.py");
    const std::string routes = repoFile("p4_proxy/proxy_agent/api_routes.py");
    ASSERT_FALSE(client.empty()) << "p4_proxy/proxy_agent/p4_client.py not found";
    ASSERT_FALSE(routes.empty()) << "p4_proxy/proxy_agent/api_routes.py not found";
    const auto rpc = pythonConstant(client, "RPC_TIMEOUT_S");
    ASSERT_TRUE(rpc.has_value()) << "no `RPC_TIMEOUT_S = <number>` line in " << client;

    // The write's lock wait is one RPC deadline; if that line changes, the write's slowest answer
    // is no longer two of them and the arithmetic below must be redone.
    std::ifstream in(routes);
    const std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    ASSERT_NE(text.find("\nTABLE_ENTRY_LOCK_TIMEOUT_S = RPC_TIMEOUT_S\n"), std::string::npos)
        << "the table-entry lock wait is no longer one RPC deadline";

    // Strictly more: an equal deadline lets the kernel's 504 race the proxy's own answer.
    EXPECT_GT(p4passthrough::kTwoRpcDeadlineSeconds, 2 * *rpc)
        << "a table-entry write (lock wait, then the write) or a table read (entries, then the "
           "default entry) can take two RPC deadlines";
    EXPECT_GT(p4passthrough::kOneRpcDeadlineSeconds, *rpc)
        << "a counter, direct-counter or register read can take one RPC deadline";
    EXPECT_LE(p4passthrough::kOneRpcDeadlineSeconds, p4passthrough::kTwoRpcDeadlineSeconds);

    // And by the 5 s each deadline keeps for the proxy's thread pool: a request can wait for a
    // free worker before its first RPC starts.
    constexpr double kPoolMarginSeconds = 5.0;
    EXPECT_GE(p4passthrough::kTwoRpcDeadlineSeconds - 2 * *rpc, kPoolMarginSeconds);
    EXPECT_GE(p4passthrough::kOneRpcDeadlineSeconds - *rpc, kPoolMarginSeconds);
}

TEST(P4PassthroughUnreachable, TheTableRoutesGetTheLongDeadlineAndTheNamedReadsTheShortOne)
{
    using p4passthrough::DeadlineClass;
    EXPECT_EQ(p4passthrough::matchRoute(http::verb::post, "/ndt/p4/table_entry").deadline,
              DeadlineClass::TwoRpc);
    EXPECT_EQ(p4passthrough::matchRoute(http::verb::get, "/ndt/p4/table_entry?dpid=1&table=t")
                  .deadline,
              DeadlineClass::TwoRpc);
    for (const std::string target : {"/ndt/p4/counter/c?dpid=1",
                                     "/ndt/p4/direct_counter/d?dpid=1",
                                     "/ndt/p4/register/r?dpid=1"})
    {
        EXPECT_EQ(p4passthrough::matchRoute(http::verb::get, target).deadline,
                  DeadlineClass::OneRpc)
            << target;
    }
}

TEST(P4PassthroughUnreachable, ANamedReadIsGivenUpOnAtTheShortDeadline)
{
    auto proxy = std::make_unique<FakeProxy>();
    proxy->script(hangs());
    p4passthrough::Deadlines d;
    d.twoRpc = std::chrono::seconds(30);
    d.oneRpc = kShortTimeout;
    const auto relayed =
        boundedRelay(proxy, "/ndt/p4/counter/c?dpid=1", d, std::chrono::seconds(5));
    ASSERT_TRUE(relayed.has_value()) << "a named read was not given up on at its own deadline";
    const auto& reply = *relayed;
    EXPECT_EQ(reply.status, 504u) << reply.body;
    EXPECT_EQ(json::parse(reply.body).value("timeout_ms", 0), kShortTimeout.count())
        << reply.body;
}

TEST(P4PassthroughUnreachable, AConnectThatNeverCompletesIsA504ThatSaysNothingWasSent)
{
    auto host = std::make_unique<FullListener>();
    ASSERT_EQ(host->error(), "");
    const std::string address = host->hostAndPort();
    auto pending = std::async(std::launch::async, [address] {
        return relayTo(address,
                       http::verb::post,
                       "/ndt/p4/table_entry",
                       R"({"dpid":1})",
                       std::nullopt,
                       deadlines(kShortTimeout));
    });
    // Bounded: closing the listener turns the hanging connect into a refusal, which ends a relay
    // that ignored its deadline.
    const bool finished = pending.wait_for(std::chrono::seconds(5)) == std::future_status::ready;
    if (!finished)
    {
        host.reset();
    }
    ASSERT_TRUE(finished) << "no answer 5 s after a " << kShortTimeout.count() << " ms deadline";
    const auto reply = pending.get();
    EXPECT_EQ(reply.status, 504u) << reply.body;
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("request_sent", true), false) << reply.body;
    const std::string message = body.value("message", "");
    EXPECT_NE(message.find("no connection within"), std::string::npos)
        << "the 504 dropped what went wrong: " << message;
    EXPECT_NE(message.find("the request was not sent"), std::string::npos) << message;
    EXPECT_EQ(message.find("completely"), std::string::npos)
        << "nothing reached the proxy, so nothing was partly sent: " << message;
}

TEST(P4PassthroughUnreachable, AReplyWhoseHeaderIsTooLargeSaysSo)
{
    FakeProxy proxy;
    Script s;
    s.raw = "HTTP/1.1 200 OK\r\nX-Big: " + std::string(9000, 'a') +
            "\r\nContent-Length: 2\r\n\r\n{}";
    proxy.script(s);
    const auto reply = relay(proxy, http::verb::get, "/ndt/p4/counter/c?dpid=1");
    EXPECT_EQ(reply.status, 502u) << reply.body;
    const json body = json::parse(reply.body);
    EXPECT_EQ(body.value("error", ""), "P4 proxy reply unreadable") << reply.body;
    const std::string message = body.value("message", "");
    EXPECT_NE(message.find("header"), std::string::npos) << message;
    EXPECT_NE(message.find("8 KiB"), std::string::npos) << message;
    EXPECT_EQ(message.find("64 MiB"), std::string::npos)
        << "the body limit was not what was hit: " << message;
}

TEST(P4PassthroughUnreachable, TheRelaysSocketToTheProxyIsCloseOnExec)
{
    // The kernel forks curl from other threads; a socket without FD_CLOEXEC would be inherited.
    auto proxy = std::make_unique<FakeProxy>();
    proxy->script(hangs());
    const unsigned short port = proxy->port();
    const std::string address = proxy->hostAndPort();
    auto pending = std::async(std::launch::async, [address] {
        return relayTo(address,
                       http::verb::get,
                       "/ndt/p4/counter/c?dpid=1",
                       "",
                       std::nullopt,
                       deadlines(milliseconds(1500)));
    });
    std::vector<int> fds;
    const auto from = std::chrono::steady_clock::now();
    while (fds.empty() && std::chrono::steady_clock::now() - from < milliseconds(1000))
    {
        if (!proxy->seen().empty())
        {
            fds = socketsConnectedTo(port);
        }
        std::this_thread::sleep_for(milliseconds(5));
    }
    std::vector<int> flags;
    for (const int fd : fds)
    {
        flags.push_back(::fcntl(fd, F_GETFD));
    }
    // Closing the fake proxy ends the relay whatever its deadline, so the wait below is bounded.
    proxy.reset();
    pending.wait();

    ASSERT_EQ(fds.size(), 1u) << "expected exactly one connection to the fake proxy";
    ASSERT_GE(flags[0], 0) << "fcntl(F_GETFD) failed";
    EXPECT_TRUE(flags[0] & FD_CLOEXEC) << "the relay's socket to the proxy is inheritable";
}

TEST(P4PassthroughOrdering, AnAnswerThatNeedsNoNetworkStillArrivesAfterRespondAsyncReturns)
{
    // Called from inside the io_context, as the session calls it: that is where a dispatch would
    // run the relay inline and hand the reply over before respondAsync had returned.
    for (const std::string target : {"/ndt/p4/counter/c?dpid=1", "/ndt/p4/readopt/2"})
    {
        net::io_context ioc;
        bool returned = false;
        bool ranBeforeReturn = false;
        int calls = 0;
        unsigned status = 0;
        net::post(ioc, [&] {
            p4passthrough::respondAsync(ioc.get_executor(),
                                        http::verb::get,
                                        target,
                                        "",
                                        std::nullopt,
                                        true,
                                        "an-address-with-no-port",
                                        deadlines(milliseconds(5000)),
                                        [&](p4passthrough::Reply reply) {
                                            ++calls;
                                            ranBeforeReturn = !returned;
                                            status = reply.status;
                                        });
            returned = true;
        });
        EXPECT_NO_THROW(ioc.run()) << target;
        EXPECT_EQ(calls, 1) << target;
        EXPECT_FALSE(ranBeforeReturn) << target << ": the handler ran before respondAsync returned";
        EXPECT_NE(status, 0u) << target;
    }
}

TEST(P4PassthroughOrdering, AReplyTheKernelCannotBuildIsAKernel500DeliveredOnce)
{
    // An address that is not UTF-8 makes the kernel's own error body impossible to serialise --
    // a throw inside the relay's completion. It must become one kernel 500, not an exception out
    // of the io_context, which would terminate the kernel: its io threads do not catch.
    net::io_context ioc;
    int calls = 0;
    p4passthrough::Reply got;
    net::post(ioc, [&] {
        p4passthrough::respondAsync(ioc.get_executor(),
                                    http::verb::post,
                                    "/ndt/p4/table_entry",
                                    R"({"dpid":1})",
                                    std::nullopt,
                                    true,
                                    "bad\xff",
                                    deadlines(milliseconds(5000)),
                                    [&](p4passthrough::Reply reply) {
                                        ++calls;
                                        got = std::move(reply);
                                    });
    });
    EXPECT_NO_THROW(ioc.run());
    EXPECT_EQ(calls, 1);
    EXPECT_EQ(got.status, 500u) << got.body;
    EXPECT_EQ(got.origin, "kernel");
    EXPECT_TRUE(got.labClaimBearing) << "a 500 on the write route is still the write's reply";
    EXPECT_EQ(json::parse(got.body).value("origin", ""), "kernel") << got.body;
}

// ---------------------------------------------------------------------------------------------
// The allowlist: anything else under /ndt/p4 is answered by the kernel and relayed nowhere.
// ---------------------------------------------------------------------------------------------

TEST(P4PassthroughAllowlist, APathOutsideTheFiveIsNotRelayed)
{
    const std::vector<std::pair<http::verb, std::string>> cases = {
        {http::verb::post, "/ndt/p4/readopt/2"},
        {http::verb::get, "/ndt/p4/switch_state"},
        {http::verb::post, "/ndt/p4/multicast_group"},
        {http::verb::get, "/ndt/p4/stats/flow/2"},
        {http::verb::get, "/ndt/p4"},
        {http::verb::get, "/ndt/p4/"},
        {http::verb::get, "/ndt/p4/counter/"},
        {http::verb::get, "/ndt/p4/counter/.?dpid=1"},
        {http::verb::get, "/ndt/p4/counter/..?dpid=1"},
        {http::verb::get, "/ndt/p4/counter/../../stats/flow/2"},
        {http::verb::get, "/ndt/p4/counter/a/b?dpid=1"},
        {http::verb::get, "/ndt/p4/direct_counter/a\\b?dpid=1"},
        {http::verb::get, "/ndt/p4/register/..%2F..%2Fswitch_state"},
        {http::verb::get, "/ndt/p4/table_entry/extra"},
        {http::verb::get, "/ndt/p4/table_entryX"},
    };
    const json expectedRoutes = json::array({"POST /ndt/p4/table_entry",
                                             "GET /ndt/p4/table_entry",
                                             "GET /ndt/p4/counter/{name}",
                                             "GET /ndt/p4/direct_counter/{name}",
                                             "GET /ndt/p4/register/{name}"});
    for (const auto& [method, target] : cases)
    {
        FakeProxy proxy;
        const auto reply = relay(proxy, method, target);
        EXPECT_EQ(proxy.accepted(), 0) << target << " reached the proxy";
        EXPECT_EQ(reply.status, 404u) << target;
        EXPECT_EQ(reply.origin, "kernel") << target;
        const json body = json::parse(reply.body);
        EXPECT_EQ(body.value("error", ""), "not a P4 pass-through route") << target;
        EXPECT_EQ(body.value("routes", json()), expectedRoutes)
            << target << ": the 404 must name the routes that do exist";
    }
}

TEST(P4PassthroughAllowlist, AnAllowlistedPathWithTheWrongMethodIsA405AndNotRelayed)
{
    const std::vector<std::tuple<http::verb, std::string, std::string>> cases = {
        {http::verb::delete_, "/ndt/p4/table_entry", "GET, POST"},
        {http::verb::put, "/ndt/p4/table_entry", "GET, POST"},
        {http::verb::post, "/ndt/p4/counter/c?dpid=1", "GET"},
        {http::verb::post, "/ndt/p4/direct_counter/d?dpid=1", "GET"},
        {http::verb::delete_, "/ndt/p4/register/r?dpid=1", "GET"},
    };
    for (const auto& [method, target, allow] : cases)
    {
        FakeProxy proxy;
        const auto reply = relay(proxy, method, target);
        EXPECT_EQ(proxy.accepted(), 0) << target << " reached the proxy";
        EXPECT_EQ(reply.status, 405u) << target;
        EXPECT_EQ(reply.allow, allow) << target;
        EXPECT_EQ(reply.origin, "kernel") << target;
    }
}

TEST(P4PassthroughAllowlist, TheRouterTestCoversOnlyTheP4Prefix)
{
    EXPECT_TRUE(p4passthrough::isP4PassthroughTarget("/ndt/p4"));
    EXPECT_TRUE(p4passthrough::isP4PassthroughTarget("/ndt/p4?x=1"));
    EXPECT_TRUE(p4passthrough::isP4PassthroughTarget("/ndt/p4/table_entry"));
    EXPECT_FALSE(p4passthrough::isP4PassthroughTarget("/ndt/p4_table_entry"));
    EXPECT_FALSE(p4passthrough::isP4PassthroughTarget("/ndt/get_graph_data"));
    EXPECT_FALSE(p4passthrough::isP4PassthroughTarget("/p4/table_entry"));
}

// ---------------------------------------------------------------------------------------------
// Not a P4 fabric: refused, relayed nowhere.
// ---------------------------------------------------------------------------------------------

TEST(P4PassthroughFabric, OnAFabricWithNoP4SwitchEveryRouteIsRefusedAndNothingIsRelayed)
{
    const std::vector<std::pair<http::verb, std::string>> cases = {
        {http::verb::post, "/ndt/p4/table_entry"},
        {http::verb::get, "/ndt/p4/table_entry?dpid=1&table=t"},
        {http::verb::get, "/ndt/p4/counter/c?dpid=1"},
        {http::verb::get, "/ndt/p4/direct_counter/d?dpid=1"},
        {http::verb::get, "/ndt/p4/register/r?dpid=1"},
    };
    for (const auto& [method, target] : cases)
    {
        FakeProxy proxy;
        const auto reply = p4passthrough::respond(method,
                                                  target,
                                                  R"({"dpid":1})",
                                                  std::nullopt,
                                                  false,
                                                  proxy.hostAndPort(),
                                                  deadlines(milliseconds(5000)));
        EXPECT_EQ(proxy.accepted(), 0) << target << " reached the proxy";
        EXPECT_EQ(reply.status, 501u) << target;
        EXPECT_EQ(reply.origin, "kernel") << target;
        const json body = json::parse(reply.body);
        EXPECT_EQ(body.value("error", ""), "not a P4 fabric") << reply.body;
        EXPECT_NE(body.value("message", "").find("only on a P4 fabric"), std::string::npos)
            << reply.body;
    }
}

// ---------------------------------------------------------------------------------------------
// Through the request path: a kernel on a loopback port, called over a socket.
// ---------------------------------------------------------------------------------------------

/**
 * Points a session at a fake proxy before it starts. Global scope to match
 * `friend class HttpSessionP4PassthroughTestPeer`.
 */
class HttpSessionP4PassthroughTestPeer
{
  public:
    static void configure(HttpSession& session,
                          const std::string& proxyHostAndPort,
                          const p4passthrough::Deadlines& d)
    {
        session.m_p4ProxyHostAndPort = proxyHostAndPort;
        session.m_p4Deadlines = d;
    }

    static json labClaim() { return HttpSession::labClaimJson(); }
    static std::size_t labClaimHeaderCap() { return HttpSession::kLabClaimHeaderMaxBytes; }
};

namespace
{

/**
 * HttpSession served the way ControllerAndOtherEventHandler serves it: one io_context with a
 * concurrency hint of 1 (main.cpp's `net::io_context ioc{1}`), run by several threads, accepting
 * on a loopback port and starting a session per connection.
 */
class LiveKernel
{
  public:
    LiveKernel(std::shared_ptr<TopologyAndFlowMonitor> monitor,
               std::string proxyHostAndPort,
               p4passthrough::Deadlines d,
               int threads = 4,
               std::shared_ptr<DeviceConfigurationAndPowerManager> power = nullptr)
        : m_ioc(1),
          m_acceptor(m_ioc, tcp::endpoint(net::ip::address_v4::loopback(), 0)),
          m_monitor(std::move(monitor)),
          m_power(std::move(power)),
          m_proxy(std::move(proxyHostAndPort)),
          m_deadlines(d)
    {
        m_port = m_acceptor.local_endpoint().port();
        doAccept();
        for (int i = 0; i < threads; ++i)
        {
            // The kernel's own io threads do not catch, so an exception out of run() terminates
            // the kernel. Here it is recorded instead, and the destructor fails the case.
            m_threads.emplace_back([this] {
                try
                {
                    m_ioc.run();
                }
                catch (const std::exception& e)
                {
                    std::lock_guard<std::mutex> lock(m_escapedMu);
                    m_escaped.push_back(e.what());
                }
            });
        }
    }

    ~LiveKernel()
    {
        m_ioc.stop();
        for (auto& t : m_threads)
        {
            t.join();
        }
        for (const auto& what : m_escaped)
        {
            ADD_FAILURE() << "an exception left the kernel's io_context, which would terminate "
                             "the kernel: "
                          << what;
        }
    }

    unsigned short port() const { return m_port; }

  private:
    void doAccept()
    {
        m_acceptor.async_accept([this](beast::error_code ec, tcp::socket socket) {
            if (ec)
            {
                return;
            }
            auto session = std::make_shared<HttpSession>(std::move(socket),
                                                         m_monitor,
                                                         nullptr,        // EventBus
                                                         utils::MININET, // mode
                                                         nullptr,        // FlowLinkUsageCollector
                                                         nullptr,        // FlowRoutingManager
                                                         m_power,        // DeviceConfig...Manager
                                                         nullptr,        // ApplicationManager
                                                         nullptr,        // SimulationRequestMgr
                                                         nullptr,        // IntentTranslator
                                                         nullptr,        // HistoricalDataManager
                                                         nullptr,        // Controller
                                                         nullptr);       // LockManager
            HttpSessionP4PassthroughTestPeer::configure(*session, m_proxy, m_deadlines);
            session->start();
            doAccept();
        });
    }

    net::io_context m_ioc;
    tcp::acceptor m_acceptor;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_power;
    std::string m_proxy;
    p4passthrough::Deadlines m_deadlines;
    unsigned short m_port = 0;
    std::vector<std::thread> m_threads;
    std::mutex m_escapedMu;
    std::vector<std::string> m_escaped;
};

/// One reply as it came off the socket.
struct WireReply
{
    bool complete = false;
    std::string error;
    std::string raw;
    std::string headerBlock;
    unsigned status = 0;
    std::vector<std::pair<std::string, std::string>> headers;
    std::string body;
    milliseconds took{0};

    std::optional<std::string> header(const std::string& name) const
    {
        for (const auto& [k, v] : headers)
        {
            if (std::equal(k.begin(), k.end(), name.begin(), name.end(), [](char a, char b) {
                    return std::tolower(static_cast<unsigned char>(a)) ==
                           std::tolower(static_cast<unsigned char>(b));
                }))
            {
                return v;
            }
        }
        return std::nullopt;
    }

    bool anyCorsHeader() const
    {
        for (const auto& [k, v] : headers)
        {
            std::string lower(k);
            std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
                return static_cast<char>(std::tolower(c));
            });
            if (lower.rfind("access-control-", 0) == 0)
            {
                return true;
            }
        }
        return false;
    }
};

/**
 * Sends one request with `Connection: close` and reads every byte until the kernel closes, so the
 * reply is seen exactly as written -- including whether a HEAD reply carried a body.
 */
WireReply
call(unsigned short port,
     const std::string& method,
     const std::string& target,
     const std::string& body = "",
     std::optional<std::string> contentType = std::nullopt,
     milliseconds limit = milliseconds(10000))
{
    std::ostringstream req;
    req << method << " " << target << " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n";
    if (contentType)
    {
        req << "Content-Type: " << *contentType << "\r\n";
    }
    if (!body.empty() || method == "POST")
    {
        req << "Content-Length: " << body.size() << "\r\n";
    }
    req << "\r\n" << body;
    const std::string request = req.str();

    WireReply out;
    net::io_context ioc;
    beast::tcp_stream stream(ioc);
    std::array<char, 4096> chunk{};
    const auto started = std::chrono::steady_clock::now();
    std::function<void(beast::error_code, std::size_t)> onRead;
    onRead = [&](beast::error_code ec, std::size_t n) {
        out.raw.append(chunk.data(), n);
        if (ec == net::error::eof)
        {
            out.complete = true;
            return;
        }
        if (ec)
        {
            out.error = ec.message();
            return;
        }
        stream.async_read_some(net::buffer(chunk), onRead);
    };
    stream.expires_after(limit);
    stream.async_connect(tcp::endpoint(net::ip::address_v4::loopback(), port),
                         [&](beast::error_code ec) {
                             if (ec)
                             {
                                 out.error = ec.message();
                                 return;
                             }
                             net::async_write(stream,
                                              net::buffer(request),
                                              [&](beast::error_code wec, std::size_t) {
                                                  if (wec)
                                                  {
                                                      out.error = wec.message();
                                                      return;
                                                  }
                                                  stream.async_read_some(net::buffer(chunk),
                                                                         onRead);
                                              });
                         });
    ioc.run();
    out.took = std::chrono::duration_cast<milliseconds>(std::chrono::steady_clock::now() - started);

    const auto end = out.raw.find("\r\n\r\n");
    if (end == std::string::npos)
    {
        out.complete = false;
        return out;
    }
    out.headerBlock = out.raw.substr(0, end);
    out.body = out.raw.substr(end + 4);
    std::istringstream lines(out.headerBlock);
    std::string line;
    std::getline(lines, line);
    if (line.size() >= 12)
    {
        out.status = static_cast<unsigned>(std::stoul(line.substr(9, 3)));
    }
    while (std::getline(lines, line))
    {
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        const auto colon = line.find(':');
        if (colon == std::string::npos)
        {
            continue;
        }
        std::string value = line.substr(colon + 1);
        value.erase(0, value.find_first_not_of(' '));
        out.headers.emplace_back(line.substr(0, colon), value);
    }
    return out;
}

/**
 * Writes `raw` -- one or several requests, as one write -- on one connection and reads `count`
 * replies from it with Beast's parser, so a reply that wrongly closed the connection shows up as a
 * missing reply rather than as a short read.
 */
std::vector<WireReply>
exchange(unsigned short port,
         const std::string& raw,
         std::size_t count,
         milliseconds limit = milliseconds(10000))
{
    std::vector<WireReply> replies;
    net::io_context ioc;
    beast::tcp_stream stream(ioc);
    beast::flat_buffer buffer;
    http::response<http::string_body> res;
    std::function<void()> readOne = [&] {
        res = {};
        http::async_read(stream, buffer, res, [&](beast::error_code ec, std::size_t) {
            if (ec)
            {
                return;
            }
            WireReply r;
            r.complete = true;
            r.status = res.result_int();
            for (const auto& field : res)
            {
                r.headers.emplace_back(std::string(field.name_string()),
                                       std::string(field.value()));
            }
            r.body = res.body();
            replies.push_back(std::move(r));
            if (replies.size() < count)
            {
                readOne();
            }
        });
    };
    stream.expires_after(limit);
    stream.async_connect(tcp::endpoint(net::ip::address_v4::loopback(), port),
                         [&](beast::error_code ec) {
                             if (ec)
                             {
                                 return;
                             }
                             net::async_write(stream,
                                              net::buffer(raw),
                                              [&](beast::error_code wec, std::size_t) {
                                                  if (!wec)
                                                  {
                                                      readOne();
                                                  }
                                              });
                         });
    ioc.run();
    return replies;
}

/**
 * Writes each request in turn on one connection, reading its reply before writing the next, all
 * asynchronous under one deadline. A reply that never comes, or a connection the kernel closed,
 * shows up as fewer replies than requests.
 */
std::vector<WireReply>
exchangeInTurn(unsigned short port,
               const std::vector<std::string>& requests,
               milliseconds limit = milliseconds(10000))
{
    std::vector<WireReply> replies;
    net::io_context ioc;
    beast::tcp_stream stream(ioc);
    beast::flat_buffer buffer;
    http::response<http::string_body> res;
    std::function<void(std::size_t)> sendOne = [&](std::size_t i) {
        if (i == requests.size())
        {
            return;
        }
        auto onWritten = [&, i](beast::error_code wec, std::size_t) {
            if (wec)
            {
                return;
            }
            res = {};
            http::async_read(stream, buffer, res, [&, i](beast::error_code ec, std::size_t) {
                if (ec)
                {
                    return;
                }
                WireReply r;
                r.complete = true;
                r.status = res.result_int();
                for (const auto& field : res)
                {
                    r.headers.emplace_back(std::string(field.name_string()),
                                           std::string(field.value()));
                }
                r.body = res.body();
                replies.push_back(std::move(r));
                sendOne(i + 1);
            });
        };
        net::async_write(stream, net::buffer(requests[i]), onWritten);
    };
    stream.expires_after(limit);
    stream.async_connect(tcp::endpoint(net::ip::address_v4::loopback(), port),
                         [&](beast::error_code ec) {
                             if (!ec)
                             {
                                 sendOne(0);
                             }
                         });
    ioc.run();
    return replies;
}

json
switchNode(std::uint64_t dpid, const std::string& brand)
{
    const std::string name = "s" + std::to_string(dpid);
    return json{{"brand_name", brand},
                {"bridge_name", name},
                {"device_layer", 2},
                {"device_name", name},
                {"nickname", name},
                {"dpid", dpid},
                {"ip", json::array({"192.168.123." + std::to_string(10 + dpid)})},
                {"mac", dpid},
                {"smart_plug_ip", ""},
                {"smart_plug_outlet", 0},
                {"vertex_type", 0}};
}

/// A two-switch topology of one brand, loaded and nothing else: no poll thread starts, so the
/// fixture never asks :8081 or Ryu for anything.
std::shared_ptr<TopologyAndFlowMonitor>
loadedFabric(const std::string& brand)
{
    const std::string path = (std::filesystem::temp_directory_path() /
                              ("ndt_p4passthrough_" + brand + "_" +
                               std::to_string(static_cast<long>(::getpid())) + ".json"))
                                 .string();
    const json topology = {{"nodes", {switchNode(1, brand), switchNode(2, brand)}},
                           {"edges", json::array()},
                           {"links", json::array()}};
    {
        std::ofstream out(path);
        out << topology.dump();
    }
    ::setenv("NDTWIN_TOPO_FILE", path.c_str(), 1);
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            std::make_shared<EventBus>(),
                                                            utils::MININET);
    const bool loaded = monitor->loadStaticTopology();
    ::unsetenv("NDTWIN_TOPO_FILE");
    std::remove(path.c_str());
    return loaded ? monitor : nullptr;
}

/// A claim file for the duration of one case.
class ClaimFile
{
  public:
    explicit ClaimFile(const std::string& note)
    {
        m_path = (std::filesystem::temp_directory_path() /
                  ("ndt_p4passthrough_claim_" + std::to_string(static_cast<long>(::getpid()))))
                     .string();
        std::ofstream out(m_path, std::ios::binary);
        out << "owner=app-one\nexpires=" << (std::time(nullptr) + 3600) << "\nnote=" << note
            << "\n";
        out.close();
        ::setenv("NDT_LAB_CLAIM_FILE", m_path.c_str(), 1);
    }
    ~ClaimFile()
    {
        ::unsetenv("NDT_LAB_CLAIM_FILE");
        std::remove(m_path.c_str());
    }

  private:
    std::string m_path;
};

class P4PassthroughSession : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        s_bmv2 = loadedFabric("BMv2");
        s_ovs = loadedFabric("OVS");
    }
    static void TearDownTestSuite()
    {
        s_bmv2.reset();
        s_ovs.reset();
    }

    void SetUp() override
    {
        ASSERT_TRUE(s_bmv2 && s_ovs) << "a fixture topology did not load";
        ASSERT_EQ(s_bmv2->getSwitchKindGroups().count(SwitchKind::BMV2), 1u)
            << "the BMv2 fixture topology did not load";
        ASSERT_EQ(s_ovs->getSwitchKindGroups().count(SwitchKind::OVS), 1u)
            << "the OVS fixture topology did not load";
    }

    static std::shared_ptr<TopologyAndFlowMonitor> s_bmv2;
    static std::shared_ptr<TopologyAndFlowMonitor> s_ovs;
};

std::shared_ptr<TopologyAndFlowMonitor> P4PassthroughSession::s_bmv2;
std::shared_ptr<TopologyAndFlowMonitor> P4PassthroughSession::s_ovs;

const p4passthrough::Deadlines kSessionDeadlines = deadlines(milliseconds(5000));

} // namespace

TEST_F(P4PassthroughSession, OnAP4FabricTheRelayHandsBackTheProxysReply)
{
    FakeProxy proxy;
    const std::string proxyBody =
        R"({"detail":{"error":"owned by NDTwin","outcome":"owned_by_ndtwin"}})";
    proxy.script(answers(409, std::string("application/json"), proxyBody));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);

    const std::string body = R"({"dpid":1,"table":"MyIngress.ipv4_lpm"})";
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", body, "application/json");

    ASSERT_TRUE(res.complete) << res.error;
    const auto seen = proxy.seen();
    ASSERT_EQ(seen.size(), 1u);
    EXPECT_EQ(seen[0].method, "POST");
    EXPECT_EQ(seen[0].target, "/p4/table_entry");
    EXPECT_EQ(seen[0].body, body);
    EXPECT_EQ(res.status, 409u);
    EXPECT_EQ(res.body, proxyBody) << "the session must not edit the proxy's body";
    EXPECT_EQ(res.header("Content-Type").value_or("<absent>"), "application/json");
    EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "proxy");
}

TEST_F(P4PassthroughSession, AProxyReplyWithNoContentTypeHasNoneOnTheKernelsReplyEither)
{
    // Every other route's reply starts as application/json; a relayed reply must not inherit that.
    FakeProxy proxy;
    proxy.script(answers(200, std::nullopt, "raw"));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "GET", "/ndt/p4/register/r?dpid=1");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(res.status, 200u);
    EXPECT_EQ(res.body, "raw");
    EXPECT_EQ(res.header("Content-Type").value_or("<absent>"), "<absent>");
}

TEST_F(P4PassthroughSession, OnAnOvsFabricTheRoutesAreRefusedAndNothingIsRelayed)
{
    FakeProxy proxy;
    LiveKernel kernel(s_ovs, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "GET", "/ndt/p4/counter/c?dpid=1");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(proxy.accepted(), 0) << "an OVS fabric relayed a P4 request";
    EXPECT_EQ(res.status, 501u) << res.body;
    EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "kernel");
    EXPECT_EQ(json::parse(res.body).value("error", ""), "not a P4 fabric") << res.body;
}

TEST_F(P4PassthroughSession, WithNoTopologyAtAllNothingIsRelayed)
{
    FakeProxy proxy;
    LiveKernel kernel(nullptr, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(proxy.accepted(), 0);
    EXPECT_EQ(res.status, 501u) << res.body;
}

TEST_F(P4PassthroughSession, ThePathOutsideTheAllowlistIsAnsweredByTheKernel)
{
    FakeProxy proxy;
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/readopt/1");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(proxy.accepted(), 0) << "/ndt/p4/readopt reached the proxy";
    EXPECT_EQ(res.status, 404u);
    EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "kernel");
}

TEST_F(P4PassthroughSession, TheWriteCarriesTheLabClaimAsAHeaderAndTheBodyStaysTheProxys)
{
    ClaimFile claim("upgrade \"s1\"");
    FakeProxy proxy;
    const std::string proxyBody = R"({"status":"success","dpid":1,"op":"insert"})";
    proxy.script(answers(200, std::string("application/json"), proxyBody));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);

    const auto write = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    const auto read = call(kernel.port(), "GET", "/ndt/p4/table_entry?dpid=1&table=t");
    ASSERT_TRUE(write.complete && read.complete) << write.error << read.error;

    EXPECT_EQ(write.body, proxyBody) << "lab_claim went into the proxy's body";
    const auto header = write.header("X-NDTwin-Lab-Claim");
    ASSERT_TRUE(header.has_value());
    const json parsed = json::parse(*header);
    EXPECT_EQ(parsed.value("state", ""), "active") << *header;
    EXPECT_EQ(parsed.value("owner", ""), "app-one") << *header;
    EXPECT_EQ(parsed.value("note", ""), "upgrade \"s1\"") << *header;
    EXPECT_GT(parsed.value("expires_at", std::int64_t{0}), 0) << *header;
    EXPECT_FALSE(read.header("X-NDTwin-Lab-Claim").has_value()) << "a read carries no lab claim";
}

TEST_F(P4PassthroughSession, TheWriteCarriesTheLabClaimOnTheKernelsOwnRefusalsToo)
{
    LiveKernel kernel(s_ovs, refusingHostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(res.status, 501u);
    const auto header = res.header("X-NDTwin-Lab-Claim");
    ASSERT_TRUE(header.has_value());
    EXPECT_TRUE(json::parse(*header).contains("state")) << *header;
}

TEST_F(P4PassthroughSession, ANonAsciiNoteReachesTheHeaderAsAsciiAndParsesBackUnchanged)
{
    ClaimFile claim("\xe6\xb8\xac\xe8\xa9\xa6 upgrade"); // "測試 upgrade" in UTF-8
    FakeProxy proxy;
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    ASSERT_TRUE(res.complete) << res.error;

    for (const unsigned char c : res.headerBlock)
    {
        ASSERT_LT(c, 0x80u) << "a header byte at or above 0x80 reached the wire";
    }
    const auto header = res.header("X-NDTwin-Lab-Claim");
    ASSERT_TRUE(header.has_value());
    const json parsed = json::parse(*header);
    EXPECT_EQ(parsed.value("note", ""), "\xe6\xb8\xac\xe8\xa9\xa6 upgrade") << *header;
    EXPECT_EQ(parsed, HttpSessionP4PassthroughTestPeer::labClaim())
        << "the header must be the same object the twelve writes carry in their body";
}

TEST_F(P4PassthroughSession, AClaimFileThatIsNotUtf8DoesNotChangeTheProxysAnswer)
{
    ClaimFile claim("\xff\xfe broken");
    FakeProxy proxy;
    const std::string proxyBody = R"({"status":"success","dpid":1})";
    proxy.script(answers(200, std::string("application/json"), proxyBody));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    ASSERT_TRUE(res.complete) << res.error;

    EXPECT_EQ(res.status, 200u) << res.body;
    EXPECT_EQ(res.body, proxyBody);
    EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "proxy");
    const auto header = res.header("X-NDTwin-Lab-Claim");
    ASSERT_TRUE(header.has_value());
    EXPECT_EQ(json::parse(*header).value("owner", ""), "app-one") << *header;
}

TEST_F(P4PassthroughSession, AWrongMethodIsA405WhoseAllowHeaderIsOnTheWire)
{
    FakeProxy proxy;
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const auto table = call(kernel.port(), "DELETE", "/ndt/p4/table_entry");
    const auto counter = call(kernel.port(), "POST", "/ndt/p4/counter/c?dpid=1", "{}");
    ASSERT_TRUE(table.complete && counter.complete) << table.error << counter.error;
    EXPECT_EQ(table.status, 405u);
    EXPECT_EQ(table.header("Allow").value_or("<absent>"), "GET, POST");
    EXPECT_EQ(counter.status, 405u);
    EXPECT_EQ(counter.header("Allow").value_or("<absent>"), "GET");
    EXPECT_EQ(proxy.accepted(), 0);
}

TEST_F(P4PassthroughSession, OptionsAndHeadUnderP4AreAnsweredByThePassthroughNotThePreflight)
{
    FakeProxy proxy;
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    const std::vector<std::tuple<std::string, unsigned, std::string>> cases = {
        {"/ndt/p4/table_entry", 405, "GET, POST"},
        {"/ndt/p4/table_entry?dpid=1&table=t", 405, "GET, POST"},
        {"/ndt/p4/counter/c?dpid=1", 405, "GET"},
        {"/ndt/p4/direct_counter/d?dpid=1", 405, "GET"},
        {"/ndt/p4/register/r?dpid=1", 405, "GET"},
        {"/ndt/p4/readopt/2", 404, ""},
    };
    for (const std::string method : {"OPTIONS", "HEAD"})
    {
        for (const auto& [target, status, allow] : cases)
        {
            const auto res = call(kernel.port(), method, target);
            const std::string what = method + " " + target;
            ASSERT_TRUE(res.complete) << what << ": " << res.error;
            EXPECT_EQ(res.status, status) << what;
            EXPECT_EQ(res.header("Allow").value_or(""), allow) << what;
            EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "kernel") << what;
            EXPECT_FALSE(res.anyCorsHeader()) << what << " carries a CORS header";
            if (method == "HEAD")
            {
                EXPECT_EQ(res.body, "") << what << ": a HEAD reply carried a body";
            }
        }
    }
    EXPECT_EQ(proxy.accepted(), 0) << "an OPTIONS or HEAD was relayed";
}

TEST_F(P4PassthroughSession, NoReplyUnderP4CarriesACorsHeader)
{
    FakeProxy proxy;
    LiveKernel p4(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
    LiveKernel ovs(s_ovs, proxy.hostAndPort(), kSessionDeadlines);
    LiveKernel down(s_bmv2, refusingHostAndPort(), kSessionDeadlines);

    const auto relayed = call(p4.port(), "GET", "/ndt/p4/counter/c?dpid=1");
    const auto notListed = call(p4.port(), "GET", "/ndt/p4/switch_state");
    const auto notP4 = call(ovs.port(), "GET", "/ndt/p4/counter/c?dpid=1");
    const auto unreachable = call(down.port(), "GET", "/ndt/p4/counter/c?dpid=1");
    for (const auto& [res, status] : std::vector<std::pair<WireReply, unsigned>>{
             {relayed, 200}, {notListed, 404}, {notP4, 501}, {unreachable, 502}})
    {
        ASSERT_TRUE(res.complete) << res.error;
        EXPECT_EQ(res.status, status) << res.headerBlock;
        EXPECT_FALSE(res.anyCorsHeader()) << res.headerBlock;
    }
}

TEST_F(P4PassthroughSession, AnotherKernelRouteKeepsItsCorsHeaders)
{
    LiveKernel kernel(s_bmv2, refusingHostAndPort(), kSessionDeadlines);
    const auto notFound = call(kernel.port(), "GET", "/ndt/no_such_route");
    const auto preflight = call(kernel.port(), "OPTIONS", "/ndt/get_graph_data");
    ASSERT_TRUE(notFound.complete && preflight.complete) << notFound.error << preflight.error;
    EXPECT_EQ(notFound.status, 404u);
    EXPECT_EQ(notFound.header("Access-Control-Allow-Origin").value_or("<absent>"), "*");
    EXPECT_EQ(preflight.status, 204u);
    EXPECT_EQ(preflight.header("Access-Control-Allow-Origin").value_or("<absent>"), "*");
    EXPECT_TRUE(preflight.header("Access-Control-Allow-Methods").has_value());
}

TEST_F(P4PassthroughSession, ARelayInFlightDoesNotHoldUpTheRestOfTheKernel)
{
    // One write is stuck at a proxy that never answers, with a 3 s deadline. A request that needs
    // nothing from the proxy must still be answered at once. The bound is 1 s: an unknown route on
    // loopback answers in milliseconds, so 1 s is two orders of magnitude of slack for a loaded
    // machine, and still a third of the 3 s a blocked io thread would make it wait.
    auto proxy = std::make_unique<FakeProxy>();
    proxy->script(hangs());
    LiveKernel kernel(s_bmv2, proxy->hostAndPort(), deadlines(milliseconds(3000)));

    auto slow = std::async(std::launch::async, [&] {
        return call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    });
    const auto waitFrom = std::chrono::steady_clock::now();
    while (proxy->seen().empty() &&
           std::chrono::steady_clock::now() - waitFrom < milliseconds(2000))
    {
        std::this_thread::sleep_for(milliseconds(10));
    }
    const bool inFlight = !proxy->seen().empty();

    const auto quick = call(kernel.port(), "GET", "/ndt/no_such_route");
    const auto stuck = slow.get();
    std::cout << "    an unrelated request was answered in " << quick.took.count()
              << " ms while a relay was in flight; the relay answered " << stuck.status << " after "
              << stuck.took.count() << " ms" << std::endl;

    ASSERT_TRUE(inFlight) << "the write never reached the fake proxy";
    ASSERT_TRUE(quick.complete) << quick.error;
    EXPECT_EQ(quick.status, 404u);
    EXPECT_LT(quick.took, milliseconds(1000))
        << "a request that needs nothing from the proxy waited " << quick.took.count()
        << " ms behind a relay in flight";
    ASSERT_TRUE(stuck.complete) << stuck.error;
    EXPECT_EQ(stuck.status, 504u) << stuck.body;
}

TEST_F(P4PassthroughSession, ARelayedReplyKeepsTheConnectionForTheNextRequest)
{
    FakeProxy proxy;
    proxy.script(answers(200, std::string("application/json"), R"({"bytes":1})"));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);

    const std::string first = "GET /ndt/p4/counter/c?dpid=1 HTTP/1.1\r\nHost: k\r\n\r\n";
    const std::string second = "GET /ndt/no_such_route HTTP/1.1\r\nHost: k\r\n\r\n";
    // One request at a time on the same connection: the second is written only after the first
    // reply has been read. Asynchronous, so the deadline bounds a reply that never comes.
    const auto replies = exchangeInTurn(kernel.port(), {first, second});
    ASSERT_EQ(replies.size(), 2u);
    EXPECT_EQ(replies[0].status, 200u);
    EXPECT_EQ(replies[0].header("X-NDTwin-Origin").value_or("<absent>"), "proxy");
    EXPECT_EQ(replies[1].status, 404u);
    EXPECT_EQ(replies[1].header("Access-Control-Allow-Origin").value_or("<absent>"), "*")
        << "the second reply came from the ordinary router";
}

TEST_F(P4PassthroughSession, TwoPipelinedRequestsAreBothAnsweredInOrder)
{
    FakeProxy proxy;
    proxy.script(answers(200, std::string("application/json"), R"({"bytes":2})"));
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);

    const auto replies = exchange(kernel.port(),
                                  "GET /ndt/p4/counter/c?dpid=1 HTTP/1.1\r\nHost: k\r\n\r\n"
                                  "GET /ndt/no_such_route HTTP/1.1\r\nHost: k\r\n\r\n",
                                  2);
    ASSERT_EQ(replies.size(), 2u) << "a pipelined request after a relayed one was not answered";
    EXPECT_EQ(replies[0].status, 200u);
    EXPECT_EQ(replies[0].body, R"({"bytes":2})");
    EXPECT_EQ(replies[1].status, 404u);
}

TEST_F(P4PassthroughSession, AClientThatLeavesMidRelayLeavesNothingBehind)
{
    FakeProxy proxy;
    proxy.script(hangs());
    LiveKernel kernel(s_bmv2, proxy.hostAndPort(), deadlines(milliseconds(1000)));

    {
        net::io_context ioc;
        tcp::socket client(ioc);
        client.connect(tcp::endpoint(net::ip::address_v4::loopback(), kernel.port()));
        const std::string request = "POST /ndt/p4/table_entry HTTP/1.1\r\nHost: k\r\n"
                                    "Content-Length: 2\r\n\r\n{}";
        net::write(client, net::buffer(request));
        const auto from = std::chrono::steady_clock::now();
        while (proxy.seen().empty() && std::chrono::steady_clock::now() - from < milliseconds(2000))
        {
            std::this_thread::sleep_for(milliseconds(5));
        }
        ASSERT_EQ(proxy.seen().size(), 1u) << "the relay never reached the fake proxy";
        client.close(); // gone before the relay's 1 s deadline
    }

    // The relay ends at its deadline and its reply goes to a closed connection. A fresh request
    // must still be answered, and both sockets of the abandoned request must then be closed: the
    // relay's connection to the proxy, and the kernel's accepted side of the client's connection.
    // Checked socket by socket rather than as a descriptor count, so one leaked descriptor fails.
    std::this_thread::sleep_for(milliseconds(1200));
    const auto fresh = call(kernel.port(), "GET", "/ndt/no_such_route");
    ASSERT_TRUE(fresh.complete) << fresh.error;
    EXPECT_EQ(fresh.status, 404u);

    std::vector<int> toProxy = socketsConnectedTo(proxy.port());
    std::vector<int> accepted = socketsAcceptedOn(kernel.port());
    const auto from = std::chrono::steady_clock::now();
    while ((!toProxy.empty() || !accepted.empty()) &&
           std::chrono::steady_clock::now() - from < milliseconds(3000))
    {
        std::this_thread::sleep_for(milliseconds(20));
        toProxy = socketsConnectedTo(proxy.port());
        accepted = socketsAcceptedOn(kernel.port());
    }
    EXPECT_TRUE(toProxy.empty()) << toProxy.size() << " socket(s) still connected to the proxy";
    EXPECT_TRUE(accepted.empty()) << accepted.size() << " accepted socket(s) still open";
}

TEST_F(P4PassthroughSession, AKernel500OnTheWriteStillCarriesTheLabClaim)
{
    // A proxy address that is not UTF-8 makes the relay's own error body fail to serialise; the
    // kernel answers 500 -- and that is still a reply of the write.
    LiveKernel kernel(s_bmv2, "bad\xff", kSessionDeadlines);
    const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(res.status, 500u) << res.body;
    EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "kernel");
    const auto header = res.header("X-NDTwin-Lab-Claim");
    ASSERT_TRUE(header.has_value()) << "the write's 500 carries no lab claim";
    EXPECT_TRUE(json::parse(*header).contains("state")) << *header;
}

TEST_F(P4PassthroughSession, AClaimFileThatIsNotUtf8DoesNotTakeDownTheKernelOnTheOtherWrites)
{
    // The twelve writes of the API manual's section 0 put the claim into their JSON body. A note
    // that is not UTF-8 must come back replaced, the status must be what it would have been, and
    // the kernel must still be there for the next request.
    LiveKernel kernel(s_bmv2, refusingHostAndPort(), kSessionDeadlines);
    unsigned control = 0;
    {
        ClaimFile claim("a plain note");
        const auto res = call(kernel.port(), "POST", "/ndt/install_flow_entry", "{not json");
        ASSERT_TRUE(res.complete) << res.error;
        control = res.status;
    }
    ClaimFile claim("\xff\xfe broken");
    const auto write = call(kernel.port(), "POST", "/ndt/install_flow_entry", "{not json");
    ASSERT_TRUE(write.complete) << "the kernel did not answer: " << write.error;
    EXPECT_EQ(write.status, control) << write.body;
    const json body = json::parse(write.body, nullptr, false);
    ASSERT_TRUE(body.is_object()) << write.body;
    ASSERT_TRUE(body.contains("lab_claim")) << write.body;
    EXPECT_NE(body["lab_claim"].value("note", "").find("\xef\xbf\xbd"), std::string::npos)
        << "the bytes that are not UTF-8 should arrive as U+FFFD: " << write.body;
    EXPECT_EQ(body["lab_claim"].value("owner", ""), "app-one") << write.body;

    const auto next = call(kernel.port(), "GET", "/ndt/no_such_route");
    ASSERT_TRUE(next.complete) << "the kernel stopped serving: " << next.error;
    EXPECT_EQ(next.status, 404u);
}

TEST_F(P4PassthroughSession, AnOversizedClaimNoteIsCutInTheHeaderAndTheProxysAnswerStands)
{
    // Five ASCII bytes first, so the first cut lands inside a three-byte character and the cut
    // has to back up to the character's first byte.
    std::string cjk = "note:";
    for (int i = 0; i < 70000; ++i)
    {
        cjk += "\xe6\xb8\xac"; // 測
    }
    for (const std::string& note : {std::string(70000, 'n'), cjk})
    {
        ClaimFile claim(note);
        FakeProxy proxy;
        const std::string proxyBody = R"({"status":"success","dpid":1})";
        proxy.script(answers(200, std::string("application/json"), proxyBody));
        LiveKernel kernel(s_bmv2, proxy.hostAndPort(), kSessionDeadlines);
        const auto res = call(kernel.port(), "POST", "/ndt/p4/table_entry", R"({"dpid":1})");
        ASSERT_TRUE(res.complete) << res.error;

        EXPECT_EQ(res.status, 200u) << res.body;
        EXPECT_EQ(res.body, proxyBody);
        EXPECT_EQ(res.header("X-NDTwin-Origin").value_or("<absent>"), "proxy");
        const auto header = res.header("X-NDTwin-Lab-Claim");
        ASSERT_TRUE(header.has_value()) << "the write's reply lost its lab claim";
        EXPECT_LE(header->size(), HttpSessionP4PassthroughTestPeer::labClaimHeaderCap());
        for (const unsigned char c : res.headerBlock)
        {
            ASSERT_LT(c, 0x80u) << "a header byte at or above 0x80 reached the wire";
        }
        const json parsed = json::parse(*header);
        EXPECT_EQ(parsed.value("truncated", false), true) << *header;
        const std::string cut = parsed.value("note", "");
        EXPECT_FALSE(cut.empty()) << *header;
        EXPECT_EQ(note.compare(0, cut.size(), cut), 0) << "the cut note is not a prefix of it";
        EXPECT_EQ(parsed.value("owner", ""), "app-one") << *header;
    }
}

TEST_F(P4PassthroughSession, ABodyWithAByteThatIsNotUtf8IsA400AndTheKernelStaysUp)
{
    // The parser's own error message quotes the token it stopped at, raw. The kernel's 400 has to
    // carry that message as valid JSON, and the kernel has to be there for the next request.
    LiveKernel kernel(s_bmv2, refusingHostAndPort(), kSessionDeadlines);
    const auto bad = call(kernel.port(), "POST", "/ndt/install_flow_entry", "{\"a\":\"\xff\"}");
    ASSERT_TRUE(bad.complete) << "the kernel did not answer: " << bad.error;
    EXPECT_EQ(bad.status, 400u) << bad.body;
    const json body = json::parse(bad.body, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << "the 400 is not valid JSON: " << bad.body;
    EXPECT_NE(body.value("details", "").find("\xef\xbf\xbd"), std::string::npos)
        << "the byte should arrive as U+FFFD: " << bad.body;

    const auto next = call(kernel.port(), "GET", "/ndt/no_such_route");
    ASSERT_TRUE(next.complete) << "the kernel stopped serving: " << next.error;
    EXPECT_EQ(next.status, 404u);
}

TEST_F(P4PassthroughSession, AQueryValueWithAByteThatIsNotUtf8GetsItsOwnRefusal)
{
    // The request line may carry any byte above 0x20, and get_nickname echoes a bad dpid back.
    LiveKernel kernel(s_bmv2, refusingHostAndPort(), kSessionDeadlines);
    const auto res = call(kernel.port(), "GET", "/ndt/get_nickname?dpid=\xff");
    ASSERT_TRUE(res.complete) << res.error;
    EXPECT_EQ(res.status, 400u) << res.body;
    const json body = json::parse(res.body, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body;
    EXPECT_EQ(body.value("error", ""), "invalid dpid") << res.body;
    EXPECT_EQ(body.value("dpid", ""), "\xef\xbf\xbd") << res.body;
}

TEST_F(P4PassthroughSession, AnExceptionMessageCarryingRequestBytesIsA500ThatIsValidJson)
{
    // set_switches_power_state hands its raw ?ip= to the power manager, whose MININET lookup
    // parses it and throws "Invalid IP address: <ip>" -- an exception that is not the JSON
    // library's, so it reaches buildResponse's last catch clause with the request's bytes in it.
    // A real manager over the BMv2 fixture, never started: the lookup is all this case reaches.
    auto power = std::make_shared<DeviceConfigurationAndPowerManager>(
        s_bmv2, utils::MININET, "127.0.0.1", nullptr);
    LiveKernel kernel(s_bmv2, refusingHostAndPort(), kSessionDeadlines, 4, power);
    const auto res =
        call(kernel.port(), "POST", "/ndt/set_switches_power_state?ip=\xff&action=off", "");
    ASSERT_TRUE(res.complete) << "the kernel did not answer: " << res.error;
    EXPECT_EQ(res.status, 500u) << res.body;
    const json body = json::parse(res.body, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << "the 500 is not valid JSON: " << res.body;
    EXPECT_NE(body.value("details", "").find("\xef\xbf\xbd"), std::string::npos)
        << "the byte should arrive as U+FFFD: " << res.body;

    const auto next = call(kernel.port(), "GET", "/ndt/no_such_route");
    ASSERT_TRUE(next.complete) << "the kernel stopped serving: " << next.error;
    EXPECT_EQ(next.status, 404u);
}
