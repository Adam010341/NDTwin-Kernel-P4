// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- Phase 7: real operations via the manifest helper.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"

#include <chrono>
#include <map>
#include <mutex>

class P4PowerStrategy : public IPowerStrategy
{
public:
    P4PowerStrategy() = default;
    virtual ~P4PowerStrategy() = default;

    OpResult powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    OpResult powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;

    const char* describe() const override { return "P4/bmv2"; }

protected:
    /// The shell seam, and the whole test surface: both power operations are command
    /// sequences, so a subclass that records commands instead of running them can assert
    /// what would have been executed. Returns whether the command exited 0 -- it was void
    /// once, which is how a failed power action reported success.
    virtual bool executeSystemCommand(const std::string& cmd);

    /// [Co-developed with claude code -- Adam]
    /// The clock seam. Exists so a test can age a power-off past the distrust window below
    /// without sleeping through it; production has exactly one implementation.
    virtual std::chrono::steady_clock::time_point now() const;

    /// How long after this strategy's own successful powerOff the graph's `isUp` stops being
    /// usable evidence about that switch.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Derived rather than chosen. After the kill, DeviceConfigurationAndPowerManager's 1 Hz
    /// worker asks p4LivenessFor, which answers Up from the proxy's still-cached `probe_ok` and
    /// then Unknown until the switch's last LLDP beacon ages past kLldpFreshSeconds (12s). A
    /// beacon is at most one beacon-period old when the switch dies, so the graph can carry a
    /// wrong `isUp` for at most 12s plus one worker tick. 15s is that bound with margin, and it
    /// is also the number the operational workaround already used ("power off, wait 15 seconds,
    /// power on") -- this constant is that workaround moved out of the runbook and into the code.
    static constexpr std::chrono::seconds kPostPowerOffDistrustWindow{15};

private:
    /// True while this strategy's own powerOff is too recent for the graph to have an opinion
    /// about @p swName worth acting on.
    bool poweredOffWithinDistrustWindow(const std::string& swName) const;

    /// Opens the distrust window for @p swName; called only where a stop was confirmed.
    void notePowerOff(const std::string& swName);

    /// Closes it again, once a real process is running under that name.
    void clearPowerOffRecord(const std::string& swName);

    /// Switch name -> when this strategy last confirmed that switch stopped.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Keyed by name, not by vertex descriptor: descriptors are indices into a graph that is
    /// rebuilt when the topology changes, so a stale entry could come to name a different
    /// switch. The name is what both power calls are handed, and it does not get recycled.
    ///
    /// Guarded because this is the first state the strategy has ever held: powerOn and powerOff
    /// are reached from HTTP session threads, and one process-wide strategy object serves all of
    /// them (DeviceConfigurationAndPowerManager::m_p4PowerStrategy).
    mutable std::mutex m_lastPowerOffMutex;
    std::map<std::string, std::chrono::steady_clock::time_point> m_lastPowerOffAt;
};
