---
name: injections-must-assert-their-own-success
description: "故障注入後必須斷言注入真的生效(/proc State、qdisc show),否則實驗無聲變 no-op;同一個 sudo 陷阱 20 分鐘內咬了剛寫完警告的作者;第五式:改組態要驗到「跑著的那個 process 的 argv 指的那個檔」為止;🆕 第九式:修正案改了量測對象卻沒改暖機對象——執行了、成功了、打錯地方"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3878c1c3-5bc1-4b38-b7ea-a95f52dd8e1d
  modified: 2026-08-31T10:17:39.805Z
---

**注入不驗證=實驗無聲作廢。** 2026-08-16 故障矩陣輪連環兩次:

1. `faults.sh` 首役,`FAULTS_KILL` 預設 `sudo -n kill` 在本機 sudoers 下要密碼
   → SIGSTOP 沒打進去,round 標 not-injected(它有防)。我把逃生門
   (`sudo -n mnexec -a 1 kill`)寫進它 header。
2. **20 分鐘後,我自己的 stage3 編排器用同一個裸 `sudo -n kill`**——B4/B5 兩案
   無聲未注入,capture 照跑、verdict 照裁,差點把「link-only 的結果」當成
   「組合故障的結果」歸檔;靠輸出裡一行 `sudo: a password is required` 抓回,
   stage4 重做。

**Why:** 注入失敗的預設形狀是 silent(sudo 印到 stderr、腳本繼續跑),而下游
的 capture/verdict 一切「正常」——沒有斷言就沒有任何東西會叫。與
[[smoke-the-accept-path-not-just-refusals]] 同族:寫了警告≠處理了,連作者自己
都會踩。

**How to apply:** 每個注入動作後面立刻驗證它宣稱的狀態改變:
- 訊號類 → `grep State /proc/<pid>/status`(STOP 要看到 `T`)、kill 後 `pgrep` 反查
- qdisc 類 → `tc qdisc show dev X` 看到 netem 行
- 驗證失敗就讓整個 case 大聲 FAIL,別讓它流進 capture。

## 第三次(2026-08-21):量測工具連毀三輪實驗,每輪的結果都「乾淨又合理」

要回答「`ndt down` 中途 Ctrl-C 會留下什麼」,四輪全部作廢,**三個不同機制**:

1. **harness 自己拆掉受測物**:用 `os.forkpty()` 跑 `ndt down`,fabric(topo session
   ＋10 bmv2＋138 mininet)在 3 秒內整個消失,`[3/3]` 沒東西可掃 → 得到「零殘骸」。
   **不送任何訊號、只套 pty 就重現**;無 pty 的同一指令 `[2/3]` 正確印 `topo stopped`。
2. **注入無聲 no-op**:改用 `sudo -n mnexec -a 1 kill -INT -- -PGID`,兩輪都「乾淨完成
   rc=0」。canary(`sleep 300`)收到同樣注入**活著,exit=0**。
3. **canary 本身壞掉**:想找哪種 kill 送得到,五種全 SURVIVED,連同 uid 的裸 kill 也是。
   問題在 `setsid sleep &` 之後的 `$!` **不是 sleep 的 pid**(setsid 會 fork,`$!` 是
   wrapper);`[1]+ Done` 立刻出現就是證據。一直在對死掉 wrapper 的 group 送訊號。

🔑 **exit code 不是送達證明,而「結果乾淨」最像成功。** 三輪都給出可以直接寫進報告的
數字,沒有任何一輪會自己喊錯。**是 canary 把第 2 層翻掉的 —— 就是這個檔上面那條規則。**

順帶一條被推翻的推論:我原本斷言 teardown 最危險的窗口是 `[3/3]` 的 `mn -c`。實測
**`[2/3]` 才是**(`topo-stop` 10 秒,Mininet 自己的 exit path 在那裡拆 fabric),
`[3/3]` 是掃一台已經空了的機器,0.3 秒。**讀碼排的風險順序整個相反。**

相關:[[destructive-shell-traps]]、[[new-tools-are-the-first-thing-under-test]]、
[[process-liveness-checks-lie-in-two-ways]]、[[ndt-one-command-lab-lifecycle]]。

## 2026-08-21：往上一層 —— 斷言注入「落在對的地方」,不只是「有生效」

