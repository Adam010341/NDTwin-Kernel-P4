# TFM 測試的 mutation 驗收（2026-08-10）

外包測試給 DeepSeek 時我立的驗收條件是：**我會實際套用你的 mutation 並比對你的預測；預測錯了比測試
少更嚴重，因為那代表你不知道自己在測什麼。** 這份文件是驗收結果。

- 測試：`tests/test_TopologyAndFlowMonitor_mininet.cpp`，11 個，全部編譯通過、HEAD 上全綠。
- 它自己列的 9 個編譯不確定點（C-1 到 C-9）**全部是虛驚**：第一次編譯零錯誤零警告。
- 它交的 11 個 mutation：**10 個被殺，1 個存活**。
- 預測準確度：**6 個完全精準、3 個點名正確但低估、2 個錯**。

[Co-developed with claude code -- Adam]

---

## 逐條結果

| # | Mutation | 它預測變紅 | 實際變紅 | 判定 |
|---|---|---|---|---|
| M1 | `vp.isEnabled = false` → `true` @203 | AfterLoading…Disabled（並明說「其他全 PASS」） | ＋EnableSwitchAndEdges… | 點名正確，低估 1 |
| M2 | 註解掉 `[vertex].isEnabled = true` @2054 | EnableSwitchAndEdges… | 同 | **精準** |
| M3 | `[v].isEnabled = true` → `false` @2006 | SetVertexEnableOnly… | 同 | **精準** |
| M4 | 拿掉 `dstDpid` 那半個比較 @1280 | FindEdgeBySrcAndDstDpid… | 同 | **精準** |
| M5 | `[e].isUp = false` → `true` @1446 | SetEdgeDown… | 同 | **精準** |
| M6 | 跳過所有碰 dpid 1 的邊 @264 | 5 個 | 7 個 | 點名正確，低估 2 |
| M7 | 不把 dpid 5 放進 `dpidToVertex` @253 | HasExactly10Switches… | 7 個，**不含它** | **錯** |
| M8 | `vp.ip = {}` @200 | EveryHostHasAtLeastOneIpv4 | **全 11 個** | 點名正確，但機制不是它想的 |
| M9 | `if (ep.srcDpid != 0)` → `if (false)` @290 | SwitchToSwitchEdgesCountIsExactly32 | **無** | **存活** |
| M10 | 加 `mp.clear()` @2675 | TouchEdgeFlowAccumulates… | 同 | **精準** |
| M11 | 註解掉 switchKind 索引 @260 | GetSwitchKind… | 同 | **精準** |

---

## M9 存活的原因：等價變異，不是測試太弱

一個 mutation 存活有三種原因，而不是我原本記的兩種（測不到／打不到）。這是第三種：**改了也一樣**。

`if (ep.srcDpid != 0)` 改成 `if (false)` 之後，switch↔switch 的邊不走 dpid 查表，而掉進下一個分支
`else if (!ep.srcIp.empty()) srcVertexOpt = findVertexByIpNoLock(ep.srcIp[0]);`。三個事實讓兩條路
的結果**完全相同**：

```
10/10 switch 節點都有非空 ip（s1 = 192.168.123.11 …）
32/32 switch↔switch 邊都帶 src_ip 與 dst_ip
findVertexByIpNoLock 掃「全部」頂點，不只 host（TopologyAndFlowMonitor.cpp:339-350）
```

所以 IP 分支找到的是同一個 switch 頂點，邊照樣建起來，沒有任何可觀測差異。測試沒有錯，是這個
mutation 沒有意義。

**順手記下的事實**：邊的建立其實不依賴 `src_dpid`／`dst_dpid`——IP 分支就足夠。兩個 shipped 拓撲都
是這樣。目前有 loader 的前置檢查（switch 沒有 ip 就丟例外）擋著，所以這個冗餘不會變成缺陷。

---

## M7 錯在哪：它以為 mutation 拿掉了頂點，其實只拿掉了索引

`auto v = boost::add_vertex(vp, *m_graph);` 在 :251，`if (vp.vertexType == VertexType::SWITCH)`
的索引區塊在 :253 之後。加上 `&& vp.dpid != 5` 只讓 s5 不進 `dpidToVertex`／`m_dpidToSwitchKind`
—— **s5 的頂點還在圖裡，vertexType 還是 SWITCH，dpid 還是 5**。所以
`HasExactly10SwitchesWithDpid1Through10` 數出來還是 10 個，照樣綠。

真正壞掉的是所有碰 dpid 5 的邊（查表查不到 → 被 skip），於是 7 個邊相關的測試變紅。這正是我要的那
種錯誤：**它對自己的斷言在測什麼有誤解**，而不是測試本身有問題。

---

## M8 點名對了，但機制不是它想的那個

`vp.ip = {}` 之後 11 個測試全紅，原因不是每個測試各自的斷言，而是 loader 自己的前置檢查丟例外：

```
C++ exception with description "switch dpid 1 ("s1") has an empty "ip" array; every switch needs
at least one management address, because address lookup reads the first one unconditionally"
thrown in the test body
```

gtest 把測試主體的未捕捉例外算一次 failure，所以 11 個一起紅。**這代表有兩個測試從頭到尾沒有被
「自己的斷言」驗證過**，只是被 fixture／loader 層的守衛連帶染紅：

- `MininetTopologyHasExactly10SwitchesWithDpid1Through10`（只有 M8 殺得動）
- `EveryHostHasAtLeastOneIpv4Address`（只有 M8 殺得動）

我自己補了三個 mutation 把這個洞補完。

| # | Mutation（我加的） | 結果 |
|---|---|---|
| M12 | 在 `add_vertex` 前 `if (SWITCH && dpid == 5) continue;` | 全 11 紅，但是靠 fixture 的 `ASSERT_EQ(n, 138)` 守衛（頂點少一個）。**沒補到** |
| M13 | 在 `add_vertex` 前 `if (HOST) vp.ip = {};` | 3 紅，含目標；loader 的守衛只檢查 switch，所以載入成功、**由 `EveryHostHasAtLeastOneIpv4Address` 自己的斷言殺掉**。✅ |
| M14 | 在 `add_vertex` 前 `if (vp.dpid == 5) vp.vertexType = VertexType::HOST;` | 頂點數維持 138 → 守衛過關 → 目標測試在 **:470、:473、:476 自己的三個斷言**上紅（`expected exactly 10 switches`／`dpid 5 must be present`）。✅ |

M12 的失敗本身有價值：它說明「讓全部測試變紅」的 mutation 幾乎不帶資訊量 —— 撞到共用守衛時，每個測
試的斷言是否有效仍然沒有被證明。要證明一個測試，mutation 必須讓**它的斷言**是唯一的紅點來源。

---

## 結論

11 個測試全部有效：每一個都至少被一個 mutation 從**自己的斷言**殺掉（其中兩個是靠我補的 M13／M14
才證明的）。已落地並提交。

外包的判斷值多少：語意判斷（3 個 SPEC-UNKNOWN，見 `tfm-spec-unknown-adjudication.md`）比它的測試
更有價值 —— 其中一條問出了 `DisableSwitch` intent 被 1 秒 poll 撤销的真缺陷。而它的 mutation 預測
6/11 精準、2/11 錯，正好證明驗收這一半不能外包。
