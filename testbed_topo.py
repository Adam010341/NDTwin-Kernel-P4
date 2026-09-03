#!/usr/bin/env python3

# [Co-developed with claude code -- Adam]
# Mininet is installed for the SYSTEM python, in /usr/lib/python3/dist-packages, and this file is
# launched by two interpreters that do not have that directory on sys.path:
#
#   sudo /home/adam/miniconda3/envs/ntg-env/bin/python testbed_topo.py
#       tools/test_workflow/ndtwin-lab `ovs-topo-start`, i.e. what `ndt up ovs` runs.
#   sudo python3 testbed_topo.py
#       what stack.sh prints for the operator -- `python3` on this machine is conda's.
#
# Without these two lines both die at the first import with ModuleNotFoundError: mininet, the
# tmux window exits instantly, and `ndt up ovs` then waits 300 s for a fabric that was never
# going to be built. Appending (not inserting) leaves a real system python's own paths in front.
#
# 🔑 The lines are not new: NTG's copy of this file has carried them since it was written, and
#    tools/test_workflow/ovs_4host_topo.py -- the sibling this lab already launches under the
#    same interpreter -- carries the first one and its docstring says "testbed_topo.py already
#    uses" it. They were lost when this copy was imported into the repo. Nothing noticed,
#    because until finding #77 nothing in ndt's paths ever executed this copy.
import sys

sys.path.append('/usr/lib/python3/dist-packages')
sys.path.append('/usr/local/lib/python3/dist-packages')

from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import RemoteController, OVSKernelSwitch
from mininet.cli import CLI
from mininet.log import setLogLevel
from mininet.link import TCLink
import dataclasses
import os
import re
import threading

# --- Global Configuration ---

# The number of hosts to create in the topology.
HOST_NUM = 128

# The IP address that our sFlow collector will receive packets on.
# We will add this IP as an alias to the host's loopback 'lo' interface.
COLLECTOR_IP = "192.168.123.1"

# The base of the IP address range for our sFlow management network.
# Switches will be assigned IPs from this range.
MGMT_IP_BASE = "192.168.123."


class MyTopo(Topo):
    """
    Custom topology definition.
    """

    def build(self):
        # Add switches to the topology.
        s1 = self.addSwitch("s1")
        s2 = self.addSwitch("s2")
        s3 = self.addSwitch("s3")
        s4 = self.addSwitch("s4")
        s5 = self.addSwitch("s5")
        s6 = self.addSwitch("s6")
        s7 = self.addSwitch("s7")
        s8 = self.addSwitch("s8")
        s9 = self.addSwitch("s9")
        s10 = self.addSwitch("s10")

        # Add links between switches to form a resilient core network.
        self.addLink(s1, s5, bw=1000, port1=1, port2=1)
        self.addLink(s1, s6, bw=1000, port1=2, port2=1)
        self.addLink(s2, s5, bw=1000, port1=1, port2=2)
        self.addLink(s2, s6, bw=1000, port1=2, port2=2)
        self.addLink(s3, s7, bw=1000, port1=1, port2=1)
        self.addLink(s3, s8, bw=1000, port1=2, port2=1)
        self.addLink(s4, s7, bw=1000, port1=1, port2=2)
        self.addLink(s4, s8, bw=1000, port1=2, port2=2)
        self.addLink(s5, s9, bw=10000, port1=3, port2=1)
        self.addLink(s5, s10, bw=10000, port1=4, port2=1)
        self.addLink(s6, s9, bw=10000, port1=3, port2=2)
        self.addLink(s6, s10, bw=10000, port1=4, port2=2)
        self.addLink(s7, s9, bw=10000, port1=3, port2=3)
        self.addLink(s7, s10, bw=10000, port1=4, port2=3)
        self.addLink(s8, s9, bw=10000, port1=3, port2=4)
        self.addLink(s8, s10, bw=10000, port1=4, port2=4)

        # Create and add hosts to a list.
        hosts = []
        for i in range(1, HOST_NUM + 1):
            host = self.addHost(f"h{i}")
            hosts.append(host)

        # Connect the first quarter of hosts to switch s1.
        # Assign port numbers in 3, 4, 5, 6, ... order to avoid conflicts.
        for i in range(int(HOST_NUM / 4)):
            self.addLink(hosts[i], s1, bw=1000, port1=1, port2=i + 3)

        # Connect the second quarter of hosts to switch s2.
        for i in range(int(HOST_NUM / 4), int(HOST_NUM / 2)):
            self.addLink(
                hosts[i], s2, bw=1000, port1=1, port2=i - int(HOST_NUM / 4) + 3
            )

        # Connect the third quarter of hosts to switch s3.
        for i in range(int(HOST_NUM / 2), int(3 * HOST_NUM / 4)):
            self.addLink(
                hosts[i], s3, bw=1000, port1=1, port2=i - int(HOST_NUM / 2) + 3
            )

        # Connect the last quarter of hosts to switch s4.
        for i in range(int(3 * HOST_NUM / 4), HOST_NUM):
            self.addLink(
                hosts[i], s4, bw=1000, port1=1, port2=i - int(3 * HOST_NUM / 4) + 3
            )


