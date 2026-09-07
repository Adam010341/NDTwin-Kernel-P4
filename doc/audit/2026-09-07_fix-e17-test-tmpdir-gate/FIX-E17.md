# FIX-E17 — 把「測試的暫存路徑必須帶 pid」變成一條會擋人的規則

[Co-developed with claude code -- Adam]

裁決：`scratch/overnight-2026-09-05/DECISIONS.md`「grill §4E」**E-17**（「開小單：靜態掃描＋一支測試」）。
動機：`scratch/overnight-2026-09-05/fix/R2-CTEST-SUMMARY.md` §7 第 1 條——
`c3d99d00` 一次修好六個 fixture，但那是**六次人工修正**；下一支新 fixture 寫成常數路徑時，
`ctest -j1` 全綠、`-j2` 偶爾紅、而且每次紅的不是同一支，最後都會被當成「重跑一次就好」。

base＝`fix/intent-task-outcomes-per-test-tmpdir`@`c3d99d00`。分支 `fix/e17-test-tmpdir-carries-pid`。
**沒有建置**（不改 CMake、不加 ctest 條目）。

---

## 1. 規則

> **測試會去建立／刪除的暫存路徑，名字裡一定要有「每個行程都不一樣」的東西。**

一筆違規要同時滿足三件事：

1. **暫存根**：`temp_directory_path()`、`/tmp/…`／`/var/tmp/…` 字面路徑、`$TMPDIR`、
   `tempfile.gettempdir()`。
2. **真的會動到檔案系統**：同一個 statement（C++／Python）或同一個 command（shell）裡有
   建立或刪除的動作。
3. **沒有任何 per-process 記號**：`getpid`／`os.getpid`／`$$`／`$BASHPID`／
   `mkdtemp`／`mkstemp`／`mktemp`／`XXXXXX`／`NamedTemporaryFile`／`TemporaryDirectory`。

第 2 條是這支掃描器最重要的設計決定。這棵樹裡滿地都是**不會被建立**的 `/tmp` 字串：
丟給 parser 的 argv、斷言用的字串、被斷言「絕對不會執行」的注入 payload、glob 比對的右運算元。
一支把它們全報出來的閘門，一個禮拜之內就會被關掉——關掉之後，真的那一筆也一起沒人看。
逐條例外寫在 `tests/shell/check_test_tmpdirs.py` 的檔頭（含每一條在這棵樹裡的實際行號）。

C++ 那一半刻意比較嚴：`temp_directory_path()` 不是拿去給 parser 的字串，標準定義它就是
「拿來建暫存檔的目錄」，所以接在它後面的名字一律進掃描範圍，不要求建立動作在同一個 statement。
`c3d99d00` 修的六支裡有五支，建立的動作都在**後面**的 statement。

---

## 2. 交付物

| 檔 | 一句話 |
|---|---|
| `tests/shell/check_test_tmpdirs.py` | 掃描器。`tests/*.cpp`／`tests/python/*.py`／`tests/shell/*.sh`；rc 0 乾淨、1 有固定路徑、**2 有檔案讀不到** |
| `tests/python/test_check_test_tmpdirs.py` | 31 個 case，正例／反例成對；最後一組跑真的 `tests/` 樹 |
| `tests/shell/mutate_check_test_tmpdirs.sh` | 11 個變異，0 survived |
| `tests/shell/mutate_logger_cli.sh` | 掃描器抓到的**第七筆**，順手修（見 §5） |
| `doc/2026-08-17_testing-manual.md` §5 | 一條規則＋閘門指令 |

---

## 3. 紅：把 `c3d99d00` 的每一個 hunk 還原到本地副本

逐字在 `01-redgreen-six-hunks.log`。方法：`tests/` 整棵**複製**到 temp dir，
每次只把一個檔還原成 `git show c3d99d00^:<file>`，**worktree 本身從頭到尾沒有被寫過**。

```
=== GREEN: the branch as it stands ===
check_test_tmpdirs: 220 file(s) scanned, 0 fixed temp paths
rc=0

=== RED: tests/test_IntentTaskOutcomes.cpp reverted to c3d99d00^ in the copy ===
tests/test_IntentTaskOutcomes.cpp:121: temp_directory_path() joined with a name that is the same in every process (no getpid() / mkstemp / mkdtemp in this statement)
      m_root = std::filesystem::temp_directory_path() / "ndtwin_test_intent_task_outcomes";
rc=1
```

六支全部抓到，還原後又回到 0。`04-trunk-without-c3d99d00.log` 是同一件事的另一個角度：
把 trunk（`1a284f75`，沒有 `c3d99d00`）的 `tests/` 拉出來掃 ⇒ **7 筆**（六支＋§5 那一筆）。

**這一條要寫進交接**：這支掃描器在 trunk 上會紅，而那正是它存在的理由；
它只在 `c3d99d00` 之後才是綠的。

## 3b. 變異閘門（11 個變異，0 survived）

逐字在 `02-mutation-gate.log`。三個家族：

- **瞎掉**（M1／M2／M3／M9）：不掃 `tests/*.cpp`、不認得 `temp_directory_path()`、
  有違規仍然 exit 0、不再從「取名字的那一行」追到「刪掉它的那一行」。
- **吵起來**（M4／M10／M11）：`mkdtemp` 也算違規、每個指令的每個引數都算寫入、
  三引號區塊被當成這個檔自己的路徑。**假警報跟漏報一樣貴**——第一個被要求解釋
  「為什麼 mkdtemp 是危險的」的人就會把閘門關掉。
