# run-01（sonnet）— 對帳（預測、已知缺陷、修在哪裡）

## 1. 對 README 的三條 R12 預測

| 預測（09-02 12:5x 先寫） | 結果 |
|---|---|
| **P1** sonnet 能走完 Installation Manual §1–§6；真正的摩擦落在 User Manual | **成立**。§1–5 合計約 20 分鐘、friction 0–1（唯一的 1 是 `conda init` 在非互動 ssh 下的假象）；§6 「the single smoothest stretch」。11 個 bug 裡 9 個在 User Manual／工具側，另 2 個（BUG-001／002）是 §2.6 的文字對不上檔案——那是「照做也不影響結果」的漂移，不是阻擋 |
| **P2** 若反而卡在 Installation Manual ⇒ 那個結論比任何單一缺陷值錢 | **未觸發** |
| **P3** haiku 會在 opus 不卡的地方卡住 | **還不能檢驗**（要 run-02／run-03） |

P1 裡我寫的具體摩擦點對帳：
- 「`ndt up` 要 `NDT_OWNER`」——**機制猜錯**。`ndt up` 死於 `ndtwin-lab` 沒裝（BUG-003）與 fabric 起不來（BUG-004），`NDT_OWNER` 只在 `claim` 用到，tester 根本沒碰到。
- 「四個 app 要 JDK／NFS／root」——**半對**：JDK 21 沒給安裝指令（H2，friction 1）；NFS 步驟照手冊做就過（I3／I4）。
- 「`mn -c` 會殺 `ryu-manager`」——**對**，但手冊已寫（A20：tester 先被咬一次、再照手冊確認一次）。

## 2. 已知 vs 新

| BUG | 狀態 | 出處 |
|---|---|---|
| BUG-011 假 CPU% | **已知** | `doc/KNOWN-ISSUES.md` F-1；記憶 index/04「MININET 下交換機 CPU% 是假的」。新角度：手冊零揭露 |
| BUG-005 `ndt apps` 假 ok | 新（KNOWN-ISSUES 1268–1317 記的是 `ndt apps stop` 的優雅停止，不是 start 的假成功） | — |
| 其餘 9 個＋130≠131 | **新** | — |
| M-1（手冊用 `~/Desktop` 卻不建） | **已修得對**：seed 沒預建 Desktop，tester 照手冊 4.1 的 `mkdir -p ~/Desktop` 走過去，零摩擦 | 06:17Z clone 成功 |
| 09-02 早上的 §6.1 修正（`cd ~`、ryu-env 紅字） | **已修得對**：tester 做過 `conda init` 仍建出 3.12 的 venv、七棵樹全在 `$HOME` | #4 |

## 3. 文件缺陷 vs 程式缺陷，修在哪裡

| 要修的 | 是什麼 | 在哪個 repo／頁 |
|---|---|---|
| §2.6 三條參數指示對不上檔案（BUG-001／002） | 文件漂移 | Website · Installation Manual · Native-Linux §2.6 |
| NTG 的 venv 要 `--system-site-packages`（BUG-008） | 文件缺一個旗標 | Website · Installation Manual · NTG 段 |
| Visualizer 沒給 JDK 21 安裝指令（H2） | 文件缺一行 | Website · User Manual · Visualizer 頁 |
| `ndt` 之外還要裝 `ndtwin-lab`（BUG-003） | 文件缺步驟（或工具該自己找同目錄的檔） | Website · User Manual · Native-Linux 第 28 行附近；或 `tools/test_workflow/ndt` |
| NTG 啟動指令的 conda 路徑（BUG-007） | 兩本手冊互相矛盾 | Website · User Manual · NTG 頁 138、263 行 |
| 131／129／130（#18） | 文件數字不一致 | Website · User Manual · Native-Linux 112–119 行；先重量 |
| P4 關機檢查不看 kernel（BUG-010 站得住的部分） | 文件缺一項檢查 | Website · User Manual · P4 段 Safe Shutdown |
| CPU%／Memory% 在 Mininet 模式是常數（BUG-011） | 文件零揭露（碼是 F-1，已知） | Website · Web GUI 頁＋Visualizer 頁；碼在 KNOWN-ISSUES F-1 |
| `ndt apps sim`／`energy` 假成功（BUG-005） | **程式**：`ndt:1928-1929` 不做存活檢查 | NDTwin-Kernel `tools/test_workflow/ndt`（比照 `app_spawn`） |
| `ndt up` fabric 起不來（BUG-004） | **程式**（機制未明） | NDTwin-Kernel `tools/test_workflow/ndt`＋`ndtwin-lab`；要進 root tmux 看 pane 才知道 |
| Web-GUI Dockerfile 釘 pnpm（BUG-009） | **程式** | Web-GUI repo `Dockerfile:11`（`server/Dockerfile:6` 同病） |
| NSR stop 腳本 `pgrep -f`（BUG-006） | **程式** | Network-State-Recorder repo |
| `ndt --help` 一大片沒文件（#19） | 文件 | Website · User Manual |