LLDP 偵測那輪,探針斷言了 netem 存在(這條規則本身),然後**兩次回報「180 秒內沒有偵測到」**,
看起來像重大發現。**是探針壞了。**

128 台佈局下 host 依序填滿 s1..s4,所以 `10.0.0.4` 在 **s1 自己身上**(4 台佈局下它在 s4)。
探針打的是 `s1-eth6` —— **h4 的接取線**。接取埠上沒有 `Link` 物件,
所以 `EventLinkDelete` 永遠不會觸發,而直連主機也沒有替代路徑。
**netem 確實生效了,只是打在一個不可能產生訊號的地方。**

🔑 **注入的斷言要蓋住「位置」不只「效力」。** 同一族的另一個版本見
[[ratio-sides-must-share-a-population]](分子分母母體不同)。

## 而寫來擋這件事的守衛,自己錯了兩次

1. 拿 Ryu REST 的 `port_no`(**零填補的十六進位**)跟 `ovs-ofctl` 的**十進位**做字串比較 ——
   port ≥ 10 一律比錯。
2. `VAR=x curl ... | python3` —— **環境變數給了 curl 不是 python3**,檢查器 `KeyError` 當掉。

而且 **守衛崩潰與守衛否決共用同一個退出碼**,所以
**「從沒跑過的守衛」跟「跑過並說不」長得一模一樣**,連拒絕三次都看不出異常。
🔑 **可能失敗的守衛,失敗要跟裁決用不同的方式回報**,而且要把它讀到的東西印出來。

## 第三次:兩個 run 同時寫同一個輸出檔

前一個背景 job 還沒結束就啟動下一個,兩邊都 append 到同一個 `$OUT`。
產出的那筆 `detection=132.78s` **無法歸屬、直接作廢**。
判斷有沒有別的 run 在跑不要用 `pgrep -f`(會匹配自己的命令列,見
[[put-measurement-commands-in-script-files]]),用**環境本身的狀態**(這裡是 `ndt status`)。

## 第四次（08-21 深夜）：sudoers 只放行特定 argv 形式，裸形式無聲讀成「不存在」

beacon sweep 的注入錨點用裸 `sudo -n tc qdisc show`（無 `dev`）輪詢 netem——sudoers
只允許 `tc qdisc show dev s[0-9]*-eth[0-9]*` 這個**帶特定 device pattern 的形式**，
裸形式回 "a password is required"、stderr 被 `2>/dev/null` 吞掉 ⇒ grep 空 ⇒
「netem never appeared」，同時 measure_failover 自己在印 "netem verified present at
every check"。一個 rep 作廢。修法＝從 measure_failover 的輸出行撈 iface、
用 sudoers 放行的 `show dev <iface>` 形式輪詢（`f05da99` 前一個 commit）。

🔑 兩條可帶走：**sudo -n 的授權是 argv-pattern 級的，同一個工具的另一種寫法可能不在
allowlist 裡**——用之前 `sudo -l | grep` 查放行形式，別從「這工具能用」推論「這寫法能用」。
以及 **「當場繞過」不等於「修好」**：links-vs-edges 那個誤讀我在 run 當下就撞過、
手數 capture 繞過去，script 裡的壞 parser 留到審查才被抓（`f05da99`）——
繞過的當下就是修它的最便宜時點。


## 第五式(2026-08-25):**改了原始碼 ≠ 改了跑著的東西**,而中間有三層會說謊

為了排除一個變因,我把 `SAMPLE_TRUNC_BYTES` 從 128 sed 成 16384。**三層各自回報成功,但東西沒變:**

| 層 | 它說什麼 | 真相 |
|---|---|---|
| 1. `ndt up p4 128` | `up. ready`、fabric 起來了 | 🔴 **它不會重新編譯 `.p4`** |
| 2. 手動 `p4c-bm2-ss` 之後 | JSON 裡是 `0x00004000` ✅ | 🔴 **bmv2 還握著重啟前載入的舊 JSON** |
| 3. `pgrep -x simple_switch_grpc` | 零匹配(看起來像沒這個 process) | 🔴 **名字超過 15 字元的 comm 限制**(見 [[process-liveness-checks-lie-in-two-ways]]) |

**三層都不報錯。** 唯一抓得到的方法是逐層比對**時間戳**,最後驗到:

