# FIX — 第八處 `ip[0]`：`updateHosts` 的 attachment switch（FINDINGS #88, W18）

日期：2026-09-07（09-07 round 2）。分支 `fix/w18-eighth-index-zero`
（base：`fix/w14-index-zero-guards`@`e62c8d6f`，**不是 trunk**——本輪裁決要求接在既有分支 tip 上）。
worktree `scratch/overnight-2026-09-05/wt-w2`（沿用 W2／W14 的樹）。
**沒有 push、沒有 merge、沒有碰 lab、沒有碰別的 worktree、沒有碰 `setting/`。**

[Co-developed with claude code -- Adam]

---

## 1. 這張單修的是什麼

一行：

```
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1729   （trunk 1536ff17；本分支 base 同行）
    auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
```

函式 `TopologyAndFlowMonitor::updateHosts`（`:1552` 起）——Ryu／P4 proxy 的
`/v1.0/topology/hosts` 回覆的收件處。`vertexOpt2` 來自 `findSwitchByDpid`，所以它一定是 SWITCH；
`ip[0]` 取的是**那台 attachment switch 的位址清單的第一個**，用來當 reverse edge 的 key。

`operator[]` **不是比較溫和的 `front()`**：libstdc++ 兩支都定義成 `*(_M_start + n)`，
而 default-construct 的 `std::vector` 的 `_M_start == nullptr` ⇒ 對空的 `ip` 取 `ip[0]`
是把 reference 綁到 null pointer 再讀穿它。跟 #88 的差別只有拼法。

### 1.1 🔴 它不是新長出來的，而**正確的總數是 24 處，不是 23，也不是 16**

`git show f0687b34:src/ndt_core/collection/TopologyAndFlowMonitor.cpp`（**W2 自己的 base**）
在當時的 `:1634` 就有這一行，而且就在 W2 大改的那個檔案裡。

| 盤點 | 宣稱的總數 | 漏掉的 |
|---|---|---|
| 工單給 W2 的 | 16（只掃 `.front()`） | 七處 `ip[0]` |
| W2-SUMMARY §2.2 | 23（16＋7） | **這一處** |
| W14-SUMMARY §5.1 | 24（rescan 找到） | ——（列出來但沒修） |
| **本單** | **24，全部有守衛** | —— |

⇒ **W2-SUMMARY §2.2 與 W14 FIX 文件裡的「23 處」是錯的口徑；正確是 24。**
兩份文件本單都加了註記（見 §6）。

### 1.2 重掃：現在 `src/` `include/` 底下還有幾處？

🔴 **行號對 base `e62c8d6f`（＝修法之前）**，不是對 trunk：W14 動過 `IntentTranslator.cpp`，
所以那個檔的行號跟 trunk 不同（trunk 上是 `:738`）。
`TopologyAndFlowMonitor.cpp` 與 `DeviceConfigurationAndPowerManager.cpp`
**在 trunk `1536ff17` 與 base 之間逐位元組相同**（`git diff --stat 1536ff17..e62c8d6f --` 空），
所以那兩個檔的行號兩邊通用。

```
$ grep -rn '\.ip\[0\]\|ip\.front()\|ip\.at(0)\|ip\[0\]' src include   # 排除註解行
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1729   ← 本單修的（修完不再是這個形狀）
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3565   findSwitchByIp        （W2 的 !vprop.ip.empty() &&）
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3580   findSwitchByIpNoLock  （同上）
src/ndt_core/collection/TopologyAndFlowMonitor.cpp:3802   buildDpidIpMaps       （props.ip.empty() continue，:3796）
src/ndt_core/intent_translator/IntentTranslator.cpp:781   BlockHostTask         （hostProp.ip.empty() 早退，:776）
src/ndt_core/power_management/DCPM.cpp:1235               managementIpOf 本體   （vp.ip.empty() 早退）
src/ndt_core/power_management/DCPM.cpp:2277               smart-plug table      （vp.ip.empty() continue，:2272）
src/ndt_core/power_management/DCPM.cpp:2395               device lookup         （W2 的 !vp.ip.empty() &&）
```

**七處是有守衛的，逐一複驗過（守衛的行號寫在括號裡）。第八處就是本單這一處，修完之後
`src/`／`include/` 底下沒有無守衛的 ip 首元素解參考。**

