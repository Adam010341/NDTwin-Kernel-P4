"""Cutting a link through the kernel and putting it back (doc/2026-01-02_ndt_api.md §2b, §2c).

[Co-developed with claude code -- Adam]

`POST /ndt/inject_link_failure` declares both directions of a link down in the twin and, on a
Mininet deployment, attaches `netem loss 100%` to the interfaces at both ends, or to neither.
`POST /ndt/inject_link_recovery` withdraws the declaration and removes the netem this kernel
process attached. The netem lives in the machine's qdisc tree and the declaration in the kernel
process, so neither ends by itself when the app that made them stops: `Kernel.link_down` sends the
recovery when its `with` block ends, and `Kernel.restore_link` sends it on its own.

Each POST is sent once. A repeated injection answers that nothing was attached while the first
one's netem still cuts the wire, and a repeated recovery that lands after another client injected
the same link withdraws that injection: the kernel keeps no owner of an injection.
"""
import json
from dataclasses import dataclass
from typing import Optional

from .errors import KernelUnreachable, LinkNotRestored, NDTwinError, OutcomeUnknown

INJECT = "/ndt/inject_link_failure"
RECOVER = "/ndt/inject_link_recovery"
SKIPPED = "skipped (not MININET)"
# The kernel's 500s that say it changed nothing (HttpSession.cpp, handleInjectLinkFailure and
# handleInjectLinkRecovery): its topology holds one direction of the link and not the other.
_NOTHING_CHANGED = {
    INJECT: "reverse edge missing from the topology; nothing was injected",
    RECOVER: "reverse edge missing from the topology; nothing was withdrawn",
}


@dataclass
class LinkRestore:
    """What a recovery answered.

    `removed` holds the interfaces a netem was taken off; `still_cut` those the kernel could not
    clear: a netem it did not attach was left standing there, a delete failed, or it could not
    read their qdisc tree (then nothing is known), so a netem may still be on them; None stands for
    an end whose interface the kernel cannot name (no bridge name in its topology file). `tc` is
    the kernel's per-interface detail as it gives it, or "skipped (not MININET)". `body` is the
    kernel's 200 body and `lab_claim` its `lab_claim` key.
    """

    ends: tuple
    removed: tuple
    still_cut: tuple
    tc: object
    status: str
    body: dict
    lab_claim: Optional[dict]


@dataclass
class LinkCut:
    """What the injection did, as `Kernel.link_down` yields it.

    `on_wire` is True when every end carries the netem this injection attached, False when this
    injection attached none (the deployment is not Mininet, or the kernel refused the cut), and
    None when only some ends carry it. False does not say that packets cross the link: a netem
    that was already on an interface (an injection that outlived a kernel restart, another
    client's, a fault tool's) may drop them, and when the kernel could not read a qdisc tree
    nothing is known about it. `interfaces` holds the interfaces that carry this injection's
    netem. `why`, when `on_wire` is not True, is the kernel's reason quoted where the kernel gave
    one (it names a netem that was already there), and the SDK's own sentence when the kernel
    skipped tc (not a Mininet deployment). `tc`, `status`, `body` and `lab_claim` are the
    reply's. After the block, `restored` holds the recovery's `LinkRestore`, or `restore_error`
    the `LinkNotRestored` it raised.
    """

    ends: tuple
    on_wire: Optional[bool]
    interfaces: tuple
    why: Optional[str]
    tc: object
    status: str
    body: dict
    lab_claim: Optional[dict]
    restored: Optional[LinkRestore] = None
    restore_error: Optional[NDTwinError] = None


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def ends_of(link):
    """((dpid, port), (dpid, port)) from a topology `Link` or from the two ends; ValueError for
    anything else."""
    if all(hasattr(link, a) for a in ("src", "src_port", "dst", "dst_port")):
        ends = ((link.src, link.src_port), (link.dst, link.dst_port))
    else:
        try:
            (a, ap), (b, bp) = link
        except (TypeError, ValueError):
            raise ValueError(f"a link is a topology Link or ((dpid, port), (dpid, port)), not "
                             f"{link!r}") from None
        ends = ((a, ap), (b, bp))
    for dpid, port in ends:
        if not (_is_int(dpid) and _is_int(port) and dpid >= 0 and port >= 0):
            raise ValueError(f"a dpid and a port are integers 0 or more, not {dpid!r}, {port!r}")
    return ends


def name(ends):
    (a, ap), (b, bp) = ends
    return f"s{a}:{ap}-s{b}:{bp}"


