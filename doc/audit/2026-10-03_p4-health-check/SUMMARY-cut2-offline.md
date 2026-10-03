# P4 健檢 Cut 2（離線那一半）：交付摘要

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-health-cut2`，從 `0cd01656`（Cut 1 加上後續）開。
- **head**：`50c3379d`。
- **commit**：
  - `118329f3` 程式（A 的觀測器、B 的控制器與歸因、lab 接線、S0 新增兩步）；
  - `20a56fcb` 控制器在 LAB_STATE 的 marker 改用 run 目錄；
  - `e71dab93` 測試與 43 個新 mutant；
  - `50c3379d` 兩個 sniffer 的窗放寬。
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/`。每份 log 第 1 行是 `commit 50c3379d… tree f000f94e…`，最後一行是 `rc=`。e71dab93 那一輪完整的 gate 在 `LOG/e71dab93/`。
- **沒做**：
  - lab：`ndt up/claim/down/release/clean`；
  - sudo、Mininet、真的 mnexec、tc；
  - C++ build、push。
- **起過的 bmv2**：全是拋棄式的，pcap 模式、Thrift 29500 起、gRPC 29650 起。
  - S0 原有的：`ndt-hc-selfcheck-bmv2`、`ndt-hc-vstrial-bmv2`；
  - 本輪新增：`ndt-hc-ctrltrial-bmv2`。
- **沒動的檔**：
  - `recover.sh`：Cut 2 不需要改它；
  - `lab_round.py`：一行都沒改，claim 與 LAB_STATE 那一段留給另一條分支；
  - `DESIGN.md`；
  - `expected_today.tsv`：見 §4。

## 1. 做了什麼

### 1.1 bring-up A（`observe_a.py`、`round_a.py`、`collect/hosts.py`、`hostside.py`）

- **格**：
  - PL1、T1（CP1 是它的 alias）；
  - T2、T3、T4、T5、T6、T7、T8；
  - M1、M2、C1、C2；
  - K1、K2、MT1、MT2、MT3、R2、R3；
  - D1、P1、P2、P3、CS1、TTL1、TP1。
- **對照**：K1-neg、T3-neg。
- **自檢**：
  - SC-fwd：30 對主機的 marker pingall，加上 T1 的 dump；
  - SC-count、SC-reg、SC-ttl。
- **順序**：先 static 再 active。
- **`--only`**：會帶上該格的對照、gate 格，以及產生它所需自檢讀數的格。
- **刺激**：`hostside.py` 在主機的 namespace 裡送、收 marker（`sudo -n mnexec -a <pid>`，p4dev 直譯器）。
  - 幀由 `frames.py` 組，和 S0 送進拋棄式 bmv2 的幀逐位元組相同。
  - sniffer 經 `Runner.spawn` 起，以 pid＋start time＋marker token 記進 LAB_STATE.json。
  - 收齊、或時間到，sniffer 就自己結束。
- **證據**：每一格的觀測寫成 `<run>/A/<cell>.json`。

### 1.2 bring-up B（`controller_ext.py`、`attribution.py`、`round_b.py`、`ctrl_trial.py`）

- **控制器**：tutorials `p4runtime_lib` 的形狀，經 `run_external_controller.py` 改寫連線。
  - 仲裁成 primary、推 pipeline、寫四台的路由，然後在 s2 上做 11 項歸因。
- **確認一項歸因要兩件事都成立**：
  - 控制器的呼叫成功；
  - 一個不經控制器的讀數：
    - thrift：table_dump、meter_get_rates、mirroring_get＋mc_dump、register_read、counter_read；
    - h4 的 sniffer：packet-out；
    - DigestList 與 packet-in：內容必須等於探測器自己送的欄位與 ingress port。
