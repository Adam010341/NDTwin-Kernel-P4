# P4-D′ SUMMARY：tutorials solution 臂的控制器 import 不到 `p4runtime_lib`（phase-4 goal 7）

[Co-developed with claude code -- Adam]

| | |
|---|---|
| worker | D′（phase 4, goal item 7） |
| worktree | `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-driver-0924` |
| branch | `fix/tutorials-solution-controller-0924` |
| base → head | `0c85ad9c` → **`da0fa021`**（一個 commit；沒 push、沒 merge） |
| driver blob | `99c862a9`（修前，＝orchestrator 09-24 那輪跑的那顆）→ `4c790d8c`（修後） |
| sudo／lab／mininet／C++ build | 都沒用。`~/tutorials` 只讀（見 §2 O7） |

---

## 0. 一句話

tutorials fabric 上，**只有 solution 臂**（flowcache、p4runtime）的控制器子行程會多拿到一個
`PYTHONPATH=<exdir>/../../utils`（也就是「這支檔案被複製回原位時自己會 append 的那個目錄」），
所以 `import p4runtime_lib` 找得到。骨架臂與 `--fabric ndtwin` 的 **argv 和 env 一個 byte 都沒變**；
凍結的 plan block 與 sudo 行沒碰。gate：suite 169 綠、mutation `104 mutations, 0 survived`（head `da0fa021`）。 〔R2 取代 → §R2.9：final head `bf349b64`，170／106/0〕

---

## 1. 修法與為什麼是這個形狀

### 1.1 病因（OBSERVED，見 §2）

每支 tutorials `mycontroller.py` 都這樣找 `p4runtime_lib`：

```python
sys.path.append(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 '../../utils/'))
```

（`p4runtime/solution/mycontroller.py:15-17`、`flowcache/solution/mycontroller.py:23-25`；骨架那兩支同樣三行。）
這是相對於**檔案自己**，不是 cwd。骨架在 `<exdir>/` ⇒ `<tutorials>/utils` ✔；
解答在 `<exdir>/solution/` ⇒ `<tutorials>/exercises/utils`，**不存在**。tutorials 的本意是把 solution
**複製蓋過**骨架那支，driver 卻是原地跑 ⇒ import 就死。

### 1.2 修法（`drive_exercise.py`）

- 新 helper `tutorials_utils_of(exdir)` ＝ `normpath(<exdir>/../../utils)`。**由 exercise 目錄推，不用寫死的 `TUT`／`UTILS`**。
  它就是「solution 被放回原位時，自己那行會 append 的目錄」，所以語意上跟 tutorials 的本意一樣，沒有另外發明規則。
- `Steps._start_controller`：條件 `self.fabric != "ndtwin" and os.path.dirname(ctrl)`
  （＝tutorials fabric **而且**控制器不在 exdir 根目錄＝solution 臂）成立時，
  `env["PYTHONPATH"] = utils + os.pathsep + <繼承到的 PYTHONPATH（有的話）>`。
- 印出來的 `$ …` 行跟報告 C1 那步記下的指令都帶 `PYTHONPATH=… ` 前綴 ⇒ 報告裡那行貼出來就能重跑 〔R2 補但書 → §R2.8：只在 cwd＝exdir 時〕
  （沒有前綴的話，照抄會死在同一個 import）。

### 1.3 為什麼選這個，不選別的

| 選項 | 為什麼不選 |
|---|---|
| 把 solution 複製到 `<exdir>/mycontroller.py` | 會**蓋掉骨架**，而且是在 `~/tutorials/exercises/*/` 留檔——工單禁止 |
| 複製到 `build/` 或 `logs/` | 那兩個目錄跟 `solution/` 一樣深：`build/../../utils` ＝ `exercises/utils`，**一樣不存在** |
| 用 `python -c "sys.path.append(...); runpy.run_path(...)"` 包一層 | argv[0]／`sys.argv`／印出來的指令都變了，比一個環境變數更讓人意外 |
| 寫死 `UTILS=/home/adam/tutorials/utils` | 工單要求由 exdir 推；換一棵樹就錯（mutant 102 就是這個） 〔R2 取代 → §R2.6：production 裡等價〕 |
| 像 adapter 那樣一路往上找 `utils/p4runtime_lib`（`find_tutorials_utils`） | 在這棵樹上結果一樣；但「檔案自己會 append 的那個路徑」才是 tutorials 的本意，照抄語意比另寫一條搜尋規則少一個要解釋的東西 |

**prepend，不 append**：跟 NDTwin adapter 的 `sys.path.insert(0, utils_dir)`（`run_external_controller.py:172-174`）同一個順序，
所以兩個 fabric 上的 solution 解析 import 的方式一致。會不會因此蓋掉 venv 裡的同名套件？**實測沒有**（§2 O3）。

### 1.4 沒動到的東西

- 骨架臂：argv `[CTRL_PY, <exdir>/mycontroller.py]`、env ＝ 繼承＋`PYTHONUNBUFFERED=1`，跟修前一模一樣（測試逐字釘住）。
- `--fabric ndtwin`：argv 仍是 adapter＋package＋`solution/mycontroller.py`，env 不變（測試逐字釘住；adapter 本來就自己找 utils）。
- 凍結的 tutorials plan block 與 sudo 行：沒碰（`PlanBlockIsFrozen` 綠）。sudoers grant 的呼叫方式不變。
- `~/tutorials`：不複製、不新增檔案。

---

## 2. OBSERVED vs INFERRED

### OBSERVED（我親自跑過或親自讀過）

