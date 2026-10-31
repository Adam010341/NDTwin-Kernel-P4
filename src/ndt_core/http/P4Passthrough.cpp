// [Co-developed with claude code -- Adam]
//
// The kernel's /ndt/p4/... routes: which paths are relayed, the asynchronous HTTP client that
// relays them, and the kernel's own answers when it does not. The reasoning is in the header;
// this file is the mechanism.
//
// A separate translation unit from HttpSession.cpp, which costs about 1.6 GB and a hundred
// CPU-seconds to compile here; everything that can be decided without a session lives here.

#include "ndt_core/http/P4Passthrough.hpp"

#include "utils/FdHygiene.hpp"
#include "utils/Logger.hpp"

#include <boost/asio/dispatch.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/post.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/strand.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>

#include <array>
#include <memory>
#include <nlohmann/json.hpp>
#include <utility>

namespace p4passthrough
{

namespace
{

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;
using json = nlohmann::json;

constexpr std::string_view kKernelPrefix = "/ndt";

/// The kernel's 500 for a reply it could not build. A literal: building it must not be able to
/// fail the way the reply it replaces did.
Reply
internalErrorReply(bool isWrite)
{
    Reply reply;
    reply.status = 500;
    reply.contentType = "application/json";
    reply.body = R"({"error":"Internal server error","message":"the kernel failed while )"
                 R"(relaying this request; see the kernel log","origin":"kernel"})";
    reply.origin = "kernel";
    reply.labClaimBearing = isWrite;
    return reply;
}
constexpr std::string_view kP4Root = "/ndt/p4";
constexpr std::string_view kTableEntryPath = "/p4/table_entry";

/// The three read routes that take an object name as their last path segment.
constexpr std::array<std::string_view, 3> kNamedReadPrefixes = {
    "/p4/counter/",
    "/p4/direct_counter/",
    "/p4/register/",
};

std::string_view
pathOf(std::string_view target)
{
    const auto q = target.find('?');
    return q == std::string_view::npos ? target : target.substr(0, q);
}

/// One plain path segment: non-empty, not a dot segment, and nothing that could become a `/` on
/// the proxy's side. The proxy's server percent-decodes the path before routing, so `%2F` is
/// refused along with `/`; no P4 name needs percent-encoding.
bool
isPlainSegment(std::string_view name)
{
    if (name.empty() || name == "." || name == "..")
    {
        return false;
    }
    return name.find_first_of("/%\\") == std::string_view::npos;
}

json
routeList()
{
    return json::array({"POST /ndt/p4/table_entry",
                        "GET /ndt/p4/table_entry",
                        "GET /ndt/p4/counter/{name}",
                        "GET /ndt/p4/direct_counter/{name}",
                        "GET /ndt/p4/register/{name}"});
}

Reply
kernelReply(unsigned status, json body)
{
    body["origin"] = "kernel";
    Reply reply;
    reply.status = status;
    reply.contentType = "application/json";
    reply.body = body.dump();
    reply.origin = "kernel";
    return reply;
}

std::string
secondsText(std::chrono::milliseconds timeout)
{
    const auto ms = timeout.count();
    if (ms % 1000 == 0)
    {
        return std::to_string(ms / 1000) + " s";
    }
    return std::to_string(ms) + " ms";
}

/// A reply that is not HTTP, or one past the size limit: Beast's own parse errors, apart from the
/// two that mean the connection ended (before any byte, or part-way through a reply).
bool
isUnreadableReply(const beast::error_code& ec)
{
    return ec.category() == http::make_error_code(http::error::bad_version).category() &&
           ec != http::error::end_of_stream && ec != http::error::partial_message;
}

/**
 * One relayed request: lookup, connect, write, read, each started from the previous one's
 * completion handler. All of its handlers run on one strand of the caller's executor, so the
 * lookup deadline and the lookup itself can never complete on two threads at once.
 */
class RelayOp : public std::enable_shared_from_this<RelayOp>
{
  public:
    RelayOp(const net::any_io_executor& executor,
            std::string hostAndPort,
            http::verb method,
            std::string target,
            std::string body,
            std::optional<std::string> contentType,
            std::chrono::milliseconds timeout,
            ProxyReplyHandler done)
        : m_strand(net::make_strand(executor)),
          m_resolver(m_strand),
          m_lookupTimer(m_strand),
          m_stream(m_strand),
          m_hostAndPort(std::move(hostAndPort)),
          m_method(method),
          m_target(std::move(target)),
          m_body(std::move(body)),
          m_contentType(std::move(contentType)),
          m_timeout(timeout),
          m_deadline(std::chrono::steady_clock::now() + timeout),
          m_done(std::move(done))
    {
    }

