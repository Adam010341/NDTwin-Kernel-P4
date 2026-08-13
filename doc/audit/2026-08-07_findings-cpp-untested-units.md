# Agent A -- findings (bugs NOT fixed, and untestable code)

## Suspected real bugs

### 1. `handlePacket` reads `m_flowInfoTable` with no lock at all -- data race with `purgeIdleFlows`
`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1353`

    auto it = m_flowInfoTable.find(key);          // <-- NO LOCK
    if (it != m_flowInfoTable.end())              // Existing flow
    {
        std::unique_lock<std::shared_mutex> lk(m_flowInfoTableMutex);   // lock taken only here
        ...
    }
    else                                          // New flow
    {
        std::unique_lock<std::shared_mutex> lk(m_flowInfoTableMutex);   // ...or here
        auto& info = m_flowInfoTable[key];
        ...
        stats.ingressByteCountCurrent = uint64_t(frameLength);   // line 1401: ASSIGNS, not +=
    }

Every other access to `m_flowInfoTable` is guarded: `purgeIdleFlows` erases under
`unique_lock` (line 1888-1889), `getFlowInfoTable`, `calAvgFlowSendingRatesPeriodically` and
`getFlowInfoJson` all take the mutex. Line 1353 is the one exception, and it runs on **every
sampled packet on every sFlow worker thread**.

Two distinct consequences:

**(a) Undefined behaviour.** An unlocked `unordered_map::find` racing with `erase` (purge
thread, 1 Hz) and with `operator[]` insertions from sibling workers (which rehash) is a data
race. This is the same failure class the file's own comment at line 2128 says the locks exist
to prevent -- "invalidating the iterator, which is the crash this whole set of locks exists to
prevent."

**(b) A counter that goes backwards, silently.** The find-then-branch is not atomic, so two
workers can both miss for the same new key and both take the "New flow" branch. The second one
gets the *existing* stats from `operator[]` and **assigns** `ingressByteCountCurrent =
frameLength` (line 1401), discarding the first worker's accumulation. If that happens after
`calAvgFlowSendingRatesPeriodically` has copied Current into Previous (lines 1591-1594), the
next interval computes, at line 1558:

    stats.avgByteRateInBps = (byte_count_current - byte_count_previous) * 8 * currentSamplingRate;

on `uint64_t` operands with `current < previous`. That underflows to ~1.8e19, which is then
compared against `MICE_FLOW_UNDER_THRESHOLD` and sets `info.isElephantFlowPeriodically = true`
-- and that flag is **never cleared**, because the `else` that would clear it is commented out
(lines 1615-1618). So one lost race permanently misclassifies a flow.

Not fixed, as instructed. Not unit-testable either -- see "untestable" below.

### 2. `ModifyFlowEntryTask`'s constructor labels itself an install
`include/ndt_core/intent_translator/LLMResponseTypes.hpp:664`

    ModifyFlowEntryTask()
    {
        type = INSTALL_FLOW_ENTRY;     // should be MODIFY_FLOW_ENTRY
    }

Deserialising hides it: `task_from_json` overwrites `type` from the wire afterwards. The visible
route is a task built in C++ -- `to_json(json&, const unique_ptr<Task>&)` switches on `type`,
so it `static_cast`s a `ModifyFlowEntryTask` to `InstallFlowEntryTask` and emits
`"type": "InstallFlowEntry"`. Pinned by
`AModifyFlowEntryTaskConstructsItselfAsAnInstallDocumentsCurrentBehaviour`; the mutation that
breaks that test is the one-word fix.

### 3. `"tasks": null` with `"valid": true` parses to an Answer with no tasks and no error
`include/ndt_core/intent_translator/LLMResponseTypes.hpp:2346`

    for (const auto& taskJson : j.at("tasks"))

nlohmann iteration over a `null` or an empty object yields an empty range. So a reply that
asserts there was work to do, and names none of it, is accepted silently. The *absent* key is
caught (`.at` throws); only present-but-not-a-list slips through.

