# 指導教授審閱：大四學生四年內投 EuroP4'26 Poster 的總體評估

**情境時間：2026-08-28 深夜｜截止：2026-09-01（四天後）｜審閱身分：網路系統領域指導教授**
**審閱方法：依序讀完六份必讀文件全文（VERDICT.md / GAP.md / RELATED-WORK.md / SEARCH-ROUND-1.md / 2026-08-28_bmv2-throughput-literature-vs-ours.md / 2026-08-15_bmv2-performance-report.md），並抽檢 audit-raw / binary-provenance / PREREG / HANDOFF-CONTEXT 等支撐文件；所有判斷標〔OBSERVED〕/〔INFERRED〕/〔GIVEN〕並註出處**
**標註約定：〔O〕= 文件裡讀到的原文或可重現的數據；〔I〕= 我的判斷/推論；〔GIVEN〕= 題目給定的場地事實（無法上網驗證，照單全收）**

---

## 0. 總體先給答案（不繞圈子）

**有條件投，條件很硬；條件不滿足就現在放棄，改走 arXiv＋下一輪。**

〔O〕這份工作的「文獻審計」是實的：14+3 篇逐篇閱讀、對 build/變體/版本/pps/流數五軸掃關鍵詞、可重跑腳本 `sweep_keywords.sh`、逐篇行號引註，且第一輪檢索（3 篇新候選）全數存活、三個宣稱未被打掉（`SEARCH-ROUND-1.md §2-§3`）。〔O〕本機 A/B 是實測：同機、同 10-switch stack、同腳本、stock vs bmv2-fast 差 12-18×（UDP 天花板 12-13×、TCP 17.8×、64B pps 14×），且有原始碼層機制支撐（`-O0` + logging 巨集在 match/parser 熱點做 null-sink 格式化，`2026-08-15 報告 §成因三層`）。〔I〕兩者合起來，「審計＋recipe」的 poster 形狀在 EuroP4 場子是對的題目。

但〔I〕**四天內能誠實產出的是一個「初步結果 poster」，不是「三個宣稱都站住的 poster」**。差別在於學生願不願意在 2 頁 abstract 裡把所有已知弱點自揭到讓審稿人打不動。最傷的不是被拒，而是投出一個宣稱超過資料的版本——EuroP4 是 P4 社群的小場子，被點名的每一篇作者都可能是你的審稿人或台下聽眾。

一句話給學生：**你的文獻審計已經可以做 poster；你的量測目前只能做 poster 的 motivation。把兩者誠實分開寫，就值得投。**

*與 VERDICT.md 的關係：我同意其「角度成立、措辭停在互相不可比較、不能清單」的全部（`VERDICT.md §本輪能/不能`），但不同意其「動筆前至少要補單 switch 隔離、完整掃描、中間流數與重複數」作為 poster 前置——那是 journal/full-paper 前置。Poster 的不可協商門檻應移到別處：宣稱口徑與 raw 存檔。詳見 §1.3 與 §2。*

---

## ① 題目深度／創新性：審稿人最可能打哪裡

### 1.1 先說成立的部分（不是啦啦隊，是有出處的）

*〔O〕文獻缺口經得起查。* 量過 bmv2 的 9 篇中，build flags / optimization level **0/9**、build 對照實驗 **0/9**、變體載明 2/9、版本載明 1/9（`RELATED-WORK.md §1 主表 §3 統計`；`VERDICT.md §本輪能支持`）。檢索關鍵詞表與重跑腳本在 `sweep_keywords.sh`，逐篇行號在 txt 轉檔後可驗。第一輪系統性檢索加 3 篇（Waind & Jin PADS'26、Fernando MDPI Network 2025、P4Docker）**全數存活**，0 篇給 flags、0 篇對照，且兩篇強化論點（`SEARCH-ROUND-1.md §2-§3`）。

*〔O〕數字落差與歸因真空。* 9 篇的 bmv2 吞吐橫跨 0.57 Mbps（TSSA 64B）→1.4 Gbps（ICNCC）≈ **~2,500×**（`RELATED-WORK.md §3`；`VERDICT.md:5`），且零篇給出足以重建 binary 的資訊，任兩個數字**無法判定是否量了同一個東西**（`GAP.md §1 淨效果`）。最接近的只有 ICNCC 一句「不產生 log 的模式編譯」（`RELATED-WORK.md ICNCC 列`），無 flags、無 -O level、無對照；兩篇引了載有官方 flags 的 `performance.md` 仍未報告自己 build（`GAP.md §1`）。

