# W8b — 撤回要對得上一次觀測到的斷（＋拒收 dpid 0 ＋啟動掃 qdisc）

分支 `fix/w8b-withdrawal-needs-observed-failure`，base＝`fix/w8-declared-link-failure-sticky`@`017c060f`
（該分支的 base 是 trunk `1536ff17`）。**未併、未推、沒有碰 lab。**
[Co-developed with claude code -- Adam]

> 🔴 **「跑過」與「讀過未執行」分開寫。** 每一段都標了是哪一種。
> 本單**沒有自己的 live 驗**——lab 不是我的（R2 共用規矩：live 由 orchestrator 做）。
> 但本單修的東西**是 live 量出來的**：lw8b 臂（09-07 00:08）。那一段是 🟢，來源在下面。

---

## 1. 這一輪修的是什麼：W8 擋住了輪詢，沒擋住控制面重啟

B-6 第一輪（W8）的成果是「宣告黏得住拓樸輪詢」。lw8b 臂把它放到控制面重啟底下，
它在 **10 秒內**就沒了。

🟢 **逐字證據**（`scratch/overnight-2026-09-05/logs/live-round2-console.log`，
arm `lw8b`，OVS 4 hosts，branch `fix/w8-declared-link-failure-sticky`@`017c060f`，
kernel `37d641fa9fd6fc14`；判讀寫在 `scratch/overnight-2026-09-05/rounds/07-LIVE-branch-checks.md`）：

| 時刻 | 逐字 |
|---|---|
| 00:08:44 | 宣告 s1:1 → s5:1 ⇒ `is_up=False down_reason=declared` |
| 00:08:47 | 指名 kill Ryu（pid 793346），:8080 關；**Ryu 不在時邊仍 declared** |
| 00:08:54 | 同 argv 重起 Ryu（pid 794466），:8080 開；`ryu2.log` 每條 link 一行 `Link added:` |
| 00:08:53+ | kernel.log 每條 link 一個 `POST /ndt/link_recovery_detected` → `link recovered on …` |
| 00:09:04 起 | t+10 s … t+90 s **9/9 樣本 `is_up=True down_reason=none`** |

**機制**：Ryu 的 topology 模組在 LLDP **初次發現**每條 link 時發 `EventLinkAdd`，
`intelligent_router.py::on_link_add`（`@set_ev_cls(event.EventLinkAdd)`）從那裡 POST
`/ndt/link_recovery_detected`。⇒ **控制面重啟在 wire 上與「整個 fabric 同時復原」一模一樣**，
而 `handleLinkRecovery` 當時無條件 `clearEdgeDeclaredDown`。

🔴 **兩半，危險的是第二半**：
- 純宣告（`link_failure_detected`，沒有真的斷）：**靜默的注入結束**——B-6 的同一科，
  觸發條件從「30 s」換成「Ryu 重啟」。
- `inject_link_failure`（有 netem）：**宣告被撤、netem 還在** ⇒ **圖說 up、封包不通**。

**Adam 2026-09-07 00:1x 裁 (b)**：撤回要對得上一次觀測到的斷。

---

## 2. 機制（一句話 ＋ 檔:行）

**一句話**：邊上多一個「控制面報過這條 link 斷」的旗標，`/ndt/link_recovery_detected`
**只在能跟它配對時**才撤宣告；配對用掉就沒了，一個 report 只買一次撤回。

