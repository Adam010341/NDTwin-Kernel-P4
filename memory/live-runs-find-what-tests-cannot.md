---
name: live-runs-find-what-tests-cannot
description: "In this project, nearly every real bug was found by running the stack for real, not by unit tests — the failures are silent, so green tests prove little"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-13T02:32:11.370Z
---

On 2026-07-29 a full pre-Phase-6 test pass of NDTwin-Kernel found **9 defects. 8 of them were found by actually running the stack**, not by the 153-test suite, which was green throughout. Only one (a `countdown` helper that silently skipped its own wait) came from an automated review.

The ones that mattered most:
- `stack.sh` still fed the pre-Phase-1 stdin prompts, so the kernel exited instantly on every `stack.sh up`.
- Ryu was started without `ryu.app.rest_topology` **and** `ryu.app.ofctl_rest`, so `/v1.0/topology/*` and every `/stats/flow*` call 404'd. The kernel fed the 404's HTML to `json::parse`, caught the throw, and returned — meaning no flow install had *ever* reached OVS through this harness.
- Fixing that immediately exposed a latent **null-deref segfault** in `Classifier.cpp`: `outputPorts.front()` on Ryu's table-miss rule (`"actions": []`), inside a `SPDLOG_LOGGER_TRACE` whose arguments are evaluated even when the level is off.
- P4 mode's startup order was inverted (bmv2 is the gRPC *server*, so Mininet must precede the proxy).
- `write_clone_session()` sat outside `if push_config:`, so all ten clone sessions were programmed before any pipeline existed.
- `p4_testbed_topo.py` printed "10 BMv2 Switches listening" unconditionally while s10 was dead from a port conflict.
- `compare_baseline.py` crashed on the very shape difference it exists to detect.

**Why:** the failure mode in this codebase is overwhelmingly *silent* — HTTP 404s parsed as JSON, unconditional success banners, `baseline` printing "all layers passed" because capturing never fails, trace logs that look disabled but still crash. Unit tests here verify *contents* (what a request says) but not *timing or wiring* (whether it is sent, when, or whether anyone is listening). Both the identity-port-mapping dead code and the clone-session ordering bug had passing tests over the exact function that was broken in situ.

## The strongest instance yet, and the wrong conclusion I drew first (2026-08-10)

Broke a mid-path link under live traffic. **Every API check stayed green** — edge count correct
(35/40), 12 destination paths still advertised, watchdog fired, the proxy recomputed
`1 6 10 7 4` → `1 6 9 8 4` and pushed it to the kernel twice. Meanwhile **the packets were being
dropped**: P4 mode never reinstalls routes, so the switches kept forwarding into the dead link.
`install_initial_routes()` has one caller, guarded by `if not edge_exists` — discovery only.

**I first reported the opposite**, blaming a stale path cache in the kernel, because I ran
`tail -1` on the ping log and saw a reply line. That line was stale output from before the break;
ping had already stopped. The kernel's path was correct all along — it faithfully described where
the rules actually send packets. The proxy's path list was the fiction.

Two lessons. **A liveness check must show movement, not a value**: compare two reads separated in
time (`icmp_seq` advancing, an RX counter incrementing), never a single sample of a log tail — the
same "counter must *grow*" habit already listed below, which I failed to apply to ping. And **the
end-to-end fact outranks every API**: had the pass criterion led with "does traffic still flow",
the true finding would have been the first thing seen instead of the second.

Also on that day, three "anomalies" Adam reported turned out to be **my documentation being wrong**,
not the code: `avg_link_usage` documented as a climbing cumulative average when it is an instantaneous
mean over a denominator that changes every second; a hardcoded dpid list from a previous run's path;
and a link showing flows with zero usage, which is two fields with the same source and different
lifetimes. Check the doc's claim against the code before believing the system is broken.

## Two more, from the 2026-08-13 overnight round — including one that beat four review agents

- **readopt wipes a healthy switch and reports success.** Three static agents had verified the
  endpoint that same night — exists, wired end-to-end, message pasteable — and one had run 7/7
  mutants against its tests. All green, all真. The defect was *behavioral*: arbitration refused
  → pipeline push applied anyway (tables erased) → every route write refused → `"success"`.
  Only agent A's live call, plus a control experiment on an uncontaminated switch, could see it.
  Static verification answers "is it built as described", never "does the sequence hold against
  a live peer that already has a primary".
- **Unidirectional link loss blackholes traffic for 291 s while the twin reports the flow at
  9–15 Mbps.** Found because agent C refused to over-read an ambiguous 44.5 s observation and
  re-ran with the duration extended past the detection window — the discipline of "observation
  insufficient, extend the experiment" is what converted a shrug into the night's biggest P0.
  No scripted test injected asymmetry; every existing failure test was bidirectional.

Tally: the pre-Phase-6 pass was 8/9 live; this round's three real defects were 3/3 live-found
(the static agents' genuine catches were doc rot and process hazards — valuable, different class).

**How to apply:** when the user reports something odd, or before declaring a phase done, run the real stack and read the logs and counters — don't infer from a green suite. Specific habits that paid off: grep the log for parse errors and count them; check that a counter *grows* rather than merely being non-zero (`rx` vs `addressed` in the sFlow collector); resolve crashes with `journalctl` + `addr2line` rather than guessing; and after fixing, reintroduce the bug to confirm the new test actually goes red. Prefer asking the user for terminal output over hypothesising — they asked for exactly that ("需要其他terminal的資訊跟我說，不要盲猜") after I speculated about an ARP cause that [[ndtwin-static-arp-blocks-host-discovery]] later disproved. See doc/2026-07-29_environment_gotchas.md in the repo for the measurement pitfalls (`pgrep` undercounting, `tcpdump` filter counts, missing thrift bindings).
