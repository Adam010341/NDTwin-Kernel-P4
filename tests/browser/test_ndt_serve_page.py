#!/usr/bin/env python3
"""ndt serve's page (v2: React, built into tools/ndt_serve/static) in a real headless Chrome:
SCOPE-v2 section 5, one named case per guarantee (doc/audit/2026-09-27_ndt-serve-gui/SCOPE-v2.md).

[Co-developed with claude code -- Adam]

What only a browser can show, because it is about what the page DOES once it runs, asserted from
what Chrome reports (tests/browser/cdp_pipe.py, the DevTools protocol over a pipe) and from what
the server and the stub ndt recorded -- never from the page's word alone where the server has one:

  the token      not in the DOM (outerHTML), localStorage, sessionStorage, document.cookie,
                 indexedDB.databases(), nor in any file of the Chrome profile (UTF-8 and UTF-16LE,
                 after Chrome has ended and flushed it)                              Load, Profile
  the key        traded exactly once (the server log holds one POST /api/v1/session), and gone
                 from location.href; a used key and a URL with no key open nothing          Load
  loading        writes nothing: only GETs and the one key trade in the server log, and the stub
                 ndt sees only `status` and `apps status`                                   Load
  CSP            <body data-csp-violations> is "0" after the page has been used             Load
  confirm        how hard the dialog asks is the server's (confirm_policy, needs_own_claim), plus
                 the page's measuring rule; claim first under somebody else's claim, `claim none`
                 or no claim row; the exact typed word; focus starts on Cancel, Enter on Confirm
                 does nothing, a double click posts once                                 Confirm
  dry run        the argv in the dialog is the argv the server's dry run answered (read from
                 Chrome's own network record), for an app start too, and the write is posted after
                 that dry run                                                            Confirm
  auto-refresh   10 s while shown and idle; no tick while measuring, while a measurement is
                 declared, or while the page is hidden (a second target really hides it), and a
                 read as soon as it is shown again; 立即更新 while measuring keeps the pause;
                 during a measuring pause a probe reads /measuring alone once a minute (`ndt
                 status --measuring`, never /lab), and the one that reads nothing measuring and
                 nothing declared brings the tick back; shown again while measuring, one probe
                 60 s later; hidden, nothing at all                                     Refresh
  probe timeout  a probe stopped at --read-timeout keeps the pause, and the next one ends it
                                                                                 ProbeTimeout
  job log        2 s while the job runs; nothing after Close, after the job ended, or while the
                 page is hidden                                                           JobLog

    JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh python3 tests/browser/test_ndt_serve_page.py
    ... python3 tests/browser/test_ndt_serve_page.py Confirm.test_a_double_click_posts_once   # one case
    NDT_SERVE_UNDER_TEST=/tmp/x/tools/ndt_serve ...   (a mutant tree: tests/shell/mutate_ndt_serve_page.sh)

WHY tests/browser/ AND NOT tests/python/: CI's L1 lane globs tests/python/test_*.py and fails any
suite that skips; CI has no Chrome, so every case here would skip there.

WHEN IT SKIPS (every case, with the reason): google-chrome is not installed; or it is not running
inside tools/build_guard/guarded_build.sh (NDTWIN_GUARD_HELD unset) -- systemd-oomd on this laptop
has killed Adam's own application under memory pressure, and a browser can make some. A skipped
case proves nothing, which is why the mutation gate refuses a baseline with a skip in it.

HOW A CASE RUNS: ONE Chrome per test class (cdp_pipe.Chrome: its own session and process group, a
profile, HOME and TMPDIR inside the class's temp dir, no NDT_* and no XDG_* from the shell). Each
case gets its own stub server (test_ndt_serve_gui.GuiServe: stub ndt recording to calls.jsonl, no
real ndt, no lab, its own HOME) and its own page -- a new target, which is the visible one; the case's
targets are closed when it ends. The page URL is the one the server wrote to its 0600 `url` file.
When the class ends, Chrome is closed and nothing may be left in its session or group or naming
its profile ("chrome leftovers (<class>): N" on stderr; N > 0 fails the class). Only the group
cdp_pipe created is ever signalled; no process is looked up by name.

TIME: the auto-refresh (10 s), the probe (60 s) and the job log (2 s) are measured in real time --
a window just longer than the interval for "nothing was read", the spec's 25 s for "it does read".
No virtual time: it stops while a fetch is pending, which is exactly what is being counted. The
whole suite is about 12 minutes, most of it the five probe cases (1 to 2.5 min each).

PROVENANCE: run as a script, it prints its own header first (date, argv, git HEAD and how many
paths are uncommitted, the python and Chrome it runs, the page's files with their sha256) and, at
the end, how many processes still name a temp dir it made.

THE PAGE'S HOOKS (web/src/testhooks.ts): data-href, data-session (ok | refused | no-key),
data-storage, data-loaded (yes | no-session | no-meta), data-csp-violations, data-refresh. They
are read where they ARE the guarantee (the CSP counter) or to know the page has finished loading;
everything else is read from Chrome or from the server's log.

THE SERVER'S LOG (serve.py log_message, stderr): `HH:MM:SS "GET /api/v1/lab HTTP/1.1" 200 -`, one
line per request when its answer starts. A dry run and a real write are the same POST line;
they differ by status: a dry run answers 200, a write that starts a job 202. The cases never send
their own requests to a path they count while counting it (a job's end is read from its exit.json).

tests/shell/mutate_ndt_serve_page.sh is this file's mutation gate.
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tests", "python"))
sys.path.insert(0, HERE)
import cdp_pipe  # noqa: E402
import test_ndt_serve as base  # noqa: E402 -- the stub ndt; honours NDT_SERVE_UNDER_TEST
import test_ndt_serve_gui as gui  # noqa: E402 -- GuiServe: a Serve with its own HOME and url file
from test_ndt_serve import tearDownModule  # noqa: E402,F401 -- the same leftover-server sweep

CHROME = shutil.which("google-chrome")
GUARD_HELD = os.environ.get("NDTWIN_GUARD_HELD", "")
NO_CHROME = "google-chrome is not installed (CI has none): the page cases need a real browser"
NO_GUARD = ("not inside tools/build_guard/guarded_build.sh: headless Chrome runs only under the guard on "
            "this laptop (systemd-oomd) -- JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh "
            "python3 tests/browser/test_ndt_serve_page.py")
CHROME_XDG = ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME")
# Chrome's SingletonSocket is a unix socket at $TMPDIR/com.google.Chrome.XXXXXX/SingletonSocket, and
# a path longer than sun_path holds is FATAL at start ("Socket path too long", measured 10-01 with a
# 107-byte TMPDIR): every case would then fail on a broken pipe, saying nothing about the page.
SOCKET_PATH_MAX = 107

# `ndt status` as the stub answers it. The server reads three rows (claim, measuring, declared);
# the own-claim form is ndt's claim_line (serve.py OWN_CLAIM).
IDLE = "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      nothing\n"
MEASURING = "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      iperf3 (pid 4242)\n"
DECLARED = ("lab\n  claim          yours -- 30m left (until 23:59:00)\n"
            "  declared       iperf3 matrix   (claim measuring=; 'ndt check' refuses while set)\n"
            "  measuring      nothing\n")
FOREIGN = "lab\n  claim          someone -- 10m left (until 23:59:00)\n  measuring      nothing\n"
NOTHING_ROWS = "  measuring      nothing\n"    # `ndt status --measuring` with nothing measuring
CLAIM_NONE = "lab\n  claim          none\n  measuring      nothing\n"      # ndt claim_line, no claim file
NO_CLAIM_ROW = "lab\n  measuring      nothing\n"

REFRESH_S = 10            # web/src/hooks/useAutoRefresh.ts REFRESH_INTERVAL_MS
JOB_LOG_S = 2             # web/src/hooks/useJobLog.ts JOB_LOG_INTERVAL_MS
QUIET_S = REFRESH_S + 2   # "nothing was read": one interval and a margin
LOG_QUIET_S = 2 * JOB_LOG_S + 1.5
READING_S = 25            # SCOPE-v2 section 5: >= 2 reads in about 25 s
PROBE_S = 60              # useAutoRefresh.ts PROBE_INTERVAL_MS: /measuring alone, during a measuring pause (Q6)

REQUEST_RE = re.compile(r'"([A-Z]+) (\S+) HTTP/[0-9.]+" (\d{3})')
TICK_RE = re.compile(r"/api/v1/(lab|apps|health|jobs|measuring)")   # what a tick reads, and the probe
with open(os.path.join(REPO, "tools", "ndt_serve", "web", "src", "i18n", "zh.json"), encoding="utf-8") as _f:
    CLAIM_FIRST = json.load(_f)["ndtServe"]["confirm"]["blockClaim"]

DIALOG_JS = """(() => {
  const $ = (id) => document.getElementById(id);
  const d = $('confirm');
  return {open: d.open, phase: d.dataset.phase, typed: !$('c-typed-row').hidden, word: $('c-word').textContent,
          go_disabled: $('c-go').disabled, focus: document.activeElement ? document.activeElement.id : null,
          blockers: [...document.querySelectorAll('#c-blockers li')].map((e) => e.textContent),
          argv: [...document.querySelectorAll('#c-argv code')].map((e) => e.textContent)};
})()"""
READY_JS = "document.getElementById('confirm').open && document.getElementById('confirm').dataset.phase === 'ready'"
CLOSED_JS = "!document.getElementById('confirm').open && document.getElementById('confirm').dataset.phase === 'closed'"
STORAGE_JS = """(async () => {
  const dump = (s) => { const o = {}; for (let i = 0; i < s.length; i++) o[s.key(i)] = s.getItem(s.key(i)); return o; };
  return {local: dump(localStorage), session: dump(sessionStorage), cookie: document.cookie,
          indexeddb: await indexedDB.databases()};
})()"""
BOX_JS = """(() => { const e = document.getElementById(%s); if (!e) return null; e.scrollIntoView({block: 'center'});
  const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2, r.width, r.height]; })()"""

OPEN_CLASSES = []   # classes whose Chrome is running -- closed in __main__'s finally on an interrupt
RUN_DIRS = []       # every temp dir this run made (Chrome's, the servers'): what a leftover would name


def describe(rows):
    return "; ".join("pid %d pgrp %d sid %d: %s" % (p, g, s, c.replace(b"\0", b" ")[:160].decode("utf-8", "replace"))
                     for p, g, s, c in rows)


def files_holding(root, secret):
    """Files under `root` holding `secret`, as UTF-8 or as UTF-16LE (how Chrome's DOM storage
    keeps a string it cannot store as Latin-1)."""
    needles = (secret.encode(), secret.encode("utf-16-le"))
    hits = []
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            try:
                with open(p, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            if any(x in data for x in needles):
                hits.append(os.path.relpath(p, root))
    return hits


def until(fn, timeout, interval=0.2):
    """fn() once it is true, or its last value when `timeout` s have passed."""
    end = time.monotonic() + timeout
    while True:
        v = fn()
        if v or time.monotonic() > end:
            return v
        time.sleep(interval)


def hook(p, name):
    return p.eval("document.body.dataset[%s] ?? null" % json.dumps(name))


def double_click(p, element_id):
    """Two real clicks on the element (press, release, press, release; clickCount 1 then 2), sent to
    Chrome back to back without waiting for any of them to be handled: as fast as a mouse can go,
    so the page gets no round trip of ours between the two in which to re-render."""
    box = p.eval(BOX_JS % json.dumps(element_id))
    if not box or box[2] == 0 or box[3] == 0:
        raise cdp_pipe.CdpError("no visible element #%s" % element_id)
    p.call("Input.dispatchMouseEvent", {"type": "mouseMoved", "x": box[0], "y": box[1]})
    pending = set()
    for kind, n in (("mousePressed", 1), ("mouseReleased", 1), ("mousePressed", 2), ("mouseReleased", 2)):
        pending.add(p.chrome.send("Input.dispatchMouseEvent", {"type": kind, "x": box[0], "y": box[1],
                                                               "button": "left", "clickCount": n}, p.session))

    def answered(m):
        if m.get("id") in pending:
            pending.discard(m["id"])
            if "error" in m:
                raise cdp_pipe.CdpError("Input.dispatchMouseEvent: %s" % m["error"].get("message"))
        return True if not pending else None
    p.chrome._pump(answered, 20)


@unittest.skipUnless(CHROME, NO_CHROME)          # outermost: its reason wins when both are missing
@unittest.skipUnless(GUARD_HELD, NO_GUARD)
class PageCase(unittest.TestCase):
    """One Chrome for the class; per case a stub server and a page of its own."""
    SERVE_EXTRA = ()          # more of serve.py's options, for a class that needs them

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="ndt-page-")    # short: Chrome's socket path is under it
        sock = os.path.join(cls.root, "com.google.Chrome.XXXXXX", "SingletonSocket")
        if len(sock.encode()) > SOCKET_PATH_MAX:
            shutil.rmtree(cls.root, ignore_errors=True)
            raise RuntimeError("TMPDIR is too long for Chrome's SingletonSocket (%d > %d bytes): %s -- use a "
                               "shorter TMPDIR" % (len(sock.encode()), SOCKET_PATH_MAX, sock))
        RUN_DIRS.append(cls.root)
        cls.home = os.path.join(cls.root, "home")
        cls.profile = os.path.join(cls.root, "chrome-profile")
        os.makedirs(cls.home)
        os.makedirs(cls.profile)
        env = {k: v for k, v in os.environ.items() if not k.startswith("NDT_")}
        env["HOME"] = cls.home
        env["TMPDIR"] = cls.root    # Chrome's own temp files (its socket, a url_fetcher dir) go with the class
        for k in CHROME_XDG:
            env.pop(k, None)
        cls.left = None
        cls.chrome = cdp_pipe.Chrome(cls.profile, env=env)
        OPEN_CLASSES.append(cls)

    @classmethod
    def end_chrome(cls):
        """Closes the class's Chrome once and answers what it left ([] for nothing)."""
        if cls.left is None:
            cls.left = cls.chrome.close()
            if cls in OPEN_CLASSES:
                OPEN_CLASSES.remove(cls)
        return cls.left

    @classmethod
    def say_leftovers(cls):
        # its own line, after the class's last case (the gate reads it)
        sys.stderr.write("chrome leftovers (%s): %d%s\n" % (cls.__name__, len(cls.left),
                                                           (" -- " + describe(cls.left)) if cls.left else ""))

    @classmethod
    def tearDownClass(cls):
        try:
            left = cls.end_chrome()
            cls.say_leftovers()
        finally:
            shutil.rmtree(cls.root, ignore_errors=True)
        if left:
            raise AssertionError("Chrome left %d process(es) behind: %s" % (len(left), describe(left)))

    def setUp(self):
        self.s = gui.GuiServe(extra=list(self.SERVE_EXTRA))
        RUN_DIRS.append(self.s.tmp)
        self.addCleanup(self.s.close)
        self.addCleanup(self.jobs_end)          # cleanups run last-in first-out: pages, jobs, server
        self.beh = {"status": {"stdout": IDLE}, "apps_status": {"stdout": "energy  stopped\n"},
                    "claim": {"stdout": "claimed\n"}}
        self.s.behave(**self.beh)
        self.s.start()
        self.pages = []
        self.addCleanup(self.close_pages)

    # --- the stub, the server's log, the jobs on disk ---
    def stub(self, status=None, **verbs):
        """What the stub ndt answers from now on (the server reads behavior.json on every call)."""
        if status is not None:
            self.beh["status"] = {"stdout": status}
        self.beh.update(verbs)
        self.s.behave(**self.beh)

    def requests(self):
        """(method, path, status) of every request the server logged, in order."""
        return [(m.group(1), m.group(2), int(m.group(3)))
                for m in REQUEST_RE.finditer(base._read(self.s.out + ".err"))]

    def count(self, method, pattern):
        return sum(1 for m, path, _ in self.requests() if m == method and re.fullmatch(pattern, path))

    def tick_reads(self):
        """{lab, apps, health, jobs, measuring}: how often the server answered each read an auto-refresh
        tick makes, and the probe's /measuring."""
        out = {"lab": 0, "apps": 0, "health": 0, "jobs": 0, "measuring": 0}
        for m, path, _ in self.requests():
            hit = TICK_RE.fullmatch(path)
            if m == "GET" and hit:
                out[hit.group(1)] += 1
        return out

    def job_reads(self, jid):
        """GET /jobs/<id> and /jobs/<id>/log/<stream>: the job view's reads."""
        return self.count("GET", r"/api/v1/jobs/%s(?:/log/std(?:out|err)\?offset=\d+)?" % re.escape(jid))

    def posts(self, path):
        """The statuses the server answered POST /api/v1<path> with, in order (200: a dry run)."""
        return [st for m, pth, st in self.requests() if m == "POST" and pth == "/api/v1" + path]

    def job_ended(self, jid):
        return os.path.exists(os.path.join(self.s.state, "jobs", jid, "exit.json"))

    def jobs_end(self):
        until(lambda: not any(self.s.job_running_on_disk()), 20)

    def ndt_calls(self, verb):
        return [c["argv"] for c in self.s.calls() if c["argv"][:1] == [verb]]

    # --- Chrome ---
    def pause(self, seconds):
        """Real time, with Chrome's pipe read every half second (it must never fill up)."""
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            time.sleep(min(left, 0.5))
            self.chrome.call("Browser.getVersion")

    def open_page(self, url=None, network=False):
        p = self.chrome.page()
        self.pages.append(p)
        if network:
            p.call("Network.enable")
        p.navigate(url or base._read(self.s.url_file()).strip())
        return p

    def load(self, network=False):
        p = self.open_page(network=network)
        p.wait_for("document.body.dataset.loaded", 20)
        self.assertEqual(hook(p, "loaded"), "yes", "the page did not load: %r"
                         % p.eval("Object.assign({}, document.body.dataset)"))
        return p

    def close_pages(self):
        if self.left is not None:
            return
        for p in self.pages:
            try:
                self.chrome.call("Target.closeTarget", {"targetId": p.target}, timeout=10)
            except cdp_pipe.CdpError:
                pass

    def hide(self, p):
        """A second target: Chrome makes `p` really hidden (cdp_pipe's docstring). Answers the new one."""
        q = self.chrome.page()
        self.pages.append(q)
        p.wait_for("document.visibilityState === 'hidden'", 10)
        return q

    def show(self, p):
        p.activate()
        p.wait_for("document.visibilityState === 'visible'", 10)

    # --- the dialog ---
    def dialog(self, p, button, tab="actions"):
        """Opens the confirm dialog from `button` on `tab` and waits until it is ready."""
        if p.eval("document.getElementById('panel-%s').hidden" % tab):
            p.click("tab-" + tab)
        p.click(button)
        p.wait_for(READY_JS, 20)
        return p.eval(DIALOG_JS)

    def cancel(self, p):
        p.click("c-cancel")
        p.wait_for(CLOSED_JS, 10)

    def settle(self, p, seconds=0.3):
        self.pause(seconds)
        return p.eval(DIALOG_JS)

    def start_job(self, p, sleep):
        """A claim through the dialog, its stub running `sleep` s: the job panel opens and follows it."""
        self.stub(claim={"stdout": "claimed\n", "sleep": sleep})
        self.dialog(p, "do-claim")
        p.click("c-go")
        p.wait_for("!document.getElementById('job').hidden && !!document.getElementById('job-id')", 20)
        jid = p.eval("document.getElementById('job-id').dataset.fullId")
        self.assertTrue(os.path.isdir(os.path.join(self.s.state, "jobs", jid)), "the page opened job %r, which "
                        "the server does not have" % jid)
        self.assertTrue(until(lambda: self.job_reads(jid) >= 2, 10), "the job panel never read job %s" % jid)
        return jid


