---
name: mutation-harness-must-guard-its-baseline
description: "An interrupted mutation run leaves a mutant in the tree; capturing that as \"the baseline\" makes unrelated mutants look like they kill unrelated tests."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b955baee-a646-4fe6-9986-df69b65478e6
  modified: 2026-08-30T14:31:35.623Z
---

**A mutation harness must verify the baseline before mutating and verify the restore after.** On
2026-08-10 a multi-mutant Bash run was interrupted partway through. It had already patched
`bfsAllPathsToDst`'s edge check and had not yet restored, so the mutant stayed in the working
tree. The next thing I did was `cp` that file to `tfm.base.cpp` and call it the baseline. The two
mutants I ran next each appeared to kill *two* tests — their own target plus
`BfsShortestPathDoesNotUseAdminDisabledEdge`, which had nothing to do with either and was simply
already failing. I nearly reported a routing bug that did not exist.

The fix in `scratchpad/mutate.sh`: count a known invariant in the baseline file (here, six
`isUsable` call sites) and refuse to run if it is wrong; restore at the end and print a loud
warning if the restore did not take. A count is enough — it does not need to be a full diff.

**Why:** mutation testing deliberately makes the tree wrong, so any interruption leaves it wrong,
and the harness is the only thing that knows what "right" looked like. Unlike a failed edit, a
stranded mutant is silent: everything still compiles and most tests still pass.

**Restoring the source does not restore the binary.** 2026-08-12, found by the audit agent
replaying my mutants: after `git checkout HEAD -- <file>` the tree was clean, but the mutated
object was still linked into `test_routing_strategy`, so the next run measured the *mutant* while
`git status` said the tree was pristine. Every "restore verified" check I wrote looks at git, and
git cannot see the build directory. **Rebuild after every restore, and make the harness do it —
`git diff --quiet` is necessary and not sufficient.**

**The mutant that never arrived — the worst error the table can hold.** 2026-08-12, same session:
`sed -i '244s/for s in samples/…/'` matched nothing, because line 243 was blank and the loop was at
:245. **`sed` exits 0 when its line address matches no pattern**, so the chain continued, the build
compiled unchanged code, and the suite was green. Reported unchecked that is a **false NO-FAILURE**
— strictly more damaging than a false KILL, because it reads as "this test does not bite" and
invites deleting a test that works. Caught only because a `grep` was chained after the `sed`.
So the per-row invariant is six steps, not four: **assert the mutant text is on disk (abort if
absent) → rebuild → run the whole binary → restore → rebuild → assert baseline green.** The first
assertion catches the no-op mutation; the last catches the stale binary. Knowing both traps is not
enough — I described the binary one to another session and then walked into it myself ten minutes
later, which is the argument for putting both in the harness rather than in one's head.

**How to apply:** never snapshot "the baseline" from the working tree right after a mutation run —
snapshot it before the first mutant, and assert an invariant on it each time. If a mutant kills a
test it has no causal path to, suspect the baseline before suspecting the production code. Related:
[[mutation-gate-for-tests]] (why mutation is the acceptance gate at all),
[[destructive-shell-traps]] (the other way mutation runs destroy work — `git checkout`).

**2026-08-12, delegated version of the same failure — and the defence that worked.** A test-writing
subagent was killed mid-mutation by a session limit, twice. The second death left a live mutant in
`tools/p4_power_helper.py` (the `argv` required-field check deleted from `cmd_on`). Nothing was
red: the suites still passed, the tree looked ordinary. What caught it was committing the
implementation *before* delegating — a plain `git diff <commit>` named the stranded edit in one
command. So: **commit the implementation before any delegated mutation run, and diff against that
commit before trusting anything the agent hands back or before resuming it.** Tell the resumed
agent what you reverted; it may have died before capturing that row's failure and has to redo it.
Do not resume a mutation agent without checking first — its next act is to re-apply a mutation on
top of whatever it left behind.

## 🔴 08-27：同一個失敗，這次穿的是**建置系統**

mainDev 的突變 harness 用 `cp -p` 從備份還原原始碼。
**`-p` 會把原始 mtime 一起放回去，而那個時間比「用突變體編出來的 `.o`」更舊。**

⇒ **ninja 判定沒東西要重建** ⇒ **下一輪測的是突變體，而磁碟上的原始碼是乾淨的。**

🔴 **而 sha256 檢查全程通過**——因為**它驗的是檔案，不是用那個檔案建出來的產物**。

發現的方式：**restore 之後那一輪竟然是紅的**。（不是靠檢查，是靠意外。）

⇒ 🔑 **還原了原始碼 ≠ 還原了被測的東西。**
本檔原本記的是「中斷的 run 留下 mutant 被當成 baseline」——**同一個失敗的兩種載體：
一個經由中斷，一個經由建置系統的快取。**

**修法**：restore 之後 `touch`，並把「restore 後那一輪必須全綠」做成**會 exit 2 的斷言**，
不是印一行給沒人看。
相關：[[benchmark-must-name-the-binary-it-measured]]（同族：驗了檔案不等於驗了被執行的東西）

## 08-30：第三次復發——新作者、同一個坑（還原 source 未重建）

mainDev 的 A-7 變異 harness 還原 source 後未重建：全套紅 3 顆（恰是 M11 該紅的那三顆）
而 `git diff` 乾淨——**磁碟上的 `test_routing_strategy` 還是 M11 的 binary**。靠「restore
後基線必須綠」斷言自抓自修。本檔 08-12／08-27 已兩記此坑，**三個作者、三套獨立 harness、
各踩一次** ⇒ 規則寫在檔案裡擋不住，只有寫進**共用的機器可判 harness**才擋得住
（T-10 §6 附錄排的那件，優先級上調）。出口守則自此雙面：**進去守 source、出來守 artifact。**
