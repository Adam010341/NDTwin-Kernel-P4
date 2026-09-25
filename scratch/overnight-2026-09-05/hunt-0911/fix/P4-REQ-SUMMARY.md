# P4-REQ-SUMMARY — `p4_proxy/requirements.txt` 對齊實測環境＋試升 protobuf

[Co-developed with claude code -- Adam]

- worker：REQ；票：`doc/audit/2026-09-25_p4proxy-requirements/TICKET-p4proxy-requirements.md`（紀律＝`TICKET-P4-heartbeat.md` §3）
- worktree：`scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925`；base `62f76cf5`
- 交件時間：第一輪 2026-09-25 13:2x CST；**第二輪（審查後修正）17:4x CST（09:4x UTC）**
- **head sha（兩條分支，都未 push、未 merge）**
  - 任務 1（對齊）：`fix/p4proxy-requirements-0925` ＝ **`851cefd79e26ee2fb481e461a7bd77ebaeb5b329`**（第二輪；父 `55cebe6c`，祖父 `62f76cf5`）
  - 任務 2（候選）：`cand/p4proxy-protobuf5-0925` ＝ **`7cc50b4284e89d8f2459d560633697656d49254d`**（父 `55cebe6c`）。**第二輪依 orchestrator 指示凍結，沒動**；judge 裁「只能 live 試跑，不可併」，要不要繼續做交給 Adam。
  - worktree 目前停在 `fix/p4proxy-requirements-0925`。
- 所有 log：`scratch/overnight-2026-09-05/logs/gates-0910/*.p4req-*.log`。第二輪的 log（`*.p4req-851cefd7.log`，共 48 份，其中 6 份是 `*_verdictdiff_*`）第一行都是完整 HEAD sha＋venv 路徑。有三份不跑任何直譯器，第一行寫 `venv n/a` 或不寫 venv：`build_copy_hashes`、`scripts_sha256`、`verdict_diffs_round1`。最後這份只 diff 第一輪存下的 TSV，各 TSV 對應的 `.log` 第一行就記著 venv。第一輪有兩份不合這個格式，見 §R2.5；腳本與 `SHA256SUMS` 在 `logs/gates-0910/scripts-p4req/`。

---

## R2. 第二輪（2026-09-25 17:xx，judge 報告 `logs/orchestrator-0924/intake-0925/judge-REQ-55cebe6c-7cc50b42.md` 之後）

本輪只修對齊分支；候選分支凍結在 `7cc50b42`。新 commit **`851cefd7`**（`git diff --stat 55cebe6c 851cefd7`：2 檔，+30／−16）。

### R2.1 judge #1：starlette 是直接 import，改成 pin（`851cefd7`）

- **OBSERVED**：`starlette.concurrency` 在 `p4_proxy/proxy_agent/api_routes.py`；`starlette.requests` 在 `tests/test_multicast_group.py`、`tests/test_table_entry_route.py`（import 覆蓋檢查列出的，見 R2.2）。fastapi 0.139.2 的 METADATA 寫 `Requires-Dist: starlette>=0.46.0`。
- **改動**：加 `starlette==1.3.1`（主 venv 的版本），附註說明它是直接 import。header 的宣稱範圍改成「p4_proxy/、它的測試、tools/p4_exercise/ import 的每個套件都 pin 住」。沒 pin 的「被帶進來的套件」從 12 個改成 11 個；這個數字是先用 dry-run 算、再用 fresh venv 核對的（R2.3 的 freeze diff 裡，除了 googleapis 之外剛好 11 行不同）。
- **重建（跑過）**：`venv-aligned2` 從 **commit 後**的檔案建立（log 第二行記下兩邊 sha256 都是 `13b261ff…`）：
  ```
  /home/adam/miniconda3/bin/python3 -m venv <wt>/scratch/venv-aligned2
  (cd <wt>) <wt>/scratch/venv-aligned2/bin/python -m pip install -r p4_proxy/requirements.txt   # pip 26.0.1, rc=0, pip check: No broken requirements
  ```
  另外建了 `venv-py312b`（`/usr/bin/python3.12`，pip 24.0），同一份檔案，給 CI 的 3.12 對照。兩個 venv 都裝到 `starlette==1.3.1`。
  Log：`venv_create_aligned2.p4req-851cefd7.log`、`venv_create_py312b.p4req-851cefd7.log`（兩份的結尾都有完整 freeze）。

| suite @`851cefd7` | 主 venv | venv-aligned2（3.13.13） | venv-py312b（3.12.3） |
|---|---|---|---|
| p4_proxy（41 檔） | Ran 1557 / OK (skipped=1) | Ran 1557 / OK (skipped=1) | Ran 1557 / OK (skipped=1) |
| p4_exercise（真 HOME） | Ran 187 / OK | Ran 187 / OK | Ran 187 / OK |
| p4_exercise（空 HOME） | Ran 187 / OK (skipped=1) | Ran 187 / OK (skipped=1) | Ran 187 / OK (skipped=1) |
| **逐條 id diff 對主 venv（存檔、沒剪）** | — | 三套都 **0 行**（1557／187／187 id） | 三套都 **0 行** |

  - 逐條 diff 的完整檔案：`{p4_proxy_suite,p4_exercise_suite,p4_exercise_suite_notutorials}_verdictdiff_main_vs_{aligned2,py312b}.p4req-851cefd7.log`。
  - 判決 TSV：`*_verdicts_{main,aligned2,py312b}.p4req-851cefd7.tsv`。
  - 本輪起 empty-HOME 那套和 3.12 都有逐條比對（judge 列的兩個缺口）。
- **freeze 差異（整份存檔）**：`freeze_main_vs_aligned2.p4req-851cefd7.log`，共 12 行不同：googleapis-common-protos（1.75.0→1.73.0，刻意的），加上 11 個沒 pin 的（annotated-doc、annotated-types、anyio、certifi、charset-normalizer、click、idna、pydantic、pydantic-core、typing-inspection、urllib3）。**starlette 兩邊都是 1.3.1。**
- **check_pins（跑過）**：
  - `62f76cf5` 的檔案對主 venv：RED 6 行。
  - `55cebe6c` 的檔案對主 venv：GREEN。**這正是 judge 說的盲點**：檔案裡沒有 starlette 這一行，check_pins 就看不到。
  - `851cefd7` 的檔案對主 venv：GREEN（starlette MATCH 1.3.1＝1.3.1；googleapis 列為 DECLARED-MISMATCH）。
  - `851cefd7` 的檔案對 venv-aligned2：GREEN，每一行都 MATCH。
  - Log：`check_pins_file-{62f76cf5,55cebe6c,851cefd7}_vs_main.p4req-851cefd7.log`、`check_pins_file-851cefd7_vs_aligned2.p4req-851cefd7.log`。

### R2.2 import 覆蓋檢查（新工具；證據，**沒 commit 進 repo**）

- 工具：`scripts-p4req/check_imports_vs_requirements.py`。
  - 用 ast 掃 `p4_proxy/`（不含 venv）和 `tools/p4_exercise/` 底下每個 `.py` 的絕對 import。函式內、try 區塊內的也算。
  - 標準庫用 `sys.stdlib_module_names` 判斷。repo 內的模組算本地。
  - 其他的，用**受測 venv** 中各 distribution 自己的檔案清單對應到套件，不 import 任何第三方套件。
  - 有 import、檔案沒列 ⇒ MISSING（紅）；對不到任何已安裝套件、也沒被豁免 ⇒ UNRESOLVED（紅）。
