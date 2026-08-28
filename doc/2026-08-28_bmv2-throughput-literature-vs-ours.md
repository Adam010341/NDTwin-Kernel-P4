# bmv2 吞吐：文獻值與本機實測的對照

**建立日 2026-08-28。** 四篇論文全文讀過（PDF 在 `~/Desktop/NDTwin slide material/paper/bmv2 performance/`），
本機數字全部來自 repo 內已 commit 的量測。

⚠️ **本檔的範圍限制先講**：這是**四篇論文**的對照，**不是文獻回顧**。
它們來自兩次關鍵字搜尋，**沒有做系統性檢索**。
⇒ **本檔可以說「這四篇沒有寫 X」，不能說「文獻裡沒有人寫 X」。** 兩者差很多。

---

## 1. 🔴 四篇沒有一篇給出 build flags 或做過 build 對照（08-28 深夜更正措辭）

對四篇全文搜 `disable-logging` / `disable-elogger` / `-O2` / `-O3` / `configure` /
`compilation flag` / `build option` ⇒ **零命中**。

⚠️ **08-28 深夜更正**：上面的「零命中」是**關鍵詞 grep 的假陰性**。ICNCC '23 §4.2 有一句
質性敘述——為改善效能，以「不產生 log 的模式」**編譯**——不含上列任何關鍵詞。
正確版本：**四篇無一給 flags／optimization level、無一做對照；其中一篇（ICNCC）有一句
質性 build-mode 敘述且載明版本 1.15**。完整 14 篇對照見
`doc/audit/2026-08-28_bmv2-literature-review/RELATED-WORK.md`。

**而這個變數有多大，論文自己寫了**（Chen/Hu/Jin, SIGSIM-PADS '23）：

> Various BMv2 implementations, such as `simple_switch`, `simple_switch_grpc`, `psa_switch`
> have different performance (e.g., **the maximum throughput ranges from 40 Mbps to 1 Gbps**).

⇒ **它指認了這個變數存在、把範圍寫出來、然後沒有控制它，也沒有說自己用哪一種。**

---

## 2. 所有已知數字並排（含本機）

| 來源 | 條件 | bmv2 吞吐 |
|---|---|---|
| Mininet-P4 testbed（**TSSA 2023**；08-28 更正：先前誤記為「ICT 2023」，數字吻合同一篇） | 64 B 封包 | **~0.57–0.76 Mbps** |
| 同上 | 128 B 封包 | ~1.03 Mbps |
| **本機 stock build**（`-O0`＋logging） | UDP、1400 B | **~40–42 Mbps** |
| Chen/Hu/Jin | **`simple_switch_grpc`**、線性 16 switch | **~170 Mbps** |
| Chen/Hu/Jin | 線性拓樸飽和點 | 130 Mbps |
| **本機 bmv2-fast**（`-O3`、無 logging） | UDP、1400 B、**單流** | **~460–530 Mbps** |
| **本機 bmv2-fast** | UDP、**16 流合計** | 🔴 **~48 Mbps** |
| Chen/Hu/Jin | **`simple_switch`（非 grpc）** | **up to 1 Gbps** |
| p4lang 官方 `docs/performance.md` | c4.2xlarge、`simple_router.p4`、`-O3 --disable-logging-macros --disable-elogger` | **~1,047 Mbps 中位 / 80 kpps** |
| BMv2 vs T4P4S（ICNCC '23） | UDP ramp | **1 Gbps 無損；上限 ~1.4 Gbps** |

⇒ **橫跨約三個數量級。** 在沒有 build 資訊的前提下，**這張表不能用來預測任何一台機器的行為**。

---

## 3. 本機量到、而文獻沒有量的三件

### 3-1. 🔴 build 設定值 **12–18 倍**（`doc/2026-08-15_bmv2-performance-report.md`）

| 量 | stock | bmv2-fast | 倍率 |
|---|---|---|---|
| UDP delivered 天花板 | ~40–42 Mbps | ~460–530 Mbps | **12–13×** |
| TCP 單流 | 24.2 Mbps | 431.0 Mbps | **17.8×** |
| 64 B 小包 | 3,619 pps | 50,786 pps | **14×** |
| 閒置 RTT（3 hops） | 9.1 ms | 2.8 ms | 3.3× |

📌 **要和論文的 30.7% 分開**：Chen/Hu/Jin 說「turning on all tracing features」讓效能掉 **30.7%**
——那是**執行期旗標**。**編譯期把 logging 移除是一個數量級。** 兩者常被混為一談。

