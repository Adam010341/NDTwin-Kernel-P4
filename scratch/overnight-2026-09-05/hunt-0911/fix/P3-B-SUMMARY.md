# TICKET-P3 工單 B — fabric bring-up（link telemetry＋G2-C＋telemetry knob／package 欄位）

worker B；worktree `scratch/overnight-2026-09-05/wt-p3-fabric-0919`，branch
`feat/p3-link-telemetry-0919`。

- **base**：`8eddb0e8`
- **round 1 head**：`40868006`（fable-judge 裁 **MERGE AFTER FIXES**，verdict 存 `P3-B-JUDGE.md`）
- **round 2 head（現在的 head）**：`80c97464`
- gate log：round 1 的在 `…/logs/gates-0910/<gate>.p3b-40868006.log`，
  round 2 的在 `…/logs/gates-0910/<gate>.p3b-80c97464.log`。**兩輪都留著。**
- **§1–§7 是 round 1 的交件，數字保持原樣**（只有 judge 指出算錯／寫錯的地方就地更正，
  每處都標了「round 1 …，judge 指出」）；**round 2 的全部在 §8**。
- **沒有 push、沒有 merge、沒有動主 checkout、沒有 commit 未追蹤的工單副本。**

[Co-developed with claude code -- Adam]

---

## 1. commit（round 1：base `8eddb0e8` → `40868006`，六顆；round 2 的兩顆在 §8.5）

| sha | 內容 |
|---|---|
| `bb5fda2d` | §2.1／§2.4 的**讀法**：`telemetry.source`、`telemetry_override`、`telemetry_source()`、`shaped_links()`，＋`mutate_app_package.sh` 續號 M48（M-B12） |
| `b4b7849d` | 新模組 `link_telemetry.py`＋`psample_sflow_emitter.py`＋兩支離線測試 |
| `7a54d027` | bring-up 的**接線**：`build_net` 的 TCLink、per-cable `bw`/`delay`、telemetry 生命週期、`tear_down`、新 gate `mutate_link_telemetry.sh` |
| `2f88c0e6` | gate 的 N2 控制組標籤印出字面 `'\''`（純字串） |
| `8730b618` | emitter 改成寫自己的 log，不繼承 topology 的 fd 1／2（見 §5 異議-0，這是我在寫 summary 前自己抓到的 defect） |
| `40868006` | `test_link_telemetry` 三個字串不再長得像固定 `/tmp` 路徑（`check_test_tmpdirs` 靜態檢查） |

---

## 2. 閘門與測試（每個數字都來自實跑；指令、rc、最後一行）

全部在 `cd <worktree>`、`p4_proxy/venv/bin/python`、跑前清 `__pycache__`。

