# P4 健檢 Cut 0 與 Cut 1：交付摘要（第 3 輪）

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-health-cut1`，從 trunk `995bdfd0` 開。
- **本輪 head**：`57dd9c5a`。程式碼在 `7e68dcf9`，測試在 `7c0c290f`，設計稿副本與預測在 `57dd9c5a`；都疊在 `cdd7a951` 之上。
- **設計稿**：本目錄 `DESIGN.md` 的 r6 原文沒有動。
  - §13 是 Cut 1 加的。
  - §14 是第 1 次審查之後改的，標「r2 (Cut 1 review)」。
  - §14.6 是第 2 次審查之後改的，標「r3 (Cut 1 review)」。
  - 以上都**未經審查**。
- **沒做**：`ndt up/claim`、Mininet、sudo、C++ build、push。
- **跑過的 bmv2 全是拋棄式的**：
  - `ndt-hc-selfcheck-bmv2`，Thrift 29500 起；
  - `ndt-hc-vstrial-bmv2`，gRPC 29650；
  - drop check 自己的 `ndt-hbdrop-bmv2`。
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut1/`。
  - 第 1 輪的證據在 LOG 根目錄，第 2 輪在 `LOG/r2/`，本輪在 `LOG/r3/`。
  - **r3 的每一份 log 第一行**都是 `commit 57dd9c5a… tree 0eb56ed9…`。gate 的 log 例外：同一對寫在第 5–6 行。

## 1. 觀測到的（OBSERVED，r3，都在 57dd9c5a）

| 檢查 | 結果 | log（`LOG/r3/` 底下） |
|---|---|---|
| S0 | rc 0；49/49 ok；COMPLETE。第 1 行是 HEAD 57dd9c5a、probe tree 0eb56ed9 | `s0-final/probe.log` |
| cells 測試 | 92 tests OK（Python 3.8.20、3.12.3、3.13.13） | `test_cells.py*.log` |
| collect 測試（封死） | 55 tests OK（同上三版）。seal 報告：55 個測試都檢查過，tripwire 0、網路嘗試 0、spawn 0、真實檔案變動 0 | `test_collect.hermetic.py*.log`、`seal_report.green.py*.json` |
| 故意不封死的 H1–H4 | 全部紅：真的 Runner（tripwire）、連 localhost:8081、`os.system`、連 127.0.1.1:8081 | `test_collect.nonhermetic.H*.log`、`seal_report.H*.json` |
| recover 測試 | 41 checks，0 failed | `test_recover.log` |
| 舊碼看到紅（NEW-C） | 第 3 輪的測試對 cdd7a951 的 recover.sh 跑：41 個 check 有 7 個 FAIL，其中 4 個是 down-done 的情境 | `test_recover.old_code_red.log` |
| down 之後的收拾，舊碼與新碼對照（NEW-C） | qdisc stub 報告漂移。舊碼（phase 是 teardown）rc 4，停在 qdisc 比對，沒有 release。新碼（phase 是 down-done）rc 0，只呼叫 `ndt status` → `ndt release` → `ndt status` | `recover_after_down.old_vs_new.log` |
| mutation gate | **130 mutations，0 survived**；只改註解的負對照維持綠；原檔 byte-identical | `mutate_p4_health.log` |
| `check_test_tmpdirs` | 412 個檔，0 個 | `check_test_tmpdirs.log` |
| `check_gate_anchors` | 本 gate ok(129)，全部 132/132 | `check_gate_anchors.*.log` |
| `test_l1_shell_scoring` | 163 checks，0 failed | `test_l1_shell_scoring.log` |
| 用 L1 lane 的評分規則評三個新檔 | 都 PASS（92／55／41） | `l1_lane_sim.log`、`l1sim_*.log` |
| 磁碟 | 3864 MB 可用。沒有殘留行程，`/tmp` 也沒有殘留 | — |

- **S0 的 binary 身分**（`s0-final/s0.json` 的 identity，sha16）：

| binary | sha16 | 版本 |
|---|---|---|
| p4c | `226f3f66df515c9e` | 1.2.5.15 |
| stock simple_switch | `4c5e5ad31b0a8b4b` | 1.15.3-f0b7d201 |
| stock simple_switch_grpc | `327fa7d172217397` | 1.15.3-f0b7d201 |
| fabric（bmv2-fast）simple_switch_grpc | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201 |
| simple_switch_CLI | `590b4b32e0db8d98` | — |

  （第 2 輪摘要把兩支 grpc 的版本寫成「—」，那是我寫錯了：s0.json 裡有記錄。）
- **p4info sha 不變**：hc_main 是 `5ce0a5595d5a65f1`，hc_alt 是 `b7490e9eb9979888`。mutant 與 fwd 的 p4info 和原版逐位元相同。
- **drop check**：A、B、C 都 rc 0；FWD rc 1。
- **拋棄式交換機上的自檢**：
  - main、alt、fwd 全部通過；
  - mutant 恰好 SC-count、SC-qstamp、SC-ttl 三項失敗；
  - fwd 那一次，0x88B5 有 3 個幀離開了交換機，這個檢查看到了紅。
- **ValueSetEntry**：兩支 build 都回 canonical_code 12（「ValueSet writes are not supported yet」），兩支交換機都還活著。

## 2. 推論的（INFERRED）

