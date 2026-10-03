[Co-developed with claude code -- Adam]

# Cut A 摘要：P4 通用 table writer 支援 ternary／range／optional＋priority

**結論**：Cut A（除 V7 外）已完成並 commit，head 為 `1b16b0a0`，在分支 `feat/p4-ternary-writer-a`，未推送。V7 依指示未做。

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
2. 六欄位全省略、priority 10：被接受，等於一條 catch-all；因此 §1.5 的缺陷從「推論」變成「已量到」。
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

**要注意的地方**
- Q3 採 (a)：don't-care 的第二種寫法一律 400，訊息為「omit the field」。
- Q2 未答：沒有 owner 檢查，沒有改任何既有 fixture，`flow_5tuple` 空 match 的現況行為照舊（測試明確寫成「今天接受」）。
- 順帶發現：priority 超過 int32 時，舊碼會丟出沒接住的 protobuf ValueError（等於 500）；現在是 400。
- 另一個既有問題：`mutate_p4_rule_install_time.sh` 在 dd8022fa 本來就會 baseline 紅（缺 `setting/`），已修。
- `entry_key` 的 default key（§10-2 後半）留給 Cut B。
- M-B7、M-B14、M-B20 沒有退役：它們守的 `journaled:false` 在 Cut B 之前仍然是事實。

**V7 待辦**（等 Q2 答覆）：見上方 V7 follow-up list，包含 `source` 參數、409 body、R19／R19b、V7 與 M-J29 mutant，以及會翻轉的既有測試清單。
