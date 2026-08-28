# 指導教授審閱：EuroP4'26 poster 投稿案（bmv2 量測 hygiene 題材）——四天截止前的最嚴苛版評估

**審閱日（情境內）：2026-08-28 深夜。** 截止 9/1（四天後）。
**標註約定**：〔O〕＝文件/程式碼裡讀到的；〔I〕＝我的判斷或推論；〔GIVEN〕＝題目提供的場地事實（無法上網驗證，照單全收）。文獻側事實來源＝`doc/audit/2026-08-28_bmv2-literature-review/` 四檔（策展版），本機量測事實＝`doc/2026-08-15_bmv2-performance-report.md` 及 8/28 各 audit 目錄。

---

## 總體判斷（先給答案）

**有條件投，條件很硬；條件不滿足就現在放棄、改成 arXiv＋下一輪，而不是硬投。** 題材是真的、審計是實的、判斷力（OBSERVED/INFERRED 紀律）在水準之上；但**四天內能產出的是一個「誠實的初步結果 poster」，不是一個「站得住的三宣稱 poster」**——兩者的差別在於學生願意在 abstract 裡自揭多少。最傷的不是被拒絕，而是投出一個宣稱超過資料撐得住的版本：EuroP4 是 P4 社群的小場子，被批的每一篇文獻作者都可能是你的審稿人或台下聽眾。

一句話給學生：「你的文獻審計可以做 poster；你的量測目前只能做 poster 的 motivation。四天內把兩者誠實地分開寫，就值得投。」

---

## ① 題目深度／創新性：審稿人最可能打哪裡

### 1.1 先講成立的部分（這些是真的，不是啦啦隊）

〔O〕文獻缺口經得起查：9/14 篇量過 bmv2 者 **build flags 0/9、build 對照 0/9**、變體 2/9、版本 1/9，逐篇證據在 `RELATED-WORK.md` §1–3，repo 內有 `sweep_keywords.sh` 與四份 `hits_*.txt` 可重跑；檢索第一輪新增 3 篇全數存活（`SEARCH-ROUND-1.md`）。
〔O〕9 篇吞吐數字橫跨 ~2,500×（0.57 Mbps→1.4 Gbps）且「以各篇自己提供的資訊無法互相歸因」——這是主論點的骨架（`VERDICT.md:5`、`RELATED-WORK.md` §3）。
〔O〕本機 A/B 是實測不是臆測：同機同 stack 同腳本，stock vs fast 差 12–18×（UDP 天花板 12–13×、TCP 17.8×、64B 14×），且有來源碼層機制（`-O0`＋logging 巨集在 match/parser 熱點做 null-sink 格式化，`2026-08-15` 報告「成因三層」節）。
〔O〕收端瓶頸已被獨立排除：08-15 有 h1→h1 loopback 42.4/63.5 Gbit/s 對照，且 99% 丟包定位在第一台 switch 進程內——「12–18× 不是被共同收端天花板壓出來的下界」有書面裁定（`2026-08-28_receiver-bottleneck-sweep/FINDINGS.md`）。
〔O〕「互相不可比較」的措辭降級是對的，且是這個 poster 的生存關鍵：ICNCC 有質性 build 揭露、我們沒做過任何一篇的重現，所以「不可複現」不能用（`VERDICT.md:7`）。

〔I〕這個組合在 EuroP4 poster track 的適配度偏高：P4 社群自己會在乎「社群的預設模擬器被量成 2,500× 落差」這件事；poster track 本來就收 work-in-progress，而這份工作的「審計＋recipe」形狀正好是 poster 尺寸。

### 1.2 審稿人最可能打的五個點（按殺傷力排序）

**攻擊 1：「改 build 不是創新，官方 performance.md 早就寫了建議 flags 和 917 Mbps。」**
〔O〕`performance.md` 的 flags 確實存在，且語料裡 2 篇（ICNCC、TSSA）引了它卻仍不報自己的 build（`GAP.md` §1）。
〔I〕這是繞不開的攻擊，學生自己也提了。反制不是否認，是**重新定位**：貢獻不是「發現 flags 有用」，是「量出這個沒人報告的變數值 12–18×，足以把語料裡 40 M–1 G 自陳範圍吃掉大半，且語料裡無人控制」＋ Mytkowicz et al. ASPLOS'09 的 measurement-bias 前例。**但 abstract 的 novelty 句必須自己把這句話寫出來**，否則審稿人會用第一頁就擋掉。