*〔O〕本機 12–18× 是實測且有機制。* 同機同 10-switch fabric 同腳本 A/B：UDP delivered 天花板 12–13×、TCP 17.8×、64B pps 14×、閒置 RTT 3.3×（`2026-08-15 報告 §本機飽和實測 表`；`2026-08-28_vs-ours.md §3-1 表`）。原始碼層「成因三層」已定位：`-O0` 讓 GMP Bignum accessor 全成真呼叫、每次查表/命中/parser 狀態做 `ostringstream` 格式化丟 null-sink、`--log-level off` 救不回來唯有編譯期 `--disable-logging-macros`（`2026-08-15 報告 §成因三層 第1層`，引 `match_units.cpp:783`、`match_tables.cpp:116` 等）。

*〔O〕措辭降級是生存關鍵。* `VERDICT.md §我推翻 auditor 立場` 正確把「已發表數字全都不可複現」降為「**互相不可比較／不可歸因**」，理由：ICNCC 有質性揭露、我們沒重現過任何一篇。Poster 若用前者，一句反例即死；用後者，審稿人打不動。

*〔O〕兩個「資料裡有、結論裡沒有」的現成展品。* TSSA 的 64B/128B 兩點換算後 ~1.0–1.1 kpps 近恆定，論文未算、歸因錯誤（`GAP.md §2` 引 `TSSA txt 371–378`）；Waind & Jin PADS'26 與 PADS'24 同實驗室每-switch RTT 差 1.7×（1.217 ms vs 729.4 µs/switch，皆無 build）──「不可比較在同一實驗室內部成立」（`SEARCH-ROUND-1.md §2 表`）。

*〔I〕場域適配度。* EuroP4 poster 歷屆收 work-in-progress、2 頁 extended abstract、進 ACM proceedings 帶 DOI〔GIVEN〕；「社群預設交換器被量成 2,500× 落差、零篇報 build」是 P4 社群會在乎的 hygiene 故事，尺寸正好是 poster，不是 full paper。

### 1.2 審稿人最可能打的五個點（按殺傷力排序）

**攻擊 1：「官方 performance.md 早就寫了 flags，換 build 不是創新。」**
〔O〕官方 `performance.md` 的建議旗標（`-O3 --disable-logging-macros --disable-elogger`）確實存在，ICNCC 與 TSSA 引了它仍未報自己 build（`GAP.md §1`；`RELATED-WORK.md §1`）。〔O〕學生自己已提出「改 build 不是創新」的疑慮（題目「已知弱點」）。〔I〕這是繞不開的第一槍。反制不是否認，是**重新定位**：貢獻不是「發現 flags 有用」，是**量出這個從未被報告的變數值 12–18×，足以吞掉語料自陳 40M–1G 範圍的大半，且語料無人控制**，並以 measurement-bias 前例（Mytkowicz et al. ASPLOS'09）為辯護——同屬「把隱藏的量測偏置量化並給 recipe」這類貢獻。〔I〕Abstract 的 novelty 句若不自己先寫這句，會被審稿人第一頁擋掉。

**攻擊 2：「你的 12–18× 不是單變數實驗，是六個旋鈕的複合差距。」**
〔O〕兩顆 binary 差異是六旋鈕同動：stock = `-O0 -g` + logging macros on + elogger on；fast = `-O3 -g -DNDEBUG -march=native -fno-semantic-interposition` + 兩者皆 off（`doc/audit/bmv2-binary-provenance.md 表`）。兩者 `--version` 同印 `1.15.3-f0b7d201`（`bmv2-binary-provenance.md`），本身是好故事，但口徑「build flags 值 12–18×」是過度簡化。〔O〕08-15 報告自承兩輪差異是「編譯期把 logging 移除」與 `-O0` 的疊加，主解配方 `build_bmv2_fast.sh` 即此複合（`2026-08-15 報告 §解方`）。〔I〕Abstract 必須寫「**p4-guide 預設 debug build vs 官方建議效能 build 的複合差距**」，不能寫「-O3 值 12–18×」。逐旋鈕二分（單關 macros、單改 -O3）無資料，別承諾也別暗示。這是 `VERDICT.md` 未點出的口徑缺口。

**攻擊 3：「16 流塌 3.3× 的兩端不在同一條曲線上，且解析度只有 2×。」**
〔O〕既有 1 流點與 16 流點擺位不同：16 流分散在 4 個 path class，flows-per-switch 與 flows-per-link 碰巧同值；PREREG 註冊「全部擺在 h1→h65 單一路徑 s1→s3，使 flows/switch = flows/link = n」才可比，舊 16 流點**不得畫在同一曲線**（`PREREG.md §2 表`；`HANDOFF-CONTEXT.md §4`）。〔O〕兩端皆為幾何階梯最高無損 rung：1 流梯 `5 10 20 … 160 320` ⇒ 真值 ∈[160,320) 為 **2× 區間**；16 流梯 `30 10 5 3` ⇒ 每流 ∈[3,5)（`PREREG.md §3`）。〔O〕PREREG 已註冊新梯 `1 2 3 5 8 12 … 240`（×1.5，±20%）且重測 1 與 16，但 **no traffic has been sent. No data exists**（`HANDOFF-CONTEXT.md §1`）。〔O〕「12 Mbit 四流」已更正為除法推導非量測（`PREREG.md §1` 引 commit `6d67d45`）。〔I〕如把 160→48 M 直接畫成「3.3× 塌陷曲線」，方法論審稿人（尤其 Chen 組）可當場拆掉。這是三宣稱中最脆弱的一塊，優先級高於 pps 掃描。

