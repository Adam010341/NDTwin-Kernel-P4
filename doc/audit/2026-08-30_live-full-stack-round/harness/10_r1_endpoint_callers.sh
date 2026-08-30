#!/bin/bash
# =================================================================================================
# 10_r1_endpoint_callers.sh -- R-1: does any consumer still parse the reply from the historical
# logging endpoint, whose success body gained a "recording" field and a new early-return branch
# (HttpSession.cpp:1801-1818)?
#
# WRITTEN, NOT RUN. `bash -n` only.
#
# 🔴 READ THIS BEFORE RUNNING -- THE PREREG NAMES A URL THAT DOES NOT EXIST
#   PREREG §3 R-1 calls the endpoint `/ndt/set_historical_logging_state`. That is the C++ HANDLER
#   name (`handleSetHistoricalLoggingState`), not the route. The only route that reaches it is
#       HttpSession.cpp:284   POST  target.starts_with("/ndt/historical_logging")
#   so the correct probe is  POST /ndt/historical_logging?state=enable .
#   A probe written from the PREREG's string would 404 -- and would 404 for the WRONG REASON,
#   which is the H-19 shape: the kernel answering "no such route" read as "the endpoint is
#   broken". Both spellings are probed below, separately, so the difference is on the record.
#   Do not edit the PREREG to match; record the discrepancy in the write-up.
#
# ⚠️ R-1's REGISTERED NULL BRANCH IS THE ONE THAT FIRES
#   PREREG §3: "no app calls this endpoint at all -- in which case R-1 is untestable by this
#   round and must be reported as untestable, not as passed."
#   A read of all seven sibling repos on 2026-08-30 found ZERO callers, by enumerating every
#   /ndt/ path each repo constructs rather than by grepping for the endpoint name. This script
#   re-runs that enumeration live so the conclusion is dated by the run, not inherited.
#
#   🔑 WHY A PLAIN GREP IS NOT ENOUGH (and why this script does two passes):
#   Traffic-Engineering-App.py:32 sets  ndt_url = "http://localhost:8000/ndt/"  -- WITH a
#   trailing slash -- and appends bare fragments like "get_graph_data". So the literal string
#   "/ndt/get_graph_data" appears NOWHERE in that repo even though it calls it every second.
#   Grepping endpoint names there returns zero hits for endpoints that are definitely called.
#   Pass 2 therefore greps for the FRAGMENT (no /ndt/ prefix) and for the base-URL idioms.
#   See memory: grep-endpoints-misses-concatenation.
#
# H-CORRESPONDENCE
#   H-17  no process liveness needed; nothing is spawned or killed here.
#   H-18  🔑 THE CENTRAL DEFECT THIS SCRIPT IS DESIGNED AGAINST. Every conclusion of the form
#         "no caller" is required to be corroborated by a POSITIVE CONTROL: the same search
#         method must find a caller that is known to exist. If the control finds nothing, the
#         search method is broken and the script reports UNTESTABLE, never "no callers".
#   H-19  the two spellings are probed separately and curl-rc is kept apart from http-code, so
#         "404" and "nothing answered" cannot merge into one verdict.
#   H-20  no artefact is inherited; the scan reads source trees, which this round does not write.
#   H-21  `set -o pipefail` from lib.sh; every grep result is captured into a variable with
#         `|| true` and then tested. No gate is the tail of a pipeline.
#   H-22  nothing backgrounded.
#   H-23  patterns are fragments taken from the callers' own source idioms, and the positive
#         control proves each search shape can actually match.
#   H-24  n/a (no buffered producer read here).
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 10_r1_endpoint_callers

# shellcheck source=/dev/null
. "$REPO/tools/test_workflow/components.env"

REPOS=(
    "Energy-Saving-App:$ENERGY_APP_DIR"
    "Simulation-Platform-Manager:$SIM_MGR_DIR"
    "Network-Traffic-Visualizer:$VISUALIZER_DIR"
    "Web-GUI:$WEBGUI_DIR"
    "Network-State-Recorder:$NSR_DIR"
    "Network-Traffic-Generator:$NTG_DIR"
    "Traffic-Engineering-App:$TE_APP_DIR"
)

EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=venv --exclude-dir=__pycache__
      --exclude-dir=dist --exclude-dir=build --exclude-dir=target --exclude-dir=logs)

SCAN="$OUT/r1_scan.txt"
: > "$SCAN"

say "the seven sibling repos exist"
MISSING=0
for pair in "${REPOS[@]}"; do
    n="${pair%%:*}"; d="${pair#*:}"
    if [[ -d "$d" ]]; then ok "$n -> $d"; else bad "$n NOT FOUND at $d"; MISSING=$((MISSING+1)); fi
