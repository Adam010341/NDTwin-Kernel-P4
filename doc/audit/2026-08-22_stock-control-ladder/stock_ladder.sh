#!/usr/bin/env bash
# stock_ladder.sh -- P0-2: the control the fast-build ladder never had.
#
# [Co-developed with claude code -- Adam]
#
# B2 (3)'s honest verdict on 2026-08-21 was "the fast build introduced zero NEW failures", not
# "the ladder passes" -- and that phrasing was only defensible because the residual reds were
# each attributed by argument. Nobody ran the same ladder on the stock binary. This is that run.
#
# Adam's ruling: control green -> promote fast to default.
#
# ## Both arms, one code path, same night
#
# The first version of this ran only the stock arm, to be compared against the 2026-08-21 fast
# ladder. That comparison would have been worthless: between the two runs the invocation changed
# (--traffic dropped, TOPO_P4 corrected), the OVS L4 baseline was re-banked, and the settle
# default moved. Four variables, one of them the binary. A control varies ONE thing, so both
# arms run here, back to back, through the identical code below.
#
# ## Naming the binary is the point
#
# Both installs answer `--version` with the same string (1.15.3-f0b7d201), and this exact pair
# has already been confused once in an A/B where both numbers looked plausible. Each arm reads
# the LIVE switches' /proc/<pid>/cmdline and sha256s the binary they name, and refuses to run
# the ladder unless that hash is the one the arm asked for. An arm that silently ran the other
# binary would produce a perfect "identical failures" result that means nothing.
#
# The /proc scan matches an ABSOLUTE path on purpose: the scan's own grep command line contains
# the search string and is itself in /proc, and "]*simple_switch_grpc" sorts before "/usr/...",
# so the unanchored version picked its own pattern, hashed nothing, and aborted a run whose
# fabric was in fact correct. Third instance of a process scan matching its own argv this day.
#
# NO --traffic: it requires flows/paths/rates, and passing it with no generator running is where
# 48 of the 2026-08-21 L4 "differences" came from. TOPO_P4 is pinned to the 128-host model
# because the fabric is 128 hosts and the default declares 4 -- the other half of that defect,
# which this script walked straight into on its first run by invoking run_layers.sh directly.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_stock-control-ladder"
OUT="$DIR/stock_ladder.txt"
OVERRIDE="$REPO/p4_proxy/mininet/bmv2_binary_override"
RL="$REPO/tools/test_workflow/run_layers.sh"
export TOPO_P4="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"

STOCK=/usr/local/bin/simple_switch_grpc
FAST=/usr/local/bmv2-fast/bin/simple_switch_grpc
STOCK_SHA=327fa7d17221739747a15c6ced580b452b5c8981f29ba6a6998c1361d73cdef4
FAST_SHA=3ff54b5c1901c9d3ffd80ac05dc3dc7d0e696e3df73174c1616fb87ac9aedb4a
ARMS="${ARMS:-stock fast}"

mkdir -p "$DIR/raw"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

BACKUP="$(mktemp -t bmv2_override.XXXXXX)"
cp "$OVERRIDE" "$BACKUP"
trap 'cp "$BACKUP" "$OVERRIDE"; ndt down >/dev/null 2>&1; printf "override restored\n"' EXIT

say "# stock vs fast: the same ladder on both bmv2 builds (P0-2)"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# TOPO_P4: $(basename "$TOPO_P4")   (fabric is 128 hosts; the default declares 4)"
say "# arms:   $ARMS"
say ""

live_binary() {
    for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p" 2>/dev/null; echo; done \
      | grep -o '/[^ ]*simple_switch_grpc' | sort -u | head -1
}

run_arm() {
    local arm="$1" binary want_sha rc
    case "$arm" in
        stock) binary="$STOCK"; want_sha="$STOCK_SHA" ;;
        fast)  binary="$FAST";  want_sha="$FAST_SHA" ;;
        *) say "unknown arm '$arm'"; return 1 ;;
    esac

    say "=================================================================="
    say "## ARM: $arm  ($binary)"
    if [[ "$(sha256sum "$binary" | cut -d' ' -f1)" != "$want_sha" ]]; then
        say "  ABORT: $binary does not match its sha in bmv2-binary-provenance.md"
        return 1
    fi

    { grep '^#' "$BACKUP"; echo; echo "$binary"; } > "$OVERRIDE"
    ndt down > /dev/null 2>&1
    sleep 3
    local t0; t0=$(date +%s)
    if ! timeout 1800 ndt up p4 128 > "$DIR/raw/${arm}_up.out" 2>&1; then
        say "  UP FAILED after $(( $(date +%s) - t0 ))s -- see raw/${arm}_up.out"
        tail -10 "$DIR/raw/${arm}_up.out" | sed 's/^/    /' | tee -a "$OUT"
        return 1
    fi
    say "  boot: $(( $(date +%s) - t0 ))s"

    local running running_sha
    running="$(live_binary)"
    [[ -n "$running" ]] || { say "  ABORT: no simple_switch_grpc running"; return 1; }
    running_sha="$(sha256sum "$running" | cut -d' ' -f1)"
    if [[ "$running_sha" != "$want_sha" ]]; then
        say "  ABORT: asked for '$arm' but the live switches run $running"
        say "         (sha ${running_sha:0:16}...) -- refusing to attribute a ladder to the"
        say "         wrong binary, which is exactly the mistake this arm exists to prevent"
        return 1
    fi
    say "  confirmed live: $running"
    say ""

    bash "$RL" full p4 > "$DIR/raw/${arm}_ladder.out" 2>&1
    rc=$?
    say "  run_layers exit: $rc"
    say ""
    say "  layer summary:"
    sed -n '/^Summary/,/logs:/p' "$DIR/raw/${arm}_ladder.out" \
      | grep -E "PASS|FAIL" | sed 's/^/    /' | tee -a "$OUT"
    say ""
    say "  failed checks:"
    { grep -h "^FAILED checks:" "$DIR/raw/${arm}_ladder.out" | sort -u
      grep -hE "^\s+BROKEN\s+/ndt/" "$DIR/raw/${arm}_ladder.out" | sort -u; } \
      | sed 's/^/    /' | tee -a "$OUT"
    say ""
}

for arm in $ARMS; do
    run_arm "$arm" || say "  (arm '$arm' did not complete -- it is not a data point)"
done

say "=================================================================="
say "## the comparison"
for arm in $ARMS; do
    if [[ -f "$DIR/raw/${arm}_ladder.out" ]]; then
        say "  $arm:"
        sed -n '/^Summary/,/logs:/p' "$DIR/raw/${arm}_ladder.out" \
          | grep -E "PASS|FAIL" | sed 's/^/      /' | tee -a "$OUT"
        say "    failed: $(grep -h '^FAILED checks:' "$DIR/raw/${arm}_ladder.out" | sort -u | sed 's/FAILED checks: //' | tr '\n' ' ')"
    else
        say "  $arm: no ladder output"
    fi
done
say ""
say "  Identical sets -> the residuals belong to the plane and the harness, not to the fast"
say "  build, and 'zero new failures' becomes a measurement instead of an argument."
say "  Anything failing on fast but not on stock -> promotion is off."
say ""
say "done -> $OUT"
