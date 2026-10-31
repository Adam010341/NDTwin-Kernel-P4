// [Co-developed with claude code -- Adam]
#pragma once

#include <chrono>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

#include <boost/asio/any_io_executor.hpp>
#include <boost/beast/http/verb.hpp>

/**
 * @brief The kernel's pass-through routes to the P4 proxy's own P4 reads and writes.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ### What this is
 *
 * The P4 proxy serves five routes that speak P4 rather than OpenFlow: one table-entry write, one
 * table-entry read, and the counter, direct-counter and register reads. An app talks to the kernel
 * on :8000, so the kernel serves the same five under `/ndt/p4/...` and relays each request to the
 * proxy it already polls on a P4 fabric (AppConfig::P4_PROXY_IP_AND_PORT):
 *
 *     POST /ndt/p4/table_entry          -> POST /p4/table_entry
 *     GET  /ndt/p4/table_entry?...      -> GET  /p4/table_entry?...
 *     GET  /ndt/p4/counter/<name>?...   -> GET  /p4/counter/<name>?...
 *     GET  /ndt/p4/direct_counter/<n>?. -> GET  /p4/direct_counter/<n>?...
 *     GET  /ndt/p4/register/<name>?...  -> GET  /p4/register/<name>?...
 *
 * ### What the kernel does and does not do
 *
 * It relays. The method, the query string and the body go out as they came in, and the proxy's
 * status code, content type and body come back as the proxy wrote them -- a 409 `owned by NDTwin`
 * or a 503 `switch busy` reaches the app byte for byte. Nothing here parses a P4 name, a match or
 * a value: what those mean is the pipeline's business, and the proxy is the only component that
 * has read the pipeline's p4info.
 *
 * What the kernel does decide is which paths it relays. The five above are the whole list; any
 * other path under `/ndt/p4/` is answered here and goes nowhere. Relaying whatever path came in
 * would make :8000 an open door to every route on :8081, the restart and readopt routes
 * included. A `<name>` must be one plain path segment, so `..` and an encoded `/` cannot climb
 * out of the route it was sent to.
 *
 * ### Telling the kernel's answers from the proxy's
 *
 * Every reply carries `X-NDTwin-Origin`: `proxy` when the status and body are the proxy's,
 * `kernel` when the kernel answered itself (not a P4 fabric, not a relayed path, the proxy could
 * not be reached, did not answer in time, or answered something unreadable). A kernel answer's
 * body is a JSON object with `"origin": "kernel"`; the proxy's own error bodies are FastAPI's
 * `{"detail": ...}`.
 *
 * ### The relay never blocks a kernel thread
 *
 * The kernel serves :8000 from one io_context whose concurrency hint is 1, so a handler that
 * blocks holds up every other session for as long as it blocks. The relay is therefore made of
 * asynchronous operations on the caller's executor (respondAsync, forwardToProxyAsync), and the
 * session writes its reply from the completion handler.
 */
