/**
 * TopologyAndFlowMonitor::updateHosts used to read the graph without holding the graph mutex, and
 * this file is the instrument that says what that cost. It is also the gate that keeps the lock
 * there: remove it again and case 2 below goes red.
 *
 * [Co-developed with claude code -- Adam]
 *
 * THE SITE. TopologyAndFlowMonitor.cpp, in updateHosts, the attachment-switch branch. It was:
 *
 *     auto vertexOpt2 = findSwitchByDpid(*attachDpidOpt);          // takes and RELEASES shared_lock
 *     if (vertexOpt2.has_value())
 *     {
 *         auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
 *                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 *                                                 read with NO lock held
 *
 * findSwitchByDpid releases its shared_lock before it returns, so the descriptor it hands back was
 * used to dereference the graph outside every lock. findEdgeBySrcAndDstIp then takes a shared_lock
 * of its own -- which is why the read could not simply be wrapped in one: this shared_mutex is not
 * recursive, and a second shared_lock on the same thread deadlocks as soon as a writer is queued
 * (the same trap loadStaticTopologyFromFile documents at its own write lock). So the fix copies the
 * address out inside a scope that ends before the lookup. Every other graph access in updateHosts
 * was already under a lock; that one was not. R2-W18 §7 raised it, and Adam's ruling E-29 was
 * "open a ticket, but get independent race evidence first" -- hence the four cases below, which
 * were all run against the UNFIXED code before the lock was added.
 *
 * WHAT THESE FOUR CASES ARE FOR, AND WHAT EACH ONE CAN AND CANNOT SHOW
 *
 *  1. LiveShape_UpdateHostsAgainstRealReaders
 *     The production arrangement: one thread applying /v1.0/topology/hosts replies while other
 *     threads walk the read paths an HTTP handler, the power manager and the intent translator
 *     walk -- graph snapshot, topology serialisation, host and switch lookup, path computation.
 *     No synthetic writer anywhere. This is the case that can say whether a race happens TODAY.
 *
 *  2. ProbeWriter_UpdateHostsUnlockedReadOfSwitchIp
 *     Production updateHosts -- whatever it currently does -- against a writer that mutates
 *     s1's address list while holding the WRITE lock, exactly as any lock-respecting writer of
 *     the graph would. The writer is synthetic and this file says so plainly: no production code
 *     writes VertexProperties::ip after load -- parseStaticTopologyFile is the only writer of that
 *     field in the tree, and it refuses a second call. So this case tests the SHAPE of the defect
 *     ("the read is unsynchronised, and would race with any writer") and not its liveness.
 *
 *     It has two independent readouts, and they are NOT equally sensitive. 🔴 The verdict is the
 *     process exit code: 66 means ThreadSanitizer reported. Do not read "[  OK  ]" as "clean" --
 *     in one of the three recorded runs against the lock-less code TSan reported and every gtest
 *     assertion still passed, because the assertion needs the racy read to have actually landed
 *     on the probe value, while TSan only needs the two accesses to be unordered.
 *       - ThreadSanitizer, which names the unlocked read; and
 *       - an invariant assertion that needs no sanitizer at all. The probe writes s2's address
 *         into s1's slot and puts s1's own back before releasing the lock, so no reader that holds
 *         the lock can EVER observe s1.ip[0] == 192.168.123.12. The hosts entry names dpid 1 and
 *         host 10.0.0.2, so a correct read yields 192.168.123.11, findEdgeBySrcAndDstIp finds no
 *         192.168.123.11 -> 10.0.0.2 edge, and nothing is written. A read that catches the probe
 *         value yields 192.168.123.12, which DOES resolve -- to the s2 -> h2 edge -- and marks it
 *         up. That edge going up is an effect no lock-respecting execution can produce.
 *
 *  3. Control_LockedReaderOfTheSameBytes  <-- the control that decides what case 2 means
 *     Same writer, same bytes, same thread counts; the only thing changed is the reader's lock
 *     discipline. findSwitchByIp reads vprop.ip.front() for every switch vertex under a
 *     shared_lock. If case 2 reports and case 3 does not, the difference is the lock and nothing
 *     else. Without this, "TSAN reported something" is not evidence about updateHosts -- it is
 *     evidence that the binary is instrumented.
 *
 *  4. Control_UpdateSwitchesAgainstTheSameWriter
 *     The control named in the ticket: updateSwitches is the sibling ingest that does hold the
 *     lock across its lookup (unique_lock + findSwitchByDpidNoLock), so it must come out clean.
 *     Weaker than case 3 as a control -- it reads different bytes of the vertex than the probe
 *     writes, so byte-disjointness alone would explain a clean result -- and it is here because
 *     the ticket asks for the known-locked update path, not because it discriminates on its own.
 *
 * WITH THE FIX IN PLACE ALL FOUR CASES ARE CLEAN. Case 2 is the mutation gate: take the
 * shared_lock back out of updateHosts and it reports again, at the line the lock came from. Both
 * directions were run and are quoted verbatim in
 * doc/audit/2026-09-07_fix-e29-update-hosts-race/FIX-E29.md.
 *
 * HOW TO RUN IT. Not in ctest, deliberately: it is a sanitizer instrument, it costs minutes, and
 * one of its cases is allowed to report when the code is wrong. Run each case in its own process
 * so one verdict cannot contaminate another:
 *
 *     cmake -S . -B build-tsan -G Ninja -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=tsan
 *     JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
 *         cmake --build build-tsan --target test_update_hosts_race
 *     TSAN_OPTIONS="history_size=7" setarch "$(uname -m)" -R \
 *         ./build-tsan/bin/test_update_hosts_race --gtest_filter='UpdateHostsRaceTest.LiveShape*'
 *
 * 🔴 `setarch -R` (ASLR off) is not optional on this machine. Without it the binary dies before
 * main() with "FATAL: ThreadSanitizer: unexpected memory mapping" -- Ubuntu 24.04's
 * vm.mmap_rnd_bits against TSan's shadow layout, nothing to do with this project. The documented
 * fix is `sysctl vm.mmap_rnd_bits=28`, which needs root; setarch does not.
 *
 * Exit code 66 means ThreadSanitizer found a race, whatever gtest printed -- it replaces the
 * process exit code at exit. 0 means clean AND every assertion passed. Iteration and thread counts
 * are env-tunable so a run can be lengthened without a rebuild -- NDT_E29_ITERS (per reader
 * thread) and NDT_E29_READERS. The defaults are what the recorded evidence was taken with.
 */

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loader and the two protected ingest points. Same seam as
/// tests/test_TopologyAndFlowMonitor.cpp and tests/test_OptimisticTopologyReporting.cpp.
class RaceTestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path) { loadStaticTopologyFromFile(path); }

    using TopologyAndFlowMonitor::updateHosts;
    using TopologyAndFlowMonitor::updateSwitches;
};