**攻擊 4：「OVS 對照臂不是同工作點。」**
〔O〕bmv2 臂乾淨點 3 M/流、OVS 臂 30 M/流；OVS 臂在帶 htb shaping 的 as-configured 狀態量；H1a（datapath）vs H1b（shaper）未分離（`2026-08-28_vs-ours.md §3-3 表`；審計補件 `04_ovs_result.md §5-§6` 記載）。〔I〕不能寫「同工作點」，要寫「**各自 drop-free 的每流工作點**」（OVS 30 M、 bmv2 3 M），並在圖註標明帶 shaping。此攻擊可防，但現口徑（題目一段話「同工作點不塌」）不行。

**攻擊 5：「否定句只有 17 篇效力，讀起來像全文獻；且 2,500× 的主詞錯。」**
〔O〕一切否定句主詞是「這 14+3 篇」而非全文獻，`SEARCH-ROUND-1.md §4` 自列未查：TOMACS/ICNCC cited-by、Google Scholar 全文、dblp、p4-dev。〔O〕語料成分混雜：9 篇量 bmv2、5 篇 survey/方法/非 bmv2、含 arXiv、碩士論文（`RELATED-WORK.md §0 表 §3 統計`）。〔O〕2,500× 是 9 篇有量者的跨度，非 17 篇（`RELATED-WORK.md §3`）。〔O〕「兩篇排序相反」機制不同：Fernando 的 SDN+P4 > SDN+OvS 反轉來自 ONOS reactive 的 ARP/LLDP 繞控制器，非 datapath 對照，工作點 6.3 Kbps–96 Mbps 遠離任一 datapath 天花板（`SEARCH-ROUND-1.md §2 Fernando 列`）。〔I〕Poster 可寫「in our corpus of 17」並精準寫「兩篇同儕審查結論排序相反，且雙方皆無 build 資訊」；寫成「兩顆 datapath 量出相反結論」是過度宣稱。

### 1.3 我與 VERDICT.md 的明示異同

*〔I〕同意*：角度成立；「互相不可比較」措辭；「能/不能」清單每一條；對 TOMACS 收編為「TDF runtime ∝ 效能缺口，build 快 12–18× ⇒ 所需 TDF 同除」的互補寫法（`GAP.md §4-9`、`VERDICT.md §5`）。

*〔I〕部分不同意*：`VERDICT.md:5 但書`「動筆前至少要補單 switch 隔離、完整包長掃描、中間流數與重複數」——這是 full-paper/workshop-full 的前置，不是 2 頁 poster 的前置。Poster 定位即 preliminary，我把不可協商門檻移到：**宣稱口徑**（複合 build、17 篇範圍、兩點 pps、端點同擺位）與 **raw 存檔**（見 §2.3）。此外 VERDICT 未點出攻擊 2（六旋鈕）與攻擊 3（16 流擺位不同）的具體口徑陷阱，此為本審閱的增補。

*〔I〕補充*：若把「12–18×」「pps 恆定」「3.3× 塌陷」三件並列為等權重主貢獻，會分散焦點。Poster 應以 **① build 審計 + 12–18× 複合差距 + 四行 provenance recipe** 為主論點，② 與 ③ 為「機制與帶對照的初步證據」——審稿人對主論點的容忍度遠高於對 16 流曲線的容忍度。

---

## ② 時間急迫性：四天內該做什麼、放棄什麼、哪些弱點必須在 abstract 裡自揭

### 2.1 現實盤點〔O〕

*截止與物流。* EuroP4'26 poster/demo 截止 9/1〔GIVEN〕，今天 8/28 深夜〔O：VERDICT/GAP 建立日皆 2026-08-28，PREREG 當晚註冊〕，**實剩 3.5 個工作天**。投稿入口尚未公布、已去信兩位 chair 詢問未回〔GIVEN〕→ 最後 24–48 小時可能耗在物流，寫作必須 8/30 前定稿，否則最後一天只能空等入口。

