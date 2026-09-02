# 配對 A/B：那一階是不是那個常數造成的

2026-09-02，`9/1 mainDev`。12 格 × 300 s，P4/bmv2 128-host／288-edge fabric，**只有 nopoll 臂**。
[Co-developed with claude code -- Adam]

預註冊：[`PREREG.md`](PREREG.md)（四條預期在一筆資料存在之前寫死）。圖：`page_paired-ab.png`。
逐字輸出：`analyse_ab.out`。Dry run：`run_ab.dryrun.log`／`run_ab.dryrun.stdout`。
raw：`audit-raw` 分支 `5f37fb59`（74 檔，含作廢目錄；推上去後與本地 `raw/` 逐檔比對一致）。

---

## 頭條

**那 46 點是 `kFlowPathRecomputeInterval` 那一個常數造成的，而且它只在有樣本時才收費。**
兩顆 kernel 只差那一行：零取樣時差 0.74 點，1/1024 時差 45.01 點；六個配對的流量指紋完全相同。

| 取樣 | A 臂 1 Hz | B 臂 1 kHz | 差（B − A，配對） |
|---|---|---|---|
| **none** | 2.02（sd 0.04） | 2.76（sd 0.03） | **+0.74**（+0.80／+0.72／+0.71） |
| **1/1024** | 3.24（sd 0.05） | 48.24（sd 0.20） | **+45.01**（+45.20／+44.82／+45.00） |

（單位＝**一顆核心**的百分比，機器 14 顆。n=3，配對差在同一複本內取。本輪自己的噪聲地板＝最大格內 sd＝0.20 點。）

## 四條事前寫死的預期，逐條裁決

| | 預期 | 量到 | 裁決 |
|---|---|---|---|
| **P1** | 零取樣時兩臂差 ≤ 噪聲地板 0.7 | +0.74 | **未達標**（差 0.04；門檻不動） |
| **P2** | 1/1024 時 B 顯著高於 A | +45.01 | 成立 |
| **P3** | P2 的差 ≈ 46 點 | 45.01＝09-01 那 46.3 的 98% | 成立 |
| **P4** | A 臂沒有那一階 | A 臂 none→1/1024 只 +1.21；B 臂同一步 +45.48 | 成立 |

P2、P3、P4 三條把 09-01 的歸因釘死：**「有樣本才觸發」的那一階，其高度就是這個常數的高度**。
P1 是唯一沒過的——但三個複本 +0.80／+0.72／+0.71，格內 sd ≤ 0.04，這不是雜訊貼線，
是一個**穩定的 0.7 點**。它的意思寫在下一節；門檻按 PREREG 不動，裁決照寫「未達標」。

## 這一輪為什麼能歸因，而 09-01 不能

兩顆 binary：同一棵樹、同 commit（`4d831b58`）、同編譯器、同 `CMAKE_BUILD_TYPE=Debug`、同旗標，
**差 `revert-2f57ba5.patch` 那一行**。08-31 E 輪建的，其 provenance §9 明載從未跑過。
判別式（`sleep_for` 的樣板實例化）在兩顆上重跑，印出**兩種**答案；每格佈署後、**開量前一刻**
再讀一次正在跑的 `/proc/<pid>/exe`，不符即中止（12 格全部「matches」）。兩臂在時間上相鄰、
六個臂對三對 A 先三對 B 先。

⇒ **臂間差值可以歸因給那個常數。** 09-01 那輪的兩顆 binary 差十二天，不能。

## 事前讀出的機制，與資料對得上／對不上

`calFlowPathByQueried`（`FlowLinkUsageCollector.cpp:2764`）每圈：快照流表的 keys →
對每一個 key `getGraph()`（**by value**，`TopologyAndFlowMonitor.hpp:171`；同檔 `:186` 自述
"deep-copied the entire BGL graph"）→ ≤100 hop 的 classifier 查表 → `sleep_for(interval)`。

⇒ 成本 ≈ 每秒圈數 × **流數** ×（整圖深拷貝 ＋ 查表）。**流表由樣本填；零取樣 ⇒ 空表 ⇒ 零次拷貝
⇒ interval 無關。** 這是 PREREG §2 在量之前寫下的。

