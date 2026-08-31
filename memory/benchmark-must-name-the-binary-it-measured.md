---
name: benchmark-must-name-the-binary-it-measured
description: 同一個 A/B 對照連續兩次給出錯的答案——一次是 Debug 對 Release、一次是量到了不是我以為的那個 process;兩次的數字都看起來很合理
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-31T12:39:52.811Z
---

2026-08-19,量「現行 kernel 的讀取路徑有沒有比 baseline `28b8b13` 慢」。
**同一個對照連續兩次給出錯的答案,而且兩次的數字都合理到不會引起懷疑。**

## 第一次錯:build type 就是全部的差距

第一輪量出 **`get_graph_data` 現行慢 5.5×**(11.99 ms 對 2.18 ms)。看起來像個大回歸,
而且**方向也符合預期**(我們動最重的就是那條路徑:`FlowLinkUsageCollector.cpp` +442/−168、
`TopologyAndFlowMonitor.cpp` +454/−96、`HttpSession.cpp` +329/−234)。

實際原因:**主樹是 `CMAKE_BUILD_TYPE=Debug`,而我把 baseline worktree 建成了 `Release`。**
把 baseline 改建成 Debug 之後,**結論整個反過來**:13.02 ms 對 11.99 ms,**現行沒有變慢**。

🔑 **符合預期的結果最不會被查。** 我當時已經準備好一個因果故事(「改最多的路徑最慢」),
那個故事讓數字看起來自洽。查 `CMakeCache.txt` 只要一行指令。

## 第二次錯:量到的不是我以為的那個 process

重建成 Debug 之後起來量,得到 2.33 ms——**又是一個合理的數字**。
實際上新 kernel **已經 abort 了**(`bind: Address already in use`,舊的還佔著 sFlow 的
UDP 6343),而**舊的 Release kernel 繼續在服務 `:8000`**,所以我量到的是它。

會發現只是因為 abort 訊息和量測輸出剛好印在同一段。**如果分兩次跑就完全看不出來。**

🔑 **延遲量測必須指認自己量的是哪一個 process**:
```
ss -lptn 'sport = :8000'          # → users:(("ndtwin_kernel",pid=N,...))
ls -l /proc/N/exe                 # → 哪一顆 binary
```
這已寫進 `doc/audit/2026-08-19_api-latency-vs-baseline/REPORT.md` 的程序。
連帶:`kill $!` 殺到的是 shell 記的 job pid,**不一定是真正在聽 port 的那個 process**。

## 順手學到的:baseline 其實很好建

`28b8b13` 只有 17 個 `.cpp`,機器有 ccache ＋ 14 核心,**建置幾分鐘**。
兩個看起來會擋路的東西實際上都不擋:
- 它**不能用現在的 GCC 編**(`-Werror=unused-result`,忽略 `system()` 回傳值),
  但 `CMakeLists.txt:53` 拿掉 `-Werror` 就過,**不影響 codegen**。
  ⚠️ `-DCMAKE_CXX_FLAGS="-Wno-error"` **無效**,因為 CMakeLists 在後面才 append `-Werror`。
- 它沒有 headless 旗標,但 `main.cpp` 裡 9 個 `std::cin` **只有 2 個是真提問**
  (其餘是重試迴圈的 `clear`/`ignore`),`printf '1\n2\n' |` 就能起(1=Mininet、2=不用 AI)。
  而且它的 `TOPOLOGY_FILE_MININET` 與現行**指向同一個 JSON**,所以沒有「安靜載入錯拓撲」的風險
  ——**但量測腳本仍然應該先斷言拓撲**(`api_latency.py` 會印 nodes/switches/edges)。

**所以「要建 baseline 才能比」不該再被當成不做對照的理由。**
相關:[[arithmetic-that-fits-is-not-the-mechanism]]、[[reproducible-is-not-mechanism]]。

---

## 2026-08-20：怎麼「指認」，以及 28b8b13 的建置配方

**指認的方法（這次用的）**：cpu trace 裡本來就有每個行程的 `name:pid`，所以**事後可以從資料本身證明量到誰**——
`ovsjit_head` 的 trace 只含 `kernel:1166963`（ndt 起動時 log 的 pid），`ovsjit_base` 只含 `kernel:1169447`。
比「我記得我跑的是哪個」強，因為它寫在資料裡，事後任何人都能複查。
`ndt status` / `ndt up` 也會直接印 `running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc`。

**baseline `28b8b13` 建置配方（實測，約 3.5 分鐘）：**
```
git worktree add --detach <dir> 28b8b13
cp setting/AppConfig.hpp.example setting/AppConfig.hpp     # 不用改，預設就對
sed -i 's/^    -Werror -pthread/    -Wno-error -pthread/' CMakeLists.txt
cmake -S <dir> -B <dir>/build -DCMAKE_BUILD_TYPE=Release -G Ninja && cmake --build <dir>/build -j 10
( cd <dir>/build && printf '1\n2\n' | ./bin/ndtwin_kernel )    # 1=Local Mininet, 2=no AI
```
- **`-Werror` 必須放寬**：2026-04 的碼配今天的 GCC 會卡 `system()` 的 `warn_unused_result` 和 Boost 的 `maybe-uninitialized`。**只改警告是否致命，不改產生的程式碼**，所以 A/B 仍然有效——但報告要寫出來。
- **沒有 CLI flag，用 `std::cin` 提示兩次**（環境、AI），所以要餵 stdin。
- `AppConfig.hpp` 的 `TOPOLOGY_FILE_MININET` 預設指向 `StaticNetworkTopologyMininet_10Switches.json`，而**那個檔在 28b8b13 和 HEAD 之間逐位元組相同**（128 hosts / 288 edges）——所以 OVS 128-host 的跨版本 A/B 沒有拓樸混淆。
- 相依（libssh / OpenSSL / Boost 1.83 / C++23）與 HEAD 相同，機器上都有。原始碼只有 **2.9 MB / 182 檔**。

