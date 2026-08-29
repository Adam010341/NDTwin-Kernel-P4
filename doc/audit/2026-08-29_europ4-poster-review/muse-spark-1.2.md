# EuroP4'26 Poster Abstract Hostile Review — /home/adam/Desktop/NDTwin-Kernel/doc/2026-08-29_europ4-poster-abstract

**Reviewer stance:** hostile PC member, 2-page poster abstract genre. Separate OBSERVED (file:line) from INFERRED. No praise padding. Line numbers refer to `abstract.tex` unless noted.

---

## (1) DE-AI / ACADEMIC TONE — Sentence-by-Sentence

### Method
- Grep for prescribed LLM-tells across `abstract.tex`: pattern `delve|robust|crucial|leverage|underscore|important to note|comprehensive|seamless|pivotal|shed light|in the realm|navigate the landscape` → **0 hits** in `abstract.tex` (verified via `default.grep` on 2026-08-29 snapshot). INFERRED: draft avoids the most detectable LLM ornament.
- Hedgingscan: `may potentially|might suggest|could potentially` → 0 hits.
- Remaining audit is manual: does sentence survive 50% deletion? Does adjective carry measurement? Is voice active? Is tricolon/filler present?

### Verdict
OBSERVED: draft is unusually dense and self-disciplined vs typical LLM poster. The LLM-risk is not buzzwords but **over-explanation of preregistration discipline and defensive hedging that exhausts a poster's attention budget**. The title is the only slightly cute/phoric element; the rest is systems-conference register already, but too long for a poster.

### Table: LINE / ORIGINAL / REWRITE

