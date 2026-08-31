---
name: agent-can-do-live-tests-except-start-mininet
description: Agent 免密碼就能跑完整輪：打流量、斷鏈路、開關電源、起停 proxy/kernel，**連起 fabric 也可以**（`ndtwin-lab` v2／`ndt up`）。檔名的 except 早已過時，留著護 wikilink
metadata:
  node_type: memory
  type: reference
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-19T04:21:52.354Z
---

2026-08-12：我跟 Adam 說「讓 agent 把整個 stack 開起來不可行」，**他反問「agent 不是可以
直接在 mininet 打流量嗎」，他是對的**——我整場都在用 `mnexec` 打流量卻沒把界線想清楚。
實際查 `sudo -n -l` 之後的準確答案：

## 免密碼就能做（`sudo -n`）

| 能力 | 指令 |
|---|---|
| **對任何 host 打流量** | `sudo -n mnexec -a <host-pid> ping/iperf/tcpdump` |
| **斷／復原單一鏈路** | `sudo -n tc qdisc add\|del\|show dev s[0-9]*-eth[0-9]* root netem *` |
| **開關 switch 電源** | `sudo -n /usr/local/sbin/ndtwin-p4-power off\|on <name>` |
| **OVS 全套** | `sudo -n ovs-vsctl …` ← **只有 OVS 那輪用得到，bmv2 不是 OVS bridge** |
| **介面 up/down** | `sudo -n ifconfig …` ← **⚠️ 在 bmv2 上不能拿來斷鏈路，見下** |

> ⚠️ **這張表是「能不能做」，不是「該不該做」。** 抄進任何 prompt 或交接文件時，
> 至少要跟著抄兩條限制，否則等於在教人踩坑：
>
> 1. **`ifconfig down` 在 bmv2 上會讓整台 switch 停止轉送**，不是斷一條鏈路。
>    斷單一鏈路一律用 `tc netem loss 100%`，**兩端都要下**。
>    見 [[ifconfig-down-breaks-whole-bmv2-switch]]（並排實測：`ifconfig` 那組
>    5 次 link-down 有 3 次是假的、38% 遺失永不恢復、failover 無從觀察）。
> 2. **`ovs-vsctl` 跟 bmv2 那輪無關。** 2026-08-12 我寫交接文件時整段搬過去，
>    結果它就排在 P4 開場指令下面，Adam 當場問「它現在要測的不是 bmv2 嗎」。

不需要 root 的：建置、全部測試、`stack.sh up/wait/down`（proxy + kernel）、所有 API 查詢。

host pid 這樣拿：`ps -eo pid,args | awk '$NF=="mininet:h1"{print $1}'`

## 唯一做不到的

```
sudo python3 p4_proxy/mininet/p4_testbed_topo.py   →  sudo: a password is required
```

而且那個腳本結尾是 `CLI(net)`（**`p4_testbed_topo.py:384`**，2026-08-14 起；`b9a5bea` 在它下面
加了 teardown reap，行號從 304 推移過來），**沒有非互動參數**，會佔住一個
終端機；用 `< /dev/null` 餵它，CLI 會 EOF 然後整個 Mininet 收掉。

**所以：Adam 開一次 Mininet 並留著那個終端機，之後整輪 agent 自己跑得完。**
2026-08-12 就是這樣——他說「p4 mininet 我開好了」，§479 步驟 6 從頭到尾我一個人做完。

**設計限制**：那一輪不能需要重啟 Mininet，所以 **P4 和 OVS 必須分兩輪**，中間要人切換。

**教訓**：問「agent 能不能做 X」之前先 `sudo -n -l`，不要憑「這需要 root」就下結論。
sudoers 裡已經為此開過的洞比我記得的多。

相關：[[check-env-state-dont-ask]]、[[live-runs-find-what-tests-cannot]]、
[[p4-orphan-switches-and-manifest-lifetime]]。