| 項目 | 指令 | rc | 最後一行 |
|---|---|---|---|
| p4_proxy 全套（34 模組） | `cd p4_proxy && PYTHONDONTWRITEBYTECODE=1 ./venv/bin/python -m unittest $(ls tests/test_*.py \| sed 's#tests/##; s#\.py##; s#^#tests.#')` | 0 | `Ran 1205 tests in 17.305s` / `OK (skipped=1)` |
| `mutate_link_telemetry.sh`（新） | `bash tests/shell/mutate_link_telemetry.sh` | 0 | `mutation gate: 15 mutations, 0 survived`（前一行 `baseline byte-identical: yes (4 sources, 4 test files)`） |
| `mutate_app_package.sh`（舊的全殺＋M48） | `bash tests/shell/mutate_app_package.sh` | 0 | `mutation gate: 48 mutations, 0 survived`（前一行 `baseline byte-identical: yes (10 sources, 7 test files)`） |
| `test_topo_from_json.py` | `./p4_proxy/venv/bin/python tools/test_workflow/test_topo_from_json.py` | 0 | `PASS -- derived wiring is identical to the hard-coded lists` |
| `merged_checks.sh <head> 1` | `bash scratch/overnight-2026-09-05/hunt-0911/drivers/merged_checks.sh 40868006 1` | 0 | `MERGED-CHECKS 40868006 r1: ALL-GREEN` |
| `check_gate_anchors.py`（**我的 worktree、我的 sha**） | `./p4_proxy/venv/bin/python tests/shell/check_gate_anchors.py 40868006` | 0 | `111/111 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `check_process_by_name.py`（紅線 1 的掃描器，我的 worktree） | `./p4_proxy/venv/bin/python tests/shell/check_process_by_name.py` | 0 | `check_process_by_name: 303 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` |
| `check_test_tmpdirs.py`（我的 worktree） | `./p4_proxy/venv/bin/python tests/shell/check_test_tmpdirs.py` | 0 | `check_test_tmpdirs: 336 file(s) scanned, 0 fixed temp paths` |

**`skipped=1` 是什麼**：`tests.test_p4_client.LiveSwitchTest.test_installs_routes_and_the_clone_session`
——既有的 live-switch opt-in（`NDTWIN_LIVE_SWITCH_OPT_IN=1`），與本工單無關，base 上就是 skip。

**`merged_checks.sh` 量的是主 checkout 的 `HEAD`（＝trunk），不是我的分支**：它自己
`cd /home/adam/Desktop/NDTwin-Kernel` 且把字面 `HEAD` 傳給 `check_gate_anchors.py`（§2.7 要 D 修的那條）。
所以它的 `110/110` 不含我的新 gate；**分支上的值是上表第六列的 `111/111`**，那是我在自己的
worktree 對 `40868006` 跑的。兩個都附 log。

### 各測試檔的規模（實跑；base 欄＝把 `8eddb0e8` 的測試檔取出來跑一次量到的）

| 檔 | Ran | 新增 |
|---|---|---|
| `p4_proxy/tests/test_link_telemetry.py`（新） | 41 | 41 |
| `p4_proxy/tests/test_psample_sflow_emitter.py`（新） | 32 | 32 |
| `p4_proxy/tests/test_fabric_bring_up.py` | 88 | +36（base 52） |
| `p4_proxy/tests/test_app_package.py` | 119 | +27（base 92） |
| `p4_proxy/tests/test_bmv2_binary_override.py` | 13 | 0（未動） |

---

## 3. 變異表（哪個變異被哪顆測試殺）

`mutate_link_telemetry.sh`：**15 mutations, 0 survived；2 控制組 green**。

| # | 變異 | 殺它的測試 |
|---|---|---|
| M-B1 | egress 濾器掛到每個埠（不只 host-facing） | `test_ingress_on_every_port_and_egress_on_host_facing_ports_only` |
| M-B2 | ifindex 對映用全 32 位元（碰撞檢查失效） | `test_the_map_is_keyed_on_the_low_sixteen_bits_psample_reports` |
| M-B3 | `inNamespace` 檢查拿掉 | `test_a_switch_in_its_own_namespace_is_refused` |
| M-B4 | emitter 早死不 fatal | `test_a_fabric_whose_emitter_exited_is_refused` |
| M-B5 | `telemetry_source` 忽略 knob | `test_the_knob_outranks_the_packages_own_declaration` |
| M-B6 | `auto` 對外來 pipeline 回 cooperative | `test_auto_sends_a_foreign_pipeline_down_the_link_path` |
| M-B7 | TCLink 對無整形 package 也開 | `test_a_package_that_shapes_nothing_is_also_the_call_it_has_always_been` |
| M-B8 | `bw` 單位用 bps 不換 Mbps | `test_a_bottleneck_is_reported_in_megabit_with_its_endpoints` |
| M-B9 | egress 樣本 `ingress_port` 填成埠號 | `test_an_egress_sample_fills_the_egress_port_and_leaves_ingress_zero` |
| M-B10 | emitter 的 `frame_length` 用 `len(DATA)` 不用 ORIGSIZE | `test_the_frame_length_is_origsize_and_not_the_captured_length` |
| M-B11a | tear_down 不 detach **也不停 emitter**（整個 `shut_down` 換 `pass`；比工單粗，round 2 改名） | `test_the_qdiscs_come_off_before_the_net_is_stopped` |
| M-B11b ‡ | **工單字面的那顆**：emitter 照停、manifest 照刪，只把 detach 拿掉 | `test_it_stops_the_pid_the_manifest_names_and_detaches_every_interface` |
| M-B13 † | emitter pid 不查 `/proc` 就送信號（pid 回收） | `test_a_pid_that_is_no_longer_the_emitter_is_not_signalled` |
| M-B14 † | 別人 group 的樣本算成本 fabric 的 | `test_a_sample_from_another_groups_filter_is_dropped_and_counted` |
| M-B15 † | `tc` 失敗被忽略（fabric 只量到自己的一半） | `test_a_tc_that_failed_stops_the_bring_up_rather_than_half_measuring` |
| M-B16 † | emitter 繼承 fd 1／2（見異議-0） | `test_it_is_launched_onto_its_own_file_and_this_process_keeps_no_descriptor` |
| N1 | `_commands` 上面只加註解 | 全綠（控制組） |
| N2 | 樣本方向判斷處只加註解 | 全綠（控制組） |

† 工單 §4.3 沒列，理由寫在 gate 裡該條旁邊。
‡ round 2 新增（judge：round 1 的 M-B11 比工單粗，「只拿掉 detach」那顆沒跑過）。

`mutate_app_package.sh` 續號：**M48（M-B12）loader 接受值域外的 `telemetry.source`**
⇒ `test_a_word_outside_the_domain_is_refused_by_name`。舊的 M1–M47 全部仍 caught，
三個控制組仍 green（`48 mutations, 0 survived`）。

### 宣告為「等價、故意不做」的變異（寫在 gate 檔頭，不是默默省略）
1. **每台一個 psample group**：方向已經在 kernel 選的 attribute 裡（IIFINDEX vs OIFINDEX，
   09-17 實測），ifindex 已經指名交換機 ⇒ per-switch group 不帶任何新資訊，兩邊都會綠。
   真正被斷言的是「非本 fabric group 的樣本被丟掉**並計數**」（M-B14）。
2. **`LINK_SUB_AGENT_ID` 改回 0**：kernel 用 `AgentKey{agentIP, port}`，根本不讀 sub-agent id
   ⇒ 下游分不出來。用普通斷言釘住（`test_this_path_says_it_is_sub_agent_one`），不用變異。

---

## 4. orchestrator live 要看的東西

### 4.1 manifest
- **路徑 `/tmp/ndtwin_link_telemetry.json`**（`link_telemetry.LINK_TELEMETRY_MANIFEST`）。
  bring-up 寫、tear_down 刪；tempfile + `os.replace`，每次都是新 inode。
- 鍵：`pid`、`log`、`rate`(256)、`trunc`(128)、`group`(27)、`ifindex_width`(16)、
  `collector` `["127.0.0.1", 6343]`、`sub_agent_id`(1)、
  `switches[]`＝`{dpid, name, agent_ip, ports:{"<port>": {ifname, ifindex, key, ingress, egress}}}`、
  `tc_commands[]`（實際跑過的每一行）。
  🔴 **`key` 才是 emitter 查表用的 `ifindex & 0xFFFF`；`ifindex` 是完整值，只供人看。**
- C 的 `switch_state.control_plane.telemetry.link_emitter` 要讀的就是這個檔；
  D 的 `ndt status`／`verify_p4` 同。`alive` 判準建議用
  `link_telemetry.process_is_the_emitter(pid)`（讀 `/proc/<pid>/cmdline`），不要只看 `/proc/<pid>` 存在。

### 4.2 emitter 的輸出在哪、長什麼樣
- **`/tmp/ndtwin_link_telemetry.log`**（`link_telemetry.LINK_TELEMETRY_LOG`，manifest 的 `log` 鍵）。
  **不是 topo.log**——見異議-0：emitter 若繼承 topology 的 fd 1／2 會把 `topo_log.Tee.stop()`
  卡住五秒並且每十秒往 NTG prompt 噴一行。像 bmv2 一樣寫自己的檔。
- 起來第一行（stderr）：
  ```
  psample_sflow_emitter: manifest /tmp/ndtwin_link_telemetry.json, 10 switch(es), group 27, rate 256, joined psample/packets (id 29), netns net:[4026531840]
  ```
- **統計行，每 10 s 一行，退出前再一行**（`--stats-interval` 可改）。欄位順序固定、全部 `k=v`：
  ```
  psample_sflow_emitter: samples=1203 emitted=1200 dropped_unknown_ifindex=3 dropped_no_direction=0 dropped_ambiguous_direction=0 dropped_no_origsize=0 dropped_other_group=1 dropped_decode_error=0 emit_failed=0 enobufs=0 per_switch=s1:2,s2:1 elapsed=10.0s
  ```
  🔴 **`samples` 不是全部十個計數器的和**，對帳時別加錯（round 1 的範例就是加錯的，judge 抓到）：
  `dropped_other_group` 與 `dropped_decode_error` 在 `samples += 1` **之前**就丟了，
  所以不變式是
  **`samples = emitted + emit_failed + dropped_unknown_ifindex + dropped_no_direction
  + dropped_ambiguous_direction + dropped_no_origsize`**
  （上面那行：1200 + 0 + 3 + 0 + 0 + 0 = 1203），
  而 `dropped_other_group`／`dropped_decode_error` 是**額外**的、進不了那個和。
  - `per_switch` 是**成功送出**的樣本數，`s<dpid>:<n>` 逗號分隔，沒有就是 `-`。
  - 第一次 live 要看的：`samples` 有在長、`emitted ≈ samples`、
    **`dropped_unknown_ifindex` 應該是 0**（不是 0 ⇒ ifindex 對映錯或有別人的濾器）、
    `enobufs` 應該是 0（不是 0 ⇒ 樣本量超過 8 MB 接收緩衝，要降 rate）。
- **EPERM 的訊息把三件事一起講**（CAP_NET_ADMIN／必須同 netns／其他都不需要權限），
  因為只講「permission denied」的話，操作者修好權限後仍然收不到樣本時無從查起。

### 4.3 tc 指令列（逐字；4 主機 10 台模型、`--telemetry link`）
每個埠一條 `clsact`＋一條 ingress 濾器；**只有 host-facing 埠**多一條 egress：
```
tc qdisc  add dev s1-eth1 clsact
tc filter add dev s1-eth1 ingress matchall action sample rate 256 group 27 trunc 128
tc qdisc  add dev s1-eth2 clsact
tc filter add dev s1-eth2 ingress matchall action sample rate 256 group 27 trunc 128
tc qdisc  add dev s1-eth3 clsact
tc filter add dev s1-eth3 ingress matchall action sample rate 256 group 27 trunc 128
tc filter add dev s1-eth3 egress  matchall action sample rate 256 group 27 trunc 128
```
（實際輸出沒有把 `qdisc`/`filter` 對齊，上面加空白只為好讀。）
- 全 fabric：**76 條**（36 clsact＋36 ingress＋4 egress），bring-up 那行印
  `link telemetry: 10 switch(es), 36 ingress + 4 egress filters, emitter pid <n>`。
- 拆：每個介面一條 `tc qdisc del dev <ifname> clsact`（刪 qdisc 就刪掉它的濾器），共 36 條。
- emitter argv：`<sys.executable> <mininet>/psample_sflow_emitter.py --manifest /tmp/ndtwin_link_telemetry.json`。
  live 下 `sys.executable` ＝ `$NTG_PY`（`/home/adam/miniconda3/envs/ntg-env/bin/python`），
  沒問題：`proxy_agent/sflow_emitter.py` 只用 stdlib。
- **關掉時的一行**：`link telemetry: off (no switch is on the link path (10 cooperative))`。

### 4.4 live 第一輪建議的次序
1. `ndt up p4 4`（沒有 `--telemetry`）⇒ 應該逐格同 baseline，bring-up 那行是 `off (... 10 cooperative)`，
   **沒有** `/tmp/ndtwin_link_telemetry.json`、**沒有** tc、**沒有** emitter。
2. `ndt up p4 4 --telemetry link` ⇒ 看 §4.1／§4.2／§4.3 三處。
3. `ndt down` ⇒ manifest 不見、`tc qdisc show dev s1-eth1` 沒有 clsact、emitter pid 不在。
4. 🔴 **跑 `--telemetry link` 的數值結論之前，先確認工單 A 已經併回且 kernel 重建**——見異議-1。

---

## 5. 異議／objections

### 異議-0（我自己的檔內就修掉了，但併回時要知道）：emitter 不能繼承 topology 的 fd
`ntg_bmv2_topo.py` 跑在 `topo_log.Tee` 底下，那是 **fd 層級**的 tee（`os.dup2` 把 pipe 放到 fd 1／2，
一條 pump thread 抽）。`Tee.stop()`（NTG prompt 之前要呼叫，因為 prompt_toolkit 對 pipe 會退成純文字）
靠「**最後一個 write end 消失 ⇒ pump 讀到 EOF**」結束，而它自己的註解寫明了前提：
「this process owns them all -- Mininet gives its node shells their own pipes and bmv2 is launched
with `> /tmp/sN_bmv2.log 2>&1`」。**emitter 繼承 fd 2 就是第四個持有者**：pump 永遠等不到 EOF、
`stop()` 每次 bring-up 白燒五秒 join，而且 emitter 的統計行會透過 pump 每十秒打到操作者的 NTG prompt 上，
直到 fabric 收掉為止。已改成像 bmv2 一樣寫自己的檔（`8730b618`，M-B16 守）。
**寫在這裡是因為：任何以後要從 bring-up 起子行程的人都會踩到同一顆。**

### 異議-1（🔴 跨工單順序，最重要的一條）：B 先併、A 後併的話，host-facing 邊會是**錯的**，不是缺的
§2.2 第一條要我在 host-facing 埠掛 egress 濾器 ⇒ 產生 `inputPort == 0 && outputPort != 0` 的樣本。
§2.2 第二條要 A 把那種樣本只記進 `m_egressCounterReports`。**A 還沒改之前**，
`FlowLinkUsageCollector` 今天那條死分支會把它記進 `m_counterReports`
（工單 §1.3／§1.1：`relevantPort = isIngress ? inputPort : outputPort`，而 `isIngress = (inputPort != 0)`），
也就是**算到反向那條邊上**。
⇒ **B 單獨併回後，`--telemetry link` 下：**
- **host→switch 那條邊被灌高**（多了本來該記在對向的位元組），
- **switch→host 那條邊恆為零**（egress 銀行從來沒被寫進去，`creditHostBoundEgressEdges` 沒東西可付）。

**round 1 這裡寫「兩條邊互相污染」是高估**（judge 指出）：污染是**單向**的，
一邊被灌高、另一邊是零，不是互相。結論不變——這不是「少量到」，是「量錯」，
而且 twin 上看起來完全正常。
**請求 orchestrator：`--telemetry link` 的任何 live 讀數（含 §2.7 的通用格、§2.8 的 B 組）
都要等 A 併回、kernel 用 guard 重建之後才取。** 只跑 switch↔switch 邊的話不受影響。

### 異議-2：`link` 與 proxy 的排他只有 C 能保證，而兩邊是**各自實作**同一條規則
§2.1 明寫 C 在 `main.py` 自算 `_telemetry_source(package, dpid)`，不 import 我的
`app_package.telemetry_source`。兩份實作若對同一台答出不同的字，後果不是報錯而是
**同一台交換機同時被 tc 取樣又被 clone 到 CPU**，kernel 兩邊都收 ⇒ 鏈路使用率大約雙倍，
而且是「看起來很合理」的雙倍。
**請求 orchestrator 在併回時做一次對帳**：拿同一組（package, knob, dpid）餵兩邊，
斷言逐格相同（P2 對 `pipeline_is_ndtwin` 的作法）。我這邊可直接用
`app_package.telemetry_source(package, dpid, knob_path=…)`。

### 異議-3：我沒有辦法驗證的事，逐條列出（不要當成已驗）
- **一行 `tc` 都沒有真的跑過，psample socket 一次都沒開過，fabric 一次都沒起過。**
  紅線 §0-2 就是這樣要求的。所有「濾器掛上去了」「樣本變成 sFlow」的證據都是離線的：
  指令列逐字比對＋自編 netlink 訊息餵解碼器＋datagram 位元組對 `build_datagram` 的期望。
  **端到端（`tc` → 真 psample → kernel 的鏈路使用率）沒有被本工單證明過**，
  現有證據只有 09-17 的 spike（那是兩個 netns＋一對 veth，不是 bmv2 fabric）。
- **`trunc 128` 與 `rate 256` 對 bmv2 fabric 的 CPU 成本沒有量過。** 那是 E 的事。
- **psample group `27` 是我挑的號碼**（工單沒指定）。同一台機器若有別人的 `action sample`
  用同一個 group，樣本會進來——但 ifindex 不在對映裡 ⇒ 丟掉並計入 `dropped_unknown_ifindex`／
  `dropped_other_group`。不會被算進去，但會消耗 CPU。
- **`ndt status` 的 `link shaping` 那一行我只提供函式，沒有印過它**（D 的檔）。
- **ecn／mri 的 0.5 Mbps 只驗到「`bw=0.5` 進了 `addLink` 的 kwargs」**；TCLink 真的把
  htb 裝上去、qdepth 真的非零，要 live。

### 異議-4：`merged_checks.sh` 對 feature 分支證不了東西（已知，§2.7 交給 D）
它 `cd` 進主 checkout 又把字面 `HEAD` 傳給 `check_gate_anchors.py`
⇒ 在我的分支上跑它，量到的是 trunk（110 cells，不含我的新 gate）。
我另外在自己的 worktree 對 `40868006` 跑了一次（111 cells ok），兩份 log 都在。
D 把它改成 `"$sha"` 之後這條就消失。

### 異議-5：`ndt down` 之後殘留的判準，我這邊只做到一半
§2.7 要 D 在 `ndt down` 時「emitter 還活著 ⇒ 印出來並列為 residue（不殺）」。
我這邊 `tear_down` 會停它；但**若 topology 進程是被 SIGKILL 掉的**（tmux session 被收），
`tear_down` 根本沒跑，manifest 與 qdisc 都會留著。
我加的補償是 `reset_for_bring_up()` 開頭呼叫 `link_telemetry.shut_down()`
（＝下一次 bring-up 會清掉上一輪的 emitter 與濾器，和它 reap 上一輪 bmv2 的道理一樣）。
**`ndt down` 自己那條路徑仍然只有 D 能補。**

---

## 6. 與工單文字不同的地方（碼為準，逐條說）

1. **`telemetry_source(package, dpid, knob_path=None)` 多一個 `base_dir=None`**。
   `auto` 那層要問 `pipeline_is_ndtwin(dpid, base_dir)`，那是 `Package` 的方法且需要 p4_proxy root。
   預設值＝fabric 自己用的那個字串（`os.path.join(_HERE, "..")`，故意不正規化，和
   `MultiSwitchTopo` 同一個寫法），只有測試會傳。
2. **`plan(package, model, switches, knob_path=None)` 多 `ifindex_of=None`、`base_dir=None`**。
   `ifindex_of` 預設在**呼叫時**解析模組屬性 `read_ifindex`（不是 def 時綁定），
   所以離線測試換掉模組屬性就夠，和 `resolve_bmv2_launcher` 解析 override 路徑的作法一致。
3. **`shaped_links(package) -> [(a, b, bw_mbps, delay_ms)]` 的 `a`／`b` 是 `(name, port)` tuple**，
   不是字串。工單只給了 `ndt status` 的顯示樣子（`s1:3<->s2:3 0.5 Mbit/s`），
   而 `addLink` 需要能比對的鍵。**給 D 的三個函式**：
   - `app_package.shaped_links(package)` — 清單（未整形的鏈路不在裡面；`bw_mbps`／`delay_ms` 各自可為 `None`）
   - `app_package.format_shaped_link(entry)` — `ndt status` 的字串，**印的那一行和裝 shaping 的那段讀同一個函式**
   - `app_package.shaping_index(package)` / `link_shaping_kwargs(index, a, b)` — fabric 內部用（無序鍵）
4. **`attach(plan, run=subprocess.run)`／`write_manifest(..., path=LINK_TELEMETRY_MANIFEST)` 的預設寫成 `None`**，
   在函式體內解析成模組屬性。行為相同，但測試換模組屬性就能同時影響兩個 main（這支測試檔存在的理由）。
5. **`write_manifest` 多一個 `log_path`，manifest 多一個 `log` 鍵**（異議-0）。
6. **`bring_up` 把 `switches = [net.get(name) …]` 移到 `configure_hosts` 之前**：
   §2.5 要求濾器掛在 `net.start()` 與 `configure_hosts` 之間，而規劃濾器需要這些物件。
   影響：`net.gets` 的順序變成「先交換機後主機」。**沒有任何測試把 `net.gets` 釘成字面清單**
   （`test_the_switches_are_the_models_ten_in_dpid_order` 只過濾 `s` 開頭那些、
   `TheTwoEntryPointsDoTheSameThingTest` 是兩個 main 互比），baseline byte-identical 的三項
   （bmv2 argv、Mininet 建構參數、host 指令）不受影響且仍綠。
7. **工單沒要求但我加了兩條清理**（都在我的檔內）：
   - `attach`／`start_emitter`／`write_manifest` 任一失敗 ⇒ 先 `detach` 再 raise
     （manifest 還沒寫出來之前，`tear_down` 讀不到東西可拆）；
   - `reset_for_bring_up()` 開頭 `link_telemetry.shut_down()`（見異議-5）。
8. **`mutate_app_package.sh` 除了續號 M48，還加了一行 `ln -s "$REPO/tools" "$BK/tools"`**：
   `test_app_package` 新增的一格會去讀 `tools/p4_exercise/common.py` 的 `DEFAULT_LINK_BPS`
   並斷言它等於 `app_package.DEFAULT_LINK_BPS`（那份重複是**被檢查的**，不是被假設的）；
   沒有那個 symlink，該格在每個 mutant 裡都會 error、baseline 直接紅。
   **M18 一個字都沒動**（與 D 協調過的那條）。
9. **commit trailer 用 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`**，
   不是工單 §0-5 寫的 `Claude Opus 5`：本 session 的 harness attribution 指示明寫要帶
   `(1M context)` 且「replaces any earlier attribution guidance」。
   **如果要和 repo 既有六顆 commit 的寫法一致，orchestrator 可以在併回時 amend**——
   我不自己改，因為那是誠實標註模型身分的那一行。