**對得上的部分**：那一階的 45 點在空表時整個消失（P2 對 P1：45.01 對 0.74），A 臂在 1/1024 只多
1.21 點——「每圈 × 流數 × 深拷貝」這個形狀是對的。

**對不上的部分**：「空表 ⇒ interval 無關」寫得太滿。空表時 1 kHz 仍比 1 Hz 貴 **0.74 點**，
三複本都在，比本輪噪聲地板高三倍以上。這是每秒一千次「醒來、鎖表、快照空的 key 集、`sleep_for`」的
**每圈本體成本**，跟流數無關。所以正確的分解是：**46 ≈ 0.7（每圈本體，固定）＋ 45（每圈 × 流數，只在
有樣本時存在）**。PREREG §2 漏了第一項，P1 因此差 0.04 沒過。

### 📌 產品碼裡的註解與資料牴觸

`FlowLinkUsageCollector.cpp:2979-2980` 與 `FlowLinkUsageCollector.hpp:40-41` 寫著那 46.31% 是
**"a fixed cost, not a per-sample one"**。資料說：**固定的部分只有 0.7 點；其餘 45 點在零取樣時不存在**。
更準的一句是「**per-flow-per-pass**，而流表在有樣本之前是空的」。⚠️ 產品碼，本輪不動。

## 對帳 ①：08-27 工單 M 的預註冊，六天前寫的、從沒被測過

`doc/audit/2026-08-27_1khz-path-recompute/PREREG.md` §M-5 寫死了
「**6-1：該執行緒 46.31% → <1%；總 kernel CPU 降 35–50 個百分點**」，§M-6 的判讀表寫著
「**CPU 沒大降 ⇒『46% 在這個迴圈』的歸因翻案**」。那一輪只留下 preflight 檔，**沒有 REPORT**。

本輪是那條預測第一次被測：**1/1024 時 1 Hz 臂比 1 kHz 臂低 45.0 點，落在 35–50 的帶子裡，6-1 成立；
歸因不翻案。**（本輪量的是整顆 kernel，不是那條執行緒的自身份額；「→ <1%」那半句沒有直接量到。）

🔴 **但本輪只測了 M-4 四個指標裡的 6-1。** M-4 把 **6-2（churn 下 `path` 非空比例）**標為
「**這才是真實代價**」，M-2 明寫「穩態工作負載會給出假綠燈」——**本輪就是穩態 iperf3**。
所以本輪對「1 Hz 有沒有讓短流失去路徑」**零發言權**。那一臂仍然沒人量過。

## 對帳 ②：09-01 那 46 點

09-01 量到兩輪在有取樣時差 46.3 點、零取樣時差 1.0 點，但兩顆 binary 差十二天，
只能寫成「兩輪之間的差」。**本輪把同樣的兩個數字在同一顆樹上重做出來：45.0 與 0.74。**
⇒ 09-01 那 46 點**可以**寫成「這個常數的代價」了；那 1.0 點也不是雜訊，是上面那 0.7 的每圈本體。

⚠️ 絕對高度**不並排**：09-01 量的是 `e3bad23c`，本輪兩顆是另外的。

## 守衛與對照

**守衛（PREREG §6，±5% tx）**：六個配對的 iperf3 封包數全部 **5,357,127**，聚合 tx 617.3–617.7 Mbit/s，
比值 1.000–1.001。沒有一對被丟。

**對照（不該隨臂動的東西）**，逐格：

| 格 | iperf3 | bmv2 | proxy | 整機 |
|---|---|---|---|---|
| zero 1 Hz r1／r2／r3 | 113.5／113.8／114.7 | 144.7／151.3／157.0 | 3.8／4.4／4.8 | 15.4／20.3／**38.0** |
| zero 1 kHz r1／r2／r3 | 113.7／113.5／113.7 | 146.9／143.0／144.5 | 3.8／4.2／4.9 | 17.4／15.6／15.3 |
| 1/1024 1 Hz r1／r2／r3 | 113.4／114.1／113.6 | 150.0／152.8／151.9 | 7.2／7.0／7.9 | 17.2／**26.3**／17.8 |
| 1/1024 1 kHz r1／r2／r3 | **140.1**／113.5／113.3 | 146.5／146.5／147.3 | 6.5／7.4／7.5 | 18.0／18.0／17.7 |

