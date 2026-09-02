# run-01（sonnet）— auditor 補驗 4(a)(b)(c)（2026-09-02 20:09–20:28 CST）

auditor（9/1）要求、帳本 A-7／run-01 補驗列登記在先、R12 預測寫在跑之前。VM＝`nslab:~/ndtwin-vm-usertest-01-sonnet/`（port 2311，
run-01 結束時的狀態，只多了 `~/auditor-verification/` 與 `~/logs/av*.log`）。腳本在 `../orchestrator-scripts/`：`av_launch.sh`（preflight＋串跑）、
`av_a_ndt_up.sh`、`av_b_sigint.sh`（第一版，`kpid()` 有 bug）、`av_b2_sigint.sh`（重跑版）、`av_c_apps.sh`、`av_poll.sh`。
guest＝UTC；本目錄的檔是 guest 的原樣。`GUEST-STATE.txt`＝拉檔當下 repo 的 `git status`／`diff`。

## 預測 vs 結果

| 項 | R12 預測（帳本原文摘） | 結果 | 檔 |
|---|---|---|---|
| (a) `ndt up ovs` | ~300 s 後 `fabric has 0 hosts, expected 128`；root pane 最後幾行是 `/home/adam/miniconda3/envs/ntg-env/bin/python: No such file or directory` | **一字不差**：12:13:49→12:18:58 `XX fabric has 0 hosts, expected 128` rc 1；root tmux 活不到 2 s（45 次 capture 全空）；留住的 pane：`bash: line 1: /home/adam/miniconda3/envs/ntg-env/bin/python: No such file or directory` `EXIT=127` | `a2_ndt_up_ovs.txt` `a2_post_ovs.txt` `a3_pane_repro_ovs.txt` |
| (a) `ndt up p4` | 同理死在 `$NTG_PY $BRIDGE`；manifest 不存在 | `XX fabric did not come up: 0/10 switches, manifest missing`；pane 同句 `EXIT=127`；`/tmp/ndtwin_p4_switches.json` 不存在 | `a5_*` `a6_pane_repro_p4.txt` |
| (a) `sudo -n -l` | NOPASSWD ALL | `(ALL) NOPASSWD: ALL` | `a0_env.txt` |
| (b) SIGINT | sudo 會把 SIGINT 轉給 kernel，kernel ~5 s 內印關機序列並退出（即 BUG-010 來自認錯 pid 或重複啟動） | **成立**：兩輪都在對 sudo wrapper `kill -INT` 後 **2–3 s** 印 `All subsystems stopped. Exiting.` 並退出、:8000 釋放；arm2 不需要。kernel 的 `SigCgt=0000000100000002`（含 SIGINT）、`SigIgn=5`（HUP+QUIT）、`SigBlk=0` | `b2/b1_pre.txt` `b2/b1_arm1_wrapper.txt` `b2/b2_*` |
| (b) 額外 | — | **每次退出都以 `terminate called without an active exception` 收尾**（`logs/av2_kernel_1.log:208`、`logs/av2_kernel_2.log:45`；第一次跑 `logs/av_kernel_1.log:209` 同）。與 tester 的 `kernel_p4.log` 同句 ⇒ 關機路徑上的 abort，可重現；`doc/KNOWN-ISSUES.md` 目前沒有這句 | `logs/av*_kernel_*.log` |
| (c) `ndt apps sim`／`energy` | 再印 ok（`SIM_DIR`／`ENERGY_DIR` 寫死、tmux `-c` 進不去、秒死、`new-session -d` rc 0） | **成立**：`ok sim started (tmux: sim)` rc 0；3 s 後 `no server running on /tmp/tmux-0/ndtwinlab`、無 `app_sim.log`；留住的 pane：`./simulation_platform_manager: No such file or directory` `EXIT=127` | `c_sim.txt` `c_energy.txt` `c_sim_pane_repro.txt` |
| (c) `ndt apps nsr` | 走 `app_spawn`，因 `NTG_PY` 不存在而誠實報 `exited immediately` | 誠實但機制不同：`XX NSR not found at /home/ndt/Network-State-Recorder` rc 1（目錄檢查先擋） | `c_nsr.txt` |
| (c) 額外 | — | `ndt apps stop all` 對從沒起來的 sim／energy 印 `ok energy stopped`／`ok sim stopped` rc 0 | `c_stop_all.txt` |

## 順帶查到的

- **tester 在 repo 留了三個未提交修改**（`ndt status --check` 自己報「2 of them can change behaviour」）：
  `intelligent_router.py:38` 靜態拓樸預設路徑寫死 `/home/adam/Desktop/NDTwin-Kernel/setting/…`（sonnet 改成 `/home/ndt`；trunk 至今仍是 `/home/adam`，
  sonnet 的 JOURNAL 第 70 行有引）——與 ④ 同一家族、在 Ryu app 裡；`p4_proxy/mininet/bmv2_binary_override` 指 `/usr/local/bmv2-fast/bin/simple_switch_grpc`
  （Adam 機器的 fast build；sonnet 改成 `/usr/local/bin/`，JOURNAL 379 行）；`tools/test_workflow/ndtwin-lab` 只是 mode 100644→100755（內容同 trunk，
  `/usr/local/sbin/ndtwin-lab` 是指向它的 symlink）。(a) 測到的是 trunk 的內容。見 `GUEST-STATE.txt`。
- (b) 的 fabric 用 `sudo -n python3 testbed_topo.py`：系統 python3 有 mininet；guest 內**沒有** ntg-env（sonnet 的 NTG 安裝在 BUG-008 死掉），
  手冊那條 `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py` 在這台本來就跑不了。128 hosts、22 s 收斂（`b2/b0_fabric.txt`）。

## 儀器自己的錯（記下來）

第一次跑的 `av_b_sigint.sh` 用 `readlink /proc/<pid>/exe` 找 kernel——kernel 是 root 行程，ndt 讀不到它的 `exe` ⇒ `kpid()` 回空字串，
`b1_pre.txt` 的 `kernel=` 空、`kill -INT ''` 報 `not a pid`、cleanup 對空字串下手；腳本沒有斷言 pid 非空。log 與 `:8000` 本身已證明 kernel 死了，
但 SigCgt 等要 pid 才抓得到，所以用 `av_b2_sigint.sh`（以 `:8000` 持有者取 pid）重跑；第一次的 `b*.txt` 原樣保留在本目錄。

## auditor（9/1）裁定

**auditor 裁定 20:41**：三預測收下。`terminate called without an active exception` ⇒ KNOWN-ISSUES **§B 新條目（kernel 缺陷：關機路徑上 joinable `std::thread` 或解構子丟例外，行程以 134 而非 0 退出；示範看不到、檢查 rc 的 harness 會被騙）**，auditor 今晚整機一輪每次 `ndt down` 抓 kernel exit code 與 log 末五行複驗，修法排示範後、開單；`ndt apps stop all` 假 ok ⇒ 併 ⑤（§G，同「只看 tmux rc」的根）；`intelligent_router.py:38` 預設路徑（有 `NDTWIN_RYU_TOPO_FILE` 可覆寫、比 ④ 軟、但 naive user 不知道要設）⇒ 併 ④ 家族；`p4_proxy/mininet/bmv2_binary_override`（**trunk 追蹤的檔**、指 `/usr/local/bmv2-fast/…`、設計上無 fallback、檔不對就拒起 topology）⇒ §G 第三實例，**手冊安裝步驟必須要人（或 install script）寫這個檔**。三處進 auditor 的 KNOWN-ISSUES 下一波 diff（引 `01e642e8` 的 README）。run-03 照跑；push 仍 auditor 整合後一次做。
