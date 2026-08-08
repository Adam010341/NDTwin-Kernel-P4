# 任務：判定 NDTwin-Kernel 的改動是否會讓外部工具失效

你是一位資深的系統整合審查者。這次要你判定的**不是**程式碼品質，而是一個具體、可否證的問題：

> NDTwin-Kernel（C++ 網路數位孿生核心，HTTP 伺服器，監聽 :8000）自 baseline commit `28b8b13`
> 以來的改動，會不會讓**七個獨立開發的外部工具**失效、行為改變、或誤判核心故障？

這七個工具是各自獨立的 repo，由不同人維護，**不會隨 kernel 一起改**。它們是 kernel 的
消費者（少數也是被 kernel 呼叫的伺服器）。任何一個因為 kernel 改動而壞掉，都是回歸缺陷。

## 為什麼要你做這件事（請認真讀，這決定你該怎麼回答）

你在前一輪審查過同一份 kernel diff，判定「變更幅度：大／回退痛苦指數：高」。那份判斷是對的，
但你當時**看不到任何一行外部工具的程式碼**，所以你在建議中寫下：

> 「HTTP 狀態碼相容性：大量端點由 200/500 改為 400/404/501/502。即使行為更正確，但與 NDTwin
> 整合的外部應用可能誤判這些狀態為『kernel 故障』而觸發警報或不正確回退。**需確認所有用戶端
> 已更新或容忍新狀態碼。**」

這一輪就是來做那個「需確認」。這次七個工具**所有接觸 HTTP 的原始碼都完整附在下面**。
所以請不要再輸出「需確認客戶端是否…」這種把問題丟回來的句子 —— 客戶端的碼就在你手上，
請直接讀它、指出行號、給出判定。

## 你必須遵守的證據紀律（最重要的一節）

我們在這個專案上被兩種錯誤咬過，請務必避免：

1. **「存在」不等於「接上」。** 一個函式有定義，不代表有人呼叫它；有呼叫點，也不代表執行時
   真的走到。要主張某個客戶端會壞，請指出**它實際呼叫該端點的那一行**，以及**它處理回應的
   那一行**。只有定義、沒有呼叫的死碼，請明確標記為死碼而不是缺陷。
2. **不要從摘要推論。** 下面給的是原始 diff 與原始檔案。若某件事在給你的材料裡看不出來，
   請放進「無法判定」那一節，不要用推測填空。

另外請注意：**diff 的 context 只有 ±3 行**，所以你看到的是被改動的行，不是完整函式。
如果某個判斷需要看到函式全貌才能成立，請說「需要完整函式才能確認」，不要當成已確認的缺陷。

## 系統事實（背景，非推測）

- kernel 是 HTTP 伺服器，路徑前綴 `/ndt/`，預設 `localhost:8000`。
- 傳輸層與框架**沒有改變**（Boost.Beast），路由方式（`target == "/ndt/xxx"` 或
  `starts_with`）也沒有改變，端點名稱**沒有任何一個被改名或移除**。
- 這批改動的主軸是：把「一律回 200 OK 但數值錯誤／操作其實失敗」的無聲缺陷改成**誠實回報**。
  也就是說，大部分狀態碼變化都是「原本騙人的 200」變成「正確的 4xx/5xx」。
- 部分改動是**輸入嚴格度提高**：原本用 `std::stoull` / `std::stoi`（會把 `-1` 轉成巨大正數、
  把 `12abc` 解析成 `12`、越界時拋例外導致 500），現在改用不拋例外的 `tryParseUint64` /
  `tryMacToUint64` / `tryIpStringToUint32`，失敗回 400。
- 也有**內容層**（非 shape 層）的改動：主機的 `ipv4` 欄位以前常常是空的，現在因為改成持續輪詢
  控制平面而會被填上；流的 `path` 以前常常是 `[]`，現在會有值；`get_average_link_usage` 的
  數值以前可能因整數下溢而荒謬（例如 18 Ebps），現在正確。**這些是回應內容變了，欄位沒變。**

## 我已經自己驗證過的事實（請當作資料，並主動反駁或補漏）

我用「逐函式 md5 比對 baseline 與 HEAD」的方式，檢查了每一個外部工具會碰到的 handler。
結果如下 —— 以下 14 個 handler 的函式本體與 baseline **位元相同（完全沒改）**：

    handleGetGraphData, handleGetDetectedFlowData, handleGetDetectedTopKFlowData,
    handleGetCpuUtilization, handleGetMemoryUtilization, handleGetTemperature,
    handleGetAverageLinkUsage, handleGetSwitchOpenflowTableEntries,
    handleAppRegister, handleAcquireLock, handleReleaseLock,
    handleSetSwitchesPowerState, handleInstallFlowEntry, handleDeleteFlowEntry

而**有被改動**的 handler 是（來自下面 PART A 的 diff hunk 標頭）：

    handleModifyFlowEntry, processFlowBatch（批次端點）,
    handleInstall/Delete/ModifyGroupEntry, handleInstall/Delete/ModifyMeterEntry,
    handleInformSwitchEntered, handleModifyDeviceName, handleModifyNickname,
    handleGetNickname, handleGetPathSwitchCount,
    handleReceivedSimulationCase, handleSimulationCompleted, handleInputTextIntent,
    以及 handleRequest 本身（dispatch 層）

**請驗證這個對照是否成立，特別是：**
- 有沒有哪個「未改動的 handler」其實會因為它呼叫的下層（Utils、TopologyAndFlowMonitor、
  Classifier、FlowRoutingManager）改變而回應不同的內容或狀態碼？函式本體沒改不代表行為沒改。
- dispatch 層（`handleRequest`）的改動有沒有影響到所有端點（例如新增的全域驗證、
  例外處理、或未知 target 的回應）？這會擴大受影響範圍。

## 需要你產出的東西

請依序輸出以下六節，**用繁體中文**：

### 第 1 節：受影響矩陣（最重要）
一張表，每一列是「**某個工具 × 某個端點**」，只列出**該工具真的會呼叫**的端點。欄位：

| 工具 | 端點 | 該工具呼叫的行號 | kernel 改了什麼 | 判定 | 後果 | 客戶端要不要改 |

「判定」只能是這四個之一，請嚴格使用：
- **BREAKS**：會壞。功能失效、崩潰、資料錯誤、或流程中斷。
- **DEGRADES**：不會壞但行為變差或變吵（例如誤報警、log 洪水、UI 顯示錯誤訊息但可繼續）。
- **SAFE**：不受影響，且你能指出為什麼。
- **DEAD**：該呼叫點是死碼（沒有呼叫者），所以不論 kernel 怎麼改都不影響執行。

判定為 BREAKS 或 DEGRADES 時，「後果」欄必須寫出**具體的觸發情境**：什麼輸入／什麼狀態下，
使用者會看到什麼。不要寫「可能有問題」。

### 第 2 節：BREAKS 逐項展開
每一個 BREAKS 寫一段：kernel 側的證據（檔案＋diff 片段）、客戶端側的證據（檔案＋行號）、
觸發條件、使用者可見的症狀、最小修法（改 kernel 還是改客戶端，並說明你為什麼選那一邊）。

### 第 3 節：狀態碼相容性專章
把 kernel 現在可能回的每一個非 2xx 狀態碼（400 / 404 / 412 / 423 / 501 / 502 / 500）
對上每一個客戶端的錯誤處理路徑，判斷該客戶端遇到它時會怎樣。特別注意這幾個客戶端行為的差異：
- 有些客戶端**完全不檢查狀態碼**就直接 parse body（那麼錯誤 body 會被當成資料）
- 有些客戶端 `if status_code == 200` 才處理（那麼非 200 會走 else 分支 —— 那個分支做什麼？）
- 有些客戶端把非 2xx 當例外拋出（那麼呼叫端會怎樣？UI 會不會整頁失敗？）
請注意 kernel 新的錯誤 body 形狀是 `{"status":"error","error":"...","controller_status":N}`，
成功是 `{"status":"<成功訊息>"}`。判斷各客戶端的 body 解析會不會因此拿到 null／拋例外。

### 第 4 節：輸入嚴格度提高造成的回歸
逐一檢查每個客戶端**實際送出的參數值**（請從它們的碼裡找出它們怎麼組 query string 與 body），
判斷有沒有任何一個會被新的嚴格解析拒絕。例如：送出的 dpid 是不是十進位整數字串？
MAC 是不是 17 字元且分隔符一致？IP 格式？有沒有送過 `-1` 之類的哨兵值？
這一節如果沒有問題，請明確說「檢查過，沒有」，並列出你檢查了哪些參數。

### 第 5 節：內容層（非 shape 層）的相容性
主機 `ipv4` 從常常為空變成有值、流 `path` 從 `[]` 變成有值、link usage 數值變正確 ——
這些會不會讓某個客戶端壞掉？特別想一想：有沒有客戶端寫了「假設某欄位為空」的分支、
或用欄位長度／存在性當判斷條件、或有固定大小的緩衝／表格？

### 第 6 節：無法從給定材料判定的事項
明確列出你**看不到所以不能判斷**的東西，以及要判斷它需要什麼（例如「需要 X 檔案」、
「需要一次實際的 HTTP 回應」、「需要跑起來觀察」）。這一節請務實且完整 —— 誠實說看不到，
比猜一個答案有價值得多。

---

# 以下是全部材料

材料順序：
- PART A：kernel HTTP 層（含 header）自 baseline 以來的完整 diff
- PART B：kernel 的狀態碼清單（baseline vs 現在）
- PART C：`OpResult` 型別與 `respondToOpResult`（南向失敗 → HTTP 狀態碼的對映）
- PART D：kernel Utils 的完整 diff（輸入嚴格度改動就在這裡）
- PART E：七個外部工具所有接觸 HTTP 的原始碼（完整檔案，非片段）



# PART A —— kernel HTTP 層完整 diff（28b8b13..HEAD）


===== git diff 28b8b13..HEAD -- src/ndt_core/http/ include/ndt_core/http/ =====

