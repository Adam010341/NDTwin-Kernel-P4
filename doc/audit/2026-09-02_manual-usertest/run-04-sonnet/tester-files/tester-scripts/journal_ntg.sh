#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Network Traffic Generator: install + use   started 16:04   ended 16:37   friction: 1
what I did: Installation Manual steps all worked (`python3 -m venv --system-site-packages
~/ntg-env`, pip deps, clone). Confirmed the manual's own claim that `--system-site-packages`
is load-bearing: `python3 -c "import mininet"` inside `ntg-env` resolved to the apt-installed
copy. User Manual step "modify NTG.yaml's host_file into ./setting/Mininet.yaml" turned out to
be non-optional, not just a suggestion -- the shipped `NTG.yaml` defaults to
`./setting/Hardware.yaml`. Editing it and running the documented 3-terminal sequence (Ryu,
then NTG's own `testbed_topo.py` via `sudo ~/ntg-env/bin/python`, then the Kernel) worked:
reached NTG's own "NTG>" prompt in `custom_command` mode. Its own copy of the topology
self-test showed the same false 100%-packet-loss pattern already logged as BUG-2 (see BUGS.md
note) -- but the fabric underneath was fine, confirmed by what came next.
`flow --config flow_template.json` ran a full mixed varied/fixed traffic experiment to
completion ("SUCCESS : Experiment completed."), and I cross-checked it against the kernel's
own API rather than trusting NTG's own log: `curl :8000/ndt/get_detected_flow_data` during the
run showed 29 real detected-flow records. `dist --config dist_template.json` (using the
shipped `cesnet_2022/*.csv` distribution files) also ran real iperf3 flows with
distribution-derived parameters. That config included unlimited-duration flows, so the CLI got
stuck (correctly) waiting for them to finish -- a natural opportunity to test the manual's
"Notice" that Ctrl-C does not cancel just the one experiment. It did exactly what the manual
says: "Keyboard interrupt received. Stopping ongoing tasks and exiting..." then tore down the
whole Mininet topology, not just the flow generation. Confirmed verbatim, not inferred.
surprised by: nothing about NTG itself broke; genuinely smooth once the one required YAML edit
was made. The self-test false-failure carried over from the Kernel's own copy of the script,
which was expected once BUG-2 was already known.
verdict: 1 confusing but worked -- the Hardware.yaml-vs-Mininet.yaml default and the implicit
"Terminal 3 kernel must already be running or NTG spins forever retrying" dependency are both
things the page could state more directly, but neither actually blocked anything once
followed.
EOF
echo APPENDED
