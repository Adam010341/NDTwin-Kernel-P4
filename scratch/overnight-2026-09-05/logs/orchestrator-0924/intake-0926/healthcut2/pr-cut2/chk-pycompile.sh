#!/usr/bin/env bash
# py_compile of the .py files Cut 2 changes vs trunk 6c1a78c8 (output to a throwaway pycache prefix)
for f in tests/python/test_grpc_port_block.py tests/python/test_p4_health_cells.py tests/python/test_p4_health_collect.py tools/p4_health/cells/table.py tools/p4_health/ctrl_trial.py tools/p4_health/frozen.py tools/p4_health/lab.py tools/p4_health/lab_round.py tools/p4_health/probe.py tools/p4_health/report.py tools/p4_health/s0.py tools/p4_health/throwaway.py; do
  [ -f "$f" ] || { echo "py_compile $f -> missing"; continue; }
  PYTHONPYCACHEPREFIX=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/prcut2/pyc /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3 -m py_compile "$f"; r=$?; echo "py_compile $f -> $r"
done
