"""Writing one flow entry through the kernel's OpenFlow-shaped flow routes
(doc/2026-01-02_ndt_api.md §9 and §42).

[Co-developed with claude code -- Adam]

The routes are `POST /ndt/install_flow_entry`, `/ndt/modify_flow_entry` and
`/ndt/delete_flow_entry`. The kernel answers 200 `queued` once the entry passed its own checks and
is on its dispatcher's queue: it may not have reached the controller yet. What the controller then
did with it is read from `GET /ndt/get_flow_dispatch_status?request_id=R`, which `OF.write` polls.

On OVS a normal return means the controller (Ryu) took the request, not that the switch holds the
rule: OpenFlow does not acknowledge a flow mod, so nothing on the kernel's API says the switch has
it, and `FlowWrite.on_switch` is None. The same routes reach a bmv2 switch through the P4 proxy;
on NDTwin's own pipeline the proxy programs the switch before it answers (`on_switch` True). On a
package's pipeline it writes only a destination route into a route table the package gives to
NDTwin, and refuses the rest (use `k.p4.write` there).
"""
import json
import math
import time
from dataclasses import dataclass
from typing import Optional

from .errors import NDTwinError, NotFound, OutcomeUnknown, Refused

ROUTES = {"install": "/ndt/install_flow_entry",
          "modify": "/ndt/modify_flow_entry",
          "delete": "/ndt/delete_flow_entry"}
DISPATCH_STATUS = "/ndt/get_flow_dispatch_status"

# The keys the kernel forwards to the controller (HttpRoutingStrategyBase.cpp, installAnEntry,
# modifyAnEntry, deleteAnEntry). Any other key would be dropped without a word.
_KEYS = {"install": {"dpid", "priority", "match", "actions", "idle_timeout"},
         "modify": {"dpid", "priority", "match", "actions"},
         "delete": {"dpid", "priority", "match"}}

# The match keys Ryu 4.34 reads (ryu/lib/ofctl_v1_3.py, `to_match`): it drops any other key with a
# log line only, which widens the rule.
MATCH_KEYS = frozenset((
    "in_port", "in_phy_port", "metadata", "dl_dst", "dl_src", "eth_dst", "eth_src", "dl_type",
    "eth_type", "dl_vlan", "vlan_vid", "vlan_pcp", "ip_dscp", "ip_ecn", "nw_proto", "ip_proto",
    "nw_src", "nw_dst", "ipv4_src", "ipv4_dst", "tp_src", "tp_dst", "tcp_src", "tcp_dst",
    "udp_src", "udp_dst", "sctp_src", "sctp_dst", "icmpv4_type", "icmpv4_code", "arp_op",
    "arp_spa", "arp_tpa", "arp_sha", "arp_tha", "ipv6_src", "ipv6_dst", "ipv6_flabel",
    "icmpv6_type", "icmpv6_code", "ipv6_nd_target", "ipv6_nd_sll", "ipv6_nd_tll", "mpls_label",
    "mpls_tc", "mpls_bos", "pbb_isid", "tunnel_id", "ipv6_exthdr"))

# Match keys that must be JSON integers. Ryu takes "0x0800" too, but on a modify or a delete the
# kernel reads eth_type, ip_proto and, when ip_proto is 6 or 17, tcp_src/tcp_dst or udp_src/udp_dst
# as integers when it updates its table view after the entry is queued
# (DeviceConfigurationAndPowerManager.cpp, updateOpenFlowTables), and a string there makes it answer
# an error for an entry that was already queued. The kernel does not read the other spellings
# (dl_type, nw_proto, tp_*) nor the SCTP ports; they are held to the same form so that a field is
# checked alike whichever name it is written with.
INT_MATCH_KEYS = frozenset(("eth_type", "dl_type", "ip_proto", "nw_proto", "tp_src", "tp_dst",
                            "tcp_src", "tcp_dst", "udp_src", "udp_dst", "sctp_src", "sctp_dst"))

# The action and instruction types Ryu 4.34 builds for OpenFlow 1.3 (ryu/lib/ofctl_utils.py
# `to_action`, ryu/lib/ofctl_v1_3.py `to_actions`): it drops any other type with a log line only,
# which turns a forwarding rule into a drop.
ACTION_TYPES = frozenset((
    "OUTPUT", "COPY_TTL_OUT", "COPY_TTL_IN", "DEC_MPLS_TTL", "POP_VLAN", "DEC_NW_TTL", "POP_PBB",
    "PUSH_VLAN", "PUSH_MPLS", "POP_MPLS", "PUSH_PBB", "SET_MPLS_TTL", "SET_QUEUE", "GROUP",
    "SET_NW_TTL", "SET_FIELD", "EXPERIMENTER", "WRITE_ACTIONS", "CLEAR_ACTIONS", "GOTO_TABLE",
    "WRITE_METADATA", "METER"))

