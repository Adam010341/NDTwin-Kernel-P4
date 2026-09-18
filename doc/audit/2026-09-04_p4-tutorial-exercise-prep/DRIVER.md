# `drive_exercise.py` — 非互動式 exercise 驅動器

讓 Adam **打一行 sudo 就拿到 pass/fail**，不用在 `mininet>` 裡手動敲字、不開 xterm。

🏁 **2026-09-08 17:24 首跑（Adam 以 root，euid 0）：四種組合全 PASS**——
`source_routing` solution **5/5**、skeleton **2/2**、`basic`（pod-topo）solution **5/5**、skeleton **4/4**，
四次都 **exit 0**，報告在 [`runs/`](runs/)。工具鏈：`/usr/local/bin/simple_switch_grpc` sha `327fa7d172217397`、
`p4c-bm2-ss` sha `226f3f66df515c9e`（**不是** `bmv2-fast` 那顆）。`~/tutorials` 的 `git status` 跑前跑後相同。
🔑 **這證明的是「exercise 的預期行為」與「driver 能用」，不是 NDTwin 能跑它們**——**在 NDTwin fabric 上 0/13**。
下面 §4 標【源碼推導，未執行】而已被那四次驗掉的，逐條加了 ✅；**沒加 ✅ 的仍未被 root 路徑驗證過**。

[Co-developed with claude code -- Adam]

## 1. 它做什麼

1. **pre-flight（唯讀、不殺行程）**：9090–9099 有 listener 就**拒跑**並印出 pid／cmdline／cwd
   讓你自己決定要不要收；檢查直譯器是不是 venv 那支；印 `simple_switch_grpc` 與 `p4c-bm2-ss`
   的 sha256 前 16 碼＋版本（**版本字串分不出那兩顆 bmv2，只有 sha 分得出**）。
2. **編譯**：把選中的程式（預設 `solution/`）編到**骨架的輸出檔名** `build/<prog>.json`，
   `.p4` 原始檔一個字沒動；記下 bytes 與 sha。
3. **起網路**：`cd` 進 exercise 目錄後 import `ExerciseRunner` 並繼承它，**`do_net_cli()` 換成
   腳本化步驟**、`net.stop()` 放進 `finally`（upstream 沒有）。`send.py`／`receive.py` 一律用
   絕對路徑的 venv 直譯器叫（它們的 shebang 會抓到 conda 那支）。
4. **判定＋報告**：每條期望沿用 M7 的三級標記，寫到 `runs/<UTC>_<exercise>_<which>.md`
   （工具鏈 sha、json sha、每步指令、原始輸出、判定表、log 路徑），最後印出報告路徑。
   exit **0** 全過／**1** 有一條沒過／**2** pre-flight 擋掉或那支還沒腳本化。

~~目前腳本化的只有 **`source_routing`** 與 **`basic`**~~ ⇒ 🆕 **2026-09-19：十三支全部腳本化**（TICKET-P3 §2.7，期望表在 §6）。`EXERCISES` 以外的名字仍然印 "not scripted yet" 然後 exit 2。
**新增的九支一次都沒跑過**——§6 每一格都標了證據等級。

## 2. Adam 要打的那一行

```
sudo /home/adam/p4dev-python-venv/bin/python \
  doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py source_routing --which solution
```

`--which skeleton` 換骨架（Step 1 的對照組）、`basic` 換另一支、`--dry-run` 只做第 1–2 步（不需
root，會把該打的 sudo 指令原字印出來）。**跑之前先收掉 9090 上的 dashboard**，否則 s1 綁不上
thrift port——驅動器只會告訴你是誰佔著，不會去動它。

## 3. pass 長什麼樣

