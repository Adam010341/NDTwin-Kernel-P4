#!/usr/bin/env bash
# stray_timed.sh : tests/shell/check_no_stray_table_journal.sh under /usr/bin/time -v, with the load before and after.
# Run in a clone. [Co-developed with claude code -- Adam]
echo "nproc $(nproc)  loadavg before: $(cat /proc/loadavg)"
PROXY_PY="$PWD/p4_proxy/venv/bin/python" /usr/bin/time -v bash tests/shell/check_no_stray_table_journal.sh
rc=$?
echo "loadavg after: $(cat /proc/loadavg)"
exit $rc
