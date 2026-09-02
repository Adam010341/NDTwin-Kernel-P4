---
title: Install All Required Components on a Linux Server
description: > 
  A comprehensive guide for manually installing the NDTwin system on a native Linux environment.
  This section covers system dependencies, building the NDTwin Kernel with Ninja, configuring Python environments, and running the full system.
date: 2025-12-24
weight: 2
---



**Pre-flight Checks:**

1. **Source Code:** Ensure `NDTwin-Kernel` is in your `~/Desktop` (or adjust paths below).
2. **Compilation:** Ensure `ndtwin_kernel` exists in `build/bin/` (from [Installation Manual](/docs/ndtwin-installation-manual/ndtwin-kernel/operate-an-emulated-software-network/)).
3. **Topology Script:** Ensure `testbed_topo.py` exists (from [Installation Manual](/docs/ndtwin-installation-manual/ndtwin-kernel/operate-an-emulated-software-network/)).

**Startup Order is Critical:** Please execute Terminals 1 through 3 in the **exact order** listed below.

---

## The short way: `ndt up`

The repository ships a launcher that does everything the three terminals below do, in the right
order, and then **waits until the fabric has actually converged before telling you it is up**:

**Two scripts have to be installed, not one.** `ndt` runs as you; the root-side operations it
needs — starting the topology, stopping it, cleaning up — live in a second script,
`ndtwin-lab`, which sits next to `ndt` in the same directory and which `ndt` invokes as
`sudo -n /usr/local/sbin/ndtwin-lab`. Install both:

```bash
cd ~/Desktop/NDTwin-Kernel

# 1. the launcher you run.  ~/.local/bin does not exist on a fresh Ubuntu 24.04,
#    and 'ln' will not create it: without the mkdir the next line fails with
#    "No such file or directory".
mkdir -p ~/.local/bin
ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt

# 2. the root-side half it calls, installed root-owned and executable
sudo install -o root -g root -m 755 \
    tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab

# 3. let it run without a password prompt -- 'ndt' calls it with 'sudo -n',
#    which cannot ask for one
echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab" \
    | sudo tee /etc/sudoers.d/ndtwin-lab
```

> **Open a new login shell before calling `ndt`.** Ubuntu's stock `~/.profile` puts
> `~/.local/bin` on `PATH` only `if [ -d "$HOME/.local/bin" ]`, and it tests that **at login**.
> The shell you created the directory in was started before it existed, so `ndt` is not on its
> `PATH` no matter how correct the symlink is. Log out and back in, or start one with
> `bash -l`.

> **Skip step 2 and `ndt up` stops at its second phase** with
> `sudo: /usr/local/sbin/ndtwin-lab: command not found`, then `XX ovs-topo-start failed`.
> Nothing points at the missing script, because from `ndt`'s side the only symptom is that
> `sudo` could not find something.
>
> 🔑 **Step 2 installs a *copy*, on purpose.** `sudo` runs the root-owned file at
> `/usr/local/sbin`, not the one in your checkout, which is what stops a writable script from
> being run as root. The practical consequence is that **`git pull` does not update it** —
> re-run the `install` command after any change to `tools/test_workflow/ndtwin-lab`.
>
> ⚠️ **Step 3 grants a real privilege**: after it, anything running as you can perform that
> script's fixed set of operations as root — start and stop the topology and the app binaries,
> and type into the NTG CLI. The script's own header states this surface. If you would rather
> not, skip step 3 and run `ndt` from a shell whose `sudo` credentials are already warm.

🔴 **Known limitation, worth reading before you rely on `ndt up`.** `ndtwin-lab` locates the
repository and the NTG interpreter through paths written into the script itself —
`/home/adam/Desktop/NDTwin-Kernel` and `/home/adam/miniconda3/envs/ntg-env/bin/python` — and
they are deliberately not overridable from the environment, because it runs as root. On any
machine where those paths do not exist, the topology it starts dies immediately
(`No such file or directory`, exit 127, inside a root `tmux` session you never see) and
`ndt up` waits out its timeout before reporting `XX fabric has 0 hosts, expected 128`. The
message names the symptom, not the missing path. **Until this is fixed, use the three-terminal
procedure below**, which does not go through `ndtwin-lab` at all. This note applies until the
kernel repository's G-7 fix — an install-time configuration file for `ndtwin-lab` — lands (see
KNOWN-ISSUES G-7), and should be removed with it.

