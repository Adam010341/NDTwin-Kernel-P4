# Finding #71 — rule journal 在 production 從來沒有被寫過，而一支叫「journal wiring」的 14 個測試全綠

分支 `fix/rule-journal-is-wired`，基底 **trunk `eeda3cba`**（doc commit 當下 trunk 已前進到
`50defbbe`，只多一個 doc 檔，`git merge-tree` 仍 rc=0）。程式碼 commit `5fc5a13c`。
**沒有 push**。不需要 C++ 建置、不需要實驗室；全部離線。
[Co-developed with claude code -- Adam]

## 1. 一句話

`p4_proxy/proxy_agent/main.py` 唯一的 production 建構點是 `TopologyManager(kernel_notifier=kernel)`
——**沒有傳 journal**，所以 `_note_in_journal` 第一行 `if not accepted or self._journal is None`
每一次都立刻返回，`rule_journal.py` 連一個 production import 都沒有；修法是讓 `main.py` 真的
建一個 `RuleJournal` 並注入，再補一支**不注入**的接線測試（走 `main.py` 自己的 import 路徑、
讀磁碟上的檔案），而 replay 維持關閉。

## 2. 前後對照

### 2.1 程式碼

| | BEFORE（`eeda3cba`） | AFTER（`5fc5a13c`） |
|---|---|---|
| `main.py` 的建構點 | `TopologyManager(kernel_notifier=kernel)` | `TopologyManager(kernel_notifier=kernel, journal=journal)` |
| production import `rule_journal` | **0 個**（唯一 import 在 `tests/test_rule_journal.py:47`） | `main.py` 直接 import `RuleJournal` |
| `main.topo._journal` | `None`（實測，見 §3） | `RuleJournal`，`path=<repo>/p4_proxy/.run/rule_journal.jsonl` |
| 一次 `route_flow` 之後 journal 檔 | 不存在 | 一行 JSON：`{"op":"install","dpid":1,"match":…,"actions":…,"priority":100,"t":…}` |
| 路徑可覆寫 | — | `NDTWIN_RULE_JOURNAL_PATH` |
| 接線測試 | 只有注入式的 `test_journal_wiring.py`（14，全綠且無鑑別力） | 加 `test_journal_is_wired_in_main.py`（12，修前 6 FAIL ＋ 4 ERROR） |
| 變異閘 | 無 | `tests/shell/mutate_rule_journal_is_wired.sh`，14 mutations / 0 survived |

`p4_proxy/tests/test_journal_wiring.py` 的 **14 個 case 一個字都沒動**（`git diff` 只有 docstring）。
它證明的是「**給它一個 journal 它會寫**」，不是「**有人給它 journal**」；兩段 docstring 補上這句話，
並改掉那句把 bug 記成設計意圖的話——原文寫著 *"Every existing construction site passes no journal
-- main.py's module-level `topo`"*，那句當時是真的，而它就是缺陷本身。

### 2.2 🔴 對外行為變更（三件，都要 Adam 知道）

**🔴 (a) 每一次被接受的規則寫入多一次 `fsync`，量到 6.37 ms。** 這是這次改動唯一的效能代價，
而且它落在 REST 安裝路徑上（`/stats/flowentry/add|delete|modify` → `route_flow`／`unroute_flow`／
`modify_flow` 的六條成功路徑），並且在 `RuleJournal._lock` 上序列化——FastAPI 的 threadpool 可以
併發進來，journal 這一段不行。

| 量測（本機 ext4，`RuleJournal.record` 直接量 200 次，同一個 entry 形狀） | median | p95 |
|---|---|---|
| 目前設定（`fsync` 開，就是 AFTER 的行為） | **6.374 ms** | 6.730 ms |
| 同一段程式把 `os.fsync` stub 掉 | **0.027 ms** | 0.051 ms |

⇒ **代價 100% 是 `fsync`**（236×），不是 JSON 序列化也不是開檔。entry 大小 132 bytes。
上界約 **150 條規則/秒**（1/6.4 ms），單機單鎖。

🔴 **這和 `rule_journal.py` 自己的說法對不起來，我沒有推翻它、也沒有證實它。** 該模組
docstring 寫著 *"One rule install is already a gRPC round trip, so an fsync is not what makes
this path slow."*——那句成立的條件是「bmv2 的一次 gRPC table write ≫ 6.4 ms」。**我在 repo 裡找不到
這個數字的量測**（`doc/audit/` 沒有 per-rule install latency 的紀錄），所以我只能把 6.37 ms
放在這裡，等一次帶 bmv2 的量測來對帳。**`fsync` 我沒有動**——關掉它是 `rule_journal.py` 明寫的
設計決定（「還在 page cache 裡的一行撐不過一次不乾淨的關機」），要不要換由 Adam 裁。

