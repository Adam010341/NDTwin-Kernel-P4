> ⚠️ **Baseline 時期的廠商語法參考，未對現況查證。**
> 最後實質更新 2026-01-02，且 repo 內目前**沒有任何檔案引用它**。內容是HPE 交換器的 flow entry 操作範例，
> 保留的理由是 kernel 確實還在跟這類設備對話（`FlowLinkUsageCollector` 有 `sampleType == 3`
> 的 HPE 分支），但**這份文件本身沒有人對照過現在的程式碼**。當作外部語法備忘看，不要當作
> 本專案行為的依據。

# HPE
---
## APPLY_ACTIONS (by default, it means you don't need to specify APPLY_ACTIONS explicitly)
### SET_QUEUE, OUTPUT
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512,
    "table_id": 0,
    "priority": 202,
    "match": { "eth_type": 2048, "ipv4_dst": "10.10.10.4" },
    "actions": [
      { "type": "SET_QUEUE", "queue_id": 5 },
      { "type": "OUTPUT", "port": 25 }
    ]
}'
```
### GROUP (ALL)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512,
    "type": "ALL",
    "group_id": 10,
    "buckets": [
      { "actions": [ { "type": "OUTPUT", "port": 25 } ] },
      { "actions": [ { "type": "OUTPUT", "port": 26 } ] }
    ]
  }'
```
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512,
    "table_id": 0,
    "priority": 205,
    "match": { "in_port": 27 },
    "actions": [ { "type": "GROUP", "group_id": 10 } ]
  }'
```
### GROUP (INDIRECT)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 334525264558512,
    "type": "INDIRECT",
    "group_id": 20,
    "buckets": [
      { "actions": [ { "type": "OUTPUT", "port": 27 } ] }
    ]
  }'
```
```json
  curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 334525264558512,
    "table_id": 0,
    "priority": 210,
    "match": { "in_port": 25 },
    "actions": [
      { "type": "GROUP", "group_id": 20 }
    ]
  }'
```

## GROUP (FF, fast failover)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 334525264558512,
    "type": "FF",
    "group_id": 30,
    "buckets": [
      {
        "watch_port": 25,
        "watch_group": 0,
        "actions": [ { "type": "OUTPUT", "port": 25 } ]
      },
      {
        "watch_port": 26,
        "watch_group": 0,
        "actions": [ { "type": "OUTPUT", "port": 26 } ]
      }
    ]
  }'
```
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 334525264558512,
    "table_id": 0,
    "priority": 211,
    "match": { "in_port": 25 },
    "actions": [ { "type": "GROUP", "group_id": 30 } ]
  }'
```
### DROP
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512, "table_id": 0, "priority": 206,
    "match": { "in_port": 25 },
    "actions": []
  }'
```  
### SET_FIELD
```json
  curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512, "table_id": 0, "priority": 207,
    "match": { "eth_type": 2048, "ip_proto": 17 }, 
    "actions": [
      { "type": "SET_FIELD", "field": "ip_dscp", "value": 46 },
      { "type": "OUTPUT", "port": 26 }
    ]
  }'
```
## WRITE_ACTIONS
 ```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json'  \
-d '{
  "dpid": 334525264558512,
  "table_id": 0,
  "priority": 209,
  "match": { "eth_type": 2048, "ip_proto": 17, "in_port": 1 },
  "actions": [
    { "type": "WRITE_ACTIONS",
      "actions": [
        { "type": "SET_FIELD", "field": "ip_dscp", "value": 46 },
        { "type": "OUTPUT", "port": 2 }
      ]
    }
  ]
}'
```

## METER
```json
curl -sS -X POST 'http://localhost:8080/stats/meterentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 334525264558512,
    "flags": ["KBPS", "BURST", "STATS"],
    "meter_id": 5,
    "bands": [
      { "type": "DROP", "rate": 5000, "burst_size": 1000 }
    ]
  }'
