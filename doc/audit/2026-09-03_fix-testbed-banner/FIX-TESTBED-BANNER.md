# FIX-TESTBED-BANNER — 收尾橫幅改成讀它自己底下那 128 個 ping

FINDINGS-ALL #42（coverage 標「最該先派 #3」）的離線那一半。

- 分支：`fix/testbed-banner-reads-its-ping`，基底 trunk `431d98a5`
- 檔案：`testbed_topo.py`（**repo 根目錄**，不是 finding 寫的 `tools/test_workflow/`）
- 日期：2026-09-03

[Co-developed with claude code -- Adam]

---

## 1. 缺陷本身

`testbed_topo.py` 在建好 128 台主機、灌完靜態 ARP 之後，開 128 條執行緒橫跨 fabric 打 ping
（64 對主機、雙向），join 完之後印：

```
--- Final Configuration Active ---
Host internet: OK | sFlow reachability: OK | Switch identification: OK
```

**這三個 OK 跟那 128 個 ping 之間沒有任何資料流。** 三段都是常數：

- `ping_test()` 只 `print`，回傳 `None`；
- `threading.Thread` 連 `None` 都丟掉——thread 不會把 target 的回傳值交給任何人；
- 橫幅是 `print("Host internet: OK | ...")`，一個 literal。

實測（2026-09-03）：128 個 ping 全部 100% loss，三個 OK 照印。這是「儀器說謊」那一族——
錶面上的指針是畫上去的。

還有第二層問題，是修的時候才看清楚的：**這三個宣稱，ping 只撐得起其中一個**。

| 原本的宣稱 | 這支腳本裡有沒有量它 |
|---|---|
| `Host internet: OK` | ping 有量「主機之間通不通」。但這些 ping 從沒離開 `10.0.0.0/24`，跟 internet 無關——**用詞本身也是錯的** |
| `sFlow reachability: OK` | **完全沒量**。`enable_sflow()` 的 `ovs-vsctl` 走 `os.system`，狀態直接丟掉；這支腳本從來沒讀回任何一個 datagram |
| `Switch identification: OK` | **完全沒量**。agent 位址在上面指派完就沒再跟任何東西對過 |

所以修法不只是接線，用詞也得改。

參考形狀在 repo 裡本來就有：`tools/test_workflow/ovs_4host_topo.py` 的收尾橫幅只陳述
**建了什麼**（數量、位址、model 檔路徑），一個健康宣稱都不打。

---

## 2. before / after

### before（`testbed_topo.py:142-149, 228-247`）

```python
def ping_test(src, dst_ip):
    print(f"Pinging from {src.name} to {dst_ip}...")
    result = src.cmd(f"ping -c 1 {dst_ip}")
    print(f"Result from {src.name} to {dst_ip}:\n{result}")     # 回傳 None
...
        threads = []
        for i in range(int(HOST_NUM / 2)):
            t = threading.Thread(target=ping_test, args=(client, server_ip))   # 回傳值丟掉
            ...
        for t in threads:
            t.join()

        print("\n--- Final Configuration Active ---")
        print("Host internet: OK | sFlow reachability: OK | Switch identification: OK")
```

### after

新增五個 module-level 的東西（都可離線 import、可測）：

| 名稱 | 做什麼 |
|---|---|
| `parse_ping_output(text)` | 從 ping 的 statistics 行讀出 `(transmitted, received, loss_pct)`；**讀不到就回 `None`**，不猜 |
| `PingResult` | 一個 ping 的量測結果。`reached` = `parsed and received > 0`——**讀不懂的輸出永遠不算「通」** |
| `PingResults` | 執行緒安全的 sink。thread 會丟掉回傳值，所以這是數字唯一到得了橫幅的路 |
| `summarize_pings(results, expected)` | 收成 `PingSummary`。`expected` 是**發出去幾個 ping**，從外面傳進來 |
| `banner_lines(summary)` | 橫幅，只從 summary 推導 |

