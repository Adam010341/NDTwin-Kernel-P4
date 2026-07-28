// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- reports whether the commands actually worked.
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <cstdlib>
#include <iomanip>
#include <sstream>

void OVSPowerStrategy::executeSystemCommand(const std::string& cmd)
{
    // std::system returns the wait status; non-zero means the command failed. That was
    // previously discarded, so a failed ovs-vsctl looked exactly like a success.
    const int rc = std::system(cmd.c_str());
    if (rc != 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "command failed (status {}): {}", rc, cmd);
        m_lastCommandFailed = true;
    }
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

OpResult
OVSPowerStrategy::powerOn(Graph::vertex_descriptor node,
                          const std::string& swName,
                          uint64_t dpid,
                          TopologyAndFlowMonitor* topoMonitor)
{
    if (topoMonitor->getVertexIsUp(node))
    {
        // Already up: nothing to do, and reporting success is accurate.
        return OpResult::success();
    }

    m_lastCommandFailed = false;

    auto formatDpid = [](uint64_t d) -> std::string {
        std::ostringstream oss;
        oss << std::hex << std::setw(16) << std::setfill('0') << d;
        return oss.str();
    };

    // Bridge creation now goes through executeSystemCommand like everything else, so its
    // failure is observed. It previously called utils::execCommand directly, which also meant
    // a test subclass mocking executeSystemCommand still really ran `sudo ovs-vsctl add-br`
    // against the developer's machine -- the seam had a hole in it.
    executeSystemCommand("sudo ovs-vsctl add-br " + swName + " && sudo ovs-vsctl set bridge " +
                         swName + " other-config:datapath-id=" + formatDpid(dpid));

    auto ports = topoMonitor->getMininetBridgePorts(node);
    for (auto& port : ports)
    {
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ovs-vsctl add-port {} {}", swName, port);
        executeSystemCommand("sudo ovs-vsctl add-port " + swName + " " + port);
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ifconfig {} up", port);
        executeSystemCommand("sudo ifconfig " + port + " up");
    }
    executeSystemCommand("sudo ovs-vsctl set-controller " + swName + " tcp:127.0.0.1:6633");

    if (m_lastCommandFailed)
    {
        // Deliberately do not mark the vertex up: claiming a switch is running when the
        // commands to start it failed is exactly the twin/network disagreement this change
        // exists to prevent.
        return OpResult::failure(500,
                                 "one or more ovs-vsctl/ifconfig commands failed while "
                                 "bringing up " + swName + "; see the log for which");
    }

    topoMonitor->setVertexUp(node);
    return OpResult::success();
}

OpResult
OVSPowerStrategy::powerOff(Graph::vertex_descriptor node,
                           const std::string& swName,
                           TopologyAndFlowMonitor* topoMonitor)
{
    if (!topoMonitor->getVertexIsUp(node))
    {
        return OpResult::success();
    }

    m_lastCommandFailed = false;

    // Record the ports before the bridge goes away, so powerOn can restore them.
    auto ports = executeListPorts(swName);
    topoMonitor->setMininetBridgePorts(node, ports);
    for (auto& port : ports)
    {
        executeSystemCommand("sudo ifconfig " + port + " down");
    }
    executeSystemCommand("sudo ovs-vsctl del-br " + swName);

    if (m_lastCommandFailed)
    {
        return OpResult::failure(500,
                                 "one or more ifconfig/ovs-vsctl commands failed while "
                                 "shutting down " + swName + "; see the log for which");
    }

    topoMonitor->setVertexDown(node);
    return OpResult::success();
}
