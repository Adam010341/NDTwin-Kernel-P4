// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <sstream>
#include <iomanip>
#include <cstdlib>

void OVSPowerStrategy::executeSystemCommand(const std::string& cmd)
{
    std::system(cmd.c_str());
}

std::vector<std::string> OVSPowerStrategy::executeListPorts(const std::string& br)
{
    std::vector<std::string> ports;
    std::string cmd = "sudo ovs-vsctl list-ports " + br;
    FILE* fp = popen(cmd.c_str(), "r");
    if (!fp)
    {
        return ports;
    }
    char buf[128];
    while (fgets(buf, sizeof(buf), fp))
    {
        std::string p(buf);
        p.erase(p.find_last_not_of(" \n\r\t") + 1);
        ports.push_back(p);
    }
    pclose(fp);
    return ports;
}

bool OVSPowerStrategy::powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor)
{
    if (!topoMonitor->getVertexIsUp(node))
    {
        topoMonitor->setVertexUp(node);

        auto formatDpid = [&](uint64_t dpid) -> std::string {
            std::ostringstream oss;
            oss << std::hex << std::setw(16) << std::setfill('0') << dpid;
            return oss.str();
        };

        std::string cmd = "sudo ovs-vsctl add-br " + swName + " && sudo ovs-vsctl set bridge " +
                          swName + " other-config:datapath-id=" + formatDpid(dpid);
        utils::execCommand(cmd);

        auto ports = topoMonitor->getMininetBridgePorts(node);
        for (auto& port : ports)
        {
            SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ovs-vsctl add-port {} {}", swName, port);
            executeSystemCommand("sudo ovs-vsctl add-port " + swName + " " + port);
            SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ifconfig {} up", port);
            executeSystemCommand("sudo ifconfig " + port + " up");
        }
        executeSystemCommand("sudo ovs-vsctl set-controller " + swName + " tcp:127.0.0.1:6633");
    }
    return true;
}

bool OVSPowerStrategy::powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor)
{
    if (topoMonitor->getVertexIsUp(node))
    {
        topoMonitor->setVertexDown(node);

        auto ports = executeListPorts(swName);
        topoMonitor->setMininetBridgePorts(node, ports);
        for (auto& port : ports)
        {
            executeSystemCommand("sudo ifconfig " + port + " down");
        }
        executeSystemCommand("sudo ovs-vsctl del-br " + swName);
    }
    return true;
}
