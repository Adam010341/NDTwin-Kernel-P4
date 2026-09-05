#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"

// --- System & Library Headers ---
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <shared_mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

// --- Third-Party Headers ---
#include "spdlog/spdlog.h"
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/detail/adj_list_edge_iterator.hpp>
#include <boost/graph/detail/adjacency_list.hpp>
#include <boost/graph/detail/edge.hpp>
#include <boost/iterator/iterator_categories.hpp>
#include <boost/iterator/iterator_facade.hpp>
#include <boost/move/utility_core.hpp>
#include <boost/range/irange.hpp>
#include <boost/range/iterator_range_core.hpp>
#include <nlohmann/json.hpp>
#include <openssl/sha.h>

// --- Local Headers ---
#include "utils/Logger.hpp"
#include "utils/KeyedFailureLog.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;
using namespace std;

namespace
{
// [Co-developed with claude code -- Adam]
// Shared by both findReverseEdgeByAgentIpAndPort twins, so the same missing link is reported once
// rather than once per copy. A function-local static rather than a member: both finders are
// const, and a member would have to be mutable for no gain.
utils::KeyedFailureLog&
reverseEdgeFailures()
{
    static utils::KeyedFailureLog log{std::chrono::seconds(60)};
    return log;
}

/** @brief Name one node or edge of a topology JSON well enough to find it in the file.
 *
 * [Co-developed with claude code -- Adam]
 * Every field is read defensively, through contains() and a catch-all, because this runs
 * *while reporting* a failure that one of those fields caused: a describer that trusts
 * `at("device_name")` throws out of the error path and we are back to a diagnostic naming
 * nothing. Falls back to the item's index, which is always available and is still enough to
 * find the entry with `jq '.nodes[41]'`.
 */
std::string
describeTopologyItem(const json& item, const char* kind, std::size_t index)
{
    auto field = [&item](const char* key) -> std::string {
        try
        {
            if (!item.is_object() || !item.contains(key))
            {
                return {};
            }
            const auto& value = item.at(key);
            return value.is_string() ? value.get<std::string>() : value.dump();
        }
        catch (...)
        {
            return {};
        }
    };

    std::string desc = std::string(kind) + " #" + std::to_string(index);

    // Node identity first, then edge identity: one describer, because the caller already
    // knows which loop it is in and the fields do not overlap.
    const std::string name = field("device_name").empty() ? field("nickname")
                                                          : field("device_name");
    if (!name.empty())
    {
        desc += " \"" + name + "\"";
    }
    const std::string ip = field("ip");
    if (!ip.empty())
    {
        desc += " ip=" + ip;
    }
    const std::string srcIp = field("src_ip");
    const std::string dstIp = field("dst_ip");
    if (!srcIp.empty() || !dstIp.empty())
    {
        desc += " src_ip=" + (srcIp.empty() ? std::string("?") : srcIp) +
                " dst_ip=" + (dstIp.empty() ? std::string("?") : dstIp) +
                " src_dpid=" + (field("src_dpid").empty() ? std::string("?") : field("src_dpid")) +
                " dst_dpid=" + (field("dst_dpid").empty() ? std::string("?") : field("dst_dpid"));
    }
    return desc;
}

/// The largest interface index a topology *file* may name, on either side of an edge.
///
/// [Co-developed with claude code -- Adam]
/// A sanity bound, and it is worth being exact about which one, because the obvious story is
/// wrong. This project speaks OpenFlow 1.3 (see Classifier.cpp), where port numbers are 32 bits
/// and only 0xffffff00 and above are reserved -- so 999999, the value round 5 fed it, is a
/// perfectly legal OF 1.3 port number and no protocol rule rejects it. What rejects it is the
/// fleet: across all thirteen shipped topology files the highest interface index is 67, and
/// 65535 is the ceiling of the sixteen-bit port space OpenFlow 1.0 had, so it sits comfortably
/// above any port any switch here has while still refusing a number that is nonsense on its face.
///
/// 🔴 What this deliberately does NOT do: tell port 4 from port 5. A plausible-but-wrong port
/// still passes, and the 2026-08-17 failure that make_topology.py's validate() exists for was
/// exactly that. This bound catches typos and generator bugs, not mistakes.
constexpr std::uint32_t kMaxTopologyInterface = 65535;

/** @brief Refuse a topology document that names things the document does not contain.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * FINDINGS #61 and #62, in one function because they are one defect seen from two sides: a file
 * describing a fabric that does not exist, accepted.
 *
 *   #61 measured (round5-topology-repro/03_mutant_m1_host_edge_ghost_dpid.log): one host edge's
 *       dst_dpid changed 1 -> 99, a switch no node declares. The loader wrote a single
 *       `[warning] ... Skipping edge:` line and served 39 of 40 edges on :8000. Every endpoint
 *       answered 200. A fabric with one cable in the wrong socket looked healthy from outside.
 *
 *   #62 measured (06_/07_mutant logs): src_interface 0 and 999999 on a switch-side port both
 *       loaded, and get_graph_data republished them verbatim.
 *
 * 🔴 THIS RUNS BEFORE THE FIRST add_vertex, AND THAT IS THE DESIGN. The old drop was a rejected
 * input partially applied -- 39/40 of a topology nobody wrote -- and moving the check ahead of
 * the builder is what makes "refused" mean the graph is untouched, rather than "refused, and
 * also here is most of it". loadStaticTopology() turns the throw into one CRITICAL line and
 * main.cpp returns EXIT_FAILURE, before any socket is bound.
 *
 * 🔴 THE HOST SIDE OF A HOST EDGE IS NOT CHECKED FROM BELOW, AND MUST NOT BE.
 * doc/2026-01-02_ndt_api.md:233: "At the edge between the switch and host, the dpid and interface
 * on the host side are set to 0." Five shipped TESTBED files (StaticNetworkTopology_ipAlias4_*)
 * do exactly that on every host edge -- 32 to 96 of them each -- while the eight OVS/P4/Mininet
 * files put 1 there instead. So the lower bound belongs to the side whose dpid names a switch,
 * and only to that side. A check written as "a port index is >= 1" would refuse five shipped
 * files: a wider outage than the defect it was meant to fix.
 *
 * FINDINGS #89 / W-TOPO-THREE-DOORS extends this function on the NODE side. #61/#62 made "the
 * whole file is checked before the first add_vertex" the rule, but the coverage of the rule was
 * transcribed by hand -- edges were checked here, node addresses were parsed here, and three
 * refusals were left sitting inside the builder loop below, where they fire on node N with nodes
 * 0..N-1 already in the graph. That is the 39-of-40 shape this function exists to abolish,
 * reached through a different door. `ecmp_groups` was the fourth door: not looked at here at all,
 * so a `port_id` got none of the range checking its edge-interface sibling got from #62.
 *
 * 🔴 THE BUILDER'S OWN THROWS ARE NOT REMOVED, DELIBERATELY -- same two-layer reasoning as #61's
 * edge guard. If this pass and the builder ever disagree the builder must still refuse rather
 * than add half a graph. What changes is that the refusal now happens here FIRST, so the graph
 * is untouched; the builder copy is the backstop, and the tests tell the two apart by asserting
 * num_vertices == 0 rather than merely that something threw.
 *
 * @param j      the parsed topology document
 * @param where  set to a description of the entry under examination, so the rethrow in
 *               loadStaticTopologyFromFile names it
 * @param mode   the deployment mode the graph will be built in. 🔴 The one signature change this
 *               fix needed: `bridge_name` is read by the builder only under MININET, so checking
 *               it up here is impossible without knowing the mode, and a check that ran in every
 *               mode would refuse the five _ipAlias4_ TESTBED files, none of which declare one.
 */
void
validateStaticTopologyJson(json& j, std::string& where, utils::DeploymentMode mode)
{
    // The endpoints, indexed exactly the way the edge loop below resolves them: switches by
    // dpid, hosts by the first address on the edge, matched against every address every node
    // carries -- findVertexByIpNoLock searches the whole vector, so this must too.
    std::unordered_set<std::uint64_t> switchDpids;
    std::unordered_set<std::uint32_t> nodeAddresses;

    std::size_t itemIndex = 0;
    for (const auto& nodeJson : j["nodes"])
    {
        where = describeTopologyItem(nodeJson, "node", itemIndex++);

        const auto vertexType = static_cast<VertexType>(nodeJson.at("vertex_type").get<int>());
        if (vertexType == VertexType::SWITCH)
        {
            switchDpids.insert(nodeJson.at("dpid").get<std::uint64_t>());
        }
        const auto addresses =
            utils::ipStringVecToUint32Vec(nodeJson.at("ip").get<std::vector<std::string>>());
        nodeAddresses.insert(addresses.begin(), addresses.end());

        // ---- #89 door 3a: a switch_kind no mapping accepts ----
        // switchKindFromString throws std::invalid_argument on anything unmapped, and the builder
        // still calls it for the value it needs. Calling it here for its throw alone is what
        // moves the refusal in front of the first add_vertex.
        if (nodeJson.contains("switch_kind"))
        {
            (void)switchKindFromString(nodeJson.at("switch_kind").get<std::string>());
        }

        // ---- #89 door 3b: a switch with no management address ----
        // FINDINGS #85's door, hoisted. Ten sites call ip.front() on a switch unconditionally,
        // including findSwitchByIp() which does it for every switch while searching, so one
        // `"ip": []` switch is undefined behaviour for the whole graph's address lookup.
        if (vertexType == VertexType::SWITCH && addresses.empty())
        {
            throw std::runtime_error(
                "switch dpid " + std::to_string(nodeJson.at("dpid").get<std::uint64_t>()) +
                " has an empty \"ip\" array; every switch needs at least one management address, "
                "because address lookup reads the first one unconditionally");
        }

        // ---- #89 door 3c: MININET, and a switch with no bridge to attach to ----
        // 🔴 MININET only. The five _ipAlias4_ TESTBED files declare no bridge_name on any switch
        // and must keep loading; the builder reads the field only on this branch, so the check
        // has to sit on the same branch or it takes those five files down.
        if (mode == utils::DeploymentMode::MININET && vertexType == VertexType::SWITCH &&
            !(nodeJson.contains("bridge_name") && nodeJson.at("bridge_name").is_string()))
        {
            throw std::runtime_error(
                "switch dpid " + std::to_string(nodeJson.at("dpid").get<std::uint64_t>()) +
                " has no \"bridge_name\" string, and MININET mode attaches every switch to a "
                "bridge by that name");
        }

        // ---- #89 door 2: ecmp_groups[].port_id, which had no range check at all ----
        // Parsed here, through the same from_json the builder's `.value("ecmp_groups", ...)` will
        // use, so a malformed group is a refusal before the graph is touched rather than a throw
        // from the middle of the node loop. Then the range: the identical bound #62 put on an
        // edge's interface index, because it is the identical thing -- a switch port number.
        // Two of the thirteen shipped files carry no "ecmp_groups" key at all
        // (StaticNetworkTopology_ipAlias4_10Switches{,_all_1g_cable}.json), which is why this
        // reads with value() and not at().
        const auto ecmpGroups = nodeJson.value("ecmp_groups", std::vector<EcmpGroup>{});
        for (const auto& group : ecmpGroups)
        {
            for (const auto& member : group.members)
            {
                const auto* port = std::get_if<PortMember>(&member);
                if (port == nullptr)
                {
                    continue;
                }
                const auto portId = static_cast<std::int64_t>(port->portId);
                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))
                {
                    throw std::runtime_error(
                        "an \"ecmp_groups\" member names \"port_id\" " + std::to_string(portId) +
                        ", which is not a switch port index this loader accepts (1.." +
                        std::to_string(kMaxTopologyInterface) +
                        "). The same bound already applies to an edge's interface index; this "
                        "field was reaching the flow path with no check at all");
                }
            }
        }
    }

    // One end of one edge. `side` is "src" or "dst" and names the JSON keys, so every message
    // below points at the field the operator has to open the file and edit.
    auto checkEndpoint = [&](const json& edgeJson, const char* side) {
        const std::string dpidKey = std::string(side) + "_dpid";
        const std::string ipKey = std::string(side) + "_ip";
        const std::string interfaceKey = std::string(side) + "_interface";

        const auto dpid = edgeJson.at(dpidKey).get<std::uint64_t>();
        const auto ifIndex = edgeJson.at(interfaceKey).get<std::uint32_t>();

        // ---- #61: does this end name something this file contains? ----
        if (dpid != 0)
        {
            if (switchDpids.count(dpid) == 0)
            {
                throw std::runtime_error(
                    "\"" + dpidKey +
                    "\" is " + std::to_string(dpid) +
                    " and no switch node in this file declares that dpid. Refusing the file: this "
                    "link used to be dropped with one warning and the rest of the topology served "
                    "as though it were complete");
            }
        }
        else
        {
            const auto addresses =
                utils::ipStringVecToUint32Vec(edgeJson.at(ipKey).get<std::vector<std::string>>());
            if (addresses.empty())
            {
                throw std::runtime_error(
                    "\"" + dpidKey +
                    "\" is 0, which means \"resolve this end by address\", and \"" + ipKey +
                    "\" is empty, so this end of the link names nothing at all");
            }
            if (nodeAddresses.count(addresses.front()) == 0)
            {
                throw std::runtime_error(
                    "\"" + dpidKey +
                    "\" is 0, so this end is resolved by address, and no node in this file "
                    "carries " +
                    edgeJson.at(ipKey)[0].get<std::string>() +
                    ". Refusing the file: this link used to be dropped with one warning and the "
                    "rest of the topology served as though it were complete");
            }
        }

        // ---- #62: is this an interface index a switch in this fabric could have? ----
        if (ifIndex > kMaxTopologyInterface)
        {
            throw std::runtime_error(
                "\"" + interfaceKey + "\" is " + std::to_string(ifIndex) +
                ", above the largest interface index this loader accepts (" +
                std::to_string(kMaxTopologyInterface) +
                "). It used to be republished verbatim by get_graph_data and used to attribute "
                "flow to a port that does not exist");
        }
        if (dpid != 0 && ifIndex == 0)
        {
            throw std::runtime_error(
                "\"" + interfaceKey + "\" is 0 on the side attached to switch dpid " +
                std::to_string(dpid) +
                ", and 0 is not a switch port. It IS the documented value on the host side of a "
                "host edge, where the dpid is 0, and it is accepted there");
        }
    };

    itemIndex = 0;
    for (const auto& edgeJson : j["edges"])
    {
        where = describeTopologyItem(edgeJson, "edge", itemIndex++);
        checkEndpoint(edgeJson, "src");
        checkEndpoint(edgeJson, "dst");
    }
}
} // namespace

/**
 * @brief The Ryu topology API base, derived from the one configured Ryu address.
 *
 * [Co-developed with claude code -- Adam]
 * This used to be `static const std::string RYU_BASE_URL = "http://localhost:8080/v1.0/topology"`
 * under a "---Please change to your own RYU base url---" comment, which bypassed
 * AppConfig::RYU_IP_AND_PORT -- the knob the flow-stats poll (FlowLinkUsageCollector.cpp) and the
 * OVS routing strategy (FlowRoutingManager.cpp) already read, and the one an operator would
 * expect to be sufficient.
 *
 * The consequence of the split was silent: redeploy Ryu elsewhere and update AppConfig, and
 * switch/host/link liveness would go on polling a dead localhost:8080. execCommand returns an
 * empty body on failure and updateSwitches/updateHosts/updateLinks all early-return on empty
 * without logging, so the graph simply stops tracking the control plane with no error anywhere.
 *
 * A function rather than a namespace-scope std::string: the value depends on another
 * dynamically-initialised object (AppConfig::RYU_IP_AND_PORT), and computing it on demand sidesteps
 * initialisation-order questions entirely. It is called once, from the constructor.
 *
 * Note this is only the *default*. configureTopologyApiUrls() still re-points the poll at the P4
 * proxy for an all-bmv2 MININET topology, and must keep running after the topology file is
 * loaded -- see its own comment for why it cannot move into the constructor.
 */
static std::string
ryuTopologyBaseUrl()
{
    return "http://" + AppConfig::RYU_IP_AND_PORT + "/v1.0/topology";
}

TopologyAndFlowMonitor::TopologyAndFlowMonitor(std::shared_ptr<Graph> graph,
                                               std::shared_ptr<std::shared_mutex> graphMutex,
                                               std::shared_ptr<EventBus> eventBus,
                                               int mode)
    : m_graph(std::move(graph)),
      m_graphMutex(std::move(graphMutex)),
      m_eventBus(std::move(eventBus)),
      m_mode(static_cast<utils::DeploymentMode>(mode))
{
    // Defaults to Ryu. Re-pointed at the P4 proxy in configureTopologyApiUrls(), which cannot
    // run here: the switch kinds come from the topology file, and that is not loaded yet.
    setTopologyApiUrls(ryuTopologyBaseUrl());
}

void
TopologyAndFlowMonitor::setTopologyApiUrls(const std::string& base)
{
    m_ryuUrl[0] = base + "/switches";
    m_ryuUrl[1] = base + "/hosts";
    m_ryuUrl[2] = base + "/links";
}

/** @brief Point the topology poll at whichever control plane owns this data plane.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * The proxy serves Ryu's `/v1.0/topology` shapes, so the kernel polls it the same way and
 * updateSwitches/updateHosts/updateLinks need no P4-specific branch.
 *
 * Must be called *after* loadStaticTopologyFromFile, because it asks the graph what kinds of
 * switch it holds. Calling it from the constructor would always observe an empty topology and
 * silently keep the Ryu default -- exactly the bug that made the identity ifIndex mapping dead
 * code for several commits, so it is done at the point of use instead.
 *
 * Only an all-bmv2 topology is re-pointed. Empty or mixed keeps Ryu, which is the conservative
 * choice: an OVS deployment must not start polling a proxy that is not there.
 */
void
TopologyAndFlowMonitor::configureTopologyApiUrls()
{
    if (m_mode != utils::MININET)
    {
        return;
    }

    const auto groups = getSwitchKindGroups();
    const bool allBmv2 = groups.size() == 1 && groups.begin()->first == SwitchKind::BMV2;
    if (!allBmv2)
    {
        return;
    }

    const std::string base = "http://" + AppConfig::P4_PROXY_IP_AND_PORT + "/v1.0/topology";
    setTopologyApiUrls(base);
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "All-bmv2 topology: polling {} for switch/host/link state instead of Ryu.",
                       base);
}

TopologyAndFlowMonitor::~TopologyAndFlowMonitor()
{
    stop();
}

/** @brief Load the static topology now, on the caller's thread, and say whether it worked.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * The ordering fix. The load used to be the first statement of run(), i.e. on the thread
 * start() spawns, so main.cpp went straight on to bind the sFlow socket and the REST server
 * while the JSON was still being parsed. Measured 2026-09-03 (round5-topology-repro step 09) on
 * a 17 KB topology with one bad host address: `:8000` was accepting connections at 0.50 s and
 * "Server Listening on port 8000" was in the log; the process aborted at 1.50 s, rc=134.
 *
 * That second is the whole problem. Anything that has opened :8000 has told every health check,
 * every guard script and every human reading the log that this kernel is up. A twin that
 * announces itself and then dies is worse than one that never starts, because the announcement
 * is what the rest of the system keys off -- and 1.0 s is comfortably long enough for a poller
 * to have seen it and recorded the kernel as healthy.
 *
 * So the load is pulled forward to the one place that is unambiguously before any bind:
 * main.cpp, before collector->start() and handler->start(). Returning bool rather than throwing
 * keeps the decision at the call site, next to the other startup refusal (the sFlow bind), and
 * makes the ordering readable in main() instead of implied by a thread's first statement.
 *
 * Idempotent: run() calls this too, so a caller that only calls start() still gets a topology,
 * and the second call is a no-op. That matters because it is what lets this compose with the
 * separate D15 change that moves the same three calls into start().
 */
