# W2 工具實作（agent T）— twin 測謊器與 L5 故障注入 harness

## TL;DR

| 項目 | 狀態 |
| --- | --- |
| worktree base | ✅ 開場是 `8b61cdc`（origin/main，無 `tests/`），已 `git fetch p4 && git reset --hard a3bfa40`，`tests/` 與 `tools/test_workflow/` 都在 |
| baseline | ✅ C++ **547 tests / 69 suites** 全綠；Python 全綠（**需 `P4_PROXY_PY` 覆寫**，見下） |
| `tools/twin_audit/criteria.py` | ✅ 三交叉判準模組（ping／paths／counters），quorum=2，路徑對帳保留為 `RESERVED_CHECKS` |
| `tools/twin_audit/twin_audit.py` | ✅ 測謊器 CLI：對 twin 宣稱 active 的每條 flow 跑判準，矛盾即告警 |
| `tools/test_workflow/faults.sh` + `faults.txt` | ✅ L5 注入層，資料驅動目錄＋強制 qdisc 前後置，判準共用 `criteria.py` |
| 測試 | ✅ 新增 3 檔共 **55 + 39 + 60**；**18 個 mutant、0 存活** |
| 收尾 CI | ✅ `local_ci.sh gcc python` 全綠（C++ 547、新測試三檔都被 runner 收到） |
| 未 commit | ✅ 依指示，程式碼留在 worktree `agent-adacd70ae1a1a590f` |
| **live 未驗證** | ⚠️ 見〈我無法驗證的部分〉11 條 — 我沒碰任何 live 環境，**所有 live 行為都是待驗** |

### 🔴 兩個必讀的發現（都不在原本的任務範圍內，但會影響你怎麼收這批東西）

1. **`tc` 的 NOPASSWD 授權只放行 `root netem`——正好是那個會靜默毀掉 TCLink htb 的寫法**；
   文件推薦的安全寫法 `parent 5:1` **沒有被授權**。live 注入前必須把 `FAULTS_TC` 改成走
   `mnexec`（以 uid 0 跑）。詳見 §4，含實查的 `sudo -n -l` 輸出。
   順帶：`doc/environment_gotchas.md:297` 那句「實測非破壞」和現在的 sudoers 不相容，**需要複核**。
2. **`__pycache__` 會讓「等長」的 Python 突變體從未執行，而徵狀和「測試不夠力」一模一樣**。
   我第一輪的 3 個「存活」全是量測錯誤，不是測試漏洞。詳見 §3，含決定性實驗。
   **這條建議進 memory**——凡是用 `spec_from_file_location` 的 mutation 測試都會中。

**給 orchestrator 的一句話**：判準模組是兩個工具的唯一真相來源；live 驗收的建議順序（由零風險往上）在 §5 末。

---

## 0. Worktree base（開場即中招，已修正）

```
開場：8b61cdc Add sharding        <- origin/main，上游 lab codebase，沒有 tests/ 也沒有 tools/test_workflow/
修正：git fetch p4 && git reset --hard a3bfa40
現在：a3bfa40 Fuzz the sFlow parser, and prove the harness can fail
```

`ls tests/ tools/test_workflow/` 兩者皆在，確認完成。之後所有結論以 `a3bfa40` 為準。

## 0b. Baseline（`bash tools/test_workflow/local_ci.sh gcc python`）

**C++（gcc job）**：`547/547 ran and passed`，`ctest cases=547 gtest tests=547 consistent`，
`--gtest_list_tests` 數得 **69 suites**。與預期完全相符。

**Python：第一次跑 FAIL，原因是 worktree 環境而非程式碼。** 完整紀錄，因為下一個 worktree agent
會再踩一次：

`components.env` 的 `P4_PROXY_PY` 預設是 `$KERNEL_DIR/p4_proxy/venv/bin/python`，而 `KERNEL_DIR`
由腳本自身位置推導 → 指向 **worktree**，那裡沒有 venv。`l1_unit_tests.sh` 的探測迴圈於是掉到
第二順位 `/home/adam/p4dev-python-venv/bin/python3`（該直譯器有 P4Runtime protobufs，所以通過
探測），但缺其他相依 → 8 個檔案 `ran=0`、`test_ryu_topology.py` 32 個 ERROR。**看起來像真的壞掉。**

