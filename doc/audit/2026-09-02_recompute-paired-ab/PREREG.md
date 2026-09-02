# 預註冊：配對 A/B —— 那一階是不是那個常數造成的

**寫於 2026-09-02，`9/1 mainDev`。這一輪一筆資料都還不存在。**
[Co-developed with claude code -- Adam]

Adam 2026-09-02 裁示（逐字）：

> 配對 A/B 的問題也變尖了：不是「省了多少」，而是那一階為什麼由「有沒有樣本」觸發，
> 而那只要 baseline ＋ 一個低取樣率就分得出來。

---

## 0. 受測 binary —— 兩顆，只差一個常數

**不重建。** 08-31 的 E 輪已經建好這一對，附**建置期**寫下的 provenance，
而它們的 `SUPPLEMENTARY-provenance.md` §9 逐字寫著 **"Neither arm has been run.
Nothing here is a measurement."** ⇒ 本輪是它們的第一次量測，沒有先前結果要對帳。

| | A 臂（1 Hz） | B 臂（1 kHz） |
|---|---|---|
| 檔 | `.test_run/binaries/e-round/ndtwin_kernel.recompute-1hz` | `…recompute-1khz` |
| sha256 | `fcb0d9d40d5814a8…` | `4dc9193de97a2cfe…` |
| size | 72,877,744 | 72,883,184 |
| 原始碼那一行 | `std::chrono::seconds(1)` | `std::chrono::microseconds(1000)` |
| commit（上游） | `4d831b5859b6…` | **同一個** |
| 編譯器／`CMAKE_BUILD_TYPE`／旗標 | 13.3.0 / Debug / 空 | **全部相同** |
| gtest `FlowPathRecomputeInterval` | **PASS**（要求 pass） | **FAIL rc=8**（要求 fail） |

**分隔它們的是 `revert-2f57ba5.patch`，一行**（sha `f7dfc6e9…`）。

### 判別式在 binary 上重跑過，而且印得出兩種答案

`sleep_for` 的樣板實例化，**不是原始碼、不是 mtime、不是 provenance 的自述**：

| binary | 讀出 | |
|---|---|---|
| `recompute-1khz` | `sleep_forIlSt5ratioILl1ELl1000000EE` | `ratio<1,1000000>` ＝微秒 ⇒ **1 kHz** |
| `recompute-1hz` | `sleep_forIlSt5ratioILl1ELl1EE` | `ratio<1,1>` ＝秒 ⇒ **1 Hz** |
| `build/bin/ndtwin_kernel`（生產） | `sleep_forIlSt5ratioILl1ELl1EE` | 1 Hz |

**兩種答案都出現過** ⇒ 「讀到 1 Hz」與「grep 壞了」可分辨。
`run_ab.sh` 每格佈署後重跑這個檢查，**讀到與該格宣稱的不符就中止整輪**。

### 生產 binary 的還原保證（動它之前先驗）

`build/bin/ndtwin_kernel` 會被 `cp` 覆蓋。開跑前已驗三份副本
（`build/bin/`、`.test_run/binaries/e-round/…production-backup`、
`~/ndtwin-artifacts/production-kernel/…`）**sha256 全部等於
`e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94`**。
收尾把 backup 複製回去並重驗 sha。

---

## 1. 🔴 這一輪能講什麼、不能講什麼

**能講**：這是一個**真正的控制實驗**。同一棵樹、同一顆機器、同一個 fabric、同一支儀器、
交錯執行、只差一個常數 ⇒ **差值可以歸因給那個常數**。
09-01 那輪不行（兩顆 binary 差十二天，中間夾著 ticket Q 與 B-2①／E-2）。

**不能講**：

1. 🔴 **這一對停在 08-31 的 `4d831b58`，不是今天的 HEAD。** 它們**不含** 09-01 的
   B-2①（`LockManager::renew`）與 E-2（`getTopKFlowInfoJson` 遞迴 shared lock）。
   本輪只跑 **nopoll** 臂（不打 kernel 的 API），E-2 在 nopoll 下構不到，
   但**「本輪的數字＝今天 HEAD 的數字」這句話不成立**。
