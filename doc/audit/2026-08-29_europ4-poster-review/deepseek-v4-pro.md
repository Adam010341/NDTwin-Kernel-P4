# Hostile EuroP4'26 review + Artifact Evaluation of `doc/2026-08-29_europ4-poster-abstract/`

Scope: (A) experimental method and logical holes, (B) citation correctness/hygiene, (C) reproducibility/AE checklist. Only these three axes.
Conventions: **O** = observed (file:line quoted verbatim), **I** = inferred. "NO BACKING FOUND" = no evidence on disk. Severity: 🔴 blocking / 🟠 major / 🟡 minor.

Supporting evidence reviewed on disk: `abstract.tex`, `refs.bib`, `NOTES.md`, `make_figs.py`; `doc/2026-08-29_bmv2-performance-study.md`; `doc/2026-08-15_bmv2-performance-report.md`; `doc/audit/bmv2-binary-provenance.md`; `doc/audit/2026-08-28_{single-switch-build-ratio,packet-size-sweep,flow-count-capacity,bmv2-literature-review,jitter-working-point}/` (PREREGs, FINDINGS, driver/arm scripts, raw `arm.meta` files).

---

## (A) EXPERIMENTAL METHOD AND LOGICAL HOLES

### A1. 🔴 The OvS comparison arm: "matched working points" is contradicted by the authors' own records; and the quantity compared on the OvS side is not the quantity claimed.

- CLAIM: "per-flow highest clean rate falls monotonically with flow count, replicated, while OvS at matched working points does not." (abstract.tex:40-41); again "OvS at matched working points showed no decline (earlier measurement; a same-ladder control is planned)." (abstract.tex:162-163).
- EVIDENCE FOUND:
  - The flow-count OVS arm was never run. O: "⬜ **本輪未跑 OVS 臂**——C3 的「OVS 不降」半邊目前由舊工作點量測支撐（`audit/2026-08-28_jitter-working-point/04_ovs_result.md`，不同置放、不同梯）" (`2026-08-29_bmv2-performance-study.md:306`). "不同置放、不同梯" = different placement, different ladder.
  - The OvS numbers cited are from a jitter study on a *shaped* testbed: O: "本輪在 as-configured 狀態量…`bw=1000` 存在…htb qdisc" (`03_ovs_PREREG.md:9-13`); the bmv2 flow study ran on the unshaped 128-host topology with a ×1.5 ladder. Not the same testbed.
  - Quantity mismatch: the bmv2 claim is per-flow clean rate; the OvS evidence is aggregate non-collapse. O (`04_ovs_result.md:49-52`): "| **OVS** | ~400 M（0.146%） | **480 M**（不塌陷）". In the OvS data per-flow rate falls from ~400 M/flow (n=1) to 30 M/flow (16×30 M = 480 M) — i.e. per-flow declines ~13× on the OvS side too. Only the *aggregate* does not collapse. So "per-flow … while OvS … does not [decline]" is unsupported by the very numbers the authors cite.
- WHAT IS MISSING: an OvS arm on the same machine, same 128-host topology, same unshaped links, same ×1.5 per-flow ladder, same n=1..16 placement, reporting per-flow highest clean rate.
- MINIMAL FIX: run ③'s exact ladder and placement against OvS before submission; until then the sentence must read "aggregate clean rate showed no decline in an earlier, non-matched OvS measurement (different placement and ladder; same-ladder control planned)".

This is the task's category (i) hole: an OVS-vs-bmv2 comparison lacking a same-generation / same-testbed control arm.

### A2. 🔴 The survey population is mischaracterized: "18 papers that measure or relay bmv2 throughput" — 5 of the 18 neither measure nor relay bmv2 at all, and 2 measure latency/delay only.