    void start()
    {
        // post, not dispatch: called from a kernel io thread, dispatch would run the lookup -- and,
        // for an address that does not parse, the whole relay and its completion -- inline,
        // before forwardToProxyAsync had returned, and outside every handler's guard below.
        net::post(m_strand, [self = shared_from_this()] {
            self->guarded([&] { self->beginLookup(); });
        });
    }

  private:
    /// Runs one step of the relay. An exception becomes Outcome::Failed, delivered once like any
    /// other outcome; one thrown by the caller's own handler, which runs inside finish(), is
    /// logged and dropped, because that handler has already been given its one call.
    template <typename Step>
    void guarded(Step&& step)
    {
        try
        {
            step();
        }
        catch (const std::exception& e)
        {
            fail(e.what());
        }
        catch (...)
        {
            fail("unknown exception");
        }
    }

    void fail(const char* what)
    {
        if (m_finished)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "P4 pass-through: the reply handler threw: {}",
                                what);
            return;
        }
        finish(ProxyReply::Outcome::Failed, what);
    }

    void beginLookup()
    {
        const auto colon = m_hostAndPort.rfind(':');
        if (colon == std::string::npos || colon == 0 || colon + 1 == m_hostAndPort.size())
        {
            finish(ProxyReply::Outcome::NotConnected,
                   "the proxy address '" + m_hostAndPort + "' is not host:port");
            return;
        }
        // The lookup is inside the deadline. Asio runs every lookup of this io_context on one
        // resolver thread of its own and cannot interrupt getaddrinfo, so a lookup that outlives
        // the deadline is abandoned, not cancelled: the reply is a 504 at the deadline and the
        // late result is dropped. While one getaddrinfo hangs, every later relay's lookup queues
        // behind it on that thread, so each of them is a 504 at its own deadline too.
        m_lookupTimer.expires_at(m_deadline);
        m_lookupTimer.async_wait([self = shared_from_this()](beast::error_code ec) {
            if (!ec)
            {
                self->guarded([&] { self->onLookupDeadline(); });
            }
        });
        m_resolver.async_resolve(
            m_hostAndPort.substr(0, colon),
            m_hostAndPort.substr(colon + 1),
            [self = shared_from_this()](beast::error_code ec, tcp::resolver::results_type r) {
                self->guarded([&] { self->onResolve(ec, std::move(r)); });
            });
    }

    void onLookupDeadline()
    {
        if (m_lookupDone)
        {
            return;
        }
        m_resolver.cancel();
        finish(ProxyReply::Outcome::TimedOut,
               "could not resolve " + m_hostAndPort + " within " + secondsText(m_timeout));
    }

    void onResolve(beast::error_code ec, tcp::resolver::results_type results)
    {
        m_lookupDone = true;
        m_lookupTimer.cancel();
        if (m_finished)
        {
            return;
        }
        if (ec)
        {
            finish(ProxyReply::Outcome::NotConnected,
                   "could not resolve " + m_hostAndPort + ": " + ec.message());
            return;
        }
        m_endpoints = std::move(results);
        m_next = m_endpoints.begin();
        connectNext();
    }

    void connectNext()
    {
        while (m_next != m_endpoints.end())
        {
            const tcp::endpoint endpoint = m_next->endpoint();
            ++m_next;
            auto& socket = m_stream.socket();
            beast::error_code ignored;
            if (socket.is_open())
            {
                socket.close(ignored);
            }
            beast::error_code openEc;
            socket.open(endpoint.protocol(), openEc);
            if (openEc)
            {
                m_connectEc = openEc;
                continue;
            }
            // The kernel forks curl from other threads. Without this, a child forked while this
            // request is in flight holds the connection to the proxy open after the kernel has
            // finished with it. Asio offers no SOCK_CLOEXEC at open, so there is a short window
            // between open and this call; what leaks through it is one client connection, not a
            // listening port.
            if (!utils::setCloseOnExec(socket.native_handle()))
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "could not mark the connection to the P4 proxy close-on-exec; "
                                   "a child process may inherit it and hold it open");
            }

            m_stream.expires_at(m_deadline);
            m_stream.async_connect(endpoint, [self = shared_from_this()](beast::error_code e) {
                self->guarded([&] { self->onConnect(e); });
            });
            return;
        }
        finish(ProxyReply::Outcome::NotConnected, m_connectEc.message());
    }

    void onConnect(beast::error_code ec)
    {
        if (ec == beast::error::timeout)
        {
            finish(ProxyReply::Outcome::TimedOut, "no connection within " + secondsText(m_timeout));
            return;
        }
        if (ec)
        {
            m_connectEc = ec;
            connectNext();
            return;
        }
        m_out.connected = true;

        m_req = http::request<http::string_body>{m_method, m_target, 11};
        m_req.set(http::field::host, m_hostAndPort);
        m_req.set(http::field::user_agent, "ndtwin-kernel");
        if (m_contentType)
        {
            m_req.set(http::field::content_type, *m_contentType);
        }
        m_req.keep_alive(false);
        m_req.body() = std::move(m_body);
        m_req.prepare_payload();

        m_stream.expires_at(m_deadline);
        http::async_write(
            m_stream, m_req, [self = shared_from_this()](beast::error_code e, std::size_t) {
                self->guarded([&] { self->onWrite(e); });
            });
    }

    void onWrite(beast::error_code ec)
    {
        if (ec)
        {
            finish(ec == beast::error::timeout ? ProxyReply::Outcome::TimedOut
                                               : ProxyReply::Outcome::NoCompleteReply,
                   "the request could not be sent: " + ec.message());
            return;
        }
        m_out.requestSent = true;

        m_parser.emplace();
        m_parser->body_limit(kMaxReplyBytes);
        m_parser->header_limit(kMaxReplyHeaderBytes);
        m_stream.expires_at(m_deadline);
        http::async_read(m_stream,
                         m_buffer,
                         *m_parser,
                         [self = shared_from_this()](beast::error_code e, std::size_t) {
                             self->guarded([&] { self->onRead(e); });
                         });
    }

    void onRead(beast::error_code ec)
    {
        if (ec == beast::error::timeout)
        {
            finish(ProxyReply::Outcome::TimedOut,
                   "no complete reply within " + secondsText(m_timeout));
            return;
        }
        if (ec && isUnreadableReply(ec))
        {
            finish(ProxyReply::Outcome::Unreadable, unreadableReason(ec));
            return;
        }
        if (ec)
        {
            finish(ProxyReply::Outcome::NoCompleteReply,
                   "the connection ended without a complete reply: " + ec.message());
            return;
        }

        auto res = m_parser->release();
        m_out.status = res.result_int();
        const auto ct = res.find(http::field::content_type);
        if (ct != res.end())
        {
            m_out.contentType = std::string(ct->value());
        }
        m_out.body = std::move(res.body());
        finish(ProxyReply::Outcome::Answered, {});
    }

    void finish(ProxyReply::Outcome outcome, std::string error)
    {
        if (m_finished)
        {
            return;
        }
        m_finished = true;
        beast::error_code ignored;
        m_stream.socket().shutdown(tcp::socket::shutdown_both, ignored);
        m_stream.socket().close(ignored);

        m_out.outcome = outcome;
        m_out.error = std::move(error);
        ProxyReplyHandler done = std::move(m_done);
        // Inside the caller's guard: if `done` throws, guarded() logs it and does not call it
        // again.
        done(std::move(m_out));
    }

    static std::string unreadableReason(const beast::error_code& ec)
    {
        if (ec == http::error::header_limit)
        {
            return "its header is larger than the " + std::to_string(kMaxReplyHeaderBytes / 1024) +
                   " KiB the kernel reads (" + ec.message() + ")";
        }
        if (ec == http::error::body_limit)
        {
            return "it is larger than the " +
                   std::to_string(kMaxReplyBytes / (1024 * 1024)) + " MiB the kernel reads (" +
                   ec.message() + ")";
        }
        return ec.message();
    }

    net::strand<net::any_io_executor> m_strand;
    tcp::resolver m_resolver;
    net::steady_timer m_lookupTimer;
    beast::tcp_stream m_stream;

    std::string m_hostAndPort;
    http::verb m_method;
    std::string m_target;
    std::string m_body;
    std::optional<std::string> m_contentType;
    std::chrono::milliseconds m_timeout;
    std::chrono::steady_clock::time_point m_deadline;
    ProxyReplyHandler m_done;

    bool m_lookupDone = false;
    bool m_finished = false;
    tcp::resolver::results_type m_endpoints;
    tcp::resolver::results_type::const_iterator m_next;
    beast::error_code m_connectEc = net::error::host_not_found;
    http::request<http::string_body> m_req;
    beast::flat_buffer m_buffer;
    std::optional<http::response_parser<http::string_body>> m_parser;
    ProxyReply m_out;
};