# --- the token, the key, loading, CSP ---------------------------------------------------------

class Load(PageCase):
    def exercise(self, p):
        """Use the page a little: every tab, and the claim dialog opened (its dry run) and cancelled."""
        for t in ("actions", "apps", "jobs", "cells", "lab"):
            p.click("tab-" + t)
        self.dialog(p, "do-claim")
        self.cancel(p)

    def test_the_key_leaves_the_address_bar(self):
        p = self.load()
        want = "http://127.0.0.1:%d/" % self.s.port
        href = p.eval("location.href")
        self.assertNotIn("#", href, "the key is still in the address bar after the page ran: %s" % href)
        self.assertEqual((href, hook(p, "href")), (want, want), "location.href, and the page's data-href")

    def test_the_key_is_traded_exactly_once(self):
        key = self.s.key()
        p = self.load()
        self.exercise(p)
        trades = self.posts("/session")
        self.assertEqual(trades, [200], "the server logged %d key trade(s) (POST /api/v1/session), not exactly one "
                         "answered 200: %r" % (len(trades), trades))
        st, j = self.s.trade(key)
        self.assertEqual((st, (j or {}).get("error")), (403, "nonce"), "the key the page traded still opens a session")

    def test_the_token_is_not_in_the_dom(self):
        key, token = self.s.key(), self.s.token()
        self.assertGreaterEqual(len(token), 40)
        p = self.load()
        self.exercise(p)
        html = p.eval("document.documentElement.outerHTML")
        self.assertNotIn(token, html, "the token is in the page's DOM")
        self.assertNotIn(key, html, "the one-time key is in the page's DOM")

    def test_the_token_is_not_in_browser_storage(self):
        token = self.s.token()
        p = self.load()
        self.exercise(p)
        st = p.eval(STORAGE_JS)
        self.assertNotIn(token, json.dumps(st), "the token is in browser storage: %r" % st)
        self.assertEqual(st, {"local": {}, "session": {}, "cookie": "", "indexeddb": []},
                         "the page left something in browser storage")
        self.assertEqual(json.loads(hook(p, "storage") or "null"), {"local": 0, "session": 0, "cookie": ""},
                         "the page's own data-storage hook")

    def test_loading_the_page_writes_nothing(self):
        p = self.load()
        self.pause(1.5)                         # anything the load still had on its way
        self.jobs_end()
        problems = []
        jobs = [os.path.basename(d) for d in sorted(os.listdir(os.path.join(self.s.state, "jobs")))] \
            if os.path.isdir(os.path.join(self.s.state, "jobs")) else []
        if jobs:
            problems.append("the server holds job(s) %r" % jobs)
        argvs = sorted(set(" ".join(c["argv"]) for c in self.s.calls()))
        if argvs != ["apps status", "status"]:
            problems.append("the stub ndt saw %r, not exactly `status` and `apps status`" % argvs)
        not_get = [r for r in self.requests() if r[0] != "GET"]
        if not_get != [("POST", "/api/v1/session", 200)]:
            problems.append("the requests other than GET were %r, not the one key trade" % not_get)
        self.assertEqual(problems, [], "loading the page wrote (data-loaded=%s)" % hook(p, "loaded"))

    def test_a_used_key_opens_nothing(self):
        url = base._read(self.s.url_file()).strip()
        first = self.load()
        self.assertEqual(hook(first, "session"), "ok")
        before = self.s.calls()
        second = self.open_page(url)
        second.wait_for("document.body.dataset.loaded", 20)
        self.assertEqual((hook(second, "session"), hook(second, "loaded")), ("refused", "no-session"),
                         "the second load of a used key opened a session")
        self.assertEqual(self.s.calls(), before, "the second load of a used key ran ndt")

    def test_a_url_without_a_key_opens_nothing(self):
        p = self.open_page("http://127.0.0.1:%d/" % self.s.port)
        p.wait_for("document.body.dataset.loaded", 20)
        self.pause(1)
        seen = (hook(p, "session"), hook(p, "loaded"), self.s.calls(), [r for r in self.requests() if r[0] != "GET"])
        self.assertEqual(seen, ("no-key", "no-session", [], []),
                         "a URL with no key: (data-session, data-loaded, ndt calls, non-GET requests)")

    def test_the_page_sees_no_csp_violation(self):
        p = self.load()
        self.exercise(p)
        n = hook(p, "cspViolations")
        self.assertEqual(n, "0", "the page counted %s CSP violation(s) (data-csp-violations)" % n)