| LINE | ORIGINAL (verbatim) | REWRITE (tighter, active, no empty adjective) | FLAG |
|------|---------------------|-----------------------------------------------|------|
| 15 | `\title{Mind the Build: Why Published BMv2 Throughput Figures Cannot Be Compared}` | `Build Flags Explain 8× of BMv2 Throughput Spread` (or keep if you want provocation, but colon-title costs 7 words for 0 bits) | INFERRED: pun title is poster-OK but buries the quantitative claim; EuroP4/SOSR prefers result in title. Not an LLM tell. |
| 26-27 | `The software P4 switch bmv2 anchors much of the P4 research pipeline, and papers routinely report its forwarding performance in Mbps.` | `Papers routinely report bmv2 forwarding in Mbps.` | OBSERVED `abstract.tex:26-27` — “anchors much of the research pipeline” = metaphor with no number; survives deletion. |
| 28-31 | `We surveyed 18 papers that measure or relay bmv2 throughput: reported figures span ${\sim}2{,}500\times$ (0.57\,Mbps to 1.4\,Gbps), none reports build flags or provides enough information to reconstruct the binary, and two peer-reviewed papers order bmv2 versus Open vSwitch in opposite directions.` | `We surveyed 18 papers reporting bmv2 throughput: 2,500× spread (0.57 Mbps to 1.4 Gbps); 0/18 report build flags; 2 papers order bmv2 vs. OvS oppositely.` | OBSERVED `abstract.tex:28-31` — original is 47 words, carries 4 facts; rewrite is 22 words, same 4 facts. No LLM tell, but hedge-free and dense already. Flag is length, not tone. |
| 31-44 | `We then quantified, under preregistered protocols on one machine, three variables that no surveyed paper isolates. (1)~\emph{Build:} ... (2)~\emph{Unit:} ... (3)~\emph{Flows:} ... In two of our three experiments, our own instrument's limit nearly became the reported number; none of the 18 papers states what limited its measurement.` | `On one machine, preregistered, we isolate three unreported variables: (1) Build: recommended vs. default = 12× (3-hop, UDP zero-loss), 8.0× single-hop (45 vs 360 Mbps, q-interval 5.14–12.0). (2) Unit: 64/256/1024 B frames → pps varies 1.25×, Mbps varies 16.0×; Mbps without frame size is a 16× ambiguity. (3) Flows: per-flow clean rate falls monotonically with n (replicated); OvS does not (matched points, earlier run). Instrument ceiling censored 2/3 experiments; 0/18 papers report a limit.` | OBSERVED `abstract.tex:31-44` — abstract paragraph is 110 words; survives cut to ~60. Not filler, but poster abstract must front-load numbers. “preregistered protocols on one machine” buries the scope limiter at clause end. |
| 50 | `\section{A 2,500$\times$ spread nobody can arbitrate}` | `\section{2,500× Spread: No Two Papers Measure the Same Binary}` | INFERRED: original heading is editorializing; rewrite states the evidentiary claim. |
| 52-55 | `Of 18 surveyed papers that measure or relay bmv2 performance, 12 measure it directly. Among those twelve: \textbf{0/12} report compiler flags or optimisation level, \textbf{0/12} run any build comparison, 3/12 name the variant (all one lab's lineage), 1/12 names a version.` | `12/18 measure bmv2 directly: 0/12 report flags or optimization, 0/12 compare builds, 3/12 name variant (one lab), 1/12 names version.` | OBSERVED `abstract.tex:52-55` — tight already; only cut “Among those twelve:” scaffolding. No tell. |
| 56-58 | `Their throughput figures span ${\sim}2{,}500\times$, from 0.57\,Mbps at 64\,B \cite{hasnaa2023tssa} to 1.4\,Gbps on physical NICs \cite{kumazoe2023icncc}.` | `Reported throughput: 2,500× (0.57 Mbps at 64 B [Hasnaa23] to 1.4 Gbps on NICs [Kumazoe23]).` | No fill. Keep. |
| 58-61 | `With the information the papers themselves provide, no two of these numbers can be shown to measure the same artifact. We say \emph{mutually incomparable} deliberately --- we did not attempt reproductions, so we claim nothing about reproducibility.` | `Given reported info, no two numbers demonstrably measure the same binary. “Mutually incomparable” ≠ “irreproducible”; we did not reproduce.` | OBSERVED `abstract.tex:58-61` — defensive clause is required per `NOTES.md:29` red line. Poster can compress to footnote. Not LLM filler, but verbose for poster wall. |
| 63-69 | `The consequence is concrete: one line of work measures Open vSwitch two orders of magnitude above bmv2 \cite{chen2025tomacs,chen2023pads}, while another concludes the P4 pipeline outperforms OvS \cite{fernando2025network} (a reactive-control-plane effect, per its own analysis) --- and a reader cannot arbitrate, because neither reports its build; even one lab's adjacent papers differ $1.7\times$ per switch with no build stated \cite{waind2024pads,waind2026pads}.` | `Consequence: one lineage reports OvS ≫ bmv2 by 100× [Chen23/25]; another reports P4 > OvS [Fernando25]; reader cannot arbitrate — neither reports build. Even one lab's adjacent papers differ 1.7× per switch, no build stated.` | OBSERVED `abstract.tex:63-69` — “The consequence is concrete:” is throat-clearing (survives deletion). No LLM tell word, but classic filler frame. |
| 71-75 | `The missing variable is not obscure. The bmv2 repository's README warns that build flags ``can have a massive impact on performance'' \cite{bmv2repo}, and its performance documentation lists the recommended configuration; two of the surveyed papers cite that very document and still do not report their own build.` | `Not obscure: bmv2 README warns “massive impact” [bmv2repo] and docs list recommended flags; two surveyed papers cite that doc and still omit their build.` | OBSERVED `abstract.tex:71-73` — “The missing variable is not obscure.” is metacommentary; delete. |
| 75-77 | `The knowledge exists in project documentation and forums; the \emph{reporting norm} does not exist in the 18 papers.` | `Knowledge exists in docs/forums; reporting norm does not — in 0/18 papers.` | OBSERVED `abstract.tex:75-77` — semicolon aphorism is poster-OK but costs a line for sociology. |
| 77-79 | `The adjacent NFV benchmarking community shows the norm is attainable: its flagship study pins per-switch commits, build notes, and parameters \cite{zhang2021benchmarking}.` | `NFV benchmarking shows the norm is attainable: per-switch commits and params [Zhang21].` | No tell. “adjacent” is needed contrast. |
| 80-82 | `Our study is a P4-community instance of a familiar genre: an unreported, ``trivial'' variable large enough to invalidate published comparisons \cite{mytkowicz2009wrong}.` | `This is a P4 instance of a known genre: an unreported “trivial” variable invalidating comparisons [Mytkowicz09].` | OBSERVED `abstract.tex:80-82` — “familiar genre” is academic throat-clearing (LLM-adjacent framing). Survives deletion but citation justifies it. Poster could cut entire sentence and keep citation. |
| 85-93 | `All experiments preregistered outcome intervals \emph{and the meaning of every outcome} before data; the replication unit is the interleaved arm (fresh fabric per arm); ladders are $\times1.5$ ($\pm$20\% per rung); the running binary is identified by symbol signature against a negative control, never by PATH; CPU gates use per-process attribution, trusted only after a positive control made them fire. Every arm reads both endpoint counters and paired ingress-RX/egress-TX interface counters --- kernel drop counters read zero even where bmv2 lost 79.66\% internally. Raw data is content-hash archived.` | `Preregistered intervals and decision rules. Replication = interleaved arm (fresh fabric). Ladder ×1.5 (±20%). Binary = symbol signature vs. negative control, not PATH. CPU gate = per-process, positive-control validated. Per-arm: endpoint + ingress-RX/egress-TX counters (kernel drops = 0 even at 79.66% internal loss). Raw data hash-archived.` | OBSERVED `abstract.tex:85-93` — densest methods sentence in abstract; no LLM words but **poster-unreadable**. Must become a sidebar box or methods pictogram, not a paragraph (see §2). |
| 95-97 | caption: `Build-configuration result (frame-size and flow-count results are Figs.~\ref{fig:unit}--\ref{fig:flows}). One machine, 128-host emulated topology, ten \texttt{simple\_switch\_grpc}; UDP; clean $=$ loss ${\le}0.5\%$.` | `Build results. 1 machine, 128-host emulation, 10× simple_switch_grpc, UDP, clean ≤0.5% loss. Frame-size and flow results: Figs. 1–2.` | No tell; caption buries scope limiter in parentheses. |
| 111-113 | `\textbf{(1) Build.} \emph{Stock} is a default-style build (\texttt{-O0}, logging compiled in, as installed by common guides); \emph{fast} is the officially recommended composite configuration (\texttt{-O3 --disable-logging-macros --disable-elogger}).` | `(1) Build: stock = -O0 + logging (common guides); fast = -O3 --disable-logging-macros --disable-elogger (recommended).` | OBSERVED `abstract.tex:111-113` — “default-style build” hedges; “composite configuration” is accurate per `NOTES.md:35` red line (must say composite). Keep composite. |
| 113-121 | `On our three-hop production path the UDP zero-loss point differs $12\times$. Isolated to a single switch --- one hop, control plane still live --- it is $45$ vs.\ $360$ Mbit/s: $R=8.0$, zero spread across arms, quantisation interval $(5.14,12.0)$, knee-shape interpolation ${\approx}7.8$. This landed in the preregistered outcome ``part of the production-path ratio is not the compiler flags.'' We report \emph{both} working points; whether the difference is path length or the live control plane is preregistered future work, and this abstract attributes it to neither.` | `3-hop prod path: 12× (UDP zero-loss). Single-hop, control plane live: 45 vs 360 Mbps, R=8.0, zero arm spread, q-interval (5.14,12.0), knee ≈7.8. Preregistered outcome: part of 12× is not compiler flags. We report both points; path vs. control-plane attribution = preregistered future work.` | OBSERVED `abstract.tex:113-121` — preregistered attribution restraint is required per `NOTES.md:31` (three prohibitions). Poster must keep but compress. No LLM tell. |
| 126-129 | caption: `The same six clean-rate cells, twice: packets per second are flat ($\times1.25$) while the identical data span $\times16.0$ as bit rate (two arms per frame size).` | Keep (poster-ideal caption). | No tell. |
| 132-144 | `Sweeping the standard NFV frame-size axis \cite{zhang2021benchmarking}, clean-rate pps is near-constant while the same cells span $16.0\times$ as bit rate (Fig.~\ref{fig:unit}); the registered ratios $P(256)/P(64){=}1.25$ and $P(1024)/P(64){=}1.00$ fall in the pps-ceiling interval and far from the bps-ceiling prediction (0.15--0.40 / 0.03--0.12). A registered sender-side control passed with $9.6\times$ headroom, so the flat line is bmv2's, not the generator's; all six arms also truncated at the same pps rung under a rule that is blind to frame size. \emph{Reporting bmv2 capacity in Mbps without the frame size is therefore not imprecision; it is a $16\times$ ambiguity.} ...` | `NFV axis (64/256/1024 B) [Zhang21]: pps flat across sizes (16.0/20.0/16.0 kpps), same data = 8.2/41.0/131.1 Mbps (16.0×). Registered ratios P(256)/P(64)=1.25, P(1024)/P(64)=1.00 → pps-ceiling, far from bps prediction (0.15–0.40 / 0.03–0.12). Sender gate 9.6× headroom; truncation at same 110 kpps rung (frame-size-blind rule). → Mbps without frame size = 16× ambiguity, not imprecision. ...` | OBSERVED `abstract.tex:132-144` — “is therefore not imprecision; it is a 16× ambiguity” is editorial but earned (quantified). Not filler. Length is the issue. |
| 149-152 | caption: `Per-flow highest clean rate vs.\ flow count: two independent arms, each monotone. Horizontal gridlines are the ladder's rungs --- adjacent rungs are the instrument's resolution.` | Keep; best caption in draft — explains instrument. | No tell. |
| 155-163 | `With all $n$ flows pinned to one path class (so flows/switch $=$ flows/link $=n$ by construction), the per-flow highest clean rate falls monotonically in each of two independent arms, cells agreeing within one ladder rung (Fig.~\ref{fig:flows}). The aggregate is an arithmetic consequence; we report no ratio --- an earlier ``collapse factor'' divided a clean threshold by a saturation knee, two different quantities, and was withdrawn. OvS at matched working points showed no decline (earlier measurement; a same-ladder control is planned).` | `n flows pinned to one path class → flows/switch = flows/link = n. Per-flow clean rate monotone ↓ in both arms, agreement within 1 rung (Fig. 2). Aggregate = n×per-flow, no ratio (earlier collapse factor withdrawn: clean threshold ÷ knee = different quantities). OvS matched points: no decline (earlier run; same-ladder control planned).` | OBSERVED `abstract.tex:155-163` — parenthetical “so flows/switch = flows/link = n by construction” is essential method, not filler. “arithmetic consequence” is defensive but needed after retraction (`2026-08-29_bmv2-performance-study.md:42-43`). |
| 167-176 | `Each experiment's dominant threat turned out to be the same: \emph{our own instrument's ceiling masquerading as the system's}. It happened twice --- a flow-count ladder's top rung was mistaken for the switch's single-flow ceiling long enough to enter a draft, and the first build-ratio round's ladder ended below the fast build's ability, censoring the numerator --- and was blocked once, by the registered sender gate. Both slips were caught by rule-driven ladder tops and post-hoc checks, and both corrections moved \emph{away} from the more publishable answer. None of the 18 surveyed papers states what limited its measurement; we read this as the same disease as Mbps-without-size, in a second form.` | `Dominant threat in all three: instrument ceiling ≠ system ceiling. Happened twice (flow top rung → draft error; build ladder censored fast numerator) and blocked once by sender gate. Both fixes moved away from the more publishable number. 0/18 papers reports what limited measurement — same disease as Mbps-without-size.` | OBSERVED `abstract.tex:167-176` — “turned out to be the same: our own instrument's ceiling masquerading as the system's” is the draft's most literary line; poster can keep as a callout box, but in body it is verbose. “we read this as the same disease … in a second form” is metaphor, not measurement. |
| 180-184 | `We propose a four-line provenance minimum for any software-switch number: \textbf{build} (flags/commit), \textbf{unit} (pps with the frame size), \textbf{placement} (flows per switch and link), and \textbf{limit} (what stopped the measurement --- the system, or the instrument). Preregistrations, raw data (content-hashed), and scripts will be released.` | `Proposed 4-line minimum for any software-switch number: build (flags/commit), unit (pps + frame size), placement (flows/switch, flows/link), limit (system vs. instrument). Prereg, hash-archived raw data + scripts to be released.` | OBSERVED `abstract.tex:180-184` — “four-line provenance minimum” is the takeaway; keep. No LLM tell. |