```diff
diff --git a/include/ndt_core/http/HttpSession.hpp b/include/ndt_core/http/HttpSession.hpp
index 2e4ea46..64afbc9 100644
--- a/include/ndt_core/http/HttpSession.hpp
+++ b/include/ndt_core/http/HttpSession.hpp
@@ -6,6 +6,7 @@
 #include <boost/beast/http.hpp>
 #include <memory>
 #include <nlohmann/json.hpp>
+#include "ndt_core/routing_management/OpResult.hpp" // [Co-developed with claude code -- Adam]
 
 using json = nlohmann::json;
 
@@ -69,6 +70,14 @@ class HttpSession : public std::enable_shared_from_this<HttpSession>
     void start();
 
   private:
+    // [Co-developed with claude code -- Adam]
+    // Test seam. tests/test_HttpSessionRouting.cpp constructs a session over an unconnected
+    // socket, sets m_req and calls buildResponse(), which does no I/O. Granted to one named peer
+    // rather than opening the routing internals up, and preferred over testing extracted helpers
+    // because the thing worth asserting -- which status code an endpoint answers with -- is
+    // decided by the catch clauses in buildResponse and is not observable anywhere else.
+    friend class HttpSessionTestPeer;
+
     // --- Asynchronous Operation Handlers ---
     void readRequest();
     void onRead(beast::error_code ec, std::size_t bytesTransferred);
@@ -79,6 +88,16 @@ class HttpSession : public std::enable_shared_from_this<HttpSession>
     // --- Request Routing and Handling ---
     void handleRequest();
 
+    /**
+     * @brief Route m_req to its handler and return the response, mapping any escaping exception
+     *        to a status code: json::exception to 400, anything else to 500.
+     *
+     * Performs no socket I/O; handleRequest() is this followed by writeResponse().
+     *
+     * @return The response to send. Never null.
+     */
+    std::shared_ptr<http::response<http::string_body>> buildResponse();
+
     // Each API endpoint gets its own handler function for clarity.
     /**
      * @brief Handles a link-failure notification sent by the Ryu controller.
@@ -265,6 +284,19 @@ class HttpSession : public std::enable_shared_from_this<HttpSession>
      *
      * @note The request body must be valid JSON in the format expected by Ryu's group-entry API.
      */
+    /**
+     * @brief Maps a southbound OpResult onto the HTTP response.
+     *
+     * 501 when the data plane cannot express the operation, 502 when the controller failed
+     * or never answered, otherwise the controller's own status. Replaces handlers that
+     * discarded the result and answered 200 regardless.
+     *
+     * [Co-developed with claude code -- Adam]
+     */
+    void respondToOpResult(http::response<http::string_body>& res,
+                           const OpResult& result,
+                           const char* successMessage);
+
     void handleInstallGroupEntry(http::response<http::string_body>& res);
     /**
      * @brief Deletes an OpenFlow group entry via the Ryu REST API.
diff --git a/src/ndt_core/http/HttpSession.cpp b/src/ndt_core/http/HttpSession.cpp
index 9e11d1b..45fe9ad 100644
--- a/src/ndt_core/http/HttpSession.cpp
+++ b/src/ndt_core/http/HttpSession.cpp
@@ -18,6 +18,7 @@
 #include <filesystem>
 #include <fstream>
 #include <iostream>
+#include <limits>
 #include <nlohmann/json.hpp>
 #include <string>
 #include <string_view>
@@ -96,6 +97,24 @@ HttpSession::handleRequest()
                        m_req.method_string(),
                        m_req.target());
 
+    m_res = buildResponse();
+    writeResponse();
+}
+
+// [Co-developed with claude code -- Adam]
+// Split out of handleRequest so the routing table and the exception-to-status mapping can be
+// exercised without a connected socket -- everything up to writeResponse() is a pure
+// request-to-response function.
+//
+// That mapping is the part that needed a test. `?dpid=abc` and a non-numeric "app_id" were both
+// answering 500 because std::stoull/std::stoi throw std::invalid_argument, which lands in the
+// std::exception catch rather than the json::exception one. Both were fixed by parsing the value
+// explicitly, but nothing could observe the fix: putting std::stoi back left the entire suite
+// green, because a test that calls a validation helper directly never sees which catch clause
+// would have run. Driving the real router is the only way that distinction is visible.
+std::shared_ptr<http::response<http::string_body>>
+HttpSession::buildResponse()
+{
     auto response =
         std::make_shared<http::response<http::string_body>>(http::status::ok, m_req.version());
     response->keep_alive(m_req.keep_alive());
@@ -119,9 +138,7 @@ HttpSession::handleRequest()
         if (method == http::verb::options)
         {
             response->result(http::status::no_content); // 204 No Content
-            m_res = response;
-            writeResponse();
-            return;
+            return response;
         }
 
         // --- API ROUTING ---
@@ -303,7 +320,13 @@ HttpSession::handleRequest()
     {
         response->result(http::status::bad_request);
         response->body() = json{{"error", "JSON parsing error"}, {"details", e.what()}}.dump();
-        SPDLOG_LOGGER_ERROR(Logger::instance(), "JSON exception in request handler: {}", e.what());
+        // [Co-developed with claude code -- Adam]
+        // WARN, not ERROR: this catch *is* the 400 path. Logging a malformed client request at
+        // ERROR makes exactly the conflation the 500-to-400 work removed from the wire -- "you sent
+        // rubbish" and "I am broken" become the same entry -- and it makes check_logs.py's rule
+        // that an error line is never acceptable unusable, because a contract test that probes the
+        // error paths fills the log with them on purpose.
+        SPDLOG_LOGGER_WARN(Logger::instance(), "JSON exception in request handler: {}", e.what());
     }
     catch (const std::exception& e)
     {
@@ -320,8 +343,7 @@ HttpSession::handleRequest()
         SPDLOG_LOGGER_ERROR(Logger::instance(), "Unknown exception in request handler.");
     }
 
-    m_res = response;
-    writeResponse();
+    return response;
 }
 
 void
@@ -713,15 +735,64 @@ HttpSession::handleModifyFlowEntry(http::response<http::string_body>& res)
     processFlowBatch(j, res);
 }
 
+// [Co-developed with claude code -- Adam]
+// Maps a southbound OpResult onto the HTTP response, so a failure downstream becomes a
+// failure the caller sees rather than a 200 with a cheerful message.
+void
+HttpSession::respondToOpResult(http::response<http::string_body>& res,
+                               const OpResult& result,
+                               const char* successMessage)
+{
+    if (result.ok)
+    {
+        res.result(http::status::ok);
+        res.body() = json{{"status", successMessage}}.dump();
+        return;
+    }
+
+    // 501 means the target data plane cannot express the operation at all (e.g. group
+    // entries on bmv2); 502 that the controller behind us failed or never answered.
+    // Anything else is passed through so the caller sees what the controller said.
+    if (result.httpStatus == 501)
+    {
+        res.result(http::status::not_implemented);
+    }
+    else if (result.noResponse())
+    {
+        res.result(http::status::bad_gateway);
+    }
+    else if (result.httpStatus >= 400 && result.httpStatus < 600)
+    {
+        res.result(static_cast<http::status>(result.httpStatus));
+    }
+    else
+    {
+        res.result(http::status::bad_gateway);
+    }
+
+    res.body() = json{{"status", "error"},
+                      {"error", result.message},
+                      {"controller_status", result.httpStatus}}
+                     .dump();
+
+    SPDLOG_LOGGER_WARN(Logger::instance(),
+                       "Responding {} for a failed southbound operation: {}",
+                       static_cast<int>(res.result_int()),
+                       result.message);
+}
+
 void
 HttpSession::handleInstallGroupEntry(http::response<http::string_body>& res)
 {
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Group Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->installAGroupEntry(jsonData);
-
-    res.body() = R"({"status":"Group entry installed"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->installAGroupEntry(jsonData);
+    respondToOpResult(res, result, "Group entry installed");
 }
 
 void
@@ -730,9 +801,12 @@ HttpSession::handleDeleteGroupEntry(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Delete Group Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->deleteAGroupEntry(jsonData);
-
-    res.body() = R"({"status":"Group entry deleted"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->deleteAGroupEntry(jsonData);
+    respondToOpResult(res, result, "Group entry deleted");
 }
 
 void
@@ -741,9 +815,12 @@ HttpSession::handleModifyGroupEntry(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Group Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->modifyAGroupEntry(jsonData);
-
-    res.body() = R"({"status":"Group entry modified"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->modifyAGroupEntry(jsonData);
+    respondToOpResult(res, result, "Group entry modified");
 }
 
 void
@@ -752,9 +829,12 @@ HttpSession::handleInstallMeterEntry(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Meter Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->installAMeterEntry(jsonData);
-
-    res.body() = R"({"status":"Meter entry installed"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->installAMeterEntry(jsonData);
+    respondToOpResult(res, result, "Meter entry installed");
 }
 
 void
@@ -763,9 +843,12 @@ HttpSession::handleDeleteMeterEntry(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Delete Meter Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->deleteAMeterEntry(jsonData);
-
-    res.body() = R"({"status":"Meter entry deleted"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->deleteAMeterEntry(jsonData);
+    respondToOpResult(res, result, "Meter entry deleted");
 }
 
 void
@@ -774,9 +857,12 @@ HttpSession::handleModifyMeterEntry(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Meter Entry");
     auto jsonData = json::parse(m_req.body());
 
-    m_flowRoutingManager->modifyAMeterEntry(jsonData);
-
-    res.body() = R"({"status":"Meter entry modified"})";
+    // [Co-developed with claude code -- Adam]
+    // The OpResult used to be discarded and this answered 200 unconditionally, so a
+    // rejected entry, an unreachable controller and a success were indistinguishable to
+    // the caller. These handlers are synchronous, so the real outcome can be reported.
+    const OpResult result = m_flowRoutingManager->modifyAMeterEntry(jsonData);
+    respondToOpResult(res, result, "Meter entry modified");
 }
 
 static FlowJob
@@ -863,19 +949,84 @@ HttpSession::processFlowBatch(const json& j, http::response<http::string_body>&
     catch (const std::exception& ex)
     {
         SPDLOG_LOGGER_DEBUG(Logger::instance(), "request body {}", j.dump());
-        SPDLOG_LOGGER_ERROR(Logger::instance(), "Bad entry in request: {}", ex.what());
+        // WARN: answers 400 four lines down, so this is a client error, not a kernel one.
+        // [Co-developed with claude code -- Adam]
+        SPDLOG_LOGGER_WARN(Logger::instance(), "Bad entry in request: {}", ex.what());
         res.result(http::status::bad_request);
         res.body() = R"({"error":"Bad entry"})";
         return;
     }
 
+    // [Co-developed with claude code -- Adam]
+    // Reject dpids this kernel does not know about, before enqueueing anything.
+    //
+    // This endpoint answered 200 for a nonexistent dpid, which the L2 contract has been failing on
+    // for as long as it has existed. The instinct is to blame the asynchrony -- the dispatcher
+    // drains on worker threads, so the southbound outcome genuinely is not available yet -- but
+    // "there is no such switch" is not a southbound outcome. It is knowable here, from the
+    // topology the kernel already holds, before a job is queued at all.
+    //
+    // All-or-nothing: a batch naming one bad dpid is rejected whole rather than partially applied,
+    // because a caller that gets 200 for a partially-applied batch has no way to find out which
+    // half landed. The genuinely asynchronous outcomes are still asynchronous, and are logged per
+    // entry by Controller's sender.
+    std::vector<uint64_t> unknownDpids;
+    for (const auto& job : jobs)
+    {
+        if (!m_topologyAndFlowMonitor->getSwitchKind(job.dpid).has_value())
+        {
+            unknownDpids.push_back(job.dpid);
+        }
+    }
+    if (!unknownDpids.empty())
+    {
+        std::sort(unknownDpids.begin(), unknownDpids.end());
+        unknownDpids.erase(std::unique(unknownDpids.begin(), unknownDpids.end()),
+                           unknownDpids.end());
+        SPDLOG_LOGGER_WARN(Logger::instance(),
+                           "refusing flow batch: {} dpid(s) are not switches in the loaded "
+                           "topology",
+                           unknownDpids.size());
+        res.result(http::status::not_found);
+        res.body() = json{{"status", "error"},
+                          {"error", "unknown dpid"},
+                          {"unknown_dpids", unknownDpids},
+                          {"detail", "these dpids are not switches in the loaded topology; check "
+                                     "the dpid, or that the topology file matches the running "
+                                     "network"}}
+                         .dump();
+        return;
+    }
+
     // Enqueue once; dispatcher drains per-DPID on worker threads
+    const size_t accepted = jobs.size();
     m_controller->dispatcher().enqueue(std::move(jobs));
 
     // TODO: Immediately update the table
     m_deviceConfigurationAndPowerManager->updateOpenFlowTables(j);
 
-    res.body() = R"({"status":"Flows installed, modified and deleted"})";
+    // [Co-developed with claude code -- Adam]
+    // This used to answer {"status":"Flows installed, modified and deleted"} -- a claim it
+    // cannot make. FlowDispatcher is asynchronous by design (bursts of up to 2000, one
+    // worker per DPID), so the entries are still sitting in a queue at this point and no
+    // request has reached the controller yet. A rejected rule or an unreachable controller
+    // was therefore reported as a completed installation.
+    //
+    // The response now says what is actually true: the entries were accepted for
+    // programming. Their outcome is logged per entry with the dpid and the controller's
+    // reply -- which was claimed here before it was true: Controller's sender discarded every
+    // OpResult it received. It logs them now, so check_logs.py can fail a run on a rejected rule.
+    //
+    // Kept as HTTP 200 rather than 202 Accepted: 202 would be more accurate, but callers
+    // that check for exactly 200 would break, and this is the endpoint every writing app
+    // uses. Reporting per-entry status to the caller needs either a synchronous path or a
+    // completion handle -- an architectural decision, not a wording one.
+    res.result(http::status::ok);
+    res.body() = json{{"status", "queued"},
+                      {"accepted", accepted},
+                      {"detail", "entries accepted for programming; per-entry outcomes are "
+                                 "reported in the kernel log, not in this response"}}
+                     .dump();
 }
 
 void
@@ -921,7 +1072,26 @@ HttpSession::handleInformSwitchEntered(http::response<http::string_body>& res)
         return;
     }
 
-    uint64_t dpid = std::stoull(dpidStr);
+    // [Co-developed with claude code -- Adam]
+    // std::stoull threw on `?dpid=abc` and the outermost catch turned it into 500 -- the L2 failure
+    // inform_switch_entered__bad_dpid. tryParseUint64 is also stricter than stoull, which would
+    // read "12abc" as 12 and "-1" as 18446744073709551615: a mistyped dpid must be refused, not
+    // silently redirected to a different switch.
+    const auto dpidOpt = utils::tryParseUint64(dpidStr);
+    if (!dpidOpt)
+    {
+        SPDLOG_LOGGER_WARN(Logger::instance(),
+                           "inform_switch_entered: dpid '{}' is not an unsigned integer",
+                           dpidStr);
+        res.result(http::status::bad_request);
+        res.body() = json{{"status", "error"},
+                          {"error", "invalid dpid"},
+                          {"dpid", dpidStr},
+                          {"detail", "dpid must be an unsigned integer"}}
+                         .dump();
+        return;
+    }
+    const uint64_t dpid = *dpidOpt;
     auto switchVertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
     if (!switchVertexOpt)
     {
@@ -951,8 +1121,28 @@ HttpSession::handleModifyDeviceName(http::response<http::string_body>& res)
     }
     else if (vertexType == 1) // Host
     {
-        vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(
-            utils::macToUint64(body.at("mac").get<std::string>()));
+        // [Co-developed with claude code -- Adam]
+        // tryMacToUint64, because macToUint64 throws and the throw reaches buildResponse's
+        // std::exception catch -- which answers 500 for a malformed client request. Exactly the
+        // defect the dpid and app_id parsing was fixed for; this call site was missed. Found by
+        // agy-review 0115.
+        const std::string macText = body.at("mac").get<std::string>();
+        const auto mac = utils::tryMacToUint64(macText);
+        if (!mac)
+        {
+            SPDLOG_LOGGER_WARN(Logger::instance(),
+                               "modify_device_name: mac '{}' is not a MAC address",
+                               macText);
+            res.result(http::status::bad_request);
+            res.set(http::field::content_type, "application/json");
+            res.body() = json{{"status", "error"},
+                              {"error", "invalid mac"},
+                              {"mac", macText},
+                              {"detail", "expected xx:xx:xx:xx:xx:xx"}}
+                             .dump();
+            return;
+        }
+        vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(*mac);
     }
     else
     {
@@ -977,6 +1167,22 @@ HttpSession::handleReceivedSimulationCase(http::response<http::string_body>& res
 {
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Recieved Simulation Case");
 
+    // This endpoint used to answer 202 Accepted to *anything*, including `{not json`: the body went
+    // straight into a curl command and whatever came back -- including nothing at all -- was
+    // wrapped as {"status": "..."}. The five required fields are Simulation-Platform-Manager's own,
+    // so a body that fails here would have thrown inside that process instead, where no status code
+    // can reach the caller. [Co-developed with claude code -- Adam]
+    if (const auto problem = SimulationRequestManager::validateRequestBody(m_req.body()))
+    {
+        SPDLOG_LOGGER_WARN(Logger::instance(),
+                           "Rejecting simulation case: {}",
+                           *problem);
+        res.result(http::status::bad_request);
+        res.set(http::field::content_type, "application/json");
+        res.body() = json{{"error", "Invalid simulation case"}, {"details", *problem}}.dump();
+        return;
+    }
+
     std::string resp = m_simulationRequestManager->requestSimulation(m_req.body());
 
     res.result(http::status::accepted);
@@ -991,7 +1197,23 @@ HttpSession::handleSimulationCompleted(http::response<http::string_body>& res)
     SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Simulation Completed");
     auto j = json::parse(m_req.body());
 
-    int appId = std::stoi(j.at("app_id").get<string>());
+    // Malformed JSON and a missing/non-string app_id already answer 400 via the json::exception
+    // handler, but std::stoi("abc") throws std::invalid_argument, which does not -- the same
+    // mistyped-parameter-reported-as-500 defect that `?dpid=abc` had. [Co-developed with claude
+    // code -- Adam]
+    const std::string appIdText = j.at("app_id").get<string>();
+    const auto parsedAppId = utils::tryParseUint64(appIdText);
+    if (!parsedAppId || *parsedAppId > static_cast<uint64_t>(std::numeric_limits<int>::max()))
+    {
+        SPDLOG_LOGGER_WARN(Logger::instance(),
+                           "Rejecting simulation result: app_id '{}' is not a valid id",
+                           appIdText);
+        res.result(http::status::bad_request);
+        res.set(http::field::content_type, "application/json");
+        res.body() = json{{"error", "Invalid app_id"}, {"details", appIdText}}.dump();
+        return;
+    }
+    const int appId = static_cast<int>(*parsedAppId);
 
     m_simulationRequestManager->onSimulationResult(appId, m_req.body());
 
@@ -1111,7 +1333,8 @@ HttpSession::handleInputTextIntent(http::response<http::string_body>& res)
     }
     catch (const std::exception& e)
     {
-        SPDLOG_LOGGER_ERROR(Logger::instance(),
+        // WARN: answers 400 below. [Co-developed with claude code -- Adam]
+        SPDLOG_LOGGER_WARN(Logger::instance(),
                             "Exception in intent_translator: {}, request body: {}",
                             e.what(),
                             m_req.body());
@@ -1197,7 +1420,31 @@ HttpSession::handleGetNickname(http::response<http::string_body>& res)
     {
         try
         {
-            uint64_t dpid = std::stoull(dpidStr);
+            // [Co-developed with claude code -- Adam]
+            // Same guard as handleInformSwitchEntered: std::stoull threw on `?dpid=abc` and the
+            // outermost catch turned it into 500. tryParseUint64 is also stricter than stoull,
+            // which would read "12abc" as 12 and "-1" as 18446744073709551615 -- a mistyped dpid
+            // must be refused, not silently redirected to a different switch.
+            //
+            // The message names *this* endpoint. It was copy-pasted from handleInformSwitchEntered
+            // with the text unedited, so a bad `?dpid=` on /ndt/get_nickname logged
+            // "inform_switch_entered: ..." and sent the reader to the wrong handler. Checked the
+            // other forty-odd handlers for the same slip; this was the only one.
+            const auto dpidOpt = utils::tryParseUint64(dpidStr);
+            if (!dpidOpt)
+            {
+                SPDLOG_LOGGER_WARN(Logger::instance(),
+                                   "get_nickname: dpid '{}' is not an unsigned integer",
+                                   dpidStr);
+                res.result(http::status::bad_request);
+                res.body() = json{{"status", "error"},
+                                  {"error", "invalid dpid"},
+                                  {"dpid", dpidStr},
+                                  {"detail", "dpid must be an unsigned integer"}}
+                                 .dump();
+                return;
+            }
+            const uint64_t dpid = *dpidOpt;
             vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
         }
         catch (const std::exception& e)
@@ -1274,8 +1521,25 @@ HttpSession::handleModifyNickname(http::response<http::string_body>& res)
         }
         else if (type == "mac")
         {
-            uint64_t mac = utils::macToUint64(identifier.at("value").get<std::string>());
-            vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(mac);
+            // Same as above: a malformed MAC is a client error, not a server one.
+            // [Co-developed with claude code -- Adam]
+            const std::string macText = identifier.at("value").get<std::string>();
+            const auto mac = utils::tryMacToUint64(macText);
+            if (!mac)
+            {
+                SPDLOG_LOGGER_WARN(Logger::instance(),
+                                   "modify_nickname: mac '{}' is not a MAC address",
+                                   macText);
+                res.result(http::status::bad_request);
+                res.set(http::field::content_type, "application/json");
+                res.body() = json{{"status", "error"},
+                                  {"error", "invalid mac"},
+                                  {"mac", macText},
+                                  {"detail", "expected xx:xx:xx:xx:xx:xx"}}
+                                 .dump();
+                return;
+            }
+            vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(*mac);
         }
         else if (type == "name")
         {
@@ -1375,8 +1639,30 @@ HttpSession::handleGetPathSwitchCount(http::response<http::string_body>& res)
                            srcIpStr,
                            dstIpStr);
 
-        uint32_t srcIp = utils::ipStringToUint32(srcIpStr);
-        uint32_t dstIp = utils::ipStringToUint32(dstIpStr);
+        // [Co-developed with claude code -- Adam]
+        // ipStringToUint32 throws, and the throw escaped to the outermost catch, which answers 500.
+        // A malformed query parameter is the caller's mistake, not the kernel breaking, and telling
+        // them otherwise sends them looking in the wrong place. This is the L2 failure
+        // get_path_switch_count__bad_ip.
+        const auto srcIpOpt = utils::tryIpStringToUint32(srcIpStr);
+        const auto dstIpOpt = utils::tryIpStringToUint32(dstIpStr);
+        if (!srcIpOpt || !dstIpOpt)
+        {
+            SPDLOG_LOGGER_WARN(Logger::instance(),
+                               "get_path_switch_count: bad IP parameter(s) src='{}' dst='{}'",
+                               srcIpStr,
+                               dstIpStr);
+            res.result(http::status::bad_request);
+            res.body() = json{{"status", "error"},
+                              {"error", "invalid IP address"},
+                              {"src_ip", srcIpStr},
+                              {"dst_ip", dstIpStr},
+                              {"detail", "src_ip and dst_ip must be dotted IPv4 addresses"}}
+                             .dump();
+            return;
+        }
+        const uint32_t srcIp = *srcIpOpt;
+        const uint32_t dstIp = *dstIpOpt;
 
         auto switchCountOpt = m_flowLinkUsageCollector->getSwitchCount({srcIp, dstIp});
 

```


# PART B —— 狀態碼清單對照

以下是 HttpSession.cpp 中所有 `res.result(...)` 呼叫，先 baseline 後現在。


===== BASELINE 28b8b13: HttpSession.cpp 的 res.result() 共 46 處 =====

```text
 387:        res.result(http::status::bad_request);
 402:        res.result(http::status::not_found);
 428:        res.result(http::status::bad_request);
 449:        res.result(http::status::not_found);
 608:        res.result(http::status::not_found);
 654:        res.result(http::status::bad_request);
 666:        res.result(http::status::internal_server_error);
 838:        res.result(http::status::bad_request);
 867:        res.result(http::status::bad_request);
 912:        res.result(http::status::bad_request);
 919:        res.result(http::status::bad_request);
 928:        res.result(http::status::not_found);
 959:        res.result(http::status::bad_request);
 966:        res.result(http::status::not_found);
 982:    res.result(http::status::accepted);
 998:    res.result(http::status::ok);
 1065:        res.result(http::status::bad_request);
 1077:        res.result(http::status::bad_request);
 1091:    res.result(http::status::ok);
 1109:        res.result(http::status::ok);
 1118:        res.result(http::status::bad_request);
 1187:        res.result(http::status::bad_request);
 1205:            res.result(http::status::bad_request);
 1219:            res.result(http::status::bad_request);
 1243:        res.result(http::status::not_found);
 1251:    res.result(http::status::ok);
 1301:            res.result(http::status::not_found);
 1312:        res.result(http::status::ok);
 1317:        res.result(http::status::bad_request);
 1385:            res.result(http::status::ok);
 1393:            res.result(http::status::not_found);
 1406:        res.result(http::status::ok);
 1446:    res.result(http::status::ok);
 1490:        res.result(http::status::bad_request);
 1499:        res.result(http::status::internal_server_error);
 1506:    res.result(http::status::ok);
 1521:    res.result(http::status::ok);
 1593:    res.result(http::status::not_found);
 1624:            res.result(http::status::ok);
 1630:            res.result(http::status::locked);
 1638:        res.result(http::status::internal_server_error);
 1671:            res.result(http::status::ok);
 1676:            res.result(http::status::precondition_failed); // 412 Precondition Failed
 1685:        res.result(http::status::bad_request);
 1713:        res.result(http::status::ok);
 1718:        res.result(http::status::internal_server_error);

```


===== HEAD: HttpSession.cpp 的 res.result() 共 60 處 =====

```text
 409:        res.result(http::status::bad_request);
 424:        res.result(http::status::not_found);
 450:        res.result(http::status::bad_request);
 471:        res.result(http::status::not_found);
 630:        res.result(http::status::not_found);
 676:        res.result(http::status::bad_request);
 688:        res.result(http::status::internal_server_error);
 748:        res.result(http::status::ok);
 758:        res.result(http::status::not_implemented);
 762:        res.result(http::status::bad_gateway);
 766:        res.result(static_cast<http::status>(result.httpStatus));
 770:        res.result(http::status::bad_gateway);
 924:        res.result(http::status::bad_request);
 955:        res.result(http::status::bad_request);
 990:        res.result(http::status::not_found);
 1024:    res.result(http::status::ok);
 1063:        res.result(http::status::bad_request);
 1070:        res.result(http::status::bad_request);
 1086:        res.result(http::status::bad_request);
 1098:        res.result(http::status::not_found);
 1136:            res.result(http::status::bad_request);
 1149:        res.result(http::status::bad_request);
 1156:        res.result(http::status::not_found);
 1180:        res.result(http::status::bad_request);
 1188:    res.result(http::status::accepted);
 1211:        res.result(http::status::bad_request);
 1220:    res.result(http::status::ok);
 1287:        res.result(http::status::bad_request);
 1299:        res.result(http::status::bad_request);
 1313:    res.result(http::status::ok);
 1331:        res.result(http::status::ok);
 1341:        res.result(http::status::bad_request);
 1410:        res.result(http::status::bad_request);
 1439:                res.result(http::status::bad_request);
 1452:            res.result(http::status::bad_request);
 1466:            res.result(http::status::bad_request);
 1490:        res.result(http::status::not_found);
 1498:    res.result(http::status::ok);
 1533:                res.result(http::status::bad_request);
 1565:            res.result(http::status::not_found);
 1576:        res.result(http::status::ok);
 1581:        res.result(http::status::bad_request);
 1655:            res.result(http::status::bad_request);
 1671:            res.result(http::status::ok);
 1679:            res.result(http::status::not_found);
 1692:        res.result(http::status::ok);
 1732:    res.result(http::status::ok);
 1776:        res.result(http::status::bad_request);
 1785:        res.result(http::status::internal_server_error);
 1792:    res.result(http::status::ok);
 1807:    res.result(http::status::ok);
 1879:    res.result(http::status::not_found);
 1910:            res.result(http::status::ok);
 1916:            res.result(http::status::locked);
 1924:        res.result(http::status::internal_server_error);
 1957:            res.result(http::status::ok);
 1962:            res.result(http::status::precondition_failed); // 412 Precondition Failed
 1971:        res.result(http::status::bad_request);
 1999:        res.result(http::status::ok);
 2004:        res.result(http::status::internal_server_error);

```

分佈（HEAD）：400 Bad Request × 24、200 OK × 15、404 Not Found × 10、500 × 4、502 Bad Gateway × 2、501 Not Implemented × 1、412 Precondition Failed × 1、423 Locked × 1、202 Accepted × 1、以及 1 處直接把控制器回的狀態碼透傳（`static_cast<http::status>(result.httpStatus)`）。


# PART C —— OpResult 與 respondToOpResult（南向失敗 → HTTP 狀態碼）


===== include/ndt_core/routing_management/OpResult.hpp（baseline 不存在此檔） =====

```cpp
// [Co-developed with claude code -- Adam]
#pragma once

#include <string>
#include <utility>

/**
 * @brief Outcome of a southbound operation against a controller or proxy.
 *
 * Every routing and power method used to return void, and the layers beneath them threw
 * results away: curl ran with -s and no --fail, its return value was discarded,
 * executeCommand returned void, and the P4 proxy answered `{"status":"error"}` to nobody.
 * A dead controller, a rejected rule and a successful install were therefore
 * indistinguishable to the kernel, and /ndt/install_flow_entry answered 200 either way.
 *
 * This type is the smallest thing that fixes that: did it work, what did the far end say,
 * and why not. It is deliberately not an exception -- a rejected flow rule is an expected
 * outcome on a hot path handling thousands of entries per burst, not an exceptional one.
 */
struct OpResult
{
    bool ok = false;

    /**
     * HTTP status from the controller, or 0 when no response arrived at all.
     *
     * 0 is what curl reports as %{http_code} when it cannot connect, so it distinguishes
     * "the controller said no" from "the controller is not there" -- a distinction the
     * kernel could not previously make.
     */
    int httpStatus = 0;

    /// Human-readable reason, for logs and for the /ndt/ response body. Empty on success.
    std::string message;

    static OpResult success(int status = 200)
    {
        return OpResult{true, status, ""};
    }

    static OpResult failure(int status, std::string why)
    {
        return OpResult{false, status, std::move(why)};
    }

    /// No response at all: the far end is unreachable, or the request timed out.
    static OpResult unreachable(std::string why)
    {
        return OpResult{false, 0, std::move(why)};
    }

    /// The target data plane cannot express this operation (e.g. group entries on bmv2).
    static OpResult unsupported(std::string why)
    {
        return OpResult{false, 501, std::move(why)};
    }

    /// True when nothing answered, as opposed to answering with an error.
    bool noResponse() const
    {
        return httpStatus == 0;
    }

    explicit operator bool() const
    {
        return ok;
    }
};

```

HttpSession::respondToOpResult 的對映邏輯：
```cpp
// failure the caller sees rather than a 200 with a cheerful message.
void
HttpSession::respondToOpResult(http::response<http::string_body>& res,
                               const OpResult& result,
                               const char* successMessage)
{
    if (result.ok)
    {
        res.result(http::status::ok);
        res.body() = json{{"status", successMessage}}.dump();
        return;
    }

    // 501 means the target data plane cannot express the operation at all (e.g. group
    // entries on bmv2); 502 that the controller behind us failed or never answered.
    // Anything else is passed through so the caller sees what the controller said.
    if (result.httpStatus == 501)
    {
        res.result(http::status::not_implemented);
    }
    else if (result.noResponse())
    {
        res.result(http::status::bad_gateway);
    }
    else if (result.httpStatus >= 400 && result.httpStatus < 600)
    {
        res.result(static_cast<http::status>(result.httpStatus));
    }
    else
    {
        res.result(http::status::bad_gateway);
    }

    res.body() = json{{"status", "error"},
                      {"error", result.message},
                      {"controller_status", result.httpStatus}}
                     .dump();

    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Responding {} for a failed southbound operation: {}",
                       static_cast<int>(res.result_int()),
                       result.message);
}
```


# PART D —— kernel Utils 完整 diff（輸入嚴格度改動在這裡）


===== git diff 28b8b13..HEAD -- include/utils/Utils.hpp src/utils/Utils.cpp =====

```diff
diff --git a/include/utils/Utils.hpp b/include/utils/Utils.hpp
index f6efe03..6595c45 100644
--- a/include/utils/Utils.hpp
+++ b/include/utils/Utils.hpp
@@ -3,6 +3,10 @@
 #include "utils/Logger.hpp"
 #include <arpa/inet.h>
 #include <array>
+#include <cerrno>
+#include <string_view>
+#include <cstring>
+#include <sys/wait.h>
 #include <boost/asio/connect.hpp>
 #include <boost/asio/ssl.hpp>
 #include <boost/beast/core.hpp>
@@ -17,6 +21,8 @@
 #include <iomanip>
 #include <iostream>
 #include <sstream>
+#include <optional>
+#include <cctype>
 #include <stdexcept>
 #include <string>
 #include <vector>
@@ -32,7 +38,7 @@
  *  - timestamp helpers and formatting.
  *
  * @warning Some functions (execCommand, httpsPost) perform I/O and may throw.
- * @warning Functions using inet_ntoa/localtime rely on non-thread-safe libc APIs.
+ * @warning localtime is a non-thread-safe libc API. (ipToString uses inet_ntop and is safe.)
  *          Prefer thread-safe alternatives if called from multiple threads.
  */
 namespace utils
@@ -57,19 +63,32 @@ enum DeploymentMode
  * @return Dotted string (e.g., "10.10.10.12").
  * @throws std::runtime_error if conversion fails.
  *
- * @warning Uses inet_ntoa(), which is not thread-safe.
+ * [Co-developed with claude code -- Adam]
+ * Uses inet_ntop rather than inet_ntoa. This is a portability fix, not a bug fix, and the
+ * distinction is worth recording because a review claimed otherwise.
+ *
+ * POSIX does not require inet_ntoa to be thread-safe, and this header used to carry an @warning
+ * saying it was not -- with 62 call sites across threads, that reads alarming. Measured on this
+ * platform (glibc 2.39): inet_ntoa's buffer is thread-local, so each thread gets its own and the
+ * race cannot happen. A concurrency test with eight threads and 160,000 conversions passes against
+ * inet_ntoa unchanged, which is how the overclaim was caught. There was never a segfault risk
+ * either: the buffer is always valid.
+ *
+ * So the switch buys portability off a glibc-specific guarantee, and removes a warning that was
+ * frightening and wrong. inet_ntop writes into a caller-supplied buffer, so there is nothing
+ * shared under any libc.
  */
 inline std::string
 ipToString(uint32_t ip)
 {
     struct in_addr addr;
     addr.s_addr = ip;
-    const char* s = inet_ntoa(addr);
-    if (!s)
+    char buf[INET_ADDRSTRLEN] = {};
+    if (!inet_ntop(AF_INET, &addr, buf, sizeof(buf)))
     {
-        throw std::runtime_error("inet_ntoa failed");
+        throw std::runtime_error("inet_ntop failed");
     }
-    return std::string(s);
+    return std::string(buf);
 }
 
 /**
@@ -79,22 +98,17 @@ ipToString(uint32_t ip)
  * @return Vector of dotted strings.
  * @throws std::runtime_error on conversion failure.
  *
- * @warning Uses inet_ntoa(), which is not thread-safe.
+ * [Co-developed with claude code -- Adam] Delegates to the single-address overload; see there for
+ * why inet_ntop rather than inet_ntoa, and for what that did and did not fix.
  */
 inline std::vector<std::string>
 ipToString(std::vector<uint32_t> ipVec)
 {
     std::vector<std::string> res;
+    res.reserve(ipVec.size());
     for (const auto& ip : ipVec)
     {
-        struct in_addr addr;
-        addr.s_addr = ip;
-        const char* s = inet_ntoa(addr);
-        if (!s)
-        {
-            throw std::runtime_error("inet_ntoa failed");
-        }
-        res.push_back(std::string(s));
+        res.push_back(ipToString(ip));
     }
     return res;
 }
@@ -117,6 +131,82 @@ ipStringToUint32(const std::string& ipStr)
     return addr.s_addr;
 }
 
+/**
+ * @brief Parse a dotted IPv4 string, or nothing if it is not one.
+ *
+ * @details
+ * [Co-developed with claude code -- Adam]
+ * The throwing version above is the right shape for internal callers who already know the string is
+ * an address. It is the wrong shape for a REST handler: `?src_ip=not.an.ip` threw
+ * std::invalid_argument out of the handler, HttpSession's outermost catch turned it into
+ * **500 Internal Server Error**, and the caller was told the kernel had broken when in fact their
+ * request was malformed. The L2 contract has been failing on exactly that
+ * (get_path_switch_count__bad_ip) for as long as it has existed.
+ *
+ * A handler wants to answer 400 and say which parameter was wrong, which needs a parse that reports
+ * failure rather than throwing it.
+ *
+ * @param ipStr Dotted IPv4 string.
+ * @return The address in network byte order (in_addr::s_addr), or nullopt.
+ */
+inline std::optional<uint32_t>
+tryIpStringToUint32(const std::string& ipStr)
+{
+    struct in_addr addr;
+    if (ipStr.empty() || inet_aton(ipStr.c_str(), &addr) == 0)
+    {
+        return std::nullopt;
+    }
+    return addr.s_addr;
+}
+
+/**
+ * @brief Parse an unsigned 64-bit id from a query parameter, or nothing if it is not one.
+ *
+ * @details
+ * [Co-developed with claude code -- Adam]
+ * `?dpid=abc` reached std::stoull, which threw std::invalid_argument and became a
+ * **500 Internal Server Error** -- the L2 failure inform_switch_entered__bad_dpid.
+ *
+ * Stricter than stoull deliberately. stoull accepts leading whitespace, a leading `+` or `-`, and
+ * any trailing junk: "12abc" parses as 12, and "-1" wraps to 18446744073709551615. A dpid that a
+ * caller mistyped must be refused, not silently turned into a different switch. Only digits are
+ * accepted, and the value must fit.
+ *
+ * @param text The parameter value.
+ * @return The parsed value, or nullopt.
+ */
+inline std::optional<uint64_t>
+tryParseUint64(const std::string& text)
+{
+    if (text.empty())
+    {
+        return std::nullopt;
+    }
+    for (const char c : text)
+    {
+        if (!std::isdigit(static_cast<unsigned char>(c)))
+        {
+            return std::nullopt;
+        }
+    }
+    try
+    {
+        size_t consumed = 0;
+        const unsigned long long value = std::stoull(text, &consumed);
+        if (consumed != text.size())
+        {
+            return std::nullopt;
+        }
+        return static_cast<uint64_t>(value);
+    }
+    catch (const std::exception&)
+    {
+        // out_of_range for something longer than 64 bits. Refusing beats wrapping.
+        return std::nullopt;
+    }
+}
+
 inline static uint32_t
 prefixToMaskHost(uint8_t p)
 {
@@ -212,6 +302,110 @@ hexStringToUint64(const std::string& hexStr)
     return value;
 }
 
+/**
+ * @brief The tool a shell command line actually runs, for a diagnostic that names it.
+ *
+ * @details Skips a leading `sudo` and its options, because "is sudo installed?" is never the
+ * question. Returns empty when there is nothing to name. [Co-developed with claude code -- Adam]
+ */
+inline std::string
+commandToolName(std::string_view command)
+{
+    std::size_t pos = 0;
+    for (int hop = 0; hop < 4; ++hop) // sudo, then at most a couple of its options
+    {
+        while (pos < command.size() && std::isspace(static_cast<unsigned char>(command[pos])))
+        {
+            ++pos;
+        }
+        const std::size_t end = command.find_first_of(" \t", pos);
+        std::string_view token = command.substr(pos, end == std::string_view::npos
+                                                        ? std::string_view::npos
+                                                        : end - pos);
+        if (token.empty())
+        {
+            return {};
+        }
+        // Strip any directory part: /usr/bin/ovs-vsctl -> ovs-vsctl.
+        if (const std::size_t slash = token.find_last_of('/'); slash != std::string_view::npos)
+        {
+            token = token.substr(slash + 1);
+        }
+        if (token != "sudo" && !token.starts_with('-'))
+        {
+            return std::string(token);
+        }
+        if (end == std::string_view::npos)
+        {
+            return {};
+        }
+        pos = end;
+    }
+    return {};
+}
+
+/**
+ * @brief Renders a pclose()/std::system() wait status as something an operator can act on.
+ *
+ * @details
+ * [Co-developed with claude code -- Adam]
+ *
+ * Neither pclose() nor std::system() returns an exit code -- both return a **wait status**, so a
+ * command that exited 1 is 256 and one that exited 127 is 32512. Printing that number raw has
+ * misled a reader of these logs more than once, which is why this lives in one place instead of
+ * being open-coded at each call site.
+ *
+ * @param status  Wait status from pclose() or std::system(), or -1.
+ * @param command The command line that produced it, when the caller has it. Used to name the tool
+ *                in the 127 case and to decide whether the sudo hint applies.
+ *
+ * The two hints are the two failures this codebase actually sees, and they send an operator to
+ * completely different places -- but only if they name the right tool. When this decoder lived in
+ * DeviceConfigurationAndPowerManager it hardcoded `ovs-vsctl`, which was correct there because that
+ * class runs nothing else. Moving it here wired it into utils::execCommand, the generic shell-out
+ * behind `curl` to Ryu and the proxy and **13 snmpget/snmpwalk call sites** -- so a TESTBED machine
+ * without net-snmp reported "is ovs-vsctl installed?" for every power reading, on a path where
+ * nobody runs ovs-vsctl at all. Caught by review; a misleading diagnostic costs more than a missing
+ * one, which is the lesson this whole decoder exists to serve.
+ *
+ * The sudo hint is likewise conditional now: `sudo` refusing for want of a password is what exit 1
+ * means for `sudo ovs-vsctl`, and it is emphatically not what exit 1 means for `snmpget` (a timeout
+ * or an unknown OID) or for `curl` (an unsupported protocol).
+ */
+inline std::string
+describeCommandStatus(int status, std::string_view command = {})
+{
+    if (status == -1)
+    {
+        return std::string("could not be reaped: ") + std::strerror(errno);
+    }
+    if (WIFSIGNALED(status))
+    {
+        return "killed by signal " + std::to_string(WTERMSIG(status));
+    }
+    if (WIFEXITED(status))
+    {
+        const int code = WEXITSTATUS(status);
+        const std::string tool = commandToolName(command);
+        if (code == 127)
+        {
+            if (tool.empty())
+            {
+                return "exit code 127 (command not found)";
+            }
+            return "exit code 127 (command not found -- is " + tool + " installed?)";
+        }
+        if (code == 1 && command.find("sudo") != std::string_view::npos)
+        {
+            return "exit code 1 (" + (tool.empty() ? std::string("the command") : tool) +
+                   " refused; a sudo password prompt does this on a process with no controlling "
+                   "terminal)";
+        }
+        return "exit code " + std::to_string(code);
+    }
+    return "unrecognised wait status " + std::to_string(status);
+}
+
 /**
  * @brief Execute a shell command and capture its stdout.
  *
@@ -239,7 +433,9 @@ execCommand(const std::string& cmd)
     int rc = pclose(pipe);
     if (rc != 0)
     {
-        std::cerr << "Command exited with code " << rc << "\n";
+        // Was "exited with code " << rc, which printed the wait status: a command exiting 1
+        // reported "code 256". [Co-developed with claude code -- Adam]
+        std::cerr << "Command failed (" << describeCommandStatus(rc, cmd) << "): " << cmd << "\n";
     }
     return result;
 }
@@ -399,6 +595,57 @@ logCurrentTimeSystemClock()
     SPDLOG_LOGGER_DEBUG(Logger::instance(), "Local Time: {}", buffer);
 }
 
+/**
+ * @brief Parse a MAC address, refusing anything that is not exactly one.
+ *
+ * @param mac Expected form `xx:xx:xx:xx:xx:xx` (`-` accepted as the separator too).
+ * @return The 48-bit value, or nullopt if @p mac is not a well-formed MAC.
+ *
+ * @details The previous implementation read six 2-digit fields at fixed offsets 0, 3, 6, 9, 12, 15
+ * without ever looking at `mac.size()`. It relied entirely on `std::from_chars` failing on whatever
+ * it happened to find, which is not the same as validating:
+ *
+ *   - `"00:11:22:33:44:5"` -- one digit short -- returned **73588229125**, silently. `from_chars`
+ *     parsed the single `5` and stopped at the terminator, reporting success. A wrong MAC means the
+ *     wrong host is looked up, with nothing anywhere saying so.
+ *   - Where it did fail it threw, and both HTTP handlers that call it let the throw escape to
+ *     `buildResponse`'s catch-all, which answers **500** for what is a malformed client request.
+ *
+ * Not an out-of-bounds read, which is worth writing down because it looks like one: the loop touches
+ * index 16 at most, and libstdc++ allocates `size() + 1` for the terminator while its short-string
+ * buffer is 16 bytes. Checked under ASan rather than assumed.
+ *
+ * [Co-developed with claude code -- Adam]
+ */
+inline static std::optional<uint64_t>
+tryMacToUint64(const std::string& mac)
+{
+    constexpr size_t kMacTextLength = 17; // 6 pairs + 5 separators
+    if (mac.size() != kMacTextLength)
+    {
+        return std::nullopt;
+    }
+
+    uint64_t result = 0;
+    for (size_t i = 0; i < 6; ++i)
+    {
+        const size_t at = i * 3;
+        if (i > 0 && mac[at - 1] != ':' && mac[at - 1] != '-')
+        {
+            return std::nullopt;
+        }
+        uint8_t byte = 0;
+        const auto [end, ec] = std::from_chars(mac.data() + at, mac.data() + at + 2, byte, 16);
+        // end must have consumed both digits: from_chars stops early on "5:" and reports success.
+        if (ec != std::errc() || end != mac.data() + at + 2)
+        {
+            return std::nullopt;
+        }
+        result = (result << 8) | byte;
+    }
+    return result;
+}
+
 /**
  * @brief Convert MAC address string ("aa:bb:cc:dd:ee:ff") to a 48-bit integer.
  *
@@ -409,24 +656,14 @@ logCurrentTimeSystemClock()
 inline uint64_t
 macToUint64(const std::string& mac)
 {
-    uint64_t result = 0;
-    auto parse_hex_byte = [&](const char* ptr) {
-        uint8_t byte = 0;
-        auto [p, ec] = std::from_chars(ptr, ptr + 2, byte, 16);
-        if (ec != std::errc())
-        {
-            throw std::invalid_argument("Invalid hex digit");
-        }
-        return byte;
-    };
-
-    const char* p = mac.data();
-    for (int i = 0; i < 6; ++i)
+    // [Co-developed with claude code -- Adam]
+    // Delegates so every caller gets the validation, not just the ones updated to use the
+    // optional form. See tryMacToUint64 for what was wrong.
+    if (const auto parsed = tryMacToUint64(mac))
     {
-        result <<= 8;
-        result |= parse_hex_byte(p + i * 3);
+        return *parsed;
     }
-    return result;
+    throw std::invalid_argument("Invalid MAC address: " + mac);
 }
 
 /**

```


# PART E —— 七個外部工具的原始碼（完整檔案，已加行號，請引用行號）


===== 工具：Web-GUI（TypeScript / React / Vite，瀏覽器端） =====
這是整個 GUI 唯一的 kernel API 封裝層。注意最上方的 handleResponse 與 fetchApi —— 所有端點都經過它。

檔案：`Web-GUI/src/api/index.ts`

```ts
     1	const NDT_API_BASE_URL = import.meta.env.VITE_NDT_API_BASE_URL;
     2	
     3	// Local API server for node positions (runs in Docker, accessible from browser)
     4	const NODE_POSITIONS_API_URL =
     5	  import.meta.env.VITE_NODE_POSITIONS_API_URL || 'http://localhost:3001';
     6	
     7	export const handleResponse = async (response: Response) => {
     8	  if (!response.ok) {
     9	    const errorData = await response.json().catch(() => null);
    10	    throw new Error(errorData?.error || `API Error: ${response.status}`);
    11	  }
    12	  const jsonData = await response.json();
    13	  return jsonData;
    14	};
    15	
    16	const fetchApi = async (endpoint: string, options = {}) => {
    17	  try {
    18	    const response = await fetch(`${endpoint}`, {
    19	      ...options,
    20	      headers: {
    21	        'Content-Type': 'application/json',
    22	        ...(options as any).headers,
    23	      },
    24	    });
    25	    return handleResponse(response);
    26	  } catch (error) {
    27	    console.error(`API request failed: ${endpoint}`);
    28	    throw error;
    29	  }
    30	};
    31	
    32	// Authentication removed - no longer needed
    33	
    34	export const get_graph_data = {
    35	  get_graph_data: async () =>
    36	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_graph_data`),
    37	};
    38	
    39	export const get_cpu_utilization = {
    40	  get_cpu_utilization: async () =>
    41	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_cpu_utilization`),
    42	};
    43	
    44	export const get_memory_utilization = {
    45	  get_memory_utilization: async () =>
    46	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_memory_utilization`),
    47	};
    48	
    49	export const get_temperature = {
    50	  get_temperature: async () =>
    51	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_temperature`),
    52	};
    53	
    54	export const get_nickname = {
    55	  get_nickname: async (params: {
    56	    dpid?: number;
    57	    mac?: string;
    58	    name?: string;
    59	  }) => {
    60	    const queryParams = new URLSearchParams();
    61	    if (params.dpid !== undefined) {
    62	      queryParams.append('dpid', params.dpid.toString());
    63	    } else if (params.mac) {
    64	      queryParams.append('mac', params.mac);
    65	    } else if (params.name) {
    66	      queryParams.append('name', params.name);
    67	    }
    68	
    69	    const url = `${NDT_API_BASE_URL}/ndt/get_nickname${queryParams.toString() ? `?${queryParams.toString()}` : ''}`;
    70	    return fetchApi(url);
    71	  },
    72	};
    73	
    74	export const get_flow_table_data = {
    75	  get_flow_table_data: async () =>
    76	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_detected_flow_data`),
    77	};
    78	
    79	export const get_top_k_flow_table_data = {
    80	  get_top_k_flow_table_data: async (k: number) => {
    81	    const queryParams = new URLSearchParams();
    82	    queryParams.append('k', k.toString());
    83	    return fetchApi(
    84	      `${NDT_API_BASE_URL}/ndt/get_detected_top_k_flow_data?${queryParams.toString()}`
    85	    );
    86	  },
    87	};
    88	
    89	export const modify_device_name = {
    90	  modify_device_name: async ({
    91	    vertex_type,
    92	    dpid,
    93	    mac,
    94	    new_name,
    95	  }: {
    96	    vertex_type: number;
    97	    dpid?: number;
    98	    mac?: string;
    99	    new_name: string;
   100	  }) => {
   101	    const body: any = { vertex_type, new_name };
   102	    if (vertex_type === 0 && dpid !== undefined) {
   103	      body.dpid = dpid;
   104	    } else if (vertex_type === 1 && mac) {
   105	      body.mac = mac;
   106	    }
   107	    return fetchApi(`${NDT_API_BASE_URL}/ndt/modify_device_name`, {
   108	      method: 'POST',
   109	      body: JSON.stringify(body),
   110	    });
   111	  },
   112	  modify_nickname: async (params: {
   113	    identifier: { type: 'dpid' | 'mac' | 'name'; value: number | string };
   114	    new_nickname: string;
   115	  }) => {
   116	    return fetchApi(`${NDT_API_BASE_URL}/ndt/modify_nickname`, {
   117	      method: 'POST',
   118	      body: JSON.stringify(params),
   119	    });
   120	  },
   121	};
   122	
   123	// Flow entry management APIs
   124	export const flowEntry = {
   125	  // New batch operation API
   126	  // According to API spec:
   127	  // - install_flow_entries: dpid, match, actions required; priority optional (defaults to 0)
   128	  // - modify_flow_entries: dpid, match, actions required; priority optional (defaults to 0)
   129	  // - delete_flow_entries: dpid, match required
   130	  install_modify_delete_flow_entries: async (data: {
   131	    install_flow_entries?: Array<{
   132	      dpid: number;
   133	      priority?: number;
   134	      match: object;
   135	      actions: Array<{
   136	        type: string;
   137	        port?: number;
   138	      }>;
   139	    }>;
   140	    modify_flow_entries?: Array<{
   141	      dpid: number;
   142	      priority?: number;
   143	      match: object;
   144	      actions: Array<{
   145	        type: string;
   146	        port?: number;
   147	      }>;
   148	    }>;
   149	    delete_flow_entries?: Array<{
   150	      dpid: number;
   151	      match: object;
   152	    }>;
   153	  }) =>
   154	    fetchApi(
   155	      `${NDT_API_BASE_URL}/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries`,
   156	      {
   157	        method: 'POST',
   158	        body: JSON.stringify(data),
   159	      }
   160	    ),
   161	
   162	  get_switch_openflow_table_entries: async () =>
   163	    fetchApi(`${NDT_API_BASE_URL}/ndt/get_switch_openflow_table_entries`),
   164	};
   165	
   166	// This function saves and loads the positions of nodes in the topology
   167	// Uses PostgreSQL database via local API server
   168	export const node_positions = {
   169	  save: async (nodes: any[]) => {
   170	    try {
   171	      // Transform node data to match database schema
   172	      // nodes have: { id, x, y, type }
   173	      // database expects: { node_id, x, y, type }
   174	      const nodePositions = nodes.map(node => ({
   175	        node_id: node.id,
   176	        x: parseFloat(node.x.toString()),
   177	        y: parseFloat(node.y.toString()),
   178	        type: node.type || null,
   179	      }));
   180	
   181	      console.log(
   182	        `Saving node positions to: ${NODE_POSITIONS_API_URL}/api/node_positions`
   183	      );
   184	      const response = await fetchApi(
   185	        `${NODE_POSITIONS_API_URL}/api/node_positions`,
   186	        {
   187	          method: 'POST',
   188	          body: JSON.stringify({ nodes: nodePositions }),
   189	        }
   190	      );
   191	
   192	      console.log(`Successfully saved ${nodePositions.length} node positions`);
   193	      return {
   194	        success: true,
   195	        message: 'Node positions saved to PostgreSQL',
   196	        ...response,
   197	      };
   198	    } catch (error) {
   199	      console.error('Failed to save node positions:', error);
   200	      console.error(
   201	        `API URL was: ${NODE_POSITIONS_API_URL}/api/node_positions`
   202	      );
   203	      // Fallback to localStorage if API fails
   204	      try {
   205	        localStorage.setItem('node_positions', JSON.stringify({ nodes }));
   206	        console.warn('Fell back to localStorage due to API error');
   207	        return {
   208	          success: true,
   209	          message: 'Node positions saved to localStorage (fallback)',
   210	        };
   211	      } catch (localError) {
   212	        console.error('Failed to save to localStorage:', localError);
   213	        throw error;
   214	      }
   215	    }
   216	  },
   217	  load: async () => {
   218	    try {
   219	      console.log(
   220	        `Loading node positions from: ${NODE_POSITIONS_API_URL}/api/node_positions`
   221	      );
   222	      const response = await fetchApi(
   223	        `${NODE_POSITIONS_API_URL}/api/node_positions`
   224	      );
   225	
   226	      // Response should have: { success: true, nodes: [{ node_id, x, y, type }] }
   227	      if (response.success && response.nodes) {
   228	        console.log(
   229	          `Successfully loaded ${response.nodes.length} node positions`
   230	        );
   231	        return {
   232	          success: true,
   233	          nodes: response.nodes,
   234	        };
   235	      }
   236	
   237	      return { success: true, nodes: [] };
   238	    } catch (error) {
   239	      console.error('Failed to load node positions from API:', error);
   240	      console.error(
   241	        `API URL was: ${NODE_POSITIONS_API_URL}/api/node_positions`
   242	      );
   243	      // Fallback to localStorage if API fails
   244	      try {
   245	        const stored = localStorage.getItem('node_positions');
   246	        if (stored) {
   247	          const data = JSON.parse(stored);
   248	          // Transform localStorage data to match expected format
   249	          const nodes = (data.nodes || []).map((node: any) => ({
   250	            node_id: node.id || node.node_id,
   251	            x: node.x,
   252	            y: node.y,
   253	            type: node.type || null,
   254	          }));
   255	          console.warn('Loaded from localStorage (fallback)');
   256	          return { success: true, nodes };
   257	        }
   258	        return { success: true, nodes: [] };
   259	      } catch (localError) {
   260	        console.error('Failed to load from localStorage:', localError);
   261	        return { success: false, nodes: [] };
   262	      }
   263	    }
   264	  },
   265	};

