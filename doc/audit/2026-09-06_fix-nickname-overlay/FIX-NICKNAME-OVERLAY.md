# W10：nickname overlay —— kernel 從此不寫模型檔

工單：`scratch/overnight-2026-09-05/fix/TICKETS-0906/W10-nickname-overlay.md`。
裁決：`scratch/overnight-2026-09-05/DECISIONS.md` §67（18:1x）。
分支：`fix/w10-nickname-overlay`（base＝trunk `1536ff17`）。日期：2026-09-06。

[Co-developed with claude code -- Adam]

---

## 1. 一句話

`modify_nickname`／`modify_device_name` 不再寫 `setting/<model>.json`，
名字改寫進 `.test_run/nickname_overlay/<model>.names.json`，
kernel 載入拓樸的**最後一步**把它疊回圖上；`ndt status --check` **指名它、但不比它**。
⇒ **模型檔從此對 kernel 唯讀**，`--check` 的 sha256 只在 `ndt up` 時變。

## 2. 為什麼「W5 那樣修」不夠 —— 這不是 W5 修壞了

W5（OV-1，09-04）把一次改名的 diff 從 **3998 行降到 1 行**，做法是保順序、保縮排、保結尾換行。
**那一步是對的，也不夠。** `ndt status --check` 第 5 列比的是模型檔的 **sha256**
（`tools/test_workflow/ndt`，`check_up_target` 的 topology file 那一列），
而 sha256 不數行。09-05 夜巡在 live OVS 上實測：一次 `POST /ndt/modify_nickname`
→ `git diff` 只有 2 行 → `ndt status --check` **rc=1**，紅字是
「the topology file has been edited since the ndt up that loaded it」。

同一輪有**兩個對照組**，它們是「這是 `--check` 在正常工作、不是 W5 壞掉」的證據：

| 對照 | 觀測 | 說明 |
|---|---|---|
| 改過去又改回來 | 檔案 byte-identical、`--check` rc=0 | 紅的原因**就是 byte 差異本身** |
| 與 nickname 無關的寫者（R3 改頻寬） | **一字不差的同一句話** | 那句話不是 W5 的缺陷訊號 |

⇒ **只要 kernel 還寫那個檔，「只改一行」與「`--check` 綠」就不可能同時成立。**
這是設計層級的互斥，不是實作品質問題。W5 的 FIX 文件 §8 已經把 (a)/(b+)/(c) 三條路列給 Adam；
09-05 18:1x 裁的是 **(c)**，也就是本單。

## 3. 修法（🟢 開檔核對；座標以本分支 HEAD 為準）

| 位置 | 內容 |
|---|---|
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp:321-352` | 新增 `nicknameOverlayPath()`／`applyNicknameOverlayNoLock()` 兩個宣告與理由 |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`（`getGraph()` 之後那一段） | **刪掉** `TopologyFileLayout`／`detectJsonIndent`／`readTopologyFileWithLayout`／`writeTopologyFileWithLayout`（W5 為了寫模型檔而存在，模型檔不寫了就沒有使用者，留著會被 `-Werror -Wunused-function` 擋下）；**新增** `readJsonFile`／`writeJsonFileAtomically`／`overlaySection`／`readNameOverlayForWriting`／`setOverlayName` |
| 同上 `setVertexDeviceName`／`setVertexNickname` | 改寫 overlay，不碰模型檔 |
| 同上 `parseStaticTopologyFile` 末行 | `applyNicknameOverlayNoLock();` |
| `tools/test_workflow/ndt`（`check_up_target`） | 新增 `_ut_overlay_row`（第 6 列）＋ `local overlay=...`；**不進 `bad`** |

### 3-1. overlay 的位置：`.test_run/nickname_overlay/<model stem>.names.json`

工單給了兩個建議，選 `.test_run/` 底下，理由三條（前兩條是要求，第三條是工單交代要確認的）：

1. **`.gitignore:21` 已經忽略 `.test_run/`** ⇒ 改名再也不可能弄髒版控追蹤的檔。
   這是 W10 存在的理由本身，用「幾何」達成而不是靠人記得。
2. **per-checkout**，和 `up.target`／`lab.claim`／pid ledger 同一層 ——
   而名字只在「這個 checkout 跑起來的那座 fabric」上有意義，範圍剛好一致。
3. 🟢 **`ndt clean` 不會把它當殘骸**：`cmd_clean` 斷言的是 bmv2 行程數、mn 行程數、
   topo tmux session、`$MANIFEST`、port table 五樣，**完全沒有列舉 `.test_run/` 的內容**
   （2026-09-06 開檔讀 `tools/test_workflow/ndt` 的 `cmd_clean`）。
   全 repo `grep` 也沒有任何 `rm -rf .test_run`。

`NDTWIN_NICKNAME_OVERLAY` 可整條覆寫（測試用，以及在沒有 `.test_run/` 的目錄裡跑 kernel 的人）；
空字串當作沒設，理由與 `NDTWIN_TOPO_FILE` 同一條（`getenv` 對 `VAR=` 回傳合法的 `""`，
而 append `.tmp` 之後會 rename 到不存在的地方）。