```bash
p=$(ps -eo pid,args | awk '/simple_switch_grpc/ && !/awk/ {print $1; exit}')
j=$(tr '\0' '\n' < /proc/$p/cmdline | grep '\.json$' | head -1)   # 跑著的那個 process 自己說它載了什麼
stat -c %y "$j"                                                     # 那個檔的 mtime vs 我改動的時間
python3 -c "...檢查 JSON 裡的實際常數..."                            # 內容,不是檔名
```

🔑 **判準:驗到「那個正在轉發封包的 process,它 argv 指的那個檔,裡面的值是多少」為止。**
驗原始碼不算、驗編譯產物不算、驗「重啟過了」也不算。

### 🔴 更前面還有一層:**記錄一個前提 ≠ 需要時會想起它**

那個 truncate 前提**是我自己查證後寫進報告的**,還跟審查員轉述過兩次
(「我的 P4 數字全在 `f64897b`(19:30) 之前」)。然後我自己在 23:15 `ndt up` 重建 fabric 時
**完全沒想起來**,拿著被污染的比值跑了一個「決定性比較」,差點據此下結論。

⇒ 前提要寫成**執行路徑上的斷言**,不能只寫在報告裡。
`run_plane.sh` 之類的 harness 應該在開跑前印出「當前 pipeline 的關鍵常數」,而不是靠人記得。
**(這條尚未實作,只是本輪學到的判斷。)**

## 🔴 08-27：**第三例——改到的檔不是會被執行的那份**（OVS 拓撲）

`8/27 sampling` 為工單 N 發現：**`ndtwin-lab` 起 OVS 拓撲跑的是
`~/Network-Traffic-Generator/testbed_topo.py`，不是 repo 裡那份同名檔。**
⇒ 改 repo 那份 ⇒ `git status` 顯示改了、還原紀律滿分、**fabric 一個位元組不變**。

**同族第三例**（前兩例：`ndt up` 不重編 `.p4`；bmv2 握舊 JSON）。
🔑 三例的共同形狀：**版控裡的檔案 ≠ 被執行的檔案**，而版控會給你一個很有說服力的
「我改了而且我還原了」的證據鏈，那個鏈**整條都是真的，只是打在旁邊那份上**。

📌 **對我接下來的工單 M（1 kHz → 1 Hz）直接適用，兩條**：
1. **碰任何組態前，先確認我改的是會被執行的那份**——用跑著的 process 的 argv 回推路徑，
   不是用 repo 裡的檔名。
2. **兩臂之間，那份檔的狀態必須一致。** N 會改 NTG 那份再還原 ⇒
   **若 M 的 before 在還原前、after 在還原後，兩臂的 fabric 不同**。跟對方對時間表。
   （同理：**兩臂要在同一個 VM 狀態下跑**——那台 4 vCPU 的 QEMU 起於 08-27 12:41:45。）

## 🔴 第六式（2026-08-28）：**同名檔案的兩份副本，只有一份在跑**

`mainDev` 要拿掉測試床的 `bw=` shaping，編輯了 **`NDTwin-Kernel/testbed_topo.py`（repo 根）**、重建 fabric。
**那不是跑的那一份。** `ndt:767` 自己的註解逐字寫著：

> **「128 comes from NTG's testbed_topo.py」** ⇒ 實際用的是 `~/Network-Traffic-Generator/testbed_topo.py`

**兩份內容還不一樣**（`diff` 說 differ）。**編輯完全沒生效**——驗證步驟量到上限沒動
（967.1M vs 改動前 969M；同交換機內 h1→h2 offered 4000M 也只送出 965.7M）。

## 🔑 沒有那步驗證會發生什麼，才是這條的重點

> 臂 B 會回報「**拿掉 shaper 之後抖動不變 ⇒ H1a**」——**一個完全捏造的結論**，
> 而且**很有說服力**，因為兩臂的數字**確實會不一樣**（fabric 重建過）。

⇒ 🔴 **最壞的形狀：假結論配上真的會變動的數字。**
**兩臂數字不同會被當成「實驗有效」的證據**，而它其實只反映 fabric 重建的雜訊。
**任何事後審查都攔不住它**——攔得住的只有「先驗證操作生效，再量測」。

## ⇒ 可操作

> **改一個檔案之後，不要驗「檔案被改了」，要驗「被改的那份是跑的那份」。**
> 便宜的做法：**改完先量一個該變的量**，沒變就是改錯地方。