`ping_test(src, dst_ip, sink=None)` 現在 **回傳** 結果，並在有 sink 時寫進去；
`src.cmd` 丟例外（namespace 被拆、mnexec 死掉）也記成一筆失敗，而不是讓 thread 死掉、
什麼都不留。

`run_ping_self_test(net, host_num)` 把原本 `__main__` 裡那兩段迴圈搬進來，
`expected = 2 * pairs` 在開執行緒**之前**就算好。

`__main__` 變成：

```python
        ping_summary = run_ping_self_test(net, HOST_NUM)

        for line in banner_lines(ping_summary):
            print(line)
```

### 橫幅實際長相（四條路都跑過）

```
--- Final Configuration Active ---
host reachability: OK -- 128/128 pings replied (0.0% loss)
sFlow reachability: NOT MEASURED (configured above, never read back here)
switch identification: NOT MEASURED (agent IPs assigned above, never verified here)
```

```
--- Final Configuration Active ---
host reachability: FAIL -- 0/128 pings replied, 128 lost (100.0% loss)
  the Mininet CLI below is still available -- the fabric is built, not forwarding
sFlow reachability: NOT MEASURED (configured above, never read back here)
switch identification: NOT MEASURED (agent IPs assigned above, never verified here)
```

```
--- Final Configuration Active ---
host reachability: FAIL -- 64/128 pings replied, 64 lost (50.0% loss)
  ... 64/128 pings reported a result at all; the rest are missing, which is not the same as passing
  the Mininet CLI below is still available -- the fabric is built, not forwarding
...
```

```
--- Final Configuration Active ---
host reachability: FAIL -- 128/128 pings replied, 0 lost (0.0% loss)
  ... covering only 64/128 distinct host pairs; a result recorded twice is a copy, not a second measurement
  the Mininet CLI below is still available -- the fabric is built, not forwarding
...
```

沒量的兩項**保留、標 NOT MEASURED**，不是刪掉——刪掉了下一個讀的人只會再補一個 OK 回去。
那兩項真正被檢查的地方是 `ndt up ovs` 的 `verify_sflow`。

---

## 3. 幾個判斷，寫下來

### 3.1 partial loss 怎麼算（假設，明講）

**零容忍：只要有一個 ping 沒回就是 FAIL，沒有門檻。**

依據：這個 topology 在打 ping 之前已經替**每一台對每一台**灌了靜態 ARP
（`testbed_topo.py` 那個 128×127 的 `arp -s` 迴圈），controller 也會裝 proactive rule。
在這種前提下掉一個 ping 是 fabric 有問題，不是雜訊。
`ovs_4host_topo.py` 的註解也把「128/128 hosts carrying IPs」當成好的狀態記下來。

刻意**不做**可調門檻：門檻會被人從 0 一路調到 100 而沒人發現。要放寬是要寫進
`PingSummary.ok` 的決定，不是看著橫幅一直綠而慢慢默認的。

### 3.2 `expected` 為什麼跟 `attempted` 分開

分母必須是**發出去幾個**，不是**回來幾個**。

某條 thread 死在記錄之前，它不會留下一筆失敗——`replied / attempted` 是 64/64＝完美，
`replied / expected` 才是 64/128。空 list 上任何比值都是 0/0，讀起來像「什麼都沒出錯」。

### 3.3 `distinct` 這一欄（自己的測試抓到的）

第一版的 `ok` 是 `expected > 0 and attempted == expected and replied == expected`。
自己寫的 `test_a_result_recorded_twice_does_not_fill_in_for_a_missing_one` 當場把它打紅：
64 筆結果各記兩次 → `attempted` 128、`replied` 128，**全部條件成立、判定 OK**。
所以加了第四欄 `distinct`＝不重複的 `(src, dst)` 對數。**複製的單位不是第二次量測。**

`ok` 的四個 clause 每一個都有一個「只有它擋得住」的形狀，M6/M7/M8/M9 各對應一個。

---

## 4. 讀過的 caller，跟 exit code 的決定

