# Auto-deriving custom-header layout from the P4 program: success rate (opus worker, 2026-10-01)

## 先說交付狀態

- **REPORT.md 沒有寫成檔案。** harness 不讓 subagent 寫報告類 .md（`Subagents should return findings as text, not write report files`），所以完整報告就是這則訊息的下半部，要落檔請 orchestrator 自己寫。
- 其他產物都在 `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/parser-autoderive/`：
  - 編譯產物：`json/*.json`，20 支 = 15 支 corpus + 5 支合成；`compile-logs/`
  - 原型：`p4pi.py`
  - 測試：`pkts.py`、`run_tests.py` → `run_tests.log`、`results.json`
  - 突變閘門：`mutate.py` → `mutate.log`
  - 線上位置證據：`pcap_links.py` → `pcap_links.log`
  - 附錄 A 逐路徑表：`gen_tables.py` → `appendix_paths.md`（從 results.json 產生，可直接接在報告後面）
- 範圍守住了：沒改 repo、沒 commit、沒 sudo、沒碰 lab，也沒編 C++、沒下載。p4c 一次只跑一支，都掛 `nice -n 19`。

## 成功率（每個數字都附分母）

- **路徑層，全部 15 支**：共 50 條 parse path，23 條 X（程式不 parse IP），27 條帶 IP。
  - 只用 bytes + JSON 推：**18/27（67%）**。
  - 推不出來的 9 條全卡在同一處：start state 就 `select(standard_metadata.ingress_port)`。flowcache 1 條，**NDTwin 自己的 ndtwin_switch.p4 8 條**。
  - 把 sFlow sample 帶的 input port 當 context 補進去：**27/27**。
  - 扣掉 4 條只走 CPU port 的路徑：只用 bytes 18/23，補 port 23/23。
- **7 支 custom-header exercise**：11 條帶 IP 的路徑，只用 bytes **10/11**，補 port **11/11**。
- **程式層**：
  - 有 IP 路徑的 13 支裡，只用 bytes 能全推的 11/13，補 port 13/13。
  - custom-header 那 7 支裡有 IP 路徑的是 6 支（calc 沒有），只用 bytes 5/6，補 port 6/6。
- **真實 frame（RAN）**：13 個 exercise 的 bmv2 pcap，取 tc 實際會取樣的那一組，共 72,213 個，截到 128 B；線上帶 IP 的 71,966 個。
  - 只用程式 parser：68,085（94.6%），錯 0。
  - 今天的 native-model：71,943。
  - native 先、程式 parser 補位：71,966/71,966。
  - 3 行 hints：71,966/71,966。
- **auto-derive 比今天多救回的只有 23 個 frame / 3 條路徑**：basic_tunnel、p4runtime 的 tunnel，加 source_routing。mri 那 3 條 option 路徑今天的 twin 已經會解。

## 三大風險

1. **以 ingress_port 為 key 的 parser，包括我們自己的程式。**
   - context 要接進 identity 計算。但 `identifyFrame` 只吃 bytes（`SFlowType.hpp:267`），而且在 `FlowLinkUsageCollector.cpp:1510` 就呼叫了，比 port 換算（`:1549-1550`）早。
   - egress-only 的 sample 根本沒有 ingress port（`psample_sflow_emitter.py:427-428`），只能「假設」不是 CPU port。
2. **程式 parser 不等於線上真相。**
   - 只用程式 parser 會漏 3,881 個 IP frame：IPv6 3,691、multicast 的 IPv4 188、source_routing 末跳 2。
   - 收端是 host 的 egress sample，沒有哪支 P4 parser 是對的。
   - ⇒ 它只能排在 native 後面補位。兩層 IP 時（`syn-ipip`），native 先做會拿到外層——用哪層當 flow identity 是政策問題。
3. **真實論文 app 帶來 tutorials 沒有的構造。**
   - INT shim 插在 IPv4 和 L4 中間：native 和原型都用 `ihl*4` 找 port，會安靜讀錯。
   - per-hop stack 會長：IP 必須從 ≤104 開始，否則截斷（`syn-deep-6` TRUNCATED）。
   - 遇到 value_set、union、metadata key，原型一律 REFUSE。
   - JSON 跟線上對不上時，只剩 version/ihl sanity 擋著：K3b 關掉它就給出錯的五元組。

