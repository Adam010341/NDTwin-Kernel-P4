/**
 * W10: renaming a device must not write the model file at all, and the name must come back
 * after a restart.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHERE THIS CAME FROM, in two measurements a night apart.
 *
 * OV-1, 2026-09-04: one POST /ndt/modify_nickname produced a 3998-insertion /
 * 3998-deletion diff on setting/StaticNetworkTopologyMininet_10Switches.json -- a file the
 * repository tracks -- with the JSON semantically identical, because the writer read the
 * document into an `nlohmann::json` (default ObjectType std::map) and wrote every object back
 * in dictionary order. The fix preserved order, indent and trailing newline, and the diff
 * became one line. This file's previous version, test_NicknameDoesNotRewriteTheFile.cpp,
 * asserted exactly that: "changes one line, and one line only".
 *
 * 2026-09-05, on a live OVS fabric, that turned out not to be enough, and the reason is not a
 * bug in the OV-1 fix. `ndt status --check` compares the model file's sha256 against the one
 * recorded by the `ndt up` that loaded it (tools/test_workflow/ndt:2239-2255). A sha256 does
 * not count lines. One nickname change, a two-line diff, `--check` rc=1 and "the topology file
 * has been edited since the ndt up that loaded it". The same run carried two controls proving
 * this was the check working rather than failing: renaming and renaming BACK left the file
 * byte-identical and `--check` green, and an unrelated writer earned the identical sentence.
 * "The rename touches one line" and "--check stays green" are not simultaneously reachable
 * while the kernel writes that file at all.
 *
 * Adam's decision, 2026-09-05 18:1x: an overlay outside setting/, `--check` does not look at
 * it, the kernel lays it back on at startup, and the model files become read-only to the
 * kernel. This suite is the kernel half of that. The `ndt status --check` half is
 * tests/shell/test_ndt_status_check_baseline.sh group 9.
 *
 * WHAT EACH GROUP IS FOR
 *   * the model file is byte-identical after a rename -- for every shipped topology, not the
 *     two the incidents were measured on;
 *   * the name is in the overlay, at the key the loader will look it up by;
 *   * a fresh load picks the overlay up -- which is the half that makes the rename outlive a
 *     restart, and the half a "just stop writing the file" fix would have silently dropped;
 *   * 🔴 the controls: the rename still reaches the graph, hosts are keyed by mac and not by
 *     dpid, an unreadable overlay does not stop a load, and an entry for a device that is not
 *     in the topology is a warning rather than a throw or a rename of the wrong device.
 *
 * 🔴 NEVER points at setting/, and never at the real .test_run/. Every case copies a shipped
 * file to a pid-tagged temp file (NDTWIN_TOPO_FILE) and points the overlay at a pid-tagged
 * temp path (NDTWIN_NICKNAME_OVERLAY) -- the construction in tests/test_PollDoesNotResurrect.cpp
 * and tests/test_DataPlaneKindOrdering.cpp. A test for a defect whose whole content is "it
 * writes to a file it should not" must not write to that file.
 */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <vector>

#include <unistd.h> // getpid, for a temp name no concurrent run collides with

#include <boost/graph/adjacency_list.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loader, the same seam tests/test_TopologyInputValidation.cpp uses.
class LoadingMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