`source_routing --which solution`：h2 收到 **2 個**封包、ttl 是 **{59, 62}**（順序不保證，見 §4）、
封包裡**沒有 SourceRoute 層**、ether type 是 IPv4。最後兩行 `>>> PASS (5/5)` 與 `report: .../runs/...md`
（🆕 **09-08 更正**：這裡原本寫 `(4/4)`，實際是 **5/5**——`source_routing` solution 有五條斷言）。
`--which skeleton` 的 pass 是**收到 0 個**——同時要求 `send.py` 真的印出兩份 `type = 0x1234` 的
show2（**沒有這條，「0 個」是空的**）。`basic`：solution ⇒ `pingAll` loss 0%、`ping -c3` 3/3、
h2 收得到；skeleton ⇒ loss 100%、0/3、收不到。
✅ **09-08 四次實跑逐字對上**：5/5（`[59, 62]`、0 個 SourceRoute 層、兩包都顯示 `IPv4`）、
2/2（h2 收 0 個、`send.py` 兩份 `0x1234` show2 都在）、5/5（loss `0.0%`、3/3、ttl `[63]`）、
4/4（loss `100.0%`、0/3、收 0 個）。

## 4. 已知未知

- ✅ ~~🔴 **整條 root 路徑一次都沒跑過**~~ ⇒ **2026-09-08 17:24 由 Adam 跑過了**（四種組合，euid 0）：
  交換機都起得來、P4Runtime 灌得進去（`basic` 四台各 `Inserting 5 table entries...`；
  `source_routing` 是 `0`，本來就沒有 entry）、封包收得到，
  下面這段的「全部【源碼推導，未執行】」**只描述 09-08 之前**。仍未跑過的是：其餘 11 支 exercise、
  `run_exercise.sh --go`、`basic` 的 `triangle-topo`、以及**任何在 NDTwin fabric 上的執行**。
- （09-08 之前的原文）🔴 整條 root 路徑一次都沒跑過（我沒有互動式 sudo）：交換機起不起得來、P4Runtime 灌不灌得進去、
  封包收不收得到，全部【源碼推導，未執行】。**已實跑的只有**：pre-flight、四種組合的編譯
  （sha 與 M7／COMPILE-MATRIX 完全對上）、`from run_exercise import ExerciseRunner`、
  以及輸出解析器的綠紅雙向測試（餵造出來的 show2 文字，錯 ttl／零封包／殘留 SourceRoute 都確實轉紅）。
- ✅ **停掉 `receive.py` 靠 `Popen.terminate()`**，前提是 `mnexec -da` 不 fork（它只在自己已是
  process group leader 時才 fork，Popen 的子行程不是）⇒ `Popen.pid` 就是 python 本身。
  ~~【源碼推導，未執行】~~ ⇒ **09-08 四次都收乾淨**：`receive.py` 的輸出檔完整寫出、
  `net.stop() returned cleanly`、四次都 exit 0、沒有卡住的 sniffer。【實測】
- **兩個封包同一次 `send.py` 送**（`send.py:52-73` 讀到 `q` 才跳出），而 `2 1` 比 `2 3 2 2 1` 短
  ⇒ **抵達順序不保證**。判定因此比對 multiset `{59, 62}`，不看順序。
  ✅ 09-08 那次的實際順序是 **59 先、62 後**（繞圈的先到）——**一次觀察，不足以推翻「不保證」，判定維持 multiset**。
- ✅ **`basic` 骨架 ⇒ 100% loss 的推導**（`exercises/basic/basic.p4` 行號）——**09-08 實測 `loss = 100.0%`
  （pingAll 0/12）、`h1 ping -c3 h2` 0/3、h2 收 0 個**，推導與結果相符（**驗到的是結果，不是每一條機制**）：`:66-74` parser 直接
  `transition accept`，沒有 `packet.extract` ⇒ `hdr.ipv4` 永遠 invalid；`:150-157` 仍無條件
  `ipv4_lpm.apply()`，key `:139` 讀的是 invalid header ⇒ 必 miss；`:147` 預設 `NoAction()`，
  而 `pod-topo/s1-runtime.json` 第一筆 `"default_action": true` 又把它改成 `MyIngress.drop`；
  就算命中，`:119-129` 的 `ipv4_forward` **整段是註解**，`egress_spec` 從未被指派；
  `:202-211` deparser 也不 emit ⇒ 沒有任何封包會被送到資料埠。【源碼推導，未執行】
