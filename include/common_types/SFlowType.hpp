#pragma once

#include <arpa/inet.h>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <optional>
#include <map>
#include <nlohmann/json.hpp>
#include <queue>
#include <stdexcept>
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
 * @brief Parses one `[node, interface]` hop, or nothing if the JSON does not describe one.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Both ingests of `all_destination_paths` -- the background poll in FlowLinkUsageCollector and
 * the POST handler in HttpSession -- indexed `nodeJson[0]` and `nodeJson[1]` on a const json
 * with no size or type check. That is not the same defect as an unchecked object key, and it is
 * worse: nlohmann's two const `operator[]` overloads differ. The object overload does a `find`
 * and a `JSON_ASSERT`, so a missing key aborts loudly in a Debug build. The array overload
 * forwards straight to `std::vector::operator[]` with no bounds check at all --
 *
 *     if (JSON_HEDLEY_LIKELY(is_array())) { return m_data.m_value.array->operator[](idx); }
 *
 * -- so a hop array shorter than two elements is a heap read past the end in *every* build type,
 * Debug included, and the enclosing `catch (const std::exception&)` cannot see it. ASan reports
 * it as a heap-buffer-overflow. The HTTP handler's copy takes its input from the sibling apps
 * over the network.
 *
 * The value parses are non-throwing for the same reason the surrounding ingest guards are: an
 * unparseable address or port used to throw out of the loop and cost the whole reply, so one bad
 * hop discarded every path after it.
 *
 * Shared rather than duplicated because the two call sites were already near-identical copies,
 * and a guard that exists in one copy is the shape this codebase keeps rediscovering.
 *
 * @param nodeJson One element of a path array, expected to be `[node, interface]`.
 * @return The (node id, interface) pair, or nullopt if the element is not a well-formed hop.
 */
inline std::optional<std::pair<uint64_t, uint32_t>>
tryParsePathNode(const nlohmann::json& nodeJson)
{
    if (!nodeJson.is_array() || nodeJson.size() < 2)
    {
        return std::nullopt;
    }

    const auto& nodeField = nodeJson[0];
    const auto& portField = nodeJson[1];

    uint64_t nodeId = 0;
    if (nodeField.is_string())
    {
        // Host hops carry a dotted address; switch hops carry a numeric dpid.
        const std::string text = nodeField.get<std::string>();
        struct in_addr addr;
        if (inet_pton(AF_INET, text.c_str(), &addr) != 1)
        {
            return std::nullopt;
        }
        nodeId = addr.s_addr;
    }
    else if (nodeField.is_number_unsigned() || nodeField.is_number_integer())
    {
        const auto raw = nodeField.get<int64_t>();
        if (raw < 0)
        {
            return std::nullopt;
        }
        nodeId = static_cast<uint64_t>(raw);
    }
    else
    {
        return std::nullopt;
    }

    uint32_t port = 0;
    if (portField.is_number_unsigned() || portField.is_number_integer())
    {
        const auto raw = portField.get<int64_t>();
        if (raw < 0 || raw > static_cast<int64_t>(UINT32_MAX))
        {
            return std::nullopt;
        }
        port = static_cast<uint32_t>(raw);
    }
    else if (portField.is_string())
    {
        // from_chars, not stoi: stoi throws std::invalid_argument on "abc", which is how a
        // single malformed port used to cost every path behind it, and reached the HTTP caller
        // as a 500 rather than a 400.
        const std::string text = portField.get<std::string>();
        uint32_t parsed = 0;
        const char* begin = text.data();
        const char* end = text.data() + text.size();
        const auto [stop, ec] = std::from_chars(begin, end, parsed);
        if (ec != std::errc() || stop != end)
        {
            return std::nullopt;
        }
        port = parsed;
    }
    else
    {
        return std::nullopt;
    }

    return std::make_pair(nodeId, port);
}

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
 * @brief Thrown when the sFlow parser would read past the end of a datagram.
 *
 * Carries the offending word index and the datagram's size so the log line says which
 * offset a malformed packet reached for.
 *
 * [Co-developed with claude code -- Adam]
 */
