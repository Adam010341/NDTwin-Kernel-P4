# Re-review of the settled() fix at 75b5dd0e

I worked read-only. I did not read the investigation report, the rulings file, git history, or any of the three 2026-10-02 rounds.

## Verdict: MERGE AFTER FIXES. The fixes are README-only.

- **The code at 75b5dd0e is correct and meets the amendment bar.** That covers EE, TS and MG, and no code change is required.
- **What blocks the fresh run:** the pre-registration record. It still says no live data exists, and it does not register the 10-02 run or this amendment (F1–F3 below).
- **No gate rerun is needed for those fixes.** No script or test reads `live-p1/README.md` beyond a docstring mention. I established that in round 6 and re-checked it this round.

## Q1. Is the rule correct, and derived only from pre-existing data? Yes

**real.txt against the raw data.** I read all 12 cited rounds in the main checkout's `runs/`, and real.txt matches them verbatim.
- real.txt is TS:373-617. It has 24 `@@` sections, one log and one iperf section per round, all dated 2026-09-*. These are exactly the 12 p4runtime/solution rows of `external_survey_34.tsv:17-28`.
- **Log tails:** `:54-65` for the four 09-19 rounds and `:114-125` for the other eight. Each is the file's last lines.
- **iperf_client lines:** `:6,9,10`, plus `:11,12` where the round was acked.
- **Pings:** each cited .md line reads "5 packets transmitted" (grep).
- Nothing from 2026-10-02 is in real.txt or in MG's `R3504` list. TS mentions 10-02 only to exclude it.

**What the frozen data show.**
- **The six 3504 rounds:** s1 bytes are 4,346,248 = 5×98 + 3499×1242 exactly, and every acked client and server file says `0/3499`. So the wire carried D datagrams, and the first FIN is inside D: the server answered, so a FIN reached it.
- **081205Z:** s1 = 3505 with 4,347,490 bytes, i.e. 3500 datagrams, and tunnel 200 shows 7 packets against the usual 6. That is two FINs and two server reports, so the retransmission is shown by the data.
- **175425Z:** s1 = 3820, which is 316 datagrams more than the server's 3499, and s2e − s1 = +1 in each of its last four blocks.
- **The four 09-19 rounds:** forwarding broken (s1 = 3), and "did not receive ack ... after 10 tries".

**No parameter of the rule could have been set from 10-02 data.**
- The low bound is forced by the frozen byte counts.
- The ack condition comes from the frozen iperf output.
- s2e == s1 holds in 7 of the 8 acked final blocks.
- +10 is a constant that already existed (`IPERF_FIN_RETRIES`).
- The rule was evaluated on the 10-02 rounds only after it was committed. The EE sha256 `69bccf77…` is identical at d08713cc and 75b5dd0e (mutate logs :145). settled15 ran at 13:51:19Z on 75b5dd0e and printed only "settled" ×3 (`settled15.extb9-75b5dd0e.log:17-19`, script `extb9/settled15.py:20-23`). Since C1, C2 and T all gave the same result, it carries no information that tells them apart.

**Caveats. None of these blocks.**
- **(a) The high bound is probably one too loose.** Because the first FIN is inside D, an acked run with a 10-try limit can show at most +9.
- **(b) Any datagram loss reads as "under the low bound: a read taken mid-traffic".** The lost count is parsed and then thrown away (EE:181, :319). This is fail-safe, but the message would mislead an investigation.
- **(c) The descriptive invariant still uses Sent** (EE:437-443), so it reads "broken" in every normal round. This was deliberate, to keep the survey stable, and it is not counted. It should still be stated where people will read it.
- **(d) The docstring says 175425Z was "read mid-traffic" (EE:360).** That is an interpretation, not something the data show. The round is unreadable either way (s2e ≠ s1, and over the high bound).
- **(e) The D = 0 branch (iperf target not 10.0.2.2) has no cell and no mutant.** It is UNTESTED.

## Q2. Does it meet the bar? Yes, except for the README record (F1)

- **The reason cites only pre-existing data:** EE:355-363, TS:367-372, MG `R3504`.
- **The rule is fixed before the fresh run:** by the 75b5dd0e commit and EE's sha. But README:681 still says "C1、C2、T 都沒跑過", which is now false. README:684 itself requires any change to be recorded before the next live run, with its reason.
- **The low-bound loosening is a correction justified independently of 10-02:** the byte counts and server totals of 6 frozen rounds. It is disclosed.
- **The +10:** the mechanism is justified by 081205Z, but the size is inferred, and it is disclosed as inferred. It only loosens the high side, and a mid-traffic read lies below the low bound, so it cannot settle one. I recommend keeping +10 rather than changing the reader now: t_top pins 3514, so a change means rerunning TS and MG.
- **"Tighter" is narrower than described.** For the explicit no-ack warning case, the old code already settled only on a repeat: its expected_s1_in returned a range, so only `before == last` could pass. What is new is only "no Server Report and no warning" plus s2e == s1. Neither is load-bearing on the frozen rounds, and both fail safe.

## Q3. Do the red runs support the claims? Yes

- **Old EE (redfirst_b9):** 21 FAILED lines, at :146, 149, 171, 173, 176, 179, 181, 185, 188, 192, 194, 197, 200, 203, 206, 209, 214, 217, 220, 223, 226; rc 1 at :287-289.
  - The six 3504 rounds are red at :194–209, and t_lost at :146.
  - 081205Z is green on the old EE, as claimed.
  - 175425Z is rc 2 on the old EE too; only its reason check is red (:214).
