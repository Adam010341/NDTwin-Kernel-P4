# run-04（sonnet）— orchestrator 獨立複驗（2026-09-03 02:35–03:0x CST）

**原則**同前三輪：tester 的回報是**宣稱**。每一列都是本線進 guest **唯讀**採證
（`orchestrator-scripts/{recon04,harvest04}.sh`、`pull04.sh`，18:36–18:37Z）
或讀 repo 原始碼／`doc/KNOWN-ISSUES.md` 查出來的。
「CONFIRMED-by-log」＝只讀它留下的 raw log、沒重跑。
VM＝`nslab:~/ndtwin-vm-usertest-04-sonnet/`（port 2314、qemu 342820）。guest＝UTC，host＝CST（+8）。

🔴 **原始碼引用的口徑（共用 worktree，必須先講）。** 本文所有行號一律以 **`git show HEAD:`** 覆核，
不是讀工作樹，理由是採證當下這棵樹有別的 session 的未提交修改：

- **`tools/test_workflow/ndt`：工作樹乾淨**（`git status --porcelain` 空）⇒ 與 HEAD 相同，行號直接可用。
- ⚠️ **`tools/test_workflow/stack.sh`：工作樹有別人 149 行的未提交修改**（`git diff --stat`）。
  **本文不採用那份**。所有 `stack.sh` 的行號都是 HEAD 的：`:67`（`prompt_for_mininet` 的 `read`）、
  `:771`（`await_convergence`）、`:780-781`（`start_bg kernel`）。
  已逐一確認那份未提交 diff **沒有觸及 `prompt_for_mininet`**（hunk 落在 `:279`／`:364`／`:379`／
  `:436`／`:779`／`:781`／`:865`／`:872` 附近）；它對 `:781` 的改動是在 `./bin/ndtwin_kernel` 前面加 `exec`，
  **而 kernel 自己的 argv 在兩個版本裡完全相同** ⇒ 〈註 ①〉的識別在兩版下皆成立。
- ⚠️ **tester 實際跑的不是這棵樹**，是它從 GitHub clone 的公開快照 **`936f8c6`**
  （`logs/ndt_status_baseline.log`：`code 936f8c6 (clean tree)`）。**本線讀不到那份**
  （公開 repo 推不上去也沒有本機副本）⇒ 凡是讀碼得到的機制結論，口徑是
  **「trunk HEAD 是這樣，而公開快照比 HEAD 舊」**，不是「tester 跑的那份逐字如此」。
  〈註 ①〉的四項證據裡，**前兩項（log 路徑、argv 形狀）不依賴讀碼**，是從 guest 的 raw log 直接讀出來的。

🟢 **這一輪有 tester 的最終報告**（`JOURNAL.md` 的 `## SUMMARY`，517 行、17 節、每節有
`started`／`ended`／`friction` 分數），與 run-03 不同——run-03 的 agent 被我們自己 session 的
用量上限殺掉、沒有總結。run-04 跑滿 **6h48m** 並自行收尾。

🔴 **採證缺口，先講在前面。** harvest 時 **guest 上沒有任何 tmux server**
（`pane_capture_errors.txt`：`NO TMUX SERVER AT HARVEST TIME`），所以**一格 pane 都沒採到**。
tester 自己 tee 到 `~/logs/` 的 54 個檔是這一輪唯一的第一手畫面。
這造成一個系統性後果，見〈註 ⑦〉：**它在自己回合裡讀過就丟掉的 shell 輸出，事後無檔可查。**

## 時間線（guest UTC ／ host CST＝+8）

| UTC | CST | 事件 |
|---|---|---|
| 15:35:01 | 23:35 | VM start（4 vCPU／6144 MB、affinity 16-19）；qemu 342820 |
| 15:37 | 23:37 | sonnet tester 派出（prompt sha256 前 16 碼 `efa1f596e3ee76f0`；docs **`2612b0a`**） |
| 15:39–15:49 | 23:39–23:49 | 安裝手冊 §1／§2／§3，**friction 全 0** |
| 15:51 | 23:51 | §4 build 丟背景（`setsid`）→ **tester 停手（干預 #1 的起因）** |
| 15:57 | 23:57 | §4 build 完成（`CMAKE_EXIT=0`／`NINJA_EXIT=0`）；tester 自述於此時被外部叫醒 |
| **16:0x** | **00:0x** | 🔴 **干預 #1**（帳本記錄的時刻；與 tester 自述的 15:57 差約 10 分，見〈註 ⑨〉） |
| 15:59:10 | 23:59 | `ndt` 安裝（`mkdir -p ~/.local/bin` 有跑、`.local/bin` birth＝15:59:10） |
| 16:00:09–16:05:17 | 00:00–00:05 | `ndt up ovs` 卡 **5m08s** 後 `XX fabric has 0 hosts, expected 128` |
| 16:02:57 | 00:02 | §6.1 `install-p4dev-v8.sh` 進 `p4` tmux **detached** 開跑（逐字照抄 `2612b0a` 新增的那段） |
| 16:05:5x | 00:05 | `ndt down` → `clean`（五條斷言全過） |
| **16:08:38** | **00:08** | 🔴 **孤兒 kernel pid 59174 誕生**——見〈註 ①〉，本線已查明來源 |
| 16:15:08 | 00:15 | tester 自己的 Terminal 3 被 `:6343` 擋下（BUG-3） |
| 16:18:38 | 00:18 | 孤兒被 `kill -TERM 59174` 收掉 |
| 16:19:49 | 00:19 | 自己的 Terminal 3 起來：`10 switches, 128 hosts, 288 edges up` |
| 16:26–16:47 | 00:26–00:47 | Web GUI／NSR／NTG／SPM＋ESA／TrafficVisualizer |
| **16:52–16:53** | **00:52** | 🔴 **干預 #2**（同一個錯誤信念，第二次） |
| 18:11–18:12 | 02:11 | §6.2–6.6：兩個 binary 驗過、pipeline 編過、proxy venv 建好 |
| 18:13:23–18:16:29 | 02:13–02:16 | `ndt up`（bare／P4）卡 **3m06s** 後失敗 |
| 18:16 | 02:16 | `install-p4dev-v8.sh` `SCRIPT_EXIT=0`；`log.txt` 自報 **`Total time : 7748 sec`** |
| 18:17–18:21 | 02:17–02:21 | User Manual 的 P4／BMv2 三終端走完，全部數字命中 |
| 18:25:27 | 02:25 | `JOURNAL.md` 最後一次寫入（`## SUMMARY` 完成）＝ tester 收尾 |
| 18:37:15 | 02:37 | 本線唯讀 harvest（140 檔；tmux 已全滅、機器乾淨） |

## 宣稱 vs 證據

「檔案」欄一律相對 `tester-files/`。

### A. 安裝手冊 §1–§5

