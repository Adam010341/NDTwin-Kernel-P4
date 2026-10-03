# SUMMARY：external control plane 也跑心跳，只偵測（feat/external-detect-only-0927）

- **分支**：`feat/external-detect-only-0927`，照指示從 AEG 的 `ebe17f7c` 開出（不是 trunk），AEG 修正輪 `f7e2a128` 已 merge 進來（`b01ad9b9`）。
- **Worktree**：`scratch/overnight-2026-09-05/wt-external-detect-0927`，`p4_proxy/venv` 與 `p4_proxy/p4_src/build` 連到主 checkout。
- **Head**：第五輪是 ``4c18bf3da29efed3d2f36abd2db67d8f780a222b``（§R5，在最後）；第四輪是 ``faf6eb410c2cb0b38b06c86000bdc65b21c8ac7a``（§R4）；第三輪 `480e9f2e`（§R3）；第二輪 `14921f98`（§0）；第一輪 `17e40e29`（§6 列出 commit）。
- 沒 push、沒 merge 到 trunk、沒 sudo、沒碰 lab、沒碰主 checkout（只**讀**了主 checkout 裡未追蹤的 live raw `074635Z`，見 §4）；沒碰 process_is_the_emitter、FixtureProvenance。
- commit 訊息是一般工程師的寫法，沒有 trailer。

[Co-developed with claude code -- Adam]

## R4. 第四輪（Adam 09-28 14:2x 裁定：B merge 前兩個揭露的缺口都要修）

- **Head**：``faf6eb410c2cb0b38b06c86000bdc65b21c8ac7a``。
- **merge 了兩次 trunk，都沒有衝突**：
  - round 4 開工前 merge `08f67b7a`（KJL 那批）＝`35b19663`；
  - extb4 開跑時 trunk 又到了 `3368412d`（suite 的 INT/TERM trap、GAP-2b 文件），我停掉剛啟動、還在等鎖的 driver（它一個閘門都沒跑；那份 log 寫明是我停的），merge 成 `faf6eb41`，再從頭跑。
  - trunk 的 `3368412d` 改了 test_live_p1_common 的 trap（INT/TERM 結束整個 suite）；B 的 §19 送訊號給的是被測的 step，不是 suite 本身，合併後 220/0。
- 沒 push、沒碰 lab、沒 sudo。G1 仍 HOLD。
- **我的做法**：round 3 的閘門在重開機後補跑（約 1.5 小時）時，round 4 在另一個 worktree `wt-external-detect-r4-0928`（分支 `wip/external-detect-r4-0928`，從 `480e9f2e` 開）做；round 3 交付後，B 的分支 fast-forward 到那裡。

### R4.1 項目 1：external 上不再報猜的 destination path（`03bb1880`）

- **改法**：
  - `TopologyManager.destination_paths_unknown`（class 與 instance 屬性，預設 False）。
  - startup 在「external control plane 跑自己的 pipeline」那一支設成 True——宣告的連線照樣進 graph（心跳要判它們），只是不拿來算路徑。
  - `/ryu_server/all_destination_paths` 在這個旗標下回 `{"status": "success", "all_destination_paths": []}`（跟沒有 topology 時一樣）。
  - 連線變化後的 `push_destination_paths` 在這個旗標下不推（kernel 本來也拒收空快照），印一行原因。
  - NDTwin 自己的 pipeline、不是 external 的外來 fabric 都不變（它們的路徑照舊：有 NDTwin 安裝的路由就是安裝的，沒有就是在宣告連線上算的最短路徑）。
- **文字**：
  - ndt verify_p4 external 那段回到「0 是設計上的答案，不是讀數」，並說 proxy 不在宣告連線上猜。
  - `ndt status` 的 proxy 列：external 自己的 pipeline ⇒ `none expected -- an external control plane ... reports no path rather than guess one`；其他外來 fabric ⇒ `not a count of installed routes unless NDTwin owns the route tables ...`（修正 round 3 S3 那句「whether or not the routes are NDTwin's」——NDTwin 擁有表時，報的就是它安裝的路由，不是猜的）。
  - topology_manager 偵測不改路由那段註解、README 的 F5 段。
  - test_declared_links.py ~319 那個 test 名稱我沒改：它講的是「external 在 NDTwin 自己的 pipeline 上不宣告連線」，現在仍對。
- **測試**（test_heartbeat_fabric 新 class `AnExternalFabricReportsNoGuessedPathsTest`，真的 TopologyManager、pod-topo 的線、兩個 host 在不同交換機上）：
  - startup 只在 external 自己的 pipeline 上設旗標（baseline、非 external 的外來、NDTwin pipeline 上的 external 都不設）；
  - 宣告的連線照樣進 graph；
  - external 的 pull 回空；
  - 對照：同一張 graph 沒有旗標時確實有 2 條路徑可以扣（NDTwin pipeline 與非 external 外來各一次）；
  - 剪一條線：kernel 照樣收到 link_failure，external 上不推路徑、對照組推一次。
  - test_ndt_app_package：external 自己 pipeline 的 status 列說 none expected、不說 twin 的猜測、不是 --check 的問題。
- **mutation**：X11／X11b（startup 不設旗標，猜測回來）、X12（pull 不看旗標）、X13（push 不看旗標）、X14（每個 fabric 都扣路徑——對照格的紅）；ndt 的 M28b（status 的 external 分支永遠不走）。

### R4.2 項目 2：external 上的心跳預設安全（`1ece97ab`、`ec04eb95`、`89615935`）

- **規則**：`ndt up p4 --app` 在 external control plane 跑自己的 pipeline 時，**在動機器之前**（package pre-flight 裡）跑離線的 drop check（新 `tools/test_workflow/heartbeat_drop_check.py`）。
  - rc 0（每個程式都丟）才啟動心跳。
  - rc 1（有程式不丟）、rc 2（判斷不了）、或檢查根本沒跑 ⇒ **不啟動**。`ndt up` 說原因；`.test_run/heartbeat.withheld` 記下原因，`ndt status` 的 heartbeat 列下面印出來；下一次 bring-up 或 `ndt down` 清掉它。
  - bring-up 本身不會因此失敗（fabric 是好的，缺的只是偵測）。
  - 不是 external 的外來 fabric 不跑檢查，心跳照舊（segment W、ruling 4）。
- **方法（bmv2，不用 p4testgen）**：
  - 丟棄式的 **stock** `/usr/local/bin/simple_switch`：與 fabric 的 fast build 同一個 bmv2 commit（兩者 `--version` 都是 `1.15.3-f0b7d201`，OBSERVED）。fast build 是 `--disable-logging-macros` 編的（它的 BUILD-MANIFEST），沒有逐封包 log，所以用 stock。
  - 載入 package 的**同一份編好的 JSON**，沒有控制器、沒有表項、沒有 clone session、沒有 multicast group；`--use-files` 讀寫 pcap，不需要 root 也不需要介面。
  - 每個資料埠（package 模型給那些交換機的 host 埠與交換機間的埠，跟 fabric 接上的一樣）各打一個真的心跳幀。這個幀與 root helper 的 `encode()` 逐 byte 相同，測試把兩者釘在一起。
  - 判定讀 bmv2 自己的逐封包 log，再用每個接上的埠（資料埠與 CPU 埠）的輸出 pcap 交叉核對：
    - **丟**：egress 511，或 egress 結束時被丟；或只送到一個 fabric 沒有的埠（advanced_tunnel 的預設 egress 0）——什麼都出不去。
    - **不丟**：送到 fabric 的埠（轉送／洪泛）、送到 CPU 埠（punt）、跑了 `generate_digest`（digest 給控制器）、clone（log 的 `Cloning packet` 或 clone primitive）、multicast（`Multicast requested`），或任何 pcap 有幀。
    - **判斷不了**：幀沒被處理、有 copy 沒記下去向、交換機提早結束、讀不到的 pcap 或 package。判斷不了不是丟。
  - 快取：以程式 JSON 的 sha256 為鍵，存在 `${NDT_HB_CHECK_CACHE:-~/.cache/ndtwin/heartbeat-drop}`；只有 port 集合、CPU 埠、bmv2 版本、檢查版本都相同才重用；判斷不了的答案不存。
  - 不選 p4testgen 的理由：它解的是路徑，不是在同一個 target 上跑同一份 JSON；而且我們記過「P4Testgen 構不到 clone 取樣路徑」。
- **這三個程式都過**（OBSERVED，離線，bmv2 載入程式、沒有控制器）：
  - flowcache/solution：三個埠的幀都在 ingress 丟掉（egress 511）；
  - advanced_tunnel（p4runtime skeleton 與 solution 同一個程式）：都送到埠 0，而這個 fabric 沒有交換機有埠 0。
- 🔴 **限制**（每個答案都帶著，`ndt up` 那一行也說）：只驗預設（table-miss）行為；external 控制器之後裝的表項、clone session、multicast group 都不涵蓋。
- **不是 lab**（照 orchestrator 09-28 的條件）：
  - 以呼叫者身分跑，沒有 root；
  - pcap、log、nanomsg socket（`ipc://notif.ipc`，相對於它自己的目錄）都在它自己的暫存目錄；
  - Thrift 埠從 29400–29499 挑（ports.sh 列的每個 lab 埠都在排除範圍內，測試釘住），啟動前**再確認一次**沒人用；
  - device id ≥ 900000；
  - argv[0] 是 `ndt-hbdrop-bmv2`（comm 是 `simple_switch`，不是 `simple_switch_g`）；
  - 以 Popen 的確切 pid 停止（TERM 再 KILL），在 `finally`、SIGTERM／SIGINT／SIGHUP；checker 被 SIGKILL 時由 `PR_SET_PDEATHSIG` 一起帶走。
  - **閘門裡**每次啟動都經一個 wrapper（`NDT_HB_CHECK_BMV2`），在 tripwire log 記一行 `ALLOWED-LAUNCH`；tripwire 閘門另外確認每個被記下的 pid 最後都不在了。
- **ndt 輸出只有一行**（`ec04eb95`）：live-p1/06 每臂只留 `ndt up` 輸出的前 6000 字，external_evidence.py 要讀的 detect-only 那行在後面；所以 `ndt up` 只印一行答案（含限制），完整答案寫進 `.test_run/logs/heartbeat_drop_check.log`。
- **proxy 的普查文字**改成：external 上「只在 drop check 證明程式會丟之後」才啟動；三個程式的 P4 原始碼讀法之外，加上 drop check 在丟棄式 bmv2 上的結果；「其他 external 程式」改成「啟動前一樣檢查；控制器之後裝的不涵蓋」。
- **測試**：
  - 新 `tests/shell/test_heartbeat_drop_check.py`（67 格，每格都真的跑 stock simple_switch）：
    - 注入的幀＝daemon 的幀；
    - 三個程式 DROPPED，並用 convert.py 轉出來的 p4runtime package 端到端 rc 0；
    - 洪泛／punt／digest／clone／multicast 各一個 fixture 程式都 NOT_DROPPED、各自說出做了什麼；換成洪泛程式的 package rc 1；
    - judge 的單元格：pcap 勝過 log、讀不到的都是 unknown；
    - rc 2／rc 3；
    - 快取；
    - 「不是 lab」：port 在 lab 外、被占的候選跳過、啟動前再確認；跑著的時候 ndt 的 `bmv2_count` 不算它、helper 的 `sweep_matches` 不匹配、p4_testbed_topo 的名字與身分規則都不認它、kernel capacity scan 的 argv[0] 規則不認它（並釘住 C++ 原始碼裡那條規則）、沒有 argv 元素含 `simple_switch_grpc`、socket 在自己的目錄、device id > 512；回傳時 pid 已經不在、目錄已刪；checker 被 SIGKILL 時交換機跟著死。
  - fixture 程式：`tests/fixtures/heartbeat_drop/`，這裡編的（`hb_fixture.p4` 一份原始碼、`-D` 選行為），加上 flowcache solution 的 JSON；README 寫了指令與 p4c 版本。advanced_tunnel 用 `tools/p4_exercise/tests/fixtures/p4runtime/build/advanced_tunnel.json`（與 `~/tutorials` 的 build 在去掉 `program`／`source_info` 後相同，我比對過）。
  - test_ndt_heartbeat 新 §2c 與 §6 的格：檢查在 topo-start 之前跑、剛好一次；DROPPED ⇒ 啟動；NOT_DROPPED／UNKNOWN／沒跑 ⇒ 不啟動、說原因、有紀錄、bring-up 照樣 rc 0、proxy 與 kernel 照樣起；非 external 與 NDTwin pipeline 不跑檢查；紀錄在下次 bring-up 與 `ndt down` 被清掉；`ndt status` 印出紀錄。
- **mutation**：
  - 新 gate `tests/shell/mutate_heartbeat_drop_check.sh`：D1 跳過檢查、D2 punt 當成丟、D3 忽略洪泛（orchestrator 點名的三個），再加 pcap、digest、clone、multicast、unknown、快取、port、argv[0]、socket、device id、pdeathsig、停止、目錄、幀、計畫、文字等共 39 個 mutation；並要求 suite 的每一格都在某個 mutation 下紅過（6 格豁免，理由寫在 gate 裡）。
  - mutate_p4_heartbeat_w：N40–N55（ndt 的接線：不看檢查、判斷不了當成證明、不跑、一律不啟動、不說、一行答案與完整答案、bring-up 失敗、原因、紀錄、沒跑當成證明、每個 package 都跑、非 external 也受限、紀錄不清、status 列兩向）。
  - dry run 時 N55 存活，找到真的問題：`set -u` 下沒有紀錄時 status 列會因 `why` 未定義而中斷，而不是印出東西。已修（`89615935`：先初始化），手動確認 N55 變紅。

### R4.3 red first、mutation、閘門——**停在途中（ABORTED），round 4 尚未 DELIVERED**（第五輪更正：10-01 由 extb4r 補跑另外 5 個，22＋5＝27 個全部 rc 0，round 4 已 DELIVERED——§R5.6）

- 21:2x orchestrator 通知 Adam 的額度用完、立刻收尾。我用 process group 停了 extb4 的 driver；它當時在等 guard 鎖跑 `mutate_app_package`（一個 mutation 都沒跑），那份 log 的最後兩行寫明 ABORTED。
- driver：凍結副本 `scratchpad/nolab2/frozen/gates_b4.sh`，tag `extb4`，head `faf6eb41`。它是 gates_b3 加上 redfirst_b4、test_heartbeat_drop_check、mutate_heartbeat_drop_check，drop check 的 simple_switch 經 wrapper 在 tripwire log 記 `ALLOWED-LAUNCH`，tripwire 閘門另外確認每個 pid 最後都不在。
- **跑完的 ~~21~~ 22 個全部 rc 0**（第五輪更正：下面列的是 22 個；`logs/gates-0910/<gate>.extb4-faf6eb41.log`；我讀了各自的最後一行，第一行 sha 會在接手時一起核）：
  - redfirst_b／b2／b3／b4：ALL-AS-EXPECTED。
    - b4（base `35b19663`）：proxy 剛好紅 5 條、status 列 2 格、drop check 接線 16 格；沒有工具時 suite 失敗。
    - b／b2／b3 的期望集合補了 round 4 的格與 trunk `08f67b7a` 的一格，每一處都印出理由。
  - proxy_unit：1733 passed、1 skipped。
  - test_ndt_heartbeat 88/0、test_ndt_app_package 399/0、test_ndt_up_down_robust 424/0、test_ndt_sudo_surface 55/0、test_ndt_status_check_baseline 112/0。
  - selftest_08、selftest_07：PASS。
  - test_live_p1_common 220/0、thirteen 45/0、external_evidence 103/0。
  - test_heartbeat_drop_check 67/0。
  - test_drive_exercise：OK。
  - mutate_p4_heartbeat_w：**256 mutations，0 survived**；新 proxy test 123/123 看過紅；ndt 86 個不同名的 check 除 12 個 control 外都看過紅；X11–X14、N40–N55、M28／M28b 各自殺在點名的格。
  - mutate_live_p1_common 59／0 survived、mutate_live_p1_thirteen 12／0、mutate_live_p1_external_evidence 61／0（103/103 看過紅）、mutate_roles_binding 179／0。
- **還沒跑的 5 個**：mutate_app_package、mutate_ndt_app_package、mutate_heartbeat_drop_check、check_gate_anchors、nolab_tripwire。
- **跑閘門之外量過的（OBSERVED，不是閘門）**：
  - mutate_heartbeat_drop_check 在 r4 worktree 上的 dry run：39 mutations、0 survived、非豁免格 61/61 看過紅。
  - `check_gate_anchors.py 89615935`：128/128。
  - extb4 到停下時的 tripwire log：allowed launches 之外 0 個不是 `file://`。

### R4.6 接手步驟（round 4 收尾）

1. **環境與原料**：
   - B worktree `git rev-parse HEAD` 應是 `faf6eb41`，`status --porcelain` 乾淨；
   - `df -h /` ≥ 1.5 GB；
   - 若 scratchpad 被清掉（重開機），從 `logs/gates-0910/worker-extb-0928/` 複製回 `aeg/`、`nolab2/frozen`、`tmp/hbsnap`、`hbsnap.sha256`。
2. **新 driver**：`scratchpad/aeg/gates_b4r.sh`（TAG `extb4r`）＝`gates_b4.sh` 只留上面 5 個（仿照 `gates_b3r.sh` 從 `gates_b3.sh` 的做法），凍結、setsid 啟動。
   - 預估：沒有鎖等待時約 1.5 小時；別的 worker 占鎖時更久（今天等過 50 分鐘）。
3. 讀完每份 log（第一行 sha、最後一行 rc、tripwire 的 allowed launches 都已不在），填 §R4.3，全部 rc 0 才寫 `DELIVERED faf6eb41…`。
4. 若 trunk 又動了：先 `git merge-tree --write-tree <trunk> faf6eb41`；乾淨就在交付報告裡說明，要不要再 merge 由 orchestrator 決定（會使整套重跑）。
5. `wt-external-detect-r4-0928`（分支 `wip/external-detect-r4-0928`，已與 B 同 head `faf6eb41`）是我開的，交付後可以 `git worktree remove`。

### R4.4 Commits（`480e9f2e..HEAD`，first-parent）

- `35b19663` Merge trunk 08f67b7a into feat/external-detect-only-0927
- `03bb1880` external detect-only: report no destination paths on an external control plane
- `1ece97ab` ndt: start the heartbeat on an external control plane only after a drop check
- `3a6986e1` heartbeat gate: N08 anchors on the teardown as it reads now
- `ec04eb95` ndt: say the heartbeat drop check in one line and keep its full answer
- `89615935` ndt: initialize the withheld row's fields before reading them
- `faf6eb41` Merge trunk 3368412d into feat/external-detect-only-0927
- B 自己這一輪的改動（`35b19663..89615935`）：22 個檔，+6137／−42。
  - 其中約 4270 行是 fixture 的 bmv2 JSON（p4c 的原樣輸出；flowcache_solution.json 就有 1814 行）。
  - 新增行裡的 `/home/adam` 只在 flowcache_solution.json 的 `program`／`source_info`（p4c 寫進去的原始碼路徑，同 `tools/p4_exercise/tests/fixtures` 的前例）。（第五輪更正：**不只**——`tests/fixtures/heartbeat_drop/README` 的編譯指令也有一行；第五輪照 orchestrator 的裁定改成 `~/`，p4c 的 JSON 照原樣。）
  - 掃過秘密字串，沒有。

### R4.5 沒有驗證的（INFERRED 或沒跑）

- **live 從沒跑過**：`ndt up` 裡真的跑 drop check、真的因此啟動或不啟動心跳，都只在 offline 的 stub 與丟棄式 bmv2 上驗過；H4／H5 下一次 live 才會真的走到。
- **switch_state 不知道原因**：心跳被 drop check 擋下時，proxy 的 `heartbeat` 區塊顯示的是報告不可用（它自己的理由，例如 stopped／not_running），不是 drop check 的原因；原因在 `ndt up` 與 `ndt status`。
- **「埠 0 出不去」**：在真的 fabric 上仍是從 bmv2 行為推論的；drop check 量到的是 bmv2 把幀送往埠 0，而 fabric 的模型沒有埠 0。
- **stock 與 fast 是同一個 commit**，但不是同一個 binary（fast 沒有 log）。判定依據的是同一份 JSON 在同一個 bmv2 版本上的行為。
- **mutation gate 裡看過紅、但理由退化的豁免格**：「runs as the caller」「bmv2_count 不算它」「identity rule」在有些 mutant 下是紅的，但那是因為那個 mutant 根本沒啟動交換機，不是性質被打破；它們列在 gate 的豁免名單裡並寫了理由。（external judge 對 14921f98 判 MERGE AFTER FIXES：M1–M3、S1–S4、m1–m4）

- **Head**：``480e9f2e2187eb814708e003c81eb313fe1fb5cf``。
  - 先 `git merge 85bec430`（trunk）＝`8c75a618`，沒有衝突；之後在同一分支上加 5 個 commit（§R3.7）。
  - trunk 現在仍是 `85bec430`，已是 HEAD 的祖先；`git merge-tree --write-tree 85bec430 HEAD` rc 0。
- 沒 push、沒碰 lab、沒 sudo、沒碰主 checkout（只**讀**了主 checkout 裡未追蹤的 074635Z raw）。
- commit 訊息一般工程師寫法、沒有 trailer。
- **G1 仍 HOLD。**

### R3.1 M2：比對工具（`external_evidence.py`，`a8d11f02`）

- **沒有 `--samples` 就拒絕（rc 3）**。round 報告裡的標記（N3 的 `ndt up`、N4 的 switch_state、N5 的 `ndt status`）都在 exercise 的控制器啟動、pipeline 載入**之前**取得，說不出程式在跑的時候心跳有沒有在跑（judge §2(a)）。
- **其他拒絕（rc 3）**：
  - 沒有 `--control2`；
  - `--control2` 就是對照組本身；
  - 同一個對照組給兩次；
  - 處理組同時被當成對照組。
- **處理組每一臂的 session，要在整個臂的窗口裡都在跑**。
  - 窗口照 08 H5 的算法：由 round 報告的 stamp 開、下一臂的 stamp 關；最後一臂用 `50_t06_end.txt`（06 結束的時間）。
  - 以下情況拒絕：
    - 從沒被取樣到 running；
    - 報告 STALE：`wall − written_wall > 10 s`（被 SIGKILL 的 daemon 會留下一個永遠的 `running`），或者有 `stop_reason`；
    - 取樣中間有超過 10 s 的空檔；
    - 停了又起；
    - 在控制器最後一次寫 log（log 的 mtime）之前就停；
    - 窗口裡還有**別的** session 在跑。
- **sampler 多記的欄位**（08，`45ca199e`）：`written_wall`、`stop_reason`，以及 daemon 的四個計數器（多了 `misdelivered`、`foreign_frames`）。
  - 四個計數器在該臂的 session 裡任何一個非 0 ⇒ 差異（`!! DAEMON …`；轉給 host 就說 ruling 4）。
  - 這是**程式載入之後**它怎麼處理 0x88B5 的唯一證據。
- **N4 的 daemon 計數器改標籤、不判**：印成「before the exercise's pipeline was loaded: not evidence about the program」。
- **對照組有任何心跳痕跡就拒絕**：detect-only 那行、heartbeat 區塊、running 列，不論 N5 那列是 STALE 還是已停（judge §2(c)）。
- **不變式對所有對照組判**：處理組破了、而**每一個**對照組都守住，才算差異。只有某個對照組也破的，列出、不計。
- **最後一個 counter 區塊要已經穩定**，否則 UNREADABLE（rc 2）。穩定＝與前一個區塊相同，或 s1 ingress 100 已等於這一輪送出的全部封包（ping＋iperf 資料報）。
  - 074635Z 的兩個 p4runtime 臂，最後一塊與前一塊不同，但剛好等於送出的數目（skeleton 5、solution 3505）。
  - 所以對 074635Z 跑 `show` 仍是 rc 0（OBSERVED，這一輪重跑過）。
