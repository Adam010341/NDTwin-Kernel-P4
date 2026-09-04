# W5／OV-1：`modify_nickname`／`modify_device_name` 重寫追蹤中的模型檔

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W5。
修的人：夜巡「修法 agent」session，worktree `wt-integrate`。日期：2026-09-04。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論，以及**這不是今晚新發現的**

持久化是「把整份 JSON 讀進 `nlohmann::json`、改一格、整份寫回」，而
`nlohmann::json` 的預設 `ObjectType` 是 `std::map`
⇒ **每個 object 的 key 都按字典序吐出來**，於是整份檔案重排。
今晚實測：一次 `POST /ndt/modify_nickname` 造出 **3998 insertions／3998 deletions**，
JSON 語意完全相同；同一晚換平面又發生在另一份檔案（664/664）
⇒ **與平面無關，是 `activeTopologyPath()` 指到哪份就重寫哪份。**

🔴 **這不是新缺陷**：`tools/contract_test/spec.py:1341-1349` 的 `modify_device_name` 註記
從 **2026-08-17** 起就逐字寫著同一個現象與「git checkout it after a mutation run」。
**今晚新的是後果**：`ndt status --check` 的第四列比對拓樸檔 sha256
（`tools/test_workflow/ndt:2239-2255`，判紅那行是 `:2249`），
所以 kernel 自己的重寫被報成「topology file has been edited since the ndt up that loaded it」。

## 2. 修法：ordered_json **不夠**——這是我這一輪量出來的

工單建議選項 (b)「`nlohmann::json` → `nlohmann::ordered_json`」。
🟢 **我實測過，(b) 單獨做不成立。**

我寫了一支拋棄式探針（讀→寫→逐位元比對，用 repo 自己的 `libs/nlohmann`），
對 `setting/StaticNetworkTopology*.json` 十三份跑：

| 寫法 | 逐位元相同 |
|---|---|
| 只換 `ordered_json`，維持 `setw(2) << … << std::endl` | **5 / 13** |
| ordered_json ＋**讀出縮排**＋**保留結尾換行** | **9 / 13** |

**為什麼 (b) 單獨不夠**：出貨檔**不是每一份都用 2 空格縮排**（四份用 4 空格），
也不是每一份都以換行結尾。固定 `setw(2)` 會把 4 空格檔**逐行重排版**——
把「重新排序的 diff」換成「重新縮排的 diff」，**sha256 一樣會變、`--check` 一樣判紅**。

所以本輪的修法是 (b+)：
1. `nlohmann::ordered_json`（保留讀進來的順序）；
2. **從文件本身讀出一層縮排幾個空格**（`detectJsonIndent`：第一行有前導空白的行，數它的前導空白）；
3. **保留原檔有沒有結尾換行**；
4. 讀寫抽成 `readTopologyFileWithLayout`／`writeTopologyFileWithLayout` 兩支 file-local 函式，
   兩個孿生呼叫端共用（tmp＋`rename` 的原子寫沒有動）。

### 那 4 份還是不 byte-identical 的是哪些、為什麼

`StaticNetworkTopology_ipAlias4_*` 四份 legacy testbed 檔：
- 它們的陣列裡有**手留的空行**——**任何 JSON 序列化器都不會保留**；
- 其中兩份還有 **3 個大括號縮 7 格**，而檔案其餘部分縮 8 格（手改留下的錯位），序列化會把它對齊。

⇒ **兩個平面實際在用的檔案全部 byte-identical**：OV-1 兩個事發檔（Mininet 與 P4_4Hosts）、
五份 OVS、兩份 P4。**這一段寫在測試的註解裡也寫在這裡，不藏。**

## 3. 為什麼沒有選 (a)（不寫檔）

Adam 的紅線是「程式在改 repo 追蹤的檔」，(a)（拿掉持久化）確實徹底解決，
但它是**對外行為變更**（nickname 不再跨重啟保留），
而我的指令是「選最小修法；要動『模型檔可不可寫』的設計就只寫選項」。
⇒ **(a) 與 (c) 留成給 Adam 的問題**（§8），本輪做 (b+)。

## 4. 座標（🟢 開檔核對）