```


===== 工具：Web-GUI（LLM / Intent Translator 面板） =====
呼叫 /ndt/intent_translator/text。

檔案：`Web-GUI/src/components/llm/LLM.ts`

```ts
     1	import OpenAI from 'openai';
     2	
     3	const token = import.meta.env.VITE_GITHUB_TOKEN;
     4	const endpoint = 'https://models.github.ai/inference';
     5	const modelName = 'openai/o1';
     6	
     7	// NDT API base URL
     8	const NDT_API_BASE_URL = import.meta.env.VITE_NDT_API_BASE_URL;
     9	
    10	// New function to call NDT server LLM API
    11	export async function callNDTLLM(
    12	  userInput: string,
    13	  sessionId?: string
    14	): Promise<any> {
    15	  const session =
    16	    sessionId ||
    17	    `session-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    18	
    19	  try {
    20	    const response = await fetch(
    21	      `${NDT_API_BASE_URL}/ndt/intent_translator/text`,
    22	      {
    23	        method: 'POST',
    24	        headers: {
    25	          'Content-Type': 'application/json',
    26	        },
    27	        body: JSON.stringify({
    28	          prompt: userInput,
    29	          session: session,
    30	        }),
    31	      }
    32	    );
    33	
    34	    if (!response.ok) {
    35	      throw new Error(`HTTP error! status: ${response.status}`);
    36	    }
    37	
    38	    const data = await response.json();
    39	    return data;
    40	  } catch (error) {
    41	    console.error('Error calling NDT LLM API:', error);
    42	    throw error;
    43	  }
    44	}
    45	
    46	export async function callChatWidgetLLM(userInput: string): Promise<string> {
    47	  const client = new OpenAI({
    48	    baseURL: endpoint,
    49	    apiKey: token,
    50	    dangerouslyAllowBrowser: true,
    51	  });
    52	
    53	  const response = await client.chat.completions.create({
    54	    messages: [
    55	      {
    56	        role: 'user',
    57	        content: `You are NDTwin Assistant. You assist users with questions about the current network topology and related information. Pretend you already know the answers and respond to user queries confidently. Even if you encounter a question you don't know, respond with a serious tone and make up an answer. The User input: ${userInput}. Please give the response to the user.`,
    58	      },
    59	    ],
    60	    model: modelName,
    61	  });
    62	
    63	  return response.choices[0].message.content || '';
    64	}

