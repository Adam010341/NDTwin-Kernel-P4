# W1／#87：install 與 modify 也要讀回再宣稱

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W1（工單代號 **W-GROUP-INSTALL-MODIFY**，
`doc/audit/2026-09-03_night-rounds/WORK-ITEMS.md:133`）。Adam 09-04 裁：測完開工單（N22 Q3 (a)），含 API 文件。
修的人：夜巡「修法 agent」session，worktree `wt-integrate`。日期：2026-09-04。

[Co-developed with claude code -- Adam]

---

## 1. 一句話結論，與**兩側要分開讀**

`guardedMod` 的**前置**檢查與**後置**讀回是兩件事。finding #1 只把後置讀回接到 Delete；
Add／Modify 走到 `switch (op)` 就把 Ryu 的 200 直接翻譯成 `installed`／`modified`——
而 Ryu 對 group/meter mod **不下 barrier、不等交換機回覆**，交換機的拒絕是非同步回來、對不上請求。
修法把讀回抬成**三個動詞共用、期待值不同**：delete 期待 `Absent`，Add／Modify 期待 `Present`。

🔴 **這張單修的不是 404 那一側。** auditor 今晚在 OVS 上量到「modify 一個不存在的 group 回 404
`nothing was modified`」——那是 `guardedMod` 的**前置**檢查給的，**本來就對了，沒有動它**。
這張單修的是另一側：**前置檢查通過、`post()` 回 200、而交換機其實拒絕了**。
把兩側混讀，會以為 404 那條也被改過。

## 2. 座標（🟢 自己開檔核對過）

| 位置 | 內容 |
|---|---|
| `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:546` | `guardedMod` |
| 同上 `:563-584` | 前置檢查：Add 撞 `Present` 回 409、非 Add 撞 `Absent` 回 404（**沒有動**） |
| 同上 `:616-619` | `before == Unknown` ⇒ 直接 `unverified`（**沒有動**；讀不到就不宣稱） |
| 同上（修法前）`:636-682` | delete 專用的讀回；`switch (op)` 的 Add/Modify **沒有任何讀回** |
| `include/…/HttpRoutingStrategyBase.hpp:110-115`／`:117-118` | `enum class Existence`／`entryExists`（**virtual**，測試接縫） |
| 同上 `:146`／`:149`／`:152` | `pauseBeforeReVerify()`／`VERIFY_ATTEMPTS = 3`／`VERIFY_PAUSE_MS = 100` |
| `include/…/OpResult.hpp:87-92`／`:99-102` | `withOutcome`／`failure` |
| `src/ndt_core/http/HttpSession.cpp`（`respondToOpResult`） | 502 走 400..599 passthrough，`outcome` 附在 body |

## 3. 修法與狀態碼形狀

| 動詞 | 讀回 = 期待 | 讀回 ≠ 期待 | 讀不回來 |
|---|---|---|---|
| Add | 200 `installed` | **502 `absent`** | 200 `unverified` |
| Modify | 200 `modified` | **502 `absent`** | 200 `unverified` |
| Delete（既有） | 200 `deleted` | 502 `still_present` | 200 `unverified` |

`Unknown` 的處理**先於**不匹配的處理：讀不回來不是失敗的證據，
把它翻成 502 等於把「kernel 構不到」發表成「交換機拒絕了」。

### 🔴 Modify 的鑑別力比另外兩個弱——這件事寫進 API 文件了

`entryExists` 只答「這個 id 在不在」（比對 `/stats/groupdesc` 的 `group_id`），
**答不出 buckets 有沒有換成新的**。所以 modify 的 `Present` 只證明「entry 還在」，
不證明「改成了你要的樣子」。
⇒ outcome 維持 `"modified"`（不是 `modified_verified`），
並在 `doc/2026-01-02_ndt_api.md` 的 outcome 表底下明寫這條但書。
**閘門的 M7 就是釘這件事的**：它把 outcome 改成 `"modified_verified"`——碼不會壞、
看起來還更明確，但那個宣稱是假的。M7 若 survive，這組測試釘住的只是「有讀回」，
而不是「宣稱的強度對得上讀回的強度」。

## 4. 看紅（逐字）

**RED**：把 `HttpRoutingStrategyBase.cpp` 換回 HEAD 的版本（新測試留著）、重建、跑：

