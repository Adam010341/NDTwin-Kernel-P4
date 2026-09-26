# P4-PB5-PREP-SUMMARY：protobuf 5 候選的併入前離線準備（pb5prep，2026-09-26）

[Co-developed with claude code -- Adam]

- worker：pb5prep；worktree `scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926`；分支 `fix/p4proxy-protobuf5-0926`，從 trunk `580767a8` 開出。
- **head：`5bb5f1fa8591151faea71217f6df8de81ce22e9d`**（第三輪，judge 複審 d2e4708a 判 READY FOR ADAM'S DECISION 之後的 N1–N8；第二輪交件 `d2e4708a`、第一輪 `6351be15`，見下方 R3、R2 與原 §0–§6）。**沒 push、沒 merge、沒碰 lab、沒切換任何 venv**；主 checkout 的 `p4_proxy/venv` 與 `wt-p4proxy-reqs-0925/scratch/venv-cand` 都沒寫過（前者指紋前後相同，見 §3；後者本輪完全沒用到）。
- 所有 log：`scratch/overnight-2026-09-05/logs/gates-0910/*.pb5prep-<sha8>.log`，第一行 `# HEAD <完整 sha>`，最後一行 `rc=<n>`。腳本、README 與 `SHA256SUMS` 在 `logs/gates-0910/scripts-pb5prep/`。

## R3. 第三輪（judge 複審 d2e4708a：READY FOR ADAM'S DECISION，N1–N8）

新增一個 commit：`5bb5f1fa`，只改 `p4_proxy/requirements.txt`，而且只動遷移程序和檔頭一句話。pin 與 08483aa5 相同。

- **N1（最重要）**
  - 第 1 步的第一條指令會在 guard shell 裡**再 claim 一次**（同一個 owner），所以 90 分鐘從等完 build lock 之後才開始算。
  - `at()` 對**每一條**指令都呼叫 `inwin()`：自己的 claim 必須還剩 ≥30 分鐘，不然印 `STOP at <步驟>: renew the claim … then paste again from this command`，STEP 不變，續 claim 後可以從那條接著貼。
  - 演練：
    - S20：2a 之後把 claim 改成只剩 60 秒，結果 STOP at 2b；pip install 沒跑；續 claim 後從 2b 重貼，VERIFIED、release。
    - S21：2b 之後 claim 被別的 owner 拿走，結果 STOP at 2c；續 claim 被拒；regen 沒跑；舊 venv 仍停放且指紋不變；第 5 步在遷移 shell 裡被拒絕。
- **N4**
  - 文字不再說「每個檢查都注入過失敗」，改成列出實際注入過的：window、claim 過期或被拿走、步驟 1–3 的每個檢查、rb1–rb3、ip1–ip4、失敗後重貼 1–3。沒注入失敗的是第 4、5 步和 ip5（只跑過）。
  - 新演練：
    - S22：有行程在跑新 venv 時，STOP at rb2；停掉它再貼 ROLLBACK，還原成功。
    - S23：搬完後才被改動，ERROR at rb3，並提示續 claim 當 handoff。
    - S24：ip1（site-packages 唯讀）、ip2 和 ip3（index 不通）、ip4（protobuf 被換回 5）各失敗一次，每次照 STOP 的指示打 `STEP=ipN` 接著貼，最後 rolled back in place。
  - ROLLBACK IN PLACE：`$PARK` 有停放的 venv 就拒絕（該用 ROLLBACK）；最後多一條 ip5 跑兩套 suite，兩套都要 OK；gate 改名為 ip0。
- **N5**
  - 重新寫明：貼的時候要去掉開頭的 `#   $ `。
  - ROLLBACK 會先 `OLD=${OLD%/}`，去掉結尾斜線。
  - 第 0 步：`LOCK`／`TIMEOUT` 有設就印 WARNING。
  - 第 5 步被拒絕時，訊息說明：若這其實是第 0 步的 shell（貼錯了），打 `unset STEP` 再貼一次。
- **N6**：ERROR at rb1／rb3 時要「用同一個 owner 續 claim，把狀況寫進 claim note 當 handoff，通知其他人，再詢問」。
- **N2／N3／N8（文字）**
  - `users()` 看不到的列出來：root 的行程、只靠 PYTHONPATH／VIRTUAL_ENV 用到 venv 的純 Python 行程、含 `..` 或經 symlink 的相對路徑。
  - 在髒的 checkout 跑，1f 的 STOP 是 checkout 的問題，不是 venv 的。
  - 遷移後才回滾：要把檔頭那兩句放回去，或 revert 那次 merge。
