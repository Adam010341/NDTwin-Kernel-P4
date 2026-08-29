# Generating Traffic (Validation): the detector works, and the documented check cannot see it

**Date:** 2026-08-29 (session opened 2026-08-28; directory keeps its creation date)
**Page:** User Manual → NDTwin Kernel → Operate an Emulated (Software) Network →
Native-Linux Execution Environment, "Generating Traffic (Validation)" (appears twice: the
OVS section at L84 and the P4 section at L303, which says "Exactly as in the OVS flow above")
**Fabric:** the live 128-host P4 fabric, 10 BMv2 switches, 288 links, 16256 destination paths

---

## Why this was re-opened

`COVERAGE.md` listed this step as verified *only* to the extent that
`/ndt/get_detected_flow_data` returns **HTTP 200**. That is not the claim the page makes, and
the page's own acceptance sentence is why:

> **Expected:** The API returns a JSON response containing the currently detected flow
> records (or an empty list if no flows have been captured yet).

**An empty list satisfies that sentence.** Any 200 passes. If flow detection were entirely
dead, this step would still read as success — so the check covers none of the failure modes
it exists to catch. The criterion was replaced with one that can go red:

> **PASS** ⟺ after real h2 → h1 iperf3 traffic, the response *body* contains a record
> identifying the pair 10.0.0.2 → 10.0.0.1, which was absent beforehand.

The baseline is what makes that mean anything: measured at 00:16:27, the endpoint returned
`200`, **2 bytes, `[]`** — after mainDev had driven ~3 h 50 m of iperf3 through this same
fabric. Zero records. Without that reading, "a flow appeared" would prove nothing.

## Result 1 — the detector works, and is correct

| | |
| :--- | :--- |
| baseline (t+0) | `[]`, 0 records |
| t+5 s | **2 records**, both directions of the pair |
| held continuously | to t+312 s |
| gone | t+317 s |

Both directions are present and correctly attributed: 1.197 Gbit/s h2→h1 (the bulk transfer)
and 25.1 Mbit/s h1→h2 (the ACK stream), with a three-hop `path` of h1 → s1 → h2. That is the
right shape for a default iperf3 run. **The claim the page makes is true.**

Identification was done two independent ways, and the script aborts if they disagree:

1. **Port identity** — the record whose `src_port` is 5201 must be the server this test
   started inside h1's namespace. That names h1 with no arithmetic.
2. **Byte order** — `16777226` = `0x0100000A`, reversed `0x0A000001` = `10.0.0.1`.

They agree. (Two routes because arithmetic that merely fits is not a mechanism — one of them
had to be independent of the byte-order guess.)

## Result 2 — the API reports IPs as raw integers, and nothing tells the reader

The response identifies hosts as `"src_ip": 16777226`, not `"10.0.0.1"`:

```
src/ndt_core/collection/FlowLinkUsageCollector.cpp:2300
    j["src_ip"] = flowKey.srcIP;          <- raw uint32
```

The same codebase converts elsewhere — `utils::ipToString(e.srcIp)` at `:2726` and
`HttpSession.cpp:1732` — and `purgeIdleFlows()` twenty lines below even *logs* the same field
as a dotted quad. Two conventions, one struct; this endpoint uses the undecoded one.

⇒ A reader told to "confirm the kernel is detecting flows" is handed integers with no key.
The page shows a screenshot and no decoding hint. To check their own host they need:

```bash
python3 -c "import struct,sys; print('.'.join(str(b) for b in struct.pack('<I',int(sys.argv[1]))))" 16777226
```

Not a defect in the kernel — but the manual asks the reader to perform a comparison it never
gives them the means to perform.

## Result 2b — the `path` field, and a negative result on `get_path_switch_count`

Asked for specifically, because round 6 established that `get_path_switch_count` returns the
same number for three different states and therefore has no discriminating power, while
`get_detected_flow_data`'s `path` does. **If the manual sent readers to the former, that would
itself be a finding.** It does not:

| page | endpoints it tells a reader to call |
| :--- | :--- |
| User Manual / Native-Linux | `/ndt/get_detected_flow_data` ×2 (both Generating Traffic sections) |
| Installation Manual / Native-Linux | none |

`get_path_switch_count` appears **only** in `NDTwin Developer Manual / NDTwin Kernel API.md`
(§22, L1425), which is a reference listing, not a validation instruction. ⇒ Negative result:
the manual does not steer readers onto the blunt endpoint. (Separately, and outside this
deliverable: that reference page documents an endpoint round 6 found non-discriminating,
without saying so. Noted, not chased.)

The `path` that *is* discriminating, across all 130 records sampled:

```json
"path": [ {"interface": 3, "node": 16777226},
          {"interface": 4, "node": 1},
          {"interface": 0, "node": 33554442} ]
```