### Summary for (1)
- **No prescribed buzzword hits** — OBSERVED via grep.
- **Remaining tone risk is verbosity and metacommentary**, not LLM ornament. Draft already in systems register; hostile cut is ~35–40% word count without losing a number.
- **Strongest LLM-adjacent habits:** “The X is not obscure / The consequence is concrete / The knowledge exists … the norm does not” — tricolon-like moral framing (abstract.tex:63,71,75). Poster should replace with numbers.
- **Hedge discipline is exemplary** (mutually incomparable vs irreproducible, three prohibitions) but costs poster space; move to footnote/box per `NOTES.md:29,31`.
- **Active voice:** ~70% already active; remaining passives (“was withdrawn”, “is planned”, “will be released”) are appropriate.


---

## (2) INFORMATION DENSITY AND VISUAL POTENTIAL (poster genre)

### Poster-reader skip test — OBSERVED paragraphs

Poster reading ≈ 90 seconds, eyes go to titles → numbers → figures. Any block >4 lines without a number callout, table, or figure is skipped. Judged against `abstract.tex` 2026-08-29 snapshot:

| Lines / Paragraph | Verbatim opening (OBSERVED) | Skip? | Why skipped / What it should become (INFERRED) |
|---|---|---|---|
| Abstract `25-44` — 1 block, ~190 words, 6 numbers | `The software P4 switch bmv2 anchors...` | **SKIM only** — reader extracts 2500×, 0/12, 12×/8×, 16×, monotone, then bails | Abstract on poster = unread. Should become **4 number callouts** (2,500× / 0/12 / 16× / 8.0×) + 1-sentence question. Wall text must be deleted from poster. |
| §1 `52-61` P1 “Of 18 surveyed … mutually incomparable” | `Of 18 surveyed papers that measure or relay bmv2 performance, 12 measure it directly...` | **READ** (barely) — first 2 lines earn attention because bold 0/12 and 2,500× are scannable | Keep as **bulleted takeaway + 2,500× spread figure**. But current prose buries 0/12 in inline text. Should become table row, not sentence. |
| §1 `63-69` P2 “The consequence is concrete: …” | `The consequence is concrete: one line of work measures Open vSwitch two orders...` | **SKIP** | Opposite OvS ordering is important but told as narrative with 4 citations in one sentence. Poster reader will not decode `chen2025tomacs` vs `fernando2025network`. Should become **2-row comparison table** (see skeleton T-A below) or delete to footnotes. |
| §1 `71-82` P3-4 “The missing variable is not obscure … Our study is a P4-community instance …” | `The missing variable is not obscure. The bmv2 repository's README warns...` | **SKIP entirely** | Two paragraphs of “everybody knows / nobody reports / NFV shows it is possible / Mytkowicz genre” = sociology essay. A poster reader gets zero numbers here. On poster this is **one line under Fig 4**: `README says "massive impact" [bmv2repo]; cited by 2/18 papers; 0/18 report flags.` + citation `Zhang21` as existence proof. The Mytkowicz framing belongs in caption, not body. |
| §2 `85-93` methods block `All experiments preregistered outcome intervals...` | `All experiments preregistered outcome intervals \emph{and the meaning of every outcome} before data;` | **SKIP — densest skip in draft** | 1 sentence = 7 methods claims (prereg, arm, ×1.5 ladder, PATH vs signature, per-process gate + positive control, dual counters, 79.66% loss invisible to kernel). Poster reader will read 0 of them. Must become **methods pictogram / icon strip** (see skeleton T-B). Current paragraph is a journal methods dump in a poster. |
| Table `94-109` Build-configuration result | `caption{Build-configuration result (frame-size and flow-count ... One machine...}` | **READ as table** — but table wastes its chance | Current table has 2 rows (1-hop vs 3-hop) and hides scope in 9pt caption. Should display scope limiter in row header, not caption. See skeleton T-C. |
| (1) Build `111-121` | `\textbf{(1) Build.} \emph{Stock} is a default-style build...` | **READ first line, skip rest** — numbers land, hedging paragraph does not | Numbers (12×, 45 vs 360, R=8.0, interval 5.14–12.0, ≈7.8) are poster-grade. The 2-sentence prereg caveat (“part of … is not compiler flags… whether path or live control plane … is future work”) will be skipped but **must stay** per `NOTES.md:31` three prohibitions — compress to 1 clause in table footer. |
| Fig1 caption + (2) Unit `123-144` | `Sweeping the standard NFV frame-size axis...` + caption 126-128 | **FIG READ, TEXT SKIP** | Caption is poster-perfect (`same six cells, twice: pps flat ×1.25 vs Mbps ×16.0`). Body text repeats it with registered ratios and sender gate. Reader will look at figure, not 90-word paragraph. Body should become **3 bullet annotations on figure**: `H1: pps-ceiling 1.00/1.25 inside 0.65–1.30; H2 far (0.03–0.40)`, `gate 770.7 vs 80.0 = 9.6×`, `all 6 arms same 110 kpps rung (blind rule)` |
| Fig2 caption + (3) Flows `146-163` | `Per-flow highest clean rate vs.\ flow count...` + `With all $n$ flows pinned...` | **FIG READ, TEXT HALF-SKIP** | Monotone point and “within one rung” lands. Withdrawn-ratio disclaimer (“earlier collapse factor was withdrawn”) is honest but poster reader will parse as defensiveness. Compress to footnote `† earlier ratio clean-threshold ÷ knee = different quantities, withdrawn` under figure. OvS clause (`earlier measurement; same-ladder control planned` — `abstract.tex:162-163`) is critical caveat; do not hide. |
| §3 `165-176` What limited our measurements | `Each experiment's dominant threat turned out to be the same: \emph{our own instrument's ceiling...` | **SKIP despite being best insight** | Metaphor (“masquerading”, “same disease in second form”) is too literary for poster wall. Yet this is the only paragraph that generalizes beyond bmv2. Must become **visual anchor callout box**, not prose (see proposal below). Currently 115 words where 25 + icon would land. |
| §4 `178-185` Takeaway 4-line minimum | `We propose a four-line provenance minimum...` | **READ if bulleted** — currently semi-bulleted inline | `build / unit / placement / limit` is the poster's payoff; inline `\textbf{build} (flags/commit)...` will be skimmed as sentence. Must become **checklist with boxes**, not paragraph. |

