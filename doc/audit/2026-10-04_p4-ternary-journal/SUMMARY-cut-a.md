[Co-developed with claude code -- Adam]

# Cut A 摘要：P4 通用 table writer 支援 ternary／range／optional＋priority

**結論**：Cut A（除 V7 外）已完成並 commit，分支 `feat/p4-ternary-writer-a`，未推送。V7 依指示未做。

> 🆕 **第三輪（2026-10-10）**：V7 已經在 trunk 上（`6c1a78c8`／main `92c1c77a`，「p4 proxy: refuse table-entry writes into tables NDTwin owns」），並已 merge 進這個分支。**下面的 hold (2) 因此解除；`flow_5tuple` 的空 match catch-all 現在在 NDTwin 的 pipeline 上回 409、什麼都不送上交換機。** hold (1) D 照舊。細節見文末「第三輪」。下面原文保留，凡被 V7 改變的句子都就地標了 🆕。

🔴 **這個分支現在有兩個 hold，不是一個**：(1) D（健檢那條線的檔案，見下）；(2) **Q2／V7**。沒有 V7 的 Cut A，等於 Q2 (c) 的實際效果：baseline 的 `MyIngress.flow_5tuple` 以前只要 POST 裡寫了任何具名欄位就回 **501**，現在一律建出來、回 **200**。後果有兩個：
- 部分遮罩的 ternary entry（例如一個 /16 的 drop）現在可以被裝在 `ipv4_lpm` 前面；
- `insert_5tuple_rule` 的 MODIFY fallback 會默默覆蓋 operator 用同一個 key 寫的 entry（設計 Q2 (c) 自己寫的代價）。
空 match 打 `flow_5tuple` 回 200 的既有缺陷（§1.5）也還在。所以 **V7 決定（Q2）之前，這個分支不該合併**，即使 D 已經備好。
- 🆕 **已解除（第三輪）**：V7 併入後，在 NDTwin 的 pipeline 上，`flow_5tuple`（具名欄位或空 match）與 `ipv4_lpm`、`l2_forward` 的 API 寫入都在建 entry 之前回 **409 `owned_by_ndtwin`**，`stub.requests == []`。上面兩個後果都不再走得到：operator 寫不進 `flow_5tuple`，所以既不能裝在 `ipv4_lpm` 前面，也不會被 `insert_5tuple_rule` 的 MODIFY fallback 覆蓋。

**做了什麼**
- 新增 `match_shape.py`：writer 與 pre-flight 共用同一份形狀檢查。
- 三種新型別都能建：ternary `[value, mask]`、range `[low, high]`、optional 單一值；欄位省略代表 don't-care。
- V1–V6、V8、V9 都在 `stub.Write` 之前回 400，什麼都不會寫到交換機。
- 讀取側補上 optional；寫入側與讀取側共用同一個 `_match_as_dict`，所以安裝時間記錄找得到 ternary／range／optional 的 entry。
- E1：502 的 body 多了 `p4rt_error {code, message}`，直接解出交換機的真正原因（例如 NOT_FOUND）；`grpc_status` 照舊保留。
- 200 的 body 多了 `priority`。
- Pre-flight 的「G5 not done」已刪除，改為呼叫同一份檢查。
- 只剩 `UNSPECIFIED` 欄位型別還回 501。

**量測（A0 補量的四項，stock 與 bmv2-fast 結果相同）**
1. `value & ~mask != 0`：交換機拒絕。
2. 六欄位全省略、priority 10：被接受，等於一條 catch-all；因此 §1.5 的缺陷從「推論」變成「已量到」。🆕 這是**交換機**的行為，照舊；V7 之後，proxy 在 NDTwin 的 pipeline 上就先拒絕（409），這筆不會送到交換機。
3. 同上但 priority 0：被拒絕。
4. exact／lpm 表帶非 0 priority：insert、modify、delete 都被拒絕。
沒有任何結果與設計的 V 規則矛盾。唯一補充：exact／lpm 表的 V6 對 modify、delete 也成立。

**驗證**（🆕 這一段是第一輪的數字，只描述當時的 dd8022fa；HEAD 的數字見「第五輪」一節；它之後還有 D 一節，所以不是文末）
- p4_proxy 測試 1734 → 1788；tools/p4_exercise 測試 196 → 210；全綠。
- mutate_table_entry.sh：76 個 mutation，0 survivor（原本 41 個）。🆕 到第三輪是 78 個，第四輪 81 個。
- mutate_p4_exercise_tools.sh（36 個）與 mutate_p4_rule_install_time.sh（27 個）都是 0 survivor。
- check_gate_anchors.py HEAD（133/133；🆕 之後的 HEAD 是 136/136，見第四輪）、check_test_tmpdirs.py、test_l1_shell_scoring.sh 全綠。
- 紅燈證據：R1–R3、R4、R5、R6a、R7、R7b、R8、R9、R18、R25 在舊的 dd8022fa 複本上為各自的理由而紅。
  - R6b–R6f 在 dd8022fa 上只因 501 而紅，要到 A1 commit 才為自己的理由紅。
  - R6g 靠 mutant 殺（M-S2a–c）。
  - R23 依設計只靠 mutant M-J21 殺。
- 對真的 bmv2 做了 52 個案例比對（本機 writer 的判斷 vs 交換機的判斷）：48 個一致、4 個只有本機有意義（沒有線上形式）、0 個不一致。E1 也用真的 trailer 驗過。

**S0 對 PF-T 的反應**
Pre-flight 的 PF-T 現在 rc 0，「G5 not done」不再出現。但 S0 自己有兩條檢查要求 PF-T 必須失敗，所以結果是 `PROBE-BROKEN`（rc=1），其餘所有項目皆 ok。這正是設計預測的結果：A 必須與 D 一起合併。