---

## 2. 可達性：SWITCH 級，**沒有找到產線路徑**，而這是修它的理由不是跳過它的理由

W14 的五處 HOST 站點是「走得到」的；**本單這一處不是**，它跟 W14 的第 1／2／6／7 處同一級。
下面三條是**我自己查的**，不是轉述：

| 問題 | 查法 | 答案 |
|---|---|---|
| 誰會造出 SWITCH vertex？ | `grep -rn 'add_vertex' src/ include/` | **整棵產線樹只有一處**：`TopologyAndFlowMonitor.cpp:775`（loader） |
| loader 收不收空 ip 的 SWITCH？ | 讀 `validateStaticTopologyJson:219` 與 builder backstop `:759` | **兩道門都 throw**，訊息含 `empty "ip" array` |
| 載入之後有沒有人把 SWITCH 的 ip 清空？ | `grep -rn '\.ip\.clear()\|\.ip = \|\.ip\.erase\|\.ip\.resize\|\.ip\.assign' src/ include/` | 三個命中：`GraphTypes.hpp:483`（`from_json`，**產線無呼叫端**，只有測試與被註解掉的兩行）、`TopologyAndFlowMonitor.cpp:707`（loader 自己）、`DCPM.cpp:2268`（**區域變數**，不是圖裡的頂點） |

⇒ **今天沒有路走到這一行。** 那正是 W14 對它的四處 SWITCH 站點寫的同一句話，而理由也一樣：

* 那道門是**另一個子系統裡的一個 `if`**，比依賴它的呼叫端**年輕**（#85／#89 才寫的）；
* 一個檔案裡同一個運算式修了七處、留一處，本身就是這個缺陷家族的形狀
  （W14 §2「一個分支補了、旁邊那個沒補」）；
* 而「這個檔案已經掃乾淨」這句話，在它還在的時候不能講。

⚠️ **口徑**：測試的 fixture 用 `boost::add_vertex` **直接造**一顆沒有位址的 SWITCH。
它證明的是「守衛在」，**不是**「產線造得出這種圖」。上表才是可達性的證據，而它的結論是**造不出來**。

---

## 3. 修法：守在哪裡、回什麼

```cpp
auto vertexOpt2 = findSwitchByDpid(*attachDpidOpt);
if (vertexOpt2.has_value())
{
    const auto attachIpOpt = utils::firstAddressRaw((*m_graph)[*vertexOpt2].ip);
    if (!attachIpOpt.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "host {} attaches to switch dpid {}, which carries no IP address in "
                           "this topology; the reverse edge is keyed by that address, so it "
                           "cannot be looked up and is left as it was",
                           macStr, *attachDpidOpt);
        continue;
    }
    auto edgeRevOpt = findEdgeBySrcAndDstIp(*attachIpOpt, ip);
    ...
}
```

三個決定，逐一寫理由：

### 3.1 用 `utils::firstAddressRaw`，不是 `firstAddressOf`

這個站點**從頭到尾不字串化**：它要的是 `findEdgeBySrcAndDstIp(uint32_t, uint32_t)` 的 key。
`firstAddressRaw` 在 W2 交付時是死碼（W2 §7 第 3 題），W14 的第 6／7 處是它的第一個呼叫端；
**本單是第二個**。兩張單都指向同一個答案：那支 helper 要留。

### 3.2 🔴 守在這裡，不是守在整筆條目的開頭

這一筆 hosts entry 做**三件互相獨立的事**，而缺的那個欄位只 key 其中一件：

| 做的事 | key 是什麼 | 缺 switch 位址會怎樣 |
|---|---|---|
| MAC 對到 host vertex，設 `isUp`／`isEnabled` | **host 的 MAC** | 不受影響 |
| `findEdgeByHostIp(ip)` 抬 host 側的 edge | **host 的位址** | 不受影響 |
| `findEdgeBySrcAndDstIp(switchIp, ip)` 抬 reverse edge | **(switch 位址, host 位址)** | **查不了** |

