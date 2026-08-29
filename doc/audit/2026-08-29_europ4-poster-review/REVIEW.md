# EuroP4'26 Poster 草稿——外部審查（PC member + Artifact Evaluator 口徑）

**建立日 2026-08-29。** 審查對象＝`doc/2026-08-29_europ4-poster-abstract/`（`abstract.tex` 189 行、
`refs.bib` 11 條、`NOTES.md`），佐證＝`doc/2026-08-29_bmv2-performance-study.md` 與四個 audit 目錄。
**標註**：〔O〕＝我親自讀到／親自查證；〔I〕＝我的推論。

> **先講結論**：這篇的方法學紀律（預註冊、雙讀值、陰性對照、儀器極限自查）**比我審過的多數
> workshop 投稿都強**，論點也真的存在。但草稿目前有 **4 個會被 desk-reject 或當場打臉的硬傷**，
> 其中 3 個的形狀，正是本文自己指控那 18 篇的錯。**這是最糟的一種錯**——審稿人不需要懂 P4
> 就能抓到，而且抓到之後整篇的道德權威會歸零。

---

## 0. 先看這個：時程與投稿門檻（〔O〕全部查自官方頁）

| 事實 | 出處 | 對 `NOTES.md` 的影響 |
|---|---|---|
| **Poster/demo 截稿＝2026-09-01（週二）**、通知 09-14 | p4.org/euro-p4-2026、sessionize.com/europ426 | 🔴 `NOTES.md:12`「官方頁沒有 poster 投稿連結」**部分過期**：deadline 官方頁寫著。**剩 3 天。** 連結確實仍未公布 |
| **EuroP4'26 採 double-blind** | 同上，原文 "EuroP4 will use a double-blind review process." | 🔴 **`NOTES.md` 三道關完全沒有「匿名化」這一關** |
| 主論文 6 頁、08-17 截止（已過） | 同上 | poster 頁限**官方未載明**；2 頁是從 '23 推的慣例〔I〕 |
| 正式名稱 8th European P4 Workshop，12/07 Utrecht，與 CoNEXT'26 共站 | 同上 | 與 `NOTES.md` 一致 |

**⇒ 第一優先動作**：問 chairs 兩件事而不是一件——(a) poster 投稿入口；(b) **poster/demo 是否也適用
double-blind、頁限多少**。這封信本來就要寄，多問兩句零成本。

---

## 1. 抄襲與原創性

**方法揭露**：我**沒有**把草稿上傳到任何第三方查重服務——未發表稿件送進會留存內容的商業平台，
風險大於收益，且那不是查重的必要手段。我改用**特徵句反查**（把草稿中最可能撞句的斷言、
引號內文字、數據描述丟去搜尋比對來源），這正是查重工具的核心動作。
**若你要我改用商業查重平台（Turnitin/iThenticate 等），跟我說一聲，那是你的稿子、你的決定。**

**結果：沒有發現任何未標示的文字重用。**〔O〕草稿的句子是自己寫的，沒有從 18 篇或官方文件
整段搬運。**但有一個引號的問題，嚴重度比抄襲更高**（見 §5 的 C-1，那是**引文不實**，不是抄襲）。

**原創性**：〔O〕我用 `bmv2 throughput benchmarking measurement study`、
`EuroP4 P4 performance measurement reproducibility` 等查詢掃過，**沒有找到任何已發表研究做過
「bmv2 build flags 的量化 A/B」**。官方 `docs/performance.md` 只給建議 flags 與單一參考數字
（~1047 Mbps 中位／~80 kpps，c4.2xlarge、`simple_router.p4`、2 host 1 switch），**沒有做對照實驗**。
⇒ **§3 的新穎性宣稱成立。**〔O＋I〕

---

## 2. 實驗方法與邏輯漏洞（最重的一節）

### 🔴 C-2【核心宣稱不實】`fast` 不是「officially recommended configuration」

`abstract.tex:112-114` 寫：

> *fast* is the officially recommended composite configuration
> (`-O3 --disable-logging-macros --disable-elogger`)

〔O〕`doc/audit/bmv2-binary-provenance.md:24-25` 記載**實際量到的那兩顆 binary**：

| | optimisation | logging |
|---|---|---|
| stock | `-O0 -g` | macros + elogger **on**（autoconf 預設） |
| fast | **`-O3 -g -DNDEBUG -march=native -fno-semantic-interposition`** | 兩者 **off** |

〔O〕官方 `docs/performance.md` 的建議是：
`./configure 'CXXFLAGS=-g -O3' 'CFLAGS=-g -O3' --disable-logging-macros --disable-elogger`

⇒ **實測的 fast 比官方建議多了三個旋鈕**（`-DNDEBUG`、`-march=native`、`-fno-semantic-interposition`），
**沒有一個出現在官方文件裡**。草稿卻稱它為「officially recommended」。

**後果三條**：
1. **R=8.0 不能全額歸給官方建議組態**——它是「官方建議 ＋ 三個作者自加的最佳化」對 `-O0` 的比值。
   對官方建議本身，**8.0 只是上界**。這與 ① 已經接受的 H2 收窄是同一種收窄，且**同樣必須寫進論文**。
2. `-march=native` **把 ISA 烘進 binary**——〔O〕`bmv2-binary-provenance.md:126-127` 自己就寫了
   "It can be rebuilt functionally equivalent from `f0b7d201`, **not identically**"。
   一篇要求別人報告可重建 build 的論文，**自己的 fast binary 不可逐 byte 重建**，這一條必須自曝。
3. 這正是 08-28 外部審查（`external-review-muse-spark-1.2.md:45`）已經指出過的口徑缺口：
   「不能寫『-O3 值 12–18×』，要寫**複合差距**」。**草稿目前仍未修。**〔O〕

