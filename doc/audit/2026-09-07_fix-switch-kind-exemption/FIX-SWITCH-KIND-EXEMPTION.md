# W15-2／W15-1(b) — `switch_kind` 豁免與合法 brand 清單單一來源

[Co-developed with claude code -- Adam]

分支 `fix/w15b-switch-kind-exemption`，base＝`fix/w15-unknown-brand-rejected`@`8b3ebe49`。
2026-09-07。**沒 push、沒 merge、沒碰 lab、沒動 `setting/`、沒碰主 checkout 與其他 worktree。**

## 0. 這一單為什麼存在：它推翻的是前一單自己提出的問題

`FINDINGS #91`（`doc/audit/2026-09-06_fix-unknown-brand-rejected/FIX-UNKNOWN-BRAND.md`）
把未知的 `brand_name` 一律拒絕，並在自己的 §5／§7 寫下代價與問題：

> 拿一台這個 codebase 沒有電源路徑的交換機（例如 Cisco）的人，**必須改一行 C++ 才能載入拓樸**。

Adam 2026-09-06 grill §4D 第三輪裁決（`scratch/overnight-2026-09-05/DECISIONS.md`）：

> **W15-2 未知 brand 的代價**：**有明確 `switch_kind` 就豁免**（⚠️ 與建議相反 ⇒ W15 續單：
> 驗證器加一個條件；並要定義這種機器的電源／遙測預設行為＝「沒人管」要明寫在圖與手冊）。

> **W15-1 brand 清單單一來源**：(a) 現狀＋絆線；**(b) 搬進 `GraphTypes.hpp` 另排**（全樹重編的排程問題）。

🔴 **裁決有兩半，而第二半才是這一單真正的內容。** 「放行」很容易；
「放行而且圖上寫著這台機器沒人管」才是裁決的條件。閘門的 M27 就是為了第二半而存在——
一台載得進來、路由也走得通、但電源與健康數字沒有任何一段碼是為它寫的交換機，
**在圖上看起來跟一台真的被管理的交換機一模一樣**，除非有人明寫。

## 1. 兩顆 commit

| commit | 做了什麼 |
|---|---|
| `35a1c9cf` | 驗證器加豁免條件；`power_path`／`telemetry_path` 兩個節點欄位；§38 手冊；八支測試；閘門 M25–M27／W7 |
| 第二顆 | 合法 brand 清單與五個具名常數搬進 `GraphTypes.hpp`；`.cpp` 與電源管理器六處字串比較改引用；絆線測試改寫；閘門 M23 搬到 header ＋新增 M28 |

### 1.1 看紅（**不是變異體造的**）

`git show 8b3ebe49:src/.../TopologyAndFlowMonitor.cpp` 蓋回去（sha256 `1e9f0637…`，
與 git object 逐位元組相同），**新的 header 留著**——base 那份 `.cpp` 不呼叫 header 新增的東西，
兩個新欄位就停在預設值 `"none"`。**這一點是明講的，不是藏起來的**：
base 樹連編都編不起來這些測試（`VertexProperties` 當時沒有 `powerPath`），
不這樣做就完全沒有非變異體的紅。

**44 支跑、38 綠、6 紅**；修法後同一組 **44 支全綠**。逐字（節錄）：

```
[ RUN      ] TopologyInputValidationTest.AnUnknownBrandWithAnExplicitSwitchKindIsAccepted
tests/test_TopologyInputValidation.cpp:1416: Failure
Value of: out.threw
  Actual: true
Expected: false
a switch that declares its data plane explicitly was still refused for its brand: ...
  out.vertices Which is: 0   14u Which is: 14

[ RUN      ] TopologyInputValidationTest.EveryAcceptedBrandCarriesAPowerPathThatIsNotNone
Expected: (sw->powerPath) != ("none"), actual: "none" vs "none"
brand OVS is on the accepted list but is reported as having no power path, which makes "none"
useless as the mark of an unsupported switch
```

🔴 **兩支沒紅，而且它們沒紅是對的**：
`ASwitchWithASwitchKindStillNeedsABrandName`（base 也會拒、也會給句子 ⇒ 它的鑑別力在 **M26**）、
`AnUnknownBrandWithAMalformedSwitchKindIsStillRefused`（純對照，兩邊都拒）。

