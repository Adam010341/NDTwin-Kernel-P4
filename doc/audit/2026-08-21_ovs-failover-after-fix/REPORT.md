# After the fix, OVS matches BMv2 — and the scaling penalty drops from 3.30× to 1.10×

[Co-developed with claude code -- Adam]

Run 2026-08-21 night at `45eccba`+. Raw ping logs `raw/`, protocol `after_fix_outage.sh`,
figures `plot_after_fix.py` → `page_ovs-before-after.png`, `page_ovs-vs-bmv2-after.png`
(both under the slide material's `figures/`).

Fix under evaluation: `NDTWIN_RYU_LLDP_GUARD=0.01` (announce-verified per cell). The O(1)
walk token (`4810e8f`) is committed code present in both after-cells; the backoff flag stayed
off so the "after" has one moving knob.

## Result (ping-gap outage, same instrument as every before-cell)

| cell | before | after (n=3) | prediction (from terms) |
|---|---:|---|---|
| OVS 128 hosts | 51.75 s (n=10) | **14.4 / 18.1 / 16.9 → 16.4 s** | ~15 s ✓ |
| OVS 4 hosts | 15.70 s | **14.6 / 13.3 / 17.1 → 15.0 s** | 13–14 s ✓ (barely moves) |
| BMv2/P4 128 | 16.59 s | — | (reference) |

* **128 hosts: 3.1× shorter, and statistically on top of P4's 16.59 s.**
* **4 hosts: essentially unchanged** (15.7 → 15.0). Predicted before running: the guard term
  is ports × 0.05 s, which at 36 ports was never the dominant cost. The asymmetry is the
  mechanism's fingerprint — a fix that "just made things faster" would have moved both sizes.
* **Scaling penalty 4 → 128 hosts: OVS before 3.30×, OVS after 1.10×, P4 1.21×.** The fixed
  OVS no longer pays for hosts it gained; the remaining ~1.1× is within these n.

## Caveats

* After-cells n=3 vs before n=10; different day, same machine and protocol.
* The 128-host after-cells ran at `settle=10`, under the known kernel-graph regression
  (256 host edges down — reported by the bring-up session). It does not touch this
  measurement (data plane + Ryu REST only), but the cells are not clean references for
  anything that reads the kernel's graph.
* Black-hole failures (`netem loss 100%`), not physical port-down — same caveat as every
  round with this protocol: a real port-down raises `OFPT_PORT_STATUS` and is immediate.
* Defaults unchanged. The guard's idle false-positive rate is zero
  (`../2026-08-21_lldp-guard-false-positives/REPORT.md`); the loaded case is open.
