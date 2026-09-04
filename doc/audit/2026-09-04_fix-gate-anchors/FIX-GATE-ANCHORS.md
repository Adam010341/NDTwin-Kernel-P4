# 閘門修錨:tests/shell/check_gate_anchors.py 15 個壞格

（2026-09-04 夜巡;worktree `scratch/overnight-2026-09-04/wt-anchors`,branch `fix/gate-anchors-0904`,
未 push、未合進 trunk。）

## 結果

`python3 tests/shell/check_gate_anchors.py HEAD` 在 trunk `f943de8f` 上:53/68 ok,15 not ok
(其中 10 格 NOT CHECKED AT ALL)。修完在本 worktree HEAD `c30d130f` 上:**66/68 ok,2 not ok
(其中 1 格 NOT CHECKED AT ALL)**。exit code 仍是 2(`mutate_redirection_order.sh` 還在
UNPARSED,見下)。

- before log:`scratch/overnight-2026-09-04/fix/anchors-before.log`
- after log:`scratch/overnight-2026-09-04/fix/anchors-after.log`
- 9 個 commit,`f943de8f..c30d130f`(見文末列表)

15 格裡面,**5 格是閘門腳本本身的 anchor 真的漂了**(改閘門的 anchor 字串,沒碰產品碼);
**8 格是 checker 讀不懂閘門既有的寫法**(改 `check_gate_anchors.py`,補測試);**1 格兩者都是**
(`mutate_ports_that_block_restart.sh`,閘門本身沒壞,但 checker 的舊寫法會讓它在真的跑的時候
悄悄 mutate 錯地方,順手也修了);**1 格沒修**(`mutate_redirection_order.sh`,根因完全查清楚了,
但修法會動到全部 68 個閘門共用的 env 解析,今晚沒把握在跑不了保護閘門本身的情況下驗證乾淨)。

## 逐格

### 五個閘門腳本真的漂了(只改 anchor 字串,產品碼沒動)