_POLL_FIRST_S = 0.05     # the first wait between two reads of the dispatch record
_POLL_MAX_S = 0.5        # the longest one


class FlowEntry(dict):
    """A flow entry in the kernel's request shape: `dpid`, `priority` (optional), `match`
    (a dict, optional), `actions` (a list, install and modify) and `idle_timeout` (install)."""

    dpid = property(lambda self: self["dpid"])
    priority = property(lambda self: self.get("priority"))
    match = property(lambda self: self.get("match"))
    actions = property(lambda self: self.get("actions"))
    idle_timeout = property(lambda self: self.get("idle_timeout"))


@dataclass
class FlowWrite:
    """What `OF.write` found out.

    `request_id` and `accepted` are the kernel's 200 body's. `on_switch` is True when the dispatch
    record says every job of the request was accepted by the switch (a bmv2 switch through the P4
    proxy; after a delete it means the delete was applied), None otherwise: on OVS always, and
    when the call did not wait. `failures` is the
    record's failure list ([] when it says none), None when the call did not wait. `body` is the
    kernel's 200 body and `lab_claim` its `lab_claim` key (these routes send no header for it).
    """

    request_id: int
    accepted: int
    on_switch: Optional[bool]
    failures: Optional[list]
    body: dict
    lab_claim: Optional[dict]


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _check_entry(entry, op, all_rules=False):
    """Raise ValueError, before anything is sent, for an entry the kernel or the controller would
    take and then not do what it says. Returns the entry as a FlowEntry."""
    if op not in ROUTES:
        raise ValueError(f"op must be install, modify or delete, not {op!r}")
    if not isinstance(entry, dict):
        raise ValueError(f"an entry is a dict, not {type(entry).__name__}")
    entry = FlowEntry(entry)
    extra = sorted(set(entry) - _KEYS[op])
    if extra:
        why = ("the kernel forwards only " + ", ".join(sorted(_KEYS[op]))
               + f" on a {op}, so the rest would be dropped without a word")
        raise ValueError(f"{op}: {', '.join(map(str, extra))} not sent: {why}")
    match = entry.get("match")
    if match is not None and not isinstance(match, dict):
        raise ValueError(f"match must be a dict, not {type(match).__name__}")
    match = match or {}
    unknown = sorted(k for k in match if k not in MATCH_KEYS)
    if unknown:
        raise ValueError(f"match keys {unknown} are not match fields the controller knows; it "
                         f"would drop them and the rule would match more than you asked")
    for key in sorted(INT_MATCH_KEYS & set(match)):
        if not _is_int(match[key]):
            raise ValueError(f"match.{key} must be an integer, not {match[key]!r}: the kernel "
                             f"reads eth_type, ip_proto and the TCP and UDP ports as integers "
                             f"after the entry is queued, and the SDK holds every spelling of "
                             f"these fields to that form")
    proto = match.get("ip_proto", match.get("nw_proto"))
    if {"tp_src", "tp_dst"} & set(match) and proto not in (6, 17):
        raise ValueError("match.tp_src and tp_dst need ip_proto (or nw_proto) 6 or 17: the "
                         "controller cannot tell TCP from UDP without it")
    if op in ("install", "modify"):
        actions = entry.get("actions")
        if not isinstance(actions, list):
            raise ValueError(f"{op}: actions must be a list ([] for a drop rule), not {actions!r}")
        for action in actions:
            if not isinstance(action, dict) or action.get("type") not in ACTION_TYPES:
                raise ValueError(f"{op}: {action!r} is not an action the controller knows (a dict "
                                 f"whose type is one of {sorted(ACTION_TYPES)}); it would drop it")
    if op == "delete" and not match and not all_rules:
        raise ValueError("a delete without a match removes every rule in the switch's table 0, "
                         "the kernel's own included (LLDP, table-miss, routes), or with a "
                         "priority the match-all rule at that priority (the table-miss rule at "
                         "0); pass all_rules=True if that is what you mean")
    return entry


def _lab_claim_of(body):
    return body.get("lab_claim") if isinstance(body, dict) else None


def _again(cls, err, message, nothing_written):
    """`err` (an NDTwinError of the POST) as `cls`, with its fields and the body's lab_claim."""
    new = cls(f"{message}: {err}", method=err.method, path=err.path, status=err.status,
              origin=err.origin, body=err.body, nothing_written=nothing_written)
    new.lab_claim = _lab_claim_of(err.body)
    return new