namespace p4passthrough
{

/**
 * @brief The deadline for POST and GET /ndt/p4/table_entry, whose slowest answers take longer than
 *        one proxy RPC deadline.
 *
 * The proxy gives every P4Runtime call RPC_TIMEOUT_S (5 s, p4_proxy/proxy_agent/p4_client.py).
 *
 * A table read waits up to TABLE_READ_WAIT_S (3 s) for one of the switch's read slots and then
 * makes two reads, the entries and the default entry, at RPC_TIMEOUT_S each: TABLE_READ_WORST_S,
 * 13 s (both in p4_proxy/proxy_agent/api_routes.py). That leaves 2 s of this deadline for the
 * proxy to convert the entries and send them; how long that takes on a large table is not
 * bounded or measured.
 *
 * A table-entry write first waits for a thread in the proxy's shared pool (`run_in_threadpool`,
 * which the proxy's other routes that run on it, such as the counter and register reads, the
 * flow-entry writes, the multicast-group writes and `/stats/flow`, also use), and that wait has no
 * bound. Measured on bmv2 1.15.5 on 2026-10-30, with forty table reads stuck on one stopped switch
 * while table reads still used the shared pool, POSTs to healthy switches waited up to about 5 s
 * (median about 0.01 s). Table reads have since moved to their own per-switch pool; forty stuck
 * counter or register reads would hold the shared pool the same way, which has not been measured.
 * The write then waits up to TABLE_ENTRY_LOCK_TIMEOUT_S (= RPC_TIMEOUT_S) for the switch's lock,
 * makes its write at RPC_TIMEOUT_S, and fsyncs the journal. So the 15 s covers the waits those
 * constants bound (10 s for a write, 13 s for a read), and leaves about 5 s for the POST's wait
 * for a pool thread; the GET does not use that pool. It does not cover every case. A POST that
 * runs out of time is answered by the kernel with a `504`. With `request_sent: true` the proxy
 * may still be working on the write, because nothing stops it when the kernel gives up, so the
 * write can land later, at a time the kernel cannot bound.
 *
 * A shorter deadline would turn the proxy's own `503 switch busy`, or a write that did land, into
 * a kernel 504 that says nothing about the switch.
 * p4_proxy/tests/test_kernel_deadline_covers_table_read.py fails if the read's or the write's
 * bounded waits reach this number.
 */
inline constexpr int kTwoRpcDeadlineSeconds = 15;

/**
 * @brief The deadline for the counter, direct-counter and register reads, whose slowest legitimate
 *        answer is one proxy RPC deadline (5 s), plus the same 5 s for the proxy's thread pool.
 *
 * Shorter than the table routes' so that a read the proxy has given up on is reported 5 s sooner,
 * and an app polling counters is not held for a write's budget.
 */
inline constexpr int kOneRpcDeadlineSeconds = 10;

/// The two deadlines a session relays with. The defaults are the deployment's; a test shortens
/// them.
struct Deadlines
{
    std::chrono::milliseconds twoRpc{std::chrono::seconds(kTwoRpcDeadlineSeconds)};
    std::chrono::milliseconds oneRpc{std::chrono::seconds(kOneRpcDeadlineSeconds)};
};

/// What matchRoute decided about one request.
enum class RouteMatch
{
    /// The target is not under /ndt/p4 at all.
    NotP4Route,
    /// One of the five routes, with the method it takes: relay it.
    Forward,
    /// One of the five paths, with a method it does not take.
    MethodNotAllowed,
    /// Under /ndt/p4, but not one of the five paths.
    NotAllowlisted,
};

/// Which of the two deadlines a route gets.
enum class DeadlineClass
{
    TwoRpc,
    OneRpc,
};

struct Route
{
    RouteMatch match = RouteMatch::NotP4Route;
    /// The proxy's target -- path and query, exactly as received minus the `/ndt` prefix. Only
    /// set for Forward.
    std::string proxyTarget;
    /// The method(s) the path takes, for the Allow header of a 405.
    std::string allow;
    /// True for POST /ndt/p4/table_entry, the one route that writes to a switch.
    bool isWrite = false;
    DeadlineClass deadline = DeadlineClass::TwoRpc;
};

/// True for "/ndt/p4", "/ndt/p4?..." and anything under "/ndt/p4/". The session's test.
bool isP4PassthroughTarget(std::string_view target);

/// Decides whether a request is relayed, and to which proxy target.
Route matchRoute(boost::beast::http::verb method, std::string_view target);

/// What happened when one request was relayed.
struct ProxyReply
{
    enum class Outcome
    {
        /// The proxy sent a complete HTTP reply, whatever its status.
        Answered,
        /// No connection was made: the address did not resolve, or nothing accepted.
        NotConnected,
        /// Connected, and the connection ended or failed before a complete reply.
        NoCompleteReply,
        /// Bytes came back that are not an HTTP reply this relay can hand on: malformed, or
        /// larger than kMaxReplyBytes.
        Unreadable,
        /// The deadline ran out before a complete reply.
        TimedOut,
        /// The kernel itself failed while relaying (an exception in one of the relay's own
        /// steps). Answered as a kernel 500.
        Failed,
    };