**INFERRED summary:** Draft has 4 readable number anchors (2,500×, 0/12, 16×, 8.0×) buried in 8 prose paragraphs. A poster reader will see the numbers and the two figures, skip every methods/threats paragraph, and leave without the provenance checklist unless it is boxed. Cut ≥40% of words; move every caveat that is a red line (`NOTES.md:29-35`) to table footnote or icon so it survives the cut (`NOTES.md:25` cut order already anticipates this).

### Proposed poster-ready structures (concrete skeletons, rows from draft's own numbers)

All numbers below OBSERVED from `abstract.tex` and `make_figs.py` comments and `2026-08-29_bmv2-performance-study.md:101-128`.

**T-A — Spread that nobody can arbitrate (replaces §1 P1-P2 prose). Two-column “what literature reports vs what we measured” spread table — put beside Fig 4.**

| What 12 papers report (OBSERVED `abstract.tex:52-58`, `make_figs.py:140-146`) | Value | Papers that report it |
|---|---|---|
| `TSSA '23 64 B` | 0.574–0.757 Mbps | `hasnaa2023tssa` (`abstract.tex:56`) |
| `P4sim '25 (Mininet baseline)` | ~43 Mbps (saturation) | `Ma & Nguyen 2025` (`study:112`) |
| `PADS '24 native/VM` | 145–175 Mbps (single switch) | `waind2024pads` (`study:103`) |
| `TOMACS '25 grpc` | ~170 Mbps grpc ceiling; `simple_switch` up to 1 Gbps | `chen2025tomacs` (`study:105`) |
| `ICNCC '23 phys NIC` | 1,000 Mbps lossless; ~1,400 Mbps mean ceiling | `kumazoe2023icncc` (`abstract.tex:57`) |
| **Same corpus:** | **0/12 report flags, 0/12 build comparison, 3/12 name variant (one lab), 1/12 names version** | `abstract.tex:53-55` |
| **Opposite OvS ordering (why it matters)** | Chen lineage: OvS 100× > bmv2 (`chen2025tomacs/chen2023pads`); Fernando25: P4 > OvS | `abstract.tex:63-66` |
| **This work, same machine** | **45 Mbps (stock) vs 360 Mbps (fast) = 8.0× (q-interval 5.14–12.0, knee ≈7.8)** | `abstract.tex:116`, `make_figs.py:106-108` |

*Column header suggestion for poster:* `Published bmv2 throughput (Mbit/s, quantity types mixed — that is the point [study 5-6])`

**T-B — Methods icon strip (replaces `abstract.tex:85-93` paragraph). One row, 5 icons + short labels, footnotes carry red lines.**

| Icon | Label | Poster text (≤10 words) | Source |
|---|---|---|---|
| 📋 | Prereg | Intervals + decision rules before data | `abstract.tex:85` |
| 🔁 | Arm | Replication = interleaved arm, fresh fabric | `abstract.tex:86-87` |
| 🪜 | Ladder | ×1.5 ladder, ±20% per rung, rule-driven top | `abstract.tex:87-88` |
| 🔑 | Binary | Symbol signature vs negative control, not PATH | `abstract.tex:88-89` |
| ⚖️ | Gate | Per-process CPU, positive-control validated; dual counters (kernel drops = 0 at 79.66% loss) | `abstract.tex:89-92` |
| 🗄️ | Archive | Raw hash-archived, 168 + 1465 files | `study:14, 99-100` |

**T-C — Build results (replaces Table `94-109` + (1) Build prose). Scope limiter in row, not caption.**

| Working point (scope in row) | Stock (`-O0` + logging) | Fast (`-O3 --disable-logging-macros --disable-elogger`) | R | Quantisation interval | Arms | Status |
|---|---|---|---|---|---|---|
| 1 hop, isolated, control plane live (**this work, prereg**) | 45 Mbps (45/45) | 360 Mbps (360/360) | **8.0** | (5.14, 12.0) | 2/arm, 4 total, zero spread, next rung 540 fails 25.8/26.6% | **measured** |
| 3-hop production path (pilot, **not a control**) | 25 Mbps | 300 Mbps | **12×** | — | — | **pilot, not for attribution** |

