# judge-R2B-4f661e31（fix/hb-followups-r2-0927 @4f661e31，base trunk 3f8c2abf）

路徑縮寫（皆為絕對路徑）
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-followups-r2-0927
- G = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- R = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/r2b
- LP = WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
- TM = WT/p4_proxy/proxy_agent/topology_manager.py

**範圍**
- 全程唯讀：沒執行任何東西、沒用 git。
- 讀了：
  - R2 SUMMARY（含 §0），以及兩份舊 SUMMARY 檔尾的「更正（09-27）」——內容正確；
  - delta patch；
  - G 下全部 `*.p4hbr2b-4f661e31.log` 與三組 scripts；
  - WT 原始碼；
  - `R/rerun-*.fc4c1688.log`：3 份都在、全綠，你那份 tripwire 是 0 行。
- 依角色規則沒讀 INCIDENT 檔，只用你的描述和 SUMMARY §0。
- 【讀】＝親自讀到；【推】＝推論。

## 判決：**MERGE**（沒有 BLOCKING）
1. **NOTE 是否解決**：N1-1、N1-2、N2-1、N2-2、N3-1、N3-2 都解了。N2-3 量了沒修，可以接受。N3-3 已由四份真實 08 capture 取代。
2. **那次沒解釋的紅**：可以接受，列 NOTE，不擋。
3. **`last_beacon_age_s` 規則**：在健康的 live run 上不會假紅【推】。
4. **live 07**：merge 後可以跑，條件見 R-N5。
5. **本分支能否碰到 live lab**：沒找到任何路徑；有兩個銳邊，見 R-N1、R-N4。

## Q1. 逐項 NOTE

| NOTE | 狀態 | 證據【讀】 |
|---|---|---|
| N1-1 README 行號 | 解 | WT/tools/ndt_serve/README.md:60 已是 9416-9431。新測試在 test_ndt_serve.py:1096-1124，檢查引用必須落在 lock_probe 的註解頭到 POST 之間、且在函數內。它對 3f8c2abf 是紅的（G/redfirst_r2b…log:51）；M64/M65 被抓到（G/mutate_ndt_serve…log:103-104,117，93/0） |
| N1-2 verbs 措辭 | 解 | verbs.py:252-254（122＋2） |
| N2-1 sampler 起來後才死 | 解 | 見下方說明 |
| N2-2 盤點 | 解（殘留見 R-N3） | G/embedded_compile…log:10（08:140-141 `consts`）、:68（_common.sh:748-780）；總數 98＝88＋10（:118）；cover 97 段標記、88 段被執行，08 為 31/31（G/embedded_cover…log:115,120）；runtime_check 現在 10/10，含 oldcode:67（G/runtime_check…log:22-23；runtime_covers_not:29） |
| N2-3 self-test flake | 量了沒修：56 次裡 1 次不乾淨 | 見 Q2 |
| N3-1 grace 造成的 false green | 解 | LP/07_roles_basic.sh:205-207,217-218；兩個 grace fixture；L7-23 抓到（G/mutate_roles_binding…log:602）；四份真實 capture 判成 BAD/BAD/OK/OK（G/redfirst_r2b_keep…log:49，snapshot 的 sha 在 :11 核過） |
| N3-2 state_until 沒被測過 | 解 | 見下方說明 |

**N2-1 的修法【讀】**
- stderr 非空改成 `fail`（LP/08_heartbeat.sh:791）。
- 寫 stop 檔之前先查 `sampler_alive`，同時比對 pid 和 argv（772-782）。
- 樣本缺口規則：
  - 門檻 `MAX_SAMPLE_GAP_S=10`（541）；
  - `v_h5_heartbeat` 查 06 期間（571）；
  - `v_no_session` 查 01 的窗（586）。
- red first 在 7403eb79 上正好 5 紅，每條各紅一次（G/redfirst_r2b…log:13-24）。
- L55–L60 都被抓到，195/0（G/mutate_p4_heartbeat_w…log:218-223,229）。

**N3-2 的修法【讀】**
- `state_until`、`l6_switch_state`、`l6_roles`、`l6_plain` 移到 dispatch 上方（07:354-392、self_test 在 396、dispatch 在 657）。
- live 流程只呼叫這兩個函數（801、892）。
- `st_l6` 透過 file:// 跑的就是 live 那份程式碼（R/rerun-live07_selftest.fc4c1688.log:36-40）。
- L7-24..27 都被抓到，172/0（mutate_roles_binding log:603-606,613）。

## Q2. 那一次 redfirst_r2b 的紅：可以接受（NOTE）
- 【讀】紅在 G/redfirst_r2b…log:25 `08 at HEAD: not a clean PASS`。但同一次 run 裡，四個新案例都有 ok 行（:26-29），所以紅不在本輪的新程式裡。
- 【讀】判準在 scripts-p4hbr2b-4f661e31/redfirst_r2b.sh:39-43：最後一行必須是 SELF-TEST PASS，而且 0 條紅。這版不保留輸出，所以無法分辨是真的有紅，還是結尾多了一行。
- 【讀】之後在 guard 內乾淨 31 次：
  - flake08_guard 20/20（log:10-30）；
  - keep 1 次，125 ok（log:25）；
  - repeat 10/10（log:9-19）；
  - 另外 orchestrator 在 fc4c1688 上也 PASS（R/rerun-live08_selftest.fc4c1688.log:131）。
  - 「guard 外 23 次」我沒看到 log，UNDER-EVIDENCED，但不影響判決。