| # | 宣稱（tester 原文） | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| 1 | §1 friction 0；Ubuntu 24.04.4、x86_64、無 `~/Desktop` | `JOURNAL.md:20-25` ＋ `logs/s4_1_clone.log` | `mkdir -p ~/Desktop` 確實在 §4.1 被需要 | **CONFIRMED** |
| 2 | §2 friction 0；`python --version` 印 `Python 3.8.20` | `logs/s2_2to5_ryu.log:88` | `Python 3.8.20` | **CONFIRMED** |
| 3 | §2.4 驗證區塊「matched the manual's expected output *exactly*」：dnspython 1.16.0、eventlet 0.30.2、greenlet 2.0.2、ryu 4.34 | `logs/s2_2to5_ryu.log:761-764` | `dnspython 1.16.0` ／ `eventlet 0.30.2` ／ `greenlet 2.0.2` ／ `ryu 4.34` | **CONFIRMED** |
| 4 | §2.5 `ryu-manager` 掛住＝成功；Ctrl-C 收掉 | `logs/s2_5_ryutest.txt`（216 B）＋ `s2_5_ryutest_afterctrlc.txt`（**0 B**） | 後者空檔＝session 隨 ryu 消失，與它自述一致 | **CONFIRMED** |
| 5 | §2.7 networkx 3.1／requests 2.28.2／urllib3 1.26.20 | `logs/s2_7.log` | 依 pin 安裝 | **CONFIRMED** |
| 6 | §3 friction 0；驗證區塊「matched on every line」，`sudo mn --test pingall` → `0% dropped (2/2 received)` | `logs/s3_all.log:2417,2444` | `*** Results: 0% dropped (2/2 received)` | **CONFIRMED** |
| 7 | §2.6 三個 knob 讀碼確認：`NDTWIN_RYU_TOPO_FILE` 可覆寫、`is_mininet` 被無條件重設、`switch_num` 三層 fallback | repo `intelligent_router.py:36-38`／`:42-55`／`:92-101` | `Path(os.environ.get("NDTWIN_RYU_TOPO_FILE", …))`；`⚠️ EDITING THIS LINE DOES NOTHING.`；三層 fallback 逐字吻合 | **CONFIRMED**（＝ run-03 #1 的修法 `c60c70f` 生效，見〈註 ④〉） |
| 8 | §4 build：`CMAKE_EXIT=0`、`NINJA_EXIT=0`、**零** `warning:`、`ndtwin_kernel` 11.8 MB、約 6 分鐘 | `logs/s4_2_build.log:48-49,148-149` | `CMAKE_EXIT=0` ／ `NINJA_EXIT=0`；`grep -c 'warning:'` ＝ 0 | **CONFIRMED** |
| 9 | §5 `testbed_topo.py` 已在 repo、10575 B、executable | `logs/s5_check.log` | `-rwxrwxr-x 1 ndt ndt 10575 … testbed_topo.py` | **CONFIRMED** |
| 10 | clone 到的 kernel 快照＝`936f8c6` | `logs/ndt_status_baseline.log` | `code  936f8c6  (clean tree)` | **CONFIRMED** |

### B. `ndt` launcher

| # | 宣稱 | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| 11 | 三個安裝步驟全 WORKS（symlink／root `ndtwin-lab`／sudoers） | `logs/ndt_install.log` | `lrwxrwxrwx … ndt -> …/tools/test_workflow/ndt`；`-rwxr-xr-x 1 root root 6560 … ndtwin-lab`；`ndt ALL=(root) NOPASSWD: …` | **CONFIRMED** |
| 12 | `mkdir -p ~/.local/bin` 不再吐 `No such file or directory` | `logs/ndt_install.log` ＋ `GUEST-STATE.txt`（`.local/bin` **Birth: 15:59:10**） | 全程無 `ln:` 錯誤 | **CONFIRMED**（＝ R12 ③ 的前半，見〈註 ③〉） |
| 13 | `ndt: command not found`（非 login shell）／`bash -l -c` 後正常 | **無 raw 檔**（`grep -rn 'command not found' logs/` 命中 0） | — | **UNSUPPORTED**（機制無疑，見〈註 ③〉與〈註 ⑦〉） |
| 14 | 手冊那句 login-shell 註記逐字＝「Open a new login shell before calling `ndt`. … Log out and back in, or start one with `bash -l`.」 | `BUGS.md:79-80`（tester 逐字引手冊）＋ `GUEST-STATE.txt` 的 `.profile:25-27` | `if [ -d "$HOME/.local/bin" ] ; then PATH="$HOME/.local/bin:$PATH" fi` | **CONFIRMED**——**它讀到了那段註記，而註記管用** |
| 15 | `ndt up ovs` 5m08s（16:00:09→16:05:17）後 `XX fabric has 0 hosts, expected 128`，`NDT_UP_OVS_EXIT=1` | `logs/ndt_up_ovs_attempt1.log` | 逐字，含頭尾兩個時戳 | **CONFIRMED** |
| 16 | `ndtwin-lab` 裡的 `/home/adam/…` 是真的、無條件 | repo `tools/test_workflow/ndtwin-lab:51-56` ＋ KNOWN-ISSUES **G-7** | `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel` 等四行 | **CONFIRMED**（已知＝**G-7**） |
| 17 | `ndt down` 之後五條斷言全 ok、印 `clean` | `logs/ndt_down_1.log` | `ok ports 8000/8080/8081 closed` ／ `clean` | **CONFIRMED** |
| 18 | `ndt down` 只檢查 8000／8080／8081 | repo `ndt:1112-1119`（`cmd_clean`） | `for p in 8000 8080 8081; do` | **CONFIRMED**（見〈註 ①〉） |
| 19 | `ndt up`（bare／P4）3m06s（18:13:23→18:16:29）後 `fabric did not come up: 0/10 switches, manifest missing`，並自報診斷指令 | `logs/ndt_up_p4_attempt1.log` | 逐字，含 `XX look at the pane: sudo -n /usr/local/sbin/ndtwin-lab topo-out 40` | **CONFIRMED**（頭尾時戳本身在 `JOURNAL.md`，log 內無時戳；差值與 mtime 18:16:26 相符） |
| 20 | `ndt --help` 與 User Manual 的指令表逐字相符 | `logs/ndt_help.log` | `up [what]` … `apps [names]` … `energy sim nsr viz te` | **CONFIRMED** |
| 21 | `ndt apps nsr` → `XX NSR not found at /home/ndt/Desktop/Network-State-Recorder`，symlink 後 → `nohup: failed to run command '/home/ndt/miniconda3/envs/ntg-env/bin/python'` | `Desktop/NDTwin-Kernel/test_run-harvested/logs/app_nsr.log`（後半）；前半**無 raw 檔** | `nohup: failed to run command '/home/ndt/miniconda3/envs/ntg-env/bin/python': No such file or directory` | **後半 CONFIRMED／前半 UNSUPPORTED**（`NSR_DIR`／`NTG_PY` 在 `ndt` 內確為此形，已讀碼） |
| 22 | `ndt ntg` → `XX not found: /home/adam/Network-Traffic-Generator/setting/Mininet.yaml` | **無 raw 檔** | — | **UNSUPPORTED**（同 G-7 家族，機制經讀碼成立） |
| 23 | `ndt check`／`ndt claim`／`ndt release`／`ndt clean`／`ndt down --deep` 全 WORKS | **無 raw 檔**（`logs/` 無對應 log） | — | **UNSUPPORTED**（五條 CHECKLIST 的正面宣稱） |
| 24 | `ndt status` 有 `note /ndt/get_cpu_utilization is fabricated in MININET mode` | `logs/ndt_status_baseline.log` | 逐字 | **CONFIRMED**（＝ run-01 BUG-011 的揭露仍在） |

