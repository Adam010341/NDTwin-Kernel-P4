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

bool OVSPowerStrategy::executeArgvCommand(const std::vector<std::string>& argv)
{
    // [Co-developed with claude code -- Adam]
    // The argv twin of executeSystemCommand. See the header for why the sFlow restore uses it:
    // its values come out of the switch's own OVSDB rows, and B-2b's rule is that a value never
    // becomes shell code in the first place rather than being escaped into safety.
    const std::string rendered = utils::describeArgv(argv);
    const utils::CommandOutcome outcome = utils::execArgv(argv);
    if (!outcome.succeeded())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "command failed ({}): {}",
                           utils::describeCommandStatus(outcome.status, rendered),
                           rendered);
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

namespace
{
/**
 * @brief Runs a command and returns its stdout, or nothing if the command itself failed.
 *
 * [Co-developed with claude code -- Adam]
 * The exit status is checked before the output is looked at, deliberately. A `sudo -n` that is
 * refused writes its complaint to stderr, exits non-zero and leaves stdout completely empty --
 * so a caller that parses first cannot tell "the switch said no sFlow" from "the command never
 * ran". That is the eighth form in the memory file `injections-must-assert-their-own-success`:
 * an assertion that never executed looks exactly like one that executed and answered negative.
 */
std::optional<std::string>
captureArgv(const std::vector<std::string>& argv)
{
    // [Co-developed with claude code -- Adam]
    // Was popen(cmd) -- a second shell-execution site, which tests/python/
    // test_shell_command_construction.py counted and refused to leave unclassified. execArgv
    // captures the same stdout without ever building a command line. Its one visible difference:
    // the `ip` read used to end in 2>/dev/null, and execArgv leaves the child's stderr attached
    // to ours, so a failing read now says why in the log instead of vanishing. The exit status
    // is still what decides, and it is still checked before the output is looked at.
    const std::string rendered = utils::describeArgv(argv);
    const utils::CommandOutcome outcome = utils::execArgv(argv);
    if (!outcome.ran)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "could not run: {}", rendered);
        return std::nullopt;
    }
    const std::string out = outcome.output;
    const int rc = outcome.status;
    const std::string cmd = rendered;
    if (rc != 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed ({}); the answer is unknown, not empty",
                           cmd,
                           utils::describeCommandStatus(rc, cmd));
        return std::nullopt;
    }
    return out;
}

/// Trims whitespace and the `[`, `]` and `"` that OVSDB wraps set-typed values in.
std::string
unwrapOvsdbScalar(std::string s)
{
    const std::string junk = " \t\r\n[]\"";
    const auto first = s.find_first_not_of(junk);
    if (first == std::string::npos)
    {
        return "";
    }
    const auto last = s.find_last_not_of(junk);
    return s.substr(first, last - first + 1);
}

/// The `a.b.c.d/nn` in one `ip -4 -o addr show` line, or "" when the interface has no address.
std::string
firstInetCidr(const std::string& ipOutput)
{
    std::istringstream lines(ipOutput);
    std::string line;
    while (std::getline(lines, line))
    {
        std::istringstream words(line);
        std::string word;
        while (words >> word)
        {
            if (word == "inet")
            {
                std::string cidr;
                if (words >> cidr)
                {
                    return cidr;
                }
            }
        }
    }
    return "";
}
} // namespace