| Command | What it does |
| :--- | :--- |
| `ndt up ovs` | Ryu + Open vSwitch fabric + kernel, converged and verified |
| `ndt up` | the P4 / BMv2 fabric instead — proxy agent in place of Ryu (needs Section 6) |
| `ndt status` | what is actually running, **plus the three settings that silently decide every number** |
| `ndt down` | stack → topology session → `mn -c`, then proves the machine is clean |
| `ndt check` | post-hoc health: telemetry double-count, and the fake-CPU reminder |

> **Why this exists, in the tool's own words: the three-command sequence it replaces is correct
> but not safe to type from memory, because the things that decide whether a run is meaningful
> are not arguments to any of them.** `TOPO_P4` defaults to the 4-host model, so starting a
> 128-host fabric without exporting it leaves the kernel modelling a different network — and
> that reads as a hang rather than as a misconfiguration. `up` derives it from the host count
> instead, so the pairing cannot be got wrong, and `up` and `status` both print the three
> override files rather than assuming them.

> **On a machine you share with other people**, claim it first so your run is distinguishable
> from theirs — `export NDT_OWNER='your-name'` then `ndt claim`. On your own machine you can
> skip that; `ndt up` does not require it.

#### The rest of the interface

Those five are what this page uses. The launcher has more, and `ndt --help` is where it lists
them — reproduced here so you know they exist:

| Command | What it does |
| :--- | :--- |
| `ndt up 4` | P4 at 4 hosts; rewrites `host_count_override` |
| `ndt up p4 128` | P4 at 128 hosts |
| `ndt up ovs4` | Ryu + OVS on the P4 test bed's 4-host layout |
| `NDT_TOPO=<file> ndt up …` | forces a specific kernel model instead of the derived one |
| `ndt down --deep` | also kills whatever still holds `:8000` / `:8080` / `:8081`, including processes this stack did not start. Without it a stray is reported and left alone |
| `ndt status --check` | exits non-zero on anything that would make a measurement untrustworthy |
| `ndt clean` | the teardown assertion on its own — exit 1 if anything survived |
| `ndt check` | telemetry double-count tripwire |
| `ndt apps [names]` | start readers/apps: `energy sim nsr viz te`. No arguments on a terminal gives an interactive picker |
| `ndt apps stop [names\|all]` | stop them |
| `ndt apps orphans` | is an app running that no pidfile names? Exits 1 if so |
| `ndt ntg [cli\|prompt]` | which prompt the topology hands control to |
| `ndt claim [min] [note]` | reserve the lab, default 30 minutes; needs `NDT_OWNER` set |
| `ndt release` | give it back |

> This table is the help text, not a behaviour guarantee — run `ndt --help` on your own
> checkout for the authoritative list. `.test_run/pids/` is shared, so `ndt down` stops
> whoever is registered there; declare yourself before a long run.

**The three terminals below are still the reference.** Read them once even if you use `ndt`:
they are what it automates, and when something does not come up they are how you find out
which layer stopped.

---

### Terminal 1: Ryu Controller

* **Purpose:** Starts the SDN Logic.
* **Environment:** `ryu-env` (Python 3.8).

```bash
conda activate ryu-env
# 'intelligent_router.py' is our custom controller app
ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link

```

> App Path Note: You can launch your custom app using an absolute path (recommended) or a relative path.
> * Absolute path example: ~/ryu_apps/intelligent_router.py
> * Relative path example: ./intelligent_router.py (if you cd into the folder first)

> **Start Ryu first, and let it come up before you start the topology.** The topology
> script asks Mininet for a remote controller without naming a port, so Mininet probes
> 6653, then 6633, and connects to whichever one answers. If Ryu is not listening yet,
> Mininet quietly settles on 6653 and every switch dials a port with nothing behind it.
> Neither side logs anything naming the port — the only symptom is a topology that
> never converges.

### Terminal 2: Mininet Topology

* **Purpose:** Creates the virtual network and configures sFlow.
* **Environment:** System Native (Root).

```bash
# Start the custom topology script
sudo python3 testbed_topo.py
```

> **Note:** After the topology starts, **wait for the `"all-destination paths installed"`
> message** before doing anything else. Host discovery and path installation typically take
> **about a minute and a half**, but treat that as an estimate and the message as the signal —
> measured three times on a 4-vCPU machine it took **80 s, 85 s and 80 s**, so a fixed wait of
> one minute would have been too short every time.
>
> Only then start launching NDTwin (backend/GUI); otherwise, NDTwin may query Ryu before the topology is fully detected.