done
(( MISSING == 0 )) || die "R-1 cannot be answered while $MISSING repo(s) are missing: an absent repo is not a repo without callers. Fix WORKSPACE_ROOT (components.env:19-28) and re-run."

# -------------------------------------------------------------------------------------------------
say "POSITIVE CONTROL for the search method (H-18)"
# Before believing any "zero hits", prove the search can find something that is definitely there.
# get_graph_data is called by six of the seven repos, and by TE via bare-fragment concatenation,
# so it exercises both search shapes at once.
#
# HOW TO FORCE THIS RED: change CONTROL_FRAG to a string no repo uses, e.g. "get_moon_phase".
# The control must fail and the script must abort instead of reporting "no callers".
CONTROL_FRAG='get_graph_data'
CONTROL_HITS=0
for pair in "${REPOS[@]}"; do
    n="${pair%%:*}"; d="${pair#*:}"
    c="$(grep -rIl "${EXCL[@]}" -e "$CONTROL_FRAG" "$d" 2>/dev/null | wc -l || true)"
    printf 'CONTROL %-30s %s file(s) mention %s\n' "$n" "$c" "$CONTROL_FRAG" >> "$SCAN"
    CONTROL_HITS=$(( CONTROL_HITS + c ))
done
if (( CONTROL_HITS >= 5 )); then
    ok "positive control: the fragment search found '$CONTROL_FRAG' in $CONTROL_HITS file(s) across the repos, so a zero below means absence rather than a broken search"
else
    die "positive control FAILED: '$CONTROL_FRAG' was found in only $CONTROL_HITS file(s), but at least six repos call it. The search method is broken -- every 'no caller' verdict from it would be an H-18 false negative. Do not proceed."
fi

# -------------------------------------------------------------------------------------------------
say "PASS 1 -- literal endpoint spellings"
P1_TOTAL=0
for pat in \
    '/ndt/set_historical_logging_state' \
    '/ndt/historical_logging' \
; do
    for pair in "${REPOS[@]}"; do
        n="${pair%%:*}"; d="${pair#*:}"
        hits="$(grep -rIn "${EXCL[@]}" -F -e "$pat" "$d" 2>/dev/null || true)"
        if [[ -n "$hits" ]]; then
            printf 'PASS1 %s :: %s\n%s\n' "$n" "$pat" "$hits" >> "$SCAN"
            P1_TOTAL=$(( P1_TOTAL + $(printf '%s\n' "$hits" | wc -l) ))
        fi
    done
done
info "pass 1 literal hits: $P1_TOTAL"

# -------------------------------------------------------------------------------------------------
say "PASS 2 -- fragments, for callers that concatenate onto a base URL"
# TE (Traffic-engineering-App.py:32) appends bare fragments to a base ending in "/ndt/";
# NSR (network_state_recorder.py:21,23) holds paths in module constants and rebinds them at :283;
# VIZ (NDTApiClient.java:15) does baseUrl + "/ndt/...";
# Web-GUI (src/api/index.ts:1) uses a `${NDT_API_BASE_URL}/ndt/...` template literal.
# All four idioms survive a fragment search; only the first survives a literal-path search.
P2_TOTAL=0
for frag in \
    'historical_logging' \
    'set_historical' \
    'historicalLogging' \
    'HistoricalLogging' \
    'logging_state' \
    'SetHistorical' \
; do
    for pair in "${REPOS[@]}"; do
        n="${pair%%:*}"; d="${pair#*:}"
        hits="$(grep -rIni "${EXCL[@]}" -e "$frag" "$d" 2>/dev/null || true)"
        if [[ -n "$hits" ]]; then
            printf 'PASS2 %s :: %s\n%s\n' "$n" "$frag" "$hits" >> "$SCAN"
            P2_TOTAL=$(( P2_TOTAL + $(printf '%s\n' "$hits" | wc -l) ))
        fi
    done
done
info "pass 2 fragment hits: $P2_TOTAL  (expect some NOISE: 'historical' appears in Web-GUI and"
info "Visualizer UI strings about replaying historical DATA FILES, which is a different feature."
info "Read $SCAN by hand before concluding -- a hit is a candidate, not a caller.)"

# -------------------------------------------------------------------------------------------------
say "PASS 3 -- how each repo builds kernel URLs, so a future reader can audit the enumeration"
{
    printf '# URL-construction idiom per repo, so that "we enumerated every /ndt/ call" is checkable.\n'
    printf '# Recorded %s\n\n' "$(_ts)"
    for pair in "${REPOS[@]}"; do
        n="${pair%%:*}"; d="${pair#*:}"
        printf '## %s\n' "$n"
        grep -rIn "${EXCL[@]}" -e '/ndt/' -e 'ndt_url' -e 'NDT_URL' -e 'NDT_API' -e 'ndtwin_kernel' \
             -e 'baseUrl' -e 'base_url' -e ':8000' "$d" 2>/dev/null | head -60 || true
        printf '\n'
    done
} > "$OUT/r1_url_idioms.txt"
ok "URL idioms captured to $OUT/r1_url_idioms.txt (read it; the matrix in the write-up must be derived from this file, not from memory)"

