#!/usr/bin/env bash
#
# E-2 / KNOWN-ISSUES G-15: run_layers.sh must ask the kernel which model it loaded, and must
# refuse when it cannot confirm that the file has not changed underneath it.
#
# [Co-developed with claude code -- Adam]
#
# THE DEFECT. `topo_for_mode()` derived the model from (data plane, live host count) and never
# asked the kernel. `setting/` holds more than one model with the same ten dpids and the same
# 10 switch / 4 host / 40 edge cardinality, so a fabric built from model A and validated against
# model B was green **by construction** -- every per-node identity check passes because the
# numbers agree (fix/R2-PY-SUMMARY.md §7-3). L-1 made the derivation follow the running fabric;
# it did not make it correct, because the fabric cannot say which FILE the twin opened.
#
# 🔴 What this file pins is DISCRIMINATING POWER, in three directions:
#
#   * the kernel's answer is USED (case 1) -- a run against the model the kernel actually
#     loaded, even when the derivation would have picked a different one;
#   * a model edited since the load is REFUSED (case 2), not tested against. The twin would be
#     serving the old contents and the layers the new ones, and every difference between them
#     would be reported as a product defect -- the L-1 failure again, one level further in;
#   * a kernel that does NOT answer still gets a run (cases 3, 4, 8) and is told that the model
#     was guessed. Aborting there is the widening: baseline `28b8b13` serves none of the three
#     keys, and "the kernel did not say" must not become "there is nothing to test".
#
# No kernel, no fabric, no lab claim: NDTWIN_RUN_LAYERS_LIB_ONLY=1 stops run_layers.sh above its
# mode dispatch, the fabric host count is injected by overriding fabric_host_count(), and the
# kernel's reply is injected by overriding kernel_graph_json(). The models are fixtures in a
# temp dir. The one file the kernel "loads" deliberately does NOT follow the naming convention
# the derivation greps for, so no derivation can produce it by accident -- if case 1 passes, it
# passed because the kernel was asked.
#
# Run:  bash tests/shell/test_run_layers_asks_kernel.sh
# Env:  RUN_LAYERS_UNDER_TEST=<path>   score another copy (the mutation gate uses this)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${RUN_LAYERS_UNDER_TEST:-$HERE/../../tools/test_workflow/run_layers.sh}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }
done_() { echo "Ran $((PASS+FAIL)) checks, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; exit $?; }

# shellcheck source=/dev/null
if ! NDTWIN_RUN_LAYERS_LIB_ONLY=1 source "$DRIVER" >/dev/null 2>&1; then
    echo "  FAILED   could not source $DRIVER with NDTWIN_RUN_LAYERS_LIB_ONLY=1"
    echo "Ran 1 checks, 1 failed"
    exit 1
fi

TMPROOT="$(mktemp -d /tmp/run-layers-kernel-XXXXXX)"
cleanup() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/run-layers-kernel-* ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixtures -------------------------------------------------------------------------------
SETTING_DIR="$TMPROOT/setting"
mkdir -p "$SETTING_DIR"
write_model() {   # $1 = path, $2 = host count
    python3 - "$1" "$2" <<'PY'
import json, sys
path, hosts = sys.argv[1], int(sys.argv[2])
nodes = [{"vertex_type": 0, "dpid": i} for i in range(1, 11)]
nodes += [{"vertex_type": 1, "dpid": 0} for _ in range(hosts)]
json.dump({"nodes": nodes, "edges": []}, open(path, "w"))
PY
}
write_model "$SETTING_DIR/StaticNetworkTopologyP4_10Switches_4Hosts.json" 4
write_model "$SETTING_DIR/StaticNetworkTopologyOVS_10Switches_4Hosts.json" 4

# The model the kernel "loaded". Its name matches none of the globs topo_for_hosts searches, so
# the derivation cannot reach it -- which is what makes case 1 evidence rather than a coincidence.
KERNEL_MODEL="$TMPROOT/loaded_by_the_kernel.json"
write_model "$KERNEL_MODEL" 4
KERNEL_MODEL_SHA="$(sha256sum "$KERNEL_MODEL" | cut -d' ' -f1)"

KERNEL_DIR="$TMPROOT"
TOPO_P4="$SETTING_DIR/StaticNetworkTopologyP4_10Switches_4Hosts.json"
TOPO_OVS="$SETTING_DIR/StaticNetworkTopologyOVS_10Switches_4Hosts.json"

# --- the two seams --------------------------------------------------------------------------
LIVE_HOSTS=4
fabric_host_count() { echo "$LIVE_HOSTS"; }

# The kernel's reply. Empty KERNEL_BODY means "nothing answered at $NDT_URL", which is what curl
# reports by failing -- so the stub fails too rather than printing an empty body.
KERNEL_BODY=""
kernel_graph_json() {
    [[ -z "$KERNEL_BODY" ]] && return 1
    printf '%s' "$KERNEL_BODY"
}

# body <topology_file> <topology_sha256> -- a graph response. An empty argument omits that key,
# which is the pre-E-2 shape; the literal `null` sets it to JSON null.
body() {
    python3 - "$1" "$2" <<'PY'
import json, sys
doc = {"nodes": [{"dpid": 1}], "edges": [], "topology_round": {"kind": "complete"}}
for key, raw in (("topology_file", sys.argv[1]), ("topology_sha256", sys.argv[2])):
    if raw == "null":
        doc[key] = None
    elif raw:
        doc[key] = raw
print(json.dumps(doc))
PY
}

# choose <mode> -- run topo_for_mode and stash stdout / stderr / rc.
choose() {
    CHOSEN="$(topo_for_mode "$1" 2>"$TMPROOT/err")"; CHOSE_RC=$?
    CHOSE_ERR="$(cat "$TMPROOT/err")"
}

# --- 1. THE DEFECT: the kernel's own answer wins over the derivation -------------------------
KERNEL_BODY="$(body "$KERNEL_MODEL" "$KERNEL_MODEL_SHA")"
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$KERNEL_MODEL" ]]; then
    t_ok "the model the kernel says it loaded is the model used"
else
    t_bad "the model the kernel says it loaded is the model used" \
          "rc=$CHOSE_RC chose [$CHOSEN]; wanted [$KERNEL_MODEL] -- a derived path here means the \
kernel was never asked"
fi

# --- 2. a model edited since the load is refused, not tested against -------------------------
KERNEL_BODY="$(body "$KERNEL_MODEL" "0000000000000000000000000000000000000000000000000000000000000000")"
choose p4
if [[ "$CHOSE_RC" -eq 3 && -z "$CHOSEN" ]] && grep -q 'edited since the kernel loaded it' <<<"$CHOSE_ERR"; then
    t_ok "a topology whose sha256 no longer matches is refused (rc 3)"
else
    t_bad "a topology whose sha256 no longer matches is refused (rc 3)" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# ... and the refusal shows both digests, because "they differ" is not a diagnostic
if grep -q "$KERNEL_MODEL_SHA" <<<"$CHOSE_ERR" && grep -q '0000000000000000' <<<"$CHOSE_ERR"; then
    t_ok "the refusal prints the digest the kernel loaded and the one on disk now"
else
    t_bad "the refusal prints the digest the kernel loaded and the one on disk now" \
          "stderr: ${CHOSE_ERR:0:200}"
fi

# --- 3. a kernel that does not report the field: derive, and SAY it is a guess ---------------
KERNEL_BODY="$(body "" "")"
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]] && grep -qi 'guessing' <<<"$CHOSE_ERR"; then
    t_ok "a pre-E-2 kernel falls back to the derivation and says it is guessing"
