"""Bring-up A's cells in one LabRound body: static first, then active (design 4.2). (Cut 2)

[Co-developed with claude code -- Adam]

`ARound(...).body(lab_round)` is what probe.py hands LabRound.run for bring-up A. It reads and
stimulates through the round's Runner and Config only, records every observation as evidence
under <run>/A/<cell>.json, and fills `observations` / `sc_observations` for verdict.judge_all.
It does not judge: the verdicts come after bring-up B has supplied the attributions (design 4.2's
order -- A, then B).

`only` (design 4.4 `--only`) narrows the round to the named cells plus everything they depend on:
their controls, their gate cells, the self-checks they need and the cells that produce those
self-checks' readings -- so `--only K1,TTL1` on the mutant artefact runs PL1, T1, TP1, the marker
pingall, K1-neg, K1 and TTL1 (design 5.2-④, Cut 2's see-red run).

Bring-up A's Cut 2 cells: PL1 T1 T2 T3 T4 T5 T6 T7 T8 M1 M2 C1 C2 K1 K2 MT1 MT2 MT3 R2 R3 D1 P1
P2 P3 CS1 TTL1 TP1 (CP1 is T1's alias), VS1 (Q3(b); AP1, AS1 and IT1 are cut 3), the controls
K1-neg and T3-neg, and the self-checks
SC-fwd SC-count SC-reg SC-ttl. Cut 3-5 cells are not observed here; they judge NOT RUN.
"""
from __future__ import annotations

import json
import os

from . import observe as OB
from . import observe_a as OA
from .cells import table as T
from .collect import sniff as S
from .collect.hosts import Hosts
from .lab_round import SignalAbort

HOSTS = ("h1", "h2", "h3", "h4", "h5", "h6")
#: Where the active markers go: from h4 (on s2, where the counter, register and meters are
#: read) to h6 over s2 -> s4 (two hops by the lpm entries thrift reads).
SRC, DST = "h4", "h6"
K1_FRAMES = 200
K2_FRAMES = 200
R2_CHOSEN = 0x1234 + 0x4D      # the non-zero value the R2 marker writes (its sport)
MARKER_FRAMES = 50
PINGALL_EXPECTED = len(HOSTS) * (len(HOSTS) - 1)
PING_FRAMES = 3
PING_DPORT = 40001

#: What each self-check's readings come from (the cell whose step takes them).
SC_PRODUCER = {"SC-fwd": "T1", "SC-count": "K1", "SC-reg": "R2", "SC-ttl": "TTL1"}
#: The cells this round observes, in the order it runs them: static, then active.
STATIC = ("PL1", "TP1", "T2", "M1", "C1", "C2", "P1", "CS1", "MT2", "MT3", "R3", "P3", "VS1")
ACTIVE = ("T1", "K1-neg", "K1", "K2", "R2", "D1", "P2", "TTL1", "T3-neg", "T3", "T4", "T5", "T6",
          "T7", "T8", "M2", "MT1")
CUT2_CELLS = STATIC + ACTIVE


def expand(only, table=T.TABLE):
    """The cells to observe for `--only`: the named ones and, transitively, their controls, their
    gates, and the producers of the self-checks they (and those gates) need."""
    if not only:
        return set(CUT2_CELLS)
    want, todo = set(), list(only)
    by_id = {c.id: c for c in table.cells}
    scs = {s.id: s for s in table.self_checks}
    while todo:
        cid = todo.pop()
        if cid in want:
            continue
        want.add(cid)
        spec = by_id.get(cid) or scs.get(cid)
        if spec is None:
            continue
        todo += list(spec.gates) + list(getattr(spec, "controls", ())) + list(spec.self_checks)
        if getattr(spec, "alias_of", None):
            todo.append(spec.alias_of)
        if cid in SC_PRODUCER:
            todo.append(SC_PRODUCER[cid])
    return {c for c in want if c in CUT2_CELLS}


