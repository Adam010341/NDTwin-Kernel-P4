#!/usr/bin/env python3
"""Which NTG hosts file the P4 bridge hands NTG, and the mode line in it.

[Co-developed with claude code -- Adam]

One answer, read by three callers: the P4 bridge (ntg_bmv2_topo.py), which decides the config
NTG starts with; `ndt ntg`, which reports and edits the mode; and the `up. ready` line, which
says what the topology pane holds. Each of them used to have its own idea, and they disagreed.

How NTG finds its mode. The bridge chdirs into the NTG checkout and calls
command_line(net, <config>). NTG hands that file to nornir, whose SimpleInventory opens
inventory.options.host_file -- relative to that cwd -- and NTG reads
`hosts["Mininet_Testbed"].data.get("mode", "cli")`. With no Mininet_Testbed host it looks for
Hardware_Testbed and drives remote worker nodes instead.

🔴 THE BRIDGE ALWAYS HAS A MININET NET, so NTG's hardware-testbed mode is never right there. NTG
   as shipped names setting/Hardware.yaml in its NTG.yaml, and under the bridge that left the
   topology pane waiting on a hardware kernel address with neither mininet> nor a prompt. So
   when the hosts file NTG.yaml names has no Mininet_Testbed entry, the bridge hands NTG a copy
   of NTG.yaml, in a temp dir, whose host_file is <checkout>/setting/Mininet.yaml. The
   checkout is never edited for this. `ndt ntg` then reports and edits that same file.

🔴 IT REFUSES RATHER THAN GUESSES. This is a line reader, not a YAML loader (the kernel side has
   no YAML library to rely on). A shape it cannot read as one plain line -- a mode key in flow
   style, quoted, with a space before the colon, or arriving through a merge key; two
   host_file lines; a host_file under ~ -- is reported as such, and nothing claims a mode for
   it. tests/shell/test_ndt_ntg_mode.sh compares this reading with nornir's own on the same
   files where nornir is installed.

🔴 THE VALUE IS REPLACED WHOLE OR NOT AT ALL. Only the word between the quotes changes; every
   other byte, the line end included, is written back as it was read, in place.

Command line (used by `ndt`): `probe <ntg_dir>` or `set <ntg_dir> <cli|custom_command>`. Prints
one record of six \\x1f-separated fields -- state, NTG.yaml, the hosts file in force, the mode,
a detail sentence, and the hosts file NTG.yaml names when the bridge substitutes another:
  ok            the hosts file has Mininet_Testbed and one mode line NTG knows
  unknown-mode  one parseable mode line whose value NTG does not know (NTG refuses to start)
  hardware-mode one parseable mode line other than cli, in a file that also has Hardware_Testbed:
                NTG then leaves Mininet mode for its hardware-testbed mode, and stops if no
                hardware testbed is set up
  no-mode       Mininet_Testbed has no mode key at all (NTG then uses cli)
  bad-mode      a mode key this cannot read as one plain line, or more than one
  no-mininet    neither the named file nor setting/Mininet.yaml has a Mininet_Testbed entry
  no-host-file  the hosts file NTG.yaml names is not there
  unreadable    a hosts file is there and cannot be read
  unresolved    NTG.yaml does not name one hosts file this can resolve, or cannot be read
  no-ntg-yaml   there is no NTG.yaml
  write-failed  `set` only: the edit could not be written
`set` writes only from ok, unknown-mode or hardware-mode, and exits 3 from any other state
(4: write failed).
"""

import os
import re
import sys

#: NTG's own words for the Mininet testbed's mode (network_traffic_generator.py, command_line).
KNOWN_MODES = ("cli", "custom_command")
#: The Mininet hosts file NTG ships, relative to its checkout.
MININET_HOSTS = os.path.join("setting", "Mininet.yaml")
#: States `set` may write from: the mode line was read whole.
SETTABLE = ("ok", "unknown-mode", "hardware-mode")

KEY = re.compile(r"""^( *)(["']?)([A-Za-z0-9_.<-]+)\2[ \t]*:(?:[ \t]+(.*))?$""")
MODE = re.compile(r"""( +mode:[ \t]*)(?:"([a-z_]+)"|'([a-z_]+)'|([a-z_]+))([ \t]*(?:#.*)?)""")
# Anything in a Mininet_Testbed block NTG could read a mode from: a mode key in any spelling
# (quoted, flow style, a space before the colon), a merge key, or an alias.
MODE_TOKEN = re.compile(r"""(?:^|[\s{,])["']?mode["']?[ \t]*:""")
INDIRECT = re.compile(r"""<<[ \t]*:|:[ \t]*\*|^[ \t]*-?[ \t]*\*""")