## 觀測到的（OBSERVED）與推論的（INFERRED）

**OBSERVED（RAN）：**
- 71/71 個合成與改壞 JSON 的案例符合預期；27 條帶 IP 的路徑每條都有 ≥1 個 PASS 案例走完整條，其中 15 條另有真實 frame 走過。
- 13 個突變在 suite v2 全紅。v1 時有 3 個活下來（M4、M11、M12），補了案例才轉紅。
- firewall 的 39,841 個 `*_in` frame 用兩支程式各解一次，identity 差異 0。
- `pcap_links.log` 對到的位置：p4runtime 的 0x1212 只出現在 s1-eth2/s2-eth2；source_routing 末跳 s2-eth1_out 是 0x0800；mri 的 ihl 沿路 6→8→10；link_monitor 的 probe 最長 186 B。
- 我編的 `basic_tunnel.json` 和 09-24 live run 的產物 byte 完全相同（sha256 前綴 `bcb4ff532f30`）。

**READ（只讀了碼）：**
- 「今天的 twin」那一欄全部是讀碼，不是跑。native-model 是我拿 Python 重寫 `identifyFrame` 再跑的，不是 C++。
- 截斷值：`trunc 128`（`link_telemetry.py:75`），emitter 再截一次 `[:128]`（`sflow_emitter.py:88,174`）。

**INFERRED（推論，沒有實證）：**
- sFlow 的 input port 等於 bmv2 的 `standard_metadata.ingress_port`（沒有 RAN）。
- tc ingress 看到的 frame 跟 bmv2 `*_in` pcap 是同一份 bytes。
- 第 8 節「論文 app 會壞在哪」整節。
- INT 的形狀來自 `PAPER-APPS-CANDIDATES.md` 的轉述，我沒核實。

---

# 完整報告

## 1. 身分

- **編譯器**：`/usr/local/bin/p4c-bm2-ss`，sha256[:16] `226f3f66df515c9e`，1.2.5.15（SHA 5b948b037a），跟 `runs/2026-09-24T095344Z_basic_tunnel_solution.md` 記的是同一顆。
  - 指令：`nice -n 19 p4c-bm2-ss --p4v 16 -o json/<tag>.json <src>`。
  - 15 支 rc 都是 0，JSON 大小跟 `COMPILE-MATRIX.txt` 對得上。
- **tutorials**：`c80d83e9`。solution 檔、`firewall/basic.p4`、`p4runtime/advanced_tunnel.p4` 都乾淨。
- **NDTwin-Kernel**：HEAD `da10d3a3`，引用到的 9 個檔 `git status` 都乾淨。
- **環境**：Python 3.13.13，沒有 scapy（沒去裝）。
- **腳本 sha256**（`run_env.txt`）：
  - `p4pi.py` 68128e84…
  - `run_tests.py` bb7a6886…
  - `results.json` 7096c7bc…
  - `run_tests.log` a9fe86a9…

## 2. 分類定義與我判斷不同的兩處

- **D1**：每個 key 都是已抽出的欄位或固定寬度的 lookahead，header 都是固定長度。
- **D2**：要有 loop、stack 或 varbit 的直譯器才走得完，但結果完全由 bytes 決定。
- **N**：光靠 bytes + JSON 決定不了。
- **X**：這條路徑上沒有 IP。

跟工單不同的兩個判斷：

**(a) verify 不一律算 N。**
- mri 的 `verify(ihl>=5)`（`mri.p4:106`）只看已抽出的欄位，原型直接算得出來（`mri-ihl4`、`mri-5-ihl-wrap` 都得到 `IPHeaderTooShort`）。
- 若照工單字面把 verify 一律算 N，只用 bytes 的成功率降為 14/27 和 6/11；補 port 後的數字不變。

**(b) X 是「依程式語意的 X」。**
- 每支程式的 `default→accept` 都會吃進 IPv6。multicast 的唯一一條路徑也吃進 IPv4，source_routing 的 default 也吃進末跳的 IPv4。
- 也就是說，被判成 X 的路徑上，線上仍可能有 IP。

## 3. 逐支程式表

欄位說明：
- **合成**：B 部分，照各 exercise 的 send.py 用 struct 組封包。
- **真實**：D 部分，分子是程式 parser 解出的，分母是 oracle 判定線上有 IP 的。oracle 跟 JSON 無關。
- **今天**：READ。

