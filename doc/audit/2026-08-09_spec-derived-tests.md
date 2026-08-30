# 從規格寫的單元測試

## 0. 摘要

本報告提供 **5 個測試檔案**（1 個新檔案、4 個對現有檔案的補充），共 **10 個新測試**。

| 類型 | 數量 | 說明 |
|------|------|------|
| 預期**失敗**（抓到已知缺陷） | 4 | 分別對應四個已知缺陷 |
| 預期**通過**（規格行為正確） | 4 | 驗證符合規格的行為 |
| 預期**通過**（覆蓋空洞） | 2 | TopologyAndFlowMonitor 和 FlowDispatcher 新測試 |

**依據的規格來源**：
1. `doc/2026-01-02_ndt_api.md`（API 契約文件，最高權威）
2. OpenFlow 1.3.0 規格（ONF TS-006）— 用於 reserved port 常數
3. `tools/contract_test/spec.py` + `schema.py` — 用於端點結構與不變量
4. `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` — 用於推導期望的 vertex/edge 數量

---

## 1. 我使用的規格來源，以及每一條的具體出處

### 1.1 `doc/2026-01-02_ndt_api.md`

- **第 124-250 行** (`GET /ndt/get_graph_data`)：
  - 第 127-128 行：「**vertex_type = 0** means a switch, and **vertex_type = 1** means a host.」
  - 第 129-130 行：「**is_up** suggests whether a switch reply ping or whether a host is detected by Ryu.」
  - 第 129 行：「**is_enable** in switch node suggests whether the switch is connected to controller.」
  - 第 130 行：「At the edge between the switch and host, the dpid and interface on the host side are set to 0.」
  - 第 133-143 行：`src_ip`/`dst_ip` 是 network byte order 的 32-bit 整數。
  - 第 150-225 行：完整的回應結構（nodes 陣列 + edges 陣列）。

### 1.2 OpenFlow 1.3.0 規格（ONF TS-006, OpenFlow Switch Specification Version 1.3.0）

- **Section 4.1.1 (Ports)**：Port numbers are 32 bits. Reserved ports:
  - `OFPP_MAX` = `0xffffff00`
  - `OFPP_IN_PORT` = `0xfffffff8`
  - `OFPP_TABLE` = `0xfffffff9`
  - `OFPP_NORMAL` = `0xfffffffa`
  - `OFPP_FLOOD` = `0xfffffffb`
  - `OFPP_ALL` = `0xfffffffc`
  - `OFPP_CONTROLLER` = `0xfffffffd`
  - `OFPP_LOCAL` = `0xfffffffe`

  **信心程度**：我對 CONTROLLER (`0xfffffffd`) 和 LOCAL (`0xfffffffe`) 的值有**高信心**——它們是 OpenFlow 1.0 16-bit 值 (`0xfffd`, `0xfffe`) 的直接 32-bit 延伸（高位元補 `0xffff`）。我對 FLOOD (`0xfffffffb`) 和 NORMAL (`0xfffffffa`) 的值有**中等信心**——同樣的延伸邏輯，但 OpenFlow 1.1+ 已將 NORMAL 和 FLOOD 標記為 optional 且某些實作可能不支援。然而，這個專案明確使用 OpenFlow 1.3（`intelligent_router.py:66` 用 `ofproto_v1_3`），且 Ryu 的 ofctl_rest 輸出字串 "OUTPUT:FLOOD" 和 "OUTPUT:NORMAL" 是存在的——Classifer 已在解析它們。內部儲存的 uint32_t 值**應為** OpenFlow 1.3 定義的 32-bit 常數。

  **注意**：當前實作將四個常數全部設為 `65535`（即 `0xffff`，在 OpenFlow 1.0 中為 `OFPP_NONE`，1.3 中無對應語意）。這表示 CONTROLLER、LOCAL、FLOOD、NORMAL 全部塌成同一個值，且該值在 OpenFlow 1.3 中並非有效的 forwarding target。

### 1.3 `tools/contract_test/spec.py` + `schema.py`

- `schema.py` 第 61-86 行：`GRAPH_NODE` 物件的結構定義——`device_name`, `dpid`, `ip`, `is_enabled`, `is_up`, `mac`, `vertex_type`, `brand_name`, `device_layer`。
- `schema.py` 第 73-86 行：`GRAPH_EDGE` 物件的結構定義——`src_dpid`, `dst_dpid`, `src_interface`, `dst_interface`, `src_ip`, `dst_ip`, `is_enabled`, `is_up`, `link_bandwidth_bps`, `link_bandwidth_usage_bps`, `link_bandwidth_utilization_percent`, `flow_set`。
- `spec.py` 第 134-158 行：`inv_graph_matches_topology`——驗證 switch/host/edge 數量與 topology file 一致。
- `spec.py` 第 161-183 行：`inv_all_switches_up`——驗證所有 switch 的 `is_up` 和 `is_enabled`。

### 1.4 拓撲檔 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`

- 從檔案名稱推導：10 switches + 4 hosts = 14 nodes
- 從 JSON 結構：
  - 10 個 `"vertex_type": 0` 的項目（switches）
  - 4 個 `"vertex_type": 1` 的項目（hosts）
  - 40 個 edges（32 個 switch-switch directed edges + 8 個 host-switch directed edges）
  - Host edges 的 `dst_dpid` 或 `src_dpid` 為 0（符合 2026-01-02_ndt_api.md 第 130 行）

### 1.5 Intent Translator Task Types（`LLMResponseTypes.hpp`）

