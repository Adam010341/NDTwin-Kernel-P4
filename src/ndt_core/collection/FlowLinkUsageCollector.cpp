#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "common_types/GraphTypes.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
// [Co-developed with claude code -- Adam] FINDINGS #47: cloexecSocket() and the /proc lookup that
// says who is actually holding the sFlow port.
#include "utils/FdHygiene.hpp"
#include "utils/KeyedFailureLog.hpp"
#include "utils/Utils.hpp"
#include <limits>
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/detail/edge.hpp>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <deque>
#include <errno.h>
#include <exception>
#include <fcntl.h>
#include <initializer_list>
#include <linux/net_tstamp.h>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <nlohmann/json.hpp>
#include <optional>
#include <poll.h>
#include <pthread.h>
#include <random>
#include <set>
#include <spdlog/spdlog.h>
#include <sstream>
#include <stdexcept>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <string_view>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <thread>
#include <tuple>
#include <unistd.h>
#include <vector>
struct iovec;

using namespace std;
using namespace std::chrono;
using json = nlohmann::json;

namespace sflow
{

// [Co-developed with claude code -- Adam]
// These two definitions must precede every member-function definition in this file, and that is a
// language requirement rather than a preference. The header declares
//     std::vector<std::unique_ptr<SPSCQueue<Packet>>> m_queues;
// with Packet and SPSCQueue only forward-declared, and destroying that vector deletes each
// SPSCQueue<Packet>. std::unique_ptr<T>::~unique_ptr requires T to be *complete* where it is
// instantiated; with an incomplete type it is undefined behaviour, not merely unportable
// ([unique.ptr.single.dtor]). The constructor instantiates it too, because members must be
// destroyable if construction throws.
//
// They used to sit ~450 lines below, after the constructor and destructor. GCC accepts that -- which
// is why this has built and passed all along -- but clang 18 correctly refuses:
//     error: implicit instantiation of undefined template 'sflow::SPSCQueue<sflow::Packet>'
// That was not just tidiness: libFuzzer only exists for clang, so this single placement blocked the
// entire fuzzing plan. Found while checking whether the codebase compiles under clang at all.
//
// Moving the *types* up rather than the two functions down is deliberate: it makes every present and
// future member function correct, instead of fixing the two that happen to exist today.
struct Packet
{
    uint16_t len = 0;
    alignas(4) std::array<char, BUFFER_SIZE> data{};
};

// Single-producer / single-consumer queue
template <typename T>
class SPSCQueue
{
  public:
    explicit SPSCQueue(size_t capacity)
        : m_capacity(capacity)
    {
    }

    bool tryPush(T&& item, const std::atomic_bool& running)
    {
        if (!running.load(std::memory_order_relaxed))
        {
            return false;
        }

        std::unique_lock<std::mutex> lk(m_mu);

        if (m_q.size() >= m_capacity)
        {
            return false;
        }
        m_q.emplace_back(std::move(item));
        lk.unlock();
        m_cv_not_empty.notify_one();
        return true;
    }

    // bool push(T&& item, const std::atomic_bool& running)
    // {
    //     // TODO: Count dropped packet, return immediately don't wait here
    //     std::unique_lock<std::mutex> lk(m_mu);
    //     m_cv_not_full.wait(lk, [&] { return m_q.size() < m_capacity || !running.load(); });
    //     if (!running.load())
    //     {
    //         return false;
    //     }
    //     m_q.emplace_back(std::move(item));
    //     lk.unlock();
    //     m_cv_not_empty.notify_one();
    //     return true;
    // }

    bool pop(T& out, const std::atomic_bool& running)
    {
        std::unique_lock<std::mutex> lk(m_mu);
        m_cv_not_empty.wait(lk, [&] { return !m_q.empty() || !running.load(); });
        if (m_q.empty())
        {
            return false; // stop and drained
        }
        out = std::move(m_q.front());
        m_q.pop_front();
        lk.unlock();
        // m_cv_not_full.notify_one();
        return true;
    }

    void notify_all()
    {
        m_cv_not_empty.notify_all();
        // m_cv_not_full.notify_all();
    }

  private:
    size_t m_capacity;
    std::mutex m_mu;
    std::condition_variable m_cv_not_empty;
    // std::condition_variable m_cv_not_full;
    std::deque<T> m_q;
};

FlowLinkUsageCollector::FlowLinkUsageCollector(
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceManager,
    std::shared_ptr<EventBus> eventBus,
    int mode,
    std::shared_ptr<ndtClassifier::Classifier> classifier)
    : m_sockfd(-1),
      m_topologyAndFlowMonitor(std::move(topologyAndFlowMonitor)),
      m_deviceConfigurationAndPowerManager(std::move(deviceManager)),
      m_eventBus(std::move(eventBus)),
      m_mode(static_cast<utils::DeploymentMode>(mode)),
      m_classifier(classifier)
{
}

FlowLinkUsageCollector::~FlowLinkUsageCollector()
{
    stop();
}

std::string_view
trim(std::string_view s)
{
    s.remove_prefix(std::min(s.find_first_not_of(" \t\n\r\f\v"), s.size()));
    s.remove_suffix(std::min(s.size() - s.find_last_not_of(" \t\n\r\f\v") - 1, s.size()));
    return s;
}

// [Co-developed with claude code -- Adam]
bool
FlowLinkUsageCollector::usesIdentityPortMapping(
    const std::map<SwitchKind, std::vector<uint64_t>>& switchKindGroups)
{
    if (switchKindGroups.empty())
    {
        // Topology not loaded, or it has no switches. Keep the ovs-vsctl behaviour rather than
        // guessing: assuming bmv2 here would break OVS runs whose topology loads late.
        return false;
    }
    return switchKindGroups.size() == 1 && switchKindGroups.begin()->first == SwitchKind::BMV2;
}

/** @brief host:port of the control plane that owns this data plane.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Reuses usesIdentityPortMapping's all-bmv2 test rather than repeating it: "this is a bmv2
 * fabric" is one fact, and two copies of it could disagree.
 *
 * Resolved per call, not cached at construction. The switch kinds come from the topology file,
 * which is loaded by another thread after this object is built -- deciding early would always
 * see an empty graph and silently pick Ryu, which is exactly how the identity ifIndex mapping
 * became dead code for several commits.
 */
std::string
FlowLinkUsageCollector::controlPlaneHostAndPort() const
{
    if (m_mode == utils::MININET && m_topologyAndFlowMonitor
        && usesIdentityPortMapping(m_topologyAndFlowMonitor->getSwitchKindGroups()))
    {
        return AppConfig::P4_PROXY_IP_AND_PORT;
    }
    return AppConfig::RYU_IP_AND_PORT;
}

// [Co-developed with claude code -- Adam]
void
FlowLinkUsageCollector::configurePortMapping()
{
    // Matches the original gating: only MININET ever translated ifIndex values at all.
    if (m_mode != utils::MININET)
    {
        return;
    }

    const auto groups = m_topologyAndFlowMonitor
                            ? m_topologyAndFlowMonitor->getSwitchKindGroups()
                            : std::map<SwitchKind, std::vector<uint64_t>>{};

    if (usesIdentityPortMapping(groups))
    {
        m_identityPortMapping.store(true, std::memory_order_relaxed);
        SPDLOG_LOGGER_INFO(
            Logger::instance(),
            "All-bmv2 topology: using identity ifIndex->port mapping and skipping ovs-vsctl, "
            "which does not know about bmv2 interfaces.");
        return;
    }

    populateIfIndexToOfportMap();
}

// [Co-developed with claude code -- Adam]
uint32_t
FlowLinkUsageCollector::lookupOfport(uint32_t ifIndex)
{
    // Must happen before the shared_lock below: populateIfIndexToOfportMap takes the same
    // mutex exclusively, so calling it while holding a shared lock would deadlock.
    std::call_once(m_portMappingOnce, [this] { configurePortMapping(); });

    if (m_identityPortMapping.load(std::memory_order_relaxed))
    {
        // The bmv2 emitter already reports P4 port numbers, so there is nothing to translate.
        return ifIndex;
    }
    std::shared_lock lock(m_ifIndexMapMutex);
    auto it = m_ifIndexToOfportMap.find(ifIndex);
    return (it != m_ifIndexToOfportMap.end()) ? it->second : 0;
}

void
FlowLinkUsageCollector::populateIfIndexToOfportMap()
{
    std::unique_lock lock(m_ifIndexMapMutex); // Lock for writing
    m_ifIndexToOfportMap.clear();
    SPDLOG_LOGGER_INFO(Logger::instance(), "Populating ifIndex to OFPort map...");

    FILE* pipe = popen("sudo ovs-vsctl list interface", "r");
    if (!pipe)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "popen() for ovs-vsctl failed: {}",
                            strerror(errno));
        return;
    }

    char buffer[256];
    std::string current_block_name_str;
    // uint32_t current_ifindex = 0;
    // uint32_t current_ofport = 0;
    bool in_block = false;

    // Temporary variables for parsing current interface block
    std::string temp_name_str;
    uint32_t temp_ifindex = 0;
    uint32_t temp_ofport = 0;
    std::string temp_type_str;

    while (fgets(buffer, sizeof(buffer), pipe) != nullptr)
    {
        std::string_view line(buffer);

        if (line.find("_uuid") != std::string_view::npos)
        {
            // Start of a new block, process the previous one if valid
            if (in_block && !temp_name_str.empty() && temp_ifindex > 0 && temp_ofport > 0 &&
                temp_ofport != 65534)
            {
                // We only care about ports that are not the "local" port (OFPP_LOCAL = 65534)
                // And typically sX-ethY pattern
                if (temp_name_str.rfind("s", 0) == 0 &&
                    temp_name_str.find("-eth") != std::string::npos)
                {
                    m_ifIndexToOfportMap[temp_ifindex] = temp_ofport;
                    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                        "Mapped ifIndex: {} to OFPort: {} for Name: {}",
                                        temp_ifindex,
                                        temp_ofport,
                                        temp_name_str);
                }
                else
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Skipping interface (not sX-ethY or local): Name: {}, "
                                        "ifIndex: {}, OFPort: {}",
                                        temp_name_str,
                                        temp_ifindex,
                                        temp_ofport);
                }
            }
            // Reset for new block
            temp_name_str.clear();
            temp_ifindex = 0;
            temp_ofport = 0;
            temp_type_str.clear();
            in_block = true;
            continue;
        }

        if (!in_block)
        {
            continue;
        }

        size_t colon_pos = line.find(':');
        if (colon_pos == std::string_view::npos)
        {
            continue;
        }

        std::string_view key = trim(line.substr(0, colon_pos));
        std::string_view value_sv = trim(line.substr(colon_pos + 1));

        // Remove quotes from value if present
        if (!value_sv.empty() && value_sv.front() == '"' && value_sv.back() == '"')
        {
            value_sv.remove_prefix(1);
            value_sv.remove_suffix(1);
        }
        std::string value(value_sv);

        if (key == "name")
        {
            temp_name_str = value;
        }
        else if (key == "ifindex")
        {
            try
            {
                temp_ifindex = std::stoul(value);
            }
            catch (const std::exception& e)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Failed to parse ifindex value '{}': {}",
                                   value,
                                   e.what());
            }
        }
        else if (key == "ofport")
        {
            try
            {
                temp_ofport = std::stoul(value);
            }
            catch (const std::exception& e)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Failed to parse ofport value '{}': {}",
                                   value,
                                   e.what());
            }
        }
        else if (key == "type")
        {
            temp_type_str = value;
        }
    }

    // Process the last block after EOF
    if (in_block && !temp_name_str.empty() && temp_ifindex > 0 && temp_ofport > 0 &&
        temp_ofport != 65534)
    {
        if (temp_name_str.rfind("s", 0) == 0 && temp_name_str.find("-eth") != std::string::npos)
        {
            m_ifIndexToOfportMap[temp_ifindex] = temp_ofport;
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "Mapped ifIndex: {} to OFPort: {} for Name: {}",
                                temp_ifindex,
                                temp_ofport,
                                temp_name_str);
        }
        else
        {
            SPDLOG_LOGGER_TRACE(
                Logger::instance(),
                "Skipping interface (not sX-ethY or local): Name: {}, ifIndex: {}, OFPort: {}",
                temp_name_str,
                temp_ifindex,
                temp_ofport);
        }
    }

    int status = pclose(pipe);
    if (status == -1)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "pclose() failed: {}", strerror(errno));
    }
    else
    {
        if (WIFEXITED(status))
        {
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "ovs-vsctl command exited with status {}",
                                WEXITSTATUS(status));
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "ovs-vsctl command exited abnormally");
        }
    }
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "Finished populating ifIndex to OFPort map. Size: {}",
                       m_ifIndexToOfportMap.size());
    for (const auto& pair : m_ifIndexToOfportMap)
    {
        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "Final Map Entry: ifIndex {} -> OFPort {}",
                            pair.first,
                            pair.second);
    }
}

static inline pid_t
gettid_linux()
{
    return (pid_t)syscall(SYS_gettid);
}

static inline pid_t
getpid_linux()
{
    return (pid_t)getpid();
}

void
log_thread_ids(const char* tag)
{
    pid_t pid = getpid_linux();
    pid_t tid = gettid_linux();
    SPDLOG_LOGGER_INFO(Logger::instance(), "[{}] pid={} tid={}", tag, pid, tid);
}

void
FlowLinkUsageCollector::start(size_t numWorkers, size_t queueCapacity)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Collector Starts Up");

    // The ifIndex->port mapping is configured on first use rather than here: the topology is
    // not loaded yet at this point. See configurePortMapping.
    // [Co-developed with claude code -- Adam]

    // No first fetch here any more, deliberately.
    //
    // [Co-developed with claude code -- Adam]
    // There used to be an "opportunistic" fetchAllDestinationPaths() on this line. It could
    // never succeed -- the comment on refreshDestinationPathsPeriodically says so itself: at
    // this point the topology file has not been loaded, so controlPlaneHostAndPort() cannot
    // tell Ryu from the P4 proxy and the request goes to the wrong host, and the control plane
    // has not finished discovery anyway. Its stated cost was "gets nothing and returns".
    //
    // Its real cost, measured 2026-08-21: main() calls start() before it opens the northbound
    // HTTP server, this call is synchronous, and a request to an address nothing answers took
    // 131 seconds. So a fetch that was known to be useless held the entire kernel unavailable
    // for over two minutes -- :8000 closed, every consumer timing out -- while the logs showed
    // a healthy startup. stack.sh reported the stack as failed; it was not, it was hostage.
    //
    // Removing it costs the first attempt at T+0 and gains it at T+5s (kWhileEmpty) on the
    // refresh thread, which is where every attempt that has ever succeeded came from.
    // The curl timeouts added alongside this bound the same failure wherever else it appears.

    // [Co-developed with claude code -- Adam]
    // Bound here, on the caller's thread, and before anything is spawned. It used to happen inside
    // run() -- which is a std::thread entry point, so the exception it throws on failure had
    // nowhere to go but std::terminate, killing the process with no usable message. Now a failure
    // propagates to whoever called start(), which can report it and exit, and nothing has been
    // started that would need unwinding.
    openReceiveSocket();

    this->m_running.store(true);
    m_pktRcvThread = thread(&FlowLinkUsageCollector::run, this, numWorkers, queueCapacity);
    m_calAvgFlowSendingRateThreadPeriodically =
        thread(&FlowLinkUsageCollector::calAvgFlowSendingRatesPeriodically, this);
    m_testCalAvgFlowSendingRatesRandomly =
        thread(&FlowLinkUsageCollector::testCalAvgFlowSendingRatesRandomly, this);
    m_purgeThread = thread(&FlowLinkUsageCollector::purgeIdleFlows, this);
    m_calFlowPathByQueried = thread(&FlowLinkUsageCollector::calFlowPathByQueried, this);
    m_destinationPathRefreshThread =
        thread(&FlowLinkUsageCollector::refreshDestinationPathsPeriodically, this);
}

/** @brief Keep re-pulling the destination paths until they arrive, then refresh them slowly.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Polls quickly while the map is empty and slowly once it is populated. Two distinct problems
 * make a plain one-shot call at startup useless, and both are fixed by retrying:
 *
 *  - **Ordering.** start() runs before loadStaticTopologyFromFile, so the switch kinds are not
 *    known and controlPlaneHostAndPort() cannot tell Ryu from the P4 proxy. The first attempt
 *    therefore asks the wrong host, gets nothing, and `fetchAllDestinationPaths` returns
 *    silently on the empty body.
 *  - **Convergence.** Even against the right host, the control plane has not finished LLDP
 *    discovery that early, so it has no paths to give.
 *
 * The slow refresh afterwards matters too: paths change when links fail or recover, and nothing
 * else re-pulls them.
 */
