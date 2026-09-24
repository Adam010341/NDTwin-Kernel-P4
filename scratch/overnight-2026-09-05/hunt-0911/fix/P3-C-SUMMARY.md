# P3-C SUMMARY — 工單 C（proxy＋package 工具：G1／telemetry A／G7／G8／G9a/b／揭露）

worker「P3-C」2026-09-19 寫；工單 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/TICKET-P3-observation.md` §5，
契約 §2.1、§2.6，前例 TICKET-P2 §2.2／§2.3／§7（第 7、8 條仍綁）。形式照 §3.6。

[Co-developed with claude code -- Adam]

## 0. base／head／commit

- worktree `scratch/overnight-2026-09-05/wt-p3-proxy-0919`，branch `feat/p3-proxy-telemetry-pre-0919`
- **base `8eddb0e8`**
- **head `8f3e5e3a`**
- 未推、未併、未動主 checkout；未 commit 工單複本（`TICKET-P3-observation.md` 仍是 untracked）

| sha | 標題 |
| --- | --- |
| `9d054a0a` | P3-C 01: the telemetry ids come from each switch's own p4info, the source is a word three processes agree on, and the PRE entries a package declares are programmed |
| `4406c17e` | P3-C 02: the tests for all of it, plus the exercise's own CPU port and the PRE entries pre-flight checks against the model it will build |
| `9c83acd9` | P3-C 03: the mutation gates -- a new one for the telemetry path, and the two existing ones repaired and extended |
| `8f3e5e3a` | P3-C 04: the sentinel knob path carries a pid |

## 1. 每套件的實跑指令＋rc＋最後一行

全部在 worktree 根跑，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p3c-8f3e5e3a.log`。
Python 一律 `p4_proxy/venv/bin/python`（worktree 的 symlink → 主 checkout 的 venv）；跑前清 `__pycache__`。

| 套件 | 指令 | rc | 最後一行 |
| --- | --- | --- | --- |
| p4_proxy 全套 | `cd p4_proxy && PYTHONPATH=$PWD PYTHONDONTWRITEBYTECODE=1 venv/bin/python -m unittest $(ls tests/test_*.py \| sed 's#tests/##; s#\.py$##; s#^#tests.#')` | 0 | `Ran 1189 tests in 19.114s` ／ `OK (skipped=1)` |
| tools/p4_exercise | `PYTHONDONTWRITEBYTECODE=1 p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests` | 0 | `Ran 154 tests in 1.904s` ／ `OK` |
| 契約自測 | `cd tools/contract_test && python3 run_contract_test.py --self-test` | 0 | `Self-test passed: 166 checks` |
| **新**`mutate_telemetry_by_name.sh` | `bash tests/shell/mutate_telemetry_by_name.sh` | 0 | `mutation gate: 19 mutations, 0 survived` |
| `mutate_table_entry.sh` | `bash tests/shell/mutate_table_entry.sh` | 0 | `mutation gate: 39 mutations, 0 survived` |
| `mutate_app_package.sh` | `bash tests/shell/mutate_app_package.sh` | 0 | `mutation gate: 47 mutations, 0 survived` |
| `mutate_p4_exercise_tools.sh` | `bash tests/shell/mutate_p4_exercise_tools.sh` | 0 | `22 mutations, 0 survived` |
| 閘門衛生 1 | `python3 tests/shell/check_process_by_name.py` | 0 | `302 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` |
| 閘門衛生 2 | `python3 tests/shell/check_gate_anchors.py HEAD` | 0 | `111/111 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| 閘門衛生 3 | `python3 -m unittest tests.python.test_known_issues_references` | 0 | `OK` |
| 閘門衛生 4 | `python3 tests/shell/check_test_tmpdirs.py` | 0 | `337 file(s) scanned, 0 fixed temp paths` |
| 閘門衛生 5 | `bash tests/shell/test_redirection_order.sh` | 0 | `Ran 48 checks, 0 failed` |
| 閘門衛生 6 | `bash tests/shell/test_log_suffix_idempotent.sh` | 0 | `30 passed, 0 failed` |
| `test_topo_from_json.py` | `p4_proxy/venv/bin/python tools/test_workflow/test_topo_from_json.py` | 0 | `PASS -- derived wiring is identical to the hard-coded lists` |

- p4_proxy 全套的最後一行是直譯器關閉時的 `ResourceWarning`（既有現象，與本輪無關）；判定行是
  `grep -E '^(Ran|OK|FAILED)'` 抓到的 `Ran 1189 tests` / `OK (skipped=1)`。
  **base `8eddb0e8` 時是 `Ran 1069 tests, OK (skipped=1)`；+120 顆。** 唯一的 skip 是既有的
  `tests.test_p4_client.LiveSwitchTest.test_installs_routes_and_the_clone_session`
  （要 `NDTWIN_LIVE_SWITCH_OPT_IN=1` 才跑，會寫真交換機；§0-2 不允許）。
- tools/p4_exercise base 是 `Ran 106 tests, OK`；+48 顆。
- 🔴 **`merged_checks.sh` 沒有整支跑**：它第 4 行 `cd /home/adam/Desktop/NDTwin-Kernel`，
  也就是**主 checkout**，而 §0-5 禁止動主 checkout；整支跑會去檢查別人的樹、並用我的 sha 命名 log。
  所以我在**我的 worktree** 裡逐項跑了它的六項（上表閘門衛生 1–6，加 §2.7 要求進第七項的
  `test_topo_from_json.py`），每項各一個 log。**這不是「merged_checks 綠」的轉述，是六項各自的實跑。**

## 1b. 工單行號對帳（§0-8：碼為準）

在 base `8eddb0e8` 逐條查過工單 §1.2 引的行號。**只有一條漂了，其餘都對**：

| 工單寫 | 實際（`8eddb0e8`） | |
| --- | --- | --- |
| `sflow_emitter.py:425-429` `PKTIN_META_*` | 425 | ✅ |
| `sflow_emitter.py:435` `metadata_by_id` | 435 | ✅ |
| `sflow_emitter.py:446-485` `sample_from_packet_in` | 446 | ✅ |
| `sflow_emitter.py:498` `load_switch_agent_ips` | 498 | ✅ |
| **`p4_client.py:217/222` packet-out 的 `metadata_id = 1/2`** | **472／477** | 🔴 **漂了 255 行** |
| `p4_client.py:551` `probe` | 551 | ✅ |
| `p4_client.py:622` `write_clone_session` | 622 | ✅ |
| `p4_client.py:1245` `read_egress_counter` | 1245 | ✅ |
| `main.py:266-271` `SKIP_*` | 265 起 | ✅（差一行） |
| `main.py:286` `FOREIGN_PIPELINE_SWITCH_SKIPS` | 284 | ✅（差兩行） |
| `api_routes.py:559` `GET /p4/switch_state` | 559 | ✅ |
| `p4_src/build/ndtwin_switch.p4info.txt:210-265` `controller_packet_metadata` | 210 | ✅ |

還有一處數字對不上（不是行號）：**工單說既有變異 49 個，實數是 102**（§3.3）。

## 2. 做了什麼（對 §2.1／§2.6 逐條）

### G1 — packet-in metadata 按名字（§2.6 第一條）
- `sflow_emitter.packet_in_metadata_ids(p4info) -> PacketInIds`、`packet_out_metadata_ids(p4info) -> {name: id}`、
  `TelemetryHeaderMissing(missing, present)`；`sample_from_packet_in(packet_in, ids)` 的 `ids` 是**必填**
  （沒有預設值——預設在呼叫點看不見，忘記傳的那一個呼叫者會長得跟傳對的一模一樣）。
- `p4_client.__init__` 解析一次存 `self.packet_in_ids` / `self.packet_in_ids_error` / `self.packet_out_ids`；
  **缺 header 不是建構失敗**（`basic`／`source_routing` 沒有 controller header，那種交換機仍要能讀、能探、能寫）。
- `send_packet_out` 兩個 id 也按名字；對 `ndtwin_switch.p4info.txt` 解出 1 與 2，**LLDP beacon 逐位元組同 base**。
- `PKTIN_META_*` 常數留著當**期望值**（`test_sflow_emitter.P4InfoAgreementTest` 與 `test_packet_in_by_name` 對真 p4info 驗）。

### telemetry A — 合作式 include（§2.6 第二條）
- 新 `p4_proxy/p4_src/ndtwin_telemetry.p4`：兩個 controller header、六個常數、
  `NdtwinTelemetrySample`（ingress 一行 apply）、`NdtwinTelemetryEmit`（egress 一行 apply＋一個 out bool）。
- 證明：`tools/p4_exercise/tests/fixtures/basic_telemetry/basic_telemetry.p4`＝tutorials `basic` **解答**＋include＋七處標記編輯，
  用 `p4c-bm2-ss --p4v 16 -I <repo>/p4_proxy/p4_src --p4runtime-files … -o …` 編過（**p4c 1.2.5.15，rc 0**），
  p4info 的 `packet_in` 解得出五個名字、id 1..5。build 產物已 commit（`git add -f`，`.gitignore` 擋 `build/`，
  與既有 `firewall/build`、`calc/build` 同前例）。
- `ndtwin_switch.p4` **一個字都沒動**，也沒 include 它（§0-7）；兩份 header 的漂移由
  `test_telemetry_include.TheIncludeAndNdtwinSwitchAgreeTest` 逐欄位＋六個常數比對。

### 遙測來源（§2.1 的本地等價式）
- `main.TELEMETRY_{AUTO,NONE,COOPERATIVE,LINK}`、`TELEMETRY_KNOB_PATH = p4_proxy/mininet/telemetry_override`、
  `read_telemetry_knob(path)`（第一個非空非 `#` 行；不存在＝None＝auto；值域外＝`TelemetryConfigError`；空檔＝拒絕）、
  `package_telemetry_source(package)`（`getattr(package, "telemetry_source", "auto")`——**沒有 import B 的任何東西**）、
  `_telemetry_source(package, dpid, knob_path=None, base_dir=None)` 三層優先。
