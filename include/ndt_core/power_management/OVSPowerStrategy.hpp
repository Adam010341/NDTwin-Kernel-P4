// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"
#include <optional>
#include <string>
#include <vector>

class OVSPowerStrategy : public IPowerStrategy
{
public:
    OVSPowerStrategy() = default;
    virtual ~OVSPowerStrategy() = default;

    OpResult powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    OpResult powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;

    const char* describe() const override { return "Open vSwitch"; }

    /**
     * @brief Turns one `ovs-vsctl br-exists` result into the three-way answer. No process, no
     *        shell, no bridge.
     *
     * @param ran        utils::CommandOutcome::ran -- whether the program was reached at all.
     * @param waitStatus the wait status from waitpid(), NOT an exit code.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * FINDINGS #82. Split out of executeBridgeExists so the rule can be tested without running
     * anything: every double in tests/ replaces the seam, so the seam's own body would otherwise
     * be exercised by no test at all -- the same gap tests/test_OvsPowerStrategy.cpp's
     * `TheRealShellSeamRunsTheCommandAndReportsItsExitStatus` was written to close for
     * executeSystemCommand, arrived at before it could open.
     *
     * The rule, from ovs-vsctl(8) EXIT STATUS:
     *   - exit 0     -> true      the bridge exists
     *   - exit 2     -> false     it does not. An answer.
     *   - otherwise  -> nullopt   1 (a usage or connection error), a signal, or never ran.
     *
     * 🔴 `waitStatus` is a wait status. Exit 2 is 512 as an int, which is why this takes WIFEXITED
     * apart rather than comparing the number: executeSystemCommand's own comment records that
     * this file once logged "status 256" for a command that exited 1.
     */
    static std::optional<bool> interpretBrExistsStatus(bool ran, int waitStatus);

protected:
    /**
     * @brief Runs a shell command; returns false when it failed.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Returns the outcome rather than setting a member. It used to set m_lastCommandFailed, which
     * powerOn/powerOff reset on entry and read at the end -- and there is exactly one
     * OVSPowerStrategy for the whole process (DeviceConfigurationAndPowerManager::m_ovsPowerStrategy),
     * while the HTTP server runs std::thread::hardware_concurrency() threads on one io_context with
     * no strand. So two concurrent power requests for different switches shared that flag: one
     * request's reset could erase the other's failure, and one request's failure could be reported
     * against the other. Powering s1 on and s2 off at the same time could report the wrong outcome
     * for either.
     *
     * The flag was introduced by the change that made these failures visible at all -- baseline kept
     * everything in locals and discarded the result, so it had the opposite bug and not this one.
     * Found by a review of that change; see doc/audit/2026-08-08_commit-review/power.md H1.
     */
    virtual bool executeSystemCommand(const std::string& cmd);

    /**
     * @brief Runs a command as an explicit argument vector. **No shell.** Returns false on failure.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md B-2b/B-4. executeSystemCommand hands its string to /bin/sh, so every
     * value interpolated into it is shell *code*. The two sFlow restore commands A-4f added
     * interpolate five values read back out of the switch's own OVS database -- targets, header,
     * sampling, polling and the agent interface name -- and tests/python/
     * test_shell_command_construction.py refuses to let an unclassified site like that stand,
     * on the principle that an unclassified site is presumed request-controlled.
     *
     * This is the seam that removes the question instead of answering it: each element goes to
     * execvp() as one argument, so a quote, a semicolon, a newline or `$(...)` inside an OVSDB
     * value is just bytes. Note it is not "escaping done right" -- there is no character table
     * here to get wrong, which is the property that makes it a fix.
     *
     * 🔴 Virtual for the reason executeListPorts and executeReadSflowState are: this file's
     * header records that add-br once bypassed the fake and really ran `sudo ovs-vsctl` against
     * a developer's machine. A test double that replaces executeSystemCommand alone does NOT
     * intercept this one, so a double must override both -- FakeOvs and RendezvousOvs in
     * tests/test_OvsPowerStrategy.cpp do, by delegating here to their string seam.
     */
    virtual bool executeArgvCommand(const std::vector<std::string>& argv);

    /**
     * @brief Lists a bridge's ports, or reports that it could not find out.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Returns std::nullopt when the query itself failed, which used to be indistinguishable from a
     * bridge that genuinely has no ports: both were an empty vector. That is the same one-way
     * conflation that made `ovs-vsctl list-br` failing mark the entire fabric dead, but the
     * consequence here is worse and permanent. powerOff() recorded the empty list over the graph's
     * saved ports and then deleted the bridge, so the ports it was supposed to restore were gone
     * for good and a later powerOn() built an empty bridge -- a switch reporting UP with no data
     * plane attached.
     *
     * Verified against a live ovs-vsctl: `list-ports` on a bridge that does not exist writes
     * nothing to stdout and exits 1, so the exit status is the only thing that distinguishes the
     * two cases.
     */
    virtual std::optional<std::vector<std::string>> executeListPorts(const std::string& br);