- **比 IPv4 header 短的 packet-in**（m1）：UNREADABLE、rc 2，不再是 IndexError。
- `within()` 跨多個對照組算 spread，`counters_final` 那一支也一樣（m3）。

### R3.2 M3：INT／TERM 的 rc，與 `_common.sh:324` 的窗口（`fdae10a9`）

- **trap 改從源頭裝**：`start_step` 不再裝 `trap finish EXIT INT TERM`，改呼叫 `arm_step_traps`：
  - EXIT → `finish`；
  - INT → `interrupted SIGINT 130`；
  - TERM → `interrupted SIGTERM 143`。
- **`interrupted` 做的事**：
  - 把這一輪記成失敗：「interrupted by SIG… before the run finished」；之前已經有失敗，就附上第一個失敗。
  - 再 `exit 130／143`。
- **rc 帶到結束**：`finish` 最後 `exit "${SIGNAL_RC:-$VERDICT_RC}"`，130／143 不再被換成 1。
- **窗口關掉了**：`start_step` 一裝好就是這組 trap，所以 `start_step` 與 08 自己的 `arm_traps` 之間收到 TERM 也是 FAIL＋143。
  - 用 `start_step` 的步驟（01–05、07、08）都一樣。
  - 08 的 `w_interrupted` 拿掉了，`arm_traps` 用同一個 `interrupted`。
- **新格**：
  - 08 self-test：H1 途中收到 TERM ⇒ FAIL、**rc 143**；`arm_traps` 之前（還是 `start_step` 的 trap）收到 TERM ⇒ FAIL、rc 143。
  - test_live_p1_common §19：TERM ⇒ FAIL＋143；INT ⇒ FAIL＋130；不送訊號的對照 ⇒ PASS＋0。
- 08 開頭與 README 對 130／143 的說法，現在與程式一致。

### R3.3 M1：可以照著跑的比對程序（README，`9d9ee602`）

README 的「合併前的比對——可以照著跑的程序」一段是預先登記的，事後不改。

- **在哪裡跑**：全部在主 checkout 跑。
  - 主 checkout 就是 `/etc/ndtwin-lab.conf` 的 KERNEL_DIR 指的樹，所以不需要 root 步驟。
  - B 沒改 C++，不用重建 kernel。
- **對照組 C1、C2**：主 checkout 在 trunk head、還沒 merge B，各跑一次 `ONLY=p4runtime,flowcache` 的 06。
  - trunk 的 06 不寫 `00_venv.txt`，所以用 B 的 `venv_fingerprint.sh` 手動補記。
  - 另寫 `00_code.txt`：`rev-parse HEAD` 加上未提交檔數。
- **B 只在本地 merge、不 push**。
- **處理組 T**：跑一次 `OLD_06=<C1> PART=h5` 的 08。
  - T＝它印出的那個 06 run；samples＝它的 `50_samples.tsv`。
  - 「B 上的 06 一次」這個選項拿掉了。
- **比對指令**：`compare <C1> <T> --control2 <C2> --samples <08 run>/50_samples.tsv`。
- **判定規則**：
  - 只有 rc 0 是通過。
  - rc 1，而且是下列任一種 ⇒ 失敗，停下回報：
    - `!! DAEMON`；
    - 任何 0x88B5 的 packet-in；
    - `INV BAD`；
    - C1＝C2 的欄位上出現 DIFF。
  - rc 1，但 DIFF 只出現在 C1≠C2 的欄位 ⇒ 加跑 C3、C4，用四個對照組重跑一次比對定案，不再加。
  - rc 2 ⇒ 重跑出問題的那個 run 一次；同樣原因再出現就回報。
  - rc 3 ⇒ 程序沒照做，修正後重跑。
  - H5 的 `where the heartbeat ran` 失敗或 STOP ⇒ T 無效。
- **S4：H4 的 `reported_to_kernel` 風險**：H4 若**只**因為 kernel 不收 Down 交換機的連線回報而失敗，那是 kernel 的發現。它**不改變** external 比對的結論，但要回報。
- **拿掉的兩件事**：
  - 「臂結束時的 switch_state」檢查：06 只在 bring-up 時記一次 switch_state，這件事改由 H4 的 `no_writes` 回答。
  - 需要另外接 driver 的「B 上停掉心跳」對照組。
- **順手改的**：
  - README:24 的舊 worktree 名改成主 checkout，並寫明 KERNEL_DIR 的限制。
  - 08 開頭（:46-49、:56-57）的 OLD_06 說明改成：做 external 比對時設成 C1；074635Z 跑的是別份程式，只能當參考（S2）。

### R3.4 S1、S3、m2、m3

- **S1**（`45ca199e`、`9d9ee602`）：普查的文字、README、test 的敘述，都改成「三個程式是**從 P4 原始碼讀的**」。
  - 段 S 沒有啟動這三臂的控制器（`S_heartbeat_spike.sh:63-65`），所以普查那三列量到的是**空的交換機**。
  - **`PART=h5` 是第一次在程式載入時量。**
  - 「沒有埠 0」是從 bmv2 推論的。
- **S3**：`ndt status` 在 package fabric 上不再說「none expected」。
  - 改成「destination paths reported; not a count of installed routes」，並說明那是在宣告連線上算的最短路徑，是 twin 的猜測。
  - test_ndt_app_package 與它的 M28 跟著改。
- **m2**：main.py 的 N-11 docstring 補上一句：routes 被 own 時，`install_initial_routes` 會從清單上拿掉。
- **m3**：
  - 08 新格：
    - up-told 的 BAD 格（proxy 看到 up、kernel 沒收下）；
    - 只有 `table_generation` 動的 BAD 格；
    - F9 的紅：`v_restore_strict`，19.9 s OK、20.5 s BAD。
  - 03／04 的消費者鎖（test_live_p1_common §18）。
  - evidence 那三格從沒看過紅的：
    - 「沒有單一對照組的警告」改成拒絕（E34）；
    - report 是目錄時「沒有 traceback」（E47）；
    - 「只給一個 run：usage、rc 2」（E46）。
  - `within()` 的 counters_final 那一支（E45）。
- **m4**：已 merge trunk `85bec430`，整套閘門在新 head 上重跑（§R3.6）。

### R3.5 我自己找到的：evidence 還有 11 格從沒被 mutation 看紅（`480e9f2e`）

- **怎麼發現的**：第一次在 `9d9ee602` 上跑閘門時，我寫了一支只讀的覆蓋檢查（OBSERVED）。
  - 它把 50 個 E mutant 的完整 suite 輸出，逐格（按位置，因為名字會重複）對上 base 工具下綠的 67 格。
  - 結果：有 **11 格**沒有任何 mutant 能看紅。
- **這 11 格**：
  - 三個 rc 0 的對照；
  - `show` 的 rc 0；
  - 「處理組是對照組」；
  - 「0x88B5 的 packet-in：rc 1」；
  - 「verdict 變了：rc 1」；
  - 「解析不了的 packet-in：rc 2」與它的原因格；
  - 兩格程式身分；
  - 「對照組沒有 venv 指紋」那一格。
- **它們在哪裡看過紅**：
  - 10 格在 red first 看過紅：沒有工具時紅，或在 `17e40e29` 的工具上紅（後者部分是因為舊工具不認得新參數、argparse 回 2）。
  - 「解析不了的 packet-in：rc 2」在這個 head 的 suite 上**哪裡都沒看過紅**。第二輪 suite 的同一格在 extb2 看過紅。
  - 所以 `redfirst_b3` 裡「the evidence gate's E mutants kill each」那句在 `9d9ee602` 上是**錯的**。
- **我怎麼處理**：
  - 停掉 `9d9ee602` 的 driver（停在 mutate_p4_heartbeat_w 途中；那份 log 的最後兩行寫明是我停的、不是結果）。
  - 補了 `480e9f2e`，只動兩個 test 檔。
- **`480e9f2e` 補的 mutation**：E50–E60，每一格各一個。
  - 兩格是好幾個 guard 同時守著，所以那個 mutant 一次拿掉那一格的全部 guard：
    - 0x88B5 的 packet-in 由 packet-in 數、兩個比對鍵、IPv4 不變式四處同時抓到。E51 讓讀 log 的地方看不到那一幀的兩行。
    - verdict 變了由 rc 與 verdict 兩個鍵同時抓到。E52 兩個都拿掉。
  - rc 0 的對照也各有一個 mutant：E56 每次比對都判差異；E57 讓 `show` 拒絕。
- **「處理組是對照組」那格改寫了**：原本跑的其實是「同一個對照組給兩次」，跟上一格重複。
  - 現在跑 `compare c1 t1 --control2 c2 --control2 t1`，用拒絕訊息「the treatment is one of the controls」判。
  - 單看 rc 分不出是這個 guard 還是 check_roles 擋下的（處理組有心跳痕跡，當對照組本來就會被拒）。
- **evidence gate 現在自己報覆蓋**：
  - 它保留每個 mutant 的完整 suite 輸出，最後逐格（按位置）檢查每一格至少在一個 mutant 下紅過；有一格沒紅過，gate 就 rc 1。
  - 這個報告本身也看過紅：拿掉 E56 的 gate＝60 個 mutation、0 survived，但 rc 1，剛好點出那兩個 rc 0 的對照（`redfirst_b3` F 段）。

### R3.6 red first、mutation、閘門

**狀態：全部 rc 0，`480e9f2e` DELIVERED（重開機後補完）。**
- 重開機前我在 14:48 停了 extb3 的 driver（orchestrator 通知 15:1x 重開機）：23 個閘門跑完 19 個，mutate_roles_binding 停在第 54 個 mutation（log 最後兩行寫明是我停的，不是結果）。
- 重開機後（15:02）同一個 head 用 `gates_b3r.sh`（tag `extb3r`）補跑沒跑完的 4 個與 tripwire：**全部 rc 0**（下表）。
- extb3 那次沒跑到 tripwire 閘門；它的 shim log（`scripts-extb3-480e9f2e/tripwire.log`）另外用一個 guard 下的小閘門讀過：`nolab_tripwire_extb3log.extb3r-480e9f2e.log`（見下）。

**跑法**：
- driver 是凍結副本 `scratchpad/nolab2/frozen/gates_b3.sh`，tag `extb3`。它是 `gates_b2.sh` 加上：`redfirst_b3`、`selftest_07`、`mutate_ndt_app_package`，以及 trunk 的兩個 ndt suite（`test_ndt_sudo_surface`、`test_ndt_status_check_baseline`，當 merge 檢查）。
- 每個 gate 各取一次 guard 鎖（`JOBS=1 LOCK_WAIT=10800`）；nolab shim 在 PATH 最前面。
- 磁碟下限 1.5 GB，排隊前與拿到鎖之後各查一次：排隊時 4301–4412 MB、鎖下 4301–4412 MB。
- log 在 `logs/gates-0910/<gate>.extb3-480e9f2e.log`。**跑完的 19 份我都讀過**：第一行都是 `480e9f2e2187…`，最後一行都是 `# rc=0`。

| gate | rc | 結果 |
|---|---|---|
| redfirst_b | 0 | ALL-AS-EXPECTED（base `f7e2a128`）；期望集合補了 §19 的 4 格 |
| redfirst_b2 | 0 | ALL-AS-EXPECTED（base `17e40e29`）；更新見下 |
| redfirst_b3 | 0 | ALL-AS-EXPECTED（base `14921f98`）；見下 |
| proxy_unit | 0 | 46 個檔、1674 個 test：1673 passed、1 skipped、0 個檔 FAILED |
| test_ndt_heartbeat / app_package / up_down_robust | 0 | 63/0、395/0、424/0 |
| test_ndt_sudo_surface / status_check_baseline（trunk 的，merge 檢查） | 0 | 55/0、112/0 |
| selftest_08 / selftest_07 | 0 | SELF-TEST PASS / SELF-TEST PASS |
| test_live_p1_common / thirteen / external_evidence | 0 | 220/0、45/0、103/0 |
| test_drive_exercise | 0 | OK |
| mutate_p4_heartbeat_w | 0 | **233 mutations，0 survived**；新 proxy test 118/118 看過紅；ndt 63 checks 除 12 個 control 外都看過紅。L68、L73b、L76、L77、L78、M28／M28b 各自殺在點名的格 |
| mutate_live_p1_common | 0 | 59 mutations，0 survived（多了 M57：INT／TERM 回到 finish；M58：訊號的 step exit 1）；4 個 control 沒紅 |
| mutate_live_p1_thirteen | 0 | 12，0 survived；1 個 control 沒紅 |
| mutate_live_p1_external_evidence | 0 | **61 mutations，0 survived；每一格都看過紅 103/103**；工具 sha256 前後相同 |
| mutate_roles_binding（extb3r） | 0 | 179 mutations，0 survived；新 test 197/197 看過紅；2 個 control 沒紅 |
| mutate_app_package（extb3r） | 0 | 48 mutations，0 survived |
| mutate_ndt_app_package（extb3r） | 0 | 75 mutations，0 survived（M28 caught，2 個點名的格紅）；4 個 control 沒紅 |
| check_gate_anchors（extb3r） | 0 | 127/127 |
| nolab_tripwire（extb3r） | 0 | **0 lab call(s)**；shim log 1837 行，全是 `file://` |
| nolab_tripwire_extb3log（extb3r） | 0 | extb3 那 19 個閘門的 shim log：236 行，0 個不是 `file://`，**0 lab call(s)** |

- extb3r 的 log 在 `logs/gates-0910/<gate>.extb3r-480e9f2e.log`，我都讀過：第一行都是 `480e9f2e2187…`、最後一行 `# rc=0`；磁碟排隊時 5130–5412 MB、鎖下 5130–5408 MB。

**另外量到的（OBSERVED，都不是閘門）**：
- `check_gate_anchors.py 480e9f2e`（我在 commit 之後直接跑的）：127/127，evidence gate ok(61)。
- mutate_ndt_app_package 在 `9d9ee602` 上的 dry run：跑到 M29 為止都 caught，**M28 caught**（2 個點名的格紅）；之後我停了它。
- 這次 driver 的 shim log（`scripts-extb3-480e9f2e/tripwire.log`）：236 行，全是 `curl … file://`，0 個 lab 呼叫。
- `9d9ee602` 那次的 shim log：76 行，全是 `file://`。
- 這兩個是我直接讀的，不是 tripwire 閘門。

**red first**（OBSERVED，`redfirst_b3.extb3-480e9f2e.log`；base＝第二輪的 head `14921f98`，HEAD 的新格對 base 的程式碼）：
- **08**：
  - 配 base 的 `_common.sh`（M3）：剛好紅 3 格——TERM 在 H1 途中、rc 143、TERM 在 `arm_traps` 之前。base 的行為是 `'PASS 08_heartbeat' (rc 0)`，以及 `arm_step_traps: command not found`。
  - 換回 base 的 sampler、拿掉 `v_restore_strict`（M2、F9）：剛好紅 2 格——restore 19.9 s 是 OK、sampler rows。
  - up-told BAD 格與只有 table_generation 動的格在 base 上是綠的（base 的 `v_links`／`v_no_writes` 已經回答得了），分別由 L73b、L77 看紅。restore 的 BAD 格由 L76 看紅。
  - HEAD 自己的 08 在同一棵樹：SELF-TEST PASS。
- **`_common.sh`**：HEAD 的 test_live_p1_common 對 base 的 `_common.sh`，剛好紅 §19 的 4 格。03／04 拿掉消費者那一行後，鎖讀到的是 `fi`（紅）。
- **proxy**：HEAD 的 test_heartbeat_fabric 對 base 的 main.py，剛好紅 1 條（普查的新說法）。
- **ndt**：HEAD 的 test_ndt_app_package 對 base 的 ndt，剛好紅 1 格（「count is not a reading」）。
- **比對工具**：HEAD 的 suite 對 base 的工具，103 格紅 36 格；我點名的 19 格都紅。
  - 「tunnel counters outside the controls': rc 1」在 base 上是綠的（base 的 `within()` 已經對 `--control2` 算 counters 的 spread），由 E45 看紅。
  - 其他在 base 上綠的格，都由 evidence gate 的覆蓋報告確認在某個 mutation 下紅過（103/103）。
- **F 段**：拿掉 E56 的 evidence gate＝60 個 mutation、0 survived，但 rc 1，點名 #1 與 #101 兩個 rc 0 的對照。所以覆蓋報告自己就能讓 gate 變紅。
- **`redfirst_b`／`redfirst_b2` 在新 head 上的更新**：兩支都是舊 base，HEAD 的測試多了這一輪的新格。每一處改動都在腳本裡印出理由。
  - `redfirst_b` C 段、`redfirst_b2` B 段：補上 §19 的 4 格（base 沒有 `interrupted`）。
  - `redfirst_b2` A 段：
    - N-1 的混合版改對新的 `arm_traps`（handler 現在是 `interrupted`）；期望多了 rc 格（`a TERM'd run exited 0, not 143`）。
    - F4 的混合版多紅 1 格：`H4 up at the proxy, not accepted by the kernel`——`17e40e29` 的 `v_links` 對 up 不看 `reported_to_kernel`。
  - `redfirst_b2` E 段，第三輪改寫了 suite：
    - 第二輪的格改用現在的名字：「a control whose heartbeat was running」拆成兩個對照組拒絕格；「kept by the control」→「kept by every control」；「a daemon that counted」→「a session whose daemon counted」。
    - suite 的每個 `compare` 都帶 `--samples` 與第二個 `--control2`，`17e40e29` 的 argparse 會以 rc 2 拒絕。所以只看 rc 2 的格在那個 base 上是**意外地**綠；對這幾格改看說出原因的那一格（`has`）。
    - 「a controller log that is not UTF-8: rc 2」沒有原因格。它在 extb2 的 `redfirst_b2` log（同一個 base、第二輪的 suite）看過紅。

### R3.7 Commits（`14921f98..HEAD`，first-parent）

- `8c75a618` Merge trunk 85bec430 into feat/external-detect-only-0927
- `fdae10a9` live-p1: INT and TERM fail every step with the signal's exit code
- `45ca199e` external detect-only: source-level wording, status text, H4 and sampler checks
- `a8d11f02` live-p1 external evidence: require H5 samples across each arm, two controls, settled counters
- `9d9ee602` live-p1 README: an executable procedure for the external comparison
- `480e9f2e` live-p1 evidence gate: a mutation for every check, and a report of the ones never red
- B 自己這一輪的改動（`8c75a618..480e9f2e`）：14 個檔，+1052／−388。我逐檔看過清單，也掃過秘密字串，沒有。
- 新增行裡有 5 行 `/home/adam/...`，都在 live-p1 README 的程序段：主 checkout 的路徑與控制器 venv 的路徑。
  - 這個 README 以前沒有這種路徑。
  - 但 trunk 已有 525 個追蹤檔帶著它，03／04／06 本身也有。
  - 而且 `doc/audit/**/*.md` 不進 PR。
  - 要不要改成 `<主 checkout>` 這種佔位寫法，請 orchestrator 決定。

### R3.8 前兩輪報告的更正（judge 列的報告內部不一致）

1. **§4 的 A/A 比對**：「`compare 074635Z 074635Z` 印 NO DIFFERENCE、rc 0」是**第一輪**工具的行為。
   - 第二輪起 A/A 被拒絕（rc 3）；第三輪沒有 `--control2`／`--samples` 也拒絕。
   - 第三輪對 074635Z 跑的是 `show`（rc 0，§R3.1）。
   - §4 那一行已加註。
2. **「狀態」一段的磁碟範圍**：原本寫的「4148–4525 MB」只是拿到鎖之後那一次讀數的範圍。
   - 已改成排隊時 4147–4712 MB、鎖下 4148–4525 MB（與 §0.5 一致）。
3. **§1 的普查**：「現在在段 S 的 20 臂上都啟動」是**預期**，不是事實（F6 已改 main.py 的文字）。要到 `PART=h5` 才量到。§1 那一行已改。
4. **§4 的「以前沒有任何 inter-switch edge」是錯的**。
   - 074635Z 的 external round 報告寫 `kernel: 3 switches in the graph, 12 edges, 3 hosts`（p4runtime_skeleton `.md:202`、flowcache_solution `.md:200`，OBSERVED）。
   - `ndt status` 寫 `links 12 total, 6 down`（`.md:496`）。
   - B 之前沒有的，是 **proxy 自己**的連線：switch_state 的 `"links": {}`（`.md:266`）與 `link_discovery none`。
   - 12 條怎麼分成 host 邊與交換機間的邊，我沒有逐條讀過。
   - §4 那一行已改。
5. **074635Z 的用途**：08 開頭與 README 現在說法一致，它只能當參考；H5 的 OLD_06 設成 C1（§R3.3）。
6. **「三個量過的程式」**（§2、§0.1 F3）已改成「從 P4 原始碼讀的」（S1），兩處都加了註。

### R3.9 重開機後怎麼接（round 3 收尾）

0. **scratchpad 在 `/tmp`，重開機會被清掉**（`tmpfiles.d/tmp.conf` 是 `D /tmp`）。
   - 我已把 `aeg/`（全部 driver 與 red-first 腳本、patch 腳本）、`nolab2/frozen`、`make_shims.sh`、`hbsnap` 與它的 sha256、兩個 driver 的輸出，複製到 `logs/gates-0910/worker-extb-0928/`。
   - 重開機後先複製回 scratchpad 原路徑，因為 driver 寫死了 `SP`。
   - 跑過的腳本本來就各有一份在 `logs/gates-0910/scripts-extb3-*/`。
1. 先確認環境：
   - `git -C <B worktree> rev-parse HEAD` 仍是 `480e9f2e`，而且 `status --porcelain` 乾淨；
   - `df -h /` ≥ 1.5 GB；
   - 沒有孤兒 `ndtwin-build-*` scope。
2. 新 driver `scratchpad/aeg/gates_b3r.sh`（TAG `extb3r`），從 `gates_b3.sh` 複製：
   - 只留 mutate_roles_binding、mutate_app_package、mutate_ndt_app_package、check_gate_anchors、nolab_tripwire；
   - 凍結到 `nolab2/frozen/`，用 setsid 啟動。
   - 預估約 2.5 小時：roles 約 40 分、ndt_app_package 約 90 分。
3. 讀完每份 log（第一行 sha、最後一行 rc、tripwire 全是 `file://`），再把 §R3.6 表格補完。
4. 全部 rc 0 才在 SUMMARY 最後寫 `DELIVERED 480e9f2e…`。

### R3.10 Round 4 計畫（Adam 09-28 14:2x 裁定：B merge 前兩個揭露的缺口都要修；取代 MORNING-QUESTIONS 13 的關閉選項）

同一個分支、round 3 交付之後做。每一項都要先看到紅（red first，對 `480e9f2e`），並且有 mutation。

**項目 1：external 上 twin 不再畫最短路徑的猜測。**
- **要找的地方**（judge 的行號）：api_routes.py ~343、ryu_topology.py ~226-239。
- **改法**：external fabric 上 `/ryu_server/all_destination_paths` 回到「沒有路徑」＝unknown，不是猜測。
  - 宣告的連線照樣餵 topology。
  - NDTwin 自己的 pipeline 不變。
- **文字跟著改**：
  - ndt ~2982、~4013-4031（我在 S3 改成「shortest paths over the package's declared links」的那一段，要改回「external 上不報路徑、不是讀數」）；
  - main.py ~1087、~1097-1107 的註解；
  - topology_manager ~2154；
  - test_declared_links.py ~319 的 test 名稱；
  - README 的 F5 段。
- **測試**：
  - 帶宣告連線的 external fabric 報 0 條 destination path；
  - NDTwin pipeline 的路徑不變（對照）。