10. **工單 §4.3 的 M-B1..M-B11 全做，另加 M-B13／M-B14／M-B15／M-B16 四條**（理由寫在 gate 裡），
    另有兩條宣告為等價、故意不做（§3 末）。round 2 再加 M-B11b／M-B17..M-B22（見 §8）。
11. **`sampling_rate` 取 kernel 在樣本裡回報的 `SAMPLE_RATE` 屬性，manifest 的 rate 只是 fallback**
    （`psample_sflow_emitter.sample_for`）。工單 §2.2 只說 `RATE = 256`。
    理由：manifest 記的是**計畫**的速率，屬性記的是**實際套上去**的；兩者不同時
    （例如濾器是別人掛的、或 `tc` 被改過）照 manifest 報會把錯的速率乘進鏈路位元組。
    **round 1 沒寫，judge 指出**（他評「可說更好，但沒回報」）。
    有兩顆測試釘住兩邊：`test_the_rate_the_kernel_reports_wins_over_the_manifests`、
    `test_the_manifests_rate_is_the_fallback_when_the_kernel_states_none`。
12. **manifest 是在 `net.stop()` 之前刪掉的，工單 §2.5 把它排在最後**。
    我的 `tear_down` 呼叫一次 `link_telemetry.shut_down()`，那一支裡面是
    「停 emitter → detach → 刪 manifest」，整個在 `net.stop()` 之前。
    理由：`shut_down` 是「把 link telemetry 整個收掉」的**單一原子動作**，
    這也是 `reset_for_bring_up` 能直接重用它、以及 abort 路徑不必多帶一個物件的原因；
    而 manifest 的語意是「有一個 emitter 正在跑」，emitter 一停它就是假的，
    留到 `net.stop()` 之後等於留一段「manifest 指著一個死 pid」的窗。
    **沒有東西在那之後還需要它**（detach 用的 ifname 已經讀出來了）。
    **round 1 沒寫，judge 指出。** 要照工單排也可以，但要把 manifest 路徑從 `shut_down` 拆出來，
    請 orchestrator 裁。

