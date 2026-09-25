# P4-HB-SUMMARY — TICKET-P4-heartbeat（第二刀：外來 P4 fabric 的 veth 心跳）

> 存檔說明（orchestrator）：worker HB 的 harness 不讓 subagent 寫報告檔，它把全文放在交件回覆裡；以下是該回覆的原文，由 orchestrator 於 09-25 存到本路徑，未改寫內容。

worker HB（opus）｜worktree `scratch/overnight-2026-09-05/wt-p4-heartbeat-0925`｜分支 `feat/p4-heartbeat-0925`｜base `62f76cf5`｜**最終 head `9fbedc39`**（`9fbedc392ec02c1b4dc1bf1117ca0cfd64e9ec22`）｜2026-09-25

這次只做段 H 和段 S 的離線準備。段 W 沒開工。沒 push、沒 merge、沒碰 lab、沒 `ndt up`、沒 sudo、沒建 C++。主 checkout 只寫了 `scratch/.../logs/gates-0910/*.p4hb-*.log`。

## 段 H — `ndtwin-lab heartbeat {start|stop|status}`

### H.0 結論
- **helper 改好了，但要重裝才會生效**：`tools/test_workflow/ndtwin-lab` 在 commit `8c930eb4` 加了 `heartbeat` 子指令（+1053／−1）。已裝的 `/usr/local/sbin/ndtwin-lab` 是 sha256 `6685d3a9…`，就是 base，還沒有這個動詞。
- **新測試 186 顆，紅燈先行**：`tests/shell/test_ndtwin_lab_heartbeat.sh`。在還沒有實作的 commit 上跑，92 顆紅 71 顆；到 head 全綠。
- **具名變異 32 個＋控制組 1 個**：`tests/shell/mutate_ndtwin_lab_heartbeat.sh`，**32 個全被點名的那顆抓到，0 存活**。
- **`check_gate_anchors` 全部 ok**：head `117/117`，base 對照 `116/116`。
- **既有 helper 相關 22 支 suite＋`test_testbed_banner.py`：只有一顆紅，是預期的**。`test_ndt_helper_apps_window.sh` 裡「已裝的 helper 就是這支 suite 讀的那份」那顆會紅，因為已裝的還是舊版。裝了就會綠（§H.4）。
- **口徑**：daemon 只記「每個方向最後一次在什麼時候被聽到」，不判上下、不改路。判定和改路是段 W 的事，用 proxy 自己的常數。

### H.1 設計
- **子指令**：`start`／`stop`／`status`，照工單字面，好讓 `ndt up／down／status` 一對一呼叫。`heartbeat` 後面只收一個字；其他任何參數（介面名、`--iface`、`--manifest`、`--ethertype`、pid）在被用到之前就拒絕。
- **介面清單的來源是 `/tmp/ndtwin_p4_switches.json`，不是 `up.target`，也不是 package 的 topology**：

  | 候選 | 誰寫 | 描述什麼 | 結論 |
  |---|---|---|---|
  | `up.target` | adam（每個 checkout 一份） | 上次要求了什麼，不含介面名 | 不用：adam 可寫 |
  | package `topology.json` | adam | 要求的拓樸 | 不用：adam 可寫 |
  | switch manifest | root 拓樸程序本身（mkstemp＋replace，0644） | 正在跑的每台交換機：pid、device_id、bmv2 argv | **用**：argv 裡的 `-i <port>@<ifname>` 就是介面 |

- **manifest 的信任規則**：
  - 開檔用 `O_NOFOLLOW|O_NONBLOCK`，同一個 fd 做 fstat。
  - 必須是一般檔、owner 是 root、group／other 不可寫。
  - 所在目錄必須是 root（或測試 uid）擁有，而且「沒人可寫」或「有 sticky」。
  - 每個 `-i` 必須等於 `<交換機名>-eth<port>`，否則整份拒絕。介面要在 `/sys` 存在，`ETHTOOL_GDRVINFO` 要回 `veth`。
  - 一條鏈路＝兩個 iflink 互相指向對方的 veth；只有單向指過去的不算。
  - 其餘介面視為 host-facing：只聽、永不送。
  - manifest 裡每台交換機的 pid 都要是活著的 `simple_switch_grpc`。
- **daemon 程式嵌在 helper 裡**（quoted heredoc），不放在 `KERNEL_DIR`：helper 是 root-owned、sha 被釘住的那份。每次 start 會寫到 `/run/ndtwin-lab/heartbeat.py`，再以 `/usr/bin/python3 -I /run/ndtwin-lab/heartbeat.py daemon` 執行。只用 stdlib。
- **幀格式**：60 bytes，ethertype **0x88B5**。dst `02:4e:44:54:48:42`，src 是送出介面自己的 MAC。body 依序是 magic `NDHB`／version／flags／session（8 bytes）／方向 id／seq／tx 和 rx 的 dpid:port。
  - socket：先以 protocol 0 建立，掛上 BPF（只收 0x88B5），再 bind `ETH_P_ALL`，這樣才看得到 OUTGOING。
  - 不設 `PACKET_QDISC_BYPASS`，讓 netem 能剪到。
- **什麼才算 heard**：必須是 INCOMING、本 session、到達該方向指定的 rx 介面、端點欄位和方向 id 一致。以下都只計數、不算 heard：
  - OUTGOING 副本 → `forwarded`
  - 收錯介面 → `misdelivered`
  - 其他 session → `foreign`
- **常數 `PERIOD_S=5`，不在執行期讀 proxy，而是用測試釘住**，理由兩個：
  - 執行期去讀 adam 可寫的原始檔，等於讓那個檔操縱 root 的送出頻率。
  - proxy 的有效值可能被 `NDTWIN_P4_BEACON_S` 覆寫，而 sudo 的 env_reset 讓 daemon 看不到這個變數，所以就算讀了也讀不到正確值。

  測試用 venv import proxy，斷言 `PERIOD_S == LLDP_BEACON_INTERVAL_S` 且 `LINK_BEACON_TIMEOUT_S == 3×PERIOD_S`。helper 裡沒有任何 timeout。
- **報告寫檔，不走 HTTP**：`/run/ndtwin-lab/heartbeat.json`，0644、原子替換。每輪必寫一次，聽到東西後 ≤0.5 s 內再寫。不讓 root 去 POST adam 擁有的服務，也避免開一條誰都能偽造的 localhost 路由。
- **保證只有一個 daemon**：start 先用 pidfile＋argv＋uid 認出活著的 daemon，是的話 rc 0、不 launch。兩個 start 同時競爭時，由 daemon 第一件事取的 `flock(LOCK_EX|LOCK_NB)` 決定，輸的 rc 2。
- **stop**：
  - pidfile 若是 symlink 就拒絕；內容必須符合 `^[1-9][0-9]{0,9}$`。
  - `/proc/<pid>/cmdline` 必須逐元素等於那四個字，而且 uid 必須是 0。
  - 然後 TERM，等 5 s，KILL，再確認一次。
  - 任何一項不符都當成 stale：不送任何訊號，刪 pidfile。
- **fabric 消失**：daemon 每輪檢查 manifest 還在、各介面 ifindex 沒變；否則把 `stopped`＋原因寫進報告，rc 4 退出。POLLERR 會先讀掉 SO_ERROR，避免忙迴圈。
- **退出碼**：

  | 對象 | 碼與意義 |
  |---|---|
  | start | 0 起了或已在跑；1 拒絕；**3 此 fabric 沒有交換機間鏈路**（例如單交換機，不是錯） |
  | stop | 0 |
  | status | 0 在跑；3 沒在跑 |
  | daemon 本身 | 1 拒絕；2 鎖被佔；3 無鏈路；4 fabric 消失 |

- **設定檔閘門**：`lab_conf_gate` 對 heartbeat 照「會動作的動詞」處理，設定檔壞掉就 fail closed。G-7 的 `status|config` 那一行沒動。

### H.2 helper diff（`62f76cf5..8c930eb4`）
1. 在 `ovs_topo_start` 之後、sourced-return 之前加一整段新的：
   - `HB_*` 常數
   - `hb_program`：約 770 行 Python——信任與解析、plan、編解碼、BPF、`Heartbeat` 帳本、報告、鎖、daemon 迴圈、只收 `plan|daemon|report` 的 CLI
   - bash 函式：`hb_refuse`、`hb_dir_trusted`、`hb_prepare_run_dir`、`hb_install_program`、`hb_run`、`hb_is_daemon`、`hb_read_pidfile`、`hb_pid`、`hb_signal`（唯一會送訊號的地方）、`hb_proc_gone`、`hb_launch`、`hb_log_tail`、`hb_start`、`hb_stop`、`hb_status`、`heartbeat_main`
2. dispatch 加一行：`heartbeat) shift; hb_rc=0; heartbeat_main "$@" || hb_rc=$?; exit "$hb_rc" ;;`
3. usage 加上 `|heartbeat {start|stop|status}`。
4. 其他既有動詞一個字沒改。檔案 mode 維持 100644：我一度誤改成 755，已在同一個 commit 用 amend 修回，被丟掉的 sha 沒有任何地方引用過。

### H.3 測試內容（非 root、離線、不開 packet socket）
1. **命令列**：各種多餘參數、`$(...)`、`*` 都被拒絕，而且什麼都沒執行。dispatch 那行和 usage 只能用原文釘（從 sourced 檔走不到，屬於讀碼檢查）。
2. **start**：
   - 沒有 topo session → 拒絕，且拒絕訊息要點名 topo session。
   - 已有活 daemon → rc 0、不 launch。
   - plan 失敗 → 不 launch。
   - plan 回 rc 3 → start 也回 3。
   - 正常情況下只 launch 一次，而且在 plan 之後。
   - 用替身程式走真實 launch：start → 以 argv 認得 → 再 start 不重複 → stop。
   - run dir 的信任規則；安裝進去的程式與 heredoc 逐位元相同、0644。
