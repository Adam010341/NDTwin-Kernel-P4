#!/usr/bin/env python3
"""p4pi -- a prototype bmv2-JSON parser interpreter for sampled frames.

[Co-developed with claude code -- Adam]

Question it exists to answer: given only (a) the bmv2 JSON a user's .p4 compiled to and
(b) the first <=128 bytes of a sampled Ethernet frame, can the twin find the inner IPv4/IPv6
header and the L4 ports without the user describing their headers?

What it does
  * loads header_types / headers / header_stacks / parse_vsets / errors / parsers[0];
  * runs the parse graph on the bytes: extract (regular, stack .next), extract_VL with an
    evaluable length, set, verify, add_header/remove_header primitives, lookahead, select on
    concatenated keys with masks, stack_field (.last) keys;
  * identifies IP headers BY STRUCTURE (field widths), never by the user's header name;
  * reads the 5-tuple from the raw bytes at the IP offset, using ihl*4 for the L4 offset.

What it refuses (class N), and says so with the construct named
  * a read of standard_metadata.* when the caller supplied no context for that field;
  * a read of a metadata field the parser never wrote;
  * a parse_vset transition (its members are written by the control plane at runtime);
  * header unions / union stacks, unknown parser ops, unknown expression ops;
  * a read of a field of a header that is not valid.

What it reports but does not refuse
  * bmv2 parser errors (PacketTooShort, StackOutOfBounds, verify failures, NoMatch), with
    TRUNCATED distinguished from PacketTooShort when the capture is shorter than the frame.

Analysis tool only. Not production code; not wired into anything.
"""
from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from typing import Optional


# --------------------------------------------------------------------------------------------
# Exceptions
# --------------------------------------------------------------------------------------------

class Refuse(Exception):
    """Class N: the path cannot be decided from packet bytes + JSON alone."""

    def __init__(self, construct: str, detail: str = ""):
        super().__init__(f"{construct}: {detail}")
        self.construct = construct
        self.detail = detail


class ParserError(Exception):
    """A bmv2 parser error (the switch would set standard_metadata.parser_error)."""

    def __init__(self, name: str, detail: str = ""):
        super().__init__(f"{name}: {detail}")
        self.name = name
        self.detail = detail


# --------------------------------------------------------------------------------------------
# Structural header recognition
# --------------------------------------------------------------------------------------------

def _layout(fields):
    """[(name, bit_offset, width)] for a fixed header type, or None if it has a varbit."""
    out, off = [], 0
    for f in fields:
        w = f[1]
        if w == "*":
            return None
        out.append((f[0], off, w))
        off += w
    return out


def classify_header_type(fields) -> Optional[str]:
    """'ipv4', 'ipv6', 'tcp', 'udp' or None -- from widths and offsets only, never names."""
    lay = _layout(fields)
    if lay is None:
        return None
    total = sum(w for _, _, w in lay)
    at = {off: w for _, off, w in lay}
    if total == 160 and at.get(0) == 4 and at.get(4) == 4 and at.get(72) == 8 \
            and at.get(96) == 32 and at.get(128) == 32:
        return "ipv4"
    if total == 320 and at.get(0) == 4 and at.get(48) == 8 and at.get(56) == 8 \
            and at.get(64) == 128 and at.get(192) == 128:
        return "ipv6"
    if total == 64 and at.get(0) == 16 and at.get(16) == 16 and at.get(32) == 16 \
            and at.get(48) == 16:
        return "udp"
    if total == 160 and at.get(0) == 16 and at.get(16) == 16 and at.get(32) == 32 \
            and at.get(64) == 32 and at.get(96) == 4:
        return "tcp"
    return None


# --------------------------------------------------------------------------------------------
# The program
# --------------------------------------------------------------------------------------------

