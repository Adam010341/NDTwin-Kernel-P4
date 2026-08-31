---
name: mutation-gate-for-tests
description: "A test is not delivered until you have watched it fail — apply a named mutation, observe the failure, revert. Has caught 12 false tests on NDTwin-Kernel"
metadata:
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-31T09:58:13.662Z
---

Every test ships with the mutation that breaks it: the exact file and line, old text → new text, plus the **observed** failure output. Apply it, `grep` to confirm the edit landed, run, capture the real `[  FAILED  ]` / `FAIL:` lines, revert. If no mutation can be found that breaks a test, delete the test — it proves nothing. Prefer narrow mutations: one that breaks 30 tests at once is weak evidence for any single one.

**Why:** on this repo the failure mode is not "tests fail", it is "tests pass while proving nothing", and it is common rather than exceptional. Measured instances:

- Mutation has caught **7** of my own false tests, including two that read as obviously correct — e.g. one asserting a map was "replaced too" when the mutation-free version passed anyway because `operator[]` overwrites, and one claiming an empty table still registered a switch when an earlier non-empty ingest had already registered it.
- The repo's pre-existing P4 tests asserted a bug as intended behaviour, **and** the whole suite was silently SKIPPED (double `Logger::init` throws), **and** `ctest` still reported 100% green.
- Three tooling checks reported PASS while examining zero records.
- A mutation harness I wrote reported "all four mutants survived" because a `grep -v "("` filter ate both forms of the FAILED line. Verify the harness too, not just the code.

**A surviving mutation has three causes, not two.** Besides "the test cannot catch it" and "the target is unreachable", there is **the mutant is equivalent** — the change compiles to different code with identical observable behaviour. Measured: `if (ep.srcDpid != 0)` → `if (false)` in the topology loader killed nothing, because the `else if (!ep.srcIp.empty())` branch resolves the *same* vertex (all 10 switches carry an IP, all 32 inter-switch edges carry `src_ip`, and `findVertexByIpNoLock` scans every vertex, not just hosts). Diagnose before touching the test: deleting a good test is the expensive mistake.

**A surviving mutant is not a finding until you show it changed anything.** 2026-08-21, a
reviewing session reported "3 mutants survived" against the topology-reader equivalence gate
and then retracted all three: two were equivalent (the model stores both directions, so
swapping or deleting one is erased by normalisation) and **one mutation had simply not taken
effect** — the sed matched nothing. They only saw it after adding a step that made each
mutation prove it had altered the derived output. 🔑 **Mutate, then assert the mutation is
real, then run.** Without that middle step a broken harness reads exactly like a well-tested
one — the same shape as the `grep -v "("` bug above, from the other direction.

**A mutation that reddens everything proves nothing about any one test.** Two of the delegated TFM tests were killed *only* by a mutation that tripped the loader's own precondition (`switch dpid 1 has an empty "ip" array` — an uncaught exception, which gtest counts as one failure per test). Neither test's own assertions had ever been exercised. Fixing that needs a mutation that leaves the shared fixture guard satisfied: `ASSERT_EQ(n, 138)` in every test means "drop a vertex" reddens all of them, while "keep the vertex, retype it" isolates the one assertion under test.

**Run the whole suite per mutant, never a hand-picked filter.** 2026-08-12: my harness ran
`--gtest_filter=<the tests I expected to catch this>` for each mutant and reported 4 of 11 as
NO-FAILURE. Re-running with no filter killed all four — restoring the `stoull` in
`updateSwitches` *was* caught, by a test in the same suite that my filter excluded. A filter
scores the mutant against my theory of which test matters, which is exactly the thing under
test. The build dominates the runtime anyway; the filter bought nothing and cost a wrong verdict.

**Widening a catch changes which mutants your tests can kill.** In the same run, "restore the
throwing parse" stopped being killed by the `EXPECT_NO_THROW` tests, because the widened
`catch (std::exception)` swallowed it. The damage had moved: the exception no longer kills the
process, it makes the handler `return` and silently discard every entry after the bad one. That
needed a different assertion shape — "one bad entry does not cost the entries after it" — which
I only wrote because the mutation run said the no-throw tests had stopped biting. When a fix has
both a guard and a backstop, test the guard's *granularity*, not just the absence of the throw.

