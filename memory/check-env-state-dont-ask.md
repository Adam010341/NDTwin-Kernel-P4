---
name: check-env-state-dont-ask
description: "Adam expects me to determine which stack is running (OVS vs P4, what holds which port) from the documented commands, not to ask him."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b955baee-a646-4fe6-9986-df69b65478e6
  modified: 2026-08-10T05:29:09.068Z
---

**Work out the environment state myself before asking.** On 2026-08-10 I asked "is the running
stack OVS or P4?" and Adam's answer was that I should be able to tell. I could: `pgrep -ax
ndtwin_kernel` shows the `--topology` argument, which names the OVS or the P4 file outright, and
the rest follows from `pgrep -ax simple_switch_g`, `pgrep -af "[r]yu-manager"`,
`sudo -n ovs-vsctl list-br` and `ss -ltn` on 8000/8080/8081/6653/6633 plus the bmv2 range
50051-50060.

Two traps that make the answer look ambiguous when it is not, both already in
`doc/2026-07-29_environment_gotchas.md`: `pgrep -f <pattern>` matches **my own shell** when the pattern is in
the command line (it did — a `pgrep -af "uvicorn|proxy_agent"` "found" a proxy that was my own
`bash -c`), so use `-x` or the `[b]racket` trick; and `comm` truncates at 15 characters, so
`simple_switch_grpc` never matches and `simple_switch_g` does.

**Why:** asking costs a round trip and hands back work that is mine. The state is fully observable,
and asking implies otherwise.

**How to apply:** run the checks in `doc/2026-07-29_HANDOFF.md` §5 first, state the conclusion with the
evidence, then ask only about what genuinely needs a human — starting Mininet, `sudo mn -c`, and
anything else outside the NOPASSWD list (`ovs-vsctl`, `ifconfig`, `mnexec` only). Related:
[[cited-line-numbers-are-not-evidence]] (same habit applied to docs).