    /**
     * @brief Whether the bridge exists on this machine right now, or nothing when the question
     *        could not be asked.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * FINDINGS #82. `powerOff` used to open with
     *
     *     if (!topoMonitor->getVertexIsUp(node)) { return OpResult::success(); }
     *
     * -- the OVS twin of the P4 early return #35 names. It asked the graph, and the graph is a
     * cache of somebody else's opinion about this bridge: `loadStaticTopologyFromFile` starts
     * every vertex at `isUp = false`, the 1 Hz liveness worker writes false the moment
     * `ovs-vsctl list-br` stops naming the bridge or cannot be run at all, and after FINDINGS #46
     * a commanded-off switch stays false until a power-on lifts it. A power-off arriving in any
     * of those states returned 200 "Success" having deleted nothing -- and, since #46, without
     * ever reaching `setVertexPoweredOffByCommand`, so on OVS the #46 fix held only when `isUp`
     * happened to be true at power-off time.
     *
     * The P4 side could simply delete its guard because its helper is idempotent FROM A
     * MEASUREMENT (`already-stopped`, read out of /proc). OVS has no such helper, and the reason
     * the guard could not just be deleted here is `executeListPorts`: `list-ports` on a bridge
     * that does not exist writes nothing and exits 1, so an unguarded power-off on an
     * already-deleted bridge would refuse with a 500. This seam is the measurement that makes
     * the guard unnecessary -- the same role the P4 helper plays, one question smaller.
     *
     * `ovs-vsctl br-exists NAME` is ovs-vsctl's own existence predicate and the one command here
     * whose entire answer IS its exit status (ovs-vsctl(8), EXIT STATUS):
     *
     *   - exit 0            -- the bridge exists.
     *   - exit 2            -- it does not. An ANSWER, not a failure.
     *   - anything else     -- `std::nullopt`. The question was not answered: the binary is
     *                          missing, sudo refused, ovsdb-server is not listening.
     *
     * 🔴 Three outcomes, kept apart for the reason spelled out on `executeListPorts` and
     * `executeReadSflowState`: a refusal that got read as "no such bridge" would make every
     * power-off on that machine skip the teardown and report success, which is a louder version
     * of the defect this seam exists to remove.
     *
     * ⚠️ `br-exists` is a NEW `sudo` argv shape, and a NOPASSWD allowlist is argv-pattern scoped
     * -- `list-ports` being permitted says nothing about `br-exists`. `powerOff` therefore treats
     * `std::nullopt` as "attempt the teardown anyway" rather than as a refusal: on a machine
     * where the question cannot be asked, behaviour degrades to exactly what this file did
     * before, instead of to a power-management outage.
     *
     * Runs through `utils::execArgv`, so the bridge name never becomes shell code (B-2b) and the
     * shell-site population in tests/python/test_shell_command_construction.py is unchanged.
     *
     * 🔴 Virtual for the reason all three seams above it are: this file's test header records
     * that `add-br` once bypassed the fake and really ran `sudo ovs-vsctl` against a developer's
     * machine because a seam had a hole in it. Every double in tests/ must override this one too.
     */
    virtual std::optional<bool> executeBridgeExists(const std::string& br);

    /**
     * @brief Deletes the bridge and saves what `powerOn` will need to rebuild it.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * FINDINGS #82. This is `powerOff`'s body as it stood, lifted out unchanged so that the
     * bridge-absent path can skip it without duplicating the line that records the command.
     * There is exactly one `setVertexPoweredOffByCommand` call in this translation unit, in
     * `powerOff`, on both paths -- which is what makes "a redundant power-off is still a
     * command" true by construction rather than by two call sites agreeing.
     *
     * Returns a failure when the ports could not be read or a command failed; the vertex is left
     * up in both cases, because a bridge that is still there is still forwarding.
     */
    OpResult tearDownBridge(Graph::vertex_descriptor node,
                            const std::string& swName,
                            TopologyAndFlowMonitor* topoMonitor);

    /**
     * @brief Reads a bridge's sFlow record and its agent interface's address, or reports that it
     *        could not find out.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * KNOWN-ISSUES A-4f. `powerOff` calls this before `del-br` and `powerOn` calls it again after
     * the restore, so one seam both saves the state and verifies that putting it back worked.
     *
     * Three outcomes, and keeping them apart is the whole point (see executeListPorts above for
     * what conflating two of them cost the port list):
     *
     *   - `std::nullopt`         -- the query failed. Not "no sFlow".
     *   - `configured == false`  -- the bridge genuinely has no sFlow record.
     *   - `configured == true`   -- the record, plus the IPv4 on its agent interface.
     *
     * ⚠️ The commands this runs are new `sudo -n ovs-vsctl` argv shapes. A NOPASSWD allowlist is
     * argv-pattern scoped, so `list-ports` being permitted says nothing about `get bridge`. A
     * denial arrives on stderr with a non-zero status and must come back as nullopt, never as an
     * empty state -- that is the same "counted 0 from an empty stream" trap the memory file
     * `injections-must-assert-their-own-success` records as its eighth form.
     */
    virtual std::optional<SflowBridgeState> executeReadSflowState(const std::string& br);

    /**
     * @brief Rebuilds the sFlow record on a freshly created bridge and puts the agent address
     *        back, then reads it back and says whether it is really there.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Separate from powerOn's body so the read-back and the decision it drives can be tested
     * without a fabric. Returns true only when executeReadSflowState afterwards reports
     * `configured == true` -- an ovs-vsctl that exits 0 is not evidence that the record is
     * attached, and this project has already paid twice for treating an exit status as proof of
     * an effect.
     */
    bool restoreSflow(const std::string& swName, const SflowBridgeState& saved);

    /**
     * @brief Settles whatever sFlow restore the switch is owed, marks it up, and says what
     *        happened.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Reached from two places: the end of a full bring-up, and directly from the top of powerOn
     * when the switch is already running and only the telemetry is missing. Those two must not
     * share a code path any further back than this, because a switch that is already up cannot
     * be brought up again -- `add-br` on an existing bridge exits 1 and would fail the retry for
     * the wrong reason.
     *
     * Marks the vertex up on every path including the failures: a bridge with no sFlow forwards
     * traffic, and that is exactly what makes A-4f silent rather than obvious.
     */
    OpResult finishTelemetryRestore(Graph::vertex_descriptor node,
                                    const std::string& swName,
                                    const SflowBridgeState& saved,
                                    TopologyAndFlowMonitor* topoMonitor);
};
