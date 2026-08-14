> ⚠️ **裁決前言(主 session 覆核後加,2026-08-15 01:20)——先讀這裡再讀本文:**
> 本報告由 log 深掃 subagent 產出,證據行全數屬實,但**兩處系統級結論被 live 證據推翻或修正**:
> 1. **S2「P4 era 跑在空 twin 上」不成立。** 那 10 筆 `inform_switch_entered` connection
>    refused 發生在 **proxy 啟動階段**——stack.sh 的順序刻意讓 kernel 最後起([2/3] proxy
>    → [3/3] kernel),推播必然撲空;kernel 起來後靠**拉取**路徑填滿拓撲。live 實證:當晚
>    `stack.sh status` 回 `10 switches (10 up, 10 enabled), 4 hosts, 40 edges`,且 flow 帶
>    完整 7 跳路徑。**真正成立的縮小版發現**:①推播路徑在此啟動順序下必死,無重試;
>    ② proxy 那句「graph will stay partly disabled …for the rest」是誇大的錯誤預測,
>    會誤導日後讀 log 的人(本報告就是受害者)。
> 2. **S1 截斷機制指認修正:** 不是 kernel 開檔截斷——kernel 走 stdout,truncate 來自
>    **啟動器的 shell `>` 重導**(stack.sh 的 start_bg 與本輪手動啟動皆然)。修法相同
>    (`>>` 或輪替),但責任在 launcher 不在 kernel。
> 其餘發現(NTG 多文件 JSON、ApplicationManager 開機 sudo 清理三連敗、proxy 路由重裝
> 16 次、GUI graph 雙倍輪詢、NSR 重疊窗)經抽查採信,已併入矩陣文件明早清單。

# Cross-component integration test log audit — 2026-08-14 23:30 → 2026-08-15 01:00

Read-only audit. Nothing in any repo or log was modified. Logs were copied to
`scratchpad/snap/` at **00:58:01** and all line numbers below refer to that snapshot,
because `kernel.log` and `ryu.log` were still being written during the audit
(`kernel.log` grew 981,971 → 1,128,133 bytes between two reads).

Era boundaries used throughout:
- **P4 era** ~23:39–00:27 — bmv2 Mininet + P4 proxy + kernel
- **OVS era** 00:45+ — 128-host OVS Mininet + Ryu (6653) + kernel

Snapshot line counts: kernel.log 8,967 · ryu.log 2,734 · p4_proxy.log 7,031 ·
NSR_2026-08-14.log 1,538 · NSR_2026-08-15.log 181.

---

## 1. NEW anomalies, severity-ranked

### S1 — HIGH — the entire P4-era kernel log was destroyed by the restart · **lasting effect**

`kernel.log` contains **only the OVS era**. Its first line is:

```
[2026-08-15 00:46:00.429] [info] [main.cpp:299 main] Logger Loads Successfully! level
```

`kernel.log` line 1 (`.test_run/logs/kernel.log`). Per-minute bucket counts run
`00:46 → 00:57` and nothing earlier. A search for any Aug-14 content across the whole
log directory returns nothing:

```
$ grep -lE '2026-08-14' /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/*.log*
(no output)
```

The six rotated siblings (`kernel.log.prefix`, `.prev`, `.beforeblips`, `.pre20`,
`.preflagfix`, `.2026-08-11-run1`) all end on 2026-08-11/08-12, so no copy survives.
Both the P4-era run and the intermediate ~00:32 start are unrecoverable.

**Hypothesis:** the kernel opens `kernel.log` in truncate mode rather than append on each
start, so every restart erases the previous era. The two restarts tonight were expected;
the data loss was not.

**Consequence for this audit:** deliverable 3 cannot be answered from `kernel.log` for the
P4 era. I reconstructed the P4-era kernel request profile from the *server* side
(`p4_proxy.log`) instead — see §3.

---

### S2 — HIGH — P4 proxy: all 10 `inform_switch_entered` calls refused; proxy declares itself permanently degraded · **lasting effect**

`p4_proxy.log` lines 70–79, one per switch, all identical apart from the dpid:

```
[Kernel] switch 1 entered: FAILED ConnectionError: HTTPConnectionPool(host='localhost', port=8000): Max retries exceeded with url: /ndt/inform_switch_entered?dpid=1 (Caused by NewConnectionError("HTTPConnection(host='localhost', port=8000): Failed to establish a new connection: [Errno 111] Connection refused"))
```

followed immediately by line 80:

```
[Proxy Agent] Kernel acknowledged only 0/10 switches (missing [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]); the graph will stay partly disabled and paths/rates will be empty for the rest
```

This is **not** the known ":8080 curl at kernel startup" item: different port (8000),
opposite direction (proxy → kernel, not kernel → proxy), ten occurrences rather than one,
and the proxy's own message states it does **not** recover ("for the rest").

Context makes it worse: the proxy had already succeeded at everything on the bmv2 side
before this — 10× `Received arbitration response: Mastership confirmed.`, 10×
`Connected to Switch N`, 10× `Clone session 250 -> port 255 installed`, 10×
`Switch N sampling to sFlow as 192.168.123.1N` (lines 20–69). So the data plane was fully
up and only the kernel handshake failed.

**Hypothesis:** the proxy's startup handshake races the kernel's HTTP listener with no
retry or backoff; the proxy won the race and burned its only attempt. The P4 era therefore
ran ~48 minutes with a twin graph the proxy itself expected to be empty.

---

### S3 — MEDIUM — NTG flow logs are not valid JSON: 10 of 70 files hold concatenated documents · **lasting effect**

`json.load()` fails outright on 7 of the 70 files, e.g.:

```
receiver_h26_40185_tcp_1786726022.json: Extra data: line 134 column 1 (char 2812)
```

The files contain multiple whole iperf3 JSON documents written back to back. At the seam in
`receiver_h26_40185_tcp_1786726022.json` (line 134 onward) a second document opens with a
different peer than the first:

```
}
{
	"start":	{
		"connected":	[{
				"socket":	8,
				"local_host":	"10.0.0.26",
				"local_port":	40185,
				"remote_host":	"10.0.0.38",
				"remote_port":	54870
			}],
```

Decoding each file with `raw_decode` in a loop gives the true document counts:

| file | documents |
|---|---|
| `receiver_h122_49215_tcp_1786726022.json` | 315 |
| `sender_h122_49215_tcp_1786726022.json` | 315 |
| `receiver_h26_40185_tcp_1786726022.json` | 280 |
| `sender_h26_40185_tcp_1786726022.json` | 280 |
| `receiver_h44_51187_tcp_1786726022.json` | 273 |
| `sender_h44_51187_tcp_1786726022.json` | 273 |
| `receiver_h54_57019`, `h67_51875`, `h76_40815`, `h86_41743` | 2 each |

**1,734 documents beyond the first** are invisible to any consumer that calls `json.load()`
— and a consumer that instead reads only the first document silently undercounts
`h122_49215` by 314/315 of its records. `receiver_h26_40185_tcp_1786726022.json` is 37,157
lines / 800,915 bytes for what is nominally one flow record.

**Hypothesis:** NTG names the log by `(host, port, run-timestamp)` and appends each iperf3
invocation's JSON to it; short repeated flows reuse the same key within one run and pile up
in one file.

---

### S4 — MEDIUM — two NSR instances ran concurrently for 41s against one output directory

`NSR_2026-08-14.log` line 1523 onward shows instance A still alive:

```
2026-08-15 00:53:14 | INFO : Stopping NSR...
2026-08-15 00:53:22 | INFO : NSR stopped.
```

while `NSR_2026-08-15.log` line 1 shows instance B already started:

```
2026-08-15 00:52:41 | INFO : Recorder settings: NDTwin server: http://127.0.0.1:8000, Request interval: 5 seconds, Storage interval: 2 minutes
```

Both target the same kernel and the same `./recorded_info/`. During the 41-second overlap
instance A ran its zip-and-delete pass (`00:53:17 | INFO : Starting to zip stored JSON files
: ./recorded_info/2026_08_15_00-51-44_flowinfo.json...`) while instance B was writing into
the same directory.

**Error logged but self-healed this run** — A only zipped files it owned
(`00-51-44_*`, its own), so nothing was lost. The hazard is structural: a zip-and-delete
sweep in a directory another live recorder is writing to.

**Hypothesis:** the second recorder was launched before the first was confirmed stopped;
nothing in NSR prevents a second instance binding the same output directory.

---

### S5 — LOW/MEDIUM — P4 proxy re-installs the entire proactive route table once per discovered link

`[TopologyManager] Installing initial routes proactively...` appears **16 times** in
`p4_proxy.log` (lines 85, 89, 92, 95, 98, 101, 104, 107, 112, 122, 214, 248, 267, 409, 416,
564) — once after each `[TopologyManager] Discovered link: ...`. Each pass re-emits the full
rule set, always starting from the same first rule:

