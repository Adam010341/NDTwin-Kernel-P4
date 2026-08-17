# P4/bmv2 支援：目前進度與測試流程

> 📍 **歷史文件（2026-08-17 標記）**：現役入口是
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份的「目前進度」是
> **2026-07-30 的**現況，Phase 7/8 之後已大幅過時；保留是為了追溯 P4 支援怎麼演進。
> 要現在的狀態看 `2026-07-27_p4_bmv2_support_plan.md` 與 `2026-07-29_HANDOFF.md`。

對應計畫：[2026-07-27_p4_bmv2_support_plan.md](2026-07-27_p4_bmv2_support_plan.md)　測試分層定義：[2026-07-27_testing_workflow.md](2026-07-27_testing_workflow.md)
環境陷阱（sudo 設定、`pgrep` 數錯、清理殘留、啟動順序）：[2026-07-29_environment_gotchas.md](2026-07-29_environment_gotchas.md)

最後更新：2026-07-30（branch `fix/flow-rate-divide-by-zero`）

---

> ## ⚠️ 2026-08-10 校正：這份文件有一整類過期敘述
>
> 本文多處寫著「Phase 6 未做／圖是死的／`is_enabled` 是 0／P4 liveness 是 stub」。**那些都已經
> 不成立**，逐處已在下文標註，這裡先給總表，免得只讀開頭的人被誤導：
>
> | 文中寫的 | 現況 | 依據 |
> |---|---|---|
> | 「P4 的 liveness 還是 stub，不要用 `is_up` 判斷」 | ✅ 已是真存活偵測（`GET /p4/switch_state` ＋ kernel 三態判決，`Unknown` 不動圖） | `a8db425` |
> | 「`inform_switch_entered` 沒人呼叫，`is_enabled` 是 0、`path` 是 `[]`」 | ✅ 由 `main.startup()` 在 pipeline 推完後呼叫 | 計畫書 Phase 6 |
> | 「`GET /stats/flow/{dpid}` 還是回 `[]`」 | ✅ 已實作（`ryu_flow_stats.py` ＋ `read_table_entries()`） | 同上 |
> | 「`./stack.sh wait` 在 P4 模式一定會逾時（`enabled=0`）」 | ❌ 不再成立 | 同上 |
> | 測試數字（153 個／90 個 C++／`PASSED 90 tests`） | 現為 **C++ 414、p4_proxy Python 312、kernel 側 Python 101** | 2026-08-10 實跑 |
>
> **Phase 6 已完成**（2026-08-10 實機驗證通過）。原本剩的兩件實機驗證都過了：
> `seed_expected_links` 的接收側 port 假設成立（靜態 32/32 ＋ 實機 16/16 ingress port 零矛盾），
> 失效鏈路在 kernel 圖裡維持 down（238 秒、約 7–8 個 poll 週期，只出現 `up=37/40` 一種狀態）。
> 細節見 `2026-07-27_p4_bmv2_support_plan.md` 的 Phase 6 章節。
>
> ⚠️ 同時記下一個測試方法的陷阱：在 bmv2 上 `ifconfig <iface> down` 會讓整台 switch 的 packet-in
> 停擺，害同一台上另一條健康鏈路被誤報失效 —— 見 `2026-07-29_environment_gotchas.md`。
>
> 這份文件為什麼會爛掉：它是手寫的進度快照，而進度靠 commit 前進 —— 和計畫書那張表同一個病
> （計畫書 §「為什麼這張表會過期」自己就寫了）。**要相信這裡的任何數字，先花十分鐘對一遍。**

---

## 先講最重要的一件事

**Phase 6 的圖已經活了**（commit `198bffd` / `e49327a` / `c24bc91`）。下面的數字是實測，不是推論：

| 項目 | 先前 | 現在 |
|---|---|---|
| switch `is_enabled` | 0/10 | **10/10** |
| host `is_enabled` | 0/4 | **4/4** |
| edge `is_up` / `is_enabled` | 0/40 | **40/40** |
| `get_path_switch_count` | 空 | **12 組 pair 都有，`switch_count: 5`** |

~~⚠️ **但 P4 的 liveness 還是 stub**：bmv2 switch 被無條件標成 up，所以不要用 `is_up` 判斷 P4
模式成不成功，要看 `is_enabled`。~~
✅ **已修（`a8db425`）—— 2026-08-10 更正。** proxy 的 `GET /p4/switch_state` 回報事實
（`GetForwardingPipelineConfig` 往返 ＋ LLDP 新鮮度），kernel 用 `p4LivenessFor` 三態判決，
`Unknown` 不動圖。實機驗證：殺掉一台 bmv2 約 10 秒後變 down 並留在 down。**`is_up` 在兩種模式
下都可以信了。**

計畫書原本寫「光做 `inform_switch_entered` 就能解開 BFS」，**實測不成立**：它只會把 switch
*vertex* 設成 enabled，edge 是 `updateLinks()` 設的，而那只在 kernel 輪詢時才跑。

⚠️ **`avg_link_usage` 為 0 通常不是壞掉**，見下面 2e：它刻意排除所有接到 host 的邊，
所以同一台交換機底下的兩台 host 互打一定是 0。

---

## 一、目前應該要有的功能

### A. 已完成，而且有測試證明它對

