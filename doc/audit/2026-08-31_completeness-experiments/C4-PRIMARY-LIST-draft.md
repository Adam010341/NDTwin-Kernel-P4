# C4 primary-list 草案（凍結前、資料接觸前；待 auditor 快核 → 併入 PREREG-C4 §3 → v1.0）

**規則來源**：auditor 08-31 三條（規則先於清單，免得清單長成資料的形狀）——
①open/closed 兩個都登記（避免 data-dependent selection）；②若機時只能選一個，
**理由必須先驗、寫進 prereg 才凍結，且明記被放棄者與理由**；③六個候選逐個標
入 primary／secondary／不報，**secondary 不得在結果期升級**。
**輸入**＝`C4-whippersnapper/RECON-R2-install.md` §5–§6（讀碼列舉，非跑出來的）。

## 1. 五個 primary（兩個 loop＝兩個不同的問題；各指標獨立適用 H-C4a/b）

| 臂 | Primary 指標 | 單位（**逐項寫死**，因 artifact 自身單位不一致） | 檔 |
|---|---|---|---|
| **closed-loop** | **P1** 每 1000-封包窗的平均 RTT（修剪序列）與其平均 `avg_latency` | **秒**（`parse_results.py` 的窗均值單位） | `results.tsv` |
| closed-loop | **P3** `sent recv lost tput duration` 的 **loss fraction** 與 **tput** | loss＝無單位分數；tput＝**pkt/s**；duration＝秒 | `load_stats.tsv` |
| **open-loop** | **P4** 每秒 `(recv_count, mean_latency_µs)` 序列的**平均延遲** | **微秒**（`main.c:153` 原生單位，不換算） | `latency.csv` |
| open-loop | **P5** 最終 `sent recv loss_fraction` | 無單位分數 | `loss.csv` |
| open-loop | **P6** pen_* 掃描的**零損容量點**＝最後一個未掉包的 `offer_load` | **B/s**；解析度＝**±100,000 B/s（加法步進）** | 目錄結構＋`loss.csv` |

- **H-C4a/b 逐指標各判一次**（**五個 primary ⇒ 五個獨立判定**），不合成單一總分。
- 🔴 **多重性的措辭閘（auditor 08-31）**：獨立判定越多，「至少一個動了」的機率越高
  ⇒ **任何摘要句必須寫出「動了幾個／共幾個」**（例：「五個 primary 中兩個超出散布」），
  **不得寫成「其量測會隨 build 移動」**。此條同時進 PREREG-C4 §4 措辭紅線。
- 🔴 **單位不得跨指標換算後比較**（artifact 自己 µs／秒／ns 三種混用，見 RECON §5g.4）；
  跨指標並列一律標事後探索（同 PREREG-C4 §4 的跨代碼庫免責同構）。

## 2. secondary（報、但**不得在結果期升級為 primary**）

| # | 指標 | 為何不入 primary |
|---|---|---|
| **P2** | `p99/p95/std/cv`（同窗） | 分布細節；頭條是中央趨勢，登記 tail 會多開四個判定面 |
（P6 原列於此、理由為「太像我們的量」——**該理由已作廢**，見 §2a。）

## 2a. P6 的裁定：**升 primary**（原理由作廢——那是便利性排除）

**我的原理由錯了**：我寫「它最像我們自家的量，正因如此不入 primary」——auditor 指出那是
**selection by convenience**，與我們批評別人「只報好看的工作點」同形。
**正確判準（auditor 08-31）**：這個數字是 **artifact 自己吐的（用它自己的門檻）**，
還是**要我們拿門檻去推**？

**偵察已查明（讀碼，凍結前、非看到結果才決定）**：
- `benchmark/benchmark.py:48-56` `P4Benchmark.has_lost_packet()`＝讀 `loss.csv` 末列，
  `return (recv < sent)` ⇒ **artifact 自帶零損定義，且比我方嚴**（掉**任何一個**封包即算，
  不是 0.5%）。
- `benchmark/pen_parser.py:44-53` `main()`＝`offer_load` 自 100000 起、每次 `+100000`、
  **climb until `has_lost_packet()` 為真**；`BenchmarkParser(P4Benchmark)`（`:12`）繼承之。

⇒ **門檻是他們的、步進是他們的、判定由他們的程式做**——讀它**不輸入我方任何東西**
⇒ **P6 ＝ primary #5**。
🔴 **解析度是加法不是乘法**：步進固定 100,000 B/s ⇒ 讀值為區間
`[last_clean, last_clean+100000)` B/s，**與我方 ×1.5 梯階在種類上不同、不得換算比較**
（C2 免責同構）。
🔴 **P6 屬 open-loop 家族** ⇒ §4 的放棄順序若觸發，**一次失去三個 primary（P4/P5/P6）**；
此代價明列於此，但**不改變**先驗理由（見 §4）。

## 3. 不報

- PISCES／MoonGen 側（RECON §5f）＝容器範圍外、非 bmv2 臂。
- artifact README 提及但**檔案不存在**的 `analyse.R`／`plot.R` 衍生統計（RECON §5g.1）
  ——**無法產生，且此缺席本身列為可重現性發現**（見 §5）。