class Record:
    """One answer. `where` is (lines, index, match) when a mode line was read whole."""

    def __init__(self, state, conf="", host="", mode="", detail="", via="", where=None):
        self.state, self.conf, self.host, self.mode = state, conf, host, mode
        self.detail, self.via, self.where = detail, via, where

    def line(self):
        return "\x1f".join(str(x).replace("\x1f", " ").replace("\n", " ").replace("\r", " ")
                           for x in (self.state, self.conf, self.host, self.mode,
                                     self.detail, self.via))


def oserror(e):
    """`[Errno 13] Permission denied`, the errno named."""
    return "[Errno %s] %s" % (e.errno, e.strerror)


def lines_of(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "surrogateescape").split("\n")


def bare(raw):
    return raw[:-1] if raw.endswith("\r") else raw


def walk(lines):
    """(index, key path, raw value or None) for every block-mapping key line."""
    stack = []
    for i, raw in enumerate(lines):
        line = bare(raw)
        body = line.lstrip(" ")
        if not body or body.startswith("#") or body.startswith("-") or body.startswith("---"):
            continue
        m = KEY.match(line)
        if not m:
            continue
        ind = len(m.group(1))
        while stack and stack[-1][0] >= ind:
            stack.pop()
        stack.append((ind, m.group(3)))
        yield i, tuple(k for _, k in stack), m.group(4)


def scalar(v):
    v = (v or "").strip()
    for pat in (r"\"([^\"\\]*)\"(?:[ \t]+#.*)?", r"'([^']*)'(?:[ \t]+#.*)?",
                r"([A-Za-z0-9_./~+-]+)(?:[ \t]+#.*)?"):
        m = re.fullmatch(pat, v)
        if m:
            return m.group(1)
    return None


def uncomment(line):
    """The line without a comment: `#` at its start or after a blank."""
    m = re.search(r"(?:^|[ \t])#", line)
    return line[:m.start()] if m else line


def block(lines, entries, top):
    """(first index, text) of the top-level entry `top`: its key line up to the next top key."""
    starts = [(i, p[0]) for i, p, _ in entries if len(p) == 1]
    for n, (i, k) in enumerate(starts):
        if k == top:
            end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
            text = [uncomment(bare(lines[j])) for j in range(i, end)]
            # the key line's own key is not part of what it holds
            text[0] = text[0].split(":", 1)[1] if ":" in text[0] else ""
            return i, text
    return None, []


def named_host_file(ntg):
    """(Record or None, NTG.yaml, entries, host_file index, the resolved path)."""
    conf = os.path.join(ntg, "NTG.yaml")
    if not os.path.isfile(conf):
        return Record("no-ntg-yaml", conf, detail="no such file"), conf, None, None, None
    try:
        lines = lines_of(conf)
    except OSError as e:
        return Record("unresolved", conf, detail="cannot read it: %s" % oserror(e)), conf, None, None, None
    entries = list(walk(lines))
    plugin = [v for _, p, v in entries if p == ("inventory", "plugin")]
    if plugin and scalar(plugin[-1]) != "SimpleInventory":
        return Record("unresolved", conf,
                      detail="its inventory plugin is %s, not SimpleInventory"
                      % (plugin[-1] or "(empty)").strip()), conf, None, None, None
    hf = [(i, v) for i, p, v in entries if p == ("inventory", "options", "host_file")]
    if len(hf) != 1:
        return Record("unresolved", conf,
                      detail="it has %d inventory.options.host_file lines, not one"
                      % len(hf)), conf, None, None, None
    idx, raw = hf[0]
    val = scalar(raw)
    if not val:
        return Record("unresolved", conf,
                      detail="line %d: its host_file value cannot be read: %s"
                      % (idx + 1, (raw or "(empty)").strip())), conf, None, None, None
    if val.startswith("~"):
        return Record("unresolved", conf,
                      detail="line %d: its host_file %s starts with ~, and NTG runs as root "
                      "under the bridge" % (idx + 1, val)), conf, None, None, None
    while val.startswith("./"):
        val = val[2:]
    host = val if os.path.isabs(val) else os.path.join(ntg, val)
    return None, conf, lines, idx, host


