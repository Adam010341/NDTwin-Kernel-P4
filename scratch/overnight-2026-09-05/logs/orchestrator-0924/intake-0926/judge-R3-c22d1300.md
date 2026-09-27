# judge-R3-c22d1300（fix/hb-followups-r3-0927 @c22d1300，base trunk b2eeb71d）

路徑縮寫（皆為絕對路徑）
- WT3 = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-followups-r3-0927
- LP = WT3/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
- MW = WT3/tests/shell/mutate_p4_heartbeat_w.sh
- G = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- S = G/scripts-p4hbr3-c22d1300-c
- S0 = G/scripts-p4hbr3-c22d1300

**範圍**
- 全程唯讀：沒執行任何東西、沒用 git。
- 讀了：R3 SUMMARY、delta patch、G 下全部 `*.p4hbr3-c22d1300.log`、三組 scripts、WT3 原始碼，以及 R2 SUMMARY 的 R-N3 改字。
- 【讀】＝親自讀到；【推】＝推論。

## 判決：**MERGE**
- **BLOCKING：無。**
- NOTE：R3-N1～R3-N7，全部不擋。

## Q1. R-N1：已解決

**ltree 把 knob 擋在 tree 外【讀】**
- `ltree`（MW:99-107）把 `p4_proxy` 建成一個真的目錄，裡面只連兩條 symlink：`proxy_agent` 和 `venv`。
- 所以 tree 裡根本沒有 `p4_proxy/mininet`。
- `_common.sh` 的三個 knob 都以 `$REPO` 為基準（:30、:31、:172）。在 tree 裡，`$REPO` 就是 tree 本身，因此：
  - `rm -f` 刪的是不存在的檔；
  - `cp -p` 因為目錄不存在而失敗；
  - 兩者都碰不到 checkout 的 knob。
- 08、`_common.sh`、`faults.sh`、`qdisc_snapshot.sh` 裡都沒有 `readlink -f`、`realpath`、`pwd -P`。
- mutant tree 用同一個 `ltree`（MW:1112）；baseline tree（MW:1138-1139）另外再做一次 leak check。
- 08 在這種 tree 裡的自測是 PASS（G/mutate_p4_heartbeat_w_c…log:10,164）。

**有沒有路徑經由那兩條 symlink 寫回 `$REPO`**
- `consts`（08:139-142）帶了 `PYTHONDONTWRITEBYTECODE=1`，所以不會寫 .pyc【讀】。
- 它 import 的模組在載入時都不寫檔【讀】。
- `sflow_emitter.py:604` 的 `REPO_ROOT` 用 `abspath`，是字面上的路徑運算，會解析回 tree，不會穿過 symlink 回到真正的 checkout【讀】。
- 剩下的唯一可能見 R3-N7；那只是 Python 的快取，不是 lab 狀態。

**對照組是真的對照組【讀】**
- 整棵 p4_proxy 被連進去的那棵對照 tree，至少要列出一個出口，否則 refuse（MW:123-126）。
- 探測用的 tree 則必須一個出口都沒有。
- 所以這個檢查兩個方向都會被驗到。
- red first 證據：在 c0cef392 上跑整支 gate 得到 rc 2，而且沒有執行任何 mutation；兩條出口都被點名（G/redfirst_r3…log:11-19）。
- 缺點見 R3-N5。

## Q2. R-N2：已解決

**live 路徑不再讀環境變數【讀】**
- poll 改成第 7 個參數（LP/07:378）。
- `l6_roles` 和 `l6_plain` 沒收到參數時用 `${1:-30}`（:390、:394）。
- live 流程呼叫這兩個函數時不帶參數（:827、:918）。
- grep 結果：`L1_POLL_S` 和 `SELFTEST_L1_POLL_S` 只出現在測試本身的 export（:613）和 L7-28 的 mutant 文字裡。
- 另外 gate 腳本也 unset 了這兩個變數（S/gates_r3c.sh:28）。

**`st_l6_inherited` 有鑑別力【讀】**
- 在 a435d24e 上，正好只有這一格紅：`judged 3 polls 2`（G/redfirst_r3…log:24-27）。
- 在 HEAD 上是 `judged 0 polls 4`（:29）。
- L7-28 和 L7-29 都被抓到（G/mutate_roles_binding_c…log:607-608）。

**6.5 s 不是會 flaky 的餘裕【推】**
- 正確版本的 deadline 是 30 s，所以「還沒有任何判定」一定成立。
- 「至少讀兩次」只要求第二次讀取在約 2.5 s 內開始、6.5 s 內完成。
- 如果機器極度繁忙，最壞只會讓 mutant 被誤判成存活；這會很顯眼，不會讓錯誤悄悄通過。
- 缺點見 R3-N3、R3-N4。

## Q3. redfirst_lib：多出來的那一行分得出來，輸出也會保留

**它做到什麼【讀】**
- `green()` 要求 PASS 必須是最後一行，並說出後面有幾行、第一行是什麼（S/redfirst_lib.sh:19-38）。
- `exactly_red` 要求最後一行是 FAIL（:40-55）。
- 兩者不乾淨時都會把輸出存到 `$KEEP`。
- 自測的 fixture 就是「PASS 後面接一行 Killed」這個情境（:63）。
- mutant Q2-1 讓三條檢查同時變紅（G/redfirst_lib_gate…log:22-25）。這是一個真的測試，但只測到「這個分支存在」。

