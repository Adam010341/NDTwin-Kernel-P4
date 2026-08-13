> ⚠️ **Baseline 時期的廠商語法參考，未對現況查證。**
> 最後實質更新 2026-01-02，且 repo 內目前**沒有任何檔案引用它**。內容是OVS (Open vSwitch) 的 flow entry 語法範例，
> 保留的理由是 kernel 確實還在跟這類設備對話（`FlowLinkUsageCollector` 有 `sampleType == 3`
> 的 HPE 分支），但**這份文件本身沒有人對照過現在的程式碼**。當作外部語法備忘看，不要當作
> 本專案行為的依據。


-----

# OVS (Open vSwitch)

-----

### APPLY\_ACTIONS

This instruction immediately applies a set of actions to the packet. It's the default behavior if no other instruction type is specified. In this example, traffic from host **h3** is matched on switch **s1** and the `OUTPUT` action is applied right away.

```json
curl -X POST http://localhost:8080/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 1,
    "priority": 300,
    "match": { "in_port": 5 },
    "actions": [
        { "type": "APPLY_ACTIONS",
          "actions": [
              { "type": "OUTPUT", "port": 6 }
          ]
        }
    ]
}'
```

*Note: You can omit the `"type": "APPLY_ACTIONS"` wrapper, as it is the default.*

-----

### WRITE\_ACTIONS

This instruction adds actions to an "action set" which is carried with the packet. The actions in this set are executed only after the packet has been processed by the current flow table, typically right before it is forwarded or sent to the next table.

This is useful for building up a list of actions across multiple matching flow entries. In this example, we match traffic from host **h5** on switch **s1**, and "write" two actions to the action set: one to modify the DSCP value and another to specify the output port.

```json
curl -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json'  \
 -d '{
   "dpid": 1,
   "priority": 301,
   "match": { "in_port": 7, "eth_type": 2048 },
   "actions": [
     { "type": "WRITE_ACTIONS",
       "actions": [
         { "type": "SET_FIELD", "field": "ip_dscp", "value": 34 },
         { "type": "OUTPUT", "port": 8 }
       ]
     }
   ]
 }'
```

-----

### CLEAR\_ACTIONS

This instruction clears all actions currently in the packet's action set. This is useful when a lower-priority rule needs to completely override the actions specified by a higher-priority rule.

In this example on switch **s4**, a high-priority rule first adds a `WRITE_ACTIONS` instruction for all IP traffic. A second, more specific rule then matches traffic from **h97** and uses `CLEAR_ACTIONS` to remove the previous action before applying a new, correct one.

1.  **High-priority "catch-all" rule:**

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "priority": 10,
        "table_id": 0,
        "match": { "eth_type": 2048 },
        "actions": [
            { "type": "WRITE_ACTIONS", "actions": [ { "type": "OUTPUT", "port": 1 } ] },
            { "type": "GOTO_TABLE", "table_id": 1 }
        ]
    }'
    ```

2.  **Low-priority "override" rule:**

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "priority": 100,
        "table_id": 1,
        "match": { "in_port": 3 },
        "actions": [
            { "type": "CLEAR_ACTIONS" },
            { "type": "WRITE_ACTIONS", "actions": [ { "type": "OUTPUT", "port": 4 } ] }
        ]
    }'
    ```

-----

### GOTO\_TABLE

This instruction sends the packet to a subsequent flow table for more processing, enabling a multi-stage pipeline.

Here, switch **s4** uses two tables. Table 0 does coarse-grained matching (just the input port) and sends the packet to Table 1. Table 1 does fine-grained matching (the specific destination IP) to decide the final output port.

1.  **Table 0: Port-based matching**

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "table_id": 0,
        "priority": 302,
        "match": { "in_port": 3 },
        "actions": [
            { "type": "GOTO_TABLE", "table_id": 1 }
        ]
    }'
    ```

2.  **Table 1: IP-based matching**

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "table_id": 1,
        "priority": 303,
        "match": { "eth_type": 2048, "ipv4_dst": "10.0.0.98" },
        "actions": [
            { "type": "OUTPUT", "port": 4 }
        ]
    }'
    ```

-----

### WRITE\_METADATA

This instruction writes a value to a packet's metadata field. This metadata isn't part of the packet header but is carried with it through the switch pipeline. It allows one table to "tag" a packet with information that a later table can match on.

