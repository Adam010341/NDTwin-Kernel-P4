// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <cstdlib>

void P4PowerStrategy::executeSystemCommand(const std::string& cmd)
{
    std::system(cmd.c_str());
}

bool P4PowerStrategy::powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor)
{
    if (!topoMonitor->getVertexIsUp(node))
    {
        topoMonitor->setVertexUp(node);
        SPDLOG_LOGGER_WARN(Logger::instance(), "P4 BMv2 Power ON from Kernel is currently a stub for {}.", swName);
        // Note: Fully restoring a BMv2 process with all its Mininet namespace parameters is complex
        // from outside the Mininet CLI.
    }
    return true;
}

bool P4PowerStrategy::powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor)
{
    if (topoMonitor->getVertexIsUp(node))
    {
        topoMonitor->setVertexDown(node);
        SPDLOG_LOGGER_INFO(Logger::instance(), "P4 BMv2 Power OFF for {}.", swName);
        
        // Kill the specific simple_switch_grpc process using its log file name as a marker,
        // or by executing pkill in the mininet host namespace.
        // Assuming swName is "s1", "s2", etc., the mininet node can be targeted via `mnexec`.
        std::string cmd = "sudo mnexec -a " + swName + " pkill -f simple_switch_grpc";
        executeSystemCommand(cmd);
    }
    return true;
}