def find_ovs_agent_iface(switch):
    """
    Finds the correct network interface name for a given switch.
    In Mininet, the management interface for a switch (e.g., 's1') is
    named after the switch itself. This function reliably finds it.
    """
    for intf in switch.intfList():
        if not intf.name.startswith("lo") and "s" in intf.name:
            return intf.name
    return switch.name  # Fallback to the switch name.


def enable_sflow(switch, agent_iface, collector_ip, collector_port=6343):
    """
    Generates and executes the ovs-vsctl command to enable sFlow on a switch.
    Args:
        switch (str): The name of the switch (e.g., "s1").
        agent_iface (str): The network interface to use as the sFlow agent.
        collector_ip (str): The IP address of the sFlow collector.
        collector_port (int): The UDP port of the sFlow collector.
    """
    target = f"{collector_ip}:{collector_port}"
    # The 'agent' parameter tells OVS which interface's IP should be used
    # as the source IP for sFlow datagrams. This is crucial for identification.
    cmd = (
        f"ovs-vsctl -- --id=@sflow create sflow agent={agent_iface} "
        # [Co-developed with claude code -- Adam]
        # polling=0 disables sFlow counter samples, and that is correct here -- do not "fix" it.
        #
        # I changed it to 10 on 2026-08-07 believing it was why get_average_link_usage read 0.0, and
        # that was wrong. In MININET mode the kernel discards every counter sample before using it
        # (FlowLinkUsageCollector.cpp, the `m_mode == utils::MININET` early continue in the
        # sampleType 2 branch) and derives link utilisation from *flow* samples instead, via
        # m_counterReports. Counter samples are only read on the TESTBED path, whose fixed offsets
        # are calibrated for Brocade and HPE hardware.
        #
        # The 0.0 had nothing to do with any of that: the traffic was h1 to h2, and both are on
        # dpid 1, while getAvgLinkUsage counts switch-to-switch edges only. Re-run across the fabric
        # -- 10.0.0.1 to 10.0.0.100, which is dpid 1 to dpid 4 -- and it reads 0.166, 0.256, 0.278
        # and back to 0.0 when the traffic stops. The metric was right and I was measuring the
        # wrong link.
        #
        # So enabling polling here buys nothing in MININET and only adds datagrams.
        f'target=\\"{target}\\" header=128 sampling=256 polling=0 '
        f"-- set bridge {switch} sflow=@sflow"
    )
    os.system(cmd)


