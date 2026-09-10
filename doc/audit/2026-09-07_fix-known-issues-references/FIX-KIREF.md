# FIX-KIREF — `doc/KNOWN-ISSUES.md` 的引用改用條目代號，並加一支測試守住

[Co-developed with claude code -- Adam]

單子＝`scratch/overnight-2026-09-05/fix/TICKETS-0907/R3/R3-KIREF.md`；
裁決＝`DECISIONS.md`「09-07 21:0x（R3-DOC §7 三題）」第 3 條。
分支 `fix/known-issues-refs-by-entry-code`，base＝trunk `1a284f75`。**無建置**（純 python＋文件）。

---

## 1. 缺陷

`doc/KNOWN-ISSUES.md` 是一份 3,483 行、天天在中間插條目的清單（光 09-05 那一夜就有六條分支在動它）。
插一條就把它下面的每一行都推走 ⇒ **`KNOWN-ISSUES.md:<行號>` 這種引用是制度性會壞的**。

在 `1a284f75` 上，全 repo（排除 `scratch/`、`build*/`、`.git/`、`*.log`）有 **62 個**行號引用，
掃描器判定其中 **58 個不可信**。四個**在寫下的當天就已經指錯**（單子 §0 點名的那五處即在此列）：

- `findings/IPERF3-CONFLICT.md` 引的 `:1614`
- `FIX-FLOW-VISIBILITY-UNITS.md` 引的 `:1429`／`:1475`
- `doc/2026-08-29_bmv2-performance-study.md` 與 `2026-08-28_flow-count-capacity/FINDINGS.md` 引的 `:1679`

剩下四筆判定 ok 的（#12／#15／#51／#54）**是巧合，不是正確**：它們的舊行號在漂移之後
剛好還落在同一條條目的區段裡，而條目本身的內容早就換過了。四筆一樣改掉。

🔴 **本檔的「改前」欄只寫行號（`:1679`），不寫完整引用形狀。** 理由：本檔在 `doc/` 底下，
是掃描器讀的檔之一；寫成完整形狀，這份修法文件自己就會被自己的閘門抓到。
**這不是規避，是刻意讓儀器不對自己開特例**——測試檔與閘門腳本也用同樣的手法
（fixture 用 `%d` 組、閘門用 `"$KI:1679"` 組），三個檔都在掃描範圍內。

---

## 2. 改了什麼

**(a) 63 處引用改寫，34 個檔**（62 個閘門認得的形狀 ＋ `RATIONALE.md:281` 的
`（KNOWN-ISSUES 1488）` 空白形，順手一起改）。寫法採 repo 已有的多數形
（`git grep -c`：`KNOWN-ISSUES <代號>` **287** 處／`KNOWN-ISSUES **<代號>**` 3 處／
`KNOWN-ISSUES §<代號>` 5 處／`KNOWN-ISSUES.md#...` 0 處）⇒ **`KNOWN-ISSUES <代號>`**，全單一致。

**行號一律不留。** 單子允許「留行號當附註」，本單選擇不留，理由是可驗證的：
同一夜有六條分支在 `doc/KNOWN-ISSUES.md` 裡插條目（B-10／B-11／B-12／B-6／C-5／C-6／G-13），
**任何我今天留下的行號，在 Adam 早上併完之後就是錯的**——留一個就等於在合併後的樹上
埋一顆紅。舊行號當時指向什麼，逐筆記在 §3 的表裡，資訊沒有丟。

**(b) 一支測試** `tests/python/test_known_issues_references.py`（stdlib、離線、不需要 kernel、
不建置；30 個 case，0.2 s）。掃 `doc/ tests/ tools/ src/ include/ p4_proxy/` 與根目錄 `*.md`，
對每個 `KNOWN-ISSUES.md:<n>`（`.md` 可省）形式的引用：找同一行（找不到再找同一段落）最近的
`[A-Z]-\d+[a-z]?`，斷言第 n 行（與範圍的 m 行）落在該代號的區段裡。四種判定：
`NO-CODE`／`WRONG-ENTRY`／`UNRESOLVABLE-CODE`／`OUT-OF-RANGE`，訊息一律帶「改成條目代號」。

**(c) 變異閘門** `tests/shell/mutate_known_issues_references.sh`：9 個變異＋1 個對照格。

**(d) 手冊** `doc/2026-08-17_testing-manual.md` 新增 §5.1（純附加，接在 §5 尾）。

