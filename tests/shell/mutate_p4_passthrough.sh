#!/usr/bin/env bash
#
# Mutation gate for tests/test_P4Passthrough.cpp: the kernel's /ndt/p4 routes, which relay five
# P4 reads and writes to the P4 proxy and nothing else.
#
# [Co-developed with claude code -- Adam]
#
# What the suite claims, and the mutations aimed at each claim:
#
#   * the request reaches the proxy as it came in (method, query, body, Content-Type)  -> 1-4, 23
#   * the proxy's answer comes back as the proxy wrote it                              -> 5-7, 20
#   * the kernel's own answers say which failure it was (refused, closed, unreadable,
#     timed out) and whether the request was sent                                      -> 8-11, 27-30
#   * only the five paths are relayed, with their methods, and only on a P4 fabric     -> 12-18
#   * the deadlines cover the proxy's own slowest answers, per route                   -> 21, 22, 24, 25
#   * the lab claim rides on the write only, in a header, as ASCII, never as an error  -> 19, 26,
#                                                                                         H3, H4, H11, H12
#   * the request path: wired, fabric-checked, asynchronous, no CORS under /ndt/p4,
#     Allow on the wire, no body on HEAD, CORS kept everywhere else                    -> H1, H2, H5-H10
#   * replies that echo outside text stay valid JSON (request bytes, exception text,
#     another process's words)                                                         -> H17-H24
#   * the relay completes after respondAsync returns, a throw becomes one kernel 500,
#     keep-alive survives a relay, the proxy socket is close-on-exec                   -> 31-39, H13
#
# KNOWN GAPS run last (known_gap): mutations no case can catch yet. They are applied, built and
# run, and reported -- a known gap that starts going red is news, and is printed as such -- but a
# gap that still survives does not fail the gate. A STALE record does: an anchor that no longer
# matches once, or a mutant that no longer compiles, means the record describes code that is not
# there, and that fails the gate exactly as a moved anchor does in mutate(). A run that hangs is a
# survivor here too, as it is in mutate().
#
# 🔴 Anything that stops the tests RUNNING counts as SURVIVED: an anchor that no longer matches, a
# mutation that will not apply, a mutant that does not compile. In all three the behaviour is as
# unproven as if the suite had stayed green.
#
# The widenings at the end must stay GREEN: they change spelling, not behaviour.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD. Restore is `cp -p`
# then `touch`, because cp -p puts the ORIGINAL mtime back -- older than the object built from the
# mutant -- and the build would then score the next mutation against the previous mutant's binary.
# Only a file that differs from its snapshot is restored and touched: touching all three would
# rebuild HttpSession.cpp, and every test that includes P4Passthrough.hpp, for every mutation.
#
# Usage:  LOCK_WAIT=10800 JOBS=1 tools/build_guard/guarded_build.sh \
#             ./tests/shell/mutate_p4_passthrough.sh
#         ONLY="9." ... runs only the mutations and widenings whose label starts with that text.
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured.
#          Run it under the build guard: this laptop's systemd-oomd killed the user's own
#          application during an unguarded build on 2026-09-02.
# Exit:    0 all mutations caught and all widenings green
#          1 a mutation survived -- including one that failed to build or whose anchor moved
#          2 refused (baseline red, tree unbuildable, or a source not restored byte-identically)
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='P4Passthrough*:DispatchStatusEndpointTest.*:GroupMeterEndpointTest.*'

RELAY=src/ndt_core/http/P4Passthrough.cpp
RELAY_H=include/ndt_core/http/P4Passthrough.hpp
SESSION=src/ndt_core/http/HttpSession.cpp
FILES=("$RELAY" "$RELAY_H" "$SESSION")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured." >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(echo "$1" | tr '/' '_')"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        if ! cmp -s "$f" "$(snap "$f")"; then
            cp -p "$(snap "$f")" "$f"
            touch "$f"
        fi
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WIDENINGS_RED=0
KNOWN_GAPS=0
KNOWN_GAPS_STALE=0

# anchor_count <file> <literal>. python, not `grep -c -F`: grep splits a multi-line -F pattern
# into several patterns and counts matching LINES.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