const char*
sentClause(const ProxyReply& proxy)
{
    if (proxy.requestSent)
    {
        return "; the request was sent, so whether it took effect is not known";
    }
    return proxy.connected ? "; the request was not completely sent" : "; the request was not sent";
}

Reply
replyFor(ProxyReply proxy, const std::string& proxyHostAndPort, std::chrono::milliseconds timeout)
{
    Reply reply;
    switch (proxy.outcome)
    {
    case ProxyReply::Outcome::Answered:
        reply.status = proxy.status;
        reply.contentType = std::move(proxy.contentType);
        reply.body = std::move(proxy.body);
        reply.origin = "proxy";
        break;
    case ProxyReply::Outcome::NotConnected:
        reply = kernelReply(502,
                            {{"error", "P4 proxy unreachable"},
                             {"message",
                              "the kernel could not connect to the P4 proxy at " +
                                  proxyHostAndPort + " (" + proxy.error +
                                  "); the request was not sent"},
                             {"proxy", proxyHostAndPort},
                             {"request_sent", false}});
        break;
    case ProxyReply::Outcome::NoCompleteReply:
        reply = kernelReply(502,
                            {{"error", "no reply from P4 proxy"},
                             {"message",
                              "the kernel reached the P4 proxy at " + proxyHostAndPort +
                                  " but got no complete reply (" + proxy.error + ")" +
                                  sentClause(proxy)},
                             {"proxy", proxyHostAndPort},
                             {"request_sent", proxy.requestSent}});
        break;
    case ProxyReply::Outcome::Unreadable:
        reply = kernelReply(502,
                            {{"error", "P4 proxy reply unreadable"},
                             {"message",
                              "the P4 proxy at " + proxyHostAndPort +
                                  " answered, but the kernel could not read its reply: " +
                                  proxy.error + sentClause(proxy)},
                             {"proxy", proxyHostAndPort},
                             {"request_sent", proxy.requestSent}});
        break;
    case ProxyReply::Outcome::TimedOut:
        reply = kernelReply(504,
                            {{"error", "P4 proxy timed out"},
                             {"message",
                              "the P4 proxy at " + proxyHostAndPort + " did not answer within " +
                                  secondsText(timeout) + " (" + proxy.error + ")" +
                                  sentClause(proxy)},
                             {"proxy", proxyHostAndPort},
                             {"timeout_ms", timeout.count()},
                             {"request_sent", proxy.requestSent}});
        break;
    case ProxyReply::Outcome::Failed:
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "P4 pass-through failed while relaying to {}: {}",
                            proxyHostAndPort,
                            proxy.error);
        reply = internalErrorReply(false);
        break;
    }
    return reply;
}

} // namespace

