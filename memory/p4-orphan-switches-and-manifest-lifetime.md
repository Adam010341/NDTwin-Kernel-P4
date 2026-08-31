---
name: p4-orphan-switches-and-manifest-lifetime
description: helper 開回來的 bmv2 活過 mininet exit 和 sudo mn -c；而 manifest 在 teardown 時被刪掉，於是 helper 再也定址不到那台 orphan
metadata:
  node_type: memory
  type: project
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-27T13:56:14.033Z
---

2026-08-12 實測，兩件事疊在一起變成一個真缺口。Phase 7 的殘留項。

## 一、helper 開回來的 switch 是 orphan

`ndtwin-p4-power on <name>` 用 **`setsid` spawn**，所以那個 `simple_switch_grpc`
**不是 Mininet 的子程序**。實測：

- `mininet> exit` 帶不走它
- **`sudo mn -c` 也帶不走它**（實測確認過——Adam 跑完 `mn -c` 之後它還在）

它會一直佔著自己的 gRPC port。下次跑 topo script 時，那台 switch 會因為
「something is already listening on gRPC port」被 helper 拒絕——helper 有這道守衛，
所以不會無聲疊第二個 listener，但你會看到一台起不來。

## 二、manifest 在 teardown 時被刪掉

`/tmp/ndtwin_p4_switches.json` 在 Mininet 收掉之後**就不存在了**。而 helper
**只靠 manifest 定址**（設計決定 1：helper 是 manifest 唯一擁有者，kernel 不碰 PID）。
所以：

```
sudo -n /usr/local/sbin/ndtwin-p4-power off s6
→ cannot open manifest /tmp/ndtwin_p4_switches.json: [Errno 2]   exit 1
```

**唯一被認可的關機途徑，對它自己製造出來的 orphan 失效。** 只能 `sudo kill <pid>`，
而那正是整個 helper 設計要避免的手動殺 PID。

## 怎麼收尾（下次一定要做）

live 輪結束後，`stack.sh down` **之外**還要：

```bash
pgrep -ax simple_switch_g    # 注意：-x 比對截斷後的 comm，不是 simple_switch_grpc
```

有殘留就 `sudo kill <pid>`（root 起的，adam 殺不動）。
2026-08-12 那一輪就是漏了這步，留下 s6 佔著 `:50056`。

## 2026-08-13 深夜收尾：抓到活例＋事前偵測法

收尾時親代掃描抓到現行犯：**s10（pid 180154）的 ppid 是 `systemd --user`（4551）**、
etime 比 topo 家族九台短 1.5h——就是白天被 helper 重啟過的那台，原親代退出後被 reparent。
**預測（未驗，依上面 08-12 的 s6 實測模式）**：`sudo mn -c` 收不走它，要再 `sudo kill 180154`。
已寫進當時的收尾待辦，交 Adam 執行（該節現在在 repo
`doc/audit/2026-08_session-handoff-log.md`，2026-08-21 移出記憶）。

**事前偵測法（Mininet 還活著就能跑，不用等 mn -c 之後才發現）**：
`ps -o pid,ppid,etime,cmd --no-headers -C simple_switch_grpc`，
找 ppid 不在 topo 家族、etime 偏短的離群者。

> ⚠️ **2026-08-13 後續：pid 180154 那個具體預測沒能驗成。** 下一個 session 開頭
> `pgrep -cx`/`-ax simple_switch_g` 都回 0——s10 orphan 已不在，但**無法判定是 `mn -c`
> 這次真的收走、還是 Adam 之前手動 `sudo kill` 了它**（兩者我都沒觀察到）。所以「orphan
> 活過 mn -c」這條**在 08-12 的 s6 有實測、在 08-13 的 s10 沒驗成**——機制本身（下方 §一）
> 的 08-12 證據仍然成立，但別再把 s10/180154 當已驗證的實例引用。之後 Adam 又重開 Mininet
> 跑 live 輪，pid 全換過，這個具體編號徹底作廢。

