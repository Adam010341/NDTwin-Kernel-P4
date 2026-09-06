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

---

## 5. 沒做的與為什麼

1. **沒有 live 驗本單的修法。** lab 不是我的（R2 共用規矩明寫）。
   §1 的 lw8b 是**修法之前**的量測，證明缺陷存在；**「修好之後 Ryu 重啟不會撤」沒有在真機上跑過**，
   只有離線測試（`ARyuRestartDoesNotWithdrawAnInjectedLinkFailure` 走真的 HTTP 路由 ＋ 真的輪詢
   `updateLinks`，但不是真的 Ryu）。最小 live 配方寫在 SUMMARY §7。
2. **啟動掃 qdisc 沒有在真機上跑過**——`realTcRunner()` 這條路徑（真的 `sudo -n tc qdisc show`）
   只有讀碼。假 runner 覆蓋了掃描範圍、偵測、不寫入、不宣告、讀不到、非 MININET 六種行為。
3. **沒有把純宣告那一半也擋掉**（見 §2 末）。那要一個 kernel 現在沒有的鑑別力
   （「這個 POST 真的來自 Ryu 嗎」），而裁決的口徑不是那個。
4. **沒有動 `updateHosts`**——W8-7 是輸入驗證，不是狀態機（Adam 裁的方向）。
5. **沒有改 `intelligent_router.py`**（Ryu 那側完全不用改，也不該改：它的行為是對的）。
6. **`inject_link_*` 在 MININET 下真的會不會讓封包停，仍然沒有被任何東西證明過**——
   這是 W8 §5-1 的既有缺口，本單沒有補。
