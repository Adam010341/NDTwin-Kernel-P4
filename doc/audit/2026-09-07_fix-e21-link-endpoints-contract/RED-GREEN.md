# E-21 — 看紅的逐字紀錄

分支 `fix/e21-link-endpoints-in-contract`。[Co-developed with claude code -- Adam]

> 🔴 **沒看過紅不算修完。** 下面每一行都是 🟢 **實際跑出來的**，不是抄的。
> 閘門：`tests/shell/mutate_contract_link_endpoints.sh`（不需要建置、不需要 kernel）。
> 直譯器：`p4_proxy/venv/bin/python`。

---

## §1 綠的起點

```
E-21 link-endpoint contract mutation gate
  baseline : 694c8b45631d93d4 tools/contract_test/spec.py
  baseline : e0d54c1a3df7875f tools/contract_test/selftest_fixtures.py

baseline (must be green before any mutation):
  ok       spec baseline green
  ok       selftest baseline green
```

- `tests/python/test_contract_spec.py` ⇒ **Ran 177 tests … OK**（本單之前是 141）。
- `run_contract_test.py --self-test` ⇒ **Self-test passed: 88 checks**（本單之前是 66）。

---

## §2 verdict

```
=== verdict ===
  15 mutations, 0 survived
  4 widenings, 0 wrongly caught

baseline byte-identical: yes (no real file was written)
```

十五顆全被抓、四個對照全留綠，逐格：

```
  caught   M1: the schema stops naming declaration_retained           (spec: test_a_truthy_string_is_not_declaration_retained)
  caught   M2: the check that reads the field answers nothing         (spec: test_the_declined_recovery_must_report_declaration_retained)
  caught   M3: a dpid-0 door stops requiring 400                      (spec: test_the_dpid_zero_doors_accept_only_400)
  caught   M4: an endpoint path is mistyped                           (spec: test_all_four_endpoints_have_a_dpid_zero_door)
  caught   M5: the table is sorted, so the sequence loses its order   (spec: test_the_six_steps_run_in_the_order_the_pairing_rule_needs)
  caught   M6: the tc report need not cover both ends                 (selftest: tc_half_is_reported_per_interface: catches one end cut instead of two)
  caught   M7: the skipped-tc string becomes a free-form excuse       (spec: test_the_tc_report_accepts_both_documented_shapes_and_no_third)
  caught   M8: the injection stops naming what can end it             (spec: test_the_injection_reply_must_name_the_only_endpoint_that_ends_it)
  caught   M9: the PAIRED withdrawal check answers nothing            (spec: test_the_paired_withdrawal_must_not_decline)
  caught   M10: the chosen link need not be switch-to-switch          (spec: test_the_mutating_sequence_names_one_switch_to_switch_link_of_this_topology)
  caught   M11: a topology with no switch link is guessed at          (spec: test_a_topology_with_no_switch_to_switch_link_is_refused_not_guessed)
  caught   M12: the declined step gets its sibling's invariant        (spec: test_the_declined_step_is_checked_by_the_invariant_written_for_it)
  caught   M13: a kernel that never says the failure is sticky passes (selftest: declared_failure_says_who_can_withdraw_it: reports trunk's bare status)
  caught   M14: a read-only run would cut a real link                 (spec: test_every_step_of_the_sequence_needs_allow_mutations)
  caught   M15: the sequence ends where an injection cannot be ended  (spec: test_the_sequence_ends_with_a_withdrawal_that_needs_no_agreement)

  ✅ survived W1: a comment                                           (spec stayed green, as it must)
  ✅ survived W2: the same finding, reworded                          (spec stayed green, as it must)
  ✅ survived W3: an added optional field                             (spec stayed green, as it must)
  ✅ survived W4: a reworded fixture comment                          (selftest stayed green, as it must)
```

閘門本身只印「哪一格紅了」。下面四顆的 unittest 逐字是**另外跑一次同樣的變異**抓下來的
（同一支直譯器、同一份複本；真的檔案一樣沒有被寫過）。

---

## §3 單子點名的三顆，逐字

### M1 — `spec.py` 不再指名 `declaration_retained`

變異：把 `LINK_RECOVERY_REPORTED` 的 `"declaration_retained": Bool(),` 整行拿掉。

```
======================================================================
FAIL: test_a_truthy_string_is_not_declaration_retained (__main__.LinkEndpointContractTest.test_a_truthy_string_is_not_declaration_retained)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/…/tests/python/test_contract_spec.py", line 1443, in test_a_truthy_string_is_not_declaration_retained
    self.assertTrue(validate(spec.LINK_RECOVERY_REPORTED,
                             {**DECLINED_RECOVERY, "declaration_retained": "true"}))
AssertionError: [] is not true

----------------------------------------------------------------------
Ran 177 tests in 0.017s

FAILED (failures=1)
```

⇒ 欄位一旦不被 schema 指名，`"true"` 這個字串就通過了驗證——**這正是一個欄位退化成裝飾的方式**。

### M3 — 400 不在狀態碼集合裡

變異：`inject_link_failure__host_edge_dpid_zero` 的 `expect_status=[400]` 改成 `[404]`。

