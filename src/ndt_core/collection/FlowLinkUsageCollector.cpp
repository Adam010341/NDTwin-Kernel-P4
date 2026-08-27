#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "common_types/GraphTypes.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
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
    m_sockfd = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (m_sockfd < 0)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "socket() failed: {}", strerror(errno));
        throw std::runtime_error("Failed to create UDP socket");
    }

    // Increase receive buffer
    int rcvbuf = 4 * 1024 * 1024; // 4 MB
    setsockopt(m_sockfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    // [Co-developed with claude code -- Adam]
    // SO_REUSEADDR was set here and has been removed deliberately. On Linux, two unicast UDP
    // sockets may both bind the same port when both set it -- measured, not assumed -- and the
    // datagrams are then delivered to whichever bound *last*. So a second kernel started while
    // the first was still running did not fail: it silently took the sFlow feed, and the older
    // kernel went deaf while continuing to report a healthy zero. UDP has no TIME_WAIT, so the
    // option was buying nothing in exchange for that. Without it the second bind gets EADDRINUSE,
    // which is a diagnosis rather than a mystery.
    int one = 1;
    setsockopt(m_sockfd, SOL_SOCKET, SO_RXQ_OVFL, &one, sizeof(one));

    // Non-blocking mode
    int flags = fcntl(m_sockfd, F_GETFL, 0);
    fcntl(m_sockfd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_in bindAddr{};
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(SFLOW_PORT);
    bindAddr.sin_addr.s_addr = INADDR_ANY;
    if (::bind(m_sockfd, reinterpret_cast<sockaddr*>(&bindAddr), sizeof(bindAddr)) < 0)
    {
        const int err = errno;
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "bind() to sFlow port {} failed: {}. Another NDTwin kernel is almost "
                            "certainly still running and holding it; without telemetry this twin "
                            "would report every flow rate as zero, so it will not start.",
                            SFLOW_PORT,
                            strerror(err));
        ::close(m_sockfd);
        // Left at -1 so stop() and the destructor do not close a descriptor number that has since
        // been handed to somebody else.
        m_sockfd = -1;
        throw std::runtime_error("Failed to bind UDP socket");
    }
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

            // 1. Extract flow data. Offsets differ by vendor.
            uint32_t inputPort, outputPort, frameLength;
            uint8_t protocol;
            uint32_t srcIp, dstIp;
            uint16_t srcPort, dstPort, icmpType, icmpCode;
            uint32_t flowDataLength = 0;
            uint32_t samplingRate = ntohl(data[index + 4]);

            uint16_t etherType = 0;
            uint16_t frag;
            uint16_t fragOff;
            bool mf;
            bool df;

            bool isAckPacket = false;
            const uint8_t TCP_ACK_FLAG = 0x10;

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

                etherType = ntohl(data[index + 19]) >> 16 & 0xFFFF;

                SPDLOG_LOGGER_TRACE(Logger::instance(), "etherType = 0x{:04x}", etherType);
                if (etherType != 0x0800)
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Not IPv4 packet, etherType {}",
                                        etherType);
                    if (m_mode == utils::MININET)
                    {
                        index += (sampleLen / 4 + 2 - (flowDataLength / 4 + 2));
                    }
                    else
                    {
                        index += (sampleLen / 4 + 2);
                    }
                    continue;
                }

                uint32_t w21 = ntohl(data[index + 21]);

                // bytes 6..7 of IPv4 header (flags+fragment offset)
                frag = (w21 >> 16) & 0xFFFF;

                mf = (frag & 0x2000) != 0; // More fragments
                df = (frag & 0x4000) != 0; // Don't fragment
                fragOff = frag & 0x1FFF;   // in 8-byte units

                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "ntohl(data[index + 21]) {}",
                                    ntohl(data[index + 21]));
                protocol = ntohl(data[index + 21]) & 0xFF;
                srcIp = ipFromFrontBack(ntohl(data[index + 22]), ntohl(data[index + 23]));
                dstIp = ipFromFrontBack(ntohl(data[index + 23]), ntohl(data[index + 24]));
                if (protocol != 1)
                {
                    srcPort = ntohl(data[index + 24]) & 0xFFFF;
                    dstPort = (ntohl(data[index + 25]) >> 16) & 0xFFFF;
                    if (protocol == 6)
                    {
                        uint8_t tcpFlags = (ntohl(data[index + 28]) >> 8) & 0xFF;

                        if (tcpFlags & TCP_ACK_FLAG)
                        {
                            isAckPacket = true;
                        }
                    }
                }
                else
                {
                    icmpType = (ntohl(data[index + 24]) >> 8) & 0xFF;
                    icmpCode = ntohl(data[index + 24]) & 0xF;
                }
            }
            else
            { // HPE (sampleType == 3)
                samplingRate = ntohl(data[index + 5]);
                inputPort = ntohl(data[index + 9]);
                outputPort = ntohl(data[index + 11]);
                frameLength = ntohl(data[index + 12 + 4]);

                etherType = ntohl(data[index + 12 + 6 + 5]) >> 16 & 0xFFFF;

                SPDLOG_LOGGER_TRACE(Logger::instance(), "etherType = 0x{:04x}", etherType);
                if (etherType != 0x0800)
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Not IPv4 packet, etherType {}",
                                        etherType);
                    if (m_mode == utils::MININET)
                    {
                        index += (sampleLen / 4 + 2 - (flowDataLength / 4 + 2));
                    }
                    else
                    {
                        index += (sampleLen / 4 + 2);
                    }
                    continue;
                }

                uint32_t w25 = ntohl(data[index + 25]);
                frag = (w25 >> 16) & 0xFFFF;

                mf = (frag & 0x2000) != 0;
                df = (frag & 0x4000) != 0;
                fragOff = frag & 0x1FFF; // in 8-byte units

                protocol = ntohl(data[index + 12 + 6 + 7]) & 0xFF;
                srcIp = ipFromFrontBack(ntohl(data[index + 12 + 6 + 7 + 1]),
                                        ntohl(data[index + 12 + 6 + 7 + 2]));
                dstIp = ipFromFrontBack(ntohl(data[index + 12 + 6 + 7 + 2]),
                                        ntohl(data[index + 12 + 6 + 7 + 3]));
                if (protocol != 1)
                {
                    srcPort = ntohl(data[index + 12 + 6 + 7 + 3]) & 0xFFFF;
                    dstPort = (ntohl(data[index + 12 + 6 + 7 + 4]) >> 16) & 0xFFFF;
                    if (protocol == 6) // It's a TCP packet
                    {
                        uint8_t tcpFlags = (ntohl(data[index + 32]) >> 8) & 0xFF;

                        if (tcpFlags & TCP_ACK_FLAG)
                        {
                            isAckPacket = true;
                        }
                    }
                }
                else
                {
                    icmpType = ntohl(data[index + 28] >> 8) & 0xFF;
                    icmpCode = ntohl(data[index + 28]) & 0xF;
                }
            }

            if (m_mode == utils::TESTBED)
            {
                SPDLOG_LOGGER_TRACE(
                    Logger::instance(),
                    "FLOW SAMPLE from Agent {}: {} -> {} (Proto: {}, Len: {}, Input "
                    "port: {}, Ouput port: {} ICMP type {} ICMP code {}, Sampling rate {})",
                    agentIpStr,
                    utils::ipToString(srcIp),
                    utils::ipToString(dstIp),
                    protocol,
                    frameLength,
                    inputPort,
                    outputPort,
                    icmpType,
                    icmpCode,
                    samplingRate);
            }

            // check whether it is pure ack
            bool isPureAck = false;
            if (protocol == 6) // Check if it's a TCP packet first
            {
                const uint32_t PURE_ACK_SIZE_THRESHOLD = 80; // Your proposed threshold

                // isAckPacket should be true if the ACK flag is set
                if (isAckPacket && frameLength < PURE_ACK_SIZE_THRESHOLD)
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Pure ACK packet (size: {} bytes)",
                                        frameLength);
                    isPureAck = true;
                }
            }

            // 2. Process the extracted data using common logic.
            if (protocol == 6 || protocol == 17 || protocol == 1) // TCP, UDP, or ICMP
            {
                if (m_mode == utils::MININET)
                {
                    // Read-only lookup: operator[] would insert a 0 entry for every unknown
                    // ifIndex, mutating the map from a worker thread without the mutex.
                    inputPort = lookupOfport(inputPort);
                    outputPort = lookupOfport(outputPort);
                    SPDLOG_LOGGER_TRACE(
                        Logger::instance(),
                        "FLOW SAMPLE in Mininet from Agent {}: {} -> {} (Proto: {}, Len: {}, Input "
                        "port: {}, Ouput port: {}, frag: {:#06x})",
                        agentIpStr,
                        utils::ipToString(srcIp),
                        utils::ipToString(dstIp),
                        protocol,
                        frameLength,
                        inputPort,
                        outputPort,
                        static_cast<uint32_t>(frag));
                }

                bool isIngress = (inputPort != 0); // Simple direction check
                uint32_t relevantPort = isIngress ? inputPort : outputPort;

                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "Flow Sample Recieve Src Ip {}, Dst Ip {}, Src port {}, Dst "
                                    "port {}, Protocol {}, frag {:#06x}",
                                    utils::ipToString(srcIp),
                                    utils::ipToString(dstIp),
                                    srcPort,
                                    dstPort,
                                    protocol,
                                    static_cast<uint32_t>(frag));

                // Drop non-first fragments (they don't have UDP/TCP ports)
                if (fragOff != 0)
                {
                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Drop non-first fragment: frag={:#06x} off={} mf={} df={}",
                                        frag,
                                        fragOff,
                                        mf,
                                        df);
                    continue;
                }

                FlowKey key = {};
                if (protocol != 1)
                {
                    key = {srcIp, dstIp, srcPort, dstPort, protocol};
                }
                else
                {
                    key = {srcIp, dstIp, icmpType, icmpCode, protocol};
                }

                AgentKey agentKey = {agentIp, relevantPort};

                if (m_mode == utils::MININET)
                {
                    std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);
                    m_counterReports[make_pair(agentIp, relevantPort)]
                        .inputByteCountOnALinkMultiplySampingRate +=
                        uint64_t(frameLength) * samplingRate;

                    // The same sample also crossed the sampling switch's *egress* edge. For a
                    // switch-to-switch edge that credit belongs to the downstream sampler, but
                    // the last hop of a path ends at a host, which has no sampler -- so the
                    // egress side is banked here and creditHostBoundEgressEdges pays out only
                    // the host-bound entries. Guarded on isIngress: an ingress-less sample has
                    // already been keyed by its output port on the line above, and banking it
                    // twice would count the same bytes twice. [Co-developed with claude code -- Adam]
                    if (isIngress && outputPort != 0)
                    {
                        m_egressCounterReports[make_pair(agentIp, outputPort)]
                            .inputByteCountOnALinkMultiplySampingRate +=
                            uint64_t(frameLength) * samplingRate;
                    }
                }

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
                    info.isAck = isAckPacket;

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
FlowLinkUsageCollector::calAvgFlowSendingRatesPeriodically()
{
    log_thread_ids("calAvgFlowSendingRatesPeriodically");

    // [Co-developed with claude code -- Adam]
    // Loop-scoped rather than function-local statics: statics are shared by every instance of the
    // class, so two collectors in one process -- which a test can easily create -- would report
    // each other's deltas.
    uint64_t lastSockOvfl = 0;
    uint64_t lastAppDrop = 0;

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
    // It is also the acceptance instrument for the fix. Once the accumulator is divided by the
    // measured interval instead of an assumed one, this line must read ~1000 ms forever.
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

        // Estimate average flow sending rate
        {
            unique_lock lock(m_flowInfoTableMutex);
            for (auto& [flowKey, info] : m_flowInfoTable)
            {
                uint64_t avgFlowSendingRateTemp = 0;
                uint64_t avgPacketSendingRateTemp = 0;
                int hopsCounter = 0;
                for (auto& [agentKey, stats] : info.agentFlowStats)
                {
                    // --- 1. CALCULATE ALL RATES FOR THE CURRENT INTERVAL ---

                    uint32_t currentSamplingRate =
                        (stats.samplingRate > 0) ? stats.samplingRate : 1;

                    // Calculate byte rate
                    uint64_t byte_count_current =
                        stats.ingressByteCountCurrent + stats.egressByteCountCurrent;
                    uint64_t byte_count_previous =
                        stats.ingressByteCountPrevious + stats.egressByteCountPrevious;
                    // counterDelta, not a bare subtraction: these are uint64_t, so a counter
                    // that went backwards wrapped to ~1.8e19 and was reported as the flow's bit
                    // rate. [Co-developed with claude code -- Adam]
                    stats.avgByteRateInBps =
                        sflow::counterDelta(byte_count_current, byte_count_previous) * 8 *
                        currentSamplingRate;

                    SPDLOG_LOGGER_TRACE(Logger::instance(),
                                        "Agent {}:{} Current ingress byte counter: {},Current "
                                        "egress byte counter: {} stats.avgByteRateInBps {}",
                                        utils::ipToString(agentKey.agentIP),
                                        agentKey.interfacePort,
                                        stats.ingressByteCountCurrent,
                                        stats.egressByteCountCurrent,
                                        stats.avgByteRateInBps);

                    // Calculate packet rate
                    uint64_t packetCountCurrent =
                        stats.ingresspacketCountCurrent + stats.egresspacketCountCurrent;
                    uint64_t packetCountPrevious =
                        stats.ingresspacketCountPrevious + stats.egresspacketCountPrevious;
                    stats.avgPacketRate =
                        sflow::counterDelta(packetCountCurrent, packetCountPrevious) *
                        currentSamplingRate;

                    // --- 2. AGGREGATE THE RESULTS  ---

                    avgFlowSendingRateTemp += stats.avgByteRateInBps;
                    avgPacketSendingRateTemp += stats.avgPacketRate;

                    if (stats.avgByteRateInBps != 0)
                    {
                        hopsCounter++;
                    }

                    // --- 3. UPDATE STATE FOR THE *NEXT* INTERVAL ---
                    // All state updates are done together at the end.

                    stats.ingressByteCountPrevious = stats.ingressByteCountCurrent;
                    stats.egressByteCountPrevious = stats.egressByteCountCurrent;
                    stats.ingresspacketCountPrevious = stats.ingresspacketCountCurrent;
                    stats.egresspacketCountPrevious = stats.egresspacketCountCurrent;
                }

                SPDLOG_LOGGER_TRACE(Logger::instance(), "Hops counter: {}", hopsCounter);

                const sflow::EstimatedRates rates = sflow::computeEstimatedRates(
                    avgFlowSendingRateTemp, avgPacketSendingRateTemp, hopsCounter);

                if (!rates.hasActiveHops)
                {
                    // [Co-developed with claude code -- Adam]
                    // Clear, exactly as the Immediately path a few hundred lines below does.
                    //
                    // This used to `continue` without clearing, justified as "leave the previous
                    // estimates in place rather than dividing by zero" -- but that reason does not
                    // hold: the divide-by-zero is already prevented by `hasActiveHops` itself, and
                    // writing 0 divides by nothing. What to report *after* the guard was a separate
                    // choice, and carrying the old value forward was the wrong one.
                    //
                    // The consequence was not cosmetic. getTopKFlowInfoJson orders by
                    // estimated_packet_rate_in_the_proceeding_1sec_timeslot -- this field -- so a
                    // flow that stopped kept its last non-zero rate forever, stayed flagged as an
                    // elephant, and never left top-k. Measured: five and ten seconds after iperf3
                    // ended, top-k still reported a bit-identical 20.3 Mbps / 10496 pps while
                    // `_in_the_last_sec` in the same object read 0 (KNOWN-ISSUES A-3, reproduced in
                    // scratch/phase2/FINDINGS.md E9). Optimistic failure: it shows load that is not
                    // there, and it looks like stability rather than staleness.
                    //
                    // Introduced on this branch by the divide-by-zero guard (31b357a6), so it is
                    // ours to fix.
                    info.estimatedFlowSendingRatePeriodically = 0;
                    info.estimatedPacketSendingRatePeriodically = 0;
                    info.isElephantFlowPeriodically = false;
                    continue;
                }

                uint64_t estimatedFlowSendingRatePeriodically = rates.flowSendingRate;
                info.estimatedFlowSendingRatePeriodically = estimatedFlowSendingRatePeriodically;

                // [Co-developed with claude code -- Adam]
                // The else was commented out, so the flag latched: once set it was never cleared,
                // and a flow that spiked for one interval stayed an elephant for the rest of the
                // process. The name says "Periodically" -- it is meant to describe this interval --
                // and the Immediately variant a few hundred lines down has always had its else, so
                // this was an oversight rather than a decision.
                //
                // A latched flag mattered more than it looks: the unsigned underflow above could
                // set it from a single lost counter update, permanently.
                if (estimatedFlowSendingRatePeriodically >= MICE_FLOW_UNDER_THRESHOLD)
                {
                    info.isElephantFlowPeriodically = true;
                }
                else
                {
                    info.isElephantFlowPeriodically = false;
                }

                uint64_t estimatedPacketSendingRatePeriodically = rates.packetSendingRate;
                info.estimatedPacketSendingRatePeriodically =
                    estimatedPacketSendingRatePeriodically;

                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "FlowKey: {} -> {}",
                                    utils::ipToString(flowKey.srcIP),
                                    utils::ipToString(flowKey.dstIP));
                SPDLOG_LOGGER_TRACE(Logger::instance(),
                                    "Estimated flow sending rate (Periodically): {}",
                                    estimatedFlowSendingRatePeriodically);
            }
        }

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
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "rate divisor check: measured_interval_s={:.6f} divisor_used_s={:.6f}"
                               " (ticket Q gate: these must agree to 1%; a negative divisor means "
                               "no rate has been published yet, which is not a pass)",
                               drainElapsedSeconds, used);
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

nlohmann::json
FlowLinkUsageCollector::getFlowInfoJson()
{
    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json result = nlohmann::json::array();

    for (const auto& [flowKey, flowInfo] : m_flowInfoTable)
    {
        nlohmann::json j;

        j["src_ip"] = flowKey.srcIP;
        j["dst_ip"] = flowKey.dstIP;
        j["src_port"] = flowKey.srcPort;
        j["dst_port"] = flowKey.dstPort;
        j["protocol_id"] = flowKey.protocol;

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
FlowLinkUsageCollector::getTopKFlowInfoJson(int k)
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "getTopKFlowInfoJson k={}", k);
    shared_lock lock(m_flowInfoTableMutex);
    nlohmann::json flowInfo = getFlowInfoJson();
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
    uint32_t srcIp = graph[*srcHostOpt].ip[0];
    uint32_t dstIp = graph[*dstHostOpt].ip[0];

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
