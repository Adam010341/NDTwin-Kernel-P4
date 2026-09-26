# pb5-trial-0926：protobuf 5 候選（`7cc50b42`／venv-cand）live 試跑

（worker 最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，筆記與逐階段時間在 `logs/orchestrator-0924/intake-0926/pb5-trial/`（INDEX.txt、JOURNAL.txt）。orchestrator 事後實查 `ndt status`：claim none、measuring nothing、無 fabric、無殘留程序。）

**結論：從 live 這一側看，候選可以併**；judge-REQ §8 的非 live 項目未做，**整體仍不能併**。沒有 commit／push／merge、沒改追蹤檔。

1. 切換／還原（OBSERVED）：只在試跑指令前加 `env -u PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION P4_PROXY_PY=<wt-p4proxy-reqs-0925>/scratch/venv-cand/bin/python`（`components.env:45` 只在未設時給預設、`ndt:2057` `p4_proxy_py` 認它、drive_exercise `ndt_env()` 往下傳）；10 個相關追蹤檔前後 sha256 全 OK；knob 前後相同（host `7de1555d…`＝`4\n`，另兩個不存在）；主 venv 指紋前後 `33b3465d…`；venv-cand 開跑前 `aa1d4c72…`（＝REQ 交件時）→ 之後 `abecbbe2…`（只多 9 個 `__pycache__/*.pyc`；8 個重生 `_pb2*.py` `sha256sum -c` OK）。
2. /proc（OBSERVED）：06 的 24 個 cand proxy 與 01 cand 的 proxy：cmdline[0]＝venv-cand python、maps 有 `…/venv-cand/…/google/_upb/_message.abi3.so`、environ 無 `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION`；主 venv 三個 proxy 無 `_upb`。
3. live 01（OBSERVED）：09-24 baseline、今天主 venv、cand、還原後主 venv 四次都 PASS；switch_state 457 行、graph 998 行遮時間後逐行 0 差；23_verify_p4 相同；首條規則時間 1.20–1.30 s 四組相同；proxy log 各類事件次數同型、Traceback／TypeError／RuntimeError／版本錯誤 0。
4. live 06（OBSERVED）：cand 26 臂 `PASS 06_thirteen`，兩個設計紅臂照舊；逐列 SAME 164／DIFF 6（全是 ecn、mri 注入封包計數，PASS 且高於門檻；09-19 對 09-24 兩次主 venv 也有 5 個同類 DIFF ⇒ 雜訊）；主 venv `ONLY=basic,p4runtime` 同碼對照 SAME 31／DIFF 0、4 臂 proxy log 行型態多重集合相同；24 份 cand proxy log 錯誤字樣 0。
5. LiveSwitchTest（OBSERVED）：`ndt up p4 4` 在 cand proxy 上、只停 proxy（核對 supervisor cmdline＋pgid 後 `kill -TERM -- -<pgid>`）；`NDTWIN_LIVE_SWITCH_OPT_IN=1` 主 venv 與 venv-cand 各 `Ran 1 test … OK`（非 skip）；ad-hoc error-path probe 兩 venv 除直譯器行外逐行相同；之後 `ndt down` rc 0 verify clean。
6. 資源（n 小）：01 CPU 1.22／1.27（主）vs 1.06 s（cand），peak RSS 90.4／90.5 vs 86.0 MB；06 同 4 臂 RSS 87.5–87.9 vs 84.4–84.9 MB。
7. 範圍：**不是單一變數**——兩 venv 差 15 項（protobuf 3.20.3→5.29.6、backend python→upb、另 12 個套件版本不同、多 grpcio-tools 1.71.2 與 setuptools 84.0.0；`dists_diff.txt`）⇒ 證明的是「這一整組」live 可用；drive_exercise 的 convert／preflight（N2）仍在主 venv；5.29.6 下的 preflight 只經 ndt app_preflight（N3）跑到（24 份 N3 `PASS p4info parses`，N3 在 venv-cand 下是 INFERRED）；basic_tunnel/skeleton 在 N2 被拒 ⇒「5.29.6 下拒絕 entry」未跑到；judge item 3 的前提一半不成立（proxy 無 `google.rpc.Status`／`Any` 解包）。未涵蓋：128 hosts、長跑、有流量的遙測、OVS；候選 commit 的非 venv 部分（regen 工具負面路徑、ci.yml、3 處 hint 字串）。
8. 併之前（非 live，judge §8）：改寫 CANDIDATE 字樣、rebase 到 `851cefd7`（trunk 已含其 merge `a4c951a8`）、推分支讓 GitHub CI 綠一次、寫遷移與回滾步驟（建議新建 venv 再切換）、更新 repo 外的使用手冊。
- 額外用了 lab 三次短跑（01 主 venv 同碼對照、06 `ONLY=basic,p4runtime` 主 venv 對照、01 主 venv 還原檢查），都有記錄。
- raw（untracked）：`live-p1/runs/2026-09-26T054912Z_01_baseline`（主）、`…T055003Z_01_baseline`（cand）、`…T055148Z_06_thirteen`（cand 26 臂）、`…T062049Z_06_thirteen`（主對照）、`…T062558Z_01_baseline`（還原檢查）；drive_exercise 報告 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T05*`、`…T06*`。
