# 🔴 Blocker for the "publishable grade" bar — the manual's recommended repository is not reachable

Found 2026-08-30 evening, while checking every repository the manuals tell a reader to clone.
**This one needs Adam, not the auditor**: it is a contradiction between two of his own decisions,
not a mistake by anyone.

---

## What was measured

Every `ndtwin-lab` repository the site instructs a reader to clone, checked **unauthenticated** —
the only view that answers "can a reader get this" (`memory:
local-git-refs-cannot-tell-you-what-is-public`):

| repository | unauthenticated |
|---|---|
| `NDTwin-Kernel` | ✅ public |
| **`NDTwin-Kernel-P4`** | 🔴 **404** |
| `Network-State-Recorder` | ✅ public |
| `Network-Traffic-Generator` | ✅ public |
| `Simulation-Platform-Manager` | ✅ public |
| `Energy-Saving-App` | ✅ public |
| `Traffic-Engineering-App` | ✅ public |
| `Web-GUI` | ✅ public |
| `Network-Traffic-Visualizer` | ✅ public |

Confirmed with **the operation the reader actually performs**, not only the API:

```
$ GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/ndtwin-lab/NDTwin-Kernel-P4.git HEAD
remote: Repository not found.

$ GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/ndtwin-lab/NDTwin-Kernel.git HEAD
f5db629bd5bc…        HEAD
```

🔑 The API check and the clone check are **not** the same instrument. The API can 404 for
"private" and for "never existed"; `git ls-remote` is the exact call `git clone` makes first, so
it answers the reader's question rather than a proxy for it. Both were run.

## Why it is a blocker rather than a defect

Installation Manual, Step 4.1, in bold:

> | **P4 / BMv2 as well (Section 6)** | **`ndtwin-lab/NDTwin-Kernel-P4`** |
>
> **If you are not sure, clone the P4 one.**

So the manual **recommends as the default** the one repository a reader cannot obtain. And it is
not an optional path: Section 6 — the whole P4/BMv2 half, including §6.7, which is being verified
tonight — has no other source. `NDTwin-Kernel` is explicitly documented as **not** containing the
P4 files.

⇒ At the bar set this evening — *"tested to a publicly-releasable standard"* — a reader following
the manual's own recommendation stops at Step 4.1 with `Repository not found.`

## This is a collision between two decisions, both deliberate

* The kernel repository was **made private on Adam's ruling**, with public status to be
  reconsidered after review.
* The manual line was raised tonight to **publishable grade**.

Both are current. Nothing is broken and nobody made a mistake; the two simply cannot both hold
while Step 4.1 reads as it does.

**Three ways out, all Adam's to pick:**

1. **Make `NDTwin-Kernel-P4` public** before the manual is published. Restores the manual as
   written; reverses the earlier ruling.
2. **Keep it private and say so in the manual** — Step 4.1 states that the P4 repository is not
   yet public and how to request access. Honest, and leaves Section 6 unfollowable for an
   outside reader.
3. **Keep it private and do not publish** the manual line yet. Consistent with the existing
   ruling; defers the new bar.

Doing nothing selects (2) by accident, without the sentence that would make it honest.

## What this does **not** affect

* Nothing measured tonight or in T-4 depends on it. All work uses the local checkout.
* The eight other repositories are reachable, so every other Tools page's clone step is fine as
  written.
* §6.7's verification is unaffected — it builds BMv2 from **p4lang's** public repository, not
  from ours.

## Method note worth keeping

This was found by checking **all nine** repositories rather than the one that happened to be
under the cursor. Eight passes and one failure is a result; had I checked only the repository I
was working on, the failure would have looked like a local accident instead of a publication
blocker.

[Co-developed with claude code -- Adam]