class Program:
    def __init__(self, path_or_dict):
        if isinstance(path_or_dict, dict):
            j = path_or_dict
            self.path = "<dict>"
        else:
            self.path = path_or_dict
            with open(path_or_dict) as fh:
                j = json.load(fh)
        self.j = j
        self.header_types = {ht["name"]: ht for ht in j["header_types"]}
        self.headers = {h["name"]: h for h in j["headers"]}
        self.stacks = {}
        id2name = {h["id"]: h["name"] for h in j["headers"]}
        for s in j.get("header_stacks", []):
            self.stacks[s["name"]] = {"size": s["size"], "header_type": s["header_type"],
                                      "instances": [id2name[i] for i in s["header_ids"]]}
        self.pvs = {p["name"]: p for p in j.get("parse_vsets", [])}
        self.errors = {v: n for n, v in j.get("errors", [])}
        self.has_unions = bool(j.get("header_unions")) or bool(j.get("header_union_stacks"))
        if len(j["parsers"]) != 1:
            raise Refuse("multiple parsers", f"{len(j['parsers'])} parsers in JSON")
        self.parser = j["parsers"][0]
        self.states = {s["name"]: s for s in self.parser["parse_states"]}
        self.init_state = self.parser["init_state"]
        # structural class per header type
        self.ht_class = {name: classify_header_type(ht["fields"])
                         for name, ht in self.header_types.items()}
        self.ip_reachable = self._ip_reachable()

    def _extracts_ip(self, sname: str) -> bool:
        for op in self.states[sname]["parser_ops"]:
            if op["op"] in ("extract", "extract_VL"):
                t, v = op["parameters"][0]["type"], op["parameters"][0]["value"]
                ht = self.stacks[v]["header_type"] if t == "stack" else \
                    self.headers.get(v, {}).get("header_type")
                if self.ht_class.get(ht) in ("ipv4", "ipv6"):
                    return True
        return False

    def _ip_reachable(self) -> set:
        """States from which some IP-extracting state is reachable (including themselves)."""
        succ = {n: {t["next_state"] for t in s["transitions"] if t["next_state"]}
                for n, s in self.states.items()}
        good = {n for n in self.states if self._extracts_ip(n)}
        changed = True
        while changed:
            changed = False
            for n, nx in succ.items():
                if n not in good and nx & good:
                    good.add(n)
                    changed = True
        return good

    # -- helpers ------------------------------------------------------------------------------
    def header_type_of(self, hname: str) -> dict:
        return self.header_types[self.headers[hname]["header_type"]]

    def is_metadata(self, hname: str) -> bool:
        return bool(self.headers[hname].get("metadata"))

    def field_width(self, hname: str, fname: str) -> int:
        for f in self.header_type_of(hname)["fields"]:
            if f[0] == fname:
                if f[1] == "*":
                    raise Refuse("varbit field read", f"{hname}.{fname}")
                return f[1]
        raise Refuse("unknown field", f"{hname}.{fname}")

    def stack_field_width(self, sname: str, fname: str) -> int:
        ht = self.header_types[self.stacks[sname]["header_type"]]
        for f in ht["fields"]:
            if f[0] == fname:
                return f[1]
        raise Refuse("unknown stack field", f"{sname}.{fname}")


# --------------------------------------------------------------------------------------------
# Runtime state
# --------------------------------------------------------------------------------------------

@dataclass
class Extracted:
    name: str            # header instance name
    header_type: str
    byte_offset: int
    byte_len: int
    fields: dict
    klass: Optional[str]  # structural class


@dataclass
class Result:
    status: str                       # IP | NO_IP | REFUSE | PARSER_ERROR | TRUNCATED | SANITY
    states: list = field(default_factory=list)
    extracted: list = field(default_factory=list)
    ip_family: Optional[str] = None
    ip_offset: Optional[int] = None
    five_tuple: Optional[tuple] = None
    ports_located: bool = False
    l4_program_offset: Optional[int] = None
    detail: str = ""
    consumed: int = 0

    def short(self) -> str:
        if self.status == "IP":
            return (f"IP {self.ip_family}@{self.ip_offset} tuple={fmt_tuple(self.five_tuple)}"
                    f"{'' if self.ports_located else ' (ports beyond capture)'}")
        return f"{self.status} {self.detail}".strip()


def fmt_tuple(t):
    if t is None:
        return "-"
    s, d, p, sp, dp = t
    return f"{s}->{d} proto={p} {sp}->{dp}"


def _ip4(b):
    return ".".join(str(x) for x in b)


