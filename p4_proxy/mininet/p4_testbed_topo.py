#!/usr/bin/env python3

import json
import os
import signal
import socket
import sys
import tempfile
import time
from mininet.net import Mininet
from mininet.topo import Topo
from mininet.node import Switch, Host
from mininet.cli import CLI
from mininet.log import setLogLevel, info

# [Co-developed with claude code -- Adam]
# Where the switch manifest is written: name -> pid, grpc_port, thrift_port, device_id.
# P4PowerStrategy needs this to power one switch off without killing the other nine
# (Mininet switches share the root PID namespace, so `pkill -f simple_switch_grpc` kills
# all of them). See Phase 7 of doc/2026-07-27_p4_bmv2_support_plan.md.
MANIFEST_PATH = "/tmp/ndtwin_p4_switches.json"

class BMv2Switch(Switch):
    """BMv2 switch for Mininet"""
    def __init__(self, name, json_path=None, device_id=1, grpc_port=50051, thrift_port=9090, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.device_id = device_id
        self.grpc_port = grpc_port
        self.thrift_port = thrift_port
        self.log_file = f"/tmp/{self.name}_bmv2.log"
        # PID of the launched simple_switch_grpc, captured so stop() can target this one
        # switch and so the manifest can be written. None until start() runs.
        self.bmv2_pid = None
        self.launch_argv = None

    def start(self, controllers):
        args = ['simple_switch_grpc']
        for port, intf in self.intfs.items():
            if not intf.IP():
                args.extend(['-i', f'{port}@{intf.name}'])
                
        # args.extend(['--log-console'])
        args.extend(['--thrift-port', str(self.thrift_port)])
        args.extend(['--device-id', str(self.device_id)])
        
        if self.json_path:
            args.append(self.json_path)
        else:
            args.append('--no-p4')
            
        args.append('--')
        args.append('--grpc-server-addr')
        args.append(f'0.0.0.0:{self.grpc_port}')
        args.append('--cpu-port')
        args.append('255')
        
        cmd = ' '.join(args)
        self.launch_argv = cmd
        info(f"Starting {self.name} (gRPC: {self.grpc_port}, Thrift: {self.thrift_port})\n")
        # `echo $!` yields the background PID; cmd() returns the shell's output. Without this
        # there is no handle on the process at all, which is why stop() used a job spec.
        out = self.cmd(f"{cmd} > {self.log_file} 2>&1 & echo $!")
        try:
            self.bmv2_pid = int(out.strip().split()[-1])
        except (ValueError, IndexError):
            self.bmv2_pid = None

    def is_alive(self):
        """Whether the launched process still exists."""
        if self.bmv2_pid is None:
            return False
        try:
            os.kill(self.bmv2_pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def grpc_is_listening(self, timeout=0.3):
        """
        Whether anything accepts TCP on this switch's gRPC port.

        Checked in addition to the process being alive: bmv2 stays up briefly before its gRPC
        server binds, and a bind failure is reported by exiting, so both signals are needed to
        distinguish "still starting" from "died".
        """
        try:
            with socket.create_connection(("127.0.0.1", self.grpc_port), timeout=timeout):
                return True
        except OSError:
            return False

    def failure_reason(self):
        """
        Why this switch is not usable, or None when it is.

        [Co-developed with claude code -- Adam]
        Reads the switch's own log, which is where the real cause goes: bmv2's stderr is
        redirected to a file, so a bind failure ("Address already in use", the usual cause,
        from a leftover process holding the port) is completely invisible on the console.
        Nothing used to look at it, and the script reported success regardless.
        """
        if self.is_alive() and self.grpc_is_listening():
            return None

        detail = ""
        try:
            # errors="replace": bmv2 writes its own diagnostics here and can emit non-UTF-8
            # bytes. A UnicodeDecodeError is not an OSError, so it would escape this handler
            # and abort startup verification -- turning "one switch failed" into "the whole
            # topology script crashed".
            with open(self.log_file, encoding="utf-8", errors="replace") as fh:
                lines = [ln.strip() for ln in fh if ln.strip()]
            if any("Address already in use" in ln for ln in lines):
                detail = (f"gRPC port {self.grpc_port} was already in use -- most likely a "
                          f"leftover simple_switch_grpc from an earlier run")
            elif lines:
                detail = lines[-1][:300]
        except OSError:
            detail = "no log file"

        state = "process exited" if not self.is_alive() else "process alive but gRPC not listening"
        return f"{state}; {detail} (full log: {self.log_file})"

    def stop(self, deleteIntfs=True):
        # Kill this switch's PID rather than `kill %simple_switch_grpc`. The job spec only
        # works inside the shell that launched it, so closing the terminal left the process
        # running -- and those orphans are what hold the gRPC port and make the next run's
        # switch fail to bind.
        if self.bmv2_pid is not None:
            try:
                os.kill(self.bmv2_pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
        Switch.stop(self, deleteIntfs)

class MultiSwitchTopo(Topo):
    def __init__(self, **opts):
        Topo.__init__(self, **opts)
        
        json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')
        
        # Add 10 switches
        switches = {}
        for i in range(1, 11):
            s_name = f's{i}'
            # grpc_port: 50051-50060, thrift_port: 9091-9100, device_id: 1-10
            s = self.addSwitch(s_name, cls=BMv2Switch, json_path=json_path, 
                               device_id=i, grpc_port=50050+i, thrift_port=9090+i)
            switches[i] = s
            
        # Add links between switches (Same as original testbed_topo.py)
        self.addLink(switches[1], switches[5], port1=1, port2=1)
        self.addLink(switches[1], switches[6], port1=2, port2=1)
        self.addLink(switches[2], switches[5], port1=1, port2=2)
        self.addLink(switches[2], switches[6], port1=2, port2=2)
        self.addLink(switches[3], switches[7], port1=1, port2=1)
        self.addLink(switches[3], switches[8], port1=2, port2=1)
        self.addLink(switches[4], switches[7], port1=1, port2=2)
        self.addLink(switches[4], switches[8], port1=2, port2=2)
        
        self.addLink(switches[5], switches[9], port1=3, port2=1)
        self.addLink(switches[5], switches[10], port1=4, port2=1)
        self.addLink(switches[6], switches[9], port1=3, port2=2)
        self.addLink(switches[6], switches[10], port1=4, port2=2)
        self.addLink(switches[7], switches[9], port1=3, port2=3)
        self.addLink(switches[7], switches[10], port1=4, port2=3)
        self.addLink(switches[8], switches[9], port1=3, port2=4)
        self.addLink(switches[8], switches[10], port1=4, port2=4)
        
        # Add 4 hosts for testing (128 hosts in BMv2 might be too heavy)
        HOST_NUM = 4
        hosts = []
        for i in range(1, HOST_NUM + 1):
            mac_str = f"00:00:00:00:00:{i:02x}"
            ip_str = f"10.0.0.{i}/24"
            host = self.addHost(f"h{i}", ip=ip_str, mac=mac_str)
            hosts.append(host)
            
        # Connect hosts to s1-s4
        self.addLink(hosts[0], switches[1], port1=1, port2=3)
        self.addLink(hosts[1], switches[2], port1=1, port2=3)
        self.addLink(hosts[2], switches[3], port1=1, port2=3)
        self.addLink(hosts[3], switches[4], port1=1, port2=3)
        
def verify_switches(switches, timeout=10.0):
    """
    Wait for every switch to be up, and report the ones that are not.

    [Co-developed with claude code -- Adam]
    Returns a list of (name, reason). Empty means all are usable.

    Polls rather than sleeping a fixed amount: bmv2 needs a moment to bind its gRPC port, so
    an immediate check reports false failures, and a fixed sleep is either too short on a slow
    machine or wasted time on a fast one.
    """
    deadline = time.time() + timeout
    pending = list(switches)
    while pending and time.time() < deadline:
        pending = [sw for sw in pending if sw.failure_reason() is not None]
        if pending:
            time.sleep(0.5)
    return [(sw.name, sw.failure_reason() or "unknown") for sw in pending]


def write_manifest(switches, path=MANIFEST_PATH):
    """
    Record each switch's PID and ports so one switch can be managed on its own.

    [Co-developed with claude code -- Adam]
    Written for P4PowerStrategy (Phase 7): Mininet switches share the root PID namespace, so
    powering one switch off by pattern-matching the process name would kill all ten. Only
    verified-live switches are listed -- a manifest entry for a dead switch would be worse
    than no entry, since a caller would trust it.
    """
    manifest = {
        sw.name: {
            "pid": sw.bmv2_pid,
            "device_id": sw.device_id,
            "grpc_port": sw.grpc_port,
            "thrift_port": sw.thrift_port,
            "log_file": sw.log_file,
            "argv": sw.launch_argv,
        }
        for sw in switches
        if sw.failure_reason() is None
    }
    # Replace the inode, never truncate in place. /tmp is sticky, so anyone can create this
    # *name* before we run; open(path, "w") as root would truncate their file and leave them
    # the owner -- able to rewrite the argv that ndtwin-p4-power later executes as root. A
    # tempfile + os.replace makes the manifest a fresh inode owned by us every time, which is
    # exactly what the helper's owner check verifies before trusting the contents.
    # [Co-developed with claude code -- Adam]
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                                   prefix=".ndtwin_p4_switches.")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(manifest, fh, indent=2)
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except OSError:
            os.unlink(tmp)
            raise
    except OSError as e:
        print(f"WARNING: could not write the switch manifest to {path}: {e}")


def main():
    setLogLevel('info')
    
    json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')
    if not os.path.exists(json_path):
        print(f"Error: Compiled P4 JSON not found at {json_path}. Run 'p4c-bm2-ss' first in p4_src.")
        sys.exit(1)

    os.system('sudo mn -c > /dev/null 2>&1')
    # [Co-developed with claude code -- Adam]
    # `mn -c` does not touch bmv2, so a switch orphaned by a closed terminal keeps holding its
    # gRPC port and the matching switch in this run dies with "Address already in use". That
    # is a real failure we hit. Two Mininet topologies cannot coexist here anyway, and mn -c
    # above is already a full reset, so clearing these is consistent with what it does.
    os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')
    time.sleep(0.5)  # let the ports actually be released before anything tries to bind

    topo = MultiSwitchTopo()
    net = Mininet(topo=topo, controller=None, autoSetMacs=True)
    net.start()
    
    # Add static ARPs
    hosts = [net.get(f'h{i}') for i in range(1, 5)]
    for src in hosts:
        for dst in hosts:
            if src != dst:
                # Add ARP entry: src knows dst IP -> dst MAC
                # We extract IP from '10.0.0.x/24' (removing /24)
                dst_ip = dst.IP() 
                dst_mac = dst.MAC()
                src.cmd(f'arp -s {dst_ip} {dst_mac}')

    switches = [net.get(f's{i}') for i in range(1, 11)]
    failures = verify_switches(switches)
    write_manifest(switches)

    print("\n======================================================================")
    if failures:
        # Reported as a failure rather than the old unconditional success line. A dead switch
        # used to be completely silent here: its bind error went to /tmp/sN_bmv2.log, which
        # nothing read, and this banner claimed all ten were listening anyway. The proxy then
        # failed only on that one switch, tens of lines deep in its own log.
        print(f"WARNING: {len(failures)} of {len(switches)} BMv2 switches did NOT come up.")
        for name, reason in failures:
            print(f"  {name}: {reason}")
        alive = len(switches) - len(failures)
        print(f"\n{alive}/{len(switches)} switches are usable. The P4 proxy expects all "
              f"{len(switches)} and will report errors for the rest.")
        print("Fix the cause and restart this script rather than continuing.")
    else:
        print("Multi-Switch Network Started.")
        print(f"All {len(switches)} BMv2 switches verified listening on gRPC 50051 ~ 50060")
        print(f"Switch manifest: {MANIFEST_PATH}")
    print("======================================================================\n")

    CLI(net)
    net.stop()
    try:
        os.remove(MANIFEST_PATH)
    except OSError:
        pass

if __name__ == '__main__':
    main()

# Developed in collaboration with Gemini 3.1 Pro.
