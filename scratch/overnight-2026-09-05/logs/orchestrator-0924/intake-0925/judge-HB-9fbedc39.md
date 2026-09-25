# fable-judge report on feat/p4-heartbeat-0925 @ 9fbedc39 (segment H + S prep)

# 裁決：MERGE AFTER FIXES

helper 本體（`tools/test_workflow/ndtwin-lab` 的三個 hunk，root 入口）我沒有找到 blocking 級的安全缺陷，可以併。「AFTER FIXES」是因為同一分支裡段 S 的 spike 有兩個缺陷會讓**正常的一次跑也以 FAIL 收尾／浪費整個 lab 時段**（#1、#2），加上兩條政策點要 Adam 裁（#4、#5）。以下每條都標明「verified against a file」或「inferred」。

## 0. 證據核對（C／SUMMARY 的每個數字）

全部 verified against `scratch/overnight-2026-09-05/logs/gates-0910/*.p4hb-*.log`：

| 宣稱 | log | 結果 |
|---|---|---|
| head 全 sha 在第 1 行 | 五支 `*.p4hb-9fbedc39.log`＋`installed_helper_sha` | 六支第 1 行都是 `9fbedc392ec02c1b4dc1bf1117ca0cfd64e9ec22` ✓ |
| suite 186/0 | `test_ndtwin_lab_heartbeat.p4hb-9fbedc39.log:203-205` | `Ran 186 checks, 0 failed`／`# rc=0` ✓ |
| 變異 32 caught／0 survived | `mutate_...9fbedc39.log:48-51` | 逐行 32 個 `caught by:` 都等於點名的 check；control SURVIVED；restore byte-identical；rc=0 ✓ |
| anchors 117/117、base 116/116、新閘門 ok(33)、lab 四支 4/4 | `check_gate_anchors...log:15,24,27,38` | ✓。注意表格只列 6 行是 worker 的 `anchors.sh` 用 `tail -8` 截的（scratchpad `hb/anchors.sh:6`），摘要行是工具自己印的 |
| spike 自測 PASS | `spike_selftest...9fbedc39.log:38` | ✓ |
| 22 支 suite＋banner 只 1 紅 | `helper_suites...9fbedc39.log:10-11,31` | 唯一紅＝`test_ndt_helper_apps_window.sh` 的「installed helper is the copy this suite read」；該 check 就是比 sha（`tests/shell/test_ndt_helper_apps_window.sh:235-238`）；`installed_helper_sha` log：已裝 `6685d3a9`＝base，head `d504af41` ✓ 預期紅 |
| 紅燈先行 87/67 → 92/71 | 兩支 `.red.` log | ✓；第一輪儀器問題（EXIT trap 刪 TMPROOT）在 log 裡看得到（`line 158-210`），與 SUMMARY 描述一致 |
| 32a25b23 那輪 31/1（`no-topo-check` 紅錯顆） | `mutate_...32a25b23.log:13-15` | ✓，9fbedc39 改成看拒絕原因後被點名的顆抓到（`:13`） |

**空洞通過**：無實作那輪有 21 顆綠（92−71），全是「沒發生壞事」型：`$(...)` 沒執行 ×3、沒 glob、沒 launch ×3、stranger 還活著、8 顆「pidfile 垃圾：nothing is signalled」、no pidfile content executed、symlink nothing signalled、程式 checks ran to the end。其中只有 `and the stranger is still alive` 之後被變異（`stop-by-pid-only`）弄紅過；**8 顆「nothing is signalled」從未紅過**（見 #7）。

**抓錯顆**：逐一對過 32 個 pair 的語意，沒有靠錯的 check 抓到的。唯一要註記的是 `program-accepts-extra-args`：變異後 `daemon --iface eth0` 會真的進 `run_daemon()` 而在 `/run/ndtwin-lab` 上以 PermissionError 崩潰，rc 1 但訊息缺 `nothing else is accepted` ⇒ 點名的顆紅——是「崩了」不是「拒絕」，仍算有效。

## A. root 入口安全（verified against worktree `tools/test_workflow/ndtwin-lab`，行號＝worktree）