- **mutation**：重新打開猜測 ⇒ 紅。放進 mutate_p4_heartbeat_w 或 mutate_roles_binding，看哪個 gate 已經 lay out 那幾個檔。

**項目 2：external 上的心跳預設安全、不是預設開。**
- **規則**：先離線證明載入的程式會丟掉 0x88B5 心跳幀，證明了才啟動；否則不啟動，並在 `ndt` 輸出與 status 欄位說明原因。
- **方法（我選 bmv2，不用 p4testgen）**：
  - 用一個丟棄式的 `simple_switch --use-files`：跑 package 的**同一份編好的 JSON**、同一個 bmv2 build，沒有控制器、沒有表項，走 table-miss 預設動作。
  - 不需要 root、不需要介面：每個埠讀 `N_in.pcap`、寫 `N_out.pcap`。
  - 對每個埠各打一個真的心跳幀（daemon 發的那種 bytes）；所有埠的 `_out.pcap`（**含 package 的 CPU 埠**）都必須是空的，同時讀 bmv2 log 的 egress 決定當旁證。
  - 本機已確認有 `/usr/local/bin/simple_switch`，`--use-files` 可用（`--help`，OBSERVED）。
  - 不選 p4testgen 的理由：它解的是路徑，不是跑同一個 target；而且第二輪 memory 記過「P4Testgen 構不到 clone 取樣路徑」。
- **要避開 lab**：`--device-id` 用不衝突的值、`--thrift-port` 用空的埠、`--notifications-addr` 指到暫存目錄的 ipc；只用 pid 停它，不用 `pkill -f`。
  - 🔴 **要先問 orchestrator**：gate 裡跑這種 simple_switch 算不算「碰 lab」。shim 的 tripwire 名單沒有 simple_switch。
- **注意 CPU 埠**：沒有接 interface 的埠，bmv2 會默默丟掉，所以要接上拓樸的每個埠加上 package 的 CPU 埠。否則「punt 到 CPU」會被誤判成丟棄。
- **cache**：以程式 JSON 的 sha256 為鍵存結果（`~/.cache/ndtwin/heartbeat-drop/<sha>.json`，含方法、埠、bmv2 版本、判定）。
- **接在哪裡**：`ndt` 的 `heartbeat_wanted foreign:*` 分支、`heartbeat start` 之前；只有 external package 需要。
  - 沒通過 ⇒ 不啟動。switch_state 的 heartbeat 區塊寫 not_started 與原因，`link_discovery` 保持 declared。
- **揭露的限制**：只驗 table-miss／預設動作；external 控制器之後裝的表項不在涵蓋範圍內。
- **測試**：
  - 三個 tutorial 的 JSON 通過（照它們的 P4 應該丟）；
  - fixture 程式——一個洪泛未知 ethertype、一個 punt 到 CPU——都不通過、不啟動心跳。fixture 預先編好 JSON 放進 repo，gate 裡不跑 p4c。
- **mutation**：跳過檢查 ⇒ 紅；把 punt 當成丟棄 ⇒ 紅；忽略洪泛 ⇒ 紅。

**round 4 之後**：
- README 的比對程序要補一句「心跳只在檢查通過時啟動」。三個 tutorial 應該會通過，所以程序本身不變。
- live 比對照 Adam 核准的程序 (a)：先跑 trunk 的兩個對照組，再在本地 merge B、不 push 當處理組；compare 通過才 push。

## 0. 第二輪（external judge 對 17e40e29 判 MERGE AFTER FIXES；AEG judge 對 f7e2a128 的 N-1…N-11）

- **Head**：``14921f9887cc59e665cc5926358b063c9bbb772b``。先 `git merge 9ef10250`（trunk：CI clang/TSan、CI-L1；只有 `ndt` 的 usage 一段自動合併，無衝突）＝`c5a7c1bf`，之後在同一分支上加 commit（§0.4）。
- 沒 push、沒碰 lab、沒 sudo；commit 訊息一般工程師寫法、沒有 trailer。

### 0.1 external judge 的 F1–F9

- **F1（比對會空轉）**：`external_evidence.py` 改成 `compare <control> <treatment> [--control2 <run>] [--samples <50_samples.tsv>]`。
  - **拒絕（rc 3）**：處理組任何一臂的 round 報告裡沒有 `ndt up` 的 detect-only 那行、沒有 `heartbeat running (pid, session)` 那一列、沒有 daemon 計數器（switch_state 的 `heartbeat.side_effects`）；給了 `--samples`（H5 的 sampler）時，那個 session 沒被讀到 running、或有任何一筆算到轉給 host／別台交換機的幀。對照組（含 `--control2`）有一臂的心跳在跑也拒絕——A/A 只會印 NO DIFFERENCE。
  - 處理組的 daemon 計數器有任何一個非 0，算差異並說成 ruling 4。
- **F2（基準不是同一份程式、欄位有噪音、有預先準備的說辭）**：
  - 工具與 README 都印出每個 run 的程式身分（報告裡 `code <sha> …`）。**074635Z 是 `5dc7fc9a` ＋ 95 個未提交的檔**（OBSERVED，`p4runtime_solution.log:153`），不是 `f7e2a128`；沒有 venv 指紋。README 寫明它只能當第三個參考。
  - **拿掉**了第一輪 SUMMARY §4 與 README 裡「flowcache 的差異不是心跳造成的」那句預先準備的說辭。
  - **同一個 session 的對照組**：README 寫了程序——C1、C2（同機器、同 venv、三臂各兩次、不跑心跳：trunk 上跑 06，或 B 上 `ndt up` 後停掉心跳）＋處理組 T（B 上的 `PART=h5` 或 06）＋ `compare C1 T --control2 C2 [--samples …]`。落在 C1、C2 之間的算 spread、不計；沒給 `--control2` 時每個 DIFF 都印，並聲明分不出噪音。
  - **每臂的不變式**（與基準無關，judge §5.5／§5.4）：p4runtime/solution 的 s1 ingress 100 ＝ h1→h2 ping ＋ 打到 10.0.2.2 的 iperf 資料報（沒收到 ack 時最多再 10 個 FIN），s2 egress 100 ＝ s1 ingress 100，s1 egress 200 ＝ s2 ingress 200；skeleton 的 s1 ingress 100 ＝ ping、其餘 0；flowcache 的 packet-in 全是 IPv4、每條 cache entry 都是某個 IPv4 packet-in 的 flow。處理組破而對照組守住的算差異；兩邊都破的只列出。074635Z 自己的讀數全部成立（`show`，OBSERVED：3505 ＝ 5 ＋ 3500；skeleton 5 與 0；flowcache 6 個 IPv4 packet-in、5 條 entry 都有對應）。
  - **被截斷的 counter 區塊**（控制器在印的途中被 SIGTERM）＝讀不到（rc 2），不是讀數。
- **F3（揭露）**：README 的 external 段、心跳普查的 summary（switch_state 上看得到）、本 SUMMARY §2 都寫了：這對**每一個**跑自己 pipeline 的 external package 生效；會 punt 或洪泛未知 ethertype 的程式會把 0x88B5 交給**它自己的**控制器或 host，而 proxy（external 上沒有 stream）與 daemon（只數離開交換機埠的幀）都看不到；三個程式從 P4 原始碼讀得到為什麼應該安全（第三輪更正，S1：原本寫「量過的」——段 S 沒啟動它們的控制器，那三列量的是空交換機；flowcache 在 ingress 丟掉非 IPv4；advanced_tunnel 沒有表套到它、egress 埠 0 不存在——後者是從 bmv2 行為**推論**）；其他 external 程式沒人看過。**沒有加關掉的選項**（等 Adam）。
- **F4**：H4 現在要求剪線後與復原後兩個方向的 `reported_to_kernel` 都是 true（`v_links … down-told`／`up-told`），以及每台交換機的 `pipeline_commits`／`rules_timed`／`table_generation` 在剪線、復原前後都沒動（新 `v_no_writes`）。self-test 有 OK／BAD 各格。
- **F5**：`ndt` 的失敗分支在 external 上說 `reroute.reason external_control_plane`（新 suite 格＋ N03d）；`ndt` 的 external verify 段改寫（`all_destination_paths` 在 external 自己的 pipeline 上是在宣告連線上算的最短路徑、是 twin 的猜測，不是 0 也不是讀數——**揭露**，README 同段）；`main.py` 的 `link_discovery` 註解；`topology_manager.py` 的 reroute 分支 log 說出 external 這個理由；`test_declared_links.py` 那條改名為 `test_an_external_fabric_on_ndtwins_own_pipeline_seeds_nothing`（roles gate 的 MN15 跟著改名）。
- **F6**：普查 summary 的「全部 20 臂」改成**預期**：「Since 2026-09-27 `ndt up p4 --app` is EXPECTED to start it on all 20 … not yet measured under ndt (live-p1/08 PART=h5 checks it per arm)」。
- **F7**：讀檔一律包起來——`OSError`／`UnicodeDecodeError` 是 UNREADABLE、rc 2，不再是 traceback ＋ rc 1；非 IPv4 的 packet-in 另計（`non_ipv4_packet_ins`，也在 COMPARED）；**解析不了的 packet-in ＝ 讀不到**。
- **F8**：evidence gate 重寫，**32 個 mutation**：E10–E14 各拿掉一個 COMPARED 的鍵（packet_ins、cache_entries、grpc_errors、rc、verdict），E15 把 ethertype 讀晚兩個 byte；其餘見 §0.3。
- **F9**：H4 的復原以**嚴格 20 s** 判（`fail`），輪詢等到 35 s 只是為了量到晚到的；08 開頭與 README 一致。

### 0.2 AEG judge 的 N-1…N-11（同一批檔、分開的 commit）

- **N-1（live 08 之前必修）**：INT／TERM 各有自己的 trap（`w_interrupted SIGINT 130`／`SIGTERM 143`，`arm_traps`），記下「interrupted by SIG…」再 exit；EXIT trap 照常拆。self-test 新格：TERM 送到 run 自己的 shell、H1 途中、之前沒有任何失敗 ⇒ 最後一行 `FAIL 08_heartbeat -- interrupted by SIGTERM before the run finished`；對照：同一個 harness 不送訊號 ⇒ PASS。
- **N-3**：結論移到 `finish` 之前（netem 先拿掉），註解屬實。
- **N-4**：`v_strict` 在 `d > b + 15` 時回 BAD（不再是 OVER）；H1 的 cycle 標題改成「about 20 s（strict 量並揭露；超過 35 s 判 FAIL）」。self-test 直接測 `v_strict`：19.5 OK、21 OVER、36 BAD。
- **N-5**：`heartbeat_skips_verdict` 在 python 裡接住所有例外、一行 BAD、說出原因；stderr 不合併；直譯器死掉仍有一行 BAD。新格：頂層是 list ⇒ 恰好一行、`AttributeError`；檔案不存在 ⇒ 恰好一行。
- **N-6**：jqp 的註解移回 jqp 上面。
- **N-7**：02:184 的註解改正；新 fixture：not_started ＋兩個名字、沒有 heartbeat 區塊＋兩個名字（M50／M52 真正會放過的兩種）；鎖住 02 下一行的消費者 `[[ "$V" == OK* ]] || fail …`；「不再從 heartbeat.watchdog 挑清單」的鎖改成任何拼法。
- **N-11**：`main.py` 的 docstring（`control_plane.skipped` 的內容）改正。
- **另加**：H3 的 cut-short 格、全部在 20 s 內的早退格（結算、不揭露）、乾淨的 run 完全不出現「cut short」的格。
- **N-9**（driver，不在 commit）：`proxy_unit` 的 passed 只算 OK 的檔、另列 FAILED 的檔數。

### 0.3 red first 與 mutation

**red first**（OBSERVED，`redfirst_b2.extb2-14921f98.log`；base＝第一輪的 head `17e40e29`，HEAD 的新格對 base 的程式碼）
- 08，每個修正各做一個混合版放進 HB W gate 的 ltree：
  - INT／TERM 換回 `w_finish`（N-1）：**剛好紅 1 格**（TERM 那格）；base 的行為就是 judge 說的——`'PASS 08_heartbeat' (rc 0)`。
  - base 的 `v_strict`（N-4）：剛好紅 1 格（36 s）。
  - base 的 `v_links`、拿掉 `v_no_writes`（F4）：剛好紅 2 格（剪線且 kernel 收下、剪線前後沒寫入）。另外三個 F4 格在 base 上是綠的——base 的 `v_links` 對不認得的 want 一律回 BAD，所以兩個 BAD 格與 up-told 的 OK 格恰好綠；它們由 L73、L74、L75 看紅。
  - HEAD 自己的 08 在同一棵樹：SELF-TEST PASS。
  - H3 cut-short、全在 20 s 內的早退、乾淨的 run 三格守的是 base 已有的行為（AEG 的 F1 已在 base 裡），由 L69、L70、L72 看紅。
- `_common.sh`（N-5）：HEAD 的 test_live_p1_common 對 base 的 `_common.sh`，剛好紅 2 格（頂層 list 恰好一行、說出原因）。02 的消費者鎖：拿掉那一行的 02，鎖讀到的是下一行註解（紅）。N-7 的兩個新 fixture 在 base 上本來就 BAD（綠），由 M50、M52 看紅。
- proxy（F3／F6）：HEAD 的 test_heartbeat_fabric 對 base 的 main.py，剛好紅 2 條（普查的預期句、punt 盲點）。
- ndt（F5）：HEAD 的 test_ndt_heartbeat 對 base 的 ndt，剛好紅 2 格。
- 比對工具（F1／F2／F7）：HEAD 的 suite 對 base 的工具，77 格紅 48 格；我點名確認的 9 格都紅（A/A、沒有 detect-only、對照組有心跳、spread、不變式、截斷、解析不了、非 UTF-8、daemon 轉了幀）。在 base 上綠的格全列在 log 裡，都是 base 本來就做到的事或 `hasnt` 格，由 evidence gate 的 E 系列看紅。
- 另外 `redfirst_b`（第一輪的，base＝`f7e2a128`）照樣重跑，期望集合補上這一輪的新格（普查 punt、ndt 的 external 失敗理由、08 的兩個 told OK 格、`_common` 的 N-5 兩格）：ALL-AS-EXPECTED。

**mutation（新的，都 caught）**
- mutate_p4_heartbeat_w：L68（INT／TERM 回到 w_finish）、L69（cut short 一律說 H1）、L70（沒東西也結算）、L71（沒有硬上限）、L72（全在 20 s 內也揭露）、L73（不問 kernel 收下沒）、L74（不看 pipeline_commits）、L75（從不相信 kernel 收下）、M28b（普查不再說其他程式沒人看過）、N03d（external 的失敗理由）；L64 換了 anchor。
- mutate_live_p1_common：M56（只接 KeyError）；M50、M52 多點名 N-7 的兩個新 fixture。
- mutate_live_p1_external_evidence：32 個（E1–E32），見 §0.1 F8。

### 0.4 閘門與 commits

18＋1 個閘門（第一輪的 extb 那一套，加 `redfirst_b2`），tag `extb2`，head `14921f98`，**全部 rc 0**。每個 gate 各自取一次 guard 鎖（`JOBS=1 LOCK_WAIT=10800`）；磁碟下限 1.5 GB，排隊前與拿到鎖之後各查一次：排隊時 4594–4816 MB、鎖下 4594–4817 MB。log 在 `logs/gates-0910/<gate>.extb2-14921f98.log`，**19 個我都讀過**：第一行都是 `14921f9887cc…`，最後一行都是 `# rc=0`。

| gate | 結果 |
|---|---|
| redfirst_b | ALL-AS-EXPECTED（期望集合補了這一輪的新格） |
| redfirst_b2 | ALL-AS-EXPECTED（§0.3） |
| proxy_unit | 46 個檔、1674 個 test：1673 passed（只算 OK 的檔）、1 skipped、0 個檔 FAILED |
| test_ndt_heartbeat / test_ndt_app_package / test_ndt_up_down_robust | 63/0、395/0、424/0 |
| selftest_08 | SELF-TEST PASS |
| test_live_p1_common / thirteen / external_evidence | 211/0、45/0、77/0 |
| test_drive_exercise | OK |
| mutate_p4_heartbeat_w | **229 mutations，0 survived**；118/118 個新 proxy test 看過紅；ndt 63 checks 除 12 個 control 外都看過紅 |
| mutate_live_p1_common | 57，0 survived；4 個 control 沒紅 |
| mutate_live_p1_thirteen | 12，0 survived；1 個 control 沒紅 |
| mutate_live_p1_external_evidence | **32，0 survived**；工具 sha256 前後相同 |
| mutate_roles_binding | 179，0 survived（MN15 用改名後的 test） |
| mutate_app_package | 48，0 survived |
| check_gate_anchors | 123/123 |
| nolab_tripwire | **0 lab call(s)**；shim log 2001 行，全是 `file://`（我逐行確認：沒有一行不是） |

- 與 trunk `9ef10250` 的 `git merge-tree --write-tree 9ef10250 14921f98`：rc 0（乾淨）——trunk 已在 `c5a7c1bf` merge 進來。
- 這一輪的改動（`c5a7c1bf..14921f98`）：17 個檔，+1165／−288；逐檔看過清單、掃過秘密字串與 `/home/adam` 新增行，都沒有。

**Commits（`17e40e29..14921f98`，first-parent）**

- `c5a7c1bf` Merge trunk 9ef10250 into feat/external-detect-only-0927
- `daa4dce4` 08: a TERM'd run fails; hard detection ceiling; one-line heartbeat verdict
- `3a540897` external detect-only: operator text, census expectation, H4 kernel and write checks
- `5c670a97` topology manager: keep the reroute branch's first lines together
- `7b98edbe` live-p1 external evidence: refuse A/A comparisons, control spread, invariants
- `a5e608f5` ndt heartbeat suite: a failed start on an external plane names its reason
- `14921f98` heartbeat gate: a mutant for H4's up-and-accepted cell

### 0.5 第一輪報告的更正

- X mutant 沒有 X4：是九個有編號的（X1–X3、X5–X10）加 X2b、X3b。
- 「剛好紅 8 條」＝ log 的 `failures=8, errors=1`：7 條 FAIL（其中一條有兩個 subtest 失敗，所以算 8 個 failure）＋ 1 條 ERROR（`not_started` 讀自不存在的 heartbeat 區塊）。
- 磁碟：「4148–4525 MB」只是**拿到鎖之後**那一次讀數的範圍；排隊前的讀數是 4147–4712 MB。
- 第一輪 §7「kernel 那側在 live 06 看得到」是錯的：06 從不剪線；現在由 H4 的 `reported_to_kernel` 負責（F4）。
- 第一輪 §4 的「flowcache 的差異不是心跳造成的」那句已刪（F2）。

## 狀態

**已交付。**
- 18 個閘門全部 rc 0（§5）。driver 是凍結副本 `scratchpad/nolab2/frozen/gates_b.sh`，tag `extb1`；每個 gate 各自取一次 guard 鎖（`JOBS=1 LOCK_WAIT=10800`）；磁碟下限 1.5 GB（orchestrator 09-28，這批沒有 C++ build），排隊前與拿到鎖之後各查一次：排隊時 4147–4712 MB、鎖下 4148–4525 MB（第三輪更正：原本只寫了鎖下那一個範圍）。
- 與 trunk `149c8234`（已含 AEG `f7e2a128`）的 `git merge-tree --write-tree 149c8234 17e40e29`：rc 0，乾淨（tree `d4cbec9d`）。所以沒有再 merge trunk、閘門不必重跑。
- 途中的事：
  - AEG 被判 MERGE AFTER FIXES 時我停了 B，修完 AEG（`f7e2a128`）再 merge 進 B（`b01ad9b9`）。唯一衝突是 test_live_p1_common 的 §17（B 的指紋）與 §18（AEG 的 N1），兩段都留。
  - merge 之後把 AEG 的 F2 原則套到 external 那行 log、把 N1 的原則套到 03／04（見 §1）。
  - `check_gate_anchors` 在我改 main.py 之後抓到三個 gate 的 anchor 失效：mutate_roles_binding 的 R6／R2-8a（external 分支用了同一行 seed，anchor 變兩處）、R2-8b（`capabilities_for` 的順序改了）、MN15（註解改了），以及 HB W gate 的 N12／N29（rc 0 那一行改了）。都改成唯一且指到原本意圖的位置；我新寫的 evidence gate 一開始把 label 放在第一個參數，checker 讀成 anchor，改成 anchor 在前。修完 122/122。

## 1. 改了什麼（照核准的設計）

**proxy（`p4_proxy/proxy_agent/main.py`）**
- external control plane **跑自己的 pipeline** 時（06 的 p4runtime 兩臂、flowcache/solution），startup 現在跟外來 fabric 一樣宣告 package 的連線（`_seed_declared_links`，`declared_links=True`），並啟動心跳 watchdog。
- **只偵測、不改路由、不寫交換機**，兩層各自成立：
  - 這個 fabric 的 client 沒有 arbitration，`_refuse_write` 拒絕每一種寫入（原本就是）；
  - `install_initial_routes` 仍在 `control_plane.skipped`，所以 `routes_to_attached_hosts_only` 是 True，watchdog pass 走「告訴 kernel、不 reroute」那條分支（`topology_manager.run_watchdog_pass`）。
- `reroute` 永遠 false，理由**保留** `external_control_plane`：`_fabric_reroute` 先問 `external`，再問心跳。detail 跟著心跳現況走：心跳 usable 時寫「cut 會被偵測並告訴 kernel、不改路由」，不 usable 時寫「watchdog 在跑但報告不可用，偵測不到」。
- `capabilities.link_discovery`：`declared`（心跳 usable 時 `heartbeat`）；`none` 只留給 **NDTwin 自己 pipeline 上的 external**（那種 fabric 照舊：不宣告、不跑心跳；helper 拒絕 NDTwin 的 pipeline，ndt 也不啟動）。啟動前的預測（`_capabilities_blank`）同樣改。
- 裁決 E 同樣適用：心跳 watchdog 起來時 `link_watchdog` 不在 `skipped`，沒起來就列著。
- 啟動 log：external 那行不再宣稱「不 watch links」；Skipped 清單改在心跳決定**之後**另印一行（F2 的原則套到 external），和 `control_plane.skipped` 一致。
- 心跳普查（`HEARTBEAT_CENSUS.summary`）：`ndt up p4 --app` **預期**在段 S 的 20 臂上都啟動，其中 3 個 external 只偵測（第三輪更正：原本寫成事實；F6 已把 main.py 的文字改成預期，要到 `PART=h5` 才量到）。

**ndt**
- `heartbeat_wanted` 改成所有 `foreign:*` pipeline（含 external）；external 時 rc 0 的訊息寫 detect only、不 reroute、控制器擁有所有表。

**live-p1**
- 08 H4 改寫：`ndt up` 說 detect only、helper `heartbeat status` rc 0、switch_state 心跳 usable、capabilities `reroute: false`／`link_discovery: heartbeat`、`reroute.reason` 仍是 `external_control_plane`、四個 `/stats/flowentry/*` 仍是 409；剪 s1-s2（p4runtime 的 tunnel 100 走的那條，先對 package 模型確認存在），**proxy 自己**（switch_state 的 `links`）兩個方向 down、來源 heartbeat，約 20 s 內（超過揭露、不判 FAIL）；剪著時 reroute 仍 false；復原後兩向 up、沒有殘留 netem、ruling 4（沒有心跳幀離開 host 埠）。
  - 🔴 H4 **不看 kernel 的 graph**：08 沒跑 exercise 的控制器，pipeline 沒載入，twin 把這些交換機判 down（03 在 09-18 的讀數）。exercise 自己的證據要看 live 06 的比對（§4）。