class Profile(PageCase):
    def test_the_token_is_in_no_file_of_the_profile(self):
        token = self.s.token()
        p = self.load()
        self.dialog(p, "do-claim")
        self.cancel(p)
        self.pause(1)
        left = self.end_chrome()                # ended and flushed: what is on disk now is all of it
        self.assertEqual(left, [], "Chrome left processes behind: %s" % describe(left))
        self.assertEqual(files_holding(self.profile, token), [], "the token is in a file of the browser profile")


# --- the confirm dialog ------------------------------------------------------------------------

class Confirm(PageCase):
    def test_up_asks_for_the_typed_word(self):
        p = self.load()
        d = self.dialog(p, "do-up")
        self.assertTrue(d["typed"], "the Up dialog asks for no typed word (the server's confirm_policy says typed): "
                        "%r" % d)
        self.assertEqual((d["word"], d["blockers"], d["go_disabled"]), ("up", [], True),
                         "word, blockers, and Confirm before anything is typed")
        p.focus("c-typed")
        p.type("u")
        self.assertTrue(self.settle(p)["go_disabled"], "Confirm is on after typing only `u`")
        p.type("p")
        self.assertFalse(self.settle(p)["go_disabled"], "Confirm is still off after typing `up`")
        p.type("x")
        self.assertTrue(self.settle(p)["go_disabled"], "Confirm is on after typing `upx`")
        self.cancel(p)
        self.assertEqual((self.posts("/up"), self.ndt_calls("up")), ([200], []), "Cancel wrote")

    def test_a_claim_not_yours_puts_claim_first(self):
        self.stub(status=FOREIGN)
        p = self.load()
        d = self.dialog(p, "do-up")
        self.assertIn(CLAIM_FIRST, d["blockers"], "no \"claim first\" blocker for Up under somebody else's claim: "
                      "%r" % d)
        p.focus("c-typed")
        p.type("up")
        self.assertTrue(self.settle(p)["go_disabled"], "Confirm is on under somebody else's claim")

    def test_no_claim_puts_claim_first(self):
        # Adam 09-28: no claim at all is not yours either. `claim none` is what plain ndt status prints
        # without a claim file (claim_line); a status with no claim row at all reads as claim null.
        p = self.load()
        for status, what in ((CLAIM_NONE, "`claim none`"), (NO_CLAIM_ROW, "no claim row")):
            self.stub(status=status)
            for button, word in (("do-up", "up"), ("do-down", "down")):
                d = self.dialog(p, button)
                self.assertIn(CLAIM_FIRST, d["blockers"], "no \"claim first\" blocker for %s with %s: %r"
                              % (word, what, d))
                p.focus("c-typed")
                p.type(word)
                self.assertTrue(self.settle(p)["go_disabled"], "Confirm is on for %s with %s" % (word, what))
                self.cancel(p)
        self.assertEqual((self.ndt_calls("up"), self.ndt_calls("down")), ([], []), "a write ran")

    def test_an_app_start_shows_the_dry_run_and_claim_first(self):
        p = self.load(network=True)
        d = self.dialog(p, "app-start-energy", tab="apps")
        answers = until(lambda: self.dry_run_answers(p, "/apps/energy/start"), 10)
        self.assertEqual(len(answers), 1, "Chrome saw %d dry-run answer(s) to POST /apps/energy/start, not 1"
                         % len(answers))
        self.assertEqual((d["argv"], answers[0]["argv"][1:]), (answers[0]["argv"], ["apps", "energy"]),
                         "the app dialog's argv is not the argv the dry run answered")
        self.assertEqual((d["blockers"], d["go_disabled"]), ([], False), "an app start under your own claim")
        self.cancel(p)
        self.stub(status=FOREIGN)
        d = self.dialog(p, "app-start-energy", tab="apps")
        self.assertIn(CLAIM_FIRST, d["blockers"], "no \"claim first\" blocker for an app start under somebody "
                      "else's claim: %r" % d)
        self.assertTrue(d["go_disabled"], "Confirm is on for an app start under somebody else's claim")
        self.cancel(p)
        self.assertEqual(self.ndt_calls("apps"), [["apps", "status"]] * len(self.ndt_calls("apps")),
                         "an app start ran")

    def test_measuring_or_declared_makes_it_typed(self):
        self.stub(status=MEASURING)
        p = self.load()
        d = self.dialog(p, "do-claim")
        self.assertTrue(d["typed"], "no typed word for Claim while measuring: %r" % d)
        self.assertEqual((d["word"], d["go_disabled"]), ("claim", True), "while measuring")
        self.cancel(p)
        self.stub(status=DECLARED)
        d = self.dialog(p, "do-claim")
        self.assertTrue(d["typed"], "no typed word for Claim while a measurement is declared: %r" % d)
        self.assertEqual((d["word"], d["go_disabled"]), ("claim", True), "while a measurement is declared")

    def test_claim_asks_for_no_typed_word(self):
        p = self.load()
        d = self.dialog(p, "do-claim")
        self.assertFalse(d["typed"], "the Claim dialog asks for a typed word (the server says plain): %r" % d)
        self.assertEqual((d["blockers"], d["go_disabled"]), ([], False), "blockers, and Confirm, with nothing typed")

    def test_the_focus_starts_on_cancel(self):
        p = self.load()
        p.click("tab-actions")
        p.click("do-claim")
        p.wait_for("document.getElementById('confirm').open", 10)
        opened = p.eval("document.activeElement && document.activeElement.id")
        p.wait_for(READY_JS, 20)
        d = self.settle(p, 0.6)
        self.assertEqual((opened, d["focus"]), ("c-cancel", "c-cancel"),
                         "the focus is not on Cancel (when the dialog opened, once it was ready)")

    def test_enter_on_confirm_does_not_confirm(self):
        p = self.load()
        d = self.dialog(p, "do-claim")
        self.assertFalse(d["go_disabled"], "precondition: Confirm is on")
        p.focus("c-go")
        self.assertEqual(p.eval("document.activeElement.id"), "c-go", "precondition: Confirm has the focus")
        p.key("Enter")
        self.pause(1.5)
        self.jobs_end()
        self.assertEqual((self.posts("/claim"), self.ndt_calls("claim")), ([200], []),
                         "Enter on Confirm confirmed the write: (POST /claim statuses, ndt claim calls)")
        self.assertTrue(p.eval("document.getElementById('confirm').open"), "Enter on Confirm closed the dialog")

    def test_a_double_click_posts_once(self):
        self.stub(claim={"stdout": "claimed\n", "sleep": 1})
        p = self.load()
        self.dialog(p, "do-claim")
        double_click(p, "c-go")
        p.wait_for(CLOSED_JS, 20)
        self.pause(1.5)                         # a second POST, if there is one, has landed by now
        self.jobs_end()
        self.assertEqual((self.posts("/claim"), len(self.ndt_calls("claim"))), ([200, 202], 1),
                         "a double click on Confirm posted more than the one write: (POST /claim statuses, "
                         "ndt claim calls)")

    def test_the_dialog_shows_the_argv_the_dry_run_answered(self):
        p = self.load(network=True)
        d = self.dialog(p, "do-claim")
        answers = until(lambda: self.dry_run_answers(p, "/claim"), 10)
        self.assertEqual(len(answers), 1, "Chrome saw %d dry-run answer(s) to POST /claim, not 1" % len(answers))
        self.assertTrue(answers[0]["argv"], "the dry run answered no argv: %r" % answers[0])
        self.assertEqual(d["argv"], answers[0]["argv"], "the dialog's argv is not the argv the dry run answered")

    def test_the_write_is_posted_after_its_dry_run(self):
        p = self.load()
        shown = self.dialog(p, "do-claim")["argv"]
        p.click("c-go")
        p.wait_for(CLOSED_JS, 20)
        self.jobs_end()
        self.assertEqual(self.posts("/claim"), [200, 202], "the write was posted with no dry run before it "
                         "(POST /claim statuses in order; 200 is the dry run, 202 the write)")
        self.assertEqual(self.ndt_calls("claim"), [shown[1:]], "the write ran another argv than the dialog showed "
                         "(%r)" % shown)

    def dry_run_answers(self, p, path):
        """The JSON bodies Chrome received for the page's POSTs to /api/v1<path> that were dry runs --
        Chrome's own network record (Network.enable before the page loaded), not the page's."""
        p.eval("1")                             # read whatever events are waiting in the pipe
        posts, done, out = {}, set(), []
        for e in self.chrome.events:
            if e.get("sessionId") != p.session:
                continue
            if e.get("method") == "Network.requestWillBeSent":
                r = e["params"]["request"]
                if r["method"] == "POST" and r["url"].split("?")[0].endswith("/api/v1" + path):
                    posts[e["params"]["requestId"]] = r["url"]
            elif e.get("method") == "Network.loadingFinished":
                done.add(e["params"]["requestId"])
        for rid in posts:
            if rid in done:
                body = p.call("Network.getResponseBody", {"requestId": rid})
                j = json.loads(body["body"]) if not body.get("base64Encoded") else None
                if isinstance(j, dict) and j.get("dry_run") is True:
                    out.append(j)
        return out


