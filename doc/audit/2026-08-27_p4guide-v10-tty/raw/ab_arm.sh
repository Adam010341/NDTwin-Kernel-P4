#!/bin/bash
# Run ONE arm of the tty/no-tty A/B on install-p4dev-v10.sh.   usage: ab_arm.sh notty|tty
#
# Both arms: restore the shared 'ab-base' snapshot, run the SAME pinned script, log to $HOME
# (never /tmp -- `D /tmp` in tmpfiles.d empties it at every boot), mirror the log to the host
# while it runs, and decide on PRODUCTS.
#
# The single variable is whether the installer has a CONTROLLING TERMINAL:
#   notty : setsid nohup bash -c '... < /dev/null'   <- reproduces the 23:00 launch exactly
#   tty   : tmux new-session -d                      <- allocates a pty, so /dev/tty opens
# tmux rather than `ssh -tt` on purpose: ssh -tt would also couple the arm's survival to my
# connection staying up for hours, which is a second difference, not one. Both arms are
# detached from this shell; only the controlling terminal differs.
#
# EVERY arm asserts its own injection worked. Without that I could run a "TTY arm" that has
# no tty and never know -- and the whole experiment would silently become one arm run twice.
# The assertion is `exec 3</dev/tty`, because an openable /dev/tty is precisely what debconf
# reported missing ("This frontend requires a controlling tty").
# [Co-developed with claude code -- Adam]
set -u

ARM="${1:?usage: ab_arm.sh notty|tty}"
case "$ARM" in notty|tty) ;; *) echo "arm must be notty or tty"; exit 2 ;; esac

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:-install-p4dev-v10.sh}"
LABEL="${LABEL:-$ARM}"
OUT="$DIR/ab-results/$LABEL"
MAXMIN="${MAXMIN:-360}"          # 6 h ceiling; expiry means "I stopped waiting", not "it failed"
SSH="ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30 tester@localhost"
SCP="scp -q -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
mkdir -p "$OUT"
STATUS="$OUT/STATUS.txt"

say() { echo; echo "=== $* ==="; }
{ echo "state: STARTING"; echo "arm: $ARM"; echo "started: $(date -Is)"; } > "$STATUS"

say "restore ab-base and boot  [arm=$ARM]"
bash "$DIR/vm.sh" stop
bash "$DIR/vm.sh" restore ab-base || { echo "ABORT: restore failed"; exit 1; }
bash "$DIR/vm.sh" start          || { echo "ABORT: start failed";   exit 1; }
bash "$DIR/wait_ssh.sh"          || { echo "ABORT: no ssh";         exit 1; }

