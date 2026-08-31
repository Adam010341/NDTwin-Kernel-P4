---
name: speedups-pass-the-wrong-test
description: "一個 commit 的兩個加速宣稱全壞、驗證卻全綠:索引比它取代的掃描慢 1.69×(斷言了沒量的 O(1)),縮短的 settle 讓 twin 看不見 128 台 host(量了連通性,而壞掉的是模型保真度)"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 50445b3c-51cd-4c3b-9364-d120dd6a72ff
  modified: 2026-08-22T03:56:40.763Z
---

2026-08-21,`957a646`「Cut OVS bring-up from 73s to 25s: index the host lookup, and put a
number on the settle」。**兩個宣稱都壞了**,而它通過了我為它寫的驗證,還產生四個別的
session 的善後 commit(`4810e8f` `6c2b3fd` `06546e0` `5030b9a`)。

## 兩個實例,同一個形狀

**一、斷言了一個從沒量過的性質。** 我把 `find_host_by_ip` 加上 cache,token 寫成
`(id(net), net.number_of_nodes(), net.number_of_edges())`,並在註解裡寫
「node and edge counts are O(1) in networkx」。**那句話我沒查過。** networkx 的
`number_of_edges()` 是 `size()`,對每個節點的度數求和 ⇒ O(V),而且**每次查詢都算一次**。
於是那個「索引」**比它取代的線性掃描慢 1.69×**。修正 = token 拿掉 edge 數(`4810e8f`)。

**二、量了,但量錯軸。** 同一個 commit 把 Ryu 的 settle 從 60 s 降到 10 s,
驗證是「128-host fabric 起來後 h1→h64、h64→h128、h128→h1 三條全通」——**3/3 通過,
而且那個驗證到今天重跑還是通過的**。因為**資料面從頭到尾都是好的**。壞掉的是別的東西:

| settle | Ryu 有 ipv4 的 host | kernel 的圖 |
|---|---|---|
| 60(舊預設) | 128/128 | 288 up / 0 down |
| 10(我改的) | **0/128** | 32 up / **256 down** |

> 08-22 解案:機制由介入實驗釘死([[punt-window-host-learning]],`e5e4980`)——學習窗=
> 規則安裝前的 punt 窗;修法 patch(等事件、上限 90s)已裁由 mainDev v2 apply(P0-1)。

機制(介入實驗,只換這一個變數):Ryu 只從 packet-in 學 host 的 IPv4。testbed 建完 host
會平行 ping 128 台;規則裝在 burst **之前**,ICMP 就在資料面被轉走、永不上送 ⇒ Ryu 學不到
⇒ kernel 在「沒有 IPv4 就跳過」那道門丟掉全部 128 台 ⇒ 256 條 host 邊維持出廠的 down。
**數位分身對 288 條線裡的 256 條是錯的,而網路完全正常。**

## Why

加速改動的驗證天生偏向「還會動嗎」,而那正是加速**最不可能**弄壞的東西。
真正在風險上的是**那個舊值在保護的東西**——而舊值往往沒有記錄理由(這裡的 60 s 就沒有),
所以「我看不出它在保護什麼」會被當成「它沒在保護什麼」。**看不出來不是證據。**

第一個實例更基本:**沒量的東西不要寫成事實**,尤其是寫在論證這個改動正確的註解裡。

## How to apply

1. **動手縮短／移除任何等待或加上任何 cache 之前,先寫下「它在保護什麼」。** 寫不出來就
   去量,不要去猜。舊值沒有記錄理由 ⇒ 風險更高不是更低。
2. **驗證要涵蓋宣稱以外的那一軸。** 加速就量「快了嗎」**加上**「輸出還一樣嗎」——
   對帳完整輸出而不是抽一條斷言(見 [[verify-against-known-good-output]],
   那條記的是壓縮靜默打壞 reader,同一族)。這裡完整輸出唾手可得:`ndt status` 的
   `288 total, 0 down` 就是已知正確的輸出,改前改後各跑一次就抓到了。
3. **複雜度是可量的,不要斷言。** `number_of_edges()` 一個 offline 微基準就露餡。
   「我以為它是 O(1)」和「我量過它是 O(1)」在註解裡長得一模一樣,讀的人分不出來。
4. **加速的數字要標它量在哪個 binary／哪個 commit**——見
   [[benchmark-must-name-the-binary-it-measured]]。這裡兩個宣稱的數字都還在,
   只是量的東西不是宣稱的東西。

相關:[[arithmetic-that-fits-is-not-the-mechanism]](算式吻合不等於機制)、
[[live-runs-find-what-tests-cannot]]、[[ryu-startup-costs-measured]](被這條推翻的那份)、
[[two-writers-one-worktree]](四個善後 commit 是別的 session 收的)。

## 🔴 08-27 夜:同一晚三個實例、三個 session —— 這不是個人習慣,是系統性缺口

| 誰 | 改了什麼 | 驗證了「機制在動」 | 沒驗證「目的達成」 |
|---|---|---|---|
| 我(上午 `957a646`) | 用索引取代掃描 | 索引真的被查詢 | **比它取代的掃描慢 1.69×**;縮短的 settle 讓 twin **看不見 128 台 host** |
| 我(夜 §6.1) | 文件改成「取最大版號 + 檔頭有列 24.04」 | v10 檔頭**逐字**有 `24.04`(第 34 行) | **裝完之後兩個 binary 都不存在**,rc=1 |
| mainDev | churn 產生器的守衛 | **數 result 檔的數量**,計數 68/72 | **每條流都在連自己、全程 0 bytes**(註解逐字寫著它就是為這個失敗寫的) |

🔑 **可操作的驗收問句(比「要小心」強得多)**:
> **如果這個改動完全沒有效果,這一步會不會變紅?**

答不出來,就是在**驗機制**不是**驗目的**。

🔑 **最短的可引用形式**(寫進官網文件了):
> **A script declaring support is not evidence that it installs.**
> (一份宣稱支援的腳本,不等於它裝得起來。)

⚠️ **v10 那個特別值得記,因為判準是我自己剛發明的**:我把「跑指南指名的那支」改成
「列目錄取最大版號、再確認檔頭有 24.04」,自認為更可驗證。結果**判準驗的是腳本對自己的宣稱
(規則的輸入),不是它的產物**。⇒ **判準要釘在產物上。** 相關:[[test-conclusions-by-using-them]]。