```
[TopologyManager] Proactive Rule: DPID 1: 10.0.0.1/32 -> Port 3 (MAC: 00:00:00:00:00:01)
```

The write breakdown confirms the redundancy: **39** `Added route` vs **368**
`Modified route` — roughly 90% of the 407 proactive writes rewrite an entry that already
holds the correct value.

**Self-healing** (the writes are idempotent and the end state is correct), but it is
O(links × rules) P4Runtime writes at every startup, and the word "initial" is inaccurate
after the first pass.

---

### S6 — LOW — kernel warns about NFS exports that do not exist, and leaks 9 sudo prompts to stderr · **no lasting effect**

All 17 warnings in `kernel.log` come from this one startup path (lines 6–40), plus 9
un-prefixed stderr lines. Representative quotes:

```
[2026-08-15 00:46:00.440] [warning] [ApplicationManager.cpp:285 cleanupAppFolder] 'sudo exportfs -u /srv/nfs/sim/3' failed (exit status 1). The export is still live.
[2026-08-15 00:46:00.447] [warning] [ApplicationManager.cpp:296 cleanupAppFolder] 'sudo sed -i' failed to remove /srv/nfs/sim/3 from /etc/exports (exit status 1). The entry will be re-exported on the next reload.
[2026-08-15 00:46:00.495] [warning] [ApplicationManager.cpp:355 cleanupStaleEntries] 'sudo exportfs -ra' failed while clearing stale entries (exit status 1). Stale exports from a previous run may still be live.
```

and interleaved on stderr (kernel.log lines 7–8, ×9 total):

```
sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
sudo: a password is required
```

**The warnings' stated consequences did not materialise.** Current state:

```
$ cat /etc/exports        → /srv/nfs/sim 127.0.0.1(rw,sync,no_subtree_check,all_squash)
$ cat /var/lib/nfs/etab   → /srv/nfs/sim 127.0.0.1(...)
$ showmount -e localhost  → /srv/nfs/sim 127.0.0.1
$ ls /srv/nfs/sim/        → empty
```

There is only ever one export (the parent), so the per-app `exportfs -u /srv/nfs/sim/N`
and the `sed` were always going to fail regardless of sudo — and "The export is still live"
/ "will be re-exported on the next reload" are both false. The folder deletions themselves
succeeded.

This is adjacent to but distinct from the known Energy-App NFS chain: that one is
`setupNFSForApp` / chown / all_squash at app-launch; this is `cleanupStaleEntries` /
`exportfs` at kernel startup.

**Hypothesis:** `cleanupAppFolder` assumes each app folder is its own NFS export; it is not.

---

### S7 — LOW — `get_graph_data` latency triples under load · no lasting effect

Measured as the gap between `Handle Get Graph Data` and `get_graph_data success`:

| minute | n | p50 ms | p90 ms | max ms |
|---|---|---|---|---|
| 00:46–00:53 | 120–132/min | 14–16 | 17–18 | 18–29 |
| 00:54 | 132 | 16 | 32 | 73 |
| 00:55 | 185 | 36 | 64 | 148 |
| 00:56 | 224 | 47 | 67 | 155 |
| 00:57 | 230 | 44 | 71 | 134 |

Across the window: n=1,751, p50 17 ms, p90 53 ms, max 155 ms, **46.4 s of wall time spent
serializing the graph in 12 minutes** (~6.4% of one core). The degradation tracks the
second NTG run (~00:54) and TE-App joining (00:55) rather than accumulating over time, so
it reads as load, not a leak — but it is the most expensive endpoint and it is also the
most-polled (see §3).

---

### Files with NO new anomalies

- **`ryu.log`** — explicitly clean. All **814** HTTP responses are `200`; zero non-2xx, zero
  tracebacks. The 10 `Link deleted` / `removed edge` / `topology changed (link N -> N down)`
  events (lines 615–653) are **not** a mid-run flap: every one is followed by the matching
  `Link added` in the same block, and the whole block sits **before the first access-log
  timestamp of `00:45:10`** — i.e. normal LLDP discovery settling during Mininet bring-up.
  42 `Link added` vs 10 `Link deleted` nets out to the 32 expected links.

---

## 2. NTG run quality — `flow_logs/2026-08-15_00_47_02/`

Counted after splitting the concatenated documents described in S3; totals differ from a
naive `json.load()` pass, which fails on 7 files.

**Pair completion**

- 70 files = 35 senders + 35 receivers; **35/35 pair cleanly** on `(host, port, timestamp)`.
  No unpaired file on either side.
