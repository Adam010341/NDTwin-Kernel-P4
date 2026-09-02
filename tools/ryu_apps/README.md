# tools/ryu_apps

- **What**: `rest_topology_bounded.py` is ryu 4.34's stock `ryu/app/rest_topology.py` (sha256 `099104dd…1522`) with `rest_topology_bounded.patch` applied; `tools/test_workflow/stack.sh` loads it *instead of* `ryu.app.rest_topology` — never both, or `/v1.0/topology/*` is registered twice.
- **Why**: doc/KNOWN-ISSUES.md A-2. Upstream the three handlers block forever in `app_manager.send_request` → `reply_q.get()`, so a wedged `ryu.topology.switches` makes them accept a connection and never answer (HTTP 000). The patch bounds each at 3 s and returns **503 with an empty body** — empty because `utils::execCommand` discards curl's exit status, so the body is the only channel to the kernel; 3 s because it must stay under the kernel's `--max-time 5` or the client aborts first and nothing gets logged.
- **Refresh from upstream**: `cp "$(python -c 'import ryu.app,os;print(os.path.dirname(ryu.app.__file__))')/rest_topology.py" tools/ryu_apps/rest_topology_bounded.py && patch tools/ryu_apps/rest_topology_bounded.py < tools/ryu_apps/rest_topology_bounded.patch`, then re-run `tests/python/test_ryu_rest_topology_bounded.py` and `tests/shell/mutate_ryu_rest_topology_bounded.sh`. If the patch rejects, upstream moved: update the sha256 in the vendored file's header too.

[Co-developed with claude code -- Adam]
