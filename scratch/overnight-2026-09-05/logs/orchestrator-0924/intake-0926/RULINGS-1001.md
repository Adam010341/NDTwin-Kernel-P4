# Adam rulings 2026-10-01 (morning, session 6f189e52)

Asked by Adam: (1) should subagents move to Sonnet 5.5 xhigh/max; (2) professor wants a top-level P4 app
that finds what NDTwin still cannot support (after the in-flight work); (3) plain-language to-do list, grill
on technical details.

## Form 1 answers
1. Subagent model: "混用，先試兩件" — judges and kernel/proxy/test workers stay Opus/Fable; mechanical work to
   Sonnet 5.5; trial on 2 tasks, compare judge findings and rework before widening.
   Then mid-turn: "sonnet 5.5 vs opus 5.5 誰要當 subagent 這個問題你可以先上網查查看資料" -> research done,
   re-asked in form 2 (see below).
2. Professor's P4 app: "健檢組合" — a test P4 program that uses every feature + a probe app on NDTwin that
   brings up a fabric and tries each dimension, printing a red/green table (automated GAP-2b). My proposal:
   build it right after the in-flight work, before the other P4 gap fixes, so each fix flips a red cell.
3. Custom-header flow identity: not ruled. Adam asked three things:
   (a) analyse the success rate of auto-deriving the layout from the P4 program -> opus worker dispatched,
       scratchpad `parser-autoderive/REPORT.md` (copy here when delivered);
   (b) what "non-IPv4 only goes to the side table" means -> answered in chat;
   (c) does "hints" mean users annotate headers themselves, once per program, and is that hard -> answered.
4. Rule-writing line, next cut: "遮罩／範圍比對＋記帳本" — ternary/range/optional + priority in the generic
   writer, plus a journal so entries survive a proxy restart.

## Mid-turn instruction
- "opus 5.5 的 subagent 的 effort 改成 high": done in ~/.claude/agents/opus-worker.md (xhigh -> high) and
  opus-judge.md (max -> high). fable-judge (Fable, max) untouched. Judge effort re-asked in form 2 because the
  CodeRabbit data shows Opus max catching more bugs than Opus standard (10/13 vs 8/13, 13 cases).

## Form 2 (after the web research)
Research (primary: anthropic.com/claude-sonnet-5-5, platform docs optimizing-for-cost-and-intelligence,
code.claude.com model-config; third party: CodeRabbit 13-case review benchmark):
- Sonnet 5.5 trails Opus 5.5 by a few points on most benchmarks, beats it on Terminal-Bench 4.0 (70.6 vs 66.4),
  and at max still trails on FrontierCode 1.1 (46.2 vs 54.4).
- "Up to 30% less per task" is against Sonnet 5, not against Opus 5.5.
- Cost doc: on work one model can do alone, the same model at lower effort was cheaper every time measured.
- Claude Code docs: high = "work where verification matters or edge cases are likely, such as fixing a bug";
  max is prone to overthinking.
- CodeRabbit (13 hard cases): Sonnet 5.5 6/13, Opus 5.5 standard 8/13, Opus 5.5 max 10/13.

1. "Opus high＋Sonnet high 試雜活": workers Opus 5.5 high; Sonnet 5.5 high (new ~/.claude/agents/sonnet-worker.md)
   for two trial tasks: (i) classify the 42 L1 no-build failures of the residue fix against trunk 3368412d,
   (ii) the next PR's CI-log comparison. Judges never Sonnet. Report judge findings and rework after the trial.
   CLAUDE.md "subagent 明寫 opus" left unchanged until the trial is decided.
2. "判官改回 max": opus-judge effort max again; opus-worker stays high.