    Outcome outcome = Outcome::NotConnected;
    /// True once a connection to the proxy was made. False means nothing reached the proxy.
    bool connected = false;
    /// True once the whole request had been written to the connection. A request that was not
    /// completely written cannot have been acted on; one that was may have been.
    bool requestSent = false;
    unsigned status = 0;
    /// The proxy's Content-Type, or nullopt when its reply had none.
    std::optional<std::string> contentType;
    std::string body;
    /// For any outcome other than Answered: what failed, in words.
    std::string error;
};

/// A relayed reply larger than this is reported as unreadable rather than buffered. A
/// whole-table direct-counter read of a 1024-entry table is a few hundred kilobytes.
inline constexpr std::uint64_t kMaxReplyBytes = 64ull * 1024 * 1024;

/// A relayed reply whose header is larger than this is reported as unreadable. The proxy's own
/// headers are a few hundred bytes.
inline constexpr std::uint32_t kMaxReplyHeaderBytes = 8u * 1024;

using ProxyReplyHandler = std::function<void(ProxyReply)>;

/**
 * @brief Sends one request to `hostAndPort` and reads one reply, all within `timeout`.
 *
 * Asynchronous: returns at once, and `done` is called exactly once, from `executor`, never before
 * this function has returned, when the reply is in or the deadline has passed. One deadline covers
 * the name lookup, the connect, the write and the read together. An exception in one of the
 * relay's own steps becomes Outcome::Failed rather than leaving the io_context.
 */
void forwardToProxyAsync(const boost::asio::any_io_executor& executor,
                         const std::string& hostAndPort,
                         boost::beast::http::verb method,
                         const std::string& target,
                         std::string body,
                         const std::optional<std::string>& contentType,
                         std::chrono::milliseconds timeout,
                         ProxyReplyHandler done);

/// The reply the kernel sends back for one /ndt/p4 request.
struct Reply
{
    unsigned status = 0;
    /// nullopt: send no Content-Type (the proxy sent none).
    std::optional<std::string> contentType;
    std::string body;
    /// `proxy` or `kernel`; becomes the X-NDTwin-Origin header.
    std::string origin;
    /// Non-empty only on a 405: the Allow header.
    std::string allow;
    /// True for the write route, on every reply, refusals included: the kernel adds the lab
    /// claim to it as a header (the body is the proxy's, and is not the kernel's to edit).
    bool labClaimBearing = false;
};

using ReplyHandler = std::function<void(Reply)>;

/**
 * @brief The whole decision for one request under /ndt/p4: route, fabric, relay.
 *
 * Asynchronous: returns at once, and `done` is called exactly once, from `executor` -- also for the
 * answers that need no relay, so a caller never sees its handler run before this returns. A reply
 * that cannot be built (an exception while building it) is delivered as a kernel 500, through the
 * same `done`.
 *
 * @param p4Fabric  Whether the loaded topology has a P4 switch. False answers 501 and relays
 *                  nothing.
 */
void respondAsync(const boost::asio::any_io_executor& executor,
                  boost::beast::http::verb method,
                  std::string_view target,
                  std::string body,
                  const std::optional<std::string>& contentType,
                  bool p4Fabric,
                  const std::string& proxyHostAndPort,
                  const Deadlines& deadlines,
                  ReplyHandler done);

/**
 * @brief respondAsync run to completion on a private io_context, for callers with no event loop
 *        of their own (tests, tools). Blocks the calling thread; never call it from a kernel
 *        io thread.
 */
Reply respond(boost::beast::http::verb method,
              std::string_view target,
              const std::string& body,
              const std::optional<std::string>& contentType,
              bool p4Fabric,
              const std::string& proxyHostAndPort,
              const Deadlines& deadlines);

} // namespace p4passthrough