---

## 7. 檔案清單（我動的，全部在所有權範圍內）

改：
- `p4_proxy/mininet/app_package.py`
- `p4_proxy/mininet/p4_testbed_topo.py`
- `p4_proxy/tests/test_app_package.py`
- `p4_proxy/tests/test_fabric_bring_up.py`
- `tests/shell/mutate_app_package.sh`

新：
- `p4_proxy/mininet/link_telemetry.py`
- `p4_proxy/mininet/psample_sflow_emitter.py`
- `p4_proxy/tests/test_link_telemetry.py`
- `p4_proxy/tests/test_psample_sflow_emitter.py`
- `tests/shell/mutate_link_telemetry.sh`

**沒動**：`p4_proxy/mininet/ntg_bmv2_topo.py`（§4.2 兩個入口的 abort 路徑都經由
`testbed.tear_down(net)`，而 tear_down 現在自己讀 manifest 停 emitter＋detach ⇒ bridge 一個字都不用改，
這也是「manifest 而不是 plan 物件」這個設計的目的）、
`proxy_agent/*`、`tools/test_workflow/ndt`、`stack.sh`、`drive_exercise.py`、`p4_proxy/tests/test_bmv2_binary_override.py`。

**round 2 沒有新增或移除任何檔**，動的是上面同一份清單裡的四個（`p4_testbed_topo.py`、`link_telemetry.py`、`test_fabric_bring_up.py`、`test_link_telemetry.py`）加 `tests/shell/mutate_link_telemetry.sh`；`ntg_bmv2_topo.py` 到 round 2 結束仍然一個字都沒動。