| 程式 | 路徑數 | 每條路徑的類別 | 合成 PASS | 真實（解出／線上有 IP） | 今天（READ） | hint 行數 |
|---|---|---|---|---|---|---|
| basic | 2 | P1 D1，P2 X | 2/2 | 496/870（漏的 374 是 v6） | 對 | 0 |
| basic_tunnel | 4 | P1 D1（IP@18），P2 X，P3 D1，P4 X | 4/4 | 6/278（tunnel 6/6，漏的 272 是 v6） | **tunnel 錯**，只給 L2 key | 1（要加 next-proto 欄） |
| calc | 3 | 全 X（lookahead select） | 4/4 | 線上沒有 IPv4 | L2，對 | 0 |
| ecn | 2 | P1 D1，P2 X | 1/1 | 12199/12574 | 對 | 0 |
| firewall_basic（s2–s4） | 2 | P1 D1，P2 X | 1/1 | 跟 fw 合計 | 對 | 0 |
| firewall_fw（s1） | 3 | P1 D1，P2 D1，P3 X | 2/2 | 合計 52612/53014 | 對 | 0 |
| flowcache | 3 | P1 X（只走 CPU），**P2 N**，P3 X | 2/2（含 1 個預期拒絕） | 45/304（有給 port） | 對 | 0 |
| link_monitor | 4 | P1 D1，P2 X（D2 loop），P3 X（2 個 loop），P4 X | 6/6 | 80 個 probe 判 X | L2，對 | 0 |
| load_balance | 3 | P1 D1，P2 D1，P3 X | 2/2 | 30/303 | 對 | 0 |
| mri | 5 | P1 D1，P2 D1，P3 **D2**（count 迴圈），P4 D1，P5 X | 8/8 | 2588/2877（其中 12 個帶 MRI option） | 對（有看 ihl） | 0 |
| multicast | 1 | P1 X（只抽 ethernet） | 1/1 | **0/445** | 對 | 0 |
| p4runtime | 4 | 同 basic_tunnel | 2/2 | 30/320（tunnel 10/10） | **tunnel 錯** | 1 |
| qos | 2 | P1 D1，P2 X | 2/2 | 72/389 | 對 | 0 |
| source_routing | 2 | P1 **D2**（stack 讀到 bos=1，IP@16..32），P2 X | 5/5 | 7/240（漏 2 個末跳 v4、231 個 v6） | **srcRoute 錯** | 1（照 sketch 原樣即可） |
| ndtwin_switch | 10 | P1–P4 **N**（只走 CPU，IP@16），P5 X，P6–P9 **N**，P10 X | 11/11 | pcap 裡沒有它的資料 | 對 | 0 |

## 4. 成功率

**路徑層：**

| 口徑 | 只用 bytes | 補 port | 扣掉只走 CPU 的路徑（只用 bytes／補 port） |
|---|---|---|---|
| 全部 15 支 | 18/27（D1 16 + D2 2；N 9） | 27/27 | 18/23 ／ 23/23 |
| 7 支 custom-header | 10/11 | 11/11 | 10/11 ／ 11/11 |
| 程式層：13 支有 IP 路徑 | 11/13 | 13/13 | — |
| 程式層：custom-header 中有 IP 的 6 支 | 5/6 | 6/6 | — |
| IP 在 custom header 後面或裡面的 6 條 | 6/6 | 6/6 | 其中 mri 3 條今天已經對 ⇒ **淨增 3 條** |

**封包層合計**：
- 取樣 72,213，線上帶 IP 71,966，其中 IPv6 3,691。
- 解對的數量：程式 parser 68,085；native-model 71,943；hints 71,966；native 先、程式補位 71,966。
- 程式 parser 補上 native 漏掉的：23 個。解錯的：0 個。
- 真實證據裡 custom-header frame 很少：tunnel／srcRoute 23 個，MRI option 12 個。
- **firewall 和 link_monitor 的 pcap 是 skeleton run 寫的**（時間窗分別對到 `111149Z`、`113038Z`）。兩支的 parser 跟 solution 一字不差，所以 frame 格式可以用；但那兩組 frame 不是 solution 產生的。

## 5. 原型會說「不」：跑過的反例（RAN）