*Footer (red line, `NOTES.md:31`):* `Difference between 12× and 8.0×: path length vs live control plane — preregistered future work, attributed to neither this paper.`
*Source:* `abstract.tex:111-121`, `make_figs.py:106-113`, `study:42-43`

**T-D — Unit / frame-size ambiguity (annotates Fig 1; replaces (2) Unit paragraph).**

| Frame (Ethernet) | `-l` payload | Clean pps (arm a / b) | Mean pps | Same data (Mbit/s) | Registered ratio |
|---|---|---|---|---|---|
| 64 B | 22 B | 20 / 12 kpps | **16.0** | **8.2** | — |
| 256 B | 214 B | 20 / 20 kpps | **20.0** | **41.0** | P(256)/P(64)=**1.25** ∈ H1 (0.75–1.30), far from H2 (0.15–0.40) |
| 1024 B | 982 B | 12 / 20 kpps | **16.0** | **131.1** | P(1024)/P(64)=**1.00** ∈ H1 (0.65–1.30), far from H2 (0.03–0.12) |
| **Spread** | — | **1.25×** | **p = flat** | **16.0×** | — |
| Gate (64 B loopback) | — | 770.7 kpps vs 80.0 required | **9.6× headroom** | — | — |
| Truncation | — | **all 6 arms same 110 kpps rung, rule blind to size** | — | bit rates differ 16× there | — |

*Takeaway calle d out on figure:* `Mbps without frame size = 16× ambiguity, not imprecision` (`abstract.tex:139-141`)
*Source:* `make_figs.py:42-50`, `study:43`, `packet-size-sweep/FINDINGS.md:16-27`

**T-E — Flow-count placement (annotates Fig 2; replaces (3) Flows paragraph).**

| n (all on one path class → flows/switch = flows/link = n) | arm a (M/flow) | arm b (M/flow) | Aggregate (n×per-flow, derived) |
|---|---|---|---|
| 1 | 160 | 240 (top rung, right-censored — true value ≥240) | 160 / 240 |
| 2 | 110 | 110 | 220 / 220 |
| 4 | 30 | 45 | 120 / 180 |
| 8 | 5 | 8 | 40 / 64 |
| 16 | 2 | 1 | 32 / 16 |
| **Pattern** | **both arms monotone ↓, agreement within 1 rung** | | |
| OvS matched points | **no decline (earlier run; same-ladder control planned)** | | `abstract.tex:161-163`; `NOTES.md:33` |

*Footnote:* `† Aggregate = n × per-flow; no ratio reported — earlier "collapse factor" (clean threshold ÷ knee) withdrawn: different quantities [study §3-3, 5-6].`
*Source:* `make_figs.py:84-86`, `flow-count-capacity/FINDINGS.md:14-27`

---

### Do the four existing figures earn their space? (OBSERVED `make_figs.py`)

| Figure | What it shows (OBSERVED code + comments) | Poster value | Verdict |
|---|---|---|---|
| **fig1 `fig1_unit_ambiguity`** — dual panel: top scatter pps flat (×1.25), bottom log bar Mbps ×16.0; 6 cells `make_figs.py:45-75`, data `16.0/20.0/16.0 kpps == 8.2/41.0/131.1 Mbit/s` | **Core quantitative contribution (C2).** One image proves “Mbps without size = 16× ambiguity” without reading text. Caption `make_figs.py:126-128` is poster-perfect. | **Earns space — keep large.** Top-2 candidate for anchor. |
| **fig2 `fig2_perflow_monotone`** — log-log per-flow rate vs n with rung gridlines, `arm_a 160/110/30/5/2 arm_b 240/110/45/8/1`, `rungs [1…240]`, annotation `adjacent rungs = ±1 resolution` `make_figs.py:82-102` | **Replication + instrument resolution argument.** Shows monotone in each arm, spread = resolution (INFERRED: study §5-9 reframes 1.5–2× as ±1 rung). Without gridlines figure loses its point; with them it teaches the method. | **Earns space — keep medium.** Not anchor (less hallway wow) but strong credibility piece. |
| **fig3 `fig3_build_two_working_points`** — log horizontal 25→300 (12×) vs 45→360 (R=8.0 interval 5.14–12.0), `make_figs.py:110-132` | **Scope honesty figure.** Shows why 12× ≠ 8× and that difference is not attributed (`NOTES.md:31` three prohibitions). For poster, distinction between pilot 3-hop and isolated 1-hop is subtle; reader may conflate. Value is for reviewers, not hallway. | **Does not earn full figure space on poster.** Demote to **inset inside T-C or small panel beside Table 1.** The 8.0× number itself suffices; the two-row visual is reviewer-grade, not poster-grade. `NOTES.md:40` already parks fig3 in full paper — correct call. |
| **fig4 `fig4_literature_spread`** — log spread 0.574…1400 Mbps five literature points + our 45/360 bar, annotation `~2,500×, zero papers report build` `make_figs.py:139-169` | **Why the poster exists.** Mixed quantity types (zero-loss / saturation / mean) are intentional — “that is the point (report 5-6)” `make_figs.py:137-138`. One image justifies “mutually incomparable”. OBSERVED `NOTES.md:38-40` says fig4 is in study report §4, not in abstract — i.e., authors chose not to show it on condensed 2-pager. | **Earns space — strongest visual anchor.** INFERRED: for poster genre, this should be **the big central figure**; fig1 should be #2. Fig4 stops a passerby; fig1 convinces them. |

**Single visual anchor (poster genre):** `fig4_literature_spread` — because the poster's job is to make “you cannot compare published numbers” unavoidable in 5 seconds. It does three things no table can: (a) shows 2,500× incomprehensibility as physical distance on log scale, (b) overlays our 8× build bar inside that spread to show one trivial variable fills a factor 8 of it, (c) annotates `zero papers report build` where it hurts. If only one figure can be 40% of poster board, it is fig4. INFERRED alternative if PC wants novelty over sociology: fig1 as anchor — defensible, but fig4 has higher “oh.” factor for hallway.

**Evidence discipline note (INFERRED gap):** `make_figs.py:139` comment `Quantity types are mixed ... that is part of the point` is correct rhetoric but a reviewer will ask whether log spread overstates incomparability by mixing 64 B (TSSA) with NIC line-rate (ICNCC). The poster must answer in caption: `Quantity types mixed — exactly as literature reports them; incomparability includes reporting` — otherwise hostile reader dismisses fig4 as apples-vs-oranges.


---

## (3) THREATS TO VALIDITY / EXTERNAL VALIDITY — Does the draft over-claim?

### What was checked

