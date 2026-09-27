#!/usr/bin/env python3
"""ndt serve's page in a real browser: SCOPE section 6, the page rows G12-G14
(doc/audit/2026-09-27_ndt-serve-gui/SCOPE.md).

[Co-developed with claude code -- Adam]

What only a browser can show about tools/ndt_serve/static/app.js, because it is about what the
page DOES once it runs, not about how it is spelled:

  G12  the one-time key leaves the address bar (history.replaceState) and is traded for the
       token -- once: the key the page used is refused afterwards;
  G13  the token lives in the page's memory only: nothing in localStorage, sessionStorage or
       document.cookie, and neither the token nor the key anywhere in the rendered DOM or, for the
       token, in any file of the browser profile;
  G14  loading the page writes nothing: the stub ndt sees only plain `status`, no job exists,
       and the only non-GET request the server logged is the key trade (POST /api/v1/session);

plus the two refusals: a used key opens nothing (no session, no ndt call) and neither does a URL
with no key at all.

    JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh python3 tests/browser/test_ndt_serve_page.py
    NDT_SERVE_UNDER_TEST=/tmp/x/tools/ndt_serve ... (a mutant tree -- tests/shell/mutate_ndt_serve_page.sh)

WHY tests/browser/ AND NOT tests/python/: CI's L1 lane globs tests/python/test_*.py and
tests/shell/test_*.sh and fails any suite that skips; CI has no Chrome, so every case here would
skip there. This directory is outside that glob on purpose.

WHEN IT SKIPS (every case, with the reason in unittest's output): google-chrome is not installed;
or it is not running inside tools/build_guard/guarded_build.sh (NDTWIN_GUARD_HELD unset) -- on
this laptop systemd-oomd has twice killed Adam's own application under memory pressure, and a
browser is the one thing in this suite that can make some. A skipped case proves nothing, which is
why the mutation gate refuses a baseline with a skip in it.

HOW A CASE RUNS: its own stub server (tests/python/test_ndt_serve.py's Serve: a stub ndt that
records every call to calls.jsonl, no real ndt, no lab), with HOME inside the case's temp dir and
XDG_CONFIG_HOME / XDG_STATE_HOME unset, so no default path reaches the real ~. The page URL is the
one the server wrote to the 0600 `url` file beside its token file (its stdout is not a terminal).
Then ONE Chrome at a time -- headless, a fresh profile inside the case's temp dir, the same HOME --
dumps the DOM once the page's own fetches are done. Chrome is started in a session and process
group of its own. After it exits, no process may remain in that session or that group, or carry
the profile directory in its cmdline. A Chrome that runs past its timeout, and a leftover in that
group, get the GROUP SIGKILLed -- the group this file created, by the pid it recorded -- and the
case fails naming the pids; nothing else is ever signalled, and no process is looked up by name.

The page reports through data-* attributes on <body> (app.js, hook()): data-href (location.href
after the wipe), data-session (ok | refused | no-key), data-storage ({"local":N,"session":N,
"cookie":"..."}), data-loaded (yes | no-session | no-meta). The token never goes there.

tests/shell/mutate_ndt_serve_page.sh is this file's mutation gate.
"""
import html
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
import test_ndt_serve as base  # noqa: E402 -- Serve, the stub ndt; honours NDT_SERVE_UNDER_TEST
from test_ndt_serve import tearDownModule  # noqa: E402,F401 -- the same leftover-server sweep

CHROME = shutil.which("google-chrome")
GUARD_HELD = os.environ.get("NDTWIN_GUARD_HELD", "")
NO_CHROME = "google-chrome is not installed (CI has none): the page cases need a real browser"
NO_GUARD = ("not inside tools/build_guard/guarded_build.sh: headless Chrome runs only under the guard on "
            "this laptop (systemd-oomd) -- JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh "
            "python3 tests/browser/test_ndt_serve_page.py")

CHROME_TIMEOUT_S = 60
LEFTOVER_GRACE_S = 5       # a child still on its way out when the main process is reaped
STATUS = "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      nothing\n"
SERVER_XDG = ("XDG_CONFIG_HOME", "XDG_STATE_HOME")
CHROME_XDG = ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME")

URL_RE = re.compile(r"http://127\.0\.0\.1:(\d+)/#k=([A-Za-z0-9_-]{16,64})")
# <body ...>, with a quoted value allowed to hold any byte but a double quote (Chrome writes " as &quot;)
BODY_RE = re.compile(r'<body((?:\s+[^\s=>"]+(?:="[^"]*")?)*)\s*>')
ATTR_RE = re.compile(r'([^\s=>"]+)(?:="([^"]*)")?')
# the server's access log line (serve.py log_message): HH:MM:SS "POST /api/v1/session HTTP/1.1" 200 -
REQUEST_RE = re.compile(r'"([A-Z]+) (\S+) HTTP/[0-9.]+" (\d{3})')