- ✅ **`basic` 的 h2 ttl 應為 63**（pod-topo 裡 h1、h2 同掛 s1，只有一跳）。~~【源碼推導，未執行】~~
  ⇒ **09-08 實測 `[63]`**（`ping -c3` 三個回應也都是 `ttl=63`）。【實測】
- `--recv-warmup` 預設 3 s（venv 冷啟 `import scapy.all` 實測 0.21 s），不夠就加大。
  ✅ 09-08 四次都夠（該收到的都收到了，`source_routing` solution 2/2 包、`basic` solution 1 包）。

### 順手抓到的三個文件缺陷（~~**我沒有改 M7／README**，請 Adam 裁~~ ⇒ ✅ **2026-09-08 三處都已就地改掉**：M7 §3 1.6、M7 §5 3.4、README §6）

1. **M7 1.6**：`send.py` 印的是 `sending on interface eth0`，不是 `h1-eth0`——
   `p4_mininet.py:21` 的 `P4Host.config` 把 defaultIntf 改名成 `eth0`。
2. **M7 3.4**：scapy `show2()` 對 0x800 印的是 `type      = IPv4`（名字），不是 `0x0800`；
   0x1234 才印數字。要拿字串當預期值的話得照這個寫。（**實測**）
3. **README §6**：宣稱 `build/`／`logs/`／`pcaps/` 三個都在 `.gitignore`——`pcaps/` 這個**目錄**
   其實不在，只有 `*.pcap` 在（`.gitignore:18`）。實務上 `git status` 仍乾淨，但那句話要修。（**實測**）

## 5. 中途爆掉時

驅動器把 `net.stop()` 放在 `finally`，正常路徑會自己收乾淨。若真的死在中間：

1. 先確認**沒有 NDTwin 的 lab 在跑**：`NDT_OWNER=adam ndt status` 看 `claim`／`measuring` 欄——
   tutorials 不走 `ndt`，但它佔的是同一套 mininet 與 network namespace。
2. 確認之後再 `sudo mn -c`。**不要 `pkill -f`**；上一輪的 orphan bmv2 有活過 `mn -c` 的前例，
   真的還在就用 `ss -ltnp` 認出 pid 再個別處理。
3. `~/tutorials` 的寫入只落在 `build/`／`logs/`／`pcaps/`；`git -C ~/tutorials status --short`
   跑前跑後應完全相同（本輪四次 dry-run 前後 md5 皆 `b2f872b1916e20a3879d2dbebc35e06c`）。
   ✅ **09-08 那四次真跑也一樣**：`git status` 前後相同，寫入只有 `build/`／`logs/`／`pcaps/`
   （tutorials tree `c80d83e`；`~/tutorials` 本來就有的那三行註解改動與兩個 `.vsix` 不是這輪造成的，見 README §6）。

---

## 6. 十三支的期望表（TICKET-P3 §2.7；**2026-09-19 新增的九支一次都沒跑過**）

🔴 **這一節整張表的證據等級是【源碼推導，未執行】或【README 宣稱】。** 寫這九支的 session 沒有
sudo、沒有 lab、沒有跑過任何一支（TICKET-P3 §0-2）；離線測試斷言的是「driver 用這個方式問問題」
以及「兩臂可區分」，**不是**「exercise 在 NDTwin 上會這樣」。上面 §3／§4 那四支（`basic`／
`source_routing`／`firewall`／`link_monitor`）仍是 09-08／09-18 那幾次實跑的結論，沒有被這輪改動。

三級標記沿用 M7：

- 【README 宣稱】＝ exercise 自己的 README 逐字說的；
- 【源碼推導，未執行】＝ 從 `.p4`／`send.py`／`receive.py`／`sX-runtime.json` 讀出來的；
- 【README 宣稱】＋【源碼推導，未執行】＝ 兩者都有，而且一致。

### 6.1 九支的判定表

