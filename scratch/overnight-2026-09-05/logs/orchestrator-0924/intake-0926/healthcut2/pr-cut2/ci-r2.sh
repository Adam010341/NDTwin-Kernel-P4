#!/usr/bin/env bash
# ci-r2.sh <dir> <suite.sh> : same shape as ci-prediction-pr32.raw/ci5.sh (env -i, own session via setsid --wait, suite shell neither leader nor its child);
# only the interpreter dir differs: the old PATH entry (scratchpad/pr31/venv312) no longer exists, so p4_proxy/venv/bin of the main checkout (python 3.13, has networkx) is used.
c="$1"; f="$2"; cd "$c" || exit 2
exec setsid --wait env -i PATH=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin:/usr/bin:/bin HOME=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/fakehome LANG=C.UTF-8 CI=true GITHUB_ACTIONS=true GITHUB_WORKSPACE="$c" RUNNER_TEMP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6f189e52-cb92-4f95-9cbe-05c8b1405742/scratchpad/fakehome/_temp USER=runner NDT_HB_CHECK_BMV2=/nonexistent/simple_switch PY_PLOT=/nonexistent/python \
  bash -c 'bash -c "bash $1; exit \$?" _ "$1"; exit $?' _ "$f"
