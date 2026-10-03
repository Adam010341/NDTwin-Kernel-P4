# P4 健檢 Cut 0 與 Cut 1：交付摘要（第 2 輪，審查後）

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-health-cut1`，基於 trunk `995bdfd0`。
- **本輪的 head**：`cb8cbaf6`。
- **本輪的三個 commit**（疊在 88b4848c 之上）：
  - `096d261a`：程式碼；
  - `74949de9`：測試；
  - `cb8cbaf6`：設計稿副本 §14 與預測檔。
- **設計稿**：本目錄 `DESIGN.md` 的 r6 原文未動。
  - §13 是 Cut 1 加的。
  - §14 是本輪審查之後改的設計。每一處都標「r2 (Cut 1 review)」，總共 9 處，**未經審查**。
- **沒做**：`ndt up/claim`、Mininet、sudo、C++ build、push。
- **這次跑過的 bmv2 全是拋棄式的**，每一支都沒碰 lab 的埠：
  - `ndt-hc-selfcheck-bmv2`，Thrift 埠 29500 起；
  - `ndt-hc-vstrial-bmv2`，`simple_switch_grpc`，gRPC 埠 29650；
  - drop check 自己的 `ndt-hbdrop-bmv2`。
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut1/`：
  - 第 1 輪的證據在 LOG 根目錄；
  - 本輪的在 `LOG/r2/`。

## 1. 觀測到的（OBSERVED，本輪；commit 寫在每份 log 的第一行）

### 1.1 S0（`LOG/r2/s0-final/probe.log`）

- **這一份是在哪個 commit 上跑的**：第 1 行記著 HEAD `cb8cbaf6…`（commit）與 probe tree `6b120501…`（`tools/p4_health` 的 git tree）。gate 的表頭（`LOG/r2/mutate_p4_health.log` 第 5–6 行）記的是同一對。
- **結果**：rc 0；49 項檢查全部 ok；COMPLETE。
- **binary 的身分**（第 48 行與 `s0.json` 的 identity；sha16 是 sha256 的前 16 位，version 取自 `--version`，執行時用 `ndt-hc-version-*` 這個名字的 symlink）：

| binary | sha16 | version |
|---|---|---|
| p4c | `226f3f66df515c9e` | 1.2.5.15 (SHA 5b948b037a) |
| stock simple_switch | `4c5e5ad31b0a8b4b` | 1.15.3-f0b7d201 |
| stock simple_switch_grpc | `327fa7d172217397` | — |
| fabric 的 simple_switch_grpc（bmv2-fast） | `3ff54b5c1901c9d3` | — |
| simple_switch_CLI | `590b4b32e0db8d98` | — |

- **p4info**：
  - 六份 build 的 p4info sha 與第 1 輪相同：hc_main 是 `5ce0a5595d5a65f1`，hc_alt 是 `b7490e9eb9979888`。
  - mutant／fwd 的 p4info 與原版逐位元相同（第 8–11 行）。
  - json 的 sha 和第 1 輪不同：bmv2 json 內嵌了編譯時的絕對路徑，run 目錄換了，sha 就跟著換。
- **清點**：29 項構造都在。mcast_grp 與 enq_qdepth 現在要求 action 裡**真的有使用**（MINOR 12）：mcast_grp 被賦值，enq_qdepth 被讀取。
- **pre-flight**：A、B、C 都 PASS。PF-T 只在 G5 那一列 FAIL。
- **drop check**：A、B、C 都 rc 0，FWD rc 1（第 24–27 行）。
- **拋棄式 bmv2 上的自檢**（第 28–46 行）：

| 跑的 build | 結果 |
|---|---|
| main、alt、fwd | 7 項自檢全部 ok |
| mutant | 恰好 SC-count、SC-qstamp、SC-ttl 三項失敗 |

  - fwd 那一次，0x88B5 的檢查**看到了紅**：3 個心跳幀離開了交換機（第 36 行，MINOR 13）。
  - 其他三次，0x88B5 都是 0 個離開。
  - 每個輸出 pcap 都讀得到。
  - 每次 throwaway 啟動都驗了 `switch_info` 的 device id，所以連到的確定是剛啟動的那支。