| 功能 | 說明 | 證據 |
|---|---|---|
| **不會再 SIGFPE 崩潰** | `hopsCounter == 0` 的除以零守衛回來了，並且把速率計算抽成 `computeEstimatedRates` 這個可測的接縫 | 單元測試（含 `hopsCounter == 0` 的迴歸測試） |
| **sFlow parser 不會被打爆** | 加了 `BoundedWords` 邊界檢查。這是 kernel 第二個對外輸入面（任何能送 UDP 到 6343 的東西都碰得到） | ASan 實測：拿掉 `BoundedWords` 就重現 `heap-buffer-overflow` |
| **typed SwitchKind 派發** | `enum class SwitchKind { OVS, BMV2, HARDWARE }`，取代原本用檔名做大小寫敏感的字串比對。O(1) 查表，不再每個 flow 操作都深拷貝整張 BGL 圖 | 單元測試：BMV2 dpid 給 P4 strategy、OVS dpid 給 OVS、未知 dpid 回錯誤 + WARN、只有 `brand_name` 的舊 JSON 仍能正確分類 |
| **同質性驗證** | 拓撲裡 switch 種類不一致會直接 fatal 並列出是哪些 dpid，除非 `ALLOW_MIXED_DATAPLANE` | 單元測試（預設失敗、開旗標後通過） |
| **南向失敗看得見** | `OpResult { ok, httpStatus, message }`，curl 帶 `-w '%{http_code}' --max-time 5`。200 裡面包 `{"status":"error"}` 也算失敗 | 單元測試：mock 回 404／500／timeout |
| **P4 誠實宣告自己的極限** | group/meter 回 `501 unsupported`，而不是像以前那樣安靜地轉給 Ryu | 單元測試 |
| **P4 pipeline 能表達 5-tuple 規則** | `flow_5tuple` ternary 表 + 真正的 priority，前置於 `ipv4_lpm`。LPM 表做不到這件事（LPM 沒有 priority，是比 prefix 長度） | `p4c-bm2-ss` 編譯把關 |
| **ARP 不再被安靜丟掉** | 加了 `l2_forward` exact 表。之前非 IPv4 的 frame 因為沒設 `egress_spec` 就消失了 | 編譯把關 |
| **TTL 不會繞回 255** | 遞減前先檢查 | 編譯把關 |
| **synthesised sFlow 真的能被 kernel 解析** | proxy 自己組 sFlow v5 打到 6343，所以 `FlowLinkUsageCollector`、`Classifier` 和所有 `/ndt/` metric 都不用改 | **跨語言 round-trip**：Python emitter 真的產出的位元組 → 餵進 C++ 真的在用的 parser → 斷言還原出的 5-tuple。TCP／UDP／ICMP／截斷／非 IPv4／多 sample 串接都有 |
| **clone session 250 有被設定** | 沒設的話 bmv2 會**安靜地**丟掉每一份 clone。失敗是硬錯誤而且會講出來 | 單元測試：斷言送出去的 request（session id、CPU port replica、oneof 用哪一邊、`class_of_service = 0`、ALREADY_EXISTS 改用 MODIFY、真失敗回 False） |
| **sample 和真 packet-in 分流** | 靠 `packet_in.reason` 區分。取樣是全部流量的 1/256，讓 sample 跑進 LLDP parser 會把 discovery 淹掉 | 單元測試 |
| **全 bmv2 拓撲用 identity port mapping** | `populateIfIndexToOfportMap` 是去 shell 呼叫 `ovs-vsctl`，它完全不認識 bmv2 的介面，所以會回空 map、每個 port 都變 0 | 單元測試（含「空拓撲」和「混合拓撲」都必須維持原本的翻譯行為，不能影響現有 OVS 部署） |
| **agent IP 從 kernel 讀的同一份拓撲 JSON 來** | kernel 是用 `AgentKey{agentIP, port}` 把 sample 對到 edge，位址不對就是「收到了但對應到空氣」 | 單元測試（含 host 必須被排除 —— host 的 dpid 都是 0，會全部塌到同一個假 agent） |
| **headless 啟動** | `--mode` / `--topology` / `--no-ai`，不用再手動打 `std::cin` | — |

### A2. 實機驗證過的（2026-07-29 在 10 台 bmv2 上實測）

| 項目 | 實測結果 |
|---|---|
| **bmv2 fabric 端到端轉發** | `h1 ping -c 5 h4` → **0% loss**、`ttl=59`（從 64 減 5，證實經過 5 台 switch 且 TTL 遞減有效）、RTT 6.5ms |
| **1/256 取樣 → clone → packet-in → proxy → emitter → kernel 整條鏈** | 送 ~2700 個 ping，kernel 收到 **`rx=126, addressed=126`**。`rx == addressed` 表示**每一個 datagram 都成功歸戶到 agent**，agent IP 對應正確 |
| **取樣率符合預期** | 2700 封包 × 10 跳 ÷ 256 ≈ **105** 個期望 sample，實測 **107**（第一次查詢時）|
| **kernel 正確解析出雙向 flow** | `10.0.0.1 → 10.0.0.4` ICMP type 8 code 0（echo request）＋ `10.0.0.4 → 10.0.0.1` type 0 code 0（echo reply），ICMP type/code 確實在 port 欄位 |
| **零錯誤** | `app_drop=0`、0 個 malformed datagram、proxy 和 kernel log 都沒有 exception |
| **clone session 實機安裝** | 10 台全部 `Clone session 250 -> port 255 installed`，0 失敗 |

### B. 已完成，但只有單元測試，還沒對真的 bmv2 跑過

- **direct counter（`flow_5tuple` / `ipv4_lpm`）和 per-port counter** —— 表和 counter 都在 p4info 裡。⚠️ 2026-08-10 更正：`/stats/flow/{dpid}` **已經接上了**（`ryu_flow_stats.py`），原本這裡寫「還沒接」。仍然成立的是：讀 bmv2 counter 需要 Thrift 的 Python binding，這台機器上兩個 interpreter 都沒裝，所以 counter 本身沒被外部驗證過。
- **P4RoutingStrategy 的實際下規則路徑** —— curl → proxy → P4Runtime 這條鏈的每一段都有測，但整條沒有對活的 switch 跑過。

