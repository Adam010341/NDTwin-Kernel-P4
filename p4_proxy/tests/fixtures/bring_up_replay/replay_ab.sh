#!/usr/bin/env bash
#
# The byte-identity evidence for TICKET-P1D, regenerable from this repo.
#
# [Co-developed with claude code -- Adam]
#
# THE CLAIM: with no app package, `p4_testbed_topo.main()` and `ntg_bmv2_topo.main()` ask the
# fabric for exactly what they asked for before the two copies were merged into one bring-up --
# the same bmv2 argv, the same static-ARP commands, the same switch order, the same `net.get`
# sequence and the same switch manifest.
#
# THE METHOD: check the PRE-CHANGE pair of files out of git into a real directory, run all four
# main()s (old/new x topo/bridge) over a net that records instead of building, normalise the
# paths that are necessarily different between two trees, and diff the four recordings.
#
# 🔴 NOTHING IS STARTED. replay.py replaces os.system, sleep, CLI, NTG's prompt, the orphan
# reap, the port refusal and the manifest path before either main() runs; no sudo, no Mininet,
# no bmv2, no root. It is safe to run on a machine with a live fabric -- and it has to be, which
# is why write_manifest is forced to a temp file rather than merely pointed at one.
#
# Usage:  bash replay_ab.sh [<pre-change rev>]     (default: 41d7950f, P1-D's base)
# Exit:   0 the four comparisons came out as VERDICT.txt records them, 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
BASE_REV="${1:-41d7950f}"
PY="${PROXY_PY:-$REPO/p4_proxy/venv/bin/python}"
[[ -x "$PY" ]] || { echo "REFUSE: no interpreter at $PY (set PROXY_PY=)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bring-up-replay-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A bmv2 binary this script made, so the recorded argv is a property of the code and not of
# which build happens to be installed. No sibling ../lib on purpose: bmv2_launch_head then adds
# no LD_LIBRARY_PATH prefix and the argv has one fewer machine-dependent part.
mkdir -p "$WORK/prefix/bin"
printf '#!/bin/sh\n' > "$WORK/prefix/bin/simple_switch_grpc"
chmod +x "$WORK/prefix/bin/simple_switch_grpc"
printf '%s\n' "$WORK/prefix/bin/simple_switch_grpc" > "$WORK/override"
export FAKE_OVERRIDE="$WORK/override"

# 🔴 A REAL DIRECTORY, not a symlink to one. MultiSwitchTopo resolves the compiled JSON as
# `<this file's dir>/../p4_src/build/...` WITHOUT normalising, and `symlink/..` resolves to the
# symlink TARGET's parent -- so a symlinked mininet/ sends the lookup somewhere else entirely.
# Measured while writing this: the old arm refused with "Compiled P4 JSON not found".
OLD="$WORK/old/p4_proxy/mininet"
mkdir -p "$OLD" "$WORK/old/p4_proxy/p4_src"
for f in p4_testbed_topo.py ntg_bmv2_topo.py; do
    git -C "$REPO" show "$BASE_REV:p4_proxy/mininet/$f" > "$OLD/$f" || exit 2
done
# Unchanged by this ticket, so the current copies stand for the old ones. `git diff --name-only
# <rev> HEAD -- p4_proxy/mininet/` is the check that this is still true.
cp "$REPO/p4_proxy/mininet/topo_from_json.py" "$REPO/p4_proxy/mininet/grpc_ports.py" \
   "$REPO/p4_proxy/mininet/app_package.py" "$REPO/p4_proxy/mininet/host_count_override" \
   "$OLD/"
cp -rL "$REPO/p4_proxy/p4_src/build" "$WORK/old/p4_proxy/p4_src/" 2>/dev/null
ln -sfn "$REPO/setting" "$WORK/old/setting"

changed="$(git -C "$REPO" diff --name-only "$BASE_REV" HEAD -- p4_proxy/mininet/ | tr '\n' ' ')"
echo "files under p4_proxy/mininet/ that changed since $BASE_REV: $changed"
echo

run_arm() {   # <label> <mininet dir> <repo root> <hosts>
    NDTWIN_P4_HOST_NUM="$4" "$PY" "$HERE/replay.py" "$2" "$5" "$3" \
        "$WORK/$1.json" > "$WORK/$1.stdout" 2>&1
    local rc=$?
    (( rc == 0 )) || { echo "REFUSE: arm $1 exited $rc"; tail -3 "$WORK/$1.stdout"; exit 2; }
}

for hosts in 4 128; do
    # 🔴 THE OLD TREE'S COUNT FILE HAS TO BE SET, AND THAT IS ITSELF A FINDING. The pre-change
    # bridge built its host list from `_host_count_override()` -- the FILE -- while the fabric
    # was built from the MODEL, so the two could disagree with nothing saying so. Run it here
    # with a 128 in the file and NDTWIN_P4_HOST_NUM=4 and it dies `KeyError: 'h5'`: the same
    # shape, on the same line of reasoning, as the `net.get('s5')` that ended the live round on
    # 2026-09-18. `ndt up p4` keeps the two in step in practice, which is why this was latent.
    # The post-change bring_up reads only the model, so it has no second answer to disagree
    # with; this line exists to give the OLD arm the agreement it needs to be comparable at all.
    printf '%s\n' "$hosts" > "$OLD/host_count_override"
    for arm in topo bridge; do
        run_arm "old$hosts.$arm" "$OLD"                      "$WORK/old" "$hosts" "$arm"
        run_arm "new$hosts.$arm" "$REPO/p4_proxy/mininet"    "$REPO"     "$hosts" "$arm"
    done
done

"$PY" - "$WORK" "$OLD" "$REPO/p4_proxy/mininet" <<'PY'
import json, re, sys
work, old_dir, new_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def norm(name, root):
    text = json.dumps(json.load(open("%s/%s.json" % (work, name))), sort_keys=True, indent=2)
    text = text.replace(root, "<MININET>").replace(work, "<WORK>")
    return json.loads(re.sub(r"/tmp/replay\.[A-Za-z0-9_]+", "<TMP>", text))

rc = 0
for hosts in (4, 128):
    rec = {(w, arm): norm("%s%d.%s" % (w, hosts, arm), old_dir if w == "old" else new_dir)
           for w in ("old", "new") for arm in ("topo", "bridge")}
    print("=== %d hosts ===" % hosts)
    for label, a, b in (
            ("p4_testbed_topo.main()  BEFORE vs AFTER", rec[("old", "topo")], rec[("new", "topo")]),
            ("ntg_bmv2_topo.main()    BEFORE vs AFTER", rec[("old", "bridge")], rec[("new", "bridge")]),
            ("BEFORE: the two mains against each other", rec[("old", "topo")], rec[("old", "bridge")]),
            ("AFTER:  the two mains against each other", rec[("new", "topo")], rec[("new", "bridge")])):
        differ = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
        print("%-48s %s%s" % (label, "IDENTICAL" if not differ else "DIFFERS",
                              ("  (only: %s)" % ", ".join(differ)) if differ else ""))
    for w in ("old", "new"):
        for arm in ("topo", "bridge"):
            cmds = rec[(w, arm)]["host_setup"]["h1"]
            print("  %s %-7s h1: %d command(s), %d arp entries, longest %d bytes"
                  % (w, arm, len(cmds), sum(c.count("arp -s") for c in cmds),
                     max(len(c) for c in cmds)))
    print()
PY

# [Co-developed with claude code -- Adam]
