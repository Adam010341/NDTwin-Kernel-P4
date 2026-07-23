// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"

class OVSPowerStrategy : public IPowerStrategy
{
public:
    OVSPowerStrategy() = default;
    virtual ~OVSPowerStrategy() = default;

    bool powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    bool powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;
    
protected:
    virtual void executeSystemCommand(const std::string& cmd);
    virtual std::vector<std::string> executeListPorts(const std::string& br);
};