```


===== 工具：Energy-Saving-App（C++，Boost.Beast 客戶端） =====
節能應用。會裝流表、改流表、關交換機電源、取鎖。注意它的 post/get 回傳 std::pair<int, json>（狀態碼 ＋ 已解析的 body），所以它看得到狀態碼 —— 請檢查每個呼叫點如何使用那個 int。

檔案：`Energy-Saving-App/src/app/http.cpp`

```cpp
     1	#include "app/http.hpp"
     2	#include "app/settings.hpp"
     3	#include "utils/Logger.hpp"
     4	#include "utils/common.hpp"
     5	
     6	#include <boost/asio/connect.hpp>
     7	#include <boost/asio/ip/tcp.hpp>
     8	#include <boost/beast/core.hpp>
     9	#include <boost/beast/http.hpp>
    10	#include <boost/beast/version.hpp>
    11	#include <boost/stacktrace.hpp>
    12	#include <cstdlib>
    13	#include <fstream>
    14	#include <iostream>
    15	#include <nlohmann/json.hpp>
    16	#include <optional>
    17	#include <string>
    18	
    19	namespace beast = boost::beast;
    20	namespace http = beast::http;
    21	namespace net = boost::asio;
    22	using tcp = net::ip::tcp;
    23	using json = nlohmann::json;
    24	
    25	std::optional<std::pair<uint32_t, json>> send_get_json_request(const std::string host, const std::string port,
    26	                                                               const std::string &target)
    27	{
    28	    try
    29	    {
    30	        // Build io_context
    31	        net::io_context ioc;
    32	
    33	        // Parse host
    34	        tcp::resolver resolver(ioc);
    35	        beast::tcp_stream stream(ioc);
    36	        auto const results = resolver.resolve(host, port);
    37	        stream.connect(results);
    38	
    39	        // Prepare HTTP GET request
    40	        http::request<http::string_body> req{http::verb::get, target, 11};
    41	        req.set(http::field::host, host);
    42	        req.set(http::field::user_agent, BOOST_BEAST_VERSION_STRING);
    43	
    44	        std::cout << "GET from " << target << std::endl;
    45	
    46	        // Send request
    47	        http::write(stream, req);
    48	
    49	        // Receive response
    50	        beast::flat_buffer buffer;
    51	        http::response<http::string_body> res;
    52	        http::read(stream, buffer, res);
    53	
    54	        // std::cout << "POST reponse code: " << res.result_int() << std::endl;
    55	
    56	        // Close connection
    57	        beast::error_code ec;
    58	        stream.socket().shutdown(tcp::socket::shutdown_both, ec);
    59	
    60	        // Return body and turn to json
    61	        return std::make_pair(res.result_int(), json::parse(res.body()));
    62	    }
    63	    catch (const std::exception &e)
    64	    {
    65	        std::cerr << "Error: " << e.what() << "\n";
    66	        std::cerr << boost::stacktrace::stacktrace();
    67	        return std::nullopt;
    68	    }
    69	}
    70	
    71	std::optional<std::pair<uint32_t, json>> send_post_json_request(const std::string host, const std::string port,
    72	                                                                const std::string &target, const json &body_json)
    73	{
    74	    try
    75	    {
    76	        // Build io_context
    77	        net::io_context ioc;
    78	
    79	        // Parse host
    80	        tcp::resolver resolver(ioc);
    81	        beast::tcp_stream stream(ioc);
    82	        auto const results = resolver.resolve(host, port);
    83	        stream.connect(results);
    84	
    85	        // Prepare HTTP POST request
    86	        http::request<http::string_body> req{http::verb::post, target, 11};
    87	        req.set(http::field::host, host);
    88	        req.set(http::field::user_agent, BOOST_BEAST_VERSION_STRING);
    89	        req.set(http::field::content_type, "application/json");
    90	
    91	        if (body_json != nullptr)
    92	        {
    93	            req.body() = body_json.dump();
    94	            req.prepare_payload();
    95	        }
    96	
    97	        SPDLOG_LOGGER_INFO(Logger::instance(), "POST to {}", target);
    98	
    99	        // Send request
   100	        http::write(stream, req);
   101	
   102	        // Receive response
   103	        beast::flat_buffer buffer;
   104	        http::response<http::string_body> res;
   105	        http::read(stream, buffer, res);
   106	
   107	        // std::cout << "POST reponse code: " << res.result_int() << std::endl;
   108	
   109	        // CLose connection
   110	        beast::error_code ec;
   111	        stream.socket().shutdown(tcp::socket::shutdown_both, ec);
   112	
   113	        // Return body and turn to json
   114	        return std::make_pair(res.result_int(), json::parse(res.body()));
   115	    }
   116	    catch (const std::exception &e)
   117	    {
   118	        std::cerr << "Error: " << e.what() << "\n";
   119	        std::cerr << boost::stacktrace::stacktrace();
   120	        return std::nullopt;
   121	    }
   122	}
   123	
   124	std::optional<uint32_t> set_switches_power_state(const uint64_t ip, const bool on)
   125	{
   126	    const std::string target =
   127	        "/ndt/set_switches_power_state?ip=" + utils::ip_to_string(ip) + "&action=" + (on ? "on" : "off");
   128	
   129	    auto result = send_post_json_request(ndt_ip, ndt_port, target, nullptr);
   130	
   131	    if (!result)
   132	    {
   133	        std::cout << "No result.\n";
   134	        return std::nullopt;
   135	    }
   136	
   137	    auto [code, body] = *result;
   138	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   139	
   140	    return code;
   141	}
   142	
   143	json to_install_or_modify_flow_entry_json(uint64_t dpid, uint32_t priority, uint32_t dstIp, uint32_t newOutInterface)
   144	{
   145	    return json{{"dpid", dpid},
   146	                {"priority", priority},
   147	                {"match", {{"eth_type", 2048}, {"ipv4_dst", utils::ip_to_string(dstIp)}}},
   148	                {"actions", json::array({{{"type", "OUTPUT"}, {"port", newOutInterface}}})}};
   149	}
   150	
   151	json to_delete_flow_entry_json(uint64_t dpid, uint32_t dstIp)
   152	{
   153	    return json{{"dpid", dpid}, {"match", {{"eth_type", 2048}, {"ipv4_dst", utils::ip_to_string(dstIp)}}}};
   154	}
   155	
   156	std::optional<uint32_t> install_flow_entry(uint64_t dpid, const sflow::FlowChange &change, uint32_t priority)
   157	{
   158	    const std::string target = "/ndt/install_flow_entry";
   159	
   160	    json body_json = to_install_or_modify_flow_entry_json(dpid, priority, change.dstIp, change.newOutInterface);
   161	
   162	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   163	
   164	    if (!result)
   165	    {
   166	        std::cout << "No result.\n";
   167	        return std::nullopt;
   168	    }
   169	
   170	    auto [code, body] = *result;
   171	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   172	
   173	    return code;
   174	}
   175	
   176	std::optional<uint32_t> modify_flow_entry(uint64_t dpid, const sflow::FlowChange &change, uint32_t priority)
   177	{
   178	    const std::string target = "/ndt/modify_flow_entry";
   179	
   180	    json body_json = to_install_or_modify_flow_entry_json(dpid, priority, change.dstIp, change.newOutInterface);
   181	
   182	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   183	
   184	    SPDLOG_LOGGER_INFO(Logger::instance(), "switch: {}, match: {}, output port: {}", dpid,
   185	                       utils::ip_to_string(change.dstIp), change.newOutInterface);
   186	
   187	    if (!result)
   188	    {
   189	        std::cout << "No result.\n";
   190	        return std::nullopt;
   191	    }
   192	
   193	    auto [code, body] = *result;
   194	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   195	
   196	    return code;
   197	}
   198	
   199	std::optional<uint32_t> delete_flow_entry(uint64_t dpid, const sflow::FlowChange &change)
   200	{
   201	    const std::string target = "/ndt/delete_flow_entry";
   202	
   203	    json body_json = to_delete_flow_entry_json(dpid, change.dstIp);
   204	
   205	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   206	
   207	    if (!result)
   208	    {
   209	        std::cout << "No result.\n";
   210	        return std::nullopt;
   211	    }
   212	
   213	    auto [code, body] = *result;
   214	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   215	
   216	    return code;
   217	}
   218	
   219	std::optional<uint32_t> install_modify_delete_flow_entries(const std::vector<sflow::FlowDiff> &diffs)
   220	{
   221	    const std::string target = "/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries";
   222	
   223	    json install_flow_entries = json::array();
   224	    json modify_flow_entries = json::array();
   225	    json delete_flow_entries = json::array();
   226	
   227	    for (const auto &diff : diffs)
   228	    {
   229	        for (auto &change : diff.added)
   230	            install_flow_entries.push_back( // TODO: Don't make priority hard-coded
   231	                to_install_or_modify_flow_entry_json(diff.dpid, 10, change.dstIp, change.newOutInterface));
   232	        for (auto &change : diff.modified)
   233	            modify_flow_entries.push_back( // TODO: Don't make priority hard-coded
   234	                to_install_or_modify_flow_entry_json(diff.dpid, 10, change.dstIp, change.newOutInterface));
   235	        for (auto &change : diff.removed)
   236	            delete_flow_entries.push_back(to_delete_flow_entry_json(diff.dpid, change.dstIp));
   237	    }
   238	
   239	    SPDLOG_LOGGER_INFO(Logger::instance(),
   240	                       "install_flow_entries len {} modify_flow_entries len {} delete_flow_entries len {}",
   241	                       install_flow_entries.size(), modify_flow_entries.size(), delete_flow_entries.size());
   242	
   243	    json body_json{
   244	        {"install_flow_entries", std::move(install_flow_entries)},
   245	        {"modify_flow_entries", std::move(modify_flow_entries)},
   246	        {"delete_flow_entries", std::move(delete_flow_entries)},
   247	    };
   248	
   249	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   250	
   251	    if (!result)
   252	    {
   253	        std::cout << "No result.\n";
   254	        return std::nullopt;
   255	    }
   256	
   257	    auto [code, body] = *result;
   258	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   259	
   260	    return code;
   261	}
   262	
   263	std::optional<std::vector<sflow::FlowDiff>> disable_switch(const uint64_t dpid)
   264	{
   265	    try
   266	    {
   267	        std::cout << "disable_switch: " << dpid << std::endl;
   268	
   269	        const std::string target = "/ndt/disable_switch";
   270	
   271	        // Build JSON
   272	        json j;
   273	        j["dpid"] = dpid;
   274	
   275	        auto result = send_post_json_request(ndt_ip, ndt_port, target, j);
   276	
   277	        if (!result)
   278	        {
   279	            std::cout << "No result.\n";
   280	            return std::nullopt;
   281	        }
   282	
   283	        auto [code, body] = *result;
   284	        SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}, Body: {}", code, body.dump());
   285	
   286	        std::vector<sflow::FlowDiff> flowDiffs = body.get<std::vector<sflow::FlowDiff>>();
   287	
   288	        // Show results
   289	        SPDLOG_LOGGER_INFO(Logger::instance(), "new Openflow Tables");
   290	        for (const auto &diff : flowDiffs)
   291	        {
   292	            SPDLOG_LOGGER_INFO(Logger::instance(), "Switch DPID: {}, added: {}, removed: {}, modified: {}", diff.dpid,
   293	                               diff.added.size(), diff.removed.size(), diff.modified.size());
   294	        }
   295	
   296	        return flowDiffs;
   297	    }
   298	    catch (std::exception const &e)
   299	    {
   300	        std::cerr << "Error: " << e.what() << std::endl;
   301	        std::cerr << boost::stacktrace::stacktrace();
   302	        return std::nullopt;
   303	    }
   304	}
   305	
   306	json get_switch_openflow_table_entries()
   307	{
   308	    const std::string target = "/ndt/get_switch_openflow_table_entries";
   309	
   310	    auto result = send_get_json_request(ndt_ip, ndt_port, target);
   311	
   312	    if (!result)
   313	    {
   314	        std::cout << "No result.\n";
   315	        return json::object();
   316	    }
   317	
   318	    auto [code, body] = *result;
   319	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}", code);
   320	
   321	    if (code != 200 || body.is_null())
   322	    {
   323	        SPDLOG_LOGGER_ERROR(Logger::instance(), "get_switch_openflow_table_entries: bad HTTP code {} or null body: {}",
   324	                            code, body.dump());
   325	        return json::object();
   326	    }
   327	
   328	    std::ofstream out("SwitchFlowRuleTables.json");
   329	    out << body.dump();
   330	    out.close();
   331	
   332	    return body;
   333	}
   334	
   335	json get_graph_data()
   336	{
   337	    const std::string target = "/ndt/get_graph_data";
   338	
   339	    auto result = send_get_json_request(ndt_ip, ndt_port, target);
   340	
   341	    if (!result)
   342	    {
   343	        std::cout << "No result.\n";
   344	        return json::object();
   345	    }
   346	
   347	    // Structured binding
   348	    auto [code, body] = *result;
   349	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}", code);
   350	
   351	    if (code != 200 || body.is_null())
   352	    {
   353	        SPDLOG_LOGGER_ERROR(Logger::instance(), "get_graph_data: bad HTTP code {} or null body: {}", code, body.dump());
   354	        return json::object();
   355	    }
   356	
   357	    std::ofstream out("Graph.json");
   358	    out << body.dump();
   359	    out.close();
   360	
   361	    return body;
   362	}
   363	
   364	json get_detected_flow_data()
   365	{
   366	    const std::string target = "/ndt/get_detected_flow_data";
   367	
   368	    auto result = send_get_json_request(ndt_ip, ndt_port, target);
   369	
   370	    if (!result)
   371	    {
   372	        std::cout << "No result.\n";
   373	        return json::array();
   374	    }
   375	
   376	    auto [code, body] = *result;
   377	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}", code);
   378	
   379	    if (code != 200 || body.is_null())
   380	    {
   381	        SPDLOG_LOGGER_ERROR(Logger::instance(), "get_detected_flow_data: bad HTTP code {} or null body: {}", code,
   382	                            body.dump());
   383	        return json::object();
   384	    }
   385	
   386	    std::ofstream out("FlowDataList.json");
   387	    out << body.dump();
   388	    out.close();
   389	
   390	    return body;
   391	}
   392	
   393	double get_average_link_usage()
   394	{
   395	    const std::string target = "/ndt/get_average_link_usage";
   396	
   397	    auto result = send_get_json_request(ndt_ip, ndt_port, target);
   398	
   399	    if (!result)
   400	    {
   401	        std::cout << "No result.\n";
   402	        return json::array();
   403	    }
   404	
   405	    auto [code, body] = *result;
   406	
   407	    if (code != 200 || body.is_null())
   408	    {
   409	        SPDLOG_LOGGER_ERROR(Logger::instance(), "get_average_link_usage: bad HTTP code {} or null body: {}", code,
   410	                            body.dump());
   411	        return -1;
   412	    }
   413	
   414	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code: {}", code);
   415	
   416	    SPDLOG_LOGGER_INFO(Logger::instance(), "avg_link_usage {}", std::to_string(body["avg_link_usage"].get<double>()));
   417	
   418	    return body["avg_link_usage"].get<double>();
   419	}
   420	
   421	bool acquire_lock()
   422	{
   423	    const std::string target = "/ndt/acquire_lock";
   424	
   425	    json body_json{{"ttl", 300}, {"type", "routing_lock"}};
   426	
   427	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   428	
   429	    if (!result)
   430	    {
   431	        std::cout << "No result.\n";
   432	        return false;
   433	    }
   434	
   435	    auto [code, body] = *result;
   436	
   437	    if (code != 200 || body.is_null())
   438	    {
   439	        SPDLOG_LOGGER_ERROR(Logger::instance(), "acquire_lock: bad HTTP code {} or null body: {}", code, body.dump());
   440	        return false;
   441	    }
   442	
   443	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code {}", code);
   444	
   445	    if (body.value("status", "") != "")
   446	    {
   447	        SPDLOG_LOGGER_INFO(Logger::instance(), "acquire_lock succeeded");
   448	        return true;
   449	    }
   450	    else
   451	    {
   452	        SPDLOG_LOGGER_INFO(Logger::instance(), "acquire_lock failed");
   453	        return false;
   454	    }
   455	}
   456	
   457	bool release_lock()
   458	{
   459	    const std::string target = "/ndt/release_lock";
   460	
   461	    json body_json{{"type", "routing_lock"}};
   462	
   463	    auto result = send_post_json_request(ndt_ip, ndt_port, target, body_json);
   464	
   465	    if (!result)
   466	    {
   467	        std::cout << "No result.\n";
   468	        return false;
   469	    }
   470	
   471	    auto [code, body] = *result;
   472	
   473	    if (code != 200 || body.is_null())
   474	    {
   475	        SPDLOG_LOGGER_ERROR(Logger::instance(), "release_lock: bad HTTP code {} or null body: {}", code, body.dump());
   476	        return false;
   477	    }
   478	
   479	    SPDLOG_LOGGER_INFO(Logger::instance(), "Code {}", code);
   480	
   481	    if (body.value("status", "") != "")
   482	    {
   483	        SPDLOG_LOGGER_INFO(Logger::instance(), "release_lock succeeded");
   484	        return true;
   485	    }
   486	    else
   487	    {
   488	        SPDLOG_LOGGER_INFO(Logger::instance(), "release_lock failed");
   489	        return false;
   490	    }
   491	}