🔴 **`doc/KNOWN-ISSUES.md` 一行都沒動。** 不改代號、不補代號、不加註。理由是合併順序：
同一夜六條分支都在動這個檔，本單動它必衝，而本單的價值（引用的穩定性）不需要動它就拿得到。
沒有代號的十七個 `###` 標題怎麼辦 ⇒ SUMMARY §7，**沒有自己補代號**。

---

## 3. `1a284f75` 上抓到的全部 62 筆（逐筆，含改後寫法）

「該行號實際落在」＝那個行號在 `1a284f75` 的 `doc/KNOWN-ISSUES.md` 裡真正屬於哪一條條目。

| # | 引用它的檔:行 | 改前引的行號 | 該行號實際落在 | 判定 | 改後寫成 |
|---|---|---|---|---|---|
| 1 | `NEXT.md:232` | `:2164` | **C-4b** | WRONG-ENTRY | KNOWN-ISSUES §G |
| 2 | `NEXT.md:234` | `:1488` | **B-9** | WRONG-ENTRY | （KNOWN-ISSUES §G 同一則） |
| 3 | `RATIONALE.md:280` | `:2164` | **C-4b** | NO-CODE | KNOWN-ISSUES §G |
| 4 | `doc/2026-08-29_bmv2-performance-study.md:331` | `:1679` | **B-12** | UNRESOLVABLE-CODE | KNOWN-ISSUES〈生產線在跑的那顆 kernel 的重建配方〉 |
| 5 | `doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md:17` | `:1679` | **B-12** | NO-CODE | KNOWN-ISSUES〈生產線在跑的那顆 kernel 的重建配方〉 |
| 6 | `doc/audit/2026-08-30_known-issues-wave/12_auditor-rulings.md:178` | `:444` | **A-4e** | WRONG-ENTRY | **KNOWN-ISSUES B-3 過期** |
| 7 | `doc/audit/2026-08-31_completeness-experiments/B-nslab-build/CROSSCHECK-existence-vs-enabled.md:5` | `:1018` | **B-2d** | NO-CODE | KNOWN-ISSUES E-2 |
| 8 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/COST-TABLE.md:6` | `:1018` | **B-2d** | NO-CODE | KNOWN-ISSUES E-2 |
| 9 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/PREREG.md:83` | `:1018` | **B-2d** | NO-CODE | KNOWN-ISSUES E-2 |
| 10 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/PREREG.md:88` | `:1018` | **B-2d** | NO-CODE | KNOWN-ISSUES E-2 |
| 11 | `doc/audit/2026-08-31_sampling-ceiling-after-merge/TBD-DRAFT.md:23` | `:1018` | **B-2d** | NO-CODE | KNOWN-ISSUES E-2 |
| 12 | `doc/audit/2026-09-02_fix-design-campaign/LEDGER.md:198` | `:132-133` | **A-2** | ok | KNOWN-ISSUES A-2 機制節的同一條舊引用 |
| 13 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-2.md:30` | `:105-108` | **A-2** | NO-CODE | entry（KNOWN-ISSUES A-2 的 item 2，機制節帶同一句）說： |
| 14 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-2.md:106` | `:134-136` | **A-2** | NO-CODE | （KNOWN-ISSUES A-2） |
| 15 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-2.md:612` | `:132-133` | **A-2** | ok | KNOWN-ISSUES A-2 的機制節 |
| 16 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-2.md:625` | `:105-111` | **A-2** | NO-CODE | 取代 KNOWN-ISSUES A-2 |
| 17 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-4c.md:132` | `:270-281` | **A-4** | NO-CODE | | KNOWN-ISSUES A-4c 的說法 | |
| 18 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-4d.md:98` | `:282-306` | **A-4** | NO-CODE | KNOWN-ISSUES A-4d 的機制敘述 |
| 19 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-4d.md:353` | `:295-299` | **A-4** | WRONG-ENTRY | KNOWN-ISSUES A-4d 條目 |
| 20 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-4f.md:533` | `:505` | **A-4f** | WRONG-ENTRY | KNOWN-ISSUES **B-2 的 case ②** |
| 21 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-7.md:18` | `:411-414` | **A-4d** | NO-CODE | (KNOWN-ISSUES A-7) |
| 22 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-7.md:427` | `:410-416` | **A-4d** | NO-CODE | (KNOWN-ISSUES A-7) |
| 23 | `doc/audit/2026-09-02_fix-design-campaign/findings/A-8.md:55` | `:116` | **A-2** | WRONG-ENTRY | 更正 KNOWN-ISSUES A-2 裡的一句話 |
| 24 | `doc/audit/2026-09-02_fix-design-campaign/findings/B-1-VERIFY.md:615` | `:964` | **B-2** | WRONG-ENTRY | KNOWN-ISSUES §D 的 F-5 那列 |
| 25 | `doc/audit/2026-09-02_fix-design-campaign/findings/B-1-VERIFY.md:643` | `:453-504` | **A-4e** | NO-CODE | KNOWN-ISSUES B-1 與 §D 的 F-5 那列 |
| 26 | `doc/audit/2026-09-02_fix-design-campaign/findings/B-3.md:126` | `:886` | **B-1** | WRONG-ENTRY | KNOWN-ISSUES 的 F-1 |
| 27 | `doc/audit/2026-09-02_fix-design-campaign/findings/B-3.md:203` | `:886` | **B-1** | WRONG-ENTRY | F-1（KNOWN-ISSUES §C 表那一列） |
| 28 | `doc/audit/2026-09-02_fix-design-campaign/findings/B-x.md:110` | `:776-853` | **A-10** | NO-CODE | | 條目 | KNOWN-ISSUES §B-x | |
| 29 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-1.md:52` | `:886` | **B-1** | NO-CODE | KNOWN-ISSUES F-1 描述的那一半 |
| 30 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-1.md:153` | `:886` | **B-1** | WRONG-ENTRY | | KNOWN-ISSUES 的 F-1 兩列 | |
| 31 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-14-F-16-F-4.md:216` | `:965` | **B-2** | WRONG-ENTRY | （KNOWN-ISSUES §D 的 F-4 那列） |
| 32 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-15.md:141` | `:890` | **B-1** | NO-CODE | 與 KNOWN-ISSUES F-15 的對帳 |
| 33 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-15.md:403` | `:890` | **B-1** | NO-CODE | KNOWN-ISSUES F-15 |
| 34 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-15.md:437` | `:890` | **B-1** | NO-CODE | KNOWN-ISSUES F-15 的「bring-up guard 擋下了」 |
| 35 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-15.md:536` | `:890` | **B-1** | WRONG-ENTRY | | KNOWN-ISSUES F-15 | |
| 36 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-6.md:575` | `:888` | **B-1** | NO-CODE | KNOWN-ISSUES F-6 那一列 |
| 37 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:98` | `:885` | **B-1** | WRONG-ENTRY | KNOWN-ISSUES F-8 寫 |
| 38 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:122` | `:905-906` | **B-1** | WRONG-ENTRY | （見 KNOWN-ISSUES §C 的「關機決策實際讀什麼」那一列） |
| 39 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:136` | `:1150-1154` | **B-2c** | WRONG-ENTRY | 而 KNOWN-ISSUES §F 記載 |
| 40 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:139` | `:889` | **B-1** | WRONG-ENTRY | （KNOWN-ISSUES F-9） |
| 41 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:167` | `:1785` | **（無條目）** | NO-CODE | 與 KNOWN-ISSUES |
| 42 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:206` | `:1785` | **（無條目）** | WRONG-ENTRY | KNOWN-ISSUES 記的 |
| 43 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:369` | `:885` | **B-1** | WRONG-ENTRY | **KNOWN-ISSUES F-8 那一列沒有動** |
| 44 | `doc/audit/2026-09-02_fix-design-campaign/findings/F-8.md:388` | `:885` | **B-1** | WRONG-ENTRY | **Q2. KNOWN-ISSUES F-8 的「暫態」要不要改？** |
| 45 | `doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md:87` | `:1614` | **B-11** | NO-CODE | KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉的兩處都寫 |
| 46 | `doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md:149` | `:1684` | **B-12** | NO-CODE | KNOWN-ISSUES 同名條目同族 |
| 47 | `doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md:349` | `:1614` | **B-11** | NO-CODE | **KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉兩處、TBD-DRAFT:146、 |
| 48 | `doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md:530` | `:1614` | **B-11** | NO-CODE | KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉兩處、`TBD-DRAFT:146` |
| 49 | `doc/audit/2026-09-02_fix-design-campaign/findings/IPERF3-CONFLICT.md:591` | `:1617` | **B-11** | NO-CODE | KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉的既有判定 |
| 50 | `doc/audit/2026-09-02_recompute-paired-ab/PREREG.md:241` | `:1610` | **B-11** | NO-CODE | KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉已登記 |
| 51 | `doc/audit/2026-09-03_fix-chaos-invariants/FIX-CHAOS-INVARIANTS.md:52` | `:516` | **A-4f** | ok | KNOWN-ISSUES A-4f 記 |
| 52 | `doc/audit/2026-09-03_fix-flow-visibility-units/FIX-FLOW-VISIBILITY-UNITS.md:72` | `:1429` | **B-8** | WRONG-ENTRY | `doc/KNOWN-ISSUES.md` §B-x 之後新增〈B-x 的反向〉小節 |
| 53 | `doc/audit/2026-09-03_fix-flow-visibility-units/FIX-FLOW-VISIBILITY-UNITS.md:81` | `:1475` | **B-9** | WRONG-ENTRY | KNOWN-ISSUES **F-9**（兩處） |
| 54 | `doc/audit/2026-09-03_fix-flow-visibility-units/FIX-FLOW-VISIBILITY-UNITS.md:83` | `:275` | **A-4** | ok | KNOWN-ISSUES **A-4** |
| 55 | `doc/audit/2026-09-03_night-rounds/BRANCHES-FOR-REVIEW.md:181` | `:2164` | **C-4b** | NO-CODE | KNOWN-ISSUES §G |
| 56 | `doc/audit/2026-09-03_night-rounds/COMMON-BRIEF.md:164` | `:2164` | **C-4b** | NO-CODE | in KNOWN-ISSUES §G |
| 57 | `doc/audit/2026-09-04_fix-dispatch-succeeded-counter/OPTIONS-SUCCEEDED-COUNTER.md:56` | `:554` | **A-4f** | NO-CODE | KNOWN-ISSUES 的 A-4f／A-7 兩條 |
| 58 | `tests/python/test_unavailable_metric_sentinel.py:8` | `:886` | **B-1** | WRONG-ENTRY | F-1 (doc/KNOWN-ISSUES.md, entry F-1) |
| 59 | `tests/test_OptimisticTopologyReporting.cpp:236` | `:881` | **B-1** | WRONG-ENTRY | // F-4 -- doc/KNOWN-ISSUES.md, entry F-4 |
| 60 | `tests/test_OptimisticTopologyReporting.cpp:304` | `:884` | **B-1** | WRONG-ENTRY | // F-16 -- doc/KNOWN-ISSUES.md, entry F-16 |
| 61 | `tests/test_OptimisticTopologyReporting.cpp:341` | `:883` | **B-1** | WRONG-ENTRY | // F-14 -- doc/KNOWN-ISSUES.md, entry F-14 |
| 62 | `tests/test_SimulatedDeviceMetrics.cpp:6` | `:886` | **B-1** | WRONG-ENTRY | F-1, doc/KNOWN-ISSUES.md, entry F-1. |

