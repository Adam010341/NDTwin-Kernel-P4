---
name: destination-paths-not-monotonic
description: "all_destination_paths 會先到 16256 再掉回 13184;它不是進度條而是會被重建的清單。⚠️ 「kernel 只抓一次不重試、永久殘缺」已於 08-28 撤回——它有 refresh 執行緒;真正的缺陷是降頻條件為『非空』而非『收斂』,所以 16224(99.8%)會被當成載好並撐 60 秒"
metadata: 
  node_type: memory
  type: project
  originSessionId: ead7700c-55b2-4730-a1f9-4bdd2b99ee33
  modified: 2026-08-28T10:55:23.385Z
---

2026-08-20 實測。P4 proxy 的 `/ryu_server/all_destination_paths` **不是單調遞增的進度條**。

冷啟一次的實際觀察:

```
stack.sh:                    paths=16256   converged after 4s
幾秒後我自己讀:                13184/16256
再連續 poll 40 秒:            16256,四十個樣本全穩
```

另一次冷啟,填充過程中就會**往下掉**:

```
paths=8064  ->  paths=6144  ->  paths=10880  ->  paths=16256
```

**兩個後果:**

1. **`stack.sh` 的收斂閘會被瞬間尖峰觸發** —— 它只要一個樣本等於目標就 return
   (`stack.sh` 的 `await_convergence`)。
2. 🔴 ~~**kernel 只在啟動時抓一次 destination paths,而且不重試。**~~
   ⚠️ **這句已於 08-28 撤回,見本檔 §「已經不成立了」。以下保留原文以供對照。**
   原文:**kernel 只在啟動時抓一次 destination paths,而且不重試。** 抓的那一刻如果落在低谷,
   kernel 的路徑集合就**永久殘缺,而且沒有任何 log 會說**。這一輪沒發生
   (kernel log 有 `Pulled 16256 paths from controller`),但視窗是真的。

**機制(觀察到相關,因果未證):** 低谷與 proxy 大量裝路由(`Modified route: 10.0.0.N/32 -> port P`)
以及 kernel 的一次性 topology pull 同時發生 —— 看起來像清單被整個重建再填回去。
**不要把這個相關當成已證實的機制**(見 [[arithmetic-that-fits-is-not-the-mechanism]])。

**How to apply:** 任何「等收斂」的判斷都要**沉澱**,不要單次取樣。
`ndt up` 的作法:要求目標值**連續兩次、間隔 ≥3 秒**才算 ready。
沒有這層,當天第一次冷啟就會在一個其實健康的 stack 上驗證失敗。

相關:[[ndt-one-command-lab-lifecycle]]、[[reproducible-is-not-mechanism]]。

**2026-08-20 補：不是 P4 專有，而且 `ndt up` 的沉澱邏輯實戰有效。**
同一晚兩個平面都直接看到低谷：P4 `paths=9280 → 14336 → 16256`（69 s 收斂）、
OVS `links=32 → 31 → 32`（開機手冊在 `ndt up ovs`／`ovs4` 都看到）。
兩輪冷啟量測都靠 `ndt up` 撐過低谷才開始量，**沒有髒資料進到結果**。
所以這條從「已知風險」降級成「已有防護的已知風險」——但**只在走 `ndt up` 時**；
直接 `stack.sh` 起的沒有這層。

**2026-08-27 補：`ndt up` 的沉澱是在「啟動 kernel 之前」跑的——這比我先前記的更強。**

換平面到 P4 時逐行看到（`ndt up p4 128`，實測）：

```
waiting for link discovery: want 16256 destination paths
  paths=10336   paths=14528   paths=16192   paths=16256   converged after 14s
started kernel (pid 697424)
waiting for kernel API on :8000 . up
```

⇒ **順序是對的**：沉澱閘門擋在 kernel 啟動**之前**，而 kernel 正是那個「只抓一次、不重試、
抓錯了不會有 log」的消費者。⇒ 只要走 `ndt up`，那個永久殘缺的視窗**在結構上構不到**。

📌 先前我記的是「`ndt up` 要求連續兩次才算 ready」（防低谷），**這條補的是它跑在什麼位置**
——防護有沒有效，取決於它在一次性消費者的前面還是後面。

## 🔴 2026-08-28 更正：「只抓一次、不重試、永久殘缺」**已經不成立了**

上面第 31 行那句是這整條記憶被引用最多的一句，而它**對現在的 main（`20cd80b`）是錯的**。
`FlowLinkUsageCollector.cpp:478-495` 明寫 T+0 的那次 fetch **被移除了**（它從來不可能成功，
而且在位址沒人回應時把整顆 kernel 卡住 131 秒），改成一條 refresh 執行緒：

```cpp
constexpr auto kWhileEmpty = 5s;    // 還在收斂：快點再試
constexpr auto kOnceLoaded = 60s;   // 穩態：只追變化
const auto interval = haveAny ? kOnceLoaded : kWhileEmpty;
```

⇒ **它會一直重抓，殘缺最多撐 60 秒，不是永久。** 引用這條之前先改掉那個量詞。

## 🔑 但真正的缺陷換了形狀，而且現在有數字

`haveAny = !getAllPaths().empty()` ⇒ **降頻的條件是「非空」，不是「收斂」。**
所以節奏在清單變動最劇烈的那一刻從 5 s 掉到 60 s。

`開機手冊` 08-28 的 128-host 收斂表把窗口量出來了：

| t | paths | |
|---|---|---|
| +1s | 155 | |
| **+8s** | **16224** | 🔴 **差 32＝最終值的 99.8%** |
| +18s | 16256 | |

⇒ **落在 +8s 的那次 fetch 拿到一個「大而穩而錯」的集合**，然後**六十秒內不會再看**。
99.8% 不會觸發任何「看起來還沒好」的直覺——**這正是比低谷危險的地方：
低谷長得像沒收斂，99.8% 長得像收斂了。**

⚠️ 那筆收斂曲線是 **proxy 算的**（`ryu_topology.py:191 render_destination_paths`），
輪詢期間 kernel 還沒起來；kernel 是這個端點的**消費端**（`fetchAllDestinationPaths` curl 它）。
**別把它讀成 kernel 側的讀數。**

相關：[[disclosure-is-not-downgrading]]（撤回沒收乾淨：這句過時的話在四處被引用過）

## 🏁 08-30 TR-1：那個約 60 秒的天花板第一次被當成主角量到

4-host P4＋流量、取樣 0.5 s／1200 樣本／**0 overrun**／2.001 Hz（128 hosts 量不到，見
[[instrument-must-not-mimic-its-own-finding]]）。消費者實際讀到的值的變動間隔：
`n=56, min=0.50, p50=28.01, p95=60.01, max=60.52`——**上緣就卡在 60 s**，正是這個 refresh thread。
⇒ **R-2（1 kHz→1 Hz 重算）對任何消費者都不可觀測**，但**登記的理由是錯的**：
預註冊說「消費者 15 s 輪詢」，實測**沒有一支 app 用 15 s**（viz/te 1 s、nsr 5 s、energy 60 s，
五支裡三支比 1 Hz 還快）。結論活下來、前提沒有。
🔴 **56 個間隔裡有 3 個是次秒級（min 0.50 s），比它應該下游的 1 Hz 重算還快，沒有解釋。**
候選（都沒測）：0.5 s 取樣邊界的假象／兩個 flow key 混疊成一個／另有事件驅動的更新路徑。
5% 很小，但那是分布裡**唯一**跟上面結論不一致的部分，所以不要抹掉。