class Interpreter:
    def __init__(self, prog: Program, frame: bytes, captured: Optional[int] = None,
                 orig_len: Optional[int] = None, ctx: Optional[dict] = None,
                 max_steps: int = 512, sanity: bool = True, early_x: bool = True):
        self.p = prog
        self.frame = frame if captured is None else frame[:captured]
        self.orig_len = orig_len if orig_len is not None else len(frame)
        self.ctx = ctx or {}
        self.max_steps = max_steps
        self.sanity = sanity
        self.early_x = early_x
        self.cursor = 0                        # bits
        self.valid = {}                        # header instance -> Extracted
        self.meta = {}                         # (hname, fname) -> int, written by the parser
        self.stack_next = {s: 0 for s in prog.stacks}
        self.order = []                        # Extracted, in extraction order

    # -- bit access ---------------------------------------------------------------------------
    def _bits(self, bit_off: int, width: int) -> int:
        end = bit_off + width
        if end > len(self.frame) * 8:
            if len(self.frame) < self.orig_len and end <= self.orig_len * 8:
                raise ParserError("TRUNCATED", f"need bit {end}, capture has {len(self.frame)*8}")
            raise ParserError("PacketTooShort", f"need bit {end}, frame has {len(self.frame)*8}")
        first, last = bit_off // 8, (end + 7) // 8
        v = int.from_bytes(self.frame[first:last], "big")
        shift = last * 8 - end
        return (v >> shift) & ((1 << width) - 1)

    # -- field reads --------------------------------------------------------------------------
    def read_field(self, hname: str, fname: str) -> int:
        p = self.p
        if hname not in p.headers:
            raise Refuse("unknown header", hname)
        if p.is_metadata(hname):
            if hname == "standard_metadata":
                key = f"standard_metadata.{fname}"
                if key in self.ctx:
                    return self.ctx[key]
                raise Refuse("standard_metadata key",
                             f"{key} is not in the packet bytes and no context was given")
            if (hname, fname) in self.meta:
                return self.meta[(hname, fname)]
            raise Refuse("metadata read before parser wrote it", f"{hname}.{fname}")
        ex = self.valid.get(hname)
        if ex is None:
            raise Refuse("read of invalid header", f"{hname}.{fname}")
        if fname not in ex.fields:
            raise Refuse("unknown field", f"{hname}.{fname}")
        return ex.fields[fname]

    def read_stack_last(self, sname: str, fname: str) -> int:
        n = self.stack_next[sname]
        if n == 0:
            raise Refuse("stack .last before any extract", sname)
        inst = self.p.stacks[sname]["instances"][n - 1]
        return self.read_field(inst, fname)

    # -- expressions --------------------------------------------------------------------------
    def eval(self, e) -> int:
        if "type" not in e and "op" in e:
            # p4c wraps some expressions once ({"type":"expression","value":{op}}) and some
            # twice; an op dict reached directly is evaluated as an op
            return self.eval_op(e)
        t = e["type"]
        v = e["value"]
        if t == "hexstr":
            return int(v, 16)
        if t == "bool":
            return 1 if v else 0
        if t == "field":
            return self.read_field(v[0], v[1])
        if t == "stack_field":
            return self.read_stack_last(v[0], v[1])
        if t == "lookahead":
            off, width = v
            return self._bits(self.cursor + off, width)
        if t == "expression":
            return self.eval_op(v)
        if t == "local":
            raise Refuse("local in parser expression", json.dumps(v))
        raise Refuse("unknown operand type", t)

    def eval_op(self, x) -> int:
        if "op" not in x:
            return self.eval(x)
        op = x["op"]
        L = x.get("left")
        R = x.get("right")
        if op == "?":
            return self.eval(L) if self.eval(x["cond"]) else self.eval(R)
        if op in ("d2b", "b2d"):
            return 1 if self.eval(R) else 0
        if op == "not":
            return 0 if self.eval(R) else 1
        if op == "~":
            # bmv2 JSON from p4c always masks after ~, so an unbounded complement is fine
            return ~self.eval(R)
        if op == "valid":
            h = R["value"]
            return 1 if h in self.valid else 0
        a = self.eval(L)
        # short-circuit logic
        if op == "and":
            return 1 if (a and self.eval(R)) else 0
        if op == "or":
            return 1 if (a or self.eval(R)) else 0
        b = self.eval(R)
        ops = {
            "+": lambda: a + b, "-": lambda: a - b, "*": lambda: a * b,
            "&": lambda: a & b, "|": lambda: a | b, "^": lambda: a ^ b,
            "<<": lambda: a << b, ">>": lambda: a >> b,
            "==": lambda: int(a == b), "!=": lambda: int(a != b),
            "<": lambda: int(a < b), ">": lambda: int(a > b),
            "<=": lambda: int(a <= b), ">=": lambda: int(a >= b),
        }
        if op in ops:
            return ops[op]()
        raise Refuse("unsupported expression op", op)

    # -- writes -------------------------------------------------------------------------------
    def write_field(self, hname: str, fname: str, value: int):
        p = self.p
        if p.is_metadata(hname):
            if hname == "standard_metadata":
                # a write is harmless for parsing; record it for later reads
                self.ctx = dict(self.ctx)
                self.ctx[f"standard_metadata.{fname}"] = value
                return
            w = p.field_width(hname, fname)
            self.meta[(hname, fname)] = value & ((1 << w) - 1)
            return
        ex = self.valid.get(hname)
        if ex is None:
            # setValid'd (add_header) headers are created on add_header
            raise Refuse("write to invalid header", f"{hname}.{fname}")
        w = p.field_width(hname, fname)
        ex.fields[fname] = value & ((1 << w) - 1)

    # -- extract ------------------------------------------------------------------------------
    def extract(self, hname: str, vl_bits: Optional[int] = None):
        p = self.p
        ht = p.header_type_of(hname)
        fields = {}
        start = self.cursor
        if start % 8:
            raise Refuse("unaligned extract", hname)
        bit = start
        for f in ht["fields"]:
            fname, w = f[0], f[1]
            if w == "*":
                if vl_bits is None:
                    raise Refuse("varbit extract without length", hname)
                maxbits = ht.get("max_length", 0) * 8 - sum(
                    g[1] for g in ht["fields"] if g[1] != "*")
                if vl_bits < 0 or vl_bits > maxbits:
                    raise ParserError("HeaderTooShort", f"{hname} varbit {vl_bits} > {maxbits}")
                fields[fname] = self._bits(bit, vl_bits) if vl_bits else 0
                bit += vl_bits
            else:
                fields[fname] = self._bits(bit, w)
                bit += w
        self.cursor = bit
        ex = Extracted(name=hname, header_type=ht["name"], byte_offset=start // 8,
                       byte_len=(bit - start) // 8, fields=fields,
                       klass=p.ht_class.get(ht["name"]))
        self.valid[hname] = ex
        self.order.append(ex)

    def do_op(self, op):
        kind = op["op"]
        prm = op["parameters"]
        if kind == "extract":
            t, v = prm[0]["type"], prm[0]["value"]
            if t == "regular":
                self.extract(v)
            elif t == "stack":
                n = self.stack_next[v]
                if n >= self.p.stacks[v]["size"]:
                    raise ParserError("StackOutOfBounds", f"{v}.next with {n} already extracted")
                self.extract(self.p.stacks[v]["instances"][n])
                self.stack_next[v] = n + 1
            else:
                raise Refuse("extract of " + t, str(v))
        elif kind == "extract_VL":
            t, v = prm[0]["type"], prm[0]["value"]
            if t != "regular":
                raise Refuse("extract_VL of " + t, str(v))
            nbits = self.eval(prm[1]["value"] if prm[1]["type"] == "expression" else prm[1])
            self.extract(v, vl_bits=nbits)
        elif kind == "set":
            dst = prm[0]
            if dst["type"] != "field":
                raise Refuse("set to " + dst["type"], json.dumps(dst))
            src = prm[1]
            val = self.eval(src["value"] if src["type"] == "expression" else src)
            self.write_field(dst["value"][0], dst["value"][1], val)
        elif kind == "verify":
            cond = self.eval(prm[0]["value"] if prm[0]["type"] == "expression" else prm[0])
            if not cond:
                err = self.eval(prm[1])
                raise ParserError(self.p.errors.get(err, f"error{err}"), "verify failed")
        elif kind == "primitive":
            inner = prm[0]
            iop = inner["op"]
            if iop == "add_header":
                h = inner["parameters"][0]["value"]
                ht = self.p.header_type_of(h)
                self.valid[h] = Extracted(name=h, header_type=ht["name"],
                                          byte_offset=-1, byte_len=0,
                                          fields={f[0]: 0 for f in ht["fields"]},
                                          klass=None)  # synthesised, not on the wire
            elif iop == "remove_header":
                self.valid.pop(inner["parameters"][0]["value"], None)
            else:
                raise Refuse("parser primitive " + iop, json.dumps(inner)[:120])
        elif kind == "advance":
            nbits = self.eval(prm[0]["value"] if prm[0]["type"] == "expression" else prm[0])
            self.cursor += nbits
        else:
            raise Refuse("parser op " + kind, json.dumps(op)[:120])

    # -- transitions --------------------------------------------------------------------------
    def key_value(self, state):
        val, width = 0, 0
        for k in state["transition_key"]:
            t, v = k["type"], k["value"]
            if t == "field":
                w = self.p.field_width(v[0], v[1])
                x = self.read_field(v[0], v[1])
            elif t == "stack_field":
                w = self.p.stack_field_width(v[0], v[1])
                x = self.read_stack_last(v[0], v[1])
            elif t == "lookahead":
                w = v[1]
                x = self._bits(self.cursor + v[0], v[1])
            else:
                raise Refuse("transition key type " + t, json.dumps(v))
            val = (val << w) | (x & ((1 << w) - 1))
            width += w
        return val, width

    def next_state(self, state):
        trans = state["transitions"]
        if not state["transition_key"]:
            for t in trans:
                if t["type"] == "default":
                    return t["next_state"]
            raise Refuse("keyless state without default", state["name"])
        val, _w = self.key_value(state)
        for t in trans:
            ty = t["type"]
            if ty == "hexstr":
                m = int(t["mask"], 16) if t.get("mask") else None
                tv = int(t["value"], 16)
                if (val & m) == (tv & m) if m is not None else val == tv:
                    return t["next_state"]
            elif ty == "default":
                return t["next_state"]
            elif ty == "parse_vset":
                raise Refuse("parse_vset", f"{t['value']} (members are written at runtime)")
            else:
                raise Refuse("transition type " + ty, json.dumps(t))
        raise ParserError("NoMatch", f"state {state['name']} key 0x{val:x}")

    # -- run ----------------------------------------------------------------------------------
    def run(self) -> Result:
        res = Result(status="?")
        if self.p.has_unions:
            res.status, res.detail = "REFUSE", "header unions present"
            return res
        st = self.p.init_state
        steps = 0
        try:
            while st is not None:
                steps += 1
                if steps > self.max_steps:
                    raise ParserError("ParserTimeout", f"> {self.max_steps} states")
                state = self.p.states[st]
                res.states.append(st)
                if self.early_x and st not in self.p.ip_reachable and not any(
                        x.klass in ("ipv4", "ipv6") for x in self.order):
                    # no IP header can follow from here: class X, decided without reading on
                    res.detail = f"no IP-extracting state reachable from {st}"
                    break
                for op in state["parser_ops"]:
                    self.do_op(op)
                st = self.next_state(state)
        except Refuse as r:
            res.status, res.detail = "REFUSE", f"[{r.construct}] {r.detail}"
        except ParserError as e:
            res.status = "TRUNCATED" if e.name == "TRUNCATED" else "PARSER_ERROR"
            res.detail = f"{e.name}: {e.detail}"
        res.extracted = [(x.name, x.byte_offset, x.byte_len, x.klass) for x in self.order]
        res.consumed = self.cursor // 8
        self._identify(res)
        return res

    def _identify(self, res: Result):
        ips = [x for x in self.order if x.klass in ("ipv4", "ipv6")]
        if not ips:
            if res.status == "?":
                res.status = "NO_IP"
            return
        ip = ips[-1]   # innermost
        fr = self.frame
        o = ip.byte_offset
        res.ip_family, res.ip_offset = ip.klass, o
        prior = res.status
        if ip.klass == "ipv4":
            ver, ihl = fr[o] >> 4, fr[o] & 0x0F
            if self.sanity and (ver != 4 or ihl < 5):
                if prior == "?":
                    res.status = "SANITY"
                    res.detail = (f"structural IPv4 at {o} has version={ver} ihl={ihl}; "
                                  f"refusing (the JSON and the wire disagree)")
                return
            proto = fr[o + 9]
            src, dst = _ip4(fr[o + 12:o + 16]), _ip4(fr[o + 16:o + 20])
            frag = struct.unpack(">H", fr[o + 6:o + 8])[0] & 0x1FFF
            l4 = o + ihl * 4
        else:
            proto = fr[o + 6]
            src = fr[o + 8:o + 24].hex()
            dst = fr[o + 24:o + 40].hex()
            frag = 0
            l4 = o + 40   # extension headers: not walked by the prototype
        sp = dp = 0
        located = False
        if frag == 0:
            if proto in (6, 17) and l4 + 4 <= len(fr):
                sp, dp = struct.unpack(">HH", fr[l4:l4 + 4])
                located = True
            elif proto in (1, 58) and l4 + 2 <= len(fr):
                sp, dp = fr[l4], fr[l4 + 1]
                located = True
            elif proto not in (6, 17, 1, 58):
                located = True   # no ports to find
        else:
            located = True       # non-first fragment: no ports exist
        res.five_tuple = (src, dst, proto, sp, dp)
        res.ports_located = located
        # cross-check: an L4 header the program itself extracted after IP
        after = [x for x in self.order if x.klass in ("tcp", "udp") and x.byte_offset > o]
        if after:
            res.l4_program_offset = after[0].byte_offset
        if prior == "?":
            res.status = "IP"
        elif prior in ("PARSER_ERROR", "TRUNCATED") and located:
            # the IP header (and the ports) were read before the error: still an identity
            res.detail += " (IP+ports were extracted before the error)"
            res.status = "IP"