else
    t_bad "a pre-E-2 kernel falls back to the derivation and says it is guessing" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# --- 4. no kernel at all: same fallback, same admission --------------------------------------
KERNEL_BODY=""
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]] && grep -qi 'guessing' <<<"$CHOSE_ERR"; then
    t_ok "an unreachable kernel falls back to the derivation and says it is guessing"
else
    t_bad "an unreachable kernel falls back to the derivation and says it is guessing" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# --- 5. the kernel names a file this host cannot read: refuse, do not quietly derive ---------
KERNEL_BODY="$(body "$TMPROOT/there_is_no_such_model.json" "$KERNEL_MODEL_SHA")"
choose p4
if [[ "$CHOSE_RC" -eq 3 && -z "$CHOSEN" ]] && grep -q 'cannot read that file' <<<"$CHOSE_ERR"; then
    t_ok "a model the kernel named but this host cannot read is refused, not derived around"
else
    t_bad "a model the kernel named but this host cannot read is refused, not derived around" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# --- 6. a path with no digest beside it: usable, and the gap is stated -----------------------
KERNEL_BODY="$(body "$KERNEL_MODEL" "")"
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$KERNEL_MODEL" ]] &&
   grep -q 'no topology_sha256' <<<"$CHOSE_ERR"; then
    t_ok "a kernel that names a file but no digest is still believed about the file, with a note"
else
    t_bad "a kernel that names a file but no digest is still believed about the file, with a note" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# --- 7. NDT_TOPO still overrides everything, kernel included ---------------------------------
KERNEL_BODY="$(body "$KERNEL_MODEL" "$KERNEL_MODEL_SHA")"
NDT_TOPO="$TOPO_P4"
choose p4
unset NDT_TOPO
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]]; then
    t_ok "NDT_TOPO overrides the kernel's answer as well as the derivation"
else
    t_bad "NDT_TOPO overrides the kernel's answer as well as the derivation" \
          "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 8. a key that is present but not a path is "did not say", not a path --------------------
# A JSON null is the shape a half-finished kernel would emit, and reading it as a filename would
# make the whole run test against "" -- a confident wrong answer where an admission belongs.
KERNEL_BODY="$(body null "$KERNEL_MODEL_SHA")"
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]] && grep -qi 'guessing' <<<"$CHOSE_ERR"; then
    t_ok "a null topology_file reads as \"the kernel did not say\", not as a filename"
else
    t_bad "a null topology_file reads as \"the kernel did not say\", not as a filename" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:160}"
fi

# --- 9. the reader itself, on the body it will actually meet ---------------------------------
# kernel_loaded_model takes the body on STDIN and not in an argument, because a 128-host graph
# is larger than one exec argument may be. Driving it with a body padded past that limit is the
# half an injected small fixture cannot cover.
big="$(python3 - "$KERNEL_MODEL" "$KERNEL_MODEL_SHA" <<'PY'
import json, sys
doc = {"nodes": [{"dpid": i, "device_name": "s%d" % i, "pad": "x" * 200} for i in range(1500)],
       "edges": [],
       "topology_file": sys.argv[1],
       "topology_sha256": sys.argv[2]}
print(json.dumps(doc))
PY
)"
read_back="$(printf '%s' "$big" | kernel_loaded_model)"
if [[ ${#big} -gt 131072 && "$read_back" == "$KERNEL_MODEL	$KERNEL_MODEL_SHA" ]]; then
    t_ok "the reader parses a body larger than one exec argument (${#big} bytes)"
else
    t_bad "the reader parses a body larger than one exec argument (${#big} bytes)" \
          "got [$read_back]"
fi

done_