## Form 3 (after the auto-derive analysis, parser-autoderive/REPORT.md)
Data: 15 programs; real sampled frames 72,213 (71,966 with IP): today's native 71,943, program parser alone 68,085,
native first + program-parser fallback 71,966/71,966, native + 3 hint lines 71,966/71,966. The gap is 23 frames on
3 paths (basic_tunnel / p4runtime 0x1212 tunnel, source_routing stack). Path level 18/27 IP paths from bytes alone,
27/27 with the sample's input port (the 9 others select on ingress_port; 8 are ndtwin_switch CPU-only paths).
Main risk (inferred): an INT shim between IPv4 and L4 makes today's ihl*4 port read silently wrong.
1. Custom-header flows: "啟動前自動產生說明" — native parse first; for what it cannot read, hints generated at
   pre-flight from the program's compiled JSON on every bring-up (the Python prototype's job), user may override;
   the kernel only interprets hints (no C++ parser interpreter); what hints cannot express is reported in
   switch_state and stays in the side table.
2. Download int-v1: approved and done -> /home/adam/paper-apps/int-v1 (github.com/niloysh/int-v1, MIT, commit 84a3ebe8,
   672 KB on disk). INT-shim test sent to the analysis worker (read/compile only).
3. Two IP layers: "外層，維持現狀" — flow identity stays the outer IP (what the switches forward on).

## INT follow-up (parser-autoderive/REPORT-int-v1.md)
int-v1 @84a3ebe8 compiles unpatched; its INT shim sits AFTER TCP/UDP (DSCP 0x17 signals it; parser.p4:36-70,
deparser :96-116), so the 5-tuple stays at bytes 14-42: native-model, p4pi as-is and p4pi with l4_program_offset all
correct on 9/9 frames. PAPER-APPS-CANDIDATES §3 ("between IPv4 and UDP") is wrong for this code. Only the deliberate
control (shim between IP and UDP) misreads silently in all three. This commit has no transit/sink; the 1/2/4-hop and
sink-stripped frames were hypothetical (INT v1.0 format). Wire layout inferred from code, no bmv2/pcap run.

## Form 4 (handover from the 9/25 orchestrator: PR #18 and ndt serve GUI v2)
1. PR #18 README trim: "公開" -> squashed a7ff42ab (no trailers), trunk da10d3a3 pushed to both repos, ndtwin-lab
   main ff to a7ff42ab; unauthenticated ls-remote both repos main a7ff42ab / trunk da10d3a3 (push-pr18-1001.log).
2. GUI v2 delivery 2 adds browser claim cases: "要加" (start with Up/Down with no claim row + foreign-claim-only mutant).
3. Built bundle (~290 KB) and lockfile (2,914 lines) committed: "兩個都進 repo".
   Sent to the ndt serve session with the round-1 judge report (FIX; HIGH = Q6 60 s automatic probe not implemented).

## Form 5 (afternoon): Sonnet trial result
Trial: (i) L1 classification 42/42 BOTH, no rework; it caught and killed an accidental C++ build my command caused under gawk.
(ii) PR #19 CI compare: every cited line verified by me; honest NOT FOUND where the runner hides per-check lines. ~76k tokens vs ~300k for
Opus on comparable tasks. No judge was involved, so "judge findings" is untested.
Adam: "正式採用" -> mechanical work with a known answer goes to Sonnet 5.5 (sonnet-worker) by default, I spot-check key lines; reviews,
code, tests on Opus, hard rulings on Fable, judges never Sonnet. CLAUDE.md §委派 changed on trunk 64c89e1c, PR #20 (38a03eb2).

## Form 6 — GUI v2 round 2 (2026-10-01, after the r2 review)

Review: judge-NDTSERVE-GUI-V2-r2-189e89a0.md (MERGE AFTER FIXES). Corrected facts given to Adam before he ruled:
- the 221 processes / 7 sudo per probe were measured on an idle lab (no fabric, kernel closed), where the probe never runs;
- while measuring, each probe also sends one get_graph_data GET to the kernel under measurement, unmeasured;
- a full tick is 9 sudo (status 7 + apps status 2), about 49 a minute, not 38;
- the Web-GUI 0.0.0.0:3000 / no-CSP sentence has been public on both repos' audit-raw since 09-28
  (RULINGS-0927-ndtserve-gui-v2.md in 5cf0364c, checked by unauthenticated raw URL, 200 on both),
  and Web-GUI's public docker-compose publishes 3000:3000.