std::string
settingDir()
{
    static const char* kCandidates[] = {"setting", "../setting", "../../setting"};
    for (const char* candidate : kCandidates)
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

std::string
readWhole(const std::string& path)
{
    std::ifstream ifs(path);
    std::ostringstream out;
    out << ifs.rdbuf();
    return out.str();
}

/// Sets an environment variable for the life of the object and puts back what was there.
/// One case must not leak its overlay or its topology into the next.
class ScopedEnv
{
  public:
    ScopedEnv(std::string name, const std::string& value) : m_name(std::move(name))
    {
        const char* previous = std::getenv(m_name.c_str());
        m_hadPrevious = previous != nullptr;
        if (m_hadPrevious)
        {
            m_previous = previous;
        }
        setenv(m_name.c_str(), value.c_str(), 1);
    }

    ~ScopedEnv()
    {
        if (m_hadPrevious)
        {
            setenv(m_name.c_str(), m_previous.c_str(), 1);
        }
        else
        {
            unsetenv(m_name.c_str());
        }
    }

  private:
    std::string m_name;
    std::string m_previous;
    bool m_hadPrevious = false;
};

/// A pid-tagged copy of a shipped topology plus a pid-tagged overlay path beside it, both
/// pointed at through the environment and both removed on destruction.
class TempFabricFiles
{
  public:
    explicit TempFabricFiles(const std::string& shippedName)
        : m_source(settingDir() + "/" + shippedName),
          m_topology((std::filesystem::temp_directory_path() /
                      ("ndt-w10-" + std::to_string(getpid()) + "-" + shippedName))
                         .string()),
          m_overlay((std::filesystem::temp_directory_path() /
                     ("ndt-w10-" + std::to_string(getpid()) + "-" + shippedName + ".names.json"))
                        .string()),
          m_topologyEnv("NDTWIN_TOPO_FILE", m_topology),
          m_overlayEnv("NDTWIN_NICKNAME_OVERLAY", m_overlay)
    {
        std::filesystem::copy_file(m_source,
                                   m_topology,
                                   std::filesystem::copy_options::overwrite_existing);
        std::error_code ignored;
        std::filesystem::remove(m_overlay, ignored);
    }

    ~TempFabricFiles()
    {
        std::error_code ignored;
        std::filesystem::remove(m_topology, ignored);
        std::filesystem::remove(m_overlay, ignored);
    }

    const std::string& topologyPath() const { return m_topology; }
    const std::string& overlayPath() const { return m_overlay; }
    std::string original() const { return readWhole(m_source); }
    std::string topologyNow() const { return readWhole(m_topology); }
    bool overlayExists() const { return std::filesystem::exists(m_overlay); }
    nlohmann::json overlay() const { return nlohmann::json::parse(readWhole(m_overlay)); }

    void writeOverlay(const std::string& text) const
    {
        std::ofstream ofs(m_overlay);
        ofs << text;
    }

  private:
    std::string m_source;
    std::string m_topology;
    std::string m_overlay;
    // Declared after the paths so they are constructed after them, and destroyed first.
    ScopedEnv m_topologyEnv;
    ScopedEnv m_overlayEnv;
};

/// A monitor over @p file, loaded, in TESTBED mode -- every shipped file loads in that mode
/// (tests/test_TopologyInputValidation.cpp's no-regression case relies on the same thing) and it
/// avoids MININET's bridge_name requirement, which is nothing to do with this defect.
struct LoadedFabric
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::shared_ptr<LoadingMonitor> monitor;

    explicit LoadedFabric(const std::string& file)
    {
        monitor = std::make_shared<LoadingMonitor>(graph, mutex, bus, utils::TESTBED);
        monitor->load(file);
    }

    /// The first SWITCH vertex, whichever the file has. Renaming needs a real vertex; which one
    /// is irrelevant to the property under test.
    Graph::vertex_descriptor aSwitch() const
    {
        for (auto v : boost::make_iterator_range(vertices(*graph)))
        {
            if ((*graph)[v].vertexType == VertexType::SWITCH)
            {
                return v;
            }
        }
        ADD_FAILURE() << "the topology has no switch vertex, so nothing can be renamed";
        return Graph::vertex_descriptor();
    }

    /// The first HOST vertex, or nullopt for a file that has none.
    std::optional<Graph::vertex_descriptor> aHost() const
    {
        for (auto v : boost::make_iterator_range(vertices(*graph)))
        {
            if ((*graph)[v].vertexType != VertexType::SWITCH)
            {
                return v;
            }
        }
        return std::nullopt;
    }

    std::string nicknameOf(Graph::vertex_descriptor v) const
    {
        std::shared_lock lock(*mutex);
        return (*graph)[v].nickName;
    }

    std::string deviceNameOf(Graph::vertex_descriptor v) const
    {
        std::shared_lock lock(*mutex);
        return (*graph)[v].deviceName;
    }
};