- **沒給 port**：`fc-2-noctx`、`ndt-2-noctx` → REFUSE `standard_metadata.ingress_port`。
- **同一包 bytes、不同 port 就不同答案**（`syn_meta_key`，key 是從 ingress_port 算出來的 scalar）：不給 port → REFUSE；port 4 → IP@18；port 1 → NO_IP。
- **給錯 port**（`ndt-3-wrongctx`）：→ NO_IP，安靜地漏掉，但沒有給錯的五元組。
- **value_set**：排在它之後的 transition（0x88B6）→ REFUSE；排在它之前的（0x0800）→ IP@14。
- **stack 爆掉**：`sr-10-overflow` → StackOutOfBounds，bmv2 本身也會如此；hints 沒有 stack 上限，照樣找到 IP@34。
- **截斷**：`syn-deep-6`/`-8` → TRUNCATED。
- **改壞的 JSON**：
  - K1、K2：沒給 identity，安全。
  - K3：sanity 拒絕。
  - **K3b 把 sanity 關掉 → 給出錯的五元組 `1.1.10.0->2.2.195.82 proto=203`。**
  - K4 是正向對照：把 IPv4 改名後仍然認得出來，因為原型認 IP 靠欄位結構、不靠名字。
- **突變**：13 個突變在 v2 全紅。v1 時 M4（忽略 transition mask）、M11（取最外層 IP）、M12（varbit 長度當 0）活下來，補了 `syn-meta-ipv4-core`、`syn-ipip`、`syn-varbit` 的 `expect_l4` 才轉紅。
  - 補完後未突變的原型一度是紅的：`syn_varbit_ok` 的 `l4_t` 只有 port 欄位、不是完整 UDP。重編成真的 tcp_t/udp_t 才轉綠，兩版都記在 `COMPILE-synthetic.txt`。

## 6. 兩種方法都會撞到的限制

### 6.1 截斷

- 截斷長度 128：tc 那層 `link_telemetry.py:75`（命令在 `:347-351`），emitter 再截一次 `sflow_emitter.py:88,174`。kernel 端上限 256（`SFlowType.hpp:151`），不是瓶頸。
- 最遠需要讀到的 offset，全在 128 內：

| 路徑 | IP + L4 port 結束位置 |
|---|---|
| 一般 IPv4 | 38（ihl 15 時 78） |
| tunnel | 42 |
| srcRoute | 40..56（ihl 15 時 96） |
| mri | 42..74（實測最遠 58） |

- link_monitor 的 probe 最長 186 B，但原型靠可達性提早判成 X，不必讀到尾。
- 懸崖在哪：IP 起點必須 ≤104 B。

### 6.2 custom header 在線上的位置

READ 與 RAN 一致：
- **basic_tunnel**：所有 link 都有，包括送到 host 的最後一跳。switch 從不 push 或 pop（`basic_tunnel.p4:147-157`；host 送出，`send.py:40`）。
- **p4runtime**：只在 s1–s2。s1 加上（`advanced_tunnel.p4:123-127`），s2 拆掉（`:135-139`）；控制器設定在 `mycontroller.py:192,196`。
- **source_routing**：host→switch 和 switch→switch 有，最後一跳沒有，因為 `srcRoute_finish` 把 etherType 改回 0x0800（`source_routing.p4:119-120`）。
- **mri**：所有 link 都有，藏在 IPv4 裡、每跳變長（`mri.p4:196-208`）。
- **flowcache／ndtwin**：controller header 只在 CPU port 出現（`p4_testbed_topo.py:225-226`；`topology.json:30-36`），永遠不會出現在 veth 上。

### 6.3 混合 fabric：該用哪支 parser

- firewall：s1 跑 firewall，s2–s4 跑 basic（`pod-topo/topology.json:39`）。用哪支解，identity 都沒差（39,841 個 frame 差異 0）。
- **規則（推論）**：
  - ingress sample → 用收端 switch 的程式。逐台 pipeline 已經查得到（`app_package.py:302-312`）。
  - egress sample（只在 host-facing port，`link_telemetry.py:312,332-338`）→ 只有 native 才對。用送端的 parser 只是運氣：`btun-1b` 碰對，`sr-last-hop` 就錯。

### 6.4 twin 這邊的接線點（READ）