- **iperf3**：11 格在 113.3–114.7；**rep 1 的 1/1024 1 kHz 格是 140.1**，rep 2、3 同格 113.5／113.3
  ——**沒有重現**，是單格事件，成因不明。`analyse_ab.out` 對照表裡 1/1024 的 iperf3 delta +8.6
  全是這一格拉的。它沒有動到那格的 kernel 讀數（48.51，對 48.03／48.19）。
- **proxy** 隨取樣條件動（3.8–4.9 → 6.5–7.9），不隨臂動——proxy 處理樣本，這是預期。
- **bmv2** 143–157，1 Hz 臂略高（+4.8／+6.2），方向與 kernel 相反、且格內散布大，不影響歸因。
- **整機**：典型 15–18；三個 1 Hz 格是 20.3／26.3／38.0（zero r2、1/1024 r2、zero r3）——
  同一台機器上另有工作（worktree 當時有二十幾個未提交檔在動；不是 auditor，它在等 lab）。
  這三格的 kernel 讀數（2.01／3.21／2.08）與各自的兄弟格差 ≤ 0.1，**per-process 數字沒被帶動**。
  但這也說明本輪的 claim 沒有 `exclusive cpu`；下一次要量絕對高度時得要。

## 🔴 一次事故：兩支腳本同時在跑，rep1 的 s1024 臂對作廢重量

12:37 用 SIGTERM 在臂對邊界「停」腳本——**bash 跑完 trap handler 會從原處繼續**，第一版的 handler 沒有 `exit`。
舊實例還原完儀器後接著量了一格 fabric 已拆的死格、卡在 iperf3 的 wait；12:55 續跑的第二支實例把它放開，
舊實例 12:56 進下一格：拆掉新 fabric、把 1hz 臂 `cp` 進生產路徑、自己再 bringup；兩支的 `measure.sh` 同時
append 同一組 raw（`cpu.jsonl` 是正常的 2–3 倍大）。12:57 靠 `pstree` 看到兩棵樹，逐 PID 驗 `/proc/*/cmdline` 後 SIGKILL。

- 作廢的兩格在 `raw/void_2026-09-02_1237-1257_two-scripts-raced/`（**不刪**：它們是「標籤是錯的」的證據；已一併推上 `audit-raw`）。
- rep1 zero 臂對（12:24–12:36）在事故前寫完、之後沒被碰過，保留。
- 腳本修四處（`fc9ef81a`，每處先看過紅再看過綠）：handler 還原後 `exit`；`flock` 單實例鎖在 trap 綁定前；
  **開量前一刻**讀 `/proc/<pid>/exe` 驗正在跑的 kernel（先不提權再 `sudo -n`，先驗 64-hex）；`measure.sh` 失敗即 FATAL。
- 13:06 續跑（單實例 pid 213247），rep1 s1024 重量；之後 10 格一路到 14:09 沒有再出事。全文 `PREREG.md` §3c。

## Dry run 抓到的兩件事（正輪開跑前修好）

| | 機制 | 修法 |
|---|---|---|
| 🔴 **還原沒有還原** | `cp` 蓋不過**正在被執行**的檔（ETXTBSY，`run_ab.dryrun.stdout` 有那一行），而最後一格量完 stack 還活著 ⇒ 生產路徑留著實驗臂、kernel 還在跑它。**sha 檢查抓到了** | 先 `stack.sh down`、讀 `cp` 的 rc |
| 🔴 **只還原 `.p4` 等於沒還原** | fabric 載的是**編譯產物**（`p4_testbed_topo.py:357`），源碼還原了但 json 還是舊的 ⇒ 之後每一輪遙測無聲變成別的取樣率 | 還原後重編，驗產物裡 `0xff` 不是 `0x3ff` |

