[Co-developed with claude code -- Adam]

# Cut 1 follow-ups r6：讓健檢的「這一輪的身分」真的屬於這一輪

分支 `fix/p4-health-run-identity`，從 trunk `dd8022fa` 開，head `26685043`（含 `f9667cee`）。未推送。

## 為什麼要做
上一輪審查指出：`recover.sh` 判斷「現場是這個 run 的」只靠 owner 和 package 路徑，兩輪之間這兩樣都可以相同。後果是：人去救一個舊 run 目錄時，若後來同 owner、同 package 路徑的一輪正持有 live claim，`recover.sh` 會對那一輪的介面下 `tc qdisc del`，快照相符時再下 `ndt down`。這是第一次 live 之前必須關掉的洞。

## 做了什麼
| 項目 | 內容 |
|---|---|
| 每輪自己的 package | `LabRound` 拒絕 run 目錄以外的 `package_dir`（含 `..`、符號連結、名字開頭相同的鄰居、run 目錄本身），在動任何東西之前丟 `PackageOutsideRunDir`。`recover.sh` 同樣要求 package 在 run 目錄內，否則 rc 3、什麼都不寫。 |
| claim 身分 | `ndt claim` 成功後立刻從 claim 檔讀 `expires`，記進 `LAB_STATE.claim_expires`。live 分支與過期分支都要求 claim 檔的 `expires` 等於記下的，否則 rc 3、什麼都不寫。claim 檔讀不出自己的 claim → 新 phase `claim-unverified`，不 up、不 release。 |
| 補強 | `owner`、`run`、`package`、`claim_file`、`app_package_override`、`claim_expires` 缺或空 → rc 2。`recover.sh` 自己重新 claim 成功後，把新的 `expires` 寫回 LAB_STATE，否則失敗後第二次執行會在自己的 claim 上 rc 3。 |
| R5-1c | 改成真的把 fabric 檢查「移到 claim 之後」，不再是刪掉。 |
| 改名與斷言 | 掃描測試改名為 `..._in_expected_today_tsv_or_tools_p4_health`；表頭測試加上兩個檔案確實存在的斷言。 |
| 表頭與設計 | `recover.sh` 第 9 行改成「用只屬於這一輪的證據確認」，並寫明還沒證明的兩件事。DESIGN §4.5、§14.7 第 12 項標 r6。 |

## 證據
- 舊碼（dd8022fa）上：recover 32 個新檢查紅（共 108）、collect 9 個失敗，原因都是舊碼照常往下跑 tc 與 ndt down。
- 新碼上：recover 108/0、cells 98 OK、collect 60 OK，在 3.12.3、3.13.13、3.8.20 都綠。H1–H4 非封死版仍全紅。
- 變異閘門：180 個變異、0 存活，對照組綠，原檔 byte-identical。S0 經 run.sh 仍 COMPLETE。anchors、tmpdirs、l1 scoring 都綠。
- 閘門跑了三次：前兩次各抓到我新加的檢查把舊變異體「遮住」（D9、R5-1b）或變異體本身寫壞（R6-2a 語法錯、R6-3f 多餘），都已修。

## 要注意的決定
1. claim 檔不見（gone）時，過期分支一律 rc 3，不再接手。這是我對「過期 claim 檔的 expires 要等於記下的」的字面解讀；想要放寬可以改回來。
2. 沒有 `claim_expires` 的 state（lab-busy、claim-refused、或在 `ndt claim` 與寫入之間當掉）一律 rc 2，交給人處理。
3. Cut 1 沒有 lab 驅動程式，「把 S0 建好的 package 複製進 run 目錄」是 Cut 2 驅動程式要做的事；Cut 1 只擋住不照做的情況。
4. 還沒證明的：同 owner 在同一秒、同長度的另一個 claim 會有相同的 `expires`；人手動對這一輪的 package 目錄下 `ndt up --app`，看起來就像探測器。