3. **stop**：
   - pidfile 指向真的 `sleep` → 它還活著。
   - 替身 daemon → 能停掉；但要求 uid 0 時不認它。
   - argv 多一個字、或程式路徑不同 → 不認，而且那個 process 還活著。
   - 八種垃圾 pidfile → 一個訊號都沒送。
   - symlink pidfile → rc 1。
4. **介面**：
   - pod-topo 夾具：host 埠的 iflink 故意撞到 s3-eth1 的號碼。
   - 真實 bring-up 產生的 manifest 能解析。
   - 以下都拒絕：manifest 缺失；本 uid 在 root 的 sticky `/tmp` 裡擁有的檔（用來單獨驗 owner 檢查）；他人的目錄；group 可寫；symlink；FIFO（5 s 內拒絕、不卡住）；world-writable 但不是 sticky 的目錄（加上 sticky 就過）；有死掉或冒名的 bmv2；介面名不是 `wlp0s20f3` 這類 `<switch>-eth<port>`；非 veth；單向 iflink；介面缺失；五種壞欄位。
   - 真實 ethtool：`lo` 不是 veth；本機一個真 veth 回 veth。
5. **heard**：一輪一方向一幀；編解碼正確；OUTGOING、收錯介面、別的 session、偽造端點都不算 heard；用 BPF 迷你直譯器驗證只收 0x88B5。
6. **報告**：每方向正好 10 個觀測鍵、頂層正好 19 個鍵，沒有任何 up/down 欄位；`forwarded_to_hosts` 和 `forwarded_between_switches` 會計數；0644 且原子寫入；`status` 只顯示年齡。
7. **生命週期與釘子**：
   - 鎖：第二個 daemon 取不到。
   - `fabric_changed` 的四種情況。
   - 程式 CLI 拒絕多餘參數。
   - `PERIOD_S` 和 proxy 常數的釘子。
   - ethertype 不在 26 支 tutorials `.p4` 和 `ndtwin_switch.p4` 裡；掃描本身要看得到 0x0800、0x0812、0x1212、0x1234，確保不是瞎掃。
8. **daemon 迴圈端到端**：用 unix socket 當替身跑 `run_daemon()` 本體——
   - 起來後：pidfile、`running`、8 個方向、8 個 tx 各一幀、host 埠沒有送；
   - 送到對端 3 s 內 heard；OUTGOING 記成 `forwarded`；
   - 第二個 daemon rc 2；SIGTERM 後 rc 0 並寫 `stopped`；fabric 消失 → rc 4；單交換機 → rc 3；沒有 fabric → rc 1；
   - 最後：helper 的 `HB_RUN_DIR`／`HB_PIDFILE` 要等於程式裡的值。

### H.4 閘門
全部經 `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`，`setsid -f` 背景跑。log 都在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`。

**最終 head 9fbedc39：**

| log | 最後一行 |
|---|---|
| `test_ndtwin_lab_heartbeat.p4hb-9fbedc39.log` | `Ran 186 checks, 0 failed`／`# rc=0` |
| `mutate_ndtwin_lab_heartbeat.p4hb-9fbedc39.log` | `mutants: 32 named + 1 control; caught 32, survived 0, invalid 0`／`VERDICT: every mutation was caught by the check named for it; the control survived`／`# rc=0`；restore 逐位元相同，restore 後 suite 綠 |
| `check_gate_anchors.p4hb-9fbedc39.log` | HEAD `117/117 cells ok`；base 對照 `116/116 cells ok`；新閘門 `ok(33)`；錨在 helper 上的 4 支 `4/4 cells ok`；`# rc=0` |
| `spike_selftest.p4hb-9fbedc39.log` | `SPIKE SELF-TEST PASS`／`# rc=0` |
| `helper_suites.p4hb-9fbedc39.log` | `suites: 1 red`／`# rc=1`：21 支＋banner 全綠；紅的是 `test_ndt_helper_apps_window.sh` 150 顆裡的 1 顆 |

那一顆紅的原因見 `installed_helper_sha.p4hb-9fbedc39.log`：已裝的 `6685d3a9…` 等於 base，不等於 head 的 `d504af41…`。這顆檢查就是設計來比對已裝的和 repo 的，Adam 重裝後就會綠。

**紅燈與歷程：**
- `test_ndtwin_lab_heartbeat.red.p4hb-8be43e77.log`：`Ran 87 checks, 67 failed`。
  - 這輪有儀器問題：背景子程序遇到 `set -u` 死掉，執行了繼承來的 EXIT trap，把 TMPROOT 刪了，Python 那幾節沒跑到。
- `test_ndtwin_lab_heartbeat.red.p4hb-9b17f8f9.log`：`Ran 92 checks, 71 failed`。
  - 還是沒有實作，但所有節都跑到了。
- `*.p4hb-32a25b23.log`：suite 186／0。
  - mutate 那輪 31 個 caught，1 個「紅了但不是點名的那顆」（`no-topo-check`）：只看 rc 的那顆檢查，被「launch 了但替身 daemon 以 rc 1 死掉」混過去。
  - 在 `9fbedc39` 把那顆改成同時看拒絕原因，重跑後 32／32。

### H.5 ethertype 碰撞表（讀過；06 的 13 個練習，skeleton＋solution 共 26 支，另加 NDTwin 自己的 pipeline）

| 練習 | 16-bit 常數 | 對 etherType 的 select |
|---|---|---|
| basic | 0x800 | solution：0x800→ipv4，default accept；skeleton：沒有 select |
| source_routing | 0x800、0x1234 | solution：0x1234→srcRouting；skeleton：沒有 select |
| calc | 0x1234 | 0x1234→check_p4calc |
| multicast | — | 只有 default accept |
| basic_tunnel | 0x1212、0x800 | solution：0x1212、0x800；skeleton：只有 0x800 |
| load_balance | 字面 0x800 | 0x800→ipv4 |
| qos、ecn、mri、firewall（三支）、flowcache | 0x800 | 0x800→ipv4 |
| link_monitor | 0x800、0x812 | 0x800→ipv4，0x812→probe |
| p4runtime（advanced_tunnel） | 0x1212、0x800 | 兩者 |
| ndtwin_switch.p4 | 0x0800、0x0806、0x88CC | — |

已用的值：{0x0800, 0x0806, 0x0812, 0x1212, 0x1234, 0x88CC}。**0x88B5 和 0x88B6 都沒人用，選 0x88B5**。所有 parser 遇到未知 ethertype 都是 `default: accept`，沒有一支 reject。

### H.6 13 練習遇到心跳幀的預測（讀碼推得，未量）
- **calc、multicast 送不到**：06 的包裝裡它們是單交換機（看主 checkout 未提交的 `.test_run/packages/*-solution`），start 會回 3，一幀都不送。
- **basic skeleton**：無條件 `ipv4_lpm`，key 是 0.0.0.0，沒命中，走 default drop。
- **丟掉**：source_routing 兩臂（`drop()`）、flowcache solution（`drop_packet()`）。
- **egress_spec 維持 0**：其他練習都是。link_monitor 的 egress 會對 `byte_cnt_reg[0]` 加 60，但 index 0 不是真的埠。
- **egress_spec 0 會被丟**：bmv2 只綁模型裡的埠（從 1 起）。這點要段 S 驗。
- **結論與唯一的結構性風險**：預測沒有一支會把幀送到主機。唯一的結構性風險是 multicast.p4 的 `default_action=multicast`：如果被做成多交換機，未知 dst 的幀會被複製到 host 埠。那正是裁決 4 的停止條件，而 daemon 的 `forwarded_to_hosts` 和 host sniff 都會抓到。

### H.7 給段 W 的 proxy 端契約提案（本段沒有實作任何 proxy 程式碼）
1. **讀什麼、怎麼驗**：讀 `/run/ndtwin-lab/heartbeat.json`。先驗：一般檔、不是 symlink、owner 0、group／other 不可寫；父目錄也一樣。proxy 裡的路徑常數要有測試釘住它等於 helper 的值。
2. **心跳活著的判準**：`format==1`、`source=="heartbeat"`、`status=="running"`，而且 `time.monotonic()-written_mono <= 2×period_s`。`*_mono` 是 CLOCK_MONOTONIC，和 proxy 用的 `time.monotonic` 同一個時鐘。
   - **心跳死了不能被解讀成全網斷線**：watchdog 對這些鏈路的逾時必須凍結。
3. **比對 fabric**：用 dpid 和宣告的鏈路（`load_switch_links`）比對。宣告了但報告裡沒有的方向、或報告有但沒宣告的方向，都要揭露；`manifest_sha256` 用來辨認是不是同一次 bring-up。
4. **link key**：`(tx.dpid,tx.port,rx.dpid,rx.port)` 正好就是 LLDP 用的 `link=(sender dpid, sender port, receiver dpid, ingress_port)`（`topology_manager.py:1600` 附近）。
5. **判定**：沿用 `_link_timeout`——聽過的用 `LINK_BEACON_TIMEOUT_S`，沒聽過的用 `LINK_STARTUP_GRACE_S`，起點是 `started_mono`。
   - 建議把 `last_heard_mono` 當成 beacon 證據的 `at`，讓 `check_link_beacons`／`_notify_link` 用同一條路徑處理。
   - `report_external_link_state` 目前是「現在」的語意，可能要加 `at` 參數；這由 W 決定。