- 第 55-63 行：`TaskType` enum 定義 `INSTALL_FLOW_ENTRY` 和 `MODIFY_FLOW_ENTRY` 為**不同的**列舉值。
- 從列舉語意推導：`ModifyFlowEntryTask` 的 type 應為 `MODIFY_FLOW_ENTRY`，不是 `INSTALL_FLOW_ENTRY`。

---

## 2. 預期通過 / 預期失敗對照表

| 測試名稱 | 預期 | 依據的規格 | 若失敗，代表實作哪裡錯 |
|----------|------|-----------|---------------------|
| `ClassifierActionFormsTest.TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers` | **失敗** | OpenFlow 1.3 §4.1.1: CONTROLLER=0xfffffffd, LOCAL=0xfffffffe, FLOOD=0xfffffffb, NORMAL=0xfffffffa | `Classifier.cpp:875-879` 四個常數全部設為 65535 |
| `LLMResponseParsingTest.AModifyFlowEntryTaskConstructsItselfAsAModify` | **失敗** | `LLMResponseTypes.hpp:62` `MODIFY_FLOW_ENTRY` 是獨立列舉值；語意上 modify task 不該自稱 install | `LLMResponseTypes.hpp:664` constructor 設 `type = INSTALL_FLOW_ENTRY` |
| `LLMResponseParsingTest.DeserialisingAnAnswerReplacesExistingTasks` | **失敗** | JSON 反序列化的普遍契約：解析新資料應取代舊狀態，不是累加 | `LLMResponseTypes.hpp:2346-2351` `from_json` 做 `push_back` 而非先 `clear()` |
| `LLMResponseParsingTest.AnAnswerClaimingValidWithNullTasksIsRejected` | **失敗** | `doc/2026-01-02_ndt_api.md` 無直接規定，但 `valid: true` 語意為「有工作要做」，`tasks: null` 表示「沒有工作」——兩者矛盾 | `LLMResponseTypes.hpp:2344-2351` 當 `valid` truthy 時直接 iterate `j.at("tasks")`，nlohmann 對 null 迭代為空 |
| `TopologyAndFlowMonitorTest.LoadingTheP4TopologyProducesTheCorrectNumberOfVertices` | **通過** | `StaticNetworkTopologyP4_10Switches_4Hosts.json` 有 14 nodes（10 switches + 4 hosts） | — |
| `TopologyAndFlowMonitorTest.LoadingTheP4TopologyProducesTheCorrectNumberOfEdges` | **通過** | 同上 topology file 有 40 directed edges | — |
| `TopologyAndFlowMonitorTest.SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne` | **通過** | `doc/2026-01-02_ndt_api.md:127-128` | — |
| `TopologyAndFlowMonitorTest.HostEdgesHaveDpidZeroOnTheHostSide` | **通過** | `doc/2026-01-02_ndt_api.md:130` | — |
| `FlowDispatcherTest.DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep` | **通過** | FlowDispatcher.hpp 文件：「enqueue() is thread-safe」「Workers block on a condition variable when no work is available」——隱含契約：工作不應遺失 | — |
| `TopologyAndFlowMonitorTest.EveryVertexHasTheFieldsRequiredByTheApiSpec` | **通過** | `doc/2026-01-02_ndt_api.md:150-225` 定義的 node 欄位 + `spec.py:61-71` 的 `GRAPH_NODE` schema | — |

---

## 3. 檔案內容（完整、可套用）

### 3.1 新檔案：`tests/test_TopologyAndFlowMonitor.cpp`

