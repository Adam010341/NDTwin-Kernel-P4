# src_ip 整數位元組序覆核(2026-08-16)——甲類題「維持整數」的前提補全

> DeepSeek 於驗收審計抓到「src_ip 是 LE 重讀整數」,判官建議併入甲類 src_ip 題覆核
> (`doc/audit/2026-08-15_acceptance-judgments.md` 可行動輸出 #5)。Adam 表單核准本輪。
> 純源碼考證,零程式修改;兄弟 repo 只讀不改。

## 結論先講

**「維持整數」的裁決成立,但前提要升級**:維持的不是「整數」,而是
「**IPv4 網路序位元組重讀為 host-LE 整數**」這個**已被三個消費端雙向依賴的既成契約**。
kernel 內部慣例刻意、有註解、自洽;API 文件(`doc/2026-01-02_ndt_api.md` §flow)早已
完整記載位元組序與轉換方法;消費端各自補償且行為正確。**改動它是零功能增益的
跨 repo 協調工程**(至少 kernel+Web-GUI+TE 三處同步改),維持現狀是正解。

## 生產端(kernel 內部,全部網路序,刻意為之)

| 來源 | 證據 |
|---|---|
| sFlow 樣本解析 → `FlowKey.srcIP/dstIP` | `include/common_types/SFlowType.hpp:30` 註解明寫 `// in network order` |
| 拓撲 JSON 載入 → graph edge `srcIp` | `ipStringVecToUint32Vec` 用 `inet_aton`(=網路序 `s_addr`) |
| 內部渲染 | `utils::ipToString` 用 `inet_ntop` 吃網路序 → 點分字串正確 |
| 內部跨慣例邊界 | `FlowLinkUsageCollector.cpp:2602` 給 Classifier 的鍵**有做 `ntohl`**——兩套內部慣例在邊界正確轉換 |

## API 面(三種形式並存——本輪新地圖)

| 端點 | 形式 | 位置 |
|---|---|---|
| `get_detected_flow_data` | **裸網路序整數**(`16777226`=10.0.0.1) | `FlowLinkUsageCollector.cpp:2128` |
| `get_graph_data` edges(`src_ip`/`dst_ip`/`flow_set` 內 FlowKey) | **裸網路序整數** | `HttpSession.cpp:558`、`SFlowType.hpp:539` |
| `get_static_topology_json` | **點分字串**(`ipToString`) | `TopologyAndFlowMonitor.cpp:2703` |
| `get_path_switch_count` | **點分字串**(query param 進出) | `HttpSession.cpp:1605+` |

同一 JSON 內的不對稱:port 欄位是 host 序十進位(5201 直讀正確)、IP 欄位是網路序
整數——文件已載,消費端已知。

## 消費端(三個,三種姿態,全部行為正確)

1. **Web-GUI 讀側補償**:`src/utils/formatters.ts` 以**最低位元組在前**渲染
   (`ip&0xff . ip>>>8&0xff . …`)——硬編了對本契約的反解。改 kernel 吐法=GUI 立即
   顯示垃圾。
2. **TE 寫回側補償**:`Traffic-engineering-App.py:333`
   `str(ipaddress.IPv4Address(socket.htonl(flow_key[1])))`——把 LE 整數轉回點分字串
   再組 `ipv4_dst` 迴寫;內部只當不透明 dict 鍵。改 kernel 吐法=TE 迴寫錯地址。
3. **NSR 透傳**:全 repo 零 `src_ip` 解讀點,純歸檔,無依賴。

## 兩個附帶警語(記錄,不屬本題)

- **可攜性**:契約只在 LE host 上穩定。BE 上 kernel 吐的整數值會變,GUI 的反轉與
  TE 的 htonl(BE 上是恆等)會同步失效。本生態全 x86/ARM-LE,理論風險,一行記錄即可。
- **相鄰觀察(非 src_ip 範圍)**:TE 迴寫帶 `priority` 與 `idle_timeout`;P4 proxy 的
  `route_flow` 兩者**靜默忽略**(unsupported_match_fields 只驗 match 欄位)——TE 在
  P4 模式下的遷移規則是**永久的**,不像 OVS 會 idle 老化。與 OVS 路由「只會加」
  (replace-vs-add 形狀第 7 例)同族;記錄待裁,未修。

[Co-developed with claude code -- Adam]