📌 同型的線索常常已經寫在碼裡（這裡是 `ndt:767` 的註解），
**而沒有人讀到那一行**——見 [[cited-line-numbers-are-not-evidence]] 的反面：
**行號不是證據，但註解有時候就是答案，只是沒人往那裡看。**

## 🔴 第七式（2026-08-28 傍晚）：**檔案在打開的 fd 底下被搬走，寫入者不會知道**

第六式是「你改錯了副本」。第七式是**你沒改任何東西，是檔案自己走了**。

`log_host_memory.py` 用 `raw/host_mem.jsonl` 啟動；`20cd80b` 的配套 `mv` 把 `raw/` 搬成
`raw_block1/`（讓區塊 2 重用同一批標籤）。**fd 跟著 inode 走。**
六小時後：argv 指的路徑**已經不存在**，而它一直在往**區塊 1 的檔案**寫**區塊 2 的樣本**。

| 檢查 | 讀數 | 判定 |
|---|---|---|
| 行程活著嗎 | `ps` 有，etimes 21755 | ✅ 正常 |
| 檔案在長嗎 | 每 10 s 一行，2246 行 | ✅ 正常 |
| **argv 指的檔案存在嗎** | **不存在** | 🔴 沒人查 |
| **`readlink /proc/PID/fd/*`** | **`raw_block1/host_mem.jsonl`** | 🔴 沒人查 |

🔑 **判準（`開機手冊` 的說法比我準）**：同一天它被 `mininet/clean.py` 刪掉 `/tmp/t1.log`，
**那是同一個形狀但便宜得多**——
> **刪除留下一個洞（大聲）；改名留下一個假答案（安靜），而假答案比洞貴。**

洞會讓下一步報錯；假答案會被下一個人**當成真的讀**，而且檔名還替它背書。

⇒ **可操作**：長命的寫入者要**週期性斷言「我的 fd 還解析得到我被給的那個路徑」**，
不是只斷言「檔案打得開」。`readlink /proc/self/fd/N` 對比 argv，一行，六小時裡任何一次都會當場發現。
**「檔案在長」不是「檔案在對的地方長」。**

📌 這條和 [[replace-vs-add-bug-shape]] 的提問合起來用：
每個 ingest 問「舊資料什麼時候消失」，每個長命寫入者問「**我寫的還是我以為的那個檔嗎**」。

---

## 🆕 第八式（2026-08-31）：**「數出 0」的斷言，先證明它的輸入存在**

**懸案結案**：OvS 輪記著「htb 斷言兩次讀 0、**機制未定位**」。機制找到了——
**那條指令從未執行**。

```
$ sudo -n tc -s qdisc show ; echo $?     →  sudo: a password is required   /  rc=1
$ sudo -n tc -s qdisc show 2>/dev/null | grep -c htb   →  0
```
免密碼白名單**不含這條形式**（記憶裡「`tc` 免密碼」需要修正）⇒ stdout 全空
⇒ `grep -c htb` 忠實數出 0。**讀到的 0 不是「沒有 htb」，是「沒有輸出」。**

**它能活過兩輪（③ 08-28 與 OvS 08-30，31/31 raw 全是那一行）靠三件事疊加**：
1. **`2>&1` 把診斷訊息寫進了資料檔** ⇒ 檔案非空、看起來像有輸出；
2. **`grep -c` 對「空輸入」與「有輸入但無匹配」給同一個答案 `0`**；
3. **閘門只裝在 expect-0 那側**，**有訊息的那一側只有 echo**。
⇒ **一個從未執行的斷言，長得跟一個執行了並回報陰性的斷言一模一樣。**

🔑 **兩條可操作的**：
- **註冊一條斷言之前，先讓它對「已知為真」的情況成功一次**（本例＝先在有 htb 的 fabric
  上跑出非零計數，再寫進 prereg）。第二輪**重新註冊了同一條**而沒有先驗它能不能跑。
- **先斷言指令成功，再談內容**：`out=$(cmd 2>err) || die` ＋ `[ -n "$out" ] || die`，
  最後才 `grep -c`。**不要把 stderr 併進 stdout 之後再解析**。

相關：[[failures-that-report-success]]（兩種原因、同一個輸出）、
[[verify-the-purpose-not-the-mechanism]]（單側閘門）。