// StaticNetworkTopologyP4_10Switches_4Hosts.json: 10 switches on 192.168.123.11-20 with dpids
// 1-10, four hosts on 10.0.0.1-4 with macs 1-4, 40 directed edges. h1 hangs off s1 and h2 off s2.
// Small on purpose -- every lookup in updateHosts is a linear scan, and a 14-vertex graph gives
// the reader thread far more trips through the unlocked read per second than the 138-vertex
// Mininet file does.
constexpr std::size_t kVertices = 14;
constexpr std::size_t kEdges = 40;

// Parsed rather than written as hex literals, and that is not a nicety: the graph stores
// addresses in **network** byte order (utils::ipStringToUint32 returns in_addr::s_addr), so
// 192.168.123.11 is 0x0B7BA8C0 on this machine and the obvious 0xC0A87B0B matches nothing. The
// first draft of this file used the obvious one and the detector edge simply was not found.
// [Co-developed with claude code -- Adam]
const uint32_t kS1Ip = utils::ipStringToUint32("192.168.123.11"); ///< s1's management address.
const uint32_t kS2Ip = utils::ipStringToUint32("192.168.123.12"); ///< s2's -- the probe value.
const uint32_t kH1Ip = utils::ipStringToUint32("10.0.0.1");
const uint32_t kH2Ip = utils::ipStringToUint32("10.0.0.2"); ///< named in the hosts reply below.

/// A hosts reply naming host 10.0.0.2 with its attachment dpid given as s1 rather than s2.
///
/// [Co-developed with claude code -- Adam]
/// Deliberately "wrong" in a way the control plane is free to be, and chosen so the correct
/// answer is *no write at all*: with s1.ip[0] read correctly there is no 192.168.123.11 ->
/// 10.0.0.2 edge, so the reverse-edge branch takes its WARN and touches nothing. That makes the
/// s2 -> h2 edge a clean detector -- see the file header.
constexpr const char* kHostsReplyAttachedToS1 =
    R"([{"mac": "00:00:00:00:00:02", "ipv4": ["10.0.0.2"], "port": {"dpid": "1"}}])";

/// A switches reply listing every dpid in the file, for the updateSwitches control.
constexpr const char* kSwitchesReply =
    R"([{"dpid": "1"}, {"dpid": "2"}, {"dpid": "3"}, {"dpid": "4"}, {"dpid": "5"},
        {"dpid": "6"}, {"dpid": "7"}, {"dpid": "8"}, {"dpid": "9"}, {"dpid": "a"}])";