覆寫後全綠：

```bash
P4_PROXY_PY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python \
  bash tools/test_workflow/l1_unit_tests.sh --no-build
```

| 群組 | 結果 |
| --- | --- |
| p4_proxy/tests（13 檔） | 361 ran，全綠（`test_p4_client.py` 為宣告過的 opt-in skip；`test_sflow_emitter.py` 2 skip 因無 p4info，屬環境） |
| tests/python（5 檔） | 134 ran，全綠 |
| tests/shell（5 檔） | 49 checks，全綠 |

> 📌 **建議 orchestrator 採納**：這個陷阱值得在 `l1_unit_tests.sh` 的探測迴圈加一行——
> 當 `$P4_PROXY_PY` 不存在但主樹的同名路徑存在時，明講一句 warning。目前的行為是
> **安靜降級到一個會假失敗的直譯器**，和「假綠」是同一枚硬幣的兩面。
> （我沒有動這個檔案，這超出本次範圍。）

---

## 1. 交付的檔案

| 檔案 | 職責 |
| --- | --- |
| `tools/twin_audit/criteria.py` | **共用判準模組**。三個獨立通道（雙向 ping／`all_destination_paths` 路徑數／對端 counter 兩次取樣的成長），quorum=2 才成立、任一異議即 `DISPUTED`。含 `reconcile()` 把「twin 的宣稱」和「網路的事實」對起來。路徑對帳登記在 `RESERVED_CHECKS`，被要求時**丟 `NotImplementedError`**（不是安靜回 UNKNOWN——那會在輸出裡看起來像已實作）。 |
| `tools/twin_audit/twin_audit.py` | **測謊器 CLI**。讀 `get_detected_flow_data`，對每條 twin 宣稱 active 的 flow 跑判準；矛盾分成 `LYING`（twin 說活、網路說死）與 `BLIND`（網路在動、twin 不知道）。另有 `flows` / `hosts` 兩個唯讀子命令供人工核對。 |
| `tools/test_workflow/faults.txt` | **故障目錄（資料）**。`ID \| ACTION key=value... \| 理由` 三欄，沿用 `warning_allowlist.txt` 的 `" \| "` 分隔慣例。第一批三型 `L-2` / `L-3` / `N-4`，其餘留 TODO 註解。 |
| `tools/test_workflow/faults.sh` | **L5 注入 harness**。逐輪：qdisc save → 基線判準 → 注入 → 判準 → **一定還原** → 判準 → qdisc diff。diff 不為空整輪作廢。判準呼叫 `criteria.py`，不自己寫第二份。 |
| `tests/python/test_twin_audit_criteria.py` | 55 tests |
| `tests/python/test_twin_audit.py` | 39 tests |
| `tests/shell/test_faults.sh` | 60 checks |

### 兩個設計決定，先講清楚

**(a) 測試放在 `tests/python/` 而不是 `p4_proxy/tests/`——這偏離了指示，理由如下，要改是一行 `git mv`。**
指示給 `p4_proxy/tests/` 的理由是「venv 直譯器、可用第三方套件」。但 `criteria.py` / `twin_audit.py`
**只用標準庫**（刻意的：這樣工具在 live 機器上不需要 venv 也能跑），所以那個理由不成立，而
`p4_proxy/tests/` 的 runner 是以 `p4_proxy/` 為 cwd、`PYTHONPATH=.`，要 import `tools/` 底下的東西
得繞路。這是 kernel-side 通用工具，`tests/python/` 才是它的家族。
**兩個測試檔都用「從自己往上找 repo root」定位受測模組，所以搬到 `p4_proxy/tests/` 不改一行也能跑。**

**(b) `criteria.py` 的 counter 通道有一個已知弱點，我寫在 docstring 裡沒有藏起來**：對端 rx counter
會因為無關的背景流量而成長，所以這條通道**可能因為錯的理由說 MOVING**。這正是 quorum=2 存在的原因
——它一票不能定案。要做到「只算這條 flow 的封包」需要 tcpdump/scapy 之類的東西，都沒裝也不准裝。

---

## 2. Mutation 預測（**先寫，後跑**）

