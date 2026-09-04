# run-06 — orchestrator verification of the tester's findings

The tester's report is a claim, not a finding. Each item below was re-checked
against a source independent of the tester: the manual at the frozen docs commit
`c5262c3`, the source of the ref it actually tested (`9e6cc307`, fetched
unauthenticated from the public snapshot), trunk, or the shipping repository of
the tool concerned.

**11 of 17 confirmed, 1 partial, 5 not verified.** The unverified ones are named at
the end and must not be quoted as findings.

Run ended without a `## SUMMARY`: three interruptions, none from the thing under
test. See NSLAB-USAGE-RULES.md row A-11.

---

## BUG-03 — CONFIRMED. Class: snapshot lags trunk, not a new kernel defect

**Claim:** `POST /ndt/acquire_lock` with no `type` (or a malformed body, or no
body) answers `200 {"status":"locked","type":"routing_lock"}` and really takes
the lock — while the API page states that was fixed on 2026-08-30.

**Checked four ways, three of them independent of the tester:**

1. **The manual quote is accurate.** `c5262c3`, Developer Manual → NDTwin Kernel
   API, lines 1955/1958/1997 carry the quoted sentences verbatim, including
   *"All three now return `400` and acquire nothing"* and *"`detail` quotes what
   the caller sent, never a value the server substituted."*
2. **The fix exists in trunk**: `4ee086f8`, 2026-08-30, *"acquire_lock: decide
   first, acquire second"*, and `git merge-base --is-ancestor` puts it in trunk.
3. **The fix is absent from the ref the tester ran.** In
   `src/ndt_core/http/HttpSession.cpp` at `9e6cc307`: `routing_lock` appears
   **0** times and `decide first` **0** times, against **4** and **2** in trunk.
   `acquire_lock` appears once in both — the positive control that says the
   comparison is looking at the right file.
4. **The mechanism matches the symptom**, which is what turns a keyword count
   into an explanation. The tested version assigns the default *before* parsing
   and keeps it when parsing fails:

   ```cpp
   std::string lockType = LockManager::DEFAULT_LOCK_TYPE_STR;
   try  { lockType = jsonBody.value("type", LockManager::DEFAULT_LOCK_TYPE_STR); }
   catch (...) { /* Keep default values if JSON parsing fails */ }
   bool success = m_lockManager->acquireLock(lockType, ttl);
   ```

   Trunk parses first and refuses before acquiring anything. That also explains
   the detail the tester noticed and could not have predicted: unknown types
   answer **423, not the documented 400** — because in the old code every
   rejection came out of `acquireLock` failing, one message for two unrelated
   conditions.

**Verdict: real, reproduced, and mechanically explained.** Per Adam's ruling this
class goes to the ledger and not into the pass/fail criterion — the tester hit a
defect fixed in trunk but absent from the frozen public snapshot.

🔴 **But one consequence is live and needs no kernel change.** The manual states
the fix as accomplished fact, and it is false for every reader who clones what
the manual tells them to clone. A first-time tester with no access to any of our
internal documents rediscovered exactly this. It is the sharpest instance of the
pattern we already had on file, now with an outside witness.

---

## BUG-09, BUG-10, BUG-11 — CONFIRMED. Class: live defects in a shipped tool

🔴 **Not a snapshot gap.** These are in `main` of
`ndtwin-lab/Network-State-Recorder` — fetched unauthenticated, so this is what
anyone gets today. The whole of both scripts:

```bash
# start_network_state_recorder.sh                     # stop_network_state_recorder.sh
#!/bin/bash                                           #!/bin/bash
                                                      echo $(pgrep -f network_state_recorder.py)
SETTING_FILE="./setting/recorder_setting.yaml"        sudo kill -15 $(pgrep -f network_state_recorder.py)
if [ -f "$SETTING_FILE" ]; then
    sed -i 's/\(display_on_console:\s*\).*/\1false/'   SETTING_FILE="./setting/recorder_setting.yaml"
fi                                                    if [ -f "$SETTING_FILE" ]; then
                                                          sed -i 's/…/\1true/' "$SETTING_FILE"
nohup python3 network_state_recorder.py &             fi
```

**BUG-09 — confirmed, all three parts.**

* Line 9 is a bare `python3`. The Installation Manual (`c5262c3`, *Network State
  Recorder.md:52*) tells the reader *"Note the interpreter path
  (`~/nsr-env/bin/python`, or the Conda equivalent) — `start_…sh` launches the
  recorder with an interpreter path written inside the script, so open it once
  and check that path points at the environment you just created."* **There is no
  such path to check.** The one instruction that would have prevented the failure
  cannot be carried out.
* The same page requires a venv because 24.04 enforces PEP 668, so the system
  `python3` is guaranteed to lack `nornir`. The script therefore fails on a
  correctly-followed install, every time — the tester's traceback is exactly that.