6. **週期不一致**：`period_s != LLDP_BEACON_INTERVAL_S` 時，建議 `reroute=false`，原因 `heartbeat_period_mismatch`。
7. **揭露**：`side_effects` 和各介面的計數放進 `switch_state`；`forwarded_to_hosts>0` 就是裁決 4 的停止條件；心跳活著時 `link_discovery` 標成 `heartbeat`。
8. **生命週期**：
   - `ndt up p4 --app`（外來 fabric）在拓樸起來後呼叫 `sudo -n ndtwin-lab heartbeat start`：0 在跑、3 不適用、1 拒絕。
   - `ndt down` 在 `topo-stop` 之前呼叫 `stop`。
   - `ndt status` 呼叫 `heartbeat status`。
   - NDTwin 自己的 pipeline 不啟動心跳：這條要在 `ndt` 擋，helper 不做政策判斷。
9. **語意差別**：心跳只證明那條 veth，不證明交換機活著；被 P4PowerStrategy 關掉的交換機仍會被 heard。LLDP 兩者都證明。
10. **遙測副作用**：link 遙測是 1/256 取樣，也會取到心跳幀（每方向每 5 s 一幀 60 bytes），要揭露。

### H.8 要轉給 Adam 的事（合併進 trunk 之後）
```
sudo install -o root -g root -m 755 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
sha256sum /usr/local/sbin/ndtwin-lab
```
- 預期新 sha256 是 **`d504af411e54079fb0d2cd184c5232787d4a2360a546b2d5c3ab9459ee88e71a`**（本分支 head 的檔案；合併時若沒被改動，trunk 那份應該一模一樣）。舊的是 `6685d3a9…`。
- sudoers 不用改。

### H.9 揭露與限制
- **設定檔閘門**：heartbeat 在設定檔壞掉時 fail closed，連 stop 也跑不了。要不要放寬是一行政策，由 orchestrator 決定。
- **helper 不擋 NDTwin 自己的 pipeline 啟動心跳**：要擋的話是 plan 裡看 `program` 欄的一行，需要新測試加變異。
- **未量**：bmv2 對 egress_spec 0 的處理、bmv2 pcap 的方向、真 veth 上 BPF／OUTGOING 的實際行為、netem 丟幀——都留給段 S。
- **既有狀態沒變**：root 本來就會執行 `KERNEL_DIR` 裡的 `.py`；這一段沒有擴大它。

## 段 S — 離線準備（寫好、自測過，**從沒在 lab 上跑過**）

### 檔案（commit `32a25b23`）
- `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`：主腳本。
- `hb_watch.py`：用 proxy 的規則判定，常數由呼叫端從 `topology_manager.py` import 傳進來。
- `hb_sniff.py`：在 host 的 netns 裡跑（mnexec），限時；用 ethertype 或「payload 裡 magic 後 6 bytes 起是 session」兩種方式認心跳幀。
- `census_prepare.py`：import `drive_exercise.py` 的函式，照 06 的方式建每個臂。

### 內容
- **PART=detect**：
  - pod-topo `--app basic`，對 s1-eth3↔s3-eth1 兩端下 out-of-band netem（用 `faults.sh` 的 htb 安全掛點，不走 `inject_link_failure`）。
  - 做 CYCLES 次（預設 10），每次量：剪 → 兩向都不再被聽到；復原 → 兩向重新被聽到。
  - 另外檢查：其他 6 個方向不受波及、沒有殘留 netem、qdisc 全樹和快照相同。
- **PART=census**：
  - 13 個練習 × 臂。每個臂：建起來 → `ndt up` → 心跳 → 所有 host 同時 sniff 20 s → 讀 daemon 計數 → `ndt down`。
  - **任何 host 看到心跳幀、或 `forwarded_to_hosts>0`，就立刻停（裁決 4）**，判 FAIL。
  - p4runtime 和 flowcache 的 controller 不啟動。
- **沒做到**：「進了哪張表／哪個計數器」只有 §H.6 的讀碼預測。本機的 `simple_switch_CLI` 會挑到 p4dev venv 的 python3.13，而那裡缺 `thrift`（OBSERVED：`ModuleNotFoundError: No module named 'thrift'`）；要打開 bmv2 的 log 就得改拓樸，超出本段範圍。

### 怎麼跑
條件：lab 有時段、新 helper 已裝、在有 `p4_proxy/venv` 的 checkout 裡（也就是合併後的主 checkout）、以 operator 身份跑，不加 sudo。
```
NDT_OWNER=<you> PART=all bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh
# PART=detect CYCLES=10 | PART=census ARMS=solution ONLY=basic,load_balance | --self-test
```
- **claim 與還原**：腳本自己 claim（`CLAIM_MINUTES` 預設 180；detect 階段會設 `NDT_MEASURING`），快照並還原 `host_count_override` 和 `telemetry_override`。
- **收尾順序**：EXIT trap 先停心跳、拆 netem，再交給 `_common.sh` 的 `finish()`：`ndt down` → 旋鈕還原 → release。
- **開跑前會拒絕（rc 2、不 claim）的情況**：已裝 helper 的 sha 和 checkout 的不一致、已裝的沒有 heartbeat 動詞、已經有心跳在跑、lab 被別人佔用或正在 measuring、以 root 身份跑。
- raw 放在 `spike/runs/<UTC>_S_heartbeat/`；數字請寫進 `doc/audit/2026-09-25_p4-heartbeat/P4-HB-SPIKE.md`。

### 自測（跑過）
`spike_selftest.p4hb-9fbedc39.log`：`SPIKE SELF-TEST PASS`，包含：
- 20 個判定情境
- 4 個 sniffer 分類情境
- 17 個借來的函式都存在
- 用 daemon 自己的 `encode` 產生的幀，sniffer 能認出（原樣和重新包裝過的都認得）

這個自測抓到過一個真 bug：sniffer 的 payload 比對原本假設 magic 後面緊接 session，已修正。

## 跑過 vs 讀過未執行

| 跑過（有 log） | 讀過、未執行 |
|---|---|
| 186 顆 suite；32 個變異＋控制組；兩輪紅燈；anchors；22 支 helper 相關 suite＋banner；spike 自測；daemon 迴圈端到端（unix socket 替身）；真實 ethtool 查 `lo` 和本機 veth | §H.6 的 13 練習預測；bmv2 egress 0；真 veth 上的 AF_PACKET、BPF、netem；daemon 以 root 在 `/run` 的全部行為；sudo 下的 dispatch；段 S 在 lab 上的每一步 |

## commit（`62f76cf5..HEAD`）

| sha | 內容 |
|---|---|
| `8be43e77` | 只有測試（紅燈先行） |
| `9b17f8f9` | 修紅燈輪的儀器問題（仍無實作） |
| `8c930eb4` | helper 實作（只改 `tools/test_workflow/ndtwin-lab`） |
| `d6bafeae` | 變異閘門 |
| `32a25b23` | 段 S 的 spike 四支檔 |
| `9fbedc39` | 修 `no-topo-check` 的點名檢查（只改測試和閘門） |

**head＝`9fbedc392ec02c1b4dc1bf1117ca0cfd64e9ec22`**


---

> 存檔說明（orchestrator）：以下「段 H 第二輪」是 worker HB 第二輪交件回覆的原文，09-25 由 orchestrator 附加，未改寫。

## 段 H 第二輪（判官 MERGE AFTER FIXES＋Adam 09-25 兩項裁決）

worktree／分支同第一輪，base 仍是 `62f76cf5`。第一輪 head `9fbedc39` → **第二輪 head `b22e88ed`**（`b22e88ed1629bc0e28293ee6271d19e6bc0f9543`）。
沒 push、沒 merge、沒碰 lab、沒 sudo、沒建 C++、沒動主 checkout。
判官報告：`scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925/judge-HB-9fbedc39.md`。

### 2.1 commit（`9fbedc39..b22e88ed`）

| sha | 內容 |
|---|---|
| `fb4243e2` | **只加測試（紅燈先行）**：<br>① heartbeat suite：NDTwin pipeline 拒絕、bmv2 uid、兩個 start 競爭、KILL 後備、算術注入<br>② G-7 suite：heartbeat 的設定檔閘<br>③ spike 自測：teardown、tc 預檢、首次命中即停、sniffer 早退、first-hit<br>另把 spike 重排成先 source `faults.sh`／`_common.sh` 再自測，行為不變 |
| `f139c800` | **實作**：<br>① helper：`plan()` 拒絕 `ndtwin_switch.json`；`bmv2_alive` 要求 real／effective uid 都是 0；`lab_conf_gate` 放行 `heartbeat stop|status`，dispatch 改成傳入 `"${2:-}"`；標頭「看過紅」的說法縮到事實範圍<br>② spike：`spike_ndt`＋`FABRIC_UP`、`precheck_tc`、`watch_sniffers`<br>③ `hb_sniff.py`：看到第一個心跳幀或 stop file 就結束<br>④ `hb_watch.py`：加 `first-hit` |
| `b22e88ed` | **變異**：<br>① heartbeat 閘門加 6 個（32→38）<br>② G-7 閘門加 3 個（15→18）<br>③ 閘門標頭註明 `ethertype-collides` 需要 `~/tutorials/exercises` |

### 2.2 逐項（OBSERVED＝跑過有 log；INFERRED＝讀碼推得、未執行）

