[Co-developed with claude code -- Adam]

# Cut 1 follow-ups r7：run-identity 分支審查之後的修正

分支 `fix/p4-health-run-identity`，head `a281f2cc`（兩個新 commit：`15a5a1dd`、`a281f2cc`），未推送。

## 審查找到的三件事，和怎麼修
| 項目 | 問題 | 修法 |
|---|---|---|
| F1 | `recover.sh` 用 `head -1` 讀 knob，但真的 `ndt` 把它寫成兩行（註解、再是路徑）。結果對真的 knob，每個「knob 還在」的當機狀態都 rc 3。測試一直綠，是因為 fixture 寫的是 ndt 從不會寫的一行。 | 改讀第一個不是空白、不是 `#` 的行（同 `app_knob_dir`）。fixture 全部改成 ndt 的兩行格式（複製 ndt 的兩行 printf，並註明出處）。新增三個 knob 格式的檢查，和「把 `head -1` 放回去」的變異體。 |
| F4 | `recover.sh` 自己跑完 `ndt down` 卻不記 phase；真的 `ndt down` 不論成敗都會清掉 knob，所以重跑時 knob 不在、phase 還是 cells，對自己的 live claim rc 3。測試的假 `ndt down` 沒清 knob，所以一直綠。 | `ndt down` 成功寫 `down-done`，失敗寫 `down-failed`；假的 `ndt down` 改成像真的一樣清掉 knob。 |
| F2 | knob 不在、claim 還是自己的 live claim 時，只要 note 是「in use: ndt up …」就放行。同 owner 的另一個 baseline `ndt up` 正好寫這個 note，於是 recover 會對別人的 fabric 下 tc、`ndt down`、release。 | knob 不在時，只認這一輪自己的 note 或 `ndt down` 的 "down at …"，不認 ndt up 的 note；`<claim>.overrides` 裡有一行 `claim_expires` 等於記下的值（有人 `--force` 越過這一輪的 claim），不論哪個分支都不行動。header 與 DESIGN 的說法一併更正。 |

## 順手做的小項目
- `ndt down` 之後、還原 knob 與 release 之前，再讀一次 claim（owner 與 expires 都要還在，否則 rc 3）。只做一次，因為 release 緊接在 knob 還原之後、中間沒有 ndt 呼叫。
- claim 檔不見時，印出 `lab.claim.prev` 的 owner 與 expires，並說明那是不是這一輪記下的 claim；沒記到 `claim_expires` 但 claim 的 note 是這一輪獨有的格式時，印出 `ndt release` 的指令。
- 探測器還活著的檢查移到欄位檢查之前（還在跑的探測器得到 rc 3，不是 rc 2）。
- 殘餘風險措辭改成「同一個結束秒」。
- `LabRound` 把 package 路徑解析一次，檢查、LAB_STATE、`ndt up --app` 都用同一條；expires 改用 `^[1-9][0-9]*$`，不再用 `isdigit`。

## 證據
- F1、F4、F2 的新檢查在 f721be78 上都看過紅；F1 的檢查在 dd8022fa 上也紅。F2 在 f721be78 上被 F1 遮住（舊碼本來就 rc 3），所以另外做了「只修 F1」的副本來單獨看 F2 與 F4 的紅（18 個檢查紅）。
- 新碼：recover 136/0、cells 98 OK、collect 61 OK，在 3.12.3、3.13.13、3.8.20 都綠。H1–H4 仍全紅。
- 變異閘門 198 個變異、0 存活，對照組綠，原檔 byte-identical。S0 COMPLETE。anchors、tmpdirs、scoring 都綠。
- 閘門跑了三次：前兩次發現我新加的檢查遮住了舊變異體（R1、R3）、一個變異體變成等價（R6-1f、R7-1c）、一個變異體語法錯（R7-5d），都已修。

## 沒做
- 每輪自己的 owner 或 claim nonce（會關掉整個「同 owner」類），要在 Cut 2 的驅動程式裡做。
- `recover.sh` 在自己的 `ndt down` 之後、寫 phase 之前被殺：下一次是舊 phase 加已清掉的 knob，會 rc 3。header 與 DESIGN 已寫明。
