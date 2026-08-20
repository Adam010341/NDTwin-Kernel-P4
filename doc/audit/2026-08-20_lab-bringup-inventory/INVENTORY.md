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
| ~16:08 | **me** | `ndt check` traffic put 606 Mbit/s through the fabric, spoiling one of their cells |

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
