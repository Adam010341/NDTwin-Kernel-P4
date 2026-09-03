# FIX-GATE-ANCHORS — 目標檔在 repo 根目錄時，錨點被算到別的檔案裡

Finding #78。分支 `fix/gate-anchors-root-files`，基底 `209251dd`，修正 commit `aed8f299`。
2026-09-03。

[Co-developed with claude code -- Adam]

---

## 1. 這是什麼等級的錯

`tests/shell/check_gate_anchors.py` 是「每一個 mutation gate 還找得到它要改的那段字嗎」的儀器。
它整份文件在講一件事：**「檢查不了」永遠不可以長得像「檢查過而且沒問題」**。所以它有
`NO-ANCHORS`、`UNPARSED`、`VIA-UNCHECKED`、`PENDING-VIA` 四種大聲的講法，會另外印在 stderr、
會 exit 2、會在總結行寫「其中 N 格根本沒被檢查」。

#78 不是那四種的任何一種。它是**第五種：算了、算錯了、而且很有自信**。

`MISSING:23` 是「這個 gate 的 23 個錨點都不見了」。讀到這一格的人會去翻 23 個已經漂移的錨點——
而那 23 個錨點**一個都沒漂**，全部都在、而且全部唯一。

---

## 2. 錯的輸出（verbatim）

重現方式：把 `integrate/2026-09-03-auditor-merge` 的 `tests/shell/mutate_testbed_banner.sh`
取出來、**把繞道拿掉**（`TOPO="$REPO/./testbed_topo.py"` → `TOPO="$REPO/testbed_topo.py"`），
用 plumbing 做成一個 commit `01f5ff5f`（不動任何分支），拿 `209251dd` 的工具去跑：

```
$ python3 tests/shell/check_gate_anchors.py 01f5ff5f --gates mutate_testbed_banner.sh
anchors of each gate, counted in each rev's own files
columns:
  c0   01f5ff5f66ad04d5ce8d950bcac51310e924e98f

                          c0
mutate_testbed_banner.sh  MISSING:23

--- broken anchors ---
mutate_testbed_banner.sh @ 01f5ff5f66ad04d5ce8d950bcac51310e924e98f
  file  : tests/python/test_testbed_banner.py
  from  : mutant (literal)
  count : 0 (want 1)
  anchor:         for line in banner_lines(ping_summary): ...
mutate_testbed_banner.sh @ 01f5ff5f66ad04d5ce8d950bcac51310e924e98f
  file  : tests/python/test_testbed_banner.py
  from  : mutant (literal)
  count : 0 (want 1)
  anchor:         ping_summary = run_ping_self_test(net, HOST_NUM)

  （……中間 20 筆，file 欄全部是 tests/python/test_testbed_banner.py……）

mutate_testbed_banner.sh @ 01f5ff5f66ad04d5ce8d950bcac51310e924e98f
  file  : tests/python/test_testbed_banner.py
  from  : mutant (literal)
  count : 0 (want 1)
  anchor:     match = _PING_STATS_RE.search(text or "")

0/1 cells ok  (1 not ok, of which 0 were NOT CHECKED AT ALL)
check_gate_anchors: 1 cell(s) not ok (exit 1)
```

23 筆明細的 `file` 欄**全部**是同一個值——`grep -c '^  file  :'` ＝ 23，
`grep -c '^  file  : tests/python/test_testbed_banner.py$'` ＝ 23，`sort -u` 之後只剩一個值。
23 個 anchor 各不相同。

**注意最後一行：`0 were NOT CHECKED AT ALL`。** 工具認為自己完整讀懂了這個 gate、完整檢查了
它的 23 個錨點、而且確定它們都不在。exit 1（「檢查過，有問題」）而不是 exit 2（「沒檢查到」）。

`file` 欄那個 `tests/python/test_testbed_banner.py` 是 gate 宣告的**另一個**路徑（它拿來跑
python 測試用的），23 個錨點沒有一個在裡面。

---

## 3. 判準 before / after

### before

決定「這個字串是**檔案**、還是要去檔案裡找的**那段字**」，全靠一件事：**裡面有沒有斜線。**

同一個判斷在工具裡寫了七次，七次都是 `"/" in v`：

| # | 位置 | 什麼形狀的 gate 會走到 |
|---|---|---|
| 1 | `path_at()` | applier 自己命名參數（`local ... file="$2" old="$3"`），按位置取檔案 |
| 2 | `default_file_of()` | 檔案烤在 applier body 裡，呼叫行上沒有 |
| 3 | `declared_paths()` | 釘不到檔案的錨點，退回「gate 宣告過的所有路徑」的聯集 |
| 4 | 通用規則 `<file>` 後面接引號字串 | 手寫的 `mutate_must_die "$SRC" 'anchor' 'repl'` |
| 5 | pass 1 直譯器運算元 | `python3 - "$FILE" <<PY` |
| 6 | inline python 同一行的檔案 | `apply_py '<python>' "$FILE"` |
| 7 | `head == "mutate"` 的特例判斷 | `mutate <label> <file> <anchor> <repl>` |

