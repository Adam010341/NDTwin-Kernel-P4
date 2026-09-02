#!/bin/bash
cat >> ~/BUGS.md << 'INNEREOF'

## Addendum to BUG-1: `ndt up` (bare, P4 default) fails the same way, with a better message
- **Feature:** `ndt up` with no argument -- the manual's own table: "p4 at the current host
  count (default)".
- **Exact steps:** ran it after Section 6 install finished for real (both `simple_switch_grpc`
  and `p4c-bm2-ss` confirmed working, `bmv2_binary_override` pointed at the stock build).
- **Observed (verbatim):**
  ```
  ndt up p4
    hosts        128        (p4_proxy/mininet/host_count_override)
    topology     setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
    bmv2         /usr/local/bin/simple_switch_grpc
  [1/3] bmv2 fabric
    waiting for 10 switches and the manifest
    XX  fabric did not come up: 0/10 switches, manifest missing
    XX  look at the pane:  sudo -n /usr/local/sbin/ndtwin-lab topo-out 40
  ```
  Took 3m06s to give up (18:13:23 -> 18:16:29) -- faster than `ndt up ovs`'s 5m08s, so the two
  paths apparently use different timeout values. Followed its own suggested diagnostic:
  `sudo -n /usr/local/sbin/ndtwin-lab topo-out 40` -> `ndtwin-lab: no topo session` (exit 1) --
  consistent with BUG-1's root cause (the hardcoded `/home/adam` paths mean `ndtwin-lab` never
  starts a topology session at all for this fabric either). `ndt down` afterward reported the
  machine fully clean.
- **Reproduced:** this is the P4 counterpart of the already-reproduced OVS case, and the root
  cause is identical (verified once by reading the one file the manual names) -- not repeated a
  third time.
- **Severity:** same as BUG-1. Noted here mainly because the failure message is *better* on
  this path -- it names a concrete diagnostic command, even though following it only confirms
  "nothing started" rather than explaining why.
INNEREOF
echo APPENDED