def interpret(prog: Program, frame: bytes, **kw) -> Result:
    return Interpreter(prog, frame, **kw).run()


# --------------------------------------------------------------------------------------------
# Static analysis: every start->accept path, loops collapsed to patterns, class per path
# --------------------------------------------------------------------------------------------

def _expr_refs(e, out):
    """Collect (kind, value) references of an expression tree."""
    if e is None:
        return
    if isinstance(e, dict):
        t = e.get("type")
        if t == "field":
            out.append(("field", tuple(e["value"])))
        elif t == "stack_field":
            out.append(("stack_field", tuple(e["value"])))
        elif t == "lookahead":
            out.append(("lookahead", tuple(e["value"])))
        elif t == "expression":
            _expr_refs(e["value"], out)
        elif "op" in e:
            for k in ("left", "right", "cond"):
                _expr_refs(e.get(k), out)
        elif t in ("header",):
            out.append(("header", e["value"]))


def state_constructs(prog: Program, sname: str):
    """What a state uses: tags that decide the class, plus the headers it extracts."""
    s = prog.states[sname]
    tags, extracts = set(), []
    refs = []
    for op in s["parser_ops"]:
        k = op["op"]
        if k == "extract":
            t, v = op["parameters"][0]["type"], op["parameters"][0]["value"]
            if t == "stack":
                tags.add("stack")
                extracts.append(("stack", v, prog.stacks[v]["header_type"]))
            elif t == "regular":
                extracts.append(("regular", v, prog.headers[v]["header_type"]))
            else:
                tags.add("N:extract-" + t)
        elif k == "extract_VL":
            tags.add("varbit")
            extracts.append(("varbit", op["parameters"][0]["value"],
                             prog.headers[op["parameters"][0]["value"]]["header_type"]))
            _expr_refs(op["parameters"][1], refs)
        elif k in ("set", "verify", "advance"):
            for prm in op["parameters"]:
                _expr_refs(prm, refs)
            if k == "verify":
                tags.add("verify")
            if k == "advance":
                tags.add("advance")
        elif k == "primitive":
            iop = op["parameters"][0]["op"]
            if iop not in ("add_header", "remove_header"):
                tags.add("N:primitive-" + iop)
        else:
            tags.add("N:op-" + k)
    for key in s["transition_key"]:
        if key["type"] == "lookahead":
            tags.add("lookahead-key")
        refs.append((key["type"], tuple(key["value"])))
    for kind, val in refs:
        if kind == "field" and val[0] == "standard_metadata":
            tags.add(f"N:standard_metadata.{val[1]}")
        if kind == "lookahead":
            tags.add("lookahead")
    return tags, extracts, refs


