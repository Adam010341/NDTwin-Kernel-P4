#!/usr/bin/env python3
"""Mutation gate for the prototype: each mutant must turn run_tests.py red.
Runs every mutant against suite v1 (before mutation-driven additions) and v2 (current).
[Co-developed with claude code -- Adam]"""
import os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
M = [
 ("M1 standard_metadata read without context returns 0",
  '                raise Refuse("standard_metadata key",',
  '                return 0\n                raise Refuse("standard_metadata key",'),
 ("M2 parse_vset entry skipped instead of refused",
  '                raise Refuse("parse_vset", f"{t[\'value\']} (members are written at runtime)")',
  '                continue'),
 ("M3 stack .next does not advance", "                self.stack_next[v] = n + 1", "                self.stack_next[v] = n"),
 ("M4 transition mask ignored", "                if (val & m) == (tv & m) if m is not None else val == tv:", "                if val == tv:"),
 ("M5 IPv4 version/ihl sanity check removed", "            if self.sanity and (ver != 4 or ihl < 5):", "            if False:"),
 ("M6 verify ignored", "            if not cond:", "            if False:"),
 ("M7 reachability exit removed", "                if self.early_x and st not in self.p.ip_reachable", "                if False and st not in self.p.ip_reachable"),
 ("M8 lookahead reads one byte late", "            return self._bits(self.cursor + off, width)", "            return self._bits(self.cursor + off + 8, width)"),
 ("M9 IPv4 not recognised structurally", '        return "ipv4"\n    if total == 320', '        return None\n    if total == 320'),
 ("M10 L4 offset ignores ihl", "            l4 = o + ihl * 4", "            l4 = o + 20"),
 ("M11 outermost IP instead of innermost", "        ip = ips[-1]   # innermost", "        ip = ips[0]"),
 ("M12 varbit length ignored (0)", "            self.extract(v, vl_bits=nbits)", "            self.extract(v, vl_bits=0)"),
 ("M13 truncation reported as PacketTooShort", '                raise ParserError("TRUNCATED",', '                raise ParserError("PacketTooShort",'),
]
src = open(os.path.join(HERE, "p4pi.py")).read()
print(f"{'mutant':<52} {'suite v1':<10} {'suite v2':<10} red cases (v2)")
survivors = []
for name, a, b in M:
    assert src.count(a) == 1, (name, src.count(a))
    res = {}
    for suite in ("v1", "v2"):
        d = tempfile.mkdtemp(prefix="p4pi-mut-")
        for f in ("pkts.py", "run_tests.py"):
            shutil.copy(os.path.join(HERE, f), d)
        os.symlink(os.path.join(HERE, "json"), os.path.join(d, "json"))
        open(os.path.join(d, "p4pi.py"), "w").write(src.replace(a, b))
        env = dict(os.environ, SKIP_PCAP="1", SUITE=suite)
        pr = subprocess.run([sys.executable, os.path.join(d, "run_tests.py")], env=env,
                            capture_output=True, text=True, timeout=300)
        out = pr.stdout + pr.stderr
        fails = [l.split()[1] for l in out.splitlines() if l.startswith("[FAIL]")]
        crashed = "Traceback" in out
        res[suite] = ("RED" if (pr.returncode != 0) else "green", fails, crashed)
        shutil.rmtree(d)
    v1, v2 = res["v1"], res["v2"]
    red = ",".join(v2[1]) + (" (+crash)" if v2[2] else "")
    print(f"{name:<52} {v1[0]:<10} {v2[0]:<10} {red}")
    if v2[0] != "RED":
        survivors.append(name)
print(f"survivors in suite v2: {survivors or 'none'}")
