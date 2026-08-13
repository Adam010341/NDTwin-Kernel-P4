// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- Phase 7: real power operations via the manifest
// helper and the proxy's readopt endpoint. Design: doc/2026-08-11_phase7_power_mechanism_design.md.
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <cstdlib>

namespace
{
// The privileged half. It lives outside the repo on purpose: sudoers pins this exact
// root-owned path, because NOPASSWD on a user-writable file is root for whoever can edit
// the file. Install steps are in the design doc; tools/p4_power_helper.py is the source.
//
// The helper addresses processes only by manifest PID, re-verified against /proc before any
// signal. Never by name: the pre-Phase-7 implementation's `pkill -f simple_switch_grpc`
// would have stopped all ten switches at once (Mininet nodes share the root PID namespace),
// and was removed rather than fixed so nobody could "repair" its mnexec invocation without
// noticing that second problem. No command built here may ever contain pkill.
constexpr const char* kPowerHelper = "/usr/local/sbin/ndtwin-p4-power";
} // namespace

bool P4PowerStrategy::executeSystemCommand(const std::string& cmd)
{
    // Same honesty as OVSPowerStrategy's seam: std::system returns the wait status, and
    // discarding it is how a failed power action used to look identical to a success.
    const int rc = std::system(cmd.c_str());
    if (rc != 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "command failed ({}): {}",
                           utils::describeCommandStatus(rc, cmd),
                           cmd);
        return false;
    }
    return true;
}

OpResult
P4PowerStrategy::powerOn(Graph::vertex_descriptor node,
                         const std::string& swName,
                         uint64_t dpid,
                         TopologyAndFlowMonitor* topoMonitor)
{
    if (topoMonitor->getVertexIsUp(node))
    {
        // Already up: nothing to do, and reporting success is accurate.
        return OpResult::success();
    }

    // Step 1, the process. The helper owns the manifest (name -> pid/argv, written by
    // p4_testbed_topo.py) and exits 0 only once the relaunched bmv2 is accepting connections
    // on its gRPC port.
    if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " on " + swName))
    {
        return OpResult::failure(500,
                                 "ndtwin-p4-power could not start " + swName +
                                     "; the switch was not brought up. See the kernel log for "
                                     "the helper's reason (stale manifest, occupied port, or "
                                     "the helper is not installed -- the design doc has the "
                                     "install steps).");
    }

    // Step 2, the relationship. A restarted bmv2 comes back with no pipeline, no clone
    // session, no table entries and no P4Runtime mastership, and the liveness probe cannot
    // tell: it is a unary RPC on a channel gRPC reconnects on its own, answered without any
    // pipeline loaded. Without this step the twin would certify Up a switch that cannot
    // forward one packet.
    //
    // [Co-developed with claude code -- Adam]
    // `--fail-with-body`, not `-f`. Both turn a non-2xx into exit 22, which is what lets this
    // one seam observe both steps -- but plain `-f` *discards the response body*, and the
    // readopt endpoint's whole 502 contract is that it names the step that broke
    // (mastership/pipeline/clone/routes). This comment used to claim "the response body lands
    // in the kernel log" while `-f` was guaranteeing it did not. Measured on a live fabric
    // (2026-08-12): the kernel log held only `curl: (22) ... error: 502`, and the actual
    // `step: "pipeline"` had to be recovered by re-running the endpoint by hand without `-f`.
    // A caller's flag silently cancelled a diagnostic the other process had gone to the
    // trouble of producing. Needs curl >= 7.76; an older curl rejects the option and the
    // power-on fails loudly rather than lying, which is the right way round.
    if (!executeSystemCommand("curl -sS --fail-with-body -X POST --max-time 30 http://" +
                              AppConfig::P4_PROXY_IP_AND_PORT + "/p4/readopt/" +
                              std::to_string(dpid)))
    {
        // Not marked up: powerOn did not deliver a usable switch. Said plainly because the
        // state is awkward -- the process *is* running, and the 1 Hz probe will report it Up
        // even though it has no pipeline (the known residual in the design doc). The honest
        // signal that remains is this failure and the proxy's log.
        //
        // [Co-developed with claude code -- Adam]
        // Two corrections live here, and the second was found by running the first.
        //
        // The message once ended "retrying this power-on retries the readopt." It does not:
        // helper-on succeeded, so bmv2 is serving, so p4LivenessFor answers Up on probe_ok
        // alone and the 1 Hz pingWorker calls setVertexUp within a second. A retry then hits
        // the `getVertexIsUp` early-return at the top of this function and reports success
        // without touching the readopt -- or, if it beats the probe, the helper refuses to
        // start a second instance and the failure names the wrong step. That much still holds.
        //
        // The replacement -- "power off and then power on" -- was never run against a live
        // fabric, and when it finally was (2026-08-12) it returned 500 too. So the first fix
        // removed advice that could not work and substituted advice that also did not, which
        // is the same defect wearing different clothes. What actually recovered the switch was
        // calling the proxy's readopt endpoint directly, which is the one request that
        // re-attempts the adoption without passing through any of the early-returns above.
        //
        // Why off-then-on fails: powering off leaves the proxy's liveness prober hammering the
        // dead port every 2s, and grpc-python's process-global subchannel pool hands that
        // address's accumulated reconnect backoff to the next channel built for it -- including
        // the fresh one readopt creates. Measured offline on grpc 1.82.1: after 90s of failed
        // connects, a default channel took 32.56s to reach READY against a listening port while
        // one built with grpc.use_local_subchannel_pool reached it in 0.00s. Retrying readopt
        // works because the backoff decays; off-then-on does not because it adds to it.
        return OpResult::failure(502,
                                 "bmv2 for " + swName + " is running again, but the proxy "
                                     "could not re-adopt it (mastership/pipeline/clone/"
                                     "routes); it cannot forward traffic. The failing step is "
                                     "in the readopt response body in the kernel log above. "
                                     "Recover by retrying the readopt directly: POST http://" +
                                     AppConfig::P4_PROXY_IP_AND_PORT + "/p4/readopt/" +
                                     std::to_string(dpid) +
                                     " -- it is the only call that re-attempts the adoption, "
                                     "and it may need several tries. Do NOT repeat this "
                                     "power-on: the process is up, so liveness marks the switch "
                                     "up within a second and the retry returns success without "
                                     "re-attempting the readopt. Power off then power on does "
                                     "not work either; measured on a live fabric, it returned "
                                     "500 as well.");
    }

    topoMonitor->setVertexUp(node);
    return OpResult::success();
}

OpResult
P4PowerStrategy::powerOff(Graph::vertex_descriptor node,
                          const std::string& swName,
                          TopologyAndFlowMonitor* topoMonitor)
{
    if (!topoMonitor->getVertexIsUp(node))
    {
        return OpResult::success();
    }

    // The helper SIGTERMs the one PID the manifest names for this switch -- after
    // re-verifying the PID still is that switch -- and exits 0 only once the process is
    // gone. Everything the twin then observes follows honestly: the stream dies with the
    // process, the probe starts failing, and the watchdog reroutes around the switch, which
    // is exactly the plan's acceptance criterion ("the other nine keep forwarding").
    if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " off " + swName))
    {
        // Left running is left up: marking the vertex down over a failed kill would be the
        // twin disagreeing with the network, in the direction that hides a live switch.
        return OpResult::failure(500,
                                 "ndtwin-p4-power could not stop " + swName +
                                     "; it was left running and the twin still reports it "
                                     "up. See the kernel log for the helper's reason.");
    }

    topoMonitor->setVertexDown(node);
    return OpResult::success();
}