- CLAIM: "We surveyed 18 papers that measure or relay bmv2 throughput" (abstract.tex:27-28); "Of 18 surveyed papers that measure or relay bmv2 performance, 12 measure it directly." (abstract.tex:52-53).
- EVIDENCE FOUND: the study's own census table (`2026-08-29_bmv2-performance-study.md:103-122`) marks rows 13 (CompNet 2021), 14 (NetSoft 2019), 16 (vSDNEmul), 17 (HotSDN '13), 18 (P4Docker) as ❌ — no bmv2 measurement or relay — and row 15 (TUM survey) as ➖ "轉述". Rows 6 (Whippersnapper) and 9 (PoliTO thesis) measure bmv2 **latency/delay only** (study doc:110, :113).
- WHAT IS MISSING: an accurate population description. At most 12 measure performance directly (2 of those latency-only), 1 relays; 5 are non-bmv2 context papers. The abstract's own denominator statements ("none of the 18 papers states what limited its measurement", abstract.tex:42-43) inherit this inflation: it is asserted about papers that never measured bmv2 at all.
- MINIMAL FIX: reword to "We screened 18 papers; 12 measure bmv2 performance directly (10 report throughput), 1 relays a figure, and 5 are non-bmv2 NFV/emulator context papers." Scope all universal claims to the 12 (or 10) that actually measured.

### A3. 🔴 "All 18 surveyed papers report Mbps" is contradicted by the authors' own corpus, which includes Mpps-based papers.

- CLAIM: "All 18 surveyed papers report Mbps (one adds a single pps point \cite{kohler2018p4cep}); none sweeps frame size for bmv2" (abstract.tex:141-142).
- EVIDENCE FOUND: the authors' own related-work notes state NetSoft '19 and CompNet 2021 are Mpps-primary: O "**NetSoft 2019** | 同組人的前身：4 場景方法學、**Mpps@64B 本位**" (`RELATED-WORK.md:49`); O in the retained keyword hits: NetSoft "thus limited up to 14.88 Mpps for 64B packets" (`raw/hits_pktsize.txt:26`); CompNet "≤4 Mpps with 64B" (`raw/hits_pktsize.txt:222`). Both papers are members of the 18.
- WHAT IS MISSING: a true universal. The correct scope is "the 12 papers that measure bmv2 throughput report Mbps, except P4CEP (pps)".
- MINIMAL FIX: change subject of the universal; it currently can be falsified by two entries in the authors' own census table.

### A4. 🟠 The 2,500× spread headline is computed across mixed quantity types — a confound the authors themselves concede, but the abstract (which lacks fig4) omits it.

- CLAIM: "reported figures span ${\sim}2{,}500\times$ (0.57\,Mbps to 1.4\,Gbps)" (abstract.tex:28-29); "Their throughput figures span ${\sim}2{,}500\times$, from 0.57\,Mbps at 64\,B \cite{hasnaa2023tssa} to 1.4\,Gbps on physical NICs \cite{kumazoe2023icncc}." (abstract.tex:56-57).
- EVIDENCE FOUND: the endpoints are different quantities, per the authors' own records. TSSA's 0.57 Mbps is measured with heavy loss: O "64 B loss 27.8–44.7%" (`RELATED-WORK.md:38`); ICNCC's 1.4 Gbps is a mean ceiling: O "均值天花板 ~1.4 Gbps" (`RELATED-WORK.md:37`). The study concedes: O "文獻 2,500× spread 的一部分可能只是兩個量的混用" (`2026-08-29_bmv2-performance-study.md:438-439`). In the abstract, the caveat lives only in fig4's caption ("quantity types mixed", make_figs.py:168), and fig4 is not included in the abstract.
- ADDITIONALLY: TSSA's "64 B" is iperf buffer length = UDP *payload*, not a frame, per the authors' own reading: O "TSSA 自述其 64/128 B 是 iperf「buffer length」〔O〕＝ UDP payload 不是 Ethernet frame" (`2026-08-29_bmv2-performance-study.md:150-151`). The abstract calls it "0.57 Mbps at 64 B" (abstract.tex:56) and later presents the TSSA pps conversion ("one paper's own two sizes imply near-constant pps", abstract.tex:143-144) without noting the payload-vs-frame issue — ironic given the paper's own thesis.
- WHAT IS MISSING: one sentence: "endpoints are not the same quantity (zero-loss vs mean ceiling, frame vs payload)".
- MINIMAL FIX: add the quantity-type and payload-vs-frame caveat to §1; otherwise a reader will treat 2,500× as a like-for-like spread, which the authors' own §5-6 says it is not.

### A5. 🟠 The 12× is a pilot (n=1-2, raw data not saved) that is reported in the same breath as the preregistered measurements, without disclosing that its raw does not exist.