- **argv**：`heartbeat_main`（1603-1614）`(( $# != 1 ))` 先拒、`case` 字面比對、`*)` 用 `printf %q` 回顯；dispatch（1786）`shift; heartbeat_main "$@" || hb_rc=$?` 把 errexit 關在外面。介面、路徑、ethertype 都到不了程式碼。程式端 `main`（1399）`len(argv)!=2 or not in COMMANDS`。✓
- **manifest**（785-823）：先 `dir_trusted`（owner ∈ {root, expect_uid} 且「無 g/o 寫」或 sticky），再 `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` 開、同 fd `fstat`、S_ISREG、uid==0、`mode & 0o022 == 0`、1 MiB 上限。sticky /tmp 語意正確：adam 建不出 root 擁有的檔；預先放目錄會被 S_ISREG 擋；FIFO 被 O_NONBLOCK 擋（測試真的量了 5 s 不卡）。比 `tools/p4_power_helper.py:94-106` 的規則嚴（多了 O_NONBLOCK、S_ISREG、目錄、大小）。✓
- **誰寫 manifest**：`p4_proxy/mininet/p4_testbed_topo.py:494-534` `write_manifest`：mkstemp → chmod 0644 → `os.replace`，由 `topo-start`（1625-1628）在 root tmux 裡跑的拓樸程序寫；`p4_power_helper.py:120-136` 同形。✓ **但**：那個 root 程序執行的是 `KERNEL_DIR`（預設 adam 的 checkout，helper 自己的註解 60-65 行承認）裡的 `.py`，所以「root 寫的」≠「adam 碰不到的」——adam 可以透過 `topo-start` 讓 root 寫任何 manifest。這不是本刀擴大的（SUMMARY H.9 有揭露），而 heartbeat 的後段檢查限制了偽 manifest 能讓 root 做的事：介面必須叫 `<key>-eth<port>`（871）、`/sys` 存在、ETHTOOL 回 `veth`（941）、兩端 iflink 互指才送（957）。⇒ 一個偽 manifest 最多讓 root 在 adam 自己建起來的 veth 上每 5 s 送一個 60 byte 幀。**送不到實體網卡**（非 veth 即拒；連 listen 都不會開）。
- **/run/ndtwin-lab**：`hb_prepare_run_dir`（1432）只在不存在時 `mkdir -m 0755`；/run 是 root 0755 非 sticky，adam 預建不了；`hb_dir_trusted`（1416）再驗 symlink／owner／mode。無 TOCTOU 空間。程式以 mktemp+mv 新 inode 裝入（1440），0644。✓
- **python -I**：`/usr/bin/python3 -I`，絕對路徑 root 擁有；`-I` 自 3.4 起就不把 script 目錄／`''` 放進 sys.path、忽略 PYTHON*（inferred，Python 文件）；daemon `chdir("/")`；只 import stdlib；所有路徑常數是無條件賦值（`HB_EXPECT_UID=0` 等，非 `${X:-}`），env 蓋不掉。系統 site-packages 的 `.pth` 仍會被處理——那是這台機器上每一個 root python 共有的既有面，未擴大（無法不執行指令就驗權限，inferred）。
- **kill 路徑**：唯一送訊號處 `hb_signal`（1490），來源只有 `hb_read_pidfile`（1472：symlink 拒、`^[1-9][0-9]{0,9}$`）→ `hb_is_daemon`（1458：regex → `(( pid > 1 ))` → `/proc/<pid>/cmdline` 逐元素等於四個字 → `Uid: 0 0`）。pidfile 在 root-only 目錄。`hb_start` 逾時路徑也先 `hb_is_daemon` 再 TERM（1544）。**adam 無法讓 root 對任意 pid 送訊號。** regex 都排在算術之前，`x[$(...)]` 型算術注入到不了。✓
- **資源**：每方向每 PERIOD_S 一幀，方向數受真實 veth 數限制；報告 ≤2 次/s、大小∝介面數；log 只有起停各一行；POLLERR 先讀 SO_ERROR（1319-1326）、POLLNVAL unregister；`poll` 等待時間非負。foreign 幀洪流只會吃 CPU（DoS，非提權）。無忙迴圈。✓
- **daemon 收到的幀**：`decode` 固定長度 unpack；`on_frame` 只改計數與時間戳；沒有任何以幀內容為 key 的動作。偽造 heard 需要幀 INCOMING 到指定 rx 介面且 session／方向／端點全對——只能經由那條 cable 本身，所以 heard ⇒ cable 通，設計正確。✓

## B. daemon 是否只做幀＋報告