### C. User Manual — OVS 三終端

| # | 宣稱 | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| 25 | Terminal 2 的內建自測：128 個 `Pinging from`、128 個 `Result from`、**全部 100% packet loss** | `logs/T2_mininet.log`（run 1）：`Pinging from`＝128、`Result from`＝128、`100% packet loss`＝**128**、`0% packet loss`＝**0** | `1 packets transmitted, 0 received, 100% packet loss, time 0ms` | **CONFIRMED** |
| 26 | 同樣的失敗在**第二次獨立重啟**重現 | `logs/T2_mininet_snapshot2.txt`：128／128／**128**／0，banner ＝1 | 同上 | **CONFIRMED** |
| 27 | NTG 自己那份 `testbed_topo.py` 也一樣 | `logs/NTG_T2_snapshot.txt`：128／128／**128**／0，banner ＝1 | 同上 | **CONFIRMED** |
| 28 | banner 照印 `Host internet: OK \| sFlow reachability: OK \| Switch identification: OK` | `logs/T2_mininet.log:1611-1613` | `--- Final Configuration Active ---` 下一行逐字 | **CONFIRMED** |
| 29 | 「同一對主機幾秒後手動 ping 通、0% loss」（`h1 ping -c 3 10.0.0.65` 三收三） | **無 raw 檔**：`T2_mininet_snapshot2.txt` 只有**一行** `mininet>`（`:1869`，檔尾），其後未再存畫面；全樹 `3 packets transmitted` 命中 0 | — | 🔴 **UNSUPPORTED**（見〈註 ②〉；BUG-2 本身**不因此垮掉**，另有旁證） |
| 30 | 收斂數 `ovs-ofctl dump-flows sN \| grep -c actions=` ＝ **130，十台皆同** | **無 raw 檔**：全樹無任何 `ovs-ofctl` 輸出（`cookie=0x`／`n_packets=` 命中 0） | — | 🔴 **UNSUPPORTED**（R12 ⑤ 的受測物，見〈註 ⑤〉） |
| 31 | Ryu log 有 `install_all_pair_paths done: hosts=128 pairs=16256 rules=128 paths=3968` | `logs/T1_ryu.log` | 逐字命中（同檔另有 `rules=1280 paths=16256` 兩行） | **CONFIRMED**（引的是三行中的一行，非全部） |
| 32 | Terminal 3 首次被 `:6343` 擋下，錯誤訊息誠實具體 | `logs/T3_kernel.log` | `bind() to sFlow port 6343 failed: Address already in use. Another NDTwin kernel is almost certainly still running…` ／ `[critical] [main.cpp:406] cannot start telemetry collection` | **CONFIRMED** |
| 33 | 孤兒 pid 59174、起於 16:08:38、`ss -ulnp` 與 `ps` 兩具工具互證 | pid＋起始時刻 **CONFIRMED**（`test_run-harvested/logs/kernel.log:10`：`pid=59174`，首行時戳 `16:08:38.740`）；`ss`／`ps` 兩段畫面**無 raw 檔** | `[run] pid=59174 tid=59181` | **CONFIRMED-by-log**（畫面本身 UNSUPPORTED，但事實由更強的證據獨立成立） |
| 34 | 「無法確定它從哪來，兩個候選各半」 | 本線已**查明**：來自 `stack.sh` 的 `start_bg kernel` | 見〈註 ①〉 | **CONFIRMED-but-mis-stated**：候選 (b)（`testbed_topo.py` 的副作用）**已被排除**；(a) 實質成立 |
| 35 | 自己的 Terminal 3 起來後 `10 switches, 128 hosts, 288 edges up` | `logs/T3_kernel_run2.log` | 逐字，`16:19:49.611` | **CONFIRMED** |
| 36 | 流量驗證：`get_detected_flow_data` **恰好 2 筆**、一方向一筆、h1↔h2 | `logs/T3_kernel_run2.log:29,31,32` | `(flows=2, counters=2)`；`Flow Key: 10.0.0.1 -> 10.0.0.2 idles`／`10.0.0.2 -> 10.0.0.1 idles` | **CONFIRMED**（由 kernel 自己的計數與 flow key 獨立成立；API 回應體無存檔，整數值 16777226／33554442 的十六進位換算與 10.0.0.1／10.0.0.2 相符） |
| 37 | iperf3 持續 **~955–956 Mbit/s** | **無 raw 檔**（全樹無 `Mbits/sec`） | — | **UNSUPPORTED** |
| 38 | 閒置 >15 s 後 API 回 `[]`，對上 `FLOW_IDLE_TIMEOUT` | `logs/T3_kernel_run2.log:31-32` 有 `purgeIdleFlows … idles`（16:20:30，距最後流量約 11 s）；`[]` 本身**無存檔** | — | **CONFIRMED-by-indirect**（purge 事件成立；回應體未存） |
| 39 | 無旗標啟動→三問互動提示，逐字與手冊相同，答 1/1/2 | **無 raw 檔** | — | **UNSUPPORTED** |
| 40 | Ctrl-C 時 **沒看到** `terminate called without an active exception`（B14），並自承可能是 `tee` 造成 | `logs/T3_kernel_run2.log` 尾端確無該行 | — | **CONFIRMED**（負面觀測成立） |
| 41 | 第二次（P4 那次）用 `>` 導向就**看到了**該行，回頭結掉 B14 | `logs/P4T3_kernel.log:77` | `terminate called without an active exception` | **CONFIRMED**——**它自己的兩次觀測互相解釋，方法差異被隔離出來**（＝ KNOWN-ISSUES **B-5** 的行為） |
| 42 | `sudo mn -c` 會連 Ryu 的 tmux session 一起殺（手冊有警告） | **無 raw 檔**（session 前後清單未存） | — | **UNSUPPORTED** |
| 43 | 第三次完整重啟同樣收斂到 10／128／288 | `logs/T3_kernel_run3.log:18-19` | `Data plane: ovs (10 switch(es))`；`10 switches, 128 hosts, 288 edges up`（16:23:58） | **CONFIRMED** |
| 44 | run 1 的 Mininet CLI 崩在 `OSError: [Errno 5] Input/output error`，判為自己 `tee` 的問題不是專案缺陷 | `logs/T2_mininet.log` 尾 | `OSError: [Errno 5] Input/output error` | **CONFIRMED**——**歸因也正確**（run 2 不接 `tee` 未重現） |

### D. §6 P4／BMv2