say "re-assert the base is clean (a restore that silently no-ops would ruin the arm)"
d=$($SSH 'n=0; for p in ~/behavioral-model ~/p4c ~/PI /usr/local/bin/p4c-bm2-ss /usr/local/bin/simple_switch; do
          if [ -e "$p" ]; then echo "DIRTY: $p"; n=$((n+1)); fi; done; echo "DIRTY_COUNT=$n"')
echo "$d"
if [ "$(printf '%s\n' "$d" | sed -n 's/^DIRTY_COUNT=//p')" != "0" ]; then
    echo "ABORT: ab-base did not restore clean"; echo "state: ABORTED_DIRTY_BASE" >> "$STATUS"; exit 1
fi
$SSH 'echo "pinned script sha256: $(sha256sum ~/p4-guide/bin/'"$SCRIPT"' | cut -d" " -f1)"
      echo "p4-guide HEAD:        $(git -C ~/p4-guide rev-parse HEAD)"' | tee "$OUT/base-identity.txt"

say "deploy the arm body into the VM"
$SSH 'cat > ~/arm_body.sh' <<'BODY'
#!/bin/bash
# Runs INSIDE the VM. Self-check first, then the installer, then a product verdict.
set -u
LOG=~/arm.log
{
  echo "=== ARM SELF-CHECK (proves which arm this actually is) ==="
  echo "date:            $(date -Is)"
  echo "pid/ppid:        $$ / $PPID"
  if (exec 3</dev/tty) 2>/dev/null; then echo "controlling_tty: YES  <- /dev/tty opened"
  else                                   echo "controlling_tty: NO   <- /dev/tty could not be opened"; fi
  if [ -t 0 ]; then echo "stdin_is_tty:    YES"; else echo "stdin_is_tty:    NO"; fi
  echo "tty(1):          $(tty 2>&1)"
  echo "ps tty column:   '$(ps -o tty= -p $$ 2>/dev/null)'"
  echo "sid:             $(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')"
  echo "=== END SELF-CHECK ==="
  echo
} > "$LOG" 2>&1
./p4-guide/bin/__SCRIPT__ >> "$LOG" 2>&1
echo $? > ~/arm.rc
BODY
$SSH "sed -i 's|__SCRIPT__|$SCRIPT|' ~/arm_body.sh
      chmod +x ~/arm_body.sh; rm -f ~/arm.log ~/arm.rc
      echo -n 'body deployed, installer line: '; grep -m1 'p4-guide/bin' ~/arm_body.sh" 

say "launch arm '$ARM'"
if [ "$ARM" = "notty" ]; then
    # Exactly the 23:00 launch: no stdin, new session, no controlling terminal.
    $SSH 'cd ~ && setsid nohup bash -c "~/arm_body.sh" < /dev/null > /dev/null 2>&1 & sleep 5; echo launched'
else
    # tmux allocates a pty and makes it the session's controlling terminal.
    $SSH 'cd ~ && tmux new-session -d -s arm "~/arm_body.sh"; sleep 5; tmux ls; echo launched'
fi

say "VERIFY THE INJECTION -- what the arm reports about itself"
sleep 10
$SSH 'sed -n "1,12p" ~/arm.log' | tee "$OUT/self-check.txt"
ctty=$(sed -n 's/^controlling_tty: *\([A-Z]*\).*/\1/p' "$OUT/self-check.txt" | head -1)
echo "--> controlling_tty reported: '${ctty:-<none>}'"
if [ "$ARM" = "tty" ]; then want=YES; else want=NO; fi
if [ "${ctty:-}" != "$want" ]; then
    echo "ABORT: arm '$ARM' wanted controlling_tty=$want but got '${ctty:-<none>}'."
    echo "       Running it anyway would silently make this the OTHER arm."
    { echo "state: ABORTED_WRONG_ARM"; echo "wanted: $want"; echo "got: ${ctty:-none}"; } >> "$STATUS"
    exit 1
fi
echo "injection asserted: arm '$ARM' really has controlling_tty=$want"
{ echo "state: RUNNING"; echo "controlling_tty: $ctty"; } >> "$STATUS"

say "wait (poll every 5 min, mirror the log out each time)"
rc=""
for i in $(seq 1 $((MAXMIN/5))); do
    sleep 300
    rc=$($SSH 'cat ~/arm.rc 2>/dev/null' 2>/dev/null)
    $SCP tester@localhost:'~/arm.log' "$OUT/install.log" 2>/dev/null
    sz=$(stat -c %s "$OUT/install.log" 2>/dev/null || echo 0)
    echo "  [$((i*5)) min] log ${sz} bytes${rc:+  rc=$rc}"
    [ -n "$rc" ] && break
done

say "evidence out FIRST, verdict second"
$SCP tester@localhost:'~/arm.log' "$OUT/install.log" 2>/dev/null; echo "log: $OUT/install.log ($(stat -c %s "$OUT/install.log" 2>/dev/null || echo 0) bytes)"

say "VERDICT -- products, on disk and on PATH, never the exit status"
$SSH 'bash -s' <<'V' | tee "$OUT/verdict.txt"
for c in simple_switch_grpc simple_switch p4c-bm2-ss; do
    p=$(command -v "$c" 2>/dev/null)
    if [ -n "$p" ]; then echo "$c: PRESENT  $p"; else echo "$c: MISSING"; fi
done
echo "--- /usr/local/bin ---"; ls /usr/local/bin 2>/dev/null | tr '\n' ' '; echo
echo "--- disk ---"; df -h / | awk 'NR==2{print $4" free"}'
V

say "WHY it is absent -- PREREG confounder #5"
# A missing binary is BOTH a legitimate result and the signature of a resource shortage, and
# the product verdict cannot tell those apart. So never record a bare MISSING: record the last
# build error alongside it, plus the host's memory state, so a later reader can decide whether
# this arm is a result or is void.
{
  echo "arm finished at: $(date -Is)"
  echo "--- host memory/swap at finish (asymmetric neighbour load shows up here) ---"
  free -m | sed -n '1,3p'
  echo "--- last 12 lines of the build log ---"
  tail -12 "$OUT/install.log" 2>/dev/null
  echo "--- last error-shaped lines ---"
  grep -nEi 'FAILED|\bfatal\b|Aborted|No such file|command not found|cannot|Killed' "$OUT/install.log" 2>/dev/null | tail -8
} > "$OUT/why-absent.txt" 2>&1
cat "$OUT/why-absent.txt"

say "mechanism markers (the debconf lines the tty hypothesis predicts)"
{
  echo -n "controlling tty complaints: "; grep -ciE 'requires a controlling tty|unable to re-open stdin|Dialog frontend will not work' "$OUT/install.log"
  echo -n "network failures:           "; grep -ciE 'Connection broken|IncompleteRead|Could not resolve|Network is unreachable' "$OUT/install.log"
  echo -n "skip-because-present:       "; grep -ciE 'Assuming desired version of .* is already installed' "$OUT/install.log"
} | tee "$OUT/markers.txt"

ssg=$(sed -n 's/^simple_switch_grpc: \([A-Z]*\).*/\1/p' "$OUT/verdict.txt")
p4c=$(sed -n 's/^p4c-bm2-ss: \([A-Z]*\).*/\1/p' "$OUT/verdict.txt")
{
  if [ -n "$rc" ]; then echo "state: FINISHED"; else echo "state: NO_VERDICT  # I stopped waiting at ${MAXMIN}m; says nothing about the installer"; fi
  echo "arm: $ARM"
  echo "controlling_tty: $ctty"
  echo "installer_rc: ${rc:-<no sentinel>}   # informational only"
  echo "simple_switch_grpc: ${ssg:-UNKNOWN}"
  echo "p4c-bm2-ss:         ${p4c:-UNKNOWN}"
  if [ "$ssg" = "PRESENT" ] && [ "$p4c" = "PRESENT" ]; then echo "ARM_RESULT: SUCCESS"; else echo "ARM_RESULT: FAILURE"; fi
  echo "finished: $(date -Is)"
} > "$STATUS"
cat "$STATUS"