- **O1 live 失敗**（讀過，orchestrator 的 log，trunk `6291db35`、driver blob `99c862a9`）：
  `logs/orchestrator-0924/tutorials-18/flowcache_solution.log:60`（啟動行，無 PYTHONPATH）→ `:66`
  `ModuleNotFoundError: No module named 'p4runtime_lib'` → `:94` `>>> FAIL (4/4)`；
  `p4runtime_solution.log:60` → `:66` 同一行 → `:91` `>>> FAIL (4/4)`。
  對照 `p4runtime_skeleton.log:60`（`<exdir>/mycontroller.py`）→ `:125` `>>> PASS (4/4)`。
  run report `doc/audit/…/runs/2026-09-24T095545Z_flowcache_solution.md:66-67`、`…T095955Z_p4runtime_solution.md:66-67` 同一個 traceback（main checkout，只讀）。
- **O2 不用 root 的重現**（我跑的，真的 tutorials 檔、真的 p4dev venv，不連任何交換機）：〔R2：round 1 沒存 log；原始 log 已補 → §R2.4〕
  cwd＝exdir，`<venv python> <exdir>/solution/mycontroller.py --p4info /nonexistent/p4info.txtpb`：
  - 不帶 PYTHONPATH：兩支都 `ModuleNotFoundError: No module named 'p4runtime_lib'`，rc 1（＝live 那個錯）。
  - 帶 `PYTHONPATH=/home/adam/tutorials/utils`：兩支都印 `p4info file not found: /nonexistent/p4info.txtpb`，rc 1
    ⇒ **整段 import 都過了**（scapy、grpc、p4runtime_lib、flowcache 的 p4runtime_sh），停在 argparse 後的檔案檢查，沒連任何東西。
  - 對照：`p4runtime/mycontroller.py`（骨架）不帶 PYTHONPATH 也走到 `p4info file not found` ✔。
    順帶：`flowcache/mycontroller.py`（骨架）是 `IndentationError`（line 271，學生的 TODO）——
    跟本工單無關，因為 flowcache 骨架臂在 p4c 就停了（designed red arm），從來不會跑到控制器。
- **O3 沒有遮蔽**（我跑的 `importlib.util.find_spec`，p4dev venv，`PYTHONPATH=/home/adam/tutorials/utils`）：〔R2：round 1 沒存 log；原始 log 已補 → §R2.4〕
  `mininet`／`scapy`／`grpc`／`p4runtime_sh` 仍解析到 venv 的 site-packages；`utils/mininet/` 沒有 `__init__.py`，
  是 namespace portion，贏不了後面的 regular package。`netstat`／`p4_mininet`／`p4runtime_switch`／`run_exercise`／`p4apprunner`
  在 venv 裡本來就不存在（不帶 PYTHONPATH 時 `find_spec` 全是 None），所以沒有東西被蓋掉。
- **O4 紅燈先看到**（修 driver 之前，driver blob `99c862a9`＝`0c85ad9c` 的那顆，新測試未提交）： 〔R2 取代 → §R2.3、§R2.5：跑的是 test blob `888d7db5`；「修之前」撤回；6 個 failure 逐條〕
  `TheSolutionControllerFindsTheTutorialsLibrary` 6 個 cell 裡 **4 個紅**（subtest 算進去 6 個 failure），
  訊息就是 live 那句 `No module named 'p4runtime_lib'`；兩個「不准改」的守衛 cell（skeleton、ndtwin）**在舊碼上是綠的**——本來就該是綠的。
  log：`logs/gates-0910/test_drive_exercise.red-first.p4d-0c85ad9c.log`。
- **O5 修完全綠**：169 tests OK、0 skipped（真樹那格有跑到，沒被 skip），`/tmp/drv-*` 前後都是 0。
- **O6 mutation gate**：見 §3／§4。
- **O7 `~/tutorials` 沒被寫**〔R2：round 1 沒存 log；非 root 那一半的原始 log 已補，root 那一半仍 INFERRED → §R2.4〕：我所有的跑法前後 `git -C ~/tutorials status --short` 都是同樣三行
  （` M exercises/basic/basic.p4` 和兩個 `.vsix`，DRIVER.md §5 記過是本來就有的）。真樹那格的 log 寫在 temp dir，
  子行程帶 `PYTHONDONTWRITEBYTECODE=1`。
  但要說清楚：`~/tutorials/utils/p4runtime_lib/__pycache__/` **已經存在而且是 root 的**（`drwxr-xr-x root root`，Sep 24 17:59）——
  那是之前 sudo 跑過的臂留下的（骨架臂 import 的就是同一個 package；driver 自己也從 utils import `run_exercise`）。
  修好之後 solution 臂在 root 底下 import 同一個 package，**最多**寫同一批 `.pyc`（`*.pyc` 在 tutorials 的 `.gitignore` 裡，
  而且位置在 `utils/`，不在 `exercises/*/`）。這條我沒有用 root 驗過。
- **O8 NDTwin fabric 上同樣兩支 solution 控制器是綠的**（讀過 main checkout 的報告判定行）：
  `runs/2026-09-19T151037Z_p4runtime_solution_ndtwin.md` `PASS (5/5)`、`runs/2026-09-19T151139Z_flowcache_solution_ndtwin.md` `PASS (5/5)`
  ——走 adapter，而 adapter 本來就把 utils 插到 `sys.path[0]`。所以 NDTwin 那條路從來沒有這個 bug。
