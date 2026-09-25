**判決：MERGE**

r2 的 blocking #1 和 #3、#4、#5、#7 全部 CLOSED。worktree 裡唯一的紅格是機器環境造成的，我確認了，不是這輪的 diff 造成的。其餘發現都不擋合併。全程唯讀，沒有執行任何東西，也沒用 git。

證據核對：這輪 9 份 `*.ndtovs-98442add.log` 第 1 行都是 `98442add6ed344a4e60c4346147f35c120a31e06`，全部沒有 dirty 檔。只有 `ndt_lab_suite` 是 rc 1，就是 helper 那一格。

## r2 新項目

| 項目 | 結果 | 證據（一行） |
|---|---|---|
| #1（blocking）新的 `--check` rc 1 沒揭露、沒測 | CLOSED | help 在 ndt:10785-10788，手冊在 :520-523，都寫了「有 baseline 時 rc 1、沒有時仍是 3」；SUMMARY §2 那一列補了限定詞；§17 這一格在 base 上是紅的（base log:317-318，實際 0），在 head 是綠的；M36、M37 都抓到（mutate log:51-52） |
| #3 同一次 `down` 前後矛盾 | CLOSED | ndt:4876-4883 對 kernel／p4_proxy／ryu 的回收號碼加一句 `; stack.sh kept it above because the number is somebody else's`；這格紅燈先行（red-first log:164）；M38 抓到（log:53） |
| #4 F4 錯誤訊息沒講救法 | CLOSED | ndt:4866 加了「to recover: make .test_run/apps a directory this user can write, then run 'ndt down' again」；紅燈先行（log:174）；M39 抓到（log:54） |
| #5 手冊的判定順序和程式不符 | CLOSED | 手冊 :513-516 改成：號碼被回收就直接判 stale、不問 group，app 和 stack 的 pidfile 都一樣；和 ndt:4784-4787、4795-4798 一致；手冊這格紅燈先行（log:209-210） |
| #7 變異 log 標頭寫錯數量 | CLOSED | 標頭改成執行時從腳本數：「39 named mutants, 3 controls -- counted from the script at run time」（mutate log:2） |

## 這格測試能不能證明 rc 變更，以及 M36、M37 改的行對不對

- **判別方式對。** 這個 rc 變更是第二輪引入的，所以這格在 e1420df2 的 ndt 上一定是綠的。真正的「變更前」是 base 62f76cf5：
  - rc 那格在 base 上是紅的（實際 0）；
  - 同一節的兩個對照在 base 和 head 上都是綠的：同一個活程序、檔案在它啟動後才寫 ⇒ 0；沒有 baseline ⇒ 3（base log:321-322）。
  - 所以 base 和 head 在 §17 只差回收號碼的判定這一個變數。
  - `CHECK_STUB` 只回答有沒有 baseline；對照格 rc 0 證明 fixture 裡沒有其他 problem 來源。
- **M36 改的是對的那一行，而且是最有力的證據。** 它把 recycled 那行的 `bad+=` 改成 `live+=`：文字照樣印出來，所以第二輪那些驗列文字的格全部維持綠，但這一行不再算 problem。結果只有 §17 紅了 2 格（rc 那格、problem 清單那格）。這證明 §17 抓的是 rc 的接線，不只是文字。
- **M37 改的也是對的那一行。** 它把 help 的限定詞改成「always rc 1」，§16 的整句檢查紅了 1 格。這是文字變異，只釘住 help 的句子，這正是「help 講實話」需要的。手冊那句沒有變異（手冊不在變異範圍內），但它的測試格有紅燈先行。

## helper 那一格紅：確認是環境問題

- 紅的只有「the installed helper is the copy this suite read」：預期值是這棵樹的副本 `6685d3a9…`，實際值是已安裝的 `6a558fe4…`。匯出的 e1420df2 樹和 head 都是 150 格紅 1 格（helper_env_evidence log:25-34）。
- 這棵樹的副本在 62f76cf5、e1420df2、HEAD 三個版本都一樣（log:17-19）；這輪 diff 的 4 個檔都不是 helper，也不是那支 suite。
- 同一支 suite 在 18:20-18:24、也就是換檔（19:34:12）之前是全綠的（ndt_lab_suite.ndtovs-e1420df2.log:25）。
- 我另外用唯讀方式比對了內容：
  - 已安裝的 `/usr/local/sbin/ndtwin-lab` 和主 checkout 的 `tools/test_workflow/ndtwin-lab` 都是 1,835 行，heartbeat 時期字串都各有 80 行命中；
  - 這個分支的副本是 745 行、10 行命中。
  - 我算不了 sha256，只能比內容。