class ARound(object):
    def __init__(self, cfg, runner, run_id, model, expect_pipelines, runtimes, orders, only=None,
                 out_dir=None, hosts=None):
        self.cfg, self.runner, self.run_id, self.model = cfg, runner, run_id, model
        self.expect_pipelines = expect_pipelines
        self.runtimes, self.orders = runtimes, orders
        self.selected = expand(only)
        self.out_dir = out_dir or os.path.join(cfg.run_dir, "A")
        self.hosts = hosts
        self.observations, self.sc_observations = {}, {}
        self.problems = []
        self.fabric = None

    # --- evidence -----------------------------------------------------------------------------
    def keep(self, cid, obs):
        self.observations[cid] = obs
        with open(os.path.join(self.out_dir, "%s.json" % cid), "w", encoding="utf-8") as fh:
            json.dump(obs, fh, indent=2, sort_keys=True, default=_jsonable)
            fh.write("\n")

    def keep_sc(self, sid, obs):
        self.sc_observations[sid] = obs
        with open(os.path.join(self.out_dir, "%s.json" % sid), "w", encoding="utf-8") as fh:
            json.dump(obs, fh, indent=2, sort_keys=True, default=_jsonable)
            fh.write("\n")

    # --- one window: markers from SRC to DST, sniffed at DST ------------------------------------
    def markers(self, cell, dport, count, sport=40000, src=SRC, dst=DST):
        seconds = 8.0 + count / 500.0
        return self.hosts.window([(dst, [cell], dport)],
                                 lambda: self.hosts.send(src, dst, cell, dport, count, sport=sport),
                                 seconds=seconds, until=count)

    def pingall(self):
        """SC-fwd's marker pingall: PING_FRAMES markers from every host to every other, each
        receiver sniffed. A pair counts as sent when its sender reported >= 1 frame and as
        received when the receiver saw >= 1 of them. -> ((received pairs, sent pairs), frames)."""
        sniffs = [(h, ["SCfwd"], PING_DPORT) for h in HOSTS]
        outs = []

        def stimulate():
            for src in HOSTS:
                for dst in HOSTS:
                    if dst != src:
                        outs.append(self.hosts.send(src, dst, "SCfwd", PING_DPORT, PING_FRAMES,
                                                    sport=40000 + self.hosts.num(src)))
            return "\n".join(outs)
        sent_out, rx = self.hosts.window(sniffs, stimulate, seconds=120.0,
                                         until=(len(HOSTS) - 1) * PING_FRAMES)
        sent = S.sent(sent_out, "SCfwd") or 0
        pairs = sum(1 for o in outs if (S.sent(o, "SCfwd") or 0) > 0)
        got = 0
        for dst, text in rx.items():
            if text is None:
                continue
            srcs = {r.get("ip_src") for r in S.received(text, "SCfwd")}
            got += len(srcs - {self.hosts.ip(dst)})
        return (got, pairs), sent

    # --- the round -------------------------------------------------------------------------------
    def body(self, lab_round):
        os.makedirs(self.out_dir, exist_ok=True)
        if self.hosts is None:
            self.hosts = Hosts(self.cfg, self.runner, self.run_id, self.out_dir, self.model,
                               register=lab_round.register)
        for cid in STATIC + ACTIVE:
            if cid in self.selected:
                self.run_step(cid)
        self.problems += self.hosts.problems
        with open(os.path.join(self.out_dir, "problems.json"), "w", encoding="utf-8") as fh:
            json.dump(self.problems, fh, indent=2)

    def run_step(self, cid):
        """One cell's step. (Cut 2 review m2) An observer that raises on a live shape it did not
        expect costs its own cell only: the exception is recorded, the observation is left
        UNREADABLE (answer and oracle None -> NOT RUN), and the round goes on with the next."""
        try:
            getattr(self, "step_" + cid.replace("-", "_"))()
        except SignalAbort:
            raise                                   # a signal still ends the round (lab_round)
        except Exception as exc:  # noqa: BLE001 -- recorded in problems and in the observation
            why = "%s: %s" % (type(exc).__name__, exc)
            self.problems.append("step %s raised %s" % (cid, why))
            self.keep(cid, {"answer": None, "oracle": None, "negative": None, "sent": None, "error": why})

    # static
    def step_PL1(self):
        self.keep("PL1", OB.observe_pl1(self.cfg, self.runner, self.expect_pipelines))

    def step_TP1(self):
        obs = OA.observe_tp1(self.cfg, self.runner, self.hosts, HOSTS)
        self.fabric = obs["oracle"]
        self.keep("TP1", obs)

    def step_T2(self):
        self.keep("T2", OA.observe_t2(self.cfg, self.runner))

    def step_M1(self):
        self.keep("M1", OB.observe_m1(self.cfg, self.runner))

    def step_C1(self):
        self.keep("C1", OA.observe_c1(self.cfg, self.runner))

    def step_C2(self):
        self.keep("C2", OA.observe_c2(self.cfg, self.runner))

    def step_P1(self):
        self.keep("P1", OA.observe_p1(self.cfg, self.runner))

    def step_CS1(self):
        self.keep("CS1", OA.observe_cs1(self.hosts, HOSTS))

    def step_MT2(self):
        self.keep("MT2", OA.observe_mt2(self.cfg, self.runner))

    def step_MT3(self):
        self.keep("MT3", OA.observe_mt3(self.cfg, self.runner))

    def step_R3(self):
        self.keep("R3", OA.observe_r3(self.cfg, self.runner))

    def step_VS1(self):
        self.keep("VS1", OA.observe_vs1(self.cfg, self.runner))

    def step_P3(self):
        self.keep("P3", OA.observe_p3(self.cfg))

    # active
    def step_T1(self):
        (got, total), sent = self.pingall()
        obs = OA.observe_t1(self.cfg, self.runner, self.runtimes, self.orders, sent)
        self.keep("T1", obs)
        dumps = (obs.get("oracle") or {}).get("dumps")
        expect = obs["expect"]["entries"]
        dump_ok = dumps is not None and all(expect[d] <= (dumps.get(d) or set()) for d in expect)
        self.keep_sc("SC-fwd", {"pingall": (got, total), "expected_total": PINGALL_EXPECTED,
                                "dump_ok": dump_ok})

    def step_K1_neg(self):
        self.keep("K1-neg", OB.observe_counter_control(self.cfg, 2))

    def step_K1(self):
        rx = {}

        def stimulate():
            out, got = self.markers("K1", T.DPORTS["K1"], K1_FRAMES)
            rx["text"] = got.get(DST)
            return out
        obs = OB.observe_counter(self.cfg, self.runner, 2, "c_in", 0, stimulate, "K1")
        self.keep("K1", obs)
        received = None if rx.get("text") is None else len(S.received(rx["text"], "K1"))
        self.keep_sc("SC-count", {"thrift_delta": (obs.get("oracle") or {}).get("delta"),
                                  "sent": obs.get("sent"), "received": received})

    def step_K2(self):
        self.keep("K2", OA.observe_k2(self.cfg, self.runner,
                                      lambda: self.markers("K2", T.DPORTS["K2"], K2_FRAMES)[0]))

    def step_R2(self):
        obs, sc = OA.observe_r2(self.cfg, self.runner,
                                lambda: self.markers("R2", T.DPORTS["R2"], MARKER_FRAMES, sport=R2_CHOSEN)[0],
                                R2_CHOSEN)
        self.keep("R2", obs)
        self.keep_sc("SC-reg", sc)

    def step_D1(self):
        self.keep("D1", OA.observe_d1(self.cfg, lambda: self.hosts.send(SRC, DST, "D1", T.DPORTS["D1"],
                                                                       MARKER_FRAMES, sport=40041),
                                      self.hosts.ip(SRC), 40041))

    def step_P2(self):
        self.keep("P2", OA.observe_p2(self.cfg, lambda: self.hosts.send(SRC, DST, "P2", T.DPORTS["P2"],
                                                                       MARKER_FRAMES)))

    def step_TTL1(self):
        win = self.markers("TTL1", T.DPORTS["TTL1"], MARKER_FRAMES)
        cell, sc = OA.observe_ttl1(self.cfg, self.runner, (win[0], win[1].get(DST)),
                                   self.hosts.ip(DST), OA.links_from(self.fabric))
        self.keep("TTL1", cell)
        self.keep_sc("SC-ttl", sc)

    def step_T3_neg(self):
        self.keep("T3-neg", OA.observe_t3_neg(self.cfg))

    def step_T3(self):
        self.keep("T3", OA.observe_t3(self.cfg, self.runner))

    def step_T4(self):
        self.keep("T4", OA.observe_t4(self.cfg, self.runner))

    def step_T5(self):
        self.keep("T5", OA.observe_t5(self.cfg, self.runner))

    def step_T6(self):
        self.keep("T6", OA.observe_t6(self.cfg, self.runner))

    def step_T7(self):
        self.keep("T7", OA.observe_t7(self.cfg, self.runner))

    def step_T8(self):
        self.keep("T8", OA.observe_t8(self.cfg))

    def step_M2(self):
        self.keep("M2", OA.observe_m2(self.cfg, self.runner))

    def step_MT1(self):
        self.keep("MT1", OA.observe_mt1(self.cfg, self.runner))


def _jsonable(x):
    if isinstance(x, (set, frozenset)):
        return sorted(x, key=repr)
    return repr(x)