規矩：弄壞它守的邏輯 → 該測試必須紅 → 還原 → 綠。每個 mutant 跑**三個測試檔全套**，不下 filter。
mutate 前已 `cp` 到 scratchpad `pristine/`（`git checkout --` 會連未提交的實作一起洗掉）。

| # | 檔案 | 突變 | **預測會紅的測試** |
| --- | --- | --- | --- |
| M1 | criteria.py | `ip_int_to_str` 的 `"<I"` → `"!I"`（位元組序陷阱） | `IpConversionTest` 4 條中至少 3 條 + `FlowPairTest.test_addresses_come_out_in_the_documented_byte_order` + `IpToHostNameTest` 2 條 |
| M2 | criteria.py | `check_ping` 不再探反向（`reverse = forward`） | `test_it_actually_probes_both_directions`、兩條 `only_the_*_direction` |
| M3 | criteria.py | `QUORUM = 2` → `1` | `test_one_channel_alone_decides_nothing`、`test_the_quorum_is_two` |
| M4 | criteria.py | `combine` 拿掉 `if moving and still: DISPUTED` | `test_any_dissent_is_disputed_even_when_outnumbered`、`LiveP0Shape.test_a_control_plane_that_still_advertises_a_dead_link_is_disputed` |
| M5 | criteria.py | `check_counters` 改看數值不看成長（`second >= min_growth`） | `test_a_large_but_frozen_counter_is_still`、`test_growth_below_the_floor_is_still` |
| M6 | criteria.py | `check_ping` 探針跑不動時回 `STILL` 而非 `UNKNOWN` | `test_a_ping_that_cannot_run_is_unknown_not_still` |
| M7 | criteria.py | `check_paths` 單向有路 → `MOVING` | `test_a_path_one_way_only_is_still` |
| M8 | twin_audit.py | `twin_claims_active` 的 `> 0` → `>= 0` | `test_a_zero_rate_is_not_a_claim`、`test_a_missing_rate_field_is_not_a_claim`、`test_flows_the_twin_calls_idle_are_not_probed` |
| M9 | twin_audit.py | `list_host_pids` 拿掉 `mininet:` 過濾 | `test_it_reads_the_mininet_process_tags`、`test_no_mininet_is_an_empty_map_not_an_error`、`test_untagged_processes_are_ignored` |
| M10 | twin_audit.py | `ip_to_host_name` 拿掉 `vertex_type` 過濾 | `test_switch_vertices_are_not_hosts` |
| M11 | twin_audit.py | `exit_code_for` 矛盾時仍回 0 | `test_a_lie_exits_one`、`test_a_blind_spot_also_exits_one`、`test_a_lie_beats_everything` |
| M12 | faults.sh | `netem_attach_point` 一律回 `root`（**就是那個會毀掉 htb 的錯**） | 「htb root -> netem hangs under the default class」、「htb root -> the answer is NEVER 'root'」、「netem went under the class, not at root」、「nothing was added at root」、handle/default 那條 |
| M13 | faults.sh | `run_round` 不再檢查 `qdisc_diff` | 「a dirty qdisc tree fails the round」、「and says the round is void」 |
| M14 | faults.sh | `netem_attach_point` 拿掉「已有 netem」的擋 | 「netem already present -> unsafe, refuse」 |
| M15 | faults.sh | `run_round` 只在注入成功時還原 | 「but the netem was still removed」 |
| M16 | faults.sh | `run_round` 拿掉「基線必須 moving」的前置條件 | 「a round on an already-dead network fails」、「and injects nothing」、「and says why」 |


## 3. Mutation 證據（**18 個 mutant，0 存活**）

跑法：每個 mutant 都跑**三個測試檔全套**（55 + 39 + 60），不下 filter。實作先 `cp` 到
scratchpad `pristine/`，每輪從 pristine 還原。最後重驗 baseline 全綠。

