/**
 * E-2 -- the kernel must say WHICH model it loaded, and say it about the bytes it read.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THIS IS FOR
 * `tools/test_workflow/run_layers.sh` picked the topology file to validate the running fabric
 * against from (data plane, live host count) and never asked the kernel. `setting/` holds more
 * than one model with the same ten dpids and the same 10 switch / 4 host / 40 edge cardinality,
 * so validating fabric A against model B was green **by construction**: every per-node identity
 * check passes because the numbers agree, and nothing in the response could say the twin was
 * describing a different network. The instrument could not know what it was testing
 * (fix/R2-PY-SUMMARY.md §7-3; DECISIONS.md, grill §4E, E-2).
 *
 * WHAT IS ASSERTED, AND WHY EACH HALF IS NEEDED
 *   1. the record exists and names the file, the digest of its BYTES, and when it was read;
 *   2. the digest is not the digest of the PATH -- a hash of the filename would look exactly
 *      like a working feature to every caller that only checks the field is present, and would
 *      answer the one question it exists for ("has this file changed?") with a permanent no;
 *   3. the record does NOT follow the file. Editing the model after the kernel has loaded it is
 *      the specific accident this is built to expose, so a kernel that re-read the file per
 *      request would report the edit as though it were what it is serving -- confidently wrong,
 *      and wrong in the direction that hides the fault;
 *   4. a monitor that has loaded nothing says nothing, and the endpoint then serves exactly the
 *      key set a pre-E-2 kernel serves (baseline `28b8b13`). "Absent" has to keep one meaning:
 *      the kernel did not say. A consumer meeting it must not guess;
 *   5. the three keys reach the WIRE. 1-4 hold on the monitor; a handler that never asked for
 *      the record would leave every one of them green and serve nothing.
 *
 * 🔴 THE INSTRUMENT MUST NOT BE ABLE TO PRODUCE THE ANSWER. The expected digest is computed
 * here, from bytes this file read itself, by a hasher that shares no code with the one under
 * test -- and that hasher is itself checked against the published SHA-256 vector for "abc"
 * before any of it is believed. A test that called TopologyAndFlowMonitor's own helper would
 * follow a mutation into it and stay green.
 *
 * Gate: tests/shell/mutate_kernel_reports_loaded_model.sh
 */

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <shared_mutex>
#include <string>
#include <system_error>

#include <unistd.h> // getpid, for a temp-file name no concurrent run collides with

#include <boost/graph/adjacency_list.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <openssl/sha.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Drives HttpSession::buildResponse() with nothing but a monitor.
 *
 * Global scope to match `friend class HttpSessionLoadedModelTestPeer`. Its own class rather
 * than a reuse of test_HttpSessionStatusCodes.cpp's peer for the ODR reason the header states:
 * each peer is defined in its own translation unit.
 */
class HttpSessionLoadedModelTestPeer
{
  public:
    explicit HttpSessionLoadedModelTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  nullptr,        // EventBus
                                                  utils::MININET, // mode
                                                  nullptr,        // FlowLinkUsageCollector
                                                  nullptr,        // FlowRoutingManager
                                                  nullptr,        // power manager
                                                  nullptr,        // ApplicationManager
                                                  nullptr,        // SimulationRequestManager
                                                  nullptr,        // IntentTranslator
                                                  nullptr,        // HistoricalDataManager
                                                  nullptr,        // Controller
                                                  nullptr))       // LockManager
    {
    }

    /// The body of GET /ndt/get_graph_data, parsed.
    nlohmann::json getGraphData()
    {
        m_session->m_req = {};
        m_session->m_req.version(11);
        m_session->m_req.method(http::verb::get);
        m_session->m_req.target("/ndt/get_graph_data");
        m_session->m_req.prepare_payload();

        m_response = m_session->buildResponse();
        return nlohmann::json::parse(m_response->body());
    }

  private:
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

// `json` is nlohmann::json here: HttpSession.hpp declares the alias at global scope, and
// redeclaring it in this namespace would give the same type two spellings for no gain.

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

/// The repo's `setting/` directory, wherever the binary was started from. Same three candidates
/// and the same reason as tests/test_TopologyInputValidation.cpp: ctest runs from the build
/// tree, l1_unit_tests.sh runs the binary from the repo root.
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

/// sha256 as lowercase hex. THE TEST'S OWN, sharing no line with the implementation under test.
std::string
digestOf(const std::string& bytes)
{
    unsigned char raw[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size(), raw);

    static constexpr char kDigits[] = "0123456789abcdef";
    std::string hex;
    hex.reserve(sizeof(raw) * 2);
    for (unsigned char byte : raw)
    {
        hex.push_back(kDigits[byte >> 4]);
        hex.push_back(kDigits[byte & 0x0F]);
    }
    return hex;
}