- 豁免是以 (模組, 檔案) 為單位並寫明理由；同一個模組從別的檔案被 import 就會再紅。目前三組：
  - `mininet`／`network_traffic_generator`／`nornir`：只允許出現在 `p4_proxy/mininet/{p4_testbed_topo,ntg_bmv2_topo}.py`。這兩支由 ndtwin-lab 用 NTG_PY 以 root 執行（ndtwin-lab:99,564,581）。
  - `p4runtime_lib`：只允許出現在 `tools/p4_exercise/run_external_controller.py` 和 tutorials fixture。它是 tutorials 的 utils，執行時才加進 sys.path（run_external_controller.py:116-175）。
- **工具自己的錯（寫的時候抓到並修掉）**：`p4_proxy/mininet/` 沒有 `__init__.py`，是 namespace 目錄。第一版把「本地有同名目錄」當成本地模組，於是**把真正的 `mininet` 套件藏掉了**。依 PEP 420，任何 sys.path 上的 regular package 都會蓋過 namespace portion。修正後，沒有 `__init__` 的目錄只在「沒有已安裝套件、也沒有豁免條目認領這個名字」時才算本地。
- **結果（全部跑過，用主 venv 做對應）**：

| 檔案 | 結果 | 缺什麼 |
|---|---|---|
| `62f76cf5`（舊檔） | **RED** | MISSING starlette |
| `55cebe6c`（第一輪） | **RED** | MISSING starlette |
| `851cefd7`（本輪） | **GREEN** | — |
| `851cefd7` 刪掉 `requests==` 一行（負對照） | **RED** | MISSING requests |
| `851cefd7` 刪掉 `starlette==` 一行（負對照） | **RED** | MISSING starlette |
| `851cefd7`，改用 venv-aligned2 做對應 | GREEN | — |

  Log：`check_imports_file-{62f76cf5,55cebe6c,851cefd7,851cefd7-minus-requests,851cefd7-minus-starlette}.p4req-851cefd7.log`、`check_imports_file-851cefd7.under-aligned2.p4req-851cefd7.log`。GREEN 的那份也把「列了但掃描範圍內沒人直接 import」的行寫成 INFO：thrift（檔案自己寫明只給 CLI 用）；googleapis-common-protos 也是間接依賴。
- **不是持續防護**：工具放在 gitignored 的 scratch 裡，CI 和別台機器都跑不到。要升格成閘門得另外開票，入 repo 的時候要處理「受測 venv 不存在就 SKIP」。我沒做，因為本輪只修對齊分支。

### R2.3 judge #2、#3：兩句措辭（`851cefd7`）

- **#2**：requirements.txt 原本 `:29-30` 寫「p4dev-python-venv 是測試跑的直譯器」，已改寫：
  - 2026-08 修正那條 floor 時（`49dcbfca`，08-10），測試跑在 p4dev-python-venv；今天跑在 p4_proxy/venv，因為 `l1_unit_tests.sh:311` 先試 `$P4_PROXY_PY`，而 `components.env:45` 把它預設成 p4_proxy/venv。
  - 兩者都是 protobuf 3.20.3。p4dev 那個是本輪實查的：`/home/adam/p4dev-python-venv/bin/python -c 'import google.protobuf'` 印出 3.20.3，唯讀，沒另存 log。
- **#3**：「使用手冊 P4 路徑給使用者的就是 3.12」原本是推論，現在改成引用 doc/ 裡的一次手冊實跑紀錄，並寫明「不是手冊原文、沒重讀手冊」。requirements.txt 和 ci.yml 兩處都改了。依據（**讀過**，都是 repo 內檔案）：
  - `doc/audit/2026-09-02_manual-usertest/run-06-opus/JOURNAL.md:3`：全新的 Ubuntu 24.04.4 VM，docs snapshot 是 website commit c5262c3。
  - `CHECKLIST.md:40`：A30「6.3 `python3 -m venv p4_proxy/venv` + reqs」，預期 3.12.x。
  - `CHECKLIST.md:372`：`p4_proxy/venv/bin/python --version -> Python 3.12.3`。
  - **順帶觀察到**：同一列記的是 `protobuf 3.20.3, p4runtime 1.4.1, grpcio 1.83.1`。照手冊裝的使用者，拿到的正是舊檔的 floor 版本，跟開發機的 venv 不同。這佐證了本票的前提（INFERRED：那一輪的 requirements.txt 就是當時公開 repo 上的版本）。
  - 手冊原文沒讀：本機唯一的網站 docs 是 `/home/adam/ndtwin-website_docs-p4-bmv2-environment_2026-08-28.bundle`，我沒解開。

### R2.4 judge #4：第一輪寫成 OBSERVED、卻沒存檔的東西，本輪補成檔案

全部由 `scripts-p4req/evidence_r2.sh` 產生，第一行是完整 sha＋venv：

| 宣稱 | 檔案 | 內容 |
|---|---|---|
| 主 venv 前後指紋 | `mainvenv_fingerprint.p4req-851cefd7.log`、`mainvenv_fingerprint_final.p4req-851cefd7.log` | BEFORE（12:54:57 CST 寫下）＝NOW＝`f30dfcae…`；BEFORE 之後沒有任何檔案較新 |
| **主 venv 並非全程零寫入**（新發現，見下） | `mainvenv_pyc_writes_today.p4req-851cefd7.log`、`mainvenv_touched_today.p4req-851cefd7.log` | 今天 mtime 的檔案共 189 個，全是 `site-packages/pip/**/__pycache__/*.pyc`：11:56 有 146 個，12:51–12:52 有 43 個 |
| 主 venv `pip check` 原文 | `mainvenv_pip_check.p4req-851cefd7.log` | `googleapis-common-protos 1.75.0 has requirement protobuf<8.0.0,>=4.25.8, but you have protobuf 3.20.3.`，rc=1；另附 freeze、backend、1.75.0 的 METADATA、status_pb2 開頭、dist-info mtime（安裝史） |
| build 複製的雜湊 | `build_copy_hashes.p4req-851cefd7.log` | 兩組 sha256（`0b19d789…`、`d54ff552…`）、`ls --full-time`（mtime 一致，cp -p）、cmp identical |
| p4runtime 1.5.0 是 PyPI 最新 | `pip_index_versions.p4req-851cefd7.log` | `p4runtime (1.5.0) Available versions: 1.5.0, 1.4.1, 1.3.0`；另有 protobuf、googleapis、grpcio、grpcio-tools、starlette、fastapi 的原始輸出 |
| 1.73.0 是 pip 自己解出來的 | `googleapis_resolution.p4req-851cefd7.log` | 把 googleapis 那行拿掉後 dry-run，解出 `googleapis-common-protos 1.73.0`。各版宣告的 protobuf 範圍：1.73.0 `>=3.20.2,<7`；1.73.1、1.74.0、1.75.0 `>=4.25.8`；1.75.4 `>=6.33.5` |
| 第一輪各組「diff 0 行」 | `verdict_diffs_round1.p4req-851cefd7.log`（166 行，沒剪） | main 對 aligned／pb5_pyimpl／pb5_regen@55cebe6c、main 對 cand@7cc50b42：兩套都是 0；main 對 pb5_upb：p4_exercise **98 行全文**，p4_proxy「NO VERDICT FILE（沒載入）」 |
| 腳本完整性 | `scripts_sha256.p4req-851cefd7.log`、`scripts-p4req/SHA256SUMS.r2`、`scripts-p4req/README.md` | 第一輪的 SHA256SUMS：本輪沒改的腳本全部 OK；改過的兩支（run_suites、compare_verbose）第一輪版本另存成 `*.v2.sh`，雜湊與舊 SUMS 相符。README 寫明 `scripts-p4req/regen_p4runtime_pb2.py` 是**實驗版**，不是候選工具 |

