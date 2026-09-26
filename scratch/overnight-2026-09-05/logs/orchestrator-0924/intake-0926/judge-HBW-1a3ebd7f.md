# 審查：`feat/p4-heartbeat-w-0926` @ `1a3ebd7f`（段 W，TICKET-P4-heartbeat）

（fable-judge，新開、無記憶；2026-09-26 ~19:5x 交回；唯讀，沒執行任何東西。全文由 orchestrator 轉錄，未改判定。）
輸入：`intake-0926/hbw/diff-580767a8..1a3ebd7f.patch`、`hunt-0911/fix/P4-HBW-SUMMARY.md`、票面、`hbw/worker-brief.txt`、`hbw/worker-addenda.txt`、`P4-HB-SPIKE.md`、`logs/gates-0910/*.p4hbw-1a3ebd7f.log`、orchestrator 重跑 `hbw/rerun-*.a4be233b.log`。

## 0. 總判定：**MERGE AFTER FIXES**

§3 紀律沒發現違反；產品碼（proxy 四檔＋`ndt`）邏輯與票面一致、證據充分。擋住的是 live 腳本的判定出口，以及 orchestrator 自己的證據缺口。

| # | 等級 | 事項 | 修法 |
|---|---|---|---|
| F1 | **BLOCKING（對 live H1 的回報）** | `08_heartbeat.sh` 在有 cycle 超過嚴格 20 s 時仍以 `PASS` 收尾：`:1733-1737` 用 `note` 不用 `fail`；`v_budget`（`:427-447`）在設計正常時**恆為 OK**（§4.6 代數證明）。票面 §2 H1「≤20 s」、§2 末「不如預期照實回報」。 | `:1734` 的 `note` 改 `fail`（一行）；`OVER+x` 與預算拆解照留 `30_cycles.tsv`。Adam 之後若裁「20 s＋量到的」可接受，再把 FAIL 升回 PASS——反過來不行。 |
| F2 | **BLOCKING（對「merge 已驗證」這句話）** | orchestrator 在 test merge `a4be233b` 重跑的 `p4_proxy_suite` rc=1（`rerun-p4_proxy_suite.a4be233b.log:3901-3903` `FAILED (failures=4, errors=80, skipped=11)`），原因全是 worktree 沒有 `p4_src/build/ndtwin_switch.json`（`:209-263`），不是分支；但 merge commit 上的 proxy 全套還沒有綠的紀錄。 | 照 `red_first_w.sh:13` 把 `p4_src/build` 連到主 checkout 再跑；綠了才算驗過。 |
| F3 | NOTE→建議推公開前修 | `tests/shell/mutate_roles_binding.sh:274` 拿 working tree 對 `6291db35` 掃 class，merge 後 trunk 永遠 rc 1（§7）。 | 可帶說明 merge，但**同一批推送前**補 pin 到 `177b9f03` 的 commit。 |

**live H1–H5 可否 merge 後立刻開跑**：F1 改完且 F2 綠即可。不改 F1 也能跑，但 orchestrator 必須自己把 `strict_20s` 欄與「N of M cycle(s) OVER」那行當 FAIL 報給 Adam，不能拿最後一行的 `PASS`。H5 不受 F1 影響。

## 1. 報告各主張的判定