- **ValueSetEntry 的試驗**（第 47 行與 `s0.json` 的 vs_trial；stock 與 fast 兩支 `simple_switch_grpc` 都試了）：
  - Write 回 `canonical_code 12`：「ValueSet writes are not supported yet」。
  - Read 回 UNIMPLEMENTED。
  - 寫之後、讀之後，兩支交換機都還活著。
- **openapi**：15 條 path。
- **PF-T**：RED（structural＋static）。

### 1.2 測試與閘門（全部在 cb8cbaf6）

| 檢查 | 結果 | log |
|---|---|---|
| cells 測試 | 84 tests OK，在 Python 3.8.20、3.12.3、3.13.13 上都跑過 | `r2/test_cells.py*.log` |
| collect 測試（封死） | 52 tests OK（3.8.20、3.12.3、3.13.13）；seal 報告：52 個測試都檢查過，tripwire 0、網路嘗試 0、spawn 0、真實檔案變動 0 | `r2/test_collect.hermetic.py*.log`、`r2/seal_report.green.py3.8.20.json` |
| 故意不封死的 H1：真的 Runner | 紅；tripwire 抓到 `simple_switch_CLI --thrift-port 9092` | `r2/test_collect.nonhermetic.H1.log`、`r2/seal_report.H1.json` |
| H2：連 localhost:8081 | 紅，6 個 failures；被拒的是 `create_connection ('localhost', 8081)` | `…H2.*` |
| H3：`os.system` | 紅；被拒的是 `os.system('ndt status')` | `…H3.*` |
| H4：連 127.0.1.1:8081 | 紅；被拒的是 `create_connection ('127.0.1.1', 8081)` | `…H4.*` |
| `test_p4_health_recover.sh` | 31 checks，0 failed | `r2/test_recover.log` |
| mutation gate | **109 mutations，0 survived**；只改註解的負對照維持綠；原檔 byte-identical | `r2/mutate_p4_health.log` |
| `check_test_tmpdirs` | 412 個檔，0 個寫死的 temp 路徑 | `r2/check_test_tmpdirs.log` |
| `check_gate_anchors`，只看 `mutate_p4_health.sh` | ok(109)：distinct anchor 109 個，因為 D5 與 C4 共用同一個 anchor | `r2/check_gate_anchors.p4_health.log` |
| `check_gate_anchors`，全部 | 132/132 ok | `r2/check_gate_anchors.all.log` |
| `test_l1_shell_scoring.sh` | 163 checks，0 failed | `r2/test_l1_shell_scoring.log` |
| 用 L1 lane 自己的評分規則評三個新檔 | 三個都 PASS（84／52／31） | `r2/l1_lane_sim.log` |
| 磁碟 | 3968 MB 可用。worktree 74 MB，LOG 11 MB | — |
| 殘留 | `ps` 裡沒有 `ndt-hc-*`／`ndt-hbdrop*` 行程；`/tmp` 沒有 `p4h-*` 殘留 | — |

- **gate 第一次跑時抓到的是 gate 自己的缺陷**：突變用的副本缺了 `p4_proxy/mininet/grpc_ports.py`，所以每個突變底下都有兩個 throwaway 測試是紅的，負對照也跟著紅。
- **修法**：gate 的副本現在會抄這一個檔。
- **重跑之後**：「also red」裡不再出現那兩個測試，負對照綠。

## 2. 推論的（INFERRED）

1. **openapi**：「proxy 的 route 只有這 15 條」是 grep 的推論：`main.py` 裡沒有 `@app.get`／`@app.post`。這點和第 1 輪相同。
2. **PF-T 的 static 歸因**：證據是拋棄式 stock bmv2 經 **thrift** 收下並 dump 回一筆 ternary entry。PF-T 那一列寫的是「同 T4 的 bmv2」，指的是 B 經 P4Runtime。兩條路不一樣（MINOR 1），P4Runtime 那一條在 Cut 2 補。
3. **Q3(b) 的預測**：HR1、HR2、HU1 都還是讀碼得來的。RC1＝V1、VB1＝CH3 是 alias，跟著來源格的預測走。
4. **VS1**：bmv2 的 P4Runtime 不支援 value set，這點是觀測到的。但「NDTwin 日後加了 route，VS1 仍然只能判 UNATTRIBUTED」是推論。
5. **pcap 模式下 qdepth 一律是 0**：Q1 只能在 live 證明。
6. **磁碟**：第 1 輪少掉的約 126 MB，大部分是 worktree 本身（現在 74 MB）。其餘推測是共用這顆磁碟的其他 session，沒有量。

