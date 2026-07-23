// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "common_types/GraphTypes.hpp"
#include <string>
#include <vector>

class TopologyAndFlowMonitor;

/**
 * @brief Interface for device power and configuration management strategies.
 */
class IPowerStrategy
{
public:
    virtual ~IPowerStrategy() = default;

    /**
     * @brief Power on a switch
     * @param node The graph vertex descriptor of the switch
     * @param swName The mininet bridge name (e.g. "s1")
     * @param dpid The DPID of the switch
     * @param topoMonitor Pointer to the topology monitor
     * @return true if successful, false otherwise
     */
    virtual bool powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) = 0;

    /**
     * @brief Power off a switch
     * @param node The graph vertex descriptor of the switch
     * @param swName The mininet bridge name (e.g. "s1")
     * @param topoMonitor Pointer to the topology monitor
     * @return true if successful, false otherwise
     */
    virtual bool powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) = 0;
};
