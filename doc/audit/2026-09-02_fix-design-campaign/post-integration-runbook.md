# 整合報告到手後的收尾順序（auditor 自己執行；每步有證據才進下一步）
1. 對帳（buildwt）：`git status --porcelain` 空；HEAD sha 與報告一致；我自己跑 `python3 tests/shell/check_gate_anchors.py HEAD`（期望全 ok／driver 型 2）、`/home/adam/miniconda3/bin/python3 tests/python/test_shell_command_construction.py`（A-4f execArgv 後應 7/7 綠）、`grep -E 'tests passed' integ.ctest.log`；閘門表逐支 rc=0 且有 `N mutations, 0 survived`；rc=2 的要有理由（baseline 紅＝trunk 既有／環境）。
2. 主 worktree 合併：`git status --porcelain | wc -l`（mainDev 未提交檔不可與整合變動同檔：`git diff --name-only trunk..integrate/... | sort > /tmp/a; git status --porcelain | awk '{print $2}' | sort > /tmp/b; comm -12 /tmp/a /tmp/b` 必須空）→ `git merge --ff-only integrate/2026-09-02-fix-campaign` → `git log --oneline -1`。
3. KNOWN-ISSUES：`for d in mechanism rulings status usertest; do patch -p0 doc/KNOWN-ISSUES.md < $S/known-issues-delta/KNOWN-ISSUES.$d.diff; done`；狀態 diff 裡 B-2b/B-4 那句「守衛目前紅」在 execArgv 已修時要拿掉（手改一行）；`git commit -m "..." -- doc/KNOWN-ISSUES.md`（英文、co-developed 標記；訊息列四個 diff 的來源與 Adam 四題裁決）。
4. 快照入庫：`git add -N doc/audit/2026-09-02_fix-design-campaign/`（先 rsync 最新 LEDGER／findings／delta／batch 進去）→ `git commit -- doc/audit/2026-09-02_fix-design-campaign/<逐檔>`（**列到檔案**，用 `git ls-files -o --exclude-standard doc/audit/2026-09-02_fix-design-campaign | xargs git commit -m ... --`）。
5. 推送：`git fetch lab p4`；`git diff --stat lab/trunk..trunk | tail -1`（暴漲檢查：預期 ≈ 整合 +N 檔）；`git push lab trunk && git push p4 trunk`；**不推 origin**；公開與否只打公開 URL 驗（本次不涉及）。
6. lab：釋放整合 claim（agent 應已 release；若沒有 `NDT_OWNER=auditor ndt release`）→ 派整機一輪 agent（`live-round-brief.md`；它自己 claim）。
7. 通知：mainDev（trunk 已合、kernel 重建規則、別開 ninja 直到 live round 結束）、開機手冊（推了）。
8. 記憶 checkpoint（`/pre-compact` 程序）：補記三十六（整合結果、oomd、shim、四題裁決、usertest 三條、live-verify 佇列）。