std::optional<SflowBridgeState>
OVSPowerStrategy::executeReadSflowState(const std::string& br)
{
    SflowBridgeState state;

    // --if-exists so that a bridge which is already gone answers empty rather than failing; a
    // *missing* bridge genuinely has no sFlow, which is different from not being able to ask.
    const auto rowRaw =
        captureArgv({"sudo", "ovs-vsctl", "--if-exists", "get", "bridge", br, "sflow"});
    if (!rowRaw)
    {
        return std::nullopt;
    }
    const std::string row = unwrapOvsdbScalar(*rowRaw);
    if (row.empty())
    {
        // The bridge has no sFlow record. Answered, and the answer is "none".
        return state; // configured == false
    }

    // One `get` with five columns rather than five calls: one exit status to check, and the
    // columns cannot come from two different reads of a row that changed in between.
    const auto fieldsRaw = captureArgv({"sudo", "ovs-vsctl", "get", "sflow", row, "agent",
                                        "targets", "header", "sampling", "polling"});
    if (!fieldsRaw)
    {
        return std::nullopt;
    }

    std::vector<std::string> values;
    std::istringstream fields(*fieldsRaw);
    std::string line;
    while (std::getline(fields, line))
    {
        values.push_back(unwrapOvsdbScalar(line));
    }
    if (values.size() < 5)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "sFlow row {} on {} answered {} of the 5 columns asked for; treating "
                           "the record as unreadable rather than guessing the rest",
                           row,
                           br,
                           values.size());
        return std::nullopt;
    }

    state.configured = true;
    state.agentIface = values[0];
    state.targets = values[1];
    state.header = values[2];
    state.sampling = values[3];
    state.polling = values[4];

    // The agent's address, which del-br takes as well. Read with `ip`, which needs no privilege,
    // so this half cannot be refused by a sudoers pattern.
    if (!state.agentIface.empty())
    {
        const auto addr =
            captureArgv({"ip", "-4", "-o", "addr", "show", "dev", state.agentIface});
        if (addr)
        {
            state.agentIpCidr = firstInetCidr(*addr);
        }
    }
    return state;
}

bool
OVSPowerStrategy::restoreSflow(const std::string& swName, const SflowBridgeState& saved)
{
    // The agent's address first: OVS resolves the agent interface to a source IP when the record
    // is created, and a record pointing at an address-less interface produces datagrams the
    // collector cannot attribute to any edge. Same shape as testbed_topo.py:194, and `ifconfig`
    // rather than `ip` to stay inside the argv shapes this file already uses.
    if (!saved.agentIpCidr.empty() && !saved.agentIface.empty())
    {
        executeArgvCommand({"sudo", "ifconfig", saved.agentIface, saved.agentIpCidr, "up"});
    }

    // Byte-for-byte the shape testbed_topo.py:118-137 uses, including the escaped quotes around
    // the target, so a bridge rebuilt here is configured identically to one built at bring-up.
    // The double quotes around the target are OVSDB's own string syntax and are meant to reach
    // ovs-vsctl -- they used to be written \\" so that /bin/sh would strip the backslash and pass
    // the quote through. With no shell in the path they are simply part of the argument.
    // [Co-developed with claude code -- Adam]
    executeArgvCommand({"sudo", "ovs-vsctl", "--", "--id=@sflow", "create", "sflow",
                        "agent=" + saved.agentIface,
                        "target=\"" + saved.targets + "\"",
                        "header=" + saved.header,
                        "sampling=" + saved.sampling,
                        "polling=" + saved.polling,
                        "--", "set", "bridge", swName, "sflow=@sflow"});

    // 🔑 The return value is the read-back, not the commands' exit statuses. An ovs-vsctl that
    // exits 0 says the transaction was accepted, not that this bridge now samples: the record
    // could be attached to nothing, or the agent could still have no address. This project has
    // twice shipped a change whose only evidence was an exit code and twice been wrong about it
    // (see memory injections-must-assert-their-own-success, forms 5 and 6), so the assertion
    // here reads the state back through the same seam that saved it.
    const auto after = executeReadSflowState(swName);
    if (!after)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "restored sFlow on {} but could not read it back, so whether it is "
                            "attached is unknown. Treating that as failure: an unverified "
                            "restore is what A-4f is made of",
                            swName);
        return false;
    }
    if (!after->configured)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "sFlow record for {} is still absent after the restore ran",
                            swName);
        return false;
    }
    if (after->agentIpCidr.empty())
    {
        // Structurally attached, but to an interface with no address. The datagrams would go out
        // (or not) with no usable agent IP and the collector could not key them to an edge, so
        // this is a restore that ran, succeeded, and landed where it cannot be seen.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "sFlow record for {} is attached, but its agent interface {} has no "
                            "IPv4 address, so samples cannot be attributed to any link",
                            swName,
                            after->agentIface);
        return false;
    }
    return true;
}