- CLAIM: "the officially recommended compile configuration versus a default-style build is $12\times$ on a three-hop production path" (abstract.tex:33-35); "on our three-hop production path the UDP zero-loss point differs $12\times$" (abstract.tex:114-115). Table 1 labels the row "pilot" (abstract.tex:106) but nothing in the abstract discloses that the pilot's raw data was never archived.
- EVIDENCE FOUND: 12× = 300/25 Mbps UDP zero-loss, 1400 B, 3-hop, from `2026-08-15_bmv2-performance-report.md:66`. The pilot's raw is gone: O "原始 JSON 與 per-switch 證據：session scratchpad …（session 結束即失效；關鍵數字已全數載於本節）" (`2026-08-15_bmv2-performance-report.md:96-97`); O "08-15 報告：**raw 未保存**" (`2026-08-29_bmv2-performance-study.md:425`).
- WHY IT MATTERS: the abstract's own proposed provenance minimum ("Raw data is content-hash archived", abstract.tex:92) is violated by one of its two headline numbers. A PC member can note the paper criticizes 18 papers for unreconstructable measurements while resting the "12×" on an unarchived pilot.
- ADDITIONAL CONFOUND: the 12× (3-hop, 4-host production stack with proxy pushing routes, kernel polling, sFlow clone — `2026-08-15_bmv2-performance-report.md:58-61`) is compared against R=8.0 (1-hop, 128-host topology, ①b harness) to derive "part of the production-path ratio is not the compiler flags" (abstract.tex:36-37). Path length is not the only difference: topology size, harness generation, and auxiliary processes all differ across the two experiments. The abstract's "this abstract attributes it to neither" (abstract.tex:120-121) is honest about the *cause*, but the comparison itself still conflates three variables, not two. (Task category (ii).)
- MINIMAL FIX: either re-run the 3-hop production path under the ①b protocol with raw archiving, or demote 12× in the abstract to "pilot, n=1-2, raw not retained, three additional stack variables uncontrolled".

### A6. 🟠 "clean-rate pps varies 1.25×" / "packets per second are flat" overstates the instrument's resolution; the authors' own findings say the cells are "indistinguishable at ±1 rung".

- CLAIM: "across 64/256/1024\,B frames, clean-rate pps varies $1.25\times$" (abstract.tex:37-38); figure caption: "packets per second are flat ($\times1.25$)" (abstract.tex:126-127).
- EVIDENCE FOUND: the mean cells 16.0/20.0/16.0 kpps come from arm pairs 20/12, 20/20, 12/20 (`FINDINGS.md:16-20`). The authors' own threat assessment: O "The within-cell spread equals the between-cell spread … **The honest statement is that the three sizes are indistinguishable at ±1 rung**" (`packet-size-sweep/FINDINGS.md:124-128`). A ×1.5 ladder rung is the instrument resolution, and 1.25× < one rung. The abstract presents the mean variation as a measured quantity and drops the ±1-rung caveat.
- ALSO: the 16.0× bit-rate spread is threshold-fragile: O "the 1024 B pass B confirmation scored a median of 0.4969% against a 0.5% clean threshold … Had it read 0.5001 … moving the 1024 B mean from 16.0 to 14.0 and P(1024)/P(64) from 1.00 to 0.88" (`packet-size-sweep/FINDINGS.md:130-133`). The abstract's "span $16.0\times$" (abstract.tex:38) rests on that wafer-thin cell and the caveat is absent. (Task category (iv): six arms/means are being used to justify a resolution the instrument cannot support.)
- MINIMAL FIX: state "the three sizes are indistinguishable at ±1 ladder rung (span ≤1.25× in pps), while the identical cells span 16.0× as bit rate"; disclose the 0.4969%-vs-0.5% cell.

### A7. 🟠 The method paragraph (abstract.tex:85-92) generalizes disciplines that only the build experiment (①) actually implemented. Three sub-claims are false for ② and/or ③.