def chrome_argv(profile, url):
    # The 09-27 invocation the parent session verified, plus four switches that keep a throwaway
    # profile from reaching anything beyond this page: no component/background fetches, no sync,
    # and a plain password store instead of the desktop keyring.
    return [CHROME, "--headless=new", "--no-first-run", "--no-default-browser-check",
            "--user-data-dir=" + profile, "--disable-background-networking", "--disable-component-update",
            "--disable-sync", "--password-store=basic", "--virtual-time-budget=8000", "--dump-dom", url]


def processes():
    """(pid, pgrp, sid, state, cmdline bytes) of every process /proc lists now. One that exits
    while it is being read is skipped. Read by pid from /proc, never looked up by name."""
    rows = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as f:
                rest = f.read().rsplit(")", 1)[1].split()
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        rows.append((int(d), int(rest[2]), int(rest[3]), rest[0], cmd))
    return rows


def leftovers(pid, profile):
    """Every process in the session or the process group Chrome was started as (both numbered by
    its pid), and every process whose cmdline names its profile directory -- detection only."""
    mark = profile.encode()
    return [r for r in processes() if r[1] == pid or r[2] == pid or mark in r[4]]


def describe(rows):
    return "; ".join("pid %d pgrp %d sid %d state %s: %s" % (p, g, s, st, c.replace(b"\0", b" ")[:160].decode(
        "utf-8", "replace")) for p, g, s, st, c in rows)


def body_attrs(dump):
    tags = BODY_RE.findall(dump)
    if len(tags) != 1:
        raise AssertionError("the dump holds %d <body> tags, not 1: %r" % (len(tags), dump[:400]))
    return {k: html.unescape(v or "") for k, v in ATTR_RE.findall(tags[0])}


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


