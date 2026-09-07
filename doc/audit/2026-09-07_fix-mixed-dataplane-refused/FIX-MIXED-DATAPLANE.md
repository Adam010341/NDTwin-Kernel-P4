# BUG-17 — 混合資料平面：回傳值真的擋下

[Co-developed with claude code -- Adam]

分支 `fix/bug17-mixed-dataplane-refused`，base＝`fix/w15b-switch-kind-exemption`@`4bc93d00`。
2026-09-07。**沒 push、沒 merge、沒碰 lab、沒動 `setting/`。**

## 1. 缺陷：一個沒有人接的回傳值

`TopologyAndFlowMonitor::validateDataPlaneHomogeneity(bool allowMixed) const` 回 `bool`，
而 `parseStaticTopologyFile()` 的最後一行把它當**陳述句**呼叫：

```cpp
    validateDataPlaneHomogeneity(AppConfig::ALLOW_MIXED_DATAPLANE);
```

所以「拒絕」只存在於那一行 `[error]` 的語氣裡。R6 2026-09-05 實測（run-06 BUG-17）：
把出貨的 P4 10-switch 檔複製一份、改一台的 `brand_name` 成 `OVS`，kernel 印出
`Topology mixes data planes (ovs=[1]; bmv2=[2..10])`，然後 **:8000 開著、用混合模型回答**
（`nodes 14 edges 40`、`switch brands: ['BMv2','OVS']`）。

🔴 **三份文件各說各話，只有最弱的那一份是真的**（R6 的原始發現）——見 KNOWN-ISSUES C-5。

## 2. 修法：判定移到第一個 add_vertex 之前，回傳值真的擋下

1. **判定從圖搬到文件**：`switchKindGroupsFromJson(j)` 用**和 builder 完全相同的規則**
   （有 `switch_kind` 用它，否則 `switchKindFromBrandName(brand_name)`）算出 dpid → kind，
   在 `validateStaticTopologyJson` 的 node 迴圈之後判定。
   ⇒ **被拒絕的檔案留下 `num_vertices == 0`**，與 #61／#89／#90／#91 五扇門同一條紀律。
   （在原地用回傳值 throw 會留下一張蓋好的圖，正是 #61 要廢掉的「拒絕了，順便把大部分給你」。）
2. **`validateDataPlaneHomogeneity` 的回傳值現在真的擋下**：builder 尾端那一呼叫保留為**第二層**，
   回 false 且真的有一種以上平面 ⇒ throw。與 door 3a/3b/3c 的 builder backstop 同一形狀，
   而且同樣**在正常路徑上到不了**（第一層已經擋掉了）。
3. **訊息只有一個地方生成**：`describeSwitchKindGroups()` 從
   `validateDataPlaneHomogeneity` 抽出來，兩邊共用 ⇒ 操作者看到的字彙只有一套。
4. **`ALLOW_MIXED_DATAPLANE` 一個字沒動**，它仍然是支援的 opt-in；
   只是改成經由一個成員讀（`m_allowMixedDataPlane`，建構時取自 `AppConfig`），
   讓測試可以在不重編 `AppConfig.hpp` 的情況下把它打開——
   「開旗標 ⇒ 收下」這條宣稱**沒有測試就等於沒有**。

## 3. 「沒有交換機」那一支：第一顆刻意沒改，**當天被 Adam 裁回來**（見 §6）

`validateDataPlaneHomogeneity` 對「一台交換機都沒有」也回 false（並印 error）。
**第一顆 commit（`ee049958`）只讓「一種以上平面」擋下**（`groups.size() > 1`），沒有讓
switch-less 檔案被拒；理由是「那是另一條政策，沒有人裁過」，而 `test_SwitchKindDispatch.cpp` 的
`EmptyTopologyFailsValidation` 正是拿空檔案在測那個函式。當時的閘門用一顆變異體
（M31：`> 1` 寫成 `!= 1`）＋一支對照測試（`ASwitchlessTopologyIsNotWhatThisRefuses`）
把這條界線釘住，另加一顆對照 widening（W8：`> 1` 寫成 `>= 2` 必須維持綠）。

🔴 **2026-09-07 當天，Adam 裁了那條政策，而且與建議相反：零交換機**也**要拒**（E-26）。
所以本節描述的是「一天之內成立過的狀態」，不是現在的行為——現在的行為在 §6。
**W8 沒有動**；**M31 反過來了**，對照測試連名字一起翻。

## 3b. 🔴 第一輪閘門抓到兩顆存活，而兩顆都是「新的門把舊的門遮住了」

`08-gate-ctest-bug17.log`：`31 mutations, 2 survived`。**整個套件 1109/1109 全綠**——
沒有任何測試在說話，是閘門在說話。

```
=== M10. door 3a: a malformed switch_kind is refused by the builder again, not by the validator ===
  🔴 SURVIVED -- these stayed green: TopologyInputValidationTest.AMalformedSwitchKindLeavesNoPartiallyLoadedGraph
=== M21. door 3e: an unknown brand_name is accepted again ===
  🔴 SURVIVED -- these stayed green: TopologyInputValidationTest.AnUnknownBrandNameLeavesNoPartiallyLoadedGraph
```

