# 審查：段 W 併入後的三條後續（皆從 `cafd518a`）

（opus-judge，新開；2026-09-27 ~00:xx 交回；唯讀，未用 git、未執行。要點由 orchestrator 轉錄，未改判定。路徑縮寫：G＝`logs/gates-0910`、I＝`intake-0926`、RUNS＝`live-p1/runs`〔未提交的觀測〕。）

## 判決

| 分支 | 判決 | BLOCKING |
|---|---|---|
| `fix/ndt-serve-anchors-0926` @ `60194b09` | **MERGE** | 無 |
| `fix/08-h5-sampler-0926` @ `f4f43a32` | **MERGE** | 無 |
| `fix/07-heartbeat-links-0926` @ `e012a5a7` | **MERGE** | 無 |

- **Live H5 重跑：merge 後可開始。** sampler 起不來現在會在 06 之前 FAIL；但起來之後才死，仍可能只留一行 `!!`（N2-1）。建議先補 N2-1；不補的話跑完人工核對：`$RUN/50_sampler.err` 為空、`50_samples.tsv` 最後一列 wall 晚於 01 結束。
- **Live 07：merge 後可開始。** 沒找到健康 run 會 false red 的路徑；但 L1-on-switch_state 的 OK 不代表每個方向都聽到過（N3-1）；`state_until` 第一次被執行會在 live 上（N3-2）；07 從沒在 lab 跑過（`07_roles_basic.sh:9-14`）。
- `I/fix3/rerun-*.5475445a.log` 四份都在、全綠。

## 1. `60194b09`（ndt serve 錨點）

11 個錨點逐一核對（ndt 即 cafd518a 的）：`cmd_status`（6670-7075）7063/7068/7072/7074；`app_start`（8889-8974）8895/8899/8972；`cmd_apps`（10341-）10346/10413/10416/10419。每列語意對得上 `RC_TABLE`（`verbs.py:226-245`），11 列全部 +124；註解引用行號逐一核過；`heartbeat_row`（2998-3028）只印、在 6881 被呼叫、不碰 `problems[]`。M63 新值 8439 是 `proc_checkout`（8376-8440）的 `return 1`——文字符、函數不符，仍只測函數那一半；M61 跟 verbs.py 新列。測試沒放寬（`test_ndt_serve.py:1054-1083` 仍比文字與函數）。red first 同 CI（`G/test_ndt_serve_tmpshort.ndtserve-cafd518a.log:66,111,118`；`I/ci-36251857977-gcc.raw.log:6744-6747`）；91/0（`G/mutate_ndt_serve.ndtserve-60194b09.log:68,72,101,113`）；CI 14→15 只差這支（`ci-36233414349:6879` vs `ci-36251857977:6888`）；本機兩 lane 11→10、8→7。「在 580767a8 上逐列核對」無 log、judge 無 git，未獨立驗。

- **N1-1 NOTE**：`tools/ndt_serve/README.md:60` 仍寫 `ndt:9292-9307`（serve.py:22 與 test_ndt_serve.py:419 已改 9416-9431）；公開 repo，建議順手補。
- **N1-2 NOTE**：`verbs.py:252` 說 124 行都在 cmd_status「above」，但 ndt:6880-6881 在 cmd_status 裡（判定之前）。不影響錨點。

## 2. `f4f43a32`（08 H5 sampler）

修法正確：quoted heredoc（`08:691-720`）、stderr 寫檔（728-729）、`sampler_start` 等 header＋`kill -0` 最多 5 s，否則 `fail`＋`sampler_stop`＋return 1（731-741）、H5 在 06 前 `|| exit 1`（1855）、stop 後再讀一次（718）。自測跑的是正本（全域 `SAMPLER_PY`，1580-1591；L49 放回缺陷被抓，`G/mutate_p4_heartbeat_w.p4hbh5-f4f43a32.log:211`）；假報告欄位與真 daemon 一致（`ndtwin-lab:1137-1162`，同為 os.replace）。**06 之前失敗的路徑安全**：PART=h5 **不 claim**（08:1850）；`exit 1` → `w_finish`（1815、635-651）；`finish` 的 down／release 以 `CLAIMED` 為閘（`_common.sh:239,263`）；knob byte 相同不寫（:154）；fabric 未起。

| 宣稱 | 判定 |
|---|---|
| live H5 什麼都沒記、ruling 4 沒量到 | SUPPORTED（那次跑完整個 06＋01 才發現；h5 log:42,48,52,59） |
| red first 4 紅，第一條 `header '', rows ''` | SUPPORTED（`G/live08_sampler_redfirst…log:9-16`） |
| 189/0 | SUPPORTED（log:211-216,222） |
| stop 後最後一讀是「確定性」證明 | 功能 SUPPORTED；措辭過頭（1625-1644 只有 ~0.5 s 時序餘裕） |
| stopped 報告留到下一臂 | SUPPORTED（06 raw `calc_solution.log:187` 36 s、`multicast_solution.log:186` 145 s） |
| 79 段、08 30/30、0 編譯不過 | 編譯 SUPPORTED；完整性 **CONTRADICTED**（N2-2） |
| 沒被執行的 10 段每段都經 runtime_check | **CONTRADICTED**：9/10，缺 `oldcode_selftest.sh:67` |
| 這 10 段對 live 不是問題 | SUPPORTED【推】 |

