"""The `tc` side: reading the link shaping, and the netem cut the probe makes and takes back.

[Co-developed with claude code -- Adam]

The netem commands are the ones tools/test_workflow/faults.sh uses (`sudo -n tc qdisc ... dev
<if> root netem loss 100%`), on the s2-s4 interfaces, which carry no shaping of their own --
design 4.2. Before any of them runs, lab_round records the interface in LAB_STATE.json.
"""
from __future__ import annotations

import re


def qdisc_show(runner, iface):
    res = runner.run(["tc", "qdisc", "show", "dev", iface], timeout=10)
    return res.stdout if res.rc == 0 else None


def rate_kbit(text):
    """The first `rate <N><unit>` in tc's output, in kbit/s; None when there is none."""
    if text is None:
        return None
    m = re.search(r"\brate (\d+(?:\.\d+)?)([KMG]?)bit\b", text)
    if not m:
        return None
    scale = {"": 0.001, "K": 1.0, "M": 1000.0, "G": 1e6}[m.group(2)]
    return float(m.group(1)) * scale


def netem_add_argv(iface):
    return ["sudo", "-n", "tc", "qdisc", "add", "dev", iface, "root", "netem", "loss", "100%"]


def netem_del_argv(iface):
    """The grant faults.sh records is `del dev s*-eth* root` (faults.sh:54-56), without `netem`."""
    return ["sudo", "-n", "tc", "qdisc", "del", "dev", iface, "root"]