**兩顆的成因不同，修法也不同：**

**M10 ——「我的儀器變成了被測物」。** `switchKindGroupsFromJson` 第一版照抄 builder 的寫法
（`contains("switch_kind") ? switchKindFromString(...) : ...`），
而 `switchKindFromString` 對畸形的值會 throw ⇒ **它變成了第二扇 door 3a**，
坐在 node 迴圈之後。M10 把 door 3a 的拒絕推回 builder（要證明「拒絕的是門，不是 builder」），
結果我的新函式先拒了，測試照樣綠。
**修法：讓它不會 throw**——改用 `declaresLegalSwitchKind`（有合法的就用，否則退回 brand 對映）。
未變異的碼行為完全相同（door 3a 已經保證合法），但 door 3a 重新成為唯一拒絕畸形
`switch_kind` 的地方。

**M21 ——「同一份壞檔現在有兩個毛病」。** R0b 的檔案是**一台**交換機掛未知 brand，
而未知 brand 對映成 HARDWARE ⇒ 那份檔案**同時**是混平面。
BUG-17 之後混平面也在第一個 `add_vertex` 之前被拒 ⇒
把 door 3e 關掉不再改變「檔案載不載得進來」，只改變操作者看到哪一句話。
**修法：新增 `AFabricEntirelyOfAnUnknownBrandIsStillRefused`**——
**整片** fabric 都是未知 brand（十台全部對映成 HARDWARE ⇒ 沒有混平面），
door 3e 是唯一能拒它的東西；M21 改用它計分。
原本那兩支訊息測試留著，它們現在的角色是**釘住是哪一扇門拒的**
（混平面那句話既沒有指名 brand，也確實會建議 `ALLOW_MIXED_DATAPLANE`）。

🔴 **兩顆都不是「閘門太嚴」。** 一顆是我新增的碼悄悄接管了別人的職責，
一顆是舊測試的鑑別力被新行為吃掉。**沒有放寬任何一顆變異體。**

## 4. 四份文件（其中一份不在這個 repo 裡）

| 文件 | 原本說什麼 | 這一單怎麼處理 |
|---|---|---|
| `doc/2026-07-29_p4_status_and_test_guide.md:76` | 「會直接 fatal」 | 這一單**讓它變成真的**，並補上「2026-09-07 以前這一格是假的」與新的證據欄 |
| `doc/2026-01-02_ndt_api.md` §38 | 只寫了打錯的 brand 那一半 | 加一段「Changed 2026-09-07 (BUG-17)」講**真的**混平面 |
| `setting/AppConfig.hpp:12-15` 的註解 | 「the kernel refuses to load a mixed topology」 | **一個字沒改**——它本來是假的，現在是真的 |
| 網站 `NDTwin-Website` `content/en/docs/architecture.md:89-93` | 2026-09-06 已被更正成描述**舊行為**（「loads the topology anyway ... discards its result」） | 🔴 **另一個 repo，這一單沒有動它**。它會因為這一單而反過來變假；替換文字寫在 `R2-BUG17-SUMMARY.md` §6 |

## 5. 自己跑過 vs 讀過未執行

- 🟢 **自己跑過**：紅綠（`07-redgreen-bug17.log`）、閘門兩輪
  （`08-gate-ctest-bug17.log` ＝ **2 survived**、`09-gate-ctest-bug17-2.log` ＝
  `31 mutations, 0 survived`／`8 widenings, 0 wrongly caught`／`GATE EXIT rc=0`）、`ctest`
  （`100% tests passed ... out of 1110`）、
  十三份出貨拓樸的平面盤點（每一份都是單一 kind，所以這扇門對出貨檔零影響——腳本與結果在 SUMMARY §5）。
- 🔵 **讀過未執行**：R6 2026-09-05 的 live 重現（引用 `run-06-opus/BUGS.md`，**沒有重跑**）；
  網站 repo 那兩行是**開檔讀過**（`git log` 也讀過），沒有改、沒有建。

---

## 6. 補一顆（2026-09-07，E-26）：零交換機拓樸也拒

[Co-developed with claude code -- Adam]

**這一節推翻 §3。** §3 留著沒刪，因為它是一天之內成立過的狀態，而且它記著「當時為什麼那樣決定」；
讀的人要知道**哪一半還算數**：`> 1` 的界線論證作廢，W8 那顆對照 widening 的角色沒變。

### 6.1 裁決

`scratch/overnight-2026-09-05/DECISIONS.md:266`（grill §4E 第七輪），逐字：

> **E-26 零交換機拓撲：拒，在 BUG17 分支補一顆**（⚠️ 與建議相反：建議是不拒另開單）。

建議在 `R2-BUG17-SUMMARY.md` §7 第 3 題與本文件 §3。**Adam 裁的是相反方向**，所以這一顆同時要做兩件事：
改行為，以及把「當時為什麼相信另一邊」留在原地不塗掉。

### 6.2 修法（機制一句話＋檔:行）

