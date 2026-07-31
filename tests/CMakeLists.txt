# tests/CMakeLists.txt
add_executable(
  test_routing_strategy
  test_RoutingStrategies.cpp
  test_EstimatedRates.cpp
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