**修法（照抄即可）**：
> *Stock* is the build produced verbatim by the `p4-guide` installer
> (`./configure --with-pi --with-thrift 'CXXFLAGS=-O0 -g'`, logging macros and elogger left on)
> [cite p4-guide]. *Fast* is bmv2's documented performance configuration
> (`-O3 --disable-logging-macros --disable-elogger`) **plus three further optimisation flags we
> added** (`-DNDEBUG -march=native -fno-semantic-interposition`). Both were built from
> behavioral-model `f0b7d201`; both report `--version 1.15.3-f0b7d201`, so the version string
> does not distinguish them. `-march=native` bakes in this host's ISA: the fast binary is
> functionally, not bit-wise, reproducible. **$R=8.0$ therefore upper-bounds what the documented
> configuration alone buys.**

### ✅ 反過來說：`stock` 那一側我查證後**站得住**，但必須引用

〔O〕草稿寫 stock 是 "as installed by common guides"，**無引用**——審稿人無法驗證，這是弱點。
我去查了：`jafingerhut/p4-guide` 的 `bin/install-p4dev-v8.sh` 對 behavioral-model 用的是
`./configure --with-pi --with-thrift ${configure_python_prefix} 'CXXFLAGS=-O0 -g'`，
註解寫 `# Remove 'CXXFLAGS ...' part to disable debug`，且**不帶** `--disable-logging-macros`
或 `--disable-elogger`。〔O〕這與 `bmv2-binary-provenance.md:36` 記的 stock configure 行
**逐字相同**。

⇒ **這是一個被埋掉的強項。** 把「common guides」換成「the p4-guide installer, verbatim」＋引用
＋附上那行 configure，stock 臂就從「作者自選的慢 build」變成「**這個社群實際安裝 bmv2 的方式**」。
建議直接寫進 §1：*the single most widely used install path for bmv2 ships `-O0` with logging on*。

### 🔴 C-3【摘要過度宣稱】OvS 那半句：不是 matched working points，且被 shaper 汙染

`abstract.tex:40-41`（**摘要**）：
> per-flow highest clean rate falls monotonically with flow count, replicated,
> **while OvS at matched working points does not**.

〔O〕證據側：
- `2026-08-29_bmv2-performance-study.md:306`：**「本輪未跑 OVS 臂」**、「不同置放、不同梯」。
- `doc/audit/2026-08-28_jitter-working-point/04_ovs_result.md:70-71`：
  「**不**宣稱 H1a／H1b 已分離。現象在有 shaping 的狀態下出現，而我沒跑拿掉 `bw=` 的第二臂
  ⇒ **無法區分「OVS datapath 在抖」與「htb 在抖」**。」
- 〔O〕外部審查兩份都記：bmv2 臂乾淨點 **3 M/流**、OVS 臂 **30 M/流**——差一個數量級。

⇒ **「matched working points」是不成立的**：置放不同、梯子不同、每流工作點差 10×，
而且 OVS 臂**帶著 htb shaping**——**shaper 本身就會把曲線壓平**，也就是說
**這個混淆因子的方向恰好會製造出你要的那個 null 結果**。這是控制組設計裡最糟的一種汙染。

**這也是本次審查裡「缺乏對照組支撐的因果宣稱」的唯一一個**，但它坐在**摘要**裡。
`NOTES.md:33` 的紅線（「維持 earlier measurement; same-ladder control planned 的誠實狀態」）
**在 §3 內文守住了、在摘要沒守住**。

**修法（二選一，我建議 A）**：
- **A（建議）**：摘要**整句刪掉 OvS**，改成
  `(3) *Flows:* per-flow highest clean rate falls monotonically with flow count, replicated across
  two independent arms. Whether a production-grade datapath behaves differently is an open control
  we have not yet run on the same ladder.`
  → 少一個賣點，但**沒有一個審稿人能打它**。以 poster 的體裁，誠實的 open question 反而是好的
  對話起點。
- **B**：保留但**必須**寫成
  `while an OvS arm measured earlier — at a different placement, on a different ladder, and with
  htb shaping active — did not decline; we do not claim a matched control.`
  → 又長又弱，還把 shaping 這個把柄主動遞出去。**A 比較好。**

### 🔴 C-4【自打嘴巴】Table 1 用 Mbit/s 報結果、不講 frame size

`abstract.tex:104` Table 1：`stock 45 vs. fast 360 Mbit/s`。**沒有 frame size。**

而同一篇 `abstract.tex:139-141` 的頭條句是：
> Reporting bmv2 capacity in Mbps without the frame size is therefore not imprecision;
> it is a $16\times$ ambiguity.

〔O〕① 實際用的是 **1400 B payload**（`FINDINGS-1b.md:8`「one hop h1→h2 on s1, **1400 B payload**」、
`FINDINGS.md:7` 同）⇒ frame ＝ 1442 B。**這個數字存在、只是沒寫進論文。**

⇒ **審稿人會在同一頁上抓到你違反自己的規則。** 這是全篇最容易被引用來羞辱的一段，
而修法只要在 Table 1 caption 加六個字。

**修法**：caption 補 `UDP, 1400 B payload (1442 B frame)`；§3(1) 內文第一句也補一次。
**順帶**：這樣一來 ①②③ 三個工單就全部滿足你自己的「unit」那一行。

### 🟡 C-5【頭條比值跨母體】2,500× 的兩端不是同一種量

`abstract.tex:28-29` / `56-57`：`span ${\sim}2{,}500\times$ (0.57 Mbps to 1.4 Gbps)`，
低端 `at 64 B \cite{hasnaa2023tssa}`。