apply_anchor() {
    ANCHOR="$2" REPL="$3" python3 - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# A suite run is bounded: a mutant that hangs a case is caught, not waited on forever.
red_tests() {
    local out rc
    out=$(timeout 300 "$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    if [[ $rc -eq 124 ]]; then echo "TIMED-OUT"; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <file> <old> <new> <expected-test>
mutate() {
    local label="$1" file="$2" old="$3" new="$4" expected="$5"
    [[ -n "${ONLY:-}" && "$label" != "$ONLY"* ]] && return
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! apply_anchor "$file" "$old" "$new"; then
        echo "  🔴 mutation could not be applied. NOT a pass. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- the test never ran, so this counts as SURVIVED."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ "$failed" == "TIMED-OUT" ]]; then
        echo "  🔴 THE SUITE HUNG -- no case reported, so this counts as SURVIVED."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <old> <new> <why-behaviour-is-preserved>
widen() {
    local label="$1" file="$2" old="$3" new="$4" why="$5"
    [[ -n "${ONLY:-}" && "$label" != "$ONLY"* ]] && return
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== WIDENING: %s ===\n' "$label"
    printf '  %s\n' "$why"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    WIDENINGS=$((WIDENINGS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this widening proves nothing. Counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    apply_anchor "$file" "$old" "$new"
    if ! build; then
        echo "  🔴 WIDENING DOES NOT COMPILE -- counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  ✅ stayed green, as it must"
    else
        printf '  🔴 WENT RED: %s\n' "$failed"
        echo "     The suite is pinned to the spelling, not to the behaviour."
        WIDENINGS_RED=$((WIDENINGS_RED + 1))
    fi
    restore
}

# known_gap <label> <file> <old> <new> <why-no-case-catches-it>
known_gap() {
    local label="$1" file="$2" old="$3" new="$4" why="$5"
    [[ -n "${ONLY:-}" && "$label" != "$ONLY"* ]] && return
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== KNOWN GAP: %s ===\n' "$label"
    printf '  %s\n' "$why"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    KNOWN_GAPS=$((KNOWN_GAPS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 STALE: the anchor matches $n times -- the gap is no longer where this says."
        KNOWN_GAPS_STALE=$((KNOWN_GAPS_STALE + 1)); restore; return
    fi
    apply_anchor "$file" "$old" "$new"
    if ! build; then
        echo "  🔴 STALE: does not compile -- the gap is no longer where this says."
        KNOWN_GAPS_STALE=$((KNOWN_GAPS_STALE + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  survives, as recorded"
    elif [[ "$failed" == "TIMED-OUT" ]]; then
        echo "  survives, as recorded (the suite hung, which mutate() also scores as surviving)"
    else
        printf '  ✅ NOW CAUGHT by %s -- move it to a mutate line\n' "$failed"
    fi
    restore
}

echo "mutation gate -- the /ndt/p4 pass-through routes"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
    cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    exit 2
fi
timeout 300 "$BIN" --gtest_filter="$FILTER" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- the request reaches the proxy as it came in -------------------------------------------------

mutate "1. every relayed request is a GET" \
    "$RELAY" \
    '        m_req = http::request<http::string_body>{m_method, m_target, 11};' \
    '        m_req = http::request<http::string_body>{http::verb::get, m_target, 11};' \
    'P4PassthroughRelay.TableEntryWriteGoesOutAsAPostWithItsBodyAndContentType'

mutate "2. the query string is dropped" \
    "$RELAY" \
    '    route.proxyTarget = std::string(target.substr(kKernelPrefix.size()));' \
    '    route.proxyTarget = std::string(pathOf(target).substr(kKernelPrefix.size()));' \
    'P4PassthroughRelay.TableEntryReadGoesOutAsAGetWithItsQuery'

mutate "3. the body is dropped" \
    "$RELAY" \
    '        m_req.body() = std::move(m_body);' \
    '        m_req.body() = "";' \
    'P4PassthroughRelay.TableEntryWriteGoesOutAsAPostWithItsBodyAndContentType'

mutate "4. the request's Content-Type is not sent" \
    "$RELAY" \
    '        if (m_contentType)
        {
            m_req.set(http::field::content_type, *m_contentType);' \
    '        if (false)
        {
            m_req.set(http::field::content_type, *m_contentType);' \
    'P4PassthroughRelay.TableEntryWriteGoesOutAsAPostWithItsBodyAndContentType'

mutate "23. the configured host name is not looked up" \
    "$RELAY" \
    '            m_hostAndPort.substr(colon + 1),
            [self = shared_from_this()]' \
    '            m_hostAndPort.substr(colon + 1),
            tcp::resolver::numeric_host,
            [self = shared_from_this()]' \
    'P4PassthroughRelay.TheAddressIsResolvedAsAHostNameTheWayItIsConfigured'

# --- the proxy's answer comes back as written ----------------------------------------------------

mutate "5. the proxy's error statuses are rewritten to 502" \
    "$RELAY" \
    '        reply.status = proxy.status;' \
    '        reply.status = proxy.status >= 400 ? 502 : proxy.status;' \
    'P4PassthroughRelay.TheProxysStatusAndBodyComeBackUnchanged'

mutate "6. the proxy's body is re-serialised" \
    "$RELAY" \
    '        reply.body = std::move(proxy.body);' \
    '        reply.body = nlohmann::json::parse(proxy.body, nullptr, false).dump();' \
    'P4PassthroughRelay.TheProxysStatusAndBodyComeBackUnchanged'

mutate "7. the proxy's Content-Type is replaced by application/json" \
    "$RELAY" \
    '        reply.contentType = std::move(proxy.contentType);' \
    '        reply.contentType = std::string("application/json");' \
    'P4PassthroughRelay.TheProxysContentTypeComesBackEvenWhenItIsNotJson'

mutate "20. the proxy's answer is labelled as the kernel's" \
    "$RELAY" \
    '        reply.origin = "proxy";' \
    '        reply.origin = "kernel";' \
    'P4PassthroughRelay.TableEntryWriteGoesOutAsAPostWithItsBodyAndContentType'

# --- the kernel's own answers -------------------------------------------------------------------

mutate "8. a refused connection is reported as a timeout" \
    "$RELAY" \
    '        reply = kernelReply(502,
                            {{"error", "P4 proxy unreachable"},' \
    '        reply = kernelReply(504,
                            {{"error", "P4 proxy timed out"},' \
    'P4PassthroughUnreachable.NothingListeningIsAKernel502ThatSaysTheProxyWasNotReached'

mutate "9. the relay has no deadline" \
    "$RELAY" \
    '          m_deadline(std::chrono::steady_clock::now() + timeout),' \
    '          m_deadline(std::chrono::steady_clock::time_point::max()),' \
    'P4PassthroughUnreachable.AProxyThatNeverAnswersIsAKernel504WithinTheDeadline'

mutate "10. a read that timed out is reported as a closed connection" \
    "$RELAY" \
    '        if (ec == beast::error::timeout)
        {
            finish(ProxyReply::Outcome::TimedOut,
                   "no complete reply within " + secondsText(m_timeout));' \
    '        if (false)
        {
            finish(ProxyReply::Outcome::TimedOut,
                   "no complete reply within " + secondsText(m_timeout));' \
    'P4PassthroughUnreachable.AProxyThatNeverAnswersIsAKernel504WithinTheDeadline'

mutate "11. a request that was sent is reported as not sent" \
    "$RELAY" \
    '        m_out.requestSent = true;
' \
    '' \
    'P4PassthroughUnreachable.AProxyThatClosesAfterReadingIsA502ThatSaysTheRequestWasSent'

mutate "27. an unreadable reply is reported as a closed connection" \
    "$RELAY" \
    '        if (ec && isUnreadableReply(ec))' \
    '        if (false && ec && isUnreadableReply(ec))' \
    'P4PassthroughUnreachable.AMalformedReplyIsUnreadableNotUnreachable'

mutate "28. a connection that ended without a reply is reported as a timeout" \
    "$RELAY" \
    '        reply = kernelReply(502,
                            {{"error", "no reply from P4 proxy"},' \
    '        reply = kernelReply(504,
                            {{"error", "P4 proxy timed out"},' \
    'P4PassthroughUnreachable.AHalfSentReplyIsA502NotTheProxysAnswer'

mutate "29. the reply size limit is lifted" \
    "$RELAY" \
    '        m_parser->body_limit(kMaxReplyBytes);' \
    '        m_parser->body_limit(boost::none);' \
    'P4PassthroughUnreachable.AReplyOverTheSizeLimitIsUnreadableNotUnreachable'

mutate "30. the 404 stops naming the routes that exist" \
    "$RELAY" \
    '                             {"routes", routeList()}}));' \
    '                             {"routes_", routeList()}}));' \
    'P4PassthroughAllowlist.APathOutsideTheFiveIsNotRelayed'

# --- only the five, with their methods, on a P4 fabric ------------------------------------------

mutate "12. any path under /ndt/p4 is relayed" \
    "$RELAY" \
    '        if (!named)
        {
            route.match = RouteMatch::NotAllowlisted;
            return route;
        }
' \
    '        (void)named;
' \
    'P4PassthroughAllowlist.APathOutsideTheFiveIsNotRelayed'

mutate "13. a name is not checked to be one segment" \
    "$RELAY" \
    '                if (!isPlainSegment(path.substr(prefix.size())))' \
    '                if (false && !isPlainSegment(path.substr(prefix.size())))' \
    'P4PassthroughAllowlist.APathOutsideTheFiveIsNotRelayed'

mutate "14. a name of . is accepted" \
    "$RELAY" \
    '    if (name.empty() || name == "." || name == "..")' \
    '    if (name.empty() || name == "..")' \
    'P4PassthroughAllowlist.APathOutsideTheFiveIsNotRelayed'

mutate "15. a name with a backslash is accepted" \
    "$RELAY" \
    '    return name.find_first_of("/%\\") == std::string_view::npos;' \
    '    return name.find_first_of("/%") == std::string_view::npos;' \
    'P4PassthroughAllowlist.APathOutsideTheFiveIsNotRelayed'

mutate "16. a named read takes any method" \
    "$RELAY" \
    '        if (method != http::verb::get)
        {
            route.match = RouteMatch::MethodNotAllowed;' \
    '        if (false)
        {
            route.match = RouteMatch::MethodNotAllowed;' \
    'P4PassthroughAllowlist.AnAllowlistedPathWithTheWrongMethodIsA405AndNotRelayed'

mutate "17. the fabric is not checked" \
    "$RELAY" \
    '    if (!p4Fabric)
' \
    '    if (false)
' \
    'P4PassthroughFabric.OnAFabricWithNoP4SwitchEveryRouteIsRefusedAndNothingIsRelayed'

mutate "18. the prefix test takes /ndt/p4_anything" \
    "$RELAY" \
    "            path[kP4Root.size()] == '/');" \
    '            true);' \
    'P4PassthroughAllowlist.TheRouterTestCoversOnlyTheP4Prefix'

# --- deadlines ----------------------------------------------------------------------------------

mutate "21. the table routes get only one proxy deadline and a margin" \
    "$RELAY_H" \
    'inline constexpr int kTwoRpcDeadlineSeconds = 15;' \
    'inline constexpr int kTwoRpcDeadlineSeconds = 10;' \
    'P4PassthroughUnreachable.TheDeadlinesCoverTheProxysOwnSlowestAnswers'

mutate "22. the named reads get exactly one proxy deadline" \
    "$RELAY_H" \
    'inline constexpr int kOneRpcDeadlineSeconds = 10;' \
    'inline constexpr int kOneRpcDeadlineSeconds = 5;' \
    'P4PassthroughUnreachable.TheDeadlinesCoverTheProxysOwnSlowestAnswers'

mutate "24. the named reads get the long deadline" \
    "$RELAY" \
    '        route.deadline = DeadlineClass::OneRpc;' \
    '        route.deadline = DeadlineClass::TwoRpc;' \
    'P4PassthroughUnreachable.ANamedReadIsGivenUpOnAtTheShortDeadline'

mutate "25. the table routes get the short deadline" \
    "$RELAY" \
    '        route.deadline = DeadlineClass::TwoRpc;' \
    '        route.deadline = DeadlineClass::OneRpc;' \
    'P4PassthroughUnreachable.TheTableRoutesGetTheLongDeadlineAndTheNamedReadsTheShortOne'

# --- the lab claim ------------------------------------------------------------------------------

mutate "19. the table read carries the lab claim" \
    "$RELAY" \
    '        route.isWrite = (method == http::verb::post);' \
    '        route.isWrite = true;' \
    'P4PassthroughRelay.TableEntryReadGoesOutAsAGetWithItsQuery'

mutate "26. every relayed reply carries the lab claim" \
    "$RELAY" \
    '            reply.labClaimBearing = isWrite;' \
    '            reply.labClaimBearing = true;' \
    'P4PassthroughRelay.EachNamedReadGoesOutUnderItsOwnPathWithItsQuery'

mutate "H3. the write's lab claim header is not sent" \
    "$SESSION" \
    '            res->set(kLabClaimHeader, claim);' \
    '            (void)claim;' \
    'P4PassthroughSession.TheWriteCarriesTheLabClaimAsAHeaderAndTheBodyStaysTheProxys'

mutate "H4. the lab claim is also put into the proxy's body" \
    "$SESSION" \
    '            res->set(kLabClaimHeader, claim);' \
    '            res->set(kLabClaimHeader, claim);
            json merged = json::parse(res->body(), nullptr, false);
            if (merged.is_object())
            {
                merged["lab_claim"] = labClaimJson();
                res->body() = merged.dump();
            }' \
    'P4PassthroughSession.TheWriteCarriesTheLabClaimAsAHeaderAndTheBodyStaysTheProxys'

mutate "H11. the lab claim header is not ASCII-only" \
    "$SESSION" \
    "    std::string value = claim.dump(-1, ' ', true, json::error_handler_t::replace);" \
    "    std::string value = claim.dump(-1, ' ', false, json::error_handler_t::replace);" \
    'P4PassthroughSession.ANonAsciiNoteReachesTheHeaderAsAsciiAndParsesBackUnchanged'

mutate "H12. a claim file that is not UTF-8 throws" \
    "$SESSION" \
    "    std::string value = claim.dump(-1, ' ', true, json::error_handler_t::replace);" \
    "    std::string value = claim.dump(-1, ' ', true);" \
    'P4PassthroughSession.AClaimFileThatIsNotUtf8DoesNotChangeTheProxysAnswer'

# --- the request path ---------------------------------------------------------------------------

mutate "H1. /ndt/p4 is not routed to the pass-through" \
    "$SESSION" \
    '    if (p4passthrough::isP4PassthroughTarget(m_req.target()))
    {
        startP4Passthrough();' \
    '    if (false)
    {
        startP4Passthrough();' \
    'P4PassthroughSession.OnAP4FabricTheRelayHandsBackTheProxysReply'

mutate "H2. every topology counts as a P4 fabric" \
    "$SESSION" \
    '    return m_topologyAndFlowMonitor->getSwitchKindGroups().count(SwitchKind::BMV2) > 0;' \
    '    return true;' \
    'P4PassthroughSession.OnAnOvsFabricTheRoutesAreRefusedAndNothingIsRelayed'

mutate "H5. a relayed reply with no Content-Type gets application/json" \
    "$SESSION" \
    '        res->result(reply.status);
' \
    '        res->result(reply.status);
        res->set(http::field::content_type, "application/json");
' \
    'P4PassthroughSession.AProxyReplyWithNoContentTypeHasNoneOnTheKernelsReplyEither'

mutate "H6. the relay blocks the io thread (the synchronous shape)" \
    "$SESSION" \
    '        p4passthrough::respondAsync(m_socket.get_executor(),' \
    '        finishP4Passthrough(p4passthrough::respond(m_req.method(),
                                                   std::string_view(m_req.target()),
                                                   m_req.body(),
                                                   contentType,
                                                   topologyHasP4Switch(),
                                                   m_p4ProxyHostAndPort,
                                                   m_p4Deadlines));
        return;
        p4passthrough::respondAsync(m_socket.get_executor(),' \
    'P4PassthroughSession.ARelayInFlightDoesNotHoldUpTheRestOfTheKernel'

mutate "H7. /ndt/p4 replies carry CORS" \
    "$SESSION" \
    '        res->set(http::field::server, "ndt-server");
        res->result(reply.status);' \
    '        res->set(http::field::server, "ndt-server");
        res->set(http::field::access_control_allow_origin, "*");
        res->result(reply.status);' \
    'P4PassthroughSession.NoReplyUnderP4CarriesACorsHeader'

mutate "H8. the other routes lose their CORS headers" \
    "$SESSION" \
    '    response->set(http::field::access_control_allow_origin, "*");' \
    '    (void)0;' \
    'P4PassthroughSession.AnotherKernelRouteKeepsItsCorsHeaders'

mutate "H9. the 405's Allow header is not sent" \
    "$SESSION" \
    '            res->set(http::field::allow, reply.allow);' \
    '            (void)0;' \
    'P4PassthroughSession.AWrongMethodIsA405WhoseAllowHeaderIsOnTheWire'

mutate "H10. a HEAD reply carries a body" \
    "$SESSION" \
    '        if (m_req.method() != http::verb::head)' \
    '        if (true)' \
    'P4PassthroughSession.OptionsAndHeadUnderP4AreAnsweredByThePassthroughNotThePreflight'

# --- ordering, guards, keep-alive, close-on-exec ------------------------------------------------

mutate "31. the relay starts inline, before respondAsync returns" \
    "$RELAY" \
    '        net::post(m_strand, [self = shared_from_this()] {' \
    '        net::dispatch(m_strand, [self = shared_from_this()] {' \
    'P4PassthroughOrdering.AnAnswerThatNeedsNoNetworkStillArrivesAfterRespondAsyncReturns'

mutate "32. a throw while building the reply is not turned into a 500" \
    "$RELAY" \
    '                reply = internalErrorReply(isWrite);
            }
            done(std::move(reply));' \
    '                throw;
            }
            done(std::move(reply));' \
    'P4PassthroughOrdering.AReplyTheKernelCannotBuildIsAKernel500DeliveredOnce'

mutate "33. the write's own 500 does not bear the lab claim" \
    "$RELAY" \
    '                reply = internalErrorReply(isWrite);' \
    '                reply = internalErrorReply(false);' \
    'P4PassthroughSession.AKernel500OnTheWriteStillCarriesTheLabClaim'

mutate "34. the relay's socket is left inheritable" \
    "$RELAY" \
    '            if (!utils::setCloseOnExec(socket.native_handle()))' \
    '            if (false)' \
    'P4PassthroughUnreachable.TheRelaysSocketToTheProxyIsCloseOnExec'

mutate "35. the relay waits five times its deadline" \
    "$RELAY" \
    '          m_deadline(std::chrono::steady_clock::now() + timeout),' \
    '          m_deadline(std::chrono::steady_clock::now() + 5 * timeout),' \
    'P4PassthroughUnreachable.AProxyThatNeverAnswersIsAKernel504WithinTheDeadline'

mutate "36. the named reads keep less than the pool margin" \
    "$RELAY_H" \
    'inline constexpr int kOneRpcDeadlineSeconds = 10;' \
    'inline constexpr int kOneRpcDeadlineSeconds = 6;' \
    'P4PassthroughUnreachable.TheDeadlinesCoverTheProxysOwnSlowestAnswers'

mutate "37. a request that never reached the proxy is called partly sent" \
    "$RELAY" \
    '    return proxy.connected ? "; the request was not completely sent" : "; the request was not sent";' \
    '    return "; the request was not completely sent";' \
    'P4PassthroughUnreachable.AConnectThatNeverCompletesIsA504ThatSaysNothingWasSent'

mutate "38. the 504 drops what went wrong" \
    "$RELAY" \
    '                                  secondsText(timeout) + " (" + proxy.error + ")" +' \
    '                                  secondsText(timeout) +' \
    'P4PassthroughUnreachable.AConnectThatNeverCompletesIsA504ThatSaysNothingWasSent'

mutate "39. an oversized header is reported as an oversized body" \
    "$RELAY" \
    '        if (ec == http::error::header_limit)' \
    '        if (false)' \
    'P4PassthroughUnreachable.AReplyWhoseHeaderIsTooLargeSaysSo'

mutate "H14. the section 0 mark is dumped strictly again" \
    "$SESSION" \
    "        std::string marked = body.dump(-1, ' ', false, json::error_handler_t::replace);" \
    '        std::string marked = body.dump();' \
    'P4PassthroughSession.AClaimFileThatIsNotUtf8DoesNotTakeDownTheKernelOnTheOtherWrites'

mutate "H15. the section 0 mark is strict and catches nothing again" \
    "$SESSION" \
    "        std::string marked = body.dump(-1, ' ', false, json::error_handler_t::replace);
        res.body() = std::move(marked);
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            \"lab_claim could not be added to the reply: {}\",
                            e.what());
    }
    catch (...)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), \"lab_claim could not be added to the reply\");
    }" \
    "        res.body() = body.dump();
    }
    catch (const std::bad_alloc&)
    {
    }" \
    'P4PassthroughSession.AClaimFileThatIsNotUtf8DoesNotTakeDownTheKernelOnTheOtherWrites'

mutate "H17. the JSON-error catch clause dumps strictly again" \
    "$SESSION" \
    '        response->body() =
            dumpUntrusted(json{{"error", "JSON parsing error"}, {"details", e.what()}});' \
    '        response->body() = json{{"error", "JSON parsing error"}, {"details", e.what()}}.dump();' \
    'P4PassthroughSession.ABodyWithAByteThatIsNotUtf8IsA400AndTheKernelStaysUp'

mutate "H18. replies that echo outside text are dumped strictly" \
    "$SESSION" \
    "    return j.dump(-1, ' ', false, json::error_handler_t::replace);" \
    '    return j.dump();' \
    'P4PassthroughSession.AQueryValueWithAByteThatIsNotUtf8GetsItsOwnRefusal'

mutate "H19. a relayed session is kept after its reply" \
    "$SESSION" \
    '    m_res = std::move(res);
    writeResponse();' \
    '    static std::vector<std::shared_ptr<HttpSession>> kept;
    kept.push_back(shared_from_this());
    m_res = std::move(res);
    writeResponse();' \
    'P4PassthroughSession.AClientThatLeavesMidRelayLeavesNothingBehind'

mutate "H20. the header cut does not back up to a character boundary" \
    "$SESSION" \
    '            while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80)' \
    '            while (false)' \
    'P4PassthroughSession.AnOversizedClaimNoteIsCutInTheHeaderAndTheProxysAnswerStands'

mutate "H21. the cut header value is not ASCII-only" \
    "$SESSION" \
    "            value = claim.dump(-1, ' ', true, json::error_handler_t::replace);" \
    "            value = claim.dump(-1, ' ', false, json::error_handler_t::replace);" \
    'P4PassthroughSession.AnOversizedClaimNoteIsCutInTheHeaderAndTheProxysAnswerStands'

mutate "H22. the catch-all clause dumps strictly again" \
    "$SESSION" \
    '        response->body() =
            dumpUntrusted(json{{"error", "Internal server error"}, {"details", e.what()}});' \
    '        response->body() = json{{"error", "Internal server error"}, {"details", e.what()}}.dump();' \
    'P4PassthroughSession.AnExceptionMessageCarryingRequestBytesIsA500ThatIsValidJson'

mutate "H23. a failed dispatch's controller message is kept raw" \
    "$SESSION" \
    '                                {"message", withInvalidUtf8Replaced(rec.message)}});' \
    '                                {"message", rec.message}});' \
    'DispatchStatusEndpointTest.AControllerMessageThatIsNotUtf8IsReportedNotThrownOn'

mutate "H24. a controller refusal's message is kept raw" \
    "$SESSION" \
    '                     {"error", withInvalidUtf8Replaced(result.message)},' \
    '                     {"error", result.message},' \
    'GroupMeterEndpointTest.AControllerMessageThatIsNotUtf8IsRelayedWithItsStatus'

mutate "H16. the lab claim header has no length cap" \
    "$SESSION" \
    '    if (value.size() <= kLabClaimHeaderMaxBytes)
    {
        return value;
    }
    // Too long for a header' \
    '    if (true)
    {
        return value;
    }
    // Too long for a header' \
    'P4PassthroughSession.AnOversizedClaimNoteIsCutInTheHeaderAndTheProxysAnswerStands'

mutate "H13. a relayed reply closes the connection" \
    "$SESSION" \
    '        res->keep_alive(m_req.keep_alive());' \
    '        res->keep_alive(false);' \
    'P4PassthroughSession.ARelayedReplyKeepsTheConnectionForTheNextRequest'

# --- widenings: behaviour-preserving, must stay green -------------------------------------------

widen "W1. the origin header written through a named local" \
    "$SESSION" \
    '        res->set(kOriginHeader, reply.origin);' \
    '        const std::string origin = reply.origin;
        res->set(kOriginHeader, origin);' \
    "same value, one indirection out"

widen "W2. the 404's message reworded" \
    "$RELAY" \
    '                              "proxy; this request was not sent anywhere"},' \
    '                              "proxy. This request was not sent anywhere."},' \
    "a message may be improved without breaking a test"

# --- known gaps: run and reported, never failing the gate ---------------------------------------

known_gap "L1. the lookup has no deadline of its own" \
    "$RELAY" \
    '        m_lookupTimer.expires_at(m_deadline);' \
    '        m_lookupTimer.expires_at(std::chrono::steady_clock::time_point::max());' \
    "no case makes getaddrinfo hang: that needs a resolver seam this code does not have"

known_gap "G1. one relay step runs outside guarded()" \
    "$RELAY" \
    '                             self->guarded([&] { self->onRead(e); });' \
    '                             self->onRead(e);' \
    "no relay step has a reachable throw: Beast's fields::set throws only above 65533 bytes, and the request's Content-Type is held under 8 KiB by the session's parser"

known_gap "G4. the read handler loses its last catch" \
    "$SESSION" \
    '    try
    {
        handleRequest();
    }' \
    '    handleRequest();
    try
    {
    }' \
    "with the replies dumped safely nothing reachable throws out of handleRequest; H17 and H18 are caught with or without this catch"

known_gap "G2. the section 0 mark loses its own catch" \
    "$SESSION" \
    '    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "lab_claim could not be added to the reply: {}",
                            e.what());
    }
    catch (...)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "lab_claim could not be added to the reply");
    }' \
    '    catch (const std::bad_alloc&)
    {
    }' \
    "with the replacing dump nothing in attachLabClaimIfWrite has a reachable throw; H15 is the strict dump without the catch, and that is caught"

# --- restore and verify -------------------------------------------------------------------------

restore
echo
echo "restoring and rebuilding the pristine tree:"
if ! build; then
    echo "  REFUSE: the restored tree does not build. The working tree may be damaged."
    exit 2
fi
DIRTY=0
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  🔴 NOT RESTORED: $f differs from its pre-run snapshot."
        DIRTY=1
    fi
done
[[ $DIRTY -eq 0 ]] && echo "  ok       all ${#FILES[@]} sources byte-identical to the pre-run snapshot"
FINAL_RED=$(red_tests)
if [[ -n "$FINAL_RED" ]]; then
    echo "  🔴 the restored tree is RED: $FINAL_RED"
    DIRTY=1
fi

echo
echo "================================================================"
printf 'mutations : %d\n' "$MUTATIONS"
printf 'survivors : %d\n' "$SURVIVORS"
printf 'widenings : %d green of %d\n' "$((WIDENINGS - WIDENINGS_RED))" "$WIDENINGS"
printf 'known gaps: %d (reported above, not counted), %d stale\n' "$KNOWN_GAPS" "$KNOWN_GAPS_STALE"
echo "================================================================"

[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVORS -eq 0 && $WIDENINGS_RED -eq 0 && $KNOWN_GAPS_STALE -eq 0 ]] || exit 1
echo "all mutations caught, all widenings green"
exit 0
