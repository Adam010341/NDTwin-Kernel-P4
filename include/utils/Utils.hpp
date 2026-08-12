#pragma once

#include "utils/Logger.hpp"
#include <arpa/inet.h>
#include <array>
#include <cerrno>
#include <string_view>
#include <cstring>
#include <sys/wait.h>
#include <boost/asio/connect.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/beast/version.hpp>
#include <boost/url.hpp>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <optional>
#include <cctype>
#include <stdexcept>
#include <string>
#include <vector>

/**
 * @brief Common utility helpers used across NDTwin.
 *
 * This header provides small, header-only helpers for:
 *  - deployment mode flags (MININET vs TESTBED),
 *  - IPv4 and MAC address conversions,
 *  - shell command execution (popen),
 *  - HTTPS POST helper (Boost.Beast),
 *  - timestamp helpers and formatting.
 *
 * @warning Some functions (execCommand, httpsPost) perform I/O and may throw.
 * @warning localtime is a non-thread-safe libc API. (ipToString uses inet_ntop and is safe.)
 *          Prefer thread-safe alternatives if called from multiple threads.
 */
namespace utils
{

/**
 * @brief Indicates where NDTwin is running.
 *
 * MININET: simulated environment (Mininet/OVS).
 * TESTBED: physical hardware testbed.
 */
enum DeploymentMode
{
    MININET = 1,
    TESTBED = 2
};

/**
 * @brief Convert an IPv4 address to dotted-decimal string.
 *
 * @param ip IPv4 address (expected in network byte order, i.e., in_addr.s_addr format).
 * @return Dotted string (e.g., "10.10.10.12").
 * @throws std::runtime_error if conversion fails.
 *
 * [Co-developed with claude code -- Adam]
 * Uses inet_ntop rather than inet_ntoa. This is a portability fix, not a bug fix, and the
 * distinction is worth recording because a review claimed otherwise.
 *
 * POSIX does not require inet_ntoa to be thread-safe, and this header used to carry an @warning
 * saying it was not -- with 62 call sites across threads, that reads alarming. Measured on this
 * platform (glibc 2.39): inet_ntoa's buffer is thread-local, so each thread gets its own and the
 * race cannot happen. A concurrency test with eight threads and 160,000 conversions passes against
 * inet_ntoa unchanged, which is how the overclaim was caught. There was never a segfault risk
 * either: the buffer is always valid.
 *
 * So the switch buys portability off a glibc-specific guarantee, and removes a warning that was
 * frightening and wrong. inet_ntop writes into a caller-supplied buffer, so there is nothing
 * shared under any libc.
 */
inline std::string
ipToString(uint32_t ip)
{
    struct in_addr addr;
    addr.s_addr = ip;
    char buf[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &addr, buf, sizeof(buf)))
    {
        throw std::runtime_error("inet_ntop failed");
    }
    return std::string(buf);
}

/**
 * @brief Convert a vector of IPv4 addresses to dotted-decimal strings.
 *
 * @param ipVec IPv4 addresses (expected in network byte order).
 * @return Vector of dotted strings.
 * @throws std::runtime_error on conversion failure.
 *
 * [Co-developed with claude code -- Adam] Delegates to the single-address overload; see there for
 * why inet_ntop rather than inet_ntoa, and for what that did and did not fix.
 */
inline std::vector<std::string>
ipToString(std::vector<uint32_t> ipVec)
{
    std::vector<std::string> res;
    res.reserve(ipVec.size());
    for (const auto& ip : ipVec)
    {
        res.push_back(ipToString(ip));
    }
    return res;
}

/**
 * @brief Parse dotted IPv4 string into uint32_t.
 *
 * @param ipStr Dotted IPv4 string (e.g., "10.10.10.12").
 * @return IPv4 address in network byte order (in_addr.s_addr).
 * @throws std::invalid_argument if the string is not a valid IPv4 address.
 */