| caller | 它怎麼跑這支腳本 | 有沒有讀 exit code |
|---|---|---|
| `tools/test_workflow/stack.sh:63-72` `prompt_for_mininet()` | **只把指令印出來**（`sudo python3 $script`）然後 `read` 等操作員按 Enter。註解寫得很清楚：Mininet 要 root、而且會掉進互動 CLI，所以 stack.sh 不自己跑它 | 沒有——根本沒執行 |
| `tools/test_workflow/stack.sh:775` | `script="$OVS_TOPO_SCRIPT"`，值來自 `components.env:80` = `$KERNEL_DIR/testbed_topo.py` | 同上 |
| `tools/test_workflow/ndtwin-lab:571-580` `ovs-topo-start` | `tmux new-session -d -s topo ... "$NTG_PY" /home/adam/Network-Traffic-Generator/testbed_topo.py`——detached tmux，**而且跑的是 NTG 那份，不是這份** | 沒有 |
| `tools/test_workflow/ndt:878, 901` | 只是說明文字＋拒絕非 4/128 的 host 數 | 沒有 |
| `tools/test_workflow/faults.sh:146, 538` `topo_pid` | 用**名字**比對行程 | 沒有 |
| `tests/python/test_ovs4_sflow.py:59, 169-176` | 把這個檔當**參考檔**，regex 抓 `header=/sampling=/polling=` | 沒有（不執行） |

**決定：自我測試失敗時 `raise SystemExit(1)`，位置在 `CLI(net)` 之後、`finally` 清理之後。**

理由三條：

1. **不會弄壞任何現有東西**——上表沒有一個 caller 讀它的 exit code。
2. **還是要設**——一支量到 100% loss 卻 exit 0 的腳本，就是這次要修的橫幅缺陷往下一層而已。
3. **位置**：fabric 壞掉的時候操作員更需要那個 CLI，不是更不需要。所以不提早退出；
   `finally` 裡的 `ip addr del` 與 `net.stop()` 照常跑完（`SystemExit` 是在 try/finally 之外才拋的）。

`ping_summary` 在 `try` 之前先綁 `None`，所以「自我測試失敗」跟「根本沒跑到自我測試」分得開。

---

## 5. 紅過才算數

測試檔：`tests/python/test_testbed_banner.py`，45 個 case，mininet 用 stub，
不需要 fabric、不需要 root、不需要第三方套件。`TESTBED_TOPO_UNDER_TEST` 可指到別的檔
（mutation gate 就是這樣用的）。

**紅**：把 `431d98a5` 的原始 `testbed_topo.py`（sha256
`e2079a5966eff991ffa285fb8c43e7f1a43a043bd5d9802efd0f566c6773705f`）取出來，
新測試打它：

```
$ TESTBED_TOPO_UNDER_TEST=<431d98a5 的原始檔> python3 tests/python/test_testbed_banner.py
...
Ran 45 tests in 0.022s

FAILED (failures=8, errors=36)
```

45 個裡 44 個紅（唯一綠的是 `test_it_pings_the_address_it_was_given`——舊版確實也送
`ping -c 1 <ip>`）。8 個 `FAIL` 是**接線**那組，也是最該看的四行：

```
FAIL: test_the_bring_up_runs_the_self_test
AssertionError: 'run_ping_self_test' not found in {'find_ovs_agent_iface', 'CLI', 'enumerate',
'setLogLevel', 'Mininet', 'print', 'range', 'int', 'enable_sflow', 'MyTopo'} : the bring-up never
runs the ping self-test, so the banner below it is printed from nothing -- the defect, exactly

FAIL: test_no_health_claim_is_spelled_as_a_constant_in_the_bring_up
AssertionError: Lists differ: ['Host internet: OK | sFlow reachability: OK | Switch identification: OK'] != []
... : the bring-up block still contains hard-coded OK text:
['Host internet: OK | sFlow reachability: OK | Switch identification: OK']

FAIL: test_the_banner_is_printed_from_the_self_tests_result
AssertionError: set() is not true : run_ping_self_test's result is not assigned to anything

FAIL: test_the_run_exits_non_zero_when_the_self_test_failed
AssertionError: [] is not true : the bring-up exits 0 whatever the self-test measured
```