### C. 還沒做（會影響你測試時看到什麼）

| Phase | 缺什麼 | 對你測試的影響 |
|---|---|---|
| ~~**6**~~ | ✅ **已完成（2026-08-10 更正）** —— 北向三個通知、`/stats/flow/{dpid}`、真存活偵測都做了。只剩兩件**實機驗證**：`seed_expected_links` 接收側的 port 假設、失效鏈路在 kernel 圖裡維持 down | 圖是活的。原本這格寫「整張圖是死的」 |
| **3**（proxy 那半） | 少 `POST /stats/flowentry/delete`（非 strict，這是所有 `priority == -1` 刪除的預設路徑，包含 Intent Translator 的）；prefix 還是硬寫 `/32`；沒有 idle_timeout 模擬；dpid→grpc_addr 還是硬寫 `range(1,11)`；`TopologyManager` 沒加鎖 | 刪規則和聚合路由會不如預期 |
| **4**（漏掉的） | `p4_testbed_topo.py` 的 **TCLink 頻寬沒補回來**（OVS 那邊是 1000/10000 Mbps，`GraphTypes.hpp` 和兩份拓撲 JSON 都假設 1 Gbps）；ECMP 的 ActionSelector 也還沒做 | 頻寬相關的計算會用預設值，不是 1 Gbps |
| **7** | 電源管理還是壞的 | 別測關機 |
| **8** | 清理 | — |

> **技術債（你說先留著，之後跟其他人討論）**：每一條南向指令都是
> `popen("curl … -d '" + json.dump() + "'")`。`nlohmann::json::dump()` 不會 escape 單引號，而 JSON 來自
> 未認證的 REST body 和 LLM 輸出。目前 3 個檔案共 22 處。

---

## 二、測試流程

由快到慢，**建議照順序**。前面的過不了就不用往後跑。

### 進 Phase 6 之前的完整測試清單

要做「完整一輪」就照這個順序跑完。**⚙️ = 我可以代跑，🔒 = 需要你自己執行**（要 root 或要在
互動式 CLI 裡操作）。

| # | 步驟 | 誰跑 | 大約時間 |
|---|---|---|---|
| 0 | `./run_layers.sh quick`（**827** 個測試：C++ 414 ＋ p4_proxy Python 312 ＋ kernel 側 Python 101；原本寫 153） | ⚙️ | 2 分 |
| 0b | `./l0_build_check.sh p4`（P4 pipeline 編譯） | ⚙️ | 30 秒 |
| 0c | `./run_layers.sh selftest`（contract schema + 依賴圖） | ⚙️ | 10 秒 |
| 0.5 | ASan／UBSan 建置並跑測試 | ⚙️ | 3 分 |
| 1 | telemetry 灌 fixture（不需要資料平面） | ⚙️ | 2 分 |
| 2a | `./stack.sh up ovs` —— 它先開 **Ryu**，然後停下來等你 | ⚙️ | 10 秒 |
| 2b | 開 **OVS** Mininet，回去按 Enter（**Ryu 一定要先**） | 🔒 | — |
| 2c | 等收斂 —— `paths=installed`，**約 70 秒**（Ryu app 內建 60 秒 sleep） | 自動 | 1.5 分 |
| 2d | `./stack.sh wait` 確認 `up=10 enabled=10` | ⚙️ | 10 秒 |
| 2e | Mininet CLI 開**背景 iperf**（流量要持續到 2f 跑完） | 🔒 | 1 分 |
| 2f | `./run_layers.sh api ovs --traffic`（趁流量還在跑） | ⚙️ | 1 分 |
| 2g | `./run_layers.sh baseline ovs`（**只在 2f 通過時才抓**） | ⚙️ | 1 分 |
| 2h | `./stack.sh down` + **`sudo mn -c`** | 🔒 | — |
| 3a | 開 **bmv2** Mininet（**不同的腳本**） | 🔒 | — |
| 3b | `./stack.sh up p4` | 🔒（要按 Enter） | 1 分 |
| 3c | 確認 10 台都有 clone session；`api p4`、`baseline p4` | ⚙️ | 2 分 |
| 3d | Mininet CLI 產流量 + `tcpdump` 抓 UDP 6343 | 🔒 | 2 分 |
| 3e | `./run_layers.sh compare`（L4 差異比對） | ⚙️ | 30 秒 |
| 3f | `./stack.sh down` + `sudo mn -c` | 🔒 | — |

**兩個 Mininet 不能同時開**，而且切換模式之間**一定要 `sudo mn -c`**，否則殘留的
namespace／bridge 會讓下一個模式起不來或測出假結果。

**第 3d 步已於 2026-07-29 實機驗證通過**（bmv2 取樣 → packet-in → proxy → emitter → kernel 整條鏈，
`rx=126, addressed=126`，雙向 ICMP flow 都正確解析）。它現在是**迴歸標準**，不再是待驗證項目。
做這一步的時候務必看 3d 那節關於「流量要夠多」的說明 —— 送太少封包會看起來像壞掉。

### 第 0 步：不需要開任何東西（約 2 分鐘）

這步涵蓋 **827** 個測試（C++ **414** ＋ p4_proxy Python **312** ＋ kernel 側 `tests/python/` **101**），
是你日常改完程式碼唯一需要跑的。（2026-08-10 實跑更正，原本寫「153 個（90 C++ + 63 Python）」。
⚠️ `tests/python/` 那 101 個**沒有**被 ctest 註冊，要另外跑。）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./run_layers.sh quick
```

**通過標準**（腳本會自己判斷，不用你看 log 找 warning）：

```
L0 passed: ... build
L1 passed: 1 test binary/binaries, clean under ctest and direct execution.
  test_clone_session.py          PASS  14 ran and passed
  test_p4_client.py              PASS  1 ran, 1 skipped     ← 沒開 bmv2，這是正常的
  test_sflow_emitter.py          PASS  48 ran and passed