而 gate 都是這樣寫目標的：

```bash
TOPO="$REPO/testbed_topo.py"
```

`_repo_relative()` 會把 `$REPO/` 剝掉（因為交給 `git show <rev>:<path>` 的路徑必須是 repo 相對），
剩下 **`testbed_topo.py`——沒有斜線**。於是七個判斷一致認為它不是檔案，23 個錨點的 `file` 欄
全部落到唯一有斜線的 `tests/python/test_testbed_banner.py`（走的是第 3 條的聯集），
在那裡各數到 0 次。

repo 裡在此之前沒有任何一個 gate 的目標在根目錄，所以這個洞從來沒被踩到。

### after

七個地方共用同一個述詞 `is_repo_path(v, exists)`：

```python
def is_repo_path(v, exists=None):
    if not isinstance(v, str) or not v:
        return False
    if "/" in v:
        return True                             # unchanged: a directory part is a path
    if exists is None:
        return False                            # no rev to ask -- do not guess
    return _BARE_FILENAME.fullmatch(v) is not None and bool(exists(v))
```

三條，順序有意義：

1. **斜線那條原封不動。** 有目錄成分就是路徑，跟以前一樣、一樣不去問 git。
   （動它的話，每個 gate 的判決都會隨著「那個 rev 剛好有沒有搬過檔案」而變。）
2. **沒有 rev 可以問，就不猜。** `extract()` 被直接呼叫（沒有 `exists`）時，行為與修正前完全相同。
3. **新增的只有 git 的回答，不是猜測。** 形狀像檔名的裸字，**當且僅當**這個 rev 的 tree 裡真的
   有一個同名檔案時，才算檔案。`exists` 是工具本來就有的 `git show <rev>:<path>` 探針
   （`default_file_of` 一直在用它，註解寫著「`exists` is git's answer, not a guess」）。

形狀檢查 `_BARE_FILENAME` 擺在 `exists` 前面，是為了另一個方向：**一個既沒有斜線、tree 裡也沒有
同名檔案的字串，不會被升格成路徑。** 它維持「認不出來」，錨點就維持 unresolved、照原來的規矩被
報成 NOT checked，絕不會被安到某個猜出來的檔案上。放寬成「每個參數都是檔案」是相反方向的失敗，
gate 裡的 R1／R3 就是那個對照組。

---

## 4. 紅／綠

### 4.1 紅：修正前

**(a) 那個 gate 本身。** `MISSING:23`（上面第 2 節）。

**(b) 測試。** 新的 case 對 `209251dd` 的工具跑（`CHECKER_UNDER_TEST=` 指過去）：

```
FAILED (failures=9, errors=3, skipped=2)
```

9 個 FAIL 全部在 `ATargetAtTheRepoRootIsAFile`（八種 gate 形狀 + 端到端那格），
3 個 ERROR 是 `NotEveryStringIsAFile` 的三個 unit case——`209251dd` 的工具還沒有 `is_repo_path`
這個述詞（`AttributeError`）。

反方向的兩個 case（`test_a_root_targets_drift_is_still_caught`、
`test_a_root_target_that_is_not_in_the_tree_is_not_checked`）在舊工具上**是綠的**——它們本來就
是護欄，不是這次的缺陷。

### 4.2 綠：修正後

| 對象 | 結果 |
|---|---|
| 拿掉繞道的 gate（`01f5ff5f`） | `ok(23)`，exit 0 |
| 真的那個 gate（`integrate/2026-09-03-auditor-merge`，繞道還在） | `ok(23)`，exit 0 |
| `tests/python/test_check_gate_anchors.py` | 29 cases，`OK (skipped=2)` |
| `tests/python/` 全部 28 個檔 | 28 pass / 0 fail |

繞道留著也對、拿掉也對——這是刻意的：`fix/testbed-banner-reads-its-ping` 不必因為這個修正而改動。

### 4.3 自己的 mutation gate

`tests/shell/mutate_gate_anchors_root_files.sh`，13 個變異全部打在工具的**副本**上
（`CHECKER_UNDER_TEST`），本尊從頭到尾沒被寫過：

```
mutation gate: 13 mutations, 0 survived
baseline byte-identical: yes (check_gate_anchors.py 9e4b0563...)
```