# --- the ping self-test, and the banner that is printed from it -----------------------------
#
# [Co-developed with claude code -- Adam]
#
# 🔴 The defect this section replaces (finding #42, measured 2026-09-03). ping_test() printed
# each ping and returned None; the threads that ran it discarded even that; and the closing
# banner printed three health claims
#
#     Host internet: OK | sFlow reachability: OK | Switch identification: OK
#
# UNCONDITIONALLY. There was no data flow of any kind from the 128 pings to those three OKs.
# Measured on a fabric where every one of the 128 pings was at 100% loss, and the banner still
# printed all three. A banner that cannot say anything but OK is not a check -- it is an
# instrument whose needle is painted on.
#
# What the pings can and cannot support is not the same for the three claims, and that is why
# the wording below changed as well as the wiring:
#
#   host reachability      -- this the pings DO measure, and it is what the banner now reports,
#                             with the counts it was computed from. The old wording ("Host
#                             internet") was wrong in a second way: these pings never leave the
#                             10.0.0.0/24 fabric and say nothing about internet access.
#   sFlow reachability     -- nothing in this script tests it. enable_sflow() runs its
#                             ovs-vsctl through os.system and discards the status; no datagram
#                             is ever read back here.
#   switch identification  -- nothing in this script tests it either. The agent addresses are
#                             assigned above and never verified against anything.
#
# The two unmeasured claims are printed as NOT MEASURED rather than deleted, so the next reader
# can see the claim was never backed instead of re-adding an OK for it. `ndt`'s verify_sflow is
# where those two are actually checked.
#
# The sibling fixture tools/test_workflow/ovs_4host_topo.py already had the right shape for a
# closing banner -- it states what was built (counts, addresses, model path) and claims no
# health at all.

#: iputils prints "1 packets transmitted, 1 received, 0% packet loss, time 0ms"; BSD ping and
#: some busybox builds print "... 1 packets received, 0.0% packet loss"; and an unreachable
#: destination makes iputils insert "+1 errors" between the two. All three spellings are read
#: here. Output this cannot read is counted as UNPARSED and never as a reply -- "we could not
#: tell" and "it answered" being the same value is the whole family of bug this fix is in.
_PING_STATS_RE = re.compile(
    r"(?P<tx>\d+)\s+packets\s+transmitted,\s*"
    r"(?P<rx>\d+)\s+(?:packets\s+)?received"
    r"[^\n]*?(?P<loss>\d+(?:\.\d+)?)%\s+packet\s+loss"
)


@dataclasses.dataclass(frozen=True)
class PingResult:
    """What one ping measured. `reached` is never true for output we could not read."""

    src: str
    dst: str
    transmitted: int = 0
    received: int = 0
    loss_pct: float = 100.0
    #: False when ping printed no statistics line at all, or never ran.
    parsed: bool = False
    error: str = None

    @property
    def reached(self):
        return self.parsed and self.received > 0


@dataclasses.dataclass(frozen=True)
class PingSummary:
    """The only numbers the closing banner is allowed to claim anything from."""

    #: How many pings the caller LAUNCHED. Kept separate from `attempted` on purpose -- see
    #: summarize_pings().
    expected: int
    #: How many of them came back with a result of any kind.
    attempted: int
    #: How many DISTINCT (src, dst) pairs those results cover. Every ping in this self-test is
    #: a different pair, so a result recorded twice is a copy, not a second measurement.
    distinct: int
    replied: int
    lost: int
    #: Results whose ping output had no readable statistics line.
    unreadable: int
    loss_pct: float

    @property
    def ok(self):
        # 🔴 Zero tolerance, deliberately. Every host in this topology is given a static ARP
        # entry for every other one before these pings run, and the controller installs
        # proactive rules; one lost ping here is a fabric defect, not noise. If a future
        # operator wants to tolerate loss, that is a decision to write down here -- not a
        # threshold to discover by watching a banner stay green.
        #
        # Four clauses, each of which some plausible implementation passes while failing
        # another. `expected > 0`: a self-test that measured nothing must not read like a
        # self-test that passed. `attempted`: 129 results for 128 pings means one was recorded
        # twice and one may be missing. `distinct`: 128 results covering 64 pairs is a copied
        # measurement, not a fabric that answered 128 times. `replied`: the fabric answered.
        return (self.expected > 0
                and self.attempted == self.expected
                and self.distinct == self.expected
                and self.replied == self.expected)