std::string
readWholeFile(const std::string& path)
{
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

/// A private copy of a shipped topology, removed on destruction. Private because case 3 edits
/// it, and the shipped file is tracked by git and read by every other suite in this binary.
class TopologyCopy
{
  public:
    explicit TopologyCopy(const std::string& tag)
    {
        const std::string dir = settingDir();
        if (dir.empty())
        {
            return;
        }
        const std::string source = dir + "/StaticNetworkTopologyP4_10Switches_4Hosts.json";
        if (!std::filesystem::exists(source))
        {
            return;
        }
        m_path = (std::filesystem::temp_directory_path() /
                  ("ndt_e2_" + tag + "_" + std::to_string(::getpid()) + ".json"))
                     .string();
        std::error_code ec;
        std::filesystem::copy_file(
            source, m_path, std::filesystem::copy_options::overwrite_existing, ec);
        if (ec)
        {
            m_path.clear();
        }
    }

    ~TopologyCopy()
    {
        if (!m_path.empty())
        {
            std::error_code ignored;
            std::filesystem::remove(m_path, ignored);
        }
    }

    TopologyCopy(const TopologyCopy&) = delete;
    TopologyCopy& operator=(const TopologyCopy&) = delete;

    bool usable() const { return !m_path.empty(); }
    const std::string& path() const { return m_path; }

    /// Appends bytes, changing the file's digest without changing what it parses to. A JSON
    /// trailing newline is semantically nothing and is exactly one byte -- so a test that then
    /// finds the digest changed has measured the digest, not the parse.
    void appendAByte() const
    {
        std::ofstream out(m_path, std::ios::binary | std::ios::app);
        out << "\n";
    }

  private:
    std::string m_path;
};

/// A monitor with the copy loaded. TESTBED rather than MININET for the reason
/// test_HttpSessionStatusCodes.cpp gives: the shipped P4 file carries no `bridge_name`, which
/// MININET mode requires and this suite has no reason to depend on.
std::shared_ptr<LoadingMonitor>
monitorLoadedWith(const std::string& path)
{
    auto monitor = std::make_shared<LoadingMonitor>(std::make_shared<Graph>(),
                                                    std::make_shared<std::shared_mutex>(),
                                                    std::make_shared<EventBus>(),
                                                    utils::TESTBED);
    monitor->load(path);
    return monitor;
}

std::int64_t
nowEpochSeconds()
{
    return static_cast<std::int64_t>(std::chrono::duration_cast<std::chrono::seconds>(
                                         std::chrono::system_clock::now().time_since_epoch())
                                         .count());
}

// --- 0. the instrument, before anything is believed ------------------------------------------
//
// The published SHA-256 test vector for "abc" (FIPS 180-4, appendix B.1). If this fails, every
// digest comparison below is comparing against an unknown quantity and none of them means
// anything -- so it is asserted first and separately rather than folded into a helper.
TEST(TopologyLoadedModel, TheTestsOwnHasherMatchesThePublishedVector)
{
    EXPECT_EQ(digestOf("abc"),
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

// --- 1. the record ----------------------------------------------------------------------------
TEST(TopologyLoadedModel, ThePathTheHashAndTheTimeAreRecordedAtLoad)
{
    const TopologyCopy copy{"record"};
    ASSERT_TRUE(copy.usable()) << "cannot find the repo's setting/ directory from "
                               << std::filesystem::current_path()
                               << " -- this test would otherwise assert over a kernel that "
                                  "loaded nothing, which is the condition case 4 exists to "
                                  "tell apart";

    const std::int64_t before = nowEpochSeconds();
    auto monitor = monitorLoadedWith(copy.path());
    const std::int64_t after = nowEpochSeconds();

    const json said = monitor->loadedTopologyJson();
    ASSERT_TRUE(said.contains("topology_file")) << said.dump();
    ASSERT_TRUE(said.contains("topology_sha256")) << said.dump();
    ASSERT_TRUE(said.contains("topology_loaded_at")) << said.dump();

    // The path, absolutised. std::filesystem::equivalent rather than string equality: /tmp is a
    // symlink on some distributions, and the claim is about which file, not which spelling.
    const auto reported = std::filesystem::path(said.at("topology_file").get<std::string>());
    EXPECT_TRUE(reported.is_absolute())
        << "a relative path cannot be resolved by a consumer that does not know the kernel's "
           "working directory: "
        << reported;
    std::error_code ec;
    EXPECT_TRUE(std::filesystem::equivalent(reported, copy.path(), ec))
        << reported << " is not " << copy.path();

    // The digest, of the bytes this test read for itself.
    EXPECT_EQ(said.at("topology_sha256").get<std::string>(), digestOf(readWholeFile(copy.path())));

    // The time. A window rather than an instant, and both ends are real assertions: `before`
    // catches a zero or an epoch-0 default, `after` catches a value from the future.
    const std::int64_t at = said.at("topology_loaded_at").get<std::int64_t>();
    EXPECT_GE(at, before);
    EXPECT_LE(at, after);
}

// --- 2. of the bytes, not of the name ---------------------------------------------------------
TEST(TopologyLoadedModel, TheHashIsOfTheFileBytesNotOfItsPath)
{
    const TopologyCopy copy{"bytes"};
    ASSERT_TRUE(copy.usable());

    auto monitor = monitorLoadedWith(copy.path());
    const std::string said =
        monitor->loadedTopologyJson().at("topology_sha256").get<std::string>();

    EXPECT_EQ(said, digestOf(readWholeFile(copy.path())));
    // Named as its own expectation because it is the mutation, not a corollary: hashing the
    // path is the cheapest way to a present-and-plausible field that can never change.
    EXPECT_NE(said, digestOf(copy.path()));
    EXPECT_NE(said, digestOf(std::filesystem::absolute(copy.path()).string()));
}

// --- 3. the record does not follow the file ---------------------------------------------------
TEST(TopologyLoadedModel, TheRecordDoesNotFollowTheFileAfterTheLoad)
{
    const TopologyCopy copy{"frozen"};
    ASSERT_TRUE(copy.usable());

    auto monitor = monitorLoadedWith(copy.path());
    const json atLoad = monitor->loadedTopologyJson();
    const std::string digestAtLoad = digestOf(readWholeFile(copy.path()));
    ASSERT_EQ(atLoad.at("topology_sha256").get<std::string>(), digestAtLoad);

    copy.appendAByte();
    const std::string digestNow = digestOf(readWholeFile(copy.path()));
    // Without this the case would pass on a file the edit failed to change, and would be
    // asserting nothing at all.
    ASSERT_NE(digestNow, digestAtLoad) << "the fixture did not manage to change the file";

    const json afterEdit = monitor->loadedTopologyJson();
    EXPECT_EQ(afterEdit.at("topology_sha256").get<std::string>(), digestAtLoad)
        << "the kernel re-read the file: it is reporting what is on disk NOW, which is the "
           "thing the consumer is trying to compare against";
    EXPECT_NE(afterEdit.at("topology_sha256").get<std::string>(), digestNow);
    EXPECT_EQ(afterEdit.at("topology_loaded_at").get<std::int64_t>(),
              atLoad.at("topology_loaded_at").get<std::int64_t>());
}

// --- 4. nothing loaded, nothing said ----------------------------------------------------------
TEST(TopologyLoadedModel, AMonitorThatHasLoadedNothingSaysNothing)
{
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            std::make_shared<EventBus>(),
                                                            utils::MININET);
    const json said = monitor->loadedTopologyJson();
    EXPECT_TRUE(said.is_object()) << said.dump();
    EXPECT_TRUE(said.empty()) << "a kernel that has loaded nothing must say nothing, not invent "
                                 "an empty path or a null digest: "
                              << said.dump();
}

// --- 5. the wire ------------------------------------------------------------------------------
TEST(TopologyLoadedModelWire, TheThreeKeysAreServedByGetGraphData)
{
    const TopologyCopy copy{"wire"};
    ASSERT_TRUE(copy.usable());

    auto monitor = monitorLoadedWith(copy.path());
    HttpSessionLoadedModelTestPeer peer{monitor};
    const json body = peer.getGraphData();

    ASSERT_TRUE(body.contains("topology_file")) << "response begins: " << body.dump().substr(0, 200);
    ASSERT_TRUE(body.contains("topology_sha256"));
    ASSERT_TRUE(body.contains("topology_loaded_at"));

    EXPECT_EQ(body.at("topology_sha256").get<std::string>(), digestOf(readWholeFile(copy.path())));
    EXPECT_EQ(body.at("topology_file").get<std::string>(),
              monitor->loadedTopologyJson().at("topology_file").get<std::string>());

    // The additive claim: the keys the fleet already reads are untouched.
    EXPECT_TRUE(body.contains("nodes"));
    EXPECT_TRUE(body.contains("edges"));
    EXPECT_FALSE(body.at("nodes").empty());
}

TEST(TopologyLoadedModelWire, AKernelWithNoTopologyServesTheBaselineShape)
{
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            std::make_shared<EventBus>(),
                                                            utils::MININET);
    HttpSessionLoadedModelTestPeer peer{monitor};
    const json body = peer.getGraphData();

    EXPECT_FALSE(body.contains("topology_file"));
    EXPECT_FALSE(body.contains("topology_sha256"));
    EXPECT_FALSE(body.contains("topology_loaded_at"));
    EXPECT_TRUE(body.contains("nodes")) << "the response must still be a graph response";
}

} // namespace