〔O〕你**自己的**研究報告拆穿了這兩端：
- §5-6：「TSSA 的 64 B 值**帶 27–44% loss、在膝蓋之外**」⇒ 那不是無損門檻，是飽和後的送達值。
- §2-3：「TSSA 自述其 64/128 B 是 iperf **buffer length**〔O〕＝ **UDP payload 不是 Ethernet frame**
  ⇒ 在 NFV frame 軸上這兩點該畫在 **106/170 B**」。
- ICNCC 的 1.4 G 是**均值天花板**、且在**實體 10 G NIC** 上（§5-3）。
- §5-6 自己的結論：「**文獻 2,500× spread 的一部分可能只是兩個量的混用**」。

⇒ 目前草稿把「有損飽和值（106 B frame、payload 誤標成 frame）」除以「實體 NIC 均值天花板」
得到頭條數字，**而低端還沿用了 TSSA 自己的 frame/payload 錯誤**（草稿寫 "at 64 B"，
你自己的 §2-3 說那是 106 B frame）。

**這不會毀掉論點——反而是論點本身。** 但必須主動講，不能等審稿人講。

**修法**：把 2,500× 從「震撼數字」改成「**震撼數字＋它為什麼本身就是證據**」：
> Reported figures span ${\sim}2{,}500\times$ (0.57\,Mbps at a 64\,B iperf payload — a 106\,B frame,
> measured at 27--44\% loss — to 1.4\,Gbps as a mean ceiling on physical NICs). **That the two ends
> are not even the same kind of quantity is the finding, not a caveat**: the corpus mixes
> loss-free thresholds with post-knee delivered ceilings, and payload with frame, without naming
> which is which.

這比原句**更強**，而且把最大的攻擊面變成賣點。

### 🟡 C-6【分母膨脹】「18 篇」在三個句子裡用錯

〔O〕你的普查表（study §2-1）：18 篇裡**只有 12 篇量 bmv2**，1 篇轉述（TUM survey），
**5 篇根本不量 bmv2**（CompNet、NetSoft、vSDNEmul、HotSDN'13、P4Docker——它們是對照組／背景）。

問題句：
| 行 | 現文 | 問題 |
|---|---|---|
| `abstract.tex:28` | `We surveyed 18 papers that measure or relay bmv2 throughput` | 〔O〕5 篇既不量也不轉述 ⇒ 不實 |
| `abstract.tex:141` | **`All 18 surveyed papers report Mbps`** | 🔴 **明確假**：5 篇沒有 bmv2 數字可報；而且 P4CEP 是 corpus 裡**唯一 pps 本位**的（study §2-1 #7），不是「Mbps 再加一個 pps 點」 |
| `abstract.tex:42-43` | `none of the 18 papers states what limited its measurement` | 同上，分母應為 12 |

**修法**：全文統一成「**18 篇檢索命中、12 篇直接量測 bmv2**」，所有否定句的分母改 **12**。
`141` 改成：`Of the 12 that measure bmv2, 11 report only bit rate; the twelfth reports a single
pps figure \cite{kohler2018p4cep} and no size sweep.`
**分母縮小不會削弱論點**（0/12 比 0/18 更精準也更可信），但寫錯會讓審稿人懷疑整張表。

### 🟡 C-7【0/12 的措辭對 ICNCC 不公平，而 ICNCC 剛好是你的高端】

`abstract.tex:53-54`：`\textbf{0/12} report compiler flags or optimisation level`。
〔O〕study §2-1 #4：ICNCC **有**一句質性 build 敘述——「以不產生 log 的模式編譯」。

⇒ 讀過 ICNCC 的審稿人會說「你說 0/12，但那篇寫了」。技術上你是對的（無 flags），
但**這是你最不該讓人抓到的地方**——因為 ICNCC 正是 spread 的高端（1.4 G），
而「它可能是關掉 logging 的 build」**恰好支持你的主張**。

**修法**：`0/12 name compiler flags or an optimisation level; one states qualitatively that it
compiled bmv2 in a non-logging mode \cite{kumazoe2023icncc} — and it reports the corpus maximum.`
→ 從弱點變成**最漂亮的一個佐證**。

### 🔴 C-8【必答而未答】你自己的數字比官方文件低 4–5 倍，論文沒交代

〔O〕官方 `docs/performance.md`：~1047 Mbps 中位、**~80,000 pps**，
c4.2xlarge、`simple_router.p4`、**2 host + 1 switch 的 Mininet 拓樸**。
〔O〕你的 ②：64/256/1024 B 乾淨階＝**16.0 / 20.0 / 16.0 kpps**。

⇒ 你的 **fast** build、單 switch、Mininet——和官方參考點的設定高度可比——
**pps 低了約 4–5 倍**。草稿全篇**沒有提過這個數字一次**。

這一擊很致命，因為它落在你自己的 §4「What limited our measurements」上：
**你指控 18 篇沒人說是什麼限制了他們的量測，而你自己也沒說明為什麼你比官方參考點低 5 倍。**

**這不是缺陷、是必須回答的一題**。合理答案（你手上都有素材）：14 核共享機器、
veth 而非實體 NIC、128-host 拓樸下 10 個 `simple_switch_grpc` 並存、你的 P4 程式比
`simple_router.p4` 重、control plane 全程活著。**寫兩句就夠**，但一定要寫。

**修法**（放在 §4 開頭）：
> For calibration: bmv2's own documentation reports ${\sim}80$\,kpps for `simple_router.p4` on a
> dedicated cloud instance with a two-host, one-switch topology. Our fast build reaches
> 16--20\,kpps — 4--5$\times$ lower — under a heavier P4 program, ten co-resident switch processes,
> veth rather than physical NICs, and a live control plane. **We state this because it is exactly
> the comparison the 12 surveyed papers make impossible for their own numbers.**

### 🟡 C-9【動機數字沒有 raw】12× 進了摘要，但 raw 沒保住

