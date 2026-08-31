# C4 primary-list 草案（凍結前、資料接觸前；待 auditor 快核 → 併入 PREREG-C4 §3 → v1.0）

**規則來源**：auditor 08-31 三條（規則先於清單，免得清單長成資料的形狀）——
①open/closed 兩個都登記（避免 data-dependent selection）；②若機時只能選一個，
**理由必須先驗、寫進 prereg 才凍結，且明記被放棄者與理由**；③六個候選逐個標
入 primary／secondary／不報，**secondary 不得在結果期升級**。
**輸入**＝`C4-whippersnapper/RECON-R2-install.md` §5–§6（讀碼列舉，非跑出來的）。

## 1. 兩個 primary（兩個不同的問題，各自獨立適用 H-C4a/b）

| 臂 | Primary 指標 | 單位（**逐項寫死**，因 artifact 自身單位不一致） | 檔 |
|---|---|---|---|
| **closed-loop** | **P1** 每 1000-封包窗的平均 RTT（修剪序列）與其平均 `avg_latency` | **秒**（`parse_results.py` 的窗均值單位） | `results.tsv` |
| closed-loop | **P3** `sent recv lost tput duration` 的 **loss fraction** 與 **tput** | loss＝無單位分數；tput＝**pkt/s**；duration＝秒 | `load_stats.tsv` |
| **open-loop** | **P4** 每秒 `(recv_count, mean_latency_µs)` 序列的**平均延遲** | **微秒**（`main.c:153` 原生單位，不換算） | `latency.csv` |
| open-loop | **P5** 最終 `sent recv loss_fraction` | 無單位分數 | `loss.csv` |

- **H-C4a/b 逐指標各判一次**（四個 primary ⇒ 四個獨立判定），不合成單一總分。
- 🔴 **單位不得跨指標換算後比較**（artifact 自己 µs／秒／ns 三種混用，見 RECON §5g.4）；
  跨指標並列一律標事後探索（同 PREREG-C4 §4 的跨代碼庫免責同構）。

## 2. secondary（報、但**不得在結果期升級為 primary**）

| # | 指標 | 為何不入 primary |
|---|---|---|
| **P2** | `p99/p95/std/cv`（同窗） | 分布細節；頭條是中央趨勢，登記 tail 會多開四個判定面 |
| **P6** | pen_* 掃描裡「零損下最大 offer_load」 | **最像我們自家梯階的量**，正因如此**不入 primary**：它需要選一個 loss 門檻（artifact 未定義），而我方門檻（0.5%）**不得輸入到別人的管線**（那就是拿我們的儀器量他們的系統）。若 pen_* 有跑，僅以「artifact 自身零損定義」報為 secondary |

## 3. 不報

- PISCES／MoonGen 側（RECON §5f）＝容器範圍外、非 bmv2 臂。
- artifact README 提及但**檔案不存在**的 `analyse.R`／`plot.R` 衍生統計（RECON §5g.1）
  ——**無法產生，且此缺席本身列為可重現性發現**（見 §5）。

## 4. 先驗的放棄順序（規則②：現在就寫死，不等機時壓力出現）

若機時／容器穩定性只容一個 loop：**保留 closed-loop（P1+P3）、放棄 open-loop（P4+P5）**。
**先驗理由**：受測論文的頭條量是**延遲類**（parse 1 header 11.2 ms），closed-loop 的 P1
與該頭條同量類；C4 的問題是「他們自己那條管線的頭條會不會動」，因此保留與頭條同類者。
🔴 **此理由與任何實測值無關、且已在資料接觸前寫下**；放棄 open-loop 一事**必須在報告
中可見**（不得靜默省略）。反向（保留 open-loop）**不允許**——除非 closed-loop 在偵察
階段即證明不可跑，且該證明落檔。

## 5. benchmark feature 的範圍（同屬先驗選擇）

artifact 產生器有九個 feature（RECON §4）。**primary feature ＝ `parse header`**——
先驗理由同上（論文頭條即該類）。其餘八個：**不跑**（機時）；若跑則一律 secondary。
🔴 不得因為某個 feature「動比較多」而事後改列 primary。

## 6. 併入 PREREG-C4 時要一起帶的兩句

1. **可重現性發現節**（RECON §5g 的三件）：thrift 鏡像已死、`analyse.R`/`plot.R` 缺席、
   單位不一致——**皆為親手撞到的一手證據**，屬 C4 的獨立產出，與 H-C4a/b 判定無關。
2. 🔴 **CRAN 短 key ID 碰撞**：技術事實照記於 repo 內部檔案；**在 Adam 裁定前，
   不寫進任何會對外的稿件（擴寫材料亦算對外），亦不在本輪報告內建議第三方如何修**
   （auditor 08-31 界線）。

[Co-developed with claude code -- Adam]