- 【推】最可能是既有的時序邊際格（N2-3）。紅出在離線 self-test，碰不到 lab，也不改變 live 行為。
- 建議把會保留輸出的 `green()`（-extra 版的 :39-45）當成標準腳本；下次再紅就先診斷。

## Q3. `last_beacon_age_s` 規則：健康 run 不會假紅【推，依據都讀過】
- daemon 一啟動就送第一輪（WT/tools/test_workflow/ndtwin-lab:1313,1320-1331），而「聽到」是在 veth 上發生，和 pipeline 無關。
- ndt 先起 daemon 再起 proxy（ndt:2939-2940）；proxy 的第一個 pass 在 watchdog 起來後 ≥5 s（TM:2083-2089）。所以到第一個 pass 時，健康方向都已被聽到。
- 聽到後 `seen` 變成 True，之後不會變回 False（TM:2401-2410）；只要 seen，age 就是數字（TM:2279）。epoch 重設也不會把 seen 清掉。
- 只有「從沒聽到」的方向會是 None，這正是規則要抓的真紅。
- 30 s 輪詢至少涵蓋 4 個 pass；真實穩態的 age 是 1.63／1.77。
- 唯一的例外見 R-N2。

## Q4. live 07：merge 後可以跑
- 附條件 R-N5。
- L1-on-switch_state 如果紅，先看 `30_switch_state_roles.json.polls` 和 `71_switch_state_plain.json.polls`，每次輪詢的判定都留在那裡。

## 本分支能否碰到 live lab：沒找到路徑【讀】
- 07 `st_l6`：只用 file:// 的 PROXY_URL，沒有碰 KERNEL_URL、沒有 sudo。
- 08 `st_h5_dies`：
  - ndt 是 stub；
  - `CLAIMED=0`；
  - knob 的副本都是空的，APP_KNOB 指向 tmp（08:1377-1378，另外兩處同樣設定在 1772-1773、1839-1840）；
  - 所以 `w_finish`／`finish` 不會呼叫 ndt、tc 或 sudo。
- `consts` 只是 import（TM:1-16 都是本地模組），並加了 PYTHONDONTWRITEBYTECODE。
- 新的 ndt serve 測試只讀檔。
- tripwire 全部 0/0：G/nolab_tripwire…log:443、_extra:19、_repeat:18，以及 R/nolab/tripwire.log 0 行。

## 新 NOTE（都不擋）
- **R-N1** mutate_p4_heartbeat_w.sh:1073,1103 把整個 `p4_proxy` 用 symlink 接進 mutant 樹。
  - 結果是 mutant 樹裡的 `$REPO/p4_proxy/mininet/{host_count_override,app_package_override,telemetry_override}` 會指到真正那份 checkout；在主 checkout 裡，這些檔案就是 lab 狀態。
  - 今天沒有任何寫入【讀】，但這是銳邊。
  - 建議只 symlink `p4_proxy/proxy_agent` 和 `p4_proxy/venv`。
- **R-N2** `L1_POLL_S`（07:376）是 live 路徑會繼承呼叫端環境的變數。如果外面設了很小的值，poll 會縮短，可能假紅。建議 live 路徑 unset 它，或改名成 SELFTEST_ 開頭。
- **R-N3** 仍有兩段放在變數裡的測試夾具程式不在 98 段內：08:1381（stderr 夾具，會被執行）和 08:1717（刻意編譯不過）。「0 段編譯不過」只對掃描器認得的集合成立。影響只在措辭。
- **R-N4** tripwire 只記得到經由 PATH 找到的 `sudo`／`curl`；絕對路徑或 Python HTTP 都記不到。這次讀碼沒找到那種呼叫，但 0/0 不等於證明沒碰 lab。
- **R-N5**（操作面，不在本分支）trunk 上 `test_live_p1_common.sh` 5e 的缺陷還在，而本輪的 embedded_cover 閘門也照樣跑它（embedded_cover log:12-13），靠的是 shim 加上當時沒有 fabric。
  - live 07 的 pod-topo 就是 h1..h4。
  - 在 `fix/live-p1-common-5e-nolab-0927` merge 之前，live 07（或任何 live run）進行中時，這台機器上不能在沒有 sudo shim 的情況下跑這支測試、L1 shell lane 或覆蓋率閘門。

## 我會跑、而報告沒跑的
1. 把 R-N1 改好之後，重跑 mutate_p4_heartbeat_w。
2. 對 08 self-test 做一次刻意製造「結尾多一行」的判準測試，確認 `green()` 會分辨。
3. 在 fc4c1688 上重跑三個 mutation gate。

## 內部數字：全部對得上【讀】
- 盤點：98＝32+15+23+27+1；Python/awk 88＝32+15+23+17+1；標記 97；執行 88＝31+12+19+26+0；未執行 9＝0+3+4+1+1。
- mutation：195＝189+6、172＝167+5、93＝91+2。
- 測試數：test_ndt_serve 74＝73+1；07 為 56 ok（45+2+5+4）；08 為 125 ok（117+8）。