@unittest.skipUnless(CHROME, NO_CHROME)          # outermost: its reason wins when both are missing
@unittest.skipUnless(GUARD_HELD, NO_GUARD)
class PageSession(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.mkdtemp(prefix="ndt-serve-page-")
        self.home = os.path.join(tmp, "home")
        os.makedirs(self.home)
        self.s = base.Serve(tmp=tmp, env={"HOME": self.home})
        for k in SERVER_XDG:
            self.s.env.pop(k, None)
        self.addCleanup(self.s.close)     # also removes tmp, profiles included -- after Chrome is gone
        self.s.behave(status={"stdout": STATUS})
        self.s.start()

    # --- helpers ---
    def page_url(self):
        """The one-time URL the server wrote beside its token file, and its key."""
        path = os.path.join(os.path.dirname(self.s.token_file), "url")
        deadline = time.monotonic() + 10
        while not os.path.exists(path) and time.monotonic() < deadline:
            time.sleep(0.05)
        text = base._read(path).strip()
        m = URL_RE.fullmatch(text)
        self.assertIsNotNone(m, "the url file does not hold a page URL with a key: %r" % text)
        self.assertEqual(int(m.group(1)), self.s.port, "the url file names another port")
        return text, m.group(2)

    def open_page(self, url):
        """One headless Chrome on `url`, to the end: -> (<body> data-* attributes, the dump, the
        profile directory). Fails on a timeout, a non-zero exit, or any leftover process."""
        profile = tempfile.mkdtemp(prefix="chrome-profile-", dir=self.s.tmp)
        out, err = profile + ".dump", profile + ".stderr"
        env = {k: v for k, v in os.environ.items() if not k.startswith("NDT_")}
        env["HOME"] = self.home
        for k in CHROME_XDG:
            env.pop(k, None)
        with open(out, "wb") as o, open(err, "wb") as e:
            p = subprocess.Popen(chrome_argv(profile, url), stdin=subprocess.DEVNULL, stdout=o, stderr=e,
                                 env=env, cwd=self.s.tmp, start_new_session=True)
        problems = []
        try:
            p.wait(CHROME_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)   # the group this test created for it
            p.wait(10)
            problems.append("Chrome did not finish in %d s: its process group %d was SIGKILLed"
                            % (CHROME_TIMEOUT_S, p.pid))
        except BaseException:                  # interrupted (SIGTERM from the gate's timeout, ^C)
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(10)
            raise
        left = leftovers(p.pid, profile)
        deadline = time.monotonic() + LEFTOVER_GRACE_S
        while left and time.monotonic() < deadline:
            time.sleep(0.1)
            left = leftovers(p.pid, profile)
        if left:
            if any(r[1] == p.pid for r in left):
                try:
                    os.killpg(p.pid, signal.SIGKILL)   # our group, and only our group
                except ProcessLookupError:
                    pass
                problems.append("processes left in Chrome's process group %d (SIGKILLed): %s"
                                % (p.pid, describe([r for r in left if r[1] == p.pid])))
            other = [r for r in left if r[1] != p.pid]
            if other:
                problems.append("processes left in Chrome's session or naming its profile (NOT signalled): %s"
                                % describe(other))
        if p.returncode != 0 and not problems:
            problems.append("Chrome exited %d" % p.returncode)
        if problems:
            self.fail("%s\n  profile %s\n  Chrome's stderr (tail): %s"
                      % ("\n  ".join(problems), profile, base._read(err)[-1500:]))
        dump = base._read(out)
        return body_attrs(dump), dump, profile

    def requests_seen(self):
        """(method, path, status) of every request the server logged, in order."""
        return [(m.group(1), m.group(2), int(m.group(3)))
                for m in REQUEST_RE.finditer(base._read(self.s.out + ".err"))]

    # --- G12 ---
    def test_the_key_leaves_the_address_bar_and_is_traded(self):
        url, key = self.page_url()
        body, _, _ = self.open_page(url)
        self.assertEqual(body.get("data-session"), "ok", "the page did not open a session: %r" % body)
        self.assertEqual(body.get("data-href"), "http://127.0.0.1:%d/" % self.s.port,
                         "the key is still in the address bar after the page ran")
        trades = [st for method, path, st in self.requests_seen() if (method, path) == ("POST", "/api/v1/session")]
        self.assertEqual(trades, [200], "the server did not see the page trade the key exactly once")
        st, j, _, _ = self.s.request("POST", "/api/v1/session", body={"nonce": key}, token=None,
                                     headers={"Origin": "http://127.0.0.1:%d" % self.s.port})
        self.assertEqual((st, (j or {}).get("error")), (403, "nonce"),
                         "the key the page traded still opens a session")

    # --- G13 ---
    def test_the_token_is_only_in_memory(self):
        url, key = self.page_url()
        body, dump, profile = self.open_page(url)
        self.assertEqual(body.get("data-loaded"), "yes", "the page did not load: %r" % body)
        self.assertEqual(json.loads(body.get("data-storage") or "null"), {"local": 0, "session": 0, "cookie": ""},
                         "the page left something in browser storage")
        token = self.s.token()
        self.assertGreaterEqual(len(token), 40)
        self.assertFalse(token in dump, "the token is in the page's DOM")
        self.assertFalse(key in dump, "the one-time key is in the page's DOM")
        self.assertEqual(files_holding(profile, token), [], "the token is in a file of the browser profile")

    # --- G14 ---
    def test_loading_the_page_writes_nothing(self):
        url, _ = self.page_url()
        body, _, _ = self.open_page(url)
        self.assertEqual(body.get("data-loaded"), "yes", "the page did not load: %r" % body)
        problems = []
        st, j, _, _ = self.s.get("/jobs")
        jobs = j.get("jobs") if st == 200 and isinstance(j, dict) else None
        if jobs != []:
            problems.append("GET /jobs after loading the page answered %d with %r" % (st, jobs))
            for job in jobs or []:
                try:
                    self.s.wait(job["id"])     # so the stub has recorded what the job ran
                except (AssertionError, OSError, KeyError, TypeError):
                    pass                       # already a problem; the calls below say what ran
        argvs = [c["argv"] for c in self.s.calls()]
        if not argvs:
            problems.append("the stub saw no call at all: the page never read the lab, so this checked nothing")
        writes = [a for a in argvs if a != ["status"]]
        if writes:
            problems.append("the stub saw calls other than plain status: %r" % writes)
        not_get = [(method, path, code) for method, path, code in self.requests_seen() if method != "GET"]
        if not not_get:
            problems.append("the server logged no key trade (POST /api/v1/session): nothing was loaded")
        others = [r for r in not_get if r[:2] != ("POST", "/api/v1/session")]
        if others:
            problems.append("the page's load made requests that are not the key trade: %r" % others)
        self.assertEqual(problems, [], "loading the page writes")

    # --- the refusals ---
    def test_a_used_key_opens_nothing(self):
        url, _ = self.page_url()
        first, _, _ = self.open_page(url)
        self.assertEqual((first.get("data-session"), first.get("data-loaded")), ("ok", "yes"),
                         "the first load, the one the second is held against, did not open")
        before = self.s.calls()
        second, _, _ = self.open_page(url)
        self.assertEqual((second.get("data-session"), second.get("data-loaded")), ("refused", "no-session"),
                         "the second load of a used key opened a session")
        self.assertEqual(self.s.calls(), before, "the second load of a used key ran ndt")

    def test_a_url_without_a_key_opens_nothing(self):
        body, _, _ = self.open_page("http://127.0.0.1:%d/" % self.s.port)
        self.assertEqual(body.get("data-session"), "no-key", "a URL with no key: %r" % body)
        self.assertEqual(body.get("data-loaded"), "no-session", "a URL with no key: %r" % body)
        self.assertEqual(self.s.calls(), [], "a URL with no key ran ndt")
        self.assertEqual([r for r in self.requests_seen() if r[0] != "GET"], [],
                         "a URL with no key made a non-GET request")


def _interrupted(signum, frame):
    # SIGTERM (the gate's `timeout`) becomes ^C, so open_page's handler kills the Chrome group it
    # started and the finally below stops the servers, instead of both outliving this process.
    raise KeyboardInterrupt("signal %d" % signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _interrupted)
    try:
        unittest.main(verbosity=2)
    finally:
        tearDownModule()
