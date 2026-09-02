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