def enumerate_paths(prog: Program):
    """DFS start->accept. A transition to a state already on the DFS stack is a loop edge:
    recorded as a pattern on the path, not followed."""
    paths = []

    def edges(sname):
        # bmv2 tries transitions in order, so an edge is decided by runtime-written vset
        # contents iff a parse_vset entry comes at or before it in the list.
        s = prog.states[sname]
        out = []
        vset_seen = False
        for t in s["transitions"]:
            if t["type"] == "parse_vset":
                vset_seen = True
            if t["type"] == "default":
                lab = "default"
            elif t["type"] == "parse_vset":
                lab = f"vset:{t['value']}"
            else:
                lab = t["value"] + (f"&{t['mask']}" if t.get("mask") else "")
            if vset_seen:
                lab += "{vset-dependent}"
            out.append((lab, t["next_state"]))
        return out

    def dfs(sname, stack, labels, loops):
        stack = stack + [sname]
        for lab, nxt in edges(sname):
            if nxt is None:
                paths.append({"states": stack, "labels": labels + [lab], "loops": list(loops)})
            elif nxt in stack:
                loops_here = loops + [(sname, lab, nxt)]
                # the loop itself is not a path; its exits are explored from the states on
                # the stack, so record the pattern on every path that continues from here
                pending_loops.setdefault(tuple(stack), []).append((sname, lab, nxt))
            else:
                dfs(nxt, stack, labels + [lab], loops)

    pending_loops = {}
    dfs(prog.init_state, [], [], [])
    # attach loops: a path carries every loop whose source and target are both on it
    all_loops = [l for ls in pending_loops.values() for l in ls]
    uniq = []
    for l in all_loops:
        if l not in uniq:
            uniq.append(l)
    for p in paths:
        p["loops"] = [l for l in uniq if l[0] in p["states"] and l[2] in p["states"]]
    return paths