- `abstract.tex` full-text for explicit limitations: `functional`, `reference model`, `never intended`, `hardware`, `extrapolat`, `single machine`, `one machine`, `Mininet`, `veth`, `NIC`, `commit`, `version` → grep results below.
- `2026-08-29_bmv2-performance-study.md §5-3`, `§5-4` as background truth (the study report the abstract abbreviates).
- `NOTES.md` red lines as binding scope.

### OBSERVED quotes from `abstract.tex` (what the draft DOES say)

| Sentence (verbatim `abstract.tex:line`) | What it bounds | Assessment |
|---|---|---|
| `We then quantified, under preregistered protocols on one machine, three variables that no surveyed paper isolates.` (`:31-32`) | scope = one machine | **States single-machine scope — good.** |
| `on one machine, 128-host emulated topology` (`Table caption :95-97`) | topology = emulated | States emulated; keeps “One machine, 128-host emulated topology...” in 9pt caption — will be missed on poster but present on paper. |
| `Isolated to a single switch --- one hop, control plane still live --- it is 45 vs. 360 Mbit/s: R=8.0` (`:115-117`) | working point = single hop, control plane live | **States isolated point — excellent, per NOTES.md:31 three prohibitions obeyed.** |
| `This landed in the preregistered outcome "part of the production-path ratio is not the compiler flags." We report both working points; whether the difference is path length or the live control plane is preregistered future work, and this abstract attributes it to neither.` (`:117-121`) | attribution restraint | **Explicitly refuses to attribute remainder — exemplary.** OBSERVED also in `study:42` table. |
| `on physical NICs \cite{kumazoe2023icncc}` (`:57`) + `ten simple_switch_grpc; UDP; clean = loss ≤0.5%` (caption `:97`) + `128-host emulated` | environment differs from NIC papers | Implies but **does not state** that results are Mininet/veth-specific and not comparable to NIC measurements. |
| `With the information the papers themselves provide, no two of these numbers can be shown to measure the same artifact. We say mutually incomparable deliberately --- we did not attempt reproductions, so we claim nothing about reproducibility.` (`:58-61`) | claim type = incomparability, not irreproducibility | **Correct restraint per NOTES.md:29.** |
| `quantisation interval 5.14--12.0` (`:35-36`, `Table :104-105`) + `knee ≈7.8` (`:36,105`) | ratio is not point estimate | States uncertainty interval — good. But missing explicit statement that reported R=8.0 inherits ±45% ladder quantisation (`study:14, 99-100` / `single-switch FINDINGS-1b:80-82`). |
| `We report no ratio --- an earlier "collapse factor" divided a clean threshold by a saturation knee, two different quantities, and was withdrawn.` (`:159-161`) | withdrawal | **Explicit withdrawal — strong for validity.** |

### OBSERVED gaps from `abstract.tex` (what the draft does NOT say)

Grep `abstract.tex` for `functional`, `reference model`, `never intended as a performance target`, `hardware target`, `P4 the language`, `extrapolat`, `Mininet`, `veth`, `kernel version`, `14-core`, `single-switch-build-ratio`, `other hosts`, `cannot be extrapolated` → **0 hits**. I.e., the draft **does not contain** the following required limitations anywhere in the 2-pager text, table, or figure captions:

1. **bmv2 is a functional reference model, never intended as a performance target.** No sentence in `abstract.tex` says this. OBSERVED `study §5-3:399-403` lists “Single machine … Mininet/veth … not physical NIC … single P4 program … version single point” but also does not say “functional reference model” in those lines. The limitation exists only implicitly (“emulated topology”) not plainly.
2. **One environment — forbid extrapolation to other hosts, kernels, hardware.** `abstract.tex` says “on one machine” once (`:32`) and “One machine, 128-host emulated topology” in a 9pt caption (`:95`). It does **not** say: “do not extrapolate factor 8/12/16 to other machines, kernels, NICs, or bmv2 versions/commits,” nor does it name the host (CPU, kernel), the bmv2 commit, or that Mininet/veth is a specific environment distinct from ICNCC’s physical NIC. OBSERVED `study §5-3:399-403` gets closer: `Single machine (14 cores); Mininet/veth environment (not physical NIC — ICNCC's 1.4 Gbps on physical 10G NIC, working point inherently different); single P4 program; bmv2 version single point; UDP primary.` INFERRED: the abstract should surface that sentence in readable type, not caption.
3. **Avoid implying anything about P4 the language or hardware pipelines.** No sentence in `abstract.tex` guards against “P4 is slow” reading. OBSERVED `2026-08-28_bmv2-throughput-literature-vs-ours.md:163` does: `Slow is bmv2 this implementation not P4 this language (T4P4S same program 2.3–2.6 Gbps)`. That guard is in background notes, not in poster abstract. Only defense in abstract is citing `[Zhang21]` NFV vs P4 distinction, which is insufficient.
4. **Flow-count result is 5 cells on one placement, not a collapse factor.** Draft withdraws ratio (`:159-161`) but does not bound external validity of monotone itself (one path class, one topology, one build, UDP, n ≤16). See `study §5-3:400` caveats.
5. **OvS non-decline is not same-ladder:** `abstract.tex:161-163` says `(earlier measurement; a same-ladder control is planned).` — present and correct, but in parentheses at end of paragraph; easy to misread as same-evidence tier as bmv2 arms.
6. **Provenance row-level:** `abstract.tex:80-82` cites Mytkowicz but does not limit retrieval coverage (`study §5-4:405-421` says search covered 18 identified papers via kill-shot + cited-by + recall, but database/ML/T4P4S/MoonGen not checked). Abstract says “18 surveyed papers” — does not state that 18 is not exhaustive coverage of literature.

### INFERRED: why this is over-claim risk for a hostile reader

- The title `Why Published BMv2 Throughput Figures Cannot Be Compared` (`:15`) is a **universal** claim; the quantified scope is **18 specific papers + 1 machine**. Hostile reader will say: “Your title claims literature is incomparable; your threat model covers only your machine.”
- Hostile reader will also say: “You use bmv2’s variability to discredit bmv2 numbers, then your numbers are the ones I should trust — but your numbers are also bmv2 on one box.”
- Without `functional reference model` guard, the hallway takeaway becomes “bmv2 is slow / broken” rather than “reporting is broken.” That misreading hurts the authors’ own credibility and antagonizes artifact reviewers who know bmv2’s intent.

### READY-TO-PASTE missing Limitations paragraph (INFERRED: propose to insert as boxed sidebar on poster and as §3.1 paragraph in 2-pager)

**Paragraph below is INFERRED synthesis of `study §5-3:399-403` and `§5-4:405-421` plus required bmv2-intent framing; not observed verbatim. Language tightened for EuroP4 register. Paste-ready:**