- CLAIM (abstract.tex:85-92): "the replication unit is the interleaved arm (fresh fabric per arm)"; "the running binary is identified by symbol signature against a negative control, never by PATH"; "CPU gates use per-process attribution, trusted only after a positive control made them fire."
- EVIDENCE FOUND:
  - "fresh fabric per arm" — true only for ① (`drive_p1.sh:72-75` runs `ndt down`/`ndt up` per arm). ②'s driver (`drive_p2.sh`) contains no fabric restart, and ③ explicitly ran all ten arms on one fabric: O "Same fabric throughout" (`flow-count-capacity/FINDINGS.md:8`). ③'s driver also has none (`drive_p1_3.sh`).
  - "symbol signature against a negative control, never by PATH" — only `run_build_arm.sh` does this (`EventLogger` bidirectional check, `run_build_arm.sh:61-86`). `run_size_arm.sh` and `run_flowcount_arm.sh` contain no symbol check; they record `switch_binary=$(pgrep -af 'simple_switch_g[r]pc' | head -1 | grep -o …)` — i.e. identity *from argv*, exactly the PATH-like evidence ① rejects (`run_flowcount_arm.sh:73`; grep for `EventLogger` in both scripts: no matches).
  - "CPU gates use per-process attribution, trusted only after a positive control made them fire" — false for ③: its gate was the old total `/proc/stat` busy fraction, had no positive control, and was shown to fire on the cell's own forwarding load: O "this round had no working detector for foreign CPU contamination" (`flow-count-capacity/FINDINGS.md:136-140`); O "per-process 歸因屬 ①②，未回溯套用" (`FINDINGS.md:139`).
- WHAT IS MISSING: per-experiment scoping of the method claims.
- MINIMAL FIX: "In the build experiment each arm ran on a fresh fabric; in the sweep and flow experiments arms shared one fabric. Symbol-level binary identification and per-process CPU gates were applied in ①/②; ③ used argv identification and had no validated foreign-load detector."

### A8. 🟡 "none of the 18 papers states what limited its measurement" — NO BACKING FOUND in the literature-review artifact.

- CLAIM: "none of the 18 papers states what limited its measurement" (abstract.tex:42-43); repeated at abstract.tex:174-175.
- EVIDENCE FOUND: the per-paper coding tables code variant / version / build flags / axes / numbers (`RELATED-WORK.md:32-42`, `SEARCH-ROUND-1.md`, `SEARCH-ROUND-2.md`) but contain no column or per-paper note on "states what limited its measurement". No such coding exists anywhere in `audit/2026-08-28_bmv2-literature-review/` (searched). The statement appears as prose in the study report §5-7 (`2026-08-29_bmv2-performance-study.md:452-454`) with no per-paper evidence attached.
- MINIMAL FIX: either add the per-paper coding to the review artifact (one row per paper: does it state its generator/limit?) or soften the abstract to what is actually coded.

### A9. 🟡 "R=8.0 … knee ${\approx}7.8$" — the knee value is presented without its self-attached caveats, and the interval spans the registered decision boundary.

- CLAIM: "it is $45$ vs.\ $360$ Mbit/s: $R=8.0$, zero spread across arms, quantisation interval $(5.14,12.0)$, knee-shape interpolation ${\approx}7.8$" (abstract.tex:115-117); Table 1 row (abstract.tex:104-105).
- EVIDENCE FOUND: all numbers exist in `FINDINGS-1b.md:27` (R=8.0), `:65-69` (interval (5.14,12.0)), `:96-105` (≈7.8). But the authors' own corrections state: the interval contains the H1/H2 boundary 9 ("The H1/H2 boundary of 9 is inside that interval", `FINDINGS-1b.md:71`; "The decision rule was missing a branch", `:79`), and the knee interpolation "is **supporting evidence, not a measurement**" (`FINDINGS-1b.md:102-105`). The abstract reports the interval (good) but asserts the conclusion and the 7.8 without the "supporting evidence / lower bound" qualifier.
- MINIMAL FIX: add "the interval (5.14,12.0) spans our preregistered H1/H2 boundary; the ≈7.8 knee reading is supporting evidence, not the registered readout."

### A10. 🟡 Minor: "even one lab's adjacent papers differ 1.7× per switch with no build stated" omits that the two papers also used different machines.

- CLAIM: abstract.tex:68-69.
- EVIDENCE FOUND: the 1.7× (1.217 ms vs 729.4 µs per-switch RTT) is in the survey (`2026-08-29_bmv2-performance-study.md:66-67`), but the survey notes the confound: O "不同機器、皆無 build 資訊" (`SEARCH-ROUND-1.md:19`). The abstract attributes the 1.7× rhetorically to the missing build variable while the papers differ in machine too. Their own wording discipline ("否定句主詞＝the 18 surveyed papers") is fine, but the 1.7× sentence is presented as build-evidence.
- MINIMAL FIX: "differ 1.7× per switch (different machines as well as no build stated)".

