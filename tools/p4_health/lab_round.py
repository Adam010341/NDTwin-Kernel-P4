"""One bring-up's lifecycle: claim -> up -> cells -> teardown, crash-safe. (Q1(a))

[Co-developed with claude code -- Adam]

design 4.2 and 4.5, with section 12 items 10 and 12. In Cut 1 this is exercised ONLY offline,
through a RecordingRunner (tests/python/test_p4_health_collect.py); nothing in Cut 1 calls it
against the lab.

  * Before every step that changes the machine, LAB_STATE.json is rewritten (atomically) with
    the probe's pid, the owner, the bring-up, the phase, the knob snapshot, the netem
    interfaces, the sniffer and controller pids and the qdisc snapshot -- so `recover.sh <run>`
    can finish what a crash left. The claim note carries the file's path.
  * The qdisc snapshot is taken AFTER `ndt up` and before any netem (12-12): before the up there
    is no fabric to snapshot.
  * SIGTERM, SIGINT and SIGHUP become an exception, so they take the `finally`.
  * The teardown, in order: stop sniffers -> stop controllers -> remove netem -> compare qdisc
    -> `ndt down` -> put the two knobs back as BYTES -> `ndt release`. A qdisc mismatch is
    recorded and does NOT stop the down, the restore or the release -- only recover.sh stops
    there (12-10). A failed `ndt down` DOES stop the release: a lab released with a fabric
    still up is a lab the next session tears down blind (12-10).
  * `app_package_override` is never touched: `ndt down` clears it (ndt:1597-1601).
  * A claim that is refused makes the round INCOMPLETE; there is no --force.
  * (Cut 1 review, MAJ-6) A sniffer or controller is recorded as pid + start time
    (/proc/<pid>/stat field 22) + a marker its command line carries (the run id), and is signalled
    only while all three still match; once stopped it leaves LAB_STATE.json, so nothing kills it
    again later. Before every teardown step that changes shared state (netem, `ndt down`, the
    knobs, the release) the claim is re-read: if it is no longer ours and live, the teardown
    stops there and leaves the rest to recover.sh. A netem whose add failed leaves the list.
"""
from __future__ import annotations

import base64
import json
import os
import signal
import time

from .collect import proxy as P
from .collect import tc as TC

PHASES = ("pre-claim", "claiming", "up", "cells", "teardown", "released", "down-failed",
          "claim-refused", "lab-busy")


class SignalAbort(Exception):
    def __init__(self, signum):
        Exception.__init__(self, "signal %d" % signum)
        self.signum = signum


class RootRefused(RuntimeError):
    pass