**19 筆（62 筆裡）的目標本身沒有代號可引**（另加 `RATIONALE.md:281` 那個空白形，共 20 處）⇒
改成「章／小節＋標題引號」，**沒有替它們補代號**。三種情況：目標是那十七個沒有代號的 `###`
標題之一、目標根本不是標題（是 `##` 章底下的 bullet 或散文）、或目標的代號不合
`[A-Z]-\d+`（`B-x`）：

| 目標 | 它在 `1a284f75` 的位置 | 改後寫法 | 出現在 |
|---|---|---|---|
| `### 🟡 生產線在跑的那顆 kernel 的重建配方…` | `:3265`（沒有代號的 `###`） | `KNOWN-ISSUES〈生產線在跑的那顆 kernel 的重建配方〉` | #4、#5 |
| `` ### `measure.sh` 內含專案硬規矩禁用的 `pkill -f`… `` | `:3120`（沒有代號的 `###`） | ``KNOWN-ISSUES〈`measure.sh` 內含 `pkill -f`〉`` | #45、#47、#48、#49、#50 |
| `### 哨兵值會製造空洞的通過…` | `:3421`（沒有代號的 `###`） | `KNOWN-ISSUES`（下一句已逐字引標題） | #41、#42 |
| `### 🔴 兩個守衛在最需要它們的時候失效…` | `:3230`（沒有代號的 `###`） | `＝KNOWN-ISSUES 同名條目` | #46 |
| 「`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell」 | `:2738`，`## G.` 底下的 **bullet**，連標題都不是 | `KNOWN-ISSUES §G` | #1、#2、#3、#55、#56 |
| 「關機決策實際讀什麼」那一列 | `:1905`，`## C.` 底下的散文表格，沒有 `###` | `KNOWN-ISSUES §C 的「關機決策實際讀什麼」那一列` | #38 |
| 「Mininet 靜靜忽略 `bw>1000`」 | `:2401`，`## F.` 底下的 bullet | `KNOWN-ISSUES §F` | #39 |
| `## B-x.` 與 `### B-x 的反向` | `:1681`／`:1786`——**`B-x` 不合 `[A-Z]-\d+`**，掃描器不認 | `KNOWN-ISSUES §B-x` | #28、#52 |