〔O〕study §5-5：08-15 pilot **raw 未保存**、n=1–2、非隔離工作點。
Table 1 標了 `pilot`，但 **`abstract.tex:34` 的摘要句沒有任何標記**，
12× 與 R=8.0 並列呈現得像兩個同級的結果。

**修法**：摘要句改 `$12\times$ on a three-hop production path (pilot, $n{=}1$--2, raw not retained)`。
一個括號的成本，換掉「你要求別人存 raw、自己頭條數字沒 raw」這個把柄。

### ✅ 我實際重跑了什麼（Artifact Evaluation 口徑）

**我沒有重跑實驗**——那需要 fabric，且 lab claim 不在我手上（跨 session 協定）。
**我做的是算術與內部一致性的重現**，全部從論文與 FINDINGS 給的數字獨立重算：

| 檢查 | 我算的 | 論文寫的 | |
|---|---|---|---|
| 16.0 kpps × 64 B × 8 | 8.192 Mbit/s | 8.2 | ✅ |
| 20.0 kpps × 256 B × 8 | 40.96 Mbit/s | 41.0 | ✅ |
| 16.0 kpps × 1024 B × 8 | 131.07 Mbit/s | 131.1 | ✅ |
| bit-rate 跨度 131.07/8.192 | 16.0× | 16.0× | ✅ |
| pps 跨度 20.0/16.0 | 1.25× | 1.25× | ✅ |
| R ＝ 360/45 | 8.0 | 8.0 | ✅ |
| 量化區間 (360/70, 540/45) | (5.143, 12.0) | (5.14, 12.0) | ✅ **且我一開始算錯**——我用 ×1.5 推下一階＝67.5 得到 5.33，查 `FINDINGS-1b.md:69` 才知道實際梯階是 **70**（×1.556，在 ±20% 內）。**梯階值必須進論文**，否則沒人重算得出來 |
| ③ 合計＝n×每流（五格） | 200/220/150/52/24 | 200/220/150/52/24 | ✅ |
| 文獻 spread 1400/0.57 | 2456× | ~2,500× | ✅ |

⇒ **算術層面完全可重現，沒有一個數字對不上。** 這在我審過的稿子裡不常見，值得說。
**但**：上表最後一列那個 `70`，就是「不列梯階就不可重算」的活例——見 §8。

---

## 3. 創新性與貢獻定位

**成立。**〔O〕我掃過 EuroP4/SOSR/ANRW 方向與一般文獻檢索，**沒有找到已發表的 bmv2 build A/B 量化研究**。
官方 `performance.md` 說了「flags 有巨大影響」但**沒做對照**；這正是你的縫。

**核心價值的定位我同意，但建議調整措辭的重心**：
- 目前草稿把價值放在「**文獻未標註 build flags ⇒ 效能不可比較**」——這是**診斷**。
- 更有力的是加上**規範性後果**（§9 會展開）：**拿未優化的 bmv2 當 baseline 證明自己的機制，
  會系統性地灌水 8×**。診斷讓人點頭，後果讓人改行為。

**要主動防的一個反駁**：「這是 folklore，官方文件早寫了，不算新」。
〔O〕你的 study §1-4 已經有完美答案（**folk knowledge ≠ reporting norm**，且兩篇引了
`performance.md` 的論文自己仍不報 build）——**但這個答案在 `abstract.tex` 裡只佔半句**
（`75-76` 行）。**把它擴成一個有標題的小段**，這是最可能被挑戰的點。

---

## 4. 學術語氣與 De-AI

〔O〕我逐句掃過 189 行。**好消息：沒有 `delve into` / `robust` / `crucial` / `leverage` /
`comprehensive` / `pivotal` / `seamless` / `shed light on` 任何一個。** 這份稿子的 AI 味
**明顯低於平均**，動詞具體、句子帶數字。

仍可收緊的（按價值排序，不多）：

| 行 | 現文 | 建議 | 理由 |
|---|---|---|---|
| 26 | `anchors much of the P4 research pipeline` | `is the default target for P4 prototyping` | "anchors...pipeline" 是空的隱喻，且無法查證 |
| 63 | `The consequence is concrete:` | 刪，直接接下一句 | 過場句，2 頁稿買不起 |
| 71 | `The missing variable is not obscure.` | 刪，直接寫 `bmv2's own documentation gives the flags:` | 同上；且下一句就證明了 |
| 79-81 | `Our study is a P4-community instance of a familiar genre: an unreported, "trivial" variable large enough to invalidate published comparisons` | `The shape is Mytkowicz et al.'s \cite{mytkowicz2009wrong}: an unreported variable large enough to invalidate published comparisons.` | 省 12 字、更直接 |
| 167-168 | `Each experiment's dominant threat turned out to be the same:` | `The same threat dominated all three:` | 省 6 字 |
| 174 | `both corrections moved \emph{away} from the more publishable answer` | **保留原樣** | 這句是全篇最有說服力的一句，別動 |

**整體 register 判定**：合格。**不要再改語氣了，把預算花在 §2 的硬傷上。**

---

## 5. 引用正確性

### 🔴 C-1【引文不實——本次審查最嚴重的單點】

`abstract.tex:71-73`：
> The bmv2 repository's **README** warns that build flags
> ``**can have a massive impact on performance**'' \cite{bmv2repo}

〔O〕我逐字查了兩份原始文件：
- **`README.md` 裡沒有 "massive impact" 這個字串。** README 關於 build/效能只有一句：
  "Debug logging is enabled by default. If you want to disable it for performance reasons,
  you can pass `--disable-logging-macros` to the `configure` script."
- "massive impact" 出現在 **`docs/performance.md`**，原句是：
  **"this can have a massive impact."** ——**沒有 "on performance" 三個字**，
  主詞也是 "this"（指前文的 build flags），不是 "build flags"。

⇒ **兩個錯疊在一起：引號內的字串不是原文，出處檔案也指錯。**