```


===== 工具：Network-State-Recorder（Python，週期性快照記錄器） =====
長時間執行，週期性抓 graph 與 flow 資料寫檔。

檔案：`Network-State-Recorder/network_state_recorder.py`

```python
     1	"""
     2	This is a Network State Recorder (NSR) that periodically fetches network state data from 
     3	NDTwin and stores it in JSON files, which are then compressed into ZIP archives for efficient storage,
     4	and can be used for our Visualizer and Web-GUI to replay network states over time.
     5	"""
     6	from nornir import InitNornir
     7	from loguru import logger
     8	import orjson
     9	import requests
    10	import threading
    11	import time
    12	from datetime import datetime
    13	import queue
    14	import os
    15	from concurrent.futures import ProcessPoolExecutor
    16	import zipfile
    17	import signal
    18	import argparse
    19	import sys
    20	
    21	FLOWINFO_URL = "/ndt/get_detected_flow_data"
    22	
    23	GRAPHINFO_URL = "/ndt/get_graph_data"
    24	
    25	REQ_INTERVAL = 1  # in seconds
    26	STORAGE_INTERVAL = 300 # in seconds
    27	
    28	DIR = "./recorded_info"
    29	
    30	THREADS = []
    31	
    32	QUEUES = {}
    33	
    34	ZIP_PATH = queue.Queue()
    35	
    36	STOP_EVENT = threading.Event()
    37	
    38	FLOW_FINAL_EVENT = threading.Event()
    39	GRAPH_FINAL_EVENT = threading.Event()
    40	
    41	def zipper(file_path:str):
    42	    """
    43	    Compress a JSON file into a ZIP archive and remove the original file.
    44	    
    45	    Args:
    46	        file_path (str): The path to the JSON file to be compressed.
    47	    """
    48	    logger.debug(f"Zipping file: {file_path}...")
    49	    with zipfile.ZipFile(f"{file_path.replace('.json', '_json')}.zip", 'w', zipfile.ZIP_DEFLATED, compresslevel=4) as zipf:
    50	        zipf.write(file_path, os.path.basename(file_path))
    51	    logger.debug(f"Removing original file: {file_path}...")
    52	    os.remove(file_path)
    53	
    54	def zip_json_files():
    55	    """
    56	    Background thread function that continuously monitors the ZIP_PATH queue
    57	    and compresses JSON files in parallel using ProcessPoolExecutor.
    58	    
    59	    Runs until STOP_EVENT is set, then processes any remaining files in the queue.
    60	    """
    61	    global ZIP_PATH,DIR
    62	    while not STOP_EVENT.is_set():
    63	        paths = set()
    64	        # wait for files to zip
    65	        
    66	        while not ZIP_PATH.empty():
    67	            file_path = ZIP_PATH.get(timeout=REQ_INTERVAL)
    68	            paths.add(file_path)
    69	            logger.debug(f"Files to zip: {paths}")
    70	            ZIP_PATH.task_done()
    71	        
    72	        if len(paths) == 0:
    73	            time.sleep(REQ_INTERVAL)
    74	            continue
    75	
    76	        with ProcessPoolExecutor(max_workers=2) as executor:
    77	            logger.debug(f"Zipping files in parallel: {paths}...")
    78	            futures = [executor.submit(zipper, file_path) for file_path in paths]
    79	
    80	        for future in futures:
    81	            try:
    82	                future.result()
    83	            except Exception as e:
    84	                logger.error(f"Error zipping files: {e}")
    85	
    86	        logger.success(f"Files: {paths} zipped successfully.")
    87	
    88	    logger.info("Zipping last files... ")
    89	    while not FLOW_FINAL_EVENT.is_set() or not GRAPH_FINAL_EVENT.is_set():
    90	        logger.debug("Waiting for final files to be ready for zipping...")
    91	        time.sleep(REQ_INTERVAL)
    92	    logger.debug("All files are ready fot Zipping... ")
    93	    
    94	    paths = set()
    95	    while not ZIP_PATH.empty():
    96	        file_path = ZIP_PATH.get(timeout=REQ_INTERVAL)
    97	        paths.add(file_path)
    98	        ZIP_PATH.task_done()
    99	
   100	    for path in paths:
   101	        zipper(path)
   102	
   103	    logger.info("Zipping Stopped.")
   104	
   105	def write_data(queue_name):
   106	    """
   107	    Write data from a named queue to JSON files at regular intervals.
   108	    
   109	    Creates a new JSON file every STORAGE_INTERVAL seconds and writes
   110	    queued data items to it. Files are then added to ZIP_PATH for compression.
   111	    
   112	    Args:
   113	        queue_name (str): The name of the queue to read data from (e.g., 'flowinfo', 'graphinfo').
   114	    """
   115	    global QUEUES,ZIP_PATH
   116	    file_name = ""
   117	    while not STOP_EVENT.is_set(): # loop until stop event is set
   118	        start_time = time.time()
   119	        file_name = f"{DIR}/{datetime.fromtimestamp(start_time).strftime('%Y_%m_%d_%H-%M-%S')}_{queue_name}.json"
   120	        logger.info(f"Storing data from {queue_name} queue to file: {file_name}...")
   121	        # initialize empty file
   122	        with open(file_name,'wb') as f: # open a new JSON file
   123	            while time.time() - start_time < STORAGE_INTERVAL and not STOP_EVENT.is_set(): # In the interval of STORAGE_INTERVAL, write to same file.
   124	                while not QUEUES[queue_name].empty() and not STOP_EVENT.is_set(): # while there is data in the queue
   125	                    item = QUEUES[queue_name].get(timeout = 0.1)
   126	                    logger.debug(f"Writing item with timestamp {item['timestamp']} to {file_name}...")
   127	                    logger.trace(f"Item content: {item}")
   128	                    byte_item = orjson.dumps(item)
   129	                    f.write(byte_item)
   130	                    f.write(b"\n")
   131	                    QUEUES[queue_name].task_done()
   132	                time.sleep(REQ_INTERVAL-0.1)
   133	            
   134	            ZIP_PATH.put(file_name)
   135	            logger.info(f"Starting to zip stored JSON files : {file_name}...")
   136	
   137	    logger.info("Zipping remaining data to file before stopping...")
   138	    if file_name != "":
   139	        ZIP_PATH.put(file_name)
   140	
   141	    # make sure the last file can be zipped.
   142	    if queue_name == "flowinfo":
   143	        FLOW_FINAL_EVENT.set()
   144	    elif queue_name == "graphinfo":
   145	        GRAPH_FINAL_EVENT.set()
   146	
   147	    logger.info(f"Stopped data writing from {queue_name} queue...")
   148	
   149	
   150	def terminate(): 
   151	    """
   152	    Gracefully stop the NSR application by setting the STOP_EVENT
   153	    and waiting for all threads to complete before exiting.
   154	    """
   155	    global THREADS
   156	    logger.info("Stopping NSR...")
   157	    STOP_EVENT.set()
   158	    for t in THREADS:
   159	        t.join()
   160	    THREADS = []
   161	    time.sleep(2)
   162	    logger.info("NSR stopped.")    
   163	    exit(0)
   164	
   165	def request_data(url,queue_name, params=None):
   166	    """
   167	    Periodically fetch data from a REST API endpoint and store it in a queue.
   168	    
   169	    Sends GET requests at REQ_INTERVAL intervals and adds received data
   170	    with timestamps to the specified queue for later storage.
   171	    
   172	    Args:
   173	        url (str): The full URL of the API endpoint to request data from.
   174	        queue_name (str): The name of the queue to store received data.
   175	        params (dict, optional): Query parameters to include in the request. Defaults to None.
   176	    """
   177	    global QUEUES
   178	    try:
   179	        while not STOP_EVENT.is_set():
   180	            sleep_time = time.perf_counter_ns()
   181	            if queue_name not in QUEUES:
   182	                QUEUES[queue_name] = queue.Queue()
   183	            response = requests.get(url, params=params)
   184	            if response.status_code == 200:
   185	                # add received data to queue with timestamp in ms
   186	                current = int(datetime.now().timestamp()*1000)
   187	                data = {"timestamp": current}
   188	                if queue_name == "flowinfo":
   189	                    data['flowinfo'] = response.json()
   190	                elif queue_name == "graphinfo":
   191	                    data = {**data, **response.json()}
   192	                if not response.json():
   193	                    logger.warning(f"No new data from {url}.")
   194	
   195	                logger.trace(f"Received {data} from {url}.")
   196	
   197	                QUEUES[queue_name].put(data)
   198	
   199	            else:
   200	                response.raise_for_status()
   201	
   202	            sleep_time = REQ_INTERVAL - ((time.perf_counter_ns() - sleep_time) / 1e9)
   203	            logger.trace(f"Next request to {url} in {sleep_time:.2f} seconds.")
   204	
   205	            if sleep_time < 0:
   206	                continue
   207	
   208	            if STOP_EVENT.wait(timeout=sleep_time):
   209	                break  # STOP_EVENT was set, exit loop
   210	
   211	        logger.info(f"Stopped data request from {url}...")
   212	    except requests.RequestException as e:
   213	        logger.error(f"Error fetching data: {e}")
   214	        return None
   215	
   216	def ndtwin_alive()->bool:
   217	    """
   218	    Check if the NDTwin server is reachable and responding.
   219	    
   220	    Returns:
   221	        bool: True if the server responds with status code 200, False otherwise.
   222	    """
   223	    try:
   224	        response = requests.get(FLOWINFO_URL)
   225	        if response.status_code == 200:
   226	            return True
   227	        else:
   228	            return False
   229	    except requests.RequestException as e:
   230	        logger.error(f"Error checking NDTwin server status: {e}")
   231	        return False
   232	
   233	def logger_config(level:str="DEBUG", display_on_console:bool=True):
   234	    """
   235	    Configure the loguru logger with file rotation and formatting.
   236	    
   237	    Sets up daily log rotation with colored output and diagnostic information.
   238	    
   239	    Args:
   240	        level (str): The minimum logging level to capture (e.g., 'DEBUG', 'INFO', 'WARNING'). Defaults to 'DEBUG'.
   241	        display_on_console (bool): Whether to enable real-time logging output. Defaults to True.
   242	    """
   243	    logger.remove(0)
   244	    if display_on_console:
   245	        logger.add(
   246	            sys.stdout,
   247	            format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level} : {message}</level>",
   248	            colorize=True,
   249	            backtrace=True,
   250	            diagnose=True,
   251	            level = level
   252	        )
   253	    else:
   254	        logger.add(
   255	            "logs/NSR_{time:YYYY-MM-DD}.log",
   256	            format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level} : {message}</level>",
   257	            colorize=True,
   258	            backtrace=True,
   259	            diagnose=True,
   260	            rotation= "1 day",
   261	            level = level
   262	        )
   263	
   264	def start():
   265	    """
   266	    Initialize and start the NSR (Network State Recorder) application.
   267	    
   268	    Reads configuration from NSR.yaml using Nornir, validates NDTwin server
   269	    connectivity, creates necessary directories, and spawns threads for:
   270	    - Fetching flow info data from NDTwin API
   271	    - Fetching graph info data from NDTwin API  
   272	    - Writing queued data to JSON files
   273	    - Compressing stored JSON files into ZIP archives
   274	    """
   275	    global THREADS,FLOWINFO_URL,GRAPHINFO_URL,REQ_INTERVAL,STORAGE_INTERVAL
   276	    config = InitNornir(config_file="NSR.yaml")
   277	    try:
   278	        # config
   279	        if config.inventory.hosts.get("Recorder") is not None:
   280	            display_on_console = config.inventory.hosts["Recorder"].data.get("display_on_console",True)
   281	            logger_config(level=config.inventory.hosts["Recorder"].data.get("log_level","INFO"), display_on_console=display_on_console)
   282	            ndtwin_kernel = config.inventory.hosts["Recorder"].data.get("ndtwin_kernel","http://127.0.0.1:8000")
   283	            FLOWINFO_URL = ndtwin_kernel + FLOWINFO_URL
   284	            GRAPHINFO_URL = ndtwin_kernel + GRAPHINFO_URL
   285	            REQ_INTERVAL = config.inventory.hosts["Recorder"].data.get("request_interval",1)
   286	            STORAGE_INTERVAL = config.inventory.hosts["Recorder"].data.get("storage_interval",5) * 60
   287	        else:
   288	            logger.error("No Recorder setting found, exiting...")
   289	            return
   290	        
   291	        logger.info(f"Recorder settings: NDTwin server: {ndtwin_kernel}, Request interval: {REQ_INTERVAL} seconds, Storage interval: {int(STORAGE_INTERVAL/60)} minutes")
   292	
   293	        if not ndtwin_alive():
   294	            logger.error("NDTwin server is not reachable, exiting...")
   295	            exit(1)
   296	
   297	        os.makedirs(DIR, exist_ok=True)
   298	
   299	        logger.info("Starting NSR...")
   300	        # start threads
   301	        flowinfo_thread = threading.Thread(target=request_data, args=(FLOWINFO_URL,'flowinfo'))
   302	        flowinfo_write_process = threading.Thread(target=write_data, args=('flowinfo',))
   303	        
   304	
   305	        graphinfo_thread = threading.Thread(target=request_data, args=(GRAPHINFO_URL,'graphinfo'))
   306	        graphinfo_write_process = threading.Thread(target=write_data, args=('graphinfo',))
   307	
   308	        zip_process = threading.Thread(target=zip_json_files)
   309	
   310	        THREADS.append(flowinfo_thread)
   311	        THREADS.append(flowinfo_write_process)
   312	        THREADS.append(graphinfo_thread)
   313	        THREADS.append(graphinfo_write_process)
   314	        THREADS.append(zip_process)
   315	
   316	        for thread in THREADS:
   317	            thread.start()
   318	
   319	        logger.success("All components started successfully.")
   320	        logger.success("NSR is running.") 
   321	
   322	    except Exception as e:
   323	        logger.warning(f"Fail reading Recorder setting: {e}")
   324	        return
   325	    
   326	
   327	
   328	if __name__ == '__main__':
   329	    signal.signal(signal.SIGINT, lambda s, f: terminate())
   330	    signal.signal(signal.SIGTERM, lambda s, f: terminate())
   331	    start()
   332	    while True:
   333	        time.sleep(1)