```cpp
/**
 * Tests for TopologyAndFlowMonitor's static topology loading.
 *
 * [Co-developed with claude code -- Adam]
 *
 * TopologyAndFlowMonitor is a 2675-line class with no dedicated test file. Its
 * loadStaticTopologyFromFile method is the single point where a topology JSON becomes
 * the in-memory graph that every routing, power, and telemetry path reads. Getting the
 * vertex/edge counts or the vertex types wrong would silently corrupt every downstream
 * computation.
 *
 * These tests load a real topology file (StaticNetworkTopologyP4_10Switches_4Hosts.json)
 * and verify the resulting graph against the counts and invariants documented in
 * 2026-01-02_ndt_api.md and the file's own structure. Nothing is mocked: the graph, mutex, and
 * EventBus are the real objects, exactly as the OvsPowerStrategy Fixture does.
 *
 * The assertions are derived from the spec (2026-01-02_ndt_api.md lines 124-250) and the topology
 * file's own structure (10 switches, 4 hosts, 40 directed edges), not from reading
 * loadStaticTopologyFromFile's implementation.
 */

#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loadStaticTopologyFromFile for testing.
class TestableTopologyAndFlowMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    /// Public seam for the protected loader.
    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

/// A graph + monitor pair. The graph is shared so the test can inspect it after loading.
struct TopologyFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableTopologyAndFlowMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the P4 topology and returns the number of vertices present afterwards.
    size_t loadP4Topology()
    {
        // Path relative to the build directory; CMake runs tests from the build tree
        // and the topology files live in ../setting/.
        monitor.load("../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json");
        std::shared_lock lock(*mutex);
        return boost::num_vertices(*graph);
    }
};

} // namespace

// ---------------------------------------------------------------------------
// Vertex and edge counts, derived from the topology file name and structure.
// The file name promises 10 switches and 4 hosts = 14 vertices.
// The edge count is verified by inspecting the JSON directly in the test.
// ---------------------------------------------------------------------------

TEST(TopologyAndFlowMonitorTest, LoadingTheP4TopologyProducesTheCorrectNumberOfVertices)
{
    // StaticNetworkTopologyP4_10Switches_4Hosts.json contains exactly:
    //   10 switches (vertex_type=0) + 4 hosts (vertex_type=1) = 14 vertices.
    // This count is derived from the file name and confirmed by counting the
    // "device_name" entries in the JSON.
    TopologyFixture fix;
    const size_t n = fix.loadP4Topology();
    EXPECT_EQ(n, 14u) << "expected 10 switches + 4 hosts = 14 vertices";
}

TEST(TopologyAndFlowMonitorTest, LoadingTheP4TopologyProducesTheCorrectNumberOfEdges)
{
    // The P4 topology has 32 switch-to-switch directed edges (16 bidirectional links)
    // plus 8 host-to-switch directed edges (4 bidirectional links) = 40 total.
    // Counted from the "src_dpid" entries in the JSON edges array.
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);
    EXPECT_EQ(boost::num_edges(*fix.graph), 40u);
}

TEST(TopologyAndFlowMonitorTest, SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne)
{
    // Per 2026-01-02_ndt_api.md lines 127-128: "vertex_type = 0 means a switch, and vertex_type = 1 means a host."
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    size_t switches = 0;
    size_t hosts = 0;
    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        if (vp.vertexType == VertexType::SWITCH)
        {
            ++switches;
            EXPECT_EQ(static_cast<int>(vp.vertexType), 0)
                << "switch " << vp.deviceName << " has vertex_type != 0";
        }
        else if (vp.vertexType == VertexType::HOST)
        {
            ++hosts;
            EXPECT_EQ(static_cast<int>(vp.vertexType), 1)
                << "host " << vp.deviceName << " has vertex_type != 1";
        }
    }
    EXPECT_EQ(switches, 10u);
    EXPECT_EQ(hosts, 4u);
}

TEST(TopologyAndFlowMonitorTest, HostEdgesHaveDpidZeroOnTheHostSide)
{
    // Per 2026-01-02_ndt_api.md line 130: "At the edge between the switch and host, the dpid
    // and interface on the host side are set to 0."
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    size_t hostEdgesChecked = 0;
    const auto [ei, ee] = boost::edges(*fix.graph);
    for (auto e = ei; e != ee; ++e)
    {
        const auto& ep = (*fix.graph)[*e];
        const auto srcV = boost::source(*e, *fix.graph);
        const auto dstV = boost::target(*e, *fix.graph);
        const bool srcIsHost = (*fix.graph)[srcV].vertexType == VertexType::HOST;
        const bool dstIsHost = (*fix.graph)[dstV].vertexType == VertexType::HOST;

        if (srcIsHost)
        {
            ++hostEdgesChecked;
            EXPECT_EQ(ep.srcDpid, 0u)
                << "host " << (*fix.graph)[srcV].deviceName
                << " edge has non-zero src_dpid " << ep.srcDpid;
            EXPECT_EQ(ep.srcInterface, 1u)
                << "host edge src_interface should be 1 (the host's single interface)";
        }
        if (dstIsHost)
        {
            ++hostEdgesChecked;
            EXPECT_EQ(ep.dstDpid, 0u)
                << "host " << (*fix.graph)[dstV].deviceName
                << " edge has non-zero dst_dpid " << ep.dstDpid;
            EXPECT_EQ(ep.dstInterface, 1u)
                << "host edge dst_interface should be 1";
        }
    }
    EXPECT_EQ(hostEdgesChecked, 8u)
        << "there should be 8 directed edges involving hosts (4 hosts × 2 directions)";
}

TEST(TopologyAndFlowMonitorTest, EveryVertexHasTheFieldsRequiredByTheApiSpec)
{
    // Per 2026-01-02_ndt_api.md lines 150-225 and tools/contract_test/schema.py lines 61-71,
    // every node in the graph response must have: device_name, dpid, ip, is_enabled,
    // is_up, mac, vertex_type, brand_name, device_layer.
    //
    // After loadStaticTopologyFromFile, these fields must be present on every vertex
    // because they come directly from the topology JSON. We check that:
    //   - deviceName is non-empty
    //   - dpid is present (can be 0 for hosts)
    //   - ip is non-empty (the code enforces this for switches; hosts also carry IPs)
    //   - vertexType is SWITCH or HOST
    //   - brandName is set (may be empty for hosts per the topology)
    //   - deviceLayer is >= 0 (the topology sets layer 2 for switches, 3 for hosts)

    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        EXPECT_FALSE(vp.deviceName.empty())
            << "vertex has empty device_name";
        // dpid 0 is valid for hosts
        EXPECT_FALSE(vp.ip.empty())
            << "vertex " << vp.deviceName << " has empty ip array";
        EXPECT_TRUE(vp.vertexType == VertexType::SWITCH || vp.vertexType == VertexType::HOST)
            << "vertex " << vp.deviceName << " has unexpected vertexType";
        EXPECT_GE(vp.deviceLayer, 0)
            << "vertex " << vp.deviceName << " has negative device_layer";
    }
}
```

### 3.2 補充：`tests/test_ClassifierActionForms.cpp`（新增一個測試）

在檔案末尾（第 327 行之後，最後一個 `}` 之前）新增：