**D 的完整檔案清單**（DESIGN §7；全屬健檢線，這個分支一個都沒碰）：
- `tools/p4_health/s0.py:283-294`（PF-T 斷言本身在 `:289-294`）與 `pft_verdict`（`:673-682`）：兩條斷言 PF-T 必須 FAIL；
- `classify_pft`（`s0.py:124-133`，數「G5 not done」的那一行在 `:129`）：它的 RED 路徑只認「G5 not done」那句話；
- `pft_cannot`（`tools/p4_health/cells/table.py:394-399`）；
- `tests/python/fixtures/p4_health/preflight_pft.txt:26`（那份 fixture 還存著「G5 not done」那一行）；
- `doc/audit/2026-10-03_p4-health-check/expected_today.tsv`（PF-T 那列在 `:18`）；
- `tools/p4_health/exercise/gen_runtime.py:120`（寫著「Pre-flight must refuse it (G5)」的註解）；
- T4–T7 的 oracle（priority 要用 bm priority = 2147483647 − p 換算、optional 的 thrift 顯示為 `TERNARY v &&& ff`、「數字大的贏」要比換算後的值）。

**要注意的地方**
- Q3 採 (a)：don't-care 的第二種寫法一律 400，訊息為「omit the field」。
- Q2 未答：沒有 owner 檢查，沒有改任何 route binding。**但 `flow_5tuple` 的行為不是「照舊」**：空 match 照舊回 200，而具名欄位從 501 變成 200（見最上面的 hold）。
  - 🆕 第三輪：Q2 已照 (a)＋(a-i) 實作為 V7（trunk `6c1a78c8`）。合併後 `flow_5tuple` 在 NDTwin 的 pipeline 上：空 match 與具名欄位**都是 409**。
- 哪些 fixture 變了（精確版）：`test_p4_client_writes.py` 與 `test_table_entry_route.py` 的 p4info fixture 各**新增**了 Synthetic 表（`Synthetic.unspecified_table`；前者另加 `Synthetic.mixed_table`）；`a_client` 替身、`bind_routes`、binding 一個都沒動（🆕 第三輪的 `42c22297` 之後不再成立：`TheShapeRulesTest`、`ThePriorityRulesTest` 與 findability 測試現在自己呼叫 `bind_routes(None)`，見第三輪）。被改寫的是九個 501 測試與兩個 pre-flight 測試（它們的斷言本來就是舊行為）；`test_rule_install_times.py` 裡拿 `"optional"` 當「沒人建模的型別」的那顆，改成 `"some_future_type"`。
- 順帶發現：priority 超過 int32 時，舊碼會丟出沒接住的 protobuf ValueError（等於 500）；現在是 400。
- 另一個既有問題：`mutate_p4_rule_install_time.sh` 在 dd8022fa 本來就會 baseline 紅（缺 `setting/`），已修。
- `entry_key` 的 default key（§10-2 後半）留給 Cut B。
- M-B7、M-B14、M-B20 沒有退役：它們守的 `journaled:false` 在 Cut B 之前仍然是事實。

**V7 待辦**（等 Q2 答覆；沒有實作）🆕 **第三輪：已由 trunk `6c1a78c8` 實作，下面是當時的清單，對照見文末**
- 程式：`write_table_entry(spec, op, source)`，`source` 為 `"boot"`／`"api"`／`"replay"`，`apply_package_entries` 傳 `"boot"`；409 body 為 `error: "owned by NDTwin"`、`outcome: "owned_by_ndtwin"`，remedy 放在前 200 bytes；default-action 例外只給 `roles.ipv4_route` 綁定的 owner-ndtwin package 表、而且只限開機。
- 測試：R19（baseline 空 match 打 `flow_5tuple` 與 `ipv4_lpm` 都是 409；owner-ndtwin 表的 package default 開機仍裝得上，bring-up C 的 `failed == 0`；同一張表用 API 改 default 是 409）；R19b（API 改 baseline `ipv4_lpm` 的 default → 409，`stub.requests == []`）。
- Mutant：V7、V7 的 default 例外、M-J29（例外擴大到 baseline 表或 API）。
- **會翻轉的既有測試**（V7 在 `write_table_entry` 裡，所以只有經過它的才會翻；`BuildTableEntryTest` 只呼叫 `build_table_entry`，**不會翻**）：
  - `test_table_entry_route.py`：所有 POST `AN_LPM_ENTRY` 的成功路徑，以及 Cut A 新增的三個接受測試（ternary／range／optional）；
  - `test_p4_client_writes.py`：`WriteTableEntryTest` 的成功路徑、`TheShapeRulesTest` 與 `ThePriorityRulesTest` 的接受路徑（含 catch-all 與空 match）、`TheReadSideKnowsEveryMatchTypeTest` 的 findability 測試；`a_client` 是 baseline 替身，所以都會 409；
  - 若 V7 排在 build 之前，這些類別裡斷言 `TableEntryInvalid` 的拒絕測試也會先拿到 409，順序要在 V7 實作時定；
  - `test_foreign_pipeline.py` 的真 p4info ternary 寫入測試；
  - Q2 (a-iii) 決定替身要不要加 `bind_routes`。

---

## 第二輪（審查後）的修正

- **M1（揭露）**：上面最前面的 hold 說明、D 的完整檔案清單、V7 翻轉清單都已更正（`BuildTableEntryTest` 不會翻；`TheShapeRulesTest`、`TheReadSideKnowsEveryMatchTypeTest` 等的成功路徑會翻）。
- **M2（`/stats/flow` 的顯示）**：`ryu_flow_stats.py` 依「無法描述的規則就不列、只計數」處理新的 match 型別。
  - ternary 欄位的遮罩是 CIDR 形（開頭一串 1）：在位址欄位顯示成 `value/n`，與 lpm 相同；遮罩全滿：精確值。
  - 其他任何遮罩，以及任何 range 欄位：整列不列出，計入 `flow_stats.unrendered_entries`，**在所有 pipeline 上，NDTwin 自己的也一樣**。
  - 🆕 第四輪更正：第二輪的程式只讓 foreign pipeline 的計數到得了 `switch_state`；NDTwin 自己的 pipeline 上，route 把計數丟掉，`flow_stats.unrendered_entries` 答 0（或 null）。第四輪起 `get_flow_stats` 對所有 pipeline 都用 `render_flow_stats_counted` 並記下 `last_flow_render`（`/stats/flow` 的 HTTP body 位元組不變），所以現在上面這句才成立。NDTwin 自己的 pipeline 上，未知 action 的列仍然照舊列出（action 為空）、不計入；Ryu 說不出的 ternary 遮罩或 range 才不列、計入。🆕 第五輪更正：「沒有可用 match 的列」（空 match 的 catch-all、或只有 Ryu 沒有名字的欄位）在所有 pipeline 上都不列，但只有 foreign pipeline 會計入，NDTwin 自己的 pipeline 不計入；這是照舊的行為（有測試釘住）；owner 已裁定維持不計入，見第五輪。
  - 「baseline 的 count 恆為 0」只在 NDTwin 是 baseline 表唯一寫入者時成立（V7 之下為真），已寫進模組註解。
  - 為此把 `test_ryu_flow_stats.py` 的 `a_ternary_rule` 預設 `in_port_mask` 從 `b"\xff"`（bit<9> 欄位的低 8 位）改成真正的全滿遮罩 `b"\x01\xff"`；渲染出來的位元組與基準擷取相同。