- `HB_ARMS` 17 → 20（加 p4runtime／skeleton、solution、flowcache／solution），H5 的 `OLD_06` 預設改成 `2026-09-27T074635Z_06_thirteen`（與 185505Z 逐臂 rc／verdict 相同，我對過）。
- 03／04：`heartbeat_skips_verdict` 斷言 `heartbeat.watchdog` 是 `running`（N1 的原則，不是讀它來挑清單），再要求五個名字（沒有 link_watchdog）。
- **venv 指紋**（你的答覆 3）：新 `live-p1/venv_fingerprint.sh`，每個 `start_step` 的 raw 與 06 的 raw 都寫 `00_venv.txt`——proxy venv 與控制器／driver 直譯器各一段：路徑、resolve 到哪、Python 與 prefix、protobuf 版本與 `api_implementation`、grpcio、全部已裝套件（排序）與其 sha256。取不到就揭露成 NOTE，不判 FAIL。以 importlib.metadata 讀，不跑 pip、不連網。
- **比對工具**（你的答覆 2）：新 `live-p1/external_evidence.py compare <基準 06> <新 06>`，從三臂各自的控制器 log 讀 exercise **自己的**證據逐項比：p4runtime 的每條安裝規則與**最後一次** tunnel counter（封包＋位元組）；flowcache 的 packet-in 數、cache entry、ethertype 為 0x88B5 的 packet-in（＝心跳幀到了 exercise 的控制器）；三臂的 rc／verdict、gRPC 錯誤數。counter 讀了幾次只列不比。兩邊的 venv 指紋一併印。rc 0 沒差異、1 有差異（逐項列出）、2 讀不到。
- README 加一段：怎麼跑比對、指紋是什麼。

## 2. 設計上的取捨（請看）

- **NDTwin pipeline 上的 external 不動**：與 ndt 的 `foreign:*` 條件、helper 的拒絕一致。它沒有可以判的宣告連線，心跳也起不來。
- **一個守門、一個理由**：「不改路由」只靠 `routes_to_attached_hosts_only`（由 `skipped` 決定），沒有在旁邊再加一個 `external` 的條件——那是 M19 的教訓（兩個 guard 互相遮蔽、mutant 殺不到）。寫入層的 `_refuse_write` 是另一層、另一個理由（線上不能有 RPC），各有自己的測試／mutant。
- **H5 的基準換成 074635Z**：你指定的 no-heartbeat 基準；rc／verdict 與原本的 185505Z 逐臂相同。
- 🔴 **看不到的地方（第二輪加，F3）**：這對**每一個**跑自己 pipeline 的 external package 生效（helper 只拒絕 `ndtwin_switch.json`）。會把未知 ethertype punt 給控制器或洪泛的程式（例如 L2 學習型控制器）會把 0x88B5 交給**它自己的**控制器或 host，proxy（external 上沒有 stream）與 daemon（只數離開交換機埠的幀）都看不到。從 P4 原始碼讀得到為什麼應該安全的只有三個（第三輪更正，S1：原本寫「量過而且」；段 S 沒有啟動這三臂的控制器，普查那三列量到的是**空的交換機**，`PART=h5` 才是第一次在程式載入時量）：flowcache/solution 在 ingress 丟掉不是 packet-out 也不是 IPv4 的幀（`flowcache.p4:251-257`）；advanced_tunnel（p4runtime 兩臂）沒有表套到它（`:170-180`），`egress_spec` 停在 0、沒有埠 0 ⇒ 被丟（從 bmv2 行為**推論**），tunnel counter 只在 tunnel action 裡動、沒有控制器 header；段 S 的普查在這三臂上 host 0 幀、`forwarded_between_switches` 0、`misdelivered` 0（空交換機上的讀數）。其他 external 程式沒人看過；關掉的選項等 Adam。
- **twin 那側的另一個改變（第二輪揭露，F5）**（第五輪更正：這段只對第二、三輪成立；第四輪 §R4.1 起 external 上**不報任何路徑**）：external 自己的 pipeline 上，`/ryu_server/all_destination_paths` 現在是在宣告連線上算的最短路徑（沒有已安裝的路由可讀），**不是** exercise 真正的轉發——是猜測，不是讀數。

## 3. 測試與 red first

**新測試**
- `p4_proxy/tests/test_heartbeat_fabric.py`：
  - 新 class `AnExternalControlPlaneOnItsOwnPipelineDetectsOnlyTest`（10 條）：宣告連線並啟動心跳 watchdog；route writer 保持 skip（一刀剪下去不改路由）；沒有任何 client 被要求寫入；心跳 usable 時 reason 仍是 `external_control_plane`、detail 說偵測得到、capabilities 是 false／heartbeat；**每張表都綁 ndtwin 時也不 reroute**；心跳不 usable 時是 declared、detail 說偵測不到；link_watchdog 在心跳驅動時不列；心跳 watchdog 沒起來就六個都列；啟動前的預測說 declared；external 那行 log 的 Skipped 就是 switch_state 那份。
  - 新 class `AnExternalFabricsCutIsToldAndRewritesNothingTest`：startup 在 external 上留下的 flag 交給**真的** TopologyManager（pod-topo、真的報告檔），剪一條：kernel 收到 link_failure、route installer 沒被呼叫。
  - `test_an_external_fabric_does_not_start_it` 改名 `…_on_ndtwins_own_pipeline_does_not_start_it`（並斷言沒有 seed）；普查那條改成 20 臂、detect only。
- `tests/shell/test_ndt_heartbeat.sh` §2b：external 上 `heartbeat start` 恰好一次、在 topo-start 之後 proxy 之前、訊息說 detect only、不說 routed around；非 external 的外來 fabric 不被說成 detect only。
- 08 self-test：H4 的 `links`／`model_has` 兩個新判定各有 OK／BAD 格；HB_ARMS 20 且含三個 external 臂；H5 的 fixture 改 20 臂。
- test_live_p1_common §17（start_step 的指紋，含取不到時的揭露）、§18 的 external 五名格與 03／04 的原始碼鎖；test_live_p1_thirteen（06 的指紋）；新 `tests/shell/test_live_p1_external_evidence.sh`（34 格，合成 fixture 取自 074635Z 三臂控制器 log 的形狀）。

**red first**（OBSERVED，`redfirst_b.extb1-17e40e29.log`；base＝B 合進來的 AEG head `f7e2a128`，HEAD 的測試對 base 的程式碼）
- proxy：HEAD 的 `test_heartbeat_fabric.py` 對 base 的 main.py，**剛好紅 8 條**——宣告與啟動、usable 時的 reason／detail、不 usable、link_watchdog、預測、external 那行 log、普查、以及「心跳 watchdog 沒起來就六個都列」（base 上 external 根本沒有 heartbeat 區塊可讀）。
  - 另外 5 條在 base 上**是綠的，這是對的**：它們守的是 external 本來就不做的事（不改路由、不寫、綁 ndtwin 也不 reroute、真 TopologyManager 剪一條不 install、NDTwin pipeline 上的 external 不啟動）。它們由 gate 的 X2／X2b／X3／X8／M01b 看紅。
  - 同一棵樹換回 HEAD 的 main.py：40 tests OK。
- ndt：HEAD 的 `test_ndt_heartbeat.sh` 對 base 的 ndt，剛好紅 3 格（恰好一次、順序、detect only）；「非 external 不說 detect only」在 base 上綠（base 根本沒有那句），由 N03c 看紅。
- 08：HEAD 的 08，換回 base 的 HB_ARMS、拿掉兩個新判定，剛好紅 6 格（H4 三個 OK 格、H5 的 OK 格、HB_ARMS 兩格）。
- `_common.sh`：HEAD 的 test_live_p1_common 對 base 的 `_common.sh`，剛好紅 §17 的 6 格；03／04 的原始碼鎖對 base 的 03／04 讀出紅的值（0，要 1）。
- 06：HEAD 的 test_live_p1_thirteen 對 base 的 06，剛好紅 3 格（指紋）。
- 比對工具：沒有工具時 34 格裡 4 格是綠的（兩個 `hasnt` 與兩個「rc 2」——沒有檔案時 python 恰好也回 2）。這 4 格由 evidence gate 的 E3、E4、E9 看紅。

## 4. 合併前的 live 比對（你跑）

- 基準：`live-p1/runs/2026-09-27T074635Z_06_thirteen`。**我讀過它（OBSERVED）**：三個 external 臂的控制器 log 都在各自的 round 目錄（`doc/audit/.../runs/2026-09-27T0811{31,205}Z_p4runtime_*_ndtwin/`、`...081256Z_flowcache_solution_ndtwin/`），裡面有 tunnel counter 與 packet-in／cache entry 行；**沒有** venv 指紋（早於這個改動）。
- `external_evidence.py compare <074635Z> <074635Z>`（我對它自己跑過）：`NO DIFFERENCE`，rc 0——**那是第一輪的工具**（第三輪更正）。第二輪起 A/A 被拒絕（rc 3），第三輪沒有 `--control2`／`--samples` 也拒絕；第三輪對 074635Z 跑的是 `show`（rc 0）。074635Z 的讀數：p4runtime/solution 最後 counter `s1 ingress 100 = 3505 packets (4347490 bytes)`、`s2 egress 100 = 3505 (4361510)`、`200` 兩個各 7；p4runtime/skeleton `s1 ingress 100 = 5 packets (490 bytes)`，其餘 0；flowcache/solution 6 個 packet-in、5 條 cache entry、0 個 0x88B5、**1 個 gRPC 錯誤**。
- 074635Z 的 flowcache/solution 控制器在第 6 個 packet-in 後 gRPC UNKNOWN 死掉（OBSERVED；iperf 到 h3 沒送達、G1 卻判 PASS——G1 單）。~~新的一輪若控制器沒死，packet-in／cache entry 會因此不同，那不是心跳造成的~~——**第二輪刪掉**（external judge 的 F2：這是預先準備的說辭，讓那一臂的比對不可能失敗）。那一臂的差異要落在同 session 對照組的離散之外才算（§0.1）。
- 建議的 H4 式檢查：`NDT_OWNER=<你> bash .../08_heartbeat.sh`（H1–H4；H4 是 external 只偵測），以及 `PART=h5`（06 一次＋sampler，20 臂）。
- **預期會變的（twin 這一側，是功能本身，INFERRED）**：external 臂上 proxy 會宣告交換機間的連線並由心跳判斷（~~以前沒有任何 inter-switch edge~~——**錯的**，第三輪更正：074635Z 的 round 報告寫 `kernel: 3 switches in the graph, 12 edges, 3 hosts`、`ndt status` 寫 `links 12 total, 6 down`；B 之前沒有的是 **proxy 自己**的連線，switch_state 的 `"links": {}`）；`link_discovery` 從 `none` 變成 `heartbeat`／`declared`；`control_plane.skipped` 少了 `link_watchdog`；switch_state 多了 `heartbeat` 與 `declared_links` 區塊。kernel 若因此想在 external 上寫表，proxy 回 409（原本就是）。這些都可能讓 twin 那側的讀數（例如 06 的 G1 link usage）跟基準不同——**不是** exercise 自己的轉發結果；判斷看 `external_evidence.py` 那張表。

## 5. 閘門

全部經 guard，每個 gate 各自取一次鎖，nolab shim 在最前面，driver 從凍結副本執行，tripwire 放在最後。log 在 `logs/gates-0910/<gate>.extb1-17e40e29.log`，**18 個我都讀過**：第一行都是 `17e40e2972f9…`，最後一行都是 `# rc=0`。

| gate | rc | 結果 |
|---|---|---|
| redfirst_b | 0 | §3，ALL-AS-EXPECTED |
| proxy_unit | 0 | 46 個檔、1672 個 test：1671 passed、1 skipped（`test_p4_client.py`，`NDTWIN_L1_OPT_IN`）；test_heartbeat_fabric 40 passed |
| test_ndt_heartbeat | 0 | 61/0 |
| test_ndt_app_package | 0 | 395/0 |
| test_ndt_up_down_robust | 0 | 424/0 |
| selftest_08 | 0 | SELF-TEST PASS |
| test_live_p1_common | 0 | 204/0 |
| test_live_p1_thirteen | 0 | 45/0 |
| test_live_p1_external_evidence | 0 | 34/0 |
| test_drive_exercise | 0 | OK（它 source `_common.sh`） |
| mutate_p4_heartbeat_w | 0 | **219 mutations，0 survived**；117/117 個新 proxy test 看過紅；ndt 61 checks 除 12 個 control 外都看過紅。X1–X10、X2b、X3b、N03／N03b／N03c、N12、N29、M01b、M28、L64–L67 各自殺在點名的 test／check／case |
| mutate_live_p1_common | 0 | 56 mutations，0 survived（多 M54 指紋沒取、M55 沒揭露）；4 個 control 沒紅 |
| mutate_live_p1_thirteen | 0 | 12 mutations，0 survived（多 M12：06 不取指紋）；1 個 control 沒紅 |
| mutate_live_p1_external_evidence | 0 | 9 mutations，0 survived（E1–E9）；工具 sha256 前後相同 |
| mutate_roles_binding | 0 | 179 mutations，0 survived；196/196 個新 test 看過紅；R6、R2-8a、R2-8b、MN15 用新 anchor 照樣 caught |
| mutate_app_package | 0 | 48 mutations，0 survived（它 anchor 在 main.py 的 external 那幾行） |
| check_gate_anchors | 0 | 122/122 |
| nolab_tripwire | 0 | **0 lab call(s)**。shim log 1980 行，全是 `curl … file://…`（我逐行確認：沒有一行不是 file://） |

- 沒跑、也不在這批的：07 self-test（B 沒改 07）；其餘讀 ndt 的 gate（B 只改了 ndt 的心跳那幾行，anchor 由 check_gate_anchors 確認都還在）。

## 6. Commits（`ebe17f7c..HEAD`，first-parent）

- `6f14bcff` proxy, ndt: detect link cuts on external control planes
- `66a81c4f` live-p1: venv fingerprints in every raw; compare external arms' evidence
- `b01ad9b9` Merge fix/rulings-aeg-0927 into feat/external-detect-only-0927
- `a693acab` external detect-only: log line, 03/04 assertion, mutation gates
- `c9364849` live-p1 evidence suite: an unreadable arm prints no conclusion at all
- `f1cf5bac` live-p1 evidence gate: E3 also names the IPv4 punt check
- `48d8324d` gates: anchors that stay unique after the external seeding branch
- `17e40e29` heartbeat gate: N12 and N29 anchor on the rc-0 branch as it reads now
- （`b01ad9b9` 是 merge `fix/rulings-aeg-0927`（`f7e2a128`）；B 自己的改動＝`f7e2a128..17e40e29`：20 個檔，+1286／−88；我逐檔看過清單，並掃過秘密字串，沒有。）

## 7. 開放項目

- 08 H4 的新流程、03／04 的新斷言、06 與 start_step 的指紋都要到下一次 live 才會真的被執行到；self-test 與 suite 涵蓋的是函式與 stub，不是 fabric。
- H4 只看 proxy 的偵測，不看 kernel graph（理由見 §1）。~~kernel 那側的「告訴 kernel」在 live 06 … 才看得到~~——**錯的**（06 從不剪線）；第二輪起 H4 要求 `reported_to_kernel` 在兩個方向、剪線後與復原後都是 true（§0.1 F4）。
- `_common.sh` 的 `record_venvs` 預設控制器直譯器是 `/home/adam/p4dev-python-venv/bin/python`（與 03／06 既有的預設同一個路徑，`CTRL_PY` 可改）。
- restore 仍以嚴格 20 s 判（AEG 的 N2，等 Adam）。

（第一輪交付的是 `17e40e29`；第二輪見 §0。）

DELIVERED 14921f9887cc59e665cc5926358b063c9bbb772b

（上面那行是第二輪的。）

第三輪（§R3）：extb3 的 19 個加 extb3r 的 4 個與兩個 tripwire，全部 rc 0。

DELIVERED 480e9f2e2187eb814708e003c81eb313fe1fb5cf

第四輪（§R4）：head `faf6eb410c2cb0b38b06c86000bdc65b21c8ac7a`，已 commit；21 個閘門 rc 0，還有 5 個沒跑（§R4.3、§R4.6）——**尚未 DELIVERED**。（第五輪更正：這是 09-28 21:2x 的狀態；~~21~~ 22 個，另外 5 個 10-01 補跑完，27 個全部 rc 0，round 4 DELIVERED faf6eb41——§R5.6。）

## R5. 第五輪（round-4 review 對 faf6eb41 判 MERGE AFTER FIXES：M-1..M-5、S-1..S-9、nits；orchestrator 10-01 的裁定）

[Co-developed with claude code -- Adam]

- **接手**：前一個 worker 不在了，這一輪是另一個 worker 接著做（同一個 worktree、同一個分支）。
- **Head**：`4c18bf3da29efed3d2f36abd2db67d8f780a222b`。
- **merge-tree 的基準**：最後是 trunk `1e350bf2`。第一次：`git merge-tree --write-tree d452d111 faf6eb41` 預測 tree `62979b4d`，實際 merge（`2469c2a2`）就是 `62979b4d`（OBSERVED，notes:3）；第二次：`git merge-tree --write-tree 1e350bf2 cc798de2` 預測 `24286ec3`，實際 merge（`4c18bf3d`）就是 `24286ec3`（notes:48）。交付前再查：`git rev-parse trunk`＝`1e350bf2`（已在 HEAD 裡），`git merge-tree --write-tree trunk HEAD` rc 0、tree `24286ec3`。
- 沒 push、沒 merge 進 trunk、沒 sudo、沒碰 lab（沒有 `ndt up/down/claim`、mininet、lab 的 bmv2）、沒碰主 checkout（只**讀**了主 checkout 裡未追蹤的 raw：34 個舊 round 與段 S 的普查）。丟棄式交換機只在裁定的條件下、全部經過會拒絕的 wrapper。
- commit 訊息照規矩：一行標題、幾句話、沒有 trailer、沒有禁用字。
- 我的 findings log：`logs/gates-0910/extb5-notes.log`（下面的 `notes:N` 都指它）。

### R5.1 M-1：H5 的參考是一個完整的 06（`868e4ed0`）

- **改法**：對照組 C1／C2 改成**不加 `ONLY=`**、完整的 06（README 程序第 1 步）。08 的前導段在 `PART=h5` 時數 `OLD_06/00_table.tsv` 的臂數，不是 26 就 `REFUSED 08_heartbeat -- OLD_06 is not a whole 06`、rc 2，什麼都還沒跑。
- 這也讓 C 與 T 跑**同一個臂序**（review 列的另一個風險）。
- **H5 的判準改寫**（README，預先登記）：`H5 where the heartbeat ran` 必須 OK、沒有 STOP；`H5 06 against <C1>` **只回報**——verdict 在 34 個舊 round 裡會自己翻（S-9），所以它讓 08 的最後一行變 FAIL 是可能的，不改變判定。README:282 那一列加了這句。
- **self-test 新格**（OBSERVED，selftest_08 log）：
  - `🔴 H5 against the control C1 as the README runs it (a whole 06)`：OK（26 臂、別的 stamp 與 report 路徑）；
  - `H5 against a 4-arm ONLY= control`：BAD `the reference table has 4 arms, not 26`；
  - `🔴 PART=h5 with a 4-arm OLD_06 (an ONLY= 06): refused (rc 2) before anything ran`；
  - `PART=h5 with a whole 06 as OLD_06 goes through the prelude, and keeps it`。
- **看過紅**：L79（拒絕拿掉）紅在點名的格；L79b（rc／verdict 連 report 路徑一起比）讓 C1 那格紅（mutate_p4_heartbeat_w log）。

### R5.2 M-2：本地 merge 的程序（`868e4ed0`、`79235fac`）

- **新 `live-p1/code_identity.py`**：
  - `record <repo> <out>`：HEAD 與 parents、merge 帶進來的檔（`merge_changes`）、未提交的追蹤檔（狀態、路徑、磁碟上內容的 sha256）、kernel（`build/bin/ndtwin_kernel`）、fabric 的 bmv2（override 指的那顆）、drop check 的 stock bmv2、安裝的 helper 的 sha256、兩個 venv 的 distributions sha。
  - `verify <C> <T> <B sha>`：T 必須是兩個 parent 的 merge，第一個＝C 的 HEAD、第二個＝B；未提交的檔、binary、venv 都相同；未提交的檔裡沒有 B 也改的。
  - 未追蹤的檔**不記**（每個 live run 都在 `runs/` 加 raw）——揭露在 README 與 docstring。
- **06（B 的）**每次開跑寫 `00_identity.txt`；trunk 的 06 不寫，README 第 1 步在每個對照組跑完立刻手動補記。
- **compare** 必須帶 `--b-sha`；所有對照組的身分必須相同，T 必須 `verify` 通過——否則 rc 3。
- **08 `PART=h5`** 給了 `C_IDENTITY`＋`B_SHA` 時，06 開跑前先記錄並 verify，不通過就 rc 2。
- **README 程序**（預先登記）：第 0 步凍結 trunk（orchestrator 的裁定）；第 1 步 C1、C2 與補記；第 2 步 `merge --no-ff`，衝突就 `merge --abort`；第 3 步 T 帶 `OLD_06`、`C_IDENTITY`、`B_SHA`；第 4 步 compare 帶 `--b-sha`；第 5 步通過才 push、解凍；失敗或放棄就 **`git reset --keep <C_HEAD>`，永遠不是 `--hard`**，回復後核對 HEAD 與未提交清單。
- **看過紅**：
  - compare 的身分格（沒有 `--b-sha`、對照組沒有身分、HEAD 不同、T 合到別的 trunk、合的不是 B、不是 merge、單一 parent、沒記 merge_changes、未提交的檔不同、kernel 不同、B 也改的檔）：E69–E72、I1–I8，每個殺在點名的格（evidence gate log）。
  - 08 的 identity gate 在一個**真的** git repo 上（C、B 分支、本地 merge、主 checkout 那樣有一個別人未提交的檔）：通過的那格與四個拒絕格（另一個 B、沒有 B_SHA、checkout 裡多了一個改動、HEAD 又往前走）；L82–L85 殺（mutate_p4_heartbeat_w log）。
  - 06 記身分：test_live_p1_thirteen 新格，M13 殺；redfirst_b5 E 段對 faf6eb41 的 06 紅。

### R5.3 M-3：每個方向都要聽到（`868e4ed0`）

- **sampler** 每一列多兩欄：`heard`（每個方向 `tx>rx=次數`）與 `controllers`（當下 argv 跑著 `run_external_controller.py` 的 pid，讀 /proc）。
- **compare**：用 round 報告裡 drive_exercise 的那一行 `controller pid N (handed to the generic cell…)` 找出控制器；它在處理組 session 那段裡被 sampler 看到的那些 sample＝它的生命期（至少 2 個）；每個方向的 `heard` 在第一個與最後一個之間都必須增加——否則 rc 3（`did not hear k of n direction(s) while the controller (pid N) ran`）。報告裡沒有唯一的 controller pid、控制器沒被看到、方向集合變了，也都拒絕。
- 順手關掉 review 列的殘留：running sample 裡**不是數字的計數器**原本讀成 0，現在 rc 2；`heard` 不是數字也 rc 2；第四輪的 sampler 檔（10 欄）rc 2。
- **看過紅**：E61–E68 各殺在點名的格；08 sampler 的兩格（12 欄、controllers 欄真的看到一個假控制器的 pid、只在它活著時）由 L80、L81 殺；redfirst_b3 對 14921f98 的 sampler 紅在 controllers 那格。

### R5.4 M-4：mutant 不再啟動違反條件的交換機，tripwire 會擋（`bdc1a12f`）