This is the only failure shape in the parser with no diagnostic anywhere: `LLMAgent` sees a
non-null pointer, `inputTextIntent`'s `dynamic_cast` to `Answer` succeeds, the task loop has
nothing to iterate, and the GUI is handed the model's prose explanation of what it claims to
have done. Pinned by `ANullTasksFieldYieldsNoTasksAndNoErrorDocumentsCurrentBehaviour`.

### 4. All four reserved OUTPUT targets collapse to 65535
`src/ndt_core/collection/Classifier.cpp:875-879`

    constexpr uint32_t OFPP_CONTROLLER = 65535;
    constexpr uint32_t OFPP_LOCAL      = 65535;
    constexpr uint32_t OFPP_FLOOD      = 65535;
    constexpr uint32_t OFPP_NORMAL     = 65535;

OpenFlow assigns these distinct values (CONTROLLER 0xfffd, LOCAL 0xfffe, FLOOD 0xfffb,
NORMAL 0xfffa); 0xffff is OFPP_ANY/NONE, which is not a forwarding target at all. So punt-to-
controller, flood and hand-to-local-stack are indistinguishable, and all three report a port
number no switch has. Latent -- nothing downstream compares against the reserved range yet.
Pinned by `AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour`.

### 5. `order` and `priority` wrap silently, and widening the field would NOT fix it
`LLMResponseTypes.hpp:471` (`uint16_t order`), `:611` (`uint16_t priority`)

`"order": -1` arrives as 65535 (the largest possible order -- the opposite of what a model
emitting -1 to mean "first" intends). `"priority": 70000` arrives as 4464, so a rule meant to
win against everything is installed below a default priority-10 rule.

Worth stating because mutation testing proved it: changing `uint16_t order;` to `int32_t order;`
and `uint16_t priority;` to `uint32_t priority;` **changed no behaviour at all** -- both
mutations came back NO-FAILURE. The narrowing happens inside nlohmann's `get<uint16_t>()`, not
in the assignment, so the field's own type never sees the out-of-range value. A fix has to
reject or clamp at the `get` site; widening the field is a no-op.

### 6. `Answer::from_json` appends to `tasks` without clearing it
`LLMResponseTypes.hpp:2346-2351`. Latent -- `make_llm_from_json` always allocates a fresh
`Answer` -- but `Answer` is a public type with a public `from_json`, and the failure mode is
every task being executed twice. Pinned by
`DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour`.

### 7. `utils::macToUint64` does no format or length validation
`include/utils/Utils.hpp:605-626`. It reads fixed offsets `mac.data() + i*3` for i in 0..5 with
no check on `mac.size()` and no check that the separators are colons. Demonstrated: the
17-character colon-free string `"aabbccddeeff11223"` returns 187728154005795 instead of being
rejected.

I attempted to demonstrate a buffer over-read for short inputs and **could not** -- for any
`std::string` the bytes at indices 0..16 stay inside either the SSO buffer or the heap
allocation, so ASAN reports nothing and short inputs happen to throw "Invalid hex digit" from
`from_chars`. So the provable finding is the missing validation, not a memory-safety bug. I am
not claiming the latter.

### 8. `parseUint` is lenient about leading whitespace and `+`, despite looking strict
`src/ndt_core/collection/Classifier.cpp:797-816`. It checks `errno`, rejects empty, and requires
the whole string to be consumed -- but it is built on `strtoul`, which skips leading whitespace
and accepts a leading `+` before any of those checks can see them. So `"OUTPUT: 4"` is port 4,
while `"OUTPUT:4 "` is rejected. Found by one of my tests failing on the opposite assumption.
Also worth knowing: `"OUTPUT:-4"` is rejected only by the `v > 0xFFFFFFFF` range check --
`strtoul` wraps `-4` to 2^64-4 rather than erroring -- so that range check is doing double duty
as the sign check.