---

## 8. Round 2（judge 裁定 MERGE AFTER FIXES 之後；head `80c97464`）

judge 的 verdict 在 `scratch/overnight-2026-09-05/hunt-0911/fix/P3-B-JUDGE.md`。
下面每一列都是「哪一條、哪顆 commit、哪顆測試／變異證明它」。

### 8.1 必修

| 項 | 修法 | commit | 證明 |
|---|---|---|---|
| **F1（擋併入）**：`bring_up` 內 raise 的 `LinkTelemetryError`／壞 knob 字是**未捕捉例外**不是 abort 路徑——net 已 start、`tear_down` 沒跑 | `start_link_telemetry` 自己 `except ValueError`，把它折成 **fatal verdict**（和 dead emitter 同一條路），兩個 main 就走它們本來就有的 `if fatal: tear_down(net); sys.exit(1)`。**只捕 ValueError**：其他例外是這支碼的缺陷，不准被裝扮成 fabric verdict。`LinkTelemetryError` 的 docstring 改成講真話（見 §8.4） | `7201ddd5` | 新 class `ARefusalInsideTheBringUpIsAVerdictAndNotATracebackTest` 六顆，其中 **`test_the_topology_script_stops_the_net_it_started`／`test_the_bridge_stops_the_net_it_started` 直接斷言 `net.stopped`**（round 1 只證了 attach 失敗會拆 qdisc，沒證 net 被收）；`test_a_defect_in_this_code_is_still_a_traceback` 守住「不要吞 AttributeError」。變異 **M-B18** |
| **F2**：knob 沒有 pre-flight ⇒ 值域檢查第一次跑在 `bring_up` 裡，那時 `reset_for_bring_up` 已毀掉舊 fabric、`net.start()` 已建好新的 | `plan_fabric` 讀 `app_package.read_telemetry_knob()` 並逐台解析出 `telemetry_sources`；兩者都放進 `FabricPlan`，並印一行 `telemetry: <word> (knob\|no knob) -> N link, M cooperative` | `7201ddd5` | `test_a_telemetry_knob_outside_the_domain_is_refused_in_the_pre_flight`、**`test_the_refusal_happens_before_anything_is_reset`（監看 `reset_for_bring_up` 有沒有被呼叫）**、`test_the_plan_resolves_and_reports_the_source_of_every_switch`、`test_with_no_knob_the_plan_reports_the_rule_that_was_applied`。變異 **M-B19** |
| **F3（報告）** | 全部就地更正：§2「35 模組」→ **34**（實測 `ls tests/test_*.py \| wc -l`）；§4.2 的統計行改成算得通的 `samples=1203` 並補上不變式；§6 補兩條漏報的偏離（第 11、12 條）；§3 的 M-B11 改名 M-B11a 並補上工單字面的 M-B11b；異議-1 的措辭改成「host→switch 灌高、switch→host 為零」 | 本檔 | — |

### 8.2 judge 列的「應補的測試」與「站不住的細節」

| judge 的點 | 修法 | commit | 證明 |
|---|---|---|---|
| (細節 4) `reset_for_bring_up` 的 `shut_down()` 沒帶 `report`——被 SIGKILL 那輪留下的 emitter 被殺得無聲，和這支自己的立場相反 | 改成 `shut_down(report=print)` | `7201ddd5` | `test_a_previous_runs_emitter_is_stopped_before_a_new_fabric_is_built` 現在用 `contextlib.redirect_stdout` 斷言那行真的出現在 stdout。變異 **M-B20** |
| (細節 3／應補 3) `test_the_filters_are_on_before_the_emitter_is_started` 名字說順序、斷言只查非空 | `FakeSubprocess` 改成**一條有序 event log**（`ran`／`started` 變成衍生 property，`reset()` 取代重新賦值）；該顆斷言 76 條 attach 全在 Popen 之前、之後沒有任何 tc | `7201ddd5` | 該顆本身＋變異 **M-B17**（對調 attach／start_emitter）。**順便更正了理由**：attach 先做不是為了「不漏樣本」，是為了**失敗時沒有行程要收**——manifest 還沒寫，pid 沒被記下來，recovery 停不掉它 |
| (應補 5) `write_manifest` 在 `start_emitter` 之前只有散文釘住 | 新 `test_the_manifest_is_written_after_the_emitter_so_it_can_carry_its_pid`：斷言順序 **與** 記下的 pid＝行程的 pid | `7201ddd5` | 變異 **M-B22** |
| (細節 2／應補 4) M-B11 比工單粗，「只拿掉 detach」那顆沒跑 | 拆成 **M-B11a**（粗的，整個 `shut_down` 換 `pass`）與 **M-B11b**（工單字面：emitter 照停、manifest 照刪，只 `removed = []`） | `7201ddd5` | 兩顆都 caught，殺手不同 |
| (應補 6) 混合 fabric 的 `plan`——所有 plan 測試都是十台全 link 或全 off | 新 `AMixedFabricUnderAutoTest`（firewall 形狀：s1 外來、s2-s4 NDTwin，**無 knob**）：`sources` ＝ 1 link ＋ 3 cooperative、濾器只在 `s1-eth1..4`、manifest 只有 s1、`--telemetry link` 仍把四台都拉上來、`none` 連 s1 都關掉 | `7201ddd5` | 六顆 |
| (應補 7) package 模型（pod-topo，host 埠 1）下的 `link` | 新 `APackagesOwnFabricTest`：**先斷言這個模型的 host 真的在埠 1**（前提不用假設的），再斷言 egress 濾器跟著模型走而不是跟著數字 3；s3／s4 沒有主機 ⇒ 只有 ingress；12 ingress ＋ 4 egress | `7201ddd5` | 四顆 |
| (應補 8) `stop_emitter` 的等待迴圈是浮點相減（0.5 s ⇒ 6 次），正是 `p4_testbed_topo` 自己警告的寫法 | 改成 `range(ceil(grace_s / EMITTER_POLL_INTERVAL_S))` | `7201ddd5` | `test_one_that_will_not_go_is_killed_after_the_grace_period` 斷言 **5** 次且每次都是那個常數。變異 **M-B21** |
| (細節 5) 閘門的 `report()` 只證「具名格紅了」，不證「只有它紅」 | **未改，也不打算改**——工單沒要求，而且「只有它紅」對一個會連鎖的變異是錯的期望（例：M-B19 的正確版本必然也讓報告那顆紅）。當成已知限制記在這裡 | — | — |
| (細節 6) 閘門表第 5 列量的是 trunk | round 1 §2 已經寫明，並另外附了 worktree／我的 sha 的那一列。**未改**（`merged_checks.sh` 是 D 的檔） | — | — |