bool
TopologyAndFlowMonitor::loadStaticTopology()
{
    if (m_staticTopologyLoadAttempted.exchange(true))
    {
        // Already done -- by main, or by an earlier start(). loadStaticTopologyFromFile refuses
        // a second load anyway; this just keeps the log quiet about it.
        return m_staticTopologyLoadOk.load();
    }

    const std::string path = activeTopologyPath();
    try
    {
        loadStaticTopologyFromFile(path);
        initializeMappingsFromGraph();
        // Only now is it known whether this is a bmv2 fabric, so only now can the poll be aimed.
        configureTopologyApiUrls();
    }
    catch (const std::exception& err)
    {
        // CRITICAL, one line, and it carries the file and the entry -- see the rethrow in
        // loadStaticTopologyFromFile for why "Invalid IP address: 10.0.0.256" on its own is not
        // a diagnostic. The caller ends the process; nothing has been bound yet.
        SPDLOG_LOGGER_CRITICAL(Logger::instance(),
                               "cannot load the static topology: {}. Refusing to start: a kernel "
                               "whose topology did not load answers every query confidently and "
                               "wrongly. No port has been opened.",
                               err.what());
        m_staticTopologyLoadOk.store(false);
        return false;
    }

    {
        std::shared_lock lock(*m_graphMutex);
        if (boost::num_vertices(*m_graph) == 0)
        {
            // The file was missing, empty, or held no usable nodes. loadStaticTopologyFromFile
            // logs and returns for an unopenable path rather than throwing, so without this the
            // kernel would come up with an empty graph and report a network of zero switches as
            // if that were an observation.
            SPDLOG_LOGGER_CRITICAL(Logger::instance(),
                                   "the static topology \"{}\" produced no nodes at all. "
                                   "Refusing to start; see the error above for whether the file "
                                   "was missing or empty. No port has been opened.",
                                   path);
            m_staticTopologyLoadOk.store(false);
            return false;
        }
    }

    m_staticTopologyLoadOk.store(true);
    return true;
}

void
TopologyAndFlowMonitor::start()
{
    // Once, on the caller's thread, and reported. Two fixes met here:
    //
    //   D15 (fix/d15-dataplane-kind-race) moved the load into start() so that it happens-before
    //   every caller main.cpp sequences after start() -- the power manager's bmv2 verdict used
    //   to race it and lose on every shipped topology file.
    //
    //   fix/topology-load-fails-before-listen made the load *report*: loadStaticTopology() is
    //   guarded to run once, catches what loadStaticTopologyFromFile throws, logs CRITICAL, and
    //   returns false so main.cpp can refuse to bind a port on a topology that did not load.
    //
    // main.cpp calls loadStaticTopology() before anything binds and exits on false; by the time
    // it calls start() this is a no-op returning the cached verdict. start() still calls it
    // because start() is callable on its own -- the tests build a monitor and start it with no
    // main.cpp in front of it -- and because the ordering guarantee must not depend on who called
    // what first. The flags below are set even on a failed load: the load *pass* is over either
    // way, and a consumer that blocked on them forever would be a worse failure than one that
    // reads an empty topology and says so. (staticTopologyLoadedOnThread() records the thread
    // that ran start(); when main.cpp loaded first, that is the same thread.)
    (void)loadStaticTopology();
    m_staticTopologyLoadThread.store(std::this_thread::get_id(), std::memory_order_release);
    m_staticTopologyLoaded.store(true, std::memory_order_release);

    m_running.store(true);
    // Before any worker exists. [Co-developed with claude code -- Adam]
    m_stopSignal.reset();
    m_thread = thread(&TopologyAndFlowMonitor::run, this);
    m_flushEdgeFlowLoop = thread(&TopologyAndFlowMonitor::flushEdgeFlowLoop, this);
}

void
TopologyAndFlowMonitor::setStopReportBound(std::chrono::milliseconds bound)
{
    m_stopReportBound = bound;
}

void
TopologyAndFlowMonitor::stop()
{
    m_running.store(false);

    // [Co-developed with claude code -- Adam]
    // FINDINGS #76. main.cpp's bind-failure path prints its message and then calls this; without
    // the line below, "this" is a join that waits out whichever of the three topology requests was
    // in flight -- up to 5 s each, and 8 s was measured. request() kills it.
    const std::size_t killed = m_stopSignal.request();
    if (killed > 0)
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "stop: cancelled {} in-flight topology request(s)",
                           killed);
    }

    utils::reportIfWorkersOutlastTheBound(m_stopSignal, m_stopReportBound, "topology monitor");

    if (m_thread.joinable())
    {
        m_thread.join();
    }
    // [Co-developed with claude code -- Adam]
    // Must be joined too: a joinable std::thread destructor calls std::terminate.
    if (m_flushEdgeFlowLoop.joinable())
    {
        m_flushEdgeFlowLoop.join();
    }
}

/** @brief loadStaticTopologyFromFile, with the file and the offending entry attached.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Measured 2026-09-03 (round5-topology-repro step 09): feeding the kernel a host whose `ip` is
 * `10.0.0.256` -- which `tools/make_topology.py --hosts 300` emits for h256..h300 -- produced
 * exactly two lines on stderr,
 *
 *     terminate called after throwing an instance of 'std::invalid_argument'
 *       what():  Invalid IP address: 10.0.0.256
 *
 * and nothing else. Neither line names the topology file, and neither names the node. With
 * `--topology` pointing at one of several candidate files and 310 nodes in it, that is a
 * diagnostic the reader has to *guess* their way out of -- and this codebase has a documented
 * habit of guessing wrong under exactly that pressure (a permission denial read as a data-plane
 * failure; an orphaned curl read as "another kernel is running").
 *
 * So the parse keeps a description of the entry it is currently on, and any exception out of it
 * -- json::type_error, our own invalid_argument from an unparseable address, anything a future
 * field adds -- is rethrown with the file and that entry in front of it. The original `what()`
 * is preserved verbatim at the end, because it is the part that says what was wrong.
 */
void
TopologyAndFlowMonitor::loadStaticTopologyFromFile(const std::string& path)
{
    std::string where;
    try
    {
        parseStaticTopologyFile(path, where);
    }
    catch (const std::exception& err)
    {
        throw std::runtime_error(
            "topology file \"" + path + "\": " +
            (where.empty() ? std::string("the file itself could not be read as topology JSON")
                           : where) +
            ": " + err.what());
    }
}

void
TopologyAndFlowMonitor::parseStaticTopologyFile(const std::string& path, std::string& where)
{
    // [Co-developed with claude code -- Adam]
    // Refused rather than repeated. This function *adds* vertices and edges from the file; it does
    // not reconcile against what is already there, so a second call duplicates the whole topology.
    // Measured the first time a poll loop called it twice: switches 10 -> 20 -> 30 -> 40 -> 50,
    // hosts 128 -> 640, edges 288 -> 1440, one extra copy every five seconds.
    //
    // The guard is here rather than only at the call site because the hazard belongs to this
    // function, and it was invisible for as long as there happened to be exactly one caller.
    // Reconciling properly would be the better answer; refusing is the honest one until then.
    {
        std::shared_lock lock(*m_graphMutex);
        if (boost::num_vertices(*m_graph) > 0)
        {
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "static topology already loaded ({} vertices); ignoring a second "
                                "load of {}",
                                boost::num_vertices(*m_graph),
                                path);
            return;
        }
    }

    std::ifstream file(path);
    if (!file.is_open())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot open topology file:  {}", path);
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Load Static Topology File");

    json j;
    file >> j;

    // [Co-developed with claude code -- Adam]
    // FINDINGS #61/#62. The whole file is checked here, before the first add_vertex below, so a
    // file that is going to be refused is refused without having partially applied. Placement is
    // the point: the same checks after the builder would still leave the 39-of-40 graph the
    // measurement found. See validateStaticTopologyJson for what it refuses and what it must not.
    //
    // FINDINGS #89 adds the node-side doors and the mode argument: `bridge_name` is only read
    // under MININET, so the pass cannot check it without being told which mode it is validating
    // for. That is the whole of the signature change.
    validateStaticTopologyJson(j, where, m_mode);

    // [Co-developed with claude code -- Adam]
    // This was commented out, and it is not an oversight that can be undone by uncommenting: the
    // body used to call findVertexByIp(), which takes a shared_lock on this same non-recursive
    // shared_mutex, so taking the write lock here deadlocked the kernel at startup. That is almost
    // certainly why it was commented out rather than fixed.
    //
    // Without it, add_vertex/add_edge mutate the graph unlocked while start() has already spawned
    // flushEdgeFlowLoop, and main.cpp starts the collector and power manager around the same time --
    // any of which may read the graph. A genuine data race, pre-existing since the d6f7c01 refactor.
    //
    // The two calls in the body now use findVertexByIpNoLock, which already existed: this class has
    // a NoLock variant of essentially every lookup precisely for callers that already hold the lock.
    // m_switchKindMutex below is a different mutex and does not participate.
    std::unique_lock lock(*m_graphMutex);

    std::unordered_map<uint64_t, Graph::vertex_descriptor> dpidToVertex;

    // Add nodes
    std::size_t itemIndex = 0;
    for (const auto& nodeJson : j["nodes"])
    {
        // Set before anything is read out of the entry, so the description survives a throw
        // from the very first field access.
        where = describeTopologyItem(nodeJson, "node", itemIndex++);

        // VertexProperties vp = nodeJson.get<VertexProperties>();
        // Custom extraction (like from_json function)
        VertexProperties vp;
        vp.vertexType = static_cast<VertexType>(nodeJson.at("vertex_type").get<int>());
        vp.mac = nodeJson.at("mac").get<uint64_t>();
        vp.ip = utils::ipStringVecToUint32Vec(nodeJson.at("ip").get<std::vector<std::string>>());
        vp.dpid = nodeJson.at("dpid").get<uint64_t>();
        vp.isUp = false;
        vp.isEnabled = false;
        vp.deviceName = nodeJson.at("device_name").get<std::string>();
        vp.nickName = nodeJson.at("nickname").get<std::string>();
        vp.brandName = nodeJson.at("brand_name").get<std::string>();

        // [Co-developed with claude code -- Adam]
        // Prefer an explicit "switch_kind"; fall back to mapping brand_name so both
        // existing topology files keep working unchanged. A malformed switch_kind throws
        // out of switchKindFromString, which is deliberate: failing at load is far better
        // than misrouting flow rules at runtime.
        if (nodeJson.contains("switch_kind"))
        {
            vp.switchKind = switchKindFromString(nodeJson.at("switch_kind").get<std::string>());
        }
        else
        {
            vp.switchKind = switchKindFromBrandName(vp.brandName);
        }

        vp.deviceLayer = nodeJson.at("device_layer").get<int>();

        // [Co-developed with claude code -- Adam]
        // value(), not at(): host nodes carry no plug assignment and every switch node in every
        // shipped topology file does. Read here so /ndt/get_static_topology_json can echo the
        // real per-switch pair instead of the constant it used to fabricate.
        vp.smartPlugIp = nodeJson.value("smart_plug_ip", std::string{});
        vp.smartPlugOutlet = nodeJson.value("smart_plug_outlet", -1);

        vp.ecmpGroups = nodeJson.value("ecmp_groups", std::vector<EcmpGroup>{});

        // [Co-developed with claude code -- Adam]
        // Ten places call `ip.front()` on a switch's address list without checking it, including
        // findSwitchByIp(), which does so for *every* switch vertex while searching -- so one
        // switch with `"ip": []` is undefined behaviour that takes out IP lookup for the whole
        // graph, not just that switch. `at("ip")` throws on a missing key but accepts an empty
        // array, so only the file has to be wrong.
        //
        // Rejected here rather than guarding each call site: this makes the invariant those ten
        // sites already assume actually true, and failing at load with the offending dpid beats
        // undefined behaviour later. Same reasoning as the malformed-switch_kind throw above.
        //
        // 🔴 FINDINGS #89 door 3: this throw, the switch_kind one above and the bridge_name one
        // below are all now ALSO made by validateStaticTopologyJson, before the first add_vertex.
        // These three copies are the backstop, not the check: reached on node N they leave nodes
        // 0..N-1 in the graph, which is the partial application #61 exists to abolish. Do not
        // delete them -- if the two passes ever disagree, refusing here still beats building half
        // a graph -- and do not treat them as the guard either. TopologyInputValidationTest's
        // three *LeavesNoPartiallyLoadedGraph cases assert num_vertices == 0, not merely that
        // something threw, and that is what tells the two apart.
        if (vp.vertexType == VertexType::SWITCH && vp.ip.empty())
        {
            throw std::runtime_error(
                "switch dpid " + std::to_string(vp.dpid) + " (\"" + vp.nickName +
                "\") has an empty \"ip\" array; every switch needs at least one management "
                "address, because address lookup reads the first one unconditionally");
        }

        if (m_mode == utils::DeploymentMode::MININET && vp.vertexType == VertexType::SWITCH)
        {
            vp.bridgeNameForMininet = nodeJson.at("bridge_name").get<std::string>();
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "vp.bridgeNameForMininet {}",
                                vp.bridgeNameForMininet);
        }

        auto v = boost::add_vertex(vp, *m_graph);

        if (vp.vertexType == VertexType::SWITCH)
        {
            dpidToVertex[vp.dpid] = v;
            // [Co-developed with claude code -- Adam]
            // Index the data plane while we are here, so the flow-install path can look it
            // up in O(1) instead of copying the whole graph per entry.
            std::unique_lock kindLock(m_switchKindMutex);
            m_dpidToSwitchKind[vp.dpid] = vp.switchKind;
        }
    }
    // Add edges
    itemIndex = 0;
    for (const auto& edgeJson : j["edges"])
    {
        where = describeTopologyItem(edgeJson, "edge", itemIndex++);

        // EdgeProperties ep = edgeJson.get<EdgeProperties>();
        // Custom extraction (like above, like from_json function)
        EdgeProperties ep;
        ep.isUp = false;
        ep.isEnabled = false;
        ep.linkBandwidth = edgeJson.at("link_bandwidth_bps").get<uint64_t>();
        ep.leftBandwidth = ep.linkBandwidth;
        // [Co-developed with claude code -- Adam]
        // F-8. The declared capacity was already being read on the line above and handed to
        // leftBandwidth -- the field TESTBED mode reports -- while leftBandwidthFromFlowSample,
        // the field MININET mode reports (HttpSession.cpp handleGetGraphData), was left holding
        // its in-class initialiser. That initialiser was a literal 1 Gbit/s, so every core link
        // this file declares at 10 Gbit/s advertised one tenth of its headroom until a flow
        // sample arrived, and an edge that never carries traffic never gets one: in MININET mode
        // the counter-sample branch returns before touching m_counterReports
        // (FlowLinkUsageCollector.cpp), so only flow samples create the map entry the rate loop
        // iterates. A permanently silent 10 Gbit/s link kept the wrong figure forever.
        //
        // Both fields are seeded here, from the same declared number, and both are stamped
        // Declared. That is deliberately not the same claim as Measured: nothing has observed
        // this link yet, and under Mininet nothing ever enforced the 10 Gbit/s either.
        ep.leftBandwidthFromFlowSample = ep.linkBandwidth;
        ep.leftBandwidthSource = BandwidthSource::Declared;
        ep.linkBandwidthUsage = 0;
        ep.linkBandwidthUtilization = 0;
        ep.srcIp =
            utils::ipStringVecToUint32Vec(edgeJson.at("src_ip").get<std::vector<std::string>>());
        ep.srcDpid = edgeJson.at("src_dpid").get<uint64_t>();
        ep.srcInterface = edgeJson.at("src_interface").get<uint32_t>();
        ep.dstIp =
            utils::ipStringVecToUint32Vec(edgeJson.at("dst_ip").get<std::vector<std::string>>());
        ep.dstDpid = edgeJson.at("dst_dpid").get<uint64_t>();
        ep.dstInterface = edgeJson.at("dst_interface").get<uint32_t>();
        // ep.flowSet = std::set<sflow::FlowKey>();
        ep.flowSet = {};

        std::optional<Graph::vertex_descriptor> srcVertexOpt;
        std::optional<Graph::vertex_descriptor> dstVertexOpt;

        // Lookup switch by src DPID, or host by IP if src_dpid == 0
        if (ep.srcDpid != 0)
        {
            auto it_src = dpidToVertex.find(ep.srcDpid);
            if (it_src != dpidToVertex.end())
            {
                srcVertexOpt = it_src->second;
            }
        }
        else if (!ep.srcIp.empty())
        {
            srcVertexOpt = findVertexByIpNoLock(ep.srcIp[0]);
        }

        // Lookup switch by dst DPID, or host by IP if dst_dpid == 0
        if (ep.dstDpid != 0)
        {
            auto it_dst = dpidToVertex.find(ep.dstDpid);
            if (it_dst != dpidToVertex.end())
            {
                dstVertexOpt = it_dst->second;
            }
        }
        else if (!ep.dstIp.empty())
        {
            dstVertexOpt = findVertexByIpNoLock(ep.dstIp[0]);
        }

        // [Co-developed with claude code -- Adam]
        // FINDINGS #61, the second layer. validateStaticTopologyJson resolved every edge in this
        // file before the first vertex was added, so both ends are present by construction and
        // this branch is unreachable on any file that got this far. It is still written, and it
        // still refuses: the failure being fixed is a *silent* drop, and "the validator and the
        // builder disagree" must not be the one remaining path back to it. What used to be here
        // was a WARN and a `continue`, which is how 40 edges became 39 while every endpoint went
        // on answering 200.
        if (!srcVertexOpt.has_value() || !dstVertexOpt.has_value())
        {
            throw std::runtime_error(
                "this edge resolved while the file was validated but not while the graph was "
                "built, which should be impossible. Refusing rather than dropping it: a graph "
                "quietly missing one link reports a healthy fabric with a cable unplugged");
        }
        boost::add_edge(srcVertexOpt.value(), dstVertexOpt.value(), ep, *m_graph);
    }

    // [Co-developed with claude code -- Adam]
    // Report the data plane, and refuse a mixed topology unless explicitly allowed. Doing
    // this at load turns a confusing runtime mixture into a clear startup message.
    validateDataPlaneHomogeneity(AppConfig::ALLOW_MIXED_DATAPLANE);

    // [Co-developed with claude code -- Adam]
    // W10. The names an operator set, laid back over the graph -- LAST, and inside this
    // function rather than in loadStaticTopology() above it, for two reasons. Last, because a
    // topology that is about to be refused (a mixed data plane, a node this file's validator
    // rejects) must never have an overlay applied to it. Here, because "the topology is
    // loaded" and "the topology is loaded with the operator's names on it" have to be the
    // same event: get_nickname and get_graph_data read VertexProperties straight out of the
    // graph, so anything that can observe the graph between those two points observes the
    // shipped names and is wrong. The graph write lock taken above is still held.
    applyNicknameOverlayNoLock();
}

std::optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByIp(uint32_t ip) const
{
    std::shared_lock lock(*m_graphMutex);

    for (auto [v_it, v_end] = boost::vertices(*m_graph); v_it != v_end; ++v_it)
    {
        const auto& props = (*m_graph)[*v_it];
        if (std::find(props.ip.begin(), props.ip.end(), ip) != props.ip.end())
        {
            return *v_it;
        }
    }

    return std::nullopt;
}

std::optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByIpNoLock(uint32_t ip) const
{
    for (auto [v_it, v_end] = boost::vertices(*m_graph); v_it != v_end; ++v_it)
    {
        const auto& props = (*m_graph)[*v_it];
        if (std::find(props.ip.begin(), props.ip.end(), ip) != props.ip.end())
        {
            return *v_it;
        }
    }

    return std::nullopt;
}

// [Co-developed with claude code -- Adam]
//
// The one place that decides which topology file this run uses.
//
// NDTWIN_TOPO_FILE was previously honoured in exactly one of five places. The other four
// -- the read-modify-rename pairs in setVertexDeviceName and setVertexNickname -- used the
// hardcoded TOPOLOGY_FILE_MININET. Since dpids 1-10 exist in both the OVS and P4 topology
// files, renaming a device while running the P4 fabric found a matching dpid in the OVS
// file and wrote the new name *into the OVS topology*, corrupting it, while hosts threw
// "No matching node in JSON".
std::string
TopologyAndFlowMonitor::activeTopologyPath() const
{
    // The override is checked before the mode defaults, so --topology (which sets this env
    // var) works in TESTBED as well as MININET. Checking the mode first meant
    // `--mode testbed --topology custom.json` silently loaded the default file instead --
    // the same class of quiet-wrong-topology failure this function exists to prevent.
    // An empty value counts as unset. getenv returns a valid pointer to "" for
    // NDTWIN_TOPO_FILE= , which would otherwise make this return "" -- and since the rename
    // paths append ".tmp" to whatever comes back, the kernel would write a stray ".tmp" into
    // its working directory and rename it over nothing.
    const char* custom = std::getenv("NDTWIN_TOPO_FILE");
    if (custom != nullptr && custom[0] != '\0')
    {
        return custom;
    }
    if (m_mode == utils::TESTBED)
    {
        return TOPOLOGY_FILE;
    }
    return TOPOLOGY_FILE_MININET;
}

