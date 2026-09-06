/**
 * GET /ndt/get_openflow_capacity must report the plane it is actually running (W17).
 *
 * [Co-developed with claude code -- Adam]
 *
 * The endpoint served a static vendor catalogue -- OVS 1000000, BrocadeICX7250 3072, HPE5520
 * 65535 -- with no mention of bmv2 at all, while the fabric under it takes 1024 entries in
 * `MyIngress.ipv4_lpm` and hands the caller 896 of them once the fabric's own host routes are
 * counted (measured 2026-09-06, `rounds/06-X-experiments.md` §X2). The smallest catalogue number
 * was 3.4x the truth.
 *
 * ### What these tests are shaped to prove, and what they refuse to
 *
 * The one property worth defending is that **the ceiling is read, not known**. So the artifact
 * fixtures below never say 1024: they say 512 and 2048, and the same code must answer both. A
 * test written against 1024 would pass just as happily against `plane["max_entries"] = 1024;`,
 * which is the exact defect one layer up -- a number that is right today and unattached to
 * anything that could make it wrong tomorrow.
 *
 * The `/proc` walk is driven against a fixture tree, not the machine's real process table: the
 * question "does this find the running switch's artifact" must have the same answer whether or
 * not a bmv2 fabric happens to be up on this laptop while the suite runs.
 */

// HttpSession.hpp comes first on purpose: it declares the global `using json = nlohmann::json;`
// that the rest of this file uses unqualified, as every other test in this suite does, and it
// brings in the Beast/Asio types the endpoint peer at the bottom is built from.
#include "ndt_core/http/HttpSession.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <unistd.h> // getpid, for the per-process fixture directories

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/OpenflowCapacityReport.hpp"
#include "utils/Logger.hpp"

namespace
{

/// A throwaway directory, unique per process and per instance. ctest gives every test its own
/// process, so a fixture path shared by name is a race -- the one measured on
/// tests/test_IntentTaskOutcomes.cpp under `ctest -j2`. [Co-developed with claude code -- Adam]
class TempTree
{
  public:
    explicit TempTree(const std::string& tag)
    {
        static int counter = 0;
        m_root = std::filesystem::temp_directory_path() /
                 ("ndt_ofcap_" + tag + "_" + std::to_string(::getpid()) + "_" +
                  std::to_string(++counter));
        std::filesystem::remove_all(m_root);
        std::filesystem::create_directories(m_root);
    }

    ~TempTree()
    {
        std::error_code ec;
        std::filesystem::remove_all(m_root, ec);
    }

    TempTree(const TempTree&) = delete;
    TempTree& operator=(const TempTree&) = delete;

    const std::filesystem::path& root() const { return m_root; }

    /// Writes `body` at `relative`, creating parents.
    std::filesystem::path write(const std::string& relative, const std::string& body) const
    {
        const auto path = m_root / relative;
        std::filesystem::create_directories(path.parent_path());
        std::ofstream(path) << body;
        return path;
    }

    /// A `<root>/<pid>/cmdline` shaped like /proc: NUL-separated, NUL-terminated argv.
    std::filesystem::path fakeProcess(const std::string& pid,
                                      const std::vector<std::string>& argv) const
    {
        const auto dir = m_root / pid;
        std::filesystem::create_directories(dir);
        std::ofstream out(dir / "cmdline", std::ios::binary);
        for (const auto& arg : argv)
        {
            out.write(arg.data(), static_cast<std::streamsize>(arg.size()));
            out.put('\0');
        }
        return dir / "cmdline";
    }

