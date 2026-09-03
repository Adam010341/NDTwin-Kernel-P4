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
    // [Co-developed with claude code -- Adam]
    // This used to be `if (topoMonitor->getVertexIsUp(node))` alone, under the comment "Already
    // up: nothing to do, and reporting success is accurate." Accurate only while the vertex is
    // telling the truth, and there is one interval in which it reliably is not: the seconds after
    // this strategy's own powerOff.
    //
    // What happens in that interval. powerOff marks the vertex down. Within one tick the 1 Hz
    // pingWorker asks p4LivenessFor, which reads the proxy's still-cached `probe_ok: true` and
    // answers Up, so the worker calls setVertexUp -- on a switch it has already been told is
    // dead, and which is dead. From then until the last LLDP beacon ages past kLldpFreshSeconds
    // the verdict is Unknown, which the worker deliberately does not write, so the wrong Up
    // stands unchallenged. A power-on arriving in that interval took the branch below and
    // returned 200 "Success" in 0.01s having run no command: measured (scratch/phase2/FINDINGS.md
    // E2) the bmv2 process count did not move, no readopt was sent, the switch stayed dead, and
    // the twin reported power=ON, is_up=True, 8/8 edges up against 100% packet loss. The same
    // POST replayed after the graph settled to is_up=false took 1.27s, moved the process count
    // 9 -> 10 and restored forwarding, which is what proves the first call had simply not acted.
    //
    // The file's own comment predicted this would bite a *retry*. It bites the first call: a
    // person demonstrating "switch it off, now switch it back on" takes a few seconds, and every
    // few-second gap lands inside the window.
    //
    // So the guard asks two questions instead of one -- does the graph say up, and is the graph
    // entitled to an opinion about this switch yet. Outside the window the answer to the second
    // is always yes and nothing changes: an already-up switch is still a no-op success that runs
    // no commands, which is what keeps the Energy-Saving-App's repeated desired-state requests
    // from turning into helper "already running" failures.
    //
    // [Co-developed with claude code -- Adam]
    // FINDINGS #35/#36, the residual the distrust window did not reach. The window is bounded by
    // TIME (15 s), and the measurement that made it necessary is not: with #46 in place a
    // commanded-off switch keeps `isUp = false`, so this guard already stops firing for it -- but
    // only while nothing else writes up. The third question closes the gap that is left, and
    // states the rule the other two only imply: a no-op success is honest exactly when nothing
    // the twin knows contradicts "it is already on". A standing commanded power-off contradicts
    // it. Measured before this fix: past the 15 s window, 4 of 4 power-ons returned Success in
    // ~1 ms having run no command, on a switch whose process was gone.
    //
    // The cost is named rather than hidden: a switch restarted OUT OF BAND (helper invoked by
    // hand, not through this API) still carries the off command, so the next power-on actuates
    // and the helper refuses to start a second instance -- a 500 that names the wrong step. That
    // is a loud wrong answer replacing a silent one, which is the right direction, and it is
    // written up in FIX-POLL-RESURRECT.md §6.
    if (topoMonitor->getVertexIsUp(node) && !topoMonitor->getVertexAdminPoweredOff(node) &&
        !poweredOffWithinDistrustWindow(swName))
    {
        // Already up, on evidence that is allowed to count: nothing to do, and reporting success
        // is accurate.
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

    // [Co-developed with claude code -- Adam]
    // The window closes here, not at the end of this function, and the difference is load-bearing.
    // The window's only question is "is the process I killed still gone", and the helper exiting 0
    // has just answered it: a bmv2 is serving that gRPC port again, so the graph's `isUp` is once
    // more backed by something real. Clearing it later -- after readopt -- would leave the window
    // open across the 502 path, and the next power-on would then re-run the helper against a live
    // process and get "refusing to start a second instance", turning a switch that needs a readopt
    // into a 500 that names the wrong problem. The pipeline-less half-state is what step 2's
    // failure and its named recovery are for; it is not a power-state question.
    clearPowerOffRecord(swName);

    // [Co-developed with claude code -- Adam]
    // FINDINGS #46. The commanded power-off is spent at exactly the same instant and for exactly
    // the reason spelled out above: a bmv2 is serving that gRPC port again, so discovery's word
    // about this switch is worth having again. Cleared HERE and not after readopt, because the
    // 502 path below leaves a running process the twin must still be able to learn about -- and
    // its named recovery (POST the readopt endpoint directly) never comes back through this
    // function, so a flag cleared later would never be cleared at all and every subsequent poll
    // would go on declining to mark a live switch up.
    topoMonitor->clearVertexAdminPowerOff(node);

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
    // [Co-developed with claude code -- Adam]
    // FINDINGS #35, the power-off direction. This began as
    //
    //     if (!topoMonitor->getVertexIsUp(node)) { return OpResult::success(); }
    //
    // -- "already down, nothing to do". It asked the graph, and the graph is a cache of somebody
    // else's opinion about this switch. The opinion is wrong in this exact direction on a
    // schedule: the 1 Hz liveness worker writes `isUp = false` the moment the proxy's probe stops
    // answering, which happens for a switch that is briefly unreachable, mid-restart, or whose
    // proxy channel is in reconnect backoff -- all states a real bmv2 process lives through while
    // still running and still forwarding. A power-off arriving then returned 200 "Success" having
    // sent no signal to anything, and the caller had no way to tell that from a kill.
    //
    // There is no early return any more, because there does not need to be one: the guard's only
    // job was idempotence, and the helper already provides it FROM A MEASUREMENT. `off` reads the
    // manifest PID, checks /proc, and prints {"status":"already-stopped"} with exit 0 when the
    // process is gone -- re-verifying the pid is still that switch before it signals anything, so
    // a recycled pid is not killed. The cost of dropping the guard is one sudo+exec per redundant
    // request (the Energy-Saving-App re-sends desired state); the benefit is that "Success" now
    // means /proc was consulted rather than that the graph agreed with us.
    //
    // What must NOT be done here is asking the graph a *different* question -- `adminPoweredOff`
    // instead of `isUp` -- and returning early on that. It is the same class of answer: a record
    // of what we last decided, not a look at the machine.

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

    // [Co-developed with claude code -- Adam]
    // Recorded before the graph write, so the window can never begin later than the kill it
    // describes, and recorded only here -- on the path where the helper confirmed the process is
    // gone. A powerOff that failed left the switch running, so there is nothing to distrust.
    notePowerOff(swName);

    // [Co-developed with claude code -- Adam]
    // FINDINGS #46. setVertexDown, which this was, is the OBSERVATION writer -- the same call the
    // 1 Hz liveness worker makes -- so the graph could not tell "the twin killed this" from "the
    // probe missed a beat", and the next topology poll lifted `isUp` straight back and never
    // wrote false again. This records the same down *and* the fact that it was commanded, which
    // is what updateSwitches now refuses to overrule.
    topoMonitor->setVertexPoweredOffByCommand(node);
    return OpResult::success();
}

