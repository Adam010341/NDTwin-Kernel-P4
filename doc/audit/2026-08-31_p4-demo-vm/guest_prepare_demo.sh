#!/bin/bash
# Turn the verified §1-§6.7 clean-room state into a distributable demo image.
#
# Runs INSIDE the guest. Two jobs: match the login table the website already publishes for the
# existing demo VM, and remove the parts that are build scaffolding rather than product.
#
# WHAT IS DELIBERATELY NOT DONE HERE
#   - The install is NOT moved out of /home/tester. p4_proxy/venv has absolute interpreter
#     paths baked into 11 of its console scripts and conda lives at /home/tester/miniconda3,
#     so relocating the tree breaks it. The ndtwin account is therefore an ADDITIONAL login,
#     not a new home for the install, and it says so on sight (README + MOTD) rather than
#     leaving the reader to discover an empty home.
#   - SSH host keys are left alone. Removing them is the usual hardening for a distributed
#     image, but nothing in this image regenerates them (cloud-init is disabled), so sshd
#     would fail to start and the shipped VM would have no SSH at all. A hardening change
#     that breaks the product is not hardening. Recorded as a known property instead.
#   - authorized_keys and shell history are NOT removed here. They are removed in the final
#     step, after verification, because removing the key ends my own access.
#
# The source trees below are removed only because the installed binaries do not depend on
# them: the fast build carries RUNPATH=/usr/local/bmv2-fast/lib and the stock one resolves
# through ldconfig, both installed prefixes. That is a claim about this image, so the
# acceptance test is re-run after this script -- deletion is not assumed to be harmless.
# [Co-developed with claude code -- Adam]
set -u
say() { echo; echo "### $* ###"; }
before=$(df --output=used -BM / | tail -1 | tr -dc 0-9)

say "1. ndtwin account, matching the login table the website already publishes"
if id ndtwin >/dev/null 2>&1; then
    echo "  ndtwin already exists"
else
    sudo useradd -m -s /bin/bash -c "NDTwin demo user" ndtwin
    sudo usermod -aG sudo ndtwin
    echo "  created ndtwin, added to sudo"
fi
echo "ndtwin:ndtwin" | sudo chpasswd
echo "root:ndtwin"   | sudo chpasswd
echo "  passwords set for ndtwin and root"
echo "  ndtwin: $(sudo passwd -S ndtwin)"
echo "  root:   $(sudo passwd -S root)"

say "2. tell whoever logs in as ndtwin where the system actually is"
sudo tee /home/ndtwin/README >/dev/null <<'EOF'
NDTwin P4/BMv2 demo VM
======================

The NDTwin installation lives under the `tester` account, not this one:

    /home/tester/Desktop/NDTwin-Kernel

It has to stay there. The proxy's Python virtual environment and the conda
environment that holds Ryu both contain absolute paths to /home/tester, so
copying or moving the tree breaks it.

To drive the system, switch to that account:

    sudo -iu tester

Accounts on this image:

    tester / tester     owns the installation -- use this one
    ndtwin / ndtwin     this account, sudo-capable
    root   / ndtwin

Change these passwords with `passwd` before putting this VM on a network.
EOF
sudo chown ndtwin:ndtwin /home/ndtwin/README
sudo tee /etc/motd >/dev/null <<'EOF'

  NDTwin P4/BMv2 demo VM
  The installation lives under the `tester` account: /home/tester/Desktop/NDTwin-Kernel
  Log in as tester (password: tester), or from here: sudo -iu tester
  Default passwords are published in the manual -- change them with `passwd`.

EOF
echo "  README and MOTD written"

say "3. remove the harness -- these are our test drivers, not part of the product"
cd "$HOME" || exit 1
for f in guest_nsr_journey.sh guest_ntg_journey.sh guest_section6_7.sh guest_section6_p1.sh \
         guest_section6_p2.sh guest_sections_1_5.sh guest_t2_investigate.sh guest_t2_run.sh \
         guest_t7_p1_switchstate.sh kernel.log t2i.log topo2.log proxy2.log t2i.done; do
    [ -e "$f" ] && { rm -rf "$f"; echo "  removed $f"; }
done
rm -rf "$HOME/install-details" && echo "  removed install-details/"

say "4. remove build source trees (binaries are installed; these are scaffolding)"
for d in bmv2-fast-src PI behavioral-model; do
    [ -d "$HOME/$d" ] && { sudo rm -rf "${HOME:?}/$d"; echo "  removed $d/"; }
done

say "5. caches"
sudo apt-get clean
rm -rf "$HOME/.cache"/* "$HOME/.wget-hsts" 2>/dev/null
"$HOME"/miniconda3/bin/conda clean -afy >/dev/null 2>&1 && echo "  conda cache cleaned"
sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null
sudo journalctl --vacuum-time=1s >/dev/null 2>&1
sudo rm -f /var/log/*.gz /var/log/*.1 2>/dev/null
sudo truncate -s0 /var/log/syslog /var/log/kern.log /var/log/auth.log 2>/dev/null
echo "  apt, conda, tmp, journal and rotated logs cleared"

after=$(df --output=used -BM / | tail -1 | tr -dc 0-9)
say "DONE -- guest used ${before}M -> ${after}M (freed $(( before - after ))M)"
df -h / | tail -1
