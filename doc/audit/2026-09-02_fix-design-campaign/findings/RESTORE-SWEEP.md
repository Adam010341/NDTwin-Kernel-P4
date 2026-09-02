# RESTORE-SWEEP — 還原路徑缺陷全 round 掃描

指派 ID：**RESTORE-SWEEP**（唯讀稽核 subagent，未修改 repo 內任何檔案）
日期：2026-09-02
所有宣稱一律為「**讀過，未執行**」。沒有跑任何 round script、沒有 build、沒有 Mininet、
沒有 `ndt`、沒有 claim、沒有 sudo。唯一「執行」過的是 `git log`／`git status`／`git diff`、
`cat`／`sed -n`／`grep`／`ls`／`find`／`date`，以及一段**唯讀**解析 compiled JSON 的 python
（只 `json.load`，不寫檔）。

---

## 1. Base + status 快照

### HEAD

指派書預期 `4cbec52d`，實際觀測到 **HEAD 已往前移動兩次**（開工時與寫稿時各一）：

```
$ git -C /home/adam/Desktop/NDTwin-Kernel log --oneline -1
7e553f35 Name the dry-run logs as what they are, before the real run reuses the name
```

（rc=0。另一個 session 正在同一棵樹上工作——見下面第 5 節，那一輪**此刻正在跑**。）

### git status --short（**全部都是別人未提交的工作**）

```
 M doc/2026-08-29_bmv2-performance-study-figs/fig5_reporting_matrix.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig6_twelve_numbers_one_axis.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig7_aggregate_two_planes.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig7_aggregate_two_planes.png
 M doc/2026-08-29_bmv2-performance-study-figs/fig8_known_but_never_reported.pdf
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/gates_e.dryrun.log
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/run_e.dryrun.log
 M p4_proxy/p4_src/ndtwin_switch.p4          <=== 見第 5 節
?? .claude/launch.json
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.dryrun.restore.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.dryrun.selftest.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.plan.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.selftest.log
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/acceptance.sh
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/churn.sh
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.lifetime-acceptance.log
?? doc/audit/2026-09-02_recompute-paired-ab/run_ab.log
?? doc/audit/2026-09-02_recompute-paired-ab/run_ab.stdout
?? tests/python/test_cpu_gate_lifetime.py
```

本檔引用被 `M` 標記的檔案時，一律標注「**未提交觀測**」。

### R1 的前提已查證（不是轉述）

`p4_proxy/mininet/p4_testbed_topo.py`：

- **`:357`** `json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')` — `MultiSwitchTopo` 載入的就是**編譯產物**。
- 同檔 **`:574`** 有第二處相同載入；`p4_proxy/mininet/ntg_bmv2_topo.py:64` 是第三處。

⇒ **fabric 只認 `build/ndtwin_switch.json`，不認 `.p4`。** R1 的前提成立。

實際被 sed 的常數不是指派書舉例的 `0x3ff`，而是
`p4_proxy/p4_src/ndtwin_switch.p4:52` 的 `const bit<16> SAMPLE_RATE = 256;`
與 `:74` 的 `const bit<32> SAMPLE_TRUNC_BYTES = 128;`；
另有第二種改法（09-01 起）：`:406` 的 `random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);`
把下界 `0` 改成 `1`，讓 `sample_rand == 0` 永遠不成立 ⇒ **完全不取樣**。

---

## 2. 掃描結果表

掃描範圍：`doc/audit/*/**.{sh,py}`（106 個 round 目錄、約 260 個腳本）、`tools/`、`p4_proxy/`。
先用 `grep -rn 'SAMPLE_RATE|SAMPLE_TRUNC_BYTES|ndtwin_switch\.p4'` 與
`grep -rln 'bmv2_binary_override'` 收斂出**真正會改東西**的腳本，再逐一讀。
不改任何受管制檔案的腳本不列（例如 `2026-08-30_live-full-stack-round/90_restore.sh` 只還原
被關掉的交換機電源，與 R1／R2 無關——它是 KNOWN-ISSUES 的 **T-10**，另一條線，見第 3.4 節）。

圖例：**Y** ＝ 缺陷存在；**N** ＝ 有正確處理；**N-A** ＝ 該腳本不做這件事，故不適用。