- **今天真的犯過的三個 parser bug**（M5／M6／M7／M8），見 §4。

---

## 4. 寫這支掃描器的時候，它自己瞎了三次

三次都**不是**回報錯誤，是**整個檔安靜地掃出乾淨**——跟真的乾淨印出來一模一樣。
這正是 KNOWN-ISSUES **L-3** 的形狀（`check_gate_anchors.py` 有四支 gate 讀不到，
卻報成 NO-ANCHORS）。所以掃描器現在有第三種結果：**`NOT CHECKED` ⇒ exit 2**，
既不是乾淨也不是有違規，而是「去看一下」。

| # | bug | 症狀 | 現在被什麼釘住 |
|---|---|---|---|
| 1 | heredoc 偵測跑在**引號之外**（前置掃描） | `mutate_logger_cli.sh:137` 的 `<< known_option_names(…)` 在單引號字串裡，被讀成 heredoc `<<known_option_names`，接下來 **482 行**被當 heredoc body 丟掉；整支 gate 掃出乾淨 | heredoc 改在 tokenizer 裡認（引號有效） |
| 2 | `<<<` herestring 被讀成 heredoc | `<<<"$OUT"` 的第二個 `<` 讓 `<<"` 看起來像「delimiter 被引號包住的 heredoc」，**吃掉那個開引號**，其後全部變成字串內容 | 拿掉 `!= "<<<"` 那個 guard（M5 把它裝回去） |
| 3 | `"$( … )"` 裡面引號不會重新開始 | `test_l1_shell_scoring.sh:219`、`test_ndtwin_lab_config.sh:269` 的巢狀引號被讀成沒關的字串，其後全部失效 | command substitution 會 push／pop 引號狀態（M6） |

⚠️ **寫這幾個 case 的時候踩到第二層陷阱**：bug 2、3 的「症狀」是**引號奇偶性**——
把真實那一行抽出來當合成 case，奇偶性剛好對上，case 就**綠著**而真檔仍然壞掉
（M5／M6 第一版都 survived，而同一次 run 裡真樹那一格是紅的）。
⇒ 這兩格改成斷言**能力**而不是**症狀**：巢狀在 `"$( … )"` 裡的 `mkdir` 是不是被看見。
記憶那條「儀器不能長得像自己的發現」在這裡的具體形狀是：**合成 case 要複製的是性質，不是那一行的字元。**

另外，「掃了幾個檔」不等於「看見了什麼」：
`TheRealTreeIsClean.test_it_actually_looked_at_the_six_fixtures_c3d99d00_fixed`
直接斷言那六個檔裡的 `temp_directory_path()` 呼叫點**每一個都被走到**，
而且註解剝除之後剩下 13 個 code 站點（原始 14 個，差的那一個是
`test_IntentTaskOutcomes.cpp:470` 文件註解裡引用的那一行）。

---

## 5. 掃描器上線第一天抓到的第七筆：`mutate_logger_cli.sh`

```
tests/shell/mutate_logger_cli.sh:87: $NOFILE is a fixed /tmp/ndtwin-logger-cli-gate-should-not-exist.log
    path, and line 218 creates or deletes it; no $$ / mktemp / getpid in either place
```

`NOFILE` 是那支 gate 的**判準本身**：它 `rm -f "$NOFILE"`，把同一條路徑當 `--logfile` 傳給
kernel，然後用「這個檔在不在」來判斷 `--help` 有沒有走到 `Logger::init`。名字是常數、目錄
world-writable ⇒ 同一台機器上兩次 run 會互相刪掉對方的證據：
一邊把**別人建的檔**讀成失敗，另一邊把**自己被刪掉的檔**讀成通過。

修法是一個 token：`…-should-not-exist.$$.log`。`$$` 在賦值當下展開，
`trap` 裡的 `$NOFILE`、第 218／220／222／601／602 行的每一個使用點都在同一個 shell、同一個 `$$`。
**驗到哪裡**：`bash -n` 過、六個使用點逐一讀過。**沒有跑過那支 gate**——它要編譯，本單無建置。
要不要留這個 hunk 由 Adam 決定（`R3-E17-SUMMARY.md` §7-1）。

---

## 6. 已知界線（寫在腳本檔頭，這裡摘要）

- 嵌在別的語言裡的原始碼是**資料**：Python 三引號區塊、shell heredoc body 一律跳過。
  `tests/python/test_check_gate_anchors.py` 用三引號帶了十五個合成 shell gate（其中三個有
  `/tmp/mutate-shape-*`），那些 gate 只會被靜態解析、不會被執行。C++ 註解同理
  （`test_IntentTaskOutcomes.cpp:470` 引用的就是那條不可以回來的行）。
  **這條規則也是本單自己的測試檔能掃出乾淨的原因**，所以它有自己的 case 與變異（M11）。
- 變數只追一跳、只在同一個檔內：`NAME=<固定暫存路徑>` 之後 `$NAME` 走到寫入處會被報在
  **取名字的那一行**。穿過函式參數、跨檔案不追。
- 引號裡的 `"$( … )"` 會正確 re-parse，但裡面的指令仍留在同一個 word；**沒有**引號的
  `$( … )` 才會被當指令分析。
- 由片段組出來的路徑（`"/" + "tmp"`）認不出來。這棵樹沒有這種寫法。