constexpr const char* kP4Topology = "StaticNetworkTopologyP4_10Switches_4Hosts.json";
constexpr const char* kOvsTopology = "StaticNetworkTopologyOVS_10Switches_4Hosts.json";
constexpr const char* kMininetTopology = "StaticNetworkTopologyMininet_10Switches.json";
constexpr const char* kNewNickname = "NDT-TEST-NICKNAME";
constexpr const char* kNewDeviceName = "NDT-TEST-DEVICE-NAME";

class NicknamePersistenceTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        ASSERT_FALSE(settingDir().empty())
            << "cannot find the repo's setting/ directory from "
            << std::filesystem::current_path()
            << " -- every case below would then compare two empty strings";
    }
};

} // namespace

// --- the defect itself: the model file is not written ---------------------------------------

TEST_F(NicknamePersistenceTest, AModifyNicknameLeavesTheTopologyFileByteIdentical)
{
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());

    fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

    // 🔴 The whole file, byte for byte -- not "one line differs". A sha256 is what
    // `ndt status --check` compares, and one byte is one byte to it. This assertion is the
    // one the OV-1-era test could not make.
    EXPECT_EQ(files.topologyNow(), files.original())
        << "the kernel wrote the model file; W10 is that it must not touch it at all";
}

TEST_F(NicknamePersistenceTest, AModifyDeviceNameLeavesTheTopologyFileByteIdenticalToo)
{
    // The twin. A separate case, not a second assertion in the one above, because the two
    // setters are near-duplicates of each other: a gate that mutated only one of them would
    // otherwise be caught by a test that never exercised it.
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());

    fabric.monitor->setVertexDeviceName(fabric.aSwitch(), kNewDeviceName);

    EXPECT_EQ(files.topologyNow(), files.original())
        << "modify_device_name is the other writer, and it must not write either";
}

TEST_F(NicknamePersistenceTest, TheMininetTopologyKeepsItsBytesToo)
{
    // The file OV-1 was first observed on, and the one that does NOT end in a newline -- the
    // byte a line-by-line comparison cannot see and a sha256 can.
    TempFabricFiles files(kMininetTopology);
    LoadedFabric fabric(files.topologyPath());

    fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

    EXPECT_EQ(files.topologyNow(), files.original());
}

TEST_F(NicknamePersistenceTest, EveryShippedTopologySurvivesARenameByteForByte)
{
    // Before W10 this could only be asserted as "at most one line differs", and only nine of
    // the thirteen shipped files could round-trip byte-identically at all: four legacy
    // `_ipAlias4_*` testbed files carry hand-left blank lines inside their arrays, which no
    // JSON serialiser reproduces. With the writer gone the exception is gone with it, so this
    // is now 13 of 13 rather than 9 of 13, and it is stated as an equality per file.
    int examined = 0;
    for (const auto& entry : std::filesystem::directory_iterator(settingDir()))
    {
        const std::string name = entry.path().filename().string();
        if (name.rfind("StaticNetworkTopology", 0) != 0 || entry.path().extension() != ".json")
        {
            continue;
        }

        TempFabricFiles files(name);
        LoadedFabric fabric(files.topologyPath());
        fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

        EXPECT_EQ(files.topologyNow(), files.original())
            << name << " was rewritten by a rename";
        ++examined;
    }
    EXPECT_GE(examined, 5) << "this walked the shipped topologies and found almost none, so it "
                              "would have passed whatever the writer did";
}

// --- the overlay: where the name went --------------------------------------------------------

