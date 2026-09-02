#!/bin/bash
set -x
mkdir -p ~/logs
cat > ~/JOURNAL.md << 'EOF'
# NDTwin install/use journal — run-04 (tester model: sonnet)

Tester persona: grad student, fresh Ubuntu 24.04 VM, first time seeing NDTwin.
Docs snapshot: website commit 2612b0a. Started 2026-09-02.

EOF
cat > ~/BUGS.md << 'EOF'
# BUGS.md — run-04

Format per entry: feature · manual page/section · exact steps · expected (quoted) ·
observed (verbatim, trimmed) · reproduced on 2nd try? · severity guess.

EOF
cat > ~/CHECKLIST.md << 'EOF'
# CHECKLIST.md — run-04

Populated from User Manual pages once install is complete. One line per
feature/command/API/tool/procedure. Outcome: WORKS / WORKS-BUT / BROKEN / NOT-TRIED (why).

EOF
echo "INIT DONE"
date +%H:%M
