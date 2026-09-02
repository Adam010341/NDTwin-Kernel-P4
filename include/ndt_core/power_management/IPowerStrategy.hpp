// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- OpResult returns.
#pragma once

#include "common_types/GraphTypes.hpp"
#include "ndt_core/routing_management/OpResult.hpp"
#include <string>
#include <vector>

class TopologyAndFlowMonitor;

/**
 * @brief Interface for device power and configuration management strategies.
 *
 * Returns OpResult rather than bool. The bool was decoration: both implementations returned
 * true unconditionally -- including a powerOn that did nothing at all -- and the only caller
 * discarded it and logged success regardless. A switch that was never started was therefore
 * reported as powered on, which in a digital twin, whose whole job is to reflect the real
 * network, is the worst available failure mode.
 */
class IPowerStrategy
{
public:
    virtual ~IPowerStrategy() = default;

    /**
     * @brief Power on a switch.
     * @param node The graph vertex descriptor of the switch
     * @param swName The mininet bridge name (e.g. "s1")
     * @param dpid The DPID of the switch
     * @param topoMonitor Topology monitor, used to read and update liveness
     * @return ok when the switch was actually started, otherwise a failure describing why
     *         not. An implementation that cannot start a switch must not mark the twin's
     *         state as up.
     *
     * [Co-developed with claude code -- Adam]
     * There is a third outcome, and it was missing here. A switch can come back forwarding
     * traffic and still not be *usable by the twin*: OVSPowerStrategy rebuilds the bridge but
     * the sFlow record went with the old one (KNOWN-ISSUES A-4f), and P4PowerStrategy restarts
     * bmv2 but the proxy may fail to re-adopt it. Those two differ in one way that decides what
     * the vertex flag should say: the P4 switch has no pipeline and cannot forward a packet, so
     * it is not up; the OVS switch forwards perfectly and only cannot be measured, so it IS up
     * and saying otherwise would be a lie in the opposite direction.
     *
     * So: mark up if and only if the switch is really carrying traffic, and return a failure
     * whenever the twin did not get back everything it needs. Those two are allowed to disagree,
     * and an implementation that takes that path must leave itself a way to retry -- a caller
     * repeating the request must not hit an "already up" early return that skips the part that
     * failed.
     */
    virtual OpResult powerOn(Graph::vertex_descriptor node,
                             const std::string& swName,
                             uint64_t dpid,
                             TopologyAndFlowMonitor* topoMonitor) = 0;

    /**
     * @brief Power off a switch.
     * @param node The graph vertex descriptor of the switch
     * @param swName The mininet bridge name (e.g. "s1")
     * @param topoMonitor Topology monitor, used to read and update liveness
     * @return ok when the switch was actually stopped, otherwise a failure describing why not.
     */
    virtual OpResult powerOff(Graph::vertex_descriptor node,
                              const std::string& swName,
                              TopologyAndFlowMonitor* topoMonitor) = 0;

    /// Name of the data plane this strategy controls, for log and error messages.
    virtual const char* describe() const = 0;
};
