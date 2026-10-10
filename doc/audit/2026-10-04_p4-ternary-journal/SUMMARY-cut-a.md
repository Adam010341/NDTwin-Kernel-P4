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

**驗證**
- p4_proxy 測試 1734 → 1788；tools/p4_exercise 測試 196 → 210；全綠。
- mutate_table_entry.sh：76 個 mutation，0 survivor（原本 41 個）。
- mutate_p4_exercise_tools.sh（36 個）與 mutate_p4_rule_install_time.sh（27 個）都是 0 survivor。
- check_gate_anchors.py HEAD（133/133）、check_test_tmpdirs.py、test_l1_shell_scoring.sh 全綠。
- 紅燈證據：R1–R3、R4、R5、R6a、R7、R7b、R8、R9、R18、R25 在舊的 dd8022fa 複本上為各自的理由而紅。
  - R6b–R6f 在 dd8022fa 上只因 501 而紅，要到 A1 commit 才為自己的理由紅。
  - R6g 靠 mutant 殺（M-S2a–c）。
  - R23 依設計只靠 mutant M-J21 殺。
- 對真的 bmv2 做了 52 個案例比對（本機 writer 的判斷 vs 交換機的判斷）：48 個一致、4 個只有本機有意義（沒有線上形式）、0 個不一致。E1 也用真的 trailer 驗過。

**S0 對 PF-T 的反應**
Pre-flight 的 PF-T 現在 rc 0，「G5 not done」不再出現。但 S0 自己有兩條檢查要求 PF-T 必須失敗，所以結果是 `PROBE-BROKEN`（rc=1），其餘所有項目皆 ok。這正是設計預測的結果：A 必須與 D 一起合併。

**D 的完整檔案清單**（DESIGN §7；全屬健檢線，這個分支一個都沒碰）：
- `tools/p4_health/s0.py:275-277` 與 `pft_verdict`（`:574-583`）：兩條斷言 PF-T 必須 FAIL；
- `classify_pft`（`s0.py:124-133`）：它的 RED 路徑只認「G5 not done」那句話；
- `pft_cannot`（`tools/p4_health/cells/table.py:390-395`）；
- `tests/python/fixtures/p4_health/preflight_pft.txt:26`（那份 fixture 還存著「G5 not done」那一行）；
- `doc/audit/2026-10-03_p4-health-check/expected_today.tsv`；
- T4–T7 的 oracle（priority 要用 bm priority = 2147483647 − p 換算、optional 的 thrift 顯示為 `TERNARY v &&& ff`、「數字大的贏」要比換算後的值）。

**要注意的地方**
- Q3 採 (a)：don't-care 的第二種寫法一律 400，訊息為「omit the field」。
- Q2 未答：沒有 owner 檢查，沒有改任何 route binding。**但 `flow_5tuple` 的行為不是「照舊」**：空 match 照舊回 200，而具名欄位從 501 變成 200（見最上面的 hold）。
  - 🆕 第三輪：Q2 已照 (a)＋(a-i) 實作為 V7（trunk `6c1a78c8`）。合併後 `flow_5tuple` 在 NDTwin 的 pipeline 上：空 match 與具名欄位**都是 409**。
- 哪些 fixture 變了（精確版）：`test_p4_client_writes.py` 與 `test_table_entry_route.py` 的 p4info fixture 各**新增**了 Synthetic 表（`Synthetic.unspecified_table`；前者另加 `Synthetic.mixed_table`）；`a_client` 替身、`bind_routes`、binding 一個都沒動。被改寫的是九個 501 測試與兩個 pre-flight 測試（它們的斷言本來就是舊行為）；`test_rule_install_times.py` 裡拿 `"optional"` 當「沒人建模的型別」的那顆，改成 `"some_future_type"`。
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
  - 「baseline 的 count 恆為 0」這個承諾只在 NDTwin 是 baseline 表唯一寫入者時成立（Q2 (a) 之下為真），已寫進模組註解。
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
  - 沒有刪掉任何斷言。
- **舊結論要改的**：最上面 hold (2) 解除；「空 match 打 `flow_5tuple` 回 200」只描述 V7 之前；`ryu_flow_stats.py` 那句「直到 owner 檢查擋住」已改成「owner 檢查已擋住」。
- **驗證**（在 `42c22297` 的拋棄式 clone 跑，log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-writer-a/merge-v7/`，每份第一行 commit、最後一行 rc）：
  - merge 當下（`02ce0232`）：`test_p4_client_writes.py` 206 個、37 error（全是 `TableOwnedByNDTwin`）；V7 自己的 owner 兩個檔與其餘四個檔全綠。
  - 修正後（`42c22297`）：`test_p4_client_writes` 207、`test_table_entry_owner` 46、`test_table_entry_owner_package` 5、`test_table_entry_route` 36、`test_foreign_pipeline` 17、`test_exact_one_element_list` 14、`test_readopt` 134、`test_rule_install_times` 44、`test_ryu_flow_stats` 61、`test_switch_state` 71、`tools/p4_exercise` 210，全部 OK，沒有任何 skip。
  - 五個 gate 的 anchor：`check_gate_anchors.py 42c22297` 5/5 ok（全部 gate 136/136 ok）；每個 gate 點名的測試都還在；`bash -n` 全過。
- **還沒做的**：mutation gate 都沒跑（照指示，另一個 gate 在跑）；要跑的清單在交付訊息裡。
