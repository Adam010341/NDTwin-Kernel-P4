#!/usr/bin/env python3
"""ndt serve's page, v2: what can be checked without Node, a browser or the lab.

[Co-developed with claude code -- Adam]

The page is a React app built from tools/ndt_serve/web/ into tools/ndt_serve/static/, and the
built files are committed. CI has no Node, so three things are held here, from files alone:

  BuildManifest  static/BUILD.json names every source file under web/ and every built file, each
                 with its sha256. A source changed without a rebuild, a bundle edited by hand, a
                 file added on either side and left out of the manifest -- each turns this red.
                 Whether the sources really BUILD into these bytes is the local rebuild gate's
                 question (tests/shell/rebuild_ndt_serve_web.sh, under the build guard).
  BundleLint     the built files carry no inline script, style or handler, load nothing from
                 another origin and call no eval -- what the server's CSP would otherwise refuse
                 at run time, found before it ships.
  SourceLint     web/src/**/*.ts(x) keeps the page's rules where a reader can see them: the token
                 only in memory, one door out (fetch and the token header in api/client.ts), every
                 write through the confirm dialog, the one-time key traded once and wiped first,
                 the job log's three stop conditions, the refresh's two pauses and its 60 s probe, every UI string in
                 the string table. The rules are about spelling; what the page DOES is
                 tests/browser/test_ndt_serve_page.py's (headless Chrome, under the guard).

    python3 tests/python/test_ndt_serve_web.py
    NDT_SERVE_UNDER_TEST=/tmp/x/tools/ndt_serve python3 tests/python/test_ndt_serve_web.py   # a mutant

tests/shell/mutate_ndt_serve.sh (the G series) is this file's mutation gate.
"""
import hashlib
import json
import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVE_DIR = os.environ.get("NDT_SERVE_UNDER_TEST") or os.path.join(REPO, "tools", "ndt_serve")
WEB = os.path.join(SERVE_DIR, "web")
SRC = os.path.join(WEB, "src")
STATIC = os.path.join(SERVE_DIR, "static")
BUNDLE = ("index.html", "app.js", "app.css", "manual.html")
NOT_SOURCE = ("node_modules", "dist")     # never committed (web/.gitignore), never in the manifest


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def source_files():
    """Every file under web/ but node_modules/ and dist/, as the manifest names it."""
    out = {}
    for d, dirs, files in os.walk(WEB):
        dirs[:] = sorted(x for x in dirs if not (d == WEB and x in NOT_SOURCE))
        for f in files:
            p = os.path.join(d, f)
            out["tools/ndt_serve/web/" + os.path.relpath(p, WEB).replace(os.sep, "/")] = p
    return out