- **N7**：本報告與程序文字都寫明演練和真實操作的差異：HOME 指向 scratch、經 pipe 而不是終端機、`ndt` 是 stub、替身 venv 版本相同但檔案不同。
- **演練結果：25／25 GREEN @5bb5f1fa**（`fi_<情境>.pb5prep-5bb5f1fa.log`、`fi_summary-*.pb5prep-5bb5f1fa.log`）。因為 `at()` 的行為改了，S01–S19 全部重跑，不只跑受影響的幾個。S02 另外確認：貼錯 shell 時不會拿 claim。
- 最終閘門：`final_gates_r3.pb5prep-5bb5f1fa.log`。主 venv 指紋：`mainvenv_fingerprint_after-round3.pb5prep-5bb5f1fa.log`。

## R2. 第二輪（judge `judge-PB5PREP-6351be15.md` 之後，2026-09-26 17–18 時 CST）

新增 3 個 commit（`git log 6351be15..d2e4708a`）：
- `94a1ccb9`：B1–B3，以及 notes 1–3、5、7、11。
- `dc2dc80a`：`suites()` 用完的空 HOME 會刪掉。
- `d2e4708a`：失敗注入找到的缺陷，已修（見 R2.2）。

protobuf 5 本體沒動：pin 從 08483aa5 起逐行相同，regen 工具與 7cc50b42 逐位元組相同（`git_evidence.pb5prep-94a1ccb9.log`）。

### R2.1 各項改了什麼（全部在 `p4_proxy/requirements.txt`，另有 ci.yml 與 l1 各一處）

- **B1**
  - 第 1 步把絕對路徑的 V 印出來，並存成 `"$OLD.origin"`。
  - ROLLBACK 從 `.origin` 讀 V，並且：
    - 要求 V 是 `/…/p4_proxy/venv`，而且 `test ! -L "$V"`；
    - 要求在「該 checkout」上持有 window（`inwin` 讀 `$R/.test_run/lab.claim`，R 由 V 推回）；
    - 搬動之前先比對停放 venv 的指紋（rb1，這一條是 R2.2 新增的），不符就印 `ERROR at rb1 … Nothing was moved` 並停下；
    - 搬完之後再比一次（rb3），不符就印 `ERROR at rb3`。
- **B2**
  - 停放前的檢查：
    - 從 venv 自己的 python 讀 protobuf 版本，只接受 3.x（1b）；
    - `$PARK` 裡已經有 `p4_proxy-venv.protobuf*/` 就拒絕，而且必須和 V 在同一個檔案系統（1c）；
    - pyvenv.cfg 的 home python 必須和 venv 同一個 minor 版本（1d）；
    - `users()` 掃 `/proc/*/maps`，也看 cmdline（絕對路徑，或相對於該行程 cwd 的路徑），有人在用就拒絕（1e），搬之前再掃一次。
  - 停放前先在舊 venv 上跑兩套 suite 當基準（1f）。
  - 每條指令都經過 `at()`：只有前一條指令把 STEP 設成它預期的值才會執行；第一個失敗印 `STOP at <步驟>` 和下一步該貼什麼，後面的指令全部印 `(skipped …)`。**第 3 步也照這個規則**。
  - 第 3 步沒過時：可以貼 ROLLBACK，或修好後打 `STEP=2` 再貼一次第 3 步；不會自動回滾。
  - 停放名稱是 `protobuf<讀到的版本>-<時間戳>`。
- **B3**
  - 第 0 步是指令：
    - `export NDT_OWNER=p4-venv-migration NDT_MEASURING='p4_proxy venv migration: no runs, no gates'`；
    - `ndt claim 90 …` 成功後，接 `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh bash -i`。
  - `inwin()` 要求目前在持有 build lock 的那個 shell 裡（看 `NDTWIN_GUARD_HELD`），而且 NDT_OWNER 的 claim 還沒過期。這兩個條件都滿足，每一步才會執行。
  - 文字要求先通知其他 session。第 5 步只能在外層 shell `ndt release`；在遷移 shell 裡打會被拒絕。
- **note 7**
  - HELPERS 先 `unset PYTHONPATH PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION`，並 `export PYTHONDONTWRITEBYTECODE=1`（跑舊 venv 的基準不會寫 .pyc）。
  - 其餘四項已併入 B2：舊 venv 基準、停放名不寫死、檢查 home 的 minor 版本、失敗不自動回滾。
- **notes 1–3**：run history 改成三組：
  - A：候選那組，09-25 離線；
  - B：A 組，09-26 live；
  - C：這個檔案 09-26 解出的組合，只跑過離線。
  - "that exact set" 只用在 C。
  - live 未涵蓋清單補上兩項：5.29.6 下 switch 拒絕 entry 的路徑；ndt app pre-flight 在 5.29.6 下跑（是推論，沒觀察到）。
  - 沒 pin 的套件：C 組實數 15 個。
