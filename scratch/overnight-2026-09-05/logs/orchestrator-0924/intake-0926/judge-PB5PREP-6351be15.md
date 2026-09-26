# 審查：`fix/p4proxy-protobuf5-0926` @ `6351be15`（併入準備，尚未併入）

（opus-judge 最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，此處保留裁決、blocking 與要點。）

## 裁決：READY AFTER FIXES
要修的只有 `p4_proxy/requirements.txt` 檔尾 "UPGRADING AN EXISTING VENV, AND ROLLING BACK" 這一段（B1–B3），修完再做一次含失敗注入的重演。protobuf 5 本體（pin、regen 工具、ci.yml、3 處提示字串、檔頭措辭）沒有需要擋的問題。擋的理由：回滾這張安全網本身有兩種自然操作會放回錯的 venv 或把舊 venv 搬進別的 checkout，而指紋檢查照樣印 "old venv restored unchanged"；「整段貼上時前一步失敗後面不亂動」從未注入失敗驗過。

- **B1** 回滾在新 shell 用相對路徑 `V=p4_proxy/venv`（:188、:221-225）：新 shell 的 cwd 若是另一個 worktree 根目錄 ⇒ 舊 venv 被搬進那個 worktree、主 checkout 仍是失敗的新 venv。修：V 絕對路徑、存成 `"$OLD.origin"`、`test ! -L "$V"`、指紋不符明確報錯。
- **B2** 失敗後重貼第 1 步 ⇒ 半成品新 venv 被 freeze、取指紋、停放成 `protobuf3-<新時間戳>`；回滾放回半成品且指紋通過。「每條指令先檢查前一步」對第 3 步字面不成立；guard 從沒被看到擋下任何東西。修：停放前確認 V 是 protobuf 主版本 3、`$PARK` 已有 `p4_proxy-venv.protobuf3-*` 就拒絕、做失敗注入重演。
- **B3** 「When」只是文字：沒 claim lab、沒持有建置鎖。遷移窗口會踩到 `mutate_table_entry.sh:70-79`（經 `git worktree list` 找主 venv，探針在半成品上會過 ⇒ 別人的閘門假紅）、`test_ndtwin_lab_heartbeat.sh:48` 寫死主 venv、`l1_unit_tests.sh:311` 靜默改用 `/home/adam/p4dev-python-venv/bin/python3`、相對路徑呼叫 grep 抓不到、主 venv 有 3.12 的 `.pyc`（04:26，來源未知）。修：第 0 步寫成指令——claim lab（measuring＝venv 遷移）、1–3 步在 guard 底下跑、唯讀掃 `/proc/*/maps`、通知其他 session。

## Notes（要點）
1–3 檔頭「HOW THIS SET HAS BEEN RUN」裡 09-25 的是候選那組；"that exact set" 只對 09-26 解析成立（11 個 transitive 仍沒 pin）；live 未涵蓋清單漏了 5.29.6 下 switch 拒絕 entry 路徑與 N3 在 venv-cand 下是 INFERRED。4 本機 CI 形狀≠GitHub（setup-python 非 venv、本機有 p4_src/build、pip 版本）。5 GitHub CI 本來就紅 ⇒「推分支讓 CI 綠一次」做不到，驗收改成 P4 lane 逐檔對照 run 36220555111 沒有新紅＋單獨看 Install 步。6 ROLLBACK IN PLACE 演練起點與替身不忠實。7 第 3 步缺 `unset PYTHONPATH PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION`、遷移前沒在舊 venv 先跑基準、失敗不自動回滾、停放名寫死、沒確認 pyvenv.cfg home 的 minor 版本。8 `process_is_the_emitter` 真的危險但機率低，另開 chip 正確。9 主 venv 唯讀證據有空檔（07:36:55Z 之後）。10 cherry-pick 內容正確（regen 工具 188 行逐行相同）但沒存 git 輸出。11 22/41 實為 21＋1；l1 自己的 "will skip themselves" 也錯。12 遷移後 P4 live 量測的 stack 換了，raw 要記 venv 指紋、前後不混比。13 958bec1c RED 另一原因是 `tail -2` 藏了 TypeError。14 live 06 重建了 `~/tutorials/*/build` ⇒ FixtureProvenance 在真 HOME 下會紅，fixture 與 ~/tutorials 哪個對要有人決定。

## Adam 要裁的事（判官整理）
1. 併不併、怎麼併：(a) 另建確切這一組的 venv 經 P4_PROXY_PY 再試跑一次 live；(b) 接受 venv-cand 的 live＋離線逐條相同，改寫主旨，以遷移後的 live 01／06 當驗收。
2. 何時遷移：建議併入與遷移在同一個安靜時段、claim lab、持有建置鎖、和 HB spike 協調；先併晚遷 ⇒ 檔案與主 venv 不一致（check_pins 紅、就地 `pip install -r` 會讓 proxy TypeError）；先遷再併做不到；不併 ⇒ dependabot 兩個 high 繼續開。
3. 推分支跑 CI＝公開程序與 CANDIDATE 主旨；CI 本來就紅；也可併入後推 trunk。
4. repo 外手冊必須和公開推送同時更新（P4 路徑 clone 的另一個公開 repo 同步時機也要定）。
5. dependabot 只有預設分支帶上 5.29.6 後才會關（推論）。6. process_is_the_emitter chip 另案。