**🔴 (b) 檔案系統上多一個檔：`p4_proxy/.run/rule_journal.jsonl`。** 第一次「被接受的規則寫入」
才建立（import 不建立，見 `test_importing_the_proxy_does_not_create_the_file`）。已加進
`.gitignore`（`p4_proxy/.run/`）——它是 per-machine、per-generation 狀態，而且 `quarantine()`
產生的名字是 `rule_journal.jsonl.<boot>.<epoch>`，沒有單一檔名 pattern 蓋得住，所以擋整個目錄。

**🔴 (c) replay 沒有被接上，而且我確認過它「不會在每次 proxy 啟動時自動跑」。** 依任務指示
**預設保持現況**。查證：`grep -rn "\.replay(\|replay_enabled" --include=*.py p4_proxy/proxy_agent/
p4_proxy/tests/` 共 14 行，`proxy_agent/` 底下命中的 3 行**全是註解／docstring**（`main.py:67`、
`rule_journal.py:54`、`rule_journal.py:256`），真正的呼叫 11 行**全部**在
`tests/test_rule_journal.py` ⇒ production 端 **0 個呼叫點**。`main.startup()` 這次一行都沒改。所以接上 journal **只增加寫**，
不增加任何開機時的寫入交換機動作。`NDTWIN_RULE_JOURNAL_REPLAY` 仍然是一個**沒有 reader 的環境
變數**（這正是 repo 最常見的那個形狀），只是現在它至少有東西可讀了。

## 3. 閘門證據

### 3.1 修前那次紅（**沒看過紅不算交付**）

在 `eeda3cba` 的工作樹上、只加測試檔、`main.py` 一個字都沒改時跑：

```
$ cd p4_proxy && venv/bin/python -m unittest tests.test_journal_is_wired_in_main -v
...
FAIL: test_the_module_level_topology_holds_a_real_rule_journal
      (tests.test_journal_is_wired_in_main.TheProxyBuildsAJournalTest.…)
----------------------------------------------------------------------
    self.assertIsNotNone(
        main.topo._journal,
        "main.topo was built with no journal: _note_in_journal returns on its first "
        "line and no rule this proxy installs is ever recorded")
AssertionError: unexpectedly None : main.topo was built with no journal: _note_in_journal
returns on its first line and no rule this proxy installs is ever recorded

FAIL: test_one_accepted_install_is_one_line_in_the_journal_file
AssertionError: 0 != 1 : journal file holds []

Ran 12 tests in 0.090s
FAILED (failures=6, errors=4)
```

十條紅的完整名單（6 FAIL ＋ 4 ERROR；4 個 ERROR 是 `main.default_journal_path` 當時不存在）：

| 紅法 | case |
|---|---|
| FAIL | `test_the_module_level_topology_holds_a_real_rule_journal` |
| FAIL | `test_the_topology_the_rest_handlers_use_is_the_journalled_one` |
| FAIL | `test_one_accepted_install_is_one_line_in_the_journal_file` |
| FAIL | `test_a_five_tuple_install_is_in_the_journal_file` |
| FAIL | `test_two_writes_append_rather_than_replace` |
| FAIL | `test_the_journal_the_proxy_wrote_is_readable_by_rule_journal` |
| ERROR | `test_the_default_path_is_inside_this_checkout` |
| ERROR | `test_the_default_path_does_not_move_between_constructions` |
| ERROR | `test_the_default_path_does_not_depend_on_the_working_directory` |
| ERROR | `test_the_environment_override_is_read` |

**兩條在修前就是綠的，那是刻意的**：`test_a_refused_install_leaves_the_journal_file_empty` 與
`test_importing_the_proxy_does_not_create_the_file`——一個沒接線的 journal 當然「不記錄被拒絕的
寫入」也「不建立檔案」。它們不是接線的證據，是**放寬方向的控制組**，由變異閘的 N1／N6 負責讓它們
真的會紅（見 §3.3）。

修後：`Ran 12 tests`／`OK`，而且跑完 checkout 裡沒有多出 `.run/`（測試把真的建構路徑指向 tmpdir）。

### 3.2 沒有打壞別人

`p4_proxy/tests/` 全部 25 個模組逐一跑，**全綠**：13/23/6/31/23/9/**12**/**14**/21/74/16/1(skip1)/74/10/3/47/19/25/32/49(skip2)/17/24/11/1/49。
`test_journal_wiring` 仍是 **14 OK**、`test_rule_journal` 仍是 **19 OK**。