1. **判官 #1：spike 正常跑完被第二次 `ndt down` 的 rc 3 判 FAIL**
   - 修法：`finish()` 呼叫的 `"$NDT"` 在 `spike_finish` 裡換成 `spike_ndt`。
   - 只有 `down` 回 3、且 `FABRIC_UP==0`（本 run 自己的帳：`nd_up` 時設 1，`nd_down` 回 0 或 3 時清 0）時才當作 0。其他 rc 原樣傳出；以為 fabric 還在卻回 3，照樣 FAIL。release 仍用真的 ndt。
   - OBSERVED：自測用 stub ndt（`down` 回指定 rc，claim／release 回 0），真的走 `spike_finish` → `_common.sh` 的 `finish()`：

     | 情境 | 最後一行 | stub 被呼叫 |
     |---|---|---|
     | FABRIC_UP=0、down 回 3 | `PASS S_heartbeat` | down,release |
     | FABRIC_UP=1、down 回 3 | `FAIL … 'ndt down' exited 3 …` | down,release |
     | FABRIC_UP=1、down 回 0 | `PASS` | down,release |

     紅燈輪（`fb4243e2`）第一格是 `FAIL S_heartbeat -- 'ndt down' exited 3`。
2. **判官 #2：tc 權限預檢**
   - `precheck_tc` 用 `sudo -n -l`（不執行任何東西）問三條：`tc qdisc show dev s1-eth3`、`… add dev s1-eth3 root netem loss 100%`、`… del dev s1-eth3 root`。
   - 若設了 `FAULTS_TC` 覆寫，就改成實跑 `qdisc show dev lo`。
   - 位置在 `take_claim` 之前（PART≠census 時才做）。被拒 ⇒ rc 2，不 claim，並提示改用 `FAULTS_TC='sudo -n mnexec -a 1 tc'`。
   - OBSERVED（自測，stub sudo）：沒有授權 ⇒ 1，並點名那條 add 指令；授權齊全 ⇒ 0；失敗的覆寫 ⇒ 1。「預檢在 claim 之前」是讀原文比行號（550 < 572）。
   - INFERRED：這台 operator 實際有沒有這些授權，沒有查。
3. **Adam 裁決 (a)：helper 拒絕 NDTwin 自家 pipeline**
   - manifest 裡任何一台交換機的 program 是 `ndtwin_switch.json`，整個 fabric 拒絕，rc 1。
   - 訊息寫明原因：該 pipeline 帶 LLDP，未知 ethertype 會送 CPU，心跳幀會變成 packet-in 被當作存活證據。
   - OBSERVED：測試用「四台中一台」的夾具，紅燈輪紅、實作後綠；變異 `ndtwin-pipeline-accepted` 被點名的那顆抓到。
4. **Adam 裁決 (b)：設定檔壞掉時的閘**
   - `lab_conf_gate heartbeat stop|status` 放行，並印「touches only /run/ndtwin-lab」。
   - `start`、沒帶子動詞、未知子動詞仍 fail closed。
   - OBSERVED（G-7 suite 66 顆全綠）：新增 7 顆，其中 stop、status、「dispatch 把子動詞交給閘」3 顆紅燈輪紅；start、無子動詞、未知子動詞 3 顆紅燈輪時本來就綠（舊閘本來就擋）；「stop 仍公告設定檔被拒」1 顆實作後綠。
   - OBSERVED（`mutate_g7` 18／18）：新增 3 個變異都被點名抓到——`heartbeat-gate-lets-start-run`、`heartbeat-gate-locks-out-stop`、`gate-not-given-the-sub-verb`。
   - dispatch 一行只能用原文釘住：從 sourced 檔走不到它。
5. **判官 #6：`bmv2_alive` 加 uid 檢查**
   - `/proc/<pid>/status` 的 real 和 effective uid 必須都是預期 uid（正式環境是 0）。
   - OBSERVED：夾具中 argv 對、uid 不對 ⇒「no fabric」；變異 `bmv2-uid-unchecked` 被抓到。
6. **判官 #7：算術注入與標頭措辭**
   - 垃圾 pidfile 清單加入 `a[$(touch …pwned5)]`。
   - 另加一顆直接問 `hb_is_daemon 'a[$(touch …pwned6)]'` 的檢查：必須回 1 且沒有執行。先在本機實測過 bash 的 `(( pid > 1 ))` 真的會執行 `a[$(cmd)]` 裡的指令。
   - 變異 `is-daemon-arithmetic-first`（先算術後驗證）被這顆抓到。
   - helper 標頭改成：只宣稱「每條規則的正向那顆看過紅」；雙層防護下的「沒送訊號、沒執行」幾顆不宣稱看過紅。
7. **判官 #9：兩條未測分支**
   - 兩個 start 競爭：本次 launch 的 daemon 拿不到鎖回 2，此時 `hb_pid` 已看得到贏家 ⇒ rc 0，訊息點名贏家的 pid。
   - 忽略 TERM 的替身：`stop` 走 KILL 後備，並刪掉 pidfile。
   - OBSERVED：三個變異 `race-branch-dropped`、`kill-fallback-dropped`、`kill-path-leaves-pidfile` 都被點名抓到。這兩條是既有行為，所以測試在紅燈輪本來就綠，看過紅靠的是這三個變異。
8. **判官 #10**：變異閘門標頭寫明 `ethertype-collides` 依賴 `$HOME/tutorials/exercises`。那個目錄不在時，這個變異會存活，閘門 rc 1，會大聲失敗、不是靜默通過。
9. **判官 #11：census 的停止時機**
   - 每個 sniffer 看到第一個心跳幀就結束，看到 stop file 也結束（每 0.5 s 檢查一次）。
   - `watch_sniffers` 每 0.2 s 讀 `hb_watch.py first-hit`；一有命中就寫 stop file、存報告快照、停心跳，不必等 20 s 窗口結束。
   - OBSERVED（自測，兩個替身 sniffer）：一個 0.3 s 後命中、另一個本來會跑 20 s ⇒ 1 s 內全部結束、心跳被停；沒有命中的對照組 ⇒ 不命中、不停。`hb_sniff` 的自測用 socketpair 驗兩種早退，`first_hit` 兩個情境也驗了。
   - INFERRED：真的 root sniffer（經 mnexec）看不看得到 stop file，取決於 mount namespace；讀碼判斷 Mininet host 與 root 共用 mount ns，沒有量。
10. **SUMMARY 數字更正**
    - **既有 suite 數**：判官說得對，應為「既有 **21** 支＋新 1 支＋banner」。
    - **行數**：OBSERVED `git diff --numstat 62f76cf5 8c930eb4 -- tools/test_workflow/ndtwin-lab` = `1053 1`，所以第一輪寫的「+1053／−1」是對的。判官的 +1059 是把第一個 hunk 標頭 `+566,1053` 的新側行數（含 6 行 context）當成新增行，再加上另外兩個 hunk 的 +6。
    - **到第二輪 head 為止**：`git diff --numstat 62f76cf5 b22e88ed -- tools/test_workflow/ndtwin-lab` = **`1092 2`**。

### 2.3 閘門
全部在 `b22e88ed` 上跑，經 `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`、`setsid -f` 背景執行。log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`，每支第一行都是完整 sha。

| log | 最後一行（摘錄） |
|---|---|
| `round2_tests.red.p4hb-fb4243e2.log`（紅燈輪） | heartbeat `Ran 196 checks, 2 failed`；G-7 `Ran 66 checks, 3 failed`；spike 自測 12 紅（`SPIKE SELF-TEST FAIL`） |
| `test_ndtwin_lab_heartbeat.p4hb-b22e88ed.log` | `Ran 196 checks, 0 failed`／`# rc=0` |
| `mutate_ndtwin_lab_heartbeat.p4hb-b22e88ed.log` | `mutants: 38 named + 1 control; caught 38, survived 0, invalid 0`／`VERDICT: every mutation was caught by the check named for it; the control survived`；restore 後逐位元相同、suite 綠／`# rc=0` |
| `mutate_g7_ndtwin_lab_config.p4hb-b22e88ed.log` | 18 個 `caught by`、control SURVIVED、restore 逐位元相同／`VERDICT: every mutation was caught…`／`# rc=0` |
| `check_gate_anchors.p4hb-b22e88ed.log` | HEAD `117/117 cells ok`（`mutate_g7` ok(18)、`mutate_ndtwin_lab_heartbeat` ok(39)）；base `62f76cf5` 對照 `116/116`；`# rc=0` |
| `spike_selftest.p4hb-b22e88ed.log` | `SPIKE SELF-TEST PASS`／`# rc=0` |
| `helper_suites.p4hb-b22e88ed.log` | `suites: 2 red`／`# rc=1`（見下） |
| `apps_residue_rerun2.p4hb-b22e88ed.log` | `red runs: 0 of 5`／`# rc=0` |

`helper_suites` 的兩顆紅：
- **`test_ndt_helper_apps_window.sh`（預期中的紅）**：「installed helper is the copy this suite read」。已裝的 `6685d3a9` 不等於 head 的 `6a558fe4`；Adam 重裝後就會綠。
- **`test_apps_residue.sh`（新出現、判定為時間相依的偶發紅）**：`Ran 131 checks, 2 failed`，兩顆都是「sec=0 with nsec set … is DATED」這組，這是該測試自己註明的「牆鐘一兩秒窗口」檢查。
  - OBSERVED：它讀的 `tests/shell/test_apps_residue.sh`、`tools/test_workflow/{ndt,stack.sh,ports.sh}` 在 base 與 head 之間逐字相同。同一 head 再跑 5 次 5 次全綠。第一輪（`9fbedc39`）兩次跑也都綠。
  - INFERRED：當時機器上其他 session 正在跑閘門造成負載，時間敏感的檢查因此偶發紅；和本分支無關。
  - 另有一份 `apps_residue_rerun.p4hb-b22e88ed.log` 最後一行是 rc=1：那是腳本結尾 `grep FAILED` 找不到東西的回傳碼，5 次都 rc 0。重跑一次、以正確退出碼記錄的是 `rerun2`。