〔O〕同一個錯也在 `2026-08-29_bmv2-performance-study.md:68`：
「官方 README 寫著 "Build flags can have a massive impact on performance"」——
**連首字母大寫都做了，看起來完全像逐字引用。** 這個錯是從研究報告繼承進草稿的。

**為什麼這是最嚴重的**：一篇**主張引用與 provenance 紀律**的論文，
**自己捏造了一句官方引文**。審稿人只要點開 README 搜尋就會發現。
這一擊之後，這篇的所有其他宣稱都會被重新懷疑。

**修法**：
> bmv2's own performance documentation warns that the choice of build flags
> ``can have a massive impact''~\cite{bmv2perf}, and lists the recommended configuration.

並把 `bmv2repo` 拆成兩條 bib（`bmv2repo` 指 README、`bmv2perf` 指 `docs/performance.md`），
因為你在兩處引用了兩份不同文件。

### 🔴 C-10【引成非同儕審查版，而摘要靠它撐一個宣稱】

`abstract.tex:30-31`（摘要）：`two **peer-reviewed** papers order bmv2 versus Open vSwitch in
opposite directions`，對應 `\cite{fernando2025network}`。

〔O〕你 corpus 裡的那份 PDF 是 `preprints202504.2530.v1.pdf`，首頁**明白印著**：

```
Article
Not peer-reviewed version
A Performance Evaluation for Software Defined Networks with P4
Omesh A Fernando *, Hannan Xiao, Joseph Spring, Xianhui Che
Posted Date: 30 April 2025
doi: 10.20944/preprints202504.2530.v1
```

⇒ **手上這份不是同儕審查版**，而摘要那句話的力道**完全來自「peer-reviewed」這個詞**。

〔O〕好消息：**期刊版存在**——*Network* **5(2)**, 21, 2025, DOI `10.3390/network5020021`。
⚠️ 但 `refs.bib:54` 寫 `number = {1}` ⇒ **期號錯**（應為 2）。

**修法（兩步，缺一不可）**：
1. bib 換成期刊版（見下方修好的條目）。
2. **開期刊版 PDF 核對 OvS 那個結論與數字有沒有變**——preprint 到 published 之間改結論是常事。
   在核對之前，**「peer-reviewed」這個詞不能留在摘要裡**。

### 🟡 C-11 其餘 bib 逐條（〔O〕全部對 PDF 首頁或官方頁查證）

| key | 問題 | 修正 |
|---|---|---|
| `kohler2018p4cep` | 🔴 **`K{\"o}hler` 的分音符是捏造的**——PDF 首頁印 **"Thomas Kohler"**（無 umlaut）<br>🔴 `and others` 藏了 **5 位**作者<br>🟡 venue 漏了 "Morning" | `Kohler, Thomas and Mayer, Ruben and D{\"u}rr, Frank and Maa{\ss}, Marius and Bhowmik, Sukanya and Rothermel, Kurt`<br>booktitle: `Proc.\ ACM SIGCOMM 2018 Morning Workshop on In-Network Computing (NetCompute~'18)`<br>刪掉 `note` 裡的 TODO |
| `zhang2021benchmarking` | 🔴 `and others` 藏了 **1 位**（James Roberts）；**且現有列表漏排** | 完整＝`Zhang, Tianzhu and Linguaglossa, Leonardo and Giaccone, Paolo and Iannone, Luigi and Roberts, James`（〔O〕PDF 首頁；**沒有** Massimo Gallo——我原先記得有，查了才知道記錯） |
| `fernando2025network` | 🔴 四個 `TODO` ＋ 期號錯 | `author = {Fernando, Omesh A. and Xiao, Hannan and Spring, Joseph and Che, Xianhui}`<br>`title = {A Performance Evaluation for Software Defined Networks with {P4}}`<br>`journal = {Network}, volume = {5}, number = {2}, pages = {21}, year = {2025}, doi = {10.3390/network5020021}` |
| `chen2025tomacs` | 🟡 缺 article number 與 DOI | 〔O〕PDF 的 ACM Reference Format：`35, 2, Article 16 (April 2025), 24 pages`<br>加 `articleno = {16}, numpages = {24}, doi = {10.1145/3725530}` |
| `chen2023pads` / `waind2024pads` / `waind2026pads` | 🟡 `Proc.\ ACM SIGSIM-PADS` 是簡寫，非官方名 | 官方＝`Proc.\ ACM SIGSIM Conf.\ on Principles of Advanced Discrete Simulation (SIGSIM-PADS~'2X)`；`waind2026pads` 建議補 DOI `10.1145/3806789.3810263`（〔O〕檔名即 ACM DOI） |
| `bmv2repo` | 🟡 一條 bib 指兩份文件 | 拆成 `bmv2repo`（README）與 `bmv2perf`（`docs/performance.md`）——見 C-1 |
| **新增** | 🔴 stock build 沒有引用來源 | 加 `@misc{p4guide, author={Fingerhut, Andy}, title={p4-guide: install scripts for the P4 development tools}, howpublished={\url{https://github.com/jafingerhut/p4-guide}}, note={\texttt{bin/install-p4dev-v8.sh}; accessed 2026-08-29}}` |

### 🔴 C-12 TODO 與匿名化

〔O〕`abstract.tex` 剩 **3 個 TODO**：
- `:19` `% TODO: confirm affiliation wording with advisor`
- `:21` **`\email{TODO@example.edu}`** ← **這個會直接 desk-reject**
- `:23` `% TODO: second author (advisor) pending consent`

〔O〕`refs.bib` 剩 **6 個 TODO**（`fernando2025network` ×5、`kohler2018p4cep` ×1）——上表已全部解掉。

