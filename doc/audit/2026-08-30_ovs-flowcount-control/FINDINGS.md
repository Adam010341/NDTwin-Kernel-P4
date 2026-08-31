# FINDINGS——OvS 同梯對照（C3 對照平面半邊；PREREG＋AMENDMENT-1 本目錄）

**2026-08-30 13:44–14:1x 量測；6＋1 臂（原名「無 shaping／shaped 對照」——🔴 實為同 config，見下方更正框）。**
執行 `8/29 poster-reviewer`。raw＝`raw/`（**audit-raw `a868948`**；🔴 **08-31 更正：原寫
「本地、push 凍結中」已過期**——`a868948` 已是 `p4/audit-raw` 的祖先，**不再是 local-only**；
`lab/audit-raw` 則**不含**它。非公開靠的是 `Adam010341/NDTwin-Kernel-P4` 為 **PRIVATE**
（`gh repo view --json visibility` 實查），**不是靠沒推**。公開的 `ndtwin-lab/NDTwin-Kernel`
上**沒有** `audit-raw` 分支。⇒ 引用 artifact 要指名 commit，分支名不是可引用的東西。）
driver 在第七臂 160M 階被行程重啟殺掉——**決定性讀值（45 clean／70/110 大髒）已在盤面上**，
缺的只有無資訊的尾階與收尾摘要。

> 🔴 **更正（08-30 15:0x，最終驗收時發現；取代 `71e482e` 版的歸因與對照裁定，H-B 主結論不動）**
> **七支臂全部跑在 as-configured 的 1 Gbit-shaped fabric 上。**「unshaped」臂不存在：
> `ndt up ovs` 執行的是 **NTG repo 的** `testbed_topo.py`（`/usr/local/sbin/ndtwin-lab:83` 指名；
> mtime 2026-07-08、`bw=1000` 全在），我 patch 的是 kernel repo 的**同名副本**＝對 fabric 是 no-op。
> 證據三重：①實跑檔內容（access＋leaf-mid `bw=1000`、spine `bw=10000` 被 Mininet 靜默忽略）；
> ②n=1/4 高階發送端被壓到 ~0.95–0.96 G ≈ **htb 1 G 的 goodput 上限**（1000×1400/1442≈971 Mbit）；
> ③08-28 jitter 輪在同一 fabric 直接讀到 htb（`2026-08-28_jitter-working-point/05_layer_attribution.md`：
> h1-eth1／s3-eth3、overlimits 數百萬）。driver 的 htb 斷言兩次讀 0＝**假陰性**（機制未定位，
> 待 T-4 窗外 live 釘死）；結構缺陷＝expect-0 側有 die-gate、expect->0 側只有 echo——
> **有訊息的那一側沒有 gate**。
> 連帶更正：§2 天花板歸因（veth/softirq→配置的 htb 帽）、§3 陽性對照（空跑＝第七 replicate）、
> §5 素材句（「shaping removed」拔除；poster :238 已落稿處同步修）。另查明 bmv2 ③ 的 fabric
> （`p4_proxy/mininet/ntg_bmv2_topo.py`）**無 bw=／TCLink＝unshaped**：兩平面 shaping 不對稱，
> 方向對 H-B **保守**（OvS 戴 1 G 帽仍 22–45×）。

## 0. 一句話

**H-B（預註冊分支）：OvS 每流也降，但只降到「合計天花板 ÷ n」的均分線上——
aggregate 不塌（720–960 Mbit 全程撐住）；bmv2 的 aggregate 自己塌了 10×。
n=16 每流：OvS 45 vs bmv2 1–2＝22–45×。**
（🔴 天花板＝**配置的 htb 1 G 帽**的 goodput 上限 ≈971 Mbit，不是有機極限——見更正框。）

> 🔴 **08-31 追加裁決：H-C（儀器界定）亦成立 ⇒ 本輪三個每流數字一律 instrument-bounded。**
> 逐格界定＝**n=1：540（receiver-socket-bounded）／n=4：240（htb-capped；名目最高乾淨階
> 810＝其 generator-gate 頂）／n=16：45（未受上述兩者界定）**。
> **H-B 的判決不變**（拿掉收端限的 n=1 格，n=4 對 n=16 仍差四階），改變的是**敘述**：
> 這三個數不得以裸值引用，須帶界定詞並**指名是哪個儀器**。歧義與裁決理由＝§1a。