- **suite**（test_heartbeat_drop_check.py）：
  - argv 的性質（argv[0]、helper 的 sweep、p4_testbed_topo 的名字、kernel 的 scan、沒有 simple_switch_grpc、`ipc://notif.ipc`、pcap 與 log 相對路徑、自己的目錄、CPU 埠也接上、Thrift 埠、device id ≥ 900000）改在一個 **recorder** 上斷言——recorder 取代 `Launch.start`，什麼都不啟動。
  - 只有需要**跑著的程序**的格（uid、comm、bmv2_count、身分規則、socket 存在、停掉、目錄刪掉）才真的啟動，而且經過 **guard**：這個 process 裡每一次 `Launch.start` 都先比對裁定的條件（argv[0]、沒有 `simple_switch*` 參數、Thrift 29400–29499、device id ≥ 900000、`ipc://notif.ipc`、相對的 log、`N@pN` 的 pcap、自己的 `ndt-hbdrop-*` 目錄、不是 root；在閘門裡 executable 必須是 `NDT_HB_CHECK_BMV2` 的 wrapper），不合就**不啟動**、記下來，最後一格紅。`--version` 也一樣（argv[0] 不對、或在閘門裡不是 wrapper 的路徑，就不跑）。SIGKILL 探針與 SIGTERM 子程序跑同一份 guard。
  - section 8、9 的子程序沒有 guard：只有 section 7 的 recorder 確認工具的 launch 乾淨時才跑，否則每一格照樣印（位置對得上），標成 not run。
- **wrapper**（`extb5/make_hbwrap.sh`，閘門的 `NDT_HB_CHECK_BMV2`／`NDT_HB_CHECK_FABRIC_BMV2`）：每次呼叫寫一行（pid、start time、uid、argv0、cwd、exe、args），**違反就不 exec、rc 97、寫 `REFUSED-LAUNCH`**。fabric 那顆只准 `--version`。自我檢查：五種違反各 rc 97、一個合法的 `--version` rc 0（`extb5/wrapper_selfcheck.log`）。
- **tripwire 閘門**（`extb5/aeg/tripwire_b5.sh`）：讀這個 driver 與之前每個 extb5 driver 的 shim log；lab 呼叫、任何 `REFUSED-LAUNCH`、任何一行 `ALLOWED-*` 重新驗不過（同上的條件）、任何一個記下的 pid 以**同一個 start time** 還活著——都是紅。自我檢查：好的一行綠，argv0、Thrift、device id、ipc、cwd、refused、還活著、lab 各一個 fixture 都紅（`extb5/tripwire_selfcheck.log`）。
- **OBSERVED 的對照**：第四輪 extb4r 的 shim log 1585 行＝625 個交換機＋960 個 `--version`；其中 argv0 不是 `ndt-hbdrop-bmv2` 的 80 行、device id 1 的 16 個、沒有 notifications-addr 的 16 個（notes:22-23）——新的 tripwire 會判它紅。
- **dev 量（不是閘門）**：新 suite 在 wrapper 下 112 格全綠、0 REFUSED；D16、D18、D14 各跑一次，wrapper 的 log 只有 76 個 `--version`，0 個交換機啟動、0 REFUSED（notes:51，晚記）。閘門裡 D16、D16b、D17、D18 都 caught（`mutate_heartbeat_drop_check.extb5c-4c18bf3d.log:35-38`），而同一個 driver 的 tripwire 0 違反、0 REFUSED。

### R5.5 M-5：merge trunk、重跑全部

- **兩次 merge，都沒有衝突**：
  - 開工時 `2469c2a2` merge trunk `d452d111`（trunk 改了 ndt 48 行與多個 trunk 的 suite）；
  - trunk 在 13:59Z 又到了 `1e350bf2`（7 個 commit、9 個 `tests/shell` 的檔：fixture-spawn 的 INT／TERM 處理；沒有一個是 B 改的檔）。我沒在正式 driver 開跑前再查一次——**是我漏的**（notes:47）。extb5b 跑完後才發現，於是 merge 成 `4c18bf3d`（tree `24286ec3`，與 merge-tree 的預測相同，notes:48），整套再跑一次（extb5c）。
- 這一輪的閘門＝第四輪的 27 個（gates_b4＋gates_b4r）全部重跑，加上 redfirst_b5、test_l1_shell_scoring、mutate_l1_shell_scoring，與 trunk 帶進來的 suite（merge 檢查：d452d111 的 8 個；extb5c 再加 1e350bf2 新增的 test_fixture_suites_end_on_signal）：extb5b **38 個**（`cc798de2`）、extb5c **39 個**（`4c18bf3d`），見 §R5.16。
- 中途停掉的 driver（不是結果）：extb5（`6163cef4`，跑完 redfirst_b、b2，停在 redfirst_b3：它凍結的 redfirst_b3 的 F 段已被我改掉）、extb5a（`6163cef4`，停在第一個閘門：我加了 D30／D31）——那三份 log 最後兩行寫明 `# rc=stopped`（notes:27、34）。它們的 shim log 也被 tripwire 讀了。

### R5.6 S-1：數字與過時的字

- 第四輪是 **22＋5＝27** 個閘門（不是 21／26）；`1585 allowed launches`＝625 個交換機＋960 個 `--version`（我重數，notes:22-23）。
- 已在本檔原處加註「第五輪更正」：§R4.3 標題、R4.3 的「21 個」→22、R4.4 的 `/home/adam`（fixture README 也有一行）、§2 F5 那段（只對第二、三輪成立）、檔尾第四輪那行（已 DELIVERED）。
- 第四輪計畫只在 **§R3.10**；§R3.9 是第三輪的重開機程序（INTAKE:43 的「§R3.9-§R3.10」是 orchestrator 的檔，我沒改）。
- gates_b4r.sh 標頭的「21 gates」「22 run lines removed」在凍結的副本裡，不改；正確是：21 個之外的 5 個、拿掉 22 行。

### R5.7 S-2：控制器自己推的 pipeline、runtime 改的 default action 不在涵蓋範圍（`bdc1a12f`、`639695da`、`f4b2e377`）

- checker 的 docstring 與 `LIMITS`、ndt 的那一行、proxy 普查的 summary、README 的限制，都加上：只驗 package **宣告的那個程式**的預設行為；控制器自己推的另一個 pipeline（SetForwardingPipelineConfig）、runtime 改的 default action 都不涵蓋。
- 看過紅：M28b（普查不再說這句）；N44 的 anchor 跟著換（ndt 那一行）。

### R5.8 S-3：段 S 那一句對著 raw 重寫（`f4b2e377`）

- **raw 顯示的**（OBSERVED，主 checkout 未追蹤的 `doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/`）：
  - `census_{p4runtime_solution,p4runtime_skeleton,flowcache_solution}/30_report.json` 的 `fabric.switches.*.program`：三臂每台交換機都是 package 的程式（`advanced_tunnel.json`、`flowcache.json`，helper 從 bmv2 的啟動 argv 讀的）；
  - 每個方向 sent 5、heard 5；`side_effects` 四個都是 0；`40_census.tsv:24-26` 三個 host 都沒看到幀；
  - `10_up.txt:62-67` 的「no pipeline loaded」是 liveness probe 的 FAILED_PRECONDITION——P4Runtime 沒人推過 pipeline config。
- ⇒ 舊句「沒有 pipeline／空的交換機」是錯的；新句：每台交換機跑 package 編好的程式、沒有表項（＝程式的預設動作，drop check 問的事），P4Runtime 沒推過 config；`PART=h5` 才是第一次在控制器載入程式、裝上表項之後量。main.py 的 summary、README 那一段都改了。
- 看過紅：test_heartbeat_fabric 的三個新斷言（含 `assertNotIn("so no pipeline was loaded")`）；M28d（把句子改回去）殺；redfirst_b5 D 段對 faf6eb41 的 main.py 紅。
- **INFERRED**：bmv2 用啟動時給的 JSON 跑 data plane、P4Runtime 那側在沒有 p4info 時回 FAILED_PRECONDITION——這是 bmv2 的行為，我沒有另外量。

### R5.9 S-4：checker 加固（`bdc1a12f`）

- **任何崩潰都是 rc 2**：`main()` 包住 `_main()`，`SystemExit` 照傳（訊號的 128+N），其他任何例外印 `could not tell -- the check itself crashed (…)`、rc 2；連自己的模組都 import 不了也 rc 2（`could not load its modules`）。Python 自己的 SyntaxError 仍然是 rc 1，ndt 讀成「不丟」——一樣不啟動，揭露。
- **root**：`_main()` 在 euid 0 時 rc 2；`Launch.start` 在 euid 0 時直接 `PermissionError`。
- **沒有資料埠**：`plan()` 對沒有埠的程式 `NotApplicable`（rc 3）；`check_program(ports=[])` 是 unknown（不是空洞的 DROPPED）。
- **跟 fabric 比版本**：stock 那顆的 `--version` 必須等於 fabric 那顆（`p4_proxy/mininet/bmv2_binary_override` 的第一行，`NDT_HB_CHECK_FABRIC_BMV2` 可蓋過）的；不同或讀不到＝每個程式 unknown、rc 2、不快取。兩次 `--version` 都經一個叫 `ndt-hbdrop-bmv2` 的 symlink 執行，comm 不是 `simple_switch_g`（不然 ndt 的 bmv2_count 會在那一瞬間數到它）。交換機本身也一樣（comm 從 `simple_switch` 變成 `ndt-hbdrop-bmv2`）。`CHECK_VERSION` 1→2，舊快取不再被讀。
- **main() 帶訊號的格**：子程序跑 `main()`（`settled` 換成永遠 False，讓它停在檢查中間），找到它的交換機（cwd 是 `ndt-hbdrop-*` 且有 notif.ipc）後送 SIGTERM：rc 143、交換機不在、目錄不在。
- **mutants**：settled 的三個條件各一個（D33、D33b、D33c）、永不 settle（D33d）、did-not-settle 的 guard（D32）、env 蓋過（D34）、預設路徑（D34b）、CPU 埠（D35）、頂層 except（D36）、root（D37、D37b）、import（D38、D38b）、沒有埠（D39、D39b）、版本（D40、D40b、D40c）、訊號（D41）、comm（D42）、log 路徑（D43）、目錄名（D44）。
- **dev 量（OBSERVED，不是閘門）**：mutate_heartbeat_drop_check 在 wrapper 下 64 mutations、0 survived、非 control 103/103 看過紅（`extb5/dev-gate-hbdrop.out`）；同一份 tripwire log 1191 個交換機、2743 個 `--version`、0 個違反、0 REFUSED、0 還活著。

### R5.10 S-5：每次 bring-up 一份 drop-check log（`639695da`）

- `.test_run/logs/heartbeat_drop_check.<UTC>.<pid>.log`，三種結果的那一行都寫出檔名（README 的「回報那臂的輸出」因此做得到）。
- 新格：第二次 bring-up 有自己的 log、第一次的還在、是不同的檔；N44c（固定檔名）殺；redfirst_b5 B 段對 faf6eb41 的 ndt 紅。

### R5.11 S-6：ndt → 真的 checker → bmv2（`bdc1a12f`，suite section 9）

- source ndt（與 test_ndt_heartbeat 一樣只 stub 會動到機器的東西，**不** stub `hb_drop_check_run`），fixture 的 `tools/test_workflow/` 放受測的 checker，`up_p4` 一個轉好的 p4runtime package 與一個換成洪泛程式的 package。topo-start 的 stub 在一秒內找這次 run 的 TMPDIR 底下 argv[0] 是 `ndt-hbdrop-bmv2` 的程序。
- 斷言：一行答案（`advanced_tunnel.json checked`）、heartbeat start 恰好一次、topo-start 時沒有丟棄式交換機、完整答案在那一行點名的 log；`drop check` 相關的輸出只有一行且 ≤ 400 字；洪泛：`does NOT drop`、沒有 heartbeat start、紀錄寫 `FORWARDED`、topo-start 時也沒有交換機。對照：同一個探針在 section 7 看得到一顆跑著的交換機。
- 看過紅：NE1（ndt 不等 checker）、NE2（不跑 checker）、NE3（印出整個答案）各殺在點名的格（`mutate_heartbeat_drop_check.extb5c-4c18bf3d.log:75-77`）；其餘幾格由 gate 的覆蓋報告確認至少在一個 mutant 下紅過（103/103，:82）。
- **6000 字的位置（INFERRED）**：074635Z 的 p4runtime/solution 的 N3 輸出裡，`running binary` 那行結束在第 4087 字（OBSERVED，flowcache 3477）；B 在它之前加 drop check 那一行（286 字）、之後加 helper 的回答（段 S `11_hb_start.txt` 6 行、510 字）與 detect-only 那行（226 字）⇒ 約第 5109 字結束，餘 891 字。

### R5.12 S-7：保留 mutant 的輸出，D10 的原因

- mutate_heartbeat_drop_check 的 mutant 一次 run 沒有跑到 `Ran N checks` 那一行，整份輸出存到 `$HBDROP_KEEP`（driver 設成 `<gate>.<tag>-<sha>.kept`），路徑印出來；gate 結尾說幾個。
- **D10 的 `ProcessLookupError`**：那一行在 suite 最後的 `os.kill(orphan, SIGKILL)`——`alive()` 在 3 秒後還說活著、下一刻它不在了。
  - OBSERVED：當時的 SIGKILL 探針在 wrapper 還沒 exec 之前就殺掉 checker（review 說的），被殺的是 bash wrapper；那個 gate 跑在 guard 的 `systemd-run --user`（MemoryHigh 3G）裡。
  - INFERRED，沒重現：一個在 D 狀態（等 IO、被 MemoryHigh 節流）的程序收到 SIGKILL 後要超過 3 秒才真的消失，於是「還活著」→ 下一刻 kill 撲空。D10 本身與它無關（它改的是 pcap 判斷），它的點名格在崩潰前已經紅。
  - 改法：kill 接住 `ProcessLookupError`；探針等 `notif.ipc` 出現（交換機真的在跑）才殺 checker，格名改成 `…takes its RUNNING switch with it`；mutant 的輸出會留下。
- 另一個 OBSERVED（notes:12-18）：我第一次 dev 跑這個 gate 時停錯了 process group，兩份 gate 同時跑了約 15 分鐘，互搶 Thrift 埠（`ss -ltnp` 兩個 suite 的交換機同時 listen）；那兩次 dev 結果全部作廢。由此看到的限制（INFERRED，已寫進 README）：兩個 check 同時挑到同一個埠，後啟動的那顆綁不上、自己結束（手動重現：`Could not bind`、SIGSEGV）⇒ unknown，不是通過。

### R5.13 S-8：l1 跑 test_heartbeat_drop_check.py（`7a82f317`、`960d555b`、`cc798de2`）

- `l1_unit_tests.sh` 的 kernel-side 段多收 `tests/shell/test_*.py`，用 `python3` 跑、用 shell suite 的方式計分（`Ran N checks`、`SKIP:`），新增 need `bmv2-stock`（`/usr/local/bin/simple_switch` 或 `NDT_HB_CHECK_BMV2` 可執行）；suite 沒有 stock simple_switch 就印 `SKIP:` 並宣告 `# NDTWIN_L1_NEEDS: bmv2-stock` ⇒ hosted runner 上是 DECLARED-SKIP。
- test_l1_shell_scoring：D27（收）、D28（計分方式）、D29（宣告）、D30（沒有 simple_switch 時 suite 真的 SKIP：rc 0、一行 SKIP、什麼都沒跑）、D31（lane 在 hosted runner 上給 DECLARED-SKIP、在 lab 上給 FAIL-SKIP）新格；D18、D19、X 段的定位跟著改。
- mutate_l1_shell_scoring：sandbox 帶上 `tests/shell/test_*.py`；五個新 mutation（不收、用 unittest 計分、不宣告、不 probe、沒有 simple_switch 時照跑）；extb5b：58 killed、0 survived。
- redfirst_b5 F 段：HEAD 的 suite 對 faf6eb41 的 l1 紅 7 格（D18、D19、D22、D27、D28、X0、X3）。

### R5.14 S-9：預先登記的判定規則與誤判率（`868e4ed0`）

- **算式**：沒有效果時，一個連續的噪音欄位落在 n 個對照組範圍外的機率是 2/(n+1)（n=2：67%、n=4：40%）；要 ≤ 5% 得 n ≥ 39。所以噪音欄位不能用範圍判。
- **依據**（OBSERVED，`extb5/survey.py`／`survey.out`，主 checkout `runs/` 裡 B 之前、沒有心跳的 34 個同臂 round）：verdict 三臂都會翻（p4runtime/solution FAIL ×3／12、flowcache/solution FAIL ×3／11）；rules_installed 每臂 1 種；p4runtime/solution 的 counters_final 4 種、流量不變式 `s1 ingress 100 = pings + datagrams` 只 1／12 成立（6 個少 1）；flowcache 的 packet_ins／cache_entries／grpc_errors 3／4／2 種；0x88B5 與非 IPv4 的 packet-in 34／34 都是 0。
- **規則**（`external_evidence.py` 的 `DESCRIPTIVE`／`DESCRIPTIVE_INVARIANTS`，README 寫明）：變過的＝只描述（印、說在不在範圍內、不計）；沒變過的＝判定（對照組一致、處理組必須相等；對照組自己不一致＝UNDECIDED、rc 2、回報）。判定欄位的 DIFF ⇒ T 重跑一次，同一處再出現才算失敗；`!! DAEMON` 與 0x88B5 packet-in ⇒ 立刻失敗、不重跑。
- **誤判率**：判定檢查每次自己變的機率 q，加上重跑，至多 q²；34 個 round 裡沒有一個判定檢查變過（點估計 0）；0/N 的 95% 上界：N=11 → q² ≤ 5.7%（skeleton 那幾個，**略高於 5% 的目標，揭露**）、N=12 → 4.9%、N=23 → 1.5%、N=34 → 0.7%。family-wise 的保守上界是相加，**超過 5%**——揭露。
- **為什麼現在改是正當的**：還沒有任何 live 比對資料；只用規則的算術與 B 之前、別的程式版本的舊 round（只拿來分類欄位）；裁定要求的；在 commit 裡、早於任何 live run。
- **看過紅**：E73–E80（把會變的欄位當判定、把 rules_installed 當描述、拿掉 UNDECIDED、UNDECIDED 回 0、把變過的不變式當判定、結論不說 UNDECIDED、每個不變式都只描述），每個殺在點名的格；舊的 E1/E5/E10/E11/E14/E23–E26/E29/E45/E52/E56/E57/E59 照新格名改了點名。

### R5.15 nits

- `ndt status` 在 external 上報出路徑數 > 0 時印 `!! … a guessed route is being served`，並算 `--check` 的問題（`639695da`）；0 時安靜。M28c 殺；redfirst_b5 C 段對 faf6eb41 紅。
- D21 留下的四個目錄（`extb4r-1001/tmp/ndt-hbdrop-*`，24–40K）：**沒刪**——不是我的檔，我的規則不准刪別人的資料，留給人（notes）。這一輪 suite 把自己的 TMPDIR 設成它自己的 WORK，mutant 留下的目錄跟著 WORK 一起刪。
- `/home/adam`：fixture README 的說明改成 `~/`（`bdc1a12f`）；p4c 的 JSON 照原樣。新的 `code_identity.py` 的預設控制器直譯器用 `~/p4dev-python-venv`（expanduser），不寫死。README（doc/audit 的 .md，不進 main）新增 8 行 `/home/adam`，照第三輪的裁定保留。
- advanced_tunnel 的 fixture 與 `~/tutorials` 的 build，去掉 `program`／`source_info` 後相同（OBSERVED，notes:19；review 列為 under-evidenced）。
- 08 self-test 的 `phase_for` 格是 flaky 的（範圍的兩端 %.2f 會印出來、檢查卻排除它們，約 1/250）——在一次 red-first dev run 紅過（`… 1.30 4.95`），改成含兩端（`6163cef4`）。
- 注入的幀的欄位值（rx_dpid 0、合成的 MAC 與 session）沒改——不在這一輪的清單，揭露。

### R5.16 閘門

- 全部經 guard（`JOBS=1 LOCK_WAIT=10800`，每個 gate 各取一次鎖），PATH 最前面是 nolab shim，drop check 的兩顆 binary 經 `make_hbwrap.sh` 的 wrapper（會拒絕），tripwire 最後；driver 從凍結、唯讀的副本跑。磁碟下限 1.5 GB，排隊時與鎖下各查一次。
- **extb5c，head `4c18bf3d`（最終）**：`extb5/frozen/gates_b5c.sh`（sha256 `0a442e8fcfdfc29d…`，與 gates_b5.sh 只差標頭、cp 的名字與 trunk 新增的一個 suite）；log 在 `logs/gates-0910/<gate>.extb5c-4c18bf3d.log`。**39 個我都讀過：第一行都是 `4c18bf3da29e…`，最後一行都是 `# rc=0`**；driver 的結尾 `GATES-extb5c 4c18bf3d: ALL-AS-EXPECTED`（`extb5/gates_extb5c.out`）。磁碟：排隊時 2627–2977 MB、鎖下 2627–2994 MB。

