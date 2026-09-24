### 裁決 40（09-24）：E 第十輪 `bc1db4c0` 的裁定＋PREREG 沒寫到可機械執行的那幾條，怎麼報

⓪ **交件與核對**：worker 交 `DELIVERED bc1db4c0`（六個 commit，含併 trunk 的 `56d83ee8`，無衝突）。我逐 hunk 讀完 15 檔（+1408/−44）；
   `analyse.py` 的 `all_registered_rates`／`registered_sampling`／`registered_cross_group`／`cpu_comparison(registered=)`／`bmv2_ratio` 與 PREREG `:251-254`、`:262-277` 逐條對過。
   我在其 head 重跑：unit 94×2（venv＋conda）、offline 78/0、gate self-test 14/0、hazard 4 檔 0、anchor sweep 45 gate＋13 external 全解析、`check_gate_anchors` 115/115、mutate（見 log）。
   判官：〈填〉。**這次判官是在 worker 的最終通知之後才派的**（裁決 39⓪a 的規矩守住）。
   worker 的 commit trailer 寫 `Claude Opus 5.5 (1M context)`——**採**：那是真正做事的模型；我指令裡的 Fable 5.1 是複製自己的 trailer 規則，錯在我。

① **組級判決採用**（唯一可進 FINDINGS 的層）：`cooperative`「neither H-B1 nor H-B2 holds as registered」（2 M 0.2953 > 帶上緣 0.2853、符號混；100 M 在帶內）、
   `link`「H-B1」（三速率都在帶內）、「not H-B4」（2 M link/coop 0.253 ∉ [0.5, 2.0]；20 M 1.255、100 M 1.489 在內）。逐格描述留作資料。
   數字與 09-19 的 summary 逐葉相同（1424 個），只有標籤層變。

② **H-C2 的第二條件（`:271`「Δ(高階)/Δ(低階) ≈ S(高)/S(低)」）沒有註冊容差 ⇒ 本輪不可判。** link：第一條件成立（share 0.0623 ≤ 0.2），第二條件 31.5 vs 58.7（0.537）。
   FINDINGS §4 對 link 寫「H-C2 as registered：**undecidable**（第一條件成立、第二條件無註冊容差）」，**不准**事後挑一個容差把它判成立或不成立。
   候選（不套用於本資料）：下一輪 PREREG 補「≈」＝比值 ∈ [0.5, 2.0]（與其他帶同口徑）。

③ **H-C1 與 H-C2 的先後（cooperative）**：H-C1 成立（m 122.9 ∈ [103, 618]），H-C2 的第一條件也成立（share 0.0722 ≤ 0.2）。PREREG 沒註冊先後，
   但 H-C2 需兩條件且第二條不可判 ⇒ H-C2 本輪無法成立 ⇒ 沒有真正的衝突。裁：cooperative 報 **H-C1**，FINDINGS 必須同時寫「H-C1 成立的依據只有 m 落帶；固定份額 0.072 那條不成立、H-C2 的第一條件反而成立」。

④ **H-C0 的散佈量**：碼用兩臂原始 CPU 全距、PREREG `:273` 用同一格三窗／三 rep 的 Δkernel 散佈。**本輪不改碼、不重算**（事後換散佈定義＝換判準）；
   第五次 11 階 0 個 unresolved（worker 量的），差異沒改變任何判決。登記 FINDINGS §6；PREREG 明確化＝下一輪。「部分格不可解時整組擬不擬合」與 `S_top` 定義同樣登記（第五次都不適用／相同）。

⑤ **H-A2 跨 frame／跨遍**：PREREG `:220`「< 0.60 且兩個 frame 尺寸與兩遍都同向」，碼逐 (組, frame) 只驗 < 0.60。第五次：link/none 64 B 0.533、1024 B 0.533；
   兩遍 link 12／20 vs none 30／30 都在下方 ⇒ 註冊條件成立（我從 summary.json 的 cells 抽的，不是碼判的）。FINDINGS §2 的 H-A2 只引**一次**（組級），並列四個值；碼的組級彙總＝第十一輪候選。

⑥ **`external_gate` 把負殘差跟 `-1` 哨兵一起丟**：`none_f64_b` external −0.0096 不在閘門也不在 `none` 中位數（3 臂 0.0560 vs 4 臂 0.0355）；兩種算法都無臂觸發。
   FINDINGS §1.2 註明 11 列＋這一臂的值。修法（只丟 −1）＝第十一輪候選，紅先＋變異。

⑦ **`members[0]` 的 N**：link 20 M／100 M 第一窗讀 5 條、另兩窗 4 ⇒ 帶用 N=5；改用註冊的 4 條同樣在帶內，判決不變。FINDINGS §3 逐格揭露 `links_used` 與三窗值；候選：每窗各自的 N 或註冊的 4。

⑧ **H-B3「該視窗」計數來源**：碼加總梯子臂的 emitter 計數；第五次無 ratio > 2.0，不觸發。登記。

⑨ **FINDINGS §6 第 6 條**：原引第四次的 18/9，改成第五次 {0: 9, 4: 16, 5: 2}（已改）。

⑩ **併入**：〈判官結果後填：merge --no-ff、merged_checks、推送〉。
