# NDTwin user guide

NDTwin is a digital twin of a network: a kernel that watches a live (or emulated) network through a
controller or a P4 proxy, keeps a model of its topology, links and flows, and serves it over a
REST API for applications. This guide is for someone who has built the kernel and now wants to
run an emulated lab on one machine: install what the lab needs, bring a fabric up, check it, run
applications against it and take it down again.

## 1. Where things are documented

| You want | Read |
|---|---|
| Build the kernel | [README](../README.md#build) |
| Install and run a lab (this guide) | this file |
| The REST API the kernel serves on port 8000 | [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) |
| Run your own P4 program in the lab | [2026-10-31_p4-app-guide.md](2026-10-31_p4-app-guide.md) |
| Drive the kernel from Python | [sdk/python/README.md](../sdk/python/README.md) |
| A known defect (they are cited by entry ID, for example `B-9`) | [KNOWN-ISSUES.md](KNOWN-ISSUES.md) lists the open ones; a message may also name the code of a fixed one, which [FIXED-ISSUES.md](FIXED-ISSUES.md) explains |
| OpenFlow request examples | the two cookbooks in this directory; their first lines say they are unverified |

The lab is driven by one command, `tools/test_workflow/ndt` (written `ndt` below). Run it from the
root of the checkout, or put it on your `PATH`. Its claim, records and logs go under `.test_run/` in the
checkout. It also writes three one-line files in `p4_proxy/mininet/` (`host_count_override`,
`app_package_override`, `telemetry_override`) and, for `ndt ntg`, the mode line of NTG's hosts file.

## 2. Install and build

1. Build the kernel as the [README](../README.md#build) describes. `ndt` refuses to bring a lab up
   without `build/bin/ndtwin_kernel`.
2. Install the software the fabric runs on. The installation and user manuals at
   <https://ndtwin.org/> list it; in short:
   - for both planes: `tmux`, Mininet (`mn`), `python3`;
   - for the OVS plane: Open vSwitch and Ryu in its own Python environment;
   - for the P4 plane: bmv2 (`simple_switch_grpc`), the P4 compiler `p4c-bm2-ss`, and the proxy's
     Python environment (below);
   - for `ndt ntg` and the NTG prompt: a checkout of Network-Traffic-Generator (NTG).
   Where each lives is declared once in `tools/test_workflow/components.env`; set the variable in
   your environment before running `ndt` to override a default (for example `NTG_PY`, `RYU_PY`,
   `CONDA_ROOT`). The sibling applications used by `ndt apps` are looked up next to the kernel
   checkout.
3. The P4 plane also needs the proxy's Python environment and a compiled pipeline:

   ```bash
   python3 -m venv p4_proxy/venv
   p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt
   p4_proxy/venv/bin/python p4_proxy/regen_p4runtime_pb2.py
   cd p4_proxy/p4_src && mkdir -p build && p4c-bm2-ss --arch v1model \
       -o build/ndtwin_switch.json --p4runtime-files build/ndtwin_switch.p4info.txt ndtwin_switch.p4
   ```

   Without them `ndt up p4` stops at its pre-flight with `proxy venv missing: p4_proxy/venv/bin/python`
   or `P4 pipeline not compiled: p4_proxy/p4_src/build/ndtwin_switch.json`. Always give
   `--p4runtime-files` that exact path: without it `p4c` writes a differently named p4info, and a second,
   stale p4info in `build/` is a hazard (the proxy loads it if pointed at it, and constructs missing from
   it fail silently).
   After you recompile, take the fabric down and bring it up again; a running switch keeps the old
   pipeline.

### Building bmv2 for realistic throughput

The `simple_switch_grpc` that common install scripts produce is a debug build (`-O0`, every logging
macro and the event logger on). Every table lookup formats a log message that is thrown away, and
runtime options such as `--log-level off` do not remove that cost, because the arguments are
evaluated before the level is checked. The ceiling is set in packets per second, not bandwidth:
about 3.6 kpps for 64-byte and 1400-byte packets alike (roughly 40 Mbps of UDP, 24 Mbps of TCP). A
percentage-based decision on top of it, such as a 70 % congestion threshold on links declared as
1 Gbps, can never trigger. Dropped packets are lost inside the first switch process, so the
interface counters of the veth pairs do not show them.

Build a second copy into its own prefix and keep the stock one:

```bash
./configure --prefix=/usr/local/bmv2-fast --with-pi --with-thrift \
    --disable-logging-macros --disable-elogger \
    'CXXFLAGS=-O3 -g -DNDEBUG -march=native -fno-semantic-interposition' \
    'CFLAGS=-O3 -g -DNDEBUG -march=native'
make -j"$(nproc)" && sudo make install    # do NOT run ldconfig afterwards
```

- Build from a fresh clone: an existing in-tree configuration makes autoconf refuse an out-of-tree
  configure.
- Never run `ldconfig` afterwards. Both builds ship libraries with the same sonames; without
  `LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib` the fast binary silently loads the debug libraries.
  Check `/proc/<pid>/maps` that nothing resolves to the old prefix.
- Re-run your functional tests against the fast binary before trusting a number from it.
- `--disable-elogger` removes the event stream some PTF tooling subscribes to; keep the elogger if
  you need it and drop only the logging macros.

Which binary a lab runs is chosen by the first non-comment line of
`p4_proxy/mininet/bmv2_binary_override`: the absolute path of the `simple_switch_grpc` to start. If
the file is missing, has no such line, or the line is not an absolute path to an executable, the
topology refuses to start rather than pick a binary. When the directory `<binary dir>/../lib` exists, it is set
as `LD_LIBRARY_PATH` for that binary (replacing any value you had). The file in the repository names
`/usr/local/bmv2-fast/bin/simple_switch_grpc`, the prefix used above: if you have not built that copy,
write the path of the binary you have (for example `/usr/local/bin/simple_switch_grpc`, the stock
build) on that line, or `ndt up p4` will not start.

| Same fabric, same path | debug build | performance build |
|---|---|---|
| UDP delivered ceiling (1400 B) | about 40 Mbps | about 460-530 Mbps |
| TCP goodput | about 24 Mbps | about 431 Mbps |
| 64-byte packets delivered | about 3.6 kpps | about 50.8 kpps |
| Idle round trip over 3 hops | about 9 ms | about 2.8 ms |

These come from one 14-core machine; measure your own fabric before relying on them.

## 3. Lab setup

### 3.1 The helper and what it may do as root

Starting Mininet and bmv2 needs root. `ndt` does not run as root; it calls one root-owned script,
`/usr/local/sbin/ndtwin-lab`, through `sudo -n`, and that script accepts a fixed list of verbs
(`topo-start`, `ovs-topo-start`, `ovs-topo-4host`, `topo-cmd`, `topo-out`, `topo-stop`, `cleanup`,
`energy-start`, `energy-stop`, `energy-out`, `sim-start`, `sim-stop`, `sim-out`, `heartbeat`,
`status`, `config`). Install it from the checkout, once, and again after you update the checkout:

```bash
sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
```

`ndt` compares the installed copy with the one in the checkout. When they differ it warns
`helper: /usr/local/sbin/ndtwin-lab is sha256 ..., tools/test_workflow/ndtwin-lab is ...` and prints
the install command; `ndt up` and `ndt down` run the installed copy, so a change you pulled does not
run until you reinstall it.

### 3.2 sudo grants

`ndt` calls `sudo -n` (never a password prompt) for three programs, and a missing grant would make
other lines of its output wrong rather than failing loudly, so `ndt status` tests all three:

| Program | What happens without it |
|---|---|
| `/usr/local/sbin/ndtwin-lab` | the `ndtwin-lab status` call fails, so `ndt` cannot tell whether a topology session is running: `ndt up p4` stops before it touches the fabric (rc 5), `ndt status` shows the topo session as unknown and lists it under `--check`, and `ndt clean` and `ndt down` say they cannot tell and end non-zero (`ndt down`'s stop and sweep are refused too, and it says they did not run and keeps the `ndt up` record) |
| `/usr/bin/ovs-vsctl` | with a topology session present and Open vSwitch running, `ndt up p4` cannot tell whether an OVS fabric is running, so it stops with `cannot tell whether an OVS fabric is running under the topo session` (rc 5, nothing built) rather than risk destroying one, unless the session is a running P4 fabric of the size asked for, which it reuses without asking; with Open vSwitch running and no bmv2 switch up, `ndt status` cannot tell the data plane and its up-target block (once a record exists) shows `cannot tell (ovs-vsctl refused; see the sudo grants block)` |
| `/usr/bin/mnexec` | the forwarding check at the end of `ndt up` cannot send its ping |

The kernel itself also runs programs through `sudo`. It starts without a terminal, so sudo cannot ask
for a password, and a missing grant makes the feature below fail:

| Program | The kernel uses it for | Without it |
|---|---|---|
| `/usr/bin/ovs-vsctl` | listing bridges for switch liveness, reading and restoring sFlow records and interface lists, creating and deleting bridges on power control | OVS switch liveness stays frozen at its last known state (the kernel logs `OVS switch liveness is frozen`); sFlow samples cannot be mapped to ports; power control fails |
| `/usr/sbin/ifconfig` (package `net-tools`) | only OVS power control: bringing a switch's ports up on power-on and down on power-off, and re-addressing the sFlow agent | power-on answers HTTP 500 and the switch stays down in the twin; power-off also answers 500, after the bridge has already been deleted |
| `/usr/sbin/tc` | only the link-fault API (`sudo -n tc qdisc show\|add\|del`) | the injection is refused |
| `/usr/local/sbin/ndtwin-p4-power` | only P4 power control: powering a bmv2 switch on or off; install it from `tools/p4_power_helper.py` (steps in that file's header) | P4 power control fails |

Grant only what you use. The default file below holds the three `ndt` grants. Add the optional lines
that follow it only for the feature they name; they are scoped to what the kernel actually runs, so
do not widen them to the bare programs.

Write the rule file somewhere safe, let `visudo` check it, and only then install it, so that a typo
cannot lock sudo:

```bash
tmp=$(mktemp)
cat > "$tmp" <<EOF
$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab
$USER ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl
$USER ALL=(root) NOPASSWD: /usr/bin/mnexec
EOF
sudo visudo -cf "$tmp" && sudo install -o root -g root -m 440 "$tmp" /etc/sudoers.d/ndtwin-lab
rm -f "$tmp"
```

These three grants make the user root on that machine: `mnexec` runs any command, and the helper runs
the NTG Python interpreter on a topology script from trees you can write, as root. Give them only on a
lab machine, to users who may be root there.

Optional lines, added inside the same heredoc (before `EOF`) and checked by the same `visudo -cf`:

```
# OVS power control only (names Mininet interfaces only; sudo 1.9.10 and later also accept an
# anchored ^regex$ in place of these globs, which is tighter)
$USER ALL=(root) NOPASSWD: /usr/sbin/ifconfig s[0-9]*-eth[0-9]* up, /usr/sbin/ifconfig s[0-9]*-eth[0-9]* down, /usr/sbin/ifconfig s[0-9]* * up
# link-fault API only
$USER ALL=(root) NOPASSWD: /usr/sbin/tc qdisc show dev s[0-9]*-eth[0-9]*, /usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* root netem *, /usr/sbin/tc qdisc add dev s[0-9]*-eth[0-9]* parent * netem *, /usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* root, /usr/sbin/tc qdisc del dev s[0-9]*-eth[0-9]* parent *
# P4 power control only
$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-p4-power
```

A glob in sudoers also matches spaces, so these lines pin the interface, not the whole command line.
Never grant bare `ifconfig`, bare `tc`, `sed` or `exportfs`: each of them is root on the machine.

Per-app NFS exports. When an application is deployed through the API, the kernel appends a line to
`/etc/exports` and reloads the NFS server, which needs root. A kernel started by `ndt` runs as you, so
it does not create the export: it logs `Per-app export line for <dir> is not active (writing
/etc/exports needs root)` and carries on, and clients can still mount through an export of the parent
directory if root has configured one. Its `sudo exportfs` and `sudo sed` calls exist only to clean up
a line that a root-run kernel left behind. Do not grant either one.

A sudoers rule must name the path the program really has; check it with `command -v ovs-vsctl mnexec`
(and `ifconfig`, `tc` if you use them), remembering that sudo looks programs up in its own
`secure_path`, which can differ from your `PATH`. `ovs-ofctl` is not needed. To read a switch's flow
table without sudo, ask Ryu: `curl localhost:8080/stats/flow/1`.

`ndt status` shows the result in its `sudo grants` row: `all 3 granted`, `refused -- readings below
them are not measurements`, or `could not be tested`. For every refused grant it prints what that
costs and the line to add, indented under the row (the last line names a document where the grant is
also described; the line above it is what you need):

```
                 sudo: ovs-vsctl  REFUSED -- ovs-vsctl list-br
                    without it: ...
                    grant it:   <user> ALL=(root) NOPASSWD: /usr/bin/ovs-vsctl
                    taught in:  ...
```

With `--check`, a refused or untestable grant counts as a problem. Only the three `ndt` grants are
tested; the kernel's own grants are not.

`mnexec` is also the way to run a command inside a Mininet host without the Mininet CLI:

```bash
sudo -n mnexec -a <host-pid> ping -c 2 10.0.0.2
```

### 3.3 The helper's config file `/etc/ndtwin-lab.conf` (optional)

The helper's built-in defaults point at paths under one developer's home directory. On any other
machine, or whenever the lab should run from a checkout other than the default one, write the config
file. The helper reads it as root and uses it only if root owns it; `ndt` reads `KERNEL_DIR` and
`NTG_DIR` from it too, as your user, under the same trust rules, so keep it mode 644:

```bash
sudo install -o root -g root -m 644 /dev/stdin /etc/ndtwin-lab.conf <<'EOF'
KERNEL_DIR=/home/<user>/NDTwin-Kernel
NTG_PY=/home/<user>/miniconda3/envs/ntg-env/bin/python
NTG_DIR=/home/<user>/Network-Traffic-Generator
EOF
sudo ndtwin-lab config      # shows what took effect
```

| Key | Meaning |
|---|---|
| `KERNEL_DIR` | the one checkout the helper acts in; it must contain `p4_proxy/mininet/ntg_bmv2_topo.py` |
| `NTG_PY` | the Python interpreter that runs the topology scripts |
| `NTG_DIR` | the Network-Traffic-Generator checkout the P4 bridge imports its CLI from; it must contain `network_traffic_generator.py` |
| `ENERGY_DIR` | where `energy-start` runs the Energy-Saving-App |
| `SIM_DIR` | where `sim-start` runs the Simulation-Platform-Manager |

All five keys may be omitted; an omitted key keeps its built-in default. The file is parsed, not
executed: one `KEY=VALUE` per line, `#` comments, values must be absolute paths without `..`, and any
other key is an error. Reinstall the helper (3.1) before you write `NTG_DIR=`: an older helper does
not know the key and refuses the whole file.

The helper refuses to use the file, and says why in red together with `sudo rm /etc/ndtwin-lab.conf`,
when the directory or the file is not owned by root or can be written by group or others (use mode
644), when the file is a symlink, when a key is unknown or a value is not an absolute path, or when
`KERNEL_DIR` is not a directory holding the bridge script. A refused file is never half applied. The
read-only verbs `status` and `config` then still run, on the built-in defaults; every verb that acts
(`topo-start`, `cleanup`, `*-start`, `*-stop`, ...) refuses to run; `heartbeat stop` and
`heartbeat status` also still run. Without the file the defaults
apply. If `NTG_DIR` is not an NTG checkout, `topo-start` stops at once and names the key instead of
starting a pane that dies.

Why a file and not an environment variable: the helper runs as root and starts a script from
`KERNEL_DIR`, so the choice of tree must belong to whoever administers the machine, not to whatever
runs as your user. For the same reason `ndt` does not pass the tree through the environment. The
first line of `sudo ndtwin-lab status` and `topo-start`'s output tell you which tree was used.

One consequence: the helper acts in **one** tree. `ndt up` compares its own checkout with the
helper's `KERNEL_DIR` before it touches anything and refuses (rc 1) when they differ, printing both
paths and the `host_count_override` each carries. Run `ndt` from the helper's tree, or point
`KERNEL_DIR` at the checkout you work in. Two checkouts cannot be live at the same time.

## 4. Running a lab with `ndt`

### 4.1 First look

```bash
export NDT_OWNER=my-name    # every ndt command needs this, see 4.2
ndt status                  # who has the lab, what is running, which settings apply
```

`ndt` with no verb, and `ndt help`, print the full usage and exit with 2. That is not a failure; in
a script under `set -e` write `ndt help || true`.

### 4.2 Claiming the lab: `NDT_OWNER`

Several people or scripts may share one machine. `ndt claim` reserves the lab for a while and
`ndt release` gives it back:

```bash
NDT_OWNER=my-name ndt claim 60 "measuring X"     # minutes (default 30), then a note
NDT_OWNER=my-name ndt release
```

- Set `NDT_OWNER` on **every** `ndt` command, not only `claim`. With it unset, every claim counts as
  somebody else's, including the one you just made. `ndt claim` itself answers
  `set NDT_OWNER first, so others can tell your claim from theirs` with rc 2.
- The `claim` row of `ndt status` has four distinct forms: `yours -- 68m left (until 03:27:18)`,
  `<other owner> -- 12m left (until ...)`, `EXPIRED ... -- treated as free`, and `none`. An expired
  claim is never worded like a live one.
- A second `ndt claim` on a held lab fails with rc 1. The claim is taken under a lock
  (`.test_run/lab.claim.lock`) and read back afterwards; the loser of a same-second race is told
  `beaten to it`.
- `ndt claim` keeps the claim it replaces in `.test_run/lab.claim.prev`, and `ndt release` renames
  the released claim to the same file. `ndt release` refuses while somebody else's claim is live
  (`ndt release --force` overrides), and also while the P4 host-count knob (4.4) differs from its
  value when you claimed; `ndt release --force` leaves it as it is.
- Optional declarations, set in the environment of `ndt claim`: `NDT_EXCLUSIVE_CPU=1` says no
  heavy local job (a VM, a compile) may overlap the claim; `ndt status` then shows the 1-minute load
  next to it and `--check` fails when the load shows the promise is not holding.
  `NDT_MEASURING='...'` declares a measurement in progress (below).

A claim is an agreement between `ndt` commands, not a lock. It blocks only the `ndt` verbs.
It is not the northbound API, and a program that calls `/ndt/install_flow_entry` keeps getting http 200
through its own claim's expiry and after another owner has taken the claim. Nothing signals a lapse
or a change of hands, to the API caller or to the previous holder. Re-read `ndt status`.

What the claim and a declared measurement block:

- `ndt up` refuses over somebody else's live claim, and while a measurement is in flight, on both
  planes (rc 5; nothing is built or written). The refusal prints the command to retry with the right
  owner and, last, the override: `ndt up ... --force`. Every `--force` that went past something is
  appended to `.test_run/lab.claim.overrides` (who, when, whose claim); if that line cannot be
  written the bring-up is refused. Exporting `NDT_UP_FORCE=1` does nothing: the flag must be on the
  command line. A `measuring=` declaration on your own claim never refuses `ndt up`.
- `ndt down` refuses over somebody else's claim, and over your own claim when its `measuring=` field is
  not empty (rc 5, nothing touched). `--force` is the only way past; `--deep` is not one. A forced
  `ndt down` clears `measuring=` and says so in the claim's note.
- The refusal prints `NDT_OWNER=<owner> ndt down` first, with `--force` last. Setting the right owner
  is almost always what you want; `--force` can tear down a lab somebody is using.

### 4.3 Bringing a lab up: `ndt up`

```bash
ndt up              # Ryu + OVS, 128 hosts (OVS is the default plane)
ndt up ovs          # the same
ndt up 4            # Ryu + OVS on the P4 test bed's 4-host layout
ndt up ovs4         # the same as ndt up 4
ndt up p4           # bmv2 at the current host count (see 4.4)
ndt up p4 4         # bmv2 at 4 hosts (rewrites host_count_override)
ndt up p4 128       # bmv2 at 128 hosts
ndt up p4 --app <dir>   # bmv2 on a P4 app package or tutorials exercise (2026-10-31_p4-app-guide.md)
```

- A bare `4` or `128` is an OVS size. `ndt up 4` is **not** P4; name the plane for P4.
- The OVS plane builds only 128 or 4 hosts, because each is a different helper verb. Any other number
  is a usage error (rc 2); `ndt up ovs 16` is refused. The P4 plane takes any multiple of 4 that is at
  least 4 for which a model file exists (4.4).
- The two fabrics cannot be live at once (the interface names collide). `ndt up p4` over a live OVS
  fabric stops with `an OVS fabric is running (N bridges) under the topo session ... take it down
  first:  ndt down`; the OVS bring-up likewise refuses when Mininet is already running.
- `ndt up p4 --telemetry {auto|none|cooperative|link}` chooses where a bmv2 switch's sFlow samples
  come from. `--app` and `--telemetry` are P4 flags: on the OVS plane they are usage errors (rc 2),
  not ignored arguments.
- `--force` goes past somebody else's claim or a measurement in flight, and is written down (4.2).

Progress is printed as numbered steps. P4: `[1/3] bmv2 fabric`, `[2/3] proxy + kernel`,
`[3/3] verify`. OVS: `[1/4] control plane (Ryu)`, `[2/4] data plane (OVS fabric)`,
`[3/4] proxy-less convergence + kernel`, `[4/4] verify`. The two planes start in opposite orders, and
`ndt up` encodes that: Ryu must already be listening when Mininet starts (switches dial out to it),
whereas bmv2 must already be running when the proxy starts (the proxy is the gRPC client and exits
if it cannot reach the switches).

Before it builds anything `ndt up` checks the claim, a running `ndt down`, that the helper acts in
this checkout, that the kernel binary, proxy environment and compiled pipeline exist, and that the
ports it needs are free. A port held by something that is not part of this checkout's stack is
refused (`refusing to build: a port this bring-up needs is held by a process that is not part of
this checkout's stack`). The last step, `verify`, sends a real ping between two hosts with `mnexec`,
because a topology view that is all green over a network that forwards nothing has happened. It ends
with `ok  data plane: <host> -> <ip> forwards`, or with `data plane: ... cannot reach ... -- fabric is
up but not forwarding` (a failure), or with `data plane: forwarding NOT tested -- <reason>` (neither
a pass nor a failure; the usual reason is a missing `mnexec` grant, with the line that fixes it).

The kernel's API is on `:8000`, the P4 proxy on `:8081` and Ryu's REST on `:8080`.

### 4.4 Host count and model files

Three layers decide what the lab looks like, and `ndt up` aligns them from the one number you give:

| Layer | Decided by |
|---|---|
| how many hosts the fabric builds | P4: `p4_proxy/mininet/host_count_override`. OVS: the verb (128 or 4) |
| the kernel's model | picked from `setting/` by host count; `NDT_TOPO=<file>` forces one |
| Ryu's model (OVS) | set by `ndt up` to the same file as the kernel's |

Ryu's own default model is `setting/StaticNetworkTopologyMininet_10Switches.json` (the 128-host Mininet model) in the
checkout that holds the `intelligent_router.py` Ryu loads, whatever the fabric size. Only `ndt up ovs` sets
`NDTWIN_RYU_TOPO_FILE` to the model it gives the kernel; a Ryu you start by hand, or with bare `stack.sh`, uses that default: set `NDTWIN_RYU_TOPO_FILE` to your model when it is a different one. Do not export the variable yourself when you use `ndt`.

Only `ndt up p4 <n>` and `ndt up p4 --app <dir>` write `host_count_override` (the second sets it to
the package's host count, and `ndt down` puts the previous value back). It is persistent state: the next bring-up inherits it,
so `ndt` prints `host_count_override: <old> -> <n> (persistent; affects every later run)`, and if you changed it with `ndt up p4 <n>` you are expected to write the old value back
(`echo <old> > p4_proxy/mininet/host_count_override`; `git checkout --` is not a restore). `ndt status` compares it with the value at `ndt claim` time in its
`knob baseline` row.

Model files shipped in `setting/`:

| Hosts | P4 | OVS |
|---:|---|---|
| 4 | `StaticNetworkTopologyP4_10Switches_4Hosts.json` | `StaticNetworkTopologyOVS_10Switches_4Hosts.json` |
| 8, 16, 32, 64 | none | `StaticNetworkTopologyOVS_10Switches_{8,16,32,64}Hosts.json` (not built by `ndt up`) |
| 128 | `StaticNetworkTopologyP4_10Switches_128Hosts.json` | `StaticNetworkTopologyMininet_10Switches.json` |

For another P4 size derive a model first (`tools/test_workflow/derive_p4_topology_json.py`, its
arguments are printed by the `no P4 topology model in setting/ has <n> hosts` refusal), or name one with
`NDT_TOPO`. `NDT_TOPO` naming a model of a different network than the host count asks for is refused
(rc 5).

### 4.5 Checking the lab: `ndt status`

```bash
ndt status                # a report; always exit 0
ndt status --check        # the same, but exit non-zero when something makes a measurement untrustworthy
ndt status --measuring    # only the rows that say whether somebody is measuring (no sudo, no kernel request)
```

The report includes these blocks:

```
lab                 claim, note, measuring, exclusive cpu, code (git commit and uncommitted files)
configuration       hosts, topology, p4 host knob, bmv2 binary, sample rate and where it was read from
running             bmv2 switches, topo session, host/switch processes, :8000 :8081 :8080, pidfiles
network health      switches up/enabled, links total/down, tc netem, sudo grants, apps
kernel graph        switch, host and edge counts from the kernel
proxy               (P4, only when :8081 answers) destination paths; --check fails if the count is not hosts x (hosts - 1) on NDTwin's own pipeline
up target           what the last ndt up asked for, compared with what is running
```

These are the main blocks; the report also has rows for the app package, telemetry and the heartbeat
daemon when they apply.

`code` is the git commit and the number of uncommitted files of the source, not a statement about the
binary: it does not show that `build/bin/ndtwin_kernel` was rebuilt after you edited C++. Compare the
timestamps (`ls -la build/bin/ndtwin_kernel`) before you measure. `configuration` decides every number you
measure: copy it into your report. `sample rate` is read back from what is running (the compiled
pipeline on P4, OVSDB on OVS), not from a setting; if no sample rate can be read, `--check` is red.

`ndt status --check` compares the live lab with what the last `ndt up` asked for, recorded in
`.test_run/up.target`: data plane, host count, kernel graph and the model file's checksum.

| rc | Meaning |
|---|---|
| 0 | everything compared matches |
| 1 | a problem; the message names it |
| 3 | nothing was compared: there is no baseline (`ndt down` clears it unless `verify clean` still finds the fabric; see 4.9) |

3 is never "checked and matched". `--check` also prints a `rules-in-window` row: flow rules installed
inside an app's time window and locks still held. `none` means it asked and found none; `N rule(s)
inside an app window, M lock(s) HELD` is a problem; `NOT CHECKED: ...` means it could not ask (kernel
down, flow table unreadable, or the P4 plane, whose flow statistics have no time axis) and is **not**
"clean". Rules found are an rc 1 only while a baseline exists; without one the problem is listed under
"everything else this report could still check" and the rc stays 3. `ndt` deletes none of these rules.

A pidfile in `.test_run/pids/` whose process is gone is marked STALE; `ndt down` removes it.
For the stack's own files (kernel, proxy, Ryu), a live pid that started after the pidfile was written is a recycled number and is stale at once, without asking the process group.
With a baseline, that is a `--check` problem (rc 1); without one the answer is still 3.
For an app's pidfile the mark is informational.

What a healthy lab looks like:

| Plane | Expect |
|---|---|
| P4 | `ndt status --check` exits 0 and prints `check: ok` |
| OVS | the last lines of `ndt up` say the data plane forwards. `--check` also lists links that are down; see below |

The kernel marks a link and a host up only after the controller reports it. A host is reported up
only once Ryu returns an IPv4 address for it, while the P4 proxy renders every host from its own
model with its address. If Ryu returns hosts without IPv4, the kernel's graph keeps those host links
down and `--check` lists `N link(s) are down` although traffic flows. On the OVS plane read the
`data plane` line of `ndt up` and the reported link count against what you expect, not the exit code
alone. `ndt status` also prints `/ndt/get_cpu_utilization is fabricated in MININET mode`: that
endpoint returns a constant unrelated to load in an emulated lab; measure CPU with
`tools/test_workflow/cpu_probe.py`.

`ndt check` is a separate verb, a tripwire for double counting in the telemetry: it compares the
twin's link rate with `/proc/net/dev` while traffic flows. rc 0 inside the +/-50% band or when there
was too little traffic (under 1 Mbit/s) to compute a ratio, so read the ratio block, not the code;
rc 1 when the kernel is not up, a declared measurement was refused, or the twin could not be read;
rc 4 when double counting was printed.

### 4.6 Sampling rate and the other knobs

| Change | How | Takes effect |
|---|---|---|
| host count (P4) | `ndt up p4 <n>` | next bring-up |
| bmv2 build | `p4_proxy/mininet/bmv2_binary_override` (section 2) | next bring-up |
| sampling rate (P4) | the `SAMPLE_RATE` constant in `p4_proxy/p4_src/ndtwin_switch.p4`, recompile (section 2) | after recompiling **and** restarting the fabric |

There is no runtime switch for the P4 sampling rate. If you recompile while a fabric is up, `ndt
status` reads the new JSON while the switches still run the old pipeline, so its sample rate describes
a fabric that is not running. It flags `the fabric predates the current build of ndtwin_switch.json`
and `--check` is red. Take the fabric down and up again.

### 4.7 Talking to the fabric: Mininet CLI or the NTG prompt

When the topology starts, its terminal (the tmux session `topo` of the helper; attach with
`sudo tmux -L ndtwinlab attach -t topo`) either drops into the Mininet CLI or hands control to NTG's
own prompt. The choice is made at bring-up and cannot change while the fabric runs. The choice exists
only on the P4 plane (NTG's P4 bridge reads it); the OVS topologies always end in Mininet's CLI, so
`ndt ntg` changes nothing there.

```bash
ndt ntg                  # which is selected
ndt ntg cli              # Mininet's CLI (mininet>)
ndt ntg custom_command   # NTG's prompt (the older name "prompt" still works)
```

`ndt ntg <mode>` edits a file in the NTG checkout and warns that it did (`edited <file> (the hosts
file NTG reads): mode <old> -> <new>`). It prints which file it reads, and it takes effect on the next
`ndt up` after an `ndt down`; a running topology keeps its mode. An unusable file is refused and left
for you to fix by hand, with the line named. The checkout is the helper's `NTG_DIR` (3.3); if the
file cannot be found, the error shows `NTG_DIR` and where its value came from. `ndt ntg` exits 0, 1
(refused or not found) or 2 (usage).

`ndt up p4` will not build a fabric for NTG to take over when NTG's config names a mode NTG does not
know or a hosts file that does not exist: NTG would fail on it, and the topology would stop and take
the switches with it after the bring-up had passed. It refuses with rc 5 before anything is built;
set a mode with `ndt ntg custom_command` (or `cli`), or fix the hosts file, and run the same `ndt up`
again.

Handy Mininet CLI commands: `nodes`, `net`, `h1 ping -c 3 h2`, `h1 ifconfig`, `iperf h1 h2`,
`sh <command>` (runs in the root namespace) and `exit` (which ends the topology, that is the whole
fabric). `pingall` over 128 hosts takes a long time. In NTG's prompt, `flow --config <file>` generates
traffic; NTG cannot interrupt an experiment (interrupting stops NTG), so wait for the finite flows to
end. Before the kernel is up NTG repeats `Failed to get hosts, retrying`; that is expected.

### 4.8 Applications: `ndt apps`

```bash
ndt apps                  # status, then (on a terminal) a picker
ndt apps nsr te           # start these
ndt apps stop energy      # stop one;  ndt apps stop all  stops every app
ndt apps status           # status only
ndt apps trim [names]     # bound a running app's log without stopping it
ndt apps orphans          # is anything of an app's still running, or still on the network?
```

| Name | Application | Changes the network? |
|---|---|---|
| `energy` | Energy-Saving-App | yes, it powers switches down |
| `te` | Traffic-Engineering-App | yes, it installs flow rules |
| `nsr` | Network-State-Recorder | no, it reads the kernel API |
| `sim` | Simulation-Platform-Manager | no |
| `viz` | Network-Traffic-Visualizer | no; a JavaFX GUI that needs a display |

Applications are separate repositories, found next to the kernel checkout (paths in
`tools/test_workflow/components.env`). They are deliberately not part of `ndt up`: two of them change
the network, so which are running is part of an experiment's setup. Start the kernel first; the apps
read its API. `ndt down` stops apps first. Their logs are `.test_run/logs/app_<name>.log`; `ndt apps`
prints each log's size and suggests `trim` when it is large.

`ndt apps stop` exits 0 when it stopped something, 1 when an app could not be stopped, and 2 when there
was nothing to stop. Both `stop` and `orphans` list the flow rules and locks an app may have left on the
network, and delete none of them. `ndt apps orphans` has its own codes: 0 nothing; 1 untracked app
processes are running; 2 a liveness channel could not look (the ordinary answer when the lab helper
started an app, because it runs as root and `/proc/<pid>/fd` is unreadable); 4 processes clean but a
rule or lock is still there; 5 processes clean and the rules-in-window could not be checked. The
process answer wins whenever it is non-zero. Do not read this rc as a gate: read the report through
`tools/test_workflow/orphans_verdict.sh`
(`ndt apps orphans > r.log 2>&1; bash tools/test_workflow/orphans_verdict.sh r.log $?`), which prints
`VERDICT: CLEAN`, `NOT CLEAN`, `NOT CHECKED` or `UNUSABLE`.

Two things outside `ndt`: the Web-GUI is a Docker container on `:3000` that you start and stop with
docker, and NTG is not a process but the prompt of 4.7.

### 4.9 Taking it down: `ndt down` and `ndt clean`

```bash
ndt down          # stop everything and prove the machine is clean
ndt clean         # the assertion only; it stops nothing
```

`ndt down` prints its steps: `[0/3] apps` (only if an app is running), `[1/3] kernel + proxy/Ryu`
(the processes registered in `.test_run/pids/`), `[2/3] topology session` (the helper's `topo-stop`,
which closes Mininet), `[3/3] sweep` (the helper's `cleanup`: stray topology and bmv2 processes, `mn -c`,
and the switch manifest), then `verify clean`.
Its steps can be repeated safely: if it was interrupted, run `ndt down` again and then `ndt clean`.
When sudo refuses the helper (3.2), `[2/3]` and `[3/3]` say they did not run and print the sudoers
line, and `ndt down` ends with rc 1. `ndt down` clears the `ndt up` record (`.test_run/up.target`)
unless `verify clean` still finds the fabric itself: bmv2 switches, Mininet hosts or switches, the
topo session, or a topo session it cannot read; it also keeps it when its own `verify clean` was
refused because another `ndt down` is running. Then it keeps the record, so `ndt status --check`
still compares against what was asked for. The next `ndt down` that finds none of the fabric clears
it, the next `ndt up` that builds a fabric replaces it (one that refuses leaves it as it is), and
once the fabric is gone you can remove it yourself (`rm .test_run/up.target`). When the topo session
could not be read, restore the sudo grant `ndt down` printed (3.2) and run `ndt down` again. Anything
else `verify clean` reports, such as a stranger holding a port, does not keep it.

`ndt clean` checks bmv2 processes, host/switch processes, the `topo` session, the switch manifest and
every port in the table of `tools/test_workflow/ports.sh`; `ndt help` prints that table's size and port
list under `down --deep`, computed from the file, so they are not repeated here. Everything passing
prints `ok  ports closed: <that list>` and `clean`. When something
is left it prints `XX` lines for each. Over a fabric you started yourself it names the processes your
own `.test_run/pids/` registered under `the fabric this stack started is still up`; only holders neither
that record nor the switch manifest knows are called strangers.

`ndt down` does not touch what it did not start. A stray holding a port is reported (`:8000 is still
listening, held by ...`; `ndt clean` adds `this stack did not start it; to kill it too:  ndt down --deep`)
and left alone. `ndt down --deep` kills whatever holds any
port of the table, including processes you did not start; use it only on a machine that is yours.
`ndt clean` stops nothing and deletes no logs, but it does clear a selected `--app` package (it prints
`app package cleared: <dir>`). It does not check veths, OVS bridges or namespaces, and nothing in `ndt`
removes `.test_run/`. `ndt status` counts leftover netem qdiscs in its `tc netem` row
(`N qdisc(s) still shaping -- leftover fault injection?`); `ndt down` removes them along with the
interfaces.

Links shaped with a bandwidth, which are every link of the OVS 128-host fabric and the links of an app
package that sets `bandwidth_bps`, are built with Mininet's TCLink and have an htb carrying the limit as
their root qdisc. On such a link, `tc qdisc add ... root netem` replaces the htb rather than adding a
layer, and a later `tc qdisc del ... root` restores the kernel's default qdisc, not the htb: the shaping
stays gone until `ndt down` and `ndt up` rebuild the links. Attach netem under htb's default class
(`parent <handle>:<default>` from `tc qdisc show`) and delete it at that same parent, as
`tools/test_workflow/faults.sh` does; on an unshaped link `root` is fine. A package link that sets
`delay_ms` already carries a netem (at the root when it has no bandwidth, under the htb when it has one),
and `faults.sh` refuses to add a second netem to any interface that has one.
`tools/test_workflow/qdisc_snapshot.sh save` before an injection and `diff` after it show whether the
qdisc tree came back unchanged.

### 4.10 Exit codes of `up`, `down` and `clean`

`ndt up`, `ndt down` and `ndt clean` share one set of exit codes. The right-hand column is what
`ndt help` prints for that code.

<!-- NDT-RC-TABLE:BEGIN
     Source: the up, down and clean blocks of `ndt help`. The right-hand column is copied from that
     output and tests/shell/test_manual_rc_table.sh checks it against the live help.
     Keep exactly one table of these codes in this guide. -->

| rc | Meaning | `ndt help` says |
|---|---|---|
| 0 | measured, and clean | `the teardown finished and the machine verified clean` |
| 1 | measured, and dirty | `something was MEASURED and is still there` |
| 3 | **nothing to measure**: an idle machine, a lab that was already down | `THERE WAS NOTHING TO JUDGE` |
| 5 | **a guard refused and the machine was not touched** | `A GUARD REFUSED and nothing was torn down` |
| 2 | usage error | `is a usage error` |

<!-- NDT-RC-TABLE:END -->

- 3 is not "clean". On an idle machine `ndt clean` prints `nothing to judge` and exits 3, and `ndt down`
  of a lab that is already down also exits 3 ("nothing was up to tear down"): tearing down ten
  switches and proving them gone, and there never having been a lab, are different statements.
- 5 means it did not look. The lab is claimed by somebody else, the claim declares `measuring=`, a
  measurement is running, another `ndt down` from this checkout is still running, or `NDT_TOPO` names
  a model of another network. Nothing was done. `ndt clean` also answers 5 while an `ndt down` of this
  checkout is running, because that teardown's own processes would otherwise be listed as residue. Read
  who refused and wait, or, when it names a missing sudo grant or NTG's config, fix what it names; 5 is
  neither clean nor dirty.
- `ndt up` exits 5 for the same refusals, and also when `--app`'s pre-flight failed, when NTG's config
  names a mode NTG does not know or a hosts file that does not exist (4.7), and when `ndt up p4` cannot
  tell whether a topology session, or an OVS fabric under one, is running because a sudo call failed
  (3.2). It never exits 3.
- `ndt down` exits 1 also when a component's recorded ending was a fatal signal (SIGKILL, SIGABRT,
  SIGSEGV) from an earlier session. That record is delivered once; the next `ndt down` is green again.
  It exits 1 too when a component it stops is still running 10 s after SIGTERM: that component is
  killed, and `[1/3]` says it `did not stop cleanly`. Measured 2026-11-08 on a Debug build in a VM
  with no fabric, `stack.sh` saw the kernel gone 1.0 to 2.1 s after SIGTERM; it was not measured on a fabric.
  `STOP_WAIT_TICKS` (half-second ticks, default 20) changes the wait; see `tools/test_workflow/README.md`.
  Read the `[1/3]` block, which names the component. A port held at `[1/3]` is not by itself a failed
  teardown: on a live P4 fabric it can only be naming the bmv2 ports about to be removed, so those
  ports are read again after `verify clean` and the rc follows the second reading.
- The codes cover only these three verbs. `ndt status --check` (4.5), `ndt check` (4.5), `ndt apps
  orphans` and `ndt apps stop` (4.8) have their own, and the same number means something else there.

<!-- NDT-RESTORE-CRITERION:BEGIN
     The only place this guide says how to decide that a lab was restored. What the rc values mean
     is in the table above; tests/shell/test_manual_rc_table.sh checks this paragraph. -->

**Deciding that a lab was restored** takes three things:

1. **`ndt clean` returns 0 or 3.** Both mean restored; a lab that was just taken down has nothing to
   judge, which is 3.
2. **`orphans_verdict.sh` prints `VERDICT: CLEAN`.** Do not read the rc of `ndt apps orphans`: its
   codes are another set (4.8).
3. **`ndt status --check` agrees with the state at the start of your work.**

All three together mean restored.

- `ndt down` itself passes with rc 0 or 3 (3 means there was nothing to tear down when it started); rc 1 means it measured something dirty.
- `ndt clean` returning 1 means something is still there, so the lab is not restored.
- `ndt clean` returning 5 means a guard blocked it and it checked nothing: read who is blocking, wait for it to finish, then judge again. 5 is not a pass for any of the three.

<!-- NDT-RESTORE-CRITERION:END -->

Over a live fabric a plain `ndt clean` returns rc 1: it is asserting that the lab is gone, and the lab
is there. Use `ndt down` to take it away.

### 4.11 Reading `ndt status`: the lab block

```
lab
  claim          alice -- 80m left (until 18:39:09)
  note           experiment: LLDP detection time at 4 vs 128 hosts
  measuring      nothing
  code           07ae07c  +4 file(s) with uncommitted changes
```

| Row | How to read it |
|---|---|
| `claim` | see 4.2 |
| `note` | a sentence the owner left; `ndt up` rewrites it to `in use: ...` and `ndt down` to `down at ... claim kept` |
| `measuring` | whether an `iperf3 -c` or similar is running. Anything but `nothing`: do not tear down |
| `declared` | what the claim's `measuring=` says is running |
| `code` | commit and uncommitted files of this checkout; record the commit with every number |
| `knob baseline` | `host_count_override` now versus at `ndt claim`. `<n> == the value this round started with` (the round starts at `ndt claim`) is fine; `<n>, written by 'ndt up p4 <n>' ... this round` is a warning, not a problem; `NOT RESTORED` means a hand edit and makes `--check` fail |
| `tree vs round` | which uncommitted files appeared or disappeared since the claim; informational |
| `prev claim`, `override` | the claim that was replaced or released, and the last `ndt up --force` |

The knob baseline lives in `.test_run/round.baseline`; `ndt release` moves it to `round.baseline.prev`.

## 5. Troubleshooting

Logs are in `.test_run/logs/` of the checkout: `kernel.log`, `p4_proxy.log`, `ryu.log`,
`topo.log` (the topology session) and `app_<name>.log`. On every start `stack.sh` moves the previous
`kernel.log`, `p4_proxy.log` and `ryu.log` aside as `<log>.<timestamp>` and keeps the newest
`NDT_LOG_KEEP` (default 5) of them, deleting older ones. `ndt down` and `ndt clean` never delete a log.
`ndt status --check` lists, in one place, every state that makes a measurement untrustworthy.

| What you see | Why, and what to do |
|---|---|
| `refusing to build: the lab is claimed by <owner>` (rc 5) | somebody holds the claim. If it is yours, set `NDT_OWNER` to that name; otherwise wait or ask. `--force` only if you know it is finished |
| `set NDT_OWNER first ...` | export `NDT_OWNER` (4.2) |
| `refusing to build: 'sudo /usr/local/sbin/ndtwin-lab' does not act in this checkout` | the helper's `KERNEL_DIR` is another tree (3.3) |
| `helper: /usr/local/sbin/ndtwin-lab is not installed` | install it (3.1) |
| `sudo: <program> REFUSED` in `ndt status` | add the printed sudoers line (3.2) |
| `/etc/ndtwin-lab.conf was REFUSED and is NOT in use` | read the reason; fix ownership and mode or `sudo rm` it (3.3) |
| `kernel binary missing: build/bin/ndtwin_kernel` | build the kernel (2) |
| `proxy venv missing` or `P4 pipeline not compiled` | section 2, step 3 |
| `refusing to build: a port this bring-up needs is held by a process that is not part of this checkout's stack` | something else owns the port. A stack started from another checkout counts as foreign here: take it down from that checkout with `ndt down`. For a stray nobody owns, `ndt down --deep` |
| `no P4 topology model in setting/ has <n> hosts` | 4.4 |
| `host count must be a multiple of 4 and at least 4` | `ndt up p4 <n>` constraint |
| `NDT_TOPO names a model of a different network` | unset `NDT_TOPO` or set the host count to the model's (rc 5) |
| `refusing to build: NTG does not know mode ...` or `refusing to build: the hosts file ... is not a file NTG can load` (rc 5) | NTG's config would stop the fabric after it came up (4.7): `ndt ntg custom_command` (or `cli`), or create the hosts file, then the same `ndt up` again |
| `--app is a P4 flag` / `--telemetry is a P4 flag` | you named the OVS plane (rc 2) |
| `ndt up` ends `forwarding NOT tested` | the `mnexec` grant is missing (3.2) |
| `[2/4]` or the topology never converges, and no log mentions a port | Ryu was not listening when Mininet started: start through `ndt up`, which starts Ryu first and waits for it. `ndt up` starts Ryu with its default listeners, 6653 and 6633. If you run your own Ryu, let it listen on both 6653 and 6633 (Ryu's default when `--ofp-tcp-listen-port` is not given): the 4-host layout connects to 6653 explicitly, only the 128-host layout probes 6653 then 6633, and OVS power-on reattaches a rebuilt bridge to `tcp:127.0.0.1:6633` |
| hosts cannot reach each other although everything looks right | Ryu loaded a model of another size (4.4); use `ndt up ovs4` (or `ndt up ovs`), which sets Ryu's model, instead of starting Ryu yourself |
| flows have no paths, or fewer destination paths than hosts imply | the kernel reads the controller's topology and destination paths once at start, with no retry, so anything not yet discovered stays invisible for the whole run. Bring the lab down and up through `ndt up`, which waits for convergence before it starts the kernel |
| `no lab sessions` although the fabric is running | `tmux` needs `TERM` to be set; `ndt` sets `TERM=dumb` itself. Set it when you call `sudo ndtwin-lab status` by hand |
| `an OVS fabric is running (N bridges) under the topo session` | `ndt up p4` will not tear an OVS fabric down for you: `ndt down` first |
| `pgrep -c simple_switch_grpc` returns 0 though switches run | the process name is cut to 15 characters in `/proc`; use `pgrep -cx simple_switch_g` or `ps -eo comm= \| grep -c '^simple_switch'` |
| `ndt down` returns 5 | read the lines it prints: another claim, a declared measurement, a measurement in flight or another teardown. They name the owner and the command to retry |
| `ndt down` returns 1 and the fabric is gone | see the note on earlier sessions in 4.10 |
| `ndt apps ...` says `viz is a JavaFX GUI and there is no display` | `viz` needs `DISPLAY` or `WAYLAND_DISPLAY` |
| nothing helps | `ndt status --check`, then the logs above |

**Do not**

- Use `pkill -f` or `pgrep -f`: the pattern matches the shell that runs it. Use `pgrep -x`, or put the
  command in a script file.
- Mix `ndt` with bare `ndtwin-lab` or `stack.sh`. `ndt` records what it starts in `.test_run/pids/`
  and bare commands do not, so `ndt down` cannot finish the job. If `ndt` itself is broken, the
  underlying steps are `sudo -n /usr/local/sbin/ndtwin-lab topo-start`, `bash tools/test_workflow/stack.sh up p4`,
  `... stack.sh wait`, `... stack.sh down`, `sudo -n ... topo-stop`; for OVS run `stack.sh up ovs` and
  `ovs-topo-start` in two terminals. Take it down yourself afterwards.
- Run `kill` or `pkill` inside a Mininet host: Mininet isolates only the network namespace, so the
  process id space is the machine's.
- Bring a link down with `ifconfig <iface> down` on bmv2: it stops forwarding for the whole switch. Cut
  one link with `tc netem loss 100%` on both ends, attached where `tools/test_workflow/faults.sh`
  attaches it: under htb's default class on a link shaped with a bandwidth, at `root` on an unshaped
  one. A link with a declared delay already has a netem, and `faults.sh` will not add another (4.9).
- Recompile the P4 pipeline while a fabric is up (4.6).

**Protecting bmv2's Thrift port.** bmv2's Thrift server (port 9090 + the switch's dpid, so
`9091-9100` for the shipped topologies) listens on every interface and cannot be told otherwise, and
anyone who reaches it can control the switch without a password. The gRPC ports (`30051-30060`)
listen on `127.0.0.1` only (`NDTWIN_BMV2_HOST`, see `p4_proxy/mininet/SPEC.md`). On a machine reachable
from other hosts, block new outside connections to the Thrift ports in a table of your own:

```bash
sudo nft add table inet ndtwin_guard
sudo nft add chain inet ndtwin_guard input '{ type filter hook input priority 0; policy accept; }'
sudo nft add rule inet ndtwin_guard input iifname != "lo" tcp dport 9091-9100 ct state new drop
```

An app package can use any dpid; for a largest dpid `D` widen the range to `9091-(9090 + D)`. While the
table exists these ports are blocked for every program (for example node_exporter on 9100). Check with
`sudo nft list table inet ndtwin_guard`; remove with `sudo nft delete table inet ndtwin_guard`. The
rules do not survive a reboot. To make them permanent put only this table in a file of its own
(for example `/etc/ndtwin-guard.nft`) and load it with `sudo nft -f` from a systemd unit, after
deleting the table; do not add it to `/etc/nftables.conf`, which usually starts with `flush ruleset`
and would remove the other host firewall rules (container networking, VPN) on reload.

## 6. Where to go next

- Your own P4 program: [2026-10-31_p4-app-guide.md](2026-10-31_p4-app-guide.md).
- The REST API and the Python client: [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md),
  [sdk/python/README.md](../sdk/python/README.md).
- Checking a running stack against the API contract:
  `bash tools/test_workflow/run_layers.sh api p4 --traffic` (or `api ovs`).
- `ndt serve` starts a local HTTP API and web page over `up`, `down`, `status`, `claim`, `release`
  and `apps`, on 127.0.0.1 only, for one user; `ndt serve --help` lists its options and
  `tools/ndt_serve/README.md` describes the API.
- A defect you hit: search [KNOWN-ISSUES.md](KNOWN-ISSUES.md) for the message you saw. A message that names a code you cannot find there names a fixed defect: look it up in [FIXED-ISSUES.md](FIXED-ISSUES.md).

[Co-developed with claude code -- Adam]