## 3. 審查的發現：逐條怎麼處理

**MAJOR 全部採納，沒有反駁。** 每一條都先對過碼。

| # | 處理 | 主要位置 | 守住它的測試 |
|---|---|---|---|
| MAJ-1 | 每格宣告它需要的讀數（`need`）；步驟 4b：缺一個就 NOT RUN。比較函式要求自己的正向鍵；T1／PL1 要涵蓋 s1–s4；TP1 的清單不能是空的；CS1 的答案不能是空的 | `cells/verdict.py` 的 `missing_reading`；`cells/table.py` 的各列 | `test_an_empty_answer_or_oracle_is_never_green`、`test_every_need_key_is_needed` |
| MAJ-2 | 步驟 0：答案讀不到就 NOT RUN。observer 在讀不到時交 `answer=None` | `verdict.decide`、`observe.py` | `test_an_unreadable_answer_is_not_run`、`test_unreadable_switch_state_is_no_answer` |
| MAJ-3 | 對照先判。步驟 0b：K1／T3 跟著自己的對照走。對照要端點自己的 404 `{"error": "not in this pipeline"}`；FastAPI 的 Not Found 不算。health.json 新增 `controls` | `verdict.control_problem`、`table.Control`、`report.py` | `test_k1_and_t3_follow_their_controls`、`test_controls_are_in_health_json` |
| MAJ-4 | 審查列出的每個分支都有一個由它自己決定結果的 fixture，再加一個 mutant。涵蓋：T1 與 PL1 的 thrift 那一半、G1 的積分與 off-path、TP4 的 drop check 與 withheld、CP4 的負讀旗標、HU1 的 SC-union 邊、rates／r2／r3／d1／delivered／it1、INCOMPLETE、throwaway 的埠守門 | — | gate 的 B1–B15、N1–N7 |
| MAJ-5 | recover.sh 認 ndt 自己寫的 up／down note；fixture 改用真實的「in use: ndt up p4 … by <owner>」 | `recover.sh` 第 2 步 | recover 測試的 happy 與 afterdown；gate 的 R1、R6 |
| MAJ-6 | 行程以 pid＋start time＋marker 認，停掉之後從 `LAB_STATE` 移除；重新 claim 只接受「是自己的或沒有 owner，而且沒有量測」；teardown 在每個改共用狀態的步驟之前重讀 claim | `lab_round.py`、`recover.sh` | 6 個新的 LabRound 測試、4 個新的 recover 情境；gate 的 L1–L6、R3–R5 |
| MAJ-7 | 一發生就拒絕：stub 以外的 spawn、`os.*` 的各種 spawn、所有 inet 的 connect／send（127/8 全部、`::1`、IPv4-mapped、任何位址）；真實的 knob 檔與 claim 檔做指紋比對；`P4H_HERMETIC` 下 Config 不准用預設值 | `test_p4_health_collect.py` 開頭、`collect/config.py` | `TestTheSealHolds`；H1–H4 |
| MAJ-8 | HR1／HR2 用安靜窗比，HR1 要恰好一條上行；IT1 用 thrift 的 `Life:` 那一行，加負讀；VS1 先在拋棄式 grpc 上試過 | `table.multipath`／`hr_pre`／`it1`；`vs_trial.py` | `test_hr_*`、`test_it1_*`；S0 第 47 行 |
| MAJ-9 | VB1→CH3、RC1→V1，都改成 alias，理由寫在 `alias_why` | `table.py` | `test_aliases_carry_their_sources_verdict` |
| MAJ-10 | 三組 rollup：core 16、full 16、q3b 6 | `verdict.rollup` | `test_three_rollups_sixteen_sixteen_and_six`、`test_the_predictions_give_the_three_rollups` |

**MINOR**

