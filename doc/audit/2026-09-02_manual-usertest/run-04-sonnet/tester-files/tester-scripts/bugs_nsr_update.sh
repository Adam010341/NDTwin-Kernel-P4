#!/bin/bash
cat >> ~/BUGS.md << 'INNEREOF'

## Update to BUG-4: the `pgrep -f` anti-pattern in `stop_network_state_recorder.sh` actually reproduced, live
Earlier I only inspected this script's source and called out that it uses the exact pattern
the User Manual's own NSR page tells you not to use. I then ran it for real, to stop the NSR
instance started under the documented workaround (`source ~/nsr-env/bin/activate` first):
```
$ pgrep -af network_state_recorder.py
184273 python3 network_state_recorder.py
$ ./stop_network_state_recorder.sh
184273 190740
```
`190740` was **not NSR** -- it was the PID of the very shell that was running my *previous*
command, whose command-line text happened to contain the literal string
`network_state_recorder.py` (because it had `pgrep -af network_state_recorder.py` in its own
`-c` argument). `pgrep -f` doesn't distinguish "the program I mean" from "any process whose
command line mentions the same string," which is precisely what the manual's prose warns
about two sections earlier -- and the shipped script's `sudo kill -15
$(pgrep -f network_state_recorder.py)` signalled both PIDs it found. That earlier command's
own SSH connection terminated immediately (exit code 255) as a direct result. NSR itself
(184273) did also stop -- the script's primary job still happened -- but it took an unrelated
process down as collateral damage, from a completely ordinary way of invoking it (a scripted
shell rather than someone's raw interactive terminal).
This was not a contrived test: it is what "run the stop script" looks like from anything
other than a bare interactive terminal -- a cron job, a CI step, or (as here) any wrapper
shell whose own invocation happens to mention the target script's name.
**Reproduced:** yes, on the one deliberate run -- did not repeat it a second time given what
the first run had just done to my own session; the mechanism (unfiltered `pgrep -f` catching
whatever is running it) is deterministic, not a fluke.
**Revised severity:** Medium, up from the "not yet reproduced" note earlier in this file --
this is no longer a theoretical reading of the source, it is an observed side effect that
reached outside the process NSR itself started.
INNEREOF
echo APPENDED
