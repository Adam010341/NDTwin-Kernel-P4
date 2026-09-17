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

目前腳本化的只有 **`source_routing`** 與 **`basic`**，其它會印 "not scripted yet" 然後 exit 2。

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