- **做了**：
  - 2：PF-T 沒有觀測時判 NOT RUN。
  - 3：SC-count 拿掉 netdev 那種比法。
  - 4：SC-union 的跳數改從 `v6_host` entries 走。
  - 5：HU1 兩個成員都判，加上側表上限的前提。
  - 6：AS1 改成要求 entry 指向 group。
  - 7：訊息的措辭改了。
  - 8：thrift 的唯讀檢查改成精確比對，也擋換行；拿掉死碼。
  - 9：docstring 改正。
  - 10：讀不到就回 None，不回空的。
  - 11：lab 的埠清單改從 `grpc_ports` 讀；驗 device id；PDEATHSIG 設不起來就不跑。
  - 12：清點改成要求真的有使用。
  - 13：fwd build 跑在拋棄式交換機上，看到紅。
  - 14：S0 記錄 HEAD、probe tree、p4c 與各個 bmv2；gate 的表頭記錄 HEAD 與 tree。
  - 15：tools/ 裡沒有 `/home/<user>` 字面路徑，p4dev 由 `P4H_P4DEV_PY` 或家目錄推出；有測試守。
  - 16：gate 不再用 xargs。
  - 17：D7 改成 `return out`。
  - 19：`probe.py judge` 預設不算完成；對照的預期改從 tsv 讀。
  - 20：netem 加失敗就移出清單。
  - 21：對照要錯誤字。
  - 23：一個樣本都沒抽到就 NOT RUN。
- **只寫成註記**：
  - 1：PF-T 的 static 歸因走 thrift，見 §2 第 2 項與 DESIGN §14.5。
  - 18：CS1 是 gate，但沒有任何依賴邊，留給設計審查。
  - 22：P4 的 `bmv2` 歸因是什麼意思，寫在 `p4()` 的 docstring。
- **只做了一部分**：
  - 11：PDEATHSIG 沒有測試。
  - 15：公開的碼裡仍以「the design」稱呼設計稿，沒有寫路徑。

## 4. 第 1 輪摘要的數字更正

1. TestLabRound：第 1 輪是 16 個，不是 17 個。17 是當時 recover 測試的 check 數。本輪 TestLabRound 有 23 個，recover 有 31 checks。
2. thrift fixture 有 29 份（含 `no_switch.txt`），不是 28 份。
3. L1 的 glob 在 `l1_unit_tests.sh:591`，不是 :589。
4. 「每一項 §12 都有 12-x 突變」這句不對。現在的狀況：
   - 12-5（mutant 的 p4info 逐位元相同）只有 S0 的 live 檢查，沒有 mutant；
   - 12-6 由 M8 守；
   - 12-9 由 H1–H4 守；
   - 12-11 由 R3、R4 守，加上 recover 測試的 expired 情境。
5. 「29 項構造」在第 1 輪實際只證明了 27 項；本輪 29 項都已證明（MINOR 12）。
6. p4c 的版本與 sha 本輪有 log 了（S0 第 48 行）。
7. 「C++ 沒 build、沒 push」沒有 log 可證；作為宣稱，照實記載。

## 5. 設計項目與 done-check

- **Cut 1 的設計項目 → 檔案 → 測試**：對照表同第 1 輪 §4，以下是本輪新增的列：

| 設計項目 | 檔案 | 測試 |
|---|---|---|
| 步驟 0／0b／4b | `verdict.py` | 見 §3 |
| 三組 rollup | `verdict.rollup`、`report.py` | 見 §3 |
| VS1 的試驗 | `vs_trial.py` | S0 第 47 行 |
| 行程身分與 claim 重讀 | `lab_round.py`、`recover.sh` | 見 §3 |

- **done-check**：

| # | done-check | 證據 |
|---|---|---|
| 1 | 每個突變都被它指名的測試抓到；負對照維持綠 | `r2/mutate_p4_health.log`：109／0、負對照綠 |
| 2 | test_collect 封死，故意不封死的會紅 | `r2/seal_report.green.*` 全部為 0；H1–H4 全部紅 |
| 3 | S0：drop check、自檢、p4info | `r2/s0-final/probe.log` 第 8–11 行、24–27 行、28–46 行 |
| 4 | repo 自己的檢查 | 見 §1.2 |
| 5 | 磁碟與清理 | 3968 MB；scratch 已清 |

## 6. 給設計審查的

DESIGN.md 的 §14 要審：
- 新的判定步驟；
- 改過的 Q3(b) 各格；
- 第三組 rollup；
- 當機收拾的規則；
- VS1 改成預測 UNATTRIBUTED。