- **O9 tutorials harness 會帶 CPU port**（讀過）：`flowcache/topology.json:30-36` 三台都 `"cpu_port": "510"`，
  `utils/run_exercise.py:91` 把它交給 switch，`utils/p4runtime_switch.py:122-123` 變成 `--cpu-port 510`。flowcache 的 packet-in 要靠這個。

### INFERRED（沒跑過，推導）

- **I1** orchestrator 用修後的 driver 重跑，兩支 solution 臂的控制器會活著過 12 s、import 不再死。
  依據：O2（真檔真 venv，過了 import）＋O4/O5（driver 交出去的那條指令真的跑得過 import）。**唯一沒驗的是 root＋真交換機。**
- **I2** 預期判定見 §7。依據：O8（同一份控制器程式碼在 NDTwin 上 5/5）、09-24 tutorials p4runtime 骨架臂 `PASS (4/4)`
  （控制器連 s1／s2、裝 pipeline 在這個 harness 上是通的）、O9。
- **I3** sudo 的 `env_reset` 大概會把呼叫者的 PYTHONPATH 洗掉（我讀不到 sudoers）。這不影響修法：PYTHONPATH 是 driver 自己在子行程 env 裡設的，不靠繼承。

---

## 3. mutant ↔ killer（`tests/shell/mutate_drive_exercise.sh`，接續編號 98–104）

| # | mutant（改了什麼） | 被誰殺（expected，gate 判定 ✅） | also red |
|---|---|---|---|
| **98** | 修法整個拿掉（`if False:`）——回到 09-24 live 那一輪的狀態 | `test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib` | `…inherited_is_kept…`、`…report_records_reproduces…`、`test_the_real_solution_controllers_get_past_their_imports` |
| 99 | 骨架臂也拿到 PYTHONPATH（條件只剩 `fabric != "ndtwin"`） | `test_the_skeleton_arm_is_handed_the_environment_it_always_had` | （無） |
| 100 | ndtwin 臂也拿到 PYTHONPATH（條件只剩 `dirname(ctrl)`） | `test_the_ndtwin_arm_is_handed_the_environment_it_always_had` | （無） |
| 101 | utils 少推一層（`<exdir>/../utils`＝`exercises/utils`，就是原本壞掉的那個路徑） | `test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib` | `…inherited_is_kept…`、`…report_records_reproduces…`、`…real_solution_controllers…` |
| 102 | 改回寫死的 `UTILS`（這台筆電上剛好對，換一棵樹就錯） 〔R2 取代 → §R2.6：production 裡等價，只守設計要求〕 | `test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib` | `…inherited_is_kept…`、`…report_records_reproduces…`（真樹那格在這台上理所當然是綠的） |
| 103 | 繼承到的 PYTHONPATH 被丟掉 | `test_a_pythonpath_the_driver_inherited_is_kept_behind_the_exercises_utils` | （無） |
| 104 | 報告 C1 記的指令不帶 PYTHONPATH（跑得起來，但報告裡那行貼出來會死） | `test_the_command_the_report_records_reproduces_the_run` | （無） |

新的 6 個 cell 每一個都至少被一個 mutant 打紅過（上表 killer／also red 兩欄合起來就涵蓋全部 6 個）。
另外，既有的 **59**（ndtwin 臂不走 adapter）也把 `test_the_ndtwin_arm_is_handed_the_environment_it_always_had` 列在 also red——
那格把 ndtwin 的 argv 逐字釘住，所以這是預期中的。

既有的 **97 個**全部仍然被殺，而且都是被它們各自指名的那一格殺掉（沒有 `WRONG TEST`、沒有 `NOT UNIQUE`、沒有 `HUNG`、沒有 NO-SUITE）；
**合計 `104 mutations, 0 survived`，rc 0**；負對照（只加一行註解）維持綠；gate 前後原檔 sha256 `463119e1…` byte-identical，
最後再對真檔跑一次 suite 仍綠。

---

## 4. 閘門 log（全部在 final head `da0fa021` 上跑；紅燈那份在修之前）

| gate | log | head | 結果 |
|---|---|---|---|
| 紅燈先看到（修之前） 〔R2 取代 → §R2.3〕 | `logs/gates-0910/test_drive_exercise.red-first.p4d-0c85ad9c.log` | `0c85ad9c`（driver blob `99c862a9`）＋新測試（未提交，blob 記在 log 檔頭） | 6 個 cell 裡 4 個紅（6 個 subtest failure），訊息＝`No module named 'p4runtime_lib'`；守衛 2 格綠 |
| driver 離線 suite | `logs/gates-0910/test_drive_exercise.p4d-da0fa021.log` | `da0fa021`（driver blob `4c790d8c`、test blob `1bd38d62`） | **Ran 169 tests, OK**，rc 0，0 skipped；`/tmp/drv-*` 前後都 0 |
| mutation gate | `logs/gates-0910/mutate_drive_exercise.p4d-da0fa021.log` | `da0fa021`（subject sha256 `463119e1…`），18:58:26–19:24:11 | **104 mutations, 0 survived**，rc 0；baseline 169 綠；負對照綠；原檔 byte-identical；結束後 `/tmp/drv-*`＝0、`/tmp/drive-exercise-mutate-*`＝0 |
| gate 自己的測試（第 5 節會實際跑 `mutate_drive_exercise.sh`） | `logs/gates-0910/test_mutate_gate_dead_mutant.p4d-da0fa021.log` | `da0fa021` | **Ran 43 checks, 0 failed**，rc 0（跟上面那個 gate 同時跑；這一點記在 log 檔頭） |
| anchor 檢查（唯讀） | `logs/gates-0910/check_gate_anchors.mutate_drive_exercise.p4d-da0fa021.log` | `da0fa021` | `mutate_drive_exercise.sh ok(100)`，rc 0 〔R2 說明 → §R2.7：數的是不重複的 anchor〕 |

