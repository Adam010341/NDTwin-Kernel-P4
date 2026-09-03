# FIX — finding #50: `2>/dev/null` after `<` cannot suppress the open

分支 `fix/redirection-order`，sha `42a0b52f`（base `feb9baef`）。
本文件的圖表數字全部來自本機實跑，log 路徑列在第 ③ 節。

[Co-developed with claude code -- Adam]

---

## ① 一句話

Redirection 由左而右套用，所以 `cmd < FILE 2>/dev/null` 在 fd 2 還是繼承來的 stderr 時就去開檔——
**它擋掉了所有訊息，唯獨擋不掉它唯一要擋的那一則**；全 repo 十五處同形，一次修完，並補上雙面 mutation gate。

---

## ② 行為變更前後對照

### 機制（本機實測，非推導）

| 寫法 | rc | stderr |
|---|---|---|
| `mapfile -d '' -t x < /proc/999999/cmdline 2>/dev/null` | 1 | `bash: /proc/999999/cmdline: No such file or directory` |
| `mapfile -d '' -t x 2>/dev/null < /proc/999999/cmdline` | 1 | *(空)* |
| `tr '\0' ' ' < /proc/999999/cmdline 2>/dev/null`（外部指令） | 1 | `bash: ... No such file or directory` |
| `tr '\0' ' ' 2>/dev/null < /proc/999999/cmdline` | 1 | *(空)* |
| `v=$(tr '\0' ' ' < /proc/999999/cmdline 2>/dev/null)`（在 `$( )` 裡） | 1 | `bash: ... No such file or directory` |
| `cat /proc/999999/comm 2>/dev/null`（**檔名是引數不是重導向**） | 1 | *(空)* — 本來就對，不用改 |

builtin 與外部指令都會漏：外部指令是 fork 後在子行程套 redirection，順序規則一樣。

### 修掉的十五處（一律把 stderr 重導向移到輸入重導向之前）

| # | 位置 | 靜音對不對？判斷 |
|---|---|---|
| 1 | `tools/test_workflow/ndt:1687` `pid_is_app` | **對**。函式契約就是「這個 pid 可能已經不在」，註解已寫明。這就是 09-02 洩到 audit log 的那一處 |
| 2 | `tools/test_workflow/ndt:1999` `app_stop` | **對**。印一個剛剛還活著的 pid 的 argv；它沒了就印空的，不是錯 |
| 3 | `tools/test_workflow/ndt:2034` `apps_orphans` | **對**，同上 |
| 4 | `tools/test_workflow/ndt:894` `up_ovs` | **這裡的 `2>&1` 不是靜音，是把輸出收進 `$out`**。`mkfifo` 在 861 行，開檔失敗機率低；但真失敗時訊息會噴到終端機，而錯誤路徑印的是 `$out`——**診斷跟印它的地方被拆開**。改順序後失敗會落進 `$out` |
| 5 | `tools/test_workflow/test_teardown_guards.sh:48` | **對**。掃整個 `/proc`，pid 在 glob 與 read 之間消失是常態，這處在實務上必漏 |
| 6 | `tests/shell/test_ndt_app_orphans.sh:128` | **對**。重試迴圈，前幾輪讀不到本來就是預期狀態 |
| 7 | `tests/shell/test_ep4_gate_and_abort_evidence.sh:119` | **對**。`find` 找不到時 `$empty_file` 是空字串，但 `check` 那格會紅，失敗仍有人報 |
| 8 | `tests/shell/test_preflight_instrument_self_failures.sh:165` | **對**。`else` 分支有 `t_bad` 明講「fixture listener 沒回報 port」 |
| 9 | `tools/remote-lab/host_witness.sh:100` | **對**。註解寫明 kernel thread 的 cmdline 是空的、那是定義不是啟發式 |
| 10 | `tools/remote-lab/ndtwin-vm.sh:188` | **對**，`/proc` 全掃 |
| 11–12 | `tools/remote-lab/ndtwin-vm.sh:209,263` | **對**，呼叫端剛列舉過的 pid |
| 13–14 | `tools/remote-lab/ndtwin-vm.sh:832,847` | **對**，報表列印 argv |
| 15 | `tools/remote-lab/p4_patch_preflight.sh:61` | **對**（靜音的是 `patch` 自己的輸出，判斷看 rc；上方另有 `[ -f "$f" ]` 守衛）。順序仍改，屬縱深防禦 |