# --- the auto-refresh ---------------------------------------------------------------------------

class Refresh(PageCase):
    def test_refresh_reads_while_shown_and_idle(self):
        p = self.load()
        self.assertEqual(p.eval("document.visibilityState"), "visible", "precondition: the page is shown")
        n0 = self.tick_reads()["lab"]           # the load's own read
        until(lambda: self.tick_reads()["lab"] - n0 >= 2, READING_S)
        n = self.tick_reads()["lab"] - n0
        self.assertGreaterEqual(n, 2, "%d timer read(s) of /lab in %d s of a shown page with nothing measuring"
                                % (n, READING_S))
        self.assertEqual(hook(p, "refresh"), "running")

    def paused_by_the_lab(self, status, why, refresh_now_while_measuring=False):
        self.stub(status=status)
        p = self.load()
        before = self.tick_reads()
        self.pause(QUIET_S)
        after = self.tick_reads()
        self.assertEqual(after, before, "the page read %r in %d s while %s (before %r)" % (after, QUIET_S, why, before))
        self.assertEqual(hook(p, "refresh"), "paused-measuring")
        if refresh_now_while_measuring:
            # 立即更新 reads everything once (the four reads, not the probe), and a read that is still
            # measuring keeps the pause
            p.click("refresh-now")
            want = {k: v + (k != "measuring") for k, v in after.items()}
            until(lambda: self.tick_reads() == want, 5)
            self.assertEqual(self.tick_reads(), want, "立即更新 did not read everything once")
            self.pause(REFRESH_S + 1)
            self.assertEqual((self.tick_reads(), hook(p, "refresh")), (want, "paused-measuring"),
                             "立即更新 while still measuring brought the 10 s tick back")
        # back to the 10 s tick: 立即更新 (here) or the probe (test_a_measuring_pause_probes_measuring_alone),
        # and only once nothing measures (SCOPE-v2 section 6, Adam's Q6)
        self.stub(status=IDLE)
        n = self.tick_reads()["lab"]
        p.click("refresh-now")
        p.wait_for("document.body.dataset.refresh === 'running'", 10)
        self.assertEqual(self.tick_reads()["lab"], n + 1, "立即更新 read /lab other than once")

    def test_refresh_stops_while_measuring(self):
        self.paused_by_the_lab(MEASURING, "ndt status said measuring", refresh_now_while_measuring=True)

    def test_refresh_stops_while_declared(self):
        self.paused_by_the_lab(DECLARED, "a measurement was declared")

    def probe_calls(self):
        """(`ndt status --measuring` calls, plain `ndt status` calls) the stub ndt has seen."""
        argvs = [c["argv"] for c in self.s.calls()]
        return argvs.count(["status", "--measuring"]), argvs.count(["status"])

    def test_a_measuring_pause_probes_measuring_alone(self):
        # Adam's Q6 (09-28): during a measuring pause, one probe every 60 s; 10-01: it asks only "is
        # anyone measuring" -- /measuring, `ndt status --measuring`, never /lab's plain status. The
        # probe changes nothing the tabs show, and one that reads nothing measuring brings the tick back.
        self.stub(status=MEASURING)
        p = self.load()
        t0 = time.monotonic()                   # the load's read has just ended: the probe is due at t0 + 60
        before, calls = self.tick_reads(), self.probe_calls()
        last = p.eval("document.getElementById('last-read').textContent")
        self.pause(PROBE_S + 6)
        got = self.tick_reads()
        want = dict(before, measuring=before["measuring"] + 1)
        self.assertEqual(got, want, "the measuring pause read %r in %d s, not /measuring alone once (before %r)"
                         % (got, PROBE_S + 6, before))
        self.assertEqual(self.probe_calls(), (calls[0] + 1, calls[1]),
                         "the probe ran other than one `ndt status --measuring` and no plain status")
        self.assertEqual(hook(p, "refresh"), "paused-measuring")
        self.assertEqual(p.eval("document.getElementById('last-read').textContent"), last,
                         "the probe changed the full read's time (the tabs are as old as the last full read)")
        self.assertTrue(p.eval("!!document.getElementById('last-probe')"), "the top bar does not say when it probed")
        self.stub(status=IDLE)
        deadline = 2 * PROBE_S + REFRESH_S + 6 - (time.monotonic() - t0)   # the next probe, then one tick
        self.assertTrue(until(lambda: self.tick_reads()["apps"] > before["apps"], deadline),
                        "the refresh did not resume by the next probe and a tick after nothing measured: %r"
                        % self.tick_reads())
        p.wait_for("document.body.dataset.refresh === 'running'", 5)

    def test_shown_again_while_measuring_probes_once_60_s_later(self):
        # The r2 review's test 4: hidden during a measuring pause and shown again, the page reads
        # nothing at once and exactly one /measuring about 60 s after it was shown -- no tick.
        self.stub(status=MEASURING)
        p = self.load()
        self.hide(p)
        self.pause(5)
        before = self.tick_reads()
        self.show(p)
        t_show = time.monotonic()
        self.pause(PROBE_S - 6)
        self.assertEqual(self.tick_reads(), before, "shown again while measuring, the page read before its 60 s "
                         "probe: %r (before %r)" % (self.tick_reads(), before))
        self.assertTrue(until(lambda: self.tick_reads()["measuring"] > before["measuring"],
                              t_show + PROBE_S + 6 - time.monotonic()),
                        "shown again while measuring, no probe within %d s" % (PROBE_S + 6))
        self.pause(1)
        self.assertEqual(self.tick_reads(), dict(before, measuring=before["measuring"] + 1),
                         "shown again while measuring: not exactly one probe of /measuring about 60 s later")
        self.assertEqual(hook(p, "refresh"), "paused-measuring")

    def test_a_declared_pause_is_resumed_by_the_probe(self):
        # The r2 review's test 5: a pause on a DECLARED measurement (measuring nothing) ends at the
        # probe that reads no declaration -- not only at 立即更新.
        self.stub(status=DECLARED)
        p = self.load()
        self.assertEqual(hook(p, "refresh"), "paused-measuring", "precondition: a declaration pauses the page")
        before = self.tick_reads()
        self.stub(status=IDLE)
        self.assertTrue(until(lambda: self.tick_reads()["apps"] > before["apps"], PROBE_S + REFRESH_S + 8),
                        "the declared pause did not resume by the probe and a tick: %r (before %r)"
                        % (self.tick_reads(), before))
        self.assertEqual(self.tick_reads()["measuring"], before["measuring"] + 1,
                         "the declared pause was not ended by one probe of /measuring")
        p.wait_for("document.body.dataset.refresh === 'running'", 5)

    def test_a_measuring_pause_reads_nothing_while_hidden(self):
        # The load's own read ends while the page is hidden (the stub's status is slow and the page is
        # hidden while it runs), so the pause begins hidden: no probe may be armed, none may read, and
        # being shown again arms the probe for later -- it does not read at once.
        self.beh["status"] = {"stdout": MEASURING, "sleep": 2}
        self.s.behave(**self.beh)
        p = self.open_page()
        self.assertTrue(until(lambda: any(c["argv"] == ["status"] for c in self.s.calls()), 15),
                        "the page never read the lab")
        self.hide(p)
        self.stub(status=MEASURING)
        p.wait_for("document.body.dataset.loaded", 20)
        self.assertEqual((hook(p, "loaded"), p.eval("document.visibilityState")), ("yes", "hidden"),
                         "precondition: the load ended while the page was hidden")
        before = self.tick_reads()
        self.pause(PROBE_S + 8)
        after = self.tick_reads()
        self.assertEqual(after, before, "the page read %r in %d s while measuring and hidden (before %r)"
                         % (after, PROBE_S + 8, before))
        self.show(p)
        self.pause(5)
        self.assertEqual(self.tick_reads(), after, "the page read at once when shown again while measuring")
        self.assertEqual(hook(p, "refresh"), "paused-measuring")

    def test_refresh_stops_while_hidden_and_resumes_when_shown(self):
        p = self.load()
        self.hide(p)
        self.pause(0.5)
        before = self.tick_reads()
        self.pause(QUIET_S)
        after = self.tick_reads()
        self.assertEqual(after, before, "the page read %r in %d s while the page was hidden (before %r)"
                         % (after, QUIET_S, before))
        self.show(p)
        self.assertTrue(until(lambda: self.tick_reads()["lab"] > after["lab"], 4),
                        "no read of /lab after the page was shown again")
        p.wait_for("document.body.dataset.refresh === 'running'", 5)