（全部路徑都在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/` 底下。）
這些 log 顯示的 gate interpreter 是 `/home/adam/miniconda3/bin/python3.13`——那是 `p4_proxy/venv/bin/python` 這個 symlink 的 realpath，
本來就這樣，venv 的 `pyvenv.cfg` 照樣生效；gate 第二段的 header 印的是 venv 路徑本身。

---

## 5. `git diff --stat 0c85ad9c..HEAD`

```
 .../2026-09-04_p4-tutorial-exercise-prep/DRIVER.md |  13 ++
 .../drive_exercise.py                              |  38 ++++-
 .../tests/test_drive_exercise.py                   | 187 +++++++++++++++++++++
 tests/shell/mutate_drive_exercise.sh               |  58 +++++++
 4 files changed, 294 insertions(+), 2 deletions(-)
```

---

## 6. 給 orchestrator 的兩行（要 root；我沒跑）

🔴 **前提**：sudoers grant 寫的是 **main checkout** 的路徑
`/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py`，
所以要先把 `da0fa021` 併進 main checkout 的 trunk（我沒 merge、沒 push），確認那個路徑的 blob 是
`4c790d8c`（`git -C /home/adam/Desktop/NDTwin-Kernel hash-object <那個路徑>`），並照慣例先 `ndt claim`、帶 `NDT_OWNER`。 〔R2 取代 → §R2.12：併 `bf349b64`、查 `13f60fda`〕

```
sudo -n /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py flowcache --which solution
sudo -n /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py p4runtime --which solution
```

（跟 `tutorials-18.sh` 的 `sudo -n $PY $DRV $ex --which $which` 同一個形狀；不帶 `--fabric`＝tutorials。）

## 7. 預期判定（INFERRED，見 I1/I2）

| 臂 | 預期 | 用來判讀的那幾行 |
|---|---|---|
| `flowcache --which solution` | **`>>> PASS (4/4)`，exit 0** | 啟動行變成 `$ PYTHONPATH=/home/adam/tutorials/utils /home/adam/p4dev-python-venv/bin/python …/flowcache/solution/mycontroller.py`；控制器 log **沒有** `ModuleNotFoundError`；`injection: the controller stayed up` got=`alive`；`switches the controller programmed` got=`[1, 2, 3]`；`the controller cached the flow it was punted` got=`cached`；`h1 -> h2 forwards once the cache is warm` got=`0% loss` |
| `p4runtime --which solution` | **`>>> PASS (4/4)`，exit 0** | 同樣的啟動行（`…/p4runtime/solution/mycontroller.py`）；`stayed up` `alive`；`programmed` `[1, 2]`；`the transit rule went in` `installed`；`h1 -> h2 forwards through the tunnel` `0% loss, 5/5` |

**怎麼讀結果**：
- 如果**還是** `ModuleNotFoundError` ⇒ 跑到的不是 `4c790d8c`（先查 blob），不是這個修法的問題。 〔R2 取代 → §R2.12：`13f60fda`〕
- 如果 import 過了但別的格紅 ⇒ 那是新的發現（這兩支 solution 臂在 tutorials 上**從來沒真的跑到控制器**），不是這個 bug 的殘留。
  flowcache 若只紅在 `cached the flow`／ping，先看 CPU port／packet-in（O9）；p4runtime 若只紅在 ping，先看 transit rule 那行。
- 骨架臂不用重跑：它的 argv／env 沒變（測試逐字釘住〔R2：round 1 只在沒有繼承 PYTHONPATH 時釘住 → §R2.1〕），09-24 那兩個結果（p4runtime 骨架 `PASS (4/4)`、flowcache 骨架在 p4c 停下的 designed red）仍然有效。

---

## 8. 範圍外、只記錄不處理

- `flowcache/mycontroller.py`（骨架）本身有 `IndentationError`（line 271）。只有在 flowcache 骨架**編譯成功**時才會碰到，而那本身已經是 driver 要抓的發現。沒改。
- `test_drive_exercise.py:2195` 的 `SyntaxWarning: invalid escape sequence '\s'` 是本來就有的（不在我的 diff 裡）。
- DRIVER.md §6.2 有兩個條目都編號「3.」，是本來就有的；我只在第二個「3.」後面加了一段，沒有重新編號。
- mutation gate 檔尾的說明文字還寫著「all fifty-one」之類的舊數字，是本來就有的，這次沒改（只加了表格項目）。
- 沒有 Dissent：工單範圍內就修得了，沒有動到任何被釘住的行。


---
---

# Round 2（2026-09-24 晚；judge 判 MERGE AFTER FIXES；final head **`bf349b64`**）

[Co-developed with claude code -- Adam]

judge 的結論是「程式碼沒有缺陷；SUMMARY 宣稱的比 log 證明的多，外加一個測試缺口」。Round 1 的文字**原封不動留在上面**，
被取代的句子在原處加了 `〔R2 取代 → §R2.x〕`，對照表在 §R2.10。本節所有 log 都在
`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`，每一份的檔頭都記了
head、dirty 旗標，以及 driver／測試檔／gate 三個檔案的 WT blob 與 HEAD blob。

| | |
|---|---|
| base → head | `0c85ad9c` → `da0fa021`（round 1）→ **`bf349b64`**（round 2，一個 commit；沒 push、沒 merge） |
| driver blob | `99c862a9` → `4c790d8c` → **`13f60fda`**。`4c790d8c→13f60fda` **只改了一行註解**（`git diff da0fa021 bf349b64 -- drive_exercise.py`：`:1586-1587` 補上「從 `<exdir>` 重跑」），行為不變 |
| test blob | `1bd38d62`（round 1 交付）→ **`38343a20`** |
| gate blob | → **`04d5acd1`** |
| orchestrator 對 `da0fa021` 的重跑 | 我讀過兩份 log 的結尾：`logs/orchestrator-0924/rerun-D-da0fa021.unit.log` `Ran 169 tests … OK`；`…mutate.log` `104 mutations, 0 survived` / `# rc=0`。跟我 round 1 的結果一致 |