## 2. 第一顆：豁免與那個記號

### 2.1 豁免條件（`TopologyAndFlowMonitor.cpp`，door 3e）

未知 brand ＋ **明確合法的 `switch_kind`** ⇒ 放行；否則照 #91 拒絕。
「明確合法」由 `declaresLegalSwitchKind()` 判定，三件事都要成立：key 在、是字串、
`switchKindFromString` 收得下。`"switch_kind": "cisco"` **是第二個錯字，不是逃生門**。

⚠️ **那三件事今天有兩件構不到，而我把它寫下來而不是假裝它有鑑別力。**
door 3a（`switchKindFromString`）在 door 3e 之前二十行就跑，任何畸形的 `switch_kind` 在那裡就 throw
⇒ 述詞自己的嚴格度目前是**防禦性死碼**。閘門因此**沒有**為它安排變異體
（安排了就是在給一條到不了的分支打分數），測試
`AnUnknownBrandWithAMalformedSwitchKindIsStillRefused` 的註解逐字寫了這一點。
述詞仍然寫成獨立成立的樣子：「因為兩個檢查的先後順序所以到不了」不是任何人會維護的性質。

### 2.2 記號：`power_path`／`telemetry_path`

裁決要求把「這台機器沒有電源／遙測路徑」寫進圖與手冊。實作：

- `GraphTypes.hpp`：`powerPathForBrandName()`／`telemetryPathForBrandName()` 兩個函式
  ＋ `VertexProperties` 兩個欄位；
- 載入時由 builder 寫上；
- `/ndt/get_static_topology_json`（手冊 §38）在 **switch 節點**上發佈這兩個 key。

🔴 **這兩個欄位的定義寫得很窄，因為寬一點就會變成謊話。**
它們說的是 `DeviceConfigurationAndPowerManager.cpp` 裡**依 brand 分支**的那幾段——
讀電力、讀 CPU／記憶體／溫度——**不是**電源開關的致動。
致動是依 `SwitchKind` 派工的（`getPowerStrategyForDpid`：BMV2 走 P4 proxy，
**OVS 與 HARDWARE 都走 `OVSPowerStrategy`**），跟 brand 無關。
被豁免的交換機仍然會拿到它宣告的 `switch_kind` 所選的致動路徑；
它沒有的是**為它的型號寫過的那一段**。

（行號都是 `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`，2026-09-07 的樹。）

| 值 | 來自哪一段碼 |
|---|---|
| `snmp` | `brandName == "HPE5520"`：HPE OID——電力 `:1805`／`:2308`（`snmpwalk`）、CPU `:2120`、記憶體 `:1342`、溫度 `:2209`（那一段逐字拒絕其他所有 brand：「The temperature function only supports the HPE 5520.」） |
| `ssh` | 兩台 Brocade：同幾段的 else 分支。電力走 `:2325` 的 `getPowerReportViaSsh`，註解逐字寫著 `// Brocade / Others (Currently via SSH)`；CPU／記憶體的 else 打的是 Brocade 的 OID |
| `synthetic` | OVS／BMv2：MININET 模式把電力短路成 `syntheticPowerMilliwattsFor(dpid)`（`:1777`／`:2301`） |
| `none` | 其他——**只有透過 `switch_kind` 豁免才到得了**，而它是誠實的答案 |

🔴 **注意那個 else 是「Others」。** 一台未知型號的交換機在 TESTBED 模式下不是「沒人理」，
是**被當成 Brocade 對待**：Brocade 的 OID、Brocade 的 SSH 取電。這正是 #91 說的
「by accident rather than by design」，也正是 `power_path: "none"` 要講的那句話。

⚠️ **`telemetry_path` 對 OVS／BMv2 也是 `none`，這不是把記號稀釋掉。**
MININET 模式的 CPU／記憶體／溫度一律回 `kHealthMetricUnavailable`（−1，KNOWN-ISSUES F-1）
⇒ 軟體交換機**本來就沒有**健康遙測。
**唯一只屬於被豁免交換機的記號是 `power_path == "none"`**：清單上五個 brand 每一個都有電源路徑。
測試 `EveryAcceptedBrandCarriesAPowerPathThatIsNotNone` 就是這一句的對照組——
如果被接受的 brand 也標 `none`，這個記號就什麼都沒說。