## 1. 每臂結果（validity 欄＝auditor 要求：這階的 clean 是量出來的、還是發送端沒送滿）

🔴 **validity 欄是「跑完之後」才補上的判準**（auditor 於審 FINDINGS 時要求；同 §6.7 第 6 條）。
**它不得用來決定任何預註冊條款是否觸發**——08-31 的 H-C 裁決即依此（詳 §1a）。
本表把它保留為診斷欄，不作為註冊判準的仲裁者。

「valid」判準（逐階）：`agg_sent ≥ 0.95 × n × offered`。不滿足＝**發送端 backpressure 假象**
（🔴 更正：壓住發送端的是 h1 access link 的 **htb 1 G 帽**——goodput ≈971 Mbit @1442 B frame——
不是原版寫的「veth 回壓」；iperf3 被壓到 ~960 Mbit 合計、loss 讀 clean 但該階根本沒被施加）——
「儀器極限偽裝成乾淨」的**反向新形狀**，本輪首見，raw 的 `agg_sent` 欄全程可稽。
（n=16 髒階 sent 滿載、n=1/4 高階 sent 被壓——同一頂帽下兩種發送端行為，kernel 層機制未定位；
判準只比對 sent vs offered、不依賴機制，兩種情形都分對了。）

| 臂 | 名目 best_clean | **valid best_clean** | 無效階（offered≠sent） | 頂階確認 | 髒階證據（sent 滿載） |
|---|---|---|---|---|---|
| ovs_n1_a | 540 | **540** | 1215（sent 952） | 0.3391% ✅ | 810 @ 0.647%（sent 809.9 ✓） |
| ovs_n1_b | 540 | **540** | 1215（首讀假 clean→確認 0.6193% 掛） | 0.2681% ✅ | 810 髒（sent 滿） |
| ovs_n4_a | 810 ⚠️假 | **240** | 360/540/810（sent 皆 ~962＝殺到 240/流） | （240 行 3 reps 0.0893%） | — |
| ovs_n4_b | 810 ⚠️假 | **240** | 同上 | 同上 0 損 | — |
| ovs_n16_a | 45 | **45** | 無（70/110/160 sent 滿載） | 0.0187% ✅ | 70 @ 16.78%、110 @ 50.3% |
| ovs_n16_b | 45 | **45** | 無 | 0.1245% ✅ | 70 @ 17.79%；110/160＝NO_MEASUREMENT（iperf3 控制通道，與 ③ n=16 高階同形） |
| n16_shaped | （45） | **45** | 無 | ⚠️ 無最終確認輪（driver 被殺）；階內 3 reps 中位 0.0156% | 70 @ 18.97%、110 @ 47.2% |

## 1a. H-C 的歧義、四種讀法，與它往哪邊解（08-31 auditor 裁）

**不要只讀結論**：我們在資料之後發現一條註冊判準有歧義，並解掉了它。**解一個歧義就是用掉
一個自由度**，所以歧義本身、四種讀法、以及往哪邊解，都必須留在紀錄裡。

**判準原文**（`PREREG.md:75`）：「**≥2 格右截尾或被收端指認** ⇒ 報 instrument-bounded；poster 不動」。
**它依賴的截尾規則**（`PREREG.md:41-42`）：「每格允許梯頂＝最大 rung 使 `n×rung ≤ loopback_agg(n)/5`
… **若某格的最高乾淨階＝該格 gate 頂 ⇒ 該格右截尾**」。

**數據**（gates 實測 `:157`＝7311／21361／38258 Mbit）：

| n | gate 頂算式 | 允許梯頂 | 名目最高乾淨階 | ＝gate 頂？ | 另註 |
|---|---|---|---|---|---|
| 1 | 7311/5/1＝1462.2 | 1215 | 540 | ✗ | **被收端指認**（RcvbufErrors） |
| 4 | 21361/5/4＝**1068.05** | **810** | **810** | **✅** | 表中標 `810 ⚠️假 → 240`（依 validity 欄） |
| 16 | 38258/5/16＝478.2 | 360 | 45 | ✗ | — |