| # | script | 改什麼 | 還原機制（file:line） | R1？ | R2？ | 還原後的斷言查對的是不是**正確的產物** | 對其後 round 的後果 | 最小修法 |
|---|---|---|---|---|---|---|---|---|
| 1 | `doc/audit/2026-09-01_cpu-matrix-1hz/zero_cell.sh` | `.p4` 原始碼（取樣述詞下界 0→1）＋ compiled json | `restore_p4()` `:50-61`，掛在 `trap ... EXIT INT TERM` `:64` | 🔴 **Y** — `restore_p4()` **只改 `.p4`，完全不重編**。`:59` `say "  p4 sampling predicate restored"` 就結束了 | N-A（不碰 binary） | 🔴 **否，而且兩處**。(a) trap 路徑完全不驗 compiled JSON；(b) happy path `:135-136` 的 `p4c-bm2-ss` **沒有任何 rc 檢查**，收尾證據行 `:138-139` 讀的是 **`$P4SRC`**（原始碼），那正是唯一無法說明 fabric 在跑什麼的檔案 | 🔴 **最嚴重**。腳本有三個 `exit 1`（`:115`、`:122`、`:137`）走 trap；任一觸發 ⇒ 原始碼讀起來正確、**compiled JSON 停在「不取樣」**。之後每一輪 telemetry 全零或近零，而所有 source-based 檢查都是綠的 | `restore_p4()` 內含 `p4c` 並**對 compiled JSON 的 rng 兩個界斷言**；把 `:135` 那個裸 `p4c` 拿掉 ⇒ `RESTORE-SWEEP.patches/zero_cell.sh.diff` |
| 2 | `doc/audit/2026-09-01_cpu-matrix-1hz/matrix_1hz.sh` | `.p4` `SAMPLE_RATE`（1024→512→256→128→64）＋ compiled json | 尾段 `:148-151` `teardown; compile_at 256 \|\| exit 1; bringup` | 🟡 **部分 Y** — `compile_at()` `:65-70` **有**重編（happy path 正確），但**沒有 trap**：body 內七個 `\|\| exit 1` 全部裸奔 | N-A | 🔴 **否**。全篇對 compiled JSON **零斷言**；收尾證據行 `:151` `grep -oE 'SAMPLE_RATE = [0-9]+' "$P4SRC"` 讀原始碼 | **已經真的發生過**：`matrix_1hz.aborted-2131.log` 停在 `m1024_poll` 之後 ⇒ 中止時 JSON 停在 **1/1024**。只因三分鐘後重跑的第一件事就是 `compile_at 1024`（量測之前）才沒事——**是運氣不是設計**。掃到 1/64 收尾，所以中止殘留最壞是 **1/64（4× 生產值）** | 加 `trap`＋`compiled_rate()` 斷言，收尾行改讀產物 ⇒ `matrix_1hz.sh.diff` |
| 3 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh` | `.p4` 兩個常數＋**kernel binary**（`swap_kernel()` `:840`） | `restore_production()` **`:928-937`**；斷言 `assert_restore_landed()` **`:891-926`** | **N** — `restore_production` `:935` 呼叫 `compile_at 256`，`compile_at` `:800-816` **有**重編且 p4c 失敗會 `abort` | 🟡 **Y（結構上在，後果被巧合抵銷）** — `:931` `RUN cp -f "$KBIN_BACKUP" "$KBIN"` 在 **`:934 teardown` 之前**，即 stack 還活著；`RUN` `:211` 只是 `"$@"`，呼叫端無 `\|\|` ⇒ **rc 沒被讀**。🔑 但 `cp -f` 碰到 ETXTBSY 會**unlink 目的檔再建新檔**，所以磁碟上的檔案變對、**跑著的 process 仍是實驗臂**（從已 unlink 的 inode 執行），然後下一行 `teardown` 把它殺掉 ⇒ 終局正確。**這是意外，不是設計** | 🟡 **一半**。kernel 查 `sha256sum "$KBIN"`（`:909`）＝**磁碟檔**——只因 `teardown` 已先跑過才剛好是對的產物。P4 那邊：`SAMPLE_RATE=256` 只驗**原始碼**（`:904`），compiled JSON 只驗 `"op":"truncate"` **存在**（`:906`）——而 truncate op **在每個 rate、以及取樣關閉的 build 裡都在** ⇒ **對本輪真正動的那個軸零鑑別力** | 實測 5 次 `restore_production` 全部印出 `restore verified: P4 constants, compiled artefact and kernel binary all back at production`（`run_e.log` 45/158/2083/3932/5751 行）⇒ **E 輪沒有被咬到**。但那句話比它證明的多 | 對調 `cp`／`teardown`；讀 `cp` 的 rc；斷言 compiled JSON 的 **rate 與 rng 下界** ⇒ `lib_e.sh.diff` |
| 4 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/gates_e.sh` | 不改，只是閘 | `:224-238 g9_clean_half()` 呼叫 `assert_restore_landed`；`:617` 用 `DRY_FAIL=restore` 強制紅 | N-A（不改） | N-A | 見 #3——它把 `lib_e.sh` 的斷言**當作已經正確**再包一層。`:249-252` 的 half-covered 記錄是本 repo 最好的「沒驗到就寫下來」實作 | 中止路徑只跑得到紅那一半，這件事**有被記錄**（`G9-COVERAGE.txt`） | 無須改；#3 修好它自動變強 |
| 5 | `doc/audit/2026-08-31_f5-fine-grid-round/run_f5.sh` | 🔑 **什麼都不改**。全檔**沒有 `sed -i`**，兩個 `cp` 是 `:330`（複製 log）與 `:726`（複製 PREREG）。註解 `:190` 說「This round SWAPS kernel binaries」——**腳本裡沒有那個動作** | 它是**偵測器**：`assert_kernel_restored()` `:193-217`、`assert_sampling_config()` `:279-297`、EXIT trap `f5_exit_restore_check` `:363` | 🔴 **Y（在偵測器裡）** — `:287` 驗**原始碼**的 `SAMPLE_RATE`，`:294` 對 compiled JSON **只驗 truncate op 存在**。⇒ `:297` 印的「source and compiled JSON agree」**不是這個函式建立的事實** | N-A | 🟡 **R2 這半是全 repo 最正確的**：`:201-206` 讀 **`/proc/$pid/exe`** 的**跑著的**行程，不是磁碟檔。⚠️ 但鑑別子是 `nm -C \| grep -c setProgrammedPredicate`＝**符號存在計數**——`lib_e.sh:830-838` 明寫這招對「只差常數值」的兩臂無鑑別力；這裡分辨的是 pre/post-T-11（符號真的不存在過）所以成立，但**換不掉另一顆 post-T-11 binary** | 🔑 **F-5 從未真跑過**：`raw/` 只有 3 個 selftest jsonl ＋1 個 `dst_sequence.txt`（共 4 檔），**沒有 `run_f5.log`**（只有 `.dryrun`／`.plan`／`.selftest`）。⇒ 修它**現在零成本**，而它是隊列裡負責替鄰輪把關的那一個 | 讓 `assert_sampling_config` 真的讀 JSON 的 **rate＋rng 下界** ⇒ `run_f5.sh.diff` |
| 6 | `doc/audit/2026-09-02_recompute-paired-ab/run_ab.sh` | `.p4` 述詞＋`SAMPLE_RATE`＋**kernel binary** | `restore_all()` `:54-101`，`trap restore_all EXIT INT TERM` `:102` | ✅ **N — 這是正確範本** | ✅ **N — 這是正確範本** | ✅ **是**。`:78` `if p4_compile;` 重編並讀 rc；`:86` `if ! cp ...` **讀 cp 的 rc**；`:89-94` `sha256sum "$KBIN"` 比對硬編碼的 `PROD_SHA`。**`:63` 先 `stack.sh down` 再 `sleep 2` 才動 binary**，註解 `:56-62` 明寫這一行就是 dry run 逼出來的 | 它就是找到 R1／R2 的那一輪 | 唯一還缺的：`p4_compile` 之後**沒有回頭讀 compiled JSON 確認 rng 回到 `0 255`**（只信 p4c 的 rc）。屬加分項，不是缺陷 |
| 7 | `doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh` | `.p4` `SAMPLE_RATE`（1024…64） | 尾段 `:96-99` `teardown; compile_at 256 \|\| exit 1; bringup "" \|\| exit 1` | **N** — `compile_at()` `:60-65` 有重編 | N-A | ❌ **無任何斷言**（連原始碼的都沒有） | `matrix.log:259/293` 顯示 `restoring production config` → `matrix complete, production config restored`（08-20 15:57:29）⇒ **有還原**。無 trap，中止殘留最壞 1/64 | 同 #2（低優先，此輪已封存） |
| 8 | `doc/audit/2026-08-25_sampling-rounds/` D 族六支：`gate_d.sh:101-104`、`ladder_ext.sh:119-122`、`wall_f.sh:140-143`、`run_c.sh:66-69`、`h_probe.sh:140-143`、`ctl_c.sh:69-72` | `.p4` `SAMPLE_RATE`（＋部分改 `SAMPLE_TRUNC_BYTES`） | 一律 `teardown; compile_at 256 [128] && bringup && say "restored" \|\| say "RESTORE FAILED"` | **N** — 六支的 `compile_at` 全部重編 | N-A | 🟡 **只有 `run_c.sh:50-51` 對 compiled JSON 斷言**（`"op":"truncate"` 存在）。其餘五支零斷言。**六支都沒有 trap** | 六支的 log 全部收在 `production restored`（`gate_d.log:19:41:39`、`ladder_ext.log:20:05:42`、`run_c.log:22:41:07`、`ctl_c.log:23:03:00`、`wall_f.log:03:16:05`、`gil_g.log:11:43:25`、`h_probe.log:12:49:38`）⇒ **D 族全部有還原到**。`run_c.sh:46` 註記的那次污染（`gate_d` 把 truncate 留在 16384）是**這個檔案自己記下來的先例** | 已封存，不建議動；當作 #2／#1 的先例引用 |
| 9 | 🔴 `doc/audit/2026-08-25_sampling-rounds/run_e8.sh` | `.p4` `SAMPLE_RATE = 8`（`:36`），**32× 生產值** | 🔴 **沒有還原。** `:71` `say "=== run_e8 complete (production restore left to operator) ==="` | 🔴 **N-A ⇒ 更糟**：不是「還原不完整」，是**明寫不還原** | N-A | ❌ 無 | 見第 3.1 節：它**還提早中止**（`run_e8.log:48` `[02:18:34] ABORT: proxy did not reopen :8081`），所以連那句「left to operator」都沒印出來 | 已封存。**價值在於它是 Q1 的唯一真實暴露窗** |
| 10 | `doc/audit/2026-08-22_stock-control-ladder/stock_ladder.sh` | `p4_proxy/mininet/bmv2_binary_override`（**指令文字檔**，不是 binary） | `:59` `trap 'cp "$BACKUP" "$OVERRIDE"; ndt down >/dev/null 2>&1; printf "override restored\n"' EXIT | N-A | **N-A** — 還原的是文字檔，不會 ETXTBSY | 🟡 trap 內 **`cp` 的 rc 沒被讀**，還原後**不驗**。但 `:82`／`:101` 在**跑之前**比對 `/proc/<pid>` 指到的 binary 的 sha ⇒ 下一輪自己會發現 | 影響面小（override 只是選 binary 的一行指令） | 低優先：trap 內加一行 `grep -q` 對帳 |
| 11 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/build_1khz_binary.sh` | `include/ndt_core/collection/FlowLinkUsageCollector.hpp`（**C++ 原始碼**） | `:172-184`：`git diff` 存 patch → 還原 → `:183` `grep -qF "$LINE_1HZ" "$HPP" \|\| FATAL` → **`:184` `cmake --build`（重建！）** | ✅ **N — 這是 C++ 側的正確範本**：還原原始碼**之後有重建**，正是 R1 要求的形狀 | N-A（只寫 `$KBIN_STAGE`，不覆蓋跑著的 `$KBIN`） | 🟡 `:184` 的 `cmake --build` 失敗只 `say "🔴 rebuild of the restored tree failed"`，**不 exit** | 產出兩顆 staged 臂＋各自 provenance；`:187` 還做「兩臂 sha 必須不同」的負控制 | `:184` 改成 `\|\| exit 1` |
| 12 | `doc/audit/2026-08-30_known-issues-wave/11b_mutation-harness/{run_one.sh,restore.py}` | 另一個 worktree 裡的 C++ 原始碼 | `run_one.sh:3-4`：`restore-clean → apply → assert-on-disk → rebuild → run → classify → restore → REBUILD → assert 46/46` | ✅ **N — 全 repo 最完整的還原契約**：還原→**重建**→**逐檔 sha256 對帳 46/46** | N-A | ✅ **是**。`restore.py` 明寫不用 `git checkout`（會還原到 index）、不用裸 `cp`（磁碟 100% 時短寫會就地截斷），改用 temp+fsync+驗 size 與 sha256+`os.replace` | 不碰 `.p4`／`$KBIN` | 無。**當作 #1 的目標形狀** |
| 13 | `doc/audit/2026-08-25_large-scale-concurrent/restart_kernel.sh` | 重啟 kernel（不改檔） | — | N-A | ✅ **N — 這是 R2 的正確範本**。`:11` 明寫「acceptance test here is not "the command ran" -- it is the sha256 of `/proc/<newpid>/exe`」；`:72-73` 真的去讀 | ✅ **是**，讀**跑著的行程**，且 `:47` 另外分開印 on-disk sha ⇒ **兩個產物分開報，不混表** | — | 無。**當作 R2 斷言的目標形狀** |
| 14 | 🔴 `tools/test_workflow/ndt`（`sample_rate()` `:445`、`stale_pipeline()` `:520`） | 不改，是**儀器** | — | 🔴 **Y（儀器盲區，我實測到的）** | N-A | 🔴 **否**。見第 5 節：`sample_rate()` 只讀 rng **上界**（`int(hi,16)+1`），對「下界被改成 1 ⇒ 完全不取樣」**回報 `1/256`**。`stale_pipeline()` 只測 `built -nt MANIFEST`＝「在 fabric 活著時重編過」，**測不到 R1 的方向**（還原原始碼但沒重編 ⇒ JSON 比 manifest 舊 ⇒ 回傳 false） | `ndt status` 正是操作者用來回答「lab 回到生產狀態了嗎」的指令，而它對**最該擋的那一種還原失敗**回答「1/256」 | 讀兩個界；補 `source_ahead_of_build()` ⇒ `ndt.diff` |

