# W10 看紅：`tests/shell/mutate_nickname_overlay.sh`

分支 `fix/w10-nickname-overlay`。2026-09-06。
`src/ndt_core/collection/TopologyAndFlowMonitor.cpp` sha256 `fa3b82b449da3fcb3432d94a77a9f226c3a64adb60849b475d0b51a94e64276e`；
`tools/test_workflow/ndt` sha256 `fa6b8c4d27d4d8f7…`。**兩份在整輪之後都逐位元還原。**

[Co-developed with claude code -- Adam]

---

## 1. 閘門結果（🟢 跑過，逐字）

```
W10 mutation gate -- the model file is read-only and the names live in an overlay
  baseline  : src/ndt_core/collection/TopologyAndFlowMonitor.cpp  sha256 fa3b82b449da3fcb
  baseline  : tools/test_workflow/ndt  sha256 fa6b8c4d27d4d8f7
baseline (unmutated) must build and be green:
  ok       gtest baseline green ([  PASSED  ] 16 tests.)
  ok       ndt baseline green (Ran 73 checks, 0 failed)

mutations -- the kernel:
  caught   M1 a nickname is written to the model file again     (NicknamePersistenceTest.AModifyNicknameLeavesTheTopologyFileByteIdentical went red)
  caught   M2 nothing is persisted anywhere                     (NicknamePersistenceTest.TheNicknameIsWrittenToTheOverlayUnderTheSwitchsDpid went red)
  caught   M3 the overlay is never applied at load              (NicknamePersistenceTest.AFreshLoadPicksTheNicknameBackUp went red)
  caught   M4 the device name is not persisted                  (NicknamePersistenceTest.TheDeviceNameGoesToTheSameEntryAndDoesNotEvictTheNickname went red)
  caught   M5 the graph is not updated either                   (NicknamePersistenceTest.ANicknameChangeStillReachesTheGraph went red)
  caught   M6 a host is keyed by dpid on the write side         (NicknamePersistenceTest.AHostIsKeyedByItsMacAndNotByItsDpid went red)
  caught   M7 the loader looks hosts up by dpid                 (NicknamePersistenceTest.AFreshLoadPicksAHostsNicknameBackUpUnderItsMac went red)
  caught   M8 all models share one overlay                      (NicknamePersistenceTest.TheOverlayPathFollowsTheActiveTopology went red)
  caught   M9 the overlay is inside setting/                    (NicknamePersistenceTest.TheDefaultOverlayPathIsOutsideSettingAndNamedAfterTheModel went red)
  caught   M10 an unreadable overlay refuses the load           (NicknamePersistenceTest.AnUnreadableOverlayDoesNotStopTheTopologyFromLoading went red)

controls (behaviour-preserving; these must stay GREEN):
  ok       C1 the empty-value test is spelled differently       (control stayed green, as it must)
  ok       C2 the comment above the atomic writer is reworded   (control stayed green, as it must)

mutations -- ndt status --check:
  caught   M11 --check hashes the overlay with the model file   (🔴 renaming two switches leaves --check GREEN went red)
  caught   M12 the overlay row becomes part of the verdict      (🔴 renaming two switches leaves --check GREEN went red)
  caught   M13 the row no longer says it was not compared       (  and the row says it was left out on purpose went red)

baseline restored: src/ndt_core/collection/TopologyAndFlowMonitor.cpp and tools/test_workflow/ndt byte-identical to the pre-run snapshot
rebuilding from the restored source:
  ok       green again from the restored source

15 mutations, 0 survived
```

**15 個變異、0 存活、2 個對照留綠、原始碼逐位元還原、還原後重建再綠。**

---

## 2. 逐字的紅（🟢 跑過；把修法拿掉之後，同一顆 binary）

閘門會刪掉自己的 run log，所以下面這兩顆是**另外手動重跑一次**留下來的
（先綠 → M1 紅 → M3 紅 → 還原再綠，同一個 build 目錄）。

### GREEN（未變異）

```
[==========] 16 tests from 1 test suite ran. (159 ms total)
[  PASSED  ] 16 tests.
gtest rc=0
```

### 🔴 M1 — 把「不寫模型檔」拿掉（＝回去寫模型檔）

變異：`setVertexNickname` 在寫完 overlay 之後**多寫一次模型檔**
（`writeJsonFileAtomically(activeTopologyPath(), overlay);`）。