🔴 **而且，若 poster 適用 double-blind，`:17-21` 整個 author block 都必須拿掉**，
`\documentclass` 要加 `anonymous`，`\settopmatter{printacmref=false}` 之外還要處理自我引用。
**這一關 `NOTES.md` 完全沒有列。**

---

## 6. 資訊密度與視覺化（Adam 說「太短、圖太少」——我同意，而且比你想的更嚴重）

先把兩個東西分開，這是關鍵：

| 產出 | 現況 | 判定 |
|---|---|---|
| **2 頁 extended abstract**（09-01 投稿用） | 已寫、2 圖 1 表 | 密度**偏低但不致命**，見下 |
| **實體 poster**（12/07 現場的 A0） | **完全不存在** | 🔴 **這才是「太短、沒圖」的真正所在** |

### 6-1. Abstract：兩張最有說服力的圖被留在檔案裡沒用

〔O〕`make_figs.py` 產了 **4 張**，`abstract.tex` 只放了 **fig1、fig2**。
`NOTES.md:38-40` 說 fig3/fig4「留給 full paper」。

**我認為這個取捨下反了**：

- **fig4（文獻 spread ~2,500×）沒進稿，是這份草稿最大的編輯失誤。**
  §1 花了 **32 行純文字**（`50-81`）講 spread，而 spread 正是全篇的頭條、
  也是**唯一一眼就能懂**的東西。一張把 12 個點畫在對數軸上、
  旁邊標「build flags: 未載明 ×12」的圖，**抵得過那 32 行的一半**。
  在 poster 體裁裡，**頭條必須有圖**。
- **fig3（12× / 8.0× 兩工作點）**是你「主張收窄、誠實揭露」這個賣點的視覺化。
  審稿人最欣賞的就是這種自我收窄，而它現在只是 Table 1 裡的兩行字。

**建議的版面重排**（不增頁，靠壓縮 §1 換空間）：
1. §1 的 32 行文字 → 壓到 ~14 行 ＋ **fig4**。刪的是 lineage 1.7× 那句細節
   （`NOTES.md:25` 本來就把它列在裁切順序第二位）。
2. Table 1 → 併進 **fig3**，表消失、圖出現。表格現在只有 2 列，撐不起一個 float。
3. fig1、fig2 保留。
⇒ **從 2 圖 1 表變成 4 圖 0 表**，總佔版面相近，**掃視性大幅提升**。

### 6-2. 三段該變成結構化元素的散文

| 位置 | 現況 | 該變成 |
|---|---|---|
| `abstract.tex:52-57` §1 開頭統計（0/12、3/12、1/12…） | 埋在句子裡 | **一個 4 列小表或圖內標註**——這是全篇最容易被引用的數字，現在讀者要自己從句子裡挖 |
| `abstract.tex:85-92` §2 方法紀律（預註冊／臂／梯／簽名／CPU gate／雙讀值／raw） | **一段 8 行、七個子句用分號串起來** | 🔴 **這是全篇最不可掃視的一段**，而它是你最強的賣點。改成 **6 條 bullet**，每條 ≤ 8 字：`Preregistered intervals + meanings` / `Replication unit = arm` / `×1.5 ladder, ±20%` / `Binary by symbol signature` / `Per-process CPU gate (positive-controlled)` / `Dual readout, content-hashed raw` |
| `abstract.tex:180-184` §5 四行 provenance minimum | 散文句 | **編號 4 條 ＋ 每條配一個「你該寫什麼」的例子**。這是你要別人**照做**的東西——照做用的東西不能是散文 |

### 6-3. 實體 poster：現在是零

Adam 的直覺對，但真正的洞在這裡：**12/07 要站在板子前面，而板子還不存在。**
若 09-14 通知錄取，到 12/07 有近三個月，不急——**但別把 2 頁 abstract 誤當成 poster**。

A0 版面建議（等錄取再做，先記著）：
- **視覺錨＝fig4 放大**（spread 圖），佔左上 1/3。這是唯一能讓路過的人停下來的東西。
- 中欄三格＝①②③，**每格一張圖一個數字**，不要句子。
- 右下＝**四行 provenance minimum，做成一張可以拍照帶走的 checklist**。
  這是 poster 場最有價值的產出形式——**讓人拍照的不是你的結果，是你的規範。**
- 「What limited our measurements」做成一個小方塊，標題直接寫
  **"Twice, our own instrument nearly became the result"**——這在 poster 場會招來對話。

---

## 7. 外部效度與限制揭露

### 🔴 C-13 缺「bmv2 是功能模型，不是效能標的」的免責聲明

〔O〕我全文搜過 `abstract.tex`：**沒有任何一句**說明 bmv2 是 functional reference model、
**不以效能為設計目標**。

而官方文件講得非常明白（兩處，可直接引）：
- README：`bmv2 is not meant to be a production-grade software switch. It is meant to be used as a
  tool for developing, testing and debugging P4 data planes and control plane software written for them.`
- README：`the performance of bmv2 — in terms of throughput and latency — is significantly less than
  that of a production-grade software switch like Open vSwitch.`

**缺了這段的後果**：審稿人會讀成「這篇在批評 bmv2 慢」——**那會完全誤讀你的貢獻**。
你的論點不是「bmv2 慢」，是「**大家在報告一個功能模型的效能數字時不寫 build，
所以那些數字彼此不可比**」。**加上這段免責，論點反而更鋒利**，因為它把攻擊面
從 bmv2 移到**報告規範**上。

### 🔴 C-14 §5-3 的外部效度清單**整段沒有進 abstract**

〔O〕study `§5-3` 有一份很老實的清單：單機 14 核、Mininet/veth 非實體 NIC、單一 P4 程式、
bmv2 單一版本、UDP 為主。**`abstract.tex` 一條都沒寫。**
`abstract.tex:97` 只在 Table 1 caption 有 `One machine, 128-host emulated topology, ten
simple_switch_grpc; UDP` ——這是設定描述，不是限制聲明。