---

## 🔴 2026-08-26：**原始碼與磁碟上的 binary 現在是刻意不一致的**（會安靜咬人）

迴圈週期的儀器（`FlowLinkUsageCollector.cpp` 每 30 輪記一次 period）**已經放回原始碼，但刻意
沒有重建**，所以磁碟上的 `build/bin/ndtwin_kernel` 仍然是**未加儀器**的
`3367d0e9ed22db84ba8a66ef61d74b3f56571e2d60ef94ccd40742a969ebdb27`。

⚠️ **任何人只要跑一次 `cmake --build build`，binary 就會無聲換成 `5b30e448`**，
而**沒有任何東西會告訴你**——`ndt status` 印的是路徑不是 hash，量測腳本若只記路徑就完全看不見。

**做法**：任何跨 run 的比較都要**記 binary 的 sha256、不是路徑**。
`gate_e.sh` 做對了（兩臂各印一次 `kernel sha256(on disk)`，事後可複查兩臂同一顆）。

🔑 **這一條之所以重要，是因為 08-25 有半天的時間，一個「儀器改變了量測」的假說活著**
（頭條從 1.18 變 0.92）。最後證明**儀器是無辜的**（同 fabric 換 binary 只動 0.18%），
真兇是**讀錯欄位**（`per-edge min` 被當成 `ratio`）。但在那半天裡，
「磁碟上到底是哪顆」是唯一能把假說釘死的東西——**而它只能靠 hash，不能靠記憶**。

相關：[[verify-against-known-good-output]]（拿現在的分析器重跑舊資料當已知輸出對帳，
就是這樣抓到讀錯欄位的，零成本）。

## 🔑 08-27：**指認的形式是 `/proc/<pid>/exe` 的 sha256，不是路徑**

```bash
sha256sum /proc/$(pgrep -x ndtwin_kernel)/exe
```

**路徑不是位元組。** 任何 `cmake --build` 都會無聲換掉路徑底下那顆，
而 `ndt status` 只印路徑不印 hash。

實例：`3367d0e9…`（①與 P 的可比性基礎）→ `ab2d7ed1…`（工單 Q 的儀器版）。
🔴 **要保留可比性基礎，備份要放在 `build/` 外面**——`make clean` 或砍掉 `build/` 會帶走放在裡面的。
（`.test_run/binaries/ndtwin_kernel.3367d0e9`。驗證含不含儀器用 `strings`：舊 0 命中、新 3 命中。）

## ✅ 換 kernel **不必**重起 fabric（08-27 實測）——這解鎖了交替設計

`doc/audit/2026-08-25_large-scale-concurrent/restart_kernel.sh`（工單 D arm U 寫的）：
按**精確 pid** 殺舊的、起新的、用 `/proc/<pid>/exe` 的 sha256 驗身分、
並擋 `:8000` 被別人佔住（**否則舊答案繼續被服務，讀起來就像重啟成功**）。

實測：bmv2／proxy／mininet 全部存活，twin **5 秒**重新收斂
（`edges=288 down=0 ipv4=128`，`Pulled 16256 paths`）。**重建只吃 69 MB。**

🔴 **但它沒檢查路徑數**（`16256 = 128 × 127`）。`down==0 && ipv4==128` 看不到
[[destination-paths-not-monotonic]] 那個「抓在低谷 ⇒ 路徑集合永久殘缺且無 log」。

🔑 **為什麼這件事重要**：A/B 的兩顆 binary 可以在**同一代 fabric 內交替**
（`B A B A`，不是 `B B A A`）⇒ **「哪一顆 binary」變成處理變項，而不是跟「發生過一次重建」綁在一起**
⇒ 世代漂移與處理正交，**而且不需要知道世代效應的機制**（我們到現在還沒指認它）。
相關：[[replication-unit-not-the-rep]]（每格至少兩臂）

## 🔴 2026-08-28 推廣：**同一條規則適用於「原始碼宣稱」，不只是量測**

一天之內，「baseline 的死流速率會不會保留」被講成**三個互相矛盾的版本**，
三個 session 各對一部分，而**沒有一次的分歧是關於行為的**——全部是關於「baseline 指哪個 commit」：

| 講「baseline」時指的 | 行為 |
|---|---|
| `28b8b13`（fork point） | `continue`，**保留** |
| `origin/main`（今天的公開版，只領先 fork point **2 個 commit**） | **明文清除**（改它的是 `8b61cdc "Add sharding"`，標題完全看不出來） |
| `3367d0e9`（實驗 base 臂**實際跑的 binary**） | **沒有人查** |