void
FlowLinkUsageCollector::refreshDestinationPathsPeriodically()
{
    using namespace std::chrono_literals;
    constexpr auto kWhileEmpty = 5s;   // still converging: try again soon
    constexpr auto kOnceLoaded = 60s;  // steady state: just track changes

    bool everLoaded = false;
    while (m_running.load())
    {
        const bool haveAny = !getAllPaths().empty();

        // Sleep first, and now this is the *only* place a fetch happens: start() no longer makes
        // one (see the note there -- it could not succeed and it blocked the HTTP server for two
        // minutes when the address did not answer). Sleeping up front is still what we want, so
        // the topology-loading thread has run and controlPlaneHostAndPort() knows which control
        // plane owns the switches before the first request goes out.
        const auto interval = haveAny ? kOnceLoaded : kWhileEmpty;
        for (auto slept = 0s; slept < interval && m_running.load(); slept += 1s)
        {
            std::this_thread::sleep_for(1s);
        }
        if (!m_running.load())
        {
            break;
        }

        fetchAllDestinationPaths();

        if (!everLoaded && !getAllPaths().empty())
        {
            everLoaded = true;
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "Destination paths loaded from {} ({} pairs); "
                               "path and switch-count queries will answer from now on.",
                               controlPlaneHostAndPort(),
                               getAllPaths().size());
        }
    }
}

void
FlowLinkUsageCollector::stop()
{
    this->m_running.store(false);

    SPDLOG_LOGGER_INFO(Logger::instance(), "Collector Stops");

    if (m_sockfd != -1)
    {
        ::close(m_sockfd);
        m_sockfd = -1;
    }
    // Join the worker pool here as well as in run(): stop() is what the destructor calls, and it
    // used to leave m_workers untouched. Idempotent. [Co-developed with claude code -- Adam]
    stopAndJoinWorkers();

    if (m_pktRcvThread.joinable())
    {
        m_pktRcvThread.join();
    }
    if (m_calAvgFlowSendingRateThreadPeriodically.joinable())
    {
        m_calAvgFlowSendingRateThreadPeriodically.join();
    }
    if (m_testCalAvgFlowSendingRatesRandomly.joinable())
    {
        m_testCalAvgFlowSendingRatesRandomly.join();
    }
    if (m_purgeThread.joinable())
    {
        m_purgeThread.join();
    }
    // [Co-developed with claude code -- Adam]
    // Must be joined: a joinable std::thread destructor calls std::terminate.
    if (m_destinationPathRefreshThread.joinable())
    {
        m_destinationPathRefreshThread.join();
    }

    if (m_calFlowPathByQueried.joinable())
    {
        m_calFlowPathByQueried.join();
    }
}


/**
 * @brief Signals the worker pool to finish and joins it. Safe to call more than once.
 *
 * [Co-developed with claude code -- Adam]
 * Extracted because the join used to exist only at the very end of run(), while the workers are
 * created near its start -- and everything in between can throw. `::socket` and `::bind` both throw
 * std::runtime_error on failure, and bind failing is not exotic: EADDRINUSE on 6343 is exactly what
 * happens when a previous kernel has not fully exited. On that path run() unwound past the join,
 * leaving joinable std::threads in m_workers, so the eventual destructor called std::terminate --
 * a crash on shutdown whose cause is a socket error reported nowhere near it. stop() did not join
 * them either, so nothing did.
 *
 * Now run() calls this on both its normal and its exceptional exit, and stop() calls it too, which
 * covers a throw from anything added between creation and shutdown later.
 */
void
FlowLinkUsageCollector::stopAndJoinWorkers()
{
    m_running.store(false);
    for (auto& q : m_queues)
    {
        q->notify_all();
    }
    for (auto& t : m_workers)
    {
        if (t.joinable())
        {
            t.join();
        }
    }
    m_workers.clear();
}

void
FlowLinkUsageCollector::openReceiveSocket()
{
    // Assigned only on success. openSflowSocket() closes its own descriptor before throwing, so
    // m_sockfd stays at -1 on failure and neither stop() nor the destructor closes a number that
    // has since been handed to somebody else.
    m_sockfd = openSflowSocket(SFLOW_PORT);
}

int
FlowLinkUsageCollector::openSflowSocket(uint16_t port)
{
    // [Co-developed with claude code -- Adam]
    // FINDINGS #47: SOCK_CLOEXEC, and it must be here rather than an fcntl() on the next line.
    // This process runs curl through popen() from its poll threads, and popen() is fork()+exec();
    // a descriptor created without SOCK_CLOEXEC and marked a moment later is inherited by any
    // child that happens to be forked in between. Measured 2026-09-03 (round3 step 03): the sFlow
    // socket was still held by orphaned `sh`/`curl` for 2.01-2.22 s after the kernel's pid was
    // gone, and the six restarts attempted inside that window all failed.
    int sockfd = utils::cloexecSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sockfd < 0)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "socket() failed: {}", strerror(errno));
        throw std::runtime_error("Failed to create UDP socket");
    }

    // Increase receive buffer
    int rcvbuf = 4 * 1024 * 1024; // 4 MB
    setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    // [Co-developed with claude code -- Adam]
    // SO_REUSEADDR was set here and has been removed deliberately. On Linux, two unicast UDP
    // sockets may both bind the same port when both set it -- measured, not assumed -- and the
    // datagrams are then delivered to whichever bound *last*. So a second kernel started while
    // the first was still running did not fail: it silently took the sFlow feed, and the older
    // kernel went deaf while continuing to report a healthy zero. UDP has no TIME_WAIT, so the
    // option was buying nothing in exchange for that. Without it the second bind gets EADDRINUSE,
    // which is a diagnosis rather than a mystery.
    int one = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_RXQ_OVFL, &one, sizeof(one));

    // Non-blocking mode
    int flags = fcntl(sockfd, F_GETFL, 0);
    fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in bindAddr{};
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(port);
    bindAddr.sin_addr.s_addr = INADDR_ANY;
    if (::bind(sockfd, reinterpret_cast<sockaddr*>(&bindAddr), sizeof(bindAddr)) < 0)
    {
        const int err = errno;
        // [Co-developed with claude code -- Adam]
        // FINDINGS #47, the other half. This used to read "Another NDTwin kernel is almost
        // certainly still running and holding it" -- an assertion, printed without looking. In
        // the 6 measured failures there was no other kernel: the holder was this kernel's own
        // orphaned curl, which had inherited the socket across popen()'s exec. An operator who
        // believes that sentence goes hunting for a process that does not exist. So the holder is
        // now read out of /proc and the sentence is built from what was found; "another kernel"
        // is printed only when a process actually named like this one is holding the port.
        const std::string who =
            utils::diagnosePortInUse(port, utils::PortProtocol::Udp, "ndtwin_kernel");
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "bind() to sFlow port {} failed: {}. {} Without telemetry this twin "
                            "would report every flow rate as zero, so it will not start.",
                            port,
                            strerror(err),
                            who);
        ::close(sockfd);
        throw std::runtime_error("Failed to bind UDP socket");
    }
    return sockfd;
}

void
FlowLinkUsageCollector::run(size_t numWorkers, size_t queueCapacity)
{
    log_thread_ids("run");
    SPDLOG_LOGGER_INFO(Logger::instance(), "Run with {} workers", numWorkers);

    if (numWorkers == 0)
    {
        numWorkers = 1;
    }
    if (queueCapacity == 0)
    {
        queueCapacity = 1024;
    }

    // Create per-worker queues
    m_queues.clear();
    m_queues.reserve(numWorkers);
    for (size_t i = 0; i < numWorkers; ++i)
    {
        m_queues.emplace_back(std::make_unique<SPSCQueue<Packet>>(queueCapacity));
    }

    // Spawn workers only once the socket exists and is bound.
    //
    // [Co-developed with claude code -- Adam]
    // This used to sit ~40 lines earlier, before ::socket and ::bind -- both of which throw
    // std::runtime_error on failure -- while the join was at the very end of run(). So a failed
    // bind unwound straight past the join, leaving joinable std::threads in m_workers, and the
    // eventual destructor called std::terminate: a crash at shutdown whose actual cause was a
    // socket error logged far away from it. stop() did not join them either, so nothing did.
    // EADDRINUSE on 6343 is not exotic -- it is what happens when a previous kernel has not fully
    // exited, which is a normal thing to do by accident.
    //
    // Neither the socket nor the queues depend on the workers, so reordering removes the window
    // entirely rather than papering over it with a catch. stop() now joins them as well, for
    // anything added between here and the end of run() later.
    m_workers.clear();
    m_workers.reserve(numWorkers);
    for (size_t i = 0; i < numWorkers; ++i)
    {
        m_workers.emplace_back([this, i] { workerLoop(i); });
    }


    SPDLOG_LOGGER_INFO(Logger::instance(), "Listening for sFlow on UDP port {}", SFLOW_PORT);

    // Prepare recvmmsg structures
    constexpr int BATCH_SIZE = 32;
    std::vector<std::array<char, BUFFER_SIZE>> buffers(BATCH_SIZE);
    std::vector<iovec> iov(BATCH_SIZE);
    std::vector<mmsghdr> msgs(BATCH_SIZE);
    std::vector<sockaddr_in> srcAddrs(BATCH_SIZE);
    std::vector<socklen_t> addrLens(BATCH_SIZE, sizeof(sockaddr_in));
    std::vector<std::array<char, CMSG_SPACE(sizeof(uint32_t))>> ctrls(BATCH_SIZE);

    for (int i = 0; i < BATCH_SIZE; ++i)
    {
        iov[i].iov_base = buffers[i].data();
        iov[i].iov_len = BUFFER_SIZE;
        msgs[i].msg_hdr.msg_iov = &iov[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
        msgs[i].msg_hdr.msg_name = &srcAddrs[i];
        msgs[i].msg_hdr.msg_namelen = addrLens[i];
        msgs[i].msg_hdr.msg_control = ctrls[i].data();
        msgs[i].msg_hdr.msg_controllen = ctrls[i].size();
        msgs[i].msg_hdr.msg_flags = 0;
        msgs[i].msg_len = 0;
    }

    // Main loop: poll without timeout, then recvmmsg
    struct pollfd pfd
    {
        m_sockfd, POLLIN, 0
    };

    // [Co-developed with claude code -- Adam]
    // 0 means "return immediately", not "no timeout" -- so with no traffic this loop was
    // poll -> ret==0 -> continue -> poll, spinning a full core forever. Measured on an idle
    // kernel with no data plane and zero flows: this thread alone accounted for 100.9% CPU
    // (2:05 of CPU in 2:03 of wall clock), which is the long-standing "kernel burns a core
    // while idle" symptom.
    //
    // A short timeout keeps the loop responsive to m_running on shutdown -- the reason it
    // polls at all rather than blocking indefinitely -- while letting the thread sleep in the
    // kernel between packets. 100ms bounds shutdown latency at a tenth of a second and costs
    // nothing in throughput, because a readable socket wakes poll() immediately regardless.
    const int POLL_TIMEOUT_MS = 100;
    while (m_running.load())
    {
        int ret = poll(&pfd, 1, POLL_TIMEOUT_MS);
        if (ret < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            SPDLOG_LOGGER_ERROR(Logger::instance(), "poll() failed: {}", strerror(errno));
            break;
        }
        if (ret == 0)
        {
            continue; // timeout, recheck m_running
        }

        int received = recvmmsg(m_sockfd, msgs.data(), BATCH_SIZE, 0, nullptr);
        if (received < 0)
        {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                continue;
            }
            if (errno == EBADF)
            {
                break; // socket closed
            }
            SPDLOG_LOGGER_ERROR(Logger::instance(), "recvmmsg() failed: {}", strerror(errno));
            break;
        }

        for (int i = 0; i < received; ++i)
        {
            if (msgs[i].msg_len == 0)
            {
                // reset for reuse
                msgs[i].msg_hdr.msg_controllen = ctrls[i].size();
                msgs[i].msg_hdr.msg_flags = 0;
                msgs[i].msg_hdr.msg_namelen = sizeof(sockaddr_in);
                continue;
            }

            // parse cmsg first
            for (cmsghdr* cmsg = CMSG_FIRSTHDR(&msgs[i].msg_hdr); cmsg != nullptr;
                 cmsg = CMSG_NXTHDR(&msgs[i].msg_hdr, cmsg))
            {
                if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SO_RXQ_OVFL)
                {
                    uint32_t v;
                    std::memcpy(&v, CMSG_DATA(cmsg), sizeof(v));
                    uint32_t cur = m_sockOvflDrops.load(std::memory_order_relaxed);
                    if (v > cur)
                    {
                        m_sockOvflDrops.store(v, std::memory_order_relaxed);
                    }
                }
            }

            receivedPacketNumFromSocket.fetch_add(1, std::memory_order_relaxed);

            Packet pkt;
            pkt.len = static_cast<uint16_t>(std::min<size_t>(msgs[i].msg_len, BUFFER_SIZE));
            std::memcpy(pkt.data.data(), buffers[i].data(), pkt.len);

            uint32_t rr = m_rr.fetch_add(1, std::memory_order_relaxed);
            size_t qid = rr % numWorkers;

            if (!m_queues[qid]->tryPush(std::move(pkt), m_running))
            {
                if (!m_running.load(std::memory_order_relaxed))
                {
                    break;
                }
                droppedPackets.fetch_add(1, std::memory_order_relaxed);
                // Even if app drops, socket ovfl is still captured above
            }

            // reset for reuse
            msgs[i].msg_len = 0;
            msgs[i].msg_hdr.msg_controllen = ctrls[i].size();
            msgs[i].msg_hdr.msg_flags = 0;
            msgs[i].msg_hdr.msg_namelen = sizeof(sockaddr_in);
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Run loop exiting");

    stopAndJoinWorkers();

    if (m_sockfd >= 0)
    {
        ::close(m_sockfd);
        m_sockfd = -1;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Run loop existing");
}

void
FlowLinkUsageCollector::workerLoop(size_t qid)
{
    Packet pkt;
    while (m_running.load())
    {
        if (!m_queues[qid]->pop(pkt, m_running))
        {
            break;
        }

        try
        {
            handlePacket(pkt.data.data(), pkt.len);
        }
        catch (const std::exception& e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "worker {} handlePacket exception: {}",
                                qid,
                                e.what());
        }
        catch (...)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "worker {} handlePacket unknown exception",
                                qid);
        }
    }

    // Drain remaining after stop
    while (m_queues[qid]->pop(pkt, m_running))
    {
        handlePacket(pkt.data.data(), pkt.len);
    }
}

namespace
{

/**
 * @brief Lifts a sampled Ethernet frame out of the datagram's 32-bit words into bytes.
 *
 * [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
 *
 * The parser around this reads the frame through fixed *word* offsets, which is why it could only
 * ever answer questions whose answer sat at a constant offset -- and why an IPv4 option (mri) or a
 * VLAN tag shifted every field after it without anything noticing. identifyFrame needs bytes, so
 * this is the one place the conversion happens.
 *
 * Three independent bounds, because each one is wrong on its own:
 *   - the end of this sample, so a short frame cannot read the next sample's bytes as its own;
 *   - the agent's declared captured length, when the vendor's layout lets us find it;
 *   - kMaxSampledHeaderBytes, so a crafted length cannot make this copy unbounded.
 * `BoundedWords::has` covers the datagram's own end, which the first two do not imply.
 */
sflow::SampledHeader
readSampledHeader(const sflow::BoundedWords& data,
                  size_t startWord,
                  size_t endWord,
                  uint32_t declaredCapturedBytes)
{
    sflow::SampledHeader out;
    if (startWord >= endWord)
    {
        return out;
    }

    size_t availableBytes = (endWord - startWord) * 4;
    if (declaredCapturedBytes > 0 && declaredCapturedBytes < availableBytes)
    {
        availableBytes = declaredCapturedBytes;
    }
    if (availableBytes > sflow::kMaxSampledHeaderBytes)
    {
        availableBytes = sflow::kMaxSampledHeaderBytes;
    }

    size_t written = 0;
    for (size_t word = 0; written < availableBytes; ++word)
    {
        if (!data.has(startWord + word))
        {
            break;
        }
        const uint32_t value = ntohl(data[startWord + word]);
        for (int shift = 3; shift >= 0 && written < availableBytes; --shift)
        {
            out.bytes[written++] = static_cast<uint8_t>((value >> (shift * 8)) & 0xFF);
        }
    }
    out.length = written;
    return out;
}

} // namespace

