#include "ndt_core/collection/Classifier.hpp"
#include "utils/Utils.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <spdlog/fmt/bin_to_hex.h>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <arpa/inet.h>

namespace ndtClassifier
{
/** @file Classifier.cpp
 * @brief Implementation of the OVS-like OpenFlow classifier.
 *
 * @details
 * This file contains all internal data structures and logic:
 * - canonical fixed-width key packing
 * - mask interning (deduplication)
 * - synthetic RuleId computation (tableId + coreHash)
 * - OVS-like subtable hashing (mask-grouped subtables)
 * - incremental update (mark-and-sweep pre poll epoch)
 * - lookup (fast hashed match + highest priority selection)
 */

// ======================================================================
// Internal: byte key + helpers
// ======================================================================
/** @brief Fized size of the packed match key.
 *
 * @details
 * The classifier converts a FlowKey (structured fields) into a canonical byte array.
 * This allows:
 * - consistent masking (bitwise AND)
 * - stable hashing
 * - simple equality checks checks for bucket lookup
 *
 * Layout (32 bytes):
 * - inPort     : 4 bytes (BE)
 * - ethType    : 2 bytes (BE)
 * - ipProto    : 1 byte
 * - pad        : 1 byte
 * - ipv4Src    : 4 bytes (BE)
 * - ipv4Dst    : 4 bytes (BE)
 * - tpSrc      : 2 bytes (BE)
 * - tpDst      : 2 bytes (BE)
 * - vlanTci    : 2 bytes (BE)
 * - pad        : 2 bytes
 * - metadata   : 8 bytes (BE)
 */
static constexpr size_t kKeyBytes = 32;

/** @brief Canonical packed key representation used for hashing and masking.
 *
 * @details
 * We use this instead of hashing FlowKey directly because:
 * - different architecture/padding won't affect representation
 * - masking can be implementated as a byte-wise AND
 * - hashing becomes stable and fast
 */
struct KeyBytes
{
    std::array<uint8_t, kKeyBytes> bytes{};

    bool operator==(const KeyBytes& other) const noexcept
    {
        return bytes == other.bytes;
    }
};

/** @brief Hash functor for  KeyBytes.
 *
 * @details
 * Uses 64-bit FNV-1a over the key bytes. This is good enough for hashtables here.
 */
struct KeyBytesHash
{
    size_t operator()(const KeyBytes& k) const noexcept
    {
        uint64_t h = 1469598103934665603ULL;
        for (uint8_t c : k.bytes)
        {
            h ^= c;
            h *= 1099511628211ULL;
        }
        return static_cast<size_t>(h);
    }
};

/** @brief Bitwise AND between a key and a mask (byte-wise).
 *
 * @param a Key bytes
 * @param m Mask bytes
 * @return Maked key bytes
 *
 * @details
 * This models how OpenFlow match masking works: only bits enabled in the mask matter.
 */
static inline KeyBytes
bitAnd(const KeyBytes& a, const KeyBytes& m) noexcept
{
    KeyBytes out;
    for (size_t i = 0; i < kKeyBytes; ++i)
    {
        out.bytes[i] = static_cast<uint8_t>(a.bytes[i] & m.bytes[i]);
    }
    return out;
}

static inline void
writeU32Be(std::array<uint8_t, kKeyBytes>& out, size_t off, uint32_t v) noexcept
{
    uint32_t be = htonl(v);
    std::memcpy(out.data() + off, &be, sizeof(be));
}

static inline void
writeU16Be(std::array<uint8_t, kKeyBytes>& out, size_t off, uint16_t v) noexcept
{
    uint16_t be = htons(v);
    std::memcpy(out.data() + off, &be, sizeof(be));
}

static inline void
writeU64Be(std::array<uint8_t, kKeyBytes>& out, size_t off, uint64_t v) noexcept
{
    out[off + 0] = static_cast<uint8_t>((v >> 56) & 0xFF);
    out[off + 1] = static_cast<uint8_t>((v >> 48) & 0xFF);
    out[off + 2] = static_cast<uint8_t>((v >> 40) & 0xFF);
    out[off + 3] = static_cast<uint8_t>((v >> 32) & 0xFF);
    out[off + 4] = static_cast<uint8_t>((v >> 24) & 0xFF);
    out[off + 5] = static_cast<uint8_t>((v >> 16) & 0xFF);
    out[off + 6] = static_cast<uint8_t>((v >> 8) & 0xFF);
    out[off + 7] = static_cast<uint8_t>((v >> 0) & 0xFF);
}

/** @brief Pack FlowKey into canonical KeyBytes (network byte order).
 *
 * @details
 * We store the packed bytes in a stable BE layout so masks derived from IPv4 prefixes
 * (e.g., /24) work naturally.
 */
static inline KeyBytes
packKey(const FlowKey& k) noexcept
{
    KeyBytes out;
    writeU32Be(out.bytes, 0, k.inPort);
    writeU16Be(out.bytes, 4, k.ethType);
    out.bytes[6] = k.ipProto;
    out.bytes[7] = 0;

    writeU32Be(out.bytes, 8, k.ipv4Src);
    writeU32Be(out.bytes, 12, k.ipv4Dst);

    writeU16Be(out.bytes, 16, k.tpSrc);
    writeU16Be(out.bytes, 18, k.tpDst);

    writeU16Be(out.bytes, 20, k.vlanTci);
    out.bytes[22] = 0;
    out.bytes[23] = 0;

    writeU64Be(out.bytes, 24, k.metadata);
    return out;
}

// ======================================================================
// Internal: mask interning
// ======================================================================

/** @brief Fixed mask representation aligned with KeyBytes.
 *
 * @details
 * A mask indicates which bits of the key participate in matching.
 * Rules that match the same set of fields will share identical masks
 * (e.g., {dl_type + nw_dst/24}).
 */
struct Mask
{
    KeyBytes bytes{};
};

/** @brief Mask interning pool to deduplicate identical masks.
 *
 * @details
 * In OVS, subtables are grouped by identical masks. Interning provides:
 * - less memory (one mask instance shared by many rules)
 * - faster comparisons (pointer equality instead of memcmp)
 */
class MaskIntern
{
  public:
    /** @brief Intern (deduplicate) mask bytes and return a stable pointer.*/
    const Mask* interMask(const KeyBytes& maskBytes)
    {
        auto it = pool_.find(maskBytes);
        if (it != pool_.end())
        {
            return it->second.get();
        }

        auto m = std::make_unique<Mask>();
        m->bytes = maskBytes;
        const Mask* ret = m.get();
        pool_.emplace(maskBytes, std::move(m));
        return ret;
    }

