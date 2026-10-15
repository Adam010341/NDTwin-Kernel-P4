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
  - 凍結（第 4 輪起，第 5 輪改過）：乾淨檢查之後、S0 之前，立刻把各輪會執行的 7 個檔（root 3 個、B 4 個，`frozen.py:42-44`）複製進 `<run>/frozen/`。HEAD 只問一次（`git rev-parse --verify HEAD`），每個副本用 `git hash-object --no-filters <副本>` 對 `<那個 sha>:tools/<路徑>` 的 blob 逐一比對；對不上、git 答不出、HEAD 釘不住、`<run>/frozen` 已存在、mkdir 失敗，都是 rc 2，什麼 lab 動作都還沒做（`frozen.py:13-24`）。那個 sha 記在 health.json 的 `frozen_head`。（這一條原來寫的是第 4 輪的做法，`git hash-object <副本>` 對 `git rev-parse HEAD:<路徑>`，已過時；r5 審查 #9。）
  - **第 6 輪起**：HEAD 在最前面釘一次（先於載入模組與乾淨檢查），乾淨檢查之後再問一次，不一樣就 rc 2（`probe.py cmd_lab`）；凍結拿這個 sha，不再自己問（§10，釘 HEAD 的 NIT）。S0 的 `exercise/` 副本在 `compile_all` 之後用同樣的 `git hash-object --no-filters` 對這個 sha 驗（`frozen.check_tree`），對不上、多一個檔、少一個檔、有連結、git 答不出，都是 rc 2，在任何 lab 動作之前（§10，finding 2）。
  - **凍結只蓋這 7 個檔，不是「這一輪執行的所有東西」**；`exercise/` 另有上面那道檢查；其餘從共用 tree 執行或讀的，見 §6 前提 3。
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

- Adam 對這一次逐次授權（DESIGN.md §9 Q6(a)：第一次 live，含看過紅那一次）。
- **在 ndtwin-lab 作用的那一棵 tree 跑，也就是主 checkout `/home/adam/Desktop/NDTwin-Kernel`**（Adam 對 r4 審查 #1 的裁示 (A)）。第 4 輪寫的「專用的乾淨 worktree」做不到，已拿掉：
  - **為什麼不是別的 checkout**：
    - claim 是每個 checkout 各一份：`CLAIM="$REPO/.test_run/lab.claim"`（`ndt:341`），`.test_run/` 是 per checkout（`ndt:6513`）。在 worktree 裡 claim，主 checkout 上的人看到的是 `claim none`。
    - root 的 helper 只指一棵 tree（`ndt:1526-1561`，「It names ONE tree, so two worktrees cannot both be live at the same time」）：`ndt up p4` 的 preflight 在別的 checkout 會拒絕（`ndt:2686`）。**`ndt down` 沒有這一關**：它只讀自己 checkout 的 claim、自己 checkout 宣告的 measuring 和四個 in-flight driver（`ndt:5141-5215`），然後對 lab 那棵 tree 跑 `sudo -n ndtwin-lab topo-stop`（`ndt:5356-5357`）；所以 teardown 的 `ndt down` 從任何 checkout 跑，都會停 lab 那棵 tree 的 fabric，不看主 checkout 的 claim。
    - `run.sh` 要有 `<checkout>/p4_proxy/venv/bin/python`（或 `P4_PROXY_PY`），kernel binary、venv、編好的 pipeline 也只在那一棵 tree 裡。
  - **前提 1（跨 checkout 規則，r5 審查 #1）：探測器持有 lab 的期間，任何 checkout 都不得跑 `ndt down`、`ndt clean` 或 `sudo ndtwin-lab …`；開跑前，先向每一個 session 宣告這一次 run（owner、run 目錄、預計時間：全輪約 13–18 分鐘，看過紅那一次另約 6–8 分鐘）。**
    - 為什麼 claim 擋不住：探測器的 claim 在主 checkout 的 `.test_run/lab.claim`（`ndt:341`）；別的 checkout 的 `foreign_claim` 只讀它自己那一份（`ndt:686-696`），那邊的 `ndt status` 顯示 `claim none`，它的 `ndt down` 的三道檢查（`ndt:5141-5215`）全部通過，然後 `topo-stop`（`ndt:5356-5357`）停掉探測器正在 A 或 B 中間的 fabric。（r5 審查的情境，讀碼得來，沒有實測。）
    - 這條只能靠人遵守與宣告，探測器和 ndt 都擋不住。ndt 的修法（讓 `cmd_down` 讀 `$(lab_kernel_dir)/.test_run/lab.claim`）在 ndt，不在這個分支。
  - **前提 2（helper 的 tree，r5 審查 #1）：`/etc/ndtwin-lab.conf` 不存在，或它的 `KERNEL_DIR` 就是主 checkout `/home/adam/Desktop/NDTwin-Kernel`**（預設值 `ndt:1409`；設定檔可以改它，`ndt:1479-1494`）。檢查命令在下面「命令」的第 2 行。
    - 不是的話：A 的 `ndt up` 被拒絕（`lab_round.py:395-398`），而 `finally` 裡的 teardown 仍然跑 `ndt down`（`lab_round.py:416-419`），那會停掉 helper 那棵 tree 正在跑的東西（`ndt:5356-5357`）。這是 r4 #1 的原樣。
    - 編輯本文時（10-09）`ls -l /etc/ndtwin-lab.conf` 是 No such file（OBSERVED，只代表那一刻；開跑前自己再查）。
  - **前提 3（乾淨檢查與凍結實際蓋到什麼，r5 審查 #2；這一條更正第 4、5 輪的說法）**：
    - 乾淨檢查只蓋 `tools/p4_health`（`git status --porcelain -- tools/p4_health`，`probe.py:174`）。凍結只蓋 7 個檔（`frozen.py:42-44`）：root 的 `hostside.py`、`frames.py`、`__init__.py`，B 的 `controller_ext.py`、`run_external_controller.py`、`common.py`、`__init__.py`。探測器行程自己用到的 `p4_health` 模組，在乾淨檢查之前就載入（`probe.LAB_PATH_MODULES`，`probe.py:61-69`）。
    - **乾淨檢查之後，這一輪還是從共用 tree 讀或執行下面這些；沒有任何一道檢查擋它們，改了就照用**：
      - （第 6 輪起不在這張清單：`exercise/` 整個目錄——S0 複製的副本現在在 `compile_all` 之後對釘住的 commit 驗過，controller trial 也改讀那份副本，不再 exec 共用 tree 的 `gen_runtime.py`，見 §10 finding 2。）
      - `tools/p4_health/openapi_probe.py`（`s0.py:698`）；
      - `tools/p4_exercise/convert.py`、`preflight.py`（`s0.py:265`、`:307`）；
      - `tools/test_workflow/heartbeat_drop_check.py`（`s0.py:329`）；
      - `tools/test_workflow/ndt` 與 `qdisc_snapshot.sh`，整輪都用（`collect/config.py:114`、`:125-126`）；
      - `exercise/` 底下的 `build*`（r7 審查 finding 10）：`check_exercise` 把副本本來就不含的 `__pycache__`、`build*` 扣掉（§10.1 finding 2），所以 `build*` 沒有被重驗。`expectations` 讀的 p4info 檔，與 B 的 build 目錄，都在這個缺口裡；沒有任何程式在擋，靠「命令」第 3 行延伸過的 `git status` 與「跑的期間沒有人動」；
      - live-p1 的 `code_identity.py` 與 `venv_fingerprint.sh`（`probe.py:233-242`；`identity.py:110-112`、`:146-148`）：它們產生 `system_under_test` 和基準指紋的 interpreters 部分。
    - 一個改動什麼時候被擋：
      - 乾淨檢查**之前**、在 `tools/p4_health` 之下：rc 2 拒絕。
      - 乾淨檢查**之後、凍結之前**：凍結的 7 個檔會因為副本對不上釘住的 commit 的 blob 而 rc 2（`frozen.py`）；**第 6 輪起，`exercise/` 的副本也一樣（在 S0 的 `compile_all` 之後驗）。`openapi_probe.py` 和上面清單的其他檔不會被拒絕，會被用。**（第 4、5 輪的文字寫成「檢查之後、凍結之前的改動都會被拒絕」，是錯的；r5 審查 #2。）
      - 乾淨檢查之前、在 `tools/p4_health` 之外（`tools/p4_exercise`、`tools/test_workflow`、live-p1 那兩支）：探測器不查；只有「命令」第 3 行的 `git status` 由人查。
      - 凍結**之後**：7 個檔、`exercise/` 的副本與已載入的模組，這一輪執行副本與已載入的碼，結果不受影響；清單裡的其他檔照樣被用，也不會被偵測。`gate_fingerprint` 的 tracked 部分（`repo_tracked`，約第 3 分鐘算）和 `system_under_test` 只記算的那一刻的狀態，之後的改動不在紀錄裡。
    - **所以原來的兩句是錯的**，已刪：「主 checkout 其他地方別的 session 的未提交改動不影響這一輪」（探測器還執行 `tools/p4_exercise`、`tools/test_workflow`、live-p1 的檔），以及「之後不再從共用 tree 讀 probe 程式」（`gen_runtime.py` 與子行程執行的檔不在其內）。`probe.py` 的 `LAB_PATH_MODULES` 註解也寫了同樣的話，**那段註解對這些檔是錯的**；第 6 輪已改成逐項寫出沒蓋到的是什麼、由什麼蓋（§10 finding 2）。
    - **`exercise/` 的缺口在第 6 輪關了**（`ctrl_trial` 讀 `<run>/exercise`，S0 的副本對釘住的 commit 驗過）；**第 6 輪只在 `compile_all` 之後驗一次**，之後 S0 把這份副本當 input 交給共用 tree 的 `convert.py`（`s0.py:265`，沒有任何東西查它），`lab.load_model` 更晚才從副本執行 `gen_runtime.py`（`lab.py`），所以那個保證只在 `convert.py` 不寫它的 input 時成立（r6 審查 finding 4）。**S0 自己的 controller trial 也比 `run_lab` 的再驗早**（r7 審查 finding 2）：S0 的順序是 `packages()`（`convert.py`，`s0.py:726`）…`ctrl_trial()`（`s0.py:731`），trial 從 `<run>/exercise/gen_runtime.py` 執行那份副本（`ctrl_trial.py:37-43`），所以 `convert.py` 若改了副本，被改的檔在 S0 裡已經被執行過一次，才輪到下面的再驗。這是安全失敗：再驗隨後拒絕（INCOMPLETE、rc 2），發生在任何 claim 之前，被改的模型到不了 lab。（讀碼得來，沒有測。）`probe.py:47-52` 的註解（`LAB_PATH_MODULES` 旁，列「`lab.load_model`、S0 與 controller trial 載入副本」那一段）要加同一句話；`probe.py` 在 gate 的 WATCHED 路徑裡，這一輪不動，留給下一輪 code。**第 7 輪起 `lab.run_lab` 在 `load_model` 之前再驗一次**（同一個釘住的 commit；claim 之前，所以被拒絕就是這一輪原本的「could not be set up」：INCOMPLETE、rc 2、什麼都沒 claim，health.json 的 `problems` 寫是哪個檔；§11 項目 3）。清單裡剩下的檔仍然沒有程式在擋，靠「命令」第 3 行延伸過的 `git status`，和「跑的期間，這些檔沒有人動」（前提 1 的宣告要把這一點也寫進去）。
  - **已知的殘餘（第 5 輪不修）**：gate fingerprint 會算進主 checkout 的未追蹤檔（`identity.py:91-97` 的 `repo_untracked`，除了 `.test_run/`、`scratch/`、run 目錄和 may-differ 那幾類），而主 checkout 常有別的 session 的未追蹤檔，所以兩輪之間這一項可能不同。第一輪的紀錄換成常設授權前，要先把「`repo_untracked` 的變動算不算相符」定下來（Adam 另外決定）。
  - 這一輪的 HEAD 是 `cmd_lab` 一開始**先釘住**的那一個（`probe.py:160`；乾淨檢查之後再問一次，變了就 rc 2；凍結拿到的是那個 sha，不再自己問：第 6 輪的釘 HEAD NIT，原來寫「凍結時 pin 住」是第 5 輪的做法）（health.json 的 `frozen_head`，也是 `repo_identity` 的 head）；主 checkout 上別的 session 之後再 commit，不改變凍結的 7 個檔與已載入的模組是什麼（commit 不改 working tree 的檔，所以清單裡的共用檔不因此被保護）。

**命令**