| gate | first line | last line | result, log:line |
|---|---|---|---|
| redfirst_b | `4c18bf3d` | `# rc=0` | `REDFIRST-B: ALL-AS-EXPECTED` (:71) |
| redfirst_b2 | `4c18bf3d` | `# rc=0` | `REDFIRST-B2: ALL-AS-EXPECTED` (:77) |
| redfirst_b3 | `4c18bf3d` | `# rc=0` | `REDFIRST-B3: ALL-AS-EXPECTED` (:231) |
| redfirst_b4 | `4c18bf3d` | `# rc=0` | `REDFIRST-B4: ALL-AS-EXPECTED` (:30) |
| redfirst_b5 | `4c18bf3d` | `# rc=0` | `REDFIRST-B5: ALL-AS-EXPECTED` (:37) |
| proxy_unit | `4c18bf3d` | `# rc=0` | `PROXY-UNIT: 46 file(s), 1734 test(s): 1733 passed in OK files, 1 skipped, 0 file(s) FAILED -- all OK` (:57) |
| test_ndt_heartbeat | `4c18bf3d` | `# rc=0` | `Ran 91 checks, 0 failed` (:121) |
| test_ndt_app_package | `4c18bf3d` | `# rc=0` | `Ran 404 checks, 0 failed` (:458) |
| test_ndt_up_down_robust | `4c18bf3d` | `# rc=0` | `424 passed, 0 failed` (:484) |
| test_ndt_sudo_surface | `4c18bf3d` | `# rc=0` | `Ran 55 checks, 0 failed` (:73) |
| test_ndt_status_check_baseline | `4c18bf3d` | `# rc=0` | `Ran 112 checks, 0 failed` (:156) |
| test_apps_residue | `4c18bf3d` | `# rc=0` | `Ran 145 checks, 0 failed` (:193) |
| test_ndt_app_orphans | `4c18bf3d` | `# rc=0` | `Ran 111 checks, all passed` (:133) |
| test_ndt_apps_liveness | `4c18bf3d` | `# rc=0` | `Ran 57 checks, all passed` (:76) |
| test_ndt_down_stops_only_ours | `4c18bf3d` | `# rc=0` | `Ran 32 checks, 0 failed` (:53) |
| test_ndt_helper_apps_window | `4c18bf3d` | `# rc=0` | `Ran 157 checks, 0 failed` (:199) |
| test_ndt_ovs_claim | `4c18bf3d` | `# rc=0` | `Ran 174 checks, 0 failed` (:220) |
| test_ndtwin_lab_sweep | `4c18bf3d` | `# rc=0` | `Ran 33 checks, all passed` (:51) |
| test_faults_topo_pid | `4c18bf3d` | `# rc=0` | `Ran 61 checks, all passed (0 skipped)` (:87) |
| test_fixture_suites_end_on_signal | `4c18bf3d` | `# rc=0` | `Ran 84 checks, all passed` (:124) |
| selftest_08 | `4c18bf3d` | `# rc=0` | `SELF-TEST PASS` (:182) |
| selftest_07 | `4c18bf3d` | `# rc=0` | `SELF-TEST PASS` (:70) |
| test_live_p1_common | `4c18bf3d` | `# rc=0` | `Ran 220 checks, 0 failed` (:264) |
| test_live_p1_thirteen | `4c18bf3d` | `# rc=0` | `Ran 46 checks, 0 failed` (:70) |
| test_live_p1_external_evidence | `4c18bf3d` | `# rc=0` | `Ran 151 checks, 0 failed` (:175) |
| test_heartbeat_drop_check | `4c18bf3d` | `# rc=0` | `Ran 112 checks, 0 failed` (:142) |
| test_l1_shell_scoring | `4c18bf3d` | `# rc=0` | `Ran 157 checks, 0 failed` (:189) |
| test_drive_exercise | `4c18bf3d` | `# rc=0` | `OK` (:82) |
| mutate_p4_heartbeat_w | `4c18bf3d` | `# rc=0` | `every new proxy test seen red: 123 of 123` (:300); `mutation gate: 266 mutations, 0 survived` (:303) |
| mutate_live_p1_common | `4c18bf3d` | `# rc=0` | `Ran 220 checks, 0 failed` (:12); `mutation gate: 59 mutations, 0 survived; 4 control(s), 0 went red` (:380) |
| mutate_live_p1_thirteen | `4c18bf3d` | `# rc=0` | `Ran 46 checks, 0 failed` (:12); `mutation gate: 13 mutations, 0 survived; 1 control(s), 0 went red` (:126) |
| mutate_live_p1_external_evidence | `4c18bf3d` | `# rc=0` | `mutation gate: 89 mutations, 0 survived` (:105); `every check seen red: 151/151 (over 89 mutant runs)` (:106) |
| mutate_roles_binding | `4c18bf3d` | `# rc=0` | `OK` (:14); `mutation gate: 179 mutations, 0 survived` (:622) |
| mutate_app_package | `4c18bf3d` | `# rc=0` | `OK` (:14); `mutation gate: 48 mutations, 0 survived` (:69) |
| mutate_ndt_app_package | `4c18bf3d` | `# rc=0` | `Ran 404 checks, 0 failed` (:12); `mutation gate: 78 mutations, 0 survived; 4 control(s), 0 went red` (:677) |
| mutate_heartbeat_drop_check | `4c18bf3d` | `# rc=0` | `mutation gate: 64 mutations, 0 survived` (:81); `every non-control check seen red: 103/103 (over 64 mutant runs); 9 control(s), 8 of them red too: ['and it is still rc 0', '(the run under observation` (:82) |
| mutate_l1_shell_scoring | `4c18bf3d` | `# rc=0` | `Ran 157 checks, 0 failed` (:12); `===== 58 mutation(s): 58 killed, 0 survived =====` (:86) |
| check_gate_anchors | `4c18bf3d` | `# rc=0` | `130/130 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` (:147) |
| nolab_tripwire | `4c18bf3d` | `# rc=0` | `NOLAB-TRIPWIRE: 0 lab call(s); 2508 allowed switch launch(es) and 5734 --version probe(s), each re-checked: 0 breaking a condition, 0 refused by the w` (:15) |

39 logs

- tripwire（`nolab_tripwire.extb5c-4c18bf3d.log:11-15`）讀了四個 extb5 driver 的 shim log（extb5、extb5a 兩個停掉的、extb5b、extb5c）：0 個 lab 呼叫；2508 個交換機、5734 個 `--version`，每一行都重新驗過，0 個違反、0 個被 wrapper 拒絕、0 個以同一個 start time 還活著。交付前 `ps` 裡沒有任何 argv[0] 是 `ndt-hbdrop-bmv2` 的程序（OBSERVED）。
- **extb5b，head `cc798de2`（第二次 merge 之前）**：`extb5/frozen/gates_b5.sh`（sha256 `de6c016b4a254b91…`）；38 個（同上，少 trunk 新增的那個 suite），全部第一行 `cc798de22edb…`、最後一行 `# rc=0`，`GATES-extb5b cc798de2: ALL-AS-EXPECTED`；計數與 extb5c 相同（test_l1_shell_scoring 156 而不是 157：group C 讀的 corpus 多了 trunk 的新 suite）。它的 tripwire：0 lab、1254 交換機、2867 `--version`、全部 0（`nolab_tripwire.extb5b-cc798de2.log:14`）。磁碟：排隊與鎖下 2076–3335 MB。
- 與第四輪相比（reconcile）：proxy_unit 1733＋1 skipped（同）；test_ndt_heartbeat 88→91、test_ndt_app_package 399→404、test_heartbeat_drop_check 67→112、test_live_p1_external_evidence 103→151、test_live_p1_thirteen 45→46、test_l1_shell_scoring（新）157；mutate_p4_heartbeat_w 256→266、mutate_live_p1_external_evidence 61→89（151/151）、mutate_heartbeat_drop_check 39→64（103/103）、mutate_ndt_app_package 77→78、mutate_live_p1_thirteen 12→13、mutate_l1_shell_scoring（新）58、check_gate_anchors 128→130；mutate_live_p1_common 59、mutate_roles_binding 179、mutate_app_package 48 不變。每個增加都是這一輪新加的格或 mutant（上面各節）。


### R5.17 live run（需要 Adam 在這個 session 授權 lab；這一輪**沒有**跑）

在主 checkout（`/home/adam/Desktop/NDTwin-Kernel`），`LP=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`、`B_WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927`、`B_SHA=4c18bf3da29efed3d2f36abd2db67d8f780a222b`：

```
# 0. orchestrator：凍結 trunk 的 push／merge；主 checkout 在 trunk head、未 merge B
cd /home/adam/Desktop/NDTwin-Kernel
# 1. 對照組（完整的 06），每個跑完立刻補記
NDT_OWNER=<你> bash $LP/06_thirteen.sh                       # C1
bash $B_WT/$LP/venv_fingerprint.sh <C1>/00_venv.txt /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/p4dev-python-venv/bin/python
python3 $B_WT/$LP/code_identity.py record /home/adam/Desktop/NDTwin-Kernel <C1>/00_identity.txt
NDT_OWNER=<你> bash $LP/06_thirteen.sh                       # C2，同樣補記兩行
# 2. 本地 merge（不 push）
git -C /home/adam/Desktop/NDTwin-Kernel merge --no-ff --no-edit $B_SHA
# 3. 處理組
NDT_OWNER=<你> OLD_06=<C1> C_IDENTITY=<C1>/00_identity.txt B_SHA=$B_SHA PART=h5 bash $LP/08_heartbeat.sh
# 4. 比對
python3 $LP/external_evidence.py compare <C1> <T> --control2 <C2> --samples <08 run>/50_samples.tsv --b-sha $B_SHA
# 5. 通過 ⇒ push、解凍；失敗或放棄 ⇒
git -C /home/adam/Desktop/NDTwin-Kernel reset --keep <C1 的 00_identity.txt 裡的 head>
# 之後一次 H1-H4
NDT_OWNER=<你> bash $LP/08_heartbeat.sh
```

判定照 README「判定（預先登記，第五輪）」。

### R5.18 沒做的、只推論的

- **live 從沒跑過**（裁定：這一輪不跑）。上面所有東西在 lab 上第一次被執行，都是 live run 那一次。
- 段 S 那一句的 bmv2 行為（R5.8 INFERRED）。
- D10 的原因（R5.12 INFERRED，沒重現）。
- 6000 字的餘量（R5.11 INFERRED，用舊 raw 加上算出來的長度）。
- 判定欄位的 family-wise 誤判率沒有壓到 5% 以下（R5.14，揭露）。
- 注入的幀的欄位值、switch_state 沒有 withheld 的原因（第四輪的 deviation，review 的 minor 8）：沒改。
- D21 的四個目錄沒刪（R5.15）。

### R5.19 Commits（`faf6eb41..HEAD`，first-parent）

- `4c18bf3d` Merge trunk 1e350bf2 into feat/external-detect-only-0927
- `cc798de2` l1 scoring suite: the drop check's suite skips, declared, without a stock simple_switch
- `6163cef4` 08 self-test: phase_for's range check includes its two reachable ends
- `79235fac` 08 self-test: the controllers-column case names its pid as a quoted value
- `9020a496` live-p1 evidence suite: cells each mutation can reach under the decisive split
- `960d555b` l1 gate: the ryu-probe mutation names D18 as it reads now
- `52049946` gates: anchors the anchor checker can find for the new mutations
- `7a82f317` l1: run tests/shell's Python suites, scored as shell suites
- `868e4ed0` live-p1: record each run's code, hear every direction, decide only on fields that hold still
- `f4b2e377` proxy: describe segment S's census of the external programs as its raw shows it
- `639695da` ndt: keep one drop-check log per bring-up and flag paths on an external plane
- `bdc1a12f` heartbeat drop check: never a pass or rc 1 on a crash, root, a port-less program or another bmv2
- `2469c2a2` Merge trunk d452d111 into feat/external-detect-only-0927
- B 自己這一輪的改動（兩次 trunk merge 之外）：`2469c2a2..cc798de2` 23 個檔，+2256／−268（約 600 行是 README 的程序與表）。逐檔看過清單；新增行掃過秘密字串（0）；新增的 `/home/adam` 只在 live-p1 README（doc/audit 的 .md，照第三輪的裁定保留）。

第五輪（§R5）：head `4c18bf3da29efed3d2f36abd2db67d8f780a222b`；extb5c 39 個閘門全部 rc 0（第一行都是這個 sha），tripwire 0；live 比對還沒跑（等 Adam 授權）。

DELIVERED 4c18bf3da29efed3d2f36abd2db67d8f780a222b

## §R6 第六輪（round-5 re-review 在 `4c18bf3d` 上：MERGE AFTER FIXES；Must 1–4、S-8 的裁定、四個 should）

[Co-developed with claude code -- Adam]

起點 `4c18bf3d`，終點 `5311f3f6`（R6.10）。OBSERVED（我自己跑、讀過的 log，附 log:line）與 INFERRED（推論）分開寫。
findings log：`logs/gates-0910/extb6-notes.log`。live 比對**沒有跑**（要 Adam 在這個 session 授權 lab）。

### R6.1 Must 1：README 的程序與指令（`2d54f270`）

- `live-p1/README.md`「合併前的比對」改寫（OBSERVED，檔案本身）：
  - 第 0 步：orchestrator 宣布凍結（trunk 不 commit、不 merge、不 push），直到第 7 步解凍；
    `C_HEAD == git rev-parse trunk`；`git merge-base --is-ancestor $C_HEAD $B_SHA`，或 `git merge-tree --write-tree
    $C_HEAD $B_SHA` 的 tree 等於 B 的 tree——兩個都不成立就停下。
  - 第 1 步：每個對照組開跑前 `code_identity.py record` 到暫存檔、跑 06、跑完再記一次，兩份放進 run 目錄。
  - 第 2 步：merge 後核對 `T_MERGE^1 == C_HEAD`、`T_MERGE^2 == B_SHA`、`T_MERGE^{tree}` 等於 merge-tree 的結果。
  - 第 3 步 T（`C_IDENTITY=<C1>/00_identity.after.txt`）；**第 4 步 H1–H4 在本地 merge 之下、判定之前**；第 5 步 compare；
  - 第 6 步回復前 `[[ $(git rev-parse HEAD) == $T_MERGE ]]`，不是就不 reset、回報；永遠 `reset --keep`。
  - 預先登記的結果：merge 被拒（衝突就 `merge --abort`、確認 HEAD 仍是 C_HEAD、不跑 T）；身分因別人的改動被拒
    ⇒ 回復、從第 0 步與 C1 重來；T 重跑 rc 0／同一欄位 rc 1（失敗）／別的欄位 rc 1（不通過、不是失敗的定論、
    回報 Adam、不跑第三次）／rc 2（同上）／rc 3（那次不算，修正後最多再做一次）；`UNDECIDED heard` ⇒ T 重跑一次；
    H1–H3 任何 FAIL、H4 因 `reported_to_kernel` 以外的原因 FAIL ⇒ 不通過。
  - 凍結與縮小比較範圍的裁定都寫進去了。
- 指令清單在 R6.8。

### R6.2 Must 2：身分與比對（`c1b1c22f`、`9c860882`）

- `code_identity.py`（FORMAT 2）多記：`tree`、merge 的 `merge_tree`（`git merge-tree --write-tree p1 p2`）、
  `bmv2_libs`（fabric binary 的 `../lib` 底下每個非 symlink 的 `.so` 的 sha256 digest）、`tutorials`（`~/tutorials`
  的 HEAD、未提交的追蹤檔與 sha256、`exercises/p4runtime`、`exercises/flowcache`、`utils` 每個檔的 digest，跳過
  `build/ logs/ pcaps/ __pycache__`）。未提交的比較跳過 `doc/**/*.md`、`doc/audit/**/*.tsv`（裁定）。
  `verify` 多一條：T 的 tree 不等於 merge_tree ⇒ 拒絕。新 `unchanged_reasons(before, after)`。
- `external_evidence.py`：每個 run 必須有 `00_identity.before.txt` 與 `.after.txt`，兩者不同 ⇒ rc 3
  （`the code changed while a run ran`），比較用 after。新 `programs_same`：每臂的 p4c sha 與編出來的 JSON sha
  （round 報告 §2 的表）在 C1、C2、T 之間必須相同，否則 rc 3；報告裡沒有 ⇒ rc 2。
- B 的 06 開跑寫 before、跑完寫 after（`record_identity`）。
- OBSERVED：主 checkout 的 34 個 round 的 p4c 都是 `226f3f66df515c9e`、每臂的 JSON 都只有一種（survey.out）；
  控制器推的就是那張表裡的 `build/*.json`（mycontroller.py 的預設，notes:3）。`~/tutorials` 現在（未提交的觀察）
  HEAD `c80d83e9`，`exercises/basic/basic.p4` 有未提交的改動、在比較範圍內（notes:2）。
- 看過紅：見 R6.6 的表。

### R6.3 Must 3：「聽到」的窗口（`b938dee3`、`c1b1c22f`）

- 08 的 sampler 多一欄 `ctrl_logs`（第 13 欄）：`$SAMPLER_RUNS_DIR`（預設 drive_exercise 的 `runs/`）裡 sampler 開始之後
  才建的 round 目錄中每個 `driver-controller-*.log` 的大小。
- compare：窗口起點＝第一個 `ctrl_logs` 看到這臂的 log 長到最後一行 pipeline push 結尾的 sample（沒有 push 行就用第一行
  rule／cache entry；都沒有 ⇒ rc 2）；終點＝log 的 mtime。起點之前（含）與終點之前（含）的最後一個 session sample，
  每個方向的 `heard` 要至少 +1，否則 rc 3；起點時 session 還沒在跑 ⇒ rc 3；**窗口 < 10 s ⇒ `UNDECIDED heard`，
  計入 UNDECIDED（rc 2，除非另有 DIFF），整份比對照印**。不再需要 controller pid（死碼 `CTRL_PID` 拿掉）。
- fixture 是真的節奏：每秒一筆、每個方向每 5 s +1；push 在 45 s、最後寫入 150 s；窗口 5 s 的（UNDECIDED）、剛好 10 s
  的（判定，+2）、只在 push 前聽到的、只在最後寫入後聽到的、兩次 push 取後一次的、沒有 push 行的、session 晚於 push 的、
  sampler 沒看到 log 的、沒看到長到 push 的、log 什麼都沒有的。
- INFERRED：控制器的 log 是無緩衝寫的（drive_exercise 給 `PYTHONUNBUFFERED=1`，drive_exercise.py:1623），所以 log 的大小
  隨 push 立即變——這是 sampler 能用大小定位 push 的前提；live 才會真的驗到。

### R6.4 Must 4：S-9（`d74297fc`、`2d54f270`）

- `live-p1/external_survey_34.tsv`：34 個 round（11／12／11）的報告與控制器 log 的路徑、sha256；
  `external_survey.py <prep>`：檔案不見、變了、有心跳痕跡 ⇒ rc 3，其餘印每臂每欄的值數。對主 checkout 跑：
  `34 rounds, every report and controller log as frozen, none with the heartbeat`（survey_34 閘門）。
- README 寫了：點估計 0（22 個判定檢查在各自的 round 裡 0 次變動）；每個檢查的 q² 上界；**family-wise＝上界相加約 54%**
  （skeleton 23.7、solution 11.5、flowcache 19.2；re-review 的 N 分配算出約 52%），明寫是上界之和、不是估計；
  FAIL 的代價是一份調查加那一次 T 重跑，不反覆重跑；PASS 不證明的：只描述的欄位（轉發的量）、重跑規則的檢定力 p²。

### R6.5 S-8 的裁定與 should

- `test_heartbeat_drop_check.py` 在任何交換機啟動之前讀 ndt 的 claim 檔（`lab_kernel_dir` 的 `.test_run/lab.claim`，
  `NDT_LAB_CLAIM_FILE` 可覆寫）：未過期、別人的 claim，或宣告了 measuring ⇒ `SKIP:`、rc 0、什麼都沒跑。過期或讀不了的
  claim 不算（與 ndt 自己的讀法一致，ndt:5890）。`test_l1_shell_scoring` D32–D35。driver 把這個 suite 的 SKIP 算失敗，
  並在開跑前用同一個規則讀 claim。
- self-check：`extb6/aeg/selfcheck_b6.sh`，35 個 fixture（tripwire 21、wrapper 14）＋一行說 euid 0 要 root、沒跑。
  switch 的 cwd 必須在 TMPDIR 底下（wrapper 拒絕 `cwd-not-under-…`、tripwire 標出來）。
- SIGKILL 探針等 10 s（原 3 s）。
- `main.py:1382-1384` 過時的註解改寫（`1cf0692c`，只有註解；沒有測試，它不是一個檢查）。

### R6.6 看過紅（新的檢查各自紅在舊碼或 mutant 上，綠在新碼上；全部是 extb6m 的閘門 log）

| 新的檢查 | 紅在哪裡（log:line） |
|---|---|
| 聽到的窗口（push 之前才聽到、最後寫入之後才聽到、session 晚於 push、5 s 窗口 UNDECIDED、剛好 10 s 判定、取最後一次 push、沒有 push 行、沒看到 log、沒看到長到 push、log 什麼都沒有、ctrl_logs 沒讀、第五輪的 sampler 檔） | E61–E65、E81–E90（`mutate_live_p1_external_evidence.extb6m-5311f3f6.log:75-89`）；redfirst_b6 A 對 4c18bf3d 的工具（`redfirst_b6.extb6m-5311f3f6.log:12-39`） |
| 同一個 p4c 與 JSON、報告裡沒有 sha | E91–E94（同 log:90-93） |
| 每個 run 前後身分、沒有 after、HEAD 在跑的途中動了 | E95、E72、I20（:94、:101、:129） |
| tree 對 merge-tree、`~/tutorials`、bmv2 libs、`build/` 不算、未追蹤的 exercise 檔、symlink 不算、NOT_CODE 兩個方向 | I9–I19（:118-128）；真的 git repo 上的 record 格（section 7），redfirst_b6 A 對舊的 code_identity 紅 |
| 34 個凍結的 round（變了、不見、有心跳、壞 manifest、印出的內容、rc） | S1–S7（:130-136）；redfirst_b6 A（沒有 survey 工具） |
| sampler 的 `ctrl_logs` | L86–L88（`mutate_p4_heartbeat_w.extb6m-5311f3f6.log:284-286`）；redfirst_b6 C（舊 sampler，`redfirst_b6…log:42-48`）；selftest_08:133、:135 綠 |
| 06 前後各記一次身分 | M13、M14（`mutate_live_p1_thirteen.extb6m-5311f3f6.log:122`、`:125`）；redfirst_b6 B（:40-41） |
| drop check suite 讀 lab claim（D32–D35） | 四個 mutant（`mutate_l1_shell_scoring.extb6m-5311f3f6.log:84-87`）；redfirst_b6 D（舊 suite：D32、D33 紅，:50-51） |
| wrapper／tripwire 的 cwd 在 TMPDIR 底下 | redfirst_b6 E：第五輪的 tripwire 與 wrapper 恰好在這兩個 fixture 上不如預期（:54-55）；第六輪的 35 個都如預期（:56；selfcheck_b6 閘門:47） |

- redfirst_b6 A 對舊工具有 147／202 格紅（:13），是退化的：舊工具找不到 `00_identity.before.txt` 就全部 rc 3，所以本輪 rc 3 的那幾格在舊工具上**碰巧綠**——它們的紅是上表各自的 mutant，脚本裡印了這一段。
- 「乾淨的 merge：tree 等於 merge-tree」那一格在舊的 code_identity 上是綠的（舊的沒有 tree 檢查，好情況照樣過），它的紅是 I10。
- 舊的 redfirst（b、b3、b5）因為 HEAD 的 suite 改名或加格而改了預期集合（`extb6/aeg/patch_old_redfirsts_r6.py`，每一處在腳本裡印原因）；全部 ALL-AS-EXPECTED（R6.7 表）。

### R6.7 閘門

- **extb6（head `1cf0692c`）停掉，不算數**（notes:6-7）：trunk 在跑的途中從 `1e350bf2` 走到 `67ec9f9e`（GUI v2）。停之前 25 個 log：redfirst_b6 rc 1（它在腳本的上一層找 `make_hbwrap.sh`，driver 是放在旁邊——我的 dev run 剛好有一份在上一層），其餘 rc 0；mutate_p4_heartbeat_w 跑到一半被我停（log 結尾 `guarded_build: exit 143`）。停法：driver pid 2137576 TERM、`systemctl --user stop ndtwin-build-2511622.scope`；session 裡沒有剩下的 pid、沒有 `ndt-hbdrop-bmv2` 程序。
- **merge trunk `67ec9f9e` 成 `5311f3f6`**：tree `2f6f20bc`＝`git merge-tree --write-tree 1cf0692c 67ec9f9e`（rc 0）；兩邊都改的檔只有 `tools/test_workflow/ndt`，自動合併（notes:8）。driver 開跑前 `git rev-parse trunk`（不 fetch）＝`67ec9f9e`，是 HEAD 的祖先；跑完 `trunk: 67ec9f9e… throughout (not moved)`（`extb6/gates_extb6m.out`）。gate 引用的是字串 anchor，不是 ndt 的行號（check_gate_anchors 131/131）；這份 SUMMARY 引的 `ndt:5890` 在 merge 後仍是那一行。
- **extb6m（head `5311f3f6`，交付）**：`extb6/frozen/gates_b6m.sh`（sha256 `f1b04b98…`，與 `scripts-extb6m-5311f3f6/gates_b6.sh` 相同）。round 5 的 39 個＋redfirst_b6、selfcheck_b6、survey_34、trunk 新的 test_ndt_status_measuring 與 mutate_ndt_status_measuring＝**44 個，我都讀過：第一行都是 `5311f3f60add…`，最後一行都是 `# rc=0`**；`GATES-extb6m 5311f3f6: ALL-AS-EXPECTED`。磁碟：排隊與鎖下 2705–3226 MB；中途一次掉到 809 MB（notes:9，不是我的：我的目錄都在幾 MB 以內），沒有落在檢查點上。drop check suite 沒有 SKIP（test_heartbeat_drop_check 112 格）。