| 閘門 | 原狀態 | 原 anchor 出了什麼事 | 改法 | commit |
|---|---|---|---|---|
| `mutate_a2_poll_round.sh` | MISSING:3 | Round 6 N1 把逐端點字串判斷(`linksAnswered = !linksBody.empty()`)換成 `EndpointOutcome`/`EndpointReply`。mutation #5(🔴「發明故障」那條,最重要的一條)的 anchor 整個消失;#10、CTRL_ANCHOR 只是參數改名(`switchesStr`→`switchesReply`,`switchesAnswered`→`switches.outcome`)。 | #5:重新定位到 `classifyEndpointReply` 的 `bodyIsBlank` 那行——`TopologyAndFlowMonitor.cpp` 自己的註解說「the emptiness rule ... moved into classifyEndpointReply」,不是用猜的。#10、CTRL:純改名跟過去。 | `c1514d8b` |
| `mutate_a7_dispatch_status.sh` | DUP:1 | `table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"` 現在 `api_routes.py` 裡出現兩次(`_priority_disclosure()` helper 一次、`add_flow_entry()` 內聯一次)。**這不只是 checker 誤報**——`mutate()` 用 `s.replace(a, r, 1)`,先按檔案順序命中第一個,也就是說沒修的話這支閘門會**悄悄 mutate 錯函式**(`_priority_disclosure`,而 mutation #4 跟它的 expected test 講的是 `add_flow_entry`)。 | 把 anchor 擴成兩行(帶進下一行 `body = {...}` 當去重上下文),精準命中 `add_flow_entry` 那份。negative control 同樣處理。 | `c1514d8b` |
| `mutate_f6_stale_table_carry_forward.sh` | MISSING:1 | `doc/KNOWN-ISSUES.md` B-1 的 2026-09-02 review 在呼叫前面加了回傳值擷取(`const std::size_t withheld = `),mutation #7 的呼叫本身沒搬家。 | anchor 補上 `const std::size_t withheld = ` 前綴,語意不變。 | `c1514d8b` |
| `mutate_g6_apps_liveness.sh` | NO-ANCHORS(checker 問題,見下)+ 1 格真漂 | case `notrunning-rc-zero`:poisoned-pidfile 的 guard(`if [[ "$poisoned" == 0 && -e "$p" ]]; then rm -f "$p"; ...; fi`)加進來,把目標兩行從 20 space 推深到 24 space,且原本跟 `fi ;;` 同一行的 `return 2` 現在自己一行。 | anchor 改成現在的兩行(24 space,不含 `;;`),replacement 同步。 | `e020805e` |
| `mutate_check_gate_anchors.sh`(自己這場修錨過程中被我弄壞、當場修好) | 我編輯 `is_whole_param_ref` 時順手改掉了它的 M4 mutation 目標到的那行 | M4 pin 的是 `is_whole_param_ref` 的完整 `return` 敘述(舊版一行),我加 `\|[0-9]+` 那條分支時它變兩行。 | anchor 換成新的兩行敘述,mutation 語意不變(砍到 `return False`)。 | `708418d0` |

### 八個是 checker 讀不懂,不是閘門的錯(路徑 (b):改 `check_gate_anchors.py` + 補測試)

| 閘門 | 原狀態 | checker 的限制是什麼 | 修法 | commit |
|---|---|---|---|---|
| `mutate_g6/g7/g9_cleanup/g9_faults_topo_pid` 四支 | NO-ANCHORS | `write_case <name> <expect> <<'PAIR' <FROM> @@@TO@@@ <TO> PAIR`——mutation table 存在 heredoc 裡,heredoc 內容是純文字不是 python,`_py_anchors` 找不到東西可讀。 | 新增一個 pass:認出 `@@@TO@@@` 單獨一行(跟 applier 自己 `pair.split("@@@TO@@@\n")` 那種被雙引號包住、後面接 `\n` 兩個字元的用法區分開),切出 FROM 文字,歸屬到「函式本體裡真的含有這個 marker 當 python 原始碼」的那個函式(不是猜、不是隨便挑第一個有 baked-in 檔案的函式——這四支都另外有 `run_suite()` 之類會誤導的函式)。 | `e020805e` |
| `mutate_build_guard.sh`、`mutate_ndt_up_target.sh` | NO-ANCHORS | `cat > "$DIR/<name>.old" <<'EOF' ... EOF`(`.new` 同理)——mutation table 是**檔案**不是 shell word(閘門自己註解說第一版用 printf packing 弄丟過 6 個 mutation)。`cat` 在 `NOT_APPLIERS` 裡,`_py_anchors` 對 heredoc 只認 python。 | 新增 pass,配對 `.old`/`.new` 檔名裡的 `<name>`,歸屬同上(找真的讀回兩個檔尾碼的函式)。`mutate_build_guard.sh` 多一層:applier 的目標檔**逐 case 不同**(`mutant <name> <rel>`),透過 `check()` 自己的具名角色(`rel`,新增進 `ROLE_FILE`)在呼叫點解析,跟 applier 自己 baked-in 的目錄組合。 | `fcf05761` |
| `mutate_harness_instruments.sh` | DUP:1 | anchor 是裸 `s.replace(old, new)`(沒帶 count 引數——Python 預設「全部取代」),而它是**故意的**:FINDING-02 Defect B 的 hidden-owner sentinel 在 lib.sh 裡有兩個呼叫點都要塌陷,checker 卻假設每個 anchor 都只想要 1 個命中。 | `_replace_call_want`:裸的二引數 `.replace()` 讀成「至少 1,沒有上限」(`want=None`),第三個字面整數引數當精確 count(跟 `apply_exact` 的慣例對齊),讀不準的一律退回舊行為(want=1)。 | `c1514d8b` |
| `mutate_logger_cli.sh` | MISSING:1 | `is_whole_param_ref` 的正則要求變數名第一個字元是字母/底線,漏掉純數字的位置參數(`$1`..`$9`)——`widen()` 把自己的 `"$1" "$2" "$3"` 轉呼叫給具名角色的 `apply()`,`$2`(對應 `apply` 的 `anchor` 角色)被讀成兩個字元的字面文字 `$2`。**函式自己的 docstring 早就把 `"$1"` 列為範例**,下游 `role_position` 那段甚至已經有一條 `name.isdigit()` 的死碼分支在等這個情況——這是本來就該做的事,不是新發明的規則。 | 正則加 `|[0-9]+` 分支。 | `c1514d8b` |
| `mutate_flow_rate_denominator.sh` | UNPARSED(5 個「no target file」) | `SFT=include/....hpp   # 註解` 這種帶行尾註解的宣告——`scalar_assignments` 的正則要求整行剩下的部分是空白,行尾註解讓整條 regex 不匹配,`SFT`/`FLUC`/`FHDR` 全部沒被讀到。 | 正則加一段可選的 `[ \t]+#.*`(要求註解前面有空白,符合 bash 自己「`#` 何時算註解」的規則,`X=a#b` 不受影響)。 | `138e69a6` |

### 一格閘門本身沒壞,但 checker 舊寫法會讓它在真的跑的時候 mutate 錯檔案(路徑 (a) 改寫成 checker 認得的字面形狀)

| 閘門 | 原狀態 | 發生什麼事 | 改法 | commit |
|---|---|---|---|---|
| `mutate_make_topology_stdout.sh` | NO-ANCHORS | applier 叫 `mutant`(不是字面上的 `mutate`),checker 只認字面 `mutate`;anchor/repl 是裸引數,目標檔 baked 進 `mutant()` 自己的 body。 | 加 `local name="$1" old="$2" new="$3"`(讀不到別的地方,純粹讓 `param_roles` 看得懂),不改任何實際邏輯。 | `196da630` |
| `mutate_ports_that_block_restart.sh` | NO-ANCHORS → 改完 MISSING:1(8/9 ok) | 全部 9 個 mutation 把 anchor+repl 包進**一個**執行期算出來的引數:`"$(printf 'old\x1fnew')"`。checker 的設計原則明講「絕不評估 command substitution 會算出什麼」——這是刻意的邊界,不是漏洞。閘門本身沒問題,但這個包裝方式讓它對 checker 完全不透明。 | `mutant()` 改吃兩個明確引數(`old`/`new`,具名角色),9 個呼叫點解包成字面文字。**逐一驗證過**:寫一個只擷取引數、不寫檔不跑 python 不跑測試的 stub `mutant()`,分別餵原始 9 行呼叫跟改寫後的 9 行呼叫,base64 比對 old/new 逐位元組相同——9/9 相同。8/9 anchor 現在 `ok`;第 9 個(M9,唯一目標是 `tools/test_workflow/ndt` 而非 `ports.sh`)見下「未解決」。 | `55f34812` |

### 未解決(2 格)

**`mutate_ports_that_block_restart.sh` 的 M9(MISSING:1,不是 NOT CHECKED)。**
`mutant()` 的 body 同時 bake 進 `$PORTS` 跟 `$NDT`(不管哪個 case,兩個檔都複製進暫存目錄),
`default_file_of` 只會回傳掃到的第一個(`$PORTS`)。M9 呼叫時把檔案引數寫成裸字面 `ndt`
(沒有副檔名,`_BARE_FILENAME` 需要 `.` 才算,`path_at` 也只認變數參照不認裸字面),所以完全沒有
訊號可以分辨這一個 case 要的是 `$NDT` 不是 `$PORTS`。**失敗方向是安全的**——回報 MISSING(count=0),
不是假的 `ok`。真正的 anchor 文字本身在 `tools/test_workflow/ndt` 裡確認存在且唯一(見
`anchors-after.log` 前一版的驗證紀錄),閘門邏輯沒問題,只是這一格 checker 讀不到。

**`mutate_redirection_order.sh`(UNPARSED,2 個 `$A2`/`$A2b` 讀不到)。**
閘門自己的註解(第 113-121、137-141 行)已經記錄了完整的來龍去脈:作者曾經把這兩個 case 改寫成
跟其他 4 個新加的 case 一樣的 `$(printf ...)` 形式,結果讓 checker **整支閘門讀到 0 個 anchor**
(2026-09-03 量過),所以刻意留在「變數形式」——寧可 2 格讀不到,不要 0 格讀得到。

我把根因完全查清楚了,分兩層:
1. `A2='...'; B2='...'` 兩個賦值同一行,用 `;` 隔開。`quoted_assignments` 的正則要求
   `^\s*NAME=` 只認**行首**,B2 完全掃不到;A2 雖然掃得到開頭,但收尾檢查要求「關閉引號後,
   這行剩下的部分要是空白」,`; B2=...` 不是空白,A2 也被丟棄。
2. 更深一層:即使把兩個賦值拆成各自一行,A2/B2 的值本身用了 bash 的 `'"'"'` 技巧在單引號字串裡
   內嵌字面單引號(為了塞進 `$(tr '\0' ' ' ...)`)。`quoted_assignments` 的掃描器是逐字元找
   「下一個跟開頭同款的引號字元」,不懂這個技巧,會在**第一個**內嵌 `'` 就以為值結束了——
   已經實測確認(見下)。

**驗證過一條可行的修法,但今晚沒有把它落地**:`split_commands()`(這支 checker 已有、被
`extract()` 到處呼叫的分詞器)本來就懂引號拼接跟 `;` 分隔——直接餵它整行 `A2='...'; B2='...'`,
它正確切成兩個各含一個字的獨立命令,且值裡的內嵌單引號被正確還原:

```
word: 'A2=info "  pid $pid: $(tr \'\\0\' \' \' 2>/dev/null < "/proc/$pid/cmdline" | cut -c1-' quote: "'"
word: 'B2=info "  pid $pid: $(tr \'\\0\' \' \' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-' quote: "'"
```

要修,對的路是讓 `quoted_assignments`(或一個新函式)吃 `split_commands` 的輸出,而不是繼續補
那支手寫的逐字元掃描器。**沒動手的原因**:這條路會改到 `env` 的组裝方式,而 `env` 是全部 68 支
閘門共用的——今晚的規則不准跑 `mutate_check_gate_anchors.sh`(它是保護 `check_gate_anchors.py`
自己那支閘門),沒有它我沒辦法用「跑過保護閘門」的把握程度驗證這種核心改動,只能靠重跑
checker 全表 + `tests/python/test_check_gate_anchors.py` 這兩層對帳,信心不到能動全域解析路徑
的程度。留給白天:有 build lock 可以正常跑閘門的時段再做。

## 額外修的東西(任務第 4 點,不是 anchor 問題)

`tests/shell/mutate_flow_rate_denominator.sh:40` 原本把 `BUILD_LOCK`/`BUILD_SHIM` 指到**某一個
特定 agent session 自己的 scratchpad**(`/tmp/claude-1000/.../1e91440a-.../scratchpad`)——
那個 session 一結束,`flock` 對著一個不存在的鎖檔案、PATH 前綴指到一個不存在的 shim 目錄,
兩者都會**悄悄變成什麼都沒做**,閘門會在完全沒有 guard(無限並行度)的狀況下重建約 60 個
translation unit,正是 2026-09-02 讓使用者自己的 app 被 systemd-oomd 殺掉那種狀況。已經改接
`tools/build_guard/guarded_build.sh`(`JOBS=1`、`LOCK_WAIT=10800`、`NO_GUARD=1` 逃生閥),跟
`mutate_cpu_report_no_ip.sh` 的 `build()` 同一個寫法。Anchor 不受影響(`GUARD` 只在
`build_it()` 裡用到,不是任何 anchor 的 applier)。

## CI 接線(任務第 5 點)

`check_gate_anchors.py` 接進 `tools/test_workflow/l1_unit_tests.sh`,當作 step 0,擺在
build 之前(`--no-build` 也會跑到)——checker 本身不建置、不跑閘門,理當排在前面而不是後面。
跟其他 step 共用同一個 `$FAILURES` 計數器,壞了會讓整個 L1 lane 紅。`local_ci.sh` 的
`job_python` 本來就呼叫 `l1_unit_tests.sh`,所以順帶接上,不用另外改。

**已知限制**:checker 讀的是 git 版本(`git show HEAD:path`),不是 working tree——未提交的
閘門修改這一關看不到。這是工具原本的設計(唯讀、不建置),不是這次接線引入的新問題。

**這會讓 L1 下一次真的跑起來時回報 FAILED**——66/68 ok,不是 68/68。這是誠實的現況,不是新
的 regression,兩格都已經在本文件寫清楚原因跟(其中一格已驗證過)修法方向。

## 明早需要真的跑一次確認的閘門

anchor checker 只能確認「anchor 字串在檔案裡出現的次數對不對」,**不能**確認 mutation 真的會
被正確的測試抓到——尤其是我今晚做了語意判斷(不只是機械式跟著改名)的那幾支,**優先順序由高
到低**:

1. **`mutate_a2_poll_round.sh`**——特別是 mutation #5(閘門自己標記「🔴 THE ONE THAT INVENTS
   A FAULT」,今晚最有把握但也風險最高的一個重新定位:把 anchor 從已經消失的 `linksAnswered`
   布林值搬到 `classifyEndpointReply` 的 `bodyIsBlank` 那行,repl 讓 `body.size() <= 2` 也算
   blank)。