```
cd /home/adam/Desktop/NDTwin-Kernel                          # ndtwin-lab 作用的那一棵 tree
ls -l /etc/ndtwin-lab.conf                                   # 必須是 No such file；存在的話 cat 它，KERNEL_DIR= 必須是 /home/adam/Desktop/NDTwin-Kernel（前提 2；ndt:1409、1479-1494）
git status --porcelain -- tools/p4_health tools/p4_exercise tools/test_workflow \
    doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/code_identity.py \
    doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/venv_fingerprint.sh     # 必須是空的（前提 3）。probe.py 的乾淨檢查只替 tools/p4_health 擋（不是空的就 rc 2）；其餘路徑只有這一行在擋，由人看，不是空的就不開跑
NDT_OWNER=<owner> tools/test_workflow/ndt status                # 必須是 claim none、measuring nothing、bmv2 switches 0（claim 列 ndt:6849-6850，bmv2 switches 列 ndt:6992）
                                                                # 不要用 --measuring：它只印 declared、measuring（或 orphaned，ndt:6803-6807；recover.sh:309-316 靠這一列）幾種列（ndt:6818-6824），看不到 claim 與 bmv2
df -m /                                             # > 2500 MB（見上面「第一次 live 時要照做的兩條」第 2 條；程式不查）
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


**第一次 live 時要照做的兩條（r5 審查 #3、#4、#5 的程式部分在第 6 輪修了，見 §10；這兩條是讀結果的規矩，仍然有效）**

1. **一個結果要 rc 與 health.json 的 `verdict` 兩個一致才算數**。對應：COMPLETE＝0、PROBE-BROKEN＝1、INCOMPLETE 與 SEE-RED-NOT-SEEN＝2。
   - 第 6 輪起程式盡量讓兩者一致：`run_lab` 先寫 `observations.json`、最後才寫 `health.json`，都經過暫存檔與 `os.replace`；寫入失敗（磁碟滿最可能）不會留下一個帶 verdict 的 health.json；`probe.main()` 的 catch-all 在 rc 2 時，把已經在的 health.json 改名為 `health.json.not-a-verdict`，訊息以 `ERROR:` 開頭（不再是與真正拒絕相同的 `refused:`）；一個漏出 `run_lab` 的停止訊號是 rc 2、「stopped」，不再是 Python 的 status 1（§10 finding 3、5）。
   - 但規矩不變：**rc 與 verdict 對不上，這一輪作廢**。看過紅那一次，rc 1 而 `$RUN2/health.json` 不存在或 verdict 不是 PROBE-BROKEN ⇒ 不是過。health.json 不存在、或只有 `health.json.not-a-verdict`，就是沒有 verdict。
   - 第 6 輪的修法是讀碼加注入測試（`OSError` 注入在 `observations.json` 的寫入與 `os.replace`、log 呼叫）；真的磁碟滿沒有重現過。
2. **開跑前可用磁碟要高於下限**。下限是 §6 命令寫的 **> 2500 MB**；探測器與 `run.sh` 都不查（`tools/p4_health/*.py`、`run.sh` 沒有 `statvfs`／`df`），只有人查。**今天（10-09）不夠**：r5 審查寫 2485 MB，r6 起跑時 `df -m /` 是 2100 MB，gate 期間最低 1042 MB（別的專案在用磁碟，見 §10.4）；都低於 2500，所以今天不能開跑。
   - 停止之後先查 B 有沒有被 claim 這一條（r5 #4）：程式現在把 `_finish` 與 handler 還原放在同一個 signal mask 下，停止不再被吞掉（§10 finding 4）；**第 6 輪的這個說法以「行程只有一個 thread」為前提，那個前提不成立**（r6 審查 finding 1；`LOG/r7/obs.grpc_threads.log` 觀察到 gRPC 在行程裡留下 thread），第 7 輪起 `run_lab` 在第一次 claim 之前讀每個其他 thread 的 `SigBlk`，有任何一個不擋 SIGTERM、SIGINT、SIGHUP 就 rc 2、什麼都不碰，S0 的 ValueSet trial 在三個訊號擋住下跑（§11 項目 1），這條查法仍不是程序的一部分；若仍想確認，`$RUN/LAB_STATE.B.json` 不存在、`probe.log` 沒有「bring-up B (external)」那一行、`ndt status` 沒有第二次 claim，就是 B 沒起。

**停止（第 7 輪起；r7 審查 finding 4）**

- S0 的 ValueSet trial（`s0.stops_held()`，§11.2 項目 1）整段在 SIGTERM、SIGINT、SIGHUP 被擋住的狀態下跑（每個 bmv2 約幾十秒）。這段時間送出的停止（`kill -TERM`、Ctrl-C、關終端機）**不會立刻生效**：它等到 trial 結束、mask 放回才送達，行程再依預設動作結束。
- trial 卡住時，**只有 SIGKILL 出得去**（`kill -KILL <pid>`，用 pid，不用 `pkill -f`）。SIGKILL **只在第一次 claim 之前安全**：S0 在任何 claim 之前跑（§1.3），拋棄式 bmv2 有 `prctl(PDEATHSIG)`，會跟著結束；殺完用 `ndt status` 確認沒有 claim、沒有 bmv2。
- **claim 之後不要靠 SIGKILL，改用 `recover.sh $RUN`**（人執行，見上面「命令」最後一行）。是否已經 claim，看 `ndt status`、`probe.log` 與 `$RUN/LAB_STATE*.json`。

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
- delta：57 格裡 same 30、not observed 27、**flipped 0**（假 fabric 的端對端測試實測，第 5 輪補存了 log：`LOG/r5/delta_counts.log:7-10`，rollup 也在裡面；產生它的 script 是 `LOG/r5/delta.py`，與 log 第 2 行指名的那份 byte 相同（`cmp`）；兩列對照 K1-neg、T3-neg 另外各是 same）；
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
- **LOG5** 指 `LOG/r5/`。**log 的開頭與結尾並不一致**（r5 審查 #9，逐份查過；原來寫「每份 log 第 1 行是 `commit <sha> tree <tree> …`，最後一行是 `rc=`」是錯的）：
  - `n*.log`、`test_*.log`、`check_*.log`、`delta_counts.log`：第 1 行是 `commit <sha> tree <tree> (tools/p4_health) tracked-dirty=0`，最後一行 `rc=`；
  - `mutate_p4_health.shard*of4.log`、`mutate_p4_health.run1_*.shard*of4.log`、`GATE*.log`、`mutate_p4_health.partial_C2R4-F4_after_fix.log`、`n6.old.*.log`：第 1 行**只有** `commit <sha>`，沒有 tree（shard log 的 tree 在 `HEAD`／`tree`／`subject sha` 那幾行，`mutate_p4_health.shard0of4.log:6-8`）；最後一行 `rc=`；
  - `mutate_p4_health.partial_early_*.log`：第 1 行是「partial run of the C2R5- mutants from a snapshot of an earlier head…」，沒有 `commit` 行；`partial_early_m2` 和 `partial_early_m2a` **連 snapshot 那一行都沒有**（`partial_early_m2.log:6-7` 的 HEAD 是 `8437dba4`、tree 行寫 `+UNCOMMITTED changes`，即它在 W 裡以未提交的改動跑；`partial_early_m2a.log:6-7` 的 HEAD 與 tree 是空的，是 scratchpad 的複本）；`partial_early_m2` 最後一行是「PARTIAL RUN…」，沒有 `rc=`；
  - `disk_watchdog.log`：沒有 `commit` 行，也沒有 `rc=`（見 §8.5 的磁碟一條）。
  - 紅都是**先 commit 測試、再跑**；r5 的 commit 在跑完之後改寫過一次（只改訊息，tree 不變），log 第 1 行是改寫前的 sha，對照在 `LOG/r5/SHA-MAP.txt`（紅 log 的 commit 是只有測試、還沒有修的那一個；第 1 行的 `tracked-dirty=0`）。SHA-MAP 只配對了 sha，沒有 log 顯示新 sha 的 tree。
- **新 mutant 的前綴**：`C2R5-`，共 69 個（表現在 397 個＝328＋69）。
- **#1（which tree）**：Adam 裁示 (A)，§6 已照改（在主 checkout 跑，前提與殘餘寫在 §6 前提）。「專用的乾淨 worktree」已從 SUMMARY 拿掉。

### 8.1 每一項

| 項 | 改了什麼 | 紅（LOG5） | 綠（LOG5） | mutant |
|---|---|---|---|---|
| #2 rc 1 不再兼代三件事 | `lab.run_lab`：S0 不是 COMPLETE、準備階段出錯（load_model、expectations）、`_rounds` 丟出的 Exception（StateInUse 等）都是 INCOMPLETE rc 2，health.json 的 `problems` 寫原因；`probe.py lab` 的 S0 不是 COMPLETE 也走 run_lab（不做 identity、不碰 lab）；`main()` 接住 `cmd_lab` 的任何 Exception，印 traceback、rc 2。**這句原來還寫「這種情況沒有 health.json」，對一種例外是錯的**（r5 審查 #5）：例外若發生在 `lab.py:257` 寫完 health.json 之後（observations.json、log 行，`lab.py:258-267`），health.json 已經在，它的 verdict 可能是 PROBE-BROKEN、`problems` 是空的，而 rc 是 2；見 §6「還沒修的缺陷」第 1 條與 §9。測試用的假 `Reached` 改成 BaseException（`MustNotRun`），不然「一碰就失敗」的 double 會被這個 handler 吞掉 | `n2.collect.RED.log`、`n2.cells.RED.log`（`296d8eb8`；`n2.collect.RED.log:145` 是 4 個 ERROR〔例外跑出 run_lab〕加 1 個 FAIL〔rc 1 ≠ 2〕；`n2.cells.RED.log:17` 另有 1 個 FAIL〔S0 不完整時 rc 1、沒有 health.json〕，所以這兩份合起來是 4 個 ERROR、2 個 FAIL）、`n2b.cells.RED.log`（`8437dba4`；S0 丟例外時 `main` 讓它跑出去；`n2b.cells.RED.log:23` 是 1 個 ERROR） | `n2.collect.GREEN.log`、`n2.cells.GREEN.log`（`d4fb721e`） | `C2R5-2a`–`2h` |
| #3 看不到紅的 see-red 不是過 | `cells/verdict.py`：`see_red`、完整乾淨、沒有任何 PROBE-BROKEN → **`SEE-RED-NOT-SEEN`、rc 2**（不是 COMPLETE rc 0；也不是 rc 1，因為 rc 1 是 see-red 的過） | `n3.collect.RED.log`、`n3.cells.RED.log`（`ba539085`；`('COMPLETE', 0) != ('SEE-RED-NOT-SEEN', 2)`） | `n3.collect.GREEN.log`、`n3.cells.GREEN.log` | `C2R5-3a`–`3c` |
| #4 B 跑了但什麼都沒確認 | `round_b.BRound.did_nothing`：除了預期的 `register`，什麼都沒確認，或 s2 不是 primary（只要 s2 的記錄有、沒有 `connect_error`、而 `primary` 不是 true；比審查寫的「且 set_pipeline_ok」更嚴，是它的超集）→ failed B。假 controller 的 `switches` 照 `controller_ext.py:130-157`、`205`、`336-339` 的形狀寫（連得上、沒回應這兩種是照碼；**「s2 不是 primary」那一種是假設的**，不是複製來的：真的 controller 在這種情況會記 `set_pipeline_ok: False` 和 `set_pipeline_error`，`controller_ext.py:150-156`，而 FakeController 仍記 `set_pipeline_ok: True`；r5 審查 #8，未改）；「沒有交換機回應」時 digest／packet-in 也是空的（控制器收不到） | `n4.RED.log`（`d260a803`；兩個 `('COMPLETE', 0)`）、`n4b.RED.log`（`ab637862`，interface：`did_nothing` 還不存在，行為由 4a／4b 承擔） | `n4.GREEN.log` | `C2R5-4a`–`4d` |
| #5 凍結之後的探測器程式 | 選項：**在乾淨檢查之前把 lab 路徑會載入的每個 `p4_health` 模組都 import**（`probe.LAB_PATH_MODULES`、`load_lab_path`），而不是事後逐檔對 HEAD 重驗。理由：重驗比的是磁碟上的檔，不是行程載入的碼（改了又改回來會過），而且蓋不到驗證之後才載入的模組；先載入則檢查之後行程不再從共用 tree 讀 `p4_health` 的模組（**只對模組成立**：用路徑 exec 的 `gen_runtime.py` 與子行程執行的共用檔不在內，見 §6 前提 3、§9）。`S0(frozen=)`：controller trial（`ctrl_trial.trial(controller=)`）與 adapter dry-run 用凍結的副本 | `n5.RED.log`（`64b056e4`）、`n5b.RED.log`（`a613f863`）：dry-run 的 argv 指共用 tree、trial 沒有 `controller`、identity 在 S0 時還沒載入、probe 沒把 frozen 交給 S0 | `n5.GREEN.log` | `C2R5-5a`–`5g` |
| #6 量測工具 | `mutate_p4_health.sh`：在 baseline **之前**拒絕 `MUT_SHARD` 的 k ≥ n、n > 表的大小、格式不對（含前導 0）、以及任何選不到突變的跑法（含吻合不到任何東西的 `ONLY_LABEL_PREFIX`）；每份 shard log 頂端與尾端印 `NOT THE GATE BY ITSELF: shard k/n`；新 `tests/shell/sum_p4_health_gate_shards.sh <log>…`：同一個 commit／tree／subject sha、baseline／控制／after-check 都綠、rc 都 0、k 剛好 0..n-1、各份的數量等於各自的份額，才印 `GATE: N mutations, S survived, shards k/n ok`，否則印 `NOT THE GATE: …`、rc 1。測試 `tests/shell/test_p4_health_gate_scripts.sh`（43 個檢查）；gate 的 mutant 現在也可以改這兩支 script 的副本。（檔名不用 `mutate_*`，因為 `check_gate_anchors.py` 會把那樣的檔當成 gate、找不到 anchor 就 exit 2。） | `n6.RED.log`（`bc8980f3`，43 個檢查 38 個紅）；**今天的 script 拒絕不了的跑法**（`n6.old.*.log`，在 `ed6dce9b`）：`MUT_SHARD=400/500` 跑 0 個突變、`rc=0`；`ONLY_LABEL_PREFIX=NOPE-` 跑 0 個突變、`rc=0`；`MUT_SHARD=5/4` 原來就拒絕，但是在約 1 分鐘的 baseline **之後** | `n6.GREEN.log` | `C2R5-6a`–`6z`（26 個，用 `test_p4_health_gate_scripts.sh` 的檢查名當預期） |
| NIT 7 | `frozen.freeze`：`git rev-parse --verify HEAD` 一次，blob 用 `<sha>:tools/<path>`；`Frozen.head`；health.json 的 `frozen_head`；`repo_identity(head=)` 用同一個 sha | `n789.RED.log`（`1bcdeaf5`；中途 commit 竟然通過凍結） | `n789.GREEN.log` | `C2R5-7a`–`7e` |
| NIT 8 | `git hash-object --no-filters` | 同上（run 目錄在 repo 裡、`*.py text`、CRLF 的副本通過） | 同上 | `C2R5-8` |
| NIT 9 | `<run>/frozen` 已存在就拒絕；`os.mkdir`（不 exist_ok）建目錄、`O_CREAT\|O_EXCL\|O_NOFOLLOW` 開檔（`frozen.copy_file`）；放在目的地的連結被拒絕、目標不動 | `n789.RED.log`、`n9b.RED.log`（`b49c95a4`；子目錄的連結） | `n789.GREEN.log` | `C2R5-9a`–`9c` |
| NIT 10 | `lab_round.py`：body 的 raiser 先換成收拾期間的 handler 再 raise；換 handler 時用 `pthread_sigmask` 擋住三個訊號；紀錄在 `_restore_handlers` **之前**定稿（`_finish`）；`LabRound.rec`，`lab.take_unrecorded` 在 run 被訊號或例外提前結束時補上已開始的輪的紀錄與 state 檔 | `n10_13.RED.log`（`5bebaa96`：第二個訊號跑出 `run()`、teardown 沒跑；`restore` 之後的訊號與例外讓該輪紀錄不見） | `n10_13.GREEN.log` | `C2R5-10a`–`10d` |
| NIT 11 | `probe.py judge` 從紀錄讀 `stopped`（旗標、輪的 problems、run 的 problems）與 `see_red`（`mutant`／`see_red`）；`observations.json` 多寫 `bringups_complete`、`stopped`、`see_red`、`bringups`、`problems` | `n11.cells.RED.log`、`n11.collect.RED.log`（`8def2d90`） | `n11.cells.GREEN.log`、`n11.collect.GREEN.log` | `C2R5-11a`–`11f` |
| NIT 12 | `ctrl_garbage_result` 標明是假設性的（真的 controller 用 tmp＋`os.replace`，`controller_ext.py:399-404`）；`runner.py` 的引用改成 66-71；`adapter_argv` 的 docstring 改成實話（S0 的 dry-run 用同一個 argv 加 `--dry-run`；controller trial 不經過 adapter）；選項：凍結的 adapter＋controller 照 B 的 argv（沒有 `-I`；**直譯器是 `sys.executable`，不是 B 用的 p4dev 直譯器**〔`round_b.py:119`〕，所以「B 的 argv」只在形狀上成立，r5 審查 #8，第 6 輪已在測試的 docstring 寫明）真的啟動一次，p4runtime 用 stub，檢查載入的檔沒有一個在共用 tree 下，控制組是同樣啟動共用 tree 的檔、偵測器必須看到 | `n12.cells.GREEN.log`（沒有紅：沒有要修的行為；紅由控制組與 mutant 承擔） | 同左 | `C2R5-12` |
| NIT 13 | `rec["complete"]` 也需要 `knobs_restored` | `n10_13.RED.log`（`True is not false`） | `n10_13.GREEN.log` | `C2R5-13` |

### 8.2 沒辦法確定性測的

- **NIT 10**：`_swap_handlers` 擋住三個訊號再換 handler，目的是不讓訊號夾在兩次 `signal.signal` 之間；這個窗口是位元碼之間的幾個指令，我沒有辦法確定性地在那裡送訊號，所以**沒有針對 `pthread_sigmask` 本身的測試或 mutant**。測到的是審查點名的兩個縫：第二個訊號在 `_handlers(False)` 之前（從那個 hook 送）、訊號／例外在 `_restore_handlers` 之後（從那個 hook 送）。一個訊號落在 `return rec` 與 `recs.append` 之間（呼叫邊界）與 `_restore_handlers` 之後走同一條 `take_unrecorded` 的路，但沒有單獨在那個點測。
- **#6**：真的 shard log 尾端那一行 `NOT THE GATE BY ITSELF` 要整個 shard 跑完才碰得到，沒有 mutant；`MUTATIONS == SELECTED` 的保險（`mutate_p4_health.sh:2901`）**原來寫成「要整個 shard 才碰得到」是錯的：它不可能失敗**（`MUTATIONS` 在每次 `mutate()` 開頭加一，`:2814`，迴圈對每個被選的索引呼叫一次，`:2868-2871`），真正的保險是加總 script 的份額檢查（`sum_p4_health_gate_shards.sh:134-138`；r5 審查 #7，未改）；被釘住的是頂端那一行，與 sum script 讀的合成 log（格式取自 r4 的真 shard log）。
- **NIT 9**：`O_NOFOLLOW` 與 `O_EXCL` 沒有各自分開的測試（目的地是連結時 `O_EXCL` 本身就失敗）；mutant `9b` 把兩個一起拿掉。
- **NIT 12**：B 的真實啟動用的是 stub 的 `p4runtime_lib`、沒有交換機；controller 的 `frames` 延遲 import 是用結束時的 `import p4_health.frames` 驗，不是 controller 真的在連線後走到它。
- **#5**：行程啟動到乾淨檢查之間（`probe.py` 頂端 import 的 `expected`、`report`、`cells`、`collect.config`、`runner`）與「改了又改回來」都不在保護內。

### 8.3 沒有改、或新發現的

- **共用 tree 裡的碼，乾淨檢查和凍結都沒蓋到**（完整清單與行號在 §6 前提 3；r5 審查 #2 更正了原來較短的清單）：
  - `exercise/gen_runtime.py`（controller trial 的模型）與 `exercise/` 的副本（T1／PL1 的預期）：**第 6 輪已關**，副本對釘住的 commit 驗過、trial 讀副本（§10 finding 2）；
  - `openapi_probe.py`（`s0.py:698`）；`tools/p4_exercise/convert.py`、`preflight.py`；`tools/test_workflow/heartbeat_drop_check.py`；
  - `ndt` 與 `qdisc_snapshot.sh`，整輪都用；
  - live-p1 的 `code_identity.py` 與 `venv_fingerprint.sh`（`system_under_test` 與指紋的 interpreters 部分）。
  - 原來的清單漏了 gen_runtime 的行程內 exec、live-p1 的兩支、`ndt` 與 `qdisc_snapshot.sh`。#5 只涵蓋審查點名的 controller trial、adapter dry-run 與 identity 等模組；`LAB_PATH_MODULES` 看不到用路徑 exec 的檔（`hc_gen`、`hc_gen_lab` 不在 `sys.modules`）。
- **gate fingerprint 的未追蹤檔變動**（`identity.py:91-97`）：依指示沒有修，寫在 §6 前提。
- **`run_lab` 寫的 `observations.json` 不能直接交給 `probe.py judge`**：JSON 來回後 `table.py` 的 `t1` 對 list 做 `set()`（unhashable），修好之後 M1、M2、C1 拿 list 和 frozenset 比，三格會默默讀成 RED（r5 審查 #10）。這在第 5 輪以前就如此；NIT 11 的離線測試用手做的紀錄，只釘 `judge` 讀的那幾個欄位。**第 6 輪修了，並加了來回測試**（§10 finding 10）。
- F10、`show_ports_trial` 沒有單元測試：沒有動。

### 8.4 r4 審查「數字對不起來」的處理

- 「Three doc-only commits follow 2e630d34」：只有兩個（`d8ce630b`、`ed6dce9b`）。
- 「每份 log 最後一行是 `rc=`」：除了兩份 `stopped_by_me_*`（已寫在 LOG4 的說明）。
- `recover_claiming.log:3,18,33` 標的 39／18／187（共 300）來自那次沒存檔的 300 次；存檔的 `claim_kill_300.log` 是 35／24／241。兩份是不同的跑，不互相佐證。
- `partial_F1-F3.log:97-100`、`:117-119`：`C2R4-F3e` 在 `551b2751` 是 WRONG-TEST 的存活，`cbc47503` 把它的預期測試改對；第 4 輪的 SUMMARY 與回報都沒有提。
- `f3.GREEN.log`（`0fa6902a`）早於 `3b283c48` 把 stop 改成旗標：出貨的碼由 `2e630d34` 的整份綠與 mutant `F3b`、`F3c` 涵蓋，不是那份 log。
- cells：+10 之後是 130（`2e630d34` 的 `test_cells.py*.log`，§7.3）。**原來寫的「`b1efe699` 的 `Ran` 是 120（第 5 輪把那個 commit 的封存檔跑了一遍：cells 120、collect 130）」沒有 log**（`LOG/r5/` 裡沒有那一次跑；同 r4 審查 #14 那種「單獨重跑」），**120 這個數字因此未經 log 支持，標為未記錄**，不能拿來證明「119＋10＝129」是錯的。
- §6 的 delta 數字（30／27／0 flipped）和 rollup：`LOG/r5/delta_counts.log:7-10`（假 fabric 的端對端測試，`COMPLETE` rc 0，57 格：same 30、not observed 27；對照 2 列 same；core 9／1／3／3、full 6／4／3／3、q3b 0／0／0／6）。log 第 1 行有 commit 與 tree（`dd2e7300`／`fbf5a13c`，`tracked-dirty=0`），第 2 行的命令指名一支 scratchpad 的 `delta.py`；那支 script 現在存檔為 `LOG/r5/delta.py`（一支很短的 script，跑假 fabric 的完整 run 並數 delta），與 log 第 2 行指名的那份 byte 相同（`cmp`）。

### 8.5 gate 與最後的檢查（在 `59d6b014`，LOG5）

- `check_gate_anchors.py HEAD`：133/133 cells ok，`mutate_p4_health.sh` ok(373)（`check_gate_anchors.HEAD.log`）；`check_test_tmpdirs.py`：416 個檔，0 個固定暫存路徑（`check_test_tmpdirs.log`）。
- `p4_proxy/venv/bin/python`：collect 162 個 OK、cells 153 個 OK、`test_p4_health_recover.sh` 163 checks 0 failed、`test_p4_health_gate_scripts.sh` 43 checks 0 failed（`test_collect.log`、`test_cells.log`、`test_recover.log`、`test_gate_scripts.log`）。
- **mutation gate：397 個突變（328＋69），0 存活**，4 份 shard 各自有基線、負對照、byte-identical 與之後的檢查，全綠、`rc=0`（`mutate_p4_health.shard{0,1,2,3}of4.log`，各 100／99／99／99 個）。
  - **加起來的那一行**（`tests/shell/sum_p4_health_gate_shards.sh`，`LOG/r5/GATE.log`）：`GATE: 397 mutations, 0 survived, shards 4/4 ok`。
  - 同一支 script 讀第一輪（`mutate_p4_health.run1_61c19eab.shard*of4.log`，不是結果）：`NOT THE GATE`，原因是兩個存活與 `rc=1`（`GATE.run1_61c19eab.log`）。**注意那份 log 的第 1 行寫 `commit 59d6b014`，它的 shard 卻是 `61c19eab` 的**（`mutate_p4_health.run1_61c19eab.shard0of4.log:1`）：加總 script 印的 commit 是它自己跑在哪個 checkout，不是 shard 的 commit，GATE 那一行也不比對兩者（`sum_p4_health_gate_shards.sh:144-145`；r5 審查 #6，未改）。這一輪的證據不受影響：四份最終 shard 各自寫著同一個 commit、tree、subject sha（`mutate_p4_health.shard0of4.log:1`、`:6-8`，其餘三份相同位置）。
- **第一輪 4 份在 `61c19eab`（不是結果）有 2 個存活：`C2R4-F4b`、`C2R4-F4d`。** 原因：`probe.py lab` 現在把任何例外變成 rc 2，這兩個舊測試只看 rc 2——F4d（拒絕之後繼續跑）撞上 `frozen.head` 的例外、F4b 的 git double 把 `rev-parse --verify HEAD` 也答成空——都是「rc 2 分不出是拒絕還是當掉」。已修（`59d6b014`：測試要求 stderr 有 `refused:`、沒有 traceback；double 把 HEAD 的問題留給真的 git），兩個在修好之後被抓到（`mutate_p4_health.partial_C2R4-F4_after_fix.log`，F4a–j 全抓到），然後整張表在 `59d6b014` 重跑一遍，就是上面的結果。
- **較早的 head 上的分段檢查**（`mutate_p4_health.partial_early_*.log`；不是 gate，開頭格式見 §8 開頭）：本輪用 `ONLY_LABEL_PREFIX` 分段跑過 `C2R5-` 的 mutant。log 實際顯示：
  - `partial_early_m2`（8 個突變，1 個存活，`:69`）：**負對照是紅的**——「A COMMENT TURNED A SUITE RED: test_an_s0_with_a_failing_check_is_rc_2_with_a_health_json_and_no_identity_work」（`partial_early_m2.log:61-63`）。那個測試在 gate 的複本裡是紅的（後來 `d4fb721e` 修了這個測試用的 predictions 檔路徑〔`Config` 的 `expected_tsv`，`r5-diff.patch:271-274`，`SHA-MAP.txt` 有它的 sha 配對〕），所以**在這一次跑裡，2a、2b 以及其他幾個突變的「caught」是因為那個無關的紅**（每個突變的 `also red` 都列著它，`:17`、`:23`、`:29`、`:35`…），不能算 2a／2b 的證據。最終 gate 在 `59d6b014` 取代這一次，不受影響；但這份分段不能當 2a／2b 的獨立佐證；
  - `partial_early_mall`（31 個突變，1 個存活，`:207`）：`9a`（`:143`）；
  - `partial_early_mB`（26 個突變，2 個存活，`:182`）：`6d`（突變不能 parse，`:39`）和 `6o`（WRONG TEST，`:104`）；`partial_early_mB2` 之後 0 個存活（`:181`）；
  - `partial_early_mC`：baseline 因為環境變數 `ONLY_LABEL_PREFIX` 漏進 gate-script 測試而紅（`:14`；測試現在清掉 `MUT_SHARD`／`ONLY_LABEL_PREFIX`／`ANCHOR_CHECK`）；
  - 修法：`9a` 是等價的（`mkdir` 本來就會擋，改成測試要求訊息裡有「already exists」）、`6d` 的註解吃掉續行、`6o` 的改法不是把檢查關掉。
  - 取代這些分段的是上面在 `59d6b014` 的整張表。
- **磁碟**：`df -m /` 一開始低於 brief 的 2600，這一輪在 2485 MB 起跑，違反 §6 的「保持在 2500 以上」，照實寫。另放了一個看門狗（低於 1500 MB 就停四份 shard、高於 1800 才繼續）。**log 只支持很少的東西**（`disk_watchdog.log` 共 6 行）：第 1 行是起始（free 2485 MB），其後 5 行只記「new min free」，從 23:40:49（2484 MB）到 23:47:30（1915 MB）（`disk_watchdog.log:2-6`）；**沒有結束記錄**，沒有 commit 行，沒有 `rc=`。所以：
  - 「跑的時候最低到 1915 MB」：只對 23:40:49–23:47:30 有 log；
  - 「看門狗沒有動過」：log 沒有動作記錄，也沒有 23:47:30 之後的任何一行，不能從 log 證明它整個 gate 期間都沒動、甚至還在跑；
  - 「空閒時 2485、跑起來在 1915–2400 之間擺盪」的上界 ~2400：log 只記新的最低值，沒有這個數；
  - 這三句原來寫成事實，已改為上面的範圍。
  - 這個 gate 的結果沒有因此受影響的跡象：四份 shard 沒有 ENOSPC、Errno 28、No space、HUNG、NO-SUITE、WRONG TEST、SURVIVED 的行（`grep -c` 四份都是 0），基線、負對照、after-check 都綠。機制上，磁碟滿會讓很多測試同時紅，而 gate 把「指名的測試在紅的集合裡」算成 caught（`mutate_p4_health.sh:2852`），所以低磁碟的方向是假 caught，不是漏跑。

## 9. 第 5 輪審查（r5 review，對 `269251f1`；code 與測試在 `59d6b014`）

審查結論：**MERGE AFTER FIXES**。code 與測試在 `59d6b014` 成立（gate 的四份 shard 逐份讀過）；沒有任何拒絕被放鬆。這個 commit 只改這份文件，沒有動 code、測試、`probe.py` 的註解，所以 `59d6b014` 的 mutation gate 結果仍然有效，不重跑。

### 9.1 這個 commit 在文件裡更正了什麼

- **finding 1**：§6 加了前提 1（跨 checkout 規則）、前提 2（helper 的 tree）和命令第 2 行（`/etc/ndtwin-lab.conf`）；「為什麼不是別的 checkout」補上 `ndt down` 沒有 tree 的那一關。
- **finding 2（文字）**：§6 前提 3 重寫（乾淨檢查和凍結實際蓋到什麼、檢查之後仍從共用 tree 執行的清單、什麼時候被擋）；§6 命令的 `git status` 延伸到 `tools/p4_exercise`、`tools/test_workflow` 和 live-p1 那兩支；§8.3 的清單；§1.3 的凍結描述；說明 `probe.py:38-47` 的註解是錯的（沒有改，它是程式）。
- **finding 3、4、5（修好之前）**：§6「還沒修的缺陷」三條：rc 與 verdict 要一致、停止之後查 B 有沒有被 claim、磁碟下限；§8.1 #2 列把「沒有 health.json」改成只對一部分例外成立。
- **finding 9**：§8 開頭的 log 開頭／結尾描述；§8.4 的 cells 120（標為未記錄）與 delta.py（存檔，`cmp` 相同）；§8.5 的早期分段（含紅的負對照）和磁碟；§1.3 的過時描述。
- **「數字對不起來」**：§8.1 #2 列的 ERROR／FAIL 數（`n2.collect.RED.log:145` 是 4 ERROR＋1 FAIL，`n2.cells.RED.log:17` 另有 1 FAIL）；§8.5 的 `GATE.run1_61c19eab.log` 第 1 行。
- **順手改的（同一批 finding 的文字）**：§8.1 #4 列（s2 不是 primary 那一種是假設的，finding 8）、§8.1 #5 列（只對模組成立）、§8.2（`MUTATIONS == SELECTED` 不可能失敗，finding 7）、§6 前提的 Q6 引用改為 DESIGN.md §9。

### 9.2 當時還開著的（第 6 輪全部處理了；逐項見 §10）

| finding | 內容 | 位置 |
|---|---|---|
| 2（code） | `ctrl_trial` 改讀 `<run>/exercise`（S0 傳 `self.ex`）；`compile_all` 之後用同樣的 `hash-object --no-filters` 把 exercise 副本對 `frozen.head` 驗；改 `probe.py:38-47` 的註解；可選：S0 結束時審一次 `sys.modules`，補上 `LAB_PATH_MODULES` | `ctrl_trial.py:36-47`、`s0.py:185-188`、`probe.py:38-47` |
| 3 | `main()` 接 `SignalAbort` 當 rc 2（stopped; INCOMPLETE），和／或讓 run 層的 raiser 像各輪的一樣只觸發一次（先換成 noter 再 raise） | `probe.py:249`、`lab.py:117-123`、`:205-226` |
| 4 | `_finish` 與 handler 還原放在同一個 `pthread_sigmask` 之下，或還原之後重讀 `teardown_signal`；同處的 NIT：A 的第一個停止落在 try 結尾與 `_handlers(False)` 的換 handler 之間，會在 `finally` 裡 raise 而略過 teardown（走 `recover.sh` 安全失敗）；`take_unrecorded` 寫進 health.json 的紀錄可能是 `_finish` 沒碰過的（`complete` 仍為 True、`down_rc`／`release_rc` 是 None），應標為不完整 | `lab_round.py:394-403`、`:407`；`lab.py:101-109`、`:140` |
| 5 | 先寫 observations.json、最後才寫 health.json，用 tmp＋`os.replace`；catch-all 對已存在的 health.json 改名或標記；catch-all 的訊息換一個與拒絕不同的前綴 | `lab.py:257-267`、`report.py:75-78`、`probe.py:249-257` |
| 6 | GATE 那一行印出它認證的 commit、tree、subject sha，與 checkout 的 HEAD（或要求的 `--commit`）不同就拒絕；`+UNCOMMITTED` 的 pathspec 加上 gate 自己的三支 script、`tools/p4_exercise/*`、`p4_proxy/mininet/grpc_ports.py` | `sum_p4_health_gate_shards.sh:144-145`、`mutate_p4_health.sh:60-61` |
| 7 | `MUTATIONS == SELECTED` 的保險不可能失敗（真正的保險是加總 script 的份額檢查）；`GATES_SUM` 含絕對路徑，不要跨 log 比較（partial F4 log 的 `fc6727630a451269` 與 shard 的 `004904542fd1ca40`，script 相同） | `mutate_p4_health.sh:2772`、`:2894`、`:2901` |
| 8 | FakeController 的「s2 不是 primary」要標為假設；NIT 12 的啟動用 `sys.executable`，不是 B 用的 p4dev 直譯器（「B 的 argv」只在形狀上成立）；#5 的偵測器只算 `sys.modules` 裡以 `p4_health` 開頭的名字，用路徑 exec 的檔看不到 | `round_b.py:119`；偵測器在 `n5` 的測試 |
| 10 | `probe.py judge` 讀不了 `run_lab` 寫的 observations.json：JSON 來回後 `table.py:335` 對 list 的 list 做 `set()` 會 TypeError；修好之後 M1、M2、C1 拿 list 和 frozenset 比（`table.py:414`、`:425`、`:434`），三格都會默默讀成 RED。要加一個 `run_lab` → observations.json → `probe.py judge` → 同樣標題與格的來回測試，之後離線重判才能當證據。§8.3 原來只寫了 TypeError 那一半。不擋第一次 live（`run_lab` 在行程內判格，§6 不呼叫 `judge`） | `cells/table.py:335`、`:414-434` |
| NIT（釘 HEAD） | 凍結在 `load_lab_path` 與乾淨檢查**之後**才釘 HEAD；那一秒內有人 commit 到 `tools/p4_health`，`frozen_head` 就會指向預載的模組不是從那裡讀的 commit。先釘，乾淨檢查也用同一個 sha | `probe.py:145-172` |

- 另外兩條仍然是前提而不是 code：Adam 對這一次的逐次授權（DESIGN.md §9 Q6(a)）；`repo_untracked` 的變動算不算相符（§6 前提的「已知的殘餘」），要在第一輪的紀錄變成常設授權之前決定，不是第一次 live 之前。
- 如果下一輪改了 code：所有 shard 在新的 head 上重跑，GATE 那一行連同四份 log 一起附上，那個 diff 另外審查。
- 這份審查的 finding 3、4、5、10 是**讀碼**得來的，沒有執行過；上面的描述要這樣讀。

## 10. 第 6 輪（r5 審查的程式項目）

- **基底**：`257fd0e0`（r5 審查的對象 `269251f1` 之後的文件 commit；`tools/p4_health` 的 tree 與 `59d6b014` 相同，`fbf5a13c`）。**code 與測試的 head：`b09cd060`**（`tools/p4_health` 的 tree＝`4acc71ea`）；之後只有這份文件的 commit，tools 與 tests 沒有再動。
- **LOG6** 指 `LOG/r6/`。**log 的開頭與結尾**（r6 審查 finding 2 更正；原來寫「每份 log 第 2 行有 `tracked-dirty=<n>`」只對一部分成立）：第 1 行是 `commit <sha>`、最後一行 `rc=` 對**每一份** log 成立，**除了** `disk_watchdog.log`（有 `start`／`end` 記錄，沒有 commit 行與 `rc=`）；第 2 行則分三種：`n*.log`、`test_*.log`、`check_*.log` 是 `cwd … tracked-dirty=<n>  command: …`；`mutate_p4_health.*.log`（shard、partial、aborted、run1）是 gate script 自己的 `gate       : …` 那一行；`GATE*.log` 是 `GATE: …` 或 `NOT THE GATE: …` 那一行。第 1 行**另外帶註記**的不只 `GATE.run1`：`partial_*` 帶「(a partial run, not the gate)」，`GATE.at_doc_head_*` 帶「(the aggregator …)」，`GATE.run1_c82a9f49` 帶「NOT THE GATE: one survivor」。
  - 紅：每一項都是**先 commit 測試、再跑**；紅 log 的 commit 是只有測試、還沒修的那一個，`tracked-dirty=0`。第一項（finding 2）的紅在 `e85aab7a`，它的 `tools/p4_health` tree 與 `257fd0e0` 的相同（`fbf5a13c`）；其後各項的紅，tools 裡含有前面各項的修，測試仍在它自己的修之前紅。
  - 綠：修的 commit 之後跑整份 cells、collect（和 finding 6、7 的 `test_p4_health_gate_scripts.sh`）。
  - 每一項各一個「測試」commit 與一個「修」commit（修的 commit 同時帶它的 mutant）；有幾個測試 commit 後面接著一個很小的測試修正 commit（測試自己的錯，紅 log 在修正之後重跑）。
- **新 mutant 的前綴**：`C2R6-`，共 53 個（表現在 450 個＝397＋53）。另有舊 mutant 的 anchor 隨被改動的行搬了位置：`18adf47c` 重新對位 B1、C2R3-N1c、C2R4-F4c、C2R5-7b、C2R5-11f（連同本輪自己的 3e），C2R5-10b 與 C2R5-6z 在各自的修裡重新對位；**我一開始漏了這件事**，是跑 `ANCHOR_CHECK=1` 才發現 5 個 anchor 數到 0。另有兩個舊 mutant 改了「指名的測試」（`C2R3-N3a`、`C2R5-10b`），原因見 §10.3。
- **和 brief 不一致的一處**：brief 寫 shard `1/4`–`4/4`；gate script 的 shard 從 0 編號，`MUT_SHARD=4/4` 會被拒絕（k 必須小於 n），所以跑的是 `0/4`–`3/4`，log 叫 `mutate_p4_health.shard{0,1,2,3}of4.log`，和 r5 一樣。

### 10.1 每一項

| finding | 改了什麼 | 紅（LOG6） | 綠（LOG6） | mutant |
|---|---|---|---|---|
| 2（code） | `frozen.check_tree`／`Frozen.check_exercise`：S0 的 `exercise/` 副本必須恰好是釘住的 commit 在 `tools/p4_health/exercise` 下有的檔（扣掉副本本來就不含的 `__pycache__`、`build*`），每個檔 `git hash-object --no-filters` 等於 `git ls-tree` 的 blob；不同的、commit 沒有的、副本缺的、連結、git 答不出，都是 `Refused`。`S0.run` 在 `compile_all` 之後呼叫（不論 compile 成不成功），`probe.py cmd_lab` 把 `Refused` 變成 `refused:` rc 2，那時什麼 lab 動作都還沒做。`ctrl_trial.gen(exercise)`／`trial(exercise=)`：S0 傳 `self.ex`。`probe.py` 的 `LAB_PATH_MODULES` 註解改成實話（逐項寫沒蓋到什麼、由什麼蓋） | `n2.cells.RED.log`（11 個測試：4 FAIL 是行為——trial 用了共用 tree 的 CPU 埠 510 而不是副本的 4242、編輯過的／多的／少的檔都沒被拒絕，`(None, True) != (2, False)`；5 ERROR 是 `check_exercise` 還不存在；2 個控制組綠） | `n2.cells.GREEN.log`、`n2.cells.full.GREEN.log`、`n2.collect.full.GREEN.log` | `C2R6-2a`–`2k`（11 個） |
| 3 | `lab._stop_on_signals`：run 層的 raiser 只觸發一次——先換成 noter（`pthread_sigmask` 擋住三個訊號再換，和各輪的一樣）再 raise；之後的停止只記進 `problems`（「further stop signal(s)…」）。`probe.main`：`SignalAbort` 是 rc 2、`stopped: … INCOMPLETE`，不是 Python 的 status 1 | `n3.collect.RED.log`（第二個停止跑出 run_lab 與 main；一階段的 noter 測試 ERROR）、`n3.cells.RED.log`（`SignalAbort` 跑出 `main`） | `n3.collect.GREEN.log`、`n3.cells.GREEN.log` | `C2R6-3a`–`3e` |
| 4 | **選的是「`_finish` 與 handler 還原放在同一個 `pthread_sigmask` 下」**（`LabRound._masked`），不是「還原之後重讀 `teardown_signal`」。理由：窗口整個關掉，不用另外推理重讀之後的縫；停止會被送到 run 層的 handler（它結束整個 run），而不是被併進一份已經定稿的紀錄裡；探測器沒有 thread（`tools/p4_health` 沒有 `import threading`），擋主 thread 就是擋整個行程〔**這個前提只對 `tools/p4_health` 自己的碼成立，對行程不成立**：S0 的 ValueSet trial 在行程內跑 gRPC，結束後 thread 還在；r6 審查 finding 1，第 7 輪修，§11 項目 1〕。`lab.take_unrecorded`：`_finish` 沒跑過（`seconds` 仍是 `None`）的紀錄標為不完整並加一條 problem | `n4.collect.RED.log`（`2 != 1 : B was claimed over the stop`；`True is not false`） | `n4.collect.GREEN.log`、`n4.cells.GREEN.log` | `C2R6-4a`–`4e` |
| 5 | `report.write_json_atomic`（暫存檔、`fsync`、`os.replace`，失敗時刪暫存檔）；`report.dump` 用它。`run_lab` 先寫 `observations.json`、**最後**才寫 `health.json`。`probe.main` 的 catch-all：把已經在的 `health.json` 改名為 `health.json.not-a-verdict`（改名失敗也在訊息裡說），訊息以 `ERROR:` 開頭，不再是 `refused:`；漏出 `run_lab` 的 `SignalAbort` 同樣處理 | `n5.collect.RED.log`（5 個測試全紅：`['health.json'] != []`、`0 != 2`〔寫入沒經過 `os.replace`〕等） | `n5.collect.GREEN.log`、`n5.cells.GREEN.log` | `C2R6-5a`–`5f` |
| 6 | `sum_p4_health_gate_shards.sh [--commit <sha>] <log>…`：GATE 那一行印 `commit`、`tree`、`subject sha`；logs 的 commit 不是 checkout 的 HEAD（有 `--commit` 時是那個 commit）、tools/p4_health 的 tree 不是那個 commit 的 tree、git 答不出 HEAD、`--commit` 不是 commit、沒給值、不認得的選項，都是 `NOT THE GATE`。checkout 是 script 自己的 `../..`，或 `$P4_HEALTH_SUM_REPO`。**subject sha 是工作檔的雜湊，commit 並不決定它，所以只在 logs 之間比、並印出來**，沒有和 checkout 比。`mutate_p4_health.sh`：`+UNCOMMITTED` 的 pathspec 變成 `WATCHED` 陣列，加上 gate 自己的三支 script、`tools/p4_exercise`、`p4_proxy/mininet/grpc_ports.py` | `n67.gatescripts.RED.log`（68 個檢查，22 個紅） | `n67.gatescripts.GREEN.log`（68，0 failed） | `C2R6-6a`–`6m`（13 個） |
| 7 | 那個不可能失敗的 `(( MUTATIONS == SELECTED ))` **拿掉了**，換成一段註解指出真正的保險是加總 script 的份額檢查；**沒有為它寫 mutant**（沒有東西可以 mutate）。`GATES_SUM`：`gates_sum()` 對每個檔走 stdin（`sha256sum < "$f"`，輸出裡沒有路徑）再雜湊；也印在 header（`gates sum  :`），所以可以跨 log 比，並被測 | 同 finding 6 的紅（其中 4 個檢查是 finding 7 的） | 同上 | `C2R6-7a`–`7d`（4 個） |
| 8 | FakeController 的「s2 不是 primary」標為**假設**（真的 controller 會記 `set_pipeline_ok: False` 加 `set_pipeline_error`，`controller_ext.py:150-156`），註解、docstring 都改；NIT 12 的啟動測試的 docstring 寫明直譯器是 `sys.executable`，不是 B 用的 p4dev 直譯器（`round_b.py:119`） | 沒有——只改註解與 docstring | `n2.collect.full.GREEN.log` 之後的整份綠（最後的檢查） | 沒有 mutant（文字） |
| 10 | `cells/table.py` 的 `as_set`：t1 與 M1、M2、C1 比的是 `as_set(…)`，所以 set／tuple 變成 list 之後仍等。來回測試：`run_lab` → `observations.json` → `probe.py judge`，同樣的標題、rc、每一格的 verdict／reason／delta、rollup；三種 run：完整、看過紅（PROBE-BROKEN）、被停止（INCOMPLETE） | `n10.collect.RED.log`（3 個 ERROR：`TypeError: unhashable type: 'list'`，r5 審查寫的那一個） | `n10.collect.GREEN.log`、`n10.cells.GREEN.log` | `C2R6-10a`–`10e` |
| 釘 HEAD 的 NIT | `probe.py cmd_lab` 在載入模組之前先問一次 HEAD（答不出就 rc 2），乾淨檢查之後再問一次，不同就 `refused: HEAD moved…`；凍結的 git 把「HEAD 是什麼」答成那個 sha，不再自己問。`repo_identity(head=frozen.head)` 原來就用凍結的 sha | `npin.cells.RED.log`（4 個；**r6 原來寫的四句有三句和 log 不符，r6 審查 finding 3 更正**：①「一個 commit 在釘住之後落下」——舊 code **其實拒絕了它**，用的是凍結的訊息，不是 `HEAD moved`（`npin.cells.RED.log:32`），所以這個測試在舊 code 只靠訊息紅；②「`frozen.head` 是後來的 HEAD」——hook 在舊 code 根本沒觸發，紅的是測試自己的前提 「HEAD did move」（`:40-42`）；③「釘住不是第一個 git 呼叫」——**這一個是行為上的紅**（`:52`）；④「HEAD 答不出沒被拒絕」——紅只顯示凍結在乾淨檢查**之後**才被走到（`:22`），不是「沒被拒絕」） | `npin.cells.GREEN.log`、`npin.collect.GREEN.log` | `C2R6-pin-a`–`pin-d`（4 個）；**pin-b 在 r6 只靠訊息 `assertIn("HEAD moved")` 抓到**（commit 落在 `frames.py`，凍結本來就會拒絕它，r6 審查 finding 3），第 7 輪把那個測試的 commit 移到 `lab.py` 後由行為斷言抓到（§11 項目 2） |

mutant 的部分跑（`ONLY_LABEL_PREFIX=…`，**不是 gate**）：`mutate_p4_health.partial_C2R6-{2,3,4,5,5b,10,pin,6,7}.log`，各自 0 存活；`partial_C2R6-5` 一開始有 1 個存活（5b 的預期測試名寫錯，WRONG TEST），改名後 `partial_C2R6-5b` 抓到。另有 `partial_C2R3-N3a`、`partial_C2R5-10b`（§10.3 的兩個修）與一批舊前綴的診斷跑（`partial_C2R3-N3`、`C2R4-F4`、`C2R4-F8`、`R2-m4a`、`C2R5-2`、`C2R5-7`、`C2R5-5`），都 0 存活。

### 10.2 沒辦法確定性測的，以及沒做的

- **finding 4 的窗口本身**：測試從 `_finish` 裡的 hook 在「讀完 `teardown_signal` 之後」送停止，那是窗口裡的一個確定的點；任意位元碼上落下的停止沒有取樣。`pthread_sigmask` 是否真的擋住由 mutant `4b`（遮罩不擋任何訊號）與 `4c`（遮罩不放開）承擔。
- **finding 4 的 NIT 殘餘**：A 的第一個停止落在 body 結束與 `_handlers(False)` 的換 handler 之間，仍然在 `finally` 裡 raise、略過 teardown（走 `recover.sh` 安全失敗）；現在那份紀錄標為不完整（有測試）。另外**讀碼得來、沒有測**：這樣跑出 `run()` 的那一輪，body 的 raiser 已經換成該輪的 noter 且沒有還原，直到 `run_lab` 的 `finally` 還原原來的 handler；那之間的停止被 noter 記下就丟了。
- **finding 3**：「停止落在 run 層 handler 安裝與 `try:` 之間」用一個從 `cmd_lab` 丟出 `SignalAbort` 的 double 測 `main()`，不是真的在那一刻送訊號。
- **finding 5**：沒有重現真的磁碟滿；`OSError(ENOSPC)` 是注入在 `observations.json` 的 `open` 與 `os.replace`、以及 `run_lab` 最後的 log 呼叫。
- **finding 2**：「乾淨檢查之後的編輯」是在 git 的 `status` 呼叫之後的 hook 裡做的；真的時間差沒取樣。
- **釘 HEAD 的 NIT**：「先於 `load_lab_path`」沒有被任何測試分辨（`load_lab_path` 不問 git）；乾淨檢查之後的再問一次擋住兩者之間的 commit，這一點有測。
- **finding 6**：sum script 不拿 subject sha 和 checkout 比（見上）。
- **finding 8**：沒有測試也沒有 mutant。`#5` 的偵測器只算 `sys.modules` 裡以 `p4_health` 開頭的名字、看不到用路徑 exec 的檔（r5 審查 #8 的第三點）仍是這樣——它的缺口由 finding 2 的檢查補，不是偵測器。
- **沒做的**：r5 審查 #2 提到的可選項（S0 結束時審一次 `sys.modules`）；#6 的「A 的每一步例外只進 `A/problems.json`、不進 health.json 的 `problems`」（§6 步驟 5 仍是唯一的防線）；finding 1 的 ndt 端修法（在 ndt，不在這個分支）；`repo_untracked` 的決定（Adam）。

### 10.3 gate 與最後的檢查（在 `b09cd060`，LOG6）

- **mutation gate：450 個突變（397＋53），0 存活**，4 份 shard 各自有基線、負對照、byte-identical 與之後的檢查，全綠、`rc=0`（`mutate_p4_health.shard{0,1,2,3}of4.log`，113／113／112／112 個，「caught」行同數；四份都沒有 SURVIVED、WRONG TEST、HUNG、NO-SUITE、REFUSED、ENOSPC、Errno 28 的行）。四份第 1 行都是 `commit b09cd060…`，HEAD／tree／subject sha 行相同（`4acc71ea…`、`00baee280a968776`），header 的 `gates sum` 都是 `4851d9607830aed5`（第 6 輪起這個數是內容的雜湊，跨 log 可以比）。
  - **加起來的那一行**（`LOG/r6/GATE.log`，`sum_p4_health_gate_shards.sh --commit b09cd060…`）：`GATE: 450 mutations, 0 survived, shards 4/4 ok, commit b09cd0600a0f44a8aa6a1d00989371af999d45ec, tree 4acc71ea869582232dca9c1d8a3f225e86d7c95b, subject sha 00baee280a968776`。跑加總的時候 HEAD 就是 `b09cd060`；文件 commit 在它之後，所以之後要再跑這支 script 得帶 `--commit b09cd060…`，不帶的話它會拒絕（這是 finding 6 要的行為；`GATE.at_doc_head_without_commit.log`）。
  - **這一次 gate 之前還跑了兩次，結果都不是 gate**，各留了 log：
    1. 在 `520e6034`，shard 0 跑到第 90 個左右我自己停掉（`mutate_p4_health.aborted_520e6034_shard0of4.log`，最後一行寫 `rc=killed by me`）：`C2R3-N3a`（git 答不出 `status` 當成乾淨）存活。原因是 finding 的釘 HEAD 讓 git 壞掉的情況在 `rev-parse` 就被拒絕，舊測試 `test_a_git_that_cannot_answer_is_refused_before_s0` 再也走不到 `status` 那一行；新增 `test_a_git_status_that_cannot_answer_is_refused_before_s0`（只讓 `status` 失敗），mutant 改指它（`c82a9f49`）。
    2. 在 `c82a9f49`，四份 shard 跑完（`mutate_p4_health.run1_c82a9f49.shard*of4.log`，`GATE.run1_c82a9f49.log`＝`NOT THE GATE`）：shard 0 有 1 個存活 `C2R5-10b`（WRONG TEST，紅的是另一個測試）。原因是 finding 4 的 mask 之後，「`_finish` 在還原之後」與「在還原之前」對一個落在還原之後的停止沒有差別，原來指名的測試不再分辨它；順序現在只在還原裡丟例外時看得出，mutant 改指 `test_an_exception_after_a_rounds_record_is_final_keeps_that_rounds_record`（`b09cd060`）。shard 1–3 在那一次是 `rc=0`。
    - 這兩個存活都是我自己的修造成的測試漏洞，在 gate 才發現，不是在各項的部分跑裡發現（部分跑只跑新 mutant 的前綴）；之後改在重跑 gate 之前，先把可能受影響的舊 mutant 前綴（`C2R3-N3`、`C2R4-F4`、`C2R4-F8`、`R2-m4a`、`C2R5-2`、`C2R5-5`、`C2R5-7`）部分跑過一遍（都 0 存活）。
  - **gate 的行程被停住過兩次；r6 原來只寫了一次，而且時間與原因都不對**（r6 審查 finding 2）。事實：r5 留下的一支磁碟看門狗（它在可用空間低時對 shard 行程送 SIGSTOP、回升時送 SIGCONT，用指令形狀比對行程；程式碼已不在）在 r6 的最後一次 gate 期間還活著，停了 gate 的 shard：
    - **shard 3**：`LOG/r5/disk_watchdog.log:25` 記 `19:39:23 free 1452 MB: STOPPED shards`，沒有對應的 CONTINUED；free 的取樣從 19:41:17 起不動，到 19:58:19 才又動（`LOG/r6/disk_watchdog.log:1987-2021`）；我在 20:00 送 SIGCONT（同檔 2025 行的註記）。**原來寫的「19:43 到 20:00、17 分鐘、原因不明」更正為：19:39:23 起到約 20:00，約 21 分鐘，原因是 r5 的看門狗。**
    - **shard 1**：`LOG/r5/disk_watchdog.log:23-24` 記 `17:31:53 STOPPED`、`17:32:53 CONTINUED`，一分鐘；free 取樣在 17:32:05–17:32:35 不動（`LOG/r6/disk_watchdog.log:1725-1726`）。**原來沒寫。**
    - 06:29:38–06:30:39（`LOG/r5/disk_watchdog.log:21-22`）在第一次 gate 中止之後、run1 開始之前，沒有任何 shard 在跑，兩次 gate 都沒碰到。
    - **為什麼這些停止沒有改變任何結果**：每一個 mutant 的紅綠由 `timeout 300` 內的一次套件執行決定，停住的套件只會變成 HUNG（計為存活）；沒有任何一份 shard 有 HUNG 行，外層 `timeout 21600` 也沒有走完（shard 3 共 1 小時 51 分）。更直接的證據是 **run1（`c82a9f49`）的對照**：它跑的是同樣的 450 個 mutant、同一棵 tools 與 subject sha、同樣的套件（run1 shard*:7-8；`c82a9f49` → `b09cd060` 只改了 `C2R5-10b` 指名的測試），**從頭到尾沒有被停過**（唯一的 STOP 事件是 06:29、17:31、19:39，run1 在 06:50–13:09 跑完）；最後的 shard 0、1、3 與 run1 逐項相同（指名的測試與完整的紅清單），shard 2 的每一行「caught by」相同；唯一的差別是 `C2R5-10b`（run1 是 WRONG TEST，最後一次由改指的測試抓到，是預期的）。
    - **各次停止時在跑的 mutant（推算，不是記錄；shard log 沒有逐個 mutant 的時間，只能用看門狗的 START／END 與每輪約 48 秒估）**：shard 1 約第 89 輪（`C2R5-9a`、`C2R5-5b`，容差 5% 時 `C2R5-2f` 到 `C2R5-11f`）；shard 3 約 #14–#16（`C5`、`B4`、`B8`）。基線在 shard 的第一輪、負對照與之後的檢查在最後兩輪，都在停止之外。
    - 沒有解釋的一件事：最後的 shard 0 花了 2 小時 22 分，run1 的同樣 113 個花 1 小時 37 分（`LOG/r6/disk_watchdog.log:424`、`:619`、`:1197`、`:1482`）；沒有記錄到任何停止，它的每一項仍與 run1 相同。
    - **gate script 沒有逐個 mutant 的時間戳**，所以以上的對位是估計；若要確定，最小的重跑是在 `b09cd060` 對 `C2R5-9a`、`C2R5-5b`、`C2R5-5f`、`C1.`、`C5.`、`B4.`、`B8.` 各做一次部分跑（各約 3 分鐘）。這一輪沒有做，因為 run1 的對照已經夠。
  - 分段的部分跑（`ONLY_LABEL_PREFIX=…`，不是 gate）：見 §10.1 與 `LOG/r6/mutate_p4_health.partial_*.log`。
- 最後的檢查（`p4_proxy/venv/bin/python`；都在文件 commit 之後的 HEAD 重跑過一次，log 第 1 行是那個 commit）：
  - `check_gate_anchors.py HEAD`：133/133 cells ok，`mutate_p4_health.sh` ok(420)（`check_gate_anchors.HEAD.log`）。**為什麼是 420 而不是 450**（r6 審查「數字對不起來」）：表有 450 列，但有 26 個 anchor 被不只一列用到（共 31 列是重複的，例如同一行被好幾個 mutant 以不同方式改），而 `check_gate_anchors` 數的是**不同的** `(檔, anchor)`（它自己的說明：「`ok(n)` counts DISTINCT anchors」）；450 列 → 419 個不同的 anchor，再加負對照的 anchor（`def g1_holds(g1):`，`anchor_count` 那一路）＝420。我用 `check_gate_anchors.extract` 的輸出和 gate 表逐一比對（表在 `b518b9fb`）：表裡的 anchor 沒有一個沒被檢查器讀到、檢查器也沒有讀到表裡沒有的 anchor（0 problems、0 delegates）。**沒有被藏起來的缺口**，檢查器不用改；每一列的 anchor 是否恰好一個，由 gate 執行時自己每一列數一次（`ANCHOR IS NOT UNIQUE` 就是存活）。
  - `check_test_tmpdirs.py`：416 個檔，0 個固定暫存路徑（`check_test_tmpdirs.log`）；
  - collect 174 個 OK（162＋12）、cells 170 個 OK（153＋17）、`test_p4_health_recover.sh` 163 checks 0 failed（沒變）、`test_p4_health_gate_scripts.sh` 68 checks 0 failed（43＋25）（`test_collect.log`、`test_cells.log`、`test_recover.log`、`test_gate_scripts.log`）。

### 10.4 磁碟

- 起跑時 `df -m /` 是 2100 MB（低於平常的 2500 下限），整個過程由別的專案在用磁碟；我沒有碰別人的檔，自己的突變複本與暫存目錄都由 gate 的 `trap` 清掉（我自己停掉那一次的 `/tmp/p4-health-mutate-*` 手動刪了）。
- 看門狗（`LOG/r6/disk_watchdog.log`）每 30 秒寫一行 `date`、`free_mb`，共 2152 筆，第 1 行 `start`、最後一行 `end 2026-10-09 21:18:09 free_mb=1375`。**最低 1042 MB（20:10:50，在最後那次 gate 的 shard 3 裡）**，最高 2624 MB。
- 每一份 shard 開跑前先查 `df`：低於 1800 就等（每 5 分鐘一次，記在看門狗 log）。**實際等過一次**：第二次 gate 的 shard 0 結束後（15:35），`free` 在 1695–1746 MB，等了 9 次（15:35–16:15，約 45 分鐘），到 16:20 回到 2563 MB 才開 shard 1。其餘的開跑點 free 在 1843–2616 MB。
- **跑的當中不會停**（brief 只要求開跑前查）：最後一次 gate 裡 free 曾低到 1042 MB，四份 shard 沒有 ENOSPC、Errno 28、No space、HUNG、NO-SUITE、WRONG TEST、SURVIVED 的行。機制上低磁碟的方向是假 caught，不是漏跑（§8.5）；這個 gate 的結果沒有因此受影響的跡象，但「沒有任何一個 caught 是 ENOSPC 造成的」我沒有逐個證明。**r6 審查 finding 2 補：上面「沒有 ENOSPC、Errno 28 的行」那個檢查看不到測試自己的錯誤**——shard log 只留紅測試的名字（`mutate_p4_health.sh` 的 red_tests），不留訊息。真正排除「低磁碟造成假 caught」的是 run1 的對照（§10.3）：run1 的磁碟是 2142–2291 MB，最後的 shard 3 在 1042–1506 MB 下跑，兩者逐項相同。
- 第一次 live 的下限仍是 > 2500 MB（§6）；今天（10-09）整天都低於它，所以今天不能開跑。

## 11. 第 7 輪（r6 審查的程式項目與文字）

- **基底**：`b518b9fb`（r6 審查的對象；code 在 `b09cd060`，`tools/p4_health` 的 tree＝`4acc71ea`）。**code 與測試的 head：`7a7a2577`**。`tools/p4_health` 的最後一次改動是 `af2b3490`（tree＝`349e5ab0a1fa635ddde98e046447e00607f3b84d`，之後沒有變）；`ae753c29`（項目 4）、`01ba2a41`、`7a7a2577` 只動測試。`ae753c29` 是**第一次** r7 gate 的 head，那次停在 shard 3，見 §11.7；之後的 gate 在 `7a7a2577`，四份 shard 都在 nslab 的 VM 上跑（§11.3）。這份文件的 commit 在它們之後。
- **LOG7** 指 `LOG/r7/`；**NS** 指 `scratch/overnight-2026-09-05/logs/gates-0910/nslab-a13-1010/`（nslab 上跑的 gate 與它的檢查，§11.3、§11.8）。格式同 §10 開頭：每份 log 第 1 行 `commit <sha>`、最後一行 `rc=`。
  - **例外**（r7 審查 finding 8 更正；這裡原來寫「只有兩份」，是錯的）：
    - 只記錄、第 1 行不是 `commit`：`disk_watchdog.log`、`disk_watchdog.r7b.log`（第 1 行 `start`）、`v7_polls.log`、`gate_disk_polls.log`（LOG7 與 `first_gate_ae753c29/` 各一份；等待的紀錄，每行自己有時間）、`gate-chain.out`（第 1 行就是 `rc=`）、`r7b/partials.log`（只有 `partial … rc=` 行，見 §11.8 項 5）；
    - 有 `commit` 行、沒有 `rc=`：`r7b/repro.4c.collect.log`（被 `KeyboardInterrupt` 打斷，最後一行是它，§11.7）。
  - `n1.*.RED.log` 在 `aa526f97` 跑（測試已 commit、`tools/` 是 `b518b9fb` 的，`tracked-dirty=0`）；`dirty-pre-commit/` 是同一批紅的第一次跑（測試還沒 commit，`tracked-dirty=2`），**被取代，留著當紀錄**。
  - `n1.collect.RED2.log`、`n3.cells.RED2.log`、`n4.grpc_port_block.RED.log` 是在 **`git archive` 出來的暫存目錄**跑的（log 第 2 行寫 cwd 和「old tools/, new tests」）；原因：測試 commit 之後又有一個很小的測試修正 commit，要在「舊 code＋新測試」的狀態重跑，而 worktree 的 `tools/` 已經是修過的。
  - 這一輪起的輔助行程都只寫 log、不送訊號，列在 §11.4。
- 順序：每一項都是**先 commit 測試、再 commit 修**（修的 commit 同時帶 mutant）；`C2R7-` 共 23 個（`1a`–`1r` 18 個、`3a`–`3e` 5 個），表現在 473 個＝450＋23。項目 2 只改測試，項目 4 只改測試（allowlist）。

### 11.1 commit

| commit | 內容 |
|---|---|
| `aa526f97` | 項目 1 的測試：collect 9 個（8 個紅、1 個對照）、cells 6 個 |
| `4658e981` | 項目 1 的測試修正（迴圈測試在兩次 `run_lab` 之間要清掉 `frozen/`） |
| `dcca2505` | 項目 1 的修與 `C2R7-1a`–`1r` |
| `611630e3` | 項目 2：釘 HEAD 的測試的 commit 移到 `lab.py` |
| `004f204f` | 項目 3 的測試（3 個） |
| `c8c2cef8` | 項目 3 的測試補強（編輯過的 `gen_runtime.py` 不得被**執行**，不只是不被交給 `expectations`）。**只對測試走的路徑成立**（convert → `run_lab`，`n3.cells.RED2.log:6`）：完整的 S0 裡，`ctrl_trial` 在 `convert.py` 之後、`run_lab` 的再驗之前就執行那份副本（`s0.py:726`、`:731`；`ctrl_trial.py:37-43`），安全失敗，見 §6 前提 3 |
| `af2b3490` | 項目 3 的修與 `C2R7-3a`–`3e` |
| `ae753c29` | 項目 4：`test_grpc_port_block.py` 的 allowlist 加一行 |
| `01ba2a41` | gate 修（§11.7）：collect 的每個測試結束時把 signal mask 放回、pending 的停止送到不做事的 handler |
| `7a7a2577` | gate 修（§11.7）：cells 的 `TestS0Cut2Checks` 每個測試開始與結束都清掉 signal mask |

### 11.2 每一項

| 項目（r6 審查） | 改了什麼 | 紅（LOG7） | 綠（LOG7） | mutant |
|---|---|---|---|---|
| **1**（finding 1，code） | **設計是 brief 決定的，照做。** (a) `s0.stops_held()`：用 `signal.pthread_sigmask(SIG_BLOCK, SIGTERM／SIGINT／SIGHUP)` 把 S0 的 ValueSet trial（`vs_trial`，行程內跑 gRPC）整個包起來，`finally` 還原先前的 mask（trial 丟例外也還原）；gRPC 在 trial 裡起的 thread 繼承這個 block。(b) `lab.stop_signal_threads_refusal()`：`run_lab` 在第一個 claim 之前讀 `/proc/self/task` 裡**除了呼叫者以外**每個 thread 的 `SigBlk`，任何一個沒有三個訊號全擋、讀不到某個 thread 的 status、或 `/proc/self/task` 讀不了，都是 `refused: …` 加進 `problems`，`run_lab` 走原來的「什麼都沒碰」路徑（INCOMPLETE、rc 2、沒有 claim、沒有 LAB_STATE），訊息點出 tid 和缺的訊號。`lab_round.py` 的註解與 §6／§10.1 的「探測器沒有 thread」更正。**(a) 的一個必然後果，brief 沒寫**：signal mask 跨 fork／exec 繼承，所以 trial 起的拋棄式 bmv2 如果沿用 block，`Throwaway.stop()` 的 `terminate()`（SIGTERM）就殺不掉它，要等 3 秒 timeout 再 `kill()`；所以 `throwaway._die_with_parent`（`preexec_fn`）在 exec 之前把三個訊號 `SIG_UNBLOCK`。 | `n1.collect.RED.log`（`aa526f97`；3 FAIL 是行為：延伸 finish-hook 測試，多一個沒擋 SIGTERM／SIGHUP／SIGINT 的 thread，舊 code 在 A 之後**又 claim 了 B**〔兩個 `ndt claim`〕，`n1.collect.RED2.log` 在 `4658e981`；5 ERROR 是 `lab.PROC_TASK` 還不存在，**只有介面的紅**）、`n1.cells.RED.log`（6 FAIL，全是行為：trial 沒擋訊號、gRPC 類的 thread 不擋、trial 內沒有擋住（`n1.cells.RED.log:172-178`，丟例外的那個測試在 trial 裡看不到 block；「丟例外後沒還原」本身不是這個紅證明的，由 mutant `C2R7-1o` 承擔，`NS/logs/mutate_p4_health.shard0of4.nslab.log:713-717`）、停止在 trial 中途殺掉行程、拋棄式 switch 繼承 block） | `n1.collect.GREEN.log`（183）、`n1.cells.GREEN.log`（176）；python3.8 也綠（`final.*.py38.log`；gate 的直譯器是 nslab 的 3.12.3，3.8 只是交叉檢查，§11.3） | `C2R7-1a`–`1r`（18 個） |
| **2**（finding 3，測試） | `test_a_commit_that_lands_after_head_was_pinned_and_before_the_clean_check_is_refused` 的 commit 從 `frames.py`（凍結的 7 個檔之一，沒有重查凍結也會拒絕）移到 `lab.py`（已載入、不在凍結裡）；斷言順序是 `(rc, frozen) == (2, None)` 在前、訊息在後，訊息斷言保留 | 沒有紅 log 可以給——測試改的是「抓不抓得到 mutant」。**證據**：`n2.pinb_by_hand.RED.log`（`C2R6-pin-b` 手動套在暫存複本上：`(None, <Frozen>) != (2, None)`，行為斷言，S0 被走到、`frozen` 不是 None）；`mutate_p4_health.partial_C2R6-pin-b.log`（gate 的部分跑，抓到） | `n2.cells.GREEN.log` | 既有的 `C2R6-pin-b` |
| **3**（finding 4，code） | `run_lab` 在 `load_model` 之前，對 `frozen.head` 再呼叫一次 `frozen.check_exercise(<run>/exercise)`（沒有 `head` 的離線 Frozen 不查，與 `S0.check_exercise_copy` 同一個條件）。**位置在 claim 之前**（`run_lab` 一開始、`_rounds` 之前），所以拒絕走的是這一階段原有的路徑：`the run could not be set up: Refused: …` → INCOMPLETE、rc 2、health.json 的 `problems` 點出檔名與 commit、沒有 claim。（claim 之後那條路徑——正常 teardown——這一項用不到。）`frozen.py`、`probe.py` 的註解同步 | `n3.cells.RED.log`（`004f204f`，2 FAIL，行為：舊 code `expectations` 拿到被編輯過的模型）、`n3.cells.RED2.log`（`c8c2cef8`：2 FAIL，`the edited gen_runtime.py was executed`） | `n3.cells.GREEN.log`（179）、`n3.collect.GREEN.log`（183）；對照組（沒被改的副本）綠 | `C2R7-3a`–`3e`（5 個） |
| **4**（CI） | `tests/python/test_grpc_port_block.py`：`ALLOWED_LINES_NAMING_THE_OLD_BLOCK` 加 `(tools/p4_health/controller_ext.py, "TUTORIALS_PORT_BASE = 50050")`，理由 `_HEALTH_CONTROLLER`（p4lang tutorials 的慣例，controller trial 的 controller 照它撥號，再由 adapter 或 trial 自己的 connect 表改寫；`run_external_controller.py:41` 的同一行早已 allowlist） | `n4.grpc_port_block.RED.log`（`b09cd060` 的 `git archive`：32 個測試 1 FAIL，`NoLiveDocumentStillNamesTheOldPortBlock.test_no_live_doc_or_tool_names_the_old_block` 點名 `tools/p4_health/controller_ext.py:42`） | `n4.grpc_port_block.GREEN.log`（32 個 OK；allowlist 的過期檢查、拼字檢查、正對照三個一併綠） | 沒有（這一項本身就是測試；沒有東西可以 mutate，紅就是拿掉那一行） |

- **項目 1 的觀察**（`obs.grpc_threads.log`，一個 channel 連到 `127.0.0.1:1`，沒有 switch、沒有 lab）：**不擋的話，gRPC 在行程裡留下 thread（第一次跑 16 個：`grpc_global_timer`、`event_engine`×14、`lifeguard`；第二次也是這 16 個 gRPC thread 加一個 python thread，不是 3 個：`obs.grpc_threads.log:64-82`），全部不擋任何訊號；先擋的話它們全部繼承 `SigBlk 0x4003`。** 所以 r6 審查 finding 1 的疑慮是真的，r6 寫的「探測器沒有 thread」不成立，不是只有「沒被證明」。
- **項目 1 的「確定性」**：舊 code 的 hook 測試原本是競爭——有 sleeping 的 thread 時，主 thread 常常在那個 thread 被排程跑 C 層 handler 之前就走完 `_finish` 與還原（我第一次寫的測試在舊 code 上 claim 只有 1 次〔B 沒被 claim〕，不紅；那一次沒有留 log）。現在 hook 在送訊號之後用 `signal.set_wakeup_fd` 等 C 層 handler 真的跑了才繼續（最多 0.5 秒；訊號被擋、沒有 handler 跑的對照組等滿 0.5 秒），所以舊 code 上穩定紅。
- **這一輪的行為變化（要知道）**：S0 的 ValueSet trial 期間（每個 bmv2 約幾十秒），SIGTERM／SIGINT／SIGHUP 不再立刻殺行程，要等到 trial 結束、mask 放回才送達（再用預設動作結束行程，測試 `…ends_an_unhandled_process_only_after_the_trial_is_over`）；trial 本身卡住時，只有 SIGKILL 有用。拋棄式 bmv2 有 `prctl(PDEATHSIG)`，所以不會留下。

### 11.3 gate 與最後的檢查

- **mutation gate：473 個突變，0 存活；四份 shard 都在 nslab 的 VM 上跑（登記列 A-13，`NSLAB-USAGE-RULES.md`），code 是 `7a7a2577`。**
  - **加起來的那一行**（`NS/logs/GATE.nslab.log:3`，逐字；`:4` 是 `rc=0`）：
    `GATE: 473 mutations, 0 survived, shards 4/4 ok, commit 7a7a257734eee3cd8966c783f77101b3cd56d863, tree 349e5ab0a1fa635ddde98e046447e00607f3b84d, subject sha d2a38f99dbaaf3b3`
    指令（`GATE.nslab.log:2`）：`sum_p4_health_gate_shards.sh --commit 7a7a2577… <四份 nslab shard log>`。
  - **四份 shard 的 header 相同**（`NS/logs/mutate_p4_health.shard{0,1,2,3}of4.nslab.log`）：`:1` commit `7a7a2577…`、`:2` `tracked-dirty=0`、`:5` `/usr/bin/python3.12 (3.12.3)`、`:7` HEAD `7a7a2577…`、`:8` tree `349e5ab0…`（沒有 `+UNCOMMITTED`）、`:9` subject sha `d2a38f99dbaaf3b3`、`:10` gates sum `e4082a69a7af6149`。份量 119／118／118／118（shard 0 在 `:740-743`，shard 1–3 在 `:734-737`），各自 `0 survived`、`rc=0`。shard 一份一份跑（`NS/logs/driver.log`）。
  - **環境**：nslab 的 guest（Ubuntu 24.04.4）、python 3.12.3、locale `C.UTF-8`（`NS/checks/subject-sha-by-locale.laptop.txt:5`：driver 沒設 `LC_ALL`，guest 的 `LANG=C.UTF-8`；`NS/README.md`）。這個 gate 的 shard 全是同一台機器、同一個直譯器、同一個 locale，所以 subject sha 一致。
  - **筆電的 shard 0 只是交叉檢查，不是 gate 的一部分**（`LOG/r7/mutate_p4_health.shard0of4.log`，`7a7a2577`，python **3.8.20**，locale en_US.UTF-8，13:37:19–15:21:38，`119 mutations, 0 survived`，`rc=0`）：和 nslab 的 shard 0 逐塊比對，**121／121 個塊的 verdict 與「也紅」的測試集合都相同**（`NS/checks/compare.shard0.laptop-vs-nslab.txt:2`）。同一份比對只報一個差異：header 的 subject sha（筆電 `4651b09cb90a1387`，nslab `d2a38f99dbaaf3b3`，`:3-4`、`:8`）。為什麼不同見 §11.8 項 3：這是 locale 造成的，檔案同、bytes 同。**所以筆電的那份不能和 nslab 的三份一起加總**（加總 script 會因 subject sha 不同而拒絕）。
  - 另一個交叉檢查：第一次 gate 的 shard 1、2（`67af72b3`，3.8.20）對 nslab 的 shard 1、2，每塊（120／120）相同；header 只有 HEAD 與 subject sha 不同（`NS/checks/compare.shard{1,2}.firstgate-vs-nslab.txt`）。那兩份的測試在 `01ba2a41`／`7a7a2577` 之前，所以只是交叉檢查。
  - **兩次較早的嘗試不算 gate**：第一次（head `ae753c29`）shard 0–2 `rc=0`，shard 3 在 `C2R6-4c` 被 REFUSED（§11.7，`LOG/r7/first_gate_ae753c29/`）；第二次（`7a7a2577`）在筆電上只跑完 shard 0，之後磁碟 < 1700 MB（`gate_disk_polls.log`、`disk_watchdog.r7b.log`；筆電 15:21 起 Avail 1427 MB，降到 1298 MB），16:42 我在 driver 的等待迴圈裡（沒有 shard 在跑）用 pid 停了它，原因記在 `gate_disk_polls.log` 最後一行。剩下的 shard 1–3 與加總改在 nslab 重跑（shard 0 也重跑了一次，所以 gate 的四份全在 nslab）。
  - 這一輪早先「還沒有 GATE 那一行」的寫法與「py3.8 是 gate 用的直譯器」都過時了，已改（r7 審查 finding 1）。§11.7 的部分跑仍是診斷，不是 gate；`dev.quickmut_C2R7.log` 只跑指名的測試（`quickmut.py:30`），它把 `C2R7-1n` 記成 CAUGHT（`:16`），gate 的部分跑卻是 WRONG TEST（`partial_r7b_C2R7-1.first_01ba2a41.log:98`），所以它**不當證據**。
- **最後的檢查**（`p4_proxy/venv/bin/python`；log 第 1 行是文件 commit，`LOG/r7/final.*.log`）：
  - `check_gate_anchors.py HEAD`：133/133 cells ok，`mutate_p4_health.sh` **ok(438)**（`final.check_gate_anchors.log`）。438 的算法同 §10.3：473 列 → 437 個不同的 anchor，加負對照的 1 個；有 30 個 anchor 被不只一列用到（36 列重複）。
  - `check_test_tmpdirs.py`：416 個檔，0 個固定暫存路徑（`final.check_test_tmpdirs.log`）；
  - collect **183** 個 OK（174＋9）、cells **179** 個 OK（170＋9）、`test_p4_health_recover.sh` 163 checks（沒變）、`test_p4_health_gate_scripts.sh` 68 checks（沒變；gate script 的表加了列，這份測試不數列）、`test_grpc_port_block.py` **32** 個 OK（`final.collect.log`、`final.cells.log`、`final.recover.log`、`final.gate_scripts.log`、`final.grpc_port_block.log`）；collect、cells 在 python3.8 也綠（`final.collect.py38.log`、`final.cells.py38.log`；gate 在 nslab 的 3.12.3 上跑，3.8 不是 gate 的直譯器，§11.3）。

### 11.4 磁碟與輔助行程

- **磁碟**：第一階段（V7 還沒結束）22:07–00:42 在 1177–1300 MB：大多在 1281–1300，只有 6 筆低於 1270，最低 1177（`disk_watchdog.log:37`）、最高 1300（`disk_watchdog.log`：309 筆取樣，加 `start` 與 `end` 各一行，`end` 在 `:311`，1287；原來寫「310 筆」把 `end` 算進去，區間也寫成了 1281–1300，與同一句的最低 1177 互相矛盾）。第二階段（`disk_watchdog.r7b.log`，10-10 10:0x 起）：10:57 起 1676–1679 MB，13:37 回到 1820 MB（orchestrator 移除 V7 worktree 與 Cut A scratch clone 後），shard 0 在 13:37:19 起跑（`gate_disk_polls.log`）；15:21 shard 0 結束時 1427 MB，降到 1298 MB；取樣最低 1264 MB、最高 1817 MB。都低於 §6 第一次 live 的 2500 MB 下限；今天不能開 live。
- **輔助行程**（都只寫 log、不送訊號）：
  - 第一階段：磁碟取樣器 `watchdog.sh`（pid 858158／858160）、`waitv7.sh`（943308／943310／943311）、`pipeline.sh`（960107／960109）、兩個 `until grep` 迴圈（960765／960949）、一個 Monitor：結束情形見上一版（取樣器用停止檔，其餘 `kill <pid>`）。
  - 第二階段：部分跑串接腳本 `partials.sh`／`partials2.sh`（pid 895241／895243 等，各自跑完自己結束）；磁碟取樣器 `watchdog.sh`（pid 2003882／2003884，停止檔，`end 2026-10-10 16:42:32`）；gate driver `gate_driver.sh`（pid 2003737／2003739，16:42 在等待迴圈裡用 `kill <pid>` 停掉；它啟動的 shard 0 已經正常結束）。
  - **結束時的 `ps -eo pid,etime,args` 檢查**：沒有 `gate_driver`、`watchdog.sh`、`mutate_p4_health`、`partials`、`pipeline` 的行（那一次的輸出沒有存檔；r7 審查 finding 6）。**補存的檢查**（事後 10-10 23:22，不是結束當下）：`NS/checks/ps.watchers.txt`——掃 `/proc`，argv 指名 watchdog／SIGCONT／gate driver 的行程 0 個；陽性對照（一個假的 `fake-watchdog.sh`）被找到 1 個，停掉後又是 0 個；
  - r5 的看門狗：`ps` 沒有它；這一輪沒有任何 STOP／CONT／kill 的看守。

### 11.5 還開著的

- **第一次 live 之前**（r6 審查「Before the first live run」）：磁碟下限 > 2500 MB（§6）；§6 對每個 session 的宣告與 helper tree 的檢查（r5 #1，ndt 那邊還開著）；Adam 的逐次授權；`repo_untracked` 的決定。項目 1 的 code 修好了；gate 的結果見 §11.3，r7 審查之後的紀錄與還開著的項目見 §11.8。
- **這一輪沒有做的**：
  - r6 審查建議的「真的跑一次離線 S0（拋棄式 switch）再數 `/proc/self/task`」：沒有跑——離線 S0 要起 bmv2，brief 的範圍是離線 code 與測試。取代它的是 `obs.grpc_threads.log`（只用 gRPC channel，觀察 gRPC 本身會留下什麼 thread）與「`run_lab` 在 claim 前一定查」；真正的 S0 之後 `run_lab` 看到的 thread 集合沒有觀察過。
  - r6 審查「我會跑的測試」第 4、5、7 項（claim 之後立刻 SIGTERM；重用的 run 目錄加 catch-all；gate 開始之後被改的測試檔）：沒有做，見 §11.6。
  - `ERROR:` 前綴的解析 NIT：只在 §11.6 記，沒有改。

### 11.6 §10.2 的補記（r6 審查 finding 1、3、5 的剩餘）

- **finding 1 修了之後的殘餘**：(1) thread 檢查是 `run_lab` 開頭的一個時間點；那之後才起的 thread 不在內（`tools/p4_health` 自己的碼沒有起 thread 的地方，但沒有機制擋它）。(2) 只看 Linux 的 `/proc/self/task/<tid>/status` 的 `SigBlk`，不看 `SigIgn`、handler 或 thread 之後有沒有解除 block；非 Linux 或 `/proc` 讀不了就是拒絕（有測試）。(3) 「呼叫者」用 `threading.get_native_id()`（Python 3.8 起）。(4) 訊息裡的 tid 只在檢查的那一刻有意義。(5) 這個檢查測的是**設計決定的前提**（沒有 thread 能收到停止）；它沒有證明停止之後的流程在每個位元碼位置都對，那一半仍是 §10.2 第一條的取樣限制。
- **finding 3 同類、較小**：`C2R6-5b` 把 `os.replace` 換成 `os.rename`——在 Linux 上做同一件事——只因為測試 patch 的是名字 `os.replace` 才抓到；`n5.collect.RED.log:60` 的 `0 != 2` 是同一種測試造成的紅（§10.1 已說）。這種 mutant 不證明行為。
- **finding 5（都是安全失敗，讀碼得來，沒有測）**：
  1. **`ndt claim` 之後、round 的 `try:` 之前的停止**（`lab_round.py:374-392`，包括 `_handlers(True)` 放開 mask 時送達的那一個）：停止從 `run()` 跑出去，claim 還在、沒有 teardown。這在 r6 之前就存在，安全失敗：`take_unrecorded` 把那份紀錄標為被切斷（`lab.py`），`recover.sh` 處理 `claim_expires` 為 null（`test_recover.log:134`、`:161`）。
  2. **`set_verdict_aside` 會改名 run 目錄裡「任何」`health.json`**（`probe.py` 的 `set_verdict_aside`）：如果 run 目錄被重用，catch-all 又在凍結拒絕之前觸發（例如 `load_lab_path` 的 import 錯誤），上一輪的 verdict 會被改名。需要 `P4_HEALTH_RUN_DIR` 被重用；§6 的命令每次產生新的目錄。
  3. **`ERROR:` 前綴與 gate 的解析**：`probe.py` 的 catch-all 印的行以 `ERROR:` 開頭，gate 的 `FAIL|ERROR: <name>` 解析（`mutate_p4_health.sh` 的 red_tests）把它讀成測試名字，在紅清單裡加一個假的「the」（r6 `shard1:500`、`:506`）。沒有任何指名的測試叫 `the`，所以沒有 verdict 改變。**沒有改**（brief：留成註記）。
  4. gate script 沒有逐個 mutant 的時間戳，所以停止的分析是估計（§10.3）。
  5. **看守**：r5 的磁碟看門狗（會對 shard 行程送 SIGSTOP）是 r6 最後一次 gate 被停的原因（§10.3）；這一輪沒有任何會送訊號的輔助行程，結束時用 `ps` 確認沒有任何一個留下（§11.4）。


### 11.7 第一次 r7 gate 停在 shard 3：原因與修

- **發生了什麼**：orchestrator 在 V7 結束之後跑了 `gate_driver.sh ae753c29`（四份 shard 一份一份跑；log 在 `LOG/r7/first_gate_ae753c29/`，log 第 1 行的 commit 是 `67af72b3`，即 `ae753c29` 加這份文件的第一版，`tools/` 與 `tests/` 與 `ae753c29` 相同）。shard 0、1、2 `rc=0`（119、118、118 個，0 存活）；**shard 3 在 09:59:12 `rc=2`**：`mutate_p4_health.shard3of4.log:638`「🔴 REFUSED: a suite did not run at all while measuring: C2R6-4c. the mask is never lifted. No verdict.」。`C2R6-4c` 在 r6 被抓到過。**這一次 gate 不算數**（shard 3 沒有 verdict，也沒有 GATE 那一行）。
- **原因**（讀的是 gate script 丟掉的套件輸出：在暫存複本套上 `C2R6-4c`，直接跑兩個套件，python3.8、`timeout 300`；`LOG/r7/r7b/repro.4c.collect.log`、`repro.4c.cells.log`，HEAD 是 `67af72b3`）：
  - cells 在 4c 下 `rc=0`（沒有測試抓到 4c；它的預期測試在 collect）。
  - **collect 不是掛住，是被一個 `KeyboardInterrupt` 打斷**，沒有印 `Ran N tests`，gate 把「沒有結果」當作 `NO-SUITE`，也就是 REFUSED（`red_tests` 的 `grep -qE '^Ran [0-9]+ tests?'`）。trace 在 log 末端：`test_p4_health_collect.py:3338, in test_a_running_thread_that_does_not_block_sigint_is_refused_too` → `:3260, in background_thread`（`old = signal.pthread_sigmask(signal.SIG_SETMASK, set(blocked))`）→ `KeyboardInterrupt`。
  - 機制：4c 讓每一輪結束後三個停止訊號**一直是擋住的**，所以前面的測試送出的訊號都留在 pending。我在 r7 加的 `background_thread` 為了讓新 thread 繼承某個 mask，用 `SETMASK` 把 SIGINT 解開（這個測試要的 mask 是 `{SIGTERM, SIGHUP}`）；pending 的 SIGINT 就在這一行送達，Python 預設的 SIGINT handler 丟 `KeyboardInterrupt`，unittest 不攔它，整個套件結束。r6 的測試沒有在一個會洩漏 mask 的 mutant 之後還改 mask，所以 r6 沒碰到。
  - orchestrator 的猜測對了一半：是 r7 新加的 thread 測試的 helper；但不是 `set_wakeup_fd` 的等待（它有 0.5 秒上限），也不是「跑不完」。
- **修一（`01ba2a41`，測試）**：`Sealed.setUp` 記下測試開始時的 mask，cleanup 把它放回，放回的當下 pending 的停止送到不做事的 handler（`_put_the_signal_mask_back`）。一個洩漏 mask 的 mutant 因此只影響會洩漏的那個測試。**4c 的預期測試不變**（`test_a_stop_from_a_hook_inside_finish_after_it_read_the_teardown_signal_means_b_is_not_claimed`）。紅：`repro.4c.collect.log`（修之前）；修之後在同一個 4c 複本上套件跑完，4 個測試紅，包括預期的那個（`repro.4c.fixed.collect.log`，`repro.4c.fixed.cells.log` 綠）；gate 的部分跑 `mutate_p4_health.partial_r7b_C2R6-4c.log`：caught。
- **修一之後的部分跑發現同類的第二個洞（`7a7a2577`，測試）**：`C2R7-1n`（S0 的 trial block 不放開）是 `WRONG TEST`（`mutate_p4_health.partial_r7b_C2R7-1.first_01ba2a41.log`）。cells 的 `TestS0Cut2Checks` 在 1n 下第一個測試之後 mask 一直是擋住的，後面那個「比較 trial 前後的 mask」的指名測試一開始就在擋住的狀態，看不到「沒放開」。1n 在 shard 3 的份裡（表的位置 463，463 mod 4＝3），所以第一次 gate 在同一處也會有一個存活（1n 是 `WRONG TEST`、rc 1，`partial_r7b_C2R7-1.first_01ba2a41.log:98`、`:134-136`），讓 gate 失敗；它不是像 4c 那樣的 REFUSED（沒有套件結果）。修：這個 class 的每個測試開始與結束都把 mask 清掉（`_clear_the_stop_mask`）；在 1n 的複本上整個 cells 套件：指名的測試與另外三個紅。
- **修完之後的部分跑**（gate script 的 `ONLY_LABEL_PREFIX`，都不是 gate；`C2R6-4c`、`C2R7-3` 跑在 `01ba2a41`，`C2R6-4`、`C2R7-1` 重跑在 `7a7a2577`）：`mutate_p4_health.partial_r7b_C2R6-4c.log`（1 個，caught）、`…_C2R6-4.log`（`4a`–`4e` 5 個，0 存活）、`…_C2R7-1.log`（18 個，0 存活）、`…_C2R7-3.log`（5 個，0 存活；`7a7a2577` 沒有碰它的測試）。每份的第 1 行是它跑的 commit。
- **沒有改的**：mutant、gate 的規則、`tools/`。

### 11.8 r7 審查之後的紀錄（只改這份文件）

審查的對象是 `4a8cdf7b`（gate 認證的 code 是 `7a7a2577`）。這一節和上面幾處被更正的句子，是對 r7 審查（finding 1、2、4、5、8、10 與 partials.log 的註記）的回應；**沒有動 code、測試或 gate**。

1. **gate 與 code 的對應**：`7a7a2577..4a8cdf7b` 只改這一份文件（`NS/checks/diff.7a7a2577-4a8cdf7b.txt`：`1 file changed, 29 insertions(+), 14 deletions(-)`，gate 的 WATCHED 路徑〔`mutate_p4_health.sh:64-74`〕下有差異的檔：0 個）。所以 `GATE.nslab.log:3` 的 `--commit 7a7a2577…` 對這份文件之後的 HEAD 仍然成立，前提是 WATCHED 路徑之後都不變。
2. **沒有看守行程**：事後掃 `/proc`，沒有 watchdog、SIGCONT、gate driver 在跑；陽性對照找得到假的那一個（`NS/checks/ps.watchers.txt`，見 §11.4）。
3. **subject sha 依 locale 而變**（finding 5）：`mutate_p4_health.sh:84` 的 `find … | sort | xargs sha256sum | sha256sum` 照 `LC_COLLATE` 排序；同一份檔案，`LC_ALL=C` 與 `C.UTF-8` 給 `d2a38f99dbaaf3b3`，`en_US.UTF-8` 給 `4651b09cb90a1387`（`NS/checks/subject-sha-by-locale.laptop.txt:2-4`，筆電，`7a7a2577` 的 `tools/p4_health`）。同樣的 `find | sort` 在 `:3355`、`:3475`（byte-identical 的 hash，筆電 `6d9e486d69ca0806`、nslab `86a08ac3a8121ab3`，兩邊的 shard 0 都在 `:736`），`sort -u` 在 `:3376`（測試名字的順序，locale 不同，順序不同）。`gates_sum` 不排序，兩邊相同（`:10`）。
   - **安全失敗**：加總 script 拒絕 subject sha 不同的 log（`sum_p4_health_gate_shards.sh:139-142`）。這個 gate 的四份全在 nslab，不受影響。
   - **修法留給下一輪 code**：在 `:84`、`:3355`、`:3475`、`:3376` 的 `sort` 上加 `LC_ALL=C`（逐處加，**不是**全域 export，全域 export 會改變套件的 locale）；配一個先看過紅的測試；加總 script 加直譯器檢查（它現在只比 commit、tree、subject sha，沒有讀直譯器那一行，所以 locale 不同是現在唯一擋住「兩台機器或兩種直譯器的 shard 被加總」的東西）。這一項改的是 WATCHED 檔，也是 mutation 的對象，需要一次完整的新 gate。
4. **`gen_runtime.py` 與 S0 的 controller trial**（finding 2，只改文字）：見 §6 前提 3 與 §11.1 的 `c8c2cef8`。可選的 code 修法：`packages()` 之後再呼叫一次 `check_exercise_copy`；要一個新 mutant 與完整 gate。
5. **`r7b/partials.log:1-4` 沒有真的結束碼**：`partials.sh:8` 在 `$(date)` 之後才讀 `$?`（讀到的是 `date` 的），所以 `:1-4` 的 `rc=0` 不是部分跑的結果；`partials2.sh` 修了（`:5` 起是真的）。**那一刻 C2R7-1 的真實結果**：`18 mutations, 1 survived`、`rc=1`（`partial_r7b_C2R7-1.first_01ba2a41.log:134-136`），也就是 §11.7 的 `1n`，不是 `:3` 寫的 `rc=0`。同樣的寫法也在 `gate_driver*.sh:22`（那兩支沒有走到這個路徑）。
6. **還開著、下一輪 code 一起做**：finding 2 的 `probe.py:47-52` 註解（與可選的 code 修法）；finding 3（01ba2a41、7a7a2577 的清理靜靜修復 mask，與 `_swap_handlers` 的兩處還原，`lab.py:181`、`lab_round.py:316`，沒有 mutant）；finding 5 的 locale 修與直譯器檢查。第一次 live 之前的項目見 §11.5 與 §6。

### 11.9 subject sha 與 interpreter 行在哪一個 commit 換了算法（gate 紀錄用）

- **subject sha**：`a33fbb73` 之前，`mutate_p4_health.sh` 的 subject sha 用**呼叫者的 locale** 排序檔名；從 `a33fbb73` 起用 `LC_ALL=C`。
  - 例：`fd208fbd` 的四份 shard（`gates-0910/p4-ternary-replay-c/mutate_p4_health.shard{0..3}of4.log:9`，`LANG=en_US.UTF-8`）都是 `7c5479134e91cf55`；同一棵 `tools/p4_health`（`c24a7d19`）在 C 排序下是 `d26b009c0cd59412`（`gates-0910/p4-health-locale/subject_sha_old.log:3-4`）。
  - **跨這個改動的 subject sha 不能互相比**：值不同不代表檔案不同，值相同也只在兩邊都是 C 排序（或剛好同一個 locale）時才有意義。merged head 的 gate 只和 `a33fbb73` 之後、同樣 C 排序的 log 比。
- **interpreter 行**：從第 9 輪起是 `interpreter: <realpath> (<版本>, prefix <sys.prefix>)`，之前沒有 `prefix`。加總 script 比整行，所以新舊 log 的這一行不會相同，不能加總在一起（本來也不該：commit 不同）。這一行不含主機名：兩台機器上路徑、版本、prefix 都相同時，分不出來。

### 11.10 `feat/p4-health-locale` 分支改了什麼，與 merged head 的 gate

- **分支**：`feat/p4-health-locale`，頭 `4a4eb94e`（從 `c24a7d19` 之後開出，11 顆非 merge commit，13 個檔，+826／−77），在 `merge/trunk-1015` 裡併成 M2（`d92bf1a258cec2d1524652fcff17526926fbcefa`）。
- **這個分支改了什麼**：
  - **subject sha 與 locale**：`mutate_p4_health.sh` 的 subject sha 的檔名排序固定用 `LC_ALL=C`（`a33fbb73`），不再隨呼叫者的 locale 變；從這個 commit 起的 log 才能互相比，見 §11.9。
  - **interpreter 行**：`interpreter: <realpath> (<版本>, prefix <sys.prefix>)`，加上 `sys.prefix`（`2e39cb0d`），也見 §11.9；同一個 commit 補了 shard 的上界在 table 的大小時的測試。
  - **exercise 複本的檢查**：除了複本的檔案，也檢查它的 build 輸出，並且從原始碼載入複本裡的模組（`863ca045`）；`convert.py` 處理過之後再檢查一次（`bc9f79c3`）；複本的根目錄是 symlink 就拒絕，並且以呼叫者給的路徑（而不是它解析到的目錄）記錄 build 輸出，所以兩次檢查之間被改指到別處的連結會被比出來；複本裡任何地方有 `__pycache__`，每一次檢查都拒絕，第一次也一樣（`4a4eb94e`）。
  - **訊號遮罩的測試**：洩漏的 stop 遮罩讓該測試失敗，而不是被修回去（`109f4c6c`）；cells 的每個測試和開始時的遮罩比較（`ebbc43d6`）；ValueSet delivery 測試在放開 stop 之前先裝好不做事的 handler，所以已經 pending 的 stop 不會結束整個套件（`8918d051`，`4a4eb94e`）。
  - **其他**：T8 的 RED 原因多了「snapshot 失敗」（`a741e763`）；`s0.stops_held` 的 docstring 寫明 SIGINT 的行為（`02cf1b40`）；`SUMMARY` 註明 subject sha 在哪一個 commit 換了算法（`5fd954f6`）。
- **merged head 的 GATE 行**（`gates-0910/merged-trunk-1015/GATE.log`）：
  `GATE: 517 mutations, 0 survived, shards 4/4 ok, commit d92bf1a258cec2d1524652fcff17526926fbcefa, tree fd872b3ddb9d6eaa87d264675c8aaabcbabf2c26, subject sha e69a74d976c1a022`
  - 四個 shard 是 130／129／129／129 個，各 `rc=0`（22:50:49–06:33:01，7 小時 42 分）；interpreter 行四份相同：`interpreter: /home/adam/miniconda3/envs/ryu-env/bin/python3.8 (3.8.20, prefix /home/adam/miniconda3/envs/ryu-env)`。
  - tree `fd872b3d` ＝ M2 的 `tools/p4_health`。squash 之後還要記錄 squash commit 的 `tools/p4_health` tree 等於它。
  - 完整的步驟表與 Cut C 那一半（Stage C）在 `scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015/REPORT-merged-trunk-1015.md`，`SUMMARY-cut-c.md` 第 14 節有精簡版。
- **預檢（REPORT 的 Stage B，20:28–20:39，11 分 36 秒，全綠）**：

  | 步驟 | 結果 |
  |---|---|
  | `ANCHOR_CHECK=1 mutate_p4_health.sh` | 518 行計數（517 個 mutant＋負向對照），每個都是 1；rc 2 是設計如此 |
  | `check_gate_anchors.py HEAD` | 137/137 cells ok；`mutate_p4_health.sh` 一列 ok(476) |
  | 裸 `sort` 的檢查 | `bare (not LC_ALL=C) sorts in a pipe: 0` |
  | cells／collect，py3.13 與 py3.8 | Ran 203／203／192／192，OK；再各跑一次在 SIGHUP 被擋住的 parent 底下，同樣 203／203／192／192 OK |
  | `test_p4_health_recover.sh`／`test_p4_health_gate_scripts.sh` | 163 checks, 0 failed／79 checks, 0 failed |
  | `ONLY_LABEL_PREFIX=C2R8-5g` 部分跑 | 1 mutation, 0 survived（baseline 綠、mutant 被抓、負向對照綠） |
  | ValueSet delivery 測試，SIGHUP 在 exec 前就 pending；對照組沒有 pending | 兩個都 Ran 1 OK |
  | S0（bytecode 寫入打開） | `S0 verdict: COMPLETE`，`S0 checks: 57, failed: 0`；結束後複本裡沒有 `__pycache__` |

  - 預檢每一步的 log 在 `gates-0910/merged-trunk-1015/B_<n>_*.log`，判定取自各 log 自己的最後一行 `rc=`。
- **啟動 shard 的訊號遮罩前提**：每個 shard 與每個預檢步驟起跑前，在**執行的行程自己**裡讀 `/proc/self/status` 的 `SigBlk`（不經命令替換；經命令替換讀到的是 bash 等待時自己的遮罩，會得到 `0x2` 的假值），要求 `SigBlk & 0x4203 == 0`（0x4203 是訊號 1、2、10、15 的位元），並把這一行記在 log 裡。四個 shard 都通過：子行程的 `SigBlk` 是 `0000000000000000`，exec 的行程是 `0000000000010000`（只有 SIGCHLD），兩者 `& 0x4203` 都是 0（`gates-0910/merged-trunk-1015/mutate_p4_health.shard{0..3}of4.log` 的第 3–9 行、`shard{0..3}.guard.log`、`shardwrap.sh`）。

[Co-developed with claude code -- Adam]