**新發現、照實揭露：主 venv 被寫進了 pip 的 bytecode 快取**
- **OBSERVED**：主 venv 今天有 189 個 `.pyc` 被寫入，全部在 `site-packages/pip/` 的 `__pycache__` 底下。沒有任何 `.py`、dist-info 或其他套件的檔案被動到。時間分兩群：
  - 11:56 CST，146 個。
  - 12:51:35–12:52:28 CST，43 個，其中有 `pip/_internal/commands/__pycache__/freeze.cpython-313.pyc`。
- **INFERRED**：12:51–12:52 那 43 個幾乎可以確定是我寫的。開工第一次看主 venv 時，我沒設 `PYTHONDONTWRITEBYTECODE` 就跑了 `pip freeze`、`pip check`、`pip show`；時間吻合，而且寫入的正是 freeze 相關模組。那次查看發生在 BEFORE 指紋（12:54:57）**之前**，所以第一輪「前後指紋相同 ⇒ 全程只讀」這個說法**不成立**。
  - 正確的說法是：從 BEFORE 之後到現在，主 venv 零寫入（指紋相同，而且 12:53 之後沒有任何較新的檔案）。在那之前，我的 pip 指令寫了 pip 自己的 bytecode 快取。
  - 11:56 那 146 個早於本 worker 開工（session 目錄 12:45 建立），來源不明，不是我。
  - 影響：`pip freeze`、套件版本、backend 都沒變；那些 `.pyc` 是 Python 載入 pip 時自動產生的快取。
  - 我**沒有**刪它們，刪也是一次寫入。要不要清由 orchestrator 決定：刪掉的話，下一次有人用那個 venv 跑 pip 就會重新產生。

### R2.5 SUMMARY 各判定的分類（judge 表中 CONTRADICTED、UNDER-EVIDENCED、UNTESTED 的列，本輪後狀態）

| 判定（第一輪位置） | judge 分類 | 本輪後 | 依據 |
|---|---|---|---|
| §0-1 每個直接依賴都用 `==` 釘在主 venv 的版本 | **CONTRADICTED** | **已修正**（`851cefd7`），措辭改成「p4_proxy/、它的測試、tools/p4_exercise/ import 的每個套件」 | R2.1；import 覆蓋 `851cefd7` GREEN、舊檔兩份都 RED |
| §0-2／§3「3.12 就是使用者的直譯器」 | UNDER-EVIDENCED | **改成有引用的說法**：一次手冊實跑，全新 Ubuntu 24.04.4 VM 得到 Python 3.12.3。仍然**不是**手冊原文 | R2.3 |
| §4.2 p4runtime 1.5.0 是 PyPI 最新 | UNDER-EVIDENCED | **SUPPORTED（已存檔）** | `pip_index_versions.p4req-851cefd7.log` |
| §0-6 主 venv 全程只讀、指紋相同 | UNDER-EVIDENCED | **部分推翻**：BEFORE 之後零寫入（已存檔）；BEFORE 之前我的 pip 指令很可能寫了 43 個 pip `.pyc` | R2.4 |
| §1 主 venv 安裝史（dist-info mtime） | UNDER-EVIDENCED | **SUPPORTED（已存檔）** | `mainvenv_pip_check.p4req-851cefd7.log` 末段 |
| §1 主 venv pip check 不一致 | SUPPORTED（原文沒存） | **原文已存** | 同上 |
| §1 build 複製雜湊與主 checkout 相同 | UNDER-EVIDENCED | **SUPPORTED（已存檔）** | `build_copy_hashes.p4req-851cefd7.log` |
| §2.1 1.73.0 是 pip 解出的最新版 | UNDER-EVIDENCED | **SUPPORTED（已存檔）**：拿掉 pin 後 dry-run 解出 1.73.0，下一版 1.73.1 起宣告 `>=4.25.8` | `googleapis_resolution.p4req-851cefd7.log` |
| §0-1 3.12.3 也跑過、數字一樣 | SUPPORTED（僅計數） | **SUPPORTED（逐條）**，@`851cefd7`，venv-py312b，三套都 diff 0 | R2.1 |
| 各「diff 0 行」只印到終端機 | （#4） | **整份存檔**；第一輪 v2 那份被剪過的 log 保留原樣，旁邊補上全文 | `verdict_diffs_round1…`、`*_verdictdiff_*…851cefd7` |
| **§0-5／§5.1 切換 venv 只要 `export P4_PROXY_PY`** | **UNTESTED** | **仍然 UNTESTED**，已在 §0-5 與 §5.1 內文標注 | 只讀過程式碼，沒執行 |
| §5.1 unset 後 proxy 自動重啟、§5.3 venv 可以整包搬 | UNTESTED | **仍然 UNTESTED**（已標注） | 同上 |
| §2.2「pip 26.0.1」沒有 log | （附註） | 已存：`venv_create_aligned2…` 記錄了 `pip 26.0.1`；py312b 是 `pip 24.0` | R2.1 |

**第一輪 log 格式不符的（沒改寫，舊 log 不覆寫；本輪起的新 log 都合格式）**：
- `regen_tool_red_green.p4req-55cebe6c-wt.log`：第一行只有短 sha。
- `venv_create_cand.p4req-55cebe6c-wt.log`：第一行沒有直譯器。
- 第一輪的 suite log 第一行寫的是 realpath（所有 3.13 venv 都是同一支 miniconda binary），括號裡的 venv 路徑才分得出是哪個 venv；本輪 v3 的第一行直接寫 `venv <sys.prefix>`。
- `run_suites.sh` v2 註解裡的「複製出來的 venv」只是在講為什麼用 `python -m pip`，本報告的 venv 沒有任何一個是複製出來的，全部有新建 log。

### R2.6 本輪閘門最後一行（全部經 guard，JOBS=1 LOCK_WAIT=10800；「跑過」）

| log（`logs/gates-0910/`） | 最後一行 |
|---|---|
| `p4_proxy_suite_{main,aligned2,py312b}.p4req-851cefd7` | 三個都 Ran 1557 / OK (skipped=1) |
| `p4_exercise_suite{,_notutorials}_{main,aligned2,py312b}.p4req-851cefd7` | Ran 187 / OK；OK (skipped=1) |
| `*_verdictdiff_main_vs_{aligned2,py312b}.p4req-851cefd7`（6 份） | `# diff lines (<,>): 0` |
| `check_pins_file-851cefd7_vs_{main,aligned2}` | RESULT: GREEN |
| `check_imports_file-851cefd7`／`-62f76cf5`／`-55cebe6c` | GREEN／RED (starlette)／RED (starlette) |
| `check_gate_anchors.p4req-851cefd7` | 116/116 cells ok (0 not ok, 0 NOT CHECKED) |
| `scripts_sha256.p4req-851cefd7` | 本輪改過的兩支 FAILED（預期；v2 另存且雜湊相符），其餘 OK；寫出 SHA256SUMS.r2 |