// [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
void
FlowLinkUsageCollector::noteFrameIdentity(const FrameIdentity& identity,
                                          uint32_t frameLength,
                                          uint32_t samplingRate)
{
    if (!identity.ethernetHeaderPresent)
    {
        // Not counted against a family: we do not know one. A sample whose Ethernet header did not
        // fit is a fact about the agent's capture length, not about the traffic.
        m_samplesUndecodable.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    switch (identity.key.family)
    {
    case FlowKeyFamily::IPv4:
        m_samplesIpv4.fetch_add(1, std::memory_order_relaxed);
        break;
    case FlowKeyFamily::IPv6:
        m_samplesIpv6.fetch_add(1, std::memory_order_relaxed);
        break;
    case FlowKeyFamily::L2:
        m_samplesL2.fetch_add(1, std::memory_order_relaxed);
        break;
    }

    if (identity.ipv4MalformedIhl)
    {
        m_malformedIpv4Ihl.fetch_add(1, std::memory_order_relaxed);
    }

    // IPv4 keys belong in the flow table, which the caller fills; this table is what the flow
    // table cannot hold. See the header for why the two are separate.
    if (!identity.identified || identity.key.family == FlowKeyFamily::IPv4)
    {
        return;
    }

    // Two clocks, on purpose, and the header says which is which: the steady one decides who
    // leaves when the table is full, the wall one is what a reader outside this process can
    // compare with anything. [Co-developed with claude code -- Adam] Round 3, ruling 11c.
    const int64_t nowSteadyMs = utils::getCurrentTimeMillisSteadyClock();
    const int64_t nowWallMs = utils::getCurrentTimeMillisSystemClock();

    std::unique_lock<std::shared_mutex> lk(m_nonIpv4ObservationsMutex);
    auto it = m_nonIpv4Observations.find(identity.key);
    if (it == m_nonIpv4Observations.end())
    {
        if (m_nonIpv4Observations.size() >= kMaxNonIpv4Observations)
        {
            // [Co-developed with claude code -- Adam] Round 2, fable-judge F5.
            // 🔴 EVICT THE OLDEST RATHER THAN REFUSE THE NEWEST. The first draft refused, which
            // reads fine for a cap on distinct *ethertypes* and is wrong for what these keys
            // actually are: an IPv6 key carries the L4 ports, so one run of ordinary traffic
            // mints a new identity per ephemeral port and fills 1024 in minutes. After that the
            // table would be frozen on whatever was seen first and every later identity -- the
            // one an operator is looking for, because it is the one happening now -- would only
            // increment a counter. Least-recently-seen goes, which is the same thing
            // purgeIdleFlows does to the flow table and for the same reason.
            //
            // O(n) over 1024 entries, and only on an insert into a full table. The ingest that
            // reaches here is one sampled frame in `samplingRate`, so this is nowhere near the
            // hot path -- and a heap keyed on a timestamp that every hit updates would be more
            // machinery than the bound is worth.
            auto oldest = m_nonIpv4Observations.begin();
            for (auto scan = m_nonIpv4Observations.begin(); scan != m_nonIpv4Observations.end();
                 ++scan)
            {
                if (scan->second.lastSeenSteadyMs < oldest->second.lastSeenSteadyMs)
                {
                    oldest = scan;
                }
            }
            m_nonIpv4Observations.erase(oldest);
            m_nonIpv4ObservationsEvicted.fetch_add(1, std::memory_order_relaxed);
        }
        it = m_nonIpv4Observations.emplace(identity.key, FamilyObservation{}).first;
    }
    it->second.samples += 1;
    it->second.estimatedBytes += uint64_t(frameLength) * samplingRate;
    // Written on every hit, not only on the insert: a hit is what makes an identity recently
    // seen, and without this line the table would evict in insertion order no matter how busy
    // an identity is. [Co-developed with claude code -- Adam] Round 3, ruling 11c/11e(1).
    it->second.lastSeenSteadyMs = nowSteadyMs;
    it->second.lastSeenWallMs = nowWallMs;
}

// [Co-developed with claude code -- Adam]
FlowLinkUsageCollector::FrameFamilyCounts
FlowLinkUsageCollector::frameFamilyCounts() const
{
    FrameFamilyCounts out;
    out.ipv4 = m_samplesIpv4.load(std::memory_order_relaxed);
    out.ipv6 = m_samplesIpv6.load(std::memory_order_relaxed);
    out.l2 = m_samplesL2.load(std::memory_order_relaxed);
    out.undecodable = m_samplesUndecodable.load(std::memory_order_relaxed);
    out.malformedIpv4Ihl = m_malformedIpv4Ihl.load(std::memory_order_relaxed);
    return out;
}

// [Co-developed with claude code -- Adam]
std::map<FlowKey, FlowLinkUsageCollector::FamilyObservation>
FlowLinkUsageCollector::nonIpv4Observations() const
{
    std::shared_lock<std::shared_mutex> lk(m_nonIpv4ObservationsMutex);
    return m_nonIpv4Observations;
}

// [Co-developed with claude code -- Adam]
nlohmann::json
FlowLinkUsageCollector::frameFamilyStatsJson() const
{
    const FrameFamilyCounts counts = frameFamilyCounts();

    nlohmann::json families{{"ipv4", counts.ipv4},
                            {"ipv6", counts.ipv6},
                            {"l2", counts.l2},
                            {"undecodable", counts.undecodable}};

    nlohmann::json observed = nlohmann::json::array();
    const auto table = nonIpv4Observations();
    for (const auto& [key, observation] : table)
    {
        nlohmann::json row = flowKeyIdentityJson(key);
        row["samples"] = observation.samples;
        row["estimated_bytes"] = observation.estimatedBytes;
        // The wall clock, deliberately: the steady one beside it orders the evictions and means
        // nothing outside this process. [Co-developed with claude code -- Adam] Round 3, 11c.
        row["last_seen_ms"] = observation.lastSeenWallMs;
        observed.push_back(row);
    }

    return nlohmann::json{
        {"samples_by_family", families},
        {"malformed_ipv4_ihl", counts.malformedIpv4Ihl},
        // The count beside the list, not derived from it: a reader must be able to tell a quiet
        // network from a table that stopped accepting new keys.
        {"non_ipv4_flows",
         {{"tracked", table.size()},
          // Non-zero means this list is a window over the most recently seen identities rather
          // than everything since startup. [Co-developed with claude code -- Adam]
          // Round 3, ruling 11b: `dropped_over_capacity` used to sit here and could only ever
          // read 0 once the table started evicting instead of refusing. See the header.
          {"evicted_least_recently_seen",
           m_nonIpv4ObservationsEvicted.load(std::memory_order_relaxed)},
          {"capacity", kMaxNonIpv4Observations},
          {"observed", observed}}}};
}

void
FlowLinkUsageCollector::handlePacket(char* buffer, size_t len)
{
    if (buffer == nullptr)
    {
        return;
    }
    if (len < 7 * 4)
    {
        return; // need at least header up to sampleCount
    }
    if ((len % 4) != 0)
    {
        return; // sFlow is 32-bit aligned
    }

    // [Co-developed with claude code -- Adam]
    //
    // The parser below indexes ~40 fixed word offsets from `index` (up to index+38) with
    // lengths and a sample count taken straight from the datagram, and previously never
    // checked any of them against the buffer. A truncated or malformed datagram therefore
    // read past the end: garbage rates, or an occasional crash, from the one external input
    // surface with no validation and no tests.
    //
    // sflow::BoundedWords has the same operator[] syntax as the raw pointer it replaces, so
    // every existing access is now bounds-checked without touching the call sites. Reading
    // out of range throws sflow::TruncatedDatagram, caught below.
    //
    // The reinterpret_cast requires `buffer` to be 4-byte aligned, or this is undefined
    // behaviour and faults outright on strict-alignment targets. That holds because callers
    // pass Packet::data, declared `alignas(4)` -- which is therefore load-bearing, not
    // decoration. Anything else feeding this function must guarantee the same.
    const sflow::BoundedWords data(reinterpret_cast<const uint32_t*>(buffer), len / 4);
    const size_t words = len / 4;

    try
    {

    uint32_t version = ntohl(data[0]);

    if (version != 5)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Unsupported SFlow Version {}", version);
        return;
    }

    uint32_t agentIp = data[2];
    uint32_t sampleCount = ntohl(data[6]);
    string agentIpStr = utils::ipToString(agentIp);

    SPDLOG_LOGGER_TRACE(Logger::instance(), "Version: {}", version);
    SPDLOG_LOGGER_TRACE(Logger::instance(), "Agent Address: {}", agentIpStr);
    SPDLOG_LOGGER_TRACE(Logger::instance(), "Sample Count: {}", sampleCount);

    // [Co-developed with claude code -- Adam]
    // sampleCount comes from the datagram and was trusted as-is. A crafted value of 2^32-1
    // meant that many iterations; each is now bounds-checked so it would terminate, but
    // capping it at what the remaining bytes could possibly hold rejects the nonsense up
    // front. The smallest sample any branch parses is a header plus length, i.e. 2 words.
    const size_t maxPossibleSamples = (words > 7) ? (words - 7) / 2 : 0;
    if (sampleCount > maxPossibleSamples)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "sFlow datagram from {} claims {} samples but {} bytes can hold "
                           "at most {}; discarding",
                           agentIpStr,
                           sampleCount,
                           len,
                           maxPossibleSamples);
        return;
    }

    uint32_t index = 7;
    // Sentinel below the initial index so the first iteration always passes the guard.
    uint32_t previousIndex = 0;

    for (uint32_t i = 0; i < sampleCount; i++)
    {
        // [Co-developed with claude code -- Adam]
        // Guards at the top rather than the bottom because several branches below reach the
        // next iteration via `continue`, which would skip a bottom-of-loop check.
        //
        // Forward progress: the advancement expressions include
        //     index += (sampleLen / 4 + 2 - (flowDataLength / 4 + 2));
        // which is unsigned, so when flowDataLength exceeds sampleLen -- easy to arrange in
        // a crafted datagram -- it wraps to near 2^32 and index leaps out of the buffer.
        // Elsewhere a sampleLen of 0 leaves index unchanged and spins forever.
        if (index <= previousIndex)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Malformed sFlow datagram from {}: read position did not "
                               "advance at sample {} ({} -> {}); discarding the rest",
                               agentIpStr,
                               i,
                               previousIndex,
                               index);
            break;
        }
        // Two words are needed for any sample: its type and its length.
        // Widened to size_t before adding: `index + 1` in uint32_t arithmetic wraps to 0
        // when index reaches UINT32_MAX, and `0 >= words` is false, so the guard was
        // bypassed. BoundedWords still caught the read that followed, but the loop should
        // stop here rather than rely on the throw.
        if (static_cast<size_t>(index) + 1 >= words)
        {
            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                "Reached end of sFlow datagram from {} after {} sample(s)",
                                agentIpStr,
                                i);
            break;
        }
        previousIndex = index;

        uint32_t sampleType = ntohl(data[index]);
        //================================================================
        // Handle Counter Samples (Brocade Type 2 and HPE Type 4)
        //================================================================
        if (sampleType == 2 || sampleType == 4)
        {
            // Brocade (2) uses a base offset of 4.
            // HPE (4) uses a base offset of 5.
            uint32_t baseOffset = (sampleType == 2) ? 4 : 5;
            const char* vendor = (sampleType == 2) ? "Brocade" : "HPE";

            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                "============{} Counter Sample ==============",
                                vendor);

            uint32_t sampleLen = ntohl(data[index + 1]);

            uint64_t interfaceIndex, interfaceSpeed, inputOctets, outputOctets;

            if (sampleType == 2)
            {
                interfaceIndex = ntohl(data[index + baseOffset + 15 + 3]);

                // Combine high and low 32-bit words to form 64-bit values
                interfaceSpeed =
                    (static_cast<uint64_t>(ntohl(data[index + baseOffset + 15 + 5])) << 32) |
                    ntohl(data[index + baseOffset + 15 + 6]);
                inputOctets =
                    (static_cast<uint64_t>(ntohl(data[index + baseOffset + 15 + 9])) << 32) |
                    ntohl(data[index + baseOffset + 15 + 10]);
                outputOctets =
                    (static_cast<uint64_t>(ntohl(data[index + baseOffset + 15 + 17])) << 32) |
                    ntohl(data[index + baseOffset + 15 + 18]);
            }
            else
            {
                interfaceIndex = ntohl(data[index + baseOffset + 3]);

                // Combine high and low 32-bit words to form 64-bit values
                interfaceSpeed =
                    (static_cast<uint64_t>(ntohl(data[index + baseOffset + 5])) << 32) |
                    ntohl(data[index + baseOffset + 6]);
                inputOctets = (static_cast<uint64_t>(ntohl(data[index + baseOffset + 9])) << 32) |
                              ntohl(data[index + baseOffset + 10]);
                outputOctets = (static_cast<uint64_t>(ntohl(data[index + baseOffset + 17])) << 32) |
                               ntohl(data[index + baseOffset + 18]);
            }

            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                "COUNTER SAMPLE {} from Agent {}: ifIndex={}, ifSpeed={}, "
                                "ifInOctets={}, ifOutOctets={}",
                                sampleType,
                                agentIpStr,
                                interfaceIndex,
                                interfaceSpeed,
                                inputOctets,
                                outputOctets);

            // Advance index past the current sample
            index += (sampleLen / 4 + 2);

            if (m_mode == utils::MININET)
            {
                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "==========================================\n");
                continue;
            }

            int64_t now = utils::getCurrentTimeMillisSteadyClock();
            pair<uint32_t, uint32_t> agentIpAndPort(agentIp, interfaceIndex);

            // log time
            // utils::logCurrentTimeSystemClock();

            uint64_t leftIn = 0, leftOut = 0;
            bool shouldUpdateTopo = false;
            uint64_t ifSpeedCopy = interfaceSpeed;
            {
                std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);
                auto& st = m_counterReports[agentIpAndPort];

                int64_t interval = (now - st.lastReportTimestampInMilliseconds) / 1000;

                if (interval == 0)
                {
                    continue;
                }

                // Check if this is not the first report
                if (st.lastReportTimestampInMilliseconds != 0)
                {
                    SPDLOG_LOGGER_TRACE(
                        Logger::instance(),
                        "Agent Address: {}, Sample Len: {}, Iface Index: {}, Iface Speed: {}",
                        agentIpStr,
                        sampleLen,
                        interfaceIndex,
                        interfaceSpeed);

                    uint64_t avgIn = 0, avgOut = 0;
                    bool inNoOverflow = false, outNoOverflow = false;

                    if (inputOctets >= st.lastReceivedInputOctets)
                    {
                        uint64_t inputOctetsDiff = inputOctets - st.lastReceivedInputOctets;
                        avgIn = inputOctetsDiff * 8 / interval; // Calculate average bits per second
                        inNoOverflow = true;
                        SPDLOG_LOGGER_TRACE(Logger::instance(),
                                            "Average Link Usage (In): {}",
                                            avgIn);
                    }
                    if (outputOctets >= st.lastReceivedOutputOctets)
                    {
                        uint64_t outputOctetsDiff = outputOctets - st.lastReceivedOutputOctets;
                        avgOut =
                            outputOctetsDiff * 8 / interval; // Calculate average bits per second
                        outNoOverflow = true;
                        SPDLOG_LOGGER_TRACE(Logger::instance(),
                                            "Average Link Usage (Out): {}",
                                            avgOut);
                    }

                    leftIn = (avgIn > interfaceSpeed) ? 0 : (interfaceSpeed - avgIn);
                    leftOut = (avgOut > interfaceSpeed) ? 0 : (interfaceSpeed - avgOut);

                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "left_in in SFlow Collector: {} (bps)",
                                        leftIn);
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "left_out in SFlow Collector: {} (bps)",
                                        leftOut);

                    shouldUpdateTopo = (inNoOverflow && outNoOverflow);
                }

                // Update state for the next calculation
                st.lastReportTimestampInMilliseconds = now;
                st.lastReceivedInputOctets = inputOctets;
                st.lastReceivedOutputOctets = outputOctets;
            }

            if (shouldUpdateTopo)
            {
                std::unique_lock<std::shared_mutex> lk(m_topologyMutex);
                m_topologyAndFlowMonitor->updateLinkInfo(agentIpAndPort,
                                                         leftIn,
                                                         leftOut,
                                                         ifSpeedCopy);
            }

            SPDLOG_LOGGER_TRACE(Logger::instance(), "==========================================\n");
        }
        //================================================================
        // Handle Flow Samples (Brocade Type 1 and HPE Type 3)
        //================================================================
        else if (sampleType == 1 || sampleType == 3)
        {
            uint32_t sampleLen = ntohl(data[index + 1]);

            // 1. Extract the sample's own fields. The offsets differ by vendor; the *frame* is no
            //    longer read here at all -- readSampledHeader lifts it into bytes and
            //    identifyFrame says what it is. Before TICKET-P3 this block read the ethertype,
            //    the IPv4 header and the L4 ports from fixed word offsets three times over, and a
            //    sample that was not IPv4 was discarded whole -- bytes and all.
            //    [Co-developed with claude code -- Adam]
            uint32_t inputPort = 0;
            uint32_t outputPort = 0;
            uint32_t frameLength = 0;
            uint32_t flowDataLength = 0;
            uint32_t samplingRate = 0;
            /// First word of the sampled Ethernet frame.
            size_t frameStartWord = 0;
            /// What the agent says it captured, or 0 when this vendor's layout does not say.
            uint32_t declaredCapturedBytes = 0;

            if (sampleType == 1)
            { // Brocade
                samplingRate = ntohl(data[index + 4]);
                inputPort = ntohl(data[index + 7]);
                // Word +8 is the sample's output interface. It was hardcoded to 0 here, which
                // made egress-side attribution impossible for standard flow samples -- the wire
                // carries the field (both the P4 emitter and OVS fill it), the parser dropped
                // it, and the last hop of every path read usage=0 forever as a result. Read
                // before the MININET index shift below, like inputPort.
                // [Co-developed with claude code -- Adam]
                outputPort = ntohl(data[index + 8]);
                if (m_mode == utils::MININET)
                {
                    flowDataLength = ntohl(data[index + 11]);
                    SPDLOG_LOGGER_TRACE(Logger::instance(), "flowDataLength: {}", flowDataLength);
                    index += flowDataLength / 4 + 2;
                }
                frameLength = ntohl(data[index + 13]);
                declaredCapturedBytes = ntohl(data[index + 15]);
                frameStartWord = static_cast<size_t>(index) + 16;
            }
            else
            { // HPE (sampleType == 3)
                samplingRate = ntohl(data[index + 5]);
                inputPort = ntohl(data[index + 9]);
                outputPort = ntohl(data[index + 11]);
                frameLength = ntohl(data[index + 12 + 4]);

                // The frame starts three words before the one this branch read the ethertype
                // from (index + 12 + 6 + 5), i.e. at +20. The captured-length word is NOT
                // identifiable from these offsets -- +16 as the original length leaves one
                // unexplained word before the frame -- so the read below is bounded by the
                // sample and the datagram instead of by a declared length. No fixture and no
                // capture has ever covered this vendor. [Co-developed with claude code -- Adam]
                declaredCapturedBytes = 0;
                frameStartWord = static_cast<size_t>(index) + 20;
            }

            // [Co-developed with claude code -- Adam]
            // Where this sample ends, by the same arithmetic the advancement at the bottom of the
            // branch uses -- but clamped. That subtraction is unsigned and wraps when a crafted
            // flowDataLength exceeds sampleLen; the loop's own no-progress guard catches the wrap
            // afterwards, which is fine for advancing and useless as a bound. Falls back to the
            // end of the datagram, which BoundedWords enforces anyway.
            const size_t sampleWords = static_cast<size_t>(sampleLen) / 4 + 2;
            const size_t skippedWords =
                (m_mode == utils::MININET) ? (static_cast<size_t>(flowDataLength) / 4 + 2) : 0;
            const size_t advanceWords =
                (sampleWords > skippedWords) ? (sampleWords - skippedWords) : 0;
            size_t sampleEndWord = words;
            if (advanceWords > 0 && static_cast<size_t>(index) + advanceWords <= words)
            {
                sampleEndWord = static_cast<size_t>(index) + advanceWords;
            }

            const SampledHeader header =
                readSampledHeader(data, frameStartWord, sampleEndWord, declaredCapturedBytes);
            const FrameIdentity identity = identifyFrame(header.bytes.data(), header.length);

            if (m_mode == utils::TESTBED)
            {
                SPDLOG_LOGGER_TRACE(
                    Logger::instance(),
                    "FLOW SAMPLE from Agent {}: family {} ethertype 0x{:04x} (Proto: {}, Len: {}, "
                    "Input port: {}, Ouput port: {}, Sampling rate {})",
                    agentIpStr,
                    toString(identity.key.family),
                    identity.key.ethType,
                    identity.key.protocol,
                    frameLength,
                    inputPort,
                    outputPort,
                    samplingRate);
            }

            // check whether it is pure ack
            bool isPureAck = false;
            if (identity.key.family == FlowKeyFamily::IPv4 && identity.key.protocol == 6)
            {
                const uint32_t PURE_ACK_SIZE_THRESHOLD = 80; // Your proposed threshold

                // identity.tcpAck should be true if the ACK flag is set
                if (identity.tcpAck && frameLength < PURE_ACK_SIZE_THRESHOLD)
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Pure ACK packet (size: {} bytes)",
                                        frameLength);
                    isPureAck = true;
                }
            }

            // 2. Process the extracted data using common logic.
            if (m_mode == utils::MININET)
            {
                // Read-only lookup: operator[] would insert a 0 entry for every unknown
                // ifIndex, mutating the map from a worker thread without the mutex.
                inputPort = lookupOfport(inputPort);
                outputPort = lookupOfport(outputPort);
            }

            const bool isIngress = (inputPort != 0); // Simple direction check
            const uint32_t relevantPort = isIngress ? inputPort : outputPort;

            // =====================================================================================
            // 🔴 LINK BYTES FIRST, FLOW IDENTITY SECOND. [Co-developed with claude code -- Adam]
            // TICKET-P3 §2.2. This block used to sit *inside* `if (protocol == 6 || 17 || 1)`,
            // downstream of an ethertype test that `continue`d the whole sample -- so a link
            // carrying source-routed frames (0x1234), ARP, LLDP, IPv6 or a non-first fragment
            // reported 0 bps while the bytes demonstrably moved. How many bytes crossed a link is
            // not a question about what the bytes were, and PLAN §8.3's first claim -- "link
            // utilisation is independent of the application" -- is exactly this ordering.
            //
            // The direction split is the second half of §2.2. A sample with inputPort == 0 (the
            // egress-only shape B's tc filters produce on host-facing ports) used to be banked in
            // m_counterReports keyed by its *output* port, which the drain then reads as "bytes
            // arriving on that port" and credits to the edge pointing the other way. Such samples
            // did not exist before -- every P4-clone and OVS sample carries an ingress port -- so
            // the branch was dead rather than wrong in production; B makes it live.
            // =====================================================================================
            if (m_mode == utils::MININET)
            {
                std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);
                const uint64_t sampledBytes = uint64_t(frameLength) * samplingRate;

                // A-4f. Two timestamps, under the lock this line already holds. The rate drain a
                // second later cannot leave them behind: it zeroes the byte accumulator, which is
                // exactly why the accumulator alone can never distinguish "no bytes because the
                // link is idle" from "no bytes because nobody is sampling this switch any more".
                // These do not get zeroed.
                //
                // lastReportTimestampInMilliseconds is reused rather than duplicated: on the
                // MININET path it is otherwise never written (only the TESTBED counter-sample
                // branch touches it) and the two paths are mutually exclusive on m_mode, so the
                // field means what its name says in both.
                const int64_t sampleAt = utils::getCurrentTimeMillisSteadyClock();

                if (isIngress)
                {
                    auto& ingress = m_counterReports[make_pair(agentIp, inputPort)];
                    ingress.inputByteCountOnALinkMultiplySampingRate += sampledBytes;
                    ingress.lastReportTimestampInMilliseconds = sampleAt;

                    // The same sample also crossed the sampling switch's *egress* edge. For a
                    // switch-to-switch edge that credit belongs to the downstream sampler, but
                    // the last hop of a path ends at a host, which has no sampler -- so the
                    // egress side is banked here and creditHostBoundEgressEdges pays out only
                    // the host-bound entries.
                    if (outputPort != 0)
                    {
                        m_egressCounterReports[make_pair(agentIp, outputPort)]
                            .inputByteCountOnALinkMultiplySampingRate += sampledBytes;
                    }
                }
                else if (outputPort != 0)
                {
                    // Egress-only: the bytes left through outputPort and nothing is known about
                    // where they came in. The egress bank is the only honest place for them --
                    // m_counterReports would claim they *arrived* on that port.
                    m_egressCounterReports[make_pair(agentIp, outputPort)]
                        .inputByteCountOnALinkMultiplySampingRate += sampledBytes;
                }
                else
                {
                    // Neither port survived: both ifIndexes translated to 0, which is what
                    // lookupOfport returns for an unknown interface when the topology is not an
                    // all-bmv2 one (and therefore what every sample looks like before a topology
                    // is loaded at all). §2.2's redirect is written for `inputPort == 0 &&
                    // outputPort != 0` precisely so this case is left where it was: the bytes
                    // are real and dropping them here would lose the sample entirely, while the
                    // (agent, 0) entry names no edge and so credits none.
                    auto& unattributed = m_counterReports[make_pair(agentIp, relevantPort)];
                    unattributed.inputByteCountOnALinkMultiplySampingRate += sampledBytes;
                    unattributed.lastReportTimestampInMilliseconds = sampleAt;
                }

                // Per agent, not per port, and therefore written for every flow sample whatever
                // it carried: the question this answers is "is this switch sampling at all".
                m_lastSampleFromAgentMillis[agentIp] = sampleAt;
            }

            // Counted for every sample, including the ones no flow is made of. The counters are
            // the only place a non-IPv4 frame is visible to a reader of the API.
            noteFrameIdentity(identity, frameLength, samplingRate);

            // The flow table is IPv4-only -- see FlowLinkUsageCollector.hpp for the two frozen
            // contract tests that fix that and P3-A-SUMMARY.md for the objection. A non-first
            // fragment carries no ports, so it is banked above and identified above but is not a
            // flow. [Co-developed with claude code -- Adam]
            const bool isClassifiableIpv4 =
                identity.identified && identity.key.family == FlowKeyFamily::IPv4 &&
                identity.ipv4FragmentOffset == 0 &&
                (identity.key.protocol == 6 || identity.key.protocol == 17 ||
                 identity.key.protocol == 1); // TCP, UDP, or ICMP

            if (isClassifiableIpv4)
            {
                const FlowKey key = identity.key;

                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "Flow Sample Recieve Src Ip {}, Dst Ip {}, Src port {}, Dst "
                                    "port {}, Protocol {}",
                                    utils::ipToString(key.srcIP),
                                    utils::ipToString(key.dstIP),
                                    key.srcPort,
                                    key.dstPort,
                                    key.protocol);

                AgentKey agentKey = {agentIp, relevantPort};

                // [Co-developed with claude code -- Adam]
                // One lock taken *before* the lookup and held across the branch, rather than one
                // per branch after it. Two separate defects were fixed by moving it:
                //
                //  1. The `find` itself ran unlocked, on every sampled packet on every worker
                //     thread, while purgeIdleFlows erases at 1 Hz and sibling workers insert via
                //     operator[] (which rehashes). That is a data race and undefined behaviour --
                //     the same one the comment further down this file calls "the crash this whole
                //     set of locks exists to prevent".
                //
                //  2. Locking only inside each branch made find-then-branch non-atomic, so two
                //     workers seeing the same *new* key could both take the "New flow" path. The
                //     second one then **assigns** ingressByteCountCurrent = frameLength instead of
                //     accumulating, discarding the first one's bytes. A counter that goes backwards
                //     underflows the unsigned subtraction in the rate loop to ~1.8e19, which trips
                //     the elephant-flow threshold -- and that flag is never cleared, because the
                //     `else` that would clear it is commented out. One lost race permanently
                //     misclassified a flow.
                //
                // Released explicitly before the graph work below rather than scoped, to keep the
                // diff reviewable; the graph locks must not nest under this one.
                std::unique_lock<std::shared_mutex> flowTableLock(m_flowInfoTableMutex);

                auto it = m_flowInfoTable.find(key);
                if (it != m_flowInfoTable.end()) // Existing flow
                {
                    auto& info = m_flowInfoTable[key];

                    // Find flow stasts on an agent
                    info.isPureAck = isPureAck;
                    info.isAck = identity.tcpAck;

                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Ack?{} PureAck?{} ",
                                        info.isAck,
                                        info.isPureAck);

                    auto& stats = info.agentFlowStats[agentKey];
                    stats.samplingRate = samplingRate;

                    if (isIngress)
                    {
                        stats.ingressByteCountCurrent += uint64_t(frameLength);
                        stats.ingresspacketCountCurrent += 1;
                    }
                    else
                    {
                        stats.egressByteCountCurrent += uint64_t(frameLength);
                        stats.egresspacketCountCurrent += 1;
                    }

                    // log time
                    // utils::logCurrentTimeSystemClock();

                    stats.packetQueue.push({frameLength, utils::getCurrentTimeMillisSteadyClock()});
                    info.endTime = utils::getCurrentTimeMillisSystemClock();
                }
                else // New flow
                {
                    auto& info = m_flowInfoTable[key];

                    info.startTime = utils::getCurrentTimeMillisSystemClock();
                    info.endTime = utils::getCurrentTimeMillisSystemClock();

                    // Initialize stats for the new flow
                    auto& stats = info.agentFlowStats[agentKey];
                    stats.samplingRate = samplingRate;
                    if (isIngress)
                    {
                        stats.ingressByteCountCurrent = uint64_t(frameLength);
                        stats.egressByteCountCurrent = 0;
                        stats.ingresspacketCountCurrent = 1;
                        stats.egresspacketCountCurrent = 0;
                    }
                    else
                    {
                        stats.egressByteCountCurrent = uint64_t(frameLength);
                        stats.ingressByteCountCurrent = 0;
                        stats.egresspacketCountCurrent = 1;
                        stats.ingresspacketCountCurrent = 0;
                    }
                    stats.packetQueue.push({frameLength, utils::getCurrentTimeMillisSteadyClock()});
                }

                // This read of m_flowInfoTable was itself unguarded before, and operator[] can both
                // insert and rehash -- so the diagnostic could corrupt the table it was reporting
                // on. It is inside the lock now. [Co-developed with claude code -- Adam]
                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "Flow Table Entry Updated for {} -> {}. End Time: {}",
                                    utils::ipToString(key.srcIP),
                                    utils::ipToString(key.dstIP),
                                    m_flowInfoTable[key].endTime);

                flowTableLock.unlock();

                // 2. Update the network map
                // [Co-developed with claude code -- Adam]
                // Scoped to the lookup itself: this runs on the 1 Hz rate loop for every tracked
                // flow, and the body below takes graph locks, which must not be nested under
                // this one.
                const bool pathKnown = [&] {
                    std::shared_lock<std::shared_mutex> pathLock(m_allPathMapMutex);
                    return m_allPathMap.count({key.srcIP, key.dstIP}) > 0;
                }();
                if (pathKnown)
                {
                    if (isIngress)
                    {
                        if (auto edgeOpt =
                                m_topologyAndFlowMonitor->findReverseEdgeByAgentIpAndPort(
                                    {agentIp, relevantPort}))
                        {
                            m_topologyAndFlowMonitor->touchEdgeFlow(edgeOpt.value(), key);
                        }
                        // The last hop: the flow's own path already names the egress edge, but
                        // no downstream sampler exists to touch it when it ends at a host, so
                        // the sampling switch touches it from its egress metadata. Kept to
                        // host-bound edges for the same ownership reason as the byte credit.
                        // [Co-developed with claude code -- Adam]
                        if (outputPort != 0)
                        {
                            if (auto lastHopOpt =
                                    m_topologyAndFlowMonitor->findEdgeToHostByAgentIpAndPort(
                                        {agentIp, outputPort}))
                            {
                                m_topologyAndFlowMonitor->touchEdgeFlow(lastHopOpt.value(), key);
                            }
                        }
                    }
                    else
                    { // Egress flow
                        // Finds the link connected to the output port
                        if (auto edgeOpt = m_topologyAndFlowMonitor->findEdgeByAgentIpAndPort(
                                {agentIp, relevantPort}))
                        {
                            m_topologyAndFlowMonitor->touchEdgeFlow(edgeOpt.value(), key);
                        }
                    }
                }
            }
            // Adjust offset index for MININET
            if (m_mode == utils::MININET)
            {
                index += (sampleLen / 4 + 2 - (flowDataLength / 4 + 2));
            }
            else
            {
                index += (sampleLen / 4 + 2);
            }

            addresedSampleNum++;
        }
        //================================================================
        // Handle Unknown Sample Types
        //================================================================
        else
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(), "Unknown sampleType {}", sampleType);
            // Safely advance index to avoid an infinite loop if sampleLen is available
            uint32_t sampleLen = ntohl(data[index + 1]);
            if (sampleLen > 0)
            {
                index += (sampleLen / 4 + 2);
            }
            else
            {
                // Can't determine length, break to avoid getting stuck
                break;
            }
        }

    }

    } // try
    catch (const sflow::TruncatedDatagram& e)
    {
        // A malformed or truncated datagram, not a kernel fault: drop it. Before the bounds
        // check this read past the end of the buffer instead.
        //
        // Rate-limited, because this is an unauthenticated UDP port: logging every bad packet
        // is itself a denial-of-service vector -- a flood would fill the disk and, with
        // flush_on(info), block the worker on a synchronous write per line. The running total
        // is carried in the message so nothing is hidden, only the volume is bounded.
        reportMalformedDatagram(len, e.what());
    }
}