**四種讀法**（歧義點＝量詞「≥2 格」對選言「右截尾 或 被收端指認」的轄域）：
R1「(≥2 格右截尾) 或 (任一格被收端指認)」⇒ **觸發**；R2「≥2 格滿足(截尾或收端指認)」⇒ **觸發**；
R3 需 ≥2 格右截尾 ⇒ 不觸發；R4 同 R3 且主張 n=4 不算截尾（810 係假 clean）⇒ 不觸發。

**裁決＝觸發，理由分四層，第三層決定性**：
1. 文法上 R2 最自然（量詞前置、轄域涵蓋選言）；R3/R4 需兩個額外假設。
   ⚠️ **但文法不具仲裁力**：**鄰列 H-A 用括號消歧（「差 ≤1 階（或兩者皆右截尾…）」）而 H-C 沒有**
   ⇒ 缺括號不能被讀成作者的本意。**歧義是真的。**
2. R4 要求**一個事後補上的 validity 欄推翻一條預註冊的截尾規則**——用資料之後才存在的判準
   決定資料之前凍結的條款是否觸發，**正是預註冊要消滅的東西**。
3. 🔑 **決定性**：R4 用來否定截尾的那個事實**本身就是儀器界限**——810 之所以是假 clean，
   **是因為 htb 的 1 G 帽，而那是我們的儀器不是受測系統**。⇒ n=4 在 gate 頂的數字由儀器決定；
   叫它「右截尾於產生器閘」或「被 htb 帽污染」都是 instrument bound。
   **H-C 的用途就是標記這件事，所以在 R4 自己的前提下 H-C 想抓的東西確實發生了。**
   **條文與用途分岔時，用途說了算。**
4. 後果不對稱：觸發只改 framing（H-B 判決不變）；不觸發等於用事後判準解掉預註冊條款、
   且方向剛好省事——**那一筆將來沒有辯護**。

🔑 **通則（進裁決紀錄）**：**一條預註冊判準在資料之後被發現有歧義時，往「對自己比較不利」
的那個讀法解。** 歧義是一個自由度，而預註冊的全部意義就是事前交出自由度；
事後才發現的自由度，唯一不破壞制度的用法就是**不去用它**。

⚠️ **poster 那一行依註冊「不動」＝屬 Adam 的投稿物件裁量，本輪不自行處理。**

**鏡像複製：三格兩臂全部同階（540/540、240/240、45/45）＝rung 級零階差。**
（照 ③ 紀律：這證明階穩定，不證明真值在階內何處。）
🔴 更正：表中 `n16_shaped` 與其他六臂**同一個 fabric config**（patch no-op，見更正框）——
它不是對照臂，是第七支 replicate；各臂的「無 shaping」原名一律讀作 **as-configured（1 G-shaped）**。

## 2. 歸因（雙讀值兌現）

- **零 ECMP 散佈**：n16_a 全 switch 計數器＝**s1/s6/s9/s7/s3 各 7.26 GB（rx=tx 逐台相等）**，
  其餘 switch 靜默 ⇒ 16 條 port 區分的流走**同一條 5-switch 路徑**——
  `flows/switch=flows/link=n` 在 OvS 側**由量測成立**（PREREG 已知差異 #2 消滅；
  置放構造與 ③ 同構，Ryu 的轉發等效 dst-based）。
- **n=1 的天花板是收端 socket**：RcvbufErrors 44,392／48,410（a/b），與髒階損失同量級
  ⇒ **540 這個數字是「單收端行程」的極限，不是 OvS datapath 的**（[[jitter-is-the-receiver-not-the-network]] 的再現）。
- **n=4/16 的損失在 fabric 內**：RcvbufErrors 僅 199–3,586，對髒階數百萬丟包＝滄海一粟
  ⇒ 損失在 fabric 內、不是 socket。🔴 更正：~0.96 Gbit 天花板＝**as-configured htb 1 G shaping
  的 goodput 上限（≈971 Mbit）**，不是原版寫的「OVS kernel datapath／veth 路徑（softirq）」；
  具體丟在哪個 qdisc（h1 access egress vs s1→s6 leaf-mid trunk，兩者同為 1 G）未逐一定位。
- ⇒ **對照最乾淨的格＝n=16**（兩平面同為 fabric 限制、同構造、同梯；OvS 側的 fabric 限制
  ＝配置帽）：**45 vs 1–2**。