| # | 宣稱 | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| 45 | §6.1 以 **detached tmux** 開跑，逐字照抄手冊 | `orchestrator-evidence/2026-09-03_00-03_p4-detached-as-documented.md`（**跑到一半時的唯讀觀測**） | `p4: "cd ~ && ./p4-guide/bin/install-p4dev-v8.sh 2>&1 \| tee log.txt; \\ echo \"SCRIPT_EXIT=\\${PIPESTATUS[0]}\" >> log.txt"` | **CONFIRMED**（本線當場取證，非事後推斷） |
| 46 | 開跑前先做手冊要求的 `conda deactivate`／python 版本檢查，順序沒弄反 | `logs/s6_1_pyversion.log`（`Python 3.12.3`）＋ `s6_0_check.log`（16:02） | `S6_0_EXIT=0` | **CONFIRMED** |
| 47 | 16:02:57 開跑 | `logs/s6_1_kickoff_time.log` ＝ `16:02` | — | **CONFIRMED**（分鐘級；秒數僅見於 `JOURNAL.md`） |
| 48 | 「約 2h13m」總時 | `log.txt:14241` ＝ **`Total time : 7748 sec`**（＝2h09m08s）；`log.txt:14605` ＝ `SCRIPT_EXIT=0` | — | **CONFIRMED-but-mis-stated**：腳本自報 **7748 s**，tester 從未引用這個數字，只給了自己的外部觀測 2h13m。兩者量的不是同一段（見〈註 ⑥〉） |
| 49 | 兩個 binary 都會答 `--version`，且與手冊 2026-09-02 的例子逐字相同 | `logs/s6_2to6_setup.log:5-13` ＋ `GUEST-STATE.txt` | `1.15.6-1c8c9a4f`；`Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)` | **CONFIRMED**（**兩條 `--version` 都被回頭收了**，＝ R12 ② 的後半） |
| 50 | §6.2 編譯乾淨，只有兩個良性 warning，產出 75852 B／4051 B | `logs/s6_2to6_setup.log:19-31` | `'TYPE_ARP' is unused`；`.txt format is being deprecated`；`75852` ／ `4051` | **CONFIRMED** |
| 51 | §6.3 proxy venv 由 Python 3.12.3 建、pin 全裝（含 `protobuf==3.20.3`） | `logs/s6_2to6_setup.log:33,134` | `Python 3.12.3` | **CONFIRMED** |
| 52 | `bmv2_binary_override` 原指 `bmv2-fast`，依手冊 6.6 改成 stock 並確認可執行 | `logs/s6_2to6_setup.log:149-170` | `/usr/local/bmv2-fast/bin/simple_switch_grpc` → `selected: /usr/local/bin/simple_switch_grpc`；`[ -x … ]` | **CONFIRMED**（該檔的「刻意無 fallback」註解＝ G-7 的第三處） |
| 53 | P4 三終端：`Data plane: bmv2`、切去打 :8081、收斂 10／128／288 | `logs/P4T3_kernel.log:18,20,22` | `Data plane: bmv2 (10 switch(es))`；`10 switches, 128 hosts, 288 edges up`；`Destination paths loaded from localhost:8081 (16256 pairs)` | **CONFIRMED** |
| 54 | `:8081/ryu_server/all_destination_paths` ＝ **16256**，兩次 5 s 取樣穩定 | `logs/P4T3_kernel.log:21` 有 `Pulled 16256 paths from controller`；三次 curl 的畫面**無存檔** | `Pulled 16256 paths` | **CONFIRMED-by-indirect**（數字成立；「穩定」那半無檔） |
| 55 | P4 上流量驗證同樣**恰好 2 筆** | `logs/P4T3_kernel.log:50,52` | `(flows=2, counters=2)` ×2 | **CONFIRMED** |
| 56 | stock（debug）build 吞吐 **~34–37 Mbit/s**，落在手冊記的 ~40 Mbps 天花板內 | **無 raw 檔** | — | **UNSUPPORTED**（與 KNOWN-ISSUES **F-bmv2** 相容，但本輪無自有量測檔） |
| 57 | Terminal 1 十台 BMv2 起來、manifest 10 筆真 PID、gRPC 50051-50060 | **無 raw 檔**（`/tmp/ndtwin_p4_switches.json` 未採到） | — | **UNSUPPORTED** |
| 58 | Mininet `exit` 之後 `simple_switch_grpc` 存活數已經是 **0**（`ps -eo args= \| grep -c "[s]imple_switch_grpc"`） | **無 raw 檔**；`GUEST-STATE.txt` 的 `/proc` 掃描（18:37）確認全機無殘留 | 只有 `ovs-vswitchd` 一支系統服務 | **CONFIRMED-by-indirect**（終態成立；當下那一格無檔） |

### E. 工具頁

| # | 宣稱 | 佐證檔 | 逐字節錄 | 判定 |
|---|---|---|---|---|
| 59 | NSR：`./start_network_state_recorder.sh` 直接 `ModuleNotFoundError: No module named 'nornir'`；腳本裡是 bare `python3` | **無 raw 檔**（traceback 未 tee） | — | **UNSUPPORTED**（＝ run-01 **BUG-006** 家族，run-01 已有獨立證據） |
| 60 | NSR：`stop_…sh` 的 `sudo kill -15 $(pgrep -f …)` **實地打到自己的 shell**（184273＋190740，ssh exit 255） | **無 raw 檔** | — | **UNSUPPORTED-as-transcript／CONFIRMED-as-known**（見〈註 ⑧〉） |
| 61 | NSR 前景模式起不來：kernel 沒開時自己退出 | `logs/nsr_foreground_test.log` | `NDTwin server is not reachable, exiting...` | **CONFIRMED**（**這是誠實的失敗，值得記正面**） |
| 62 | Web GUI：`pnpm install --frozen-lockfile` → `ERR_PNPM_IGNORED_BUILDS` on `esbuild@0.25.5`，容器零啟動 | `logs/webgui_deploy.log:331,334,338` | `Error: ERR_PNPM_IGNORED_BUILDS` ／ `Ignored build scripts: esbuild@0.25.5` ／ `Failed to start containers.` | **CONFIRMED** |
| 63 | Dockerfile 用**未 pin** 的 `npm install -g pnpm`，今天解到 **v12.3.0** | `logs/webgui_deploy.log:220,262` | `RUN npm install -g pnpm`；`Done in 322ms using pnpm v12.3.0` | **CONFIRMED**（連版本號都有檔） |
| 64 | Docker 29.7.2／Compose v5.5.0 | `logs/webgui_docker_install.log:148,150` | 逐字 | **CONFIRMED** |
| 65 | 手冊 `chmod a+r …/docker.asc` 失敗（該行前面建的是 `docker.gpg`），但無害因為已是 644 | `logs/webgui_docker_install.log:33-34,44-45` | `chmod: cannot access '/etc/apt/keyrings/docker.asc': No such file or directory`；`644 root:root /etc/apt/keyrings/docker.gpg` | **CONFIRMED** |
| 66 | `groupadd docker` 在這個順序下永遠說 already exists | `logs/webgui_docker_install.log:139` | `groupadd: group 'docker' already exists` | **CONFIRMED** |
| 67 | D5：繞過 frontend、`postgres`＋`node-positions-api` 兩支單獨起得來 | **無 raw 檔**（`logs/` 無此次 compose 的 log） | — | **UNSUPPORTED** |
| 68 | NTG：`venv --system-site-packages` 是必要的，`import mininet` 通 | `logs/ntg_install.log:3,137-138` | `python3 -m venv --system-site-packages /home/ndt/ntg-env`；`mininet importable from ntg-env: /usr/lib/python3/dist-packages/mininet/__init__.py` | **CONFIRMED**（＝ run-01 BUG-008 **已被 `062d8eb` 修掉**） |
| 69 | NTG `flow --config` 跑完，kernel 端獨立看到 **29** 筆偵測流 | `logs/NTG_T3_kernel.log` | `flows=29`（命中 1 次；同檔最大到 `flows=32`） | **CONFIRMED**（由 kernel 自己的計數獨立成立） |
| 70 | NTG Ctrl-C 會把整個拓樸拆掉，與手冊 Notice 一致 | **無 raw 檔** | — | **UNSUPPORTED** |
| 71 | SPM 真的掛了 NFS、`Server started at http://localhost:9000` | `logs/spm_run.log:3-4` | `mount -t nfs localhost:/srv/nfs/sim /mnt/nfs/sim`；`Server started at http://localhost:9000` | **CONFIRMED** |
| 72 | 手冊 5.4 的例子寫 `:8003`，而實際是 `:9000`，出貨預設已經對 | repo `setting/AppConfig.hpp.example:6` ＝ `http://localhost:9000/submit`；`AppConfig.hpp:6` ＝ `http://127.0.0.1:9000/submit` | — | **CONFIRMED-in-part**：`:9000` 側完全成立；手冊寫 `:8003` 那半**本線無法查**（docs 快照未採，見〈註 ⑨〉） |
| 73 | ESA 單獨跑會卡在 `/srv/nfs/sim/power` 不存在 | `logs/esa_run.log` | `mount.nfs: mounting localhost:/srv/nfs/sim/power failed, reason given by server: No such file or directory` ／ `EXIT=1` | **CONFIRMED** |
| 74 | Traffic Visualizer：`./mvnw clean package` BUILD SUCCESS 26 s | `logs/trafficvis_install.log:1345,1347` | `[INFO] BUILD SUCCESS`；`[INFO] Total time:  26.219 s` | **CONFIRMED** |
| 75 | 無 display 時照手冊預測失敗；`xvfb-run` 下真的跑起來、有 render loop | `logs/trafficvis_run_headless.log`（失敗）＋ `trafficvis_run_xvfb.log`（`TopologyCanvas.draw()` 出現 **3882** 次） | `TopologyCanvas.draw() - nodes: 0, links: 0, flows: 0` | **CONFIRMED** |
| 76 | `ndt apps energy`／`sim` 印 `ok … started` 而 tmux session 已經不在；兩種前提各試一次 | **無 raw 檔**（`ok energy started` 全樹命中 0）；機制由 repo `ndt:1928-1929` 讀碼成立 | `energy) sudo -n "$LAB" energy-start >/dev/null && ok "energy started (tmux: energy)"` | **UNSUPPORTED-as-transcript／CONFIRMED-as-known**（＝ **G-6**，見〈註 ⑩〉） |
| 77 | `viz` 誠實拒絕、`te` 誠實回報找不到 | repo `ndt:1933-1943` | `err "viz is a JavaFX GUI and there is no display; not starting it"`；`err "TE app not found"` | **CONFIRMED-by-source**（與 G-6 的「五個目標裡兩個說謊」完全一致） |
| 78 | Web GUI 的 `.env` 有手冊從沒提過的 `VITE_GITHUB_TOKEN` | `logs/webgui_deploy.log`（`.env` 內容被印出）| — | **CONFIRMED** |

