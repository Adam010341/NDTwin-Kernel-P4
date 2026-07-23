#!/usr/bin/env python3

import os
import sys
from mininet.net import Mininet
from mininet.topo import Topo
from mininet.node import Switch, Host
from mininet.cli import CLI
from mininet.log import setLogLevel, info

class BMv2Switch(Switch):
    """BMv2 switch for Mininet"""
    def __init__(self, name, json_path=None, device_id=1, grpc_port=50051, thrift_port=9090, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.device_id = device_id
        self.grpc_port = grpc_port
        self.thrift_port = thrift_port
        self.log_file = f"/tmp/{self.name}_bmv2.log"

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
        info(f"Starting {self.name} (gRPC: {self.grpc_port}, Thrift: {self.thrift_port})\n")
        self.cmd(f"{cmd} > {self.log_file} 2>&1 &")

    def stop(self):
        self.cmd('kill %simple_switch_grpc')
        Switch.stop(self)

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
        
def main():
    setLogLevel('info')
    
    json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')
    if not os.path.exists(json_path):
        print(f"Error: Compiled P4 JSON not found at {json_path}. Run 'p4c-bm2-ss' first in p4_src.")
        sys.exit(1)

    os.system('sudo mn -c > /dev/null 2>&1')

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

    print("\n======================================================================")
    print("Multi-Switch Network Started.")
    print("10 BMv2 Switches listening on gRPC ports 50051 ~ 50060")
    print("======================================================================\n")

    CLI(net)
    net.stop()

if __name__ == '__main__':
    main()

# Developed in collaboration with Gemini 3.1 Pro.