| 報告主張 | 判定 | 證據 |
|---|---|---|
| proxy 讀報告、用 beacon 同一條規則與常數 | SUPPORTED | `link_heartbeat.py:164-235`；`topology_manager.py:2843-2865`（`period_s=LLDP_BEACON_INTERVAL_S`）、`:2867-2896`、`:2121-2127`；常數 `:373,419,422,432`（5/15/5/30） |
| 只在 NDTwin 擁有路由表時繞路 | SUPPORTED | patch `_routes_blocked_word` 2308-2321、`_fabric_reroute` 2330-2367；`topology_manager.py:2153-2165`；`main.py:2202`；BFS 排除 down link `:842` |
| punt 上來的心跳幀不算 link 證據 | SUPPORTED | `topology_manager.py:1592-1625`；mutant T19（`mutate_p4_heartbeat_w.sh:498-507`） |
| 報告不可用時凍結、從未可用則不判 | SUPPORTED（設計取捨，§3） | `link_heartbeat.py:260-283`；`topology_manager.py:2884-2896`；T08/T08b/P18b |
| 沒有 HTTP route 能 POST link state | SUPPORTED | patch 4335-4368 |
| external 上 `/stats/flowentry/*` 回 409 | SUPPORTED | patch 1878-1893、1902-1924；A03–A07 |
| `ndt` 起停順序、rollback、status | SUPPORTED | `ndt:3463`、`:3528`、`:5252-5255`、patch 6273-6277、`ndt:6878` |
| helper 一 byte 沒改（`6a558fe4…`） | SUPPORTED | `baseline_and_helper.p4hbw-1a3ebd7f.log:9-11` |
| 本段自己的 10 支閘門 | SUPPORTED（逐一抽查） | `mutate_p4_heartbeat_w…log:12,149,198,200-203`；`red_first…log:9-32`；`live08_redfirst…log:9-34`；`test_ndt_heartbeat…log:80`；`live08_selftest…log:114`；`check_gate_anchors…log:134`；`p4_proxy_suite…log:2419-2429` |
| `p4_exercise_suite` 紅＝FixtureProvenance、base 也紅 | SUPPORTED | `p4_exercise_suite…log:13,23,35-39`；`_at_base_full` 同紅；patch 無 `tools/p4_exercise` |
| `ndt_suites` 2 紅是暫時性 | **UNDER-EVIDENCED** | `ndt_suites…log:27-42` 沒記到是哪兩條；只有 4 次綠重跑＋前兩輪綠。原因未知 |
| rule 閘門 plain 版 rc 2，base 亦然 | SUPPORTED | `mutate_rule_journal_is_wired_at_base…log:6,14,16`；driver 宣告 expected 0（`final_gates_w.sh:88,90`） |
| roles_binding 的 1 survivor＝class 掃描、18 class＝本段新增 | SUPPORTED | `mutate_roles_binding…log:15-35,619-624`；`roles_binding_survivor_check…log:9-15` |
| 最壞相位嚴格 ≤20 s 不保證；(15−φ)+ψ+d+ε | SUPPORTED（讀碼推導） | `topology_manager.py:2086`、`:2892` |
| 08 隨機相位沒有 phase lock | φ SUPPORTED；**ψ UNDER-EVIDENCED** | `08_heartbeat.sh:794-815`；ψ 一次 run 內近乎固定（§4.5） |
| `v_budget` 等價於「超時後第一個 pass 就報了」 | SUPPORTED——正因如此它**不是** ≤20 s 的驗收 | `:427-447` 對 `:405-407` |
| 07 的 L6 會紅 | SUPPORTED（推論，未跑） | `07_roles_basic.sh:68-69` |
| external 不啟動心跳的理由 | SUPPORTED | `main.py:2194-2196` |
| commit 用 `-- <files>`、`add -N` | UNTESTED（judge 無 history） | — |
| §11 別的 session lab 在跑時某些 suite 紅 | UNTESTED | 非正式 log |

## 2. 票面符合度

§3 紀律可驗者皆過（每份 log `:5` 印 guard；helper 未改；AI 標記在讀到的每個 hunk）。**沒有退件級違反。**

1. **external 不起心跳（H5 17 臂）**——可辯護，交 Adam，不擋。但 `switch_state.heartbeat.census` 寫 `heartbeat_ran: 20`（patch 2398-2412），而 `ndt up` 只在 17 臂起——census 文字應註明那 3 臂是段 S 手動跑的。NOTE。
2. **`reroute.reason` 放頂層**——可辯護（五 key GUI 契約；M16 守住不長第六個 key）。每台交換機一份 `reroute_reason`：Adam 裁。
3. **偵測上界**：§4.6，Adam 裁。
4. **07 L6 紅**——NOTE，merge 後第一時間修（`07_roles_basic.sh:68-69` 兩個常數：owned → `true,"heartbeat"`；unbound → `false,"heartbeat"`）。附帶：07 的 L4 若 inject 真下 netem，心跳會在 owned 包上改路，L4 記錄的流量數字會變（L4 不斷言改路）。推論未跑。
5. **NDTwin 自家 pipeline `switch_state` 多兩個頂層 key**——NOTE，不擋；寫入與 `/stats/flow` 鏈 byte-identical（`baseline_and_helper…log:12-15`）；`01_baseline.sh:69-102` 只讀 key。

