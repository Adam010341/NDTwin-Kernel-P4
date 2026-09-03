# 決策：P4 平面到底要不要實作 priority？

2026-09-03，`fix/p4-priority-not-silently-dropped`。
**這份文件裡的實作半邊已經做完；決策半邊沒有做，那是 Adam 的。**

---

## 0. 已經改掉的（不是決策，是止血）

`delete_strict` / `modify` 帶著 ipv4_lpm 無法兌現的 priority 時，**不再回 success**，改回
**501** ＋ body 指名原因、`outcome: "unsupported_on_p4"`，而且**在寫交換機之前就拒**。
`add` 沒動——維持既有的 `priority_honoured` 揭露。

為什麼只拒兩個動詞，理由在 §2。這裡先講清楚**這個改動沒有回答的問題**：它只讓謊話停止，
沒有讓 priority 變成可用的功能。使用者要的東西仍然拿不到。

---

## 1. 現狀：兩個平面現在真的不一樣

| | OVS／HTTP 平面 | P4／bmv2 平面 |
|---|---|---|
| install 帶 priority | `HttpRoutingStrategyBase.cpp:295-300`、`:313` 寫進 body，Ryu 照做 | 目的地-only ⇒ `ipv4_lpm`，**無 priority 欄**，`priority_honoured: false` |
| 疊規則 | priority 100 **疊在** router 的 priority 10 上面 | **取代**該目的地唯一那筆（`topology_manager.py:816` docstring 自己寫了） |
| 刪掉上層規則 | 露出下面那筆 | 下面沒有東西；`unroute_flow` 只好**重算控制平面路由塞回去**（A-4d） |
| delete/modify 指名 priority | strict 比對 priority，不存在就 no-op | 以前：照做在別人身上。**現在：501** |

五元組匹配（`needs_five_tuple`）走 `flow_5tuple` 三元表，priority **是真的**——
`p4_client.py:736-740` 直接 `entry.priority = int(priority)`，而且是 entry 身分的一部分。
所以「P4 沒有 priority」是錯的說法：**P4 有一半的 priority**，缺的是目的地-only 那條路。

---

## 2. 為什麼 install 揭露、delete/modify 拒絕（我畫的線，可以推翻）

同一個 `priority` 欄位在三個動詞裡是兩種東西：

- **install ⇒ 優先序（precedence）**。規則有裝進去、有在轉發，掉的是層次。回應已經講了
  （`priority_honoured: false` ＋ `priority_note`），而且 T-15 Option 0／2026-08-30 §1.2
  已經裁過「不能改成 4xx」。**我沒有推翻那個裁決。**
- **delete_strict / modify ⇒ 身分（identity）**。priority 指的是「哪一筆」。ipv4_lpm 一個
  目的地一筆、沒有 priority 欄 ⇒ **任何 priority 都指到同一筆**。昨晚量到的 777／999
  就是這個：改／刪了一筆呼叫者從來沒有指名的規則。**這個沒辦法用揭露補救**——等使用者
  讀到 body，那筆規則已經不在了。

狀態碼選 **501 而不是 400**：請求是合法的 OpenFlow，沒有任何一個欄位是呼叫者寫錯的。
回 400 等於把責任推給呼叫者，這正是 `OpResult::notSent`（`OpResult.hpp:78-98`）當初被加出來
要停止的那種誤指。501 講的是「這個資料平面沒有實作」，和六個 group/meter 端點是同一個意思，
所以直接沿用它們的形狀（`P4RoutingStrategy.cpp:11-23`）。

**拒絕放在 proxy 不放在 kernel**：只有 proxy 知道一個 match 會編到哪張表
（`needs_five_tuple`）。在 kernel 複製一份等於製造 A-7 註解明講要避免的漂移。
Kernel 不用改：`post` 把非 2xx 變成 `OpResult::failure`、`HttpSession` 400..599 直通，
flow 路徑則記成 `failed+1`＋`recent_failures` 裡的原因，不再進 `succeeded`。
（**代價**：`outcome` 欄位在 kernel 端是空的——501 的原因在 message 字串裡而不是結構化欄位。
要一模一樣的 `outcome: "unsupported_on_p4"`，是 `HttpRoutingStrategyBase::post` 的一行後續，
我沒做，因為那要動 C++ 並重編。）

---

## 3. 決策：P4 要不要真的實作 priority？

### 使用者現在失去什麼

不是「priority 這個欄位沒用」，是**分層式流量工程整套不能用**。TE／Energy-Saving 在 OVS 上
的做法是「在 router 的 base rule 上面疊一條高 priority 的遷移規則，做完拆掉就自動回原狀」。
在 P4 上這個模式**不存在**：疊 = 覆蓋，拆 = 目的地變成沒有規則（所以才要有 A-4d 的
restore hack，那個 hack 本身就是這個缺口的補丁）。連帶：不能做 A/B 兩條規則共存、不能做
「暫時性 override，到期回退」、不能對同一目的地做多條不同來源的策略疊加。
兩個平面的實驗結果因此**不可直接比較**——這是論文層級的問題，不只是 API 的。

