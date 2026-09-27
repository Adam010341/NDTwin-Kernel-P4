判決：**MERGE AFTER FIXES**（`fix/sudo-probe-unknown-0927` @ `103f94f0`）

依裁定來看，rc 對應的程式邏輯我讀不出錯，改動也只動三個檔（diff 只改這三個檔，ndt 本身沒動，所以 7746832e 的行號在 HEAD 上一樣有效）。要修的兩項都只是補測試，程式碼不用改。

**路徑縮寫**
- SS＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-sudo-probe-unknown-0927/tools/test_workflow/sudo_surface.sh
- T＝…/wt-sudo-probe-unknown-0927/tests/shell/test_ndt_sudo_surface.sh
- M＝…/wt-sudo-probe-unknown-0927/tests/shell/mutate_ndt_sudo_surface.sh
- NDT＝…/wt-sudo-probe-unknown-0927/tools/test_workflow/ndt
- G＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- SUM＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/SUDO-PROBE-UNKNOWN-SUMMARY.md
- RES＝/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/SUDO-PROBE-UNKNOWN.merge-with-queued-notes/

---

## BLOCKING（要補的只是測試）

**B1｜新增的 SS:217 `NDT_SUDO_UNREAD=""` 沒有任何測試，也沒有 mutant。**
- 它的作用：SS:218-221 那幾個提早 `return 2` 的路徑不會呼叫 unread，而 SS:176 的重設只在 unread 函式裡面才跑。所以多列報告能不能正確，全靠 SS:217。【讀】
- 拿掉它會怎樣：`ndt status` 的某一列若因為程式沒裝（`command -v` 失敗）而回 2，這一列會引用前一列 sudo 說的話，而不是印「not installed」。【推】
- 為什麼現有測試抓不到：T:295-298 的 `report_of` 把表縮成只剩 ovs-vsctl 一列。【讀】
- 要補：一個兩列的報告案例，加一個刪掉 SS:217 的 mutant。

**B2｜16 條新 check 裡有 6 條，交付的所有 log 裡都沒看過它紅。專案規則是「測試沒看過紅就不算交付」。**
- 這 6 條：
  - T:255-258（injection）
  - T:260-261（已知拒絕⇒1）
  - T:277-278（probe 成功⇒0）
  - T:279-280（無聲拒絕⇒0，已知限制的釘子）
  - T:290-291（警告＋已知拒絕⇒1）
  - T:302-303（report 已知拒絕 rc 1）
- 為什麼說沒看過紅：
  - R1 裡它們在 base 上是綠的（G/redfirst_probe.probe3-103f94f0.log:41）。
  - R2 不碰它們。
  - mutate 閘門只列出每個 mutant 指名的那一條 check（M:40-45），S1–S7、M、N 都沒有點到這 6 條。【讀】
- M2/M5/M6 很可能已經把 T:260、T:290、T:302 打紅，但 log 裡看不到。【推】
- 要補的 mutant：
  - 把 SS:224 和 SS:225 對調順序 → 應打紅 T:260、T:290、T:302
  - SS:223 的 `&& return 0` 改成 `&& return 2` → 應打紅 T:277
  - 「stderr 為空也回 2」→ 應打紅 T:279

注意：裁定的核心分支都看過紅了。requiretty、PAM、secure_path、nolab、警告＋未知、report 這幾條在 R1 看過；沒有 sudo: 行⇒0 在 S2 看過；兩個警告案例在 R2 和 S4/S5 看過。

---

## 逐題

**1. rc 對應（HEAD）** 【讀】SS:145-155、SS:174-188、SS:215-228

| 情況 | 結果 | 測過了嗎 |
|---|---|---|
| 多行 stderr | refused 掃整段 stderr，所以已知拒絕永遠贏；否則取第一條不在警告清單裡的 `sudo:` 行 ⇒ 2 | 只測了兩行的情況（T:287-291） |
| 警告在前、已知拒絕在後 | 1 | T:290（從未見紅） |
| 警告在前、未知拒絕在後 | 2 | T:287；R1、R2、S6 都見紅 |
| 非英語 sudo | SS:130 把 LC_ALL=C LANGUAGE=C 釘住，sudo 自己的字句應該是英文【推】。萬一漏網：以 `sudo:` 開頭的在地化拒絕 ⇒ 2（安全方向）；在地化警告＋程式自身失敗 ⇒ 誤判成 2 | 未測 |
| 指令自己的 stderr 以 `sudo:` 開頭 | 2，符合裁定，本來就無法區分。三支 probe 自己不會印 `sudo:`【推】（ndtwin-lab:315 的 die 前綴是 `ndtwin-lab:`；ndtwin-lab:1825-1831 的 status 分支） | 未測 |
| stderr 為空 | 0（已知限制） | T:279（從未見紅） |