// [Co-developed with claude code -- Adam]
void
FlowLinkUsageCollector::reportMalformedDatagram(size_t len, const char* reason)
{
    // Log the first, then one per LOG_EVERY. Relaxed ordering: the count only drives how
    // often we log, so an occasional interleaving is harmless.
    constexpr uint64_t LOG_EVERY = 1000;
    const uint64_t total = m_malformedDatagrams.fetch_add(1, std::memory_order_relaxed) + 1;

    if (total == 1 || (total % LOG_EVERY) == 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Discarding malformed sFlow datagram ({} bytes): {} "
                           "[{} malformed datagram(s) so far; logging 1 per {}]",
                           len,
                           reason,
                           total,
                           LOG_EVERY);
    }
}

// [Co-developed with claude code -- Adam]
uint64_t
FlowLinkUsageCollector::sampledByteCreditFor(uint32_t agentIp, uint32_t port) const
{
    // Shared, not unique: this only reads, and the rate loop holds the same mutex while it
    // drains. Taking it at all matters -- the ingest path writes these entries from worker
    // threads, so an unlocked read races with a map insert, not merely with a value update.
    std::shared_lock<std::shared_mutex> lk(m_counterReportsMutex);
    const auto it = m_counterReports.find(std::make_pair(agentIp, port));
    return it == m_counterReports.end() ? 0u : it->second.inputByteCountOnALinkMultiplySampingRate;
}