verified：`run_daemon`（1207-1361）除 AF_PACKET 收發、`/sys`、`/proc`、manifest 讀取、`/run/ndtwin-lab/{pid,lock,json,log}` 外無任何動作；`document()` 沒有 up/down 欄（測試釘住 19＋10 個 key；`report-makes-a-verdict` 變異紅過）；`render` 只印年齡。無 tc／ip／P4Runtime。✓

## D. ethertype 表與 §H.6

- H.5 標「讀過」，而且有自動掃描背書（26 支＋`ndtwin_switch.p4`，正對照 0x0800/0x0812/0x1212/0x1234 都看得到；`ethertype-collides` 變異紅過）。掃描是 regex（`bit<16> X = 0x…` 與 `0x…: state;`），十進位或運算得出的 ethertype 看不到（inferred；tutorials 沒這種寫法）。
- H.6 全段標「讀碼推得，未量」，`egress_spec 0` 明寫留給段 S。無 overclaim。「calc／multicast 單交換機」引用的是主 checkout 未提交狀態，有明講。
- 一個 SUMMARY 沒說的事實（verified，`p4_proxy/p4_src/ndtwin_switch.p4:377-400`、`p4_proxy/proxy_agent/topology_manager.py:1584-1589`）：在 **NDTwin 自己的 pipeline** 上，未知 ethertype 走 `l2_forward` 的 `default_action = send_to_cpu()` ⇒ 每個心跳幀變成一個 packet-in，proxy 的 `handle_packet_in` 會無條件把它記成該交換機的 `_last_packet_in`（存活證據）再因非 LLDP 丟掉。不會 flood 到主機，但會**污染 NDTwin 自家的存活判定與 packet-in 負載**（pod-topo 每 5 s 8 個）。⇒ 見 #4。

## E. 段 S spike（verified against `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`）

符合工單的部分：out-of-band netem 走 `faults.sh` 的 `netem_attach_point`（htb 安全掛點），不碰 `inject_link_failure`；自己 `require_free_lab`／`take_claim`（380，在所有拒絕之後）；`snapshot_knob`／`snapshot_telemetry_knob` 由 `_common.sh` 的 `finish()` 還原；EXIT trap 先 `revert_link_loss` 再 `heartbeat stop`；每輪後 `no_netem_on_cut`＋最後 qdisc 全樹 diff；主機看到幀或 `forwarded_to_hosts>0` ⇒ `STOP` → `fail`＋`return`（裁決 4）；EUID 0 拒跑；只碰寫死的 `s1-eth3`／`s3-eth1`；sniffer 只收不送、`timeout` 包住。沒有會傷 lab 的動作。缺陷見 #1、#2。

## F. 檔案 mode

verified：diff 標頭 `index 0ea96df3..c1fee179 100644`（mode 未變）；helper 自己的安裝指令 `ndtwin-lab:8` 與 `ndt:2462 LAB_INSTALL_CMD` 都是 `install -o root -g root -m 755`。H.8 的指令與既有慣例一致（只是寫成絕對路徑）。✓

## 發現（依嚴重度）

**1. [should-fix，段 S 開跑前必修] spike 正常跑完也會 FAIL：`finish()` 的第二次 `ndt down` 回 3。**
- 位置：`S_heartbeat_spike.sh:307`（detect 末尾 inline `"$NDT" down`）、`:363`（每個 census 臂 inline down）、`:161-174`（`spike_finish` → `_common.sh` `finish()`）。
- 證據：`live-p1/_common.sh:239-246` `finish()` 在 `CLAIMED` 時再跑一次 `ndt down` 且 `(( down_rc == 0 )) || fail`；`tools/test_workflow/ndt:4924-4932` `cmd_down` 在「nothing was up」時 `down_verdict=3`（Adam 09-12 裁）。⇒ detect／census 已 inline 收掉 fabric，trap 再 down 一次 ⇒ rc 3 ⇒ 最後一行 `FAIL S_heartbeat -- 'ndt down' exited 3`。07 沒踩到是因為它 phase B 之後才交給 finish（`07_roles_basic.sh:650-656`）。自測只跑純函式，沒覆蓋 teardown。
- 修：detect 末尾與最後一個 census 臂不要 inline down（交給 finish），或在 `spike_finish` 裡先問 `ndt status`、若已 down 就把 `CLAIMED` 的 down 半段跳過（release 照做）。任一種都要用 stub `$NDT`（down 回 3）在自測裡走一遍 trap。