### A11. 🟡 "the officially recommended compile configuration" — the measured fast binary is not exactly the official configuration; it adds `-march=native`, which the abstract never discloses.

- CLAIM: "\emph{fast} is the officially recommended composite configuration (\texttt{-O3 --disable-logging-macros --disable-elogger})" (abstract.tex:112-114).
- EVIDENCE FOUND: the actual fast binary's flags: O "optimisation | `-O3 -g -DNDEBUG -march=native -fno-semantic-interposition`" and "logging macros / elogger | off (`--disable-logging-macros --disable-elogger`)" (`bmv2-binary-provenance.md:24-25`). `-march=native` bakes in this machine's ISA and makes the binary non-portable and not byte-reproducible: O "The fast build is **not byte-reproducible** … `-march=native` bakes in this machine's ISA" (`bmv2-binary-provenance.md:125-127`). The study likewise concedes "12–18× 這個值不可外推到別的機器" (`2026-08-29_bmv2-performance-study.md:402`), but the abstract's build sentence hides the machine-specific flag.
- MINIMAL FIX: list the full flag set and state "-march=native; results not claimed transferable across CPUs."

---
## (B) CITATION CORRECTNESS AND HYGIENE

Global findings first (all file:line from `refs.bib` and `abstract.tex`):

- 🟠 **TODO placeholders inside the draft and the bib.** `abstract.tex:19` ("TODO: confirm affiliation wording with advisor"), `:21` (`\email{TODO@example.edu}`), `:23` ("TODO: second author (advisor) pending consent"). `refs.bib:51-52` — the entire `fernando2025network` author list is `{Fernando, TODO and Xiao, TODO and Spring, TODO and Che, TODO}` and the title is `{TODO: verify full title and author first names …}`. `refs.bib:65` — `note = {TODO: verify author list from PDF (page 1 is image-based)}`. NOTES.md itself confirms both are outstanding (NOTES.md:46-51).
- 🟠 **Truncated author lists inside the bib (not "et al.", but equivalent):** `refs.bib:61` (`K{\"o}hler, Thomas and others`) and `refs.bib:69` (`Iannone, Luigi and others`). Both are literal truncations; neither list can be considered complete. The repo cannot supply the missing names (the full-text PDFs are outside the repo and unparseable here) — must be fixed from the PDFs before submission.
- ✅ **\cite-key integrity:** all 11 keys used in abstract.tex (`hasnaa2023tssa`, `kumazoe2023icncc`, `chen2025tomacs`, `chen2023pads`, `fernando2025network`, `waind2024pads`, `waind2026pads`, `bmv2repo`, `zhang2021benchmarking`, `mytkowicz2009wrong`, `kohler2018p4cep` — abstract.tex:57,64,65,69,73,79,81,133,142,144) have matching entries; no bib entry is uncited.
- ✅ No literal "et al." appears in refs.bib. No FIXME/XXX/?? markers found.