inline uint32_t
ipStringToUint32(const std::string& ipStr)
{
    struct in_addr addr;
    if (inet_aton(ipStr.c_str(), &addr) == 0)
    {
        throw std::invalid_argument("Invalid IP address: " + ipStr);
    }
    return addr.s_addr;
}

/**
 * @brief Parse a dotted IPv4 string, or nothing if it is not one.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * The throwing version above is the right shape for internal callers who already know the string is
 * an address. It is the wrong shape for a REST handler: `?src_ip=not.an.ip` threw
 * std::invalid_argument out of the handler, HttpSession's outermost catch turned it into
 * **500 Internal Server Error**, and the caller was told the kernel had broken when in fact their
 * request was malformed. The L2 contract has been failing on exactly that
 * (get_path_switch_count__bad_ip) for as long as it has existed.
 *
 * A handler wants to answer 400 and say which parameter was wrong, which needs a parse that reports
 * failure rather than throwing it.
 *
 * @param ipStr Dotted IPv4 string.
 * @return The address in network byte order (in_addr::s_addr), or nullopt.
 */
inline std::optional<uint32_t>
tryIpStringToUint32(const std::string& ipStr)
{
    struct in_addr addr;
    if (ipStr.empty() || inet_aton(ipStr.c_str(), &addr) == 0)
    {
        return std::nullopt;
    }
    return addr.s_addr;
}

/**
 * @brief Parse an unsigned 64-bit id from a query parameter, or nothing if it is not one.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * `?dpid=abc` reached std::stoull, which threw std::invalid_argument and became a
 * **500 Internal Server Error** -- the L2 failure inform_switch_entered__bad_dpid.
 *
 * Stricter than stoull deliberately. stoull accepts leading whitespace, a leading `+` or `-`, and
 * any trailing junk: "12abc" parses as 12, and "-1" wraps to 18446744073709551615. A dpid that a
 * caller mistyped must be refused, not silently turned into a different switch. Only digits are
 * accepted, and the value must fit.
 *
 * @param text The parameter value.
 * @return The parsed value, or nullopt.
 */
inline std::optional<uint64_t>
tryParseUint64(const std::string& text)
{
    if (text.empty())
    {
        return std::nullopt;
    }
    for (const char c : text)
    {
        if (!std::isdigit(static_cast<unsigned char>(c)))
        {
            return std::nullopt;
        }
    }
    try
    {
        size_t consumed = 0;
        const unsigned long long value = std::stoull(text, &consumed);
        if (consumed != text.size())
        {
            return std::nullopt;
        }
        return static_cast<uint64_t>(value);
    }
    catch (const std::exception&)
    {
        // out_of_range for something longer than 64 bits. Refusing beats wrapping.
        return std::nullopt;
    }
}

/**
 * @brief Parse a base-16 identifier (a dpid as the control plane writes it) into uint64_t.
 *
 * [Co-developed with claude code -- Adam]
 * The hex twin of tryParseUint64, and it exists for the same reason one step further out.
 * `hexStringToUint64` throws, and `std::stoull(s, nullptr, 16)` throws std::invalid_argument on
 * an empty or non-hex string -- which is not a json::exception, so in the poll path it escaped
 * every catch between updateSwitches and the run() thread and terminated the kernel. A control
 * plane that answers with a `switches` entry carrying no `dpid` should cost us that entry, not
 * the process.
 *
 * Strict for the same reason as tryParseUint64: stoull would accept leading whitespace, a sign,
 * and trailing junk, so "1a2bzz" would silently become switch 0x1a2b. No `0x` prefix is accepted
 * either -- the control plane does not send one, and treating it as optional makes "0x" itself
 * parse as zero.
 *
 * @param text The identifier, hex digits only, no prefix.
 * @return The parsed value, or nullopt.
 */