⇒ **這 20 處在閘門的視線之外**（它只認代號）。要不要替那十七個標題補代號＝SUMMARY §7-1。

`.cpp`／`.py` 註解裡的四＋一處（#58–#62）改成英文的 `doc/KNOWN-ISSUES.md, entry F-n`——
純註解，不影響行為，也不需要重新編譯（本單無建置，那四個 `.cpp` 這一輪**沒有編過**）。

---

## 4. 閘門看紅（逐字）

🔴 **下面幾個逐字塊裡的行號被加了角括號**（`:<2164>`）：這份文件在掃描範圍內，原樣貼會被自己的閘門抓到。理由同 §1，除了那對角括號以外逐字。

### 4.1 base 上先看紅：`1a284f75` ＋ 只加測試（引用尚未改）

```
AssertionError: 0 != 58 : 58 citation(s) of KNOWN-ISSUES.md cannot be trusted. 改成條目代號 -- 見 doc/audit/2026-09-07_fix-known-issues-references/FIX-KIREF.md：
  NEXT.md:232  KNOWN-ISSUES.md:<2164>         claims G-9      WRONG-ENTRY        line 2164 is in C-4b -- 改成條目代號
  ...（58 行，全表見上面 §3）
Ran 30 tests in 0.217s
FAILED (failures=1)
```