**綠**：

```
$ python3 tests/python/test_testbed_banner.py
Ran 45 tests in 0.040s

OK
```

### 測試分組

| class | 擋什麼 |
|---|---|
| `PingOutputIsRead` | parser 本身。iputils／BSD 兩種拼法、`+1 errors` 不能把 loss 讀成 1%、沒有 statistics 行時**回 None 不猜** |
| `OnePingReportsWhatItMeasured` | `ping_test` 回傳、寫進 sink、`cmd` 丟例外時記成失敗而不是消失 |
| `TheSummaryCannotPassVacuously` | 0/0、結果沒回來、結果被記兩次、比發出去的還多、讀不懂的輸出 |
| `TheBannerCarriesTheNumbers` | 壞的路上**任何地方都不能出現 OK**；好的路上必須有 OK 而且不能有 FAIL（control）；數字要帶到 |
| `TheSelfTestMeasuresTheFabric` | `run_ping_self_test` 在假 net 上端到端跑：全好／全壞／一半／全丟例外／sink 會掉結果 |
| `TheSelfTestIsWiredToTheBanner` | 🔴 **存在≠接線**。讀 `__main__` 的 AST：自我測試有沒有被呼叫、`banner_lines` 拿到的是不是它的結果、那個區塊裡有沒有常數 OK、`SystemExit` 有沒有被量測結果守住 |

---

## 6. Mutation gate

`tests/shell/mutate_testbed_banner.sh` — **25 個 mutation，0 存活**。

```
$ bash tests/shell/mutate_testbed_banner.sh
baseline (must be green before any mutation):
OK
  caught   M1 ... (25 行，全部 caught)
baseline byte-identical: yes (testbed_topo.py efbc4f88aadb6de9decaecaea640622434e95990e37b4a862df6a526f789bb88)
mutation gate: 25 mutations, 0 survived
```

Mutation 一律套在 `$BK/<label>/` 底下的**複本**上，用 `TESTBED_TOPO_UNDER_TEST` 指過去；
anchor 必須唯一（不唯一就 assert 失敗）；跑完重算 `testbed_topo.py` 的 sha256 確認沒被寫過。

| # | 方向 | mutation | 必須變紅的 case |
|---|---|---|---|
| M1 | defect | 常數三 OK 橫幅原樣裝回去 | `test_no_health_claim_is_spelled_as_a_constant_in_the_bring_up` |
| M2 | defect | bring-up 不再跑自我測試 | `test_the_bring_up_runs_the_self_test` |
| M3 | defect | `banner_lines` 有被呼叫，但傳的不是量到的東西 | `test_the_banner_is_printed_from_the_self_tests_result` |
| M4 | defect | ping 的結果進不了 sink（只 return 給 thread） | `test_the_result_reaches_the_sink` |
| M5 | defect | 不管量到什麼都 exit 0 | `test_the_run_exits_non_zero_when_the_self_test_failed` |
| M6 | loosening | `expected >= 0`：0 個 ping 算通過 | `test_measuring_nothing_is_not_passing` |
| M7 | loosening | 拿掉 `attempted` clause | `test_more_results_than_pings_launched_is_not_ok` |
| M8 | loosening | 拿掉 `distinct` clause | `test_a_result_recorded_twice_does_not_fill_in_for_a_missing_one` |
| M9 | loosening | `replied >= 0`：不再看掉包 | `test_total_loss_is_not_ok` |
| M10 | loosening | `lost = len(results) - replied`：沒回報的從分母消失 | `test_results_that_never_arrived_are_lost_not_absent` |
| M11 | loosening | 一個 ping 都沒有讀成 0% loss | `test_measuring_nothing_does_not_report_zero_loss` |
| M12 | loosening | `reached` 不再看 `parsed`：讀不懂算通 | `test_unreadable_output_is_not_reached` |
| M13 | defect | 讀不懂的輸出用猜的（回 `(1,1,0.0)`） | `test_output_with_no_statistics_line_is_unreadable_not_perfect` |
| M14 | defect | regex 把 loss 讀成 `+1 errors` 的那個 1 | `test_the_errors_field_does_not_confuse_the_loss_percentage` |
| M15 | defect | `except Exception` 收窄成 `except ValueError`：跑不動的 ping 消失 | `test_hosts_that_cannot_be_reached_at_all_still_report` |
| M16 | loosening | `expected = 0`：什麼都不缺 | `test_a_healthy_fabric_passes` |
| M17 | loosening | 分母改讀 `len(sink.all())`（自我指涉） | `test_results_lost_on_the_way_back_are_still_counted_as_pings` |
| M18 | defect | 失敗分支也印 OK | `test_total_loss_does_not_say_ok_anywhere` |
| M19 | defect | 沒量的那項又被宣稱 | `test_the_unmeasured_claims_are_not_claimed` |
| M20 | defect | 失敗訊息不再帶數字 | `test_total_loss_carries_the_counts_it_was_computed_from` |
| M21 | defect | 短少被診斷成重複（訊息把人指去錯的地方） | `test_missing_results_are_named_as_missing` |
| N1 | **control** | 沒有任何 fabric 通得過 | `test_a_healthy_fabric_says_ok_with_its_numbers` |
| N2 | **control** | 橫幅只剩失敗分支 | `test_a_healthy_fabric_says_ok_with_its_numbers` |
| N3 | **control** | 每個 ping 都讀不懂，所以每個 fabric 都壞 | `test_a_reply_is_read_as_a_reply` |
| N4 | **control** | 無條件 `raise SystemExit(1)` | `test_the_exit_status_is_conditional_on_the_measurement` |