def _post_error(err):
    """The exception for a POST the kernel did not answer with a 2xx, as the SDK raises it."""
    if err.status is None:
        return err      # KernelUnreachable, or the connection broke after the request went out
    body = err.body if isinstance(err.body, dict) else {}
    if err.status == 400 and body.get("error") == "JSON parsing error":
        # The kernel's router answers this for an exception thrown anywhere in the handler,
        # also after the entry was queued (when it updates its table view).
        return _again(OutcomeUnknown, err, "the kernel failed while handling the entry, maybe "
                      "after queueing it", None)
    if err.status == 501:
        return _again(Refused, err, "refused before queueing: "
                      + str(body.get("refused_on_p4_reason") or body.get("error")), True)
    if err.status >= 500:
        return _again(OutcomeUnknown, err, "the kernel failed while handling the entry, maybe "
                      "after queueing it", None)
    if 400 <= err.status < 500:
        err.lab_claim = _lab_claim_of(err.body)
        return err      # Refused or NotFound: nothing was queued
    return _again(OutcomeUnknown, err, "an answer the SDK cannot read", None)


def _classify(rec):
    """(class, nothing_written, why) for one failure record of the dispatch status."""
    status, by = rec.get("controller_status"), rec.get("refused_by")
    if not _is_int(status):
        return OutcomeUnknown, None, "a failure record without a status the SDK can read"
    if status == 0:
        return OutcomeUnknown, None, "the controller did not answer in time; it may still apply it"
    if by == "switch":
        # The kernel books every 502 of the P4 proxy as the switch's (HttpRoutingStrategyBase.cpp,
        # refuserOf), and the proxy answers 502 on its flow routes for any write that failed, its
        # own gRPC errors included; the record keeps no p4rt_error that would say the switch
        # itself refused. So, as for the proxy's 502 without p4rt_error on /ndt/p4 (errors.py),
        # the write may have landed.
        return OutcomeUnknown, None, ("the P4 proxy reported the write as failed, which does not "
                                      "say whether the switch has it")
    if by == "controller":
        if status == 404:
            return NotFound, True, ("the controller answered 404: usually the switch is not "
                                    "connected to the controller (off or disconnected); Ryu "
                                    "also answers 404 for a command, port or URL it does not "
                                    "know")
        if 400 <= status < 500 or status == 501:
            return Refused, True, "the controller refused it"
        return OutcomeUnknown, None, "the controller failed while handling it"
    if by == "proxy":
        if status == 404:
            return NotFound, True, "the P4 proxy does not know the switch"
        if 400 <= status < 500 or status == 501:
            return Refused, True, "the P4 proxy refused it"
        return OutcomeUnknown, None, "the P4 proxy failed while handling it"
    if status == 500:
        return NDTwinError, True, "the kernel could not send it"
    if status == 404:
        return NotFound, True, "the kernel no longer knows the switch"
    if 400 <= status < 500:
        return Refused, True, "the kernel refused it"
    return OutcomeUnknown, None, "an outcome the SDK cannot read"


