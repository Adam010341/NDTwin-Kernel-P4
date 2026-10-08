# P4 健檢 Cut 2（離線那一半）：交付摘要（含第 1 次審查的修正）

[Co-developed with claude code -- Adam]

- **分支**：`feat/p4-health-cut2`，從 `0cd01656` 開；中途合併了 `fix/p4-health-run-identity`（`f721be78`）。
- **head**：`fa7fcb83`。
  - 第 1 輪：`118329f3`、`20a56fcb`、`e71dab93`、`50c3379d`。
  - 審查之後：`1340729f`（合併）、`eb95555a`、`3c2e7e0b`、`cdd6153b`、`f0596efe`、`5a1b287d`、`58293b47`、`da9176d9`、`7a9b2880`、`91ec19c0`、`fa7fcb83`。
- **LOG** 指 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-cut2/`。
  - 第 1 輪的證據在 `LOG/e71dab93/` 與 LOG 根目錄；審查修正之後在 `LOG/r2/`。
  - 每份 log 第 1 行是 `commit <sha> tree <tree>`，最後一行是 `rc=`。
- **沒做**：
  - lab：`ndt up/claim/down/release/clean`；
  - sudo、Mininet、真的 mnexec、tc；
  - C++ build、push。
- **起過的 bmv2**：只有拋棄式的，pcap 模式、Thrift 29500 起、gRPC 29650 起。
  - S0 原有的：`ndt-hc-selfcheck-bmv2`、`ndt-hc-vstrial-bmv2`；
  - Cut 2 新增：`ndt-hc-ctrltrial-bmv2`。
- **iproute2 的格式**：用 `unshare -rn`（非特權的 user＋net namespace，不碰主機網路）實測過一次。
- **沒動的檔**：
  - `recover.sh`；
  - `DESIGN.md`；
  - `lab_round.py`：只加了 MAJOR-3 那一段小的 LAB_STATE 覆寫拒絕，緊鄰 run-identity 的檢查。

## 1. 做了什麼

### 1.1 bring-up A（`observe_a.py`、`round_a.py`、`collect/hosts.py`、`hostside.py`）

- **格**：
  - PL1、T1（CP1 是它的 alias）；
  - T2–T8、M1、M2、C1、C2；
  - K1、K2、MT1–MT3、R2、R3；
  - D1、P1、P2、P3、CS1、TTL1、TP1；
  - VS1（Q3(b)，沒有 route）。
- **對照**：K1-neg、T3-neg。
- **自檢**：
  - SC-fwd：30 對主機的 marker pingall，加上 T1 的 dump；
  - SC-count、SC-reg、SC-ttl。
- **順序**：先 static 再 active。
  - 每一步各自包住：某一步拋出例外，只影響它自己那一格（讀數記成讀不到）。
  - 停止訊號（SIGTERM、SIGINT、SIGHUP）的處理（第 3、4 輪修正後）：
    - 在輪內：結束這一輪，收拾照跑；觀測的 `except Exception` 不會吞掉它（`SignalAbort` 是 `BaseException`）。
    - 在收拾期間：收拾不中斷，第一個訊號被記下，收拾做完後寫進該輪的 problems（「aborted by signal N (during the teardown)」）。
    - 兩輪之間：由 run 層的 handler 接。
    - 任何一種都讓整個 run 結束：B 不起，整輪 INCOMPLETE、rc 2（見第 4 輪 F1、F3）。
- **`--only`**：會帶上該格的對照、gate 格，以及產生它所需自檢讀數的格。
- **刺激**：`hostside.py` 在主機的 namespace 裡送、收 marker（`sudo -n mnexec -a <pid>`）。
  - 以 root 跑的 p4dev 直譯器加上 `-B -X pycache_prefix=<run> -I`。
  - 幀由 `frames.py` 組，和 S0 送進拋棄式 bmv2 的幀逐位元組相同。
- **sniffer 只算**：這一輪的 token、這一格的 id、**IPv4 UDP、dport 是這一格的、ip_dst 是收端自己**的幀。
  - 收端回送的 ICMP port unreachable 會引用整個 marker，有了這個條件就不會被算進去。
- **TP1 的 fabric oracle**：兩種 veth 寫法都讀。
  - 同一個 namespace 的對端寫名字：`s1-eth4@s2-eth2`，也就是每一條交換機之間的鏈路；
  - 另一個 namespace 的對端寫 index：`s1-eth1@if2`，也就是每一個接主機的埠。
  - show_ports 列出的每一個埠都必須落在某一條鏈路上，否則 oracle 讀不到（NOT RUN）。

### 1.2 bring-up B（`controller_ext.py`、`attribution.py`、`round_b.py`、`ctrl_trial.py`）

- **控制器**：tutorials `p4runtime_lib` 的形狀，經 `run_external_controller.py` 改寫連線。
  - 仲裁成 primary、推 pipeline、寫四台的路由，然後在 s2 上做 11 項歸因。
  - **起控制器之前**，先讀 `switch_state`，必須是 `control_plane.mode == "external"`。
- **確認一項歸因要兩件事都成立**：
  1. 控制器的呼叫成功；
  2. 另一個讀數：
     - thrift：table_dump、meter_get_rates、mirroring_get＋mc_dump、register_read、counter_read；
     - h4 的 sniffer：packet-out。
- **DigestList 與 packet-in 例外**：讀數是**控制器自己回報收到的內容**，拿來和探測器自己選、自己送的欄位與 ingress port 比對。
  - 這是設計允許的做法；它不是一個繞過控制器的讀數。
- **對應到 A 的格**：
  - T4＝ternary，T5＝range，T6＝optional，T7＝priority；
  - MT1、MT2＝MeterEntry，MT3＝DirectMeterEntry；
  - D1＝digest，C2＝clone，R3＝register，K2＝direct counter；
  - P2＝packet-in，P3＝packet-out。

### 1.3 接線（`lab.py`、`probe.py lab`、`s0.py`、`identity.py`）

- **前置**：`probe.py lab` 在 `tools/p4_health` 有任何未提交的改動時拒絕（rc 2）。
  - 第 4 輪起，乾淨檢查之後、S0 之前，立刻把各輪會執行的檔案複製進 `<run>/frozen/`，並逐一比對 HEAD 的 blob（`git hash-object <副本>` 對 `git rev-parse HEAD:<路徑>`）；對不上就 rc 2，什麼 lab 動作都還沒做。
  - root 的 `hostside.py`、B 的 controller 與 adapter 都執行副本，不執行共用的 working tree；各檔的 sha256 記在 health.json 的 `frozen_code`（root 那三個另外在 `root_code`）。
- **S0**：在 run 目錄跑 S0，不是 COMPLETE 就停：第 5 輪起是 **rc 2**（INCOMPLETE），health.json 的 `problems` 寫哪幾個檢查沒過，不碰 lab、不做 identity。（第 4 輪以前是 rc 1、沒有 health.json；rc 1 在 see-red 那一輪是「過」，見 §8。）
- **記錄這一輪跑的是什麼**：
  - `system_under_test`：用 `code_identity.py` 記錄；
  - `gate_fingerprint`：Q6(a)「必須相同」那一側，每一部分一個 digest；
  - 兩者都寫進 health.json。
- **A**：A 一輪結束後把 `LAB_STATE.A.json` 留一份。
- **B 有條件**：A 必須乾淨結束——phase `released`、down 與 release 都是 rc 0、沒有停不掉的行程、LAB_STATE 裡不再有行程或 netem——否則 B 不起，整輪 INCOMPLETE。
  - LabRound 本身也拒絕覆寫一份還沒結束的 LAB_STATE.json。
- **最後才判格**。
- **每一輪的 package**：用它自己在 run 目錄裡的那一份（`<run>/packages/A`、`B`、`A-MUT`）。
- **S0 新增的檢查**：
  - A-MUT 的 convert、pre-flight、drop check；
  - B 控制器在拋棄式 simple_switch_grpc 上的 trial；
  - adapter 對 package B 的 `--dry-run`：必須指名 controller_ext.py，並把 s1–s4 改寫到 30051–30054、device id＝dpid。
- **判定新增一步**：這一輪沒觀測的格判 NOT RUN，理由是「not observed in this run」。
  - 它的 delta 寫「not observed」，不寫「flipped」；以這種格為來源的 alias 也一樣。

## 2. 觀測到的（OBSERVED；除表中註明的 commit 外，都在 fa7fcb83）

| 檢查 | 結果 | log（`LOG/r2/`） |
|---|---|---|
| cells（3.8.20、3.12.3、3.13.13） | 116 tests OK | `test_cells.py*.log:37,39` |
| collect（封死，三版） | 118 tests OK；seal 報告：118 個測試都檢查過，tripwire／網路／spawn／真實檔案變動都是 0 | `test_collect.hermetic.py*.log:5,7` |
| recover（三版） | 108 checks，0 failed | `test_recover.py*.log:133` |
| H1–H6 | 全部紅 | `test_collect.nonhermetic.H*.log` 末行 |
| mutation gate | 252 個突變，0 存活；負對照綠；原檔 byte-identical | `mutate_p4_health.log:1528,1531,1534` |
| S0 | rc 0、55 個 ok、COMPLETE、112 s；adapter dry run 通過 | `s0.run.log:4-5`、`s0-final/probe.log:53,57` |
| check_gate_anchors HEAD | ok(242)；133/133 | `check_gate_anchors.HEAD.log:109,142` |
| check_test_tmpdirs／test_l1_shell_scoring | 414 個檔 0 個／163 checks 0 failed | 各自的 log |
| veth 的兩種寫法（在 1340729f） | 同一個 namespace 寫 `@名字`，跨 namespace 寫 `@if<index>`（iproute2-6.1.0） | `veth_format.log:5,10` |
| gate fingerprint（離線、唯讀；在 91ec19c0，`identity.py` 在那之後沒有再改） | 約 5 s；各部分都讀得到 | `fingerprint_offline.log` |
| ok(N) 與突變數為什麼不同（在 91ec19c0） | `ok(n)` 數的是不同的 anchor 加上對照：197＝196＋1（50c3379d），242＝241＋1（fa7fcb83） | `anchors_197_vs_201.log` |

- **審查三個 MAJOR 與 m1–m7**：除了下面兩類，每一項都有在舊碼上看到紅的 log（`r2/*.OLD_red.log`）與綠的 log（`*.NEW_green.log`），也都有 mutant。
  - m6 只改措辭，沒有紅 log，也沒有 mutant。
  - m5 的紅是介面錯誤（`r2/m5.OLD_red.log:2-3`）。m3 的紅 log 與 MAJOR-2 共用（`r2/major2_m3.OLD_red.log:58-61`，有兩行 FAIL），單看那份 log 不能證明它是介面錯誤；m3 的行為由它的 mutant 承擔。（第 4 輪 SUMMARY 寫成「m3 的紅是介面錯誤」，第 5 輪更正。）
- **拋棄式 simple_switch_grpc 上的事實**（stock 與 bmv2-fast 兩支）：
  - 11 項歸因有 10 項確認；
  - RegisterEntry 寫入回 `canonical_code 12: Register writes are not supported yet`；
  - thrift 的 priority 是 INT32_MAX 減去 P4Runtime 的 priority；
  - optional 在 dump 裡顯示成 `TERNARY 11 &&& ff`。

## 3. 推論的（INFERRED）

1. **Mininet fabric 上 veth 的寫法**：交換機之間寫名字、接主機的埠寫 `@if`。這是從 `p4_testbed_topo.py` 的 Switch 子類別加上 §2 的實測推的，沒有在 fabric 上跑過。live 第一件事就是看 TP1（§6）。
2. **收端回 ICMP**：會回、而且引用整個 marker，這是 Linux 的行為。sniffer 的條件讓它不會被誤算；沒有在 fabric 上量過。
3. **TP1 對 `get_graph_data` 的正規化**：照碼與一份舊的 live 圖寫的。
4. **時間**：§6 的時間都是推估。
5. **主機介面名**：假定叫 `eth0`。

## 4. 預測（`expected_today.tsv`）

- **R3 改成 UNATTRIBUTED**：決定者的裁示，第一次 live 之前就改。依據是 controller trial 的觀測。
- **AP1、AS1、IT1 的 cut 改成 3**：B 的 11 項歸因沒有涵蓋它們，Cut 2 歸因不了。`cells/table.py` 同步改。
- **VS1 這一輪有觀測**：預測 UNATTRIBUTED（沒有 route；bmv2 的 P4Runtime 拒絕 value-set 寫入）。
- **比對**：假 fabric 的端對端測試逐格拿 tsv 比，Cut 2 的格（含 VS1）全部一致，**沒有任何一格 flipped**。

## 5. 設計沒寫、我選的

1. **送收工具**：用 frames.py＋AF_PACKET，不用 scapy；以 root 跑的直譯器加 `-B -X pycache_prefix -I`。
2. **sniffer 的條件**：只算 UDP、dport 是這一格的、ip_dst 是收端自己。
3. **控制器的直譯器**：用 p4dev venv（p4runtime_lib 需要 `p4.tmp`）。
   - 指令經 `$P4H_CTRL_CONFIG` 傳；
   - 在 LAB_STATE 的 marker 是 run 目錄。
4. **`sent`**：
   - 寫入格＝發出且有回覆的寫入數；
   - T1＝pingall 的幀數。
5. **T2 的 NDTwin 那一半**＝s2 的 table_entries 計數；**T8**＝s2 的 `journaled`。
6. **有端點、但探測器還沒有 client 的**，判 NOT RUN。
7. **priority 的換算**：INT32_MAX 減法。
8. **meter 的目標值**：0.125 B/µs、burst 12500。
9. **刺激**：
   - 路徑 h4 → h6，經 s2 → s4；
   - K1、K2 各 200 幀；
   - pingall 每對 3 幀，共 30 對。
10. **B 的歸因**在 s2 上做；packet-out 送 5 幀到 s2 的 port 1（dport 40051）。
11. **沒觀測的格**判 NOT RUN，delta 寫「not observed」；以這種格為來源的 alias 也一樣。
12. **TP1**：
    - 每一個埠都必須落在某一條鏈路上，否則 oracle 讀不到；
    - 主機那一側的介面不看。
13. **B 只在 A 乾淨結束之後才起**；每一輪的最後一份 LAB_STATE 留成 `LAB_STATE.<X>.json`。
14. **gate fingerprint**：一個部分讀不到，整份就是 `incomplete`，不算相符。

## 6. 第一次 live 的程序（沒跑）

**前提**

- Adam 對這一次逐次授權（§9 Q6(a)：第一次 live，含看過紅那一次）。
- **在 ndtwin-lab 作用的那一棵 tree 跑，也就是主 checkout `/home/adam/Desktop/NDTwin-Kernel`**（Adam 對 r4 審查 #1 的裁示 (A)）。第 4 輪寫的「專用的乾淨 worktree」做不到，已拿掉：
  - **為什麼不是別的 checkout**：
    - claim 是每個 checkout 各一份：`CLAIM="$REPO/.test_run/lab.claim"`（`ndt:341`），`.test_run/` 是 per checkout（`ndt:6513`）。在 worktree 裡 claim，主 checkout 上的人看到的是 `claim none`。
    - root 的 helper 只指一棵 tree（`ndt:1526-1561`，「It names ONE tree, so two worktrees cannot both be live at the same time」）：`ndt up p4` 的 preflight 在別的 checkout 會拒絕，而 teardown 的 `ndt down` 從任何 checkout 跑都會 `topo-stop` lab 那棵 tree 的 fabric（`ndt:5356`），不看本地 claim。
    - `run.sh` 要有 `<checkout>/p4_proxy/venv/bin/python`（或 `P4_PROXY_PY`），kernel binary、venv、編好的 pipeline 也只在那一棵 tree 裡。
  - **前提與為什麼夠**：`git status --porcelain -- tools/p4_health` 必須是空的（`probe.py` 的乾淨檢查，`probe.py:155`；不是空的就 rc 2，什麼 lab 動作都還沒做）。主 checkout 其他地方別的 session 的未提交改動**不影響這一輪**，因為：
    - 乾淨檢查之後、S0 之前，root 與 B 會執行的 7 個檔先複製進 `<run>/frozen/`，逐一對同一個 pin 住的 HEAD blob 驗過（`git hash-object --no-filters`），root、B 的 controller 與 adapter，以及 S0 的 controller trial 與 adapter dry-run 都執行副本（第 4 輪 F4、第 5 輪 NIT 7–9、#5）；
    - 探測器行程自己用到的 `p4_health` 模組，在乾淨檢查**之前**就全部載入（第 5 輪 #5，`probe.LAB_PATH_MODULES`），之後不再從共用 tree 讀 probe 程式。
  - **run 期間沒有人可以改主 checkout 的 `tools/p4_health`**（也請不要動 `tools/p4_exercise/` 的 `convert.py`、`preflight.py`、`common.py`、`run_external_controller.py`，和 `tools/test_workflow/heartbeat_drop_check.py`）。如果有人改了：
    - 在乾淨檢查**之前**：rc 2，拒絕；
    - 在乾淨檢查**之後、凍結之前**：凍結時副本對不上 HEAD 的 blob，rc 2，拒絕（`frozen.py`），lab 還沒碰；
    - 在凍結**之後**：**不會被拒絕、也不會被偵測**——這一輪照舊跑，執行的是凍結的副本和已載入的模組，所以結果不受影響；但 `gate_fingerprint` 的 tracked 部分（`repo_tracked`，約第 3 分鐘算）和 `system_under_test` 只記算的那一刻的狀態，之後的改動不在紀錄裡。
    - 已知沒有蓋到的：S0（約前 2–3 分鐘）還是從共用 tree 讀 `tools/p4_health/exercise/`（P4 原始碼，編成被測的 pipeline）、跑 `tools/p4_exercise/convert.py`、`preflight.py` 和 `heartbeat_drop_check.py`、`openapi_probe.py`；這幾個不在凍結的 7 個檔裡（第 5 輪沒動）。
  - **已知的殘餘（第 5 輪不修）**：gate fingerprint 會算進主 checkout 的未追蹤檔（`identity.py:91-97` 的 `repo_untracked`，除了 `.test_run/`、`scratch/`、run 目錄和 may-differ 那幾類），而主 checkout 常有別的 session 的未追蹤檔，所以兩輪之間這一項可能不同。第一輪的紀錄換成常設授權前，要先把「`repo_untracked` 的變動算不算相符」定下來（Adam 另外決定）。
  - 這一輪的 HEAD 是凍結時 pin 住的那一個（health.json 的 `frozen_head`，也是 `repo_identity` 的 head）；主 checkout 上別的 session 之後再 commit，不改變這一輪執行的是什麼。

**命令**

```
cd /home/adam/Desktop/NDTwin-Kernel                          # ndtwin-lab 作用的那一棵 tree
git status --porcelain -- tools/p4_health           # 必須是空的（不是空的，probe.py lab 會 rc 2 拒絕）
NDT_OWNER=<owner> tools/test_workflow/ndt status                # 必須是 claim none、measuring nothing、bmv2 switches 0（claim 列 ndt:6849-6850，bmv2 switches 列 ndt:6992）
                                                                # 不要用 --measuring：它只印 declared、measuring（或 orphaned，ndt:6803-6807；recover.sh:309-316 靠這一列）幾種列（ndt:6818-6824），看不到 claim 與 bmv2
df -m /                                             # > 2500 MB
RUN=$PWD/.test_run/p4_health/$(date -u +%Y-%m-%dT%H%M%SZ)_p4_health
P4_HEALTH_RUN_DIR=$RUN tools/p4_health/run.sh lab --owner <owner>        # S0 → identity → A → B → 判格
# 當掉、被中斷：tools/p4_health/recover.sh $RUN   （人執行）
```

**看過紅那一次**：只在全輪 PL1、T1、TP1 都是 GREEN，而且 A、B 兩輪都乾淨結束之後才跑。

```
RUN2=$PWD/.test_run/p4_health/$(date -u +%Y-%m-%dT%H%M%SZ)_p4_health_seered
P4_HEALTH_RUN_DIR=$RUN2 tools/p4_health/run.sh lab --owner <owner> --bringups A --only K1,TTL1 --mutant
```

**存檔**：把 `$RUN` 與 `$RUN2` 整個目錄抄進 audit-raw。

**時間（推論）**

- S0 約 2 分鐘；identity 不到 1 分鐘；
- A 約 6–9 分鐘；B 約 4–6 分鐘；
- 全輪約 13–18 分鐘；看過紅那一次另外約 6–8 分鐘。

**全輪預測會看到的**

- GREEN：PL1、T1（CP1）、T2、T3、M1、M2、C1、K1、P1、CS1、TTL1、TP1；
- 對照：K1-neg、T3-neg 都是 GREEN；
- 自檢：SC-fwd（pingall 30/30）、SC-count、SC-reg、SC-ttl 都是 ok；
- RED（歸因成立）：T4、T5、T6、T8、C2、K2、MT1、MT2、MT3、R2、D1、P2、P3、PF-T；
- T7：NOT RUN（gate T4 RED）；
- UNATTRIBUTED：R3、VS1；
- 其餘格：NOT RUN「not observed in this run」，delta 寫「not observed」；
- delta：57 格裡 same 30、not observed 27、**flipped 0**（假 fabric 的端對端測試實測，第 5 輪補存了 log：`LOG/r5/delta_counts.log`，rollup 也在裡面；兩列對照 K1-neg、T3-neg 另外各是 same）；
- rollup：
  - core：can 9、partial 1、cannot 3、undecided 3；
  - full：6、4、3、3；
  - q3b：0、0、0、6；
- 整輪：COMPLETE，rc 0，**而且** health.json 的 `problems` 是空的、B 的 controller 有做完。
  - 只看 COMPLETE rc 0 不夠：第 4 輪之前，B 的 sniffer 沒起來、或結果檔讀不了，整輪仍會是 COMPLETE（第 4 輪 F2 修了「沒有結果」的六個出口）；第 5 輪 #4 又補上「有結果、但什麼都沒確認」（只有 register 確認、或 s2 不是 primary）。這些都由程式標成 failed B、整輪 INCOMPLETE；仍要照步驟 6 看 `controller.result.json`。

**看過紅那一次預測會看到的**

- K1 是 PROBE-BROKEN，原因 SC-count；TTL1 是 PROBE-BROKEN，原因 SC-ttl；
- PL1、T1、TP1 都是 GREEN；
- PROBE-BROKEN，rc 1——這正是 §5.2-④ 要的，**但只在 A 完整、乾淨結束，而且 health.json 的 `problems` 是空的時候**才算數。**看 health.json 的 `verdict`（PROBE-BROKEN）和 K1、TTL1 的理由（SC-count、SC-ttl），不要只看 rc**：第 5 輪起 `probe.py lab` 的 rc 1 只代表 PROBE-BROKEN；S0 沒過、run 目錄留著沒結束的 LAB_STATE.json、準備階段出錯、任何例外，都是 rc 2。mutant 沒被發現（沒有任何格 PROBE-BROKEN）是 `SEE-RED-NOT-SEEN`、rc 2，不再是 COMPLETE rc 0。
  - 第 4 輪起程式自己強制這一點：see-red 這一輪沒完成、有 problem、或被停止訊號打斷，標題是 INCOMPLETE、rc 2，不是 PROBE-BROKEN（F3）。
  - 這一輪的步驟 2 也要照做（見下）。

**先看什麼（照順序）**

1. `probe.log`：
   - 有「S0 COMPLETE」；health.json 有 `frozen_code`；
   - 兩行 B controller trial 與 adapter dry run 都是 ok；
   - 有「gate fingerprint <sha>」那一行，而且不是 `incomplete`。
2. 收拾乾淨了沒有（全輪與看過紅那一次都要做；看過紅那一次只有 A，沒有 `LAB_STATE.B.json`）：
   - `LAB_STATE.A.json`、`LAB_STATE.B.json` 的 phase 都是 `released`，sniffers／controllers／netem 都是空的；
   - health.json 的 bringups 每一筆：complete、down_rc 0、release_rc 0、knobs_restored、frames_reached_hosts false；
   - `ndt status`：沒有 claim、沒有 bmv2。
3. **rc 2（INCOMPLETE）時**：先讀 health.json 的 `problems` 與 `bringups` 每一筆，以及每一份 `LAB_STATE.<X>.json`。
   - 如果寫著「B not brought up」：先對 `$RUN` 跑 `recover.sh`，不要直接再跑一輪。
4. **TP1**：`A/TP1.json` 的 answer 與 oracle 逐集合比。
   - oracle 是 null，代表有一個交換機的埠落不到任何鏈路上，或某一個讀取失敗。
   - 這時不要去跑 `ip -o link show`：`ndt down` 之後 fabric 已經不在了。看 `A/TP1.json` 的 `diagnostics`：它留著原始的 `ip -o link show` 文字、每一台的 show_ports、每個主機的 link 與位址、對不上的埠、列出的 CPU 埠，以及哪一個讀取失敗。
5. `A/SC-fwd.json` 的 pingall 是 (30, 30)；`A/problems.json` 是空的。
6. B 那一輪：
   - `B/attributions.json`：除了 register，其餘都是 ok；
   - `B/controller.log` 有 adapter 改寫的那幾行；
   - `controller.result.json` 的四台都是 primary、set_pipeline_ok。
7. `00_table.tsv`：不應該有任何一格是 flipped。有的話，那一格就是這一輪要先解釋的。
8. health.json 的 `gate_fingerprint` 與 `system_under_test`：這是第一次授權那一輪的紀錄，以後的常設授權要拿它來比，保存好。

## 7. 第 4 輪（r3 審查的修正）

- **基底**：`b1efe699`；中途合併了 `fix/p4-health-run-identity` 兩次：`79e13808`（在 `196c8340`）、`65491ceb`（在 `eac246cb`）。那個分支只動 `test_p4_health_cells.py`，兩次都合併乾淨。
- **code 的 head**：`2e630d34`（`tools/p4_health` 的 tree＝`e42f47f9`）。之後只有這份文件的 commit，tools 與 tests 沒有再動。
- **LOG4** 指 `LOG/r4/`；每份 log 第 1 行是 `commit <sha> tree <tree>`，最後一行是 `rc=`——**除了** `mutate_p4_health.stopped_by_me_*.log` 兩份（被我中途停掉的，不是結果；`stopped_by_me_at_18_to_shard.log` 停在 M18 的標題，沒有 `rc=`）。
  - 紅：F1–F3 跑在 `5391a7f4`，F4、F6、F8、F9 跑在 `66043c74`；兩者都是**先 commit 測試、再跑**，沒有未提交的測試文字。
  - 綠：F1–F3 跑在 `0fa6902a`，F4、F6、F8、F9 跑在 `6a7954e2`；整份套件的綠與 gate 在 `2e630d34`。
- **新 mutant 的前綴**：`C2R4-`（30 個，另有 `C2R3-N8a/b` 與 `C2-RB2` 跟著搬了位置的程式改了 anchor）。

### 7.1 每一項

| 項 | 改了什麼 | 紅（LOG4） | 綠（LOG4） | mutant |
|---|---|---|---|---|
| F1（MAJOR）收拾期間的停止訊號 | `lab_round.py`：收拾 handler 記下第一個訊號，收拾做完後 `run()` 把「aborted by signal N (during the teardown)」寫進該輪的 problems、`complete` 設 false；docstring 改成和程式一致 | `f1.RED.log`：3 個失敗，含審查預測的「2 次 claim、2 次 up」與「COMPLETE rc 0」 | `f1.GREEN.log` | `C2R4-F1a`–`F1d`（不記下訊號、留最後一個而非第一個、`run()` 不寫、`complete` 不清） |
| F2 每一個沒有 controller 結果的 B 出口都是 failed | `round_b.py`：`finish()` 在結果是 None 時一律設 `failed`；sniffer 沒起來（沒有 stimulate、沒有 `go`）有自己的理由 | `f2.RED.log`：2 個失敗（sniffer 沒起來、結果檔讀不了）；其餘四個出口原本就對，補的是測試 | `f2.GREEN.log`（6 個出口各一個 run_lab 測試） | `C2R4-F2a`–`F2f`（六個出口各一個，各自的理由被拿掉） |
| F3 停止訊號蓋過標題；see-red 要完整乾淨 | `cells/verdict.py` 的 `run_verdict(…, stopped, see_red)`；`lab.py` 依任何一輪的紀錄或 run 自己的停止（旗標，不是比字串）傳入 | `f3.RED.log`：5 個行為上的失敗；`f3.cells.RED.log` 是介面錯誤（`TypeError`，引數還不存在） | `f3.GREEN.log`、`f3.cells.GREEN.log` | `C2R4-F3a`–`F3f` |
| F4 早凍結、對 HEAD 驗、B 也用副本 | 新的 `frozen.py`；`probe.py lab` 在乾淨檢查之後、S0 之前凍結；7 個檔（root 3 個、B 的 controller、adapter 與它 import 的 `common.py`、`__init__.py`）都比對 `git hash-object` 對 `git rev-parse HEAD:<路徑>`，對不上、git 答不出、兩個答案都是空的，都 rc 2；B 的 argv 用副本；health.json 多 `frozen_code` | `f4.RED.log`、`f4.collect.RED.log`：行為上的失敗（改動在檢查與凍結之間，S0 照樣起；B 的 argv 指向共用的 tree）：cells 3 個測試共 11 個失敗的 subtest（`f4.RED.log:3`、`:215`），collect 2 個測試；另有 3 個測試因為 `frozen` 模組還不存在而是 import 錯誤（`f4.RED.log:5-31` 兩個、`f4.collect.RED.log:5-11` 一個） | `f4.GREEN.log`、`f4.collect.GREEN.log` | `C2R4-F4a`–`F4j`；`C2R3-N8a/b` 搬到新程式 |
| F6 用真實路徑登記 controller | `round_b.py`：`os.path.realpath(self.cfg.run_dir)`；凍結的目錄也用解析後的路徑 | `f6.RED.log`（LAB_STATE.B.json 的 controllers 是空的） | `f6.GREEN.log` | `C2R4-F6`（`C2-RB2` 的 anchor 跟著改） |
| F8 讀不了 override 的分支 | 測試：`fabric_binary` 被 mock；真的 `ID.fingerprint` 在「其他部分都讀得到」的機器上，對照組是可讀的 override（有指紋、lab 起）、OSError 組是 `incomplete`＋rc 2＋lab 不起；原本的「缺少 identity 記錄」測試不再讀真的 `bmv2_binary_override`，並斷言是 identity 檢查擋下的 | `f8.RED.log` 是 import 錯誤（測試要 patch 還不存在的 `frozen`）；這個分支的程式本來就對，**行為上的紅由 mutant 承擔** | `f8.GREEN.log` | `C2R4-F8a/b` |
| F9 C2R3-N8b 收緊 | 測試比對的是**副本**的位元組；另一個測試讓副本和來源不同，紀錄必須是副本的 | `f9.RED.log` 是 import 錯誤；**行為上的紅由 mutant 承擔** | `f9.GREEN.log` | `C2R4-F9`（hash 來源而非副本）被 `test_the_recorded_hash_is_of_the_copy_not_of_the_source` 殺死（`mutate_p4_health.partial_F4-F9.log`） |

- **紅 log 的限制**：F3 的 cells 測試、F4 的兩個、F8、F9 的紅是介面錯誤，不是行為紅；它們的行為由對應的 mutant 承擔。F1、F2、F3（collect）、F4（cells 的 3 個測試〔11 個 subtest〕、collect 的 2 個測試）、F6 的紅是行為上的。（第 4 輪的 SUMMARY 寫成「兩個 import 錯誤、cells 5 個」，第 5 輪照 log 更正。）
- **模擬 stub 照真實工具**：
  - F1 的假 `ndt down` 對自己（探測器）送 SIGTERM，等於 `kill -TERM <pid>` 在 `subprocess.run` 等 ndt 的時候到達；Python 的 handler 跑完，等待繼續（PEP 475）。這次用的是各輪**真實**的 handler（`install_signals=True`）。
  - F2 的 spawn 失敗照 `Runner.spawn`：Popen 丟 OSError 就回 None（`collect/runner.py:66-71`；第 4 輪寫的 62-65 是環境變數那幾行）。
  - F4 的 git 是真的 git（暫存的 repo）。

### 7.2 沒有改、或只回報的

- **審查項目 11（SIGTERM 落在 `ndt claim` 期間）：只查、沒修。**
  - **claim 檔長什麼樣（實測，OBSERVED；`LOG/r4/item11/claim_kill_300.log`）**：暫存複本的 `tools/test_workflow`、真的 `ndt claim`，300 次隨機 0–90 ms 後 SIGKILL（`subprocess.run` 在例外時做的就是 `process.kill()`）：
    - 241 次：ndt 還沒寫任何東西（沒有 claim 檔，沒有 baseline）；
    - 35 次：claim 檔完整（5 行），`round.baseline` 也有；
    - 24 次：claim 檔完整，**沒有 `round.baseline`**；
    - **空的或只寫一半的 claim 檔：0 次。**之前另跑過一次 300 次（187／39／18，另有 56 次殺的時候已經結束），同樣是 0 次，沒有存檔。寫入是 `claim_write … > "$CLAIM"`（`ndt:824-826`）一次小的 printf，空檔的窗口只有截斷到寫入之間的幾個微秒，沒碰到；我沒有證明它不可能。
    - 每次殺完緊接著再 `ndt claim` 都成功（300/300），鎖不會卡住。
  - **recover.sh 對 phase `claiming`（實測；`recover_claiming.log`、`release_states.log`）**：四種狀態（完整＋baseline、完整無 baseline、沒有 claim 檔、**空檔——人工造的，沒有真的觀測到**）都是 rc 2，印「has claim_expires '', not a time -- the probe did not record its claim. Nothing done.」，不呼叫任何 stub。
    - claim 檔完整、note 指名這一輪的 state 檔時，多印「The claim … is this run's」「Nothing was brought up under it」和 `NDT_OWNER=<owner> <ndt> release`；沒有 claim 或空檔時只有那一行 STOP，沒有 release 指令。
    - 真的 `ndt release`：完整無 baseline 的 claim 可以放掉（rc 0，留 `.prev`）；空的 claim 檔也可以（rc 0）；空檔之後再 `ndt claim` 也成功。
  - **探測器這一側（OBSERVED，假 runner、真 handler）**：claim 寫好之後 SIGTERM 到達：`ndt claim` 在 `LabRound.run` 的 try 之外（`lab_round.py` 的 claim 在 try 之前），所以沒有收拾；`run_lab` 的 `except SignalAbort` 記下「stop signal 15 outside a bring-up's body」，INCOMPLETE rc 2，`bringups` 是空的（這一輪沒有紀錄），LAB_STATE 停在 `claiming`、`claim_expires` 是 null。
  - **結論**：這個窗口不會讓 B 起來，也不會留下 recover.sh 看不懂的狀態；人要照 recover.sh 印的指令（或 `ndt release`）放掉 claim。這不是新的缺口，我沒有改程式。
- **F5**：不在這一輪的範圍；`test_p4_health_cells.py` 的「引用的記錄」檢查已經由 `fix/p4-health-run-identity` 的 `9cf3e0b7`、`79e13808` 改成只看文字與單一 trunk ref，合併進來了。
- **F10**、**`show_ports_trial` 沒有單元測試**：沒有動。
- **S0 的 adapter dry-run** 在第 4 輪執行共用 tree 的 adapter；原來寫的「它在凍結之後跑，所以是同一個 HEAD 的內容」推不出來（HEAD 檢查驗的是副本，不是 S0 之後才跑的那份共用檔），而且漏了 S0 的 controller trial（`ctrl_trial.py` 也跑共用 tree 的 `controller_ext.py`）。第 5 輪 #5 已修：兩者都用凍結的副本，見 §8。
- **see-red 那一輪如果沒有任何格 PROBE-BROKEN**（mutant 沒被抓到）在第 4 輪仍然讀 COMPLETE、rc 0；第 5 輪 #3 已修，改讀 `SEE-RED-NOT-SEEN`、rc 2（§8）。

### 7.3 gate

- **在 `2e630d34`（LOG4）**：
  - 三版直譯器（3.13.13、3.12.3、3.8.20）：`test_p4_health_collect` 147 個 OK、`test_p4_health_cells` 130 個 OK（`test_collect.py*.log`、`test_cells.py*.log`）；`test_p4_health_recover.sh` 163 checks、0 failed（`test_recover.log`）。
  - 封死的 collect：147 個測試都檢查過 seal，tripwire、網路、spawn、真實檔案變動都是 0（`seal_report.green.py3.13.13.json`、`test_collect.hermetic.py3.13.13.log`）。
  - `check_gate_anchors.py HEAD`：133/133 cells ok，`mutate_p4_health.sh` 是 ok(306)（`check_gate_anchors.HEAD.log`）；`check_test_tmpdirs.py`：414 個檔，0 個固定暫存路徑。
  - **mutation gate：328 個突變（r3 的 298＋這一輪的 30），0 存活；4 份負對照都是綠；原檔 byte-identical；之後套件對真檔仍綠**（`mutate_p4_health.shard{0,1,2,3}of4.log`，各 82 個，最後一行 `rc=0`）。
- **gate 怎麼跑的（照實寫）**：
  - 單一程序的 gate 在這台機器上約每個突變 1 分鐘（recover 測試最久），328 個要 5 小時以上，超過任務指定的 `timeout 10800`。
  - 我停掉了前兩次（`mutate_p4_health.stopped_by_me_at_59_slow_machine.log`、`…_at_18_to_shard.log`，**不是結果**），給 `tests/shell/mutate_p4_health.sh` 加了 `MUT_SHARD=k/n`（位置對 n 取餘數），同一個 head 上並行跑 4 份，各自有基線與負對照，合起來剛好蓋過整張表一次；timeout 改成 21600。
  - 第一輪 4 份（`mutate_p4_health.run1_56b27f60.shard*of4.log`，在 `56b27f60`）有 2 個存活：`R2-m4a`、`C2R3-N3a`。原因：早凍結放在乾淨檢查之後，這兩個測試用不存在的 run 目錄，突變讓檢查放行後，凍結照樣 rc 2，測試只看 rc 2，分不出是哪個檢查擋的。已修（`2e630d34`：測試把凍結換成一碰就失敗的 stub），然後整張表在 `2e630d34` 重跑一遍，就是上面的結果：這兩個突變在最終的 shard 0 被抓到（`mutate_p4_health.shard0of4.log:433-437`、`:445-449`）。（原來寫的「單獨重跑兩個突變都被抓到」沒有 log，第 5 輪刪掉。）
  - 起 gate 之前，兩次都查了 `fix/p4-health-run-identity` 的 head：第一次是 `79e13808`（不是 `9cf3e0b7`），合併後才跑；第二次是 `65491ceb`，也合併了（`eac246cb`），再跑。最後一次起跑前那個分支的 head 仍是 `65491ceb`。

### 7.4 r2、r3 審查指為矛盾的句子，已改

- §1.1 的「收到訊號仍然結束這一輪」：改成上面那一段完整的訊號說明（第 3、4 輪）。
- §2 的「每一項都有紅 log 與 mutant」：改成除了 m6、m3、m5 之外（N6）。
- §2 的「都在 fa7fcb83」：改成逐列註明 commit（N6）。
- §6 的 delta 數字：27，不是 26（N6）。
- §6 的前置命令：用 `ndt status`，不是 `--measuring`（N6）。
- §6 的步驟 4：看 `A/TP1.json` 的 `diagnostics`，不是 `ip -o link show`（N4、N6）。
- §6 的「在主 checkout 跑」：第 4 輪改成專用的乾淨 worktree（N8、F4(c)）；r4 審查 #1 指出那一步做不到，第 5 輪依 Adam 的裁示 (A) 改回「在 ndtwin-lab 作用的主 checkout 跑」，並寫明前提與殘餘（§6 前提）。
- §6 的「COMPLETE rc 0」：加上 problems 空、B 有做完（N2、F2）。
- §6 的 see-red 判讀和步驟 2：延伸到 see-red 那一輪（N5、F3）。

## 8. 第 5 輪（r4 審查的修正）

- **基底**：`ed6dce9b`（code 的 head `2e630d34`）。**code 與測試的 head：`59d6b014`**（`tools/p4_health` 的 tree＝`fbf5a13c`）；之後只有這份文件的 commit，tools 與 tests 沒有再動。
- **LOG5** 指 `LOG/r5/`。每份 log 第 1 行是 `commit <sha> tree <tree> …`，最後一行是 `rc=`。紅都是**先 commit 測試、再跑**；r5 的 commit 在跑完之後改寫過一次（只改訊息，tree 不變），log 第 1 行是改寫前的 sha，對照在 `LOG/r5/SHA-MAP.txt`（紅 log 的 commit 是只有測試、還沒有修的那一個；第 1 行的 `tracked-dirty=0`）。
- **新 mutant 的前綴**：`C2R5-`，共 69 個（表現在 397 個＝328＋69）。
- **#1（which tree）**：Adam 裁示 (A)，§6 已照改（在主 checkout 跑，前提與殘餘寫在 §6 前提）。「專用的乾淨 worktree」已從 SUMMARY 拿掉。

### 8.1 每一項

| 項 | 改了什麼 | 紅（LOG5） | 綠（LOG5） | mutant |
|---|---|---|---|---|
| #2 rc 1 不再兼代三件事 | `lab.run_lab`：S0 不是 COMPLETE、準備階段出錯（load_model、expectations）、`_rounds` 丟出的 Exception（StateInUse 等）都是 INCOMPLETE rc 2，health.json 的 `problems` 寫原因；`probe.py lab` 的 S0 不是 COMPLETE 也走 run_lab（不做 identity、不碰 lab）；`main()` 接住 `cmd_lab` 的任何 Exception，印 traceback、rc 2（這種情況沒有 health.json）。測試用的假 `Reached` 改成 BaseException（`MustNotRun`），不然「一碰就失敗」的 double 會被這個 handler 吞掉 | `n2.collect.RED.log`、`n2.cells.RED.log`（`296d8eb8`；4 個 ERROR 是例外跑出 run_lab、1 個 FAIL 是 rc 1 ≠ 2）、`n2b.cells.RED.log`（`8437dba4`；S0 丟例外時 `main` 讓它跑出去） | `n2.collect.GREEN.log`、`n2.cells.GREEN.log`（`d4fb721e`） | `C2R5-2a`–`2h` |
| #3 看不到紅的 see-red 不是過 | `cells/verdict.py`：`see_red`、完整乾淨、沒有任何 PROBE-BROKEN → **`SEE-RED-NOT-SEEN`、rc 2**（不是 COMPLETE rc 0；也不是 rc 1，因為 rc 1 是 see-red 的過） | `n3.collect.RED.log`、`n3.cells.RED.log`（`ba539085`；`('COMPLETE', 0) != ('SEE-RED-NOT-SEEN', 2)`） | `n3.collect.GREEN.log`、`n3.cells.GREEN.log` | `C2R5-3a`–`3c` |
| #4 B 跑了但什麼都沒確認 | `round_b.BRound.did_nothing`：除了預期的 `register`，什麼都沒確認，或 s2 不是 primary（只要 s2 的記錄有、沒有 `connect_error`、而 `primary` 不是 true；比審查寫的「且 set_pipeline_ok」更嚴，是它的超集）→ failed B。假 controller 的 `switches` 照 `controller_ext.py:130-157`、`205`、`336-339` 的形狀寫；「沒有交換機回應」時 digest／packet-in 也是空的（控制器收不到） | `n4.RED.log`（`d260a803`；兩個 `('COMPLETE', 0)`）、`n4b.RED.log`（`ab637862`，interface：`did_nothing` 還不存在，行為由 4a／4b 承擔） | `n4.GREEN.log` | `C2R5-4a`–`4d` |
| #5 凍結之後的探測器程式 | 選項：**在乾淨檢查之前把 lab 路徑會載入的每個 `p4_health` 模組都 import**（`probe.LAB_PATH_MODULES`、`load_lab_path`），而不是事後逐檔對 HEAD 重驗。理由：重驗比的是磁碟上的檔，不是行程載入的碼（改了又改回來會過），而且蓋不到驗證之後才載入的模組；先載入則檢查之後行程不再從共用 tree 讀 probe 程式。`S0(frozen=)`：controller trial（`ctrl_trial.trial(controller=)`）與 adapter dry-run 用凍結的副本 | `n5.RED.log`（`64b056e4`）、`n5b.RED.log`（`a613f863`）：dry-run 的 argv 指共用 tree、trial 沒有 `controller`、identity 在 S0 時還沒載入、probe 沒把 frozen 交給 S0 | `n5.GREEN.log` | `C2R5-5a`–`5g` |
| #6 量測工具 | `mutate_p4_health.sh`：在 baseline **之前**拒絕 `MUT_SHARD` 的 k ≥ n、n > 表的大小、格式不對（含前導 0）、以及任何選不到突變的跑法（含吻合不到任何東西的 `ONLY_LABEL_PREFIX`）；每份 shard log 頂端與尾端印 `NOT THE GATE BY ITSELF: shard k/n`；新 `tests/shell/sum_p4_health_gate_shards.sh <log>…`：同一個 commit／tree／subject sha、baseline／控制／after-check 都綠、rc 都 0、k 剛好 0..n-1、各份的數量等於各自的份額，才印 `GATE: N mutations, S survived, shards k/n ok`，否則印 `NOT THE GATE: …`、rc 1。測試 `tests/shell/test_p4_health_gate_scripts.sh`（43 個檢查）；gate 的 mutant 現在也可以改這兩支 script 的副本。（檔名不用 `mutate_*`，因為 `check_gate_anchors.py` 會把那樣的檔當成 gate、找不到 anchor 就 exit 2。） | `n6.RED.log`（`bc8980f3`，43 個檢查 38 個紅）；**今天的 script 拒絕不了的跑法**（`n6.old.*.log`，在 `ed6dce9b`）：`MUT_SHARD=400/500` 跑 0 個突變、`rc=0`；`ONLY_LABEL_PREFIX=NOPE-` 跑 0 個突變、`rc=0`；`MUT_SHARD=5/4` 原來就拒絕，但是在約 1 分鐘的 baseline **之後** | `n6.GREEN.log` | `C2R5-6a`–`6z`（26 個，用 `test_p4_health_gate_scripts.sh` 的檢查名當預期） |
| NIT 7 | `frozen.freeze`：`git rev-parse --verify HEAD` 一次，blob 用 `<sha>:tools/<path>`；`Frozen.head`；health.json 的 `frozen_head`；`repo_identity(head=)` 用同一個 sha | `n789.RED.log`（`1bcdeaf5`；中途 commit 竟然通過凍結） | `n789.GREEN.log` | `C2R5-7a`–`7e` |
| NIT 8 | `git hash-object --no-filters` | 同上（run 目錄在 repo 裡、`*.py text`、CRLF 的副本通過） | 同上 | `C2R5-8` |
| NIT 9 | `<run>/frozen` 已存在就拒絕；`os.mkdir`（不 exist_ok）建目錄、`O_CREAT\|O_EXCL\|O_NOFOLLOW` 開檔（`frozen.copy_file`）；放在目的地的連結被拒絕、目標不動 | `n789.RED.log`、`n9b.RED.log`（`b49c95a4`；子目錄的連結） | `n789.GREEN.log` | `C2R5-9a`–`9c` |
| NIT 10 | `lab_round.py`：body 的 raiser 先換成收拾期間的 handler 再 raise；換 handler 時用 `pthread_sigmask` 擋住三個訊號；紀錄在 `_restore_handlers` **之前**定稿（`_finish`）；`LabRound.rec`，`lab.take_unrecorded` 在 run 被訊號或例外提前結束時補上已開始的輪的紀錄與 state 檔 | `n10_13.RED.log`（`5bebaa96`：第二個訊號跑出 `run()`、teardown 沒跑；`restore` 之後的訊號與例外讓該輪紀錄不見） | `n10_13.GREEN.log` | `C2R5-10a`–`10d` |
| NIT 11 | `probe.py judge` 從紀錄讀 `stopped`（旗標、輪的 problems、run 的 problems）與 `see_red`（`mutant`／`see_red`）；`observations.json` 多寫 `bringups_complete`、`stopped`、`see_red`、`bringups`、`problems` | `n11.cells.RED.log`、`n11.collect.RED.log`（`8def2d90`） | `n11.cells.GREEN.log`、`n11.collect.GREEN.log` | `C2R5-11a`–`11f` |
| NIT 12 | `ctrl_garbage_result` 標明是假設性的（真的 controller 用 tmp＋`os.replace`，`controller_ext.py:399-404`）；`runner.py` 的引用改成 66-71；`adapter_argv` 的 docstring 改成實話（S0 的 dry-run 用同一個 argv 加 `--dry-run`；controller trial 不經過 adapter）；選項：凍結的 adapter＋controller 照 B 的 argv（沒有 `-I`）真的啟動一次，p4runtime 用 stub，檢查載入的檔沒有一個在共用 tree 下，控制組是同樣啟動共用 tree 的檔、偵測器必須看到 | `n12.cells.GREEN.log`（沒有紅：沒有要修的行為；紅由控制組與 mutant 承擔） | 同左 | `C2R5-12` |
| NIT 13 | `rec["complete"]` 也需要 `knobs_restored` | `n10_13.RED.log`（`True is not false`） | `n10_13.GREEN.log` | `C2R5-13` |

### 8.2 沒辦法確定性測的

- **NIT 10**：`_swap_handlers` 擋住三個訊號再換 handler，目的是不讓訊號夾在兩次 `signal.signal` 之間；這個窗口是位元碼之間的幾個指令，我沒有辦法確定性地在那裡送訊號，所以**沒有針對 `pthread_sigmask` 本身的測試或 mutant**。測到的是審查點名的兩個縫：第二個訊號在 `_handlers(False)` 之前（從那個 hook 送）、訊號／例外在 `_restore_handlers` 之後（從那個 hook 送）。一個訊號落在 `return rec` 與 `recs.append` 之間（呼叫邊界）與 `_restore_handlers` 之後走同一條 `take_unrecorded` 的路，但沒有單獨在那個點測。
- **#6**：真的 shard log 尾端那一行 `NOT THE GATE BY ITSELF` 與 `MUTATIONS == SELECTED` 的保險要整個 shard 跑完才碰得到，沒有 mutant；被釘住的是頂端那一行，與 sum script 讀的合成 log（格式取自 r4 的真 shard log）。
- **NIT 9**：`O_NOFOLLOW` 與 `O_EXCL` 沒有各自分開的測試（目的地是連結時 `O_EXCL` 本身就失敗）；mutant `9b` 把兩個一起拿掉。
- **NIT 12**：B 的真實啟動用的是 stub 的 `p4runtime_lib`、沒有交換機；controller 的 `frames` 延遲 import 是用結束時的 `import p4_health.frames` 驗，不是 controller 真的在連線後走到它。
- **#5**：行程啟動到乾淨檢查之間（`probe.py` 頂端 import 的 `expected`、`report`、`cells`、`collect.config`、`runner`）與「改了又改回來」都不在保護內。

### 8.3 沒有改、或新發現的

- **S0 仍從共用 tree 讀**：`tools/p4_health/exercise/`（P4 原始碼，編成被測的 pipeline）、`tools/p4_exercise/convert.py`、`preflight.py`、`tools/test_workflow/heartbeat_drop_check.py`、`openapi_probe.py`。#5 只涵蓋審查點名的 controller trial、adapter dry-run 與 identity 等模組。已寫進 §6 前提。
- **gate fingerprint 的未追蹤檔變動**（`identity.py:91-97`）：依指示沒有修，寫在 §6 前提。
- **`run_lab` 寫的 `observations.json` 不能直接交給 `probe.py judge`**：JSON 來回後 `table.py` 的 `t1` 對 list 做 `set()`（unhashable）。這在第 5 輪以前就如此；NIT 11 的離線測試用手做的紀錄，只釘 `judge` 讀的那幾個欄位。沒有修。
- F10、`show_ports_trial` 沒有單元測試：沒有動。

### 8.4 r4 審查「數字對不起來」的處理

- 「Three doc-only commits follow 2e630d34」：只有兩個（`d8ce630b`、`ed6dce9b`）。
- 「每份 log 最後一行是 `rc=`」：除了兩份 `stopped_by_me_*`（已寫在 LOG4 的說明）。
- `recover_claiming.log:3,18,33` 標的 39／18／187（共 300）來自那次沒存檔的 300 次；存檔的 `claim_kill_300.log` 是 35／24／241。兩份是不同的跑，不互相佐證。
- `partial_F1-F3.log:97-100`、`:117-119`：`C2R4-F3e` 在 `551b2751` 是 WRONG-TEST 的存活，`cbc47503` 把它的預期測試改對；第 4 輪的 SUMMARY 與回報都沒有提。
- `f3.GREEN.log`（`0fa6902a`）早於 `3b283c48` 把 stop 改成旗標：出貨的碼由 `2e630d34` 的整份綠與 mutant `F3b`、`F3c` 涵蓋，不是那份 log。
- cells：`b1efe699` 的 `Ran` 是 120（第 5 輪把那個 commit 的封存檔跑了一遍：cells 120、collect 130），+10 ＝ 130，不是「119＋10＝129」。
- §6 的 delta 數字（30／27／0 flipped）和 rollup：補存了 `LOG/r5/delta_counts.log`（假 fabric 的端對端測試，`COMPLETE` rc 0，57 格：same 30、not observed 27；對照 2 列 same；core 9／1／3／3、full 6／4／3／3、q3b 0／0／0／6）。

### 8.5 gate 與最後的檢查（在 `59d6b014`，LOG5）

- `check_gate_anchors.py HEAD`：133/133 cells ok，`mutate_p4_health.sh` ok(373)（`check_gate_anchors.HEAD.log`）；`check_test_tmpdirs.py`：416 個檔，0 個固定暫存路徑（`check_test_tmpdirs.log`）。
- `p4_proxy/venv/bin/python`：collect 162 個 OK、cells 153 個 OK、`test_p4_health_recover.sh` 163 checks 0 failed、`test_p4_health_gate_scripts.sh` 43 checks 0 failed（`test_collect.log`、`test_cells.log`、`test_recover.log`、`test_gate_scripts.log`）。
- **mutation gate：397 個突變（328＋69），0 存活**，4 份 shard 各自有基線、負對照、byte-identical 與之後的檢查，全綠、`rc=0`（`mutate_p4_health.shard{0,1,2,3}of4.log`，各 100／99／99／99 個）。
  - **加起來的那一行**（`tests/shell/sum_p4_health_gate_shards.sh`，`LOG/r5/GATE.log`）：`GATE: 397 mutations, 0 survived, shards 4/4 ok`。
  - 同一支 script 讀第一輪（`mutate_p4_health.run1_61c19eab.shard*of4.log`，不是結果）：`NOT THE GATE`，原因是兩個存活與 `rc=1`（`GATE.run1_61c19eab.log`）。
- **第一輪 4 份在 `61c19eab`（不是結果）有 2 個存活：`C2R4-F4b`、`C2R4-F4d`。** 原因：`probe.py lab` 現在把任何例外變成 rc 2，這兩個舊測試只看 rc 2——F4d（拒絕之後繼續跑）撞上 `frozen.head` 的例外、F4b 的 git double 把 `rev-parse --verify HEAD` 也答成空——都是「rc 2 分不出是拒絕還是當掉」。已修（`59d6b014`：測試要求 stderr 有 `refused:`、沒有 traceback；double 把 HEAD 的問題留給真的 git），兩個在修好之後被抓到（`mutate_p4_health.partial_C2R4-F4_after_fix.log`，F4a–j 全抓到），然後整張表在 `59d6b014` 重跑一遍，就是上面的結果。
- **前一輪（`mutate_p4_health.partial_*`）的分段檢查**：本輪另在較早的 head 上用 `ONLY_LABEL_PREFIX` 分段跑過 `C2R5-` 的 mutant（沒有存檔，取代它的是上面的整張表）；其間抓到 3 個 mutant 自己的錯（`9a` 等價〔`mkdir` 本來就會擋〕改成要求訊息、`6d` 的註解吃掉續行、`6o` 的改法錯了），都已修。
- **磁碟**：`df -m /` 一開始就低於 brief 的 2600，且沒有任何我的行程在跑時停在 2485 超過 25 分鐘不回升；我在 2485 MB 起跑，另放一個看門狗（`disk_watchdog.log`；低於 1500 MB 就停四份 shard、高於 1800 才繼續），它沒有動過。跑的時候最低到 1915 MB（`disk_watchdog.log`）——四份 shard 同時跑自己大約吃掉 500 MB 左右的暫存（空閒時 2485，跑起來掉到約 1915–2400 之間擺盪）。這違反了「保持在 2500 以上」，已照實寫。