def classify_path(prog: Program, path) -> dict:
    tags, extracts, notes = set(), [], []
    for s in path["states"]:
        t, ex, _ = state_constructs(prog, s)
        tags |= t
        extracts += ex
    if any("{vset-dependent}" in lab for lab in path["labels"]):
        tags.add("N:parse_vset")
    # an N tag on a state only matters if the path's choice depends on it; a standard_metadata
    # read in a state that has no transition key and feeds no later key is still flagged,
    # conservatively (we do not do dataflow on scalars across states here).
    n_tags = sorted(t for t in tags if t.startswith("N:"))
    has_loop = bool(path["loops"]) or "stack" in tags
    has_ip = any(prog.ht_class.get(ht) in ("ipv4", "ipv6") for _, _, ht in extracts)
    ip_kind = [prog.ht_class.get(ht) for _, _, ht in extracts
               if prog.ht_class.get(ht) in ("ipv4", "ipv6")]
    # IP offset range along the path: fixed headers add their width; a stack adds 1..size
    # entries; a varbit adds 0..max_length. Stops at the (first) IP header on the path.
    lo = hi = 0
    ip_lo = ip_hi = None
    seen_stack = set()
    for kind, name, ht in extracts:
        cls = prog.ht_class.get(ht)
        if cls in ("ipv4", "ipv6"):
            ip_lo, ip_hi = lo, hi
            break
        hw = _layout(prog.header_types[ht]["fields"])
        if kind == "stack":
            if name in seen_stack:
                continue
            seen_stack.add(name)
            w = sum(x for _, _, x in hw) // 8
            lo += w
            hi += w * prog.stacks[name]["size"]
        elif kind == "varbit":
            fixed_bits = sum(f[1] for f in prog.header_types[ht]["fields"] if f[1] != "*")
            lo += fixed_bits // 8
            hi += prog.header_types[ht].get("max_length", 0)
        else:
            w = sum(x for _, _, x in hw) // 8
            lo += w
            hi += w
    if not has_ip:
        klass = "X"
    elif n_tags:
        klass = "N"
    elif has_loop or "varbit" in tags:
        klass = "D2"
    else:
        klass = "D1"
    return {"class": klass, "n_constructs": n_tags, "tags": sorted(tags),
            "ip": ip_kind, "ip_offset_min": ip_lo, "ip_offset_max": ip_hi,
            "also_N": bool(n_tags) and klass == "X"}