| 位置 | 內容 |
|---|---|
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:2959` | `setVertexDeviceName`（唯一呼叫端 `HttpSession.cpp:1541`） |
| 同上 `:3039` 一帶 | `setVertexNickname`（唯一呼叫端 `HttpSession.cpp:1992`） |
| 同上（新增） | `TopologyFileLayout`／`detectJsonIndent`／`readTopologyFileWithLayout`／`writeTopologyFileWithLayout` |
| 同上 `:832-852` | `activeTopologyPath()`：`NDTWIN_TOPO_FILE` 優先，否則依模式 |
| `tools/test_workflow/ndt:2239-2255`／`:2249` | `check_up_target` 的 sha256 那一列與判紅訊息 |

`grep` 全 `src/`＋`include/`：`setVertexNickname` ← 只有 `HttpSession.cpp:1992`；
`setVertexDeviceName` ← 只有 `HttpSession.cpp:1541`。**只有這兩個端點有這個副作用。**

## 5. 測試

新增 `tests/test_NicknameDoesNotRewriteTheFile.cpp`（**開新檔有理由**：
沒有任何既有 gtest 覆蓋這兩支，也沒有現成 fixture 可擴充），
並加進 `tests/CMakeLists.txt` 的來源清單（照既有格式寫了一段說明它守哪條 finding）。

🔴 **每一支都用 `NDTWIN_TOPO_FILE` 指到一份 pid-tagged 的暫存副本**
（手法抄 `test_PollDoesNotResurrect.cpp`／`test_DataPlaneKindOrdering.cpp`）：
一個「它會寫到追蹤中的檔」的缺陷，它的測試不可以寫到那個檔。
跑完 `git status --porcelain setting/` 是空的。

| 測試 | 斷言 |
|---|---|
| `AModifyNicknameChangesExactlyOneLineOfTheTopologyFile` | P4 檔：行數不變、**只有 1 行不同**、結尾換行狀態不變 |
| `AModifyDeviceNameChangesExactlyOneLineOfTheTopologyFile` | 孿生（各自一支，不是同一支的第二個斷言） |
| `TheMininetTopologyKeepsItsBytesToo` | Mininet 檔（**就是沒有結尾換行的那一份**） |
| `ANicknameChangeStillReachesTheGraph` | 🔴 對照：記憶體那一半還在 |
| `TheNicknameIsStillWrittenToTheTopologyFile` | 🔴 對照：檔案那一半還在（少了它，「整支刪掉」會全綠） |
| `EveryShippedTopologyKeepsItsContentThroughARename` | 每一份出貨檔：**去掉縮排後的內容只有 1 行不同**；外加「至少 9 份逐位元存活」的總量斷言 |

最後那支的兩段斷言是刻意分開的：**內容**（每一份都必須成立）與**版面**（總量 9/13，
把 §2 的量測釘住，掉回 5/13 就紅）。

## 6. 看紅

把排序放回去（＝閘門 M1，讀進 `std::map` 版本再轉成 `ordered_json`，字典序照樣活下來）之後，
在同一顆 binary 上逐字：

```
[ RUN      ] NicknamePersistenceTest.AModifyNicknameChangesExactlyOneLineOfTheTopologyFile
tests/test_NicknameDoesNotRewriteTheFile.cpp:273: Failure
Expected equality of these values:
  differingLines(before, after)
    Which is: 841
  1u
    Which is: 1
one nickname was changed and 841 lines moved; that is the 3998-line rewrite this test exists for
[  FAILED  ] NicknamePersistenceTest.AModifyNicknameChangesExactlyOneLineOfTheTopologyFile (14 ms)
```

🔴 **`841 lines moved`**——測試用的是 P4_4Hosts（1049 行）而不是 auditor 那次的 Mininet 檔（3998 行），
所以數字比實測小；**形狀一模一樣**：改一個 nickname，八百多行搬家。
之後把原始碼還原、`cmp` 逐位元相同、重建通過。

閘門 log：`scratch/overnight-2026-09-04/fix/W5-gate.log`。
六個變異各指名一支必死測試，兩個對照必須留綠。
🔴 其中三個是**過度修**：M2／M3 把持久化整個拿掉（**檔案沒被寫＝所有逐位元斷言都會過**）、
M4 把記憶體那一半拿掉（**任何看檔案的斷言都看不到**）、
M6 一律補結尾換行（**逐行比對看不到，sha256 看得到**）。
M5 是「只換 ordered_json、縮排用猜的」那個半套修法——它會讓 9/13 掉回 5/13。

## 7. 沒做的事

- **沒有跑 live**：這一輪沒有起 kernel、沒有打 `POST /ndt/modify_nickname`、沒有碰 lab。
  AFTER 的證據是 gtest 與閘門。BEFORE 是今晚 auditor 的實測（🟠，我沒複驗）
  加上 fixplan 作者 🟢 的 `git diff --stat` 觀測。
- **`ndt status --check` 那一列沒有實測轉綠**。推論是「檔案 byte 不變 ⇒ sha 不變 ⇒ 那一列綠」，
  但**我沒有跑過 `ndt status --check`**（不碰 lab）。⚠️ 這是本張單最需要 live 補一刀的地方。
- **`spec.py:1341-1349` 的註記還沒更新**（它現在過時了）。沒動的理由：那個檔今晚已經被 W6 改過，
  而這句話要怎麼寫牽涉「(a)/(b)/(c) 最後選哪個」——等 Adam 裁完一次改乾淨，比改兩次好。
- **四份 `_ipAlias4_*` legacy 檔仍然會被正規化一次**（空行與 3 個錯位大括號），見 §2。

## 8. 給 Adam 的問題（工單附錄第 2 題，本輪只做最小修法）

nickname／device_name 該不該持久化到**版控追蹤的** `setting/*.json`？

| 選項 | 代價 |
|---|---|
| **(b+) 本輪做的**：保序＋保版面地原地改一格 | 出貨檔照樣被寫，只是 diff 從 3998 行變成 1 行；四份 legacy 檔仍會被正規化一次 |
| (a) 不寫檔 | 徹底解決「程式在改追蹤中的檔」；**nickname 不再跨重啟保留**＝對外行為變更 |
| (c) 寫到 `setting/` 以外的 overlay 檔，載入時套上 | 兩者兼得，但是一張更大的單（要定義 overlay 的位置、載入順序、衝突規則） |

**我的建議**：(b+) 已經把後果（`--check` 判紅、4000 行髒 diff）拿掉了；
(c) 才是最終形狀，但值不值得一張大單由 Adam 決定。
