"""NDTwin's own observation surface, as the kernel answers it.

[Co-developed with claude code -- Adam]

`get_graph_data` (topology, link usage, `is_up`) and `get_detected_flow_data` (the flow table,
and the `non_ipv4_flows` side table, FlowLinkUsageCollector.cpp:1134-1161). Read through
`cfg.kernel`, the client object the Config carries. None = the kernel did not answer.
"""
from __future__ import annotations


def _get(cfg, path):
    reply = cfg.kernel.get(path)
    if reply.status != 200 or reply.body is None:
        return None
    return reply.body


def graph(cfg):
    return _get(cfg, "/ndt/get_graph_data")


def flows(cfg):
    return _get(cfg, "/ndt/get_detected_flow_data")


def side_rows(flow_doc):
    """The non-IPv4 side table's rows out of a get_detected_flow_data document; None when the
    document is unreadable or carries no such list -- unreadable is not "no rows"."""
    if isinstance(flow_doc, dict) and isinstance(flow_doc.get("non_ipv4_flows"), list):
        return list(flow_doc["non_ipv4_flows"])
    return None


def side_row_for(rows, ethertype, src_mac, dst_mac):
    """The side-table row for exactly this ethertype AND this MAC pair, or None.

    🔴 ALL THREE KEYS (design 2.3 CH7). Matching on the ethertype alone lets CH2's
    0x1234 row, or any host's ARP, answer for CH7; matching without the destination MAC lets a
    row from another pair answer for this one.
    """
    def norm(m):
        return str(m or "").lower()
    for row in rows or ():
        if not isinstance(row, dict):
            continue
        et = row.get("ethertype")
        try:
            et = int(et, 0) if isinstance(et, str) else int(et)
        except (TypeError, ValueError):
            continue
        if et == ethertype and norm(row.get("src_mac")) == norm(src_mac) \
                and norm(row.get("dst_mac")) == norm(dst_mac):
            return row
    return None
