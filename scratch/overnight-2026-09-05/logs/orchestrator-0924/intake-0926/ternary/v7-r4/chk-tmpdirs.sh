#!/usr/bin/env bash
exec env -i PATH=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin:/usr/bin:/bin HOME=/tmp CI=true GITHUB_ACTIONS=true python3 tests/shell/check_test_tmpdirs.py
