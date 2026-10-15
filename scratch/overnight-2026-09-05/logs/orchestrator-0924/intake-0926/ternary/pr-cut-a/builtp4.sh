#!/usr/bin/env bash
# supplementary: what the P4 suites do WITH the compiled p4info present (CI does not have it). p4_src/build is symlinked inside this clone only.
# the three suites builtp4.sh of pr-cut2 ran, plus the p4_proxy suites this PR touches.
ln -s /home/adam/Desktop/NDTwin-Kernel/p4_proxy/p4_src/build p4_proxy/p4_src/build || exit 3
cd p4_proxy
for t in test_table_entry_owner test_foreign_pipeline test_table_entry_owner_package test_p4_client_writes test_table_entry_route test_switch_state test_flow_stats_route; do
  PYTHONPATH=. /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3 tests/$t.py -v 2>&1 | grep -E "^(Ran|OK|FAILED)|skipped"; echo "$t rc=${PIPESTATUS[0]}"
done
rm p4_src/build
