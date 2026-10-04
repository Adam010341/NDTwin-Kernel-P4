[Co-developed with claude code -- Adam]

# Cut 1 follow-ups r8：重新審查找到的兩個收尾舊洞

分支 `fix/p4-health-run-identity`，head `a7f9e03f`（一個新 commit），未推送。

## 這一輪的規則
測試用的 stub，只要某個修法的結果取決於它的行為，就必須照 `tools/test_workflow/ndt` 與 `qdisc_snapshot.sh` 真的行為寫，並在旁邊註明行號。照著寫之後，兩個舊洞立刻現形：先前的 stub 讓 `qdisc diff` 在 down 之後仍然成功、`ndt release` 永遠成功、`ndt claim` 不記 baseline，所以兩個洞一直是假綠。

## N1：`ndt down` 跑過之後沒有介面了，qdisc diff 一定不同
- 後果：`ndt down` 拆乾淨卻回 1（被 SIGKILL 過一次之後的一次性紅，`ndt:5312-5318`），或探測器自己的 down-failed 之後，重試會在 qdisc diff 停在 rc 4，並說「fabric 還在」——這是假的。
- 修法：knob 不在、phase 不是 `down-done` 時，先問 `ndt status`。沒有 bmv2、沒有 host/switch → 這個 down 已經做完，記 `down-done`，跳過第 4–5 步，接著重讀 claim、還原 knob、release；還有 fabric → 第 4–5 步照舊。`ndt down` 的 rc 3（沒有東西可以拆，`ndt:5524-5537`）算做完。
- 證據：新檢查在 a281f2cc 上紅（舊碼 rc 5 之後重試 rc 4），新碼綠；四個變異體各被指名的檢查抓到。

## N2：`recover.sh` 自己重新 claim 之後，release 被自己的 baseline 擋住
- 後果：`ndt claim` 把當下的 host knob 值記成 round baseline；重新 claim 時 knob 還是這一輪的值，第 6 步還原成輪前的值之後，`ndt release` 必定拒絕（rc 6），而 ndt 印的補救是「把 baseline 的值寫回去」，會把還原蓋掉。夜裡當機、早上發現 claim 已過期，正是這條路。
- 修法（審查者的選項 b）：重新 claim 的 `expires` 同時記進 `recover_claim_expires`。release 時若手上的 claim 就是那一個、而且每個 knob 都等於 snapshot，就用 `ndt release --force` 並印一行原因；其他情形仍用普通 release。rc 6 的訊息改成：knob 已還原到輪前的快照，不要把印出的值寫回去，lab 可能需要人看。
- 證據：新檢查在 a281f2cc 上紅（rc 6 加上 ndt 的 baseline 拒絕訊息），新碼綠；四個變異體（一律 --force、從不 --force、沒記 claim、舊訊息）都被抓到。

## 其他
- 殘餘風險補上：探測器自己的 `ndt down` 在清掉 knob 與寫 note 之間被殺，note 規則會拒絕（rc 3，安全）。
- 沒記到 `claim_expires` 的提示：只有在 `<claim>.overrides` 沒有針對該 claim 的行時才說「沒有東西被帶起來」，否則改成警告。
- 更正我上一份回報的三處不準：F2 在 f721be78 上四個 note 檢查都是紅的（被 F1 遮住的是 overrides 與重讀 claim 的檢查）；collect 的紅是 failures=2、errors=1，兩個測試函式；recover 綠的行號是 165。

## 驗證
- recover 155/0、cells 98 OK、collect 61 OK，在 3.12.3、3.13.13、3.8.20 都綠。H1–H4 仍全紅。
- 變異閘門 208 個變異、0 存活，對照組綠，原檔 byte-identical。S0 COMPLETE。anchors、tmpdirs、scoring 都綠。

## 沒做
- `knobs_match_snapshot` 條件沒有變異體：第 6 步成功之後它必然成立，沒有測試能讓它不成立。