// [Co-developed with claude code -- Adam] TICKET-P3 §2.2.
uint64_t
FlowLinkUsageCollector::egressByteCreditFor(uint32_t agentIp, uint32_t port) const
{
    // Same mutex as the ingress bank: the two maps are written on the same ingest line and
    // drained by the same rate-loop pass.
    std::shared_lock<std::shared_mutex> lk(m_counterReportsMutex);
    const auto it = m_egressCounterReports.find(std::make_pair(agentIp, port));
    return it == m_egressCounterReports.end()
               ? 0u
               : it->second.inputByteCountOnALinkMultiplySampingRate;
}

// [Co-developed with claude code -- Adam]
// A-4f. See the header for the four states and for why the agent, not the port, is the level at
// which this question can be answered at all.
FlowLinkUsageCollector::LinkTelemetryStatus
FlowLinkUsageCollector::telemetryStatusFor(uint32_t agentIp,
                                           uint32_t ifIndex,
                                           double windowSeconds) const
{
    const int64_t now = utils::getCurrentTimeMillisSteadyClock();

    int64_t portAt = 0;
    int64_t agentAt = 0;
    {
        std::shared_lock<std::shared_mutex> lk(m_counterReportsMutex);
        const auto port = m_counterReports.find(std::make_pair(agentIp, ifIndex));
        if (port != m_counterReports.end())
        {
            portAt = port->second.lastReportTimestampInMilliseconds;
        }
        const auto agent = m_lastSampleFromAgentMillis.find(agentIp);
        if (agent != m_lastSampleFromAgentMillis.end())
        {
            agentAt = agent->second;
        }
    }

    // The lock is released before the decision: classifyTelemetry touches no member, so holding
    // the collector's busiest mutex across it would be contention for nothing.
    return classifyTelemetry(now, portAt, agentAt, windowSeconds);
}

// [Co-developed with claude code -- Adam]
// Round 4 lead 5(b). The verdict on the ingest, with no clock, no socket and no collector --
// see the header for why it is split out and why it must stay that way.
FlowLinkUsageCollector::IngestHealth
FlowLinkUsageCollector::classifyIngestHealth(bool windowClosed,
                                             uint64_t samplesInWindow,
                                             uint64_t socketDropsInWindow,
                                             uint64_t appDropsInWindow,
                                             double windowSeconds)
{
    IngestHealth out;

    // Nothing has been measured yet. Saying "ok" here would be the code grading a check that
    // never ran -- exactly the shape this whole family of defects has.
    if (!windowClosed)
    {
        out.status = "unknown";
        out.lossFraction = -1.0;
        out.windowSeconds = 0.0;
        return out;
    }

    out.samplesInWindow = samplesInWindow;
    out.socketDropsInWindow = socketDropsInWindow;
    out.appDropsInWindow = appDropsInWindow;
    out.windowSeconds = windowSeconds;

    const uint64_t dropped = socketDropsInWindow + appDropsInWindow;
    out.offeredInWindow = samplesInWindow + dropped;

    if (out.offeredInWindow == 0)
    {
        // A closed window in which nothing at all was offered. This is a real measurement -- we
        // asked and the answer was zero -- so lossFraction is 0.0, not -1.0. But it is NOT "ok":
        // every rate derived from this window is zero because we saw nothing, and a consumer
        // must be able to tell that from a network that genuinely carried nothing. It cannot be
        // told apart downstream, so it is told apart here.
        out.status = "no_samples";
        out.lossFraction = 0.0;
        return out;
    }

    out.lossFraction = static_cast<double>(dropped) / static_cast<double>(out.offeredInWindow);

    if (dropped == 0)
    {
        out.status = "ok";
    }
    else if (out.lossFraction >= kIngestSevereLossFraction)
    {
        out.status = "severe_loss";
    }
    else if (out.lossFraction > kIngestLossyFraction)
    {
        out.status = "lossy";
    }
    else
    {
        // Loss below the "lossy" threshold is still loss. Round 4's 150 000/s cell lost 0.34% and
        // that under-reports; the honest report is "lossy", not "ok" with a footnote.
        out.status = "lossy";
    }
    return out;
}

FlowLinkUsageCollector::IngestHealth
FlowLinkUsageCollector::ingestHealth() const
{
    // Acquire pairs with the release store in the rate loop.
    const bool closed = m_healthWindowClosed.load(std::memory_order_acquire);
    return classifyIngestHealth(
        closed,
        m_healthSamplesInWindow.load(std::memory_order_relaxed),
        m_healthSockDropsInWindow.load(std::memory_order_relaxed),
        m_healthAppDropsInWindow.load(std::memory_order_relaxed),
        static_cast<double>(m_healthWindowMicros.load(std::memory_order_relaxed)) / 1e6);
}

nlohmann::json
FlowLinkUsageCollector::ingestHealthJson() const
{
    const IngestHealth h = ingestHealth();
    return nlohmann::json{
        {"status", h.status},
        // The numerator and the denominator, over the same window, so a reader can recompute the
        // fraction and disagree with our thresholds without calling anything else.
        {"samples_in_window", h.samplesInWindow},
        {"offered_in_window", h.offeredInWindow},
        {"dropped_in_window", h.socketDropsInWindow + h.appDropsInWindow},
        {"socket_drops_in_window", h.socketDropsInWindow},
        {"app_drops_in_window", h.appDropsInWindow},
        {"loss_fraction", h.lossFraction},
        {"window_seconds", h.windowSeconds},
        // Totals since start, for a consumer keeping its own baseline across polls.
        {"rx_total", receivedPacketNumFromSocket.load(std::memory_order_relaxed)},
        {"addressed_total", addresedSampleNum.load(std::memory_order_relaxed)},
        {"sock_ovfl_total", m_sockOvflDrops.load(std::memory_order_relaxed)},
        {"app_drop_total", droppedPackets.load(std::memory_order_relaxed)}};
}

// [Co-developed with claude code -- Adam]
// A-4f. The decision, with no clock and no state -- see the header for why it is split out.
FlowLinkUsageCollector::LinkTelemetryStatus
FlowLinkUsageCollector::classifyTelemetry(int64_t nowMillis,
                                          int64_t portLastSampleMillis,
                                          int64_t agentLastSampleMillis,
                                          double windowSeconds)
{
    LinkTelemetryStatus out;
    const int64_t portAt = portLastSampleMillis;
    const int64_t agentAt = agentLastSampleMillis;

    // -1 rather than a large age for "never". A never-seen link and one last seen an hour ago
    // are different claims, and a number that merely looks big invites a reader to treat the
    // first as the second.
    out.lastSampleAgeSeconds = portAt > 0 ? (nowMillis - portAt) / 1000.0 : -1.0;
    out.agentLastSampleAgeSeconds = agentAt > 0 ? (nowMillis - agentAt) / 1000.0 : -1.0;

    if (agentAt <= 0)
    {
        // Nothing has ever arrived from this agent. A kernel that started ten seconds ago and a
        // switch that was never given an sFlow record look identical from in here, and saying
        // "unknown" is the only one of the four that is not a guess.
        out.status = "unknown";
        return out;
    }
    if (out.agentLastSampleAgeSeconds > windowSeconds)
    {
        // The agent has gone quiet on every port while the switch is still in the graph. This is
        // A-4f: the 0 bps on this edge is an absence of telemetry, not a measurement of traffic.
        out.status = "silent";
        return out;
    }
    if (portAt > 0 && out.lastSampleAgeSeconds <= windowSeconds)
    {
        out.status = "live";
        return out;
    }
    // The agent is reporting, just not on this port: the sampler is alive, so 0 here means the
    // link really is carrying nothing.
    out.status = "idle";
    return out;
}

// [Co-developed with claude code -- Adam]
void
FlowLinkUsageCollector::creditHostBoundEgressEdges(double elapsedSeconds)
{
    std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);
    for (auto& [key, value] : m_egressCounterReports)
    {
        // Only the host-bound entries are paid out; a switch far end means the downstream
        // sampler owns the edge, so that entry is dropped rather than written. The zeroing is
        // unconditional either way: an entry must not carry bytes into the next interval.
        if (m_topologyAndFlowMonitor->findEdgeToHostByAgentIpAndPort(key).has_value())
        {
            // Bytes and the interval, not a pre-multiplied bps. This is the switch->host edge
            // class; the main loop below serves the other two. [Co-developed with claude code -- Adam]
            m_topologyAndFlowMonitor->updateLinkInfoLeftLinkBandwidth(
                key, value.inputByteCountOnALinkMultiplySampingRate, elapsedSeconds);
        }
        value.inputByteCountOnALinkMultiplySampingRate = 0;
    }
}

void
FlowLinkUsageCollector::runFlowRatePass()
{
    // [Co-developed with claude code -- Adam]
    // Flow-side twin of the drain-to-drain interval the link path measures further down. It has
    // to be its own anchor: the flow counters are snapshotted (...Previous = ...Current) inside
    // the walk below, the counter reports are zeroed at the bottom of the loop body, and the two
    // spans differ by however long the walk takes. Using the link one here would be the mistake
    // f5e35561's own commit message warns about -- two intervals that agree on average, so the
    // wrong one survives inspection and then misses the 1% gate.
    const auto nowFlowDrain = std::chrono::steady_clock::now();
    const double flowElapsedSeconds =
        std::chrono::duration<double>(nowFlowDrain - m_lastFlowDrainAt).count();

    // Refuse, exactly as updateLinkInfoLeftLinkBandwidth does, and for the same reason: no rate
    // exists over a non-positive interval, and a flow publishing 0 is indistinguishable from a
    // flow that stopped. The anchor is deliberately NOT advanced here -- the bytes stay banked
    // and are paid out over the next interval, which is the one difference from the link path,
    // where the accumulator is zeroed unconditionally by its caller.
    if (!(flowElapsedSeconds > 0.0))
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "per-flow rate pass skipped: elapsed interval {} s is not positive, "
                            "so the banked counters cannot be converted to a rate. Flow rates "
                            "left unchanged and the bytes kept for the next interval.",
                            flowElapsedSeconds);
        return;
    }

    m_lastFlowDrainAt = nowFlowDrain;
    m_lastFlowRateDivisorSeconds.store(flowElapsedSeconds);

    unique_lock lock(m_flowInfoTableMutex);
    for (auto& [flowKey, info] : m_flowInfoTable)
    {
        sflow::updateFlowRatesForInterval(info, flowElapsedSeconds, MICE_FLOW_UNDER_THRESHOLD);

        SPDLOG_LOGGER_TRACE(Logger::instance(),
                            "FlowKey: {} -> {} estimated flow sending rate (Periodically): {} bps "
                            "over {:.6f} s, packet rate {} pps",
                            utils::ipToString(flowKey.srcIP),
                            utils::ipToString(flowKey.dstIP),
                            info.estimatedFlowSendingRatePeriodically,
                            flowElapsedSeconds,
                            info.estimatedPacketSendingRatePeriodically);
    }
}