def describe_path(path) -> str:
    parts = []
    for s, lab in zip(path["states"], path["labels"]):
        parts.append(f"{s} -[{lab}]->")
    txt = " ".join(parts) + " accept"
    if path["loops"]:
        txt += "  loops: " + ", ".join(f"{a}-[{l}]->{b}" for a, l, b in path["loops"])
    return txt


# --------------------------------------------------------------------------------------------
# Native model: a Python re-statement of identifyFrame (include/common_types/SFlowType.hpp
# 267-511). A MODEL of the C++, not the C++ -- the report keeps its column separate.
# --------------------------------------------------------------------------------------------

def native_identify(frame: bytes):
    n = len(frame)
    if n < 14:
        return ("undecodable", None)
    et = struct.unpack(">H", frame[12:14])[0]
    pl = 14
    if et == 0x8100 and pl + 4 <= n:
        et = struct.unpack(">H", frame[pl + 2:pl + 4])[0]
        pl += 4
    if et == 0x0800:
        if pl + 20 > n:
            return ("ipv4-unidentified", None)
        ihl = frame[pl] & 0x0F
        if ihl < 5:
            return ("ipv4-malformed-ihl", None)
        if pl + ihl * 4 > n:
            return ("ipv4-unidentified", None)
        proto = frame[pl + 9]
        src, dst = _ip4(frame[pl + 12:pl + 16]), _ip4(frame[pl + 16:pl + 20])
        frag = struct.unpack(">H", frame[pl + 6:pl + 8])[0] & 0x1FFF
        l4 = pl + ihl * 4
        sp = dp = 0
        if frag == 0:
            if proto == 1 and l4 + 2 <= n:
                sp, dp = frame[l4], frame[l4 + 1] & 0x0F
            elif proto in (6, 17) and l4 + 4 <= n:
                sp, dp = struct.unpack(">HH", frame[l4:l4 + 4])
        return ("ipv4", (src, dst, proto, sp, dp))
    if et == 0x86DD:
        if pl + 40 > n:
            return ("ipv6-unidentified", None)
        return ("ipv6", (frame[pl + 8:pl + 24].hex(), frame[pl + 24:pl + 40].hex(),
                         frame[pl + 6], 0, 0))
    return ("l2", (frame[6:12].hex(), frame[0:6].hex(), hex(et)))


