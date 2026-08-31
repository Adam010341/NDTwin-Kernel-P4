# 回報義務清償・進度（母體＝`77_` 的 16 條未清償）

**規則**：母體是**條款**不是關鍵詞；補報一律「追加一節、不改原文、記明補報日期與漏報事實」。
常設化＝`doc/2026-08-31_round-closing-checklist.md` §6。

| # | 條款 | 狀態 | 落點 |
|---|---|---|---|
| R41／R42 | ② §7.4 第 1 項＋其後果條款（「both are reported whichever way they come out」） | 🏁 **已補報** | `packet-size-sweep/FINDINGS.md` 補報節（`e081a25`）——判準達成 1.25<1.5、敏感度揭露（arm a 1.875／均值恰 1.50）；後果觸發：stock 側隔離後 ×1.8 vs fast ×1.2 |
| R56 | ③ `/proc/net/snmp` 收端讀出 | 🏁 **已補報（替換而非補強）** | `flow-count-capacity/FINDINGS.md` 補報節（`0dc8fa5`）——56 個 datagram 全落 n=1/2、n≥4 全零 |
| R9 | ①/①b ingress-RX vs egress-TX 配對 | 🏁 **已補報** | `FINDINGS-1b.md` 補報節（`4b0da33`）——stock 22.6/22.9%、fast 9.9/10.2% 於 s1 內部消失而 netdev drop 欄全 0；**附整臂累計的口徑限制** |
| R55 | ③ `tc -s qdisc`（註冊為 non-negotiable） | 🏁 **已定位並記錄**（無法補報——資料不存在） | `FINDING-htb-false-negative-mechanism.md`（`c55a12b`）——31/31 檔內容是 `sudo: a password is required`；**這同時解掉 OvS 輪掛著的「機制未定位」** |
| R83／R95 | OvS 截尾規則＋H-C | 🏁 **已裁決並落地** | auditor 裁 H-C 觸發；`ovs-flowcount-control/FINDINGS.md` §1a（`d8037ea`）——四種讀法、算式、往哪邊解全部寫出 |
| R52 | ③ 的 H3 從未書面裁決 | ⬜ **待 auditor 裁**（材料已備＝`77_` Part 2(a)，四種讀法） | — |
| R12／R35／R60 | 三輪的「量測窗內不 commit」合規從未主張 | ⬜ **可補報，資料已回收** | `git log --all` 三輪窗內皆無 commit；⚠️ ①b 有兩顆 commit 落在窗前 **7m34s**，而 `agy` 尾巴約 10 分鐘 ⇒ **補報時要照實揭露這個重疊風險** |
| R88 | OvS 的 `softirq` 獨立欄從未回報 | ⬜ **可補報，資料已回收** | `softirq_ticks` 5212/7447/10843/8587/5758/7309；**第七臂的 `arm.meta` 沒有 load 區塊** |
| R73 | ③「128-host fabric 是否約略減半」的 open observation | ⬜ **可補報，需一句判讀** | 300→160＝0.53×（約減半）但 300→240＝0.80×；且 ①b 在**同一個 128-host fabric** 單跳讀到 **360**，高於 4-host 三跳的 300 ⇒ 「表格佔用效應」的簡單版**不成立** |
| R11 | ①「`load1` 作為 pre-screen」 | 🔴 **永久無法清償** | **從未採集**——`run_build_arm.sh` 無 `load1`、`arm.meta` 無該鍵（③ 與 OvS 有）。⇒ 只能記為「註冊了但未實作」 |
| R92 | OvS「外部 commit/agy 以 per-PID 差分量化記錄」 | 🔴 **永久無法清償** | 僅有定性敘述（`F:122-124`「7 agents streamed concurrently」「n16_a busy 0.8658 部分屬之」），**無任何 per-PID `utime+stime` 差分數字** |

## 兩條「永久無法清償」的處置建議

**不是把它們刪掉，是把它們寫成限制。** 建議措辭：
> 本輪註冊了 X 作為 Y，**但該讀數從未被採集／從未被量化**；因此本輪對 Y 的宣稱
> 僅有 Z 級證據。此缺口在 2026-08-31 的回報義務清償盤點中發現並記錄。

🔑 **理由**：一條「註冊了但沒做」的條款若靜靜消失，下一個讀者會以為它做了——
**而預註冊的全部價值就在於它列出了本來該做的事**。

[Co-developed with claude code -- Adam]