| 檔 | 做了什麼 |
|---|---|
| `include/common_types/GraphTypes.hpp` `EdgeProperties` | 🆕 **第六個旗標 `failureReported`**。與 `declaredDown` 分開：前者是「控制面說它看到斷了」，後者是「分身正因為被要求而把它壓著」。`from_json` 一樣**刻意不讀回來** |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | 🆕 `enum class LinkRecoveryOutcome { Applied, Retained }`；`setEdgeDownByReportedFailure`／`applyReportedLinkRecovery`／`getEdgeFailureReported`；`mininetLinkInterfaces()`／`warnAboutResidualNetem()`；寫入者表補成五種身分 |
| `src/…/TopologyAndFlowMonitor.cpp` `setEdgeDownByReportedFailure` | 寫 report ＋ 呼叫既有的宣告版。**只有 `/ndt/link_failure_detected` 走這裡** |
| 同上 `applyReportedLinkRecovery` | 🔑 **規則本體，一個條件**：`!failureReported && declaredDown` ⇒ WARN ＋ `Retained`（不撤、不抬）。否則花掉 report、撤宣告、抬起邊、清 `downReason`、erase `m_linkResurrectionDeclined` |
| 同上 `clearEdgeDeclaredDown` | 維持**無條件**（`/ndt/inject_link_recovery`），並一併花掉 report |
| 同上 `mininetLinkInterfaces` | 每條**交換機↔交換機** edge 的 source 端 ⇒ `<bridge>-eth<port>`，去重。跳過 host 邊與沒有 `bridge_name` 的交換機 |
| 同上 `warnAboutResidualNetem` | 非 MININET 直接回空；每個介面 `tc qdisc show`；讀不到 ⇒ 一行 WARN 說「讀不到」；找到 netem ⇒ 收進 `found`；最後 **一行** WARN 列出全部 |
| `src/…/HttpSession.cpp` 匿名 namespace | 🆕 `namesTwoSwitches(src,dst)` ＋ `kHostEdgeRefusal`（W8-7） |
| 同上 `handleLinkFailure` | 加 dpid-0 門；兩處改叫 `setEdgeDownByReportedFailure` |
| 同上 `handleLinkRecovery` | 加 dpid-0 門；兩處 `clearEdgeDeclaredDown`+`setEdgeUp` ⇒ 一次 `applyReportedLinkRecovery`；任一方向 `Retained` ⇒ body 加 `declaration_retained` ＋ `detail` ＋ `until` |
| 同上 `handleInjectLinkFailure`／`handleInjectLinkRecovery` | 各加一道 dpid-0 門 |
| `src/main.cpp` | `loadStaticTopology()` 成功之後、**綁 port 之前**呼叫 `warnAboutResidualNetem(realTcRunner())`；回傳值刻意不當 gate |

### 為什麼 `applyReportedLinkRecovery` 是**一次**上鎖

原本是 handler 裡 `clearEdgeDeclaredDown(e); setEdgeUp(e);` —— 兩次上鎖，中間那個窗口裡
邊是 `isUp=false` 且**沒有宣告**，而那正是輪詢唯一被允許抬起它的組合。合成一次順手修掉。

### 🔴 這條規則**沒有**蓋住的殘餘（自我揭露）

用 `/ndt/link_failure_detected` 做的**純宣告**注入，**仍然**會被同一條 link 的重新發現撤掉——
因為那個 POST 本身就登記成「控制面報了這條 link 斷」，kernel 分不出它是不是真的來自 Ryu。
**這正是裁決的口徑**（「Ryu 之前**也**對這條 link 報過 `link_failure_detected`」）：
一個 report 買一次撤回，配得上就撤。

⇒ **lw8b 那一次重播，s1↔s5 那條邊的結果不會改變。** 改變的是：
1. 其他 8 條 link 的「無主 recovery」再也撤不掉任何東西；
2. **`inject_link_failure` 的宣告對 Ryu 重啟免疫**——也就是「圖說 up、封包不通」那一半被關掉；
3. 被拒絕的那一次，回應**說得出來**（`declaration_retained`）而不是靜默。

要注入而不想被撤：**用 `/ndt/inject_link_failure`。** 手冊 §2b 已寫。

### 為什麼被拒絕仍然回 200

`intelligent_router.py` 的兩個 POST 站點都有這段：任何 ≥400 就記
`"NDT REJECTED this notification: … the kernel's view is now stale"`。
在這裡那句話是**假的**（kernel 的判斷才是對的），而且會在每次控制面重啟時對每條 link 各印一次。
所以狀態碼留 200，**把誠實放進 body**：`declaration_retained: true` ＋ 指到
`/ndt/inject_link_recovery` 的 `detail`／`until`，另外 kernel 這側寫一行 WARN。

---

## 3. W8-7：四個端點拒收 dpid 0