- 限制：這棵樹裡其他 149 格測的是分支上的舊 helper；你合併後在 trunk 上跑的那一次才是對新 helper 的真正檢查。

## 工單 ecda7e09 對 (b) 的陳述

大致正確。§1 標了「讀碼推得、沒實測」，以下都對：
- 規則從哪來，以及 F2／F8 把它搬進 ndt；
- 單純 suspend 不會觸發；
- 時鐘往前調 Δ，btime 跟著加 Δ，mtime 不動；
- 累積超過約 2 秒後的三個後果；
- 哪些是本來就有的問題、哪些是 OVS 單加上的；
- 修法方向是先比 supervise.sh 的 argv，而且 `stop_one` 和 ndt 用同一個判準；
- 先查 log 裡有沒有發生過；
- 驗收用倒填 mtime 來模擬時鐘往前調，這和 btime 往前跳是等價的。

引用的行號在 trunk 的 stack.sh 上仍然正確（:579、:588；supervise.sh :3、:48），引用的判官報告路徑也存在。需要改或補的：

1. **§2 裡「`.child.pid` 對照 `<name>.cmd`」不能逐字比。** 這是我 r2 的建議不夠精確，被工單照抄了。
   - `.cmd` 記的是包裝指令。以 kernel 為例，記的是 `bash -c "export …; cd … && exec ./bin/ndtwin_kernel …"`（stack.sh:1118-1119）。
   - `/proc` 看到的是 exec 之後的 `./bin/ndtwin_kernel --mode …`。stack.sh:349、:438 自己就說每個服務都經過會 exec 掉的包裝。
   - 所以要改成在記錄的指令裡找 exec 後的 argv；或者 `.child.pid` 乾脆不做這項比對，因為它是否有效可以由 supervisor 那個檔推出來。
2. **stack.sh:584 沒有 supervise.sh 的退路。** 那條路徑記的 pid 就是元件本身，argv 裡不會有 `$PID_DIR/<name>`，需要另外處理。
3. **加一句範圍說明。** argv 帶著該 app 簽名的 app pidfile 不受影響，因為身分比對在時間檢查之前（ndt:4781）。免得接手的人把修改擴大到 app。
4. **後果清單補一條：** `clean`／`down` 不再把這個檔當 subject。
5. **kernel 行為的前提要實測。** 「starttime 以 boottime 計、suspend 前後 btime 不變」是推論。建議接手的人在這台機器上用唯讀方式驗證：resume 前後、NTP 校時前後各讀一次 `/proc/stat` 的 btime。

## 其他發現（不擋合併）

- **serve 轉告要照表改。** SUMMARY §2 寫「舊行號在新檔裡全都不含 needle」，但它自己的 serve_evidence log:30 顯示，舊的 apps.start rc 1 錨點 ndt:8315 在 head 上正好也是一行 `return 1`（是另一個函式裡的敘述）。serve 的 `test_code_sourced_tables_are_in_ndt` 只檢查該行含不含 needle，所以萬一漏改這個錨點也照樣會綠。轉告 serve 時要照表改，不能靠那支測試抓漏。
- **手冊 :522-523 說 rc 翻成 1「是新規則，不是 lab 壞了」，說過頭了。** 真的回收代表某個有登記的元件已經不在，另一種可能是時鐘往前調造成的誤判（見這張工單）。建議改成「先看 problems 那一行」，並指向工單。
- **這輪沒有重跑其他既有的變異閘門**（robust、honesty、status_check、helper_apps_window、down_claim_guard、up_target、app_package、ovs4_has_sflow）。這輪 ndt 的改動只有兩句訊息和一段 help，anchor checker 117/117，除了 helper 那格以外所有 suite 都綠，風險低。
- **merge-tree 只對 serve 分支做過，沒對現在的 trunk 做。** trunk 已經動過（helper 在 f139c800 改了）。主 checkout 的 ndt 仍是 base 的版面（P4 內嵌拒絕在 :3059、`pid_registry_entries` 在 :4521、`cmd_status` 在 :6100），所以 ndt 衝突和 serve 行號位移的可能性都低；但合併前跑一次 `git merge-tree` 對 trunk 成本很低。這一點是從 working tree 推論的，不是從 commit 看的。