| gate | first line | last line | result, log:line |
|---|---|---|---|
| redfirst_b | `5311f3f6` | `# rc=0` | `REDFIRST-B: ALL-AS-EXPECTED` (:80) |
| redfirst_b2 | `5311f3f6` | `# rc=0` | `REDFIRST-B2: ALL-AS-EXPECTED` (:85) |
| redfirst_b3 | `5311f3f6` | `# rc=0` | `REDFIRST-B3: ALL-AS-EXPECTED` (:291) |
| redfirst_b4 | `5311f3f6` | `# rc=0` | `REDFIRST-B4: ALL-AS-EXPECTED` (:30) |
| redfirst_b5 | `5311f3f6` | `# rc=0` | `REDFIRST-B5: ALL-AS-EXPECTED` (:40) |
| redfirst_b6 | `5311f3f6` | `# rc=0` | `REDFIRST-B6: ALL-AS-EXPECTED` (:57) |
| selfcheck_b6 | `5311f3f6` | `# rc=0` | `SELFCHECK-B6: 35 fixture(s), every one as expected` (:47) |
| proxy_unit | `5311f3f6` | `# rc=0` | `PROXY-UNIT: 46 file(s), 1734 test(s): 1733 passed in OK files, 1 skipped, 0 file(s) FAILED -- all OK` (:57) |
| test_ndt_heartbeat | `5311f3f6` | `# rc=0` | `Ran 91 checks, 0 failed` (:121) |
| test_ndt_app_package | `5311f3f6` | `# rc=0` | `Ran 404 checks, 0 failed` (:458) |
| test_ndt_up_down_robust | `5311f3f6` | `# rc=0` | `424 passed, 0 failed` (:484) |
| test_ndt_sudo_surface | `5311f3f6` | `# rc=0` | `Ran 55 checks, 0 failed` (:73) |
| test_ndt_status_check_baseline | `5311f3f6` | `# rc=0` | `Ran 112 checks, 0 failed` (:156) |
| test_apps_residue | `5311f3f6` | `# rc=0` | `Ran 145 checks, 0 failed` (:193) |
| test_ndt_app_orphans | `5311f3f6` | `# rc=0` | `Ran 111 checks, all passed` (:133) |
| test_ndt_apps_liveness | `5311f3f6` | `# rc=0` | `Ran 57 checks, all passed` (:76) |
| test_ndt_down_stops_only_ours | `5311f3f6` | `# rc=0` | `Ran 32 checks, 0 failed` (:53) |
| test_ndt_helper_apps_window | `5311f3f6` | `# rc=0` | `Ran 157 checks, 0 failed` (:199) |
| test_ndt_ovs_claim | `5311f3f6` | `# rc=0` | `Ran 174 checks, 0 failed` (:220) |
| test_ndtwin_lab_sweep | `5311f3f6` | `# rc=0` | `Ran 33 checks, all passed` (:51) |
| test_faults_topo_pid | `5311f3f6` | `# rc=0` | `Ran 61 checks, all passed (0 skipped)` (:87) |
| test_fixture_suites_end_on_signal | `5311f3f6` | `# rc=0` | `Ran 84 checks, all passed` (:124) |
| test_ndt_status_measuring | `5311f3f6` | `# rc=0` | `Ran 102 checks, 0 failed` (:121) |
| selftest_08 | `5311f3f6` | `# rc=0` | `SELF-TEST PASS` (:183) |
| selftest_07 | `5311f3f6` | `# rc=0` | `SELF-TEST PASS` (:70) |
| test_live_p1_common | `5311f3f6` | `# rc=0` | `Ran 220 checks, 0 failed` (:264) |
| test_live_p1_thirteen | `5311f3f6` | `# rc=0` | `Ran 47 checks, 0 failed` (:71) |
| test_live_p1_external_evidence | `5311f3f6` | `# rc=0` | `Ran 202 checks, 0 failed` (:230) |
| survey_34 | `5311f3f6` | `# rc=0` | `34 rounds, every report and controller log as frozen, none with the heartbeat` (:11) |
| test_heartbeat_drop_check | `5311f3f6` | `# rc=0` | `Ran 112 checks, 0 failed` (:142) |
| test_l1_shell_scoring | `5311f3f6` | `# rc=0` | `Ran 162 checks, 0 failed` (:194) |
| test_drive_exercise | `5311f3f6` | `# rc=0` | `OK` (:82) |
| mutate_p4_heartbeat_w | `5311f3f6` | `# rc=0` | `every new proxy test seen red: 123 of 123` (:303); `mutation gate: 269 mutations, 0 survived` (:306) |
| mutate_live_p1_common | `5311f3f6` | `# rc=0` | `Ran 220 checks, 0 failed` (:12); `mutation gate: 59 mutations, 0 survived; 4 control(s), 0 went red` (:380) |
| mutate_live_p1_thirteen | `5311f3f6` | `# rc=0` | `Ran 47 checks, 0 failed` (:12); `mutation gate: 14 mutations, 0 survived; 1 control(s), 0 went red` (:131) |
| mutate_live_p1_external_evidence | `5311f3f6` | `# rc=0` | `mutation gate: 123 mutations, 0 survived` (:139); `every check seen red: 202/202 (over 123 mutant runs)` (:140) |
| mutate_roles_binding | `5311f3f6` | `# rc=0` | `OK` (:14); `mutation gate: 179 mutations, 0 survived` (:622) |
| mutate_app_package | `5311f3f6` | `# rc=0` | `OK` (:14); `mutation gate: 48 mutations, 0 survived` (:69) |
| mutate_ndt_app_package | `5311f3f6` | `# rc=0` | `Ran 404 checks, 0 failed` (:12); `mutation gate: 78 mutations, 0 survived; 4 control(s), 0 went red` (:677) |
| mutate_ndt_status_measuring | `5311f3f6` | `# rc=0` | `Ran 102 checks, 0 failed` (:16) |
| mutate_heartbeat_drop_check | `5311f3f6` | `# rc=0` | `mutation gate: 64 mutations, 0 survived` (:81); `every non-control check seen red: 103/103 (over 64 mutant runs); 9 control(s), 8 of them red too: ['and it is still rc 0', '(the run under observation` (:82) |
| mutate_l1_shell_scoring | `5311f3f6` | `# rc=0` | `Ran 162 checks, 0 failed` (:12); `===== 62 mutation(s): 62 killed, 0 survived =====` (:90) |
| check_gate_anchors | `5311f3f6` | `# rc=0` | `131/131 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` (:148) |
| nolab_tripwire | `5311f3f6` | `# rc=0` | `NOLAB-TRIPWIRE: 0 lab call(s); 1317 allowed switch launch(es) and 2991 --version probe(s), each re-checked: 0 breaking a condition, 0 refused by the w` (:13) |

44 logs

- tripwire（`nolab_tripwire.extb6m-5311f3f6.log:11-13`）讀了 extb6 與 extb6m 兩個 driver 的 shim log：0 個 lab 呼叫；1317 個交換機、2991 個 `--version`，每一行重驗：0 違反（含新的 cwd 條件）、0 被 wrapper 拒絕、0 以同一個 start time 還活著。交付前 `ps` 沒有 argv[0] 是 `ndt-hbdrop-bmv2` 的程序（OBSERVED）。
- 與第五輪（extb5c）相比：test_live_p1_external_evidence 151→202、mutate_live_p1_external_evidence 89→123（202/202）、test_live_p1_thirteen 46→47、mutate_live_p1_thirteen 13→14、mutate_p4_heartbeat_w 266→269、test_l1_shell_scoring 157→162（D32–D35 四格＋trunk 的新 suite 進了 corpus）、mutate_l1_shell_scoring 58→62、check_gate_anchors 130→131、selftest_08 多兩格；其餘相同。新增：redfirst_b6、selfcheck_b6、survey_34、test_ndt_status_measuring（102）、mutate_ndt_status_measuring（19 mutants, 0 survivor）。
- 沒跑的 trunk 新測試：`tests/python/test_ndt_serve*.py`、`tests/browser/*`、`mutate_ndt_serve*.sh`（GUI v2 的；B 沒有改 `tools/ndt_serve/**`）。

### R6.8 live run（要 Adam 在這個 session 授權 lab；這一輪**沒有**跑）

照 README「合併前的比對」第 0–7 步，`M=/home/adam/Desktop/NDTwin-Kernel`、`B_WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927`、`B_SHA=5311f3f60add32e9b92b2bf964db68a38419ae2a`、`LP=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1`、`ID="python3 $B_WT/$LP/code_identity.py"`：

```
# 0. orchestrator 宣布凍結；然後
C_HEAD=$(git -C $M rev-parse HEAD); [[ "$C_HEAD" == "$(git -C $M rev-parse trunk)" ]] || echo STOP
git -C $M merge-base --is-ancestor $C_HEAD $B_SHA \
  || [[ "$(git -C $M merge-tree --write-tree $C_HEAD $B_SHA | head -1)" == "$(git -C $M rev-parse $B_SHA^{tree})" ]] || echo STOP
# 1. C1、C2 各一次（完整的 06）
S=$(mktemp -d); $ID record $M $S/before.json
NDT_OWNER=<你> bash $M/$LP/06_thirteen.sh                     # raw 目錄 R
cp $S/before.json $R/00_identity.before.txt; $ID record $M $R/00_identity.after.txt
bash $B_WT/$LP/venv_fingerprint.sh $R/00_venv.txt $M/p4_proxy/venv/bin/python /home/adam/p4dev-python-venv/bin/python
# 2. 本地 merge
git -C $M merge --no-ff --no-edit $B_SHA; T_MERGE=$(git -C $M rev-parse HEAD)
[[ "$(git -C $M rev-parse $T_MERGE^1)" == "$C_HEAD" && "$(git -C $M rev-parse $T_MERGE^2)" == "$B_SHA" \
   && "$(git -C $M rev-parse $T_MERGE^{tree})" == "$(git -C $M merge-tree --write-tree $C_HEAD $B_SHA | head -1)" ]] || echo STOP
# 3. T
NDT_OWNER=<你> OLD_06=<C1> C_IDENTITY=<C1>/00_identity.after.txt B_SHA=$B_SHA PART=h5 bash $M/$LP/08_heartbeat.sh
# 4. H1-H4，仍在本地 merge 之下
NDT_OWNER=<你> bash $M/$LP/08_heartbeat.sh
# 5. 比對
python3 $M/$LP/external_evidence.py compare <C1> <T> --control2 <C2> --samples <08 run>/50_samples.tsv --b-sha $B_SHA
# 6. 通過 ⇒ push；否則
[[ "$(git -C $M rev-parse HEAD)" == "$T_MERGE" ]] && git -C $M reset --keep $C_HEAD || echo "STOP: HEAD is not T's merge"
# 7. 解凍
```

判定與每一種中途結果照 README「判定（預先登記）」。

### R6.9 沒做的、只推論的

- **live 從沒跑過**。sampler 的 `ctrl_logs` 能在 push 時看到 log 變大，靠的是控制器無緩衝寫 log（INFERRED，R6.3）；窗口、身分前後兩次、tutorials 的 digest 在 lab 上都是第一次。
- family-wise 上界約 54% 是上界之和；真正的誤判率不知道，34 個 round 只給了 0 次的點估計（README 的揭露，裁定接受）。
- `ndt app validate` 自己編的那一份 JSON（報告裡 `PASS p4c-bm2-ss … sha256:4780…`）不比；比的是控制器推的 `build/*.json`（notes:3）。
- claim 檔壞掉或讀不了時 drop check suite 不 skip（照 ndt 自己「malformed … treated as free」的讀法，ndt:5890）。
- proxy_unit 在 TMPDIR 留下 `ndtwin_link_pkg_*` 目錄（每次 10 個，notes:10），沒查是哪個測試；不是 B 改的檔，已刪。
- trunk 的 GUI v2 測試（python、browser、ndt_serve 的 mutate）沒跑（R6.7）。

### R6.10 Commits（`4c18bf3d..5311f3f6`，first-parent）

- `5311f3f6` Merge trunk 67ec9f9e into feat/external-detect-only-0927
- `1cf0692c` proxy: correct the census comment on the external arms
- `11309566` tests: skip the drop check suite while the lab is held or measured
- `2d54f270` live-p1: rewrite the pre-merge comparison procedure
- `9c860882` live-p1: record 06's code identity before and after the rounds
- `d74297fc` live-p1: freeze the rounds the decisive split rests on
- `c1b1c22f` live-p1: count heard frames inside the controller's own window
- `b938dee3` live-p1: record controller log sizes in the H5 sampler
- 本輪自己的改動（merge 之外）：`4c18bf3d..1cf0692c` 16 個檔。逐檔看過；新增行掃過秘密字串（0）；commit 訊息裡沒有禁用的字（一個 subject 原本用了 judge 當動詞，push 之前改寫，tree 不變，notes:4-5）。
- driver 與閘門工具（不在 repo）：`logs/gates-0910/extb6/aeg/`（gates_b6.sh、redfirst_b6.sh、redfirst_b6.cells、selfcheck_b6.sh、tripwire_b6.sh、patch_old_redfirsts_r6.py）、`extb6/make_hbwrap.sh`、`extb6/frozen/gates_b6m.sh`。
- scratch：dev 用的目錄都刪了；`/` 剩 2.7 GB。

第六輪（§R6）：head `5311f3f60add32e9b92b2bf964db68a38419ae2a`；extb6m 44 個閘門全部 rc 0（第一行都是這個 sha），tripwire 0；live 比對還沒跑（等 Adam 授權）。

DELIVERED 5311f3f60add32e9b92b2bf964db68a38419ae2a

## §R7 第七輪（round-6 re-review 在 `5311f3f6` 上：MERGE AFTER FIXES；只改 README 的 F1–F4、N1–N5，加三個不用 lab 的檢查）

[Co-developed with claude code -- Adam]

起點 `5311f3f6`，終點 `9054d0c4`（只有一個 README commit）。OBSERVED（我跑過、讀過的 log，附 log:line）與
INFERRED 分開寫。log 都在 `logs/gates-0910/`；findings 接在 `extb6-notes.log` 後面（:11 起）。**沒有用 lab。**

### R7.1 README（`9054d0c4`）

- `git diff --stat 5311f3f6..9054d0c4`：只有 `live-p1/README.md`（+140／−35）——OBSERVED。沒有閘門或腳本讀這份
  README（re-review 的 grep），所以 extb6m 的 44 個閘門照樣代表這棵樹的其他部分。
- **F4 變數檔**：`V=…/scratch/live-extb/vars`，開始前寫 `M`、`B_WT`、`B_SHA`、`LP`；每一步 `source "$V"` 後
  `: "${X:?}"`；`C_HEAD`、`C1`、`C2`、`T_MERGE`、`T`、`H5` 一知道就 `>> "$V"`（同名以後寫的為準）。變數檔不見時：
  `C_HEAD`＝`<C1>/00_identity.after.txt` 的 `head`；`T_MERGE`＝`<T>/00_identity.after.txt` 的 `head`，`parents`
  要等於 `[C_HEAD, B_SHA]`；T 還沒跑而已 merge：`HEAD` 只在 `HEAD^1==C_HEAD && HEAD^2==B_SHA` 時算數。
- **F2 第 2 步**：merge 前 HEAD==C_HEAD（否則 `trunk moved since step 0 -- no merge`，從第 0 步重來）、沒有 staged；
  merge 被拒 ⇒ `merge --abort`、確認 HEAD 仍是 C_HEAD、不跑 T；merge 之後的檢查不過 ⇒ 第 6 步、不跑 T、回報。
- **F1 第 6 步**：照 re-review 的形狀——guard、HEAD==T_MERGE、`reset --keep "$T_MERGE^1"`、`reset --keep` 被拒有
  自己的訊息、之後 HEAD==C_HEAD 才印 `ROLLED-BACK`，否則 `do not unfreeze`；登記：被拒 ⇒ 凍結不解除、主人把改動
  移走（別處 commit 或 stash，絕不 `--hard`／`checkout --`）再做一次；reset 成功而 HEAD≠C_HEAD ⇒ 回報、從第 0 步重來；
  第 7 步只在 `ROLLED-BACK` 或通過的 push 之後。**我改了兩處，理由**：
  - 多一個 `diff --cached --quiet` 的分支：演練（R7.2 case C）顯示 `reset --keep` 會把別人 stage 好、與 B 無關的檔
    **默默 unstage**（成功、rc 0，內容留著）——re-review 的形狀在這裡不會停。
  - 多一個「HEAD 已經是 C_HEAD」的分支：讓第 6 步重做一次時說「nothing to reset」，而不是假的 `HEAD is not T's merge`。
- **F3**：第一次比對的 rc 3——指令錯 ⇒ 改指令重比、不重跑；某個 run 因自己的內容被拒 ⇒ 那個 run 重做一次（對照組先
  第 6 步回復、第 1 步、第 2 步 merge，新 merge 的 tree 對舊的 `T_MERGE`）；同一種拒絕再一次 ⇒ 停下回報，不算通過也不算
  失敗。
- **N1** 凍結公告：trunk 不 commit／merge／push、不 stage；`git diff --name-only $C_HEAD $B_SHA` 那份清單不做未提交
  的改動；不重產圖、不寫追蹤的非 .md／.tsv 檔；第 1–4 步別人不 claim；這台機器不跑閘門或 mutation driver；操作者的
  `NDT_OWNER` 與閘門的不同。**N2** C1 跑完立刻 `unchanged_reasons(before, after)`，對上才跑 C2（C2 之後也比）。
  **N3** 工具一律用 `$B_WT/$LP/` 的那份。**N4** 讀不到的對照組：回復、重跑、再 merge（tree 對舊的），T 不重跑。
  **N5** 一句：rc 1 與對照組分歧同時出現時，重跑最好只到 rc 2 ⇒ 不跑第三次，C3／C4 走不到——登記好的結果，照做。

### R7.2 演練第 0、2、6 步（`extb7-rehearsal.log`）

- 方法：`git clone` 主 checkout 到 scratchpad（**不是** `git worktree add`），clone 停在 trunk `67ec9f9e`；從舊
  （`5311f3f6` 的）與新 README **逐字抽出**第 0、2、6 步的程式區塊（`logs/gates-0910/extb7/extract.py`；harness `extb7/rehearse.sh`），舊的照它的假設在同一個 shell 跑
  （變數留著），新的每一步一個新 shell、經變數檔；第 1 步（06）不演練，`C1`、`C2` 填假路徑。每一個 case 一個新 clone，
  跑完刪掉。新 README 的 sha256 `986c51a059657e25`＝commit 進去的那份（log:1）。B 是 `5311f3f6`（只差 README）。
- 結果（OBSERVED，log 的 verdict 行在最後）：

| case | 舊的文字 | 新的文字 |
|---|---|---|
| A merge 之後別人改了 `tools/test_workflow/ndt`（B 也改它） | **紅**：`reset --keep` 被拒，印的是假的 `STOP: HEAD is not T's merge`，B 留在 trunk，沒有一句說凍結不解除（:2-9） | **綠**：`reset --keep refused …` ＋ `do not unfreeze`，改動還在；主人 stash 後再做第 6 步：`ROLLED-BACK`（:10-22） |
| B 第 0 與第 2 步之間有人 commit 到 trunk | **紅**：merge 疊在那個 commit 上、只印 `STOP`；照「先回復」做第 6 步，`--keep $C_HEAD` 把那個 commit 從 trunk **拿掉**（:23-29） | **綠**：`trunk moved since step 0 -- no merge`，那個 commit 還在、B 沒 merge（:30-38） |
| C merge 之後別人 stage 了 README.md（B 不改它） | **紅**：第 6 步成功，那個檔**被 unstage**（:39-43） | **綠**：`staged changes … no reset` ＋ `do not unfreeze`，仍 staged；stash 後 `ROLLED-BACK`（:44-54） |
| C0 merge 之前就 staged | 參考：merge 被拒、只印 `STOP`；這個 harness 接著跑了第 6 步，把它 unstage（舊文字的「merge 被拒」那條其實不叫第 6 步）（:55-63） | `staged changes … no merge`，仍 staged（:64-71） |
| D 第 6 步在新的 shell、`C_HEAD` 空了 | **紅**：`git reset --keep` 沒有目標、rc 0、沒有 STOP，B 留著（:72-76） | **綠**：`C_HEAD: parameter null or not set`，rc 1，什麼都沒 reset（:77-84） |

- 開跑前 `df /` 2738 MB（log:1）；clone 都刪了（`ls clone-*` 0 個）。

### R7.3 身分的 pre-flight（`extb7-preflight.log`）

- 這台機器上對主 checkout 連續 `code_identity.py record` 兩次（1.97 s、0.43 s），中間什麼都沒做：`unchanged_reasons`
  ＝`[]`（OBSERVED）。順便看到（未提交的觀察）：`$M` 在 trunk `67ec9f9e`、tree `274a9e4c`，7 個未提交的追蹤檔（四張
  `doc/2026-08-29_bmv2-performance-study-figs/` 的圖、兩個 dryrun log、`p4_proxy/mininet/host_count_override`），
  **沒有一個是 B 改的檔**；`~/tutorials` HEAD `c80d83e9`、1 個未提交的檔（basic.p4，第六輪 notes:2 那個）；fabric bmv2
  `3ff54b5c…`、9 個 shared object。四張圖在比較範圍內——N1 的「不重產圖」就是為了它們。

### R7.4 N6：GUI v2 的測試與 ndt_serve 的閘門，在 merged head `9054d0c4` 上

- 怎麼跑：照 `gui/HANDOFF-ndt-serve-1001.md` §3；suite、main gate、page suite 各經 guard（JOBS=1 LOCK_WAIT=10800），
  page gate 不包 guard（它自己對每個 build 與 Chrome 取鎖）；每個之前 `/` ≥ 2 GB。`web/node_modules` 從 GUI 的 worktree
  `cp -a` 一份到我的 worktree（兩邊的 `package-lock.json` sha256 相同 `205ad129…`；被 web/.gitignore 擋著，status 乾淨）。
- 結果（OBSERVED，`gui_*.extb7-9054d0c4.log`，driver 輸出 `extb7-gui.out`）：

| 跑的 | 3.12 | 3.8 | handoff 的預期 |
|---|---|---|---|
| test_ndt_serve.py | **75 跑、2 FAILED**（:136-138） | **75 跑、2 FAILED** | 75 OK |
| test_ndt_serve_cells.py | 35 OK | 35 OK | 35 |
| test_ndt_serve_gui.py | 39 OK | 39 OK | 39 |
| test_ndt_serve_web.py | 18 OK | 18 OK | 18 |
| mutate_ndt_serve.sh | **rc 2：baseline 紅，拒跑**（:12-13） | **rc 2，同上** | 198／0 |
| page suite（test_ndt_serve_page.py） | 32 OK，每個 class 的 chrome leftovers 0（:59-61） | — | 32 OK |
| mutate_ndt_serve_page.sh | 58／0＋3 個等價，rc 0（重跑，見下） | — | 58／0＋3 個等價 |

- **🔴 兩個紅格是 B 造成的，而且會擋住通過之後的 push**：
  - `RcProvenance.test_code_sourced_tables_are_in_ndt`：12 個 RC_SOURCE 的行號引用不再指向它們的行（例：
    `status.check rc 3: ndt:7086 is 'printf …apps…' in cmd_status, cited as 'return 3'`，log:106-110）；
  - `RcProvenance.test_lock_probe_citations_are_lock_probe`：`README.md:78 cites ndt:9452-9467; lock_probe's comment
    starts at 9567 … ends at 9592`（log:121-125）。
  - 同一個 suite 在 trunk `67ec9f9e` 的 clone 上：75 OK（`gui_test_ndt_serve_py312.trunk-67ec9f9e.log`）。ndt 在 trunk 是
    11110 行，在 B 是 11227 行（B 第五輪對 ndt 的 +127／−10）：GUI 用**行號**引 ndt，B 的行數一動就紅——handoff §5 寫過這個
    陷阱（"When ndt's line count moves … verbs.RC_SOURCE line numbers, the lock-probe citations in README and serve.py
    comments, and main-gate anchors M61/M64/M65 move together"）。
  - 修法要動 `tools/ndt_serve/verbs.py` 的 RC_SOURCE、`tools/ndt_serve/README.md`、serve.py 的註解、`mutate_ndt_serve.sh`
    的 M61／M64／M65——不是 B 的檔，也不是這一輪（只改 README）的範圍。**我沒有改**；交給 orchestrator 決定由誰、在哪個
    commit 修（B 上、或 merge 之後在 trunk 上）。在修好之前，通過之後的 push 不能做（README 第 7 步要這些綠過）。
