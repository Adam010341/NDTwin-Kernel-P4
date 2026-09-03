# FIX-PORT-TABLE — 一張宣告式的 port 表，取代四處各自為政的檢查

2026-09-03 夜間場｜branch `fix/ports-that-block-restart`｜[Co-developed with claude code -- Adam]

## 缺陷形狀

> 殘留檢查涵蓋的是**好命名的 port**，不是**擋住下一次 bring-up 的 port**。

`cmd_clean` 與 `deep_sweep` 各自 `for p in 8000 8080 8081`。其餘全部知道、全部寫下來、
**全部沒有被執行**——四段註解裡。2026-09-02 的代價是實測的：一個沒人啟動的 kernel 佔住
UDP `:6343`，正當的 Terminal 3 死在 `bind() to sFlow port 6343 failed`，而 `ndt down`
的五條斷言**全綠**。

兩個獨立原因，缺一不可：

1. `:6343` 不在任何一條檢查裡。
2. `port_open()` 只會講 TCP（`/dev/tcp`），`port_listener_pids` 用 `ss -ltnpH`——
   **就算當初有去看，也看不到 UDP。** 這一條之前沒人指出過。

## 那張表

`tools/test_workflow/ports.sh`，欄位 `spec|proto|plane|owner|consequence`。
`proto` 是欄位而不是假設，就是因為第 2 點。

| spec | proto | plane | owner | 別人佔住的後果（摘要） |
|---|---|---|---|---|
| 8000 | tcp | both | kernel 北向 API | 下一次 `up` 量到殘留 kernel，自己啟的那個死於 EADDRINUSE |
| 8080 | tcp | ovs | Ryu REST | kernel 從**上一輪**的 controller 拉拓樸與路徑 |
| 8081 | tcp | p4 | P4 proxy (uvicorn) | 同 8000，量到上一輪的 proxy |
| 6653 | tcp | ovs | Ryu OpenFlow | 存活的 Ryu 被下一輪的 switch 靜默認領；probe 6653→6633→退回 6653，「沒有 controller」與「錯的 controller」長得一樣 |
| 6633 | tcp | ovs | Ryu OpenFlow（無旗標時兩個都開） | 同上；只擋 6653 等於留一條繞路 |
| 6343 | **udp** | both | kernel sFlow collector | 下一個 kernel `bind()` 失敗，**所有 flow rate 與鏈路使用率讀成 0**，與閒置網路無法區分 |
| 30051-30060 | tcp | p4 | bmv2 simple_switch_grpc（每 device 一個） | orphan 佔住 → 下一個 fabric 綁不上，錯誤訊息長得像 P4 pipeline 問題 |
| 9091-9100 | tcp | p4 | bmv2 Thrift（每 device 一個） | 同一行程式指派兩者，只查一半等於半個檢查 |
| 9000 | tcp | apps | Simulation-Platform-Manager | 殘留者讓 sim 的存活判準通過而 app 其實不在（09-02 那一輪就是用 `:9000 有 listener` 當判準） |

`8001`（energy app）**沒有收進表裡**：repo 內沒有任何宣告，只在一份 run report 裡被觀測過一次。
要收，先找到宣告它的地方。

## 現在誰讀這張表

| 讀者 | 位置 | 讀法 |
|---|---|---|
| `cmd_clean` | `ndt` | `ndt_port_residue all`；每列印持有者與後果 |
| `deep_sweep`（`--deep`） | `ndt` | 逐列 kill；訊息帶上 `$consequence` |
| bring-up guard `preflight` | `ndt` | `ndt_port_residue "$mode"`，**只警告不改 return** |
| `up_p4` 的 orphan 分支 | `ndt`（原 :635） | 印實際被佔的 P4 ports，取代「數幾個 process」 |
| `stack.sh cmd_down` | `stack.sh` | 保留 ours/stray 判定，port 集合改讀表——🔴 **改動在工作樹裡，未進本 commit**，見下 |

🔴 **`tools/test_workflow/stack.sh` 沒有進這個 commit。** 我開工前它就已經有**別的 agent 的
未提交修改**（`supervise.sh`／`report_exit`／B-5 crash reporting，177 行）。CLAUDE.md 的規則是
列到檔案，但**列到檔案擋不住同一個檔案裡別人的 hunk**——`git commit -- stack.sh` 會把他們的
工作一起帶進一個沒有描述它的 commit message。所以我的三處 stack.sh 修改（source ports.sh、
`cmd_down` 的 port 迴圈改讀表、`ss -ltnp` 那行建議改寫）**留在工作樹裡未提交**，等 stack.sh
的擁有者先提交後再單獨提交。引用時請註明這是**未提交的觀測**。

