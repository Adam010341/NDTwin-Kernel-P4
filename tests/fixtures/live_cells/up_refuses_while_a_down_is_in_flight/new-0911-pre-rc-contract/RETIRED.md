# RETIRED as the cell's `new/` fixture -- 2026-09-12, FIX-NDT-8

[Co-developed with claude code -- Adam]

This directory is the raw of **the first fixed run**, captured live on 2026-09-11 13:32 (see
`PROVENANCE.md` beside this file, which is unchanged). It was this cell's `new/` fixture until
today.

**What changed.** Since 2026-09-12 `ndt up`, `ndt down` and `ndt clean` share one rc
vocabulary: a bring-up REFUSED by a guard now exits **5**, and 1 is kept for a bring-up that
measured something dirty. The cell's rc assertion was renamed `h3_up_rc_is_1` -> `h3_up_rc_is_5`
and now expects 5, which is the first value that tells this refusal from the pre-fix run -- the
09-11 header of the cell records that the pre-fix `ndt up` **also** exited 1, from `a Mininet is
already running` on the OVS arm, so the old assertion passed on `old/` and `new/` alike.

`up.rc` in here reads `1`. That is what the tool returned on 09-11 and it is not edited: it is
captured evidence, and the one thing this project does not do to captured evidence is make it
agree with a later contract. The directory is renamed instead, so
`tests/shell/mutate_live_cells.sh` no longer treats it as the cell's `new/` fixture, and until a
live round under the 09-12 contract was captured it reported the cell as **PENDING** ("no new/ yet").

**What was still needed on 2026-09-12:** one live `run_cells.sh --cell up_refuses_while_a_down_is_in_flight`
round on a tree carrying the FIX-NDT-8 rc vocabulary, with its raw copied in as `new/`. That
round needs the lab, so it was not part of this change; it has since been captured as `../new/`.