  private:
    std::filesystem::path m_root;
};

/// A bmv2 pipeline artifact carrying exactly the two tables the northbound writes into, at
/// whatever sizes the caller asks for. Deliberately not 1024; see the file header.
json
artifactWith(long long ipv4LpmSize, long long fiveTupleSize)
{
    return json{{"pipelines",
                 json::array({json{{"name", "ingress"},
                                   {"tables",
                                    json::array({
                                        json{{"name", "tbl_ndtwin_switch386"},
                                             {"match_type", "exact"},
                                             {"max_size", 1024}},
                                        json{{"name", ofcapacity::kFiveTupleTable},
                                             {"match_type", "ternary"},
                                             {"max_size", fiveTupleSize}},
                                        json{{"name", ofcapacity::kFlowEntryTable},
                                             {"match_type", "lpm"},
                                             {"max_size", ipv4LpmSize}},
                                    })}},
                              json{{"name", "egress"}, {"tables", json::array()}}})}};
}

/// The table view `get_switch_openflow_table_entries` serves, with `rows` rows on `dpid`.
json
tableViewWith(uint64_t dpid, int rows)
{
    json flows = json::array();
    for (int i = 0; i < rows; ++i)
    {
        flows.push_back(json{{"table_id", 0}, {"priority", 0}, {"match", json::object()}});
    }
    return json::array({json{{"dpid", dpid}, {"flows", {{std::to_string(dpid), flows}}}}});
}

/// The three brands the shipped catalogue carries, trimmed to what these tests read.
json
vendorCatalogue()
{
    return json{{"OVS", {{"tables", json::array({json{{"id", 0}, {"max_entries", 1000000}}})}}},
                {"BrocadeICX7250",
                 {{"tables", json::array({json{{"id", 0}, {"max_entries", 3072}}})}}},
                {"HPE5520", {{"tables", json::array({json{{"id", 0}, {"max_entries", 65535}}})}}}};
}

/**
 * A const-safe read of an optional key.
 *
 * [Co-developed with claude code -- Adam]
 * 🔴 nlohmann's **const** `operator[]` on a missing key trips `JSON_ASSERT` and **aborts the
 * process** -- this build has no NDEBUG. A mutant that aborts prints no `[  FAILED  ]` line at
 * all, so the mutation gate can only score it as a SURVIVOR: the assertion that was supposed to
 * catch it looks exactly like an assertion nobody wrote. Mutations 9 and 12 of
 * tests/shell/mutate_capacity_reads_running_artifact.sh did precisely that on the first run --
 * they strip `source`, and `report["OVS"]["source"]` then killed the binary instead of failing.
 * Every optional read in this file goes through here so that a missing key is a red test.
 */
json at(const json& j, const std::string& key)
{
    return j.is_object() && j.contains(key) ? j.at(key) : json();
}

ofcapacity::ArtifactSource
sourceNamed(const std::string& path)
{
    ofcapacity::ArtifactSource src;
    src.path = path;
    src.how = "test fixture";
    return src;
}

} // namespace

// =====================================================================================
// The ceiling is READ, not known
// =====================================================================================

/**
 * The whole point of W17, in one assertion pair.
 *
 * WHICH LINE MAKES THIS RED: any constant in place of the artifact read --
 * `plane["max_entries"] = 1024;` in buildBmv2Plane, or a pipelineTableSizes that answers a fixed
 * map. Both fixtures below then report the same number and one of the two expectations fails.
 */
TEST(OpenflowCapacityTest, TheCeilingIsWhateverTheRunningPipelineSays)
{
    const auto small = ofcapacity::buildBmv2Plane({1}, sourceNamed("/x/small.json"),
                                                  artifactWith(512, 512), {{1, 0}});
    const auto large = ofcapacity::buildBmv2Plane({1}, sourceNamed("/x/large.json"),
                                                  artifactWith(2048, 2048), {{1, 0}});

    EXPECT_EQ(small["max_entries"], 512) << small.dump();
    EXPECT_EQ(large["max_entries"], 2048) << large.dump();
    EXPECT_EQ(small["per_switch"][0]["max_entries"], 512) << small.dump();
    EXPECT_EQ(large["per_switch"][0]["max_entries"], 2048) << large.dump();
}

/// The two writable tables are reported separately: a caller installing 5-tuple rules is
/// spending a different budget from one installing plain destination routes.
TEST(OpenflowCapacityTest, BothWritableTablesCarryTheirOwnCeiling)
{
    const auto plane = ofcapacity::buildBmv2Plane({1}, sourceNamed("/x/p.json"),
                                                  artifactWith(512, 2048), {{1, 0}});

    ASSERT_EQ(plane["tables"].size(), 2u) << plane.dump();
    EXPECT_EQ(plane["tables"][0]["name"], ofcapacity::kFlowEntryTable);
    EXPECT_EQ(plane["tables"][0]["max_entries"], 512);
    EXPECT_EQ(plane["tables"][1]["name"], ofcapacity::kFiveTupleTable);
    EXPECT_EQ(plane["tables"][1]["max_entries"], 2048);
    // The headline number is the flow-entry table's, not the largest one on the chip.
    EXPECT_EQ(plane["max_entries"], 512) << plane.dump();
}