*寫作起點。* Repo 內無任何 poster/abstract 草稿：`doc/` 全文無 `EuroP4`/`poster`/`extended abstract` 命名的檔案（`list_dir doc/`、`list_dir doc/audit` 目錄清單）；策展表、GAP、VERDICT、兩份量測報告與 PREREG 皆為現成素材，但** 2 頁 abstract 需從零壓縮**。〔O〕

*量測現況。* 12–18× 來源為 2026-08-15 A/B 兩輪，n=1–2、單機、單拓樸（10-switch fabric，iperf 走 h1→h2 經 s1→s5→s2 的 3-hop，生產態含 kernel 輪詢與 sFlow clone），方法段載明「`bmv2_binary_override` 為唯一差異、`/proc/<pid>/maps` 實證零 stock 庫映射」（`2026-08-15 報告 §本機飽和實測 方法`）。但**原始 JSON 在 session scratchpad、`session 結束即失效`**（同報告「原始 JSON 與 per-switch 證據」段自述），audit-raw 分支上有 08-28 的 jitter/capacity/OVS raw，**沒有 08-15 的**。〔O〕換言之，最核心的 12–18× 目前在 repo 內無可解析的 raw 可供審稿人追溯。

*中間流數。* PREREG（n=2/4/8 + 重測 1/16，同梯 ×1.5、兩臂、鏡像順序 `1 2 4 8 16 | 16 8 4 2 1`、雙 readout）已註冊完成，fabric 當下即為所需狀態（`/usr/local/bmv2-fast`、10 switches、manifest 已寫）（`HANDOFF-CONTEXT.md §1`），但**零封包已送、零資料存在**（同 §1 粗體）。PREREG 自估「流量時間 ~40 分鐘」（§6），但含兩臂、交錯、load1/ /proc/stat gates、禁窗內 commit 等，實為半天工作量。〔O〕

*並行交付。* 學生手上有 9/03 內部 deck，且圖「從未確認能 render」（matplotlib 全機缺席、無 PNG 輸出，兩次 commit 對 render 的陳述矛盾）（`HANDOFF-CONTEXT.md §6`）。四天投入 poster，內部交付必然吃緊。〔O〕

### 2.2 四天計畫（寫作永遠優先於實驗）

| 天 | 做什麼 | 不做什麼 |
|---|---|---|
| **D1 8/29 上午** | **先與指導教授談**（見 §5 C1）。取得署名/affiliation/AI 揭露同意前，**一個字不送出**。會談帶 VERDICT/GAP/RELATED-WORK 三檔與本審閱 §1.2 的五個攻擊清單去，證明你知道弱點在哪。 | 不碰任何實驗、不開始系統性檢索 |
| **D1 8/29 下午** | 寫 abstract 骨架：related-work 段直接濃縮 `RELATED-WORK.md §1-§3` 的統計；claim 句逐句對 §1.2 口徑（複合 build、17 篇範圍、兩點 pps、16 流 preliminary）。 | — |
| **D2 8/30** | 完成 abstract 全文 + 圖（圖可用文字表先占位）。**若 lab 有空檔且 abstract 已定稿**，跑最便宜的一項：**封包大小掃描 64→1400 B**（兩 build 各一條曲線，把「兩點」升成曲線；`GAP.md §4` 標 🟢，成本低於 P1-3）。同時**重跑一輪 A/B 並按 audit-raw 規矩存 raw**（見 §2.3 第6條）。 | 不跑 P1-3，除非 D2 定稿已完成 |
| **D3 8/31** | 定稿、排版成 2 頁 extended abstract；投稿物流待命（入口未開則備 email 提交方案，並向 chair 確認收件方式）。PREREG 若在 D2 已啟動，D3 內完成一臂亦可，但**不新增宣稱**。 | 不擴大語料、不新增「變體×build 2×2」「jitter」等 |
| **D4 9/1** | 截止日緩衝（入口延遲、格式修正、取得教授最終簽字）。 | — |

### 2.3 必須在四天內放棄的（不是不重要，是放不進 2 頁/四天）

*〔I〕系統性檢索補完*（TOMACS/ICNCC cited-by、Google Scholar 全文、dblp 目錄、p4-dev 郵件列表；`SEARCH-ROUND-1.md §4` 清單）。四天做不完，誠實寫「one-round corpus of 17」即可；把「未系統性檢索」寫進 limitation，比假裝做過更能過審。

*〔I〕變體×build 2×2*（`GAP.md §4-4` 🟡）、*規模 vs 流數解耦*（§4-5 🟡）、*jitter 軸*（§4-6：bmv2 上判別法結構性無適用域，`vs-ours.md §4` 已裁定此輪無適用域）。這些是 full-paper 題目。