inline std::optional<uint64_t>
tryParseHexUint64(const std::string& text)
{
    if (text.empty())
    {
        return std::nullopt;
    }
    for (const char c : text)
    {
        if (!std::isxdigit(static_cast<unsigned char>(c)))
        {
            return std::nullopt;
        }
    }
    try
    {
        size_t consumed = 0;
        const unsigned long long value = std::stoull(text, &consumed, 16);
        if (consumed != text.size())
        {
            return std::nullopt;
        }
        return static_cast<uint64_t>(value);
    }
    catch (const std::exception&)
    {
        // out_of_range for something longer than 64 bits. Refusing beats wrapping.
        return std::nullopt;
    }
}

inline static uint32_t
prefixToMaskHost(uint8_t p)
{
    if (p == 0)
    {
        return 0u;
    }
    if (p == 32)
    {
        return 0xFFFFFFFFu;
    }
    return (1u << p) - 1u; // low p bits set
}

inline static uint8_t
maskToPrefixHost(uint32_t mask)
{
    // contiguous in host-order means: low bits are 1s, high bits are 0s
    if (mask == 0u)
    {
        return 0;
    }

    uint8_t p = static_cast<uint8_t>(__builtin_popcount(mask));
    uint32_t expected = (p == 32) ? 0xFFFFFFFFu : ((1u << p) - 1u);

    if (mask != expected)
    {
        throw std::runtime_error("bad ipv4 netmask (non-contiguous)");
    }

    return p;
}

/**
 * @brief Parse a vector of dotted IPv4 strings into uint32_t addresses.
 *
 * @return IPv4 addresses in network byte order.
 * @throws std::invalid_argument if any entry is invalid.
 */
inline std::vector<uint32_t>
ipStringVecToUint32Vec(std::vector<std::string> ipStringVec)
{
    std::vector<uint32_t> res;
    for (const auto& ipStr : ipStringVec)
    {
        struct in_addr addr;
        if (inet_aton(ipStr.c_str(), &addr) == 0)
        {
            throw std::invalid_argument("Invalid IP address: " + ipStr);
        }
        res.push_back(addr.s_addr);
    }
    return res;
}

inline uint32_t
portStringToUint(const std::string& portStr)
{
    try
    {
        return std::stoul(portStr, nullptr, 16);
    }
    catch (const std::invalid_argument& e)
    {
        std::cerr << "Invalid input: " << e.what() << std::endl;
        return 0; // Handle appropriately (e.g., return a default value)
    }
    catch (const std::out_of_range& e)
    {
        std::cerr << "Out of range: " << e.what() << std::endl;
        return 0; // Handle appropriately
    }
}

/**
 * @brief Parse a hex string into uint64_t.
 *
 * Accepts strings like "0x1a2b" or "1A2B".
 *
 * @throws std::invalid_argument on parse failure.
 */
inline uint64_t
hexStringToUint64(const std::string& hexStr)
{
    std::stringstream ss(hexStr);
    ss >> std::hex >> std::ws;
    uint64_t value;
    if (!(ss >> value))
    {
        throw std::invalid_argument("Invalid hex string: " + hexStr);
    }
    return value;
}

/**
 * @brief The tool a shell command line actually runs, for a diagnostic that names it.
 *
 * @details Skips a leading `sudo` and its options, because "is sudo installed?" is never the
 * question. Returns empty when there is nothing to name. [Co-developed with claude code -- Adam]
 */
inline std::string
commandToolName(std::string_view command)
{
    std::size_t pos = 0;
    for (int hop = 0; hop < 4; ++hop) // sudo, then at most a couple of its options
    {
        while (pos < command.size() && std::isspace(static_cast<unsigned char>(command[pos])))
        {
            ++pos;
        }
        const std::size_t end = command.find_first_of(" \t", pos);
        std::string_view token = command.substr(pos, end == std::string_view::npos
                                                        ? std::string_view::npos
                                                        : end - pos);
        if (token.empty())
        {
            return {};
        }
        // Strip any directory part: /usr/bin/ovs-vsctl -> ovs-vsctl.
        if (const std::size_t slash = token.find_last_of('/'); slash != std::string_view::npos)
        {
            token = token.substr(slash + 1);
        }
        if (token != "sudo" && !token.starts_with('-'))
        {
            return std::string(token);
        }
        if (end == std::string_view::npos)
        {
            return {};
        }
        pos = end;
    }
    return {};
}

