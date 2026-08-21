# Lab bring-up / teardown: tool inventory and trap verification

2026-08-20. Everything below is tagged **[OBS]** (I ran it or read the line) or **[INF]**
(reasoning from what I read, not demonstrated). The split matters here because this project
has a recorded history of over-estimating defects from source reading alone.

[Co-developed with claude code -- Adam]

---

## 0. What was actually live when I started

**[OBS]** The environment was fully up, not partly up. My first snapshot said otherwise and
was wrong:

| time | what I saw | truth |
|---|---|---|
| ~14:52:5x | `stack.sh status` -> mode unknown, all ports closed, `.test_run/pids/` empty | the stack was **mid-bring-up** |
| 14:53 | `kernel.pid` appears, `.test_run/mode` written | up |

`stack.sh` writes `.test_run/mode` **last** ([stack.sh:649](tools/test_workflow/stack.sh:649)),
deliberately, so a failed start cannot leave a stale mode behind. The consequence is that
during bring-up the machine looks torn down. **Do not read "mode: unknown" as "nothing is
running"** -- read the process and port state.

**[OBS]** A measurement matrix launched from another session was running the whole time:
`doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh`, 5 sampling rates x 2 poll arms x 300 s,
which tears down and rebuilds the fabric between rates and recompiles the P4 pipeline each
time. Nothing in `stack.sh status` or `ndtwin-lab status` shows this. It is the reason the new
`ndt down` has a guard.

---

## 1. Tool inventory

### `/usr/local/sbin/ndtwin-lab` (root, NOPASSWD)
**[OBS]** Verbs, from running it with no argument:
`topo-start | ovs-topo-start | ovs-topo-4host | topo-cmd <text> | topo-out [n] | topo-stop |
cleanup | energy-start | energy-stop | energy-out [n] | sim-start | sim-stop | sim-out [n] |
status`

- **[OBS]** `topo-start` runs `ntg_bmv2_topo.py`, not `p4_testbed_topo.py`
  ([ndtwin-lab:27,38](tools/test_workflow/ndtwin-lab:27)). Confirms the brief.
- **[OBS]** `status` is the honest liveness check. It reports tmux sessions plus
  `bmv2: N  mininet: N`, and matched independent `ps` counts exactly (10 / 138).
- **[OBS]** `cleanup` = `pkill ntg_bmv2_topo.py` + `pkill p4_testbed_topo.py` +
  `pkill testbed_topo.py` + `mn -c` + `pkill simple_switch_grpc` + `rm manifest`. It does
  **not** touch the tmux session ([ndtwin-lab:65-77](tools/test_workflow/ndtwin-lab:65)).

### `tools/test_workflow/stack.sh`
**[OBS]** `up {ovs|p4}` / `wait [secs]` / `status` / `down` / `logs`. Reads
`components.env`. Contains real, load-bearing guards (stray-listener detection on
:8000/:8080/:8081, pid validation before `kill`, a `/stats/flow` wedge refusal for
`up ovs` under a live Mininet).

### `tools/test_workflow/components.env`
**[OBS]** Path/port truth. The one dangerous default is line 74 -- see trap 4.

### Driver-script precedents
**[OBS]** The brief points at `doc/audit/2026-08-18_live-full-stack-round/up_ovs.sh` /
`up_p4.sh`. **They are not there.** That directory has `measure_core_bandwidth.sh`,
`measure_f5_frequency.sh`, `run.py`, `cadence.py`, `analyse.py`, `method_check.py`. The
`up_*.sh` drivers live in **`scratch/lab/`** (and older copies in `scratch/round4/`,
`scratch/phase2/`). `scratch/` is not committed, so these patterns would be lost on a clean
checkout -- that is why the new command lives in `tools/test_workflow/`.

---

## 2. Trap verification

### Confirmed as written

**Trap 3 -- `pgrep -c simple_switch_grpc` returns 0 with 10 switches running. [OBS]**
Reproduced. procps even prints its own warning:
```
pgrep: pattern that searches for process name longer than 15 characters will result in zero matches
pgrep -c simple_switch_grpc  = 0     (ps truth: 10)
```

**Trap 4 -- `TOPO_P4` defaults to the 4-host JSON. [OBS]**
[components.env:74](tools/test_workflow/components.env:74). Arithmetic verified by reading
both files:

| model | switches | hosts | edges | destination paths `stack.sh` waits for |
|---|---|---|---|---|
| `...P4_10Switches_4Hosts.json` | 10 | 4 | 40 | **12** |
| `...P4_10Switches_128Hosts.json` | 10 | 128 | 288 | **16256** |

**Trap 5 -- the two override files decide every number. [OBS]**
`host_count_override` = `128`; `bmv2_binary_override` points at
`/usr/local/bmv2-fast/bin/simple_switch_grpc`, and that is the binary the 10 running
processes were actually launched from. Also **[OBS]** `NDTWIN_P4_HOST_NUM` is a second,
higher-priority seam ([p4_testbed_topo.py:294](p4_proxy/mininet/p4_testbed_topo.py:294)) --
env var beats file. **[INF]** it will not reach a `ndtwin-lab topo-start` fabric, because
sudo's `env_reset` strips it.

**Trap 6 -- `topo-start` runs `ntg_bmv2_topo.py`. [OBS]** See above.

**Trap 8 -- bmv2 outlives `mn -c`. [OBS]** `ntg_bmv2_topo.py` itself does
`mn -c` **then** a separate `pkill -f simple_switch_grpc`
([ntg_bmv2_topo.py:85-87](p4_proxy/mininet/ntg_bmv2_topo.py:85)), with the comment naming the
"Address already in use" failure. The code treating them as two separate kills *is* the
evidence that `mn -c` alone does not do it.

**Trap 12 -- switch CPU is fabricated. [OBS]** Exact line:
`cpu = 10 + (std::hash<std::string>{}(ip_str) % 50)` at
[DeviceConfigurationAndPowerManager.cpp:1545](src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1545),
and again at `:1807` keyed on `deviceIdentifier`.

### Confirmed, with a sharper mechanism

**Trap 1 -- `cleanup` kills the calling shell.** **[OBS]** the mechanism, from
`mininet/clean.py`: `mn -c` runs
```
pkill -9 -f 'mininet:'          pkill -9 -f "sudo mnexec"          pkill -9 -f 'Tunnel=Ethernet'
```
These match **command lines**, so the blast radius is *any process whose argv mentions those
strings* -- not "the caller" as such. **[INF]** that is why bundling cleanup into a
`bash -c` one-liner kills the shell: the wrapper's argv carries the whole command text, and
a compound command that also counts `mininet:` processes puts the pattern in its own argv.

**Consequence, and it is a good one: a script file is immune.** `/bin/bash .../ndt down`
mentions neither pattern, so teardown *can* safely be bundled -- as long as no child gets the
pattern into its argv either. That is why the new command counts processes with
`ps -eo comm=`/`ps -eo args=` read into bash, never `awk '$NF ~ /^mininet:/'`.

**[OBS] Demonstrated, not just reasoned.** Two detached `sleep` processes were planted before
a real `ndt down`, identical except for their command lines:

| canary | argv | after teardown |
|---|---|---|
| TEST | `sh -c 'sleep 600' mininet:canary` | **KILLED** |
| CONTROL | `sh -c 'sleep 600' ndtcontrolcanary` | **SURVIVED** |

The invoking shell survived as well. So the rule is exactly "argv mentions the pattern", and
bundling teardown into a script file is safe.

**Trap 2 -- `topo-out` prints the previous round's pane.** **[OBS] and partly refuted as
stated.** The matrix tore the session down and rebuilt it at 15:03:28; `topo-out` immediately
after showed content timestamped **15:03:46** -- current, not stale. **[OBS]** the real
mechanism: `topo-start` **refuses and exits 1 without acting** when a session already exists
(`ndtwin-lab: topo session already running (topo-stop first)`,
[ndtwin-lab:37](tools/test_workflow/ndtwin-lab:37)). A driver that ignores that exit code and
then reads `topo-out` gets the old session's pane and reads a corpse as alive. So the ordering
rule (`stack.sh down` -> `topo-stop` -> `cleanup`) is right and the warning is right, but
`topo-out` is not inherently stale -- **a session that was never replaced is**.

### Not reproduced this round (and why)