`preflight` 為什麼只警告：`ndt up` 打在已經起來的 stack 上時，`:8000`／`:6343` 由**它自己的
kernel** 持有，硬失敗會讓 reuse 路徑不能用。分辨自己人要 pidfile 歸屬判定，那在 `stack.sh`
的 `port_owner_verdict`／`wait_for_port`，而且**那裡本來就會拒絕**。缺的從來不是拒絕，是
**沒有人講出那個 port 的名字**。

## 四段註解的現況（逐一）

| 原始位置 | 現況 | 是否與新表衝突 |
|---|---|---|
| `ndt:635`（`:3005x` 讓下一個 fabric 綁不上） | **已改寫**。行為移進 ports.sh 的 30051-30060 列，該分支現在印真正被佔的 port | 否 |
| `ovs_4host_topo.py:31`（probe 靜默遮蔽不存在的 controller） | **已補**。保留「為什麼這裡寫死 port」的理由，指向 6653/6633 兩列 | 否 |
| `stack.sh:782-798`（原任務單寫 :676；probe 順序＋`0.0.0.0:30051-30060`） | **已補**。保留 2026-08-21 三臂實測與**排序**論證（表裝不下），加上「改 port 要一起改列」 | 否 |
| `ndtwin-lab:141,152`（原任務單寫 :337/348——**該檔只有 226 行，那兩個行號不存在**） | **已補**兩處。點出這裡無法分辨是哪一輪的 Ryu，那是 6653/6633 列的工作 | 否 |

## Mutation gate

- 測試 `tests/shell/test_ports_that_block_restart.sh`（18 checks）
- 閘門 `tests/shell/mutate_ports_that_block_restart.sh`
- 結果：**`9 mutations, 0 survived`**；baseline byte-identical（ports.sh 與 ndt 都沒被寫過）

🔴 **不在原本三個之內的鑑別力**（這是重點——舊的鑑別力檢查是拿 `:8081` 驗的，
而 `:8081` 正是壞版本已經涵蓋的三個之一，所以它不可能失敗）：

- 機制類案例全部把 holder 綁在 **45901/45902**，並經 `NDT_PORT_TABLE` 注入，**零 lab 接觸**。
- **M4**（`ndt_port_open` 忽略 proto，退回 TCP-only）只有在 **UDP** port 上才觀察得到——
  這正是 `:6343` 當初隱形的機制。
- **M8**（residue 不管有沒有人佔都回報）由「free port 必須安靜」的對照組抓到；沒有它，
  上面每一條「抓到了」都可能來自一個從不去看的函式。
- **注入先斷言注入成功**：每個機制案例先 `ndt_port_open` 確認真的有人佔住，再斷言工具的反應。

**Live 佐證**（fabric 已停，`:30051` 空著，綁 25 秒後放掉）：

```
XX  residue: python3 pid 1642032 holding :30051 (tcp)
XX           -> owner: bmv2 simple_switch_grpc, one port per device (grpc_ports.py GRPC_PORT_BASE + N)
XX           -> if something else holds it: an orphan holding one makes the next fabric fail to bind, ...
not clean
```

同樣情境在修改前是 **clean**。

## Exit code（依指示未動）

`cmd_clean` 仍是 0=clean／1=not clean，`stack.sh cmd_down` 仍是 `leftovers>0 → 1`。
**沒有新增第三種狀態，沒有重新定義任何代碼的意義。**

但要講清楚一件事給合併的人：**同一個代碼現在會在更多情況下正確地觸發**——`:6343`／`:30051`
等被佔住時 `ndt clean` 會紅，這在修改前是綠的，而那正是本次修復的全部目的。
若接手的三態分支認為這需要協調，這是唯一的接觸面。

## 留下沒做的

1. **`--deep` 的殺傷範圍擴大了**：從 3 個 port 變成 9 個 spec（含 30051-30060、9091-9100 共 20 個 port）。
   已補上拒絕訊號自己、`$PPID`、自己 pgid 的保護，但 `--deep` 仍未經實機驗證（不動 lab）。
2. **`ndt status` 仍自帶 `:8000/:8081/:8080` 三個字面值**（`ndt` 內約 :1343-1345）——同一形狀，
   本次未改，因為它是顯示而非閘門。建議接手一併改讀表。
3. **`8001`（energy）未收表**，理由如上。
4. `ndt_port_open` 回傳 2（探測不到，例如沒有 `ss` 的機器）在 `cmd_clean` 被當成 not-clean。
   本機有 `ss`，**這條路徑沒有被實機走過**，只有單元層級的設計；接手若要依賴它請先驗。
