# int-v1 INT shim check (opus worker, 2026-10-01; int-v1 @84a3ebe8)

## 結論：int-v1 的 INT 流量，今天的 identity 不會悄悄讀錯 5-tuple，p4pi 也解得對

int-v1 @84a3ebe8 的 INT 標頭排在 **TCP/UDP 標頭之後**。PAPER-APPS-CANDIDATES §3 寫的「插在 IPv4 與 UDP 之間」跟它的程式碼不符，我上一份報告 §8 第 1 點的風險，在這支程式上也就不成立。

我把 4 條 link 上的 9 種 frame 都跑過一遍（INT source 之前、之後、送到 h2、有 metadata 的 1/2/4 跳、sink 剝掉後），每一種都得到正確 5-tuple：
- native-model（我用 Python 重寫的 identifyFrame，**是模型，不是 C++**）：10 個案例中的這 9 個都對。
- p4pi 照原樣跑（port 位置用 ihl*4 算）：同樣 9/9 對。
- p4pi 改用程式自己抽出的 L4 header 位置（`l4_program_offset`）讀 port：也 9/9 對，兩種算法的位置都是 34。

真的會悄悄錯的情況只在對照組：我刻意把 shim 插在 IPv4 和 UDP 之間，也就是 PAPER-APPS 宣稱、但 int-v1 實際上不是這樣排的那種版位。這時 native-model 得到 sport 256 / dport 2816，p4pi 兩種讀法也一樣錯。p4pi 只會照 JSON 描述的版位去讀，JSON 沒描述的版位它救不了。

## 1. 編譯（RAN）

- 指令：`cd /home/adam/paper-apps/int-v1 && nice -n 19 p4c-bm2-ss --p4v 16 -o <scratch>/int-v1/int.json int.p4`
- 結果：rc=0，**沒有改任何一行**，只有 2 個 unused-typedef 警告。
- 產物 `int.json` sha256[:12] 為 `2c4dba92b858`。repo 的 `git status` 仍是乾淨的。

## 2. INT 標頭在線上的位置

以下是 READ，附 `file:line`：

**怎麼標示 INT**
- 靠 DSCP，不是靠 IP option。`DSCP_INT = 0x17`（`include/defines.p4:30`）。
- parser 是在**已經抽出 TCP 或 UDP 之後**，才看 `select(hdr.ipv4.dscp)`（`include/parser.p4:36-55`）。
- 接著是 shim、INT header，再來是長度可變的 `int_data`。長度算法是 `(shim.len-3)<<5` 個 bit（`parser.p4:57-70`），上限 1920 bit（`include/headers.p4:138`）。

**deparser 輸出順序**
- ethernet、ipv4、tcp、udp、int_shim、int_header，然後是逐跳 metadata、int_data（`parser.p4:96-116`）。
- 所以 INT 一定在 L4 之後；5-tuple 永遠落在第 14–42 byte。

**source 做了什麼**（`include/int_source.p4:21-53`）
- 加上 shim（4 B，`len=3`）和 INT header（8 B）。
- `ipv4.len` 和 `udp.length_` 各加 12，DSCP 改成 0x17。

**實際啟用的 source 只有一個**
- `runtime_cmds/s1.sh:7` 只把 s1 的 port 1 設成 source，對應的流量規則在 `:21`，參數是 hop_metadata_len=8、remaining=4。
- `runtime_cmd.sh` 只執行 s1.sh。

**這個 commit 沒有 transit，也沒有 sink**
- 全樹沒有任何地方把 `int_switch_id` 這類 metadata header 設成 valid。
- `int_set_sink`（`int_source.p4:109-111`）只設 `int_meta.sink`，之後沒有任何程式讀這個值。
- egress 是空的（`int.p4:52-56`）。

**由此推得線上長這樣（推論自上面的程式碼）**
- 拓樸是 h1–s1–s3–s2–h2（`linear-topo/topology.json`）。
- h1→s1 是一般 UDP（send.py:37-38，port 8001→8002）。
- s1→s3、s3→s2、s2→h2 都帶 shim+header，固定多 12 B，每跳不再變長，到 h2 也**不會被剝掉**。
- 1/2/4 跳 metadata 的 frame，以及「sink 剝掉後」的 frame，在這個 commit 都不會真的出現。我照 INT v1.0 的格式建出來，在 log 裡標成 HYPOTHETICAL。