- **note 5**：檔頭和 ci.yml 都改寫驗收條件。CI 本來就紅（run 36220555111 @580767a8：L1 FAILED，14 組，依 `ci-compare-580767a8.txt`），所以驗收改成：P4 lane 逐檔和那次 run 對照，沒有新紅；Install 步驟單獨看。
- **note 11**：
  - 22 個紅改寫成「21 個 import 時死掉＋1 個是它起的 proxy 子行程死掉」（檔頭、ci.yml）。
  - l1 的 "will skip themselves" 提示加上「或是 import 時就 FAIL」這種情況（`l1_unit_tests.sh`：1 行訊息加一段註解）。CI 形狀的 lane 重跑時看到了新訊息。
- **note 9**：主 venv 指紋在 phase 7／8 之後（@6351be15）與 R2 之後（@d2e4708a）都是 `33b3465d…`，比 marker 新的檔案 0 個（`mainvenv_fingerprint_after-phase7-8.pb5prep-6351be15.log`、`mainvenv_fingerprint_after-review-fixes.pb5prep-d2e4708a.log`）。
- **note 10**：`git_evidence.pb5prep-94a1ccb9.log` 存了 log、`diff --stat`、`git diff 7cc50b42 HEAD -- p4_proxy/regen_p4runtime_pb2.py`（0 行）、兩邊 sha256 都是 `66fb47b0…`。

### R2.2 失敗注入演練（`scripts-pb5prep/fi_rehearsal.py`；log `fi_<情境>.pb5prep-d2e4708a.log`、`fi_summary-175840.pb5prep-d2e4708a.log`）

做法：
- 每個情境都用一份一次性的 repo 副本：`git archive HEAD p4_proxy tools tests setting`，加上 p4 build 檔，`ndt` 換成 stub（只做 claim／release，欄位與真的相同）。
- 替身 venv 用主 venv 自己的 `pip freeze --all` 加 `--no-deps` 全新建立，**不用 `cp -a`**。freeze 和主 venv 逐行相同，`pip check` 的缺陷（googleapis 1.75.0 對 3.20.3）也重現了。建它時從 PyPI 下載了 11 個舊版的 transitive 套件，快取裡沒有。
- `$HOME` 指向 scratch。
- 程序的指令**逐字**取自 HEAD，整段經 pipe 貼進 `bash -i`。bash 讀 pipe 是一個位元組一個位元組讀的，所以 guard 開出來的那個 shell 會吃到後面的行，`exit` 之後的行回到外層 shell，和真的貼上一樣。
- 非程序的行都有標記：`[inject]` 是注入的失敗，`[type]` 是操作者會打的東西。
- 只有 S01 持有**真的** `/tmp/ndtwin-build.lock`；其他情境用私有的 LOCK。**沒有對真的 lab 跑過任何 `ndt`**。

**20／20 GREEN @d2e4708a**：

| 情境 | 注入 | 結果 |
|---|---|---|
| S01 | 無，整段流程 | 真 lock；parked、VERIFIED、外層 release；舊 venv 停放後指紋不變 |
| S01（接續） | 從 `$HOME` 開的新 shell 回滾 | STOP at rb1，沒搬任何東西 |
| S01（接續） | 從另一個 checkout 回滾（它有自己的 claim 和 guard shell） | 拒絕；沒有把 venv 搬進那個 checkout |
| S01（接續） | 正確做法：在 checkout 做第 0 步，再 `cd $HOME` 回滾 | restored unchanged；指紋等於最初；新 venv 改名成 failed-* |
| S02 | 不在 window 裡（「貼進第一個 shell」這種錯） | STOP，其餘全部 skipped |
| S03 | 別人已持有 claim | 沒開 guard shell，STOP |
| S04 | V 已經是 protobuf 5 | STOP at 1b |
| S05 | V 是 symlink | STOP at 1b |
| S06 | `$PARK` 已有停放的 venv | STOP at 1c |
| S07 | `$PARK` 在 tmpfs | STOP at 1c |
| S08 | home 的 python 是 3.12，venv 是 3.13 | STOP at 1d |
| S09 | 行程 map 了 venv 的 .so | STOP at 1e |
| S09b | 行程用相對路徑跑 venv 的 python | STOP at 1e |
| S10 | 舊 venv 上 suite 失敗 | STOP at 1f，沒搬任何東西 |
| S11 | `$OLD` 已被佔 | STOP at 1g「nothing moved」；照樣貼 ROLLBACK 也在 rb1 ERROR，沒搬任何東西 |
| S12 | V 在停放後又出現 | STOP at 2a；ROLLBACK 還原 |
| S13 | 2b pip 失敗後，原樣重貼 1–3 | 重貼時 STOP at 1b，不會再停放一次；ROLLBACK 還原 |
| S14 | regen 失敗 | STOP at 2c；ROLLBACK 還原 |
| S15 | pip check 失敗（3a） | 修好、`STEP=2`、再貼第 3 步 → VERIFIED |
| S16 | backend 被設成 python | STOP at 3b；ROLLBACK 還原 |
| S17 | 新 venv 少了 hypothesis | STOP at 3c；ROLLBACK 還原 |
| S18 | 停放期間舊 venv 被改動 | ERROR at rb1，什麼都沒搬 |
| S19 | ROLLBACK IN PLACE，起點是剛由三道指令建好的新 venv | 回到 3.20.3；freeze 和主 venv 不同（googleapis 1.73.0 vs 1.75.0、transitive 較新、多了 setuptools），pip check 乾淨；檔內已寫明 |

