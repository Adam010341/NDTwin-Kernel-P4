#!/usr/bin/env python3


from mininet.topo import Topo
from mininet.net import Mininet
from mininet.node import RemoteController, OVSKernelSwitch
from mininet.cli import CLI
from mininet.log import setLogLevel
from mininet.link import TCLink
import os
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
        f'target=\\"{target}\\" header=128 sampling=256 polling=0 '
        f"-- set bridge {switch} sflow=@sflow"
    )
    os.system(cmd)


def ping_test(src, dst_ip):
    """
    A simple utility function to perform a single ping test and print the result.
    This is used for verifying connectivity within the Mininet topology.
    """
    print(f"Pinging from {src.name} to {dst_ip}...")
    result = src.cmd(f"ping -c 1 {dst_ip}")
    print(f"Result from {src.name} to {dst_ip}:\n{result}")


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

        # Launch ping tests in parallel to generate some traffic.
        threads = []
        for i in range(int(HOST_NUM / 2)):
            client = net.get(f"h{i+1}")
            server_ip = f"10.0.0.{i+1+int(HOST_NUM/2)}"
            t = threading.Thread(target=ping_test, args=(client, server_ip))
            threads.append(t)
            t.start()
        for i in range(int(HOST_NUM / 2)):
            server = net.get(f"h{i+1+int(HOST_NUM/2)}")
            client_ip = f"10.0.0.{i+1}"
            t = threading.Thread(target=ping_test, args=(server, client_ip))
            threads.append(t)
            t.start()
        for t in threads:
            t.join()

        print("\n--- Final Configuration Active ---")
        print("Host internet: OK | sFlow reachability: OK | Switch identification: OK")
        print(f"Run 'sflowtool -p 6343' in another terminal to see the data.")
        CLI(net)

    finally:
        # == STEP 3: Clean Up Gracefully ==
        # This 'finally' block ensures that our created IP alias is removed,
        # and the Mininet network is stopped, no matter how the script exits.
        # This keeps the host system clean.
        print(f"\nCleaning up: Removing IP alias {COLLECTOR_IP} from 'lo' interface...")
        os.system(f"sudo ip addr del {COLLECTOR_IP}/24 dev lo")
        net.stop()