```


===== 工具：Network-Traffic-Generator（Python，流量產生器的距離分群工具） =====
用 get_path_switch_count 與 get_graph_data 依跳數分群主機對。注意 get_path_switch_count 是有被改動的 handler 之一。

檔案：`Network-Traffic-Generator/Utilis/distance_seperate.py`

```python
     1	"""
     2	NTG Utilis - Distance Separate Module.
     3	
     4	Get current hosts in topology and paths of host pair.
     5	
     6	Partition the unique paths array to {near,middle,far} set.
     7	
     8	"""
     9	import requests
    10	import json
    11	from collections import deque
    12	import ipaddress
    13	import numpy as np
    14	
    15	GET_HOSTS = ""
    16	GET_PATHS = ""
    17	
    18	
    19	def get_hosts():
    20	    """
    21	    Get host's ip from /get_graph_data api.
    22	    """
    23	    try:
    24	        response = requests.get(GET_HOSTS)
    25	        if response.status_code == 200:
    26	            response = json.loads(response.text)
    27	            nodes = response["nodes"]
    28	            hosts = {}
    29	            for node in nodes:
    30	                if node["vertex_type"] == 1: # is host
    31	                    for i,host in enumerate(node["ip"]):
    32	                        if isinstance(host, int) and 0 <= host <= 0xFFFFFFFF:
    33	                            ip_str = str(ipaddress.IPv4Address(host.to_bytes(4, 'little', signed=False)))
    34	                        else:
    35	                            ip_str = str(ipaddress.ip_address(host))
    36	
    37	                        device_name = f"h{ (int(node['device_name'][1:])-1)*(len(node['ip'])) + (i+1) }"
    38	                        hosts.update({ip_str: device_name})
    39	                        
    40	            return hosts
    41	        return None
    42	    except Exception:
    43	        return [-1]
    44	
    45	def distance_partition(hosts = None, ndtwin_kernel=None):
    46	    """
    47	    Partition the unique paths array to {near,middle,far} set.
    48	    """
    49	    global GET_PATHS,GET_HOSTS
    50	
    51	    if ndtwin_kernel is not None:
    52	        GET_PATHS = ndtwin_kernel+"/ndt/get_path_switch_count"
    53	        GET_HOSTS = ndtwin_kernel+"/ndt/get_graph_data"
    54	    
    55	    if hosts is None:
    56	        hosts = get_hosts()
    57	    
    58	    if -1 in hosts:
    59	        return False,False,"Failed to get hosts from NDTwin server."
    60	    
    61	    unique_paths = {}
    62	
    63	    # get all paths from api.
    64	    response = requests.get(GET_PATHS)
    65	    if response.status_code == 200:
    66	        response = json.loads(response.text)
    67	        paths = response["data"]
    68	        for path in paths:
    69	            client = {"ip":path["src_ip"],"name":hosts[path["src_ip"]]}
    70	            server = {"ip":path["dst_ip"],"name":hosts[path["dst_ip"]]}
    71	            switch_count = path["switch_count"]
    72	            unique_paths.setdefault(switch_count, []).append((client, server))
    73	    else:
    74	        raise ConnectionError("NDTwin Server not up...")
    75	    
    76	    # partition the paths
    77	    if not unique_paths:
    78	        return False,False,"Failed to get paths from NDTwin server."
    79	    
    80	    unique_paths = {k:unique_paths[k] for k in sorted(unique_paths)}
    81	
    82	
    83	    points = partition_method(unique_paths.keys())
    84	
    85	    partition = {"near":[],"middle":[],"far":[]}
    86	    start = 0
    87	
    88	    for point,par in zip(points, partition): # point's index element is in the same cluster
    89	        segments = [{'src':pair[0],'dst':pair[1]} for _, pairs in list(unique_paths.items())[start:point] for pair in pairs]
    90	        partition[par].extend(segments)
    91	        start = point
    92	    
    93	    return partition,hosts,"success"
    94	
    95	
    96	def CC(x):
    97	    """
    98	    Calculate the cost function for 1-D K-Means clustering.
    99	    """
   100	    m = np.mean(x)
   101	    d = (x - m)**2
   102	    return np.sum(d)
   103	
   104	def partition_method(unique_paths):
   105	    """
   106	    Partition the unique paths array to {near,middle,far} set using 1-D K-Means clustering.
   107	    3 clusters: near, middle, far
   108	    """
   109	    unique_paths = list(unique_paths)
   110	    n =  len(unique_paths)
   111	    
   112	    # implement 1-D K-Means from "https://arxiv.org/abs/1701.07204", DP method with complexity O(kn^2)
   113	
   114	    D = np.zeros((3+1,n+1))
   115	    T = np.zeros((3+1,n+1))
   116	
   117	    for m in range(1,n+1):
   118	        D[1,m] = CC(unique_paths[0:m])
   119	
   120	    for i in range(2,4):
   121	        for m in range(i,n+1):
   122	            D_ms = np.array([D[i-1, j-1] for j in range(2,m+1)])
   123	            CC_ms = np.array([CC(unique_paths[j-1:m]) for j in range(2,m+1)])
   124	            ms = D_ms + CC_ms
   125	            D[i,m] = np.min(ms)
   126	            T[i,m] = np.argmin(ms)+1
   127	
   128	        
   129	    m = n
   130	    T = T.astype(int)
   131	    # Find the borders of clusters
   132	    cluster_boards = deque()
   133	    for i in range(3,0,-1): # 3 -> 1
   134	        m = T[i,m]
   135	        cluster_boards.appendleft(m)
   136	    cluster_boards.append(n)
   137	
   138	    # Create an array of length n where ith element is assigned to cluster
   139	    clusters = []
   140	    l = cluster_boards.popleft()
   141	    while cluster_boards:
   142	        r =  cluster_boards.popleft()
   143	        clusters.append(int(r))
   144	    return clusters
   145	
   146	if __name__ == '__main__':
   147	    print(distance_partition())

```


===== 工具：Network-Traffic-Visualizer（Java，Apache HttpClient） =====
視覺化前端的 kernel API 客戶端。請特別注意它有沒有檢查狀態碼。

檔案：`Network-Traffic-Visualizer/src/main/java/org/example/demo2/NDTApiClient.java`

```java
     1	package org.example.demo2;
     2	
     3	import org.apache.http.HttpEntity;
     4	import org.apache.http.client.config.RequestConfig;
     5	import org.apache.http.client.methods.CloseableHttpResponse;
     6	import org.apache.http.client.methods.HttpGet;
     7	import org.apache.http.impl.client.CloseableHttpClient;
     8	import org.apache.http.impl.client.HttpClients;
     9	import org.apache.http.util.EntityUtils;
    10	
    11	import com.fasterxml.jackson.databind.DeserializationFeature;
    12	import com.fasterxml.jackson.databind.ObjectMapper;
    13	
    14	public class NDTApiClient {
    15	    private final String baseUrl;
    16	    private final ObjectMapper objectMapper;
    17	    private final CloseableHttpClient httpClient;
    18	
    19	    public NDTApiClient(String baseUrl) {
    20	        this.baseUrl = baseUrl;
    21	        this.objectMapper = new ObjectMapper();
    22	
    23	        this.objectMapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
    24	        RequestConfig config = RequestConfig.custom()
    25	            .setConnectTimeout(5000)
    26	            .setSocketTimeout(10000)
    27	            .build();
    28	        this.httpClient = HttpClients.custom().setDefaultRequestConfig(config).build();
    29	    }
    30	
    31	    public GraphData getGraphData() {
    32	        try {
    33	            HttpGet request = new HttpGet(baseUrl + "/ndt/get_graph_data");
    34	            try (CloseableHttpResponse response = httpClient.execute(request)) {
    35	                HttpEntity entity = response.getEntity();
    36	                if (entity != null) {
    37	                    String result = EntityUtils.toString(entity);
    38	                    return objectMapper.readValue(result, GraphData.class);
    39	                }
    40	            }
    41	        } catch (Exception e) {
    42	            e.printStackTrace();
    43	            System.err.println("[API] get_graph_data error: " + e.getMessage());
    44	        }
    45	        return null;
    46	    }
    47	
    48	    public DetectedFlowData[] getDetectedFlowData() {
    49	        try {
    50	            HttpGet request = new HttpGet(baseUrl + "/ndt/get_detected_flow_data");
    51	            try (CloseableHttpResponse response = httpClient.execute(request)) {
    52	                HttpEntity entity = response.getEntity();
    53	                if (entity != null) {
    54	                    String result = EntityUtils.toString(entity);
    55	                    return objectMapper.readValue(result, DetectedFlowData[].class);
    56	                }
    57	            }
    58	        } catch (Exception e) {
    59	            e.printStackTrace(); // Show detailed exception
    60	            System.err.println("[API] get_detected_flow_data error: " + e.getMessage());
    61	        }
    62	        return null;
    63	    }
    64	    
    65	    /**
    66	     * Call the Top-K flow API.
    67	     * Example: GET {baseUrl}/ndt/get_detected_top_k_flow_data?k=50
    68	     */
    69	    public DetectedFlowData[] getDetectedTopKFlowData(int k) {
    70	        try {
    71	            // Ensure K is positive; fall back to 1 if invalid
    72	            int safeK = Math.max(1, k);
    73	            String url = String.format("%s/ndt/get_detected_top_k_flow_data?k=%d", baseUrl, safeK);
    74	            HttpGet request = new HttpGet(url);
    75	            try (CloseableHttpResponse response = httpClient.execute(request)) {
    76	                HttpEntity entity = response.getEntity();
    77	                if (entity != null) {
    78	                    String result = EntityUtils.toString(entity);
    79	                    return objectMapper.readValue(result, DetectedFlowData[].class);
    80	                }
    81	            }
    82	        } catch (Exception e) {
    83	            e.printStackTrace();
    84	            System.err.println("[API] get_detected_top_k_flow_data error: " + e.getMessage());
    85	        }
    86	        return null;
    87	    }
    88	    
    89	
    90	    public java.util.Map<String, Integer> getCpuUtilization() {
    91	        try {
    92	            HttpGet request = new HttpGet(baseUrl + "/ndt/get_cpu_utilization");
    93	            try (CloseableHttpResponse response = httpClient.execute(request)) {
    94	                HttpEntity entity = response.getEntity();
    95	                if (entity != null) {
    96	                    String result = EntityUtils.toString(entity);
    97	                    return objectMapper.readValue(result, new com.fasterxml.jackson.core.type.TypeReference<java.util.Map<String, Integer>>() {});
    98	                }
    99	            }
   100	        } catch (Exception e) {
   101	            e.printStackTrace();
   102	            System.err.println("[API] get_cpu_utilization error: " + e.getMessage());
   103	        }
   104	        return null;
   105	    }
   106	    
   107	
   108	    public java.util.Map<String, Integer> getMemoryUtilization() {
   109	        try {
   110	            HttpGet request = new HttpGet(baseUrl + "/ndt/get_memory_utilization");
   111	            try (CloseableHttpResponse response = httpClient.execute(request)) {
   112	                HttpEntity entity = response.getEntity();
   113	                if (entity != null) {
   114	                    String result = EntityUtils.toString(entity);
   115	                    return objectMapper.readValue(result, new com.fasterxml.jackson.core.type.TypeReference<java.util.Map<String, Integer>>() {});
   116	                }
   117	            }
   118	        } catch (Exception e) {
   119	            e.printStackTrace();
   120	            System.err.println("[API] get_memory_utilization error: " + e.getMessage());
   121	        }
   122	        return null;
   123	    }
   124	    
   125	
   126	    public void close() {
   127	        try {
   128	            if (httpClient != null) {
   129	                httpClient.close();
   130	            }
   131	        } catch (Exception e) {
   132	            System.err.println("Error closing HTTP client: " + e.getMessage());
   133	        }
   134	    }
   135	} 