**Trap 11 -- warm-fabric proxy restart multiplies telemetry. [OBS: not observed]** The matrix
restarted the proxy on rebuilt fabrics repeatedly with no sign of it, consistent with the
settle pair `79e4f69` having fixed it. Kept as a tripwire in `ndt check`. Note the twin has
**no cumulative byte counter** -- the edge schema is
`link_bandwidth_usage_bps` / `link_bandwidth_bps` / `link_bandwidth_utilization_percent`
**[OBS]** -- so the ratio must be computed rate-against-rate over a window, the way
`doc/audit/2026-08-18_live-full-stack-round/run.py` does it. A "sum the twin's bytes" check
has nothing to sum and silently reports zero; my first version did exactly that.

### Not tested (would have perturbed the running matrix)

- **Trap 7** (`stack.sh up ovs` interactive prompt / FIFO): needs an OVS fabric.
- **Trap 9** (power-on no-op within ~10 s): **[OBS]** `/usr/local/sbin/ndtwin-p4-power` has
  `TERM_WAIT_S = 10.0` at line 56, which is consistent with the reported window.
  **[INF]** that an `action=on` arriving inside that terminate-wait sees the switch as still
  present and no-ops. Not demonstrated.
- **Trap 10** (`ifconfig down` stops the whole bmv2 switch): destructive.

---

## 3. Document-vs-reality discrepancies

1. **[OBS] `up_ovs.sh` / `up_p4.sh` are in `scratch/lab/`, not
   `doc/audit/2026-08-18_live-full-stack-round/`.** And `scratch/` is uncommitted.

2. **[OBS] The `.p4` comment above `SAMPLE_RATE` is stale.**
   [ndtwin_switch.p4:50-52](p4_proxy/p4_src/ndtwin_switch.p4:50) says *"Matches OVS's
   sampling=256"* directly above `const bit<16> SAMPLE_RATE = 1024;`. The compiled JSON
   agrees with the constant, not the comment: the rng bound is `0x03ff` = 1023, i.e.
   `random(0, 1023)` = 1 in 1024. **Benign in context** -- `matrix.sh` rewrites that constant
   per cell with `sed` and restores 256 at the end, so 1024 was simply the cell in flight.
   But it means **the sampling rate cannot be read from the source file**; only the built
   JSON knows. `ndt status` reads the built JSON for exactly this reason.

3. **[OBS] The memory file name `agent-can-do-live-tests-except-start-mininet.md` is stale**,
   as the brief says: `ndtwin-lab topo-start` starts Mininet unattended, and I used it.

4. **[OBS] "mode: unknown" during bring-up is not a fault** -- see section 0. Worth a line in
   the eventual manual, because it looks exactly like a torn-down machine.

---

## 4. Timings measured this round

**[OBS]**, from `matrix.log` and `ndtwin-lab status`:

| step | time |
|---|---|
| `topo-start` -> 10 bmv2 + manifest | ~11 s (session 15:03:28, CLI banner 15:03:46) |
| P4 link discovery, 128 hosts -> 16256 paths | **12 s** (`converged after 12s`) |
| proxy `:8081` open | ~2 s |
| kernel `:8000` open | ~1 s |

Matches the brief's "topo-start 約 10 秒 / up p4 約 30-45 秒".

---

## 5. What the new command is

`tools/test_workflow/ndt`, symlinked to `~/.local/bin/ndt` (no sudo -- `~/.local/bin` is
already on PATH; `/usr/local/bin` is not writable without a password).

```
ndt up [p4|ovs]   ndt down [--force]   ndt status   ndt clean   ndt check [--force]
```

The design points that come straight out of the traps above:

- **`up` derives `TOPO_P4` from `host_count_override`** by reading each
  `setting/StaticNetworkTopologyP4_*.json` and picking the one whose host count matches. Trap
  4 becomes unreachable rather than documented.
- **`up` verifies the model matches the fabric** (kernel graph host count == topology file
  host count), which is the assertion that would have caught a wrong `TOPO_P4` after the fact.
- **`down` bundles the three-step order safely** because it is a script file (trap 1).
- **`down` and `check` refuse while a measurement is in flight.** Added after the guard's own
  first run found the matrix I was about to destroy.
- **Every process count avoids both `pgrep` failure modes** (trap 3 and the self-match below).
- **`status` prints the invisible state**: host count, topology model, bmv2 binary, and the
  sampling rate decoded from the compiled JSON.

---

## 6. New trap, found while building this

**[OBS] `pgrep -cf` over-counts by matching the shell that is running the check.** The usual
fix for trap 3 is `-f`, but `-f` matches command lines, so a shell whose argv contains the
pattern matches itself:

```
pgrep -cf simple_switch_grpc      -> 11      (ps truth: 10; the 11th is the calling bash -c)
pgrep -cf '[s]imple_switch_grpc'  -> 11      (same -- see below)
```

The `[s]imple...` bracket trick does **not** save it, because the same argv usually also
carries the unbracketed form somewhere (another echo, a comparison line, a heredoc that wrote
the script). Observed both from a `bash -c` one-liner and from a script file whose *parent*
heredoc carried the pattern.

This is a fourth variant for `process-liveness-checks-lie-in-two-ways`. The reliable form is
to compare inside the checking shell:

```bash
n=0; while read -r c; do [[ "$c" == simple_switch_g ]] && n=$((n+1)); done < <(ps -eo comm=)
```

**[OBS] A second self-inflicted variant, from writing this tool:** `sudo -n ndtwin-lab status
| grep -q '^topo:'` reports a live session as absent. `grep -q` exits on first match,
`ndtwin-lab` still has a line to write, and the resulting SIGPIPE becomes the pipeline's
status under `set -o pipefail`. Capture first, match after.

---

## 7. Findings from the live up/down cycles

Four full cycles were run on 2026-08-20 between 16:00 and 16:20.

### 7.1 `all_destination_paths` is not monotonic -- and the kernel reads it once **[OBS]**

This is the most important thing found, because it affects every P4 run, not just this tool.

The first cold `ndt up` produced:

```
stack.sh:  paths=16256   converged after 4s
ndt verify (seconds later):  13184/16256
40s poll afterwards:         16256, stable for all 40 samples
```

and a later cold start showed the count **falling during fill**:

```
paths=8064   ->   paths=6144   ->   paths=10880   ->   paths=16256
```

So the endpoint is not a progress bar; it exposes a list that is repopulated, and a read can
land mid-repopulation. The proxy log shows the dip coinciding with bulk route installation
(`Modified route: 10.0.0.N/32 -> port P`) and with the kernel's one-shot topology pull.
**[INF]** that a rebuild triggered by the kernel's startup pull is what empties and refills it
-- the correlation is observed, the causal claim is not proven.

Two consequences:

1. **`stack.sh`'s convergence gate can fire on a transient peak.** It returns as soon as one
   sample equals the target ([stack.sh:231](tools/test_workflow/stack.sh:231)).
2. **The kernel pulls destination paths exactly once at startup and never retries**, so a pull
   that lands in a dip leaves the kernel with a permanently incomplete path set, with nothing
   logged to say so. In this round it did not happen -- the kernel logged
   `Pulled 16256 paths from controller` -- but the window is real.

`ndt up` therefore requires the target value **twice, at least 3s apart**, before reporting
ready. This is not defensive padding: without it the first cold start of the day failed
verification on a stack that was in fact fine.

### 7.2 Measured cycle times **[OBS]**

| | time |
|---|---|
| `ndt down` (full teardown + clean proof) | **13 s** |
| `ndt up` cold, 128 hosts, verified | **33-34 s** (3 runs) |
| `ndt up` on an already-up stack (reuse) | **6 s** |

### 7.3 A second writer appeared mid-test -- now attributed **[OBS]**

Between two of my cycles the proxy and kernel were restarted by something I did not
initiate: `p4_proxy.log.prev` ends with a clean uvicorn shutdown (`Finished server process
[901755]`), the pids changed (kernel 902047 -> 902915), and the fabric was left untouched.

**Resolved by the other session identifying itself afterwards.** It was session
"8/19 mainDev v2" restarting its kernel with `setsid` at 16:03:31, after **my** `ndt down`
had killed it at 16:01:59. Its own reading of the sequence had been that its `nohup` failed
to survive its process group; that inference was wrong, and so was mine. The collision was
mutual and symmetric:

| time | who | what |
|---|---|---|
| 15:00-15:57 | them | 12-cell matrix; I detected it and stayed off the machine |
| 16:01:59 | **me** | `ndt down` killed their kernel |
| 16:03:31 | them | restarted their kernel |
| ~16:08 | **me** | `ndt check` traffic put 606 Mbit/s through the fabric, forcing them to re-run a cell |

