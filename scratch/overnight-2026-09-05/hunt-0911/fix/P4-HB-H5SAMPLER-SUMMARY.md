# SUMMARY：08 的 H5 sampler 從沒跑起來（live H5 on cafd518a），以及內嵌程式的全面盤點

- **分支**：`fix/08-h5-sampler-0926`，從 trunk `cafd518a` 開出（ndt-serve 錨點的修正當時還沒 merge）。
- **Worktree**：`scratch/overnight-2026-09-05/wt-08-h5-sampler-0926`。
- **Head**：`f4f43a3264a1dacc8c5a12e002204e5a08866fca`，共 4 個 commit。
- 沒 push、沒 merge、沒碰 lab 也沒碰主 checkout、沒 sudo、沒跑任何 `ndt`。

[Co-developed with claude code -- Adam]

## 1. 缺陷與修法

**缺陷（OBSERVED，離線重現）**

- `SAMPLER_PY` 裡有 `f"…{d.get(\"status\")}…"`。f-string 的運算式裡出現反斜線，在任何 Python 版本都是 SyntaxError（這台是 3.13）。
- `sampler_start` 把 stderr 丟進 /dev/null，而且從不確認 sampler 還活著；sampler 在編譯時就死了。
- 自測從來沒有執行過這段程式。

**red first：`c6c49215`**

- 新的 `st_sampler` 直接用本腳本自己的 `SAMPLER_PY`，走真的 `sampler_start`／`sampler_stop`。
- 對一份假報告做原子重寫，依序模擬 daemon 的狀態：缺檔 → running → 計數變動 → stopped（最終計數 2/3）→ 再缺檔 → 第二個 session。
- 斷言：
  - header 正確；
  - 每次讀取寫一列 6 欄，而且順序正確；
  - 停止時會再取一次樣；
  - stopped 那一列的計數會走到 ruling-4 的判定，並得到 STOP；
  - 起不來的 sampler 必須讓 `sampler_start` 失敗，並保留它的 stderr。
- 在 cafd518a 的程式上 SELF-TEST FAIL，4 紅，第一條是 `header '', rows ''`——就是 live 的缺陷本身。

**修正：`294fbd97`**

- `SAMPLER_PY` 改成 quoted heredoc：兩種引號都能用，bash 不會展開裡面任何東西。
- 每一列由普通值 join 而成，沒有任何 f-string 在運算式裡放引號，所以不依賴 Python 版本的特性。
- stderr 寫到 `$RUN/50_sampler.err`。
- `sampler_start` 最多等 5 s，要同時看到 header 和活著的 pid；否則就 `fail`，把 stderr 內容印出來，並回傳 1。
- H5 呼叫時用 `sampler_start … || exit 1`，所以在 06 起任何東西之前就會停下來。
- 讀取間隔是選填的第 4 個參數：H5 用 1.0 s，自測用 0.1 s。

**最終計數是否一定會記到**

- 看到 stop 檔之後，sampler 會**再讀一次**才退出，所以 daemon 最後那次 `stopped` 重寫一定在紀錄上，不論時序怎麼落。
- 這由一個刻意做成確定性的測試證明（`5f153382`）：讀取間隔 1 s，同一瞬間寫入 `stopped` 並呼叫 `sampler_stop`，必須記到 5/6。
- 在 H5 的實際流程裡，每個 session 的 `stopped` 報告會一直保留到下一臂的 `heartbeat start`，中間隔著數十秒，而 sampler 每 1 s 讀一次，所以不靠最後那次讀取也會記到。

**閘門：`f4f43a32`**

- L49：把 live 的缺陷放回去；
- L50：`sampler_start` 相信一個它沒看到的 sampler；
- L51：停止時不再多讀一次；
- L52：stderr 又回到 /dev/null；
- L53：`report_dirs` 把兩個方向對調；
- L54：`graph_until` 的 elapsed 倒著算。
- 每一個都有具名的 killer。
- 沒有自測涵蓋的：H5 裡的 `|| exit 1` 那一行本身在 live 路徑上，只能讀過。

## 2. 內嵌程式盤點（08、07、`_common.sh`、spike 腳本）

**方法：插標記，不用 LINENO**

- 一開始用 bash xtrace 的 LINENO 判斷哪些行被執行，但在函數裡的 `$( )` 中它會偏移約 20 行，得出的答案不可信，所以放棄。
- 改成 `embedded_cover.py`：在每一段內嵌程式的第一個敘述插一個標記，程式真的執行時就會建立 `$COV_DIR/<id>`。
- 標記的範圍：
  - Python：heredoc、`-c '…'`、`-c "…"`、存在變數裡的程式；
  - awk：單引號和雙引號的程式；
  - `jqp` 的運算式。