**盲點**
- 見 R3-N1：如果多出來的那一行沒有換行字元，就抓不到。

## Q4. 數字：都對得上【讀】

| 項目 | 數字 | 證據 |
|---|---|---|
| mutate_p4_heartbeat_w | 195/0 | mutate_p4_heartbeat_w_c log:230；root helper 的 byte-identical 在 :229 |
| mutate_roles_binding | 174/0＝172＋2 | mutate_roles_binding_c log:615 |
| 07 自測 | 57 個 ok | live07_selftest log 以 grep 計數；redfirst_r3 log:28 |
| 08 自測 | 125 個 ok、0 紅 | live08_selftest log |
| anchors | 120/120 | check_gate_anchors log:135 |
| tripwire | 0 | nolab_tripwire log:21、_c 的 :21；S/tripwire.log 共 512 行，全部是 `curl … file://` |

- 不計入的 run 排除得正確：
  - 沒加後綴的那兩次：baseline 紅，rc 2（mutate_p4_heartbeat_w…log:12-18）；
  - `_b`：exit 143（:109）。

## Q5. 先前各項的現況
- **R-N4**：有改善，但本質沒變。
  - shim 擴大了：新增擋 mnexec、iperf、ping，擋會改動狀態的 tc/ip/ovs 呼叫，curl 擋 :8080，另有假 fabric 用的 `ps`（S/make_shims.sh:15-85）。
  - 仍然只攔得到經 PATH 找到的指令。例如 07 的 `TC=${TC:-/usr/sbin/tc}` 是絕對路徑（只在 live 用到）。
  - 計數用的 regex 也不含 tc/ip/ovs（S/gates_r3c.sh:52-53）。
- **R-N5**：本分支沒有動它，要看 be2ad2d2（我沒審）。在它 merge 之前，原本的操作規則照舊。本輪的 gate 沒有跑 test_live_p1_common（gates_r3c.sh:48-55）。
- **N2-3**：沒變，08 本輪沒動。r2 那一次紅仍然沒有解釋；新 lib 可以讓下一次「結尾多一行、而且有換行」的情形留下可查的證據。

## NOTE（都不擋）
- **R3-N1** `green()` 用 `wc -l` 算總行數（redfirst_lib.sh:21）。
  - 如果結尾多出來的那一行沒有換行字元，就不會被算進去，結果會誤判成乾淨的 PASS。
  - fixture（:63）是有換行的，所以沒測到這種情況。
  - 建議改用 `awk 'END{print NR}'`，並補一個沒有換行的 fixture 和對應的 mutant。
- **R3-N2** `$KEEP` 預設在 `$T/kept-not-saved`，而 `$T` 在結束時會被刪（redfirst_r3.sh:15-16）。這次 gate 把它設在 session 的 scratchpad（redfirst_r3 log:4）。建議改放在 G 底下，證據才會跟 log 一起留下來。
- **R3-N3** 【推】`st_l6_inherited` 殺掉的是外層那個 subshell（07:616-619），但 `state_until` 是在 `$( )` 產生的子程序裡跑的，不會跟著死。
  - 結果是這個輪詢迴圈會變成孤兒，繼續以 file:// 輪詢約 24 s。
  - 它的輸出都導到檔案，所以不會在 PASS 後面多印一行，只是浪費資源。
  - 建議用 setsid 或 timeout 包起來，讓整組程序一起結束。
- **R3-N4** `l6_plain` 的預設值 `${1:-30}`（:394）沒有任何自測執行到：plain 那格一律傳 4（:628）。
  - 所以把它改成 `${1:-2}` 的 mutant 會存活，而 live 的 phase B（:918）用的正是這個預設值。
  - 另外，6.5 s 這個門檻只證明 poll ≥7 s，不證明是 30 s。
- **R3-N5** 對照組只要求「至少一行」（MW:124）。knob 分支和 link 分支只要任一個還在運作，就能讓對照組通過，所以它證明不了兩個分支都有效。red-first 時兩行都有出現（redfirst_r3 log:12-13），可見當時兩個分支都在運作。建議分別斷言兩行。
- **R3-N6** 【推】tripwire 只記錄驅動腳本自己 `NOLAB_LOG` 裡的呼叫，而且只攔 PATH 上的指令；絕對路徑和 Python 發出的 HTTP 都記不到。
- **R3-N7** 【推】`_common.sh` 的 `"$PY" -c`（:315、:328…）跑的是經由 symlink 接進來的 venv 直譯器，而且沒帶 `PYTHONDONTWRITEBYTECODE`。
  - 只有在 site-packages 的 .pyc 過期或缺漏時，才會寫進那個 venv。
  - redfirst_r3.sh:47 用 readlink -f 解析 venv 路徑，顯示它可能連到別的 checkout，也可能是主 checkout。
  - 寫進去的只會是快取，不是 lab 狀態。
  - 在 lrun 加上這個環境變數就能完全封住。

**本分支能否碰到 live lab：沒找到路徑【讀】**
- 07 新增的那格只走 file://。
- ltree 只建立兩條 symlink。
- 沒有任何 sudo。
