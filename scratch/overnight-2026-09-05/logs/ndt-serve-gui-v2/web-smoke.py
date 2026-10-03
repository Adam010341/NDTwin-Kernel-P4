# Smoke run of the v2 page (tools/ndt_serve/static as built) in headless Chrome against the stub
# server of tests/python. A worker's observation, not a gate: run only under the build guard.
# [Co-developed with claude code -- Adam]
import json
import os
import re
import sys
import tempfile
import time

WT = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927"
sys.path.insert(0, WT + "/tests/python")
sys.path.insert(0, WT + "/tests/browser")
import test_ndt_serve_gui as gui  # noqa: E402
import cdp_pipe  # noqa: E402

IDLE = "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      nothing\n"
MEAS = "lab\n  claim          someone -- 10m left (until 23:59:00)\n  measuring      iperf3 (pid 4242)\n"
FAILS = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (" -- " + repr(detail)[:300] if detail != "" else ""), flush=True)
    if not ok:
        FAILS.append(name)


def lab_reads(s):
    return len(re.findall(r'"GET /api/v1/lab ', gui.base._read(s.out + ".err")))


def body(p, name):
    return p.eval("document.body.dataset[%s] || null" % json.dumps(name))


def el(p, expr):
    return p.eval(expr)


s = gui.GuiServe().start()
s.behave(status={"stdout": IDLE}, apps_status={"stdout": "energy  stopped\n"}, claim={"stdout": "claimed\n", "sleep": 1})
prof = tempfile.mkdtemp(prefix="chrome-profile-", dir=s.tmp)
c = cdp_pipe.Chrome(prof, env=dict(os.environ, HOME=s.home))
try:
    p = c.page()
    url = open(os.path.join(s.conf(), "url")).read().strip()
    p.navigate(url)
    p.wait_for("document.body.dataset.loaded", 20)
    check("loaded=yes", body(p, "loaded") == "yes", body(p, "loaded"))
    check("session=ok", body(p, "session") == "ok", body(p, "session"))
    check("href has no fragment", body(p, "href") == "http://127.0.0.1:%d/" % s.port, body(p, "href"))
    check("location has no fragment", "#" not in el(p, "location.href"), el(p, "location.href"))
    check("storage empty", json.loads(body(p, "storage") or "null") == {"local": 0, "session": 0, "cookie": ""},
          body(p, "storage"))
    check("csp violations 0", body(p, "cspViolations") == "0", body(p, "cspViolations"))
    check("refresh running", body(p, "refresh") == "running", body(p, "refresh"))
    check("title", el(p, "document.title") == "ndt serve")
    check("h1 rendered (no error boundary)", el(p, "document.querySelector('h1') && document.querySelector('h1').textContent") == "ndt serve")
    wg = el(p, "(() => { const a = document.getElementById('open-webgui'); return a && [a.href, a.target, a.rel]; })()")
    check("open-webgui", wg == ["http://localhost:3000/", "_blank", "noopener noreferrer"], wg)
    mn = el(p, "(() => { const a = document.getElementById('open-manual'); return a && [a.getAttribute('href'), a.target, a.rel]; })()")
    check("open-manual", mn == ["./manual.html", "_blank", "noopener noreferrer"], mn)
    check("lab-claim verbatim", el(p, "document.getElementById('lab-claim').textContent") ==
          "yours -- 30m left (until 23:59:00)", el(p, "document.getElementById('lab-claim').textContent"))
    check("lab-yours", el(p, "document.getElementById('lab-yours').dataset.yours") == "yes")
    check("declared row hidden", el(p, "document.getElementById('lab-declared-row').hidden") is True)
    check("apps-out", "energy  stopped" in el(p, "document.getElementById('apps-out').textContent"))
    check("ndt calls at load are status + apps status only",
          sorted(set(" ".join(r["argv"]) for r in s.calls())) == ["apps status", "status"],
          [r["argv"] for r in s.calls()])
    check("tab-lab panel shown", el(p, "document.getElementById('panel-lab').hidden") is False)
    check("other panels hidden", el(p, "['actions','apps','jobs','cells'].every(t => document.getElementById('panel-' + t).hidden)"))

    # claim: plain, no typing
    p.click("tab-actions")
    check("actions panel shown", el(p, "document.getElementById('panel-actions').hidden") is False)
    check("claim-min default", el(p, "document.getElementById('claim-min').value") == "30")
    p.click("do-claim")
    p.wait_for("document.getElementById('confirm').open && !document.getElementById('c-go').disabled", 20)
    check("claim dialog ready", el(p, "document.getElementById('confirm').dataset.phase") == "ready")
    check("focus on cancel", el(p, "document.activeElement.id") == "c-cancel", el(p, "document.activeElement.id"))
    argv = el(p, "[...document.querySelectorAll('#c-argv code')].map(e => e.textContent)")
    check("argv from dry run", argv[1:] == ["claim", "30"], argv)
    check("typed row hidden for claim", el(p, "document.getElementById('c-typed-row').hidden") is True)
    p.focus("c-go")
    p.key("Enter")
    time.sleep(1)
    check("Enter on Confirm does not confirm", el(p, "document.getElementById('confirm').open") is True)
    check("no claim job yet", [r for r in s.calls() if r["argv"][:1] == ["claim"]] == [])
    p.click("c-go")
    p.wait_for("document.getElementById('actions-answer').textContent.length > 0", 20)
    ans = el(p, "document.getElementById('actions-answer').textContent")
    check("answer 202", ans.startswith("202"), ans)
    check("dialog closed", el(p, "document.getElementById('confirm').open") is False)
    check("closed dialog keeps nothing", el(p, "[document.getElementById('confirm').dataset.phase,"
          " document.getElementById('c-note').textContent, document.getElementById('c-argv').textContent]") ==
          ["closed", "", ""])
    p.wait_for("!document.getElementById('job').hidden", 10)
    p.wait_for("document.getElementById('job-stdout').textContent.includes('claimed')", 20)
    check("job log read", True)
    p.wait_for("document.getElementById('job-following').textContent.includes('沒有')", 20)
    check("log following stopped after the job ended", True)
    jid = el(p, "document.getElementById('job-id').dataset.fullId")
    short = el(p, "document.getElementById('job-id').textContent")
    check("short id rule", re.fullmatch(r"[0-9]{4}·[0-9a-f]{6}", short or "") is not None and
          jid.endswith(short[-6:]) and jid[9:13] == short[:4], (jid, short))
    check("short id title", el(p, "document.getElementById('job-id').title") == jid)
    claims = [r for r in s.calls() if r["argv"][:1] == ["claim"]]
    check("exactly one claim ran", len(claims) == 1, claims)

    # up: typed. The wait below is the one that went red on the first build (a stale note from the
    # claim dialog satisfied it while the up dialog was still reading).
    p.click("do-up")
    p.wait_for("document.getElementById('confirm').open && document.getElementById('c-note').textContent.length > 0", 20)
    check("up dialog is ready when its note shows", el(p, "document.getElementById('confirm').dataset.phase") == "ready",
          el(p, "document.getElementById('confirm').dataset.phase"))
    check("typed row shown for up", el(p, "document.getElementById('c-typed-row').hidden") is False)
    check("word is up", el(p, "document.getElementById('c-word').textContent") == "up")
    check("confirm off before typing", el(p, "document.getElementById('c-go').disabled") is True)
    p.focus("c-typed")
    p.type("u")
    time.sleep(0.3)
    check("confirm off on a partial word", el(p, "document.getElementById('c-go').disabled") is True)
    p.type("p")
    time.sleep(0.3)
    check("confirm on after typing", el(p, "document.getElementById('c-go').disabled") is False)
    p.click("c-cancel")
    time.sleep(0.3)
    check("cancel closes", el(p, "document.getElementById('confirm').open") is False)
    check("no up ran", [r for r in s.calls() if r["argv"][:1] == ["up"]] == [])
    # reopened: the typed word starts empty again
    p.click("do-up")
    p.wait_for("document.getElementById('confirm').dataset.phase === 'ready'", 20)
    check("typed word cleared on reopen", el(p, "document.getElementById('c-typed').value") == "" and
          el(p, "document.getElementById('c-go').disabled") is True)
    p.key("Escape")
    time.sleep(0.3)
    check("Escape closes", el(p, "document.getElementById('confirm').open") is False)

    # job panel close
    p.click("job-close")
    check("job panel hidden after close", el(p, "document.getElementById('job').hidden") is True)

    # jobs tab
    p.click("tab-jobs")
    rows = el(p, "document.querySelectorAll('#jobs-table tbody tr').length")
    check("jobs table has the claim", rows >= 1, rows)

    # cells tab (no grid in this stub: an error line, no crash)
    p.click("tab-cells")
    time.sleep(2)
    check("cells tab shows", el(p, "document.getElementById('panel-cells').hidden") is False)
    check("legend has four buttons", el(p, "document.querySelectorAll('#cells-legend dt').length") == 4)

    # hidden -> paused-hidden -> visible -> running
    q = c.page()
    time.sleep(0.5)
    check("first page hidden", el(p, "document.visibilityState") == "hidden")
    p.wait_for("document.body.dataset.refresh === 'paused-hidden'", 15)
    n0 = lab_reads(s)
    time.sleep(12)
    check("no /lab while hidden", lab_reads(s) == n0, (n0, lab_reads(s)))
    p.activate()
    p.wait_for("document.visibilityState === 'visible'", 10)
    p.wait_for("document.body.dataset.refresh === 'running'", 15)
    time.sleep(1)
    check("one read on coming back", lab_reads(s) >= n0 + 1, (n0, lab_reads(s)))
    n1 = lab_reads(s)
    time.sleep(11)
    check("timer ticks while visible", lab_reads(s) >= n1 + 1, (n1, lab_reads(s)))

    # measuring -> paused-measuring, only 立即更新 resumes
    s.behave(status={"stdout": MEAS}, apps_status={"stdout": "energy  stopped\n"})
    p.click("refresh-now")
    p.wait_for("document.body.dataset.refresh === 'paused-measuring'", 20)
    check("banner", "已暫停（量測中）" in el(p, "document.getElementById('refresh-state').textContent"),
          el(p, "document.getElementById('refresh-state').textContent"))
    n2 = lab_reads(s)
    time.sleep(12)
    check("no /lab while measuring", lab_reads(s) == n2, (n2, lab_reads(s)))
    q2 = c.page()
    time.sleep(0.5)
    p.activate()
    time.sleep(2)
    check("stays paused-measuring after visible", body(p, "refresh") == "paused-measuring", body(p, "refresh"))
    check("no read on coming back while measuring", lab_reads(s) == n2, (n2, lab_reads(s)))
    # a write while measuring is typed, and claim first for up
    p.click("tab-actions")
    p.click("do-release")
    p.wait_for("document.getElementById('confirm').dataset.phase === 'ready'", 20)
    check("release typed while measuring", el(p, "document.getElementById('c-typed-row').hidden") is False)
    p.click("c-cancel")
    p.click("do-up")
    p.wait_for("document.getElementById('confirm').dataset.phase === 'ready'", 20)
    bl = el(p, "document.getElementById('c-blockers').textContent")
    check("claim first for up under a foreign claim", "claim" in bl, bl)
    p.focus("c-typed")
    p.type("up")
    time.sleep(0.3)
    check("confirm stays off with a blocker", el(p, "document.getElementById('c-go').disabled") is True)
    p.click("c-cancel")
    # 立即更新 while still measuring: one read, stays paused
    n3 = lab_reads(s)
    p.click("refresh-now")
    time.sleep(3)
    check("立即更新 reads once while measuring", lab_reads(s) == n3 + 1, (n3, lab_reads(s)))
    check("and stays paused", body(p, "refresh") == "paused-measuring", body(p, "refresh"))
    s.behave(status={"stdout": IDLE}, apps_status={"stdout": "energy  stopped\n"})
    p.click("refresh-now")
    p.wait_for("document.body.dataset.refresh === 'running'", 20)
    check("立即更新 resumes when nothing measures", True)
    check("csp violations still 0", body(p, "cspViolations") == "0", body(p, "cspViolations"))
    check("storage still empty", json.loads(body(p, "storage") or "null") == {"local": 0, "session": 0, "cookie": ""})
    tok = s.token()
    check("token not in DOM", tok not in el(p, "document.documentElement.outerHTML"))
    trades = re.findall(r'"POST /api/v1/session ', gui.base._read(s.out + ".err"))
    check("one POST /session", len(trades) == 1, len(trades))

    # the manual: no script, styled by app.css, CSP-clean
    mst = s.request("GET", "/manual.html", token=None)[0]
    if mst != 200:
        print("NOTE manual not checked: the server answers %d for /manual.html (serve.py's STATIC table "
              "does not list it yet)" % mst, flush=True)
    else:
        m = c.page()
        m.navigate("http://127.0.0.1:%d/manual.html" % s.port)
        st = m.eval("document.title")
        check("manual served", st == "ndt serve 使用手冊", st)
        check("manual has no script", m.eval("document.scripts.length") == 0)
        check("manual h2 styled", m.eval("getComputedStyle(document.querySelector('h2')).color") == "rgb(25, 118, 210)",
              m.eval("document.querySelector('h2') && getComputedStyle(document.querySelector('h2')).color"))
finally:
    left = c.close()
    print("chrome leftovers:", left, flush=True)
    s.close()
print("SMOKE %s: %d failed %s" % ("OK" if not FAILS else "RED", len(FAILS), FAILS), flush=True)
sys.exit(1 if FAILS else 0)