**2. [should-fix，段 S 開跑前必修] tc 權限沒有預檢：可能 claim、建 fabric、起心跳後才在第一刀失敗。**
- 位置：`S_heartbeat_spike.sh:180`（`require_root` 只驗 ndtwin-lab＋mnexec，`_common.sh:96-97`）、`:237-246`（`run_tc`）。
- 證據：`faults.sh:88` `FAULTS_TC="${FAULTS_TC:-sudo -n tc}"`；`faults.sh:311-319` 自述 sudo 的 tc 授權（08-13 量的）只放 `root netem` 形式，`parent H:D` 不放；`_common.sh:93-98` 又說 operator 只有 ndtwin-lab／mnexec 兩條授權。三處說法不一致，spike 沒有自己驗。basic/solution 無 shaping ⇒ 不走 TCLink（`p4_testbed_topo.py:937-952`）⇒ 掛點會是 `root`，若 tc 授權還在就能過；若不在，`cut_link` 失敗 → `break` → FAIL，白用一個時段（無損害）。
- 修：`take_claim` 之前 `run_tc qdisc show dev lo` 探一次，拒絕就 `die`（rc 2、不 claim）；或照 `faults.sh` 自己的逃生路，`FAULTS_TC="sudo -n mnexec -a <拓樸 pid> tc"`。

**3. [should-fix，helper，可留給段 W 但建議現在做] helper 不拒絕 NDTwin 自己的 pipeline。**
- 位置：`plan()`（925-969）已解析出 `Switch.program`（basename of the .json）卻不用它。
- 證據：見 D 最後一段——NDTwin pipeline 上心跳幀＝packet-in＝存活證據污染。SUMMARY H.9 承認、留給 `ndt`；但 `ndt` 不是 sha 釘住的，而一句 `sudo ndtwin-lab heartbeat start` 就能在 NDTwin fabric 上開跑（含 H5 要求的「01 PASS（NDTwin fabric 不變）」基線）。
- 修：`plan()` 裡 `if any(s.program == "ndtwin_switch.json") → Refusal("NDTwin's own pipeline carries LLDP; heartbeat frames would be packet-ins counted as liveness")` rc 1；一顆測試＋一個變異。在修好或 W 的 `ndt` 擋住之前，orchestrator 不得在 NDTwin fabric 上 start。

**4. [政策，需 Adam] 設定檔閘門對 `heartbeat stop`／`status` fail closed。**
- 證據：`ndtwin-lab:280-294` `lab_conf_gate` 只放 `status|config`；`:1622` 每個動詞都先過閘；heartbeat 三個子動詞完全不讀 `KERNEL_DIR`／設定檔。後果：`/etc/ndtwin-lab.conf` 打壞時，一個 root daemon 停不掉（它會在 manifest 消失後 ≤5 s 自停，rc 4——verified `fabric_changed`＋測試，但那要先能 `topo-stop`，而 `topo-stop` 也被閘住）。
- 建議：`lab_conf_gate "${1:-}" "${2:-}"`，`heartbeat` 且 `$2 ∈ {stop,status}` 放行（觸碰的只有 `/run/ndtwin-lab`），`start` 維持 fail closed；G-7 suite 加測試、`mutate_g7_ndtwin_lab_config.sh` 加變異（ok(15)→16）。

**5. [政策，需 Adam] 是否要求 helper 端擋 NDTwin pipeline（=#3 的裁決）。** 建議 helper 端擋：它是釘 sha、要 Adam 重裝的那份，保證不依賴 `ndt` 版本。

**6. [note] `bmv2_alive`（886-893）只看任一 argv 元素 basename==`simple_switch_grpc`，不看 uid。** adam 用 `python3 -c 'import time;time.sleep(1e6)' simple_switch_grpc` 就能滿足。不是邊界（manifest 仍須 root 擁有），但 `hb_is_daemon` 已示範了更嚴的形狀；加一行 `Uid: 0 0` 檢查即可。

**7. [note→建議補] 「每條規則都看過紅」對「nothing is signalled」不成立。** 8 顆垃圾 pidfile 的 `nothing is signalled`（`tests/shell/test_ndtwin_lab_heartbeat.sh:318-327`）與另外 12 顆負向 check 從未紅過（讀端 regex 與 `hb_is_daemon` 是兩層，單一變異弄不紅）。helper 標頭（585-608）的「each … has been seen red」對這組是 overclaim。建議：垃圾清單加 `a[$(touch @TMP@/pwned5)]`（算術注入形），讓「did not run」對「regex 在算術之前」的順序敏感；並在標頭把「seen red」限定到正向那顆。

