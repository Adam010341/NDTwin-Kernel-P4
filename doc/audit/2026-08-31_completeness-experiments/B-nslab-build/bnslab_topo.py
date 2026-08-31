#!/usr/bin/env python3
"""PREREG-B — single-hop bmv2 fabric for the guest, with the arm-selection mechanism.

[Co-developed with claude code -- Adam]

🔴 The arm-selection mechanism is the point of this file.  PREREG-B §2 v1.1 requires the
VM to have an equivalent of machine 1's `bmv2_binary_override`: the topology must take the
switch binary from a named file holding an ABSOLUTE PATH, and must REFUSE to start if that
file is missing or empty.  There is no PATH lookup and no fallback -- on machine 1 the
comment records why (`p4_testbed_topo.py:39`): a bare name resolved through PATH once and
silently selected the stock build, and both builds answer --version identically.

Topology: h1 --- s1 --- h2.  One hop, which is what the round measures.

Non-interactive mode (BNSLAB_NONINTERACTIVE=1): instead of dropping to the Mininet CLI,
write READY and block until STOP appears.  The eight-arm driver needs the fabric to
outlive the process that started it without a human at a prompt.
"""
import os
import subprocess
import sys
import time

from mininet.net import Mininet
from mininet.node import Host
from mininet.link import TCLink
from mininet.log import setLogLevel, info
from mininet.topo import Topo

HERE = os.path.dirname(os.path.abspath(__file__))
OVERRIDE = os.path.join(HERE, "bmv2_binary_override")
JSON = os.path.join(HERE, "p4", os.environ.get("BNSLAB_P4_JSON", "ndtwin_switch.json"))


def switch_binary():
    """Absolute path of the switch to launch.  Refuses rather than guessing."""
    if not os.path.isfile(OVERRIDE):
        sys.exit(f"REFUSE: {OVERRIDE} does not exist. The round must name its binary; "
                 "there is no default (PREREG-B §2 v1.1).")
    path = ""
    with open(OVERRIDE) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                path = line
                break
    if not path:
        sys.exit(f"REFUSE: {OVERRIDE} has no non-comment line.")
    if not os.path.isabs(path):
        sys.exit(f"REFUSE: {OVERRIDE} holds '{path}', which is not an absolute path. "
                 "A bare name would be resolved through PATH, which is how the stock "
                 "build was selected silently once already.")
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        sys.exit(f"REFUSE: {path} is not an executable file.")
    # And it must be the ELF, not the libtool wrapper -- see build_four_arms.sh.
    ftype = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout
    if not ftype.startswith("ELF"):
        sys.exit(f"REFUSE: {path} is not an ELF ({ftype.strip()}). The libtool wrapper "
                 "runs, so this would start a switch whose /proc/<pid>/exe is bash.")
    return path


class OneHop(Topo):
    def build(self):
        s1 = self.addSwitch("s1")
        for i in (1, 2):
            h = self.addHost(f"h{i}", ip=f"10.0.0.{i}/24", mac=f"00:00:00:00:00:0{i}")
            self.addLink(h, s1)          # no bw= : this fabric is UNSHAPED on purpose


def main():
    setLogLevel("info")
    binary = switch_binary()
    if not os.path.isfile(JSON):
        sys.exit(f"REFUSE: {JSON} missing -- compile the .p4 first.")

    info(f"*** switch binary (from bmv2_binary_override): {binary}\n")
    sha = subprocess.run(['sha256sum', binary], capture_output=True, text=True).stdout.split()[0]
    info(f"*** sha256: {sha}\n")
    info(f"*** json:   {JSON} (sha {subprocess.run(['sha256sum', JSON], capture_output=True, text=True).stdout.split()[0][:16]})\n")

    from p4_mininet import P4Switch                     # noqa: E402
    net = Mininet(topo=OneHop(), host=Host, link=TCLink, controller=None,
                  switch=lambda name, **kw: P4Switch(
                      name, sw_path=binary, json_path=JSON,
                      thrift_port=9090, pcap_dump=False, **kw))
    net.start()

    # Static ARP both ways. Only ipv4_lpm is programmed, so ARP (ethertype 0x0806) has no
    # table to hit; without this the first ping dissolves into an unanswered broadcast and
    # the ladder measures a path that was never established.
    h1, h2 = net.get("h1"), net.get("h2")
    h1.cmd("arp -s 10.0.0.2 00:00:00:00:00:02")
    h2.cmd("arp -s 10.0.0.1 00:00:00:00:00:01")

    # Record what actually launched, kernel-verified -- argv is the launcher's claim.
    #
    # 🔴 `sw.pid` is NOT the switch. p4_mininet's P4Switch.start() captures the bmv2 pid
    # into a local variable and discards it; `sw.pid` stays Mininet's node shell, whose
    # /proc/<pid>/exe is /usr/bin/bash. Asserting on it fails (correctly, 2026-08-31 smoke)
    # -- but note which assertions would NOT have failed: "a process exists", "the argv
    # looks right", "check_switch_started returned true". Only reading the kernel's own
    # view of the executable separates the switch from the shell that spawned it.
    #
    # So find it the way that cannot be fooled by any intermediary: scan every process for
    # one whose exe IS this binary, and require EXACTLY one. Zero means it died; more than
    # one means a previous arm's switch outlived `mn -c` (which bmv2 is known to do) and
    # this arm would be measuring an ambiguous population.
    def find_switch_pids(path):
        found = []
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                if os.readlink(f"/proc/{entry}/exe") == path:
                    found.append(int(entry))
            except OSError:
                continue          # gone, or not ours: both are "not a match"
        return found

    pids = find_switch_pids(binary)
    if len(pids) != 1:
        sys.exit(f"REFUSE: expected exactly 1 process running {binary}, found {len(pids)}: "
                 f"{pids}. Zero = the switch died at start-up. More than one = a previous "
                 f"arm's bmv2 survived teardown, and this arm's numbers would not have a "
                 f"single binary behind them.")
    swpid = pids[0]
    info(f"*** s1 bmv2 pid={swpid} /proc/{swpid}/exe -> {binary}  (node shell pid={net.switches[0].pid})\n")
    with open(os.path.join(HERE, "running_s1.txt"), "w") as fh:
        fh.write(f"bmv2_pid={swpid}\nnode_pid={net.switches[0].pid}\nexe={binary}\nsha256={sha}\n")

    info("*** fabric up. one hop, unshaped, control plane not yet programmed.\n")

    if os.environ.get("BNSLAB_NONINTERACTIVE") == "1":
        stop = os.path.join(HERE, "STOP")
        ready = os.path.join(HERE, "READY")
        if os.path.exists(stop):
            os.remove(stop)
        with open(ready, "w") as fh:
            fh.write(f"h1={net.get('h1').pid}\nh2={net.get('h2').pid}\n"
                     f"bmv2={swpid}\nnode_s1={net.switches[0].pid}\n"
                     f"binary={binary}\nsha256={sha}\n")
        info(f"*** READY written; waiting for {stop}\n")
        while not os.path.exists(stop):
            time.sleep(1)
        os.remove(ready)
        info("*** STOP seen; tearing down.\n")
    else:
        from mininet.cli import CLI
        CLI(net)
    net.stop()


if __name__ == "__main__":
    main()