- startup 在**推 pipeline 之前**逐台解析並拒絕 `cooperative` ＋無 header 的組合（`TelemetryConfigError`，不是 warning）。
- 遙測迴圈三分岔：`read_only` / `broken` / `foreign` 三個既有跳過**原樣保留**（訊息、順序、`pipeline.skipped` 都沒動），
  之後多一個 `source != cooperative` 的跳過，所以 **`auto`＋NDTwin pipeline 走的是與 base 完全相同的那條路**。
- readopt 同步：`cooperative = ndtwin and source == cooperative` 決定 `sample_callback`；
  `install_routes` **仍只看 `ndtwin`**（`--telemetry link` 不該讓 power-cycle 後的交換機失去 NDTwin 的最短路徑）。

### G7 counter route
`GET /p4/counter/{name}?dpid=&index=` → 200／404（未知 dpid、counter 不在 p4info，`CounterNotFound` 訊息）／
503（讀失敗或無 entry，訊息明說「不是零」）／400（負 index）；`external` 下 **200**（ReadRequest 沒有 election_id 欄位）。
`read_egress_counter` 加 alias 查找。

### G8 multicast＋G9a PRE entries
- `p4_client.write_multicast_group(group_id, replicas, op)`：INSERT→MODIFY 退法與訊息照 `write_clone_session`，
  **但不抄它的 DELETE-first settle pair**（MODIFY 對 multicast group 是整份取代，疊加形狀不會發生）。
  拒絕：id<1、無 replica、replica 缺 port／負數／布林、**同一 (port, instance) 出現兩次**（PRE 會吸收第二個）。
- `POST /p4/multicast_group`：200／400／404／409／502；400/404/409 三列測試斷言 `stub.requests == []`。
- `write_clone_session(..., replicas=None)`：`None` ＝今天的單 replica，**baseline WriteRequest 逐欄位同 base**。
- startup／readopt 套 package 的 `multicast_group_entries` 與 `clone_session_entries`
  （`apply_package_pre_entries`），**每台都套**（PRE 物件與 pipeline 無關），在 table entries 之後、
  proxy 自己的 clone session 之前。

### G9b convert／preflight
- `convert._cpu_port`（int／字串／`0x` 前綴，0..511）＋`convert.package_cpu_port`（不一致 ⇒ `ConversionError` 指名兩台）；
  預設 `common.DEFAULT_CPU_PORT = 255`。
- convert 照舊整檔複製 runtime json ⇒ `multicast_group_entries`／`clone_session_entries` 原樣留著（有測試守）。
- preflight 新增 `_check_telemetry`（值域＋cooperative 的 header 自檢）與 `_check_pre_entries`
  （group id 正整數、replica 的 port 是模型給該台的埠或 `bmv2.cpu_port`、重複 (port, instance)）。

### 揭露（`GET /p4/switch_state`）
- 每台加 `telemetry {source, clone_session, sflow_registered, packet_in_ids, reason}` 與
  `pre_entries {multicast:{recorded,applied,failed}, clone:{…}}`；
  `control_plane` 加 `telemetry {knob, package, link_emitter}`，`link_emitter.alive` 是**請求當下**讀 `/proc/<pid>`。
- **既有鍵一個都沒動**；`pipeline.skipped` 照 P2 §7-7 不變。
- startup 回傳多三個鍵：`telemetry_sources`、`telemetry_report`、`pre_entries`。
  🔴 **既有的 `telemetry`（拿到 clone session 的 dpid 清單）沒有改名也沒有改語意**——工單 §5.2 寫
  「startup 回傳多 `telemetry` 鍵」，我讀成「多一個講遙測的鍵」而不是「把既有那個換掉」，
  因為 live-p1/01 讀它，同名換義是最壞的一種改法。

## 3. 變異表（哪個變異被哪顆測試殺）

### 3.1 新閘門 `tests/shell/mutate_telemetry_by_name.sh`（19＋2 控制，0 survived）

