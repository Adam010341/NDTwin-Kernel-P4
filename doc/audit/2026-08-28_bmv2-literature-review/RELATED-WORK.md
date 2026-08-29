# bmv2 效能文獻：14 篇逐篇對照表

**建立日 2026-08-28。** 委託：8/27 auditor（Adam 指派）。
**材料**：`~/Desktop/NDTwin slide material/paper/bmv2 performance/` 的 14 篇 PDF，全部經 `pdftotext -layout` 轉文字後閱讀（9 篇全文、5 篇全文＋評估章節逐行；無一篇只讀摘要）。
**行號引註**：指 `pdftotext -layout` 輸出的行號（重生方式見 `raw/README.md`；全文 txt 不入 repo——公開 repo 不能收論文全文）。

⚠️ **範圍限制**：這 14 篇來自關鍵字搜尋，**不是系統性檢索**。本檔只支撐「**這 14 篇裡**沒有」等級的宣稱，不支撐「文獻裡沒有人」。
📌 **14→18 的沿革（08-29 補記）**：檢索兩輪擴充 4 篇（+3＝`SEARCH-ROUND-1.md`：PADS'26／MDPI Network'25／P4Docker；+1＝`SEARCH-ROUND-2.md`：P4sim）。**本檔逐篇表維持原 14 篇**，擴充篇目之逐篇證據在各 round 檔；合併統計（12 篇量測）見 `doc/2026-08-29_bmv2-performance-study.md` §2-1；逐篇「儀器極限檢查」編碼另見 `LIMIT-CODING.md`。

## 0. 檔名 → 論文身分

| 檔名 | 論文 | bmv2 有被量嗎 |
|---|---|---|
| `3725530.pdf` | Chen, Hu, Qu, Jin — *Enhancing P4-Based Network Emulation Fidelity…* **TOMACS 35(2), 2025**（PADS '23 的期刊擴充版） | ✅ 受測物 |
| `3573900.3591120.pdf` | Chen, Hu, Jin — 同題 **SIGSIM-PADS '23** | ✅ 受測物 |
| `3615979.3662157.pdf` | Waind, Chen, Hu, Jin — *Comparative Analysis and Evaluation of P4-Based Network Emulation Testing Environments*, **SIGSIM-PADS '24**（2 頁） | ✅ 受測物 |
| `3638837.3638871.pdf` | Kumazoe, Shibata, Tsuru — *Experimental comparison … BMv2 and T4P4S*, **ICNCC 2023** | ✅ 受測物 |
| `Performance_Analysis_of_Mininet-based_Testbed…pdf` | Hasnaa, Mulyana, Nurkahfi — **TSSA 2023** | ✅ 受測物 |
| `3050220.3050231.pdf` | Dang et al. — *Whippersnapper*, **SOSR '17** | ✅（僅 latency） |
| `arXiv_P4CEP…pdf` | Kohler et al. — *P4CEP*, **NetCompute '18** | ✅（對照 target） |
| `arXiv_P4-NIDS.pdf` | Chen, Layeghy, Manocchio, Portmann — *P4-NIDS*（arXiv，2024 版） | ✅（應用載體） |
| `PoliTO_thesis…pdf` | 碩士論文 — *Delay Control with Programmable Data Planes*, PoliTO | ✅（僅 delay） |
| `TUM_NET-2022-01-1…pdf` | Tsareva, Scholz, Gallenmüller — *Taxonomy of the Performance of P4 Targets*, TUM seminar SS21（**survey，轉述他篇**） | ➖ 轉述 |
| `1-s2.0-S1389128621000372-main.pdf` | Zhang et al. — *Performance benchmarking of state-of-the-art software switches for NFV*, **Computer Networks 188 (2021)** | ❌（受測 7 switch 含 t4p4s；bmv2 僅在參考文獻） |
| `A_benchmarking_methodology…NFV.pdf` | Zhang et al. — **NetSoft 2019**（上一篇的前身） | ❌（6 switch，無 bmv2） |
| `arXiv_vSDNEmul…pdf` | Farias et al. — *vSDNEmul*（arXiv） | ❌（OVS 系容器模擬器） |
| `HotSDN13…pdf` | Huang, Yocum, Snoeren — **HotSDN '13** | ❌（前 P4 時代；OVS＋3 台硬體 switch） |

## 1. 主表：量了 bmv2 的 9 篇

「未載明」＝該篇全文找不到。**這一欄的「未載明」本身就是本輪最重要的資料點。**