## 3. 陽性對照裁定 —— 🔴 更正：空跑（void），不是命中

原版裁定「shaped（htb 1G）n=16 發火位置逐階命中」**作廢**：patch 是 no-op（更正框），
「shaped 臂」與六支主臂**同一個 fabric config**——「還原 shaping」這個操縱從未發生，
對照量不到它。第七臂實際上是**追加 replicate**：70 階 agg_recv 954.77 vs 主臂 955.75（差 0.1%）、
45/70/110 的 clean／髒邊界與主臂全同＝**階穩定性的追加證據，不是對照證據**。
原版已揭露「shaped 與 unshaped 在本工作點不可分辨」——現在知道不可分辨的真因：
**兩臂本來就同 config**。

「讀出鏈看得見 ~1 G 級的帽」改由主臂資料自身承擔：n=1/4 高階 sent-throttle 恰落在 htb
goodput 上限（≈971）、n=16 髒階損失率與 1 G 帽算術一致（70 階均分預測 ~15%、實測 16.8–19.0%）。
PREREG 的放棄條款（「shaped n=16 讀不出帽 ⇒ 整輪 instrument-invalid」）**未觸發**——
帽的簽名處處讀得出；失效的是**操縱**，不是**讀出**。PREREG 沒註冊「對照空跑」這一支
＝C1「跨界⇒不可分辨」教訓的同族缺口，照實記。

## 4. 與 bmv2 ③ 對照（同梯、同置放構造、各自 as-configured 控制平面）

| n | bmv2 每流（a/b） | OvS 每流（a/b） | bmv2 aggregate | OvS aggregate |
|---|---|---|---|---|
| 1 | 160 / 240 | 540 / 540 ⚠️收端限 | 160–240 | 540 |
| 4 | 30 / 45 | 240 / 240 | 120–180 | 960 |
| 16 | 2 / 1 | 45 / 45 | **32–16（塌 ~10×）** | **720（撐住）** |

- OvS 每流 540→45＝6 階；**與「合計天花板均分」一致**（45×16=720 ≤ 960 < 70×16=1120）。
- bmv2 每流 160→2／240→1＝10–12 階；**aggregate 自身塌陷**＝超出任何均分模型的下降。
- n=16 每流差 **22–45×**；且 bmv2 n=16 實測（1–2）比自己單流的均分預測（160/16=10）還低 5–10×。
- 🔴 更正補充：**兩平面 shaping 不對稱**——OvS 臂在 1 G-shaped fabric（as-configured），
  bmv2 ③ 的 fabric builder（`p4_proxy/mininet/ntg_bmv2_topo.py`）**無 bw=／TCLink＝unshaped**。
  方向保守：OvS 戴帽仍 22–45×；bmv2 無帽而 aggregate 自塌（塌到帽以下 30 倍處，帽解釋不了）。
  表中數字全部不變。

## 5. 建議落稿句（Adam 已裁「加」；作者 session 措辭，紅線如下）

素材句（🔴 更正版——原版的 "shaping removed" 為假，poster :238 已落稿處**必須拔除**）：
> *An OvS control on the same ladder and placement (all $n$ flows measured onto one path ---
> switch counters confirm zero ECMP spread --- on its as-configured 1\,Gbit-shaped fabric,
> a cap the unshaped bmv2 fabric does not have) declines only as aggregate-sharing predicts:
> per-flow 540/240/45\,Mbit at $n{=}1/4/16$, the $n{=}1$ cell receiver-socket-limited, with
> the aggregate holding at its configured cap (0.72--0.96\,Gbit delivered) --- whereas bmv2's
> uncapped aggregate itself collapsed an order of magnitude.*

**紅線**：(a) n=1 的 540 若入文必掛「receiver-socket-limited」——或乾脆只用 n=4/16；
(b) 不得寫「matched working points」以外延伸（同梯＝真、同置放＝量測證實，就寫這兩件）；
(c) 兩平面各自 as-configured 控制平面（Ryu vs proxy）照舊揭露；(d) 「不可分辨」句已由
§3 更正取代——poster 不進、study 版收更正後的版本；(e) smoke 級規模照實
（3 格×2 臂、單日）；(f) **本輪任何數字不回填 C1/C2**；
(g) 🔴 **不得寫「unshaped」「shaping removed」「有機天花板」**——OvS 臂全程 1 G-shaped，
aggregate 天花板入文必須歸給配置的帽，且 bmv2 fabric 無帽這個不對稱要見光（方向保守）；
(h) 🔴 陽性對照不得引用（空跑）。

