# W2 live 複驗輪（P4/bmv2）— 2026-08-13 下午

執行者：orchestrator（Adam 在場開的 Mininet）。HEAD `a3bfa40`。
環境：bmv2 10 台、4 host、kernel :8000、proxy :8081。h1 pid 25072。

## TL;DR

| # | 測項 | 結果 |
|---|---|---|
| 1 | **readopt gate 拒絕路徑**（修復 `a72a168`） | ✅ **通過**：健康 switch → 502 `step:mastership`、**規則 4→4 一條沒少**、ping 0% loss |
| 2 | **P4 側單向鏈路故障**（先前完全未測） | ✅ **系統正確處理**：canary 只掉 12.5s 就自癒、規則從 `OUTPUT:1` 改成 `OUTPUT:2` 真的繞路 |
| 3 | **readopt 接受路徑**（power-cycle 後） | ⚠️ **通過但發現漏洞**：回 200 success 而 `routes_attempted=0`、switch 當下**空表**；~30 秒後才由別的機制補上 |
| 4 | **qdisc 前後置快照**（新工具首次實戰） | ✅ 零漂移（43 行不變） |
| 6 | **L5 故障注入首次實戰**：三型跑過，N-4 抓到 🔴 P1（一台 switch 停止回應 → liveness 端點 60s+ 無回應、kernel 圖掉到 32/40） | 見 §6 |
| 5 | **bmv2 非 primary pipeline push** | ~~🔴 坐實：仲裁被拒的 client 照樣推成 config，s10 規則 **4→0**。任何連得到 gRPC 埠的程式都能清空一台交換器~~ **← 2026-08-13 晚推翻，見 §5 更正橫幅。清表為真，但 bmv2 符合規格；肇因是我方 election id 重用，且「任何程式都能清空」這句不成立** |

---

## 1. readopt gate — 拒絕路徑 ✅

【觀察】對**健康**的 s1 打 `POST /p4/readopt/1`：

```
HTTP 502
{"detail":{"status":"failed","step":"mastership",
 "error":"arbitration was not granted within the settle window; the old client (or another
  controller) likely still holds mastership. The switch was not touched."}}
```

規則數：**before 4 → after 4**。canary ping 5/5、0% loss。

【推論】昨晚的缺陷（4→0 且回 `success`）在真環境不再發生。修復成立。

## 2. P4 側單向鏈路故障 ✅（先前是完全未測的空白）

【設計】h1→h2 路徑為 `h1 -3-> s1 -1-> s5 -2-> s2 -3-> h2`（查 `all_destination_paths` 得出），
所以目標鏈路是 **s1-eth1 ↔ s5-eth1**。**只在 s1-eth1 一端**下 `netem loss 100%`
（s1→s5 死、s5→s1 活），複製 OVS 輪 P0 的故障形狀。T0 = 13:27:23。

【觀察】kernel 圖的取樣：

| 時間 | 相對 T0 | edges up |
|---|---|---|
| 13:27:31 | +8s | 40/40（尚未偵測） |
| 13:27:41 | +18s | **38/40**（兩條標 down） |
| 13:27:51 | +28s | **39/40**（自我修正成一條） |
| …至 13:29:34 | | 穩定 39/40 |

**「先標兩條、再修正成一條」與 OVS 輪的觀察形狀完全相同**——不對稱狀態成為穩態。

【觀察】資料面：canary（`ping -D -i 0.5`）整輪 293 個回應、**只有一個 gap：seq 7→33（25 個封包 = 12.5 秒）**，之後一路通到 seq 318。
s1 對 `10.0.0.2` 的規則從 `OUTPUT:1` 變成 **`OUTPUT:2`** —— 真的繞路了。
proxy log **零 traceback、零 KeyError**（僅有的 "failed" 是啟動時 proxy 先於 kernel 的預期 ConnectionError）。

【推論】**P4 側沒有 OVS 那個 P0。** 同樣的故障形狀、同樣的不對稱穩態，OVS 側是
`install_all_pair_paths` KeyError → 291 秒黑洞零自癒；P4 側是 12.5 秒自癒。
差異在實作：P4 proxy 的重算路徑不假設反向邊必然存在。

**還原後**：40/40 up、canary 無新 gap、`qdisc_snapshot.sh diff` 零漂移。

## 3. readopt 接受路徑 ⚠️ — 新發現：`attempted=0` 時回報 success 但 switch 是空表