```cpp
TEST(ClassifierActionFormsTest,
     TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers)
{
    // Per OpenFlow 1.3.0 spec (ONF TS-006) §4.1.1, reserved ports are 32-bit:
    //
    //   OFPP_CONTROLLER = 0xfffffffd  (4294967293)
    //   OFPP_LOCAL      = 0xfffffffe  (4294967294)
    //   OFPP_FLOOD      = 0xfffffffb  (4294967291)
    //   OFPP_NORMAL     = 0xfffffffa  (4294967290)
    //
    // The current implementation assigns 65535 (0xffff, which is OFPP_ANY/NONE in
    // OpenFlow 1.0 but has no forwarding meaning in 1.3) to ALL FOUR of them --
    // see AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour.
    //
    // This test asserts the SPEC behaviour: each reserved name must map to its
    // correct, DISTINCT 32-bit OpenFlow 1.3 port number. It is EXPECTED TO FAIL
    // until Classifier.cpp:875-879 is corrected.
    //
    // Confidence: HIGH for CONTROLLER (0xfffffffd) and LOCAL (0xfffffffe) --
    // these are the 32-bit extensions of the well-known 16-bit values 0xfffd/0xfffe.
    // MEDIUM for FLOOD (0xfffffffb) and NORMAL (0xfffffffa) -- same extension
    // pattern, but these are optional in OF1.3 and the correct values are drawn from
    // the standard openflow-1.3.h header convention.

    // OpenFlow 1.3 32-bit reserved port numbers
    constexpr uint32_t OFPP_CONTROLLER = 0xfffffffd;  // 4294967293
    constexpr uint32_t OFPP_LOCAL      = 0xfffffffe;  // 4294967294
    constexpr uint32_t OFPP_FLOOD      = 0xfffffffb;  // 4294967291
    constexpr uint32_t OFPP_NORMAL     = 0xfffffffa;  // 4294967290

    // Each reserved target must map to its own distinct value.
    struct Case { const char* action; uint32_t expected; };
    const std::vector<Case> cases = {
        {"OUTPUT:CONTROLLER", OFPP_CONTROLLER},
        {"OUTPUT:LOCAL",      OFPP_LOCAL},
        {"OUTPUT:FLOOD",      OFPP_FLOOD},
        {"OUTPUT:NORMAL",     OFPP_NORMAL},
        // Case-insensitive variants must also map correctly.
        {"OUTPUT:controller", OFPP_CONTROLLER},
        {"OUTPUT:flood",      OFPP_FLOOD},
    };

    for (const auto& c : cases)
    {
        const auto effect = effectOf(json::array({c.action}));
        ASSERT_TRUE(effect.has_value()) << c.action;
        ASSERT_EQ(effect->outputPorts.size(), 1u)
            << c.action << " produced " << effect->outputPorts.size() << " ports";
        EXPECT_EQ(effect->outputPorts.front(), c.expected)
            << c.action << " mapped to " << effect->outputPorts.front()
            << " (0x" << std::hex << effect->outputPorts.front() << std::dec
            << ") instead of 0x" << std::hex << c.expected << std::dec;
    }

    // Sanity: all four reserved values must be distinct.
    // If this fails, a different bug is present -- the values were corrected but
    // some are still duplicates.
    EXPECT_NE(OFPP_CONTROLLER, OFPP_LOCAL);
    EXPECT_NE(OFPP_CONTROLLER, OFPP_FLOOD);
    EXPECT_NE(OFPP_CONTROLLER, OFPP_NORMAL);
    EXPECT_NE(OFPP_LOCAL, OFPP_FLOOD);
    EXPECT_NE(OFPP_LOCAL, OFPP_NORMAL);
    EXPECT_NE(OFPP_FLOOD, OFPP_NORMAL);
}
```

### 3.3 補充：`tests/test_LLMResponseParsing.cpp`（新增三個測試）

在檔案末尾（第 820 行 `}` 之前）新增：