### F. Tester 自陳的三則自我校正

| # | 宣稱 | 佐證 | 判定 |
|---|---|---|---|
| 79 | 兩次「停手」是自己工具的問題，不是專案 | `JOURNAL.md:60-70`／`:317-325`；帳本兩段逐字 | **CONFIRMED**——**它自己歸類正確，沒有把干預算到 NDTwin 頭上** |
| 80 | JOURNAL 有一段被腳本重複貼了兩次，已刪並留 `.bak-dedup` | `JOURNAL.md.bak-dedup`（492 行）vs `JOURNAL.md`（517 行）；`JOURNAL.md:456-465` | **CONFIRMED**——**主動揭露，不是被抓到** |
| 81 | 總時 15:37→18:25、約 6h48m | `logs/` 最早 15:40:48、`JOURNAL.md` mtime 18:24:54、`CHECKLIST.md` 18:25:27 | **CONFIRMED** |

## 統計

| 判定 | 條數 |
|---|---|
| **CONFIRMED**（含 by-log／by-source／by-indirect） | **58** |
| **CONFIRMED-but-mis-stated** | **2**（#34 孤兒來源、#48 7748 s） |
| **CONFIRMED-in-part** | **1**（#72） |
| **UNSUPPORTED** | **20** |
| **CONTRADICTED** | **0** |
| **UNVERIFIABLE** | **0** |
| 合計 | **81** |

🔑 **20 條 UNSUPPORTED 沒有一條是「說了假話」**——它們全部是**同一個取證缺口**的實例：
tester 在自己的回合裡讀了 shell 輸出、寫進 BUGS/JOURNAL，然後**沒有把那段輸出存成檔**。
凡是它 tee 到 `~/logs/` 的（kernel／ryu／build／install／deploy），逐字對得上；
凡是它只在回合裡看過的（`ndt apps`／`ndt status`／`ovs-ofctl`／`iperf3`／NSR traceback／
手動 ping／compose 子集），事後一格都沒有。見〈註 ⑦〉。

---

## 註

### ① 🔴 BUG-3 的來源，本線已查明：是 `ndt` 自己的 `stack.sh` 起的，而且是**失敗路徑漏出來的**

tester 列了兩個候選並誠實地不選（這是對的做法——它被規則禁止讀原始碼）。
**本線可以讀，於是查到了。** 四項證據：

1. **它寫進了只有 `stack.sh` 會寫的檔。**
   `tester-files/Desktop/NDTwin-Kernel/test_run-harvested/logs/kernel.log` 全檔**只有一個 pid：59174**，
   時間從 `16:08:38.740` 到 `16:18:38.964`。那個路徑逐字來自 `stack.sh:780`：
   `start_bg kernel "$LOG_DIR/kernel.log" …`。`testbed_topo.py` 不會寫這個檔。
2. **argv 形狀對得上 `stack.sh:781`，而且與 tester 自己的形狀不同。**
   `stack.sh:781` ＝ `bash -c "cd '$KERNEL_DIR/build' && exec ./bin/ndtwin_kernel --mode mininet --topology '$topo' --no-ai"`
   ⇒ 相對的 `./bin/`、**絕對**的 `--topology`、**沒有 `--loglevel`**。
   `ps` 抓到的 59174 正是這個形狀（`BUGS.md:201-202`）。
   tester 自己的 Terminal 3 則是 `sudo bin/ndtwin_kernel --topology ../setting/… --loglevel info`
   （`logs/T3_kernel.log:3` 逐字是相對路徑 `../setting/…`）。**兩種形狀不會混淆。**
3. **失敗路徑會漏，機制在 `ndt` 裡。** `ndt` 的 `cmd_up ovs` 把 `stack.sh` 當**背景協同行程**
   （`$stack_pid`），用一個 FIFO（fd 3）驅動它過關。而 `stack.sh` 那一端是
   `prompt_for_mininet`（`:59-68`），核心是 **`read -r -p "  Press Enter once Mininet is up…" _ || true`**。
   phase [2/4] 失敗時 `ndt:923-925` 做的是：
   ```
   err "fabric has $live_hosts hosts, expected $ovs_hosts"
   exec 3>&-; kill "$stack_pid" 2>/dev/null; rm -f "$fifo" "$out"; return 1
   ```
   🔑 **`exec 3>&-` 關掉 FIFO 的寫端，等於給了 `stack.sh` 一個 EOF——而 `|| true` 把 EOF 吃掉，
   `prompt_for_mininet` 回 0。** 也就是說：**「中止」與「使用者按了 Enter」在那一端長得一模一樣。**
   `kill` 只打 `$stack_pid` 一個 pid、不是整個 process group，而 `start_bg` 起的 kernel 是
   **`setsid` 獨立 session**，殺不到。