- **35/35 pairs completed with bytes > 0 on both sides.** There are **no zero-byte pairs and
  no unrecoverable parse failures.**
- Caveat worth stating plainly: a naive reader *would* report zero-byte failures here. In an
  interrupted iperf3 run the sender's `end.sum_received` is 0 and the receiver's
  `end.sum_sent` is 0; reading the wrong one shows `bytes=0` for 4 files that in fact moved
  1.8 GB and 5.5 MB. Take `max(sum_sent, sum_received)` per document.

**Volume**

| | n | min | median | max | total |
|---|---|---|---|---|---|
| sender bytes | 35 | 4,380 | 2,099,200 | 1,822,525,440 | **2,330,471,472** (2.33 GB) |
| receiver bytes | 35 | 4,380 | 2,088,960 | 1,819,596,800 | **2,323,483,696** (2.32 GB) |

Sender/receiver totals agree to within 0.3% (6.99 MB), consistent with in-flight data lost
at interrupt. **One flow dominates:** `h61:40961` alone moved 1.82 GB = **78%** of all bytes.
Excluding it, the other 34 senders total **507,946,032** bytes (508 MB) with a max of
241 MB.

**Rate distribution** (peak `bits_per_second` per sender file)

- min **1.44 Mbps** · median **14.9 Mbps** · max **964.2 Mbps**
- deciles (Mbps): 1.4, 1.4, 2.7, 9.9, 14.9, 30.1, 30.1, 35.9, 37.4

The distribution is multi-modal and matches the configured `target_bitrate` tiers — clusters
at ~1.4 Mbps (4,380-byte micro-flows), ~8.4/9.9 Mbps, ~30 Mbps, ~37.4 Mbps (10-second
46 MB flows) — plus two unbounded outliers at 927 and 964 Mbps. Nothing here is near the
bmv2 ~170 Mbps ceiling because this burst ran in the **OVS** era.

**Errors**

12 files carry an iperf `error` field — 10 receivers and 2 senders:

```
receiver_h112_55931, receiver_h122_49215, receiver_h26_40185, receiver_h44_51187,
receiver_h54_57019, receiver_h61_35219, receiver_h61_40961, receiver_h67_51875,
receiver_h76_40815, receiver_h86_41743      → "interrupt - the server has terminated"
sender_h112_55931, sender_h61_40961          → "interrupt - the client has terminated"
```

Receiver-side interrupts are the expected teardown signature of `iperf3 -s`. The two
**sender**-side interrupts are the interesting ones, and they have a clean cause: they are
**exactly the two sender tests configured with `duration=0`, `bytes=0`** — no time limit and
no byte cap, so they could only ever end by being killed:

- `sender_h61_40961` — `target_bitrate=0` (unthrottled): 1,822,525,440 bytes in 15.72 s @ 927 Mbps
- `sender_h112_55931` — `target_bitrate=3000000`: 5,509,120 bytes in 14.68 s @ 3.0 Mbps

All other 33 sender tests carry a finite `bytes` or `duration` and terminated on their own.

**Retransmits:** only 3 senders reported any, 1 retransmit each —
`sender_h67_51875`, `sender_h83_33129`, `sender_h86_41743`.

**TCP vs UDP:** **70/70 TCP, 0 UDP.** Every filename carries `_tcp_` and every parsed
`test_start.protocol` is `TCP`. If this burst was meant to exercise a UDP path, it did not.
`num_streams` is 1 for every test.

**Timing:** test start timestamps span 1786726022–1786726038 = **16 seconds**
(8 tests at t=0, then 5/5/5, then 3/3/3/3), so the "burst" is a 16-second staggered launch,
not simultaneous.

---

## 3. Kernel request-traffic profile

### OVS era — from `kernel.log`, window 00:46:00.429 → 00:58:00.935 (720.5 s)

| endpoint | count | rate |
|---|---|---|
| `GET /ndt/get_graph_data` | 1,751 | 2.43/s |
| `GET /ndt/get_detected_flow_data` | 876 | 1.22/s |
| `GET /ndt/get_memory_utilization` | 69 | 0.10/s |
| `GET /ndt/get_cpu_utilization` | 69 | 0.10/s |
| `POST /ndt/acquire_lock` | 17 | — |
| `POST /ndt/release_lock` | 17 | — |
| `POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries` | 1 | — |
| `GET /ndt/get_path_switch_count` | 1 | — |
| **total** | **2,801** | |

Connections: 370 `Accepted new connection` vs 365 `Close Socket`.

