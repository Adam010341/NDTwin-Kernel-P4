# old/ -- help_drops_deleted_claims

[Co-developed with claude code -- Adam]

**Kind: replay of the pre-fix tool.** `ndt help` reads no state, so replaying it at `3259d296^`
reproduces exactly the text F-OFFLINE-1 §1.12/§1.24 read.

| file | where it came from |
|---|---|
| `help.txt`, `help.rc` | `bash <3259d296^ ndt> help`, run 2026-09-11 13:0x in a temp tree carrying that rev's `ndt`, `ports.sh`, `sudo_surface.sh` and `components.env`. Line 62-64 is the B10 sentence; the F12 sentence is the `has run in THIS checkout. 3 is never` one |
| `ids.txt` | the blob sha of `tools/test_workflow/ndt` at `3259d296^` |

Checked before replaying: that rev's usage heredoc is the only unquoted one in the file and
contains **no** backtick and no `$(` (the 09-10 near-miss where an `ndt help` heredoc executed
`ndt down` was introduced later in FIX-NDT-2 and fixed in `3f393bf2`). Running it was therefore
safe; a rev whose heredoc does carry one must not be replayed.

**All four failing assertions carry the finding** -- two are the deleted sentences, two are the
replacements, and the fixture has the file all four read.