## 3. Proxy 邏輯（已讀）

- 規則同 beacon：`_enter_evidence` 只往前寫 `entry["at"]`（`:2827`）；`check_link_beacons(now)` 用 `now − at > 15`（`:2011`）；never-heard 30 s grace（`:1987-1989`、`:2823-2824`）；時鐘同源 CLOCK_MONOTONIC（`ndtwin-lab:1147-1150`）。無第二套 timeout。
- 只在擁有時改路：`:2153-2165`；detect-only 仍 `push_destination_paths()`（第一刀行為，§6 有揭露）。
- punt 幀仍刷新 `_last_packet_in[device_id]`——交換機存活證據，語意正確。
- stale／missing 報告：誤標 down 不會（未可用 → 判在上一次可用 pass 的時間；session 中斷後 epoch 移到 `written_mono`，`link_heartbeat.py:271-273`）。**漏標 down（cut 發生在 daemon 死掉之後）會，且是設計**——link 留 up 直到 daemon 回來再算 15 s；代價有揭露（`reroute.available=false, reason=heartbeat_stale`、`link_discovery` 退回 `declared`）。對，但**要讓 Adam 知道這個盲區**。
- 沒有測試守著的：helper 報告 key 名與 proxy 讀取端的契約（`ndtwin-lab:1129,1138-1158` vs `link_heartbeat.py:182-220`，今天逐一對過是對的）。
- daemon 死／報告停寫：10 s 後 `heartbeat_stale` → 凍結；`ndt status` 印 `STALE`（`ndt:6255`）。
- 命名 NOTE：`control_plane.skipped` 仍列 `link_watchdog`，但 `start_link_watchdog(seed_expected=False)`（`:2864`）同一條 thread 在跑——「說沒跑其實在跑」。

## 4. `08_heartbeat.sh`（已讀全檔）

**4.1 五個 live trap 全過**：(i) `:93` `unset NDT_MEASURING`＋每個 ndt 呼叫 `env -u`（`:579,582,604,606,637,643`）；(ii) release 只在 down ∈{0,3}（`:574-581`），否則 `keep_claim`（`:597-612`），自測 `:1508-1515`；(iii) `CLAIM_MINUTES:=120` 在 source 之前（`:91` vs `:101`），無 `NDT_OWNER` rc 2（`:82-87`）；(iv) `w_finish` `local rc=$?`（`:617`）、`( exit "$rc" ); finish`（`:630-631`）；(v) `phase_down` 非 0/3 → fail＋`return 1`，呼叫端 `|| exit 1`（`:1761,1789,1806`）。另：`w_finish` 先拆 netem、先讀 `INJECTED_IFACES` 再 revert（`:620-626`）；開跑前拒絕 free lab 上有人的心跳（`:1587-1595`）、helper 逐 byte 比（`:1596-1598`）、tc 路徑先 show（`:1601-1603`）。

**4.2 最壞相位落在 φ→0**：是（就 φ 而言）。`:761-775`、`:794-800`、`:849-856`、`:858,865`；φ 事後重算（`:980`、`:399`）；worst cycle φ>1 s 直接 BAD（`:400-402`）；窗口內的幀 flag 不丟（`:409-415`、`:466-472`）。風險 NOTE：`PHI_WORST=0.02` 在 addendum 20–50 ms 下緣，靠 tc 自身 10–30 ms 補足；daemon 送晚 >20 ms 的那輪會 BAD 並讓 run FAIL——誠實但脆弱。