```


===== 工具：Traffic-Engineering-App（Python，requests） =====
流量工程應用。會取鎖、讀 graph/flow、裝流表。

檔案：`Traffic-Engineering-App/Traffic-engineering-App.py`

```python
     1	# Copyright (c) 2025-present
     2	 
     3	# Licensed under the Apache License, Version 2.0 (the "License");
     4	# you may not use this file except in compliance with the License.
     5	# You may obtain a copy of the License at
     6	 
     7	#   http://www.apache.org/licenses/LICENSE-2.0
     8	
     9	# Unless required by applicable law or agreed to in writing, software
    10	# distributed under the License is distributed on an "AS IS" BASIS,
    11	# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    12	# See the License for the specific language governing permissions and
    13	# limitations under the License.
    14	
    15	# NDTwin core contributors (as of January 15, 2026):
    16	#     Prof. Shie-Yuan Wang <National Yang Ming Chiao Tung University; CITI, Academia Sinica> 
    17	#     Ms. Xiang-Ling Lin <CITI, Academia Sinica>
    18	#     Mr. Po-Yu Juan <CITI, Academia Sinica>
    19	#     Mr. Tsu-Li Mou <CITI, Academia Sinica> 
    20	#     Mr. Zhen-Rong Wu <National Taiwan Normal University>
    21	#     Mr. Ting-En Chang <University of Wisconsin, Milwaukee>
    22	#     Mr. Yu-Cheng Chen <National Yang Ming Chiao Tung University>
    23	    
    24	import requests
    25	import json
    26	from loguru import logger
    27	import networkx as nx
    28	import socket, ipaddress
    29	import time, signal, sys, threading
    30	from datetime import datetime
    31	
    32	ndt_url = "http://localhost:8000/ndt/"
    33	congested_threshold = 70
    34	idle_threshold = 30
    35	elephant_flow_threshold = 10000000  # 10Mbps
    36	migrate_threshold = 1.5
    37	te_flow_entry_priority = 100
    38	default_flow_entry_priority = 10
    39	te_flow_entry_idle_timeout = 0
    40	migrate_only_one_flow_per_round = False
    41	get_graph_data_interval = 1
    42	
    43	
    44	ecmp_group_by_switch = {}
    45	trigger = threading.Event()
    46	
    47	
    48	def get_graph_data_api_call():
    49	    logger.debug("get_graph_data_api_call")
    50	    try:
    51	        graph_data = requests.get(ndt_url + "get_graph_data").json()
    52	        # logger.debug(json.dumps(graph_data, indent=2))
    53	    except Exception as e:
    54	        logger.error(e)
    55	
    56	    return graph_data
    57	
    58	
    59	def get_detected_flow_data_api_call():
    60	    try:
    61	        flow_data = requests.get(ndt_url + "get_detected_flow_data").json()
    62	        # logger.debug(json.dumps(flow_data, indent=2))
    63	    except Exception as e:
    64	        logger.error(e)
    65	
    66	    return flow_data
    67	
    68	def acquire_lock_api_call(ttl=300):
    69	    logger.debug("acquire_lock_api_call")
    70	    try:
    71	        result = requests.post(ndt_url + "acquire_lock", json={"ttl": ttl, "type": "routing_lock"}).json()
    72	        logger.debug(result)
    73	        if result.get("status", None):
    74	            logger.debug("acquire_lock_api_call succeeded")
    75	            return True
    76	    except Exception as e:
    77	        logger.error(e)  
    78	        
    79	    return False
    80	
    81	
    82	def release_lock_api_call():
    83	    logger.debug("release_lock_api_call")
    84	    try:
    85	        result = requests.post(ndt_url + "release_lock", json={"type": "routing_lock"}).json()
    86	        if result.get("status", None):
    87	            logger.debug("release_lock succeeded")
    88	            return True
    89	    except Exception as e:
    90	        logger.error(e)  
    91	        
    92	    return False
    93	
    94	
    95	# ===== Prepare flow dict =====
    96	def construct_flow_dict(flow_data):
    97	    flow_data_dict = {}
    98	    for f in flow_data:
    99	        src_ip = f["src_ip"]
   100	        dst_ip = f["dst_ip"]
   101	        src_port = f["src_port"]
   102	        dst_port = f["dst_port"]
   103	        protocol_id = f["protocol_id"]
   104	
   105	        flow_data_dict[(src_ip, dst_ip, src_port, dst_port, protocol_id)] = f
   106	    return flow_data_dict
   107	
   108	
   109	# ===== Prepare graph =====
   110	def construct_graph(graph_data):
   111	    DG = nx.DiGraph()
   112	
   113	    edge_switches = []
   114	
   115	    for e in graph_data["edges"]:
   116	        src_dpid = e["src_dpid"]
   117	        dst_dpid = e["dst_dpid"]
   118	        if src_dpid == 0:
   119	            edge_switches.append(dst_dpid)
   120	
   121	    for n in graph_data["nodes"]:
   122	        dpid = n.get("dpid")
   123	        if dpid is None or dpid == 0:
   124	            continue
   125	
   126	        # ECMP groups normalization 
   127	        groups = n.get("ecmp_groups", []) or []
   128	        norm_groups = []
   129	        for g in groups:
   130	            members = g.get("members", [])
   131	            port_members = [
   132	                {"type": m.get("type"), "port_id": m.get("port_id")}
   133	                for m in members
   134	                if m.get("type") and m.get("port_id") is not None
   135	            ]
   136	            norm_groups.append({"members": port_members})
   137	
   138	        ecmp_group_by_switch[dpid] = norm_groups
   139	
   140	        is_up = n.get("is_up", True)
   141	        is_enabled = n.get("is_enabled", True)
   142	
   143	        DG.add_node(
   144	            dpid,
   145	            is_up=is_up,
   146	            is_enabled=is_enabled,
   147	            ecmp_groups=norm_groups,
   148	        )
   149	
   150	    # logger.debug(f"ecmp_group_by_switch {ecmp_group_by_switch}")
   151	
   152	    for e in graph_data["edges"]:
   153	        src_dpid = e["src_dpid"]
   154	        dst_dpid = e["dst_dpid"]
   155	        src_interface = e["src_interface"]
   156	        dst_interface = e["dst_interface"]
   157	        link_bandwidth_utilization_percent = e["link_bandwidth_utilization_percent"]
   158	        link_bandwidth_bps = e["link_bandwidth_bps"]
   159	        flow_set = e["flow_set"]
   160	        left_link_bandwidth_bps = e["left_link_bandwidth_bps"]
   161	
   162	        is_congested_link = link_bandwidth_utilization_percent > congested_threshold
   163	        is_connected_to_host = src_dpid == 0
   164	        is_first_layer = src_dpid in edge_switches
   165	
   166	        DG.add_edge(
   167	            src_dpid,
   168	            dst_dpid,
   169	            src_interface=src_interface,
   170	            dst_interface=dst_interface,
   171	            link_bandwidth_utilization_percent=link_bandwidth_utilization_percent,
   172	            left_link_bandwidth_bps=left_link_bandwidth_bps,
   173	            link_bandwidth_bps=link_bandwidth_bps,
   174	            flow_set=flow_set,
   175	            is_congested_link=is_congested_link,
   176	            is_connected_to_host=is_connected_to_host,
   177	            is_first_layer_link=is_first_layer,
   178	            is_congested_link_for_three_times=False,
   179	            link_bandwidth_utilization_percent_for_past_three_times=[],
   180	        )
   181	    return DG
   182	
   183	
   184	def update_congested_link_states(old_graph, new_graph):
   185	    for u, v, data in new_graph.edges(data=True):
   186	        # Update edge data
   187	        old_graph[u][v]["flow_set"] = data["flow_set"]
   188	        old_graph[u][v]["left_link_bandwidth_bps"] = data["left_link_bandwidth_bps"]
   189	        old_graph[u][v]["link_bandwidth_utilization_percent"] = data[
   190	            "link_bandwidth_utilization_percent"
   191	        ]
   192	
   193	        if (
   194	            len(
   195	                old_graph[u][v][
   196	                    "link_bandwidth_utilization_percent_for_past_three_times"
   197	                ]
   198	            )
   199	            >= 3
   200	        ):
   201	            old_graph[u][v][
   202	                "link_bandwidth_utilization_percent_for_past_three_times"
   203	            ] = old_graph[u][v][
   204	                "link_bandwidth_utilization_percent_for_past_three_times"
   205	            ][
   206	                1:
   207	            ]
   208	            old_graph[u][v][
   209	                "link_bandwidth_utilization_percent_for_past_three_times"
   210	            ].append(data["link_bandwidth_utilization_percent"])
   211	        else:
   212	            old_graph[u][v][
   213	                "link_bandwidth_utilization_percent_for_past_three_times"
   214	            ].append(data["link_bandwidth_utilization_percent"])
   215	
   216	        avg_link_bandwidth_utilization_percent = sum(
   217	            old_graph[u][v]["link_bandwidth_utilization_percent_for_past_three_times"]
   218	        ) / len(
   219	            old_graph[u][v]["link_bandwidth_utilization_percent_for_past_three_times"]
   220	        )
   221	        if avg_link_bandwidth_utilization_percent >= congested_threshold:
   222	            old_graph[u][v]["is_congested_link_for_three_times"] = True
   223	
   224	
   225	def fabric_subgraph(G):
   226	    # keep only switch<->switch edges (both endpoints have dpid != 0)
   227	    keep = []
   228	    for u, v, d in G.edges(data=True):
   229	        if d.get("src_dpid", u) != 0 and d.get("dst_dpid", v) != 0:
   230	            keep.append((u, v))
   231	    H = G.edge_subgraph(keep).copy()
   232	    if H.has_node(0):
   233	        H.remove_node(0)
   234	    return H
   235	
   236	
   237	def fabric_nodes_from_flowpath(flow_path):
   238	    """Turn your flow_data_dict path into [src_sw, ..., dst_sw] nodes (no host node 0)."""
   239	    nodes = []
   240	    for hop in flow_path:
   241	        if isinstance(hop, dict):
   242	            n = hop.get("node") or hop.get("dpid")
   243	        else:
   244	            n = hop
   245	        if n is not None and n != 0:
   246	            nodes.append(n)
   247	    return nodes
   248	
   249	
   250	def find_dst_by_src_port(G, src_dpid, src_interface):
   251	    for _, v, data in G.out_edges(src_dpid, data=True):
   252	        if data.get("src_interface") == src_interface:
   253	            return v
   254	
   255	
   256	def detect_imbalance_and_migrate_one_flow(u, v, data, flow_data_dict, DG):
   257	    src_sw = u
   258	    elephant_flows = []
   259	    for f in data["flow_set"]:
   260	        src_ip = f["src_ip"]
   261	        dst_ip = f["dst_ip"]
   262	        src_port = f["src_port"]
   263	        dst_port = f["dst_port"]
   264	        protocol_id = f["protocol_number"]
   265	
   266	        flow_key = (src_ip, dst_ip, src_port, dst_port, protocol_id)
   267	
   268	        try:
   269	            flow_info = flow_data_dict[flow_key]
   270	        except KeyError:
   271	            logger.warning("missing flow_key=%r", flow_key)
   272	            continue
   273	
   274	        sending_rate = flow_info["estimated_flow_sending_rate_bps_in_the_last_sec"]
   275	
   276	        if sending_rate >= elephant_flow_threshold:
   277	            elephant_flows.append({flow_key: sending_rate})
   278	
   279	    if len(elephant_flows) > 0:
   280	        # TODO[debug]: Sometimes the result is not in descending order?
   281	        sorted(elephant_flows, key=lambda ele: elephant_flows, reverse=True)
   282	        logger.debug(elephant_flows)
   283	
   284	        for e in elephant_flows:
   285	            # Check whether alternative path has more bandwidth, if so, migrate
   286	            flow_key = next(iter(e))
   287	            path = flow_data_dict[flow_key]["path"]
   288	            if len(path) < 2:
   289	                continue
   290	            dst_sw = flow_data_dict[flow_key]["path"][-2]["node"]
   291	            sending_rate = flow_data_dict[flow_key][
   292	                "estimated_flow_sending_rate_bps_in_the_last_sec"
   293	            ]
   294	
   295	            # Get all candidate paths between src_sw & dst_sw
   296	            logger.debug(f"src_sw {src_sw} dst_sw {dst_sw}")
   297	            H = fabric_subgraph(DG)
   298	            try:
   299	                # Only get shortest path as candidate paths
   300	                candidate_paths = list(
   301	                    nx.all_shortest_paths(H, source=src_sw, target=dst_sw)
   302	                )
   303	            except nx.NetworkXNoPath:
   304	                candidate_paths = []
   305	
   306	            logger.debug(len(candidate_paths))
   307	            logger.debug(candidate_paths)
   308	
   309	            # Filter out original path
   310	            cur_path_nodes = fabric_nodes_from_flowpath(path)
   311	            candidate_paths = [p for p in candidate_paths if p != cur_path_nodes]
   312	
   313	            candidate_next_hops = {p[1] for p in candidate_paths if len(p) > 1}
   314	            logger.debug(f"candidate_next_hops {candidate_next_hops}")
   315	            candidate_next_hops_set = set(candidate_next_hops)
   316	            logger.debug(f"candidate_next_hops_set {candidate_next_hops_set}")
   317	
   318	            for hop in candidate_next_hops_set:
   319	                if hop == 0:
   320	                    continue
   321	                left_link_bandwidth_bps_in_candidate_next_hop = DG[src_sw][hop][
   322	                    "left_link_bandwidth_bps"
   323	                ]
   324	                # Check whether migrating to the new link can get more BW
   325	                if (
   326	                    left_link_bandwidth_bps_in_candidate_next_hop
   327	                    > sending_rate * migrate_threshold
   328	                ):
   329	                    logger.debug("find a more idle link")
   330	                    # Migrate, install specific flow rule with idle timeout
   331	                    # TODO: Change to match 5-tuple in HPE
   332	                    out_port = DG[src_sw][hop]["src_interface"]
   333	                    ipv4_dst = str(ipaddress.IPv4Address(socket.htonl(flow_key[1])))
   334	                    install_openflow_flow_entry_json = {
   335	                        "dpid": src_sw,
   336	                        "priority": te_flow_entry_priority,
   337	                        "match": {
   338	                            "eth_type": 2048,
   339	                            "ipv4_dst": ipv4_dst,
   340	                        },
   341	                        "actions": [{"port": out_port, "type": "OUTPUT"}],
   342	                        "idle_timeout": te_flow_entry_idle_timeout,
   343	                    }
   344	                    requests.post(
   345	                        ndt_url + "install_flow_entry",
   346	                        json=install_openflow_flow_entry_json,
   347	                    )
   348	                    # Only migrate one flow per iteration
   349	                    return True
   350	
   351	
   352	def detect_imbalance_and_migrate_multiple_flows(
   353	    u,
   354	    v,
   355	    data,
   356	    install_openflow_flow_entry_json_list,
   357	    flow_data_dict,
   358	    DG,
   359	    ecmp_group_by_switch=ecmp_group_by_switch,
   360	):
   361	    logger.debug(f"congested link {u} -> {v}")
   362	    src_sw = u
   363	    elephant_flows = []
   364	    src_interface = data["src_interface"]
   365	
   366	    logger.debug(f"len(flow_set) {len(data["flow_set"])}")
   367	    for f in data["flow_set"]:
   368	        src_ip = f["src_ip"]
   369	        dst_ip = f["dst_ip"]
   370	        src_port = f["src_port"]
   371	        dst_port = f["dst_port"]
   372	        protocol_id = f["protocol_number"]
   373	
   374	        flow_key = (src_ip, dst_ip, src_port, dst_port, protocol_id)
   375	
   376	        try:
   377	            flow_info = flow_data_dict[flow_key]
   378	        except KeyError:
   379	            logger.warning("missing flow_key=%r", flow_key)
   380	            continue
   381	
   382	        sending_rate = flow_info["estimated_flow_sending_rate_bps_in_the_last_sec"]
   383	
   384	        if sending_rate >= elephant_flow_threshold:
   385	            elephant_flows.append({flow_key: sending_rate})
   386	
   387	    logger.debug(f"len(elephant_flows) {len(elephant_flows)}")
   388	    if len(elephant_flows) > 0:
   389	        sorted_elephant_flows = sorted(
   390	            elephant_flows, key=lambda ele: elephant_flows, reverse=True
   391	        )
   392	        logger.debug(sorted_elephant_flows)
   393	
   394	        for flow in sorted_elephant_flows:
   395	            # Check whether alternative ECMP group members has more bandwidth, if so, migrate
   396	            flow_key = next(iter(flow))
   397	            sending_rate = flow_data_dict[flow_key][
   398	                "estimated_flow_sending_rate_bps_in_the_last_sec"
   399	            ]
   400	
   401	            candidate_next_hops_interfaces = []
   402	            candidate_next_hops_dpid_set = []
   403	            # logger.debug(f"ecmp_group_by_switch {ecmp_group_by_switch}")
   404	            groups = ecmp_group_by_switch[src_sw]
   405	            # logger.debug(f"groups {groups}")
   406	            is_groups_loop_end = False
   407	            for members in groups:
   408	                if is_groups_loop_end:
   409	                    break
   410	                logger.debug(f"members {members}")
   411	                member_list = members.get("members")
   412	                for m in member_list:
   413	                    if m.get("port_id") is None:
   414	                        continue
   415	                    if m.get("port_id") == src_interface:
   416	                        candidate_next_hops_interfaces = [
   417	                            ele["port_id"]
   418	                            for ele in member_list
   419	                            if ele.get("port_id") is not None
   420	                            and ele.get("port_id") != src_interface
   421	                        ]
   422	                        is_groups_loop_end = True
   423	                        break
   424	            # logger.debug(f"src_interface {src_interface}")
   425	            logger.debug(
   426	                f"candidate_next_hops_interfaces {candidate_next_hops_interfaces}"
   427	            )
   428	
   429	            for candidate in candidate_next_hops_interfaces:
   430	                # Check is_up & is_enabled
   431	                sw_cadidate = find_dst_by_src_port(DG, src_sw, candidate)
   432	                node_data = DG.nodes[sw_cadidate]
   433	                if node_data.get("is_up", False) and node_data.get("is_enabled", False):
   434	                    candidate_next_hops_dpid_set.append(
   435	                        sw_cadidate
   436	                    )
   437	
   438	            # Sort candidate_next_hops_dpid_set based on left_link_bandwidth_bps in descending order
   439	            sorted_candidates = sorted(
   440	                candidate_next_hops_dpid_set,
   441	                key=lambda hop: DG[src_sw][hop]["left_link_bandwidth_bps"],
   442	                reverse=True,
   443	            )
   444	
   445	            for hop in sorted_candidates:
   446	                if hop == 0 or hop == v:
   447	                    continue
   448	                left_link_bandwidth_bps_in_candidate_next_hop = DG[src_sw][hop][
   449	                    "left_link_bandwidth_bps"
   450	                ]
   451	
   452	                link_bandwidth_utilization_percent_in_candidate_next_hop = DG[src_sw][
   453	                    hop
   454	                ]["link_bandwidth_utilization_percent"]
   455	
   456	                link_bandwidth_bps = DG[src_sw][hop]["link_bandwidth_bps"]
   457	
   458	                logger.debug(
   459	                    f"link_bandwidth_utilization_percent in original congested link {data['link_bandwidth_utilization_percent']}"
   460	                )
   461	                logger.debug(
   462	                    f"link_bandwidth_utilization_percent_in_candidate_next_hop {link_bandwidth_utilization_percent_in_candidate_next_hop}"
   463	                )
   464	                logger.debug(
   465	                    f"left_link_bandwidth_bps_in_candidate_next_hop {left_link_bandwidth_bps_in_candidate_next_hop}"
   466	                )
   467	                logger.debug(f"sending_rate {sending_rate}")
   468	                # Check whether the link to candidate next hop is idle & whether migrating to the new link can get more BW
   469	                if (
   470	                    (100 - link_bandwidth_utilization_percent_in_candidate_next_hop)
   471	                    >= idle_threshold
   472	                    and left_link_bandwidth_bps_in_candidate_next_hop
   473	                    > sending_rate * migrate_threshold
   474	                    and data["link_bandwidth_utilization_percent"]
   475	                    > link_bandwidth_utilization_percent_in_candidate_next_hop
   476	                ):
   477	                    logger.debug("find a more idle link")
   478	                    # Migrate, install specific flow rule with idle timeout
   479	                    # TODO: Change to match 5-tuple in HPE
   480	                    out_port = DG[src_sw][hop]["src_interface"]
   481	                    ipv4_dst = str(ipaddress.IPv4Address(socket.htonl(flow_key[1])))
   482	                    
   483	                    # TODO: Change to mod
   484	                    # install_openflow_flow_entry_json_list.append(
   485	                    #     {
   486	                    #         "dpid": src_sw,
   487	                    #         "priority": te_flow_entry_priority,
   488	                    #         "match": {
   489	                    #             "eth_type": 2048,
   490	                    #             "ipv4_dst": ipv4_dst,
   491	                    #         },
   492	                    #         "actions": [{"port": out_port, "type": "OUTPUT"}],
   493	                    #         "idle_timeout": te_flow_entry_idle_timeout,
   494	                    #     }
   495	                    # )
   496	                    
   497	                    install_openflow_flow_entry_json_list.append(
   498	                        {
   499	                            "dpid": src_sw,
   500	                            "priority": default_flow_entry_priority,
   501	                            "match": {
   502	                                "eth_type": 2048,
   503	                                "ipv4_dst": ipv4_dst,
   504	                            },
   505	                            "actions": [{"port": out_port, "type": "OUTPUT"}],
   506	
   507	                        }
   508	                    )
   509	
   510	                    logger.debug(
   511	                        f"left_link_bandwidth_bps(bf) {DG[src_sw][hop]["left_link_bandwidth_bps"]}"
   512	                    )
   513	                    logger.debug(
   514	                        f"link_bandwidth_utilization_percent(bf) {DG[src_sw][hop]['link_bandwidth_utilization_percent']}"
   515	                    )
   516	                    # Subtract sending rate of migrated elephant flow from left link BW of idle link
   517	                    DG[src_sw][hop]["left_link_bandwidth_bps"] = (
   518	                        left_link_bandwidth_bps_in_candidate_next_hop - sending_rate
   519	                    )
   520	                    DG[src_sw][hop]["link_bandwidth_utilization_percent"] = (
   521	                        link_bandwidth_utilization_percent_in_candidate_next_hop
   522	                        + (sending_rate / link_bandwidth_bps) * 100
   523	                    )
   524	                    data["link_bandwidth_utilization_percent"] = (
   525	                        data["link_bandwidth_utilization_percent"]
   526	                        - (sending_rate / link_bandwidth_bps) * 100
   527	                    )
   528	                    logger.debug(
   529	                        f"left_link_bandwidth_bps(af) {DG[src_sw][hop]["left_link_bandwidth_bps"]}"
   530	                    )
   531	                    logger.debug(
   532	                        f"link_bandwidth_utilization_percent(af) {DG[src_sw][hop]["link_bandwidth_utilization_percent"]}"
   533	                    )
   534	                    break
   535	
   536	
   537	def run_te(DG):
   538	    flow_data = get_detected_flow_data_api_call()
   539	    flow_dict = construct_flow_dict(flow_data)
   540	
   541	    if migrate_only_one_flow_per_round:
   542	        logger.debug("check congested links that are not in first layer")
   543	        for u, v, data in DG.edges(data=True):
   544	            is_congested_link = data["is_congested_link_for_three_times"]
   545	            if is_congested_link:
   546	                r = detect_imbalance_and_migrate_one_flow(u, v, data)
   547	                if r:
   548	                    release_lock_api_call()
   549	                    return
   550	    else:
   551	        install_openflow_flow_entry_json_list = []
   552	
   553	        logger.debug("check congested links that are not in first layer")
   554	        for u, v, data in DG.edges(data=True):
   555	            # logger.debug(f"link_bandwidth_utilization_percent_for_past_three_times {data["link_bandwidth_utilization_percent_for_past_three_times"]}")
   556	            is_congested_link = data["is_congested_link_for_three_times"]
   557	            if is_congested_link:
   558	                detect_imbalance_and_migrate_multiple_flows(
   559	                    u, v, data, install_openflow_flow_entry_json_list, flow_dict, DG
   560	                )
   561	
   562	        logger.info(f"{len(install_openflow_flow_entry_json_list)} entries are added")
   563	        
   564	        # TODO: Change to mod
   565	        if len(install_openflow_flow_entry_json_list) > 0:
   566	            # requests.post(
   567	            #     ndt_url
   568	            #     + "install_flow_entries_modify_flow_entries_and_delete_flow_entries",
   569	            #     json={"install_flow_entries": install_openflow_flow_entry_json_list},
   570	            # )
   571	            
   572	            requests.post(
   573	                ndt_url
   574	                + "install_flow_entries_modify_flow_entries_and_delete_flow_entries",
   575	                json={"modify_flow_entries": install_openflow_flow_entry_json_list},
   576	            )
   577	
   578	            for entry in install_openflow_flow_entry_json_list:
   579	                logger.debug(f"{entry}")
   580	                
   581	    release_lock_api_call()
   582	
   583	    return
   584	
   585	
   586	def enter_listener():
   587	    try:
   588	        while True:
   589	            input("Press Enter to run (Ctrl+C to quit)…")
   590	            trigger.set()
   591	    except (EOFError, KeyboardInterrupt):
   592	        pass
   593	
   594	
   595	def ask_mode():
   596	    print("Select TE mode:")
   597	    print("  1) Execute run_te() when you press Enter")
   598	    print("  2) Execute run_te() periodically (e.g., every 5 seconds)")
   599	    choice = input("Enter 1 or 2 [default 1]: ").strip() or "1"
   600	    if choice not in {"1", "2"}:
   601	        choice = "1"
   602	
   603	    te_interval = 5.0
   604	    if choice == "2":
   605	        s = input("How many seconds between TE runs? [default 5]: ").strip()
   606	        if s:
   607	            try:
   608	                te_interval = float(s)
   609	            except ValueError:
   610	                print("Invalid number, using 5 seconds.")
   611	                te_interval = 5.0
   612	    return choice, te_interval
   613	
   614	
   615	
   616	def main():
   617	    mode, te_interval = ask_mode()
   618	
   619	    filename = datetime.now().strftime("%Y-%m-%d-%H-%M-%S") + ".json"
   620	    record_count = 0
   621	
   622	    # kick off Enter listener only in mode 1
   623	    if mode == "1":
   624	        t = threading.Thread(target=enter_listener, daemon=True)
   625	        t.start()
   626	
   627	    # initial graph
   628	    init = get_graph_data_api_call()
   629	
   630	    
   631	    if not init:
   632	        logger.warning("Initial get_graph_data_api_call() returned no data.")
   633	    old_graph = construct_graph(init)
   634	
   635	    # schedulers
   636	    graph_interval = float(get_graph_data_interval)
   637	    next_graph = time.monotonic()  # next time to refresh graph
   638	    next_te = time.monotonic() + te_interval if mode == "2" else None
   639	
   640	    while True:
   641	        now = time.monotonic()
   642	        # compute timeouts for the next event
   643	        t_graph = max(0.0, next_graph - now)
   644	        t_te = max(0.0, next_te - now) if next_te is not None else None
   645	
   646	        # smallest timeout among pending events
   647	        if t_te is None:
   648	            timeout = t_graph
   649	        else:
   650	            timeout = min(t_graph, t_te)
   651	
   652	        if mode == "1":
   653	            # wait can be interrupted early by Enter
   654	            fired = trigger.wait(timeout)
   655	            if fired:
   656	                trigger.clear()
   657	                # immediate TE run
   658	                try:
   659	                    if acquire_lock_api_call():
   660	                        run_te(old_graph)
   661	                except Exception:
   662	                    logger.exception("run_te failed (mode 1)")
   663	                # do not change next_graph; keep cadence
   664	                continue
   665	        else:
   666	            # mode 2: no Enter listener; just sleep until the next event
   667	            time.sleep(timeout)
   668	
   669	        # handle due events
   670	        now = time.monotonic()
   671	
   672	        # periodic graph refresh
   673	        if now >= next_graph:
   674	            try:
   675	                data = get_graph_data_api_call()
   676	
   677	                
   678	                if data:  # keep old_graph if fetch failed
   679	                    new_graph = construct_graph(data)
   680	                    update_congested_link_states(old_graph, new_graph)
   681	            except Exception:
   682	                logger.exception("graph refresh failed")
   683	            # fixed-rate schedule (no drift)
   684	            while next_graph <= now:
   685	                next_graph += graph_interval
   686	
   687	        # periodic TE (mode 2)
   688	        if next_te is not None and now >= next_te:
   689	            try:
   690	                if acquire_lock_api_call():
   691	                    run_te(old_graph)
   692	            except Exception:
   693	                logger.exception("run_te failed (mode 2)")
   694	            # fixed-rate schedule
   695	            while next_te <= now:
   696	                next_te += te_interval
   697	
   698	
   699	if __name__ == "__main__":
   700	    try:
   701	        main()
   702	    except KeyboardInterrupt:
   703	        print("\nExit!")
   704	        sys.exit(0)

