# T-6 — Developer Manual, *NDTwin Kernel API* page, checked against a live kernel

Page: `NDTwin-Website/content/en/docs/NDTwin Developer Manual/NDTwin Application/NDTwin Kernel API.md`
(2 127 lines). Kernel: `89c1754`, running, verified by dev+inode (`BASELINE-PROVENANCE.md`).
Fabric: P4, 10 switches, 4 hosts, data plane verified. 2026-08-30 15:46–15:58.

Method: the two-stage criterion this round established for R-1 — **establish the route table
from the service side first, then compare.** The page is never used as the source of what
exists.

---

## Headline

| | |
|---|---|
| documented endpoints | **29** |
| documented endpoints that do not exist in the kernel | **0** |
| documented endpoints whose HTTP method disagrees with the dispatcher | **0** |
| kernel routes with no entry on this page | **12 of 41 — 29 % of the HTTP surface** |

**The page makes no false promises.** Everything it documents exists, and every method it
states is the method the dispatcher accepts. That is the stronger of the two possible results
and it is worth saying plainly.

What it does is **under-describe**: nearly a third of the kernel's routes have no entry.

## The undocumented twelve

```
/ndt/delete_group_entry              /ndt/install_group_entry
/ndt/delete_meter_entry              /ndt/install_meter_entry
/ndt/get_detected_top_k_flow_data    /ndt/intent_translator/text
/ndt/get_openflow_capacity           /ndt/modify_group_entry
/ndt/get_static_topology_json        /ndt/modify_meter_entry
/ndt/historical_logging              /ndt/inform_all_destination_paths
```

Two of these are not hypothetical surface:

* **`/ndt/intent_translator/text`** is **called by a shipped consumer** — `Web-GUI/src/components/llm/LLM.ts:21`,
  built as `` `${NDT_API_BASE_URL}/ndt/intent_translator/text` `` (recorded in
  `PRE-ROUND-R1-determination.md`). An app depends on an endpoint the Developer Manual does
  not mention.
* **`/ndt/historical_logging`** is R-1's endpoint. PREREG §3 named it by its C++ handler symbol
  (`set_historical_logging_state`) rather than its route, and **an author checking the manual
  would not have found the route either**, because it is not there. The two failures share a
  cause.

The remaining ten cluster into two coherent families — **group entries** (4) and **meter
entries** (4) — which suggests two features were added without a documentation pass, rather
than ten scattered omissions.

## Merged in from R-1, at the auditor's direction — and the answer is sharper than expected

R-1's live probe produced an observation worth checking against this page: `POST
/ndt/historical_logging` answers **`200` with `"status":"success"` on both of its branches**.
Only `recording` and `message` differ, so **a caller keying on the status code, or on the
`status` field, cannot tell "recording is on" from "recording is impossible in this
deployment"** — and the second branch is the one that fires in every run this project does.

The registered question was whether the page documents that distinction. It does not, and not
because of a wording defect:

> **`/ndt/historical_logging` has no entry on this page at all.** It is one of the twelve
> undocumented routes listed above.

⇒ There is no wording to correct. The endpoint whose two outcomes are indistinguishable by
status code is also the one with no documentation, so a caller has **neither** signal — not
from the wire, not from the manual.

🔑 This closes a loop opened before the round. `PRE-ROUND-R1-determination.md` recorded that
PREREG §3 named this endpoint by its C++ handler symbol (`set_historical_logging_state`) rather
than its route. That now reads as a symptom rather than a slip: **an author who went to the
Developer Manual to find the route would not have found one.** The two failures have one cause,
and it is this omission.

**When the entry is written it must state the two branches explicitly**, because the status code
will not.

## Live probes — documented endpoints, using their documented methods

All read-only endpoints on the page, against the running kernel:

| endpoint | method | curl_rc | http |
|---|---|---|---|
| `get_average_link_usage` | GET | 0 | 200 |
| `get_cpu_utilization` | GET | 0 | 200 |
| `get_detected_flow_data` | GET | 0 | 200 (`[]`) |
| `get_graph_data` | GET | 0 | 200 |
| `get_memory_utilization` | GET | 0 | 200 |
| `get_nickname` | GET | 0 | **400** — `{"error":"Missing dpid, mac, or name parameter"}`, correct |
| `get_path_switch_count` | GET | 0 | 200 |
| `get_power_report` | GET | 0 | 200 |
| `get_switches_power_state` | GET | 0 | 200 |
| `get_switch_openflow_table_entries` | GET | 0 | 200 |
| `get_temperature` | GET | 0 | 200 |
| `get_num_of_flows_passing_a_switch` | **POST** | 0 | 200 |
| `get_total_input_traffic_load_passing_a_switch` | **POST** | 0 | 200 |

`curl_rc` and HTTP status are recorded separately, never collapsed (H-19).

### ⚠️ Two corrections to my own work, both against the page's favour and both wrong

**1.** My first probe sent **GET** to the last two rows and got **404**. Written up naively that
is "two documented endpoints are missing". It is not: both are declared `POST` in the
dispatcher (`HttpSession.cpp:292`, `:297`) *and* the page says `POST` in its own headings
(`## 25.`, `## 26.`). **The page was right and my probe was wrong.** POST returns 200 for both.

**2.** A method-aware comparison then reported **13 method defects**. Before writing them up:
four of the thirteen were endpoints I had *just* probed live at 200. The parser was checked
against the route table and could see only **22 of 41** paths — its regex required
`target.starts_with(…)` or a literal `target.==`, and most routes are written
`target == "/ndt/get_graph_data"`, with no dot. Fixed, the parser sees **41 of 41** and reports
**0** defects.

🔑 Both near-misses were caught by the same question, and it is the one this round keeps paying
for: **can my instrument see the things it is claiming are absent?** A positive control on the
parser (41 paths visible) is what makes the zero above mean something. Without it, this file
would have carried thirteen fabricated documentation defects.

## What was *not* checked, so the zero is not read as wider than it is

* **Response schemas.** Whether each documented example body matches the live body, field for
  field. Only presence, method and status were checked.
* **The 16 mutating endpoints** (`install_*`, `modify_*`, `delete_*`, `set_switches_power_state`,
  `link_failure_detected`, `link_recovery_detected`, `app_register`, `inform_switch_entered`,
  the three lock verbs, the two simulation verbs). Exercising them changes the fabric, and this
  was a documentation check running inside another round's measurement window. Their
  **paths and methods are covered** by the source-level comparison — 29 of 29 — but their
  behaviour was not.
* **`/ndt/acquire_lock` is additionally out of scope** by PREREG §5.
* **Parameter and error semantics.** `get_nickname`'s 400 was read as correct because its
  message names the missing parameters; no other endpoint's error path was exercised.

## Recommendation

One documentation ticket, not twelve: **add the group-entry and meter-entry families, and the
four singletons**, with `/ndt/intent_translator/text` first because a shipped app already
depends on it. No corrections are needed to what is already on the page.

[Co-developed with claude code -- Adam]