W8 §7-7 留下的那扇門：`findEdgeBySrcAndDstDpid` **只比對兩個 dpid**，而 host 頂點的 dpid 是 0
⇒ `POST /ndt/link_failure_detected {"src_dpid":1,"dst_dpid":0,…}` 會挑到「s1 的第一條 host 邊」
（挑哪一條由 edge 插入順序決定，呼叫端說不出自己指的是哪一條，kernel 也不告訴它挑了哪一條），
宣告設上去，而 `updateHosts` 的 `isUp = true` **沒有** veto ⇒ 下一輪抬回來。
**B-6 在唯一沒被 veto 覆蓋的邊形狀上重演。**

**Adam 裁「端點拒收 dpid 0」**（不是「veto 也加進 `updateHosts`」）：這是**輸入驗證問題**，
不是狀態機問題。實作成一個 helper ＋ 四個呼叫點，`400` ＋ 一句說明 host 邊不由此端點定址。

⚠️ **裁決點名的是 `link_failure_detected`／`inject_*`（三個），我做了四個**——
`link_recovery_detected` 也拒。理由：這一族的契約就是「不定址 host 邊」，
一個「failure 端點拒、recovery 端點收」的 payload 是**一條沒有人能注入的 link**，
而 `inject_link_recovery` 還會對它解析出來的介面跑 `tc qdisc del`。
要撤掉第四扇門只要刪 `handleLinkRecovery` 裡那一段（見 §5）。

**Ryu 不會踩到**：`EventLinkAdd`／`EventLinkDelete` 是 LLDP 的交換機↔交換機事件，
host 走 `EventHostAdd`，根本不到這兩個端點。

---

## 4. W8-4：啟動掃 qdisc

**為什麼需要**：`declaredDown`／`failureReported` 刻意不進檔案（宣告活在行程裡），
而 `tc netem` 活在機器的 qdisc 樹裡 ⇒ **kernel 一重啟，兩者就分家**：
圖上 `down_reason` 乾乾淨淨，鏈路上 100% 丟包。

**Adam 2026-09-06 裁**：**掃、WARN，不清、不當宣告接回。**

- **掃什麼**：MININET 下，每條**交換機↔交換機** link 兩端的 `tc qdisc show`——
  剛好是 `/ndt/inject_link_failure` 能寫到的那一組，不多也不少。
  host 邊排除（W8-7 之後根本定址不到）、沒有 `bridge_name` 的交換機跳過（不用猜的）。
- **不清**：`tools/test_workflow/faults.sh` 有權在介面上掛 netem；
  一個會在啟動時清掉別人 netem 的 kernel，會靜默毀掉它自己啟動時正在跑的那一輪。
- **不當宣告接回**：從 qdisc 讀數造出一個宣告＝分身自己當自己的證人；
  而且那個讀數說不出「這對邊的哪一個方向」是誰的意思。
- **讀不到 ≠ 乾淨**：`tc qdisc show` 失敗（`sudo -n` 被拒、介面不在）另外印一行說「讀不到」。
  沉默只能有一種意思。
- **在哪裡叫**：`main.cpp`，`loadStaticTopology()` 成功之後、**任何 socket 被綁之前**。
  在 port 開了以後才印的訊息，健康檢查已經記完「up」了不會回頭讀。

> 🆕 **本節寫的是這個分支的行為，而它已經被下一張單改掉了。**
> 本單 SUMMARY §7-4 自陳的洞（`faults.sh`／chaos harness 掛在 host 面 port 的 netem 掃不到）
> 由 Adam 裁成 **E-20**：另開分支 `fix/e20-startup-sweep-all-interfaces`（base＝本分支 tip
> `8a3f71d1`）把掃描改成**一次裸 `tc qdisc show`（不帶 `dev`、不走 sudo）＋三分類**
> （`link`／`host-facing`／`unknown`）。**不清、不宣告 down 兩條都沒變。**
> 併序 W8 → W8b → E-20；細節見 `doc/audit/2026-09-07_fix-e20-startup-sweep-all-interfaces/FIX-E20.md`。

---

## 5. 沒做的與為什麼

