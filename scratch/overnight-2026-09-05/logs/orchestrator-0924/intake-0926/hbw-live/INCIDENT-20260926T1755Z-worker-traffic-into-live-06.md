# 事故：worker 的離線測試在 live 06 進行中把流量打進真 fabric（2026-09-26 17:55:05–17:55:17Z）

（orchestrator 記錄；9/25 orchestrator session。worker 自述＋orchestrator 查證。）

## 發生了什麼

- orchestrator 正在跑 H5 重跑（`NDT_OWNER=orch-0926 PART=h5 08_heartbeat.sh`，trunk `3f8c2abf`，17:29–17:56Z），其中 live-p1/06 逐臂起 fabric。
- 同時段，段 W 的 worker（修正輪 `fix/hb-followups-r2-0927`）在自己的 worktree 裡**不經 guard**試跑覆蓋率量測，其中執行了 `tests/shell/test_live_p1_common.sh`。
- 該測試 5e 段的 `to-h2`／`default` 兩格（`tests/shell/test_live_p1_common.sh:539,541`）用的假套件主機名是 `h1..h3`（與真 fabric 同名），而 `drive()` 只 stub 了 `curl`／`sleep`、沒 stub `sudo`／`iperf` ⇒ `host_pid` 找到**真 fabric 的主機**（當時是 06 的 p4runtime/solution 臂），執行 `sudo -n mnexec -a <pid> iperf -s/-c 10.0.2.2 -u -b 2M`（這台的 mnexec 免密碼）。

## 證據

- worker 的覆蓋標記 `_common.sh-701`（netdev_tx）建於 01:55:08.17 +0800（只有兩端 `host_pid` 都回數字才走到）。
- **orchestrator 查證**（`doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/<run>/link_usage/onpath.txt`，未提交的觀測；該 06 raw 已進 audit-raw `543a3aa2`）：

| run | s1-eth2 | s2-eth1 |
|---|---|---|
| 2026-09-26T061642Z_p4runtime_solution_ndtwin | 4360027 | 4346031 |
| 2026-09-26T062438Z_p4runtime_solution_ndtwin | 4359824 | 4346031 |
| 2026-09-26T155814Z_p4runtime_solution_ndtwin | 4359824 | 4346031 |
| **2026-09-26T175425Z_p4runtime_solution_ndtwin** | **4735073** | **4719873** |

多出約 375 kB ≈ 2.1 Mbit/s × 1.38 s；該臂 `netdev.after` 在 01:55:09.56 讀，與注入重疊約 1.3 s。worker 掃過 09-26 05:5xZ 以來所有 `*_ndtwin` run，只有這一臂有此等級跳動。orchestrator 01:5x 查 /proc：無殘留 iperf／mnexec。

## 影響

- 那一臂判定仍 PASS（5/5；注入的流量走同一路徑、只加在 on-path）。
- H5 的 `v_same_06` 只比 rc 與 verdict ⇒ **H5 的 PASS 不受影響**；ruling 4 取樣（1645 筆 forwarded_to_hosts 全 0）不受影響。
- **受污染的只有 `2026-09-26T175425Z_p4runtime_solution_ndtwin` 的 G1（link usage）數字（約 +8.6%）——不要當乾淨數據。** 同一臂另有三次乾淨讀數（上表）。

## 成因與處置

- 直接成因：worker 在 lab 有人跑的時候不經 guard、不帶 nolab 防護跑離線測試（brief 要求閘門經 guard；guard 本身也不擋 sudo——防護要另加）。
- 潛在缺陷：`test_live_p1_common.sh` 5e 在**任何** lab 在跑的機器上都會打進真主機（CI 沒 lab 所以看不到）。⇒ 另開修正：不可能存在的主機名（如 `zz1..zz3`）或 stub `sudo`／`iperf`，並加一個「測試中 sudo 被呼叫就紅」的守門。
- worker 已在之後所有閘門的 PATH 前放 `sudo`（記錄並拒絕）與 `curl`（拒絕 :8000/:8081）shim，tripwire log 為最後一個閘門。