第二條**不是本輪特有**：任何 sed 過 `.p4` 又只還原源碼的腳本都有。

## 儀器：控制驗證器的四格真值表都跑過

| mode | fabric 在取樣 | fabric 不取樣 |
|---|---|---|
| `zero` | **紅**（rc 6，11:40 手跑） | **綠**（dry run ×2，正輪 ×6） |
| `sampled` | **綠**（11:39 手跑，正輪 ×6） | **紅**（dry run 的陰性對照） |

只會出一種顏色的檢查不是檢查。兩個 mode 都要求「介面上確實有 byte 在動」——
沒有那一半，「twin 讀零」會被無流量／iperf 掛掉／kernel 不回應滿足。

## 🔴 這一輪不是什麼

1. **不是今天的 HEAD**：這一對停在 08-31 `4d831b58`，不含 09-01 的 B-2①／E-2。nopoll 構不到 E-2，
   但「本輪數字＝HEAD 的數字」不成立。
2. **不是 release 的數字**：`Debug`／`-O0`，三輪皆然。
3. **不是保真度的證據**：見對帳 ①。
4. **不是 1/1024 以下的形狀**：0 → 34.7 樣本/s 之間仍然只釘住兩端。
5. **不是 exclusive-CPU 下的絕對高度**：見對照的「整機」那列。

## 儀器歸位

腳本自動還原（`run_ab.log` 14:09:33–34）：

```
[14:09:33]   SAMPLE_RATE restored to 256
[14:09:34]   p4 recompiled from the restored source
[14:09:34]   production kernel restored, sha256 verified
[14:09:34]   predicate now: random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);
[14:09:34]   SAMPLE_RATE  : SAMPLE_RATE = 256;
[14:09:34]   kernel now   : e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94
[14:09:34]   fabric is left DOWN; 'ndt up' brings it back on the production binary.
```

腳本之外獨立驗過（14:10）：`sha256sum build/bin/ndtwin_kernel` ＝ `e3bad23c…`；
`ndtwin_switch.p4` 對 committed 內容無 diff（`git status` 空）；`build/ndtwin_switch.json` 裡 `"0xff"`×4、`"0x3ff"`×0，
且 json 比 `.p4` 新；`flock` 鎖已放；沒有 `ndtwin_kernel`／`p4_proxy`／`iperf3` 行程。

🔴 **「fabric is left DOWN」只對了一半**：`stack.sh down` 停的是 kernel 與 proxy，**10 台 bmv2 與 Mininet 還在**
（`ndt status` 顯示 bmv2 switches 10、host/switch 138）。依交接約定補跑 `ndt down`（rc 0）＋ `ndt clean`
（bmv2 0、host/switch 0、無 topo session、8000/8080/8081 關閉），寫 `.test_run/lab.handoff`，
**14:11:52 `ndt release`**；auditor 隨即 claim（至 16:43）。下一版 `restore_all` 應改呼叫 `ndt down` 而不是 `stack.sh down`。

## 下一步（給 Adam 裁）

1. **把 1 Hz 臂變成生產值**：這一輪已經證明 45 點是那個常數、而且 1 Hz 在穩態下沒有那一階。
   但 08-27 M-4 6-2（churn 下 `path` 非空比例）沒人量過——**改常數前先量它**，不然是拿保真度換 CPU 而不自知。
2. **改掉產品碼的兩句註解**（`FlowLinkUsageCollector.cpp:2979`／`.hpp:40`）：「fixed cost」→
   「per-flow-per-pass；空表時每圈本體約 0.7 點」。
3. **`restore_all` 改用 `ndt down`**，並把「fabric is left DOWN」那行改成事實。
4. 0 → 1/1024 之間的形狀（1/4096、1/16384）仍然空著；有了這一對 binary，補這些格子只要換 `SAMPLE_RATE`。
5. iperf3 那個 140.1 單格事件：不追（沒重現、沒動 kernel 讀數），但記在 KNOWN-ISSUES 的雜項。