2. **`mutate_a7_dispatch_status.sh`**——mutation #4,anchor 從會 mutate 錯函式改成精準命中
   `add_flow_entry`。
3. **`mutate_f6_stale_table_carry_forward.sh`**——mutation #7。
4. **`mutate_g6_apps_liveness.sh`**——case `notrunning-rc-zero`,重新定位到位移後的兩行。
5. `mutate_g7_ndtwin_lab_config.sh`、`mutate_g9_cleanup_no_pkill_f.sh`、
   `mutate_g9_faults_topo_pid.sh`、`mutate_build_guard.sh`、`mutate_ndt_up_target.sh`——閘門
   腳本本身這次沒被我改動(`g6` 除外,見上),但這是它們第一次被 checker 讀到,值得跑一次
   確認閘門本身(不是 anchor)是好的。
6. `mutate_ports_that_block_restart.sh`——重寫過呼叫方式,雖然逐位元組驗證過跟原文字相同,
   從沒真的執行過整支閘門確認 mutation 仍然被抓到。
7. `mutate_flow_rate_denominator.sh`——除了 anchor,build 機制換成 `guarded_build.sh` 了,
   該跑一次確認 guard 路徑真的可用。
8. `mutate_make_topology_stdout.sh`——加了具名角色,純命名,風險低,仍建議跑一次。
9. `mutate_check_gate_anchors.sh`——保護 checker 自己那支,M4 重新定位過。
10. `mutate_harness_instruments.sh`、`mutate_logger_cli.sh`——純 checker 端修正,閘門腳本
    完全沒動,風險最低,可以排最後或跳過。

