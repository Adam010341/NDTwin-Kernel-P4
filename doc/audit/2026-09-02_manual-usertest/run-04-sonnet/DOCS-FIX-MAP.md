# run-04 的手冊快照：run-03 的每一條缺陷，修了還是沒修，為什麼

實驗設計：**模型固定（sonnet，與 run-01 同）、手冊變動 ⇒ 差異可歸因。**
所以每一筆非必要的編輯都是在同一次比較裡多塞一個自變數。門檻（auditor 09-02 23:2x 裁）：
**只修硬錯**（指令錯／路徑錯／步驟缺漏／順序錯／前置條件沒講），**措辭一律不動**，
**每一筆要對到一個 run-03 的 BUG 編號**，**不准把 tester 自己發明的 workaround 寫進手冊**。

- run-03 用的 docs：website `bcf98f5`（2026-09-02 11:26）
- run-04 用的 docs：`d5259f0` ＋ 下表三筆 ⇒ **凍結 sha 見本檔末尾**
- run-03 正本：`../run-03-opus/`（`VERIFICATION.md` 38 條逐條複驗、`RECONCILIATION.md` 對帳）

## 今晚改的（三筆，全部在 §1–§6 ＋ bring-up 主線上）

| run-03 | 硬錯的種類 | 改了什麼 | 佐證 |
|---|---|---|---|
| **#3** | **步驟缺漏** | `ln -sf … ~/.local/bin/ndt` 之前補 `mkdir -p ~/.local/bin`；並註明 Ubuntu 內建 `~/.profile` 是**登入時**才判斷該目錄存不存在，所以要開新的 login shell | `ln: failed to create symbolic link '/home/ndt/.local/bin/ndt': No such file or directory`；`~/.local` 的 birth time 等於 tester 第一次 `mkdir` 的那一秒 |
| **#12** | **數字錯，且與自己的敘述矛盾** | 收斂停止條件 `131 per switch` → **130**，並把組成寫清楚（128 條目的地規則＋1 條 LLDP＋1 條 table-miss）。原本的敘述「one per destination host, plus its table-miss entry」算出來是 129，印出來是 131，機器是 130 —— 三個數字互不相同 | 十台交換機各 130，十秒內兩輪＋五分鐘後再一輪皆同；Ryu 自己的 `install_all_pair_paths done: … rules=1280`，1280/10＝128 |
| **§6.1** | **前置條件沒講**（auditor 09-02 23:3x 批准） | 補上預估耗時（4 vCPU／6 GB 實測 **7640 s＝2 h 07 m**）與 **detached 跑法**（`tmux new-session -d`）＋回收方法；並明寫 `SCRIPT_EXIT=0` 不是驗收、驗收是 Step 6.2 的兩條 `--version`。加在 `conda deactivate` 檢查**之後**，順序沒有被弄反 | `run-03-opus/tester-files/logs/06a_p4.log`：`Total time : 7640 sec`、`SCRIPT_EXIT=0`；tester 22:08 死時 build 未完，23:01:22 才自己跑完 |

## 故意沒改的，以及理由

| run-03 | 為什麼不改 |
|---|---|
| **#1**（§2.6 三個 knob 與實檔不符） | **已經修好了**——`c60c70f` 已在 `d5259f0` 裡，三個 knob（`NDTWIN_RYU_TOPO_FILE` 覆寫、`is_mininet` 只能讀、`switch_num` 是推導的）都改對。run-03 撞到它是因為 guest 拿的是 `bcf98f5` |
| NTG 的 catch-22（venv 少 `--system-site-packages`、User Manual 指向不存在的 conda 路徑） | **已經修好了**——`062d8eb`（20:48:30）與 `df614ce`（20:50:18）都在 `d5259f0` 裡。時序值得記：這兩個修法是在 run-03 的 VM 開機（20:30:35）之後 18 分鐘才落地的 |
| **#21 #22**（`ndt up ovs` 與 `ndtwin-lab` 的假成功） | **auditor 指示今晚不動**。G-7 由另一個 session 在 `fix/g7-ndtwin-lab-config` 上處理，範圍只到 repo 內版本支援安裝期設定檔；已安裝的 `/usr/local/sbin/ndtwin-lab` 與 sudoers 是提權路徑，夜裡無人在旁不碰。Known-limitation 段落（含三終端程序）維持原樣 |
| **#9 #10 #13**（trunk 已修卻完整重現） | **不是手冊能修的**。安裝手冊叫人 `git clone https://github.com/ndtwin-lab/NDTwin-Kernel`，而那個公開快照停在 `20cd80b`（08-28），比 `c46c51eb`／`4ee086f8`／`65c5cdb1` 三個修法都舊。修法＝更新公開快照＝推公開 repo，**超出我的授權**（見早上要問 Adam 的清單）。#10 尤其尖銳：API 頁把修法寫成帶日期的既成事實，而讀者拿得到的 build 裡沒有它 |
| **#2**（SIM_SERVER_URL 埠不一致）、**#11**（flow entry 回應體與實際不符） | 都是真的硬錯，但**不在 §1–§6 ＋ bring-up 的路徑上**（一個在 Simulation Platform 頁、一個在 API 頁），不影響本輪判準。為了讓 run-01↔run-04 的差異指向修的那三條，這兩條留到下一輪一起修 |
| **#16**（runtime API 弄髒 git checkout，手冊沒警告） | 補警語屬於**新增說明**，不是硬錯——照做不會失敗 |
| **#18**（NSR 的 `logs/` 不存在，手冊的監看指令不能用） | 修法會變成把 tester 的 `mkdir` workaround 寫進手冊 ⇒ **禁止**。正規修法在 NSR 那支腳本裡 |
| **#4 #5 #6 #7 #8 #14 #17 #20** ＋ 本線補立的 NTG 毒化案 | **程式／腳本缺陷，不是手冊錯**。歸 KNOWN-ISSUES 與 fix-design 那條線 |
| **#15 #19** | 正面紀錄，不是缺陷 |

## 早上要問 Adam 的

1. **判準要不要允許 §6 以背景完成？** §6.1 要 2 h 07 m。一個有 session 限額的 tester 幾乎不可能在「一次通關」裡用前景撐完它。若不調整，量到的是限額不是手冊。（auditor 不改 Adam 親定的判準，列進清單。）
2. **公開快照 `20cd80b`（08-28）要不要更新？** 不更新的話，#9／#10／#13 這三條已修缺陷每一輪都會重現，naive-user 測試永遠測不到修好的碼。這需要推公開 repo，我不做。

## 凍結