## R2.1 （judge 第 1 項，測試）守衛 cell 看不到「繼承到的 PYTHONPATH 被丟掉」

**缺口（judge 指出，我確認）**：round 1 的兩個守衛（skeleton 臂、ndtwin 臂「環境跟以前一樣」）整個 class 都在
**沒有 PYTHONPATH** 的狀態下跑，而且 `want` 是在呼叫**之後**才從 `os.environ` 算的 ⇒
一個會把呼叫者的 PYTHONPATH 丟掉的 driver，在那兩格裡根本沒東西可丟；一個會改自己 `os.environ` 的 driver，會被拿去跟它自己改過的值比。

**改法（`bf349b64`）**：
- 兩格都加一個維度 `INHERITED = (None, "/somewhere/else")`，涵蓋 tutorials skeleton 臂，以及 ndtwin 的 skeleton 與 solution 兩臂；
- `environment_before()` 在呼叫**之前**設好 PYTHONPATH、**先**拍下期望的 env，再呼叫 driver；
- setUp 多註冊一個 cleanup，把 cell 設的 PYTHONPATH 拿掉，再還原呼叫者原本的值（LIFO 順序寫在註解裡）。

**mutant 105**：在 solution-only 那個 `if` **之前**，對所有臂都做 `env.pop("PYTHONPATH")`。這時 solution 臂照樣拿到 utils＋繼承值，**只有兩條被守的臂會變**。

**紅燈（OBSERVED，`demo_mutants_105_106_vs_round1.p4d-bf349b64.log`）**：round-1 的測試檔（從 `da0fa021` 取出、blob `1bd38d62`、在 temp mirror 裡跑）：
- 對照組：未改的 driver，`Ran 169 tests` OK；
- **105 對 round-1 suite：`Ran 169 tests` OK ⇒ 活下來了**（缺口是真的）；
- 105 對目前的 suite：`FAILED (failures=6)`，紅的正好是帶繼承值的 6 個 subtest——ndtwin 那格 4 個（2 支 × 2 臂）、skeleton 那格 2 個。
- 正式 gate 的結果見 §R2.9。

## R2.2 （judge 第 2 項，測試）印出來的 `$ …` 那行沒有人讀

新 cell `test_the_printed_start_line_carries_the_prefix_on_the_solution_arm_only`：4 條臂 × 2 支 exercise。它斷言：
- `_start_controller` 印的那一行 `$ <cmd>   (> <log>)`，其中的 `<cmd>` 必須**等於** C1 記下的指令；
- 只有 tutorials solution 臂是 `PYTHONPATH=<utils> <argv>`，其餘三條臂是純 `<argv>`。

為了讀得到那一行，`launch()` 把 `say` 換成收集器。

**mutant 106**：只改那一行 `say`（改回 `" ".join(argv)`）。**對 round-1 suite：`Ran 169 tests` OK ⇒ 活下來**；對目前的 suite：`FAILED (failures=2)`，紅的是新 cell 的 2 個 solution-arm subtest。同一份 demo log。

## R2.3 （judge 第 3 項，SUMMARY §4 第 1 列）紅燈先看到的那份 log，跑的不是交付的測試檔

更正 round 1 §2 O4 與 §4 第 1 列：

- `test_drive_exercise.red-first.p4d-0c85ad9c.log` 檔頭記的 test blob 是 **`888d7db5`**，**不是**交付的 `1bd38d62`。
  兩者**恰好差一行**：紅燈之後我才加的 `self.addCleanup(s.stop_controller)`（交付版 `:2626`）。
  證據：把交付版的這一行拿掉，重新算 hash 就是 `888d7db5`（`red_first_blob_reconstruction.p4d-bf349b64.log`）。
  - 所以交付版在那行之後的斷言行號都往後移了 1 行；
  - 紅燈 log 裡的 `ResourceWarning: unclosed file …driver-controller-*.log` 在交付版消失。
- **交付的測試檔確實紅過**，證據是 round-1 final gate 的 mutant 98（＝修法整個拿掉）：
  `mutate_drive_exercise.p4d-da0fa021.log:604-608`。那 5 行寫的是：
  - `anchor occurrences: 1`；
  - `✅ caught by test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib`；
  - also red：`…inherited_is_kept…`、`…report_records_reproduces…`、`…real_solution_controllers…`。
- round-2 的測試檔（`38343a20`）同樣被 98 打紅：`mutate_drive_exercise.p4d-bf349b64.log` `:612-616`（also red 裡多了新的 start-line cell）。
- **撤回**「紅燈 log 證明了『先紅、後修』的順序」這個說法。
  - 那份 log 能證明的是：它跑的 driver blob 是 `99c862a9`（＝未修版、＝`0c85ad9c` 的 HEAD blob），檔頭有記。
  - 它**不能**證明它發生在修法寫出來之前。log 裡沒有任何東西顯示先後。