### 2.4 仍未執行（讀過／推得，未跑）
- sudo 下的 dispatch，包括新的 `lab_conf_gate "${1:-}" "${2:-}"`。
- 真 veth 上的 BPF、OUTGOING、netem 行為。
- 以 root 身份在 `/run` 執行的 daemon。
- 真 sniffer 的 stop file 能見度。
- operator 的 tc 授權實況。
- 段 S 在 lab 上的每一步。

### 2.5 要轉給 Adam 的事（更新）
段 H 併進 trunk 之後：
```
sudo install -o root -g root -m 755 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
sha256sum /usr/local/sbin/ndtwin-lab
```
新 sha256 **`6a558fe452955de358fd1a3b4e730fe2be55368a6c90b93675c5442c036fd4fb`**（取代第一輪的 `d504af41…`）。

建議裝好後第一件事（判官 #8；INFERRED 期望值）：
- 沒有 fabric 時 `sudo ndtwin-lab heartbeat status` ⇒ rc 3。
- 沒有 fabric 時 `sudo ndtwin-lab heartbeat start` ⇒ rc 1，訊息點名 topo session。
- 在 NDTwin 自家 fabric 上 `start` ⇒ rc 1，訊息點名 `ndtwin_switch.json`。

**head＝`b22e88ed1629bc0e28293ee6271d19e6bc0f9543`**


---

<!-- round 3: worker reply saved verbatim by the orchestrator (the worker cannot write this file) -->

DELIVERED 01ff83681d6878fc73c5741f7782ac5db92cd92f

Round 3 is done. R2-1 and R2-2 are fixed, and the spike self-test is green at the new head. The self-test's one real sudo call (`/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true`) returned rc 0, so the mnexec route works without a password on this machine. That call was made exactly twice in total, once in the red run and once in the green run, and no other sudo was run.

Round 3 changed only `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`. The helper is unchanged, so its sha256 is still `6a558fe4…`. The heartbeat suite and `check_gate_anchors` don't cover the spike, so I did not re-run them.

- **New head**: `01ff83681d6878fc73c5741f7782ac5db92cd92f`

---

## 段 H 第三輪（判官 scoped 第二輪：R2-1、R2-2、R2-4）

分支同前，從 `b22e88ed` 接著做。本輪兩個 commit：
- `0849c0e2`：只加測試，紅燈先行
- `01ff8368`：修正

兩個 commit 都只改 `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`（`b22e88ed..01ff8368`：+106／−42）。helper、測試、變異閘門都沒動，helper sha256 仍是 `6a558fe4…`，所以 heartbeat suite 和 `check_gate_anchors` 依指示沒有重跑。沒碰 lab、沒 `ndt up`、沒 push／merge。

### OBSERVED（跑過，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`，第一行是完整 sha）

1. **R2-1：tc 路線改成預設走 mnexec，並用真的執行來證明**
   - 在 source `faults.sh` 之前加 `: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"`。`faults.sh` 的 `${FAULTS_TC:-sudo -n tc}` 會保留這個值；環境變數明確設定 `FAULTS_TC` 時仍以環境為準，普通的 `sudo -n tc` 只剩覆寫這一種用法。
   - `precheck_tc` 不再用 `sudo -n -l`：依 `sudo_surface.sh:37-49`，這台機器上它對任何指令都回 0。改成對目前生效的路線**實際執行**一次 `tc qdisc show dev lo`：
     - 這個指令唯讀，也不會因為找不到介面而失敗，所以非 0 就代表路線被拒。
     - 仍然在 claim 之前執行；被拒時 rc 2。
     - 走非預設路線時，報告會註明「show 跑得動只證明 show 可用」。
   - 紅燈輪 `spike_selftest.red.p4hb-0849c0e2.log`：`SPIKE SELF-TEST FAIL`，共 3 個 🔴：
     - 預設路線還是 `sudo -n tc`
     - `sudo -n tc` 覆寫仍被用 `-n -l` 問三次
     - R2-2（見下一項）
   - 綠燈輪 `spike_selftest.p4hb-01ff8368.log`：0 個 🔴，`SPIKE SELF-TEST PASS`，`# rc=0`。新增的檢查：
     - 預設路線是 mnexec
     - 預檢透過路線實跑（sudo 用 stub，只被呼叫一次，參數正是 `-n mnexec -a 1 tc qdisc show dev lo`）
     - 被拒的路線會被拒
     - `sudo -n tc` 覆寫也是實跑、不用 `-l`
     - 跑不動 tc 的 `FAULTS_TC` 會被拒
     - 預檢在 claim 之前（讀原文比行號）
   - **唯一的真 sudo 呼叫**：`/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true`，用絕對路徑，函式或 PATH shim 都替換不了。紅、綠兩輪各跑一次，都 **rc 0**，log 裡印成 evidence 行。拿不到授權時自測會印紅行，不會判過。
2. **R2-2：`watch_sniffers` 在所有 sniffer 都結束後再讀一次 first-hit**
   - 抽出 `watch_hit`。所有 sniffer 都結束時，先再讀一次 first-hit 才把這個窗口判為乾淨；逾時分支也補讀一次。
   - 自測的做法是讓替身 `child_running` 在回報「已結束」的同時寫入命中檔，確定性地重現「在 first-hit 讀取和存活檢查之間寫入」這個空窗。紅燈輪結果是 `'none 1'`（漏抓）；綠燈輪 `hZ 0`，stop file 已寫、心跳已停。

### SUMMARY 數字更正（R2-4，照判官核對）
- 第二輪 §2.3 的 `mutate_g7_ndtwin_lab_config.p4hb-b22e88ed.log`：應為 **17 個 caught ＋ 1 個 control SURVIVED**。`ok(18)` 是 anchor 數，含 control。
- 第二輪 §2.3 的紅燈輪 spike 自測：應為 **10 個 🔴（2＋2＋6）加 2 行 `SELF-TEST FAIL`**，不是「12 紅」。

### INFERRED（沒有執行）
- **mnexec 授權不限制參數**：推論依據是 `ping_loss` 以任意參數使用 mnexec，sudoers 本身沒讀。所以「`tc qdisc show` 跑得動，`tc qdisc add … netem` 也跑得動」仍是推論；要到段 S 第一刀才會實證。
- **`-a 1` 進入的就是 root netns**：依 Mininet 的 mnexec 語意推得（本機沒有 `mnexec.c`）。
- **stop file 在 mnexec 裡的 sniffer 看不看得到**（R2-3）：依然沒量；即使看不到，sniffer 的存活時間也有上限。

**head＝`01ff83681d6878fc73c5741f7782ac5db92cd92f`**


---

<!-- judge round 3 (opus-judge acc12e4d) on 01ff8368, saved verbatim by the orchestrator; orchestrator repro of R3-1: bash -euo pipefail bare call rc=1, inside `&&` list survives -->

# 第三輪裁決（head `b22e88ed` → `01ff8368`，只動 spike）

一句話：**R2-1 CLOSED、R2-4 CLOSED、R2-2 NOT CLOSED**——補讀的邏輯對了，但它以一個裸的 `watch_hit` 呼叫引進了 `set -e` 回歸：census 每一個「沒有主機看到幀」的乾淨臂都會讓整支 spike 在 `watch_sniffers` 裡中止。自測看不到，因為整個 `self_test` 跑在 errexit 被忽略的語境裡。helper 未動（diff 只含 `S_heartbeat_spike.sh`），合併裁決不變；段 S **排程前**要再修一行。

## 三項

**R2-1（tc 路線）— CLOSED。**
證據：`S_heartbeat_spike.sh:85` 在 `:87` source `faults.sh` 之前 `: "${FAULTS_TC:=sudo -n mnexec -a 1 tc}"`，`faults.sh:88` `${FAULTS_TC:-sudo -n tc}` 保留既有值；`precheck_tc`（`:182-198`）改成**實跑** `run_tc qdisc show dev lo` 看 rc，`-l` 已消失（自測 `:512-516` 斷言錄到的 sudo 呼叫沒有 `-l`；紅燈 `spike_selftest.red.p4hb-0849c0e2.log:46,49` 顯示舊行為）；mnexec 授權由一次真呼叫證明，worker log `:51` 與 orchestrator rerun `:46` 都是 `rc 0`。
殘餘：「mnexec 授權不限參數」仍是 INFERRED（見 (d)）；不影響 CLOSED，因為執行期預檢證明的就是 `mnexec -a 1 tc qdisc show dev lo` 這個精確形狀，只剩 `add … netem` 的 tc 參數差異未實證，worker 已明寫。