/// An artifact that cannot be parsed, or one whose pipeline was renamed, must not produce a
/// number. This is the assertion that stops "read it, and if that fails use 1024".
TEST(OpenflowCapacityTest, AnUnreadableArtifactRefusesToGuess)
{
    const auto missing = ofcapacity::buildBmv2Plane({1}, sourceNamed("/x/p.json"), json(),
                                                    {{1, 42}});
    EXPECT_TRUE(missing["max_entries"].is_null()) << missing.dump();
    EXPECT_TRUE(missing["per_switch"][0]["available"].is_null()) << missing.dump();
    EXPECT_EQ(missing["per_switch"][0]["in_use"], 42) << "what IS known must still be reported";
    EXPECT_FALSE(missing.value("why", "").empty()) << "a null number must say why";

    const auto renamed = ofcapacity::buildBmv2Plane(
        {1}, sourceNamed("/x/p.json"),
        json{{"pipelines", json::array({json{{"name", "ingress"},
                                             {"tables", json::array({json{{"name", "SomethingElse"},
                                                                          {"max_size", 4096}}})}}})}},
        {{1, 0}});
    EXPECT_TRUE(renamed["max_entries"].is_null())
        << "a table this proxy does not write into is not this endpoint's ceiling: "
        << renamed.dump();
}

// =====================================================================================
// in_use and available
// =====================================================================================

TEST(OpenflowCapacityTest, AvailableIsTheCeilingMinusWhatTheSwitchReports)
{
    const auto plane = ofcapacity::buildBmv2Plane({7}, sourceNamed("/x/p.json"),
                                                  artifactWith(512, 512), {{7, 128}});

    ASSERT_EQ(plane["per_switch"].size(), 1u) << plane.dump();
    EXPECT_EQ(plane["per_switch"][0]["dpid"], 7);
    EXPECT_EQ(plane["per_switch"][0]["in_use"], 128);
    EXPECT_EQ(plane["per_switch"][0]["available"], 384) << plane.dump();
}

/**
 * A switch nothing has polled yet reports **unknown**, never zero.
 *
 * WHICH LINE MAKES THIS RED: defaulting the lookup (`rows.count(dpid) ? rows.at(dpid) : 0`).
 * "You have all 512 free" about a switch this kernel has never read is the same confident wrong
 * number the whole endpoint was rewritten to stop producing.
 */
TEST(OpenflowCapacityTest, ASwitchNothingHasPolledYetIsUnknownNotEmpty)
{
    const auto plane = ofcapacity::buildBmv2Plane({1, 2}, sourceNamed("/x/p.json"),
                                                  artifactWith(512, 512), {{1, 10}});

    ASSERT_EQ(plane["per_switch"].size(), 2u) << plane.dump();
    EXPECT_EQ(plane["per_switch"][0]["in_use"], 10);
    EXPECT_TRUE(plane["per_switch"][1]["in_use"].is_null()) << plane.dump();
    EXPECT_TRUE(plane["per_switch"][1]["available"].is_null()) << plane.dump();
    EXPECT_FALSE(plane["per_switch"][1].value("why", "").empty());
}

TEST(OpenflowCapacityTest, RowsAreCountedAcrossEveryTableTheViewLists)
{
    const json view = json::array({json{{"dpid", 3},
                                        {"flows",
                                         {{"3", json::array({json{{"table_id", 0}},
                                                             json{{"table_id", 0}}})},
                                          {"other", json::array({json{{"table_id", 1}}})}}}}});

    const auto rows = ofcapacity::rowsPerDpid(view);
    ASSERT_EQ(rows.count(3), 1u);
    EXPECT_EQ(rows.at(3), 3);
}

TEST(OpenflowCapacityTest, AMalformedViewCountsNothingRatherThanThrowing)
{
    EXPECT_TRUE(ofcapacity::rowsPerDpid(json("not an array")).empty());
    EXPECT_TRUE(ofcapacity::rowsPerDpid(json::array({json{{"no_dpid", 1}}})).empty());
    EXPECT_TRUE(ofcapacity::rowsPerDpid(json::array({json{{"dpid", 5}}})).at(5) == 0);
}