/** @brief The REST poll on its own, without re-reading the static topology file.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Split out because the loop in run() must not repeat the static load.
 * loadStaticTopologyFromFile *adds* vertices and edges; it does not reconcile. Calling it a second
 * time duplicates the entire topology, and the first time the poll loop ran this was measured
 * immediately -- switches 10 -> 20 -> 30 -> 40 -> 50, hosts 128 -> 640, edges 288 -> 1440, growing by
 * one whole topology every five seconds.
 *
 * That was invisible before because the load ran exactly once per process. It is the kind of latent
 * trap a unit test would not have found either: the duplication only appears on the *second* call,
 * and there had never been one. loadStaticTopologyFromFile now refuses a second load outright, so
 * the trap is gone rather than merely avoided here.
 */
std::string
TopologyAndFlowMonitor::buildTopologyFetchCommand(const std::string& url)
{
    // [Co-developed with claude code -- Adam]
    // -sS rather than -s: -S restores curl's own one-line diagnosis on stderr while keeping the
    // progress meter off, so "(28) Operation timed out" reaches the log alongside the warning
    // below. execCommand captures stdout only, so this costs the caller nothing.
    //
    // [Co-developed with claude code -- Adam]
    // --write-out is the fix for round 6's N1. utils::execCommand is a popen() that returns
    // stdout and discards the exit status, so `curl -sS` alone makes an HTTP 500 and an HTTP 200
    // literally indistinguishable to this process -- which is why the completeness check tested
    // `!body.empty()`: it had nothing else to test. --write-out prints to the same stdout the
    // body does, so the status arrives through the one channel that does survive.
    //
    // Appended, never prefixed, and split from the right by classifyEndpointReply: a body that
    // contains the marker cannot move the split, and one that ends without a newline still parses.
    return "curl -sS -X GET --connect-timeout " +
           std::to_string(kTopologyConnectTimeoutSeconds) + " --max-time " +
           std::to_string(kTopologyRequestTimeoutSeconds) + " --write-out '\\n" +
           kHttpStatusSentinel + "%{http_code}' " + url;
}

/** @brief One bounded topology GET. Empty means "did not answer"; the caller decides what to say.
 *
 * [Co-developed with claude code -- Adam]
 * An empty body is the only failure signal available here: utils::execCommand returns the child's
 * stdout and swallows its exit status, so a timeout, a refused connection and a controller that
 * genuinely had nothing to say arrive as the same empty string. Reporting is left to the caller so
 * that a wedged control plane -- which fails all three of these -- produces one line and not three.
 */
TopologyAndFlowMonitor::EndpointReply
TopologyAndFlowMonitor::fetchTopologyEndpoint(const std::string& url)
{
    try
    {
        return classifyEndpointReply(
            utils::execCommandCancellable(buildTopologyFetchCommand(url), m_stopSignal)
                .output);
    }
    catch (const exception& ex)
    {
        // popen() itself failed: out of file descriptors or memory. Not a control-plane problem,
        // and not rate-limited, because it is not the failure that repeats every poll.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "could not run the topology request for {} at all: {}",
                           url,
                           ex.what());
        return EndpointReply{};
    }
}

// [Co-developed with claude code -- Adam]
const char*
TopologyAndFlowMonitor::endpointOutcomeToken(EndpointOutcome outcome)
{
    switch (outcome)
    {
        case EndpointOutcome::Ok:
            return kOutcomeOk;
        case EndpointOutcome::NoResponse:
            return kOutcomeNoResponse;
        case EndpointOutcome::ReportedFailure:
            return kOutcomeReportedFailure;
        case EndpointOutcome::Unparseable:
            return kOutcomeUnparseable;
        case EndpointOutcome::WrongShape:
            return kOutcomeWrongShape;
    }
    return kOutcomeNoResponse;
}

/** @brief The rule round 6 found missing: what actually came back, and whether it can be read.
 *
 * [Co-developed with claude code -- Adam]
 * Modelled on the flow-table path in DeviceConfigurationAndPowerManager::fetchOpenFlowTablesInternal
 * (empty -> no_response, will-not-parse -> unparseable, the control plane said it failed ->
 * reported_failure), which is the branching this one did not have. The order of the tests is the
 * part worth reading:
 *
 *   1. Status first, because a failure is cheap and fast: an HTTP 500 with a JSON error body
 *      parses perfectly and would otherwise pass every later test. This is exactly how it slid
 *      past before, and it is the same trap classifyFlowStatsReply documents for {"error": ...}.
 *   2. Status 000 means curl never got a status line -- refused, unresolvable, or either deadline.
 *      Same fault the empty body was already catching, so they agree instead of competing.
 *   3. Then emptiness, then JSON, then the shape. `[]` passes all three: it is an answer.
 */
TopologyAndFlowMonitor::EndpointReply
TopologyAndFlowMonitor::classifyEndpointReply(const std::string& rawCurlOutput)
{
    EndpointReply reply;

    const std::string sentinel = kHttpStatusSentinel;
    std::string body = rawCurlOutput;

    const auto at = rawCurlOutput.rfind(sentinel);
    if (at != std::string::npos)
    {
        body = rawCurlOutput.substr(0, at);
        // The command puts a newline in front of the marker so the body ends where it ended.
        if (!body.empty() && body.back() == '\n')
        {
            body.pop_back();
        }
        try
        {
            reply.httpStatus = std::stol(rawCurlOutput.substr(at + sentinel.size()));
        }
        catch (const std::exception&)
        {
            // curl wrote the marker and then something that is not a number. Unreachable with
            // %{http_code}, and treated as "no status" rather than as a usable answer.
            reply.httpStatus = 0;
        }
    }

    const auto firstReal = body.find_first_not_of(" \t\r\n");
    const bool bodyIsBlank = (firstReal == std::string::npos);

    if (reply.httpStatus != 0 && (reply.httpStatus < 200 || reply.httpStatus >= 300))
    {
        // The control plane answered and said no. Round 6 measured this on all three endpoints:
        // every one of them was recorded as "answered" and the round as Complete.
        reply.outcome = EndpointOutcome::ReportedFailure;
        return reply;
    }
    if (reply.httpStatus == 0 || bodyIsBlank)
    {
        reply.outcome = EndpointOutcome::NoResponse;
        return reply;
    }

    const auto parsed = nlohmann::json::parse(body, nullptr, false);
    if (parsed.is_discarded())
    {
        reply.outcome = EndpointOutcome::Unparseable;
        return reply;
    }
    if (!parsed.is_array())
    {
        // All three Ryu topology endpoints return a JSON array (p4_proxy/proxy_agent/ryu_topology.py
        // renders switches, hosts and links as lists). An object here is a body that parses and is
        // still not the thing that was asked for -- and updateSwitches/updateHosts/updateLinks
        // iterate it, so what it produces downstream is a silent zero, not an error.
        reply.outcome = EndpointOutcome::WrongShape;
        return reply;
    }

    reply.outcome = EndpointOutcome::Ok;
    reply.body = std::move(body);
    return reply;
}

TopologyAndFlowMonitor::PollRoundKind
TopologyAndFlowMonitor::classifyPollRound(EndpointOutcome switches,
                                          EndpointOutcome hosts,
                                          EndpointOutcome links)
{
    // [Co-developed with claude code -- Adam]
    // Round 6 N1: this counted bodies, and every failure mode except a genuinely empty one
    // produces a body. It now counts READS -- Ok and nothing else -- so a 500, a JSON object
    // where an array belongs, and a page of HTML each subtract from the count the way an
    // unanswered request always did.
    const auto read = [](EndpointOutcome outcome) { return outcome == EndpointOutcome::Ok ? 1 : 0; };
    const int answered = read(switches) + read(hosts) + read(links);
    if (answered == 3)
    {
        return PollRoundKind::Complete;
    }
    if (answered == 0)
    {
        return PollRoundKind::Silent;
    }
    return PollRoundKind::Partial;
}

bool
TopologyAndFlowMonitor::shouldAnnouncePartialRound(PollRoundKind previous, PollRoundKind current)
{
    // [Co-developed with claude code -- Adam]
    // Silent -> Partial counts as newly partial and is announced: the control plane came back far
    // enough to start feeding the graph again, which is when the mixed-age problem *starts*, and
    // the warning next to m_topologyFetchFailures will not fire for it because its run counter is
    // already non-zero by then.
    return current == PollRoundKind::Partial && previous != PollRoundKind::Partial;
}

/** @brief Records how complete this round was, and says so once when it turns partial.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md A-2, third uncovered item; 11_behavior-evidence.md §6 open question 3 asked
 * whether a round should be all-or-nothing. It should not, and the reasons are worth keeping next
 * to the code that declines to do it:
 *
 *   1. All three writers are monotone-up. updateSwitches sets isUp/isEnabled true and never false;
 *      so does updateLinks; neither removes a vertex or an edge. A partial round therefore cannot
 *      manufacture a "down" -- it can only fail to lift one. Discarding the half that answered
 *      would throw away the only evidence available that those switches are up.
 *      [Co-developed with claude code -- Adam] Still true after FINDINGS #46, and worth saying
 *      why rather than leaving the reader to check: updateSwitches now *declines* to lift `isUp`
 *      for a switch with a standing commanded power-off, but declining is not writing false. It
 *      leaves the vertex exactly as it found it, so the argument above -- a partial round cannot
 *      manufacture a down -- is unchanged. `isEnabled` is still written unconditionally.
 *   2. A-2's failure direction is pessimistic and silent: the twin showed 40 links down and 10
 *      switches disabled while the fabric forwarded at 0% loss. Dropping a good switches reply
 *      because links did not answer converts a partial answer into no answer, which is a move in
 *      exactly that pessimistic direction. With /links wedged and /switches healthy -- which is
 *      the observed Ryu wedge, since get_link is the blocking one -- all-or-nothing would mean
 *      the twin never learns that any switch is up again.
 *   3. There is no transaction to roll back. updateSwitches has already mutated the shared graph
 *      under m_graphMutex before updateLinks runs. Real atomicity means building a shadow graph
 *      and swapping it, across a mutex shared with the liveness worker and the REST layer. That
 *      is a design change, not the smallest change that makes this observable.
 *
 * So the round is applied as before, and what is new is that it now says which kind of round it
 * was. The line is edge-triggered and carries kPartialRoundToken so a scraper can count episodes.
 */
TopologyAndFlowMonitor::PollRoundKind
TopologyAndFlowMonitor::noteAndAnnouncePollRound(const EndpointReply& switches,
                                                 const EndpointReply& hosts,
                                                 const EndpointReply& links)
{
    // [Co-developed with claude code -- Adam]
    // Round 6 N1. These three were `!body.empty()`, which is why a 500 counted as an answer. The
    // emptiness rule has not gone away -- it moved into classifyEndpointReply, where "[]" is still
    // an answer and "" is still not; what is new is that four other ways of not answering now
    // reach this line as themselves instead of as a non-empty string.
    const PollRoundKind kind = classifyPollRound(switches.outcome, hosts.outcome, links.outcome);
    const bool announce = shouldAnnouncePartialRound(m_lastPollRoundKind, kind);
    {
        // Written under the lock because pollRoundJson() reads both on an HTTP thread.
        std::lock_guard<std::mutex> lock(m_pollRoundMutex);
        m_lastPollRoundKind = kind;
        m_lastRoundEndpoints[0] = {switches.httpStatus, switches.outcome};
        m_lastRoundEndpoints[1] = {hosts.httpStatus, hosts.outcome};
        m_lastRoundEndpoints[2] = {links.httpStatus, links.outcome};
    }

    if (announce)
    {
        // Named by role rather than by URL: the roles are what the reader has to reason about,
        // and they stay the same when the poll is re-pointed at the P4 proxy.
        std::string answered;
        std::string missing;
        const auto note = [&answered, &missing](const char* role, const EndpointReply& reply) {
            if (reply.usable())
            {
                answered += answered.empty() ? "" : ", ";
                answered += role;
                return;
            }
            // The reason and the status, not just the role: "links did not answer" and "links
            // answered 500" send an operator to two different machines.
            missing += missing.empty() ? "" : ", ";
            missing += role;
            missing += " (";
            missing += endpointOutcomeToken(reply.outcome);
            missing += ", HTTP ";
            missing += std::to_string(reply.httpStatus);
            missing += ")";
        };
        note(kEndpointRoles[0], switches);
        note(kEndpointRoles[1], hosts);
        note(kEndpointRoles[2], links);

        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{}: {} answered and {} did not, and the half that answered was "
                           "applied anyway. The graph now mixes this poll's {} with whatever {} "
                           "was last seen at, and nothing downstream can tell those two ages "
                           "apart. Applying the half is deliberate -- dropping it would be the "
                           "pessimistic direction, which is the direction of this bug -- so the "
                           "thing to fix is {}. Logged once per episode, not once per poll.",
                           kPartialRoundToken,
                           answered,
                           missing,
                           answered,
                           missing,
                           missing);
    }

    return kind;
}

void
TopologyAndFlowMonitor::pollControlPlaneTopology()
{
    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md A-2. These were three bare `curl -s` calls with no deadline, each
    // wrapped in a try/catch that could only ever fire on popen() failing -- never on the failure
    // that actually happened, which is a child that does not return. One unresponsive controller
    // therefore ended this thread for the lifetime of the process, and did it without writing a
    // single line: the loop in run() logs only when graphLivenessSummary() *changes*, and a poll
    // that never returns never changes it. The fingerprint operators were left with was
    // "up=true, enabled=false" on every switch, which is not a message.
    //
    // What is new is only that each request now ends, and that not ending is said out loud. The
    // control flow is deliberately the one that was already here: all three are fetched, then all
    // three are applied together. updateSwitches, updateHosts and updateLinks each return early on
    // an empty body, so an unanswered endpoint leaves its part of the graph untouched while the
    // endpoints that did answer are still applied. That is pre-existing behaviour, and changing it
    // is a separate decision from bounding the wait.
    const auto startedAt = std::chrono::steady_clock::now();

    // [Co-developed with claude code -- Adam]
    // FINDINGS #76. Three requests, and a stop used to be answered only after all three. The checks
    // below make the unit of shutdown latency one request instead of a whole round; returning early
    // leaves the graph exactly as a round that never ran would -- see the note above on all three
    // writers returning early on an empty body.
    const EndpointReply switchesReply = fetchTopologyEndpoint(m_ryuUrl[0]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply hostsReply = fetchTopologyEndpoint(m_ryuUrl[1]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply linksReply = fetchTopologyEndpoint(m_ryuUrl[2]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }

    // [Co-developed with claude code -- Adam]
    // Round 6 N1, the half of the fix that is not a report. An unreadable reply now reaches the
    // writers as the empty string, which is the "did not answer" path they have always had: the
    // endpoints that were read are still applied, and the ones that were not still leave their
    // part of the graph untouched. Before this, a 500's error body was handed to updateLinks and
    // iterated -- the only trace the whole failure left was 16 lines of "ignoring a links entry
    // with no src/dst endpoint", which describes a malformed fabric, not a failed read.
    const std::string& switchesStr = switchesReply.body;
    const std::string& hostsStr = hostsReply.body;
    const std::string& linksStr = linksReply.body;

    const double elapsedSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();

    // Named, not counted: "the control plane is silent" and "hosts specifically is silent" are
    // different faults, and the second one is invisible if the message only says how many.
    std::string silent;
    std::string firstSilent;
    const auto noteIfSilent = [&silent, &firstSilent](const std::string& url,
                                                     const EndpointReply& reply) {
        if (!reply.usable())
        {
            silent += silent.empty() ? "" : ", ";
            silent += url;
            silent += " (";
            silent += endpointOutcomeToken(reply.outcome);
            silent += ", HTTP ";
            silent += std::to_string(reply.httpStatus);
            silent += ")";
            if (firstSilent.empty())
            {
                firstSilent = url;
            }
        }
    };
    noteIfSilent(m_ryuUrl[0], switchesReply);
    noteIfSilent(m_ryuUrl[1], hostsReply);
    noteIfSilent(m_ryuUrl[2], linksReply);

    // [Co-developed with claude code -- Adam]
    // A-2's third uncovered item. This changes nothing about what gets applied -- see
    // noteAndAnnouncePollRound for why all-or-nothing would make this bug worse rather than
    // better -- it only records which kind of round this was and says so once when a round starts
    // producing a mixed-age graph. Called before updateGraph so lastPollRoundKind() describes the
    // round whose data the graph is about to receive.
    noteAndAnnouncePollRound(switchesReply, hostsReply, linksReply);

    // Edge-triggered: this poll repeats every 5-30s forever, so an unrecovered control plane would
    // otherwise write this line until the disk filled. The run is per pass rather than per
    // endpoint, so a poll where two of three answer cannot report itself recovered.
    if (!silent.empty())
    {
        if (m_topologyFetchFailures++ == 0)
        {
            SPDLOG_LOGGER_WARN(
                Logger::instance(),
                "topology poll could not read {} after {:.3f}s (each request bounded at {}s "
                "connect / {}s total). The graph keeps what it last saw, and this retries next "
                "poll -- but until it clears, switches and links this twin never saw will read as "
                "down and disabled while the fabric may be forwarding normally. Confirm with: "
                "curl -s -o /dev/null --max-time 3 -w '%{{http_code}}\\n' {}",
                silent,
                elapsedSeconds,
                kTopologyConnectTimeoutSeconds,
                kTopologyRequestTimeoutSeconds,
                firstSilent);
        }
    }
    else if (m_topologyFetchFailures != 0)
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "topology poll is readable again after {} unreadable pass(es), in "
                           "{:.3f}s",
                           m_topologyFetchFailures,
                           elapsedSeconds);
        m_topologyFetchFailures = 0;
    }

    updateGraph(switchesStr, hostsStr, linksStr);
}

/** @brief The round's verdict, in the shape /ndt/get_graph_data serves it.
 *
 * [Co-developed with claude code -- Adam]
 * Round 6 N1 measured the gap this closes: with /links answering 500 the graph read 14/14 nodes
 * and 40/40 edges up, and the response's top-level keys were exactly ["edges","nodes"] -- a
 * half-read round and a complete one were identical in every channel a consumer has. The log line
 * added by A-2 is edge-triggered and once per episode, so a consumer that connects mid-episode
 * cannot see it at all; this is level-triggered and always present.
 */
json
TopologyAndFlowMonitor::pollRoundJson() const
{
    std::lock_guard<std::mutex> lock(m_pollRoundMutex);

    const char* kindToken = "not_yet_polled";
    switch (m_lastPollRoundKind)
    {
        case PollRoundKind::NotYetPolled:
            kindToken = "not_yet_polled";
            break;
        case PollRoundKind::Complete:
            kindToken = "complete";
            break;
        case PollRoundKind::Partial:
            kindToken = "partial";
            break;
        case PollRoundKind::Silent:
            kindToken = "silent";
            break;
    }

    json endpoints = json::object();
    for (std::size_t i = 0; i < kEndpointRoles.size(); ++i)
    {
        endpoints[kEndpointRoles[i]] = {{"outcome", endpointOutcomeToken(m_lastRoundEndpoints[i].outcome)},
                                        {"http_status", m_lastRoundEndpoints[i].httpStatus}};
    }

    // `complete` as its own boolean as well as the token: the one question every consumer asks is
    // "may I trust this graph", and making them string-compare to find out is how a consumer ends
    // up not asking. Both move together or neither does.
    return json{{"kind", kindToken},
                {"complete", m_lastPollRoundKind == PollRoundKind::Complete},
                {"endpoints", endpoints}};
}