---

## 3. 四個問題的明確回答

### 3.1 Q1 — 哪些已封存（raw 已在 `audit-raw`）的 round 跑在帶 R1 的腳本之後？

**可以定序，而且答案是：據現有證據，沒有任何已封存 round 的 telemetry 是在被污染的取樣率下收的。**
以下是定序的依據與唯一的真實暴露窗。

定序方法：每支 round 腳本自己 `say()` 出來的 `[HH:MM:SS]` 時戳（寫進各自的 `*.log`），
配合檔案 mtime。⚠️ **mtime 單獨不可信**：多支腳本把 `stack.sh up` 以 `&` 背景執行且
`>>"$LOG"`，所以背景行程會在腳本結束**之後**繼續追加，log 的 mtime 比腳本結束晚
（`run_e8.log` 中止於 02:18:34，mtime 卻是 02:58:43）。**用 log 內的時戳，不要用 mtime。**

改動 `.p4` 的 round，依時間排序：

| 時間（腳本自報） | round | 收尾狀態 |
|---|---|---|
| 08-20 15:57:29 | `matrix.sh` | ✅ `matrix complete, production config restored` |
| 08-25 19:41:39 | `gate_d.sh` | ✅ `production restored` |
| 08-25 20:05:42 | `ladder_ext.sh` | ✅ `production config restored` |
| 08-25 22:41:07 | `run_c.sh` | ✅ `production restored` |
| 08-25 23:03:00 | `ctl_c.sh` | ✅ `production restored` |
| 08-26 01:08:33 | `gate_e.sh` | ✅ `gate_e complete`（`restoring production (batch unset)`） |
| 🔴 **08-26 02:14:09 → 02:18:34** | **`run_e8.sh`** | 🔴 **`ABORT: proxy did not reopen :8081`（`run_e8.log:48`）** |
| 08-26 02:59:00 → 03:16:05 | `wall_f.sh` | ✅ `production restored` |
| 08-27 11:43:25 | `gil_g.sh` | ✅ `production restored` |
| 08-27 12:49:38 | `h_probe.sh` | ✅ `production restored` |
| 09-01 07:25:28（第 5 次，末次） | E 輪 `run_e.sh` | ✅ `restore verified: P4 constants, compiled artefact and kernel binary all back at production` |
| 🔴 09-01 21:31 → 21:34（中止） | `matrix_1hz.sh`（`aborted-2131`） | 🔴 停在 `m1024_poll` 之後，**無 trap** |
| 09-01 23:12:43 | `matrix_1hz.sh`（重跑） | ✅ `matrix complete, production config restored` |
| 09-02 00:23:17 | `zero_cell.sh` | ✅ `=== done ===`，述詞與 rate 都印回生產值 |
| **09-02 ~12:23 → 進行中** | `run_ab.sh` | ⏳ **此刻正在跑** |