| 篇 | 變體 | 版本 | build 設定 | bmv2 主要數字 | 掃過的軸 | 沒掃的軸（與我們三個宣稱相關的） |
|---|---|---|---|---|---|---|
| **TOMACS 2025** | `simple_switch_grpc`（Fig 2a **有載明**）；另述 `simple_switch` 可到 1 Gbps（txt 327–331） | 未載明 | **未載明**（僅 runtime「turning on all tracing features」−30.7%，txt 333–334） | grpc 天花板 ~170 Mbps、飽和點 130 Mbps；OVS 對照 30 Gbps；線性 4→256 sw：495.6→87.6 Mbps；ring 256-sw 每對 1000→**212 Mbps**（txt 372–373）；SYN-flood 場景該 switch ~54 Mbps；ECMP fat-tree cap ~50 Mbps、per-flow 短收 72.8–87.5% | link bw、switch 數 1–256、拓樸×3（線性/ring/fat-tree）、應用×2、TDF | 封包大小；pps 框架；build；**固定小規模下的流數軸**（16/4/1 流出現在**不同路徑型態**的三個場景，與拓樸層混雜，txt 908–933） |
| **PADS '23** | 同上（有載明） | 未載明 | **未載明** | 同 TOMACS 核心數字（170／130／30 G／495.6→87.6／ring 212，txt 199、215–218） | 同上，減 ECMP 與 SYN-flood（期刊版新增） | 同上 |
| **PADS '24**（Waind） | **未載明**（僅「BMv2」，p4lang/tutorials 安裝） | 未載明 | **未載明** | 單 switch 平台 ~175 Mbps（native）／~145 Mbps（VM）；10-sw 鏈 <30% 單台值；RTT 每 sw 1.217／1.4245 ms；TDF 最高 79.6 | 環境×4（VM/native/native+VT/Tofino 硬體）、switch 數 2–10、offered bw | 封包大小、流數、pps、build |
| **ICNCC 2023** | 未載明哪隻 binary | **1.15（有載明**，txt 117–118**）** | 🟡 **9 篇中唯一有質性敘述**：為改善效能，以**不產生 log 的模式編譯**（§4.2，txt 187–190）；**無 flags、無 -O level、無對照**；引官方 `performance.md`（ref [3]） | **1 Gbps 無損；均值天花板 ~1.4 Gbps**（2–3 G offered）；T4P4S 對照 2.3／2.6 Gbps；register 降到 ~70%；clone −5%（buf 200）／−1/3（buf 2000）；recirc ×1 → 700 Mbps；兩台串接 950 M 無損 | offered rate 1–3 G、buffer 200/2000、實體機×2、P4 功能×5、串接 1–2 sw；**實體 10 G NIC、非 Mininet** | 封包大小、流數（全程單流）、pps 框架（全 Gbps）、**build 對照** |
| **TSSA 2023** | **未載明**（P4-Utils 安裝） | 未載明 | **未載明**；🟡 引了 `performance.md`（ref [10]，**即載有官方建議 build flags 的那份文件**）卻把 ~1000× 落差全歸給 VM 規格（2 vCPU vs c4.2xlarge，txt 340–354） | 64 B：574.4–756.7 Kbps；128 B：1022–1040 Kbps；64 B loss 27.8–44.7%→128 B 0.89–2.64%；CPU >90% @ >1 Mbps；delay 11.8–14.1 ms（4-sw 拓樸） | **封包大小 2 點（64/128 B）**、offered bw、P4 程式複雜度×3 | **pps**——兩點資料逐情境配對換算後 pps 比 0.69–0.90、偏恆定端（64 B 側 ~1.1–1.5 kpps／128 B 側 ~1.0 kpps；**我們的換算，論文未計算未陳述**；它把 128 B 的改善歸因「datagram 較少→較不會丟」，txt 371–378；08-29 修正配對法，詳 `GAP.md` §②）；流數；build |
| **Whippersnapper '17** | 未載明（2017 年代 behavioral model） | 未載明 | **未載明**（硬體有載：Xeon E5-2603 1.6 GHz、Ubuntu 14.04） | latency：parse 1 header **11.2 ms**、write 1 field 11.1 ms、1 table 14.4 ms（Table 3；PISCES 同項 ~5 µs）；**bmv2 無 throughput 數字** | #headers、#field-writes、#tables（latency） | bmv2 的 throughput／封包大小；「流數」在其 workload 旋鈕清單存在（txt 265–266）但未對 bmv2 跑 |
| **P4CEP '18** | 未載明 | 未載明 | **未載明** | 🔑 **corpus 裡唯一 pps 本位的 bmv2 吞吐**：min-size 包 **≈12 kpps**（線速 14.88 Mpps 的 0.08%，txt 383–387）；baseline latency 475 µs；window n>15 時 lp >10 ms | CEP window size 0–20（latency＋相對吞吐） | **封包大小掃描（單點 min-size）**、流數、build |
| **P4-NIDS**（arXiv） | 未載明（P4-Utils） | 未載明 | **未載明**（VM 6 vCPU／8 GB 有載） | 吞吐 ~80 Mbit/s 量級（NetFlow 模組比較圖）；⚠️ 自述三場景 CPU 恆 0.3%（txt 528–530——與我們 08-15 抓過的「量測假象」同型，存疑但照錄） | NetFlow 欄位數、場景×3；另有 Netronome 硬體對照部（非 bmv2） | 封包大小、流數、pps、build |
| **PoliTO thesis** | 未載明 | 未載明 | **未載明** | 純 delay：1-sw 拓樸 RTT 基線 0.98 ms（VM）／2.16 ms（實體 server，方向反直覺、論文未解釋機制）；遞迴 0–15 次的 RTT 曲線 | link bitrate（netem）、遞迴次數、VM vs 實體、1–2 sw | throughput 全缺、封包大小固定 1200 B、流數、build |