| 變異 | 內容 | 必須紅的 case |
|---|---|---|
| R1 (control) | 每個字串都是檔案 | `test_anchor_text_is_never_promoted_to_a_file` |
| R3 (control) | tree 答應的都是檔案，不管形狀 | 同上 |
| R2 | 形狀像檔名就算，不問 tree | `test_a_root_target_that_is_not_in_the_tree_is_not_checked` |
| R4 | 沒 rev 可問就猜 yes | `test_a_bare_name_is_a_path_only_when_the_tree_holds_one` |
| R5 | 斜線那條也要 tree 批准 | `test_a_path_with_a_directory_part_still_needs_no_permission` |
| R6 | `path_at` 退回只看斜線 | `test_a_short_anchors_root_target_is_pinned_by_the_appliers_named_roles` |
| R7 | `default_file_of` 退回 | `test_a_baked_in_root_targets_anchor_is_pinned_to_the_root_file` |
| R8 | 通用規則退回 | `test_a_generic_appliers_root_target_is_pinned_to_the_root_file` |
| R9 | 直譯器運算元退回 | `test_a_heredoc_appliers_root_target_is_pinned_to_the_root_file` |
| R10 | inline python 同行檔案退回 | `test_an_inline_python_appliers_root_target_is_pinned_to_the_root_file` |
| R11 | 聯集不收根目錄檔 | `test_a_root_target_is_in_the_union_an_unpinned_anchor_falls_back_to` |
| R12 | `mutate` 特例判斷退回 | `test_a_bare_mutate_call_with_a_root_target_is_read_not_refused` |
| R13 (control) | 每個錨點都算存在 | `test_a_root_targets_drift_is_still_caught` |

🔴 **R6 第一版是 SURVIVED 的，而且是這次最值得記的一件事。**
它本來指著最明顯的那個 gate（`root_named`，就是 banner gate 的形狀）。把 `path_at` 退回只看斜線
之後，那個 case 還是綠的——因為**通用規則（第 4 條）讀得到同一行呼叫**，把同一個錨點釘到同一個
檔案上，`path_at` 壞掉完全看不出來。改成指著 `root_short`：通用規則有「引號字串至少 8 個字元」
的下限，短錨點只剩 applier 自己命名的參數這一條路，`path_at` 是唯一的路由。

換句話說：**六個 pinning case 斷言的是「錨點被釘到 `epsilon.py`」，不是「數字對」。**
工具本來就有的聯集退路常常會把數字湊對，湊對就會把壞掉的路由蓋掉。

---

## 5. 全 repo sweep（before / after）

| # | 跑法 | gates 來源 | 工具 | 結果 |
|---|---|---|---|---|
| 1 | `check_gate_anchors.py 209251dd` | `209251dd` | `209251dd`（未修） | **37/50 cells ok**（13 not ok，其中 10 NOT CHECKED），exit 2 |
| 2 | `check_gate_anchors.py 209251dd` | `209251dd` | `aed8f299`（已修） | **37/50 cells ok**（13 not ok，其中 10 NOT CHECKED），exit 2 |
| 3 | `check_gate_anchors.py HEAD` | `aed8f299` | `aed8f299` | **38/51 cells ok**（13 not ok，其中 10 NOT CHECKED），exit 2 |
| 4 | `check_gate_anchors.py trunk` | `507ff3e8` | `209251dd`（未修） | **40/53 cells ok**（13 not ok，其中 10 NOT CHECKED），exit 2 |
| 5 | `check_gate_anchors.py trunk` | `507ff3e8` | `aed8f299`（已修） | **40/53 cells ok**（13 not ok，其中 10 NOT CHECKED），exit 2 |

**1 vs 2 是隔離變因的那一組：gate 完全相同，只換工具。兩份輸出 `diff` 完全一樣——不只格子，
連 broken-anchor 明細和 UNPARSED 清單都逐字相同。**

```
$ diff <(舊工具 @209251dd 的完整輸出) <(新工具 @209251dd 的完整輸出)
（無輸出）
```

**2 vs 3 的差別只有一列**，就是這次新增的 gate 自己：

```
$ diff <(grep ^mutate_ 舊工具@209251dd) <(grep ^mutate_ 新工具@HEAD)
23a24
> mutate_gate_anchors_root_files.sh              ok(11)
（其餘差異只有 broken-anchor 明細行的 rev 標籤 209251dd → HEAD）
```

37/50 → 38/51 ＝ 多一格、多一格 ok。**沒有任何既有 gate 的判決被搬動。**