## 6. 偏差與限制（誠實清單）

1. 3 格非 5 格；每格 2 臂（smoke-grade）。
2. **無已驗證外來負載偵測器**（照 ③ 揭露）；且本輪的外來負載含**審查艦隊自己**
   （7 隻 agent 同窗串流；n16_a busy 0.8658 部分屬之）＋作者 session tectonic（13:38±，
   臂前、零重疊）。方向：外來負載**壓低** OvS 讀值 ⇒ 對「OvS 高於 bmv2」的結論是保守方向。
3. shaped 臂無最終確認輪（driver 被殺於無資訊尾階）；n16_b 有兩個 NO_MEASUREMENT 階。
4. 發送端 gate 用 loopback 註冊，**沒預見 fabric 端的發送壓制**（🔴 更正：真身＝access htb 帽，
   非 veth 回壓）——被 §1 validity 欄**事後**補上（判準是 auditor 在跑完後審 FINDINGS 時要求的，
   不是預註冊的）；下一輪的 gate 應直接量「經 datapath 的可施加率」。
5. OvS/Ryu 為 as-configured（reactive 學習已 warm）；bmv2 側為 proxy dst-based——
   對照平面本來就不同平面，C3 框架如此。
6. 🔴 **patch 打錯 repo 副本**：fabric builder＝NTG repo 的 `testbed_topo.py`（`ndtwin-lab:83`
   指名執行），我 patch＋sha256 指認的是 kernel repo 的同名副本＝no-op。py_compile／diff／sha
   斷言全打在「檔案」上，沒有一個打在「fabric」上——「指認量到的 binary」教訓的拓撲檔版本。
7. 🔴 **htb 斷言假陰性 ×2**：`sudo -n tc -s qdisc show | grep -c htb` 兩次讀 0，而 08-28 jitter
   輪在同 fabric 直接讀到 htb、且本輪 0.96 G 簽名證明帽在。
   🏁 **機制已定位（08-31 16:03，`c55a12b`）——本條原寫「未定位（待 T-4 窗外）」，該敘述作廢**：
   正本＝[`../2026-08-31_completeness-experiments/FINDING-htb-false-negative-mechanism.md`](../2026-08-31_completeness-experiments/FINDING-htb-false-negative-mechanism.md)。
   一句話：**免密碼 sudoers 白名單只有 `tc qdisc show dev s[0-9]*-eth[0-9]*`**，
   而斷言呼叫的是 `sudo -n tc -s qdisc show`（無 `dev`、`-s` 在物件前）⇒ **不匹配 ⇒ 要密碼
   ⇒ 指令從未執行 ⇒ stdout 全空 ⇒ `grep -c htb` 忠實地數出 0**。
   讀到的 0 **不是「沒有 htb」，是「沒有輸出」**；`2>&1` 還把那行錯誤寫進了「資料」檔，
   於是 31/31 個 `tcqdisc_*.txt` 存在、非空、看起來像有輸出。
   ⚠️ **這一行是 08-31 22:5x 補的**：更正在 16:03 就落了檔，但**提出這個懸案的這份文件
   沒有被指過去**，於是讀者在六個多小時裡仍然讀到「未定位」。
   同一天另一條線（8/29 poster-reviewer）因此**從頭重推了一次同樣的機制**——
   那是「撤回／更正要 grep 引用點」這條規矩的成本被實際付出的一次
   （[[disclosure-is-not-downgrading]]）。
   結構缺陷＝expect-0 側有 die-gate、expect->0 側只有 echo——有訊息的那側沒 gate。
8. 🔴 發現時序：6/7 兩條是 08-30 15:0x 最終驗收時發現，**在 auditor 收案（`71e482e` 審過）之後
   ——auditor 已撤回該簽收（帳本 §14），本更正版的 commit message 引用「收案與推翻範圍」時
   一併引撤回**。audit-raw `a868948` 的 commit message（"six unshaped arms, one shaped cell
   that fired on cue"）措辭錯誤——sha 不動，由後續 commit 註記更正。
   （commit 時序：T-4 claim 至 16:18:45、可能續 T-6——**commit 前拉式重讀 claim，`claim=none` 才動**。）