**How to apply:** make this the acceptance gate for delegated test-writing, stated in the delegation prompt, not a review step afterwards — an agent that has to produce the mutation table cannot hand back tests it never ran. Two structural traps to name explicitly: run gtest binaries **directly as well as under `ctest`** (ctest gives each test its own process, so it structurally cannot see cross-test interference), and treat SKIPPED as FAIL. Related: [[live-runs-find-what-tests-cannot]] — that covers the complementary gap, where the bug is only reachable by running the real stack.

## `__pycache__` 會讓「等長」的 Python mutant 根本不執行（2026-08-13）

子 agent 在跑 mutation 時遇到 3 個「存活的 mutant」，全部是**測量誤差**：
`"<I"` → `"!I"` 這種改動**保持檔案位元組長度不變**，而還原與再 mutate 落在同一秒內，
於是 `.pyc` 的 (mtime, size) 驗證通過 → **直譯器用快取、磁碟上的 mutant 從未被執行**，
看起來跟「測試太弱」一模一樣。它讀出 pyc 標頭裡的 mtime、用 `os.utime` 讓來源對齊，
證明了這個機制。

**解法**：mutation 跑測試時一律 `PYTHONDONTWRITEBYTECODE=1`，並在開跑前清掉既有 `__pycache__`。
任何用 `spec_from_file_location` 或直接 import 受測模組的 mutation 流程都會踩到。