**2. 呼叫端**（ndt 在這個分支沒改，行號與 7746832e 相同）【讀】

| 呼叫端 | 用到什麼 | 新的 2 造成什麼 |
|---|---|---|
| ovs_sample_rate（NDT:2177-2191） | 只用 capture | 無影響 |
| ovs_bridge_count（NDT:5999-6005） | 只用 capture | 無影響 |
| live_dataplane_kind（NDT:674-681）→ NDT:6498 | 間接 | 在 shim 下，NDT:6498 說「ovs-vsctl refused; see the sudo grants block」，以前那個 block 卻寫 all 3 granted（自相矛盾），現在兩邊一致。這是改善 |
| guard_no_live_ovs（NDT:6027-6049） | ndt_sudo_probe | probe 只決定措辭，rc 永遠是 1（NDT:6040），不會多拒絕任何事。新的 2 走「the reason is sudo, not OVS」加上 NOPASSWD 那行（NDT:6034-6038），但不引用 NDT_SUDO_UNREAD。遇到 secure_path、PAM、requiretty 時，印出的修法是錯的。以前印「permitted but did not answer」，比現在更錯。SUM:27 已承認 |
| dataplane_ok（NDT:6090-6105） | ndt_sudo_refused | requiretty 現在被當成拒絕，所以理由變成「sudo refused mnexec」，而且 verify_dataplane 會印 NOPASSWD 修法（NDT:6116-6117、6146-6147）。NOPASSWD 修不好 requiretty，這一點 SUM 沒提 |
| sflow_why（NDT:6237-6243） | ndt_sudo_refused | 只有 requiretty 的措辭改變 |
| cmd_status（NDT:6938-6947） | ndt_sudo_report | 回 2 時印黃字加一條 problem：plain `ndt status` 的 rc 永遠是 0（NDT:7074）；`--check` 則從 0 變 1（沒有基線時是 3）（NDT:7050-7072） |

- **唯一會「以前能跑、現在變紅」的地方**是 `ndt status --check`：
  - 在閘門的 nolab shim 下，三列全部變成 2。因為 shim 的 sudo 對所有指令都拒絕並印 `sudo:` 行（G/scripts-probe3-103f94f0/shims/sudo:3-4）；shim 本身提供 mnexec 和 ovs-vsctl，所以 `command -v` 會過；lab 那列用的 /usr/local/sbin/ndtwin-lab 在這台機器上存在【推】。
  - 沒有任何 tests/shell suite 斷言這一點（sweep 的結果）。
  - 有一支歷史 harness 會翻：G/scripts-pstub3-f9c59a44/redfirst_stubfix.sh:40-43 斷言 shim 的字句讀成 GRANTED，在合併後的 code 上重跑會變 BAD。這是預期中的，建議記錄下來。
- **Adam 的機器**：授權都在，probe 會成功，所以不變【推】。
- **CI**：ci.yml:32-39 沒裝 OVS 也沒裝 mininet，三列本來就是 2，所以不變【推】。
- verbs.py:204-215 對 rc 1 的說明沒列出「could not be tested」；這是舊問題，現在比較容易遇到。

**3. Red first**
- **R1 的 6 條**：在 base 上的實際值都是 `rc=0` 或 `granted`，紅的原因是對的（G/redfirst_probe.probe3-103f94f0.log:14-28）。
- **R2**：拿掉哪一項，就恰好紅以那個警告為前提的案例，沒有別的（log:44-52；…kept/r2_unable to resolve host.out:44-53）。
  - 預期集合是 probe1 看過結果之後才改的（G/redfirst_probe.probe1-103f94f0.log:45-49）。這點 SUM 有揭露，而且改得有道理：三條案例都把 W_HOST 送進 ndt_sudo_unread。
- **S1–S7**：每一個都殺在指名的 check 上（G/mutate_ndt_sudo_surface.probe3-103f94f0.log:22-28）。report() 同時要求 rc≠0 和指名那條出現 FAILED（M:40）。「殺的原因」是從 mutant 的寫法推出來的【推】。
- **從未見紅的部分**：見 B1、B2。

**4. Sweep**
- **方法**：兩棵 `git archive` 樹，正規化 check 行後逐行比，有差的再各重跑一次。在它的範圍內方法是對的（sweep_probe.sh:15-48）。
- **它看不到的**：
  - 只涵蓋 tests/shell/test_*.sh。其他 mutate_*.sh、tests/python、live cell、歷史 harness 都沒跑。
  - 只比對符合 regex 的行（sweep_probe.sh:16）。
  - 分類成 FLAKY 時不會比較 base2 和 head2，所以「flake 裡夾著一個真的翻轉」會被標成 FLAKY（sweep_probe.sh:40-47）。
    - 我直接讀了保留下來的原始輸出，排除了這種情況：base2 和 head2 都是 131/0（…kept/{base2,head2}-test_apps_residue.out:164），而且 probe1 在兩棵樹上紅的是同樣兩條（G/sweep_probe.probe1-103f94f0.log:15；probe1 的 kept 輸出 :82-86）。
