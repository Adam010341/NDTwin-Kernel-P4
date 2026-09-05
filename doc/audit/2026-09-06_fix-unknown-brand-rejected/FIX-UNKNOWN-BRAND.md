# W15／#91 — 未知的 `brand_name` 一律拒絕，並且不要再建議 `ALLOW_MIXED_DATAPLANE`

工單：`scratch/overnight-2026-09-05/fix/TICKETS-0906/W3-3b-and-W15-validator.md`（分支 2）。
裁決正本：`scratch/overnight-2026-09-05/DECISIONS.md` 第五輪——
「**W15：未知 `brand_name` 拒絕＋拿掉 `ALLOW_MIXED_DATAPLANE` 建議**」。
修的人：09-06 下半場「W3-3b／W15 修法 agent」session，worktree `wt-val`，
分支 `fix/w15-unknown-brand-rejected`，**base＝分支 1 的 tip `72ffd4dd`**（同一個函式，避免衝突）。
日期：2026-09-06。

[Co-developed with claude code -- Adam]

---

## 1. 一句話

**缺陷不是「靜默收下」，是「用拒絕的語氣放行」。**
`switchKindFromBrandName`（`GraphTypes.hpp:95-107`）只認得 `BMv2` 與 `OVS`，
**其他一律回 `HARDWARE`**——那是預設值，不是決定。於是拓樸檔裡一個打錯的 `brand_name`
變成一台硬體交換機，而操作者唯一看到的是「資料平面混用」的錯誤，
外加一句**會讓打錯永久化**的建議。

門開在 `validateStaticTopologyJson`，代號 **`door 3e`**（3a `switch_kind`／3b switch 空 ip／
3c `bridge_name`／3d host 空 ip 之後的下一個字母）。

## 2. 缺陷（🟢 量到的）

`scratch/overnight-2026-09-05/rounds/05-R0b-postmerge2.md`，2026-09-05，
kernel `862c4bf8efa048bc`，OVS4 平面，六個壞檔的第 **c** 個：

| # | 壞法 | R3（kernel `4c9e0be1`） | R0b（kernel `862c4bf8`） | 一個字 |
|---|---|---|---|---|
| **c** | `brand_name` = `NOT_A_REAL_KIND` | ❌ 收下 rc=124，訊息指錯原因 | ❌ **收下 rc=124**，同一句 data-plane 訊息 | **未修** |

逐字（R0b，去掉 ANSI）：

```
c: [error] [TopologyAndFlowMonitor.cpp:2436 validateDataPlaneHomogeneity] Topology mixes data
   planes (ovs=[1,2,3,4,5,6,8,9,10]; hardware=[7]). A single run must be all-OVS or all-BMv2:
   the flow dispatch is per-DPID and would cope, but the telemetry and liveness paths assume one
   kind. Fix the topology file, or set AppConfig::ALLOW_MIXED_DATAPLANE to override.
   （↑ 語氣是拒絕、行為是放行：這一行印完 kernel 照樣起來聽 :8000）
```

R0b 自己在「要問 Adam 的」第 6 題把它列為必問：
「**它建議的 `set AppConfig::ALLOW_MIXED_DATAPLANE to override` 會把任何打錯的 brand 變成 `hardware`。**」

### 2.1 三層後果，一個原因

1. **路由派工**：`brand_name` 決定 `SwitchKind`，`SwitchKind` 決定用哪一支 `IRoutingStrategy`。
   `GraphTypes.hpp:70-76` 的註解自己寫著這件事的理由——
   「a misspelled brand name would otherwise silently route P4 rules to the Ryu controller」
   ——**而 `switchKindFromBrandName` 的 fallback 正好把那個洞又打開。**
2. **電源／遙測派工**：`DeviceConfigurationAndPowerManager.cpp` 有六處
   `brandName == "HPE5520"`（`:1342`／`:1805`／`:2120`／`:2209`／`:2308`／`:2444`），
   else 分支的註解寫著 `Brocade / Others (Currently via SSH)`。
   ⇒ 一個不認得的 brand **會拿到 Brocade 的 SSH 指令**，不是因為它是 Brocade，是因為它不是 HPE。
3. **同質性訊息**：那台假硬體讓 all-OVS 的網路看起來是混平面
   ⇒ 印出上面那一段，而 `validateDataPlaneHomogeneity` 的**回傳值沒有人接**（run-06 BUG-17）
   ⇒ kernel 照樣起來。

## 3. 修法

### 3.1 合法值清單放在 `.cpp`，不放 `GraphTypes.hpp`