**2026-08-17 — a survivor that named the exact gap.** Four mutants against the fix for
`updateOpenFlowTables`; three died, and M4 (removing `extractKey`'s `match` guard) survived.
The test aimed at that guard **passed**, and its comment said it covered it. Both true, about
different things: the test drove an *install* batch, and `extractKey` is only called from the
**modify and delete** branches. Re-pointed at a modify and a delete, it kills M4.

The reusable part: **a surviving mutant is not "the test is weak", it is "the test is not where
you think it is".** Read the survivor as a location claim before assuming it is a strength
claim. Nothing else in the run — six green tests, a green CI, a live measurement — could have
told me that assertion never reached the function it was named after.


## 2026-08-24：兩個「看起來很好」的測試，突變一跑就現形

同一天同一個檔，兩次。都不是寫錯，是**測到的層比想測的低一層**。

**① 測試自己餵了它要驗證傳輸的那份資料。** counter 回讀的單元測試把一個 `counters` dict 交給
renderer、斷言它活著出來——**switch 以下全測到、switch 以上完全沒測**。所以當 `read_table_entries`
**從來沒有 request** counter_data（P4Runtime 要 request 裡帶 present 的 counter_data）、live 全讀 0 的時候，
測試全綠。突變：把 wrapper 整個刪掉 → **還是全綠**。
🔑 **「測試提供了它要檢查傳輸的那份資料」＝看不見來源根本沒送。**

**② 注入的 stub 讓 default 值不可見。** 每個測試都把 `HOST_QUERY_TIMEOUT_S` 注進 namespace，
所以把模組預設改成 `0`（eventlet `Timeout(0)` 立刻觸發＝每次讀都逾時＝gate 永遠回報沒學到）
**也全綠**。補法是加一個直接讀原始碼常數的測試。
🔑 **凡是測試注入的組態值，突變模組預設一定活。要嘛測原始碼、要嘛接受那格沒覆蓋。**

兩條都是突變閘門抓的，不是 review 抓的。**沒跑突變就會把兩個裝飾性測試送進一個缺陷調查裡。**

## 🔑 08-27：**「閘門變紅」不夠——要查是「哪一個測試」紅了**

工單 R 的突變閘門。承重測試有兩條：①`batch_size=1` 與 batching 前**逐位元組相同**、
②兩台交換機**不得共用一個 datagram**。

**第一個突變**（`if self.batch_size > 1:` → `>= 1`，讓預設也走 buffer）
⇒ `FAILED (failures=1)`。**看起來閘門有效**。

🔴 **但掛掉的是「buffers nothing」那條，不是 byte-for-byte 那條。**
原因：`batch_size=1` 走 buffer 路徑之後，`_flush_one` 仍然呼叫
`build_datagram([單一樣本], ...)`——**位元組真的相同**，所以 byte-for-byte 測試正確地存活。

⇒ **我的突變測到的不是我以為的那條。** 若我只看 `FAILED` 就收工，
會以為承重測試①已驗證，而它從頭到尾沒被碰過。

**補的第三個突變**：`uptime_ms` → `uptime_ms + 1`（**只動位元組、不動控制流**）
⇒ 精確殺掉 byte-for-byte 那一條。

🔑 **審查員補的一句，把它收緊成可驗收的形式**：
> **殺到「別的測試」跟「沒殺到」一樣是失敗 —— 紅燈的數量不是證據，紅燈的身分才是。**

⇒ 這是「失敗會回報成功」家族的一個**新變種，而且特別惡毒**：
突變閘門**本來就是拿來對抗裝飾性測試的最後一道防線**，而它自己可以用同樣的方式騙人
——**紅燈是真的，只是紅在別的地方。**

🔑 **可操作**：
1. **突變要指名它要殺哪一條測試**，跑完用 `grep -E "^(FAIL|ERROR):"` 確認**是那一條**。
2. **殺不到就換突變，不要換結論**——殺不到通常代表突變改的維度不對
   （我第一個改的是**控制流**，而那條測試斷言的是**位元組**）。
3. 每個突變前 `assert old in s`（防 sed 沒生效卻回報存活），
   每次還原後**驗 sha256**——這個檔是四輪量測的參照系。

（另：`p4_proxy/venv/bin/python3 -m unittest` **可用**，記憶檔舊記的「這台機器沒 pytest」
仍然對，但 unittest 一直是可跑的。）

## 🆕 2026-08-30（`開機手冊` 的措辭，收進判準）

- **「一個只能被引用的紅，是沒人能複驗的紅。」** 證據檔（`07_fix-evidence.md`）補寫時把兩個
  mutation **重新套用、重新跑**，而不是轉抄 commit message 裡的舊輸出——順帶證明 mutation
  現在還套得上去。轉抄的紅只證明「當時有人宣稱紅過」。
- **mutation 下仍通過的測試要「刻意記錄」**：pre-fix 本來就 exit 非零、本來就指名 port，
  那兩個性質從來沒壞過 ⇒ 只驗它們的測試組會在缺陷上亮綠。閘門報告要分「因修而紅」與
  「本來就綠」兩欄，後者不算證據但要列出來，免得下一手誤讀成覆蓋。

## 🆕 08-31：**測試自己也是受測物**——我的 fixture 造不出它要測的那個失敗

要測「快照列表讀不到時，不可以印成『沒有快照』」，我拿**一個內容不是 qcow2 的文字檔**
當 fixture。結果 **`qemu-img` 把它猜成 raw 格式，而 raw 就是零個快照** ⇒ 它**讀成功、
回報空的**，正是那個閘門要抓的假陰性形狀。

⇒ **那個測試對舊的壞碼也會過。** 改用 `chmod 000` 的真 qcow2（真正的 open 失敗）才真的紅。

🔑 判準：**fixture 要先證明它造得出那個失敗**，再去問受測物有沒有擋住。
「我建了一個壞掉的 X」和「X 真的以我想的方式壞掉」是兩件事——這一次它以**另一種方式**
壞掉（被當成別的格式），而那種壞法剛好長得像正常。

## 🆕 08-31：**只能透過拒絕來觀察的東西，測不到「放行」那個方向**

`rlab` 的停用表本來只有一種觀察方式——去用它，然後被拒絕。⇒ **force-red 測得到，
force-green 測不到**：沒有辦法在不撥號的情況下確認「它會放行該放行的機器」，
而「用試的去發現」正是停止令本身禁止的事。

修法是加一個**唯讀的查詢動詞**（`rlab suspended <machine>`，不撥號就回答）。
它不只是為了測試方便——**先問再動**本來就比**做了才知道**安全。

🔑 通則：**如果一個守衛只在它拒絕的時候才會說話，那它的放行行為是沒有被測過的。**
給守衛一個「你會怎麼判斷這個？」的唯讀入口，兩個方向就都測得到。

⚠️ 順帶一個運氣：08-31 同一台機器下午暫緩、晚上解封，**force-green 是真的發生的**，
不是構造出來的 fixture。真實的狀態轉換比人造的更有說服力——但**不要等它發生**。

## 🔴 08-31：**「force 觸發了」不等於「force 測到了」——三種無效方式**

一天內同型**五次**（E／F-5 兩輪的 fixture）。判一個 force 有沒有效，**四步，第零步最便宜**：

| 現象 | 判定 |
|---|---|
| **0️⃣ 這個 force 有沒有呼叫端？** | 🔴 **零呼叫端的 force，連「抵達與否」都還沒進入討論**。**這一步是純靜態的、`grep` 就查得到**——第三種失效讀碼讀不出來，**但它有一個讀碼讀得出來的近親** |
| **該路徑根本沒呼叫那個斷言** | ✅ **回 0 是正確的**——不要為了讓表好看而硬呼叫 |
| **強制值被吸收**（套在「會變成基線的那次讀數」上 ⇒ 之後永遠沒有東西不同） | 🔴 fixture 缺陷，**看起來完全正常** |
| **更早的檢查先中止** ⇒ 那個斷言**從未被抵達** | 🔴 最難發現——**讀碼讀不出來**，中止訊息還會指向另一個守衛 |

🔴 **最嚴重的一次**：身分括號（抓「binary 在一格中途被換掉」）在兩輪都是**零覆蓋**，
而且**兩種獨立機制同時成立**（強制值把兩端變成相等＋更早的 `assert_running_arm` 先中止）。
**而我已經在那份證據上蓋了 v1.0 的章**——我接受「force 全部觸發」當證據，
**沒有問下一句：每個 force 有沒有真的抵達它宣稱要測的東西。**

🔑 **修法自己要先被當成有嫌疑的檢查對待**：第一版修法**錯得一模一樣**
（用「讀取次數 >1」當觸發，而兩輪每格讀的次數不同 ⇒ **門檻與呼叫點耦合，一邊靜靜沒觸發**）。
⇒ **寫完立刻跑一次，看它真的變紅，不要看它「應該會變紅」。**

🔑 **一張全紅的 force 表看起來比較完整，而那正是它危險的地方**——
要讓每個 force 在每條路徑上都紅，只能靠**弱化斷言**或**在不該呼叫的地方硬呼叫**，
兩者都是把儀器改成配合表格（＝[[verify-against-known-good-output]] 的「禁止湊表」）。

📌 **規矩寫下來與規矩被執行中間還有一步**：三分判準是那個代理自己寫的，
但它**沒有把判準套回自己剛交出去的那張表**——是被追問才逼出第三個實例的。
⇒ 收到「N 個 force 全紅」這種表時，**問的不是數字，是「每一個抵達了嗎」**。

## 🔴 08-31 第五種：**有到期日的 fixture**——只在真實產物「缺席」時才成立

E 的 dry-run fixture 只在 provenance **不存在**時合成期望值。**真的 binary 一 staged，G8 立刻 FAIL**
——不是碼壞了，是**那個 fixture 過期了**，而且**戳破它的是真東西的到達，不是任何檢查**。

🔑 **一個「只在真實產物缺席時才成立」的 fixture，是有到期日的 fixture**，而**到期那天正好是
它要保護的東西第一次真的存在的那天**——也就是最需要它的那一天。
⇒ 寫 fixture 時問一句：**它假設了什麼「還沒有」？那個東西什麼時候會出現？**

📌 同一輪的鏡像面：**一個沒有鑑別力的驗證，代理沒有拿它當證據。**
想用 `strings | grep <gtest 名>` 獨立驗編譯進去的常數，**兩臂都回 0**——因為那個 gtest 在
**測試 binary** 裡不在 kernel 裡。⇒ **從 artefact 本身無法獨立驗證那個常數值。**
它照實說了、沒有把 0 當成「兩臂相同」也沒有當成證據，並指出**真正的驗證是執行期觀測**
（`voluntary_ctxt_switches`）——**那正是那條被 blocking 逼出來的條款存在的理由。**