venv 佔用新增：`venv-aligned2` 80M、`venv-py312b` 83M，全部 venv 合計約 690M；`df -h /` 剩 10G。

### R2.7 orchestrator 追加指示：候選要進 live 試跑（Adam 決定）

- `scratch/venv-cand`、`scratch/venv-cand312` **沒刪、沒改**。本輪沒有任何指令寫過它們：兩者最新的 mtime 分別是第一輪重生時的 13:13:09 與 13:15:37 CST。
  - 交件時的指紋存在 `venv_cand_fingerprint.p4req-851cefd7.log`：venv-cand `aa1d4c72…`、venv-cand312 `91dc9753…`，另附 8 個重生模組的 sha256，兩個 venv 完全一致。
  - orchestrator 開跑前可以用同一個方法重算，確認 venv 沒被動過。
- 候選分支 `cand/p4proxy-protobuf5-0925` 仍在 `7cc50b42`。
- **其他輔助 venv 一個都沒刪**：aligned、py312、pb5、pb5regen、aligned2、py312b 都還在。磁碟剩 10G，不需要騰空間。之後要清的話，這些都可以刪，唯獨 venv-cand 和 venv-cand312 不行。

---

## 0. 結論（第一輪原文；第二輪的更正以 ⚠️R2 標在行內）

1. **對齊完成（`55cebe6c`）**。檔案改成實跑 venv 的版本，每個直接依賴都用 `==` 釘住。⚠️R2：judge 推翻「每個直接依賴」這句，因為 starlette 是直接 import 卻沒 pin。已在 `851cefd7` 修正，見 R2.1。用改好的檔案**新建**的 venv 跑兩套測試，與主 venv 在**同一個 commit** 上的結果**逐條 test id 相同**：p4_proxy 1557 tests、OK、skip 1；tools/p4_exercise 187 tests、OK。另外用 Python 3.12.3 也跑過，數字一樣。
2. **CI 維持 3.12，不改**。理由在 §3，`ci.yml` 裡加了 3 行註解說明。
3. **只換 requirements 升到 protobuf 5.29.6：沒過**。proxy 連 `p4_client` 都 import 不了，p4_proxy 那套測試**根本載不起來**（跑了 0 個），p4_exercise 187 個裡 49 個紅。卡在 PyPI 上最新的 p4runtime 1.5.0 附的 `_pb2`，是 3.19 以前的 protoc 產生的舊碼（§4.2）。
4. **有兩種繞法，離線測試都通過（逐條 test id 相同）**：(B) 設 `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python`；(C) 用 p4runtime 舊模組內嵌的 descriptor **重新產生 `_pb2`**（不用下載 .proto）。**候選 commit `7cc50b42` 用的是 C**：安裝變成三道指令，所以 repo 裡另外三處印安裝指令的地方和 CI 都要跟著改。**還沒跑 live**，要不要併，等 orchestrator 跑完 live 01／06 再決定（§4.5 列出併之前還差什麼）。
5. **live 切到升級後 venv 的最小方法**：只要 `export P4_PROXY_PY=<worktree>/scratch/venv-cand/bin/python`，不改任何預設（§5）。⚠️**UNTESTED**：這是讀程式碼得出的，沒執行過；切換是否生效要照 judge 報告「併入前 live 必須驗」第 2 項查 `/proc/<pid>/maps` 和 `environ`。
6. 主 checkout 的 `p4_proxy/venv` 從頭到尾只讀：開工前後對 path／size／mtime 做的指紋相同（`f30dfcae…`）。⚠️R2：**部分推翻**。指紋是在我第一次用 pip 查看之後才取的，那次查看很可能寫入了 43 個 pip `.pyc`，見 R2.4。沒碰任何 GitHub alert；沒 push、沒 merge；沒碰 lab；沒 sudo。

---

## 1. 環境事實（OBSERVED，本 session 實查）

| 項目 | 值 | 怎麼查的 |
|---|---|---|
| 主 venv 直譯器 | `/home/adam/miniconda3/bin/python3.13`，Python 3.13.13（Anaconda build，Apr 14 2026） | `readlink -f`、`-VV`、`pyvenv.cfg` |
| 主 venv 關鍵套件 | p4runtime 1.5.0、grpcio 1.82.1、protobuf 3.20.3（backend＝`python`）、googleapis-common-protos 1.75.0 | `pip freeze`、`api_implementation.Type()` |
| **主 venv 本身依賴不一致** | `pip check`：`googleapis-common-protos 1.75.0 has requirement protobuf<8.0.0,>=4.25.8, but you have protobuf 3.20.3` | `pip check`（唯讀） |
| 主 venv 安裝史 | 07-20 14:37 一次裝好全部，14:40 把 protobuf 單獨降到 3.20.3。1.75.0 就是這樣留下來的 | dist-info mtime |
| PyPI 上的 p4runtime | 只有 1.5.0／1.4.1／1.3.0，**1.5.0 是最新** | `pip index versions`（2026-09-25） |
| p4runtime 1.5.0 的 gencode 形狀 | `_descriptor.FileDescriptor(... create_key=_descriptor._internal_create_key)`，是 3.19 以前的直建 descriptor 寫法 | 讀 `p4/v1/p4runtime_pb2.py` 開頭 |
| 舊檔宣稱 | `p4runtime==1.4.1`、`grpcio>=1.50.0`、"Python 3.12, 2026-08-10, 312 tests" | `git show 62f76cf5:p4_proxy/requirements.txt` |
| `ci.yml` | `setup-python` `python-version: '3.12'`（:81），`pip install -r p4_proxy/requirements.txt`（:89） | 讀檔 |
| 本機直譯器 | `python3`＝miniconda 3.13.13；另有 `/usr/bin/python3.12`（3.12.3） | `which -a` |

**開工遇到的一個坑（OBSERVED）**：第一次用主 venv 在 base 跑 p4_proxy 那套，結果是紅的：`FAILED (failures=4, errors=80, skipped=11)`（`p4_proxy_suite_mainvenv.p4req-62f76cf5.log`，保留作證據）。原因是新 worktree 沒有 gitignored 的 `p4_proxy/p4_src/build/`（`Compiled P4 JSON for s1 not found`，82 個落在 `test_fabric_bring_up`、2 個在 `test_route_binding`）。前例是 symlink 到主 checkout；我改用**複製**，免得測試有機會寫回主 checkout。兩個檔的 sha256 與主 checkout 逐位元相同：`ndtwin_switch.json` 0b19d789…、`ndtwin_switch.p4info.txt` d54ff552…。補上之後就綠了。之後所有數字都在有 build 的條件下量的。

---

## 2. 任務 1：對齊（`55cebe6c`）

### 2.1 改了什麼（`git diff 62f76cf5 55cebe6c`：2 檔，+43／−8）

`p4_proxy/requirements.txt`：
- 檔頭改寫：說明檔案描述的是 `p4_proxy/venv`（Python 3.13.13、protobuf backend `python`）、驗證日期 2026-09-25、兩套測試的數字、「改 pin 必須連同兩套測試一起重跑」、transitive 依賴**不** pin（新 venv 有 12 個 transitive 比主 venv 新，數字照樣相同）、CI 為什麼是 3.12。
- `grpcio>=1.50.0` → `==1.82.1`；`p4runtime==1.4.1` → `==1.5.0`；`fastapi`／`uvicorn`／`networkx`／`requests` 從 floor 改成 `==`，版本照主 venv。
- **新增 `googleapis-common-protos==1.73.0`，附理由**：主 venv 的 1.75.0 宣告 `protobuf>=4.25.8`，跟 `protobuf==3.20.3` 衝突，pip **不可能**從檔案裝出那一對。1.73.0 是 pip 自己解出來、宣告範圍含 3.20.3 的最新版。
- `protobuf==3.20.3` 原封不動，補一段說明：到 1.5.0 為止舊 gencode 依然存在，並列出兩個 CVE。