**R2-2（最後一個 sniffer 的命中）— NOT CLOSED（回歸 R3-1）。**
補讀本身正確：`:273` 全部退出後、`:274` 逾時後各再 `watch_hit` 一次；命中路徑紅→綠（`red…log:56` `'none 1'` → `…01ff8368.log:56`）。但 `watch_hit` 沒命中時 `return 1`（`:252`），而 `:273` `if (( ! running )); then watch_hit "$dir" "$stopf"; return 0; fi` 把它放在 then-body 當裸命令——不在 `&&/||`、不在 `if` 條件、沒有 `!`——`set -e` 生效時 shell 直接退出。生效鏈：`:62`／`:90` `set -euo pipefail`；`:638-639` `census` 在 `if … then` 的 body 裡；`:403` `watch_sniffers` 裸呼叫；`:273`。後果：PART=census／all 的第一個乾淨臂（§H.6 預測每一臂都乾淨）⇒ 腳本 rc 1 ⇒ trap `spike_finish` 收尾 ⇒ 最後一行 `FAIL S_heartbeat -- the script exited 1 before its own verdict`，census 表永遠產不出來；detect 不受影響（不用 `watch_sniffers`）。sniffer 不會殘留（走到 `:273` 表示全退了），心跳由 trap 停 ⇒ 是「跑不完」不是「傷 lab」。
自測為何看不到：`:585` `self_test && exit 0 || exit 1` 把 `self_test` 放在 `&&` 串的第一個位置 ⇒ 依 bash 語意其內部所有函式與子 shell 都忽略 `-e`，連內部再 `set -e` 也無效；`:562-567` 的乾淨對照組因此通過，真跑會死。同一類缺陷 `_common.sh:213-224` 記過一次（`finish()` 在 `-e` 下半途被殺）。
修：`:273`／`:274` 改 `watch_hit "$dir" "$stopf" || true`；自測的三個 watch 情境改在**新的** bash 行程裡跑才看得到紅，例如 `bash -euo pipefail -c "$(declare -f watch_sniffers watch_hit child_running sp_hb_stop); WATCH=…; HB_REPORT=…; watch_sniffers …"`（`declare -f` 把函式原文帶過去；不能靠子 shell 裡 `set -e`）。

**R2-4（SUMMARY 數字）— CLOSED。**
證據：SUMMARY `:416-418`：`mutate_g7` 改為「17 caught＋1 control SURVIVED，`ok(18)` 是含 control 的錨數」；紅燈 spike 自測改為「10 個 🔴（2＋2＋6）＋2 行 `SELF-TEST FAIL`」——與我第二輪讀到的兩份 log 相符。

## 四個問題

**(a) 預設路線是否真的穿過 faults.sh？是。** verified：`:85` 先設、`:87` 才 source；`faults.sh:88` 用 `:-` 不覆蓋非空值。spike 用到的每一個 tc 出口：`run_tc`（`faults.sh:119`）← spike `cut_link:286`、`precheck_tc:186`、`faults.sh` `revert_link_loss:351,354`（spike 經 `restore_link:290` 與 `spike_finish:161` 呼叫）；`show_qdisc`（`faults.sh:164`）← `netem_attach_point:258`（經 `cut_link:283`）、`netem_delete_point:364`（經 `revert_link_loss`）、spike `no_netem_on_cut:293`。`inject_link_loss:308` 與 `FAULTS_KILL` spike 不用。唯一不走 `FAULTS_TC` 的是 `qdisc_snapshot.sh`（`:24` `${QDISC_SNAPSHOT_TC:-tc} qdisc show`）——唯讀、不需 root，本來就該獨立。`${FAULTS_TC} "$@"` 未加引號展開成 6 個字，字串裡無 glob。環境覆寫：`:=` 尊重、`:84` 記下來源、自測遇到環境值會紅（`:494-495`），確保驗的是預設。附帶：`faults.sh:53-57` 說 08-17 用 `sudo -n -l` 確認 tc 四條授權「已解決」——那正是 `sudo_surface.sh:37-49`（09-03）證明零鑑別力的探針；mnexec 預設繞開了這個不可靠的前提，是對的方向。

**(b) 那一次真 sudo 是否無害且有界？無害是；有界在實務上是、在構造上不是。** `:525` `/usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true`：三個絕對路徑，含斜線的命令字 bash 不查函式也不查 PATH ⇒ `sudo()` stub 攔不到 ✓；`-a 1` 進 pid 1 的 net（新版 mnexec 連 mnt）ns＝root 的，等於不動；`true` 什麼都不做；`-n` 不會停下來問密碼。沒有 `timeout` 包住——只有異常 sudo 設定（遠端 NSS／PAM）才會卡，建議加 `timeout 15` 讓它在構造上有界。拒絕時印紅不判過 ✓（`:527-529`）。**紀律面**：工單 §3 寫 worker 的 sudo 只能經已裝的 `ndtwin-lab`；這是另一個 binary。效果無害、且 worker 揭露「共呼叫兩次、無其他 sudo」（SUMMARY `:376`）。但從此每一次 `--self-test`（含閘門、含別台機器）都會發一次 sudo；要不要接受是 orchestrator／Adam 的事，我建議至少放在 opt-in（例如 `SELFTEST_PROBE_SUDO=1`）或在 SUMMARY 首段明寫「自測含一次真 sudo」，不要只在文末。

**(c) R2-2 的替身是否重現了競態窗口而非別條路？是。** 替身 `child_running`（`:573`）在回答「已退出」的同時寫入命中檔 ⇒ 第一次 `watch_hit`（`:268`）讀不到、存活檢查說全退了、只有 `:273` 的再讀能看到——這正是「寫入落在讀取之後、存活判定之前」的順序，而且是最緊的版本。真實世界的順序保證成立：JSON 由 operator shell 的重導在 sniffer 退出前寫完、子 shell 才消失，所以「行程已不在 ⇒ 檔案已完整」，半寫檔的情形被排除。舊碼對同一替身回 `'none 1'`（red log `:56`）、新碼回 `hZ 0`——替身有鑑別力。只是它驗的是命中路徑；乾淨路徑（R3-1）正好是自測語境看不到的那條。

**(d) 「mnexec 授權不限參數」是否在每個依賴處都標 INFERRED？不是，兩處漏標。** 有標：`precheck_tc` 註解 `:179-180`（「INFERRED from ping_loss's use; not read from sudoers」）、SUMMARY `:421`（並誠實寫「要到段 S 第一刀才會實證」）。**沒標**：檔頭 `:80-81`「under the mnexec grant … ping_loss already uses with arbitrary arguments」——ping_loss 的用法是讀 `_common.sh:572-576` 可證的事實，但「因此授權允許任意參數」是推論，這裡沒說；自測註解 `:492-493`「which the mnexec grant covers whatever its arguments」——直接當事實寫。`die` 訊息 `:614-616` 不依賴這個推論 ✓。ok 行 `:528`「the mnexec grant the default route needs is there」略超：探針證明的是 `-a 1 /usr/bin/true`，路線需要的是 `-a 1 tc …`；不過執行期 `:186` 隨後就實跑 `tc qdisc show` 形狀，只剩 `add … netem` 未證。推論本身合理：repo 裡 `mnexec -a <pid> ping …`／`true`／`timeout … python3 …` 都以任意參數跑過（06/07 live 26/26），一條只放 `show` 不放 `add` 的 sudoers 樣式不合常理。修：`:80-81`、`:492-493` 各加「(INFERRED)」，`:528` 改成「the mnexec grant is usable without a password (probe: `-a 1 true`)」。

## 新發現

**R3-1 [should-fix，段 S 排程前必修；不擋合併]** 上文 R2-2：`:273-274` 裸 `watch_hit` 在 `set -e` 下中止 census 的每個乾淨臂；修法與可看紅的自測構造如上。

**R3-2 [note]** 自測的一次真 sudo（(b)）：無害、已揭露、但偏離工單 §3 字面；建議 opt-in 或 `timeout`，並在 SUMMARY 首段揭露。

**R3-3 [note] 標記缺口**（(d)）：`:80-81`、`:492-493`、`:528` 三處措辭。

**R3-4 [note，既有非本輪]** `census:389` `session="$(hb_watch session …)"` 在 `-e` 下若報告檔尚未出現會中止；`heartbeat start` 回 0 時 daemon 已寫 pidfile、報告緊接其後，窗口極小；加 `|| die` 或重試更穩。

## 核對

- 三份 log 第 1 行都是完整 sha（`0849c0e2…`、`01ff8368…`、rerun 標頭 `01ff8368…`）；紅燈輪 3 個 🔴 與 commit 訊息一致；綠燈輪與 rerun 0 紅、`SPIKE SELF-TEST PASS`、evidence 行 rc 0。
- diff 只動 `S_heartbeat_spike.sh` ⇒ helper sha 未變的說法與檔案相符（sha 值本身沿用第二輪，未另有 log）。
- verified：以上所有行號皆對照 head 全文（`wt-p4-heartbeat-0925/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`）、`faults.sh:40-75,88,119,164,256-374`、`qdisc_snapshot.sh:18-24`、主 checkout `sudo_surface.sh:37-49`、`_common.sh:71,213-224,572-576`。inferred：`mnexec -a 1` 的 namespace 語意（本機無 `mnexec.c`）、sudo `-n` 不會阻塞、bash 的 errexit 例外規則（依手冊，未在此機執行驗證）。


---

<!-- round 4: worker reply saved verbatim by the orchestrator -->

DELIVERED e1245b400efa4529ac5749c173020e862ee84cb2

Round 4 is done. R3-1 through R3-4 are fixed, and the spike self-test is green at the new head. The audit turned up one more bare call of the same kind: when `detect` fails its first check it returns 1 as the last command of `[[ … ]] && detect`, which under `set -e` ends the run and skips the census even with `CENSUS_EVEN_IF_RED=1`. That is fixed too.

Two things went wrong on the way; both are fixed:
- **I committed `6f626473` with one check still red.** The `detect` check had been red at `5c882c9f`, but because its driver died of `set -u` on a missing `CUT_DIRS`, not because of `detect`. `e1245b40` fixes the driver and adds a separate run that proves the red is genuine on the old code.
- **I accidentally ran the spike's real run path once** (a debug command sourced the script without `--self-test`). The debug output shows it stopped at the "no venv" refusal, which is before `require_root`. So no sudo was called, no claim was taken, and nothing on the lab was touched. The empty `runs/` directory it left behind is deleted.

