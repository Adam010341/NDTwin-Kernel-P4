import sys
import os
import time
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from proxy_agent.p4_client import P4RuntimeClient

def test_client():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p4info_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.p4info.txt')
    json_path = os.path.join(base_dir, 'p4_src', 'build', 'ndtwin_switch.json')
    
    print("Initializing P4RuntimeClient...")
    client = P4RuntimeClient(
        device_id=1, 
        grpc_addr='localhost:50051', 
        p4info_path=p4info_path, 
        json_path=json_path
    )
    
    print("Starting client (connecting and setting pipeline config)...")
    client.start()
    
    # Wait for mastership and pipeline config to settle
    time.sleep(1)
    
    print("Adding IPv4 rules via class methods...")
    client.insert_ipv4_route("10.0.0.1", 32, "00:00:00:00:00:01", 1)
    client.insert_ipv4_route("10.0.0.2", 32, "00:00:00:00:00:02", 2)
    
    print("Routes added. Waiting for 2 seconds to keep stream alive...")
    time.sleep(2)
    client.stop()
    print("Client stopped successfully.")

if __name__ == '__main__':
    test_client()
