# 預註冊：CPU 矩陣在 1 Hz 路徑重算下重量一次

**寫於 2026-09-01，`9/1 mainDev`。一筆資料都還不存在。**
[Co-developed with claude code -- Adam]

Adam 指示：照 08-20 那張 matrix decomposition 的邏輯，再量一次每個取樣率的 kernel CPU，
因為 `calFlowPathByQueried` 從 1 kHz 變成 1 Hz，他要比較差異。

---

## 0. 受測 binary（量之前先釘住，因為 `stack.sh` 不會重建）

🔴 `tools/test_workflow/stack.sh:760` 只檢查 kernel binary **存在**（`[[ ! -x ... ]]`），
**從不重建**。所以「原始碼寫著 1 Hz」對「等一下會跑什麼」零資訊。

| | |
|---|---|
| binary | `build/bin/ndtwin_kernel` |
| sha256 | `e3bad23cdfe4fec38bf5bf0b473ae8f4…`（`matrix_1hz.sh` 開跑時印完整值進 log） |
| mtime | 2026-09-01 07:25:10 —— **不當證據用** |

**判別式＝`sleep_for` 的樣板實例化**，不是 mtime、不是原始碼：

- `sleep_forIlSt5ratioILl1ELl1EE` → `std::ratio<1,1>` ＝ **秒** ⇒ 1 Hz
- `sleep_forIlSt5ratioILl1ELl1000000EE` → `std::ratio<1,1000000>` ＝ **微秒** ⇒ 1 kHz

**這個判別式印得出兩種答案**（否則「讀到 1 Hz」與「grep 壞了」分不開）：

| binary | 讀出 | |
|---|---|---|
| `build/bin/ndtwin_kernel`（09-01） | `ratio<1,1>` | ✅ 1 Hz |
| `.test_run/binaries/…a40e04ce`（08-27 22:21） | `ratio<1,1>` | 1 Hz |
| `.test_run/binaries/…ab2d7ed1`（08-27 22:06） | `ratio<1,1000000>` | **1 kHz** |
| `.test_run/binaries/…3367d0e9`（08-26 00:34） | `ratio<1,1000000>` | **1 kHz** |

`matrix_1hz.sh` 開跑第一件事就是重跑這個檢查，**讀到不是 `ratio<1,1>` 就中止**，
不讓這一輪被貼上「1 Hz」的標籤。

## 1. 🔴 這個比較能講什麼、不能講什麼

08-20 那組數字是**十二天前的 kernel** 量的。中間至少夾著 ticket Q 的 in-loop 除數儀器
（`f5e3556`）與今天的 B-2①／E-2 兩個修法。

**Adam 2026-09-01 裁示**：接受這個混淆，不另外建一顆「只差那個常數」的 binary 做同場 A/B
（那要多約 2.5 小時）。

⇒ **本輪的差值是「兩輪之間的差」，不是「這個改動的效果」。**
圖上與文件裡都要這樣寫。任何寫成「1 kHz → 1 Hz 省了 N 點」的句子都是錯的。

## 2. 設計（沿用 08-20，不動）

- 每格 300 s，200 Mbit/s UDP `h1 → h33`，P4/bmv2 128-host／288-edge fabric
- `cpu_probe.py` 2 Hz 取 `/proc/<pid>/stat`；twin 4 Hz
- **poll-on／poll-off 成對**：poll-off 用 `netdev_only.py`，不打 kernel 的 API
- 分解：`baseline`（冷 fabric）／`ingest`（poll-off − baseline）／`instrument`（poll-on − poll-off）
- 前 6 秒必須丟掉（harness 先起 poller 再起 iperf3，頭部無流量）

### 18 格

| 格 | n | 說明 |
|---|---|---|
| `m{1024,512,256,128,64}_{poll,nopoll}` | 10 | 五個取樣率 × 兩個 poll 臂 |
| `mnone_{poll,nopoll}` | 2 | clone 停用、**暖** fabric（承接 1/64 那張） |
| `mzero_{poll,nopoll}[_r2,_r3]` | 6 | clone 停用、**冷** fabric，**n=3** |

🆕 `mzero` 在 08-20 是**手跑的**（`matrix.log` 沒有它、也沒有任何 script 產出它）。
本輪寫進 script，因為**它是這個改動最該現形的地方**——閒置時沒有 ingest 工作可以蓋住
一個固定的每輪成本。

## 3. 事前寫死的預期（事後不得修改）

1. **方向**：1 Hz 的 `mzero_nopoll`（冷 fabric、無 clone、無 poll）**應該 ≤ 08-20 的 2.89%**。
   那個執行緒每秒少醒 999 次。
2. **形狀**：重算執行緒不碰 ingest 路徑 ⇒ 若差異真的來自它，**五個取樣率上的差應該是一個常數位移**，
   不是隨取樣率放大。**若差異隨取樣率放大，那就不是這個改動**（或不只是它）。
3. **守衛**：`samples/s` 兩輪應在 ±5% 內。超過代表 fabric／流量條件變了，
   兩輪不可比——**這條先於一切結論**。

## 3b. 修訂一次（21:31，開跑 2 分鐘後，**在任何要用的資料存在之前**）

`mzero` 那段第一版把 `bringup()` 拆開來只寫了 `stack.sh up` 那半，**掉了 `$LAB topo-start`**
⇒ 會量到「**完全沒有 fabric** 的 kernel」而把它標成冷 fabric 零點。兩者不是同一個數字：
kernel 手上有沒有那張 288-edge 的圖，它的週期工作就不一樣。

**處置**：整輪重跑，不打補丁。已產生的 `m1024_poll` 一格作廢（沒有進入任何分析）。
理由是這一格是整個分解要減掉的那個數——**減錯了每一格都錯**，而當下才 2 分鐘，重跑最便宜。

✅ 符合預註冊修改三條件：資料還沒開始用、改的是**儀器接線錯誤**不是門檻、
而且改動方向與想要的結果無關（修好之後 baseline 可能升也可能降）。

📌 中止那一輪的 log 留在 `matrix_1hz.aborted-2131.log`／`driver.aborted-2131.log`。
順帶一個會讓讀者困惑的痕跡：重跑的 log 開頭印 `p4 SAMPLE_RATE at start: 1024`，
不是生產值 256——因為中止的那一輪已經把它 `sed` 成 1024 了。**不是異常**，
結束時仍然改回 256（log 末尾那行是憑據）。

## 4. 儀器歸位

`matrix_1hz.sh` 會 `sed` 改 `p4_proxy/p4_src/ndtwin_switch.p4` 的 `SAMPLE_RATE`，
結束時**改回 256 並重新編譯佈署**，開跑與結束都把該值印進 log。
留在 1/64 會無聲改變之後每一輪量到的東西。