## R2.4 （judge 第 4 項）O2／O3／O7 補上原始 log

round 1 的 O2、O3、O7 是我在 session 裡跑的，**當時沒有存 log**。現在在 `bf349b64` 上**重新跑過**並存檔（20:02–20:04）。
這些是**新的一次執行**，不是 round-1 那一次的紀錄；內容與 round 1 描述的一致。

- **O2** → `obs_O2_real_controllers_imports.p4d-bf349b64.log`（真的 tutorials 檔、真的 p4dev venv、不用 root；參數 `--p4info /nonexistent/p4info.txtpb`）：
  - flowcache solution：不帶 PYTHONPATH → `ModuleNotFoundError: No module named 'p4runtime_lib'`、`rc=1`（`:35-36`）；帶了 → `p4info file not found: /nonexistent/p4info.txtpb`、`rc=1`（`:41`, `:43`）。
  - p4runtime solution：同樣（`:56-57` ／ `:62`, `:64`）。
  - 對照組 p4runtime 骨架，不帶 PYTHONPATH → `p4info file not found`（`:69`, `:71`）。
  - flowcache 骨架 → `IndentationError: expected an indented block after function definition on line 271`、`rc=1`（`:49-50`）。
  - 🔴 **兩種結果都是 rc 1**：rc 分不出兩者，**分得出的是訊息**——一個死在 import，一個已經走過全部 import、停在 argparse 之後的檔案檢查。
- **O3** → `obs_O3_find_spec_shadowing.p4d-bf349b64.log`（只呼叫 `importlib.util.find_spec`，不 import 任何東西）：
  - utils/ 的頂層名稱全列在 `:35`；`utils/mininet/__init__.py` 不存在（`:36`）。
  - 不帶 PYTHONPATH（`:38-52`）與帶了（`:54-68`）兩張表，venv 本來就有的
    `mininet`／`scapy`／`grpc`／`p4runtime_sh`／`p4`／`google.protobuf` 解析到**同一個**檔案。
  - utils/ 的名稱在不帶 PYTHONPATH 時全是 `None (absent)`，所以加了之後沒有蓋掉任何東西。
    `cheat_sheet_src`／`img` 加了之後成了 namespace portion。
  - 附加段：utils/ 頂層名稱 ∩ `sys.stdlib_module_names` ＝ **EMPTY**（Python 3.12.3）。
    因為 PYTHONPATH 在 sys.path 上排在 stdlib **之前**，所以要查這一項。
- **O7** → `obs_O7_tutorials_untouched.p4d-bf349b64.log`。這份把 O2、O3 和 suite 的真樹 cell 包在中間：
  - `git -C ~/tutorials status --porcelain` 前後相同，md5 都是 `b2f872b1…`（`:58` `BEFORE == AFTER`）。
  - `find ~/tutorials -newer <marker>` 只找到 **一個**：`/home/adam/tutorials/.git`（`:61-62`）。
    - 附加的對照段（`:77-82`）：`git --no-optional-locks status` 之後 `-newer` 是 `<none>`；普通的 `git status` 之後又是 `.git`。
    - ⇒ 那一個 mtime 變動是**我自己用來拍「之前」快照的 `git status`** 拿 index lock 造成的，不是 controller 或測試寫了什麼。
  - `utils/p4runtime_lib/__pycache__` 與裡面 7 個 `.pyc` 都是 `root:root`：
    - 目錄 mtime 是 `2026-09-24 17:59:37`，`error_utils.cpython-312.pyc` 也是那一刻；其餘是 07-13；
    - `utils/__pycache__` 是 `root:root` 09-08。
    - 17:59:37 落在 orchestrator 的 p4runtime **骨架臂**那一輪裡（report `2026-09-24T095933Z_p4runtime_skeleton.md`＝17:59:33 +08）。
      骨架 `p4runtime/mycontroller.py:20` 是 `from p4runtime_lib.error_utils import printGrpcError`；solution 沒有 import `error_utils`，它在 `solution/mycontroller.py:152` 自己定義 `printGrpcError`（grep 過）。
      時間吻合是 OBSERVED；「那個 `.pyc` 是 root 跑骨架臂時寫的」是 INFERRED。
      這間接支持「sudo 底下的 controller 本來就會在 `utils/` 寫 `.pyc`」，但仍然不是 root 驗證。
  - **root 那一半維持 INFERRED**。「修好之後，solution 臂在 sudo 底下最多只會寫同一批 `.pyc`」我**沒有辦法用 root 驗**（→ §R2.10 表）。
    O7 能證明的只有：**我不用 root 跑的東西**沒有寫 `~/tutorials`。

## R2.5 （judge 第 5 項）紅燈 log 的失敗訊息，逐條

更正 round 1 §2 O4 那句「4 個紅，訊息都是 `No module named 'p4runtime_lib'`」。實際是 6 個 failure、4 種寫法
（行號是 `test_drive_exercise.red-first.p4d-0c85ad9c.log` 的）：

| failure | 斷言訊息 | 行 |
|---|---|---|
| `test_a_pythonpath_the_driver_inherited_is_kept_behind_the_exercises_utils` | `AssertionError: Lists differ: ['/tmp/drv-ctrlpath-…/utils', '/somewhere/else'] != ['/somewhere/else']`——**list 不相等，不是 ModuleNotFoundError** | `:53`, `:62` |
| `test_the_command_the_report_records_reproduces_the_run` | `AssertionError: 0 != 1 : <那條指令>`，輸出裡 `ModuleNotFoundError: No module named 'p4runtime_lib'` | `:76`, `:83`, `:87` |
| `test_the_real_solution_controllers_get_past_their_imports` (p4runtime) | `AssertionError: 'ModuleNotFoundError' unexpectedly found in '…No module named \'p4runtime_lib\'…'` | `:91`, `:98` |
| 同上 (flowcache) | 同上 | `:101`, `:108` |
| `test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib` (p4runtime) | `AssertionError: 0 != 1 : Traceback …`，`ModuleNotFoundError: No module named 'p4runtime_lib'` | `:111`, `:118`, `:121` |
| 同上 (flowcache) | 同上 | `:125`, `:132`, `:135` |