**只有第三件可以掉。** 把守衛往上搬一格＝連 host 側的 edge 一起掉（回報一條沒有斷的鏈路是斷的）；
往上搬兩格＝連 host 自己的存活一起掉，而 **host 一旦沒被抬起來就再也沒有別的東西會抬它**
（KNOWN-ISSUES F-14：沒有任何路徑會把 host 標 down，也就是說 `updateHosts` 是唯一的寫者）
⇒ 那一格的損失是**永久**的。閘門的 M4／M5 就是這兩個「整筆丟掉」的修法，各自有自己的紅。

`continue` 而不是 `else`：這個函式在它上面兩個檢查（`port.dpid` 不存在、dpid 不是 hex）
用的就是 `continue` ＋「its switch-side edge is left as it was」的句型，本單這一處是同一族的第三個。

### 3.3 不捏 `0.0.0.0`——而這裡的理由比平常那條更硬

平常的理由是「捏一個看起來像量測的位址，呼叫端分不出真假」（`FIX-CPU-REPORT-NO-IP.md` §5 記過兩次）。
這個站點還多一層：**捏出來的 key 查不到任何 edge**，於是控制流會掉進下面那個既有的 else：

```
"Rev Edge (host {}) not found in static network topology file"
```

那句話叫維運**去改拓樸檔**——去補一條「以一個這台交換機根本沒有的位址當 key」的 edge。
**檔案不可能寫得出那條 edge。** 也就是說替代值不只是答錯，它是**把紀錄的性質報成檔案的錯**，
而且指了一個做不到的動作。這一條就是測試 `TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile`
斷言 `"Rev Edge"` **不得出現**的原因，也是閘門 M2 的內容。

### 3.4 考慮過、**沒有採用**的另一種修法（留給下一個人，不要當成缺陷）

「switch 沒位址就改用 `findReverseEdgeByHostIp(ip)` 退而求其次」——用 host 的位址單邊比對，
把那條 reverse edge 抬起來。**我沒有把它寫成 mutation，也沒有寫測試禁止它**，因為它是不是錯的
**要 Adam 裁**：一方面回覆確實說了這台 host 掛在那個 dpid 上，抬它並非無據；
另一方面「只比對一個位址」正是 F-4 那一族的形狀。**在沒有裁決以前，把它寫成必須紅的變異
＝用閘門把一個設計偏好變成規則。** 見 SUMMARY §7。

---

## 4. 這一行原本就沒有在鎖裡讀，本單**沒有動**

`findSwitchByDpid` 在回傳前就放掉了它自己的 `shared_lock`，所以
`(*m_graph)[*vertexOpt2].ip[0]`（以及本單的 `firstAddressRaw(... .ip)`）是**在沒有持鎖的情況下
讀圖**；真正的 `unique_lock` 要到下面 `edgeRevOpt.has_value()` 之後才拿。

* 本單**沒有擴大**這個曝露面：讀的是同一個 vertex 的同一個 `ip` 成員，只是多讀一次 `empty()`。
* 本單**沒有修**它：修它要把讀搬進一個獨立的 scoped `shared_lock`（不能直接罩住
  `findEdgeBySrcAndDstIp`——它自己會再拿一次 shared lock，同一執行緒重入在有 writer 排隊時會死鎖），
  而那是**另一個缺陷**，需要它自己的證據（一個看得到 race 的測試），今晚做不出來。
* 記在這裡而不是留白：它是 `updateHosts` 全函式的性質，不是本單造成的。見 SUMMARY §7。

---

## 5. 測試：一支必死 ＋ 五支「守衛之後答什麼」

`tests/test_AddresslessAttachmentSwitch.cpp`，fixture `AddresslessAttachmentSwitchTest`。
**自己的檔、自己的 fixture**，不併進 `test_AddresslessNodeReplies.cpp`：那支 fixture 是
intent／agent／flow 三個子系統的 peer 組合，而本單餵的是一份 Ryu HTTP 回覆；
而且 W14 的閘門硬寫著「`AddresslessNodeTest.*DoesNotKillTheProcess` 必須剛好七支」，
在那個 suite 裡加第八支會讓一支**別人的**閘門 REFUSE。

### 5.1 為什麼第一支要 fork