**4.3** `mono_offset` 前後各讀、差 >2 ms 標出（`:418-420`）。**4.4** φ uniform (0.02, 4.98)、seed 印出（`:814`、`:1702-1703`）。

**4.5 ψ——H1 一次 run 只量到一個 ψ（NOTE，重要）**：daemon 嚴格 5 s、watchdog `wait(5)`＋d，ψ 在 run 內每 pass 只漂 d；6 個 cycle 約掃 1 s 帶寬。**H1 一次 PASS 只證明「在那個 ψ 下 ≤20 s」，不證明最壞情況。** 要取樣 ψ 得在 cycle 之間重啟 daemon 或多次 `ndt up`。建議寫進 H1 回報，不要求本輪改腳本。

**4.6 `v_budget` 是循環的，設計正常時恆為 OK**：`v_cycle` 已要求超時後開始的 pass 必須報（`:405-407`），所以 ψ ≤ 5 + extra；detection = (15−φ)+ψ+overhead；budget = 20+extra+overhead+window（`:438`），window ≥ −φ ⇒ detection ≤ budget 恆成立。唯一能 BAD 的是 `prev` 缺席（自測 `:1298-1299`）。它驗的是**實作有沒有照設計做**（`:405-407` 已驗），不是**設計有沒有達到 ≤20 s**。它不會把實作失敗變 OK，但**會**把設計未達 20 s 的 cycle 變 OK，`judge` 記成 note（`:558-565`），最後一行 `PASS`（`:1733-1737`）。「20 s＋量到的 pass／read／HTTP／kernel」**來自 orchestrator 的 addendum**（`worker-addenda.txt:11`），worker 照字面實作；字面剛好等於設計的最壞上界，所以它是重述不是驗收。裁決 2 原文「最多約 20 s」、常數同自家 fabric——「約」能否吸收 +d+ε 是 Adam 的裁決；票面 §2 H1「≤20 s」是硬的。**在 Adam 裁之前，H1 以 `strict_20s` 判（F1）。** worker 的推導正確；事件驅動 pass 最壞 ≈15.5 s 合理，代價是 proxy 要 watch 檔案、LLDP 與心跳不再共用 pass 節奏——設計裁決。

**4.7 其他 NOTE**：H2 凍結路徑對（`ndtwin-lab:1389` → `heartbeat_not_running` → 凍結 → 30 s `is_up` 不動，`:1745-1757`）。H4 依賴 `HB_RC_NOT_RUNNING=3`（`ndtwin-lab:652`），與 start 的 `HB_RC_NO_LINKS=3` 同值不同動詞，`ndt:6210` 與 `08:1797` 各自用對。前一次 08 keep_claim 且 fabric 留著又沒心跳時，下一次 08 的 `require_free_lab` 不擋（同 owner），是 `ndt` 既有行為。

## 5. `tools/test_workflow/ndt`（已讀）

rollback 由新到舊（stack → heartbeat → fabric，N14／N37 守）；`cmd_down` `[1/3] stack → heartbeat stop → [2/3] topo-stop → [3/3] sweep`（`ndt:5225-5258`）。失敗的 `heartbeat start` 不讓 bring-up 失敗（patch 6199-6215）、先記 `up_started heartbeat`（6205）；stop 以 pidfile 為閘（6220）；helper stop 自驗 pid/argv/uid（`ndtwin-lab:1597-1613`）。報告 0644、目錄 0755 ⇒ status／watcher 不需 sudo。sudo 面：只有 `sudo -n "$LAB" heartbeat start|stop`，`mutate_ndt_sudo_surface` 0 survived——**沒有變寬**。reuse 分支再叫 start，helper 對 already running 回 0（`:1553-1555`）。

## 6. 測試與閘門

