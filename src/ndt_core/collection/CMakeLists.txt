# src/ndt_core/collection/CMakeLists.txt
add_library(NdtCore_CollectionLib STATIC
    FlowLinkUsageCollector.cpp
    TopologyAndFlowMonitor.cpp
    Classifier.cpp
)

# [Co-developed with claude code -- Adam] Boost.Graph false positive; see the top-level CMakeLists.txt.
set_source_files_properties(TopologyAndFlowMonitor.cpp PROPERTIES
    COMPILE_OPTIONS "${NDTWIN_BOOST_GRAPH_MAYBE_UNINITIALIZED}")