*〔I〕單 switch 隔離工作點*——若 harness 無法半小時內起 1-switch 拓樸就放棄，在 limitation 寫明「3-hop 生產 stack、未隔離」（`VERDICT.md §5 但書` 所憂）。Poster 容許誠實的不隔離，full-paper 才不容許。

*〔I〕一切「量測→模型」與「儀器效度」敘事*（`GAP.md §4-7/4-8 🔵`），留一句給 NDTwin 定位即可。

### 2.4 中間流數 P1-3 的精準處置〔O+I〕

P1-3 是唯一「半天內能讓最脆弱宣稱翻盤」的實驗（§1.2 攻擊3）。處置原則：

* **有餘力才跑**：D2 abstract 定稿後才啟動；PREREG 禁「量測窗內 commit」（`PREREG.md §6`；`HANDOFF-CONTEXT.md §4` 載明 commit 背景 `agy` 占 54.7% 核），違反此規矩跑出的資料寧可不要。
* **跑出來 vs 跑不出來皆加分**：跑出來→把 ③ 從「兩端點」升級為「曲線」；跑不出來→在 abstract 標「preliminary endpoints + pre-registered replication in progress (PREREG committed pre-data)」，此為 EuroP4 少見的加分項（社群少有 poster 附 PREREG）。
* **口徑紀律**：新 n=16 與舊 16 流不得同圖；新曲線 x 軸為 flows/switch（=flows/link，因單一路徑），舊 16 流僅作 secondary observation（`PREREG.md §2`）。

### 2.5 Abstract 必須自揭的弱點（一條都不能省）

以下每一條皆為〔O〕已知弱點或 repo 已註冊的限制，abstract 的 limitation 段必須逐條出現，缺一條即多一個被審稿人追打的面：

1. **語料範圍**：17 篇、非系統性檢索（one-round）、所有否定句主詞為 `in this corpus`（`SEARCH-ROUND-1.md §4`；`GAP.md §1 我沒查到的範圍`）。
2. **12–18× 的邊界**：單機、單拓樸、n=1–2、3-hop 生產 stack（kernel 輪詢與 sFlow clone 照常）、**六旋鈕複合差距**（`bmv2-binary-provenance.md`），不可外推（`VERDICT.md §不能` 第二條）。
3. **pps 恆定**：目前僅兩點（stock 3.66k vs 3.62k；fast 64B 50.8k；`2026-08-15 報告 §機制`），D2 掃描若成則升級，不成則照實寫兩點；可並列 TSSA 內部兩點換算 ~1.0–1.1 kpps 作為文獻內 anchor（`GAP.md §2`）。
4. **流數塌陷**：兩端同為階梯最高無損 rung（解析度 ±2×/±20% 取決於梯子）、**擺位不同**（舊 16 流分散 4 path class）、機制部分實證（10 burner 把 3 M/流從 0.000% 推到 2.192% loss，`01_capacity.md`）+ 部分推論（每流查表成本的定量模型未測，正是 PREREG 要測的）。
5. **OVS 對照**：各平面各自的 drop-free 工作點（bmv2 3 M/流 vs OVS 30 M/流）、帶 htb shaping、H1a/H1b 未分離（`vs-ours.md §4`）。
6. **Raw 存檔的自嘲點**：08-15 A/B 原始 JSON 已失效（session scratchpad），投稿前至少重跑一輪並按 `audit-raw` 規矩存好（`HANDOFF-CONTEXT.md §4`；pre-commit hook `f1df56e`）。Provenance 論文自己不留 raw，會在 Q&A 被一擊反殺——此條 `VERDICT.md` 未提，我列為必要條件。
7. **否定句僅 17 篇效力**與**文獻偏差前例的性質**：不宣稱「文獻裡沒人」、不宣稱「官方沒寫」，只宣稱「corpus 內無人報告/對照」；Mytkowicz 僅作 measurement-bias 類比，非等同。
8. **作者與 AI 揭露**：AI 輔助撰寫依 ACM 政策揭露，affiliation 與作者序經教授同意（見 §5 C1）。

〔I〕自揭不是示弱，是審稿策略：EuroP4 poster 的審稿人對「誠實的 preliminary」容忍度高，對「隱藏的不確定性」容忍度為零。你把刀遞給他，他反而不好砍。


---

## ③ 值不值得：對一個要申請碩士的大四學生，期望值 vs 成本（含 12 月到不了場的情境）

### 3.1 成本面〔O+I〕

*〔O〕邊際工時。* 素材已齊：14+3 策展表、`sweep_keywords.sh` 可重跑、四行 provenance 配方、A/B 數字與機制、PREREG。写作是壓縮而非創作。〔I〕實需 1.5–2 個工作天寫作 + 0.5 天實驗緩衝（封包掃描與/或重跑 A/B 存 raw），總計約 2–2.5 天。若 D2 才啟動 P1-3，成本再 +0.5 天。相對於從零做一個新題目，成本偏低。