| 變異 | 內容 | 被殺於 |
| --- | --- | --- |
| M-C1 | ids 回常數不查 p4info | `test_a_reordered_header_gives_reordered_ids` |
| M-C2 | 缺名字不 raise | `test_a_pipeline_with_no_controller_header_names_all_five` |
| M-C11 | id 用欄位順序不用編譯器給的號 | `test_the_id_is_the_compilers_number_and_not_the_fields_position` |
| M-C12 | packet-out 的 egress_port 恆用 id 1 | `test_a_reordered_packet_out_header_is_followed` |
| M-C3 | `link` 下仍寫 clone session | `test_link_on_ndtwins_pipeline_programs_no_clone_and_registers_nothing` |
| M-C4 | `none` 下仍 `register_switch` | `test_none_on_ndtwins_pipeline_samples_nothing_at_all` |
| M-C5 | cooperative＋無 header 的 pipeline 不拒 | `test_cooperative_on_a_foreign_pipeline_refuses_to_start` |
| M-C13 | knob 讀了不用 | `test_the_knob_beats_the_package` |
| M-C14 | 值域外的字被接受 | `test_a_word_outside_the_domain_is_refused_rather_than_defaulted` |
| M-C6 | counter 404 改回 200 零 | `test_a_counter_this_pipeline_does_not_have_is_404` |
| M-C15 | 讀失敗回 200 零 | `test_a_failed_read_is_503_rather_than_a_zero` |
| M-C7 | multicast replica 少 `instance` | `test_instance_defaults_to_one_rather_than_zero` |
| M-C16 | 重複 replica 檢查拿掉 | `test_the_same_port_and_instance_twice_is_refused_and_names_the_pair` |
| M-C8 | PRE entries 失敗計成 applied | `test_a_refused_group_is_counted_as_failed_not_applied` |
| M-C17 | package 的 PRE entries 整段不套 | `test_a_declared_group_is_programmed_on_ndtwins_own_pipeline_too` |
| M-C18 | 預設 clone replica 的 instance 改成 0 | `test_no_replicas_argument_writes_one_replica_to_the_cpu_port` |
| M-C10 | `link_emitter.alive` 恆 true | `test_a_dead_pid_reads_dead` |
| M-C19 | switch_state 不再講每台的來源 | `test_each_switch_carries_its_own_telemetry_object` |
| M-C20 | 每台都報 cooperative | `test_link_on_ndtwins_pipeline_programs_no_clone_and_registers_nothing` |
| N1（控制） | 註解 only | 全綠 |
| N2（控制） | `{}` 寫成 `dict()` | 全綠 |

🔴 **兩顆寫了、跑了、被換掉的變異，因為它們「正確地存活」**（兩顆都是等價變異，閘門檔頭寫了原委）：
① 把預設 replica 的 `"instance": 1` 拿掉——下面的 `spec.get("instance", 1)` 會補回來；
② 把那個 `.get` 的預設改成 0——唯一會省略 `instance` 的呼叫者是 package 自己的 replica 清單，預設路徑是寫死的。
唯一可觀測的差別是預設路徑寫上線的值，所以變異要做在那裡。教訓是閘門的：
**「這行看起來很重要」和「改這行會改變上線的位元組」不是同一個宣稱。**

### 3.2 `tests/shell/mutate_p4_exercise_tools.sh` 續號 17–22（合計 22，0 survived）

| 變異 | 內容 | 被殺於 |
| --- | --- | --- |
| 17 | 兩台 cpu_port 不一致仍通 | `test_switches_that_disagree_are_refused_and_both_are_named` |
| 18 | 字串 cpu_port 不轉 int | `test_a_string_cpu_port_becomes_an_integer` |
| 19 | preflight 接受值域外的遙測字 | `test_a_word_outside_the_domain_fails` |
| 20 | preflight 的 cooperative 自檢失效 | `test_cooperative_on_a_program_with_no_controller_header_fails` |
| 21 | replica 可以指到模型沒有的埠 | `test_a_replica_on_a_port_the_model_does_not_build_fails` |
| 22 | 同一 (port, instance) 兩次仍通 | `test_the_same_replica_twice_fails` |

### 3.3 既有閘門：**全殺，一個都沒少**

| 閘門 | 變異數 | survived |
| --- | --- | --- |
| `mutate_app_package.sh`（rehash 我動的三個檔） | 47 | 0 |
| `mutate_table_entry.sh` | 39 | 0 |
| `mutate_p4_exercise_tools.sh`（含新增的 6 顆） | 22 | 0 |
| `mutate_telemetry_by_name.sh`（新） | 19 | 0 |

⚠️ **工單說「49 個既有變異」，實際是 47＋39＋16＝102**（`mutate_app_package.sh` 47、`mutate_table_entry.sh` 39、
`mutate_p4_exercise_tools.sh` 16）。以碼為準，這裡列實數。

#### `mutate_table_entry.sh` 五個 anchor 修過＋一個覆蓋洞（沒有削弱任何變異）
🔴 **judge 更正（round 2）**：本節原本寫「六個全是 anchor 漂了」，與它自己引的 log 矛盾。
第一次跑是 **39 mutations, 6 survived**（log：`mutate_table_entry.p3c-4406c17e-pre.log`），
其中**五個**是 anchor 不唯一／找不到（log 有 `anchor not unique`）：M-B20／M-B12／M-B23／M-B27／M-B32；
**M-B9 不是**——它的 log 是 `Ran 400 / OK`，變異套用成功、測試全綠，是**真的存活**
（`auto` 把外來 pipeline 解成 `link`，foreign guard 與來源檢查互相遮蔽）。
下面 §3.4 與異議 ① 本來就是這樣解釋的，是本節的措辭錯了。五個 anchor 的修法逐一列在後面：

- **M-B20／N3（控制）**：`"journaled": False, "note": …` 與 `op = data.get("op", "insert")`
  本輪各多了第二個出現點（multicast route 帶同一句不 journal 的警告、同樣的 op 預設）⇒ anchor 命中 2 次。
  🔴 **N3 是控制組**，它命中兩次等於控制組什麼都沒證明——這是這次修 anchor 最該記的一條。
- **M-B27**：`result["clone_session"] = False` 現在有兩個寫入點，而舊 anchor（4 空格）是新那行（12 空格）的**子字串**。
- **M-B12**：readopt 的那個 `if` 裡多了遙測那段，兩行 anchor 不再連續。
- **M-B23／M-B32**：callback 改成看 `cooperative`。

每一個都是**往還唯一的那一行延長**，不是縮短。修完重跑 0 survived。

#### M-B9 需要的不只是 anchor
`auto` 下外來 pipeline 解析成 `link`，所以**就算把 foreign 那個 guard 刪掉**，下面的來源檢查照樣會跳過那台——
兩個 guard 互相遮蔽，正是 `read_only` 與「沒有 agent IP」曾經互相遮蔽的形狀（`main.py` 那段註解記著）。
所以 M-B9 指名的測試現在多一格：**外來 pipeline ＋ knob 明寫 `cooperative` ＋ 該台的 p4info 帶得動 header**——
那是 foreign guard 唯一在做事的情況。那一格同時是下面的異議 ①。

## 4. 沒做／沒驗的（明列）

1. **沒有任何 live**：不 sudo、不 `ndt up`、不 `mn`、不起 bmv2、不開 psample socket（§0-2）。
   所有測試離線：stub 的 gRPC stub、stub client、in-memory p4info、fixture p4info 檔。
   **`ndtwin_telemetry.p4` 只證明「編得過而且 p4info 對」，沒有證明它在 bmv2 上真的 clone 出樣本**——
   那要 live，屬 orchestrator。
