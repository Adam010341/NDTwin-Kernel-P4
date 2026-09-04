# M7 — `source_routing` 逐步表與每步預期輸出

Adam 15:2x 裁定的順序第一支。**本檔一個封包都沒送過。**
每一條預期輸出都標了來源，三種**不可互換**：

- 【實測】＝我在這台機器上真的跑出來的（時間 2026-09-04 14:0x–15:4x）
- 【源碼推導】＝我讀 `.p4`／`topology.json`／`send.py` 推出來的，**沒有執行**
- 【README 宣稱】＝ exercise 自己的 README 這樣寫，**它本身也在受測**

🔑 **後兩者跟第一者不同級。** 若實跑結果與【源碼推導】不合，先查我的推導；
若與【README 宣稱】不合而【源碼推導】合，那就是 exercise 的文件缺陷，照報。

[Co-developed with claude code -- Adam]

---

## 0. 這支 exercise 在測什麼

Source routing：**由來源主機決定整條路徑**。h1 把一疊「出埠編號」塞在 Ethernet 與 IP 之間
（`etherType = 0x1234`），每台交換機從堆疊頂端彈出一個、照它設 egress port。
最後一跳（`bos == 1`）把 `etherType` 改回 `0x0800`。

⇒ **交換機一條 table entry 都不需要。** `s1/s2/s3-runtime.json` 的 `table_entries` 都是 `[]`
【實測：三個檔都是空陣列】。這一點使它成為排序第一支的好選擇——
**控制面完全不參與，任何失敗都只能是資料面或環境。**

---

## 1. 前置（一次性，不需要 root）

| # | 動作 | 預期 |
|---|---|---|
| P1 | `bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/preflight.sh` | 見 README §1 的三個 blocker。**9090 那項會亮紅**，那是 Adam 的 dashboard，照裁定不要動——但 **s1 會綁不上 thrift port**，要嘛先收掉它再跑，要嘛接受 s1 起不來 |
| P2 | 確認 lab 沒人用：`NDT_OWNER=<你> ndt status` 的 `claim`／`measuring` | `claim none`／`measuring nothing`。**tutorials 不走 `ndt`，但它會佔 mininet 與網路 namespace** ⇒ 跟 `ndt up` 不能同時 |
| P3 | 直譯器 | 一律 `/home/adam/p4dev-python-venv/bin/python`。**PATH 上的 `python3` 是 conda 3.13，三個套件全缺**【實測】 |

---

## 2. 拓樸與埠對照（【實測】，讀自 `topology.json`）

```
            s1
          /  |  \
      p1/  p2|   \p3
      h1     |    \
             |     s3 --p1-- h3
             |    /  \
             |  p2    p3
             |  /      \
             s2 --------+
           p1 |  p2  p3
              h2
```

| 交換機 | p1 | p2 | p3 |
|---|---|---|---|
| **s1** | h1 | s2 | s3 |
| **s2** | h2 | s1 | s3 |
| **s3** | h3 | s1 | s2 |

主機：`h1 10.0.1.1`、`h2 10.0.2.2`、`h3 10.0.3.3`（`/24`，各自 default gw ＋ 靜態 ARP）【實測】。

### README 的 `2 3 2 2 1` 走哪裡（【源碼推導】，與【README 宣稱】一致）

| 跳 | 在哪 | 從哪個埠進 | 彈出 | 出埠 | 去哪 | 剩下的堆疊 |
|---|---|---|---|---|---|---|
| 1 | s1 | p1（h1） | `2` | p2 | s2 | `3 2 2 1` |
| 2 | s2 | p2 | `3` | p3 | s3 | `2 2 1` |
| 3 | s3 | p3 | `2` | p2 | s1 | `2 1` |
| 4 | s1 | p3 | `2` | p2 | s2 | `1` |
| 5 | s2 | p2 | `1`（**bos=1**） | p1 | **h2** | 空 |

⇒ 路徑 `h1, s1, s2, s3, s1, s2, h2`，**5 次交換機處理**，其中 s1、s2 各走兩次（**刻意繞圈**）。
`update_ttl()` 每跳減 1、初始 `ttl=64`（scapy `IP()` 預設）⇒ **h2 收到 `ttl = 59`**。

### 最短路徑（README 留的問題，【源碼推導】）

`2 1`——s1 的 p2 到 s2、s2 的 p1 到 h2。**2 跳，`ttl = 62`。**

---

## 3. Step 1：跑骨架，預期「起得來但收不到」

**不是**預期編譯失敗。骨架的 parser 在 `parse_ethernet` 就 `transition accept`
（`source_routing.p4:78` 的 `TODO` 還沒填），`hdr.srcRoutes[0]` 永遠 invalid，
`apply` 走 `else` 分支 `drop()`【源碼推導，讀 `:71-87` 與 `:134-147`】。