/// Iterations per reader thread. Env-tunable so a run can be lengthened without a rebuild.
std::size_t iterations()
{
    if (const char* v = std::getenv("NDT_E29_ITERS"))
    {
        const auto n = std::strtoull(v, nullptr, 10);
        if (n > 0) return static_cast<std::size_t>(n);
    }
    return 4000;
}

/// Reader threads. The writer is always one thread -- a second one would only contend with the
/// first for the write lock, not widen the window the reader has to be caught in.
std::size_t readerThreads()
{
    if (const char* v = std::getenv("NDT_E29_READERS"))
    {
        const auto n = std::strtoull(v, nullptr, 10);
        if (n > 0) return static_cast<std::size_t>(n);
    }
    return 4;
}

/// Quiet, once. getStaticTopologyJson and getAllPathsBetweenTwoHosts each log a line at INFO on
/// every call, and at these iteration counts that is hundreds of thousands of lines interleaved
/// with the sanitizer's own output on the same stderr.
void
quietLoggerOnce()
{
    static std::once_flag once;
    std::call_once(once, [] {
        LogConfig cfg;
        cfg.level = spdlog::level::err;
        Logger::init(cfg);
    });
}

struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    RaceTestableMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the 14-vertex P4 topology, failing loudly rather than leaving an empty graph: every
    /// loop below would be vacuously clean on one, and loadStaticTopologyFromFile only logs when
    /// it cannot open the file.
    void load()
    {
        quietLoggerOnce();
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
            "../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
            "../../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
        };
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                monitor.load(candidate);
                break;
            }
        }
        ASSERT_EQ(boost::num_vertices(*graph), kVertices)
            << "the P4 topology did not load; every assertion below would be vacuous";
        ASSERT_EQ(boost::num_edges(*graph), kEdges);
    }

    /// The s2 -> h2 edge: source dpid 2, far end a host, addresses 192.168.123.12 -> 10.0.0.2.
    /// The detector described in the file header.
    std::optional<Graph::edge_descriptor> reverseEdgeS2ToH2() const
    {
        std::shared_lock lock(*mutex);
        for (const auto& e : boost::make_iterator_range(boost::edges(*graph)))
        {
            const auto& ep = (*graph)[e];
            if (ep.srcDpid == 2 && ep.dstDpid == 0 &&
                std::find(ep.srcIp.begin(), ep.srcIp.end(), kS2Ip) != ep.srcIp.end() &&
                std::find(ep.dstIp.begin(), ep.dstIp.end(), kH2Ip) != ep.dstIp.end())
            {
                return e;
            }
        }
        return std::nullopt;
    }

    bool edgeIsUp(Graph::edge_descriptor e) const
    {
        std::shared_lock lock(*mutex);
        return (*graph)[e].isUp;
    }

    /// s1's vertex, so the probe writer does not have to search for it on every iteration.
    Graph::vertex_descriptor switchS1() const
    {
        std::shared_lock lock(*mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*graph)))
        {
            if ((*graph)[v].vertexType == VertexType::SWITCH && (*graph)[v].dpid == 1)
            {
                return v;
            }
        }
        return Graph::null_vertex();
    }
};

/// The synthetic writer of case 2, 3 and 4. Holds the write lock for the whole mutation and puts
/// s1's own address back before releasing it, so the graph every lock-respecting reader sees is
/// byte-for-byte the one the file described. See the file header for why it is legitimate to
/// probe with a writer production does not have.
void
probeWriteSwitchIp(Fixture& fix, Graph::vertex_descriptor s1, std::atomic<bool>& stop)
{
    while (!stop.load(std::memory_order_relaxed))
    {
        std::unique_lock lock(*fix.mutex);
        auto& ips = (*fix.graph)[s1].ip;
        // Two distinct stores rather than one same-value store: a compiler is entitled to fold
        // away a write it can prove changes nothing, and this must not depend on it not doing so.
        ips[0] = kS2Ip;
        ips[0] = kS1Ip;
    }
}