def names(ifaces):
    """Interface names for a message: an end the kernel gave no name is said to be one, and any
    other value is written as text. [Co-developed with claude code -- Adam]"""
    out = [str(i) for i in ifaces if i is not None]
    if any(i is None for i in ifaces):
        out.append("an end the kernel did not name")
    return ", ".join(out)


def restore_call(ends):
    return f"k.restore_link({ends!r})"


def _body(ends):
    (a, ap), (b, bp) = ends
    return {"src_dpid": a, "src_interface": ap, "dst_dpid": b, "dst_interface": bp}


def _lab_claim_of(body):
    return body.get("lab_claim") if isinstance(body, dict) else None


def _tc_of(body):
    """The reply's `tc` as a list of per-interface reports, SKIPPED, or None when it is neither.
    A report names its interface, except one that says `ok` false (the kernel's for a switch the
    topology file gives no bridge name)."""
    tc = body.get("tc")
    if tc == SKIPPED:
        return SKIPPED
    if (isinstance(tc, list) and tc
            and all(isinstance(e, dict) and isinstance(e.get("ok"), bool)
                    and (isinstance(e.get("interface"), str) or e.get("interface") is None
                         and e["ok"] is False)
                    for e in tc)):
        return tc
    return None


def _post(http, path, ends):
    """The POST, sent once; returns its 200 body, or raises the NDTwinError of its failure with
    `nothing_written` True only when the kernel says it changed nothing (or nothing was sent)."""
    try:
        return http.call("POST", path, body=_body(ends)).body
    except NDTwinError as err:
        raise _post_error(err, path, ends) from None


def _post_error(err, path, ends):
    if isinstance(err, KernelUnreachable):
        return err      # nothing was sent; the transport already tried again
    body = err.body if isinstance(err.body, dict) else {}
    err.lab_claim = err.lab_claim or _lab_claim_of(err.body)
    status = err.status
    if status is not None and 400 <= status < 500 and body.get("error") != "JSON parsing error":
        return err      # Refused or NotFound: refused before anything was changed
    if status == 500 and body.get("error") == _NOTHING_CHANGED[path]:
        new = NDTwinError(f"the kernel changed nothing: {err}", method="POST", path=path,
                          status=status, origin=err.origin, body=err.body, nothing_written=True)
        new.lab_claim = err.lab_claim
        return new
    # A 5xx, a 400 "JSON parsing error" (the kernel's router answers it for an error thrown after
    # the change too), a 2xx that is not JSON, a connection that broke after the request went out.
    remedy = restore_call(ends)
    new = OutcomeUnknown(f"the kernel may have acted on it, so {name(ends)} may be cut now; "
                         f"restore it with {remedy}: {err}", method="POST", path=path,
                         status=status, origin=err.origin, body=err.body)
    new.lab_claim, new.remedy = err.lab_claim, remedy
    return new


def _carries(end):
    """Whether this end of an injection reply may carry the netem the injection attached: it says
    `ok`, or the kernel attached it and then could not take it off again (`rolled_back` not ok)."""
    if end["ok"]:
        return True
    back = end.get("rolled_back")
    return back is not None and not (isinstance(back, dict) and back.get("ok") is True)


def inject(http, ends):
    """POST /ndt/inject_link_failure once and read its 200 into a `LinkCut`. Raises Refused or
    NotFound (nothing changed), NDTwinError (nothing changed: the kernel's topology is
    inconsistent), KernelUnreachable, or OutcomeUnknown (the link may be cut) whose `remedy`
    names the restore."""
    body = _post(http, INJECT, ends)
    tc = _tc_of(body) if isinstance(body, dict) else None
    status = body.get("status") if isinstance(body, dict) else None
    carrying = None if tc is None else (
        () if tc == SKIPPED else tuple(e.get("interface") for e in tc if _carries(e)))
    if not isinstance(status, str) or carrying is None:
        remedy = restore_call(ends)
        err = OutcomeUnknown(f"POST {INJECT}: a 2xx the SDK cannot read: "
                             f"{json.dumps(body)[:300]} -- {name(ends)} may be cut now; restore "
                             f"it with {remedy}", method="POST", path=INJECT, status=200,
                             body=body)
        err.lab_claim, err.remedy = _lab_claim_of(body), remedy
        raise err
    n = 0 if tc == SKIPPED else len(tc)
    on_wire = (False if not carrying else True if len(carrying) == n else None)
    why = None
    if on_wire is not True:
        why = (body.get("wire") if isinstance(body.get("wire"), str)
               else "tc skipped (not MININET): this injection attached no netem"
               if tc == SKIPPED else status)
    return LinkCut(ends=ends, on_wire=on_wire, interfaces=carrying, why=why, tc=tc, status=status,
                   body=body, lab_claim=_lab_claim_of(body))