**修法（一段，放 §5 之前或 §4 之後，這是 2 頁稿裡最值得的 6 行）**：
> **Scope.** bmv2 is a functional reference model; its own documentation states it is not meant to
> be a production-grade switch~\cite{bmv2repo}. We do not report it as a performance target — we
> report that its published numbers cannot be compared. All measurements come from one 14-core
> host, Mininet veth links (not physical NICs), one P4 program, one behavioral-model commit
> (`f0b7d201`), and predominantly UDP. **The ratios do not transfer to another machine, another P4
> program, or to hardware targets, and say nothing about P4 the language.** What we claim
> transfers is the structure: a variable this large, unreported, makes comparison impossible.

⇒ 這段同時解決 C-13、C-14、以及 §8 的一半 provenance。**若只能改一處，改這裡。**

---

## 8. 可重現性（Artifact Evaluator 口徑）

**AE 標準問法：一個陌生人拿到這 2 頁，能重建你的量測嗎？** 逐項對帳：

| AE 必要項 | 草稿有寫嗎 | 你手上有嗎 | 動作 |
|---|---|---|---|
| bmv2 source commit | 🔴 **無** | ✅ **`f0b7d201`**（`bmv2-binary-provenance.md:28`） | **加**。這是全篇最諷刺的缺項 |
| bmv2 版本字串 | 🔴 無 | ✅ `1.15.3-f0b7d201`，**且兩顆 binary 印一樣** | **加**——「版本字串無法區分兩顆 binary」本身就是你論點的完美例證，白送的一句 |
| stock 完整 configure | 🟡 只寫 `-O0` | ✅ `./configure --with-pi --with-thrift ... 'CXXFLAGS=-O0 -g'` | **加逐字**＋引 p4-guide |
| fast 完整 configure | 🔴 **寫錯**（見 C-2） | ✅ `-O3 -g -DNDEBUG -march=native -fno-semantic-interposition` ＋兩個 disable | **改正**＋聲明不可逐 byte 重建 |
| binary 識別（sha256/BuildID） | 🔴 無 | ✅ sha256 `327fa7d1…`/`3ff54b5c…`、BuildID 兩組 | poster 放不下全部 ⇒ **至少放前 8 碼**，其餘進 artifact |
| CPU / kernel / OS | 🔴 無 | 🟡 「14 核」在 study §5-3 | **加**具體型號與 kernel 版本 |
| **pps↔bps 的 frame size 定義** | 🟡 ② 有、**① 完全沒有** | ✅ 1400 B payload ＝ 1442 B frame | **加**（見 C-4）。**這是你自己那條規則** |
| frame vs payload 的換算式 | 🔴 無 | ✅ study §3-2：`frame = payload + 42` | **加一句**——TSSA 就是栽在這裡，寫出來同時是方法也是論點 |
| **梯階實際值** | 🔴 無 | ✅ …45, 70, 105, 160, 240, 360, 540, 810 | **加**。我重算量化區間時第一次就算錯（用 ×1.5 得 67.5→5.33，實際梯階是 70→5.14）⇒ **不列梯階，沒有人能重算你的區間** |
| clean 判準 | ✅ `loss ≤0.5%` 在 caption | ✅ | ok，但**中位數 / 3-rep 規則**沒寫 |
| 臂數與重複規則 | 🟡 Table 只有 `2 arms/build` | ✅ | ok |
| 流量產生器版本 | 🔴 無 | 🟡 iperf3（版本未見） | **加版本號** |
| P4 程式 | 🔴 無 | ✅ | **加**名稱與行數／表數 |
| raw 存檔位置 | 🟡 `will be released` | ✅ `audit-raw` 分支＋content hash | **改成具體**：內容雜湊 ＋ 釋出承諾。⚠️ **double-blind 下不能放 GitHub 連結**（見 C-12）——用匿名 archive |

⇒ **目前草稿滿足自己「四行 provenance minimum」的 2/4**（placement ✅、limit ✅；
**build ✗**（flags 寫錯、無 commit）、**unit ✗**（① 無 frame size））。

> 🔴 **這是整份審查的頭條**：一篇提出四行最低要求的論文，**自己只做到兩行**。
> 這不是修辭問題——這是審稿人一定會做的檢查，而且做起來只要三十秒。
> **好消息：四項缺料你全部有，補齊是純編輯工作，不需要任何新實驗。**

---

## 9. 社群痛點對齊

### 現況：診斷寫滿了，**後果沒寫**

〔O〕草稿通篇在講「不可比較」，但**從頭到尾沒有一句**說出那個最痛的後果：

> **拿未優化的 bmv2 當 baseline 來證明自己的機制有多快，會系統性地灌水，
> 而灌水的幅度（此機器上 8×）可能大於被宣稱的加速本身。**

這句話才是會讓 P4 社群坐直的東西。理由：〔I〕大量 P4 加速／offload／in-network computing
論文用 bmv2 當 baseline 報 speedup。若那顆 baseline 是 p4-guide 預設的 `-O0` + logging build
（而按你的 §2-1，**沒有人報告過**，所以我們無從知道有幾篇是），
**那些 speedup 有一個 8 倍的天花板是編譯器給的，不是機制給的。**

**這正好把 §7 的免責聲明變成武器**：因為 bmv2 是功能模型、**沒有人為效能編譯它**，
所以它作為 baseline 特別危險——**它慢得不像任何真實系統，卻被拿來當真實系統的下界。**

### 建議：把 Takeaway 從「四行清單」升級成「一句警告 ＋ 四行清單」

`abstract.tex:178-184` 目前直接進四行清單。建議前面加這一段：