  private:
    std::unordered_map<KeyBytes, std::unique_ptr<Mask>, KeyBytesHash> pool_;
};

// ======================================================================
// Internal: RuleId (coreHash)
// ======================================================================

/** @brief Synthetic rule identity used for incremental updates.
 *
 * @details
 * Many hardware switches export cookie=0 for all rules, so cookie cannot be used as identity.
 * We compute:
 * - RuleId = (tableId, coreHash)
 *
 * coreHash fingerprints the *core semantics*:
 * - mask + maskedValue + priority + effect (OUTPUT/GROUP/goto)
 *
 * Excludes counters (byte_count, packet_count, durations) so it remains stable across polls.
 */
struct RuleId
{
    uint8_t tableId = 0;
    uint64_t coreHash = 0;

    bool operator==(const RuleId& other) const noexcept
    {
        return tableId == other.tableId && coreHash == other.coreHash;
    }
};

/** @brief Hash functor for RuleId, suitable for unordered_map. */
struct RuleIdHash
{
    size_t operator()(const RuleId& id) const noexcept
    {
        uint64_t x = id.coreHash ^ (static_cast<uint64_t>(id.tableId) << 56);
        x ^= x >> 33;
        x *= 0xff51afd7ed558ccdULL;
        x ^= x >> 33;
        x *= 0xc4ceb9fe1a85ec53ULL;
        x ^= x >> 33;
        return static_cast<size_t>(x);
    }
};

static inline uint64_t
fnv1a64(const uint8_t* data, size_t n) noexcept
{
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; ++i)
    {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/** @brief Fingerprint rule core semantics for stable identity (coreHash). */
static inline uint64_t
fingerprintRuleCore(const KeyBytes& maskBytes,
                    const KeyBytes& maskedValue,
                    int priority,
                    const RuleEffect& effect) noexcept
{
    uint64_t h = 1469598103934665603ULL;

    h ^= fnv1a64(maskBytes.bytes.data(), maskBytes.bytes.size());
    h *= 1099511628211ULL;
    h ^= fnv1a64(maskedValue.bytes.data(), maskedValue.bytes.size());
    h *= 1099511628211ULL;

    uint32_t p = static_cast<uint32_t>(priority);
    h ^= fnv1a64(reinterpret_cast<const uint8_t*>(&p), sizeof(p));
    h *= 1099511628211ULL;

    if (effect.gotoTable)
    {
        uint8_t t = *effect.gotoTable;
        h ^= t;
        h *= 1099511628211ULL;
    }
    for (uint32_t op : effect.outputPorts)
    {
        h ^= fnv1a64(reinterpret_cast<const uint8_t*>(&op), sizeof(op));
        h *= 1099511628211ULL;
    }
    if (effect.groupId)
    {
        uint32_t g = *effect.groupId;
        h ^= fnv1a64(reinterpret_cast<const uint8_t*>(&g), sizeof(g));
        h *= 1099511628211ULL;
    }
    return h;
}

// ======================================================================
// Internal: classifier data structures (OVS-like)
// ======================================================================

struct Subtable; // forward

/** @brief Internal rule repersentation stored in the classifier.
 *
 * @details
 * Stores:
 * - identity: RuleId(tableId, coreHash)
 * - match: mask + maskedValue
 * - effect: RuleEffect (OUTPUT/GROUP/goto)
 *
 * Also stores placement pointers for fast removal:
 * - subtable pointer
 * - bucketKey
 */
struct Rule
{
    RuleId id{};
    uint8_t tableId = 0;
    int priority = 0;

    const Mask* mask = nullptr;
    KeyBytes maskedValue{};
    RuleEffect effect{};

    uint64_t lastSeenEpoch = 0;

    // placement for fast deletion
    Subtable* subtable = nullptr;
    KeyBytes bucketKey{};
};

/** @brief Bucket of rules that share the same (key & mask) value inside a Subtable.
 *
 * @details
 * Each bucket corresponds to a specific masked vkey (e.g., nw_dst/24 = 192.168.1.0/24).
 * Rules in a bucket are kept sorted by priority decending so "best match" is vec.front().
 */
struct Bucket
{
    std::vector<Rule*> rules;
};

/** @brief Subtables groups all rules with the same mask.
 *
 * @details
 * In OVS, rules are grouped by identical masks so lookup can:
 * - apply that mask once
 * - hash the masked key
 * - only scan candidate rules in the matched bucket
 *
 * maxPriority enables pruning: if maxPriority is below current best, skip subtable.
 */
struct Subtable
{
    const Mask* mask = nullptr;
    int maxPriority = -1;
    std::unordered_map<KeyBytes, Bucket, KeyBytesHash> buckets;

    void recomputeMaxPriority()
    {
        int mp = -1;
        for (auto& [k, b] : buckets)
        {
            if (!b.rules.empty())
            {
                mp = std::max(b.rules.front()->priority, mp);
            }
        }
        maxPriority = mp;
    }
};

/** @brief Per-table classifier state (OpenFlow table_id).
 *
 * @details
 * A table contains multiple subtables (one per unique mask).
 * 'subtablesByPriority' is cached ordering to speed lookup.
 */
struct TableClassifier
{
    std::unordered_map<const Mask*, std::unique_ptr<Subtable>> byMask;
    std::vector<Subtable*> subtablesByPriority;
    bool priorityOrderDirty = true;

    /** @brief Get existing subtable or create a new one for a mask. */
    Subtable* getOrCreateSubtable(const Mask* mask)
    {
        auto it = byMask.find(mask);
        if (it != byMask.end())
        {
            return it->second.get();
        }

        auto st = std::make_unique<Subtable>();
        st->mask = mask;
        Subtable* ret = st.get();
        byMask.emplace(mask, std::move(st));
        priorityOrderDirty = true;
        return ret;
    }

    /** @brief Rebuild subtable ordering by maxPriority if changes occured. */
    void rebuildPriorityOrderIfNeeded()
    {
        if (!priorityOrderDirty)
        {
            return;
        }

        subtablesByPriority.clear();
        subtablesByPriority.reserve(byMask.size());
        for (auto& [m, st] : byMask)
        {
            subtablesByPriority.push_back(st.get());
        }

        std::sort(
            subtablesByPriority.begin(),
            subtablesByPriority.end(),
            [](const Subtable* a, const Subtable* b) { return a->maxPriority > b->maxPriority; });

        priorityOrderDirty = false;
    }
};

/** @brief Per-switch classifier state.
 *
 * @details
 * - stores multiple OpenFlow tables
 * - owns all rules in rulesById
 * epoch increments per polling update; used for mark-and-sweep deletion
 */
struct SwitchClassifier
{
    std::unordered_map<uint8_t, TableClassifier> tables;
    std::unordered_map<RuleId, std::unique_ptr<Rule>, RuleIdHash> rulesById;
    uint64_t epoch = 0;

    TableClassifier& getTable(uint8_t tableId)
    {
        return tables[tableId];
    }
};

// ======================================================================
// Internal: JSON + match parsing (supports masks for IPv4)
// ======================================================================

/** @brief Parse an integer-like JSON node (number or string, decimal or hex). */
static uint64_t
parseU64(const nlohmann::json& j)
{
    if (j.is_number_unsigned())
    {
        return j.get<uint64_t>();
    }
    if (j.is_number_integer())
    {
        return static_cast<uint64_t>(j.get<uint64_t>());
    }
    if (j.is_string())
    {
        std::string s = j.get<std::string>();
        while (!s.empty() && std::isspace((unsigned char)s.front()))
        {
            s.erase(s.begin());
        }
        while (!s.empty() && std::isspace((unsigned char)s.back()))
        {
            s.pop_back();
        }
        int base = 10;
        if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        {
            base = 16;
        }
        return std::stoull(s, nullptr, base);
    }
    throw std::runtime_error("parseU64: unsupported json type");
}

static int
parseI32(const nlohmann::json& j)
{
    if (j.is_number_integer())
    {
        return j.get<int>();
    }
    if (j.is_number_unsigned())
    {
        return static_cast<int>(j.get<unsigned>());
    }
    if (j.is_string())
    {
        return std::stoi(j.get<std::string>());
    }
    throw std::runtime_error("parseI32: unsupported json type");
}

/** @brief Extract the flow entry array from either supported JSON shape. */
static const nlohmann::json*
extractFlowArray(const nlohmann::json& flowsNode, uint64_t dpid)
{
    if (flowsNode.is_array()) // "flows": [ { ... }, { ... } ]
    {
        return &flowsNode;
    }

    if (flowsNode.is_object()) // "flows": {"106225808402492": [ { ... }, { ... } ]}
    {
        std::string key = std::to_string(dpid);
        auto it = flowsNode.find(key);
        if (it != flowsNode.end())
        {
            return &(*it);
        }

        if (flowsNode.size() == 1)
        {
            return &flowsNode.begin().value();
        }
    }
    return nullptr;
}

static bool
isAllDigits(const std::string& s)
{
    if (s.empty())
    {
        return false;
    }
    for (char c : s)
    {
        if (!std::isdigit((unsigned char)c))
        {
            return false;
        }
    }
    return true;
}

static std::optional<uint32_t>
parseIpv4AddrHost(const std::string& ip)
{
    in_addr a{};
    if (inet_pton(AF_INET, ip.c_str(), &a) != 1)
    {
        return std::nullopt;
    }
    return ntohl(a.s_addr);
}

/** @brief Parse IPv4 with optional prefix or netmask.
 *
 * @return (addrHost, maskHost) or nullpot on failure.
 */
static std::optional<std::pair<uint32_t, uint32_t>>
parseIpv4WithMaskOrPrefix(const nlohmann::json& j)
{
    if (!j.is_string())
    {
        return std::nullopt;
    }

    std::string s = j.get<std::string>();
    auto slash = s.find('/');

    std::string ipStr = (slash == std::string::npos) ? s : s.substr(0, slash);
    std::string maskStr = (slash == std::string::npos) ? "" : s.substr(slash + 1);

    auto addrOpt = parseIpv4AddrHost(ipStr);
    if (!addrOpt)
    {
        return std::nullopt;
    }
    uint32_t addrHost = *addrOpt;

    if (maskStr.empty())
    {
        return std::make_pair(addrHost, 0xFFFFFFFFu); // /32
    }

    if (isAllDigits(maskStr))
    {
        int prefix = std::stoi(maskStr);
        if (prefix < 0 || prefix > 32)
        {
            return std::nullopt;
        }
        uint32_t maskHost = (prefix == 0)    ? 0u
                            : (prefix == 32) ? 0xFFFFFFFFu
                                             : (0xFFFFFFFF << (32 - prefix));
        return std::make_pair(addrHost, maskHost);
    }

    if (maskStr.size() > 2 && maskStr[0] == '0' && (maskStr[1] == 'x' || maskStr[1] == 'X'))
    {
        try
        {
            unsigned long v = std::stoul(maskStr, nullptr, 16);
            return std::make_pair(addrHost, static_cast<uint32_t>(v));
        }
        catch (...)
        {
            return std::nullopt;
        }
    }

    auto maskOpt = parseIpv4AddrHost(maskStr);
    if (!maskOpt)
    {
        return std::nullopt;
    }
    return std::make_pair(addrHost, *maskOpt);
}

static inline void
setU32MaskAll(KeyBytes& mb, size_t off)
{
    mb.bytes[off + 0] |= 0xFF;
    mb.bytes[off + 1] |= 0xFF;
    mb.bytes[off + 2] |= 0xFF;
    mb.bytes[off + 3] |= 0xFF;
}

static inline void
setU16MaskAll(KeyBytes& mb, size_t off)
{
    mb.bytes[off + 0] |= 0xFF;
    mb.bytes[off + 1] |= 0xFF;
}

/** @brief Build packed mask bytes and FlowKey value from a rule's "match" object.
 *
 * @details
 * - Converts supported match fields into FlowKey fields
 * - Computes cooresponding mask bytes (including IPv4 prefix masks)
 * - Leaves unsupported fields ignored (mask bits remain 0)
 */
static void
buildMaskAndValueFromMatch(const nlohmann::json& match, KeyBytes& outMaskBytes, FlowKey& outValue)
{
    outMaskBytes = KeyBytes{};
    outValue = FlowKey{};

    if (match.contains("in_port"))
    {
        outValue.inPort = static_cast<uint32_t>(parseU64(match.at("in_port")));
        setU32MaskAll(outMaskBytes, 0);
    }

    if (match.contains("eth_type"))
    {
        outValue.ethType = static_cast<uint16_t>(parseU64(match.at("eth_type")));
        setU16MaskAll(outMaskBytes, 4);
    }
    else if (match.contains("dl_type"))
    {
        outValue.ethType = static_cast<uint16_t>(parseU64(match.at("dl_type")));
        setU16MaskAll(outMaskBytes, 4);
    }

    if (match.contains("ip_proto"))
    {
        outValue.ipProto = static_cast<uint8_t>(parseU64(match.at("ip_proto")));
        outMaskBytes.bytes[6] |= 0xFF;
    }
    else if (match.contains("nw_proto"))
    {
        outValue.ipProto = static_cast<uint8_t>(parseU64(match.at("nw_proto")));
        outMaskBytes.bytes[6] |= 0xFF;
    }

    auto applyIpv4Masked = [&](bool isSrc, const nlohmann::json& j) {
        auto p = parseIpv4WithMaskOrPrefix(j);
        if (!p)
        {
            return;
        }

        if (isSrc)
        {
            outValue.ipv4Src = p->first;
        }
        else
        {
            outValue.ipv4Dst = p->first;
        }

        uint32_t maskBe = htonl(p->second);
        std::array<uint8_t, 4> mb{};
        std::memcpy(mb.data(), &maskBe, 4);

        size_t off = isSrc ? 8 : 12;
        for (int i = 0; i < 4; ++i)
        {
            outMaskBytes.bytes[off + i] |= mb[i];
        }
    };

    if (match.contains("ipv4_src"))
    {
        applyIpv4Masked(true, match.at("ipv4_src"));
    }
    else if (match.contains("nw_src"))
    {
        applyIpv4Masked(true, match.at("nw_src"));
    }

    if (match.contains("ipv4_dst"))
    {
        applyIpv4Masked(false, match.at("ipv4_dst"));
    }
    else if (match.contains("nw_dst"))
    {
        applyIpv4Masked(false, match.at("nw_dst"));
    }

    auto setTpSrc = [&](const nlohmann::json& v) {
        outValue.tpSrc = static_cast<uint16_t>(parseU64(v));
        setU16MaskAll(outMaskBytes, 16);
    };
    auto setTpDst = [&](const nlohmann::json& v) {
        outValue.tpDst = static_cast<uint16_t>(parseU64(v));
        setU16MaskAll(outMaskBytes, 18);
    };

    if (match.contains("tcp_src"))
    {
        setTpSrc(match.at("tcp_src"));
    }
    if (match.contains("tcp_dst"))
    {
        setTpDst(match.at("tcp_dst"));
    }
    if (match.contains("udp_src"))
    {
        setTpSrc(match.at("udp_src"));
    }
    if (match.contains("udp_dst"))
    {
        setTpDst(match.at("udp_dst"));
    }
    if (match.contains("tp_src"))
    {
        setTpSrc(match.at("tp_src"));
    }
    if (match.contains("tp_dst"))
    {
        setTpDst(match.at("tp_dst"));
    }

    if (match.contains("vlan_vid"))
    {
        // [Co-developed with claude code -- Adam]
        // Was `match.at("vlan_id")` -- guarded on one key, read from another. "vlan_id" appears
        // nowhere else in this repo, so guard and read now agree and the landmine is defused.
        //
        // ⚠️ The first version of this comment said "vlan_vid is what Ryu's OFPMatch calls the
        // field". That is the *request* spelling. On the response side -- which is what this
        // parser eats -- ofctl_v1_3.py:296 renames it: `'vlan_vid': 'dl_vlan'`. So Ryu sends
        // `dl_vlan`, the P4 proxy emits no VLAN key at all, and `dl_vlan` is read nowhere in this
        // kernel (`git grep dl_vlan -- src/ include/` is empty). This branch is therefore still
        // unreachable, and **Ryu's VLAN matches are silently dropped from the classifier key** --
        // two flows differing only by VLAN collide. That is a separate defect from the one fixed
        // here, recorded rather than fixed because it needs a decision about whether VLAN belongs
        // in the key at all. Corrected after an independent review checked the claim against
        // Ryu's source rather than against the field name. A flow
        // carrying vlan_vid without vlan_id therefore made .at() throw json::out_of_range, which
        // openflowTablesUpdateWorker catches and logs, so it would not crash -- it would repeat.
        // The same rule is in every poll, so the poisoned switch's mark-and-sweep would never
        // run again, the switches after it in the loop would never update, and the cached
        // openflow table would never refresh, all reported as one repeated worker error.
        // Latent only because nothing currently emits vlan_vid, which is what would have made it
        // arrive as a mystery.
        //
        // ⚠️ **Do not fix only this side.** Whoever makes Ryu's VLAN reach this branch (by
        // reading `dl_vlan` here) must fix the sFlow side in the same change. `vlanTci` is
        // serialised into the key by packKey above, and the two producers of a FlowKey are
        // not symmetric: rules come from here, but *lookups* come from the sFlow path walk,
        // which builds its FlowKey in FlowLinkUsageCollector::calFlowPathByQueried (grep
        // `ndtClassifier::FlowKey fk{}` -- the only hit in the file) and sets no VLAN at all.
        //
        // Located by name, not by line: the first version of that sentence cited
        // "FlowLinkUsageCollector.cpp:2534" and was already wrong the same hour, because the
        // companion comment added to that very function pushed the line to 2542.
        //
        // Today both sides are 0, so they agree and every lookup matches. Populate one side alone and
        // every VLAN-tagged rule becomes unfindable: the walk would hit the "table has no
        // matching rule" branch for traffic whose rule is sitting right there. Half a fix here
        // is worse than none. Either do both sides, or mark vlanTci reserved.
        // Recorded, not fixed, on Adam's instruction (2026-08-12).
        outValue.vlanTci = static_cast<uint16_t>(parseU64(match.at("vlan_vid")));
        setU16MaskAll(outMaskBytes, 20);
    }

    if (match.contains("metadata"))
    {
        outValue.metadata = parseU64(match.at("metadata"));
        for (int i = 0; i < 8; ++i)
        {
            outMaskBytes.bytes[24 + i] = 0xFF;
        }
    }
}

static inline std::string
toUpper(std::string s)
{
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return s;
}

static bool
parseUint(const std::string& s, uint32_t& out)
{
    if (s.empty())
    {
        return false;
    }
    char* end = nullptr;
    errno = 0;
    unsigned long v = std::strtoul(s.c_str(), &end, 10);
    if (errno != 0 || end == s.c_str() || *end != '\0')
    {
        return false;
    }
    if (v > 0xFFFFFFFFul)
    {
        return false;
    }
    out = static_cast<uint32_t>(v);
    return true;
}

/** @brief The first output port as text, or "none" when a rule has no output action.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Exists because outputPorts is legitimately empty for a rule that drops: Ryu reports a
 * table-miss drop as `"actions": []`, and parseActionsArrayIntoEffect also skips OUTPUT
 * targets it cannot parse. Calling front() on that is a null dereference.
 *
 * The trap is that the call sites are all SPDLOG_LOGGER_TRACE. spdlog's macros pass their
 * arguments as ordinary function arguments and filter by level *inside* log(), so the
 * arguments are evaluated even when the level is disabled -- a "switched off" trace line
 * still crashes the process.
 */
static std::string
describeFirstOutputPort(const RuleEffect& effect)
{
    return effect.outputPorts.empty() ? std::string("none")
                                      : std::to_string(effect.outputPorts.front());
}

/** @brief Parse an actions array into RuleEffect.
 *
 * @details
 * Supports string actions like "OUTPUT:1" and "GROUP:10".
 */
static void
parseActionsArrayIntoEffect(const nlohmann::json& actions, RuleEffect& effect)
{
    if (!actions.is_array())
    {
        return;
    }

    for (const auto& a : actions)
    {
        if (a.is_string())
        {
            std::string s = a.get<std::string>();
            auto colon = s.find(':');
            std::string kind = (colon == std::string::npos) ? s : s.substr(0, colon);
            std::string rest = (colon == std::string::npos) ? "" : s.substr(colon + 1);

            kind = toUpper(kind);

            if (kind == "OUTPUT" && !rest.empty())
            {
                // rest might be:
                // "1"
                // "CONTROLLER"
                // "CONTROLLER:65535"
                // "LOCAL" / "FLOOD" / "NORMAL" ...

                auto colon2 = rest.find(':');
                std::string portStr = (colon2 == std::string::npos) ? rest : rest.substr(0, colon2);
                portStr = toUpper(portStr);

                // OpenFlow 1.3 reserved ports (OpenFlow Switch Specification 1.3.0, table of
                // reserved OFPP_* values). This project speaks 1.3 -- intelligent_router.py uses
                // ofproto_v1_3, and the flow dumps come back from `ovs-ofctl -O OpenFlow13`.
                //
                // [Co-developed with claude code -- Adam]
                // All four of these used to be 65535. Two things were wrong with that. Port numbers
                // are 32-bit in 1.3, so 65535 is not any reserved port -- it was the 1.0
                // sixteen-bit OFPP_NONE, and 1.3's catch-all is 0xffffffff. And collapsing four
                // distinct targets onto one value made them indistinguishable: the effect hash at
                // the top of this file mixes the port in to detect when a rule has changed, so a
                // rule edited from FLOOD to CONTROLLER hashed identically and the change was
                // invisible. Neither consumer treats 65535 as a sentinel -- the other one looks the
                // port up as an edge, which a reserved port never matches either way -- so the
                // values could simply be corrected.
                //
                // Not handled, deliberately: ALL (0xfffffffc), IN_PORT (0xfffffff8) and TABLE
                // (0xfffffff9). Ryu can emit them; they fall through to parseUint below, fail, and
                // the action is skipped with the rest of the rule kept. Stated here because a
                // reader should not have to infer it from the absence of a branch.
                constexpr uint32_t OFPP_NORMAL = 0xfffffffa;
                constexpr uint32_t OFPP_FLOOD = 0xfffffffb;
                constexpr uint32_t OFPP_CONTROLLER = 0xfffffffd;
                constexpr uint32_t OFPP_LOCAL = 0xfffffffe;

                uint32_t port = 0;
                if (portStr == "CONTROLLER")
                {
                    port = OFPP_CONTROLLER;
                }
                else if (portStr == "LOCAL")
                {
                    port = OFPP_LOCAL;
                }
                else if (portStr == "FLOOD")
                {
                    port = OFPP_FLOOD;
                }
                else if (portStr == "NORMAL")
                {
                    port = OFPP_NORMAL;
                }
                else if (!parseUint(portStr, port))
                {
                    // unknown OUTPUT target -> skip
                    continue;
                }

                effect.outputPorts.push_back(port);
            }
            else if (kind == "GROUP" && !rest.empty())
            {
                uint32_t gid = 0;
                if (parseUint(rest, gid))
                {
                    effect.groupId = gid;
                }
            }
        }
    }
}

/** @brief Extract forwarding effect from a flow entry.
 *
 * @details
 * - OpenFlow 1.0: typically has "actions" directly.
 * - OF1.3+: may have "instructions". We support minimal goto-table parsing.
 */
static RuleEffect
parseEffectFromFlowEntry(const nlohmann::json& flow)
{
    RuleEffect effect;

    if (flow.contains("actions"))
    {
        parseActionsArrayIntoEffect(flow.at("actions"), effect);
    }

    if (flow.contains("instructions") && flow.at("instructions").is_array())
    {
        for (const auto& ins : flow.at("instructions"))
        {
            if (ins.contains("type") && ins.at("type").is_string())
            {
                std::string t = ins.at("type").get<std::string>();
                if (t == "GOTO_TABLE" && ins.contains("table_id"))
                {
                    effect.gotoTable = static_cast<uint8_t>(parseU64(ins.at("table_id")));
                }
            }

            if (ins.contains("actions"))
            {
                parseActionsArrayIntoEffect(ins.at("actions"), effect);
            }
        }
    }

    return effect;
}

// ======================================================================
// Impl: update + lookup algorithms
// ======================================================================

/** @brief Hidden implementation.
 *
 * @details
 * Holds:
 * - global lock (shared_mutex)
 * - per-switch classifier state
 * - mask interning pool
 *
 * Update path:
 * - updateFromQueriedTables() takes unique _lock and calls updateOneSwitch()
 * - updateOneSwitch() increments epoch, upserts rules, then sweeps unseen rules
 *
 * Lookup path:
 * - lookup() takes shared_mutex and runs lookupInTableNoLock()
 */
struct Classifier::Impl
{
    mutable std::shared_mutex mutex;
    MaskIntern maskIntern;
    std::unordered_map<uint64_t, SwitchClassifier> switches;

    /** @brief Parsed rule extracted from JSON before being inserted. */
    struct ParsedRule
    {
        RuleId id{};
        uint8_t tableId = 0;
        int priority = 0;
        const Mask* mask = nullptr;
        KeyBytes maskedValue{};
        RuleEffect effect{};
    };

    ParsedRule parseRuleFromJson(const nlohmann::json& flow)
    {
        ParsedRule pr;

        pr.tableId =
            flow.contains("table_id") ? static_cast<uint8_t>(parseU64(flow.at("table_id"))) : 0;

        pr.priority = flow.contains("priority") ? parseI32(flow.at("priority")) : 0;

        KeyBytes maskBytes{};
        FlowKey value{};
        if (flow.contains("match") && flow.at("match").is_object())
        {
            buildMaskAndValueFromMatch(flow.at("match"), maskBytes, value);
        }

        pr.mask = maskIntern.interMask(maskBytes);

        KeyBytes valueBytes = packKey(value);
        pr.maskedValue = bitAnd(valueBytes, pr.mask->bytes);

        pr.effect = parseEffectFromFlowEntry(flow);

        pr.id = RuleId{pr.tableId,
                       fingerprintRuleCore(pr.mask->bytes, pr.maskedValue, pr.priority, pr.effect)};
        return pr;
    }

    /** @brief Insert a new rule into the OVS-like structure (subtable + bucket). */
    void insertRuleIntoTables(SwitchClassifier& sw, Rule* r)
    {
        TableClassifier& tc = sw.getTable(r->tableId);
        Subtable* st = tc.getOrCreateSubtable(r->mask);

        KeyBytes bucketKey = r->maskedValue;
        Bucket& bucket = st->buckets[bucketKey];

        auto pos = std::lower_bound(
            bucket.rules.begin(),
            bucket.rules.end(),
            r,
            [](const Rule* a, const Rule* x) { return a->priority > x->priority; });

        bucket.rules.insert(pos, r);

        r->subtable = st;
        r->bucketKey = bucketKey;

        if (!bucket.rules.empty())
        {
            st->maxPriority = std::max(st->maxPriority, bucket.rules.front()->priority);
        }
        tc.priorityOrderDirty = true;
    }

    /** @brief Remove a rule quickly using its stored placement info. */
    void removeRuleFromTables(SwitchClassifier& sw, Rule* r)
    {
        if (!r->subtable)
        {
            return;
        }

        Subtable* st = r->subtable;
        auto it = st->buckets.find(r->bucketKey);
        if (it != st->buckets.end())
        {
            auto& vec = it->second.rules;
            auto vit = std::find(vec.begin(), vec.end(), r);
            if (vit != vec.end())
            {
                vec.erase(vit);
                if (vec.empty())
                {
                    st->buckets.erase(it);
                }
            }
        }

        st->recomputeMaxPriority();
        sw.tables[r->tableId].priorityOrderDirty = true;

        r->subtable = nullptr;
        r->bucketKey = KeyBytes{};
    }

    /** @brief Insert a rule if new, or mark it as seen if it already exists. */
    void upsertRule(SwitchClassifier& sw, const ParsedRule& pr)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(),
                            "tableId {} priority {} effect(output port) {} maskedValue {}",
                            std::to_string(pr.tableId),
                            std::to_string(pr.priority),
                            describeFirstOutputPort(pr.effect),
                            spdlog::to_hex(pr.maskedValue.bytes));

        auto it = sw.rulesById.find(pr.id);
        if (it == sw.rulesById.end())
        {
            auto r = std::make_unique<Rule>();
            r->id = pr.id;
            r->tableId = pr.tableId;
            r->priority = pr.priority;
            r->mask = pr.mask;
            r->maskedValue = pr.maskedValue;
            r->effect = pr.effect;
            r->lastSeenEpoch = sw.epoch;

            insertRuleIntoTables(sw, r.get());
            sw.rulesById.emplace(pr.id, std::move(r));
            return;
        }
        it->second->lastSeenEpoch = sw.epoch;
    }