- page gate：第一次（`gui_mutate_ndt_serve_page.extb7-9054d0c4.log`）rc 2——**我的錯**：TMPDIR
  `/tmp/claude-1000/g7` 太長，Chrome 的 SingletonSocket 108 > 107 bytes（handoff §3 寫過）。用 `TMPDIR=/tmp/r7` 重跑：
  `58 mutation(s), 0 survivor(s); 3 documented equivalent(s), 0 broken`、rc 0（`gui_mutate_ndt_serve_page.extb7b-9054d0c4.log:294-296`）＝handoff 的預期。

### R7.5 live 程序要多久（INFERRED，從主 checkout 的舊 raw 算）

- 完整的 06（26 臂）：8 次 22.1–29.3 分鐘，最近 4 次 26.7–27.3（`live-p1/runs/*_06_thirteen` 的目錄名到最後一個檔的
  mtime）。08 `PART=h5`（06＋01）：27.4、27.5 分鐘（09-26 兩次）。08 H1–H4：一次完整的 6.1 分鐘（09-26 152605Z）。
  01：0.4–0.8 分鐘。身分記錄每次約 2 s，compare 幾秒。
- **一次程序**（C1、C2、merge、T、H1–H4、compare、回復或 push）：27＋27＋27.5＋6 ≈ **88 分鐘**純跑，加每一步之間的
  檢查與轉手（估 2–3 分鐘 × 8 步）≈ **1.7 小時**。在 Adam 的 1–2 小時之內，但靠近上限。
- **最壞情況**：
  - 加那一次 T 重跑：＋28 分鐘 ⇒ 約 **2.2 小時**；
  - 改走 C3／C4（回復、兩個 06、重新 merge）：＋55–60 分鐘 ⇒ 約 **2.7 小時**；
  - 讀不到的對照組重跑一次（回復、06、merge）：＋28 分鐘；
  - 最壞的組合（一次 T 重跑＋C3／C4）≈ **3.2 小時**。
- **明說**：任何一條重跑的路都**明顯超過** 1–2 小時的授權；第一次比對之後若要重跑，應先回頭問 Adam，而不是在同一個
  授權裡做下去。一次乾淨的程序本身約 1.7 小時。

### R7.6 沒做的、只推論的

- live 仍然沒跑（等 orchestrator 的 go-ahead）。
- GUI 的兩個紅格與 main gate 沒修、沒跑成（R7.4）——它們擋的是通過之後的 push，不擋 live 的比對本身（INFERRED：
  live 只用 ndt 與 live-p1 的工具，不碰 ndt_serve）。
- 演練只覆蓋 git 的部分（第 0、2、6 步）；第 1、3、4 步的指令（06、08、記錄身分）只讀過、沒在 clone 裡跑——它們要 lab。
- 時間估計是從舊 raw 推的，不是量的。
- 交付前：`ps` 裡沒有我起的背景迴圈；scratch（`r7/` 的 clone、`/tmp/claude-1000/g7`、`/tmp/r7`、我 worktree 裡複製的
  `web/node_modules`）刪了。

### R7.7 Commits

- `9054d0c4` live-p1: make the pre-merge procedure safe to run step by step（只有 README；訊息掃過禁用字：0）

第七輪（§R7）：head `9054d0c40…`（README-only，對 `5311f3f6`）；演練 4 個 case 舊紅新綠、pre-flight 空；GUI v2 的
test_ndt_serve 在 merged head 上有 2 格因 B 的 ndt 行數而紅（trunk 上綠），沒修，交 orchestrator。

### R7.8 live 的指令（照 README 第 0–7 步，就是會跑的樣子；等 go-ahead）

`B_SHA=9054d0c40…`（下面寫完整 sha）。每一個 ``` 區塊是一次獨立的呼叫；任何一行印 `STOP` ⇒ 不做下一步、照 README 的登記處理。
見交付訊息的結尾（逐字取自 README `9054d0c4`）。

## §R8 settled() 的規則：用 iperf server 的 total，不用 client 的 Sent（`9b5c0607` → `75b5dd0e`）

[Co-developed with claude code -- Adam]

起點 `9b5c0607`，終點 `75b5dd0e`（一個 commit）。診斷照 `logs/orchestrator-0924/intake-0926/extb/INVESTIGATE-unreadable-1002.handback.txt`
與 `scratch/live-extb-pre/investigate/`（table／proposed／skel.out、NOTES.txt），我都讀過。**沒有用 lab、沒有 push、沒動 trunk 與主 checkout。**
log 都在 `logs/gates-0910/`，tag `extb9-75b5dd0e`。

### R8.1 改了什麼（OBSERVED，`git diff --stat 9b5c0607..HEAD`：只有 EE、TS、MG 三個檔，+462／−37）

- **EE**：`report_evidence` 多讀 client 檔裡 `Server Report:` 之後那行的 `lost/total`（`SERVER_REPORT`、`LOST_TOTAL`，與 `SENT` 同一種寫法），放在 `iperf["server_total"]`。
  `expected_s1_in` 拿掉，`settled()` 改成：最後一塊與前一塊相同 ⇒ settled；否則
  - p4runtime/skeleton：s1 ingress 100 ＝ pings（照舊，精確相等）；
  - p4runtime/solution：(a) client 收到 server 的 ack（有 Server Report 的 total、沒有 "did not receive ack"）、(b) 同一塊裡 s2 egress 100 ＝ s1 ingress 100、
    (c) pings＋D ≤ s1 ≤ pings＋D＋`IPERF_FIN_RETRIES`，D＝server report 的 total（iperf 不是打 10.0.2.2 時為 0，與舊碼對 target 的處理相同）。
  - UNREADABLE 的訊息點名是哪一條沒過（no ack／no Server Report、s2e≠s1、低於下限、高於上限、skeleton 不等於 pings）。
  - docstring 寫明：沒有 server report 時只有 (i) 能 settle，**沒有任何更早的 round 以資料支持這種情況**（唯一的 no-ack round 是 09-19 那四個，轉送已經壞了）。
  - `invariants()` 沒動（描述性的那條仍用 Sent）⇒ survey 的輸出不變（R8.4）。
- **TS**：
  - mk 的預設 iperf client 檔多了 081205Z 那三行 Server Report（`0/3499`）；`no_ack=1` 時預設沒有；`server_report=0|1` 可強制。
  - `real.txt`：12 個凍結的 p4runtime/solution round 的**最後兩塊 counter 與 iperf client 那幾行**，逐字取自主 checkout `runs/`，每段標了來源檔與行號
    （log `:54-65` 或 `:114-125`；iperf_client `:6,9,10[,11,12]`；報告的 pings 行）。**10-02 的三個 round 沒有放進去、也沒拿來當證據。**
  - 新格：12 個 real round（7 個 rc 0；175425Z 與四個 09-19 rc 2＋點名原因）、每個條件各一格（t_eg2、t_over、t_top、t_ackwarn、t_noreport、t_noreport2、t_skel_unset），t_unset 多一格點名下限。
  - TS:642-645 那段過時的註解與格名改了（3504 ＝ pings＋server 的 3499，不是「少一個」）。
- **MG**：E41 的 anchor 換到新碼；E78 跟著格名改；新增 E96–E106：重複塊、ack 的兩半（warning 被忽略／沒有 report 當成 Sent−1）、s2e＝s1、下限（`<` 與拿掉）、上限（不留 FIN 餘量與拿掉）、用 Sent 代替 Total、把 lost 當 total、skeleton 的 pings。

### R8.2 既有格的預期結果有沒有變（OBSERVED）

沒有一格的預期 rc 或預期字串改變；改的是三格的 fixture，理由：
- **t_lost**：拿掉 `reads_extra=1`。3504 現在由 (ii) settle，不需要重複塊——這正是真實資料的形狀；這格在舊碼上變紅（redfirst_b9 :146）。
- **t_eg**（3505／3504）：加 `reads_extra=1`。s2e≠s1 的單一最後塊在新規則下是 UNREADABLE（這是規則本身，t_eg2 測它），這格要測的是不變式的描述行，所以讓它讀兩次。
- **t_trunc**：`truncate=p4rt_sol` → `p4rt_skel`。第一次在 `d08713cc` 上跑閘門時 **E21 存活**（`mutate_live_p1_external_evidence.extb9-d08713cc.log:31`，`every check seen red: 231/232`，:147-148）：
  被截斷的 solution 塊只有 s1，s2e 是 None ≠ s1，新規則也判它沒 settle ⇒ 「截斷」那條檢查拿掉之後 rc 照樣是 2，看不出來。
  搬到 skeleton（s1＝5＝pings 會 settle）後 E21 被殺。這是**新規則多擋了一層造成的遮蔽**，不是規則錯；修完後 amend 成 `75b5dd0e`，閘門全部重跑。
  `d08713cc` 那輪的 log（`*.extb9-d08713cc.log`、`extb9/gates_extb9.d08713cc.out`）留著，不算數。

### R8.3 看過紅（OBSERVED）

- `redfirst_b9.extb9-75b5dd0e.log`：新的 TS 對 `9b5c0607` 的 EE，rc 1，`Ran 232 checks, 21 failed`（:287）。六個 3504 round 在舊碼上 UNREADABLE：
  :194、:197、:200、:203、:206、:209；t_lost :146。081205Z 在舊碼上就是 settled（:212 ok），175425Z 舊碼也是 rc 2（:213 ok，只有點名原因那格紅 :214）。
- 新碼：`test_live_p1_external_evidence.extb9-75b5dd0e.log:256` `Ran 232 checks, 0 failed`。
- 每個新 mutant 都被殺：`mutate_live_p1_external_evidence.extb9-75b5dd0e.log` E41 :51、E96–E106 :106-116、E21 :31；`134 mutations, 0 survived`（:146）、`every check seen red: 232/232`（:147）。

### R8.4 閘門（`extb9/gates_b9.frozen.sh`，sha256 `bc9a1379…`；每個一個 guard，JOBS=1 LOCK_WAIT=10800，磁碟下限 1536 MB 排隊前與鎖下各查一次，nolab shims 在 PATH 上）

| gate | first line | last line | result, log:line | 對 extb6m |
|---|---|---|---|---|
| redfirst_b9（預期 rc 1） | `75b5dd0e` | `# rc=1` | `Ran 232 checks, 21 failed` (:287) | 新 |
| test_live_p1_external_evidence | `75b5dd0e` | `# rc=0` | `Ran 232 checks, 0 failed` (:256) | 202 → 232 |
| survey_34 | `75b5dd0e` | `# rc=0` | `34 rounds, every report and controller log as frozen, none with the heartbeat` (:7) | 本體與 extb6m 逐行相同 |
| check_gate_anchors | `75b5dd0e` | `# rc=0` | `131/131 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)` (:144)；本 gate `ok(129)` (:75) | 131/131 相同 |
| mutate_live_p1_external_evidence | `75b5dd0e` | `# rc=0` | `134 mutations, 0 survived` (:146)；`every check seen red: 232/232 (over 134 mutant runs)` (:147) | 123 → 134；202/202 → 232/232 |

- 讀 EE 的閘門（`git grep external_evidence`）：只有 `external_survey.py` import 它；TS 跑它、MG 經由 TS 跑它的 mutant、check_gate_anchors 讀 MG 的 anchor。
  `06_thirteen.sh`、`08_heartbeat.sh`、`code_identity.py`、`test_live_p1_thirteen.sh`、`tools/test_workflow/ndt`、README 只在註解或文字裡提到它，不讀不跑 ⇒ 沒有再跑。
- tripwire：0 行（`extb9/gates_extb9.out`）。
- **survey 再查**：`external_survey.py`／manifest 從 `5311f3f6` 到 HEAD 沒變（`git diff --stat` 空）；`survey_34.extb9-75b5dd0e.log` 去掉表頭後與 `survey_34.extb6m-5311f3f6.log` `diff` 無差異。

### R8.5 新的 settled() 在 15 個 p4runtime/solution round 上（`settled15.extb9-75b5dd0e.log`，腳本 `extb9/settled15.py`）

| round | 凍結？ | 新規則 | 原因（只有凍結的才印） | 舊規則（9b5c0607） |
|---|---|---|---|---|
| 09-19T055210Z | 是 | UNREADABLE | no ack（did not receive ack） | UNREADABLE |
| 09-19T065612Z | 是 | UNREADABLE | no ack | UNREADABLE |
| 09-19T085331Z | 是 | UNREADABLE | no ack | UNREADABLE |
| 09-19T085746Z | 是 | UNREADABLE | no ack | UNREADABLE |
| 09-19T151037Z | 是 | settled | | UNREADABLE |
| 09-24T162954Z | 是 | settled | | UNREADABLE |
| 09-24T192012Z | 是 | settled | | UNREADABLE |
| 09-26T061642Z | 是 | settled | | UNREADABLE |
| 09-26T062438Z | 是 | settled | | UNREADABLE |
| 09-26T155814Z | 是 | settled | | UNREADABLE |
| 09-26T175425Z | 是 | UNREADABLE | s2 egress 3821 ≠ s1 ingress 3820 | UNREADABLE |
| 09-27T081205Z | 是 | settled | | settled |
| 10-02T114342Z | 否（受測） | settled | — | UNREADABLE |
| 10-02T121113Z | 否（受測） | settled | — | UNREADABLE |
| 10-02T124023Z | 否（受測） | settled | — | UNREADABLE |

與調查者的 `proposed.out` 一致（12 個凍結的逐一相同）。今天的三個：只印了 settled／UNREADABLE；沒有跑 `compare`、沒有印任何判定欄位。
（明說：`settled()` 的輸入要經過 `controller_evidence`／`report_evidence`，它們在記憶體裡會把整個 log 解析一遍；除了 settled 的結論，沒有印出、存下或比較任何別的值。）

### R8.6 INFERRED／沒做的

- 「iperf 的 Sent 多算一個（FIN 或多一個 id）」仍是推論，沒對 iperf 原始碼查（照調查者的說法）。
- 沒有 server report 的情況（client 輸出被截、或沒 ack 但轉送正常）只靠重複塊；**沒有資料支持**這個分支在真實 round 上的行為。
- 上限 `pings＋D＋10` 的「10」借自 no-ack 的 FIN 重試上限；acked 時實測只看過 +1（081205Z），10 是寬鬆的推論值。
- target 不是 10.0.2.2 時 D 記 0：沿用舊碼的寫法，沒有資料。
- 只跑了讀 EE 的閘門；R6.7 其他 40 個閘門沒有重跑（這個 commit 只動這三個檔）。
- 交付前：我起的背景迴圈都停了，`ps` 沒有 `gates_b9`／`mg_subset`；scratchpad 裡我的檔與 `extb9/tmp` 已刪。

### R8.7 Commit

- `75b5dd0e` live-p1: read iperf's server total when deciding a counter block settled（三個檔；訊息掃過禁用字與 trailer：0）

## §R8b 第八輪之二：README 的登記、10-02 資料上的就緒檢查、舊的 red-first 閘門（`75b5dd0e` → `bcdeca0e`）

[Co-developed with claude code -- Adam]

re-review（`judge-EXTB-75b5dd0e-r8.md`）判 MERGE AFTER FIXES，只改 README；EE、TS、MG 這一輪**不動**。**沒有用 lab、沒有 push、
沒動 trunk 與主 checkout**（主 checkout 只讀 `live-p1/runs/` 的 10-02 目錄）。log 在 `logs/gates-0910/`，tag `extb10-bcdeca0e`。

### R8b.1 README（`bcdeca0e`，OBSERVED：`git diff --stat 75b5dd0e..HEAD` 只有 `live-p1/README.md`，+57／−10；commit 訊息掃禁用字與 trailer：0）

- **F1**：新增「第八輪改了什麼」（README:447 起）——10-02 那次（B_SHA `9b5c0607`、六個 raw 目錄、第 5 步 rc 2 停在 C1 的
  p4runtime/solution、沒有印判定欄位、ROLLED-BACK）、Adam 的 form 9（重新跑、10-02 永不比）、修改（`75b5dd0e`、EE sha256
  `69bccf77…`、只用凍結 round 的理由、放寬與收緊各是什麼——含 re-review 指出的「no-ack warning 那一半本來就只靠重複塊」）、
  settled15 的結果（`settled15.extb9-75b5dd0e.log:17-19`）。「為什麼現在改預先登記是正當的」的（1）更正為只對第六輪成立（:726），（4）補上第八輪就是照它改的（:729-731）。
- **F2**：第 0 步把 `START=<UTC stamp>` 寫進 `$V`（:519）；「找回來」只算名字的時間戳晚於 `START` 的 raw 目錄（:498-501），
  第 1 步的 raw 目錄不晚於 `START` 就 STOP、不寫進 `$V`，第 5 步四個目錄都查；兩處「沿用」限於同一個 `START` 的 C1、C2（:576、:675）。
  時間戳比較（`[[ a > b ]]`，en_US.UTF-8）我試過跨日、跨月、差一秒三種：都對。
- **F3**：「判定」第一條（:638），照 orchestrator 給的英文原句，加中文說明：讀法的錯 ⇒ 停、回復、回報 Adam，不在改過的讀法下重比，也不走「重跑那一個 run 一次」。
- **N1**：＋10 是推論；acked 看過最多＋1；第一個 FIN 在 D 裡，所以大概最多＋9；為什麼不改。**N4**：描述用的不變式仍用 Sent，每個正常 round 都印 `inv ..`。
- **N5**：第 0 步算 EE 的 sha256 寫進 `$V`（`EE_SHA`），不等於登記的 `69bccf77…` 就 STOP；第 5 步比對前再算一次、寫成
  `EE_SHA_AT_COMPARE` 並印出，不同就 STOP；第 5 步改成任何 STOP 都**不執行** compare（`(( ok )) &&`，:593-599）。
- 沒有閘門讀 README（re-review Q4 與第六輪的確認）⇒ README 的改動不需重跑 extb9 的閘門。

### R8b.2 10-02 資料上的就緒檢查（`readiness.extb10-bcdeca0e.log`，腳本 `extb10/readiness.py`，EE sha256 `69bccf77…`）

**呼叫的**（`external_evidence.py` 在 HEAD 的行號）：`table_rows` :203、`controller_log` :217、`controller_evidence` :247、
`report_evidence` :297、`settled` :341、`arms` :403、`read_samples` :476、`t06_end` :514、`check_roles` :632（裡面是
`session_evidence` :522、`push_offset` :567、`heard_evidence` :589）、`programs_same` :753。
**刻意不呼叫的**：`identities` :717（10-02 live 已經跑過、通過）、`compare` :769（含判定欄位的迴圈 :821 與結論 :859-863）、
`invariants` :428、`within` :676、`show` :701、`header` :693、`fingerprint` :654、`fmt` :667、`main` :866。`check_roles` 的回傳值
（含 daemon 計數與 heard 的數字）**不印**，只印每臂的 heard 窗口有沒有 UNDECIDED。

| stage | run | 結果（log 行） |
|---|---|---|
| settled p4runtime/skeleton | C1／C2／T | ok／ok／ok（:6、:9、:12） |
| settled p4runtime/solution | C1／C2／T | ok／ok／ok（:7、:10、:13） |
| settled flowcache/solution | C1／C2／T | ok／ok／ok（:8、:11、:14；這一臂 `settled()` 不檢查，ok 是空的） |
| arms | C1／C2／T | ok／ok／ok（:15-17） |
| programs_same | C1,C2,T | ok（:18） |
| read_samples | H5 | ok（:19） |
| t06_end | H5 | ok（:20） |
| check_roles（對照組 C1、C2；處理組 T；heard 窗口） | C1,C2,T,H5 | ok（:21） |
| heard 窗口 p4runtime/skeleton／solution／flowcache/solution | T,H5 | ok／ok／ok（:22-24） |

`readiness: 0 FAIL`（:25），`# rc=0`（:27）。OBSERVED：從來沒在 live 資料上跑過的四個階段，在 10-02 的資料上都讀得過去。
INFERRED：同一套 `compare` 在新的 run 上不會在這四個階段因為讀法而停下——只對與 10-02 同形狀的資料成立；`compare` 裡判定欄位的
那一段（:821 起）仍然沒有在 live 資料上跑過，這是刻意的（form 9）。

### R8b.3 舊的 red-first 閘門（`scripts-extb6m-5311f3f6/gates_b6.sh` 原封不動，`TAG=extb10 ONLY_GATES="redfirst_b redfirst_b2 redfirst_b3 redfirst_b5 redfirst_b6"`）

腳本與 `extb6/aeg/` 的來源逐一 `cmp` 相同、extb6m 的 SHA256SUMS 對得上、hbsnap 的 sha256 對得上；跑的是 `scripts-extb10-bcdeca0e/` 裡的副本。
每個一個 guard（JOBS=1 LOCK_WAIT=10800），nolab shims 在 PATH 上，drop check 經 hbwrap。

| gate | first line | last line | result, log:line |
|---|---|---|---|
| redfirst_b | `bcdeca0e` | `# rc=0` | `REDFIRST-B: ALL-AS-EXPECTED` (:90) |
| redfirst_b2 | `bcdeca0e` | `# rc=0` | `REDFIRST-B2: ALL-AS-EXPECTED` (:92) |
| redfirst_b3 | `bcdeca0e` | `# rc=0` | `REDFIRST-B3: ALL-AS-EXPECTED` (:330) |
| redfirst_b5 | `bcdeca0e` | `# rc=0` | `REDFIRST-B5: ALL-AS-EXPECTED` (:40) |
| redfirst_b6 | `bcdeca0e` | `# rc=0` | `REDFIRST-B6: ALL-AS-EXPECTED` (:57) |
| nolab_tripwire（extb10 的 shim log） | `bcdeca0e` | `# rc=0` | `0 lab call(s); 42 allowed switch launch(es) and 79 --version probe(s) … 0 breaking a condition, 0 refused … 0 still running` |

driver：`GATES-extb10 bcdeca0e: ALL-AS-EXPECTED`；`trunk: 67ec9f9e… throughout (not moved)`（`extb10/gates_extb10.out`）。kept 輸出在 `redfirst_b*.extb10-bcdeca0e.kept/`。
redfirst_b4 不在這一輪的清單裡，沒跑。

### R8b.4 trunk（OBSERVED）

`git -C /home/adam/Desktop/NDTwin-Kernel rev-parse trunk` ＝ `67ec9f9ecf9caf9d7df8cc92c4166cd04b79af34`，是 `bcdeca0e` 的祖先（`merge-base --is-ancestor` rc 0），
跑閘門的前後都沒動。

### R8b.5 沒做的、只推論的

- N2（每臂各自讀不到）、N3（下界訊息帶 lost 數）、N6（manifest 不雜湊 iperf_client.txt）照裁定留到之後。
- re-review 的 test 2–4（skeleton 的 real-data 格、target≠10.0.2.2 的格、讀 iperf 原始碼決定 9 或 10）沒做。
- 就緒檢查會把 10-02 的整個控制器 log 與 samples 讀進記憶體；印出的只有 ok／FAIL（沒有 FAIL）。
- 交付前：我起的背景迴圈都停了（`ps` 沒有 `gates_b6`／`redfirst`／我的 `until`）；沒有留下 tmp 目錄（`extb6/tmp` 只有目錄 mtime 變了）。

### R8b.6 Commit

- `bcdeca0e` live-p1: record the 10-02 run and the settled() change in the procedure（只有 README）