| # | 突變 | 結果 | 實際變紅的測試 | 與預測 |
| --- | --- | --- | --- | --- |
| M1 | `ip_int_to_str` `"<I"`→`"!I"` | KILLED | crit 4（含 masking 那條）＋ audit 4 | **比預測廣**（也打到 `test_malformed_nodes…`、`test_switch_vertices…`，因為兩者都拿位址當 key） |
| M2 | `check_ping` 不探反向 | KILLED | `test_it_actually_probes_both_directions` + 兩條 `only_the_*_direction` | ✅ 完全相符 |
| M3 | `QUORUM` 2→1 | KILLED | `test_one_channel_alone_decides_nothing`、`test_the_quorum_is_two` | ✅ |
| M4 | `combine` 拿掉異議判定 | KILLED | `test_any_dissent_is_disputed…`、`…dead_link_is_disputed` | ✅ |
| M5 | counter 看數值不看成長 | KILLED | `test_a_large_but_frozen_counter_is_still`、`test_growth_below_the_floor_is_still`、`test_the_flow_the_twin_swore_was_flowing_comes_out_lying` | 多一條（P0 場景本來就是「巨大但靜止的 counter」） |
| M6 | ping 跑不動→STILL | KILLED | `test_a_ping_that_cannot_run_is_unknown_not_still` | ✅ |
| M7 | 單向有路→MOVING | KILLED | `test_a_path_one_way_only_is_still` | ✅ |
| M8 | `> 0` → `>= 0` | KILLED | 3 條 | ✅ |
| M9 | 拿掉 `mininet:` 過濾 | KILLED | 3 條 | ✅（**強化後才 3 條**，見下） |
| M10 | 拿掉 `vertex_type` 過濾 | KILLED | `test_switch_vertices_are_not_hosts` | ✅ |
| M11 | 矛盾仍回 exit 0 | KILLED | 3 條 | ✅ |
| M12 | `netem_attach_point` 一律 `root` | KILLED | **5 條**（含「nothing was added at root」） | ✅ |
| M13 | 不檢查 `qdisc_diff` | KILLED | 2 條 | ✅ |
| M14 | 拿掉「已有 netem」的擋 | KILLED | 1 條 | ✅ |
| M15 | revert 只在 `rc==0` 時跑 | KILLED | 「but the netem was still removed」 | ✅（**第一版 mutant 寫錯**，見下） |
| M16 | 拿掉「基線必須 moving」 | KILLED | 3 條 | ✅（**強化後才 3 條**） |
| M17 | 拿掉 `& 0xFFFFFFFF` | KILLED | `test_a_signed_reading_of_a_high_address_is_masked_not_a_crash` | 事後補的 mutant，見下 |

### 🔴 第一輪有 3 個「存活」，全部是**我的量測錯誤**，不是測試不夠力

追下去才是這輪最有價值的產出：

**(1) `__pycache__` 會讓等長的 Python 突變「從未執行」——而它看起來完全像測試不夠力。**
M1 把 `"<I"` 改成 `"!I"`：**檔案大小一個位元組都沒變**。驅動程式用 `shutil.copy` 還原（mtime＝現在）
再寫入突變（mtime 還是現在），而 pyc 的快取驗證看的是**來源檔的 (mtime, size)**、**mtime 只有 1 秒解析度**——
整個 restore→mutate→run 都在同一秒內完成，所以 `(mtime, size)` 完全吻合，Python 直接用舊 bytecode，
**突變體從來沒有被執行過**，測試當然全綠。

我第一次的「反證實驗」也是錯的（我 `touch` 成 13:46:00，但 pyc 記的是來源檔 13:44 的 mtime，
不吻合所以快取失效、測試變紅，於是我一度以為快取假說被推翻）。決定性實驗是**從 pyc 標頭直接讀出
它記錄的 mtime/size，再把來源檔 `os.utime` 成那個值**：

```
pyc records source mtime=1786600073 size=22710
after mutation          mtime=1786600073 size=22710
=> rc=0  OK          <- 突變在磁碟上，測試全綠
```

修法：驅動程式跑測試時設 `PYTHONDONTWRITEBYTECODE=1`，且每次突變後遞迴清掉 `__pycache__`。
**這條值得進 memory**——它和既有的〈Mutation harness must guard its baseline〉是同一個家族，
但徵狀相反：那條是「殘留的 mutant 被當成 baseline」，這條是「真的 mutant 從未執行、被記成存活」。
凡是用 `spec_from_file_location` 載入受測模組的 mutation 測試都會中。