def code(path):
    """A TS/TSX file without its comments: /* ... */ blocks, and // to the end of a line when the
    // stands at the start of a line or after whitespace (so "http://" in a string stays)."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), read(path), flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.splitlines())


def sources():
    """{path relative to src/: code without comments} for every .ts / .tsx under src/."""
    out = {}
    for d, _, files in os.walk(SRC):
        for f in files:
            if f.endswith((".ts", ".tsx")):
                p = os.path.join(d, f)
                out[os.path.relpath(p, SRC).replace(os.sep, "/")] = code(p)
    return out


def block(text, opener):
    """The body of the block that `opener` (ending in "{") starts, by brace matching; None if absent."""
    i = text.find(opener)
    if i < 0:
        return None
    start = i + len(opener)
    depth = 1
    for j in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0:
            return text[start:j]
    return None


def where(pattern, srcs, flags=0):
    """{file: number of matches} for every file that matches."""
    out = {}
    for name, text in srcs.items():
        n = len(re.findall(pattern, text, flags))
        if n:
            out[name] = n
    return out


# --- the committed bundle and its sources --------------------------------------------------

class BuildManifest(unittest.TestCase):
    def setUp(self):
        self.m = json.loads(read(os.path.join(STATIC, "BUILD.json")))

    def test_the_manifest_says_how_it_was_built(self):
        self.assertEqual(sorted(self.m), ["bundle", "command", "source", "toolchain"])
        self.assertRegex(self.m["toolchain"].get("node", ""), r"^v[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertRegex(self.m["toolchain"].get("npm", ""), r"^[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertIn("--ignore-scripts", self.m["command"])

    def test_every_source_file_is_in_the_manifest_with_its_hash(self):
        files = source_files()
        self.assertIn("tools/ndt_serve/web/package-lock.json", files)
        self.assertEqual(sorted(files), sorted(self.m["source"]),
                         "web/ and BUILD.json disagree on which files the bundle was built from")
        stale = [k for k, p in files.items() if sha256(p) != self.m["source"][k]]
        self.assertEqual(stale, [], "sources changed since the bundle was built -- rebuild it")

    def test_the_bundle_is_the_one_the_manifest_names(self):
        built = sorted(f for f in os.listdir(STATIC) if f != "BUILD.json")
        self.assertEqual(built, sorted(BUNDLE))
        self.assertEqual(sorted(self.m["bundle"]), sorted(BUNDLE))
        edited = [f for f in BUNDLE if sha256(os.path.join(STATIC, f)) != self.m["bundle"][f]]
        self.assertEqual(edited, [], "a built file is not what the build wrote")


class BundleLint(unittest.TestCase):
    def test_the_page_html_loads_only_its_own_two_files(self):
        html = read(os.path.join(STATIC, "index.html"))
        scripts = re.findall(r"<script\b([^>]*)>(.*?)</script>", html, re.S)
        self.assertEqual(len(scripts), 1, scripts)
        self.assertRegex(scripts[0][0], r'\bsrc="\./app\.js"')
        self.assertEqual(scripts[0][1].strip(), "", "an inline script")
        self.assertEqual(re.findall(r"\b(?:href|src)=\"([^\"]*)\"", html), ["./app.js", "./app.css"]
                         if html.index("app.js") < html.index("app.css") else ["./app.css", "./app.js"])
        for pat in (r"<style\b", r"\sstyle\s*=", r"\son[a-z]+\s*=", r"javascript:", r"https?://"):
            self.assertNotRegex(html, pat)

    def test_the_script_calls_no_eval(self):
        js = read(os.path.join(STATIC, "app.js"))
        for pat in (r"\beval\s*\(", r"\bnew\s+Function\s*\(", r"\bimport\s*\(\s*[\"'`]https?:"):
            self.assertNotRegex(js, pat)

    def test_the_styles_load_nothing(self):
        css = read(os.path.join(STATIC, "app.css"))
        self.assertNotRegex(css, r"@import\b")
        self.assertNotRegex(css, r"url\(\s*[\"']?(?:https?:)?//")

    def test_the_manual_is_a_page_without_script_or_inline_style(self):
        html = read(os.path.join(STATIC, "manual.html"))
        self.assertIn("<h1", html)
        for pat in (r"<script\b", r"<style\b", r"\sstyle\s*=", r"\son[a-z]+\s*=", r"javascript:",
                    r"<(?:img|link|iframe|object|embed)\b[^>]*\b(?:src|href)=\"(?:https?:)?//"):
            self.assertNotRegex(html, pat)
        self.assertEqual(re.findall(r"<link\b[^>]*\bhref=\"([^\"]*)\"", html), ["./app.css"])


# --- the page's rules, where a reader can see them -----------------------------------------

class SourceLint(unittest.TestCase):
    def setUp(self):
        self.src = sources()
        self.assertIn("api/client.ts", self.src)

    def test_nothing_is_kept_outside_memory(self):
        stores = where(r"\b(?:localStorage|sessionStorage|indexedDB|caches)\b|document\.cookie", self.src)
        self.assertEqual(sorted(stores), ["testhooks.ts"], stores)
        hooks = self.src["testhooks.ts"]
        self.assertNotRegex(hooks, r"setItem|removeItem|clear\(|cookie\s*=(?!=)|token")
        self.assertEqual(where(r"\.setItem\s*\(|document\.cookie\s*=(?!=)", self.src), {})

    def test_no_html_from_strings_no_eval_no_inline_style(self):
        for pat in (r"dangerouslySetInnerHTML", r"\binnerHTML\b", r"\bouterHTML\b", r"insertAdjacentHTML",
                    r"document\.write", r"\beval\s*\(", r"\bnew\s+Function\b", r"\bsetTimeout\s*\(\s*[\"'`]",
                    r"\bDOMParser\b", r"\bsrcdoc\b", r"\bstyle\s*=\s*\{"):
            self.assertEqual(where(pat, self.src), {}, pat)

    def test_there_is_one_door_out_and_the_token_is_set_at_it(self):
        self.assertEqual(where(r"\bfetch\s*\(", self.src), {"api/client.ts": 1})
        self.assertEqual(where(r"X-NDT-Token", self.src), {"api/client.ts": 1})
        for pat in (r"XMLHttpRequest", r"sendBeacon", r"\bWebSocket\b", r"\bEventSource\b", r"window\.open\s*\(",
                    r"\bimport\s*\(", r"\bnew\s+Worker\b"):
            self.assertEqual(where(pat, self.src), {}, pat)
        callers = where(r"(?<![\w.])call(?:<[^>]*>)?\s*\(", {k: v for k, v in self.src.items()})
        callers.get("api/client.ts") and callers.pop("api/client.ts")
        self.assertEqual(callers, {"api/session.ts": 1}, "call() is used past get()/post()")

    def test_every_write_goes_through_the_confirm_dialog(self):
        posts = where(r"(?<![\w.])post(?:<[^>]*>)?\s*\(", {k: v for k, v in self.src.items() if k != "api/client.ts"})
        self.assertEqual(sorted(posts), ["components/ConfirmDialog.tsx"], posts)
        self.assertEqual(sorted(where(r"[\"']POST[\"']", self.src)), ["api/client.ts", "api/session.ts"])
        # the session module trades the key with exactly one POST, to /session (judge G-N10)
        self.assertEqual(re.findall(r"call\(\s*\"POST\"\s*,\s*\"([^\"]*)\"", self.src["api/session.ts"]),
                         ["/session"])

    def test_the_key_leaves_the_address_bar_before_it_is_traded(self):
        s = self.src["api/session.ts"]
        wipe = [m.start() for m in re.finditer(r"history\.replaceState\(\s*null\s*,\s*\"\"\s*,\s*"
                                               r"location\.pathname\s*\+\s*location\.search\s*\)", s)]
        self.assertEqual(len(wipe), 1, "the key is not wiped from the address bar exactly once")
        read_hash = s.index("location.hash")
        trade = s.index("trade(m[1])")
        self.assertLess(read_hash, wipe[0])
        self.assertLess(wipe[0], trade, "the key is traded before it leaves the address bar")

    def test_the_job_log_stops_when_the_job_ends_the_view_closes_or_the_page_hides(self):
        s = self.src["hooks/useJobLog.ts"]
        self.assertRegex(s, r"export const JOB_LOG_INTERVAL_MS = 2_000;")
        # 1. the job ended
        ended = block(s, 'if (job.state !== "running") {')
        self.assertIsNotNone(ended, "the loop does not stop when the job ends")
        self.assertRegex(ended, r"\breturn;\s*$", "the job-ended branch does not leave the loop")
        # 2. closed or opened again: every opening has its own token, and the loop asks after each wait
        self.assertRegex(s, r"const mine = \{\};\s*\n\s*watching\.current = mine;")
        self.assertGreaterEqual(len(re.findall(r"if \(watching\.current !== mine\) return;", s)), 3)
        # 3. hidden: after the sleep, nothing is read until the page is shown again
        self.assertRegex(s, r"await sleep\(JOB_LOG_INTERVAL_MS\);\s*await whileHidden\(\);\s*"
                            r"if \(watching\.current !== mine\) return;")
        self.assertIn('if (document.visibilityState !== "hidden") return Promise.resolve();', s)
        self.assertEqual(s.count("Promise.resolve()"), 1)

    def test_the_refresh_pauses_while_measuring_and_while_hidden(self):
        s = self.src["hooks/useAutoRefresh.ts"]
        self.assertRegex(s, r"export const REFRESH_INTERVAL_MS = 10_000;")
        self.assertRegex(s, r"return lab\.measuring_is_nothing === false \|\| lab\.declared !== null;")
        arm = re.search(r"const arm = \(\) => \{(.*?)\n  \};", s, re.S)
        self.assertTrue(arm, "no arm()")
        body = arm.group(1)
        armed = body.index("window.setTimeout(tick, REFRESH_INTERVAL_MS)")
        self.assertLess(body.index('setState("paused-measuring");'), armed)
        self.assertLess(body.index('setState("paused-hidden");\n      return;'), armed)
        # the two timers, tick and probe, are armed in arm() and nowhere else
        self.assertEqual(s.count("window.setTimeout("), 2, "a timer armed past arm()")
        self.assertEqual(body.count("window.setTimeout("), 2, "a timer armed past arm()")
        self.assertNotRegex(s, r"setInterval")
        tick = re.search(r"const tick = async \(\) => \{(.*?)\n  \};", s, re.S).group(1)
        self.assertLess(tick.index('if (document.visibilityState === "hidden") {'),
                        tick.index("await readOnce(readRef.current);"))
        # shown again: a read only when the last one was not measuring; measuring, the probe is re-armed
        self.assertRegex(s, r"if \(timer\.current !== null \|\| inFlight\.current\) return;\s*"
                            r"if \(measuring\.current\) \{\s*arm\(\);\s*return;\s*\}\s*void tick\(\);")

    def test_a_measuring_pause_probes_lab_alone_once_a_minute(self):
        # Adam's Q6 (09-28): after a measuring pause, an automatic probe -- read-only and light
        s = self.src["hooks/useAutoRefresh.ts"]
        self.assertRegex(s, r"export const PROBE_INTERVAL_MS = 60_000;")
        body = re.search(r"const arm = \(\) => \{(.*?)\n  \};", s, re.S).group(1)
        paused = block(body, "if (measuring.current) {")
        self.assertIsNotNone(paused, "arm() does not look at measuring")
        # measuring: the probe, and only while shown; then arm() returns before the 10 s tick
        self.assertRegex(paused, r'setState\("paused-measuring"\);\s*'
                                 r'if \(document\.visibilityState !== "hidden"\) '
                                 r'timer\.current = window\.setTimeout\(probe, PROBE_INTERVAL_MS\);\s*return;\s*$')
        probe = re.search(r"const probe = async \(\) => \{(.*?)\n  \};", s, re.S)
        self.assertTrue(probe, "no probe()")
        probe = probe.group(1)
        self.assertLess(probe.index('if (document.visibilityState === "hidden") {'),
                        probe.index("await readOnce(labRef.current);"), "the probe reads while hidden")
        self.assertNotIn("readRef", probe, "the probe reads more than /lab")
        self.assertEqual(s.count("await readOnce(labRef.current);"), 1, "/lab alone is read past the probe")
        # labRef is NdtServeApp's readLab, and readLab reads /lab and nothing else
        app = self.src["NdtServeApp.tsx"]
        self.assertIn("useAutoRefresh(meta !== null, readAll, readLab, firstRead)", app)
        lab = block(app, "const readLab = useCallback(async (): Promise<LabAnswer | null> => {")
        self.assertIsNotNone(lab, "no readLab")
        self.assertEqual(re.findall(r"\bget(?:<[^>]*>)?\(\s*\"([^\"]*)\"", lab), ["/lab"], "the probe reads more than /lab")
        self.assertNotRegex(lab, r"\b(?:post|call|fetch)\b")

    def test_every_write_the_server_can_preview_is_previewed(self):
        # a confirm request with preview: false skips the server's dry run -- and with it the argv
        # shown and the "claim first" check (ConfirmDialog). Every write the server can dry-run
        # (serve.py DRY_RUN_OK) asks for it; the three that cannot say so.
        want = {
            ("components/tabs/ActionsTab.tsx", '"/claim"'): "true",
            ("components/tabs/ActionsTab.tsx", '"/release"'): "true",
            ("components/tabs/ActionsTab.tsx", '"/up"'): "true",
            ("components/tabs/ActionsTab.tsx", '"/down"'): "true",
            ("components/tabs/AppsTab.tsx", '"/apps/" + encodeURIComponent(name) + "/" + action'): "true",
            ("components/tabs/CellsTab.tsx", '"/cells/" + encodeURIComponent(c.name) + "/run"'): "true",
            ("components/WalkPanel.tsx", 'path("/next")'): "true",
            ("components/tabs/CellsTab.tsx", '"/cells/" + encodeURIComponent(c.name) + "/guided"'): "false",
            ("components/WalkPanel.tsx", 'path("/abort")'): "false",
            ("components/WalkPanel.tsx", 'path("/verdict")'): "false",
        }
        got = {}
        for name, text in self.src.items():
            if not name.startswith("components/") or name == "components/ConfirmDialog.tsx":
                continue    # the requests are made in the tabs; the dialog only declares the field
            for m in re.finditer(r"\bpath: (.+),\n((?:(?![ \t]*path: ).*\n){0,8})", text):
                pv = re.search(r"^[ \t]*preview: (\w+),$", m.group(2), re.M)
                got[(name, m.group(1))] = pv.group(1) if pv else None
        self.assertEqual(got, want)

    def test_csp_violations_are_counted_for_the_browser_tests(self):
        s = self.src["main.tsx"]
        self.assertIn('document.addEventListener("securitypolicyviolation"', s)
        self.assertRegex(s, r"hook\(\"cspViolations\"")

    def test_every_ui_string_is_in_the_string_table(self):
        cjk = where(r"[　-〿㐀-鿿＀-￯]", self.src)
        self.assertEqual(cjk, {}, "Chinese text outside src/i18n/zh.json")
        table = json.loads(read(os.path.join(SRC, "i18n", "zh.json")))
        self.assertEqual(sorted(table), ["ndtServe"], "every key lives under ndtServe.*")


if __name__ == "__main__":
    unittest.main(verbosity=2)
