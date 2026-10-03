"""Where the probe reads from and writes to: one object, handed in.

[Co-developed with claude code -- Adam]

design section 4.1: the proxy's and the kernel's addresses and every knob path come from one
`Config`. Section 12 item 9: the Config carries HTTP CLIENT OBJECTS, not URLs, so a test hands it
an in-process client and no socket is ever opened.
"""
from __future__ import annotations

import json
import os

try:                                            # Python 3: the stdlib client; no requests needed
    from urllib import request as _urlreq
    from urllib import error as _urlerr
except ImportError:                             # pragma: no cover
    _urlreq = _urlerr = None

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(PKG))


class HttpReply(object):
    """status (int, or None when nothing answered), parsed JSON body (or None), raw text."""

    def __init__(self, status, body=None, text="", error=None):
        self.status = status
        self.body = body
        self.text = text
        self.error = error

    def __repr__(self):
        return "HttpReply(%r)" % (self.status,)


class HttpClient(object):
    """The real client: urllib, a short timeout, JSON in and out. Never raises."""

    def __init__(self, base_url, timeout=10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def request(self, method, path, body=None):
        data = None
        headers = {}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = _urlreq.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with _urlreq.urlopen(req, timeout=self.timeout) as resp:
                text = resp.read().decode("utf-8", "replace")
                return HttpReply(resp.status, _maybe_json(text), text)
        except _urlerr.HTTPError as exc:
            text = exc.read().decode("utf-8", "replace") if exc.fp is not None else ""
            return HttpReply(exc.code, _maybe_json(text), text)
        except Exception as exc:  # noqa: BLE001 -- unreachable is an answer, not a crash
            return HttpReply(None, None, "", error="%s: %s" % (type(exc).__name__, exc))

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, body):
        return self.request("POST", path, body)


def _maybe_json(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def default_p4dev_python():
    """The interpreter that imports the bmv2 thrift client (and scapy): $P4H_P4DEV_PY, else the
    p4dev venv under the caller's home (the layout the lab machine uses)."""
    return os.environ.get("P4H_P4DEV_PY") or os.path.join(
        os.path.expanduser("~"), "p4dev-python-venv", "bin", "python")


class HermeticViolation(ValueError):
    """A Config default was reached while P4H_HERMETIC is set (the sealed tests set it)."""


class Config(object):
    """Everything the reading layer and the lifecycle need to know about the machine.

    Under P4H_HERMETIC=1 every argument that would otherwise default to the real machine -- the
    proxy and kernel clients, ndt, the knob directory, .test_run, the thrift CLI, the qdisc
    script, the predictions file -- must be passed explicitly, or construction is refused: a
    sealed test that forgot one override must fail before it can touch anything real.
    """

    DEFAULTED = ("proxy", "kernel", "ndt", "knob_dir", "test_run_dir", "thrift_cli",
                 "expected_tsv", "qdisc_snapshot")

    def __init__(self, run_dir, proxy=None, kernel=None, repo=REPO, ndt=None, owner=None,
                 knob_dir=None, test_run_dir=None, thrift_cli=None, thrift_port_base=9090,
                 p4dev_python=None, expected_tsv=None, qdisc_snapshot=None):
        if os.environ.get("P4H_HERMETIC") == "1":
            given = {"proxy": proxy, "kernel": kernel, "ndt": ndt, "knob_dir": knob_dir,
                     "test_run_dir": test_run_dir, "thrift_cli": thrift_cli,
                     "expected_tsv": expected_tsv, "qdisc_snapshot": qdisc_snapshot}
            left = sorted(k for k, v in given.items() if v is None)
            if left:
                raise HermeticViolation("P4H_HERMETIC: Config would default %s to the real machine"
                                        % ", ".join(left))
        self.repo = repo
        self.run_dir = run_dir
        self.proxy = proxy if proxy is not None else HttpClient("http://localhost:8081")
        self.kernel = kernel if kernel is not None else HttpClient("http://localhost:8000")
        self.ndt = ndt or os.path.join(repo, "tools", "test_workflow", "ndt")
        self.owner = owner
        self.knob_dir = knob_dir or os.path.join(repo, "p4_proxy", "mininet")
        self.test_run_dir = test_run_dir or os.path.join(repo, ".test_run")
        self.p4dev_python = p4dev_python or default_p4dev_python()
        # simple_switch_CLI's shebang finds a python3 without thrift on the lab machine; the
        # p4dev venv is the one that imports it (checked 2026-10-03).
        self.thrift_cli = list(thrift_cli or [self.p4dev_python, "/usr/local/bin/simple_switch_CLI"])
        self.thrift_port_base = thrift_port_base
        self.expected_tsv = expected_tsv or os.path.join(
            repo, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv")
        self.qdisc_snapshot = qdisc_snapshot or os.path.join(
            repo, "tools", "test_workflow", "qdisc_snapshot.sh")

    # the two knobs this probe moves and puts back; app_package_override is never touched
    @property
    def knobs(self):
        return {"host_count_override": os.path.join(self.knob_dir, "host_count_override"),
                "telemetry_override": os.path.join(self.knob_dir, "telemetry_override")}

    @property
    def app_package_override(self):
        return os.path.join(self.knob_dir, "app_package_override")

    @property
    def lab_state_path(self):
        return os.path.join(self.run_dir, "LAB_STATE.json")

    @property
    def claim_file(self):
        return os.path.join(self.test_run_dir, "lab.claim")

    def thrift_port(self, dpid):
        return self.thrift_port_base + int(dpid)

    def ndt_env(self):
        if not self.owner:
            raise ValueError("Config.owner (NDT_OWNER) is required for every ndt call")
        return {"NDT_OWNER": self.owner}
