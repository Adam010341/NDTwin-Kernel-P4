---
name: p4-128-hosts-four-hardcoded-lists
description: "「128 hosts in BMv2 might be too heavy」是錯的猜測——bmv2 撐得住,擋路的是四份寫死 4 台的清單散在三個檔;而且 ndtwin-lab 跑的是 ntg_bmv2_topo.py 不是 p4_testbed_topo.py"
metadata: 
  node_type: memory
  type: project
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-28T06:06:14.189Z
---

2026-08-19 實測。P4 從沒在 128 台 host 上測過,記錄的理由是 `p4_proxy/mininet/p4_testbed_topo.py`
裡那句註解 **`# Add 4 hosts for testing (128 hosts in BMv2 might be too heavy)`**。
**那是猜測,而且是錯的。** 它擋了這個實驗好幾個月。

## bmv2 完全撐得住(實測)

10/10 switches up、**16256 條 all-pairs 路徑 11 秒收斂**、每台交換機裝 **128 筆**規則
(`ipv4_lpm` 表容量 1024,遠不到上限)、記憶體剩 7 GB、拓撲建置 22 秒。
孿生的模型也正確:10 switches / 128 hosts / 288 edges。

## 真正擋路的:四份寫死 4 台的清單,在三個檔

| # | 位置 | 症狀 |
|---|---|---|
| 1 | `p4_testbed_topo.py` host 接線(四行 `addLink` 寫死) | 只建 4 台 |
| 2 | `p4_testbed_topo.py` 靜態 ARP 迴圈 `range(1, 5)` | — |
| 3 | `proxy_agent/main.py` 四行 `add_host` | proxy 只認識 4 台,**而且 128 佈局下位置是錯的**(h2 在 s1 port 4,不是 s2 port 3) |
| 4 | **`ntg_bmv2_topo.py` 的 ARP 迴圈 `range(1, 5)`** | **這份才是實際會跑的** |

🔴 **第 4 份是這次最貴的一課:`sudo -n ndtwin-lab topo-start` 跑的是
`p4_proxy/mininet/ntg_bmv2_topo.py`,不是 `p4_testbed_topo.py`。**
(`ndtwin-lab:27` 的 `BRIDGE=$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py`)
而 `ntg_bmv2_topo.py` **import 前者的 `MultiSwitchTopo`**,所以拓撲會照前者的改動建出來——
**看起來像改對了**,但 ARP 用的是它自己那份。我改完前三份、拓撲正確建出 128 台、
路徑全算對、規則全裝上,**然後 100% 遺失**,因為發送端學不到目的 MAC。
**症狀與資料面壞掉完全無法區分。**

## ⚠️ 2026-08-21 部分被取代:fabric 的接線現在讀 JSON

`p4_testbed_topo.py` 的 **16 條字面 `addLink` 已經換成讀拓樸模型**
(`p4_proxy/mininet/topo_from_json.py`,commit `c8d73a5`)。所以下表的第 1 項不再成立,
第 4 項(`ntg_bmv2_topo.py` 的 ARP 迴圈)仍然是 `_host_count_override()` 那條路。

🔑 **切換前先證明等價再切**:`tools/test_workflow/test_topo_from_json.py` 把衍生出來的
switch/link/host 逐項對比字面清單,三份模型全部相同才動手。**字面清單是 known-good output**
—— 它建過這個專案量測過的每一個 fabric,差一個 port 就不是重構而是換了拓樸。
見 [[verify-against-known-good-output]]。

### 🔴 2026-08-28 更正框架:**這個改動不是「實驗室原本的設計被改掉」**

它一度被當成「架構漂移」的已知實例拿去當正控制。查證後不成立:

```
git ls-tree -r 28b8b13 → 182 個檔案、0 個 .py、頂層沒有 p4_proxy/ tools/ tests/
git cat-file -e 28b8b13:p4_proxy/mininet/p4_testbed_topo.py  → 不存在
git cat-file -e 28b8b13:p4_proxy/mininet/topo_from_json.py   → 不存在
```

⇒ **整棵 `p4_proxy/` 在 baseline 裡不存在。** 這兩個檔都是我們寫的,
所以「寫死清單 → 讀 JSON」動的是**我們自己新增的程式碼在自己內部演進**,
按稽核分類屬「新增能力」,不是改掉別人的設計。

🔑 **「切換前先證明逐項等價」那條仍然成立,但理由換了**:
不是「不要改掉實驗室的設計」,而是「**我們自己的兩個版本要對得起來**」。
[[verify-against-known-good-output]] 的論證(字面清單是 known-good output)不受影響。

📌 這件事本身對 Adam 的疑慮是個答案:**被拿來擔心架構漂移的兩個例子裡,
有一個一查之下根本不是漂移。** 見 [[baseline-drift-audit-2026-08-28]]。

**仍然成立的**:host 數的唯一來源是 `host_count_override`;`ndtwin-lab topo-start` 跑的是
`ntg_bmv2_topo.py`;ARP 要分塊下(每 32 筆)。

## 修法(已 commit `cc249c8`)

四份都改讀同一個 `p4_proxy/mininet/host_count_override` 檔,形狀抄隔壁的
`bmv2_binary_override`(理由相同:lab wrapper 用固定 root 環境起拓撲,環境變數傳不進去,
檔案是唯一通道)。**預設 4,行為與改動前逐條相同**——推之前實測驗過預設路徑
(12 條路徑 / 4 秒收斂 / 40 edges / 每台 3 筆 ARP / h1→h2,3,4 全 0% 遺失)。

⚠️ **ARP 要分塊下,不能一次下完也不能逐對下。** 127 筆一次是 ~4.4 kB,**Mininet 的
`cmd()` 會截斷**——實測 h1 只拿到 h2..h112 就停了,而部分 ARP 表的失敗形狀跟資料面壞掉一樣。
逐對下是 16256 次 `cmd()` round-trip,要好幾分鐘。**現在是每 32 筆一塊。**

## 量到的結果推翻了一個已發表的結論

見 repo `doc/audit/2026-08_session-handoff-log.md` 的 §5-I 節(原 `ndtwin-state-2026-08-11`
1350-1438 行,2026-08-21 移出記憶)。摘要:08-17 那輪把三項排成
「缺陷 ≫ 拓撲 3.2× ≫ 資料面 1.13×」並**刻意跳過第四格**說「只驗交互作用」。
**交互作用比兩個主效應都大**:4→128 台,OVS 慢 3.29×、P4 只慢 1.21×;
128 台時兩者差 **3.12× 且零重疊**(P4 最慢 20.8 s、OVS 最快 47.0 s)。
**「資料面是三項裡最小的」只在 4 台上成立。** 機制未查明,不要猜。

**教訓**:一句沒驗證過的註解可以擋住一個實驗好幾個月,而且它會被後續文件當成事實引用。
相關:[[existence-is-not-wiring]]、[[agent-can-do-live-tests-except-start-mininet]]。