```
======================================================================
FAIL: test_the_dpid_zero_doors_accept_only_400 (__main__.LinkEndpointContractTest.test_the_dpid_zero_doors_accept_only_400)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/…/tests/python/test_contract_spec.py", line 1636, in test_the_dpid_zero_doors_accept_only_400
    self.assertEqual(entry["expect_status"], [400], entry["name"])
AssertionError: Lists differ: [404] != [400]

First differing element 0:
404
400

- [404]
?    ^

+ [400]
?    ^
 : inject_link_failure__host_edge_dpid_zero

----------------------------------------------------------------------
Ran 177 tests in 0.012s

FAILED (failures=1)
```

⇒ 404 剛好是**門被拆掉之後**那個 payload 會拿到的答案（dpid 0 會解析到某條 host 邊，
邊存在 ⇒ 200；解析不到 ⇒ 404）。所以「連 404 也收」等於**這個檢查對兩種 kernel 都點頭**，
也就是 OV-3 那個形狀。

### M4 — 端點名打錯

變異：`link_recovery_detected__host_edge_dpid_zero` 的 path 打成 `/ndt/link_recovery_detectd`。

```
======================================================================
FAIL: test_all_four_endpoints_have_a_dpid_zero_door (__main__.LinkEndpointContractTest.test_all_four_endpoints_have_a_dpid_zero_door)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/…/tests/python/test_contract_spec.py", line 1629, in test_all_four_endpoints_have_a_dpid_zero_door
    self.assertEqual(doors, set(LINK_ENDPOINT_PATHS))
AssertionError: Items in the first set but not the second:
'/ndt/link_recovery_detectd'
Items in the second set but not the first:
'/ndt/link_recovery_detected'

----------------------------------------------------------------------
Ran 177 tests in 0.011s

FAILED (failures=1)
```

⇒ 打錯的路徑會拿到 404（kernel 的 dispatch 落到 `handleNotFound`），而 404 ≠ 400 ⇒
那筆檢查**永遠紅**，看起來像 kernel 壞了；或者若期望值也跟著放寬，就變成一扇**什麼都不守的門**。

---

## §4 頭條那一顆（E-21 自己的欄位），逐字

### M2 — 讀那個欄位的檢查什麼都不回答

變異：在 `inv_recovery_was_declined_and_said_so` 的第一行插 `return []  # MUTANT`。

```
======================================================================
FAIL: test_a_declined_reply_that_says_only_true_is_not_enough (__main__.LinkEndpointContractTest.test_a_declined_reply_that_says_only_true_is_not_enough)
----------------------------------------------------------------------
    self.assertTrue(spec.inv_recovery_was_declined_and_said_so(bare, None))
AssertionError: [] is not true

======================================================================
FAIL: test_the_declined_recovery_must_report_declaration_retained (__main__.LinkEndpointContractTest.test_the_declined_recovery_must_report_declaration_retained)
----------------------------------------------------------------------
    self.assertTrue(
        spec.inv_recovery_was_declined_and_said_so(APPLIED_RECOVERY, None),
        "a recovery that withdrew an injected declaration passed the declined check, so "
        "the field E-21 put in the contract is not actually being read")
AssertionError: [] is not true : a recovery that withdrew an injected declaration passed the declined check, so the field E-21 put in the contract is not actually being read

======================================================================
FAIL: test_the_declined_reply_must_point_at_the_endpoint_that_can_withdraw_it (__main__.LinkEndpointContractTest.test_the_declined_reply_must_point_at_the_endpoint_that_can_withdraw_it)
----------------------------------------------------------------------
    self.assertTrue(problems)
AssertionError: [] is not true

======================================================================
FAIL: test_the_two_recovery_checks_are_opposites_on_the_same_two_bodies (__main__.LinkEndpointContractTest.test_the_two_recovery_checks_are_opposites_on_the_same_two_bodies)
----------------------------------------------------------------------
    self.assertNotEqual(applied, declined, body)
AssertionError: True == True : {'status': 'link recovery processed'}

----------------------------------------------------------------------
Ran 177 tests in 0.013s

FAILED (failures=4)
```

最後那一格是這一輪最有意思的一行：`{'status': 'link recovery processed'}` 這個 body
**同時通過了「撤回成功」與「被拒」兩個檢查**——也就是 lw8b 那個失效態
（注入被一個沒有配對的 report 撤掉）在契約上變成看不見的。

---

## §5 對照組為什麼要在

W1（純註解）、W2（同一個發現、換句話說）、W3（多一個 optional 欄位）、W4（fixture 註解改字）
四個都必須留綠。沒有它們，上面十五顆紅只證明「這些測試會對改動有反應」，
不證明它們在描述行為——`W2` 尤其重要：本單有三個檢查在讀回應的**內容**
（`declaration_retained`／`until`／`detail` 非空），如果連措辭都被釘死，那就是在釘一段散文。

---

## §6 兩條 lane 都真的跑了

一條從不執行的 lane 什麼也不證明，所以 15 顆裡有 2 顆（M6／M13）是拿
`run_contract_test.py --self-test` 判的，其餘 13 顆拿 `tests/python/test_contract_spec.py` 判，
而 **baseline 兩條都先驗過綠**（見 §1）。
