# run-04 — 讀取式觀測：§6.1 的 detached 指令被逐字照做

抓取時間 2026-09-03 00:03 CST（guest 16:03 UTC），**唯讀**：只跑 `tmux list-sessions` /
`tmux list-panes` / `head`，未在 guest 建立或修改任何檔案，非干預。

抓這一格的理由：run-03 的 `pane_P4.txt` 是空的——tmux session 隨 build 結束消失，
採證時已經來不及。這裡在 build 進行中先取。

## 為什麼重要

run-04 的 R12 預期 ② 是「§6.1 會被丟背景（手冊這次自己教 `tmux new-session -d`）」。
下面 `pane_start_command` 的內容與 `2612b0a` 寫進 Step 6.1 的那段**逐字相同**，
包含 `; \\` 的續行與 `${PIPESTATUS[0]}`——tester 是照抄手冊，不是自己發明的。
在那之前它先跑了 `s6_1_pyversion.log`，即手冊要求的 `conda deactivate` / python 版本檢查，
順序與手冊一致。

```
2026-09-02T16:03:30+00:00
=== tmux sessions ===
p4 created=
=== pane start commands ===
p4: "cd ~ && ./p4-guide/bin/install-p4dev-v8.sh 2>&1 | tee log.txt; \\\n   echo \"SCRIPT_EXIT=\\${PIPESTATUS[0]}\" >> log.txt"
=== log.txt head ===
Found supported ID ubuntu and VERSION_ID 24.04 in /etc/os-release
Minimum recommended memory to run this script: 1920 MBytes
Memory on this system from /proc/meminfo:      5925 MBytes -> enough
=== bash_history 裡的 tmux 那行 ===
```