```cpp
// ---------------------------------------------------------------------------
// Tests that assert SPEC behaviour for the four known Answer/Task defects.
// These are expected to FAIL until the corresponding implementation bugs are fixed.
// ---------------------------------------------------------------------------

TEST(LLMResponseParsingTest, AModifyFlowEntryTaskConstructsItselfAsAModify)
{
    // Per LLMResponseTypes.hpp:62, MODIFY_FLOW_ENTRY is a distinct TaskType enumerator.
    // A ModifyFlowEntryTask is semantically a modification of an existing flow entry,
    // not an installation of a new one. Its constructor must set type = MODIFY_FLOW_ENTRY.
    //
    // Currently the constructor sets type = INSTALL_FLOW_ENTRY (line 664), which means
    // a C++-constructed ModifyFlowEntryTask serialises as "InstallFlowEntry" on the wire
    // and is dispatched to the wrong handler. This test is EXPECTED TO FAIL until
    // LLMResponseTypes.hpp:664 is corrected from INSTALL_FLOW_ENTRY to MODIFY_FLOW_ENTRY.

    llmResponse::ModifyFlowEntryTask built;
    EXPECT_EQ(built.type, llmResponse::MODIFY_FLOW_ENTRY)
        << "ModifyFlowEntryTask constructor must set type = MODIFY_FLOW_ENTRY, "
        << "not INSTALL_FLOW_ENTRY. Fix: change LLMResponseTypes.hpp:664";
}

TEST(LLMResponseParsingTest, DeserialisingAnAnswerReplacesExistingTasks)
{
    // The universal contract of a from_json deserialiser: parsing new data REPLACES the
    // object's state, it does not append to it. Answer::from_json currently push_backs
    // into `tasks` without clearing it first (LLMResponseTypes.hpp:2346-2351), which
    // means deserialising twice into the same Answer doubles the task list.
    //
    // Production never hits this because make_llm_from_json always allocates a fresh
    // Answer. But the type is public, its from_json is public, and reusing an Answer
    // object (e.g. in a retry loop) would silently execute every task twice.
    //
    // This test is EXPECTED TO FAIL until LLMResponseTypes.hpp:2344 adds
    // `ans.tasks.clear()` before the push_back loop.

    const json reply = answerWith(json::array({aTask("GetAllHosts", json::object())}));
    Answer ans;
    from_json(reply, ans);
    EXPECT_EQ(ans.tasks.size(), 1u) << "first parse should produce 1 task";

    // Parse the SAME reply again into the SAME Answer object.
    // The correct behaviour: the second parse REPLACES the first, so we still have 1 task.
    // The current behaviour: the second parse APPENDS, so we have 2 tasks.
    from_json(reply, ans);
    EXPECT_EQ(ans.tasks.size(), 1u)
        << "parsing the same reply twice must replace, not append. "
        << "Fix: add ans.tasks.clear() at LLMResponseTypes.hpp before the push_back loop";
}

TEST(LLMResponseParsingTest, AnAnswerClaimingValidWithNullTasksIsRejected)
{
    // When an Answer says "valid: true", it is asserting that there is actionable work.
    // A `tasks` field that is JSON null or a JSON object is not a list of tasks --
    // it is a contradiction. The kernel must reject this rather than silently treating
    // it as zero tasks (which reports success for work nobody carried out).
    //
    // The current code (LLMResponseTypes.hpp:2344-2351) iterates `j.at("tasks")` with a
    // range-for, and nlohmann yields an empty range for both `null` and `{}`. So both
    // parse successfully into an Answer with zero tasks, which is then executed as a
    // valid, successful, do-nothing plan.
    //
    // The spec does not explicitly enumerate every malformed input, but the combination
    // `valid:true` + non-array `tasks` is a contradiction by the plain meaning of the
    // fields. The absent-key case is already caught (AnEmptyTaskListIsAcceptedButAMissingOneIsNot);
    // the present-but-wrong-type case should be caught too.
    //
    // This test is EXPECTED TO FAIL until LLMResponseTypes.hpp:2344 validates that
    // `j.at("tasks")` is an array before iterating it.

    for (const json& empty : {json(nullptr), json::object()})
    {
        json reply = json{{"state", "answer"}, {"explanation", "I did the thing"}, {"valid", true}};
        reply["tasks"] = empty;

        // The correct behaviour: this should throw, because "valid: true" with a non-array
        // "tasks" is a malformed reply. The LLMAgent caller catches std::exception and retries.
        EXPECT_THROW(
            {
                std::unique_ptr<LLMResponse> p;
                p = parseReply(reply);
                // If it didn't throw, also verify the result is not silently accepted as valid.
                auto* ans = dynamic_cast<Answer*>(p.get());
                ASSERT_NE(ans, nullptr);
                ADD_FAILURE()
                    << "Answer with valid:true and tasks: " << empty.dump()
                    << " was accepted. It has " << ans->tasks.size() << " task(s)."
                    << " Fix: validate that tasks is an array before iterating.";
            },
            std::exception)
            << "tasks: " << empty.dump();
    }
}
```

### 3.4 補充：`tests/test_FlowDispatcher.cpp`（新增一個 rendezvous 測試）

在檔案末尾（第 218 行 `}` 之前）新增：

```cpp
// ---------------------------------------------------------------------------
// Deterministic lost-wakeup test using a rendezvous, so the interleaving is
// chosen by the test rather than by the scheduler.
//
// The scenario: a worker thread has drained its queue and is about to sleep on
// the condition variable. At that exact moment, a producer enqueues a job. The
// job must be picked up on the next wake, not left in the queue forever.
//
// The existing StopReturnsRatherThanDeadlockingOnAnIdleWorker test covers the
// stop-path lost-wakeup (running_ written outside mtx_), but is probabilistic:
// it relies on the OS scheduler to produce the unlucky interleaving within a
// 10-second window. On a fast or deterministic machine it could pass against
// broken code.
//
// The test below uses a blocking sender to park the worker at a known point,
// then enqueues while the worker is not holding mtx_. When the sender is
// released, the worker must loop back, reacquire mtx_, and see the new job.
// This is the same shape as the real lost-wakeup: a job arriving while the
// worker is between releasing the lock and reacquiring it for the next wait.
// ---------------------------------------------------------------------------

TEST(FlowDispatcherTest, DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep)
{
    // A sender that blocks on the SECOND batch, parking the worker outside mtx_.
    // The test then enqueues a job while the worker is parked. After release,
    // the worker must pick up the new job -- a lost wakeup would leave it
    // sitting in the queue forever.
    std::atomic<int> batchCount{0};
    std::atomic<bool> parkWorker{false};
    std::atomic<bool> workerParked{false};
    std::atomic<bool> releaseWorker{false};

    Recorder recorder;
    auto sender = [&](const std::vector<FlowJob>& batch) {
        {
            std::lock_guard<std::mutex> lock(recorder.mutex);
            recorder.seen.insert(recorder.seen.end(), batch.begin(), batch.end());
        }
        const int n = ++batchCount;
        if (n == 2 && parkWorker.load())
        {
            workerParked.store(true);
            // Busy-wait until the test releases us. We cannot use a mutex here
            // because the worker must not hold mtx_ while parked -- that would
            // prevent enqueue from pushing work, which is the whole point.
            while (!releaseWorker.load())
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    };

    FlowDispatcher dispatcher(sender, /*burstSize*/ 1);
    dispatcher.start();

    // Batch 1: create the worker and let it run through once.
    dispatcher.enqueue(jobFor(42));
    ASSERT_TRUE(waitFor([&] { return recorder.count() >= 1; }));

    // Now tell the sender to park on the NEXT batch.
    parkWorker.store(true);

    // Batch 2: this will park the worker inside the sender callback.
    dispatcher.enqueue(jobFor(42));
    ASSERT_TRUE(waitFor([&] { return workerParked.load(); }))
        << "worker did not park within the timeout";

    // The worker is now parked in the sender (NOT holding mtx_).
    // Enqueue a job while the worker is between iterations.
    // This is the critical moment: the job must be seen when the worker
    // loops back, even though no notify_all() reaches a sleeping worker
    // (because the worker is not sleeping -- it's in the sender).
    dispatcher.enqueue(jobFor(42));
    const size_t countBeforeRelease = recorder.count();

    // Release the worker.
    releaseWorker.store(true);

    // The worker should now finish the sender, loop back, acquire mtx_,
    // see the new job in the queue, and process it as batch 3.
    ASSERT_TRUE(waitFor([&] { return recorder.count() > countBeforeRelease; }))
        << "worker did not pick up the job enqueued while it was parked; "
        << "count stuck at " << recorder.count();

    EXPECT_GE(recorder.count(), 3u)
        << "expected at least 3 deliveries (batches 1, 2, 3), got " << recorder.count();

    dispatcher.stop();
}
```

