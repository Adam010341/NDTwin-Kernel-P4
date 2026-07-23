# src/ndt_core/routing_management/CMakeLists.txt
add_library(NdtCore_RoutingManagementLib STATIC
    FlowRoutingManager.cpp
    Controller.cpp
    FlowDispatcher.cpp
    OpenFlowRoutingStrategy.cpp
    P4RoutingStrategy.cpp
)