```

**要特別注意**：如果看到 `NO TESTS RAN`，那是失敗，不是通過 —— 表示那個檔案一個測試都沒真的跑到
（通常是缺套件）。這正是我把 Python 測試接進 L1 的當下抓到 `test_p4_client.py` 從來沒跑成功過的方式。

`test_p4_client.py` 顯示 `1 ran, 1 skipped` 是正常的 —— 它是實機整合測試，需要 bmv2 在跑、
**而且 proxy 不能在跑**。兩者都用 `election_id = 1` 去搶 mastership，P4Runtime 只允許一個持有者，
後到的會拿到 `Election id already exists` 然後每個 write 都被拒絕。要跑它就只開 bmv2、不要開 proxy。

P4 pipeline 的編譯要另外跑：

```bash
./l0_build_check.sh p4
```

還有一組完全離線的檢查（contract schema 自檢 + 元件依賴圖），不需要 kernel 也不需要 Mininet：

```bash
./run_layers.sh selftest
```

### 第 0.5 步：sanitizer（改到 parser 或 collector 的時候跑）

sFlow parser 是對外輸入面，改到它就值得跑一次：

```bash
cd /home/adam/Desktop/NDTwin-Kernel
cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
cmake --build build-asan -j$(nproc)
cd build-asan && ASAN_OPTIONS=detect_leaks=0 ./bin/test_routing_strategy
```

通過標準：`[  PASSED  ] 414 tests.`（2026-08-10 更正，原本寫 90），而且**沒有**任何
`ERROR: AddressSanitizer` 或 `runtime error:`。

### 第 1 步：telemetry 路徑（不需要 bmv2，也不需要 Mininet）

這一步很有價值：它用真的 kernel process 驗證 sFlow 這條路，而且不用開資料平面。

⚠️ **這一步要在沒有其他 stack 在跑的時候做。** 如果 `stack.sh` 起的 kernel 還活著，:8000 已經被
佔住，手動再開一個會直接 abort：

```
terminate called after throwing an instance of 'boost::wrapexcept<boost::system::system_error>'
  what():  bind: Address already in use
```

先確認並收掉：

```bash
cd tools/test_workflow && ./stack.sh status   # kernel 應該顯示 "-" 而不是 "running"
./stack.sh down                              # 如果還在跑
```

⚠️ **而且這一步會把 5 筆合成 flow 灌進 kernel 的 flow table**，跟第 3d 步（實機 telemetry）
共用同一張表。兩步都要做的話，**先做 3d**（table 乾淨才看得出實機 sample 有沒有進來），
或者中間重開 kernel，否則你會分不出哪筆是 fixture 假造的、哪筆是 bmv2 真的送上來的。

**開一個 terminal 跑 kernel：**

```bash
cd /home/adam/Desktop/NDTwin-Kernel/build
./bin/ndtwin_kernel --mode mininet \
  --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json --no-ai
```

啟動時應該看到這行（這是新的 identity mapping 生效的證據）：

```
All-bmv2 topology: using identity ifIndex->port mapping and skipping ovs-vsctl,
which does not know about bmv2 interfaces.
```

**另一個 terminal 把 fixture 打進去**（這些就是 emitter 真的產出的位元組）：

```bash
cd /home/adam/Desktop/NDTwin-Kernel
python3 -c "
import socket, glob
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for f in sorted(glob.glob('tests/fixtures/emitted_*.bin')):
    s.sendto(open(f,'rb').read(), ('127.0.0.1', 6343))
    print('sent', f)
"
curl -s http://localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json, sys
flows = json.load(sys.stdin)
print('flow count:', len(flows))
for f in flows:
    print(' ', f['src_ip'], f['src_port'], '->', f['dst_ip'], f['dst_port'], '| path', f['path'])
