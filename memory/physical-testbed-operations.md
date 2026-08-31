---
name: physical-testbed-operations
description: 實體 testbed（Brocade/HPE 交換機、智慧排插 PDU、硬體 P4 switch）怎麼運作與怎麼別弄壞——含我方自律規則與待問學姐清單
metadata: 
  node_type: memory
  type: reference
  originSessionId: 103a1748-0691-49d5-b92f-8ab519a66ee0
  modified: 2026-08-31T03:43:20.416Z
---

# 實體 testbed 操作（正本＝學姐 HackMD，08-30 讀過）

**正本**：`https://hackmd.io/@EnLGjDLPTFikScTj_L3kWw/BylUS3VLye`（憑證都在那，**記憶不留密碼值**）。以下標「文件記載」vs「我實測」。

## 這座 testbed 其實是「兩座」

| | 舊 testbed | 新 testbed |
|---|---|---|
| 交換機 | **Brocade ICX7250 ofswitch1–11**＝`10.10.10.3/.4/.9–.15/.100`＋ICX6610 `.26/.27` | **HPE hpeswitch1–10**＝`10.10.10.16–.25`＋ICX6610_2 |
| 主機 | server1~4、cc（`.2`）、gw | server5~8、cc2（`.250`）、gw2 |
| 智慧排插 | `172.25.197.121` | `172.25.197.120` |
| 另有 | **NDTwin collector `10.10.10.30`**（帳號 alen；文件把它掛舊排插，但我從 gw2 ping 得到＝⚠️ 待釐清） | **硬體 P4 switch `10.10.10.28`（root/onl，ONL）** |

✅ **我的 ARP 掃描與文件對上了**：gw2 側 `.16–.25` 十台 REACHABLE（MAC 30:3f:bb）＝HPE 交換機群；gw 側 `.3–.15/.100`（60:9c:9f）＝Brocade 群。⇒ **實體交換機就掛在 server 的同一條 LAN 上**（VM/容器要 NAT 隔離的硬理由）。

## 🔑 「智慧排插」是**電源**不是主機（08-30 Adam 問，這裡講清楚）

**排插＝PDU（可用網路控制的電源插座排），兩台：`172.25.197.120`（新）／`.121`（舊），各 24 槽。**
**一槽＝一條電源線**，所有東西（交換機、server、gateway、collector、P4 switch）的電都插在上面 ⇒
表格裡的「slot 對照」是**插座編號↔設備**，不是主機清單。**它不是七台 host、也不是 server。**

**非 serverN 的那幾台才是主機**（是機器，但角色不同，不是拿來跑實驗的算力）：
`Proxy 172.25.197.102`（VPN 入口）／`Gateway .103`／`Gateway2 .50`／
`controller&collector 10.10.10.2`（Ryu＋sFlow）／`controller&collector2 10.10.10.250`／`NDTwin collector 10.10.10.30`。
**硬體 P4 switch `10.10.10.28` 全實驗室只有一台**（新排插槽 15–16）⇒ **獨佔資源，借＝擋住所有人**。

## 危險動作（我方自律規則，未經 Adam＋學姐同意不做）

1. 🔴 **智慧排插 API 一律不碰**（`curl` 打 `/api/outlet/relay` off/on，兩座排插各 24 槽、slot↔機器對照在文件裡）。理由：**斷電是對別人機器的破壞性動作**，而我們自己有記憶 [[power-on-reports-success-without-acting]]——**開機回報成功卻沒真的開**（繞法要關機後等 15 秒）⇒ **關掉可能開不回來**，就得有人到機房。連 `GET relay` 查狀態也先不打（同一組憑證、同一個面板）。
2. 🔴 **不進交換機改設定**。Brocade 要 legacy 旗標（`-oKexAlgorithms=+diffie-hellman-group1-sha1 -oCiphers=+aes128-cbc -oHostKeyAlgorithms=+ssh-rsa`；**Linux 主機不要加**），文件裡有 `no sflow enable`→`sflow enable` 這種 config-mode 操作——**共用設備上一條指令會打斷別人正在跑的量測**。Juniper（`192.168.100.4/.5`）同理，且文件裡有 `request system power-off at now`。
3. 🔴 **server 上不准碰實體網卡**：不把 `enp*` 加進 OVS bridge、不 `ifconfig down`（[[ifconfig-down-breaks-whole-bmv2-switch]] 的實體版＝機器直接離線，只能靠排插或人到現場）。只動 Mininet 自建的 veth/`s*-eth*`。
4. ⚠️ **`mn -c` 只在確認整台是我們的時候跑**（會清掉該機所有 mininet/OVS 殘留與 controller 行程）。
5. 🔴 **server1~3 的 15 天 iperf3＋server1 的 uvicorn 不要動**——對照文件的操作步驟，那正是「產生流量」與「traffic generation server（`uvicorn server:app --port 8000`）」，**是別人正在跑的完整實驗**。