- **兩棵樹都紅的 4 支**：對本改動來說可以接受。這 4 支都不引用 ndt_sudo_* 或 sudo_surface；test_live_p1_common 用的是它自己的 sudo stub（:77、:194）。
  - 但紅的原因只是推論（SUM:118）。「log_suffix 在 worktree 裡是 30/0」引用的是另一個交付（queued3）的 log，不在本交付裡。

**5. 合併 bbb9fd41 的解法**
- **程式碼**：resolved 檔去掉註解後與本分支逐字相同（resolved:100-277 對照 SS:85-257，我逐函式比對過）【讀】。
- **過時的註解**：bbb9fd41 的 sudo_surface.sh 有四處過時，resolution 都改寫了（bbb9fd41-to-resolved.diff:3-35、105-114）。四處是：
  - 「any other means granted (0)」
  - 「is reported as a live grant」
  - ndt_sudo_refused 前面那段註解
  - 衝突那一段
  - 比對來源是 wt-queued-notes-0927 目前的檔案（:66-73、150-154、196-197）；我沒用 git，無法確認它就等於 bbb9fd41。
- **沒修到的**：
  - resolved:132-133 說 probe 從 stderr 取「granted / refused」的判定，漏了 could not tell（小事）。
  - lib_probe_stub.sh:24、37、65 引用 sudo_surface.sh:179-182、176-177，還寫「five wordings」（現在是六種）；合併後行號全錯。這屬於延後處理的 Q-N2，但 SUM 沒列出內容。
- **其他**：
  - 合併後的檔案還沒跑過任何閘門。
  - 「merge-tree 有 1 個衝突」沒有保留原始輸出。

**6. 數字對帳**
- 各數字都和 log 對得上：
  - 49/0：test log:65。我數了 ok 行：7＋5＋8＋9＋16＋4＝49；33＋16＝49。
  - 21/0：mutate log:35。M1–M10 十個，S1–S7 七個，N1–N4 四個。
  - anchors 的 `ok(19)`（check_gate_anchors log:96）：21 個 mutant 減掉兩組共用的 anchor——M1/N1 共用 M:85/197，S4/S5 共用 M:172/177。
  - 121/121：anchors log:136，121 列。
  - 96/0：l1 log:120。
  - 10/0：P1–P9 加 T1。
  - tripwire 0：nolab log:20-21，全檔 0 行。
  - 368/0：tmpdirs log:9。
  - 63 支 suite＝61 same＋1 FLIP＋1 FLAKY（我逐行數過）。