def _not_restored(ends, why, remedy, *, status=None, body=None, tc=None, still_cut=None,
                  restore=None, nothing_written=None, lab_claim=None, cause=None):
    err = LinkNotRestored(f"POST {RECOVER}: {name(ends)} may still be cut: {why}. To clear it: "
                          f"{remedy}", method="POST", path=RECOVER, status=status,
                          origin=None if cause is None else cause.origin, body=body,
                          nothing_written=nothing_written)
    err.ends, err.tc, err.still_cut, err.restore = ends, tc, still_cut, restore
    err.remedy, err.lab_claim = remedy, lab_claim
    return err


def _by_hand(ifaces):
    """What clears a netem this kernel process did not attach: nothing the SDK can send."""
    where = names(ifaces) if ifaces else "the link's interfaces"
    return (f"the netem on {where} was not attached by this kernel process, so the kernel refuses "
            f"to remove it and a recovery is refused again; remove it by hand on the kernel's "
            f"machine once you know whose it is (`tc qdisc show dev <interface>` shows where it "
            f"hangs: `sudo tc qdisc del dev <interface> root`, or `parent <id>`)")


def _remedy(ends, entries, problems):
    """What clears `problems`, from the kernel's per-interface reports: its own sentence for a
    netem it refused to remove, the restore call again for the rest (a delete that failed, a tree
    it could not read, an interface it did not report)."""
    refused = {e.get("interface"): e["refused"] for e in entries
               if not e["ok"] and isinstance(e.get("refused"), str)}
    parts = [f"{names([i])}: {refused[i]}" for i in problems if i in refused]
    if any(i not in refused for i in problems):
        parts.insert(0, f"{restore_call(ends)} again once the kernel can run tc there")
    return "; ".join(parts)


def recover(http, ends, attached=None):
    """POST /ndt/inject_link_recovery once; returns a `LinkRestore` or raises LinkNotRestored.

    With `attached` (the interfaces an injection of this link put netem on), the recovery must
    report each of them cleared; an interface it could not clear that the injection did not
    attach is reported in `still_cut` and not raised. Without it, any interface not cleared
    raises."""
    try:
        body = _post(http, RECOVER, ends)
    except NDTwinError as err:
        still = tuple(attached) if attached else None
        remedy = restore_call(ends)
        if err.status == 409:
            theirs = err.body.get("netem_not_ours") if isinstance(err.body, dict) else None
            if isinstance(theirs, list):
                still = tuple(str(i) for i in theirs)
            remedy = _by_hand(still)
        raise _not_restored(ends, f"the recovery failed: {err}", remedy, status=err.status,
                            body=err.body, still_cut=still, nothing_written=err.nothing_written,
                            lab_claim=err.lab_claim, cause=err) from err
    tc = _tc_of(body) if isinstance(body, dict) else None
    status = body.get("status") if isinstance(body, dict) else None
    if not isinstance(status, str) or tc is None:
        raise _not_restored(ends, f"a 2xx the SDK cannot read: {json.dumps(body)[:300]}",
                            restore_call(ends), status=200, body=body,
                            still_cut=tuple(attached) if attached else None,
                            lab_claim=_lab_claim_of(body))
    entries = [] if tc == SKIPPED else tc
    cleared = {e.get("interface") for e in entries if e["ok"]}
    still_cut = tuple(e.get("interface") for e in entries if not e["ok"])
    removed = tuple(e.get("interface") for e in entries if e["ok"] and "noop" not in e)
    done = LinkRestore(ends=ends, removed=removed, still_cut=still_cut, tc=tc, status=status,
                       body=body, lab_claim=_lab_claim_of(body))
    if attached is None:
        problems = still_cut
    else:
        problems = tuple(i for i in attached if i not in cleared)
    if problems:
        whys = "; ".join(f"{names([e.get('interface')])}: {e['error']}" for e in entries
                         if not e["ok"] and e.get("interface") in problems
                         and isinstance(e.get("error"), str))
        raise _not_restored(ends, f"the kernel answered {status!r} and did not clear "
                            f"{names(problems)}" + (f" ({whys})" if whys else ""),
                            _remedy(ends, entries, problems), status=200, body=body, tc=tc,
                            still_cut=problems, restore=done, lab_claim=done.lab_claim)
    return done