---

# 範圍複審（`d2e4708a`）：**READY FOR ADAM'S DECISION**

（同一位 opus-judge；要點。）B1–B3 都修好；失敗注入 20 情境全綠且看過紅（S11 在 dc2dc80a 紅、d2e4708a 綠）；protobuf 5 本體未動（pin 非註解行同 08483aa5、regen 工具 sha256 同 7cc50b42＝`66fb47b0…`）；演練逐字取 HEAD 文字（`fi_rehearsal.py:45-46`、形狀斷言 `:94`）；沒碰真 lab／主 venv（08:58Z 與 10:00Z 指紋皆 `33b3465d…`）／venv-cand；`test_l1_shell_scoring` 的 12 紅是既有的（trunk 一側只存 6/12 行）。
Notes（無擋併項；N1 建議在真正遷移前修或用繞法）：
1. **claim 時鐘在等鎖時就開始跑，之後只查兩次**：`ndt claim 90` 在等 build lock（LOCK_WAIT=10800）之前；`inwin` 只在第 1 步與 2a 查；claim 過期即被當空閒 ⇒ 2b–3c 間別人的 `ndt up` 可能用上半成品。S01 拿真鎖跑 912 s，私有鎖 53–55 s。修：claim 挪進 guard shell，或 `at()` 每步都 `inwin` 並要求剩餘 ≥30 分；繞法：進 guard shell 後、第 1 步前再 `ndt claim 90`。
2. `users()` 看不到：只靠 PYTHONPATH 的純 Python 行程（主 venv 的 3.12 `.pyc` 使用者仍未查出）、`PYTHONPATH`／`VIRTUAL_ENV` 指向者、root cwd 讀不到時連 argv 也跳過、含 `..` 的相對路徑、symlink 邏輯路徑。
3. 1f 在主 checkout（工作樹髒）跑基準，演練用乾淨 `git archive` 副本。
4. 「every check made to fail in turn」說過頭：rb2、rb3、ip1–ip4 沒注入失敗；ROLLBACK IN PLACE 做完不跑 suites、不查 `$PARK`。
5. 操作面：R2 文字不再說要去掉每行開頭的 `#   $ `；`ls -d …/` 的結尾斜線照抄會在 rb1 停；`LOCK`／`TIMEOUT` 環境變數會改 guard 行為；貼錯 shell 後外層留下 `STEP`，第 5 步拒絕 release 需先 `unset STEP`。
6. 卡在「ERROR at rb1/rb3 … ask」時 claim 90 分到期即失效 ⇒ 補「先同 owner 續 claim、寫 handoff note」。
7. 演練與真實的差異：HOME 指 scratch、pipe 非 TTY、真 `ndt claim/release` 沒跑、替身 venv 版本同但非逐檔同。
8. 遷移後再回滾，trunk 檔頭文字就不對了。
Adam 要裁：①併不併、怎麼併（(a) 先用 P4_PROXY_PY 對 C 組再跑 live；(b) reword 主旨、以遷移後的 live 01/06 驗收，舊 venv 保留可一步退回）②何時遷移、誰執行、N1 先修或繞法③推分支跑 CI 或併入後推 trunk（皆公開；CI 本來就紅，驗收看 P4 lane 逐檔對 run 36220555111＋Install 步）④repo 外手冊與其 clone 的公開 repo 同步⑤遷移後回滾時 trunk 怎麼處理⑥N1–N6 文字修正要不要現在做⑦dependabot、process_is_the_emitter chip、fixture vs `~/tutorials`、遷移後 live raw 記 venv 指紋。

---

# 範圍複審（`5bb5f1fa`）：**READY FOR ADAM'S DECISION**

（同一位 opus-judge，2026-09-26 ~19:1x；唯讀，未執行任何東西。要點由 orchestrator 轉錄。）
5bb5f1fa 只動 `p4_proxy/requirements.txt` 註解；pin 同 08483aa5（`final_gates_r3:3-4`）。**N1 已修**：第 1 步在 guard shell 內重 claim（`:237`）、`at()` 每條呼叫 `inwin` 要求剩 ≥30 分（`:215`、`:219`），失敗 STEP 不變並印續 claim 指令；S01 真鎖跑，步驟 0 claim 與步驟 1 重 claim 的 expires 差 415 s（等鎖不再吃 90 分）；S20 剩 60 s → STOP at 2b → 續 claim 從 2b 重貼 → VERIFIED。**N4 措辭與實注入相符**（新注入 rb2＝S22、rb3＝S23、ip1–ip4＝S24；ip0、第 4／5 步、ip5 未注入失敗且照實寫）。N2／N3／N5／N6／N8 文字到位（`OLD=${OLD%/}`；S02 確認貼錯 shell 不拿 claim）。演練 25/25 GREEN（`fi_summary-184418`；S01–S19 全重跑）。主 venv 11:00:25Z 仍 `33b3465d…`、比 marker 新 0 個。`test_l1_shell_scoring` 12 紅同 trunk（trunk 側 `logs/` 只存 6 行，但書同上輪）。