/**
 * @brief Renders a pclose()/std::system() wait status as something an operator can act on.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 *
 * Neither pclose() nor std::system() returns an exit code -- both return a **wait status**, so a
 * command that exited 1 is 256 and one that exited 127 is 32512. Printing that number raw has
 * misled a reader of these logs more than once, which is why this lives in one place instead of
 * being open-coded at each call site.
 *
 * @param status  Wait status from pclose() or std::system(), or -1.
 * @param command The command line that produced it, when the caller has it. Used to name the tool
 *                in the 127 case and to decide whether the sudo hint applies.
 *
 * The two hints are the two failures this codebase actually sees, and they send an operator to
 * completely different places -- but only if they name the right tool. When this decoder lived in
 * DeviceConfigurationAndPowerManager it hardcoded `ovs-vsctl`, which was correct there because that
 * class runs nothing else. Moving it here wired it into utils::execCommand, the generic shell-out
 * behind `curl` to Ryu and the proxy and **13 snmpget/snmpwalk call sites** -- so a TESTBED machine
 * without net-snmp reported "is ovs-vsctl installed?" for every power reading, on a path where
 * nobody runs ovs-vsctl at all. Caught by review; a misleading diagnostic costs more than a missing
 * one, which is the lesson this whole decoder exists to serve.
 *
 * The sudo hint is likewise conditional now: `sudo` refusing for want of a password is what exit 1
 * means for `sudo ovs-vsctl`, and it is emphatically not what exit 1 means for `snmpget` (a timeout
 * or an unknown OID) or for `curl` (an unsupported protocol).
 */
/**
 * @brief Reads one query parameter out of a request target, or "" if it is absent.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details This was a lambda defined **five times** inside HttpSession -- once each in
 * handleGetDetectedTopKFlowData, handleSetSwitchesPowerState, handleGetNickname,
 * handleGetPathSwitchCount and handleGetSwitchesPowerState. Four copies were byte-identical and the
 * fifth differed only in having numbered explanatory comments, so the logic never actually diverged;
 * that was checked rather than assumed, because extracting a "duplicate" that has quietly drifted is
 * how a refactor changes behaviour.
 *
 * The duplication mattered less than what it hid: this parses **untrusted URLs** and had no tests at
 * all. test_ParamParsing.cpp covers the value parsers -- tryParseUint64, tryIpStringToUint32 -- not
 * the splitter that feeds them. One definition is what makes it testable, which is the point of the
 * extraction rather than the line count. Found by the http-routing review, M3.
 *
 * Deliberate behaviours, all of them relied on by the handlers:
 *  - no '?' at all, or the key absent: "" -- indistinguishable from `?key=`, and the callers treat
 *    "missing" and "empty" alike, so nothing depends on telling them apart;
 *  - the value runs to the next '&' or to the end;
 *  - a pair with no '=' is **skipped**, not fatal: "?broken&dpid=3" still yields "3", because the
 *    scan's find('=') looks past the malformed pair and the following find('&') steps over it. The
 *    scan stops only when no '=' remains anywhere in the rest of the target. I wrote the opposite
 *    here first and a test caught it within minutes of the extraction -- which is the argument for
 *    the extraction, since five copies of this had no test to catch anything;
 *  - keys are compared exactly: no case folding, no percent-decoding, no '+'-as-space. A caller
 *    that needs a decoded value must decode it.
 *
 * @param target Full request target, e.g. "/ndt/get_nickname?dpid=3&mac=aa:bb".
 * @param key    Parameter name, compared exactly.
 */