⇒ **兩個「矛盾」的宣稱其實都對，因為它們在講不同的 commit。**
而**實驗真正依賴的那一個，三個人都沒問。**

> **凡是宣稱「baseline 如何」，都必須指名 commit。不指名的一律作廢，不管它說什麼。**
> **「上游」「公開版」「原本的」「baseline」——這四個詞在這個專案裡都不是識別碼。**

🔑 **我犯的那一版最值得記**：我讀了 `28b8b13`，發現與別人的說法衝突，就發訊息指控對方錯，
並且特地寫「**我自己去讀了原始碼**」當權威來源。**原始碼讀對了，問題問錯了。**
⇒ **「我親自驗證過」只在「我驗證的對象 ＝ 對方講的對象」時才是權威。**
驗證前要先對齊識別碼，否則親自驗證只是把一個錯誤講得更有信心。

相關：[[cited-line-numbers-are-not-evidence]]、[[fresh-grep-before-confirmed-quote]]

## 🔴 2026-08-28 下一層：**sha256 識別的是位元組，不是來源**

追一個實驗結果時我想知道 base 臂那顆 binary 是哪個 commit 建的。**查不到，而查不到是個發現：**

```
binary 內嵌的 40-hex   961c151d…   git cat-file 說不是 git 物件
ELF BuildID            d8ae7ac4…   建置產物，與原始碼無關
doc/ 裡記了 3367d0e9 的 6+ 個檔案  全部只記 sha256，沒有一個記 commit
```

⇒ **六個實驗量過這顆 binary，沒有任何紀錄能把它接回原始碼。**
我們對**位元組**極度嚴謹（到處 sha256、拿 `/proc/<pid>/exe` 驗跑著的那顆），
對**它是哪份原始碼**完全沉默——而問題一旦變成「baseline 有沒有那個修正」，就只能停在這裡。

⚠️ **不要用 mtime 推**：binary 的 mtime 是複製／建置時間，不是 commit 時間，兩者可以差很多。

**修法（已建議給 mainDev）**：建置臂用的 binary 時一併寫
`.test_run/binaries/<sha>.provenance`，內容至少 `git rev-parse HEAD` ＋ `git status --porcelain`。
🔑 **「有沒有未 commit 的改動」和 commit 本身一樣重要**——
**從髒工作區建出來的 binary，連 commit 都不足以識別它。**

## 📌 我追這件事時踩的坑：**二分判準遇到第三種情況**

```bash
git merge-base --is-ancestor aabe605 961c151d && echo "有修正" || echo "沒有修正"
```
印出「**沒有修正**」，而真正的原因是 **`961c151d` 根本不是 git 物件**——
指令是因為**第三個理由**失敗的，`||` 把它折進「沒有修正」。

⇒ 與 [[controls-decide-what-you-learn]]「判準要留『以上皆非』」、
[[failures-that-report-success]]「`cmd && A || B` 一族」是同一條。
**`&&`/`||` 只有兩個出口，而失敗的理由永遠多於一個。**

## 🔴 2026-08-28 再一層：**上面那張表混了兩種識別碼，而第三列根本不是 commit**

那張「baseline 指哪個 commit」的表被轉述給我時，我照規則去查第三列——**查不到**：

```
git cat-file -t 3367d0e9      # NDTwin-Kernel        → fatal: Not a valid object name
git log --all | grep 3367d0e  # 所有 ref + reflog     → 空
# 另外 8 個兄弟 repo 逐一 git cat-file -t 3367d0e9    → 全部 fail
```

⇒ **`3367d0e9` 在九個 repo 裡都不是 git 物件。** 而本檔前面早就記著答案：
它是**磁碟上那顆 binary 的 sha256 前綴**（`3367d0e9ed22db84ba8a66ef61d74b3f56571e2d…`）。

🔑 **所以那張表的三列是：兩個 commit ＋ 一個 binary hash，放在同一個標著「commit」的欄位裡。**
「沒有人查第三列」的真正原因不是懶——**是它不能用查 commit 的方式查**，
而欄位名稱讓每個看到它的人（包括我）都以為可以。

⇒ **規則要再收緊一格：指名識別碼時，連「這是哪一種識別碼」也要講。**
`commit` / `binary sha256` / `ELF BuildID` / binary 內嵌的 40-hex 在這個專案裡**全都出現過**，
四種都長得像 hex 前綴，而**只有第一種能用 `git` 查**。
本檔「sha256 識別的是位元組，不是來源」那節講的是同一件事的另一面：
**位元組 → 原始碼**這個方向斷了；這一節是**有人把位元組當成原始碼在引用**。

## ✅ 同一天的正面實例：規則有效，而且是它救的

同一輪 baseline 架構漂移稽核（[[baseline-drift-audit-2026-08-28]]），我在報告開頭
逐字寫了 `28b8b13`（fork point）→ `b024354`（HEAD）。auditor 明說**那個習慣正是
為什麼那份報告沒掉進這個坑**——同一天有三個 session 在同一個詞上互相矛盾。

⇒ 這條規則的成本是**一行**，收益是整份報告的可對帳性。沒有理由省。

