import requests
data = {"dpid": 1, "match": {"nw_dst": "10.0.0.2"}, "actions": [{"type": "OUTPUT", "port": 1000}]}
resp = requests.post("http://localhost:8081/stats/flowentry/modify", json=data)
print("Modify response:", resp.json())