2. **`telemetry_override` 這個 knob 檔沒有被任何東西寫過**（寫入者只有 D 的 `ndt`，§2.1）。
   我只驗了讀：值域、三層優先、空檔拒絕、缺檔＝auto。
3. **`app_package.telemetry_source` / `Package.telemetry_source` 沒碰**（B 的檔）。
   `package_telemetry_source` 用 `getattr` 讀，所以在 B 併回前每個 package 都答 `auto`，
   宣告那一層的測試是用**子類別帶類別屬性**餵的（`test_startup.declaring_telemetry`）。
   ⇒ **「package 宣告 cooperative」這條路徑在真 `Package` 上沒有驗過**，B 併回後 orchestrator 要重跑。
4. **`link_emitter` 的 manifest 格式是照 §2.5 的描述讀的，不是照 B 的實作**：
   我讀 `emitter_pid`（fallback `pid`）、`rate`、`switches`。⇒ **併回後要對一次真 manifest**。
   🔴 **judge 更正（round 2）**：原文寫「B 若用別的鍵名，這裡會安靜地讀成 `None`／空」——**不精確**。
   B 的 `switches` 是**物件清單**而我當 dict 迭代，結果是一串 **dict 被字串化**的東西：
   既不是 `None` 也不會炸，是**安靜地錯**，而我的 fixture 用同一個錯形狀寫的，所以沒有測試抓得到。
   （round 2 已改：見 §7 的 R5；fixture 改由 `link_telemetry.manifest_document()` 自己產。）
5. **`alive` 只證明「有一個行程用這個 pid」**，不證明它是 emitter（pid 會重用）。
   更強的檢查（讀 `/proc/<pid>/cmdline`）留給 `ndt verify_p4`（D），程式碼註解寫了。
6. **502 那一列沒有斷言「沒有 Write 上線」**：`POST /p4/multicast_group` 的 502 是**交換機的回答**，
   WriteRequest 必然出去過。工單 §2.6 寫「任何非 200 沒有 Write 上線」，這一列做不到，
   也不該做到——照 §2.3 對 `table_entry` 的同一個論證處理，400／404／409 三列才斷言 `stub.requests == []`。
7. **502 的 body 沒有帶 gRPC status 名字**：`write_multicast_group` 保持 `write_clone_session` 的
   布林契約（§2.6 說「規則與訊息照 `write_clone_session`」），code 名字印在 proxy log 裡。
   要在 body 裡給的話得改那個契約——沒改，寫在這裡。
8. **`p4c` 的 unused 警告**：`NDTWIN_PKTIN_REASON_PACKET_IN` 在 include 內部沒人讀（它是給 include 方用的），
   p4c 1.2.5 的 `@unused` 不消這個警告。**rc 仍是 0**，警告內容寫進了那個常數的註解。
9. **沒有跑整支 `merged_checks.sh`**（理由見 §1 最後一條），改成在自己的 worktree 逐項跑六項＋第七項。
10. **`tools/contract_test/**` 沒動**（沒撞到 schema）。
11. **`topology_manager.py` 沒動**：readopt 的遙測分岔全部在 `main.readopt_switch` 這一側表達得完
    （`sample_callback` 給不給、`install_routes` 給不給），不需要下到那個函式裡。

## 5. 異議／objections

① **🔴 `ndtwin_telemetry.p4` 目前對「用它的人」沒有作用，而這正是它存在的理由。**
  `main.startup` 的遙測迴圈裡，`i in foreign` 那個分岔（TICKET-P2 §2.2、§7-7 凍結的）**先於**來源判斷，
  所以一台跑自己程式、但**已經 include 了 `ndtwin_telemetry.p4`**、而且 package 明寫 `telemetry.source: cooperative`
  的交換機，仍然拿不到 clone session，也不會被 `register_switch` —— 只有揭露（`telemetry.reason`）說了為什麼。
  兩個相衝的條文：
  - §2.1 的拒絕**判準是 header**（「`cooperative` 對**沒有合作式 header 的 pipeline**＝拒絕啟動」），
    這暗示「有 header 的外來 pipeline」是應該可以 cooperative 的；
  - §2.6 末條與 P2 §7-7 把**外來台的 `pipeline.skipped` 固定成 `[clone_session, sflow_telemetry]`**，
    而 `pipeline_report_for` 的 `skipped` 是 `ndtwin` 的函式，import 時就算好了。
  兩邊不能同時成立：要讓這種台拿到 cooperative telemetry，`pipeline.skipped` 就必須停止只看 `ndtwin`——
  那是契約改動，**不是我這張工單能自己決定的**，所以我**保留了 P2 的行為**並把這條寫在這裡。
  （我也沒有選另一條路：把 foreign 分岔刪掉讓來源判斷接管。那會讓 `mutate_table_entry.sh` 的 M-B9
  變成等價變異，而工單要求既有變異全殺。M-B9 的測試改成覆蓋這一格，正好把這個洞釘在測試裡。）
  **建議**：orchestrator 裁「`pipeline_report_for.skipped` 改成看『這台實際跳過了什麼』」，
  或裁「include 的用法是 package 宣告 `pipeline: null` 以外的第三種形態，下一輪處理」。

② **`bmv2.cpu_port` 與 pipeline 編進去的 CPU port 沒有交叉檢查。**
  G9b 之後 package 可以宣告 `cpu_port: 510`（flowcache），而 `ndtwin_switch.p4` 與 `ndtwin_telemetry.p4`
  都把 `CPU_PORT = 255` 編進去。一台用 NDTwin pipeline、package 卻宣告 510 的交換機，
  **bmv2 會用 510 起，pipeline 會往 255 送**，控制器封包全丟、沒有任何一邊報錯。
  preflight 查得到這件事（package 的 `cpu_port` vs 該台 p4info／bmv2 json）——
  但 **bmv2 json 裡沒有可靠的 CPU port 欄位**，而 p4info 也不帶它，所以要嘛比對 `.p4` 原始碼的常數
  （脆弱），要嘛由 B 在 bring-up 時拒絕。**沒做，寫在這裡。**

③ **`apply_package_pre_entries` 在每台都跑，包括 NDTwin pipeline 的台——這是我自己下的判斷。**
  §2.6 只寫「startup 對 package 的 entries 檔**也套** `multicast_group_entries` 與 `clone_session_entries`」，
  沒說限於外來台。理由寫在碼裡：PRE 物件裡沒有程式，`mcast_grp 1 -> 2,3,4` 在哪個 pipeline 下都是同一件事，
  而 `convert --ndtwin-pipeline` 做出來的 package（live-p1/02 用的那種）正是「只有這條路會丟掉它的 group」的情況。
  **但它跟 table entries 的處理不對稱**（table entries 在 NDTwin pipeline 下只 recorded 不 applied），
  一個 package 若宣告了 session 250，會在 proxy 自己寫之前先被套上去（proxy 的寫在後面所以贏）。
  若 orchestrator 認為 PRE 也該只在外來台套，改一個 `if` 就好，測試會告訴你哪幾顆要跟著改。