🔴 **記號是宣告，不是行為改變。** 被豁免的交換機在 TESTBED 模式下**仍然會**掉進那個 else 分支、
仍然會被打 Brocade 的 OID（它不會回答）。這一單**沒有**去改電源管理器讓它對未知 brand 拒絕作答——
裁決要的是「明寫在圖與手冊」，而那六處的改法是另一個範圍。見 §5 與 SUMMARY §7。

## 3. 第二顆：清單搬進 header（W15-1 (b)）

W15 §7 問的是「合法 brand 清單要不要單一來源」，當時是
「`.cpp` 一份清單 ＋ `GraphTypes.hpp` 一份 mapping ＋ 電源管理器六處字串比較」，
靠絆線測試 `TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn` 綁在一起。
Adam 裁 **(b)**：搬進 `GraphTypes.hpp`，並把全樹重編排在沒有建置壓力的時段。

做法：五個 brand 各給一個具名常數，`kAcceptedSwitchBrands` 由它們組成，
`switchKindFromBrandName`、`powerPathForBrandName`／`telemetryPathForBrandName`
與電源管理器六處比較**全部改成引用常數**。

🔴 **絆線測試的性質因此變了，這一點要寫清楚而不是留給讀者發現。**
在兩份真相的世界裡，絆線的工作是「發現兩邊已經漂開」；
單一來源之後，**漂不開是編譯期保證**，絆線改成守另一件事：
「沒有任何一段碼用字面值跟 `brandName` 比對一個清單不收的 brand」。
連帶：閘門的 **M23**（把清單裡的 `HPE5520` 拼錯）搬到 header，
而它的預期紅**不再包含絆線**——單一來源之後絆線看不到這種變異，
說話的是出貨檔那兩支（`EveryShippedTopologyStillLoadsWithNothingDropped`、
`EveryBrandTheShippedFleetNamesIsAccepted`）。
新增一顆變異體把電源管理器的常數換回一個清單沒有的字面值，
**那才是絆線在新世界裡的鑑別力所在**。

## 4. 沒做的（完整清單在 SUMMARY §5，這裡只留三條最容易被誤讀的）

1. 🔴 **電源管理器的行為沒有改。** 被豁免的交換機在 TESTBED 模式下**仍然會**掉進那個
   `else`，仍然會被打 Brocade 的 OID 與 SSH 取電。這一單做的是**宣告**：
   把「沒人管」寫進圖（節點欄位）與手冊（§38），照裁決的字面。
   要不要讓那六處**行為上**也拒絕作答是另一張單（SUMMARY §7 第 1 題）。
2. **`switchKindFromBrandName` 的 HARDWARE fallback 沒動。** W15-1 的選項 (c)
   （讓 mapping 自己對未知 brand throw）沒有被裁中，而它仍然是唯一能保護
   「不經過驗證器就建圖」那條路的辦法。header 的註解逐字寫了這一點。
3. **`declaresLegalSwitchKind` 的三個條件，今天只有一個構得到。** door 3a 在二十行前
   就對畸形 `switch_kind` throw ⇒ 「不是字串」與「值不合法」兩條是防禦性死碼。
   閘門**沒有**替它們安排變異體（那會是在給一條到不了的分支打分數），
   測試 `AnUnknownBrandWithAMalformedSwitchKindIsStillRefused` 的註解與閘門 5e 節都寫了。

## 5. 這一單自己跑過的 vs 讀過未執行

- 🟢 **自己跑過**：紅綠（`02-redgreen-c1.log`）、閘門兩輪（`03-gate-ctest-c1.log`／
  `05-gate-ctest-c2.log`）、`ctest` 兩輪、`check_gate_anchors.py`、
  電源管理器六處分支的行號與 else 分支內容（開檔讀過）。
- 🔵 **讀過未執行**：R0b 2026-09-05 的 live 量測（引用 #91 的 FIX 文件，沒有重跑）；
  `getPowerStrategyForDpid` 把 HARDWARE 也送進 `OVSPowerStrategy` 這件事是**讀碼**，
  沒有在實機上驗過一台 HARDWARE 交換機的電源致動實際走哪一條。