- **New head**: `e1245b400efa4529ac5749c173020e862ee84cb2`
- **Helper sha is unchanged**: `tools/test_workflow/ndtwin-lab` at head is still `6a558fe452955de358fd1a3b4e730fe2be55368a6c90b93675c5442c036fd4fb`. From `b22e88ed` to head, only `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh` changed.

---

## 段 H 第四輪（只改 spike：R3-1～R3-4）

**首段揭露（R3-2，Adam 的裁決）**：從這一輪起，spike 自測**預設不呼叫任何 sudo**。真的 sudo 探針要設 `SELFTEST_PROBE_SUDO=1` 才會跑，指令是 `/usr/bin/timeout 15 /usr/bin/sudo -n /usr/bin/mnexec -a 1 /usr/bin/true`，全部用絕對路徑。本輪依指示只以 opt-in 跑了**一次**，rc 0。

分支沿用前幾輪，從 `01ff8368` 接著做。本輪 commit：
- `4861a458`：只加測試
- `5c882c9f`：只加測試
- `6f626473`：修正
- `e1245b40`：修一顆測試驅動

四個 commit 都只改 `S_heartbeat_spike.sh`（`01ff8368..e1245b40`：+144／−41）。沒碰 lab、沒 `ndt up`、沒 push／merge。

### OBSERVED（跑過；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`，第一行是完整 sha）

1. **R3-1：`watch_sniffers` 在 `set -e` 下遇到乾淨窗口會中止整個 spike**
   - **修法**：兩次補讀都改成 `watch_hit … || true`。
   - **自測怎麼看見它**：自測整段跑在 `self_test && exit 0 || exit 1` 裡，bash 在這種語境下忽略 errexit，所以舊自測看不到。現在三個 watch 情境（首次命中、乾淨窗口、最後一個 sniffer 的競態）改成在**新的** `bash -euo pipefail` 行程裡跑，函式原文用 `declare -f` 帶過去。
   - **紅燈**：`spike_selftest.red.p4hb-4861a458.log` 的乾淨窗口是 `rc 1, … the process died`。
   - **綠燈**：`spike_selftest.p4hb-e1245b40.log` 是 `SPIKE SELF-TEST PASS`，`# rc=0`。
2. **稽核：spike 裡所有「正常路徑可能回非 0、卻被裸呼叫」的地方**
   - **有問題、已修（2 處）**：
     - `watch_sniffers` 裡的兩個補讀（即 R3-1）。
     - `detect` 的 `[[ "$v" == OK* ]] || return`：它回 1 時，正好是主流程 `[[ … ]] && detect` 的最後一個指令，在 `set -e` 下會結束整支腳本，連 `CENSUS_EVEN_IF_RED=1` 也被跳過。已改成 `return 0`；失敗本來就由 `fail` 記錄。
   - **檢查過、沒問題**：
     - 永遠回 0 的函式：`sp_hb_stop`；`watch_sniffers`（修完後）；`census`（每條路徑都以 `continue`、`case` 或回 0 的 `fail` 收尾）。
     - 回 1 時會 `die`（本意就是要停）：`require_root`、`require_free_lab`、`take_claim`。
     - 在 `&&`／`||`、`if` 條件裡呼叫，回非 0 不會中止：`nd_up`、`nd_down`、`sp_hb_start`、`child_running`、`cut_link`、`restore_link`、`no_netem_on_cut`、`netem_attach_point`、`run_tc`、`revert_link_loss`、`precheck_tc`、`consts`、`host_pid`、`show_qdisc|grep`。
     - 用 `$(…)` 賦值、且那支程式回 0：`prepare`、`now`、`hb_watch` 的 `wait-heard`／`all-heard`／`others-up`／`wait-down`／`summary`／`census-verdict`／`first-hit`；`qdisc_snapshot save` 也回 0。
     - `hb_watch session`（報告還沒寫出時回 1）：即 R3-4，已修。
     - `spike_finish` 本身是 `set +e`。
   - **detect 那顆測試的紅燈**：同樣用新行程加 stub 驅動 `detect`。它第一版在 `5c882c9f` 的紅是**驅動自己**的 `set -u` 死在 `CUT_DIRS`，所以那次紅燈無效；我是在 `6f626473` 修完後發現還紅才察覺的。`e1245b40` 補上變數，並要求驅動確實跑到那顆檢查（記錄到「0/8 directions heard」）。
     - 對舊碼真的會紅的證據是 `spike_selftest.oldcode.p4hb-e1245b40.log`：拿本 head 的自測去跑一份把 `|| true` 和 `return 0` 都改回舊樣的副本，結果 `red lines 2 (clean window: 1, detect: 1)`，並印出 `OLD CODE IS RED IN EXACTLY THE TWO CHECKS`，`# rc=0`。
3. **R3-4：census 讀 session 改成有上限的等待**
   - 新的 `wait_session` 最多讀 20 次、每次間隔 0.25 s。讀不到就記一列 FAIL、停心跳、`ndt down`、換下一臂，不會中止整支腳本。
   - 同樣在新 `set -e` 行程裡測：
     - 已寫出的報告 ⇒ 讀到 session。紅燈在 `4861a458`／`5c882c9f`（函式還不存在時得到 `NONE`），綠燈在 `e1245b40`。
     - 沒有報告 ⇒ 回報「沒有 session」，rc 0。這顆在紅燈輪也是綠的：函式不存在時的 fallback 正好也給 `NONE`，所以它不算看過紅。
4. **R3-2：探針改成 opt-in**
   - 預設跑（`spike_selftest.p4hb-e1245b40.log`）：印一行中性的「NOT run (opt-in)」，不算 ok 也不算紅。
   - 設 `SELFTEST_PROBE_SUDO=1` 跑一次（`spike_selftest.probe.p4hb-e1245b40.log`）：evidence 行 `rc 0`，ok 行寫「the mnexec grant is usable without a password (probe: mnexec -a 1 true, rc 0)」，`SPIKE SELF-TEST PASS`。
5. **R3-3 措辭**：檔頭和自測註解都把「mnexec 授權不限參數」標成 (INFERRED)。檔頭另外寫明：`ping_loss` 用任意參數跑 mnexec 是事實，但「授權因此不限參數」是推論。
6. **意外揭露**：我在 debug 時把 spike 當 `source` 載入，沒帶 `--self-test`，結果真的進了 run 路徑一次。
   - 它死在 worktree 沒有 `p4_proxy/venv` 的拒絕上，時間點在 `require_root` 之前，所以沒有呼叫 sudo、沒有 claim（`lab.claim` 不存在），`finish` 印出 `REFUSED`。
   - 它留下一個空的 `runs/` 目錄，我已刪除。

### INFERRED（沒有執行）
- mnexec 授權不限參數，所以 `tc qdisc add … netem` 也會被放行：要到段 S 第一刀才會實證。
- 真 sniffer 在 mnexec 裡看不看得到 stop file（R2-3）：還是沒量，但 sniffer 的存活時間有上限。

**head＝`e1245b400efa4529ac5749c173020e862ee84cb2`**


---

<!-- judge round 4 (opus-judge acc12e4d) on e1245b40, saved verbatim by the orchestrator: MERGE; R4-1..R4-5 are notes for before segment S -->

# 第四輪裁決（head `01ff8368` → `e1245b40`，只動 spike）

一句話：**R3-1～R3-4 全部 CLOSED**，這次的關法是對的——三個 watch 情境、detect、session 讀取都改在**新的** `bash -euo pipefail` 行程裡用 `declare -f` 帶原文跑，紅燈有看到（`4861a458`／`5c882c9f`／oldcode 副本），綠燈兩份（worker、你的 rerun）。worker 的裸呼叫稽核與我逐行重讀的結果一致。**合併裁決：MERGE**（helper＋tests 自 `b22e88ed` 未動，sha `6a558fe4`；spike 剩下的是排段 S 前的 note，不擋）。

## R3-1～R3-4

| # | 裁決 | 一行證據 |
|---|---|---|
| R3-1 裸 `watch_hit` 在 `set -e` 下中止乾淨臂 | **CLOSED** | head `:291-292` 兩次補讀都是 `watch_hit … \|\| true`；乾淨窗口情境改在新行程跑（`:611-620`），紅燈 `spike_selftest.red.p4hb-4861a458.log:54`「rc 1 … the process died」，綠燈 `…e1245b40.log:54`，oldcode 副本再紅 `…oldcode…log:21` |
| R3-2 自測的真 sudo | **CLOSED** | `:552-561` opt-in `SELFTEST_PROBE_SUDO=1`、`/usr/bin/timeout 15`、絕對路徑、預設印中性行；預設 log `:51`「NOT run (opt-in)」、probe log `:51-52` rc 0、你的 rerun `:46` 同；SUMMARY 第四輪首段揭露（`:496`） |
| R3-3 INFERRED 標記 | **CLOSED** | 檔頭 `:81-83` 把事實（`ping_loss` 以任意參數跑 mnexec，`_common.sh:572-576`）與推論（授權因此不限參數，(INFERRED)）分開；自測註解 `:519`「(INFERRED)」；ok 行 `:557` 只說探針證明了什麼（`mnexec -a 1 true`） |
| R3-4 session 讀取可能在 `-e` 下中止 | **CLOSED** | `wait_session` `:254-262`（20×0.25 s，讀不到回 1 不印）；census `:409-415` `if ! session=$(…)` ⇒ FAIL 列、停心跳、`nd_down`、`continue`；驅動 `:664-681` 在 `set -e` 行程裡驗兩種結果；正向那顆紅燈 `red…4861a458.log:56`「got 'NONE'」（負向那顆 worker 明說沒紅過） |