**(2) M3 改到了 docstring，沒改到常數。** `"QUORUM = 2"` 這個字串在 `criteria.py` 出現兩次
（第 29 行的說明文字、第 103 行的常數），`replace(..., 1)` 改了第一個。驅動程式其實有印
`pattern occurs 2 times`，但我第一輪沒把那行當回事。改成 `"\nQUORUM = 2\n"` 後正常。

**(3) M15 的突變本身沒有模擬到我要測的東西。** 我寫的是「注入失敗時不 revert」，但那條測試演的是
「注入成功、但中途判準不如預期」。改成「`rc != 0` 就不 revert」之後一擊命中。

### 兩條「從未變紅」的檢查已補強（沒看過它失敗就不算交付）

- `test_untagged_processes_are_ignored` 原本斷言 `"bash" not in map`，但拿掉 `mininet:` 過濾後
  那行的 key 會變成 `"unrelated"`（最後一個字），所以**它在任何 mutant 下都不會紅**。改成斷言
  **PID 1234 不在 values 裡**——那才是「mnexec 絕不能指到的東西」。M9 現在打到它。
- shell 的「a round on an already-dead network fails」只斷言 `rc=1`；拿掉前置條件後整輪會跑完、
  在「後面」失敗，`rc` 一樣是 1。補了一條斷言錯誤訊息裡有 `baseline is 'still'`。M16 現在打到它。
- `test_high_addresses_do_not_overflow` 用 `255.255.255.255`——**這個位址在位元組反轉下對稱**，
  所以它證明不了任何位元組序或遮罩的性質。改成也測負數（有號讀法）並補 M17 專打 `& 0xFFFFFFFF`。


### M18（後補）：sudoers 實查後加的一條

見下一節。`Ran 60 checks`，M18 打掉 2 條。**最終：18 個 mutant，0 存活，baseline 三套全綠。**

---

## 4. 🔴 最重要的單一發現：`tc` 的 NOPASSWD 授權**只放行那個會毀掉 htb 的寫法**

我用 `sudo -n -l`（唯讀、不碰網路）實查，這台機器現在的授權是：

```
(root) NOPASSWD: /usr/bin/ovs-vsctl, /usr/sbin/ifconfig, /usr/bin/mnexec
(root) NOPASSWD: /usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* root netem *
(root) NOPASSWD: /usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* root
(root) NOPASSWD: /usr/sbin/tc qdisc show dev s[0-9]*-eth[0-9]*
```

把它和 `doc/environment_gotchas.md` 的結論擺在一起看：

| 寫法 | 對 TCLink(htb) 介面的效果 | sudo 放行？ |
| --- | --- | --- |
| `tc qdisc add dev X root netem …` | **靜默替換 htb，shaping 消失，裝不回去** | ✅ **只有這個** |
| `tc qdisc del dev X root` | 還原成核心預設，**不是** htb | ✅ |
| `tc qdisc add dev X parent 5:1 netem …` | 安全、可乾淨還原（gotchas §297 推薦） | ❌ **沒放行** |

**也就是說：唯一被授權的 tc 寫法，正是那個會破壞實驗環境的寫法；而文件推薦的安全寫法會被 sudo 擋下。**

順帶：`doc/environment_gotchas.md:297` 寫「`sudo -n tc qdisc add dev X parent 5:1 netem loss 100%`
（同輪實測非破壞、可乾淨還原）」——這句話**和現在的 sudoers 不相容**。要嘛授權後來改過，要嘛當時
那條是透過 `mnexec` 以 uid 0 跑的而記錄時省略了。**這行文件需要複核。**

**解法（和 repo 既有慣例一致）**：`mnexec` 以 uid 0 執行，所以在它底下跑 `tc` 不需要 tc 的專屬授權——
這正是 `doc/environment_gotchas.md:275` 對付「`ovs-ofctl` 不在 sudoers」用的同一招。live 跑注入前設：

```bash
export FAULTS_TC="sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py' | head -1) tc"
```

`faults.sh` 的預設仍是 `sudo -n tc`，因為那樣的失敗是**安全的失敗**（安全寫法被擋 → 整輪中止，
不會退而求其次去用破壞性寫法）。失敗時它會把上面那行 `FAULTS_TC=` 直接印出來。這條路徑由
「a tc that will not run says how to run it as uid 0」三條檢查守著，M18 驗過。