④ **`sample_from_packet_in` 的簽章是破壞性變更（多一個必填參數）。**
  repo 內唯一的生產呼叫者是 `p4_client.handle_packet_in`，已改；測試呼叫點也全改了。
  但 §1.2 記著這個模組「可被 ntg-env 的 python 以檔案路徑 import」——**B 的 `psample_sflow_emitter.py`
  會 import 它**。B 只用 `SampledPacket`／`SFlowEmitter.emit`／`build_datagram`，照 §2.5 不會碰
  `sample_from_packet_in`；若碰了，併回時會是 TypeError（不是安靜的錯），這是刻意的。

⑤ **`GET /p4/counter/{name}` 的 `name` 是 path parameter，含 `/` 的名字進不來。**
  P4 的完整名字用 `.` 分隔（`MyEgress.egress_port_counter`），目前沒有帶 `/` 的；
  若哪天有，這個端點會 404 而不是報「名字裡有斜線」。測試把「它是 `StringConvertor` 不是 `PathConvertor`」釘住了。

⑥ **`_telemetry_source` 每呼叫一次讀一次 knob 檔。** startup 對每台各讀一次（10 台＝10 次 open），
  `readopt_switch` 每次讀一次。不是熱路徑，但**如果 knob 在 startup 中途被改寫，同一個 fabric 上的兩台會拿到兩個答案**——
  所以 startup 是在迴圈**外**一次解析完全部再進迴圈的（`telemetry_sources` dict）。
  readopt 沒有這個保護（它本來就是一台一台的）。

## 6. 給 orchestrator 的實跑清單（併回後）

1. B 併回後：對一次真 `/tmp/ndtwin_link_telemetry.json` 的鍵名（`emitter_pid`／`rate`／`switches`），
   以及真 `Package.telemetry_source` 欄位——本輪那兩條都是照契約寫的，不是照實作。
2. A 併回並重建 kernel 後：`live-p1/01` 的 baseline 逐格＋新鍵
   （`telemetry.source == "cooperative"`、`clone_session == true`、`sflow_registered == true`、
   `packet_in_ids == {reason:1, ingress_port:2, egress_port:3, frame_length:4, sampling_rate:5}`、
   `pre_entries` 全 0、`control_plane.telemetry.knob == "absent"`、`link_emitter == null`）。
3. `ndt up p4 4 --telemetry link` 之後：每台 `telemetry.source == "link"`、`clone_session == false`、
   `pipeline.skipped` 照舊、`control_plane.telemetry.link_emitter.alive == true`。
4. 異議 ① 要不要改，在 E 的三組量測之前裁——`cooperative` 組若打算用 include 而不是 NDTwin pipeline，
   現在的碼會給你一組沒有樣本的資料。

---

# 7. Round 2（judge MERGE AFTER FIXES ＋ TICKET-P3 §9-4／§9-5）

worker「P3-C」2026-09-19 續寫。round 1 的數字上面原樣保留（除了 judge 指出的兩處措辭更正，已就地標注
「judge 更正（round 2）」）。

## 7.0 base／head／commit（round 2）

- **`git merge trunk` 不 rebase**：trunk `b8d6e597`＝`8eddb0e8`＋工單＋B 的 merge `f5ad6890`＋§9 裁定。
  merge commit `7069d84a`，**沒有衝突**（B 的檔與我的不重疊；唯一擋路的是我 round 1 沒 commit 的
  工單 untracked 複本，那是舊快照，刪掉後 merge 帶進 trunk 的正本）。
- **head `c293d23d`**（round 1 的 `8f3e5e3a` 沒有被改寫）。

| sha | 內容 |
| --- | --- |
| `7069d84a` | `Merge branch 'trunk' into feat/p3-proxy-telemetry-pre-0919` |
| `7ab3e3be` | P3-C 05: one implementation of the telemetry rule, and the include actually works |
| `c293d23d` | P3-C 06: M-B9 retires with its reason, and the gates follow the rule to where it moved |

## 7.1 §9-5：一份實作（R5）

| 做了什麼 | commit | 被哪個測試／變異釘住 |
| --- | --- | --- |
| `main._telemetry_source` ⇒ 一行呼叫 `app_package.telemetry_source`；`read_telemetry_knob` ⇒ 一行呼叫 B 的；`package_telemetry_source` **刪掉**（B 的 loader 已驗值域，M48） | `7ab3e3be` | `TheOneImplementationTest`（50 格 grid）＋`test_the_proxy_does_not_carry_its_own_copy_of_the_rule`（結構斷言：函式體必須含 `app_package.telemetry_source`、不得含 `pipeline_is_ndtwin`） |
| `AppPackageError` ⇒ `TelemetryConfigError`（保住 startup 的拒絕語意，且兩種錯不共用一個類別） | `7ab3e3be` | `test_a_refusal_from_the_package_reader_arrives_as_a_telemetry_refusal`（含 `__cause__` 斷言）；**M-C14** |
| 四個字與 knob path **re-export 不 re-spell**（`main.TELEMETRY_LINK is app_package.TELEMETRY_LINK`） | `7ab3e3be` | `test_the_words_are_the_same_objects_not_equal_copies`、`test_the_two_modules_name_the_same_knob_file` |
| `main.TELEMETRY_KNOB_PATH` 仍是**可 patch 的預設**（`knob_path or TELEMETRY_KNOB_PATH`）——不傳的話 app_package 會用它自己的預設，patch 就失效 | `7ab3e3be` | **M-C13**（丟掉呼叫者給的 knob path ⇒ `test_the_knob_beats_the_package` 紅） |
| `link_emitter_report` 改走 `link_telemetry.read_manifest`，`switches` 當**物件清單**讀、回 sorted dpid（int） | `7ab3e3be` | `test_the_switches_come_back_as_dpids_and_not_as_stringified_objects`；**M-C21**（把 round 1 的碼原樣放回去） |
| `alive` 改用 `link_telemetry.process_is_the_emitter(pid)`（讀 cmdline） | `7ab3e3be` | `test_a_pid_that_is_not_the_emitter_reads_dead`（**用本測試行程自己的 pid**：活著、但不是 emitter ⇒ round 1 的 `/proc/<pid>` 會說 alive）、`test_a_pid_whose_cmdline_is_the_emitter_reads_alive`；**M-C10** |
| fixture 改由 `link_telemetry.manifest_document()` 本人產（不是手寫 dict） | `7ab3e3be` | 整個 `TheLinkEmitterSummaryTest` |
| `LINK_TELEMETRY_MANIFEST` 改成 `link_telemetry.LINK_TELEMETRY_MANIFEST` | `7ab3e3be` | `test_the_proxy_reads_the_path_the_bring_up_writes` |
| `declaring_telemetry` 改用真 `Package`（`dataclasses.replace`） | `7ab3e3be` | 整個 `TelemetrySourceTest`——🔴 **round 1 的子類別技倆在 B 的欄位變成真的那一刻就安靜失效**（instance attribute 蓋掉 class attribute），merge 後三顆測試立刻紅，這就是它 |

