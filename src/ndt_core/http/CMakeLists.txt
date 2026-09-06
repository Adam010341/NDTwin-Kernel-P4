# src/ndt_core/http/CMakeLists.txt

# 1. define a static lib for all http‑session code
add_library(NdtCore_HttpLib
  HttpSession.cpp
  # [Co-developed with claude code -- Adam] W17. A separate translation unit from HttpSession.cpp
  # on purpose: that one costs ~1.6 GB and ~100 CPU-seconds to compile here, and
  # tests/shell/mutate_capacity_reads_running_artifact.sh rebuilds what it mutates once per
  # mutation.
  OpenflowCapacityReport.cpp
)

# 2. make sure the compiler can find our public headers
target_include_directories(NdtCore_HttpLib
  PUBLIC
    ${CMAKE_SOURCE_DIR}/include
)

# 3. link in any dependencies needed by HttpSession.cpp
#    Beast + ASIO are header‑only, but you may need boost_system etc.
#    We also depend on our other internal libs:
target_link_libraries(NdtCore_HttpLib
  PUBLIC
    UtilsLib
    EventSystemLib
    NdtCore_CollectionLib
    NdtCore_EventHandlingLib
    # (and any other NdtCore_* libs you call in your handlers)
)