# P4-PB5-PREP-SUMMARY：protobuf 5 候選的併入前離線準備（pb5prep，2026-09-26）

[Co-developed with claude code -- Adam]

- worker：pb5prep；worktree `scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926`；分支 `fix/p4proxy-protobuf5-0926`，從 trunk `580767a8` 開出。
- **head：`6351be151e452ee83c4f9de58c22cebe7348f7ec`**。**沒 push、沒 merge、沒碰 lab、沒切換任何 venv**；主 checkout 的 `p4_proxy/venv` 與 `wt-p4proxy-reqs-0925/scratch/venv-cand` 都沒寫過（前者指紋前後相同，見 §3；後者本輪完全沒用到）。
- 所有 log：`scratch/overnight-2026-09-05/logs/gates-0910/*.pb5prep-<sha8>.log`，第一行 `# HEAD <完整 sha>`，最後一行 `rc=<n>`。腳本、README 與 `SHA256SUMS` 在 `logs/gates-0910/scripts-pb5prep/`。

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
