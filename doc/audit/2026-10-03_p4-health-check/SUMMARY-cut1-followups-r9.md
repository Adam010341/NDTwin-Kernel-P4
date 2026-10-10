[Co-developed with claude code -- Adam]

# Cut 1 follow-ups r9：N1 的分支繼續跑 `ndt down`，claim／release 在測試裡跑真的 `ndt`

分支 `fix/p4-health-run-identity`，head `35e3479d`（一個新 commit），未推送。

## 1. F1：N1 分支只跳過第 4 步
- 問題：r8 的 N1 把「knob 不在、`ndt status` 沒有 bmv2 也沒有 host/switch」當成「down 已經做完」，連 `ndt down` 都跳過就 release。但那兩列不是 `ndt down` 要拆的全部（topo session、manifest、registry、port），而且 `ndt down` 回 1 時可能還留著活的行程、knob 卻已清掉、note 寫 "did NOT verify clean"。探測器自己的 down-failed 之後，recover 會在沒有任何 `ndt down` 成功的情況下 release，還印「done」。
- 修法：N1 分支只跳過第 4 步（netem、qdisc diff：這兩個要介面），第 5 步 `ndt down` 照跑。`ndt down` 冪等；空 lab 回 3 算做完；再失敗就是 down-failed（rc 5、不 release）。N1 分支自己不寫 phase，第 5 步的寫入就是紀錄。
- 證據：新案例（down-failed、knob 不在、status 0/0、「did NOT verify clean」的 note、重試的 `ndt down` 回 1）在 a7f9e03f 上紅（rc 0、已 release），新碼綠（rc 5、down-failed、沒有 release）。oneshotred 與 probedownfailed 的呼叫清單多了 `ndt down` 並仍是 rc 0。R9-1 取代 R8-1d；R6-2d 現在只動 `claim_expires` 那一行的寫入。

## 2. 不再讓 stub 自己發明行為
- `ndt claim`、`ndt release` 是檔案操作，測試改成跑**真的** `tools/test_workflow/ndt` 的暫存副本（自己的 `.test_run` 與 `p4_proxy/mininet`）。探測器自己的 claim 也是真的 `ndt claim`（在 knob 還是輪前的值時拿，所以真的 baseline 記的是輪前的值）。
- 離線可行，沒有擋住的地方。只有碰行程與介面的東西還是 stub：`ndt down` 的拆除、`ndt status` 的行程列、`qdisc_snapshot.sh`、sudo、kill，加上兩個注入點（回 0 卻不寫 claim 的 claim、無法自然產生的 release 拒絕）。
- `ndt status` 的 claim 檔部分沒有用到：recover 直接讀 claim 檔，而真的 status 會列出主機上的行程，不是封閉的。
- 範例：`items/real-ndt-sample.log` 是一個 N2 案例從頭到尾，裡面可以看到真的 ndt 的輸出與 `.prev`。

## 3. 便宜的測試
- ndt status 沒有回答、或缺列，在兩處讀取（N1 分支、down-done 的 fabric 檢查）都不被當成空 lab；各有一個「缺列當 0」的變異體。
- `recover_claim_expires` 只在新 claim 的 `expires` 大於現在時才記（一個回 0 卻沒寫新 claim 的 `ndt claim` 不會被當成自己的），有測試與變異體。
- down 期間別的 owner 接手 claim（`expires` 不變）→ rc 3、不 release；補上重讀 claim 的 owner 那一半（變異體 R9-5）。
- downrc3 與 probedownfailed 的 fixture 改成真的 `ndt` 做得出來的狀態。
- 殘餘風險補上：knob 還在但 data plane 已經沒了；recover 從不寫 phase `released`。

## 驗證
- recover 163/0、cells 98 OK、collect 61 OK，在 3.12.3、3.13.13、3.8.20 都綠。H1–H4 仍全紅。
- 變異閘門 212 個變異、0 存活，對照組綠，原檔 byte-identical。S0 COMPLETE。anchors、tmpdirs、scoring 都綠。
- recover 的測試現在每次約 40 秒，所以閘門要跑兩個小時左右。