`.github/workflows/ci.yml`：只在 `setup-python` 前面加 3 行註解，說明為什麼維持 3.12，行為不變。

### 2.2 venv 建立指令（實際執行）

```
# venv-aligned（Python 3.13.13，與主 venv 同一個 base 直譯器）
/home/adam/miniconda3/bin/python3 -m venv <wt>/scratch/venv-aligned
<wt>/scratch/venv-aligned/bin/pip install -r <wt>/p4_proxy/requirements.txt      # pip 26.0.1，rc=0，pip check：No broken requirements
# venv-py312（CI／使用者的 3.12，佐證 §3 的決定）
/usr/bin/python3.12 -m venv <wt>/scratch/venv-py312
<wt>/scratch/venv-py312/bin/pip install -r <wt>/p4_proxy/requirements.txt       # pip 24.0，rc=0，pip check 乾淨
```
（`<wt>`＝`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925`。venv 放在 worktree 的 `scratch/` 底下，那裡被 `.gitignore:46` 擋住，所以任何 `git add` 都帶不進去。）
venv-aligned 是用 commit 前的草稿安裝的。commit 後只改了註解，pin 完全一樣。另外用 commit 好的檔案做了 `pip install --dry-run`，結果是 0 個「Would install」（`venv_recheck_aligned.p4req-55cebe6c.log`）。
Log：`venv_create_aligned.p4req-62f76cf5-wt.log`、`venv_create_py312.p4req-55cebe6c.log`。

### 2.3 兩套測試並排（全部跑過，同一 commit `55cebe6c`，都經 `guarded_build.sh` JOBS=1 LOCK_WAIT=10800）

跑法跟 p4r 輪次一樣：p4_proxy 那套是 `cd p4_proxy && PYTHONPATH=p4_proxy python -m unittest tests.test_*`（41 個檔）；p4_exercise 是 `python -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests`，分成真 HOME 跟空 HOME 兩種。

| suite | 主 venv（3.13.13, pb 3.20.3） | venv-aligned（3.13.13, pb 3.20.3） | venv-py312（3.12.3, pb 3.20.3） |
|---|---|---|---|
| p4_proxy（41 檔） | Ran 1557 / OK (skipped=1) | Ran 1557 / OK (skipped=1) | Ran 1557 / OK (skipped=1) |
| p4_exercise（真 HOME） | Ran 187 / OK | Ran 187 / OK | Ran 187 / OK |
| p4_exercise（空 HOME） | Ran 187 / OK (skipped=1) | Ran 187 / OK (skipped=1) | Ran 187 / OK (skipped=1) |

參照舊結果：p4r 輪次在 `177b9f03` 也是 1557 / OK (skipped=1)（`p4_proxy_suite.p4r-177b9f03.log`），`3ff87a10` 的 p4_exercise 是 187 / OK。**可以直接比，沒有推翻任何東西。**主 venv 在 base `62f76cf5` 上也一樣（`*_main.p4req-62f76cf5.log`）。

**逐條 test id 比對**：只看數字相同不夠，一個 pass 變成 skip 不會改變 "Ran N / OK (skipped=1)"。所以用 `scripts-p4req/verdicts.py` 把每個 test id 的判決寫成 tsv 再 diff。主 venv 跟 venv-aligned：p4_proxy 1557 id、p4_exercise 187 id，**diff 0 行**。唯一的 skip 兩邊都是同一個：`tests.test_p4_client.LiveSwitchTest.test_installs_routes_and_the_clone_session`（要打真 switch，需 opt-in）。Log：`p4_proxy_suite_verdicts_{main,aligned}.p4req-55cebe6c.{log,tsv}` 等。

### 2.4 看過紅（這次改的是「檔案描述 venv」，測試抓不到，所以另做一道檢查）

兩套測試在新舊檔案下都會過，所以它們**不能**證明「檔案現在描述了 venv」。`scripts-p4req/check_pins_vs_venv.py` 把檔案每一行 pin 拿去對主 venv 的 `pip freeze`；`>=` 算「沒指名任何測過的版本」。
- 舊檔 `62f76cf5`：**RED**，6 行不描述 venv（p4runtime MISMATCH 1.4.1≠1.5.0；grpcio／fastapi／uvicorn／networkx／requests 都是 FLOOR）。
- 新檔 `55cebe6c`：**GREEN**，9 行 MATCH，另有 1 行 DECLARED-MISMATCH（googleapis-common-protos，理由見 §2.1）。
- Log：`check_pins_vs_mainvenv.p4req-{62f76cf5,55cebe6c}.log`

### 2.5 pip freeze（新 venv 對主 venv）

| 套件 | 主 venv | venv-aligned | venv-py312 | venv-pb5 | venv-cand | venv-cand312 |
|---|---|---|---|---|---|---|
| protobuf | 3.20.3 | 3.20.3 | 3.20.3 | **5.29.6** | **5.29.6** | **5.29.6** |
| p4runtime | 1.5.0 | 1.5.0 | 1.5.0 | 1.5.0 | 1.5.0（_pb2 重生） | 1.5.0（_pb2 重生） |
| grpcio | 1.82.1 | 1.82.1 | 1.82.1 | 1.82.1 | 1.82.1 | 1.82.1 |
| googleapis-common-protos | 1.75.0 | **1.73.0** | 1.73.0 | 1.75.0 | 1.75.0 | 1.75.0 |
| grpcio-tools | – | – | – | – | 1.71.2 | 1.71.2 |
| setuptools | – | – | – | – | 84.0.0 | 84.0.0 |
| fastapi／uvicorn／networkx／requests／hypothesis／thrift／h11／sortedcontainers／typing-extensions | 0.139.2／0.51.0／3.6.1／2.34.2／6.165.5／0.24.0／0.16.0／2.4.0／4.16.0 | 同左 | 同左 | 同左 | 同左 | 同左 |
| annotated-doc | 0.0.4 | 0.0.5 | 0.0.5 | 0.0.5 | 0.0.5 | 0.0.5 |
| annotated-types | 0.7.0 | 0.8.0 | ← | ← | ← | ← |
| anyio | 4.14.2 | 4.15.1 | ← | ← | ← | ← |
| certifi | 2026.6.17 | 2026.7.22 | ← | ← | ← | ← |
| charset-normalizer | 3.4.9 | 3.5.1 | ← | ← | ← | ← |
| click | 8.4.2 | 8.5.0 | ← | ← | ← | ← |
| idna | 3.18 | 3.20 | ← | ← | ← | ← |
| pydantic／pydantic-core | 2.13.4／2.46.4 | 2.13.5／2.46.5 | ← | ← | ← | ← |
| starlette | 1.3.1 | 1.7.0 | ← | ← | ← | ← |
| typing-inspection | 0.4.2 | 0.4.4 | ← | ← | ← | ← |
| urllib3 | 2.7.0 | 2.8.0 | ← | ← | ← | ← |

