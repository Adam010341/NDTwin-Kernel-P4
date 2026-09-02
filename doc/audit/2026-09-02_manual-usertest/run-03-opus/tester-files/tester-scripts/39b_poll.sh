#!/bin/bash
tmux capture-pane -t UP -p -S -400 | grep -v '^$' | tail -45
echo "---- ports ----"
ss -lntp 2>/dev/null | grep -E ':6633|:8080|:8000' || echo "(none)"
date +%H:%M:%S