    /** @brief Update a single switch based on the newly polled table.
     *
     * @details
     * Mark-and-sweep:
     * - epoch++
     * - upsert all polled rules (mark seen with lastSeenEpoch=epoch)
     * - delete any rule whose lastSennEpoch != epoch
     */
    void updateOneSwitch(uint64_t dpid, const nlohmann::json& flowArray)
    {
        SwitchClassifier& sw = switches[dpid];
        sw.epoch++;

        for (const auto& flow : flowArray)
        {
            ParsedRule pr = parseRuleFromJson(flow);
            upsertRule(sw, pr);
        }

        std::vector<RuleId> toDelete;
        toDelete.reserve(sw.rulesById.size());
        for (auto& [rid, rulePtr] : sw.rulesById)
        {
            if (rulePtr->lastSeenEpoch != sw.epoch)
            {
                toDelete.push_back(rid);
            }
        }

        for (const auto& rid : toDelete)
        {
            auto it = sw.rulesById.find(rid);
            if (it == sw.rulesById.end())
            {
                continue;
            }
            removeRuleFromTables(sw, it->second.get());
            sw.rulesById.erase(it);
        }

        for (auto& [tableId, tc] : sw.tables)
        {
            (void)tableId;
            tc.rebuildPriorityOrderIfNeeded();
        }
    }

