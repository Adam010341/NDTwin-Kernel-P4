// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"
#include <optional>

class OVSPowerStrategy : public IPowerStrategy
{
public:
    OVSPowerStrategy() = default;
    virtual ~OVSPowerStrategy() = default;

    OpResult powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    OpResult powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;
    
    const char* describe() const override { return "Open vSwitch"; }

protected:
    virtual void executeSystemCommand(const std::string& cmd);

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

    /// Set by executeSystemCommand when a command exits non-zero, so powerOn/powerOff can
    /// report failure instead of asserting the switch changed state.
    /// [Co-developed with claude code -- Adam]
    bool m_lastCommandFailed = false;
};