```
tests/test_NicknameOverlay.cpp:317: Failure
Expected equality of these values:
  firstDifference(files.original(), files.topologyNow())
    Which is: "differs at byte 5 (was 16960 bytes, now 194) | before: \"{\n  \"nodes\": [\n    {\n      \"brand_name\": \"BMv2\",\n      \"\" | after: \"{\n  \"hosts\": {},\n  \"switches\": {\n    \"1\": {\n      \"nickn\""
  "same"
the kernel wrote the model file; W10 is that it must not touch it at all
[  FAILED  ] NicknamePersistenceTest.AModifyNicknameLeavesTheTopologyFileByteIdentical (2 ms)
```

同一顆變異底下另外五支也紅（`TheMininetTopologyKeepsItsBytesToo`、
`EveryShippedTopologySurvivesARenameByteForByte`、`AFreshLoadPicksTheNicknameBackUp`、
`AFreshLoadPicksAHostsNicknameBackUpUnderItsMac`、`AnOverlayOnlyTouchesTheDeviceItNames`），
`[  PASSED  ] 10 tests.`／`gtest rc=1`。

### 🔴 M3 — 啟動不疊 overlay

變異：`parseStaticTopologyFile` 末行的 `applyNicknameOverlayNoLock();` → `(void)0;`。

```
tests/test_NicknameOverlay.cpp:456: Failure
Expected equality of these values:
  second.nicknameOf(*v)
    Which is: "s1"
  kNewNickname
    Which is: "NDT-TEST-NICKNAME"
the overlay was written but never applied, so the rename did not outlive the process -- the model file is untouched and the name is gone
[  FAILED  ] NicknamePersistenceTest.AFreshLoadPicksTheNicknameBackUp (4 ms)
```

`[  PASSED  ] 13 tests.`／`gtest rc=1`。
🔴 **這顆變異底下所有「檔案逐位元相同」的斷言全部留綠** ——
一個「乾脆什麼都不存」的 kernel 會通過那些斷言，這三支才看得見它。

### GREEN AGAIN（還原）

```
[  PASSED  ] 16 tests.
gtest rc=0
restored sha256:  fa3b82b449da3fcb3432d94a77a9f226c3a64adb60849b475d0b51a94e64276e
```

---

## 3. 這一輪自己踩到的兩件事（不藏）

1. 🔴 **閘門第一輪 `GATE_RC=1`，五個變異從來沒被套用。**
   `assert_unique` 用 `grep -c -F -- "$anchor"`，而 **grep -F 把含換行的 pattern 讀成好幾個
   pattern，數的是「符合其中任何一行」的行數**，所以每一個多行 anchor 都回報 3／5／3／24／3
   然後被判 INVALID。閘門**有誠實地說出來**（`5 could not be applied or built -- a human must look`，
   rc=1），這是它做對的地方；但那五顆（含兩個 host key 的方向、per-model 路徑、
   「壞 overlay 擋啟動」與一個對照）**什麼都沒量到**。
   🔑 **是 `check_gate_anchors.py` 對同一個 commit 回 `ok(15)` 才讓這件事被看見** ——
   它用 Python `str.count()` 數逐字字串。`assert_unique` 已改成同一種數法（`ef23ce82`），
   並雙向驗過（五個 anchor 都是 1；一個真的重複的字串 `        return;` 仍然被判 19 次、拒絕）。
2. **第一版的紅是 800 KB。** `EXPECT_EQ` 兩個完整拓樸檔在失敗時會把**兩份文件都印出來**。
   改成 `firstDifference()`（相等時回 `"same"`，所以性質沒變），紅訊息變成上面那一行
   （`cdf607c8`）。**那一行就是本文件要引用的東西**，800 KB 引不了。

---

## 4. 相關

- 修法說明：`doc/audit/2026-09-06_fix-nickname-overlay/FIX-NICKNAME-OVERLAY.md`
- 交付總結：`scratch/overnight-2026-09-05/fix/W10-SUMMARY.md`（**scratch 不進版控**）
- 閘門：`tests/shell/mutate_nickname_overlay.sh`
- 測試：`tests/test_NicknameOverlay.cpp`、`tests/shell/test_ndt_status_check_baseline.sh` §9
