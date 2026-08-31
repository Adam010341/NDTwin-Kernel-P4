# T-15 — the kernel API and P4 flow-entry diversity (design ticket, **no implementation**)

[Co-developed with claude code -- Adam]

Written by 8/29 mainDev during the `tr5-energy` window (22:24–00:24): **written, not built, not
run, not committed until the window opens.** Prerequisite A-7 is complete (`2016d4c`, `636f9ab`,
`30eb6d7`); T-11-A landed on top (`91e7743`).

This ticket asks for a **decision**, not code. Four options, in ascending order of cost. They are
not exclusive — 0 is a floor the others sit on.

---

## The problem, stated without overclaiming

`/ndt/install_flow_entry` accepts a match/actions JSON shaped around OpenFlow and forwards it to
whichever data plane is loaded. On the OVS arm that maps onto Ryu's `/stats/flowentry/add` fairly
directly. On the P4 arm it maps onto a **specific compiled pipeline** with a fixed set of tables,
each with fixed key fields and a fixed match kind. The API's vocabulary is wider than that
pipeline's, and nothing in the request path tells the caller where the edge is.

Two measured facts anchor this, both from 2026-08-30:

* **FINDING-07** — every rule is programmed at **priority 0** whatever the caller asked for. The
  `priority` field is accepted, echoed during the pending window, and discarded. *Where* it is
  dropped is not identified: kernel encoder, P4 proxy, or the bmv2 table write. Three candidate
  layers, none read.
* **B-1 / the 08-19 grid** — a `tcp_dst` match without `ip_proto` is refused by the P4 proxy with a
  named field (`400`), and refused **with** `ip_proto` too, because `ipv4_lpm` does not take it
  either. So the proxy already knows some of the boundary and can articulate it.

## 🔴 The `.p4` has now been read, and it refutes the premise this ticket was being built on

Approved and pulled forward (auditor §16) because it is a pure source read. `p4_proxy/p4_src/ndtwin_switch.p4`:

| table | match kind | key | size |
|---|---|---|---|
| `flow_5tuple` | **ternary** | in_port, src, dst, proto, l4_src, l4_dst | 1024 |
| `ipv4_lpm` | **lpm** | `hdr.ipv4.dstAddr` | 1024 |
| `l2_forward` | **exact** | `hdr.ethernet.dstAddr` | 512 |

**The forwarding path has no exact-match table in it** — `l2_forward` keys on MAC, not on the
fields these rules use. So the framing relayed as T-15 input (a), *"the API accepts a priority that
an exact-match table structurally cannot implement"*, **is not what is happening.** There is a
ternary table with genuine priority, sitting deliberately in front of the LPM one.

The `.p4`'s own header comment says why it was added, and it is this exact problem, already
diagnosed once:

> LPM tables have no priority concept: precedence is prefix length, so two rules the kernel
> believed were ordered were not.

⇒ **The likely mechanism behind FINDING-07 is not "a layer drops the priority". It is that a
dst-only match routes to `ipv4_lpm`, where priority is not a field that exists.** Every rule
FINDING-07 posted matched on `ipv4_dst` alone, and every one it read back carried
`{dl_type, nw_dst}` — the LPM table's shape. An LPM entry reporting `priority: 0` is **not a
dropped value; it is a table that has no such column.**

That changes what the defect is. Not "the kernel corrupts your priority" but: **the API accepts a
`priority` for a match shape it will route to a table where priority is meaningless, does not say
so, and a ternary table that *would* honour it is sitting right there, reachable only by sending a
richer match.** That is a capabilities problem in the strict sense — and a much better argument for
Option 1 than the one it replaces.

### ✅ Resolved — the auditor read the proxy, and it lands on the light side

`p4_proxy/.../api_routes.py:201-214`, `add_flow_entry`'s own docstring:

> `priority` is now READ … It is still **ignored for the destination-only path**, which is every
> rule the kernel itself writes

and the selection rule: **dst-only → `ipv4_lpm`; a match naming more than a destination compiles
to the ternary `flow_5tuple`**, where priority is meaningful *and mandatory*.

⇒ FINDING-07's seventeen rules were all destination-only, so they went to the LPM table by design.
**No packet was forwarded wrongly**, and LPM precedence by prefix length is deterministic — the
ordering the caller wanted was not silently randomised, it was decided by a different and
well-defined rule.

**FINDING-07 is therefore a contract and documentation defect, not a forwarding one.** The
inference above ("dst-only goes to LPM") was right; recording that it was *confirmed by reading
the other side* rather than left standing on the match shapes, because the two are not the same
strength of claim.

**And this is now the strongest of the four instances**, not the weakest: the API accepts a
`priority`, routes the request to a table that has no such column, answers `success`, and says
nothing — **while the table that would honour it sits one field away in the same pipeline.** The
capability is present, reachable, and undiscoverable. That is precisely what Option 1 exists to
fix, and no amount of prose accuracy would have surfaced it to a caller.

