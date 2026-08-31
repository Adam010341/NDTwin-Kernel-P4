# Lab handoff — E round released 2026-09-01 ~07:40

Claim `e-round-sampling-ceiling` held 2026-08-31 22:48 → released here, ~2 h before its 09:37:51
expiry. **Released early on the auditor's ruling**: the round was finished and the machine restored,
and another session's mutation gate was blocked behind the claim. Document QA and lab occupancy have
no dependency on each other.

## State at release — every line checked, not assumed

| | |
|---|---|
| `ndt status` claim | released (was: yours, 120 m left, `exclusive cpu yes`) |
| `measuring` | **nothing** |
| bmv2 switches / topo session | **0 / absent** |
| fabric processes (`/proc` scan, not `pgrep -f`) | **0** |
| veth interfaces / netns | **0 / 0** |
| `ndt status` sample rate | **1/256** (production) |
| `p4_proxy/p4_src/ndtwin_switch.p4` | **git-clean**, `SAMPLE_RATE = 256` |
| kernel binary | `e3bad23cdfe4fec38bf5bf0b473ae8f4e16a9962cafab6b53c950aec3afd1b94` (production) |
| `restore_production` | ran and **verified** at 07:25:28; `production restore FAILED` appears **0** times |

The round's instrument (`ndtwin_switch.p4`, sed'd per rung between 1/1024 and 1/1) is back at the
production constant and committed-clean. Nothing this round staged remains on the machine.

## What ran

**72 cells, 07:25:28, `rc=0`.** Two legs: `bl`+`p` (48, 23:26–04:47, including one resume) and
`m`+`mp` (24, 04:50–07:25).

⚠️ **One bringup aborted** at 02:10:58 on `e_p_0016_1` (`fabric short of 10`) at 25/48. The lab was
restored, a readiness check passed at 02:18:11, and the run resumed from `cells.tsv` with `LADDER`
and `ARM_ORDER` byte-identical. **The cause was never established** — the topology's own output goes
to a tmux session that the abort's cleanup destroys (F-24). If a future round sees a bringup fail,
**capture the pane before `restore_production` runs**; nothing else recovers it.

## Two live hazards that expired with this round — check before assuming they are gone

* **F-20**: `measure.sh` clears stale servers with `pkill -f` on a fixed string, and `pkill -f`
  matches the full command line. **While this round ran, any command mentioning that string was a
  target.** That constraint ends here, but `measure.sh` is unchanged and the hazard returns for the
  next round that runs it.
* **F-17**: `ndt claim <min>` reads `NDT_EXCLUSIVE_CPU` from the environment, so **renewing from a
  shell that has not sourced `round.env` silently drops the exclusive flag** and reports success.
  This claim was deliberately **never renewed** for that reason.

## For whoever takes the lab next

* `raw/` is gitignored by design (`.gitignore:74`) — `cells.tsv`, `cell_overlap.tsv`,
  `leg1-final-analysis.txt` and the per-cell CPU records belong to the **audit-raw** ref, not trunk.
* Per-cell CPU records land in **`doc/audit/2026-08-20_sampling-rate-and-cpu/raw/`** first and are
  copied afterwards (`round.env:16-22`). That directory holds two rounds' files at once; **directory
  membership is not provenance** — use mtime plus the naming rule plus the pids inside the file.
* The baseline moved **0.75 cores in twenty minutes** during this round, driven by desktop rendering
  of the sessions running and auditing it (F-19). **It is a declared covariate, not noise**, and it
  is not stable between periods.

## Not done, deliberately

* **23 commits are unpushed.** Adam performs the push himself; the correct command is
  `git push lab trunk:work/rescue-0831` — the existing line, never a new branch, never `origin`.
* The 2×2 figure is not drawn. Its spec changed: **the batching factor is perfectly aliased with
  leg/period (F-28)**, so the four cells must not be drawn as one seamless grid.

[Co-developed with claude code -- Adam]