- 插好標記後跑這些自測：08、07、`test_live_p1_common.sh`、`test_live_p1_thirteen.sh`、spike 的 `--self-test`。檔案事後從 git 還原。
- 另外 `embedded_sweep.py --strict` 用 Python 3.13（系統的和 venv 的）編譯每一段字面程式，awk 則用 `mawk -W dump` 解析。

**結果（`embedded_compile`／`embedded_cover`／`runtime_check` 的 log，@f4f43a32）**

| 檔案 | 內嵌程式 | 被自測執行 | 沒有自測執行 | 編譯不過 |
|---|---|---|---|---|
| 08_heartbeat.sh | 31（標記 30） | **30** | 0（修正前是 2：`report_dirs`、`graph_until` 的 elapsed，現在已補測試） | 0（修正前 1：`SAMPLER_PY`） |
| 07_roles_basic.sh | 15 | 12 | 3 | 0 |
| _common.sh | 22 | 17 | 5 | 0 |
| S_heartbeat_spike.sh | 10（標記 9） | 8 | 1 | 0 |
| oldcode_selftest.sh | 1 | 0 | 1 | 0 |

- 五個檔共找到 79 段。其中 69 段是字面程式，都做了編譯，**沒有一段編譯不過**。
- 另外 10 段含 bash 展開，無法做靜態編譯（清單在 `embedded_compile` 的 log 裡）：
  - 其中 8 段直接被標記，而且都有自測執行到；
  - `-c "$SAMPLER_PY"` 執行的是 `SAMPLER_PY` 本文，那段以 py-var 的形式被標記，也有執行到。
- 第 10 段是 spike 自測假 tc 裡的一行 awk，解析器讀不出它的程式本體；讀碼判斷，它在自測的模擬 daemon 路徑上執行。

**沒有任何自測執行的 10 段（OBSERVED；每一段都用 `runtime_check` 在小輸入上跑過真實的文字，結果全部正確，沒有壞的）**

| 位置 | 程式 | 在哪裡跑 |
|---|---|---|
| 07:496、07:506 | `jqp` 讀 `complete`、`request_id` | L2 的 dispatch（live） |
| 07:549 | ENTRY_TABLES（python -c） | convert 之後的 live 頂層 |
| _common.sh:315 | `get_json` 的 python -c | 每一次 live 讀取 |
| _common.sh:701 | `netdev_tx`（讀 /proc/net/dev） | `link_usage_round`（05、06 live） |
| _common.sh:1160／1168／1169 | minor 清單、P／M 計數的 awk | `link_usage_round` |
| spike:200 | `consts`（匯入 proxy 的常數） | spike live 開頭 |
| oldcode_selftest.sh:67 | 這個工具本身的程式 | 執行 `oldcode_selftest.sh` 本身時（spike 自己的閘門） |

- 07、`_common.sh`、spike 這幾段都不在本 branch 的檔案範圍內，而且都沒壞，所以只列出來。
- 它們在 live 上都跑過：例如 06 的 26 臂，以及 H5 在 live 上的 06。
- `hb_watch.py`、`hb_sniff.py`、`census_prepare.py` 是獨立的 Python 檔，不是內嵌程式，各有自己的自測；不在這張表內。

## 3. 閘門（`logs/gates-0910/*.p4hbh5-f4f43a32.log`，全部經 guard `JOBS=1 LOCK_WAIT=10800`，`FINAL-GATES f4f43a32: ALL-AS-EXPECTED`）

| 閘門 | 結果 |
|---|---|
| `live08_selftest` | rc 0，`SELF-TEST PASS` |
| `live08_sampler_redfirst` | rc 0：在 `c6c49215` 上 FAIL，真的 sampler 什麼都沒寫；在 HEAD 上 PASS |
| `mutate_p4_heartbeat_w`（持有 08 的 L-mutant） | rc 0，**189 mutations、0 survived** |
| `check_gate_anchors` | rc 0，120/120 |
| `embedded_compile` | rc 0：79 段，0 段編譯不過 |
| `embedded_cover` | rc 0：上表，08 是 30/30 |
| `runtime_check` | rc 0：沒被執行的每一段都跑過而且答對 |

**沒重跑的**：`p4_proxy_suite`、ndt suites，以及其他 `mutate_*`——本 branch 只動了 08 和本段的閘門檔。

**三條 branch 的檔案互不重疊**（都從 cafd518a 開出，可以依任何順序 merge）：
- 本條：`08_heartbeat.sh`、`mutate_p4_heartbeat_w.sh`；
- `fix/07-heartbeat-links-0926`：`07_roles_basic.sh`、live-p1 `README.md`、`mutate_roles_binding.sh`；
- `fix/ndt-serve-anchors-0926`：`tools/ndt_serve/*`、`tests/python/test_ndt_serve*.py`、`mutate_ndt_serve.sh`。

**H5 的 ruling-4 逐臂檢查**（forwarded_to_hosts）目前仍未量測，要等你 merge 後重跑 H5。

DELIVERED f4f43a3264a1dacc8c5a12e002204e5a08866fca