class ProbeTimeout(PageCase):
    """The r2 review's test 6: a probe that runs past --read-timeout, then one that answers."""
    SERVE_EXTRA = ("--read-timeout", "3")

    def test_a_probe_that_times_out_keeps_the_pause_and_the_next_one_ends_it(self):
        self.stub(status=MEASURING)
        p = self.load()
        before = self.tick_reads()
        # the probe prints `measuring  nothing` and then hangs: stopped at 3 s, it is no reading
        self.stub(**{"status --measuring": {"stdout": NOTHING_ROWS, "sleep_after": 8}})
        self.assertTrue(until(lambda: self.tick_reads()["measuring"] > before["measuring"], PROBE_S + 10),
                        "no probe within %d s" % (PROBE_S + 10))
        self.assertEqual([c for c in self.s.calls(done=True) if c["argv"] == ["status", "--measuring"]], [],
                         "precondition: the probe's ndt was stopped at its timeout, not finished")
        self.pause(REFRESH_S + 2)
        self.assertEqual((self.tick_reads(), hook(p, "refresh")),
                         (dict(before, measuring=before["measuring"] + 1), "paused-measuring"),
                         "a probe that timed out brought the 10 s tick back")
        # the measurement is over: the next probe answers, and the tick it brings back reads idle too
        self.stub(status=IDLE, **{"status --measuring": {"stdout": NOTHING_ROWS}})
        self.assertTrue(until(lambda: self.tick_reads()["apps"] > before["apps"], PROBE_S + REFRESH_S + 8),
                        "the next probe, which answered nothing measuring, did not end the pause: %r"
                        % self.tick_reads())
        self.assertEqual(self.tick_reads()["measuring"], before["measuring"] + 2,
                         "the pause was ended by something other than the second probe")
        p.wait_for("document.body.dataset.refresh === 'running'", 5)