⇒ 6 個 failure 裡 **5 個**帶著 live 那句 `No module named 'p4runtime_lib'`，**1 個**是 list 不相等（那格測的是「繼承值排在 utils 後面」，舊碼根本沒有 utils 可排）。

## R2.6 （judge 第 6 項）mutant 102 在 production 裡是等價的

更正 round 1 §1.3 表格最後一列之前那列，以及 §3 的 102 列（「這台筆電上剛好對，換一棵樹就錯」）：

- `UTILS = os.path.join(TUT, "utils")`（`drive_exercise.py:80`）；
- `main()` 產生 exdir 的地方只有一處：`exdir = os.path.join(TUT, "exercises", ex)`（`bf349b64` 的 `:3147`；`da0fa021` 是 `:3146`）。
- ⇒ 對 `main()` 能產生的**每一個** exdir，`tutorials_utils_of(exdir) == UTILS`。**102 在 production 裡與原碼等價**，沒有任何一次真的執行會因此不同；
  「換一棵樹」這種情況從 `main()` 走不到。
- 它被殺掉，只是因為測試用的是 temp tree。它守的是工單的**設計要求**（「由 exdir 推，不要寫死」），不是一個行為。
  留著它，是為了讓那條要求有人守；**但它的「✅ caught」不能拿來當作有行為缺陷被抓到的證據**。

## R2.7 （judge 第 7 項）anchor 檢查的 ok(N) 為什麼不等於 mutant 數

`check_gate_anchors.py` 數的是**不重複的 anchor 字串**，再加上負對照的那一個 anchor，**不是 mutant 數**。
log：`check_gate_anchors.count-explained.p4d-bf349b64.log`（三個 rev 的 matrix，加上 gate 表格自己的去重計數）。

| rev | mutants | 不重複的 mutation anchor | ＋負對照 | checker |
|---|---|---|---|---|
| `0c85ad9c` | 97 | 95（`ports == [0], G_BOTH,` 與 `reflushed = self.h.flush_arp()` 各被 2 個共用） | 96 | `ok(96)` |
| `da0fa021` | 104 | 99（＋4：98/99/100 共用 `if self.fabric != "ndtwin" and os.path.dirname(ctrl):`；101/102 共用 `return os.path.normpath(…)`；103；104） | 100 | `ok(100)` |
| `bf349b64` | 106 | 101（＋2：105 是兩行的 anchor，跟 98–100 那一行**不同**；106 是 `say` 那一行） | 102 | `ok(102)` |

## R2.8 （judge 附註，不需改碼）「貼出來就能重跑」只在 cwd＝exdir 時成立

- controller 讀的是 `./build/…`（`--p4info`／`--bmv2-json` 的預設值）。driver 用 `cwd=self.exdir` 啟動它。
- 所以 C1 那行指令要**在 exercise 目錄裡**貼才會重現。這個限制在修法之前就有。
- round 1 §1.2 的「貼出來就能重跑」要加上這個但書。
- `bf349b64` 在 driver 的註解（`:1586-1587`）和 C1 那格測試的 docstring 裡寫明了這一點；
  那格測試本身一直是以 `cwd=kw["cwd"]`（＝exdir）執行。

## R2.9 閘門（全部在 final head `bf349b64`、worktree clean）

| gate | log | 結果 |
|---|---|---|
| driver 離線 suite | `test_drive_exercise.p4d-bf349b64.log` | **`Ran 170 tests` OK**，rc 0，0 skipped；`/tmp/drv-*` 前後都 0 |
| mutation gate | `mutate_drive_exercise.p4d-bf349b64.log` | **`106 mutations, 0 survived`**，rc 0（20:03:10–20:35:57）。🔴 log 檔頭寫的 `[nothing else running]` **只在開跑那一刻成立**：跑的期間我另外跑了三個很短的唯讀指令——20:03:27 O3 的 stdlib 附加段（p4dev python 讀 `~/tutorials/utils` 的目錄列表）、20:04:11 anchor 計數說明（`check_gate_anchors.py` 讀 git 物件）、20:05:59 紅燈 blob 還原（`git show`＋`hash-object --stdin`，不寫入）。三個都沒碰 worktree、driver、tests 目錄或 `/tmp/drv-*`；原始 log 保留原樣，不改；baseline `Ran 170 tests` 綠；負對照綠；原檔 byte-identical（sha256 `a732f060…`＝`bf349b64` 的 driver）；結束時 worktree clean、`/tmp/drv-*`＝0、`/tmp/drive-exercise-mutate-*`＝0 |
| gate 的自我測試 | `test_mutate_gate_dead_mutant.p4d-bf349b64.log` | **`Ran 43 checks, 0 failed`**，rc 0（這次跑的時候**沒有**別的東西同時在跑） |
| anchor 檢查 | `check_gate_anchors.mutate_drive_exercise.p4d-bf349b64.log` | `ok(102)`，rc 0（為什麼是 102，見 §R2.7） |
| 105／106 對 round-1 測試檔 | `demo_mutants_105_106_vs_round1.p4d-bf349b64.log` | 對照組 169 OK；105、106 對 round-1 **都活**；對目前的 suite **都死**（§R2.1–R2.2） |
| O2／O3／O7 原始 log | `obs_O2_…`、`obs_O3_…`、`obs_O7_…` `.p4d-bf349b64.log` | §R2.4 |
| 紅燈 blob 還原 | `red_first_blob_reconstruction.p4d-bf349b64.log` | 交付版去掉 `:2626` 那一行 ⇒ `888d7db5`（§R2.3） |
| anchor 計數說明 | `check_gate_anchors.count-explained.p4d-bf349b64.log` | §R2.7 |

