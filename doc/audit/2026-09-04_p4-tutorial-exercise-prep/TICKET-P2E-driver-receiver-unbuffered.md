# TICKET-P2-E — driver 收 `receive.py` 的方式讓 link_monitor 的輸出死在 buffer 裡

orchestrator「9/18 ochestrator」2026-09-18 19:2x 寫；base trunk **`e738ef1f`**（碼＝`365c60e1`）。worktree `scratch/overnight-2026-09-05/wt-p2-recv-0918`，分支 `feat/p4-app-package-p2-recv-0918`。
上位工單 `TICKET-P2-exercise-dataplane.md` §7 第 11 條。與 P2-D（`ndt`／`stack.sh`）檔案不重疊，平行進行。

[Co-developed with claude code -- Adam]

## 0. 🔴 紅線（同 TICKET-P2 §0）
永不 `pkill -f`／`pgrep -f`；不 sudo、不起 Mininet、不碰 lab；Python 測試用 `p4_proxy/venv/bin/python -m unittest discover -s doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests -t doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests`；閘門用 `/usr/bin/grep`；只在自己的 worktree／分支 commit（`git commit -F <msgfile> -- <明列檔案>`，結尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`），不推不併；沒看過紅不算交付；閘門 stdout 存 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p2e-<sha>.log`。
**檔案所有權**：`doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py`、`…/tests/test_drive_exercise.py`、`tests/shell/mutate_drive_exercise.sh`。其他一律不動。

## 1. 現況（orchestrator 19:1x 於 tutorials harness 以 root 跑，log `scratch/overnight-2026-09-05/logs/orchestrator-0918/live/drive-link_monitor-{solution,skeleton}-tutorials.log`）
- link_monitor **兩臂都 FAIL**，第一條就倒：`FAIL injection: probes reached h1  want=>=1 report row  got=0 rows`；`logs/driver-h1-receive.log` **0 B**——連 `receive.py:26` 一開始就印的 `sniffing on eth0` 都沒有。
- 資料面沒問題：同一次跑的 bmv2 `s1.log` 有 8 次 `Egress port is 1`（＝`PROBE_SECONDS=8`，每秒一個 probe，全部回到 h1 那個口）。
- 同一支 driver 的 basic／source_routing 兩臂 PASS，因為 tutorials 的 `basic/receive.py:51,58` 與 `source_routing/receive.py:41,56` 自己 `sys.stdout.flush()`；**`link_monitor/receive.py` 不 flush**（:16-28 只有 print）。
- 機制：`drive_exercise.py:774 _start_receiver` 用 `[VENV_PY, script]` 起、stdout 導到檔案 ⇒ Python 對非 tty **全緩衝**；`:785 _stop_receiver` 先 `proc.terminate()`（SIGTERM）⇒ 直譯器不跑 atexit、不 flush ⇒ 整個 buffer 丟掉；`:792 fh.flush()` flush 的是 driver 自己的檔案物件，對子行程的 buffer 無效。

## 2. 契約
1. `_start_receiver` 起的命令改成 `[VENV_PY, "-u", script]`（或等價 `PYTHONUNBUFFERED=1` 進 env，二選一，SUMMARY 說為什麼）。**只改這裡**；`_stop_receiver` 的 terminate→wait→kill 序列不動（那是「只殺自己的 child」的紅線形狀）。
2. `steps_link_monitor` 的三條斷言與文字不動；docstring 加一句：receive.py 不 flush、driver 以 `-u` 補，並引 `receive.py:16-28` 與 09-18 19:11 的 0 B log。
3. `--dry-run` 的 plan 區逐字不變（`mutate_drive_exercise.sh` M1–M2 的 09-08 控制組仍要綠）。
4. 測試：`tests/test_drive_exercise.py` 用既有 `StubHosts.popened` 斷言 link_monitor／basic／source_routing 三條 steps 起的 receive 命令都含 `-u` 且在 script 之前；`mutate_drive_exercise.sh` 加一個變異「拿掉 `-u`」⇒ 那顆測試紅（其他全綠），控制組照舊。`tests/shell/check_gate_anchors.py <sha>` 全 ok。
5. 跑並存 log：driver tests（discover 與直跑）、`mutate_drive_exercise.sh`、`check_gate_anchors.py`。

## 3. 交付
SUMMARY `scratch/overnight-2026-09-05/hunt-0911/fix/P2-E-SUMMARY.md`：改了哪幾行、哪顆測試被哪個變異殺、閘門數字＋log 路徑。live 由 orchestrator 重跑（tutorials 兩臂＋ndtwin）。