**找到並修掉的缺陷**（@dc2dc80a 的 S11 是 RED，修正在 `d2e4708a`）：
- 1g 用 `[ -d "$OLD" ]` 判斷「搬了沒有」。`$OLD` 被佔時，它會謊報「V WAS moved — paste ROLLBACK」。照做的話，真的舊 venv 會被改名成 failed-*，佔位的東西反而被放回 V。
- 修法：1g 改成看 V 還在不在；ROLLBACK 在搬任何東西之前先比對停放 venv 的指紋（rb1）。

演練記錄：
- 另外兩輪留作紀錄：`*.trial1/trial2.pb5prep-94a1ccb9.log`。那兩輪紅是 harness 的錯：副本少了 `setting/`；檢查字串會命中 bash 自己 echo 出來的指令行，後來改成只比對行首。
- S09 注入的 sleeper 在 harness 被中止時留了下來，我已經用 pid 確認身分後 kill。

### R2.3 最終閘門 @d2e4708a（`final_gates_r2.pb5prep-d2e4708a.log`，rc=1 的原因見下）

- pin 與 08483aa5 相同。
- gate anchors 119/119。
- `test_up_ovs_wedge_guard.sh` 10/10。
- fi 20／20 GREEN。
- 新增 401 行：0 個 key、0 個 IP；只有 1 行含 `/home/`，是 trunk 原句重新折行。
- **`test_l1_shell_scoring.sh` 95 個 check 紅 12 個**，讓整份 log 的 rc=1。這 12 行 FAILED 和 trunk 580767a8 上（phase 7 A/B）**完全相同**（`l1_shell_scoring_vs_trunk.pb5prep-d2e4708a.log`，rc=0），**不是本分支造成的**。
- phase 1 @d2e4708a：
  - CI 形狀的 lane：regen 前 22 紅，regen 後 0 紅；
  - 新的提示訊息出現了；
  - prefix 拒絕 rc=2。

### R2.4 仍然只有 Adam 能決定

- 併不併、怎麼併：judge 給了兩條路。(a) 另建這一組的 venv 再跑一次 live；(b) 改寫主旨，拿遷移後的 live 01／06 當驗收。
- 何時遷移：要在 window 裡做（claim、build lock、和 HB spike 協調）。
- 推分支讓 CI 跑，就等於公開這套流程。
- repo 外的手冊要同步更新。
- dependabot。
- process_is_the_emitter 那張 chip。
- fixture 和 `~/tutorials` 哪一邊才對（judge note 14）。

## 0. 結論

1. 候選已帶到目前的 trunk 上（cherry-pick `7cc50b42` 加 `-x`，保留原作者與原訊息），唯一衝突在 `requirements.txt`：保留 `851cefd7` 的 `starlette==1.3.1` 與它改寫的句子，其餘用候選的。regen 工具與候選逐位元組相同。
2. CANDIDATE／NOT merged／NOT yet run live 的字樣已改寫成事後敘述：引用 09-26 live 試跑（日期、trunk `580767a8`、涵蓋與未涵蓋的範圍、證明的是「一整組」而不是 protobuf 單變數），並寫明**這個檔案現在解出的那一組（starlette 1.3.1）只跑過離線，沒跑過 live**。
3. 遷移與回滾程序寫在 `p4_proxy/requirements.txt` 檔尾的 **"UPGRADING AN EXISTING VENV, AND ROLLING BACK"** 段（檔頭第三段指向它）。這個選擇沿用既有慣例：`components.env:44` 說 venv 是 "created by requirements.txt"，而檔頭本來就放了 thrift CLI 的操作食譜。程序**逐字跑過**（OBSERVED）：在 worktree scratch 裡用 trunk 的檔案建一個替身舊 venv，把程序的 `$` 指令原文抽出來執行，只改了 `V` 和 `PARK` 兩個變數。兩條回滾路徑也都跑過，結果 GREEN。
4. 離線驗證（OBSERVED，全部在 `08483aa5`；之後到 head 只多了註解行）：
   - 新建的 3.13.13 與 3.12.3 venv 對主 venv（3.20.3）逐 test id 比對，三套 suite 的 diff 都是 0 行。
   - l1 的 P4 lane 以 CI 形狀在本機跑：少了第三道指令時 41 個檔紅 22 個，加上之後 0 個。
   - l1 的 Python lanes（C++ 段落切掉）：trunk 與本分支失敗的是同一組，本分支沒有新增任何紅。
