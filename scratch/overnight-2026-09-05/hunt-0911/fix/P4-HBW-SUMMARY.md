# SUMMARY：TICKET-P4-heartbeat 段 W（`feat/p4-heartbeat-w-0926`）——veth 心跳偵測＋外來 P4 fabric 自動繞路

- **分支**：`feat/p4-heartbeat-w-0926`，從 trunk `580767a8` 開出。
- **Worktree**：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-w-0926`。
- **Head**：`1a3ebd7f9ffb14ab922e844fb3f7ace7abdf405f`，共 22 個 commit，全部離線完成：
  - 沒 push、沒 merge；
  - 沒碰 lab（沒有任何 `ndt up/down/claim`，沒有 live run）；
  - 沒 sudo、沒編 C++；
  - root helper `tools/test_workflow/ndtwin-lab` 一個 byte 都沒改。
- **規模**：19 個檔案，+5910 −28。其中 5 個是產品碼（proxy 四個、`ndt` 一個），其餘是測試、閘門、live 腳本和 README。
- **可信度標記**：
  - 「OBSERVED」＝我跑過、有 log 的；
  - 「INFERRED」＝讀碼、推導、或沒在真機跑過的；
  - 「讀過未執行」另外列表，不和跑過的混在一起。

[Co-developed with claude code -- Adam]

---

## 1. 做了什麼

### 1.1 proxy 讀心跳報告，用 beacon 的同一條規則判斷

**新模組 `p4_proxy/proxy_agent/link_heartbeat.py`**

它讀 root helper daemon 寫的 `/run/ndtwin-lab/heartbeat.json`。

- **信任規則**（任何一條不過，就判 `heartbeat_report_untrusted`）：
  - 必須是 regular file，用 `O_NOFOLLOW` 開；
  - owner 必須是 uid 0，且 group／other 不可寫；
  - 父目錄同樣檢查；
  - 大小上限 1 MiB。
- **可用規則**：
  - `status == running`，且報告年齡 ≤ 2×period；
  - `period_s` 必須等於 proxy 的 `LLDP_BEACON_INTERVAL_S`，不等就是 `heartbeat_period_mismatch`；
  - 宣告的每個方向都要在報告裡，缺了就是 `heartbeat_fabric_mismatch`。
- **時鐘**：報告用 CLOCK_MONOTONIC，和 proxy 的 `time.monotonic` 是同一個時鐘。

**接入點**

- 報告經由第一刀預留的 `TopologyManager.report_external_link_state(..., source="heartbeat", at=...)` 進來。
- 唯一的呼叫者是 watchdog pass 裡的 `_ingest_link_evidence()`。
- 判斷沿用 beacon timeout 的同一條路：`check_link_beacons`、`_notify_link`，以及同一組常數——`LINK_BEACON_TIMEOUT_S=15`、`LINK_STARTUP_GRACE_S=30`、`LINK_WATCHDOG_INTERVAL_S=5`。沒有新增第二套 timeout。
- **沒有任何 HTTP route 能 POST link state**：proxy 只讀那個 root-owned 檔。

**epoch 規則**

- 新 session：靜默從 `started_mono` 開始算。
- 同一 session 內報告斷過：靜默從 `written_mono` 重新算。

**報告不可用時「凍結」**

- 判斷時間停在最後一次可用的 pass，不會因為 daemon 死掉就把全網判成斷線。
- 如果從來沒可用過，回 `_NOTHING_TO_JUDGE`，什麼都不判。

**每一次 watchdog pass 都留紀錄**

- 內容：`{start_mono, end_mono, down, up}`，時鐘是 proxy 的 monotonic；down／up 是該次 pass 的轉換數。
- 保留最近 12 次，由 `switch_state.heartbeat.watchdog_passes` 提供——這是 orchestrator 09-26 追加要的「watchdog 相位」。

### 1.2 只在 NDTwin 擁有路由表時才繞路

啟動時算出 `routes_blocked`：

- 每一台外來交換機的 `roles.ipv4_route` 都是 `owner: ndtwin` → 值是 `None`，允許繞路；
- 否則沿用第一刀 501 的字彙：`unbound`（任何一台沒有 binding），或 `owned_by_package`。

watchdog pass 裡：

- 若 `routes_to_attached_hosts_only`，就跳過 `install_initial_routes`，log 印 `NOT rerouted`。這就是 detect-only：link 照樣標 down 並通知 kernel，但不改寫任何路由。
- 其餘情況，每次 link 轉換都重新 `install_initial_routes`，走第一刀的 RouteBinding。

### 1.3 能力與揭露（`GET /p4/switch_state`）

**`capabilities`：每台交換機仍是五個 key（GUI 契約，附錄 A 不動）**

`reroute` 和 `link_discovery` 在每次請求時依心跳現況覆寫：

- `reroute: true`：心跳 watchdog 在跑、報告可用、而且全部外來路由表是 NDTwin 的——三者都成立才給。
- `link_discovery`：報告可用時是 `"heartbeat"`，否則是 `"declared"`。

**新增頂層 `reroute: {available, reason, detail}`**

- `reason` 的字彙：
  - 第一刀的 `unbound`、`owned_by_package`；
  - `external_control_plane`；
  - `heartbeat_not_running`、`heartbeat_stale`、`heartbeat_report_untrusted`、`heartbeat_report_unreadable`、`heartbeat_period_mismatch`、`heartbeat_fabric_mismatch`；
  - `heartbeat_watchdog_not_started`；
  - `link_watchdog_not_running`（NDTwin 自己的 pipeline 上 LLDP 沒起來時）。
- 兩個路由原因同時成立時，**先講路由表**：只修好心跳，這個 fabric 仍然不會繞路。

**新增頂層 `heartbeat`**（沒跑心跳的 fabric 上是 `null`）

- 內容：watchdog 狀態、報告路徑、`state`、session／pid／period／報告年齡、方向數、缺少和未宣告的方向。
- `side_effects`：daemon 自己的即時計數。
- `frames_reached_hosts`：把 ruling 4 的停止條件寫成明文，而不是藏在一個數字裡。
- `frame`：0x88B5、60 B、每方向每 period 一個。
- `census`：段 S 的普查結果原樣放上，並附 raw 路徑——26 arms 中 20 有心跳、4 單交換機、2 編不過；主機收到心跳幀的 arm 數 0。
- `watchdog_passes`：見 1.1。
- `note`：心跳證明的是 veth 通，不是交換機活著；link telemetry 會以 1/256 取樣到這些幀。

**`control_plane.skipped` 仍列 `link_watchdog`**

- 指的是 LLDP beacon watchdog，它在外來 fabric 上確實沒跑。
- 心跳 watchdog 是另一個證據來源，在 `heartbeat` 區塊揭露。
- 因此第一刀 M-R10 的測試仍成立，不必改。

### 1.4 ruling 5(a)：external 上的 `/stats/flowentry/*` 回 409

- `add`、`delete`（`delete_strict` 走同一個 handler）、`modify` 三個 handler 都接住 `ControlPlaneReadOnly`，回 409。
- body 與 `POST /p4/table_entry` 的 409 逐字相同：`{"error": "external control plane", "dpid", "message"}`。
- **以前是 FastAPI 的 500。**

### 1.5 `ndt` 生命週期（`tools/test_workflow/ndt`，+126）

**`ndt up p4 --app`**

- 在外來、非 external 的 pipeline 上（`heartbeat_wanted` = `foreign:*` 且非 `external`），於 fabric 起來之後、proxy 之前執行 `sudo -n "$LAB" heartbeat start`。
- 各種 rc：
  - rc 0：印 ok；
  - rc 3（沒有 inter-switch link）：印 info；
  - 其他：warn，**但不讓 bring-up 失敗**——fabric 是好的，缺的只是偵測，而 proxy 的 `reroute` 會說出來。
- 啟動前先記下 `up_started heartbeat`，讓 rollback 知道要收。

**停止**

- `heartbeat_stop_step` 以 pidfile 為閘：沒有 pidfile 就什麼都不問，也不 signal 任何程序；helper 的 stop 自己驗 pid／argv／uid。
- 在三個地方停：
  - `ndt down`：在 topology 之前、proxy 之後；stop 失敗 ⇒ `down_rc=1` 並列入 `not_verified`；
  - rollback：`heartbeat)` case；
  - bring-up 取代既有 topology 時：先停舊的，否則新的 `heartbeat start` 會回 "already running"，而那個舊 daemon 會跟著舊 fabric 一起結束。

**`ndt status`**

- 新增 `heartbeat` 列，直接讀 world-readable 的報告檔，不用 sudo。
- 狀態：running／STALE／stopped／none／unreadable；只要有幀到了主機就點名。

**NDTwin 自己的 pipeline 永遠不啟動心跳**：helper 本身也會拒絕；測試 N02 看過紅。

### 1.6 `live-p1/08_heartbeat.sh`（新，1808 行）＋ README 兩列

只寫好並做了離線自測，**我沒有對 lab 跑過**。細節見第 9 節。

---

## 2. 最壞相位的偵測時間（orchestrator 09-26 note 1／2／4）

**結論先講：嚴格的「≤20 s」在最壞相位上，本設計不保證。** 本設計最壞情況和 LLDP 自己一樣，約 20 s＋ε。我沒有為了讓它過而調整測試。

### 2.1 推導（INFERRED，讀碼得出，沒在真機量）

符號：

- L＝該 cable 最後一次被聽到的時刻（即那一輪的實際送出時間）；
- 切斷時刻 C = L + φ；
- watchdog 迴圈是 `wait(5)` 然後跑一次 pass（topology_manager.py:2086），所以 pass 的週期是 **5 s＋pass 本身耗時 d**，不是嚴格週期。
  - 心跳 daemon 則是嚴格週期（`next_round += PERIOD_S`）。
  - 所以 watchdog 相對於心跳的相位**會漂移**：既不固定，也不均勻。這正是 note 4 說不能假設的東西。
- 偵測發生在第一個滿足 P − L > 15 的 pass P。

偵測延遲（從切斷到 proxy 判定）＝ P − C ∈ (15 − φ, 20 + d − φ]，再加上報告讀取、`_notify_link` 的 HTTP、kernel 更新 graph、以及輪詢的延遲 ε。

- **φ → 0（剛送完就切）是最壞相位**。這時延遲 ≈ 20 + d + ε，會超過 20 s，超出多少取決於 ψ（ψ＝pass 落在 L+15 之後多久，範圍 0～5+d）。
- 只有 ψ ≲ 5 − (d + ε) 時才能守住 ≤20 s。ψ 不在測試的控制之下，是 proxy 自己的時鐘決定的。

**恢復**（note 2）：

- 最長 ≈ 5（等下一輪送出）＋0.5（daemon 聽到後寫報告的最小間隔）＋(5 + d)（等下一個 pass）＋ε ≈ **≤10.5 s＋d＋ε**。
- 在報告層面比段 S 量到的晚約 0.5 s，與 judge 的更正一致。
- 票面上限是 20 s。

### 2.1b 和 orchestrator 轉來的 live 數據對帳

**來源**：orchestrator 09-26 FYI，spike round 8，trunk `094f417f`，raw 在 `doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T085020Z_S_heartbeat`、`…T085506Z_S_heartbeat`。**不是我跑的**，我只做推導上的對帳。

**報告層**

- 偵測（兩個方向都 not-heard）：10.08–14.90 s，和 15 − φ 完全一致。取樣到的最壞相位 φ=0.131 s 時是 14.904 s。
- 恢復：0.57–5.49 s，每一輪都有 0.500 s 的報告延遲。
- 只在一端加 netem 時，只有一個方向變 not-heard——逐方向的語義在 live 上成立。這和 W 逐方向判斷一致：一端掉包，kernel 只會看到那一個方向 down。

**對到 W**

- 偵測 = 報告層 (15 − φ) ＋ ψ（0～5＋d）＋ ε。
  - φ→0 時，報告層就已經是 ≈14.9–14.95 s；
  - 剩下的 ≈5 s 預算要容下一整個 watchdog 間隔，外加 d、`_notify_link` 的 HTTP 和 kernel 更新 graph 的時間；
  - **所以最壞相位下 ≤20 s 正好卡在邊緣**，和 2.1 的推導一致。
- 恢復 = 報告層 (≤5.49) ＋ ψ'（≤5＋d）＋ ε ≈ ≤10.5＋d＋ε，也和 2.1 一致。

**沒有為了讓它過而調任何常數。** 偵測速度的裁決是「和 NDTwin 自己的 fabric 同級」，而那邊用的就是同一組常數。

**08 的相位邏輯**

- 和 spike 的 `hb_watch.py phase-wait` 等價：anchor 取 `last_heard_mono`，目標時刻是 anchor + k·period + offset，且不早於 now + margin。
- 差別在 08 取的是**被切那條 cable 兩個方向**較晚的 `last_heard_mono`，spike 取的是整份報告裡最新的一個。
- 所以沒有另外搬 `094f417f` 的程式；本分支開自 `580767a8`，本來也沒有那個版本。

### 2.2 如果裁決要求最壞相位也嚴格 ≤20 s

選項（INFERRED，未實作）：讓 pass 由「報告被重寫」觸發，不再是 `wait(5)`。

- pass 會和心跳輪次鎖相，落在 L + 5k + δ（δ ≤ 0.5 s），
- 最壞延遲變成 15 + δ − φ ≈ **15.5 s**。
- 代價：proxy 要 watch 檔案；而 LLDP watchdog 與心跳 watchdog 本來共用同一個 pass，就不再共用。

這是設計裁決，我沒有動。

### 2.3 08 怎麼測最壞相位（`0b9af42f` red first → `1a3ebd7f`；照 orchestrator 09-26 的第二份 addendum 重做）

**切斷相位**

- 前 `H1_WORST=3` 個 cycle 切在 `PHI_WORST=0.02` s，也就是從報告的 `last_heard_mono` 推出下一輪的實際送出時刻，再往後 20 ms。
  - 之前是 0.05。改的理由：tc 本身的啟動（sudo、mnexec）會讓 netem 在呼叫開始後 10–30 ms 才生效，所以實際落在送出後 20–50 ms，正是 note 4 要的區間。
  - 兩端的 attach point 在 sleep **之前**先讀好，計畫時刻和第一個 tc 呼叫之間沒有別的東西。
- 其餘 cycle 取隨機相位，seed 會印出來。

**時刻取法**

- 每一端都取 tc 呼叫**前後**的 `$EPOCHREALTIME`，也就是 **bash 自己在這個 process 裡讀的**，不再 fork `date`／`now`。
- tc 是在那個窗口內生效的。
- 換算成 CLOCK_MONOTONIC 用的 offset 在 cycle 前後各讀一次；差超過 2 ms 就標出來。

**逐 cycle 記錄**：`30_cycles.tsv` 每個 cycle 一列（H3 另寫 `64_cycle.tsv`）

- 剪線部分 18 欄：
  - 兩端 tc 的前後時刻；
  - 兩個方向各自最後聽到的幀；
  - φ：從**第一端呼叫開始**起算，所以每個時長都是可能的最長值；
  - graph 的 down 時刻、偵測時間；
  - 前一個 pass，以及讓**兩個方向都** down 的那個 pass——取 graph 顯示前最後一個有 down 的 pass，因為兩個方向的最後一幀差幾 ms 時可能分兩個 pass 報；
  - ψ、pass 超出一個間隔的遲到量、pass→graph 的時間、剪線窗口、時鐘漂移、flags。
- 嚴格 20 s 的答案單獨一欄（`strict_20s`，`yes` 或 `OVER+x`）。
- 復原部分 15 欄：
  - 背景 watcher 盯報告，記下每個方向復原後**第一個**新幀及報告的 `written_mono`；
  - daemon／報告／pass／graph 四個層級的時間，都從第一端呼叫開始算。

**窗口內的幀**

- 落在剪線或自己那一端復原窗口內的幀：**標出來，不丟掉**。
- 在自己那一端的復原開始**之前**就聽到的幀：判 BAD（剪線漏了）。

**判定**（照 orchestrator 的「20 s ＋ 量到的 pass／read／HTTP／kernel 時間」）

- 每個 cycle 有兩個答案，兩個都記：
  - **嚴格的**：≤ 20 s，否則 `OVER+x`，不隱藏；
  - **判定用的**：`v_budget`：
    - ≤ 20 s → OK；
    - ≤ 20 s ＋ pass 遲到 ＋ pass→graph ＋ 剪線窗口 → OK，但訊息寫「OVER the strict 20 s by x, all of it measured」；
    - 超過 → BAD。
- 推導上，在 pass 紀錄齊全時，這個 budget 等價於「超時後的第一個 pass 就報了」。所以另外檢查：**超時之後開始的 pass 沒報就直接 BAD**。
- H1 最後一行會數出幾個 cycle 超過嚴格的 20 s。
- 標為最壞相位的 cycle 若實際 φ > 1 s，照舊 BAD。
- **請看 `watchdog_phase_s`／`pass_lateness_s` 欄**：最壞相位的 cycle 若 ψ 都偏小，表示 ψ 的最壞情況其實沒量到，上界要以 2.1 的推導為準。

**順手抓到的 latent bug（OBSERVED）**

- 5f9316a7 以前的 `graph_until` 裡是裸的 `$T_CUT`，在任何剪線之前根本沒定義。
- `set -u` 之下，H1 的第一個檢查「all eight directions up before the cut」的 subshell 會死掉，judge 拿到空的判定而 FAIL——**在健康的 fabric 上也一樣**。
- red-first 那個 commit 的自測直接看到它：`line 591: T_CUT: unbound variable`。現在改讀 `${T_CUT:-}`，並有 mutant L38。
- 同一輪也修了 `w_finish`：原本在 faults.sh 的 revert 清掉清單**之後**才印「could NOT remove the netem on …」，所以印出來是空的；現在先讀再 revert。

**自測規模**：105 ok，之前是 79。閘門新增 L29–L42，一個行為一個 mutant，每個都看過紅；08 全部 42 個 L mutant 試跑，0 survived。

---

## 3. 心跳引起的 packet-in 不當成 liveness（orchestrator note 3）

**OBSERVED（測試＋mutation）**

- 在心跳 fabric 上，link 的證據**只有**報告。
- 切斷期間，在被切 cable 自己兩個 port 上被 punt 到控制器的心跳幀，只會蓋 `_last_packet_in[device_id]`——那是交換機 stream 活著的證據——不會刷新任何 link 的 `at`。切斷照樣在 timeout 時兩個方向都被判 down。
- 對應測試：`test_heartbeat_watchdog.py::test_punted_heartbeat_frames_do_not_keep_a_cut_link_alive`（commit `3f473d13`）。
  - 它到達時就是綠的，因為這行為本來就存在。
  - 靠閘門 mutation **T19** 看過紅：把 T19 設成「packet-in 刷新它進來的那條 link」，測試就紅。

**INFERRED**：真機上外來 pipeline 會不會把 0x88B5 幀 punt 到 CPU，要看作者的程式；段 S 的普查沒有量這件事。上述結論不論 punt 與否都成立。

---

## 4. 刻意改動的既有測試（兩個第一刀的斷言，另開 red-first commit `6e246f2d`）

1. **`test_route_binding.py::test_an_external_control_plane_refuses_first_as_it_always_did`**
   - 原本：`assertRaises(ControlPlaneReadOnly)`，也就是 FastAPI 回 500。
   - 現在：預期 `HTTPException` 409、`detail.error == "external control plane"`、`__context__` 是 `ControlPlaneReadOnly`。
   - 「external 的拒絕優先於 binding 的 501」和「wire 上是空的」照舊斷言。
   - 原因：ruling 5(a)。
2. **`test_link_state_entry.py`**
   - 原本：`test_nothing_in_the_proxy_calls_it`。
   - 現在：`test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat`（用 AST 掃；唯一呼叫者是 `topology_manager.py::_ingest_link_evidence`，且帶 `source="heartbeat"`）。
   - class 名稱保留，第一刀閘門 TM10 的 killer 仍找得到它。
   - 原因：票面「心跳報告接到第一刀預留的 report_external_link_state」。

另外還有：

- **四個 ndt shell suite 的 STUBS 各加一行**：`HB_PIDFILE`／`HB_REPORT` 指向 fixture 路徑（永遠不存在），避免這台機器上正在跑的心跳把 `heartbeat stop` 塞進 teardown cell、或把一列塞進 status cell。這四個是 `test_ndt_down_claim_guard`、`test_ndt_up_down_robust`、`test_ndt_app_package`、`test_ndt_ovs_claim`。
- **`a62a28b6` 是我自己新測試的儀器修正**：`heartbeat` 這個字會命中 fixture 目錄名，改成數 helper verb；topo-start stub 回填的 bmv2_count 也改掉。

---

## 5. 和票面字面不同、需要裁決的地方

1. **external 上不啟動心跳。**
   - 票面寫「`ndt up p4 --app`（外來 fabric）啟動心跳」。我把 external control plane 排除了。
   - 理由（OBSERVED，讀碼）：external 分支不 seed 宣告的 link（main.py 的 `elif read_only:` 分支，`declared_links=False`），kernel graph 裡根本沒有 inter-switch edge 可標，proxy 也不跑 watchdog。幀會送進別人的 pipeline，卻沒人讀。
   - 後果：
     - H4 斷言「external 上 `ndt up` 沒啟動心跳」；
     - H5 的 `HB_ARMS` 是 17 個 arm，不是段 S 普查的 20 個——少了 p4runtime 的 skeleton／solution 和 flowcache 的 solution。
   - 要改成 external 也偵測（detect-only）的話，需要：ndt 一行、proxy 在 external 上 seed link 並起 watchdog、配套測試、以及改 H4／H5 的預期。
2. **reroute 的原因放在頂層 `reroute.reason`，沒有放進每台交換機的 capabilities**，因為 capabilities 是五個 key 的 GUI 契約。要加每台交換機的 `reroute_reason` 就等於改契約，需要裁決。
3. **偵測上界**：見第 2 節，要不要改成事件驅動的 pass。
4. **07 的 L6 會紅**（INFERRED，沒跑）。
   - 位置：`live-p1/07_roles_basic.sh:68-69` 的 `CAPS_OWNED`／`CAPS_UNBOUND` 寫死了 `reroute:false, link_discovery:"declared"`。
   - merge 之後，`ndt up p4 --app` 會在這兩個 package 上啟動心跳，於是：
     - owned 會變成 `reroute:true, link_discovery:"heartbeat"`；
     - unbound 會變成 `reroute:false, link_discovery:"heartbeat"`。
   - 07 不在我的檔案範圍內，所以沒改。二選一：更新 07 的預期，或讓 07 在心跳停止的狀態下跑。
5. **NDTwin 自己的 pipeline 上 `switch_state` 多了兩個頂層 key。**
   - `reroute`：`{available:true, reason:null, detail:"LLDP and its link watchdog run on this fabric"}`；
   - `heartbeat`：`null`。
   - 這是 JSON 的**加法**，寫入 switch 的內容和 flow stats 仍 byte-identical（見 7 節 `baseline_and_helper`）。如果有任何消費者對 `switch_state` 做整體比對，會看到差異；我沒找到這樣的消費者，但也沒窮舉。

---

## 6. 限制（INFERRED）

- **心跳證明的是 veth 能傳幀，不是交換機活著。** 被 P4PowerStrategy 關掉的交換機仍會被「聽到」。這點已寫進 `heartbeat.note`。
- **`reroutable_down_endpoints` 的豁免也涵蓋單向遺失**：某台交換機所有入向 link 都單向掉包時也適用。這是第一刀既有的形狀，我沒改。
- **detect-only 的 fabric 仍會推 BFS 的目的地路徑**（第一刀行為）。作者自己的靜態表不見得照這些路徑走。
- **link telemetry 會以 1/256 取樣到心跳幀**，所以心跳本身會在 link 使用量上留下極小的痕跡。
- **ruling 4**：我沒有發現任何跡象顯示心跳改變了使用者的轉送結果。但我**沒有在 live 上驗證**；唯一的實測是段 S 的普查（不是我跑的）。

---

## 7. 閘門（head `1a3ebd7f`，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p4hbw-1a3ebd7f.log`）

- 每個 log 第一行是完整 sha，最後一行是真實的 `# rc=<n>`。
- 全部經 `env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`。
- 驅動腳本和 SHA256SUMS 在 `logs/gates-0910/scripts-p4hbw-1a3ebd7f/`。
- 之前在 `d57531d9` 跑過的那一輪（`*.p4hbw-d57531d9.log`）：
  - 跑到 `mutate_ndt_app_package` 時，因為發現 7.1(b)／(c)，我停掉了 driver；
  - 正在跑的那個閘門讓它自己跑完、還原它的 source（`guarded_build: exit 0`，75 mutations、0 survived），但因為 driver 已經停了，那份 log 沒有 `# rc=` 行；
  - 那一輪其餘的 log 都完整，只是被這一輪取代。
- `5f9316a7` 那一輪（`*.p4hbw-5f9316a7.log`）：
  - 跑到 `mutate_roles_binding` 時，orchestrator 的第二份 addendum 到了（08 的時刻取法），我停掉兩個 driver，讓正在跑的閘門自己跑完（162 mutations、1 survived，同 7.1(b)）；
  - 那一輪的 `p4_exercise_suite_at_base` **不算數**：`p4ex_at_base.sh` 只解出 `tools/p4_exercise`，讀 proxy 模組的測試全部 error（failures=8、errors=117），根本不是對照；
  - 本輪改用 `p4ex_at_base2.sh`，把 base 整個 p4_proxy＋tools＋setting 解出來，另外在 HEAD 用同樣的方式跑一次當 control。

四支 driver，全在 `1a3ebd7f` 上跑：
- `final_gates_w.sh`：本輪主體，最後一行 `FINAL-GATES 1a3ebd7f: RED`，原因見 ⚠ 那幾列；
- `_w3`：`FINAL-GATES-3 … ALL-AS-EXPECTED`；
- `_w4`：`FINAL-GATES-4 … ALL-AS-EXPECTED`；
- `_w5`：`FINAL-GATES-5 … ALL-AS-EXPECTED`。

**本段自己的**

| 閘門 | 預期 | 實際 | log 最後一行（`# rc=` 之前） |
|---|---|---|---|
| `p4_proxy_suite` | 0 | 0 | `Ran 1652 tests` / `OK (skipped=1)` |
| `test_ndt_heartbeat` | 0 | 0 | `Ran 57 checks, 0 failed` |
| `live08_selftest` | 0 | 0 | `SELF-TEST PASS`（105 ok） |
| `live08_redfirst` | 0 | 0 | `LIVE08-RED-FIRST: red at the red-first commit, green at HEAD` |
| `mutate_p4_heartbeat_w` | 0 | 0 | `mutation gate: 169 mutations, 0 survived` |
| `class_scan_probe` | 0 | 0 | `CLASS-SCAN-PROBE: every situation answered as it must` |
| `check_test_tmpdirs` | 0 | 0 | `365 file(s) scanned, 0 fixed temp paths` |
| `check_gate_anchors` | 0 | 0 | `120/120 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `red_first` | 0 | 0 | `RED-FIRST: red against the base, as it must be` |
| `baseline_and_helper` | 0 | 0 | `BASELINE-AND-HELPER: helper unchanged and installed; NDTwin pipeline chain green` |

`mutate_p4_heartbeat_w` 的細項：
- 169 個 mutant 分成 P 29、T 24、M 28、A 7、N 39、L 42；
- 97/97 個新 proxy 測試看過紅；
- 57 個 ndt check 裡，除了 12 個具名 control，其餘全看過紅；
- control C1 保持綠；
- 8 個 source 都還原成 byte-identical，root helper 也在其中。

**票面指定的 suite**

| 閘門 | 預期 | 實際 | log 最後一行 |
|---|---|---|---|
| `p4_exercise_suite` | 1 | 1 | `FAILED (failures=1)`：只有 FixtureProvenance（7.1(a)） |
| `p4_exercise_suite_notutorials` | 0 | 0 | `OK (skipped=1)` |
| `p4_exercise_suite_at_base_full` | 1 | 1 | `FAILED (failures=1)`：base 同樣只紅這一個，同樣三個檔 |
| `p4_exercise_suite_at_head_archived` | 1 | 1 | `FAILED (failures=1)`：control |
| `drive_exercise_suite` | 0 | 0 | `OK` |

**所有碰到 ndt 的 shell suite（24 支）**

| 閘門 | 預期 | 實際 | log 最後一行 |
|---|---|---|---|
| ⚠ `ndt_suites` | 0 | **1** | `suites red: 1`：`test_apps_residue.sh` 131 裡紅 2 |
| `test_apps_residue_rerun`（`_w3`） | 0 | 0 | `RERUN test_apps_residue.sh: 0 of 3 run(s) red` |
| `ndt_suites_rerun`（`_w5`） | 0 | 0 | `suites red: 0` |

這一紅的判斷：
- **OBSERVED**：`5f9316a7..HEAD` 對 ndt 和該 suite 的 diff 是空的；之前兩輪（d57531d9、5f9316a7）都是全綠；之後重跑 3＋1 次也全綠。
- `ndt_suites.sh` 的摘錄只抓到名字裡帶 🔴 的 ok 行，沒抓到是哪兩條 FAILED——這是我儀器的缺口，`ndt_suites2.sh` 已補上。
- **INFERRED**：暫時性的，可能和同時間其他 session 的負載有關。我沒有抓到原因。

**既有的 mutation 閘門**

| 閘門 | 預期 | 實際 | log 最後一行 |
|---|---|---|---|
| `mutate_roles_binding` | 1 | 1 | `162 mutations, 1 survived`（7.1(b)） |
| `roles_binding_survivor_check` | 0 | 0 | `ROLES-BINDING-SURVIVOR: the one survivor is the class scan, and only this segment's classes` |
| `mutate_app_package` | 0 | 0 | `48 mutations, 0 survived` |
| `mutate_table_entry` | 0 | 0 | `41 mutations, 0 survived` |
| `mutate_p4_priority_refusal` | 0 | 0 | `9 mutations, 0 survived` |
| `mutate_a7_dispatch_status_python_only` | 0 | 0 | `🔴 PARTIAL: the cpp lane did not run. This is not a full gate result.`（不准編 C++，所以只跑 python 那條） |
| `mutate_path_determinism` | 0 | 0 | `5 mutations, 0 survived` |
| `mutate_telemetry_by_name` | 0 | 0 | `22 mutations, 0 survived` |
| `mutate_ndt_app_package` | 0 | 0 | `75 mutations, 0 survived; 4 control(s), 0 went red` |
| `mutate_ndt_down_claim_guard` | 0 | 0 | `7 mutations, 0 survived; 1 control(s), 0 went red` |
| `mutate_ndt_up_down_robust` | 0 | 0 | `106 mutations, 0 survived, 0 dead` |
| `mutate_ndt_ovs_claim` | 0 | 0 | `39 mutations, 0 survived; 3 control(s), 0 went red` |
| `mutate_ndt_status_check` | 0 | 0 | `20 mutations, 0 survived` |
| `mutate_ndt_honesty` | 0 | 0 | `67 mutations, 0 survived` |
| `mutate_ndt_round_baseline` | 0 | 0 | `26 mutations, 0 survived` |
| `mutate_ndt_up_target` | 0 | 0 | `8 mutations, 0 survived` |
| `mutate_ndt_sudo_surface` | 0 | 0 | `14 mutations, 0 survived` |
| ⚠ `mutate_rule_journal_is_wired` | 0 | **2** | `baseline is RED -- fix that first …` |
| `mutate_rule_journal_is_wired_withmodel` | 0 | 0 | `14 mutations, 0 survived` |
| `mutate_rule_journal_is_wired_at_base`（`_w4`） | 2 | 2 | 同上的 baseline RED，**在 base 也一樣** |
| ⚠ `mutate_p4_rule_install_time` | 0 | **2** | `baseline is RED -- fix that first …` |
| `mutate_p4_rule_install_time_withmodel` | 0 | 0 | `26 mutations, 0 survived` |
| `mutate_p4_rule_install_time_at_base`（`_w4`） | 2 | 2 | 同上，**在 base 也一樣** |
| `mutate_stack_await_convergence` | 0 | 0 | `9 mutations, 0 survived; 2 control(s), 0 went red` |

兩個 rule 閘門 plain 版 rc 2 的原因：
- **OBSERVED**：它們的 baseline 把 `proxy_agent` 複製到暫存目錄，但沒帶 topology model。我照同樣方式重現了一次，12 個測試都是 `TopologyModelError: no P4 topology model in …/setting has 128 hosts`。
- 第一刀也是這樣（`p4r-3ff87a10`、`57aae1bf` 的 plain 版都是 rc 2），所以要用 `_withmodel`（帶 `NDTWIN_P4_TOPO_FILE`）那一版。
- 我把 plain 版在 main driver 裡宣告成 expected 0，所以 driver 最後一行是 RED；base 的對照另外記在 `_at_base` 那兩個 log。

### 7.1 紅閘門的說明：都不是本段的回歸，但 (b) merge 前要裁

**(a) `p4_exercise_suite` rc 1：`FixtureProvenance.test_every_fixture_is_still_byte_identical_to_its_tutorials_original`**

- 紅的是這三個檔：`basic/build/basic.json`、`basic/build/basic.p4.p4info.txtpb`、`p4runtime/build/advanced_tunnel.json`。
- **OBSERVED**：
  - 本分支對 `tools/p4_exercise` 的 diff 是空的。
  - 這台機器的 `~/tutorials/exercises/basic/build/*` 和 `p4runtime/build/*`：
    - 在 d57531d9 那輪時，mtime 是 06:22–06:24Z，落在主 checkout 那次 live-p1 run `2026-09-26T062049Z_06_thirteen` 的時段內；
    - 之後 `basic/build/*` 在 08:55:07Z 又被重寫一次（orchestrator 的 spike round 8 run `…T085506Z` 期間），內容和 fixture 仍然不同，三個檔的 sha256 前綴都不同。
    - 5f9316a7 那輪的 driver 標頭理由只寫了 06:22–06:24Z，因為它是在發現 08:55Z 那次之前啟動的。實際的 mtime 印在 `p4_exercise_suite_at_base` 的 log 裡。
  - 現在的 `basic.json` 帶有 solution 的 parser（`extract ethernet` → `parse_ipv4`），而 fixture 是 skeleton 的空 parser。
  - 同一個 suite 在 `HOME=空目錄` 下（`p4_exercise_suite_notutorials`）rc 0。
  - base 對照：見 GATES_TABLE 的 `p4_exercise_suite_at_base`。
- **INFERRED**：這是 `~/tutorials` 的 build 目錄停在「最後一個跑的 arm」的狀態，不是程式碼的問題。06 會在每個 exercise 目錄裡編 skeleton 再編 solution。我沒碰 `~/tutorials`。

**(b) `mutate_roles_binding` rc 1：「162 mutations, 1 survived」，那 1 個不是 mutant**

- **OBSERVED**：
  - 162 個 mutant 全部 caught；
  - 第一刀的 196 個新測試全部看過紅（196 of 196）；
  - 12 個 source 都還原成 byte-identical。
- 唯一計成 survivor 的是它的 `NEW_CLASSES` 完整性檢查（第 283–287 行）：
  - 它掃**每一個** `p4_proxy/tests/test_*.py` 和 `tools/p4_exercise/tests/test_*.py`，拿來和**第一刀自己的 base `6291db35`** 比，
  - 凡是之後新增、卻不在它 `NEW_CLASSES` 裡的 class，都算它的遺漏。
- 它列出的 18 個 class，和本分支（`580767a8..d57531d9`）新增的 class **逐字相同**：我用同一段 AST 邏輯比對過，`diff` 為空。
- 這 18 個 class 全數在本段閘門的 `NEW_CLASSES` 裡（四個模組用萬用字元），而且 97/97 個測試看過紅。
- **後果**：merge 之後 trunk 上的 `mutate_roles_binding` 會永遠 rc 1。之後任何 ticket 只要新增 proxy 測試 class，都會踩到同一個設計。
- **我沒改它**：那是第一刀的閘門檔，不在我的檔案範圍內。
- **推論 base 是綠的**：「HEAD 的遺漏清單 ＝ 本分支新增的 class」，所以在 `580767a8` 上這個檢查應該沒有遺漏。這是 INFERRED，我沒有在 base 重跑整個閘門。
- 建議的修法（讀碼得出，沒實作）：
  - 把 `now = classes(open(f"{repo}/{rel}").read())` 改成讀一個固定的 `TICKET_HEAD`：`git show $TICKET_HEAD:<rel>`。
  - `TICKET_HEAD` 取最後一次改這個閘門的 commit——在 `580767a8` 上是 `177b9f03`（p4 roles round 3）。
  - 這樣它只檢查自己那一刀新增的 class；其餘不變，judge finding 9 要防的事照樣防得住。
- **這要 orchestrator 裁**：在 merge 前另派一輪修，或是 merge 時接受 rc 1 並附上這段說明。
- 5f9316a7 那輪把它宣告為 expected rc 1，後面緊接一個 `roles_binding_survivor_check`，從**這一輪自己的 log** 驗四件事：
  1. caught 行數 ＝ mutant 數；
  2. `every new test seen red: N of N`；
  3. 所有 source 都還原成 byte-identical；
  4. 被列為遺漏的 class ＝ 本分支新增的 class（當場用 git 和 AST 算，不是抄上一輪的結果）。
- 這個檢查在三份竄改過的 log 上都答 `UNEXPLAINED`（刪掉一個 class、把一個 caught 改成 SURVIVED、把 survivor 數改成 2），也就是它看得到紅。

**(c) 同樣的毛病本段自己的閘門也有，已修（commit `5f9316a7`）**

- `mutate_p4_heartbeat_w.sh` 原本也是拿 working tree 和 `580767a8` 比，merge 後一樣會被之後的 ticket 弄紅。
- 現在改成：
  - 讀 `CLASSES_AT`，預設 `d57531d9`，也就是本段最後一個新增測試 class 的 commit；開發中可以設 `CLASSES_AT=worktree`；
  - pin 不是 HEAD 的祖先時，拒絕（rc 2），不會當成空清單放行；
  - 自帶 control：把 `test_flowentry_read_only` 從清單拿掉時，必須點名 `ARefusedWriteIsA409Test`，否則拒絕。
- `class_scan_probe` 驗了七種情況，全部照預期回答：
  - pin 在 head、worktree 模式：兩者都說沒有遺漏；
  - 少列一個模組：點名那三個 class，1 個 survivor；
  - 非祖先的 pin、pin 在 base：都拒絕；
  - 複本裡多一個「之後 ticket」的 class：**舊的掃描把它列為遺漏，新的不列**。
- 這個修正**只**改閘門裡那一段，不動任何 mutant 或測試。之後 `1a3ebd7f` 又新增了 L29–L42，所以最終的 mutant 數（169）以 `1a3ebd7f` 那一輪的 log 為準。

---

## 8. Commits（`580767a8..1a3ebd7f`，由舊到新）

| sha | 內容 |
|---|---|
| `1b09b14b` | **red first**：proxy 讀報告、beacon 規則、只在 NDTwin 擁有時繞路、external 回 409（新測試 4 模組） |
| `6e246f2d` | **red first**：刻意改動的兩個第一刀斷言（第 4 節） |
| `cd50dfc6` | proxy 實作：link_heartbeat.py、topology_manager、main、api_routes |
| `903ad0e2` | **red first**：ndt 啟動／停止／rollback／status 的心跳 |
| `a62a28b6` | test_ndt_heartbeat 的兩個儀器錯誤，在 ndt 改動之前修 |
| `560ba80f` | ndt 實作 |
| `e5ce6498` | 四個 ndt suite 讀 fixture 路徑 |
| `3f473d13` | 守護測試：punt 上來的心跳幀不算 link 證據（到達時綠；靠 T19 看過紅） |
| `62cd953a` | `08_heartbeat.sh` |
| `940d684e` | live-p1 README 兩列 |
| `57721e02` | test_ndt_heartbeat 每個 check 只命名一次、拿 helper 副本做 pin |
| `08041fa5` | period pin 先把 LLDP 常數移開 5 再讀回 |
| `bb81be28` | **red first**：每次 watchdog pass 都記錄並由 heartbeat 區塊提供 |
| `1f19f9fc` | 實作 pass 紀錄 |
| `1cd1802d` | 08 在 monotonic 時鐘上逐 cycle 記錄、檢查相位有沒有落對 |
| `9d500d28` | 閘門第一次跑發現的四個鑑別力不足的檢查，改尖 |
| `bdcd7889` | `mutate_p4_heartbeat_w.sh` |
| `143e55e8` | 每個 mutant 只用一個 literal anchor（N04／N06／N38） |
| `d57531d9` | 從未可用的 sentinel 補一個能和「照時鐘判」區分的測試（P18b／T08b） |
| `5f9316a7` | 閘門的 class 掃描改讀本段自己的 head（`CLASSES_AT`），避免之後的 ticket 把它弄紅；自帶 control（7.1(c)） |
| `0b9af42f` | **red first**：08 自測加上 in-process 時刻、窗口內 flag、budget、復原紀錄、glue、graph_until 剪線前（對舊 08：SELF-TEST FAIL，19 紅，含 `T_CUT: unbound variable`） |
| `1a3ebd7f` | 08 實作：`$EPOCHREALTIME`、18＋15 欄紀錄、v_budget、復原 watcher、H3 同樣記錄、`${T_CUT:-}`、w_finish 列出未移除的 netem；閘門 L29–L42；README |

---

## 9. H1–H5 需要 orchestrator 做的事

**前置**

1. **merge** `feat/p4-heartbeat-w-0926`（`1a3ebd7f`）。
   - **merge 前先裁 7.1(b)**：第一刀的 `mutate_roles_binding.sh` 在 merge 後會一直是 rc 1。
   - **不需要重裝 helper**：repo 與已安裝的 `/usr/local/sbin/ndtwin-lab` sha256 都是 `6a558fe4…`，見 `baseline_and_helper` log。
   - **不需要改 sudoers**：08 用到的只有 `ndtwin-lab heartbeat start|stop|status`、`mnexec -a 1 tc`，和段 S 同一條路。
2. **從主 checkout 跑。**
   - H5 的參照 `live-p1/runs/2026-09-24T185505Z_06_thirteen/00_table.tsv` 只在主 checkout（untracked）。
   - 在 worktree 跑要帶 `OLD_06=<絕對路徑>`。

**指令**（script 自己 claim、release，snapshot 並還原 knob）

- `NDT_OWNER=<你> bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh`（H1–H4）
- `NDT_OWNER=<你> PART=h5 bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh`（H5：06 一次＋sampler＋01）

**lab 時間（估）**

- H1–H4 約 30–40 min：三次 up、四次 down（最後一次是 teardown），H1 6 個 cycle，H2 hold 30 s。（R2 更正：原本寫「四次 up/down」，judge §9 指出。）
- H5 約 30–35 min：06 參照 run 花了約 27 min，加 01。

**需要的環境**

- `$HOME/tutorials/exercises/basic`；
- `/usr/local/bin/p4c-bm2-ss`；
- 段 S 的 `census_prepare.py`（trunk 上已有）。

**Adam 要做的**：沒有。除非要裁第 5 節那幾題。

**看結果時**

- 先看 `30_cycles.tsv` 的 `strict_20s`、`phi_s`、`watchdog_phase_s`、`pass_lateness_s`、`pass_to_graph_s`、`cut_flags`，以及 H1 最後那行「N of M cycle(s) OVER the strict 20 s」（第 2.3 節）。
  - 最壞相位的 cycle 出現 `OVER+x`，是設計在最壞相位的真實結果，要照實上報；
  - 如果 `OVER+x` 超出「20 s ＋ 量到的時間」，那就是 BAD。
- 任何 `STOP` 開頭的判定＝ruling 4（有幀到了主機），要停下來回報。

**teardown 安全**（段 S round 7 的教訓全數套用）

- 從不宣告 `measuring=`；
- 只有 `ndt down` 回 0／3 才 release；
- 其他情況留住 claim、印出在跑的東西和收尾指令、FAIL 開頭；
- `CLAIM_MINUTES` 在 source `_common.sh` 之前預設 120；
- 沒有 `NDT_OWNER` 就 rc 2 拒絕。

---

## 10. 跑過 vs 讀過未執行

**跑過（OBSERVED，離線）**：第 7 節每一個閘門。

- proxy 全套 1652 tests；
- `test_ndt_heartbeat` 57 checks；
- 08 `--self-test` 105 ok：合成 capture，對每個判定各餵一份應過、一份應敗，外加假 ndt 走 teardown；另有 stub 化的 cut_link／restore_link、背景 watcher、glue；
- 08 在 red-first commit `0b9af42f` 的自測是 FAIL（19 紅），HEAD 則是 PASS；
- 本段 mutation gate：proxy、ndt、08 全部加總 169 個 mutant（以 1a3ebd7f 那一輪的 log 為準）；
- red-first 對 base 的重現；
- helper／baseline 的 byte-identity 鏈；
- ticket 指定的 suites；
- 所有碰到 ndt 的 shell suites；
- 19 個既有 mutation 閘門。

**讀過未執行（INFERRED）**：

- 08 對真 lab 的每一步（H1–H5）；
- 08 新的時刻取法和復原 watcher 在真機上的表現：
  - `sudo -n mnexec -a 1 tc` 的窗口實際多寬；
  - 真 daemon 原子性地改寫報告時，watcher 20 ms 輪詢的表現；
  - `PHI_WORST=0.02` 會不會因為 daemon 送出晚了而切到該輪之前（會的話，那個 cycle 會以「landed … after the last heard frame」BAD 收場，不會靜靜變成較好的相位）；
- 真 daemon 與 proxy 之間的時序（第 2 節全部；orchestrator 轉來的 spike round 8 數字不是我量的）；
- 真 `ndt up p4 --app` 真的會啟動心跳：只用 stub 過的 sudo 驗過呼叫順序和 rc 處理；
- 07 的 L6 會紅；
- 外來 pipeline 會不會 punt 0x88B5。

---

## 11. 環境造成的紅（不是本段的回歸）

**OBSERVED，試跑時，不是正式 log**

- 另一個 session 的 P4 lab 在跑時，下列 suite 在我的 ndt 下是紅的：`mutate_ndt_honesty`(2)、`test_ndt_ovs_claim`(10)、`round_baseline`(6)、`status_check`(5–7)。
- 原因：它們讀到未被 stub 的 `/tmp` manifest。
- 同一時段在 base 的 ndt 下，只有 honesty 是紅的。
- 那個 lab 下線後，用我的 ndt 全綠。

**正式閘門時（1a3ebd7f 那一輪，09:5x–11:4x UTC）**

- orchestrator 最後一次 spike run 的目錄停在 09:03Z，心跳報告最後寫入也是 09:03Z，事後 `ps` 看不到 simple_switch——**推論**當時沒有 lab 在跑。
- 那一輪 `ndt_suites`（10:31–10:36Z）裡 `test_apps_residue.sh` 紅了 2 條，原因沒抓到（見第 7 節）。之後重跑 3 次加 1 次全套，都是綠的。

**另一個觀察（不在範圍內，沒修）**：`p4_proxy/tests/test_link_telemetry.py:73` 用 `tempfile.mkdtemp(prefix="ndtwin_link_pkg_")` 卻不清理。

- 每跑一次 proxy 全套就留一個目錄。
- 正式閘門的 `TMPDIR` 指向 scratchpad，所以這次的殘留在那裡（51 個）。
- `/tmp` 另有 140 個（14:09–15:50 local）。那是我早先沒設 `TMPDIR` 的試跑，加上其他 session 的留下的，分不出各是誰的，我都沒刪。
- 這是既有測試的問題，不是本段造成的；我新增的測試都有 `addCleanup`／`trap`。

---

## 12. Head 與每個閘門 log 的最後一行

Head `1a3ebd7f9ffb14ab922e844fb3f7ace7abdf405f`。log 在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p4hbw-1a3ebd7f.log`，每份第一行都是這個完整 sha。每一行的格式是：閘門名稱、它的 `# rc=` 行，以及 `# rc=` 之前的最後一行。

```
p4_proxy_suite                             # rc=0  [TopologyManager] Refusing delete for DPID 1: neither table can honour ['dl_dst']
  (R2 註：這一行是測試印出的雜訊；真正的摘要是同一份 log 的 `Ran 1652 tests` / `OK (skipped=1)`，judge §9 指出)
test_ndt_heartbeat                         # rc=0  Ran 57 checks, 0 failed
live08_selftest                            # rc=0  SELF-TEST PASS
live08_redfirst                            # rc=0  LIVE08-RED-FIRST: red at the red-first commit, green at HEAD
mutate_p4_heartbeat_w                      # rc=0  mutation gate: 169 mutations, 0 survived
class_scan_probe                           # rc=0  CLASS-SCAN-PROBE: every situation answered as it must
check_test_tmpdirs                         # rc=0  check_test_tmpdirs: 365 file(s) scanned, 0 fixed temp paths
check_gate_anchors                         # rc=0  120/120 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
red_first                                  # rc=0  RED-FIRST: red against the base, as it must be
baseline_and_helper                        # rc=0  BASELINE-AND-HELPER: helper unchanged and installed; NDTwin pipeline chain green
p4_exercise_suite                          # rc=1  FAILED (failures=1)
p4_exercise_suite_notutorials              # rc=0  OK (skipped=1)
p4_exercise_suite_at_base_full             # rc=1  FAILED (failures=1)
p4_exercise_suite_at_head_archived         # rc=1  FAILED (failures=1)
drive_exercise_suite                       # rc=0  OK
ndt_suites                                 # rc=1  suites red: 1
mutate_roles_binding                       # rc=1  mutation gate: 162 mutations, 1 survived
test_apps_residue_rerun                    # rc=0  RERUN test_apps_residue.sh: 0 of 3 run(s) red
roles_binding_survivor_check               # rc=0  ROLES-BINDING-SURVIVOR: the one survivor is the class scan, and only this segment's classes
mutate_app_package                         # rc=0  mutation gate: 48 mutations, 0 survived
mutate_table_entry                         # rc=0  mutation gate: 41 mutations, 0 survived
mutate_p4_priority_refusal                 # rc=0  9 mutations, 0 survived
mutate_a7_dispatch_status_python_only      # rc=0  🔴 PARTIAL: the cpp lane did not run. This is not a full gate result.
mutate_path_determinism                    # rc=0  5 mutations, 0 survived
mutate_telemetry_by_name                   # rc=0  mutation gate: 22 mutations, 0 survived
mutate_ndt_app_package                     # rc=0  mutation gate: 75 mutations, 0 survived; 4 control(s), 0 went red
mutate_ndt_down_claim_guard                # rc=0  mutation gate: 7 mutations, 0 survived; 1 control(s), 0 went red
mutate_ndt_up_down_robust                  # rc=0  mutation gate: 106 mutations, 0 survived, 0 dead
mutate_ndt_ovs_claim                       # rc=0  mutation gate: 39 mutations, 0 survived; 3 control(s), 0 went red
mutate_ndt_status_check                    # rc=0  mutation gate: 20 mutations, 0 survived
mutate_ndt_honesty                         # rc=0  mutation gate: 67 mutations, 0 survived
mutate_ndt_round_baseline                  # rc=0  mutation gate: 26 mutations, 0 survived
mutate_ndt_up_target                       # rc=0  mutation gate: 8 mutations, 0 survived
mutate_ndt_sudo_surface                    # rc=0  mutation gate: 14 mutations, 0 survived
mutate_rule_journal_is_wired               # rc=2  baseline is RED -- fix that first, mutations prove nothing on a red baseline
mutate_rule_journal_is_wired_withmodel     # rc=0  mutation gate: 14 mutations, 0 survived
mutate_p4_rule_install_time                # rc=2  baseline is RED -- fix that first, mutations prove nothing on a red baseline
mutate_p4_rule_install_time_withmodel      # rc=0  mutation gate: 26 mutations, 0 survived
mutate_stack_await_convergence             # rc=0  mutation gate: 9 mutations, 0 survived; 2 control(s), 0 went red
mutate_rule_journal_is_wired_at_base       # rc=2  baseline is RED -- fix that first, mutations prove nothing on a red baseline
mutate_p4_rule_install_time_at_base        # rc=2  baseline is RED -- fix that first, mutations prove nothing on a red baseline
ndt_suites_rerun                           # rc=0  suites red: 0
```

（第一輪交付：DELIVERED 1a3ebd7f9ffb14ab922e844fb3f7ace7abdf405f）

---

## §R2 修正輪（fable judge 對 `1a3ebd7f` 判 MERGE AFTER FIXES 之後）

- **分支與 worktree 同前**：`580767a8` 之後共 31 個 commit；R2 是 `1a3ebd7f..ebdf365e`，9 個。
- **紀律同前**：沒 push、沒 merge、沒碰 lab、沒用 sudo、helper 一個 byte 都沒改，閘門全部經 guard。
- **judge 報告**：`logs/orchestrator-0924/intake-0926/judge-HBW-1a3ebd7f.md`。

### R2.1 做了什麼（OBSERVED＝有 log 或自測；INFERRED 另標）

**F1（blocking）：H1 改以 `strict_20s` 判定**（`93e6d6e5` red first → `8969f4b1`）

- 每個 cycle 的判定改用 `v_strict`：偵測時間從第一端 tc 呼叫算到看到兩個方向都 down 的那次 poll，超過 20 s 就判該 cycle BAD。
- `v_budget`（「20 s ＋ 量到的時間」）降為診斷：
  - 印成 note，並留在 `30_cycles.tsv`，**不再決定任何事**；
  - 「超時後開始的 pass 沒報出這次剪線」仍由 `v_cycle` 自己判 BAD，行為不變。
- `strict_conclude H1` 把「`H1: N of M cycle(s) OVER the strict 20 s … H1 FAILS on the strict <= 20 s until Adam rules on the acceptance`」放在 run **最後一行的開頭**：
  - 若之前已有別的失敗，保留在後面的括號裡；
  - 之後若出現 ruling-4 STOP，STOP 仍排第一。
- 「one run samples one psi … the worst psi is not guaranteed to have been sampled」：
  - FAIL 時用 `bad` 印在 H1 結論處；
  - PASS 時用 note 印；
  - README 也寫了。
- 新自測 `st_h1`：讓一個 stub 過的 cycle 走真的 `cut_cycle` → `strict_conclude` → 真的 teardown（`w_finish` → `finish`，假 ndt），再讀 **run 的最後一行**（judge 8.2）。四個情境：
  - OVER 的 cycle → `FAIL … H1: 1 of 1 …`；
  - 20 s 內的 cycle → `PASS`（control）；
  - 之前已有失敗 → OVER 計數仍在最前面；
  - 之後有 STOP → STOP 排第一。
- 在 `93e6d6e5` 上 SELF-TEST FAIL：OVER 那個情境的 run 以 `PASS 08_heartbeat` 收尾——這正是 F1 的缺陷本身。HEAD 上 PASS，109 ok。
- 順手修了一個儀器錯誤：glue 測試的 note stub 用 `${*:0:110}`，那是按位置切參數，不是切字元。

**F3：第一刀閘門 `mutate_roles_binding.sh` 的 class 掃描改讀 pin**（`9bc85428`，只改這一段，經你授權）

- `CLASSES_AT` 預設為 `177b9f03`；pin 不是 HEAD 的祖先就拒絕（rc 2）；`CLASSES_AT=worktree` 可讀未提交的檔案。
- 自帶 control：把 `test_declared_links` 從清單拿掉時，必須點名它的 class。
- mutant、killer、anchor 一個都沒動。
- **OBSERVED**：`177b9f03..580767a8` 之間這兩個目錄沒有新增任何 test class。
- `roles_scan_probe` 驗了 7 種情況，全數照預期回答（見下表）。

**07 L6**（`45e03902` red first → `44c19391`）

- `CAPS_OWNED` → `reroute:true, link_discovery:"heartbeat"`；`CAPS_UNBOUND` → `reroute:false, link_discovery:"heartbeat"`。
- 自測 fixture 同步改了。
- 第一刀閘門 L7-5 的 killer「`L6 one switch says reroute:true`」保留原字面，現在指的是「unbound 的交換機聲稱會繞路」，比對 `CAPS_UNBOUND`。
- 另加一條「`L6 one owned switch says reroute:false`」。
- 07 在 `45e03902` 上 SELF-TEST FAIL（owned／unbound 兩條紅），在 HEAD 上 PASS。
- 07 的 header 與 README 寫明：L6 需要心跳在跑；L4 的 `inject_link_failure` 下的 netem 也會擋住心跳幀，所以在 owned package 上 proxy 會自己偵測並改路，**L4 記下的流量數字可能會變**（INFERRED，沒跑過）。

**Census 文字**（`207730f0` red first → `4fc40595`）

- `HEARTBEAT_CENSUS["summary"]` 加一句：段 S 的普查是「by hand（用 helper，不是 ndt）」在 20 個 arm 上啟動心跳；`ndt up p4 --app` 只在其中 17 個啟動，另外 3 個（p4runtime skeleton／solution、flowcache solution）是 external control plane，ndt 不啟動。
- 數字和 key 都沒變。
- 新測試在 `207730f0` 上 FAIL，在 HEAD 上 OK。

**契約測試（judge 8.1）：做得到，而且完全不動 helper**（`f8309d02`）

- `p4_proxy/tests/test_heartbeat_contract.py`：
  - 從 helper 切出內嵌的 daemon，切法和 `hb_program` 印出的一樣（兩個 quoted heredoc 標記之間的文字），當 module 載入；
  - 用記憶體裡的 pod-topo plan 和真正編碼過的幀，呼叫 daemon 自己的 `Heartbeat.document()`；
  - 用 daemon 自己的 `write_json_atomic` 寫進暫存目錄；
  - 再交給 proxy 的 `read_report`／`HeartbeatEvidence` 讀。
- 5 個測試：
  - 全部方向都聽到 → usable，每個方向的 `last_heard_mono` 與 daemon 寫的逐一相等；
  - 沒聽到的方向 → 從 daemon 啟動時算靜默；
  - stopped → `heartbeat_not_running`，且帶出 `stop_reason`；
  - 離開 host 埠的幀 → `forwarded_to_hosts` 1（ruling 4 的 key）；
  - writer 留下的檔案模式是 reader 信任的。
- 到達時是綠的（兩個 writer 今天是一致的）。紅由閘門的 K01–K07 證明：只在 mutant 的**複本**裡改 helper 內嵌 daemon 的 key 名、檔案模式、heard 的記錄方式，每一個都讓契約測試變紅。
- helper 本身從沒被寫過；閘門結束時重算 hash，byte-identical。

**本段閘門**（`ebdf365e`）

- 新增 L43–L48、M28、K01–K07。
- 把 `test_heartbeat_contract` 納入閘門；`CLASSES_AT` 移到 `f8309d02`。
- 結果：**183 mutations, 0 survived；103/103 個新 proxy 測試看過紅**。

**SUMMARY 本身的小修正**（judge §9）

- 第 9 節「四次 up/down」改成三次 up、四次 down；
- 第 12 節 `p4_proxy_suite` 的最後一行是雜訊，已加註真正的摘要。

### R2.2 沒做、留給 Adam 裁的（orchestrator 列的「不要做」）

1. **事件驅動的 pass**：最壞約 15.5 s，代價是要 watch 檔案，而且 LLDP 與心跳不再共用 pass 節奏。在 Adam 裁之前，H1 以嚴格 20 s 判——最壞相位很可能 FAIL，照實回報。
2. **external 也做 detect-only**：H5 目前是 17 個 arm；改成 20 個需要 ndt、proxy seed、測試和 H4／H5 預期一起改。
3. **每台交換機的 `reroute_reason`**：這會改五個 key 的 GUI 契約。
4. **`control_plane.skipped` 仍列 `link_watchdog` 的命名**：judge 指出，同一條 thread 其實在跑心跳 watchdog。
5. **ψ 取樣**：一次 run 只取樣到一個 ψ。腳本沒改，只在 H1 結論和 README 寫明「worst psi is not guaranteed to have been sampled」。要取樣，得在 cycle 之間 `heartbeat stop/start` 或多次 `ndt up`。
6. **（judge §3 另提）daemon 死掉 ⇒ 凍結的盲區**：daemon 死掉之後才發生的剪線，會一直留 up，直到 daemon 回來再算 15 s。這段期間會揭露 `heartbeat_stale`。這是設計，要不要接受由 Adam 裁。

### R2.3 orchestrator 的 F2（不是本段的事，記一筆）

- judge 的 F2：orchestrator 在 test merge `a4be233b` 重跑 proxy 全套時紅，原因是那個 worktree 沒有 `p4_src/build`。
- 本輪 `p4_proxy_suite` 在我的 worktree 裡跑，這裡有 `p4_src/build`，所以是綠的。merge commit 上仍要照 `red_first_w.sh:13` 的方式把 build 連過去再跑。

### R2.4 閘門（head `ebdf365e`，log 是 `logs/gates-0910/<gate>.p4hbw-ebdf365e.log`）

- 每份 log 的第一行都是完整 sha，最後一行是 `# rc=`。
- 全部經 `env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`。
- 驅動腳本是 `scripts-p4hbw-ebdf365e/final_gates_r2.sh` 和 `final_gates_r2_part2.sh`，附 SHA256SUMS。
- 主 driver 最後一行是 `FINAL-GATES ebdf365e: RED`。唯一的原因是 `class_scan_probe` rc 1，那是我自己的**儀器錯誤**：
  - probe 腳本把本段閘門的 `NEW_CLASSES` 寫死在腳本裡，R2 把 `test_heartbeat_contract` 加進閘門之後，那份清單就過期了；
  - 閘門本身是對的（`mutate_p4_heartbeat_w` 那行寫著 `NEW_CLASSES names every TestCase class added between 580767a8 and f8309d02`）；
  - probe 改成從 HEAD 的閘門讀 `NEW_CLASSES` 之後，以 `class_scan_probe_fixed` 重跑：rc 0，part 2 的 driver 是 `FINAL-GATES-2 ebdf365e: ALL-AS-EXPECTED`。
- 另外幾項要知道的：
  - `mutate_rule_journal_is_wired` 的 plain 版預期 rc 2（baseline 缺 topology model，base 上也一樣）；真正的閘門是 `_withmodel`，rc 0。
  - `p4_proxy_suite` 是 Ran 1658 tests、OK (skipped=1)，多出的 6 個是契約測試 5 個加 census 測試 1 個。
  - `mutate_roles_binding` 現在是 **rc 0**：162 mutations、0 survived，196/196 看過紅，12 個 source byte-identical，07 self-test baseline PASS，並印出 `NEW_CLASSES names every TestCase class added between 6291db35 and 177b9f03`。

```
p4_proxy_suite                           # rc=0  OK (skipped=1)
test_ndt_heartbeat                       # rc=0  Ran 57 checks, 0 failed
live08_selftest                          # rc=0  SELF-TEST PASS
live07_selftest                          # rc=0  SELF-TEST PASS
r2_redfirst                              # rc=0  R2-RED-FIRST: each red at its red-first commit, green at HEAD
mutate_p4_heartbeat_w                    # rc=0  mutation gate: 183 mutations, 0 survived
class_scan_probe                         # rc=1  CLASS-SCAN-PROBE: BROKEN
roles_scan_probe                         # rc=0  ROLES-SCAN-PROBE: every situation answered as it must
check_test_tmpdirs                       # rc=0  check_test_tmpdirs: 366 file(s) scanned, 0 fixed temp paths
check_gate_anchors                       # rc=0  120/120 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
red_first                                # rc=0  RED-FIRST: red against the base, as it must be
baseline_and_helper                      # rc=0  BASELINE-AND-HELPER: helper unchanged and installed; NDTwin pipeline chain green
drive_exercise_suite                     # rc=0  OK
mutate_roles_binding                     # rc=0  mutation gate: 162 mutations, 0 survived
mutate_app_package                       # rc=0  mutation gate: 48 mutations, 0 survived
mutate_ndt_app_package                   # rc=0  mutation gate: 75 mutations, 0 survived; 4 control(s), 0 went red
mutate_table_entry                       # rc=0  mutation gate: 41 mutations, 0 survived
mutate_telemetry_by_name                 # rc=0  mutation gate: 22 mutations, 0 survived
mutate_stack_await_convergence           # rc=0  mutation gate: 9 mutations, 0 survived; 2 control(s), 0 went red
mutate_rule_journal_is_wired             # rc=2  baseline is RED -- fix that first, mutations prove nothing on a red baseline
mutate_rule_journal_is_wired_withmodel   # rc=0  mutation gate: 14 mutations, 0 survived
class_scan_probe_fixed                   # rc=0  CLASS-SCAN-PROBE: every situation answered as it must
```

**本輪沒重跑的**（沒動到它們的檔案）：
- `ndt_suites` 和所有 `mutate_ndt_*`（`mutate_ndt_app_package` 除外，它的 source 含 `main.py`，已重跑）：本輪沒碰 `ndt`；
- 三個 `p4_exercise_suite*`：`tools/p4_exercise` 沒動；
- `mutate_p4_priority_refusal`、`mutate_a7_dispatch_status`、`mutate_path_determinism`、`mutate_p4_rule_install_time(_withmodel)`；
- `test_apps_residue` 的重跑。

**judge 的建議 6**（merge commit 上重跑 `ndt_suites` 並抓出名字）屬於 orchestrator 的 merge 驗證，我沒在這一輪做；`ndt_suites2.sh` 已能印出紅掉的條目名稱，可以直接用。

---

DELIVERED ebdf365e2ee7f4ad720991e096a5ac606ddd892e