**Corrected 2026-08-20 evening, and verified independently.** A third session reported that
no *surviving* cell overlaps my traffic window; I rebuilt the timeline myself from the `t`
field of all 20 `raw/*_twin.jsonl*` traces rather than taking the report on trust:

```
12-cell matrix   14:53:06 - 15:56:56      mzero_poll     16:45:07 - 16:50:07
                                          mzero_nopoll   16:50:11 - 16:55:11
```

None of the 20 traces intersects 16:05-16:12. So the precise statement is: **my interference
cost them one re-run, and contaminated no data that reached a conclusion.** The damaged
attempt was discarded at the time; the surviving zero-point pair is the re-run. Both halves
matter -- the cost was real, the contamination was not.

**A claim in that same report was wrong and is worth recording, because believing it would
throw away a good cross-check.** It said the gzip pass at `ae9f12a` reset every trace's mtime
to ~17:00, so mtime could no longer order events. Checked against all 20 files: **0 where
mtime differs from the trace's last `t` by more than 5 s** -- gzip preserves the original
mtime, and every file's mtime is exactly its own trace end. Preferring the in-band `t` field
is still the better habit (the data's own timestamp beats the filesystem's), but mtime was
never destroyed, and it is what let me verify the correction above.

**The mechanism is not process groups. It is that `.test_run/pids/` is shared.**
`stop_one` reads `.test_run/pids/kernel.pid` and does `kill -TERM -$pid` regardless of who
wrote it ([stack.sh:287-327](tools/test_workflow/stack.sh:287)). Anyone who starts a kernel
through `stack.sh up` registers it there, so any `down` from any session kills it. The
pidfile is already a shared registry -- it just has no owner field.

**Why `in_flight` did not catch it, and why that was correct.** The guard scans for
measurement drivers. By 16:01 their matrix had finished; their kernel was merely sitting
between experiments. The guard detects *whether a measurement is running*, not *whose stack
this is*. Those are different questions and only the second one prevents this collision.

### 7.3b The claim file **[OBS -- six cases tested]**

Added in response, and agreed with the other session:

```
.test_run/lab.claim
    owner=<free text, required>
    expires=<unix seconds, required>
    note=<free text, optional>
```

`expires` is mandatory so a crashed session cannot hold the lab forever; an expired claim is
ignored. `ndt up`/`ndt down` refuse when a *foreign* unexpired claim exists (`--force`
overrides). Identity comes from `NDT_OWNER`; **with it unset every claim counts as foreign**,
which is the safe default. Any script can write the file -- nothing has to call `ndt`.
Convenience verbs: `ndt claim [minutes] [note]` / `ndt release`.

Tested: refuses without `NDT_OWNER`; blocks my `up` and my `down` under a foreign claim;
does not block the owner; ignores an expired claim; releases cleanly; normal operation
restored afterwards.

### 7.4 `kill -0` on a Mininet host pid says "dead" when it means "not yours" **[OBS]**

My own debug script reported `h1=883372 (alive: no)` while `mnexec -a 883372 ping` worked
perfectly. Mininet host processes are root-owned, so `kill -0` as adam returns EPERM, and
`kill -0 $p && echo yes || echo no` prints `no`. Already recorded in
`process-liveness-checks-lie-in-two-ways`; re-confirmed here, in a script written *after*
re-reading that note.

### 7.4b Dirty-state teardown: what `down` does and does not clear **[OBS]**

Two dirty states were manufactured and torn down.

**A. Orphaned session + dead fabric under a live kernel** -- made by running
`ndtwin-lab cleanup` *without* `stack.sh down` and *without* `topo-stop`, which is the
mis-ordering the docs warn about. `ndt clean` correctly reported not-clean (exit 1, naming
:8000 and :8081), and `ndt down` then reached clean, exit 0.

Incidental: **`cleanup` did end the tmux session here**, contrary to the trap as written.
Its `pkill -f ntg_bmv2_topo.py` kills the topology python, and that python *is* the session's
only command, so the session ends with it. The trap presumably needs a session whose pane has
outlived its command. Not a reason to change the ordering rule -- `topo-stop` first is still
right -- but the stated reason is not what was observed.

**B. A kernel started by hand, with no pidfile.** `ndt down` **names it and refuses to claim
success, but does not kill it**:

```
[1/3] kernel + proxy/Ryu
        :8000 is still listening, held by ndtwin_kernel (pid 976972)
...
  XX  :8000 still listening -- the next up would measure it
not clean
DOWN EXIT=1
```

The stray survived; killing it by pid then gave clean. This is by design (`stop_one` only
knows what the stack started) and is the honest behaviour, but it means **"`ndt down` clears
any mess" is false for processes started outside the stack** -- it detects them rather than
removing them.

**Resolved: Adam chose an opt-in `--deep`, default off.** Verified in three cases:

| case | result |
|---|---|
| `ndt down --deep`, nothing stray | `deep sweep: nothing left holding the ports`, exit 0 |
| `ndt down` (plain), stray present | stray survives, `not clean`, **exit 1**, and the message now names the fix |
| `ndt down --deep`, stray present | `killing ndtwin_kernel (pid N) holding :8000`, **clean, exit 0** |

The default stays conservative on purpose: killing a listener you did not start is killing
someone else's work, which is not hypothetical on this machine. `--deep` names each process
before signalling it, refuses pids < 2 and its own, escalates TERM -> KILL, and verifies. When
the socket's owner is invisible (root-owned), it says so rather than silently doing nothing.
The claim guard still applies, so `--deep` alone cannot blow through another session's
reservation -- that additionally needs `--force`.

### 7.4c The app launcher leaked a process while reporting success **[OBS -- my own bug]**

First live run of `ndt apps nsr` recorded the wrong pid. The launcher used
`( cd D && setsid CMD >log 2>&1 & echo $! >pidfile )`; `setsid` detaches into a new session,
so `$!` named a transient shell -- **the pidfile ended up holding the pid of `ndt` itself**.
`ndt apps stop nsr` killed that, printed `ok nsr stopped`, and the recorder went on running,
reparented to init.

Two fixes, and the second matters more than the first:

1. `( cd D && exec nohup CMD >log 2>&1 ) &` -- every step execs rather than forks, so one pid
   holds from subshell to `nohup` to the program. Verified: the pidfile now names
   `.../ntg-env/bin/python network_state_recorder.py`.
2. **`app_stop` now verifies the process is gone before saying "stopped"**, and reports
   `STILL RUNNING after TERM and KILL` otherwise. The original said "ok" without checking,
   which is the "reports failure as success" shape this repo keeps re-finding.

Re-tested: start names the real pid, stop leaves nothing behind.

### 7.4d The OVS path, finally run **[OBS]**

> ⚠️ **Corrected 2026-08-21 — the `ovs4` row below is wrong.** It exited 0 and every assertion
> in it passed, and the fabric was forwarding nothing at all: 100% loss between every host
> pair. See §8.3. The row is left as written because *what it got wrong* is the finding — every
> check listed here was satisfied by a dead data plane.

Both OVS variants worked on their first live run, which closes the last untested branch.

| command | time | result |
|---|---|---|
| `ndt up ovs` | **1m13s** | 10 switches up+enabled, 128 hosts, 288 edges, exit 0 |
| `ndt up ovs4` | **1m8s** | 10 switches up+enabled, 4 hosts, 40 edges, exit 0 |

The FIFO/prompt handling held: waiting on the `[2/3]` banner rather than on the prompt string
is correct, because `read -p` writes its prompt to the terminal and it never arrives over a
FIFO. Both runs reached the prompt, built the fabric, answered, and converged.

**New finding, and it generalises 7.1: Ryu's link count is not monotonic either.**

```
ndt up ovs :   links=32 -> 31 -> 29 -> 32      (converged after 70s)
ndt up ovs4:   links=32 -> 31 -> 32            (converged after 66s)
```

So the shape found in P4 mode -- a discovery endpoint that dips while it is being rebuilt --
is not a P4 quirk. It is present on both control planes, and in both cases `stack.sh`'s gate
releases on the first sample that matches exactly
([stack.sh:231](tools/test_workflow/stack.sh:231)) while the kernel pulls the topology once
and never retries. A pull landing in a dip leaves the kernel permanently short of edges with
nothing logged.

Neither run actually hit it. But the OVS verify was only *printing* the host and edge counts,
so it would not have noticed; it now **asserts** them against the topology file, the way the
P4 path already asserted host count. That assertion is what would catch a kernel that pulled
during a dip.

### 7.5 `ndt check` validated against real traffic **[OBS]**

With 200 Mbit/s UDP crossing the fabric:

```
window               8.0s over 32 inter-switch links
twin  (integrated)   417.6 Mbit/s
/proc/net/dev        411.0 Mbit/s
ratio                1.02   ok
```

Two failed attempts came first, and both were instructive:

- **The twin has no cumulative byte counter.** The first version summed `tx_bytes`/`bytes` on
  edges; those keys do not exist, so it reported 0 and said so rather than inventing a ratio.
- **A stale one-shot `iperf3 -s -1` server held :5201**, the replacement died with `Address
  already in use`, and with the client's output discarded it looked exactly like "no
  traffic". My guard against that then read the *previous* run's root-owned log file -- the
  same stale-read shape as trap 2. Unique log path per run.

In both failures `ndt check` printed "under 1 Mbit/s; the ratio is not meaningful yet"
instead of a number. That is the behaviour worth keeping.

---

## 8. Adversarial review round, 2026-08-21 **[OBS]**

A second session was asked to learn the workflow and then attack it; a third was using the lab
meanwhile. Six defects came out of it. Two are fixed below with their evidence, one is left
open and honestly unresolved. **Five of the six are in `ndt` itself** -- the tool written to
make the lab safe was the least-tested thing touching it, which is the same lesson as
[[new-tools-are-the-first-thing-under-test]].

Findings reproduced independently before acting on any of them, per the standing rule that a
report from another agent is evidence, not a verdict.

| # | defect | status |
|---|---|---|
| F4 | `down` kills any pid in `.test_run/pids/`, verifies nothing, still reports clean | confirmed, **not fixed** |
| F5 | `app_stop` follows a symlinked pidfile; `stop_one` refuses to | confirmed, **not fixed** |
| F6 | an idle `iperf3 -s` blocks every teardown | confirmed, **not fixed** |
| F9 | `topo_session()` reports absent whenever an app session exists | confirmed, **FIXED** (§8.2) |
| — | `ndt up ovs4` builds a fabric that forwards nothing | confirmed, **FIXED** (§8.3) |
| B1/B2 | OVS↔P4 switch silently reuses the previous plane's kernel | code-level only, not reproduced live |

### 8.1 F4 / F5 / F6, reproduced here **[OBS]**

- **F4**: an unrelated `setsid sleep 900` pid written into `.test_run/pids/kernel.pid`; `ndt
  down` killed it, printed `stopped kernel`, and `verify clean` went five-for-five with rc 0.
  `stop_one` validates that the pid is an integer ≥ 2 and nothing else -- no `comm`, no start
  time -- then sends `kill -TERM -$pid`, which is the whole **process group**.
- **F5**: `.test_run/pids/app_nsr.pid` symlinked elsewhere; `ndt apps stop nsr` followed it,
  killed the target, printed `ok nsr stopped`, rc 0. `stack.sh:293` refuses symlinks and
  `app_stop`'s own comment claims "same pid hygiene as stop_one" -- it copied the `pid < 2`
  check and not the symlink one.
- **F6**: `iperf3 -s` idle on port 5299, serving nothing, is matched by `in_flight` and blocks
  teardown with rc 1. Fail-closed and therefore not urgent, but it trains the `--force` habit
  that disarms the guard for the case it exists to catch.

### 8.2 F9: fixing one liveness bug introduced another in the same function **[OBS -- my own bug]**