*〔O〕機會成本。* 9/03 內部 deck 同時待交，且圖從未確認能 render（`HANDOFF-CONTEXT.md §6`）。四天投入 poster，內部交付必然被擠壓；若兩者皆由同一位學生負責，教授最可能關切的是這個衝突，而非 poster 題目本身。〔I〕這是明天會談必須主動揭露的第一個成本，否則會被視為時間管理失誤。

*〔O〕直接成本。* 差旅未定〔GIVEN〕；Utrecht 12/7 與 CoNEXT 共站〔GIVEN〕，機票住宿與註冊費對大學部是一筆實支。〔I〕若無經費或簽證時間，需在 9/1 前問清，否則期望值計算失真。

### 3.2 收益面〔GIVEN+I〕

*〔GIVEN〕時機剛好。* 通知 9/14、workshop 12/7，多數碩士申請落在 11 月–次年 1 月，**9/14 就知道結果**，錄取即可在申請表上寫「EuroP4'26 poster (ACM proceedings, DOI)」。即使被拒，四天成本亦換得一次真實審稿回饋，對下一輪（SOSR/ANRW/下一屆 EuroP4）是正向累積。〔I〕對大學部而言，這是履歷上少見的「同儕審查 + DOI」一行，且題材（量測 hygiene / provenance）能直接展示方法紀律，對申請「系統/網路」方向的碩士有對口加分。

*〔GIVEN〕場地特性。* 歷屆 2 頁 extended abstract、poster 進 proceedings 帶 DOI（'23 屆全場 12 篇含 4 poster+1 demo）〔GIVEN〕→ poster 被視為正式發表但分量輕於 full paper，審查對 preliminary 的容忍度高於期刊。〔I〕此題材的「審計 + recipe」形狀天生適合 poster，不必硬撐成 full。

*〔I〕替代路徑的收益對比。* 不投 EuroP4，材料整理為 arXiv 技術報告 + 完成 P1-3/封包掃描/系統性檢索後的下一輪投稿，科學價值更高、但**申請時程上慢一個週期**。若學生今年就要申請，EuroP4 的 9/14 通知是無法被 arXiv 取代的時間收益；若申請在一年後，等待的收益更高。

### 3.3 12 月到不了場：期望值計算的決定項〔GIVEN+I〕

*〔GIVEN〕ACM 慣例 no-show 會被抽出 proceedings。* 這不是「少一次報告」，是**錄取後被抽掉 DOI**，等於把已到手的發表再拿走，且在小社群留下負面紀錄。〔I〕因此決策不是「先投再說」，而是**在 9/1 前把 12/7 到場可行性問成是/否**：

- 經費：系上/實驗室/學校補助是否可覆蓋 Utrecht 差旅，或是否可由共同作者代報；
- 規範：chair 是否允許遠端或他人代報（題目未給此資訊，**不能猜**，必須等兩位 chair 回信〔GIVEN〕）；
- 學業：12 月是否與期末/考試衝突。

*〔I〕期望值分岔：*

- 若 9/1 前答案為「很可能到不了」→ **不投**。此時投的期望值為負：被拒為零，錄取後 no-show 為負（占 slot、被抽 proceedings、社群記憶）。與其賭，不如改走 arXiv + 下一輪。
- 若 9/1 前答案為「可到」或「可代報且獲 chair 書面同意」→ 期望值為正，值得投（成本 2 天換一次審稿 + 可能的 DOI）。
- 若到 9/14 通知時仍不確定 → **收到錄取立刻主動撤回，優於 no-show**，但最佳策略是根本不讓自己走到這一步——9/1 前就要有答案。

*〔I〕cannot determine, would need X：* 我無法判定本屆 poster 的錄取率與 chair 對代報/遠端的政策，前者需歷屆議程與投稿數，後者需 chair 回信；兩者皆為本審閱無法上網驗證的外部事實，只能以 9/1 前的書面確認為準。

### 3.4 小結〔I〕

對要申請碩士的大四學生，若**到場可行且教授同意**，此 poster 是低成本、正期望值的交易（2 天換一次真審稿 + 可能的 DOI，且 9/14 即知結果趕得上申請）；若**到場不可行**，期望值轉負，不值得投。關鍵不在題目，在物流。

---

## ④ 風險：學術與社交（含「教授會不會覺得癡心妄想」）

### 4.1 學術風險

