// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- collapsed onto HttpRoutingStrategyBase.
#pragma once

#include "ndt_core/routing_management/HttpRoutingStrategyBase.hpp"
#include <string>

/**
 * @brief OpenFlow specific routing strategy (Ryu Controller).
 *
 * Sends Ryu REST requests. Everything is inherited: this is the reference implementation of
 * the shape HttpRoutingStrategyBase encodes, so nothing remains to override beyond naming
 * itself for log messages.
 */
class OpenFlowRoutingStrategy : public HttpRoutingStrategyBase
{
  public:
    explicit OpenFlowRoutingStrategy(const std::string& apiUrl)
        : HttpRoutingStrategyBase(apiUrl)
    {
    }

    const char* describe() const override { return "Ryu controller"; }
};