**4xx/5xx/exceptions: none.** `kernel.log` contains **0 error-level and 0 critical-level
lines**; the only 17 warnings are the S6 NFS block at startup. A grep for
`exception|throw|traceback|segfault|assert|abort|fatal|panic|refused|timeout|fail|invalid|denied|4xx|5xx`
returns only those 17 warnings — the apparent extra hits are false positives where `400`
matched a millisecond field such as `[2026-08-15 00:54:01.400]`. The kernel logged no HTTP
status codes at all, so a silent 4xx/5xx cannot be ruled out from this log alone.

### Poller consistency — per-minute breakdown

| minute | graph_data | detected_flow | cpu | mem | acquire_lock |
|---|---|---|---|---|---|
| 00:46 | 121 | 59 | – | – | – |
| 00:47 | 120 | 61 | – | – | – |
| 00:48–00:51 | 120 | 60 | – | – | – |
| 00:52 | 124 | 65 | – | – | – |
| 00:53 | 132 | 72 | – | – | – |
| 00:54 | 132 | 72 | – | – | – |
| 00:55 | 185 | 79 | – | – | 5 |
| 00:56 | 224 | 110 | 32 | 32 | 6 |
| 00:57 | 230 | 115 | 37 | 37 | 6 |

Reading the steps off this table:

- **NSR at 5 s — confirmed exactly.** Both endpoints step by **+12/min** from 00:53
  (120→132, 60→72), which is 0.2/s. The partial step at 00:52 (+4 graph, +5 flow) matches
  NSR instance B starting at **00:52:41**, ~19 s into that minute. Note this is instance B
  only; instance A's polling threads were already dead (known finding).
- **TE-App at 10 s — confirmed exactly.** `acquire_lock`/`release_lock` run at **6/min**
  from 00:55:18, always paired, always within 6–99 ms of each other
  (e.g. `00:55:18.687` acquire → `00:55:18.693` release).
- **Web-GUI at 1 s — confirmed for `get_detected_flow_data`, but `get_graph_data` runs at
  double that.** From kernel start, before NSR-B or TE-App joined, the baseline is a flat
  **120/min graph_data vs 60/min detected_flow_data** — 2.00/s against 1.00/s. A single 1 s
  poller hitting both endpoints would produce 60/60. See §4.
- **TE-App's 1 s read loop does not look like 1 s.** Its contribution above the NSR-era
  baseline is ~92–98/min graph (~1.6/s), ~38–43/min flow (~0.7/s) and 32–37/min cpu and mem
  (~0.55/s) — none of which is a clean 1/s, and the cpu/mem endpoints do not appear at all
  until 00:56 even though the lock cycle started at 00:55:18.

**Overall verdict:** volume is consistent with the stated pollers for NSR (5 s) and TE-App's
10 s control loop, both to the request. It is *not* consistent for `get_graph_data`, which
runs at exactly twice the expected 1 s rate for the whole era, and TE-App's read cadence is
irregular rather than 1 s.

### P4 era — reconstructed from `p4_proxy.log` (kernel.log destroyed, see S1)

These are the kernel's requests as seen by the proxy serving them; the proxy emulates the
Ryu REST surface. Window ~23:39–00:27:46 (~2,880 s).

| endpoint | count | implied cadence |
|---|---|---|
| `GET /p4/switch_state` | 2,836 | ~1.0 s |
| `GET /stats/flow/{1..10}` | 287 each (2,870) | ~10 s per switch |
| `GET /v1.0/topology/switches` | 112 | ~26 s |
| `GET /v1.0/topology/hosts` | 112 | ~26 s |
| `GET /v1.0/topology/links` | 112 | ~26 s |
| `GET /ryu_server/all_destination_paths` | 51 | ~56 s |

All **6,093** proxy responses were `200 OK` — zero non-2xx. Note this is the *kernel →
proxy* direction only; it says nothing about Web-GUI/NSR/TE-App traffic into the kernel
during the P4 era, which is unrecoverable.

**Cross-check against the OVS era** (`ryu.log`, same 720 s window): 680 `/stats/flow/N`
(~10.6 s per switch), 41 `/topology/links`, 40 `/topology/switches`, 40 `/topology/hosts`
(~18 s), 12 `/ryu_server/all_destination_paths` (~60 s). The 12 matches `kernel.log`'s 12
`Pulled 16256 paths from controller` exactly — kernel and controller agree, and 16,256 =
128 × 127, the full host-pair path set.

---

## 4. Worth a second look