![Alt text](/images/all-destination-flow-entries_installed.png)

> **Note:** If you want to restart Mininet and run the topology again, clean up the previous Mininet state first:
> ```bash
> sudo mn -c
> ```

#### How to tell it has finished, without watching the log

Waiting for that line is the weak point of this procedure: it scrolls past, and on a
ten-switch fabric it is interleaved with link-up and link-down messages that push it out of
view within seconds. **Ask the switches instead — they are the thing you actually depend on:**

```bash
# each switch carries one forwarding rule per destination host, plus an LLDP rule and a table-miss entry
for i in $(seq 1 10); do
  printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"
done
```

Every switch reporting the same non-trivial count, twice in a row, is convergence. On the
128-host fabric that number is **130 per switch** — 128 destination rules (`nw_dst=10.0.0.1`
… `10.0.0.128`), one LLDP rule to the controller, one table-miss — reached about 60–70 seconds
after the last switch connects (measured on a clean Ubuntu 24.04 guest, 2026-09-02: 130 on all
ten switches, stable across three samples, and Ryu's own `install_all_pair_paths done:`
line reports `rules=1280`, which is 1280/10 = 128 forwarding rules each).

> 🔑 **Why ask the switches rather than the controller.** "The controller says it installed the
> paths" and "the rules are on the switches" are two different claims, and only the second is
> the one the kernel depends on. A controller that logged the line and then failed to push
> would look identical from Terminal 1.
>
> ⚠️ **Repeated `Link added` / `Link deleted` for the same switch is normal here and does not
> mean convergence was lost** — path installation runs once, from the static topology file, so
> later link events do not retract what is already programmed.

### Terminal 3: NDTwin Kernel

* **Purpose:** Starts the NDTwin Kernel.
* **Environment:** System Native (Root).

```bash
cd ~/Desktop/NDTwin-Kernel/build

sudo bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyMininet_10Switches.json \
    --no-ai --loglevel info
```

> **Why the flags.** Without `--mode`, `--topology` and `--ai`/`--no-ai`, the kernel **stops and
> asks you three questions** before it starts:
>
> ```
> Select your deployment environment:   [1] Local Mininet  [2] Remote Testbed
> Select your Mininet Topology:         [1] OVS Environment (128 Hosts)  [2] P4 / BMv2 Environment (4 Hosts)
> Do you want to enable Intent Translator (requires OpenAI Token)?   [1] Yes  [2] No
> ```
>
> For this page the answers are **1**, **1**, **2** — which is exactly what the three flags
> above say, without anyone having to be at the keyboard. It only prompts when it has a
> terminal; run from a script or with output piped it exits with a usage message instead, so
> the flags are the form that works everywhere.

> **If you want the Intent Translator**, replace `--no-ai` with `--ai` and export a real key
> first, remembering `sudo -E` so the variable survives:
> ```bash
> export OPENAI_API_KEY="sk-..."
> sudo -E bin/ndtwin_kernel --mode mininet \
>     --topology ../setting/StaticNetworkTopologyMininet_10Switches.json \
>     --ai --loglevel info
> ```
> A placeholder key is not needed with `--no-ai`: the flag is what disables the feature, not the
> absence of a key.
![Alt text](/images/ndtwin_launching.png)


### Generating Traffic (Validation)

To test if the system is working, you can generate traffic inside the **Mininet CLI** (Terminal 2).

1. **Start an iperf3 server on Host 1:**
```bash
mininet> h1 iperf3 -s &

```


2. **Run a client on Host 2 — in the background, with the `&`:**
```bash
mininet> h2 iperf3 -c h1 -t 300 &

```

> **The `&` matters.** Without it the transfer holds the Mininet prompt for the full five
> minutes, and by the time you get to Step 3 the flow has already been dropped from the
> table — see the timing warning below.


3. **While the transfer is still running**, query the API from a normal terminal (not the
Mininet prompt):
```bash
curl -X GET http://localhost:8000/ndt/get_detected_flow_data
```

**Expected:** a JSON array with **two** records for the transfer you just started — one per
direction. Your own two hosts must appear in them. On the fabric this manual builds, `h1` is
`10.0.0.1` and `h2` is `10.0.0.2`, and one record will carry `"src_port": 5201` (the iperf3
server) while the other carries it as `"dst_port"`.