Per-entry table (venue/year judged against the authors' own corpus records in `audit/2026-08-28_bmv2-literature-review/MANIFEST.md` and `RELATED-WORK.md`; I cannot parse the PDFs themselves):

| key | authors complete? | year plausible? | venue correct / own style? | other |
|---|---|---|---|---|
| `chen2025tomacs` | ✅ 4 authors (Chen, Hu, Qu, Jin) match corpus row TOMACS25 | ✅ 2025, vol 35(2) | ✅ journal name "ACM Transactions on Modeling and Computer Simulation" correct | no DOI/article no./pages — hygiene gap |
| `chen2023pads` | ✅ 3 authors match corpus PADS23 | ✅ | 🟡 "Proc. ACM SIGSIM-PADS" is an abbreviation; the series' own name is "ACM SIGSIM Conference on Principles of Advanced Discrete Simulation (SIGSIM-PADS '23)". Year/location/DOI/pages missing | title matches corpus |
| `waind2024pads` | ✅ 4 authors match corpus PADS24 | ✅ | 🟡 same abbreviated booktitle, no year/DOI/pages | — |
| `waind2026pads` | ✅ 2 authors match `SEARCH-ROUND-1.md` ("Waind & Jin") | ✅ 2026 (PADS '26 PDF `3806789.3810263.pdf` in corpus; plausible) | 🟡 same as above | — |
| `kumazoe2023icncc` | ✅ 3 authors match corpus ICNCC23 | ✅ | 🟡 "Proc. 12th International Conference on Networks, Communication and Computing (ICNCC)": the "12th" numbering is **unverifiable from the repo**; no DOI/pages | — |
| `hasnaa2023tssa` | ✅ 3 names consistent with corpus TSSA23; author-order (surname-first) unverifiable from repo | ✅ 2023, DOI `10.1109/TSSA59948.2023.10366975` matches MANIFEST exactly | ✅ "17th International Conference on Telecommunication Systems, Services, and Applications (TSSA)" — 2023 was the 17th TSSA | DOI present (only entry with one) |
| `fernando2025network` | 🔴 authors are the literal string "TODO" (`refs.bib:51`) | ✅ 2025, vol 5 | 🟡 journal name "Network (MDPI)" fine, but `number = {1}` conflicts with the authors' own corpus record "MDPI Network **5(21)**" (`MANIFEST.md:33`, `SEARCH-ROUND-1.md:20`); `pages = {21}` looks like the article number repurposed | 🔴 title is TODO; cannot ship |
| `kohler2018p4cep` | 🔴 "and others" — truncated (`refs.bib:61`); bib's own note says list is unverified | ✅ 2018 | 🟡 "Proc. ACM SIGCOMM Workshop on In-Network Computing (NetCompute)" ≈ right (NetCompute '18 co-located with SIGCOMM) but no pages/DOI | 🔴 TODO note at `refs.bib:65` |
| `zhang2021benchmarking` | 🔴 "and others" — truncated (`refs.bib:69`); at least one author omitted | ✅ 2021, Computer Networks vol 188, article 107861 — matches corpus COMPNET21 | ✅ journal name correct | the omitted author(s) cannot be enumerated from the repo |
| `mytkowicz2009wrong` | ✅ 4 authors, complete | ✅ 2009 | 🟡 "Proc. ASPLOS" terse (no edition "ASPLOS '09" in booktitle, no location/pages/DOI) | title exact |
| `bmv2repo` | ✅ organization author | ✅ accessed 2026-08-29 | n/a (misc/URL) | fine as a @misc |

Additional notes:
- `refs.bib:1-3` claims "Titles verified against the PDFs … except where marked TODO" — consistent with NOTES.md:46-51; but the two TODO entries (`fernando2025network`, `kohler2018p4cep`) are both **cited in the abstract** (abstract.tex:65 and :142), i.e. the draft currently cites entries whose titles and author lists are placeholders.
- The `chen2025tomacs`/`chen2023pads` claim pairing in abstract.tex:64 ("one line of work measures Open vSwitch two orders of magnitude above bmv2") relies on OVS 30 Gbps vs ~170 Mbps from the corpus table (`2026-08-29_bmv2-performance-study.md:105`): ~176×, so "two orders" is fair.

---
## (C) REPRODUCIBILITY / ARTIFACT EVALUATION

For each item a stranger needs to reproduce every number: is it on disk, and is it stated in the abstract (abstract.tex) / study docs? Then the exact sentence that should be added.