**風險 1：審稿人就是被點名的作者〔I〕**
語料中 Chen/Hu/Jin 組占 4 篇（PADS'23 / TOMACS'25 / PADS'24 / PADS'26），EuroP4 PC 與 SIGSIM-PADS/P4 社群高度重疊，審稿人是被審作者的機率不低。〔I〕風險不在「被記恨」，在「對方一眼看穿你的方法漏洞」——攻擊 2–4 皆為此類。解方是 `VERDICT.md` 已採的措辭紀律：只說「互相不可比較」，不說「不可複現/不可信」；只說「corpus 內無人報告」，不說「你們的量測是錯的」。前者是事實陳述，後者是價值判斷，兩者不可互相推導。

**風險 2：自己翻車的風險大於被拒的風險〔I〕**
此工作的賣點是方法紀律（OBSERVED/INFERRED 分標、逐篇行號、PREREG、audit-raw 存檔），任何一處宣稱超過資料（如把除法推導的 12 Mbit 當量測、把擺位不同的 16 流端點同圖、把六旋鈕複合講成單一 flags）都會在 Q&A 被現場拆穿，對學生與實驗室的信譽傷害大於一次拒稿。〔I〕四天內「少寫」遠比「多寫」安全。

**風險 3：檢索不完備被抓漏〔O+I〕**
`SEARCH-ROUND-1.md §4` 自列未查清單；`RELATED-WORK.md §4-1` 已發生過關鍵詞假陰性（ICNCC 質性敘述不在表內）。〔I〕「0/17 報 flags」靠策展複驗撐住，但語料外是否有人做過 build 對照，我無法斷言（would need：Google Scholar 全文 + dblp + p4-dev 掃描）。Poster 寫「in this corpus」即可免疫，寫「no prior work」即暴露。

**風險 4：工具與方法的可追溯性〔O〕**
08-15 raw 已失效（`2026-08-15 報告` 自述）是 provenance 論文的最大反諷；若投稿前未重跑並按 `audit-raw` 規矩存檔（`HANDOFF-CONTEXT.md §4`；pre-commit hook `f1df56e`），Q&A 第一問即「你們指控別人不報 build，自己連 raw 都丟了」——一擊反殺。〔I〕此風險可歸零，成本半天。

### 4.2 社交風險

**「教授會不會覺得癡心妄想？」——不會，但會覺得順序錯了〔I〕**
讀完這批 audit，任何教授對學生的判斷力都不會搖頭：OBSERVED/INFERRED 紀律、逐條更正（如 12 Mbit、venue 誤記）、PREREG 預先註冊「若外即棄」的誠實，皆在水準之上。〔I〕會皺眉的是三個順序問題：(a) 距截止四天才告知（`GIVEN：指導教授還沒被告知，學生明天才要談`）；(b) 無草稿卻要從零寫 2 頁；(c) 同時卡 9/03 內部交付。學生的自疑「改 build 不是創新」反而顯示校準良好，教授更可能視為成熟而非自卑。真正的社交風險只有兩條，且皆可控：

- (a) **未經同意以實驗室 affiliation 投稿**——明天會談前一個字都不准送出（見 §5 C1）；
- (b) **因 poster 耽誤 9/03 交付而不先講**——明天一併攤開時程，讓教授決定優先級。

兩條在明天的談話裡即可消掉。〔I〕作者排序與 AI 揭露亦需同場議定：repo 大量標 `Co-developed with claude code`（`GAP.md`/`VERDICT.md` 末行），投 ACM 需依政策揭露 AI 輔助，作者欄大概率為學生 + 教授，此須教授同意。

**風險 5：社群記憶〔I〕**
EuroP4 是小場，poster 雖輕但進 proceedings 帶 DOI〔GIVEN〕。一篇誠實的 preliminary 會被記為「那個把 bmv2 build 審計做得很乾淨的學生」；一篇過度宣稱的 poster 會被記為「那個拿 n=2 就當曲線的」。兩種記憶皆持久，前者有助申請，後者有害。

---

## ⑤ 最終建議：有條件投（條件明列）——投／不投／有條件投的唯一可辯護答案

### 5.1 建議：有條件投

**若且唯若以下 C1–C5 全部滿足，才投 EuroP4'26 poster；任一條失敗，改走 arXiv + 下一輪（EuroP4/SOSR/ANRW），材料放一個月會變強，擠四天只會變弱。**

