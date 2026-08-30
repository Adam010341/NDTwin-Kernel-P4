# FINDINGS——OvS 同梯對照（C3 對照平面半邊；PREREG＋AMENDMENT-1 本目錄）

**2026-08-30 13:44–14:1x 量測；6 無 shaping 臂＋1 shaped 陽性對照。** 執行 `8/29 poster-reviewer`。
raw＝`raw/`（**audit-raw `a868948`，本地、push 凍結中**）。driver 在 shaped 臂 160M 階被行程重啟殺掉——
**決定性讀值（45 clean／70/110 大髒）已在盤面上**，缺的只有無資訊的尾階與收尾摘要。

## 0. 一句話

**H-B（預註冊分支）：OvS 每流也降，但只降到「~0.96 Gbit 合計天花板 ÷ n」的均分線上——
aggregate 不塌（720–960 Mbit 全程撐住）；bmv2 的 aggregate 自己塌了 10×。
n=16 每流：OvS 45 vs bmv2 1–2＝22–45×。**

## 1. 每臂結果（validity 欄＝auditor 要求：這階的 clean 是量出來的、還是發送端沒送滿）

「valid」判準（逐階）：`agg_sent ≥ 0.95 × n × offered`。不滿足＝**發送端 backpressure 假象**
（veth 回壓把 iperf3 壓到 ~960 Mbit 合計，loss 讀 clean 但該階根本沒被施加）——
「儀器極限偽裝成乾淨」的**反向新形狀**，本輪首見，raw 的 `agg_sent` 欄全程可稽。

| 臂 | 名目 best_clean | **valid best_clean** | 無效階（offered≠sent） | 頂階確認 | 髒階證據（sent 滿載） |
|---|---|---|---|---|---|
| ovs_n1_a | 540 | **540** | 1215（sent 952） | 0.3391% ✅ | 810 @ 0.647%（sent 809.9 ✓） |
| ovs_n1_b | 540 | **540** | 1215（首讀假 clean→確認 0.6193% 掛） | 0.2681% ✅ | 810 髒（sent 滿） |
| ovs_n4_a | 810 ⚠️假 | **240** | 360/540/810（sent 皆 ~962＝殺到 240/流） | （240 行 3 reps 0.0893%） | — |
| ovs_n4_b | 810 ⚠️假 | **240** | 同上 | 同上 0 損 | — |
| ovs_n16_a | 45 | **45** | 無（70/110/160 sent 滿載） | 0.0187% ✅ | 70 @ 16.78%、110 @ 50.3% |
| ovs_n16_b | 45 | **45** | 無 | 0.1245% ✅ | 70 @ 17.79%；110/160＝NO_MEASUREMENT（iperf3 控制通道，與 ③ n=16 高階同形） |
| n16_shaped | （45） | **45** | 無 | ⚠️ 無最終確認輪（driver 被殺）；階內 3 reps 中位 0.0156% | 70 @ 18.97%、110 @ 47.2% |

**鏡像複製：三格兩臂全部同階（540/540、240/240、45/45）＝rung 級零階差。**
（照 ③ 紀律：這證明階穩定，不證明真值在階內何處。）

## 2. 歸因（雙讀值兌現）

- **零 ECMP 散佈**：n16_a 全 switch 計數器＝**s1/s6/s9/s7/s3 各 7.26 GB（rx=tx 逐台相等）**，
  其餘 switch 靜默 ⇒ 16 條 port 區分的流走**同一條 5-switch 路徑**——
  `flows/switch=flows/link=n` 在 OvS 側**由量測成立**（PREREG 已知差異 #2 消滅；
  置放構造與 ③ 同構，Ryu 的轉發等效 dst-based）。
- **n=1 的天花板是收端 socket**：RcvbufErrors 44,392／48,410（a/b），與髒階損失同量級
  ⇒ **540 這個數字是「單收端行程」的極限，不是 OvS datapath 的**（[[jitter-is-the-receiver-not-the-network]] 的再現）。
- **n=4/16 的損失在 fabric 內**：RcvbufErrors 僅 199–3,586，對髒階數百萬丟包＝滄海一粟
  ⇒ ~0.96 Gbit 送達天花板位於 OVS kernel datapath／veth 路徑（softirq），不是 socket。
- ⇒ **對照最乾淨的格＝n=16**（兩平面同為 fabric 限制、同構造、同梯）：**45 vs 1–2**。

## 3. 陽性對照裁定