OpResult
OVSPowerStrategy::powerOn(Graph::vertex_descriptor node,
                          const std::string& swName,
                          uint64_t dpid,
                          TopologyAndFlowMonitor* topoMonitor)
{
    // [Co-developed with claude code -- Adam]
    // A-4f. Two questions, not one. The guard used to ask only whether the graph says up, and
    // that was sound while "up" and "delivered" meant the same thing. They stopped meaning the
    // same thing here: a power-on whose sFlow restore failed still marks the vertex up, because
    // the switch really is forwarding -- so on `getVertexIsUp` alone the operator's retry would
    // early-return success and never re-attempt the restore, and the link would stay dark for
    // ever. P4PowerStrategy.cpp:100-114 records that exact trap from a live fabric; the point of
    // reading it was not to walk into it.
    //
    // `restorePending` is false for every switch that was never powered off through here, so
    // outside the A-4f path this guard is unchanged.
    // [Co-developed with claude code -- Adam]
    // FINDINGS #46/#35. Three questions now, and the third is here rather than only in the P4
    // strategy because both early returns below would otherwise be traps: a switch carrying a
    // standing commanded power-off whose `isUp` some other writer has lifted would take one of
    // them, return success, and never reach the line that clears the flag -- leaving discovery
    // declining to mark a live bridge up for the rest of the run. Folding the question into
    // `alreadyUp` means the full bring-up path is the only way out for such a switch, and that
    // path is where the flag is cleared.
    const SflowBridgeState saved = topoMonitor->getBridgeSflowState(node);
    const bool alreadyUp =
        topoMonitor->getVertexIsUp(node) && !topoMonitor->getVertexAdminPoweredOff(node);
    if (alreadyUp && !saved.restorePending)
    {
        // Already up with nothing owed: nothing to do, and reporting success is accurate.
        return OpResult::success();
    }

    // [Co-developed with claude code -- Adam]
    // Up, but a telemetry restore is still owed: do only the part that is owed. Falling through
    // would re-run `add-br` on a bridge that already exists, which exits 1 -- verified against a
    // live ovs-vsctl, "a bridge named s1 already exists" -- and the `allOk` check below would
    // then return 500 *before* reaching the restore. The retry this whole flag exists to enable
    // would fail at step 1 for a reason that has nothing to do with why it was retried.
    //
    // Found by writing the retry test rather than by reading the code: the first version of this
    // change widened the guard, and the widened guard led straight into a bring-up that could
    // not run twice.
    if (alreadyUp)
    {
        return finishTelemetryRestore(node, swName, saved, topoMonitor);
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

    // [Co-developed with claude code -- Adam]
    // A-4f, the telemetry half. Runs after the ports are attached, because the record's agent is
    // the bridge's own internal port and there is nothing to address before `add-br` has made it.
    //
    // The switch is up either way: a bridge with no sFlow forwards packets perfectly well. That
    // is precisely what makes this defect silent, and it is also why the vertex is marked up
    // below even on the failure path -- claiming it is down would be a lie in the other
    // direction, and the 1 Hz liveness probe would overwrite it within a second regardless.
    // What must not happen is for the loss to go unsaid.

    // [Co-developed with claude code -- Adam]
    // FINDINGS #46. The commanded power-off is spent here, where `add-br`/`add-port`/`ifconfig
    // up`/`set-controller` have all just been observed to succeed -- the OVS equivalent of the
    // point where P4PowerStrategy closes its distrust window. Before finishTelemetryRestore, not
    // after, for the same reason it is before readopt over there: the telemetry restore has two
    // failure paths that leave a forwarding bridge behind, and a flag cleared only on the happy
    // path would leave discovery permanently refusing to mark a live switch up.
    topoMonitor->clearVertexAdminPowerOff(node);

    return finishTelemetryRestore(node, swName, saved, topoMonitor);
}

OpResult
OVSPowerStrategy::finishTelemetryRestore(Graph::vertex_descriptor node,
                                         const std::string& swName,
                                         const SflowBridgeState& saved,
                                         TopologyAndFlowMonitor* topoMonitor)
{
    if (saved.restorePending)
    {
        SflowBridgeState now = saved;

        if (saved.unknown)
        {
            // powerOff could not read the record before deleting the bridge, so there is nothing
            // to replay. Say so; do not invent a configuration.
            topoMonitor->setVertexUp(node);
            return OpResult::failure(
                502,
                swName + " is forwarding again, but its sFlow configuration could not be read "
                         "before the power-off and therefore could not be restored. Every link "
                         "entering it will read exactly 0 bps whatever it carries, which is "
                         "indistinguishable from idle (KNOWN-ISSUES A-4f). Restore it by hand "
                         "with the ovs-vsctl in testbed_topo.py's enable_sflow(), or rebuild the "
                         "fabric -- and do not report telemetry for this switch until you have.");
        }

        if (!saved.configured)
        {
            // The bridge genuinely had no sFlow before. Recreating one would be inventing a
            // configuration the fabric never had; nothing is owed.
            now.restorePending = false;
            topoMonitor->setBridgeSflowState(node, now);
        }
        else if (restoreSflow(swName, saved))
        {
            now.restorePending = false;
            topoMonitor->setBridgeSflowState(node, now);
        }
        else
        {
            // Left pending on purpose, so a retried power-on retries the restore rather than
            // taking the early return at the top of this function.
            topoMonitor->setVertexUp(node);
            return OpResult::failure(
                502,
                swName + " is forwarding again, but its sFlow record could not be restored and "
                         "verified. Every link entering it now reads exactly 0 bps whatever it "
                         "carries, and nothing downstream can tell that from an idle link "
                         "(KNOWN-ISSUES A-4f). The reason is in the log line above. Retrying "
                         "this power-on WILL re-attempt the restore -- that is what the "
                         "restorePending flag is for -- and `sudo ovs-vsctl list sflow` says "
                         "whether it took.");
        }
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

    // [Co-developed with claude code -- Adam]
    // A-4f. The sFlow record is read here, in the same window and for the same reason as the
    // ports: `del-br` below destroys the Bridge row, the sFlow table is not an OVSDB root table,
    // and an unreferenced sFlow row is garbage-collected. After that line the bridge is the only
    // record of it and the bridge is gone.
    //
    // A failed read does NOT refuse the power-off, and that asymmetry with the port list above is
    // deliberate. Losing the ports costs the switch its data plane permanently; losing the sFlow
    // record costs telemetry, which this change is about making visible rather than about making
    // fatal. The practical half matters more: `sudo -n` allowlists are argv-pattern scoped (see
    // the header on executeReadSflowState), so `get bridge` may well be refused on a machine
    // where `list-ports` is permitted -- and a refusal that blocked every power-off would replace
    // a quiet telemetry defect with a loud power-management outage. So it is recorded as
    // `unknown` and powerOn reports it.
    SflowBridgeState sflow;
    if (const auto readBack = executeReadSflowState(swName))
    {
        sflow = *readBack;
    }
    else
    {
        sflow.unknown = true;
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "could not read the sFlow configuration of {} before deleting its "
                            "bridge. The power-off continues, but power-on will have nothing to "
                            "restore and that switch's links will read 0 bps for ever (A-4f)",
                            swName);
    }
    // Pending unless the bridge genuinely had no record to lose. `unknown` counts as pending
    // precisely because we cannot rule out that there was one.
    sflow.restorePending = sflow.unknown || sflow.configured;
    topoMonitor->setBridgeSflowState(node, sflow);

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

    // [Co-developed with claude code -- Adam]
    // FINDINGS #46, the OVS half. The defect is in TopologyAndFlowMonitor::updateSwitches, which
    // is plane-agnostic: it applies the same reply shape whether the switches behind it are bmv2
    // or OVS bridges, and it lifted `isUp` for both. Live evidence was taken on the P4 fabric, so
    // the OVS numbers are unmeasured -- but a deleted bridge that Ryu is slow to stop announcing
    // is the same race with a different clock, and leaving this call as the observation writer
    // would have made the fix hold on the plane that was measured and not on the default one.
    // See setVertexPoweredOffByCommand.
    topoMonitor->setVertexPoweredOffByCommand(node);
    return OpResult::success();
}