4. **時間對得上，而且對得很準。** `stack.sh` 過了 `prompt_for_mininet` 之後先跑
   `await_convergence "$mode" "$topo" "$CONVERGE_WAIT"`（`stack.sh:771`），
   `ndt:893` 給的 `CONVERGE_WAIT` 是 **400 s**。
   FIFO 在 **16:05:17** 關閉 → tester 自己的 Ryu（16:07:21）＋ `testbed_topo.py`（16:08:19）
   造出一個**真的**收斂 fabric → `await_convergence` 回 0 → `start_bg kernel` 於 **16:08:38**。
   **201 秒，落在 400 秒上界內。**（而且就算沒收斂也會起——`await_convergence` 逾時那一支
   印完 warning 之後仍 `return 0`，理由寫在碼裡：「starting it anyway so the state can be inspected」。）

⇒ **候選 (b)（`testbed_topo.py` 起 kernel 當副作用）排除；(a) 實質成立並補全了機制。**
⇒ 這條的正確標題不是「有一個孤兒行程」，而是：
🔴 **`ndt up` 的失敗路徑會留下一支活的 `stack.sh`，它接著把 kernel 起到別人的 fabric 上。**
使用者看到的第一個症狀是三分鐘後、在一個完全不相干的埠上的 bind 失敗。

**清單為什麼沒接住它——兩層，第二層才是重點。**

| 層 | 碼 | 對 6343 的結果 |
|---|---|---|
| 埠清單 | `ndt:1112`（`cmd_clean`）／`ndt:161`（`deep_sweep`）皆 `for … in 8000 8080 8081` | **6343 不在清單裡** |
| 埠**原語** | `ndt:127` `port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") … }`；`ndt:132-137` `port_listener_pids` 用 `ss -ltnpH` | **兩者都只認 TCP**；6343 是 **UDP**（`UNCONN … 0.0.0.0:6343`） |

🔑 **所以「把 6343 加進那三個埠」不是修法**——加了也看不到，因為底層原語構不到 UDP。
`--deep` 同樣構不到（它迭代同一份清單、用同一支原語）⇒ **回答任務書的問題：`deep_sweep` 也不會抓到。**
而行程計數那條路一樣盲：`bmv2_count`（`:88`）只數 `simple_switch_g`，
`mn_count`（`:115`）只數 argv 末欄以 `mininet:` 開頭的——**`ndtwin_kernel` 兩邊都不是。**

⚠️ **一個必須說清楚的口徑更正。** BUGS.md 的 severity 段寫「`ndt down` 報告機器全乾淨，
而一支它不知道的 kernel 至少跑了 9 分鐘」——**`ndt down` 跑在 16:05:5x，孤兒生在 16:08:38，
晚了 2 分 41 秒。那一刻 `ndt down` 沒有說謊。** 而且孤兒同時佔著 `:8000`，
所以若當時再跑一次 `ndt clean`，它**會**報 `:8000 still listening`。
真正站得住的講法是三句：
(a) 斷言集**對 `:6343` 結構性地盲**（清單缺、原語也構不到）；
(b) `ndt status` 把一支沒人擁有的 run 描述成一次正常健康的 run，**沒有任何欄位分辨「你起的」與「別人起的」**
（`lab > claim` 讀 `none`，而 `running` 區塊一切正常——兩本帳互相矛盾）；
(c) 起因是 `ndt up` 自己的失敗路徑。

**這是一族的第四個實例，不是單點。** 同一晚另一條線獨立查到另外三個沒人檢查的埠
（bmv2 的 `:3005x`、Ryu 的 `:6653`／`:6633`、simulator 的 `:9000`）。
**本線逐一覆核過那三個**：在 `tools/test_workflow/ndt` 裡
`6653`／`6633`／`9000`／`50051` 出現次數皆為 **0**，`3005` 出現 **1** 次且只在 `:635` 的註解裡；
`9000` 在 `stack.sh` 裡也是 **0**。
⇒ 本輪這一個是**第四個，也是唯一一個被實地觀測到擋住合法操作的**。
修法的形狀因此不是「再加一個 if」，而是**一張宣告式的表**（埠、誰擁有它、被佔住時的代價），
本輪讓那張表變成**五列**。

### ② 🔴 BUG-2：banner 根本不是從 ping 結果算出來的

**回答任務書的問題：完全不是。** 讀 `testbed_topo.py`：

- `ping_test(src, dst_ip)`（`:142-149`）**只 print，沒有回傳值**，
  呼叫端把它丟進 `threading.Thread`（`:232-240`），**join 完就沒了，結果一個都沒被收**。
- banner（`:245-246`）是**兩行無條件的 `print`**：
  ```python
  print("\n--- Final Configuration Active ---")
  print("Host internet: OK | sFlow reachability: OK | Switch identification: OK")
  ```
  三個 `OK` 是**字串常值**。⇒ **沒有任何輸入能讓這行印出別的東西。**
- 而且那段迴圈自己的註解寫的是 **「Launch ping tests in parallel to generate some traffic.」**
  ⇒ 它**本來就不是健康檢查**，是造流量的。缺陷是**兩件不相干的事被排在一起**：
  上面那段印出 128 個失敗，下面那行印一個寫死的 OK，讀者只能讀成「檢查過了，OK」。

**失敗本身的形狀也指向自測而非 fabric**：128 個 result 全部是
`1 packets transmitted, 0 received, 100% packet loss, **time 0ms**`。
`time 0ms` 與「一個封包等到逾時」不相容——真的逾時會是秒級。
⇒ **這是自測自己的量測壞掉**，不是網路壞掉。

⚠️ **但 tester 用來證明這一點的那一格沒有存檔**（#29）。
`T2_mininet_snapshot2.txt` 的最後一行就是 `mininet>`，之後它手打的
`h1 ping -c 3 10.0.0.65` 與那三個回應**從來沒被再截一次畫面**。
**BUG-2 不因此垮掉**——`time 0ms`、fabric 之後跑得動 iperf3、kernel 兩次都收到 2 筆流、
三個獨立副本（Kernel／run 2／NTG）全部 128/128——但**它最漂亮的那一格是空的**。
這正是 run-03 交代給 run-04 的第 1 條取證教訓，而它只被套用在 tmux pane 上，沒被套用在
「我在自己回合裡讀過的輸出」上。

### ③ R12 ③ 的自我懷疑：**沒有應驗**

`2612b0a` 對 #3 做了兩件事：補 `mkdir -p ~/.local/bin`，加一段「Ubuntu 的 `~/.profile`
只在**登入時**判斷該目錄存不存在」的註記。帳本預先寫明「**後半會不會被照做，我沒把握**」。

- **前半：成立。** `mkdir -p` 在 tester 自己的 `ndt_install.sh` 裡（逐字），
  `.local`／`.local/bin` 的 **Birth 都是 15:59:10**，全樹沒有一行 `ln: failed to create symbolic link`。