void
TopologyAndFlowMonitor::updateSwitches(const string& topologyData)
{
    // Update Vertex(Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto switchesInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update switch json: {}", switchesInfoJson.dump(4));

        for (const auto& switchInfoJson : switchesInfoJson)
        {
            // Note that the "dpid" is written in base 16
            const string switchDpidStr = switchInfoJson.value("dpid", "");
            // [Co-developed with claude code -- Adam]
            // Was `stoull(switchDpidStr, nullptr, 16)`. An entry carrying no "dpid" yields ""
            // here, and stoull("") throws std::invalid_argument -- which is not a
            // json::exception, so it walked straight past the catch below, past updateGraph
            // (pollControlPlaneTopology calls it outside all three of its try blocks), past
            // run(), and out of the thread entry into std::terminate. The catch's comment
            // claimed a malformed reply cost us the poll; for this flavour it cost the process.
            // One bad entry now costs that entry.
            const auto switchDpidOpt = utils::tryParseHexUint64(switchDpidStr);
            if (!switchDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a switches entry whose dpid is not a hex string: "
                                   "'{}'",
                                   switchDpidStr);
                continue;
            }
            const uint64_t switchDpidUint64 = *switchDpidOpt;

            // TRACE, not INFO. This printed once per switch per process while updateSwitches was
            // called exactly once; making run() poll periodically turned it into ten lines every
            // interval, which is my own regression from that change. The WARN below is the line
            // that carries information -- a dpid the static topology does not know about.
            // [Co-developed with claude code -- Adam]
            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                "switchDpidStr {} switchDpidUint64 {}",
                                switchDpidStr,
                                switchDpidUint64);

            // Update switch isUp status
            // Keep Thread Safe
            {
                unique_lock lock(*m_graphMutex);
                auto vertexSwitchOpt = findSwitchByDpidNoLock(switchDpidUint64);
                if (vertexSwitchOpt)
                {
                    auto& vprop = (*m_graph)[*vertexSwitchOpt];

                    // [Co-developed with claude code -- Adam]
                    // FINDINGS #46, and the only line of this fix that changes what the twin
                    // reports. This was an unconditional `isUp = true` with no else branch
                    // anywhere in the function, so the *only* thing a topology poll could ever
                    // say about a switch's power was "up" -- which made it not a liveness writer
                    // at all, but a one-way ratchet.
                    //
                    // Being listed by the control plane is not evidence that a switch is
                    // powered. The proxy went on listing a killed switch for D = 3.06 s after it
                    // died (round3 07_), so the reply this loop is applying can be, and measurably
                    // was, about a switch that is already gone. What makes that permanent rather
                    // than transient is the missing else: the next poll re-asserts it, and the
                    // one after that, for ever -- so one badly-timed power-off left the fabric
                    // with a dead process the twin called up, and #35's early-return then made
                    // the power API decline to fix it. 8 of 14 at the losing phase; the winning
                    // arm 0 of 4.
                    //
                    // The narrowest rule that closes it: discovery is still allowed to lift
                    // `isUp` -- it must be, since on a healthy fabric it is real evidence and a
                    // poll that never wrote up would leave the graph dark for anything the
                    // liveness worker answers Unknown about -- but it is not allowed to overrule
                    // a power-off the twin itself commanded and confirmed. Exactly the shape of
                    // the adminDisabled rule three lines below, arrived at the same way.
                    if (vprop.adminPoweredOff)
                    {
                        // Edge-triggered: see m_resurrectionDeclined. This says the twin is
                        // holding a state the control plane disagrees with, and which of the two
                        // it is believing -- the sentence nobody could read before, because the
                        // overwrite was silent.
                        if (m_resurrectionDeclined.insert(switchDpidUint64).second)
                        {
                            SPDLOG_LOGGER_WARN(
                                Logger::instance(),
                                "the control plane still lists switch {} (dpid {}), but a "
                                "power-off was commanded for it and confirmed, so this poll is "
                                "not marking it up. The control plane lists a stopped switch for "
                                "a few seconds after it dies, and for as long as it is configured "
                                "to know about it in a Mininet fabric. Power it on to clear this",
                                switchDpidStr,
                                switchDpidUint64);
                        }
                    }
                    else
                    {
                        vprop.isUp = true;
                    }

                    vprop.isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "Switch ({}) not found in static network topology file",
                                       switchDpidStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateHosts(const string& topologyData)
{
    // Update Vertex(Host) and Edge(Host to Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto hostsInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update hosts json: {}", hostsInfoJson.dump(4));

        for (const auto& host : hostsInfoJson)
        {
            // [Co-developed with claude code -- Adam]
            // contains() before operator[]: see updateLinks. On a const json a missing key is
            // undefined behaviour under NDEBUG, not a catchable exception.
            if (!host.contains("ipv4") || host["ipv4"].empty())
            {
                SPDLOG_LOGGER_DEBUG(Logger::instance(), "Skipping host with no IPv4 address");
                continue;
            }

            auto vecIpStr = host["ipv4"];
            // [Co-developed with claude code -- Adam]
            // Every parse below this line used to be a throwing one on data from another
            // process: macToUint64, ipStringToUint32 and hexStringToUint64 all raise
            // std::invalid_argument, which is not a json::exception, so a well-typed but
            // unparseable field escaped the catch at the end of this function and terminated
            // the kernel from the poll thread. The wrong-*type* case was already handled (that
            // throws json::type_error); the wrong-*value* case was not. Held in a named string
            // so the WARNs below do not have to touch host["mac"] again -- on a const json a
            // missing key is undefined behaviour, not an exception, so `host["mac"].dump()` in
            // an error path was its own crash waiting for an entry with no mac.
            const std::string macStr = host.value("mac", "");
            const auto hostMacOpt = utils::tryMacToUint64(macStr);
            if (!hostMacOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a hosts entry whose mac is not a MAC address: '{}'",
                                   macStr);
                continue;
            }
            auto vertexOpt = findVertexByMac(*hostMacOpt);
            if (vertexOpt)
            {
                unique_lock lock(*m_graphMutex);
                (*m_graph)[*vertexOpt].isUp = true;
                (*m_graph)[*vertexOpt].isEnabled = true;
            }
            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Host ({}) not found in static network topology file",
                                   macStr);
            }

            // [Co-developed with claude code -- Adam]
            // The type check is here because the *value* check below is not enough. `.get<>()` on
            // a non-string throws json::type_error, which the function-level catch does see -- but
            // seeing it means returning, so `"ipv4": [1234]` cost every host listed after it. The
            // commit that added the value guard claimed the individual parses were all guarded;
            // this was the one it missed, and an independent review of that claim found it.
            if (!vecIpStr[0].is_string())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring host {}: its ipv4[0] is {}, not a string",
                                   macStr,
                                   vecIpStr[0].type_name());
                continue;
            }
            std::string ipStr = vecIpStr[0].get<std::string>();
            const auto ipOpt = utils::tryIpStringToUint32(ipStr);
            if (!ipOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring host {}: its ipv4[0] '{}' is not an address",
                                   macStr,
                                   ipStr);
                continue;
            }
            const uint32_t ip = *ipOpt;

            // [Co-developed with claude code -- Adam]
            // doc/KNOWN-ISSUES.md F-4, first of two guards. A control plane learns a host from
            // traffic, and a switch's own management interface emits traffic, so this reply
            // contains entries whose "host" address belongs to a switch in our own topology.
            // Everything below keys on that address, and the two lookups it reaches -- both of
            // which match on IP alone -- then resolve to a **switch-to-switch** edge and set it
            // up. In StaticNetworkTopologyMininet_10Switches.json the very first edge is
            // 192.168.123.11 -> 192.168.123.15, so the entry for s1's management address
            // resurrects the s1-s5 link. Every poll, for the life of the process, which is how a
            // link an operator had marked down came back within one interval.
            //
            // Rejected here rather than only at the lookups because this is the one place that
            // can say *why*: an entry naming a switch is a misclassification upstream, and that
            // is worth a line an operator can act on. The per-lookup direction checks below stay
            // as well -- they are what makes the invariant hold for a route to this mistake
            // nobody has thought of yet.
            //
            // The MAC-keyed vertex update above is unaffected and deliberately left where it is:
            // a switch's MAC is not in the host vertex set, so it already finds nothing.
            if (findSwitchByIp(ip).has_value())
            {
                // Once per address, not once per poll: this reply repeats every 5 to 30 seconds
                // and neither control plane's host table forgets anything, so the condition is
                // permanent. See m_switchIpsOfferedAsHosts.
                if (m_switchIpsOfferedAsHosts.insert(ip).second)
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "ignoring hosts entries for {}: {} is a switch's management "
                                       "address in this topology, not a host. The control plane "
                                       "has learned a switch as a host; that switch's links are "
                                       "left to the links poll. Reported once per address",
                                       macStr,
                                       ipStr);
                }
                continue;
            }

            auto edgeOpt = findEdgeByHostIp(ip);

            // The far end must actually be a host. `findEdgeByHostIp` returns the first edge
            // whose srcIp list contains the address and checks nothing else, and hosts are the
            // vertices with no datapath id -- see findEdgeToHostByAgentIpAndPort, which has made
            // the same check since it was written. [Co-developed with claude code -- Adam]
            if (edgeOpt)
            {
                unique_lock lock(*m_graphMutex);
                if ((*m_graph)[*edgeOpt].srcDpid == 0)
                {
                    (*m_graph)[*edgeOpt].isUp = true;
                    (*m_graph)[*edgeOpt].isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "hosts entry {} ({}) matched edge {} -> {}, which leaves a "
                                       "switch rather than a host; not touching it",
                                       macStr,
                                       ipStr,
                                       (*m_graph)[*edgeOpt].srcDpid,
                                       (*m_graph)[*edgeOpt].dstDpid);
                }
            }
            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Edge (host {} {} {}) not found in static network topology file",
                                   macStr,
                                   ipStr,
                                   ip);
            }

            // The attachment port. `host["port"]["dpid"]` was two unchecked lookups on a const
            // json plus a throwing hex parse; Ryu sends all three, but this function's contract
            // is that a reply which does not costs the entry, not the process.
            if (!host.contains("port") || !host["port"].contains("dpid"))
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "host {} has no port.dpid; its switch-side edge is left as it "
                                   "was",
                                   macStr);
                continue;
            }
            const auto attachDpidOpt = utils::tryParseHexUint64(host["port"].value("dpid", ""));
            if (!attachDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "host {} reports attachment dpid '{}', which is not hex; its "
                                   "switch-side edge is left as it was",
                                   macStr,
                                   host["port"].value("dpid", ""));
                continue;
            }
            auto vertexOpt2 = findSwitchByDpid(*attachDpidOpt);
            if (vertexOpt2.has_value())
            {
                auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
                if (edgeRevOpt.has_value())
                {
                    unique_lock lock(*m_graphMutex);
                    // [Co-developed with claude code -- Adam]
                    // doc/KNOWN-ISSUES.md F-4, second guard, and the more direct of the two
                    // routes: findEdgeBySrcAndDstIp matches (srcIp, dstIp) with no regard for
                    // datapath ids, so when `ip` is a switch's management address and
                    // `vertexOpt2` is its neighbour, this pair *is* the switch-to-switch edge
                    // between them. A host's edge is the one whose far end has no dpid.
                    if ((*m_graph)[edgeRevOpt.value()].dstDpid == 0)
                    {
                        (*m_graph)[edgeRevOpt.value()].isUp = true;
                        (*m_graph)[edgeRevOpt.value()].isEnabled = true;
                    }
                    else
                    {
                        SPDLOG_LOGGER_WARN(
                            Logger::instance(),
                            "hosts entry {} ({}) matched reverse edge {} -> {}, whose far end is "
                            "a switch rather than a host; not touching it",
                            macStr,
                            ipStr,
                            (*m_graph)[edgeRevOpt.value()].srcDpid,
                            (*m_graph)[edgeRevOpt.value()].dstDpid);
                    }
                }
                else
                {
                    SPDLOG_LOGGER_WARN(
                        Logger::instance(),
                        "Rev Edge (host {}) not found in static network topology file",
                        macStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateLinks(const string& topologyData)
{
    // Update Edge(Switch to Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto linksInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update links json: {}", linksInfoJson.dump(4));

        for (const auto& link : linksInfoJson)
        {
            // [Co-developed with claude code -- Adam]
            // contains() before operator[]: on a *const* json, operator[] with a missing key is
            // undefined behaviour (the bounds check is a JSON_ASSERT, compiled out under NDEBUG),
            // so a link entry without "src" was not even an exception to catch.
            if (!link.contains("src") || !link.contains("dst"))
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a links entry with no src/dst endpoint");
                continue;
            }
            string srcDpidStr = link["src"].value("dpid", "");
            string srcPortStr = link["src"].value("port_no", "");
            string dstDpidStr = link["dst"].value("dpid", "");
            string dstPortStr = link["dst"].value("port_no", "");
            if (srcDpidStr.empty() || dstDpidStr.empty())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(), "Empty DPID");
                continue;
            }

            // Check if both switches exist in the graph
            // [Co-developed with claude code -- Adam]
            // tryParseHexUint64, not stoull: the empty case is guarded just above, but a
            // non-empty non-hex dpid still threw std::invalid_argument past every catch on the
            // way to the run() thread. See the same change in updateSwitches.
            const auto srcDpidOpt = utils::tryParseHexUint64(srcDpidStr);
            const auto dstDpidOpt = utils::tryParseHexUint64(dstDpidStr);
            if (!srcDpidOpt || !dstDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a links entry whose dpids are not hex strings: "
                                   "'{}' -> '{}'",
                                   srcDpidStr,
                                   dstDpidStr);
                continue;
            }
            uint64_t srcDpid = *srcDpidOpt;
            uint32_t srcPort = utils::portStringToUint(srcPortStr);
            uint64_t dstDpid = *dstDpidOpt;
            // uint64_t dstPort = utils::portStringToUint(dstPortStr);

            auto srcVertexOpt = findSwitchByDpid(srcDpid);
            auto dstVertexOpt = findSwitchByDpid(dstDpid);

            if (!srcVertexOpt.has_value() or !dstVertexOpt.has_value())
            {
                // [Co-developed with claude code -- Adam]
                // `continue`, not `return`. A link naming a switch the static topology does not
                // contain is one unusable entry, not a reason to abandon the reply -- and this
                // one is persistent rather than transient: the control plane sends the same list
                // every poll, so every link *after* the offender stayed at whatever state it was
                // last given, indefinitely. That is the failure this whole ingest was hardened
                // against, still present in the one branch that used a bare return.
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a link whose endpoints are not both in the static "
                                   "topology: {} -> {}",
                                   srcDpidStr,
                                   dstDpidStr);
                continue;
            }

            {
                unique_lock lock(*m_graphMutex);
                auto srcVertex = *srcVertexOpt;
                // ==============================================
                // auto dstVertex = *dstVertexOpt;
                // auto [e, added] = boost::add_edge(srcVertex, dstVertex, *m_graph);
                // if (added)
                // {
                //     (*m_graph)[e].isUp = true;
                //     (*m_graph)[e].srcDpid = (*m_graph)[srcVertex].dpid;
                //     (*m_graph)[e].srcIp = (*m_graph)[srcVertex].ip;
                //     (*m_graph)[e].srcInterface = srcPort;
                //     (*m_graph)[e].dstDpid = (*m_graph)[dstVertex].dpid;
                //     (*m_graph)[e].dstIp = (*m_graph)[dstVertex].ip;
                //     (*m_graph)[e].dstInterface = dstPort;
                //     (*m_graph)[e].linkBandwidth = 1000000000;
                // }
                // ==============================================

                // Update link isUp status
                auto edgeOpt = findEdgeByDpidAndPortNoLock({(*m_graph)[srcVertex].dpid, srcPort});

                if (edgeOpt.has_value())
                {
                    (*m_graph)[edgeOpt.value()].isUp = true;
                    (*m_graph)[edgeOpt.value()].isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(
                        Logger::instance(),
                        "Link (dpid {} port {}) not found in static network topology file",
                        srcDpidStr,
                        srcPortStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateGraph(const string& switchesStr,
                                    const string& hostsStr,
                                    const string& linksStr)
{
    updateSwitches(switchesStr);
    updateHosts(hostsStr);
    updateLinks(linksStr);
    // Last, so it has the final word within a pass. The three writers above will happily set a
    // dead switch's host-facing edge back up every poll -- the control planes' host tables are
    // append-only, so they keep reporting a host that has been unreachable for an hour -- and
    // this is what puts it back. Ordering, not idempotence, is what makes that correct.
    // [Co-developed with claude code -- Adam]
    reconcileDerivedLiveness();
    // DEBUG, not INFO, matching logGraph() below. Unconditional and content-free: it says a poll
    // ran, not that anything changed. run()'s poll loop already prints one line when the up-counts
    // actually move, which is the version worth keeping. [Co-developed with claude code -- Adam]
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "\033[1;32mTopology Update From REST\033[0m");
    logGraph();
}

/** @brief See the header for what this does not do and why. [Co-developed with claude code -- Adam]
 */
void
TopologyAndFlowMonitor::reconcileDerivedLiveness()
{
    std::unique_lock lock(*m_graphMutex);

    // Pass 1: which switches have been unusable for long enough to isolate what they carry.
    //
    // isUsable, not isUp: a switch an operator has taken out of service, or one the control plane
    // cannot drive, carries no traffic either. That is the same intersection the six other
    // availability checks in this process take, and taking a different one here is exactly how
    // getAvgLinkUsage ended up counting links nobody could use.
    std::set<Graph::vertex_descriptor> isolating;
    for (auto v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        const auto& vp = (*m_graph)[v];
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }

        if (isUsable(vp))
        {
            m_switchUnusablePolls.erase(vp.dpid);
            continue;
        }

        const unsigned misses = ++m_switchUnusablePolls[vp.dpid];
        if (misses >= kMissesBeforeIsolating)
        {
            isolating.insert(v);
        }
    }

    // Counted rather than logged per object: isolating one switch moves a dozen edges and a
    // handful of hosts, and one line each is how the two 1 Hz INFO lines in this process reached
    // 138,000 lines a day. Edge-triggered on the reason field, so a wedge that persists for an
    // hour is one line, not one per poll -- the same shape as m_topologyFetchFailures.
    std::size_t edgesTakenDown = 0;
    std::size_t edgesReleased = 0;
    std::size_t hostsTakenDown = 0;
    std::size_t hostsReleased = 0;

    // Pass 2: edges. An edge with an isolating switch at either end cannot carry traffic --
    // including the host-facing ones, which is doc/KNOWN-ISSUES.md F-16: the only other writer of
    // edge-down is /ndt/link_failed, and that is keyed on a pair of dpids, so a host's edge (dpid
    // 0 at one end) was not addressable by it at all.
    for (auto e : boost::make_iterator_range(boost::edges(*m_graph)))
    {
        auto& ep = (*m_graph)[e];
        const bool cut = isolating.count(boost::source(e, *m_graph)) != 0 ||
                         isolating.count(boost::target(e, *m_graph)) != 0;

        if (cut)
        {
            if (ep.downReason != DownReason::SwitchUnreachable)
            {
                ++edgesTakenDown;
            }
            ep.isUp = false;
            ep.downReason = DownReason::SwitchUnreachable;
        }
        else if (ep.downReason == DownReason::SwitchUnreachable)
        {
            // Release, do not raise. Whether this edge is up again is discovery's call, and
            // discovery has evidence; this function has only the absence of a reason to keep it
            // down. It will read up on this same poll if updateLinks/updateHosts already said so,
            // and stay down until they do if they did not.
            ep.downReason = DownReason::None;
            ++edgesReleased;
        }
    }

    // Pass 3: hosts. doc/KNOWN-ISSUES.md F-14. A host is unreachable when every switch it attaches
    // to is isolating -- "every", not "any", so a dual-homed host in a future topology does not go
    // down because one of its two switches did.
    //
    // Attachment is read off the graph's own edges rather than from the control plane's
    // `port.dpid`, because that is the relation the twin can still evaluate when the control plane
    // has stopped mentioning the switch at all.
    for (auto v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        auto& vp = (*m_graph)[v];
        if (vp.vertexType != VertexType::HOST)
        {
            continue;
        }

        std::size_t attachments = 0;
        std::size_t isolatedAttachments = 0;
        for (auto e : boost::make_iterator_range(boost::out_edges(v, *m_graph)))
        {
            const auto peer = boost::target(e, *m_graph);
            if ((*m_graph)[peer].vertexType != VertexType::SWITCH)
            {
                continue;
            }
            ++attachments;
            if (isolating.count(peer) != 0)
            {
                ++isolatedAttachments;
            }
        }

        // attachments == 0 is a host the topology file left dangling. It has no switch whose
        // state could be derived from, so nothing is claimed about it -- saying "down" there
        // would be asserting a fact about a machine on the strength of our own file being
        // incomplete.
        if (attachments > 0 && isolatedAttachments == attachments)
        {
            if (vp.downReason != DownReason::SwitchUnreachable)
            {
                ++hostsTakenDown;
            }
            vp.isUp = false;
            vp.downReason = DownReason::SwitchUnreachable;
        }
        else if (vp.downReason == DownReason::SwitchUnreachable)
        {
            vp.downReason = DownReason::None;
            ++hostsReleased;
        }
    }

    if (edgesTakenDown != 0 || hostsTakenDown != 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} switch(es) unusable for {}+ polls: {} edge(s) and {} host(s) moved "
                           "to down with down_reason=switch-unreachable. These are derived, not "
                           "probed: nothing asked the hosts anything, and they are reported down "
                           "because the only switch they reach the fabric through is not there",
                           isolating.size(),
                           kMissesBeforeIsolating,
                           edgesTakenDown,
                           hostsTakenDown);
    }
    if (edgesReleased != 0 || hostsReleased != 0)
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "{} edge(s) and {} host(s) no longer isolated by an unusable switch; "
                           "their down_reason is cleared and discovery decides whether they are "
                           "up",
                           edgesReleased,
                           hostsReleased);
    }
}