- **對應到 A 的格**：
  - T4＝ternary，T5＝range，T6＝optional，T7＝priority；
  - MT1、MT2＝MeterEntry，MT3＝DirectMeterEntry；
  - D1＝digest，C2＝clone，R3＝register，K2＝direct counter；
  - P2＝packet-in，P3＝packet-out。
- **S0 新增一步**：`ctrl_trial` 把同一支控制器、同一個 `attribution.confirm`，拿到拋棄式 simple_switch_grpc（stock 與 bmv2-fast 兩支）上跑一次。

### 1.3 接線（`lab.py`、`probe.py lab`、`s0.py`、`cells/verdict.py`）

- **順序**：`probe.py lab` 先在 run 目錄跑 S0（不是 COMPLETE 就不碰 lab，rc 1）→ A → B → 判格。
  - 判格排在最後，因為 A 的 RED 要靠 B 的 `bmv2` 歸因。
- **package**：每一輪用它自己在 run 目錄裡的 package（`<run>/packages/A`、`B`、`A-MUT`）。
- **S0 新增**：A-MUT（mutant artefact，給看過紅那一次用）的 convert、pre-flight、drop check。
- **判定新增一步**：這一輪沒觀測的格判 NOT RUN，理由是「not observed in this run」。

## 2. 觀測到的（OBSERVED，都在 50c3379d）

| 檢查 | 結果 | log |
|---|---|---|
| cells（3.8.20、3.12.3、3.13.13） | 110 tests OK | `test_cells.py*.log:14,16` |
| collect（封死，三版） | 97 tests OK；seal 報告：97 個測試都檢查過，tripwire／網路／spawn／真實檔案變動都是 0 | `test_collect.hermetic.py*.log:5,7`、`seal_report.green.py*.json` |
| recover（三版） | 72 checks，0 failed | `test_recover.py*.log:94` |
| H1–H6（H5、H6 是新的：sender 走真的 Runner、sniffer 直接 Popen） | 全部紅 | `test_collect.nonhermetic.H*.log` 末行 |
| mutation gate | 201 個突變（舊 158＋新 43），0 存活；只改註解的負對照綠；原檔 byte-identical | `mutate_p4_health.log:1222,1225,1228` |
| S0 | rc 0、54 個 ok、COMPLETE、109 s | `s0.run.log:4-5`、`s0-final/probe.log:51,52,56` |
| check_gate_anchors HEAD | p4_health ok(197)；133/133 | `check_gate_anchors.HEAD.log:109,142` |
| check_test_tmpdirs | 414 個檔，0 個 | `check_test_tmpdirs.log:3` |
| test_l1_shell_scoring | 163 checks，0 failed | `test_l1_shell_scoring.log:187` |
| 舊碼看到紅 | 只把 `verdict.py` 換回 `0cd01656`，新測試紅；`0cd01656` 整棵樹是 ImportError | `items/verdict_unobserved.OLD0cd01656_red.log:3-4`、`items/{cells,collect}.OLD0cd01656_red.log:9` |

**拋棄式 simple_switch_grpc 上的事實**（stock 與 bmv2-fast 兩支，`s0-final/s0.json`）：

- **11 項裡 10 項確認**：ternary、range、optional、priority、MeterEntry、DirectMeterEntry、digest（DigestList 帶著 marker 的 src／sport／dport）、clone（mgid 0x8009 → {1}）、direct counter（控制器的讀數＝thrift）、packet-in／packet-out。
- **RegisterEntry 寫入兩支都回** `canonical_code 12: Register writes are not supported yet`（`s0.json:375,539`）。
- **thrift dump 的 priority**＝INT32_MAX 減去 P4Runtime 的 priority（10 → 2147483637），在 thrift 裡小的贏。
- **optional** 在 dump 裡顯示成 `TERNARY 11 &&& ff`。

## 3. 推論的（INFERRED）

