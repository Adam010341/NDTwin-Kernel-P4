# SUMMARY：07 的 L1 在心跳下仍然要求 `source: declared`（judge R2 附註）

- **分支**：`fix/07-heartbeat-links-0926`，從 trunk `cafd518a` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-07-hb-links-0926`。
- **Head**：`e012a5a7cb7ab9344e01809f1ae9a3a7d09819c3`，3 個 commit。
- 沒 push、沒 merge、沒碰 lab 也沒碰主 checkout、沒 sudo、沒跑任何 `ndt`。
- 中途因為 ndt-serve 錨點和 08 H5 sampler 兩件優先的事暫停過；閘門是在暫停前跑完的。

[Co-developed with claude code -- Adam]

## 1. 發現（OBSERVED，讀碼）

- 心跳跑起來之後，proxy 的第一個 watchdog pass 會把 8 個宣告方向寫進 `_link_beacons`，並帶上 `source: "heartbeat"`。
- `link_liveness`（`topology_manager.py:2270` 起）先輸出 `_link_beacons`；`declared` 項目只是後面的 `setdefault`，不會蓋掉前面的。
- 所以 07 live 的 `declared_links_marked "$SS" 8` 一定會紅。
- 自測的 fixture 寫的是 `declared`，因此自測看不到這件事。

## 2. 修法

**red first：`7de09bac`**

- fixture 改成心跳在跑時 switch_state 的真實形狀。
- live 路徑改成呼叫一個單一名稱 `l1_links_verdict`；在這個 commit 它仍是舊的檢查，行為不變。
- 自測直接顯示 judge 的發現：`BAD 0 of 8 link entries are declared, want 8 of 8`（SELF-TEST FAIL，8 紅）。

**修正：`e2e28ce4`**

新的 `links_heard <switch_state> <model>` 要求：

- `links` 的 key 正好等於 model 宣告的方向，缺的、多的都會點名；
- 每一個都是 `source: heartbeat`；
- 每個 heartbeat 項目都是 `down: false`。

**為什麼選「全部 heartbeat、8 個都在」而不是「declared 或 heartbeat」**

- 兩種都會數數量；但寬鬆的那種會放過兩種這一行存在就是為了抓的失敗：
  - 心跳根本沒進 proxy：8 個全是 `declared`，等於完全沒有偵測；
  - 報告裡少一個方向：報告整份不可用，所有項目都會留在 `declared`。
- 另外，這裡比對的是 key 而不只是數量，所以一條錯的連線頂替一條缺的連線，也會被抓到。

**時序：`state_until` 最多輪詢 30 s**

- 心跳要到第一個 watchdog pass 才會進 `links`。
- 這一刻最晚可能在 proxy 啟動後一個 watchdog 間隔（5 s）加上 pass 本身的耗時；`ndt up` 一回來就讀一次，可能落在這之前。
- L6 的 capability 檢查改讀輪詢最後那一份 capture。

**適用範圍**

- owned（phase A）和 unbound（phase B，只偵測不改路）兩個 package 都檢查，各用自己的 model。
- 07 不會起 external package，所以不涉及 external。
- header 和 README 都同步說明了。

**閘門：`e012a5a7`，持有 07 L-mutant 的是 `mutate_roles_binding.sh`**

- L7-7 的錨點跟著它所 mutate 的程式碼一起移動；killer 不變，仍是「L1 no link entries」。
- 新增的 mutant：
  - L7-18：多一條沒宣告的連線，killer「L1 an extra link」；
  - L7-19：不再檢查來源，killer「L1 a declared link the heartbeat never fed」；
  - L7-20：接受被報 down 的項目，killer「L1 a link the heartbeat reports down」；
  - L7-21：live 用的那個檢查對什麼都答 OK，killer「…the first cut's all-declared shape」；
  - L7-22：採用「declared 或 heartbeat」的寬鬆規則，killer「L1 the heartbeat never fed the proxy (all declared)」。

## 3. 其他 live-p1 腳本的逐一檢查（OBSERVED＝讀碼；是否會紅＝推論）

判斷依據：會啟動心跳的只有 `ndt up p4 --app` 上外來、非 external、而且有交換機間連線的 package。

| 腳本 | 心跳會跑嗎 | 讀到的斷言 | 會壞嗎 |
|---|---|---|---|
| 01_baseline | 否（NDTwin pipeline） | switch_state 只讀個別 key（mode、package、skipped、entries、probe_ok）；graph 的節點數和邊數對 model | 不會。頂層新增的 `reroute` 和 `heartbeat: null` 沒有任何人比對 |
| 02_app_basic | **會**（basic，unbound，只偵測） | `control_plane.skipped` 的集合（心跳不改它）、每台交換機的 pipeline 和 table_entries、graph 的交換機數和 host 數（不看邊）、`ndt up` 輸出裡的 `NOT CHECKED` 和 entries 那一行（心跳多印的幾行不影響 grep） | 不會 |
| 02b_app_basic_ndtwin_pipeline | 否 | 同 01 的樣式 | 不會 |
| 03_app_p4runtime、04_diag_p4runtime | 否（external） | mode 為 external、skipped、entries、probe_ok；**不打 `/stats/flowentry/*`**，所以 409 那個改動碰不到 | 不會 |
| 05_link_usage_generic | 第 1 組**會**（`--telemetry link`） | off-path 的下限至少是一個 sample（256×1500×8 bit），而一個心跳 sample 只有 256×60×8 = 122,880 bit；on-path 的門檻是 10 kB，而心跳每個介面約 24 B/s | 不會。一個視窗要湊到 25 個心跳 sample 才會跨過下限，期望值大約是 0.02 |
| 06_thirteen（drive_exercise） | 17 臂**會** | 只用 switch_state 產生摘要，不做斷言；link usage 的分析同 05 | 不會。H5 在 live 上實測：26 臂的 rc 和 verdict 都和參照相同 |
| 08_heartbeat | 會 | caps／reroute／hb_state／graph 的邊，都是依心跳寫的；**不檢查 `links` 的 source** | 不會 |

- 我在這些腳本裡沒有找到會比對 switch_state 整體內容或 key 集合的地方。
- **沒改的**：以上沒有任何一個會壞，所以只改了 07。

## 4. 閘門（`logs/gates-0910/*.p4hb07-e012a5a7.log`，全部經 guard）

| 閘門 | 結果 |
|---|---|
| `live07_selftest` | rc 0，`SELF-TEST PASS`（45 ok） |
| `live07_redfirst` | rc 0：在 `7de09bac` 上 FAIL，而且 live 用的檢查對心跳形狀答「BAD 0 of 8…」；在 HEAD 上 PASS |
| `check_gate_anchors` | rc 0，120/120 |
| `mutate_roles_binding` | rc 0，**167 mutations、0 survived**（原本 162，加 5 個新的；L7-7 換了錨點） |

## 5. 沒有跑過的（INFERRED）

- 07 在真機上跑。
- L4 的流量數字，以及 kernel recovery 和 proxy 心跳重新報 up 之間的互動；R2 的 README 已經寫了這一條。

DELIVERED e012a5a7cb7ab9344e01809f1ae9a3a7d09819c3