同一個 process 內混跑（`test_startup` 也 import `main`）兩種順序各一次，`Ran 113 tests / OK`
——接線測試會 pop 掉 `sys.modules["proxy_agent.main"]` 重新 import，所以它把 `api_routes` 的四個
注入全域、`sys.modules`、環境變數都存回去，並關掉重複建立的 sFlow socket。

### 3.3 變異閘

`tests/shell/mutate_rule_journal_is_wired.sh` → **`14 mutations, 0 survived`**，
baseline byte-identical（`main.py`／`topology_manager.py`／`rule_journal.py`／測試檔四個 sha 都比對）。
`check_gate_anchors.py fix/rule-journal-is-wired --gates mutate_rule_journal_is_wired.sh` → **`ok(12)`**
（14 個 mutation 共用 12 個相異錨點：M4/N1 共用 `_note_in_journal` 的守衛那行，N2/N3 共用
`default_journal_path` 的兩行 body）。

🔴 **每個 mutant 是一份 `p4_proxy` 的複本**（`proxy_agent/`＋`tests/`＋`mininet/`），測試在複本裡跑；
工作樹底下的檔案一個字都沒被寫過。`main.py`／`topology_manager.py`／`rule_journal.py` 是同一條鏈上的
三環，任何一環的 mutation 都要走真的 import 才驗得到，所以複製的是整棵可 import 的樹而不是單檔。

**缺陷方向（8）**——把缺陷放回去：

| | mutation | 該紅的 case |
|---|---|---|
| M1 | `main.py` 不再傳 journal（就是修前那一行） | `test_the_module_level_topology_holds_a_real_rule_journal` |
| M2 | journal **建了**但傳 `None` | 同上 |
| M3 | REST handler 拿到第二個、沒有 journal 的 manager | `test_the_topology_the_rest_handlers_use_is_the_journalled_one` |
| M4 | `_note_in_journal` 的 `is None` 守衛反轉 | `test_one_accepted_install_is_one_line_in_the_journal_file` |
| M5 | 5-tuple 分支不再 journal（那是**唯一沒有其他紀錄**的規則類） | `test_a_five_tuple_install_is_in_the_journal_file` |
| M6 | `record()` 回報成功但不寫（`fh.write` → `pass`） | `test_one_accepted_install_is_one_line_in_the_journal_file` |
| M7 | 寫成自己的 reader 解不開的格式 | `test_the_journal_the_proxy_wrote_is_readable_by_rule_journal` |
| M8 | 路徑覆寫環境變數被忽略（又一個沒有 reader 的 env var） | `test_the_environment_override_is_read` |

**🔴 放寬／控制方向（6）**——上面八個它們全部通過，只有這六條抓得到。少了這一面，這支閘會簽掉一個
「寫得很勤、重啟時讀不回來」的 journal：

| | mutation（control） | 該紅的 case |
|---|---|---|
| N1 | **被拒絕的寫入也記**（replay 會裝出一條從來不存在的規則） | `test_a_refused_install_leaves_the_journal_file_empty` |
| N2 | 每次 proxy 啟動開一個全新的 journal（`mkdtemp`） | `test_the_default_path_does_not_move_between_constructions` |
| N3 | 路徑跟著 cwd 走 | `test_the_default_path_does_not_depend_on_the_working_directory` |
| N4 | 路徑寫死在某台機器的家目錄 | `test_the_default_path_is_inside_this_checkout` |
| N5 | 每筆改寫檔案而不是 append | `test_two_writes_append_rather_than_replace` |
| N6 | import 時就把檔案建空（空 journal 與壞掉的 writer 從此分不出來） | `test_importing_the_proxy_does_not_create_the_file` |

閘門自己會找直譯器：`PROXY_PY=` → 工作樹的 `p4_proxy/venv` → `git worktree list` 問出主 worktree 的
venv。**找不到會 `exit 2` 拒絕**，不會綠——worktree 沒有自己的 venv（`p4_proxy/venv/` 被 gitignore），
而一支跑不了測試的閘門沒有資格 exit 0。

## 4. 合併順序與衝突

`git merge-tree --write-tree trunk fix/rule-journal-is-wired` → **rc=0**（對 `eeda3cba` 與對現在的
`50defbbe` 都是）。**這條分支可以單獨先合，不依賴任何人。**

掃過所有本地分支中會碰到這五個檔的：

