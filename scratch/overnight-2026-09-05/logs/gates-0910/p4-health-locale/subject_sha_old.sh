#!/usr/bin/env bash
# The subject sha line of mutate_p4_health.sh as it is at c24a7d19 (:86), under two locales. Read-only.
# [Co-developed with claude code -- Adam]
cd "$1" || exit 2
echo "commit $(git rev-parse HEAD)"
echo "old line: find . -name '*.py' -o -name '*.sh' | sort | xargs sha256sum | sha256sum | cut -c1-16"
for loc in C en_US.UTF-8; do
  printf 'LC_ALL=%s: ' "$loc"
  (cd tools/p4_health && export LC_ALL=$loc && find . -name '*.py' -o -name '*.sh' | sort | xargs sha256sum | sha256sum | cut -c1-16)
done
echo "--- first lines where the two orders differ (diff of the sorted lists)"
(cd tools/p4_health && diff <(find . -name '*.py' -o -name '*.sh' | LC_ALL=C sort) <(find . -name '*.py' -o -name '*.sh' | LC_ALL=en_US.UTF-8 sort) | head -12)
echo "rc=0"