- `identifyFrame` 在 `FLUC.cpp:1510` 呼叫，早於 port 換算（`:1549`）。port 本身是在的：位置 word +7（`:1456`），bmv2 不做換算（`:259-262`）。
- 今天的 IPv4 分支不檢查 version，只看 ihl（`SFlowType.hpp:347-352`）。要接在 hint 或 auto-derive 後面，就必須補上這個檢查。

## 7. Hints

- **行數**：總共 3 行（basic_tunnel、p4runtime、source_routing 各 1），其餘 12 支是 0。
- **sketch 的格式夠不夠**：
  - source_routing 照原樣就能表達。
  - tunnel 需要多一個 next-proto 欄。不加的話，proto_id≠0x0800 的封包會被當成 IPv4。加了之後，hints 在 `btun-3` 還比程式 parser 多找到一個 IPv6。
- **表達不了的**：計數迴圈（mri、link_monitor）、lookahead select（calc）、port 依賴、value_set。在 tutorials 裡這些都只出現在沒有 IP 或不在線上的路徑，所以目前沒影響。
- **RAN**：真實 frame 71,966/71,966。

## 8. 真實論文 app 上會弄壞 auto-derive 的東西（推論）

1. **INT shim 插在 IPv4 和 L4 中間**（據 `PAPER-APPS-CANDIDATES.md` §3，未核實）：`ihl*4` 規則會讀錯 port。原型已經算出 `l4_program_offset`（`fw-1-s1`=34、`syn-varbit`=42），但還沒拿它取代 `ihl*4`。
2. **per-hop stack 把 IP 推過 104 B**，或 L4 被推出 128 B。
3. **兩層 IP**：選哪層是政策問題。
4. **value_set、port 或 metadata 當 key**：一律 REFUSE，或需要 context；egress sample 沒有 ingress port。
5. **header union、多 parser、Tofino 版本**：原型拒絕 union（可以實作）。用 `#ifdef TOFINO` 的程式只有 bmv2 build 才有 JSON。
6. **JSON 跟線上不符**：只有 sanity 擋著。加上 checksum 檢查可以更嚴，但會誤拒 source_routing 這種不更新 checksum 的 app。
7. **程式不 parse 的協定**（IPv6、multicast、末跳）：只能靠 native 先做。

## 9. 論文 app 候選（沒有分析）

5 支都沒 clone、沒編、沒跑，以下只依據 `PAPER-APPS-CANDIDATES.md`：

| 候選 | 有什麼 custom header | 建議 |
|---|---|---|
| A ONTAS | VLAN | native 已經剝一層 VLAN（`SFlowType.hpp:305-311`），該文件寫的「整包丟」是 P3 之前的狀態。不必測 |
| B HashPipe | 純 IPv4 | 不必測 |
| C int-v1 | INT shim 在 IPv4 和 UDP 之間 | **最值得 clone**：正好測第 8 節第 1、2 點 |
| D GEANT int-platforms | INT，加上 clone report | 高價值，能測兩層 IP 與每跳長度；環境成本最高 |
| E p4-learning | 涵蓋的構造種類最廣 | 中 |

## 10. 對帳舊結果

- **「mri 看得見但讀錯（`:1299-1300` 固定字組位移，沒用 ihl）」**（`GAP-ANALYSIS.md:122-124,265`）：**已被 TICKET-P3 推翻**。現在的碼會看 ihl（`SFlowType.hpp:343-369`）；native-model 在 12 個真實 MRI frame 上也解對了（RAN 的是模型，不是 C++）。INT 那種形狀的讀錯風險仍在。
- **「custom_headers 做不到」**（`GAP-ANALYSIS.md:44,75`）：**更新**。非 IPv4 現在進 L2 側表（`FLUC.cpp:1049-1100`），剩下的缺口就是那 3 條路徑、23 個 frame。

## 跑過、也都有 log 的閘門

- 編譯：`compile-logs/COMPILE.txt`、`compile-logs/COMPILE-synthetic.txt`
- 全套測試：`run_tests.log`，rc 0，71/71
- 突變：`mutate.log`，v2 沒有倖存者
- 線上位置：`pcap_links.log`
- 執行環境：`run_env.txt`

DELIVERED（純分析工單，沒有 git commit，所以沒有 commit sha。產物識別碼：`results.json` sha256 `7096c7bccb685256`、`run_tests.log` sha256 `a9fe86a9f8328b35`。）