void
TopologyAndFlowMonitor::logGraph()
{
    constexpr char RESET[] = "\033[0m";
    constexpr char COLOR_SWITCH[] = "\033[1;34m"; // Bold blue
    constexpr char COLOR_HOST[] = "\033[1;32m";   // Bold green
    constexpr char COLOR_EDGE[] = "\033[1;37m";   // Bold white

    std::shared_lock lock(*m_graphMutex);

    std::vector<Graph::vertex_descriptor> verts;
    verts.reserve(boost::num_vertices(*m_graph));
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        verts.push_back(*vi);
    }

    std::sort(verts.begin(), verts.end(), [&](auto a, auto b) {
        return (*m_graph)[a].ip < (*m_graph)[b].ip;
    });

    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                        "{}=== Vertices ({}) ==={}",
                        COLOR_EDGE,
                        verts.size(),
                        RESET);

    for (auto v : verts)
    {
        const auto& P = (*m_graph)[v];
        const char* col = (P.vertexType == VertexType::SWITCH ? COLOR_SWITCH : COLOR_HOST);
        const char* tag = (P.vertexType == VertexType::SWITCH ? "[SWITCH]" : "[HOST]");

        auto ips = utils::ipToString(P.ip);
        std::ostringstream oss;
        for (size_t i = 0; i < ips.size(); ++i)
        {
            if (i)
            {
                oss << ", ";
            }
            oss << ips[i];
        }

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "{}{}{} IPs: {} | DPID: {}",
                            col,
                            tag,
                            RESET,
                            oss.str(),
                            P.dpid);
    }

    std::vector<Graph::edge_descriptor> eds;
    eds.reserve(boost::num_edges(*m_graph));
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        eds.push_back(*ei);
    }

    std::sort(eds.begin(), eds.end(), [&](auto a, auto b) {
        return (*m_graph)[a].dstIp < (*m_graph)[b].dstIp;
    });

    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                        "\n{}=== Edges ({}) ==={}",
                        COLOR_EDGE,
                        eds.size(),
                        RESET);

    for (auto e : eds)
    {
        const auto& E = (*m_graph)[e];
        auto srcIps = utils::ipToString(E.srcIp);
        std::ostringstream ossS;
        for (size_t i = 0; i < srcIps.size(); ++i)
        {
            if (i)
            {
                ossS << ", ";
            }
            ossS << srcIps[i];
        }
        auto dstIps = utils::ipToString(E.dstIp);
        std::ostringstream ossD;
        for (size_t i = 0; i < dstIps.size(); ++i)
        {
            if (i)
            {
                ossD << ", ";
            }
            ossD << dstIps[i];
        }

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "{}[EDGE]{} {} (DPID:{}, port:{})  ->  {} (DPID:{}, port:{})",
                            COLOR_EDGE,
                            RESET,
                            ossS.str(),
                            E.srcDpid,
                            E.srcInterface,
                            ossD.str(),
                            E.dstDpid,
                            E.dstInterface);
    }
}

// TODO[OPTIMIZE] Granuality Lock (Need to Carefully Check SflowCollector)
void
TopologyAndFlowMonitor::updateLinkInfo(pair<uint32_t, uint32_t> agentIpAndPort,
                                       uint64_t leftIn,
                                       uint64_t leftOut,
                                       uint64_t interfaceSpeed)
{
    auto edgeOpt = findEdgeByAgentIpAndPort(agentIpAndPort);
    if (!edgeOpt.has_value())
    {
        // SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        // SPDLOG_LOGGER_ERROR(Logger::instance(),
        //                     "Agent_ip: {}, port: {}",
        //                     utils::ipToString(agentIpAndPort.first),
        //                     agentIpAndPort.second);
        return;
    }

    auto edge = edgeOpt.value();
    auto& edgeProps = (*m_graph)[edge];

    // [Co-developed with claude code -- Adam]
    // FINDINGS #88. EdgeProperties::dstIp is a vector that starts empty, and nothing on the
    // load path checks it -- validateStaticTopologyJson only looks at an edge end whose dpid
    // is 0. Without it there is no reverse-edge key to build.
    //
    // Through KeyedFailureLog, not a bare WARN, and for the reason the reverse-edge guard
    // below states at length: this runs once per telemetry sample, so a per-call WARN is how
    // this process once reached 138,000 log lines a day -- while the condition itself is
    // structural and permanent, so DEBUG would convert it into permanent silence.
    if (edgeProps.dstIp.empty())
    {
        reverseEdgeFailures().record(
            utils::ipToString(agentIpAndPort.first) + ":" +
                std::to_string(agentIpAndPort.second),
            "this edge carries no destination address, so its reverse edge cannot be keyed; "
            "per-edge flow bookkeeping for this sample is skipped");
        return;
    }
    auto revEdgeAgentIpAndPort = make_pair(edgeProps.dstIp.front(), edgeProps.dstInterface);
    auto revEdgeOpt = findEdgeByAgentIpAndPort(revEdgeAgentIpAndPort);

    if (!revEdgeOpt)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        return;
    }

    auto revEdge = *revEdgeOpt;
    auto& revEdgeProps = (*m_graph)[revEdge];

    // Edge: from src (agent) to dst
    edgeProps.leftBandwidth = leftOut; // TX side: how much unused bandwidth remains
    edgeProps.linkBandwidthUtilization = (1.0 - (double)leftOut / interfaceSpeed) * 100;
    edgeProps.linkBandwidthUsage = interfaceSpeed - leftOut;
    edgeProps.linkBandwidth = interfaceSpeed;
    // [Co-developed with claude code -- Adam]
    // F-8. interfaceSpeed here is the speed the switch itself reported in the sFlow counter
    // sample, and leftOut/leftIn are deltas of its octet counters, so this figure really was
    // observed -- unlike the loader's, which only repeats the topology file.
    edgeProps.leftBandwidthSource = BandwidthSource::Measured;

    // Reverse Edge: from dst to src
    revEdgeProps.leftBandwidth = leftIn; // RX side
    revEdgeProps.linkBandwidthUtilization = (1.0 - (double)leftIn / interfaceSpeed) * 100;
    revEdgeProps.linkBandwidthUsage = interfaceSpeed - leftIn;
    revEdgeProps.linkBandwidth = interfaceSpeed;
    revEdgeProps.leftBandwidthSource = BandwidthSource::Measured;
}

void
TopologyAndFlowMonitor::updateLinkInfoLeftLinkBandwidth(
    std::pair<uint32_t, uint32_t> agentIpAndPort,
    uint64_t accumulatedBytes,
    double elapsedSeconds)
{
    // [Co-developed with claude code -- Adam]
    // A non-positive interval cannot produce a rate. Publishing anything here -- 0, the
    // undivided byte count, a clamped interval -- puts a number on an edge that looks exactly
    // like a measurement, and the reader has no way to tell it apart from a real one. Refuse,
    // say so, and leave the edge holding its previous value, which at least IS a measurement.
    if (!(elapsedSeconds > 0.0))
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "rate update skipped: elapsed interval {} s is not positive, so "
                            "{} bytes cannot be converted to a rate. Edge left unchanged.",
                            elapsedSeconds,
                            accumulatedBytes);
        return;
    }
    m_lastRateDivisorSeconds.store(elapsedSeconds);

    // The whole point of ticket Q: this division did not exist. The accumulator was handed on as
    // `bytes * 8` and consumed as bits-per-second, which is only correct when the interval is
    // exactly one second -- and the rate loop sleeps a full second and then runs its body.
    const uint64_t estimatedIn =
        static_cast<uint64_t>(static_cast<double>(accumulatedBytes) * 8.0 / elapsedSeconds);

    auto edgeOpt = findEdgeByAgentIpAndPort(agentIpAndPort);
    if (!edgeOpt.has_value())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Agent_ip: {}, port: {}",
                            utils::ipToString(agentIpAndPort.first),
                            agentIpAndPort.second);
        return;
    }

    auto edge = edgeOpt.value();

    {
        std::unique_lock lock(*m_graphMutex);

        auto& edgeProps = (*m_graph)[edge];

        uint64_t leftIn =
            estimatedIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - estimatedIn;
        edgeProps.leftBandwidthFromFlowSample = leftIn;
        // [Co-developed with claude code -- Adam]
        // F-8. Past this line the figure is derived from sampled bytes over a measured interval,
        // so it stops being the topology file's claim and becomes an observation. This is the
        // only place in MININET mode where that transition happens, which is why an edge that
        // never carries traffic stays Declared indefinitely -- correctly, and now visibly.
        edgeProps.leftBandwidthSource = BandwidthSource::Measured;
        edgeProps.linkBandwidthUtilization = (1.0 - (double)leftIn / edgeProps.linkBandwidth) * 100;
        edgeProps.linkBandwidthUsage =
            leftIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - leftIn;

        SPDLOG_LOGGER_TRACE(
            Logger::instance(),
            "leftBandwidthFromFlowSample {}, linkBandwidthUtilization {}, linkBandwidthUsage {}",
            edgeProps.leftBandwidthFromFlowSample,
            edgeProps.linkBandwidthUtilization,
            edgeProps.linkBandwidthUsage);
    }
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByDpid(uint64_t dpid) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH && (*m_graph)[*vi].dpid == dpid)
        {
            return *vi;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
std::optional<SwitchKind>
TopologyAndFlowMonitor::getSwitchKind(uint64_t dpid) const
{
    std::shared_lock lock(m_switchKindMutex);
    auto it = m_dpidToSwitchKind.find(dpid);
    if (it == m_dpidToSwitchKind.end())
    {
        return nullopt;
    }
    return it->second;
}

// [Co-developed with claude code -- Adam]
std::map<SwitchKind, std::vector<uint64_t>>
TopologyAndFlowMonitor::getSwitchKindGroups() const
{
    std::map<SwitchKind, std::vector<uint64_t>> groups;
    {
        std::shared_lock lock(m_switchKindMutex);
        for (const auto& [dpid, kind] : m_dpidToSwitchKind)
        {
            groups[kind].push_back(dpid);
        }
    }
    for (auto& [kind, dpids] : groups)
    {
        (void)kind;
        std::sort(dpids.begin(), dpids.end());
    }
    return groups;
}

// [Co-developed with claude code -- Adam]
bool
TopologyAndFlowMonitor::validateDataPlaneHomogeneity(bool allowMixed) const
{
    const auto groups = getSwitchKindGroups();

    if (groups.empty())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Topology contains no switches; nothing can be controlled");
        return false;
    }

    if (groups.size() == 1)
    {
        const auto& [kind, dpids] = *groups.begin();
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "Data plane: {} ({} switch(es))",
                           switchKindToString(kind),
                           dpids.size());
        return true;
    }

    std::ostringstream detail;
    bool first = true;
    for (const auto& [kind, dpids] : groups)
    {
        if (!first)
        {
            detail << "; ";
        }
        first = false;
        detail << switchKindToString(kind) << "=[";
        for (size_t i = 0; i < dpids.size(); ++i)
        {
            detail << (i ? "," : "") << dpids[i];
        }
        detail << "]";
    }

    if (allowMixed)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Topology mixes data planes ({}). Proceeding because mixed "
                           "operation was explicitly allowed; telemetry and liveness are "
                           "not validated for this configuration.",
                           detail.str());
        return true;
    }

    SPDLOG_LOGGER_ERROR(Logger::instance(),
                        "Topology mixes data planes ({}). A single run must be all-OVS or "
                        "all-BMv2: the flow dispatch is per-DPID and would cope, but the "
                        "telemetry and liveness paths assume one kind. Fix the topology "
                        "file, or set AppConfig::ALLOW_MIXED_DATAPLANE to override.",
                        detail.str());
    return false;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByDpidNoLock(uint64_t dpid) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH && (*m_graph)[*vi].dpid == dpid)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMac(uint64_t mac) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].mac == mac)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMacNoLock(uint64_t mac) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].mac == mac)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMininetBridgeName(const std::string& mininetBridgeName) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].bridgeNameForMininet == mininetBridgeName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMininetBridgeNameNoLock(
    const std::string& mininetBridgeName) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].bridgeNameForMininet == mininetBridgeName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByDeviceName(const std::string& deviceName) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].deviceName == deviceName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByDeviceNameNoLock(const std::string& deviceName) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].deviceName == deviceName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeToHostByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            // dstDpid == 0 is how the topology loader marks a non-switch endpoint: hosts are
            // the only vertices without a datapath id (see the dstDpid != 0 branch where edges
            // are loaded). A switch far end means a sampler exists over there and owns the
            // edge's accounting; a host far end has no sampler at all.
            if (props.dstDpid == 0)
            {
                return edge;
            }
            return nullopt;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByAgentIpAndPortNoLock(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            auto sourceNode = boost::source(edge, *m_graph);
            auto targetNode = boost::target(edge, *m_graph);
            // [Co-developed with claude code -- Adam]
            // `.second` is the found flag, and dropping it turned a miss into a hit: a singular
            // edge_descriptor wrapped in an *engaged* optional, which every caller then treats
            // as a real edge. FlowLinkUsageCollector writes through this one on the sFlow
            // ingest path (touchEdgeFlow), so a graph holding only the forward direction of a
            // link -- reachable, which is why 7f738e6 exists to report half-processed link
            // transitions -- had per-edge flow bookkeeping running on an invalid descriptor.
            // No sanitizer flags an unchecked `.second`; it is a dropped error flag, not a race.
            //
            // Reported through KeyedFailureLog, not at DEBUG. The first version of this used
            // DEBUG on the reasoning that a per-sample WARN is how this process once reached
            // 138,000 log lines a day -- true, but the wrong conclusion, and an independent
            // review caught it: a missing reverse edge is a *persistent structural* condition,
            // not a per-sample transient. DEBUG does not thin a flood there, it converts a
            // permanent condition into permanent silence, because LogConfig defaults to info and
            // the running kernel passes no level flag. The graph would stay asymmetric and the
            // one place that notices would say nothing -- which is the state this guard exists
            // to surface. KeyedFailureLog is the instrument this repo already built for exactly
            // that shape, and FlowLinkUsageCollector -- the caller on this path -- already uses
            // it: first occurrence per key, recovery, nothing in between.
            const auto reverse = boost::edge(targetNode, sourceNode, *m_graph);
            if (!reverse.second)
            {
                reverseEdgeFailures().record(
                    utils::ipToString(agentIpAndPort.first) + ":" +
                        std::to_string(agentIpAndPort.second),
                    "no reverse edge for this agent and port; the graph holds only one direction "
                    "of the link, so per-edge flow bookkeeping for it is skipped");
                return nullopt;
            }
            return reverse.first;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            auto sourceNode = boost::source(edge, *m_graph);
            auto targetNode = boost::target(edge, *m_graph);
            // [Co-developed with claude code -- Adam]
            // `.second` is the found flag, and dropping it turned a miss into a hit: a singular
            // edge_descriptor wrapped in an *engaged* optional, which every caller then treats
            // as a real edge. FlowLinkUsageCollector writes through this one on the sFlow
            // ingest path (touchEdgeFlow), so a graph holding only the forward direction of a
            // link -- reachable, which is why 7f738e6 exists to report half-processed link
            // transitions -- had per-edge flow bookkeeping running on an invalid descriptor.
            // No sanitizer flags an unchecked `.second`; it is a dropped error flag, not a race.
            //
            // Reported through KeyedFailureLog, not at DEBUG. The first version of this used
            // DEBUG on the reasoning that a per-sample WARN is how this process once reached
            // 138,000 log lines a day -- true, but the wrong conclusion, and an independent
            // review caught it: a missing reverse edge is a *persistent structural* condition,
            // not a per-sample transient. DEBUG does not thin a flood there, it converts a
            // permanent condition into permanent silence, because LogConfig defaults to info and
            // the running kernel passes no level flag. The graph would stay asymmetric and the
            // one place that notices would say nothing -- which is the state this guard exists
            // to surface. KeyedFailureLog is the instrument this repo already built for exactly
            // that shape, and FlowLinkUsageCollector -- the caller on this path -- already uses
            // it: first occurrence per key, recovery, nothing in between.
            const auto reverse = boost::edge(targetNode, sourceNode, *m_graph);
            if (!reverse.second)
            {
                reverseEdgeFailures().record(
                    utils::ipToString(agentIpAndPort.first) + ":" +
                        std::to_string(agentIpAndPort.second),
                    "no reverse edge for this agent and port; the graph holds only one direction "
                    "of the link, so per-edge flow bookkeeping for it is skipped");
                return nullopt;
            }
            return reverse.first;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByAgentIpAndPortNoLock(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.srcIp.empty() and props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

std::optional<std::pair<uint32_t, uint32_t>>
TopologyAndFlowMonitor::getAgentKeyFromTheOtherSide(
    const std::pair<uint32_t, uint32_t>& agentIpAndPort) const

{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.dstIp.empty() and props.dstIp.front() == agentIpAndPort.first and
            props.dstInterface == agentIpAndPort.second)
        {
            // FINDINGS #88. The far side asked for is this edge's, but this edge carries no
            // source address to answer with. nullopt is what "no key" already means to
            // every caller here; a fabricated one would be used as an agent key.
            if (props.srcIp.empty())
            {
                return nullopt;
            }
            return make_pair(props.srcIp.front(), props.srcInterface);
        }
    }
    return nullopt;
}

std::optional<std::pair<uint32_t, uint32_t>>
TopologyAndFlowMonitor::getAgentKeyFromTheOtherSideNoLock(
    const std::pair<uint32_t, uint32_t>& agentIpAndPort) const