預測（PREREG §2）：shaped（htb 1G）n=16 應 clean ≤45、70 髒。**實測 45 clean（3 reps
中位 0.0156%）、70 @ 18.97% 髒、110 @ 47.2% 髒＝發火位置逐階命中。**
⚠️ 誠實揭露：無 shaping 臂自帶 ~0.96 G 有機天花板，與 htb 1 G 帽在本工作點**不可分辨**
（70 階 agg_recv：shaped 954.77 vs unshaped 955.75）——對照證明了讀出鏈看得見 ~1G 級的帽，
**但無法分辨帽的來源**；分辨帽源不是本輪注冊問題，不影響 §1/§2 的結論。

## 4. 與 bmv2 ③ 對照（同梯、同置放構造、各自 as-configured 控制平面）

| n | bmv2 每流（a/b） | OvS 每流（a/b） | bmv2 aggregate | OvS aggregate |
|---|---|---|---|---|
| 1 | 160 / 240 | 540 / 540 ⚠️收端限 | 160–240 | 540 |
| 4 | 30 / 45 | 240 / 240 | 120–180 | 960 |
| 16 | 2 / 1 | 45 / 45 | **32–16（塌 ~10×）** | **720（撐住）** |

- OvS 每流 540→45＝6 階；**與「合計天花板均分」一致**（45×16=720 ≤ 960 < 70×16=1120）。
- bmv2 每流 160→2／240→1＝10–12 階；**aggregate 自身塌陷**＝超出任何均分模型的下降。
- n=16 每流差 **22–45×**；且 bmv2 n=16 實測（1–2）比自己單流的均分預測（160/16=10）還低 5–10×。

## 5. 建議落稿句（Adam 已裁「加」；作者 session 措辭，紅線如下）

素材句（可壓縮）：
> *An OvS control on the same ladder and placement (all $n$ flows on one path, shaping removed)
> declines only as aggregate-sharing predicts --- per-flow 540/240/45\,Mbit at $n{=}1/4/16$ with
> the aggregate holding at 0.72--0.96\,Gbit --- whereas bmv2's aggregate itself collapsed an
> order of magnitude; at $n{=}16$ the per-flow gap is 22--45$\times$.*

**紅線**：(a) n=1 的 540 若入文必掛「receiver-socket-limited」——或乾脆只用 n=4/16；
(b) 不得寫「matched working points」以外延伸（同梯＝真、同置放＝量測證實，就寫這兩件）；
(c) 兩平面各自 as-configured 控制平面（Ryu vs proxy）照舊揭露；(d) shaped/unshaped 不可
分辨那條若空間不夠可省（它不動結論），但 study 版要收；(e) smoke 級規模照實
（3 格×2 臂、單日）；(f) **本輪任何數字不回填 C1/C2**。

## 6. 偏差與限制（誠實清單）

1. 3 格非 5 格；每格 2 臂（smoke-grade）。
2. **無已驗證外來負載偵測器**（照 ③ 揭露）；且本輪的外來負載含**審查艦隊自己**
   （7 隻 agent 同窗串流；n16_a busy 0.8658 部分屬之）＋作者 session tectonic（13:38±，
   臂前、零重疊）。方向：外來負載**壓低** OvS 讀值 ⇒ 對「OvS 高於 bmv2」的結論是保守方向。
3. shaped 臂無最終確認輪（driver 被殺於無資訊尾階）；n16_b 有兩個 NO_MEASUREMENT 階。
4. 發送端 gate 用 loopback 註冊，**沒預見 veth 回壓**——被 §1 validity 欄事後補上；
   下一輪的 gate 應直接量「經 datapath 的可施加率」。
5. OvS/Ryu 為 as-configured（reactive 學習已 warm）；bmv2 側為 proxy dst-based——
   對照平面本來就不同平面，C3 框架如此。

## 7. Provenance

OVS 3.3.0（`ovs-vsctl --version`，arm.meta 逐臂）；kernel module openvswitch（modinfo 記錄）；
Linux 7.0.0-30-generic／Core Ultra 5 125U（`MACHINE-ENV`）；iperf3 3.16；1400 B payload；
topo builder `testbed_topo.py` unshaped sha `ca4de8ae`／restored `e2079a59`（patch diff＝
`raw/topo_patch.diff`）；gates（loopback n=1/4/16）＝7311/21361/38258 Mbit（`raw/gates.tsv`）；
fabric `ndt up ovs`×2（unshaped／shaped，各 log 在 raw）；量測窗 claim `8/29 poster-reviewer`
13:38–14:1x，窗內零 commit。

[Co-developed with claude code -- Adam]
