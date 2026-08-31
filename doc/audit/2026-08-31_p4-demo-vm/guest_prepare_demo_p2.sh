#!/bin/bash
# Second cleanup pass. There is a second pass because the first one was decided from a
# `ls -la ~ | head -30`, and the home directory has more than 30 entries -- the truncation
# hid ~3.2 GB of build scaffolding and every harness log. The listing was read as if it were
# the directory. Recorded here rather than quietly fixed, because the same shape (a truncated
# view standing in for the whole) is the one this project keeps paying for.
#
# WHY EACH REMOVAL IS SAFE -- measured on this image, not assumed:
#   mn            -> /usr/bin/mn, package at /usr/lib/python3/dist-packages/mininet (apt),
#                    NOT the ~/mininet source tree
#   p4c, p4c-bm2-ss, simple_switch, simple_switch_grpc -> /usr/local/bin/*
#   ovs-vsctl     -> /usr/bin/ovs-vsctl
#   and grep over ~/.bashrc, ~/.profile and /etc/profile.d found nothing that sources
#   p4setup.bash, p4dev-python-venv, or any of the source trees at login.
# So the trees below are what the installer left behind, not what the product runs on.
# p4setup.bash/csh go too: once the trees are gone they would only point at absent paths,
# and a script that names things that do not exist is worse than no script.
#
# The acceptance test is re-run after this. Deletion is not assumed harmless -- that rule is
# why the first pass was checked, and the check is what makes the claim worth anything.
# [Co-developed with claude code -- Adam]
set -u
before=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
cd "$HOME" || exit 1

echo "### build scaffolding left by install-p4dev-v8.sh ###"
for d in p4c p4-guide p4dev-python-venv tutorials mininet ptf p4runtime-shell; do
    [ -e "$d" ] && { sudo rm -rf "${HOME:?}/$d"; echo "  removed $d/"; }
done
for f in p4setup.bash p4setup.csh; do
    [ -e "$f" ] && { rm -f "$f"; echo "  removed $f"; }
done

echo
echo "### our harness output ###"
for d in ntg-results nsr-results s6.7-results snippets staged; do
    [ -e "$d" ] && { rm -rf "${HOME:?}/$d"; echo "  removed $d/"; }
done
n=0
for f in *.log *.console; do [ -e "$f" ] && { rm -f "$f"; n=$((n+1)); }; done
echo "  removed $n log/console files"

echo
echo "### caches again (conda/pip may have refilled) ###"
rm -rf "$HOME/.cache"/* "$HOME/.cmake" "$HOME/.anaconda" "$HOME/.wireshark" 2>/dev/null
sudo apt-get clean
sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null

after=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
echo
echo "### guest used ${before}M -> ${after}M (freed $(( before - after ))M) ###"
echo "### home as it will now ship: ###"
ls -A "$HOME" | tr '\n' ' '; echo
df -h / | tail -1