TEST_F(NicknamePersistenceTest, TheNicknameIsWrittenToTheOverlayUnderTheSwitchsDpid)
{
    // 🔴 Without this, deleting the persistence entirely satisfies every byte-level case
    // above -- "the model file did not change" is exactly what you get from a kernel that
    // stopped saving anything.
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());
    const auto v = fabric.aSwitch();
    const uint64_t dpid = (*fabric.graph)[v].dpid;

    fabric.monitor->setVertexNickname(v, kNewNickname);

    ASSERT_TRUE(files.overlayExists()) << "nothing was persisted anywhere";
    const auto doc = files.overlay();
    ASSERT_TRUE(doc.contains("switches")) << doc.dump();
    ASSERT_TRUE(doc.at("switches").contains(std::to_string(dpid))) << doc.dump();
    EXPECT_EQ(doc.at("switches").at(std::to_string(dpid)).value("nickname", ""), kNewNickname);
}

TEST_F(NicknamePersistenceTest, TheDeviceNameGoesToTheSameEntryAndDoesNotEvictTheNickname)
{
    // Two fields, one device, one entry: the second write must merge rather than replace. A
    // writer that rebuilt the entry from scratch would pass the case above and lose the
    // nickname here.
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());
    const auto v = fabric.aSwitch();
    const uint64_t dpid = (*fabric.graph)[v].dpid;

    fabric.monitor->setVertexNickname(v, kNewNickname);
    fabric.monitor->setVertexDeviceName(v, kNewDeviceName);

    const auto entry = files.overlay().at("switches").at(std::to_string(dpid));
    EXPECT_EQ(entry.value("nickname", ""), kNewNickname) << entry.dump();
    EXPECT_EQ(entry.value("device_name", ""), kNewDeviceName) << entry.dump();
}

TEST_F(NicknamePersistenceTest, AHostIsKeyedByItsMacAndNotByItsDpid)
{
    // 🔴 The reason the overlay is not the flat {"<dpid>": "<nickname>"} map the ticket
    // sketched: EVERY host node in EVERY shipped topology has "dpid": 0, and hosts are
    // reachable through modify_nickname's "mac" and "name" identifiers. A dpid-keyed overlay
    // collapses all four hosts of an ovs4 fabric onto the key "0", and renaming one would
    // rename all of them at the next start. This case fails on any such writer.
    TempFabricFiles files(kOvsTopology);
    LoadedFabric fabric(files.topologyPath());
    const auto host = fabric.aHost();
    ASSERT_TRUE(host.has_value()) << kOvsTopology << " has no host vertex";
    const uint64_t mac = (*fabric.graph)[*host].mac;
    ASSERT_EQ((*fabric.graph)[*host].dpid, 0u)
        << "this case's premise -- that hosts carry dpid 0 -- no longer holds for this file";

    fabric.monitor->setVertexNickname(*host, kNewNickname);

    const auto doc = files.overlay();
    EXPECT_TRUE(doc.at("hosts").contains(std::to_string(mac))) << doc.dump();
    EXPECT_FALSE(doc.at("switches").contains("0")) << "a host was filed as switch dpid 0: "
                                                   << doc.dump();
}

// --- the other half: a fresh load lays the overlay back on -----------------------------------

TEST_F(NicknamePersistenceTest, AFreshLoadPicksTheNicknameBackUp)
{
    // 🔴 This is the case that separates W10 from "stop writing the file". Rename, throw the
    // whole monitor away, load the same untouched model file again: the name must come back.
    TempFabricFiles files(kP4Topology);
    uint64_t dpid = 0;
    {
        LoadedFabric first(files.topologyPath());
        const auto v = first.aSwitch();
        dpid = (*first.graph)[v].dpid;
        first.monitor->setVertexNickname(v, kNewNickname);
        first.monitor->setVertexDeviceName(v, kNewDeviceName);
    }

    LoadedFabric second(files.topologyPath());
    const auto v = second.monitor->findSwitchByDpid(dpid);
    ASSERT_TRUE(v.has_value()) << "dpid " << dpid << " did not survive the reload";
    EXPECT_EQ(second.nicknameOf(*v), kNewNickname)
        << "the overlay was written but never applied, so the rename did not outlive the "
           "process -- the model file is untouched and the name is gone";
    EXPECT_EQ(second.deviceNameOf(*v), kNewDeviceName);

    // And the model file is still exactly what shipped, after all of that.
    EXPECT_EQ(files.topologyNow(), files.original());
}