- **後半：註記被讀到了，而且夠用。** tester 在 BUGS.md 的 **Expected** 欄**逐字引了那段註記**
  （`Open a new login shell before calling ndt. … Log out and back in, or start one with bash -l.`）
  ——這證明它讀到了；然後它**從第一次呼叫 `ndt` 起就用 `bash -l -c`**
  （BUG-1 的步驟區塊逐字寫著 `bash -l -c "ndt up ovs"     # bash -l because a non-login shell does not see ~/.local/bin`）。
  它自己的結論是「**Not filing this as a defect — the manual anticipates it and gives a working fix**」，
  嚴重度標 Cosmetic。

⇒ **任務書給的兩個選項（讀了但不夠 ／ 根本沒讀到）都不是。** 第三種：**讀了，而且夠。**
剩下的殘餘成本只有一個，而且 tester 講得比我準：手冊寫的兩條出路是
「登出再登入」與「`bash -l`」，而它的世界是 `ssh host 'cmd'`——**第三種情境手冊沒點名**，
`bash -l -c` 恰好蓋得住。⇒ 若還要再修，該補的是「非互動 ssh 一次性指令」這一句，
**不是 PATH 機制**。這是措辭增補，不是硬錯 ⇒ 依本輪門檻（只修硬錯）**不該在 run-05 動它**。

### ④ `c60c70f`（#1 的修法）在這一輪**被正面驗證**

run-03 的 #1 是「§2.6 三個 knob 與實檔不符」。run-04 的 tester 逐一讀檔核對，三個全對得上
（`intelligent_router.py:36-38`／`:42-55`／`:92-101`，本線覆核逐字吻合），
還發現手冊自己寫的「about 545 lines further down」實際是 546 ⇒ **連近似值都準**。
⚠️ 但 `static_topology_file_path` 的**預設值**在 repo 裡仍是 `/home/adam/…`（G-7 的第一處）；
手冊改對的是「這個 knob 怎麼用」，**不是那個預設值**。tester 選了非破壞性的 env 覆寫，正確。

### ⑤ 「130 條／台」沒有檔——而它正是 R12 ⑤ 的受測物

`2612b0a` 把收斂停止條件從 131 改成 **130**，並寫清楚組成（128＋LLDP＋table-miss）。
R12 ⑤ 預期「`ovs-ofctl dump-flows` 每台 130，不會有人等 131 等到天亮」。
tester 在三個地方（BUGS.md、CHECKLIST B3、JOURNAL）都寫了「130 on all ten switches」，
**而全樹沒有一行 `ovs-ofctl` 的輸出**（`cookie=0x`／`n_packets=` 命中 0）。
⇒ 這一條**只能記成 UNSUPPORTED**。
可得的旁證只有一個方向且不完整：`logs/T1_ryu.log` 有
`install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 …`，1280/10 ＝ **128**
——那是 128 條**目的地規則**，與 130（＝128＋LLDP＋table-miss）的**組成相容**，
但它不是「每台 130」的量測。**⑤ 的「不會有人等 131」這半是成立的**（沒有任何等待紀錄），
**「數字對得上」那半沒有檔。**

### ⑥ §6.1 的耗時：三個數字，要分清楚在量什麼

| 數字 | 出處 | 量的是 |
|---|---|---|
| **7748 s**（2h09m08s） | `log.txt:14241`，**腳本自報** | `install-p4dev-v8.sh` 內部計時 |
| 「約 2h13m」 | `JOURNAL.md:396`，tester 的外部觀測 | 16:02:57 → 看到 `SCRIPT_EXIT=0` 的 18:16 |
| 「約 2h08m」 | `JOURNAL.md:349`，tester 的里程碑觀測 | 16:02:57 → 兩個 binary 都答 `--version` 的 18:11 |

三個都不假，但**只有第一個是可比的量**（run-03 的 7640 s 也是同一支腳本自報的）。
tester **從未引用 7748**——它給的是自己的兩個外部觀測。
⇒ 判 **CONFIRMED-but-mis-stated**：不是錯，是**沒有引用可比的那個數字**。
R12 ② 的裁定要用 7748 對 7640（見 `RECONCILIATION.md`）。
🔑 **順帶：這正是 `2612b0a` 那筆修正想避免的誤讀**——手冊自己寫「`SCRIPT_EXIT=0` 不是驗收、
驗收是 Step 6.2 的兩條 `--version`」，而 tester **逐字照做了**（`JOURNAL.md:398-401`：
「exit 0 says the script ended, not that it succeeded」），並在腳本還在跑的時候就先收了兩條
`--version` 往下走。**這筆文件修正在行為上生效了，可以直接觀測到。**

### ⑦ 🔴 這一輪最重要的取證發現：**存檔的對得上，沒存檔的一格都沒有**

20 條 UNSUPPORTED 不是散落的，它們有一條乾淨的分界線：

| tester 怎麼取得 | 條數 | 事後可查？ |
|---|---|---|
| `… > ~/logs/X.log` 或 `\| tee`（kernel／ryu／build／install／deploy 的**長期輸出**） | 全部 | ✅ **逐字對得上**，含它引用的每一個數字 |
| `tmux capture-pane > 檔`（run-03 交代的第 1 條） | 3 個 snapshot | ✅ 對得上 |
| **在自己回合裡跑、讀完就丟的一次性指令** | 20 | ❌ **一格都沒有** |

落在第三類的：`ndt apps` 的輸出、16:15 那次 `ndt status`、`ovs-ofctl dump-flows` 的計數、
`iperf3` 的吞吐、NSR 的 traceback、`pgrep`／stop 腳本的附帶殺、手動反證 ping、
compose 的兩服務子集、`/tmp/ndtwin_p4_switches.json`、互動三問提示。

🔑 **run-03 給 run-04 的模板修正只補了 tmux pane 與長 build 兩種情況**
（帳本：「pane 一律存檔不 `tail`、長 build 要記開始／背景化指令／回收時間」），
**而漏掉的正是最常見的那一種：普通指令的輸出。**
⇒ **run-05 的模板要補的是一條更一般的規則**，形狀建議：
> **凡是你打算在 BUGS.md／JOURNAL.md 裡逐字引用的輸出，先把它寫進 `~/logs/` 再引用。**
> 「我在這個回合裡看過」不是證據——你的回合會結束，檔案不會。

⚠️ **這不是說 tester 造假。** 它引用的內容，凡是有旁證的都對得上
（`flows=2`／`flows=29`／16256／288 edges／兩個版本字串／pnpm v12.3.0），
`0 CONTRADICTED`。**問題是我們拿不到它看到的東西，而不是它看錯了。**

### ⑧ BUG-4 的 `pgrep -f`：這是這個專案的硬規矩**第一次被實地重現**

CLAUDE.md 的硬規矩是「**永不 `pkill -f`／`pgrep -f` 殺程序**」，
KNOWN-ISSUES **G-9** 記著 `ndtwin-lab cleanup` 裡有四行 `pkill -f`，
文末〈同一個字串 `iperf3`〉記著同形狀的另一則。**在此之前，這些都是「我們知道它遲早會誤傷」。**
run-04 的 tester 讓它**當場誤傷了自己的 shell**：`pgrep -f network_state_recorder.py`
同時命中 NSR（184273）與**正在跑上一條指令的那個 shell**（190740，因為它的 argv 裡有那個字串），
`sudo kill -15` 兩個都送，該 shell 的 ssh 連線 **exit 255**。