**2026-08-15 後補(收官前更新):例外已消失。** `ndtwin-lab` 已由 Adam 安裝
(`/usr/local/sbin/ndtwin-lab` + `/etc/sudoers.d/ndtwin-lab`),**完整生命週期當場實測**:
`topo-start`(10 bmv2+14 mininet 起)→`topo-out`(讀到 NTG 畫面)→`topo-stop`
(Ctrl-C 乾淨收、manifest 清)。**agent 現在可全自主**:起 fabric、對 NTG CLI 打字
(`topo-cmd`)、管 energy/sim(`energy-start`/`sim-start`,各自 tmux session 可讀可收)、
掃孤兒(`cleanup`)。全部 `sudo -n /usr/local/sbin/ndtwin-lab <動詞>`;用法與安全形狀在
repo 的 `tools/test_workflow/ndtwin-lab` 檔頭。標題的「except」已成歷史,保留檔名護 wikilink。

**2026-08-17 更新:裝的已經是 v2,不是 v1。** 實證=`sudo -n /usr/local/sbin/ndtwin-lab`
的 usage 行已含 `ovs-topo-start`(state §5-B「裝的還是 v1、v2 要 Adam 再灌一次」已過時)。
所以 **OVS 拓撲我也能自己起**——`ovs-topo-start`,不必再請 Adam `sudo` 跑 topo。
完整動詞:`topo-start|ovs-topo-start|topo-cmd <text>|topo-out [n]|topo-stop|cleanup|
energy-start|energy-stop|energy-out|sim-start|sim-stop|sim-out|status`。
⚠️ repo 裡的 `tools/test_workflow/ndtwin-lab` **仍未 commit**(等 Adam 過目自己 commit)。

**2026-08-18：完整矩陣首次全自主跑完。** OVS(128 host)與 P4 各兩輪（NTG 開／關），
起→測→收→對帳到零，全程零人工。所以「except」確實已成歷史，這次是端到端證明而非單點驗證。

🔴 **新踩到的操作陷阱：`ndtwin-lab cleanup` 會殺掉呼叫它的那個 shell。** 它內部跑 `mn -c`，
而 `mn -c` 殺得很廣。今天咬了我兩次（指令 exit 1、後面所有對帳都沒跑到）。
**一律讓 `cleanup` 單獨一行跑，對帳放下一個指令。**

`stack.sh up ovs` 會停在互動提示（`Press Enter once Mininet is up`），而且它的守衛會拒絕
「Mininet 已經活著時啟動 Ryu」（那是 `/stats/flow` wedge 的觸發條件），所以順序是被強制的：
先起 stack.sh → 等提示 → 起拓撲 → 再回答。可用 FIFO 驅動，範例在
`doc/audit/2026-08-18_live-full-stack-round/`（`up_ovs.sh` / `up_p4.sh` 的模式）。

⚠️ `tools/test_workflow/ndtwin-lab` **到 2026-08-18 仍未 commit**。

## 2026-08-19（phase-2 兩個執行者實測）：拆機順序與 FIFO 兩個新陷阱

🔴 **`cleanup` 不會停掉 topo 的 tmux session。** 殘留的 session 讓
`ovs-topo-4host` / `topo-start` **拒絕啟動**，而 `topo-out` 還在印**上一輪**的 pane——
所以驅動腳本會把屍體讀成活的然後在死 fabric 上繼續跑。
**正確順序**：`stack.sh down` → `ndtwin-lab topo-stop` → `ndtwin-lab cleanup`。
**`ndtwin-lab status` 才是誠實的存活檢查，不是 `topo-out`。**

🔴 **`read -p` 的提示在 stdin 是 FIFO 時根本不會送出**，所以等提示的驅動腳本一定逾時；
逾時後 FIFO 關閉，`stack.sh` 就**繼續前進、在空 fabric 上啟動 proxy**——
實測 `:8081` 開了並且正常服務，但底下**零台 bmv2**（與 stack.sh 自己的註解矛盾）。
用 FIFO 驅動時**不能等提示字串**，要等別的訊號（log 行、port、行程數）。

⚠️ **bmv2 行程會活過 `mn -c`** 變成孤兒佔住 gRPC port。帶起來前先
`pgrep -cf '[s]imple_switch_grpc'`（注意 bracket，見
[[process-liveness-checks-lie-in-two-ways]]）。