{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (!props.dstIp.empty() and props.dstIp.front() == agentIpAndPort.first and
            props.dstInterface == agentIpAndPort.second)
        {
            // FINDINGS #88. The far side asked for is this edge's, but this edge carries no
            // source address to answer with. nullopt is what "no key" already means to
            // every caller here; a fabricated one would be used as an agent key.
            if (props.srcIp.empty())
            {
                return nullopt;
            }
            return make_pair(props.srcIp.front(), props.srcInterface);
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByDpidAndPort(pair<uint64_t, uint32_t> dpid_and_port) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == dpid_and_port.first && eprop.srcInterface == dpid_and_port.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByDpidAndPortNoLock(pair<uint64_t, uint32_t> dpid_and_port) const
{
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == dpid_and_port.first && eprop.srcInterface == dpid_and_port.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid(
    pair<uint64_t, uint64_t> src_dpid_and_dst_dpid) const
{
    std::shared_lock lock(*m_graphMutex);
    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "Enter TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid");
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == src_dpid_and_dst_dpid.first &&
            eprop.dstDpid == src_dpid_and_dst_dpid.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstDpidNoLock(
    pair<uint64_t, uint64_t> src_dpid_and_dst_dpid) const
{
    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "Enter TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid");
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == src_dpid_and_dst_dpid.first &&
            eprop.dstDpid == src_dpid_and_dst_dpid.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIp(uint32_t hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.srcIp.begin(), props.srcIp.end(), hostIp) != props.srcIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByHostIp(uint32_t hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.dstIp.begin(), props.dstIp.end(), hostIp) != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIpNoLock(uint32_t hostIp) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.srcIp.begin(), props.srcIp.end(), hostIp) != props.srcIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIp(vector<uint32_t> hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByHostIp(vector<uint32_t> hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.dstIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIpNoLock(vector<uint32_t> hostIp) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstIp(uint32_t src_ip, uint32_t dst_ip) const
{
    std::shared_lock lock(*m_graphMutex);
    for (const auto& edge : boost::make_iterator_range(boost::edges(*m_graph)))
    {
        const auto& props = (*m_graph)[edge];
        auto itSrc = find(props.srcIp.begin(), props.srcIp.end(), src_ip);
        auto itDst = find(props.dstIp.begin(), props.dstIp.end(), dst_ip);
        if (itSrc != props.srcIp.end() && itDst != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstIpNoLock(uint32_t src_ip, uint32_t dst_ip) const
{
    for (const auto& edge : boost::make_iterator_range(boost::edges(*m_graph)))
    {
        const auto& props = (*m_graph)[edge];
        auto itSrc = find(props.srcIp.begin(), props.srcIp.end(), src_ip);
        auto itDst = find(props.dstIp.begin(), props.dstIp.end(), dst_ip);
        if (itSrc != props.srcIp.end() && itDst != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

void
TopologyAndFlowMonitor::setEdgeDown(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDown {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeDownNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDownNoLock {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeUp(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isUp = true;
    // The reason describes why this is down; something has just declared it up, so carrying the
    // reason forward would publish `is_up: true, down_reason: "switch-unreachable"`, which is a
    // contradiction a consumer has no way to resolve. reconcileDerivedLiveness re-derives it on
    // the next poll if it still holds. [Co-developed with claude code -- Adam]
    (*m_graph)[e].downReason = DownReason::None;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeUp {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeUpNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isUp = true;
    /// @see setEdgeUp for why the reason is cleared here.
    (*m_graph)[e].downReason = DownReason::None;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeUpNoLock {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeEnable(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isEnabled = true;
}

void
TopologyAndFlowMonitor::setEdgeEnableNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isEnabled = true;
}

void
TopologyAndFlowMonitor::setEdgeDisable(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isEnabled = false;
}

void
TopologyAndFlowMonitor::setEdgeDisableNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isEnabled = false;
}

pair<uint64_t, uint32_t>
TopologyAndFlowMonitor::getEdgeStats(Graph::edge_descriptor e) const
{
    std::shared_lock lock(*m_graphMutex);
    const auto& edgeProps = (*m_graph)[e];
    return {m_mode == utils::MININET ? edgeProps.leftBandwidthFromFlowSample
                                     : edgeProps.leftBandwidth,
            edgeProps.flowSet.size()};
}

pair<uint64_t, uint32_t>
TopologyAndFlowMonitor::getEdgeStatsNoLock(Graph::edge_descriptor e) const
{
    const auto& edgeProps = (*m_graph)[e];
    return {m_mode == utils::MININET ? edgeProps.leftBandwidthFromFlowSample
                                     : edgeProps.leftBandwidth,
            edgeProps.flowSet.size()};
}


std::set<sflow::FlowKey>
TopologyAndFlowMonitor::getEdgeFlowSet(Graph::edge_descriptor e) const
{
    std::shared_lock<std::shared_mutex> lock(*m_graphMutex);
    std::set<sflow::FlowKey> out;
    const auto& mp = (*m_graph)[e].flowSet; // unordered_map<FlowKey, TimePoint>
    for (const auto& kv : mp)
    {
        out.insert(kv.first);
    }
    return out;
}

std::set<sflow::FlowKey>
TopologyAndFlowMonitor::getEdgeFlowSetNoLock(Graph::edge_descriptor e) const
{
    std::set<sflow::FlowKey> out;
    const auto& mp = (*m_graph)[e].flowSet; // unordered_map<FlowKey, TimePoint>
    for (const auto& kv : mp)
    {
        out.insert(kv.first);
    }
    return out;
}

Graph
TopologyAndFlowMonitor::getGraph() const
{
    std::shared_lock lock(*m_graphMutex);
    return *m_graph;
}

// [Co-developed with claude code -- Adam]
// W10, 2026-09-06. THE KERNEL DOES NOT WRITE THE MODEL FILE. Not "writes it tidily" -- does
// not write it. The names an operator sets go to an overlay outside setting/, and the overlay
// is laid back over the graph at load. The two functions below are what used to write it, and
// the history matters because it is the reason a smaller fix is not available:
//
//   OV-1, 2026-09-04. Both setters read setting/<model>.json into an `nlohmann::json`, changed
//   one string, and wrote the whole document back. nlohmann::json's default ObjectType is
//   std::map, so every object came back out in dictionary order and one POST
//   /ndt/modify_nickname produced a 3998-insertion / 3998-deletion diff on a file the
//   repository tracks, with the JSON semantically unchanged (measured twice that night, once
//   per data plane -- it follows activeTopologyPath(), not a plane). That was fixed by
//   preserving the document's order, its indent and its trailing newline: the diff became one
//   line.
//
//   One line is still one line. `ndt status --check` compares the model file's sha256 against
//   the one the `ndt up` that loaded it recorded (tools/test_workflow/ndt:2239-2255), and a
//   sha256 does not count lines. Measured 2026-09-05 on a live OVS fabric: one nickname change,
//   a two-line diff, and `ndt status --check` rc=1 -- "the topology file has been edited since
//   the ndt up that loaded it". Two controls in the same run pinned that this was the check
//   WORKING: renaming and renaming back left the file byte-identical and the check green, and
//   an unrelated writer earned the identical sentence. So "the rename touches one line" and
//   "--check stays green" were never both reachable while this process wrote that file at all.
//
// Adam's decision, 2026-09-05 18:1x: an overlay outside setting/, `--check` does not look at
// it, the kernel lays it on at startup, and the model files are from now on read-only to this
// process. That also ends the older complaint underneath OV-1 -- the kernel dirtying a tracked
// file in a worktree several sessions share.
//
// 🔴 What the overlay is keyed by, and why it is NOT the flat {"<dpid>": "<nickname>"} map the
// ticket suggested. EVERY host node in EVERY shipped topology carries "dpid": 0 (checked
// 2026-09-06 across setting/StaticNetworkTopology*.json), and hosts are reachable here:
// modify_nickname takes identifier.type "mac" and "name" as well as "dpid". A flat dpid map
// collapses all four hosts of an ovs4 fabric onto the key "0", so renaming one host would
// rename every host at the next start. The overlay therefore keys the way these two setters
// already match vertices -- switches by dpid, hosts by mac -- in two separate sections.
//
// 🔴 And why one overlay PER MODEL FILE rather than one for the checkout: dpids 1-10 exist in
// both the OVS and the P4 topology. That exact collision is what the comment above
// activeTopologyPath() records as having written a P4 run's rename into the OVS topology. A
// single shared overlay would rebuild it one layer up.

/// The overlay's directory, relative to the working directory the kernel was started in --
/// the same place `ndt` keeps up.target, lab.claim and the pid ledger. Three reasons it is
/// here rather than beside the model: .gitignore already ignores `.test_run/` (line 21), so a
/// rename can never dirty the repository again, which is the whole point of W10; it is
/// per-checkout, exactly like the `ndt up` baseline the names are only meaningful against;
/// and `ndt clean` asserts about processes, the tmux session, the switch manifest and ports,
/// and does not enumerate .test_run/ at all, so a file that persists here is not debris to it
/// (read at tools/test_workflow/ndt, cmd_clean, 2026-09-06).
static constexpr const char* kNameOverlayDir = ".test_run/nickname_overlay";

/// The directory the shipped models live in, and the one nicknameOverlayPath() climbs out of to
/// find the checkout. Named rather than spelled inline because it is the same directory
/// `ndt status --check` hashes and the one this overlay exists to stay out of.
static constexpr const char* kShippedTopologyDirName = "setting";

/// Written so that a later format change is DETECTED rather than misread. A document that
/// declares a version this build does not know is refused, not guessed at.
static constexpr int kNameOverlayVersion = 1;
static constexpr const char* kOverlayVersionKey = "version";
static constexpr const char* kOverlayTopologyKey = "topology";
static constexpr const char* kOverlaySwitchesKey = "switches";
static constexpr const char* kOverlayHostsKey = "hosts";
static constexpr const char* kOverlayNicknameKey = "nickname";
static constexpr const char* kOverlayDeviceNameKey = "device_name";

/// Reads a JSON document, with the path in every failure message. nlohmann's own parse errors
/// name a byte offset and nothing else, which is not enough to find the file in a tree that
/// has one overlay per model.
static nlohmann::json
readJsonFile(const std::string& path)
{
    std::ifstream ifs(path);
    if (!ifs.is_open())
    {
        throw std::runtime_error("cannot open \"" + path + "\"");
    }
    std::ostringstream text;
    text << ifs.rdbuf();
    return nlohmann::json::parse(text.str());
}

/// Writes to a temp file beside the target and renames, so no reader -- including the next
/// start of this kernel -- ever sees a half-written overlay. Same construction the topology
/// writer used before W10 removed it; the hazard is the same and the file is now smaller, not
/// safer.
static void
writeJsonFileAtomically(const std::string& path, const nlohmann::json& doc)
{
    const std::filesystem::path target(path);
    if (target.has_parent_path() && !target.parent_path().empty())
    {
        std::error_code ec;
        std::filesystem::create_directories(target.parent_path(), ec);
        if (ec)
        {
            throw std::runtime_error("cannot create \"" + target.parent_path().string() +
                                     "\": " + ec.message());
        }
    }

    const std::string tmp = path + ".tmp";
    {
        std::ofstream ofs(tmp);
        if (!ofs.is_open())
        {
            throw std::runtime_error("cannot open \"" + tmp + "\" to write the overlay");
        }
        ofs << std::setw(2) << doc << "\n";
    }
    std::filesystem::rename(tmp, path);
}

/// One section of the overlay, or an empty object. Never throws on a malformed section: a
/// hosts table that is somehow a string must not stop the switches from being applied.
static nlohmann::json
overlaySection(const nlohmann::json& doc, const char* key)
{
    if (doc.is_object() && doc.contains(key) && doc.at(key).is_object())
    {
        return doc.at(key);
    }
    return nlohmann::json::object();
}

/// The overlay as a document that is about to be MODIFIED, or a throw.
///
/// 🔴 Refusing is deliberate, and so is where it happens. Both setters call this BEFORE they
/// touch the graph, so an unreadable overlay makes the whole rename a no-op and the 400 the
/// endpoint then answers is true. The alternatives were both worse: starting from an empty
/// document silently drops every other device's name the next time anyone renames anything,
/// and warning-then-carrying-on leaves the caller told "success" about a name that will not
/// survive a restart. This repo has a documented habit of the third shape -- a request that was
/// refused and did something anyway -- and this is the ordering that avoids adding to it.
static nlohmann::json
readNameOverlayForWriting(const std::string& path, const std::string& topologyPath)
{
    std::error_code ec;
    if (!std::filesystem::exists(path, ec) || ec)
    {
        nlohmann::json fresh = nlohmann::json::object();
        fresh[kOverlayVersionKey] = kNameOverlayVersion;
        fresh[kOverlayTopologyKey] = topologyPath;
        fresh[kOverlaySwitchesKey] = nlohmann::json::object();
        fresh[kOverlayHostsKey] = nlohmann::json::object();
        return fresh;
    }

    nlohmann::json doc = readJsonFile(path);
    if (!doc.is_object())
    {
        throw std::runtime_error("the nickname overlay \"" + path +
                                 "\" is not a JSON object; refusing to overwrite it");
    }
    if (doc.contains(kOverlayVersionKey) &&
        doc.at(kOverlayVersionKey) != nlohmann::json(kNameOverlayVersion))
    {
        throw std::runtime_error("the nickname overlay \"" + path + "\" declares version " +
                                 doc.at(kOverlayVersionKey).dump() + "; this build writes " +
                                 std::to_string(kNameOverlayVersion) +
                                 " and will not overwrite a format it does not understand");
    }
    doc[kOverlayVersionKey] = kNameOverlayVersion;
    doc[kOverlayTopologyKey] = topologyPath;
    if (!doc.contains(kOverlaySwitchesKey) || !doc.at(kOverlaySwitchesKey).is_object())
    {
        doc[kOverlaySwitchesKey] = nlohmann::json::object();
    }
    if (!doc.contains(kOverlayHostsKey) || !doc.at(kOverlayHostsKey).is_object())
    {
        doc[kOverlayHostsKey] = nlohmann::json::object();
    }
    return doc;
}

std::string
TopologyAndFlowMonitor::nicknameOverlayPath() const
{
    // Same rule as activeTopologyPath()'s override, for the same reason: getenv returns a
    // valid pointer to "" for `NDTWIN_NICKNAME_OVERLAY=`, and an empty path would have this
    // process rename a stray ".tmp" over nothing.
    const char* custom = std::getenv("NDTWIN_NICKNAME_OVERLAY");
    if (custom != nullptr && custom[0] != '\0')
    {
        return custom;
    }

    // 🔴 Anchored to the MODEL FILE's checkout, not to this process's working directory.
    // Found live on 2026-09-06 07:15, and invisible to every offline test in this repo:
    // tools/test_workflow/stack.sh starts the kernel with
    //     bash -c "cd '$KERNEL_DIR/build' && exec ./bin/ndtwin_kernel ..."
    // so the cwd is <checkout>/build. kNameOverlayDir is a relative path, so the overlay went
    // to <checkout>/build/.test_run/nickname_overlay/, while `ndt status --check` reads
    // <checkout>/.test_run/nickname_overlay/ -- and printed "none set through the API" on a
    // fabric where a nickname HAD been set and had survived a restart. Both halves were
    // individually honest and together they said something false. The overlay also lived
    // inside the build directory, where `rm -rf build` takes it.
    //
    // The anchor is the model file, because the overlay describes THAT model in THAT checkout:
    // <checkout>/setting/<model>.json -> <checkout>. Where the model is not in a directory
    // called "setting" (a hand-passed --topology, a test fixture in /tmp), the overlay sits
    // beside the model's own directory instead of climbing out of it -- climbing would put it
    // somewhere unrelated and possibly unwritable, e.g. "/" for /tmp/x.json.
    //
    // A RELATIVE model path is left relative on purpose, and it is still right: the kernel
    // could not have opened the model at all unless its cwd made that relative path resolve,
    // so the same cwd resolves the overlay to the same checkout. AppConfig ships
    // "../setting/<model>.json", which under the launch above resolves to <checkout>/setting/
    // and gives ".." as the root -- i.e. <checkout>/.test_run/, which is where `ndt` looks.
    const std::filesystem::path model(activeTopologyPath());
    const std::filesystem::path dir = model.parent_path();
    const std::filesystem::path root =
        dir.filename() == kShippedTopologyDirName ? dir.parent_path() : dir;
    return (root / kNameOverlayDir / (model.stem().string() + ".names.json")).string();
}

void
TopologyAndFlowMonitor::applyNicknameOverlayNoLock()
{
    const std::string path = nicknameOverlayPath();

    std::error_code ec;
    if (!std::filesystem::exists(path, ec) || ec)
    {
        // Nothing has ever been renamed against this model. The normal case, and silent:
        // every start of a fresh checkout would otherwise log a line about a missing file.
        return;
    }

    nlohmann::json doc;
    try
    {
        doc = readJsonFile(path);
    }
    catch (const std::exception& err)
    {
        // 🔴 A cosmetic file must not stop a kernel from starting. This is the opposite
        // decision from readNameOverlayForWriting above, and deliberately so: there, refusing
        // protects names that already exist; here, refusing would cost the fabric.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "the nickname overlay \"{}\" could not be read ({}); starting with "
                           "the names \"{}\" carries. Nothing in the model has been lost -- "
                           "delete the overlay to stop this warning",
                           path,
                           err.what(),
                           activeTopologyPath());
        return;
    }

    const nlohmann::json switches = overlaySection(doc, kOverlaySwitchesKey);
    const nlohmann::json hosts = overlaySection(doc, kOverlayHostsKey);

    // Everything the overlay names, minus everything the graph turned out to have. What is
    // left is reported one line per entry -- see the loop at the bottom.
    std::unordered_set<std::string> unmatchedSwitches;
    std::unordered_set<std::string> unmatchedHosts;
    for (auto it = switches.begin(); it != switches.end(); ++it)
    {
        unmatchedSwitches.insert(it.key());
    }
    for (auto it = hosts.begin(); it != hosts.end(); ++it)
    {
        unmatchedHosts.insert(it.key());
    }

    // One pass over the vertices rather than one lookup per overlay entry: the overlay is
    // keyed exactly the way the two setters match, so the graph can be walked once.
    std::size_t applied = 0;
    for (auto [v_it, v_end] = boost::vertices(*m_graph); v_it != v_end; ++v_it)
    {
        auto& vp = (*m_graph)[*v_it];
        const bool isSwitch = vp.vertexType == VertexType::SWITCH;
        const std::string key = std::to_string(isSwitch ? vp.dpid : vp.mac);
        const nlohmann::json& table = isSwitch ? switches : hosts;

        const auto entry = table.find(key);
        if (entry == table.end() || !entry->is_object())
        {
            continue;
        }
        if (entry->contains(kOverlayNicknameKey) && entry->at(kOverlayNicknameKey).is_string())
        {
            vp.nickName = entry->at(kOverlayNicknameKey).get<std::string>();
            ++applied;
        }
        if (entry->contains(kOverlayDeviceNameKey) &&
            entry->at(kOverlayDeviceNameKey).is_string())
        {
            vp.deviceName = entry->at(kOverlayDeviceNameKey).get<std::string>();
            ++applied;
        }
        (isSwitch ? unmatchedSwitches : unmatchedHosts).erase(key);
    }

    // 🔴 One WARN per entry that matched nothing, and no throw. An overlay written against a
    // 128-host model and read back under a 4-host one is an ordinary thing to do, and the
    // entries that do apply must still apply. Naming each one is what keeps this from being
    // the silent-drop shape: a name that did not take effect says so.
    for (const auto& dpid : unmatchedSwitches)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "the nickname overlay \"{}\" names switch dpid {}, which is not in "
                           "\"{}\"; that entry was ignored",
                           path,
                           dpid,
                           activeTopologyPath());
    }
    for (const auto& mac : unmatchedHosts)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "the nickname overlay \"{}\" names host mac {}, which is not in "
                           "\"{}\"; that entry was ignored",
                           path,
                           mac,
                           activeTopologyPath());
    }
    if (applied > 0)
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "applied {} name(s) from the nickname overlay \"{}\" over \"{}\"",
                           applied,
                           path,
                           activeTopologyPath());
    }
}

/// The shared half of the two setters below: put one name into the overlay document.
static void
setOverlayName(nlohmann::json& overlay,
               bool isSwitch,
               uint64_t key,
               const char* field,
               const std::string& value)
{
    overlay[isSwitch ? kOverlaySwitchesKey : kOverlayHostsKey][std::to_string(key)][field] =
        value;
}

void
TopologyAndFlowMonitor::setVertexDeviceName(Graph::vertex_descriptor v, std::string name)
{
    // 🔴 Lock order, stated because it is the reverse of what this function used to do: the
    // overlay mutex is taken FIRST and held across the graph update, so that the read of the
    // overlay happens before anything is mutated (see readNameOverlayForWriting). No path in
    // this class takes m_configurationFileMutex while holding m_graphMutex -- these two
    // setters are its only users, and they both take it in this order -- so there is no cycle.
    std::lock_guard guard(m_configurationFileMutex);
    const std::string overlayPath = nicknameOverlayPath();
    nlohmann::json overlay = readNameOverlayForWriting(overlayPath, activeTopologyPath());

    bool isSwitch = false;
    uint64_t key = 0;
    {
        std::unique_lock lock(*m_graphMutex);
        auto& vp = (*m_graph)[v];
        vp.deviceName = name;
        isSwitch = vp.vertexType == VertexType::SWITCH;
        key = isSwitch ? vp.dpid : vp.mac;
    }

    setOverlayName(overlay, isSwitch, key, kOverlayDeviceNameKey, name);
    writeJsonFileAtomically(overlayPath, overlay);
}

void
TopologyAndFlowMonitor::setVertexNickname(Graph::vertex_descriptor v, std::string nickname)
{
    // The twin of setVertexDeviceName, and still written out rather than folded into it: they
    // are two endpoints and two fields, and a gate that mutates one must not be answered by a
    // test that only ever exercised the other.
    std::lock_guard guard(m_configurationFileMutex);
    const std::string overlayPath = nicknameOverlayPath();
    nlohmann::json overlay = readNameOverlayForWriting(overlayPath, activeTopologyPath());

    bool isSwitch = false;
    uint64_t key = 0;
    {
        std::unique_lock lock(*m_graphMutex);
        auto& vp = (*m_graph)[v];
        vp.nickName = nickname;
        isSwitch = vp.vertexType == VertexType::SWITCH;
        key = isSwitch ? vp.dpid : vp.mac;
    }

    setOverlayName(overlay, isSwitch, key, kOverlayNicknameKey, nickname);
    writeJsonFileAtomically(overlayPath, overlay);
}

/** @brief Keeps the graph in step with the control plane, instead of snapshotting it once.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 *
 * This used to call fetchAndUpdateTopologyData() exactly once and return. Measured on a live run:
 * `run` was entered at 13:55:55.154 and exited at **.242** -- 88 milliseconds -- and the entire
 * graph, switches and hosts and links, was whatever Ryu happened to know in that instant. Nothing
 * re-read it for the life of the process.
 *
 * That is the actual cause of the "flaky" `get_graph_data` contract failure, and the explanation
 * previously recorded for it was wrong. The note said static ARP stops Ryu ever learning host IPs;
 * in fact `testbed_topo.py` sets the static ARP entries and *then pings all 128 hosts in parallel*,
 * which is what teaches Ryu. So the empty-`ipv4` state is transient, and whether the one snapshot
 * catches it depends entirely on when the kernel starts:
 *
 *   - started 73 s after Mininet (by hand): Ryu already knows all 128 IPs -> 128/128 hosts up
 *   - started back-to-back (stack.sh up ovs): the snapshot lands mid-burst -> permanently short
 *
 * Same commit, same network, different verdict. Hosts are the visible symptom because they have no
 * push path at all -- switches arrive via /ndt/inform_switch_entered and link failures via
 * /ndt/link_failure_detected, but nothing ever pushes a host.
 *
 * Re-polling is safe for links, which was the thing worth checking before writing this: verified
 * live that Ryu's `/v1.0/topology/links` really does drop a failed link (32 -> 30 within 2 s) and
 * restore it on recovery (-> 32 within 8 s), and that `updateLinks` only ever sets `isUp = true`.
 * So a poll can fill in what was missed but cannot resurrect an edge the push path correctly took
 * down.
 *
 * Fast at first, then slow, and time-boxed rather than gated on a convergence test: a genuinely
 * absent host would keep a convergence gate in fast mode forever.
 */
/** @brief The thread entry. Exists only so that nothing can escape it.
 *
 * [Co-developed with claude code -- Adam]
 * An exception reaching a std::thread's entry point is std::terminate -- abort() of the whole
 * kernel, with the two lines the C++ runtime prints on stderr and nothing of ours: no logger
 * line, no file, no node, no thread name. That is exactly what round5-topology-repro step 09
 * captured, and this thread had no try/catch anywhere in it. Every individual parse inside
 * runLoop() is guarded on its own, so this should be unreachable; it is here so that "a bad
 * input costs us the poll, not the process" is true for a failure shape nobody has thought of
 * yet. The kernel's topology view freezes, which is a degraded twin -- but a degraded twin that
 * is still there to be asked, and that said so, beats a core dump.
 */
void
TopologyAndFlowMonitor::run()
{
    try
    {
        runLoop();
    }
    catch (const std::exception& err)
    {
        SPDLOG_LOGGER_CRITICAL(Logger::instance(),
                               "the topology thread is exiting after an unhandled error: {}. The "
                               "kernel stays up, but its view of the topology is now frozen at "
                               "whatever was last read.",
                               err.what());
    }
    catch (...)
    {
        SPDLOG_LOGGER_CRITICAL(Logger::instance(),
                               "the topology thread is exiting after an unhandled non-standard "
                               "exception. The kernel stays up, but its view of the topology is "
                               "now frozen at whatever was last read.");
    }
}

void
TopologyAndFlowMonitor::runLoop()
{
    using namespace std::chrono_literals;
    constexpr auto kWhileConverging = 5s;
    constexpr auto kOnceConverged = 30s;
    constexpr auto kConvergingFor = 90s; // covers the ping burst and LLDP discovery

    SPDLOG_LOGGER_INFO(Logger::instance(), "TopologyAndFlowMonitor Run");

    // [Co-developed with claude code -- Adam]
    // D15. The static load, initializeMappingsFromGraph and configureTopologyApiUrls used to be
    // here, which is what made them race every caller main.cpp sequences after start(). They now
    // run inside start(), on the caller's thread; see the note there. This thread only polls.

    utils::StopSignal::WorkerScope scope(m_stopSignal, "topology-poll");

    const auto startedAt = std::chrono::steady_clock::now();
    auto previous = graphLivenessSummary();
    bool first = true;

    while (m_running.load())
    {
        pollControlPlaneTopology();

        // Reported only when something moved. One line per poll forever is how the two 1 Hz INFO
        // lines elsewhere in this process reached 138,000 lines a day.
        const auto now = graphLivenessSummary();
        if (first || now != previous)
        {
            const auto [switchesUp, hostsUp, edgesUp] = now;
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "topology from the control plane: {} switches, {} hosts, {} edges up",
                               switchesUp,
                               hostsUp,
                               edgesUp);
            previous = now;
            first = false;
        }

        const auto interval = (std::chrono::steady_clock::now() - startedAt < kConvergingFor)
                                  ? kWhileConverging
                                  : kOnceConverged;
        // [Co-developed with claude code -- Adam]
        // Was sliced into 1 s naps so stop() did not wait out a whole interval. waitFor() ends on
        // the stop request itself, so the nap contributes nothing to the bound rather than up to
        // a second.
        if (m_stopSignal.waitFor(interval))
        {
            break;
        }
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting TopologyAndFlowMonitor's updating");
}

/** @brief (switches up, hosts up, edges up). Cheap change signal for the poll loop.
 *
 * [Co-developed with claude code -- Adam]
 */
std::tuple<std::size_t, std::size_t, std::size_t>
TopologyAndFlowMonitor::graphLivenessSummary() const
{
    std::shared_lock lock(*m_graphMutex);
    std::size_t switchesUp = 0;
    std::size_t hostsUp = 0;
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if (!(*m_graph)[*vi].isUp)
        {
            continue;
        }
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH)
        {
            ++switchesUp;
        }
        else
        {
            ++hostsUp;
        }
    }

    std::size_t edgesUp = 0;
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        if ((*m_graph)[*ei].isUp)
        {
            ++edgesUp;
        }
    }
    return {switchesUp, hostsUp, edgesUp};
}

vector<sflow::Path>
TopologyAndFlowMonitor::getAllPathsBetweenTwoHosts(sflow::FlowKey flow_key,
                                                   uint64_t src_sw_dpid,
                                                   uint64_t dst_sw_dpid)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "DFS Ready");
    vector<sflow::Path> paths;
    shared_lock lock(*m_graphMutex);

    // 1. Locate source and destination switch vertices
    Graph::vertex_descriptor src_v, dst_v;

    auto srcVertexOpt = findSwitchByDpidNoLock(src_sw_dpid);
    auto dstVertexOpt = findSwitchByDpidNoLock(dst_sw_dpid);

    if (!srcVertexOpt or !dstVertexOpt)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot Find Certain Switches");
        return paths;
    }

    src_v = *srcVertexOpt;
    dst_v = *dstVertexOpt;

    // 2. Prepare for DFS
    unordered_set<Graph::vertex_descriptor> visited;
    visited.reserve(boost::num_vertices(*m_graph));

    sflow::Path current_path;
    current_path.push_back({flow_key.srcIP, 0U});

    // 3. Recursive DFS lambda
    function<void(Graph::vertex_descriptor)> dfs = [&](Graph::vertex_descriptor u) {
        if (u == dst_v)
        {
            // Found a full path—store a copy
            current_path.push_back({dst_sw_dpid, 0U});
            current_path.push_back({flow_key.dstIP, 0U});
            paths.push_back(current_path);
            current_path.pop_back();
            current_path.pop_back();
            return;
        }
        visited.insert(u);

        // Explore all outgoing edges
        auto [ei, eiEnd] = boost::out_edges(u, *m_graph);

        for (; ei != eiEnd; ++ei)
        {
            auto e = *ei;
            auto v = boost::target(e, *m_graph);
            if (visited.count(v))
            {
                continue;
            }

            const auto& ep = (*m_graph)[e];
            // Only traverse the active and enabled links
            if (isUsable(ep))
            {
                current_path.push_back({ep.srcDpid, ep.srcInterface});
                dfs(v);
                current_path.pop_back();
            }
        }
        visited.erase(u);
    };

    // 4. Kick off the search
    SPDLOG_LOGGER_INFO(Logger::instance(), "DFS Start");
    dfs(src_v);

    string paths_str;
    for (auto path : paths)
    {
        for (auto node : path)
        {
            paths_str += "(" + to_string(node.first) + "," + to_string(node.second) + ") ";
        }
        paths_str += "| ";
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "{}", paths_str);
    return paths;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByIp(uint32_t ip) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && !vprop.ip.empty() &&
            vprop.ip.front() == ip)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByIpNoLock(uint32_t ip) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && !vprop.ip.empty() &&
            vprop.ip.front() == ip)
        {
            return *vi;
        }
    }
    return nullopt;
}