- red-first SUPPORTED（proxy 三個新模組在 base 是 ImportError 級的紅——最弱的紅，由 mutation 97/97 補；08 在 `0b9af42f` 19 紅含 `T_CUT: unbound variable`）。
- mutation gate 有鑑別力：anchor 唯一（`:128-141`）、要求**具名**測試紅（`:116`）、C1 對照（`:1253-1261`）、12 個具名 control（`:56-67`）、08 要求具名自測紅且 `SELF-TEST FAIL`（`:1034`）；169＝29+24+28+7+39+42。
- 兩個刻意改動的第一刀斷言：合理（patch 4379-4394；4341-4368；red-first `6e246f2d`）。
- 四個 ndt suite 的 STUBS：理由充分。NOTE：其他 ndt suite（含紅過的 `test_apps_residue.sh`）沒有這行，會讀真的 `/run/ndtwin-lab/heartbeat.json`；重跑都綠所以應不是原因，但那 2 紅是哪兩條沒人知道。

## 7. `mutate_roles_binding.sh`

`:269-280` 讀 working tree 對 `TICKET_BASE=6291db35` 掃 ⇒ merge 後永遠 rc 1。本段自己的閘門已改成讀 pin（`mutate_p4_heartbeat_w.sh:181-235`），是正確樣板。**可帶說明 merge，但同一批推公開前補 pin 到 `177b9f03`**（F3）。

## 8. 建議加跑的測試

1. 兩個寫者的契約測試：helper `document()`（`ndtwin-lab:1126-1158`）產出直接餵 `link_heartbeat.read_report`。
2. H1 出口的自測：合成 `OVER+x` cycle，斷言 run 的**最後一行**（現在只驗 `cut_cycle` 印 OVER，`:1443-1447`）。
3. ψ 取樣：worst-phase cycle 之間 `heartbeat stop/start`。
4. 07 更新後的 `--self-test` 與 live 重跑。
5. merge commit 上帶 `p4_src/build` 的 proxy 全套（F2）。
6. merge commit 上 `ndt_suites` 再跑並抓名字。
7. `control_plane.skipped` 含 `link_watchdog` 而 `heartbeat.watchdog: running`：一條斷言把決定寫死。

## 9. 報告內部小不一致

§12 `p4_proxy_suite` 最後一行是雜訊 log（真摘要在 `:2419-2421`）；§9「四次 up/down」實為 3 up、4 down；`heartbeat_ran: 20` vs H5 17 臂沒說明；orchestrator rerun 的紅是環境（缺 `p4_src/build`），要補綠。

## 10. 誰裁什麼

**Adam**：①偵測上界——接受「(15−φ)+ψ+d+ε，最壞略超 20 s、與自家 LLDP 同級」（裁決 2 的「約」）還是要求嚴格 ≤20 s（事件驅動 pass，最壞 ≈15.5 s；代價：檔案 watch、LLDP 與心跳不再共用 pass 節奏）；**在此之前 H1 以 `strict_20s` 判**。②external 要不要 detect-only（H5 17 vs 20 臂）。③`reroute.reason` 頂層是否足夠，或每台交換機 `reroute_reason`（改 GUI 契約）。④「daemon 死 ⇒ 凍結（cut 期間留 up、但揭露 stale）」盲區是否接受。⑤`control_plane.skipped` 仍列 `link_watchdog` 的命名。

**Orchestrator**：①F1＋F2 做完即可 merge 並開跑 H1–H5。②F3 時機（merge 前或同批推送前）。③07 常數更新時機（H1–H5 之前不必）。④H1 回報寫明 φ、ψ（`watchdog_phase_s`）、`strict_20s`、OVER 數，並註明「一次 run 只取樣一個 ψ」。⑤`ndt_suites` 在 merge commit 補跑並記下紅的名字。

---

# R2 複審（`ebdf365e`，1a3ebd7f..ebdf365e 9 commits）：**MERGE**

（同一位 fable-judge，2026-09-26 ~23:1x；唯讀。要點由 orchestrator 轉錄，未改判定。）無 blocker；一項 07 遺留要在**下次跑 07 之前**補，不擋 merge、不擋 H1–H5。

