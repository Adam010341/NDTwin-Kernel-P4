---
name: py-spy-via-mnexec-under-ptrace-scope
description: 這台機器 ptrace_scope=1，py-spy 連同 uid 都不能 attach；用已授權的 mnexec 拿 uid 0 是繞法
metadata: 
  node_type: memory
  type: reference
  originSessionId: b393b3f5-119b-43a5-a384-025c6cb72e3a
  modified: 2026-08-13T09:06:02.689Z
---

想看 Python process 卡在哪一行時：`py-spy dump --pid <pid>` 會回
`Permission Denied`，**即使目標是自己的 process** —— `/proc/sys/kernel/yama/ptrace_scope` 是 `1`
（只允許 attach 自己的子孫），而 `sudo py-spy` 要密碼（NOPASSWD 只有
`ovs-vsctl` / `ifconfig` / `mnexec` / 三條 `tc`）。

繞法（與 [[ifconfig-down-breaks-whole-bmv2-switch]] 的 `kill -STOP` 同一招）：

```bash
sudo -n mnexec /home/adam/miniconda3/bin/py-spy dump --pid <pid>
```

`mnexec` 不帶 `-a` 就只是在當前 namespace 執行命令，但因為走 sudo 所以是 **uid 0**
（`sudo -n mnexec id` → `uid=0(root)`）。py-spy 在 `~/miniconda3/bin`，0.4.2 版，讀得懂
proxy venv 的 **Python 3.13**。

**為什麼值得記**：這是把「我讀程式碼推論出的機制」變成「直接證據」最快的一步。
2026-08-13 用它一次就推翻了 `W2-live-reverify.md` §6.2 記載的 head-of-line 機制——
stack dump 直接指名 event loop 卡在 `read_table_entries (p4_client.py:429)`，
而且同一份 dump 順帶證明 `liveness-probe` thread 全程健康、`AnyIO worker thread` 全程閒置
（兩件事各自否證了一個候選解釋）。**一次取樣同時給出「誰卡住」和「誰沒卡住」**，
比任何時間量測都強。見 [[investigation-briefs-separate-observation-from-inference]]、
[[arithmetic-that-fits-is-not-the-mechanism]]。