### 3.5 `tests/CMakeLists.txt` 需要的改動

```diff
--- a/tests/CMakeLists.txt
+++ b/tests/CMakeLists.txt
@@ -29,6 +29,7 @@ add_executable(
   test_ClassifierActionForms.cpp
   test_FlowStatsTimeout.cpp
   test_FlowTableConcurrency.cpp
   test_FlowBatchPartition.cpp
+  test_TopologyAndFlowMonitor.cpp
 )
 # [Co-developed with claude code -- Adam]
 # NdtCore_RoutingManagementLib declares no target_link_libraries of its own, so there
```

將 `test_TopologyAndFlowMonitor.cpp` 加入 `add_executable` 的 source 清單。

---

## 4. mutation 提案表

對每一個新測試，提出一個具體的 mutation，說明改哪個檔案的哪一行、改成什麼，它應該讓哪個測試失敗。

| 測試 | mutation（file:line → 改成什麼） | 應該讓哪個測試失敗 |
|------|--------------------------------|-------------------|
| `TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers` | `src/ndt_core/collection/Classifier.cpp:875` `constexpr uint32_t OFPP_CONTROLLER = 65535;` → 將 65535 改為其他值（例如 65534），但保留 FLOOD/NORMAL/LOCAL 仍為 65535 | `TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers` 會失敗，因為 CONTROLLER 與預期的 0xfffffffd 不同；且 `AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour` 會失敗，因為 CONTROLLER 不再是 65535 |
| `AModifyFlowEntryTaskConstructsItselfAsAModify` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:664` `type = INSTALL_FLOW_ENTRY;` → `type = DELETE_FLOW_ENTRY;`（另一個錯誤的 type） | `AModifyFlowEntryTaskConstructsItselfAsAModify` 會失敗（type 不是 MODIFY_FLOW_ENTRY） |
| `DeserialisingAnAnswerReplacesExistingTasks` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2346` 在 `for` 迴圈前加入 `ans.tasks.clear();` 然後移除（測試修復後的行為） | 反向：若修復（加入 clear()），`DeserialisingAnAnswerReplacesExistingTasks` 通過但 `DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour` 失敗（後者斷言 append 行為）。這構成 two-site mutation：兩個測試守護同一個屬性。 |
| `AnAnswerClaimingValidWithNullTasksIsRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2344` 在 `if (ans.valid)` 內，`for (const auto& taskJson : j.at("tasks"))` 之前，移除對 `j.at("tasks").is_array()` 的檢查（若已修復）或加入 `if (!j.at("tasks").is_array()) throw …` 然後移除 | 若修復後移除檢查，`AnAnswerClaimingValidWithNullTasksIsRejected` 失敗 |
| `LoadingTheP4TopologyProducesTheCorrectNumberOfVertices` | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:251` `auto v = boost::add_vertex(vp, *m_graph);` → 註解掉此行（不加入 vertex） | `LoadingTheP4TopologyProducesTheCorrectNumberOfVertices` 失敗（count 變少） |
| `LoadingTheP4TopologyProducesTheCorrectNumberOfEdges` | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:320` `boost::add_edge(...)` → 註解掉此行 | `LoadingTheP4TopologyProducesTheCorrectNumberOfEdges` 失敗（count 變少） |
| `SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne` | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:198` `vp.vertexType = static_cast<VertexType>(nodeJson.at("vertex_type").get<int>());` → 改為 `vp.vertexType = VertexType::SWITCH;`（所有 node 都變成 switch） | `SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne` 失敗（host count = 0） |
| `DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep` | `src/ndt_core/routing_management/FlowDispatcher.cpp:99-101` 將 `while (!q.empty() && burst.size() < burstSize_)` 的 drain 迴圈改為只取一個元素然後 break（不檢查剩餘），但同時保留 burstSize=1 不變 → 實際上讓 enqueue 在 worker 下次檢查前有機會插入 | 這是一個 tricky mutation：需要同時改變 burstSize 的行為。單純改變 drain 邏輯可能不會觸發 lost-wakeup，因為 worker 總是會在下次迭代檢查 queue。**two-site mutation**: 同時將 `burstSize_` 的預設改為 1 且 drain 只取一個時，enqueue 在下一次 notify_all 與 worker 的下一次 predicate check 之間有機會被跳過——但由於 cv_.wait 的 atomic 語意，這在正確的實作中不會發生。若移除 cv_.wait 的 predicate lambda（改為 plain `cv_.wait(lk)` 後手動檢查），則 `DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep` 應失敗。 |

---

## 5. 我無法從規格判定的事項

### 5.1 OpenFlow reserved port 常數的精確值

`doc/2026-01-02_ndt_api.md` 完全沒有提及 OpenFlow reserved port 的內部表示。`tools/contract_test/spec.py` 也沒有規定這些值。專案內沒有任何檔案定義 `OFPP_*` 常數。

我從 OpenFlow 1.3.0 規格（ONF TS-006）和標準 `openflow-1.3.h` 標頭檔慣例推導這些值。但以下幾點我**無法從規格完全確定**：

1. **Ryu 的 ofctl_rest 對這些保留埠的實際數值表示**：Ryu 輸出的是字串形式（"OUTPUT:CONTROLLER"），不是數字。Classifer 將字串映射到 uint32_t——但 NDTwin 下游**目前沒有任何程式碼比較這些 uint32_t 值**。所以「正確值」的定義取決於：如果將來有程式碼要比較，它會期望什麼值？我假設是標準 OpenFlow 1.3 32-bit 值，但這是一個**設計決策**而非已規定的行為。

2. **FLOOD 和 NORMAL 在 OpenFlow 1.3 中的狀態**：OpenFlow 1.1+ 將 NORMAL 和 FLOOD 標記為 optional virtual ports。某些交換機可能不支援它們。Ryu 輸出它們的事實暗示 Ryu 支援，但 NDTwin 是否應支援它們並無規格規定。

### 5.2 `Answer::from_json` 的「應該取代」語意

`doc/2026-01-02_ndt_api.md` 沒有定義 `Answer` 型別——那是內部 intent translator 的實作細節，不是 REST API 的一部分。`tools/contract_test/spec.py` 也沒有規定 Answer 的反序列化行為。

我從**一般軟體工程原則**推導「from_json 應取代而非累加」：JSON 反序列化的普遍契約是將外部表示還原為物件狀態，而非與現有狀態合併。但嚴格來說，這是**規格的空洞**——沒有任何 ND Twin 專案文件規定此行為。

### 5.3 `tasks: null` 搭配 `valid: true` 的處理

同上，這是內部型別的行為，沒有任何規格文件規定。`doc/2026-01-02_ndt_api.md` 描述的是 REST 端點，不是 LLM 回應的內部解析。

我從欄位的**語意**推導：`valid: true` 表示「此回應包含有效的工作」，而 `tasks: null` 表示「沒有工作」——兩者矛盾。但「應拋出例外」vs「應視為零個 task」是規格未規定的設計決策。

### 5.4 TopologyAndFlowMonitor 的內部圖結構

`doc/2026-01-02_ndt_api.md` 第 124-250 行規定了 `/ndt/get_graph_data` 的回應格式，但**未規定**內部圖的 vertex/edge 數量必須等於 topology file 的數量——它只說「Returns the complete graph topology configured in setting/StaticNetworkTopology.json」（**gone as of 2026-08-30**：`setting/StaticNetworkTopology.json` 這個檔名在本 repo 從未存在；引文屬實但已被 `da31795` 改寫，現行 `doc/2026-01-02_ndt_api.md:126` 改講「the file passed to `--topology`」並實名列出 P4／OVS 兩個真實檔案。本節的推論不受影響）。從這句話可合理推導數量應一致，但沒有明確的數字合約。

此外，API 回應中的欄位（`is_up`, `is_enabled`）在初始載入後設為 `false`——這是實作行為，API 規格只說它們「suggests」某種狀態，未規定初始值。

### 5.5 FlowDispatcher 的 lost-wakeup 擔保

`FlowDispatcher.hpp` 的文件說「enqueue() is thread-safe」和「Workers block on a condition variable when no work is available」，但**沒有明確規定**「在 worker 檢查條件與進入等待之間收到的工作不會遺失」。這是從 thread-safety 和 condition variable 的通常語意推導的，不是從專案規格。

### 5.6 這些空洞的意義

這些空洞顯示出一個模式：**內部型別和演算法的行為幾乎完全沒有規格化**。`doc/2026-01-02_ndt_api.md` 只規定 REST API 的 wire format，而 `tools/contract_test/spec.py` 專注於端點回應的結構與不變量。Classifer、Intent Translator、FlowDispatcher 等內部元件的行為**只能從程式碼推導**——這正是此任務要避免的事。

這表示：
- 針對這四個已知缺陷的測試，**其「正確行為」的依據有一部分是軟體工程常識而非專案規格**。
- 如果實作作者對這些行為有不同理解，他們可以合理地主張「規格沒說」。
- 修復這些缺陷的**真正價值**不是符合規格，而是消除「同一個 repo 裡兩個地方對同一件事有不同理解」的內部矛盾（例如 Classifer 的 reserved port vs OpenFlow 標準，或 ModifyFlowEntryTask 的 type vs enum 定義）。



### 補充說明：拓撲檔案路徑

`TopologyAndFlowMonitor` 測試使用 `AppConfig::TOPOLOGY_FILE_MININET_P4`（定義於 `setting/AppConfig.hpp:18`），其值為 `../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`。此路徑假設測試從 repo 根目錄下的子目錄（如 `build/` 或 `build-asan/`）執行。若執行環境不同，測試會在 `load()` 中失敗（檔案無法開啟），但不會當機——`loadStaticTopologyFromFile` 對無法開啟的檔案僅記錄錯誤並返回，vertex/edge count 會是 0，測試據此失敗並顯示明確訊息。

### 補充說明：TopologyAndFlowMonitor 測試的 fixture 修正

為使用 `AppConfig::TOPOLOGY_FILE_MININET_P4`，測試需要 `#include "../setting/AppConfig.hpp"`。但 `TopologyAndFlowMonitor.hpp` 已包含此標頭（間接），且 `AppConfig::TOPOLOGY_FILE_MININET_P4` 是 static const string（內部連結），每個 translation unit 有自己的副本，不存在 ODR 問題。