| # | Item | On disk? | Stated in the draft? | Sentence to add |
|---|---|---|---|---|
| C1 | bmv2 source commit | ✅ `f0b7d201`, recoverable from both binaries' `--version` (`bmv2-binary-provenance.md:18,40-41`) | ❌ abstract never names it | "bmv2 commit f0b7d201 (1.15.3); both binaries embed it in `--version`." |
| C2 | binary identity (sha256) | ✅ stock `327fa7d1…`, fast `3ff54b5c…` (`bmv2-binary-provenance.md:19`); recorded per arm in `arm.meta` | ❌ abstract says "identified by symbol signature" (abstract.tex:88) but gives no hashes | "stock sha256 327fa7d1, fast sha256 3ff54b5c." |
| C3 | full configure/compiler flags | ✅ stock: `./configure --with-pi --with-thrift … 'CXXFLAGS=-O0 -g'` (`bmv2-binary-provenance.md:35-37`); fast: `--prefix=/usr/local/bmv2-fast --with-pi --with-thrift --disable-logging-macros --disable-elogger 'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition'` (`2026-08-15_bmv2-performance-build-public-manual-draft.md:50-52`) | 🟡 partial — abstract gives `-O0` vs `-O3 --disable-logging-macros --disable-elogger` (abstract.tex:111-114) but omits `-DNDEBUG`, `-march=native`, `-fno-semantic-interposition`, and the `--with-pi --with-thrift`/prefix configure lines | "fast additionally used `-DNDEBUG -march=native -fno-semantic-interposition`; both builds were installed to separate prefixes with `--with-pi --with-thrift`." |
| C4 | fast binary not byte-reproducible | ✅ documented: build tree gone, `-march=native` (`bmv2-binary-provenance.md:125-127`) | ❌ not disclosed | "The fast binary cannot be rebuilt byte-identically (build tree discarded, `-march=native`); the installed artifact sha256 is the artifact of record." |
| C5 | kernel/OS/CPU | 🟡 machine described only as "14 核" (`2026-08-29_bmv2-performance-study.md:399`); no OS/kernel version or CPU model anywhere in the docs (searched audit dirs: no `uname`/`lscpu`/model records) | ❌ abstract: "one machine" (abstract.tex:31,96) | "One machine, 14-core laptop-class CPU, <OS/kernel version>, no CPU pinning/frequency fixing" (the last point is load-bearing: no frequency/affinity control is stated anywhere). |
| C6 | traffic generator + version | ✅ iperf3 via `mnexec`, `-u -b … -t 8 -l … --json` (`run_build_arm.sh:177-180`, `run_size_arm.sh:142-145`) | ❌ abstract never names iperf3 at all; version recorded nowhere in the repo (searched) | "Traffic: iperf3 <version>, UDP, 8 s steps, JSON output." |
| C7 | frame-size definition and pps↔bps conversion | ✅ frame = payload + 42 (14 Eth + 20 IP + 8 UDP), payloads 22/214/982 (`PREREG.md:27-34`); conversions in `make_figs.py:44-45` (kpps × bytes × 8 = Mbit/s, no preamble/SFD/IFG/FCS) | ❌ abstract says "64/256/1024 B frames" (abstract.tex:37) but never defines the frame or the conversion | "Frame = UDP payload + 42 B; Mbit/s = kpps × frame bytes × 8 (no preamble/IFG/FCS)." |
| C8 | payload size of the build and flow experiments | ✅ 1400 B payload (1442 B frame) — `run_build_arm.sh:37`, `arm.meta:9`; flow rounds also 1400 B payload (`packet-size-sweep/FINDINGS.md:57`) | ❌ Table 1 (abstract.tex:96-97) says "UDP" but no payload size — the 45/360 Mbit/s headline numbers are payload-size-dependent, which is exactly the paper's own thesis | "Both build and flow ladders at 1400 B UDP payload." |
| C9 | path length per experiment | ✅ ①: one hop h1→h2 on s1 (`run_build_arm.sh:46`); ②/③: h1→h65 via s1→s3, same 10-switch 128-host fabric, fast build (`run_size_arm.sh:45`, `flow-count-capacity/PREREG.md:28`) | 🟡 the abstract states "one hop" for ① and "3-hop prod. path" for the pilot, but never states the ②/③ path length | "The sweep and flow experiments ran on the 3-hop path h1→s1→…→s3→h65 with the control plane live." |
| C10 | P4 program under test | ✅ the fabric is the NDTwin 128-host P4 topology with kernel `a40e04ce` (recorded in `arm.meta:8,16`); the P4 pipeline program itself is never identified by name/commit in the three audit dirs | ❌ | "P4 pipeline: NDTwin's <name/commit>; kernel module a40e04ce." |
| C11 | repetitions per arm | ✅ rule: nonzero loss → 3 reps, median; exact 0 → 1 rep; top rung re-confirmed ×3 (`arm.meta:14`, `PREREG.md:208-210`); 2 arms per build / per size / per cell | 🟡 abstract gives arm counts (Table 1 "2 arms/build", fig captions) but never the 3-rep median rule | "Every nonzero-loss reading is the median of 3 reps; the reported top rung was re-confirmed 3 times." |
| C12 | clean threshold | ✅ ≤0.5% loss, 3-rep median, ambiguity window >2% (`run_size_arm.sh:39-40`) | ✅ stated in Table 1 caption ("clean = loss ≤0.5%", abstract.tex:97) | — |
| C13 | raw-data location | ✅ git commits: ① `714f98a`, ①b `ff9206c`, ② `28dd860`, ③ `6085dec` (verified in repo via `git show`; study doc:300-304) | ❌ abstract says "content-hash archived" (abstract.tex:92) and "will be released" (abstract.tex:184) without a repository, branch, or hashes | "Raw data: NDTwin-Kernel git history, commits 714f98a/ff9206c/28dd860/6085dec; per-arm sha256 recorded in each arm.meta." |
| C14 | harness source commit(s) | ✅ drivers/scripts in-repo; findings pinned to `52d87ee`/`e82ac6f`/`eb71e36`/`c3bfe50`/`387d3ea` (study doc:300-304) | ❌ | "Harness: <repo URL> @ <commit>." |
| C15 | OvS comparison apparatus (version, config, shaping) | ✅ OvS half ran on the shaped as-configured testbed with `bw=1000`/htb (`03_ovs_PREREG.md:9-13`); OvS version not recorded anywhere found | ❌ abstract references "an earlier measurement" (abstract.tex:162) with no pointer; nothing states OvS version or that links were shaped | "Earlier OvS measurement on the shaped testbed (htb bw=1000), OvS <version>, not same-ladder." |
| C16 | 18-paper corpus reproducibility | ✅ PDF identities + sha256 in `MANIFEST.md`; regeneration via `raw/README.md` + `sweep_keywords.sh` | ❌ abstract gives no pointer to the corpus manifest | "Survey corpus: 18 PDFs, sha256-listed in doc/audit/2026-08-28_bmv2-literature-review/MANIFEST.md." |
| C17 | registered protocols | ✅ PREREG.md / PREREG-1b.md / AMENDMENTs in each audit dir, with pre-data commit hashes | 🟡 abstract asserts preregistration (abstract.tex:85-87) but no link/hash | "Preregistrations: <paths> at commits <hashes>." |
| C18 | pilot 12× provenance | 🔴 pilot raw never saved (`2026-08-15_bmv2-performance-report.md:96-97`) | ❌ table says "pilot" only (abstract.tex:106) | "Pilot raw data was not retained; the 12× is n=1-2 from 2026-08-15." |