**唯一的真實暴露窗：2026-08-26 02:18:34 → 02:59:00（約 40 分鐘），取樣率 1/8。**

- `run_e8.sh:36` 把 `SAMPLE_RATE` 設成 **8** 並重編（`:38`），`:71` 寫明
  「production restore left to operator」——**設計上就不還原**。
- 而它甚至沒走到 `:71`：`:63` 的 `ABORT: proxy did not reopen :8081` 在 02:18:34 觸發 `exit 1`。
- 下一個動 `.p4` 的 round 是 `wall_f.sh`，02:59:00 開跑，**第一件事就是 `compile_at 16 128`**
  （重編到 1/16 才量測）⇒ **wall_f 的資料沒有被污染。**
- 這 40 分鐘內**沒有任何其他 round 的 log**。

⚠️ **我不能證明的部分（不猜）**：這 40 分鐘內操作者是否手動跑過**不寫 log** 的東西，
我看不到。`audit-raw` 在本地**不是目錄**（`ls audit-raw` ⇒ No such file），它是 branch
（`audit-raw`、`audit-raw-ff`、`remotes/lab/audit-raw`、`remotes/p4/audit-raw`）。
**我沒有去 checkout 或讀那些 branch 的內容**（唯讀約束＋共用工作樹）。
⇒ 「`audit-raw` 裡有沒有時戳落在 02:18–02:59 的 raw」**必須由人去對**，見第 5 節。