```


===== 補充：Energy-Saving-App 與 Simulation-Platform-Manager 的端點常數 =====

```cpp
     1	#pragma once
     2	
     3	#include <filesystem>
     4	#include <string>
     5	
     6	#define HIGH_WATER_MARK 0.6
     7	#define LOW_WATER_MARK 0.40
     8	#define CHECKING_INTERVAL_IN_SECOND 60
     9	
    10	namespace fs = std::filesystem;
    11	
    12	inline const std::string app_ip = "localhost";
    13	inline const uint32_t app_port = 8001;
    14	inline const std::string app_target = "/result";
    15	
    16	inline const std::string ndt_ip = "localhost";
    17	inline const std::string ndt_port = "8000";
    18	inline const std::string ndt_target = "/ndt/app_register";
    19	
    20	inline const std::string request_manager_ip = "localhost";
    21	inline const std::string request_manager_port = "8000";
    22	inline const std::string request_manager_target_for_app = "/ndt/received_a_simulation_case";
    23	
    24	inline const std::string nfs_server_ip = "localhost";
    25	inline const fs::path nfs_mnt_dir = "/mnt/nfs/app";
    26	
    27	inline const fs::path input_filename = "input";
    28	
    29	
    30	inline std::string mount_nfs_command(const std::string& app_id)
    31	{
    32	    return "mount -t nfs " + nfs_server_ip + ":" + "/srv/nfs/sim/" + app_id + " " + nfs_mnt_dir.string();
    33	}
    34	
    35	inline std::string unmount_nfs_command()
    36	{
    37	    return "umount " + nfs_mnt_dir.string();
    38	}
    39	
    40	inline fs::path abs_input_file_path(
    41	    const std::string &simulator,
    42	    const std::string &version,
    43	    const std::string &case_id,
    44	    const std::string &input_file_path)
    45	{
    46	    return nfs_mnt_dir / simulator / version / case_id / input_file_path;
    47	}
    48	
    49	inline fs::path abs_output_file_path(
    50	    const std::string &simulator,
    51	    const std::string &version,
    52	    const std::string &case_id,
    53	    const std::string &output_file_path)
    54	{
    55	    return nfs_mnt_dir / simulator / version / case_id / output_file_path;
    56	}

--- Simulation-Platform-Manager/include/settings/app.hpp ---
     1	#pragma once
     2	
     3	#include <filesystem>
     4	#include <string>
     5	
     6	namespace fs = std::filesystem;
     7	
     8	std::string app_id = "power";
     9	
    10	// inline const std::string app_ip = "127.0.0.1";
    11	inline const std::string app_ip = "10.10.10.251";
    12	inline const uint32_t app_port = 8001;
    13	inline const std::string app_target = "/result";
    14	
    15	// inline const std::string ndt_ip = "127.0.0.1";
    16	inline const std::string ndt_ip = "10.10.10.250";
    17	inline const std::string ndt_port = "8000";
    18	inline const std::string ndt_target = "/ndt/app_register";
    19	
    20	// inline const std::string request_manager_ip = "127.0.0.1";
    21	inline const std::string request_manager_ip = "10.10.10.250";
    22	inline const std::string request_manager_port = "8000";
    23	inline const std::string request_manager_target_for_app = "/ndt/received_a_simulation_case";
    24	
    25	// inline const std::string nfs_server_ip = "127.0.0.1";
    26	inline const std::string nfs_server_ip = "10.10.10.250";
    27	inline const fs::path nfs_mnt_dir = "/mnt/nfs/app";
    28	
    29	inline const fs::path input_filename = "input";
    30	
    31	inline std::string mount_nfs_command(const std::string& app_id)
    32	{
    33	    return "mount -t nfs " + nfs_server_ip + ":" + "/srv/nfs/sim/" + app_id + " " + nfs_mnt_dir.string();
    34	}
    35	
    36	inline std::string unmount_nfs_command()
    37	{
    38	    return "umount " + nfs_mnt_dir.string();
    39	}
    40	
    41	inline fs::path abs_input_file_path(
    42	    const std::string &simulator,
    43	    const std::string &version,
    44	    const std::string &case_id,
    45	    const std::string &input_file_path)
    46	{
    47	    return nfs_mnt_dir / simulator / version / case_id / input_file_path;
    48	}
    49	
    50	inline fs::path abs_output_file_path(
    51	    const std::string &simulator,
    52	    const std::string &version,
    53	    const std::string &case_id,
    54	    const std::string &output_file_path)
    55	{
    56	    return nfs_mnt_dir / simulator / version / case_id / output_file_path;
    57	}

--- Simulation-Platform-Manager/include/settings/sim_server.hpp ---
     1	#pragma once
     2	
     3	#include <filesystem>
     4	#include <string>
     5	
     6	namespace fs = std::filesystem;
     7	
     8	inline const std::string request_manager_ip = "localhost";
     9	inline const std::string request_manager_port = "8000";
    10	inline const std::string request_manager_target = "/ndt/simulation_completed";
    11	
    12	// inline const std::string sim_server_ip = "127.0.0.1";
    13	inline const uint32_t sim_server_port = 9000;
    14	inline const std::string sim_server_target = "/submit";
    15	
    16	inline const std::string nfs_server_ip = "localhost";
    17	inline const std::string nfs_server_dir = "/srv/nfs/sim";
    18	inline const fs::path nfs_mnt_dir = "/mnt/nfs/sim";
    19	
    20	inline const fs::path registered_dir = "registered/";
    21	inline const fs::path simulator_executable = "executable";
    22	
    23	// In the future, the decision may be based on the settings in all_simulators.json, and the parameter of simulator_exec_command will no longer be outputpath, but outputdir.
    24	inline const fs::path output_filename = "output";
    25	
    26	inline std::string mount_nfs_command()
    27	{
    28	    return "mount -t nfs " + nfs_server_ip + ":" + nfs_server_dir + " " + nfs_mnt_dir.string();
    29	}
    30	
    31	inline std::string unmount_nfs_command()
    32	{
    33	    return "umount " + nfs_mnt_dir.string();
    34	}
    35	
    36	inline fs::path abs_input_file_path(
    37	    const std::string &simulator,
    38	    const std::string &version,
    39	    const std::string &app_id,
    40	    const std::string &case_id,
    41	    const std::string &input_file_path)
    42	{
    43	    return nfs_mnt_dir / app_id / simulator / version / case_id / input_file_path;
    44	}
    45	
    46	inline fs::path abs_output_file_path(
    47	    const std::string &simulator,
    48	    const std::string &version,
    49	    const std::string &app_id,
    50	    const std::string &case_id)
    51	{
    52	    return nfs_mnt_dir / app_id / simulator / version / case_id / output_filename;
    53	}
    54	
    55	inline bool check_simulator_exist(const std::string &simulator, const std::string &version)
    56	{
    57	    return fs::exists(registered_dir / simulator / version / simulator_executable);
    58	}
    59	
    60	inline std::string simulator_exec_command(
    61	    const std::string &simulator,
    62	    const std::string &version,
    63	    const std::string &abs_input_file_path,
    64	    const std::string &abs_output_file_path)
    65	{
    66	    fs::path simulator_exec = registered_dir / simulator / version / simulator_executable;
    67	    return simulator_exec.string() + " " + abs_input_file_path + " " + abs_output_file_path;
    68	}
```


===== 補充：Web-GUI 中消費 api/index.ts 的元件，以及它們的 catch 位置 =====

消費者：FlowDataManager.tsx, SwitchPortPanel.tsx, DeviceInformation.tsx, GraphDataManager.tsx, Topology.tsx, LinkFlowInformation.tsx, FlowInformation.tsx, pages/SwitchFlowTable.tsx

```tsx
src/components/GraphDataManager.tsx-24-            ? updatedData.slice(-MAX_DATA_POINTS)
src/components/GraphDataManager.tsx-25-            : updatedData;
src/components/GraphDataManager.tsx-26-        });
src/components/GraphDataManager.tsx:27:      } catch (error) {
src/components/GraphDataManager.tsx-28-        console.error('Error fetching graph data:', error);
src/components/GraphDataManager.tsx-29-      }
src/components/GraphDataManager.tsx-30-    };
src/components/GraphDataManager.tsx-31-    const intervalId = setInterval(fetchData, 1000);
src/components/GraphDataManager.tsx-32-
src/components/GraphDataManager.tsx-33-    return () => clearInterval(intervalId);
src/components/GraphDataManager.tsx-34-  }, []);
src/components/GraphDataManager.tsx-35-
src/components/FlowDataManager.tsx-28-            ? updated.slice(-MAX_DATA_POINTS)
src/components/FlowDataManager.tsx-29-            : updated;
src/components/FlowDataManager.tsx-30-        });
src/components/FlowDataManager.tsx:31:      } catch (error) {
src/components/FlowDataManager.tsx-32-        console.error('Error fetching flow table data:', error);
src/components/FlowDataManager.tsx-33-      }
src/components/FlowDataManager.tsx-34-    };
src/components/FlowDataManager.tsx-35-    fetchData();
src/components/FlowDataManager.tsx-36-    const intervalId = setInterval(fetchData, 1000);
src/components/FlowDataManager.tsx-37-    return () => clearInterval(intervalId);
src/components/FlowDataManager.tsx-38-  }, []);
src/components/FlowDataManager.tsx-39-
src/components/DeviceInformation.tsx-164-        setNewDeviceName('');
src/components/DeviceInformation.tsx-165-        cpuPolling.manualRefresh();
src/components/DeviceInformation.tsx-166-        memoryPolling.manualRefresh();
src/components/DeviceInformation.tsx:167:      } catch (error) {
src/components/DeviceInformation.tsx-168-        alert('Failed to save device name');
src/components/DeviceInformation.tsx-169-      } finally {
src/components/DeviceInformation.tsx-170-        setSaving(false);
src/components/DeviceInformation.tsx-171-      }
src/components/DeviceInformation.tsx-172-    } else if (e.key === 'Escape') {
src/components/DeviceInformation.tsx-173-      setEditingDeviceName(false);
src/components/DeviceInformation.tsx-174-      setNewDeviceName('');
src/components/DeviceInformation.tsx-175-      setDeviceNameError('');
--
src/components/DeviceInformation.tsx-204-
src/components/DeviceInformation.tsx-205-        setEditingNickName(false);
src/components/DeviceInformation.tsx-206-        setNewNickName('');
src/components/DeviceInformation.tsx:207:      } catch (error) {
src/components/DeviceInformation.tsx-208-        alert('Failed to save nickname');
src/components/DeviceInformation.tsx-209-      } finally {
src/components/DeviceInformation.tsx-210-        setSaving(false);
src/components/DeviceInformation.tsx-211-      }
src/components/DeviceInformation.tsx-212-    } else if (e.key === 'Escape') {
src/components/DeviceInformation.tsx-213-      setEditingNickName(false);
src/components/DeviceInformation.tsx-214-      setNewNickName('');
src/components/DeviceInformation.tsx-215-      setNickNameError('');
src/pages/SwitchFlowTable.tsx-993-      }
src/pages/SwitchFlowTable.tsx-994-      setShowForm(false);
src/pages/SwitchFlowTable.tsx-995-      setOriginalFlowEntry(null); // Clear original flow entry after successful operation
src/pages/SwitchFlowTable.tsx:996:    } catch (error: any) {
src/pages/SwitchFlowTable.tsx-997-      alert(`Error ${operationType === 'install' ? 'adding' : 'modifying'} flow: ${error.message}`);
src/pages/SwitchFlowTable.tsx-998-    } finally {
src/pages/SwitchFlowTable.tsx-999-      setLoading(false);
src/pages/SwitchFlowTable.tsx-1000-    }
src/pages/SwitchFlowTable.tsx-1001-  }, [formData, operationType, originalFlowEntry]);
src/pages/SwitchFlowTable.tsx-1002-
src/pages/SwitchFlowTable.tsx-1003-  const handleAddFlow = useCallback(() => {
src/pages/SwitchFlowTable.tsx-1004-    setShowForm(true);
--
src/pages/SwitchFlowTable.tsx-1142-
src/pages/SwitchFlowTable.tsx-1143-      setDeleteDialog({ open: false, flow: null });
src/pages/SwitchFlowTable.tsx-1144-      alert('Flow deleted successfully!');
src/pages/SwitchFlowTable.tsx:1145:    } catch (error: any) {
src/pages/SwitchFlowTable.tsx-1146-      setError(error?.message || 'Error deleting flow');
src/pages/SwitchFlowTable.tsx-1147-    } finally {
src/pages/SwitchFlowTable.tsx-1148-      setLoading(false);
src/pages/SwitchFlowTable.tsx-1149-      setDeleteLoading(false);
src/pages/SwitchFlowTable.tsx-1150-    }
src/pages/SwitchFlowTable.tsx-1151-  }, [deleteDialog.flow]);
src/pages/SwitchFlowTable.tsx-1152-
src/pages/SwitchFlowTable.tsx-1153-  // Match Field Helpers

```

**請注意**：Web-GUI 的 `handleResponse` 在 `!response.ok` 時 `throw new Error(errorData?.error || ...)`，而 kernel 新的錯誤 body 恰好有一個 `error` 欄位。請判斷這是不是巧合相容，以及各元件的 catch 之後 UI 會呈現什麼。


---

以上為全部材料。請依前述六節格式輸出，用繁體中文，並嚴守證據紀律：能指出行號的才叫發現，指不出來的請放進第 6 節。
