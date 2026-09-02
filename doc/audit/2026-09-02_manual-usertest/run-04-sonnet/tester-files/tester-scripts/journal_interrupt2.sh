#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Tooling note: a second stop in my own harness, not the project   caught again ~16:52-16:53
what happened: same mistake as the 15:51 note, repeated -- I treated a locally-launched
polling loop as something that would page me when the VM-side `p4-guide` build finished, and
ended my turn to "wait" for it. It does not work that way here: every one of those processes
is on the far side of an `ssh` call that already returned, and nothing pushes a notification
back for it. Corrected (again, this time for good): from here on, never end a turn while
`grep -c SCRIPT_EXIT ~/log.txt` is 0 -- interleave real checklist work with periodic checks
of that file instead of stopping. Recorded here only so two stalls in my own process do not
read as the P4 build hanging -- it was not; `~/log.txt` was growing the whole time.
EOF
echo APPENDED