* **The config edit happens on line 6, before the launch on line 9**, with no
  error handling in between, and the script's exit status is that of the `if`
  block. So it flips `display_on_console` to `false` and exits 0 whether or not
  anything started — and the value it flips is the one that would have shown the
  user the error. The tester's `SCRIPT_EXIT=0` with no process, no
  `recorded_info/` and no `logs/` is reproduced by reading the script.

**BUG-10 — confirmed, and it is exact.** Line 3 of the stop script is

```bash
sudo kill -15 $(pgrep -f network_state_recorder.py)
```

and the User Manual for that same tool (`c5262c3`, *Network State Recorder.md:85*)
says **"Do not pipe the search straight into `kill`"** and then quotes that
command, character for character, as the thing not to write. **The shipped script
is the anti-pattern its own documentation warns against.**

**BUG-11 — confirmed by the same reading.** With nothing running the command
substitution is empty, and the script's exit status comes from the trailing `if`
block regardless, so it reports success having stopped nothing — while line 8 sets
`display_on_console` back to `true` either way.

📌 Worth noting for us specifically: this is the same construct this project
forbids itself (`pgrep -f` / `pkill -f`). We have the rule; a tool we ship does
not.

---

## BUG-04 — CONFIRMED, and it is a regression I introduced today

**Claim:** `install/modify/delete_flow_entry` return a body different from the
documented `{"status": "Flows installed, modified and deleted"}`. The tester saw
`{"accepted":1,"detail":"…","status":"queued"}`.

**The two clone paths return different bodies, and the manual documents one:**

| ref | `"queued"` | `"accepted"` | what it actually returns |
|---|---|---|---|
| `9e6cc307` — what the manual's **P4 path** clones | 2 | 1 | line 1080 builds `{"status","queued"},{"accepted",…}` |
| `origin/main` — what the manual's **OVS path** clones | 0 | 0 | line 878: `R"({"status":"Flows installed, modified and deleted"})"` |
| trunk | 3 | 1 | as the snapshot |

⚠️ A keyword count alone would have got this wrong: `Flows installed` appears
once in the snapshot too — **inside a comment** (`// This used to answer …`), not
in a response. Counts had to be resolved to code before they meant anything.

🔴 **How this got here.** Earlier today I changed this page *from* the queued body
*to* `Flows installed, modified and deleted`, after the auditor showed that
`origin/main` returns the latter. That evidence was correct. The change was still
wrong, because **the manual has two clone paths and tells an unsure reader to
take the P4 one** — so I made the page right for the OVS reader and wrong for the
default reader. An outside tester following the manual hit it within hours.

**The fix cannot be a single body.** The page has to key the response to which
repository the reader cloned, because no one string is true for both.

---

## BUG-06, BUG-07, BUG-12, BUG-13 — CONFIRMED

* **BUG-06** — the API page documents `404` for `get_nickname` with no
  identifier; the server answers `400`. Confirmed against the page at `c5262c3`.
  The tester notes the observed behaviour is arguably the better one; that is a
  doc fix, not a code fix.
* **BUG-07** — page line 628 documents
  `{"error": "Missing or malformed query parameters"}`; snapshot line 659 returns
  `{"error":"Missing or invalid ip/action"}`. Exact mismatch.