void
FlowLinkUsageCollector::calAvgFlowSendingRatesPeriodically()
{
    log_thread_ids("calAvgFlowSendingRatesPeriodically");

    // [Co-developed with claude code -- Adam]
    // Loop-scoped rather than function-local statics: statics are shared by every instance of the
    // class, so two collectors in one process -- which a test can easily create -- would report
    // each other's deltas.
    uint64_t lastSockOvfl = 0;
    uint64_t lastAppDrop = 0;
    // Same reasoning, for the received count: ingestHealth() publishes a per-window rx delta.
    // [Co-developed with claude code -- Adam]
    uint64_t lastRx = 0;

    // [Co-developed with claude code -- Adam]
    // "sFlow ingest healthy: rx=0" used to be printed on the first pass, one second after start,
    // when rx is necessarily still zero -- so the one line a reader greps for announced health
    // from the only moment at which there was no evidence for it. Health is now claimed when it
    // is observed, and its absence is reported rather than left silent.
    bool announcedHealthy = false;
    bool warnedNoSamples = false;
    const auto rateLoopStartedAt = std::chrono::steady_clock::now();
    constexpr auto kNoSampleGrace = std::chrono::seconds(60);

    // [Co-developed with claude code -- Adam]
    // THE PERIOD OF THIS LOOP IS THE DENOMINATOR OF EVERY RATE IT PUBLISHES, and until this line
    // existed nobody had measured it. The accumulator below is drained once per iteration and
    // handed on as bits-per-second (see updateLinkInfoLeftLinkBandwidth), which is only correct
    // if an iteration takes exactly one second. It cannot: the sleep is a full second and the
    // body runs after it. So every reported link rate is over-stated by (real period / 1 s).
    //
    // Measured externally four different ways on 2026-08-25 and all four were untrustworthy --
    // 1.539, 1.135, 1.032, 0.873, the last below the sleep's own floor and therefore impossible.
    // Polling the HTTP graph cannot resolve this; the loop has to say so itself.
    //
    // 🔴 THE PARAGRAPH ABOVE IS HISTORY, NOT CURRENT BEHAVIOUR, and the two sentences that used
    // to stand here were worse than stale -- they were wrong when written and they misled a
    // reviewer into writing a gate that a correct fix would have failed (PREREG Qb-1). Deleted
    // rather than corrected: "once the accumulator is divided by the measured interval this line
    // must read ~1000 ms forever" is false, because dividing by the measured interval fixes the
    // arithmetic without making an iteration any shorter.
    //
    // Both denominators now exist. The link accumulator is divided by drainElapsedSeconds
    // (f5e35561, ticket Q), and the per-flow rates by the interval runFlowRatePass measures.
    // The period below is therefore a health signal, not a correctness one: it says how long the
    // body takes, which still matters -- it bounds sample freshness and it is what
    // kFlowActiveWindowMs was sized against -- but no published rate assumes it is 1000 ms any
    // more. The acceptance gate is the "rate divisor check" line further down, which compares
    // the divisors actually used against the intervals measured for the same iteration.
    // [Co-developed with claude code -- Adam]
    //
    // Logged every iteration at DEBUG (off by default) and summarised at INFO every 30, so the
    // steady state is greppable without the per-second flood this file has had to undo before.
    // flows and counters are here because the body walks both, so they are the first thing to
    // look at if the period grows.
    auto lastIterStart = std::chrono::steady_clock::now();
    // Separate from lastIterStart on purpose: this one marks where the accumulators were last
    // zeroed, which is the interval the bytes actually banked over.
    // [Co-developed with claude code -- Adam]
    auto lastDrainAt = std::chrono::steady_clock::now();
    uint64_t iterCount = 0;
    // Anchors for the windowed mean above: the summary prints the interval since the previous
    // summary, not since process start. [Co-developed with claude code -- Adam]
    uint64_t lastSummaryIter = 1;
    double lastSummarySumMs = 0.0;
    double periodSumMs = 0.0, periodMinMs = 1e30, periodMaxMs = 0.0;

    while (m_running.load())
    {
        this_thread::sleep_for(chrono::seconds(1));

        {
            const auto nowIter = std::chrono::steady_clock::now();
            const double periodMs =
                std::chrono::duration<double, std::milli>(nowIter - lastIterStart).count();
            lastIterStart = nowIter;
            ++iterCount;
            // Skip the first: lastIterStart was set before the loop, so interval 1 is short by
            // however long setup took and is not a period at all.
            if (iterCount > 1)
            {
                periodSumMs += periodMs;
                periodMinMs = std::min(periodMinMs, periodMs);
                periodMaxMs = std::max(periodMaxMs, periodMs);
            }

            size_t nFlows = 0, nCounters = 0;
            {
                shared_lock fl(m_flowInfoTableMutex);
                nFlows = m_flowInfoTable.size();
            }
            {
                shared_lock cl(m_counterReportsMutex);
                nCounters = m_counterReports.size();
            }

            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "rate loop period {:.1f} ms (flows={}, counters={})",
                                periodMs, nFlows, nCounters);
            if (iterCount > 1 && iterCount % 30 == 0)
            {
                // [Co-developed with claude code -- Adam]
                // This line used to report only `mean` over ALL iterations since start, calling
                // it "the denominator every published bps assumes is 1000". A cumulative mean is
                // not the current period: at 64 flows on 2026-08-25 it printed 1106.3 ms while
                // the actual windowed period was 1248.7 -- 143 ms low, and the gap grows as early
                // low values keep dragging. Anyone who grepped this line got a number that was
                // systematically wrong in the direction that makes the defect look smaller.
                //
                // Both figures are printed now and each says which it is. "last 30" is the one
                // to read; "since start" is kept because a drift between the two IS the signal
                // that the loop is slowing down.
                const double windowMeanMs =
                    (iterCount - lastSummaryIter > 0)
                        ? (periodSumMs - lastSummarySumMs) / double(iterCount - lastSummaryIter)
                        : std::numeric_limits<double>::quiet_NaN();
                SPDLOG_LOGGER_INFO(
                    Logger::instance(),
                    "rate loop period: last {} iters mean {:.1f} ms | since start ({} iters) mean "
                    "{:.1f} ms, min {:.1f}, max {:.1f} (flows={}, counters={}) -- the LAST-N "
                    "figure is the current denominator; the since-start one lags it",
                    iterCount - lastSummaryIter, windowMeanMs, iterCount - 1,
                    periodSumMs / double(iterCount - 1), periodMinMs, periodMaxMs,
                    nFlows, nCounters);
                lastSummaryIter = iterCount;
                lastSummarySumMs = periodSumMs;
            }
        }

        // [Co-developed with claude code -- Adam]
        // Ticket Q's other half. This walk used to compute each hop's rate inline as
        // `delta * 8 * samplingRate` -- bits per LOOP PERIOD, published under a bits-per-second
        // name -- because Q enumerated its targets by grepping `MultiplySampingRate` and the
        // per-flow counters are not spelled that way. runFlowRatePass measures the interval and
        // sflow::updateFlowRatesForInterval divides by it; both are seams the suite can reach,
        // which the inline version was not.
        runFlowRatePass();

        // [Co-developed with claude code -- Adam]
        // The interval the accumulators actually covered: previous drain to this drain. NOT the
        // loop's start-to-start period measured at the top of the body -- the accumulators are
        // zeroed down here, so bytes bank from one drain to the next, and the two intervals
        // differ by however much the work above this point jitters. They agree on average, which
        // is exactly why using the wrong one would survive an eyeball check and then miss ticket
        // Q's 1% gate.
        const auto nowDrain = std::chrono::steady_clock::now();
        const double drainElapsedSeconds =
            std::chrono::duration<double>(nowDrain - lastDrainAt).count();
        lastDrainAt = nowDrain;

        // Estimate left link bandwidth using flow sample
        if (m_mode == utils::MININET)
        {
            std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);
            for (auto& [key, value] : m_counterReports)
            {
                uint32_t agentIp = key.first;
                uint32_t inputPort = key.second;
                const CounterInfo& counter = value;

                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "Agent IP: {}, Input Port: {}, Bytes: {}",
                                    utils::ipToString(agentIp),
                                    inputPort,
                                    counter.inputByteCountOnALinkMultiplySampingRate);

                // Store to graph
                auto agentKeyOtherSideOpt =
                    m_topologyAndFlowMonitor->getAgentKeyFromTheOtherSide(key);
                if (!agentKeyOtherSideOpt.has_value())
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(), "Other Side Agent Miss");
                    continue;
                }
                // Bytes and the interval, not a pre-multiplied bps. This is host->switch and
                // switch->switch; creditHostBoundEgressEdges serves switch->host.
                // [Co-developed with claude code -- Adam]
                m_topologyAndFlowMonitor->updateLinkInfoLeftLinkBandwidth(
                    agentKeyOtherSideOpt.value(),
                    counter.inputByteCountOnALinkMultiplySampingRate,
                    drainElapsedSeconds);
                value.inputByteCountOnALinkMultiplySampingRate = 0;
            }
        }

        // After the block above, not inside it: this takes m_counterReportsMutex itself, and
        // the mutex is not recursive. Outside MININET the egress map never fills, so the call
        // is a natural no-op there.
        creditHostBoundEgressEdges(drainElapsedSeconds);

        // [Co-developed with claude code -- Adam]
        // Ticket Q's acceptance gate, made observable. The criterion is that the value actually
        // used as the divisor equals the interval measured for the same iteration -- and the
        // getter that holds it is C++, unreachable from a live kernel. Logging both, from the
        // same iteration, is what lets the gate run against a running process.
        //
        // They are logged as two separate numbers rather than as a pre-computed "ok": a boolean
        // computed in here would be the code grading its own homework, and a reader could not
        // tell a passing check from a check that never ran.
        if (m_mode == utils::MININET && iterCount > 1 && iterCount % 30 == 0)
        {
            const double used = m_topologyAndFlowMonitor->lastRateDivisorSeconds();
            // [Co-developed with claude code -- Adam]
            // flow_divisor_used_s is the same gate for the per-flow rates, and it is printed
            // separately rather than folded in because the two divisors measure different
            // drains: this one spans the counter-report drain at the bottom of the body, the
            // flow one spans the flow walk near the top. They should agree to about the walk's
            // own jitter, and a persistent gap between them is a real signal -- it says the walk
            // is taking long enough to matter, which is the condition under which the missing
            // flow denominator used to do its worst damage.
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "rate divisor check: measured_interval_s={:.6f} divisor_used_s={:.6f}"
                               " flow_divisor_used_s={:.6f}"
                               " (ticket Q gate: these must agree to 1%; a negative divisor means "
                               "no rate has been published yet, which is not a pass)",
                               drainElapsedSeconds, used, lastFlowRateDivisorSeconds());
        }

        // log socket dropped packet number
        // uint32_t rxq_ovfl = 0;
        // socklen_t olen = sizeof(rxq_ovfl);
        // if (getsockopt(m_sockfd, SOL_SOCKET, SO_RXQ_OVFL, &rxq_ovfl, &olen) == 0)
        // {
        //     SPDLOG_LOGGER_INFO(Logger::instance(), "SO_RXQ_OVFL (socket drops) = {}", rxq_ovfl);
        // }
        // [Co-developed with claude code -- Adam]
        // Edge-triggered. This was INFO unconditionally, once a second, forever: on its own the
        // largest single contributor to the kernel's log volume, and unreadable for exactly the
        // reason it was written -- a line that always appears is a line nobody checks.
        //
        // The counters are monotonic, so the only *event* here is one of them growing. A dropped
        // sFlow sample is not cosmetic: every rate, link usage and top-K figure derived from that
        // second is understated and there is no other signal that it happened, so growth is
        // reported at WARN rather than demoted with the rest.
        const uint64_t sockOvfl = m_sockOvflDrops.load(std::memory_order_relaxed);
        const uint64_t appDrop = droppedPackets.load(std::memory_order_relaxed);
        const uint64_t sockOvflDelta = (sockOvfl >= lastSockOvfl) ? sockOvfl - lastSockOvfl : 0;
        const uint64_t appDropDelta = (appDrop >= lastAppDrop) ? appDrop - lastAppDrop : 0;

        if (sockOvflDelta > 0 || appDropDelta > 0)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "sFlow samples lost in the last second: {} to the socket queue, {} "
                               "dropped by us. Rates for this interval are understated. "
                               "rx={}, addressed={}, sock_ovfl_total={}, app_drop_total={}",
                               sockOvflDelta,
                               appDropDelta,
                               receivedPacketNumFromSocket.load(std::memory_order_relaxed),
                               addresedSampleNum.load(std::memory_order_relaxed),
                               sockOvfl,
                               appDrop);
        }
        else
        {
            const auto rx = receivedPacketNumFromSocket.load(std::memory_order_relaxed);

            // [Co-developed with claude code -- Adam]
            // The INFO is emitted on the first pass that has actually received something, not on
            // the first pass full stop. Announcing "healthy: rx=0" a second after start told a
            // reader the ingest was fine at the one moment nothing could yet have arrived, and it
            // was the only INFO in the run, so grepping for it always produced that line.
            const bool announceNow = rx > 0 && !announcedHealthy;
            if (announceNow)
            {
                announcedHealthy = true;
            }
            const auto level = announceNow ? spdlog::level::info : spdlog::level::trace;
            SPDLOG_LOGGER_CALL(
                Logger::instance(),
                level,
                "sFlow ingest healthy: rx={}, app_drop={}, addressed={}, sock_ovfl_total={}",
                rx,
                appDrop,
                addresedSampleNum.load(std::memory_order_relaxed),
                sockOvfl);

            // And say so when it never arrives. Waiting for evidence before claiming health means
            // a collector that receives nothing would otherwise log nothing at all, and silence is
            // the failure mode this codebase produces most often. Once only: the condition
            // persists, and a warning repeated every second is one nobody reads.
            if (!announcedHealthy && !warnedNoSamples &&
                std::chrono::steady_clock::now() - rateLoopStartedAt > kNoSampleGrace)
            {
                warnedNoSamples = true;
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "no sFlow datagram has arrived in {}s. Every flow rate and link "
                                   "utilisation will read zero, which is indistinguishable from an "
                                   "idle network. Check that the switches are sampling to this "
                                   "host on port {}.",
                                   std::chrono::duration_cast<std::chrono::seconds>(kNoSampleGrace)
                                       .count(),
                                   SFLOW_PORT);
            }
        }

        // [Co-developed with claude code -- Adam]
        // Publish the window that just closed, so an API consumer can ask what the ingest did
        // during the second the rates in their response were computed from. Deltas, not totals:
        // "41273 samples lost since boot" cannot answer "is the number I am holding usable".
        // rx is published for the same reason -- a window with zero samples is the only way an
        // outside reader can distinguish "we failed to ask" from "the network is idle".
        {
            const uint64_t rxNow = receivedPacketNumFromSocket.load(std::memory_order_relaxed);
            const uint64_t rxDelta = (rxNow >= lastRx) ? rxNow - lastRx : 0;
            m_healthSamplesInWindow.store(rxDelta, std::memory_order_relaxed);
            m_healthSockDropsInWindow.store(sockOvflDelta, std::memory_order_relaxed);
            m_healthAppDropsInWindow.store(appDropDelta, std::memory_order_relaxed);
            m_healthWindowMicros.store(
                static_cast<uint64_t>(drainElapsedSeconds > 0.0 ? drainElapsedSeconds * 1e6 : 0.0),
                std::memory_order_relaxed);
            // Released last: a reader that sees `true` sees the four counts that go with it.
            m_healthWindowClosed.store(true, std::memory_order_release);
            lastRx = rxNow;
        }

        lastSockOvfl = sockOvfl;
        lastAppDrop = appDrop;
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting Loop of calAvgFlowSendingRatesPeriodically");
}

void
FlowLinkUsageCollector::calAvgFlowSendingRatesImmediately()
{
    unique_lock lock(m_flowInfoTableMutex);
    for (auto& [flowKey, info] : m_flowInfoTable)
    {
        uint64_t accumulatedEstimatedBytes = 0;
        uint64_t accumulatedEstimatedPackets = 0;

        int hopsCounter = 0;

        for (auto& [link_key, stats] : info.agentFlowStats)
        {
            AutoRefreshQueue& packetQueueTemp = stats.packetQueue;
            uint32_t currentSamplingRate = (stats.samplingRate > 0) ? stats.samplingRate : 1;
            if (packetQueueTemp.size())
            {
                hopsCounter++;

                uint64_t estimatedBytes =
                    static_cast<uint64_t>(packetQueueTemp.getSum()) * currentSamplingRate;
                uint64_t estimatedPackets =
                    static_cast<uint64_t>(packetQueueTemp.size()) * currentSamplingRate;

                accumulatedEstimatedBytes += estimatedBytes;
                accumulatedEstimatedPackets += estimatedPackets;
                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "accumulatedEstimatedBytes {}, accumulatedEstimatedPackets {}",
                                    accumulatedEstimatedBytes,
                                    accumulatedEstimatedPackets);
            }
        }

        SPDLOG_LOGGER_TRACE(Logger::instance(), "Hops Counter: {}", hopsCounter);

        // [Co-developed with claude code -- Adam]
        // Bytes are scaled to bits for the flow rate; the packet rate must come from the
        // packet accumulator, not the byte one.
        const sflow::EstimatedRates rates = sflow::computeEstimatedRates(
            accumulatedEstimatedBytes * 8, accumulatedEstimatedPackets, hopsCounter);

        if (!rates.hasActiveHops)
        {
            // No activity, so clear the rates and continue
            info.estimatedFlowSendingRateImmediately = 0;
            info.estimatedPacketSendingRateImmediately = 0;
            info.isElephantFlowImmediately = false;
            continue;
        }

        info.estimatedFlowSendingRateImmediately = rates.flowSendingRate;

        if (info.estimatedFlowSendingRateImmediately >= MICE_FLOW_UNDER_THRESHOLD)
        {
            info.isElephantFlowImmediately = true;
        }
        else
        {
            info.isElephantFlowImmediately = false;
        }

        info.estimatedPacketSendingRateImmediately = rates.packetSendingRate;

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "FlowKey: {} -> {}",
                            utils::ipToString(flowKey.srcIP),
                            utils::ipToString(flowKey.dstIP));
        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "Estimated flow sending rate (Immediately): {}, packet sending rate: {}",
                            info.estimatedFlowSendingRateImmediately,
                            info.estimatedPacketSendingRateImmediately);
    }
}