而且現在多了一個新的可見代價：昨天還會「成功」的 delete/modify（雖然是做在錯的規則上），
今天會 501。任何依賴那個假成功的腳本會壞掉——這是對的，但它是行為改變。

### 選項

**A. 維持不支援，只保留現在的誠實**（已完成的狀態）
成本 0。使用者要分層就必須把 match 寫成五元組，讓規則落到 `flow_5tuple`（那裡 priority 是
真的）。缺點：`ipv4_lpm` 這條路永遠是二等公民，而它是控制平面自己寫規則的那條路。

**B. 把目的地-only 的規則也導進 `flow_5tuple`**（我的建議）
`flow_5tuple` 是三元表，已經在 pipeline 裡、已經在 `ipv4_lpm` 前面、已經有 priority 而且
`p4_priority()` 的 OpenFlow→P4Runtime 映射也已經寫好。要做的是讓 `route_flow`／`unroute_flow`
／`modify_flow` 在「呼叫者指名了 priority」時走三元分支，即使 match 只有目的地
（三元表對其他 key 用 don't-care）。
**Blast radius**：`topology_manager.py` 三個方法的分支條件、`_installed_routes` 的
鍵（現在是 `(dpid, ipv4_dst)`，五元組規則故意不寫進去 ⇒ `render_destination_paths` 會變瞎，
這是最大的一塊）、`rule_journal` 的重播、`install_initial_routes` 的重寫時機（它現在無條件
覆蓋每個 (switch, host) entry，會把使用者疊的規則沖掉）、`ryu_flow_stats` 的讀回、
`delete` 的 A-4d restore 語意（有了層次就不需要 restore 了，要拆掉）。
**沒有動到的**：kernel、P4 程式碼、pipeline 重編——這是選 B 的理由，它全部在 Python 裡。

**C. 給 `ipv4_lpm` 真的加 priority**
P4 的 LPM 表沒有 priority 欄，這是 P4Runtime 規格不是實作偷懶。等於改 `ndtwin_switch.p4`
的表定義、重編 pipeline、重推每一台 bmv2、改 `p4_client` 的 entry 建構。
**不建議**——B 用現成的表拿到同樣的東西。

### 建議

**B**，但**不是現在**。理由：B 的真正成本不在寫 priority，在
`_installed_routes` / `render_destination_paths` 要長出「同一個目的地有多筆規則」的概念，
那是 twin 的資料模型改動，不是路由改動。在論文量測期間動它風險太高。
所以：**現在收下 A（已完成），把 B 排進 Phase 4 和 ECMP selector 一起做**——兩者都要動
`flow_5tuple` 和同一組分支，分兩次做等於付兩次錢。

同時請 Adam 裁一件小的：**install 那半邊要不要也改成拒絕？**
我沒有動它，因為 T-15 Option 0 是既有裁決，而且 install 至少有裝進去、有在轉發，拒絕它的
blast radius 比 delete/modify 大得多（每個帶 priority 的 app 安裝都會 501）。
但它確實仍然是「使用者以為在疊、實際在覆蓋」的那個入口。
mutation 7 就是釘這件事的：有人把拒絕擴大到 install 時，會有測試變紅並指向這個裁決。

---

## 4. 證據

- 缺陷量測：`doc/audit/2026-09-03_night-rounds/round5-topology-repro/`、`round4-traffic-measurement/`
- 先看紅：`doc/audit/2026-09-03_night-rounds/priority-refusal/red-before-fix.log`
  （6 紅：3 FAIL ＋ 3 ERROR，修完 23/23 綠）
- Mutation gate：`tests/shell/mutate_p4_priority_refusal.sh`
  ⇒ `doc/audit/2026-09-03_night-rounds/priority-refusal/mutation-gate.log`，
  **7 mutations, 0 survived**，rc=0。1-3 證明「該拒的有拒」，4-7 證明「不該拒的沒拒」——
  單邊的 gate 會讓「全部都拒」通過。

## 5. 未做 / 已知限制

- **沒有 live 驗證**：這一輪沒有拿 lab（另一個 agent 持有），全部是 handler 層直呼測試。
  501 走完 kernel 到 `/ndt/` 呼叫者的那段是**讀碼推論**，不是量過的。
- **C++ 沒有編**：本輪沒有動 C++，`build-priority/` 沒有建。
- `outcome` 欄位止於 proxy body，見 §2 末。

[Co-developed with claude code -- Adam]
