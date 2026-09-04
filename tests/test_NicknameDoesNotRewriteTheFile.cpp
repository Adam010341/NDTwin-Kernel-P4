/**
 * OV-1: renaming a device must change the field it was asked to change, and nothing else.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Measured 2026-09-04, twice, once per data plane: one
 * POST /ndt/modify_nickname produced a 3998-insertion / 3998-deletion diff on
 * setting/StaticNetworkTopologyMininet_10Switches.json -- a file the repository tracks -- with
 * the JSON semantically identical. Later the same night, on the P4 plane, the same call did it
 * to StaticNetworkTopologyP4_10Switches_4Hosts.json (664/664). It follows activeTopologyPath(),
 * so it is a property of the writer and not of a plane.
 *
 * The cause is that the writer read the document into an `nlohmann::json`, whose default
 * ObjectType is std::map, so every object came back out in dictionary order. The consequence
 * that made it urgent is `ndt status --check`: it compares the topology file's sha256 with the
 * one the `ndt up` loaded (tools/test_workflow/ndt:2239-2255) and therefore reported the
 * kernel's own rewrite as "the topology file has been edited since the ndt up that loaded it".
 *
 * 🔴 This is NOT a new defect. tools/contract_test/spec.py:1341-1349 has carried a note about
 * the same behaviour -- "git checkout it after a mutation run" -- since 2026-08-17. What is new
 * is the consequence.
 *
 * What these tests pin, and why each is here:
 *   * the rename changes ONE line (the two byte-level cases). Ordering alone is not enough --
 *     the shipped files do not all use the same indent, so a writer with a fixed setw(2)
 *     reformats every line of a 4-space file and the sha256 is just as changed;
 *   * the rename still WORKS, in the graph and in the file (the two control cases). Deleting
 *     the persistence entirely would satisfy every byte-level assertion above;
 *   * every shipped topology survives a rename with its layout intact, so this cannot regress
 *     for a file no test names individually.
 *
 * 🔴 NEVER points at setting/. Every case copies a shipped file to a pid-tagged temp file and
 * points the kernel at it with NDTWIN_TOPO_FILE -- the same construction as
 * tests/test_PollDoesNotResurrect.cpp and tests/test_DataPlaneKindOrdering.cpp. A test for a
 * defect whose whole content is "it writes to a tracked file" must not write to the tracked
 * file.
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

std::vector<std::string>
lines(const std::string& text)
{
    std::vector<std::string> out;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line))
    {
        out.push_back(line);
    }
    return out;
}

/// Non-blank lines with their leading whitespace removed -- the CONTENT of the document.
///
/// Blank lines and indentation are dropped here on purpose and the limitation is named rather
/// than hidden: four of the shipped files carry hand-left blank lines inside their arrays (and
/// two of those also have three braces indented seven spaces where the rest of the file uses
/// eight), and no JSON serialiser reproduces either. The layout half of the property is asserted
/// separately, as a count, in the last case below.
std::vector<std::string>
strippedSignificantLines(const std::string& text)
{
    std::vector<std::string> out;
    for (auto& line : lines(text))
    {
        const auto first = line.find_first_not_of(" \t\r");
        if (first != std::string::npos)
        {
            out.push_back(line.substr(first));
        }
    }
    return out;
}

/// Does this document end in a newline? A line-by-line comparison cannot see the difference, and
/// `ndt status --check` can: it compares the file's sha256, and one byte is one byte.
bool
endsWithNewline(const std::string& text)
{
    return !text.empty() && text.back() == '\n';
}

/// How many lines differ, comparing position by position. A size mismatch is reported as a big
/// number so a caller's EXPECT_EQ(…, 1) says something useful rather than crashing.
std::size_t
differingLines(const std::vector<std::string>& a, const std::vector<std::string>& b)
{
    if (a.size() != b.size())
    {
        return a.size() + b.size();
    }
    std::size_t n = 0;
    for (std::size_t i = 0; i < a.size(); ++i)
    {
        if (a[i] != b[i])
        {
            ++n;
        }
    }
    return n;
}

/// A pid-tagged copy of a shipped topology, pointed at by NDTWIN_TOPO_FILE, removed on
/// destruction. The environment variable is restored, so one case cannot leak into the next.
class TempTopology
{
  public:
    explicit TempTopology(const std::string& shippedName)
    {
        m_source = settingDir() + "/" + shippedName;
        m_path = (std::filesystem::temp_directory_path() /
                  ("ndt-ov1-" + std::to_string(getpid()) + "-" + shippedName))
                     .string();
        std::filesystem::copy_file(m_source,
                                   m_path,
                                   std::filesystem::copy_options::overwrite_existing);
        const char* previous = std::getenv("NDTWIN_TOPO_FILE");
        m_hadPrevious = previous != nullptr;
        if (m_hadPrevious)
        {
            m_previous = previous;
        }
        setenv("NDTWIN_TOPO_FILE", m_path.c_str(), 1);
    }

    ~TempTopology()
    {
        if (m_hadPrevious)
        {
            setenv("NDTWIN_TOPO_FILE", m_previous.c_str(), 1);
        }
        else
        {
            unsetenv("NDTWIN_TOPO_FILE");
        }
        std::error_code ignored;
        std::filesystem::remove(m_path, ignored);
    }

    const std::string& path() const { return m_path; }
    std::string original() const { return readWhole(m_source); }
    std::string now() const { return readWhole(m_path); }

  private:
    std::string m_source;
    std::string m_path;
    std::string m_previous;
    bool m_hadPrevious = false;
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
};

constexpr const char* kP4Topology = "StaticNetworkTopologyP4_10Switches_4Hosts.json";
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

// --- the defect itself --------------------------------------------------------------------

TEST_F(NicknamePersistenceTest, AModifyNicknameChangesExactlyOneLineOfTheTopologyFile)
{
    TempTopology topo(kP4Topology);
    LoadedFabric fabric(topo.path());

    fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

    const auto before = lines(topo.original());
    const auto after = lines(topo.now());
    ASSERT_EQ(before.size(), after.size())
        << "the rename changed the number of lines in the file: " << before.size() << " -> "
        << after.size();
    EXPECT_EQ(differingLines(before, after), 1u)
        << "one nickname was changed and " << differingLines(before, after)
        << " lines moved; that is the 3998-line rewrite this test exists for";
    EXPECT_EQ(endsWithNewline(topo.now()), endsWithNewline(topo.original()))
        << "the file gained or lost its trailing newline -- invisible line by line, and a "
           "different sha256 to `ndt status --check`";
}

TEST_F(NicknamePersistenceTest, AModifyDeviceNameChangesExactlyOneLineOfTheTopologyFile)
{
    // The twin. It is a separate case, not a second assertion in the one above, because the two
    // functions are copy-paste duplicates of each other: a gate that mutated only one of them
    // would otherwise be caught by a test that never exercised it.
    TempTopology topo(kP4Topology);
    LoadedFabric fabric(topo.path());

    fabric.monitor->setVertexDeviceName(fabric.aSwitch(), kNewDeviceName);

    const auto before = lines(topo.original());
    const auto after = lines(topo.now());
    ASSERT_EQ(before.size(), after.size());
    EXPECT_EQ(differingLines(before, after), 1u);
}

TEST_F(NicknamePersistenceTest, TheMininetTopologyKeepsItsBytesToo)
{
    // The other file OV-1 was observed on. Different indent conventions live in these files and
    // that is exactly what a fixed setw(2) gets wrong, so both incident files are named.
    TempTopology topo(kMininetTopology);
    LoadedFabric fabric(topo.path());

    fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

    const auto before = lines(topo.original());
    const auto after = lines(topo.now());
    ASSERT_EQ(before.size(), after.size());
    EXPECT_EQ(differingLines(before, after), 1u);
    // 🔴 This file is the one that does NOT end in a newline, which is why the check lives here:
    // a writer that appends one changes the sha256 while every line still matches.
    EXPECT_EQ(endsWithNewline(topo.now()), endsWithNewline(topo.original()))
        << "the file gained or lost its trailing newline";
}

// --- the controls: the rename must still happen ---------------------------------------------

TEST_F(NicknamePersistenceTest, ANicknameChangeStillReachesTheGraph)
{
    // 🔴 Without this, deleting the whole function satisfies every byte-level case above.
    TempTopology topo(kP4Topology);
    LoadedFabric fabric(topo.path());
    const auto v = fabric.aSwitch();

    fabric.monitor->setVertexNickname(v, kNewNickname);

    std::shared_lock lock(*fabric.mutex);
    EXPECT_EQ((*fabric.graph)[v].nickName, kNewNickname)
        << "the in-memory half of the rename was lost";
}

TEST_F(NicknamePersistenceTest, TheNicknameIsStillWrittenToTheTopologyFile)
{
    // 🔴 And without this, deleting only the persistence satisfies both of the above.
    TempTopology topo(kP4Topology);
    LoadedFabric fabric(topo.path());
    const auto v = fabric.aSwitch();
    const uint64_t dpid = (*fabric.graph)[v].dpid;

    fabric.monitor->setVertexNickname(v, kNewNickname);

    const auto written = nlohmann::json::parse(topo.now());
    bool found = false;
    for (const auto& node : written.at("nodes"))
    {
        if (node.value("dpid", static_cast<uint64_t>(0)) == dpid && node.value("vertex_type", -1) == 0)
        {
            EXPECT_EQ(node.value("nickname", ""), kNewNickname);
            found = true;
        }
    }
    EXPECT_TRUE(found) << "dpid " << dpid << " is no longer in the file at all";
}

// --- no shipped topology loses its layout ----------------------------------------------------

TEST_F(NicknamePersistenceTest, EveryShippedTopologyKeepsItsContentThroughARename)
{
    // Two assertions, and the split is the honest part.
    //
    // 1. CONTENT, for every shipped file: comparing significant lines with their leading
    //    whitespace stripped, exactly one differs -- the field that was renamed. Nothing else
    //    moved, in any file.
    // 2. LAYOUT, in aggregate: at least nine of the thirteen come back byte for byte.
    //
    // Why the second is a count and not "all of them". Measured 2026-09-04: four shipped files
    // cannot round-trip byte-perfectly through ANY JSON writer, and it is their own doing --
    // the legacy `_ipAlias4_*` testbed files carry hand-left BLANK LINES inside their arrays,
    // and two of them additionally have three braces indented seven spaces where the rest of
    // the file uses eight. A serialiser normalises both. The nine that do round-trip include
    // every file the two data planes actually use: both OV-1 incident files, all five OVS ones
    // and both P4 ones.
    //
    // The number is here so the property cannot quietly regress: before this fix it was five of
    // thirteen (order preserved, indent not), and a future change that drops back to five turns
    // this red with a message that says so.
    int examined = 0;
    int byteIdentical = 0;
    for (const auto& entry : std::filesystem::directory_iterator(settingDir()))
    {
        const std::string name = entry.path().filename().string();
        if (name.rfind("StaticNetworkTopology", 0) != 0 || entry.path().extension() != ".json")
        {
            continue;
        }

        TempTopology topo(name);
        LoadedFabric fabric(topo.path());
        fabric.monitor->setVertexNickname(fabric.aSwitch(), kNewNickname);

        const auto before = strippedSignificantLines(topo.original());
        const auto after = strippedSignificantLines(topo.now());
        EXPECT_EQ(differingLines(before, after), 1u)
            << name << " changed more than the one field it was asked to change: "
            << before.size() << " significant lines before, " << after.size() << " after";

        if (differingLines(lines(topo.original()), lines(topo.now())) == 1u)
        {
            ++byteIdentical;
        }
        ++examined;
    }
    EXPECT_GE(examined, 5) << "this walked the shipped topologies and found almost none, so it "
                              "would have passed whatever the writer did";
    EXPECT_GE(byteIdentical, 9)
        << "only " << byteIdentical << " of " << examined
        << " shipped topologies survived a rename with every other line untouched; it was 9 "
           "when OV-1 was fixed on 2026-09-04, and 5 before that fix";
}