**F1 已解**：每 cycle 由 `verdict strict`（`08_heartbeat.sh:1008`；`v_strict` 只看 `detect_s ≤ 20`）判，BAD → `fail` → `VERDICT_RC=1`；`v_budget` 只剩 `note`（`:1009`）。`strict_conclude H1`（`:1027-1040`，呼叫 `:1835`）：over>0 → `VERDICT_RC=1`、`VERDICT_WHY="H1: N of M … until Adam rules …(first failure before it: …)"`；STOP 仍前置（`:558-565`）。**找不到任何 OVER 仍印 PASS 的路徑**：兩處判定都設 RC=1；row 不全的 cycle 在 `judge "$row" "phase record"` 已 fail；H3 worst cycle 走同一 `cut_cycle`；`w_finish` 把 `$?` 交 `finish`，以 `VERDICT_RC` 印 FAIL 並 exit 1；`v_strict` 與 `strict_20s` 欄同源。`st_h1` 真的走 cut_cycle → strict_conclude → w_finish → finish 讀最後一行，四情境；red-first `93e6d6e5` 上 OVER 的 run 以 `PASS 08_heartbeat` 收尾（`r2_redfirst.p4hbw-ebdf365e.log:11`）＝原缺陷，HEAD 109 ok（`:17`）；L43–L48 具名 killer；`mutate_p4_heartbeat_w.p4hbw-ebdf365e.log:213-218` 103/103、183/0、rc 0。NOTE：OVER 計數排最前，更早的真失敗在括號裡——讀最後一行要讀完括號。

**F3 已解，仍守得住第一刀 finding 9**：`CLASSES_AT=177b9f03`、祖先檢查、自帶 control（patch 786-846），mutant／killer／anchor 未動；`6291db35..177b9f03` 新增 class 仍全數要求；`roles_scan_probe…log:9-16` 七情境；`mutate_roles_binding.p4hbw-ebdf365e.log:15,599-604` 162/0、196/196、rc 0。

**契約測試穩、會大聲失敗**：標記找不到 → `ValueError` 在模組層 → import 失敗 → `_FailedTest`；heredoc 是 quoted（`ndtwin-lab:656`）；daemon 有 `__main__` 守門（`:1446`），`exec` 進 ModuleType 不跑 main、無 signal／umask／socket 副作用；K04 rename → KeyError → 紅。殘餘：helper 若出現第二個同名 heredoc 標記，`index` 取第一個（今天只有一個）。**Census**：只改字串，M28，red-first `207730f0`。**07 L6**：red-first `45e03902` 兩條紅；L7-5 killer 字面仍真、語意改了——NOTE。

**NOTE（07 遺留，worker 沒抓到；INFERRED 由碼決定）**：`07:600` live 仍 `declared_links_marked "$SS" 8`，要求 8 筆全部 `source: "declared"`（`07:170-180`）；心跳一跑，proxy 第一個 pass 就把 8 方向寫進 `_link_beacons`，`link_liveness` 以 `source: "heartbeat"` 輸出（`topology_manager.py:2277-2300`）⇒ 07 的「L1 declared links on switch_state」live 仍紅；自測 fixture 寫 `declared`（`07:343`）看不到。修法一行。07 不在閘門也不在 H1–H5 ⇒ 不擋，但「07 修好」對 live 是 **UNDER-EVIDENCED**。

**Live H1–H5 可以開跑**（條件：7b600ab0 上的重跑綠）。預期最壞相位 cycle 很可能 OVER ⇒ H1 依設計 FAIL，照實報；一次 run 只取樣一個 ψ。H5 不受影響。

**Adam 要裁：不變**（偵測上界／事件驅動 pass；external detect-only；每台 `reroute_reason`；daemon 死的凍結盲區；`skipped` 列 `link_watchdog` 的命名；ψ 取樣）。**Orchestrator**：07 `declared_links_marked` 下次跑 07 前補（可同批或緊接）；merge commit 上帶 `p4_src/build` 的全套（在做）；`ndt_suites2` 沿用 a4be233b 的 `suites red: 0`（R2 沒動 `ndt`）。
