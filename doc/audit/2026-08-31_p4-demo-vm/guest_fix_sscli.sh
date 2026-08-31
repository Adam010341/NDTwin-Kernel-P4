#!/bin/bash
# Make simple_switch_CLI work in the shipped image.
#
# WHY THIS IS NEEDED: removing ~/p4dev-python-venv (build scaffolding, 111 MB) took away
# whatever used to put the BMv2 Thrift bindings on the interpreter path. The wrapper
# /usr/local/bin/simple_switch_CLI survived, so the image was left with the tool PRESENT and
# BROKEN -- the worst of the three states, because it looks installed.
#
# The bindings themselves were never deleted: `make install` of the §6.7 fast build put them
# in /usr/local/bmv2-fast/lib/python3.12/site-packages (sswitch_CLI.py, bm_runtime/), which
# is an installed prefix, not a source tree. Only `thrift` was missing from the system
# interpreter -- it exists solely inside p4_proxy/venv.
#
# So the fix is a path entry plus thrift, and the result is BETTER than the state this image
# started in: the CLI now works from a plain login, instead of depending on a 111 MB venv and
# a p4setup.bash that had to be sourced first.
#
# Verified afterwards against a LIVE switch, not by importing the module: an import proves the
# path, and the thing being claimed is that the tool can dump a table.
# [Co-developed with claude code -- Adam]
set -u
BMV2_SP=/usr/local/bmv2-fast/lib/python3.12/site-packages
DIST=/usr/local/lib/python3.12/dist-packages

echo "### 1. put the BMv2 Thrift bindings on the system interpreter path ###"
if [ ! -d "$BMV2_SP" ]; then echo "  ABORT: $BMV2_SP is missing"; exit 1; fi
echo "$BMV2_SP" | sudo tee "$DIST/bmv2-thrift-bindings.pth" >/dev/null
echo "  wrote $DIST/bmv2-thrift-bindings.pth -> $BMV2_SP"

echo
echo "### 2. thrift for the system interpreter ###"
if python3 -c 'import thrift' 2>/dev/null; then
    echo "  already present"
elif sudo apt-get install -y python3-thrift >/dev/null 2>&1 && python3 -c 'import thrift' 2>/dev/null; then
    echo "  installed python3-thrift from apt"
else
    # Ubuntu 24.04 marks the system interpreter externally-managed (PEP 668), which is the
    # same trap the manual hits in four places. Copying the package the proxy venv already
    # carries avoids both a network dependency and --break-system-packages.
    SRC=$(ls -d "$HOME"/Desktop/NDTwin-Kernel/p4_proxy/venv/lib/python3*/site-packages/thrift 2>/dev/null | head -1)
    if [ -n "$SRC" ]; then
        sudo cp -r "$SRC" "$DIST/"
        echo "  copied thrift from the proxy venv ($SRC)"
    else
        echo "  ABORT: no thrift available to install"; exit 1
    fi
fi
python3 -c 'import thrift, sswitch_CLI, bm_runtime; print("  imports OK: thrift + sswitch_CLI + bm_runtime")'
sudo python3 -c 'import thrift, sswitch_CLI, bm_runtime; print("  imports OK under sudo too (this is how it is invoked)")'

echo
echo "### 3. verify against a LIVE switch, not by importing ###"
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
sudo mn -c >/dev/null 2>&1
sudo rm -f /tmp/ndtwin_p4_switches.json
FIFO=/tmp/mnfix; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 p4_proxy/mininet/p4_testbed_topo.py < "$FIFO" > ~/fixtopo.log 2>&1 &
TOPO=$!
exec 3> "$FIFO"
for i in $(seq 1 90); do grep -q "switches verified listening" ~/fixtopo.log && break; sleep 2; done
if ! grep -q "switches verified listening" ~/fixtopo.log; then
    echo "  fabric did not come up; last lines:"; tail -5 ~/fixtopo.log
else
    echo "  fabric up; dumping a table through simple_switch_CLI:"
    sudo timeout 25 simple_switch_CLI --thrift-port 9091 <<< "table_dump ipv4_lpm" 2>&1 \
        | grep -cE '^Dumping|entry' | sed 's/^/    matching lines: /'
    sudo timeout 25 simple_switch_CLI --thrift-port 9091 <<< "show_tables" 2>&1 \
        | grep -iE 'ipv4_lpm|flow_5tuple' | head -3 | sed 's/^/    /'
fi
echo "exit" >&3; sleep 6; exec 3>&-
sudo kill $TOPO 2>/dev/null; sleep 3
sudo mn -c >/dev/null 2>&1
rm -f ~/fixtopo.log "$FIFO"
echo "  fabric torn down"
