# src/ndt_core/power_management/CMakeLists.txt
add_library(NdtCore_PowerManagementLib STATIC
    DeviceConfigurationAndPowerManager.cpp
    OVSPowerStrategy.cpp
    P4PowerStrategy.cpp
)