orchestrator 提的四點：
- **(a) 續 claim 被拒後無下一步——note，不擋。** S21：`at()` 只說續 claim 再貼，續 claim 被拒後沒寫怎麼辦；ROLLBACK 也要 `inwin`（`:275`）。不擋：失敗是安全的（其後每條都拒、舊 venv 停在 `$HOME` 指紋不變）、拿回 window 即可接著貼或 ROLLBACK、觸發面窄（每條要求剩 ≥30 分 ⇒ 只剩 STOP 後離開太久過期被接手，或有人改寫 claim 檔／`release --force`）。後果要寫清楚：停在 2c ⇒ V 是半成品，proxy import 時 TypeError（看得見）；**停在 3a–3c ⇒ V 是 regen 完未驗證的新 venv，新持有者跑 live 會不知情量到 protobuf 5**。建議（不需再審）在 HOW TO RUN IT 補一句：「續 claim 被拒＝lab 被別人拿走：告訴對方 p4_proxy/venv 在遷移、不要跑 P4 live；等對方 release，重做第 0 步，再從 STOP 那條接著貼或 ROLLBACK。任何 STOP 後要離開，先同 owner 續 claim 並寫 note。」
- **(b) ip5 判斷成立。** `OK (skipped=N)` 以 OK 開頭會算；`suites()` 永遠 exit 0（最後是 sed）⇒ `SU=$(…) &&` 擋不了東西，真閘門只有 OK 行數＝2；某套在印 OK／FAILED 前死掉（崩潰、OOM、`mktemp`／`cd` 失敗）⇒ 少一行 ⇒ 1f 與 ip5 都 STOP。缺口：測試自己印以 `OK` 開頭的行會被算（目前輸出恆為 Ran/OK/Ran/OK 四行）。更嚴：兩行 `Ran`、零行 `FAILED`、OK 行整行比對。note。
- **(c) stub 就程序依賴的語意忠實。** 讀主 checkout 的 `tools/test_workflow/ndt`（無法用 git 證它是 9c2e59e4，但 686–945 行與 580767a8 逐字同）。同 owner 重 claim：`foreign_claim` 視自己非他人（`:694`）、`claim_take` 不看 measuring ⇒ 允許並以當下 NDT_MEASURING 覆寫（stub 同）；他人未過期 claim 拒 rc 1（`:785-787`，stub 同）；過期／壞格式視為空閒（`:691-692`，stub 同）。stub 未模擬（不改控制流）：flock＋讀回（改寫檔時真 claim rc 1，程序本就靠 `inwin` 讀檔）、每次 claim `record_round_baseline`（`:849`：第 1 步與每次續 claim 都把本輪基準改成當下）、`.prev` 輪替（`:796`，前任紀錄被自己上一次 claim 蓋掉）、handoff 檔改名（`:842`）；S03 的 `.foreign` 是 stub 專用注入，只驗 `&&` 串接。
- **(d) 沒東西會壞。** 真 `cmd_release`（`:865-945`）只查他人 claim 與 host knob、不看 measuring ⇒ 第 5 步外層 shell（有第 0 步 export 的 NDT_OWNER、knob 未動）可 release；knob 基準＝最後一次 claim 時所記。rb1/rb3 handoff 重 claim 與 `at()` 續 claim 同 owner、measuring 保留 ⇒ 持續擋別人的 `ndt down`／check（正是要的）。新 shell 回滾重做第 0 步、兩變數重 export。提醒：在沒 export NDT_MEASURING 的 shell 續 claim 會悄悄清空 measuring（規定路徑都會 export，不會發生）。

其他小 note：ROLLBACK（`:275`）與 ip0（`:291`）不像第 1 步先重 claim ⇒ 從新 shell 回滾若又等很久的鎖會停在 rb1／ip0，而 rb1 的 STOP 訊息沒提續 claim（只能從 `inwin` 的「30 minutes」推出）。第 4 步的 `exit` 也要求剩 ≥30 分（不夠會叫先續 claim；直接 `exit` 亦無害）。

**Adam 決定清單的變動**：刪「N1 先修或繞法」（已修）、「N1–N6 文字要不要現在做」（已做）。改寫「遷移後回滾 trunk 怎麼辦」＝程序已寫「補回那兩句，或 revert 這次 merge」，只需選一種（可選）。新增（小）：(a) 那句話與 (b) 的嚴格判斷要併前補（需小規模重演 S21、S10、S24）還是接受現狀；協調規則「遷移公告期間即使 claim 過期，其他 session 也不接手 lab」。其餘不變：併不併＋主旨（C 組未跑 live）；何時遷移、誰執行（與 HB spike 協調）；推分支或 trunk 跑 CI（基準本來就紅，逐檔對 run 36220555111＋Install 步）；repo 外手冊同步；dependabot；emitter chip；fixture vs `~/tutorials`；遷移後 live raw 記 venv 指紋。