def read_hosts(host):
    """(lines, entries) or a Record naming why not."""
    if not os.path.isfile(host):
        return None, "no-host-file"
    try:
        lines = lines_of(host)
    except OSError as e:
        return None, "cannot read it: %s" % oserror(e)
    return (lines, list(walk(lines))), None


def has_mininet(entries):
    return "Mininet_Testbed" in [p[0] for _, p, _ in entries if len(p) == 1]


def classify(conf, host, lines, entries, via):
    i0, text = block(lines, entries, "Mininet_Testbed")
    modes = [i for i, p, _ in entries if p == ("Mininet_Testbed", "data", "mode")]
    tokens = sum(len(MODE_TOKEN.findall(t)) for t in text)
    indirect = [i0 + n for n, t in enumerate(text) if INDIRECT.search(t)]
    if not modes:
        if tokens or indirect:
            at = indirect[0] if indirect else i0 + next(n for n, t in enumerate(text)
                                                         if MODE_TOKEN.search(t))
            return Record("bad-mode", conf, host, "",
                          "line %d: Mininet_Testbed holds a mode NTG would read that is not one "
                          "plain `mode: <word>` line (flow style, a quoted key, a space before the "
                          "colon, or a merge key or alias): %s"
                          % (at + 1, bare(lines[at]).strip()), via)
        return Record("no-mode", conf, host, "cli",
                      "Mininet_Testbed has no mode line; NTG then uses cli", via)
    if len(modes) > 1 or tokens > 1 or indirect:
        return Record("bad-mode", conf, host, "",
                      "Mininet_Testbed holds %d mode keys%s, lines %s"
                      % (max(len(modes), tokens), " and a merge key or alias" if indirect else "",
                         ", ".join(str(i + 1) for i in sorted(set(modes + indirect)))), via)
    i = modes[0]
    text = bare(lines[i])
    m = MODE.fullmatch(text)
    if not m:
        return Record("bad-mode", conf, host, "",
                      "line %d is not  mode: <word>  : %s" % (i + 1, text.strip()), via)
    word = m.group(2) or m.group(3) or m.group(4)
    # NTG's order (command_line): cli enters Mininet's CLI and returns at once; any other mode
    # goes on, and a Hardware_Testbed host in the same inventory then replaces the Mininet
    # communicator with the hardware one -- without the "configuration is invalid" error an
    # unknown mode gets on its own.
    if word != "cli" and "Hardware_Testbed" in [p[0] for _, p, _ in entries if len(p) == 1]:
        return Record("hardware-mode", conf, host, word,
                      "line %d: mode %s, but this file also has a Hardware_Testbed entry, so NTG "
                      "leaves Mininet mode for its hardware-testbed mode (and stops if no hardware "
                      "testbed is set up); only cli keeps it on this fabric" % (i + 1, word),
                      via, (lines, i, m))
    if word not in KNOWN_MODES:
        return Record("unknown-mode", conf, host, word,
                      "line %d: NTG does not know mode %r (it knows %s) and refuses to start"
                      % (i + 1, word, " and ".join(KNOWN_MODES)), via, (lines, i, m))
    return Record("ok", conf, host, word, "line %d" % (i + 1), via, (lines, i, m))


def resolve(ntg):
    """The hosts file the bridge hands NTG, and its mode line."""
    rec, conf, _, _, named = named_host_file(ntg)
    if rec is not None:
        return rec
    got, why = read_hosts(named)
    if got is None:
        if why == "no-host-file":
            return Record("no-host-file", conf, named, "", "the host_file NTG.yaml names is not there")
        return Record("unreadable", conf, named, "", why)
    lines, entries = got
    if has_mininet(entries):
        return classify(conf, named, lines, entries, "")
    if any("Mininet_Testbed" in uncomment(bare(x)) for x in lines):
        # e.g. a flow-style document: NTG may well find the entry this reader cannot see
        return Record("unresolved", conf, named, "",
                      "%s names Mininet_Testbed in a shape this cannot read as a block mapping"
                      % named)
    tops = ", ".join(p[0] for _, p, _ in entries if len(p) == 1) or "none"
    fallback = os.path.join(ntg, MININET_HOSTS)
    if os.path.abspath(fallback) == os.path.abspath(named):
        return Record("no-mininet", conf, named, "",
                      "it has no Mininet_Testbed entry (top-level: %s)" % tops)
    got, why = read_hosts(fallback)
    if got is None and why != "no-host-file":
        # The bridge runs as root and may well read it: say what is known, not "no Mininet".
        return Record("unreadable", conf, fallback, "", why, named)
    if got is None:
        return Record("no-mininet", conf, named, "",
                      "it has no Mininet_Testbed entry (top-level: %s), and %s, which the bridge "
                      "would use instead, is not there" % (tops, fallback))
    flines, fentries = got
    if not has_mininet(fentries):
        return Record("no-mininet", conf, named, "",
                      "it has no Mininet_Testbed entry (top-level: %s), and neither has %s, "
                      "which the bridge would use instead" % (tops, fallback))
    return classify(conf, fallback, flines, fentries, named)