1. 「proxy 的 route 只有那 15 條」來自 grep。
2. PF-T 的 static 歸因走 thrift，不是 B 的 P4Runtime。
3. 下列預測都是讀碼推來的：RC1 GREEN（recirculate 的那一趟不進埠），HR1／HR2 GREEN，HU1 PARTIAL(a)。
4. pcap 模式下 qdepth 一律是 0，Q1 只能在 live 證明。
5. HR 假紅的機率，是在「取樣是獨立的 1/256」這個假設下算的。

## 3. 第 2 次審查（judge-cdd7a951-r2）逐條處理

| # | 處理 | 位置 | 守住它的測試與 mutant |
|---|---|---|---|
| NEW-A | 取樣下限改由 sender 自己的送出數決定：期望樣本數 ≥ 19，也就是 ≥ 4864 幀。放在步驟 3（`Cell.min_sent`）。NDTwin 的 emitter 計數不參與。達到下限而 twin 什麼都沒看到就是 RED | `verdict.decide`；`table.IDENTITY_MIN_SENT` | `test_telemetry_none_through_the_real_cells`、`test_the_sample_floor_comes_from_the_sender_not_the_emitter`；R3-A1、R3-A2 |
| NEW-B | 「從沒發生」用值表示：`never` 加上 `watched_s`；CP4 的 `port_after_cut` 可以是 `gone`。盯滿整個窗還是 `never` → RED；沒盯滿 → NOT RUN；鍵不在 → 讀數沒取到。`rerouted_after_s` 與 `watched_s` 都列進 `need` | `table.deadline_met`／`link_cut`／`cp4`／`it1` | `test_a_link_that_never_went_down_is_red_not_not_read`、`test_a_route_gone_after_the_cut_is_red`；R3-B1 到 B4 |
| NEW-C | `ndt down` 成功之後，lab_round 寫 phase `down-done`。recover.sh 在這個 phase 下：用 `ndt status` 確認沒有 fabric 在跑，否則 rc 4；跳過第 3–5 步；直接還原 knob、release。測試的 qdisc stub 在 down 之後報告漂移 | `lab_round.teardown`、`recover.sh` | 兩個新的 LabRound 測試、兩個新的 recover 情境；R3-C1 到 C3；舊碼看到紅（§1） |
| alias 裁示 | RC1 改成真的格：V1 的 G1 檢查，用在 RC1 自己 dport 40091 的流上，依賴 SC-recirc。VB1＝CH3 維持。輸出上：alias 那一列的歸因欄寫「ALIAS of CH3」；某一維所有被計數的格都是 alias 時，rollup 標 `alias_only`；health.json 多一個 `aliases` 欄 | `table.py`、`verdict.rollup`、`report.py` | `test_alias_only_dimensions_are_marked`、`test_aliases_carry_their_sources_verdict`；R3-D1 到 D3 |

**MINOR**

- **做了**：
  - 1：探針那一方給的輸入是空的 → PROBE-BROKEN。
  - 2：HU1 巢狀的讀數缺了 → NOT RUN。
  - 3：決定採「對照 NOT RUN，K1／T3 判 RED『no route』，整輪仍可發佈」。格自己聲稱有 route 而對照說沒有 → PROBE-BROKEN。
  - 4：HR 的刺激量是 20000 幀 × 64 B，800 kbit/s；每一半的期望樣本約 39，假紅機率小於 1e-5。順序是 TP2 → HR → Q1。
  - 5：IT1 的報告期限是 10 s。
  - 6：kill 失敗的行程留在 LAB_STATE；探測器以 pid 加 start time 認；measuring 讀不到時當成忙碌。
  - 8：由 RC1 那一條解決。
- 每一條都有對應的 R3-m* mutant。
- **只寫成註記**：MINOR 7。三件事：
  - `shell=True` 的命令只檢查第一個字；
  - 真實檔案的變動偵測還沒看過紅；
  - 主 checkout 的 claim 被別的 session 正當地寫入時，可能誤判成紅。
- **前幾輪留下的部分完成項**：
  - 11：PDEATHSIG 沒有測試。
  - 12：29 項構造都已證明。
  - 15：公開的碼只寫「the design」，沒有路徑；審查認為這樣是對的。

## 4. 第 2 輪摘要的更正

1. 「每一份 log 第一行都有 commit」在 r2 只對 probe.log 與 gate 的 log 成立。r3 起每一份 log 都有。
2. 兩支 grpc build 的版本是 1.15.3-f0b7d201，不是「—」。
3. MINOR 11 與 15 是「做了，但只完成一部分」，不是同時寫成「做了」又寫成「部分」。MINOR 12 已全部完成。
4. MAJ-5 那一列「afterdown」的證據原本靠 stub 一律回答「相同」，見 NEW-C。r3 的 stub 改成在 down 之後報告漂移，而且舊碼確實看到了紅。

## 5. done-check

| # | done-check | 證據 |
|---|---|---|
| 1 | 每個突變都被它指名的測試抓到；負對照維持綠 | `r3/mutate_p4_health.log`：130 個突變，0 存活；負對照綠 |
| 2 | test_collect 封死 | 綠的 seal 報告全部是 0；H1–H4 都紅 |
| 3 | S0 | `r3/s0-final/probe.log` |
| 4 | repo 自己的檢查 | 見 §1 |
| 5 | 磁碟 | 3864 MB；scratch 已清 |

## 6. 給設計審查的

DESIGN.md 的 §14.6，有五點：
- 取樣下限；
- 「從沒發生」的編碼；
- `down-done`；
- RC1；
- alias 的標示、MINOR 3 的決定、HR 的刺激量與順序。