# --------------------------------------------------------------------------------------------
# Hints: the hand-written alternative, minimal engine for the same packets
# --------------------------------------------------------------------------------------------

def parse_hints(text: str):
    """Lines: `0x1212 fixed 4 next=u16@0`  or  `0x1234 stack 2 until=bit0 next=0x0800`."""
    rules = {}
    for line in text.strip().splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        w = line.split()
        et = int(w[0], 16)
        kind = w[1]
        size = int(w[2])
        kv = dict(x.split("=", 1) for x in w[3:])
        rules[et] = (kind, size, kv)
    return rules


def hints_identify(rules, frame: bytes, depth: int = 4):
    """Hints are an ADDITION to the native parser: with no hint for the frame's ethertype the
    native model decides, exactly as today."""
    n = len(frame)
    if n < 14:
        return ("undecodable", None)
    et = struct.unpack(">H", frame[12:14])[0]
    if et not in rules:
        return native_identify(frame)
    off = 14
    for _ in range(depth):
        if et not in rules:
            break
        kind, size, kv = rules[et]
        if kind == "fixed":
            hdr = off
            off += size
            nxt = kv.get("next", "0x0800")
            if nxt.startswith("u16@"):
                k = int(nxt[4:])
                if hdr + k + 2 > n:
                    return ("truncated", None)
                et = struct.unpack(">H", frame[hdr + k:hdr + k + 2])[0]
            else:
                et = int(nxt, 16)
        elif kind == "stack":
            bit = int(kv["until"].replace("bit", ""))
            while True:
                if off + size > n:
                    return ("truncated", None)
                last = (frame[off] >> (7 - bit)) & 1
                off += size
                if last:
                    break
            et = int(kv.get("next", "0x0800"), 16)
        elif kind == "l2only":
            return ("l2", None)
    if et in (0x0800, 0x86DD):
        fake = frame[:12] + struct.pack(">H", et) + frame[off:]
        return native_identify(fake)
    return ("l2", None)