- **m1**：flow_5tuple 空 match、ipv4_lpm 省略欄位這兩個「今天會被接受」的測試改成「§1.5 缺陷，等 Q2 再翻」的 pin（🆕 第三輪已翻成 409，見下）；「欄位全省略、priority ≥ 1 通過 V1–V9」這個性質改在不屬於 NDTwin 的 Synthetic 表上、透過 `build_table_entry` 斷言（新增 `Synthetic.lpm_table`）。
- **m2**：見上面「哪些 fixture 變了」；再加：`Synthetic.lpm_table`（p4info fixture 新增表）與 `a_ternary_rule` 的 in_port 遮罩（上一項）。
- **m3**：n09（過寬的 bytes 遮罩）已用 A1 build 送到真的 bmv2：兩個 binary 都拒絕（「Bytestring provided does not fit within 9 bits」）。52 個案例變成 49 一致、3 個只有本機有意義（V1 ×2、priority 2^31）、0 不一致。`match_shape.py` 檔頭的說法已改成「V1 與超過 int32 的 priority 沒有線上形式，其餘都重複 bmv2 的拒絕」。
- **可以晚點的項目**：過時註解已修；M-S2a 改用 0x1ff（截斷後會被接受），新增 M-S2e（截斷 ternary value）與 M-S2f（截斷 range low）；新增 route 測試：priority 2^31 → 400 且 `stub.requests == []`。

---

## 第三輪：併入 V7（trunk `6c1a78c8`）

- **merge**：`02ce0232` 把 trunk `6c1a78c8`（= `d811f871`＋V7 的 squash；V7 的 11 個檔與 main `92c1c77a` 一字不差）併進來。之後的修正是它後面的 commit（`git log 02ce0232..`）。
- **V7 與 Cut A 的順序**：owner 檢查在 `write_table_entry` 裡、在 `build_table_entry` 之前。⇒ 在 NDTwin 的 pipeline 上，任何寫入（含違反 V1–V9 的）先拿到 409，不是 400。新增一顆測試釘住這個順序（同一筆 zero-mask entry：NDTwin 的 pipeline 是 409，user pipeline 是 400）。
- **翻轉了什麼**（merge 當下 `test_p4_client_writes.py` 37 個 error，全部是 `TableOwnedByNDTwin`，與上面 V7 翻轉清單一致）：
  - **§1.5 的兩顆 pin 翻了**：`TheSection15DefectIsPinnedPendingQ2Test` → `TheSection15CatchAllIsRefusedTest`。空 match 打 `flow_5tuple`、省略欄位打 `ipv4_lpm`：baseline client 是 409、`stub.requests == []`；同一筆在 user pipeline 上照樣送出（對照：擋的是擁有者，不是形狀）。
  - **主題是形狀／priority／讀回的，搬到 V7 仍允許的路上**：`TheShapeRulesTest`、`ThePriorityRulesTest`、`TheReadSideKnowsEveryMatchTypeTest` 的 findability 測試，改成 `bind_routes(None)`（沒有 roles 的 package pipeline），和 V7 自己對 `WriteTableEntryTest`、`test_table_entry_route.a_client` 的做法相同。
  - `test_foreign_pipeline.py` 的真 p4info `flow_5tuple` 測試：兩邊都改過，衝突。保留 V7 的 409 斷言（加上 priority 10，使沒有 owner 檢查時是「送出去了」而紅），編碼的斷言改在 builder 上做。改名為 `…_is_owned_and_its_builder_builds_it`，`mutate_table_entry_owner.sh` 的 M16 跟著改名。
  - 🆕 第四輪更正（原句「沒有刪掉任何斷言」不對）：merge 解衝突時有三處斷言不在了，各有去處：Cut A 第二輪在 `test_foreign_pipeline.py` 的 wire 層斷言（因為現在 409 什麼都不送，改由 builder 層斷言取代）；V7 的 `TableEntryUnsupported`／"TERNARY" builder 斷言（描述 Cut A 刻意反轉的行為）；V7 的 `test_neither_range_nor_optional_reaches_the_switch`（range／optional 現在在 route 就被接受，由 Cut A 的接受測試取代）。沒有任何一顆是為了讓測試變綠而弱化。
- **舊結論要改的**：最上面 hold (2) 解除；「空 match 打 `flow_5tuple` 回 200」只描述 V7 之前；`ryu_flow_stats.py` 那句「直到 owner 檢查擋住」已改成「owner 檢查已擋住」。
- **驗證**（在 `42c22297` 的拋棄式 clone 跑，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-writer-a/merge-v7/`，每份第一行 commit、最後一行 rc）：
  - merge 當下（`02ce0232`）：`test_p4_client_writes.py` 206 個、37 error（全是 `TableOwnedByNDTwin`）；V7 自己的 owner 兩個檔與其餘三個檔（archive 裡只有這幾份 log）全綠。
  - 修正後（`42c22297`）：`test_p4_client_writes` 207、`test_table_entry_owner` 46、`test_table_entry_owner_package` 5、`test_table_entry_route` 36、`test_foreign_pipeline` 17、`test_exact_one_element_list` 14、`test_readopt` 134、`test_rule_install_times` 44、`test_ryu_flow_stats` 61、`test_switch_state` 71、`tools/p4_exercise` 210，全部 OK，沒有任何 skip。
  - 五個 gate 的 anchor：`check_gate_anchors.py 42c22297` 5/5 ok（全部 gate 136/136 ok）；`check_named_tests` 的 log（`merge-v7/check_named_tests_42c22297.log`）以 rc=1 結束，兩個落空都無害：`test_an_uninjected_reporter_adds_no_key` 在兩個類別各定義一次（定義了 2 次），以及 `test_convert` 是檔名不是測試（定義 0 次）；`bash -n` 全過。
- 🆕 **（第三輪當時）mutation gate 沒跑；第四輪已跑，結果見下。**

---

## 第四輪：把「計數」接到 NDTwin 自己的 pipeline，補 mutant

程式 commit `f81a608a`（只動 `p4_proxy/`、`tests/shell/`）。log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-writer-a/r4/`（每份第一行 commit、最後一行 rc；沒有 symlink 進 worktree，gate 在拋棄式 clone 跑，已刪）。