- **證據等級：transcript 只在 `BUGS.md:386-402`，無 raw 檔** ⇒ 逐字那格判 UNSUPPORTED。
- **但事實本身有 run-01 的獨立支持**：run-01 **BUG-006** 是同一支腳本、同一個 pattern、
  同樣「caught 2 PIDs, cut my own SSH command short」。**兩輪、兩個不同的 agent、同一個機制。**
- **加重情節：手冊自己在同一頁、兩節之前，逐字警告不要這樣寫**
  （tester 引：「Do not pipe the search straight into `kill`. Writing
  `sudo kill -15 $(pgrep -f network_state_recorder.py)` looks shorter, but it fails in three ways
  and all three are silent…」）。⇒ **出貨的腳本是它自己那段警告的反面教材。**

⇒ 嚴重度定 **High**（tester 自己給 Medium）。理由：它的失效面**超出 NSR 自己起的行程**，
打到呼叫者；而「從腳本／cron／CI 呼叫」是正常用法，不是刁鑽用法。

### ⑨ 三處本線查不到、必須誠實標明的邊界

1. **docs 快照沒採。** guest 的 `~/ndtwin-docs/` 只留了 `DOCS-SNAPSHOT.txt`（`website commit: 2612b0a`，
   已採），42 個 md 本體**沒有進 tar**，且該目錄**不是 git repo**（`GUEST-STATE.txt`：`fatal: not a git repository`）。
   ⇒ 凡是「手冊上寫著 X」的宣稱，本線只能靠 tester 的引用，**不能獨立覆核**（#72 的 `:8003` 那半就卡在這）。
   VM 映像已保留，需要時可重取。
2. **干預 #1 的時刻有 ~10 分鐘的出入。** 帳本記 **09-03 00:0x CST**（＝16:0x UTC），
   tester 自述 **caught ~15:57 UTC**（＝23:57 CST）。以帳本為準（當下寫的）；
   差額不影響任何判定，記在這裡是因為兩份記錄都會被引用。
3. **`mn --version` 變了。** `GUEST-STATE.txt` 讀到 **2.3.1b4**；run-03 的帳本記的是「`mn` 維持 2.3.0」。
   run-04 的 `install-p4dev-v8.sh` **跑完了整支**（含 mininet 元件），run-03 那輪 tester 沒看到結尾。
   NDTwin 用的是 §3.2 apt 裝的那份，本輪判準不涉及它 ⇒ **只記錄，不裁定**，列進 run-05 待查。

### ⑩ BUG-6 ＝ **G-6，一字不差**，外加兩點新佐證

任務書問「這是 G-6 本身還是它的延伸」。**是 G-6 本身**：

- G-6 的定義域逐字是 `ndt:1928-1929` 只看 tmux 的回傳碼。本線覆核該兩行**仍然是**：
  ```
  energy) sudo -n "$LAB" energy-start >/dev/null && ok "energy started (tmux: energy)" ;;
  sim)    sudo -n "$LAB" sim-start    >/dev/null && ok "sim started (tmux: sim)" ;;
  ```
- tester 撞到的正是這兩個指令、這兩個訊息、這個失效方向。**不是延伸。**

**兩點 G-6 沒有的新佐證：**
1. **在依賴齊備的情況下重現。** tester 第二次是在 **Ryu＋Mininet＋Kernel 全部收斂**之後再打一次
   `ndt apps energy`——結果一樣。⇒ **排除了「它只是因為前置條件沒齊才死」**，
   坐實 G-6 的結論「沒有任何一層問過『它還活著嗎』」。
2. **連 log 都沒有。** `.test_run/logs/app_energy.log`／`app_sim.log` 不存在
   （本線覆核 harvest 的 `test_run-harvested/logs/` 只有 `app_nsr.log`／`kernel.log`／`ryu.log` 三個）。
   ⇒ 這是繞過 `app_spawn` 的**實際後果**：使用者連個可看的東西都沒有。
   對照組就在同一次 harvest 裡——`app_nsr.log` 有一行具體有用的錯誤訊息。

**tester 沒碰到的**：G-6 的停止側（`ndt:1958-1959`，`;` 不是 `&&`，rc 連看都沒看）。
⇒ G-6 的定義域**不需要改**；要補的是「run-04 又撞到一次，且在依賴齊備下重現」這條紀錄。

---

## 缺陷歸類（已知 vs 新）

| tester 編號 | 是什麼 | 歸類 |
|---|---|---|
| **BUG-1** ＋ 兩則 addendum（`ndt apps nsr`／`ndt ntg`／`ndt up` P4） | `/home/adam` 寫死 | **已知＝G-7**（＋失敗訊息不指向成因＝**G-8** 的形狀） |
| PATH friction | `~/.local/bin` 非 login shell 看不到 | **非缺陷**（手冊已預告並給了可用解，見〈註 ③〉） |
| **BUG-2** | 自測假失敗＋寫死的 OK banner | 🆕 **新**（run-01／02／03 都沒抓到；本線另補「banner 與 ping 結果零關聯」的讀碼證明） |
| **BUG-3** | 孤兒 kernel 佔 `:6343`，teardown 斷言看不到 | 🆕 **新**，且本線把它從「有個孤兒」升級成 **`ndt up` 失敗路徑漏出活的 `stack.sh`**（〈註 ①〉）；同族第四例 |
| **BUG-4**（start 半） | NSR 啟動腳本 bare `python3`，與安裝手冊的描述矛盾 | **已知**＝run-01 **BUG-006** 家族（同一支腳本） |
| **BUG-4**（stop 半） | `pgrep -f` 實地誤殺呼叫者 | **已知**＝run-01 **BUG-006**；🔴 **但這是硬規矩第一次被實地重現**（〈註 ⑧〉），嚴重度上調 **High** |
| **BUG-5** | Web GUI 未 pin 的 pnpm 炸掉 frontend build | **已知**＝run-01 **BUG-009**（本輪刻意未修，見 DOCS-FIX-MAP） |
| **BUG-6** | `ndt apps energy`／`sim` 假成功 | **已知＝G-6，一字不差**（〈註 ⑩〉） |
| Docker `.asc` chmod／`groupadd` | 兩則手冊小疵 | 🆕 **新**（Cosmetic） |
| SPM 例子寫 `:8003` | 手冊小疵 | 🆕 **新**（Low；`:9000` 側已覆核，`:8003` 側本線查不到） |
| ESA 的 `/srv/nfs/sim/power` 依賴 | 相依性缺口 | 🆕 **新**（Low，tester 正確標為 dependency gap 而非 bug） |
| `VITE_GITHUB_TOKEN` 未文件化 | 手冊缺漏 | 🆕 **新**（Low） |
| NTG `NTG.yaml` 預設 `Hardware.yaml` | 手冊說「建議改」實為「必須改」 | 🆕 **新**（Low） |

**新缺陷 ＝ 7**（BUG-2、BUG-3、Docker 兩疵合一、SPM `:8003`、ESA NFS 依賴、`VITE_GITHUB_TOKEN`、NTG.yaml）
**已知 ＝ 4 族**（G-7／G-8、run-01 BUG-006、run-01 BUG-009、G-6）

[Co-developed with claude code -- Adam]