### 刻意**不改**的五處

`tests/shell/test_up_ovs_wedge_guard.sh:48,56,62,68` 與 `tools/git-hooks/post-commit:205`，全部是 `< /dev/null`。
`/dev/null` 是保證存在的字元裝置，**開檔不會失敗 ⇒ 形狀在、但路徑走不到**。
改它們對行為零影響，只會擴大跟其他分支的衝突面。

### 掃到但不屬於本次口徑的

- **Class C（`2>&1` 排在 `>file` 之前，stderr 會跑去舊的 stdout）：口徑內 0 處。**
- **Class D（順序對但目標寫錯：`/dev/nul`、`2>$未設變數`、`2>&非1`）：口徑內 0 處。**
- **Class B（`>file` 排在 `2>` 之前）**：5 處目標是另一個檔（`test_iperf3_guard.sh:111,113`、
  `test_preflight_…:163`、`test_slim_client_json.sh:75`、`p4_coverage_gate.sh:64`），
  其餘是 `>f 2>&1` 這個標準慣用法。這些只有在**輸出**開檔失敗時才漏，且目標目錄都由 harness 當場建立 ⇒ 判定不是缺陷，未改。
- `doc/audit/**` 底下 400 餘個歷史腳本**掃了但沒改**：那是各輪跑過的存證，改它們等於竄改紀錄。

---

## ③ 閘門證據

### 範圍怎麼找的（以及完整性怎麼證）

`grep '2>/dev/null'` 會漏 `$( )` 裡的、backtick 的、`&>` 的，而且**它根本問不到「順序」**。
所以用一支 quote／comment／heredoc／command-substitution 都認得的 **lexer**，逐個 simple command
收集「有序的 redirection 清單」再套規則。工具本身先自我驗證過：

1. **fixture 自我驗證** — 16 種形狀（builtin／外部指令／`$( )`／backtick／`while…done`／`{ }`／`( )`／
   `exec 3<`／`&>`／`2>>`／無空白／多空白／heredoc body／here-string／引號內文字／註解），
   全部命中，且「順序正確」「檔名是引數」「process substitution」等 7 種正確寫法零誤報。
   *第一版 lexer 漏掉 `"$(… < f 2>/dev/null)"`——正是 ndt:1999／2034 的形狀——因為雙引號被整段跳過；修掉才開始信它。*
2. **交叉檢查（獨立方法）** — 另寫一支「引號盲」的粗 regex 掃全部 452 個 shell 檔，得 177 條候選行；
   lexer 的 88 條是它的**真子集**（`comm -13` = 0）。口徑內候選共 **35 條**，
   **35 條全部逐條裁決**：20 條是真的（lexer 命中），15 條是粗 regex 的誤判——
   `bit<16>` 在字串裡、`dnspython<2.3` 在字串裡、註解、`< <(cmd 2>/dev/null)` 的 process substitution
   （`2>` 屬於內層指令）、`"$@" 2>&1 </dev/null`（順序本來就對）、
   以及 `( exec 3<>"/dev/tcp/…" ) 2>/dev/null`（`2>` 掛在**子 shell**上，先套用 ⇒ 正確）。
3. **原地注入實驗（測偽陰性率）** — 把 12 種變體注入 `tools/test_workflow/ndt` 的真實上下文，
   60 次注入 60 次命中。再擴大到口徑內全部 86 個檔案：**3084 次注入，195 次未命中**。