- **A（`unrendered_entries` 在 NDTwin 自己的 pipeline 上）**：`get_flow_stats` 現在只有一條路，所有 pipeline 都走 `render_flow_stats_counted` 並記下 `client.last_flow_render`；NDTwin 的 binding 照舊是 BASELINE，所以 `/stats/flow` 的 HTTP body 位元組不變（`test_flow_stats_route.py` 的 byte-identity 四顆與 `test_ryu_flow_stats.py` 的 `TheNdtwinPipelinesFlowStatsAreByteIdenticalToTheBaseTest` 全綠，見 `test_flow_stats_route.test.log`、`test_ryu_flow_stats.test.log`；rule-clock 的 M5 與 baseline 見 `mutate_p4_rule_install_time.log`）。`main.flow_stats_report` 刪掉「baseline 且讀過表就回 0」的分支：沒 render 過就是 null，讀表不算 render。
- **測試**：兩顆原本釘 0 的測試改成新行為（`test_flow_stats_route.py`、`test_switch_state.py`）；新增 `TheCountOnNdtwinsOwnPipelineTest`（端點層：baseline client 讀回含一列部分遮罩，`/stats/flow` 不列、`/p4/switch_state` 顯示 1；另三顆：計數跟著最近一次 render、失敗的讀不動舊計數、未知 action 仍列出且不計）。紅燈在改程式前跑：`r4/red/test_flow_stats_route.red.log`（1 error）、`r4/red/test_switch_state.red.log`（5 fail）；綠燈在 `r4/test_*.test.log`。
- **Gate 改動**：FS11 的必紅測試改成端點層那顆；AR3 改成「NDTwin 的交換機被當成沒有 roles 的外來交換機」；新增 AR5／AR5b（端點不記計數、記成 0）、FS13（未知 action＋不可譯 match 被算兩次）；MN12 改成「NDTwin 的計數被報成 0」；`TheCountOnNdtwinsOwnPipelineTest` 加進 NEW_CLASSES。
- **m-2**：`mutate_table_entry_owner.sh` 新增 M25（owner 檢查移到 build 之後），由 `test_on_ndtwins_pipeline_the_owner_answers_before_the_shape_rules` 殺。
- **m-3**：`mutate_table_entry.sh` 新增 M-S8c（省略的 lpm 欄位被拒）→ `test_leaving_the_lpm_field_out_is_the_way_to_say_any_address`；M-S5d（/32 被當 catch-all 拒）→ `test_a_network_address_and_a_host_route_are_both_accepted`；M-S6h（拿掉 priority 型別檢查）→ `test_a_priority_that_is_not_an_integer_is_refused`。`mutate_roles_binding.sh` 的 FS13 → `test_on_a_foreign_switch_a_row_with_an_unknown_action_and_a_range_is_counted_once`。`mutate_p4_exercise_tools.sh` 的 37（把「G5 not done」放回 pre-flight）→ `test_the_old_g5_sentence_is_gone_from_a_ternary_package`。五顆都被殺。
- **Gate 結果（有 p4 build、有 venv，在 `f81a608a` 的 clone 上）**：

| gate | 結果 | log |
|---|---|---|
| mutate_table_entry_owner.sh | 27 mutations, 0 survived（26＋M25；🆕 這個 27 含控制組 C1，其他 gate 的數字都不含控制組） | `mutate_table_entry_owner.log` |
| mutate_table_entry.sh | 81 mutations, 0 survived（78＋3） | `mutate_table_entry.log` |
| mutate_p4_rule_install_time.sh | 27 mutations, 0 survived | `mutate_p4_rule_install_time.log` |
| mutate_roles_binding.sh | 193 mutations, 0 survived；every new test seen red: 202 of 202 | `mutate_roles_binding.log` |
| mutate_p4_exercise_tools.sh | 37 mutations, 0 survived | `mutate_p4_exercise_tools.log` |

  `check_gate_anchors.py HEAD`：136/136 cells ok（`check_gate_anchors.log`）。per-file：`test_flow_stats_route` 16、`test_switch_state` 76、`test_ryu_flow_stats` 61、`test_p4_client_writes` 207，全 OK、無 skip。
- **沒動**：`tools/p4_health/`（D 另案）。D 的檔案清單只更新了行號（上面「D 的完整檔案清單」）。

---

## 第五輪：把文件和註解講準，補 FastAPI 層的測試

