# R-1 fires its registered null branch — determined **before** the round

PREREG §3 registered R-1 with an explicit third outcome:

> *Registered null branch:* **no app calls this endpoint at all** — in which case R-1 is
> untestable by this round and must be reported as untestable, not as passed.

That branch is the one that fires. Established by reading source only — no fabric, no kernel,
no load — while the lab was held by `8/29 poster-reviewer`.

## Result

**No consumer app calls the endpoint.** R-1 is **UNTESTABLE** by this round. It must not be
scored as passed, and the round must not be credited with exercising it.

---

## ✏️ Correction — my first pass searched the wrong string

The first version of this file searched for **`set_historical_logging_state`**. That is the
**handler name**. The wire route is:

```cpp
// src/ndt_core/http/HttpSession.cpp:284
else if (method == http::verb::post && target.starts_with("/ndt/historical_logging"))
{
    handleSetHistoricalLoggingState(*response);
}
```

`"/ndt/set_historical_logging_state"` appears as a route **zero times in the kernel**. A caller
would have written `/ndt/historical_logging`, which my exact-string search would have missed
entirely. **The conclusion survives; the evidence for it did not, and has been redone.**
(Raised by `8/29 auditor` alongside AMENDMENT-1; verified here by reading `:284` directly
rather than accepting it.)

🔑 The pass that saved it was the **word-level scan for `histor`**, which covers both names. It
was included as a belt-and-braces check and turned out to be the load-bearing one. Had the route
been named without that stem — `/ndt/hlog`, say — both searches would have returned zero and the
same verdict would have gone out with nothing behind it.

### The criterion this produces — a "nobody calls it" determination is **two-stage**

Luck is the diagnosis; this is the prescription:

> **1. Against the service side, establish that the name exists and is unique.** Read it out of
> the route table / dispatcher / emitter — not out of the ticket, the PREREG, or a header.
> **2. Only then, against the caller side, establish zero.**

Reversing the order produces the `/ndt/hlog` failure: a caller-side zero that is really a
name-side zero, wearing the same output.

⚠️ **A positive control does not cover this.** The control here — all seven repos yielding
`/ndt/` endpoints — proves the *instrument can find callers*. It says nothing about whether the
*string being searched is the right string*. Those are two different failures and only stage 1
catches the second. This determination originally had a strong control and was still resting on
the wrong name.

**Stage 1, discharged for this endpoint.** Every route in the kernel whose path contains the
stem:

```
$ grep -noE '"/ndt/[a-z_]*histor[a-z_]*"' src/ndt_core/http/HttpSession.cpp
284:"/ndt/historical_logging"
```

**One hit, so the name exists and is unique** — there is no second spelling for a caller to be
using. Stage 2 (the seven-repo table below) is therefore interpretable.

---

## The scan, redone: seven repos, named

`components.env` lists **seven** callers. The first version scanned six and did not say which,
so "six repos" could not be checked against anything. Named, with the correct route:

| repo | `/ndt/historical_logging` | `set_historical_logging_state` | `histor` (any) | distinct `/ndt/` found |
| :--- | ---: | ---: | ---: | ---: |
| Energy-Saving-App | 0 | 0 | 0 | 14 |
| Network-State-Recorder | 0 | 0 | 0 | 4 |
| Network-Traffic-Generator | 0 | 0 | 2 | 2 |
| Network-Traffic-Visualizer | 0 | 0 | 3 | 5 |
| Simulation-Platform-Manager | 0 | 0 | 0 | 3 |
| Traffic-Engineering-App | 0 | 0 | 0 | 1 |
| **Web-GUI** | **0** | **0** | **19** | **12** |

**The last column is the control.** A zero-hit search proves nothing about the world until it
has been shown capable of finding anything: all seven repos yield `/ndt/` endpoints, so the
zeros in the first two columns carry information.

### The `histor` hits, resolved

* **Web-GUI (19)** — UI concerns only: history panel, time-range selector, availability
  timeline, an i18n key `history.endTime`. Filtering those 19 files for any line mentioning
  `ndt|fetch|axios|api|endpoint|url` leaves **one** hit, and it is the i18n key. None is a call.
* **Network-Traffic-Visualizer (3)** — `README.md` describing local playback of saved data files.
* **Network-Traffic-Generator (2)** — not an NDT route.

### Concatenation, closed twice

Two callers build URLs from a base, which literal searches miss:

* `Traffic-Engineering-App/Traffic-engineering-App.py:32` — `ndt_url = ".../ndt/"`, endpoint
  appended at the call site. Resolved set: `get_graph_data`, `get_detected_flow_data`,
  `acquire_lock`, `release_lock`, `install_flow_entry`, and
  `install_flow_entries_modify_flow_entries_and_delete_flow_entries` (multi-line at `:571-573`,
  with a commented twin at `:565-569`).
* `Web-GUI/src/components/llm/LLM.ts:8,21` — `NDT_API_BASE_URL` from env, then a **template
  literal**: `` `${NDT_API_BASE_URL}/ndt/intent_translator/text` ``.

⚠️ **The template literal caught me a second time in the same session.** A grep for
`'/ndt/|"/ndt/|` + backtick-`/ndt/` returned **nothing** in `Web-GUI/src`, because the character
before `/ndt/` is `}`, not a quote. The pattern that works makes no assumption about what
precedes it: `grep -rhoE "/ndt/[a-z_/]*"`. Web-GUI's twelve endpoints were recovered that way
and `historical_logging` is not among them.

---

## What this does and does not say

It says: **this round cannot test R-1.** The branch that changed —
`HistoricalDataManager::start()` returning early under MININET, so the new `message` branch is
the one that fires in every lab run — has no consumer to break.

It does **not** say the change is safe. `/ndt/` is a cross-repo contract and this survey covers
the seven checkouts on this machine. A caller living anywhere else is outside what was searched.
🔑 *"The range I searched" is not "the range that exists"* — and this file now lists the range
by name so the next reader can check it rather than infer it.

## Note on PREREG §5, now stale

§5 lists `/ndt/acquire_lock`'s three defects as "still 待裁, not opened". They were opened and
fixed in `dff87f9` (T-7) after the PREREG was written. **This round is unaffected**: it builds
from `89c1754`, whose source is byte-identical to the registered `faffdbe` across `src/`,
`include/`, `p4_proxy/` and `tests/`, so the `acquire_lock` code under test is the pre-fix one
§5 describes. Recorded here rather than by editing the PREREG — a pre-registration is not
amended after the fact; it gets a determination stamped on top of it.

[Co-developed with claude code -- Adam]