1. **TP1 的正規化**是照碼與一份舊的 live P4 圖寫的，沒有對真的 fabric 跑過。
   - 碼：`GraphTypes.hpp:733-776`、`HttpSession.cpp:1390-1500`、`Utils.hpp:1113`。
   - 舊圖：`doc/audit/2026-09-02_manual-usertest/run-06-opus/logs/e6-graph-p4.json`，主機那一側的介面是 1，兩個方向都有。
   - 形狀不同的話，TP1 會判 RED，SC-fwd、SC-ttl 與後面的格判 NOT RUN，整輪仍可發佈。
2. **主機介面名**：假定叫 `eth0`。根據是 topology.json 的 commands 寫 `dev eth0`。
3. **時間**：§6 的時間都是推估。
4. **A 的 P2**：marker 打到 s2 的 CPU port，會進 proxy 的 stream，只留雜訊。沒跑過。

## 4. 預測沒改，有一項要決定者看

- **R3**：表上預測 RED。
  - 照 DESIGN §2.3 R3 那一列（「bmv2 PI 不支援的話判 UNATTRIBUTED」），加上 §2 的觀測，第一次 live 會得到 **UNATTRIBUTED**，delta 顯示 flipped。
- **為什麼沒改**：依據是拋棄式交換機上的觀測，不是讀碼，照規定不改。
  - 改不改都不影響 rollup：registers 那一維只剩 R2（RED）被計數，仍是「做不到」。
- **其餘 Cut 2 格**：假 fabric 的端對端測試 `test_bring_up_a_reads_as_predicted` 逐格比對 tsv，除了 R3 全部一致。

## 5. 設計沒寫、我選的

1. **送收工具**：用 frames.py＋AF_PACKET，不用 scapy，這樣和 S0 的幀逐位元組相同。
2. **控制器的直譯器**：用 p4dev venv。p4_proxy venv 沒有 `p4.tmp`，而 p4runtime_lib 需要它。
3. **控制器的指令**：寫在 `$P4H_CTRL_CONFIG` 指的 JSON 檔裡，因為 adapter 不傳參數。
   - 控制器在 LAB_STATE 的 marker 是 run 目錄。
4. **`sent`**：
   - 寫入格（T3–T7、M2、MT1）＝發出且有回覆的寫入數；
   - T1＝pingall 的幀數。
5. **T2 的 NDTwin 那一半**＝s2 的 table_entries 計數：recorded＝applied＞0，failed＝0。
6. **T8**＝s2 的 `table_entries.journaled`。
7. **有端點、但探測器還沒有 client 的**（C2、MT2、MT3、R2、R3、P3；D1／P2 的出口 `/p4/digest`、`/p4/packet_in`）判 NOT RUN，不判紅也不判綠。
8. **priority 的換算**：照 §2 的 INT32_MAX 減法。
9. **meter 的目標值**：0.125 B/µs、burst 12500，兩個 band 都一樣。
10. **刺激**：
    - 路徑 h4 → h6，經 s2 → s4；counter、register、meter 都讀 s2；
    - R2 寫 0x1281；
    - K1、K2 各 200 幀；
    - pingall 每對 3 幀，共 30 對。
11. **B 的歸因**在 s2 上做，值與 A 的不同；packet-out 送 5 幀到 s2 的 port 1。
12. **沒觀測的格**判 NOT RUN。
13. **`--only` 的展開規則**：見 §1.1。
14. **S0 新增**：A-MUT 與 ctrl_trial。
15. **TP1 的四個集合**：
    - switches＝dpid；
    - hosts＝(ip, mac)；
    - edges 不分方向，主機那一側的介面不看；
    - ports＝交換機那一側的埠。
16. **CS1**：有一台主機讀不到就是 NOT RUN。
17. **tsv**：沒改。

## 6. 第一次 live 的程序（沒跑）

**前提**

- Adam 對這一次逐次授權（§9 Q6(a)：第一次 live，含看過紅那一次）。
- 建議併進 trunk 之後在主 checkout 跑（§7.2）。
- `~/tutorials/utils/p4runtime_lib` 在；p4dev venv 在。這兩者 S0 的 ctrl_trial 都證明了。
- 磁碟 > 2500 MB。

