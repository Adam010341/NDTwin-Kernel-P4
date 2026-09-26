# ndt serve 併入複審（限定範圍）：`48209682 → f643b884`

（opus-judge 同一位判官的限定複審最後回覆，orchestrator 2026-09-26 存檔；全文見本 session 逐字稿，此處保留裁定與編號結論原文。）

## 裁定：MERGE（可以 fast-forward 進 trunk，條件見第 8 條）

- 上一輪唯一的 blocking（逐 commit 掃描）已經關閉。
- 第 2、3、4、5、7（第一點）條都修了，每一條都有看過紅的證據。
- 兩組 log 在 `f643b884` 上全部以 `rc=0` 收尾：worker 在 `gates-0910` 的一組，和 orchestrator 的 `rerun-NDTSERVE-f643b884/` 9 支。
- 閘門兩次都是 91 個變異、0 倖存。7 個受測檔的 sha 兩邊一致（serve.py `20a8a010…`、verbs.py `b56ad079…`、ndt `6954755b…`）。
- 這次沒有 blocking。多了一條新的不實陳述：README 的測試數字（第 5 條）。建議順手修，不擋。

要點：(a) `OWN_CLAIM.fullmatch` 與 ndt:5677 的 printf 完全吻合；claim_line 只可能印 5 種值，尾端對齊論證可確立漏洞只剩 owner 恰好叫 `yours`（已寫明）。(b) 兩個讀不到 claim 的分支訊息正確；C28 守安全（逾時讀取裡的 `yours` 讓 cell 跑起來），C27 守 API 契約。(c) 函式定位器依慣例運作：欄 0 `name() {` 256 行（單行 42、多行 214），欄 0 單獨 `}` 正好 214 行；M63 在 48209682 倖存、在 HEAD 被抓且原因正確。(d) 更正過的行號與文字在合併後的 ndt 上全部正確；新不實：README:151-153 的 72/32/86（應 73/35/91）；verbs.py「187 行」今天對、ndt 一改就過期。(e) `ndt help` 只動 3 行、無新 `$`／backtick、三個 help 測試綠、陳述屬實。(f) 三個修正 commit 無不該公開的內容。

## 編號結論

1. 【note】逐 commit 掃描成立，原第 1 條關閉。建議補：兩個 merge 的 `--cc` 檢查、通用 IPv4 pattern、修正那次的隱私對照組。
2. 【note】加一條把 OWN_CLAIM 釘在真 ndt 的 ndt:5677 printf 上的測試（否則 ndt 改格式，所有 lab 格會悄悄變 409——安全方向的失敗，但沒有測試會發現）。
3. 【note】C27 守契約、C28 守安全，兩條都成立；逾時那條測試在舊碼上只紅在訊息細節，SUMMARY 已照實揭露。
4. 【note】定位器依慣例運作；目前 ndt 完全符合那些慣例。
5. 【note，建議這次一起修】README:151-153 的測試數字已過期：72/32/86 應為 73/35/91。
6. 【note】help 仍漏了 cells／guided 和 XDG（原第 7 條其餘部分）。
7. 【note】上一輪仍開著的 note：第 6 條 SLOT 等待無上限；第 8 條舊 walk 邊角；第 9 條 post-r2 碼（含新 precheck 分支）無 live 證據；第 10–13 條 CI、NoPatternKill、登記表範圍、r2 延後項目（CI 形狀這次已用本機 python 3.12.3 在 `env -i` 下實跑，兩套件都綠、沒有 skip）；SUMMARY 自揭兩項：plain status 回非 0 時仍拿去讀 claim、walk 的 why 顯示 `(claim line: None)`。
8. 【note，推之前必做的檢查】fast-forward 的前提是 trunk 仍停在 `14554090`；推之前先確認 `git merge-base --is-ancestor <trunk> f643b884`。若 trunk 已動，就不是 FF：要重新 merge、重跑閘門，新的 merge commit 也要掃描。
