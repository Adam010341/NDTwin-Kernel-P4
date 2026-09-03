# run-06 — orchestrator verification of the tester's findings

The tester's report is a claim, not a finding. Each item below was re-checked
against a source independent of the tester: the manual at the frozen docs commit
`c5262c3`, the source of the ref it actually tested (`9e6cc307`, fetched
unauthenticated from the public snapshot), trunk, or the shipping repository of
the tool concerned.

**4 of 17 verified so far. The other 13 are untouched and must not be quoted as
findings until they are.**

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

## Not yet verified — 13 items

BUG-01, 02, 04, 05, 06, 07, 08, 12, 13, 14, 15, 16, 17.

Two of them look likely to matter and should go next:

* **BUG-02** — the manual's own detached form of Step 6.1 blocking on a sudo
  password prompt that the manual's own progress check cannot see. This is the
  one finding **produced by this round's single changed variable** (the tester VM
  no longer has blanket passwordless sudo), so rounds 01–04 could not have found
  it. That makes it the round's most interesting result even though it is filed
  as friction.
* **BUG-01** — the cloned README pointing at a demo VM the Download page marks as
  unpublished. That page changed today; check against `c5262c3`, not against the
  working tree.

[Co-developed with claude code -- Adam]
