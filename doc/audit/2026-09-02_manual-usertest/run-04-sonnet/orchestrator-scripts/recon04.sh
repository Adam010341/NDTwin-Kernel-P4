# run-04 (sonnet) recon: read-only inventory before harvest. Writes nothing on guest.
# [Co-developed with claude code -- Adam]
set -u; cd ~
echo "=== when ==="; date -u +%FT%TZ; date +%F' '%T' '%Z; uptime
echo "=== tmux ls ==="; tmux ls 2>&1
echo "=== home *.md ==="; ls -l --time-style=+%m-%d_%H:%M:%S ~/*.md 2>&1
echo "=== home top ==="; ls -la --time-style=+%m-%d_%H:%M:%S ~ 2>&1
echo "=== logs count ==="; ls ~/logs 2>/dev/null | wc -l
echo "=== logs ==="; ls -la --time-style=+%m-%d_%H:%M:%S ~/logs 2>&1
echo "=== log.txt ==="; ls -l ~/log.txt 2>&1
echo "=== du of candidates ==="; du -sh ~/logs ~/log.txt ~/install-details 2>&1
echo "=== listeners ==="; ss -tlnpH 2>&1; echo "--- udp ---"; ss -ulnpH 2>&1
echo "=== df ==="; df -h /