```cpp
constexpr std::array<std::string_view, 5> kAcceptedSwitchBrands{
    "OVS", "BMv2", "HPE5520", "BrocadeICX6610", "BrocadeICX7250",
};
```

🔴 **這份清單是「艦隊」不是猜的。** 🟢 全 repo 所有 `*.json` 裡的 `brand_name` 字面值只有六種：
`""`（1144 次，全是 host）、`BMv2`（144）、`OVS`（120）、`BrocadeICX7250`（25）、
`HPE5520`（22）、`BrocadeICX6610`（2）。**沒有別的。**
十三份出貨拓樸裡有**五份是 TESTBED**，交換機是 HPE／Brocade
⇒ **把清單縮成 `{OVS, BMv2}` 會一次打掉五份**，就是 M8／M13／M20 那個
「比缺陷更大的停機」形狀，這裡由 M23 守。

**為什麼不放進 `switchKindFromBrandName` 旁邊**（那才是「同一件事」的家）：
`GraphTypes.hpp` 幾乎被全樹 include，改它＝全樹重編；#89 為同一個理由拒絕過改那顆 header
（`FIX-TOPOLOGY-THREE-DOORS.md` §4 末），而今晚 build lock 上同時排著五個 agent。
**代價是「同一個真相有兩份」**，所以配一支結構絆線測試
`TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn`：掃 `GraphTypes.hpp` 與
`DeviceConfigurationAndPowerManager.cpp` 裡所有 `brandName ==`／`brandName !=` 的字面值，
**每一個都必須在清單裡**。哪天有人教會 mapping 一個新 brand 卻忘了清單，它就紅。

### 3.2 門本身：兩個 fault，一扇門

放在 node 迴圈裡、door 3a 之後、door 3b 之前，只對 `vertexType == SWITCH`：

1. `brand_name` **缺或不是字串** ⇒ 拒絕（原本由**建構迴圈**的 `at("brand_name")` 拒絕，
   也就是 `0..N-1` 已進圖之後，而且回的是 nlohmann 例外類別）。
2. `brand_name` **不在清單裡** ⇒ 拒絕，訊息**指名該值**、**列出全部合法值**、
   說明它以前被靜默對映成 `hardware` 的後果、並說**新機型要加在哪兩個地方**。

### 3.3 🔴 `ALLOW_MIXED_DATAPLANE` 那句建議：**不是刪掉訊息，是讓它走不到**

工單要我先確認混平面是不是真的功能。🟢 grep 結果：**是**——
`setting/AppConfig.hpp.example:15` 有旗標、`doc/2026-07-27_p4_bmv2_support_plan.md:213` 與
`doc/2026-07-29_p4_status_and_test_guide.md:76` 有規格與測試計畫、
`tests/test_SFlowEmitterRoundtrip.cpp:383` 的 `AMixedTopologyDoesNotUseIdentity` 還在推理混平面下
該用哪一種 port mapping。**⇒ 照工單的條件分支：保留真正混平面的路徑，只拿掉「未知 brand 時」那條建議。**

作法**不是**去改 `validateDataPlaneHomogeneity` 的字串，而是**位置**：
它在 `parseStaticTopologyFile` 的**最後一行**（`:956`）跑，而 door 3e 在 node 迴圈裡。
⇒ 一個打錯的 brand **到不了那一行**，那句建議因此不會對它出現。
`AnUnknownBrandNameLeavesNoPartiallyLoadedGraph` 斷言的 `vertices == 0` 就是這個順序的釘子；
`TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes` 則釘住新訊息不會把那句話抄回來。

🔵 **明講**：`validateDataPlaneHomogeneity` 回傳值被丟棄（run-06 BUG-17）**這一輪沒有修**，
所以**真正**混平面的檔案仍然是「語氣拒絕、行為放行」。那是另一張單（見 §7）。

## 4. 我改了誰的東西

- **`GraphTypes.hpp`：一個字都沒改。** `switchKindFromBrandName` 的 HARDWARE fallback 還在——
  門 3e 讓它到不了拓樸檔這條路，但它仍是那支函式的行為。
  `test_SwitchKindDispatch.cpp` 的 `UnknownBrandNameIsHardware`／
  `BrandNameMappingIsCaseSensitiveByDesign` 兩支**純 mapping 測試**因此**完全不受影響、
  一個字沒改**——它們測的是函式，不是載入器。