## 4. 先驗的放棄順序（規則②：現在就寫死，不等機時壓力出現）

若機時／容器穩定性只容一個 loop：**保留 closed-loop（P1+P3）、放棄 open-loop（P4+P5）**。
**先驗理由**：受測論文的頭條量是**延遲類**（parse 1 header 11.2 ms），closed-loop 的 P1
與該頭條同量類；C4 的問題是「他們自己那條管線的頭條會不會動」，因此保留與頭條同類者。
🔑 **代價已知且不改變此理由**：觸發時一次失去 P4/P5/P6 三個 primary（見 §2a）。
**因代價變大而改選，等同以便利性推翻先驗理由**——不允許。
🔴 **此理由與任何實測值無關、且已在資料接觸前寫下**；放棄 open-loop 一事**必須在報告
中可見**（不得靜默省略）。反向（保留 open-loop）**不允許**——除非 closed-loop 在偵察
階段即證明不可跑，且該證明落檔。

## 5. benchmark feature 的範圍（同屬先驗選擇）

artifact 產生器有九個 feature（RECON §4）。**primary feature ＝ `parse header`**——
先驗理由同上（論文頭條即該類）。其餘八個：**不跑**（機時）；若跑則一律 secondary。
🔴 不得因為某個 feature「動比較多」而事後改列 primary。

## 6. 併入 PREREG-C4 時要一起帶的兩句

1. **可重現性發現節**（RECON §5g 三件＋未釘相依＋建置空間成本）：thrift 鏡像已死、
   `analyse.R`/`plot.R` 缺席、單位不一致、`requirements.txt` 全未釘版本（今日 py2 裝不起來）、
   period 重建需 >5 GB 暫時空間。
   🔴 **定位要收窄（auditor 08-31，我原本寫過頭）**：這些支持的命題是
   **「artifact 可取得 ≠ 可重現」——那是文獻早有的老命題**，我們提供的是**有日期、有失敗點的
   一手佐證軼事**（比二手引用值錢），**不是新發現**。而 0/12 支持的是**另一個**命題
   （報告規範的缺席）。**兩者不是同一主張的強弱版本，是兩個不同主張**
   ⇒ 🔴 **不得拿腐蝕去強化 0/12**（那就是我們自己在做「方向相符就算得到了」）。
   ⚠️ 我在 08-31 的通報裡寫過「這比 0/12 更硬」——**該句作廢**，即為上述混淆。
2. 🔴 **CRAN 短 key ID 碰撞**：技術事實照記於 repo 內部檔案；**在 Adam 裁定前，
   不寫進任何會對外的稿件（擴寫材料亦算對外），亦不在本輪報告內建議第三方如何修**
   （auditor 08-31 界線）。

## 7. 偏離的兩個分類軸（auditor 08-31；第二軸才決定判定是否成立）

**軸一（原有）**：substantive（改變裝了什麼）／cosmetic（URL、平行度）。
**軸二（新增，更決定性）**：
- 🔴 **differential＝兩臂不同** ⇒ **直接威脅 H-C4a/b 本身**，**任一項出現即停輪**。
- **common-mode＝兩臂相同** ⇒ **不威脅本輪的臂間比較**，只威脅「與該論文 published
  絕對值的可比性」。
- 判例：**`requirements.txt` 的處置屬 common-mode**（兩臂共用同一 image digest、
  同一 Python 環境）⇒ **對 H-C4a/b 無害**，前提是「每 rep 全新 container、同 digest」
  條款＋下述 `pip freeze` 斷言都在。
- 🔴 **措辭紅線（進 §4）**：任何把本輪結果拿去對照該論文那個 11.2 ms 的句子，
  **必須帶環境重建免責**（common-mode 偏離已改變絕對值的可比性）。

## 8. 相依處置的順序＝**環境忠實**優先（auditor 08-31 修正我的隱含選擇）

我原本的三段式隱含選了**文本忠實**（離腳本字面最近＝少裝 > 釘版本）。但**C4 是重跑，
目的是環境忠實**——而 unpinned 在 2017 解析到的是**2017 的最新**，所以「今天的最新」
離原環境**更遠**不是更近。⇒ 修正後順序：

1. `--no-build-isolation`（只改 pip 呼叫、不動他們的檔）。
2. **跳過不在量測路徑上的**（sphinx/sphinx-autobuild＝文件、nose＝測試）——
   跳過它們**不影響量測環境的忠實度**。
3. **②′ 在量測路徑上的（thrift、scapy…）＝釘各套件最後一版支援 py2.7 者**，
   並在報告中**宣告這是「重建」而非「還原」**（2017 的確切版本不可知＝unpinned 的本質）。
4. 皆不行 ⇒ abandon 條款，如實報失敗點。

**兩個必要動作（auditor）**：
- 🔴 **preflight**：把判定為必要的模組在正式跑之前**顯式 import 一次**，缺的當場炸
  ——否則遲綁定的 import 會在量測跑到一半才失敗，而那時已有半份資料。
- 🔴 **每臂 `pip freeze` 存進 raw，並斷言兩臂逐字相同**（裝了什麼是 provenance，
  不能只留在 log 裡）。

[Co-developed with claude code -- Adam]
