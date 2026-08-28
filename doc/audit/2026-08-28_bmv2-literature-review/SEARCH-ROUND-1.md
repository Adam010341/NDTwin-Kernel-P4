# 系統性檢索第一輪（2026-08-28 深夜）：三個宣稱全部存活

**目的**：把「這 14 篇裡沒有」往「可辯護的 related work」升級的第一步；優先跑 kill-shot——
若有人已做過 build 對照，讓角度死得便宜。**執行＝Adam 在本 session 直接指派**（poster 評估的一部分）。

## 1. 檢索動作（可重跑）

| # | 通道 | 查詢 | 結果 |
|---|---|---|---|
| 1 | Web | `bmv2 "disable-logging-macros" performance throughput` | 只命中官方 `performance.md`、README、issues #823/#920——**知識存在於專案文件、學術端零命中** |
| 2 | Web | `bmv2 … compiler optimization flags -O3 debug build comparison` | 同上，無論文 |
| 3 | Web | `arxiv bmv2 throughput performance study 2024 2025` | 回到我們已有的篇目＋**Fernando et al.（MDPI Network 2025）**（新） |
| 4 | Semantic Scholar API | Chen PADS '23 的 cited-by（6 篇） | 新候選＝**Waind & Jin SIGSIM-PADS '26**、P4Docker；其餘為 VT 系列自引/不量 bmv2 |

## 2. 三篇新候選的裁決（PDF 由 Adam 下載；已進 paper 目錄）

| 篇 | 變體 | build | 對三個宣稱的威脅 | 裁決 |
|---|---|---|---|---|
| **Waind & Jin, SIGSIM-PADS '26**（`3806789.3810263.pdf`，sha256 `13a2a868…`）：BMv2＋Tofino 動態 offload 混合測試床 | `simple_switch_grpc`（有載明） | **未載明**（版本、flags 皆無） | ①②③皆無：無 build 軸、無封包大小軸（吞吐 Mbps 本位；pps 只當攻擊速率軸用）、dumbbell 僅 2 流且無隔離流數掃描、機器 4C/8T 跑 10+ switch＝host 超載框架 | **存活**。且**強化 ①**：同組第 4 篇無 build 資訊；🔑 同組兩篇的每-switch RTT 差 1.7×（PADS '24 native 1.217 ms vs 本篇迴歸 729.4 µs/switch，不同機器、皆無 build）——**「不可比較」在同一實驗室內部成立** |
| **Fernando, Xiao, Spring, Che — MDPI Network 5(21), 2025**（`network-05-00021.pdf`，sha256 `9895afc1…`；preprint `preprints202504.2530.v1.pdf` 同文） | 未載明（僅「bmv2 [46]」） | **未載明** | ①②③皆無：單一封包大小（1500 B ping／iperf 預設）、無 build、Tier-2 混流無流數軸也無總和塌陷框架 | **存活**。且是**最佳展品**：結論方向與 Chen 組相反（**SDN+P4 > SDN+OvS**）——機制為 ONOS **reactive** 模式下 OvS 逢 ARP/LLDP 走 PACKET_IN 繞控制器、P4 臂不繞（§5.1 自述）＝**控制面政策對照，非 datapath 對照**；工作點 6.3 Kbps–96 Mbps（VMware 內、i7），距任一 datapath 天花板 3–6 個數量級 ⇒ corpus 內現有**兩篇同儕審查、排序相反**的 bmv2-vs-OVS 結論，雙方皆無 build 資訊 |
| **P4Docker — Silva et al., 2024**（`29948-…pdf`，sha256 `a054a172…`）：Docker＋GUI 教學/原型工具 | —（工具論文） | — | 無任何效能量測（與 Mininet 的效能比較明列 future work） | **存活**（零重疊） |

## 3. 檢索後的宣稱狀態

- **①**（build 12–18×、無人報告/對照）：**17 篇（14＋3）裡仍然 0 篇給 flags、0 篇對照**；質性敘述維持僅 ICNCC 一句。
- **②**（pps 天花板）：17 篇裡仍無 bmv2 封包大小掃描與 pps 恆定陳述。
- **③**（多流總和塌陷＋對照平面）：17 篇裡仍無等價量測。
- 🆕 **新論證素材兩件**：同組內部 1.7× 不可比較；同 corpus 反向排序（Fernando vs Chen）。

## 4. 還沒查的（誠實清單）

- TOMACS 2025 與 ICNCC 2023 的 cited-by（PADS '23 的查過）。
- Google Scholar 全文檢索（`"behavioral model" throughput` 類寬查詢）與 dblp 掃 EuroP4/SOSR/ANRW 近三年目錄。
- 非英文文獻；學位論文庫。
- `p4-dev` 郵件列表。

[Co-developed with claude code -- Adam]
