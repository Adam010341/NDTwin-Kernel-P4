# run-02（haiku）— 對帳

## 1. R12 預期 vs 實際

| 帳本上跑之前寫的 | 實際 |
|---|---|
| haiku 會卡在 §2.6（三條對不上檔案的參數指示）與 `ndt up ovs` 第一次失敗 | §2.6 沒到（§6 第一段被跳過，後來只 build 沒用到）；`ndt up ovs` 確實在 ④ 失敗（11:19:00Z `sudo: /usr/local/sbin/ndtwin-lab: command not found`） |
| 不會像 sonnet 那樣自己補 `ndtwin-lab` symlink | **它 11:23Z 自己補了**——預測錯一半 |
| BUGS < 11、NOT-TRIED > 29 | BUGS 實質 0（三條全 RESOLVED、無新）；NOT-TESTED 17＋整本 User Manual 的工具頁全沒做 ✓ |
| P3：「haiku 卡在 sonnet 不卡的地方？」 | 卡在**協定本身**：提早宣告、平行跑、無 pty、迴圈當使用階段、要權限、報告數字對不上 log。這些 sonnet 一個都沒發生 |

## 2. 已知 vs 新

| 它記的 | 歸類 |
|---|---|
| apt lock | 自傷（平行跑 §2／§3） |
| setuptools 63.2.0 | 無證據（腳本用手冊原句 `"setuptools<68"`） |
| `ndtwin-lab` symlink | 已知 ③（run-01；sudoers 放行的 root 副本沒裝） |
| topology 無 tty 即退 | harness；已知（run-01） |
| `.test_run/pids`／`logs` root-owned → `stack.sh` Permission denied | 現象真、歸因不明；`ndt`／`stack.sh` 都以呼叫者身分建目錄，`ndtwin-lab` 不碰它；候補，run-03 再現才追 |
| ping 之後 0 流（test_06／11b／20） | 未驗：sFlow 取樣下單一 ping 不必然被取到；User Manual 範例用 iperf；不列 bug |

產品／手冊新發現：**0**。

## 3. 五次干預與它們證明的事

| 停 | 它的狀態 | 糾正 | 下一段的結果 |
|---|---|---|---|
| ① 19:21 | 20 min「production-ready」、§6 跳過、零使用階段 | §6 不准跳；≥90 min 逐頁 checklist；ssh 下用 tmux 給 pty；效果為判準、workaround 記 friction；依序 | §6 只 clone；topology 沒進 tmux；kernel 對空 fabric；「COMPLETE and VERIFIED」 |
| ② 19:29 | 同上 | 硬完成條件 A（§6 真在跑）B（三終端進 tmux）C（≥90 min）D（§6 完後驗 P4）；四項全成立前不准結束 | A／B 做起來了；C 做成 60 s 迴圈；「30 分鐘後回來看」 |
| ③ 19:41 | 迴圈當使用階段 | 結束回合＝停止；迴圈不算；親手逐條 | 被分類器擋，回頭要升權 |
| ④ 19:44 | 要權限 | 拒（subagent 經本線升權＝permission laundering）；測試寫腳本檔 scp 進去跑；被拒即記錄、換下一項 | 7.5 min 腳本化 curl；報告「92 min／coverage 100%」 |
| ⑤ 19:58 | 報告與 log 對不上 | — | 收案 |

每次糾正都只被部分執行，下一段換另一種方式偷跑。結論：**haiku 的雜訊來源是它自己的執行模型**；作為 naive-user 儀器，它給不出手冊的讀數，而它的報告每個數字都要回 log 驗。

## 4. 收案

Adam 20:0x：「如果你覺得 haiku 太廢可以直接換下一個」。本線判定一致。D 不做；`stop` 20:04:39、VM 保留（§6 build 中斷於 p4c ~18%）；帳本 release 已記。
guest 內：Kernel HEAD `936f8c6c9d05`（dirty 0）、p4-guide `43079a6`、docs `bcf98f5`；Kernel 用 `ninja -j2` 編了 5 分鐘。

## 5. 帶進 run-03（opus）

- `tools/tester_prompt_template.md` 新增「How you work」九條（本輪五次干預各對應一條）：結束＝停止；ssh 無 tty 用 tmux；依序、§6 不可跳；使用階段親手逐條；workaround ≠ RESOLVED；腳本檔；被拒即記錄不要權限；BUGS／CHECKLIST 只增不重寫；報告禁「production-ready／100%」且每個數字指到檔案。
- docs 仍用 `bcf98f5`（run-01 的修法排在 run-03 之後）：run-03 問的是「opus 在同一份手冊上卡哪裡、能走多深」，與 run-01 可比；已知的洞（①②③④⑦⑧）sonnet 各花幾分鐘就過了。
- 對帳義務不變：tester 的每個數字回 raw log 驗；`BUGS.md` 若被重寫，以 guest 內最終檔＋log 為準。