## 四個問題

**(a) oldcode 證據是否成立？成立。** 工具是 `scratchpad/hb/oldcode.sh`（30 行，我讀了）：把 head 的 spike 複製到**同一個目錄**（`$D/.S_heartbeat_spike.oldcode-$$.sh`，所以 `SPIKE_DIR`／`LIVE_P1` 解析相同），用 Python 把三行改回舊樣、`assert count == n`（1＋2 處），印出 diff（log `:7-17`），再跑**副本自己的** `--self-test`——副本的 `declare -f` 傾印的是副本的函式（裸 `watch_hit`、裸 `return`），也就是新驅動跑舊碼；判定要求 rc≠0、🔴 恰好 2 個、且正是那兩行；EXIT trap 刪副本（11:46:08 的綠燈 log `# status:` 為空，一致）；經 guarded_build、第一行全 sha。detect 那條紅線帶著「driver said: … 0/8 directions heard」——證明驅動已越過 `set -u` 走到 judge 那行才死，紅是 detect 自己的；`5c882c9f` 那次「nothing written」沒有驅動文字，確實無效，worker 揭露正確。可重現：diff 在 log 裡，任何人套回三行再跑 `--self-test` 即得。唯一缺口：工具本身只在 session scratchpad（R4-4）。

**(b) 驅動有沒有把真路徑用到的東西都帶進去？有，對所測性質沒有會讓它「誤過」的差異。**
- watch 驅動（`:575-591`）：`declare -f watch_sniffers watch_hit child_running`＋真的 `WATCH`（hb_watch.py）＋不存在的 `HB_REPORT`（`cp … || true`）＋stub `sp_hb_stop`（`echo stopped > "$1"; HB_STARTED=0`，rc 契約與真的 `sudo … || true; HB_STARTED=0` 相同：永遠 0）。兩個函式引用的每個名字（`child_running`、`watch_hit`、`sp_hb_stop`、`WATCH`、`HB_REPORT`、`date`、`sleep`、`cp`）都在；`WATCH_HIT=""`、`HB_STARTED=1` 與真跑相同。呼叫點形狀：真跑 `:429` 是 `census`（在 `if` body 裡）內的裸呼叫，驅動 `:588` 是 `set -e` 腳本裡的裸呼叫——errexit 語境等價。
- detect 驅動（`:633-660`）：`declare -f detect judge note fail bad say` 傾印的是自測 shell 裡**當下的**定義＝spike 自己的 `judge`（`:94-98`）與 `_common.sh` 的 `note`／`fail`／`bad`／`say`（`say` 是 _common 那份，faults.sh 的已被蓋掉——與真跑同一 source 順序）。`VERDICT_RC=0; VERDICT_WHY=""`＝`_common.sh:41-42` 的初值。stub 只換掉碰 lab 的步驟（`prepare`／`nd_up`／`sp_hb_start`／`sp_hb_stop`／`nd_down`／`now`）與 hb_watch 程式（假的 `all-heard` 回「BAD 0/8」）；`RUN`、`HB_REPORT`、`CUT_DIRS`、`BEACON_S`、`TIMEOUT_S`、`CYCLES` 都給了。呼叫點 `[[ "all" == detect || "all" == all ]] && detect` 重現 `:740`（detect 是 `&&` 串最後一個指令 ⇒ 內部 errexit 生效）。到 `:338` 為止 detect 觸碰的東西全覆蓋；`QDISC_TOOL`／`cut_link`／`restore_link`／`no_netem_on_cut` 在 `:338` 之後、此情境到不了（刻意）。檢查同時要求 `wrc==0`、`survived VERDICT_RC=1`、驅動輸出含 judge 那行 ⇒ 真的 `judge → fail` 路徑跑過且 detect 之後回 0；舊碼同驅動會死（oldcode log）⇒ 有鑑別力。找不到任何 stub／預設值差異能讓驅動過而真路徑失敗。

**(c) 意外的真路徑執行與腳本順序是否一致？一致，而且 `no venv` 之前碰不到任何有副作用的東西。** 不帶 `--self-test` 地 `source` ⇒ 跳過 `:687-689`，走 `:692-699`：PART／CYCLES 檢查、`mkdir -p "$RUN"`（唯一副作用：一個空的 `spike/runs/<UTC>_S_heartbeat` 葉目錄）、`trap`、banner、`[[ -x "$NDT" ]]`（worktree 有 ndt ⇒ 過）、`[[ -x "$PY" ]] || die`（`:699`，worktree 無 `p4_proxy/venv` ⇒ rc 2）。之前的 source 只定義函式（兩支檔案自述如此）。碰不到 `require_root`（`:701`）、第一個 sudo（`:713`）、`precheck_tc`（`:717`）、`require_free_lab`（`:732`，唯一的 `ndt status`）、旋鈕（`:733-734`）、`take_claim`（`:739`）。trap 進 `finish`：`CLAIMED=0` ⇒ 不 `ndt down`、不 release，`rmdir "$RUN"` 拿掉空葉子、印 `REFUSED`、exit 2——與 worker 說的「finish 印 REFUSED」相符；`rmdir` 不會拿掉空的父目錄 `spike/runs/`，與「留下一個空 runs/ 目錄、已刪」相符。與你查到的（無他人 claim、heartbeat status rc 3）一致。附註：因為是 `source`，`set -euo pipefail` 與 EXIT trap 裝進了 worker 的 debug shell、`die` 退出的是那個 shell——無 lab 影響，只解釋了「它就停在那裡」。

**(d) 還有沒有正常結果會在 `set -e` 下結束 run？沒有。** 我逐行重讀 `detect`（`:316-372`）、`census`（`:375-446`）、run 區塊（`:692-745`）：每條正常結果分支都以 `return 0`、`continue`、`case` 臂、或回 0 的 `fail`／`note` 收尾（`fail` 最後一個指令是 `bad` → printf → 0，`_common.sh:71`；`:320/325/329/441` 的裸 `return` 因此回 0）；所有正常路徑可回非 0 的函式（`nd_up`、`nd_down`、`sp_hb_start`、`wait_session`、`watch_hit`、`child_running`、`cut_link`、`restore_link`、`no_netem_on_cut`、`netem_attach_point`、`precheck_tc`、`consts`、`host_pid`）都在 `&&`／`||`／`if`／`!` 裡；`watch_sniffers`、`census`、`detect` 本身現在永遠回 0；`:740` 在 PART=census 時 `[[ ]]` 假、`&&` 串豁免。剩下的只有**儀器**失敗（非正常結果）：(i) `hb_watch all-heard`／`others-up`（`:334`、`:350`）用裸 `load()`（不像 `wait-*`／`first-hit`／`census-verdict` 有 try/except），報告檔不存在才會死——`start` 回 0 加上前面的 `wait-heard` 之後實務上到不了，且 daemon 以 `os.replace` 原子換檔；(ii) `:743` `column … | sed` 在 pipefail 下，機器沒裝 `column`（bsdextrautils）會把做完的 census 變成「exited 127 before its own verdict」。兩者都是 note。

## worker 的裸呼叫稽核

與我的結果一致（SUMMARY `:513-523`）。兩處小不精確：「`hb_watch` … 回 0」對 `all-heard`／`others-up` 只在報告存在時成立（上文 (d)(i)）；`< <(model_hosts …)` 沒列，但其狀態由構造被忽略。沒有漏掉任何會在正常結果下結束 run 的地方。

## 新發現（本輪 diff 沒有弄壞任何東西；以下全是 note）

- **R4-1 [note]** `wait_session` 不檢查 `status == "running"`（或 `pid`＝剛起的 daemon）：若 `start` 回 0 的瞬間檔案仍是上一臂的「stopped」報告，會把舊 session 交給 sniffer。窗口是微秒級（daemon 寫完 pidfile 緊接著寫報告），影響只及 payload 啟發式——ethertype 規則與 `first-hit` 不用 session。修：只接受 `status == running` 的報告。
- **R4-2 [note，第一輪就存在]** `:347` `cut_link || break`：第二端 `tc add` 失敗時，CUT_A 的 netem 只由 EXIT trap 在 `nd_down` 拆掉 veth **之後**才試著移除 ⇒ `revert_link_loss` 回「cannot locate」⇒ 多一條誤導的 `fail`。無殘留（veth 已不在）。修：`cut_link || { restore_link || true; break; }`。
- **R4-3 [note]** `:743` 加 `|| true`（上文 (d)(ii)）。
- **R4-4 [note]** oldcode 工具只在 session scratchpad；log 保存了效果（三行 diff＋紅線）但沒保存方法。若要證據方法活過 scratchpad，把 `oldcode.sh` 放進 `spike/` 或 `gates-0910/`。
- **R4-5 [note]** detect 驅動沒定義 `QDISC_TOOL`：此情境到不了 `:339` 所以無妨，但未來加「OK」情境會像 `5c882c9f` 那樣死於驅動自己的 `set -u`；現在就補上。

## 核對

- 五份 worker log 與 rerun 第一行都是完整 sha；`4861a458` 2 紅（clean window、session）、`5c882c9f` 3 紅（＋detect，該紅無效已揭露）、`e1245b40` 0 紅 PASS、probe rc 0、oldcode「exactly the two checks」rc 0；rerun 0 紅、「NOT run (opt-in)」、helper sha `6a558fe4`。
- verified：所有行號對照 head `e1245b40` 全文（`wt-p4-heartbeat-0925/doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`）、`oldcode.sh`、`_common.sh:41-42,71`；inferred：bash errexit 例外規則（手冊）、`mnexec -a 1` 語意（本機無原始碼）。