同理，`matrix_1hz` 09-01 21:31 那次中止：殘留是 **1/1024**，
三分鐘後重跑的第一個動作 `compile_at 1024` 在**任何量測之前**覆蓋掉它 ⇒ 無污染。
**兩次都沒事，兩次都是靠下一輪剛好先重編，不是靠還原。**

### 3.2 Q2 — `gates_e.sh:236` 的 `assert_restore_landed` 擋得住 R2 嗎？擋得住 R1 嗎？

先更正一個位置：`gates_e.sh:236` 是 `g9_clean_half()` 裡 `abort` 的那一行，
**函式本體在 `lib_e.sh:891-926`**。`gates_e.sh` 只是它的兩個呼叫端
（`:227` 乾淨半、`:617` 強制紅半）。

**對 R2：擋得住一半，而且擋住的是比較不危險的那一半。**

`lib_e.sh:908-911`：

```bash
        if [[ -f "$KBIN_BACKUP" ]]; then
            local a b; a=$(sha256sum "$KBIN_BACKUP" | cut -d' ' -f1); b=$(sha256sum "$KBIN" | cut -d' ' -f1)
            [[ "$a" == "$b" ]] || { say "🔴 restore: kernel is $b, production backup is $a"; fail=1; }
        fi
```

`$KBIN` 是**磁碟上的路徑**（`build/bin/ndtwin_kernel`），不是 `/proc/<pid>/exe`。

- **裸 `cp`（`run_ab.sh` 原版）＋ stack 還活著** ⇒ ETXTBSY ⇒ 磁碟檔仍是實驗臂 ⇒ sha 不合 ⇒ **這一段抓得到**。這正是 09-02 dry run 抓到的那一次。
- **`cp -f`（`lib_e.sh:931` 用的就是 `-f`）＋ stack 還活著** ⇒ `cp -f` 在目的檔開不起來時**unlink 後重建** ⇒ **磁碟檔變成正確的、跑著的行程仍是實驗臂** ⇒ **sha 比對通過** ⇒ **這一段抓不到**。

E 輪之所以沒出事，是因為 `restore_production` 的下一行 `:934 teardown` 把那個行程殺掉了，
斷言在 teardown **之後**才跑，所以「磁碟檔」剛好就是唯一存在的產物。
🔑 **也就是說：這個斷言查的是不是正確的產物，取決於呼叫順序，而順序沒有被任何東西保證。**
把 `:934` 的 `teardown` 移到 `:931` 的 `cp` **之前**，這個依賴就消失（見 `lib_e.sh.diff`）。

正確做法在同一個 repo 裡已經有兩份現成的：
`doc/audit/2026-08-25_large-scale-concurrent/restart_kernel.sh:72-73`（讀 `/proc/<newpid>/exe`）
與 `lib_e.sh` 自己的 `check_running_arm()` `:602-625`（`running_kernel_sha`）——
**後者就在同一個檔案裡，`assert_restore_landed` 沒有用它。**

**對 R1：全 repo 沒有任何東西擋得住，只有一個地方接近。**

`lib_e.sh:906` 對 compiled JSON 的唯一斷言是：

```bash
        grep -q '"op" *: *"truncate"' "$P4BUILD/ndtwin_switch.json" 2>/dev/null \
            || { say "🔴 restore: the compiled JSON has no truncate op"; fail=1; }
```

`truncate` op **在每一個 rate 下都存在**，在「取樣關閉」的 build 裡也存在
（下界改的是 rng，不是 truncate）。⇒ **對本輪真正變動的那個軸零鑑別力**——
它是「儀器不能長得像自己的發現」的鏡像：一個**永遠綠**的檢查，看起來卻像個檢查。

`SAMPLE_RATE = 256` 只在 **`:904` 的原始碼**被驗。
`run_f5.sh:294` 一模一樣（原始碼驗 rate、JSON 只驗 truncate 存在），
而且 `:297` 還印「source and compiled JSON agree」——**那句話比它建立的事實多**。

唯一真正讀出 compiled JSON 裡取樣設定的程式是 `tools/test_workflow/ndt:445 sample_rate()`，
它**不是**還原檢查、且本身有盲區（只讀上界，見第 5 節）。

### 3.3 Q3 — R1 的修法有沒有單一共用 helper 可以放？

🔴 **沒有。每一輪各有一份自己的抄本。改一份不會修好其他份——這一點請直說。**

```
$ grep -rn -iE "restore_production|restore_p4|assert_restore" tools/ p4_proxy/
（無輸出）
```

`tools/` 與 `p4_proxy/` 底下**沒有任何還原 helper**。各自為政的抄本，逐一列出：

**`compile_at()`（sed + p4c，各自獨立實作，共 9 份）**