```
[ RUN      ] GroupMeterFixture.AGroupTheSwitchNeverTookIsNotReportedAsInstalled
tests/test_GroupMeterExistence.cpp:993: Failure
Value of: r.ok
  Actual: true
Expected: false
a group the switch never took was reported as installed: 
tests/test_GroupMeterExistence.cpp:994: Failure
Expected equality of these values:
  r.outcome
    Which is: "installed"
  "absent"
[  FAILED  ] GroupMeterFixture.AGroupTheSwitchNeverTookIsNotReportedAsInstalled (0 ms)

[ RUN      ] GroupMeterFixture.AnInstallReadBackHappensAfterThePostNotBeforeIt
tests/test_GroupMeterExistence.cpp:1074: Failure
Expected: (static_cast<int>(ryu.commands.size())) > (post + 1), actual: 2 vs 2
nothing was asked of the switch after the install was forwarded
[  FAILED  ] GroupMeterFixture.AnInstallReadBackHappensAfterThePostNotBeforeIt (0 ms)
```

`r.outcome Which is: "installed"` 就是缺陷本身：**交換機從頭到尾沒被問過**，
而 `commands.size() == 2`（一次前置 GET、一次 POST）證明第二次讀根本沒發生。

⚠️ **同一輪裡 `AModifyIsNotClaimedVerifiedWhenOnlyExistenceWasChecked` 在未修的碼上是綠的**，
那是對的：它守的不是缺陷，是**措辭不可以超過證據**，未修的碼也回 `"modified"`。
它的紅只有閘門的 M7 造得出來——**這就是為什麼它必須有一個對應的變異**。

**GREEN**：修回去 ⇒ `GroupMeterFixture.*:GroupMeterEndpointTest.*` 44 支全綠；
整顆 binary **1063 tests, all passed**。

## 5. 🔴 我改了三支既有測試的 fake（不是改期望值，是改 fake 的完整度）

| 測試 | 改了什麼 |
|---|---|
| `AddingAGroupThatIsNotThereGoesThrough` | 加 `getReplyAfterPost = groupDescReply(1, {5, 9})` |
| `TheMeterAcceptPathsGoThrough`（install 那一段） | 加 `getReplyAfterPost = meterConfigReply(1, {3})` |
| `AGroupIdCanBeInstalledAgainAfterAVerifiedDelete`（re-install 那一段） | 加 `getReplyAfterPost = groupDescReply(1, {9})` |

**斷言一個字都沒改**（仍然是 `ok`／`"installed"`／請求有發出去）。改的是那個假交換機：
#87 之前 install 是拿 Ryu 的 200 宣告的，所以一個「表在 mod 前後一模一樣」的 fake
足以表示「install 成功了」。**現在不足夠了——而且它本來就不是一台接受了請求的交換機**，
它是一台表沒有變的交換機，正是 #87 要拒絕的那個狀態。
⚠️ 這一段照 `02-recurring-mistakes` 的「乾淨的版本是要回頭查的那個」留紀錄：
**測試改動要能被回頭查**，即使改的是 fixture 而不是斷言。

## 6. 測試（進既有的 `tests/test_GroupMeterExistence.cpp`，不開新檔）

接縫沿用既有的 `ScriptedRyu`：override `executeArgv`（不是 `post()`，它不是 virtual）、
`pauseBeforeReVerify()` 計次不 sleep、`getReplyAfterPost` 當「mod 之後 stats 怎麼答」的旋鈕。

| 測試 | 斷言 |
|---|---|
| `AGroupTheSwitchNeverTookIsNotReportedAsInstalled` | `!ok`、`outcome=="absent"`、message 含 "did NOT take it" |
| `AMeterTheSwitchNeverTookIsNotReportedAsInstalled` | 同型，meter |
| `AGroupTheSwitchDidTakeIsReportedAsInstalled` | 對照：交換機真的收了 ⇒ `ok`、`"installed"` |
| `AModifyThatCannotBeReadBackIsUnverifiedRatherThanFailed` | 讀不回來 ⇒ `ok`、`"unverified"`、2xx |
| `TheInstallReadBackIsRetriedAndBounded` | 沒收 ⇒ `pauses > 0` 且 `<= 8`；收了 ⇒ `pauses == 0`（成功路徑不付延遲） |
| `AnInstallReadBackHappensAfterThePostNotBeforeIt` | 最後一個動作是對 `/stats/groupdesc` 的 GET，且在 POST 之後 |
| `AModifyIsNotClaimedVerifiedWhenOnlyExistenceWasChecked` | 🔴 鑑別力：舊 buckets 仍在 ⇒ 仍回 `modified`，且 outcome／message **沒有** "verified"／"contents" |
| `InstallGroupRelaysA502WhenTheSwitchDidNotTakeIt` | endpoint 層：502 body 帶 `outcome:"absent"`、`controller_status:502` |

