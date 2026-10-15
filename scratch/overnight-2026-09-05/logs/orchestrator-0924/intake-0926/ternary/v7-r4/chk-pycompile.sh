#!/usr/bin/env bash
# py_compile of the changed .py files (output to a throwaway pycache prefix)
for f in p4_proxy/proxy_agent/p4_client.py p4_proxy/proxy_agent/api_routes.py p4_proxy/proxy_agent/main.py p4_proxy/tests/test_table_entry_owner.py p4_proxy/tests/test_table_entry_owner_package.py p4_proxy/tests/test_table_entry_route.py p4_proxy/tests/test_p4_client_writes.py p4_proxy/tests/test_exact_one_element_list.py p4_proxy/tests/test_foreign_pipeline.py; do
  [ -f "$f" ] || { echo "py_compile $f -> missing"; continue; }
  PYTHONPYCACHEPREFIX=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/v7r4/pyc /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3 -m py_compile "$f"; r=$?; echo "py_compile $f -> $r"
done