**命令**

```
cd <checkout>
NDT_OWNER=<owner> tools/test_workflow/ndt status --measuring      # 必須是 measuring nothing、沒有別人的 claim
RUN=$PWD/.test_run/p4_health/$(date -u +%Y-%m-%dT%H%M%SZ)_p4_health
P4_HEALTH_RUN_DIR=$RUN tools/p4_health/run.sh lab --owner <owner>                          # 全輪：S0 → A → B
RUN2=$PWD/.test_run/p4_health/$(date -u +%Y-%m-%dT%H%M%SZ)_p4_health_seered
P4_HEALTH_RUN_DIR=$RUN2 tools/p4_health/run.sh lab --owner <owner> --bringups A --only K1,TTL1 --mutant   # 看過紅
# 當掉、被中斷：tools/p4_health/recover.sh $RUN   （人執行）
```

**時間（推論）**

- S0 約 2 分鐘（離線量到 109 s）；
- A 約 6–9 分鐘；
- B 約 4–6 分鐘；
- 全輪約 12–17 分鐘；看過紅那一次另外約 6–8 分鐘。

**全輪預測會看到的**

- GREEN：PL1、T1（CP1）、T2、T3、M1、M2、C1、K1、P1、CS1、TTL1、TP1；
- 對照：K1-neg、T3-neg 都是 GREEN；
- 自檢：SC-fwd、SC-count、SC-reg、SC-ttl 都是 ok；
- RED（歸因成立）：
  - T4、T5、T6：501，加上 B；
  - T8：journaled 恆為 false；
  - C2：沒有 route，加上 B 的 clone；
  - K2：404，加上 B 的 direct counter；
  - MT1：501，加上 B；MT2、MT3：沒有 route，加上 B；
  - R2：沒有 route，加上 thrift；
  - D1、P2：沒有出口，加上 B；P3：沒有 route，加上 B；
  - PF-T：S0；
- T7：NOT RUN（gate T4 RED）；
- R3：UNATTRIBUTED（delta flipped，見 §4）；
- 其餘格：NOT RUN「not observed in this run」，包括 AP1、AS1、IT1、VS1；
- rollup：
  - core：can 9、partial 1、cannot 3、undecided 3；
  - full：6、4、3、3；
  - q3b：0、0、0、6；
- 整輪：verdict COMPLETE，rc 0。

**看過紅那一次預測會看到的**

- K1 是 PROBE-BROKEN，原因 SC-count；TTL1 是 PROBE-BROKEN，原因 SC-ttl；
- PL1、T1、TP1、K1-neg 都是 GREEN；
- verdict PROBE-BROKEN、rc 1——這正是 §5.2-④ 要的。

**先看什麼（照順序）**

1. `probe.log`：有沒有「S0 COMPLETE」，以及兩行 B controller trial 都是 ok。
2. 收拾乾淨了沒有：
   - `$RUN/LAB_STATE.json` 的 phase 是 `released`；
   - `health.json` 的 bringups 每一筆：complete、down_rc 0、release_rc 0、knobs_restored、frames_reached_hosts false；
   - `ndt status`：沒有 claim、沒有 bmv2。
3. `$RUN/A/problems.json` 是空的。
4. **TP1**：`A/TP1.json` 的 answer 與 oracle 逐集合比。這是最沒驗過的一段；紅的話先比集合，再相信它。
5. `A/SC-fwd.json` 的 pingall 是 (30, 30)。
6. B 那一輪：
   - `B/attributions.json`：除了 register，其餘都是 ok；
   - `B/controller.log` 有 adapter 改寫的那幾行；
   - `controller.result.json` 的四台都是 primary、set_pipeline_ok。
7. `00_table.tsv`：delta 應該只有 R3 是 flipped。