## 🔴🔴 2026-08-28：**我查了 PATH 上的 binary，而 fabric 跑的是另一顆**

Adam 問「bmv2 為什麼只能打到 0.47 Gbps」。我查 `strings /usr/local/bin/simple_switch`，
看到 elogger 符號 25 個，宣布「**我們裝的是 p4-guide 的除錯 build，沒有效能參數**」。

**錯。** 這台機器上有**兩顆** build，而 fabric 跑的是第二顆：

```
/usr/local/bin/simple_switch_grpc          9.2M   elog 符號 25   ← 我查的（PATH）
/usr/local/bmv2-fast/bin/simple_switch_grpc  88M   elog 符號  5   ← 實際在跑的
```

🔑 **我查了路徑，沒查正在跑的行程**——**本檔的核心規則，我自己違反。**
`ps -o args=` 一行就看得到，我沒跑。

## 而那個「應該做的實驗」**兩週前就做完了**

`doc/2026-08-15_bmv2-performance-report.md`：

| | stock（-O0＋logging） | **bmv2-fast（-O3、無 logging）** | 倍率 |
|---|---|---|---|
| UDP delivered 天花板 | ~40–42 Mbps | **~460–530 Mbps** | **12–13×** |
| TCP 單流 | 24.2 Mbps | 431.0 Mbps | **17.8×** |
| 64B 小包 | 3,619 pps | 50,786 pps | **14×** |

⇒ 我提議「照 p4lang 參數重編再量」——**已經有人做過，而且結論寫在 repo 裡。**
⇒ 🔴 **這同時是 [[check-against-prior-experiments]] 的失敗**：我自己定的規矩是
「每次實驗都要查推翻／更新／可對比哪個舊結果」，**而我在回答一個效能問題時沒有去查效能報告。**

## ✅ 但今天的量測本身是對的，而且被獨立佐證

`mainDev` 今天量到 **430–500 Mbit/s**，08-15 那輪量到 **fast build 460–530 Mbps**。
**兩週、不同人、不同 harness ⇒ 同一區間。**
⇒ **0.47 Gbps 是 fast build 的真實天花板，不是「build 沒調好」。** 若跑的是 stock 會是 ~0.04。

## 📌 那份報告裡兩件之後會用到的

1. **天花板是 pps 不是 bps**：stock 在 1400B 下 ~3.66k pps，64B 實測 3.62k pps ⇒ **與包長無關**。
   「多少 Mbps」是「pps × 包長」的假象。
2. **文獻值（170 Mbps，Chen/Hu/Jin SIGSIM-PADS '23）不描述本機任一顆 build**——
   stock 低 4×、fast 高 ~3×，而論文沒載明 build 條件。
   ⇒ **拿論文數字當我們的預期值是錯的。**

🔴 **而 08-28 下午還學到一件更收緊的**：**容量是流數的函數。**
單流 430–500 Mbit，**16 條流合計只有 ~48 Mbit**（瓶頸是每封包 CPU，每條流帶自己的查表成本）。
⇒ **工作點與容量不只要同單位，還要在同一個流數下量。**

## 🆕 08-28：**mtime 可以比它所屬的 commit 更早，所以連方向都不能推**

三顆停在 `.test_run/binaries/` 的 kernel，`.provenance` 分得出 Q（`f5e3556`）卻**分不出 M**
（`a40e04ce` 與 `ab2d7ed1` 對 Q 的儀器都答 yes，而 `2f57ba5` 的訊息說它產出「第三顆 binary」
⇒ 那個檔把三顆分成了兩類）。用符號定案：

```
nm -C <binary> | grep kFlowPathRecomputeInterval
  a40e04ce -> 5      ab2d7ed1 -> 0      3367d0e9 -> 0
```

`3367d0e9` 對 Q 和 M 都答 no ＝ **陰性對照**；沒有它，「有」與「grep 壞了」分不開。

🔴 **而 mtime 指向相反的答案**：`a40e04ce` mtime **22:21:46**，commit `2f57ba5` **22:22:12**
——**binary 比描述它的 commit 早 26 秒**，因為它是在 commit 之前從工作區編出來的。
照 mtime 讀，會把 M 的 binary 排在 M 存在之前。

⇒ 既有的「mtime 不是 provenance」要再加一句：
**連「至少建於 X 之後」這種單向的下界也推不出來**，因為工作區永遠可以先於 commit。
**能用的只有 binary 自己帶的簽名 ＋ 一個該答 no 的陰性對照。**

## 🔴 2026-08-28 晚：**指名 binary 還不夠——同一顆 binary 可以給相反的答案**

```
.plotvenv/bin/python3   →  symlink 到  /home/adam/miniconda3/bin/python3.13   matplotlib 3.11.1
miniconda3/bin/python3  →  同一顆 binary                                      matplotlib 3.10.8
```

**同一個 inode，兩個 `site-packages`，對「有沒有裝 matplotlib」給相反答案。**
決定答案的是 `sys.path`，而那是**環境**給的，不是 binary 給的。
⇒ 🔑 **「我跑的是哪一顆 binary」和「那次執行看得到什麼」是兩個問題。**
本檔前面那條（指名 commit／指名 binary）**必要但不充分**，要連環境一起指名。

### 而版本差異不是裝飾性的，是實測的

