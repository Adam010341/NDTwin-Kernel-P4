# Orchestrator review of the ndt serve GUI scope draft (feat/ndt-serve-gui-0927 @ bfffefa0), 2026-09-27

Reviewed: `scratch/overnight-2026-09-05/wt-ndt-serve-gui-0927/doc/audit/2026-09-27_ndt-serve-gui/SCOPE.md` (174 lines).
Basis: Adam's 09-27 13:2x ruling H (serve its own page; token via a one-time URL `#fragment`, memory only).
Engineering rulings below are the orchestrator's; each can be overturned by Adam.

## Verdict: scope APPROVED with the changes below; code may start.

| §8 # | question | ruling | why |
|---|---|---|---|
| 1 | nonce vs long-lived token in the fragment | **one-time nonce exchanged for the token** | this is the precise form of Adam's "one-time URL": a history/autocomplete record of the URL is worthless once used; the long-lived token never appears in any URL |
| 2 | UI language | **English labels for this cut** | ndt's own output (shown verbatim) is English and the repo is public; mixed-language screens read worse; labels are cheap to change if Adam prefers Chinese |
| 3 | disable confirm when the claim is not yours | **yes**, with "claim first" | UI guard only, ndt/server still decide (rc 5, claim precheck) |
| 4 | dry_run argv preview | **yes** | argv built only in verbs.py |
| 5 | confirm-dialog click behaviour | **browser run + screenshots this cut, reported in a separate "ran (browser)" column**; DevTools-protocol automation next cut, stdlib only | honest split between unit-tested and hand-run |
| 6 | auto refresh | **manual only in this cut** (NOT the 30 s poll) | a 30 s `ndt status` poll is an invisible load source during live measurements (memory: 隱形負載源); if added later it must stop whenever `measuring` is not `nothing` and be off by default |

## Additional requirements
- **CI**: the page-side tests need google-chrome, which CI lacks. They must SKIP with an explicit reason when Chrome is absent, and the L1 lane's problem-group count on the merged tree must not rise above trunk's (12 on b005bf50). Show the lane's own reading of the new suites with Chrome absent.
- **Laptop memory**: headless Chrome runs only inside the guard (`JOBS=1 LOCK_WAIT=10800 guarded_build.sh`), one instance at a time, disposable profile, zero leftover processes asserted (by its own pid, never `pkill -f`).
- **`ndt serve url`** reads the 0600 token file: tests must use a temp HOME, never Adam's `~/.config/ndt-serve/token`.
- **Browser-pane runs** (item 5) use the stub server on localhost with test tokens only.
- **§2 measuring rule**: "measuring is not `nothing` ⇒ typed confirm" is kept; also show the measuring line in the dialog even when it is `nothing`.
- Delivery as stated: branch only, no merge/push; the orchestrator does intake (diff, scan, rerun, judge).

[Co-developed with claude code -- Adam]
