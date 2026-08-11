// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- Phase 7: real operations via the manifest helper.
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
    /// The shell seam, and the whole test surface: both power operations are command
    /// sequences, so a subclass that records commands instead of running them can assert
    /// what would have been executed. Returns whether the command exited 0 -- it was void
    /// once, which is how a failed power action reported success.
    virtual bool executeSystemCommand(const std::string& cmd);
};