改完之後同一支測試：`Ran 30 tests in 0.204s` ／ `OK`。

### 4.2 變異閘門

```
baseline (must be green before any mutation):
OK

  caught   M1: a stale line-number citation comes back (data)       (test_every_line_number_citation_names_the_entry_it_lands_in went red)
  caught   M2: .cpp is not scanned                                  (test_a_cpp_comment_is_scanned went red)
  caught   M3: violations are found and never reported (rc 0)       (test_a_line_in_another_entry_is_reported went red)
  caught   M4 (widening): a correct citation is reported too        (test_a_correct_reference_is_not_a_violation went red)
  caught   M5: the .md-less spelling is a bypass again              (test_the_md_less_spelling_is_read_too went red)
  caught   M6: verbatim records are corrected like source           (test_a_log_is_a_verbatim_record_and_is_not_read went red)
  caught   M7: a table row stops being an entry                     (test_a_table_row_is_an_entry_too went red)
  caught   M8: the walk visits nothing and the scan is green        (test_the_scan_actually_read_the_repository went red)
  caught   M9: a code anywhere in the file counts as claimed        (test_a_code_in_a_different_paragraph_does_not_count went red)

  SURVIVED C1 (control): a comment is reworded                      (control, as required)

baseline byte-identical: yes  tests/python/test_known_issues_references.py
GATE-SUMMARY mutations=9 survived=0 controls=1 red=0
mutation gate: 9 mutations, 0 survived; 1 control(s), 0 went red
```

M1 是**對資料**下的變異（把 #5 那筆的舊引用放回去），M2–M9 是**對掃描器**下的。兩者是不同的
失效，這支閘門是唯一把它們分開的地方。M1 的逐字紅：

```
FAIL: test_every_line_number_citation_names_the_entry_it_lands_in (__main__.TheRepositoryAsItStands.test_every_line_number_citation_names_the_entry_it_lands_in)
AssertionError: 0 != 1 : 1 citation(s) of KNOWN-ISSUES.md cannot be trusted. 改成條目代號 -- 見 doc/audit/2026-09-07_fix-known-issues-references/FIX-KIREF.md：
  doc/audit/2026-08-28_flow-count-capacity/FINDINGS.md:17  KNOWN-ISSUES.md:<1679>         claims (none)   NO-CODE            line 1679 is in B-12 -- 改成條目代號
```