🔴 **狀態碼 502 是在 endpoint 層斷言的，不是在 strategy 層**，而且是刻意的：
`mutate_delete_group_entry.sh` 有一個 widening（W2）把 strategy 的 502 換成 503 並要求測試留綠
（它的用意是「測試釘的是行為不是無關細節」）。#87 讓兩個動詞共用同一個
`OpResult::failure(502, what)`，strategy 層若斷言 502 會把那個 widening 弄紅、
**害鄰居的閘門失去它的對照組**。endpoint 測試自己造 `OpResult`，所以釘得住 API 文件寫的 502
而不動到它。

## 7. 閘門

新增 `tests/shell/mutate_group_install_modify_readback.sh`（只 mutate `.cpp`，理由照抄
`mutate_delete_group_entry.sh` 檔頭：header 有 `VERIFY_ATTEMPTS`，動它＝全樹重編）。
log：`scratch/overnight-2026-09-04/fix/W1-gate.log`。

```
10 mutations, 0 survived
baseline restored: … byte-identical to the pre-run snapshot
  ok       green again from the restored source
```

7 變異（M1 缺陷本身、M2 期待值反轉、M3 Unknown 變失敗、M4 只讀一次、M5 迴圈條件反、
M6 用 post 之前的讀當判準、**M7 過度宣稱**）＋3 對照（C1 三元式改寫、C2 `>0`↔`>=1`、C3 訊息改寫）。

### 🔴 鄰居閘門的 anchor：我重新指了 8 個

`mutate_delete_group_entry.sh` 的讀回區塊被我整段重寫（少了四層縮排、`Present/Absent` 變成
`expected`），所以它的 M1／M2／M4／M5／W1／W2／W3／W4 **anchor 全部失效**。
照工單的規矩：**指到新文字、判定不變、在註解裡更正理由，一個變異都沒有刪。**

| 變異 | 舊 anchor | 新 anchor |
|---|---|---|
| M1 | `        if (after == Existence::Present)\n        {` | `    if (after != expected)\n    {`（delete 的 `expected` 就是 Absent） |
| M2 | `        if (after == Existence::Present)` → `!= Absent` | `    if (after == Existence::Unknown)\n    {` → `if (false)`（同一個缺陷的另一面） |
| M4／W1 | 8 空格的 `for (…VERIFY_ATTEMPTS…)` | 4 空格 |
| M5 | `if (after != Existence::Present)` | `if (after == expected \|\| after == Existence::Unknown)` |
| W2 | `OpResult::failure(502, named + " is still…"` | `auto failed = OpResult::failure(502, what)…` |
| W3 | 兩行的失敗句 | 三元式裡的 delete 那一支 |
| W4 | 12 空格的 `if (attempt > 0)` | 8 空格 |

⚠️ **我沒有重跑 `mutate_delete_group_entry.sh` 整輪**（那是 12 次以上的重建）。
我做的是：`check_gate_anchors.py` 靜態確認每個 anchor 在新原始碼裡剛好命中一次，
＋整顆 binary 1063 支全綠。**「anchor 指得到」不等於「那個變異仍然會被抓到」**——
下一個有 build 預算的人應該把那一輪跑完，這是這張單最大的未完項。

## 8. 可達性口徑

🟠 **產線走得到，但這一側今晚沒有量到。**
`FINDINGS-ALL.md:136` 原文：「install 被拒的實例**沒有量到**；auditor 未親驗」。
⇒ 同型推論成立（同一支函式、同一個 Ryu 行為、**delete 側已在 ovs4 實測**：
09-03 五次 delete、五個 200 `deleted`、五個 group 還在、log 零行），
但 **install／modify 被交換機拒絕的實例本身沒有被觀測到**。
本修法的證據是 gtest 的假交換機，**不是 live**。
🔴 **不可以寫成「已在 OVS 上重現」。**

## 9. 沒修的同型

- **比對 buckets／bands**：modify 的讀回只確認存在。要更強的宣稱得比對內容，那是另一張單
  （fixplan 附錄第 4 題正是問這個）。
- **`entryExists` 對 `"ALL"` 這種非數字 id 回 Unknown**，於是那類請求永遠是 `unverified`。
  行為沒變，也沒有新測試。
- **`mutate_f13_group_meter_existence.sh`（前置檢查那支）我沒有動也沒有重跑**；
  它的 anchor 在 `:277`／`:331-332` 一帶，不在我重寫的區塊裡。

## 10. 給 Adam 的一格

modify 的讀回只能確認「entry 還在」、確認不了「內容換了」。
維持 `"modified"` 的措辭（＋API 文件但書，本輪的做法），還是另開一張「比對 buckets」的單？