```latex
\section*{Limitations (what we do not claim)}
\label{sec:limits}
\small
\textbf{bmv2 is a functional reference model, not a performance target; its absolute
throughput is not the point.} Our numbers bound \emph{how much unreported knobs swing
a reported bmv2 number} ($R{=}8.0$ isolated; $16\times$ unit ambiguity; monotone per-flow
decline), not ``how fast bmv2 (or P4) is.'' The P4 language and hardware pipelines are
not on trial --- the same P4 program on T4P4S reaches $2.3$--$2.6$~Gbps \cite{kumazoe2023icncc}.
\textbf{One environment.} All new measurements: one 14-core host, Linux $a40e04ce$,
10$\times$\texttt{simple\_switch\_grpc} at one commit (symbol-signature identified, not
\$PATH), 128-host Mininet/veth emulation, UDP, one P4 program, clean $\le$0.5\% loss.
ICNCC's 1.4~Gbps is on physical NICs --- a different working point. \textbf{Do not
extrapolate} factors 8, 12, or 16 to other hosts, kernels, NICs, commits, or hardware
targets; what generalizes is the \emph{structure}: any factor $\gg$1 that no paper
reports makes its numbers mutually incomparable. \textbf{Scope of ``18 papers.''}
``$0/12$ report flags'' means the 18 surveyed papers (12 measuring bmv2; Sec.~1);
we do not claim exhaustive coverage (dblp/Google-Scholar/cited-by/T4P4S-HPSR'18/MoonGen/P4-Slack
not fully swept; audit, Sec.~5.4). \textbf{OvS caveat:} OvS ``no decline'' is an
earlier run at matched points; same-ladder OvS control is planned, not yet run.
```

**Shorter poster wall version (≈35 words) if no room for box above:**

```
bmv2 is a functional reference model, not a speed target.
All numbers: 1 host, Mininet/veth (not NICs), 1 commit, UDP, n≤16.
Do not extrapolate 8×/16× to other machines/targets.
Claim = reporting incomparability (18 surveyed papers), not irreproducibility nor “P4 is slow”.
```

**Where to place:** Poster: bottom strip, 90%-width, grey background, left-aligned, 6–7pt is acceptable for limitations — hostile reviewer checks that it exists, not that it is 12pt. 2-pager: end of §2 or start of §4, not appendix.

**INFERRED cannot-determine gap (evidence discipline):** Cannot determine from read evidence whether `abstract.tex:113-121` build ratio mixes 1400 B payload (`make_figs.py:43 1400 B` for build arms) with frame-size sweep’s 64–1024 B frames; the study’s `study:14` says 1400 B for build arms and 64–1024 B for sweep — they are separate ladders on same host, not directly commensurable, which draft correctly does not conflate. Would need explicit frame/payload bookkeeping per row on poster to prevent reader conflation.


---

## (4) COMMUNITY PAIN-POINT ALIGNMENT — Does the warning land sharp or buried?

### OBSERVED: where the draft puts the baseline/comparison-fallacy warning

Search `abstract.tex` for `baseline`, `speedup`, `inflate`, `comparison fallacy`, `unoptimised`, `trivial variable`, `accelerate`, `norm`, `Mytkowicz` — and read by hand:

| Location (`abstract.tex:line`) | Verbatim warning sentence (OBSERVED) | Headline or buried? |
|---|---|---|
| `:15-16` title | `Mind the Build: Why Published BMv2 Throughput Figures Cannot Be Compared` | **Headline** — strongest warning, but it is about *comparability of bmv2 numbers*, not about *inflated speedups over bmv2*. |
| `:58-61` | `no two of these numbers can be shown to measure the same artifact. We say mutually incomparable deliberately --- ...` | Headline-grade claim, but generic — does not name baseline fallacy. |
| `:63-67` OvS inversion | `one line of work measures Open vSwitch two orders of magnitude above bmv2 [Chen…], while another concludes the P4 pipeline outperforms OvS [Fernando…] --- and a reader cannot arbitrate` | **Closest to baseline pain point**, but told as “two papers disagree”. Reader must infer the lesson for their own speedup claim. No sentence says “your speedup over bmv2 is inflated.” |
| `:71-73` README | `bmv2 repository's README warns that build flags "can have a massive impact on performance" [bmv2repo], and its performance documentation lists the recommended configuration` | Folklore-vs-norm — establishes that knowledge existed, not that baseline users exploit it. |
| `:80-82` Mytkowicz | `Our study is a P4-community instance of a familiar genre: an unreported, "trivial" variable large enough to invalidate published comparisons [mytkowicz2009wrong].` | **Genre framing is the sharpest intellectual move in draft**, but at line 80 of 185 — bottom of page 1, poster reader has scrolled past. And it says “invalidate comparisons” without “baseline + speedup inflation” specifics. |
| `:180-182` Takeaway | `We propose a four-line provenance minimum ... build (flags/commit), unit (pps with the frame size), placement ...` | Checklist is constructive but not a warning. No sentence says “stop reporting X× speedups over bmv2 without stating build.” |
| Absent anywhere | `Giving your system the fast build and bmv2 the slow build inflates your speedup by ~8×` — **not stated.** | — |

**OBSERVED verdict:** The draft lands *a* warning (mutual incomparability) very sharply, but **buries the baseline/comparison-fallacy warning that matters to the measurement community**. The sentence a systems builder needs to hear — “if you compare your system to an unoptimized bmv2 without reporting build, your claimed gain is mostly the build” — never appears as a headline. The Mytkowicz genre point at `:80-82` and the OvS inversion at `:63-67` circle it, but both require inference.

**INFERRED: why this matters for EuroP4 poster passersby**
- The audience that needs the poster *is* the one that has a “our system is 8× faster than bmv2” bar chart at home. Their hallway question is “should I be worried?” The current poster answers “literature is messy” (true, sociology) instead of “your next bar chart is probably wrong” (actionable, self-interested). A hostile PC member will mark this as “interesting but not urgent.”
- Severity ranking (INFERRED): (i) baseline fallacy = most painful (affects every efficiency paper that claims speedup), (ii) unit ambiguity = second most painful (silent 16×), (iii) “mutually incomparable” = precise but less painful unless you maintain a benchmark suite. Draft orders them (i) last / absent, (ii) middle, (iii) first — inverse of pain.

### Sharpest one-sentence warning (INFERRED, ready to paste as poster headline)

Offer two registers; both fit one line at 18–20pt:

**A — confrontational, memorable (poster hallway):**
```
A stock bmv2 build is ~8× slower than the recommended build on the same
machine — report an untuned bmv2 “baseline’’ and any speedup you claim is
mostly the build, not your system.
```

**B — conference-polite, same math (paper abstract / conclusion):**
```
Any speedup over bmv2 that does not fix and report the build compares
your system to the slowest build of bmv2 — on our host, that alone is
an ~8× (≈5–12×) effect, larger than most claimed gains.
```