M4（widening）的逐字紅——**這一格是唯一證明掃描器還會「不開火」的**：

```
FAIL: test_a_correct_reference_is_not_a_violation (__main__.WhatIsAViolation.test_a_correct_reference_is_not_a_violation)
AssertionError: Lists differ: [] != [doc/x.md:1  KNOWN-ISSUES.md:<11> ... claims A-4c     WRONG-ENTRY        line 11 is in A-4c -- 改成條目代號]
```

**兩個變異在第一次跑的時候活下來，是真的活下來，不是設定問題**，兩個都改了受測物：

- **M6 活下來**＝`VERBATIM_SUFFIXES` 當時**根本沒有作用**：`.log` 被擋掉是因為它不在
  `TEXT_SUFFIXES` 白名單裡，把黑名單清空什麼都不會發生。**同一條規則寫在兩個地方，
  真正生效的那個沒人找得到。** 修法＝把 `.log`／`.diff`／`.patch` 放進 `TEXT_SUFFIXES`
  （它們**是**文字檔），讓黑名單成為唯一的排除點。
- **M7 活下來**＝被指名的 case 是 `ERROR` 不是 `FAIL`（`self.spans["F-9"]` 丟 KeyError），
  而閘門 grep 的是 `^FAIL:`。**一個會爆炸而不是失敗的斷言，是閘門看不見的斷言。**
  修法＝那三個 case 改用 `.get()`。

---

## 5. 對單子的兩處放寬（都是一行可還原）

1. **引用形狀的正規式把 `.md` 變成可選**（單子寫的是 `KNOWN-ISSUES\.md:(\d+)`）。
   理由：`1a284f75` 上 62 筆裡有 **20 筆**寫成沒有 `.md` 的形式（#2、#6、#23、#24、#27、#29、
   #32、#34、#46–#49 …），同一個缺陷、同一個檔。只讀長的那一種＝**把自己的繞道寫進閘門**。
   還原＝`CITATION_RE` 一行。
2. **`*.diff`／`*.patch` 與 `*.log` 一起排除**（單子只點名 `*.log`）。理由是單子給的理由本身：
   「log 是逐字紀錄，不能改也不該檢查」——`.diff`／`.patch` 是同一類。今天這兩種副檔名裡
   **一筆引用都沒有**（所以這次沒有差別），排除它們是為了不在未來變成一個「唯一修法是竄改
   紀錄」的永久紅。還原＝`VERBATIM_SUFFIXES` 一行。

另外，掃描器讀得懂三種條目形狀（`### <代號>`／`## <代號>.`／表格列 `| 🏁 **F-9** | …`），
比單子寫的只有 `###` 多兩種。**這不是放寬判準，是防止假陽性**：`F-1`／`F-4`／`F-5`／`F-9`／
`F-13`／`F-14`／`F-15`／`F-16` 在這份文件裡**沒有 `###` 標題**，只有表格列；只認 `###` 的話，
每一筆 F 引用都會被判成「查不到代號」，而那是儀器的問題不是文件的問題。

---

## 6. 沒有做的

- **`doc/KNOWN-ISSUES.md` 本身一個字都沒動**（含十七個沒有代號的 `###` 標題）。
- **`*.log` 沒有改也沒有檢查**（含 `doc/audit/2026-09-03_night-rounds/round6-bug-shapes/03_rank1_elephant_flag.log` 裡的三處，那是別的 worktree 的 grep 輸出）。
- **沒有動 CMake、沒有加 ctest 條目、沒有建置**。`tools/test_workflow/l1_unit_tests.sh` 用
  glob 收 `tests/python/test_*.py`，新測試會自動被收；本單**沒有實跑整支 l1**（那會建置）。
- 「其他文件」的行號引用（`FINDINGS-COVERAGE.md:236` 那一族）**沒有碰**——另一個母體，見 SUMMARY §7。
- `KNOWN-ISSUES 1488` 這種**只有空白沒有冒號**的形式，閘門**不認**（會和日期、計數撞號）。
  今天 repo 裡還有四處（`LEDGER.md:273`、`RECONCILIATION.md:21/74`、`12_auditor-rulings.md` 的
  `at line 1661`），見 SUMMARY §7。

[Co-developed with claude code -- Adam]