```
                              3.11.1    3.10.8    下緣留白差
page_bandwidth-ceiling.png     27 px     45 px      18 px
page_M_cost-and-benefit.png    65 px     79 px      14 px      （PNG 雜湊也不同）
```

🔴 **最刺的一格**：`54551bc` 修掉的那個「圖被下緣切掉」缺陷——
```
pre-fix on 3.11.1: 下緣  0 px  末列墨水 0.1411   ← 被切
pre-fix on 3.10.8: 下緣 11 px  末列墨水 0.0000   ← 看起來好好的
```
⇒ **在錯的版本上，缺陷根本不重現。** 拿 3.10.8 去複驗的人會得到
「本來就沒壞、這修正沒必要」，**而他每一步都做對了**。

### 修法：預設拒絕，不是警告

`plot_deck_903_round2.py` 現在版本不符就 `sys.exit`，印出 want／got／`sys.executable`／該用的路徑
（`e76d5c4`）。逃生門 `DECK_ALLOW_MPL_MISMATCH=1` 留著（`.plotvenv` 是單點故障），
**但走它必須是個決定不是預設**。四關驗過含**看著它失敗**（錯版本 exit 1、寫出 0 張圖）。

🔑 **通則**：當「複驗會不會重現」取決於工具版本時，**工具版本就是實驗條件的一部分**，
要像釘 commit 一樣釘住它——而且**釘的方式要能在走錯時大聲失敗**，
因為這一族的失效是靜默的：你會拿到一張圖、一個數字、一個「驗過了」。

## 🔴 2026-08-28 夜：**「12–18×」不是一個信賴區間，是跨指標的範圍**

規劃工單①（把 12–18× 拿到單一 switch 上隔離複驗）時才發現：
`doc/2026-08-15_bmv2-performance-report.md` 的那個範圍，兩端是**不同的量**。

| 量 | stock | bmv2-fast | 倍率 |
|---|---|---|---|
| UDP 零損點（1400 B） | 25 Mbps | 300 Mbps | **12×** |
| UDP delivered 天花板 | ~40–42 | ~460–530 | ~12–13× |
| 64 B 小包 delivered | 3,619 pps | 50,786 pps | **14×** |
| TCP 單流 goodput | 24.2 | 431.0 | **17.8×** |
| TCP 8 平行流 | 24.2 | 435.7 | **18×** |
| 閒置 RTT | 9.1 ms | 2.8 ms | 3.3× |

⇒ **12 到 18 的距離是「UDP 容量」與「TCP goodput」的距離，不是量測噪聲。**
（而且同一張表裡還有一個 **3.3×**，它從來沒被算進「12–18」這個講法。）

🔴 **後果**：拿一個隔離複驗的結果去對「12–18×」這個範圍，**幾乎什麼數字都會「吻合」**
——範圍寬到失去否證力，而它寬的原因是**混了指標**，不是因為我們對它的不確定性有那麼大。

⇒ **①的註冊決定：只量 UDP 零損點、只對 12× 比。** 那也正好是 P1-3 的階梯在量的同一個量，
所以兩輪可以互相對帳。**其他各列明文排除在對帳之外。**

## 🔴 2026-08-29：**這條規則我又違反了，而且是被別人的一句問話戳破的**

chaos harness 首次 live 跑完（九輪、四個對照）之後，`8/29 poster-reviewer` 問了一句：
**「這 fabric 是 stock 還是 fast？」**

**`raw/` 裡沒有任何一個產出答得出來。**

| 我以為我有的 | 實際 |
|---|---|
| `ndt status` 說 `bmv2-fast` | 只寫在交接訊息裡，**沒進 JSON** |
| argv 說 `bmv2-fast` | 只在 transcript 裡 |
| pre-state 快照 | 🔴 **我自己的 `awk` 把路徑洗掉了**，只剩 `3436314 255`（一個 pid ＋ 一個 port） |
| 事後去問行程 | 🔴 **fabric 13:55 已被重建**（我 13:47 release 後 poster-reviewer 接手重建兩次），那批 pid 全沒了 |

⇒ **證據只活在 session transcript 裡** ＝ [[evidence-must-outlive-the-handoff]] 的正字標記。
誠實的講法只能是：**我確信那輪跑在 `bmv2-fast`，但我無法從 committed raw 證明它。**
（兩顆確實是不同檔案：fast `3ff54b5c…` / stock `327fa7d1…`。）

**修法**：`probes.bmv2_provenance()` 進**每一份**報告，含 `--dry-run`——執行中的路徑＋數量、
每個的 sha256、override 檔宣告什麼，以及大聲的 `MIXED_BUILD` / `OVERRIDE_MISMATCH` /
`OVERRIDE_UNREADABLE`。**並在 payload 裡自報強度**：`/proc/<pid>/exe` 這個 uid 讀不到
⇒ argv 交叉比對 override 檔（同工單①的妥協），**sha 釘的是「那個路徑現在指的檔」，
不是「跑著的行程當初 map 的映像」**。