缺陷是 null 解參考 ⇒ 在普通 build 上**不會產生紅線**，它會把整個 binary 帶走、
任何 suite 都不留裁決（W2 的 M2 就是這樣被判 SURVIVED 的，W2-SUMMARY §4.2）。
所以那一處給一支 `EXPECT_EXIT(..., ExitedWithCode(0), "")`：子行程跑一次 poll 然後乾淨退出；
缺陷還在的時候子行程吃 SIGSEGV，父行程印一行**有名字的**紅。

### 5.2 fixture

```
s1            SWITCH dpid 1     192.168.123.11      h_on_s1  HOST 10.0.0.12  掛在 s1
s_no_address  SWITCH dpid 4242  （沒有位址）          h_on_sx  HOST 10.0.0.11  掛在 s_no_address
四條有向 edge，照 loader 的形狀：host 側 src_dpid=0 帶 host 位址；switch 側 dst_dpid=0 帶 host 位址。
```

三個刻意的設計：

* **兩筆條目在同一份 reply 裡，而且有問題的那筆在前**。對照組與缺陷走同一次呼叫 ⇒
  「另一筆還是好的」不是另一次可能因為別的原因不同的跑；而一個寫成 `return` 而不是 `continue`
  的守衛（或逃到函式層 catch 的例外）會立刻看得見。
* 🔴 **每一顆 vertex、每一條 edge 都造成 down**。`VertexProperties` 與 `EdgeProperties` 的
  `isUp`／`isEnabled` **預設是 true**，fixture 不寫就會讓底下每一句「還是被抬起來」**恆真**——
  跟 `updateHosts` 做了什麼無關。loader 自己也是寫 false 進去的，理由一樣。
* **dpid 用 4242 不用 2**：守衛的 WARN 用十進位印它，而測試要拿它去 grep log；
  「2」同時也會是 port number、index、和同一份 reply 裡半數 hex dpid 的一部分。

### 5.3 六支測試各自擋掉什麼

| 測試 | 擋掉的錯誤修法 | 閘門變異 |
|---|---|---|
| `AnAddresslessAttachmentSwitchDoesNotKillTheProcess` | 沒修（subscript 還在） | M1 |
| `TheHostOnAnAddresslessAttachmentSwitchIsStillMarkedUp` | 守衛搬到整筆條目最前面 | M5 |
| `TheHostSideEdgeIsStillRaisedWhenTheAttachmentSwitchHasNoAddress` | 守衛搬到 host 側 edge 之前 | M4 |
| `TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile` | 捏位址（→ 誤導的 "Rev Edge" 那句）／默默跳過 | M2、M3 |
| `TheReverseEdgeOfAnAddressedAttachmentSwitchIsStillRaised` | 過度守衛：對誰都不查 | M6 |
| `TheOtherHostAndItsEdgeAreUntouchedByTheGuardedEntry` | `return` 而不是 `continue`（後面的條目全掉） | （對照，無變異） |

**log 的斷言只釘兩個識別碼（哪一台 host、哪一台 switch）＋「不得出現 `Rev Edge`」，
刻意不釘句子本身。** 閘門的 C3 就是「把訊息改寫、兩個參數留著」的對照組，它必須留綠——
一個只認死句子的斷言，會在下一個人改善措辭時變紅，並教會他把斷言刪掉。

---

## 6. 連帶要改的文件

* `scratch/overnight-2026-09-05/fix/W2-SUMMARY.md` §2.2 的「23 處」⇒ 加註「正確是 24」。
* `doc/audit/2026-09-06_fix-index-zero-guards/FIX-INDEX-ZERO-GUARDS.md` ⇒ 加註第八處已修、在哪。
* **`doc/KNOWN-ISSUES.md` 沒有動**（今晚多個 session 在寫那個檔，在分支上改它是自找衝突）。
  建議條目見 SUMMARY §6。
* **API 手冊 `doc/2026-01-02_ndt_api.md` 沒有動**：`updateHosts` 不是 HTTP endpoint，
  它是 kernel 主動去 poll 控制平面得到的回覆的**消費者**；本單也沒有改任何回覆的形狀，
  只改了圖的寫入條件與一行 log。
* **`tools/contract_test/spec.py` 沒有動**：同理，它描述的是拓樸檔 schema 與 `/ndt/*` 的回覆。