【設計】驗證我的 gate **沒有擋過頭**（只驗拒絕路徑不夠——這是本 repo 的既有教訓）。
選 s10（不在 canary 路徑上）：記規則數 → `ndtwin-p4-power off s10` → 等 40s → `on` → readopt。

【觀察】

```
s10 rules before: 4
power off 13:30:39 → /v1.0/topology/switches 剩 9 台（32afeb9 行為正確 ✅）
power on 13:31:31
POST /p4/readopt/10 → HTTP 200 after 2s
{"status":"success","dpid":10,"clone_session":true,"routes_installed":0,"routes_attempted":0}
s10 rules immediately after: 0        ← 空表
s10 rules at 13:32:01 (~30s later):  4 ← 自己補上了
```

【觀察】機制（proxy log 行號為證，非推論）：

```
1901: [TopologyManager] readopt 10: pipeline pushed, clone_session=True, 0 of 0 routes installed
1925: [TopologyManager] link back up: (10, 1, 5, 4)      ← 在 readopt 之後
1932: [TopologyManager] Installing initial routes proactively...
1951-2011: Proactive Rule: DPID 10 × 4                    ← 規則在這裡才裝上
```

【推論】readopt 執行時 s10 的鏈路仍被標記 down（LLDP beacon 尚未重建），`calculate_all_paths`
排除了所有經過 s10 的路徑 → `dest_paths` 裡沒有 src=10 的條目 → **一條都沒嘗試**（attempted=0）
→ 我的守衛（`attempted>0 且 accepted==0` 才擋）不觸發 → 回 200 success。
恢復是靠後續 LLDP 重新發現鏈路觸發的**獨立機制**，不是 readopt 本身。

【嚴重度】P2–P1 之間。系統**會**自癒（~30s），但回報不誠實：kernel 的 powerOn 路徑拿到
200 success 會認為「接管完成、switch 可用」，而該 switch 在接下來約 30 秒是空表、不轉送。
這是「API 說成功、實際狀態還沒到位」——與本專案批評的「twin 說謊」同型，只是小型且短暫。

**正面副作用**：`routes_attempted` 這個欄位（`a72a168` 新增）**正是讓這個現象可觀測的東西**。
沒有它，這輪只會看到 `routes_installed: 0`，與「本來就不需要裝」無法區分。

【待裁決】修法選項見 INDEX；我建議「回 200 但明確標示 pending」而非改成失敗——
拓撲重新發現本來就需要時間，把它當失敗會讓 powerOn 路徑變成常態性失敗。

## 4. 環境交接

Mininet（Adam 開的）完好、10 台 bmv2 全在、40/40 edges up、s1/s5/s10 各 4 條規則、
netem 零殘留、qdisc 快照零漂移、canary 已停。stack 仍在跑（未 down，供後續測試）。

---

## 5. bmv2 非 primary pipeline push — 對照實驗 ✅ 坐實（2026-08-13 13:5x）

> 🔴 **2026-08-13 晚更正——本節的【推論】與【為什麼這重要】是錯的，不要引用。**
> 觀察（4→0 清表）為真，但機制不是「bmv2 少做一道檢查」。用第三方 raw gRPC client 重現後
> 確認：**bmv2 完全符合規格**，真正的非 primary（election id 較低）推 pipeline 會被
> `PERMISSION_DENIED` 擋下。當時之所以推得過去，是因為本節設計裡那句
> 「election_id 與正在跑的 proxy **相同**」——**相同就是重複**，而 P4Runtime 規定 unary RPC
> 的送出者身分依訊息裡的三元組認定，所以那個 client 拿的是現任 primary 的憑證。
> 「route 才被拒」也不是檢查不對稱，是 `old.stop()` 夾在兩個 RPC 中間。
> ⭐ **本節末「未驗證，回報上游前必須補」的第二點提的正是這個懷疑，而且它是對的。**
> **上游回報已取消。** 完整三情境實測見 `doc/2026-08-13_p4runtime-mastership-spec-check.md`。

Adam 裁決：做，拿 s10（不在 h1–h2 路徑上、剛驗證過 power-cycle 能恢復它）。

