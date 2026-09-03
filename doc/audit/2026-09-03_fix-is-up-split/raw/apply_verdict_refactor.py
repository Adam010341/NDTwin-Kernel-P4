#!/usr/bin/env python3
"""Retarget the two gate survivors.

M13 pointed at the pingWorker call site, which no test can reach (the worker needs a live
proxy), so the mutation survived -- correctly: that line was uncovered. The fix is to move the
policy out of the loop into a named function the way ovsLivenessFor and p4LivenessFor already
are, so it can be driven directly.

M15 expected a test that has a power-off record to notice a change to the branch taken only
when there is NO record. Wrong expectation, and the `if (false)` form also stepped past a
guard into `it->second` on an end() iterator. Replaced with the narrow over-correction:
the no-record branch refuses instead of accepting.
"""
import pathlib
import sys

ROOT = pathlib.Path("/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/"
                    "1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/wt-isup")


def edit(rel, old, new, count=1):
    p = ROOT / rel
    s = p.read_text()
    if s.count(old) != count:
        sys.exit(f"{rel}: anchor count {s.count(old)}, expected {count}\n---\n{old[:200]}")
    p.write_text(s.replace(old, new, 1))


# --- 1. header: declare the verdict function -----------------------------------------------
edit("include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp",
     """    bool acceptP4LivenessUp(const std::string& swName,
                            uint64_t dpid,
                            const std::optional<nlohmann::json>& payload);""",
     """    bool acceptP4LivenessUp(const std::string& swName,
                            uint64_t dpid,
                            const std::optional<nlohmann::json>& payload);

    /**
     * @brief The verdict the 1 Hz worker acts on for one bmv2 switch: p4LivenessFor's answer,
     *        with an Up that rests on a pre-kill probe downgraded to Unknown.
     *
     * [Co-developed with claude code -- Adam] -- FINDINGS #80.
     * Extracted for the same reason ovsLivenessFor and p4LivenessFor were, and the mutation gate
     * is what made the reason concrete: while this lived inline in pingWorker's switch, the line
     * that consults the evidence could not be reached by any test -- the worker needs a running
     * proxy -- so a mutation deleting it survived. Policy that cannot be driven is policy that
     * is not gated.
     *
     * Downgraded to Unknown rather than to Down: a stale reading is an absence of current
     * evidence, not evidence of death, and Unknown is the branch this file already reserves for
     * "cannot tell, so do not touch the graph".
     */
    OvsLiveness p4VerdictFor(const std::string& swName,
                             uint64_t dpid,
                             const std::optional<nlohmann::json>& payload);""")