* **BUG-12** — machine-checkable and unambiguous: of the three ```json blocks on
  the NSR User Manual page, **3 of 3 fail to parse**. No judgement involved.
* **BUG-13** — confirmed, with a nuance the tester could not see from outside.
  The snapshot *does* carry a shape guard, and its comment says exactly why it
  exists. But it validates **entries**, and a body whose *top-level* keys are
  unrecognised has no entries to validate — so the guard never fires, and the
  caller gets `200 "queued"` with `"accepted":0` as the only signal that nothing
  was taken. A guard that checks the contents of an envelope does not check
  whether the envelope was understood.

---

## BUG-05 — PARTIALLY VERIFIED

The page says *"In MININET mode, dummy values are generated for demonstration
purposes"* for **both** CPU (line 851) and memory (line 869), which is verified.
Whether the two endpoints return byte-identical maps rests on the tester's
capture alone; I did not re-run it. Given identical wording for both, identical
output is not surprising — the defect, if any, is that the worked examples imply
they differ.

---

## Not verified — 5 items

**BUG-08, BUG-14, BUG-15, BUG-16, BUG-17.** Recorded, not adjudicated. BUG-17
(three pages describing the mixed OVS+BMv2 refusal three ways) was spot-checked
only as far as confirming that six pages discuss it; which description is the
true one was not settled, and that is the whole claim.

## Standing note on classes

Two kinds of confirmed finding here, and they must not be reported together:

* **Snapshot lags trunk** — BUG-03. Real for readers, already fixed in trunk.
  Ledger only, per Adam's ruling; the live half is the documentation.
* **Live in what ships today** — BUG-09/10/11 (Network-State-Recorder `main`),
  BUG-04/06/07/12/13 (documentation, or behaviour on the ref the manual sends
  readers to). These are not waiting on anything.

---

# Addendum, 2026-09-04 (A-12i) -- the six open items, adjudicated on the shipped image

Everything below was run on the published P4/BMv2 demo image
(`sha256 5ed8dcb9...3fefab`), which is a **different artefact** from the one run-06's tester used.
Evidence: `doc/audit/2026-09-04_a12-virtualbox-manual-run/evidence-a12i/` and `-a12g/`.

## BUG-05 — now **VERIFIED** (was partial)

This document said the byte-identical CPU/memory maps rested on the tester's capture alone and
were not re-run. **They were re-run.** `get_cpu_utilization` and `get_memory_utilization` return
the same body, md5 `480e906c87b2` for both, and **sampled again six seconds later both are
unchanged**. `get_temperature` is a different series that also does not move. All three report on
`192.168.123.11`-`.20`, the physical management addresses in the static topology file, while the
switches running are `s1`-`s10`.

The doubt recorded here -- that identical wording makes identical output unsurprising -- stands,
and the defect is sharper than "dummy values": **the two endpoints return the *same* dummy values**,
so a reader comparing CPU against memory is comparing a series with itself.

## BUG-08 — **CONFIRMED**, and worse than reported

```
POST /ndt/modify_device_name  {"vertex_type":0,"dpid":1,"new_name":"a12i-renamed"}
200  {"status":"Device name updated successfully."}
```

`setting/StaticNetworkTopologyMininet_10Switches.json`:

| | sha256 (first 12) | mtime |
| :--- | :--- | :--- |
| before | `14988a44c0e6` | 2026-08-29 16:55:59 |
| after | `949b082ff482` | **2026-09-04 05:19:45** |
| after renaming back to `s1` | **`3c2ff0602230`** | later still |

**The endpoint rewrites the whole file, and the rewrite is not byte-stable.** Changing a name and
changing it back does *not* restore the file -- so on a real checkout, an API call dirties the
working tree and undoing the change does not clean it. Nothing in the response or the log warns
that a file in your source tree was written.

⚠️ The *git-tracked* half of the original claim could not be tested here: the image ships with
git metadata removed. What is confirmed is the file modification and the silence.

## BUG-14 — **CONFIRMED**

With `nfs-server` **inactive**:

```
before:  /srv/nfs/sim -> power
POST /ndt/app_register  {"app_name":"a12i-probe","simulation_completed_url":"..."}
200  {"app_id":1,"message":"Application registered successfully"}
after:   /srv/nfs/sim -> 1  power
```

The export directory is created on a machine with no NFS running, and the response says only that
registration succeeded.

## BUG-15 — **CONFIRMED as a documentation defect, corrected as a product claim**

`HttpSession.cpp:589` is `int k = 50;` -- but `k` is read from the query string first, via
`utils::queryParam(m_req.target(), "k")`. **`?k=N` works.** Proof that it is really parsed, rather
than inferred from source: `?k=abc` produces

```
[warning] [HttpSession.cpp:599 handleGetDetectedTopKFlowData] Invalid k value: abc
```

So the correct statement is **not** "silently caps at K=50 with no way to set it". It is: *the
default is 50, the parameter exists, and §30 documents neither.* The defect is real and it is in
the page, not the product.

## BUG-16 — **CONFIRMED**

| `NTG.yaml` `host_file` | value |
| :--- | :--- |
| as printed in the Installation Manual | `"./setting/Mininet.yaml"` |
| as shipped on the image | `"./setting/Hardware.yaml"` |

The page's own note beneath the block reads *"If you want to use `Mininet`, please change the path
of `host_file` to `./setting/Mininet.yaml`"* -- telling the reader to change it to the value the
block above already shows. The printed configuration is not what the repository ships, and the note
contradicts the print.

## BUG-17 — **CONFIRMED, and the source comment shares the error**

`TopologyAndFlowMonitor.cpp:385`:

```cpp
// Report the data plane, and refuse a mixed topology unless explicitly allowed. ...
validateDataPlaneHomogeneity(AppConfig::ALLOW_MIXED_DATAPLANE);
```

**The return value is discarded** -- no `if`, no assignment, no early return, no throw; the
enclosing function ends on the next line. Inside, with `ALLOW_MIXED_DATAPLANE = false`
(`AppConfig.hpp:15`), the mixed branch emits `SPDLOG_LOGGER_ERROR(... "Topology mixes data planes
...")` and returns `false`, which nobody reads.

So the kernel **logs an error and loads the topology anyway**:

* `architecture.md` -- *"refuses to load"* — **false**
* Installation Manual §6 -- *"logs an error naming the mixture when it loads"* — **true**

which is exactly this bug's claim. The additional finding is that **the code's own comment says
"refuse" too**, so the documentation and the source agree on a verb the code does not implement.

[Co-developed with claude code -- Adam]
