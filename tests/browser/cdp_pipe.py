"""A headless Chrome driven over the DevTools protocol, standard library only.

[Co-developed with claude code -- Adam]

Chrome's --remote-debugging-pipe speaks the protocol over two inherited file descriptors: it reads
commands from fd 3 and writes answers and events to fd 4, each message one JSON object followed
by a NUL byte. No websocket, no port, nothing to install. What the page tests need from it:

  * a page (a "target") to load the ndt serve page in, and JS evaluated in it (the DOM, storage);
  * real input: a mouse click on an element, typed text, a key press -- the confirm dialog's
    behaviour is about what a click and an Enter do, which reading the DOM cannot show;
  * a page that is really hidden: opening a second target makes the first one's
    document.visibilityState "hidden" (Chrome 153, measured 09-27, logs/ndt-serve-gui-v2/cdp_spike.*),
    and activating it again makes it visible.

One Chrome at a time, a profile directory the caller owns, its own session and process group.
close() ends it and then asserts nothing is left: no process in that session or group and none
whose cmdline names the profile -- found by reading /proc, never by a process name. Only the group
this module created is ever signalled.
"""
import json
import os
import select
import shutil
import signal
import subprocess
import time

CHROME_ARGS = ["--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
               "--disable-component-update", "--disable-sync", "--password-store=basic", "--remote-debugging-pipe"]
LEFTOVER_GRACE_S = 5


class CdpError(Exception):
    pass


def processes():
    """(pid, pgrp, sid, cmdline bytes) of every process /proc lists now."""
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
        rows.append((int(d), int(rest[2]), int(rest[3]), cmd))
    return rows


class Chrome:
    def __init__(self, profile, env=None, chrome=None, timeout=60):
        self.profile = profile
        self.timeout = timeout
        self.buf = b""
        self.next_id = 0
        self.events = []
        exe = chrome or shutil.which("google-chrome")
        if not exe:
            raise CdpError("google-chrome is not installed")
        r_cmd, self.w_cmd = os.pipe()   # Chrome reads commands on its fd 3
        self.r_out, w_out = os.pipe()   # and writes answers on its fd 4

        def child():
            os.dup2(r_cmd, 3)
            os.dup2(w_out, 4)
        self.proc = subprocess.Popen([exe] + CHROME_ARGS + ["--user-data-dir=" + profile, "about:blank"],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     env=env, pass_fds=(3, 4), preexec_fn=child, start_new_session=True)
        os.close(r_cmd)
        os.close(w_out)

    # --- the wire ---
    def send(self, method, params=None, session=None):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        os.write(self.w_cmd, json.dumps(msg).encode() + b"\0")
        return self.next_id

    def _pump(self, until, timeout):
        end = time.monotonic() + timeout
        while True:
            while b"\0" in self.buf:
                raw, self.buf = self.buf.split(b"\0", 1)
                msg = json.loads(raw)
                if "id" not in msg:
                    self.events.append(msg)
                hit = until(msg)
                if hit is not None:
                    return hit
            left = end - time.monotonic()
            if left <= 0:
                raise CdpError("no answer within %.0f s" % timeout)
            r, _, _ = select.select([self.r_out], [], [], min(left, 0.2))
            if r:
                chunk = os.read(self.r_out, 1 << 20)
                if not chunk:
                    raise CdpError("Chrome closed its pipe (exit %s)" % self.proc.poll())
                self.buf += chunk

    def call(self, method, params=None, session=None, timeout=None):
        i = self.send(method, params, session)
        msg = self._pump(lambda m: m if m.get("id") == i else None, timeout or self.timeout)
        if "error" in msg:
            raise CdpError("%s: %s" % (method, msg["error"].get("message")))
        return msg.get("result", {})

    def page(self):
        target = self.call("Target.createTarget", {"url": "about:blank"})["targetId"]
        session = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        return Page(self, target, session)

    # --- the end, and what it leaves ---
    def leftovers(self):
        mark = self.profile.encode()
        return [r for r in processes() if r[1] == self.proc.pid or r[2] == self.proc.pid or mark in r[3]]

    def close(self):
        """Ends Chrome and answers the processes it left: [] when there are none. A Chrome that does
        not end, or leaves something in its own group, gets that GROUP SIGKILLed -- the one this
        module created, by the pid it recorded; anything else is only reported."""
        try:
            self.call("Browser.close", timeout=10)
        except (CdpError, OSError):
            pass
        try:
            self.proc.wait(15)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(10)
        for fd in (self.w_cmd, self.r_out):
            try:
                os.close(fd)
            except OSError:
                pass
        left = self.leftovers()
        end = time.monotonic() + LEFTOVER_GRACE_S
        while left and time.monotonic() < end:
            time.sleep(0.1)
            left = self.leftovers()
        if any(r[1] == self.proc.pid for r in left):
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return left


class Page:
    def __init__(self, chrome, target, session):
        self.chrome, self.target, self.session = chrome, target, session
        self.call("Page.enable")
        self.call("Runtime.enable")

    def call(self, method, params=None, timeout=None):
        return self.chrome.call(method, params, self.session, timeout)

    def navigate(self, url, timeout=30):
        self.call("Page.navigate", {"url": url})
        self.wait_for("document.readyState === 'complete'", timeout)

    def eval(self, expr, timeout=None):
        """The value of a JS expression (a promise is awaited)."""
        r = self.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": True},
                      timeout)
        if "exceptionDetails" in r:
            raise CdpError("%s: %s" % (expr[:80], r["exceptionDetails"].get("text")))
        return r.get("result", {}).get("value")

    def wait_for(self, expr, timeout=20, interval=0.1):
        end = time.monotonic() + timeout
        while True:
            try:
                v = self.eval(expr)
            except CdpError:
                v = None
            if v:
                return v
            if time.monotonic() > end:
                raise CdpError("waited %.0f s for: %s" % (timeout, expr))
            time.sleep(interval)

    def click(self, element_id):
        """A real mouse click in the middle of the element with this id (it must be visible)."""
        box = self.eval("(() => { const e = document.getElementById(%s); if (!e) return null;"
                        " e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect();"
                        " return [r.x + r.width / 2, r.y + r.height / 2, r.width, r.height]; })()"
                        % json.dumps(element_id))
        if not box or box[2] == 0 or box[3] == 0:
            raise CdpError("no visible element #%s" % element_id)
        for kind in ("mouseMoved", "mousePressed", "mouseReleased"):
            self.call("Input.dispatchMouseEvent", {"type": kind, "x": box[0], "y": box[1], "button": "left",
                                                   "clickCount": 1})

    def focus(self, element_id):
        self.eval("document.getElementById(%s).focus()" % json.dumps(element_id))

    def type(self, text):
        self.call("Input.insertText", {"text": text})

    def key(self, name):
        """A key press (keyDown + keyUp): 'Enter', 'Tab', 'Escape'."""
        codes = {"Enter": 13, "Tab": 9, "Escape": 27}
        for kind in ("keyDown", "keyUp"):
            self.call("Input.dispatchKeyEvent", {"type": kind, "key": name, "code": name,
                                                 "windowsVirtualKeyCode": codes[name],
                                                 "text": "\r" if name == "Enter" and kind == "keyDown" else ""})

    def activate(self):
        self.chrome.call("Target.activateTarget", {"targetId": self.target})