// =====================================================================================
// Provenance: which artifact, and how we know
// =====================================================================================

TEST(OpenflowCapacityArgvTest, ThePipelineIsFoundEvenThoughItIsNotTheLastArgument)
{
    // The real shape, from p4_proxy/mininet/p4_testbed_topo.py: the artifact is the last
    // POSITIONAL argument of bmv2 itself, and four more arguments follow it for the gRPC target.
    const std::vector<std::string> argv = {"/usr/local/bmv2-fast/bin/simple_switch_grpc",
                                           "-i", "1@s1-eth1",
                                           "--thrift-port", "9091",
                                           "--device-id", "1",
                                           "/home/adam/p4_src/build/ndtwin_switch.json",
                                           "--",
                                           "--grpc-server-addr", "0.0.0.0:9559",
                                           "--cpu-port", "255"};
    const auto found = ofcapacity::pipelineJsonInArgv(argv);
    ASSERT_TRUE(found.has_value());
    EXPECT_EQ(*found, "/home/adam/p4_src/build/ndtwin_switch.json");
}

/**
 * The LAST `.json`, not the first.
 *
 * bmv2 takes `--restore-state <file>`, so an option value ahead of the pipeline can be a .json
 * too. Taking the first one would then report a saved-state file as the running pipeline --
 * a path that exists, parses as JSON, and has no tables in it at all.
 */
TEST(OpenflowCapacityArgvTest, TheLastJsonWinsWhenAnOptionValueIsAlsoAJsonFile)
{
    const std::vector<std::string> argv = {"/usr/local/bin/simple_switch_grpc",
                                           "--restore-state", "/tmp/s1-state.json",
                                           "--device-id", "1",
                                           "/p4/build/ndtwin_switch.json",
                                           "--", "--grpc-server-addr", "0.0.0.0:9559"};
    const auto found = ofcapacity::pipelineJsonInArgv(argv);
    ASSERT_TRUE(found.has_value());
    EXPECT_EQ(*found, "/p4/build/ndtwin_switch.json");
}

TEST(OpenflowCapacityArgvTest, APlainSimpleSwitchCountsAndSoDoesALocalBuild)
{
    EXPECT_TRUE(ofcapacity::isBmv2Argv0("simple_switch"));
    EXPECT_TRUE(ofcapacity::isBmv2Argv0("/usr/local/bin/simple_switch_grpc"));
    EXPECT_TRUE(ofcapacity::isBmv2Argv0("/usr/local/bmv2-fast/bin/simple_switch_grpc"));
    EXPECT_FALSE(ofcapacity::isBmv2Argv0("/usr/bin/python3"));
    EXPECT_FALSE(ofcapacity::isBmv2Argv0(""));
}

/// A process that merely *mentions* a pipeline JSON is not a switch running one. The proxy agent
/// and the P4 compiler both have that path on their command lines.
TEST(OpenflowCapacityArgvTest, AProcessThatMerelyNamesTheArtifactIsNotASwitch)
{
    EXPECT_FALSE(ofcapacity::pipelineJsonInArgv(
                     {"/usr/bin/python3", "proxy_agent.py", "/p4/build/ndtwin_switch.json"})
                     .has_value());
    EXPECT_FALSE(ofcapacity::pipelineJsonInArgv({"/usr/local/bin/simple_switch_grpc"}).has_value())
        << "a switch with no artifact on its command line names no artifact";
}

TEST(OpenflowCapacityArgvTest, ArgvIsSplitOnNulAndTrailingNulsAreNotArguments)
{
    const std::string raw("simple_switch\0--device-id\0" "0\0/p/x.json\0", 38);
    const auto argv = ofcapacity::splitNulSeparated(raw);
    ASSERT_EQ(argv.size(), 4u);
    EXPECT_EQ(argv[0], "simple_switch");
    EXPECT_EQ(argv[3], "/p/x.json");
}

/**
 * The artifact comes from a running switch's own argv.
 *
 * WHICH LINE MAKES THIS RED: reading a repository path directly instead of walking `procRoot`.
 * The fixture's switch names `/fixture/running.json`, which exists nowhere on disk -- so any
 * implementation that answers with a path of its own choosing fails here.
 */
