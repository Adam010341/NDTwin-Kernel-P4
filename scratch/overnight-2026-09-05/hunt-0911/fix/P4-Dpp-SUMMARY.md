# P4-D'' SUMMARY — ecn 臂的標記檢定鑑別力不足（TICKET-P4-roles §7 裁決 7）

[Co-developed with claude code -- Adam]

- 分支 `fix/ecn-probe-power-0925`（worktree `scratch/overnight-2026-09-05/wt-p4-ecn-0925`），base trunk `11ac9106`
- commit：`ea3ba89c`（只有測試，紅燈先行）→ **`5f985c1e`（修正＋閘門錨點；交付 head）**
- 動到的檔案（都在授權範圍內）：`drive_exercise.py`、`DRIVER.md`、`tests/test_drive_exercise.py`、`tests/shell/mutate_drive_exercise.sh`
- 沒有 lab、沒有 sudo、沒有 live、沒有 C++、沒有 push／merge；主 checkout 沒有 `cd` 進去、沒有寫任何檔案

## 選定的數字

| 常數 | 值 | 用在哪 |
|---|---|---|
| `ECN_PROBES` | **60** | ecn 的 `send.py` 探測封包數（README troubleshooting 第 5 點、README:198 自己建議的值） |
| `ECN_SEND_TIMEOUT` | `ECN_PROBES + 20` = 80 s | ecn 送端的 timeout（`SEND_TIMEOUT` = 60 s 會在尾巴殺掉 60 個探測） |
| `ecn_background_seconds(rw, dw)` | `ceil(rw + ECN_SEND_TIMEOUT + dw) + 5`（預設 3+80+3+5 = **91 s**） | 背景 iperf 的 `-t`；由 CLI 的 `--recv-warmup`／`--drain-wait` 算，不寫死 |
| `SEND_SECONDS`／`BG_SECONDS` | **不動**（6／20） | 只剩 mri／qos 用 |
| 穩定延遲（settling delay） | **不加** | 理由見 dissent 2 |

兩臂的斷言一個字都沒改：solution 仍是「h2 收到的 tos 值裡有 `0x3`」，RED ARM 仍是 `bool(tos) and set(tos) == {"0x1"}`，
injection 列（`>=1`）照舊。另加一個 **E4 步驟**（不是判定列）揭露「60 個裡有幾個在 sniffer 停之前到了 h2、依到達順序的 tos」。

---

## OBSERVED

### A. 本 session 執行過的（log 首行皆為完整 HEAD）

1. **紅燈**（`ea3ba89c`：測試已 commit、driver blob `13f60fda` = base 原檔）——
   `logs/gates-0910/test_drive_exercise.red-first.p4dpp-ea3ba89c.log`：
   Ran 178，FAILED (failures=4)，四個全在 `TheEcnProbeTrain`：
   - `test_the_ecn_sender_is_asked_for_enough_probes`：`6 not greater than or equal to 44`
   - `test_the_background_outlasts_the_whole_probe_train` ×2 subtest：`20.0 not greater than 66.0`／`81.0`
   - `test_the_arm_discloses_how_many_probes_reached_h2_and_in_what_order`：沒有 E4 步驟

   其餘 170 個（既有）綠。新類別的另外 5 個 cell 在 base 上是綠的——它們是**守門**（共用常數不動、送端 timeout、
   RED ARM 對長串仍嚴格、只有 0x3 算標記、判定列不增不減），靠下面的具名變異證明看得到紅。
2. **綠燈**（`5f985c1e`）——`logs/gates-0910/test_drive_exercise.p4dpp-5f985c1e.log`：Ran 178，OK，rc 0。
3. **mutation gate**（`5f985c1e`，經 `guarded_build.sh`，`JOBS=1 LOCK_WAIT=10800`）——
   `logs/gates-0910/mutate_drive_exercise.p4dpp-5f985c1e.log`：baseline 綠（Ran 178）；**`125 mutations, 0 survived`**；
   negative control（只改註解）綠；原檔 **byte-identical**（sha256 `5cb44094…cadf2`＝`git show HEAD:` 的同一個）；
   收尾對原檔再跑一次全綠；rc 0；02:00:30 結束，約 31 分鐘。新增的 107–125 每個都由點名的那個 cell 抓到；
   48（錨點改過）仍由 `test_ecn_runs_a_background_flow_between_h11_and_h22` 抓到，also red 包含新類別的 7 個 cell。
   直譯器 realpath `/home/adam/miniconda3/bin/python3.13`。