1.  **Table 0: Write metadata**
    On switch **s4**, traffic from host **h99** is tagged with metadata `0x5000`.

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "table_id": 0,
        "priority": 304,
        "match": { "in_port": 5 },
        "actions": [
            { "type": "WRITE_METADATA", "metadata": "0x5000", "metadata_mask": "0xFFFF" },
            { "type": "GOTO_TABLE", "table_id": 1 }
        ]
    }'
    ```

2.  **Table 1: Match on metadata**
    In the next table, a rule matches this specific metadata value to forward the packet correctly.

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 4,
        "table_id": 1,
        "priority": 305,
        "match": { "metadata": "0x5000/0xFFFF" },
        "actions": [
            { "type": "OUTPUT", "port": 6 }
        ]
    }'
    ```

-----

### METER

The `METER` instruction subjects a packet to a configured meter, which is used for rate-limiting.

1.  **Create the Meter**
    First, create a meter on switch **s3** that will drop traffic exceeding 5,000 Kbps.

    ```json
    curl -X POST 'http://localhost:8080/stats/meterentry/add' \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 3,
        "flags": "KBPS",
        "meter_id": 5,
        "bands": [
          { "type": "DROP", "rate": 5000 }
        ]
      }'
    ```

2.  **Apply the Meter in a Flow**
    Next, create a flow that directs traffic from host **h65** into the meter. Packets that are not dropped by the meter will proceed to the `OUTPUT` action.

    ```json
    curl -X POST 'http://localhost:8080/stats/flowentry/add' \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 3,
        "table_id": 0,
        "priority": 306,
        "match": { "in_port": 3 },
        "actions": [
          { "type": "METER", "meter_id": 5 },
          { "type": "OUTPUT", "port": 1 }
        ]
      }'
    ```

-----

### GROUP

The `GROUP` action forwards a packet to an OpenFlow group. This allows for more complex forwarding like multicasting.

First, create a group on switch **s2** (`dpid: 2`) that sends copies of a packet to the ports connected to switches **s5** (port 1) and **s6** (port 2).

```json
curl -X POST 'http://localhost:8080/stats/groupentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 2,
    "type": "ALL",
    "group_id": 10,
    "buckets": [
      { "actions": [ { "type": "OUTPUT", "port": 1 } ] },
      { "actions": [ { "type": "OUTPUT", "port": 2 } ] }
    ]
  }'
```

Next, add a flow entry that directs traffic from host **h33** (connected to port 3) to this group.

```json
curl -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 2,
    "table_id": 0,
    "priority": 201,
    "match": { "in_port": 3 },
    "actions": [ { "type": "GROUP", "group_id": 10 } ]
  }'
```

-----

### DROP

To drop a packet, you create a flow rule with an empty `actions` list. This example drops any traffic coming from host **h2** (`10.0.0.2`) at switch **s1**.

```json
curl -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 1,
    "table_id": 0,
    "priority": 202,
    "match": { "eth_type": 2048, "ipv4_src": "10.0.0.2" },
    "actions": []
  }'
```

-----

### SET\_QUEUE

This action sets a specific queue ID for packets, which can be used for Quality of Service (QoS) management. The packet must still be forwarded with `OUTPUT` or another action.

This rule on switch **s1** will match traffic going to host **h4** (`10.0.0.4`), assign it to queue `5`, and then send it out the correct port (port 6).

```json
curl -X POST http://localhost:8080/stats/flowentry/add \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 1,
    "table_id": 0,
    "priority": 203,
    "match": { "eth_type": 2048, "ipv4_dst": "10.0.0.4" },
    "actions": [
      { "type": "SET_QUEUE", "queue_id": 5 },
      { "type": "OUTPUT", "port": 6 }
    ]
}'
```

-----

### PUSH\_VLAN & POP\_VLAN

These actions add or remove a VLAN tag from a packet. This is useful for creating logical separations in the network.