| exercise | 臂 | 期望（driver 斷言的那一條） | 來源等級 | 依據 |
|---|---|---|---|---|
| `basic_tunnel` | injection | `send.py` 印了兩行 `sending on interface … to dst_id N` | 【源碼推導，未執行】 | `send.py:38` |
| | solution | `--dst_id 2` 只落 h2；`--dst_id 3` 只落 h3，**兩輪送同一個 IP** | 【README 宣稱】＋【源碼推導，未執行】 | README:121-124、:138-140；`solution/basic_tunnel.p4` 的 `myTunnel_exact` |
| | skeleton | **紅臂在 entries，不在資料面**：`sX-runtime.json` 的 `myTunnel_exact` 三筆裝不進去 | 【README 宣稱】 | README:41-43 逐字 |
| `calc` | injection | `calc.py` 回顯 `> 1+1` | 【README 宣稱】＋【源碼推導，未執行】 | `calc.py:80-84`；README 的兩段 transcript |
| | solution | 有一行**整行**是 `2`，而且沒有 `Didn't receive response` | 【README 宣稱】 | README step 3 的 transcript |
| | skeleton | 有 `Didn't receive response`，而且沒有 `2` 那一行 | 【README 宣稱】＋【源碼推導，未執行】 | README step 1.3；`calc.p4:116-126` 的 `check_p4calc` 沒有 transition ⇒ `:205-210` drop |
| `ecn` | injection | h2 至少收到一包，且 `send.py` 的 show2 印了 tos | 【源碼推導，未執行】 | `send.py:35-41`、`receive.py:34` |
| | solution | h2 看到的 tos 值裡有 `0x3` | 【README 宣稱】＋【源碼推導，未執行】 | README step 3；`solution/ecn.p4:131-139`、`ecn.p4:9` 的 `ECN_THRESHOLD = 10` |
| | skeleton | 每一包 tos 都是 `0x1` | 【README 宣稱】＋【源碼推導，未執行】 | README step 1.8；`ecn.p4:132-138` 空的 `MyEgress.apply` |
| `mri` | injection | h2 收到包，而且包裡真的有 MRI option（`count` 欄存在） | 【源碼推導，未執行】 | `receive.py:33-50` 的 `IPOption_MRI` |
| | solution | `count == 2`、swid 集合 `[1, 2]` | 【README 宣稱】＋【源碼推導，未執行】 | README step 3 的 dump；`sX-runtime.json:6-13` 的 `default_action` |
| | skeleton | `count == 0`、沒有任何 swid | 【README 宣稱】＋【源碼推導，未執行】 | README step 1.7；`mri.p4:205`／`:268` |
| `flowcache` | skeleton | **紅臂在編譯器**：`p4c` 拒編 | 【README 宣稱】＋【源碼推導，未執行】 | README:29 逐字；`flowcache.p4:83-91` 兩個空 header vs `:232`／`:269-271` 讀它們 |
| | solution | 控制器在 s1/s2/s3 都裝了 pipeline、cache 了一條流、h1 ping h2 通 | 【README 宣稱】＋【源碼推導，未執行】 | README step 3；`mycontroller.py:457-472`、`:372-376` |
| `load_balance` | injection | `send.py` 十次都印了 `sending on interface … to 10.0.0.1` | 【源碼推導，未執行】 | `send.py:34` |
| | solution | h2 與 h3 **各** ≥1 包 | 【README 宣稱】 | README step 3「some should be received by each server」 |
| | skeleton | h2 ≥1、h3 **恰好 0** | 【README 宣稱】＋【源碼推導，未執行】 | README:24-25；`load_balance.p4:107` 空的 `set_ecmp_select` ⇒ `ecmp_select` 恆 0 ⇒ s1 port 2 |
| `multicast` | injection | 12 個有序對**全部測到**（0 untested） | 【源碼推導，未執行】 | 沒進到 namespace 的主機和群組不複製到的主機長得一樣 |
| | solution | h1/h2/h3 互通 0%；**hX→h4 三對 100%、h4→hX 三對 0%** | 【README 宣稱】＋【源碼推導，未執行】 | README:119-120；`sig-topo/s1-runtime.json:47-65` 只複製 port 1,2,3（第四個是 README:122 的 TODO）。🔴 **但 :36-45 有替 h4 的 MAC 裝 `mac_forward → port 4`**（judge A4）：hX 的 ARP 只氾濫到 1,2,3、h4 收不到 ⇒ hX→h4 100%；h4 自己的 ARP 氾濫到 1,2,3 有人回，單播回覆命中那條 entry ⇒ **h4→hX 0%**。第一版六對都斷言 100%，會在一個完全照 exercise 行為的 fabric 上紅三對。 |
| | skeleton | pingall 100% | 【README 宣稱】＋【源碼推導，未執行】 | README:78-80；`multicast.p4:91` `default_action = drop` ⇒ 連 ARP 都死 |
| `p4runtime` | injection | 控制器活著；它裝 pipeline 的交換機集合是 `[1, 2]` | 【源碼推導，未執行】 | `mycontroller.py:142-152`（s3 從不被連） |
| | solution | log 有 `Installed transit tunnel rule`；h1 ping h2 0% | 【README 宣稱】＋【源碼推導，未執行】 | `solution/mycontroller.py:85`；README step 3 |
| | skeleton | log 有 `TODO Install transit tunnel rule`；h1 ping h2 100% | 【README 宣稱】＋【源碼推導，未執行】 | `mycontroller.py:76`；README step 1.3 |
| `qos` | injection | 兩輪都有包到 h2 | 【源碼推導，未執行】 | `send.py:40-54`；`receive.py:22` 沒有 filter |
| | solution | UDP 那輪 tos 含 `0xb9`、TCP 那輪含 `0xb1` | 【README 宣稱】＋【源碼推導，未執行】 | README:110-111；`solution/qos.p4:208-214`（46<<2\|1＝0xb9、44<<2\|1＝0xb1） |
| | skeleton | 兩輪 tos 都只有 `0x1` | 【README 宣稱】＋【源碼推導，未執行】 | README step 1.6；`qos.p4:138` |