4. **check_gate_anchors**——`logs/gates-0910/check_gate_anchors.mutate_drive_exercise.p4dpp-5f985c1e.log`：
   `mutate_drive_exercise.sh  ok(117)`，`1/1 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)`，rc 0。
   （117 = 原本 102 個相異錨點＋新增 19 個變異－與別的變異共用錨點的 4 個：113/115、116/117 與 49、123/124。）
5. 每支閘門前後 `/tmp/drv-*` 皆為 0；`/tmp/drive-exercise-mutate-*` 結束時 0。
6. （**不是閘門**）commit 前用同一張變異表對 48＋107–125 做了一次預覽，20/20 被點名的 cell 抓到；腳本在 session scratchpad，
   結果不當成交付證據——交付證據是第 3 項。

### B. 讀過、沒有執行的 raw（主 checkout 的 `runs/*.md` 是**未提交的觀測**，untracked）

1. **29 份 ecn 報告的 tos 序列**（`doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T*_ecn_*_ndtwin.md`、
   `2026-09-24T16*_ecn_*_ndtwin.md`，逐份抽 E3 的 tos）：

   | 日期 | 臂 | 每次到 h2 的序列（1＝0x1、3＝0x3） | 結果 |
   |---|---|---|---|
   | 09-19 | solution ×5 | `133` `113` `13` `113` `1333` | 5/5 PASS |
   | 09-24 | solution ×10 | `11` `11` `11` `13` `13` `1133` `11` `13` `13` `11` | 5/10 PASS |
   | 09-19 | skeleton ×4 | `11` `1111` `11` `11` | 4/4 PASS |
   | 09-24 | skeleton ×10 | `111` `11` `11` `11` `1111` `111` `111` `1111` `111` `11` | 10/10 PASS |

   - solution 臂 15 次裡，**第一個到的封包 15/15 都是 0x1**；失敗的 5 次都是恰好 2 包、都是 0x1。
   - 09-24 solution：送 60、到 22、其中 0x3 的 6 個。09-19＋09-24 合計：送 90、0x3 的 14 個。
   - 背景 iperf 伺服端每次都是 ~487–488 kbit/s、18–24% loss、interval ~14.4–14.9 s，過與不過無差（同裁決 7 的觀測）。
2. **tutorials fabric 的 `s1.log`**（`/home/adam/tutorials/exercises/ecn/logs/s1.log`，root 擁有、可讀；
   sha256 `a11ddb34…6213`；屬於 `runs/2026-09-24T095442Z_ecn_solution.md` 那次：tutorials fabric、PASS、h2 看到 `1 3 3`）。
   bmv2 debug log 對每個探測封包記下 `enq_qdepth >= ECN_THRESHOLD` 的真假與時間戳。以第一個背景封包為 0 s：
   - 佇列停留時間 0–4 s 都是 0；4–5 s 開始 0.48 s；**5 s 起背景封包約 52% 在佇列被丟**（t=5..14 s：817 進、423 沒有出佇列）。
   - 六個探測：#1 在 3.24 s 出佇列、**未標記**；#2、#3 標記；#4、#5 **沒有任何 egress 記錄**（＝在佇列被丟，見 INFERRED 3）；
     #6 **標記**，但 egress 在 9.23 s、`Transmitting` 在 **12.81 s**。
   - 背景最後一個封包在 14.49 s，早於它的 `-t 20` ⇒ tutorials fabric 上 driver 停背景 client 是有效的。
   - 保存：`hunt-0911/fix/P4-Dpp-evidence/`（gzip 原檔、`s1parse.py`、`s1-timeline.txt`；gzip 還原後 sha256 相同）。
     原檔會被下一次 tutorials ecn run 覆寫。
   - NDTwin fabric 的報告**沒有**交換機 log（bmv2-fast），所以這個時間結構在 NDTwin 上**沒有直接觀測**。
3. 讀過的原始碼：`solution/ecn.p4:131-139`（`ecn==1||2` 且 `enq_qdepth >= 10` 才標 3）、`ecn.p4:9`、
   `send.py:35-41`（`tos=1`、一秒一個、同一個封包）、`receive.py:34`（`udp and port 4321`——背景 iperf 走 5001，進不了樣本）、
   README:128-129（「tos values change from 1 to 3 as the queue builds up」）、README:193-201（troubleshooting 第 5 點，建議 60）。

---

## INFERRED

