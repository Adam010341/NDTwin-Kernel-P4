# run-04 pull: guest tarball -> nslab -> here. Run on the LOCAL machine.
# [Co-developed with claude code -- Adam]
set -eu
DEST=/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-02_manual-usertest/run-04-sonnet/tester-files
mkdir -p "$DEST"
ssh -o BatchMode=yes -o ConnectTimeout=20 nslab \
  'O="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"; scp $O -P 2314 ndt@127.0.0.1:/tmp/run04-guest.tgz /tmp/run04-guest.tgz >/dev/null; sha256sum /tmp/run04-guest.tgz >&2; cat /tmp/run04-guest.tgz' \
  < /dev/null > /tmp/claude-run04-guest.tgz
sha256sum /tmp/claude-run04-guest.tgz
tar xzf /tmp/claude-run04-guest.tgz -C "$DEST"
find "$DEST" -type f | wc -l
