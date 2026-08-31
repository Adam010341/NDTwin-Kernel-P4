# E 與 F-5 儀器節的並排 diff（**待裁：每列判哪一邊對**）

[Co-developed with claude code -- Adam]

**為什麼有這張表**：reviewer 線在 PREREG-B 掃到「註冊了 binary 身分、卻沒有一句說 fabric 怎麼被
指到那顆 binary」。auditor 判斷 E 有同樣的暴露面，並指出**同一批寫出來的多張預註冊，儀器節要彼此
對 diff**——這種漏法在單張檔案內看不出來，只有並排才顯形。
本表比對 `2026-08-31_sampling-ceiling-after-merge/PREREG.md` §2/§4 與
`2026-08-31_f5-fine-grid-round/PREREG.md` §2/§4，**逐項列出「一張有、另一張沒有」**。
時點：2026-08-31，兩輪皆未接觸資料。

## 並排結果

| # | 條款 | E | F-5 | 我判 | 不補的話會怎樣 |
|---|---|---|---|---|---|
| 1 | **括號式 `/proc/<pid>/exe` 身分，首尾各一次、不符即作廢** | ❌ 只寫「四格各記 kernel 與 proxy 的 sha256」，**未說取自何處**，也沒有首尾 | ✅ §4 F4 | **F-5 對，E 補** | E 的 `BL`/`M` vs `P`/`MP` 是換 binary 的兩臂；身分若取自編譯產物，四格全跑同一顆也會記出一份**完全正確**的身分檔 |
| 2 | **明文區分「跑起來那顆」與「編出來那顆」** | ❌ | ✅（「**不是磁碟檔、不是 `ndt status` 的 code 欄**」） | **F-5 對，E 補** | 同上；這是唯一能否證第 1 列那個失效模式的敘述 |
| 3 | **binary 換裝之間 fabric 全拆重起＋換裝雙向複驗** | ❌ | ✅ §4 | **F-5 對，E 補** | E 每格都在換 kernel 臂，換裝比 F-5 頻繁得多（96 格會換約 48 次），卻沒有換裝條款 |
| 4 | **kernel tree 釘凍結時 tip；窗內主樹不得有行為相關未 commit 改動** | ❌ | ✅ §4（輔助判準） | **F-5 對，E 補** | E 的窗長達數小時，中途有人 commit 就無法事後界定「那顆是從哪棵樹來的」 |
| 5 | **窗內禁 commit/build/VM 的條款「照 note 格式進 claim，係註冊條款不是備忘」** | 🟡 有禁令、**未說要進 claim note** | ✅ §4 | **F-5 對，E 補** | 寫在預註冊而不在 claim 裡的禁令，別的 session 看不到——而它要擋的正是別的 session |
| 6 | **組態常數逐格斷言**（E：`truncate=128` 四格一致並**在每格斷言它**） | ✅ §4 | ❌ 兩臂跨 P4／OVS，**取樣組態未凍、未斷言** | **E 對，F-5 補** | F-5 的 Q1/Q2 比兩顆 binary；若兩臂的 `SAMPLE_RATE`／`truncate` 不同，窗分布的差異會被歸給 T-11 |
| 7 | **閘門／偵測器雙向 force 的註冊條款** | ✅ §2.4（五次，逐項寫實作） | ❌ **完全沒有** | **E 對，F-5 補** | 「零幽靈」與「偵測器壞了」長得一模一樣。我在腳本裡做了三向合成 force，但**腳本不算註冊**——換人跑就沒了 |
| 8 | **「預註冊寫幾項檢查，腳本就要有幾個對應呼叫」的元條款** | ✅ §2.3 | ❌ | **E 對，F-5 補** | 這條正是 D 輪被 grep 抓出來才立的；只寫在 E 等於只保護 E |
| 9 | **儀器的已知非空前置檢查** | ✅ §2.1 | 🟡 TR-3 harness 內有 control，**F-5 §2 未註冊** | **E 對，F-5 補** | 未註冊的 control 可以被下一版腳本刪掉而不留痕跡 |
| 10 | 🔴 **fabric 怎麼被「指到」某一臂的 binary（指定機制）** | ❌ | ❌ | **兩張都缺** | 見下方「兩張都缺的兩條」 |
| 11 | 🔴 **bmv2 binary 的身分** | ❌ §4 只寫「kernel 與 proxy」 | ❌ 只寫「兩顆 binary」（指 kernel） | **兩張都缺** | 同上 |
| 12 | 取樣器自身列為已註冊共變量 | ✅ §4 | ✅ §2 | 兩張都有 | — |

## 兩張都缺的兩條（並排才看得出來，這是本表最主要的產出）

### 🔴 第 10 列：指定機制沒有被註冊，只活在腳本裡