## 4. 這一輪之後、下一輪之前，手冊動不動？

**不動 User Manual；run-02（haiku）沿用同一份 docs 快照 `bcf98f5`。** 理由：campaign 的第二個變數是模型，P3 要問的是「haiku 卡在哪裡而 sonnet 不卡」——若先把 run-01 抓到的洞都補上，run-02 只能告訴我們「補完之後 haiku 過不過」，答不了 P3。修正排在 run-02 之後（或 Adam 裁定要先修）。Installation Manual 在 09-02 14:0x 多了 `516d6d9`（只改 §6.1 計時數字與版本資料點），nslab 那份 clone 未更新，run-02 拿到的仍是 `bcf98f5`。

## 5. 對 campaign 方法的修正

- tester 模板禁用 Browser 工具（`3b09e75c`）；WebGUI 純視覺功能這一輪留下 6 條 NOT-TRIED，**要有人親眼看**（Adam 或帶真瀏覽器的一輪）。
- tester 的自我工時帳不可信（報告與 journal 自相矛盾），以 journal 的分段時間為準。
- tester 的 BUG 敘述可能把兩個 log 混在一起（BUG-010）；每個「log 顯示 X」都要回 raw 檔驗。

## 6. auditor（9/1）裁定（09-02 19:2x–19:4x，親讀 trunk 後）

| 項 | 裁定 |
|---|---|
| ⑤④③＋`cleanup` | 進 KNOWN-ISSUES §G（auditor 併入下一波 diff，出處引本檔 §3） |
| ⑥ NSR `pgrep -f`、⑨ Web-GUI pnpm | 回各 repo owner |
| ①②⑦⑧＋131 | 純文件；**等 run-02 結束再修** |
| BUG-010 降級 | 同意（站得住的只有「wrapper 收 SIGINT 後 kernel 沒死」＋手冊 P4 關機檢查缺 :8000） |
| run-02 沿用 `bcf98f5` | 同意（③ 那道牆本身是 P3 的資訊：haiku 找不找得到 workaround） |
| 推送 | auditor 的整合分支合進 trunk 後一次推 lab／p4；本線不推 |
| 補驗（§7） | 排在 run-02 stop 之後；**這台今天被 systemd-oomd 殺了四次（含 Adam 的 app 一次）**，不准壓到 4 GB |

**④ 的機制（本線讀碼）與修法（auditor 修正）**：`tools/test_workflow/ndtwin-lab:26-31` 寫死 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`、
`NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python`、`ENERGY_DIR`／`SIM_DIR=/home/adam/…`；`ovs-topo-start`（143-144）跑
`/home/adam/Network-Traffic-Generator/testbed_topo.py`；`topo-start`（99-100）跑 `$NTG_PY $BRIDGE`。使用者叫 `ndt` 時全部不存在 ⇒ root tmux pane 秒死、
`ndt` 等 300 s 報 `fabric has 0 hosts`（tester 記的 06:54→06:59）。**修法不是 source `components.env`**：檔頭明寫「KERNEL_DIR IS HARDCODED, AND
DELIBERATELY NOT OVERRIDABLE」（08-30 FINDING-01：env 覆寫曾讓 `ndt`／`stack.sh` 與這支腳本各讀不同樹）⇒ 修法＝**安裝時期設定檔**（例如
`/etc/ndtwin-lab.conf`，沒設定檔就明確 die 並印缺哪一項），維持「不吃呼叫端 env」。
**③ 的根**：sudoers 放行的是 `/usr/local/sbin/ndtwin-lab`（root 擁有、與 repo 副本 byte-identical）——repo 改了要重裝才生效；手冊的安裝步驟必須含這一步。
**⑤ 的機制**：`sim-start`／`energy-start`＝`tmux new-session -d -s X -c "$DIR" ./binary; echo started`，秒死也 rc 0，`ndt:1928-1929` 只看 rc；修法比照 `nsr` 的 `app_spawn`，排在整合合併之後。
**另列**：`ndtwin-lab cleanup:132-136` 四個 `pkill -f`（含 `simple_switch_grpc`）——與 KNOWN-ISSUES 1488（`mn -c` 內部的 `pkill -9 -f`）不同，另列 §G；修法候選＝tmux session／pid 檔定向殺。

## 7. 補驗（auditor 第 4 點）

帳本 A-7 / run-01 補驗（`c48789cd`）；腳本 `orchestrator-scripts/av_{a,b,c}_*.sh`（`74d068d5`）；預測先寫（(a) pane 最後一行 `No such file or directory`；
(b) sudo 轉送 SIGINT、kernel ~5 s 退出；(c) sim／energy 再假 ok、nsr 誠實）。執行窗＝run-02 stop 之後。raw 落 `auditor-verification/`。

