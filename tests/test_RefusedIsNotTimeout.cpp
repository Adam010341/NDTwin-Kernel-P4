/**
 * FINDINGS #38: a connection that was refused in 6 ms was reported as a 30-second timeout.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT WAS MEASURED
 *   Round 2 (`doc/audit/2026-09-03_night-rounds/round2-power-paths/05_sim502_claims_30s_timeout.log`)
 *   called POST /ndt/received_a_simulation_case five times with nothing listening on :9000. All
 *   five answered 502 in 6.0-9.0 ms with
 *       {"details":"no response from the simulator server at http://127.0.0.1:9000/submit
 *                   within 30s", ...}
 *   The kernel's own log independently timed the same 502 at 9.9 ms. Nobody waited 30 seconds.
 *
 * WHY THE CODE SAID IT
 *   requestSimulation() branched on `curl.httpStatus == 0`, which is what curl's `%{http_code}`
 *   reports ("000") for *every* failure that produced no HTTP response -- refused, reset, DNS
 *   failure and a genuine timeout alike -- and then hard-coded the timeout wording. curl's own
 *   exit status distinguishes them (7 could-not-connect, 28 operation-timed-out, 56 recv failure,
 *   52 empty reply) and it was sitting unread in `outcome.status`.
 *
 * WHY THAT COSTS SOMETHING
 *   The two failures need opposite responses. "Timed out after 30s" sends a reader looking for a
 *   slow or overloaded simulator; "connection refused" means there is no simulator and the answer
 *   is to start one. The old message named the slow-simulator hypothesis every time, and named a
 *   30-second wait that had not happened -- so an operator reading the kernel's log could not even
 *   reconstruct how long the request actually took.
 *
 * HOW THIS FILE TESTS IT
 *   Two real local listeners and no mocks, because the classification lives in curl's exit code
 *   and a fake would have to invent that code -- which is the same thing as assuming the answer.
 *     - REFUSED: a loopback port that was bound to learn its number and then closed. Nothing is
 *       listening, so the SYN is answered with RST and curl exits 7 in a few milliseconds.
 *     - HANGS:   a loopback socket that listen()s and never accept()s. The kernel completes the
 *       handshake from the backlog, so curl connects, sends the POST and waits for a reply that
 *       never comes, until --max-time fires and curl exits 28.
 *   Nothing here binds a fixed port, contacts a name server, or starts a process other than the
 *   curl that requestSimulation() runs itself.
 *
 *   The deadline is the constructor's third argument (see the header) so the hanging case costs
 *   two seconds instead of thirty. That parameter exists because of this file: while the deadline
 *   was a compile-time 30, the timed-out branch was untestable in practice, and an untested branch
 *   is exactly where a message can go on describing a wait that never happened.
 *
 * WHAT THIS FILE DOES NOT CLAIM
 *   It does not pin the exact sentence. It pins the *classification*: which of "refused" /
 *   "reset-or-empty-reply" / "timed out" the message asserts, that the two cannot collapse into
 *   one string again, and that a measured duration is present. Rewording is allowed; re-merging
 *   the categories is not. tests/shell/mutate_refused_is_not_timeout.sh proves both halves of that
 *   by trying a reworded message and requiring it to survive.
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cctype>
#include <chrono>
#include <iostream>
#include <memory>
#include <regex>
#include <string>
#include <thread>

#include <gtest/gtest.h>

#include "ndt_core/application_management/SimulationRequestManager.hpp"

namespace
{

/// The five fields Simulation-Platform-Manager requires. The body is irrelevant to every case in
/// this file -- none of these requests reaches a server -- but sending the real shape keeps the
/// test on the production path rather than on the validation reject.
std::string
validBody()
{
    return R"({"simulator":"MySimulator","version":"1.0.0","app_id":"1",)"
           R"("case_id":"case_123","inputfile":"/srv/nfs/sim/1/case_123.json"})";
}

/// A loopback listener, closed by the destructor. Ephemeral port only: a fixed one would collide
/// with whatever else is running on this laptop, and a collision would silently turn "nothing is
/// listening" into "something answered".
class LoopbackListener
{
  public:
    /// listen()s and never accept()s: the kernel completes the handshake from the backlog, so a
    /// peer connects and then waits forever for an application that is not there.
    LoopbackListener()
    {
        m_fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (m_fd < 0)
        {
            return;
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = ::htonl(INADDR_LOOPBACK);
        addr.sin_port = 0; // let the kernel pick
        if (::bind(m_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
        {
            close();
            return;
        }
        socklen_t len = sizeof(addr);
        if (::getsockname(m_fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0)
        {
            close();
            return;
        }
        m_port = ::ntohs(addr.sin_port);
        if (::listen(m_fd, 4) != 0)
        {
            close();
            return;
        }
    }

    ~LoopbackListener() { close(); }

    LoopbackListener(const LoopbackListener&) = delete;
    LoopbackListener& operator=(const LoopbackListener&) = delete;

    int port() const { return m_port; }
    bool ok() const { return m_fd >= 0 && m_port > 0; }

    /// Stops listening. The port then refuses, which is the other half of this file.
    void close()
    {
        if (m_fd >= 0)
        {
            ::close(m_fd);
            m_fd = -1;
        }
    }

    std::string url() const
    {
        return "http://127.0.0.1:" + std::to_string(m_port) + "/submit";
    }

  private:
    int m_fd = -1;
    int m_port = 0;
};

/// Case-insensitive substring test. The assertions below are about which words the message
/// commits to, and a rewording is allowed to change their case.
bool
mentions(const std::string& haystack, const std::string& needle)
{
    std::string h;
    std::string n;
    h.reserve(haystack.size());
    for (char c : haystack)
    {
        h.push_back(static_cast<char>(::tolower(static_cast<unsigned char>(c))));
    }
    for (char c : needle)
    {
        n.push_back(static_cast<char>(::tolower(static_cast<unsigned char>(c))));
    }
    return h.find(n) != std::string::npos;
}

/// True when the message claims a wait ran out. Every spelling the old message and its plausible
/// rewordings could use, because the point of this file is that a refusal must claim none of them.
bool
claimsATimeout(const std::string& message)
{
    return mentions(message, "timed out") || mentions(message, "timeout") ||
           mentions(message, "time out") || mentions(message, "timed-out") ||
           mentions(message, "within ");
}

/// The failureReason for one request against `url`, with `deadline` seconds on the clock.
///
/// It prints what it got, on every run, passing or failing. The subject of this file is a sentence
/// an operator reads out of a 502 body, and a suite about a message that never shows the message
/// leaves a reader with the assertions and no way to see what was actually said. The line below is
/// the closest thing to "here is what you would have seen".
std::string
failureReasonFor(const std::string& url, int deadline)
{
    SimulationRequestManager manager(nullptr, url, deadline);
    const SimulationRequestManager::Dispatch dispatch = manager.requestSimulation(validBody());
    EXPECT_TRUE(dispatch.sent) << "curl did not run at all; this file cannot say anything";
    EXPECT_FALSE(dispatch.answered) << "something answered on a port that should not answer";
    std::cout << "    502 details would read: " << dispatch.failureReason << std::endl;
    return dispatch.failureReason;
}

constexpr int kShortDeadlineSeconds = 2;

} // namespace

// ------------------------------------------------------------------------------------------
// The finding itself.
// ------------------------------------------------------------------------------------------

TEST(RefusedIsNotTimeoutTest, ARefusalIsNotDescribedAsATimeout)
{
    LoopbackListener probe;
    ASSERT_TRUE(probe.ok()) << "could not obtain a loopback port";
    const std::string url = probe.url();
    probe.close(); // nothing listens here now

    const auto startedAt = std::chrono::steady_clock::now();
    const std::string reason = failureReasonFor(url, kShortDeadlineSeconds);
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();

    // The measurement that produced the finding: it comes back immediately, not on the deadline.
    ASSERT_LT(elapsed, static_cast<double>(kShortDeadlineSeconds))
        << "the connection was not actually refused quickly; this run cannot judge the message";

    EXPECT_FALSE(claimsATimeout(reason))
        << "FINDINGS #38: a connection refused in " << elapsed
        << "s is being reported as a wait that ran out. Message was: " << reason;
    EXPECT_TRUE(mentions(reason, "refused"))
        << "the message does not say what happened. Message was: " << reason;
}

TEST(RefusedIsNotTimeoutTest, AHangIsStillDescribedAsATimeout)
{
    // The over-correction control. Deleting the timeout wording everywhere would satisfy the case
    // above and would be a worse message than the defect, because the one request that really does
    // wait out the deadline would stop saying so.
    LoopbackListener silent;
    ASSERT_TRUE(silent.ok()) << "could not obtain a loopback port";

    const auto startedAt = std::chrono::steady_clock::now();
    const std::string reason = failureReasonFor(silent.url(), kShortDeadlineSeconds);
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();

    ASSERT_GE(elapsed, static_cast<double>(kShortDeadlineSeconds) * 0.8)
        << "the request did not actually wait for the deadline; this run cannot judge the message";

    EXPECT_TRUE(mentions(reason, "timed out"))
        << "a request that really did run out of time must say so. Message was: " << reason;
    EXPECT_FALSE(mentions(reason, "refused"))
        << "nothing refused this connection -- it was accepted and then never answered. "
           "Message was: "
        << reason;
}

TEST(RefusedIsNotTimeoutTest, TheTwoFailuresDoNotProduceTheSameSentence)
{
    // The defect in one assertion. Both requests used to render the byte-identical string, so the
    // 502 body could not tell an operator whether to start the simulator or go looking for a slow
    // one. Deliberately separate from the two cases above: a fix that only stops saying "timeout"
    // for a refusal, without saying anything else, would pass the first case and fail this one.
    LoopbackListener silent;
    ASSERT_TRUE(silent.ok());
    LoopbackListener probe;
    ASSERT_TRUE(probe.ok());
    const std::string refusedUrl = probe.url();
    probe.close();

    const std::string refused = failureReasonFor(refusedUrl, kShortDeadlineSeconds);
    const std::string hung = failureReasonFor(silent.url(), kShortDeadlineSeconds);

    // The URLs differ by port, so strip the endpoint before comparing: what is being asserted is
    // that the *diagnosis* differs, not that the two lines contain different numbers.
    const auto withoutEndpoint = [](std::string s) {
        return std::regex_replace(s, std::regex(R"(http://127\.0\.0\.1:\d+/submit)"), "<url>");
    };

    EXPECT_NE(withoutEndpoint(refused), withoutEndpoint(hung))
        << "FINDINGS #38: a refused connection and a request that timed out are reported with the "
           "same sentence.\n  refused: "
        << refused << "\n  hung:    " << hung;
}

TEST(RefusedIsNotTimeoutTest, TheRefusalCarriesTheDurationThatWasActuallyMeasured)
{
    // The 502 quoted "30s" for a 6 ms request. Whatever the message says about time must be
    // something this process measured, so the number in it has to be small here.
    LoopbackListener probe;
    ASSERT_TRUE(probe.ok());
    const std::string url = probe.url();
    probe.close();

    const std::string reason = failureReasonFor(url, kShortDeadlineSeconds);

    std::smatch match;
    const std::regex seconds(R"((\d+\.\d+)\s*s\b)");
    ASSERT_TRUE(std::regex_search(reason, match, seconds))
        << "the message states no measured duration at all. Message was: " << reason;
    const double stated = std::stod(match[1].str());
    EXPECT_LT(stated, 1.0) << "the message quotes " << stated
                           << "s for a connection that was refused immediately. Message was: "
                           << reason;
}

TEST(RefusedIsNotTimeoutTest, ADroppedConnectionIsNeitherOfTheTwo)
{
    // The third category, and the reason the fix is a classification rather than one extra if.
    // A peer that accepts and then vanishes mid-exchange is neither refused nor timed out; curl
    // exits 52 (empty reply) or 56 (reset) or 55 (send failure) depending on where in the exchange
    // it happened, so this case asserts what all three have in common rather than picking one.
    LoopbackListener listener;
    ASSERT_TRUE(listener.ok());
    const std::string url = listener.url();

    // Accept nothing, then tear the listening socket down while curl is mid-request. The pending
    // connection is reset, which is the closest a local socket gets to "the far end died".
    std::thread closer([&listener]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        listener.close();
    });
    const auto startedAt = std::chrono::steady_clock::now();
    const std::string reason = failureReasonFor(url, kShortDeadlineSeconds);
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();
    closer.join();

    // Whatever it was, it was not a refusal: the connection was established first.
    EXPECT_FALSE(mentions(reason, "refused"))
        << "the connection was accepted before it broke. Message was: " << reason;

    // And if it broke before the deadline, the deadline is not what happened either. Guarded on
    // the measurement rather than asserted outright: a kernel that does not reset a queued
    // connection when the listening socket closes would leave curl waiting, and that is a
    // different observation, not a failure of the message.
    if (elapsed < static_cast<double>(kShortDeadlineSeconds) * 0.8)
    {
        EXPECT_FALSE(claimsATimeout(reason))
            << "the connection broke after " << elapsed
            << "s, well inside the deadline, and is still being reported as a wait that ran out. "
               "Message was: "
            << reason;
    }
}