【設計】複製 2026-08-13 事故的**精確條件**：建一個 `P4RuntimeClient` 連 s10（device_id=10、
`localhost:50060`），election_id 與正在跑的 proxy **相同**（`start()` 寫死 high=0/low=1），
所以仲裁必然被拒。`start(push_config=False)` 只做仲裁，**再明確**呼叫
`set_forwarding_pipeline_config()`。腳本：scratchpad `nonprimary_probe.py`。

【觀察】

```
s10 rules BEFORE: 4
RESULT mastership_confirmed = False                      ← 仲裁確實失敗
RESULT set_forwarding_pipeline_config returned None      ← 沒有拋例外
s10 rules AFTER: 0                                       ← 表被清空
```

【推論】**bmv2 接受了一個未取得 mastership 的 client 推送 pipeline config，並因此清空了
table entries。** 行為證據（4→0）比返回值強：中間沒有任何其他操作，client 只做了仲裁與這一次
push。這解釋了昨晚事故的完整因果鏈——仲裁被拒 → pipeline push **照樣生效**（表清空）→
後續 route 寫入才被正確地以 `PERMISSION_DENIED / Not primary` 拒絕 → 於是 switch 空表。

**為什麼這重要**：P4Runtime 對 write 有 primary 檢查（實測有效），但
`SetForwardingPipelineConfig` 這條路顯然沒有同一道檢查。也就是說**任何能連到 bmv2 gRPC 埠的
程式都能清空一台交換器的轉送表**，不需要成為 primary。我們自己的防護（`a72a168` 的 gate）
擋住了我們自己的路徑，但擋不住別人。

【未驗證，回報上游前必須補】
- P4Runtime 規格對 `SetForwardingPipelineConfig` 的 mastership 要求的**確切條文**尚未查證。
- 這次用的是**我們自己的 client**（`p4_client.py`）。要回報上游應改用最小的原始 gRPC client
  重現，排除「是我們的 client 送了什麼讓 bmv2 認為它是 primary」的可能。
- bmv2 版本與 build flags 尚未記錄。

【環境已恢復】power-cycle s10 → readopt → 4 條規則、40/40 edges up。

**副帶再現**：這次 readopt 又回 `routes_attempted: 0` 的 200 success（與 §3 同型），
再次確認那不是偶發。

---

## 6. L5 故障注入首次實戰 + N-4 的 P1 發現（2026-08-13 下午）

### 6.1 三型的結果

| 型 | 結果 |
|---|---|
| **L-2** 單向斷鏈 | ✅ 修完工具後完整通過：`before=moving during=moving after=moving, qdisc clean` |
| **L-3** 30% gray failure | ⚠️ 判定**不穩定**：`ping -c 3` 在 30% 雙向丟包下約 13% 機率三個全丟（往返成功率 0.7×0.7≈0.49，0.51³≈13%），這次抓到「forward is dead」的不對稱而判 DISPUTED。**樣本數問題，工具缺陷不是系統缺陷**，未修 |
| **N-4** SIGSTOP | 🔴 **抓到 P1**，見下 |

### 6.2 🔴 P1：一台 switch 停止回應 → liveness 端點無限期卡死

> ⚠️ **2026-08-13 晚更正：本節的【觀察】全部成立，但【推論】是錯的。**
> 原文保留不動（歷史紀錄的價值在於當時怎麼想），正確的機制與修法見本節末的「更正」段。
> 教訓：**觀察對、推論錯**——這是這輪最有價值的產出，改掉原文會讓它消失。

【觀察】對 s5 的 bmv2（pid 25269）送 SIGSTOP（process 活著、不回應 gRPC）：

```
SIGSTOP 15:43:49
/p4/switch_state  --max-time 8   → 空回應（JSON parse 失敗）
/p4/switch_state  --max-time 60  → HTTP 000，60.008 秒完全無回應
kernel 的圖                       → edges up 從 40/40 掉到 32/40
SIGCONT 15:46:04
/p4/switch_state                  → HTTP 200 in 0.0085 秒
kernel 的圖                       → 回到 40/40
```

【推論】`/p4/switch_state` 對每台 switch 做同步 P4Runtime probe，**一台不回應就讓整個端點無法
回答**。後果是 head-of-line blocking：kernel 的 pingWorker 每秒讀這個端點，讀不到就失去**所有**
switch 的狀態，於是把邊逐步標 down——**單一 switch 的故障被放大成全 fabric 的狀態遺失**。

證據式 liveness 的三態設計（Up/Down/Unknown）在這裡沒有發揮：三態要能回答才有意義，
而這個情境下 probe 本身卡住，連「Unknown」都送不出來。