1. `doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh:60`
2. `doc/audit/2026-08-25_sampling-rounds/run_c.sh:42`
3. `doc/audit/2026-08-25_sampling-rounds/ctl_c.sh:47`
4. `doc/audit/2026-08-25_sampling-rounds/gate_d.sh:69`
5. `doc/audit/2026-08-25_sampling-rounds/ladder_ext.sh:73`
6. `doc/audit/2026-08-25_sampling-rounds/wall_f.sh:66`
7. `doc/audit/2026-08-25_sampling-rounds/gil_g.sh:57`
8. `doc/audit/2026-08-25_sampling-rounds/h_probe.sh:51`
9. `doc/audit/2026-09-01_cpu-matrix-1hz/matrix_1hz.sh:65`
    ＋ `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh:800`（唯一有 `abort` 的）
    ＋ `doc/audit/2026-09-02_recompute-paired-ab/run_ab.sh:119 p4_compile()`（拆成獨立函式）
    ＋ `doc/audit/2026-08-25_sampling-rounds/run_e8.sh:36-38`（直接 inline，無函式）

**「把述詞換回來」的 python heredoc（逐字重複，2 份）**

- `doc/audit/2026-09-01_cpu-matrix-1hz/zero_cell.sh:52-58`
- `doc/audit/2026-09-02_recompute-paired-ab/run_ab.sh:105-112`（`swap_p4()`）

**「解 compiled JSON 的取樣設定」（2 份，而且兩份**都**只讀上界）**

- `tools/test_workflow/ndt:445 sample_rate()`
- ——沒有第二份。**任何 round script 都不曾讀過 compiled JSON 的 rate。**

**結論與建議**：
`lib_e.sh` 是 E 輪與 F-5 之外唯一被 `source` 進來共用的檔案，但它**只服務 E 輪**
（`run_e.sh`、`gates_e.sh`）。若要一次修好，唯一的位置是**新建**
`tools/test_workflow/p4_restore_lib.sh`，提供 `p4_compile_and_verify <rate>`
與 `p4_assert_production_pipeline`（讀 rng **兩個界**），
然後讓新 round `source` 它、舊 round 逐一移植。
⚠️ **這是新增檔案，不在我的唯讀授權內**，故未寫；`ndt.diff` 裡的 `source_ahead_of_build()`
是同一件事的最小版本，放在既有檔案裡。

### 3.4 Q4 — 提出的 diff

已寫入 `RESTORE-SWEEP.patches/`，**一律未套用**：

| 檔案 | 目標 | 修什麼 |
|---|---|---|
| `zero_cell.sh.diff` | `doc/audit/2026-09-01_cpu-matrix-1hz/zero_cell.sh` | trap 內補 `p4c`＋對 compiled JSON rng 兩界斷言；移除 `:135` 那個不讀 rc 的裸 `p4c` |
| `matrix_1hz.sh.diff` | `doc/audit/2026-09-01_cpu-matrix-1hz/matrix_1hz.sh` | 加 EXIT/INT/TERM trap；`compile_at` 讀 p4c 的 rc 並驗 compiled rate；收尾證據行改讀產物 |
| `lib_e.sh.diff` | `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh` | `teardown` 移到 `cp` 之前；讀 `cp` 的 rc；`assert_restore_landed` 加驗 compiled JSON 的 rate 與 rng 下界 |
| `run_f5.sh.diff` | `doc/audit/2026-08-31_f5-fine-grid-round/run_f5.sh` | 讓 `assert_sampling_config` 真的比對 compiled JSON 的 rate＋rng 下界，而不是只確認 truncate op 存在 |
| `ndt.diff` | `tools/test_workflow/ndt` | `sample_rate()` 讀兩個界、下界非 0 時回報 `DISABLED`；新增 `source_ahead_of_build()` 補上 `stale_pipeline()` 看不到的方向 |

**與 `doc/KNOWN-ISSUES.md` 的對帳**（我讀過，逐條核對）：

- **`:1522` T-10「兩條還原路徑都不還原」** ⇒ **不是 R1／R2**。那是
  `2026-08-30_live-full-stack-round/harness/90_restore.sh` 的**交換機電源**還原
  （`:34` 標註 OVS 上 Route 1 不還原 link shaping）。與 `.p4`／kernel binary 無關。
  ⚠️ 名字很像，**不要合併**。
- **`:1690-1715`** 已記錄 `lib_e.sh` 的 `abort() → restore_production → teardown` **順序**問題，
  但關切的是「還原毀掉 tmux pane 裡的中止原因」，**不是** ETXTBSY。
  狀態標 🏁 已修（`6c75bc3c`，改成先 `preserve_abort_evidence`）。
  ⇒ **本次 R2 是同一個函式的第二個順序問題，KNOWN-ISSUES 尚未記載。**
- **`:1756-1757`** 已記錄 `restore_production` ＝ `cp "$KBIN_BACKUP" "$KBIN"`、
  「七小時的實驗、兩次中止後的還原，全部靠這一份同碟副本」，
  關切的是**備援份數與碟**，**不是 cp 會不會成功**。
  ⇒ **R2 對這一條是新的一面。**
- **R1（還原原始碼不等於還原 fabric）在 `doc/KNOWN-ISSUES.md` 中查無對應條目。**
  唯一在 repo 裡寫下這件事的是 `run_ab.sh:73-76` 的註解（今天寫的）。

---

## 4. 排序：先修哪一支

依「**它的窗口最快會被用到**」排。各 round 目錄的最近 commit：

```
2026-09-02_recompute-paired-ab       7e553f35 2026-09-02 12:23:35   <- 正在跑
2026-09-01_cpu-matrix-1hz            a38bbdba 2026-09-02 00:30:38
2026-08-31_sampling-ceiling-after-merge  22ed1f76 2026-09-01 13:29:40
2026-08-31_f5-fine-grid-round        22ed1f76 2026-09-01 13:29:40
2026-08-25_sampling-rounds           939dcad4 2026-08-31 16:11:38
2026-08-20_sampling-rate-and-cpu     5ae3623e 2026-08-28 15:46:39
2026-08-25_large-scale-concurrent    5ae3623e 2026-08-28 15:46:39
2026-08-30_live-full-stack-round     1208d221 2026-08-30 20:11:52
```