# --- 2. cpp: define it, next to the policy it wraps -----------------------------------------
edit("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     """/** @brief See the header. Dates one Up verdict and asks the P4 strategy whether it counts.
 *
 * [Co-developed with claude code -- Adam] -- FINDINGS #80.
 */""",
     """/** @brief See the header. p4LivenessFor's verdict, with a stale Up downgraded to Unknown.
 *
 * [Co-developed with claude code -- Adam] -- FINDINGS #80.
 */
DeviceConfigurationAndPowerManager::OvsLiveness
DeviceConfigurationAndPowerManager::p4VerdictFor(const std::string& swName,
                                                 uint64_t dpid,
                                                 const std::optional<json>& payload)
{
    const OvsLiveness verdict = p4LivenessFor(dpid, payload);
    if (verdict == OvsLiveness::Up && !acceptP4LivenessUp(swName, dpid, payload))
    {
        return OvsLiveness::Unknown;
    }
    return verdict;
}

/** @brief See the header. Dates one Up verdict and asks the P4 strategy whether it counts.
 *
 * [Co-developed with claude code -- Adam] -- FINDINGS #80.
 */""")

# --- 3. pingWorker: consult the named function ----------------------------------------------
edit("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     """                        switch (p4LivenessFor(graph[v].dpid, p4SwitchState))
                        {
                        case OvsLiveness::Up:""",
     """                        switch (p4VerdictFor(swName, graph[v].dpid, p4SwitchState))
                        {
                        case OvsLiveness::Up:""")

edit("src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp",
     """                            // Declining is silent in the graph -- the vertex keeps whatever it
                            // held -- and that is the same Unknown the branch below takes when
                            // the payload cannot be trusted. It applies ONLY to a switch this
                            // strategy has stopped and nothing has seen since; for every other
                            // switch acceptLivenessUp answers yes and this costs one map lookup.
                            if (!acceptP4LivenessUp(swName, graph[v].dpid, p4SwitchState))
                            {
                                break;
                            }
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} reachable", swName);""",
     """                            // Declining is silent in the graph -- the vertex keeps whatever
                            // it held -- because p4VerdictFor turns such a reading into the same
                            // Unknown the branch below takes when the payload cannot be trusted.
                            // It applies ONLY to a switch this strategy has stopped and nothing
                            // has seen since; for every other switch the verdict is unchanged
                            // and it costs one map lookup.
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} reachable", swName);""")

# --- 4. tests: drive the verdict function, not just the join --------------------------------
edit("tests/test_IsUpSplit.cpp",
     """    using DeviceConfigurationAndPowerManager::acceptP4LivenessUp;
    using DeviceConfigurationAndPowerManager::p4ProbeAgeSeconds;""",
     """    using DeviceConfigurationAndPowerManager::acceptP4LivenessUp;
    using DeviceConfigurationAndPowerManager::p4ProbeAgeSeconds;
    using DeviceConfigurationAndPowerManager::p4VerdictFor;
    using DeviceConfigurationAndPowerManager::OvsLiveness;""")

edit("tests/test_IsUpSplit.cpp",
     """    EXPECT_FALSE(manager.acceptP4LivenessUp("s1", 1, switchState(1, true, 30.0)))
        << "the worker accepted a probe taken thirty seconds ago for a switch killed just now. "
           "This is the 8-13 s of `is_up=true` measured after every kill on the live fabric";""",
     """    EXPECT_FALSE(manager.acceptP4LivenessUp("s1", 1, switchState(1, true, 30.0)))
        << "the worker accepted a probe taken thirty seconds ago for a switch killed just now. "
           "This is the 8-13 s of `is_up=true` measured after every kill on the live fabric";""")

edit("tests/test_IsUpSplit.cpp",
     """/**
 * The switch nobody killed: the worker must not start asking permission for the whole fabric.
 */""",
     """/**
 * 🔴 THE VERDICT THE WORKER ACTS ON, which is the only thing the graph ever sees. The case above
 * proves the judgement; this one proves it is WIRED -- that a declined Up becomes Unknown, the
 * one verdict the worker does not write. The gate found this gap: while the check sat inline in
 * pingWorker's switch, no test could reach it and deleting it survived.
 */
TEST_F(IsUpSplitTest, AStaleUpBecomesUnknownSoTheWorkerWritesNothing)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, true, 30.0)),
              TestableManager::OvsLiveness::Unknown)
        << "a pre-kill probe still reaches the graph as Up. Unknown is the verdict the worker "
           "does not act on, and it is the only one that leaves the vertex alone";

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, true, 0.0)),
              TestableManager::OvsLiveness::Up)
        << "a probe taken now was downgraded too; that is 'never believe liveness again'";
}

/**
 * Downgraded, not inverted. A stale Up must not become Down -- the twin would be asserting that
 * a switch is dead on the strength of a reading it has just declared unusable.
 */
TEST_F(IsUpSplitTest, ADownVerdictIsPassedThroughUntouched)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, false, 0.5)),
              TestableManager::OvsLiveness::Down)
        << "the evidence check touched a verdict that was not Up; it exists to stop a stale "
           "reading LIFTING a switch, not to stop the twin noticing a dead one";
}

/**
 * The switch nobody killed: the worker must not start asking permission for the whole fabric.
 */""")

# --- 5. the gate: retarget M13 and M15 -------------------------------------------------------
edit("tests/shell/mutate_is_up_split.sh",
     """add_anchor "worker-join"   "$PM" '                            if (!acceptP4LivenessUp(swName, graph[v].dpid, p4SwitchState))'""",
     """add_anchor "worker-join"   "$PM" '    if (verdict == OvsLiveness::Up && !acceptP4LivenessUp(swName, dpid, payload))'""")

edit("tests/shell/mutate_is_up_split.sh",
     """# M13. The worker stops asking: the join is bypassed and every Up is written, which is trunk's
#      behaviour and the 8-13 s of `is_up=true` after every kill that #80 measured.
mutate "the 1 Hz worker writes every Up without dating it" \\
    "$PM" \\
    '                            if (!acceptP4LivenessUp(swName, graph[v].dpid, p4SwitchState))' \\
    '                            if (false)' \\
    IsUpSplitTest.TheWorkerDeclinesAnUpWhoseProbePredatesTheKill""",
     """# M13. The worker stops asking: the verdict is passed through undated and every Up is written,
#      which is trunk's behaviour and the 8-13 s of `is_up=true` after every kill that #80
#      measured. 🔴 THIS MUTATION SURVIVED THE GATE'S FIRST RUN, because the check was inline in
#      pingWorker's switch and the worker needs a running proxy -- no test could reach the line.
#      That is what moved the policy into p4VerdictFor: policy that cannot be driven is policy
#      that is not gated.
mutate "the worker acts on the raw verdict without dating it" \\
    "$PM" \\
    '    if (verdict == OvsLiveness::Up && !acceptP4LivenessUp(swName, dpid, payload))' \\
    '    if (false)' \\
    IsUpSplitTest.AStaleUpBecomesUnknownSoTheWorkerWritesNothing""")

edit("tests/shell/mutate_is_up_split.sh",
     """# M15. THE OVER-CORRECTION: nothing is ever believed again. Every catch in direction 1 gets
#      GREENER, and the twin reports a live fabric dead -- the 1 Hz worker is the only writer
#      that brings a bmv2 switch back for anything discovery answers Unknown about.
mutate "no liveness Up is ever accepted again" \\
    "$P4" \\
    '    if (it == m_lastPowerOffAt.end())
    {
        // Nothing has been commanded off, so nothing is being distrusted and every observation' \\
    '    if (false)
    {
        // Nothing has been commanded off, so nothing is being distrusted and every observation' \\
    IsUpSplitTest.AnUncommandedSwitchAcceptsEveryLivenessUp \\
    IsUpSplitTest.TheWorkerAcceptsEveryUpForASwitchItNeverStopped \\
    IsUpSplitTest.AProbeTakenAfterTheKillClosesTheWindow""",
     """# M15. THE OVER-CORRECTION: a switch this strategy never stopped is distrusted too, so nothing
#      is ever believed again. Every catch in direction 1 gets GREENER, and the twin reports a
#      live fabric dead -- the 1 Hz worker is the only writer that brings a bmv2 switch back for
#      anything discovery answers Unknown about.
#      🔴 The gate's first run named a third test here that has a power-off RECORD, so this branch
#      is not on its path at all -- a mutation must name the tests it can actually reach.
mutate "an uncommanded switch's liveness is distrusted too" \\
    "$P4" \\
    '        // Nothing has been commanded off, so nothing is being distrusted and every observation
        // counts. This is the branch the entire fabric takes on every tick.
        return true;' \\
    '        // Nothing has been commanded off, so nothing is being distrusted and every observation
        // counts. This is the branch the entire fabric takes on every tick.
        return false;' \\
    IsUpSplitTest.AnUncommandedSwitchAcceptsEveryLivenessUp \\
    IsUpSplitTest.TheWorkerAcceptsEveryUpForASwitchItNeverStopped""")

print("applied")