```

```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 334525264558512,
    "table_id": 0,
    "priority": 210,
    "match": { "in_port": 25 },
    "actions": [
      { "type": "METER", "meter_id": 5 },
      { "type": "OUTPUT", "port": 27 }
    ]
  }'
```
---
# BrocadeICX7250
## APPLY_ACTIONS (by default, it means you don't need to specify APPLY_ACTIONS explicitly)
### SET_QUEUE, OUTPUT
```json
curl -sS -X POST http://localhost:8080/stats/flowentry/add \
-H 'Content-Type: application/json' \
 -d '{
    "dpid": 106225808398208,
    "table_id": 0,
    "priority": 100,
    "match": { "eth_type": 2048, "ipv4_dst": "10.10.10.4" },
    "actions": [
      { "type": "SET_QUEUE", "queue_id": 5 },
      { "type": "OUTPUT", "port": 21 }
    ]
}'
```

### GROUP (ALL)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 106225808398208,
    "type": "ALL",
    "group_id": 10,
    "buckets": [
      { "actions": [ { "type": "OUTPUT", "port": 21 } ] },
      { "actions": [ { "type": "OUTPUT", "port": 22 } ] }
    ]
  }'
```
```json
  curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 106225808398208,
    "table_id": 0,
    "priority": 101,
    "match": { "in_port": 65 },
    "actions": [ { "type": "GROUP", "group_id": 10 } ]
  }'
```
### GROUP (INDIRECT)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 106225808398208,
    "type": "INDIRECT",
    "group_id": 20,
    "buckets": [
      { "actions": [ { "type": "OUTPUT", "port": 21 } ] }
    ]
  }'
```
```json
  curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 106225808398208,
    "table_id": 0,
    "priority": 108,
    "match": { "in_port": 65 },
    "actions": [
      { "type": "GROUP", "group_id": 20 }
    ]
  }'
```
## GROUP (FF, fast failover)
```json
curl -sS -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 106225808398208,
    "type": "FF",
    "group_id": 30,
    "buckets": [
      {
        "watch_port": 21,
        "watch_group": 0,
        "actions": [ { "type": "OUTPUT", "port": 21 } ]
      },
      {
        "watch_port": 22,
        "watch_group": 0,
        "actions": [ { "type": "OUTPUT", "port": 22 } ]
      }
    ]
  }'
```
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 106225808398208,
    "table_id": 0,
    "priority": 109,
    "match": { "in_port": 65 },
    "actions": [ { "type": "GROUP", "group_id": 30 } ]
  }'
```
### DROP
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 106225808398208, "table_id": 0, "priority": 103,
    "match": { "in_port": 21 },
    "actions": []
  }'
```
### SET_FIELD
```json
 curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 106225808398208, "table_id": 0, "priority": 105,
    "match": { "eth_type": 2048, "ip_proto": 17 }, 
    "actions": [
      { "type": "SET_FIELD", "field": "ip_dscp", "value": 46 },
      { "type": "OUTPUT", "port": 22 }
    ]
  }'
```
## WRITE_ACTIONS
```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json'  \
-d '{
  "dpid": 106225808398208,
  "table_id": 0,
  "priority": 106,
  "match": { "eth_type": 2048, "ip_proto": 17, "in_port": 21 },
  "actions": [
    { "type": "WRITE_ACTIONS",
      "actions": [
        { "type": "SET_FIELD", "field": "ip_dscp", "value": 46 },
        { "type": "OUTPUT", "port": 22 }
      ]
    }
  ]
}'
```

## METER
```json
curl -sS -X POST 'http://localhost:8080/stats/meterentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 106225808398208,
    "flags": ["KBPS", "BURST", "STATS"],
    "meter_id": 5,
    "bands": [
      { "type": "DROP", "rate": 5000, "burst_size": 1000 }
    ]
  }'
```

```json
curl -sS -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "dpid": 106225808398208,
    "table_id": 0,
    "priority": 107,
    "match": { "in_port": 21 },
    "actions": [
      { "type": "METER", "meter_id": 5 },
      { "type": "OUTPUT", "port": 22 }
    ]
  }'
```