1. 🔴 **`zero_cell.sh`** — **唯一一支「還原只改原始碼、完全不重編」的活腳本**，
   而且那條路徑掛在 **trap** 上，也就是**中止時必經**。它所屬的 09-01 輪是**倒數第二新**、
   commit 在 20 小時內，且它產出的 `mzs_*` 是 09-02 這一輪正在比對的對照組
   ⇒ 同一支腳本很可能再被跑一次。**後果最重（telemetry 全零）、觸發條件最常見（任一中止）、修改最小。**
2. 🔴 **`tools/test_workflow/ndt`** — 修 #1 之後，這是**唯一還會對人說謊的東西**。
   它不屬於任何一輪，**每一輪都用它**，而且 `ndt status` 正是「lab 還原了嗎」的標準答法。
   它現在對「完全不取樣」回答 `1/256`。**不修它，第 1 項的保護只在腳本內有效，人工查驗仍會被騙。**
3. 🟡 **`run_f5.sh`** — **F-5 從未真跑過**（`raw/` 只有 4 個檔、無 `run_f5.log`），
   所以現在改零風險、零重跑成本；而它在隊列裡的角色**就是**替鄰輪把關
   （`:274-276` 自己寫明要抓 E 輪的還原失敗）。**一個把關者帶著它要抓的那個缺陷，優先於任何已封存輪。**
4. 🟡 **`matrix_1hz.sh`** — 有 trap 缺口且**已經真的中止過一次**，但它的 happy path 會重編，
   且該輪的分析已於 09-02 00:30 收斂（`a38bbdba`）⇒ 重跑機率中等。
5. 🟢 **`lib_e.sh`** — R2 結構上在，但終局被 `cp -f`＋隨後的 `teardown` 抵銷，
   且五次 `restore_production` 全部驗證通過。**先改順序（兩行對調）成本極低**，
   斷言補強可併入 E 輪下次動它時。
6. ⚪ **08-20 / 08-25 D 族 / `run_e8.sh` / `stock_ladder.sh`** — 全部已封存且證實有還原
   （`run_e8` 除外，但其暴露窗已確認無人使用）。**不建議改**——改封存輪的腳本會讓
   「那一輪跑的是什麼」變得說不清楚。價值在於被引用為先例。

---

## 5. 我判斷不了的、以及人要接手做的

### 5.1 🔴 現場觀測：此刻 compiled pipeline 是「不取樣」——**但那是正常的**

我在 12:23–12:36 之間量到：

- **未提交觀測** `git diff -- p4_proxy/p4_src/ndtwin_switch.p4`：
  `:406` 由 `random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);`
  改成 `random(meta.sample_rand, (bit<16>)1, SAMPLE_RATE - 1);` ⇒ **取樣關閉**。
- `p4_proxy/p4_src/build/ndtwin_switch.json`（mtime `2026-09-02 12:23:36`）的
  `modify_field_rng_uniform` 參數 = **`['0x0001', '0x00ff']`** ⇒ 下界 1、上界 255。
  即**編譯產物與原始碼一致，且兩者都是「不取樣」**。

**這不是還原失敗。** `doc/audit/2026-09-02_recompute-paired-ab/run_ab.log` 最後一行是
`[12:30:57] ✓ condition holds` 之後的 `[ab_zero_1khz_r1_nopoll] ... 200Mbit/s for 300s`，
而我查看時是 12:35:58 ⇒ **那一輪的 300 秒 cell 正在跑**，現在的狀態就是它刻意架設的
zero-sampling A 臂。`run_ab.sh` 的 `restore_all()` 是全 repo 最正確的還原，會把它放回去。

🔑 **但這個觀測本身就是第 14 列那個發現的來源**：在這個狀態下，
`ndt status` 會說 **`sample rate 1/256 (compiled into ndtwin_switch.json)`**
（`ndt:579`，數值由 `:445 sample_rate()` 算出 `int(0xff,16)+1 = 256`），
而實際上**一個樣本都不會產生**。⇒ **儀器對它最該偵測的那一種狀態，回報的是生產值。**

**人要做的**：等 09-02 那一輪跑完，確認 `run_ab.log` 印出
`p4 predicate restored` / `p4 recompiled from the restored source` /
`production kernel restored, sha256 verified`，並**親自**重跑一次上面那段 rng 解析
確認回到 `['0x0000','0x00ff']`。**不要用 `ndt status` 當作驗收**——它現在分不出來。

**12:47 追加觀測（收工前重查）**：`ndtwin_switch.json`（mtime `12:46:18`）的 rng 已回到
**`['0x0000', '0x00ff']`**，`.p4` 原始碼的述詞回到 `(bit<16>)0`、`SAMPLE_RATE = 256;`，
且 `git status` 中 `p4_proxy/p4_src/ndtwin_switch.p4` **已不再是 modified**。
⇒ **`run_ab.sh` 的 `restore_all()` 確實落地了**——原始碼與編譯產物**同時**回到生產值，
這正是 R1 要求的形狀。⚠️ 我**沒有**判定該輪是跑完還是中止（兩者都會走同一個 trap），
也**沒有**核對 kernel binary 的 sha；那要看 `run_ab.log` 的收尾行，請人自行確認。

### 5.3 ⚠️ 我的 diff 的基準已經在動