- **All 130 records are 3 hops**, and there are exactly **two** distinct node sequences —
  `10.0.0.1 → s1 → 10.0.0.2` and its exact mirror. The two directions agree on the switch.
- It names the actual switch, so it *can* distinguish one path from another. That is the
  property `get_path_switch_count` lacks.

🔑 **`node` is an overloaded field.** Hosts appear as uint32 IPs (`16777226`); switches appear
as dpids (`1`). Same key, two namespaces, no type tag — a consumer can only tell them apart
by magnitude, which is a heuristic, not a rule. It happens to work here because dpids are
small and these IPs are large, and it is exactly the kind of thing that holds until it
doesn't. Recorded as an observation about the API, not as a manual defect.

## 🔴 Result 3 — following the printed steps, the expected outcome is `[]`

Detected flows are purged **15 s** after their last sample:

```
include/ndt_core/collection/FlowLinkUsageCollector.hpp:35
    #define FLOW_IDLE_TIMEOUT 15000 // milliseconds
```
`purgeIdleFlows()` sweeps at 1 Hz, so removal lands 15–16 s after the last packet. Measured
decay matched: last record t+312 s, empty t+317 s, client having exited at ≈t+302 s.

Now read the page as printed:

```
2. Run a client on Host 2:
mininet> h2 iperf3 -c h1 -t 300          <- no `&`; blocks the prompt for five minutes
3. Verify detected flow data (NDTwin API):
curl -X GET http://localhost:8000/ndt/...  <- no `mininet>` prefix; a different terminal
```

The reader waits out 300 s of blocked prompt, then switches terminals and types the curl. If
that takes longer than ~15 s — switching windows and typing it does — **their flow is already
purged and they get `[]`**, which the page calls expected.

Demonstrated rather than inferred, sweeping the gap between the client exiting and the curl:

| gap | client transferred | records at t+0 | records when the reader curls |
| ---: | :--- | ---: | ---: |
| 5 s | 2.61 GBytes | 2 | **2** |
| 20 s | 2.58 GBytes | 2 | **0** |
| 30 s | 2.59 GBytes | 2 | **0** |

⇒ **On a completely healthy system, the documented procedure's most likely outcome is the
empty result, and the document blesses it.** The step cannot distinguish success from total
failure in either direction: it passes when broken, and it shows nothing when working.

🔑 The transferable shape: **an acceptance criterion whose two branches are both spelled
"pass".** The usual version of this mistake is a criterion that is too weak; this one also has
its *timing* set so the informative branch is the one the reader is least likely to reach.

## What I got wrong, both times in the same direction

1. **The live matcher searched for the string `"10.0.0.2"`** and reported 0 matches for the
   whole 450 s run while the endpoint was reporting the flow perfectly. Had the script stored
   only its verdict and not the response bodies, this file would say FAIL. It says PASS
   because every body was kept and could be re-analysed. *The instrument was wrong and its
   output was indistinguishable from the finding.*
2. **The first reader-experience sweep reported "0 records at a 20 s gap" from a client that
   never sent a byte.** My previous test's iperf3 server had survived its own cleanup and
   held `:5201`, so the new server died with "Address already in use" and the client got
   "Connection refused". *No traffic also produces `[]`* — a broken injection produced exactly
   the observation I was trying to make. Re-run with four assertions (port free, server
   listening, **client actually transferred**, record present at t+0) and an abort rather than
   a number. All three sweep points then held, and cleanup was verified this time.

Both failures pointed the same way: toward the more interesting conclusion.

## Recommended change to the page

The fix is not wording alone — the *order* is what breaks it. The reader must query while
traffic is still flowing:

- background the client (`... -t 300 &`) or state plainly "leave this running and, in another
  terminal, ...";
- give a criterion that can fail — *find your own two hosts in the body*, with the integer
  decoding supplied;
- state the 15 s idle timeout, so an empty result is read as "you waited too long" rather than
  as success.

Drafted in the branch; see the companion edit to the User Manual page.

## Provenance

Scripts (kept out of the repo; they drive a live fabric):
`gt_baseline.sh`, `gt_hosts.sh`, `gt_run.sh`, `gt_analyse.py`, `gt_reader2.sh`.
Raw response bodies, one per 5 s sample, plus both clients' logs: `~/p4logs/gt/`.
Fabric was mainDev's, left running after their P1-3 block; it uses
`/usr/local/bmv2-fast/bin/simple_switch_grpc`, the §6.7 optional build, **not** the stock
binary the manual's main path installs. That is a deviation and is recorded as one — it is
not plausibly load-bearing for "does the API report a flow", but it was not controlled.

[Co-developed with claude code -- Adam]