> **Addresses are reported as integers, not as `10.0.0.1`.** The field reads
> `"src_ip": 16777226`. Decode one with:
>
> ```bash
> python3 -c "import struct,sys; print('.'.join(str(b) for b in struct.pack('<I',int(sys.argv[1]))))" 16777226
> ```
>
> which prints `10.0.0.1`. An empty array `[]` is **not** a pass — see below.

> ⚠️ **A flow disappears 15 seconds after its last packet.** The kernel purges idle flows
> (`FLOW_IDLE_TIMEOUT`, 15 s, swept once a second), so if you query after the transfer has
> finished you will get `[]` from a perfectly healthy system. `[]` while traffic is flowing
> means something is wrong; `[]` after it stopped just means you waited too long. Re-run the
> client and query while it is still going.

![Alt text](/images/ndtwin_api_demo.png)

See more NDTwin API docs in [NDTwin API](/docs/ndtwin-developer-manual/ndtwin-application/ndtwin-kernel-api/).


---

### Safe Shutdown Procedure

`ndt down` does all of this and then proves the machine is clean. By hand, in **reverse order**:

1. In **Terminal 2 (Mininet)**, type `exit` to quit the CLI.
2. The script will automatically remove the IP alias.
3. Run a final cleanup command in Terminal 2:
```bash
sudo mn -c

```


4. Close all other terminal windows.

> 🔴 **Step 3 already killed your Ryu controller — Terminal 1 will be gone before you get to
> step 4.** `mn -c` runs a `killall` over a list of processes it considers Mininet's, and
> `ryu-manager` is on that list. Nothing announces this; the terminal simply ends.
>
> Two consequences worth knowing. **If you meant to keep the controller running** between
> fabrics, `mn -c` is not a safe cleanup — restart it afterwards. And **if you are scripting
> this**, do not treat "Ryu is gone" after step 3 as evidence that your own shutdown logic
> worked, because `mn -c` would have produced the same state on its own. Observed on a clean
> Ubuntu 24.04 guest, 2026-09-01.

> ⚠️ **The kernel prints `terminate called without an active exception` as its last line on
> Ctrl-C**, *after* `All subsystems stopped. Exiting.` The shutdown sequence itself completes —
> every subsystem reports stopping first — but the process leaves through an abort path rather
> than a normal exit, so the shell reports it as killed. It is not a sign that cleanup failed.
> Same guest, same date; the cause has not been traced.

---

## (Optional) Running on a P4 / BMv2 Data Plane

Everything above runs the emulated network on Open vSwitch. If you completed
**Section 6 of the [Installation Manual](/docs/ndtwin-installation-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/)**,
you can run the same network on BMv2 software P4 switches instead. This section replaces
Terminals 1–3 above; nothing else about NDTwin changes.

The example below uses the **10-switch, 128-host** fabric.

### ⚠️ The startup order for P4 is the reverse of the OVS order

This is the single most important difference, and it follows from which side opens the
socket:

| Mode | Who listens | Correct order |
| :--- | :--- | :--- |
| **OVS** | **Ryu** listens on `6633`; the switches dial in | Ryu → Mininet → wait → Kernel |
| **P4** | **BMv2** listens on `50051`–`50060`; the proxy is a gRPC **client** | **Mininet → Proxy** → wait → Kernel |

In both modes the kernel starts **last**.

**Pre-flight Checks:**

1. **Pipeline compiled:** `p4_proxy/p4_src/build/ndtwin_switch.json` exists (Installation Step 6.2).
2. **Proxy environment:** `p4_proxy/venv/` exists (Installation Step 6.3).
3. **Sizes agree:** `p4_proxy/mininet/host_count_override` contains `128`, and you will pass
   the matching 128-host topology to the kernel (Installation Step 6.5).