`topo_session()` had already been fixed once, on 2026-08-20, for reporting a live session as
absent (`| grep -q` exits at the first match, `ndtwin-lab` still has its counts line to write,
SIGPIPE, and `pipefail` turns 141 into the pipeline's status). The fix -- capture first, match
after -- **dropped the per-line anchoring along with the pipeline**:

```bash
out="$(sudo -n "$LAB" status 2>/dev/null)"; [[ "$out" == topo:* ]]
```

`ndtwin-lab status` is `tmux list-sessions`, one line per session, **sorted by name**, and the
three session names are `topo`, `energy`, `sim`. `energy < sim < topo`, so with any app running
the blob does not start with `topo:` and a live session reads as absent again. Same symptom,
new mechanism, one week apart, same function.

The expensive consequence is not the misreport. `up_p4` decides whether to sweep with
`[[ "$n" -gt 0 ]] && ! topo_session`, so with an app running it calls `cleanup` on a **healthy
ten-switch fabric** and announces it as `orphan bmv2 process(es) ... sweeping first`. Reports
success, does the wrong thing, and the message actively misdescribes it.

**Fixed** by merging both callers into one `lab_session <name>` that avoids both traps at once
-- no pipeline (no SIGPIPE) and line-anchored (no ordering assumption):

```bash
[[ $'\n'"$out"$'\n' == *$'\n'"$1":* ]]
```

Acceptance: 13 assertions, including "must still say absent when it genuinely is" and "must not
be fooled by a session named `topology`". **The same suite fails 3 of 13 against the old
implementation** -- a test never seen failing is not a test.

Sibling correction, measured rather than assumed: the `| grep -q` SIGPIPE is a **race**, not a
certainty -- 141 against a deliberately slow producer, but 0 six times out of six against the
real `ndtwin-lab`. `app_running` therefore carried a *latent* hazard, not an observed defect,
and is reported as such. It was still folded into the shared helper: two implementations of one
predicate is how they came to disagree.

### 8.3 `ndt up ovs4` produced a fabric with no forwarding at all **[OBS]**

Found by the reviewing session, reproduced here. `ndt up ovs4` printed
`ok model matches fabric: 4 hosts, 40 edges` and `up. ready`, and every host pair was 100% loss.

`intelligent_router.py:36-38` takes Ryu's host list from **its own** static topology file, which
defaults to the 128-host model regardless of the fabric, overridable by `NDTWIN_RYU_TOPO_FILE`.
That variable had **one reader and zero automated setters** in the entire repo -- the only
`export` was a hand-typed line in the 2026-08-17 report (`REPORT.md:182`), which is why that
round's numbers are sound and every scripted run since was not. It is the exact mirror of
`NDTWIN_CLONE_DISABLE`: committed setters, no reader.

Measured, with the setter present and then removed (mutation gate):

| | with the fix | setter removed |
|---|---|---|
| `all_destination_paths` | **902 bytes** | **1,110,528 bytes** |
| distinct hosts in it | `10.0.0.1`–`10.0.0.4` | 128 |
| `h1 -> 10.0.0.2` | forwards | **100% loss** |
| `ndt up ovs4` exit code | 0 | **1** |
| `model matches fabric` | ok | **still ok** |

The 1,110,528 figure matches the reviewing session's measurement byte for byte, on a separate
run. The last row is the point: **both topology views were correct**, so no structural check
could have caught this.

Two fixes. `up_ovs` now sets `NDTWIN_RYU_TOPO_FILE` to the same file as `TOPO_OVS`; and a
`verify_dataplane` assertion **sends an actual packet** (`mnexec -a <host-pid> ping`), wired
into both the OVS and P4 verify paths. The P4 path has the same blind spot for a different
reason -- the destination-path count is what the proxy *says* it installed, and install-then-
delete on bmv2 has been seen to leave a black hole that still counts as a path.

### 8.4 Unresolved: the topo session reads absent under a pty **[OBS symptom, mechanism UNKNOWN]**

Recorded because it is unfinished, not because it is understood.

Under a pty, `sudo -n ndtwin-lab status` reports no `topo` session **while the fabric is fully
healthy** -- measured at t=0 with bmv2=10 and both ports open, before anything was torn down.
Four reproductions under a pty, all absent; three under a pipe, all correctly present. `TERM`
and `TMUX` are identical in both. The mechanism was **not** isolated.

This matters more than it first appears: an operator at a terminal *is* the pty case, so the
pty behaviour is the normal one and the pipe runs are the artefact. The consequence is that
`[2/3] topo-stop` is skipped and teardown falls entirely to `mn -c` in `[3/3]`. Measured
end state is still clean (bmv2 10→0, veth 160→0), but the orderly Mininet shutdown is being
skipped.

**Consequence for the Ctrl-C test**: it is not answered. Three attempts; the first two finished
before the interrupt could fire (teardown collapses to ~3 s under a pty instead of ~13 s), and
the third delivered a real SIGINT 0.2 s into `mn -c` and left no residue at all -- but on a
machine that was already effectively clean, so it measured nothing. **The question stands.**
Next step is specific: hold a live topo session and compare `tmux list-sessions` under a pty
against the same call under a pipe. That window was missed this round.

Five different mechanisms were proposed for this anomaly during the session and all five were
wrong. It is left as unknown rather than given a sixth.