TEST(OpenflowCapacityProcTest, TheArtifactIsTheOneARunningSwitchHasLoaded)
{
    TempTree proc("proc");
    proc.fakeProcess("1", {"/sbin/init", "splash"});
    proc.fakeProcess("4242", {"/usr/local/bin/simple_switch_grpc", "--device-id", "0",
                              "/fixture/running.json"});
    TempTree build("build");
    const auto fallback = build.write("ndtwin_switch.json", artifactWith(2048, 2048).dump());

    const auto src = ofcapacity::locateRunningPipeline(proc.root().string(), fallback.string());

    EXPECT_EQ(src.path, "/fixture/running.json") << "how: " << src.how;
    EXPECT_NE(src.how.find("running"), std::string::npos) << src.how;
    EXPECT_TRUE(src.disagreeing.empty());
}

/// With nothing running, the build artifact is read -- and the answer says which claim it is
/// making. "What a switch would load" and "what a switch has loaded" are different facts.
TEST(OpenflowCapacityProcTest, WithNothingRunningTheBuildArtifactIsUsedAndLabelled)
{
    TempTree proc("proc");
    proc.fakeProcess("1", {"/sbin/init"});
    proc.fakeProcess("77", {"/usr/bin/python3", "proxy_agent.py"});
    TempTree build("build");
    const auto fallback = build.write("ndtwin_switch.json", artifactWith(512, 512).dump());

    const auto src = ofcapacity::locateRunningPipeline(proc.root().string(), fallback.string());

    EXPECT_EQ(src.path, fallback.string());
    EXPECT_NE(src.how.find("build artifact"), std::string::npos) << src.how;
}

TEST(OpenflowCapacityProcTest, WithNothingRunningAndNoBuildArtifactNothingIsClaimed)
{
    TempTree proc("proc");
    proc.fakeProcess("1", {"/sbin/init"});

    const auto src = ofcapacity::locateRunningPipeline(proc.root().string(),
                                                       "/nonexistent/ndtwin_switch.json");
    EXPECT_TRUE(src.path.empty());

    const auto plane = ofcapacity::buildBmv2Plane({1}, src, json(), {{1, 3}});
    EXPECT_TRUE(plane["source"].is_null()) << plane.dump();
    EXPECT_TRUE(plane["max_entries"].is_null()) << plane.dump();
    EXPECT_FALSE(plane.value("why", "").empty());
}

/// Half the fabric on one pipeline and half on another is a fact an operator has to be told,
/// because every number below it then describes only one half.
TEST(OpenflowCapacityProcTest, SwitchesOnDifferentPipelinesAreReportedAsADisagreement)
{
    TempTree proc("proc");
    proc.fakeProcess("10", {"/usr/local/bin/simple_switch_grpc", "/a/one.json"});
    proc.fakeProcess("11", {"/usr/local/bin/simple_switch_grpc", "/b/two.json"});

    const auto src = ofcapacity::locateRunningPipeline(proc.root().string(), "");
    EXPECT_EQ(src.path, "/a/one.json") << "the answer must not depend on readdir order";
    ASSERT_EQ(src.disagreeing.size(), 1u);
    EXPECT_EQ(src.disagreeing[0], "/b/two.json");

    const auto plane = ofcapacity::buildBmv2Plane({1}, src, artifactWith(512, 512), {{1, 0}});
    EXPECT_FALSE(plane.value("why", "").empty()) << plane.dump();
    EXPECT_EQ(plane["source_disagreement"][0], "/b/two.json") << plane.dump();
}

// =====================================================================================
// The whole report
// =====================================================================================

TEST(OpenflowCapacityReportTest, TheVendorRowsSayTheyAreACatalogueAndKeepTheirNumbers)
{
    const auto report = ofcapacity::buildCapacityReport(vendorCatalogue(), {1},
                                                        sourceNamed("/x/p.json"),
                                                        artifactWith(512, 512),
                                                        tableViewWith(1, 4));

    for (const char* brand : {"OVS", "BrocadeICX7250", "HPE5520"})
    {
        ASSERT_TRUE(report.contains(brand)) << report.dump();
        EXPECT_EQ(at(at(report, brand), "source"), "vendor table")
            << brand << " must say nobody measured it here: " << report.dump();
    }
    EXPECT_EQ(at(at(report, "OVS"), "tables")[0]["max_entries"], 1000000)
        << "the catalogue's own numbers must survive untouched: " << report.dump();
    EXPECT_EQ(at(at(report, "BrocadeICX7250"), "tables")[0]["max_entries"], 3072);
}