## 7. Provenance —— 🔴 更正版（原版 identifier 指錯對象，整段重寫）

fabric builder＝**`/home/adam/Network-Traffic-Generator/testbed_topo.py`**（`ndtwin-lab:83`
指名執行）：sha256 前 16＝`ead4d84a862ccd94`（工作樹現行）、mtime 2026-07-08、NTG git
`057c1e5`＋工作樹 M（M 的 diff 僅 sys.path／CLI 註解／`config_file_path` 參數名——`bw=`
未被碰）⇒ 量測窗當時即此內容。shaping＝access＋leaf-mid `bw=1000`（htb）、spine
`bw=10000`（Mininet 靜默忽略）＝**七臂全程如此**。
原版寫的 `unshaped ca4de8ae／restored e2079a59`＝**kernel repo 副本** `testbed_topo.py` 的
sha256 前 16（patched／原始兩態，driver stdout 逐字可稽）——該副本**不參與 fabric**，記錄
僅作為「driver 實際做了什麼」的稽核線索（patch diff＝`raw/topo_patch.diff`；副本還原
byte-exact 由 git 可證：檔自 `7b7f520` 後無 commit、輪前輪後工作樹均＝HEAD）。
OVS **3.3.4**（`ovs-vsctl --version`，arm.meta 逐臂；🔴 **08-31 更正：原文寫 3.3.0，七臂
`arm.meta` 全部寫著 `3.3.4`，`dpkg` 亦為 `3.3.4-0ubuntu0.24.04.2`**）；kernel module
openvswitch（🔴 **08-31 更正：原文寫「modinfo 記錄」，實際七臂 `ovs_kmod=` 全空**——
`|| echo unknown` 的 fallback 對「成功但空輸出」不會觸發，所以缺值長得像有值）；
Linux 7.0.0-30-generic／Core Ultra 5 125U（`MACHINE-ENV`）；iperf3 3.16；1400 B payload；
gates（h1 loopback，htb 不參與）＝7311/21361/38258 Mbit（`raw/gates.tsv`）；fabric
`ndt up ovs`×2（🔴 兩次**同 config**，各 log 在 raw）；量測窗 claim `8/29 poster-reviewer`
13:38–14:1x，窗內零 commit。driver 全程 stdout＝`drive_ovs.log`（本目錄，待窗開後補進 audit-raw）。

[Co-developed with claude code -- Adam]

---

## 補報（2026-08-31，reviewer 線；原文一字未改）

🔴 **漏報事實**：`PREREG.md:55` 註冊「負載：`/proc/stat` 差分（busy fraction＋**softirq 獨立欄**…）」。
**busy fraction 有報**（`:123`，且僅一臂）；**softirq 那一欄從未回報**——而它**每臂都採了**。
2026-08-31 的回報義務清償盤點發現，同日補報。

### 回收的值（自 `audit-raw` 的 `raw/<arm>/arm.meta` 逐臂取出）

| 臂 | `softirq_ticks` |
|---|---|
| ovs_n1_a ／ ovs_n1_b | **5212 ／ 7447** |
| ovs_n4_a ／ ovs_n4_b | **10843 ／ 8587** |
| ovs_n16_a ／ ovs_n16_b | **5758 ／ 7309** |
| **n16_shaped（第七臂）** | 🔴 **`arm.meta` 完全沒有 load 區塊** |

`arm.meta` 內的自註逐字：`# kernel datapath cost lives here, not in any process`
——**OvS 的資料面成本不在任何行程裡，所以 per-process 的量測看不到它**，
這正是該欄被註冊的理由。

### 它支持什麼（獨立於 iperf3 的第二個儀器）

把 softirq 對本輪已報的 aggregate 並排：

| n | aggregate（已報） | softirq 均值 | **每 Mbit 的 ticks** |
|---|---|---|---|
| 1 | 540 Mbit | 6330 | **11.7** |
| 4 | 960 | 9715 | **10.1** |
| 16 | 720 | 6534 | **9.1** |

⇒ **softirq 隨「送達的量」走，不隨「流數」走**：n=4 是三格中 aggregate 最高的，
softirq 也最高；n=16 的 aggregate 回落，softirq 跟著回落。
每單位吞吐的成本在 **9.1–11.7** 之間，**沒有隨 n 上升**。