Rulings:
1. Probe cost: **measure first, then rule.** ndt serve measures the untraced `ndt status` in the measuring state
   (P4 4 hosts, kernel up, measuring declared, iperf3 running): /proc/stat process delta, a sudo logging shim
   (strace drops setuid, so a traced sudo fails), the kernel GET timing, one full tick. Lighter-probe and
   accept-as-is remain the options once the figures are in.
2. The Web-GUI sentence: **a public fact.** Normal --no-ff merge, no branch history rewrite, audit-raw untouched.
   The SUMMARY's pointer to 0d7f6ce8 is still trimmed.

Sent to ndt serve: the fix list that needs no ruling (Down-half and apps claim-first mutants, the sudo
arithmetic, provenance headers, G-N7 provenance, SUMMARY claims, nits) and the measurement brief.

## Form 7 — the probe, on measured figures (2026-10-01 ~17:2x)

Measured by ndt serve (logs/ndt-serve-gui-v2/live-probe-cost/RESULTS.md; Adam authorised that one lab use in its session):
one probe while measuring = plain `ndt status`, 564 tasks (524–595), 6 sudo, 1.58 s, plus one get_graph_data GET of about 6 ms
(a concurrent northbound read waits up to about 6 ms more). Idle: 448 tasks, 8 sudo. The old strace figures (221 / 7) were wrong:
under ptrace every sudo failed and nothing on the root side ran.

Ruling: **lighter probe.** The probe reads only whether anyone is measuring (the claim's measuring= declaration and the process
table), with no sudo and no kernel request. Cost accepted: an ndt change, serve change, full gate rerun, anchors shift once.

Also 2026-10-01: Adam agreed to fold ndt serve into the orchestrator session — GUI v2 work now runs as workers here.

## Form 8 — B live comparison authorised (2026-10-02 12:47)

Adam, in this (10/2 orchestrator) session: "授權 B live". Scope as I described it before he answered: the B live comparison
(procedure (a) in live-p1/README, C1 + C2 controls on trunk, T from a local unpushed merge, then H1–H4 under the merge), using the lab
for about one to two hours; claim with its own NDT_OWNER first; trunk commits, merges and pushes frozen for the window; afterwards
tear down, verify restored (ndt down / clean / apps orphans / status vs before), release. It starts only after round 6 passes
re-review. One run of the pre-registered procedure (its own one T rerun included); anything beyond that needs Adam again.

### Form 8 addendum (2026-10-02 19:2x)
Adam, replying to my note that any rerun path would take the run past the one-to-two-hour window: "超過沒關係". The time window is
lifted. The rest of form 8 stands: one run of the pre-registered procedure, following its own registered branches (the one T rerun,
C3/C4, the one redo on rc 3); every outcome the README sends to "回報 Adam" still comes to Adam; nothing outside the README.

## Form 9 — B after the UNREADABLE compare (2026-10-02 21:2x)
Question: the reader's "settled" rule is wrong (expects iperf "Sent" 3500 on the wire; 3499 go out; 11 of 12 frozen rounds read
UNREADABLE under it; nothing changed today). The fix (reader only, proven on the frozen rounds, re-reviewed) is under way; how to
get B's verdict after it?
Adam: **"修好後重跑一次 live (Recommended)"**. Scope as described in the option: the fixed rule is committed and re-reviewed first,
then one fresh run of the full procedure (C1, C2, T, compare; about 1.7 h of lab; trunk frozen as before), under form 8's terms
(own NDT_OWNER, teardown and verify, its registered branches, "回報 Adam" outcomes come to Adam; time window lifted). Today's
compare is not re-run with the fixed reader; today's raw stays as raw.