# --- the job log ----------------------------------------------------------------------------------

class JobLog(PageCase):
    def test_job_log_stops_on_close(self):
        p = self.load()
        jid = self.start_job(p, sleep=10)
        p.click("job-close")
        p.wait_for("document.getElementById('job').hidden", 5)
        self.pause(0.5)
        n = self.job_reads(jid)
        self.pause(LOG_QUIET_S)
        self.assertFalse(self.job_ended(jid), "precondition: the job is still running")
        self.assertEqual(self.job_reads(jid), n, "the page read job %s %d more time(s) after the job panel was closed"
                         % (jid, self.job_reads(jid) - n))

    def test_job_log_stops_when_the_job_ends(self):
        p = self.load()
        jid = self.start_job(p, sleep=1)
        self.assertTrue(until(lambda: self.job_ended(jid), 15), "the job did not end")
        p.wait_for("document.getElementById('job-stdout').textContent.includes('claimed')", 2 * JOB_LOG_S + 3)
        self.pause(JOB_LOG_S + 1)               # the read that sees it ended
        n = self.job_reads(jid)
        self.pause(LOG_QUIET_S)
        self.assertEqual(self.job_reads(jid), n, "the page read job %s %d more time(s) after the job ended"
                         % (jid, self.job_reads(jid) - n))

    def test_job_log_stops_while_hidden_and_resumes(self):
        p = self.load()
        jid = self.start_job(p, sleep=12)
        self.hide(p)
        self.pause(1)
        n = self.job_reads(jid)
        self.pause(LOG_QUIET_S)
        self.assertFalse(self.job_ended(jid), "precondition: the job is still running")
        self.assertEqual(self.job_reads(jid), n, "the page read job %s's job log while the page was hidden (%d time(s))"
                         % (jid, self.job_reads(jid) - n))
        self.show(p)
        self.assertTrue(until(lambda: self.job_reads(jid) > n, 2 * JOB_LOG_S),
                        "the job log was not read again after the page was shown")