TEST_F(NicknamePersistenceTest, AFreshLoadPicksAHostsNicknameBackUpUnderItsMac)
{
    // The host arm of the reload, so that a loader which only ever consults the "switches"
    // section is caught. Without it, the host case above proves only that the write side
    // chose the right key.
    TempFabricFiles files(kOvsTopology);
    uint64_t mac = 0;
    {
        LoadedFabric first(files.topologyPath());
        const auto host = first.aHost();
        ASSERT_TRUE(host.has_value());
        mac = (*first.graph)[*host].mac;
        first.monitor->setVertexNickname(*host, kNewNickname);
    }

    LoadedFabric second(files.topologyPath());
    const auto v = second.monitor->findVertexByMac(mac);
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(second.nicknameOf(*v), kNewNickname);
}

TEST_F(NicknamePersistenceTest, AnOverlayOnlyTouchesTheDeviceItNames)
{
    // The blast radius. Rename one switch, reload, and every OTHER vertex must still carry
    // the name the model file gives it -- the failure a dpid-keyed host map would produce,
    // and the failure a loader that applied the first entry to every vertex would produce.
    TempFabricFiles files(kOvsTopology);
    std::vector<std::pair<uint64_t, std::string>> before;
    uint64_t renamed = 0;
    {
        LoadedFabric first(files.topologyPath());
        for (auto v : boost::make_iterator_range(vertices(*first.graph)))
        {
            const auto& vp = (*first.graph)[v];
            before.emplace_back(vp.vertexType == VertexType::SWITCH ? vp.dpid : vp.mac,
                                vp.nickName);
        }
        const auto v = first.aSwitch();
        renamed = (*first.graph)[v].dpid;
        first.monitor->setVertexNickname(v, kNewNickname);
    }

    LoadedFabric second(files.topologyPath());
    std::size_t index = 0;
    int changed = 0;
    for (auto v : boost::make_iterator_range(vertices(*second.graph)))
    {
        const auto& vp = (*second.graph)[v];
        ASSERT_LT(index, before.size());
        const bool isTheRenamedSwitch =
            vp.vertexType == VertexType::SWITCH && vp.dpid == renamed;
        if (isTheRenamedSwitch)
        {
            EXPECT_EQ(vp.nickName, kNewNickname);
            ++changed;
        }
        else
        {
            EXPECT_EQ(vp.nickName, before[index].second)
                << "a device nobody renamed came back with a different nickname";
        }
        ++index;
    }
    EXPECT_EQ(changed, 1) << "exactly one device was renamed, so exactly one may differ";
}

// --- the controls ----------------------------------------------------------------------------

TEST_F(NicknamePersistenceTest, ANicknameChangeStillReachesTheGraph)
{
    // 🔴 Without this, deleting the whole function satisfies every file-level case above.
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());
    const auto v = fabric.aSwitch();

    fabric.monitor->setVertexNickname(v, kNewNickname);

    EXPECT_EQ(fabric.nicknameOf(v), kNewNickname) << "the in-memory half of the rename was lost";
}

TEST_F(NicknamePersistenceTest, ADeviceNameChangeStillReachesTheGraph)
{
    TempFabricFiles files(kP4Topology);
    LoadedFabric fabric(files.topologyPath());
    const auto v = fabric.aSwitch();

    fabric.monitor->setVertexDeviceName(v, kNewDeviceName);

    EXPECT_EQ(fabric.deviceNameOf(v), kNewDeviceName);
}

TEST_F(NicknamePersistenceTest, AnUnreadableOverlayDoesNotStopTheTopologyFromLoading)
{
    // 🔴 A cosmetic file must not be able to keep a fabric down. The load logs a warning and
    // carries on with the names the model file gives it.
    TempFabricFiles files(kP4Topology);
    files.writeOverlay("{ this is not json");

    LoadedFabric fabric(files.topologyPath());

    EXPECT_GT(boost::num_vertices(*fabric.graph), 0u)
        << "an unparseable overlay stopped the topology from loading";
    EXPECT_NE(fabric.nicknameOf(fabric.aSwitch()), kNewNickname);
}

