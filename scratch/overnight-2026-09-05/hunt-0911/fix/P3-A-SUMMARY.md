# P3-A-SUMMARY — 工單 A（kernel）：L3 觀測、egress-only 樣本、鏈路位元組先記

worker session「p3-kernel」，2026-09-19。工單 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/TICKET-P3-observation.md` §3。

- base：`8eddb0e8`（trunk，階段二收尾的 merge）
- worktree：`scratch/overnight-2026-09-05/wt-p3-kernel-0919`；分支 `feat/p3-kernel-l3-observation-0919`
- head：**`26e279eb`**（round 2；round 1 交件是 `d3c65dd4`）——**round 3 的 head 與檔案清單見 §8**
- 閘門 log：`scratch/overnight-2026-09-05/logs/gates-0910/*.p3a-<sha>.log`
- ~~測試 binary：`build/bin/test_routing_strategy` sha256 前 16 碼 **`2f44f739d719f37e`**（閘門跑完最後一次重建後的那顆，1361/1361 綠）~~
  🔴 **這句錯了（round 3 更正，見 §8.2）**：那次「最後一次重建」是 no-op，`2f44f739` 是**控制組 2**（`SFlowType.hpp` 多一行註解）的 build。round 3 的 binary sha 在 §8.1。

🔴 **本文件的每個數字都來自一次實跑**，指令／rc／最後一行逐條列在 §2；唯一沒有 rc 的那筆
（round 1 第一次變異閘門）在該列明講原因。沒跑過的東西一律列在 §5「沒做／沒驗」。

[Co-developed with claude code -- Adam]

---

## 0. 兩輪的關係（先讀這段）

round 1 交到 `d3c65dd4`，fable-judge 判 **MERGE AFTER FIXES**，`P3-A-JUDGE.md` 的 F1 是真的 bug：
`identifyFrame` 把 MAC／ethertype 寫進 key 之後，**IPv4 分支從不清掉**，而 `FlowKey::operator==` 是 defaulted、
流表是 `unordered_map` ⇒ 在這個 fabric（`ndtwin_switch.p4` 每跳改寫兩個 MAC、取樣是 I2E clone 帶入口 MAC）
**同一條流會按跳數裂成多筆流表項**。round 2（`4934a604` 起）修掉它，並補上 judge 列的其餘六項。

§1–§6 是 round 1 的內容，數字已按 judge 指出的錯誤更正（更正處標「⚠️ round 1 原文寫錯」）。
§7 是 round 2。

---

## 1. 做了什麼（對 §2.2／§2.3 逐條）

### 1.1 §2.2 第三條：鏈路位元組先記，再談流身份

`FlowLinkUsageCollector.cpp` 的 flow-sample 分支以前是：讀 etherType → 不是 `0x0800` 就 `continue`（整個樣本丟掉）
→ 是 IPv4 才進 `if (protocol == 6 || 17 || 1)`，而 **`m_counterReports` 的累加就在那個 `if` 裡面**。所以一條只跑
source routing（0x1234）／ARP／LLDP／IPv6 的鏈路，`link_bandwidth_usage_bps` 永遠 0——而 0 跟「這條線真的閒著」
在任何 consumer 眼裡完全一樣。現在每個格式正確的 flow sample 先記 `frameLength * samplingRate`，再問它是什麼。

附帶三件事（都是後果，不是額外功能）：

- **非首片分段**以前走 `continue`。~~而那個 `continue` **不推進 `index`** ⇒ 迴圈頂端的「read position did not advance」
  守衛 `break`，把同一個 datagram 裡**後面所有樣本一起丟掉**。~~
  🔴 **機制寫錯了（round 3 更正，見 §8.2）**：base `FlowLinkUsageCollector.cpp:1259` 的 MININET index shift
  （`index += flowDataLength / 4 + 2;`）**在 `:1455` 的 `continue` 之前就已經推進了 `index`**，所以頂端那個守衛
  **不會**觸發；真正發生的是 parser 停在樣本中間，把 dropped／ingress 那幾個 word 當成下一個樣本的 sample type 讀，
  也就是失步而不是提早收工。效果（後面的樣本拿不到）是對的，原因不是。
  現在分段不進流表，但位元組照記、index 照推進。
  （round 2 補了測試 `ANonFirstFragmentBanksItsBytesAndDoesNotEndTheDatagram`。）
- **IPv4 但 protocol ∉ {1,6,17}**（OSPF、IGMP…）現在也記鏈路位元組。§2.2 說的是「每個格式正確的 flow sample」，
  這符合條文；round 1 的報告只寫了「非 IPv4」，那是漏講。
- `addresedSampleNum`（`telemetry_health.addressed_total`）口徑變了。
  ⚠️ **round 1 原文把舊口徑寫錯**：舊碼數的是**所有 `0x0800` 樣本，扣掉 TCP/UDP/ICMP 的非首片分段**
  （非 0x0800 在計數前 `continue`；非首片分段在 protocol 過濾內 `continue`；其他 protocol 會落到底部被計）。
  現在數所有 flow sample。見 §6 異議 6。

### 1.2 §2.2 第二條：egress-only 樣本只進 egress 銀行

`inputPort == 0 && outputPort != 0` 的樣本以前被記成 `m_counterReports[(agent, outputPort)]`，而排水把那張表讀作
「從這個埠**進來**的位元組」⇒ 記到**反方向**那條邊。現在只進 `m_egressCounterReports`。

**`inputPort == 0 && outputPort == 0` 維持原狀**（記進 `m_counterReports[(agent, 0)]`）。這不是漏掉：`lookupOfport`
在非全-bmv2 拓樸下把每個 ifIndex 映成 0，**凍結的 `test_SFlowEmitterRoundtrip.cpp::BatchedSamplesBankEverySampleBytes`
就跑在這個狀態**（它自己的註解寫明每個樣本都落在 port 0），改掉這格會讓那支測試變紅。§2.2 的條件本來就寫
`&& outputPort != 0`，所以這是照字面實作。

### 1.3 §2.3：FlowKey 三個家族、ihl、VLAN

- 新增純函式 `sflow::identifyFrame(const uint8_t*, size_t)`（`SFlowType.hpp`）從 **bytes** 讀 frame，取代散在
  Brocade／HPE 兩個分支的固定 word 位移。`readSampledHeader()`（collector 的 anonymous namespace）把 frame 從
  datagram 的 word 抬成 bytes，三重界限：sample 結尾／agent 宣告的 captured length（Brocade 有；HPE 的佈局推不出來，
  見 §5）／`kMaxSampledHeaderBytes = 256`，再加 `BoundedWords::has()` 管 datagram 結尾。
- 家族：`IPv4`／`IPv6`（外層 `0x86dd`；擴展標頭鏈跳過 hop-by-hop 0／routing 43／fragment 44，其餘視為不透明 ⇒ 退
  `L2`；鏈長上限 8，**超過也退 L2**——round 2 才真的做到，見 §7 F4）／`L2`（`srcMac`／`dstMac`／`ethType`）。
  VLAN `0x8100` 剝**一**層再判。
- **ihl**：IPv4 的 L4 位移＝`ihl*4`；`ihl == 5` 時等於舊的常數位移（所以既有數字不動）；`ihl < 5` 計入
  `malformed_ipv4_ihl` 且不記流、但**位元組照記**。
- **一把 key 只帶它家族指名的欄位**（round 2 的 F1 修正）：IPv4＝五元組、IPv6＝位址對＋next header＋ports、
  L2＝兩個 MAC＋ethertype。
- **IPv4 口徑不動**：`FlowKeyHash` 對 IPv4 家族**提早 return**，回傳跟加欄位前逐位元相同的整數；`operator<` 對兩個
  IPv4 鍵仍由同樣那五個欄位決定；ICMP type/code 仍佔 port 欄位、code 仍遮 4 bits（那是今天的行為，不是新決定）。

### 1.4 揭露

- `GET /ndt/get_sflow_stats`（**只動這一個 handler**）加三個鍵，既有的 `status`／`telemetry_health` 一字不動：
  `samples_by_family {ipv4, ipv6, l2, undecodable}`、`malformed_ipv4_ihl`、
  `non_ipv4_flows {tracked, evicted_least_recently_seen, capacity, observed[]}`。
  ⚠️ **round 3 更正（裁定 11b）**：round 1／2 這裡還有第五個鍵 ~~`dropped_over_capacity`~~，**已移除**——
  側表改成淘汰之後沒有任何地方寫它，那個鍵只會讀到 0，而「只會讀到 0 的鍵」是在宣稱量過某件事。見 §8.3。
  `observed[]` 每列按家族給鍵（L2：`src_mac`／`dst_mac`／`ethertype`；IPv6：`src_ip6`／`dst_ip6`／`protocol_number`＋ports），
  外加 `samples`／`estimated_bytes`／`last_seen_ms`。
- `getFlowInfoJson` 加 `"family"`（今天恆為 `"ipv4"`）；既有鍵不動。

### 1.5 commit（`8eddb0e8..26e279eb`，11 顆）

| sha | 內容 |
|---|---|
| `e673aef4` | round 1 實作（`SFlowType.hpp`、`FlowLinkUsageCollector.{hpp,cpp}`、`HttpSession.cpp` 的 `get_sflow_stats`、`test_LastHopAttribution.cpp`） |
| `f8b942c7` | 五個新 fixture＋generator 條目＋`test_FlowKeyFamilies.cpp`＋`test_SFlowParsing.cpp` 的 IPv6 鏈＋`tests/CMakeLists.txt` |
| `c67ab277` | `tests/shell/mutate_flowkey_families.sh` |
| `63dbdb02` | 閘門拒絕在別的 checkout 上跑（第一次實跑從主 checkout 啟動，`git rev-parse --show-toplevel` 回答的是**呼叫者**的目錄） |
| `fc563aa3` | 上一條的 `dirname` 少一層 |
| `d3c65dd4` | 兩個控制組改成直接呼叫 `apply`，讓 `check_gate_anchors.py` 讀得到它們的 anchor（round 1 交件） |
| `4934a604` | **round 2 F1**：IPv4／IPv6 的 key 不再帶 MAC／ethertype；F4 鏈長耗盡退 L2；F5 側表改 LRU 淘汰、ICMPv6 code 不遮 4 bits |
| `8927d063` | round 2 F2–F5 的測試（7 顆）＋M-A7 變異＋`restore` 只 touch 真的寫過的檔 |
| `a5c71665` | `DIRTY+=("$1")` 讓 `check_gate_anchors` 把 `apply()` 讀成 mutation table ⇒ 整支閘門 UNPARSED；bookkeeping 移到呼叫點 |
| `70b04108` | M-A7 標籤裡的撇號（`frame's`）讓同一個工具的 tokenizer 整排參數位移 |
| `26e279eb` | M-A7 的 anchor 含 `//` 註解 ⇒ 工具把它當檔名（`is_repo_path` 只看有沒有斜線），改成兩行無斜線 anchor |

`8eddb0e8..26e279eb` 共 15 個檔案：工單 §0-7 給 A 的清單，**外加 `tests/test_LastHopAttribution.cpp`**（見 §6 異議 2）。
`git diff --stat 8eddb0e8..26e279eb -- tests/fixtures tests/test_GoldenFixture.cpp tests/test_SFlowEmitterRoundtrip.cpp`
只列五個**新增**的 fixture（orchestrator 已用 git 覆核）。

---

## 2. 實跑（指令／rc／最後一行）

worktree 根目錄執行；`<G>` ＝ `scratch/overnight-2026-09-05/logs/gates-0910`。**下表是最終 head `26e279eb` 的數字**，
round 1（`d3c65dd4`）的對應 log 仍在同一個目錄，檔名帶該 sha。

| # | 指令 | rc | 最後一行／關鍵行 | log |
|---|---|---|---|---|
| 1 | `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug` | 0 | `guarded_build: exit 0` | scratchpad（configure，round 1） |
| 2 | `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh cmake --build build --target test_routing_strategy` | 0 | `guarded_build: exit 0` | scratchpad `build_r2c.log` |
| 3 | `./build/bin/test_routing_strategy`（整顆直接跑） | 0 | `[  PASSED  ] 1361 tests.` | `<G>/l1_unit_tests.p3a-26e279eb.log`（`PASS 1361/1361`） |
| 4 | `ctest`（經 `l1_unit_tests.sh`） | 0 | `ctest passed (100% tests passed, 0 tests failed out of 1361)` | 同上 |
| 5 | `p4_proxy/venv/bin/python -m unittest tests.test_sflow_emitter` | 0 | `OK`（`Ran 49 tests`） | `<G>/test_sflow_emitter.p3a-26e279eb.log` |
| 6 | `p4_proxy/venv/bin/python p4_proxy/tests/generate_emitted_fixtures.py` | 0 | 12 個 fixture 寫出 | `<G>/regenerate_fixtures.p3a-26e279eb.log` |
| 7 | `git diff --exit-code -- tests/fixtures`（緊接 #6） | **0** | 無輸出＝**既有 7 個 fixture 逐位元不變**（~~log 是 0 byte~~ ⇒ 更正：log 裡有一行 `rc=0`，見 §8.2） | `<G>/fixtures_byte_identical.p3a-26e279eb.log` |
| 8 | `tools/test_workflow/l1_unit_tests.sh --no-build`（**裸跑**，不包 guard） | 1 | `L1 FAILED (13 problem group(s))` | `<G>/l1_unit_tests.p3a-26e279eb.log` |
| 9 | `python3 tests/shell/check_gate_anchors.py HEAD` | 0 | `111/111 cells ok`；本閘門 `mutate_flowkey_families.sh ok(9)` | `<G>/check_gate_anchors.p3a-26e279eb.log` |
| 10 | `python3 tests/shell/check_process_by_name.py` | 0 | `299 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` | `<G>/check_process_by_name.p3a-26e279eb.log` |
| 11 | `python3 -m unittest tests.python.test_known_issues_references` | 0 | `OK` | `<G>/kiref.p3a-26e279eb.log` |
| 12 | `python3 tests/shell/check_test_tmpdirs.py` | 0 | `335 file(s) scanned, 0 fixed temp paths` | `<G>/check_test_tmpdirs.p3a-26e279eb.log` |
| 13 | `bash tests/shell/test_redirection_order.sh` | 0 | `Ran 48 checks, 0 failed` | `<G>/test_redirection_order.p3a-26e279eb.log` |
| 14 | `bash tests/shell/test_log_suffix_idempotent.sh` | 0 | `30 passed, 0 failed` | `<G>/test_log_suffix_idempotent.p3a-26e279eb.log` |
| 15 | `bash tests/shell/mutate_flowkey_families.sh`（round 1，sha `fc563aa3`） | **未擷取**（`setsid` 背景跑沒包 rc） | `6 mutations, 0 survived`；兩個控制組 `✅ survived`；`both files byte-identical to the pre-run snapshot`；`test binary: c9dc9fb2fa870c55 (was c9dc9fb2fa870c55)` | `<G>/mutate_flowkey_families.p3a-fc563aa3.log` |
| 16 | `bash tests/shell/mutate_flowkey_families.sh`（sha `d3c65dd4`） | — | **re-run at d3c65dd4 aborted twice（disk full at 05:34；contaminated by an orchestrator rebuild at 05:51）；evidence = row 15** | `<G>/mutate_flowkey_families.p3a-d3c65dd4.attempt1-disk-full.log`、`...p3a-d3c65dd4.log` |
| 17 | `bash tests/shell/mutate_flowkey_families.sh`（**最終**，sha `26e279eb`，包了 `GATE_RC=`） | **0** | `7 mutations, 0 survived`；兩個控制組 `✅ survived`；`both files byte-identical to the pre-run snapshot`；`rebuilt from the restored tree`；`test binary: 2f44f739d719f37e (was 056bcc79aed557db)` | `<G>/mutate_flowkey_families.p3a-26e279eb.log` |
| 18 | 上述九支在 L1 lane 紅的 python 套件，改用 `p4_proxy/venv/bin/python` 重跑 | 8 支 0、`test_grpc_port_block` 1 | 見 `<G>/venv_rerun_*.p3a-26e279eb.log`（每支一個檔） | 同左 |

~~**#17 的 binary sha 在跑完後變了（`056bcc79` → `2f44f739`），而來源逐位元相同。** round 1 那次沒變。
差別來自 round 2 的 `restore` 只 touch 真的寫過的檔：最後一次重建只重建了含 `SFlowType.hpp` 的 46 個 TU、沿用其餘物件，
兩次的物件組合不同。**跑完後的那顆 binary 跑過 1361/1361**（#3 是用它跑的），閘門自己也宣告
`both files byte-identical` 與 `rebuilt from the restored tree`；這裡記下來是因為「同樣的來源、不同的 sha」值得被看見，
不值得被默默吞掉——它意味著這個 build 不是 bit-reproducible。~~

🔴 **整段收回（round 3，見 §8.2）。** 這個 build **是** bit-reproducible——round 1 同一套流程的 log
（`mutate_flowkey_families.p3a-fc563aa3.log:47`）寫的是 `c9dc9fb2fa870c55 (was c9dc9fb2fa870c55)`。
`2f44f739` 不是「物件組合不同」，而是**最後那次重建根本沒發生**：round 2 的 `restore` 只 touch 寫過的檔，
而控制組 2 的 `classify_control` 已經還原過一次，`:441` 第二次 `cp -p` 把剛 touch 的 mtime 蓋回舊值、
`DIRTY` 已空所以不 touch ⇒ ninja 無事可做。留在磁碟上的是**控制組 2 的 build**，
它跟 baseline 的差別只是 `SFlowType.hpp` 多一行註解把後面所有行號往下推（Debug build 的 DWARF）。
修法與新證據在 §8.2／§8.3。

**#8（L1）為什麼是 1，以及哪一個是我的。** 13 個 problem group **沒有一個是我造成的**（round 1 是 15 個，其中
`gate anchors` 與 `test_build_guard.sh` 兩個確實是我的，都已修掉：前者是閘門腳本的 anchor 寫法，後者是我把 L1 包在
guard 裡跑造成的巢狀 shim）。剩下 13 個的證據是三件事，不是一句宣稱：

- **輸入不相交**：`git diff --name-only 8eddb0e8..26e279eb` 的 15 個檔案，沒有一個被那些測試讀到
  （逐支 grep 我改過的檔名＋`build/bin`／`test_routing_strategy`；`test_gate_exit_code_not_tee.sh`／
  `test_l1_shell_scoring.sh`／`test_start_bg_log_rotation.sh` 都是 0 次）。
- **換直譯器就綠**（#18，每支都有 log）：`test_chaos_*` 五支、`test_l3_dispatch_drift.py`、`test_ovs4_sflow.py`、
  `test_sflow_stats_endpoint.py` 在 lane 上紅（lane 挑的直譯器沒有 fastapi／networkx／ryu），用 venv 直譯器全部 rc=0。
  ⚠️ **round 1 原文把 `test_l3_dispatch_drift`／`test_ovs4_sflow` 寫成 `ran=0`，那是錯的**：log 是
  `FAIL (exit 1, ran=12)` 帶 8 個 ERROR、`FAIL (exit 1, ran=21)` 帶 1 個 ERROR（ERROR＝import／setup 失敗，不是斷言失敗）。
- **兩邊都紅的那一支**：`test_grpc_port_block.py` 在 lane 與 venv 下都是 rc=1（兩個 FAIL，關於一段 port block 的文件與
  topology 對帳）。它不讀我的任何檔案；我沒有修它。

**`merged_checks.sh` 沒有照字面跑**：它第 4 行寫死 `cd /home/adam/Desktop/NDTwin-Kernel`（主 checkout），
在 worktree 上跑等於去檢查別人的樹，而且 `check_gate_anchors.py HEAD` 的 `HEAD` 會是主 checkout 的 HEAD。
所以我在自己的 worktree 跑了它那六項（#9–#14），六項全綠＝`MERGED-CHECKS-EQUIVALENT 26e279eb: ALL-GREEN`。見 §6 異議 4。

---

## 3. fixture 清單與每條的家族

| fixture | 新／舊 | frame | 家族 | 它釘住什麼 |
|---|---|---|---|---|
| `emitted_tcp.bin` | 舊 | Eth+IPv4+TCP，74 B，in 1 / out 2 | IPv4 | 五元組不變；IPv4 hash 不變；key 不帶 MAC |
| `emitted_udp.bin` | 舊 | Eth+IPv4+UDP，62 B，in 3 / out 4 | IPv4 | 雙埠樣本兩個銀行各記一次 |
| `emitted_icmp.bin`／`emitted_icmp_unreachable.bin` | 舊 | Eth+IPv4+ICMP | IPv4 | type/code 仍在 port 欄位 |
| `emitted_arp.bin` | 舊（改用途） | Eth+ARP，42 B，in 2 / out 1 | **L2** | §2.2 第三條：非 IPv4 也記位元組；MAC／ethertype `0x0806`；ARP 也算「這台在取樣」 |
| `emitted_tcp_truncated.bin` | 舊 | 1400 B payload，截到 128 B | IPv4 | 截斷後仍解得出五元組 |
| `emitted_multi.bin` | 舊 | 三個樣本 | IPv4×3 | 樣本鏈；三個樣本的位元組都記 |
| `emitted_ipv6_udp.bin` | **新** | Eth+IPv6+UDP，82 B，in 3 / out 4 | **IPv6** | `2001:db8::1/::2`、next header 17、ports 5201/33334；key 不帶 MAC |
| `emitted_custom_0x1234.bin` | **新** | Eth+0x1234+32 B，46 B，in 3 / out 4 | **L2** | source routing 那種「完全沒有 IP 標頭」的訊框仍記位元組 |
| `emitted_ipv4_ihl6_tcp.bin` | **新** | Eth+IPv4(ihl 6，一個 4 B option)+TCP，**78 B** | IPv4 | ihl：ports 6001/40999（舊位移會讀成 257/256） |
| `emitted_vlan_ipv4.bin` | **新** | Eth+802.1Q(vid 100)+IPv4+UDP，66 B | IPv4 | 剝一層 VLAN 後仍是 IPv4；ports 4444/5555 |
| `emitted_egress_only.bin` | **新** | Eth+IPv4+UDP，62 B，**in 0** / out 4 | IPv4 | §2.2 第二條：只進 egress 銀行 |

⚠️ **round 1 原文把 ihl6 fixture 寫成 98 B，實際 78 B**（14+24+20+20；測試裡的常數 `kIhl6FrameLen` 一直是對的，
錯的只有報告）。

新 fixture 一律**附加**在 `FIXTURES` 尾端，沒有插入；`test_sflow_emitter.py::CommittedFixtureTest` 走的就是
`FIXTURES`，所以五條新的自動進了漂移守衛（不需要動那支測試）。#6＋#7 是「佈局沒動」的證據。

gtest：`tests/test_FlowKeyFamilies.cpp` 共 **21 顆**（round 1 十四顆＋round 2 七顆；round 3 再加五顆＝26，見 §8.4）；
`tests/test_SFlowParsing.cpp` 新增 **5 顆**（IPv6 擴展標頭鏈：逐字截斷不崩、完整鏈解出 ports 的控制組、
不透明標頭退 L2、captured header 中途斷掉不憑空生 ports、8 跳解得出／9 跳退 L2）。
⚠️ **更正**：前四顆是 round 1 的，第五顆 `AChainWithinTheBoundResolvesAndOneBeyondItDoesNot`（`:893`）**是 round 2**
（F4 的證明），不是 round 1 的內容。

---

## 4. 變異表（哪個變異被哪顆測試殺）

`tests/shell/mutate_flowkey_families.sh`；每顆變異一次重建、`JOBS=1`、全部經 `guarded_build.sh`。
最終實跑 log `<G>/mutate_flowkey_families.p3a-26e279eb.log`，`GATE_RC=0`。

| # | 變異 | 檔案 | 結果 | 被哪顆殺 |
|---|---|---|---|---|
| M-A1 | 位元組只在 IPv4 家族才記（＝身份先於位元組，P3 前的順序） | `.cpp` | ✅ caught | `AnArpSampleBanksItsLinkBytesAndIsObservedAsL2`／`ACustomEtherTypeSampleBanksItsLinkBytesAndIsObservedAsL2`／`AnIpv6UdpSampleIsObservedWithItsAddressesAndPorts` |
| M-A2 | egress-only 樣本回到 ingress 銀行 | `.cpp` | ✅ caught | `AnEgressOnlySampleCreditsTheEgressBankAndOnlyThat`／`TheTwoHalvesOfADualPortSampleAreTheTwoOneSidedSamples`／`LastHopAttributionTest.AnIngressLessSampleIsBankedOnceAndOnTheEgressSide` |
| M-A5 | `samples_by_family` 不數 L2 | `.cpp` | ✅ caught | `AnArpSampleBanksItsLinkBytesAndIsObservedAsL2`／`TheStatsObjectCarriesEveryFamilyAndTheNonIpv4Identities`／`RepeatedFramesOfOneIdentityAccumulateOnOneRow` |
| M-A3 | IPv6 家族退成 L2 | `SFlowType.hpp` | ✅ caught | `AnIpv6UdpSampleIsObservedWithItsAddressesAndPorts`／`SFlowParsingFixture.AFullIpv6ExtensionChainResolvesToTheUpperLayerPorts` |
| M-A4 | IPv4 的 L4 位移忽略 ihl（固定 20） | `SFlowType.hpp` | ✅ caught | `Ipv4OptionsMoveThePortsAndTheParserFollowsThem` |
| M-A6 | L2 家族的 hash 忽略 MAC | `SFlowType.hpp` | ✅ caught | `TwoL2KeysDifferingOnlyInTheirMacsHashDifferently` |
| **M-A7** | **IPv4 分支保留 frame 的 MAC（＝`d3c65dd4` 的 F1 缺陷）** | `SFlowType.hpp` | ✅ caught | `OneIpv4FlowStaysOneRowWhenTheMacsChangeAtEveryHop`／`TheParsersOwnIpv4KeyCarriesNoL2Fields` |
| 控制 1 | collector 加一行註解 | `.cpp` | ✅ survived | —（綠才有意義） |
| 控制 2 | `SFlowType.hpp` 加一行註解 | `SFlowType.hpp` | ✅ survived | —（綠才有意義） |

驗收：**7 mutations, 0 survived；2 控制組皆存活；還原後兩個檔案與快照逐位元相同；`GATE_RC=0`。**
⚠️ **round 3 起是 8 顆**：加了 **M-A8**（`hop <= kMax` → `hop < kMax`，由 `SFlowParsingFixture.AChainWithinTheBoundResolvesAndOneBeyondItDoesNot` 殺），而且那一次實跑還多了「baseline 與最終重建的 binary sha 必須相等」這一條裁決。見 §8.6 R12。

兩個控制組（不是一個）的理由：`.cpp` 變異只重建 1 個 translation unit，`SFlowType.hpp` 變異重建 46 個——
規模差一個量級的重建本身就是「撿到舊東西」的機會，各給一個控制才說得準。

---

## 5. 沒做／沒驗（明列）

1. **IPv6 擴展標頭只跳三種**：hop-by-hop(0)、routing(43)、fragment(44)。ESP(50)／AH(51)／no-next(59)／
   destination options(60)／mobility(135)／HIP(139)／shim6(140) 一律當不透明 ⇒ 退 L2。鏈長上限 8，**超過退 L2**
   （round 2 修正，有 9 跳測試）。
2. **「第一個找得到的 IPv6」沒做**：只認外層 ethertype（剝一層 VLAN 之後）。封裝在自訂標頭裡的 IPv6 不會被找出來。
3. **VLAN 只剝一層**：QinQ（第二層 `0x8100` 或 `0x88a8`）不處理，會停在 L2 家族。
4. **側表上限 1024，滿了淘汰最久沒看到的那筆**（round 2 改的；1025 個身份的測試有跑）。淘汰是 O(n) 掃描，
   只在滿表插入時發生；沒有量過它的成本。
5. **HPE（`sampleType == 3`）仍然沒有真實資料**，而**這條路徑上有一個刻意的行為變動**：
   **HPE 分支的 ICMP type 從恆 0 變成訊框裡真正的 type**（§7 F5 ② 指的就是這一句；round 2 說「記在 §5-5」但沒寫，
   round 3 補上）。舊碼把位移放在 `ntohl` 的錯誤側（`icmpType = ntohl(data[index + 28] >> 8) & 0xFF;`，
   base `FlowLinkUsageCollector.cpp:1371`），在 little-endian 主機上**對任何訊框都算出 0**；
   現在 type 由 `identifyFrame` 從 frame bytes 讀，是真值。因為這個 vendor 從來沒有真實資料，
   沒有任何已發表的數字依賴那個 0——這也正是它一直沒被發現的原因。
   round 3 加了測試 `AnHpeIcmpSampleCarriesTheRealIcmpTypeRatherThanAConstantZero`（§8.4）。
   repo 裡沒有任何 HPE capture，以前沒有、現在也沒有。round 2 加的
   `AnHpeSampleIsReadFromWhereTheBranchSaysTheFrameIs` **釘的是這個分支自己的算術，不是某家廠商的線上格式**——
   測資是照分支自己用的位移（rate +5、in +9、out +11、frameLength +16、frame 從 +20）造出來的。
   它也讓一個既有缺陷變得可見：MININET 下分支尾端的推進會扣掉一個 type-3 樣本根本沒有的 extended_switch record，
   所以 parser 認為樣本早結束兩個 word，**frame 最後 8 bytes 讀不到**（測試裡的 frame 因此補了 20 B 尾巴，
   這是量出來的，不是猜的：第一版兩個 port 都讀回 0）。這段算術比本工單早，我沒有動它。
6. **完全沒有 live**：沒 sudo、沒 `ndt up`、沒 bmv2、沒 psample。全部離線 fixture。
7. **沒有量效能**：`readSampledHeader` 每個樣本多一次 ≤256 B 的複製，沒有 benchmark。
8. **`to_json`／`from_json(FlowKey)` 沒動**（仍只寫 IPv4 五個欄位）。今天安全，因為非 IPv4 的鍵進不了流表也進不了
   edge flow set；但如果哪天併表了，那兩支會**安靜地**掉掉家族資訊。
9. **`doc/2026-01-02_ndt_api.md` 沒動**（不是 A 的檔案）：它的 `get_detected_flow_data` 範例現在少了 `family`，
   而 `get_sflow_stats` 它從來沒寫過。
10. **`getFlowInfoJson` 的 `family` 今天恆為 `"ipv4"`**——因為流表就是 IPv4-only（§6 異議 1）。
11. **L1 lane 其餘 13 個 problem group 沒修**（不是我的；證據見 §2）。
12. ~~**這個 build 不是 bit-reproducible**：同樣的來源、不同的物件組合，binary sha 會不同（§2 #17）。沒有深究原因。~~
    🔴 **收回（round 3，見 §8.2）**：它是 bit-reproducible；當時看到的 sha 變動是閘門的 `restore` 讓最後那次重建變成
    no-op，留下控制組 2 的 binary。round 3 的閘門在 baseline 與最終重建各記一次 sha 並斷言相等。

---

## 6. 異議 / objections

**1. 流表能不能裝非 IPv4 家族——工單自相矛盾，我選了側表，最終取捨請 orchestrator 裁。**
§2.3 要「FlowKey 三個家族」並說 `emitted_arp.bin`「改用它驗 L2」，同一段又寫「契約測試不動……且仍綠」。
但那兩支凍結的測試斷言的正是**流表裡不能有非 IPv4**（`test_GoldenFixture.cpp::IgnoresNonIpv4Frames`、
`test_SFlowEmitterRoundtrip.cpp::IgnoresEmittedArpWithoutInventingAFlow`）。所以非 IPv4 身份進一張有上限的側表。
**要併成一張表，就得改那兩支凍結測試**——那是 orchestrator 的裁量。

**2. 我動了一個不在 A 清單上的檔案：`tests/test_LastHopAttribution.cpp`。**
它的 `AnIngressLessSampleIsNotBankedTwice` 斷言的字面意思是「ingress-less 樣本已經被記在 ingress 銀行了，egress 銀行
不可以再拿」——那正是 §2.2 第二條要移除的行為。這個檔案不屬於 B／C／D 任何一人，也不在「不動」清單。我改寫成從兩邊
斷言新規則並改了名。**若 orchestrator 認為這也算越界，請回退這一個 hunk 並告訴我怎麼處理那條矛盾。**

**3. §3.1 的「三個 commit、每個自己綠」沒照做。** 拿掉 etherType 的 `continue` 必須先有 frame parser，
「位元組先記」與「FlowKey 家族」在這份碼裡不是兩個可以各自綠的中間狀態；要硬切就得寫一個只活五分鐘、
而且**我沒為它跑過測試**的中間版本，那不能宣稱綠。

**4. `merged_checks.sh` 無法檢查 worktree**（第 4 行寫死主 checkout 路徑）。建議 D 改成
`cd "$(git rev-parse --show-toplevel)"`，否則階段三每個 worker 的那一格都在檢查同一棵樹。

**5. L1 應該裸跑，不要包在 guard 裡。** `--no-build` 不編譯任何 C++，包進 guard 會讓 `test_build_guard.sh` 的 8 格
變紅（巢狀 shim 改了它在量的 `-j` 改寫）。這是我 round 1 的操作失誤；round 2 裸跑後那 8 格全綠。

**6. `telemetry_health.addressed_total` 口徑變了**（舊：所有 `0x0800` 樣本扣掉 TCP/UDP/ICMP 非首片分段；
新：所有 flow sample）。E 組拿它做取樣誤差對帳時要知道。

**7. TCP ACK 旗標的位移原本錯 3 個 byte，順手改對了。** 舊碼 Brocade 讀 `data[index+28]`、HPE 讀 `data[index+32]`
（⚠️ round 1 原文寫成「兩個分支都讀 +28」，錯的是報告），兩者都落在 frame byte 50 ＝ TCP byte 16（checksum 高位），
正確的是 TCP byte 13。實測 `emitted_tcp.bin`：舊式子讀到 `0x00`，真正的 flags byte 是 `0x10`（ACK）。
**可觀察的下游只有一行 TRACE log**（`isAck`／`isPureAck` 全 repo 沒有讀者，已 grep 確認）。

**8. `samples_by_family` 多了第四個鍵 `undecodable`。** §2.3 只寫 `{ipv4, ipv6, l2}`。連 14 B 乙太標頭都不完整的樣本
不屬於任何家族，算進 `l2` 會讓那個數字說謊。**若 D／E 的斷言要求恰好三個鍵，請告訴我拿掉。**
另外：`ihl < 5` 的樣本算進 `ipv4`（它確實是 IPv4 訊框），同時計入 `malformed_ipv4_ihl`。

**9. round 1 第一次閘門的 rc 沒擷取**（`setsid nohup` 背景跑沒包 rc）。最終那次（#17）有 `GATE_RC=0`。

**10. 這台機器上，一顆 `SFlowType.hpp` 變異＝重建 46 個 TU。** round 1 的 `restore()` 無條件 touch 每個快照檔，
等於每顆變異都付一次近全樹重建，整支閘門 1h45m；round 2 改成只 touch 真的寫過的檔，同樣 7 顆＋2 控制跑完約 1h20m。
**磁碟是這台機器的硬限制**：05:34 根檔案系統歸零（driver 測試的 `/tmp/drv-*` 洩漏，59,679 個目錄，orchestrator 清掉），
把我第一次 `d3c65dd4` 重跑的 restore 步驟打斷（`cp: No space left`），留下 0 byte 的 `SFlowType.hpp` 與截斷的
`FlowLinkUsageCollector.cpp`——**兩者都已由 `git checkout --` 還原，並在事後確認 worktree 乾淨**。
閘門的 EXIT trap 保護不了磁碟滿；這是它的已知邊界。

**11. 這支閘門有兩個讀者，只有一個會跑它。** 三次（`run_control` 包裝、`DIRTY+=("$1")`、anchor 裡的 `//`）
我寫出對 bash 正確、對 `check_gate_anchors.py` 錯誤的寫法，其中兩次的症狀是「這支閘門沒有被檢查」而不是紅字。
**建議把這三條寫進 gate 撰寫慣例**：anchor 不要含斜線、`apply` 要在呼叫點原樣出現、標籤不要有撇號。

---

## 7. Round 2（fable-judge `P3-A-JUDGE.md` 的 F1–F5）

### F1（blocking）— IPv4 的 key 帶著 MAC，一條流會按跳數裂成多筆 ⇒ 已修

`identifyFrame` 先把 `dstMac`／`srcMac`／`ethType` 寫進 `out.key`，IPv4 分支從不清掉。`operator==` 是 defaulted、
流表是 `unordered_map` ⇒ 在 NDTwin fabric 上（每跳改寫兩個 MAC、取樣是 I2E clone 帶入口 MAC）同一個五元組
在每一跳都是不同的 key。後果：`get_detected_flow_data`／top-k 重複列、每筆 rate 只平均自己那一跳、classifier 每筆
分派一次、`to_json/from_json` 不寫 MAC ⇒ 讀回的鍵永遠不等於表裡的。

**修法**（`4934a604`）：MAC 與 ethertype 留在區域變數；L2 身份組一次；IPv4／IPv6 分支**整個覆寫** key
（`out.key = FlowKey{}`）而不是往上加。規則寫進標頭：**一把 key 只帶它家族指名的欄位**。hash 的早退不受影響。

**證明**：`OneIpv4FlowStaysOneRowWhenTheMacsChangeAtEveryHop`（同五元組、不同 MAC 對、不同埠 ⇒ 流表 1 筆、
`agentFlowStats` 2 筆）＋`TheParsersOwnIpv4KeyCarriesNoL2Fields`＋`AnIpv6KeyCarriesNoL2FieldsEither`；
變異 **M-A7** 把缺陷放回去，兩顆都紅（§4）。

round 1 的測試為什麼看不到它，值得記下來因為那是一種模式：它們一次斷言五個具名欄位（第六個錯了看不見）、
hash 那顆用手工零 MAC 的 key（parser 根本沒進去）、Golden 是單台 OVS（不改 MAC）、emitted fixture 的 MAC 是固定的。
**「只差 MAC 的兩個訊框」這個性質，沒有任何一個 committed fixture 表達得出來**——所以新測試自己造訊框。

### F2 — 補測試（上面三顆）＋M-A7 變異。**加一顆，不是換掉舊的**：round 2 把 `restore` 改成只 touch 真的寫過的檔，省下的時間足夠第七顆。

### F3 — 閘門跑到 verdict：`GATE_RC=0`，7 mutations 0 survived（§2 #17、§4）。

### F4 — IPv6 鏈長超過上限沒有退 L2（報告與碼不一致）⇒ 已改碼

舊碼跑滿 8 圈就掉出迴圈、`resolved` 仍是 true ⇒ 記成 IPv6 而 `protocol` 是 0／43／44（把擴展標頭當成上層協定），
ports 讀到的是碰巧在那個位移的位元組。現在多跑一圈，只為了發現「手上還是鏈標頭」⇒ `resolved=false` ⇒ 退 L2。
**證明**：`AChainWithinTheBoundResolvesAndOneBeyondItDoesNot`（8 跳解出 UDP 4242/4243，9 跳退 L2、ports 0）。

### F5 — round 1 沒說的行為變動（現在都在 §1／§5／§6，並各有測試或決定）

| 項 | 處置 |
|---|---|
| ① `m_lastSampleFromAgentMillis` 與每埠時間戳改成每個 MININET flow sample 都寫（ARP/LLDP 也算「這台在取樣」） | **這是要的語意**（A-4f 問的是「這台還在不在取樣」）。測試 `AnArpOnlySwitchCountsAsASwitchThatIsSampling`：該埠 `live`、同 agent 其他埠 `idle`、沒聽過的 agent 仍 `unknown`（控制組） |
| ② HPE ICMP type 從恆 0 變真值 | 記在 §5-5；那條路徑仍然沒有真實資料 |
| ③ 側表無淘汰（IPv6 鍵含 ports，一輪就填滿 1024） | **改成 LRU（最久沒看到的先走）**，並publish `evicted_least_recently_seen`。測試 `TheSideTableEvictsItsOldestIdentityRatherThanRefusingNewOnes`（1025 個身份 ⇒ tracked 1024、evicted ≥ 1、dropped 0）。第一版只造出 256 個身份（L2 的 key 是兩個 MAC＋ethertype，而它只變了 payload 的一個 byte）——**跟 F1 同一類的錯：測試以為自己在變 key** |
| ④ ICMPv6 code 也遮 4 bits | **改掉**：IPv4 遮是因為要跟舊碼逐位元相同，新家族沒有這個包袱，遮就變成一個「決定」 |
| ⑤ IPv4 但 protocol ∉{1,6,17} 也記位元組 | 記在 §1.1；符合 §2.2 |

另外 judge 要的兩顆也補了：`ANonFirstFragmentBanksItsBytesAndDoesNotEndTheDatagram`（分段記位元組、不進流表、
**同一個 datagram 後面的樣本仍被處理**）與 `AnHpeSampleIsReadFromWhereTheBranchSaysTheFrameIs`（§5-5 的但書）。

### Round 2 我不同意／要 orchestrator 知道的

- judge 說「F2 那顆變異可以換掉六顆之一」——**我沒換，七顆全留**，因為換掉任何一顆都會讓一條已知會壞的路失去守衛，
  而 `restore` 的改動已經把時間賺回來（1h45m → 約 1h20m）。
- **`AnHpeSampleIsReadFromWhereTheBranchSaysTheFrameIs` 是儀器對著自己的發現**：測資是照分支自己的位移造的，
  所以它能證明「重寫沒有改變這個分支讀 frame 的位置」，**不能**證明「HPE 交換機送的就是這個形狀」。
  這條限制寫在測試的註解與 §5-5，不要把它當成 HPE 支援的證據。

---

## 8. Round 3（orchestrator 裁定 11；head `f7bbee8e`）

round 2 的碼（F1／F4／F5）站得住；不站的是**閘門自己的收尾**與**報告對 binary 的出處宣稱**。
這一節是裁定 11 的逐條交代。§1–§7 不回頭改寫，錯的句子就地劃掉並指回這裡。

[Co-developed with claude code -- Adam]

### 8.1 head、檔案、binary

- head：**`f7bbee8e`**（`26e279eb..f7bbee8e` 一顆 commit）
- `git -C <wt> diff --stat 26e279eb..f7bbee8e`：

```
 include/common_types/SFlowType.hpp                 |  16 +-
 include/ndt_core/collection/FlowLinkUsageCollector.hpp |  27 ++-
 src/ndt_core/collection/FlowLinkUsageCollector.cpp |  21 +-
 tests/shell/mutate_flowkey_families.sh             |  98 ++++++---
 tests/test_FlowKeyFamilies.cpp                     | 232 ++++++++++++++++++++-
 5 files changed, 346 insertions(+), 48 deletions(-)
```

  五個檔案全部在工單 §0-7 指給 A 的清單內（沒有為了編譯而動別人的檔案；`tests/test_LastHopAttribution.cpp` 是 round 1 就宣告過的那一個例外，本輪沒有再動它）。
- 測試 binary：`build/bin/test_routing_strategy` sha256 前 16 碼 **`2911b19e88b2bfcb`**
  （log `<G>/binary_sha.p3a-f7bbee8e.log`）。**§8.6 的 gtest／ctest 兩列就是在這顆上跑的**，
  而閘門的 baseline 與最終重建各記一次 sha 並斷言相等——見 §8.2。

### 8.2 裁定 11a：閘門的 `restore`、baseline 的 touch、與兩次 binary sha

**round 2 錯在哪（診斷，不是推測）。** `restore()` 對兩個檔**無條件** `cp -p`（把快照的舊 mtime 蓋回去），
只對 `DIRTY` 裡的檔 `touch`，然後清空 `DIRTY`。控制組 2 的 `classify_control` 結尾已經呼叫過一次 `restore`
（那次有 cp＋touch），`:441` 的第二次呼叫把剛 touch 出來的新 mtime 又蓋回舊值，而 `DIRTY` 已空所以不 touch
⇒ `:443` 的 `build` 看到 `SFlowType.hpp` 比所有 `.o` 都舊 ⇒ **ninja 無事可做**。
所以 log 裡的 `rebuilt from the restored tree` 是對一個 no-op 印的，留在磁碟上的是**控制組 2 的 build**
（`SFlowType.hpp` 多一行註解，把它後面所有行號往下推一行 ⇒ Debug build 的 DWARF 不同 ⇒ sha 不同）。
EXIT trap 再 cp -p 一次，**下一支閘門的 baseline 也不會重建**。

**「不是 bit-reproducible」是錯的解釋。** round 1 的 log
`<G>/mutate_flowkey_families.p3a-fc563aa3.log:47` 寫的是 `test binary: c9dc9fb2fa870c55 (was c9dc9fb2fa870c55)`
——同一套流程、無條件 touch、真的重建，**跑前跑後同一顆 sha**。差別在腳本，不在編譯器。§2 #17、§2 的
`:134-138`、§5-12 都已就地劃掉。

**修法（`f7bbee8e`）三條：**

1. `restore()` 冪等：`cmp -s` 相同就跳過、不同才 `cp -p` ＋ `touch`。問檔案系統而不是維護一個「這次寫過誰」
   的陣列——連著呼叫兩次，第二次照定義是 no-op。`DIRTY` 整個拿掉。
2. **baseline build 之前 `touch` 兩個檔**。baseline 是所有裁決的比較基準，它必須真的是一次 build：
   前一次（或前一次被中斷的）跑留下的 `.o` 比來源新的話，「baseline 綠」講的是別人的 binary。
3. **baseline build 之後與最終 rebuild 之後各記一次 binary sha，不相等就 `ok=0`（GATE_RC≠0）。**
   `build` 沒事可做時也回 0，所以退出碼證明不了「重建發生過」；同來源同編譯器同目錄的兩顆 binary
   必須是同一顆檔案，不是的話要嘛重建沒發生、要嘛這個 build 不可重現，兩種都讓之後所有量到的數字失去出處。
   EXIT trap 用同一個 `restore`。

sha 前後證據見 §8.6 閘門列的 `test binary:` 那一行。

### 8.3 裁定 11b／11c：碼的改動

- **11b `dropped_over_capacity` 與 `m_nonIpv4ObservationsDropped` 移除。** 側表改成淘汰之後全 repo 沒有一處寫它
  （`grep` 過：唯一的讀在 `FlowLinkUsageCollector.cpp:1145`），那個鍵只會讀到 0。
  **只會讀到 0 的 API 鍵不是量測，是在宣稱量過某件事。** `test_FlowKeyFamilies.cpp:972` 的恆真式跟著刪，
  `:573` 那一顆同樣斷言（裁定只點名 `:972`，但 `:573` 讀同一個鍵、鍵沒了會紅）改成斷言**這個鍵不存在**。
  §1.4 已更正。
- **11c 淘汰順序改由 steady clock 決定。** `FamilyObservation` 現在有兩個時戳，**頭檔寫明誰是誰**：
  - `lastSeenSteadyMs`＝`utils::getCurrentTimeMillisSteadyClock()`（跟 liveness 時戳同一個時鐘）。
    **只有它進淘汰的比較，而且不揭露。**「最久沒看到」問的是兩件事的先後，牆鐘被 NTP 往回撥就答錯，
    而且會一直答錯（剛寫進去的那筆看起來最舊、下一次又輪到它）。
  - `lastSeenWallMs`＝`utils::getCurrentTimeMillisSystemClock()`，**就是 JSON 的 `last_seen_ms`**，
    因為 process 外面的讀者拿 monotonic 數字沒有用。**它不決定任何事。**

### 8.4 裁定 11e：新測試，與每一顆「怎麼看到紅的」

六條全部實跑過一次紅。**臨時 revert 一律在 head `f7bbee8e` 上做、改完立刻還原並逐位元核對**
（腳本 `see_red.sh` 每次跑完印 `restored: <file> is byte-identical to the pre-revert snapshot`；
六次都印了，而且 `git status` 在六次之後是乾淨的）。revert **從來沒有被 commit**。

| # | 測試（`FlowKeyFamiliesTest.` 開頭者省略前綴） | 怎麼看到紅 | 紅的樣子 | log |
|---|---|---|---|---|
| 1 | `TheSideTableEvictsTheLeastRecentlySeenIdentityAndAHitCountsAsSeen`（前半：餵身份 0、睡 3 ms、餵 1..1024 ⇒ 0 不在、1024 在） | **R1** 臨時 revert（`.cpp`）：淘汰掃描的 `<` 改成 `>`＝淘汰**最新**的那筆 | rc=1，該顆紅 | `<G>/seen_red_R1.p3a-f7bbee8e.log` |
| 2 | 同上（後半：命中身份 1、再餵 1025 ⇒ 2 被淘汰、1 還在） | **R2** 臨時 revert（`.cpp`）：時戳只在 insert 寫、命中不刷新 | `:1116`／`:1118` 紅（1 不在、2 還在） | `<G>/seen_red_R2.p3a-f7bbee8e.log` |
| 3 | `AnIpv4SampleOfAnotherProtocolBanksItsBytesAndIsCountedWithoutBeingAFlow`（protocol 89＋2） | **R3** 臨時 revert（`.cpp`）：位元組只在 protocol∈{1,6,17} 才記＝P3 前計數器的位置 | `:1163` 紅，banked 0 ≠ 21504 | `<G>/seen_red_R3.p3a-f7bbee8e.log` |
| 4 | `AnIcmpv6SampleCarriesItsTypeAndItsWholeCodeInThePortFields`（code `0x1F` 不被遮） | **R4** 臨時 revert（`.hpp`）：把 IPv4 的 4-bit 遮罩複製到 ICMPv6 | `:1137` 紅，讀到 15 ≠ 31 | `<G>/seen_red_R4.p3a-f7bbee8e.log` |
| 5 | `AnHpeIcmpSampleCarriesTheRealIcmpTypeRatherThanAConstantZero`（type-3 分支） | **R5** 臨時 revert（`.hpp`）：ICMP type 固定成 0＝被刪掉的 HPE 算式的結果 | `:1193` 紅，type 0 | `<G>/seen_red_R5.p3a-f7bbee8e.log` |
| 6 | `AVlanTaggedIpv6SampleIsIdentifiedAsIpv6AfterOneTagIsStripped`（0x8100 後接 0x86DD） | **R6** 臨時 revert（`.hpp`）：不剝那一層 VLAN | `:1208-1218` 紅，family L2、ethType 33024（0x8100）、位址全零 | `<G>/seen_red_R6.p3a-f7bbee8e.log` |
| 7 | `SFlowParsingFixture.AChainWithinTheBoundResolvesAndOneBeyondItDoesNot`（9 跳退 L2） | **閘門變異 M-A8**：`hop <= kMax` → `hop < kMax` | 見 §8.6 閘門列 | `<G>/mutate_flowkey_families.p3a-f7bbee8e.log` |

**為什麼 1 與 2 要兩個 revert。** 那一顆測試有兩個獨立的主張（「最久沒看到的走」與「命中算一次看到」），
一個 revert 只能打倒其中一個；兩個都打過，才知道兩半都有鑑別力。
**round 2 那一顆（`TheSideTableEvictsItsOldestIdentityRatherThanRefusingNewOnes`）留著**，它斷言的是
「1025 個身份之後 tracked 還是 1024、evicted ≥ 1」——那是容量，不是順序；新的這顆才問「走的是**誰**」。
round 2 只問了數量，而**一張每次都把最新到的那筆丟掉的表也會通過它**。

### 8.5 裁定 11d：HPE 分支的 `+20` 對 sFlow v5 規格（只對帳，不改碼）

**來源聲明：沒有網路。** 依據是①我對 sFlow v5 規格（sflow.org `sflow_version_5.txt` 的
`flow_sample_expanded`／`flow_record`／`sampled_header` 三個結構）的既有知識，
②repo 裡**可對帳的第二來源**：`p4_proxy/proxy_agent/sflow_emitter.py:21-47` 把 **format 1**（非 expanded）
的逐字 word 佈局寫在註解裡，而那份佈局有 golden fixture 與 `test_sflow_emitter.py` 釘著，
Brocade 分支讀它的四個位移**逐個對得上**——所以同一套結構知識在這個 repo 內部是被校準過的，不是空口。

**規格的排法**（word 索引以 sample 的第一個 word＝`sample_type` 為 `+0`；expanded 版的
`sflow_data_source_expanded` 與 `interface_expanded` 都是**兩個** word）：

```
+0  sample_type = 3          +8  input format        +16 frame_length
+1  sample_length            +9  input value         +17 stripped
+2  sequence_number          +10 output format       +18 header_length（opaque 的長度前綴）
+3  source_id type           +11 output value        +19 frame 的第一個 byte
+4  source_id index          +12 flow_records_count
+5  sampling_rate            +13 record[0] data_format
+6  sample_pool              +14 record[0] length
+7  drops                    +15 header protocol
```

**碼讀的是**（`FlowLinkUsageCollector.cpp` 的 `sampleType == 3` 分支）：`sampling_rate` `+5`、
`input` `+9`、`output` `+11`、`frame_length` `+12+4 = +16`——**這四個全對**，
而且只有「record[0] 就是 raw packet header、沒有 extended_switch」時才會對，所以碼自己的假設也是單一 record。
**唯一對不上的是 frame 的起點：碼用 `+20`，規格是 `+19`。**

**結論：不同意碼的 `+20`，同意判官的 `+18 header_length／+19 frame`。** 這是**本工單之前就有的假設**
（base `8eddb0e8` 的同一分支讀 ethertype 的位置是 `index + 12 + 6 + 5 = +23`，正是「frame 從 +20」推出來的那一個 word），
TICKET-P3 沒有動它，本輪也不動（11d 明寫只對帳）。碼自己的註解其實已經指到同一個地方：
「`+16` 當 original length 的話，frame 前面會剩下一個解釋不掉的 word」——那個 word 就是 `header_length`。

**如果真的有一台 HPE agent 送樣本進來會怎樣**（推論，沒有資料可驗）：frame 會從它的第 5 個 byte 開始讀，
ethertype 會落在來源 MAC 中間 ⇒ 幾乎不可能等於 `0x0800`／`0x86dd` ⇒ 每個樣本都被判成 L2、兩個 MAC 是錯的；
P3 之後位元組照記（鏈路使用率仍然對），P3 之前整個樣本被丟掉。
**另外那個 2-word 的不足是另一回事**：MININET 下分支尾端的推進扣掉一個 type-3 樣本沒有的 extended_switch record
（`sampleLen/4 + 2 - 2`），所以樣本的**結尾**早兩個 word——一頭晚一個 word、一頭早兩個 word。
兩者都留給 orchestrator 記進工單 §9 裁定 6。

### 8.6 驗證表（head `f7bbee8e`；`<G>` ＝ `scratch/overnight-2026-09-05/logs/gates-0910`）

| # | 指令 | rc | 那一行就是裁決 | log |
|---|---|---|---|---|
| R1 | `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh cmake --build build --target test_routing_strategy` | 0 | `guarded_build: exit 0` | `<G>/p3a-r3-build1.log` |
| R2 | `sha256sum build/bin/test_routing_strategy` | 0 | `BASELINE-BIN-SHA 2911b19e88b2bfcb` | `<G>/binary_sha.p3a-f7bbee8e.log` |
| R3 | `./build/bin/test_routing_strategy`（整顆直跑） | 0 | `[  PASSED  ] 1366 tests.`（＝1361＋5，五顆新的都在） | `<G>/gtest_direct.p3a-f7bbee8e.log` |
| R4 | `ctest --output-on-failure`（在 `build/`） | 0 | `100% tests passed, 0 tests failed out of 1366` | `<G>/ctest.p3a-f7bbee8e.log` |
| R5 | `/home/adam/p4dev-python-venv/bin/python p4_proxy/tests/generate_emitted_fixtures.py` | 0 | 12 個 fixture 寫出（`wrote emitted_egress_only.bin: 180 bytes (45 words)` 是最後一個）。⚠️ **直譯器是 `/home/adam/p4dev-python-venv`，不是工單 §0-4 寫的 `p4_proxy/venv`**（round 3 的表沒講；R7 兩個都跑過、結果相同，見下一列） | `<G>/regenerate_fixtures.p3a-f7bbee8e.log` |
| R6 | `git diff --exit-code -- tests/fixtures`（緊接 R5） | **0** | `rc=0`，diff 無輸出＝**重生的 12 個 fixture 與 committed 的逐位元相同** | `<G>/fixtures_byte_identical.p3a-f7bbee8e.log` |
| R7 | `python -m unittest tests.test_sflow_emitter`（`p4_proxy/` 下） | 0 | `Ran 49 tests` / `OK`。⚠️ **只有第一個直譯器（`p4dev-python-venv`）的完整輸出進了 log；第二個（`p4_proxy/venv`）只留下 `RC_p4proxy_venv=0` 一行 rc**——它的 49 顆沒有逐行存檔，要重驗請重跑 | `<G>/test_sflow_emitter.p3a-f7bbee8e.log` |
| R8 | `python3 tests/shell/check_gate_anchors.py HEAD` | 0 | `111/111 cells ok`；本閘門 **`mutate_flowkey_families.sh ok(10)`**（round 2 是 `ok(9)` ⇒ **M-A8 那一格進來了**） | `<G>/check_gate_anchors.p3a-f7bbee8e.log` |
| R9 | `python3 tests/shell/check_process_by_name.py` | 0 | `299 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` | `<G>/check_process_by_name.p3a-f7bbee8e.log` |
| R10 | 凍結測試未動（§8.7 逐字） | 0 | **空輸出** | `<G>/frozen_tests_untouched.p3a-f7bbee8e.log` |
| R11 | 六次「看到紅」的臨時 revert（§8.4） | 各 1（紅） | 每支都以 `restored: <file> is byte-identical to the pre-revert snapshot` 收尾 | `<G>/seen_red_R{1..6}.p3a-f7bbee8e.log` |
| R12 | `bash tests/shell/mutate_flowkey_families.sh`（`setsid nohup`，包了 `GATE_RC=`） | **0** | `8 mutations, 0 survived` ＋ `GATE_RC=0`（見下） | `<G>/mutate_flowkey_families.p3a-f7bbee8e.log` |

**R12 閘門的四行裁決**（`<G>/mutate_flowkey_families.p3a-f7bbee8e.log`，09:33–11:27 實跑）：

```
  both files byte-identical to the pre-run snapshot
  rebuilt from the restored tree
  test binary: 2911b19e88b2bfcb (baseline 2911b19e88b2bfcb, on disk before this run 379e82d3ced8f8ce)
  8 mutations, 0 survived
GATE_RC=0
```

**這三顆 sha 就是裁定 11a 的證據，值得逐個講：**

- `379e82d3ced8f8ce` ＝**閘門開跑前躺在磁碟上的那顆**。它是 §8.4 最後一個 revert（R6）**變異版**的 build：
  `see_red.sh` 把來源還原並 touch 了，但沒有再建一次。**round 2 的閘門在這個狀態下會直接把它當成 baseline**
  ——「baseline 綠」講的會是一顆含著 R6 缺陷的 binary。11a 的 `touch "${FILES[@]}"` 就是為了這一格：
  閘門 touch 兩個檔、真的重建、得到 `2911b19e88b2bfcb`。
- `2911b19e88b2bfcb`（baseline）**＝`2911b19e88b2bfcb`（最終重建）＝§8.6 R2 我在閘門之前獨立建出來的那顆**。
  **三次各自獨立的 build、同一份來源、同一顆 sha。** 這既證明最後那次重建**真的發生了**
  （它從 R6 之後的髒狀態走回 baseline），也正面推翻 round 2「這個 build 不是 bit-reproducible」的說法。
- 八顆變異全被具名測試殺、兩個控制組都存活（所以閘門量的是行為不是「檔案被改過」）、
  還原後兩個檔與快照逐位元相同、`GATE_RC=0`。**M-A8 由 `SFlowParsingFixture.AChainWithinTheBoundResolvesAndOneBeyondItDoesNot` 殺**
  ——這是裁定 11e(6) 要的那一格，也補上 round 2 判官指出的「F4 的斷言沒有上過變異」。

閘門的 baseline 這次跑的是 `1366 cases`（＝R3 的數字），所以「baseline 綠」與「整顆綠」是同一個母體。

### 8.7 凍結測試未動（逐字的指令與它的空輸出）

```
$ git -C <wt> diff --stat 26e279eb..f7bbee8e -- tests/test_GoldenFixture.cpp tests/test_SFlowEmitterRoundtrip.cpp tests/fixtures
$                                     <- 沒有任何輸出，rc=0
```

對 base 也一樣只有 round 1 新增的那五個 `.bin`（沒有一個既有 fixture 被改）：

```
$ git -C <wt> diff --stat 8eddb0e8..f7bbee8e -- tests/test_GoldenFixture.cpp tests/test_SFlowEmitterRoundtrip.cpp tests/fixtures
 tests/fixtures/emitted_custom_0x1234.bin | Bin 0 -> 164 bytes
 tests/fixtures/emitted_egress_only.bin   | Bin 0 -> 180 bytes
 tests/fixtures/emitted_ipv4_ihl6_tcp.bin | Bin 0 -> 196 bytes
 tests/fixtures/emitted_ipv6_udp.bin      | Bin 0 -> 200 bytes
 tests/fixtures/emitted_vlan_ipv4.bin     | Bin 0 -> 184 bytes
 5 files changed, 0 insertions(+), 0 deletions(-)
```

### 8.8 對裁定 11 的異議與要 orchestrator 知道的事

1. **沒有異議需要擋併。** 11a–11g 全部照做（11f 落在哪兩段，round 3 的 §8 漏寫了，round 4 補在 §8.9）。下面五條是「做法上的選擇」與「順帶發現」，不是反對。
2. **11b 多刪了一顆斷言。** 裁定只點名 `test_FlowKeyFamilies.cpp:972`，但 `:573`
   （`TheStatsObjectCarriesEveryFamilyAndTheNonIpv4Identities`）讀同一個鍵；鍵拿掉之後它會紅。
   兩顆都改了：`:972` 整句刪，`:573` 改成**斷言這個鍵不存在**——API 少一個鍵是對外可見的變動，
   要有一顆測試講出來，而不是靜靜地沒人提。
3. **11c 我保留了一個對外的牆鐘欄位。** 裁定說「若牆鐘 last_seen 要給讀者，它是獨立欄位」——我照這條做了，
   `last_seen_ms` 仍然是牆鐘（process 外的讀者拿 monotonic 沒有用），淘汰只看 `lastSeenSteadyMs`。
   **`get_sflow_stats` 的 JSON 值域因此沒有變**（除了 `dropped_over_capacity` 被拿掉）。
4. **11e(1) 我用了兩個 revert，而且沒有拿掉 round 2 那一顆。** 理由在 §8.4 末段。
5. **11d 的結論是「不同意碼」**（§8.5）：HPE 分支的 frame 起點應該是 `+19` 不是 `+20`，而且樣本的結尾
   另外早兩個 word。兩個都是本工單之前就有的假設、本輪不改；**請 orchestrator 收進工單 §9 裁定 6**。
6. **commit trailer 與這個分支前 11 顆不同。** 本 session 的 harness 指定
   `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`（明寫「取代先前的署名指示」），
   而 `26e279eb` 以前是 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。我照 harness 寫，
   在這裡講一聲免得看起來像手滑。
7. **這份 SUMMARY 沒有進版控**：`git -C <wt> ls-files scratch/` 是空的，`.gitignore:46` 就是 `scratch/`。
   所以它只存在於磁碟上的 `scratch/overnight-2026-09-05/hunt-0911/fix/P3-A-SUMMARY.md`，沒有 commit。
8. **磁碟**：跑完整輪之後根檔案系統 3.1 GB 可用（沒有新建 build 目錄；臨時檔都在 session scratchpad，跑完即刪）。

### 8.9 裁定 11f 落在哪兩段（round 4 補；round 3 的 §8 漏了這一條）

11f 要求的兩處註解修正都在 `include/common_types/SFlowType.hpp` 開頭那個 `identifyFrame` 的說明區塊裡，
`f7bbee8e` 的行號是：

- **`:131-143`**——原文「唯一刻意的差異是 TCP ACK」。改成 **`TWO deliberate differences, not one`**，
  a. 是 TCP ACK 的位移（frame byte 50／TCP byte 16 ⇒ TCP byte 13），
  b. 是 **HPE（sample type 3）的 ICMP type 從恆 0 變真值**；並寫明這個 vendor 在本 repo 從來沒有真實資料，
  所以沒有任何已發表的數字依賴那個 0——那正是它一直沒被發現的原因。
  （round 4 的 18② 把這段結尾的指標從 gitignored 的 `P3-A-SUMMARY.md` 換成 trunk 上的工單 §9，
  所以在 `8ec8092a` 它是 **`:131-145`**。）
- **`:127-129`**——原文「see the HPE ICMP read, where the shift is inside ntohl」指向**本工單已經刪掉的碼**。
  改成敘述那段被刪的算式本身：`icmpType = ntohl(data[index + 28] >> 8) & 0xFF;`（base
  `FlowLinkUsageCollector.cpp:1371`）把位移放在 byte swap 的錯誤側，在 little-endian 主機上恆為 0。
  兩輪的行號相同。

### 8.10 兩件「沒驗到／驗不到」的事，明講（round 4 補）

1. **`test_gate_exit_code_not_tee.sh` 我沒跑，orchestrator 補了對照臂，紅的不是我造成的。**
   它在 A 的 worktree（`f7bbee8e`）**5 passed, 2 failed**，在一個**與 A 無關的乾淨 worktree**
   （`wt-p3-fabric-0919`，`80c97464`）**同樣 5 passed, 2 failed**，只有主 checkout 綠 7/0——
   而主 checkout 的 `ROUND_DIR`（`doc/audit/2026-08-31_sampling-ceiling-after-merge/`）裡有兩個**未提交**的
   dryrun log。⇒ 這支測試讀的是 working tree 的檔案，它的綠取決於某個 checkout 的未提交狀態，
   跟本工單的改動無關。**記為既有缺陷候選，本輪不修**（不是 A 的檔案）。
   logs：`<G>/test_gate_exit_code_not_tee.p3a-f7bbee8e.orchestrator.log`、
   `<G>/test_gate_exit_code_not_tee.control-wt-fabric-80c97464.log`（兩支最後一行都是 `5 passed, 2 failed`）。
2. **閘門新加的「最終 sha ≠ baseline sha ⇒ `ok=0` ⇒ exit 2」這條斷言，沒有被看過紅。**
   §8.6 R12 那一跑它是綠的（兩顆都是 `2911b19e88b2bfcb`），而綠只證明它沒有誤報。
   **它真正要抓的那一次已經發生過**：round 2 的 log
   `<G>/mutate_flowkey_families.p3a-26e279eb.log:52` ＝ `test binary: 2f44f739d719f37e (was 056bcc79aed557db)`
   ——那一跑的最終 binary 就不是 baseline 的那一顆（是控制組 2 的），有這條斷言的話那一跑會 `GATE_RC=2`。
   本輪不做 seam（跑一次完整閘門要兩小時），**記為候選**：把 baseline 與最終 sha 的比較抽成可注入的一步，
   或加一個只跑 baseline＋最終重建的短模式。

---

## 9. Round 4（orchestrator 裁定 18；head `8ec8092a`）

judge 對 `f7bbee8e` 的裁定是 **MERGE AFTER FIXES**，而「碼（11a–11f）逐條追到 call site 都站得住、沒有行為缺陷」——
擋在前面的是文字與證據缺口。本輪**沒有任何行為改動**。

[Co-developed with claude code -- Adam]

### 9.1 head 與 diffstat

- head：**`8ec8092a`**（`f7bbee8e..8ec8092a` 一顆 commit）

```
$ git -C <wt> diff --stat f7bbee8e..8ec8092a
 include/common_types/SFlowType.hpp                  |  4 +++-
 include/ndt_core/collection/FlowLinkUsageCollector.hpp |  8 +++++---
 src/ndt_core/collection/FlowLinkUsageCollector.cpp  |  7 ++++---
 tests/test_FlowKeyFamilies.cpp                      | 21 ++++++++++++++++-----
 4 files changed, 28 insertions(+), 12 deletions(-)
```

- 另外刪掉了這個 worktree 裡那份**未追蹤**的 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/TICKET-P3-observation.md`
  複本（裁定 18⑦）。trunk 上那份是唯一一份；`git status --porcelain` 現在是空的。

### 9.2 逐條（18①–18⑦）

- **18①** `tests/test_FlowKeyFamilies.cpp` 的分段測試註解改寫成 11g 更正過的機制：
  `continue` **有**推進讀取位置（base `FlowLinkUsageCollector.cpp:1259` 的 MININET index shift 在 base `:1455`
  的 `continue` **之前**執行），只是推進到樣本中間 ⇒ parser 把這個樣本自己的 dropped／ingress word 讀成
  下一個樣本的 type 與長度，從那裡開始失步。**頂端那個 no-progress guard 從來沒有觸發過。**
  註解裡明講「症狀一樣，所以一個沒跑過的 guard 才會被賴到」。
- **18②** 四處要進 trunk 的註解不再指向 gitignored 的 `P3-A-SUMMARY.md`（`.gitignore:46` 就是 `scratch/`），
  改指 trunk 上的 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/TICKET-P3-observation.md` §9：
  `FlowLinkUsageCollector.hpp` 與 `.cpp` 的側表 ⇒ **裁定 8 第 1 項**；
  測試裡 `addressed_total` 的口徑 ⇒ **裁定 8 第 4 項**；`SFlowType.hpp` 的 HPE ICMP type ⇒ **裁定 10 第 5 項**
  （並指出其位移在 **11d** 對過規格）。**五個檔案 grep `P3-A-SUMMARY` ⇒ 0 hit**（rc=1，存檔在
  `<G>/comment_only_citation.p3a-8ec8092a.log`）。
- **18③** §8.9（11f 落在 `SFlowType.hpp:131-143`／`:127-129`，`8ec8092a` 上是 `:131-145`／`:127-129`）、
  以及 §8.6 R5／R7 兩列的但書（R5 用的是 `/home/adam/p4dev-python-venv` 不是 `p4_proxy/venv`；
  round 3 的 R7 只有第一個直譯器有完整輸出、第二個只留 rc）。**本輪 R7 兩個直譯器都留了完整輸出**（§9.3）。
- **18④** `test_gate_exit_code_not_tee.sh`：不修、只引用。見 §8.10-1。
- **18⑤** 閘門「最終 sha ≠ baseline sha ⇒ exit 2」沒看過紅、round 2 的 log 是它真正要抓的那一次。見 §8.10-2。
- **18⑥** 閘門**引用自 `f7bbee8e`**，證據在 §9.4。
- **18⑦** 見 §9.1。

### 9.3 本輪重跑的驗證表（head `8ec8092a`）

| # | 指令 | rc | 那一行就是裁決 | log |
|---|---|---|---|---|
| S1 | `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh cmake --build build --target test_routing_strategy` | 0 | `guarded_build: exit 0`（79/79） | `<G>/build.p3a-8ec8092a.log` |
| S2 | `sha256sum build/bin/test_routing_strategy` | 0 | `BINARY-SHA 43ce21f76c5ae491` | `<G>/binary_sha.p3a-8ec8092a.log` |
| S3 | `./build/bin/test_routing_strategy`（整顆直跑） | 0 | `[  PASSED  ] 1366 tests.` | `<G>/gtest_direct.p3a-8ec8092a.log` |
| S4 | `ctest --output-on-failure` | 0 | `100% tests passed, 0 tests failed out of 1366` | `<G>/ctest.p3a-8ec8092a.log` |
| S5 | `generate_emitted_fixtures.py` | 0 | 12 個 fixture 寫出 | `<G>/regenerate_fixtures.p3a-8ec8092a.log` |
| S6 | `git diff --exit-code -- tests/fixtures` | **0** | log 裡逐字有指令與 `rc=0`，diff 無輸出 | `<G>/fixtures_byte_identical.p3a-8ec8092a.log` |
| S7 | `python -m unittest tests.test_sflow_emitter` | 0 | **兩個直譯器各一段 `Ran 49 tests` / `OK`**（`p4dev-python-venv` 與 `p4_proxy/venv`，這次都留了輸出） | `<G>/test_sflow_emitter.p3a-8ec8092a.log` |
| S8 | `python3 tests/shell/check_gate_anchors.py HEAD` | 0 | `111/111 cells ok`；本閘門 **`mutate_flowkey_families.sh ok(10)`** | `<G>/check_gate_anchors.p3a-8ec8092a.log` |
| S9 | 閘門自己的 anchor 檢查（見 §9.4） | 0 | 十個 anchor 全 `exact=1` | `<G>/gate_anchor_selfcheck.p3a-8ec8092a.log` |
| S10 | `python3 tests/shell/check_process_by_name.py` | 0 | `299 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` | `<G>/check_process_by_name.p3a-8ec8092a.log` |
| S11 | 凍結測試 diff（對 `26e279eb`、`f7bbee8e`、`8eddb0e8` 三個基準）＋`git status --porcelain` | 0 | 前兩個**空**；對 base 只有 round 1 新增的五個 `.bin`；status **空** | `<G>/frozen_tests_untouched.p3a-8ec8092a.log` |
| S12 | 引用證據（subject sha、comment-only diff、grep） | — | 見 §9.4 | `<G>/comment_only_citation.p3a-8ec8092a.log` |

### 9.4 裁定 18⑥：為什麼閘門可以引用 `f7bbee8e`，而不是重跑

**被引用的那一跑**：`<G>/mutate_flowkey_families.p3a-f7bbee8e.log`
（`8 mutations, 0 survived`、兩控制組存活、`both files byte-identical`、
`test binary: 2911b19e88b2bfcb (baseline 2911b19e88b2bfcb, on disk before this run 379e82d3ced8f8ce)`、`GATE_RC=0`）。

**三個 subject 的 sha256（前 16）`f7bbee8e` → `8ec8092a`：**

```
  include/common_types/SFlowType.hpp                      a03014e20d7eed55 -> 523d5c90d70b6c9f
  include/ndt_core/collection/FlowLinkUsageCollector.hpp  543d04b80cc8571e -> b56469c91fd40034
  src/ndt_core/collection/FlowLinkUsageCollector.cpp      5b67604f565b201a -> 0e684db3c036e416
```

檔案內容變了，所以引用**不能**靠「sha 沒變」，只能靠「變的是什麼」：

```
$ git -C <wt> diff --stat f7bbee8e..8ec8092a -- <the three subjects>
 3 files changed, 12 insertions(+), 7 deletions(-)
$ git -C <wt> diff -U0 f7bbee8e..8ec8092a -- <the three subjects> | <濾掉以 // 開頭的增刪行>
        <沒有任何一行>
```

**三個 subject 的每一行增刪都是註解。** 整個 round 4 唯一一行非註解的改動在 `tests/test_FlowKeyFamilies.cpp`，
而且是一顆 `EXPECT_EQ` 的**失敗訊息字串**——`EXPECT_EQ` 的運算式本身一個字沒動（log 裡逐行列出）。
⇒ 八顆變異與兩個控制組的行為結論不可能改變。

**但 anchor 可能位移，所以兩種檢查都做了：**

1. `check_gate_anchors.py HEAD` 在 `8ec8092a`：`111/111 cells ok`，本閘門 **`ok(10)`**（S8）。
2. **閘門自己的 anchor 表**：`mutate_flowkey_families.sh` **沒有 `--dry-run`**——
   🔴 **傳一個不認識的旗標不會被拒絕，它會直接開始跑真的閘門**（我實驗過一次：它印完前兩行 anchor 就因為
   讀端關閉而 SIGPIPE 死掉，停在第 1 節、還沒進第 2 節的快照，worktree 事後確認乾淨）。
   所以改用**把該腳本第 1–133 行（第 0 節自檢＋第 1 節 anchor）原封不動抽出來單獨跑**，
   log 裡附了 `diff` 證明抽出來的內容與原檔逐位元相同。結果：十個 anchor 全部 `exact=1`（S9）。
   **沒有 anchor 位移 ⇒ 不需要動閘門的 anchor 表 ⇒ 不需要重跑到 verdict。**
   **候選**：這支閘門該有一個真的 `--dry-run`（只跑第 0／1 節就退出），以及對未知旗標報錯而不是照跑。

### 9.5 對裁定 18 的異議

**沒有。** 18①–18⑦ 全部照做。兩點要 orchestrator 知道：

1. **18⑥ 的 `--dry-run` 不存在**，我用等價且更保守的做法回答了同一個問題（§9.4-2），並把它記成候選。
   **不要對這支閘門傳未知旗標**——它會開始跑。
2. **commit trailer 本輪照工單／orchestrator 的寫法** `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
   （round 3 那顆用的是本 session harness 指定的 `Claude Opus 5 (1M context)`，已在 §8.8-6 揭露）。
   兩顆不一致，orchestrator 要統一的話請說哪一種。