🔑 **而替它寫的 mutation test 當場又抓到它自己的缺陷**：從 `harness/` 跑時
override 比對 `open()` 一個 **cwd 相對路徑**、失敗、**整個比對被跳過**
⇒ 檢查無聲變成沒檢查，**而且只對照「用正常方式跑它」的人失效**。
已改成從 `__file__` 往上走，找不到就丟大聲的 key 而不是長得像「相符」。
（＝[[harness-cd-hides-working-directory-defects]]＋[[mutation-gate-for-tests]]「沒看過它失敗就不算交付」。）

⚠️ **最該記的是觸發點**：不是我自己複查發現的，是**別人問了一個一句話的問題**。
⇒ **「我的產出能不能回答一個外人的基本提問」是比自我複查更便宜、更有效的稽核。**

🔑 **可轉移**：引用一個「X–Y 倍」的範圍之前，先問**兩個端點是不是同一個量**。
若不是，它是一張表被壓成一個數字，**而壓縮掉的正是「它在講哪一件事」**。
與本檔「指名識別碼時連『這是哪一種識別碼』也要講」同構：**指名倍率時要講它是哪個量的倍率。**

## 🆕 08-30：拓撲檔版本——patch 打在 runner 不讀的副本上（第三擊）

OvS 對照輪要「拿掉 shaping」：我 sed 了 **kernel repo 的** `testbed_topo.py`，配了 py_compile
＋diff＋前後 sha256 三重斷言——**全部打在檔案上，沒有一個打在 fabric 上**。實跑的是
**NTG repo 的**同名檔（`/usr/local/sbin/ndtwin-lab:83` 寫得明明白白）⇒ patch＝no-op，
六支「unshaped」臂全程 1 G-shaped，錯誤歸因（veth→htb）一路傳染到 poster 落稿句，
在最終驗收才被 driver log 裡一行反常（htb=0 該 >0）拉出來。

🔑 **同構於「PATH 上那顆不是 fabric 跑的」**：改動（或指認）一個 artifact 之前，先讓
**執行鏈自己說出它讀哪個路徑**（grep 啟動器，不是 grep repo）。「repo 裡的那份」與
「runner 跑的那份」是兩個宣稱。
🔑 fabric 級斷言其實有——`tc | grep -c htb`——但 expect-0 側有 die-gate、expect->0 側
只有 echo：**有訊息的那一側沒有 gate**，而且讀數本身假陰性（機制待釘）。斷言要打在
「操縱的對象」上，且兩個方向都要有牙齒。

## 🆕 08-30 夜：**指名 binary 還不夠——它載入的函式庫由 `RUNPATH` 決定，而不是由你設的環境變數**

安裝手冊 §6.7 警告：兩個 build 的 soname 相同，**不設 `LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib` 就會靜靜載到 debug 的函式庫，於是你 benchmark 的是混合物**。

乾淨室實測，**危險條件全部成立**（soname 相同、debug 的 `/usr/local/lib` 在 ldconfig 快取裡、fast 依手冊指示沒跑 `ldconfig` 所以不在快取）：

| | bmv2 自己的函式庫解析到 fast 前綴以外的數量 |
|---|---|
| 有設 `LD_LIBRARY_PATH` | **0** |
| **沒設** | **0** |

原因：`readelf -d` → `RUNPATH: [/usr/local/bmv2-fast/lib]`，而 **loader 搜 `DT_RUNPATH` 早於快取**。

🔑 **保護來自 build 的性質，不是操作者的紀律**——而手冊歸給了操作者。兩個方向都有害：
① 忘了設變數的人被告知自己在量混合物（**其實沒有**），可能因此丟掉好數字；
② 哪天 build 掉了 rpath（`--disable-rpath`、換 distro 打包），這條建議**無聲變成命脈**，而沒有任何東西會宣告這個變化。

⇒ **本檔的規則要補一句**：指名 commit 與識別碼之後，還要問「**它實際載入的是哪幾個 .so**」。`ldd` 就答得出來（跑的是同一套 loader 解析），不需要活的行程；`readelf -d` 看得到 rpath。⚠️ 手冊自己指定的驗證法 `/proc/<pid>/maps` **需要活的 switch ⇒ 需要 fabric**，所以在 §6.7 那個位置根本做不到。
正本：`doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-section6.7-fast-build.md`。

## 🔴 08-30 夜：量測窗要「擁有那個檔案」，不只是擁有 fabric

TR-5 兩臂之間，別的 session 在 **22:32:22** 重編了 `build/bin/ndtwin_kernel`
（`66f437a5` → `4e7afe2d`，含 T-11-A `91e7743`）。我的 OVS 臂 kernel 在 **22:32:13** exec——
**差九秒**。結論沒錯（兩臂都跑舊 binary），但**是運氣不是設計**：
我原本寫「兩臂都是 1208d22」的根據是「我自己沒重編過」，那是**另一句話**。
🔑 併發的 build **不會**動到已經啟動的行程，但會無聲改掉**下一個**行程載入的東西。
⇒ claim 保護 fabric，不保護磁碟上那顆 binary。長輪要嘛把 binary 複製到窗內私有路徑，
要嘛每次 `ndt up` 之後立刻記下 sha 並在收工時複驗。

🔑 附帶但更重要：**同一顆 binary 換掉之後，舊發現的 reproduce 配方會「正確地」失敗**。
T-11-A 改的正是 FINDING-06/07 量的那條路徑 ⇒ 配方不重現＝修好了，不是發現被推翻。
**發現檔的 reproduce 段落要標「量的是哪顆 sha」**，否則下一個人會把修好當成打臉。

