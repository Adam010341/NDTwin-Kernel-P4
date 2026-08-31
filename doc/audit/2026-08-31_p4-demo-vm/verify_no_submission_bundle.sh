#!/bin/bash
# Does the shipped .ova contain the EuroP4 poster submission package?
#
# Asked by the auditor before this image goes to Google Drive. The repo's working tree
# hides that package via .git/info/exclude, so `git status` looks clean while 85 objects
# matching it sit in the local repo's history -- "tree clean" is not "history clean".
#
# Method, and why it is this method:
#   - Inspect the ARTEFACT, not its provenance. "I remember it was cloned from a bundle"
#     is the kind of claim this project has been burned by. The bundle check (clean, tip
#     2026-08-27, predates the 08-29 poster work) says what the INTENDED channel carried;
#     it cannot rule out a second channel.
#   - The disk is the vmdk extracted from the .ova itself, not ndtwin-p4-demo-work.qcow2.
#     The work image was written at 13:15, AFTER the .ova was packaged at 12:40, so it is
#     not the shipped bytes.
#   - A qcow2 overlay, so the extracted vmdk stays byte-identical to the .ova payload and
#     this check cannot be accused of having modified what it inspected.
#   - Search the WHOLE filesystem, not just the repo: a stray copy under /tmp, /root or a
#     tarball in a home directory ships just as publicly as one inside the source tree.
#
# A zero result here is only worth as much as the search's discriminating power, so the
# script proves it can find something first: it greps for a control string that is known
# to be present. If the control comes back empty, the search is broken and every other
# zero in this report is meaningless.
#
# [Co-developed with claude code -- Adam]
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
VMDK="$DIR/NDTwin-P4-demo-disk1.vmdk"
OVERLAY="$DIR/verify-overlay.qcow2"
PORT=2224
PW=tester
ASKPASS="$DIR/.verify-askpass"

KEYS='europ4|EuroP4|poster-abstract|poster-review|poster-package|poster_package'

cleanup() { rm -f "$ASKPASS"; }
trap cleanup EXIT

printf '#!/bin/sh\necho %s\n' "$PW" > "$ASKPASS"; chmod 700 "$ASKPASS"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0

SSH="ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no \
     -o ConnectTimeout=10 tester@127.0.0.1"

case "${1:-run}" in
  start)
    [ -f "$VMDK" ] || { echo "ABORT: $VMDK missing"; exit 1; }
    rm -f "$OVERLAY"
    qemu-img create -q -f qcow2 -b "$VMDK" -F vmdk "$OVERLAY" || exit 1
    echo "overlay created; backing file stays read-only:"
    qemu-img info -U "$OVERLAY" | sed -n '1,6p'
    # via bash, not the exec bit: this copy lives on an NTFS mount and p4demo.sh is 0664
    # there. chmod would work but would edit a file the audit directory also tracks.
    P4DEMO_IMG="$OVERLAY" P4DEMO_SSH_PORT=$PORT P4DEMO_MAX_SECONDS=3600 \
      bash "$DIR/p4demo.sh" start
    ;;

  wait)
    for i in $(seq 1 90); do
      if $SSH 'echo up' 2>/dev/null | grep -q up; then echo "SSH UP after ${i}0s"; exit 0; fi
      sleep 10
    done
    echo "SSH DID NOT COME UP"; exit 1
    ;;

  scan)
    $SSH 'bash -s' <<'GUEST'
set -u
KEYS='europ4|EuroP4|poster-abstract|poster-review|poster-package|poster_package'

echo "=== 0. CONTROL: prove the search can find something ==="
echo "    (looking for a string known to be in this image)"
sudo find / -xdev -iname '*NDTwin-Kernel*' -maxdepth 4 2>/dev/null | head -3
echo "    control hits above must be non-empty, or every zero below is meaningless"

echo
echo "=== 1. filesystem: any path matching the submission keywords ==="
sudo find / -xdev 2>/dev/null | grep -iE "$KEYS" | head -40
echo "--- count ---"
sudo find / -xdev 2>/dev/null | grep -icE "$KEYS"

echo
echo "=== 2. where is the source tree, and is it a git repo ==="
for d in /home/tester/Desktop/NDTwin-Kernel /home/tester/NDTwin-Kernel-P4 /home/ndtwin; do
  [ -e "$d" ] && echo "exists: $d  (.git: $([ -d "$d/.git" ] && echo yes || echo no))"
done

echo
echo "=== 3. git history of every repo on the disk ==="
for g in $(sudo find / -xdev -name '.git' -maxdepth 6 2>/dev/null); do
  r=$(dirname "$g")
  echo "--- repo: $r"
  sudo git -C "$r" rev-list --objects --all 2>/dev/null | grep -icE "$KEYS" \
    | sed 's/^/    submission-keyword objects: /'
  sudo git -C "$r" log -1 --format='    tip: %H %ci' --all 2>/dev/null | head -1
  sudo git -C "$r" show-ref 2>/dev/null | sed 's/^/    ref: /' | head -5
done

echo
echo "=== 4. archives that could hide it (grep cannot see inside a tarball) ==="
sudo find / -xdev \( -name '*.tar*' -o -name '*.zip' -o -name '*.bundle' -o -name '*.pdf' \) \
     -size +100k 2>/dev/null | head -20

echo
echo "=== 5. content grep in the likely homes (paths can be renamed, content is harder) ==="
sudo grep -rilE "$KEYS" /home /root /tmp /var/tmp 2>/dev/null | head -20
echo "--- count ---"
sudo grep -rilE "$KEYS" /home /root /tmp /var/tmp 2>/dev/null | wc -l
GUEST
    ;;

  stop)
    P4DEMO_IMG="$OVERLAY" P4DEMO_SSH_PORT=$PORT bash "$DIR/p4demo.sh" stop
    ;;
esac