TEST(OpenflowCapacityReportTest, TheBmv2BlockAppearsOnlyWhenTheTopologyHasBmv2Switches)
{
    const auto ovsOnly = ofcapacity::buildCapacityReport(vendorCatalogue(), {},
                                                         sourceNamed("/x/p.json"),
                                                         artifactWith(512, 512), json::array());
    EXPECT_FALSE(ovsOnly.contains("bmv2"))
        << "an OVS-only deployment has no bmv2 plane to describe: " << ovsOnly.dump();

    const auto p4 = ofcapacity::buildCapacityReport(vendorCatalogue(), {1},
                                                    sourceNamed("/x/p.json"),
                                                    artifactWith(512, 512), tableViewWith(1, 4));
    ASSERT_TRUE(p4.contains("bmv2")) << p4.dump();
    EXPECT_EQ(p4["bmv2"]["plane"], "bmv2");
    EXPECT_EQ(p4["bmv2"]["max_entries"], 512);
    EXPECT_EQ(p4["bmv2"]["per_switch"][0]["in_use"], 4);
    EXPECT_EQ(p4["bmv2"]["per_switch"][0]["available"], 508);
}

/// The `source` string has to name the file, or "provenance" is a word rather than a fact.
TEST(OpenflowCapacityReportTest, TheSourceNamesTheFileTheNumberWasReadFrom)
{
    const auto plane = ofcapacity::buildBmv2Plane({1}, sourceNamed("/some/where/pipeline.json"),
                                                  artifactWith(512, 512), {{1, 0}});
    EXPECT_NE(at(plane, "source").dump().find("/some/where/pipeline.json"), std::string::npos)
        << plane.dump();
}

// =====================================================================================
// End to end over the filesystem
// =====================================================================================

/**
 * readCapacityReport: catalogue off disk, artifact off a running switch's argv, in one call.
 *
 * The fixture pipeline says 512 and the fixture switch is the only one in the fixture `procRoot`,
 * so this run's answer cannot be borrowed from the laptop's real process table or from the
 * repository's own compiled artifact -- either of which would say 1024.
 */
TEST(OpenflowCapacityReadTest, TheReportIsAssembledFromTheFilesTheSourcesNameAndNoOthers)
{
    TempTree tree("read");
    const auto cataloguePath = tree.write("doc/capacity.json", vendorCatalogue().dump());
    const auto pipelinePath = tree.write("p4/ndtwin_switch.json", artifactWith(512, 2048).dump());
    tree.fakeProcess("31337", {"/usr/local/bin/simple_switch_grpc", "--device-id", "0",
                               pipelinePath.string()});

    ofcapacity::CapacitySources sources;
    sources.vendorCataloguePath = cataloguePath.string();
    sources.procRoot = tree.root().string();
    sources.pipelineFallback = "/nonexistent/ndtwin_switch.json";

    const auto report = ofcapacity::readCapacityReport(sources, {1, 2}, tableViewWith(1, 100));

    EXPECT_EQ(at(at(report, "OVS"), "source"), "vendor table") << report.dump();
    ASSERT_TRUE(report.contains("bmv2")) << report.dump();
    EXPECT_EQ(report["bmv2"]["max_entries"], 512) << report.dump();
    EXPECT_NE(at(at(report, "bmv2"), "source").dump().find(pipelinePath.string()),
              std::string::npos)
        << report.dump();
    EXPECT_EQ(report["bmv2"]["per_switch"][0]["available"], 412);
    EXPECT_TRUE(report["bmv2"]["per_switch"][1]["in_use"].is_null())
        << "dpid 2 was never polled: " << report.dump();
}