inline std::string
queryParam(std::string_view target, std::string_view key)
{
    auto qpos = target.find('?');
    if (qpos == std::string_view::npos)
    {
        return "";
    }
    target.remove_prefix(qpos + 1);
    while (!target.empty())
    {
        auto key_end = target.find('=');
        if (key_end == std::string_view::npos)
        {
            break;
        }
        if (target.substr(0, key_end) == key)
        {
            target.remove_prefix(key_end + 1);
            auto val_end = target.find('&');
            return std::string(target.substr(0, val_end));
        }
        auto amp_pos = target.find('&');
        if (amp_pos == std::string_view::npos)
        {
            break;
        }
        target.remove_prefix(amp_pos + 1);
    }
    return "";
}

inline std::string
describeCommandStatus(int status, std::string_view command = {}, int savedErrno = -1)
{
    if (status == -1)
    {
        // [Co-developed with claude code -- Adam]
        // savedErrno is a parameter rather than a read of errno here, and that is the fix for a
        // real defect. The caller writes the message with a `<<` chain:
        //     std::cerr << "Command failed (" << describeCommandStatus(rc, cmd) << "): " ...
        // Since C++17 those operands are sequenced left to right, so the first `<<` performs I/O --
        // and a stream write can set errno -- *before* this function is called. By the time errno
        // was read here it need not be the value pclose set. Passing it in makes the dependency
        // impossible to reintroduce by rearranging the message; -1 means "not supplied", since
        // errno values are positive.
        const int e = (savedErrno >= 0) ? savedErrno : errno;
        return std::string("could not be reaped: ") + std::strerror(e);
    }
    if (WIFSIGNALED(status))
    {
        return "killed by signal " + std::to_string(WTERMSIG(status));
    }
    if (WIFEXITED(status))
    {
        const int code = WEXITSTATUS(status);
        const std::string tool = commandToolName(command);
        if (code == 127)
        {
            if (tool.empty())
            {
                return "exit code 127 (command not found)";
            }
            return "exit code 127 (command not found -- is " + tool + " installed?)";
        }
        if (code == 1 && command.find("sudo") != std::string_view::npos)
        {
            return "exit code 1 (" + (tool.empty() ? std::string("the command") : tool) +
                   " refused; a sudo password prompt does this on a process with no controlling "
                   "terminal)";
        }
        return "exit code " + std::to_string(code);
    }
    return "unrecognised wait status " + std::to_string(status);
}

/**
 * @brief Execute a shell command and capture its stdout.
 *
 * @param cmd Shell command string passed to popen().
 * @return Captured stdout output.
 * @throws std::runtime_error if popen() fails.
 *
 * @warning This function executes via the shell. Do not pass untrusted input
 *          into @p cmd unless properly escaped/sanitized.
 */
inline std::string
execCommand(const std::string& cmd)
{
    std::array<char, 256> buffer;
    std::string result;
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe)
    {
        throw std::runtime_error("popen() failed!");
    }
    while (fgets(buffer.data(), buffer.size(), pipe))
    {
        result += buffer.data();
    }
    int rc = pclose(pipe);
    if (rc != 0)
    {
        // Was "exited with code " << rc, which printed the wait status: a command exiting 1
        // reported "code 256". [Co-developed with claude code -- Adam]
        // errno captured before anything else runs, then the message built before any I/O.
        const int savedErrno = errno;
        const std::string why = describeCommandStatus(rc, cmd, savedErrno);
        std::cerr << "Command failed (" << why << "): " << cmd << "\n";
    }
    return result;
}

/**
 * @brief Perform an HTTPS POST request and return the response body.
 *
 * Uses Boost.URL for parsing and Boost.Beast for TLS + HTTP.
 *
 * @param url HTTPS URL (must start with "https://").
 * @param payload Request body payload.
 * @param ctype Content-Type header value (default: "application/json").
 * @param authorization Authorization header value (default: empty).
 * @return Response body as a string.
 *
 * @throws std::invalid_argument for invalid URLs (non-https, missing host, etc.).
 * @throws std::runtime_error if the server returns >= 400 or on TLS/IO failures.
 *
 * @note This helper uses system default verify paths; certificate validation behavior
 *       depends on platform configuration.
 */