| 條件 | 具體內容 | 未滿足時的處置 |
|---|---|---|
| **C1 教授同意** | 8/29 上午會談取得：署名與 affiliation 同意、作者順序、AI 輔助揭露方式、以及「投稿不影響 9/03 交付」的時程共識。會談攜帶 `VERDICT.md`/`GAP.md`/`RELATED-WORK.md` 與本審閱 §1.2 五攻擊清單，證明你已自揭弱點。 | 未取得前**不送出任何東西**。 |
| **C2 到場可行性** | 9/1 前有 12/7 Utrecht 的到場方案：經費到位，或 chair **書面**允許遠端/他人代報。投稿入口未公布期間，同步確認「若入口延遲，email 提交是否被接受」。 | 若 9/1 前答案為「很可能到不了」，**不投**。若 9/14 錄取後才發現到不了，**主動撤回優於 no-show**（no-show 會被抽 proceedings〔GIVEN〕）。 |
| **C3 宣稱口徑** | Abstract 逐句符合 §1.2/§2.5：寫「p4-guide 預設 debug build vs 官方建議效能 build 的**複合差距** 12–18×」、寫「in this corpus of 17」、寫「兩點 pps（或掃描升級後的曲線）」、寫「16 流端點為 preliminary + PREREG in progress（新舊 16 流不共圖）」、寫「OVS 為各自 drop-free 工作點（3 vs 30 M/流）、帶 shaping、H1a/H1b 未分離」。任何一條做不到自揭，就刪該宣稱。 | 做不到自揭的宣稱**整句刪除**，不留模糊空間。 |
| **C4 Raw 存檔** | 投稿前至少重跑一輪 A/B（stock vs fast），raw 按 `audit-raw` 規矩存好（`HANDOFF-CONTEXT.md §4`；hook `f1df56e`），binary 以 `bmv2-binary-provenance.md` 的 sha256/BuildID 可追溯。08-15 資料若未重跑，則在文中標為 `report-only, raw unavailable (session expired)`。 | 未存 raw 即投＝Q&A 自殺，**不投**。 |
| **C5 寫作優先** | D1 起先寫後量；D2 封包掃描與可能的 P1-3 皆為「有餘力才做」，絕不讓實驗吃掉定稿時間；D3 定稿凍結，不新增宣稱。 | 實驗吃掉寫作→**棄實驗保寫作**。 |

### 5.2 若不投，怎麼走更有價值〔I〕

* 兩週內完成：封包大小完整掃描（兩 build）、P1-3（n=2/4/8 + 重測 1/16）、單 switch 隔離工作點（若 harness 支援）、系統性檢索補完（cited-by + dblp + Scholar 全文）。
* 整理為 arXiv 技術報告（附 audit-raw 與 PREREG），投稿下一輪 EuroP4 full/demo 或 SOSR/ANRW workshop。此路徑的科學分量與申請說服力皆高於一篇倉促的 poster，且無 no-show 風險。

### 5.3 明天與教授的會談清單（帶去，一次談完）

1. 題目與定位：是否同意以「審計 + 12–18× 複合差距 + 四行 recipe」為主、②③為 preliminary 的 poster 去投 EuroP4 poster track？
2. 作者與揭露：作者序、affiliation、AI 輔助揭露（`Co-developed with claude code`）的寫法。
3. 時程衝突：9/03 內部 deck 與 9/01 截止的優先級，哪個先？
4. 差旅：Utrecht 12/7 的經費/代報/遠端可能性，以及若錄取後無法到場的撤回共識。
5. 口徑：是否同意 abstract 自揭 §2.5 八條弱點（尤其是複合 build、16 流 preliminary、raw 重跑）？

---

## 附：關鍵引用對照（會談時快速查證）

| 宣稱 | 出處 |
|---|---|
| 0/9 報 flags、0/9 對照、~2,500×、變體 2/9、版本 1/9 | `RELATED-WORK.md §1 主表 §3 統計` |
| 措辭降級為「互相不可比較」 | `VERDICT.md §我推翻 auditor 立場` |
| 12–18× 與兩點 pps、3-hop 方法、原始 JSON 失效 | `2026-08-15_bmv2-performance-report.md §本機飽和實測 §數字對帳` |
| 六旋鈕複合、--version 相同 | `doc/audit/bmv2-binary-provenance.md 表` |
| 16 流舊端點擺位不同、階梯 ±2×、PREREG 零資料、12 Mbit 為除法 | `PREREG.md §1-§3`、`HANDOFF-CONTEXT.md §1 §4`、commit `6d67d45` |
| OVS 各自工作點 3 vs 30 M/流、帶 shaping、H1a/H1b 未分離 | `2026-08-28_vs-ours.md §3-3 §4`；補件 `04_ovs_result.md` |
| 檢索未完成清單 | `SEARCH-ROUND-1.md §4` |
| 9/03 deck 圖未確認 render | `HANDOFF-CONTEXT.md §6` |

---

*審閱結束語：這是一個「題目對、材料實、時間緊、口徑險」的典型 workshop 投稿。你不需要證明 bmv2 很慢，也不需要證明別人錯了；你只需要證明「這個社群有一個沒人報告的變數值 12–18×，且你能量出來、能給 recipe、能誠實說出邊界」。做到這句，四天就值得；做不到，老實等下一輪。*