收工重查時 `git status` 顯示 **`doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh`
已變成 modified**（**未提交觀測**；另一個 session 正在改 `cell_cpu_gate_finish()` 的
`suspect` / `unattributed_cores` 讀取，`:1091` 附近，與還原路徑無關）。
同時新增了 `tests/shell/mutate_cpu_gate_lifetime.sh` 等未追蹤檔。
⇒ **`RESTORE-SWEEP.patches/lib_e.sh.diff` 是對著 `7e553f35` 的已提交版本寫的**，
套用前必須重新對位。**不要**直接 `git apply`；也**不要**在那支 session 還在寫的時候動它。

### 5.2 我判斷不了的

1. **`audit-raw` branch 裡有沒有時戳落在 08-26 02:18–02:59 的 raw。**
   本地無 `audit-raw` 目錄，只有四個 branch ref。唯讀約束下我沒有 checkout。
   ⇒ **人要做**：`git log --format='%ci %s' audit-raw` 或在別處 clone 出來，
   確認那 40 分鐘沒有 raw 落地。**這是 Q1 唯一還沒關上的縫。**
2. **08-26 02:18:34–02:59:00 之間有沒有不寫 log 的手動量測。** 無從得知。
3. **`zero_cell.sh` 09-02 00:23 收尾時 compiled JSON 到底有沒有被正確重編。**
   `:135` 的 `p4c` 不讀 rc，`:138` 的證據行讀原始碼 ⇒ **log 證明不了**。
   唯一能證明的是當時 JSON 的 mtime 與內容，而該檔已在 12:23 被今天這一輪覆寫。
   ⇒ **永久不可考**。間接證據：09-01 輪之後的分析（`a38bbdba`「at zero sampling the two
   rounds agree」）與 09-02 輪 12:30 的 `VERIFY OK: traffic moved and every edge read zero`
   都與「當時是好的」相容，但**兩者都不是對那一刻的直接觀測**。
4. **`run_f5.sh:190` 說本輪 swap kernel binaries，但腳本裡沒有那個動作。**
   我找不到 F-5 用來換 binary 的東西（無 `sed -i`、無 `cp` 到 `$KBIN`）。
   ⇒ **人要做**：問 F-5 的作者，換臂是手動、還是漏寫、還是註解過期。
   **這關係到 `assert_kernel_restored` 到底在守什麼。**
5. **`cp -f` 在這台機器上遇到 ETXTBSY 的實際行為**（GNU coreutils 會 unlink 重建）
   我是**依文件與語意推論**，**沒有實測**——實測需要一個活著的 stack，超出授權。
   ⇒ 我對第 3.2 節「`cp -f` 抓不到」的信心是**高但非實測**。人要驗的話，
   在**空閒**時開一個無關的長跑行程對它自己的 binary 做 `cp -f` 即可，不必動 lab。

---

## 6. 給 Adam 的待決問題（選項＋後果）

**Q-A. `zero_cell.sh` 的修法要多重？**

- **(A1) 只補 `p4c`＋rng 斷言（建議）** — 我寫的 diff。
  後果：中止路徑從「靜靜留下不取樣的 fabric」變成「還原並驗證，失敗就大聲＋落 marker」。
  改動小、不動量測邏輯，該輪資料不受影響。
- **(A2) A1 ＋ 把 marker 檔改成 `ndt` 開跑前會擋的東西。**
  後果：保護從「腳本內」變成「全機」，但要動 `ndt`（共用工具），diff 變大且需要新測試。
- **(A3) 先不修，只寫進 KNOWN-ISSUES。**
  後果：下一次中止仍會留下不取樣的 fabric，而**沒有人看得出來**。
  ⚠️ 我不建議：這一支的 trap 就是中止時必經的路徑。

**Q-B. `ndt sample_rate()` 的盲區怎麼處理？**

- **(B1) 讀兩個界，下界非 0 就回報 `DISABLED`（建議）** — `ndt.diff`。
  後果：`ndt status` 從「說謊」變成「說對」。⚠️ 但這會**改變 `status` 的輸出格式**，
  任何 parse 它的東西要一起看（我沒有全面查過誰在 parse）。
- **(B2) 不動 `sample_rate()`，另加一行獨立的 `sampling: ON/DISABLED`。**
  後果：不動既有輸出，但多一行；「1/256 且 DISABLED」同時出現時讀者要自己會意。
- **(B3) 不動。**
  後果：R1 的修法只在腳本內有效；操作者人工用 `ndt status` 驗收時仍會被騙——
  而那正是「離開前確認 lab 還原了」的標準動作。

**Q-C. 要不要抽共用 helper（`tools/test_workflow/p4_restore_lib.sh`）？**

- **(C1) 抽，新 round 一律 source 它，舊 round 不動（建議）。**
  後果：止血。已封存輪維持原樣（它們的腳本＝它們跑了什麼的紀錄，不該回頭改）。
  代價：新增一個共用檔，要自己的測試（mutation gate）。
- **(C2) 不抽，逐輪修。**
  後果：目前有 **12 份 `compile_at` 抄本**；修一份不修其他份，
  而**下一輪多半是從最近一輪 copy 出來的** ⇒ 缺陷會繼續複製。
- **(C3) 不抽也不修，只在 PREREG 模板裡寫一段「還原必須驗編譯產物」。**
  後果：靠人記得。`run_c.sh:46` 已經記錄過一次「上一輪沒還原」真的發生。

**Q-D. `run_e8.sh` 那 40 分鐘的窗，要不要正式關掉？**

- **(D1) 由人查 `audit-raw` 確認無 raw 落在窗內，然後在 KNOWN-ISSUES 記一條「已查、無污染」（建議）。**
  後果：把「沒去找」與「找過沒有」分開——這正是 KNOWN-ISSUES `:1698` 自己記取的教訓。
- **(D2) 當作已知無害，不查。**
  後果：留下一個**看起來已解決、其實沒查過**的缺口。

---

*[Co-developed with claude code -- Adam]*