（「←」＝跟左邊一欄相同。各 venv 的完整 freeze 都在各自的 `venv_create_*.log` 末尾，也在每支 suite log 的檔頭。）

---

## 3. CI 的 Python 版本：維持 3.12，不改

- **OBSERVED**：`ci.yml` 是 3.12，檔案的驗證環境是 3.13.13。同一份（對齊後）檔案在 `/usr/bin/python3.12`（3.12.3）新建 venv 也裝得起來、`pip check` 乾淨，兩套測試數字完全一樣（§2.3 第三欄；`*_py312.p4req-55cebe6c.log`）。
- **不改的理由**：`ubuntu-24.04` runner 上的 3.12，就是使用手冊 P4 路徑的使用者 `python3 -m venv` 拿到的直譯器（repo 內的 VM／tester 腳本也都是用 `python3 -m venv p4_proxy/venv`）。開發機的 3.13 每一輪本機閘門都會跑到。CI 改成 3.13 等於重複覆蓋開發機，又失去使用者那一版；維持 3.12 兩邊都顧到。這個理由寫在 `ci.yml` 的註解和 requirements 檔頭裡。
- **INFERRED**（沒驗）：「手冊的使用者都在 Ubuntu 24.04」是從 CI runner 跟 repo 內 VM 腳本推的，我沒去讀對外手冊。 ⚠️R2：judge 標為 UNDER-EVIDENCED。本輪改成引用 doc/ 裡的一次手冊實跑紀錄（R2.3），requirements.txt 與 ci.yml 的措辭也同步改了；手冊原文仍然沒讀。

---

## 4. 任務 2：試升 protobuf >= 5.29.6

### 4.1 venv 建立指令（實際執行）

```
# venv-pb5：路線 A／B（只換 requirements）
sed -e 's/^protobuf==3\.20\.3$/protobuf==5.29.6/' -e 's/^googleapis-common-protos==1\.73\.0$/googleapis-common-protos==1.75.0/' \
    p4_proxy/requirements.txt > <wt>/scratch/requirements-pb5.txt          # 只改這兩行
/home/adam/miniconda3/bin/python3 -m venv <wt>/scratch/venv-pb5
<wt>/scratch/venv-pb5/bin/pip install -r <wt>/scratch/requirements-pb5.txt  # rc=0，pip check 乾淨
# venv-pb5regen：路線 C 的實驗（requirements-pb5 + grpcio-tools，pip 解出 1.71.2），然後用 scripts-p4req/regen_p4runtime_pb2.py 重生
# venv-cand：候選 commit 7cc50b42 的正式安裝流程，照檔頭寫的那三行
/home/adam/miniconda3/bin/python3 -m venv <wt>/scratch/venv-cand
<wt>/scratch/venv-cand/bin/pip install -r p4_proxy/requirements.txt         # （7cc50b42 的檔案；sha256 cdd80a9b… 與 commit 內一致）
<wt>/scratch/venv-cand/bin/python p4_proxy/regen_p4runtime_pb2.py
# venv-cand312：同一套流程改用 /usr/bin/python3.12
```
Log：`venv_create_pb5.p4req-55cebe6c.log`、`venv_create_pb5regen.p4req-55cebe6c.log`、`venv_create_cand.p4req-55cebe6c-wt.log`、`venv_create_cand312.p4req-7cc50b42.log`。

### 4.2 結果（全部跑過；A／B／C 在 `55cebe6c`，候選在 `7cc50b42`）

| 路線 | 條件 | p4_proxy（1557） | p4_exercise 真 HOME（187） | p4_exercise 空 HOME | 逐條 id 對主 venv |
|---|---|---|---|---|---|
| A：只換 requirements | protobuf 5.29.6，預設 backend（upb） | **載入就死：0 個 test**（rc=1） | **FAILED (failures=44, errors=5)** | FAILED (44, 5, skipped=1) | p4_proxy：沒有判決檔（RED）；p4_exercise：98 行 diff，49 個 not ok，全在 `test_preflight` |
| B：環境變數 | 同上＋`PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python` | Ran 1557 / OK (skipped=1) | Ran 187 / OK | OK (skipped=1) | **0 行 diff** |
| C：重生 _pb2（實驗 venv） | 5.29.6，upb，_pb2 由 grpcio-tools 1.71.2（libprotoc 29.0）重生 | Ran 1557 / OK (skipped=1) | Ran 187 / OK | OK (skipped=1) | **0 行 diff** |
| 候選 `7cc50b42`（venv-cand, 3.13.13） | 照檔頭三道指令新建 | Ran 1557 / OK (skipped=1) | Ran 187 / OK | OK (skipped=1) | **0 行 diff** |
| 候選 `7cc50b42`（venv-cand312, 3.12.3） | 同上，換 3.12 | Ran 1557 / OK (skipped=1) | Ran 187 / OK | OK (skipped=1) | （沒做逐條比對，只有數字） |
| 對照：主 venv @ `7cc50b42` | — | Ran 1557 / OK (skipped=1) | Ran 187 / OK | OK (skipped=1) | — |

**卡在哪裡（路線 A，OBSERVED，traceback 原文位置）**：
`tests/test_app_package_proxy.py:48` → `proxy_agent/main.py:11` → `proxy_agent/p4_client.py:7`（`from p4.v1 import p4runtime_pb2`）→ `p4/v1/p4runtime_pb2.py:17` → `p4/config/v1/p4info_pb2.py:15` → `p4/config/v1/p4types_pb2.py:36` `_descriptor.FieldDescriptor(... create_key=...)` → `google/protobuf/descriptor.py:626` `_CheckCalledFromGeneratedFile()` → `TypeError: Descriptors cannot be created directly.`
所以問題不在測試，**proxy 本身就起不來**：`main.py` 第 11 行就 import `p4_client`。p4_exercise 的 49 紅全部是 `preflight.py` 解析 p4info 時碰到同一個 TypeError（`"p4info ... does not parse: TypeError: Descriptors cannot be created directly"`）。
p4runtime 已經是 PyPI 最新，**不能靠升級 p4runtime 解決**。grpcio 跟這件事無關，它不依賴 protobuf。

Log：`p4_*_suite*_pb5_upb.p4req-55cebe6c.log`、`*_pb5_pyimpl.*`、`*_pb5_regen.*`、`*_cand.p4req-7cc50b42.log`、`*_cand312.*`、`*_verdicts_*.{log,tsv}`、`compare_main_vs_pb5_upb.v2.p4req-55cebe6c.log`。

### 4.3 候選 commit `7cc50b42` 的內容（`git diff 55cebe6c 7cc50b42`：6 檔，+234／−26）