### 8.3 M-B19 一開始 SURVIVED，那是對的——順手記下來

第一版 M-B19 只把 `telemetry_knob = app_package.read_telemetry_knob()` 拿掉，
**pre-flight 照樣拒絕**，因為下一行逐台解析時 `telemetry_source()` 自己也會讀 knob。
具名那顆維持綠 ⇒ 閘門記 SURVIVED，**而它是對的：那顆變異不是那條宣稱**。
F2 買到的是「**這兩行任一行**跑在 `reset_for_bring_up` 之前」，所以變異要整塊拿掉。
改法與理由寫在 gate 該條旁邊（`80c97464`）。
**這正是 mutation gate 的用途：它抓到我以為釘住的東西其實沒釘住。**

### 8.4 順帶更正的一句話（不是 judge 列的，但同根）

`LinkTelemetryError` 的 docstring 原本寫「ValueError 所以兩個 main 既有的 `except` 接得住」。
對 `plan_fabric` 那個呼叫點為真，對 `bring_up` 為假——而 `bring_up` 正是它會被 raise 的地方。
改成講清楚「是 ValueError 買到什麼、**沒**買到什麼」，以及真正接住它的是
`start_link_telemetry` 自己。

### 8.5 Round 2 的 commit

| sha | 內容 |
|---|---|
| `7201ddd5` | F1＋F2＋(a)(b)(c)(d)(e)＋浮點迴圈；測試與變異一起 |
| `80c97464` | M-B19 改成拿掉整塊 pre-flight（見 §8.3） |

### 8.6 Round 2 的閘門（每個數字都來自實跑；log 在 `…/gates-0910/<gate>.p3b-80c97464.log`）

| 項目 | rc | 最後一行 |
|---|---|---|
| p4_proxy 全套（34 模組） | 0 | `Ran 1227 tests in 19.592s` / `OK (skipped=1)` |
| `mutate_link_telemetry.sh` | 0 | `mutation gate: 22 mutations, 0 survived`（`baseline byte-identical: yes (4 sources, 4 test files)`；baseline `Ran 302 tests` OK） |
| `mutate_app_package.sh` | 0 | `mutation gate: 48 mutations, 0 survived`（`baseline byte-identical: yes (10 sources, 7 test files)`） |
| `test_topo_from_json.py` | 0 | `PASS -- derived wiring is identical to the hard-coded lists` |
| `check_gate_anchors.py 80c97464`（我的 worktree） | 0 | `111/111 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `check_process_by_name.py` | 0 | `303 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` |
| `check_test_tmpdirs.py` | 0 | `336 file(s) scanned, 0 fixed temp paths` |
| `merged_checks.sh 80c97464 1` | 0 | `MERGED-CHECKS 80c97464 r1: ALL-GREEN` |

各測試檔（round 1 → round 2）：
`test_link_telemetry` 41 → **51**；`test_psample_sflow_emitter` 32 → **32**（未動）；
`test_fabric_bring_up` 88 → **100**；`test_app_package` 119 → **119**（未動）。
全套 1205 → **1227**。變異 15 → **22**。

### 8.7 Round 2 我不同意的地方

1. **細節 5（`report()` 只 grep 具名格）我不打算改**，理由在 §8.2 表內：
   「只有具名那顆紅」對會連鎖的變異是錯的期望，而且工單沒要求。judge 自己也寫了「工單也沒要求」。
2. **§6 第 12 條（manifest 在 `net.stop()` 之前刪）我保留現狀**，理由寫在該條：
   `shut_down` 是單一原子動作，這是 `reset_for_bring_up` 能重用它、abort 路徑不必多帶一個物件的原因；
   而且 manifest 的語意是「有 emitter 在跑」，停掉之後留著它只是留一段會說謊的窗。
   **要照工單的字面排也可以**（把刪 manifest 從 `shut_down` 拆出來），**請 orchestrator 裁**——
   我把它當偏離回報，沒有當作可以自己決定的事。
3. **異議-1 仍然成立且仍然是併回順序的硬條件**（judge 也判它成立，只是我 round 1 的措辭高估）。
   措辭已更正為單向污染。**`--telemetry link` 的任何 live 讀數仍必須等 A 併回、kernel 重建之後。**

[Co-developed with claude code -- Adam]

---

## 9. Live-fix round（orchestrator 2026-09-19 13:3x；§9 裁決 19①；head `b4b6ef57`）

**前情**：B 在 trunk 上**活的**——merged trunk `2a551df7` 的 live-p1/05 link 組
`LINK_USAGE link expect=follows onpath=3 rc=0`（真 fabric、外來 pipeline、psample 發射器）。
只有一個缺陷是離線測不出來的。

- **base**：`dfb9d0d7`（`git -C <wt> merge trunk`＝fast-forward，我的東西已在 trunk 的 `f5ad6890`；
  我的生產檔自 `80c97464` 起只有 `mutate_app_package.sh` 被 D 動過（M18 anchor，裁決 9⑧），無衝突）
- **head**：`b4b6ef57`
- **未追蹤的工單複本**：`TICKET-P3-observation.md` 已刪（裁決 18⑦；它現在在 trunk 上，本地那份是 merge 的障礙，不是我的東西）

```
 p4_proxy/mininet/ntg_bmv2_topo.py            |   7 +
 p4_proxy/mininet/p4_testbed_topo.py          | 116 ++++++++++++++--
 p4_proxy/mininet/psample_sflow_emitter.py    |  35 ++++-
 p4_proxy/tests/test_fabric_bring_up.py       | 200 +++++++++++++++++++++++++++
 p4_proxy/tests/test_psample_sflow_emitter.py |  41 ++++++
 tests/shell/mutate_link_telemetry.sh         |  72 +++++++++-
 6 files changed, 458 insertions(+), 13 deletions(-)