Both restate OBSERVED `R=8.0 (5.14–12.0), knee ≈7.8` (`abstract.tex:36,105-107`) + “stock = as installed by common guides” (`:111`). Neither extrapolates beyond one host (see §3 limits); both force the reader to see their bar chart differently before they read the rest.

### 3-sentence “what authors should report from now on” checklist (INFERRED, for conclusion block)

Designed to fit a 3×2-inch boxed block under the takeaway. Each sentence is one checklist item; sentence 1 is the fix for the baseline fallacy. Paste-ready:

```
(1) \textbf{Build:} commit + flags (e.g., \texttt{-O3 --disable-logging-macros
--disable-elogger} vs.\ stock) — an undisclosed build is an undisclosed
$8\times$. Your speedup over bmv2 must name the build it beats, or it is a
comparison to the slowest bmv2. (2) \textbf{Unit:} pps \emph{with} frame size
(and Mbps beside it) — bmv2's ceiling is pps; Mbps without size is a $16\times$
ambiguity. (3) \textbf{Placement \& limit:} flows/switch \& flows/link,
plus what stopped the measurement (system knee vs.\ instrument top rung) —
per-flow clean rate falls monotonically with $n$; we also show the same-packet
loss is invisible to kernel drop counters.
```

**Checklist source trace (OBSERVED → INFERRED):**
- Build 8× → `abstract.tex:113-117`, `make_figs.py:106-108`, `study:42`
- Unit 16× → `abstract.tex:132-144`, `make_figs.py:42-50`, `study:43`
- Placement monotone → `abstract.tex:155-158`, `flow-count-capacity/FINDINGS.md:14-22`
- Kernel drops zero at 79.66% → `abstract.tex:91-92`, `flow-count-capacity/FINDINGS.md:190-196` (OBSERVED) — INFERRED: belongs in checklist because it is the trap that makes “loss ≤0.5%” look clean when read wrong.

**Placement instruction (INFERRED):** Checklist must be **boxed, numbered 1–3, with verbs**, not inline bold (`abstract.tex:180-184` current). Current takeaway is paragraph prose; checklist prose is skipped. Concrete box:

```
┌─────────────────────────────────────────┐
│ REPORT THIS OR YOUR NUMBER IS NOISE     │
│ 1. BUILD   2. UNIT   3. PLACEMENT+LIMIT│
│ (1 line each, with observed example)   │
└─────────────────────────────────────────┘
```

If poster keeps the Mytkowicz line (`:80-82`), move it **into this box as footer**: `This is the P4 instance of “wrong data without doing anything obviously wrong” [Mytkowicz09].` — lets hallway reader connect folklore-vs-norm sociology to their checklist in one glance.

**Evidence discipline note (INFERRED cannot-determine):**
- Cannot determine from read evidence whether any surveyed paper’s speedup claim was *caused* by unreported build (would require reproduction with both builds, which draft correctly did not attempt per `abstract.tex:60-61` and `study:48-50`). The warning must stay at “risk/incomparability” level, not “X papers’ speedups are falsely inflated” — draft obeys this; the sharper headline proposed above obeys it by saying “any undisclosed-build speedup *risks* being mostly the build” (≈8× on our host), not “papers Y are wrong.”


---

## HOSTILE SUMMARY & SUBMIT-NO-SUBMIT CHECK

**Overall hostile read:** Numbers are strong and honestly hedged (H2 restraint, withdrawn ratio, disclosed censoring, positive-control gates) — unusually strong for a poster. The **paper’s worst enemy is its own verbosity**: a 2-page abstract tries to be a journal threats-to-validity section. A passerby will catch 2,500× and 16× and leave thinking “interesting, not my problem” unless the baseline-inflation warning is made the headline and the provenance checklist is made the visual payoff. The missing plain-English `functional reference model / do-not-extrapolate / T4P4S guard` paragraph will be the first reviewer objection; adding the boxed §3 paragraph above costs 7 lines and neutralizes it. Figures are worth keeping, but fig4 should be poster-anchor, not fig3. Fig3 should be demoted to inset; its absence from the poster (`NOTES.md:39-40`) is already a correct cut but must be replaced by the 8× bar inside fig4.

**Pre-submit blockers (bind on `NOTES.md:7-15` minus what this review can judge):**
- `abstract.tex:19-23` TODOs — affiliation, email, second author consent — unresolved at snapshot.
- `abstract.tex:5` numbers sourced from `doc/2026-08-29_bmv2-performance-study.md` + 3 audits — provenance OK per `study §4` and audit commits cited, but poster must pin commits in small type (per §3 paragraph above) or reviewers flag stealth pilot mixing (`study:12` warns pilot only in motivation).
- refs.bib TODOs — `fernando2025network` title/authors TODO (`refs.bib:52`, `NOTES.md:47-49`) and `kohler2018p4cep` author list TODO — must verify before ACM DOI; no-show withdrawal policy (`NOTES.md:14-15`) binds poster to attendance.

**Honest cannot-determine list (would need X):**
- Cannot determine whether any of the 18 papers’ 2,500× extreme (0.57 Mbps TSSA vs 1.4 Gbps ICNCC) collapses after normalizing for frame size + build + physical NIC vs veth without re-running those papers — would need artifact reproduction (explicitly not done, `abstract.tex:60-61`).
- Cannot determine whether 12× vs 8.0× gap is path length vs control-plane vs interaction — deliberately left confounded by design (`FINDINGS-1b.md:112-116`), preregistered future work.
- Cannot determine whether per-flow monotone holds beyond n=16 or at other path classes beyond “spread raises aggregate” directional hint — would need n=32 scan or different path-class grid.
- Cannot determine whether any surveyed speedup claim is *causally* build-inflated — would need controlled re-run of that paper’s exact system with both builds.

**If only 3 edits before print:**
1. Replace title or add subtitle bar with baseline warning B (≈8× effect larger than most gains) — highest reviewer-pain fix (see §4).
2. Paste Limitations boxed paragraph (§3) with `functional reference model / 1 host Mininet/veth / do-not-extrapolate / T4P4S` — preempts first hostile comment.
3. Promote fig4 to anchor (40% board), annotate fig1 on-face with 3 bullets (gate 9.6× + blind rung + 1.25× vs 16×), demote fig3 to inset inside build table, and restyle Takeaway as 3-line checklist box — converts skippable prose into poster-readable structure (see §2 skeletons T-A to T-E).

*Report generated incrementally; file:line citations are to snapshot 2026-08-29 read via `default.read_file` / `default.grep`. OBSERVED vs INFERRED separation is strict: every number’s file:line is OBSERVED; every “should become” / rewrite / headline is INFERRED.*

