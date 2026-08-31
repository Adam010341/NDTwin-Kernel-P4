---
name: ndtwin-official-docs-site
description: 官方說明書 https://ndtwin.org/docs/ ——Adam 指定跑兄弟元件前要參照;NTG 啟動流程那頁的位置、三本手冊的結構;🔴 勘誤只剩一條(python 直譯器),port 那條 08-21 live 重驗已撤回
metadata: 
  node_type: memory
  type: reference
  originSessionId: 19a77e0e-d762-431b-a3fd-4128ec1fcd85
  modified: 2026-08-27T08:46:16.560Z
---

2026-08-15 串接輪 Adam 指定:「兄弟元件都列在這份說明書裡面,使用的時候記得參照」。

**站點結構**:三本手冊 installation-manual / user-manual / developer-manual,
元件頁 pattern `/docs/ndtwin-{manual}/ndtwin-tools/<slug>/`(installation 用單數 `ndtwin-tool`)。
slug:`webgui`、`networktrafficgeneratorntg`、`network-state-recoder`(注意拼字少個 r)、
`trafficvisualizer`、`simulation-platform`。另有 tutorials-and-demo-videos 底下
energysavingapp / trafficengineeringapp。

**NTG 啟動(Adam 明指這頁)**:
`https://ndtwin.org/docs/ndtwin-user-manual/ndtwin-tools/networktrafficgeneratorntg/`
Mininet 模式四步:① Ryu(`ryu-manager intelligent_router.py ryu.app.rest_topology
ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link`)② `sudo ./testbed_topo.py`
等 Ryu 印 **"all-destination paths installed"**(~1 分鐘)③ `sudo -E bin/ndtwin_kernel
--loglevel info` ④ NTG CLI 打 `flow --config <file>`。
⚠️ **NTG 不支援中斷實驗**——中斷=整個 NTG 關掉;實驗要等所有非無限 flow 自然結束。
kernel 沒起之前 NTG 卡 "Failed to get hosts, retrying" 是**預期中間態**(等第③步)。

**文件與本機不符(2026-08-15 實測,兩處都會讓字面照抄失敗)**:
1. **port**:文件 Ryu 聽 6633,但 NTG topo 的 switch 實際撥 **6653**(`ovs-vsctl
   get-controller` 實證)——照文件跑 switch 永遠連不上,Ryu 要 `--ofp-tcp-listen-port 6653`。
2. **直譯器**:文件 `sudo ./testbed_topo.py` 會用 /usr/bin/python3(無 nornir/loguru,
   ImportError)。本機正解:`sudo /home/adam/miniconda3/envs/ntg-env/bin/python
   testbed_topo.py`(ntg-env 有 nornir/loguru,腳本 sys.path.append 借系統 mininet)。

側證:文件 kernel 用 `sudo -E`(root)——解釋了 kernel `setupNFSForApp` 為何假設能 chown
(見矩陣文件發現 6 的 NFS 權限鏈)。我們的 stack.sh 是非 root 跑 kernel。

相關:[[ntg-bmv2-support-pending-feature]]、[[cross-repo-component-ecosystem]]

## 🔴 2026-08-21 live 重驗:第 1 條(port)是**錯的勘誤**,已撤回

**文件的逐字指令完全可用。** 三臂實測(128-host NTG `testbed_topo.py`,走
`ndtwin-lab ovs-topo-start`,Ryu 先起):

| Ryu 啟動方式 | Ryu listen | switch 撥到 | 結果 |
|---|---|---|---|
| `--ofp-tcp-listen-port 6633`(文件寫的) | **只有 6633** | `tcp:127.0.0.1:6633` | ✅ 10/10 connected |
| 不帶旗標 | **6653 和 6633 都開** | `tcp:127.0.0.1:6653` | ✅ 10/10 connected |
| **文件逐字**(含單數 `--observe-link`) | 只有 6633 | **6633** | ✅ 10 switches / **32 links**、`all-destination paths installed` |