程式 commit `a6ad886c`（只動 `p4_proxy/`、`tests/shell/`，行為不變）。log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-writer-a/r5/`（每份第一行 commit、最後一行 rc；gate 在拋棄式 clone `cuta-r5` 跑，HEAD 確認是 `a6ad886c`、乾淨，clone 已刪，沒有 symlink 進 worktree）。

**Adam 對 F1 的裁定**：NDTwin 自己的 pipeline 上，「沒有可用 match 的列」（空 match 的 catch-all、或只有 Ryu 沒有名字的欄位）**維持不計入**（照舊、有測試釘住）；只把文件講準。foreign pipeline 照舊會計入。所以 `test_ndtwins_own_pipeline_does_not_count_a_row_with_no_usable_match` 與 FS3c 保留，沒有翻轉。

**各項更正**

- **F1（文件過度宣稱）**：`main.py:1488-1494`（`flow_stats_report` docstring）、`api_routes.py:1283-1287`（`get_flow_stats` 註解）、本檔上面 M2 一節（第五輪更正那句）都改成：遇到 Ryu 說不出的 ternary 遮罩或 range，所有 pipeline 都計入；沒有可用 match 的列，所有 pipeline 都不列，但只有 foreign pipeline 計入。
- **F2（null 沒寫進欄位說明）**：`api_routes.py:781-783`（`switch_state` docstring，會進 `/openapi.json`）與 `api_routes.py:855-856`（欄位註解）新增「第一次 `/stats/flow` render 之前是 null，所有 pipeline 都一樣，readopt 會重置」。roles ticket 裡「NDTwin pipeline 恆為 0」那句已被 M2（真的計數）和 null-before-render 兩度取代；ticket 本身是 owner 保管的文件，這裡沒有改它。
- **F3（P4 build 沒有身分）**：`r5/p4build.sha256`、`r5/p4build.compile.log`。`p4c-bm2-ss` 1.2.5.15（SHA 5b948b037a, Release），從 `a6ad886c` 編譯：`ndtwin_switch.json` `f1c6e09684a0ef57bf9df8e34a252c16287f76dc3f3ac51df991f80ff6d3d562`；`ndtwin_switch.p4info.txt` `d54ff55208340f3a6b4cf5434de6c278604a99c4fcab07f2e44b5b75e3f2ab67`；`ndtwin_switch.p4` `5786a63e9b31402ce40bc6401319a6408a1cf71f6dddaca0c023d450f3ae23d5`。同一份 header 也印在五份 `mutate_*.log` 與 `check_gate_anchors.log` 的開頭（例如 `mutate_roles_binding.log:2-6`、`mutate_table_entry_owner.log:2-6`）。
- **F5（過時的註解與名字）**：`ryu_flow_stats.py:319-323` 不再說「renders exactly as it always did」；`:332-338` 的「THE COUNT IS EVERY NON-DEFAULT ROW NOT LISTED」改成明說是 foreign pipeline 的規則；`:357-360` 新增一段講沒有可用 match 的列「兩邊都不列、只有 foreign 計入、要不要改是 owner 的決定」。`test_ryu_flow_stats.py:623` 改名 `test_ndtwins_own_pipeline_does_not_count_a_row_with_no_usable_match`，`mutate_roles_binding.sh` 的 FS3c 標籤跟著改（`mutate_roles_binding.sh:927-928`）。`test_flow_stats_route.py` 原本放在 `AForeignSwitch…Test` 裡的 BASELINE 測試搬到自己的類別 `ARenderOnNdtwinsOwnPipelineIsCountedTooTest`（`:114-129`），gate 的 NEW_CLASSES 同步（`mutate_roles_binding.sh:93`）。
- **F6**：`main.py:1488-1494` 重新折行；這段 docstring 沒有超過 100 欄的行（檔內別處有 8 行超過，不是這次動的）。
- **F7**：`r4/poll.log` 的時間戳早於它回答的審查，是另一個 worker 提早寫的 ALLDONE 標記留下的（`r4/poll.log.NOTE` 已說明），本檔從不引用它。這一輪的 anchors log 是工具的完整輸出（`check_gate_anchors.log`，含 rev header 與每個 gate 的列）。
- **F8（HEAD 的數字）**：本檔上面「驗證」一節說「HEAD 的數字見文末」（當時第五輪是最後一節，現在 D 一節接在它後面），現在給在這裡，全在 `a6ad886c`：
  - p4_proxy：`p4lane.log` 是 CI 的 L1 第 3 節原文（`tools/test_workflow/l1_unit_tests.sh` 的「3. P4 proxy Python tests」，由 `p4lane.sh` 用 sed 抽出照跑），48 個檔，**47 個 PASS，共 1867 個測試跑完且通過；1 個 SKIPPED**（`test_p4_client.py`，1 個測試，該檔自己宣告需要活的交換機 `NDTWIN_L1_OPT_IN`，`p4lane.log:30`）；`FAILURES=0`（`p4lane.log:52`），rc=0（`:53`）。相比第一輪的 1788（`dd8022fa`）多了 79 個。
  - `tools/p4_exercise` discover：`Ran 210 tests`、OK、rc=0（`unittest_discover_p4_exercise.log:222-224`）。
  - `check_test_tmpdirs.py`：422 個檔掃過、0 個固定暫存路徑（`check_test_tmpdirs.log:10`）。
  - `test_l1_shell_scoring.sh`：`Ran 165 checks, 0 failed`（`test_l1_shell_scoring.log:196`）。
- **F9**：owner gate 的 27 含控制組 C1（`mutate_table_entry_owner.log:15`，`held`）；其他 gate 的數字都不含控制組。上面第四輪的表已加註。
- **F10**：紅燈 log 的 header 現在帶測試檔的 sha256：`r5/red/new_asgi_test.red.log:1`，`7581de6155f3c14800a99a064e9ded228681f1acf1a9ab98eb8a09fe9b7815bc`，等於 `a6ad886c` 裡 `p4_proxy/tests/test_switch_state.py` 的 sha256（`git show a6ad886c:p4_proxy/tests/test_switch_state.py | sha256sum` 重算相符）。header 寫的是 `b2618b88+uncommitted`，因為紅燈跑在 code commit 之前的工作樹上。
- **F11**（render 的時間戳存了卻沒送出；可加 `flow_stats.age_s`）：**不在這個 cut 的範圍**，沒有動。

**新的 FastAPI 層測試**：`TheCountOnNdtwinsOwnPipelineTest.test_through_fastapi_it_is_a_json_null_before_a_render_and_the_count_after`（`test_switch_state.py:1287`，同類別 `:1232`）。它用 `asgi_get` 真的打 `GET /stats/flow/1` 與 `GET /p4/switch_state`，檢查序列化後的 JSON：render 之前是 `"unrendered_entries":null`，render 之後是 `"unrendered_entries":1`。這一輪行為不變，所以紅燈不是「改程式前」，而是把四個 mutant 套在 production 碼上看這顆測試紅不紅（`r5/red/new_asgi_test.red.log`，沒有 rc 行，是節錄，不是逐字原文：只留 mutant 輸出裡相關的區塊，長行在約 200 欄處被截斷，例如 `:48`、`:50-51` 的 AR6 區塊停在句子中間）：MN11（null 被報成 0）時它因 `{'unrendered_entries': 0} != {'unrendered_entries': None}` 而紅（`:6-8`，該類別 5 個測試 2 個紅，`:9-10`）；AR5（不記計數）時它因找不到 `"unrendered_entries":1` 而紅（`:25-27`，5 個全紅，`:28-29`）；AR5b（記成 0）同樣（`:41-43`，`:44-45`）；AR6（null 計數從 JSON 被丟掉）時它因找不到 `"unrendered_entries":null` 而紅（`:50-51`，`:52-53`）。綠燈：`p4lane.log:44`（`test_switch_state.py`，77 個測試通過）與各 gate 的 baseline。Gate 新增 AR6（`mutate_roles_binding.log:303`，被這顆測試殺）。

**Gate 結果（`a6ad886c`，P4 build 與 venv 都在）**

| gate | 結果 | log |
|---|---|---|
| mutate_table_entry_owner.sh | 27 mutations, 0 survived（含控制組 C1） | `mutate_table_entry_owner.log:44` |
| mutate_table_entry.sh | 81 mutations, 0 survived | `mutate_table_entry.log:503` |
| mutate_p4_rule_install_time.sh | 27 mutations, 0 survived | `mutate_p4_rule_install_time.log:44` |
| mutate_roles_binding.sh | 194 mutations, 0 survived；every new test seen red: 203 of 203 | `mutate_roles_binding.log:704-707` |
| mutate_p4_exercise_tools.sh | 37 mutations, 0 survived | `mutate_p4_exercise_tools.log:270` |

`check_gate_anchors.py HEAD`：136/136 cells ok（`check_gate_anchors.log:152`）。

**一件跑錯指令的事**：driver 在最後一步寫了 STOPPED，只因為它用 `unittest discover` 直接跑 `p4_proxy/tests`（沒有 `__init__.py`，回 "Start directory is not importable"，rc=1）。CI 的 L1 不是這樣跑的；正確的跑法是上面的 `p4lane.log`。錯誤的 log 保留為 `unittest_discover_p4_proxy.wrong-invocation.log`。

**沒動**：`tools/p4_health/`（D 另案）。

---

## D：健檢那一半（分支 `feat/p4-health-ternary-d`，`trunk-cut2-merge`＋Cut A）

`95a8972b` 把 Cut A（`b2618b88`）併進 trunk `18c81892`（無衝突，兩邊沒有共同檔案）；D 的程式在 `76e3b468`，只動 `tools/p4_health/`、它的測試、fixture、`mutate_p4_health.sh` 與 `expected_today.tsv`。Cut A 的檔案（`p4_proxy/`、`tools/p4_exercise/`）一個都沒碰。log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-ternary-d/`（每份第一行 commit、最後一行 rc；gate 在拋棄式 clone 跑，venv 只 symlink 在 clone 裡）。