class OF:
    """`kernel.of`: the kernel's OpenFlow-shaped flow routes. They reach OVS switches through Ryu
    and bmv2 switches on NDTwin's own pipeline through the P4 proxy."""

    def __init__(self, http):
        self._http = http

    def write(self, entry, op="install", *, wait_s=10.0, all_rules=False):
        """Send one entry with `op` "install", "modify" or "delete", then wait up to `wait_s`
        seconds for the kernel's dispatch record of it, and return a `FlowWrite`.

        A normal return on OVS means the controller took the request; the switch may still refuse
        it, and nothing on the kernel's API says so (`on_switch` is None). The kernel's table view
        (`GET /ndt/get_switch_openflow_table_entries`) is not a read-back: it shows an install only
        after its next poll of the switch, and it can show a modify or a delete at once, before
        the switch has it and even when the controller then refuses it. `wait_s` bounds the
        polling of the record, not one read of it, which can take the client's `timeout` (and its
        retries). `wait_s=0` returns once the kernel queued the entry, without reading the record
        (`on_switch` and `failures` None).

        ValueError, before anything is sent, for an entry that would not do what it says (see
        "OVS flow entries" in sdk/python/README.md); a delete without a match removes every rule
        in table 0 (with a priority, the match-all rule at it) and needs `all_rules=True`.
        Otherwise raises an NDTwinError: Refused or NotFound (nothing written) when the kernel,
        the controller or the P4 proxy refused it; OutcomeUnknown (it may have landed or still
        land) when the outcome is not known, also when the P4 proxy reported the write as failed
        and when the record is not complete within `wait_s`. An error of the wait carries
        `request_id`, `failures` and `remedy`. The entry is sent once.
        """
        entry = _check_entry(entry, op, all_rules)
        if not (isinstance(wait_s, (int, float)) and math.isfinite(wait_s) and wait_s >= 0):
            raise ValueError(f"wait_s must be finite and 0 or more, not {wait_s!r}")
        path = ROUTES[op]
        try:
            reply = self._http.call("POST", path, body=dict(entry))
        except NDTwinError as err:
            raise _post_error(err) from None
        body = reply.body
        if not (isinstance(body, dict) and body.get("status") == "queued"
                and _is_int(body.get("request_id")) and body["request_id"] > 0):
            err = OutcomeUnknown(f"POST {path}: a 2xx the SDK cannot read: "
                                 f"{json.dumps(body)[:300]}", method="POST", path=path,
                                 status=200, body=body)
            err.lab_claim = _lab_claim_of(body)
            raise err
        result = FlowWrite(request_id=body["request_id"], accepted=body.get("accepted"),
                           on_switch=None, failures=None, body=body,
                           lab_claim=body.get("lab_claim"))
        if wait_s == 0:
            return result
        record = self._wait(result, path, wait_s)
        result.failures = list(record.get("failures") or [])
        enqueued = record.get("enqueued")
        accepted = (record.get("switch_outcome") or {}).get("accepted_by_switch")
        if _is_int(enqueued) and enqueued > 0 and accepted == enqueued:
            result.on_switch = True
        return result

    def dispatch_status(self, request_id):
        """GET /ndt/get_flow_dispatch_status?request_id= (§42): the kernel's record of one write,
        as it gives it. NotFound when the kernel has no record of that id (never issued, aged
        out, or issued before the kernel restarted)."""
        if not _is_int(request_id) or request_id < 1:
            raise ValueError(f"request_id must be a positive integer, not {request_id!r}")
        return self._http.call("GET", DISPATCH_STATUS, {"request_id": request_id}).body

    def _wait(self, result, path, wait_s):
        """The complete dispatch record of `result`'s request, or raise for its failures."""
        rid = result.request_id
        deadline = time.monotonic() + wait_s
        pause = _POLL_FIRST_S

        def unknown(why, cause=None, record=None):
            err = OutcomeUnknown(f"POST {path}: queued as request {rid}, then {why}", method="POST",
                                 path=path, status=200, body=result.body)
            err.lab_claim, err.request_id = result.lab_claim, rid
            if record is not None:
                err.failures = list(record.get("failures") or [])
            return err

        while True:
            try:
                record = self.dispatch_status(rid)
            except NDTwinError as err:
                raise unknown(f"its dispatch record could not be read: {err}") from err
            if not isinstance(record, dict):
                raise unknown(f"its dispatch record is not readable: {json.dumps(record)[:200]}")
            if record.get("complete") is True:
                break
            if record.get("dispatcher_running") is False:
                raise unknown("the kernel's dispatcher stopped before every job was sent",
                              record=record)
            left = deadline - time.monotonic()
            if left <= 0:
                raise unknown(f"its dispatch record was not complete within {wait_s} s",
                              record=record)
            time.sleep(min(pause, left))
            pause = min(pause * 2, _POLL_MAX_S)
        failures = list(record.get("failures") or [])
        failed = (record.get("counters") or {}).get("dispatch_failed", len(failures))
        if not failures and not failed:
            return record
        verdicts = [_classify(f) for f in failures]
        if failed > len(failures) or any(nw is not True for _, nw, _ in verdicts):
            cls, nothing_written = OutcomeUnknown, None
        else:
            cls = verdicts[0][0]
            nothing_written = True if failed >= record.get("enqueued", 0) else None
        whys = "; ".join(f"s{f.get('dpid')}: {why} (HTTP {f.get('controller_status')}"
                         + (f", {f['message']}" if f.get("message") else "") + ")"
                         for f, (_, _, why) in zip(failures, verdicts))
        if failed > len(failures):
            whys = (whys + "; " if whys else "") + (f"{failed - len(failures)} failure(s) the "
                                                    f"kernel no longer keeps")
        err = cls(f"POST {path}: request {rid}: {whys}", method="POST", path=path, status=200,
                  body=result.body, nothing_written=nothing_written)
        err.lab_claim, err.request_id, err.failures = result.lab_claim, rid, failures
        err.remedy = next((f["remedy"] for f in failures if f.get("remedy")), None)
        raise err