TEST_F(NicknamePersistenceTest, AnOverlayEntryForAnAbsentDeviceIsIgnoredRatherThanMisapplied)
{
    // The case the ticket calls for by name: an entry whose dpid is not in this topology is
    // one warning line and no throw. The second assertion is the one that matters -- the
    // orphan entry must not land on some other device.
    TempFabricFiles files(kP4Topology);
    files.writeOverlay(R"({"version": 1,
                           "switches": {"999999": {"nickname": "NDT-TEST-ORPHAN"}},
                           "hosts": {}})");

    LoadedFabric fabric(files.topologyPath());

    ASSERT_GT(boost::num_vertices(*fabric.graph), 0u) << "the load refused over an orphan entry";
    for (auto v : boost::make_iterator_range(vertices(*fabric.graph)))
    {
        EXPECT_NE((*fabric.graph)[v].nickName, "NDT-TEST-ORPHAN")
            << "an overlay entry for a device that is not here was applied to one that is";
    }
}

TEST_F(NicknamePersistenceTest, TheDefaultOverlayPathIsOutsideSettingAndNamedAfterTheModel)
{
    // 🔴 The location itself, asserted rather than assumed, because it is half of the
    // decision: the overlay must not be inside setting/ (that is what `ndt status --check`
    // hashes) and must be per-model (dpids 1-10 exist in both the OVS and the P4 topology, so
    // one shared overlay would put OVS nicknames on a bmv2 fabric). Nothing is written here --
    // NDTWIN_NICKNAME_OVERLAY is cleared only so the default can be read back.
    const char* previous = std::getenv("NDTWIN_NICKNAME_OVERLAY");
    const std::string saved = previous != nullptr ? previous : "";
    unsetenv("NDTWIN_NICKNAME_OVERLAY");

    ScopedEnv topo("NDTWIN_TOPO_FILE", std::string(settingDir()) + "/" + kOvsTopology);
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    LoadingMonitor monitor(graph, mutex, bus, utils::TESTBED);
    const std::string path = monitor.nicknameOverlayPath();

    if (!saved.empty())
    {
        setenv("NDTWIN_NICKNAME_OVERLAY", saved.c_str(), 1);
    }

    EXPECT_EQ(path.find("setting/"), std::string::npos)
        << "the overlay is inside setting/, which is the directory `ndt status --check` "
           "hashes: " << path;
    EXPECT_NE(path.find(".test_run/"), std::string::npos) << path;
    EXPECT_NE(path.find("StaticNetworkTopologyOVS_10Switches_4Hosts"), std::string::npos)
        << "the overlay is not named after the model, so the OVS and P4 topologies -- which "
           "share dpids 1-10 -- would share one overlay: " << path;
}

TEST_F(NicknamePersistenceTest, TheOverlayPathFollowsTheActiveTopology)
{
    // The same property from the other side: two models, two overlays. A single hardcoded
    // path passes the case above and fails this one.
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    LoadingMonitor monitor(graph, mutex, bus, utils::TESTBED);

    const char* previous = std::getenv("NDTWIN_NICKNAME_OVERLAY");
    const std::string saved = previous != nullptr ? previous : "";
    unsetenv("NDTWIN_NICKNAME_OVERLAY");

    std::string ovs;
    std::string p4;
    {
        ScopedEnv topo("NDTWIN_TOPO_FILE", std::string(settingDir()) + "/" + kOvsTopology);
        ovs = monitor.nicknameOverlayPath();
    }
    {
        ScopedEnv topo("NDTWIN_TOPO_FILE", std::string(settingDir()) + "/" + kP4Topology);
        p4 = monitor.nicknameOverlayPath();
    }

    if (!saved.empty())
    {
        setenv("NDTWIN_NICKNAME_OVERLAY", saved.c_str(), 1);
    }

    EXPECT_NE(ovs, p4) << "both data planes share one overlay: " << ovs;
}
