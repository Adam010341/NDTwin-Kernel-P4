# old/ -- default_round_plane_is_classified

[Co-developed with claude code -- Adam]

**Kind: replay of the pre-fix tool.** The cell's only input is a stubbed `kernel_exit_field`, so
the pre-fix reading is reproduced exactly by sourcing `ca9af4f1^`'s `ndt` through its
`NDT_LIB_ONLY` seam.

| file | where it came from |
|---|---|
| `planes.txt` | the cell's own `observe` with `NDT_ROOT` pointed at a temp tree carrying `ca9af4f1^`'s `ndt`. Reads `mininet128: out=<empty> rc=1` there, which is F-OFFLINE-1 §1.15's measurement, and `ovs4: out=ovs rc=0` -- that report's own positive control |
| `ids.txt` | the blob sha of `tools/test_workflow/ndt` at `ca9af4f1^` |

**One failing assertion, and it is the finding**: `f10_mininet_model_reads_as_ovs`. The other
three pass on this fixture on purpose -- they are the controls that make "classify everything as
ovs" a failing answer rather than a passing one, and a fixture on which they failed too would not
be able to show that.