5. 過程中找到並修掉 6 個問題（§2）。其中 **ci.yml 原本的宣稱是錯的**：它說少了 regen 時「every P4 test file skips」，實測是 22 個檔在 import 時 FAIL。
6. 只有 Adam 能決定的事列在 §5：併不併、共用 venv 何時遷移、要不要推分支讓 GitHub CI 跑、repo 外的手冊、dependabot。

## 1. Commits（`git log 580767a8..6351be15`，6 檔，+376／−42）

| sha | 內容 |
|---|---|
| `b5f14624` | cherry-pick `7cc50b42`（`-x`）。訊息保留原文，另附衝突說明：starlette pin 來自 `851cefd7`，所以這個檔案解出的組合已經**不是** venv-cand 那一組（venv-cand 是 starlette 1.7.0）。**主旨仍是 "CANDIDATE, not for merge without a live run…"**，見 §5-2 |
| `98e9f873` | requirements.txt 檔頭改寫成事後敘述（live 範圍、未涵蓋項目、「一組不是單變數」、starlette 差異）；檔尾加遷移與回滾程序；ci.yml 註解拿掉分支名；`.gitignore` 加 `p4_proxy/venv.*`（下一個 commit 撤掉） |
| `ac8f0f3f` | 程序修兩個缺陷（§2-1、§2-2）：舊 venv 改停在 checkout 外面（`PARK=$HOME`，並檢查和 checkout 在同一個檔案系統）；每個指令先確認前一步真的完成了；`mv -T`；OLD 名稱帶時間戳。撤掉 `.gitignore` 那條規則 |
| `958bec1c` | 回滾段有一行折行後以 `# 1.` 開頭，會被讀成第 1 步（§2-3） |
| `8f10b203` | 程序第 3 步：p4_proxy 測試改用模組名；p4_exercise 跑在空 HOME 下（§2-4、§2-5） |
| `08483aa5` | ci.yml：把「少了 regen 會怎樣」改成實測結果：22／41 FAIL，不是 skip；並寫明「Not yet run on GitHub」（§2-6） |
| `bc1860c8` | requirements.txt 記錄本輪對這組的離線結果（只有註解） |
| `6351be15` | 措辭：CI 形狀的 lane 是在本機跑的，不是在 GitHub 上（只有註解） |

改到的檔案：`p4_proxy/requirements.txt`、`p4_proxy/regen_p4runtime_pb2.py`（新檔，等於候選）、`.github/workflows/ci.yml`、`tools/test_workflow/stack.sh`、`tools/test_workflow/ndt`、`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh`。後三者只有候選那 3 行安裝提示字串（三道指令）。`.gitignore` 最後和 trunk 相同。

## 2. 找到的問題（全部 OBSERVED；除第 1 項外都是實際跑出來的）