機制:兩份 `testbed_topo.py` 都是 `RemoteController` **不帶 port**,
`mininet/node.py:1551-1565` 依序探測 **6653 → 6633**,連上先應答的那個。
帶旗標時 6653 沒人應、6633 有人應 ⇒ 就連 6633。**沒有壞。**
單數 `--observe-link` 被 argparse 前綴匹配接受,連結觀測真的有開(32 links 是證據)。

**同時推翻兩個來源**:
1. 本記憶原本寫的「照文件跑 switch 永遠連不上」——**撤回**。當初的觀察
   (`get-controller` 顯示 6653)應該是在**沒帶旗標**或 Ryu 還沒起來時取的。
2. 🔴 **kernel repo `tools/test_workflow/stack.sh:660-669` 的註解也是錯的**,
   它明寫「passing --ofp-tcp-listen-port 6633 to Ryu breaks it silently」。
   程式碼本身沒問題(它不帶旗標,也能通),**錯的是那段註解**。未修。

**真正的失敗模式是啟動順序**:Ryu 兩個埠都沒聽時,mininet fallback 6653
(`node.py:1564`)、switch 對著死埠撥,而且**任何 log 都不會提到 port**。
文件該補的是「Ryu 必須先聽好再起 Mininet」,不是改埠號。

✅ **08-27 已刪(`5c91ff7`)**——照它改會去「修」一份本來就對的文件。
🔑 **刪原始那條不夠,它已經擴散了**:整合矩陣的發現 11、以及 bmv2 草稿前言裡
「**跟這條一起送給 patty**」的待辦事項——後者是會真的把錯誤勘誤送出門的那一個。
**撤回一條主張時,要找的不是它被複製到哪,是誰打算照它行動。**
教訓:[[arithmetic-that-fits-is-not-the-mechanism]]、[[reproducible-is-not-mechanism]];
與 [[model-hypotheses-saturated]] 的 6633 例證同一件事(讀原始碼會系統性高估缺陷)。

**2026-08-17 複查(WebFetch 實抓該頁,非沿用記憶)**:兩處**都還是原樣**——
`--ofp-tcp-listen-port 6633` 與 `sudo ./testbed_topo.py` 原封不動。
(⚠️ 前者現在已知**不是錯誤**,見上節;只有後者要改。)
原因單純:勘誤稿(`doc/2026-08-16_delivery-package/docs-errata.md`)**還沒轉交給 patty**,
那是 Adam 的動作。第三步 `sudo -E bin/ndtwin_kernel --loglevel info`(等 Ryu 印
`all-destination paths installed.`,約一分鐘)照做即可,那步沒問題。

---

## ✅ 2026-08-27:勘誤三條全部裁定完畢(乾淨 VM 實測)

全文與證據 [[install-manual-clean-room-test]]。

| # | 內容 | 裁定 |
|---|---|---|
| 1 | 「Ryu 要聽 6653」 | 🔴 **轉交前必須刪掉**(08-21 三臂實測已推翻) |
| 2 | 「`sudo ./testbed_topo.py` 用錯直譯器」 | ✅ **仍有效,且它正確指名了 NTG 頁,不必改** |
| 3 | 「端點實際 41 條、文件列 29」 | ✅ **08-27 重數仍是 41**,跨 580 commit 沒變 |

🔑 **但第 2 條要補一句,否則維護者會去修錯的檔案 —— 有兩支同名的 `testbed_topo.py`:**

- **安裝手冊 §5 給的**(`assets/snippet/testbed_topo.py`,240 行):只 import
  mininet + os + threading ⇒ **系統 python3 跑得動**(實測 Python 3.12.3,全部 import 成功)。
- **NTG 自己的**(User Manual 的 NTG 頁用的,250 行):多一個
  `from network_traffic_generator import command_line` ⇒ **要 ntg-env**。

⇒ 勘誤講的是**後者**。**安裝手冊那支不受影響,不要一起改。**