/// Everything a snapshot of the graph must still be true of, whatever the poll thread is doing.
/// Taken on the deep copy getGraph() returns, so it is a check on a consistent view rather than
/// a second unsynchronised reader of its own.
void
assertSnapshotSelfConsistent(const Graph& g)
{
    ASSERT_EQ(boost::num_vertices(g), kVertices) << "discovery invented or dropped a vertex";
    ASSERT_EQ(boost::num_edges(g), kEdges) << "discovery invented or dropped an edge";
    for (auto v : boost::make_iterator_range(boost::vertices(g)))
    {
        const auto& vp = g[v];
        if (vp.vertexType == VertexType::SWITCH)
        {
            ASSERT_FALSE(vp.ip.empty()) << "a switch lost its address list";
            ASSERT_NE(vp.dpid, 0u) << "a switch lost its datapath id";
        }
        else
        {
            ASSERT_EQ(vp.dpid, 0u) << "a host acquired a datapath id";
        }
    }
    for (const auto& e : boost::make_iterator_range(boost::edges(g)))
    {
        ASSERT_LT(boost::source(e, g), boost::num_vertices(g));
        ASSERT_LT(boost::target(e, g), boost::num_vertices(g));
    }
}

// ---------------------------------------------------------------------------------------------
// 1. The live shape: no synthetic writer anywhere.
// ---------------------------------------------------------------------------------------------

TEST(UpdateHostsRaceTest, LiveShape_UpdateHostsAgainstRealReaders)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    const std::size_t iters = iterations();
    std::atomic<bool> stop{false};

    // The poll thread. updateGraph calls this from TopologyAndFlowMonitor::run(); here it is
    // called directly so the test needs no control plane.
    std::thread poll([&] {
        while (!stop.load(std::memory_order_relaxed))
        {
            fix.monitor.updateHosts(kHostsReplyAttachedToS1);
        }
    });

    std::vector<std::thread> readers;
    for (std::size_t t = 0; t < readerThreads(); ++t)
    {
        readers.emplace_back([&, t] {
            for (std::size_t i = 0; i < iters; ++i)
            {
                switch ((i + t) % 5)
                {
                case 0:
                {
                    // The snapshot every consumer outside this class works on: HttpSession,
                    // DeviceConfigurationAndPowerManager, IntentTranslator and
                    // HistoricalDataManager all start from getGraph().
                    const Graph snapshot = fix.monitor.getGraph();
                    assertSnapshotSelfConsistent(snapshot);
                    break;
                }
                case 1:
                    // The serialisation behind /ndt/get_static_topology_json.
                    (void)fix.monitor.getStaticTopologyJson();
                    break;
                case 2:
                    // Host and switch lookup.
                    (void)fix.monitor.findEdgeByHostIp(kH2Ip);
                    (void)fix.monitor.findSwitchByIp(kS1Ip);
                    (void)fix.monitor.findVertexByMac(2);
                    break;
                case 3:
                {
                    // Path computation.
                    sflow::FlowKey key{};
                    key.srcIP = kH1Ip;
                    key.dstIP = kH2Ip;
                    (void)fix.monitor.getAllPathsBetweenTwoHosts(key, 1, 2);
                    break;
                }
                default:
                    (void)fix.monitor.getTopKCongestedLinksJson(3);
                    break;
                }
            }
        });
    }

    for (auto& r : readers) r.join();
    stop.store(true, std::memory_order_relaxed);
    poll.join();

    // The poll did apply: h2 and its host-side edge came up. Without this the run could have been
    // clean because nothing happened.
    const auto h2Up = [&] {
        std::shared_lock lock(*fix.mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*fix.graph)))
        {
            const auto& vp = (*fix.graph)[v];
            if (vp.vertexType == VertexType::HOST && vp.mac == 2) return vp.isUp;
        }
        return false;
    }();
    EXPECT_TRUE(h2Up) << "the hosts reply was never applied, so this run observed nothing";

    const Graph snapshot = fix.monitor.getGraph();
    ASSERT_NO_FATAL_FAILURE(assertSnapshotSelfConsistent(snapshot));
}

// ---------------------------------------------------------------------------------------------
// 2. The subject: updateHosts' unlocked read against a lock-respecting writer.
// ---------------------------------------------------------------------------------------------

