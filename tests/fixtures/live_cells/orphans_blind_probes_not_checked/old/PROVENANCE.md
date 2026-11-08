# old/ -- orphans_blind_probes_not_checked

[Co-developed with claude code -- Adam]

**Kind: replay of the pre-fix tool.** Not a captured log -- the offline investigation of 2026-09-11 measured this (§1.11 of its
write-up) with an orphans report it had built from `ndt`'s own two print sites, and that same report is what the cell's
`observe` writes today, so the input is identical on both sides and only the tool differs.

| file | where it came from |
|---|---|
| `orphans.txt` | the cell's own `observe` (byte-identical to the `all_blind` fixture of `tests/shell/test_orphans_verdict.sh`, built from `ndt:5442` and `ndt:5561-5562`) |
| `orphans.rc` | `5` -- what `ndt apps orphans` returns for this report (`residue_verdict`, `ndt:5349`) |
| `verdict.txt`, `verdict.rc` | `bash <ded00d06^ orphans_verdict.sh> - 5 < orphans.txt`, run 2026-09-11 13:0x. Agrees line for line with the output quoted in §1.11 of that investigation's write-up (kept outside this repository) |
| `ids.txt` | the blob shas of `tools/test_workflow/{ndt,orphans_verdict.sh}` at `ded00d06^` |

**The finding is carried by all three failing assertions.** `f5_verdict_rc_is_3` (0 against 3),
`f5_says_not_checked` and `f5_does_not_say_clean` are content readings of a file this fixture has.
There is no fixture gap here.