bool
isP4PassthroughTarget(std::string_view target)
{
    const std::string_view path = pathOf(target);
    return path == kP4Root ||
           (path.starts_with(kP4Root) && path.size() > kP4Root.size() &&
            path[kP4Root.size()] == '/');
}

Route
matchRoute(http::verb method, std::string_view target)
{
    Route route;
    if (!isP4PassthroughTarget(target))
    {
        return route;
    }
    const std::string_view path = pathOf(target).substr(kKernelPrefix.size());

    if (path == kTableEntryPath)
    {
        if (method != http::verb::post && method != http::verb::get)
        {
            route.match = RouteMatch::MethodNotAllowed;
            route.allow = "GET, POST";
            return route;
        }
        route.isWrite = (method == http::verb::post);
        route.deadline = DeadlineClass::TwoRpc;
    }
    else
    {
        bool named = false;
        for (const std::string_view prefix : kNamedReadPrefixes)
        {
            if (path.starts_with(prefix))
            {
                if (!isPlainSegment(path.substr(prefix.size())))
                {
                    route.match = RouteMatch::NotAllowlisted;
                    return route;
                }
                named = true;
                break;
            }
        }
        if (!named)
        {
            route.match = RouteMatch::NotAllowlisted;
            return route;
        }
        if (method != http::verb::get)
        {
            route.match = RouteMatch::MethodNotAllowed;
            route.allow = "GET";
            return route;
        }
        route.deadline = DeadlineClass::OneRpc;
    }

    route.match = RouteMatch::Forward;
    // The query string goes out byte for byte, including an empty one: what it means is the
    // proxy's to decide.
    route.proxyTarget = std::string(target.substr(kKernelPrefix.size()));
    return route;
}