def header():
    """This run's own provenance, printed before any case: what code, what tree, what interpreter."""
    def out(*argv):
        """The command's stdout, or None when it failed -- printed as "?", never as an empty or clean
        reading (a failed `git status` is not "0 paths differ")."""
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return None
        return r.stdout.strip() if r.returncode == 0 else None
    porcelain = out("git", "-C", REPO, "status", "--porcelain")
    page = os.path.join(base.SERVE_DIR, "static")
    lines = ["date -Is: %s" % datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
             "argv: %s" % " ".join(sys.argv),
             "git rev-parse HEAD: %s" % (out("git", "-C", REPO, "rev-parse", "HEAD") or "?"),
             "git status --porcelain | wc -l: %s" % ("?" if porcelain is None else len(porcelain.splitlines())),
             "python: %s %s" % (sys.executable, sys.version.replace("\n", " ")),
             "chrome: %s" % ((out(CHROME, "--version") or "?") if CHROME else "none"),
             "NDTWIN_GUARD_HELD: %s" % (GUARD_HELD or "(unset)"),
             "page under test: %s" % page]
    for name in sorted(os.listdir(page)) if os.path.isdir(page) else []:
        with open(os.path.join(page, name), "rb") as f:
            lines.append("  %s  %s" % (hashlib.sha256(f.read()).hexdigest(), name))
    sys.stderr.write("".join("# %s\n" % l for l in lines))
    sys.stderr.flush()


def stray():
    """Processes whose command line names a temp dir this run made (read from /proc; nothing signalled)."""
    marks = [d.encode() + b"/" for d in RUN_DIRS]
    hits = []
    for d in os.listdir("/proc"):
        if d.isdigit() and int(d) != os.getpid():
            try:
                with open("/proc/%s/cmdline" % d, "rb") as f:
                    cmd = f.read()
            except OSError:
                continue
            if any(m in cmd for m in marks):
                hits.append(int(d))
    return hits


def _interrupted(signum, frame):
    # SIGTERM (the gate's `timeout`) becomes ^C, so the finally below closes the Chromes and
    # stops the servers this file started, instead of both outliving it.
    raise KeyboardInterrupt("signal %d" % signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _interrupted)
    header()
    try:
        unittest.main(verbosity=2)
    finally:
        for c in list(OPEN_CLASSES):
            c.end_chrome()
            c.say_leftovers()
        tearDownModule()
        until(lambda: not stray(), 5)
        left = stray()
        sys.stderr.write("# processes naming this run's %d temp dir(s) after the run: %d %s\n"
                         % (len(RUN_DIRS), len(left), left or ""))