🔑 **這與 H-B 的機制敘述一致，且來自一個與 iperf3 正交的儀器**（核心 softirq 記帳）：
OvS 側「aggregate 撐在配置帽上、每流＝帽÷n」的圖像，在核心成本上也看得到——
**成本跟著位元組走，不跟著流走**。（bmv2 側無對應數字，本輪未採。）

### ⚠️ 三個必須隨數字引用的限制

1. **softirq ticks 是整機的**，不是每介面／每流的 ⇒ **不能歸屬到某一條流或某一個 bridge**。
2. **本輪沒有經過驗證的外來負載閘**（`raw/drive_ovs.log` 逐字：
   `no validated foreign-load gate this round -- PREREG §4.5`）
   ⇒ 其中含多少是外來負載**無法分離**；上表的「每 Mbit ticks」是**上界**不是成本估計。
3. **第七臂沒有 load 區塊** ⇒ 三格對照只有六臂，**n16_shaped 不入此表**。

⇒ **定位＝與 H-B 一致的旁證，不是獨立證明。** 依本檔紅線，不得用它回填 C1/C2。

---

## 補報二（2026-08-31）：儀器盤點撞出的兩個裝置事實

44 個 apparatus 缺口的填補作業帶出兩件與本輪已報內容牴觸的事，**我方自 `audit-raw`
與工作樹逐項複驗**（非轉述）。上面 §裝置那段的版本號與 modinfo 兩處已就地更正。

### ㈠ 🔴 反應式控制平面的暖機**沒有暖到被量測的路徑**

`drive_ovs.sh:50-52` 的 `warm_path()` 逐字：

    warm_path() {  # reactive control plane: warm h1<->h33 before any measurement
      sudo -n mnexec -a "$cp" ping -c 3 -W 2 10.0.0.33 …

而七臂 `arm.meta` 逐字寫著被量測的是 **`host_pair=h1->h65 (10.0.0.65)`**。

拓樸（`raw/testbed_topo.py.orig:65-90`，`HOST_NUM=128`，四分之一掛一台 leaf）：

| 主機 | leaf |
|---|---|
| h1 | **s1** |
| h33 | **s2** ← 暖機的終點 |
| h65 | **s3** ← 實際量測的終點 |

⇒ 暖機走 `h1→s1→(s5\|s6)→s2`；量測走 `h1→s1→(s5\|s6)→(s9\|s10)→(s7\|s8)→s3`。
**只有 h1 的接取鏈路與第一跳是共用的，路徑其餘部分從未被暖機。**

**成因**：`h33` 是 AMENDMENT-1 之前 `h1→h33` 設計的化石；同一支 driver 的開機輪詢
（`:45` `die "boot[…] h1=$h1p h33=$h33p"`）也還在等 h33。**改了量測對象，沒有改暖機對象。**

**後果與方向**：每臂的第一條流要自己付反應式控制器的裝規則延遲，而那正是 `warm_path`
存在的目的。偏誤方向＝**低估**起步階段的吞吐；穩態不受影響。本輪報的是各臂穩態
aggregate ⇒ **已報結論不變**，但 ramp 相關的任何敘述都不得引用本輪。

🔑 這是 [[injections-must-assert-their-own-success]] 的鏡像：**暖機動作成功了，
只是暖錯地方**——`ping` 回 0、`warm_*.txt` 有內容，每一個可讀的訊號都說它做完了。

### ㈡ 本輪跑的 `ndtwin_kernel` 與 bmv2 四輪**不是同一顆**

| 輪 | `kernel_sha256_start` |
|---|---|
| bmv2 ①②③＋single-switch | `a40e04ce`（逐臂） |
| **本輪（OvS）** | **`2e969618`**（七臂全部） |

⇒ 任何「`a40e04ce` 每臂皆已斷言」的敘述**涵蓋四輪，不涵蓋本輪**。本輪的 binary 身分
自己是完整的（七臂一致），**所以不影響本輪內部效度**；影響的是**跨輪並排**時能不能說
「同一顆 kernel」——不能。依 [[benchmark-must-name-the-binary-it-measured]]，
兩個平面並排時必須各自報自己的 sha。