1. **`get_graph_data` is polled at exactly 2× `get_detected_flow_data` from kernel start.**
   120/min vs 60/min flat across 00:46–00:51, before NSR-B or TE-App existed. Either the
   Web-GUI issues two graph reads per 1 s cycle, or two GUI clients/tabs were open. It
   matters because `get_graph_data` is the most expensive endpoint in the process (§S7,
   46.4 s of serialization in 12 min).
   Evidence: `00:46 get_graph_data 121` / `00:46 get_detected_flow_data 59`.

2. **TE-App took the lock 17 times and pushed flows once.** 17 `acquire_lock`/`release_lock`
   pairs from 00:55:18, but only one `install_flow_entries_...` (00:57:48.964). 16 of 17
   control cycles were no-ops that still took the global lock.
   Evidence: `[2026-08-15 00:57:48.964] ... Got request: POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries` — the only one.

3. **A raw JSON dump sits at info level in the request path.** `HttpSession.cpp:895` prints
   the entire flow batch, prefixed with a bare `j`:
   ```
   [2026-08-15 00:57:48.964] [info] [HttpSession.cpp:895 processFlowBatch] j {
     "modify_flow_entries": [
   ```
   It was harmless tonight (one 20-line batch) but scales with batch size and looks like a
   left-in debug print.

4. **`purgeIdleFlows` prints only the IP pair of a 5-tuple key, which makes distinct flows
   look like duplicate log spam.** At `00:47:18.786` the line
   `Flow Key: 10.0.0.58 -> 10.0.0.122 idles` appears **38 times**, and 341 of the 791 purge
   lines are same-millisecond textual duplicates.
   **This is not a duplicate-purge bug — I checked the code before reporting it.**
   `m_flowInfoTable` is an `unordered_map` keyed by `FlowKey`, which carries
   `srcPort`/`dstPort`/`protocol` as well as the IPs (visible in
   `FlowLinkUsageCollector::getFlowInfoJson`), and `purgeIdleFlows` sleeps 1,000 ms per
   pass — so 38 lines in one millisecond are 38 *distinct* flows (38 iperf connections
   between the same host pair) printed under one ambiguous label. The fix is to log the
   ports, not to change the purge. Flagging it because the log as written will mislead the
   next reader exactly as it initially misled me.

5. **One unbounded flow produced 78% of the run's bytes.** `h61:40961` had
   `target_bitrate=0`, `duration=0`, `bytes=0` — no throttle, no stop condition — and moved
   1.82 GB at 927 Mbps until it was killed at 15.72 s. Every aggregate over this run
   (total bytes, mean rate) is dominated by it. If the flow spec was meant to be capped,
   that is a generator-config bug; if intentional, aggregates should be reported with it
   excluded.

6. **All 70 tests were TCP.** Zero UDP in a 35-flow burst. Worth confirming against the
   intended traffic profile, since a UDP path would exercise different twin code
   (no retransmit accounting, different sFlow sampling behaviour).

7. **NSR picks its log filename at startup and never rolls it.** `NSR_2026-08-14.log`
   contains records through `2026-08-15 00:53:22`, and `NSR_2026-08-15.log` is a *second
   instance*, not a new day. Anyone diffing "yesterday vs today" by filename will be wrong.

8. **NSR's "No new data" warnings are benign — do not chase them.** 12 warnings in the P4
   era (23:42:15–23:43:10) and 23 in the OVS era (00:52:41–00:54:31), all
   `No new data from http://127.0.0.1:8000/ndt/get_detected_flow_data.` In both cases they
   start when NSR starts and **stop the moment traffic begins** — the OVS run's last one is
   `00:54:31`, right as the second NTG run starts at ~00:54. They track idle periods, not a
   defect.

9. **370 accepted connections vs 365 closed** in `kernel.log`. A 5-socket gap over 12
   minutes, most plausibly sessions still open at snapshot time rather than a leak, but
   worth a longer-run check before dismissing.

10. **`sFlow ingest healthy` appears exactly once, with `addressed=0`:**
    `[2026-08-15 00:46:10.766] ... sFlow ingest healthy: rx=1, app_drop=0, addressed=0, sock_ovfl_total=0`.
    This is **expected** — the code deliberately logs at info only on the first pass with
    `rx > 0` and at trace thereafter, and it emits a warning if nothing arrives within 60 s
    (no such warning fired). Ingest was genuinely working, as the populated flow table
    proves. Noted only because a reader grepping for sFlow health will find one line with
    `addressed=0` and reasonably conclude the opposite.