"
```

（IP 是以整數回傳的。`16777226` = `0x0100000A` = 10.0.0.1。）

**通過標準 —— 這是我實測到的輸出，你應該看到一樣的 5 筆：**

| 回傳值 | 意思 |
|---|---|
| `16777226:5001 → 67108874:40997` | 10.0.0.1:5001 → 10.0.0.4:40997（TCP）|
| `16777226:5001 → 67108874:40998` | 同上但是截斷的 frame |
| `33554442:5201 → 50331658:33333` | 10.0.0.2:5201 → 10.0.0.3:33333（UDP）|
| `16777226:8 → 33554442:0` | ICMP echo request，type 8 code 0 放在 port 欄位 |
| `50331658:3 → 67108874:1` | ICMP dest-unreachable，type 3 code 1 |

- **剛好 5 筆**。送進去的是 7 個 fixture：ARP 正確地不產生 flow，`emitted_multi.bin` 裡的三筆跟前面重複所以合併。
- **不應該**有 malformed datagram 的訊息。
- `path` 會是 `[]`、link usage 會是 `0.0` —— 在**這一步**是預期的，因為這步刻意不開 proxy。
  ⚠️ 2026-08-10 更正：原本的理由寫「Phase 6 未做」，那已經不成立；現在的理由是沒有南向對口。
- log 裡會有 `parseFlowStatsTextToJson JSON parsing failed`。P4 模式下沒開 proxy 的時候這是預期的
  （沒人回應 flow stats 查詢）。

> ⚠️ **更正**：這份文件之前寫「這些解析錯誤是正常的」並套用到 OVS 模式，**那是錯的**。在 OVS 模式下
> 同樣的錯誤代表 **Ryu 少載了 `ryu.app.ofctl_rest`**，`/stats/flow/<dpid>` 回 404 HTML 而 kernel 拿
> HTML 去 `json::parse`。那不是無害的，它表示**整個 harness 從來沒有成功下過一條 flow 到 OVS**。
> `stack.sh` 現在會載入該 app（commit `3acad16`）。如果 OVS 模式還看到這個錯誤，那是真的壞了。
>
> 順帶一提，修好之後 flow 才第一次真的進到 Classifier，並立刻暴露一個**潛伏的 null deref crash**
> （Ryu 的 table-miss 規則 `"actions": []` → `outputPorts` 為空 → `.front()`），已修（`196a10d`）。

這一步能證明的事：P4 那邊產出的 sFlow，真的能被跑起來的 kernel 收下並解析成正確的 flow。

### 第 2 步：OVS 沒有退步（**每個 phase 都必須跑**）

Phase 0／1／2 和 identity mapping 都動到共用程式碼，所以這是每一個 phase 的閘門。

**有三個前置條件，缺任一個 OVS 模式就會壞，而且壞法都是靜默的**
（全部都是實際跑的時候踩到才發現的，已經修進 `stack.sh`，寫在這裡是為了讓你看懂症狀）：

1. **`ovs-vsctl` 要能免密碼 sudo。** kernel 的 `pingWorker` 每秒 shell 出去跑一次
   `sudo ovs-vsctl list-br`；但 `stack.sh` 是用 `setsid` 背景啟動 kernel 的，沒有 controlling
   terminal，`sudo` 沒辦法問密碼就直接失敗，回一個空的 bridge 清單 → 每台 switch 都被判定
   unreachable → 每秒被 `setVertexDown()` 蓋一次。症狀是 `up=0` 但 `enabled` 可能是 10。

   ```bash
   echo "$USER ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec" \
     | sudo tee /etc/sudoers.d/ndtwin-mininet
   sudo chmod 440 /etc/sudoers.d/ndtwin-mininet
   sudo visudo -c          # 檢查語法，做完一定要跑
   ```

2. **Ryu 要多載兩個 stock app**（`stack.sh` 現在都會載，寫在這裡是為了讓你看懂症狀）：

   `intelligent_router.py` **只**提供 `/ryu_server/all_destination_paths`。kernel 依賴的其他 Ryu
   REST endpoint 全部來自內建 app：

   | 少載的 app | 提供什麼 | 少了它的症狀 |
   |---|---|---|
   | `ryu.app.rest_topology` | `/v1.0/topology/{switches,hosts,links}` | 圖永遠 `up=0 enabled=0` |
   | `ryu.app.ofctl_rest` | `GET /stats/flow/<dpid>`、`POST /stats/flowentry/{add,modify,delete,delete_strict}` | 每次輪詢都 `JSON parsing failed ... last read: '<'`（在解析 404 的 HTML）、flow table 查不到、**所有下規則都失敗** |

   兩者失敗的方式都是**靜默**的：`updateSwitches()` 把 404 的 HTML 拿去 `json::parse`、接住例外之後
   直接 return，什麼都不說。`--observe-links` 只載入 `ryu.topology.switches`（提供**事件**），
   不含這兩組 REST endpoint，所以光靠它是不夠的。

3. **kernel 必須等控制平面準備好才能開。**

   > ⚠️ **2026-08-10 更正**：原文寫「`run()` 只在啟動時**拉一次**、沒有重試迴圈，那一刻 Ryu 還
   > 不知道的東西 kernel 這輩子都不會知道」。`71d27c1` 之後已改為定期輪詢（前 90 秒每 5 秒、之後
   > 每 30 秒，`TopologyAndFlowMonitor.cpp:1793-1795`），漏掉的 host／link 會被補上。
   > 下面關於「link 收斂 vs all-destination paths」的時間差說明仍然成立，而且仍是等收斂的理由 ——
   > 只是代價從「永久缺料」降級成「前幾十秒的圖不完整」。

   ⚠️ **「link 收斂」和使用說明書講的里程碑是兩件事**，時間差非常大：

   | 里程碑 | 機制 | 實測 |
   |---|---|---|
   | switch/link discovery | LLDP，交換機之間 | **約 2 秒** |
   | **all-destination paths installed** | `intelligent_router.py` 的 `hub.sleep(60)`（在 `load_static_topology` 結尾、`if is_mininet:` 底下，緊接著才走 all-destination 安裝） 之後才跑 `install_all_pair_paths` | **60 秒以上** |

   說明書要求的是後者（「you will see the *all-destination paths installed* message」）。
   `stack.sh up ovs` 現在**兩個都等**：輪詢 `/v1.0/topology/*` 直到數量對上，**並且**輪詢
   `/ryu_server/all_destination_paths` 直到非空（`all_destination_paths` 初始是 `[]`，只在
   `install_all_pair_paths` 裡被賦值，所以非空就是直接訊號，不必去 grep log）。
   `CONVERGE_WAIT`（預設 **150**）是上限而不是固定等待時間 —— 之前預設 60，比它要等的事件本身還短。

   P4 模式本來就是對的：它的 `observed_counts` 讀的就是 proxy 的 `all_destination_paths`。

#### 需要兩個 terminal

| | 用途 | 之後要不要留著 |
|---|---|---|
| **A** | `stack.sh` / `run_layers.sh` | 留著 |
| **B** | Mininet CLI（`sudo`，會停在 `mininet>`） | **一定要留著**，後面要在裡面產流量 |

#### 2a. 起 stack，它會先開 Ryu 然後停下來等你（terminal A）

⚠️ **順序是 Ryu 先、Mininet 後**，不能顛倒 —— [使用說明書](https://ndtwin.org/docs/ndtwin-user-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/)
寫「Startup Order is Critical」，而理由比「交換機會重試」嚴重得多。

`testbed_topo.py` 用 `RemoteController` 但**沒有指定 port**，而 Mininet 在這種情況下會
**在自己啟動的那一刻去偵測 Ryu 在哪個 port** —— `mininet/node.py:1551` `checkListening()`：

```python
if self.port is not None:      # 沒指定，走 else
    ...
else:
    for port in 6653, 6633:    # 探測
        if self.isListening(self.ip, port):
            self.port = port; break
if self.port is None:          # 兩個都探不到
    self.port = 6653           # 盲猜，並印 warning
```

所以先開 Mininet 的話，兩次探測都失敗，port **回退成盲猜的 6653**。這件事的後果取決於 Ryu
之後怎麼起：

| Ryu 的起法 | 先開 Ryu | 先開 Mininet |
|---|---|---|
| `stack.sh`（不給 `--ofp-tcp-listen-port`，Ryu 預設 6653） | 探測到 6653 ✅ | 盲猜 6653，**剛好對** ⚠️ |
| 說明書那行（`--ofp-tcp-listen-port 6633`） | 探測到 6633 ✅ | 盲猜 6653，**永遠連不上** ❌ |

也就是說先開 Mininet 在 `stack.sh` 下是**靠運氣**成立的，照說明書的指令則是直接壞掉。
（順帶：說明書的 `--observe-link` 單數也可以用，oslo.config 接受不歧義的前綴。）

```bash
cd /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow
./stack.sh up ovs
```

它會開 Ryu，然後印 `[2/3] data plane (Mininet, needs sudo)` 並停下來等你按 Enter。
**先不要按**，去 terminal B 開 Mininet。

#### 2b. 開 OVS Mininet（terminal B）

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/testbed_topo.py
```

✅ 看到 `mininet>` 就成功。然後回 terminal A 按 Enter。

⚠️ 啟動時它會自己跑一輪 128 台 host 平行 ping 當自我測試，**那個階段的 ping 失敗（包含它自己印出的
`100% packet loss`）可以忽略** —— 那是啟動洪泛造成的，不代表網路壞了。等提示符出現再開始測。

#### 2c. 等收斂（terminal A，按下 Enter 之後自動）

✅ 關鍵是這幾行：
```
  waiting for 10 switches, 32 links, and all-destination paths
  the Ryu app sleeps a hard-coded 60s before installing paths, so expect >60s
    switches=10 links=32 paths=pending
    switches=10 links=32 paths=installed
  converged after 68s         ← 一定要看到 converged
[3/3] kernel
  waiting for kernel API on :8000 . up
```
⚠️ **`paths=pending` 停留 60 秒左右是正常的**，那就是 Ryu app 裡那個 `hub.sleep(60)`。
⚠️ 看到 `did not converge` 就別往下做，先查 Ryu（尤其 `all-destination paths were never
installed` 這行，代表 `install_all_pair_paths` 拋例外了，log 裡會有 `Failed to load static
topology file`）。

#### 2d. 確認圖活了（terminal A）

```bash
./stack.sh wait
```

✅ **必須是 `up=10 enabled=10`**：
```
switches=10 up=10 enabled=10 edges=288
converged after 0s
```
`enabled=10` 是 OVS 模式健康的唯一指標。（P4 模式這裡會是 0，那是 Phase 6 沒做，不是失敗。）

#### 2e. 開**持續**流量（terminal B）—— 順序很重要

⚠️ **流量必須在 2e 執行的「同時」還在跑**，不能先跑完再測。原因有兩個，都是實測踩到的：

1. **flow table 會老化**。流量停了幾秒，`get_detected_flow_data` 就變回 0 筆。
2. **sFlow 是 1/256 取樣**。`ping` 每秒 1 個封包，要 256 秒才產生一個 sample —— `ping -c 20`
   幾乎不可能產生任何 sample。**只有 iperf 這種能打滿頻寬的流量才夠**。

判斷流量夠不夠的方法：看 kernel log 的 `addressed=` 有沒有在**增加**。`rx=` 會一直漲（那是週期性的
counter sample），但 `addressed=` 只有在收到 **flow sample**（也就是真的有流量）時才會漲。

3. **兩端必須掛在不同的交換機上。** `getAvgLinkUsage`
   （`TopologyAndFlowMonitor.cpp`）**刻意排除任何接到 HOST 的邊**，只平均交換機之間的鏈路：

   ```cpp
   if (g[e].linkBandwidthUsage != 0 && g[sourceNode].vertexType != VertexType::HOST &&
       g[targetNode].vertexType != VertexType::HOST)
   ```

   所以同一台交換機底下的兩台 host 互打，流量只會出現在 host↔switch 邊上，
   `get_average_link_usage` **永遠是 0.0** —— 這不是壞掉，是設計如此。

   host 掛在哪台交換機（只有 s1–s4 有 host，各 32 台）：

   | 交換機 | host IP 範圍 |
   |---|---|
   | s1 | 10.0.0.1 – 10.0.0.32 |
   | s2 | 10.0.0.33 – 10.0.0.64 |
   | s3 | 10.0.0.65 – 10.0.0.96 |
   | s4 | 10.0.0.97 – 10.0.0.128 |

```
mininet> h97 iperf -s -u &
mininet> h1 iperf -c 10.0.0.97 -u -b 10M -t 180 &
```

⚠️ **不要用 `h1` ↔ `h2`（或 `h4`）**：它們都在 s1 底下，跨不了任何交換機鏈路。
`h1` → `h97` 是 s1 → s4，實測會經過 4 條交換機間的鏈路。

用 `&` 丟到背景，這樣 CLI 還能用；`-t 180` 給 3 分鐘的測試窗口。**不要用 Mininet 內建的
`iperf h1 h97`**，那個會卡住 CLI 直到跑完。

⚠️ 頻寬用 **`-b 10M`**，不要用 100M：實測 100M 會把 LLDP 餓死，Ryu 會誤判 link 掛掉
（曾經一次跑出 19 次 link deleted），ping 也測不了。

順手確認連線正常（這個要 Ctrl+C 或用 `-c`，因為 `ping` 預設不會停）：
```
mininet> h1 ping -c 5 h97
```
✅ 應該 0% packet loss。

實測 `h1` → `h97` 灌 10M UDP 30 秒後：

```
$ curl -s localhost:8000/ndt/get_average_link_usage
{"avg_link_usage":0.0074514431999999995,"status":"success"}

交換機之間的邊 32 條，其中有流量 4 條
  s1:2  -> s6   21733376 bps  (2.173%)
  s6:4  -> s10  12419072 bps  (0.124%)
  s8:2  -> s4    6209536 bps  (0.621%)
  s10:4 -> s8    6209536 bps  (0.062%)
```

路徑 s1 → s6 → s10 → s8 → s4 是對的。同一條路上四個數字不一致是 **1/256 隨機取樣的變異**，
不是計算錯誤 —— 短窗口下這個抖動是預期的。

⚠️ **四條邊的百分比差 10 倍不是筆誤** —— 這個拓撲的鏈路速率是混合的：s1→s6 和 s8→s4 是
**1 Gbps**，s6→s10 和 s10→s8 是 **10 Gbps**。所以 `12419072 / 10e9 = 0.124%` 是對的。
（審查這段的人假設全部 1 Gbps，得出「少了一個 10 倍」的結論 —— 實測頻寬證明不是。）


#### 2f. 跑契約測試（terminal A，趁流量還在跑）

```bash
./run_layers.sh api ovs --traffic
```

`--traffic` 才會去檢查 flow／path／速率；不帶的話那些檢查會被跳過。

✅ 通過標準：**最後一行 `all layers passed`**，Summary 三行都 PASS。

⚠️ **`GAP` 不算失敗** —— 那是已登記在案的 kernel 缺口（例如 `release_lock_not_held`）。只有 `FAIL` 算。

#### 2g. 抓基準（terminal A）

```bash
./run_layers.sh baseline ovs
```

⚠️ **這個指令永遠會印 `all layers passed`**，因為它只是把回應存檔、不做任何判斷。
**絕對不要用它的輸出判斷系統健康**，要看 2e。（這是實際誤導過人的地方。）

⚠️ 只有在 2e **通過**的時候才抓基準。從壞掉的系統抓的基準會讓之後每次 `compare` 都拿錯的當標準。

#### 2h. 收尾

terminal A：
```bash
./stack.sh down
```
terminal B：打 `exit` 離開 Mininet，然後
```bash
sudo mn -c
```
**`sudo mn -c` 不能省**，否則殘留的 namespace 會讓 P4 那輪起不來。

### 第 3 步：P4 stack 真的起得來（目前能做到的極限）

⚠️ **P4 模式的啟動順序跟 OVS 是相反的**：Ryu 是 server、switch 連進去，所以 OVS 要先開 Ryu；
但 bmv2 才是 server（`simple_switch_grpc` 監聽 `0.0.0.0:50051-50060`），proxy 是 gRPC **client**，
所以 **P4 要先開 Mininet**，proxy 才連得上。`stack.sh up p4` 會自動走對的順序並提示你。

先確認上一輪的 OVS Mininet 已經清掉（`sudo mn -c`），然後在**另一個 terminal** 開 bmv2 ——
**注意是不同的腳本**：

```bash
sudo python3 /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/p4_testbed_topo.py
```

啟動時應該看到 `10 BMv2 Switches listening on gRPC ports 50051 ~ 50060`。然後：

```bash
cd tools/test_workflow
./stack.sh up p4           # 提示你開 bmv2 Mininet → proxy → 等收斂 → kernel
```

**通過標準**（看 proxy 的 log；`.test_run` 在 repo 根目錄，不在 `tools/test_workflow` 底下）：

```bash
cd /home/adam/Desktop/NDTwin-Kernel
grep -c "Clone session 250 -> port 255 installed" .test_run/logs/p4_proxy.log   # 要是 10
grep -c "sampling to sFlow as"                    .test_run/logs/p4_proxy.log   # 要是 10
grep -c "clone session failed\|NO telemetry"       .test_run/logs/p4_proxy.log   # 要是 0
```

**這三個數字（10／10／0）已經實測達成過**，所以它現在是迴歸標準，不是待驗證項目。
如果看到 `[Proxy Agent] Switch N: clone session failed, NO telemetry from it`，那台就沒有 telemetry。

~~`./stack.sh wait` 在 P4 模式**一定會逾時**（`enabled=0`），這是預期的，不是失敗 —— Phase 6 未做。~~
**2026-08-10 更正：不再成立。** Phase 6 的北向通知已接上，P4 模式的 `enabled` 應該和 OVS 一樣收斂。
**現在這裡逾時就是真的壞了**，先查 proxy 有沒有發 `inform_switch_entered`——實際發送的是 `kernel_notifier.py` 的 `KernelNotifier.switch_entered`，由 `main.py` 的啟動流程對每一台 usable 的 switch 呼叫。

L2／L3 契約測試和 L4 基準在 P4 模式一樣可以跑：

```bash
cd tools/test_workflow
./run_layers.sh api p4          # 預期會有 Phase 6 相關的差異
./run_layers.sh baseline p4     # 記錄 P4 基準
./run_layers.sh compare         # L4：拿 P4 跟 OVS 基準比（要兩邊都 capture 過才會跑）
```

`compare` 需要 `.test_run/baseline/ovs` 和 `.test_run/baseline/p4` **都存在**，所以第 2 步的
`baseline ovs` 不能跳過，否則這一步會被 skip 掉。

#### 3d：整條 telemetry 鏈（**2026-07-29 實機驗證通過**）

⚠️ **流量要夠多，這是這一步最容易失敗的地方 —— 而且失敗看起來像壞掉。**

取樣是**隨機** 1/256（`random(meta.sample_rand, 0, 255)` 然後 `== 0` 才 clone），不是每 256 個
固定取一個。封包太少時「一個 sample 都沒有」是**正常的機率結果**，不是 bug。

好消息是**每一跳都獨立取樣**，所以取樣機會遠多於封包數：

| 送出的 ping | 取樣機會（×10 跳，去回程各 5） | 期望 sample | 至少 1 個的機率 |
|---|---|---|---|
| 5 | 50 | 0.2 | **18%** ← 實測第一次就踩到，看起來像壞掉 |
| 300 | 3,000 | 11.7 | >99.9% |
| 2,700 | 27,000 | ~105 | ~100% |

**另外：LLDP 不算。** proxy 的 LLDP beacon 會讓每個 switch port 累積上百個封包，但 P4 裡的
`if (standard_metadata.egress_spec != CPU_PORT)` 把送 CPU 的封包排除在取樣外（避免重複 packet-in），
所以**只有真實資料流量才會產生 sample**。看 interface 封包計數會誤判。

```
mininet> h1 ping -c 3000 -i 0.002 10.0.0.4
```

**通過標準（以下數字是實測值）：**

```bash
# 1. kernel 收到而且成功歸戶 —— rx 必須等於 addressed
grep -oE "rx=[0-9]+, app_drop=[0-9]+, addressed=[0-9]+" .test_run/logs/kernel.log | tail -1
#    實測: rx=126, app_drop=0, addressed=126

# 2. 解析出雙向 flow（趁流量還在跑或剛結束，table 會老化清空）
curl -s http://localhost:8000/ndt/get_detected_flow_data | python3 -c "
import json,sys,socket,struct
ip=lambda n: socket.inet_ntoa(struct.pack('<I', n))   # kernel 存的是 0x0100000A 這個順序
for x in json.load(sys.stdin):
    print(ip(x['src_ip']), '->', ip(x['dst_ip']), 'ICMP type', x['src_port'], 'code', x['dst_port'])
"
#    實測: 10.0.0.1 -> 10.0.0.4 ICMP type 8 code 0   (echo request)
#          10.0.0.4 -> 10.0.0.1 ICMP type 0 code 0   (echo reply)
```

| 檢查 | 為什麼重要 |
|---|---|
| **`rx` 等於 `addressed`** | 每個 datagram 都對應到 agent。不相等表示 `AgentKey{agentIP, port}` 對不上 —— sample 收到了卻歸戶到空氣 |
| `app_drop=0` | 沒有 datagram 因格式問題被丟掉 |
| 雙向都有、ICMP type/code 在 port 欄位 | emitter 的位元組排列跟 kernel 的 parser 在**實機**上相容，不只是單元測試層面 |

`tcpdump -i lo -n udp port 6343` 也能看，但 `rx=`／`addressed=` 更直接：它證明封包**真的被 kernel
收下並解析**，而不只是出現在 lo 上。（`0 packets captured / N received by filter` 的意思是 tcpdump
檢查了 N 個 lo 封包、但沒有一個符合過濾條件。）

~~**不要用這些當標準**（Phase 6 未做，一定是空的）：`/ndt/get_graph_data` 的 `is_enabled`、
link usage、flow 的 `path`、Web GUI 的畫面。`is_up` 會是 true 但那是 stub 騙你的。~~

**2026-08-10 更正：整段不再成立。** Phase 6 已完成，上面每一項現在都應該有真值，
可以（也應該）拿來當通過標準。`is_up` 也不再是 stub。

收尾：

```bash
./stack.sh down
# Mininet 那個 terminal 打 exit，然後：
sudo mn -c
```

---

## 三、一句話總結

現在可以放心相信的是：**kernel 不會崩、南向失敗看得見、P4 pipeline 能表達 NDTwin 真正會下的規則，
而且整條 telemetry 鏈在 10 台真實 bmv2 上通了** —— bmv2 取樣 → clone 到 CPU → packet-in → proxy →
emitter → kernel 解析出正確的雙向 flow，`rx=126, addressed=126`、零錯誤（2026-07-29 實測）。
bmv2 fabric 本身也證實能端到端轉發（`ping` 0% loss、`ttl=59` 證實過 5 跳且 TTL 遞減有效）。

~~還不能相信的是：**圖是活的**。那是 Phase 6 —— `inform_switch_entered` 沒人呼叫，所以
`is_enabled` 是 0、`path` 是 `[]`、link usage 是 0。~~

**2026-08-10 更正：這段已經過時。** Phase 6 的程式碼部分完成了 —— 北向通知、`/stats/flow/{dpid}`、
真存活偵測、失效鏈路雙邊排除、路徑轉換時推送都在。**圖是活的。**

現在還不能相信的是**別的東西**：Phase 6 剩下的兩件實機驗證（`seed_expected_links` 接收側的
port 假設、失效鏈路在 kernel 圖裡是否真的維持 down）、Phase 3／7／8，以及 HANDOFF §2c 那個
「Ryu 在錯的啟動順序下永久回空表」——**那一個會讓所有健康指標全綠而 flow table 全錯。**

[Co-developed with claude code -- Adam]