## ✅ 2026-08-14：teardown 那一半修掉了（`b9a5bea`），而且我的風險描述被更正

**Adam 反問「為什麼不直接修會產生孤兒的問題」,逼出比我原本三個選項都好的答案。**

**孤兒本身不是 bug,是功能**:`tools/p4_power_helper.py:287` 用 `start_new_session=True`
(＝setsid)開 switch,**必要**——helper 是 sudo 叫起來的短命行程,不 detach 的話 switch 會跟著
helper 一起死,`power on` 就沒有意義。所以「不產生孤兒」＝「不能開機」,這條路是死的。

**真正的缺陷是 teardown 只刪登記檔、不收登記檔裡列的機器。** 已修:
`reap_manifest_switches()` 在 `os.remove(MANIFEST_PATH)` 之前照 manifest 收掉還活著的 switch。
殺之前先讀 `/proc/<pid>/cmdline` 確認真的是 bmv2(teardown 是 root 在跑,pid 會被回收,
光憑 pid 殺遲早殺到無關行程)。SIGTERM → 共用一個 settle 窗 → 還活著才 SIGKILL。永不拋例外。
12 條新測試(`test_readopt.py` 35→47)、**mutation 6/6 全殺(實測)**。

> 🔴 **更正我自己在 grill Adam 時說錯的話**:我把這條標成「有 demo 風險——孤兒佔著 port,
> 下次起拓撲那台會起不來」。**在現在的程式碼這不成立。** `p4_testbed_topo.py` 的 `main()`
> 啟動時就跑 `sudo pkill -f simple_switch_grpc`,而且旁邊的註解正好記載了我描述的那個故障
> (「That is a real failure we hit」)並說明那行就是它的修法。上面第一節那段
> 「下次跑 topo script 那台會起不來」是**歷史狀態**,啟動掃描補上之後就過期了。
> 所以這修的是**衛生**(十個 idle bmv2 不該活過擁有它們的拓撲)不是風險緩解。
> **教訓同 [[cited-line-numbers-are-not-evidence]]:斷言風險之前先讀啟動路徑有沒有已經處理掉。**

**仍未修的另一半**:helper 在「pid 已死」路徑回 `already-stopped` + exit 0,沒去看 gRPC port
有沒有人在聽(＝**寫錯的 manifest**)。這條沒動,等 Adam。

> **觸發條件與修法**(2026-08-27 從已退休的 `phase7-state-2026-08-11` 併入,原始 08-12 實測):
> **manifest 只在 topo 啟動時寫一次。** bmv2 因任何原因重啟之後,manifest 就**無聲過期**
> ——裡面的 pid 指向一個已經不存在的行程,而 helper 只看 pid。
> **該做的是順便看 gRPC port 有沒有人在聽**:有人在聽就代表 manifest 過期而且有東西正在服務,
> 這時候要**大聲失敗**,不是回 `already-stopped` + exit 0。
> 🔑 這是 [[failures-that-report-success]] 的正典形狀——**「查不到」被當成「已經是目標狀態」**,
> 而兩者在 exit code 上長得一模一樣。設計文件在
> `doc/2026-08-11_phase7_power_mechanism_design.md`。

## 這跟原本記的「manifest 過期偵測」是同一族但更嚴重

原本記的是：helper 在「pid 已死」路徑回 `already-stopped` + exit 0，沒去看 gRPC port
有沒有人在聽。那是**寫錯的 manifest**；這條是**沒有 manifest**。兩條都還沒修，等 Adam 決定。

相關：[[failures-that-report-success]]、[[process-liveness-checks-lie-in-two-ways]]（`pgrep` 的
15 字元陷阱就在這裡會咬人）、[[agent-can-do-live-tests-except-start-mininet]]。
Phase 7 的設計與驗收全文在 `doc/2026-08-11_phase7_power_mechanism_design.md`
（記憶檔 `phase7-state-2026-08-11` 已於 2026-08-27 退休，內容併入本檔）。