### 寫 gate 的過程裡真的抓到兩件事

1. **M11 第一版存活。** 原本掛在 `test_no_result_at_all_from_a_fabric_that_was_pinged`，
   但那個 case 發了 128 個 ping，永遠走不到 `expected <= 0` 那個分支。
   那一輪**整體是紅的**（紅在別的 case），但**那個被點名的 case 沒紅**——
   「suite 有反應」跟「這個 case 證明了什麼」的差別就在這裡。改掛到真的除以零的 case 才 caught。
2. **N4 第一版也會存活**（如果只有「有沒有非零 SystemExit」這個 case）。所以加了
   `test_the_exit_status_is_conditional_on_the_measurement`：檢查那個 raise 有沒有被
   讀得到量測結果的 `if` 守住。

---

## 7. 其它沒動的東西都沒動

`tests/python/` 全部 29 支（28 支既有＋新的這支）都跑過：

```
test_chaos_c07_control.py                  rc=0   OK
...
test_ovs4_sflow.py                         rc=0   OK          ← 它 regex 讀這個檔的 sFlow 參數
test_p4_power_helper.py                    rc=0   OK
test_sflow_stats_endpoint.py               rc=0   OK          ← 用 p4_proxy/venv/bin/python
test_testbed_banner.py                     rc=0   OK
...
non-zero: 0
```

`git merge-tree --write-tree trunk fix/testbed-banner-reads-its-ping` → rc=0，
tree `d38cdf234cb74371d428290eaf09b16c66622eef`，無衝突。

### `check_gate_anchors.py` 讀得到這個 gate 嗎——讀得到，但過程發現工具的一個洞

```
$ python3 tests/shell/check_gate_anchors.py fix/testbed-banner-reads-its-ping --gates mutate_testbed_banner.sh
mutate_testbed_banner.sh  ok(23)
1/1 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
```

全 repo 掃描 trunk 與本分支逐列比對，**只多一列 `mutate_testbed_banner.sh ok(23)`**，
其餘 13 個 not-ok／10 個 NOT CHECKED 兩邊一模一樣（37/50 → 38/51）。

🔴 **但第一次跑是 `MISSING:23`。** `testbed_topo.py` 在 **repo 根目錄**，
而 `check_gate_anchors.py` 判斷「這個參數是不是檔案」是用
`return v if (v is not w and "/" in v) else None`（`path_at`，約 754 行；
`default_file_of` 約 541 行同一條規則）。`_repo_relative` 把 `$REPO/testbed_topo.py`
變成 `testbed_topo.py`——**沒有斜線**，兩條解析路徑都判定「不是檔案」，
23 個 anchor 全部落到這個 gate 唯一帶斜線的字串
`tests/python/test_testbed_banner.py` 上，然後回報 MISSING:23。