🔴 **一個行為在 collapse 時變了，明講不默默接受**：B 的 `read_telemetry_knob` 對「檔案存在但沒有
directive 行」回 `None`（＝package 決定），round 1 我這邊是**拒絕**。B 是唯一實作了，所以採 B 的；
`ndt` 是唯一寫入者而且是刪檔不是清空，所以空檔＝半成品寫入這件事現在由「package 決定」接手。
測試改名為 `test_an_empty_knob_reads_as_nothing_rather_than_raising`，理由寫在測試裡。

## 7.2 §9-4：include 真的生效（R4）

| 做了什麼 | commit | 被哪個測試／變異釘住 |
| --- | --- | --- |
| 遙測迴圈的 foreign 分岔改成 `if i in foreign and source != TELEMETRY_COOPERATIVE:` | `7ab3e3be` | `test_a_foreign_program_that_included_the_header_gets_the_cooperative_path`；**M-B9b**（`mutate_table_entry.sh`，取代退休的 M-B9） |
| `switch_skips_for(package, dpid, ndtwin, cooperative)`＝**每台實際跳過什麼**的唯一定義；startup 用實際決策 `_record_pipeline_skips` 覆寫，endpoint 在 startup 前用同一個函式**預測** | `7ab3e3be` | `test_that_switch_says_it_skipped_nothing`、`test_the_endpoint_answers_the_same_before_startup_has_run`、`test_an_external_fabric_reports_both_skipped_whatever_the_source_says`；**M-C22**、**M-B28** |
| readopt 同步：`cooperative = source == cooperative and (ndtwin or pipeline_carries_telemetry(...))`，問的是 **p4info 檔**（client 還沒建） | `7ab3e3be` | `test_a_readopted_foreign_switch_with_the_header_keeps_its_clone_session`、`test_a_readopted_foreign_switch_without_the_header_still_gets_none`；**M-C23**、**M-B27** |
| `p4_client.pipeline_carries_telemetry(p4info_path)`（模組函式，任何失敗一律 False） | `7ab3e3be` | 上兩顆 |
| fabric 級三個跳過（lldp／watchdog／routes）**對任何外來 pipeline 照舊** | `7ab3e3be` | `test_the_fabric_level_skips_are_unchanged_for_it` |
| `auto` 的語意**沒動**（問的是「誰的 pipeline」不是「這個 pipeline 做得到什麼」） | `7ab3e3be` | `test_the_same_program_under_auto_is_still_link`、`test_a_plain_foreign_program_still_says_both_were_skipped`（＝live-p1/02 那一格） |
| 測試改用**真的編譯產物**：`basic`（零 controller header）與 `basic_telemetry`（同一份解答＋include） | `7ab3e3be` | 上列全部——round 1 用的是不存在的檔名，在「誰的 pipeline」時代夠用，在「p4info 內容說了算」之後不夠 |

**M-B9 退休**（`c293d23d`，理由寫進 `mutate_table_entry.sh` 檔頭）：它變成等價變異，因為 `auto` 把外來
pipeline 解成 `link`，foreign guard 刪掉之後來源檢查會跳過同一台。取而代之的是 **M-B9b**，方向相反：
這個分岔**不可以**把「帶得動 header 的那台」也吞掉。負向那一邊仍有覆蓋
（`test_a_foreign_pipeline_that_cannot_carry_the_header_still_gets_nothing` 的拒絕，加 M-C3／M-C22）。

## 7.3 Round 2 的閘門表（head `c293d23d`；log 在 `gates-0910/<gate>.p3c-c293d23d.log`）

