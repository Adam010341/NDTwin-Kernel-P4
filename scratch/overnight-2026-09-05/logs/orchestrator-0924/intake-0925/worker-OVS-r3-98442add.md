DELIVERED 98442add6ed344a4e60c4346147f35c120a31e06

第三輪做完了：新 head 是 `98442add`，SUMMARY 已更新。判官 r2 的 blocking #1 和你點名的 #3、#4、#5、#7 都處理了。只重跑了這輪碰到的閘門，只有一格紅：它是機器上的 helper 被換掉造成的，不是這輪的 diff（見下）。

**這輪改了什麼**（先 commit 測試：`c6868f7e` 在上一版 ndt 上紅 5/166）
- **#1**：
  - 新的 `status --check` rc 1 寫進了 `ndt help` 的 status 段和手冊，限定詞是「有 baseline 時 rc 1，沒有時仍是 3」。手冊另外提醒，上面 P4 那條「`ndt status --check` 回 rc=0 才算過」碰到這個情況會變成 1。
  - 新測試格：有 baseline 時，回收號碼的 `kernel.pid` ⇒ rc 1，problem 清單點名它；對照組 ⇒ rc 0；沒有 baseline ⇒ 3。
  - 這格在上一版 ndt 上本來就綠（rc 靠既有接線成立），但在 base `62f76cf5` 上是紅的（實際 0、預期 1），所以它釘住的就是這個 rc 變更。變異 M36、M37 都抓到。
  - SUMMARY §2 那一列補上了限定詞。
- **#5**：手冊改成程式實際的判定順序——號碼被回收時直接判 stale，不問 group。
- **#3**：`down` 刪掉 kernel／p4_proxy／ryu 的回收號碼 pidfile 時，訊息多一句 `stack.sh kept it above because the number is somebody else's`。變異 M38。
- **#4**：window 寫不進去時，錯誤訊息多一行救法：把 `.test_run/apps` 改成可寫的目錄，再跑一次 `ndt down`。變異 M39。
- **#7**：變異閘門 log 的標頭改成跑的時候從腳本數出來，現在寫「39 named mutants, 3 controls」。
- **#2 沒動**，stack.sh 也沒碰。SUMMARY §5 已知限制加了一行，指向「ticket to be opened by the orchestrator」。

**閘門結果**（`98442add`，全部經 guard，`JOBS=1`）

| 閘門 | 結果 |
|---|---|
| 新測試 | 166 格，0 紅 |
| 變異閘門 | 39 個變異，0 存活；3 個對照都綠 |
| 手冊 rc 表的變異閘門 | 10 個變異，0 存活 |
| 手冊 no-stale 的變異閘門 | 16 個變異，0 存活 |
| gate-anchor checker | 117/117 |
| 靜態檢查 | 0 |
| `serve_evidence` | 和 ndt serve 分支合併無衝突、錨點全對、help 原句全在 |
| 所有會碰 ndt 的 shell 測試 | **1 支紅：`test_ndt_helper_apps_window.sh`，150 格紅 1 格** |

**那 1 格紅不是這輪的 diff**：
- 紅的那格拿機器上已安裝的 `/usr/local/sbin/ndtwin-lab` 跟這棵樹的副本比 sha256。
- 已安裝的那份在 19:34:12 被換成 trunk 的版本（heartbeat 分支 `f139c800` 改的）。不是我換的，我沒有 sudo。
- 這個分支的副本從 base 起一行都沒改。同一支測試在 e1420df2 那次跑（18:20，換檔之前）是綠的；把 e1420df2 的樹匯出來現在重跑，同一格照樣紅。
- 取證在 `helper_env_evidence.ndtovs-98442add.log`。併進 trunk 之後，兩份就會一樣。

**轉告 ndt serve**：`registry_clear_stale` 的改動讓 status／apps 的錨點又移了 13 行。`verbs.RC_SOURCE` 8 行的新舊行號對照表已在 `98442add` 重算並驗過，放在 SUMMARY §2，證據是 `serve_evidence.ndtovs-98442add.log`。

SUMMARY：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/NDT-OVS-SUMMARY.md`

Log 都在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`：
- 這輪的閘門：`*.ndtovs-98442add.log`
- 紅燈先行：`test_ndt_ovs_claim.red-first.ndtovs-c6868f7e.log`
- 對 base 跑的那份：`test_ndt_ovs_claim.base-62f76cf5.ndtovs-c6868f7e.log`