4. **未命中的 195 次全部用 bash 自己的 parser 裁決** — 在同一位置改注入 `;;;`（活的 shell 語境必為語法錯誤），
   `bash -n` 仍然通過 ⇒ 那個位置在 heredoc body 或字串字面值裡，**不是 shell 程式碼**。
   結果 **195/195 全部落在 heredoc／字串內**，live-shell 語境命中率 **2889/2889 = 100%**。
   對照組：5 個已知活語境注入 `;;;`，5/5 都被 `bash -n` 判為語法錯誤（證明這個裁決有鑑別力，不是恆真）。

> 一度以為 `ndt` 1484–1592 有盲區，追下去發現那是 `<<'PY'` 的 Python heredoc body——
> **掃描器是對的，是注入實驗把探針種進了非 shell 區域。**

### 🔴 修法前那次紅（必要證據）

`tests/shell/test_redirection_order.sh` 指向從 `feb9baef` 直接 `git archive` 出來的乾淨舊樹：

```
$ REPO_UNDER_TEST=<feb9baef 的樹> NDT_UNDER_TEST=<同上>/tools/test_workflow/ndt \
    bash tests/shell/test_redirection_order.sh

2. ndt's pid_is_app, with /proc re-bound to a fixture
  FAILED   🔑 pid_is_app is SILENT when /proc/<pid>/cmdline is gone
             expected: []  actual: [/tmp/redir-order-xixHX6/h.sh: line 14:
                                    /tmp/redir-order-xixHX6/proc/700/cmdline: No such file or directory]

3. the two report paths that print an argv (ndt app_stop / apps_orphans)
  FAILED   app_stop's argv line is silent for a pid that cannot exist
             expected: []  actual: [... line 54: /proc/4194305/cmdline: No such file or directory]
  FAILED   apps_orphans' argv line is silent for a pid that cannot exist
             expected: []  actual: [... line 54: /proc/4194305/cmdline: No such file or directory]

5. the rest of the family
  FAILED   test_teardown_guards.sh (args="$(tr) is silent
  FAILED   test_ndt_app_orphans.sh (mapfile -d '' -t argv) is silent
  FAILED   test_ep4_gate_and_abort_evidence.sh (hdr=$(wc -c) is silent
  FAILED   test_preflight_instrument_self_failures.sh (read -r LPORT) is silent
  FAILED   host_witness.sh (IFS= read -r -d '' cmd) is silent
  FAILED   ndtwin-vm.sh (a0=""; IFS= read) is silent
  FAILED   ndtwin-vm.sh (cut -c1-200) is silent
  FAILED   ndtwin-vm.sh (/^-m$/{getline;m=$0}) is silent
  FAILED   p4_patch_preflight.sh (patch -p1 --dry-run) is silent
             tools/remote-lab/ndtwin-vm.sh:209:  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | awk '
             tools/remote-lab/ndtwin-vm.sh:263:  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | awk '
             tools/test_workflow/ndt:894:        bash "$STACK" up ovs < "$fifo" > "$out" 2>&1 ) &
  FAILED   static guard: the 3 multi-line sites keep 2> ahead of < (3 lines read)
             expected: [3 0]  actual: [3 3]

Ran 25 checks, 13 failed
EXIT=1
```

**25 格裡 13 格紅，十五處修法每一處都有代表。** 修法後同一支測試 `Ran 25 checks, 0 failed`。

### 測試怎麼繞開「前面的檢查遮住後面的」

`pid_is_app` 一開頭就 `[[ -d "/proc/$pid" ]] || return 1`，所以**「確定不存在的 pid」根本走不到那行讀取**——
從正門測會對著壞掉的程式碼變綠。真實現場需要 pid 在 `-d` 與讀取**之間**死掉，那是測試排不出來的 race。
所以測試把函式從真的 `ndt` 用文字**整段抬出來**、把 `/proc` 換綁到 fixture 目錄，再拿一個
「目錄在、cmdline 不在」的 pid 去呼叫——**同一個狀態，改成可達**。
換綁次數有斷言（≥3 條移走、0 條還指著真 `/proc`）：偷偷沒換綁的副本會去讀真 `/proc`、
一樣找不到東西，那看起來跟通過**一模一樣**。

### 🔴 雙面：兩種「比 bug 更糟的綠」