TEST(UpdateHostsRaceTest, ProbeWriter_UpdateHostsUnlockedReadOfSwitchIp)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    const auto s1 = fix.switchS1();
    ASSERT_NE(s1, Graph::null_vertex());
    const auto detector = fix.reverseEdgeS2ToH2();
    ASSERT_TRUE(detector.has_value()) << "the s2 -> h2 edge is the detector; without it this test "
                                         "asserts nothing";
    ASSERT_FALSE(fix.edgeIsUp(*detector)) << "the loader must start every edge down";

    // [Co-developed with claude code -- Adam]
    // The negative control, single-threaded, before any writer exists: the SAME reply applied with
    // nothing racing must leave the detector edge alone. Without this the final EXPECT_FALSE is
    // not evidence about the race -- "the edge came up" would have the competing explanation "this
    // reply lifts that edge anyway".
    fix.monitor.updateHosts(kHostsReplyAttachedToS1);
    ASSERT_FALSE(fix.edgeIsUp(*detector))
        << "applied with no concurrency at all, this reply already reaches the s2 -> h2 edge; the "
           "detector cannot tell a race from the ordinary path";
    {
        std::shared_lock lock(*fix.mutex);
        bool h2Up = false;
        for (auto v : boost::make_iterator_range(boost::vertices(*fix.graph)))
        {
            const auto& vp = (*fix.graph)[v];
            if (vp.vertexType == VertexType::HOST && vp.mac == 2) h2Up = vp.isUp;
        }
        ASSERT_TRUE(h2Up) << "the reply was not applied at all, so nothing reached the unlocked "
                             "read this test is about";
    }

    const std::size_t iters = iterations();
    std::atomic<bool> stop{false};
    std::thread writer([&] { probeWriteSwitchIp(fix, s1, stop); });

    std::vector<std::thread> readers;
    for (std::size_t t = 0; t < readerThreads(); ++t)
    {
        readers.emplace_back([&] {
            for (std::size_t i = 0; i < iters; ++i)
            {
                fix.monitor.updateHosts(kHostsReplyAttachedToS1);
            }
        });
    }
    for (auto& r : readers) r.join();
    stop.store(true, std::memory_order_relaxed);
    writer.join();

    // Under the lock, s1's address is what the file said, at every instant a reader could look.
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_EQ((*fix.graph)[s1].ip.at(0), kS1Ip) << "the probe writer did not restore s1's "
                                                       "address; this test's detector is void";
    }

    // The readout that needs no sanitizer. See the file header: no execution in which every read
    // of s1.ip[0] is made under the lock can reach this edge.
    EXPECT_FALSE(fix.edgeIsUp(*detector))
        << "updateHosts marked the s2 -> h2 edge up. Reaching that edge requires reading "
           "192.168.123.12 out of s1's address slot, and 192.168.123.12 is only ever in that slot "
           "while the write lock is held. The unlocked read at the findEdgeBySrcAndDstIp call in "
           "updateHosts observed a value no lock-respecting reader could see.";
}

// ---------------------------------------------------------------------------------------------
// 3. The control that decides what case 2 means: same writer, same bytes, locked reader.
// ---------------------------------------------------------------------------------------------

TEST(UpdateHostsRaceTest, Control_LockedReaderOfTheSameBytes)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    const auto s1 = fix.switchS1();
    ASSERT_NE(s1, Graph::null_vertex());

    const std::size_t iters = iterations();
    std::atomic<bool> stop{false};
    std::thread writer([&] { probeWriteSwitchIp(fix, s1, stop); });

    // findSwitchByIp reads vprop.ip.front() -- the very bytes the writer is mutating -- for every
    // switch vertex, under a shared_lock. Production code, production locking.
    std::vector<std::thread> readers;
    for (std::size_t t = 0; t < readerThreads(); ++t)
    {
        readers.emplace_back([&] {
            for (std::size_t i = 0; i < iters; ++i)
            {
                (void)fix.monitor.findSwitchByIp(kS1Ip);
            }
        });
    }
    for (auto& r : readers) r.join();
    stop.store(true, std::memory_order_relaxed);
    writer.join();

    std::shared_lock lock(*fix.mutex);
    EXPECT_EQ((*fix.graph)[s1].ip.at(0), kS1Ip);
}

// ---------------------------------------------------------------------------------------------
// 4. The control the ticket names: the sibling ingest that does hold the lock.
// ---------------------------------------------------------------------------------------------

TEST(UpdateHostsRaceTest, Control_UpdateSwitchesAgainstTheSameWriter)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    const auto s1 = fix.switchS1();
    ASSERT_NE(s1, Graph::null_vertex());

    const std::size_t iters = iterations();
    std::atomic<bool> stop{false};
    std::thread writer([&] { probeWriteSwitchIp(fix, s1, stop); });

    std::vector<std::thread> readers;
    for (std::size_t t = 0; t < readerThreads(); ++t)
    {
        readers.emplace_back([&] {
            for (std::size_t i = 0; i < iters; ++i)
            {
                fix.monitor.updateSwitches(kSwitchesReply);
            }
        });
    }
    for (auto& r : readers) r.join();
    stop.store(true, std::memory_order_relaxed);
    writer.join();

    // updateSwitches did apply: it is the only writer of switch isUp here.
    std::shared_lock lock(*fix.mutex);
    EXPECT_TRUE((*fix.graph)[s1].isUp)
        << "the switches reply was never applied, so this control observed nothing";
}

} // namespace