/// A missing catalogue must not take the bmv2 numbers down with it. Before W17 the handler
/// returned an empty 200 in this case; the plane it can still describe is worth serving.
TEST(OpenflowCapacityReadTest, AMissingCatalogueStillLeavesTheBmv2PlaneAnswerable)
{
    TempTree tree("nocat");
    const auto pipelinePath = tree.write("p4/ndtwin_switch.json", artifactWith(2048, 2048).dump());
    tree.fakeProcess("31338", {"/usr/local/bin/simple_switch_grpc", pipelinePath.string()});

    ofcapacity::CapacitySources sources;
    sources.vendorCataloguePath = (tree.root() / "doc" / "absent.json").string();
    sources.procRoot = tree.root().string();
    sources.pipelineFallback = "";

    const auto report = ofcapacity::readCapacityReport(sources, {1}, tableViewWith(1, 1));

    EXPECT_FALSE(report.contains("OVS"));
    ASSERT_TRUE(report.contains("bmv2")) << report.dump();
    EXPECT_EQ(report["bmv2"]["max_entries"], 2048);
}

// =====================================================================================
// The endpoint: is any of the above actually wired to /ndt/get_openflow_capacity?
// =====================================================================================
//
// [Co-developed with claude code -- Adam]
// Everything before this point could be perfectly correct while the handler still dumps the
// vendor file verbatim -- "decided correctly, connected to nothing" is a shape this repository
// has paid for more than once, so the endpoint gets asserted through the real routing table
// rather than through the helpers it is supposed to call.

/**
 * @brief Drives HttpSession::buildResponse() for the capacity endpoint.
 *
 * A fifth named peer for the same reason the second, third and fourth exist: `friend class` names
 * one class, that class must be defined once across the whole binary, and four other test files
 * already claim the other four names.
 */
class HttpSessionCapacityTestPeer
{
  public:
    explicit HttpSessionCapacityTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  std::make_shared<EventBus>(),
                                                  utils::MININET,
                                                  nullptr,   // FlowLinkUsageCollector
                                                  nullptr,   // FlowRoutingManager
                                                  nullptr,   // DeviceConfig...PowerManager
                                                  nullptr,   // ApplicationManager
                                                  nullptr,   // SimulationRequestManager
                                                  nullptr,   // IntentTranslator
                                                  nullptr,   // HistoricalDataManager
                                                  nullptr,   // Controller
                                                  nullptr))  // LockManager
    {
    }

    /// Points the handler at fixture files instead of the deployment's own.
    void useSources(const ofcapacity::CapacitySources& sources)
    {
        m_session->m_capacitySources = sources;
    }

    const http::response<http::string_body>& get(const std::string& target)
    {
        m_session->m_req = {};
        m_session->m_req.version(11);
        m_session->m_req.method(http::verb::get);
        m_session->m_req.target(target);
        m_session->m_req.prepare_payload();
        m_response = m_session->buildResponse();
        return *m_response;
    }

  private:
    boost::asio::io_context m_ioc; // declared first: the socket is constructed from it
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

/// Exposes the protected static-topology loader, so the session can be given a monitor that
/// knows which of its switches are bmv2 without any Ryu or proxy REST call.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    TestableMonitor(std::shared_ptr<Graph> g,
                    std::shared_ptr<std::shared_mutex> m,
                    std::shared_ptr<EventBus> bus,
                    int mode)
        : TopologyAndFlowMonitor(std::move(g), std::move(m), std::move(bus), mode)
    {
    }

    using TopologyAndFlowMonitor::loadStaticTopologyFromFile;
};

/// One switch node in the shape loadStaticTopologyFromFile expects, in MININET mode.
std::string
switchNode(uint64_t dpid, const std::string& brandName)
{
    return R"({
      "vertex_type": 0,
      "mac": 0,
      "ip": ["192.168.123.)" + std::to_string(10 + dpid) + R"("],
      "dpid": )" + std::to_string(dpid) + R"(,
      "device_name": "s)" + std::to_string(dpid) + R"(",
      "nickname": "",
      "brand_name": ")" + brandName + R"(",
      "bridge_name": "s)" + std::to_string(dpid) + R"(",
      "device_layer": 1,
      "ecmp_groups": []
    })";
}