**AE verdict framing (the three most damaging omissions):**
1. The abstract's own proposed "four-line provenance minimum — build (flags/commit), unit (pps with the frame size), placement, limit" (abstract.tex:180-183) is **not met by the abstract itself**: it gives no commit (C1), no frame-size definition (C7), no payload size for its headline build numbers (C8), no path length for ②/③ (C9), and a "limit" section that is about the ladder rather than machine/generator specification (C5/C6).
2. The flagship artifact (fast binary) cannot be rebuilt identically (C4) — for an AE, "flags + commit" as proposed by the authors are insufficient provenance; the binary hash must accompany any release, and `-march=native` must be disclosed.
3. The pilot 12× has no raw data at all (C18); an AE can only reproduce the 8.0 and the ②/③ numbers, not one of the two headline claims.

---

## Severity ranking (summary)

🔴 Blocking (must fix before submission):
1. A1 — OvS "matched working points does not [decline]" is unsupported: no same-testbed OVS arm, different ladder/placement, and the OvS data actually shows per-flow decline (aggregate is what does not collapse).
2. A2/A3 — survey population mischaracterization ("18 papers that measure or relay bmv2 throughput"; "All 18 report Mbps") is falsified by the authors' own census table and Mpps-based corpus entries.
3. A7 — the method paragraph credits all three experiments with ①-only disciplines (fresh fabric per arm, symbol-signature identification, validated per-process CPU gates).
4. B — `fernando2025network` and `kohler2018p4cep` are cited in the abstract while still containing TODO author lists/titles; plus "and others" truncations in two entries.

🟠 Major:
5. A5/A11/C18 — the 12× is an unarchived pilot presented beside preregistered data; the measured fast build has undisclosed `-march=native` etc.
6. A4 — 2,500× spread mixes quantity types (their own §5-6 concession), and TSSA's "64 B" is a payload, not a frame.
7. A6 — "flat (×1.25)" overstates ±1-rung resolution; 16.0× bit-rate spread rests on a 0.4969%-vs-0.5% cell.
8. C1-C17 — nearly every AE checklist item is absent from the abstract (commits, flags, OS/CPU, iperf3 version, frame definition, reps, archive pointer).

🟡 Minor: A8 (no backing for "none states what limited its measurement"), A9 (knee 7.8 caveat), A10 (1.7× machine confound), missing DOIs/pages in bib entries.