**攻擊 2：「你的 12–18× 不是單一變數實驗。」**
〔O〕兩顆 binary 的差異是六個旋鈕同時變：stock＝`-O0 -g`＋logging macros＋elogger 全開；fast＝`-O3`＋`-DNDEBUG`＋`-march=native`＋`-fno-semantic-interposition`＋兩個 logging 都關（`doc/audit/bmv2-binary-provenance.md` 表格）。兩者甚至 `--version` 都印 `1.15.3-f0b7d201`——這本身是好故事，但「build flags 值 12–18×」的措辭是**過度簡化**。
〔I〕abstract 必須寫「p4-guide 預設 debug build vs 官方建議效能 build 的**複合**差距」，不能寫「-O3 值 12–18×」。這個但書 `VERDICT.md` 沒有明講，我認為是它最大的口徑缺口。逐旋鈕二分（如單獨 -O3、單獨關 macros）沒有資料，別承諾也別暗示。

**攻擊 3：「16 流塌陷 3.3× 的兩個端點不在同一條曲線上。」**
〔O〕這不是我的臆測，是 repo 自己 8/28 深夜註冊的：既有 1 流點與 16 流點的**擺位不同**（16 流分散在 4 個 path class，flows-per-switch 與 flows-per-link 只是碰巧同值）；兩端都是階梯（ladder）上「最高無損 rung」，只知道到**一個 2× 區間**；「12 Mbit 四流」這個數字已正式更正為**除法推導、不是量測**（`PREREG.md` §1–3、commit `6d67d45`）。中間流數 n=2/4/8 的 PREREG 已寫好，但 **「no traffic has been sent. No data exists」**（`HANDOFF-CONTEXT.md` §1）。
〔I〕如果學生把現在的 160→48 M 直接畫成「3.3× 塌陷曲線」投出去，任何有方法論意識的審稿人（尤其 Chen 組成員）都能拆掉它。**這是我認為現有題材裡最脆弱的一塊**，優先級比補 pps 掃描還高。

**攻擊 4：「OVS 對照臂不是同工作點。」**
〔O〕bmv2 臂乾淨點是 3 M/流，OVS 臂是 30 M/流；OVS 臂是在帶 htb shaping 的 as-configured 狀態量；OVS 的「單流乾淨 ~400 M」與「16 流 480 M 不塌」出自 8/28 jitter 輪的彙總表，且 H1a/H1b（datapath vs shaper）未分離（`04_ovs_result.md` §5–6）。
〔I〕「同工作點」四個字要改成「**各自 drop-free 的每流工作點**」。否則審稿人一眼看到 3 vs 30 就出局。攻擊 4 可防，但現在的口徑（含題目一段話的寫法）不行。

**攻擊 5：「你的否定句只有 17 篇的效力，卻讀起來像全文獻。」**
〔O〕`SEARCH-ROUND-1.md` §4 自己列了還沒查的：TOMACS/ICNCC 的 cited-by、Google Scholar 全文、dblp 目錄、p4-dev。
〔I〕這個攻擊對 poster track 的殺傷力最低——poster 可以誠實寫「in our corpus of 17 papers/theses」——但**絕不可以**偷渡成「no prior work」。另外注意「17 篇已發表」的措辭：語料含 arXiv 預印本、碩士論文、seminar survey；且 2,500× 是**其中 9 篇有量 bmv2 者**的跨度，不是 17 篇（`RELATED-WORK.md` §3）。「兩篇同儕審查排序相反」也要精準：Fernando 的反轉機制是控制面（reactive ONOS 的 ARP/LLDP 繞路），不是 datapath 排序（`SEARCH-ROUND-1.md` §2）——講成「兩顆 datapath 量出相反結論」是過度宣稱，講成「兩個結論相反的測量都沒有 build 資訊」才是可辯護版。

### 1.3 我與 VERDICT.md 的明示異同