inline std::string
httpsPost(const std::string& url,
          const std::string& payload,
          const std::string& ctype = "application/json",
          const std::string& authorization = "")
{
    namespace beast = boost::beast;
    namespace http = beast::http;
    namespace asio = boost::asio;
    namespace urls = boost::urls;

    urls::url_view u{url};
    if (u.scheme() != "https")
    {
        throw std::invalid_argument("Only https:// URLs are supported: " + url);
    }
    if (u.host().empty())
    {
        throw std::invalid_argument("URL missing host: " + url);
    }

    const std::string host = static_cast<std::string>(u.host());
    const std::string port = u.port().empty() ? "443" : static_cast<std::string>(u.port());

    std::string target =
        u.encoded_path().empty() ? "/" : static_cast<std::string>(u.encoded_path());

    if (!u.encoded_query().empty())
    {
        target += "?" + static_cast<std::string>(u.encoded_query());
    }

    asio::io_context ioc;
    asio::ssl::context sslCtx{asio::ssl::context::tls_client};
    sslCtx.set_default_verify_paths();

    beast::ssl_stream<beast::tcp_stream> stream{ioc, sslCtx};
    asio::ip::tcp::resolver resolver{ioc};

    auto results = resolver.resolve(host, port);
    beast::get_lowest_layer(stream).connect(results);

    if (!SSL_set_tlsext_host_name(stream.native_handle(), host.c_str()))
    {
        throw beast::system_error(
            beast::error_code(static_cast<int>(::ERR_get_error()), asio::error::get_ssl_category()),
            "Failed to set SNI");
    }

    stream.handshake(asio::ssl::stream_base::client);

    http::request<http::string_body> req{http::verb::post, target, 11};
    req.set(http::field::host, host);
    req.set(http::field::content_type, ctype);
    req.set(http::field::user_agent, BOOST_BEAST_VERSION_STRING);
    req.set(http::field::authorization, authorization);
    req.body() = payload;
    req.prepare_payload();

    http::write(stream, req);

    beast::flat_buffer buf;
    http::response<http::string_body> res;
    http::read(stream, buf, res);

    beast::error_code ec;
    stream.shutdown(ec);

    if (res.result() >= http::status::bad_request)
    {
        // SPDLOG_LOGGER_ERROR(Logger::instance(),
        //                     "HTTP request failed: {} {}", res.result(), res.reason());
        // SPDLOG_LOGGER_DEBUG(Logger::instance(), "HTTP Response: {}", res.body());
        std::cerr << "HTTP Response: " << res << std::endl;
        throw std::runtime_error("Server returned HTTP " + std::to_string(res.result_int()));
    }

    return std::move(res.body());
}

/**
 * @brief Current time in milliseconds since epoch (system_clock).
 *
 * Suitable for wall-clock timestamps and logging.
 */
inline int64_t
getCurrentTimeMillisSystemClock()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

/**
 * @brief Monotonic time in milliseconds (steady_clock).
 *
 * Suitable for measuring durations; not tied to wall-clock time.
 */
inline int64_t
getCurrentTimeMillisSteadyClock()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

/**
 * @brief Monotonic time in milliseconds (steady_clock).
 *
 * Suitable for measuring durations; not tied to wall-clock time.
 */
inline std::string
formatTime(int64_t timestamp_ms)
{
    time_t timestamp_s = timestamp_ms / 1000;
    struct tm* localTime = localtime(&timestamp_s);
    char buffer[80];
    strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", localTime);
    return std::string(buffer);
}

/**
 * @brief Log the current local time at DEBUG level using the global Logger.
 *
 * @warning Uses localtime(), which is not thread-safe.
 */