/** @brief The default clock. Overridden only by tests. */
std::chrono::steady_clock::time_point
P4PowerStrategy::now() const
{
    return std::chrono::steady_clock::now();
}

/** @brief Whether this strategy stopped @p swName recently enough that the graph cannot yet be
 *         believed about it. See kPostPowerOffDistrustWindow for where the bound comes from.
 *
 * [Co-developed with claude code -- Adam]
 */
bool
P4PowerStrategy::poweredOffWithinDistrustWindow(const std::string& swName) const
{
    // Read the clock before taking the lock: now() is virtual, and nothing that overrides it
    // should have to know what this function holds.
    const std::chrono::steady_clock::time_point at = now();

    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    const auto it = m_lastPowerOffAt.find(swName);
    if (it == m_lastPowerOffAt.end())
    {
        return false;
    }
    return at - it->second < kPostPowerOffDistrustWindow;
}

/** @brief Opens the distrust window for @p swName.
 *
 * [Co-developed with claude code -- Adam]
 */
void
P4PowerStrategy::notePowerOff(const std::string& swName)
{
    const std::chrono::steady_clock::time_point at = now();

    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    m_lastPowerOffAt[swName] = at;
}

/** @brief Closes it. Erases rather than expires: an absent key is the same answer as an old one,
 *         and this keeps the map the size of the switches that are currently mid-cycle.
 *
 * [Co-developed with claude code -- Adam]
 */
void
P4PowerStrategy::clearPowerOffRecord(const std::string& swName)
{
    const std::lock_guard<std::mutex> guard(m_lastPowerOffMutex);
    m_lastPowerOffAt.erase(swName);
}