class CapacityEndpointTest : public ::testing::Test
{
  protected:
    /// Logger::instance() is a null shared_ptr until init runs and the handler logs, so this must
    /// happen in THIS suite -- ctest gives every test its own process, and a suite that borrows
    /// another one's initialisation passes in a full run and crashes when run alone.
    /// Logger::init is idempotent.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    /// A monitor whose topology is `nodes`, written into `tree`.
    std::shared_ptr<TestableMonitor> monitorWith(const TempTree& tree, const std::string& nodes)
    {
        const auto path = tree.write("topology.json",
                                     "{\n  \"nodes\": [\n" + nodes + "\n  ],\n  \"edges\": []\n}\n");
        auto monitor = std::make_shared<TestableMonitor>(std::make_shared<Graph>(),
                                                         std::make_shared<std::shared_mutex>(),
                                                         std::make_shared<EventBus>(),
                                                         utils::DeploymentMode::MININET);
        monitor->loadStaticTopologyFromFile(path.string());
        return monitor;
    }
};

} // namespace

/**
 * The endpoint answers with the running pipeline's ceiling, not with the catalogue.
 *
 * WHICH LINE MAKES THIS RED: the trunk handler --
 * `std::ifstream file("../doc/2026-01-02_OpenflowCapacity.json"); ... res.body() = j.dump();`
 * The fixture catalogue has no `bmv2` key and no `source` anywhere in it, so a handler that
 * serves the file verbatim fails both assertions below.
 */
TEST_F(CapacityEndpointTest, TheEndpointReportsTheRunningPipelineAndNotJustTheCatalogue)
{
    TempTree tree("endpoint");
    const auto cataloguePath = tree.write("catalogue.json", vendorCatalogue().dump());
    const auto pipelinePath = tree.write("pipeline/ndtwin_switch.json",
                                         artifactWith(512, 2048).dump());
    tree.fakeProcess("20001", {"/usr/local/bmv2-fast/bin/simple_switch_grpc", "--device-id", "1",
                               pipelinePath.string(), "--", "--grpc-server-addr", "0.0.0.0:9559"});

    auto monitor = monitorWith(tree, switchNode(1, "BMv2") + ",\n" + switchNode(2, "BMv2"));

    HttpSessionCapacityTestPeer peer(monitor);
    ofcapacity::CapacitySources sources;
    sources.vendorCataloguePath = cataloguePath.string();
    sources.procRoot = tree.root().string();
    sources.pipelineFallback = "/nonexistent/ndtwin_switch.json";
    peer.useSources(sources);

    const auto& res = peer.get("/ndt/get_openflow_capacity");
    ASSERT_EQ(res.result_int(), 200u) << res.body();

    const auto body = json::parse(res.body());
    ASSERT_TRUE(body.contains("bmv2")) << body.dump();
    EXPECT_EQ(at(body, "bmv2")["max_entries"], 512) << body.dump();
    EXPECT_EQ(at(at(body, "OVS"), "source"), "vendor table") << body.dump();
    EXPECT_EQ(body["bmv2"]["per_switch"].size(), 2u)
        << "both bmv2 switches in the loaded topology must be listed: " << body.dump();
}

/// An OVS-only deployment gets the catalogue, tagged, and no invented bmv2 plane. The same
/// handler, the same fixture files, one different topology.
TEST_F(CapacityEndpointTest, AnOvsOnlyTopologyGetsNoBmv2Plane)
{
    TempTree tree("endpoint_ovs");
    const auto cataloguePath = tree.write("catalogue.json", vendorCatalogue().dump());
    const auto pipelinePath = tree.write("pipeline/ndtwin_switch.json",
                                         artifactWith(512, 512).dump());
    tree.fakeProcess("20002", {"/usr/local/bin/simple_switch_grpc", pipelinePath.string()});

    auto monitor = monitorWith(tree, switchNode(1, "OVS"));

    HttpSessionCapacityTestPeer peer(monitor);
    ofcapacity::CapacitySources sources;
    sources.vendorCataloguePath = cataloguePath.string();
    sources.procRoot = tree.root().string();
    peer.useSources(sources);

    const auto& res = peer.get("/ndt/get_openflow_capacity");
    ASSERT_EQ(res.result_int(), 200u) << res.body();

    const auto body = json::parse(res.body());
    EXPECT_FALSE(body.contains("bmv2"))
        << "no switch in this topology is bmv2: " << body.dump();
    EXPECT_EQ(at(at(body, "OVS"), "source"), "vendor table") << body.dump();
    EXPECT_EQ(at(at(body, "OVS"), "tables")[0]["max_entries"], 1000000) << body.dump();
}