inline void
logCurrentTimeSystemClock()
{
    int64_t now_ms = utils::getCurrentTimeMillisSystemClock();
    time_t now_s = now_ms / 1000;
    struct tm* localTime = localtime(&now_s);

    char buffer[80];
    strftime(buffer, sizeof(buffer), "%Y-%m-%d %H:%M:%S", localTime);
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "Local Time: {}", buffer);
}

/**
 * @brief Parse a MAC address, refusing anything that is not exactly one.
 *
 * @param mac Expected form `xx:xx:xx:xx:xx:xx` (`-` accepted as the separator too).
 * @return The 48-bit value, or nullopt if @p mac is not a well-formed MAC.
 *
 * @details The previous implementation read six 2-digit fields at fixed offsets 0, 3, 6, 9, 12, 15
 * without ever looking at `mac.size()`. It relied entirely on `std::from_chars` failing on whatever
 * it happened to find, which is not the same as validating:
 *
 *   - `"00:11:22:33:44:5"` -- one digit short -- returned **73588229125**, silently. `from_chars`
 *     parsed the single `5` and stopped at the terminator, reporting success. A wrong MAC means the
 *     wrong host is looked up, with nothing anywhere saying so.
 *   - Where it did fail it threw, and both HTTP handlers that call it let the throw escape to
 *     `buildResponse`'s catch-all, which answers **500** for what is a malformed client request.
 *
 * Not an out-of-bounds read, which is worth writing down because it looks like one: the loop touches
 * index 16 at most, and libstdc++ allocates `size() + 1` for the terminator while its short-string
 * buffer is 16 bytes. Checked under ASan rather than assumed.
 *
 * [Co-developed with claude code -- Adam]
 */
inline static std::optional<uint64_t>
tryMacToUint64(const std::string& mac)
{
    constexpr size_t kMacTextLength = 17; // 6 pairs + 5 separators
    if (mac.size() != kMacTextLength)
    {
        return std::nullopt;
    }

    uint64_t result = 0;
    for (size_t i = 0; i < 6; ++i)
    {
        const size_t at = i * 3;
        if (i > 0 && mac[at - 1] != ':' && mac[at - 1] != '-')
        {
            return std::nullopt;
        }
        uint8_t byte = 0;
        const auto [end, ec] = std::from_chars(mac.data() + at, mac.data() + at + 2, byte, 16);
        // end must have consumed both digits: from_chars stops early on "5:" and reports success.
        if (ec != std::errc() || end != mac.data() + at + 2)
        {
            return std::nullopt;
        }
        result = (result << 8) | byte;
    }
    return result;
}

/**
 * @brief Convert MAC address string ("aa:bb:cc:dd:ee:ff") to a 48-bit integer.
 *
 * @param mac MAC string in colon-separated hex format.
 * @return MAC as uint64_t (lower 48 bits used).
 * @throws std::invalid_argument if parsing fails.
 */
inline uint64_t
macToUint64(const std::string& mac)
{
    // [Co-developed with claude code -- Adam]
    // Delegates so every caller gets the validation, not just the ones updated to use the
    // optional form. See tryMacToUint64 for what was wrong.
    if (const auto parsed = tryMacToUint64(mac))
    {
        return *parsed;
    }
    throw std::invalid_argument("Invalid MAC address: " + mac);
}

/**
 * @brief Convert a 48-bit MAC stored in uint64_t to string form.
 *
 * @param mac MAC value (lower 48 bits used).
 * @return MAC string ("aa:bb:cc:dd:ee:ff").
 */
inline std::string
macToString(uint64_t mac)
{
    std::ostringstream oss;

    // Extract 6 bytes from the 48-bit MAC
    for (int i = 5; i >= 0; --i)
    {
        uint8_t byte = (mac >> (i * 8)) & 0xFF;
        oss << std::hex << std::setw(2) << std::setfill('0') << (int)byte;
        if (i > 0)
        {
            oss << ":";
        }
    }

    return oss.str();
}
} // namespace utils