**4 vs 5 是同一組隔離比較，但跑在「合併之後真正會長成的樣子」上。** 我開工用的 `209251dd` 在
我做事的期間被推進到 `507ff3e8`（多了 3 個 gate，其中就有帶著 `./` 繞道的
`mutate_testbed_banner.sh`）。同樣只換工具、gate 不動：**40/53 對 40/53，`diff` 一格都沒動。**
banner gate 在兩邊都是 `ok(23)`——因為繞道還在，它本來就讀得到。

`507ff3e8` 沒有碰過我改的三個檔案（`git diff --stat 209251dd..trunk --` 這三條路徑是空的），
`git merge-tree --write-tree trunk HEAD` rc=0（tree `9ea7e85d`）。

（前一位 agent 加 banner gate 時量到的 37/50 → 38/51 是**另一件事**——那是它自己那個 gate 的
那一格。兩者不衝突：這裡的 +1 是 `mutate_gate_anchors_root_files.sh`，那裡的 +1 是
`mutate_testbed_banner.sh`，兩個 gate 在不同分支上。合併後應該是 39/52。**未實測。**）

`209251dd` 那 13 格不 ok（10 格 NOT CHECKED）是既有狀態，跟這次修正無關，沒有被碰。

---

## 6. 沒有做的事

- **沒有重寫工具。** 只新增一個述詞、把七處同一個判斷改成呼叫它。解析邏輯、錨點計數語意、
  聯集退路、UNPARSED／NO-ANCHORS／VIA-* 的判決規則一律沒動。
- **沒有動 `mutate_testbed_banner.sh` 的繞道。** `TOPO="$REPO/./testbed_topo.py"` 還在
  `fix/testbed-banner-reads-its-ping` 上，兩種寫法現在都讀 `ok(23)`。要不要收掉那個 `./` 與那段
  註解是那個分支的決定，不是這裡的。
- **沒有推。** 分支只在本機。
- **沒有改 `_prune()`、以及 `declared_paths` / inline-python 裡「這是不是**目錄**」的三處
  `"/" in v`。** 那是另一個問題（目錄沒有副檔名、`exists` 對目錄會回 true），這次沒碰。
  ⇒ **已知極限：** 一個叫做 `foo.d` 的**目錄**若被當成目標，`git show <rev>:foo.d` 會成功，
  `is_repo_path` 會說它是檔案。`default_file_of` 原本就有這個弱點，我沒有擴大也沒有修掉。
- **沒有用 `git cat-file -e`。** 任務描述提到它；我沿用工具自己既有的 `exists` 探針
  （`Rev.show()`，有快取）而不是新增一條 git 路徑——上面那個目錄的極限就是這個選擇的代價。
- **`tests/python/` 實際只有 28 個檔，不是 29。** `209251dd` 上 `ls tests/python/test_*.py`
  數出來 28 個，全部 pass。差的那一個應該在別的分支上；**我沒有去追是哪一個。**
- **沒有跑 `tests/shell/` 的其他 gate。** 只跑了 `mutate_gate_anchors_root_files.sh`（本次新增）。
  既有 gate 的錨點狀態改用 sweep 對帳（第 5 節），那是這次唯一需要證明的東西。
- **raw 沒有進版控。** `doc/audit/*/raw*/*` 是 `audit-raw` 分支專用（`.gitignore:84` 加上
  `tools/githooks/pre-commit`，後者只在有安裝時才生效），而同一波的
  `2026-09-03_fix-ovs4-sflow` / `fix-rule-journal` 也都只 commit 一個 `.md`。
  ⇒ 七份原始輸出（那個紅、兩次 sweep、對舊工具的測試紅、gate 執行、28 個 python 檔）留在本
  session 的 scratchpad `…/scratchpad/repro/`，**沒有 commit、也沒有搬到 `audit-raw`**。
  上面每個數字都是從那裡抄的；要進 `audit-raw` 請說一聲。
- **合併只驗到 `merge-tree`。** `git merge-tree --write-tree trunk fix/gate-anchors-root-files`
  rc=0（tree `60b06e75`）；對 `integrate/2026-09-03-auditor-merge` 也 rc=0。**沒有實際合併、
  沒有在合併後的樹上跑過任何東西。**

---

## 7. 檔案

| 路徑 | 動作 |
|---|---|
| `tests/shell/check_gate_anchors.py` | 修正（+1 述詞，7 處呼叫點） |
| `tests/python/test_check_gate_anchors.py` | +9 gate 樣板、+14 case（15 → 29） |
| `tests/shell/mutate_gate_anchors_root_files.sh` | 新增，13 變異 0 存活 |
| `doc/audit/2026-09-03_fix-gate-anchors/FIX-GATE-ANCHORS.md` | 本文 |