    /** @brief Lookup best matching rule in a single  OpenFlow table (no locking).
     *
     * @details
     * Algorithm:
     * - Convert key to packed bytes
     * - Iterate subtables by descending maxPriority
     * - For each subtable:
     *   maskedKey = key & mask
     *   bucket = buckets[maskedKey]
     *   candidate = bucket.rules.front()
     * - Choose the highest priority candidate
     */
    const Rule* lookupInTableNoLock(const SwitchClassifier& sw,
                                    uint8_t tableId,
                                    const FlowKey& key) const
    {
        auto tit = sw.tables.find(tableId);
        if (tit == sw.tables.end())
        {
            return nullptr;
        }

        const TableClassifier& tc = tit->second;
        KeyBytes keyBytes = packKey(key);

        SPDLOG_LOGGER_TRACE(Logger::instance(), "keyBytes {}", spdlog::to_hex(keyBytes.bytes));

        const Rule* best = nullptr;
        int bestPriority = -1;

        for (const auto& st : tc.subtablesByPriority)
        {
            if (st->maxPriority < bestPriority)
            {
                break;
            }

            SPDLOG_LOGGER_TRACE(
                Logger::instance(),
                "mask {}",
                spdlog::to_hex(st->mask->bytes.bytes.begin(), st->mask->bytes.bytes.end()));

            KeyBytes maskedKey = bitAnd(keyBytes, st->mask->bytes);
            auto it = st->buckets.find(maskedKey);
            if (it == st->buckets.end())
            {
                continue;
            }

            const auto& vec = it->second.rules;
            if (!vec.empty())
            {
                const Rule* cand = vec.front();
                if (cand->priority > bestPriority)
                {
                    best = cand;
                    bestPriority = cand->priority;

                    // [Co-developed with claude code -- Adam]
                    // Inside the branch, not after it, for two reasons.
                    //
                    // Correctness: `best` starts null and `bestPriority` starts at -1, so a
                    // rule whose priority is <= -1 leaves `best` null while this line still
                    // runs -- and spdlog evaluates its arguments regardless of level, so
                    // `best->effect` was a null dereference. parseI32 accepts negative
                    // numbers, and -1 is already a meaningful priority elsewhere in this
                    // codebase (the non-strict delete sentinel), so a control plane reporting
                    // `"priority": -1` was enough to kill the kernel.
                    //
                    // Accuracy: outside the branch it printed the *previous* subtable's best
                    // alongside the *current* subtable's maskedKey, which reads as a match
                    // that never happened.
                    SPDLOG_LOGGER_TRACE(
                        Logger::instance(),
                        "bestPriority key {}:{} -> {}:{}, maskedKey {}, effect(outport) {}",
                        key.ipv4Src,
                        key.tpSrc,
                        key.ipv4Dst,
                        key.tpDst,
                        spdlog::to_hex(maskedKey.bytes),
                        describeFirstOutputPort(best->effect));
                }
            }
        }
        return best;
    }
};