- **E**：kernel 臂＝把 staged 檔 `cp` 覆蓋 `build/bin/ndtwin_kernel`，因為
  `tools/test_workflow/stack.sh:766` 把它寫死：
  `bash -c "cd '$KERNEL_DIR/build' && ./bin/ndtwin_kernel ..."`。
  🔑 **好消息**：那是 `./bin/...` ＝**相對路徑**，不是裸名 ⇒ **kernel 不走 PATH 查找**，
  PREREG-B 那個變體在 E 身上不會發生。剩下的失效路徑是「`cp` 沒落地」「前一格的行程活過
  `stack.sh down`」「swap 與 exec 之間有人重編」——三者都只有比對**跑著那顆**才抓得到。
- **F-5**：pre/post-T-11 換裝同理。
- **兩張都沒有一句話說這件事。** 寫在腳本裡不算註冊：換人跑就沒了。
- **建議補的條款（兩張同文）**：
  > 臂的指定機制：kernel 臂＝以 staged binary 覆蓋 `build/bin/ndtwin_kernel`（`stack.sh` 以
  > 相對路徑 exec 它，不經 PATH）。**每格／每臂在 bring-up 之後、量測之前，比對
  > `/proc/<pid>/exe` 的 sha256 與該臂 staged 檔 `.provenance` 記載的 sha256**；不符即中止。
  > 讀不到 `/proc/<pid>/exe` **算中止，不算通過**。

### 🔴 第 11 列：bmv2 的身分，兩張都沒點名——而 E 的天花板就是它決定的

- E 的取樣發生在 P4 pipeline 裡（`SAMPLE_RATE`／`truncate` 是編進 bmv2 JSON 的），
  ⇒ **bmv2 是這一輪最吃重的 binary，而它是唯一沒被點名的那顆。**
- 這還是**跨輪的退步**：D 輪的 `ladder_ext.sh:82` 就記著
  `sha256sum /usr/local/bmv2-fast/bin/simple_switch_grpc`，E 的預註冊把它掉了。
- 機制實況（已查證）：`p4_proxy/mininet/p4_testbed_topo.py` 以
  `p4_proxy/mininet/bmv2_binary_override` 的第一行非註解行決定啟動哪顆；目前directive＝
  `/usr/local/bmv2-fast/bin/simple_switch_grpc`。
  🔑 **該檔的註解逐字記著這個坑真的發生過**：曾經寫成裸名 `"simple_switch_grpc"` ⇒ PATH 查找
  ⇒ 解析到 stock `-O0` build，「silently benchmarked a binary roughly 10x slower while every
  filename, note and slide still said fast」。
  🔑 **2026-08-22 起缺 directive 是 REFUSAL 不是 fallback** ⇒ 裸名那一支在本機已封。
  但**檔案內容仍是自由變數**，而沒有任何一張預註冊記它。
- **建議補的條款（兩張同文）**：
  > 每格／每臂記錄 `bmv2_binary_override` 的 directive 行與該檔 sha256，**並從 `/proc` 取每一台
  > 執行中 `simple_switch_grpc` 的 exe sha256**；十台必須是同一顆，否則該格作廢。
  > （技術先例：`doc/audit/2026-08-22_stock-control-ladder/` 的兩臂就是
  > 「each arm verifying **from /proc** which binary the live switches actually run」。）

## 已落地的部分（E 側，含雙向 force）

第 1／2／10／11 列已寫進 `lib_e.sh`／`run_e.sh` 並在 `gates_e.sh` 加了 **G8**：

- `check_running_arm` 回三種 verdict：`MATCH` / `MISMATCH` / `UNREADABLE`。
- **兩個「不檢查也會過」的洞已封**：
  ①**哨兵值**——`running_kernel_sha` 失敗時回 `NO-KERNEL-PROCESS`／`UNREADABLE`，
  而**兩個哨兵彼此相等** ⇒ 用它做首尾對帳會**空洞地通過**。現在加 64-hex 形狀檢查，
  讀不到＝中止。②**靜默跳過**——通過的判準是輸出裡有 `verdict=MATCH`，**不是 exit code 0**，
  所以「檢查沒跑到」不可能被讀成通過。
- **G8 已三向 force 過（dry-run，本機，無 fabric）**：
  `MATCH`（正確臂）／`MISMATCH`（指到另一臂）／`UNREADABLE`（`/proc` 讀不到）全部可達。
  實跑版的 force-red＝在 1 Hz 臂執行中拿 1 kHz 臂的 provenance 去比，必須 `MISMATCH`。
- `record_bmv2_identity` 記 directive＋各交換機 `/proc/<pid>/exe`，**十台不同一顆就中止**。

🔴 **F-5 側（第 6/7/8/9 列）我沒有自行補**——那是把 E 的條款搬進 F-5，屬於修訂，等你判完再落。
F-5 只修了與 E 相同的哨兵洞（`run_f5.sh` 的首尾括號原本也會空洞通過）。