1. **舊 venv 停在 `p4_proxy/venv.<x>` 會被測試讀到**（讀碼得到，沒實跑）。`tests/python/test_known_issues_references.py` 的 SCAN_DIRS 含 `p4_proxy`，而 SKIP_DIR_NAMES 只跳過名稱正好是 `venv` 的目錄。舊 venv 按程序要保留到 live 通過才刪，這段期間主 checkout 的 l1 會把整個 site-packages 讀一遍。解法：改停到 `$HOME`。
2. **整段貼上時，前一步失敗後面照樣執行**（讀碼推演，沒實跑）。第 1 步重跑時，會用新 venv 的指紋蓋掉舊的，還會把新 venv `mv` 進已停好的舊 venv 裡面。舊 venv 還沒移走時跑第 2 步，會在它上面建 venv 再 pip install，也就是本來要避免的就地升級。現在每一步都用 `test -d "$OLD"` 或一條 `&&` 串起來擋住，而且 `mv -T` 不會移進既有目錄。
3. **折行造成的假步驟標題**：rehearsal 產生器的形狀斷言看過紅，把回滾的兩條指令算進了第 1 步（抽出結果是 `{'1': 5, …}`，沒有 `rollback`）。修正後轉綠。
4. **`python -m unittest tests/test_*.py` 會讓 `test_switch_state` 紅**（rehearsal @958bec1c，RED）。argv 裡帶著 `tests/test_psample_sflow_emitter.py`，而 `link_telemetry.process_is_the_emitter()` 是對整條 cmdline 做子字串比對，於是把測試行程自己判成 emitter。改用模組名（REQ／p4r 輪次也是這樣跑）就綠了。這是 production 程式的判斷寫太寬：teardown 以 root 身分依這個判斷送 SIGTERM／SIGKILL。已經開一張 out-of-scope 票（chip：「Tighten process_is_the_emitter's cmdline match」），**本分支沒改 production 碼**。
5. **`test_convert.FixtureProvenance` 在真 HOME 下紅**，三個 venv 都一樣（主 venv 也紅）。原因是 09-26 live 06 重建了 `~/tutorials/exercises/{basic,p4runtime}/build`（mtime 14:22–14:24 CST）。它檢查的是檔案、不是 venv，所以程序第 3 步改在空 HOME 下跑（等同 REQ 的第三套）。**有一件事要注意：`tools/p4_exercise` 的 fixture 和 `~/tutorials` 現在已經不一致**，這件事與本分支無關。
6. **ci.yml 原本的宣稱不成立**。CI 形狀的 3.12.3 lane（沒有 `p4_proxy/venv`、沒有 p4dev、`python3`＝本輪建的 venv）：少了 regen 時，探針找不到可用的直譯器，退回同一支 python3，結果 22 個檔在 import 時 FAIL（`Descriptors cannot be created directly`），不是 skip。加上 regen 後 0 個 FAIL，只有 `test_p4_client.py` 照宣告 SKIPPED。

## 3. 驗證了什麼（跑過；log 在 `logs/gates-0910/`，sha 看檔名）

| 項目 | 結果 | log |
|---|---|---|
| 3.12.3 venv，用安裝的三道指令建（pip 0 Downloading／54 Using cached） | 前兩道之後探針 rc=1（TypeError）；regen 後探針 rc=0、`5.29.6 upb`、重跑顯示 already current、`pip check` 乾淨；grpcio-tools 宣告 `protobuf <6.0dev,>=5.26.1`；重生的 8 檔 sha256 和 venv-cand 相同 | `venv_create_py312`、`venv_regen_py312` @08483aa5 |
| CI 形狀 P4 lane，regen 前／後 | FAILURES=22 rc=1 ／ FAILURES=0 rc=0 | `l1_python_lanes_ci_py312_{preregen,postregen}` @08483aa5（@958bec1c 同樣結果） |
| regen 工具：prefix 拒絕路徑（judge #12） | `/usr/bin/python3.12` 加 `PYTHONPATH`＝venv site-packages：rc=2，p4 套件指紋不變 | `regen_refusal_prefix_py312` |
| **程序第 1–3 步逐字執行**（3.13.13 替身，由 trunk 的檔案建成 3.20.3） | 12 條指令全部 rc=0；`parked:`；regen 前探針紅、後探針綠；`pip check` 乾淨；`5.29.6 upb`；already current；兩套都 `OK (skipped=1)`（1557／187） | `rehearsal_r0_standin_old_venv`、`rehearsal_forward` @08483aa5 GREEN（@958bec1c RED，見 §2-4、§2-5） |
| 三套 suite × 三個 venv | p4_proxy 三個都 1557 OK (skipped=1)；p4_exercise 空 HOME 三個都 187 OK (skipped=1)；真 HOME 三個都 FAIL 同一個 fixture 測試 | `p4_proxy_suite_{new313,new312,main}`、`p4_exercise_suite{,_emptyhome}_{…}` |
| 逐 test id 比對：new313 對 main、new312 對 main | 6 份比對**全部 0 行**（含真 HOME 那套：同一個測試在三個 venv 上判決相同） | `*_verdictdiff_{new313,new312}_vs_main` |
| l1 Python lanes（C++ 切掉；0／0b／3／3b） | new313：17 組紅；main：18 組；**trunk 580767a8（main venv）：17 組，和 new313 同一組**；new312（沒跑 3b）：0。多出的那一組 `test_apps_residue.sh` 在 HEAD 重跑 3 次 0 紅，而且它不用 proxy venv，是時序抖動 | `l1_python_lanes_{new313_with3b,main_with3b,new312}` @08483aa5、`l1_python_lanes_trunkAB-main_with3b` @580767a8、`apps_residue_repeat` |
| **回滾（ROLLBACK）逐字執行** | `old venv restored unchanged`（內容指紋相等）；回來的是 `3.20.3 python`；pip 從原路徑執行 | `rehearsal_rollback` GREEN |
| 就地升級與修復（檔頭括號裡那句話） | 在舊 venv 上 `pip install -r`，探針 TypeError；regen 後 `5.29.6 upb` | 同上 |
| **就地回滾（ROLLBACK IN PLACE）逐字執行** | 4 條指令 rc=0，結果 `3.20.3 python`；拿掉 grpcio-tools 後 regen rc=2（拒絕路徑）；3.x 下 regen「nothing to regenerate」rc=0；`pip check` 乾淨；freeze 與舊 venv 只差 `setuptools==84.0.0`（文中已寫明） | 同上 |
| import 覆蓋（REQ 工具，未改） | HEAD 的檔案 GREEN；拿掉 grpcio-tools 那一行後 RED（MISSING grpcio-tools） | `check_imports_file-HEAD` |
| pin 對 venv | 對 new313 GREEN；對主 venv RED，只差 protobuf 與 grpcio-tools（＝檔頭「開發機 venv 仍是舊組」） | `check_pins_file-HEAD` |
| thrift CLI 食譜，只測 import | new313 與 main 的 5 個模組都 import 成功，且都沒有載入 `google.protobuf` | `thrift_cli_recipe_imports` |
| 最終 head：程序指令和演練時的比對、閘門 | 18 行指令與 08483aa5 相同；08483aa5 之後改的都是註解；gate anchors 119/119；`test_up_ovs_wedge_guard.sh` 10 checks all passed；新增行掃描：0 個 key／token 樣式、0 個 IP；只有 1 行含 `/home/adam`，是 trunk 原有句子重新折行 | `final_gates` @bc1860c8（@6351be15 見 §6） |
| 主 venv 唯讀 | 前後指紋都是 `33b3465d…`（等於 live 試跑時的值），比 marker 新的檔案 0 個；全程 `PYTHONDONTWRITEBYTECODE=1` | `mainvenv_fingerprint_{before-all,after-all}` @08483aa5 |
| `.gitignore` red/green（後來撤掉） | v1 的預期寫錯了：`bin/python` 本來就被通用的 `bin/` 規則擋住，log 照實留著；v2 改用別條規則都擋不到的路徑，trunk 0/5、當時的 HEAD 5/5 | `gitignore_venv_parking_redgreen{,_v2}` @98e9f873 |