## What I could not test, and the missing seam

### `FlowLinkUsageCollector`'s rate arithmetic -- needs a pure helper extracted
The counter-delta arithmetic (finding 1b) is inline in
`calAvgFlowSendingRatesPeriodically`, a private method whose body is a `while (m_running)` loop
with a 1-second `sleep_for`. There is no way to drive one interval of it from a test: no way to
inject `AgentFlowStats`, no way to run a single iteration, no way to observe
`avgByteRateInBps` without the whole object and a live socket.

The precedent for the fix already exists in this file: `computeEstimatedRates` was extracted as
a free function and *is* tested (`tests/test_EstimatedRates.cpp`, 8 tests, including the
zero-hops divide-by-zero). The same treatment for the byte/packet delta -- a free function
taking `(currentBytes, previousBytes, samplingRate)` and returning the rate -- would make
counter-goes-backwards, first-ever-sample, and sampling-rate-scaling all testable. I did not
extract it myself because that is a larger change than a seam and it touches the hot path.

### `HistoricalDataManager` -- constructor does filesystem I/O to a hard-coded absolute path
`src/ndt_core/data_management/HistoricalDataManager.cpp:26`

    std::filesystem::create_directories("/home/of-controller-sflow-collector/LinkData");

Cannot be constructed in a unit test unless that path is creatable, and a test that creates
directories outside the build tree is not one I would write. The seam is an output-directory
parameter (defaulted to the current constant), which would also let a test assert what gets
written. Untested as a result: `start()` in MININET mode sets `m_running = true` and then
returns *without* starting the thread (`if (m_running.exchange(true) or m_mode == MININET)`),
so the flag claims the manager is running when nothing is. Reachable but not assertable today.

### `ControllerAndOtherEventHandler` -- 12 collaborators and a real TCP acceptor
Its constructor takes an `io_context` plus 12 `shared_ptr`s, and `start()` binds a listening
socket. Several of those collaborators have side-effecting constructors of their own
(`IntentTranslator` builds two `LLMAgent`s; `HistoricalDataManager` creates directories). The
routing logic worth testing lives in `HttpSession`, which is explicitly not mine. No test
written.

### `IntentTranslator::performTask` -- 720 lines behind an LLMAgent-constructing constructor
`IntentTranslator`'s constructor unconditionally builds two `LLMAgent` objects from prompt file
paths, so the class cannot be instantiated without those files. `performTask` is where every
task actually reaches the network, and it is a 720-line switch. The seam would be either a
protected constructor that skips agent creation, or `performTask` taking its collaborators as
arguments. I tested the parsing that feeds it instead, which is the layer that decides *what*
`performTask` is asked to do.

### `parseActionsArrayIntoEffect` and `describeFirstOutputPort` are file-local `static`
Reached only through `Classifier::updateFromQueriedTables` + `lookup`, which is what
`tests/test_ClassifierActionForms.cpp` does. Workable, but it means an action-parsing test has
to build a matching rule and a matching `FlowKey` to observe a parse result, and a rule that
fails to *match* is indistinguishable from an action that failed to *parse*. Every test in that
file asserts `effect.has_value()` first for exactly that reason.

---

# Review note

Finding 5 (`order`/`priority` wrap, and widening the field would not fix it) was reached
independently while resolving the NO-FAILURE rows -- see
`doc/audit/2026-08-07_mutation-evidence-cpp.md`. Two sources, same conclusion.

Finding 6 (`Answer::from_json` appends to `tasks` without clearing) is the **fourth** instance of
this repo's recurring shape: *something that should replace is implemented so it can only add.* The
earlier three were `run()` taking a single topology snapshot, `Classifier` skipping an empty flow
table, and `setAllPaths` never clearing its maps. Worth treating as a class rather than four
incidents -- the question to ask of any ingest is "when does the old data disappear?"

None of these are fixed. Each needs its own decision.