**同意**：角度成立；措辭停在「互相不可比較」；「不能」清單的每一條都同意；TOMACS 收編為互補（TDF÷build）的寫法也同意。
**不同意（部分）**：`VERDICT.md:5` 的但書「動筆前**至少**要補單 switch 隔離工作點、完整封包大小掃描、中間流數與重複數」——這是**全文**的前置，不是 **2 頁 poster** 的前置。poster track 的定位就是初步結果，誠實標註可以投。我把門檻移到別處：**宣稱口徑**（複合 build、17 篇範圍、兩點 pps、端點同擺位）與**raw 存檔**（見 §2.3 第 6 條），這些才是四天內不可協商的。另外 VERDICT 沒點出攻擊 2（六旋鈕複合）與攻擊 3（16 流擺位），這兩個必須由學生自己在 abstract 補上。

---

## ② 時間急迫性：四天內做什麼、放棄什麼、自揭什麼

### 2.1 現實盤點（OBSERVED）

- repo 裡**沒有任何 poster 草稿**：`EuroP4`／`poster`／`extended abstract` 全文檢索零命中。2 頁 abstract 要從零寫。〔O〕
- 投稿入口尚未公布、chair 已去信未回〔GIVEN〕→ 最後 24–48 小時可能完全耗在投稿物流上，寫作必須在 8/30 前完成。
- 08-15 的 A/B **raw 已滅失**：報告自述原始 JSON 在 session scratchpad、「session 結束即失效」（`2026-08-15` 報告「本機飽和實測」節）；audit-raw 分支是後來才建立的規矩，上面有 08-28 jitter/capacity/OVS 的 raw，**沒有 08-15 的**。〔O〕8/28 的 capacity 階梯與 OVS 臂 raw 則在 audit-raw 上。
- 中間流數 PREREG 已寫好、fabric 已起、**零資料**（`HANDOFF-CONTEXT.md` §1）。PREREG 自估流量時間 ~40 分鐘（§6），但兩臂＋分析＋不踩「量測窗內 commit」等 gate，實際是半天。
- 內部 9/03 deck 的圖**從未被確認能 render**（matplotlib 全機缺席，`HANDOFF-CONTEXT.md` §6）——學生手上同時有一個 9/03 的內部交付。

### 2.2 四天計畫（我的排序，寫作永遠優先）

| 天 | 做 | 不做 |
|---|---|---|
| D1（8/29） | **上午先跟教授談**（同意是全部條件的前提）；下午寫 abstract 骨架：related-work 段直接從策展表濃縮，宣稱句逐句對照 §1.2 的口徑 | 不碰任何實驗；不開始系統性檢索 |
| D2（8/30） | 完成 abstract 全文＋圖（圖可以先用手繪/文字表）；**若 lab 有空檔**，跑最便宜的一項：封包大小掃描 64→1400B（兩 build 各一條曲線，把「兩點」升成「曲線」，`GAP.md` §4-2 標 🟢） | 不跑 P1-3（除非 abstract 已定稿） |
| D3（8/31） | 定稿、排版、投稿物流待命（入口若未開，備好 email 提交方案） | 不新增宣稱 |
| D4（9/1） | 截止日緩衝 | — |

**必須放棄的**：系統性檢索補完（cited-by、dblp 掃描、p4-dev）——四天做不完，誠實寫「one-round corpus」即可；變體×build 2×2；jitter 軸（bmv2 上判別法結構性無適用域，`vs-ours.md` §4，本來就帶不進來）；單 switch 隔離工作點——**若 harness 無法在半小時內起 1-switch 拓樸就放棄**，在 abstract 寫明「3-hop 生產 stack、未隔離」，這正是 VERDICT 但書所擔心、但我接受為 poster 的誠實標註；一切「量測→模型」敘事（留一句給 NDTwin 定位即可）。

**中間流數 P1-3 的處置**：這是唯一「半天內能讓最脆弱宣稱翻盤」的實驗。若 D2 abstract 定稿後還有半天，就跑；跑出來就把 ③ 升級、跑不出來就在 abstract 把 ③ 標為「preliminary endpoints + pre-registered replication in progress」——**後者也是加分**（這個社群少有 poster 在投件時附 PREREG）。但注意 PREREG 的執行規矩（禁 commit 於窗內、兩臂、讀 interface counters 兩套 readout），違反規矩跑出來的資料寧可不要。

### 2.3 abstract 必須自揭的弱點（一條都不能省）

