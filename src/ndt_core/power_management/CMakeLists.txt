# src/ndt_core/power_management/CMakeLists.txt
add_library(NdtCore_PowerManagementLib STATIC
    DeviceConfigurationAndPowerManager.cpp
    OVSPowerStrategy.cpp
    P4PowerStrategy.cpp
    # [Co-developed with claude code -- Adam] Per-switch `capabilities` from GET /p4/switch_state,
    # onto /ndt/get_graph_data. Its own file so a mutation of it rebuilds one small object.
    P4Capabilities.cpp
)