## 文件裡對我們有用的事實

- **操作鏈**：VPN → Proxy(`.102`) → Gateway → 內網；文件用兩段跳，我們的 `~/.ssh/config` ProxyJump 等價且更省事。
- **Ryu 起法**：`source ~/Desktop/ryu-venv/bin/activate` → `ryu-manager … --ofp-tcp-listen-port 6633 --observe-link`（在 cc/cc2 上）；NDTwin collector 跑 `sudo bin/ndt_main`。
- **port forward 看 NDTwin API**：`ssh -g -L 8000:10.10.10.2:8000 gateway@…`（⚠️ `-g` 會讓同網段任何人都連得到那個 port）。
- **文件自己的舊殘留**：FileZilla 那行的 `172.25.166.137` 與表格對不起來，別照抄。
- 🔑 **文件的紅字警告很可能＝我們獨立量到的現象**（⚠️ **這是推論、未驗證**——我沒有問過寫那句話的人，也沒有在他們的組態下重現；它也可能講的是別的機制，例如 NIC/driver 或 mirroring）：「Collector 跟 Receiver 不能是同一台機器（雖然 link bandwidth 沒超過，Receiver 會收不到）」——這正是 [[jitter-is-the-receiver-not-the-network]]：瓶頸在**收端 socket**（`RcvbufErrors` 406k），不是網路。**他們的運維規則有了機制解釋**，且反過來支持我們的結論。

## 對平行開發計畫的衝擊（重要）

**同一台 server 有兩個身分**：①我們要用的「跑 Mininet/OVS 的 Linux 機器」；②實體 testbed 的**流量端點**（接在真交換機上、別人實驗的一部分）。⇒ 「這台沒人登入」不足以判定可用，**還要問這台在實體拓撲裡有沒有角色**。我們的 `rlab` claim 只協調自己人；**實體 testbed 的預約是實驗室層級（學姐說：Google Calendar 登記）**，兩層都要走。

## 待問學姐（🏁 08-30 傍晚 Adam 親裁後**從六題收斂成兩題**）

1. **排插**：⚠️ **問法要換**——不是「我們能不能用」（我們不主動斷任何人的電），而是 **「server8 被我們玩到沒反應時，誰能重開機？我們可不可以？」**。理由：Mininet/OVS 弄死 kernel 是真實失效模式，而**復原手段（PDU、實體按鈕）全在我們構不到的地方**；順便問有沒有「關掉開不回來」的前例（[[power-on-reports-success-without-acting]]）。
2. **硬體 P4 switch `10.10.10.28`（ONL）**：現在有人用嗎、能不能借？🔑 **全實驗室只有這一台** ⇒ **獨佔資源，借＝擋住所有人**，要借得講清楚時段。（我們整份報告都在 bmv2 軟體交換機上，實體 P4 target 是另一個等級的實驗。）

🔴 **08-31 記——學姐答覆：「遠端機器先不要用。」** ⇒ **server8／7 長借這題已經有答案了，答案是「現在不行」**；同日「Calendar 有登記就好」的內部裁決**被本人否決**（見 [[remote-testbed-parallel-dev]] 檔頭）。上面兩題仍然值得問，但**要等她主動解除停用之後再問，不要現在追**。

**已撤／已答（不要重開）**：**server1~4 的 iperf3＝撤問**（我們用不到）；`10.10.10.30`＝Adam 上班口頭問；**Calendar 格式＝名字／使用時間／使用機器**。
