# 09 — T-8 and T-10 acceptance evidence

Every fix below is demonstrated in **both** directions: forced RED (the gate fires when the
defect's condition is present) and forced GREEN (the gate passes when it should). The
two-direction rule is FINDING-04's lesson: *an un-greenable gate is the mirror of an
un-reddable one*, and the harness README's old force-red table only exercised one side.

**Predictions were written into this file before any fix was run.** They are in §0 and are not
edited afterwards; §2 records what actually happened, verbatim, including where a prediction was
wrong.

Base: `09c9b03` ("Three manifest rows learn what the R2 bib round verified"), branch
`t8-t10-fixes`, isolated worktree. No fabric was started; `ndt up` / `ndt down` were never run.
All evidence is from `bash -n`, from library functions driven against fixtures, and from
extracted-logic harnesses that run the real code path with the surrounding script stubbed.

[Co-developed with claude code -- Adam]

---

## §0 PREDICTIONS — written 2026-08-30, before implementing or running anything

| # | fix | forced-RED prediction | forced-GREEN prediction |
|---|---|---|---|
| P1 | `ndt` model-matches-fabric reads the fabric | with model=4 and a fabric-side count of 128, the check prints `model/fabric mismatch` and sets rc=1 | with model=4 and fabric-side 4, prints `ok model matches fabric: 4 hosts` |
| P1b | same check when the fabric reading is **unobtainable** | fabric count 0 while the model wants 4 ⇒ must go RED with a message naming the reading as unobtainable, **not** pass | (n/a — the unobtainable case has no green; a green here would be the bug) |
| P2 | `ndt:759-760` stale comment | n/a (comment) — verified by reading that the corrected text no longer claims the check catches what it demonstrably did not | n/a |
| P3 | `app_running` via `/proc` instead of `kill -0` | a pidfile naming a live pid whose `comm` is NOT the app ⇒ `app_running` false (`kill -0` would say true) | a pidfile naming a live pid whose `comm` matches ⇒ true |
| P3b | same, root-owned pid | pidfile naming a live **root** pid of another program ⇒ false (today `kill -0` returns EPERM ⇒ false *for the wrong reason*; a root pid whose comm matches must read true) | pid 1 fixture whose comm is recorded ⇒ decided on comm, not on signal permission |
| P4 | `ndtwin-lab` KERNEL_DIR | n/a (documentation) | env override, if added, must not change behaviour when unset |
| P5 | sim disk log | after `sim-start`, `.test_run/logs/app_sim.log` exists and grows | if the tee path is unwritable the start must still proceed (log is evidence, not a gate) |
| P6 | `20_apps_lifecycle.sh` real epochs | a fixture where the app serves 200 s after `T0` but only 3 s into the wait loop ⇒ old code prints `+3 s`, new code prints `+200 s` | an app that serves 2 s after its own start ⇒ per-app `t_start` shows +2 s and the T0-relative column shows the true offset |
| P7 | `port_holder` three states | a LISTEN line with **no** `pid=` ⇒ must return the sentinel, and the caller must read "bound" | a LISTEN line with `pid=N` ⇒ returns `N`; no LISTEN line ⇒ returns empty ("free") |
| P8 | `lib.sh ndt_down` channel split | with a simulated 2 leftover processes, `REMAIN` is exactly `2` and the caller takes the `bad` branch | with 0 leftover, `REMAIN` is exactly `0` and the caller takes the `ok` branch — **this is the direction that is unreachable today** |
| P9 | `90_restore.sh` does not strand | a failed teardown check must still leave a recovery attempt or an explicit instruction; the script must not `exit 1` with the fabric down and nothing said | the success path reaches `ndt_up` as before |
| P10 | `40_r5_p4.sh` manifest count | a dict manifest keyed `s1..s10` ⇒ **10**, not 0; an unrecognised shape ⇒ raises, gate goes RED | a 10-key dict against 10 bmv2 procs ⇒ gate GREEN |
| P11 | `35_r2_r3_analyse.py` `find_paths` | a body keyed `all_destination_paths` ⇒ old code finds nothing, new code finds it and records the key used | a body keyed `path` ⇒ still found (no regression) |
| P12 | `25_apps_energy.sh` degraded banner | `POWERED_OFF=3` ⇒ banner printed | `POWERED_OFF=0` ⇒ banner **not** printed, and a "nothing to restore" line printed instead |
| P13 | `25_apps_energy.sh` watch window | a slow fixture (10 s of query time per iteration) ⇒ deadline loop still spans ~`WATCH_S`, and the script reports the span it actually achieved | a fast fixture ⇒ the loop does not exit early at fewer than `WATCH_S` seconds |

### Predictions that were expected to be uncomfortable

* **P8-green is the one that has never been observed.** FINDING-04 shows the `== "0"` branch is
  unreachable, so "the caller takes the `ok` branch" has no prior instance in this repo. If it
  does not go green after the fix, the fix is wrong.
* **P1b** has no green half by construction, and that asymmetry is deliberate: the requirement is
  "fail loudly when the fabric-side reading is unobtainable", so a green there would be the
  defect returning in a new shape.

---

## §1 What was NOT verified (stated before the results, so it is not a post-hoc excuse)

* **No live fabric.** Nothing here proves the fixed `ndt` check behaves correctly against a real
  128-host fabric; it proves the comparison now consumes a fabric-side quantity and fails when
  that quantity disagrees or is unobtainable. Live proof is deferred to the traffic round's
  preflight.
* **`port_holder`'s root case is fixture-verified, live proof deferred to the traffic round's
  preflight.** Producing a genuinely root-owned listener needs sudo and a fabric; the three-state
  logic is driven against recorded `ss` output instead.
* **The installed `/usr/local/sbin/ndtwin-lab` is untouched** (root owned). Every fix here lands
  in the repo copies only. See §3 for what that means for when each fix takes effect.

---

## §2.1 — T-8 (1): `model matches fabric` now reads the fabric (FINDING-01)

`tools/test_workflow/ndt`, `verify_p4()`. The fabric-side reading chosen is
**`fabric_host_count()`** — host namespaces counted out of `ps`. Justification is in the code
comment; in short: it is the quantity FINDING-01 counted by hand to establish the defect (128),
it is already the reader that decides fabric reuse and gates the OVS build so the fix adds no
third opinion, the manifest is keyed by switch and cannot answer a host question at all, and
veth count needs a per-topology constant to interpret.

**Unobtainable is RED.** `fabric_host_count` returns 0 when `ps` yields nothing or when the
`mininet:h<N>` argv convention changes; a fabric this function just built always has ≥1 host, so
0 means the reading failed, and a failed reading must not print `ok`.

### Method

The comparison block is extracted **verbatim from the shipped file by `sed`** and `eval`'d with
`fabric_host_count` stubbed — that stub is the seam, since the whole finding is that the real
function was never called. Harness:
`scratchpad/t8_check.sh`.

⚠️ The first extraction anchored on `local live_hosts; live_hosts="$(fabric_host_count)"`, which
is **not unique** — `up_p4` has a byte-identical line — and it pulled the reuse block instead.
It failed loudly (`topo_session: command not found`, `n: unbound variable`) rather than testing
the wrong code and reporting green. Re-anchored on the comment sentence above the block.

### Forced RED and GREEN — verbatim

```
### FORCE-RED   model 4 vs fabric 128 (the exact 08-30 false pass)   (fabric=128 kernel_graph=4 topo_file=4)
  XX  model/fabric mismatch: kernel graph has 4 hosts, topology file has 4, the FABRIC has 128 host namespaces
    -> rc=1

### FORCE-RED   fabric reading unobtainable (count 0)   (fabric=0 kernel_graph=4 topo_file=4)
  XX  model/fabric UNCHECKED: no fabric-side host count obtainable (fabric_host_count gave '0').
  XX    the kernel graph says 4 hosts and the topology file says 4, but neither is the fabric.
  XX    this is reported as a failure on purpose: an unverifiable check must not print ok.
    -> rc=1

### FORCE-RED   fabric reading not a number   (fabric= kernel_graph=4 topo_file=4)
  XX  model/fabric UNCHECKED: no fabric-side host count obtainable (fabric_host_count gave '<empty>').
  XX    the kernel graph says 4 hosts and the topology file says 4, but neither is the fabric.
  XX    this is reported as a failure on purpose: an unverifiable check must not print ok.
    -> rc=1

### FORCE-GREEN model 4, fabric 4, topo 4   (fabric=4 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
    -> rc=0

### FORCE-RED   kernel graph disagrees with topo file   (fabric=4 kernel_graph=4 topo_file=8)
  XX  model/fabric mismatch: kernel graph has 4 hosts, topology file has 8, the FABRIC has 4 host namespaces
    -> rc=1
```

### The control that makes the RED mean something

"It goes red now" is not evidence unless it could not go red before. The pre-fix block, copied
verbatim from `09c9b03:tools/test_workflow/ndt:722-727`, against the same three inputs:

```
### OLD CODE, model 4 vs fabric 128 (the 08-30 false pass)   (fabric=128 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0

### OLD CODE, fabric reading unobtainable (count 0)   (fabric=0 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0

### OLD CODE, fabric 4 (correct)   (fabric=4 kernel_graph=4 topo_file=4)
  ok  model matches fabric: 4 hosts
    -> rc=0
```

🔑 **Three different fabrics, one identical line.** That is the finding restated as a
measurement: the old check's output is independent of its subject.

Predictions P1 and P1b: **both held**, 5/5 cases.

### T-8 (2) — the stale comment at `ndt:759-760` (now :786-808)

Corrected in the same commit. The old text recorded the 08-21 measurement
(`ndt up ovs 16` → `"model matches fabric: 16 hosts"` over a 128-host fabric) purely as a reason
to refuse odd sizes, which reads as though the check worked for the sizes that *are* allowed.
It did not. The correction says plainly that the recorded line is evidence about the **check**,
not only about the size argument, and points at the two repairs (`verify_p4` now reads
`fabric_host_count`; `verify_ovs`'s equivalent was already renamed to *"kernel graph matches the
model file"* because for host count it is close to tautological).

The contradiction named in the ticket is confirmed by reading: `verify_ovs`'s comment
(`ndt:940-945` pre-fix) already said the name *"claimed a guarantee it does not give"* — while
`verify_p4` four hundred lines earlier still claimed it was *"the check that would have caught a
wrong TOPO_P4"*. The OVS arm was corrected on 08-21 and the P4 arm was not.

`ndt:1141`'s historical sentence (*"the kernel's graph, Ryu's topology view and 'model matches
fabric' were all correct and every host pair was 100% loss"*) was **left alone**: it is a
statement about what happened on 08-21 under the name the check had then, and it remains true.

---

## §2.2 — T-8 (3): `app_running` stops asking `kill -0` (H-17)

`ndt`: new `app_sig()` / `pid_is_app()`, `app_running` rewired onto them. `kill -0` answers a
question about **signalling permission** and was being read as a question about **existence**.

**cmdline, not comm, is the identity.** `comm` is `python3` for both nsr and te and `bash` for
viz, so it cannot tell this project's own apps apart; `comm` is kept only as the fallback when
`/proc/<pid>/cmdline` is unreadable. An **empty** cmdline (zombies have one) is not treated as a
mismatch — existence is asserted instead, which is exactly the strength `kill -0` had, without
its EPERM hole. Inventing a second false negative to fix the first would not be a fix.

### Both directions, NEW (fixed) beside OLD (`09c9b03`), on real pids

```
=== fixtures: real pids on this machine ===
  app-like pid=396573   unrelated-but-alive pid=396574   exited pid=396576   root pid=1

=== results (NEW = fixed ndt, OLD = 09c9b03) ===
GREEN  pidfile names the real app                    app=nsr  pid=396573    NEW=running      OLD=running
RED    pid recycled onto an unrelated process        app=nsr  pid=396574    NEW=not-running  OLD=running
RED    pid has exited                                app=nsr  pid=396576    NEW=not-running  OLD=not-running
RED    pidfile garbage                               app=nsr  pid=not-a-pid  NEW=not-running  OLD=not-running
RED    pidfile says 1                                app=nsr  pid=1         NEW=not-running  OLD=not-running
H-17   live ROOT-owned pid, wrong identity           app=nsr  pid=1         NEW=not-running  OLD=not-running
H-17   live ROOT-owned pid, viz has no py sig        app=viz  pid=1         NEW=not-running  OLD=not-running

=== missing pidfile / symlinked pidfile ===
RED    no pidfile at all                             NEW=not-running  OLD=not-running
RED    pidfile is a symlink (refused)                NEW=not-running  OLD=running
```

Two rows carry the whole change: **recycled pid** (OLD `running`, NEW `not-running`) and
**symlinked pidfile** (OLD `running`, NEW `not-running` — `app_stop` already refused symlinks and
`app_running` did not, so the two disagreed about the same file).

### The EPERM direction, which the table above does NOT reach

⚠️ Every root-owned row above used pid 1, which the `pid > 1` guard rejects for its own reasons —
so **the run above does not demonstrate the case H-17 is actually named for**: a live root-owned
process whose identity *matches*. Caught by re-reading the table against prediction P3b rather
than by the harness, which reported a clean sweep. Run separately:

```
fixture pid   : 392  (/usr/lib/systemd/systemd-journald )
owner         : root
/proc exists  : yes
kill -0        : FAILS (EPERM) -- and the process is alive
registered sig: systemd-journald

GREEN  live root-owned pid, identity matches   NEW=running   OLD=not-running
       ^ OLD is wrong here: it reports 'not-running' about a process that is running.
```

**Fixture-verified, live proof deferred to the traffic round's preflight.** A genuinely
root-owned *NDTwin* app cannot be started from here (needs sudo and a fabric), so a root system
daemon stands in and `app_sig` is overridden to its signature. `pid_is_app` — the logic under
test — is the shipped text; only the lookup table is substituted.

Predictions P3 and P3b: **held**, with the caveat that P3b needed a second harness to reach.

## §2.3 — T-8 (4): `ndtwin-lab`'s hardcoded `KERNEL_DIR`

Documented with a loud comment. **The env override was NOT added, and that is a finding, not an
omission.**

This file is installed root-owned at `/usr/local/sbin/ndtwin-lab` and invoked through a NOPASSWD
sudoers rule. `BRIDGE=$KERNEL_DIR/p4_proxy/mininet/ntg_bmv2_topo.py` is **executed as root**.
Letting the environment choose `KERNEL_DIR` would let anything running as adam point root at an
arbitrary adam-writable `.py` — precisely the *"root-for-anyone-who-can-write-a-file"* shape the
script's own header says the design exists to avoid. And `sudo`'s `env_reset` would drop the
variable in the normal path anyway, so the override would be **silently ineffective where it is
safe and a privilege escalation where it worked**. Both halves are bad; "trivially safe" is not
satisfied.

The comment states the real options (pass the tree as an argument plus an ownership/allowlist
check on the path, or install one copy per tree), and states the operational consequence in the
form an executor needs: **a worktree cannot be tested through this script.** The installed copy
is byte-identical to the repo copy today (`3aaa849e…`, matching FINDING-01), so this edit makes
them diverge — see §3.

## §2.4 — T-8 (5): sim gets a disk log

`ndtwin-lab sim-start` now runs the app under `script -qfa "$SIM_LOG" -c …`, writing
`.test_run/logs/app_sim.log`. FINDING-02: sim's output went **only** to its tmux pane, so when
the pane went its account of its own behaviour went with it, and "why did sim not serve" could
not be asked at all.

**`script`, not `| tee`.** A pipe makes sim's stdout a non-tty, stdio switches to block
buffering, and then both the log *and* `sim-out`'s `capture-pane` go silent until 4 KB
accumulates — trading one unreadable record for two. Verified rather than assumed:

```
=== the command line, lifted from the shipped file ===
  163:                "script -qfa '$SIM_LOG' -c ./simulation_platform_manager"

=== GREEN: does that form write a log AND keep a tty? ===
  log exists : yes
  log size   : 253 bytes
  log content:
    | Script started on 2026-08-30 19:26:51+08:00 [COMMAND="echo SIM-STARTED; tty -s && ..."]
    | SIM-STARTED
    | STDOUT-IS-A-TTY
    | Script done on 2026-08-30 19:26:51+08:00 [COMMAND_EXIT_CODE="0"]

=== GREEN: append, not truncate (a second start must not erase the first) ===
  SIM-STARTED still present: 2
  SECOND-RUN present       : 2

=== the two branches of the writability test ===
  GREEN writable dir      -> script-path (log kept)
  RED   unwritable dir    -> fallback (start anyway, no log)
  RED   path is a dir     -> fallback (start anyway, no log)
```

`STDOUT-IS-A-TTY` is the load-bearing line: it is what `| tee` would have turned into
`STDOUT-IS-A-PIPE`. **The log is evidence, not a gate** — the two RED rows show sim still starts
when the log cannot be opened, with the loss stated on stdout. A logging change able to stop the
app from starting would be a worse defect than the one it fixes.

### A defect the red case exposed in the fix itself

The first version of the writability probe was `: >> "$SIM_LOG" 2>/dev/null`. Redirections are
applied left to right, so the append is set up — and fails — **before** stderr is silenced:

```
--- OLD order:  : >> F 2>/dev/null   (stderr below this line is the leak) ---
/tmp/.../t8_redirorder.sh: line 6: /tmp/tmp.7YhwaTCj25/ro/app_sim.log: Permission denied
   rc=1
--- NEW order:  : 2>/dev/null >> F   (nothing should appear between the markers) ---
   rc=1
--- end ---
```

A root script printing `Permission denied` from a probe that is supposed to be silent. Shipped
order is now `: 2>/dev/null >> "$SIM_LOG"`. 🔑 Found only because the RED branch was exercised
for real instead of reasoned about — the accept path alone would never have shown it.

**Live proof through `ndtwin-lab sim-start` is deferred**: it needs sudo and would start the
app. What is proven is that the exact command line the shipped code hands to tmux produces a
flushed log under a pty, and that neither failure branch aborts the start.

---

## §2.5 — T-10 (FINDING-04): the restore route that could not succeed

`lib.sh ndt_down`, `90_restore.sh`, and — newly found — `lib.sh spawn_exec`.

### The before-state, reproduced

No fabric was touched: `ndt down` is stubbed to `/bin/true` and the bmv2 count is injected.

```
--- teardown really left 0 bmv2 process(es) ---
REMAIN captured as:
    >      ndt down   (setsid; rc is NOT the verdict)
    >      bmv2 processes remaining: 0
    >0
    GATE: bad branch -> summary; exit 1  (NO ndt_up: the machine is left torn down)

--- teardown really left 2 bmv2 process(es) ---
REMAIN captured as:
    >      ndt down   (setsid; rc is NOT the verdict)
    >      bmv2 processes remaining: 2
    >2
    GATE: bad branch -> summary; exit 1  (NO ndt_up: the machine is left torn down)
```

🔑 **The `ok` branch is unreachable for every value, including the correct one.** This is the
mirror of a gate that cannot go red, and the README's force-red table had no recipe for it —
every recipe there tests the refusal direction.

### 🆕 A second instance of the same disease, which no finding had named

FINDING-04's repair note predicted it — *"every helper in this library that both narrates and
returns has the same hazard"* — and named only `ndt_down`. An audit of every call site that
captures a lib function in `$( )` found one more: **`spawn_exec`**, captured at
`20_apps_lifecycle.sh:240`. Measured:

```
TE_PID captured as:
    >  PASS  te_pty spawned as pid 398147, cmdline verified
    >398147
  [[ -n $TE_PID ]]        -> TRUE (looks like success)
  alive "$TE_PID"         -> FALSE (the wait loop breaks on iteration 1)
  PASS lines in transcript -> 0 (the ok() ran inside $( ), so nobody saw it)
  CHECKS in the parent     -> 0 (the subshell's increment did not survive)
```

It broke **four** things at once, and the fourth is the worst:

1. `TE_PID` became a blob;
2. `[[ -n "$TE_PID" ]]` still passed, so it read as success;
3. `alive "$TE_PID"` was then false, so te's 90-iteration wait loop **broke on iteration 1** —
   ⇒ **this is where FINDING-02's otherwise unexplained te value of `+1 s` comes from.** The
   loop could not reach a second iteration, so `T0 + i` could only ever be `T0 + 1`;
4. `ok()`/`bad()` ran *inside* the substitution, so their lines never reached the transcript and
   their `CHECKS`/`FAILS` increments died with the subshell — **a `bad` here was silent**, and
   the `die` on an unverifiable cmdline exited only the subshell, downgrading the H-22 abort the
   README advertises into a shrug.

Fixed by returning through the global `SPAWN_PID` rather than by moving narration to stderr:
counters cannot survive a subshell whichever channel they use. 🔑 The question to ask of any
helper is *"is it called in `$( )` anywhere?"* — if yes, it may not narrate at all.

### The after-state, both directions

```
--- FORCE-GREEN: teardown really left 0 (the branch that was UNREACHABLE before) ---
REMAIN captured as: [0]   (bare number? yes)
      ndt down   (setsid; rc is NOT the verdict)
      bmv2 processes remaining: 0
  PASS  teardown: 0 bmv2 processes remain
    -> reaches ndt_up. THE FABRIC COMES BACK.

--- FORCE-RED: teardown really left 2 ---
REMAIN captured as: [2]
  FAIL  teardown left 2 bmv2 process(es) running.

===== THE FABRIC IS DOWN AND THIS SCRIPT IS NOT GOING TO BRING IT BACK =====
      do this, in order:
        1. sudo /usr/local/sbin/ndtwin-lab cleanup
        2. ps -eo comm= | grep -cx simple_switch_g    # must print 0 before continuing
        3. sudo rm -f /tmp/ndtwin_p4_switches.json
        4. /bin/true up p4 4
    -> exits 1, but the operator has been told exactly what state the machine is in.

--- FORCE-RED: the value channel is polluted again (regression sentinel) ---
  FAIL  ndt_down returned something that is not a count: '      chatter that should not be here
0'. HARNESS fault.
  FAIL  teardown left an unknown number of bmv2 process(es) running.
```

```
--- FORCE-GREEN: a child that lives ---
  PASS  te_pty spawned as pid 398844, cmdline verified
  TE_PID              = [398844]
  is a bare pid       ? yes
  alive "$TE_PID"     ? true   (false here would break the wait loop at i=1)
  CHECKS in the parent= 5   (the PASS line survived the call)

--- FORCE-RED: a child that dies within 1s ---
  FAIL  te_dead exited within 1s -- see /tmp/.../app_dead.log
  SPAWN_PID after failure = []  (must be empty, not the stale value)
  FAIL line reached the transcript? yes
  FAILS 3 -> 4   CHECKS 5 -> 6   (both counted in the PARENT now)
```

Prediction **P8-green — the direction with no prior instance in this repo — now goes green.**
P9 held. The third RED case is a **regression sentinel**: `90_restore.sh` now asserts that what
it captured is a bare number before branching on it, and reports a polluted value channel as a
*harness* fault rather than silently taking a branch. That assertion is the check that would
have caught FINDING-04 on the first run, and it costs one test.

### Not stranding the machine

The failure path no longer does `summary; exit 1` on its own. It prints the exact recovery
sequence and states plainly that there is no fabric until step 4 completes. **The bring-up is
still not attempted automatically when processes survive** — starting a fabric over live bmv2 is
the port-conflict trap, where the next fabric fails to bind with an error that reads like a P4
problem. Refusing to auto-recover there is deliberate, and saying so is the fix.

### A defect in the fix, caught by `bash -n` discipline

The recovery message quoted `$LAB_BIN`, which **did not exist**. Under the harness's
`set -Eeuo pipefail` that is an unbound-variable abort — the recovery instructions would have
crashed on the one path where they matter. `LAB_BIN` is now defined in `lib.sh` beside `NDT_BIN`.

### Interim headers removed, and one deliberately kept

* `90_restore.sh`'s `🔴🔴 DO NOT RUN UNTIL T-10 LANDS` header and the `T-10 NOT YET LANDED`
  runtime banner are **removed** — Route 2 is fixed, so the sentence they make is false.
* Route 1's half is **still true** and was *moved to Route 1*, printed conditionally when
  `:8080` is free (i.e. a P4 run), where the operator meets it.
* `README.md` step 7 offered `power-on` as *the* P4 route. Swapped: `--rebuild` for P4,
  `power-on` for OVS with the F-7a shaping caveat.
* ⚠️ **P4 power-on remains broken and is NOT fixed here.** It is a kernel-side stub, not a
  harness defect, and out of T-10's scope. The allowlist string was not located in `src/` or
  `p4_proxy/`, so it stays recorded as the allowlist's claim corroborated by behaviour.

---

## §2.6 — T-10 (FINDING-02 Defect A): a loop counter used as a clock

`20_apps_lifecycle.sh`. Three of four rows were `T_APP = T0 + i`, where `i` is *which iteration
of a wait loop matched* and `T0` is when `ndt up` was invoked. The loop does not start at `T0` —
it starts when the script reaches that app's section, minutes later.

### Method

The **viz wait loop is extracted verbatim from the shipped file** and run twice over the same
simulated timeline: once with the old `T0 + i` line substituted back in, once as shipped.
`sleep` advances a fake clock and `date` reads it, so the timeline is exact and the test is
instant.

```
=== the timeline being simulated ===
  T0 (ndt up invoked)          = 1788073422
  this script reaches viz at   = T0 + 220
  viz then takes               = 9s of its own
  so the TRUE first-serve is   = T0 + 229

  OLD  (T0 + i)      VIZ_T=1788073432   reported as +10s   error 22x
  NEW  (date at match) VIZ_T=1788073651   reported as +229s
  TRUE                 VIZ_T=1788073651   reported as +229s

  GREEN: the fixed loop reports the true epoch.
  RED (control): the old loop was off by 219s -- it reported the loop
        iteration count, which is a property of the harness, not of viz.
```

🔑 The fixed loop lands on **1788073651**, which is *the value FINDING-02 recovered independently*
from viz's H-20 artefact signature. Two different routes to the same epoch.

### The second half of the fix, which matters as much as the first

Correct arithmetic alone would still have produced numbers that mostly measure the harness — all
three true values clustered at ≈+224…231 s because the script does not reach nsr, viz and te
until ≈`T0+220 s`. So `T_START[app]` is now recorded per app and the table carries an **`own`**
column:

```
=== the second half of the fix: the 'own' column ===
  rel viz -> +229s since T0, +9s since we started it

=== rel() on an app that never served (must not do arithmetic on empty) ===
  rel te  -> not observed serving
```

The table header is now `#app state served_epoch since_T0 started_epoch own`, and the script
prints an instruction to read `own`, not `since_T0`. PREREG §3's R-3 — *"convergence time from
`ndt up` to all five apps serving"* — is still **not** what `since_T0` contains, even with the
arithmetic fixed, and the script now says so at the point of output rather than only in a finding.

### 🔴 A bug in the fix, found by the acceptance run and not by review

The first `rel()` was written compactly:

```bash
local a="$1" t="${T_APP[$a]:-}" s="${T_START[$a]:-}"
```

`local` expands its **entire argument list before assigning any of it**, so `$a` is still unset
when `${T_APP[$a]}` is evaluated. Under the harness's `set -Eeuo pipefail` that is an abort, not
a silent empty. Isolated and confirmed:

```
--- single local statement ---
localorder.sh: line 6: a: unbound variable
```

(The split-into-two version prints `a=viz t=42`.) Split in the shipped code, with the reason in a
comment. **This would have crashed `20_apps_lifecycle.sh` on its first `ok` line.** It was caught
only because the fix was exercised rather than reasoned about.

### One more edge case, guarded

The wait loop is the authority on *when*; the `port_holder` read after it is the authority on
*who*. They can disagree — the port may bind in the gap. Without a guard, `SIM_BIND_EPOCH` would
be empty while `SIM_PID` was not, and `$(( SIM_BIND_EPOCH - SIM_START_EPOCH ))` would silently
treat `""` as 0 and print a ten-digit negative number. **`set -u` does not fire for a variable
that is set-but-empty.** The epoch is now stamped at that later reading and labelled as an
**upper bound**, not a measurement.

Prediction P6: **held**.

## §2.7 — T-10 (FINDING-02 Defect B): `port_holder`'s missing third state

**Fixture-verified, live proof deferred to the traffic round's preflight.** Producing a genuinely
root-owned listener needs sudo and a fabric, so `ss` is stubbed with **recorded** output of each
shape. The pid-less LISTEN line is the real article: it is what `ss -lptnH` prints for another
user's socket when run unprivileged, which is what FINDING-02 observed live on `:9000`.

```
=== port_holder, NEW vs OLD (09c9b03) ===
root-owned listener      (:9000)               NEW=[LISTENER-OWNER-HIDDEN]  OLD=[]
our own listener         (:8000)               NEW=[284117]                 OLD=[284117]
nothing listening        (:7777)               NEW=[]                       OLD=[]
```

🔑 `:9000` is the whole finding: OLD returns `[]`, **identical to the `:7777` "free" answer**,
while something is listening. Three states collapsed into two, and the collapsed pair is exactly
the pair a preflight must distinguish.

```
=== port_is_bound: the question the sim wait loop is actually asking ===
  port_is_bound 9000   -> true    (OLD equivalent [[ -n ... ]] -> false)
  port_is_bound 8000   -> true    (OLD equivalent [[ -n ... ]] -> true)
  port_is_bound 7777   -> false   (OLD equivalent [[ -n ... ]] -> false)

=== the sim wait loop, both code paths, driven against the stub ===
  PASS  sim is serving :9000 -- owner not visible (expected: sim runs in a root tmux session)
  PASS  sim is serving :8000 (pid 284117)
  FAIL  sim never opened :7777 -- a genuine absence of any LISTEN line, not the old blind spot

=== assert_port_is: identity is UNTESTABLE, not passed and not failed ===
  N/A   sim: :9000 HAS a listener but its owner is not visible to this uid (root-owned). Whether
        it is the pid we started (284117) cannot be decided from here -- re-run with sudo, or
        read the owner from the process that started it.
  PASS  kernel: :8000 held by the pid we started (284117)
  FAIL  kernel: :8000 is held by pid 284117, NOT the pid we started (999999) -- P-1 orphan
  FAIL  gone: nothing is listening on :7777

=== 00_preflight's 'the machine is quiet' loop ===
  FAIL  :8000 is held by pid 284117
  FAIL  :9000 HAS a listener whose owner is not visible. The machine is NOT quiet.
        Before 08-30 this printed ':9000 is free'.
  PASS  :7777 is free (no LISTEN line)
```

The sentinel is deliberately **non-numeric** so a caller that forgets to handle it fails visibly
instead of quietly meaning something else. `assert_port_is` returns **N/A (untestable)** for it —
not a pass and not a mismatch — because the P-1 question *"is the thing answering the thing we
started?"* is genuinely unreachable there, and PREREG §3 requires that third branch precisely so
"we could not reach it" is never scored as "it is fine".

`00_preflight.sh` is the caller where this mattered most and was not in the ticket: a root-owned
listener used to print `:9000 is free` from the script whose entire job is to establish that the
machine is quiet. That is the strongest possible false PASS.

Prediction P7: **held**.

---

## §2.8 — T-10 (FINDING-05): a watch window that was not 240 s, and a banner that was always on

`25_apps_energy.sh`. The watch loop and both message blocks are extracted from the shipped script
and driven against stubs; no app is started and no switch is powered off.

### The window

```
######## the watch window ########
  query cost  0s/sample -> requested 240s, ACHIEVED 240s over 25 samples
                            OLD loop would have spanned 250s and REPORTED "240s"
  query cost 10s/sample -> requested 240s, ACHIEVED 240s over 25 samples
                            OLD loop would have spanned 500s and REPORTED "240s"
```

The old loop counted iterations (`seq 0 $((WATCH_S/10))` with `sleep 10` inside) while each graph
query costs ~10 s on OVS and ~0 s on P4, so the window was whatever the fabric's response time
made it — 474 s on the real OVS run, reported as 240 s. It is now deadline-driven and **reports
the span it achieved**, written to `energy_watch_actual_seconds.txt`.

🔑 It stretched here, which is harmless — more chances for the app to act, and the report
understates its own patience. **On a faster path the same construct shortens the window
silently**, and then "nothing happened" is a statement about our patience after all, which is
exactly what the 240 s was chosen to rule out. This is the **third** instance of an iteration
count standing in for a time in this harness; it is a house style, not a slip.

### The explanation attached to the N/A

```
  quiet fabric (the real 08-30 OVS case, util 0.0):
      why: NOT TRAFFIC, cause NOT ESTABLISHED. peak 0.0% is far BELOW 0.40.
  busy fabric  (util 12.5):
      why: PLAUSIBLY TRAFFIC. peak 12.5% > LOW_WATER_MARK 0.40 -- stop traffic and re-run.
  field absent (util ?):
      why: NOT ESTABLISHED. utilisation not readable -- do not write a cause.
```

The first row is the one that was wrong. The old text asserted the traffic hypothesis
unconditionally — *"on a network carrying traffic, declining to power down is correct … stop all
traffic generation and re-run this phase"* — on a fabric with 0.0% on all 40 edges and an empty
`flows` list. There was no traffic to stop.

🔑 **The verdict was right and the explanation attached to it was wrong**, which is the more
dangerous kind: a reader takes the verdict on trust and inherits the reason with it. The peak
utilisation is now read from the graph body `graph_counts` **already fetched** — no extra request
— and the third branch says plainly that the cause is not established and lists the candidates
this run cannot distinguish.

### The banner

```
  --- FORCE-GREEN (nothing was powered off: must NOT tell the operator to restore) ---
  PASS  the fabric is NOT degraded: the app powered 0 switches off, and this script changed nothing else.
         Do NOT run ./90_restore.sh. There is nothing to restore, and its rebuild route would
         tear down a healthy fabric to fix nothing.

  --- FORCE-RED (3 switches off: must tell the operator to restore) ---
      🔴 THE FABRIC IS NOW DEGRADED: the app powered 3 switch(es) off (s9,s7,s5).
         Restore before any further measurement:
           ./90_restore.sh --rebuild '…'   (P4: the only route that works)
           ./90_restore.sh power-on        (OVS: cheaper, but F-7a leaves 4 ports unshaped)
```

Gated on the count the script had already computed; nothing new is measured to decide it.

🔑 **Harmless in isolation; not harmless in combination.** The restore this banner directed the
operator to is the one FINDING-04 shows tears the fabric down and stops. Following it on an
undegraded OVS fabric would have destroyed a healthy fabric to fix nothing. **Two defects that
are each survivable composed into one that is not** — which is the argument for fixing both in
the same round rather than ranking them.

### One more stale header, corrected

`25_apps_energy.sh:18` read *"WRITTEN, NOT RUN. `bash -n` only."* It has been run twice (P4 15:30,
OVS 15:53). `90_restore.sh` had already received exactly this correction; this file had not. The
replacement also records the `agy` contamination, so the P4-vs-OVS comparison cannot be quoted
from this script as controlled.

Predictions P12 and P13: **both held**.

---

## §2.9 — T-10: two gates that answered confidently from the wrong place

### `40_r5_p4.sh` — a missing key counted as zero switches

The manifest is written by `p4_testbed_topo.py:458-469` as a dict **keyed by switch name** —
`{"s1": {...}, …, "s10": {...}}` — with no `switches` key anywhere. The gate read
`d.get("switches", [])`, got its default, and `len([])` produced a confident **0**, which went
straight into a comparison against the bmv2 process count.

```
manifest shape                                           NEW            OLD (09c9b03)
--------------------------------------------------------------------------------------------
the REAL shape: 10 switches keyed s1..s10                10             0
legacy list of 10                                        10             10
wrapped: {"switches":[...3 items...]}                    3              3
genuinely empty dict {}                                  ?              0
unrecognised: {"version":2,"nodes":[]}                   ?              0
not JSON at all                                          ?              ?

=== the gate, both directions, against the real shape (10 bmv2 processes running) ===
  PASS  manifest count matches running bmv2 count (manifest=10 procs=10)
  FAIL  the manifest could not be counted -- shape not recognised. NOT 'zero switches'.
  --- and the OLD behaviour on that same real manifest, for comparison ---
  FAIL  manifest count matches running bmv2 count (manifest=0 procs=10)  <- a gate failing on a fabric that is FINE
```

🔑 The dangerous half is not the wrong answer. It is that `.get(k, default)` converts *"this file
is not what I think it is"* into *"the value is zero"* — a parse failure wearing a measurement's
clothes. Unrecognised shapes now **raise**, and the caller reports it as *"the file is not what
we think it is"*, explicitly not as zero switches.

**An empty manifest gets its own branch**, added after the first run of this test showed `{}`
falling into the generic unrecognised case. `{}` is a real fabric result — the topology script
writes only switches that passed verification, so `{}` means none did — and conflating it with a
parse failure would lose exactly the information an operator needs:

```
--- empty {} error message ---
manifest is an empty object: ZERO switches passed verification. This is a fabric result, not a
parse failure -- every bmv2 process that is running is one the topology script declined to vouch for.
--- unrecognised shape error message ---
unrecognised manifest shape: dict with keys ['version', 'nodes'] -- refusing to guess a count
```

Prediction P10: **held**.

### `35_r2_r3_analyse.py` — `find_paths` never tried the real name

```
body                                                 NEW (found / keys)           OLD (09c9b03)
------------------------------------------------------------------------------------------------
the REAL key (ndt verify_p4 / 40_r5_p4.sh)           1 / ['all_destination_paths'] 0 / -
destination_paths (near-miss variant)                1 / ['destination_paths']    0 / -
flow_path (previously covered -- must not regress)   1 / ['flow_path']            1 / ['flow_path']
path (previously covered -- must not regress)        1 / ['path']                 1 / ['path']
nothing path-like at all (must find nothing)         0 / -                        0 / -
```

`all_destination_paths` is the key `ndt`'s own `verify_p4` reads and the one `40_r5_p4.sh`
probes, and it was absent from the candidate list. A body keyed that way walked past every
branch and the function returned `{}`, which downstream reads as *"no paths changed"*.

🔑 Same family as R-1's wrong-name search: the terms were reconstructed from what the key *ought*
to be called rather than copied from what the software calls it. **The tolerant walk was supposed
to make the name not matter, and it does not** — a tolerant search over the wrong vocabulary is
still the wrong search, and it fails silently rather than erroring.

The last row is the control that matters: adding names must not turn the search into a sieve. A
body with nothing path-like still finds nothing.

Prediction P11: **held**.

---

## §4 — the tmux session-visibility disagreement (time-boxed investigation)

**Root cause found, shallow, and fixed.** `ndt status` reported `apps energy` while
`ndtwin-lab energy-out` reported `no energy session` — the same shape logged earlier for `sim`,
and the thing FINDING-05 names as blocking any read of the app's own reasoning.

### Hypotheses tested and rejected, in order

| # | hypothesis | test | result |
|---|---|---|---|
| 1 | `list-sessions` and `has-session` disagree | scratch socket, real session, both predicates | **agree** in every state |
| 2 | `-t` prefix matching | targets `energy`, `ener`, `energyX`, `sim` | one asymmetry found, **wrong direction** (see below) |
| 3 | TERM absent under a pty (`ndt`'s own 08-21 finding) | both predicates × {pipe, pty} × {TERM set, unset} | **did not reproduce** on tmux 3.4 |
| 4 | the session exited between the two commands | kill the session, re-probe | both agree it is gone — a race would show as *both* wrong, not one |

Hypothesis 2 did turn up a **real latent defect in the opposite direction**: `has-session -t ener`
returns *yes* for a session named `energy`, because tmux falls back to prefix matching, while
`ndt`'s `lab_session` (which matches `^name:` in `list-sessions`) returns *not-running*. So the
two predicates *can* disagree — just not the way that was observed. Not fixed here: no caller
passes a prefix today, and inventing a fix for an unobserved path is how the next false finding
gets built. Recorded as a ticket note.

### The mechanism, verified on the filesystem

**tmux's socket namespace is per-uid.** `tmux -L ndtwinlab` resolves to
`/tmp/tmux-<uid>/ndtwinlab`:

```
  drwx------ 2 root root 4096 Aug 30 15:51 /tmp/tmux-0
  drwx------ 2 adam adam 4096 Aug 30 19:49 /tmp/tmux-1000
  ndtwinlab socket in the CALLING user's namespace:
    ls: cannot access '/tmp/tmux-1000/ndtwinlab': No such file or directory
```

Every lab session is created under `sudo`, so they all live in **root's** namespace — mode 700,
which an unprivileged process cannot even stat. Run **without** sudo, `ndtwin-lab` looks in
`/tmp/tmux-1000/ndtwinlab`, finds nothing, and because `session_running` sends tmux's stderr to
`/dev/null`, reports `no energy session` instead of *"I cannot see root's sessions from here"*.

`ndt` is immune because `lab_session` **always** goes through `sudo -n "$LAB" status`. A
hand-typed `ndtwin-lab energy-out` is not. That asymmetry is the whole disagreement, and it
matches the observed direction exactly.

### The fix, both directions

A non-root invocation is now refused with the reason, rather than answered wrongly:

```
=== FORCE-RED: invoked as uid 1000 (no sudo) ===
  ndtwin-lab: must be run as root, e.g. 'sudo ndtwin-lab energy-out'.
    tmux's socket namespace is per-uid, so from uid 1000 this command would look in
    /tmp/tmux-1000/ndtwinlab and find nothing, while the lab's sessions are in root's
    /tmp/tmux-0/ndtwinlab. It would then report 'no <name> session' about a session that is
    running -- which is what happened on 2026-08-30 and disagreed with 'ndt status'.
  rc=1

=== FORCE-GREEN: invoked as uid 0 (under sudo) ===
  -> guard passed; the verb would now run
  rc=0
```

No verb is wrongly blocked: the read-only ones (`status`, `*-out`) read root's socket and the
rest run `mn`/`tmux`/`kill` as root. **Worse than blocking**: without the guard,
`ndtwin-lab topo-start` run without sudo would create a topo session in the *calling user's*
namespace, where nothing else in this project can ever see it.

🔑 The failure mode was not "it did not work" but "it produced a confident wrong answer that
contradicted the other instrument", and two of our own instruments disagreeing is a finding about
the instruments until shown otherwise. Refusing is what makes the disagreement legible.

### ⚠️ A harness bug that nearly produced a false GREEN

The first version of the acceptance test faked the uid with `local EUID=…`. **`EUID` is readonly
in bash**, so the assignment failed and *both* runs took the red branch — while the transcript
printed a `FORCE-GREEN` header above the red output. Caught by reading the output rather than the
headers. The guard's uid expression is now textually substituted for `$FAKE_UID`, and that seam
is declared in the harness. A second bug in the same harness (`set --` overwriting `$1` before
the uid was captured) turned the condition into arithmetic on the string `energy-out`.

**Two harness bugs in one ten-line test**, both of which would have reported success.

### Ticket note — what is NOT resolved

* The **`sim` half** of the disagreement is only *probably* the same cause. It was observed as
  `ndt status` vs `port_holder`, not as an `ndtwin-lab` verb, and the port_holder fix (§2.7)
  addresses that one independently. Not merged into one explanation without evidence.
* The `has-session` prefix-matching asymmetry above is unfixed and unexercised.
* This does not make the Energy-App's reasoning readable — it makes the *failure to read it*
  honest. FINDING-05's ticket (*"why does the app power switches down on P4 and not on OVS"*)
  still needs `sudo ndtwin-lab energy-out` to be run, and the sim disk log (§2.4) is the
  equivalent for sim.
