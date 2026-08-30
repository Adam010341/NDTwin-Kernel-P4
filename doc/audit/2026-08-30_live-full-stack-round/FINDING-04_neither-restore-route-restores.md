# Finding 04 — both of `90_restore.sh`'s routes fail to restore, for different reasons

**Status: CONFIRMED, 2026-08-30 15:38–15:41.** Both routes were run, in order, against a fabric
the round had deliberately degraded. Neither brought it back. The fabric was restored by hand.

This is the **recovery** step. It runs after `25_apps_energy.sh` has powered switches off, which
is the one point in the round where the machine is left in a state someone must undo.

---

## Route 1 — `./90_restore.sh power-on`

The README's first suggestion for P4. Result:

```
switches       7 up, 10 enabled, 0 admin-disabled
links          40 total, 20 down, 0 admin-disabled
check: 2 problem(s)
  - 3 switch(es) are down
  - 20 link(s) are down
===== 90_restore: 4 check(s), 2 FAIL =====
```

The script **correctly reported its own failure** — it counted back against the pre-energy
reference and said so, rather than reporting the HTTP 200s as success. That is exactly the
behaviour `memory: power-on-reports-success-without-acting` asks for, and it worked.

The switches did not come back. The kernel's own warning allowlist carries the reason as a
known message (`warning_allowlist.txt:88`):

> `WARNING | P4 BMv2 Power ON from Kernel is currently a stub`

⚠️ I could not locate that string in the worktree's `src/` or `p4_proxy/` sources, so I am
recording it as **the allowlist's claim, corroborated by the observed behaviour**, not as a
line of code I read. The distinction matters (`memory: cited-line-numbers-are-not-evidence`),
and pinning the emitting site is a loose end, not a conclusion.

⇒ **README line 80 offers `power-on` as the P4 route.** On P4 it cannot work.

## Route 2 — `./90_restore.sh --rebuild 'p4 4'`

```
===== ROUTE 2 -- full rebuild =====
  FAIL  teardown left       ndt down   (setsid; rc is NOT the verdict)
      bmv2 processes remaining: 0
0 bmv2 process(es) running. bmv2 survives 'mn -c'; do not bring a new fabric up on top of them.
===== 90_restore: 2 check(s), 1 FAIL =====
```

Read that failure message closely: it says *"teardown left … 0 bmv2 process(es) running"*. The
evidence embedded in the complaint refutes the complaint.

`90_restore.sh:78-84`:

```bash
REMAIN="$(ndt_down)"
if [[ "$REMAIN" == "0" ]]; then  ok  …
else  bad "teardown left $REMAIN bmv2 process(es) running…";  summary; exit 1
fi
```

`lib.sh:499-510`:

```bash
ndt_down() {
    info "ndt down   (setsid; rc is NOT the verdict)"     # -> stdout
    setsid "$NDT_BIN" down > "$log" 2>&1
    n="$(ps -eo comm= | grep -cx 'simple_switch_g' || true)"
    info "bmv2 processes remaining: ${n:-0}"              # -> stdout
    printf '%s' "${n:-0}"                                 # the intended return value
}
```

`info` writes to **stdout**, the same channel as the return value. `$(ndt_down)` therefore
captures all three, so `$REMAIN` is a multi-line blob that merely *ends* in `0`, and
`[[ "$REMAIN" == "0" ]]` can **never** be true.

The `else` branch then runs `exit 1` — **before `ndt_up` at line 92**. So Route 2 tears the
fabric down and stops. It leaves the machine strictly worse than it found it.

🔑 **The judgement was right and the plumbing threw it away.** The comment above the count says
*"Teardown is judged on the state of the machine, not on the word 'down'"* — a deliberate,
correct design, made in response to `ndt down`'s exit-144 behaviour — and it computed the
correct answer, `0`. Nothing was wrong with the reasoning. One shared channel discarded it.

Nearest relative: `memory: process-liveness-checks-lie-in-two-ways`, and the family of gates
that cannot go red — except this is the mirror image, **a gate that cannot go green.**

## Why neither was caught before

The harness README lists "force it red" recipes for fourteen gates. The restore gate's entry is:

> **restore verification** — Power one switch off by hand after the restore. Must FAIL on counts, not on the HTTP 200s.

That recipe tests the **failure** direction only. Route 2's defect is that its success direction
is unreachable, and no recipe in the table exercises that.
🔑 `memory: smoke-the-accept-path-not-just-refusals` — *the refusal path can be exercised for
real; the accept path often cannot*, so a guarded action needs a dry run of the **allow** branch.
This is that memory's exact shape, in a harness that was otherwise unusually careful about
red-testing its gates.

## What was actually done

`ndt up p4 4` by hand, from the pinned tree. Verified rather than assumed:

```
ok  proxy: 12/12 destination paths (stable)
ok  kernel: 10 switches, 10 up, 40 edges, 4 hosts
ok  model matches fabric: 4 hosts        <- see FINDING-01: this line carries no information
ok  data plane: h1 -> 10.0.0.2 forwards  <- this one does
up. ready
```

`/tmp/ndtwin_p4_switches.json` was gone after teardown, so no stale manifest survived into the
new fabric — the H-20 check Route 2 would have made had it reached line 86.

## Repairs, for afterwards (not applied mid-round — the instrument is mid-measurement)

* **`lib.sh ndt_down`** — send `info` to stderr, or return the count via a variable instead of
  stdout. Every helper in this library that both narrates and returns has the same hazard;
  `ndt_down` is the one that was called in a command substitution.
* **`90_restore.sh`** — do not `exit 1` on a failed teardown check without first attempting the
  bring-up, or at minimum print the recovery command. A recovery script that aborts halfway is
  worse than one that never ran.
* **README line 80** — `power-on` should not be offered as the P4 route while P4 power-on is a
  stub. `--rebuild` is the only route that can work there, once Route 2 is fixed.

[Co-developed with claude code -- Adam]
