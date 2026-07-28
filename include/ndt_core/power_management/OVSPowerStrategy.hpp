// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"

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
    virtual std::vector<std::string> executeListPorts(const std::string& br);

    /// Set by executeSystemCommand when a command exits non-zero, so powerOn/powerOff can
    /// report failure instead of asserting the switch changed state.
    /// [Co-developed with claude code -- Adam]
    bool m_lastCommandFailed = false;
};
