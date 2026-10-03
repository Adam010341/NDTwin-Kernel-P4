#!/usr/bin/env python3
# patch_r4_status.py <worktree> -- round 4 item 1: the external status cell and M28's anchor.
import os
import sys

wt = sys.argv[1]


def patch(rel, pairs):
    p = os.path.join(wt, rel)
    s = open(p).read()
    for old, new in pairs:
        assert s.count(old) == 1, (rel, old[:70])
        s = s.replace(old, new)
    open(p, "w").write(s)


patch("tests/shell/test_ndt_app_package.sh", [
    ('''PKG_FOREIGN="$FIX/packages/foreign"; mkpkg "$PKG_FOREIGN" ndtwin 4 4 firewall
''', '''PKG_FOREIGN="$FIX/packages/foreign"; mkpkg "$PKG_FOREIGN" ndtwin 4 4 firewall
# [Co-developed with claude code -- Adam] An external control plane on its OWN pipeline --
# exercises/p4runtime's shape, the 3 external arms of live-p1/06.
PKG_EXT_OWN="$FIX/packages/three-ext-own"; mkpkg "$PKG_EXT_OWN" external 3 3 advanced_tunnel
'''),
    ('''hasnt "🔴 and the shortfall is NOT a --check problem"     "proxy reports 4 destination paths, want" "$OUT"
check "  so --check still exits 0"                        "0" "$(rc_of "$OUT")"
''', '''hasnt "🔴 and the shortfall is NOT a --check problem"     "proxy reports 4 destination paths, want" "$OUT"
check "  so --check still exits 0"                        "0" "$(rc_of "$OUT")"
# [Co-developed with claude code -- Adam] Adam's 09-28 ruling: an external control plane on its
# own pipeline reports NO path (its forwarding is its controller's), so the row says none is
# expected there -- and does not call the number the twin's guess, which it no longer is.
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_EXT_OWN"); up_p4")"
OUT="$(run_status --check "$PROXY_STUBS")"
has   "🔴 an external plane on its own pipeline expects no path" "4 destination paths reported; none expected -- an external control plane on dpid 1" "$OUT"
hasnt "  and does not call its count the twin's guess"   "the twin's guess" "$OUT"
hasnt "  nor a --check problem"                          "proxy reports 4 destination paths, want" "$OUT"
'''),
])

m28_old = '''            foreign:*)
                echo "  ${paths:-?} destination paths reported; not a count of installed routes -- the package's program on dpid ${pkgpipe#foreign:}, proxy skipped lldp_discovery (they are shortest paths over the package's declared links: the twin's guess, whether or not the routes are NDTwin's)"
'''
m28_old_new = '''            foreign:*)
                if [[ "$pkgmode" == external ]]; then
'''
m28_new = m28_old.replace("foreign:*)", "never-taken:*)")
m28_new_new = m28_old_new.replace("foreign:*)", "never-taken:*)")
patch("tests/shell/mutate_ndt_app_package.sh", [
    (m28_old, m28_old_new),
    (m28_new, m28_new_new),
])

# M28b: the external branch of the status row is never taken -- an external plane's 0 is read
# as a guess over the declared links again.
anchor = '''check_fires "M28: status wants paths nobody was ever going to install" m28 \\
            "🔴 a package fabric is told the count is not a reading" \\
            "🔴 and the shortfall is NOT a --check problem"
'''
patch("tests/shell/mutate_ndt_app_package.sh", [(anchor, anchor + '''
# [Co-developed with claude code -- Adam] M28b (Adam's 09-28 ruling): the status row's external
# branch is never taken, so an external control plane on its own pipeline is told its count is
# the twin's guess over the declared links -- the guess the proxy no longer makes there.
cat > "$A/m28b.old" <<'EOF'
                if [[ "$pkgmode" == external ]]; then
EOF
cat > "$A/m28b.new" <<'EOF'
                if [[ "$pkgmode" == never-external ]]; then
EOF
check_fires "M28b: an external plane's no-path row is read as a guess" m28b \\
            "🔴 an external plane on its own pipeline expects no path"
''')])
print("ok")