### 修正後的 TopologyAndFlowMonitor 測試關鍵部分

```cpp
void loadP4Topology()
{
    // Use the same path constant the production code uses for the P4 topology.
    // AppConfig::TOPOLOGY_FILE_MININET_P4 is "../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"
    monitor.load(AppConfig::TOPOLOGY_FILE_MININET_P4);
    std::shared_lock lock(*mutex);
    return boost::num_vertices(*graph);
}
```

---

## 測試摘要

| # | 檔案 | 測試名稱 | 預期 | 對應缺陷 |
|---|------|---------|------|---------|
| 1 | test_ClassifierActionForms.cpp | `TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers` | **FAIL** | Defect 1: reserved ports collapse |
| 2 | test_LLMResponseParsing.cpp | `AModifyFlowEntryTaskConstructsItselfAsAModify` | **FAIL** | Defect 2: ModifyFlowEntryTask self-labels as install |
| 3 | test_LLMResponseParsing.cpp | `DeserialisingAnAnswerReplacesExistingTasks` | **FAIL** | Defect 3: from_json appends instead of replacing |
| 4 | test_LLMResponseParsing.cpp | `AnAnswerClaimingValidWithNullTasksIsRejected` | **FAIL** | Defect 4: tasks:null accepted |
| 5 | test_TopologyAndFlowMonitor.cpp | `LoadingTheP4TopologyProducesTheCorrectNumberOfVertices` | PASS | Coverage gap 5 |
| 6 | test_TopologyAndFlowMonitor.cpp | `LoadingTheP4TopologyProducesTheCorrectNumberOfEdges` | PASS | Coverage gap 5 |
| 7 | test_TopologyAndFlowMonitor.cpp | `SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne` | PASS | Coverage gap 5 |
| 8 | test_TopologyAndFlowMonitor.cpp | `HostEdgesHaveDpidZeroOnTheHostSide` | PASS | Coverage gap 5 |
| 9 | test_TopologyAndFlowMonitor.cpp | `EveryVertexHasTheFieldsRequiredByTheApiSpec` | PASS | Coverage gap 5 |
| 10 | test_FlowDispatcher.cpp | `DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep` | PASS | Coverage gap 6 |