## 🆕 08-31：**`RUNPATH` 也可能是 0 條——那時候「載入哪些 .so」由執行的那台機器決定**

上一節（bmv2）是 RUNPATH **存在**、於是保護來自 build。`ndtwin_kernel` 是**相反的那一格**：

```
readelf -d …/ndtwin_kernel | grep -cE 'RUNPATH|RPATH'   →  0
```

只有 `NEEDED`（`libcrypto.so.3`／`libssl.so.3`／**`libboost_url.so.1.83.0`**／`libstdc++`／…）
⇒ **解析完全交給執行端的搜尋路徑。**

實例：E 輪兩臂**在 nslab 的 VM 裡建**，但量測跑在**筆電**上（`lib_e.sh` 把 staged 臂蓋到
`build/bin/ndtwin_kernel`，而 `stack.sh:766` 寫死那條路徑）。⇒ **`ldd` 必須在筆電量，不是在
build 的那台量。** 實測筆電上兩臂 `not found` 皆 **0**（guest 與筆電同為 Ubuntu 24.04.4／
glibc 2.39／boost 1.83，soname 對得上）——**跨機器建置的風險是被否證的，不是被假設掉的**。

⇒ 本檔規則再補一格：問完「載入哪些 `.so`」之後還要問「**是誰決定的**」。
RUNPATH 有 ⇒ build 決定，到哪都一樣；RUNPATH 沒有 ⇒ **執行端決定，所以要在執行端量**。
兩種情況的驗證動作不同，而 `readelf -d` 一行就分得出來。

## 🆕 08-31：**commit sha 是對整棵樹的承諾——所以「只送子集」與「記真 sha」不能兼得**

要在共用帳號的機器上 build，只想送 build 需要的七項（3.5 MB），不想送 `doc/`／投稿包。
**做不到「送子集又保留真 commit sha」**：sparse-checkout 只管**工作樹**，物件庫照樣完整。
實查 depth-1 clone：**846 個 `doc/` 物件**＋`p4_proxy/`／`setting/`／`.claude/`（`git rev-list --objects`）。

🔴 **走不通的路（別再試）**：`--filter=blob:none` 對 `file://` 傳輸**被忽略**
（`warning: filtering not recognized by server`），兩種注入法都試過——
直接下 `--filter`、以及 `--upload-pack='git -c uploadpack.allowFilter=true upload-pack'`。

**可行的替代，而且 provenance 更強**：在目的地 `git init` 重建，provenance 兩欄並列
`upstream_commit=` 與 `subset_commit=`，身分改由**內容定址**擔保——
`git rev-parse <真sha>:<path>` 的 tree/blob hash 兩端各算一次逐一比對（E 輪用了六個，全中）。

🔑 **為什麼這比 `commit=` 強而不是妥協**：08-31 那天 repo tip 每幾分鐘動一次（全是 doc commit，
不可能改變 binary），我前後兩次 `rev-parse HEAD` 拿到不同 sha。
⇒ **一個「build 沒變它卻會變」的欄位不是 provenance。** `commit=` 記的是「你何時 clone 的」，
subtree hash 記的是「你編了什麼」。**指認輸入，不要指認一個包含輸入的容器。**

⚠️ 但 subtree hash **不會涵蓋 fetch 進來的相依**：`CMakeLists.txt:126` 的 googletest 走
`FetchContent`，是**第五個輸入**。它**釘死（commit archive `03597a01ee…`）但沒驗（無 `URL_HASH`）**
——**釘死與驗證是兩件事** ⇒ 自己補記實際下載到的 archive sha256（`edd885a1…`），
並確認兩臂共用同一次 fetch（同一個 `build/_deps/`）。

---

## 🆕 2026-08-31：**時間的版本——一個秒數也要指認它量了哪一段**

我把一組轉述的排程數字寫進預註冊，**標成「實測，非估算」**。20 分鐘後對方更正：
**高估兩倍**（30 分 → 18 分；build 段 23 分 → **4 分 25 秒**）。

那 23 分鐘**不是 build 時間，是整段佔用窗的長度——含兩次 build 失敗與診斷**。

🔴 **我的錯不是相信數字，是給它貼了一個我沒有驗過的標籤。** 我依據的是對方的措辭
（「實測，不是估的」），**而沒有問「量的是哪一段」**；對方後來承認他們同樣沒問。

🔑 **為什麼它通得過檢查**：它**是某個真實區間的長度**，只是不是被問的那一段
⇒ **通得過「這數字像不像話」的合理性檢查**。與 [[ratio-sides-must-share-a-population]]
同族——那裡問「分子分母同母體嗎」，這裡問**「這個長度，是哪一段的長度？」**

⇒ **這條規矩本來就存在，我只是沒把它套到時間上。** benchmark 要指認 binary；
**duration 要指認區間**。可操作版本：

> **落盤時記 `t_start` ／ `t_end` ／它涵蓋哪些步驟，不要只記一個 duration。**
> 一個裸的秒數**無法自證它量的是哪一段**。
>
> 轉述任何要拿去排程或下決定的數字前，問一句
> **「這是量的還是算的？量的是哪一段？」**——那一句的成本是一行字；
> 接收方拿它去排一個窗的成本，是那個窗。