| 分支 | 碰到的檔 | 對我 |
|---|---|---|
| `fix/a4c-proxy-restart-honesty` | 無交集 | `merge-tree` rc=0，**乾淨** |
| `audit/desk-check-remaining-manual-pages` | `main.py` | 我的檔上**無衝突** |
| `worktree-agent-a12e05453bd0ac03f` / `-abf084771d76f4411` | `main.py` | 我的檔上**無衝突** |
| `t7b-release-renew` | `main.py`＋`.gitignore` | `.gitignore` 衝突，**但不是我造成的**：`git merge-tree trunk t7b-release-renew`（完全不含我）就已經在 `.gitignore` 上衝突了——t7b 的 base 停在 08-29 `6adb688e`，還沒有 08-31 那次 `**` 加寬。t7b 併上 trunk 之後就沒事；我的 hunk 在檔案上半（第 33 行前），t7b 的在下半 |

上面四個 `main.py` 分支對 trunk 的 `main.py` 差異都只有 25 行 diff 且**四支完全相同**，
與我加的區塊（檔案開頭、`app = FastAPI(...)` 之後）不重疊。

⚠️ 直接 `merge-tree` 這些分支還會噴 `doc/2026-08-29_europ4-poster-abstract/abstract.tex`
之類的 modify/delete——那是**它們的 base 太舊**（投稿包 09-01 移出 repo）造成的既有漂移，
與這次改動無關。**對 trunk 才是有意義的比較，那個是乾淨的。**

## 5. 回退

一個 commit，`git revert 5fc5a13c` 就回到原狀，沒有 migration、沒有資料格式相依。

- 只想關掉寫入而不 revert：把 `main.py` 的 `journal=journal` 改回不傳即可（`TopologyManager` 的
  `journal=None` 仍是**受支援**的模式，`test_journal_wiring.py` 的 `NoJournalIsNotAnErrorTest`
  兩條就在守這件事）。副作用是 `test_journal_is_wired_in_main.py` 會紅——那是它的工作。
- 只想搬檔案位置：`NDTWIN_RULE_JOURNAL_PATH=<path>`，不必改碼。
- 已經產生的 `p4_proxy/.run/rule_journal.jsonl` 沒有任何 reader（見 §2.2c），刪掉不影響任何行為。

## 6. 未處理（🔴 都是刻意留的，不是忘了）

1. **🔴 `quarantine()` 仍然沒有呼叫點 ⇒ 檔案會跨 proxy 世代一直長。** `rule_journal.py` 寫著它
   存在的理由：「沒有它，一個檔會累積每一代的規則，一次 replay 會重裝三次重啟以前被刻意刪掉的
   規則」。要接它必須先決定**順序**（開機時：先讀 → 再決定 replay → 最後 quarantine），而 replay
   這次不在範圍內，先接 quarantine 會讓未來的 replay 讀到空檔——正是本 finding 的失敗模式。
   `proxy_agent/boot_identity.BOOT_ID` 已經是現成的 boot id。**成長速率**：132 bytes/筆，只記
   REST 進來的規則（見 3.），不記 bring-up。
2. **🔴 `install_initial_routes` 不 journal，這是既有設計、但它讓 replay 的順序不完整。**
   `_note_in_journal` 只有六個呼叫點（`route_flow`／`unroute_flow`／`modify_flow` 各兩個分支）；
   `install_initial_routes` 直接呼叫 `client.insert_ipv4_route` 並只更新 `_installed_routes`。
   設計上這是對的（重啟後 `install_initial_routes` 自己會補 bring-up 最短路徑，journal 只需要
   補「差額」），**但它在拓樸每次變動時也會重寫每一條 (switch, host)**，而那次覆蓋沒有進 journal
   ⇒ 未來的 replay 看不到「T 時刻 app 裝的規則被 install_initial_routes 蓋掉了」。這是原本就有的
   缺口，不是這次引入的；replay 真的要做的時候必須先處理它。
3. **replay 完全沒碰**（依指示）。`NDTWIN_RULE_JOURNAL_REPLAY` 仍無 reader。要不要預設開、開在哪
   （`main.startup` 的哪個點、pipeline push 之後還是 `install_initial_routes` 之後）由 Adam 裁。
4. **沒有 live 驗證。** 全部離線：沒有起 bmv2、沒有起 proxy、沒有碰實驗室。「一次 `route_flow`
   之後 journal 檔多一筆」是用 `FakeClient` 走真的 `main.topo` 量到的，**不是**對真交換機量到的。
   §2.2(a) 的 6.37 ms 是 `RuleJournal.record` 的直接量測，**不是** end-to-end 的
   `/stats/flowentry/add` 延遲，也沒有 bmv2 那一側的數字可以對帳。
5. **KNOWN-ISSUES A-4c 的條目沒有改。** 這次只讓 journal「有在寫」；A-4c 說的「重啟後拿到空
   journal 被讀成本來就沒東西要還原」現在**只解決了一半**——journal 有內容了，但沒有人讀它。
   等 replay 的裁決下來再一起改文件，免得 A-4c 被改成一個比現況樂觀的說法。