- **Mutants:** E96–E106 are each caught (:106-116). E21 is caught (:31) and E41 (:51). The gate reports 134/0 (:146) and 232/232 (:147).
- **The E21 episode:** the d08713cc logs show "SURVIVED E21" (:31), 231/232 and "NEVER RED #147" (:146-148), and the driver line reads "GATES-extb9 d08713cc: RED". Those logs are kept but not counted, and EE did not change across the amend.

## Q4. Do other gates need rerunning? Not for the live run

- Only `external_survey.py:32` imports EE. TS:38 runs it, and MG copies it and runs it through TS. All of these were rerun, plus the anchor check.
- Every other mention is a comment: 08_heartbeat.sh:50,62,879,885,2501; 06_thirteen.sh:94,97; code_identity.py:40; test_live_p1_thirteen.sh:114; ndt:2986.
- The survey output body is identical between extb6m and extb9 (I compared both logs).
- **Before a PASS push:** redfirst_b, b2, b3, b5 and b6 run the changed TS against older tools and were not rerun (UNTESTED). By inspection they check named red cells, and t_lost's renamed cell is not referenced anywhere in extb6/aeg, so they are likely still green.

## Q5. Does the README need changes for the fresh run? Yes

- **F1.** Add a round-8 entry and correct README:681-684. It should record:
  - the 10-02 run (B_SHA 9b5c0607), which stopped at rc 2 at C1 p4runtime/solution with no decision field printed;
  - Adam's ruling: a fresh run, and the 10-02 data is never compared;
  - the amendment: 75b5dd0e, EE sha256 69bccf77…, the frozen-data reason, the loosening and the tightening;
  - the settled15 check on the 10-02 rounds.
- **F2. Exclude the 10-02 raw directories from the fresh run explicitly.** The code identity cannot tell 10-02 controls from fresh ones if trunk and the binaries have not moved: verify() and the controls check do not use `recorded_at`. Also README:541 and :631 ("沿用") can be read as general permission to reuse controls. Make the recovery rule at :472-473 accept only raw directories newer than a START stamp written to `$V` at step 0.
- **F3. Register what happens if the fresh compare hits another reader defect.** The obvious outcome is the 10-02 precedent: report it, and do not re-compare under a changed reader. Adam may rule otherwise, but an outcome should be written down before the run.

## Q6. Fix list

**Blocking:** F1–F3, all README text.

**Not blocking:**
- **N1.** Keep +10 with an expanded disclosure (Q1 caveat a).
- **N2.** compare stops at the first Unreadable (EE:782-788). An unreadable arm therefore hides the DAEMON/0x88B5 immediate-fail evidence of every later arm and run. The one registered rerun usually reaches it; if the rerun is unreadable too, that evidence is never looked at. Make unreadability per-arm in a later round.
- **N3.** Name the lost count in the "under the low bound" message.
- **N4.** Note the descriptive Sent-based invariant (caveat c) in the README.
- **N5.** Pin EE's sha256 at step 0 and record it at step 5.
- **N6.** The survey manifest does not hash iperf_client.txt, which the rule now reads. real.txt keeps a verbatim copy, but nothing checks that copy against the raw files.
- **Expected rate:** 1 of the 8 acked frozen rounds stays unreadable. That gives roughly a 1-in-3 chance that some run of the three needs its one registered rerun.
- **Scheduling:** if trunk has moved past B's base, step 0 will STOP and a trunk merge plus a gate rerun is needed. Check this before committing F1–F3.

## Claims, classified

| Claim | Status |
|---|---|
| Only EE, TS and MG changed | SUPPORTED (patch headers 1/150/232) |
| real.txt is verbatim and contains no 10-02 data | SUPPORTED (all 12 rounds read against raw) |
| 21 red on the old EE, E96–E106 caught, the E21 episode | SUPPORTED |
| Counts 202→232 and 123→134 | SUPPORTED (+30 cells, +11 mutants) |
| Survey unchanged | SUPPORTED |
| No other gate needs rerunning | SUPPORTED for the live run; UNDER-EVIDENCED for the push (red-first gates) |
| "Matches the investigator's proposed.out" | UNDER-EVIDENCED (I did not read it, by rule) |
| "README unchanged; 判定 never described settled()" | SUPPORTED |
| README needs no change | CONTRADICTED by README:681 |
| "Sent counts one extra" | The wire count is SUPPORTED by bytes; the iperf mechanism is UNTESTED (disclosed) |
| +10 slack | UNDER-EVIDENCED (disclosed as inferred) |
| "Main checkout untouched" | UNDER-EVIDENCED (the worker's statement only) |

## Tests I would have run

1. **A check, printing only pass or fail per stage, of the compare stages that have never run on live data:** programs_same, read_samples, and check_roles with the heard window. The 10-02 compare passed identities and then stopped inside arms(C1). On 10-02 data this needs Adam's or the orchestrator's OK. It would catch a second latent reader defect before it costs the one fresh run.
2. **A real-data cell for the skeleton's settled rule.** It is currently supported only by the survey's invariant row (survey_34:19).
3. **A cell for the target ≠ 10.0.2.2 branch.**
4. **Read iperf 2.1.9's FIN retry count** from its source, to decide between +9 and +10.

## Key paths

- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/external_evidence.py (settled() at :341-400)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/tests/shell/test_live_p1_external_evidence.sh (real.txt at :373-617)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/README.md (:472-473, :541, :631, :681-686)
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_b9.extb9-75b5dd0e.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_live_p1_external_evidence.extb9-75b5dd0e.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_live_p1_external_evidence.extb9-d08713cc.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/settled15.extb9-75b5dd0e.log