## 3. 各 frame 結果（RAN，`int-v1/run_int.log`，10/10 符合預期，rc 0）

每個 frame 都截到 128 B，同時傳入真實原長。

| frame | 原長 | native-model | p4pi 照原樣 | p4pi 用程式抽出的 L4 位置 |
|---|---|---|---|---|
| F0 source 之前 | 51 | 對 | 對 | 對 |
| F1 source 之後（真實版位） | 63 | 對 | 對 | 對 |
| F1 到達 h2 | 63 | 對 | 對 | 對 |
| F2 1 跳 metadata（假設） | 95 | 對 | 對 | 對 |
| F3 2 跳（假設） | 127 | 對 | 對 | 對 |
| F4 4 跳（假設） | 191 → 截成 128 | 對 | 對；`int_data` 被截斷時 IP 和 port 已經抽出 | 對 |
| F5 sink 剝掉後（假設） | 51 | 對 | 對 | 對 |
| T1 INT over TCP | 75 | 對 | 對 | 對 |
| T2 TCP 2 跳（假設） | 139 → 截成 128 | 對 | 對（同樣是截斷後才抽到 int_data） | 對 |
| X1 對照組：shim 在 IP 與 UDP 之間 | 95 | **悄悄錯**（256→2816） | **悄悄錯** | **悄悄錯** |

- 在 int-v1 的版位上，沒有任何拒絕或退回 L2 的情況。
- 悄悄錯只出現在 X1 對照組，它同時證明這套判定確實分得出「悄悄錯」。

## 4. 回答第 4 點：兩種 port 讀法

- `p4pi.py` 沒有改動，sha 仍是 `68128e84`，所以我先前回報的照原樣結果不變。
- 用 `l4_program_offset` 讀 port 的做法寫在 `run_int.py` 的 `p4pi_with_program_l4`。
- 在 int-v1 上兩種讀法的位置都是 34，結果完全相同。只有在 X1 那種版位兩者才可能不同，而在 X1 上兩者都錯，因為 JSON 本身就把 shim 當成 UDP。

## 5. 上一份 §8 預測了什麼、說中了什麼

| 預測 | int-v1 實際情況 |
|---|---|
| INT 插在 IP 與 L4 之間 | **推翻**：在 L4 之後 |
| value_set | 沒有 |
| varbit | 有：`int_data`，靜態分析判為 D2，長度能由封包推出，沒有 N 類路徑 |
| clone / report 封包 | 沒有：report header 有宣告，但從未設成 valid，deparser 那幾行也被註解掉（`parser.p4:83-86`）；JSON 裡沒有 clone、resubmit、recirculate；所以也沒有「內層還有一個 IP」的情形 |
| IP 起點 ≤104 B 的截斷懸崖 | 沒撞到：IP 在 14、port 在 34–42。截斷只會切到 INT metadata，例如 F4、T2，不影響 5-tuple |

另外兩點沒有預測到：
- 靜態分析（`static.log`）列出 6 條 parse path：D1 ×3、D2 ×2、X ×1，沒有 N。最大的差別是這支程式**根本沒有 transit 和 sink**，INT 只是固定 12 B，一路帶到 host。
- READ：FlowKey 不含 DSCP（`include/common_types/SFlowType.hpp:84-115`），所以 source 前後是同一條 flow。
- 推論：INT link 上每個 frame 的 frameLength 多 12 B，算進 link bytes；以線上實際位元組來說，這是對的。

## OBSERVED 與 INFERRED

**OBSERVED（RAN）**
- int.p4 不改一行就能編譯。
- 10 個 frame 的三種 identity 結果如上表。
- JSON 裡沒有 value_set、union、clone。

**READ**
- 上面引到的所有程式碼位置。
- 「沒有 transit、沒有 sink」來自 grep 結果和 egress 為空。

**INFERRED**
- 線上各 link 長什麼樣，是從程式碼推出來的，**沒有跑 bmv2，也沒有 pcap**。
- 1/2/4 跳 metadata 和 sink 剝除的 frame 都是假設，這個 commit 不會產生它們。
- native 欄跑的是 Python 模型，不是 C++。

檔案都在 `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/parser-autoderive/int-v1/`：
- `int.json`
- `compile.log`
- `run_int.py`
- `run_int.log`
- `static.log`
- `run_env.txt`

DELIVERED（沒有 git commit；`run_int.py` sha256 `14a66f366f05a155`、`int.json` sha256 `2c4dba92b8581200`）