void
FlowLinkUsageCollector::testCalAvgFlowSendingRatesRandomly()
{
    log_thread_ids("testCalAvgFlowSendingRatesRandomly");
    random_device rd;
    mt19937 gen(rd());
    uniform_int_distribution<> dist(500, 2000); // 500ms-2000ms between calls

    while (m_running.load())
    {
        calAvgFlowSendingRatesImmediately();

        int waitTime = dist(gen);

        SPDLOG_LOGGER_TRACE(Logger::instance(),
                            "FlowLinkUsageCollector::testCalAvgFlowSendingRatesRandomly() "
                            "Waiting for {} ms before next call...",
                            waitTime);
        this_thread::sleep_for(chrono::milliseconds(waitTime));
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting Loop of testCalAvgFlowSendingRatesRandomly");
}

inline string
FlowLinkUsageCollector::ourIpToString(uint32_t ipFront, uint32_t ipBack)
{
    string res;
    res = to_string((ipFront & 65535) >> 8) + "." + to_string(ipFront & 255) + "." +
          to_string(ipBack >> 24) + "." + to_string((ipBack >> 16) & 255);
    return res;
}

inline uint32_t
FlowLinkUsageCollector::ipFromFrontBack(uint32_t ipFront, uint32_t ipBack)
{
    // extract octets in network‐order
    uint8_t o1 = (ipFront >> 8) & 0xFF;
    uint8_t o2 = ipFront & 0xFF;
    uint8_t o3 = (ipBack >> 24) & 0xFF;
    uint8_t o4 = (ipBack >> 16) & 0xFF;

    // pack into a network‐order 32‑bit IP
    uint32_t netOrder =
        (uint32_t(o1) << 24) | (uint32_t(o2) << 16) | (uint32_t(o3) << 8) | (uint32_t(o4) << 0);

    return ntohl(netOrder);
}

void
FlowLinkUsageCollector::purgeIdleFlows()
{
    log_thread_ids("purgeIdleFlows");
    while (m_running.load())
    {
        vector<FlowKey> toRemove;
        {
            shared_lock lock(m_flowInfoTableMutex);
            int64_t now = utils::getCurrentTimeMillisSystemClock();

            for (auto& [flowKey, info] : m_flowInfoTable)
            {
                if (now <= info.endTime)
                {
                    continue;
                }
                int64_t idle_time = now - info.endTime;
                if (idle_time >= FLOW_IDLE_TIMEOUT)
                {
                    toRemove.push_back(flowKey);

                    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                        "Now: {} End Time: {}",
                                        now,
                                        info.endTime);
                    SPDLOG_LOGGER_INFO(Logger::instance(),
                                       "Flow Key: {} -> {} idles",
                                       utils::ipToString(flowKey.srcIP),
                                       utils::ipToString(flowKey.dstIP));

                    SPDLOG_LOGGER_DEBUG(
                        Logger::instance(),
                        "m_flowInfoTable[flowKey].estimatedFlowSendingRatePeriodically: "
                        "{}",
                        info.estimatedFlowSendingRatePeriodically);
                }
            }
        }

        for (const auto& key : toRemove)
        {
            {
                unique_lock lock(m_flowInfoTableMutex);
                m_flowInfoTable.erase(key);
            }
        }

        this_thread::sleep_for(chrono::milliseconds(1000));
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting Loop of purgeIdleFlows");
}

unordered_map<FlowKey, FlowInfo, FlowKeyHash>
FlowLinkUsageCollector::getFlowInfoTable()
{
    shared_lock lock(m_flowInfoTableMutex);
    return m_flowInfoTable;
}

// [Co-developed with claude code -- Adam]
// KNOWN-ISSUES B-x. The predicate that was missing. Every row is classified from the age of its
// most recent sample against the same `endTime` field purgeIdleFlows uses, so the two cannot
// disagree about what has ended: one field, one clock, two readers.
sflow::FlowLivenessCounts
FlowLinkUsageCollector::countFlowsByLiveness()
{
    shared_lock lock(m_flowInfoTableMutex);
    const int64_t now = utils::getCurrentTimeMillisSystemClock();
    sflow::FlowLivenessCounts counts;
    for (const auto& entry : m_flowInfoTable)
    {
        switch (sflow::classifyFlowLiveness(
            now, entry.second.endTime, m_flowActiveWindowMs, FLOW_IDLE_TIMEOUT))
        {
            case sflow::FlowLiveness::Active:
                ++counts.active;
                break;
            case sflow::FlowLiveness::Idle:
                ++counts.idle;
                break;
            case sflow::FlowLiveness::Ended:
                ++counts.ended;
                break;
        }
    }
    return counts;
}

nlohmann::json
FlowLinkUsageCollector::getFlowInfoJson(sflow::FlowLivenessFilter filter)
{
    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json result = nlohmann::json::array();

    // One `now` for the whole pass, not one per row. Two rows sampled in the same millisecond must
    // not be able to land in different classes because the clock moved between them; a caller
    // comparing counts across the array would then see a total that does not add up.
    // [Co-developed with claude code -- Adam]
    const int64_t now = utils::getCurrentTimeMillisSystemClock();

    // [Co-developed with claude code -- Adam]
    // Built once for the whole pass, then copied into every row: the health is a property of the
    // ingest window all these rates came out of, not of any one flow, and two rows in one body
    // must not be able to disagree about it. Beside the data on purpose -- an endpoint nobody
    // calls is the shape that let round 4's 2.76x under-report be invisible to every consumer.
    const nlohmann::json health = ingestHealthJson();

    for (const auto& [flowKey, flowInfo] : m_flowInfoTable)
    {
        const auto liveness = sflow::classifyFlowLiveness(
            now, flowInfo.endTime, m_flowActiveWindowMs, FLOW_IDLE_TIMEOUT);
        if (!sflow::passesLivenessFilter(liveness, filter))
        {
            continue;
        }

        nlohmann::json j;

        // [Co-developed with claude code -- Adam]
        // The three fields the record never had. Before this, a consumer holding a row could not
        // tell a flow that stopped fourteen seconds ago from one sending right now: the only
        // hint was `latest_sampled_time`, a preformatted "%Y-%m-%d %H:%M:%S" string that is
        // unusable for arithmetic and useless without FLOW_IDLE_TIMEOUT, which the API document
        // does not publish. These are raw epoch milliseconds precisely so no consumer has to
        // re-parse a display string to do subtraction.
        //
        // `ended_at_ms` is when this row WILL be eligible for the purge, derived from the same
        // last-seen stamp rather than stored, so it cannot drift out of agreement with `liveness`.
        // For an already-ended row it is in the past.
        j["liveness"] = sflow::toString(liveness);
        j["last_seen_ms"] = flowInfo.endTime;
        j["ended_at_ms"] = sflow::flowEndedAtMs(flowInfo.endTime, FLOW_IDLE_TIMEOUT);
        // Every rate in this row was computed from `telemetry_health.samples_in_window` samples,
        // out of `offered_in_window` the network tried to give us. [Co-developed ... -- Adam]
        j["telemetry_health"] = health;

        j["src_ip"] = flowKey.srcIP;
        j["dst_ip"] = flowKey.dstIP;
        j["src_port"] = flowKey.srcPort;
        j["dst_port"] = flowKey.dstPort;
        j["protocol_id"] = flowKey.protocol;
        // [Co-developed with claude code -- Adam] TICKET-P3 §2.3. Every existing key above is
        // untouched; this one says which family the four above are to be read as. It is "ipv4" on
        // every row this table can hold today -- and that is the point of publishing it: a
        // consumer that branches on it keeps working if the table ever carries another family,
        // whereas one that assumes IPv4 silently misreads the first IPv6 row it sees.
        j["family"] = sflow::toString(flowKey.family);

        j["estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot"] =
            flowInfo.estimatedFlowSendingRatePeriodically;
        j["estimated_flow_sending_rate_bps_in_the_last_sec"] =
            flowInfo.estimatedFlowSendingRateImmediately;
        j["estimated_packet_rate_in_the_proceeding_1sec_timeslot"] =
            flowInfo.estimatedPacketSendingRatePeriodically;
        j["estimated_packet_rate_in_the_last_sec"] = flowInfo.estimatedPacketSendingRateImmediately;
        j["first_sampled_time"] = utils::formatTime(flowInfo.startTime);
        j["latest_sampled_time"] = utils::formatTime(flowInfo.endTime);
        j["path"] = nlohmann::json::array();
        // for (const auto& [node, interface] : m_allPathMap[{flowKey.srcIP, flowKey.dstIP}])
        // {
        //     j["path"].push_back({{"node", node}, {"interface", interface}});
        // }
        for (const auto& [node, interface] : flowInfo.flowPath)
        {
            j["path"].push_back({{"node", node}, {"interface", interface}});
        }

        result.push_back(j);
    }

    return result;
}

nlohmann::json
FlowLinkUsageCollector::getTopKFlowInfoJson(int k, sflow::FlowLivenessFilter filter)
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "getTopKFlowInfoJson k={}", k);

    // 🔴 NO LOCK HERE. getFlowInfoJson() TAKES m_flowInfoTableMutex ITSELF, AND THIS USED TO
    // TAKE IT AGAIN. [Co-developed with claude code -- Adam]
    //
    // The line that stood here was `shared_lock lock(m_flowInfoTableMutex);`, one line above a
    // call to getFlowInfoJson(), which opens with the same acquisition. Recursively acquiring a
    // std::shared_mutex is undefined behaviour -- [thread.sharedmutex.requirements] says a
    // thread must not own the mutex when it calls lock_shared -- and five writers take
    // unique_lock on this same mutex (:1486 :1822 :2109 :2272 :2924).
    //
    // It never bit, and the reason it never bit is an implementation detail of this machine's C++
    // library rather than anything the code arranged: glibc's pthread_rwlock defaults to
    // PTHREAD_RWLOCK_PREFER_READER_NP, so a reader does not yield to a waiting writer and the
    // second rdlock on the same thread succeeds. Two named, checkable conditions turn it into a
    // self-deadlock -- the kind switched to PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP, or a
    // libstdc++ built without _GLIBCXX_USE_PTHREAD_RWLOCK_T so shared_mutex is the condvar
    // implementation. Either would wedge the thread between the two acquisitions, with a writer
    // in the middle. KNOWN-ISSUES §E-2.
    //
    // 🔑 And a wedge here is not one endpoint: the northbound API serialises, so the stuck
    // handler thread holds the whole server.
    //
    // Deleting the outer lock is the whole fix and it costs nothing, because there was never
    // anything to protect out here: getFlowInfoJson() returns a freshly built json array, and
    // every line below operates on that local copy. Nothing in this function reads a member.
    //
    // 📌 It also closes the note KNOWN-ISSUES filed beside the deadlock: the std::sort was
    // running INSIDE the shared lock, so the critical section grew as O(n log n) in the size of
    // the flow table. It is now outside, and the lock is held only for the copy.
    // [Co-developed with claude code -- Adam]
    // KNOWN-ISSUES B-x. The filter is applied HERE, before the sort and before `min(k, size)`,
    // not to the k rows that come out. Filtering afterwards would return fewer than k rows while
    // live ones sat just below the cut -- the caller asked for the busiest k flows, not for
    // whatever survives a predicate applied to an arbitrary prefix.
    //
    // 🔴 Not because dead flows outrank live ones. They do not: their sort key
    // (estimated_packet_rate_in_the_proceeding_1sec_timeslot) is cleared to 0 at :1911 whenever no
    // hop reported traffic, and 3040 measured observations on two arms found zero dead-and-nonzero
    // rows. The measured harm is that they FILL the list from the bottom -- median 4 of the top 10
    // rows were ended flows -- because at the churn working point fewer than ten flows are alive.
    // A predicate is the only thing that removes them; zeroing rate fields never could.
    nlohmann::json flowInfo = getFlowInfoJson(filter);
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "Total flows: {}", flowInfo.size());

    std::sort(flowInfo.begin(),
              flowInfo.end(),
              [](const nlohmann::json& a, const nlohmann::json& b) {
                  return a["estimated_packet_rate_in_the_proceeding_1sec_timeslot"].get<uint64_t>() >
                         b["estimated_packet_rate_in_the_proceeding_1sec_timeslot"].get<uint64_t>();
              });

    nlohmann::json topKFlows = nlohmann::json::array();
    for (int i = 0; i < std::min(k, static_cast<int>(flowInfo.size())); ++i)
    {
        topKFlows.push_back(flowInfo[i]);
    }

    return topKFlows;
}

void
FlowLinkUsageCollector::setAllPaths(std::vector<sflow::Path> allPathsVector)
{
    // [Co-developed with claude code -- Adam]
    // Both maps were written here with no lock at all, while getSwitchCount and
    // getAllSwitchCounts read m_switchCountMap under a shared_lock -- which protects readers
    // from each other and from nothing else. m_allPathMapMutex was declared and never used.
    // Concurrent operator[] insertion can rehash the map under a reader, which is a segfault,
    // not a stale value.
    //
    // The window used to be tiny because fetchAllDestinationPaths ran exactly once at startup.
    // refreshDestinationPathsPeriodically (added in e49327a, my own change) now calls this every
    // 5-60 seconds for the life of the process, against readers on the 1 Hz rate loop and on
    // every HTTP thread serving /ndt/get_path_switch_count. That turned a startup-only race into
    // a permanent one.
    //
    // scoped_lock rather than two unique_locks: it orders the acquisition itself, so this cannot
    // deadlock against a future caller that wants them the other way round.
    // [Co-developed with claude code -- Adam]
    // An empty snapshot is NOT applied, and the asymmetry with
    // Classifier::updateFromQueriedTables -- which does apply an empty table -- is deliberate.
    // There the empty array arrives keyed by dpid, so it is a definite statement about one switch:
    // "it has no rules". Here it means "I know of no paths at all", which before the control plane
    // converges is a transient, and acting on it would throw away good data during startup.
    // fetchAllDestinationPaths guards its own empty case already; the push path --
    // HttpSession::handleInformAllDestinationPaths -- does not, so a POST carrying
    // {"all_destination_paths": []} would otherwise clear everything.
    if (allPathsVector.empty())
    {
        return;
    }

    std::scoped_lock lock(m_allPathMapMutex, m_switchCountMapMutex);

    // Replace, do not merge. Both maps were filled with operator[] and never cleared, so an entry
    // outlived the path that produced it -- and paths do disappear: a link failure makes some host
    // pairs unreachable and the control plane stops reporting them. With
    // refreshDestinationPathsPeriodically calling this every 5-60 seconds for the life of the
    // process, get_path_switch_count would keep answering from a route that no longer exists.
    // Same shape as the Classifier's empty-table bug: a snapshot that only ever added.
    // Found by agy-review 0073.
    m_allPathMap.clear();
    m_switchCountMap.clear();

    for (const auto& path : allPathsVector)
    {
        // [Co-developed with claude code -- Adam]
        // front() and back() on an empty Path is undefined behaviour, not an empty result. Both
        // present callers do filter empty paths out -- HttpSession's push path and
        // fetchAllDestinationPaths -- but this is a public method, so the invariant belongs with
        // the code that depends on it rather than with whoever happens to call it today. The
        // switchCount line below already guards on size, so the sizes were known to vary.
        //
        // Skipped rather than rejected wholesale: one unusable path in a snapshot of hundreds
        // should not discard the rest. Found by agy-review 0110.
        if (path.empty())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "ignoring an empty path in a destination-path snapshot of {}",
                               allPathsVector.size());
            continue;
        }

        uint32_t srcIp = path.front().first;
        uint32_t dstIp = path.back().first;

        // Number of switches = total nodes - 2 (source and destination)
        size_t switchCount = path.size() > 1 ? path.size() - 2 : 0;
        SPDLOG_LOGGER_TRACE(Logger::instance(),
                            "Path from {} -> {} passes through {} switches.",
                            srcIp,
                            dstIp,
                            switchCount);
        m_switchCountMap[{srcIp, dstIp}] = switchCount;

        m_allPathMap[{srcIp, dstIp}] = path;
    }

    // Print out the map
    // for (const auto& [key, value] : m_allPathMap)
    // {
    //     const auto& [srcIp, dstIp] = key;
    //     std::ostringstream oss;

    //     oss << "Path: ";
    //     for (const auto& [nodeId, port] : value)
    //     {
    //         oss << "(" << nodeId << ", " << port << ") ";
    //     }

    //     SPDLOG_LOGGER_DEBUG(Logger::instance(), "Flow from {} -> {}: {}", srcIp, dstIp,
    //     oss.str());
    // }

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "m_allPathMap size {}", m_allPathMap.size());

    return;
}

std::map<std::pair<uint32_t, uint32_t>, Path>
FlowLinkUsageCollector::getAllPaths()
{
    // [Co-developed with claude code -- Adam]
    // Copying a std::map while another thread inserts into it is undefined behaviour; returning
    // by value does not make it safe.
    std::shared_lock<std::shared_mutex> lock(m_allPathMapMutex);
    return m_allPathMap;
}

void
FlowLinkUsageCollector::fetchAllDestinationPaths()
{
    // [Co-developed with claude code -- Adam]
    // Edge-triggered, and static because this function is called once per poll: a per-call log
    // would report the same malformed reply on every poll forever, which is the flood
    // KeyedFailureLog was written for. Same instrument walkFailures uses below.
    static utils::KeyedFailureLog pathFailures{std::chrono::seconds(60)};

    try
    {
        // 1. Build and run the curl command
        //    -s: silent mode
        //    -H: set header
        // [Co-developed with claude code -- Adam]
        // The proxy serves this endpoint in the same shape for a bmv2 fabric, so ask whichever
        // control plane actually owns the switches. Hardcoding Ryu meant P4 mode polled a port
        // nothing was listening on, which is why m_switchCountMap stayed empty and
        // get_path_switch_count answered "Path not found" even with the graph fully enabled.
        // [Co-developed with claude code -- Adam]
        // The timeouts are not tuning, they are the difference between this returning and this
        // wedging the process. Measured 2026-08-21: with nothing listening on the address, this
        // curl took **131 seconds**, because `localhost` sends curl at the IPv6 loopback first
        // and this machine drops those SYNs rather than refusing them, so it waited out the full
        // TCP connect timeout. The same request to 127.0.0.1 is refused in 0s. That is the whole
        // difference between "asks the wrong host and gets nothing", which the comment on
        // refreshDestinationPathsPeriodically assumed, and a kernel that does not answer for
        // over two minutes.
        //
        // connect-timeout covers the failure that actually bit; max-time bounds a control plane
        // that accepts the connection and then stalls mid-body. 10s is generous for a response
        // measured at 0.5s for 934 kB.
        const std::string cmd = "curl -s --connect-timeout 2 --max-time 10 "
                                "-H \"User-Agent: NDT-client/1.1\" "
                                "\"http://" +
                                controlPlaneHostAndPort() + "/ryu_server/all_destination_paths\"";
        const std::string output = utils::execCommand(cmd);

        if (output.empty()) return;

        // 2. Parse JSON
        auto body = json::parse(output);

        // 3. Check status field
        if (!body.contains("status") || body["status"] != "success")
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Controller returned error or missing status: {}",
                               body.dump());
            return;
        }

        // 4. Extract paths array
        const auto& allPathsJson = body.at("all_destination_paths");
        std::vector<sflow::Path> paths;
        for (const auto& pathJson : allPathsJson)
        {
            sflow::Path p;
            // [Co-developed with claude code -- Adam]
            // Was `nodeJson[0]` / `nodeJson[1]` with no size or type check. On a const json the
            // numeric operator[] forwards straight to std::vector::operator[] -- unlike the
            // object overload, which asserts -- so a hop array shorter than two elements read
            // past the end of the heap in every build type, and the catch below could not see
            // it. The value parses threw as well, costing every path after the bad one.
            //
            // A malformed hop discards its own path rather than the reply: a path with a hop
            // missing is not a path, but the other destinations are still good data.
            bool pathIsUsable = true;
            for (const auto& nodeJson : pathJson)
            {
                const auto hop = sflow::tryParsePathNode(nodeJson);
                if (!hop)
                {
                    pathFailures.record("malformed-hop",
                                        "all_destination_paths carried a hop that is not a "
                                        "well-formed [node, interface] pair; that path is "
                                        "skipped, the rest are kept");
                    pathIsUsable = false;
                    break;
                }
                p.emplace_back(hop->first, hop->second);
            }
            if (!pathIsUsable)
            {
                continue;
            }
            if (!p.empty())
            {
                paths.push_back(std::move(p));
            }
        }

        // 5. Update and log
        setAllPaths(paths);
        SPDLOG_LOGGER_INFO(Logger::instance(), "Pulled {} paths from controller", paths.size());
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Exception in pull_all_destination_paths (curl): {}",
                            e.what());
    }
}