1. 語料範圍：17 篇、非系統性檢索（一輪）、所有否定句主詞是「in this corpus」。
2. 12–18×：單機、單拓樸、n=1–2、3-hop 生產 stack（kernel 輪詢與 sFlow clone 照常）、**六個旋鈕的複合 build 差異**（`bmv2-binary-provenance.md`）。
3. pps 恆定：目前兩點（stock 3.66k vs 3.62k；fast 64B 50.8k）；D2 掃描若成則升級，不成則照實寫兩點。**順帶一提**：更硬的版本是「TSSA 自己的 64/128B 兩點換算後 ~1.0–1.1 kpps 近恆定、論文未算」——文獻內部證據，審稿人打不動，當 anchor 用（`GAP.md` §2）。
4. 流數塌陷：兩端點同為階梯 rung（±2× 解析）、16 流端與 1 流端擺位不同、機制部分實證（10 burner 把 3 M/流從 0.000% loss 推到 2.192%，CPU 競爭會讓 bmv2 掉包——`01_capacity.md`）＋部分推論（每流查表成本的定量模型尚未測，正是 PREREG 要測的）。
5. OVS 對照臂：各平面各自的 drop-free 工作點（3 vs 30 M/流）、帶 shaping、H1a/H1b 未分離。
6. **provenance 論文的終極自嘲點**：08-15 的 raw 沒存下來（session 失效）。要投，**D2–D3 至少重跑一輪 A/B 並把 raw 按 audit-raw 規矩存好**，否則「你們指控別人不報 build，自己連 raw 都丟了」會是 Q&A 的一擊反殺。這條 `VERDICT.md` 完全沒提，我列為投稿的必要條件。
7. 作者與 affiliation 經教授同意；AI 輔助撰寫依 ACM 政策揭露。

---

## ③ 值不值得：期望值 vs 成本（大學部、申請碩士）

〔I〕**成本面（低）**：真正的邊際成本是 1.5–2 個工作天（素材已全部在 repo，策展表、數字、recipe、PREREG 都是現成的，寫作是壓縮不是創作）＋放棄 4 天內一切其他實驗。
〔GIVEN＋I〕**收益面（時機剛好）**：通知 9/14、workshop 12/7。碩士申請多半落在 11 月–次年 1 月，**9/14 就知道結果**，錄取就是申請表上「EuroP4'26 poster（ACM proceedings, DOI）」的一行；沒錄取，四天成本也買到一次真實審稿回饋。對大學部學生，這是低風險、正期望值的交易——**前提是投出去的版本不翻車**。
〔I〕**12 月到不了場的情境是整個期望值計算的決定項**：ACM 慣例 no-show 會被抽出 proceedings〔GIVEN〕。被拒＝零成本；錄取後 no-show 被抽出＝**負成本**（白佔一個 slot、被社群記住、進不了 proceedings）。所以正確決策不是「先投了再說」，而是**在 9/1 前把 12/7 到場可行性問成一個是/否**（差旅經費、或 chair 是否允許遠端/他人代報——後者題目事實未提供，必須等 chair 回信，不能猜）。若 9/1 前答案是「很可能到不了」，就不投；若到 9/14 通知時仍不確定，**收到錄取立刻撤回比 no-show 好**，但最好根本不讓自己走到那一步。
〔I〕**機會成本也要算**：學生手上有一個 9/03 的內部 deck，且其圖「從未確認能 render」（`HANDOFF-CONTEXT.md` §6）。四天花在 poster 上，內部交付就會吃緊。對教授而言，這題材的正確使用方式可能反而是「poster 是副產品，PREREG＋audit 系統才是你要秀給我的東西」——明天談話時要把這層講清楚。

---

## ④ 風險：學術與社交

**學術風險**
1. 〔I〕**審稿人＝被審語料的作者**。Chen/Hu/Jin 組四篇（PADS '23/TOMACS/PADS '24/PADS '26）在語料裡被點名最重，而 EuroP4 的 PC 與 SIGSIM-PADS/P4 社群高度重疊。風險不在「被記恨」，在「對方一眼看穿你的量測」——所以措辭維持 `VERDICT.md` 的「不可比較、不是不可複現」是對的，且不要用「這些數字是垃圾」的口氣；「corpus 內無一報告 build」是事實陳述，「你們的量測不可信」是另一個命題，前者不推導後者。
2. 〔I〕**自己翻車的風險大於被拒絕的風險**。這份工作的賣點就是方法紀律；任何一處宣稱超過資料（12 Mbit 式推導冒充量測、16 流端點直接上圖）都會在 Q&A 被現場拆穿。四天窗口內，「少寫」遠比「多寫」安全。
3. 〔O〕檢索可能還有漏網：關鍵詞 grep 已經假陰性過一次（ICNCC 的質性敘述不在關鍵詞表內，`RELATED-WORK.md` §4-1）。「0/17 報 flags」是靠策展複驗撐住的，投前把這個數字與 `hits_build.txt` 再對一次即可，別擴大為「學術界沒人做過」。