1. **`validateStaticTopologyJson`**（`TopologyAndFlowMonitor.cpp`，node 迴圈之後、edge 迴圈之前）：
   `switchKindGroupsFromJson(j)` 的結果提到兩扇門之前算一次，然後
   **`declaredKinds.empty()` ⇒ throw**（新的門），接著才是 BUG-17 的 `!allowMixed && size() > 1`。
   ⇒ 被拒的檔案 `num_vertices == 0`，與 #61／#89／#90／#91／BUG-17 同一條紀律。
2. 🔴 **新的門不在 `!allowMixed` 裡面。** `ALLOW_MIXED_DATAPLANE` 是「同時跑兩種平面」的 opt-in，
   它沒有說「一種都不跑也行」；寫成 `!allowMixed && declaredKinds.empty()` 會編、會過其他每一支測試，
   而且會讓開了旗標的 build 靜靜回到 09-06 的行為。**M32 就是那顆變異體。**
3. **builder 尾端的第二層由 `> 1` 改成 `!= 1`**：`validateDataPlaneHomogeneity` 對「零」與「多」
   都回 false，而現在兩者都是拒絕 ⇒ 第二層一起守，訊息按 `builtKinds.empty()` 分兩句。
   （開了旗標的混平面到不了這裡：那時函式回 true。）
4. **訊息**：`declares no switch node` ＋ `Refusing the file rather than starting on it` ＋
   「2026-09-07 以前這是印完就算了」的那一句；檔名由 `loadStaticTopologyFromFile` 的 rethrow 冠在前面。
5. **`validateDataPlaneHomogeneity` 的 `groups.empty()` 分支一個字沒改**——那句
   `Topology contains no switches; nothing can be controlled` 從寫下來就是對的，缺的是有人接它。

### 6.3 測試怎麼翻

| 位置 | 09-06 | 09-07（E-26 之後） |
|---|---|---|
| `test_TopologyInputValidation.cpp` | `ASwitchlessTopologyIsNotWhatThisRefuses`：`EXPECT_FALSE(out.threw)`、`vertices == 4` | **`ASwitchlessTopologyIsRefusedAtLoad`**：`EXPECT_TRUE(out.threw)`、`vertices == 0`、`edges == 0` |
| 同上（新增） | — | **`TheSwitchlessRefusalNamesTheFileAndWhatIsMissing`**：訊息含檔名／`declares no switch node`／`Refusing` |
| 同上（新增） | — | **`ASwitchlessTopologyIsRefusedEvenWithTheMixedPlaneOptIn`**：`allowMixed=true` 仍拒 |
| `test_SwitchKindDispatch.cpp` | `EmptyTopologyFailsValidation` 用 `load("")` **經由載入器**取得空圖 | 同名、同斷言，改成**直接建一個沒載入過的 monitor**——載入器現在會拒那個檔，再那樣寫就是丟例外而不是斷言 |
| 同上（新增） | — | **`AnEmptyTopologyFileIsRefusedAtLoad`**：載入那一半，訊息含 `declares no switch node` |
| 閘門 §5f | M31＝`> 1` 寫成 `!= 1`（擴張到零交換機）必須紅 | **M31 反向，而且是 `mutate2`**＝兩層一起拿掉（文件層 `empty() && false` ＋ 第二層 `!= 1` 縮回 `> 1`）必須紅——**那才是 `0f79d44f` 的行為** |
| 閘門 §5f（新增） | — | **M32**＝只拿掉文件層。第二層仍拒，但已經在 builder 尾端、4 個 host 進圖之後 ⇒ 紅在 `vertices == 4`（#61／#89 的「拒絕了，順便把大部分給你」） |
| 閘門 §5f（新增） | — | **M33**＝把新門塞進 `!allowMixed` 後面必須紅 |
| 閘門 §6（新增） | — | **W9**＝`empty()` 寫成 `size() == 0` 必須維持綠（形狀同 W5） |
| 閘門 §6 | W8＝`> 1` 寫成 `>= 2` 維持綠 | **沒有動** |

🔴 **M31 為什麼一定要是 `mutate2`（第一輪閘門教的）**：第一版把 M31 寫成單點
（只關文件層），閘門**照樣抓到**——但抓到的紅是
`out.vertices Which is: 4`，因為**第二層還在拒**。也就是說那顆變異體並不是
「`0f79d44f` 的行為」，把它寫成是就是本檔頭那句「a gate flattering its own subject」。
E-26 和 #61 一樣是兩層的修法 ⇒ restoration 一定是兩點的（M2 的形狀）。
單點那顆有它自己的價值，所以留下來當 **M32**：它證明的是**門的位置**
（在第一個 `add_vertex` 之前），不是門存不存在。

🔴 **對出貨檔零影響，而這一次是數過的**：repo 內 34 份帶 `vertex_type` 的拓樸文件
（13 份 `setting/` 出貨檔＋21 份 audit 快照／複現檔）**每一份至少 1 台交換機**，最少的是
`doc/audit/2026-09-03_night-rounds/round3-restart-concurrency/topo/topo_1sw.json` 的 1 台。
（R2 那一輪只數了平面種類，這一輪多數了 switch 數。）
