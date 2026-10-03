# SUMMARY：external control plane 也跑心跳，只偵測（feat/external-detect-only-0927）

- **分支**：`feat/external-detect-only-0927`，照指示從 AEG 的 `ebe17f7c` 開出（不是 trunk），AEG 修正輪 `f7e2a128` 已 merge 進來（`b01ad9b9`）。
- **Worktree**：`scratch/overnight-2026-09-05/wt-external-detect-0927`，`p4_proxy/venv` 與 `p4_proxy/p4_src/build` 連到主 checkout。
- **Head**：第四輪是 ``faf6eb410c2cb0b38b06c86000bdc65b21c8ac7a``（§R4）；第三輪 `480e9f2e`（§R3）；第二輪 `14921f98`（§0）；第一輪 `17e40e29`（§6 列出 commit）。
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

### R4.3 red first、mutation、閘門——**停在途中（ABORTED），round 4 尚未 DELIVERED**

- 21:2x orchestrator 通知 Adam 的額度用完、立刻收尾。我用 process group 停了 extb4 的 driver；它當時在等 guard 鎖跑 `mutate_app_package`（一個 mutation 都沒跑），那份 log 的最後兩行寫明 ABORTED。
- driver：凍結副本 `scratchpad/nolab2/frozen/gates_b4.sh`，tag `extb4`，head `faf6eb41`。它是 gates_b3 加上 redfirst_b4、test_heartbeat_drop_check、mutate_heartbeat_drop_check，drop check 的 simple_switch 經 wrapper 在 tripwire log 記 `ALLOWED-LAUNCH`，tripwire 閘門另外確認每個 pid 最後都不在。
- **跑完的 21 個全部 rc 0**（`logs/gates-0910/<gate>.extb4-faf6eb41.log`；我讀了各自的最後一行，第一行 sha 會在接手時一起核）：
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
  - 新增行裡的 `/home/adam` 只在 flowcache_solution.json 的 `program`／`source_info`（p4c 寫進去的原始碼路徑，同 `tools/p4_exercise/tests/fixtures` 的前例）。
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
- **twin 那側的另一個改變（第二輪揭露，F5）**：external 自己的 pipeline 上，`/ryu_server/all_destination_paths` 現在是在宣告連線上算的最短路徑（沒有已安裝的路由可讀），**不是** exercise 真正的轉發——是猜測，不是讀數。

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

第四輪（§R4）：head `faf6eb410c2cb0b38b06c86000bdc65b21c8ac7a`，已 commit；21 個閘門 rc 0，還有 5 個沒跑（§R4.3、§R4.6）——**尚未 DELIVERED**。