// ======================================================================
// Public API
// ======================================================================

Classifier::Classifier()
    : impl_(new Impl())
{
}

Classifier::~Classifier()
{
    delete impl_;
    impl_ = nullptr;
}

Classifier::Classifier(Classifier&& other) noexcept
    : impl_(other.impl_)
{
    other.impl_ = nullptr;
}

Classifier&
Classifier::operator=(Classifier&& other) noexcept
{
    if (this == &other)
    {
        return *this;
    }
    delete impl_;
    impl_ = other.impl_;
    other.impl_ = nullptr;
    return *this;
}

void
Classifier::updateFromQueriedTables(const json& newTables)
{
    std::unique_lock lock(impl_->mutex);

    if (!newTables.is_array())
    {
        return;
    }

    for (const auto& sw : newTables)
    {
        uint64_t dpid = parseU64(sw.at("dpid"));
        const json& flowNode = sw.at("flows");

        // [Co-developed with claude code -- Adam]
        // An EMPTY array is a snapshot and must be applied; only an unreadable one is skipped.
        //
        // `|| flowsArray->empty()` used to be part of this guard, so a switch reporting no rules was
        // skipped entirely -- and updateOneSwitch is what bumps the epoch and sweeps rules absent
        // from the new snapshot. Every previously-ingested rule therefore survived an empty table,
        // indefinitely.
        //
        // Not a hypothetical input: measured with Ryu in a degraded state, `/stats/flow/1` returned
        // `{"1": []}` for 110 consecutive seconds. The Classifier would go on computing paths from
        // rules the control plane had stopped reporting. Empty paths are a visible failure;
        // confidently wrong paths are not.
        //
        // A body that is not an array at all is different: it means the response was not understood,
        // which is no evidence about the switch's rules, so those are left alone.
        const json* flowsArray = extractFlowArray(flowNode, dpid);
        if (!flowsArray || !flowsArray->is_array())
        {
            continue;
        }

        impl_->updateOneSwitch(dpid, *flowsArray);
    }
}