- **既有測試斷言：一支都沒改。**（分支 1 改過一支，分支 2 沒有。）
- **既有閘門變異／對照：一字未改**（新增 M21–M24 與 W6）。
- **`doc/2026-01-02_ndt_api.md`**：§38 加一節列合法值；`:2105` 把 `"HPE 5520"` 更正為
  `HPE5520`（🔴 **那個空格現在會決定檔案載不載得進來**）。

## 5. 測試（全部進既有 `tests/test_TopologyInputValidation.cpp`，沒開新檔）

| 測試 | 斷言 |
|---|---|
| `AnUnknownBrandNameLeavesNoPartiallyLoadedGraph` | `threw`、`vertices == 0`、`edges == 0` |
| `TheUnknownBrandRefusalNamesTheBrandAndTheAcceptedOnes` | 訊息含 `NOT_A_REAL_KIND` 與**五個**合法值 |
| `TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes` | 訊息**不含** `ALLOW_MIXED_DATAPLANE` |
| `ASwitchWithNoBrandNameIsRefusedInPlainLanguage` | `threw`、`vertices == 0`、訊息不含 `json.exception` |
| `EveryBrandTheShippedFleetNamesIsAccepted` | 🔴 **從出貨檔推導**五個 brand，每一個都要能整份載入（14／40） |
| `AHostBrandNameIsNotChecked` | 對照：host 的 `brand_name` 亂寫仍然載得進來 |
| `TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn` | 絆線：碼裡 `brandName ==`／`!=` 的每個字面值都在清單裡 |

🔴 **`TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes` 在修法前是紅的，
但紅在 `ASSERT_TRUE(out.threw)`（前提），不是紅在它存在的那條斷言。**
修法前根本沒有拒絕訊息可看，那條 `find("ALLOW_MIXED_DATAPLANE") == npos` **一次都沒有執行到**。
⇒ **它那條宣稱的證據是閘門 M24**（把那句建議塞回新訊息）。這一點寫在測試註解與 §6 裡，
不假裝那條斷言「看過紅」。

🔴 **`TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn` 在修法前也是紅的，
而且紅得誠實——紅在「找不到清單」，不是紅在「清單漏了誰」**：

```
Expected equality of these values:
  accepted.size()
    Which is: 0
  5u
could not read kAcceptedSwitchBrands out of the validator -- the search, not the answer, is what failed
```

修法前 `kAcceptedSwitchBrands` 根本不存在。**這支絆線真正的鑑別力來自 M23**（見 §6）。

🔴 **`EveryBrandTheShippedFleetNamesIsAccepted` 把每一台交換機都換成同一個 brand，不是只換一台**：
只換一台會做出**混平面**拓樸，那是另一個（而且被支援的）題目，測到的會是同質性路徑不是這扇門。

### 5.1 看紅（逐字，**不是變異體造的**）

把 `TopologyAndFlowMonitor.cpp` 還原成 **分支 1 的 tip `72ffd4dd`** 那一份（＝有門 3d、沒有門 3e）、
只留新測試。log：`scratch/overnight-2026-09-05/fix/w3d-logs/03-w15-redgreen.log`。
**40 支跑、35 綠、5 紅**；修法後同一組 **40 支全綠**。

**主張本身：**

```
[ RUN      ] TopologyInputValidationTest.AnUnknownBrandNameLeavesNoPartiallyLoadedGraph
tests/test_TopologyInputValidation.cpp:1092: Failure
Value of: out.threw
  Actual: false
Expected: true
an unknown brand_name was accepted and mapped to hardware
tests/test_TopologyInputValidation.cpp:1093: Failure
Expected equality of these values:
  out.vertices
    Which is: 14
  0u
    Which is: 0
the file was refused only after 14 vertices were already in the graph -- and a graph that reaches
validateDataPlaneHomogeneity is a graph that gets told to set ALLOW_MIXED_DATAPLANE
```

`vertices == 14`／`edges == 40` ＝**整份檔案完整載入**，就是 R0b 在 :8000 上量到的那個行為。

**「缺 `brand_name`」那一支——紅在兩個地方，而且是門 3 的經典形狀：**

```
tests/test_TopologyInputValidation.cpp:1167: Failure
  out.vertices
    Which is: 9        ← 建構迴圈在第 10 個節點才 throw，前 9 個已經進圖
tests/test_TopologyInputValidation.cpp:1169: Failure
  out.messageSansPath.find("json.exception")
    Which is: 56
the refusal is a raw nlohmann exception, not a diagnostic: topology file "": node #9 "s10"
ip=["192.168.123.20"]: [json.exception.out_of_range.403] key 'brand_name' not found
```

