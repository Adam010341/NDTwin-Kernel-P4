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

## 3. 「沒有交換機」那一支沒有改，而且是刻意的

`validateDataPlaneHomogeneity` 對「一台交換機都沒有」也回 false（並印 error）。
這一單**只讓「一種以上平面」擋下**（`groups.size() > 1`），沒有讓 switch-less 檔案被拒。
理由：那是另一條政策（一份只有 host 的拓樸該不該載入），
而 `test_SwitchKindDispatch.cpp` 的 `EmptyTopologyFailsValidation` 正是拿空檔案在測那個函式。
閘門用一顆變異體（M31：`> 1` 寫成 `!= 1`）＋一支對照測試
（`ASwitchlessTopologyIsNotWhatThisRefuses`）把這條界線釘住，
另加一顆對照 widening（W8：`> 1` 寫成 `>= 2` 必須維持綠），
證明 M31 量的是「拒絕哪些拓樸」而不是「這個條件怎麼拼」。

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

- 🟢 **自己跑過**：紅綠（`07-redgreen-bug17.log`）、閘門（`08-gate-ctest-bug17.log`）、`ctest`、
  十三份出貨拓樸的平面盤點（每一份都是單一 kind，所以這扇門對出貨檔零影響——腳本與結果在 SUMMARY §5）。
- 🔵 **讀過未執行**：R6 2026-09-05 的 live 重現（引用 `run-06-opus/BUGS.md`，**沒有重跑**）；
  網站 repo 那兩行是**開檔讀過**（`git log` 也讀過），沒有改、沒有建。
