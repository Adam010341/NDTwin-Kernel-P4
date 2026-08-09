// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- reports whether the commands actually worked.
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <cstdlib>
#include <iomanip>
#include <sstream>

bool OVSPowerStrategy::executeSystemCommand(const std::string& cmd)
{
    // std::system returns the wait status; non-zero means the command failed. That was
    // previously discarded, so a failed ovs-vsctl looked exactly like a success.
    const int rc = std::system(cmd.c_str());
    if (rc != 0)
    {
        // Decoded rather than printed raw: std::system returns a wait status, so a command that
        // exited 1 -- which is what `add-br` on an existing bridge and a sudo password prompt both
        // do -- used to be logged as "status 256". [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "command failed ({}): {}",
                           utils::describeCommandStatus(rc, cmd),
                           cmd);
        return false;
    }
    return true;
}

std::optional<std::vector<std::string>> OVSPowerStrategy::executeListPorts(const std::string& br)
{
    std::vector<std::string> ports;
    std::string cmd = "sudo ovs-vsctl list-ports " + br;
    FILE* fp = popen(cmd.c_str(), "r");
    if (!fp)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "could not run: {}", cmd);
        return std::nullopt;
    }
    char buf[128];
    while (fgets(buf, sizeof(buf), fp))
    {
        std::string p(buf);
        p.erase(p.find_last_not_of(" \n\r\t") + 1);
        // A bridge with no ports prints nothing; guard anyway so a stray blank line cannot become
        // a port named "". [Co-developed with claude code -- Adam]
        if (!p.empty())
        {
            ports.push_back(p);
        }
    }

    // pclose's status was previously discarded, which is what made a failed query look like an
    // empty bridge. See the header for what that cost. [Co-developed with claude code -- Adam]
    const int rc = pclose(fp);
    if (rc != 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed ({}); treating the port list as unknown rather than empty",
                           cmd,
                           utils::describeCommandStatus(rc, cmd));
        return std::nullopt;
    }
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

    // Local, not a member: see executeSystemCommand's declaration for what sharing it across
    // concurrent power requests cost. [Co-developed with claude code -- Adam]
    bool allOk = true;
    auto run = [this, &allOk](const std::string& cmd) {
        // Deliberately not short-circuiting: every command still runs, so the log names all of
        // them rather than stopping at the first failure.
        if (!executeSystemCommand(cmd))
        {
            allOk = false;
        }
    };

    auto formatDpid = [](uint64_t d) -> std::string {
        std::ostringstream oss;
        oss << std::hex << std::setw(16) << std::setfill('0') << d;
        return oss.str();
    };

    // Bridge creation now goes through executeSystemCommand like everything else, so its
    // failure is observed. It previously called utils::execCommand directly, which also meant
    // a test subclass mocking executeSystemCommand still really ran `sudo ovs-vsctl add-br`
    // against the developer's machine -- the seam had a hole in it.
    run("sudo ovs-vsctl add-br " + swName + " && sudo ovs-vsctl set bridge " + swName +
        " other-config:datapath-id=" + formatDpid(dpid));

    auto ports = topoMonitor->getMininetBridgePorts(node);
    for (auto& port : ports)
    {
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ovs-vsctl add-port {} {}", swName, port);
        run("sudo ovs-vsctl add-port " + swName + " " + port);
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "sudo ifconfig {} up", port);
        run("sudo ifconfig " + port + " up");
    }
    run("sudo ovs-vsctl set-controller " + swName + " tcp:127.0.0.1:6633");

    if (!allOk)
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

    // Local, for the same reason as in powerOn. Powering one switch off must not be able to report
    // another switch's failure. [Co-developed with claude code -- Adam]
    bool allOk = true;
    auto run = [this, &allOk](const std::string& cmd) {
        if (!executeSystemCommand(cmd))
        {
            allOk = false;
        }
    };

    // Record the ports before the bridge goes away, so powerOn can restore them.
    //
    // Nothing is written to the graph and no bridge is deleted until we know what the ports are.
    // The previous order stored the query's result unconditionally and then ran del-br, so a failed
    // list-ports -- returned as an empty vector, indistinguishable from a bridge with no ports --
    // erased the saved list and destroyed the bridge that was the only other record of it. powerOn
    // would then create a bridge with no ports and mark the switch UP, so the twin reported a
    // healthy switch with no data plane, and no command had visibly failed.
    // [Co-developed with claude code -- Adam]
    const auto ports = executeListPorts(swName);
    if (!ports)
    {
        return OpResult::failure(500,
                                 "could not read the ports of " + swName +
                                     ", so it was left running: deleting the bridge would lose the "
                                     "only record of what to reattach on power-on");
    }

    topoMonitor->setMininetBridgePorts(node, *ports);
    for (const auto& port : *ports)
    {
        run("sudo ifconfig " + port + " down");
    }
    run("sudo ovs-vsctl del-br " + swName);

    if (!allOk)
    {
        return OpResult::failure(500,
                                 "one or more ifconfig/ovs-vsctl commands failed while "
                                 "shutting down " + swName + "; see the log for which");
    }

    topoMonitor->setVertexDown(node);
    return OpResult::success();
}
