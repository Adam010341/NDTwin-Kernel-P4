# tests/CMakeLists.txt
add_executable(
  test_routing_strategy
  test_LoggerEnvironment.cpp
  test_RoutingStrategies.cpp
  test_EstimatedRates.cpp
  test_RateDenominator.cpp
  test_FlowPathRecomputeInterval.cpp
  test_SwitchKindDispatch.cpp
  test_SFlowParsing.cpp
  test_GoldenFixture.cpp
  test_SFlowEmitterRoundtrip.cpp
  test_ClassifierDropRule.cpp
  test_EventBus.cpp
  test_P4FlowStatsToClassifier.cpp
  test_OvsLiveness.cpp
  test_SyntheticPower.cpp
  test_KeyedFailureLog.cpp
  test_IpToString.cpp
  test_FlowDispatcher.cpp
  test_Controller.cpp
  test_ParamParsing.cpp
  test_SimulationRequestValidation.cpp
  test_OvsPowerStrategy.cpp
  test_P4PowerStrategy.cpp
  test_P4Liveness.cpp
  test_RelayResponse.cpp
  test_RequestDeadlines.cpp
  test_FlowTableCacheOptionalFields.cpp
  test_ReverseEdgeLookup.cpp
  test_LastHopAttribution.cpp
  test_AllDestinationPaths.cpp
  test_HttpSessionRouting.cpp
  test_LLMResponseParsing.cpp
  test_LockManager.cpp
  test_ClassifierActionForms.cpp
  test_FlowStatsTimeout.cpp
  test_FlowTableConcurrency.cpp
  test_FlowBatchPartition.cpp
  test_TopologyAndFlowMonitor.cpp
  test_TopologyAndFlowMonitor_mininet.cpp
  test_AdministrativeDisable.cpp
  test_AdminDisableConsumers.cpp
  test_ApiKeyNotLogged.cpp
  test_IntentTaskOutcomes.cpp
  test_HttpSessionStatusCodes.cpp
  test_HistoricalLogging.cpp
  test_CommandFailure.cpp
  test_TopologyUrlAndPathJson.cpp
  test_SmartPlugFields.cpp
  test_PathNodeParsing.cpp
  test_ApplicationManager.cpp
)
# [Co-developed with claude code -- Adam]
# NdtCore_RoutingManagementLib declares no target_link_libraries of its own, so there
# is no transitive closure here. FlowRoutingManager.o pulls in TopologyAndFlowMonitor,
# EventBus and FlowLinkUsageCollector; list them explicitly so tests that touch the
# strategy dispatch logic link.
target_link_libraries(
  test_routing_strategy
  GTest::gtest_main
  NdtCore_RoutingManagementLib
  NdtCore_CollectionLib
  NdtCore_PowerManagementLib
  NdtCore_ApplicationLib
  # [Co-developed with claude code -- Adam]
  # Added for test_HttpSessionRouting. NdtCore_HttpLib declares Utils/EventSystem/Collection/
  # EventHandling but not the managers HttpSession's handlers call into, so the rest are listed
  # here: IntentTranslator, DataManagement and EventHandling complete the closure.
  NdtCore_HttpLib
  NdtCore_IntentTranslatorLib
  NdtCore_DataManagementLib
  NdtCore_EventHandlingLib
  EventSystemLib
  UtilsLib
  ssh
  OpenSSL::Crypto
  OpenSSL::SSL
  Boost::system
  Boost::url
)

include(GoogleTest)
gtest_discover_tests(test_routing_strategy)

# [Co-developed with claude code -- Adam]
# libFuzzer harnesses. Off by default and clang-only: libFuzzer ships with clang, so this needs
# no install, but it cannot build under GCC. Kept out of the default build because a fuzz target
# is not a test -- it is a campaign you run deliberately, and its findings become regression
# cases in test_SFlowParsing.cpp.
#
#   cmake -S . -B build-fuzz -DFUZZING=ON -DCMAKE_CXX_COMPILER=clang++ \
#         -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations
#   cmake --build build-fuzz -j"$(nproc)"
#   ./build-fuzz/bin/fuzz_sflow tests/fixtures -max_total_time=60
option(FUZZING "Build the libFuzzer harnesses (clang only)" OFF)
if(FUZZING)
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "FUZZING=ON requires clang; libFuzzer ships with it and not with GCC")
  endif()
  add_executable(fuzz_sflow fuzz/fuzz_sflow.cpp)
  # On the target rather than the directory: the top-level CMakeLists clears directory
  # COMPILE_OPTIONS around FetchContent, which is how sanitizer flags have been lost before.
  target_compile_options(fuzz_sflow PRIVATE -fsanitize=fuzzer,address -g -O1)
  target_link_options(fuzz_sflow PRIVATE -fsanitize=fuzzer,address)
  target_link_libraries(
    fuzz_sflow
    NdtCore_CollectionLib
    NdtCore_EventHandlingLib
    NdtCore_DataManagementLib
    EventSystemLib
    UtilsLib
    ssh
    OpenSSL::Crypto
    OpenSSL::SSL
    Boost::system
    Boost::url
  )
endif()