| 變異 | 為什麼危險 | 被哪一格擋住 |
|---|---|---|
| **M15** 在 `pid_is_app` 開頭插 `exec 2>/dev/null` | 連帶吞掉這個函式**未來所有**的診斷；每一格「是否安靜」都會變綠 | `🔑 a REAL error inside pid_is_app still reaches the caller`（stub 的 `app_sig` 往 stderr 寫字，必須看得到） |
| **M16** 整行讀取直接刪掉 | 沒開檔就不會漏；每一格「是否安靜」也都會變綠 | `pid_is_app MATCHES from cmdline when comm says otherwise (rc 0)`（fixture 701 的 `comm` 故意寫不相符，rc 0 只可能來自讀 cmdline） |

### mutation gate

```
$ bash tests/shell/mutate_redirection_order.sh
baseline (must be green before any mutation):
Ran 25 checks, 0 failed
  caught   M1  … M16      （16 行全部 caught）
baseline byte-identical: yes (all 8 source files)
mutation gate: 16 mutations, 0 survived
```

M1–M14 把十五處逐一改回舊順序（`ndtwin-vm.sh:209/263` 兩處錨點相同，用 count=2 一起改），
M15／M16 是上表的雙面關卡。`report()` 除了要求指名的那格變紅，**還要求結尾 `Ran N checks` 與 baseline 相同**——
只看「某格紅了」會被「測試中途死掉」冒充。變異一律套在 temp tree 的**副本**上，
跑完比對 8 個原始檔的 sha256（`baseline byte-identical: yes`），共用工作樹不會被寫到。

### 連帶回歸（被我改到的既有測試）

| 測試 | 結果 |
|---|---|
| `tests/shell/test_ep4_gate_and_abort_evidence.sh` | `12 passed, 0 failed` |
| `tests/shell/test_ndt_app_orphans.sh` | `Ran 52 checks, all passed` |
| `tools/test_workflow/test_teardown_guards.sh` | `14 passed, 0 failed` |
| `tests/shell/test_preflight_instrument_self_failures.sh` | **沒跑** — 它會 bind loopback port，違反今晚的純離線口徑 |
| `tools/remote-lab/*` | **沒跑** — 目標是遠端 VM |

### 這次沒有動到實驗環境

沒有 `ndt up`、沒有 Mininet／bmv2／OVS、沒有綁 port、沒有 `pkill -f`／`pgrep -f`。
測試只讀 `$TMPDIR` 底下的 fixture 目錄，以及一個大於 `/proc/sys/kernel/pid_max` 的 pid（4194305）。

---

## ④ 合併順序與衝突（`git merge-tree --write-tree` 實測，不是猜的）

全部 local branch 逐一比對，**六支**會動到 `tools/test_workflow/ndt`
（除了任務點名的三支，另外三支是 `fix/g7-ndtwin-lab-config`、`fix/ndt-sudo-surface`、`t8-t10-fixes`）。

| 對方分支 | merge-tree | 合併後樹裡還剩的同形位置（用同一支 lexer 掃） |
|---|---|---|
| `fix/g6-ndt-apps-liveness` | **CLEAN** | 🔴 **還剩 1 處：合併後 `ndt:2020`** |
| `fix/ports-that-block-restart` | **CLEAN** | 0 |
| `fix/g9-cleanup-no-pkill-f` | **CLEAN** | 0 |
| `fix/g7-ndtwin-lab-config` | **CLEAN** | 0 |
| `fix/ndt-sudo-surface` | **CLEAN** | 0 |
| `t8-t10-fixes` | CONFLICT | 見下 |

### `fix/g6-ndt-apps-liveness`：乾淨合併，卻把形狀帶回來

g6 新增了一行 `ndt` 沒有的：

```
err "   pid $pid: $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)"
```

它在我的 base 之後才寫的，所以不在我的十五處裡；git 會**安靜地** auto-merge，沒有任何衝突提示。
**⇒ g6 落地之後要補這一行**（同樣把 `2>/dev/null` 移到 `<` 前面）。
本次的閘門抓不到它：測試的錨點是逐處指名的字串，不是全域掃描。