### 6.2 三件跟「期望對不對」無關、但會決定判讀的事

1. **`ecn` 需要 G2-C（TICKET-P3 §2.4）。** `ecn.p4:9` 的 `ECN_THRESHOLD = 10`，而唯一會排隊的是
   `topology.json:65-69` 的 `[ "s1-p3", "s2-p3", "0", 0.5 ]`＝0.5 Mbit/s。**沒有整形的 fabric 上
   solution 臂必紅，而那不是 `ecn.p4` 的事**——spec 裡的 `"needs": "shaped_links"` 就是這件事，
   §2.4 也把 `ecn` 排在 G2-C 之前不進閘門。`mri` 的斷言只有 count 與 swid，不需要佇列
   （`qdepth` 刻意不斷言）；`qos` 的 topology **沒有**被節流的鏈路。
2. **兩支的紅臂不在資料面，而且兩個 fabric 上要讀成同一件事**（judge A6）。
   `flowcache` 停在 `p4c`（exit 1、verdict 寫 `skeleton does not compile, by design`）；
   `basic_tunnel` 停在控制面——tutorials 上 harness 在 `program_switches` 丟例外、
   NDTwin 上 pre-flight 拒絕那些 entry。兩者都是 **exit 1 而不是 exit 2**。
   🔴 **而且 `basic_tunnel` 骨架在兩個 fabric 上都印 `RED ARM (1/1): the skeleton does not get
   past the control plane, by design`／exit 1。** 第一版讓 `run_on_ndtwin` 回非零、`main()` 印
   `ERROR`；**第二版只修了 NDTwin 那半**——旗標掛在 `run_on_ndtwin` 上（只有 NDTwin 的路徑碰得到）、
   判定又寫 `args.fabric == "ndtwin"`，所以 tutorials 臂仍是 `PASS (1/1)`／exit 0。
   第三輪把旗標改成 module-level 的 `DESIGNED_REFUSAL`、兩條路徑都設、判定不問 fabric，
   並且**每一 round 開頭重設**（`06` 一個迴圈跑二十六 round，不重設就會報上一 round 的拒絕）。
3. **`qos` 的讀數只取 h1 送出的訊框**（judge A5）。`qos/receive.py:22` 沒有 BPF filter，
   h2 自己的回覆也在同一份 capture：UDP/4321 沒人聽 ⇒ ICMP port-unreachable（tos `0xc0`）、
   TCP 那輪的 SYN→80 ⇒ RST（tos `0x0`）。整份 capture 都讀進來的話，
   **骨架臂的 `set(tos) == {"0x1"}` 會在一個完全照 README step 1.6 行為的 fabric 上判紅**。
