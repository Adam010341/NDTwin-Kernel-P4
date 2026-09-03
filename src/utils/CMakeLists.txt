# src/utils/CMakeLists.txt
add_library(UtilsLib STATIC
    Logger.cpp
    # [Co-developed with claude code -- Adam] FINDINGS #47: descriptors that must not survive an
    # exec, and the /proc lookup that says who really holds a port.
    FdHygiene.cpp
    # Utils.cpp  # Uncomment and add if you have a Utils.cpp implementing Utils.hpp
)

# Public headers for UtilsLib are found via the global include path:
# "${CMAKE_SOURCE_DIR}/include/utils"
# No specific target_include_directories needed here if Logger.cpp includes "utils/Logger.hpp"