| # | 誰 | 指令 | 預期輸出 | 來源 |
|---|---|---|---|---|
| 1.1 | 任何人 | `bash …/run_exercise.sh source_routing skeleton` | 印出四個 `--Wwarn=unused` 警告：`TYPE_SRCROUTING`、`egressSpec_t`、**`srcRoute_nhop`**、**`srcRoute_finish`**；`build/source_routing.json` **12410 B**、`sha256 e6816123c89b51a8`；然後印指令並停 | 【實測】 |
| | | | 🔑 後兩個警告**就是** Step 1 的意義：那兩個 action 沒有任何呼叫者，因為 `apply` 裡的 TODO 還沒填。**這一條不用 root 就驗得到** | 【實測】 |
| 1.2 | **Adam** | 同一行加 `--go` | mininet 起來，印 `s1 -> gRPC port: 50051` … `s3 -> Thrift port: 9092`，最後停在 `mininet>` | 【源碼推導：`run_exercise.py:41,55`；未執行】 |
| | | | ⚠️ **若 9090 還被佔著，s1 這裡就會失敗** | 【實測：9090 有人佔】 |
| 1.3 | Adam | `mininet> net` | 三台交換機、三台主機，連線與 §2 的表一致 | 【源碼推導】 |
| 1.4 | Adam | `mininet> xterm h1 h2` | 兩個 xterm | 【README 宣稱】 |
| 1.5 | h2 的 xterm | `source /home/adam/p4dev-python-venv/bin/activate`<br>`./receive.py` | `sniffing on eth0`，然後**一直沒有輸出** | 【源碼推導】 |
| | | | 🔴 **不 activate 就會 `ModuleNotFoundError: No module named 'scapy'`**——shebang 是 `#!/usr/bin/env python3`，抓到的是 conda 那顆 | 【實測】 |
| 1.6 | h1 的 xterm | `source …/activate`<br>`./send.py 10.0.2.2` | `sending on interface h1-eth0 to 10.0.2.2`，然後提示 `Type space separated port nums (example: "2 3 2 2 1") or "q" to quit:` | 【源碼推導：`send.py:47,55`】 |
| 1.7 | h1 的 xterm | 輸入 `2 3 2 2 1` | `pkt.show2()` 印出 `Ether(type=0x1234)` ＋ **5 層 `SourceRoute`**（前 4 層 `bos=0`，第 5 層 `bos=1`，port 依序 2/3/2/2/1）＋ `IP(ttl=64, dst=10.0.2.2)` ＋ `UDP(sport=1234, dport=4321)` | 【源碼推導：`send.py:60-80`】 |
| 1.8 | h2 的 xterm | 看 | 🔑 **什麼都沒有。這就是 Step 1 的正確結果。** | 【README 宣稱】＋【源碼推導】 |
| 1.9 | 任何人 | `less exercises/source_routing/logs/s1.log` | 應看到封包進來、`hdr.srcRoutes[0]` 無效、走 `drop()`／`Dropping packet` 一類的 trace | 【README 宣稱】。⚠️ **確切字串我沒有觀察過，不要照抄成預期值**——要驗的是「有進來、且被丟掉」，不是某一行字 |
| 1.10 | Adam | `mininet> exit` | 回到 shell | 【README 宣稱】 |

**Step 1 的判定**：起得來 ✅、h2 收不到 ✅、s1.log 顯示丟棄 ✅ ⇒ 通過。
**若 h2 收得到，那是重大異常**（骨架不該轉發任何東西）。

---

## 4. Step 2：不做

README 的 Step 2 是要人填 `TODO`。**我們測的是 exercise 本身，不是做作業** ⇒
直接用 `solution/source_routing.p4`。

⚠️ **不要把 solution 複製蓋掉 `source_routing.p4`**（那會弄髒對照樹）。
`run_exercise.sh` 是把 solution **編到骨架的輸出檔名** `build/source_routing.json`——
`sX-runtime.json` 指名的就是那個路徑，載入的位元完全相同，而 `.p4` 原始檔一個字沒動【實測】。

---

## 5. Step 3：跑 solution，預期「收得到、`ttl = 59`」

