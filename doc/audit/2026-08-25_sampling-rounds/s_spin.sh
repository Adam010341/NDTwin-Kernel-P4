#!/usr/bin/env bash
# One CPU burner for the ticket S poller self-proof.  [Co-developed with claude code -- Adam]
#
# In a file, not an inline `bash -c`, for the reason that bit twice today: an inline loop carries
# its own pgrep pattern in its argv, so a `pgrep -f "<pattern>"` written to test whether something
# ELSE is alive matches the tester itself and never terminates.  A path in argv cannot do that.
#
# Killed by explicit PID from s_p95.sh, never by pkill -f.
while :; do :; done
