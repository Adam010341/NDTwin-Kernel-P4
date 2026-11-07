# doc/

What is in this directory and who it is for. A file name starts with the date the file was
created, not the date it was last changed.

| File | What it is | For |
|---|---|---|
| [2026-11-05_user-guide.md](2026-11-05_user-guide.md) | Install, bring up, check, use and take down an emulated lab with `ndt`; troubleshooting | anyone running NDTwin; start here |
| [2026-01-02_ndt_api.md](2026-01-02_ndt_api.md) | Reference for the kernel's REST API on port 8000 and the P4 proxy's routes | application and tool writers |
| [2026-10-31_p4-app-guide.md](2026-10-31_p4-app-guide.md) | Run your own P4 program (an app package or a P4 tutorials exercise) in the lab | P4 developers |
| [KNOWN-ISSUES.md](KNOWN-ISSUES.md) | The defects that are open, cited by entry ID (for example `B-9`) | anyone who hits a defect |
| [FIXED-ISSUES.md](FIXED-ISSUES.md) | The codes of defects that are fixed, were not defects, or were decided against, with where each is fixed or guarded | anyone following an old citation |
| [2026-08-16_delivery-package/bmv2-manual-entry.md](2026-08-16_delivery-package/bmv2-manual-entry.md) | Building a fast bmv2 for realistic throughput, written as an installation-manual entry | anyone measuring on the P4 plane |
| [2026-01-02_OpenflowCapacity.json](2026-01-02_OpenflowCapacity.json) | OVS, Brocade ICX 7250 and HPE 5520 flow-table capacity figures; the kernel reads this file at run time | the kernel (do not move or rename it) |
| [2026-01-02_OpenflowFlowEntryExamplesMininet.md](2026-01-02_OpenflowFlowEntryExamplesMininet.md) | OVS flow-entry request examples; unverified against the current code | OpenFlow users, as a syntax reference |
| [2026-01-02_OpenflowFlowEntryOperationExamples.md](2026-01-02_OpenflowFlowEntryOperationExamples.md) | HPE switch flow-entry examples; unverified against the current code | OpenFlow users, as a syntax reference |
| [images/](images/) | Figures used by the documentation | readers of the docs |
| [debug-log/](debug-log/) | An empty place to paste log excerpts while debugging; its README says why it stays | developers |
| [audit/](audit/) | Scripts, fixtures and data files that tests and lab tools still use, kept here until they move to `tools/` and `tests/`; see [audit/README.md](audit/README.md) | test and tool maintainers |

Outside this directory: the [README](../README.md) (building the kernel), the
[CHANGELOG](../CHANGELOG.md), the Python client in [sdk/python/](../sdk/python/README.md) and the
examples in [examples/](../examples/).

[Co-developed with claude code -- Adam]