1. **為什麼 6 個只剩 2 個有用**（由 B.2 的時間戳＋driver 的 sleep 推）：
   driver 停 sniffer 的時間 ≈ 最後一次 sendp 後 1 s（send.py 自己的 `sleep(1)`）＋`DRAIN_WAIT` 3 s ≈ 背景起算 12.4 s；
   #6 在 12.81 s 才由 s1 送出、還要過 0.5 Mbit/s 的 tc 佇列 ⇒ **一個已經標記的探測是被 sniffer 停掉，不是被網路丟掉**。
   第一個探測在佇列形成前出去（必為 0x1），最後約 3 個在飽和時延遲 ~6–7 s、到不了 ⇒ 6 個裡只有 ~#2–#3 兩個能帶答案。
   這同時解釋了「第一包永遠 0x1」和「失敗時恰好 2 包」。
2. **鑑別力算術**（樣本不獨立，全部是 INFERRED）。「誤判」＝資料面有在標記、但 h2 收到的探測裡一個 0x3 都沒有：

   | 模型 | 每個探測成功機率 q | N=6 的誤判 | N=60 的誤判 | 附註 |
   |---|---|---|---|---|
   | ① ticket 的框法：到達率 2/6–4/6 × 標記率 1/2 | 1/6 … 1/3 | 0.335 … 0.088 | 1.8e-5 … 2.7e-11 | |
   | ② 09-24 每個**送出**的探測：6/60 | 0.10 | **0.53**（觀測 5/10） | **0.0018** | 1% 需 N ≥ ⌈ln 0.01 / ln 0.9⌉ = **44**（測試裡的下限） |
   | ② 合併 09-19＋09-24：14/90 | 0.156 | 0.36（觀測 5/15） | 3.9e-5 | |
   | ③ 每個**可能帶答案**的探測：09-24 每次 ~2 個 ⇒ 6/20 | 0.30 | 0.49 | 2.1e-9（~56 個可用） | 用 B.2 的時間結構 |

   ②、③ 在 N=6 都重現了 09-24 的 5/10，所以不是事後湊的。
   **信賴區間**：② 的 6/60 的 Clopper-Pearson 95% 是 [0.038, 0.205]；取下緣 0.038 時 N=60 的誤判是 **0.10**（要 <1% 需 N=121）。
   但 ② 的分母裡有「第一包」和「被 sniffer 停掉的尾巴」這兩種結構性的非樣本，N 變大時它們不跟著變多，所以 ② 的下緣是過度悲觀；
   ③ 的 6/20 取 CI 下緣 0.119，N=60（~56 個可用）的誤判是 8.3e-4。
   合併資料 14/90 的 CI 下緣 0.088，N=60 是 0.004。**結論：N=60 在所有點估計下都遠低於 1%，只有「②＋CI 下緣」這一格不是。**
3. `s1.log` 裡 #4、#5「沒有 egress 記錄」＝在 egress 佇列被 tail-drop：這是推論（bmv2 在 enqueue 失敗時不寫 debug log；log 本身一路寫到 19.6 s、沒有中斷）。
4. 飽和時的延遲鏈（tc 佇列塞滿 → bmv2 transmit 被擋 → output buffer → egress 佇列）是用 Linux／bmv2 的行為推的，不是這份 repo 的原始碼；
   觀測只有 egress 與 `Transmitting` 的時間差（#6 為 3.58 s）。
5. **NDTwin fabric 的動態與 tutorials 相同**：兩邊背景 iperf 的數字一致（~488 kbit/s、~20% loss），且 solution 臂的序列形狀一致——推論，未觀測。
6. **N=60 之下的預期**：~#2 到 ~#57 在飽和佇列之後，其中約一半被丟、進得去的都會被標記；E4 會顯示大約「25–35 of 60」、
   第一個 0x1、之後多數 0x3——這是預測，要等 orchestrator 的 `ONLY=ecn` ×5 才知道。
7. **時間成本**：ecn 每一臂多 ~54 s（60 vs 6 個探測），06 的 ecn 兩臂合計多 ~2 分鐘；tutorials 對照組同。
   報告的 E3 會變長（每個到達的封包一段 show2，~0.7 KB），E2 多 54 行 `Sent 1 packets.`。

---

## dissent（我做了、但 orchestrator 可能要改的判斷）

1. **N=60 而不是 120。** 只有「② 的 CI 下緣」需要 N≈121；其他所有點估計在 60 就 ≤0.2%。選 60 是因為它就是 README 自己的建議值、
   而 ② 的下緣把結構性非樣本算進分母。如果要讓最悲觀的那一格也 <1%，把 `ECN_PROBES` 改 120 即可（`ECN_SEND_TIMEOUT`、背景 `-t` 會跟著走，
   測試的下限 44 不用改），代價是 ecn 每臂再多 ~1 分鐘。