# -------------------------------------------------------------------------------------------------
say "R-1 VERDICT (three-valued, per PREREG §3)"
if (( P1_TOTAL == 0 )); then
    skip "R-1 UNTESTABLE by observation of consumers: no repo references the endpoint under either spelling. PREREG §3 registers this branch explicitly -- it is NOT a pass. The response-shape change cannot break a caller that does not exist."
else
    bad "R-1 IS testable: $P1_TOTAL literal reference(s) found (see $SCAN). Each caller must now be exercised and checked for a parse throw or a behaviour change -- the presence of the new 'recording' field is NOT the break condition."
fi

# -------------------------------------------------------------------------------------------------
say "direct kernel probe -- the endpoint's own behaviour, independent of whether anyone calls it"
# This half IS testable even with no consumers, and it is worth recording: it shows which branch
# fires in this deployment. It does NOT convert R-1 into a pass; R-1 is about callers.
if [[ -z "$(port_holder 8000)" ]]; then
    skip "kernel is not listening on :8000; the direct probe is deferred. Run this script again after 20_apps_lifecycle.sh has the stack up."
else
    # H-19: the PREREG's spelling and the real route are probed SEPARATELY.
    read -r RC_A CODE_A <<<"$(http_probe r1_prereg_spelling POST "$NDT_URL/ndt/set_historical_logging_state?state=enable")"
    info "PREREG spelling  -> curl_rc=$RC_A http=$CODE_A  body: $(head -c 200 "$OUT/http/r1_prereg_spelling.body" 2>/dev/null || true)"
    if [[ "$RC_A" != "0" ]]; then
        bad "nothing answered at all (curl rc=$RC_A) -- that is a different observation from a 404 and must not be written up as 'the endpoint is missing'"
    elif [[ "$CODE_A" == "404" ]]; then
        ok "PREREG's spelling returns 404, confirming it is the handler name and not a route (the kernel ANSWERED; it did not fail)"
    else
        bad "PREREG's spelling returned HTTP $CODE_A, not the 404 predicted from HttpSession.cpp:284. The dispatch table has changed; re-read it before concluding anything else in this script."
    fi

    read -r RC_B CODE_B <<<"$(http_probe r1_real_route POST "$NDT_URL/ndt/historical_logging?state=enable")"
    BODY_B="$(cat "$OUT/http/r1_real_route.body" 2>/dev/null || true)"
    info "real route       -> curl_rc=$RC_B http=$CODE_B  body: $BODY_B"
    if [[ "$RC_B" == "0" && "$CODE_B" == "200" ]]; then
        # In MININET the early-return branch fires: status stays "success", HTTP stays 200, and
        # ONLY `recording` and `message` distinguish it (HttpSession.cpp:1801-1810). A client
        # that checks the status code, or even the `status` field, cannot tell the two apart.
        if printf '%s' "$BODY_B" | grep -q '"recording":false' \
        && printf '%s' "$BODY_B" | grep -q 'does not record'; then
            ok "the MININET early-return branch fired: recording=false with the 'does not record' message -- the branch PREREG §3 says fires in every run this project does"
        elif printf '%s' "$BODY_B" | grep -q '"recording":true'; then
            bad "recording=true in a MININET deployment: HistoricalDataManager::canRecord() should be false here (HistoricalDataManager.hpp:107). Either the mode is not MININET or the guard changed."
        else
            bad "200 but neither branch's signature is present. Body: $BODY_B"
        fi
        # The point worth writing down regardless of branch.
        info "NOTE for the write-up: both branches answer 200 with status=\"success\". Only 'recording' and 'message' differ, so any caller that keys on the status code or on the status field is blind to the distinction."
    else
        bad "real route: curl_rc=$RC_B http=$CODE_B (expected rc=0, http=200)"
    fi

    # Registered negative: the 400 path proves the handler is reachable and parsing, which is
    # what makes a 200 above meaningful rather than a coincidence.
    # HOW TO FORCE THIS RED: it goes red on its own if the handler stops validating `state`.
    read -r RC_C CODE_C <<<"$(http_probe r1_bad_state POST "$NDT_URL/ndt/historical_logging?state=banana")"
    if [[ "$RC_C" == "0" && "$CODE_C" == "400" ]]; then
        ok "control: an invalid state returns 400 (HttpSession.cpp:1774-1778), so the 200 above came from the handler, not from a catch-all"
    else
        bad "control FAILED: invalid state gave curl_rc=$RC_C http=$CODE_C, expected 400. Without this control the 200 above is not attributable to this handler."
    fi
fi

summary
exit 0
