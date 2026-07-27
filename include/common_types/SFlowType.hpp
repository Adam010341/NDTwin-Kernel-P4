#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <nlohmann/json.hpp>
#include <queue>
#include <string>
#include <vector>

using json = nlohmann::json;

constexpr int64_t TIME_UNIT_INTERVAL = 1000; // e.g. 1000 ms = 1 second

namespace sflow
{

/**
 * @brief Key that uniquely identifies a network flow.
 *
 * Describes a flow by its 5-tuple (src/dst IP and ports, protocol) plus
 * optional ICMP type/code for finer classification.
 */
struct FlowKey
{
    uint32_t srcIP; // in network order
    uint32_t dstIP; // in network order
    uint16_t srcPort;
    uint16_t dstPort;
    uint8_t protocol = 0;
    uint16_t icmpType = 0;
    uint16_t icmpCode = 0;

    bool operator==(const FlowKey& o) const = default;

    bool operator<(const FlowKey& o) const
    {
        return std::tie(srcIP, dstIP, srcPort, dstPort, protocol) <
               std::tie(o.srcIP, o.dstIP, o.srcPort, o.dstPort, o.protocol);
    }
};

/**
 * @brief Key for identifying an sFlow agent and interface.
 *
 * Combines the agent's IP address and a specific interface port index.
 */
struct AgentKey
{
    uint32_t agentIP;
    uint32_t interfacePort;

    bool operator==(const AgentKey& o) const = default;

    bool operator<(const AgentKey& o) const
    {
        return std::tie(agentIP, interfacePort) < std::tie(o.agentIP, o.interfacePort);
    }
};

/**
 * @brief End-to-end path represented as (node, interface) hops.
 *
 * Each element stores a datapath or host identifier together with the
 * outgoing interface used at that hop.
 */
typedef std::vector<std::pair<uint64_t, uint32_t>> Path;

/**
 * @brief Minimal sFlow sample data used for rate calculations.
 *
 * Stores the observed packet length and the sampling timestamp in milliseconds.
 */
struct ExtractedSFlowData
{
    uint32_t packetFrameLengthInByte;
    int64_t timestampInMilliseconds = 0;
};

/**
 * @brief Time-based sliding window over packet samples.
 *
 * Maintains a deque of ExtractedSFlowData entries and keeps only those
 * within the most recent configured interval, allowing fast access to
 * the total byte count in that window.
 */
class AutoRefreshQueue
{
  public:
    explicit AutoRefreshQueue(int64_t interval = TIME_UNIT_INTERVAL)
        : m_interval(interval),
          m_sum(0)
    {
    }

    /**
     * @brief Adds a new sample and prunes stale entries.
     *
     * The sample is appended to the queue, its size is added to the sum,
     * and any entries older than the interval are removed.
     */
    void push(const ExtractedSFlowData& sample)
    {
        m_queue.push_back(sample);
        m_sum += sample.packetFrameLengthInByte;
        refresh();
    }

    /**
     * @brief Returns the sum of packet lengths in the current window.
     *
     * Before returning, the queue is refreshed so that only samples from
     * the last interval are counted.
     */
    uint64_t getSum()
    {
        refresh();
        return m_sum;
    }

    /**
     * @brief Clears all samples and resets the accumulated sum.
     */
    void clear()
    {
        m_queue.clear();
        m_sum = 0;
    }

    /**
     * @brief Returns how many samples are currently in the window.
     */
    size_t size() const
    {
        return m_queue.size();
    }

  private:
    /**
     * @brief Removes samples older than the configured interval.
     *
     * Compares each sample timestamp against the current time and drops
     * those that fall outside the time window, updating the running sum.
     */
    void refresh()
    {
        int64_t now = duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now().time_since_epoch())
                          .count();
        while (!m_queue.empty() && now - m_queue.front().timestampInMilliseconds > m_interval)
        {
            m_sum -= m_queue.front().packetFrameLengthInByte;
            m_queue.pop_front();
        }
    }

    std::deque<ExtractedSFlowData> m_queue;
    const int64_t m_interval;
    uint64_t m_sum;
};

/**
 * @brief Per-flow traffic counters and derived rates.
 *
 * Tracks ingress/egress byte and packet counters over time, along with
 * computed average rates and a sliding window of recent samples.
 */