**社交風險**
4. 〔I〕**「教授會不會覺得癡心妄想？」——不會，但會覺得「順序錯了」。** 讀完這些 audit 檔，任何教授對學生的判斷力都不會搖頭；會皺眉的是：4 天前才講、沒有草稿、且中間卡著一個 9/03 內部交付。學生的自疑（「改 build 不是創新」）反而顯示校準良好。真正的社交風險只有兩個：(a) **在教授同意前以實驗室 affiliation 投稿**——明天會談前一個字都不准送出；(b) 因為 poster 耽誤 9/03 deck 而不先講。兩個都能在明天的談話裡消掉。
5. 〔I〕作者排序與署名：工作大量標註「Co-developed with claude code」＋多位 AI reviewer 的產出；投 ACM 要按政策揭露 AI 輔助，作者欄大概率是學生＋教授，這也要明天談。

---

## ⑤ 最終建議：有條件投（條件明列）

**條件（全部滿足才投；任何一條失敗 → 不投，改走 arXiv + 下一輪 EuroP4/SOSR/ANRW）**

- **C1 教授同意**：8/29 會談取得署名與 affiliation 同意、作者順序、AI 揭露方式。未取得前不送出任何東西。
- **C2 到場可行性**：9/1 前有 12/7 Utrecht 的到場方案（經費或替代報告人獲 chair 允許）；若答案是否定的，不投——no-show 被抽 proceedings 的負期望值吃掉一切收益。
- **C3 宣稱口徑**：abstract 逐句符合 §1.2／§2.3 清單——複合 build、17 篇範圍、兩點 pps（或掃描升級）、16 流端點標 preliminary＋PREREG、OVS 臂標各自工作點。任何一條做不到「自揭」就刪掉該宣稱。
- **C4 raw 存檔**：投稿前重跑至少一輪 A/B（或明確標示 08-15 資料為 report-only），raw 依 audit-raw 規矩存好。provenance 論文自己不留 raw，是會被現場一擊反殺的。
- **C5 寫作優先**：D1 起先寫後量；D2 的封包掃描與可能的 P1-3 都是「有餘力才做」，絕不讓實驗吃掉定稿時間；投稿入口若 8/31 仍未開，備好 email 提交與向 chair 的確認信。

**若 C1–C5 有任何一條不成立**：不投 EuroP4'26。把材料整理成 arXiv 技術報告＋PREREG 完成後的下一個週期投稿。這份材料放一個月會變強（中間流數、封包掃描、單 switch 隔離、系統性檢索都能補），擠四天只會變弱——**這題材的對手不是截止日，是學生自己想講超過資料的話。**

---

## 附：關鍵引用對照（供會談時快速查證）

| 宣稱 | 出處 |
|---|---|
| 0/9 報 flags、0/9 對照、~2,500× | `RELATED-WORK.md` §3 |
| 措辭降級為「互相不可比較」 | `VERDICT.md:7` |
| 12–18× 與兩點 pps、3-hop 方法 | `2026-08-15_bmv2-performance-report.md` |
| 兩 build 六旋鈕差異、--version 相同 | `doc/audit/bmv2-binary-provenance.md` |
| 16 流端點擺位不同、階梯 ±2×、PREREG 零資料 | `2026-08-28_flow-count-capacity/PREREG.md`、`HANDOFF-CONTEXT.md` |
| 12 Mbit 是除法不是量測（更正） | commit `6d67d45` |
| 12–18× 無收端瓶頸 | `2026-08-28_receiver-bottleneck-sweep/FINDINGS.md` |
| OVS 不塌＋3.3× 對照、工作點 3 vs 30 M/流 | `2026-08-28_jitter-working-point/04_ovs_result.md` |
| 檢索未完成清單 | `SEARCH-ROUND-1.md` §4 |
| 08-15 raw 已失效 | `2026-08-15_bmv2-performance-report.md`（原始 JSON 段落） |
| 9/03 deck 圖未確認 render | `HANDOFF-CONTEXT.md` §6 |
