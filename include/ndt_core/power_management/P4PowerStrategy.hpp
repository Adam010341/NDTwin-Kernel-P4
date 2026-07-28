// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"

class P4PowerStrategy : public IPowerStrategy
{
public:
    P4PowerStrategy() = default;
    virtual ~P4PowerStrategy() = default;

    OpResult powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    OpResult powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;
    
    const char* describe() const override { return "P4/bmv2"; }

protected:
    virtual void executeSystemCommand(const std::string& cmd);
};
