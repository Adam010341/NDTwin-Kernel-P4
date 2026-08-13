# 研究 session prompt：NDTwin 進階測試（大規模＋外部模板）

**用法**：貼進一個**有 web 搜尋**的全新 session（建議 opus 即可，這是研究彙整不是實作）。
預期產出是一份文件，不是程式碼。跑完把產出檔路徑回報給 Adam。

---

## 以下為 prompt 本體（從這行以下整段貼上）

你是 NDTwin-Kernel 專案的測試方法研究員。任務：研究（A）大規模測試方式與（B）網路上現成的
測試框架/模板，並**對映到本專案的具體缺口**，產出一份可執行的建議書。你不寫程式、不改 repo、
不碰 live 環境、**不安裝任何套件**（本專案吃過 PyPI 搶注套件的虧——所有工具只建議、附精確
版本與來源查證方式，不執行 pip install）。

### 專案脈絡（先讀，避免建議我們已有的東西）

- Repo：`/home/adam/Desktop/NDTwin-Kernel`（唯讀）。網路數位孿生：C++ kernel + 7 個外圍應用，
  資料面雙路：OVS/Mininet + Ryu，以及 P4/bmv2 + 自寫 Python proxy（模仿 Ryu 北向 API、
  自行合成 sFlow v5）。
- **既有測試資產（2026-08-13 實測，不要重複發明）**：
  - L0 建置檢查 → L1 單元（C++ gtest 547/69 suites；Python 524，venv 直譯器）→
    L2 API 契約 → L3 元件契約（blast radius）→ L4 OVS/P4 差異比對（allowlist 三分類）
  - **Mutation testing 是驗收關卡**：每條測試都要親眼看它紅過；已抓 12+ 假測試
  - 手動 live runbook 三份（doc/*runbook*.md）；證據式 liveness 三態；log allowlist 閘門
  - 讀 `doc/2026-08-07_testing_tools_overview.md` 與 `doc/2026-07-27_p4_bmv2_support_plan.md` 掌握全貌
- **規模現況**：P4 testbed = 10 switch / 4 host（bmv2）；OVS testbed = 10 switch / 128 host。
  sFlow 取樣 P4 側 1/256 且只有 flow sample。
- **昨晚（2026-08-12/13）整夜測試輪的教訓——這是你最重要的輸入**：
  最高價值的缺陷全部來自**沒被腳本涵蓋的故障形狀**，不是來自跑更多次既有測試：
  1. **單向鏈路故障**（單端 netem loss 100%）→ 控制器路由重算對「圖不對稱是穩態」沒有防禦
     → 永久黑洞。雙向斷有測、單向從來沒有人想到。
  2. **兩個 controller 對同一 switch 的 mastership 相撞** → 清表 + 寫入全拒 + 回報 success。
  3. **故障注入工具本身的 side effect**（`tc qdisc add root` 會靜默替換 Mininet TCLink 的
     htb）→ 假證據。
  4. 更早：controller 單獨重啟觸發 /stats/flow wedge（root cause 至今未證明）。
  結論：我們缺的是**系統性的故障模型目錄**（fault model catalog），不是更多 happy path。

### 任務 A：大規模測試方式

針對以下每一項，找方法論與實際數據（來源要可引用）：
1. **拓撲規模化**：bmv2 的實際規模天花板（每台 simple_switch_grpc 的 CPU/記憶體、
   veth 數量限制、社群實測的 fat-tree k=4/k=8 經驗）；OVS 側 Mininet 大拓撲的已知陷阱。
2. **流量規模化**：iperf mesh 編排模式、trex/scapy/hping 的適用場景比較；
   在「取樣 1/256」前提下要多少 pps 才有統計意義。
3. **長時間 soak**：數位孿生的 drift 量測方法——twin 回報值 vs ground truth 的
   偏差隨時間怎麼量、怎麼設回歸門檻（我們已有 flow-rate 精確度量測 commit `d7bf52f` 可比對）。
4. **孿生保真度（fidelity）驗證**：其他 digital twin / network emulation 專案怎麼驗證
   「twin 沒說謊」？找學術與工業做法（NS-3 對照、hardware-in-the-loop、conformance 類）。

### 任務 B：外部測試框架/模板（帶「適不適合我們」的過濾器）

逐一評估，**每項都要回答：解決我們哪個缺口？導入成本？跟既有 L0-L4 哪層對接？**
- SDN 專用：STS（troubleshooting SDN）、DELTA（SDN security testing）、BEADS、
  OFTest/PTF（packet test framework）
- P4 專用：p4testgen、P4Runtime conformance 測試、Stratum 的 bmv2 測試模式
- 故障注入：Jepsen 的 nemesis 目錄（**特別是 asymmetric network partition**——
  對映我們的單向斷鏈）、chaos engineering 的網路故障目錄（pumba/toxiproxy 的故障類型清單，
  即使工具不適用，**故障類型清單本身就是我們要的**）
- Property-based：Hypothesis 對 REST API / 拓撲不變量（例：任何事件序列後
  `edges_up ≤ edges_total`、路徑端點必在圖裡）的套路
- Fuzzing：sFlow parser 歷史上有 heap overflow（已修，ASan 建置存在）——
  libFuzzer/AFL++ 對這類 datagram parser 的標準接法

### 產出（寫到 `doc/audit/advanced-testing-research-<日期>/REPORT.md`）

1. **故障模型目錄**：表格——故障類型 → 我們已涵蓋？（引 runbook/測試檔證據）→
   缺口 → 最小注入方法（用我們環境的既有能力：tc netem / 電源 helper / kill by pid）
2. **建議清單 3–5 條**，按 價值/成本 排序，每條含：第一步指令、預期第一個產出、
   對接哪一層（L0-L4 或新層）
3. **不建議清單**：明確列出「看過但不適合」的工具與一句話理由（省之後重查的時間）
4. 全文區分【來源說了什麼】與【我推論它對我們的意義】；每個外部宣稱附連結；
   讀不到原文的標「未驗證」。

### 紀律

- 寬度上限：任務 B 每個框架最多 30 分鐘等值的深度，先廣後深；發現金礦再深挖。
- 邊做邊寫，每完成一個小節就落檔，不要最後一次寫。
- 禁止：pip install、修改 repo、碰 localhost 任何 port、開 issue/PR。