⚠️ 同一個數字一天內錯兩次、方向相反（2 分 → 30 分 → 18 分），
**而正確答案從頭到尾就在磁碟上的 build log 裡**
⇒ [[verify-against-known-good-output]]：**有現成量測時不要用推出來的數字。**
（那個 2 分鐘也有自己的前提：它假設 VM 還在，而我們的流程正好要開新 VM。
**一個帶前提的數字，前提沒跟著傳就是錯的數字。**）

---

## 🔴 08-31 晚：**跑了實驗，跑在錯的對象上**——一晚兩次，都比「沒跑」更有說服力

這條規矩不只管 binary 與 duration，它管**任何宣稱所指的那個東西**。同一晚兩次：

| | 我量的 | 宣稱其實在講的 | 我得出的假結論 |
|---|---|---|---|
| push | `git push --dry-run **origin**`（＝公開上游，記憶白紙黑字寫著不要推） | `p4`（兩個 pushurl，**都 private**） | 「push 被 GitHub 權限擋住，你自己跑也會撞同一面牆」 |
| 直譯器 | `import networkx, grpc` 在 **`PY_PLOT`** 上 | `PY_PROXY`（`round.env:47` 早就分開綁，那顆兩個都有） | 「PY_PLOT 選 miniconda 可能會跑到一半炸」 |

🔑 **兩次的共通點：性質判斷正確，量測對象錯誤。** 而且兩次都**帶回了真實的證據**
——一則真的 `Permission denied`、一組真的 `MISSING` ⇒ **比沒有診斷更有說服力，也更誤導。**
判準因此不是「我有沒有跑」，是：

> **「我跑的那個對象，是這個宣稱在講的那個對象嗎？」**

⇒ 可操作的三步查法（mainDev 08-31 示範，比我要求的完整）：
**①查我被指定的那個 ②查被提供的退路**（它常常一樣壞，那就證明這條顧慮根本不成立）
**③往上找真正持有那個性質的角色**。第三步才是把錯的變數換成對的變數的那一步。

⚠️ 這也是[[claim-verb-decides-the-evidence]]的一個變形：那裡問「這個動詞要哪一種證據」，
這裡問**「這個名詞指的是誰」**。同族：[[ratio-sides-must-share-a-population]]。


---

## 🆕 2026-08-31 夜：**autotools 那條「明顯的路徑」是一支 shell script，而檢查會亮綠燈**

B 輪四臂 build 完，身分紀錄雜湊的是

    <tree>/targets/simple_switch_grpc/simple_switch_grpc   ← 6759 bytes

**那是 libtool 的 wrapper shell script。** 真正的 ELF 在

    <tree>/targets/simple_switch_grpc/.libs/simple_switch_grpc   ← 69,168,504 bytes

（我親自跑 `file` 確認：前者 `Bourne-Again shell script`、後者 `ELF 64-bit LSB pie executable`。）

### 🔴 為什麼它不是安靜的失敗，是**會通過的失敗**

| 檢查 | 對 wrapper 的行為 | 讀起來像 |
|---|---|---|
| 「四臂 sha256 必須相異」 | **通過**——wrapper 內嵌自己的樹路徑，四份天生不同 | 四顆不同的 binary ✅ |
| `nm` 符號簽章 | script 沒有符號 ⇒ 四臂全 0 | 一個**一致的陰性結果** |
| `size_bytes` / `RUNPATH` 欄 | 都填得出值 | 紀錄完整 |

⇒ log 上真的印出 `distinct sha256 across arms: 4 (want 4)`。
**一份關於 shell script 的證據，每一格都長得跟一份關於 binary 的證據一樣。**

🔑 **兩支獨立寫的腳本（下午既有那支、我晚上重寫那支）都走了同一條路** ⇒
**坑在 autotools 的目錄佈局裡，不是誰粗心。** 修法不是「改對路徑」，是**三道斷言**：
`file` 必須回 ELF、大小必須 ≥1 MB（wrapper 是 6.7 kB）、`nm` 必須回得出符號。
落在 `doc/audit/2026-08-31_completeness-experiments/B-nslab-build/`（`build_four_arms.sh` 已修、
`rerecord_identity.sh` 為重錄工具，commit `d1048f3`）。

### 🆕 同一晚的第二件：**我自己發明的符號簽章沒有鑑別力，註冊過的那個有**

我用 `nm -C | grep -i elogger`，四臂實測 **A=56、B=18、C=18、D=18**
⇒ **分不出關掉 `--disable-elogger` 的 C/D 與沒關的 B。**

study ① 註冊的是 **`nm -DC | grep -c EventLogger`**（動態符號），實測
**A=24、B=21、C=0、D=0** ⇒ stock/fast 兩組乾淨分開。

⇒ **prereg 說「沿 study」的時候，是指連儀器一起沿用。** 我換了工具（`-C` vs `-DC`）
與關鍵字（`elogger` vs `EventLogger`），得到一個看起來有值、實際不分辨的欄位。
**一個沒有鑑別力的欄位比沒有欄位糟，因為它會被當成證據。**