## Commit 列表(`f943de8f..c30d130f`,worktree `fix/gate-anchors-0904`,未 push)

```
c1514d8b Re-anchor 3 drifted mutation gates; fix 2 checker false-positives (DUP, MISSING)
e020805e Teach the anchor checker to read write_case/@@@TO@@@ heredoc mutation tables
708418d0 Re-anchor mutate_check_gate_anchors.sh's M4 after is_whole_param_ref's own fix
196da630 Name mutate_make_topology_stdout.sh's applier roles so the checker reads it
55f34812 Unpack mutate_ports_that_block_restart.sh's runtime-packed anchors
fcf05761 Teach the anchor checker to read cat>*.old/*.new mutation-table files
138e69a6 Fix trailing-comment blind spot; route flow_rate_denominator through the guard
c30d130f Wire check_gate_anchors.py into l1_unit_tests.sh as a read-only pre-build step
```

`tests/python/test_check_gate_anchors.py` 從 29 個 test 加到 40 個(11 個新 case,涵蓋
`_replace_call_want`、`is_whole_param_ref` 的數字分支、`write_case` heredoc、
`cat > *.old/*.new` 含單一目標檔與逐 case 目標檔兩種形狀、positional relay)。全部 40 個
`python3 tests/python/test_check_gate_anchors.py` 通過(2 個因為在 worktree 裡跑
——`.git` 是檔案不是目錄——被 `TheRealGatesAreRead` 自己 skip,不是這次改動造成的)。

[Co-developed with claude code -- Adam]