**改了什麼**
- `s0.py`：PF-T 的兩條自檢反過來。pre-flight 必須 PASS（rc 0、沒有 FAIL 列），而且先確認 PF-T package 真的帶著那一筆 ternary 開機 entry（新的一項 `PF-T package carries one ternary boot entry`）：以前的 FAIL 自己指名了那筆 entry，PASS 什麼都不指名，沒有這項的話，entry 掉了也會照樣 PASS。`PF-T verdict` 要求 GREEN。
  - `classify_pft` 不再認「G5 not done」那句話，改認 pre-flight 指名那筆 entry 的位置（`s2 entry 23:`，由 `pft_entries` 從 package 讀出）。任何一行 FAIL，不論措辭，只要指名它，就算拒絕了 ternary 那一列。
- `cells/table.py`：`pft_cannot` 讀 `ternary_rows`。拒絕 ternary 那一列（不論措辭）→ RED（structural，static 歸因照舊）；其他 FAIL 列 → PROBE-BROKEN；rc 0 → GREEN。`lab.py` 的 `pft_observation` 跟著改 key。
- `observe_a.py`：T4 的探針值從 `10.0.4.4/255.255.255.0` 改成 `10.0.4.0/255.255.255.0`。Cut A 的 V3 拒絕「value 在遮罩外有位元」（`match_shape.py:314-319`；行程內呼叫 `shape_field` 觀測到 `TableEntryInvalid`）⇒ 原值到了 live 會拿到 400，T4 判 RED【推論：route 把 `TableEntryInvalid` 對到 400】。
  - T4–T7 其餘的 oracle 不用改：Cut 2 已照 DESIGN §6.4 寫好（`thrift_priority` = 2147483647 − p；T6 認 `TERNARY v &&& ff`；T7 比換算後的值、小的贏）。這三點各有一個 mutant 守著：C2-OA2、AD10、C2-OA3。
- `expected_today.tsv`：T4、T5、T6、T7、PF-T 的預測改成 GREEN（DESIGN §6.4；健檢 design 5.1「翻格的修正，同一個 PR 改這份檔」）。T8 照舊 RED（要等 Cut B）。
- fixture：
  - `preflight_pft.txt` 從真的 pre-flight 重新擷取（`95a8972b`：S0 的 compile＋convert 之後跑 `preflight.py`，PASS）；
  - 原檔改名為 `preflight_pft_g5.txt` 保留；
  - 新增 `preflight_pft_refused.txt`：同一份 package，把 s2 entry 23 的遮罩改成 /24，pre-flight 以 V3 拒絕，句子裡沒有 G5。
  - 原 fixture 沒有標頭說明怎麼擷取，所以三份各加了一行 `#` 標頭。擷取腳本與原始輸出在 log 目錄的 `capture_pft.py`、`capture/`。
- `test_p4_health_collect.py` 的 fake fabric 預設改成「今天的 trunk」：會寫 ternary，而且用 proxy 真正的 `match_shape` 判形狀（不合就 400），所以只有 fake 才收的探針 body 在測試裡就會紅。拿 T4 當「bmv2 歸因的 RED」範例的測試，改成明寫 `ndtwin_writes_ternary = False`（Cut A 之前的 proxy），或改用 MT1。
- `gen_runtime.py:120` 的註解。