1.  **Push VLAN:** This rule on switch **s1** matches traffic from host **h1** (port 3), adds a VLAN tag with ID `101`, and forwards it to switch **s5** (port 1).

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 1,
        "table_id": 0,
        "priority": 204,
        "match": { "in_port": 3 },
        "actions": [
          { "type": "PUSH_VLAN", "ethertype": 33024 },
          { "type": "SET_FIELD", "field": "vlan_vid", "value": 4197 },
          { "type": "OUTPUT", "port": 1 }
        ]
    }'
    ```

    *Note: `vlan_vid` requires the `0x1000` bit to be set, so `101 | 0x1000 = 4197`.*

2.  **Pop VLAN:** This rule on switch **s5** matches the tagged packets coming from **s1** (port 1), removes the VLAN tag, and forwards the packet to switch **s9** (port 3).

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 5,
        "table_id": 0,
        "priority": 205,
        "match": { "in_port": 1, "vlan_vid": 4197 },
        "actions": [
          { "type": "POP_VLAN" },
          { "type": "OUTPUT", "port": 3 }
        ]
    }'
    ```

-----

### PUSH\_MPLS & POP\_MPLS

These actions add or remove an MPLS label, often used by service providers to create traffic-engineered tunnels.

1.  **Push MPLS:** This rule on **s2** matches IP traffic from host **h33** (port 3), pushes an MPLS label with value `202`, and forwards it to **s5** (port 1).

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 2,
        "priority": 206,
        "match": { "in_port": 3, "eth_type": 2048 },
        "actions": [
          { "type": "PUSH_MPLS", "ethertype": 34887 },
          { "type": "SET_FIELD", "field": "mpls_label", "value": 202 },
          { "type": "OUTPUT", "port": 1 }
        ]
    }'
    ```

2.  **Pop MPLS:** This rule on **s5** matches packets from **s2** (port 2) with MPLS label `202`, removes the label (restoring the EtherType to IPv4), and forwards it to **s9** (port 3).

    ```json
    curl -X POST http://localhost:8080/stats/flowentry/add \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 5,
        "priority": 207,
        "match": { "in_port": 2, "eth_type": 34887, "mpls_label": 202 },
        "actions": [
          { "type": "POP_MPLS", "ethertype": 2048 },
          { "type": "OUTPUT", "port": 3 }
        ]
    }'
    ```

-----

### SET\_FIELD

This is a versatile action that modifies a header field value. This example modifies the DSCP value for QoS.

This rule on **s3** matches UDP traffic from host **h65** (port 3), changes its `ip_dscp` value to `46` (Expedited Forwarding), and forwards it to **s7** (port 1).

```json
curl -X POST 'http://localhost:8080/stats/flowentry/add' \
  -H 'Content-Type: application/json' \
  -d '{
    "dpid": 3,
    "table_id": 0,
    "priority": 208,
    "match": { "in_port": 3, "eth_type": 2048, "ip_proto": 17 },
    "actions": [
      { "type": "SET_FIELD", "field": "ip_dscp", "value": 46 },
      { "type": "OUTPUT", "port": 1 }
    ]
  }'
```

-----

### DEC\_NW\_TTL & DEC\_MPLS\_TTL

These actions decrement the Time-To-Live (TTL) value of a packet, which is standard router behavior to prevent infinite loops.

1.  **DEC\_NW\_TTL (IP TTL):** This rule on switch **s9** acts like a router, decrementing the IP TTL of packets from **s5** (port 1) before forwarding them to **s7** (port 3).

    ```json
    curl -X POST 'http://localhost:8080/stats/flowentry/add' \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 9,
        "table_id": 0,
        "priority": 209,
        "match": { "in_port": 1, "eth_type": 2048 },
        "actions": [
          { "type": "DEC_NW_TTL" },
          { "type": "OUTPUT", "port": 3 }
        ]
    }'
    ```

2.  **DEC\_MPLS\_TTL:** This action is for MPLS packets. Using the MPLS flow from before, this rule on **s5** will decrement the MPLS TTL of a packet from **s2** before sending it to **s9**.

    ```json
    curl -X POST 'http://localhost:8080/stats/flowentry/add' \
      -H 'Content-Type: application/json' \
      -d '{
        "dpid": 5,
        "priority": 210,
        "match": { "in_port": 2, "eth_type": 34887, "mpls_label": 202 },
        "actions": [
          { "type": "DEC_MPLS_TTL" },
          { "type": "POP_MPLS", "ethertype": 2048 },
          { "type": "OUTPUT", "port": 3 }
        ]
    }'
    ```