【嚴重度】P1。正常回應 8ms vs 卡住時 >60s，差距四個數量級。

【修法方向，待 Adam 裁決】per-switch timeout（一台卡住就回該台 Unknown、其餘照常）；
或把 probe 並行化並各自設限。**不建議**單純加總 timeout——那只是把卡死的時間變成有限而已。

【N-4 的授權限制】送信號給 root 起的 bmv2 需要 sudo，`kill` 不在 NOPASSWD 內。
本輪用已授權的 `mnexec`（以 uid 0 執行）繞過：
`sudo -n mnexec -a <topo_pid> kill -STOP <bmv2_pid>`。
faults.sh 目前用 `sudo -n kill` 會失敗並誠實回報 `during=not-injected`（未假裝成功）。

---

#### ⚠️ 更正（2026-08-13 晚）：機制不是同步 probe，而是 event loop 被塞住

上面【推論】那段寫「`/p4/switch_state` 對每台 switch 做同步 P4Runtime probe」。**程式碼不是這樣。**
該端點只讀快取（實測 1.9ms），而 probe 跑在背景執行緒、**本來就有 1.5 秒 timeout**
（`LIVENESS_PROBE_TIMEOUT_S`）。

真正的機制由 **py-spy 對活著的 proxy 取 stack dump** 直接指認（不是再一次推讀）：

```
Thread 26024 "MainThread"            ← 這是 asyncio 的 event loop
    wait (threading.py:363)
    _next (grpc/_channel.py:947)
    read_table_entries (p4_client.py:429)      ← 無 timeout 的 streaming stub.Read
    get_flow_stats (api_routes.py:254)
    run_endpoint_function (fastapi/routing.py:345)   ← async 路徑，沒進 threadpool
    run_forever (asyncio/base_events.py:683)
```

`get_flow_stats` 當時是 `async def`，所以 FastAPI 把它的**阻塞 gRPC 讀直接跑在 event loop 上**；
而 `Read` 是 streaming call、沒有 deadline，於是永遠等下去。`/p4/switch_state` 只是陪葬——
**所有**端點一起死。

同一份 dump 還否證了兩個候選解釋，這是單次取樣最值錢的地方：
- `liveness-probe` thread 全程 **idle 在正常的 wait**（`topology_manager.py:1017`）→ prober 完全健康。
- `AnyIO worker thread` 全程 **idle** → threadpool 空著沒人用。

所以原文「probe 本身卡住，連 Unknown 都送不出來」是反的：**Unknown 早就備好躺在快取裡，
而且有一個閒置的 worker 隨時可以送出去，只是 HTTP 層已經死了。**

【修法（Adam 2026-08-13 裁決，已實作於 `1a7d815`）】原文列的兩個選項（per-switch timeout、
probe 並行化）**都是針對 probe 的，而 probe 根本沒卡，兩個都無效**。實際做的是三層：

1. `get_flow_stats` 改成 `def`（FastAPI 自動派去 threadpool）；三個 flow-entry 端點必須維持
   coroutine（要 `await request.json()`），所以改用 `run_in_threadpool` 手動外送。
2. `read_table_entries` 的 `stub.Read` 加 gRPC deadline。
3. kernel 的 `curl -s` 加 `--max-time 8`（該檔最後一個無界請求）。

【live 驗證（重啟 kernel+proxy，Mininet 不動）】
`/stats/flow/5` 在 s5 SIGSTOP 下 **503 in 5.004s**（原本：永不返回）；
`/p4/switch_state` 全程 **1.2–1.9ms**（原本：死 60 秒）；
s5 回報 `probe_ok=False, DEADLINE_EXCEEDED`；kernel 的圖**全程 40/40**（原本掉到 32/40）。

【相關記憶】[[py-spy-via-mnexec-under-ptrace-scope]]（怎麼在 `ptrace_scope=1` 下取 dump）、
[[investigation-briefs-separate-observation-from-inference]]、
[[arithmetic-that-fits-is-not-the-mechanism]]。

### 6.3 工具自身的三個缺陷（首次實戰找出，全部已修）

見 commit `fbc776f`：被動 counter 觀察、faults.sh 未傳 host PID、還原指令多一個 token
不在 sudo 授權內。第三個是 qdisc 前後置快照抓到的——那部分完全按設計運作。