⇒ **兩支對照組（`AHostBrandNameIsNotChecked`、`EveryBrandTheShippedFleetNamesIsAccepted`）
與其餘 33 支從頭到尾是綠的**——5 紅 35 綠的分佈，不是「改什麼都紅」。

## 6. 閘門

擴充既有的 `tests/shell/mutate_topology_input_is_validated.sh`：
**新增 4 個 anchor、4 個變異（M21–M24）、1 個對照（W6）**。既有的 20 變異／5 對照**一字未改**。

| # | 變異 | 必死測試 |
|---|---|---|
| M21 | 成員檢查永不觸發（`&& false`） | 三支未知 brand 的案例 |
| M22 | 🔴 **過寬**：門套到所有節點型別（`if (true)`） | `AHostBrandNameIsNotChecked` ＋ `EveryShippedTopologyStillLoadsWithNothingDropped` |
| M23 | 🔴 **打爆艦隊**：清單裡的 `HPE5520` 打錯成 `HPE9999` | `EveryShippedTopologyStillLoads…` ＋ `EveryBrandTheShippedFleetNamesIsAccepted` ＋ **`TheAcceptedBrandListCovers…`** |
| M24 | 訊息把 `ALLOW_MIXED_DATAPLANE` 建議加回來 | `TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes` |
| W6 | 對照：成員檢查改寫成 `std::none_of` | **留綠** |

🔴 **M21 用 `&& false` 而不是刪掉檢查、M23 改字而不是刪一筆**：`-Werror` 會把
「`kAcceptedSwitchBrands` 或 `acceptedSwitchBrandList()` 沒人用」變成編譯錯誤，
而編不過的變異在這支閘門裡算 SURVIVED——那個 survivor 會是閘門自己的產物。
（陣列大小是宣告出來的，刪一筆還會留下一個 value-initialised 的空 brand，量到的是別的東西。）

**M23 是這一組最值得看的一個**：它同時被「出貨檔」與「絆線」抓到
——後者證明 §3.1 那份「兩份真相」的補償措施真的會說話。

### 6.1 驗收（逐字）

```
24 mutations, 0 survived
6 widenings, 0 wrongly caught
GATE EXIT rc=0
```

還原檢查：`all 1 files byte-identical to the pre-run snapshot`／`rebuilt from the restored tree`／
`suite green again after restore`／`test binary sha unchanged: 5f245df7710bc5ba`。
四個新變異全部 `✅ caught`，各自紅在它宣稱的那幾支上；`W6 ✅ survived`。
（既有的 M1–M20／W1–W5 也全數維持 caught／survived。）
log：`scratch/overnight-2026-09-05/fix/w3d-logs/03-w15-redgreen.log`。

**全套**：`100% tests passed, 0 tests failed out of 1097` ／ `CTEST rc=0`
（分支 1 的 tip 是 1090 ⇒ **＋7 就是這張單新增的七支**，沒有別的東西被動到）。

## 7. 沒做的與給 Adam 的

- **`switchKindFromBrandName` 的 HARDWARE fallback 沒改**（§4）。要不要讓它也 throw、
  讓「未知 brand」在**函式層**就不合法，是一張會動到 `GraphTypes.hpp` 全樹重編的單。
- **`validateDataPlaneHomogeneity` 的回傳值仍然被丟棄**（run-06 BUG-17）：
  **真正**的混平面拓樸至今仍是「印 `[error]` 然後照樣起來」，而
  `doc/audit/2026-07-29_p4_status_and_test_guide.md:76` 與 `architecture.md` 都寫著它會拒絕。
  🔴 **這條在 `doc/KNOWN-ISSUES.md` 裡沒有條目**（grep `brand`／`homogene`／`refuses to load` 全 0 命中）。
  要不要登記，是 Adam 的題目。
- **`switch_kind` 不豁免這扇門**：一個宣告了 `switch_kind` 但 `brand_name` 打錯的節點仍然被拒絕。
  理由是 `brand_name` **另外**決定電源／遙測派工（§2.1 第 2 點），`switch_kind` 只管路由。
  代價：拿一台這個 codebase 沒有電源路徑的交換機（例如 Cisco）做實驗的人，
  **必須改一行 C++ 才能載入拓樸**。這是刻意的取捨，不是漏掉。
- **沒有 live 驗證**：這一輪一個 kernel 都沒跑（lab 空著、不歸我碰）。§2 引的是 R0b 的量測。
- **同型盤點沒做**：`brand_name` 之外還有沒有「字串欄位靜默 fallback 成某個預設行為」的欄位，
  這一輪只處理工單點名的這一個。**不宣稱不存在。**
