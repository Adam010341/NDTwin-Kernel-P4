# §2.6's snippet is 1360 lines behind, and syncing it would introduce a defect

**Date:** 2026-08-28 · analysis only, nothing changed
**Question:** which copy of `intelligent_router.py` is canonical, and why "just regenerate the
snippet from the repo" is the wrong move.

## The two copies

| copy | lines | what §2.6 tells the reader to do with it |
| :--- | ---: | :--- |
| `NDTwin-Website/assets/snippet/intelligent_router.py` | **724** | paste it, then edit three parameters |
| `NDTwin-Kernel/intelligent_router.py` | **2084** | (not referenced — §4.1 clones the repo for the *kernel*) |

The gap was 588 lines on 2026-08-21 and is 1360 now. It widens on its own, because only one
side is being developed.

## Why the obvious fix is wrong

§2.6 instructs, verbatim:

> `is_mininet`: set `true` for Mininet, `false` for physical testbed.

**On the website's 724-line copy that instruction is true.** One assignment, one use:

```
 32:  is_mininet = True
278:              if is_mininet:
```

**On the repo's 2084-line copy the same instruction is false**, and the file says so itself:

```
 42:  # ⚠️ EDITING THIS LINE DOES NOTHING. `is_mininet` is unconditionally reassigned to True
 43:  # further down in this same module-level block ...
 56:  is_mininet = True   # ... SEE ABOVE, this value is discarded
602:  is_mininet = True          <- the reassignment that wins
```

⇒ **Regenerating the snippet from the repo would publish a control that does nothing, next to
an instruction telling readers to set it.** The manual is currently correct *because* the
snippet is stale. Syncing improves provenance and breaks correctness at the same time.

🔑 The general shape: **a document and its subject can drift in a direction that makes the
document more right, not less.** "The snippet is out of date" reads like a defect on its own;
it is only a defect once you check which side is wrong about what.

## Why testing cannot see this — the part that outlives `is_mininet`

§2.6 (paste) comes **before** §4.1 (clone), and the User Manual launches the controller by
bare filename — `ryu-manager intelligent_router.py`, resolved against the working directory.

⇒ **The reader runs the copy they pasted. Never the one they cloned.** The two files have the
same name, the reader is never told they differ, and nothing in the flow compares them. (The
VM-Linux page uses a third identity, `intelligent_router_static_topo.py`, by absolute path.
Three names; no statement anywhere about how they relate.)

🔑 This is the documentation form of a failure this project has already logged in code: **two
copies of a same-named file, only one of which is running.** In code it is caught by asserting
on the path in the live process's argv. There is no equivalent here, because the "process" is
a human following prose.

🔴 **And the reason it survives testing is structural, not an oversight in any given test:**

> **A test harness clones the repository. A reader pastes from the website. So the harness
> and the reader are running different files, and the harness is running the one nobody
> follows the manual to obtain.**

Every automated check of this manual — including mine — reads the repo copy. The copy that
actually determines whether a reader succeeds is the one on the website, and no test touches
it. Adding assertions to the harness cannot fix that; the harness is on the wrong side of the
split. What would fix it is removing the split: §2.6 moved after §4.1 so there is only one
file, or the launch command given by absolute path so the ambiguity cannot arise.

⇒ Generalised: **when a document tells the reader to obtain an artefact by a different route
than your tests obtain it, your tests are not testing the reader's artefact** — and no amount
of rigour inside the harness will reveal it, because the harness never holds the object under
question.

## What has to be decided first — and by whom

This is not a documentation decision. It is a question about the kernel's source:

1. **Is `is_mininet` meant to be a real knob?**
   - **Yes** → fix the repo (remove the L602 reassignment), *then* sync the snippet. The
     comment at L42–55 says removal changes physical-testbed startup timing, so this needs
     someone who knows that testbed.
   - **No** → the repo is right and §2.6 must stop telling readers to set it. That changes
     the documented procedure, not just a code block.
2. Only after (1) does "sync the snippet" have a correct answer.

⇒ **Recommended: leave both alone and route question (1) to whoever owns the physical
testbed.** Doing the sync first is the one option that is wrong under either answer.

## What I did not do

- Did not regenerate the snippet.
- Did not edit either `intelligent_router.py`.
- Did not change §2.6.

The line counts, the four `is_mininet` line numbers, and the §2.6 wording above were each
read directly today, not carried from notes.

[Co-developed with claude code -- Adam]