| 套件／閘門 | rc | 最後一行 |
| --- | --- | --- |
| p4_proxy 全套 | 0 | `Ran 1365 tests` ／ `OK (skipped=1)`（round 1 是 1189；B 的 merge 帶進 +158，我這輪 +18） |
| tools/p4_exercise | 0 | `Ran 154 tests` ／ `OK`（不變） |
| 契約自測 | 0 | `Self-test passed: 166 checks` |
| `mutate_telemetry_by_name.sh` | 0 | `22 mutations, 0 survived`（round 1 是 19；＋M-C21／C22／C23，M-C10／C13／C14 retarget） |
| `mutate_table_entry.sh` | 0 | `39 mutations, 0 survived`（M-B9 退休、M-B9b 進來，總數不變） |
| `mutate_app_package.sh` | 0 | `48 mutations, 0 survived`（含 B 的 M48） |
| `mutate_p4_exercise_tools.sh` | 0 | `22 mutations, 0 survived` |
| `check_gate_anchors.py c293d23d` | 0 | `112/112 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `check_process_by_name.py` | 0 | `307 file(s) scanned, 0 site(s), 0 registered, 0 new, 0 stale` |
| `check_test_tmpdirs.py` | 0 | `340 file(s) scanned, 0 fixed temp paths` |
| kiref | 0 | `OK` |
| `test_redirection_order.sh` | 0 | `Ran 48 checks, 0 failed` |
| `test_log_suffix_idempotent.sh` | 0 | `30 passed, 0 failed` |
| `test_topo_from_json.py` | 0 | `PASS -- derived wiring is identical to the hard-coded lists` |

## 7.4 Round 2 沒做／沒驗的

1. **`mutate_link_telemetry.sh` 沒跑**（B 的閘門，B 的檔；trunk 已綠，我沒動那些檔）。
2. **仍然沒有任何 live。** include 的 cooperative 路徑到今天為止證明的是：p4info 帶五個名字、
   proxy 會寫 clone session、會 `register_switch`、`skipped` 說 `[]`。
   **「bmv2 真的把樣本 clone 出來、kernel 真的收到」沒有驗過**——那要 orchestrator 跑 live。
   建議 live 清單多一格：`--app <含 include 的 package> --telemetry cooperative`，看
   `switch_state` 每台 `telemetry.clone_session == true`、`pipeline.skipped == []`，且鏈路使用率非零。
3. **`_telemetry_source` 仍然每次呼叫讀一次 knob 檔**（round 1 異議 ⑥ 未變）。startup 仍在迴圈外一次解析
   全部；`switch_skips_for` 的**預測**路徑會再讀一次（endpoint 每次請求各一次）。不是熱路徑，但
   `GET /p4/switch_state` 每秒被 kernel 打一次 ⇒ **每秒 N 次 open**。若要省，orchestrator 裁「預測值在
   startup 後就被實際值覆寫，所以 endpoint 不必再預測」即可。
4. round 1 的異議 ②（`bmv2.cpu_port` vs pipeline 編進去的 CPU port）、⑤（counter 名字含 `/`）、
   ⑦（502 不帶 gRPC code 名）已由 §9-6 收為**階段三候選**，本輪沒做。

## 7.5 Round 2 的異議

① **`switch_skips_for` 的「預測」與「實際」用的是兩個不同的證據來源，我認為這是對的，但值得裁一次。**
  startup 判斷「這台能不能 cooperative」用的是 **client 的 `packet_in_ids`**（那是這個 client 真的會拿去
  講話的 p4info）；`switch_skips_for` 在 startup 之前**預測**時用的是 **package 指的 p4info 檔**
  （`pipeline_carries_telemetry`）。真跑時兩者是同一個檔，所以不會不一致；**但測試用的 double 可以讓它們
  不一致**（我的 `cell()` 特地把 double 的 ids 跟 package 的 p4info 對齊，就是為了不靠這個巧合）。
  若 orchestrator 希望只有一個證據來源，那就得讓 `pipeline_report_for` 在 startup 前回 `null` 而不是預測——
  代價是 kernel 的第一次 poll 讀到 `null`，而 `null` 與「這個 proxy 太舊沒有這個鍵」分不開。我選了預測。

② **`auto` 對「帶得動 header 的外來 pipeline」仍然回 `link`，是 §9-4 的字面，但我懷疑它不是作者想要的。**
  一個 exercise 作者 include 了 `ndtwin_telemetry.p4`，最自然的期待是「我做了該做的，twin 就會動」；
  現在他還必須在 package 裡寫 `telemetry.source: cooperative`，否則 `auto` 把他丟給 link emitter
  （需要 root、需要 tc、需要 B 的 emitter 活著）。改法只有一行——`auto` 的第三層改問
  `pipeline_carries_telemetry` 而不是 `pipeline_is_ndtwin`——但那是 **B 的 `app_package.telemetry_source`**，
  §0-7 說我不能動，而且會改變 `basic` 以外每一個 package 的預設行為。**寫在這裡，不動。**

③ **`process_is_the_emitter` 認的是 `psample_sflow_emitter.py` 這個 basename 出現在 cmdline 裡。**
  這比 round 1 的 `/proc/<pid>` 存在強得多，但仍不是身分證明：任何 cmdline 裡有這個字串的行程都算
  （例如 `vim psample_sflow_emitter.py`，若它恰好拿到那個 pid）。那是 B 的判準，我照用不另立一套——
  兩套判準會讓 `ndt verify_p4` 與 `switch_state` 對同一個 pid 給不同答案，那比這個殘留風險糟。

---

# 8. Live-fix round（TICKET-P3 §9 裁定 23②）

worker「P3-C」2026-09-19 15:3x 續寫。§1–§7 的數字原樣保留。

## 8.0 base／head

- `git -C <wt> merge trunk`（不 rebase）：trunk **`7b09e6e3`**（＝§9 裁定 19–23，A／B／D／E 的 live 修都在）。
  **我的檔沒有衝突**（merge 只帶進別人的檔與工單）。
- **head `917b239c`**；round 2 的 `c293d23d` 沒有被改寫。
- commit：`917b239c` *P3-C 07: an EXACT value written as a one-element list is what the exercises actually ship*。

## 8.1 缺陷與修法

上游 `p4lang/tutorials` 的 `basic_tunnel/sX-runtime.json` 把 exact 欄位的值寫成**單元素 list**
（`"hdr.myTunnel.dst_id": [1]`），而那些 exercise 所對應的**參考控制器會把它拆開**：

    /home/adam/tutorials/utils/p4runtime_lib/convert.py:71-75
        def encode(x, bitwidth):
            byte_len = bitwidthToBytes(bitwidth)
            if (type(x) == list or type(x) == tuple) and len(x) == 1:
                x = x[0]

我的 writer 比參考實作嚴 ⇒ `basic_tunnel/solution` 每台 6 筆裡有 3 筆被拒，兩次 live 都紅
（`logs/orchestrator-0919/probe2-basic_tunnel-proxy.log`）。**是拒絕不是靜默寫錯**，所以沒有錯誤轉發；
但 fabric 起來只跑了半個 exercise，而 `tools/p4_exercise/preflight.py` 對同一個 package 是綠的
⇒ 操作者拿到綠 pre-flight 之後得到半套規則。

修：`p4_client.build_table_entry` 對 **EXACT** 欄位接受單元素 list／tuple 並**拆開**（在推型別之前，
與上游同序，所以 list 裡的字串仍被讀成 MAC／位址）；**雙元素仍拒**——`[value, prefix_len]` 是 lpm、
`[value, mask]` 是 ternary 的形狀，在 EXACT 欄位上收下它，會把「比對一個網段」的規則裝成
「比對一個位址」：會轉發、其餘全黑洞、哪裡都不報錯。`[]`／三元素／`[[1]]` 也仍拒（一層，不遞迴）。

## 8.2 看過紅（sha 與最後幾行）

新套件 `p4_proxy/tests/test_exact_one_element_list.py`，subject 是**真的** runtime 檔與**真的**編譯
p4info（byte copy 自 `~/tutorials/exercises/basic_tunnel/`）。在**修之前**的 `7b09e6e3` 跑：

    log: gates-0910/test_exact_one_element_list.p3c-7b09e6e3-RED.log
    Ran 14 tests in 0.051s
    FAILED (failures=4, errors=6)

紅的格（10）：`test_all_six_of_basic_tunnels_entries_go_on`（entry 3／4／5＝三筆 myTunnel_exact）、
`test_the_unwrapped_value_is_the_number_and_not_the_list`、`test_a_one_element_tuple_is_unwrapped_too`、
`test_a_one_element_list_holding_an_address_is_unwrapped_too`、
`TheProxyAndPreFlightAgreeTest.test_both_accept_every_entry_the_exercise_ships`（entry 3／4／5）。
修後 `Ran 14 / OK`。

**preflight 對帳格**（裁定要求）：`TheProxyAndPreFlightAgreeTest` 直接拿同一份 entries、同一個
`P4InfoIndex`，比 `preflight.check_entry` 與 `client.write_table_entry` 的**接受／拒絕**。
六筆**兩邊同答（都接受）**，`[2, 16]` **兩邊同答（都拒絕）**——反向那一格是為了不讓「兩邊同意」被
「pre-flight 什麼都收」滿足。**沒有編輯 `preflight.py`。**

## 8.3 變異（`tests/shell/mutate_table_entry.sh`，39 → 41）

| 變異 | 內容 | 被殺於 |
| --- | --- | --- |
| **M-B40** | 拆開拿掉（又比參考實作嚴） | `test_all_six_of_basic_tunnels_entries_go_on` |
| **M-B41** | `len(raw) != 1` 改成 `> 2`（EXACT 收下 lpm 形狀的 pair） | `test_a_two_element_pair_on_an_exact_field_is_still_refused` |

新套件也進了該閘門的 baseline（7 個測試檔）。

## 8.4 閘門表（head `917b239c`；log 在 `gates-0910/*.p3c-917b239c.log`）

| 套件／閘門 | rc | 最後一行 |
| --- | --- | --- |
| p4_proxy 全套 | 0 | `Ran 1394 tests` ／ `OK (skipped=1)`（round 2 是 1365；＋14 是本輪、＋15 來自 merge） |
| 契約自測 | 0 | `Self-test passed: 166 checks` |
| `mutate_table_entry.sh` | 0 | `41 mutations, 0 survived` |
| `mutate_telemetry_by_name.sh` | 0 | `22 mutations, 0 survived` |
| `mutate_app_package.sh` | 0 | `48 mutations, 0 survived` |
| `check_gate_anchors.py 917b239c` | 0 | `115/115 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| tools/p4_exercise | **1** | `Ran 154 tests` ／ `FAILED (failures=1)` ⚠️ 見 §8.5 |
| `mutate_p4_exercise_tools.sh` | **2** | `REFUSE: baseline is RED before any mutation.` ⚠️ 見 §8.5 |

## 8.5 ⚠️ 兩格紅／拒絕，原因**不是本輪的改動**，我沒有動它

紅的是 `test_convert.FixtureProvenance.test_every_fixture_is_still_byte_identical_to_its_tutorials_original`，
它說三個 fixture 與 `~/tutorials` 不再逐位元組相同：

| 檔 | 我的 fixture（＝`8eddb0e8` 的位元組） | `~/tutorials` 的 mtime |
| --- | --- | --- |
| `basic/build/basic.json` | `7fefd0e1e6ae734d` 未變 | **2026-09-19T14:34** |
| `basic/build/basic.p4.p4info.txtpb` | `f71c1fb75f39c62d` 未變 | **2026-09-19T14:34** |
| `p4runtime/build/advanced_tunnel.json` | `a1e89cd9ec165a37` 未變 | **2026-09-19T14:56** |

- 三個檔我這輪**一個都沒碰**（`git log 8eddb0e8..HEAD -- <那兩個 build 目錄>` 是空的），
  而且與 `8eddb0e8` 的版本 sha 相同。
- **動的是上游**：live 跑會在 exercise 目錄 `make`，而 driver 的 `compile_prog()` 把**解答**編到
  **骨架的輸出名**（工單 §1.4），所以 `~/tutorials/exercises/*/build/` 在 13:3x–15:1x 的 live 視窗裡被重寫。
  p4info 的差別就是一個 `action_id`（`21257015` → `25652968`）＝另一個程式的編譯。
- **時間上也對得起來**：round 2 這兩個東西在 **04:45／04:53** 是綠的
  （`tools_p4_exercise_tests.p3c-c293d23d.log` `Ran 154 / OK`、`mutate_p4_exercise_tools.p3c-c293d23d.log`
  `22 mutations, 0 survived`），上游重寫發生在那之後。
- 閘門 rc 2 是它**該有的行為**：baseline 紅時拒絕給裁決（「紅 baseline 上的變異什麼都沒證明」）。
- **我故意不改**：這個檢查正在做它的工作（它說「fixture 與上游不同了」，而那是真的）。
  要往哪邊收斂不是我能單方面決定的——它牽涉 D 的 live harness 會重寫一棵大家當唯讀的樹。
  🔴 **後來的事實（round 2 更正）**：**orchestrator 用 repo 的 fixture 把上游那三個檔的位元組還原了**，
  所以這三格已經自己好了（下面 §8.7 有重測）。我原本列的選項 (b)「在 `~/tutorials` `make clean` 重建」
  **是錯的建議**，兩個理由：那個 Makefile 的 clean 會跑 `sudo mn -c`（不是 no-lab 操作，我不該提），
  而且就算跑了也**還原不了** `basic.json`——那個 fixture 是**絕對路徑編譯**的產物，Makefile 的相對路徑
  編譯不會產生同樣的位元組。正確的收斂方式是 orchestrator 做的那件事（從 repo 還原上游），
  外加對**我新增的**那兩個 build 產物套用選項 (c)。
- ⚠️ **我這輪新增的 `basic_tunnel/build/*` 走的是選項 (c)**（§8.7）。它們是**解答**用絕對路徑編的
  （driver 的 `compile_prog` 等價式，也就是出事當下 fabric 真的在跑的那一份），而還原後的上游 build
  目錄是**骨架**的 Makefile 編譯——**骨架的 p4info 裡根本沒有 `MyIngress.myTunnel_exact`**，
  所以「骨架與解答在那四項上一致」是我寫錯了。
  真正的保護是另一半：`test_the_exact_field_really_is_EXACT_in_the_compiled_p4info` 用 `[0]` 取那張表，
  fixture 一旦漂成沒有那張表的程式，那一格就 IndexError 紅——**這一半成立**。

## 8.6 沒做／異議

1. **沒有 live**：`basic_tunnel/solution` 臂 PASS 由 orchestrator 驗（§9-23② 的 live 證明）。
2. `preflight.py` 沒動（D 的檔）。對帳格顯示**兩邊本來就同答**（它一直接受 `[1]`），所以這一輪沒有
   任何跨檔不一致要報。
3. §8.5 的三個漂移檔留給 orchestrator 裁——**這是本輪唯一一個我認為需要別人決定的東西**。

## 8.7 Round 2（judge on `917b239c`：MERGE AFTER FIXES；head `ea9eff2b`）

**must-fix**：`tools/p4_exercise/tests/test_convert.py` 的 `GENERATED_FIXTURES` 加入
`basic_tunnel/build/basic_tunnel.json` 與 `basic_tunnel/build/basic_tunnel.p4.p4info.txtpb`，
並把產生它們的指令寫在旁邊：

    p4c-bm2-ss --p4v 16 \
        --p4runtime-files .../fixtures/basic_tunnel/build/basic_tunnel.p4.p4info.txtpb \
        -o .../fixtures/basic_tunnel/build/basic_tunnel.json \
        /home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4

理由（judge 查證、我覆核）：我的 fixture 是**解答用絕對路徑編的**（json `program` ＝
`.../solution/basic_tunnel.p4`、p4info 102 行、有 `myTunnel_exact`），而 orchestrator 還原上游之後，
`~/tutorials/exercises/basic_tunnel/build/` 是**骨架的 Makefile 編譯**（`program` 是相對路徑、
p4info 67 行、**沒有** `myTunnel_exact`）——一條路徑不能同時是兩者，所以這個分支一落地
`FixtureProvenance` 就會對那兩個檔紅。裁定 (c)：C 新增的 build 產物**記指令、不做位元組 provenance**。
`s1-runtime.json` **不列**（沒有 build 會重寫它，而且它就是本案的主角），仍受 provenance 保護。
`test_the_generated_fixtures_are_all_there_and_are_the_only_exemptions` 仍綠（它要 json 的 `program`
以 `<stem>.p4` 結尾，解答路徑符合）。

**should-fix（純文字）**：① `test_exact_one_element_list` 裡「refused a step earlier」寫反了——
無 action 的拒絕在 `write_table_entry`，發生在 `build_table_entry` **之後**；註解改成正確方向。
② §8.5 三個漂移檔已由 orchestrator 用 repo fixture 還原（我實測：三個都 SAME），我原本的選項 (b)
是錯的建議（那個 Makefile 的 clean 會跑 `sudo mn -c`，不是 no-lab 操作；而且還原不了絕對路徑編譯的
`basic.json`），已改寫；「骨架與解答在那四項上一致」是假的（骨架沒有 `myTunnel_exact`），
改成只主張成立的那一半：`[0]` 索引在 fixture 漂掉時會 IndexError 紅。

**重跑（head `ea9eff2b`，log `gates-0910/*.p3c-ea9eff2b.log`）**

| 套件／閘門 | rc | 最後一行 |
| --- | --- | --- |
| tools/p4_exercise | 0 | `Ran 154 tests` ／ `OK` |
| `mutate_p4_exercise_tools.sh` | 0 | `22 mutations, 0 survived`（baseline 回綠，不再 REFUSE） |
| `check_gate_anchors.py ea9eff2b` | 0 | `115/115 cells ok` |
| p4_proxy 全套 | 0 | `Ran 1394 tests` ／ `OK (skipped=1)` |
