# COMMIT-PLAN — doc-fix wave, 2026-08-30

**This file is not for version control. Do not `git add` it.** It is the working note for the
changes sitting in this tree; delete it (or move it out) once the commits below are made.

Repo: `/home/adam/NDTwin-Website`, branch `docs/p4-bmv2-environment`, base `c2215f5`.
Tree was verified clean (`git status --porcelain` empty) before any edit.
**Nothing is committed. Nothing is staged. No build, render or server was run** — the machine is
inside another session's measurement window.

Sources read for every item (kernel repo, read-only):

* `doc/2026-08-30_manual-verification-report.md`
* `doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-tools-pages-desk-check.md` (N-*)
* `doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-simulation-platform-desk-check.md` (S-*)
* `doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-desk-check-remaining.md` (T1-2, T2-3…T2-5)
* `doc/audit/2026-08-30_live-full-stack-round/FINDINGS-T6-developer-manual-api-page.md` (T-13)
* `doc/audit/2026-08-28_chaos-harness/08_t7b-evidence.md` §5 (the lock §27–29 mirror)
* `doc/2026-01-02_ndt_api.md` §27–§41 (the corrected in-repo API reference; last touched by
  `87d272f`, "release_lock and renew_lock: decide first, act second", verified present in the
  kernel's current history)

---

## Status by ID

| ID | Verdict | Page |
| --- | --- | --- |
| N-3 | **FIXED** | UM / NDTwin Tools / Network Traffic Generator |
| N-5 | **FIXED** | UM / NDTwin Tools / Network State Recorder |
| N-6 | **FIXED** | UM / NDTwin Tools / Network Traffic Generator (both occurrences) |
| N-8 | **FIXED** | UM + IM / Network State Recorder (title, filename, alias) |
| S-1 | **FIXED** | IM / NDTwin Tool / Simulation Platform + UM / NDTwin Tools / Simulation Platform |
| lock §27–29 mirror | **FIXED** | DM / NDTwin Application / NDTwin Kernel API |
| T-13 (12 routes) | **FIXED** | DM / NDTwin Application / NDTwin Kernel API |
| PEP 668 family (4) | **FIXED — the dispatch premise was wrong, see below** | 4 places |
| `cd` family (4) | **1 ALREADY-FIXED (M-1, `c2215f5`) + 3 FIXED** | 3 places |

### The two "verify only" families were not previously fixed

The dispatch said the PEP 668 family (4 places) and the `cd` family (4 places) had already been
handled by a systematic pass, and asked me only to confirm and patch stragglers. **They had not
been.** Checked three ways before acting:

* `git log --all --oneline --grep='PEP|venv|externally|pip' -i` → two hits, both about the
  Installation Manual's Native-Linux page (`54c3c7a`, `b41b9e4`), neither touching a tools page.
* `grep -rn "externally-managed\|python3 -m venv" content/` → zero hits on any of the four
  PEP 668 sites.
* The working tree was clean, so there was no uncommitted pass either.

So all four PEP 668 sites and three of the four `cd` sites were still open. The fourth `cd` site
is M-1, which **is** already fixed, in `c2215f5` ("Two manual fixes: the Desktop assumption…") —
ALREADY-FIXED, no second attempt made. Commits 6 and 7 below are therefore larger than the
dispatch anticipated; they are kept separate so they can be dropped independently.

---

## Commit 1 — NTG User Manual: the interpreter, and Terminal 3's flags (N-3, N-6)

**File:** `content/en/docs/NDTwin User Manual/NDTwin Tools/NetworkTrafficGenerator(NTG)/index.md`

Finding, verbatim (`FINDINGS-tools-pages-desk-check.md`):

> **N-3** | NTG block 7: `python network_traffic_generator.py` | 🔴 **`python` does not exist** in
> the clean guest — only `python3`, and `python-is-python3` is not installed
>
> ### N-3 is an internal inconsistency, which is what makes it a defect rather than a nitpick
> The same page writes block 2 as `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py` — a
> **full interpreter path** […] — and then block 7 as a bare `python`. **No activation step is
> printed between them.** So the page knows the interpreter is special and then stops saying so.

> **N-6 — NTG's kernel command cannot complete unattended.**
> `sudo -E bin/ndtwin_kernel --loglevel info` carries no `--mode` and no `--topology`, so the
> kernel falls to its three interactive prompts. The Installation Manual's equivalent block was
> corrected on 2026-08-29 to print the flag form for exactly this reason; **this page was not**.

**What changed**

* Hardware §3 (the block N-3 names): bare `python` → `~/miniconda3/envs/ntg-env/bin/python`, the
  same interpreter form block 2 already uses, plus a callout saying `python` is not a command on
  a clean 24.04 machine and that `python3` would be the wrong interpreter anyway.
* Mininet §6 and Hardware §2 (both N-6 occurrences): the flag form, mirroring what `cd684ba`
  already verified on the UM Native-Linux page.
  * Mininet: `--mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json
    --no-ai`, which is answers **1, 1, 2**.
  * Hardware: `--mode testbed --no-ai`, and the callout states that testbed mode does **not**
    also need `--topology`. Verified in `src/main.cpp` `resolveDeploymentConfig`: the topology
    prompt is inside `else if (config.mode == 1)`, so mode 2 never reaches it.
  * `--ai` variant given with `sudo -E` and a real key, per `cd684ba`'s wording.
* Both blocks gained `cd ~/Desktop/NDTwin-Kernel/build` — this is the second half of **N-4** and
  is listed under commit 7; it is physically in this file's diff because it is the same block.
* One character outside the finding: the Mininet list item was written `1.` where `6.` was meant
  (it sits between items 5 and 7). Corrected because my own callout refers to step numbers and
  leaving it would read as though I introduced it. Flagging it rather than hiding it.

## Commit 2 — NSR User Manual: stop killing by pattern (N-5)

**File:** `content/en/docs/NDTwin User Manual/NDTwin Tools/Network State Recorder.md`

Finding, verbatim:

> **N-5 — both NSR status and stop instructions use `pgrep -f`.**
> `pgrep -f` matches **command lines**, so any shell whose own argv carries that string matches
> too — `bash -c '…'`, an editor, another grep. In the status command that is a wrong answer; in
> the stop command **it is a kill of the wrong process**, run under `sudo`. This project banned
> `pgrep -f`/`pkill -f` for killing after seven incidents; the manual teaches it.
> Two further edges: with no match the command becomes `sudo kill -15` with no argument, and with
> several matches it kills all of them.

**What changed**

* Status: `pgrep -f` → `pgrep -af`, so the command prints the matched command line next to each
  PID, with a callout explaining that `-f` matches the whole command line.
* Stop: the one-liner `sudo kill -15 $(pgrep -f …)` is replaced by a two-step recipe — list, read,
  then `sudo kill -15 <PID>` on one confirmed PID — with the three failure modes the finding names
  (no match, several matches, `sudo`) spelled out.

## Commit 3 — NSR pages: the page name is spelled "Recorder" (N-8)

**Files:** both NSR pages, renamed.

* `content/en/docs/NDTwin User Manual/NDTwin Tools/Network State Recoder.md`
  → `… /Network State Recorder.md`
* `content/en/docs/NDTwin Installation Manual/NDTwin Tool/Network State Recoder.md`
  → `… /Network State Recorder.md`

Finding, verbatim:

> **N-8 — the page name is misspelled, in the title as well as the filename.**
> `Network State Recoder.md`, and `title: Network State Recoder` in the front matter, in **both**
> the User and Installation manuals. It is the site's page title and part of its URL.

**What changed:** `title: Network State Recoder` → `Network State Recorder` in both front
matters, both files renamed, and each page given an `aliases:` entry for its old URL so existing
links do not 404:

* `/docs/ndtwin-user-manual/ndtwin-tools/network-state-recoder/`
* `/docs/ndtwin-installation-manual/ndtwin-tool/network-state-recoder/`

Both alias strings were taken from the **existing built output** in `public/` (a pre-existing
local build dated 2026-08-28; `public/` is gitignored and was only read, never regenerated), so
they are the real current URLs rather than my guess at Hugo's slug rules. No in-repo link points
at either page (`grep -rni recoder content/ layouts/ hugo.yaml` → only the two front matters), so
nothing else needed updating.

**Committing note:** the renames were done with plain `mv`, not `git mv`, to leave the index
untouched. `git status` shows them as one deletion plus one untracked file per page; use
`git add -A -- <both paths>` (or `git mv` first) when committing.

## Commit 4 — Kernel API page: the three lock verbs now match the code (§27–§29 mirror)

**File:** `content/en/docs/NDTwin Developer Manual/NDTwin Application/NDTwin Kernel API.md`

Source, verbatim (`08_t7b-evidence.md` §5, "Documentation corrected alongside the code"):

> `doc/2026-01-02_ndt_api.md` documented the defects as the contract, so leaving it would ship a
> cross-repo contract that is known to be false.
>
> * **§27 `acquire_lock`** — was already stale: `dff87f9` changed the behaviour and touched three
>   files, none of them this one. It still said "If the JSON body is missing/invalid, defaults are
>   used" and still documented `423` for an unknown type with the deleted
>   `"System busy or invalid lock type: routing_lock"` body. Corrected.
> * **§28 `renew_lock`** — "Body (optional)… defaults are used" → `type` required; `400` body shape
>   corrected (it documented `{"error":"JSON parsing error"}`, which no code path has ever
>   produced); `412` sentence no longer claims to cover invalid types.
> * **§29 `release_lock`** — "Body (optional)" → required, with the reason. Its ⚠️ block was
>   **doubly stale** […] Rewritten to keep the one that is still true — **`LockManager` has no
>   owner token, so any caller can release any other caller's lock**

The website page still carried the pre-fix text on all three (it said "If the JSON body is
missing/invalid, defaults are used", documented the deleted 423 body, and had no 412 on
`release_lock`). It is now the corrected text.

**Deviations from a byte-for-byte mirror, all deliberate:**

1. Repo-internal paths dropped — `doc/2026-07-28_test_coverage_gaps.md` and
   `tools/contract_test/README.md` are not resolvable for a website reader. The substance of the
   §29 warning (no owner token) is kept; the "two overtaken warnings, kept as history" paragraph
   and the stale-README cross-reference are dropped as internal housekeeping.
2. Two additions from the desk check, because they belong to the same body-spec gap the finding
   identified and a reader of this page cannot get them anywhere else:
   * §27 gains a note that `ttl` defaults to **5 seconds** and that both shipped apps pass
     `ttl: 300` (T2-3). Re-verified rather than taken on trust:
     `include/ndt_core/lock_management/LockManager.hpp:27` `DEFAULT_TTL_SECONDS = 5`;
     `Energy-Saving-App/src/app/http.cpp:425` `{{"ttl", 300}, {"type", "routing_lock"}}`;
     `Traffic-Engineering-App/Traffic-engineering-App.py:71` `json={"ttl": ttl, "type":
     "routing_lock"}` with `ttl=300` defaulted at `:68`.
   * §29's warning gains the second half of T2-5: the locks are global, not per-application, so
     `graph_lock` and `routing_lock` do not exclude each other while two instances of one app do.

This also discharges **T1-2** ("`/ndt/acquire_lock` required fields not written anywhere") for
this page. T1-2's own page — Developer Manual / Application structure §5.3 — is **not** touched by
this wave and still has no request-body spec.

## Commit 5 — Kernel API page: the twelve undocumented routes (T-13)

**File:** same page, new §30–§41.

Finding, verbatim (`FINDINGS-T6-developer-manual-api-page.md`):

> | kernel routes with no entry on this page | **12 of 41 — 29 % of the HTTP surface** |
>
> ```
> /ndt/delete_group_entry              /ndt/install_group_entry
> /ndt/delete_meter_entry              /ndt/install_meter_entry
> /ndt/get_detected_top_k_flow_data    /ndt/intent_translator/text
> /ndt/get_openflow_capacity           /ndt/modify_group_entry
> /ndt/get_static_topology_json        /ndt/modify_meter_entry
> /ndt/historical_logging              /ndt/inform_all_destination_paths
> ```
>
> * **`/ndt/intent_translator/text`** is **called by a shipped consumer** — `Web-GUI/src/components/llm/LLM.ts:21` […]
> * **`/ndt/historical_logging`** is R-1's endpoint […] **an author checking the manual would not
>   have found the route either**, because it is not there.
>
> **When the entry is written it must state the two branches explicitly**, because the status code
> will not.
>
> ## Recommendation
> One documentation ticket, not twelve: **add the group-entry and meter-entry families, and the
> four singletons** […] No corrections are needed to what is already on the page.

**Where the content came from, and how the strength claim is bounded**

* **Paths and methods** — the part T-6 verified — were re-derived from the dispatcher
  (`src/ndt_core/http/HttpSession.cpp`, the `method == http::verb::… && target…` chain) rather
  than copied. All twelve match T-6's list; `inform_all_destination_paths` is POST
  (`:251-252`), `get_static_topology_json` and `get_openflow_capacity` are GET (`:247`, `:280`),
  `historical_logging` and `intent_translator/text` are POST (`:284`, `:260`), the six
  group/meter routes are POST exact-match (`:193-213`), `get_detected_top_k_flow_data` is GET
  (`:161`).
* **Request/response bodies** were mirrored from the kernel repo's own API reference
  `doc/2026-01-02_ndt_api.md` §30–§41, which is where these twelve are already documented. T-6
  explicitly did **not** check response schemas ("What was *not* checked … Response schemas …
  The 16 mutating endpoints"). The page therefore opens the new block with a provenance
  paragraph saying exactly that, and each body carries its own marker — "measured live on
  2026-08-10", or "shape derived from the handler, not measured live", with the reason.
* **§39 `historical_logging` states the two branches explicitly**, as the finding requires. Both
  answer `200 {"status":"success"}` and differ only in `recording` and `message`; the callout
  says a caller keying on the status code or on `status` cannot tell them apart, and that in
  MININET the "nothing will be written" branch is the one that always fires.
  **The kernel repo's own §39 is stale here** — it shows success bodies without the `recording`
  field. The website version uses the three current shapes read from
  `HttpSession.cpp:1801-1818`. See "Noticed in passing" below.
* **§41 `intent_translator/text`** states the 503 refusal. The error string is quoted exactly as
  the kernel emits it (`HttpSession.cpp:1420`), not paraphrased.

**Editorial changes made while mirroring** (all noted so they are not read as findings):

* Source-file and line-number citations (`HttpSession.cpp lines 686-727` etc.) were dropped —
  they are provenance for a kernel-repo reader and they rot. The claim each one supported was
  kept, with its measured/derived marker.
* Two Chinese correction boxes in the kernel doc's §39 were rewritten as English prose stating
  the same measured facts (this is a public English page).
* The two orphan preambles in the kernel doc — the unheaded paragraphs before §31 and before
  §34 that describe the group and meter families — were given headings
  ("Group-entry endpoints (§31–§33) — what they share", "Meter-entry endpoints (§34–§36)").
* Three defects in the kernel doc's own markup were not reproduced: the stray empty code fences
  after §33 and §36, and §32's copy-paste sentence (`with "Group entry modified" replaced by
  "Group entry modified"`).
* §30's `400 Bad Request` "request body is not valid JSON" branch was dropped: §30 is a GET with
  no body, and the branch is boilerplate carried across from the POST sections.
* `doc/2026-01-02_OpenflowCapacity.json` (§37) is described as "the static capability catalogue
  that ships with the kernel" rather than by its repo path.

**Mechanical checks run on the result** (no render was possible — see the caveat at the end):
191 `json` fences on the page, and every one below line 1938 (i.e. everything this wave wrote)
parses with `json.loads`. Code-fence parity is even both at line start (392) and inside
blockquotes (2). All twelve route strings are present.

## Commit 6 — PEP 668: `pip install` does not work on the OS this project mandates

**Files:**

* `content/en/docs/NDTwin Installation Manual/NDTwin Tool/Network State Recorder.md` (N-1)
* `content/en/docs/NDTwin Installation Manual/NDTwin Tool/NetworkTrafficGenerator(NTG)/index.md` (N-2, two blocks)
* `content/en/docs/NDTwin User Manual/NDTwin Tools/NetworkTrafficGenerator(NTG)/index.md` (N-2, worker-node block)

Finding, verbatim:

> **N-1** | NSR install: `pip install nornir loguru orjson requests` | 🔴
> **`error: externally-managed-environment`** on Ubuntu 24.04 (PEP 668). The page's Requirements
> section names **no** virtualenv, and the Kernel manual **mandates** 24.04. **The first command a
> reader types does not work.**
>
> **N-2** | NTG: `pip install --upgrade pip` / `pip install fastapi …` | same refusal, same reason

**What changed:** each of the four blocks now creates and activates an environment before
installing, with a callout stating that this is not optional on 24.04 and that Conda is an equally
good substitute. The NTG install page's callout additionally tells the reader to **write down the
interpreter path**, because the User Manual runs the topology script and NTG under `sudo`, which
does not carry an activated environment across — that is the link between N-2 and N-3.

**One deletion to flag:** the NTG install page's line *"If your environment uses
Conda/virtualenv, activate it before installing packages."* was removed. It was placed after the
block it applied to and framed as optional; the new callout says the opposite, and leaving both
would contradict.

## Commit 7 — the remaining three `cd` defects (N-4, S-2, S-3)

**Files:** NSR install page; NTG User Manual (in commit 1's diff); Simulation Platform install page.

Findings, verbatim:

> **N-4 — the missing `cd`, twice, and it is the M-1 shape.**
> NSR install prints `git clone …` and then `chmod +x start_network_state_recorder.sh …` with
> nothing between them. The clone creates a directory; the `chmod` runs one level above it.
> NTG prints `sudo -E bin/ndtwin_kernel …` with no `cd` either.
> 🔑 Same family as M-1: **a missing `cd` whose failure is quiet, followed by a command that
> appears to work.**

> **S-2 — a comment and its command contradict each other, two lines apart.**
> `# From the source root of Energy-Saving-App` / `cd Energy-Saving-App` / `make all`
> If the reader is already at the source root, `cd Energy-Saving-App` has nothing to enter. The
> comment and the command cannot both be followed.

> **S-3 — §5.3's `cd` assumes a directory the previous step moved away from.**
> §5.2 leaves the reader in Energy-Saving-App's source root […] From there the sibling is
> `../Simulation-Platform-Manager`.

**What changed**

* NSR install: the clone block now ends with `cd Network-State-Recorder`, the clone is moved
  ahead of the dependency install so the `cd` happens before anything needs it, and the Script
  Permissions section says the `chmod` is run inside the cloned directory.
* NTG UM: both kernel blocks gained `cd ~/Desktop/NDTwin-Kernel/build` (same path the UM Physical
  Network page already uses, `Operate a Physical (Hardware) Network.md:50`).
* Simulation Platform install §5.2: the contradictory comment becomes
  `# From the directory that holds both clones (Section 2.1)`, plus a sentence explaining that
  the `../` in the destination is why the two repos must be siblings.
* Simulation Platform install §5.3: `cd Simulation-Platform-Manager` → `cd ../Simulation-Platform-Manager`,
  with a sentence naming where §5.2 leaves you.

**M-1, the fourth member of this family, is ALREADY-FIXED** in `c2215f5` (both clone blocks
`mkdir -p ~/Desktop` first, System Requirements gained an Edition line). Not re-touched.

## Commit 8 — Simulation Platform: `/mnt/nfs/sim` is never created, and the two roles are never named (S-1)

**Files:** `content/en/docs/NDTwin Installation Manual/NDTwin Tool/Simulation Platform.md`,
`content/en/docs/NDTwin User Manual/NDTwin Tools/Simulation Platform.md`

Finding, verbatim:

> ## S-1 — `/mnt/nfs/sim` is never created, and the two roles are never named
> The usage page […] "The server requires root privileges to mount the NFS directory
> **`/mnt/nfs/sim`** during operation."
> The install page creates: `/srv/nfs/sim` (the **export**, blocks 4–5); **`/mnt/nfs/app`** (the
> **mount point**, block 7); `/mnt/nfs/sim` **nowhere**.
> […] the real defect is narrower and more useful:
> 1. **The install page never creates `/mnt/nfs/sim`**, the directory the usage page says the
>    manager mounts. A reader who follows the install page has `/mnt/nfs/app` and nothing else.
> 2. **Neither page says there are two roles.** `app.hpp` and `sim_server.hpp` describe an app
>    machine and a sim-server machine with different mount points; the pages present a single
>    linear procedure with no hint that the reader is configuring two sides.

Re-verified against the source rather than taken from the finding
(`/home/adam/Simulation-Platform-Manager/include/settings/`):

```
sim_server.hpp:17  nfs_server_dir = "/srv/nfs/sim"                    <- the export
sim_server.hpp:18  nfs_mnt_dir    = "/mnt/nfs/sim"                    <- sim-server mount point
sim_server.hpp:28  "mount -t nfs " + ip + ":" + nfs_server_dir + " " + nfs_mnt_dir
app.hpp:27         nfs_mnt_dir    = "/mnt/nfs/app"                    <- app mount point
app.hpp:33         "mount -t nfs " + ip + ":" + "/srv/nfs/sim/" + app_id + " " + nfs_mnt_dir
```

**What changed**

* Install §3.2 retitled from "Client-Side Setup (On Simulation Platform Machine)" to
  "Client-Side Setup", and opened with a two-row table naming both roles, what each mounts, where,
  and which header fixes it. It states that the same-machine demo needs both directories and a
  split deployment needs only the local one.
* Install §3.2 step 2 creates `/mnt/nfs/sim` as well as `/mnt/nfs/app`, and the closing note now
  points at the matching `nfs_mnt_dir` for each.
* User Manual §1.2: a callout saying `/mnt/nfs/sim` must exist beforehand (the manager mounts it,
  it does not create it), naming this command as the **sim-server** role and contrasting it with
  the application role, and linking to Installation §3.2. Link target
  `/docs/ndtwin-installation-manual/ndtwin-tool/simulation-platform/` was confirmed against the
  existing `public/` build output, not guessed.

---

## Suggested commit order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Commits 4 and 5 touch the same file and must be applied in that
order (5 appends after 4's block). Commits 1 and 7 also share a file; if they are split, commit 1
must land first. Everything else is independent.

Style follows this repo's recent commits (`c2215f5`, `cd684ba`, `c3df964`): a prose body stating
what was wrong and how it was checked, `[Co-developed with claude code -- Adam]`, and a
`Co-Authored-By:` trailer. The standing "not pushed" note applies — `Adam010341` has no write
access to this repository.

---

## Noticed in passing — recorded, not fixed

Out of scope for this wave. None of these was touched.

1. **`start_network_state_recorder.sh` hardcodes an absolute interpreter path** —
   `nohup /home/adam/miniconda3/envs/ntg-env/bin/python network_state_recorder.py &`. It cannot
   run on any machine that is not this one. (Software, NSR repo.)
2. **`stop_network_state_recorder.sh` does the exact thing N-5 is about** — it runs
   `sudo kill -15 $(pgrep -f network_state_recorder.py)` internally, and the manual recommends
   that script as Option 1. Fixing the manual's typed commands does not reach it. (Software, NSR
   repo.)
3. **The kernel's `doc/2026-01-02_ndt_api.md` §39 is stale.** Its two success bodies have no
   `recording` field, but `HttpSession.cpp:1803-1818` emits one on all three paths, and there are
   three shapes, not two. The website page now carries the current shapes; the kernel doc does
   not.
4. **Markup defects in the same kernel doc:** stray empty code fences after §33 and §36, and a
   copy-paste sentence in §32 ("with `"Group entry modified"` replaced by `"Group entry
   modified"`"). Not reproduced on the website.
5. **UM / Operate a Physical (Hardware) Network, line 58** still has
   `sudo -E bin/ndtwin_kernel --loglevel info` with no flags — a third instance of the M-4 / N-6 /
   T1-1 family, on a page this wave was not scoped to.
6. **N-7 (NTG worker `uvicorn --port 8000` vs the kernel's port)** was not in the dispatch list and
   was left alone.
7. **T1-2's own page** — Developer Manual / Application structure §5.3 — still gives only method
   and path for the three lock verbs. The API page now has the body spec; the Application
   structure page does not link to it or repeat it.
8. **A U+00A0 (non-breaking space)** starts the line "  Also, you need to make sure NTG can
   connect to those worker nodes." on the NTG User Manual page. Harmless, but it is why a literal
   string match on that line fails.

---

## What was verified, and what was only read

**Verified mechanically:**

* Working tree was clean before the first edit.
* Section 4.1's page (`NDTwin Installation Manual/…/Native-Linux Excution Environment.md`) has a
  **zero-byte diff** — `git diff --stat` on it is empty. Not opened for editing at all.
* No conference or venue name anywhere in `content/`. Checked with a case-insensitive
  `grep -rniE` over `content/` covering the five venues this project has discussed, plus the
  generic giveaways (`submission`, `camera-ready`, `anonymi[sz]ed`). Zero hits. The pattern is
  deliberately not written out here, so that this file cannot itself become the hit.
* Code-fence parity is even in all seven changed files, at line start and inside blockquotes.
* Every changed file ends with a newline. The UM NSR page had lost its trailing newline in the
  round trip and it was restored; that one byte is the only change on the file's last line.
* All 191 `json` blocks in the newly written half of the API page parse with `json.loads`.
* All twelve route strings from the T-13 list are present on the API page.
* Both alias URLs and the one new cross-page link were taken from the existing `public/` build
  output rather than derived from Hugo's slug rules.
* Every kernel line number quoted in this file was re-read from the file before being written
  down; every commit SHA was confirmed to exist in its repo's current history with `git log -1`.

**Read but NOT verified — this is the honest boundary:**

* **Nothing was rendered.** No `hugo`, no `docker`, no server: the machine is inside another
  session's measurement window. Markdown and shortcode correctness is **eye-verified only**.
  The riskiest constructs I introduced, in descending order:
  1. the two-row **table inside a blockquote** in Simulation Platform §3.2 (Goldmark supports it
     with every line `> `-prefixed, which is what is written, but it was not seen rendered);
  2. the fenced code blocks **inside blockquotes** on the NTG UM page and API §41 — this pattern
     is already used on the site by `cd684ba`, which is why I chose it;
  3. the `aliases:` front matter on the two renamed NSR pages — standard Hugo, never rendered
     here;
  4. the `§` characters in the two new `##` headings on the API page, which Hugo will urlize into
     anchor IDs.
* **No command in any of these manuals was executed.** Every "this is what happens" statement is
  either quoted from a finding that measured it, or read from source that I opened myself. The
  new API sections say so per-body.
* The `public/` directory read for URL ground truth is a **2026-08-28 build**. If content has been
  added since then whose URL I depend on, that dependency is unchecked. The two aliases and the
  one link all point at pages that existed on 08-28.