```

### 9.1 缺陷：`ndt down` 之後 manifest 殘留、pid 已死

raw：`live-p1/runs/2026-09-19T051758Z_02_app_basic/90_down.txt`
「residue: /tmp/ndtwin_link_telemetry.json is still there and the pid it names (2386073) is gone」
（02／03／05-link 每一輪都是）。三段鏈子：

1. `ndtwin-lab topo-stop` 先送 C-c 到 tmux pane。**Mininet 的 `CLI.run()` 在 `while True` 裡
   `except KeyboardInterrupt` 印 `Interrupt` 然後繼續**——那是設計，免得誤按 Ctrl-C 毀掉 fabric。
   所以 C-c 什麼都沒做。
2. 十秒後 `kill-session` 對 pane 的 process group 送 **SIGHUP**。SIGHUP 預設就是終止，
   這支行程沒有 handler，而 `main()` 是裸的 `CLI(net)` 後面接 `tear_down(net)`——
   **python 死在那兩行中間。**
3. `tear_down` → `link_telemetry.shut_down` 因此從沒跑；發射器在同一個 process group
   被同一個 SIGHUP 帶走 ⇒ **manifest 活得比它指的行程久**。

### 9.2 改了什麼、為什麼

| 改動 | 檔 | 為什麼 |
|---|---|---|
| `try: CLI(net) finally: tear_down(net)` | `p4_testbed_topo.py` `main()` | 裁決 19①(a)。`ntg_bmv2_topo.py` 本來就有 try/finally |
| `install_teardown_signal_handlers()`：SIGINT／SIGTERM／SIGHUP ⇒ raise `SystemExit(0)`；**兩個 main 從同一支函式裝** | `p4_testbed_topo.py`（新函式）、`ntg_bmv2_topo.py`（呼叫） | **finally 接不到預設處置的訊號**——SIGHUP 就地終止行程。`topo-start` launch 的是 bridge，所以那邊才是每晚真的在跑的路徑 |
| fatal 那條移除自己的 `tear_down(net)` | `p4_testbed_topo.py` | 上面有了 `finally`，那行會讓它**跑兩次**（`net.stop()` 不是冪等的） |
| 發射器加 SIGHUP（抽成 `install_stop_handlers`） | `psample_sflow_emitter.py` | 不是為了對稱：它在**同一個 pane process group**，`kill-session` 直接打到它，預設處置下它死在半個 datagram 中間、最後一行統計都沒有 |

**兩件用查的不用猜的**：
1. **Mininet 自己不裝任何 signal handler**——`/usr/lib/python3/dist-packages/mininet/*.py`
   全檔沒有 `signal.signal`；`CLI.run` 只跑 `stty ... intr ^C`（終端設定，不是處置）。
   所以**我的 handler 不會被蓋掉，SIGINT 這條路是通的**（coordinator 問的就是這點）。
2. **`SystemExit` 不是 `KeyboardInterrupt`**——Mininet 的 `except KeyboardInterrupt` 看不見它，
   所以它會離開那個迴圈。這一步有自己的一顆測試釘著（`test_catching_keyboardinterrupt_does_not_catch_systemexit`），
   而且有一顆照 `CLI.run` 形狀寫的迴圈模擬整個缺陷。

**第一個訊號贏、後面的是 no-op**：`topo-stop` 送完 C-c 十秒後才送 SIGHUP，
**第二個很容易落在第一個要求的 teardown 中間**；在那裡重新 raise 會把 teardown 攔腰砍斷、
留下正是這次要消滅的殘留。用「自我解除」而不是 `SIG_IGN`，處置仍是 Python 層 handler，
**沒有讓這支行程變得比原本更難殺**（SIGKILL 不受影響，窗口的長度就是 `tear_down` 本身）。

**沒有蓋到的窗口（誠實列出）**：`bring_up` 執行中收到訊號仍是原本的突然死亡。
handler 裝在 `bring_up` 回來之後、`try` 之前——因為要蓋住那段就得在 `bring_up` 裡面加 `finally`，
而 net 是它還沒回傳的東西。那段只有幾秒，且是 fabric 還沒交給任何人的時候。

### 9.3 十秒窗口夠不夠：量到的數字（**raw 在 repo 裡**）

🔴 **judge F2**：這一節第一版的三個數字（45.4 ms／0.0 ms／5006 ms）**在 repo 裡沒有任何 raw**
——是我在終端跑了一次、把數字抄進報告。「跑過」與「有存檔」不是同一件事。
腳本與輸出現在都存了下來，數字改引存檔那一輪（5 次重複，報 min／median／max）：

- 腳本：`scratch/overnight-2026-09-05/logs/gates-0910/link_telemetry_timing.p3b-b4b6ef57.sh`
- 輸出：`scratch/overnight-2026-09-05/logs/gates-0910/link_telemetry_timing.p3b-b4b6ef57.log`
  （檔頭記了 tree、head `b4b6ef57`、`0 uncommitted`、直譯器、UTC 時戳）

| 情境（36 個取樣介面；NDTwin 10 台／4 主機） | min | median | max |
|---|---|---|---|
| arm 1 `shut_down`，**發射器已經不在**（SIGHUP 那條：`kill-session` 把它一起帶走） | 41.1 ms | **47.6 ms** | 48.6 ms |
| arm 2 `stop_emitter`，發射器答第一個 SIGTERM（Ctrl-C 那條） | 0.0 ms | **0.0 ms** | 0.0 ms |
| arm 3 `stop_emitter` 最壞：發射器怎麼都不走 ⇒ SIGKILL（跑 1 次，因為它真的睡滿） | — | **5006 ms** | — |

第一版寫的 45.4 ms 是同一個量測的單次取樣，落在上面的 41.1–48.6 區間內；
**以存檔那一輪為準**，不是因為它比較好看，而是因為它是唯一有 raw 的那一輪。

**這個量測不是什麼**（腳本檔頭也寫了同一段）：`/bin/true` 代替 `tc`——同樣的 fork+exec、
不需權限、不碰機器上任何東西（§0 禁止本 worker 跑 `tc`）。所以 detach 那個數字是
**子行程成本的上界、真實 teardown 成本的下界**：真的 `tc qdisc del` 還要加 netlink 的工。
發射器也沒有真的起來，arm 2／3 量的是輪詢機制本身、答案是注入的。
**這裡沒有任何一句是關於真 fabric 的宣稱。**

⇒ 最壞總和 ≈ arm 3 ＋ arm 1 ≈ **5.05 s** ＋ `net.stop()`，**在十秒窗口內**；
而且上界是**碼裡的常數決定的**，不是量出來的：`EMITTER_STOP_GRACE_S = 5.0`
（`EMITTER_POLL_INTERVAL_S = 0.1`）⇒ `stop_emitter` 不可能超過 ~5 s。
而且 handler 讓窗口**從 C-c 就開始**，不是從十秒後的 SIGHUP 才開始。

### 9.4 每顆新測試怎麼被看過紅

`mutate_link_telemetry.sh` 這一輪從 22 顆加到 **28 顆**（M-B23..M-B28），全部 caught：

| 變異 | 殺它的測試 |
|---|---|
| **M-B23** teardown 不是 `finally`（**逐字重現 2026-09-19 以前的形狀**） | `test_the_topology_script_tears_down_when_the_cli_is_cut_short` |
| **M-B24** topology script 不裝 handler | `test_the_handlers_are_armed_before_the_cli_is_entered` |
| **M-B25** bridge（`topo-start` 真正 launch 的那個）不裝 handler | `test_the_bridge_arms_them_too` |
| **M-B26** 第二個訊號照樣 raise（砍斷 teardown） | `test_the_second_signal_does_not_interrupt_the_teardown_the_first_asked_for` |
| **M-B27** 只裝 SIGINT（也就是 Mininet 本來就吃掉的那一個） | `test_all_three_signals_are_installed` |
| **M-B28** 發射器不處理真正殺死它的那個訊號 | `test_all_three_stop_signals_are_installed` |

其他新格（`test_the_bridge_tears_down_when_the_cli_is_cut_short`、
`test_a_fatal_fabric_tears_down_exactly_once_and_still_exits_one`、
`test_an_exception_out_of_the_cli_also_reaches_the_teardown`、
`test_a_cli_that_catches_keyboardinterrupt_still_lets_the_shutdown_out`、
`test_the_loop_stops_on_that_flag_and_prints_a_last_line`）由上面六顆變異連帶證明
（M-B23／M-B24／M-B27 都讓它們一起紅）。

#### 🔴 M-B27 第一輪 SURVIVED，而閘門是對的（`3e3bbc69` → `b4b6ef57`）

把 `TEARDOWN_SIGNALS` 砍成只剩 SIGINT 之後，我那顆「第二個訊號不打斷 teardown」的測試
對自己送 SIGHUP——**而 SIGHUP 回到預設處置，`signal.raise_signal` 直接終止了 test runner**。
unittest 的失敗是最後才印的，所以整份 run **一行輸出都沒有**，閘門看到 rc≠0 但找不到具名紅格
⇒ 記成 survivor。它前面其實已經有兩顆紅了，只是沒人看得到。

修法：每一個 `raise_signal` 都走 `raise_guarded()`，先斷言處置不是 `SIG_DFL`／`SIG_IGN` 再送。
**手動把該變異套到樹的複本上驗過**：`FAILED (failures=3)`、`Ran 112 tests`（沒有死掉）。
閘門檔頭記下這條——「**會殺死自己 runner 的測試不是測試**」正是它上面那段 timeout 分支的同一種形狀。

### 9.5 Live-fix round 的 commit

| sha | 內容 |
|---|---|
| `3e3bbc69` | `finally`＋三個訊號的 handler（兩個 main 一支函式）＋發射器的 SIGHUP＋測試＋M-B23..M-B28 |
| `b4b6ef57` | `raise_guarded()`：測試不准殺死自己的 runner（見 §9.4 末） |

### 9.6 Live-fix round 的閘門（log 在 `…/logs/gates-0910/<name>.p3b-b4b6ef57.log`）

| 項目 | rc | 最後一行 |
|---|---|---|
| p4_proxy 全套（**37 模組**，merge 後 C／D／A 的也在內） | 0 | `Ran 1380 tests in 19.092s` / `OK (skipped=4)` |
| `mutate_link_telemetry.sh` | 0 | `mutation gate: 28 mutations, 0 survived`（baseline `Ran 317 tests` OK；`baseline byte-identical: yes (5 sources, 4 test files)`） |
| `mutate_app_package.sh` | 0 | `mutation gate: 48 mutations, 0 survived` |
| `check_gate_anchors.py b4b6ef57` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `check_process_by_name.py` | 0 | `312 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` |
| `check_test_tmpdirs.py` | 0 | `346 file(s) scanned, 0 fixed temp paths` |
| `test_topo_from_json.py` | 0 | `PASS -- derived wiring is identical to the hard-coded lists` |

各測試檔：`test_fabric_bring_up` 100 → **112**；`test_psample_sflow_emitter` 32 → **35**；
`test_link_telemetry` **51**（未動）；`test_app_package` **119**（未動）。

#### 那四個 skip 是哪四個、為什麼（judge F1 的尾巴）

orchestrator 用同一份樹、同一條指令重跑時是 `skipped=1`，我的那輪是 `skipped=4`。
**差別不是樹，是當下有沒有人佔著 `:8081`**——我那輪跑的時候 orchestrator 的 live run
正把 proxy 開在 `:8081` 上。逐字證據：
`logs/gates-0910/p4_proxy_tests_verbose.p3b-b4b6ef57.log`（`-v`，檔頭記了 head、cwd、模組數
與當下 `:8081` 的持有者數），該輪 `:8081` 是空的 ⇒ `Ran 1380 tests` / `OK (skipped=1)`。

| skip | 條件 | 我那輪為什麼 skip |
|---|---|---|
| `test_p4_client.LiveSwitchTest.test_installs_routes_and_the_clone_session` | `NDTWIN_LIVE_SWITCH_OPT_IN=1` 才跑 | **永遠 skip**，與環境無關；base 上就是如此 |
| `test_port_guard.PortAlreadyTakenTest.test_startup_event_never_runs_when_the_port_is_taken` | `setUp` 要**自己 bind `:8081`** 來製造「埠被佔」 | 埠已被別人佔住 ⇒ `cannot occupy :8081 for the test` |
| `test_port_guard.PortAlreadyTakenTest.test_it_exits_non_zero_and_says_why` | 同上（同一個 `setUp`） | 同上 |
| `test_port_guard.PortFreeTest.test_startup_event_does_run_when_the_port_is_free` | 要 `:8081` **是空的**才能測 accept 那條 | `:8081 is occupied by something else; cannot test the free case` |

⇒ **四個都不是我的**，也不是缺陷：三個是 `test_port_guard.py` 自己的前置條件，
一個是既有的 opt-in。它們**誠實地 skip**（訊息說出理由）而不是假綠，這正是它們該有的行為。
唯一要記住的是：**live 在跑的時候跑這套件，`:8081` 那三格量不到東西**。

### 9.7 這一輪的但書

1. **我沒有跑過 live**（紅線：不 sudo、不 ndt、不碰 lab——lab 正在給 orchestrator 的 live 用）。
   上面每個數字都是離線的；「SIGHUP 真的會讓 `finally` 跑完、manifest 真的不再殘留」
   **要 orchestrator 重跑 live 才算證明**。我能證的是：處置真的被換掉、
   `SystemExit` 真的穿得過 `except KeyboardInterrupt` 的迴圈、`finally` 真的跑、
   第二個訊號真的不打斷它、時間真的在十秒內。
2. **裁決 19①(b) 是 D 的**（`ndt down` 看到 manifest 在但 pid 不是發射器 ⇒ 自己刪掉、印
   「stale link manifest removed」、不算 residue）。我這邊修的是「一開始就不要留下」；
   **兩邊都要有**——被 SIGKILL 的那輪永遠不會跑到我的 `finally`。
3. **`bring_up` 執行中的訊號仍未蓋到**（§9.2 末）。要蓋就得在 `bring_up` 裡加 `finally`，
   那會動到它還沒回傳的 net——本輪範圍外，記為候選。
4. **exit code 用 0**：這是被要求的、而且完成了的關機，不是失敗。
   今天沒有東西讀這個 pane 的 exit status（`ndt down` 看的是 residue）。
   要改成 128+signum 請裁。
5. **commit trailer 這一輪用工單 §0-5 的寫法 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`**
   （orchestrator 本輪指令明寫），而 **round 1／round 2 的六＋兩顆用的是
   `Claude Opus 5 (1M context) <noreply@anthropic.com>`**（當時 session 的 harness attribution
   指示明寫要帶 `(1M context)` 且「replaces any earlier attribution guidance」）
   ⇒ **本分支的 trailer 不是全程一致的**，要統一請 orchestrator 在併回時 amend，我不自己改。

### 9.8 judge 記為候選、本輪**不做**的三顆測試（orchestrator 指示：do not add now）

1. **端到端一格**：真 handler ＋ 真 SIGHUP 打進一個仿 `CLI.run` 的迴圈
   ⇒ 斷言 `net.stopped` 且 manifest 消失。現在這條鏈是由三格分段釘的
   （訊號真的換了處置／`SystemExit` 真的穿得過 `except KeyboardInterrupt`／`finally` 真的跑），
   **中間沒有接縫測試**。
2. **釘住 `start_emitter` 永遠不用 `setsid`／`start_new_session`**：發射器留在同一個
   process group 是 `kill-session` 的 SIGHUP 能直接到它、以及 §9.3 arm 1 成立的前提；
   那是一個**沒有任何測試守著的隱含依賴**。
3. **prompt_toolkit 那一段不會把 SIGHUP 的處置改掉**（bridge 在 `tee.stop()` 之後進 NTG prompt，
   prompt_toolkit 會碰訊號）——今天沒有任何東西證明我們的 handler 活過那一段。

**三顆都是真的洞，不是形式**。第 2、3 顆尤其：它們是 §9.2 那套說法的前提，而前提沒有被守著。

[Co-developed with claude code -- Adam]