4. **Binary override:** `p4_proxy/mininet/bmv2_binary_override` names a `simple_switch_grpc`
   that actually exists on this machine. It must name one explicitly — commenting the line
   out or deleting the file does **not** fall back to your `PATH`, it refuses to start the
   fabric
   ([Installation Step 6.6](/docs/ndtwin-installation-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/#step-66-check-the-bmv2-binary-override-before-your-first-run)):

   ```bash
   p=$(grep -vE '^[[:space:]]*(#|$)' p4_proxy/mininet/bmv2_binary_override | head -1)
   [ -x "$p" ] && echo "OK: $p" || echo "PROBLEM: ${p:-<nothing selected>}"
   ```

### Terminal 1: BMv2 Mininet Topology

* **Purpose:** Builds the P4 fabric and starts one BMv2 switch process per switch.
* **Environment:** System Native (Root).

```bash
cd ~/Desktop/NDTwin-Kernel
sudo python3 p4_proxy/mininet/p4_testbed_topo.py
```

Wait for the verification line, then the Mininet prompt:

```
All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060
Switch manifest: /tmp/ndtwin_p4_switches.json
mininet>
```

> **Confirm with the manifest, not just the message.** `/tmp/ndtwin_p4_switches.json`
> lists only the switches that actually passed verification — process alive *and* gRPC port
> listening. A switch missing from the manifest is a switch that did not come up:
>
> ```bash
> python3 -m json.tool /tmp/ndtwin_p4_switches.json | head -20
> ```

> **Note:** The script runs `sudo pkill -f simple_switch_grpc` at startup, so leftover
> switches from a previous run are cleared for you.

### Terminal 2: P4 Proxy Agent

* **Purpose:** Presents Ryu's northbound API to the kernel, and drives the BMv2 switches
  over P4Runtime.
* **Environment:** `p4_proxy/venv` (its own virtualenv, **not** `ryu-env`).

The agent takes no arguments, and it must run with `p4_proxy` as its working directory —
it resolves the P4Info and pipeline paths relative to it:

```bash
cd ~/Desktop/NDTwin-Kernel/p4_proxy
PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py
```

The agent listens on port **8081**.

> **Note:** If the proxy log shows **`Connection refused`** against `:5005x`, the BMv2 switches are
> not up — go back to Terminal 1.

### Waiting for path installation (before starting the kernel)

The kernel reads the topology and the destination paths **once at startup and does not
retry**, so what matters is not elapsed time but whether discovery has finished moving.
Poll the proxy in a fourth terminal:

```bash
curl -s http://localhost:8081/ryu_server/all_destination_paths \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["all_destination_paths"]))'
```

**Expected for this fabric: `16256`** — that is every ordered host pair, 128 × 127.
(The 4-host fabric settles at `12`, in a couple of seconds.)

> **Wait for the number to stop changing, and do not treat the first large value as done.**
> The count does not necessarily rise monotonically while discovery is in progress; sample
> it a few times a few seconds apart and only start the kernel once consecutive samples
> agree. Starting the kernel while the count is still moving leaves the digital twin
> answering from an incomplete path set for up to a minute, with nothing in the log to say so.

A measured run of this 128-host fabric, sampling every three seconds from the moment the
proxy came up:

| time | count |
| ---: | ---: |
| +1 s | 155 |
| +4 s | 11424 |
| **+8 s** | **16224** |
| +11 s | 16256 |
| +15 s | 16256 (unchanged — now safe to start the kernel) |

The reading at +8 s is the one to be careful about. `16224` is **32 short** of the final
figure, which is 99.8% of it: large, stable-looking, and wrong. Nothing about it looks like
a value still in motion, so "wait until it settles" does not protect you from it.

The kernel does re-fetch, so an incomplete set is not permanent — but the recovery is slower
than you would expect, and for a reason worth knowing. The refresh thread retries every
**5 seconds while it has no paths at all**, and drops to every **60 seconds as soon as it has
any**. The test is *non-empty*, not *complete*. So a fetch that lands on `16224` counts as
loaded, and the twin answers path and switch-count queries from that set for up to a minute
before the next refresh replaces it.

Two agreeing samples cost you six seconds and avoid that window entirely.

Convergence took about 15 seconds here. It is fast because the work is proportional to the
number of host pairs, not to the number of switches — but do not substitute this timing for
the check on your own machine.

### Terminal 3: NDTwin Kernel

* **Purpose:** Starts the NDTwin Kernel against the P4 fabric.
* **Environment:** System Native (Root).

Pass the deployment options as flags. `--topology` is what selects the P4 fabric, and it
must name the same 128-host model that `host_count_override` was sized for:

```bash
cd ~/Desktop/NDTwin-Kernel/build

sudo ./bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyP4_10Switches_128Hosts.json \
    --no-ai --loglevel info
```

> **Flags versus prompts.** If you omit `--mode`, `--topology` or `--ai`/`--no-ai`, the
> kernel prompts for them interactively — but only when its standard input is a terminal.
> A headless run (a script, CI, `nohup`) must pass the flags; it will exit with a usage
> message rather than block. Run `./bin/ndtwin_kernel --help` for the full list.
>
> To enable the Intent Translator instead, use `--ai` and export a valid
> `OPENAI_API_KEY` first, remembering to run `sudo -E` so the variable survives.

Expected convergence for this fabric: **10 switches, all up and enabled, 288 edges**
(32 inter-switch edges plus 128 hosts counted in both directions). The 4-host fabric
reports **40** edges instead — if you see 40 while expecting 128 hosts, the kernel was
handed the wrong topology model.

> **One failed request to port 8080 at startup is expected and self-healing.** The
> telemetry collector starts before the topology file is loaded, so its very first query
> goes to Ryu's port (`8080`) before the kernel knows this is a BMv2 fabric. Once the
> topology is loaded it switches to the proxy's port (`8081`) and stays there. This is not
> an error you need to act on.

### Generating Traffic (Validation)

Exactly as in the OVS flow above — from the **Mininet CLI in Terminal 1**. Note the `&` on
*both* lines, so the prompt comes back and you can query while traffic is still flowing:

```bash
mininet> h1 iperf3 -s &
mininet> h2 iperf3 -c h1 -t 300 &
```

Then, **while the transfer is still running**, confirm the kernel is detecting flows:

```bash
curl -X GET http://localhost:8000/ndt/get_detected_flow_data
```

**Expected:** two records for that transfer, one per direction, naming your two hosts. The
same two cautions as in the OVS section apply here and are worth repeating, because both make
a working system look like a broken one:

> ⚠️ **Addresses come back as integers** (`"src_ip": 16777226`, which is `10.0.0.1`), and
> **a flow is purged 15 seconds after its last packet.** Querying after the transfer has
> ended returns `[]` on a perfectly healthy fabric. See the OVS section above for the
> decoding one-liner.

Verified on this fabric: with the transfer running, the endpoint returns both directions —
about 1.2 Gbit/s h2→h1 and the ACK stream back — each with the switch-level `path` the flow
took.

### Safe Shutdown Procedure

Shut down in reverse order:

1. **Terminal 3 (Kernel):** press `Ctrl+C`.
2. **Terminal 2 (Proxy):** press `Ctrl+C`.
3. **Terminal 1 (Mininet):** type `exit`.
4. Clean up Mininet state:

```bash
sudo mn -c
```

5. **Check for surviving BMv2 processes.** They can outlive `sudo mn -c`:

```bash
ps -eo args= | grep -c '[s]imple_switch_grpc'
```

> **Do not count them with `pgrep -c simple_switch_grpc`.** Linux truncates the process
> `comm` field to 15 characters, so that command reports `0` even with ten switches
> running. Either match on the full command line as above, or search for the truncated
> name `simple_switch_g`.

Any survivors are cleared automatically the next time you start the topology script.

6. **Confirm the proxy released port `8081`.**

```bash
ss -ltn | grep 8081 || echo "released"
```

> The agent serves from a **child** process, so the process you see is not always the one
> holding the port. Stopping it with `Ctrl+C` in its own terminal reaches both and releases
> `8081`; backgrounding it and killing only the parent does not. A proxy left listening is
> worse than an obvious failure — the next run connects to it happily and talks to a fabric
> that no longer exists.

7. **Confirm the kernel released port `8000`.**

```bash
ss -tln | grep :8000 || echo "released"
```

> **Nothing above this line looks at the kernel.** Steps 5 and 6 check the BMv2 switches and
> the proxy; a kernel still holding `:8000` passes both of them and is reported clean. That is
> not hypothetical — one was found still listening **14 minutes** after its terminal was
> stopped, and the only symptom was the *next* kernel refusing to start with
> `bind: Address already in use`, an error that names the port and not the cause.
>
> If something is still there, find it before you start a second kernel on top of it:
>
> ```bash
> sudo ss -ltnp | grep :8000
> ```
>
> ⚠️ **Check the port, not the log.** A shutdown sequence in the log is a claim about the
> process that wrote it, and if you have run the kernel more than once you may be reading an
> earlier run's file. `Ctrl+C` in the kernel's own terminal releases `:8000` within a few
> seconds (measured; the same signal sent to the `sudo` that started it also reaches the
> kernel), so anything still listening did not receive the signal. The usual reason is that
> the PID you signalled was not the kernel's: `$!` after `setsid nohup sudo … &` can name a
> wrapper that has already exited. Do not guess — take the PID from the `ss -ltnp` line above
> and signal that process.

---

