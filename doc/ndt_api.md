# NDT RESTful API Documentation
## 1. POST /ndt/link_failure_detected
### Description
Called by Ryu when a link-down event is detected. Marks the edge(s) DOWN and emits internal events.
### Request
* Method: **POST**
* Content-Type: **application/json**
* Body (the information of failed link)
```json
{
  "src_dpid": 106225808402492,
  "src_interface": 23,
  "dst_dpid": 106225808387660,
  "dst_interface": 23
}
```
### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "link failure processed"
}
```
#### Error
* Status: **400 Bad Request**
```json
{
  "error": "Invalid link-failure payload"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **404 Not Found**
```json
{
  "error": "edge not found in topology"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 2. POST /ndt/link_recovery_detected
### Description
Called by Ryu when a failed link becomes UP. Marks the edge(s) UP.
### Request
* Method: **POST**
* Content-Type: **application/json**
* Body (the information of recovered link)
```json
{
  "src_dpid": 106225808402492,
  "src_interface": 23,
  "dst_dpid": 106225808387660,
  "dst_interface": 23
}
```
### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "link recovery processed"
}
```
#### Error
* Status: **400 Bad Request**
```json
{
  "error": "Missing src_dpid or dst_dpid or src_interface or dst_interface"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **404 Not Found**
```json
{
  "error": "edge not found in topology"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 3. GET /ndt/get_graph_data
### Description
Returns the complete graph topology configured in *setting/StaticNetworkTopology.json* including nodes and edges, flow information, and edge status.
**vertex_type = 0** means a switch, and **vertex_type = 1** means a host.
**is_up** suggests whether a switch reply ping or whether a host is detected by Ryu.
**is_enable** in switch node suggests whether the switch is connected to controller. 
At the edge between the switch and host, the dpid and interface on the host side are set to 0.


**Note:** `src_ip`/`dst_ip` are 32-bit integers holding the address in **network byte order** —
the same value as `struct in_addr::s_addr`, which is what the kernel stores and serialises directly.

Do **not** read the decimal digits as a host-order integer. `16777226` is `10.0.0.1`, not
`1.0.0.10`: its bytes are `0A 00 00 01`, which is the address in order. Convert with `ntohl()`
before formatting (portable, and a no-op on a big-endian host), or read the four bytes in
little-endian order. The host-order integer for `10.0.0.1` would be `167772161`.

Note also that string-valued IP fields elsewhere in this API (`get_path_switch_count`, the node
`ip` array, the static-topology endpoint) are ordinary dotted-quad text and need no conversion —
only these integer fields carry the byte-order caveat.

### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
```json
{
  "nodes": [
    {
      "device_name": "s4",
      "dpid": 106225808380928,
      "ip": [
        168430090
      ],
      "is_enabled": true,
      "is_up": true,
      "mac": 0,
      "vertex_type": 0,
      "brand_name": "OVS",
      "device_layer": 1
    },
    {
      "device_name": "h9",
      "dpid": 0,
      "ip": [
        1157736640,
        1174513856,
        1107404992,
        1090627776,
        1191291072,
        1124182208,
        1140959424,
        1208068288
      ],
      "is_enabled": true,
      "is_up": true,
      "mac": 31362038109890,
      "vertex_type": 1,
      "brand_name": "",
      "device_layer": 3
    },
    ...
  ],
  "edges": [
    {
      "dst_dpid": 0,
      "dst_ip": [
        50440384,
        33663168,
        100772032,
        117549248,
        134326464,
        83994816,
        67217600,
        16885952
      ],
      "dst_interface": 0,
      "flow_set": [
        {
          "dst_ip": 2147592384,
          "dst_port": 5201,
          "protocol_number": 6,
          "src_ip": 16885952,
          "src_port": 40997
        }
      ],
      "is_enabled": true,
      "is_up": true,
      "left_link_bandwidth_bps": 998396604,
      "link_bandwidth_bps": 1000000000,
      "link_bandwidth_usage_bps": 1603396,
      "link_bandwidth_utilization_percent": 0.16033960000000347,
      "src_dpid": 106225808402492,
      "src_ip": [
        67766794
      ],
      "src_interface": 1
    },
    ...
  ]
}
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 4. GET /ndt/get_detected_flow_data
### Description
Returns detailed information about all active flows observed by the network system (sFLow), including their estimated sending rates, timestamps, protocol type, and the full path taken across the network.

**Note:** For ICMP packets, the src_port field represents the ICMP type, and the dst_port field represents the ICMP code.

**Note:** `src_ip`/`dst_ip` are 32-bit integers holding the address in **network byte order** —
the same value as `struct in_addr::s_addr`, which is what the kernel stores and serialises directly.

Do **not** read the decimal digits as a host-order integer. `16777226` is `10.0.0.1`, not
`1.0.0.10`: its bytes are `0A 00 00 01`, which is the address in order. Convert with `ntohl()`
before formatting (portable, and a no-op on a big-endian host), or read the four bytes in
little-endian order. The host-order integer for `10.0.0.1` would be `167772161`.

Note also that string-valued IP fields elsewhere in this API (`get_path_switch_count`, the node
`ip` array, the static-topology endpoint) are ordinary dotted-quad text and need no conversion —
only these integer fields carry the byte-order caveat.

### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
```json
[
    {
        "dst_ip": 16885952,
        "dst_port": 55367,
        "estimated_flow_sending_rate_bps_in_the_last_sec": 1712000,
        "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 1817600,
        "estimated_packet_rate_in_the_last_sec": 3000,
        "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 3200,
        "first_sampled_time": "2025-08-22 10:13:12",
        "latest_sampled_time": "2025-08-22 10:13:17",
        "path": [
            {
                "interface": 5,
                "node": 1359063232
            },
            {
                "interface": 22,
                "node": 106225808391692
            },
            {
                "interface": 65,
                "node": 106225808398208
            },
            {
                "interface": 25,
                "node": 897475217989184
            },
            {
                "interface": 21,
                "node": 106225808403428
            },
            {
                "interface": 1,
                "node": 106225808402492
            },
            {
                "interface": 0,
                "node": 16885952
            }
        ],
        "protocol_id": 6,
        "src_ip": 1359063232,
        "src_port": 5201
    },
    {
        "dst_ip": 1359063232,
        "dst_port": 5201,
        "estimated_flow_sending_rate_bps_in_the_last_sec": 988560000,
        "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 962242666,
        "estimated_packet_rate_in_the_last_sec": 81333,
        "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 79166,
        "first_sampled_time": "2025-08-22 10:13:12",
        "latest_sampled_time": "2025-08-22 10:13:18",
        "path": [
            {
                "interface": 1,
                "node": 16885952
            },
            {
                "interface": 22,
                "node": 106225808402492
            },
            {
                "interface": 65,
                "node": 106225803167444
            },
            {
                "interface": 27,
                "node": 897475217989184
            },
            {
                "interface": 21,
                "node": 106225808384924
            },
            {
                "interface": 5,
                "node": 106225808391692
            },
            {
                "interface": 0,
                "node": 1359063232
            }
        ],
        "protocol_id": 6,
        "src_ip": 16885952,
        "src_port": 55367
    }
]
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 5. GET /ndt/get_switch_openflow_table_entries
### Description
Returns raw OpenFlow flow table entries directly from each switch in the topology. 

Each entry includes the DPID of the switch and the exact OpenFlow flow entries as reported by that switch.


### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
```json
[
  {
    "dpid": 106225808402492,
    "flows": {
      "106225808402492": [
        {
          "actions": [
            "OUTPUT:1"
          ],
          "byte_count": 0,
          "cookie": 0,
          "duration_nsec": 91000000,
          "duration_sec": 3935,
          "flags": 0,
          "hard_timeout": 0,
          "idle_timeout": 0,
          "length": 96,
          "match": {
            "dl_type": 2048,
            "nw_dst": "192.168.1.1"
          },
          "packet_count": 0,
          "priority": 10,
          "table_id": 0
        },
        ...
      ]
    }
  }
]
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 6. GET /ndt/get_power_report
### Description
Returns the estimated power consumption (in watts, W) of each switch. The behavior varies based on deployment mode:

In MININET mode, random values are generated for demonstration purposes.

In TESTBED mode, power values are collected via SSH or SNMP from each switch's IP address and parsed from the returned output.


### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
```json
[
  {
    "dpid": 106225808391692,
    "power_consumed": 851157966
  },
  {
    "dpid": 106225808380928,
    "power_consumed": 851152638
  },
  {
    "dpid": 106225808387660,
    "power_consumed": 842764030
  },
  {
    "dpid": 106225808402492,
    "power_consumed": 851157966
  }
]
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 7. GET /ndt/get_switches_power_state

### Description
Query the power state of one or all switches.  
- **With `?ip=`**: returns the state of the specified switch  
- **Without parameters**: returns the state of *all* known switches  

```shell
 GET "http://127.0.0.1:8000/ndt/get_switches_power_state?ip=10.10.10.10"
```

Results are returned as a JSON object where each key is a switch IP and each value is `"ON"` or `"OFF"`.


### Request
* Method: **GET**
* Query Parameter:

  ip (optional) — the switch IP to query; if omitted, returns all switches

### Response
#### Success

* Status: **200 OK**

```json
{
  "10.10.10.10": "ON"
}
```

```json
{
  "10.10.10.10": "ON",
  "10.10.10.3":  "OFF",
  "10.10.10.4":  "ON",
  "10.10.10.9":  "OFF"
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **404 Not Found**
```json
{
  "error": "Unknown switch IP"
}
```
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 8. POST /ndt/set_switches_power_state

### Description

Controls the operational state of a switch.
* TESTBED mode: Sends a power control command to a physical switch by interacting with the smart plug associated with it.
* MININET mode: Simulates switch power ON/OFF by adding (on) or removing (off) the corresponding OVS bridge via ovs-vsctl commands.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Query Parameters:

| Field | Type   | Description                            |
| --------- | ------ | -------------------------------------- |
| `ip`      | `string` | IP address of the switch               |
| `action`  | `string` | Desired power state: `"on"` or `"off"` |

* Body
  None

```shell
POST "http://localhost:8000/ndt/set_switches_power_state?ip=10.10.10.10&action=on"
```

### Response

#### Success

* Status: **200 OK**
```json
{
  "10.10.10.10": "Success"
}
```

#### Error
* Status: **400 Bad Request**
```json
{
  "error": "Missing or malformed query parameters"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

> **Note on the flow-entry endpoints (9, 10, 11 and 23).**
> These enqueue work onto an asynchronous, per-switch dispatcher and return as soon as the
> entries are accepted, before any request reaches the controller. A `200` with
> `"status": "queued"` therefore means *accepted for programming*, not *programmed*.
> Per-entry outcomes -- including a rejected rule or an unreachable controller -- are logged
> with the dpid and the controller's reply. Earlier versions answered
> `"Flow installed"` regardless of what happened, which made a failure
> indistinguishable from a success.

## 9. POST /ndt/install_flow_entry
### Description
Installs a new OpenFlow flow entry in a specific switch via the Ryu controller. 

The API constructs and sends a **flowentry/add** POST request to Ryu.


### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "dpid": 106225808380928,
  "priority": 99,
  "match": {
    "eth_type": 2048,
    "ipv4_dst": "10.0.0.3"
  },
  "actions": [
    {
      "type": "OUTPUT",
      "port": 24
    }
  ]
}
```
### Response
#### Success
* Status: **200 OK**
* Body 
```json
{
  "status": "queued",
  "accepted": 1,
  "detail": "entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response"
}
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 10. POST /ndt/delete_flow_entry
### Description
Deletes a flow entry from a switch based on match fields. 

* If the request body does not include "priority", NDTwin forwards the request to Ryu **/stats/flowentry/delete** (non-strict delete).

* If the request body includes "priority", NDTwin forwards the request to Ryu **/stats/flowentry/delete_strict** (strict delete, exact match+priority).


### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "dpid": 106225808380928,
  "match": {
    "eth_type": 2048,
    "ipv4_dst": "10.0.0.3"
  }
}
```
### Response
#### Success
* Status: **200 OK**
* Body 
```json
{
  "status": "queued",
  "accepted": 1,
  "detail": "entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response"
}
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```



## 11. POST /ndt/modify_flow_entry
### Description
Modifies an existing flow entry by matching criteria and applying new actions. 

Sends a **flowentry/modify** request to the Ryu controller.


### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "dpid": 106225808380928,
  "priority": 99,
  "match": {
    "eth_type": 2048,
    "ipv4_dst": "10.0.0.3"
  },
  "actions": [
    {
      "type": "OUTPUT",
      "port": 25
    }
  ]
}
```
### Response
#### Success
* Status: **200 OK**
* Body 
```json
{
  "status": "queued",
  "accepted": 1,
  "detail": "entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response"
}
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 12. GET /ndt/get_cpu_utilization
### Description
Returns the current CPU utilization(%) of all up switches in the network topology. Uses SNMP to retrieve CPU data. 

In MININET mode, dummy values are generated for demonstration purposes.

### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
* Body 
```json
{"10.10.10.10":1,"10.10.10.3":1,"10.10.10.4":1,"10.10.10.9":1}
```
A value of -1 means SNMP query failed or data is unavailable.


## 13. GET /ndt/get_memory_utilization
### Description
Returns the memory utilization(%) of all up switches using SNMP.

In MININET mode, dummy values are generated for demonstration purposes.

**Note:** A value of -1 means SNMP query failed or data is unavailable.

### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK** 
```json
{"10.10.10.10":28,"10.10.10.3":27,"10.10.10.4":27,"10.10.10.9":27}
```


## 14. GET /ndt/inform_switch_entered
### Description
Called by Ryu to notify the NDTwin system that a new switch has entered the network (i.e., connected). This will mark the switch as UP in the internal topology.

```shell
GET "http://localhost:8000/ndt/inform_switch_entered?dpid=106225808402492"
```
### Request
* Method: **GET**
* Query Parameter: 

  dpid
### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "Switch set to up"
}
```
#### Error
* Status: **400 Bad Request**
```json
{
  "error": "Missing dpid parameter"
}
```
* Status: **400 Bad Request**
```json
{
  "error": "Invalid dpid format"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **404 Not Found**
```json
{
  "error": "Switch not found"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 15. POST /ndt/modify_device_name
### Description
Updates the name of a switch or host in the NDTwin topology and StaticNetworkTopology.json.


### Request
* Content-Type: **application/json**
* Body Parameters:

|     Field     |    Type  |      Required     |         Description                        |
| ------------- | -------- | ----------------- | ------------------------------------------ |
| `vertex_type` | `int`    |        Yes        | `0` for switch, `1` for host               |
|    `dpid`     | `uint64` |  Yes (if switch)  | 	The DPID of the switch to rename        |
|     `mac`     | `string` |  Yes (if host)  | 	The MAC address of the host to rename (e.g., "00:11:22:33:44:55")          |
|  `new_name`   | `string` |        Yes        | 	The new name to assign to the device    |


* Body
```json
{
  "vertex_type": 1,
  "mac": "00:11:22:33:44:55",
  "new_name": "HostA"
}
```
### Response
#### Success
* Status: **200 OK**
* Body 
```json
{
  "status": "Device name updated successfully."
}
```
#### Error
* Status: **400 Bad Request**
```json
{
  "error": 	"Invalid vertex_type. Must be 0 (switch) or 1 (host)."
}
```
* Status: **400 Bad Request**
```json
{
  "error": 	"Invalid request format."
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **404 Not Found**
```json
{
  "error": 	"Device not found."
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 16. POST /ndt/app_register
### Description
Registers a new application with the server.
When an application is registered:

- The server assigns it a unique `app_id`.

- Creates a dedicated folder for the application in the NFS export directory (e.g., /srv/nfs/sim/<app_id>).

- This folder can be used by the application to store its simulation files.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "app_name": "MyApp",
  "simulation_completed_url": "http://192.168.100.5:9000/simulation_completed"
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "app_id": 1,
  "message": "Application registered successfully"
}
```

#### Error
* Status: **400 Bad Request**
```json
{
  "error": "Missing or invalid 'appName'"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 17. POST /ndt/received_a_simulation_case

### Description

Called by NDTwin Application to notify the NDTwin server that a new simulation case has been dispatched by an external simulator and reply the response from simulation platform manager.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body Parameters:

| Field       | Type   | Description                                                             |
| ----------- | ------ | ----------------------------------------------------------------------- |
| `simulator` | `string` | Name of the simulator (e.g., `"NetSquid"`)                              |
| `version`   | `string` | Version identifier of the simulator (e.g., `"v1.2.3"`)                  |
| `app_id`    | `string` | Identifier of the registered application (as returned by app\_register) |
| `case_id`   | `string` | Unique identifier for this simulation case                              |
| `inputfile` | `string` | Path or URL where the simulator can fetch its input description         |

```json
{
  "simulator": "MySimulator",
  "version": "1.0.0",
  "app_id": "1",
  "case_id": "case_123",
  "inputfile": "/srv/nfs/sim/1/case_123.json"
}
```

### Response

#### Success

* Status: **202 Accepted**
```json
{
  "status": "Request received (response from simulation server)"
}
```

#### Error

Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 18. POST /ndt/simulation_completed

### Description

Called by the external simulator when a simulation finishes. The NDTwin will forward the result URL to the registered application.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body Parameters:

| Field        | Type   | Description                                                   |
| ------------ | ------ | ------------------------------------------------------------- |
| `app_id`     | `string` | Identifier of the application that submitted the simulation   |
| `case_id`    | `string` | Identifier of the simulation case that has completed          |
| `outputfile` | `string` | Path or URL where the simulator has deposited its output file |

```json
{
  "app_id": "1",
  "case_id": "case_123",
  "outputfile": "/srv/nfs/sim/1/case_123_result.json"
}
```

### Response

#### Success

* Status: **200 OK**
```json
{
  "status": "result forwarded"
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 19. GET /ndt/get_nickname
### Description

Retrieves the **nickname** of a single device from the network topology. The device must be identified by one of the query parameters: `dpid`, `mac`, or `name`.

If multiple parameters are provided, they are processed in the following order of priority: **`dpid` \> `mac` \> `name`**. For example, if both `dpid` and `mac` are in the URL, the system will only search for the device by its `dpid`.

### Request
* Method: **GET**
* Query Parameters:

At least one of the following parameters is required.

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `dpid` | `uint64` | The **DPID** of the switch to find. |
| `mac` | `string` | The **MAC address** of the device to find (e.g., "00:1A:2B:3C:4D:5E"). |
| `name` | `string` | The current **device name** to find. |

* Example URLs:

  To get by DPID:
    `/api/device/nickname?dpid=4660`

  To get by MAC address:
      `/api/device/nickname?mac=00:1A:2B:3C:4D:5E`

### Response

#### Success 
* Status**: **200 OK**
```json
{
  "nickname": "Main-Web-Server"
}
```

#### Error 
Returned if an identifier has an invalid format (e.g., a non-numeric DPID).
* Status: **400 Bad Request**
```json
{
  "error": "Invalid DPID format",
  "details": "stoull"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when a valid identifier is provided, but no matching device is found in the topology.
* Status: **404 Not Found**
```json
{
  "error": "Device not found"
}
```
Returned if no identifier parameter (`dpid`, `mac`, or `name`) is provided in the URL.
* Status: **404 Not Found**
```json
{
  "error": "Missing dpid, mac, or name parameter"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 20. POST /ndt/modify_nickname
### Description

Updates the nickname of a device (e.g., a switch or host) in the network topology. The device can be identified by its **DPID**, **MAC address**, or its current **name**(e.g., name or nickname).

### Request
* Method: **POST**
* Content-Type: **application/json**

* Body Parameters:

| Field | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `identifier` | `object` | Yes | An object containing the unique identifier for the device. |
| `identifier.type` | `string` | Yes | Specifies the type of identifier. Must be one of: `"dpid"`, `"mac"`, or `"name"`. |
| `identifier.value`| `int`,`uint64` or `string` | Yes | The value corresponding to the identifier type (e.g., a DPID for `dpid`, a MAC address string for `mac`). |
| `new_nickname` | `string` | Yes | The new nickname to assign to the device. |
  
* Body (Example by DPID)

```json
{
  "identifier": {
    "type": "dpid",
    "value": 4660
  },
  "new_nickname": "Sinica-Switch-01"
}
```

* Body (Example by MAC)

```json
{
"identifier": {
  "type": "mac",
  "value": "00:1A:2B:3C:4D:5E"
},
"new_nickname": "Main-Web-Server"
}
```
* Body (Example by NAME)

```json
{
  "identifier": {
    "type": "name",
    "value": "h1"
  },
  "new_nickname": "Core-Switch-01"
}
```

### Response

#### Success 

* Status: **200 OK**
```json
{
  "status": "success",
  "message": "Nickname updated successfully."
}
```

#### Error 

* Status: **404 Not Found**
```json
{
  "error": "Device not found"
}
```
This error is returned for invalid request formats, such as malformed JSON, missing required fields, or an invalid identifier type.
* Status: **400 Bad Request**
```json
{
  "error": "Failed to modify nickname",
  "details": "Invalid identifier type: ip"
}
```

## 21. GET /ndt/get_temperature

### Description

Retrieves the current operating temperature for all switches in the network topology.

This function is designed to work in two modes:

  * In a MININET environment, it returns randomly generated dummy data for any switch.
  * In a TESTBED environment, it uses SNMP to query the temperature. It will only return a valid temperature for devices with a `brand_name` of "HPE 5520". For other devices or switches that are down, it returns a descriptive status message.

### Request
* Method: **GET**

### Response

#### Success 

* Status: **200 OK**

A JSON object where each key is a switch's IP address. The value is either the current temperature in Celsius (as an integer) or a status message (as a string).

```json
{
  "10.10.10.15": "The temperature function only supports the HPE 5520.",
  "10.10.10.16": 29,
  "10.10.10.17": "The switch is down."
}
```

#### Error 

Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 22. GET /ndt/get_path_switch_count

### Description

Retrieves the number of switches along network paths.

* If a **source IP** and **destination IP** are specified, it returns the switch count for that single path.
* If no IP addresses are specified, it returns a list of all known paths and their corresponding switch counts.

### Request
* Method: **GET**
* Query Parameters:

| Parameter | Type     | Required | Description                                                                                 |
| :-------- | :------- | :------- | :------------------------------------------------------------------------------------------ |
| `src_ip`  | `string` | No       | The source IP address of the path (e.g., "10.0.0.1"). If omitted, all paths will be returned. |
| `dst_ip`  | `string` | No       | The destination IP address of the path (e.g., "10.0.0.2"). If omitted, all paths will be returned. |

* Example URLs:

  For a specific path:
    `/ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.2`

  For all paths (empty query):
    `/ndt/get_path_switch_count`

### Response

#### Success
* Status: **200 OK**

A JSON object confirming the request and providing the count of switches on the specified path.

```json
{
  "status": "success",
  "src_ip": "10.0.0.1",
  "dst_ip": "10.0.0.2",
  "switch_count": 1
}
```

#### Success 

* Status: **200 OK**

A JSON object containing a `data` array with all known paths and their switch counts. The array will be empty if no paths are currently known.

```json
{
  "status": "success",
  "data": [
    {
      "src_ip": "10.0.0.1",
      "dst_ip": "10.0.0.2",
      "switch_count": 1
    },
    {
      "src_ip": "10.0.0.3",
      "dst_ip": "10.0.0.4",
      "switch_count": 2
    }
  ]
}
```

#### Error 
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
This error is returned **only when requesting a specific path** that cannot be found in the system's records.
* Status: **404 Not Found**
```json
{
  "status": "error",
  "message": "Path not found for the given IPs."
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 23. POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries

### Description

Installs, modifies and deletes OpenFlow entries in one request. 

**Implementation details:**
To minimize update time, the controller uses a producer–consumer architecture: the request handler (producer) parses and validates flow actions, then pushes them into an internal queue. A dedicated worker (consumer) dequeues actions and applies them to switches, reducing per-request overhead and improving flow update throughput.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body Parameters:

| Field        | Type   | Description                                                   |
| ------------ | ------ | ------------------------------------------------------------- |
| `install_flow_entries`     | `array` | Array of install entries. Each item must include dpid, match, and actions; priority optional (0 as default value).   |
| `modify_flow_entries`     | `array` | Array of modify entries. Each item must include dpid, match, and actions; priority optional (0 as default value).   |
| `delete_flow_entries`    | `array` | Array of delete entries. Each item must include dpid and match.          |

* **Install/Modify entry fields**

  | Field        | Type   | Description                                                   |
  | ------------ | ------ | ------------------------------------------------------------- |
  | `dpid`     | `uint64_t` | Switch datapath ID.   |
  | `priority`    | `int` | 	Rule priority (optional; defaults to 0 if missing).          |
  | `match`    | `object` | 	Match fields.          |
  | `actions`    | `array` | 	List of actions.          |

* **Delete entry fields**

  | Field        | Type   | Description                                                   |
  | ------------ | ------ | ------------------------------------------------------------- |
  | `dpid`     | `uint64_t` | Switch datapath ID.   |
  | `match`    | `object` | 	Match fields.          |
  | `priority`   | `int` | 	Rule priority (optional; defaults to -1 if missing)          |


```json
{
    "install_flow_entries":
    [
        {
            "dpid": 106225808387660,
            "priority": 99,
            "match": {
                "eth_type": 2048,
                "ipv4_dst": "10.0.0.3"
            },
            "actions": [
                {
                "type": "OUTPUT",
                "port": 21
                }
            ]
        }
    ],
    "modify_flow_entries":
    [
        {
            "dpid": 106225808387660,
            "priority": 10,
            "match": {
                "eth_type": 2048,
                "ipv4_dst": "192.168.1.1"
            },
            "actions": [
                {
                "type": "OUTPUT",
                "port": 1
                }
            ]
        },
        {
            "dpid": 106225808387660,
            "priority": 10,
            "match": {
                "eth_type": 2048,
                "ipv4_dst": "192.168.1.2"
            },
            "actions": [
                {
                "type": "OUTPUT",
                "port": 1
                }
            ]
        },
        {
            "dpid": 106225808402492,
            "priority": 10,
            "match": {
                "eth_type": 2048,
                "ipv4_dst": "192.168.1.1"
            },
            "actions": [
                {
                "type": "OUTPUT",
                "port": 1
                }
            ]
        }
    ],
    "delete_flow_entries":
    [
        
        {
            "dpid": 106225808387660,
            "match": {
                "eth_type": 2048,
                "ipv4_dst": "192.168.1.3"
            }
        }
    ]
}
```
```json
{
    "install_flow_entries": [
        {
            "dpid": 5,
            "table_id": 0,
            "priority": 202,
            "match": {
                "eth_type": 2048,
                "ip_proto": 17,
                "ipv4_src": "10.0.0.1",
                "ipv4_dst": "10.0.0.2",
                "udp_src": 12345,
                "udp_dst": 5678
            },
            "actions": [
                {
                    "type": "OUTPUT",
                    "port": 2
                }
            ]
        },
        {
            "dpid": 5,
            "table_id": 0,
            "priority": 201,
            "match": {
                "eth_type": 2048,
                "ip_proto": 6,
                "ipv4_src": "10.0.0.1",
                "ipv4_dst": "10.0.0.2",
                "tcp_src": 12345,
                "tcp_dst": 443
            },
            "actions": [
                {
                    "type": "OUTPUT",
                    "port": 2
                }
            ]
        },
        {
            "dpid": 5,
            "priority": 203,
            "match": {
                "eth_type": 2048,
                "ip_proto": 1,
                "icmpv4_type": 8,
                "icmpv4_code": 0,
                "ipv4_dst": "10.0.0.2"
            },
            "actions": [
                {
                    "type": "OUTPUT",
                    "port": 2
                }
            ]
        }
    ],
    "modify_flow_entries": [],
    "delete_flow_entries": []
}
```
```json
{
  "install_flow_entries": [
    {
      "dpid": 5,
      "match": {
        "ip_proto": 6,
        "eth_type": 2048,
        "ipv4_src": "10.0.0.1/24",
        "ipv4_dst": "10.0.0.2/24",
        "tcp_src": 12345,
        "tcp_dst": 443
      },
      "actions": [
        {
          "type": "OUTPUT",
          "port": 2
        }
      ],
      "priority": 201
    }
  ],
  "modify_flow_entries": [],
  "delete_flow_entries": []
}
```

### Response

#### Success

* Status: **200 OK**

```json
{
  "status": "queued",
  "accepted": 3,
  "detail": "entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response"
}
```

#### Error

* Status: **400 Bad Request**

```json
{
  "error": "install_flow_entries/modify_flow_entries/delete_flow_entries must be arrays"
}
```
* Status: **400 Bad Request**
```json
{
  "error": "Bad entry"
}
```
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
* Status: **500 Internal Server Error**

```json
{
  "error": "internal server error"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```





## 24. GET /ndt/get_average_link_usage
### Description
Returns the average link utilization across all UP inter-switch links (host-facing links are excluded).
Only links with non-zero link_bandwidth_usage_bps are included in the average.

### Request
* Method: **GET**
### Example
```shell
 GET "http://127.0.0.1:8000/ndt/get_average_link_usage"
```
### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "success",
  "avg_link_usage": 0.12
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 25. POST /ndt/get_total_input_traffic_load_passing_a_switch
### Description
Returns the total incoming traffic load (bps) for a given switch.
It sums link_bandwidth_usage_bps for all edges whose destination DPID equals the provided dpid
(i.e., all incoming directed links to that switch).

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "dpid": 106225808380928
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "success",
  "total_input_traffic_load_bps": 12345678
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 26. POST /ndt/get_num_of_flows_passing_a_switch
### Description
Returns the number of flows passing a switch, computed by summing the number of flows over all
edges whose destination DPID equals the provided dpid (i.e., incoming links to that switch).


### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "dpid": 106225808380928
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "success",
  "num_of_flows": 42
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 27. POST /ndt/acquire_lock
### Description
Acquires a global lock (typed lock) to prevent application conflicts (mutual exclusion).
Supports optional type and ttl (seconds). If the JSON body is missing/invalid, defaults are used.

* Body Parameters:

| Field       | Type   | Description                                                             |
| ----------- | ------ | ----------------------------------------------------------------------- |
| `type` | `string` | Lock category. **Must be one of `routing_lock`, `graph_lock`, `power_lock`** — any other value is rejected with the `423` response below, which reports it as "System busy or invalid lock type" without distinguishing the two cases. |
| `ttl`   | `int` | lock time-to-live in seconds                  |


### Request
* Method: **POST**
* Content-Type: **application/json**
* Body
```json
{
  "type": "routing_lock",
  "ttl": 30
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "locked",
  "type": "routing_lock",
  "ttl": 30
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Busy / Invalid Type
* Status: **423 Locked**
```json
{
  "error": "Lock acquisition failed",
  "detail": "System busy or invalid lock type: routing_lock"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 28. POST /ndt/renew_lock
### Description
Renews (extends) the TTL of an existing lock to keep exclusive access.
Supports optional type and ttl. If missing/invalid JSON, defaults are used.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body (optional)
```json
{
  "type": "routing_lock",
  "ttl": 30
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "renewed",
  "type": "routing_lock",
  "ttl": 30
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Not Held / Expired / Invalid
* Status: **412 Precondition Failed**
```json
{
  "error": "Renew failed",
  "detail": "Lock 'routing_lock' is expired, not held, or invalid type"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```

## 29. POST /ndt/release_lock
### Description
Releases a previously acquired lock, allowing other applications to proceed.
Supports optional type. If missing/invalid JSON, the default lock type is used.

### Request
* Method: **POST**
* Content-Type: **application/json**
* Body (optional)
```json
{
  "type": "routing_lock"
}
```

### Response
#### Success
* Status: **200 OK**
```json
{
  "status": "released",
  "type": "routing_lock"
}
```

#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Busy / Invalid Type
* Status: **423 Locked**
```json
{
  "error": "Lock release failed", 
  "detail": "..."
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```


## 30. GET /ndt/get_detected_top_k_flow_data
### Description
Returns detailed information about the Top-K active flows observed by the network system (sFlow), including their estimated sending rates, timestamps, protocol type, and the full path taken across the network.

The returned list is sorted in descending order by:
`estimated_packet_rate_in_the_proceeding_1sec_timeslot`.

**Note:** For ICMP packets, the src_port field represents the ICMP type, and the dst_port field represents the ICMP code.

**Note:** `src_ip`/`dst_ip` are 32-bit integers holding the address in **network byte order** —
the same value as `struct in_addr::s_addr`, which is what the kernel stores and serialises directly.

Do **not** read the decimal digits as a host-order integer. `16777226` is `10.0.0.1`, not
`1.0.0.10`: its bytes are `0A 00 00 01`, which is the address in order. Convert with `ntohl()`
before formatting (portable, and a no-op on a big-endian host), or read the four bytes in
little-endian order. The host-order integer for `10.0.0.1` would be `167772161`.

Note also that string-valued IP fields elsewhere in this API (`get_path_switch_count`, the node
`ip` array, the static-topology endpoint) are ordinary dotted-quad text and need no conversion —
only these integer fields carry the byte-order caveat.

### Request
* Method: **GET**
### Response
#### Success
* Status: **200 OK**
```json
[
    {
        "dst_ip": 16885952,
        "dst_port": 55367,
        "estimated_flow_sending_rate_bps_in_the_last_sec": 1712000,
        "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 1817600,
        "estimated_packet_rate_in_the_last_sec": 3000,
        "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 3200,
        "first_sampled_time": "2025-08-22 10:13:12",
        "latest_sampled_time": "2025-08-22 10:13:17",
        "path": [
            {
                "interface": 5,
                "node": 1359063232
            },
            {
                "interface": 22,
                "node": 106225808391692
            },
            {
                "interface": 65,
                "node": 106225808398208
            },
            {
                "interface": 25,
                "node": 897475217989184
            },
            {
                "interface": 21,
                "node": 106225808403428
            },
            {
                "interface": 1,
                "node": 106225808402492
            },
            {
                "interface": 0,
                "node": 16885952
            }
        ],
        "protocol_id": 6,
        "src_ip": 1359063232,
        "src_port": 5201
    },
    {
        "dst_ip": 1359063232,
        "dst_port": 5201,
        "estimated_flow_sending_rate_bps_in_the_last_sec": 988560000,
        "estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot": 962242666,
        "estimated_packet_rate_in_the_last_sec": 81333,
        "estimated_packet_rate_in_the_proceeding_1sec_timeslot": 79166,
        "first_sampled_time": "2025-08-22 10:13:12",
        "latest_sampled_time": "2025-08-22 10:13:18",
        "path": [
            {
                "interface": 1,
                "node": 16885952
            },
            {
                "interface": 22,
                "node": 106225808402492
            },
            {
                "interface": 65,
                "node": 106225803167444
            },
            {
                "interface": 27,
                "node": 897475217989184
            },
            {
                "interface": 21,
                "node": 106225808384924
            },
            {
                "interface": 5,
                "node": 106225808391692
            },
            {
                "interface": 0,
                "node": 1359063232
            }
        ],
        "protocol_id": 6,
        "src_ip": 16885952,
        "src_port": 55367
    }
]
```
#### Error
Returned when the request body is not valid JSON, or JSON fields have invalid types/format.
* Status: **400 Bad Request**
```json
{
  "error": "JSON parsing error",
  "details": "<exception message>"
}
```
Returned when an unexpected runtime error occurs (e.g., invalid state, missing dependency, system failure).
* Status: **500 Internal Server Error**
```json
{
  "error": "Internal server error",
  "details": "<exception message>"
}
```
Returned when an unknown exception type is thrown.
* Status: **500 Internal Server Error**
```json
{
  "error": "An unknown error occurred"
}
```