void
forwardToProxyAsync(const net::any_io_executor& executor,
                    const std::string& hostAndPort,
                    http::verb method,
                    const std::string& target,
                    std::string body,
                    const std::optional<std::string>& contentType,
                    std::chrono::milliseconds timeout,
                    ProxyReplyHandler done)
{
    std::make_shared<RelayOp>(executor,
                              hostAndPort,
                              method,
                              target,
                              std::move(body),
                              contentType,
                              timeout,
                              std::move(done))
        ->start();
}

void
respondAsync(const net::any_io_executor& executor,
             http::verb method,
             std::string_view target,
             std::string body,
             const std::optional<std::string>& contentType,
             bool p4Fabric,
             const std::string& proxyHostAndPort,
             const Deadlines& deadlines,
             ReplyHandler done)
{
    const Route route = matchRoute(method, target);

    // The answers that need no relay are still delivered through the executor, so `done` never
    // runs before this function has returned.
    auto deliver = [&executor, &done](Reply reply) {
        net::post(executor, [done = std::move(done), reply = std::move(reply)]() mutable {
            try
            {
                done(std::move(reply));
            }
            catch (const std::exception& e)
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(),
                                    "P4 pass-through: the reply handler threw: {}",
                                    e.what());
            }
        });
    };

    if (route.match == RouteMatch::NotP4Route || route.match == RouteMatch::NotAllowlisted)
    {
        deliver(kernelReply(404,
                            {{"error", "not a P4 pass-through route"},
                             {"message",
                              "the kernel relays only the routes listed in `routes` to the P4 "
                              "proxy; this request was not sent anywhere"},
                             {"routes", routeList()}}));
        return;
    }
    if (route.match == RouteMatch::MethodNotAllowed)
    {
        Reply reply = kernelReply(405,
                                  {{"error", "method not allowed"},
                                   {"message",
                                    "this path takes " + route.allow +
                                        "; this request was not sent anywhere"}});
        reply.allow = route.allow;
        deliver(std::move(reply));
        return;
    }
    if (!p4Fabric)
    {
        Reply reply = kernelReply(
            501,
            {{"error", "not a P4 fabric"},
             {"message",
              "the /ndt/p4 routes exist only on a P4 fabric; the topology this kernel loaded "
              "has no P4 switch, so nothing was sent to a proxy"}});
        reply.labClaimBearing = route.isWrite;
        deliver(std::move(reply));
        return;
    }

    const std::chrono::milliseconds timeout =
        route.deadline == DeadlineClass::OneRpc ? deadlines.oneRpc : deadlines.twoRpc;
    forwardToProxyAsync(
        executor,
        proxyHostAndPort,
        method,
        route.proxyTarget,
        std::move(body),
        contentType,
        timeout,
        [done = std::move(done), isWrite = route.isWrite, proxyHostAndPort, timeout](
            ProxyReply proxy) {
            // Building the reply can throw (the kernel's own JSON, from strings it did not
            // write); that becomes the kernel's 500, through the same one call of `done`.
            Reply reply;
            try
            {
                reply = replyFor(std::move(proxy), proxyHostAndPort, timeout);
                reply.labClaimBearing = isWrite;
            }
            catch (const std::exception& e)
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(),
                                    "P4 pass-through could not build its reply: {}",
                                    e.what());
                reply = internalErrorReply(isWrite);
            }
            done(std::move(reply));
        });
}

Reply
respond(http::verb method,
        std::string_view target,
        const std::string& body,
        const std::optional<std::string>& contentType,
        bool p4Fabric,
        const std::string& proxyHostAndPort,
        const Deadlines& deadlines)
{
    net::io_context ioc;
    std::optional<Reply> out;
    respondAsync(ioc.get_executor(),
                 method,
                 target,
                 body,
                 contentType,
                 p4Fabric,
                 proxyHostAndPort,
                 deadlines,
                 [&out](Reply reply) { out = std::move(reply); });
    ioc.run();
    if (!out)
    {
        return kernelReply(500, {{"error", "the relay finished without a reply"}});
    }
    return std::move(*out);
}

} // namespace p4passthrough