void
TopologyAndFlowMonitor::setVertexDown(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isUp = false;
}

void
TopologyAndFlowMonitor::setVertexUp(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isUp = true;
    /// @see setEdgeUp for why the reason is cleared here.
    (*m_graph)[v].downReason = DownReason::None;

    // [Co-developed with claude code -- Adam]
    // FINDINGS #46. `adminPoweredOff` is deliberately NOT cleared here. This is the observation
    // writer -- the 1 Hz liveness worker calls it on every tick a probe answers Up -- and the
    // proxy's `probe_ok` is cached, so within a second of a confirmed kill this function is
    // called for a switch that is already dead (P4PowerStrategy.cpp documents that sequence from
    // a live fabric). Clearing the commanded state here would hand the resurrection a second
    // door, one tick wide instead of one poll wide. The command is spent when a power-on
    // confirms a process is serving again, and that is clearVertexAdminPowerOff's job.
}

bool
TopologyAndFlowMonitor::getVertexIsUp(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].isUp;
}

/** @brief See the header. FINDINGS #46. [Co-developed with claude code -- Adam] */
void
TopologyAndFlowMonitor::setVertexPoweredOffByCommand(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    auto& vprop = (*m_graph)[v];
    vprop.isUp = false;
    vprop.adminPoweredOff = true;

    // A fresh episode: the next poll that declines to resurrect this switch should say so, even
    // if a previous off/on cycle already used up the one-shot.
    m_resurrectionDeclined.erase(vprop.dpid);
}

/** @brief See the header. FINDINGS #46. [Co-developed with claude code -- Adam] */
void
TopologyAndFlowMonitor::clearVertexAdminPowerOff(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    auto& vprop = (*m_graph)[v];
    vprop.adminPoweredOff = false;
    m_resurrectionDeclined.erase(vprop.dpid);
}

bool
TopologyAndFlowMonitor::getVertexAdminPoweredOff(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].adminPoweredOff;
}

bool
TopologyAndFlowMonitor::getVertexIsEnabled(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].isEnabled;
}

void
TopologyAndFlowMonitor::setMininetBridgePorts(Graph::vertex_descriptor v,
                                              std::vector<std::string> ports)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].bridgeConnectedPortsForMininet = ports;
}

std::vector<std::string>
TopologyAndFlowMonitor::getMininetBridgePorts(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].bridgeConnectedPortsForMininet;
}

// [Co-developed with claude code -- Adam]
// A-4f. Deliberately the same shape as the two above, including taking the value by copy: these
// are called from the power path while other threads read the graph, and the OVS strategy holds
// no lock of its own.
void
TopologyAndFlowMonitor::setBridgeSflowState(Graph::vertex_descriptor v, SflowBridgeState state)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].savedSflow = std::move(state);
}

SflowBridgeState
TopologyAndFlowMonitor::getBridgeSflowState(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].savedSflow;
}

void
TopologyAndFlowMonitor::setVertexEnable(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isEnabled = true;
}

void
TopologyAndFlowMonitor::setVertexDisable(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isEnabled = false;
}

bool
TopologyAndFlowMonitor::disableSwitchAndEdges(uint64_t dpid)
{
    std::unique_lock lock(*m_graphMutex);
    auto vertexOpt = findSwitchByDpidNoLock(dpid);
    if (!vertexOpt)
    {
        // [Co-developed with claude code -- Adam]
        // Returned rather than only logged: the caller composes the operator's answer, and while
        // this was void it answered "ok" to a disable that had touched nothing.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "administrative disable of dpid {} did nothing: no such switch in the "
                           "graph",
                           dpid);
        return false;
    }

    auto vertex = *vertexOpt;

    // [Co-developed with claude code -- Adam]
    // Both flags, and they do different jobs. `isEnabled = false` makes the disable take effect
    // now; `adminDisabled = true` makes it *survive*, because the next topology poll sets
    // `isEnabled` back to true unconditionally for everything it reports and has no idea an
    // operator ever spoke. Writing only the first is what made DisableSwitch a silent no-op.
    (*m_graph)[vertex].isEnabled = false;
    (*m_graph)[vertex].adminDisabled = true;

    for (auto [ei, ei_end] = boost::edges(*m_graph); ei != ei_end; ++ei)
    {
        auto src_v = boost::source(*ei, *m_graph);
        auto dst_v = boost::target(*ei, *m_graph);

        if (src_v == vertex || dst_v == vertex)
        {
            (*m_graph)[*ei].isEnabled = false;
            (*m_graph)[*ei].adminDisabled = true;
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "administrative disable of dpid {} recorded (survives topology polls)",
                       dpid);
    return true;
}

bool
TopologyAndFlowMonitor::enableSwitchAndEdges(uint64_t dpid)
{
    std::unique_lock lock(*m_graphMutex);
    auto vertexOpt = findSwitchByDpidNoLock(dpid);
    if (!vertexOpt)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "administrative enable of dpid {} did nothing: no such switch in the "
                           "graph",
                           dpid);
        return false;
    }

    auto vertex = *vertexOpt;

    // Clears the administrative intent as well as enabling: "enable s3" from an operator has to be
    // able to undo "disable s3" from the same operator, and only the second line does that.
    // [Co-developed with claude code -- Adam]
    (*m_graph)[vertex].isEnabled = true;
    (*m_graph)[vertex].adminDisabled = false;

    for (auto [ei, ei_end] = boost::edges(*m_graph); ei != ei_end; ++ei)
    {
        auto src_v = boost::source(*ei, *m_graph);
        auto dst_v = boost::target(*ei, *m_graph);

        if (src_v == vertex || dst_v == vertex)
        {
            (*m_graph)[*ei].isEnabled = true;
            (*m_graph)[*ei].adminDisabled = false;
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "administrative enable of dpid {} recorded", dpid);
    return true;
}

void
TopologyAndFlowMonitor::initializeMappingsFromGraph()
{
    std::shared_lock lock(*m_graphMutex);
    for (const auto& v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        const auto& props = (*m_graph)[v];

        if (props.vertexType != VertexType::SWITCH || props.ip.empty())
        {
            continue;
        }

        uint64_t dpid = props.dpid;
        std::string ipStr = utils::ipToString(props.ip[0]);

        m_dpidToIpStrMap[dpid] = ipStr;
        m_dpidStrToIpStrMap[std::to_string(dpid)] = ipStr;
        m_ipStrToDpidMap[ipStr] = dpid;
        m_ipStrToDpidStrMap[ipStr] = std::to_string(dpid);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_dpidToIpStrMap ===");
    for (const auto& [dpid, ip] : m_dpidToIpStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", dpid, ip);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_dpidStrToIpStrMap ===");
    for (const auto& [dpidStr, ip] : m_dpidStrToIpStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", dpidStr, ip);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_ipStrToDpidMap ===");
    for (const auto& [ip, dpid] : m_ipStrToDpidMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", ip, dpid);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_ipStrToDpidStrMap ===");
    for (const auto& [ip, dpidStr] : m_ipStrToDpidStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", ip, dpidStr);
    }
}

uint64_t
TopologyAndFlowMonitor::hashDstIp(const std::string& str)
{
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(str.c_str()), str.size(), hash);

    uint64_t result = 0;
    for (int i = 0; i < 8; ++i)
    {
        result = (result << 8) | hash[i];
    }
    return result;
}