### 3-2. 🔴 天花板是 **pps 不是 bps**

stock 在 1400 B 下平台 **~3.66k pps**，64 B 實測 **3.62k pps** ⇒ **與封包長度無關。**
⇒ 「多少 Mbps」是「pps × 封包大小」的假象，而文獻普遍以 Mbps 報告。

### 3-3. 🔴 多流會讓**總**吞吐下降，而且只有 bmv2 會

| | 單流乾淨到 | 16 流合計 | |
|---|---|---|---|
| **bmv2** | 160 Mbit | **48 Mbit** | 🔴 **塌陷 3.3×** |
| **OVS** | ~400 Mbit | **480 Mbit** | ✅ 不塌陷 |

**機制**：bmv2 的 datapath 是 user-space 行程、**整台交換機共享一顆 CPU**；
OVS 的 datapath 在 kernel、隨核心數擴展。

🔑 **Chen/Hu/Jin 量化了症狀、但沒有隔離變因**（08-28 深夜更正——先前寫「沒有量化」過強）：
256-switch ring，host 成對走**不重疊的鏈路**，前 40 秒 h1-h2 維持 1000 Mbps，
其他對開始傳之後**每對掉到 ~212 Mbps**（PADS '23 與 TOMACS 2025 兩版都有此值）。
他們沒做的是：(a) 流數從未單獨作為自變數（與「活躍 switch 容器數」在 256-sw 超載設計裡綁死）；
(b) 該實驗**沒有 OVS 對照臂**；(c) 只報 per-pair、無同路徑總和視角。
⇒ **他們量化了症狀，我們有固定小拓樸、host 不超載、帶對照平面的受控量測。**

---

## 4. 抖動：本輪（2026-08-28）的結果

**判別法**：每個 iperf3 interval 算 `bytes ÷ 名目 1.0` 與 `bytes ÷ 實際 (end−start)`。
**抖動在後者塌掉 ⇒ 儀器（H2）；還在 ⇒ 資料面（H1）。**

| 條件（OVS） | loss | 名目 CV | 實際/名目 |
|---|---|---|---|
| 16 流 × 30 M（**18.0 GB**）、10 burner | 0.037% | **0.64%** | 1.00 |
| 單流 800 M、**無** burner | 0.459% | **0.01%** | 0.985 |
| 單流 800 M、**10 burner** | 10.7–11.2% | **5.99–8.10%** | 0.999–1.001 |

⇒ **H1，而 H2 在每一格被否證。**
🔑 **H2 的先驗很強而它仍被否證**：**同一台機器上 kernel 的 `sleep_for(1s)` 迴圈長 141 ms**，
**而 iperf3 的一秒維持 sd 0.4–0.6 ms**。「軟體的一秒會長」在這個專案是實測事實，iperf3 不受影響。

> **驅動抖動的是「CPU 競爭造成的丟包」，不是速率、也不是總量。**
> 800 Mbit 無 burner 的 CV 是 **0.01%**；18 GB 分散在 16 流上是 **0.64%**。

⚠️ **未分離**：現象出現在**有 htb shaping** 的狀態，尚未確認丟包發生在 htb 還是 OVS datapath。

⚠️ **bmv2 上這個判別法沒有適用域**：現象需要的 loss 量級（9–67%），
正是「送端速率被忠實承載」失效的量級 ⇒ **兩個條件在 bmv2 上結構性互斥**（OVS 上不互斥）。

---

## 5. 這份對照能支持與不能支持的宣稱

**能**：
- 這四篇沒有一篇給 build flags 或做過對照（一篇有質性「無 log 編譯」敘述——見 §1 更正），而該變數在本機值 12–18 倍
- 本機兩顆 build 的數字都落在 Chen/Hu/Jin 自陳的「40 Mbps – 1 Gbps」區間內
  ⇒ **那個區間寬到無法否證任何東西**
- 慢的是 bmv2 這個實作不是 P4 這個語言（T4P4S 同程式跑到 2.3–2.6 Gbps）

**不能**：
- 🔴 **不能說「文獻裡沒有人做過 build 的對照」**——我們只讀了四篇，且未系統性檢索
- 不能說本機數字可外推（單一機器、單一拓樸、多數量測 n=1–2）
- 不能說抖動是缺陷（**沒有規格可違反**）

---

[Co-developed with claude code -- Adam]