**8. [note] 從未執行的：sudo 下的 dispatch。** SUMMARY 有揭露。我讀碼的推論（inferred）：`set -euo pipefail` 下 `|| hb_rc=$?` 使 `heartbeat_main` 內 errexit 失效、rc 原樣傳出；`hb_status` 的 rc 3 會正確變成 exit 3。裝好後第一件事應是無 fabric 時 `sudo ndtwin-lab heartbeat status`（期望 rc 3）與 `start`（期望 rc 1 且訊息點名 topo session）。

**9. [note] 兩個 `start` 競爭的 helper 端分支（1533-1536「another start won the race」）未測**（daemon 端 rc 2 有測）；`hb_stop` 的 KILL 後備與「KILL 路徑清 pidfile」（1569-1578）未測（替身都吃 TERM）。

**10. [note] 變異閘門依賴環境**：`ethertype-collides` 只有 `$HOME/tutorials/exercises` 存在時抓得到（本機 26 支）；沒有時會 SURVIVED 讓閘門紅（響亮、非靜默），應寫進閘門標頭。

**11. [note] 段 S census 的停止是在 20 s sniff 窗結束後才判**，主機在第 1 s 看到幀時心跳還會再送 ≤4 輪；符合裁決 4 的精神（停、不繞），但可把 `wait` 改成看到即殺 sniffer 群。

**12. [note] `hb_sniff.py` 經 `sudo -n mnexec -a <pid>` 以 root 執行 adam 可寫的 .py**——與 `ndt` 的 `dataplane_ok` 同一既有面（mnexec 授權本身就等於 root），sniffer 唯讀、限時、只記計數與第一個心跳幀 hex。

## 我會補跑而報告沒跑的測試

1. `lab_conf_gate heartbeat` 在設定檔被拒時的行為（G-7 suite 的 `inner` seam 就能做）——把 #4 從讀碼變成證據。
2. 兩個真 daemon 競爭 flock 的 helper 端 rc 0 分支；替身忽略 TERM 走 KILL 分支。
3. `a[$(touch …)]` 算術注入 pidfile；`MAX_MANIFEST_BYTES`；`-i` 重複綁定。
4. spike 用 stub `$NDT`（`down` 回 3、`claim`／`release` 回 0）乾跑 `spike_finish`→`finish` 的 verdict 路徑——會直接抓到 #1。
5. 段 S 開跑前 `sudo -n tc qdisc show dev lo` 的 rc（#2）。
6. 裝好後：`heartbeat status`（rc 3）、無 fabric `start`（rc 1）、pod-topo 上 `start`→`status`→`stop` 一輪，並以 `sudo tcpdump -i s1-eth3 ether proto 0x88b5` 確認真 veth 上 BPF／OUTGOING／netem 行為（SUMMARY 列為未量）。

## 數字對帳

- SUMMARY H.2「+1053／−1」：diff 有三個 hunk（+1053、+5 dispatch 段、usage 行 −1/+1）⇒ 實為 **+1059／−1**。
- H.0「既有 helper 相關 22 支 suite」：`helper_suites.sh` 列 22 支含新加的 heartbeat suite ⇒ 既有 21＋新 1＋banner。
- `check_gate_anchors` log 6 行 vs 117 cells：`tail -8` 截斷，非不一致。
- 其餘（186、92/71、87/67、32/32、31/1、26 支 .p4、8 方向、5 s、15 s、6685d3a9→d504af41）與 log／程式碼逐一相符。

主要檔案：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-0925/tools/test_workflow/ndtwin-lab`、`.../tests/shell/test_ndtwin_lab_heartbeat.sh`、`.../tests/shell/mutate_ndtwin_lab_heartbeat.sh`、`.../doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh`、`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.p4hb-*.log`、`.../wt-p4-heartbeat-0925/tools/test_workflow/ndt:4924-4932`、`.../wt-p4-heartbeat-0925/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:239-246`、`.../wt-p4-heartbeat-0925/tools/test_workflow/faults.sh:88,311-319`、`.../wt-p4-heartbeat-0925/p4_proxy/p4_src/ndtwin_switch.p4:377-400`、`.../wt-p4-heartbeat-0925/p4_proxy/proxy_agent/topology_manager.py:1584-1589`。