### 3-2. 🔴 為什麼**不是**工單寫的 `{"<dpid>": "<nickname>"}`

**每一份出貨拓樸裡的每一個 host 都是 `"dpid": 0`**（09-06 開檔查證，`OVS_10Switches_4Hosts`
四台 host 的 dpid 是 `[0, 0, 0, 0]`），而 host **打得到**：`modify_nickname` 的
`identifier.type` 支援 `dpid`／`mac`／`name` 三種，後兩種都會落到 host。
⇒ 扁平的 dpid map 會把四台 host 疊在 `"0"` 這一個 key 上，**改一台 host 的名字，
下次啟動時四台一起改**。所以 key 用兩個 setter 本來就在比的那個欄位：
**switch 用 dpid、host 用 mac**，分兩個 section。

```json
{
  "version": 1,
  "topology": "setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json",
  "switches": { "1": { "nickname": "core-a", "device_name": "sw-core-a" } },
  "hosts":    { "1": { "nickname": "web-1" } }
}
```

**一份 model 一份 overlay**，不是整個 checkout 一份：dpid 1–10 在 OVS 與 P4 兩份拓樸裡**都存在**，
而那個碰撞正是 `activeTopologyPath()` 上頭那段註解記載過的事故（P4 跑的時候改名寫進了 OVS 拓樸）。
共用一份 overlay 等於把同一個碰撞往上搬一層。

### 3-3. 順序：讀 overlay → 改圖 → 寫 overlay

兩個 setter 都**先**把 overlay 讀進來（`readNameOverlayForWriting`），**再**動圖，最後才寫檔。
這一步是刻意的：overlay 壞掉時整個呼叫**什麼都沒做**，端點回的 400 是真的。
反過來（先改圖再發現檔讀不了）就是這個 repo 已經記過的
**「被拒絕的請求仍然做了事」**（KNOWN-ISSUES §04 bug shapes）。

同一件事在**載入**時走相反的決定：overlay 讀不了 ⇒ **一行 WARN、照常啟動**。
兩邊不一致是有理由的 —— 寫的時候拒絕是在保護「已經存在的名字」，
載入時拒絕是拿一座 fabric 去換一個裝飾性的檔案。

`m_configurationFileMutex` 現在**先於** `m_graphMutex` 取得（W5 的順序相反）。
全 `src/`＋`include/` grep：`m_configurationFileMutex` 只有這兩個 setter 用，
兩支都用同一個順序，沒有環。

⚠️ **兩個端點對這個 throw 的回應碼不同，而且沒有統一**：`modify_nickname` 有自己的
local catch ⇒ **400**（`HttpSession.cpp` 的 `handleModifyNickname`）；
`modify_device_name` 沒有 ⇒ 落到 `buildResponse` 的 `std::exception` catch ⇒ **500**。
本單刻意不動這件事（那是既有的不一致，不是 W10 引進的），只把**它變得安全**：
09-04 的 chaos 審查記過「那個 local catch 對 `setVertexNickname` 內部的例外也回 400，
而那時可能已經改了一半」——現在 throw 一定發生在動圖之前，
所以無論 400 或 500，**「什麼都沒做」都是真的**。

### 3-4. `ndt status --check`：指名，但不比

新增的第 6 列 `device names` **永遠不寫 `bad`**。它存在是為了讓
「overlay 不在 sha256 裡」是一件**看得見**的事，而不是從沉默裡推出來的：

```
  topology file  sha256 2266c69cbcd3    == recorded   ok
  device names   2 set through the API   not compared -- the model file is the baseline
```

沒有 overlay 時印 `none set through the API   (.test_run/...)`；
overlay 壞掉時印 `? set through the API` —— **裝飾性的檔案不准把環境檢查判紅**。

## 4. 測試

`tests/test_NicknameDoesNotRewriteTheFile.cpp` → **改名並改寫**成 `tests/test_NicknameOverlay.cpp`
（`git mv`；舊檔的主題「模型檔被重寫得多整齊」已經不存在了）。
suite 名 `NicknamePersistenceTest` 保留，14 個 case：