## 2. 沒量 bmv2 的 5 篇為什麼還重要

| 篇 | 對本輪的意義 |
|---|---|
| **CompNet 2021** | 🔑 **① 的對照組**：對它量的 7 個 switch **逐一給 commit/版本**（FastClick 9d5e9c6、OVS-DPDK 2.11.90、t4p4s b1161b2…，txt 520–525）、BESS 註明「specifically built for Haswell」、附錄給逐 switch 參數、單核釘住＋定頻＋Turbo off。**⇒ provenance 紀律在隔壁社群是現行標準，不是做不到。** |
| **NetSoft 2019** | 同組人的前身：4 場景方法學、**Mpps@64B 本位**。 |
| **TUM SS21** | 轉述型 survey：bmv2「up to 1 Gbit/s」無 build 出處地流傳；🔑 它整理的兩類效能模型之變數清單（記憶體、軟體實作、pipeline…）**不含軟體 target 的 build 設定**；明列 jitter 為 future work。 |
| **vSDNEmul** | 容器模擬器 fidelity 先行文獻（OVS 系、6.6 Gbps 容量、對 Mininet 比較）；顯示「模擬器吞吐 fidelity」這個問題形狀早於 P4。 |
| **HotSDN '13** | 🔑 先行路線：「量測真 switch → 在模擬器內**建模型**校正 fidelity」（control-path：flow setup 42–408 flows/s、TCAM 511–65k）。這條路線在 bmv2 時代沒人接（Chen 組走的是 virtual time＝縮時間，不是建模型）——見 GAP §4。 |

## 3. 統計（9 篇有量 bmv2 的）

- **變體有載明：2/9**（PADS '23、TOMACS——同一組人）；**版本有載明：1/9**（ICNCC，1.15）。
- **build flags／optimization level：0/9。質性 build-mode 敘述：1/9**（ICNCC「無 log 模式編譯」一句）。**build 對照實驗：0/9。**
- 引了官方 `performance.md`（其中就寫著建議 build flags）的 2 篇（ICNCC、TSSA），**仍未報告自己的 build**。
- **對 bmv2 的封包大小掃描：0/9**（TSSA 有兩點但未分析；PoliTO 固定 1200 B；其餘單一大小或未載明）。
- **pps 本位的 bmv2 數字：1/9**（P4CEP 單點）；其餘全部 Mbps/Gbps 本位。
- **固定拓樸下把流數當自變數：0/9**（TOMACS 的 16/4/1 流與路徑型態混雜；ring 的 128 對與 256-switch 規模混雜）。
- **9 篇合計的 bmv2「吞吐」數字橫跨**：0.57 Mbps（TSSA 64 B）→ 1,400 Mbps（ICNCC 均值天花板）≈ **~2,500×**，其中**零篇**給出足以重建其 binary 的資訊。

## 4. 對我們自己文件的更正（讀文獻的副產物，已回改 `doc/2026-08-28_bmv2-throughput-literature-vs-ours.md`）

1. 🔴 該檔 §1「四篇沒有一篇寫出自己的 bmv2 build 設定…零命中」——**關鍵詞 grep 假陰性**。ICNCC 2023 有質性 build-mode 敘述，只是不含那組關鍵詞（[[grep-endpoints-misses-concatenation]] 同型）。正確版：「無一篇給 flags／做對照；一篇有質性敘述」。
2. 🔴 該檔 §2 把 TSSA 2023 記成「ICT 2023」——venue 錯，數字吻合確認同一篇。
3. 🟡 該檔 §3-3「Chen/Hu/Jin 觀察到同一個現象但沒有量化它」——**過強**。兩版都給了量化症狀（每對 1000→212 Mbps）。他們沒做的是：把流數當自變數隔離、在 host 不超載的規模量、給該實驗配對照平面。

[Co-developed with claude code -- Adam]