struct FlowStats
{
    uint64_t ingressByteCountCurrent = 0;
    uint64_t egressByteCountCurrent = 0;
    uint64_t ingressByteCountPrevious = 0;
    uint64_t egressByteCountPrevious = 0;
    uint64_t ingresspacketCountCurrent = 0;
    uint64_t egresspacketCountCurrent = 0;
    uint64_t ingresspacketCountPrevious = 0;
    uint64_t egresspacketCountPrevious = 0;

    uint64_t avgByteRateInBps = 0;
    uint64_t avgPacketRate = 0;
    uint32_t samplingRate = 1;
    AutoRefreshQueue packetQueue;
};

/**
 * @brief Averaged sending rates for a flow, plus whether any hop observed traffic.
 *
 * [Co-developed with claude code -- Adam]
 */
struct EstimatedRates
{
    uint64_t flowSendingRate = 0;   // bits per second
    uint64_t packetSendingRate = 0; // packets per second
    bool hasActiveHops = false;     // false when no hop reported traffic this interval
};

/**
 * @brief Averages accumulated per-hop rates over the hops that actually saw traffic.
 *
 * Callers accumulate per-agent rates and count how many hops reported non-zero
 * traffic in the interval. When that count is zero there is nothing to average:
 * this returns hasActiveHops == false so the caller can skip the flow instead of
 * dividing by zero.
 *
 * @param accumulatedFlowRate Sum of per-hop bit rates (already scaled by sampling rate).
 * @param accumulatedPacketRate Sum of per-hop packet rates.
 * @param hopsCounter Number of hops that observed traffic this interval.
 * @return Averaged rates, or a zeroed result with hasActiveHops == false.
 *
 * [Co-developed with claude code -- Adam]
 */
inline EstimatedRates
computeEstimatedRates(uint64_t accumulatedFlowRate,
                      uint64_t accumulatedPacketRate,
                      int hopsCounter)
{
    if (hopsCounter <= 0)
    {
        return {};
    }

    const uint64_t hops = static_cast<uint64_t>(hopsCounter);
    return {accumulatedFlowRate / hops, accumulatedPacketRate / hops, true};
}

/**
 * @brief Detailed view of a single flow across the network.
 *
 * Aggregates statistics from all observing agents, estimated sending
 * rates, lifetime timestamps and elephant-flow classification flags.
 */
struct FlowInfo
{
    /**
     * @brief Flow statistics grouped by observing agent.
     *
     * The key identifies the sFlow agent and interface; the value
     * describes counters and computed rates for that agent.
     */
    std::map<AgentKey, FlowStats> agentFlowStats;
    uint64_t estimatedFlowSendingRatePeriodically = 0;
    uint64_t estimatedFlowSendingRateImmediately = 0;
    uint64_t estimatedPacketSendingRatePeriodically = 0;
    uint64_t estimatedPacketSendingRateImmediately = 0;
    int64_t startTime = 0;
    int64_t endTime = 0;
    bool isElephantFlowPeriodically = false;
    bool isElephantFlowImmediately = false;
    bool isAck = false;
    bool isPureAck = false;
    Path flowPath;
};

template <typename T>
inline void
hashCombine(std::size_t& seed, const T& val)
{
    seed ^= std::hash<T>{}(val) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
}

struct FlowKeyHash
{
    std::size_t operator()(const FlowKey& key) const
    {
        std::size_t seed = 0;
        hashCombine(seed, key.srcIP);
        hashCombine(seed, key.dstIP);
        hashCombine(seed, key.srcPort);
        hashCombine(seed, key.dstPort);
        hashCombine(seed, key.protocol);
        return seed;
    }
};

/**
 * @brief Cached counter state for a single link.
 *
 * Stores the last reported octet values and computed byte counts for
 * input and output directions on a link.
 */
struct CounterInfo
{
    int64_t lastReportTimestampInMilliseconds = 0;
    uint64_t lastReceivedInputOctets;
    uint64_t lastReceivedOutputOctets;
    uint64_t inputByteCountOnALinkMultiplySampingRate = 0;
    uint64_t outputByteCountOnALink = 0;
};

struct FlowChange
{
    uint32_t dstNet;          // network address (ip & mask)
    uint32_t dstMask;         // e.g., 0xFFFFFF00
    uint32_t priority;        // OpenFlow priority
    uint32_t oldOutInterface; // 0 if added
    uint32_t newOutInterface; // 0 if removed
};

