#!/usr/bin/env bash
# The subject sha line as the gate script prints it (header only, PYTHON=/bin/true stops it at the baseline), under both locales.
# [Co-developed with claude code -- Adam]
cd "$1" || exit 2
echo "commit $(git rev-parse HEAD)"
for loc in C en_US.UTF-8; do
  printf 'LC_ALL=%s: ' "$loc"
  env -u MUT_SHARD -u ONLY_LABEL_PREFIX LC_ALL=$loc PYTHON=/bin/true bash tests/shell/mutate_p4_health.sh 2>&1 | grep '^subject sha:'
done
echo "rc=0"