class PingResults:
    """Thread-safe sink for PingResult.

    threading.Thread throws away whatever its target returns, which is precisely how the banner
    at the bottom of this file came to be printed from nothing. A ping that is not recorded here
    is not counted as anything.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._results = []

    def add(self, result):
        with self._lock:
            self._results.append(result)

    def all(self):
        with self._lock:
            return list(self._results)

    def __len__(self):
        with self._lock:
            return len(self._results)


def parse_ping_output(text):
    """(transmitted, received, loss_pct) from ping's statistics line, or None if it has none.

    None rather than a zero-loss guess: `connect: Network is unreachable` and a command that
    never ran both produce output with no statistics line, and reading either as success is
    the defect this whole section exists to prevent.
    """
    match = _PING_STATS_RE.search(text or "")
    if match is None:
        return None
    return (int(match.group("tx")), int(match.group("rx")), float(match.group("loss")))


def ping_test(src, dst_ip, sink=None):
    """
    Perform a single ping test, print the result, and RETURN what it measured.

    🔴 The return value is the point of this function. It is also appended to `sink` when one is
    given, because the callers below run this in threads and a thread discards its target's
    return value -- so the sink is the only path by which a number reaches the banner.
    """
    print(f"Pinging from {src.name} to {dst_ip}...")
    try:
        output = src.cmd(f"ping -c 1 {dst_ip}")
    except Exception as exc:
        # Broad on purpose: a torn-down namespace, a host object Mininet has already stopped, a
        # dead mnexec. Every one of those is a ping that did not happen, and the one outcome
        # this must never produce is a silently missing result -- an exception here used to kill
        # the thread, leave nothing behind, and be invisible.
        result = PingResult(src=src.name, dst=dst_ip,
                            error=f"{type(exc).__name__}: {exc}")
        print(f"Result from {src.name} to {dst_ip}: DID NOT RUN -- {result.error}")
    else:
        print(f"Result from {src.name} to {dst_ip}:\n{output}")
        stats = parse_ping_output(output)
        if stats is None:
            result = PingResult(src=src.name, dst=dst_ip,
                                error="ping printed no statistics line")
        else:
            transmitted, received, loss = stats
            result = PingResult(src=src.name, dst=dst_ip, transmitted=transmitted,
                                received=received, loss_pct=loss, parsed=True)
    if sink is not None:
        sink.add(result)
    return result


def summarize_pings(results, expected):
    """Fold the ping results into the numbers the banner reports.

    `expected` is how many pings were LAUNCHED and is passed in rather than taken from the
    results, because a thread that died before recording anything leaves no failed result
    behind. replied-over-attempted on an empty list is 0/0, which reads as "nothing went
    wrong"; a shortfall here is a failure, not a smaller sample.
    """
    results = list(results)
    replied = sum(1 for r in results if r.reached)
    return PingSummary(
        expected=expected,
        attempted=len(results),
        distinct=len({(r.src, r.dst) for r in results}),
        replied=replied,
        lost=expected - replied,
        unreadable=sum(1 for r in results if not r.parsed),
        loss_pct=100.0 if expected <= 0 else 100.0 * (expected - replied) / expected,
    )


def run_ping_self_test(net, host_num, sink=None):
    """Ping the lower half of the fabric against the upper half, both ways, and return what
    that measured.

    This is also the traffic that primes the controller's host discovery: the burst has to land
    before intelligent_router installs proactive rules, or the hosts are never punted to Ryu and
    read as down in the twin. See the same reasoning written out in
    tools/test_workflow/ovs_4host_topo.py.
    """
    pairs = int(host_num / 2)
    expected = 2 * pairs
    sink = PingResults() if sink is None else sink

    threads = []
    for i in range(pairs):
        client = net.get(f"h{i+1}")
        server_ip = f"10.0.0.{i+1+pairs}"
        t = threading.Thread(target=ping_test, args=(client, server_ip), kwargs={"sink": sink})
        threads.append(t)
        t.start()
    for i in range(pairs):
        server = net.get(f"h{i+1+pairs}")
        client_ip = f"10.0.0.{i+1}"
        t = threading.Thread(target=ping_test, args=(server, client_ip), kwargs={"sink": sink})
        threads.append(t)
        t.start()
    for t in threads:
        t.join()

    return summarize_pings(sink.all(), expected=expected)


BANNER_HEADER = "--- Final Configuration Active ---"


def banner_lines(summary):
    """The closing banner, derived from `summary` and from nothing else.

    Returns the lines to print. There is no path through this function that prints OK for a
    summary that is not ok, and none that prints a count it did not get from the summary.
    """
    lines = ["", BANNER_HEADER]
    if summary.ok:
        lines.append(
            f"host reachability: OK -- {summary.replied}/{summary.expected} pings replied "
            f"({summary.loss_pct:.1f}% loss)"
        )
    else:
        lines.append(
            f"host reachability: FAIL -- {summary.replied}/{summary.expected} pings replied, "
            f"{summary.lost} lost ({summary.loss_pct:.1f}% loss)"
        )
        if summary.attempted != summary.expected:
            lines.append(
                f"  ... {summary.attempted}/{summary.expected} pings reported a result at all; "
                f"the rest are missing, which is not the same as passing"
            )
        # `< attempted`, not `!= expected`: a result short of expected is a ping that never
        # reported, which the line above already says. This one is only for the other shape --
        # more results than pairs, i.e. one measurement recorded twice.
        if summary.distinct < summary.attempted:
            lines.append(
                f"  ... covering only {summary.distinct}/{summary.expected} distinct host "
                f"pairs; a result recorded twice is a copy, not a second measurement"
            )
        if summary.unreadable:
            lines.append(
                f"  ... {summary.unreadable} printed output this script could not read; "
                f"unreadable is counted as lost, never as reached"
            )
        lines.append(
            "  the Mininet CLI below is still available -- the fabric is built, not forwarding"
        )
    # Not measured anywhere in this script. Printed rather than dropped so the claim's absence
    # is visible; `ndt up ovs`'s verify_sflow is what actually checks these two.
    lines.append("sFlow reachability: NOT MEASURED (configured above, never read back here)")
    lines.append("switch identification: NOT MEASURED (agent IPs assigned above, never verified here)")
    return lines


if __name__ == "__main__":
    setLogLevel("info")

    # It's good practice to clean up any previous Mininet runs.
    # A good practice is to run 'sudo mn -c' in the terminal before starting.
    # os.system("sudo mn -c") # Uncomment if you want to automate this.

    topo = MyTopo()
    # Using RemoteController to connect to an external SDN controller (e.g., Ryu).
    net = Mininet(
        topo=topo,
        controller=RemoteController,
        switch=OVSKernelSwitch,
        link=TCLink,
        autoSetMacs=True,
    )

    # Bound before the try so the exit status below can tell "the self-test failed" from "we
    # never got as far as running it". [Co-developed with claude code -- Adam]
    ping_summary = None

    try:
        # == STEP 1: Add the IP Alias to the Host's Loopback Interface ==
        # This is the core of the solution. We give the host machine a "mailbox"
        # in our private management network, so it can receive sFlow packets.
        # This command is safe and does not affect normal network operations.
        print(f"Adding IP alias {COLLECTOR_IP}/24 to 'lo' interface...")
        os.system(f"sudo ip addr add {COLLECTOR_IP}/24 dev lo")

        net.start()

        # == STEP 2: Configure Each Switch with a Unique IP and sFlow Target ==
        # We loop through each switch, assign it a unique management IP, and tell it
        # to send sFlow data to our special collector IP alias.
        switch_ip_start = (
            11  # Starting from .11 to avoid collision with the collector's .1
        )

        switch_names = [
            f"s{i}" for i in range(1, 11)
        ]  # List of switch names (s1 to s10)
        for i, sw_name in enumerate(switch_names):
            sw = net.get(sw_name)
            iface_name = find_ovs_agent_iface(sw)

            # Assign a unique IP to the switch's management interface.
            switch_ip = f"{MGMT_IP_BASE}{switch_ip_start + i}"
            sw.cmd(f"ifconfig {iface_name} {switch_ip}/24 up")

            print(f"Configuring sFlow for {sw_name}:")
            print(f"  - Agent IP (source): {switch_ip}")
            print(f"  - Target Collector: {COLLECTOR_IP}:6343")

            # Enable sFlow, pointing to our collector's IP alias.
            enable_sflow(
                switch=sw_name, agent_iface=iface_name, collector_ip=COLLECTOR_IP
            )

        # Display the current sFlow configuration for verification.
        os.system("ovs-vsctl list sflow")

        # == Standard Mininet Host and Network Configuration ==
        # The following section sets up the IP addresses, MACs, and ARP entries
        # for the hosts within the simulation, enabling them to communicate.
        for i in range(1, HOST_NUM + 1):
            h = net.get(f"h{i}")
            ip = f"10.0.0.{i}/24"
            mac = f"00:00:00:00:00:{i:02x}"
            h.setIP(ip)
            h.setMAC(mac)

        for i in range(HOST_NUM):
            src = net.get(f"h{i+1}")
            for j in range(HOST_NUM):
                if i == j:
                    continue  # skip adding an ARP entry to itself
                dst_ip = f"10.0.0.{j+1}"
                dst_mac = f"00:00:00:00:00:{(j+1):02x}"
                src.cmd(f"arp -s {dst_ip} {dst_mac}")

        # Launch ping tests in parallel to generate some traffic -- and to measure whether the
        # fabric forwards it. The banner below is printed from this and from nothing else.
        ping_summary = run_ping_self_test(net, HOST_NUM)

        for line in banner_lines(ping_summary):
            print(line)
        print("Run 'sflowtool -p 6343' in another terminal to see the data.")
        CLI(net)

    finally:
        # == STEP 3: Clean Up Gracefully ==
        # This 'finally' block ensures that our created IP alias is removed,
        # and the Mininet network is stopped, no matter how the script exits.
        # This keeps the host system clean.
        print(f"\nCleaning up: Removing IP alias {COLLECTOR_IP} from 'lo' interface...")
        os.system(f"sudo ip addr del {COLLECTOR_IP}/24 dev lo")
        net.stop()

    # [Co-developed with claude code -- Adam]
    # Exit status, decided 2026-09-03 after reading every caller of this file:
    #
    #   tools/test_workflow/stack.sh   prompt_for_mininet() only PRINTS `sudo python3 <script>`
    #                                  and waits for the operator to press Enter -- Mininet needs
    #                                  root and drops into an interactive CLI, so stack.sh never
    #                                  runs this file and never sees its status.
    #   tools/test_workflow/ndtwin-lab `ovs-topo-start` launches it detached in a tmux session
    #                                  (and launches NTG's copy, not this one); nothing reads the
    #                                  window's exit code.
    #   tools/test_workflow/faults.sh  matches the process by name only.
    #
    # So no caller depends on this being 0, and the failing status below breaks nothing that
    # exists today. It is set anyway, because the alternative is a script that measured 100%
    # loss and still exits 0 -- the same shape as the banner this change was written to fix,
    # one layer down. The status is raised AFTER the CLI and after the cleanup in `finally`:
    # an operator whose fabric is broken needs the CLI more than an early exit, not less.
    if ping_summary is None or not ping_summary.ok:
        raise SystemExit(1)