def yaml_dq(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def config_for_bridge(ntg, out_dir):
    """(the config path to hand NTG, a note for the operator or "").

    NTG.yaml itself unless the hosts file it names has no Mininet_Testbed entry and
    setting/Mininet.yaml has one; then a copy of NTG.yaml in out_dir naming that file, with
    every other line as it was.
    """
    conf = os.path.join(ntg, "NTG.yaml")
    rec = resolve(ntg)
    if rec.state == "unreadable" and rec.via:
        # A file this process cannot read is not one to hand NTG; under the bridge (root) this is
        # a real I/O fault, and NTG's own config at least gives NTG's own error.
        return conf, ("[ntg_bmv2_topo] %s names %s, which has no Mininet_Testbed entry, and %s, "
                      "which would be used instead: %s. NTG gets %s as it is."
                      % (conf, rec.via, rec.host, rec.detail, conf))
    if not rec.via:
        if rec.state == "no-mininet":
            return conf, ("[ntg_bmv2_topo] %s names %s: %s. NTG will leave Mininet mode for its "
                          "hardware-testbed mode, and stop if no hardware testbed is set up."
                          % (conf, rec.host, rec.detail))
        if rec.state == "hardware-mode":
            return conf, ("[ntg_bmv2_topo] %s: %s." % (rec.host, rec.detail))
        return conf, ""
    _, _, lines, idx, _ = named_host_file(ntg)
    line = bare(lines[idx])
    cr = "\r" if lines[idx].endswith("\r") else ""
    lines = list(lines)
    lines[idx] = line[:len(line) - len(line.lstrip(" "))] + "host_file: " + yaml_dq(rec.host) + cr
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "NTG.yaml")
    with open(path, "wb") as f:
        f.write("\n".join(lines).encode("utf-8", "surrogateescape"))
    what = {"ok": "its mode: %s." % rec.mode,
            "no-mode": "it has no mode line, so NTG uses cli.",
            "hardware-mode": rec.detail + "."}.get(
        rec.state, "but that file is in a state ndt reports as %s: %s." % (rec.state, rec.detail))
    return path, ("[ntg_bmv2_topo] %s names %s, which has no Mininet_Testbed entry, so NTG would "
                  "leave Mininet mode. NTG gets %s instead: the same config with host_file %s "
                  "(the checkout is not edited); %s" % (conf, rec.via, path, rec.host, what))


def set_mode(ntg, word):
    """(Record, exit code). Writes only from SETTABLE, re-read at the time of writing."""
    rec = resolve(ntg)
    if rec.state not in SETTABLE:
        return rec, 3
    lines, i, m = rec.where
    q = '"' if m.group(2) else ("'" if m.group(3) else "")
    cr = "\r" if lines[i].endswith("\r") else ""
    lines = list(lines)
    lines[i] = m.group(1) + q + word + q + m.group(5) + cr
    data = "\n".join(lines).encode("utf-8", "surrogateescape")
    try:
        with open(rec.host, "r+b") as f:   # in place: the file keeps its inode, owner and mode
            f.seek(0)
            f.write(data)
            f.truncate()
    except OSError as e:
        return Record("write-failed", rec.conf, rec.host, rec.mode,
                      "cannot write it: %s" % oserror(e), rec.via), 4
    return Record("ok", rec.conf, rec.host, word, rec.detail, rec.via), 0


def main(argv):
    if len(argv) == 3 and argv[1] == "probe":
        print(resolve(argv[2]).line())
        return 0
    if len(argv) == 4 and argv[1] == "set" and argv[3] in KNOWN_MODES:
        rec, rc = set_mode(argv[2], argv[3])
        print(rec.line())
        return rc
    print("usage: ntg_config.py probe <ntg_dir> | set <ntg_dir> <%s>" % "|".join(KNOWN_MODES),
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