std::vector<sflow::Path>
TopologyAndFlowMonitor::bfsAllPathsToDst(
    const Graph& g,
    Graph::vertex_descriptor dstSwitch,
    const uint32_t& dstIp,
    const std::vector<uint32_t>& allHostIps,
    std::unordered_map<uint64_t, std::vector<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>>>&
        newOpenflowTables)
{
    constexpr uint32_t kHostMask = 0xFFFFFFFFu; // /32
    constexpr uint32_t kPriority = 100;

    auto ruleExists = [](const auto& flowTable, uint32_t net, uint32_t mask, uint32_t pri) {
        return std::any_of(flowTable.begin(), flowTable.end(), [&](const auto& entry) {
            return std::get<0>(entry) == net && std::get<1>(entry) == mask &&
                   std::get<3>(entry) == pri; // include priority in identity
        });
    };

    std::unordered_map<Graph::vertex_descriptor, Graph::vertex_descriptor> parent;
    std::unordered_map<Graph::vertex_descriptor, bool> visited;
    std::queue<Graph::vertex_descriptor> q;

    visited[dstSwitch] = true;
    Graph::vertex_descriptor NULL_NODE = Graph::null_vertex();
    parent[dstSwitch] = NULL_NODE;
    q.push(dstSwitch);

    // BFS
    while (!q.empty())
    {
        Graph::vertex_descriptor current = q.front();
        q.pop();

        Graph::vertex_descriptor prev = parent[current];

        if (prev != NULL_NODE)
        {
            auto edgePair = boost::edge(current, prev, g);
            if (edgePair.second)
            {
                const auto& edgeProps = g[edgePair.first];

                uint64_t dpid = g[current].dpid;           // switch that will install the rule
                uint32_t outPort = edgeProps.srcInterface; // port on *current* leading to prev
                                                           // (depends on your edge model)

                if (dpid != 0)
                {
                    auto& flowTable = newOpenflowTables[dpid];

                    uint32_t net = dstIp & kHostMask;
                    uint32_t mask = kHostMask;

                    if (!ruleExists(flowTable, net, mask, kPriority))
                    {
                        flowTable.emplace_back(net, mask, outPort, kPriority);
                        SPDLOG_LOGGER_INFO(
                            Logger::instance(),
                            "Added OF rule on switch {} for {} /32 -> outPort {} (pri={})",
                            dpid,
                            utils::ipToString(net),
                            outPort,
                            kPriority);
                    }
                }
            }
        }

        // neighbor discovery
        std::vector<Graph::vertex_descriptor> neighbors;
        for (auto edge : boost::make_iterator_range(boost::out_edges(current, g)))
        {
            Graph::vertex_descriptor neighbor = boost::target(edge, g);

            if (!isUsable(g[neighbor]))
            {
                continue;
            }
            if (!isUsable(g[edge]))
            {
                continue;
            }
            if (visited[neighbor])
            {
                continue;
            }

            neighbors.push_back(neighbor);
        }

        std::sort(neighbors.begin(),
                  neighbors.end(),
                  [this, &dstIp, &g](const auto& a, const auto& b) {
                      std::string combinedA = utils::ipToString(dstIp) + std::to_string(g[a].dpid);
                      std::string combinedB = utils::ipToString(dstIp) + std::to_string(g[b].dpid);
                      return hashDstIp(combinedA) < hashDstIp(combinedB);
                  });

        for (Graph::vertex_descriptor neighbor : neighbors)
        {
            parent[neighbor] = current;
            visited[neighbor] = true;
            q.push(neighbor);
        }
    }

    // Path reconstruction (mostly unchanged)
    std::vector<sflow::Path> allPaths;

    for (const auto& srcIp : allHostIps)
    {
        if (srcIp == dstIp)
        {
            continue;
        }

        auto srcHostOpt = findVertexByIp(srcIp);
        if (!srcHostOpt.has_value())
        {
            continue;
        }

        sflow::Path path;
        uint32_t srcOutPort = 0;
        Graph::vertex_descriptor srcSwitch;

        auto edgeOpt = findEdgeByHostIp(srcIp);
        if (edgeOpt)
        {
            srcSwitch = boost::target(edgeOpt.value(), g);
            srcOutPort = g[edgeOpt.value()].dstInterface;
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "No edge found for host IP {}", srcIp);
            continue;
        }

        if (!visited[srcSwitch])
        {
            continue;
        }

        path.emplace_back(srcIp, srcOutPort);

        Graph::vertex_descriptor v = srcSwitch;
        while (v != dstSwitch)
        {
            Graph::vertex_descriptor nextHop = parent[v];
            auto edgePair = boost::edge(v, nextHop, g);
            if (edgePair.second)
            {
                uint64_t nodeId = g[v].dpid;
                uint32_t outPort = g[edgePair.first].srcInterface;
                path.emplace_back(nodeId, outPort);
            }
            v = nextHop;
        }

        // ---- FIXED dstSwitch -> dstHost edge handling ----
        auto dstHostOpt = findVertexByIp(dstIp);
        if (!dstHostOpt.has_value())
        {
            continue;
        }

        auto edgePair = boost::edge(dstSwitch, dstHostOpt.value(), g);
        if (edgePair.second)
        {
            uint32_t outPortToHost = g[edgePair.first].srcInterface;

            path.emplace_back(g[dstSwitch].dpid, outPortToHost);

            // also store rule on dstSwitch
            auto& flowTable = newOpenflowTables[g[dstSwitch].dpid];
            uint32_t net = dstIp & kHostMask;
            uint32_t mask = kHostMask;

            if (!ruleExists(flowTable, net, mask, kPriority))
            {
                flowTable.emplace_back(net, mask, outPortToHost, kPriority);
                SPDLOG_LOGGER_INFO(Logger::instance(),
                                   "Added OF rule on switch {} for {} /32 -> outPort {} (pri={})",
                                   g[dstSwitch].dpid,
                                   utils::ipToString(net),
                                   outPortToHost,
                                   kPriority);
            }
        }
        // -----------------------------------------------

        path.emplace_back(dstIp, 0);
        allPaths.push_back(std::move(path));
    }

    return allPaths;
}

json
TopologyAndFlowMonitor::getStaticTopologyJson()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Processing static topology json file request");
    std::shared_lock lock(*m_graphMutex);
    json result;
    try
    {
        result["nodes"] = json::array();
        result["edges"] = json::array();

        auto graph = *m_graph;
        // Nodes
        for (auto vd : boost::make_iterator_range(boost::vertices(graph)))
        {
            auto& v = graph[vd];
            if (v.vertexType == VertexType::SWITCH)
            {
                if (m_mode == utils::DeploymentMode::TESTBED)
                {
                    // [Co-developed with claude code -- Adam]
                    // The switch's own plug assignment, read from the topology file, not the
                    // constant {"172.25.166.135", 3} that used to be emitted for every switch --
                    // that pair is s2's, and on real hardware a consumer trusting this endpoint
                    // would have power-cycled one wrong outlet for all ten switches. The
                    // duplicate {"brand_name", v.brandName} that appeared twice in this
                    // initialiser is also gone; nlohmann just overwrote it, so it was dead.
                    result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                               {"dpid", v.dpid},
                                               {"mac", v.mac},
                                               {"vertex_type", v.vertexType},
                                               {"device_name", v.deviceName},
                                               {"brand_name", v.brandName},
                                               {"device_layer", v.deviceLayer},
                                               {"smart_plug_ip", v.smartPlugIp},
                                               {"smart_plug_outlet", v.smartPlugOutlet}});
                }
                else
                {
                    result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                               {"dpid", v.dpid},
                                               {"mac", v.mac},
                                               {"vertex_type", v.vertexType},
                                               {"device_name", v.deviceName},
                                               {"bridge_name", v.bridgeNameForMininet},
                                               {"brand_name", v.brandName},
                                               {"device_layer", v.deviceLayer},
                                               {"smart_plug_ip", v.smartPlugIp},
                                               {"smart_plug_outlet", v.smartPlugOutlet}});
                }
            }
            else
            {
                result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                           {"dpid", v.dpid},
                                           {"mac", v.mac},
                                           {"vertex_type", v.vertexType},
                                           {"device_name", v.deviceName},
                                           {"brand_name", v.brandName},
                                           {"device_layer", v.deviceLayer},
                                           {"brand_name", v.brandName}});
            }
        }

        // Edges
        for (auto ed : boost::make_iterator_range(boost::edges(graph)))
        {
            auto& e = graph[ed];

            result["edges"].push_back({{"link_bandwidth_bps", e.linkBandwidth},
                                       {"src_ip", utils::ipToString(e.srcIp)},
                                       {"src_dpid", e.srcDpid},
                                       {"src_interface", e.srcInterface},
                                       {"dst_ip", utils::ipToString(e.dstIp)},
                                       {"dst_dpid", e.dstDpid},
                                       {"dst_interface", e.dstInterface}});
        }

        SPDLOG_LOGGER_INFO(Logger::instance(), "get static topo file success");
    }
    catch (const exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Exception in get_graph_data: {}", e.what());
    }
    // [Co-developed with claude code -- Adam]
    // `result`, not `result.dump(2)`. The declared return type is json, and dumping here made
    // this function return a json *string value* whose content happens to be JSON -- the same
    // shape that was just fixed in getPathBetweenHostsJson, except there it was only the error
    // paths and here it was every path.
    //
    // The wire was never wrong, which is why it survived: the sole caller assigns straight into
    // res.body(), a std::string, so nlohmann converted the string-valued json back to the text
    // it came from and the two conversions cancelled. Any caller that treated the result as the
    // object its signature promises got a string instead -- as a test written against the
    // signature immediately did. The caller now dumps, so the served bytes are unchanged.
    return result;
}

double
TopologyAndFlowMonitor::getAvgLinkUsage(const Graph& g) const
{
    int noneZeroEdgeNum = 0;
    double sum = 0.0;

    for (auto e : boost::make_iterator_range(boost::edges(g)))
    {
        // [Co-developed with claude code -- Adam]
        // Was `if (!g[e].isUp)`: the only one of the six availability checks that did not take
        // the full intersection, so an administratively disabled link with residual traffic still
        // counted towards the average. Made consistent when adminDisabled was introduced -- an
        // operator who takes a link out of service should not see it in the utilisation figure
        // this endpoint reports.
        //
        // 2026-08-29: this comment used to end "...the utilisation figure that Energy-Saving-App
        // reads", and that was false. Energy-Saving-App declares a client for this endpoint
        // (include/app/http.hpp:34, defined src/app/http.cpp:393) and never calls it; its power
        // decision at src/app/energy_saving_app.cpp:926 reads group_avg_link_utilization
        // (src/common/types.cpp:396), computed from the graph, which never touches this function.
        // A sweep of all seven sibling repos named in tools/test_workflow/components.env found no
        // other caller. The change above is still right -- the reason given for it was not.
        // Stated rather than deleted so the next reader does not re-derive the same wrong premise;
        // see doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md.
        // Zero in-repo callers is not a licence to change the response: /ndt/ is a cross-repo
        // contract and the client above is one line away from being live.
        if (!isUsable(g[e]))
        {
            continue;
        }
        // [Co-developed with claude code -- Adam]
        // Resolve against `g`, the graph we are iterating, not the member graph. Callers pass a
        // snapshot -- handleGetAvgLinkUsage passes getGraph(), which is a copy, precisely so it
        // does not hold the lock -- so mixing the two reads a graph this function was given no
        // lock for. It happens to work today only because adjacency_list's source()/target()
        // return the descriptor's stored endpoints and ignore the graph argument entirely; the
        // moment that stops being true it is an out-of-bounds vertex lookup.
        auto targetNode = boost::target(e, g);
        auto sourceNode = boost::source(e, g);
        if (g[e].linkBandwidthUsage != 0 && g[sourceNode].vertexType != VertexType::HOST &&
            g[targetNode].vertexType != VertexType::HOST)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "{} to {} linkBandwidthUsage {} linkBandwidth {}",
                               g[sourceNode].nickName,
                               g[targetNode].nickName,
                               g[e].linkBandwidthUsage,
                               g[e].linkBandwidth);
            noneZeroEdgeNum++;
            sum += (static_cast<double>(g[e].linkBandwidthUsage) /
                    static_cast<double>(g[e].linkBandwidth));
        }
    }

    if (!noneZeroEdgeNum)
    {
        return 0;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "none zero edge number {}", noneZeroEdgeNum);

    return sum / static_cast<double>(noneZeroEdgeNum);
}

json
TopologyAndFlowMonitor::getLinkBandwidthBetweenSwitches(const std::string& ip1_str,
                                                        const std::string& ip2_str)
{
    json result;
    std::shared_lock lock(*m_graphMutex); // Ensure thread-safe read access to the graph

    // 1. Convert string IPs to uint32_t and find the corresponding vertices in the graph.
    // We use the "NoLock" versions of find functions because we already hold a lock.
    uint32_t ip1 = utils::ipStringToUint32(ip1_str);
    uint32_t ip2 = utils::ipStringToUint32(ip2_str);

    auto v1_opt = findSwitchByIpNoLock(ip1);
    auto v2_opt = findSwitchByIpNoLock(ip2);

    // 2. Handle cases where one or both switches are not found in the topology.
    if (!v1_opt.has_value() || !v2_opt.has_value())
    {
        result["error"] = "One or both switches could not be found in the topology.";
        if (!v1_opt.has_value())
        {
            result["missing_devices"].push_back(ip1_str);
        }
        if (!v2_opt.has_value())
        {
            result["missing_devices"].push_back(ip2_str);
        }
        return result;
    }

    auto v1 = *v1_opt;
    auto v2 = *v2_opt;

    // 3. Find the directed edge between the two switches.
    // A physical link consists of two directed edges in the graph.
    auto edge_pair_1_to_2 = boost::edge(v1, v2, *m_graph);

    // 4. Handle the case where no direct link exists.
    if (!edge_pair_1_to_2.second) // .second is a bool indicating if the edge was found
    {
        result["error"] = "No direct link found between the specified switches.";
        result["from"] = ip1_str;
        result["to"] = ip2_str;
        return result;
    }

    // 5. If a link exists, get the edges for both directions.
    auto edge1_to_2 = edge_pair_1_to_2.first;
    // [Co-developed with claude code -- Adam]
    // `.second` checked here for the same reason it is checked four lines above, where it was
    // the only one of the pair that was. A physical link is two directed edges, but nothing
    // guarantees the graph holds both: the topology file could declare one direction, and
    // updateLinks only ever adds. When the reverse was absent, `.first` was a singular
    // descriptor and `(*m_graph)[edge2_to_1]` read whatever it addressed -- so the reverse
    // direction of this report was built on an invalid edge, with no error anywhere.
    auto edge_pair_2_to_1 = boost::edge(v2, v1, *m_graph);
    if (!edge_pair_2_to_1.second)
    {
        result["error"] = "Only one direction of this link exists in the topology.";
        result["from"] = ip1_str;
        result["to"] = ip2_str;
        result["missing_direction"] = ip2_str + "_to_" + ip1_str;
        return result;
    }
    auto edge2_to_1 = edge_pair_2_to_1.first;

    const auto& props1 = (*m_graph)[edge1_to_2];
    const auto& props2 = (*m_graph)[edge2_to_1];

    // 6. Populate the JSON object with the link's bandwidth information.
    result["link_found"] = true;
    result["status"] = isUsable(props1) ? "up" : "down";

    // Direction from switch 1 to switch 2
    result[ip1_str + "_to_" + ip2_str] = {{"total_bandwidth_bps", props1.linkBandwidth},
                                          {"used_bandwidth_bps", props1.linkBandwidthUsage},
                                          {"utilization", props1.linkBandwidthUtilization},
                                          {"source_port", props1.srcInterface},
                                          {"destination_port", props1.dstInterface}};

    // Direction from switch 2 to switch 1
    result[ip2_str + "_to_" + ip1_str] = {{"total_bandwidth_bps", props2.linkBandwidth},
                                          {"used_bandwidth_bps", props2.linkBandwidthUsage},
                                          {"utilization", props2.linkBandwidthUtilization},
                                          {"source_port", props2.srcInterface},
                                          {"destination_port", props2.dstInterface}};

    return result;
}

json
TopologyAndFlowMonitor::getTopKCongestedLinksJson(int k)
{
    json result;
    if (k <= 0)
    {
        result["top_k_links"] = json::array();
        return result;
    }

    // Use the actual vertex descriptor type from your Graph definition.
    using VertexDescriptor = Graph::vertex_descriptor;

    struct LinkInfo
    {
        VertexDescriptor v1; // FIX: Use the defined type.
        VertexDescriptor v2; // FIX: Use the defined type.
        double max_utilization;

        // Comparison operator to sort links by utilization in descending order.
        bool operator<(const LinkInfo& other) const
        {
            return max_utilization > other.max_utilization;
        }
    };

    std::vector<LinkInfo> all_links;
    std::shared_lock lock(*m_graphMutex);

    auto edge_iter_pair = boost::edges(*m_graph);
    for (auto it = edge_iter_pair.first; it != edge_iter_pair.second; ++it)
    {
        auto edge = *it;
        VertexDescriptor src_v = boost::source(edge, *m_graph); // FIX: Use the defined type.
        VertexDescriptor dst_v = boost::target(edge, *m_graph); // FIX: Use the defined type.

        if (src_v < dst_v)
        {
            auto edge_rev_pair = boost::edge(dst_v, src_v, *m_graph);
            if (!edge_rev_pair.second)
            {
                continue;
            }

            const auto& props_fwd = (*m_graph)[edge];
            const auto& props_rev = (*m_graph)[edge_rev_pair.first];

            if (isUsable(props_fwd) && isUsable(props_rev))
            {
                double max_util = std::max(props_fwd.linkBandwidthUtilization,
                                           props_rev.linkBandwidthUtilization);
                all_links.push_back({src_v, dst_v, max_util});
            }
        }
    }

    std::sort(all_links.begin(), all_links.end());

    json links_array = json::array();
    size_t links_to_return = std::min(static_cast<size_t>(k), all_links.size());

    // [Co-developed with claude code -- Adam]
    // FINDINGS #88. This loop walks boost::edges with NO vertexType filter, so v1/v2 can be
    // hosts -- and the load-time gate that makes ip.front() safe (see :654) covers SWITCH
    // vertices only. Worse, the expression bound ipToString's VECTOR overload, which returns
    // a vector<string> by value: for an address-less vertex .front() was taken on a
    // temporary that had just been built empty.
    //
    // A link we cannot name is skipped and COUNTED. Not reported as 0.0.0.0, which would put
    // a link that does not exist into a ranking operators act on; and not silently, which
    // would be indistinguishable from "there were only this many links".
    //
    // The loop bound moved from links_to_return to all_links.size() at the same time, and
    // that is not part of the guard: with the old bound a skipped link would have shortened
    // the whole ranking, so a request for the top 5 could return 4 while a fifth rankable
    // link sat unread. The cap is now on what is EMITTED.
    int links_skipped_no_address = 0;

    for (size_t i = 0; i < all_links.size() && links_array.size() < links_to_return; ++i)
    {
        const auto& link = all_links[i];
        auto v1 = link.v1;
        auto v2 = link.v2;

        const auto ip1Opt = utils::firstAddressOf((*m_graph)[v1].ip);
        const auto ip2Opt = utils::firstAddressOf((*m_graph)[v2].ip);
        if (!ip1Opt || !ip2Opt)
        {
            ++links_skipped_no_address;
            continue;
        }
        const std::string& ip1_str = *ip1Opt;
        const std::string& ip2_str = *ip2Opt;

        auto edge1_to_2 = boost::edge(v1, v2, *m_graph).first;
        auto edge2_to_1 = boost::edge(v2, v1, *m_graph).first;
        const auto& props1 = (*m_graph)[edge1_to_2];
        const auto& props2 = (*m_graph)[edge2_to_1];

        json link_json;
        link_json["rank"] = links_array.size() + 1;
        link_json["status"] = "up";

        // FIX: Removed extra semicolon from the end of the initializer list.
        link_json[ip1_str + "_to_"s + ip2_str] = {{"total_bandwidth_bps", props1.linkBandwidth},
                                                  {"used_bandwidth_bps", props1.linkBandwidthUsage},
                                                  {"utilization", props1.linkBandwidthUtilization},
                                                  {"source_port", props1.srcInterface},
                                                  {"destination_port", props1.dstInterface}};

        // FIX: Removed extra semicolon from the end of the initializer list.
        link_json[ip2_str + "_to_"s + ip1_str] = {{"total_bandwidth_bps", props2.linkBandwidth},
                                                  {"used_bandwidth_bps", props2.linkBandwidthUsage},
                                                  {"utilization", props2.linkBandwidthUtilization},
                                                  {"source_port", props2.srcInterface},
                                                  {"destination_port", props2.dstInterface}};

        links_array.push_back(link_json);
    }

    result["top_k_links"] = links_array;
    result["links_skipped_no_address"] = links_skipped_no_address;
    return result;
}

void
TopologyAndFlowMonitor::flushEdgeFlowLoop()
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "flushEdgeFlowLoop started");

    utils::StopSignal::WorkerScope scope(m_stopSignal, "edge-flow-flush");

    while (m_running.load())
    {
        // prune under graph lock
        {
            std::unique_lock lock(*m_graphMutex);
            for (auto e : boost::make_iterator_range(boost::edges(*m_graph)))
            {
                auto& edge = (*m_graph)[e];
                for (auto it = edge.flowSet.begin(); it != edge.flowSet.end();)
                {
                    const auto& k = it->first;   // FlowKey
                    const auto& ts = it->second; // last_seen
                    if (Clock::now() - ts > std::chrono::seconds(2))
                    {
                        SPDLOG_LOGGER_TRACE(Logger::instance(),
                                            "TTL expire flow {} -> {} on edge {}->{}",
                                            utils::ipToString(k.srcIP),
                                            utils::ipToString(k.dstIP),
                                            edge.srcDpid,
                                            edge.dstDpid);
                        it = edge.flowSet.erase(it);
                    }
                    else
                    {
                        ++it;
                    }
                }
            }
        }

        // [Co-developed with claude code -- Adam]
        // An unsliced 1 s sleep. stop() joins this thread too, so it was a 1 s floor under the
        // monitor's shutdown even after the poll thread was made prompt.
        if (m_stopSignal.waitFor(std::chrono::milliseconds(1000)))
        {
            break;
        }
    }

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "flushEdgeFlowLoop stopped");
}

bool
TopologyAndFlowMonitor::touchEdgeFlow(Graph::edge_descriptor e, const sflow::FlowKey& key)
{
    std::unique_lock lk(*m_graphMutex);
    auto& mp = (*m_graph)[e].flowSet;
    auto now = Clock::now();

    auto [it, inserted] = mp.emplace(key, now);
    if (!inserted)
    {
        it->second = now; // refresh last_seen
    }
    return inserted; // true if it was newly added
}