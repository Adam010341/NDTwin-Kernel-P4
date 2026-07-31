#pragma once

#include <cstdint>
#include <optional>
#include <vector>

#include <nlohmann/json.hpp>

namespace ndtClassifier
{
/**
 * @file Classifier.hpp
 * @brief Public API for an OVS-like OpenFlow classifier used in NDT.
 *
 * @details
 * This module targets systems that periodically poll OpenFlow flow tables from real switches
 * (e.g., Ryu '/stats/flow/<dpid>'), then compute forwarding decisions (next hop / output port)
 * for detected flows.
 *
 * Typically workflow:
 * 1. Poll all switches -> JSON result
 * 2. Call Classifier::updateFromQueriedTables(json)
 * 3. For each detected flow key, call Classifier::lookup(dpid, flowkey)
 *
 * @par Supported JSON shapes
 * - Shape A:
 * @code
 * [{"dpid": 1, "flows": [{flow}, {flow}]}]
 * @endcode
 * - Shape B:
 * @code
 * [{"dpid": 1, "flows": {"1": [ {flow}, {flow} ]}}]
 * @endcode
 *
 * @par Supported match field naming
 * Supports both OpenFlow 1.0-style and OpenFlow 1.3+-style field names:
 * - etherType: 'dl_type' OR 'eth_type'
 * - IPv4 dst: 'nw_dst' OR 'ipv4_dst'
 * - IPv4 src: 'nw_src' OR 'ipv4_src'
 * - IP proto: 'nw_proto' OR 'ip_proto'
 * - L4 ports: 'tp_src/tp_dst' OR 'tcp_src/tcp_dst' OR 'udp_src/udp_dst'
 *
 * @par IPv4 netmask formats
 * For IPv4 fields (nw_dst/nw_src/ipv4_dst/ipv4_src), supports:
 * - "192.168.1.1" (implicit /32)
 * - "192.168.1.0/24" (CIDR prefix)
 * - "192.168.1.0/255.255.255.0" (dotted netmask)
 * - "192.168.1.0/0xffffff00" (hex netmask)
 *
 * @par Identity model (cookie may be constant)
 * Some hardware exports the same cookie (e.g., '0x0') for all entries. To keep stable identity
 * across polls, the classifier uses:
 * - RuleId = (tableId, coreHash)
 * where coreHash fingerprints the rule core semantics (mask+value+priority+effect),
 * excluding counters (byte_count/packet_count/duration...).
 *
 */

/**
 * @brief Canonical flow/packet key used for matching against polled OpenFlow entries.
 *
 * @details
 * Fields are in host byte order. Internally the classifier packs this into a fixed byte order
 * layout and performs masked hashing + priority selection.
 *
 * Only set the fields you care about; others can remain 0.
 *
 * @warning ipv4Src/ipv4Dst are in host byte order.
 */
struct FlowKey
{
    /** @brief Ingress port on the current switch (OpenFlow in_port). */
    uint32_t inPort = 0;

    /** @brief Ethertype (e.g., 0x0800 for IPv4). */
    uint16_t ethType = 0;

    /** @brief IP protocol (e.g., 6 TCP 17 UDP) */
    uint8_t ipProto = 0;

    /** @brief IPv4 source address in host byte order. */
    uint32_t ipv4Src = 0;

    /** @brief IPv4 destination address in host byte order. */
    uint32_t ipv4Dst = 0;

    /** @brief Transport-layer source port (TCP/UDP). */
    uint16_t tpSrc = 0;

    /** @brief Transport-layer destination port (TCP/UDP). */
    uint16_t tpDst = 0;

    /** @brief VLAN tag control information (if used). */
    uint16_t vlanTci = 0;

    /** @brief OpenFlow metadata.
     * @details Useful if you match on metadata; otherwise keep 0.
     */
    uint64_t metadata = 0;

    bool operator==(const FlowKey& o) const = default;
};

/**
 * @brief Minimal forwarding effect extracted from a polled flow entry.
 *
 * @details
 * This is the info NDT usually needs for next-hop comuputations:
 * - OUTPUT ports
 * - optional GROUP id
 * optional goto-taable (if present)
 */
struct RuleEffect
{
    /** @brief Next table to evaluate (OpenFlow pipeline). */
    std::optional<uint8_t> gotoTable;

    /** @brief output ports parsed from actions such as "OUTPUT:1". */
    std::vector<uint32_t> outputPorts;

    /** @brief Group ID parsed from "GROUP:<id>" (group resolution is out of scope here). */
    std::optional<uint32_t> groupId;
};

/** @brief OpenFlow classifier supporting incremental updates from periodic polling.
 *
 * @details
 * - One writer thread calls updateFromQueriedTables()
 * - Many reader threads call lookup()
 *
 * Internally uses an OVS-like approach:
 * - rules grouped by identical masks into subtables
 * - hash lookup by (key & mask) within each subtable
 * - choose highest-priority match
 */
class Classifier
{
  public:
    using json = nlohmann::json;

    Classifier();

    ~Classifier();

    /** @brief Non-copyable. */
    Classifier(const Classifier&) = delete;

    /** @brief Movable. */
    Classifier(Classifier&&) noexcept;

    /** @brief Movable. */
    Classifier& operator=(Classifier&&) noexcept;

    /** @brief Update classifier from polled OpenFlow tables JSON.
     *
     * @param newTables Polled JSON array of switch objects.
     *
     * @details
     * Performs an incremental mark-and-sweep:
     * - rules seen in the new poll are kept/updated
     * - rules not present are removed
     */
    void updateFromQueriedTables(const json& newTables);

    /** @brief Lookup the best matching rule effect for a given packet/flow key.
     *
     * @param dpid Switch datapath ID.
     * @param key Packet/flow key.
     * @param tableId OpenFlow table ID (default 0).
     * @return Effect if matched; std::nullopt if no match exists.
     */
    std::optional<RuleEffect> lookup(uint64_t dpid, const FlowKey& key, uint8_t tableId = 0) const;

    /**
     * @brief Whether any flow table has been ingested for this switch.
     *
     * @details
     * Lets a caller tell "the control plane has not given us this switch's table" apart from
     * "the table is loaded and nothing matched" -- two very different faults that lookup()
     * reports identically as nullopt. Added because lookup() used to log the distinction
     * itself, at 1 kHz: 75,853 copies of "switch not found dpid 10" in two minutes with the
     * proxy down, an 8.5 MB log.
     *
     * [Co-developed with claude code -- Adam]
     */
    bool knowsSwitch(uint64_t dpid) const;

    /** @brief Get the number of stored rules for a given switch. */
    size_t getRuleCount(uint64_t dpid) const;

  private:
    /** @brief Hidden implementation (defined in Classifier.cpp). */
    struct Impl;

    /** @brief Owned implementation pointer. */
    Impl* impl_ = nullptr;
};

} // namespace ndtClassifier