/** @brief Whether any flow table has been ingested for this switch. See the header.
 *
 * [Co-developed with claude code -- Adam]
 */
bool
Classifier::knowsSwitch(uint64_t dpid) const
{
    std::shared_lock lock(impl_->mutex);
    return impl_->switches.find(dpid) != impl_->switches.end();
}

std::optional<RuleEffect>
Classifier::lookup(uint64_t dpid, const FlowKey& key, uint8_t tableId) const
{
    std::shared_lock lock(impl_->mutex);

    // [Co-developed with claude code -- Adam]
    // Both misses return nullopt silently. This is called once per hop per tracked flow by
    // calFlowPathByQueried, which runs at ~1 kHz, so warning here floods: measured 75,853
    // copies of "switch not found dpid 10" in two minutes with the proxy down, an 8.5 MB log.
    // A single miss is not a fault -- a persistent one is -- and the sole caller now reports
    // that through utils::KeyedFailureLog, using knowsSwitch() to say which of the two it is.
    auto it = impl_->switches.find(dpid);
    if (it == impl_->switches.end())
    {
        return std::nullopt;
    }

    const Rule* r = impl_->lookupInTableNoLock(it->second, tableId, key);
    if (!r)
    {
        return std::nullopt;
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "lookup for {}:{} -> {}:{} effect(output) {}",
                        key.ipv4Src,
                        key.tpSrc,
                        key.ipv4Dst,
                        key.tpDst,
                        describeFirstOutputPort(r->effect));

    return r->effect;
}

size_t
Classifier::getRuleCount(uint64_t dpid) const
{
    std::shared_lock lock(impl_->mutex);
    auto it = impl_->switches.find(dpid);
    if (it == impl_->switches.end())
    {
        return 0;
    }
    return it->second.rulesById.size();
}

} // namespace ndtClassifier