**沒做到或做不到的：**
- **GitHub CI 沒跑**（不能 push）。CI 形狀是本機模擬：用 venv 代替 setup-python 的非 venv 直譯器，並用 `l1_derive.py --ci` 把 p4dev 那條 fallback 路徑換成不存在的路徑。
- **l1 的 C++ 段落沒跑**（規定不准 build C++）。我跑的是 `l1_derive.py` 產出的副本：保留 0／0b／3／3b 的原文，切掉 build、ctest、direct execution 與 section 4。
- 3b 在本機有 17 組紅，trunk 上也一樣（環境與既有狀態造成）。其中兩類是**帶 `P4_PROXY_PY` 跑 l1 本身就會紅**：`test_ndt_app_package.sh` §9 讀 components.env 時沒有 unset 這個變數；`test_live_p1_common.sh` 需要 worktree 自己的 `p4_proxy/venv`。另外 `test_build_guard.sh` 在 guard 裡面跑會看到 shim。**這些我都沒修**，也不屬於本票範圍。
- 這一組（starlette 1.3.1）**沒跑 live**。
- 真正的切換、真正 venv 上的回滾：**按票沒做**。
- 3.12 是 `/usr/bin/python3.12`（本機既有的）；3.13 是 miniconda 3.13.13。pip 套件全部從快取取得（0 Downloading），沒有下載直譯器。

## 4. 遷移程序重點（原文在 `p4_proxy/requirements.txt` 檔尾）