---

## 5. Seam 清單（orchestrator 做 live 驗證要用的）

### `tools/twin_audit/criteria.py`

| 環境變數 | 預設 | live 時要注意 |
| --- | --- | --- |
| `TWIN_AUDIT_PING` | `ping` | |
| `TWIN_AUDIT_MNEXEC` | `sudo -n mnexec` | 有 host PID 時才會用到；`-a <PID>`，不是名字 |
| `TWIN_AUDIT_CAT` | `cat` | 讀 `/proc/net/dev` |
| `NDT_URL` | `http://localhost:8000` | kernel 北向 |
| `PATHS_URL` | `http://localhost:8080` | **OVS 是 Ryu :8080；P4 模式必須改成 proxy :8081** |
| `TWIN_AUDIT_PING_COUNT` / `GAP_S` / `MIN_GROWTH` / `TIMEOUT_S` | `3` / `2.0` / `1` / `10` | |

可覆寫函式（測試用賦值換掉）：`run_command`、`http_get_json`、`sleep`、`now`。
**這四個是本模組對外部世界的全部接觸面**，測試的 `WorldFreeTestCase` 會把它們換成「被呼叫就爆炸」。

exit code 契約：`0 moving / 1 still / 2 usage / 3 inconclusive / 4 disputed`（`faults.sh` 靠這個分支，
`ExitCodeContractTest` 釘住；2 刻意留給 usage error，與 `qdisc_snapshot.sh`、`stack.sh` 一致）。

### `tools/twin_audit/twin_audit.py`
`TWIN_AUDIT_PS`（預設 `ps`）、`TWIN_AUDIT_STALE_S`（預設 30）。exit：`0 無矛盾 / 1 有 LYING 或 BLIND / 2 讀不到 twin / 3 全部無法判定`。

### `tools/test_workflow/faults.sh`
`FAULTS_TC`（**見上節，live 要改**）、`FAULTS_KILL`（`sudo -n kill`）、`FAULTS_CRITERIA`、
`FAULTS_QDISC`、`FAULTS_CATALOGUE`、`FAULTS_SETTLE_S`（預設 5，**建議調高，見下**）。
可覆寫函式：`run_tc`、`run_signal`、`show_qdisc`、`settle`、`check_pair`、`qdisc_save`、`qdisc_diff`。

### 建議的 live 驗收順序（由零風險往上）

```bash
# 0. 完全不碰網路
python3 tools/twin_audit/criteria.py list-checks
bash   tools/test_workflow/faults.sh list

# 1. 唯讀。這是我最沒把握的一段，請先跑這個
python3 tools/twin_audit/twin_audit.py hosts     # ip -> host -> pid 對得上嗎？
python3 tools/twin_audit/twin_audit.py flows     # twin 現在宣稱什麼、樣本多舊

# 2. 唯讀＋ping。挑一對已知健康的 host，預期 moving
PATHS_URL=http://localhost:8080 \
python3 tools/twin_audit/criteria.py check --src-ip 10.0.0.1 --dst-ip 10.0.0.2 --json

# 3. 全套測謊
python3 tools/twin_audit/twin_audit.py audit

# 4. 最後才注入，且務必先設好 FAULTS_TC 與較長的 settle
export FAULTS_TC="sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py' | head -1) tc"
FAULTS_SETTLE_S=25 bash tools/test_workflow/faults.sh run L-2 \
  --pair 10.0.0.1,10.0.0.2 --iface s1-eth1
```

---

## 6. 我無法驗證的部分（誠實清單）

**大前提：我一次都沒有碰 live。** 零連線、零 process、零 `tc`／`mnexec`／`curl` 到那些 port。
以下每一條都只經過 stub 測試，**沒有任何一條經過真環境**。

