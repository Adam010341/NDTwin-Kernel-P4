#!/bin/bash
cat >> ~/BUGS.md << 'INNEREOF'

## Note: BUG-2's self-test false-failure also reproduces in NTG's own copy of testbed_topo.py
Running NTG's Terminal 2 (`sudo ~/ntg-env/bin/python testbed_topo.py` from the
Network-Traffic-Generator repo -- a different script from NDTwin-Kernel's own testbed_topo.py,
but evidently sharing the same lineage) produced the identical pattern already logged as
BUG-2: 128 pings, all "100% packet loss", followed immediately by "Host internet: OK | sFlow
reachability: OK | Switch identification: OK" and a working CLI/fabric afterward (confirmed
working by the `flow`/`dist` commands both successfully driving real iperf3 traffic and the
kernel independently reporting 29 detected flow records during the `flow --config
flow_template.json` run). Not filing as a fourth separate bug -- same root symptom, different
copy of the same script -- but recording because it shows the false-failure is not particular
to one repository's checkout of the file.
INNEREOF
echo APPENDED