| 群 | case | 斷言 |
|---|---|---|
| 缺陷本身 | `AModifyNicknameLeavesTheTopologyFileByteIdentical` | 🔴 **整份檔案逐位元相同**（不是「只差一行」） |
| | `AModifyDeviceNameLeavesTheTopologyFileByteIdenticalToo` | 孿生，各一支 |
| | `TheMininetTopologyKeepsItsBytesToo` | 沒有結尾換行的那一份 |
| | `EveryShippedTopologySurvivesARenameByteForByte` | **13/13 逐位元**（W5 只能做到 9/13） |
| overlay | `TheNicknameIsWrittenToTheOverlayUnderTheSwitchsDpid` | 🔴 對照：不是「什麼都不存」 |
| | `TheDeviceNameGoesToTheSameEntryAndDoesNotEvictTheNickname` | 兩個欄位要 merge 不是覆蓋 |
| | `AHostIsKeyedByItsMacAndNotByItsDpid` | 🔴 §3-2 那個碰撞 |
| 疊回去 | `AFreshLoadPicksTheNicknameBackUp` | 🔴 **重啟後名字要回來**（分辨 W10 與「乾脆不存」） |
| | `AFreshLoadPicksAHostsNicknameBackUpUnderItsMac` | 讀端也要看 hosts section |
| | `AnOverlayOnlyTouchesTheDeviceItNames` | 改一台，只有一台變 |
| 對照 | `ANicknameChangeStillReachesTheGraph` | 記憶體那一半還在 |
| | `ADeviceNameChangeStillReachesTheGraph` | 孿生 |
| | `AnUnreadableOverlayDoesNotStopTheTopologyFromLoading` | 🔴 壞檔不准擋啟動 |
| | `AnOverlayEntryForAnAbsentDeviceIsIgnoredRatherThanMisapplied` | 找不到的 dpid ⇒ 忽略，**且不落到別台** |
| 位置 | `TheDefaultOverlayPathIsOutsideSettingAndNamedAfterTheModel` | 不在 `setting/`、在 `.test_run/`、帶 model 名 |
| | `TheOverlayPathFollowsTheActiveTopology` | 兩個平面兩份 overlay |

🔴 **每一支都用 `NDTWIN_TOPO_FILE`＋`NDTWIN_NICKNAME_OVERLAY` 指到 pid-tagged 的暫存檔**
（手法沿用 W5，出處 `test_PollDoesNotResurrect.cpp`）。
一個內容是「它寫到不該寫的檔」的缺陷，它的測試不可以寫到那個檔，也不可以寫到真的 `.test_run/`。

`ndt` 那一半在 `tests/shell/test_ndt_status_check_baseline.sh` 新增 **§9**（12 個 check），
用該檔既有的 fixture（`REPO` 導到 temp dir、全部探針 stub）。
🔴 §9 自己帶反向對照：**有 overlay 的時候，模型檔被改仍然要紅** ——
少了它，一個「乾脆不比模型檔」的 `--check` 會通過 §9 的每一條。

## 5. 看紅

閘門：`tests/shell/mutate_nickname_overlay.sh`，13 個變異（10 個 kernel + 3 個 `ndt`）＋2 個對照。
逐字紅在 `RED-GREEN.md`。

## 6. 沒做的事

- **沒有跑 live**：沒有起 kernel、沒有打 `POST /ndt/modify_nickname`、沒有碰 lab。
  AFTER 的證據是 gtest 與閘門；BEFORE 是 09-05 夜巡 R0 的實測（🟠，我沒複驗）。
  ⚠️ **`ndt status --check` 沒有在真的 lab 上轉綠過** —— §9 是 fixture 驅動的離線測試。
  這是本張單最需要 live 補一刀的地方（和 W5 同一個位置）。
- **`--topology` 指到 `setting/` 以外的檔時，overlay 會落在 `.test_run/` 底下用該檔的 stem 命名。**
  兩份不同目錄、同檔名的 model 會共用一份 overlay。沒有處理：出貨檔沒有這種情況，
  而加 hash 會讓 overlay 的檔名對人不可讀。列在這裡不藏。
- **舊的閘門 `tests/shell/mutate_nickname_does_not_rewrite_the_file.sh` 已刪**（見 §7）。

## 7. 與別的單／文件的關係

- 🔴 **刪掉一個閘門**：`mutate_nickname_does_not_rewrite_the_file.sh` 的六個變異裡有四個
  （M1 ordered_json、M5 縮排、M6 結尾換行、M2/M3 寫模型檔）打的是**已經不存在的碼**。
  它的 M4（記憶體那一半）在新閘門裡是 M5，兩個 control 在新閘門裡是 C1／C2。
  沒有任何 CI 清單／`test_local_ci.sh`／`.github` 引用它（09-06 全 repo grep）。
- `tools/contract_test/spec.py` 的 `modify_device_name` 註記（「EXPECT A DIRTY TREE ANYWAY …
  git checkout it after a mutation run」）**已過期**，本單一併改。
  W5 的 FIX §7 當時沒改，理由是「等 (a)/(b+)/(c) 裁完一次改乾淨」—— 現在裁完了。
- `tools/contract_test/warning_allowlist.txt:127` 的 `FORBID | No matching node in JSON`
  **留著不動**：那兩個 throw 隨模型檔寫入一起消失了，這條規則從此不會觸發，
  但它擋的是「改名打到錯的拓樸檔」這個 class，留著沒有成本。
- `doc/2026-01-02_ndt_api.md` §20（`modify_nickname`）與 §15（`modify_device_name`）加持久化說明。
- `doc/KNOWN-ISSUES.md` 新增 **B-10**，狀態 **OPEN**、修法在分支上 ——
  照該檔 §B-7／B-8 前面那段自己立的慣例（條目照登、狀態維持 OPEN、分支與 commit 寫在狀態行），
  以及 A-1 的「變異閘在 trunk 上跑綠之前不得改 RESOLVED」。
