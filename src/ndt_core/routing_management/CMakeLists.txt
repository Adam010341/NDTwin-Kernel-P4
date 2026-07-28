# src/ndt_core/routing_management/CMakeLists.txt
add_library(NdtCore_RoutingManagementLib STATIC
    FlowRoutingManager.cpp
    Controller.cpp
    FlowDispatcher.cpp
    # [Co-developed with claude code -- Adam]
    # OpenFlowRoutingStrategy.cpp is gone: the class inherits everything from
    # HttpRoutingStrategyBase and has no out-of-line definitions left.
    HttpRoutingStrategyBase.cpp
    P4RoutingStrategy.cpp
)