### `t8-t10-fixes`：衝突是既有的，不是我造成的

對照組實測：`git merge-tree --write-tree feb9baef t8-t10-fixes`（**沒有我的改動**）
已經在同樣五個檔案衝突（`ndt` 與 `doc/audit/2026-08-30_live-full-stack-round/harness/` 底下四個）。
`t8-t10-fixes` 的 merge-base 是 `09c9b032`，落後很多。

我的四個 hunk 裡有**一個**落在既有衝突區內：`pid_is_app` 的那行落在合併結果 1692–1715 這個衝突區中間
（`ndt:894`、`app_stop`、`apps_orphans` 三處都在衝突區外、乾淨合併）。
⇒ **不會新增衝突區，但解那一區時要記得把修好的那行留下。**

### 建議合併順序

1. 先合 `fix/redirection-order`（跟五支之中的四支零衝突，且不碰任何 `ndt` 既有語義）。
2. `fix/ports-that-block-restart`／`fix/g9-cleanup-no-pkill-f`／`fix/g7-ndtwin-lab-config`／
   `fix/ndt-sudo-surface` 任意順序。
3. `fix/g6-ndt-apps-liveness` 之後 **必須補 `ndt:2020` 那一行**，否則 finding #50 在 trunk 上復發。
4. `t8-t10-fixes` 另案處理：它跟 trunk 的衝突與本分支無關，先 rebase 到現在的 trunk 再談。

檔名沒有碰撞：沒有任何分支存在 `tests/shell/{test,mutate}_redirection_order.sh`。

---

## ⑤ 回退方式

```bash
git revert 42a0b52f            # 十五處改回去，兩支閘門腳本一併移除
```

或只退程式碼、留閘門（閘門會立刻變紅，這是它該有的行為）：

```bash
git checkout feb9baef -- \
  tools/test_workflow/ndt tools/test_workflow/test_teardown_guards.sh \
  tests/shell/test_ndt_app_orphans.sh tests/shell/test_ep4_gate_and_abort_evidence.sh \
  tests/shell/test_preflight_instrument_self_failures.sh \
  tools/remote-lab/host_witness.sh tools/remote-lab/ndtwin-vm.sh \
  tools/remote-lab/p4_patch_preflight.sh
```

風險很低：十五處全是同一行內把兩個 redirection 對調，成功路徑的行為逐字不變
（`ndt:894` 是唯一有行為差的一處，而差別是「失敗訊息改成落進 `$out`」，方向是變好）。

---

## ⑥ 未處理

1. **`fix/g6-ndt-apps-liveness` 帶回來的 `ndt:2020`。** 已實測、已寫在第 ④ 節；
   它在別人的分支上，本 session 不動別支。
2. **閘門只守指名的十五處，不守「未來新增的同形」。** 測試的錨點是逐處字串。
   真正該有的是一條 repo 級的 lint（就用本次那支 lexer），跑在 pre-commit 或 L1。**本次沒做。**
   那支掃描器目前只在我的 scratchpad，沒有進版控。
3. **`tests/shell/test_preflight_instrument_self_failures.sh` 沒有實跑。** 它會 bind loopback port，
   違反今晚的純離線口徑；那一行的修法只由新測試的行為性案例覆蓋（該案例把 `$T` 指到不存在的目錄）。
4. **`tools/remote-lab/` 的三個檔（6 處）沒有在真實情境跑過。** 它們的目標是遠端 VM／`nslab`，
   本次只做了「把那一行抬出來、餵不可開啟的路徑、斷言 stderr 空」的行為性驗證，沒有跑整支工具。
5. **Class B 的 5 處沒改**（輸出重導向排在 `2>` 之前）。判定不是缺陷，理由寫在第 ② 節，
   但它是同一個機制的另一面，若哪天有人把輸出目標改成不保證存在的路徑就會咬人。
6. **`doc/audit/**` 底下的歷史腳本沒改**，那是存證。若之後有人從那裡複製程式碼進 `tools/`，形狀會回來。
7. **沒有 push。** 依今晚的指示。