- `p4_proxy/requirements.txt`：`protobuf==5.29.6`、`googleapis-common-protos==1.75.0`（現在跟主 venv 同版，也不再衝突）、新增 `grpcio-tools==1.71.2`（只給重生工具用；這是 pip 解出、protobuf 範圍含 5.29.6 的最新版，它產的碼要求 runtime ≥5.29.0）。檔頭第一段寫 **CANDIDATE／NOT merged／要三道指令／還沒 live**。
- 新檔 `p4_proxy/regen_p4runtime_pb2.py`（188 行）：先切到純 Python backend import 舊模組，取出它們內嵌的 `FileDescriptorProto`，組成 FileDescriptorSet，用 `grpc_tools.protoc --descriptor_set_in` 重生。**在寫任何東西之前**，先在另一個直譯器、用**預設** backend 從暫存目錄 import 新模組，要求每個 descriptor 與舊的**逐位元組相同**，不同就拒絕、什麼都不寫。寫完再從安裝位置 import 一次驗收。可以重複跑（第二次會說 already current）；protobuf 3.x 下什麼都不做；p4 套件不在本直譯器 prefix 內就拒絕。
- `.github/workflows/ci.yml`：安裝步驟多一道 `python p4_proxy/regen_p4runtime_pb2.py`，註解說明少了它 L1 的 P4 探針會失敗。
- `tools/test_workflow/stack.sh:1048`、`tools/test_workflow/ndt:1926`、`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:301`：這三處印的「create it:」安裝提示各多接一段 `&& p4_proxy/venv/bin/python p4_proxy/regen_p4runtime_pb2.py`，各改 1 行字串。

**候選的驗證（全部跑過）**：
- 重生工具看過紅（`regen_tool_red_green.p4req-55cebe6c-wt.log`，當時工具在 worktree 未提交；commit 前只再改了 stdout line buffering）：
  0. 安裝後、重生前：預設 backend 下 import，出現 TypeError（紅）
  1. **mutant**（identity 檢查改成跟截掉最後一個 byte 的 descriptor 比）：四個 descriptor 全部 DIFFERS → `refusing ... nothing was replaced`、rc=1，p4 套件指紋 `0434cc2c…` 不變
  2. 真工具：替換 8 個檔，rc=0，指紋變成 `bb1b2363…`
  3. 再跑一次：already current，rc=0，指紋不變
  4. import OK（綠）
- 重生後的 descriptor 與舊的**逐位元組相同**（4 個 proto：5273／6019／824／8825 bytes；`regen_schema_identity.p4req-55cebe6c.log`）。實驗 venv 與候選流程產出的 8 個檔 sha256 完全一樣（決定性）。
- commit 後的工具在 venv-cand 重跑：already current，rc=0（`regen_tool_committed_rerun.p4req-7cc50b42.log`）。
- `check_gate_anchors.py`：`62f76cf5`、`55cebe6c`、`7cc50b42` 三顆都是 116/116 cells ok（`check_gate_anchors.p4req-*.log`）。
- `tests/shell/test_up_ovs_wedge_guard.sh`（唯一 grep stack.sh P4 直譯器訊息區塊的測試；離線；經 guard）@`7cc50b42`：10 checks all passed。

### 4.4 路線 B 為什麼沒選作候選（INFERRED，讀碼判斷，沒實作）

B 要求**每個** import p4runtime 的行程在第一次 import `google.protobuf` 之前就設好 env：stack.sh 起 proxy、ndt 的 app_preflight、live 腳本的 `$PY` convert／preflight、drive_exercise 的 `PROXY_PY`、CI／本機閘門、reference 探針、手冊的手動指令。repo 裡沒有單一咽喉點，漏一處就在那裡 TypeError。好處是 backend 不變，還是 `python`，跟今天主 venv 在 3.13 上一樣，行為差異最小。live 若想同時比 B，方法見 §5.3。

### 4.5 候選要併之前還差什麼（給 orchestrator／Adam 決定）

1. **live 01／06 各一次**（orchestrator 做，方法見 §5）。
2. **backend 會從 `python` 換成 `upb`**（主 venv 在 3.13 上是純 Python，因為 3.20.3 沒有 3.13 的 C 擴充）。離線 1744 個測試逐條相同，但 live 的效能／行為沒量過。**INFERRED**：upb 應該更快，不會更慢，但沒量。
3. **repo 外的使用手冊**（ndtwin.org 與公開 repo 的 README 裡的安裝指令）也要加第三道指令；不加，照手冊裝出來的 proxy 起不來。那不在本 repo，我沒碰。
4. 重生後的 8 個檔跟 p4runtime wheel 的 `RECORD` hash 不符。`pip install --force-reinstall p4runtime` 會把舊碼裝回來，要再跑一次工具（工具 docstring 有寫）。重生碼沒有 proto 註解（descriptor set 不帶 source info），只影響美觀。
5. 多兩個依賴：grpcio-tools 1.71.2（它宣告 `protobuf<6`，以後 protobuf 升 6.x 要一起動）＋setuptools。venv 從 80M 變成 94M。
6. 候選的 `ci.yml` 沒在 GitHub 上跑過（沒 push）。本機用 3.12.3 照同一套流程跑過，結果全綠（venv-cand312）。

---

## 5. 給 orchestrator：live 用升級後 venv 的最小方法（不改任何預設）

### 5.1 指令（⚠️ **UNTESTED**：沒執行過，下面的指令與「換回後自動重啟」都是 §5.2 讀程式碼推論出來的）

```
export P4_PROXY_PY=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/scratch/venv-cand/bin/python
# 然後照常跑 live 01／06（主 checkout 的腳本，不用換 commit）
# 確認真的換過去了（proxy 起來後）：
cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/p4_proxy.cmd          # bash -c 那行應是 venv-cand/bin/python
ps -o args= -p "$(cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/p4_proxy.child.pid)"
# 換回：
unset P4_PROXY_PY      # 下一次 ndt up p4 會因 argv 不同自動重啟 proxy
```

### 5.2 為什麼這樣就夠（**讀過未執行**；我沒跑 live、沒起 proxy）

| 環節 | 依據（讀碼） | 會用哪個直譯器 |
|---|---|---|
| proxy 本身 | `components.env:45` `: "${P4_PROXY_PY:=$KERNEL_DIR/p4_proxy/venv/bin/python}"`，由 `stack.sh:35` source；`stack.sh:1087` `bash -c "cd ... && '$P4_PROXY_PY' proxy_agent/main.py"` | **venv-cand** |
| ndt → stack.sh | `ndt:3284-3286` `bash "$STACK" up p4` 繼承環境（只在前面加 TOPO_P4 等變數） | 環境變數會傳下去 |
| 已在跑的舊 proxy | `stack.sh:532` 拿 argv（含直譯器路徑）比對；不同就 `stop_one` 再重起 | 自動換掉 |
| ndt 的 app pre-flight（06 的 `ndt up p4 --app`） | `ndt:1913` `p4_proxy_py()` 認 `P4_PROXY_PY` | **venv-cand** |
| drive_exercise.py 把環境交給 ndt | `drive_exercise.py:461-465` `ndt_env()`＝`dict(os.environ)`＋NDT_OWNER | 會傳 |
| **不會切換的部分** | `live-p1/_common.sh:29` `PY=$REPO/p4_proxy/venv/bin/python`（01 只用來跑 json 的 `jqp`，不碰 protobuf）；`drive_exercise.py:93` `PROXY_PY` 寫死主 venv，拿來跑 convert.py／preflight.py | 仍是主 venv（protobuf 3.20.3） |

所以 06 裡 drive_exercise 自己呼叫的 convert／preflight 還是跑在 3.20.3 上。proxy 與 ndt 的 pre-flight 則跑在 5.29.6 上。對「proxy 在 5.29.6 下能不能跑」這個問題，這樣就夠了；要全部都換就得改那兩處寫死的路徑，那等於改預設，我沒做。

### 5.3 注意（⚠️ 「可以整個搬走」與「變數對其他行程沒有作用」都是 **UNTESTED**，沒執行過）

