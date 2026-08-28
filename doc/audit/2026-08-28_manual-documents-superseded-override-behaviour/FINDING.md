# A behaviour change here silently invalidated the public installation manual

**Date:** 2026-08-28
**Status:** manual corrected (NDTwin-Website `f00d69f`, branch `docs/p4-bmv2-environment`, unpushed)
**Severity:** delivery-blocking for the reader — following the published step produces a fabric that refuses to start

## The finding

Installation Manual **Step 6.6** told readers that if they had not built the performance
BMv2, they should **comment the override directive out**, and that

> "The first non-comment line wins, so commenting it out selects the stock
> `/usr/local/bin/simple_switch_grpc` from your `PATH`."

Both halves are false as of `d12641f`. `resolve_bmv2_launcher()` in
`p4_proxy/mininet/p4_testbed_topo.py` raises on **every** state the step recommended.

Established by calling the real function on a clean install, four file states, one run each
— not by reading the source:

| file state | result |
| :--- | :--- |
| as shipped (`/usr/local/bmv2-fast/…`, not built) | **REFUSES** — `bmv2 binary override names no executable` |
| commented out — *what 6.6 instructed* | **REFUSES** — `has no directive line (every line is blank or a #-comment)` |
| file deleted — *what 6.6 offered as equivalent* | **REFUSES** — `no bmv2 binary override at … there is no default to fall back to on purpose` |
| `/usr/local/bin/simple_switch_grpc` | **STARTS** |

## Why this is worth a record rather than just a docs fix

`d12641f` ("Promote the fast bmv2 to default, and refuse rather than fall back", 2026-08-22)
did the right thing in this repo: it changed the code, updated
`p4_proxy/tests/test_bmv2_binary_override.py`, and rewrote the header comment in
`p4_proxy/mininet/bmv2_binary_override`. Every consumer **inside this repository** was
updated together, and the test suite stayed green.

The installation manual is not in this repository. It is in `ndtwin-lab/NDTwin-Website`.
Nothing in this repo's CI can fail when a `p4_proxy/mininet/` behaviour change contradicts
it, so the manual described the superseded behaviour for six days and would have shipped
that way.

🔑 **The error message already contained the answer.** The raise says:

> "Commenting the line out **used to** re-select the stock build silently; **it now refuses**"

A message written in the form "X used to happen; now Y happens" is a standing marker that
some document may still describe X. That phrasing is worth treating as a prompt to grep the
docs, not just as a helpful error string.

## The asymmetry that produced it

`/usr/local/bmv2-fast/` **exists on our machines and does not exist on a reader's.** The
manual's author had the fast build, so the "you do not have it" branch was never walked.
The same asymmetry bit a second session the same day from the opposite direction — they
measured the stock binary on `PATH` while the running fabric used the fast one.

⇒ Any instruction whose correct branch depends on something only we have installed needs to
be executed on a machine that does not have it.

## Recurrence prevention

The manual now names the stock path explicitly, tabulates what each wrong action produces so
the error is recognisable, and ships a check that skips blank lines as well as comments —
the shipped override file has an empty line above the directive, so a naive
"first non-`#` line" check reports *nothing selected* on a perfectly good file.

**If `resolve_bmv2_launcher()` changes again, Step 6.6 of the installation manual has to
change with it.** That dependency is invisible from inside this repository.

## Method note

The first version of the harness checking this step asserted that the file had been
*modified*, which is true whether you comment the directive out or write a valid path. It
reported PASS while configuring a fabric that cannot start. It was replaced with a check
that asks `resolve_bmv2_launcher()` whether it accepts the result — the product, not the
action. Filtering blank lines alone would have fixed this instance and left the disease.

[Co-developed with claude code -- Adam]