1. **沒有 live 驗本單的修法。** lab 不是我的（R2 共用規矩明寫）。
   §1 的 lw8b 是**修法之前**的量測，證明缺陷存在；**「修好之後 Ryu 重啟不會撤」沒有在真機上跑過**，
   只有離線測試（`ARyuRestartDoesNotWithdrawAnInjectedLinkFailure` 走真的 HTTP 路由 ＋ 真的輪詢
   `updateLinks`，但不是真的 Ryu）。最小 live 配方寫在 SUMMARY §7。
2. **啟動掃 qdisc 沒有在真機上跑過**——`realTcRunner()` 這條路徑（真的 `sudo -n tc qdisc show`）
   只有讀碼。假 runner 覆蓋了掃描範圍、偵測、不寫入、不宣告、讀不到、非 MININET 六種行為。
   🆕 **E-20 順手修掉了這條裡藏的一個真缺陷**：`sudo -n tc qdisc show`（本單用的形式）
   確實在授權裡，但 E-20 需要的**裸形式（不帶 `dev`）不在**——而 `sudo -n` 被拒 ＋ stderr 丟掉
   長得跟「哪裡都沒有 netem」一模一樣。E-20 改走**不帶 sudo** 的讀（讀 qdisc 本來就不需要權限）。
3. **沒有把純宣告那一半也擋掉**（見 §2 末）。那要一個 kernel 現在沒有的鑑別力
   （「這個 POST 真的來自 Ryu 嗎」），而裁決的口徑不是那個。
4. **沒有動 `updateHosts`**——W8-7 是輸入驗證，不是狀態機（Adam 裁的方向）。
5. **沒有改 `intelligent_router.py`**（Ryu 那側完全不用改，也不該改：它的行為是對的）。
6. **`inject_link_*` 在 MININET 下真的會不會讓封包停，仍然沒有被任何東西證明過**——
   這是 W8 §5-1 的既有缺口，本單沒有補。

---

## 6. 補一顆（09-07，E-22）：recovery 的 log 要說出結果，＋手冊 §2b 的量測口徑

裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md`「grill §4E 第六輪」的 **E-22**
——「3-52 兩個小缺陷：**併 W8b 前在分支上補一顆**（log 移到 outcome 之後＋手冊 §2b 改句），閘門重跑」。
發現正本：`WAKEUP.md` §3-52（round 2 live 抓到的）。這一節接在上面五節後面，**同一個分支、一顆 commit**。
[Co-developed with claude code -- Adam]

### 6.1 缺陷一：`link recovered on …` 印在判定之前

`HttpSession.cpp` 的 `handleLinkRecovery` 把

```
SPDLOG_LOGGER_INFO(Logger::instance(), "link recovered on {}:{} -> {}:{}", …);
```

印在 `findEdgeBySrcAndDstDpid` **之前**、配對規則之前 ⇒ **三種結果同一句話**，
而那句話宣稱的正是讀者最想知道的那件事。

🟢 **逐字證據（跑過的 live，不是推論）**：`scratch/overnight-2026-09-05/logs/lw8b2-kernel.log`，
arm `lw8b2`，2026-09-07，OVS 4，binary＝本分支 tip `7abdd69a` 建出來的 `000bbaf392dd7c78`：

| 行 | 時刻 | 結果 | 逐字 |
|---|---|---|---|
| 437 | 04:33:37.198 | **被拒**（手動 POST） | `link recovered on 1:1 -> 5:1` |
| 453 | 04:33:38.131 | **撤回成功** | `link recovered on 1:1 -> 5:1` |
| 458 | 04:33:38.142 | **撤回成功** | `link recovered on 5:1 -> 1:1` |

🔴 **修正一個口徑**（單子與 rounds/08 的寫法都略微高估了）：**被拒的那一次不是全然沉默**——
`TopologyAndFlowMonitor.cpp:3147` 的 WARN 在 438／439 兩行就跟在後面（每個方向一行）。
所以缺陷不是「什麼都沒說」，是**同一次請求裡兩行互相矛盾**，而且矛盾的那一半
（`HttpSession` 那行 INFO）**才是宣稱結果的那一句**，級別還是 INFO。
一個 grep `link recovered on` 的操作者，在 437 與 453 之間分不出哪一次真的撤回了。

### 6.2 改法：三種結果、三句話、印在結果已知之後

`HttpSession.cpp` 的匿名 namespace 新增 `enum class RecoveryLogOutcome { Withdrawn, Retained,
NoSuchEdge }` 與 `logLinkRecoveryOutcome()`，兩個呼叫點：

| 結果 | 級別 | 句子（開頭） | 印在哪 |
|---|---|---|---|
| 撤回了 | INFO | `link recovered on …: any declaration standing on this link was withdrawn and both directions are up` | 兩個方向都跑完 `applyReportedLinkRecovery` 之後 |
| 保留宣告、沒撤 | **WARN** | `link recovery declined on …: … the declaration was retained and the link is still down. POST /ndt/inject_link_recovery to withdraw it` | 同上（任一方向 `Retained` 就算） |
| 邊不存在 | **WARN** | `link recovery ignored on …: the topology holds no such edge, so nothing was withdrawn and nothing was marked up` | 404 那一支，`findEdge` 回空之後 |

- **一次請求一行**，不是一個方向一行：一個 report 指的是一條 link，兩個方向結果不同是
  kernel 自己的狀態不一致（那條路另有 500 ＋ 它自己的 WARN），不是要講兩次的事。
  `Retained` 贏平手，因為「還是 down」才是操作者要動手的那一半。
- **不改 wire**：狀態碼、body、`declaration_retained`／`detail`／`until` 一個字都沒動
  （lw8b2 剛驗過 8 PASS）。body 的 `if` 條件抽成 `const bool retained`，同一個布林。
- **反向邊不存在的 500 那一支不變**：它本來就印了自己拿到的結果
  （`forward direction applied (declaration retained | marked up)`），而且到不了上面三句。
- ⚠️ **副作用（自我揭露）**：log 的來源欄從 `HttpSession.cpp:587 handleLinkRecovery`
  變成 `HttpSession.cpp:<n> logLinkRecoveryOutcome`。緊接在前面的
  `HttpSession.cpp:564 handleLinkRecovery] Handle Link Recovery` 與請求行還在，
  所以脈絡沒有掉；但**任何按 `handleLinkRecovery` 這個函式名 grep 結果行的腳本會漏掉它**。
  repo 裡沒有這種腳本（`git grep 'link recovered on'` 只中程式碼與本輪文件）。

### 6.3 缺陷二：手冊 §2b 那句「measured, arm lw8b」量的不是它說的那條邊

原句把「Ryu 重啟一秒內對每條 link 發 recovery」的量測，掛在「**所以 §2b 的注入撤不掉**」這個宣稱上。
🟢 **實測不支持這個連結**：

- `lw8b` 那一臂的宣告是用 **`/ndt/link_failure_detected`** 下的（`live_w8b_ryu_restart.sh:17`），
  **純宣告、沒有 netem** ⇒ 它量到的是純宣告的邊。
- `lw8b2` 直接量了另一半：`netem loss 100%` **連 LLDP 一起擋** ⇒ Ryu 重啟後**重新發現不了**那條 link
  ⇒ 04:32:06 那 **30 筆** `link_recovery_detected` 裡**沒有** 1:1↔5:1；
  `logs/lw8b2-ryu2.log` 對 s1-s5 的 `Link added` 要等到 04:33:38 拆掉 netem 之後才出現，
  而對照邊 s2-s6 在重啟一開始就 added。
- ⇒ **沒有配對規則，netem 注入一樣活得過 Ryu 重啟**——在 base 分支
  `fix/w8-declared-link-failure-sticky` 上（§2b 已經存在、撤回還是無條件的）就已經如此；
  那一半是 LLDP 擋的，不是配對規則擋的。（`trunk` 不在這個比較裡：它沒有 §2b，
  而且它的宣告連 30 秒都撐不住。）
  配對規則真正擋的是**任何打得到注入邊的 recovery**：netem 拆掉之後 Ryu 補發的那兩筆，
  以及操作者把 §2 當 §2c 用的誤 POST（`lw8b2` 步驟 6 的手動 POST 證實：200 ＋
  `declaration_retained:true` ＋ 邊仍 down）。

**改了哪裡**（英文，改的是口徑不是行為）：
- `doc/2026-01-02_ndt_api.md` **§2b**：拿掉「including the burst … (measured, arm lw8b)」，
  改成「no `link_recovery_detected` can end this injection — whoever sends it」，
  另加一段 ⚠️ 說明量的是哪一種邊、LLDP 那一半、以及配對規則實際擋的是什麼。
- 同檔 **§2 的「Why.」**：補一句「that arm declared the link through §1 — a declaration only,
  no netem」，並把「for a §2b injection that is the worse half」改成不再宣稱重啟是到得了它的路徑。
- 同檔 **§1 的指路**：`see §2 …` 改成 `see §2 for why the rule exists, and §2b for what was
  measured and on which kind of edge`。
- 同檔 **§2** 另加一段 🆕：三句 log 是什麼、以前是哪一句、`lw8b2` 04:33:37.198 vs 04:33:38.131。
- `doc/KNOWN-ISSUES.md` **B-6 第二輪**：加「補一顆（09-07，E-22）」一段，含上面兩個但書。

`git grep -n 'lw8b'` 的其餘命中都不必改：`FIX-DECLARED-LINK-FAILURE.md:186`、
KNOWN-ISSUES B-6、`GraphTypes.hpp:700`、`TopologyAndFlowMonitor.hpp:303,312`、
`TopologyAndFlowMonitor.cpp:3135`、`test_PollDoesNotResurrect.cpp:1113`、
`test_HttpSessionRouting.cpp:1031`、閘門檔頭——它們講的都是 `lw8b` 那一臂本身
（純宣告的邊被無條件撤回），**那個敘述本來就是對的**。被高估的只有 §2b 那一句把它借去
證明另一種邊的地方。`HttpSession.cpp:604` 的註解同理，未動。

### 6.4 測試與閘門

`tests/test_HttpSessionRouting.cpp` 的 `DeclaredLinkFailureWireTest` 加 **3 格**
（12 → 15，全套 1137 → 1140），抓 log 的手法照 `tests/test_NetemLinkFault.cpp` 的
`LogCapture`（ringbuffer sink ＋ 還原 level 與 sink 清單）——**重覆一份而不是抽出去**，
理由與那三個檔裡寫的一樣。W11 分支 `8c8a0fe4` 只是把 logger 釘住（level=off），
本輪需要的是**讀得到內容**，所以形狀取自 `LogCapture` 而不是它；**W11 那條分支沒有 merge**。

| 案子 | 斷言 |
|---|---|
| `ADeclinedRecoveryIsNotLoggedAsARecovery` | inject → `link_recovery_detected`：log **不含** `link recovered on`、**含** `declaration was retained`；邊仍 down |
| `AnAppliedRecoveryLogsThatTheDeclarationWentAway` | `link_failure_detected` → `link_recovery_detected`：log **含** `was withdrawn`、**不含** `declaration was retained`；邊回 up |
| `ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead` | dpid 9（拓樸沒有）：404，log **不含** `link recovered on`、**含** `no such edge` |

閘門 `tests/shell/mutate_withdrawal_needs_observed_failure.sh` **18 → 20 變異、3 → 4 對照**：

- **M19**「log 搬回判定前（3-52 verbatim）」——把那行 INFO 放回 `findEdge` 之前，
  **底下三句留著**（那才是誠實的重現：多印的那一行照樣會被讀成成功）。期望紅 2 格。
- **M20**「三句變一句，只是印得比較晚」——位置對、字不對。期望紅 3 格。
- **W4**（對照，必須留綠）「被拒那句改寫，但仍然說得出 `declaration was retained`」——
  證明新案子釘的是結果不是措辭。

新 anchor 三個：`log-placement`、`log-sentences`、`log-decline-text`（共 17 → 20），
`check_gate_anchors.py` 一併重跑。逐字紅在 `RED-GREEN.md` §5。
