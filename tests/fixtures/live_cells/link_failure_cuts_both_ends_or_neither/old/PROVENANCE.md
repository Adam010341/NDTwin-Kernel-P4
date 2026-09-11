# old/ -- link_failure_cuts_both_ends_or_neither

[Co-developed with claude code -- Adam]

**Kind: captured log.** ROLE-1, live on an OVS 4-host fabric, 2026-09-11 00:57:27, main checkout;
2 reproductions of 2.

| file | where it came from |
|---|---|
| `failure.body` | the verbatim response line under `=== RESPONSE (verbatim, then pretty) ===` in `hunt-0911/logs/ROLE-1/06-inject-failure.log` |
| `failure.code` | `200` -- that log's `http_code=200` |
| `tc_before.txt` | s1-eth1 with the hand-attached `netem loss 100%` (`04-tc-netem-on.log`) |
| `tc_before_far.txt` | s5-eth1 before the POST -- `qdisc noqueue`, the far end nobody had touched (`04-tc-netem-on.log`) |
| `tc_after.txt`, `tc_after_far.txt` | the `=== tc AFTER inject_link_failure ===` section of the same log: `netem 801d` on s1-eth1 (refused, so still the foreign one) and **`netem 801e` on s5-eth1**, which is the end that really was cut |
| `netem_final.txt` | `0`. ROLE-1 cleared both ends later in its round; the value is carried so the cleanliness assertion has a file to read, and it passes here and is not evidence |
| `ids.txt` | kernel `unknown`, for the reason given in the sibling cell's PROVENANCE |

**Five assertions carry the finding:** `a1f_far_end_was_not_cut` (the wire -- `netem 801e`),
`a1f_does_not_claim_injected` (the status line), `a1f_says_nothing_was_attached`,
`a1f_names_the_half_that_happened`, `a1f_declaration_still_stands`. No fixture gap.

Note the last one: the ruling is that the DECLARATION stands and the reply says which half
happened -- not that the whole request is refused. A judge asserting the absence of a declaration
would be pinning a contract nobody agreed to.