2. 🔴 **絕對值不能與 09-01 那輪並排。** 那輪量的是 `e3bad23c`，這一對是另外兩顆。
   本輪的結論一律取**臂間差值**，不取絕對高度。跨輪比對只當**弱線索**，並且要標明。
3. `CMAKE_BUILD_TYPE=Debug`（`-O0`）——三輪都是，所以不引入新的差異，
   但**這些數字不是 release build 的數字**，任何對外引用都要帶這一句。

---

## 2. 事前讀出來的機制（在量之前寫下，之後不得修改）

`calFlowPathByQueried`（`src/ndt_core/collection/FlowLinkUsageCollector.cpp:2764`）每一圈是：

```
while (running) {
    snapshot m_flowInfoTable 的 keys        // shared lock
    for (每一個 key) {
        auto graph = m_topologyAndFlowMonitor->getGraph();   // :2855
        for (hop < 100) { classifier lookup; ... }
    }
    endPass();
    sleep_for(kFlowPathRecomputeInterval);  // :2997  ← 本輪唯一的變數
}
```

🔑 **`getGraph()` 是 by value**（`TopologyAndFlowMonitor.hpp:171`），而同一個檔 `:186`
自己寫著它 **"deep-copied the entire BGL graph (every vertex string, ip vector and ecmp group)"**。
這裡是 128 host／288 edge。

⇒ **成本 ≈ 每秒圈數 × 流表裡的流數 ×（一次整圖深拷貝 ＋ ≤100 次 classifier 查表）**

**流表由 sFlow 樣本填。零取樣 ⇒ 表是空的 ⇒ `keys` 是空的 ⇒ 深拷貝零次
⇒ 那個 `sleep_for` 的值不影響任何東西。**

📌 這解釋了 09-01 量到的形狀（階梯之後幾乎平坦）：成本的乘數是**流數**，
而 iperf3 是一條流——所以取樣率再往上加，流數不變，成本也就不再明顯成長。

📌 而**產品碼裡的註解與這個機制牴觸**：`FlowLinkUsageCollector.cpp:2979-2980` 與
`FlowLinkUsageCollector.hpp:40-41` 都寫著那 46.31% 是
**"a fixed cost, not a per-sample one"**。09-01 的零取樣格已經推翻「fixed」這個字。
**本輪若證實 P1，那兩段註解要改。** ⚠️ 這是產品碼，本輪不動，另開。

---

## 3. 🔴 事前寫死的預期（資料出現後不得修改）

| | 預期 | 若成立 | 若不成立 |
|---|---|---|---|
| **P1** | **零取樣時兩臂的差 ≤ 噪聲地板（約 0.7 點）** | 那一階確實由「有沒有樣本」觸發，機制如 §2 | **機制錯了**——1 kHz 就算沒有流要走也很貴，成本不在深拷貝 |
| **P2** | **1/1024 時 B 臂（1 kHz）顯著高於 A 臂** | 那一階存在且由這個常數造成 | 那一階不由這個常數造成 |
| **P3** | **P2 的差值 ≈ 46 點** | 09-01 那 46 點的歸因**成立** | 見下 |
| **P4** | A 臂（1 Hz）在兩種條件下的差 ≤ 幾個點 | 1 Hz 沒有那一階，與 09-01 一致 | 跨輪不一致，要查 fabric 條件 |

🔴 **P3 是本輪最會咬人的一條，把兩種失敗分開寫清楚：**

- **P2 成立但 P3 不成立（差值顯著小於 46，例如 < 20）**
  ⇒ 那一階**部分**由這個常數造成，**其餘來自那十二天的其他改動**。
  ⇒ `2026-09-01_cpu-matrix-1hz/REPORT.md` 的頭條要**收窄**：
  「46 點是兩輪之間的差」這句話仍然對，但「這一階＝這個改動」要撤掉。
- **P2 不成立（兩臂在 1/1024 也差不多）**
  ⇒ 09-01 那 46 點**整組不歸因給這個常數**，REPORT 的對帳段落要改寫，
  而 ticket M 的 46.31% profiling 宣稱也要重新檢視。

**四條預期在資料存在之前寫死。事後只准新增觀察，不准改上面任何一格。**