3. **`p4runtime`／`flowcache` 的控制器在兩個 fabric 上用兩個啟動方式。** tutorials 上它寫死的
   `127.0.0.1:5005N`／`device_id N-1` 就是真的；NDTwin 上不是，要走
   `tools/p4_exercise/run_external_controller.py`（TICKET-P1D 的 adapter，live-p1/03 用的同一支）。

### 6.3 通用格（`--fabric ndtwin` 的**解答臂**最後一步）

`G1  link usage follows the iperf path`：在 exercise 自己的步驟**之後**、teardown **之前**跑，
內容是 `live-p1/_common.sh` 的 `link_usage_round`——**live-p1/05 跑的是同一個函式**。
它量的是「iperf 期間 `/proc/net/dev` 上真的搬了位元組的 `sN-ethP`」對「twin 的
`link_bandwidth_usage_bps` 在同一視窗的積分」，斷言 on-path > 0、off-path 的**交換機間**邊 == 0。
這一格與 exercise 的**程式**無關。**它的紅綠鑑別力由 05 的第三組（`--telemetry none`）建立，
不是由這一格自己建立。**

🔴 **但它需要一條真的流，而有兩類臂沒有。** 工單 §2.7 寫「每一支」，實際上：

| 臂 | 跑不跑 | 理由 |
|---|---|---|
| 任何 **skeleton** 臂 | **不跑** | 骨架就是「這個 fabric 不該轉發」的 fabric。跑了會得到空的 on-path 集合，而那個集合空的時候 `assert_link_usage_follows_path` 會**拒絕**——拒絕得對，但講的是別的事。 |
| `source_routing` solution | **不跑** | `solution/source_routing.p4:127-138` 是 `if (hdr.srcRoutes[0].isValid()) {…} else { drop(); }`：**解答**把每一個沒有 0x1234 stack 的訊框丟掉。audit-raw `7af2f352` 當初就是用 send.py／receive.py＋ttl 量的，不是用 ping（TICKET-P2 §7-10 同一句）。 |
| `calc` solution | **不跑** | `calc.p4:205-210` 是 `if (hdr.p4calc.isValid()) {…} else { operation_drop(); }`：只認 0x1234 計算機協定，其餘全丟。 |
| `load_balance` solution | **不跑**（judge A3） | `s1-runtime.json:6-25` 的 `ecmp_group` 只有一條 lpm 條目 `10.0.0.1/32`（負載平衡的服務位址），default action 是 drop ⇒ iperf 打去**任何真實主機位址**都在 s1 被丟掉、on-path 空。改打 10.0.0.1 也救不回來：回程走 s2／s3，它們的表是同一條。 |
| `multicast` solution | 跑，**目的地 h3** | `sig-topo/s1-runtime.json:47-65` 只複製 port 1,2,3；h4 是 README:122 的 TODO，**設計上不通**。模型的「最後一台主機」正好是它。 |
| `p4runtime` solution | 跑，**目的地 h2** | 控制器只接 s1／s2、只裝 h1↔h2 那條 tunnel（`mycontroller.py:172-178`），s3／h3 從沒被碰過。 |
| 其餘 11 支 solution | 跑，目的地＝模型最後一台主機 | |

⇒ **實際會有 10 格**（13 減掉 `source_routing`、`calc` 與 `load_balance`）。
🔴 **不跑的那幾格是「NOT RUN ＋ 理由」寫進 report，不產生任何期望**——不是綠的，也不是紅的。
把一個沒有封包經過的 fabric 記成綠色，正是這整份工單一直在拒絕的形狀。

**目的地是量測的參數，路徑仍然是量出來的。** `link_usage_round` 的第五個參數只決定 iperf 打去哪裡；
on-path 集合永遠是 `/proc/net/dev` 的 tx_bytes 增量，沒有任何一條路徑是寫死的。

[Co-developed with claude code -- Adam]