struct FlowDiff
{
    uint64_t dpid;
    std::vector<FlowChange> added;
    std::vector<FlowChange> removed;
    std::vector<FlowChange> modified;
};

inline void
to_json(nlohmann::json& j, const FlowKey& fk)
{
    j = nlohmann::json{{"src_ip", fk.srcIP},
                       {"dst_ip", fk.dstIP},
                       {"src_port", fk.srcPort},
                       {"dst_port", fk.dstPort},
                       {"protocol_number", fk.protocol}};
}

inline void
from_json(const nlohmann::json& j, FlowKey& fk)
{
    fk.srcIP = j.at("src_ip").get<uint32_t>();
    fk.dstIP = j.at("dst_ip").get<uint32_t>();
    fk.srcPort = j.at("src_port").get<uint16_t>();
    fk.dstPort = j.at("dst_port").get<uint16_t>();
    fk.protocol = j.at("protocol_number").get<uint8_t>();
}

using Key = std::tuple<uint32_t, uint32_t, uint32_t>; // net, mask, pri

struct KeyHash
{
    size_t operator()(const Key& k) const noexcept
    {
        auto h1 = std::hash<uint32_t>{}(std::get<0>(k));
        auto h2 = std::hash<uint32_t>{}(std::get<1>(k));
        auto h3 = std::hash<uint32_t>{}(std::get<2>(k));
        // simple hash-combine
        size_t h = h1;
        h ^= h2 + 0x9e3779b9 + (h << 6) + (h >> 2);
        h ^= h3 + 0x9e3779b9 + (h << 6) + (h >> 2);
        return h;
    }
};

inline std::vector<FlowDiff>
getFlowTableDiff(
    const std::unordered_map<uint64_t,
                             std::vector<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>>>&
        oldTable,
    const std::unordered_map<uint64_t,
                             std::vector<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>>>&
        newTable)
{
    std::vector<FlowDiff> diffs;

    auto buildMap = [](const auto& rules) {
        std::unordered_map<Key, uint32_t, KeyHash> m; // Key -> outPort
        for (const auto& r : rules)
        {
            uint32_t net = std::get<0>(r);
            uint32_t mask = std::get<1>(r);
            uint32_t out = std::get<2>(r);
            uint32_t pri = std::get<3>(r);
            m[{net, mask, pri}] = out; // last wins if duplicates
        }
        return m;
    };

    // dpids present in newTable
    for (const auto& [dpid, newRules] : newTable)
    {
        auto oldIt = oldTable.find(dpid);

        auto newMap = buildMap(newRules);
        std::unordered_map<Key, uint32_t, KeyHash> oldMap;
        if (oldIt != oldTable.end())
        {
            oldMap = buildMap(oldIt->second);
        }

        FlowDiff diff;
        diff.dpid = dpid;

        // added / modified
        for (const auto& [k, newOut] : newMap)
        {
            auto itOld = oldMap.find(k);
            if (itOld == oldMap.end())
            {
                diff.added.push_back({std::get<0>(k), std::get<1>(k), std::get<2>(k), 0, newOut});
            }
            else if (itOld->second != newOut)
            {
                diff.modified.push_back(
                    {std::get<0>(k), std::get<1>(k), std::get<2>(k), itOld->second, newOut});
            }
        }

        // removed
        for (const auto& [k, oldOut] : oldMap)
        {
            if (newMap.find(k) == newMap.end())
            {
                diff.removed.push_back({std::get<0>(k), std::get<1>(k), std::get<2>(k), oldOut, 0});
            }
        }

        if (!diff.added.empty() || !diff.removed.empty() || !diff.modified.empty())
        {
            diffs.push_back(std::move(diff));
        }
    }

    // dpids present only in oldTable
    for (const auto& [dpid, oldRules] : oldTable)
    {
        if (newTable.find(dpid) != newTable.end())
        {
            continue;
        }

        FlowDiff diff;
        diff.dpid = dpid;

        auto oldMap = buildMap(oldRules);
        for (const auto& [k, oldOut] : oldMap)
        {
            diff.removed.push_back({std::get<0>(k), std::get<1>(k), std::get<2>(k), oldOut, 0});
        }

        if (!diff.removed.empty())
        {
            diffs.push_back(std::move(diff));
        }
    }

    return diffs;
}

} // namespace sflow