// [Co-developed with claude code -- Adam]
// setAllPath (singular) was removed here. It had no callers -- only a declaration and a definition
// -- and it wrote m_allPathMap while leaving m_switchCountMap untouched, so the first caller to use
// it would have made getSwitchCount answer from a path it no longer matched. Dead code carrying a
// trap. Found by agy-review 0073.

std::vector<uint32_t>
FlowLinkUsageCollector::getAllHostIps()
{
    std::set<uint32_t> allHostIps;
    std::map<std::pair<uint32_t, uint32_t>, sflow::Path> allPaths = getAllPaths();

    for (const auto& [flowPair, path] : allPaths)
    {
        allHostIps.insert(flowPair.first);  // srcIp
        allHostIps.insert(flowPair.second); // dstIp
    }

    std::vector<uint32_t> hostIpList(allHostIps.begin(), allHostIps.end());

    return hostIpList;
}

void
FlowLinkUsageCollector::printAllPathMap()
{
    // [Co-developed with claude code -- Adam] Iterating while a writer inserts invalidates the
    // iterator, which is the crash this whole set of locks exists to prevent.
    std::shared_lock<std::shared_mutex> lock(m_allPathMapMutex);
    for (const auto& [key, value] : m_allPathMap)
    {
        const auto& [srcIp, dstIp] = key;
        std::ostringstream oss;

        oss << "Path: ";
        for (const auto& [nodeId, port] : value)
        {
            oss << "(" << nodeId << ", " << port << ") ";
        }

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "Flow from {} -> {}: {}",
                            utils::ipToString(srcIp),
                            utils::ipToString(dstIp),
                            oss.str());
    }
}

using Rule = std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>;

// (net, mask, outPort, priority)

// [Co-developed with claude code -- Adam]
// popcount32 was defined here with no caller anywhere in the project. Found by building
// under clang, whose -Wunused-function reported it; GCC's does not fire for a static inline
// in a .cpp. Deleted rather than kept "in case" -- git has it if it is ever wanted.

std::optional<size_t>
FlowLinkUsageCollector::getSwitchCount(std::pair<uint32_t, uint32_t> ipPair)
{
    // 1. Lock the mutex for thread-safe reading.
    // A shared_lock allows multiple readers at the same time.
    std::shared_lock<std::shared_mutex> lock(m_switchCountMapMutex);

    // 2. Use the .find() method to look for the key.
    // This is safer than operator[] because it doesn't insert a new element if the key isn't found.
    auto it = m_switchCountMap.find(ipPair);

    // 3. Check if the iterator is valid (i.e., the key was found).
    if (it != m_switchCountMap.end())
    {
        // The key exists, return the associated value (the switch count).
        return it->second;
    }

    // 4. The key was not found, return an empty optional to indicate failure.
    return std::nullopt;
}

std::map<std::pair<uint32_t, uint32_t>, size_t>
FlowLinkUsageCollector::getAllSwitchCounts()
{
    // 1. Acquire a shared lock for thread-safe reading of the map.
    std::shared_lock<std::shared_mutex> lock(m_switchCountMapMutex);

    // 2. Return a copy of the entire map. This is thread-safe because
    //    the caller gets a snapshot of the data and doesn't hold a lock.
    return m_switchCountMap;
}

json
FlowLinkUsageCollector::getPathBetweenHostsJson(const std::string& srcHostName,
                                                const std::string& dstHostName)
{
    // 1. Find hosts using the member variable m_topologyAndFlowMonitor
    auto srcHostOpt = m_topologyAndFlowMonitor->findVertexByDeviceName(srcHostName);
    auto dstHostOpt = m_topologyAndFlowMonitor->findVertexByDeviceName(dstHostName);

    // 2. Handle cases where one or both hosts are not found
    if (!srcHostOpt.has_value() || !dstHostOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts could not be found in the topology.";
        if (!srcHostOpt.has_value())
        {
            errorJson["missing_hosts"].push_back(srcHostName);
        }
        if (!dstHostOpt.has_value())
        {
            errorJson["missing_hosts"].push_back(dstHostName);
        }
        // [Co-developed with claude code -- Adam]
        // The object, not errorJson.dump(). The return type is json, so .dump() made this a JSON
        // *string value* that merely looked like JSON -- and the consumer in IntentTranslator
        // does `json path = ...; return path.dump();`, which then double-encoded it into a
        // quoted, escaped string. Success parsed as an object and failure did not, so a client
        // doing parsed["error"] hit a type mismatch exactly and only when something had gone
        // wrong.
        return errorJson;
    }

    // 3. Get the IP addresses
    auto graph = m_topologyAndFlowMonitor->getGraph();
    // [Co-developed with claude code -- Adam]
    // FINDINGS #88, W14. Both subscripts were unguarded, and `VertexProperties::ip` is a
    // std::vector that starts empty: libstdc++'s operator[] is `*(_M_start + n)` and a
    // default-constructed vector has _M_start == nullptr, so `ip[0]` on a host with no address
    // binds a reference to a null pointer -- the same undefined behaviour as `.front()`, spelled
    // differently. findVertexByDeviceName filters on name, not on whether the host has an
    // address, so nothing upstream of here excludes that host.
    //
    // The refusal is shaped like the "host not found" branch above rather than like a path
    // result, because that is what it is: a path is keyed by (srcIp, dstIp), and a host with no
    // address cannot be either end of that key. Answering "no path found" instead would report
    // a property of the network for what is a property of the topology record.
    const auto srcIpOpt = utils::firstAddressRaw(graph[*srcHostOpt].ip);
    const auto dstIpOpt = utils::firstAddressRaw(graph[*dstHostOpt].ip);
    if (!srcIpOpt.has_value() || !dstIpOpt.has_value())
    {
        json errorJson;
        errorJson["error"] = "One or both hosts carry no IP address in the topology.";
        if (!srcIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(srcHostName);
        }
        if (!dstIpOpt.has_value())
        {
            errorJson["hosts_without_address"].push_back(dstHostName);
        }
        return errorJson;
    }
    uint32_t srcIp = *srcIpOpt;
    uint32_t dstIp = *dstIpOpt;

    // 4. Retrieve the path map from this collector
    auto allPaths = this->getAllPaths();
    auto it = allPaths.find({srcIp, dstIp});

    if (it == allPaths.end())
    {
        // An object, for the same reason as the branch above: the string literal was a JSON
        // string value, not a JSON object. [Co-developed with claude code -- Adam]
        return json{{"error", "No active or known path found between the specified hosts."}};
    }

    const auto& path = it->second;

    // 5. Format the result
    json result;
    json pathJson = json::array();

    if (path.size() > 2)
    {
        for (size_t i = 1; i < path.size() - 1; ++i)
        {
            uint64_t dpid = path[i].first;
            auto switchVertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
            if (switchVertexOpt.has_value())
            {
                pathJson.push_back(graph[*switchVertexOpt].deviceName);
            }
            else
            {
                pathJson.push_back("unknown_switch_dpid_" + std::to_string(dpid));
            }
        }
    }

    result["source_host"] = srcHostName;
    result["destination_host"] = dstHostName;
    result["switch_path"] = pathJson;

    return result;
}

void
FlowLinkUsageCollector::calFlowPathByQueried()
{
    log_thread_ids("calFlowPathByQueried");
    using MapT = std::remove_reference_t<decltype(m_flowInfoTable)>;
    using FlowInfoKey = typename MapT::key_type;

    // [Co-developed with claude code -- Adam]
    // This loop re-derives every tracked flow's path every millisecond, and each failure used to
    // warn directly. One misconfigured host port therefore wrote 270,991 copies of
    // "edge not found by dpid/port 4:3" and a 41 MB kernel log -- a line that named the exact
    // fault, made unreadable by being repeated a quarter of a million times. Only the edges are
    // logged now: the first pass a failure appears in, and the pass it stops.
    // [Co-developed with claude code -- Adam]
    // 15s hold-off. For the first few seconds the flow tables are still being fetched one switch at
    // a time, so a path through a not-yet-loaded dpid legitimately fails: measured at 7454, 37 and
    // 29 passes on one real start, all of which then cleared. Reporting those would have put three
    // warnings in every clean startup, and the only ways to make the log check green again would be
    // to allowlist them -- which is exactly how the previous version of this warning became
    // unreadable -- or to raise the bar here. 15s is comfortably past the observed 7.4s worst case
    // while still catching a control plane that is genuinely absent.
    utils::KeyedFailureLog walkFailures{std::chrono::seconds(15)};

    while (m_running.load(std::memory_order_relaxed))
    {
        // Snapshot keys under a shared/read lock
        std::vector<FlowInfoKey> keys;
        {
            std::shared_lock<std::shared_mutex> lk(m_flowInfoTableMutex);
            keys.reserve(m_flowInfoTable.size());
            for (const auto& kv : m_flowInfoTable)
            {
                keys.push_back(kv.first);
            }
        }

        // Compute each path without holding m_flowInfoTableMutex
        for (const auto& flowKey : keys)
        {
            sflow::Path path;
            bool ok = true;

            // [Co-developed with claude code -- Adam]
            // `fk.vlanTci` is deliberately left at its 0 default: sFlow's flow key carries no
            // VLAN, and the rules this key is looked up against (built in
            // Classifier.cpp's flow-stats ingest) are 0 there too, so the two agree. That
            // agreement is load-bearing -- vlanTci is serialised into the key (Classifier.cpp:168),
            // so if the ingest side ever starts populating VLAN without this side doing the same,
            // every VLAN-tagged rule stops being findable from here. See the ⚠️ note at the
            // `vlan_vid` branch in Classifier.cpp before changing either side.
            ndtClassifier::FlowKey fk{};
            fk.ipProto = flowKey.protocol;
            fk.ipv4Dst = ntohl(flowKey.dstIP);
            fk.ipv4Src = ntohl(flowKey.srcIP);
            fk.tpDst = flowKey.dstPort;
            fk.tpSrc = flowKey.srcPort;
            fk.ethType = 0x0800;

            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "flow {}:{} to {}:{} proto num {}",
                                fk.ipv4Src,
                                fk.tpSrc,
                                fk.ipv4Dst,
                                fk.tpDst,
                                fk.ipProto);

            if (fk.ipv4Src == 0 || fk.ipv4Dst == 0)
            {
                ok = false;
                walkFailures.record("zero-ip", "flow path skipped: source or destination IP is 0");
            }
            else
            {
                auto edgeOpt = m_topologyAndFlowMonitor->findEdgeByHostIp(flowKey.srcIP);
                if (!edgeOpt.has_value())
                {
                    ok = false;
                    // Keyed on the source host only: every flow from an unknown host fails for
                    // the same one reason, and keying on the 5-tuple would report each of them.
                    walkFailures.record(
                        "host-edge:" + utils::ipToString(flowKey.srcIP),
                        fmt::format("no host edge for {}; flows from it cannot be traced "
                                    "(first seen for {} to {} proto {})",
                                    utils::ipToString(flowKey.srcIP),
                                    utils::ipToString(flowKey.srcIP),
                                    utils::ipToString(flowKey.dstIP),
                                    flowKey.protocol));
                }
                else
                {
                    auto edge = *edgeOpt;

                    auto graph = m_topologyAndFlowMonitor->getGraph();

                    path.push_back(std::make_pair(flowKey.srcIP, graph[edge].dstInterface));

                    int hop = 0;
                    for (hop = 0; hop < 100; ++hop)
                    {
                        auto srcSw = boost::target(edge, graph);

                        // Reached host vertex?
                        if (graph[srcSw].dpid == 0)
                        {
                            auto it = std::find(graph[srcSw].ip.begin(),
                                                graph[srcSw].ip.end(),
                                                flowKey.dstIP);
                            if (it != graph[srcSw].ip.end())
                            {
                                path.push_back(std::make_pair(flowKey.dstIP, 0));
                            }
                            break;
                        }

                        auto effect = m_classifier->lookup(graph[srcSw].dpid, fk);
                        if (!effect || effect->outputPorts.empty())
                        {
                            ok = false;
                            // [Co-developed with claude code -- Adam]
                            // This branch used to be silent, with the only diagnostic coming
                            // from a WARN inside lookup() that fired at 1 kHz. Reported here
                            // instead, once per distinct cause, and the two causes are worth
                            // telling apart: a switch the control plane never gave us versus
                            // one whose table has no matching rule.
                            const uint64_t missDpid = graph[srcSw].dpid;
                            if (!m_classifier->knowsSwitch(missDpid))
                            {
                                walkFailures.record(
                                    fmt::format("no-table:{}", missDpid),
                                    fmt::format("no flow table for dpid {}; the control plane has "
                                                "not reported it, so paths through it stay empty",
                                                missDpid));
                            }
                            else
                            {
                                walkFailures.record(
                                    fmt::format("no-rule:{}", missDpid),
                                    fmt::format("dpid {} has a flow table but no rule matches "
                                                "this flow; paths through it stay empty",
                                                missDpid));
                            }
                            break;
                        }

                        uint32_t outPort = effect->outputPorts.front();

                        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                            "effect outputPorts.size(): {} outputPorts.front() {}",
                                            effect->outputPorts.size(),
                                            outPort);

                        path.push_back(std::make_pair(graph[srcSw].dpid, outPort));

                        auto nextEdgeOpt = m_topologyAndFlowMonitor->findEdgeByDpidAndPort(
                            std::make_pair(graph[srcSw].dpid, outPort));

                        if (!nextEdgeOpt.has_value())
                        {
                            ok = false;
                            // The key is the dpid:port itself, which is the whole diagnostic:
                            // it says which link the topology file is missing.
                            walkFailures.record(
                                fmt::format("dpid-port:{}:{}", graph[srcSw].dpid, outPort),
                                fmt::format("edge not found by dpid/port {}:{}; the topology file "
                                            "has no link there, so paths through it stay empty",
                                            graph[srcSw].dpid,
                                            outPort));
                            break;
                        }

                        edge = *nextEdgeOpt;
                    }

                    if (hop >= 100)
                    {
                        ok = false;
                        // Kept as a direct WARN, not suppressed: this one is in the log check's
                        // FORBID list because a forwarding loop is never acceptable, and it is
                        // bounded at 100 iterations per flow rather than unbounded per pass.
                        SPDLOG_LOGGER_WARN(Logger::instance(),
                                           "Exceed 100 hop (potential loop) {} -> {}",
                                           utils::ipToString(flowKey.srcIP),
                                           utils::ipToString(flowKey.dstIP));
                    }
                }
            }

            // Commit the result under unique lock (no operator[]; don’t insert)
            {
                std::unique_lock<std::shared_mutex> lk(m_flowInfoTableMutex);
                auto it = m_flowInfoTable.find(flowKey);
                if (it != m_flowInfoTable.end())
                {
                    it->second.flowPath = ok ? std::move(path) : sflow::Path{};
                }
            }
        }

        // [Co-developed with claude code -- Adam]
        // Exactly once per pass, after every record() above.
        const auto report = walkFailures.endPass();
        for (const auto& [key, message] : report.newFailures)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "{}", message);
        }
        for (const auto& [key, passes] : report.recovered)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "path-walk failure '{}' cleared after {} pass(es)",
                               key,
                               passes);
        }

        // [Co-developed with claude code -- Adam]
        // Ticket M: was microseconds(1000), i.e. this loop re-derived every tracked flow's path
        // a thousand times a second. Profiling attributed 46.31% of the kernel's CPU to this one
        // function, on a single thread, and that cost was paid in full at the LOWEST sampling
        // rate -- it is a fixed cost, not a per-sample one.
        //
        // WHAT THE 1 kHz WAS BUYING, written down before the wait was touched: exactly one
        // thing, a 1 ms freshness bound on the API's `path` field. flowPath has a single reader
        // in the whole repo (getFlowInfoJson, :2256) and one writer (:2864); tests/, tools/ and
        // p4_proxy/ have none. At 1 Hz the bound becomes 1 s.
        //
        // THE RISK IS NOT PERFORMANCE, IT IS SHORT FLOWS. Between a flow appearing and the next
        // pass, its `path` is empty: 0.5 s on average, 1 s worst case. FLOW_IDLE_TIMEOUT is
        // 15 s (include/.../FlowLinkUsageCollector.hpp:34), so a flow shorter than one pass can
        // live and die without ever having a path. A steady 300-second-flow workload would show
        // this as 0.5/300 = 0.17% and report green, which is why ticket M's churn arm exists --
        // this project has already shipped a speedup that measured CPU and connectivity green
        // while what broke was model fidelity.
        //
        // The interval is a named constant so the arms can state which value they measured
        // rather than citing a line number that moves.
        std::this_thread::sleep_for(kFlowPathRecomputeInterval);
    }
}

} // namespace sflow