> **Why this matters beyond bmv2.** A large body of P4 work reports speedups against a bmv2
> baseline. None of the 12 papers we surveyed states how its bmv2 was built — so no reader can
> tell whether a reported speedup is the mechanism's or the compiler's. On this machine that
> confound is worth $8\times$: **large enough to exceed many published gains outright.** bmv2 is a
> functional model and nobody compiles it for speed; that is exactly what makes it a dangerous
> baseline, and exactly why the build line has to be reported.
>
> We therefore propose a four-line provenance minimum for any software-switch number: …

⇒ 這段做三件事：接上 §7 的免責、給出可行動的後果、**把貢獻從「一個 bmv2 的量測」
提升成「一條所有拿軟體 switch 當 baseline 的人都適用的規範」**。
**這是把 poster 從「有趣」變成「必看」的那一段。**

---

## 10. 給投稿的優先序（09-01 只剩 3 天）

### 必修（不改就不要投）
1. **C-1** 捏造的 README 引文 → 改引 `docs/performance.md`＋逐字修正〔30 分鐘〕
2. **C-2** fast build 口徑不實 → 三個額外旗標寫出來、R=8.0 降為上界〔1 小時〕
3. **C-12** `TODO@example.edu` 等 3 個 TODO ＋ **double-blind 匿名化**〔1 小時＋等 chairs 回覆〕
4. **C-10** `fernando2025network` 換期刊版並核對；未核對前摘要拿掉 "peer-reviewed"〔1 小時〕
5. **C-4** Table 1 補 frame size〔5 分鐘〕
6. **C-3** 摘要的 OvS 句刪掉或降級〔10 分鐘〕
7. **C-11** bib 六條修正（我上面全部給了現成字串）〔30 分鐘〕

### 強烈建議（大幅提升接受率）
8. **§7 的 Scope 段**（一次解 C-13/C-14＋一半 provenance）〔30 分鐘〕
9. **§9 的 Why this matters 段**〔30 分鐘〕
10. **C-8** 對官方 80 kpps 的校準兩句〔20 分鐘〕
11. **§8** 補 commit `f0b7d201`、梯階值、frame 換算式〔30 分鐘〕
12. **C-6/C-7** 分母 18→12、ICNCC 那句改寫〔20 分鐘〕

### 版面（Adam 的直覺，我背書）
13. **fig4 進稿、Table 1 換成 fig3**、§1 壓縮、§2 方法段改 bullet〔2 小時〕

### 可延到 full paper
- C-5 的 2,500× 改寫（值得做，但不改也不致命）
- 實體 A0 poster（等 09-14 通知）
- OvS 同梯對照（本來就已註冊為下一輪）

---

## 11-bis. 外部平行審查——全文驗證分級（08-29 下午補）

兩份外部報告（`deepseek-v4-pro.md` 172 行、`muse-spark-1.2.md` 347 行）我逐行讀完，
宣稱逐條回原檔驗證。完整分級與轉送內容見發給 `bmv2 performance` 的第三封訊息；此處只記帳。

**我自己的一個錯（已更正）**：第二封訊息說「DeepSeek『②③ 用 argv 指認 binary』驗不實」——
**撤回，DeepSeek 對、我錯**。我引的 ② `FINDINGS.md:94-96` 講的是 CPU 歸因的 PID 列舉
（exact comm），不是 binary 身分。實驗證據：`run_size_arm.sh:71` 與 `run_flowcount_arm.sh:73`
的 `switch_binary=` 都從 `pgrep -af` 的 argv 撈，且兩支腳本**零個** EventLogger/nm 檢查。
⇒ `abstract.tex:88-89` 的符號簽名宣稱只對 ① 成立。

**DeepSeek 實錘且我第一輪漏掉的**：A8（"none states what limited its measurement" 在檢索
artifact 裡**無 per-paper 編碼**——census 欄位只有 檔名/論文/有沒有量，我 grep 驗證）；
A6 的 abstract 層缺 ±1 rung 與 0.4969% 揭露；A9 的 knee 7.8 缺 "supporting evidence" 資格句；
C5/C6（OS/kernel/CPU 型號與 iperf3 版本**全 repo 無記錄**——要補量不是改字）；
C9/C10（②③ 路徑長度、P4 program 名與 commit 未載明）。

**Muse 採用前必修四處**：(1) Limitations 段 "Linux `a40e04ce`" 是**錯的**（那是 ndtwin_kernel
commit，不是 Linux 版本）；(2) 同段 "symbol-signature identified" 對 ②③ 不成立；
(3) 改寫表 71-75/24/36 行沿用捏造 README 引文與 "matched points"/"recommended"——照抄會回寫
C-1/C-2/C-3；(4) 標題建議 "Build Flags **Explain** 8× of Spread" 暗示做過 spread 分解，沒做過。
可直接採：skip-test、T-A~T-E skeleton（數字對過 census、T-E 算術我重算）、fig4 anchor
（三方獨立同結論）、頭條警句 B 版、checklist box、35 字牆版 Limitations。

## 11. 我沒做的事（覆蓋邊界，照這個專案的規矩老實列）

- **沒有重跑任何實驗**——需要 fabric，lab claim 不在我手上。只做了算術重現（§2 末）。
- **沒有上傳草稿到商業查重平台**——理由見 §1，需要你裁示。
- **沒有讀 18 篇 PDF 的全文**——只讀了 5 篇的首頁（為了查作者列與同儕審查狀態）。
  §2-1 普查表的逐篇數字**我沒有獨立驗證**，我驗的是**草稿對那張表的引用是否忠實**。
- **沒有驗證 `preprints202504.2530.v1.pdf` 與期刊版 `10.3390/network5020021` 的差異**
  ——MDPI 擋爬蟲（HTTP 403）。**這件事必須有人手動開一次期刊版 PDF。**
- **poster 頁限未確認**——官方頁沒寫，2 頁是慣例推論。

[Co-developed with claude code -- Adam]