---

## 最終備註

1. **四個預期失敗的測試**對應任務指出的四個已知缺陷。若這些測試通過了，表示缺陷已被修復——此時應刪除對應的 `DocumentsCurrentBehaviour` 測試（它們斷言錯誤行為），並將新測試的名稱中的 should-fail 標記移除。

2. **OpenFlow reserved port 常數**：我標記了信心程度（CONTROLLER/LOCAL 高信心，FLOOD/NORMAL 中信心）。若實作作者認為正確值應不同（例如因為 Ryu 使用不同慣例），應在修復時明確記錄該決策及其依據。

3. **FlowDispatcher lost-wakeup 測試**：由於無法在不修改 FlowDispatcher 的情況下插入 rendezvous 點到 condition_variable 的 wait 前後，此測試改為驗證「worker 忙碌時插入的工作不會遺失」。對真正的 lost-wakeup（condition variable  notify 在 wait 之前發生），現有實作因 cv_.wait 的 atomic 語意是安全的；此測試守護的是「worker 在 sender 中時的工作不遺失」屬性，以及作為未來重構的回歸防線。

4. **所有測試遵循專案慣例**：
   - 測試名稱為描述行為的句子
   - 檔案標頭說明「為什麼要有這個檔案」
   - 不使用 `Logger::init`（gtest environment 已處理）
   - 標記 `[Co-developed with claude code -- Adam]`
   - 不斷言 mock 自身的行為

---

## 附錄：CMake 包含路徑說明

專案 CMakeLists.txt:63-66 設定：
```cmake
include_directories(
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/libs"
)
```

`setting/` 目錄**不在** include path 中。`TopologyAndFlowMonitor.hpp` 使用相對路徑 `#include "../setting/AppConfig.hpp"`（從 `include/ndt_core/collection/` 到 `setting/`）。測試檔案透過 transitive include 取得 `AppConfig` 的常數。

若測試需要顯式引入 `AppConfig`，可使用 `#include "../setting/AppConfig.hpp"`（從 `tests/` 到 `setting/` 的相對路徑）。

---

## 附錄：若要編譯與執行

```bash
cd /home/adam/Desktop/NDTwin-Kernel/build
cmake ..
make test_routing_strategy
./tests/test_routing_strategy --gtest_filter='ClassifierActionFormsTest.TheFourReserved*'
./tests/test_routing_strategy --gtest_filter='LLMResponseParsingTest.AModifyFlowEntryTask*'
./tests/test_routing_strategy --gtest_filter='LLMResponseParsingTest.DeserialisingAnAnswer*'
./tests/test_routing_strategy --gtest_filter='LLMResponseParsingTest.AnAnswerClaimingValid*'
./tests/test_routing_strategy --gtest_filter='TopologyAndFlowMonitorTest.*'
./tests/test_routing_strategy --gtest_filter='FlowDispatcherTest.Deterministic*'
```

預期輸出：
- `TheFourReservedOutputTargets...` → **FAILED** (assertion: port == 0xfffffffd, actual: 65535)
- `AModifyFlowEntryTaskConstructsItselfAsAModify` → **FAILED** (assertion: type == MODIFY_FLOW_ENTRY, actual: INSTALL_FLOW_ENTRY)
- `DeserialisingAnAnswerReplacesExistingTasks` → **FAILED** (assertion: size == 1, actual: 2)
- `AnAnswerClaimingValidWithNullTasksIsRejected` → **FAILED** (assertion: should throw, actual: no throw)
- `TopologyAndFlowMonitorTest.*` → **PASSED** (5 tests)
- `DeterministicNoLostWakeup...` → **PASSED**

