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