- **SUM 內部矛盾**：
  - SUM:7 說「外層一個 guard，每個 gate 巢狀」，SUM:73 卻說「沒有外層 guard」。probe3 的 log 是每格各自拿鎖（G/*.probe3-103f94f0.log:5；gates_probe.sh:20）；SUM:7 描述的其實是 probe1（G/sweep_probe.probe1-103f94f0.log:5、9）。
  - SUM:114 列出 test_apps_residue 紅的兩條，第二條「no match for 'installed 0s ago'」其實是第一條的失敗細節。真正第二條紅的 check 是「and it is counted as dated」（sweep log:15-16）。

**7. 接觸 lab**
- 沒找到任何會碰到 lab 的路徑：
  - T 的假 sudo 放在 PATH 最前面（T:52-62、89-90），ndt 不會重設 PATH。
  - report_of 只探 ovs-vsctl 那一列。
  - R3 用的全是假 sudo，打給 shim 的 5 次呼叫都被拒絕（…kept/r3_nolab_shim_calls.log:1-5）。
  - sweep 裡 suite 自己打給 shim 的呼叫：base 0、head 0（log:101-102）。
  - tripwire 0 行。
  - tests/shell 裡沒有用絕對路徑呼叫 sudo 的。
- 殘餘風險：用絕對路徑呼叫 sudo 的話，tripwire 看不到。

---

## NOTEs
- N1｜警告比對是「整行子字串」（SS:181），沒有錨定在 `sudo: <項目>`。
  - 沒有任何案例能擋住「清單被放寬成 pattern」：例如把 `unable to resolve host` 改成 `unable to`，現有所有案例都會存活。
  - 建議錨定成 `[[ "$line" == "sudo: $w"* ]]`，並加一個致命 `sudo: unable to execute …` 行 ⇒ 2 的案例。
- N2｜SS:51-61、117、137-139 的檔頭（「rc decides … a wrong guess cannot produce a wrong answer」）被本分支自己的 SS:224-225 推翻；bbb9fd41 加上 resolution 已經改好。若本分支比 bbb9fd41 先進 trunk，這段檔頭會繼續是錯的。
- N3｜其他過時的引用：
  - check_test_tmpdirs.py:58 的 `test_ndt_sudo_surface.sh:241`，那一行現在在 :312。
  - M:193 寫「all ten mutations above」，上面現在有 17 個。
  - gates_probe.sh:8-9 還寫 `queued-<sha8>`。
- N4｜sudo-rs 這類實作：若它的前綴不是 `sudo:`（sudo-rs 某些版本可能用 `sudo-rs:`【推，未驗】），未知拒絕仍會讀成 granted。

## 宣稱表

| 宣稱 | 判定 | 證據 |
|---|---|---|
| 只動三個檔（SUM:5） | SUPPORTED | patch 檔頭；sweep log:10-13【讀】 |
| 沒 push、沒 merge（SUM:6） | UNDER-EVIDENCED | 沒有保留 ls-remote 或分支的證據 |
| 沒碰 sudo／lab（SUM:6） | SUPPORTED | tripwire 0；sweep 0/0；R3 只打到 shim【讀】 |
| 實作符合裁定（SUM:13-19） | SUPPORTED | SS:145-228【讀】 |
| R1：base 恰好 6 條紅（SUM:34-44） | SUPPORTED | redfirst log:12-42 |
| 其餘 10 條兩邊都綠（SUM:46） | SUPPORTED | redfirst log:41-42；但其中 6 條至今沒看過紅，見 B2 |
| R2 恰好紅該紅的（SUM:49-54） | SUPPORTED | log:44-52；預期集合是事後修正的 |
| R3 四種 sudo（SUM:59-68） | SUPPORTED | log:54-72；shims/sudo:3 |
| 閘門表的數字（SUM:76-86） | SUPPORTED | 見第 6 題 |
| S1–S7 各殺在指名的 check 上（SUM:88-95） | SUPPORTED | mutate log:22-28；M:40 |
| probe1 只有 R2 BAD、其餘全綠（SUM:98） | SUPPORTED | probe1 各 log 的 rc |
| probe2 一個閘門都沒跑（SUM:99） | SUPPORTED（弱） | gates-0910 裡找不到任何 probe2 產物 |
| 「沒有任何既有 check 行改變」（SUM:109） | SUPPORTED（僅限 test_*.sh） | sweep log:58-76 只有 after 行 |
| 「六支會走到真 ndt_sudo_report」（SUM:111） | UNDER-EVIDENCED | 推論；test_ndt_honesty 自己也 stub 了 report（:174） |
| apps_residue 是 FLAKY 不是翻轉（SUM:113-116） | SUPPORTED | kept 原始輸出；引用的紅行名稱有一條寫錯 |
| 4 支兩樹都紅是環境造成（SUM:117-118） | UNDER-EVIDENCED | 引用了別的交付的 log |
| merge-tree 只有 1 個衝突（SUM:124） | UNDER-EVIDENCED | 沒有原始輸出 |
| resolved 的程式碼與本分支逐字相同（SUM:131） | SUPPORTED | resolved 檔對照 SS【讀】 |
| 三段過時註解已改寫（SUM:127-129） | SUPPORTED | diff:3-35、105-114 |

## 報告沒跑、我會跑的測試（全部【跑】，我沒有執行）
1. B1：兩列的 report（第一列是未知 sudo: 行，第二列 `command -v` 失敗），加刪掉 SS:217 的 mutant。
2. B2 的三個 mutant：SS:224/225 對調順序；SS:223 改 `return 2`；stderr 為空也回 2。
3. 致命的 `sudo: unable to execute /usr/bin/ovs-vsctl: Permission denied` ⇒ 2，加一個把警告放寬成 `unable to` 的 mutant。
4. 在 nolab shim 下用完整三列表跑真正的 `ndt status` 和 `ndt status --check`，base 對 HEAD 比：rc、sudo grants 那一行、problem 清單。
5. 用 nolab shim 的字句和 requiretty 的字句跑 guard_no_live_ovs、verify_dataplane、sflow_why，比對 base 與 HEAD 各自印出什麼。
6. 除了本交付兩支以外，其他所有 mutate_*.sh 在 HEAD 上跑一次；再加 `tools/test_workflow/l1_unit_tests.sh`（含 tests/python）。
7. 兩樹都紅的那 4 支，在帶 .git 的 worktree 裡分別跑 base 和 HEAD。
8. 在真實的 sudo-rs、sudo.ws（Ubuntu 25.10/26.04）上跑 `sudo -n ovs-vsctl list-br`，確認拒絕時的前綴和字句。
9. bbb9fd41 進 trunk、再 merge 回本分支之後，重跑 test、mutate、check_gate_anchors 和 redfirst。