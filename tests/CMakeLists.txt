# tests/CMakeLists.txt
add_executable(
  test_routing_strategy
  test_OpenFlowRoutingStrategy.cpp
  test_P4RoutingStrategy.cpp
)
target_link_libraries(
  test_routing_strategy
  GTest::gtest_main
  NdtCore_RoutingManagementLib
  UtilsLib
  OpenSSL::Crypto
  OpenSSL::SSL
  Boost::system
  Boost::url
)

include(GoogleTest)
gtest_discover_tests(test_routing_strategy)