**哪顆 bmv2 在跑會改變所有數字**：`p4_proxy/mininet/bmv2_binary_override` 選用
`/usr/local/bmv2-fast`（`-O3`）時實測 ~47 kpps / 726 Mbps TCP，
stock（`-O0`＋全 logging）只有 ~40 Mbps。**量測型實驗必須記錄用的是哪顆**，
否則「速率估計錯了」的結論可能只是丟包的假象（見 [[bmv2-scale-ceiling-and-sflow-sample-math]]）。

## 2026-08-19:`ndtwin-lab topo-start` 跑的**不是** `p4_testbed_topo.py`

🔴 **`/usr/local/sbin/ndtwin-lab:27` 寫著 `BRIDGE=$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py`。**
而 `ntg_bmv2_topo.py` **import 了 `p4_testbed_topo` 的 `MultiSwitchTopo`**,所以改後者的
拓撲結構會生效,**但它自己的 ARP / host 清單不會**。這個組合會讓「改對了」和「沒改到」
看起來一模一樣——今天為此浪費一整輪。詳見 [[p4-128-hosts-four-hardcoded-lists]]。
**改任何拓撲行為之前先確認哪一支在跑。**

**`stack.sh up ovs` 的正確驅動方式(今天實測跑通)**:它會先起 Ryu,然後印
「Start it in a separate terminal」並**等 150 秒**讓拓撲出現(不是等 Enter)。
所以順序是:背景起 `stack.sh up ovs` → 輪詢 `:8080` 活了 → `ndtwin-lab ovs-topo-start`
→ 它自己會收斂。範例腳本邏輯已驗證。逾時後它**不會失敗,會繼續起 kernel**,
並印「the kernel pulls once and never retries」——那行出現就代表圖是不完整的,要重來。

**`ndtwin-lab` 已 commit(`b6b75fa`)**,前面幾條「仍未 commit」的註記已過時。

**2026-08-20 端到端確認（`ndt` 層）。** 這一晚**完全無人介入**跑完兩輪冷啟量測：
`ndt down` → `ndt up p4 128` → 量 → 再一輪 → `ndt up ovs` → 量 → `ndt down`。
`ndt up` 內部走 `sudo -n "$LAB" topo-start`（`tools/test_workflow/ndt:449`），
所以**「起 Mininet 要人」這條限制在 `ndt` 這層也確認消失了**，不只是 `ndtwin-lab` 那層。
連帶推翻的舊設計限制：**「P4 和 OVS 必須分兩輪、中間要人切換」不再成立**——
我在同一個 session 內從 P4 切到 OVS 再切回來，沒有人碰過鍵盤。

⚠️ 但多了一條**新的**協調限制取代它：實驗室是共用的，`.test_run/pids/` 沒有 owner 欄位，
所以跨 session 要先 `ndt claim`（見 [[ndt-one-command-lab-lifecycle]]）。
**限制從「需要人」變成「需要協調」。**

## 08-30 兩個構不到的地方（都花了時間才發現）

1. **`sudo -n ovs-ofctl` 要密碼**（`ovs-vsctl` 免密碼，`ovs-ofctl` 不是）。
   ⇒ 想讀 OVS 流表只能走 **Ryu REST `/stats/flow/<dpid>`**。
   🔴 我一度把被擋下的輸出讀成「flow count: 0」，而且印的 `rc=0` 是 pipeline 裡 `head` 的
   —— 差一點寫成「OVS 表是空的」（實際 130 條）。**被擋的指令和真的零，長得一模一樣。**
2. **Energy-Saving-App 的 log 只存在 root tmux buffer，session 一關就沒了**——磁碟上沒有。
   唯一讀法＝**趁它活著**跑 `sudo -n /usr/local/sbin/ndtwin-lab energy-out`。
   25_apps_energy.sh 會自己 start/stop，所以要另外手動起一份、sleep ~75 s、再 energy-out。
   這就是那支腳本檔頭說「要 app 自己的輸出，但被 session 可見性問題擋住」的那件事——**繞得過**。