⚠️ **New gap registered from the same read (auditor ③a), not covered by anything above:** a
5-tuple match arriving **without** a priority compiles to `flow_5tuple`, where P4Runtime makes
priority **mandatory** — and the proxy would be passing `route_flow(..., None)`. What happens then
is unknown to everyone who has looked. Same family as B-2c-b. Worth answering before Option 0 adds
any refusal, since it may already be a refusal, or worse, an acceptance with an invented value.

## Option 0 — write the boundary down as a contract (the floor)

Refuse out-of-range requests with a clean `400` that **names the field and says what the loaded
pipeline does support**, and document the supported subset per arm.

* **Cost**: low. The proxy already produces named-field refusals for part of this.
* **Buys**: the caller stops guessing. Today a request can be accepted, echoed back during the
  pending window, and silently not do what it said — which is the worst of the three outcomes.
* **Does not buy**: any new capability.
* ⚠️ **Interacts with an existing ruling.** "Missing priority → 400" was ruled **not to change**
  (2026-08-30, §1.2): the only known caller drops the response, so a new 400 would silently stall
  its modifies. Any refusal added here must be checked against that reasoning — *stricter
  validation is a breaking change for a caller that does not read status codes*, and this project
  has one of those.

## Option 1 — `/ndt/get_switch_capabilities`

A read endpoint: the P4 arm reports tables, key fields and actions **from P4Info**; the OVS arm
reports OpenFlow features.

* **Cost**: medium. Needs P4Info parsed and reachable from the kernel.
* **Buys**: the boundary becomes *discoverable* instead of documented — it cannot drift from the
  loaded pipeline, because it is derived from it. That matters here specifically: this repo has
  repeatedly found documentation describing a build nobody runs.
* **Watch**: it must report the **loaded** pipeline, not a compiled-in constant. A capabilities
  endpoint that answers from a hardcoded list is a new way to be confidently wrong, and it would
  pass every test that does not swap the `.p4`.

## Option 2 — a P4Runtime pass-through endpoint

Accept a P4Runtime `TableEntry`, validate against P4Info, program it directly.

* **Cost**: high. New wire format, new validation, and a second write path beside the OpenFlow one.
* **Buys**: full expressiveness of the loaded pipeline.
* 🔴 **The twin cannot model what it forwards.** The path model is built from OpenFlow-shaped
  matches; an arbitrary `TableEntry` is opaque to it. Any entry installed this way must be marked
  **"not represented in the path model"**, and every consumer of the twin's reachability answers
  has to tolerate that mark. Without it the twin would silently answer path questions from an
  incomplete graph — an over-confident answer, which is the failure direction this project keeps
  paying for.
* Depends on A-7's outcome record to report per-entry failures, since the same async dispatch
  applies.

### Capability is not only a field list — it is also behaviour per deployment mode

Second input from tonight, and it generalises the ticket. `POST /ndt/historical_logging?state=enable`
answers `{"status":"success"}` on a deployment where the recorder **is never started** (MININET —
which is both lab stacks). The fix already shipped adds `"recording": false` and says so; the
endpoint now discloses a capability it does not have.

Same family as the priority case, one level out: **the API's answer was true about the request and
false about the consequence.** So whatever Option 1 reports must cover *deployment-mode* behaviour,
not just pipeline structure — "this build will not record", "this table has no priority" and "this
arm cannot express `tcp_dst` without `ip_proto`" are three instances of one question.

🔑 And the reason to expose it rather than document it: both of those were **documented wrongly**
for weeks — §39 described the shape this lab never produces, and the ledger described a silent
failure that had already been made non-silent. A derived answer cannot drift from the build; prose
always does.

## Option 3 — make the existing endpoint do LPM

🔴 **This option is now void as written.** The read above shows the existing endpoint's dst-only
rules **already go to an LPM table**. There is nothing to add; `ipv4_lpm` is what they have been
hitting all along, which is precisely why they come back with no priority.

What remains of the intent is the opposite of what the option said: not "teach it LPM" but
**"stop silently sending priority-bearing requests to the table that cannot use it"** — either by
routing a richer match to `flow_5tuple`, or by refusing/annotating the request. Both belong to
Options 0 and 1, so **Option 3 is withdrawn rather than re-scoped.**

Recorded rather than quietly deleted: the option was written from the API's vocabulary instead of
the pipeline's, and one source read removed it. That is the cheapest thing on this list doing its
job.

## Recommendation

**Option 0 now, Option 1 next, and read the `.p4` before either is scoped.**

The source read is the cheapest item on the list and it gates two of the four options plus an open
question in FINDING-07. Doing it first costs one reading session and could remove Option 3 from
consideration entirely.

Option 2 is real work and should not start until someone has said what the twin is allowed to be
ignorant of. That is a product decision, not an engineering one.

## What this ticket does not establish

* **The `.p4` has not been read.** Every statement about match kinds above is conditional, and
  deliberately phrased that way.
* **No option was costed against the OVS arm's behaviour**, which is the arm both apps are
  actually deployed against.
* **Whether any caller wants this.** The two in-repo consumers use a narrow, stable subset; the
  demand for expressiveness is inferred from the API's shape, not from a request. Worth confirming
  before Option 2 is scheduled — an expensive capability nobody asked for is its own defect.