| # | 誰 | 指令 | 預期輸出 | 來源 |
|---|---|---|---|---|
| 3.1 | 任何人 | `bash …/run_exercise.sh source_routing solution` | **只有 1 個警告**（`egressSpec_t` unused）；`build/source_routing.json` **19572 B**、`sha256 58f74ed1d535c77e` | 【實測】 |
| | | | 🔑 **警告從 4 個掉到 1 個**，掉的正是 `srcRoute_nhop`／`srcRoute_finish`／`TYPE_SRCROUTING` ⇒ 它們現在有呼叫者了。**這是不用 root 的第二個判別點** | 【實測】 |
| 3.2 | Adam | 加 `--go`，重複 1.2–1.7 | 同上 | |
| 3.3 | h2 的 xterm | 看 | `got a packet`，接著 `pkt.show2()` | 【源碼推導：`receive.py:35-37`】 |
| 3.4 | h2 的 xterm | 讀那個 `show2()` | **`Ether type=0x0800`（不是 0x1234）**、**沒有任何 `SourceRoute` 層**、`IP ttl=59`、`UDP sport=1234 dport=4321` | 【源碼推導】＋ ttl 這項與【README 宣稱】一致 |
| | | | 為什麼沒有 SourceRoute 層：5 個項目被 5 跳各彈掉一個（`pop_front(1)`，`:116`），deparser 只 emit 還有效的（`:167`）⇒ 到 h2 時堆疊已空；而最後一跳 `srcRoute_finish()` 把 `etherType` 改回 `0x800`（`:120`），所以 scapy 也不會再當成 SourceRoute 解 | 【源碼推導】 |
| 3.5 | h1 的 xterm | 輸入 `2 1` | h2 收到，**`ttl = 62`**（最短路徑，2 跳） | 【源碼推導】 |
| 3.6 | Adam | `mininet> exit` | — | |

**Step 3 的判定**：`got a packet` ✅、`ttl == 59` ✅、無 SourceRoute 層且 `type=0x0800` ✅ ⇒ 通過。

🔑 **`ttl` 是這支 exercise 最好的斷言**：它同時證明「有送到」與「**走的是我們指定的那條繞圈路徑**」。
只看「h2 收到了」分不出 `2 3 2 2 1` 與 `2 1`——**59 與 62 才分得出**。

---

## 6. 額外邊界檢查（便宜、README 沒寫）

| 檢查 | 做法 | 預期 | 來源 |
|---|---|---|---|
| 堆疊上限 | 在 `send.py` 輸入 **10 個以上**的埠號 | 應失敗——`srcRoutes` 是 `srcRoute_t[MAX_HOPS]`，`MAX_HOPS = 9`（`solution:10,52`）。`send.py` 完全不檢查長度 ⇒ 第 10 個 extract 會 parser error，封包被丟 | 【源碼推導，未執行】 |
| 錯的埠號 | 輸入含 `9` 的序列（沒有 p9） | 交換機會設一個不存在的 egress ⇒ 丟棄。**這不是 bug** | 【源碼推導】 |
| 骨架/solution 混淆 | 比對 `build/source_routing.json` 的 sha256 | 骨架 `e6816123c89b51a8`／solution `58f74ed1d535c77e` | 【實測】 |

---

## 7. 出事時看哪裡

| 症狀 | 先查 | 為什麼 |
|---|---|---|
| `sudo: … not allowed to set … PATH` | **不是 P4 的問題**。upstream `make run` 在這台必失敗，用 `run_exercise.sh` | 【實測】README §1 B-1 |
| `ModuleNotFoundError: scapy` / `mininet` / `grpc` | 直譯器抓錯了 | 【實測】README §1 B-2 |
| s1 起不來、thrift 綁不上 | `ss -tlnH | grep 9090` | 【實測】9090 被 dashboard 佔 |
| 交換機起不來、port 被佔 | 上一輪的 orphan bmv2 活過了 `mn -c` | 我們自己的已知形狀（`p4-orphan-switches-and-manifest-lifetime`）。**不要 `pkill -f`** |
| 編出來的 json 跟預期 sha 不同 | 是不是編到另一支 `.p4` | 【實測】兩個 sha 在 §6 |
| h2 收到但 `ttl` 不是 59 | 路徑不是預期那條，或 `update_ttl` 沒每跳執行 | 這是**真正值得報的結果**，不是操作失誤 |

---

## 8. 這一份的邊界

- **`--go` 一次都沒跑**，所以第 1.2–1.10 與 3.2–3.6 全部是【源碼推導】或【README 宣稱】。
  Adam 實跑之後，這份的每一列都應該被換成【實測】或被推翻。
- 依裁定 3，今晚整機測試不含 tutorials ⇒ 這支不趕今晚。
- 9090 依裁定照舊不動。
- **下一支**：`basic` → `flowcache` → `p4runtime`。`flowcache` 的骨架**編不過**
  （5 個 `--Werror=type-error`，那正是它的第一項作業），到時候的 Step 1 預期跟這支不同。