**S0**（`76e3b468`，離線，`setsid --wait`）：`S0 COMPLETE`，rc=0；57 項 ok、0 項 FAIL。
- PF-T 的三行：`pre-flight PF-T PASSes with the ternary entry in rc 0, ternary FAIL lines 0, other FAIL rows 0`、`PF-T package carries one ternary boot entry`、`PF-T verdict GREEN`。
- 🆕 第二輪更正（原句漏算）：S0 會起 10 個拋棄式 switch（4 個 selfcheck、vs_trial 2 個、ctrl_trial 2 個、show_ports 2 個，各為 stock 與 bmv2-fast）加 drop check 的 6 個 bmv2（drop check 呼叫 5 次：3 次真的檢查、各起 2 個 bmv2，另 2 次用快取結果、沒有起 switch；`s0.commands.log:373-391`），合計 16 個 switch 行程。第一輪的取樣腳本每秒一輪、每個 /proc 項目都 fork，只記到 7 個：漏了 vs_trial 的 bmv2-fast、兩個 show_ports，以及 drop check 的 6 個 bmv2（這 5 次呼叫只在 `s0.commands.log` 看得到）。🆕 第三輪更正（第二輪的「5 個」也算錯了）：`r2/s0_procs.log` 記到 16 個 switch 行程（10 個拋棄式 switch＋3 個父行程下的 6 個 drop check bmv2）；另有一個 `ndt-hc-version-` 行程（`exe None`），它不是 switch，`r2/driver.done` 把它算進「17 recorded」。「跑完之後沒有留下任何東西」靠的是事後掃描，那一句不變。第二輪改用一支 python 掃描（`r2/proc_scan.py`：跑之前、跑的過程中每 0.1 秒、跑之後），腳本與 log 都放在 log 目錄。跑完之後掃 /proc：沒有任何 simple_switch*／ndt-hc-*／ndt-hb* 留下，所以什麼都沒 kill。跑之前的掃描也是空的（`s0_prescan.log`）。

**Gate**（都在 `76e3b468`）
- `test_p4_health_cells.py` 183 個 OK（venv 3.13 與 ryu-env 3.8 各一次；trunk 是 179 個）。
- `test_p4_health_collect.py` 186 個 OK（兩個直譯器；trunk 是 183 個）。
- `test_p4_health_recover.sh` 163 checks、0 failed；`test_p4_health_gate_scripts.sh` 68 checks、0 failed。
- mutation gate 4 個 shard 依序在這台筆電上跑，locale 都是 en_US.UTF-8，再用 `sum_p4_health_gate_shards.sh` 加總：`GATE: 483 mutations, 0 survived, shards 4/4 ok, commit 76e3b468…, subject sha ea7e5536494a03ff`（trunk 473，加上這次的 AD1–AD10）。
- Cut A 的五個 gate 沒有重跑：`git diff b2618b88 76e3b468` 沒有碰到它們讀的任何路徑（`p4_proxy/`、`tools/p4_exercise/`、`setting/`、`check_gate_anchors.py`、它們自己的腳本）。

**看過紅**
- AD1–AD10 各被自己點名的測試殺掉；D12 改名後，由新的分類測試殺掉。
- `expected_today.tsv` 不在 gate 的 subject 裡，所以另外做了一次：把它退回 `95a8972b` 的版本，`test_bring_up_a_reads_as_predicted` 與 `test_a_then_b_then_the_verdicts` 兩顆紅（`red.tsv_reverted.collect.log`）。

**留著的**
- T4–T7 的 GREEN 只是預測，沒有 live run。🆕 **已被下面「D 第二輪」取代**：T4–T7 之後在 `e17d39e5` 離線對兩台拋棄式 bmv2 觀測為 GREEN，三張表的 `table_owned_by_ndtwin` 也在手動 `bind_routes(None)` 之下量到是 False；仍然沒有 live `health.json`。下面是當時的原句：其中「package A 沒有 roles，所以 V7 不擋 `HcIngress.t_ternary` 的寫入」是讀碼推論（`table_owned_by_ndtwin`：binding 為 None 就回 False），沒有量過。
- PF-T 遇到「用新的句子拒絕 ternary 那一列」時判 RED，不判 PROBE-BROKEN。依據是健檢 DESIGN 的 PF-T 列（`:293`）：這一格要量的是「pre-flight 通過」，不是某一句話。如果要的是 PROBE-BROKEN，改 `pft_cannot` 一行就好。
- `runtime_cli.py:57` 還寫著「priority entries are not in the package format (G5)」。S0 的 throwaway 不灌 PF-T 那筆 entry，所以不影響結果，但這句話已經過時。

### D 第二輪（審查之後；`e17d39e5` 程式，`b735a518` tsv 與這一節，最後一顆 commit 把四個 mutant 搬到 anchor checker 讀得到的地方）

先把 Cut A 第五輪（`a4e67f6e`）併進來（`e1e5747e`；只有本檔衝突，兩邊各加一節，都保留）。併完之後，Cut A 的每個檔都與 `a4e67f6e` 相同（`git diff --name-only e1e5747e^2 e1e5747e` 不含 `p4_proxy/`、`tools/p4_exercise/`、Cut A 的 gate 腳本）。

**各項處理**
- **M1（T4–T7 翻成 GREEN 沒有 health.json）**：Adam 裁定先離線觀測，live 之後另行授權。
  - 一次性腳本 `r2/t4t7_trial.py`，不在 `s0.py`、也不是任何 gate 的 subject。它在兩個拋棄式 `simple_switch_grpc`（stock 與 bmv2-fast，照 throwaway.py 的規則起）上做三件事：
    - 用 package A 的 p4info 與 election id、`bind_routes(None)`，接上真的 `P4RuntimeClient`，推 hc_main；
    - 由真的 route handler `api_routes.table_entry` 回答 `observe_a.py` 原封不動的 T4_BODY、T5_BODY、T6_BODY、T7_BODIES；
    - 用 lab 的 thrift reader 做 `table_dump`，套 observer 自己的 find/check，最後 `judge_all`。
  - 結果：兩台都是 T4、T5、T6、T7 GREEN；五個 POST 都回 200；三張表都是 `table_owned_by_ndtwin` = False（`r2/t4t7.log`、`r2/t4t7.json`、原始 dump 在 `r2/t4t7_dumps.txt`）。
  - 這支腳本起了 2 個 switch，pid 記在 `r2/t4t7_procs.log`。🆕 第三輪補記：它跑在乾淨 clone 的 `e17d39e5`，不是 D 的 head `f9f28623`（`tools/p4_health` 的樹在兩者都是 `89e744c1`）；bmv2 兩個 binary 只以路徑識別。跑之前、跑之後的掃描都是空的，沒有 kill 任何東西。
  - `expected_today.tsv` 的 T4–T7 basis 改成「observed offline …; no live health.json yet」，保留程式行號。tsv 不能寫 `scratch/overnight…`（`test_no_rulings…` 會擋），所以只寫 `gates-0910/p4-health-ternary-d/r2/t4t7.json`。