- **為什麼不能就地 `pip install -r`**：protobuf 會升上去，但 p4runtime 已經是 1.5.0、不會重裝，舊的生成碼留在原處，proxy import 時 TypeError；而且這樣就沒有可以回去的舊 venv。那個 TypeError 自己印的建議（降回 protobuf 或設 `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION`）不要照做；真的碰上了，跑一次 regen 工具就能修好，演練裡看過。
- **為什麼在原位置替換，而不是改 `P4_PROXY_PY`**：`components.env:45` 與 `ndt` 的 `p4_proxy_py()` 預設都指向 `p4_proxy/venv/bin/python`；drive_exercise、`live-p1/_common.sh` 和大多數 `tests/shell/mutate_*.sh` 都用路徑直接呼叫，其中幾支寫死的是主 checkout 的 venv。`P4_PROXY_PY` 只影響得到 stack.sh、ndt、l1，這正是 09-26 試跑裡 drive_exercise 的 convert／preflight 仍停在 3.20.3 的原因。所以文中把它寫成「試用」的方法，不是「切換」的方法。
- **步驟**：
  - 0：確認沒人在用：`ndt status`、`ps -eo pid,args | grep -F p4_proxy/venv/`，並且沒有閘門在跑，包括其他 checkout 的。
  - 1：freeze 加內容指紋，再用 `mv -T` 把舊 venv 移到 `$HOME/p4_proxy-venv.protobuf3-<時間戳>`（先確認同一個檔案系統）。
  - 2：用舊 venv `pyvenv.cfg` 記的 base python3 在原位置建新 venv，接著跑三道指令。
  - 3：驗證：`pip check`、`5.29.6 upb`、regen 顯示 already current、兩套 suite。
  - 4：舊 venv 留到新 venv 過了 live 01／06 再刪（唯一不可逆的一步）；遷移完成後，刪掉檔頭那兩句「開發機仍是舊組」。
- **回滾**：新 venv 先移去 `$PARK`，再把舊 venv 移回原位，比對指紋。舊 venv 已經不在時，照「ROLLBACK IN PLACE」做：拿掉 grpcio-tools、降回 3.20.3／1.73.0、force-reinstall p4runtime。

## 5. 只有 Adam 能決定的

1. **要不要併**，以及併的方式。
2. `b5f14624` 的主旨仍是原來的 "CANDIDATE, not for merge without a live run…"。我照「保留作者與原訊息」原樣保留，另加 `-x` 和衝突說明。併的時候要不要 reword 或 squash，由 Adam 決定。
3. **共用 venv 何時遷移**：照檔尾程序做，要挑沒有 live、沒有閘門在跑的時段，大約 1–2 分鐘加兩套 suite 約 20 秒；新 venv 約 95 MB，另外保留舊的 69 MB。遷移完成要多一個 commit，刪掉檔頭那兩句。遷移之前一旦併了，檔案就不描述主 venv（`check_pins` 對主 venv 會紅在 protobuf 和 grpcio-tools）。
4. **推分支讓 GitHub CI 跑一次**：p4／lab 都是公開遠端，推上去就是公開這套安裝流程。現在的措辭已經是事後敘述，沒有候選字樣，只剩 commit 主旨那一處。
5. **repo 外的使用手冊**（ndtwin.org 等）要加第三道指令，否則照手冊裝出來的 proxy 起不來。
6. **dependabot 的兩個 high**（CVE-2025-4565、CVE-2026-0994）：在公開 repo 的預設分支併入並被重新掃描之前，不會自動關閉（這點是推論）。
7. **out-of-scope 票**：`process_is_the_emitter` 用子字串比對 cmdline，teardown 以 root 身分依它 SIGTERM／SIGKILL，可能誤判到別的行程。chip 已開。
8. 小事，沒改：
   - judge #13 提到的 `doc/audit/.../guest_section6_p2.sh`、`s6_2to6_setup.sh` 是歷史紀錄，我沒改。
   - `doc/2026-07-27_p4_bmv2_support_plan.md:564` 寫「protobuf 釘 3.20.3」，併入後就過時了。
   - `ndt:2053` 寫 "components.env:57"，實際在 `:45`。

## 6. 最後的閘門與收尾

- `final_gates.pb5prep-6351be15.log`（最終 head，rc=0）：
  - 18 條程序指令與演練時（08483aa5）逐字相同，之後的改動 0 行非註解；
  - gate anchors 119/119；`test_up_ovs_wedge_guard.sh` 10 checks all passed；
  - 新增 349 行：0 個 key／token 樣式、0 個 IP；只有 1 行含 `/home/adam`，是 trunk 原句重新折行。
- scratch 佔用：`wt-pb5-merge-prep-0926/scratch/pb5prep/` 共 651 MB。`df -h /` 剩 7.3 GB（93%）。
  - 被取代、可以刪的：`park/`、`rehearsal/`（958bec1c 那次 RED 的演練）、`venv312/`（98e9f873）、`venv312-958bec1c/`。
  - 其餘是 08483aa5 的證據：`rehearsal-08483aa5/`（回滾後停在 3.20.3）、`park-08483aa5/`（失敗的新 venv 停放處）、`venv312-08483aa5/`。
- `p4_proxy/p4_src/build/` 的兩個檔是從主 checkout `cp -p` 過來的（sha256 `0b19d789…`／`d54ff552…`，與 REQ 相同；gitignored）。
- 沒有留下任何背景行程：所有 monitor 都已結束；phase7 把 worktree detach 到 trunk 後，已確認切回 `fix/p4proxy-protobuf5-0926`。