class TruncatedDatagram : public std::exception
{
  public:
    TruncatedDatagram(size_t requestedWord, size_t availableWords) noexcept
        : m_requestedWord(requestedWord),
          m_availableWords(availableWords)
    {
    }

    /**
     * Built on demand rather than in the constructor.
     *
     * This is thrown from an unauthenticated UDP path, so a flood of malformed packets
     * throws at line rate. Formatting the message eagerly meant two string allocations per
     * bad packet whether or not anything read it; the caller logs at most one in a thousand.
     * Deriving from std::exception rather than std::runtime_error is what makes that
     * possible, since runtime_error requires the string up front.
     */
    const char* what() const noexcept override
    {
        if (m_message.empty())
        {
            try
            {
                m_message = "sFlow datagram truncated: word " +
                            std::to_string(m_requestedWord) + " requested, only " +
                            std::to_string(m_availableWords) + " available";
            }
            catch (...)
            {
                return "sFlow datagram truncated";
            }
        }
        return m_message.c_str();
    }

    size_t requestedWord() const noexcept { return m_requestedWord; }
    size_t availableWords() const noexcept { return m_availableWords; }

  private:
    size_t m_requestedWord;
    size_t m_availableWords;
    mutable std::string m_message;
};

/**
 * @brief A bounds-checked view over a datagram as 32-bit words.
 *
 * Deliberately exposes the same `operator[]` as the raw `const uint32_t*` it replaces, so
 * an existing fixed-offset parser can be made safe without rewriting its accesses. Returns
 * the raw word (no byte-order conversion) exactly as the pointer did, leaving callers'
 * ntohl() calls unchanged.
 *
 * [Co-developed with claude code -- Adam]
 */
class BoundedWords
{
  public:
    BoundedWords(const uint32_t* words, size_t count)
        : m_words(words),
          m_count(count)
    {
    }

    /// @throws TruncatedDatagram when @p i is past the end of the datagram.
    uint32_t operator[](size_t i) const
    {
        if (i >= m_count)
        {
            throw TruncatedDatagram(i, m_count);
        }
        return m_words[i];
    }

    /// Number of whole 32-bit words available.
    size_t size() const noexcept { return m_count; }

    /// True when @p i can be read without throwing. For probing before a wide read.
    bool has(size_t i) const noexcept { return i < m_count; }

  private:
    const uint32_t* m_words;
    size_t m_count;
};

/**
 * @brief Bytes or packets seen since the previous reading, saturating at zero.
 *
 * @param current  This interval's counter reading.
 * @param previous Last interval's reading of the same counter.
 * @return current - previous, or 0 if the counter went backwards.
 *
 * @details These counters are meant to be monotonic, so the rate loop subtracted them directly.
 * They are `uint64_t`, so any reading that goes backwards does not produce a small negative number
 * -- it wraps to about **1.8e19**. That is then multiplied by 8 and by the sampling rate and
 * reported as a flow's bit rate, and it sails past `MICE_FLOW_UNDER_THRESHOLD` (10 Mbps) into the
 * elephant-flow classification.
 *
 * A counter going backwards is not hypothetical. It happened whenever two sFlow worker threads
 * raced on a newly created flow: the loser's branch *assigned* the byte count instead of
 * accumulating, discarding what the winner had already added. That specific race is fixed, but the
 * subtraction should not be one lost update away from reporting 18 exabits per second either way --
 * purging and re-creating a flow between two intervals reaches the same place.
 *
 * Saturating at zero rather than clamping to the previous value: the honest reading of "the counter
 * I am differencing was reset" is "I do not know what happened during this interval", and zero is
 * the only answer that cannot invent traffic. It under-reports one interval; the alternative
 * over-reports by twelve orders of magnitude.
 *
 * [Co-developed with claude code -- Adam]
 */
inline uint64_t
counterDelta(uint64_t current, uint64_t previous)
{
    return (current >= previous) ? (current - previous) : 0;
}

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