---

## 🆕 第九式（2026-08-31）：**修正案改了量測對象，沒有改服務它的裝置**

OvS 輪的 driver 有個 `warm_path()`——反應式控制平面要先暖機，否則第一條流自己付裝規則延遲。

```
warm_path() {  # reactive control plane: warm h1<->h33 before any measurement
  … ping -c 3 -W 2 10.0.0.33 …
```

而七臂 `arm.meta` 全部寫著量的是 **`host_pair=h1->h65`**。128 台佈局四分之一掛一台 leaf ⇒
**h33 在 s2、h65 在 s3**：暖機走 `h1→s1→spine→s2`，量測走 `h1→s1→spine→s9/s10→s7/s8→s3`。
**只有起點那一跳是共用的。**

`h33` 是 AMENDMENT-1 之前 `h1→h33` 設計的化石——**同一支 driver 的開機輪詢也還在等 h33**。

🔑 **與第六式的差別**：第六式是「你改到旁邊那份副本」。第九式是**你改對了主體，
但沒有一起改那些「為了服務主體而存在」的周邊步驟**——暖機、預熱、warm-up、
sanity ping、baseline 取樣，這些的參數是**跟著量測對象走的**，而修正案通常只改量測對象。

🔴 **而且每一個可讀的訊號都說它成功了**：`ping` 回 0、`warm_*.txt` 有內容、
沒有任何 stderr。**它不是失敗，它是成功地做了一件無關的事。**
（對比第八式＝從未執行；這一式＝執行了、成功了、打錯地方。與 LLDP 那次「netem 打在
不可能產生訊號的埠上」同族，但那次是位置選錯，這次是**位置曾經正確，然後修正案讓它過期**。）

⇒ **可操作**：**改動任何「量什麼／量哪裡」的參數時，grep 整支 harness 找同一個舊值。**
本例 `10.0.0.33` 在 driver 裡出現兩次（暖機＋開機輪詢），兩處都該跟著改。
更硬的版本：暖機的目標**不要寫成常數，從量測對象的變數推導**——
`ping "$DST"` 而不是 `ping 10.0.0.33`，這樣它結構上不可能過期。

## 🆕 第十式（08-31）：**注入成功了、檢查器也正確，但兩者看的不是同一個區域**

F-5 新增一道「嵌入的證據謄本是否過期」的檢查，force-red fixture 的做法是
**刪掉檔案裡第一個 `[ok]` 行**，讓謄本短少一列。但註冊裡有一行**散文**的 `[ok]`
（講錨定規則那段）**排在矩陣 block 之前**——刪掉的是檢查器**刻意不看**的那一行。
⇒ 檢查器仍數到全部 16 列 ⇒ **force-red 出來是綠的**。

🔑 **這一式跟前九式的差別**：前面那些是「注入沒發生」。**這次注入發生了、也成功了**
（那行真的被刪了，`diff` 看得到），**檢查器的邏輯也完全正確**。
**兩者各自都對，只是不重疊。** 所以「斷言注入生效」這條規矩**擋不住它**——
它的斷言會通過。

⇒ 可操作：**fixture 要斷言的不是「我改到了東西」，是「我改到的東西落在檢查器讀的那個區域裡」。**
最硬的版本是**兩邊共用同一個定位器**：檢查器數哪個範圍，fixture 就從同一個範圍挑受害者
（本例＝只刪 block 內的列），這樣結構上不可能錯開。
次佳版本＝force-red 之後**斷言計數真的變了**（16→15），而不是只斷言「檔案被改了」。

🔑 同輪還有兩式我已記在別處，但**三個缺陷全是「跑起來」才現形的，靜態讀都讀不出來**：
①閘門擋住自己的解法（加一列⇒謄本過期⇒拒跑⇒矩陣跑不了⇒謄本永遠無法重生，
＝**永遠變不回綠**，見 [[failures-that-report-success]]）；
②新檢查**吸收**了舊檢查（子跑沒帶旗標⇒新檢查先拒跑⇒`bracket force FAIL hit=0`，
＝[[mutation-gate-for-tests]] 四步判準的第三步「更早的檢查先中止」，第三次）。
⇒ [[live-runs-find-what-tests-cannot]] 的**工具版**：新裝的閘門，第一個該被測的是它自己。