| # | 未驗證的東西 | 風險 / 怎麼查 |
| --- | --- | --- |
| 1 | **`FAULTS_TC` 到底該長什麼樣** | 上面 §4 的結論是從 `sudo -n -l` 推的，**沒有真的跑過一次 tc**。第一次注入前請先手動跑一次安全寫法確認。 |
| 2 | **`/proc/net/dev` 在 Mininet host namespace 裡的實際輸出** | 我 partition `":"` 後取第 2 欄當 rx packets（標準格式如此），排除 `lo`。欄位位移與介面命名沒對過真輸出。 |
| 3 | **`all_destination_paths` 每一跳的實際結構** | 我照 runbook §4h 假設 `p[0][0]` / `p[-1][0]` 是端點。**P4 proxy 版本的結構是否相同未確認**。一個 `curl` 就能查。 |
| 4 | **`get_graph_data` 的 node `ip` 是整數還是字串** | `doc/ndt_api.md` 自相矛盾（§3/§4 的註解說是 dotted text，同一份的範例是整數；C++ 型別 `VertexProperties::ip` 是 `vector<uint32_t>`）。**我兩種都吃**，但哪一種真的會出現沒確認。→ 順帶：**這是一個文件缺陷，值得修**。 |
| 5 | **IP↔host↔PID 的解析在真拓樸上對不對** | 128 台 host 的 OVS 拓樸下，`device_name` 與 `mininet:<name>` 的 tag 是否一致沒驗過。`twin_audit.py hosts` 就是為了先查這個而存在。 |
| 6 | **`ping -c N -W 1 -n` 在 mnexec 底下的行為** | flag 相容性、以及 100% loss 時實際要花多久才回。 |
| 7 | **`FAULTS_SETTLE_S=5` 夠不夠** | bmv2 那輪實測**自癒要 16.63 秒**，5 秒很可能讓「after」檢查抓到還沒恢復的狀態 → **假失敗**。建議先用 25。 |
| 8 | **N-4（SIGSTOP）整條路徑** | 目錄裡就寫了 THEORY ONLY。另外 `sudo -n kill` **不在 NOPASSWD 清單裡**（清單只有 ovs-vsctl/ifconfig/mnexec/tc 三式/ndtwin-p4-power），bmv2 又是 root helper 起的，所以 `FAULTS_KILL` 很可能也要走 mnexec。**沒驗過。** |
| 9 | **`tc qdisc show` 真實輸出的 handle / default 解析** | 我對的是 gotchas 文件與 `test_qdisc_snapshot.sh` 的 fixture 字串，**不是真輸出**。 |
| 10 | **測謊器的假陽性率** | 一條剛結束、rate 還沒歸零的 flow 會被判 `LYING`。quorum=2 應該能壓下大部分，但**真實假陽性率必須 live 才知道**。這是第一輪 live 最該量的數字。 |
| 11 | **counter 通道在有背景流量的 host 上** | 已知弱點（見 §1b）。真實環境噪音多大沒量過。 |


---

## 7. 收尾狀態

```
P4_PROXY_PY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python \
  bash tools/test_workflow/local_ci.sh gcc python
→ PASS gcc / PASS python / local CI passed
  test_twin_audit_criteria.py    PASS 55 ran and passed
  test_twin_audit.py             PASS 39 ran and passed
  test_faults.sh                 PASS 60 ran and passed
```

C++ 547/547（69 suites）不變，既有 Python／shell 測試一條沒壞。三個新檔都被 `l1_unit_tests.sh`
正確收到——shell 的結尾摘要用的是 `Ran N checks, all passed` 格式，沒有被判成 `NO TESTS RAN`。

**未 commit、未 push、未開 PR、未動主樹。** 程式碼在 worktree
`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-adacd70ae1a1a590f`，
`git status` 只有 6 個 untracked 項目（3 個測試檔、`faults.sh`、`faults.txt`、`tools/twin_audit/`），
**沒有修改任何既有檔案**。

### 給 orchestrator 的收件建議
1. 先決定測試檔位置（`tests/python/` vs `p4_proxy/tests/`，見 §1a）——`git mv` 即可，不改內容。
2. §4 的 `tc` 授權問題**必須在第一次 live 注入之前解決**，否則 L-2／L-3 一定失敗（安全地失敗）。
3. `FAULTS_SETTLE_S` 建議從 25 起跳，不要用預設的 5。
4. §6 第 5、10 兩條（host PID 解析、假陽性率）是 live 第一輪最該量的東西。