def lab_busy(status_text, claim_text, owner, now):
    """Why the lab must not be touched, or None. `ndt status --measuring` rows (a `declared` row,
    or a `measuring` row that is not `nothing`), or a live claim held by someone else."""
    for line in (status_text or "").splitlines():
        parts = line.split(None, 1)
        if not parts:
            continue
        if parts[0] == "declared":
            return "a measurement is declared: %s" % (parts[1] if len(parts) > 1 else "")
        if parts[0] == "measuring" and (len(parts) < 2 or parts[1].strip() != "nothing"):
            return "a measurement is in flight: %s" % (parts[1] if len(parts) > 1 else "")
    fields = {}
    for line in (claim_text or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            fields.setdefault(k.strip(), v.strip())
    if fields.get("owner") and fields["owner"] != owner:
        try:
            expires = int(fields.get("expires", "0"))
        except ValueError:
            expires = 0
        if expires > now:
            return "the lab is claimed by %s until %d" % (fields["owner"], expires)
    if fields.get("measuring"):
        return "the claim declares measuring=%s" % fields["measuring"]
    return None


def read_claim(path):
    """The claim file's fields ({} when there is none)."""
    fields = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    fields.setdefault(k.strip(), v.strip())
    except OSError:
        pass
    return fields


def proc_identity(pid, proc_root="/proc"):
    """(start time in clock ticks, command line) of a live pid, or None when it is gone."""
    try:
        with open(os.path.join(proc_root, str(pid), "stat"), encoding="utf-8", errors="replace") as fh:
            stat = fh.read()
        with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as fh:
            cmdline = fh.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        return None
    # field 2 (comm) may hold spaces; everything after its closing ")" splits cleanly
    rest = stat[stat.rfind(")") + 2:].split()
    try:
        return int(rest[19]), cmdline          # field 22 = index 19 after pid and comm
    except (IndexError, ValueError):
        return None


class LabRound(object):
    def __init__(self, cfg, runner, bringup, package_dir, run_id, minutes=45, pid=None,
                 clock=time.time, install_signals=True, proc_root="/proc"):
        self.cfg, self.runner = cfg, runner
        self.bringup, self.package_dir, self.run_id = bringup, package_dir, run_id
        self.minutes = minutes
        self.pid = pid if pid is not None else os.getpid()
        self.clock = clock
        self.install_signals = install_signals
        self.proc_root = proc_root
        me = proc_identity(self.pid, proc_root)
        self.state = {"pid": self.pid, "pid_start": me[0] if me else None, "owner": cfg.owner, "run": run_id, "bring_up": bringup,
                      "package": os.path.abspath(package_dir), "phase": "pre-claim",
                      "knob_snapshot": {}, "netem": [], "sniffers": [], "controllers": [],
                      "qdisc_before": None, "knob_paths": dict(cfg.knobs),
                      "app_package_override": cfg.app_package_override,
                      "claim_file": cfg.claim_file, "ndt": cfg.ndt}
        self.knobs = {}
        self.events = []

    # --- LAB_STATE.json ---------------------------------------------------------------------------
    def write_state(self, **changes):
        self.state.update(changes)
        path = self.cfg.lab_state_path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.state, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
        self.events.append(("state", self.state["phase"]))

    # --- the two knobs, as bytes --------------------------------------------------------------------
    def snapshot_knobs(self):
        snap = {}
        for name, path in sorted(self.cfg.knobs.items()):
            try:
                with open(path, "rb") as fh:
                    snap[name] = fh.read()
            except FileNotFoundError:
                snap[name] = None
        self.knobs = snap
        return {k: (None if v is None else base64.b64encode(v).decode("ascii")) for k, v in snap.items()}

    def restore_knobs(self):
        """Every knob back to the bytes it had (or absent). Returns (ok, why)."""
        problems = []
        for name, before in sorted(self.knobs.items()):
            path = self.cfg.knobs[name]
            try:
                if before is None:
                    if os.path.exists(path):
                        os.remove(path)
                else:
                    with open(path, "rb") as fh:
                        now = fh.read()
                    if now != before:
                        with open(path, "wb") as fh:
                            fh.write(before)
            except OSError as exc:
                problems.append("%s: %s" % (name, exc))
        self.events.append(("knobs", "restored" if not problems else "failed"))
        return (not problems), "; ".join(problems)

    # --- commands -----------------------------------------------------------------------------------
    def ndt(self, args, timeout=900):
        res = self.runner.run([self.cfg.ndt] + list(args), env=self.cfg.ndt_env(), timeout=timeout)
        self.events.append(("ndt", args[0]))
        return res

    def check_lab(self):
        st = self.ndt(["status", "--measuring"], timeout=60)
        try:
            with open(self.cfg.claim_file, encoding="utf-8") as fh:
                claim = fh.read()
        except OSError:
            claim = ""
        if st.rc != 0:
            return "ndt status --measuring exited %s" % st.rc
        return lab_busy(st.stdout, claim, self.cfg.owner, int(self.clock()))

    def add_netem(self, iface):
        """Record the interface FIRST, then cut it; an add that failed is taken off the list
        again, so the teardown never runs `del root` on an interface it did not change."""
        self.write_state(netem=self.state["netem"] + [iface])
        res = self.runner.run(TC.netem_add_argv(iface), timeout=30)
        self.events.append(("netem-add", iface))
        if res.rc != 0:
            self.write_state(netem=[i for i in self.state["netem"] if i != iface])
        return res

    def register(self, kind, pid, marker=None):
        """A sniffer or controller, recorded the moment it is known, by pid + start time +
        command-line marker (the run id unless given). Refused when the pid's command line does
        not carry the marker: that process is not ours to stop later."""
        key = {"sniffer": "sniffers", "controller": "controllers"}[kind]
        marker = marker or self.run_id
        ident = proc_identity(pid, self.proc_root)
        if ident is None or marker not in ident[1]:
            raise ValueError("pid %s is not a process carrying %r" % (pid, marker))
        entry = {"pid": int(pid), "start": ident[0], "marker": marker}
        self.write_state(**{key: self.state[key] + [entry]})
        return entry

    def claim_ours(self):
        """(ours?, why) for the claim as it is NOW: our owner, and not expired."""
        f = read_claim(self.cfg.claim_file)
        try:
            expires = int(f.get("expires", "0"))
        except ValueError:
            expires = 0
        if f.get("owner") != self.cfg.owner:
            return False, "the claim's owner is %r" % (f.get("owner"),)
        if expires <= int(self.clock()):
            return False, "the claim expired at %d" % expires
        return True, ""

    # --- the round ------------------------------------------------------------------------------------
    def _handlers(self, on):
        if not self.install_signals:
            return
        sigs = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
        if on:
            def raiser(signum, _frame):
                raise SignalAbort(signum)
            self._old = {s: signal.signal(s, raiser) for s in sigs}
        else:
            # During the teardown a second signal must not abort the cleanup: noted, ignored.
            def noter(signum, _frame):
                self.events.append(("signal-during-teardown", signum))
            for s in sigs:
                signal.signal(s, noter)

    def _restore_handlers(self):
        if self.install_signals and getattr(self, "_old", None):
            for s, h in self._old.items():
                signal.signal(s, h)

    def run(self, body):
        if os.geteuid() == 0:
            raise RootRefused("the probe refuses to run as root (design 7.3)")
        rec = {"id": self.bringup, "up_rc": None, "down_rc": None, "release_rc": None,
               "claim_rc": None, "knobs_restored": None, "qdisc_same": None,
               "heartbeat_state": None, "frames_reached_hosts": None, "seconds": None,
               "complete": False, "problems": []}
        t0 = self.clock()
        busy = self.check_lab()
        if busy:
            rec["problems"].append("lab busy: %s" % busy)
            self.write_state(phase="lab-busy")
            return rec
        snap = self.snapshot_knobs()
        self.write_state(phase="pre-claim", knob_snapshot=snap)
        self.write_state(phase="claiming")
        note = "p4-health %s %s state=%s" % (self.run_id, self.bringup, self.cfg.lab_state_path)
        claim = self.ndt(["claim", str(self.minutes), note], timeout=60)
        rec["claim_rc"] = claim.rc
        if claim.rc != 0:
            rec["problems"].append("claim refused (rc %s); no --force" % claim.rc)
            self.write_state(phase="claim-refused")
            return rec
        self._handlers(True)
        try:
            self.write_state(phase="up")
            up = self.ndt(["up", "p4", "--app", self.package_dir], timeout=1800)
            rec["up_rc"] = up.rc
            if up.rc != 0:
                raise RuntimeError("ndt up p4 --app exited %s" % up.rc)
            before = os.path.join(self.cfg.run_dir, "qdisc.%s.before" % self.bringup)
            snap_res = self.runner.run([self.cfg.qdisc_snapshot, "save", before], timeout=60)
            self.write_state(qdisc_before=before if snap_res.rc == 0 else None)
            self.write_state(phase="cells")
            body(self)
            state = P.switch_state(self.cfg)
            hb = (state or {}).get("heartbeat") or {}
            rec["heartbeat_state"] = hb.get("state")
            rec["frames_reached_hosts"] = hb.get("frames_reached_hosts")
            if rec["frames_reached_hosts"] is True:
                rec["problems"].append("frames_reached_hosts is true: a heartbeat frame reached a host")
            rec["complete"] = True
        except SignalAbort as exc:
            rec["problems"].append("aborted by signal %d" % exc.signum)
        except Exception as exc:  # noqa: BLE001 -- recorded; the teardown below runs regardless
            rec["problems"].append("%s: %s" % (type(exc).__name__, exc))
        finally:
            self._handlers(False)
            try:
                self.teardown(rec)
            finally:
                self._restore_handlers()
        rec["seconds"] = round(self.clock() - t0, 1)
        if rec["frames_reached_hosts"] is True or rec["release_rc"] != 0 or rec["down_rc"] != 0:
            rec["complete"] = False
        return rec

    def _stop(self, key, entry, root):
        """Signal one recorded process if it is still the one we started; then forget it."""
        pid = entry["pid"]
        ident = proc_identity(pid, self.proc_root)
        if ident is None:
            outcome = "gone"
        elif ident[0] != entry["start"] or entry["marker"] not in ident[1]:
            outcome = "not ours any more"
        else:
            argv = (["sudo", "-n", "mnexec", "-a", "1", "kill", "-TERM", str(pid)] if root
                    else ["kill", "-TERM", str(pid)])
            res = self.runner.run(argv, timeout=15)
            outcome = "stopped" if res.rc == 0 else "kill rc %s" % res.rc
        if outcome.startswith("kill rc"):
            # (r3, review MINOR 6) a kill that failed leaves the entry for recover.sh to retry
            self.events.append(("stop-%s" % key[:-1], pid, outcome))
            return outcome
        self.write_state(**{key: [e for e in self.state[key] if e["pid"] != pid]})
        self.events.append(("stop-%s" % key[:-1], pid, outcome))
        return outcome

    def _claim_lost(self, rec, before):
        ours, why = self.claim_ours()
        if ours:
            return False
        rec["problems"].append("the claim is no longer ours (%s): stopped before %s; finish with "
                               "recover.sh %s" % (why, before, self.cfg.run_dir))
        # After a successful down the phase stays "down-done": that is the fact recover.sh needs.
        if self.state["phase"] == "down-done":
            self.write_state(claim_lost=True)
        else:
            self.write_state(phase="claim-lost", claim_lost=True)
        return True

    def teardown(self, rec):
        self.write_state(phase="teardown")
        for entry in list(self.state["sniffers"]):
            self._stop("sniffers", entry, root=True)
        for entry in list(self.state["controllers"]):
            self._stop("controllers", entry, root=False)
        for iface in list(self.state["netem"]):
            if self._claim_lost(rec, "taking netem off %s" % iface):
                return
            self.runner.run(TC.netem_del_argv(iface), timeout=30)
            self.events.append(("netem-del", iface))
            self.write_state(netem=[i for i in self.state["netem"] if i != iface])
        if self.state.get("qdisc_before"):
            diff = self.runner.run([self.cfg.qdisc_snapshot, "diff", self.state["qdisc_before"]],
                                   timeout=60)
            rec["qdisc_same"] = diff.rc == 0
            if diff.rc != 0:
                # 12-10: recorded, and it does NOT block the down, the restore or the release.
                rec["problems"].append("qdisc state differs from the snapshot after up: %s"
                                       % diff.stdout.strip()[:200])
        if self._claim_lost(rec, "ndt down"):
            return
        down = self.ndt(["down"], timeout=900)
        rec["down_rc"] = down.rc
        if down.rc == 0:
            # (r3, review NEW-C) the fabric is gone: from here a crash leaves only the knobs and
            # the release, and recover.sh must not compare qdiscs against interfaces that no
            # longer exist.
            self.write_state(phase="down-done")
        if self._claim_lost(rec, "restoring the knobs"):
            return
        ok, why = self.restore_knobs()
        rec["knobs_restored"] = ok
        if not ok:
            rec["problems"].append("knob restore: %s" % why)
        if down.rc != 0:
            rec["problems"].append("ndt down exited %s: NOT releasing -- run recover.sh %s"
                                   % (down.rc, self.run_id))
            self.write_state(phase="down-failed")
            return
        if self._claim_lost(rec, "ndt release"):
            return
        rel = self.ndt(["release"], timeout=60)
        rec["release_rc"] = rel.rc
        if rel.rc != 0:
            rec["problems"].append("ndt release exited %s: THE LAB IS STILL CLAIMED" % rel.rc)
        self.write_state(phase="released")