2. **不加穩定延遲。** README step 3 的宣稱是「隨佇列累積從 1 變 3」（README:128-129），佇列形成前送出的探測就是「1」那一半；
   它們不可能讓「0x3 among」失敗，只會稀釋，而 N=60 時幾乎整串都在滿佇列之後送出。加延遲買到的東西 N 已經買到了，還會把「1」從 transcript 拿掉。
   從原始碼來的理由只有這一條；「佇列約 4 s 才形成」是 B.2 的一次觀測，我沒有拿它來定任何常數。
3. **揭露做成步驟（E4），不是判定列。** ticket 允許加一列「for disclosure only」；但 `Expect` 沒有「只揭露」的型別，任何一列都算進 `PASS (n/n)`，
   一列永遠 PASS 的就是「不會失敗的檢查」。所以做成步驟，並用測試＋變異 125 釘住「它不准變成判定列」。若 orchestrator 要一列，這是一個可以翻的決定。
4. **沒有延長 ecn 的 drain。** INFERRED 1 說飽和時最後 ~3 個探測會在 sniffer 停之後才到；N=60 時這只少掉 ~3 個樣本、不影響鑑別力，
   所以沒有動 `drain_wait`（ticket 沒要求、而且它是 CLI 旗標、各臂共用）。E4 的文字寫的是「before the sniffer was stopped」，不把短少說成網路丟包。
   若要讓 E4 的數字等於網路真的送到的數，ecn 專用的 drain 要 ≥7 s。
5. **背景 `-t` 的溢出面變大。** 背景是由 driver 在 sniffer 之後用 handle 停的，`-t` 只是上限。如果哪天停不掉，
   舊的會多跑 20−14.5 ≈ 5.5 s 進 G1 通用格，新的會多跑 91−~70 ≈ 20 s。B.2 觀測到 tutorials fabric 上有停成功；NDTwin 上走的是
   和 receiver 同一條 `sudo -n mnexec` + SIGTERM 路徑（receiver 每次都停得掉），所以推論也停得掉，但沒有直接觀測。
6. ticket 寫 base 為 `18dd0408`，worktree 實際在 `11ac9106`；兩者差別只有 `TICKET-P4-roles.md`（`11ac9106` 就是寫裁決 7 的那個 commit）。

---

## disclosures

1. **直譯器**：worktree 沒有 `p4_proxy/venv`（untracked），所有閘門用主 checkout 的 `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python`
   （絕對路徑、`PYTHONDONTWRITEBYTECODE=1`，realpath `/home/adam/miniconda3/bin/python3.13`），跟 P4-D／D' 的閘門是同一支。mutation gate 用 `PYTHON=` 覆寫。
2. 測試裡的 `NoSleep` 替換的是**被測模組**的 `time`（每個 cell 都 `load_driver()` 一份新的），只為了在出貨的 3 s／3 s 等待下跑 arm 而不真的睡。
3. `TheEcnProbeTrain.arm()` 會把 `steps_for()` 歸零的 `SEND_SECONDS`／`BG_SECONDS` 放回出貨值，因為「ecn 不再用共用數、mri／qos 還在用」是關於出貨值的宣稱。
4. 測試常數 `PROBE_SPACING = 1.05`、`SENDER_STARTUP = 5` 是 cell 自己的容許量；1.02–1.03 s 的間距是 B.2 的觀測，0.24 s 的啟動時間也是 B.2 一次觀測。
5. mutation gate 48 的錨點因為背景呼叫多了 `seconds=` 而跟著改；替換內容不變。新增變異 107–125，每個新 cell 至少紅一次：
   107/108→探測數下限；109/110/111→送端 timeout；112/113/114/115→背景蓋過整串（113、115 只在放大的 12 s／9 s subtest 紅，這就是那個 subtest 存在的原因）；
   116→RED ARM 讀整串；117→RED ARM 需至少一包（既有 cell）；118→只有 0x3 算；119/125→判定列不增不減；120/121→mri／qos 共用常數；122/123/124→E4 揭露。
6. 沒有做的：沒有 live、沒有估修後誤判率（那是 orchestrator 合併後在主 checkout 跑 `ONLY=ecn` ×5 的事）、沒有碰 mri／qos 的斷言。
7. B.1 的 29 份報告和 B.2 的 `s1.log` 都在我的 worktree 之外、沒有進版控；我唯一寫在 worktree 外的是本檔與 `P4-Dpp-evidence/`、`logs/gates-0910/*.p4dpp-*.log`。