- **m1（沒有 match 的 t_ternary entry）**：`pft_entries` 現在只認「非 default、match 指名 `hdr.ipv4.srcAddr`」的 t_ternary entry（`s0.py:134-153`）。新測試 `test_a_ternary_table_entry_that_names_no_ternary_field_is_not_pfts` 涵蓋三種：沒有 match 的 priority entry、default entry、別張表上的 srcAddr；mutant AD3、AD11、AD17。
- **m2**：`match_shape.py` 加進 gate 的 WATCHED（`mutate_p4_health.sh:74`）；`test_p4_health_gate_scripts.sh` 多一項檢查（68 → 69）；mutant AD16。
- **m3（continuation 那一半）**：新增兩份真的擷取，都是在 `e1e5747e` 跑 pre-flight：
  - `preflight_pft_other_first.txt`：第一個 problem 是 s2 entry 1，ternary 的拒絕在 continuation 列；
  - `preflight_pft_ternary_two.txt`：entry 23 有兩個 problem。
  - 依裁定：同一列裡還有別的 entry 被拒 → PROBE-BROKEN；RED 只代表 pre-flight 恰好只拒絕那筆 ternary entry。`classify_pft` 現在把 entries 列裡每一個不指名它的 problem 都算成 other，`... and N more` 算 N 個，沒有上層列的 continuation 也算（`s0.py:156-184`）。
  - 新測試 `test_pft_a_ternary_refusal_beside_another_one_is_probe_broken`；mutant AD12（只認有標籤的列）、AD14（舊規則：不算同一列的其他 entry）、AD15（N 算成 1）。
- **m4**：原本 collect 的那顆測試改名為 `test_pft_observation_reads_a_refusal_in_s0s_record_as_red`，docstring 寫明 run_lab 只讀 COMPLETE 的 S0。新增 `test_an_s0_that_refused_pft_is_incomplete_and_pft_not_run`：INCOMPLETE、rc 2、沒有任何 lab 動作、點名失敗的 check、PF-T NOT RUN；mutant AD13。
- **m5**：健檢 DESIGN.md:293、:423 與 ternary DESIGN.md:647 各加一句「🆕 2026-10-11 Cut A + D」。
- **NIT**：
  - `runtime_cli.py:57` 的措辭改了；
  - tsv 第 3、6 行改為說明預測對象與 T4–T7 的證據；
  - 每份 suite log 第三行印出直譯器與版本（`r2/runlog.sh`）；
  - 上面那句 process 的算法已更正；
  - 掃描腳本放在 log 目錄。
- 另外補了兩個 mutant：AD18（`s0.py` 的「carries」那一行）、AD19（讀不到的 package）；新測試 `test_pft_entries_reads_every_switch_and_an_unreadable_package_names_none`。

**看過紅**：AD1–AD19 與 D12 先在 worktree 用 `ONLY_LABEL_PREFIX` 跑過，第一次 19 個裡有 1 個存活：AD8 點名的測試已改名，gate 判它 WRONG TEST。改了點名之後，AD8 被殺。正式的數字以 r2 的完整 gate 為準。

- **anchor checker**：`check_gate_anchors.py` 在 `b735a518` 回報 `mutate_p4_health.sh` 有 4 個 anchor 讀不到（135/136）。原因是 AD8、AD9、AD10、AD13 的 subject 寫成 `"$PKG/lab.py"`、`"$PKG/observe_a.py"`，checker 解析不了；gate 本身照樣套得上（第一輪 gate 有殺到它們）。最後一顆 commit 把這四個搬到 Cut 2 那一節，改用 `$LABPY`、`$OBSA`，checker 變成 136/136。第一輪的 AD8–AD10 也有同樣的問題，當時沒有跑 checker。

**Gate**：都在最後一顆 commit（D 的 head），跑在新的拋棄式 clone 裡，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-health-ternary-d/r2/`：cells 與 collect 兩個 suite 各跑兩個直譯器（3.13 與 3.8），recover 與 gate_scripts 是 bash suite、各跑一次；完整 mutation gate（4 個 shard 加總）、S0、p4lane／klane、`check_gate_anchors.py`。每份 log 第一行是 commit、最後一行是 rc。

### D 第三輪（推 trunk 前的文字修正）

只改註解、docstring、`expected_today.tsv` 的 basis／出處文字與本檔，沒有任何行為變動。

- `api_routes.py` 的 `switch_state` docstring（會進 `/openapi.json`）與欄位註解、`ryu_flow_stats.py` 的 `render_flow_stats_counted` docstring：`flow_stats.unrendered_entries` 的說明改成與程式一致。它數的是最後一次 `GET /stats/flow` render 因為描述不了而漏列的非 default 列：所有 pipeline 上是 Ryu 拼不出來的 ternary mask 或 range；foreign pipeline 上再加不認得的 action、沒有可用 match 的列。null 到第一次 render 為止、readopt 歸 null 兩句照舊。
- `expected_today.tsv`：PL1、T3、T8 的程式行號重新指到現在的 `api_routes.py` 與 `main.py`；T4–T7 的 basis 補上離線觀測跑在 `e17d39e5`。
- 本檔：上面 S0 的 switch 行程數（16 個 switch 行程）、F10 紅燈 log 是節錄、試驗跑在 `e17d39e5`、「T4–T7 的 GREEN 只是預測」標為已被取代、兩處「文末」的指向、Gate 一段 suite 的直譯器次數。