- **N2-1 NOTE（建議 H5 重跑前補）**：sampler 起來後仍可能無聲死掉——(a) `sampler_stop` 發現 stderr 非空用 `bad`（08:752），`_common.sh:67` 的 `bad` 不改 `VERDICT_RC`（對照 `fail` :71），最後一行仍可能 PASS；(b) 寫 stop 檔前不確認 sampler 已死（745-747），被 signal 殺掉連 stderr 都沒有；(c) `v_no_session`（562-566）視窗內零樣本回 OK，`v_h5_heartbeat` 只擋整份沒樣本（556-557）。修法各一兩行。
- **N2-2 NOTE**：盤點逐行比對（`embedded_sweep.py:23-24`）漏多行開頭的程式——08:139-142 `consts` 沒有自測執行（只 live H1-H4 在 08:1913 跑），「08 未執行 0 段」不成立；`_common.sh:748-780` `link_usage_window` 其實被 `test_live_p1_common.sh:861,878` 執行但沒標到。79 是下限（≥81）。兩段對 live 無害。
- **N2-3 NOTE**：自測 0.5 s 停留配 0.1 s 取樣（1583-1590），guard 節流下可能小機率不穩，flake 率沒量。

## 3. `e012a5a7`（07 links_heard）

對照 proxy 真實輸出：`link_liveness` 先輸出 `_link_beacons`（`topology_manager.py:2277-2288`），declared 是後面 `setdefault`（2294-2300）；心跳證據以 `source="heartbeat"` 進入（2474→2352→2410）；key 為 int、雙向（2278、:491、786）。真 live 資料（15:26Z run）：`22_switch_state.json:71-74` 剛 up 時 `watchdog_passes: []`、:76-124 八條 declared；`35_switch_state_restored_1.json:158-206` 八條正好是模型的 key、全 heartbeat、down false、age 1.63；unbound 同形（61／67）；fixture（07:383-400）一致。30 s 夠（週期 5 s、watchdog 先等一個間隔，2083-2089；至少 4 個 pass）。false red 沒找到路徑。

| 宣稱 | 判定 |
|---|---|
| 舊檢查在心跳下「一定會紅」 | **CONTRADICTED（措辭）**：單次讀落在第一個 pass 前（真實資料正是）會碰巧綠；修正仍必要 |
| links_heard 規則 | SUPPORTED |
| 選嚴格規則的理由 | SUPPORTED（`link_heartbeat.py:224-231`；L7-22） |
| red first「BAD 0 of 8」 | SUPPORTED；8 紅中 7 條是函數未定義的空輸出，鑑別力靠 mutant 證 |
| 167/0；L7-7 | SUPPORTED（L7-7 實為同義新 mutant、killer 不變；`G/mutate_roles_binding.p4hb07-e012a5a7.log:585,596-600,607`） |
| 01-06 掃描 | SUPPORTED（grep 零命中；02 的 skipped 期望＝07 的 SKIPPED_UNBOUND；06 live 26 臂相同、17 臂 heartbeat running） |

- **N3-1 NOTE（建議補）**：grace 視窗造成 **false green**——從沒聽到的方向以 `(link, False, epoch)` 進來（`link_heartbeat.py:277-282`），在 `LINK_STARTUP_GRACE_S`=30 s（:432）內輸出 `heartbeat / down false / age null`（2279），links_heard 判 OK 且 poll 第一個 OK 就停（07:572）。建議再要求 `last_beacon_age_s` 是數字＋fixture＋mutant。
- **N3-2 NOTE**：`state_until`（07:563-577）與兩個呼叫點（688-695、787-795）沒有自測執行；可照 08 的 file:// 先例（08:1650-1657）。
- **N3-3 NOTE**：對真實 062604Z 模型的比對在這台沒跑。

## 4. 共通

red first 三條皆有；mutation 91/0、189/0、167/0；§3 guard（每份 log `# via JOBS=1 LOCK_WAIT=10800`）；gate 腳本無 ndt up／claim／sudo；root helper 未動；AI 標籤在新程式區塊都有；三條檔案與 mutant 錨點互不交叉。

## 5. 建議加跑

1. octopus 5475445a 上跑三個 mutation gate＋check_gate_anchors；2. 拿四份真實 switch_state 餵 `links_heard`（22、61 應 BAD；35、67 應 OK）；3. 07 `state_until` 的 file:// 自測；4. 08：sampler_start 回 0 後殺 sampler，斷言 run FAIL；`v_no_session` 零樣本案例；5. 併反斜線續行後重做盤點；6. st_sampler 負載下重跑 20 次量 flake。
