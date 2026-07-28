// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- stops claiming success it cannot deliver.
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <cstdlib>

void P4PowerStrategy::executeSystemCommand(const std::string& cmd)
{
    std::system(cmd.c_str());
}

// Both operations now refuse rather than pretend, and neither touches the twin's liveness
// state. Marking a vertex up or down for a switch whose process was never started or stopped
// makes the twin disagree with the network, which is worse than reporting that the operation
// is unavailable. Phase 7 of doc/p4_bmv2_support_plan.md implements this properly, via a
// manifest of switch name -> pid written by p4_testbed_topo.py as it launches each process.

OpResult
P4PowerStrategy::powerOn(Graph::vertex_descriptor node,
                         const std::string& swName,
                         uint64_t dpid,
                         TopologyAndFlowMonitor* topoMonitor)
{
    (void)node;
    (void)dpid;
    (void)topoMonitor;

    // Previously: marked the vertex up, logged "is currently a stub", and returned true.
    // So the twin reported a running switch that had never been started, and the caller was
    // told the operation had succeeded.
    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Refusing power-on for bmv2 switch {}: not implemented (Phase 7)",
                       swName);
    return OpResult::unsupported(
        "powering on a bmv2 switch is not implemented: restarting simple_switch_grpc "
        "requires the Mininet namespace parameters it was launched with, which the kernel "
        "does not have. Phase 7 adds a switch->pid/argv manifest written by the topology "
        "script. Start the switch from the Mininet CLI in the meantime.");
}

OpResult
P4PowerStrategy::powerOff(Graph::vertex_descriptor node,
                          const std::string& swName,
                          TopologyAndFlowMonitor* topoMonitor)
{
    (void)node;
    (void)topoMonitor;

    // Previously ran:
    //     sudo mnexec -a <swName> pkill -f simple_switch_grpc
    // which was wrong twice over. `mnexec -a` takes a PID, not a name, so atoi("s1") gave 0
    // and the command never ran -- a no-op purely by accident. And had it run, `pkill -f`
    // matches process-wide (Mininet nodes share the PID namespace), so it would have killed
    // all ten switches instead of one. That command is removed rather than left as a trap
    // for whoever "fixes" the mnexec invocation without noticing the second problem.
    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Refusing power-off for bmv2 switch {}: not implemented (Phase 7)",
                       swName);
    return OpResult::unsupported(
        "powering off a bmv2 switch is not implemented: the previous implementation could "
        "not target a single switch safely -- `pkill -f simple_switch_grpc` matches across "
        "the shared PID namespace and would stop every switch. Phase 7 adds a "
        "switch->pid manifest so one process can be stopped.");
}