**注意失敗的方向**：這不是工具大聲說「我看不懂」（那是 `NO-ANCHORS`／`UNPARSED`，
它設計上會吼），而是一個**有自信的錯誤答案**——對一個 gate 根本沒碰過的檔案報 MISSING。
輸出上目前分不出這兩者。

本分支的處理是在 **gate 自己**加一個 workaround 並寫清楚原因：
`TOPO="$REPO/./testbed_topo.py"`（保留一個斜線；git 解得開 `<rev>:./testbed_topo.py`，
bash 也一樣）。**這是繞過，不是修好**——工具本身該修，已開背景任務
「Teach check_gate_anchors to address repo-root files」。這是 repo 裡第一個目標在根目錄的
mutation gate，下一個不知道這件事的人會再中一次。

---

## 8. 沒做的（明講）

1. 🔴 **fabric 為什麼 100% loss——沒查。** 那是 lab 那一半，本任務範圍外，
   而且需要動 lab。這次的修改只保證「橫幅會把它說出來」，不保證「它不會發生」。
2. 🔴 **`/home/adam/Network-Traffic-Generator/testbed_topo.py` 沒改，而那是
   `ndt up ovs` 真正執行的那一份。**
   - repo 這份：`testbed_topo.py`，修好了。
   - NTG 那份：sha256 `ead4d84a862ccd94368c9aca86cf52450ed7ebd9ef06e50546ada458ab4130b2`，
     另一個 git repo（HEAD `6e3f388`），**第 233-234 行帶著一模一樣的常數三 OK 橫幅**，
     `ping_test` 也一樣不回傳。它跟 repo 這份的差異是：多了兩行 `sys.path.append`、
     import NTG 的 `command_line`、把 `CLI(net)` 換成 `command_line(net, "NTG.yaml")`、
     少了 `polling=0` 那段推理註解。
   - 也就是說：**`ndtwin-lab ovs-topo-start` 那條路上操作員看到的橫幅，現在還是舊的那個。**
     要不要一起改是 auditor 的裁決（跨 repo，本任務沒授權動）。
   - 沒有替 NTG 那份寫一個「兩份要一致」的測試，因為它現在就會紅，而我不能改它——
     一個永遠紅的測試比沒有測試更糟。這裡用文件記著。
3. **`sFlow reachability` 與 `switch identification` 沒有補上真的量測。** 標成
   NOT MEASURED 而已。真要量需要動 lab（讀回 datagram、比對 agent 位址），
   而且 `ndt` 的 `verify_sflow` 已經在做這件事。

---

## 9. 檔案

| 檔案 | 動作 |
|---|---|
| `testbed_topo.py` | 改（+304 −25） |
| `tests/python/test_testbed_banner.py` | 新增，45 個 case |
| `tests/shell/mutate_testbed_banner.sh` | 新增，25 個 mutation |
| `doc/audit/2026-09-03_fix-testbed-banner/FIX-TESTBED-BANNER.md` | 本檔 |

複現：

```bash
python3 tests/python/test_testbed_banner.py          # 45 tests, OK
bash tests/shell/mutate_testbed_banner.sh            # 25 mutations, 0 survived
python3 tests/shell/check_gate_anchors.py <rev> --gates mutate_testbed_banner.sh   # ok(23)
```

[Co-developed with claude code -- Adam]

---

**auditor 補記（09-04，Adam 裁 N14 Q6）**：#77 併入之前，本 repo 的 `testbed_topo.py` 在 `NTG_PY` 下連 import 都過不了（#84 那兩行只存在於 NTG 的工作樹）⇒ 本修法（#42）併入時只有單元測試、**從未執行過**；09-04 晚上的整機測試是它第一次實跑。FINDINGS-ALL #42 已於 N14 同步補記。