---

## 4. 設計

- **12 格**：2 臂 × 2 條件 × 3 複本。**只有 nopoll 臂**（理由見 §1-1；
  09-01 已量到儀器成本兩輪都是 7 點上下，不是差異的來源）
- 每格 **300 s**，200 Mbit/s UDP `h1 → h33`，P4/bmv2 128-host／288-edge fabric
- `cpu_probe.py` 2 Hz 取 `/proc/<pid>/stat`；nopoll 用 `netdev_only.py` 取地面真值
- 前 6 秒丟掉（harness 先起 poller 再起 iperf3，頭部無流量）
- 每格自己 teardown＋bringup（因為每格都要換 kernel binary），量到 09-01 是 42 s

### 條件

| 條件 | 做法 |
|---|---|
| `zero` | P4 亂數**下界改成 1**（`random(meta.sample_rand, (bit<16>)1, SAMPLE_RATE - 1)`），`== 0` 永不成立 ⇒ clone 不觸發。沿用 09-01 `zero_cell.sh` 的機制與理由 |
| `s1024` | `SAMPLE_RATE = 1024`，判斷式維持生產形式 |

### 🔴 執行順序（事前寫死，臂序對稱平衡）

臂放在最內層 ⇒ 兩臂在時間上相鄰，機器漂移由兩臂共同承受。
六個「臂對」裡三對 A 先跑、三對 B 先跑：

| # | 複本 | 條件 | 順序 |
|---|---|---|---|
| 1 | r1 | zero | **A, B** |
| 2 | r1 | s1024 | **B, A** |
| 3 | r2 | zero | **B, A** |
| 4 | r2 | s1024 | **A, B** |
| 5 | r3 | zero | **A, B** |
| 6 | r3 | s1024 | **B, A** |

### 標籤

`ab_{zero,s1024}_{1hz,1khz}_r{1,2,3}_nopoll`

## 5. 🔴 控制在開量之前驗，兩個方向都驗

09-01 學到的那條：**量完再檢查只能作廢資料，量之前驗會拒絕那一格。**
本輪把它做成雙向的（`verify_cond.py`）——**兩種條件都要證明自己成立**，
因為「有取樣」也可能因為 fabric 沒接好而變成偷偷的零取樣：

| 條件 | 斷言（兩條都要過） |
|---|---|
| `zero` | ①每一條邊的 twin 讀數都是 0 ②交換機介面上**確實有 byte 在動** |
| `s1024` | ①至少一條邊的 twin 讀數 > 0 ②交換機介面上**確實有 byte 在動** |

②是必要的：只有①的話，「沒有流量」「iperf3 掛了」「kernel 不回應」都會滿足零那一側。
**驗不過就拒絕測量那一格並中止整輪**，不補打補丁。

## 6. 守衛（跨格可比性）

- 每格記 iperf3 封包數與 `/proc/net/dev` 總 tx。**臂間差 > 5% 的臂對，該對作廢。**
- ⚠️ **不用 `total_sample_rate()`**（08-20 那支 analyser 的 gcd 回推）：
  09-01 已證它在讀數不再量子化時無聲回傳大 1.2 千萬倍的數字。

## 7. 儀器歸位

1. `build/bin/ndtwin_kernel` ← `production-backup`，**並重驗 sha256 == `e3bad23c…`**
2. P4 判斷式還原成 `(bit<16>)0`、`SAMPLE_RATE` 還原成 **256**，重新編譯佈署
3. 兩者都由 `trap … EXIT INT TERM` 保證，開跑與結束都印進 log
4. 釋放 lab claim

## 8. 已知的儀器缺陷，本輪**刻意不修**

`measure.sh:45-46` 用 `pkill -f iperf3`，而專案硬規矩禁用 `pkill -f`。
`doc/KNOWN-ISSUES.md:1610` 已登記這條，並寫明**改它與不改它都有代價**：
四輪結果錨在這支儀器上。**本輪沿用未修改的版本**，因為換掉儀器會讓本輪
與 09-01／08-20 不可比，而可比性正是這一輪的用途。**本輪不新增任何 `pkill -f`。**