- venv-cand 在我的 worktree 裡。**live 跑完之前不要移除這個 worktree。**venv 用 `bin/python` 直接呼叫時可以整個搬走（`pyvenv.cfg` 只記 base 直譯器），但 `bin/pip` 的 shebang 是寫死的。
- 想順便比路線 B：`export P4_PROXY_PY=<wt>/scratch/venv-pb5/bin/python PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python`。這個變數對其他仍用主 venv（3.20.3，本來就是 python backend）的行程沒有作用（INFERRED）。

---

## 6. venv 佔用（`du -sh`，交件時）

| 路徑 | 大小 | 用途 |
|---|---|---|
| `<wt>/scratch/venv-aligned` | 80M | 任務 1，3.13.13 |
| `<wt>/scratch/venv-py312` | 83M | 任務 1 的 3.12 佐證（§3） |
| `<wt>/scratch/venv-pb5` | 81M | 任務 2 路線 A／B |
| `<wt>/scratch/venv-pb5regen` | 94M | 任務 2 路線 C 實驗（已被 venv-cand 取代，可刪） |
| `<wt>/scratch/venv-cand` | 94M | **候選流程，live 用這個** |
| `<wt>/scratch/venv-cand312` | 97M | 候選流程的 3.12 佐證 |
| `<wt>/scratch/regen-work` | 184K | 路線 C 實驗的 descriptor set 與產出 |
| `<wt>/scratch/requirements-pb5.txt` | <4K | 路線 A／B 用的兩行改版 |
| （對照）主 `p4_proxy/venv` | 69M | 沒動 |

合計約 530M；`df -h /` 開工時剩 11G，交件時仍是 11G（90%）。票要求兩個 venv，我多建了四個（py312、pb5regen、cand、cand312）當佐證，都在 gitignored 的 `scratch/` 底下，要清就直接刪目錄。

---

## 7. 閘門／測試清單（每支的最後一行；「跑過」）

| log（`logs/gates-0910/`） | HEAD | 直譯器 | 最後一行 |
|---|---|---|---|
| `p4_proxy_suite_mainvenv.p4req-62f76cf5` | 62f76cf5 | 主 venv | FAILED (failures=4, errors=80, skipped=11)（缺 p4_src/build，見 §1） |
| `p4_proxy_suite_main.p4req-62f76cf5` | 62f76cf5 | 主 venv | Ran 1557 / OK (skipped=1) |
| `p4_exercise_suite{,_notutorials}_main.p4req-62f76cf5` | 62f76cf5 | 主 venv | Ran 187 / OK；OK (skipped=1) |
| `p4_proxy_suite_{main,aligned,py312}.p4req-55cebe6c` | 55cebe6c | 主／aligned／py312 | 三個都 Ran 1557 / OK (skipped=1) |
| `p4_exercise_suite{,_notutorials}_{main,aligned,py312}.p4req-55cebe6c` | 55cebe6c | 同上 | Ran 187 / OK；OK (skipped=1) |
| `*_verdicts_{main,aligned}.p4req-55cebe6c` | 55cebe6c | 主／aligned | 1557＋187 id，diff 0 |
| `check_pins_vs_mainvenv.p4req-62f76cf5` | 62f76cf5 | — | RESULT: RED (6 line(s) do not describe the venv) |
| `check_pins_vs_mainvenv.p4req-55cebe6c` | 55cebe6c | — | RESULT: GREEN (0 line(s) do not describe the venv) |
| `p4_proxy_suite_pb5_upb.p4req-55cebe6c` | 55cebe6c | venv-pb5 | TypeError: Descriptors cannot be created directly.（rc=1，0 tests） |
| `p4_exercise_suite{,_notutorials}_pb5_upb.p4req-55cebe6c` | 55cebe6c | venv-pb5 | FAILED (failures=44, errors=5[, skipped=1]) |
| `*_pb5_pyimpl.p4req-55cebe6c`（suite＋verdicts） | 55cebe6c | venv-pb5＋env | 1557 / OK (skipped=1)；187 / OK；diff 0 |
| `regen_p4runtime_pb2.p4req-55cebe6c`、`regen_schema_identity.p4req-55cebe6c` | 55cebe6c | venv-pb5regen | done；RESULT IDENTICAL-SCHEMA |
| `*_pb5_regen.p4req-55cebe6c`（suite＋verdicts） | 55cebe6c | venv-pb5regen | 1557 / OK (skipped=1)；187 / OK；diff 0 |
| `compare_main_vs_pb5_upb.v2.p4req-55cebe6c` | 55cebe6c | — | p4_proxy_suite RED: no verdicts；rc=1 |
| `regen_tool_red_green.p4req-55cebe6c-wt` | 55cebe6c＋未提交候選 | venv-cand | mutant rc=1 指紋不變 → 真工具 rc=0 → 重跑 already current → import OK |
| `regen_tool_committed_rerun.p4req-7cc50b42` | 7cc50b42 | venv-cand | ok: … imports on the default backend with the shipped schema.（rc=0） |
| `p4_*_suite*_{main,cand,cand312}.p4req-7cc50b42` | 7cc50b42 | 主／cand／cand312 | 全部 1557 / OK (skipped=1)；187 / OK；OK (skipped=1) |
| `*_verdicts_{main,cand}.p4req-7cc50b42` | 7cc50b42 | 主／cand | diff 0 |
| `check_gate_anchors.p4req-{62f76cf5,55cebe6c,7cc50b42}` | 各自 | python3 | 116/116 cells ok (0 not ok, 0 NOT CHECKED) |
| `test_up_ovs_wedge_guard.p4req-7cc50b42` | 7cc50b42 | bash | Ran 10 checks, all passed |

**我自己的工具出過的錯（已修，照實寫）**：
- `compare_verbose.sh` v1：suite 在**載入階段**就死、沒寫出判決檔時，印出 "per-test diff lines: 0" 而且不設 rc。沉默被讀成一致。v2 修好（缺判決檔＝RED），並對同一批既有判決檔重跑一次，看到它轉紅（`compare_main_vs_pb5_upb.v2…`）。v1 原檔保留為 `scripts-p4req/compare_verbose.v1.sh`。v1 只用在 main／aligned 與 main／pb5_pyimpl 的比對，兩邊都有判決檔，那個漏洞沒被觸發，結論不受影響。
- `run_suites.sh` 中途把 freeze 從 `$(dirname PY)/pip` 改成 `python -m pip`，只影響 log 檔頭的 freeze 那段，不影響測試指令。pb5_regen、cand、cand312 以及 main@7cc50b42 用的是新版。v1 原檔沒留，差異就這 2 行。

---

## 8. 沒做／未驗（明列）

- **live 沒跑**（按票，由 orchestrator 跑）。§5.2 是讀碼推論，沒實際執行。
- 票 §1 的 INFERRED「proxy 只解析本機 bmv2 送來的 protobuf、`p4_proxy` 內沒有 `json_format`，實際風險低」我沒有重新驗證。
- 候選的 `ci.yml` 沒在 GitHub 跑過。venv-cand312 只比了數字，沒做逐條 id 比對。
- 沒碰 GitHub alert、沒 push、沒 merge；主 checkout 只讀（p4_src/build 用複製的，主 venv 指紋前後相同）。
- 工具內部的 identity 斷言看過紅（mutant）。「只替換部分檔案後中途失敗」這種半途狀態沒有做注入測試：寫檔是逐檔 `copyfile`，不是原子操作，中途失敗會留下新舊混合；重跑工具可以收斂（INFERRED）。