新 mutant 與殺手：

| # | mutant | 被誰殺（gate 判定 ✅） | also red | `mutate_drive_exercise.p4d-bf349b64.log` |
|---|---|---|---|---|
| **105** | 在 `if` 之前對每一條臂 `env.pop("PYTHONPATH")` | `test_the_skeleton_arm_is_handed_the_environment_it_always_had` | `test_the_ndtwin_arm_is_handed_the_environment_it_always_had` | `:654-658` |
| **106** | 只把 `say` 那一行改回 `" ".join(argv)` | `test_the_printed_start_line_carries_the_prefix_on_the_solution_arm_only` | （無） | `:660-664` |
| 98–104 | 同 round 1 §3 | 同 round 1 §3，全部 ✅ | 98、99、100、101、102、104 的 also red 多了新的 start-line cell | `:612-652` |

新 cell `test_the_printed_start_line_carries_the_prefix_on_the_solution_arm_only` 是 106 的殺手，也出現在 6 個 mutant 的 also red 裡。
另外兩個守衛 cell 的「帶繼承值」subtest 由 105 打紅（demo log：6 個 subtest）。
⇒ round 2 新增或改寫的每一格，都在這一輪被看到紅過。

## R2.10 被取代的 round-1 說法

| round-1 位置 | 原句（摘） | 現在 |
|---|---|---|
| §0 | 「suite 169 綠、mutation 104/0（head `da0fa021`）」 | 對 `da0fa021` 仍然成立（orchestrator 也重跑過）；**final head 是 `bf349b64`：170／106/0**（§R2.9） |
| §1.2 | 「報告裡那行貼出來就能重跑」 | 只在 cwd＝exdir 時成立（§R2.8） |
| §1.3 表「寫死 UTILS」列、§3 的 102 列 | 「換一棵樹就錯」 | production 裡等價；只守設計要求（§R2.6） |
| §2 O2、O3、O7 | 沒有原始 log | 已補，是 `bf349b64` 上的重跑（§R2.4）；O7 的 root 那一半仍是 INFERRED |
| §2 O4 | 「4 個紅，訊息都是 live 那句」「紅燈先看到（修 driver 之前）」 | 6 個 failure、5 個帶 live 那句、1 個是 list 不相等；跑的是 test blob `888d7db5`；log 不證明先後（§R2.3、§R2.5） |
| §4 第 1 列 | 紅燈 log 當成交付測試檔的紅 | 交付測試檔的紅＝round-1 gate mutant 98（`:604-608`）（§R2.3） |
| §4 anchor 列 | `ok(100)` 沒說明 | §R2.7 |
| §7 最後一點「測試逐字釘住」 | 骨架臂 argv／env 被釘住 | round 1 只在「沒有繼承 PYTHONPATH」時釘住；現在兩種狀態都釘（§R2.1） |
| §6 前提、§7「跑到的不是 `4c790d8c`」 | 「確認那個路徑的 blob 是 `4c790d8c`」 | **改成 `13f60fda`**（`bf349b64` 的 driver；跟 `4c790d8c` 只差一行註解） |

## R2.11 `git diff --stat`

```
$ git diff --stat 0c85ad9c..bf349b64
 .../2026-09-04_p4-tutorial-exercise-prep/DRIVER.md |  13 ++
 .../drive_exercise.py                              |  39 +++-
 .../tests/test_drive_exercise.py                   | 246 +++++++++++++++++++++
 tests/shell/mutate_drive_exercise.sh               |  77 +++++++
 4 files changed, 373 insertions(+), 2 deletions(-)

$ git diff --stat da0fa021..bf349b64
 .../2026-09-04_p4-tutorial-exercise-prep/DRIVER.md |   2 +-
 .../drive_exercise.py                              |   3 +-
 .../tests/test_drive_exercise.py                   | 111 ++++++++++++++++-----
 tests/shell/mutate_drive_exercise.sh               |  19 ++++
 4 files changed, 107 insertions(+), 28 deletions(-)
```

## R2.12 給 orchestrator：指令不變，要查的 blob 換了

- 兩行指令與 round 1 §6 相同（不帶 `--fabric`、`sudo -n` 開頭、用 main checkout 的絕對路徑）。
- 前提改成：把 **`bf349b64`** 併進 main checkout 的 trunk，並確認那個路徑的 driver blob 是 **`13f60fda`**。
  指令：`git -C /home/adam/Desktop/NDTwin-Kernel hash-object doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py`。

```
sudo -n /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py flowcache --which solution
sudo -n /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py p4runtime --which solution
```

預期判定不變（仍是 INFERRED）：兩支都 **`>>> PASS (4/4)`，exit 0**，判讀方式見 round 1 §7。
從 `4c790d8c` 到 `13f60fda` 只改了一行註解，所以 round 1 對 `da0fa021` 做的所有推導，對 `bf349b64` 照樣成立。
