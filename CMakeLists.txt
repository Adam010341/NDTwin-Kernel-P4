cmake_minimum_required(VERSION 3.16)
project(NetworkDigitalTwin LANGUAGES CXX)

if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    # GCC: always use color
    add_compile_options(-fdiagnostics-color=always)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    # Clang: enable color diagnostics
    add_compile_options(-fcolor-diagnostics)
endif()

# --- Compiler Settings ---
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# whether using example file 
set(CONFIG_TEMPLATE "${CMAKE_CURRENT_SOURCE_DIR}/setting/AppConfig.hpp.example")
set(CONFIG_FILE     "${CMAKE_CURRENT_SOURCE_DIR}/setting/AppConfig.hpp")

if(NOT EXISTS ${CONFIG_FILE})

    if(EXISTS ${CONFIG_TEMPLATE})
        message(STATUS "-------------------------------------------------------")
        message(STATUS " [Config] Local config not found: ${CONFIG_FILE}")
        message(STATUS " [Config] Creating specific config from example template...")
        

        configure_file(${CONFIG_TEMPLATE} ${CONFIG_FILE} COPYONLY)
        
        message(STATUS " [Config] Done. You can now edit setting/AppConfig.hpp")
        message(STATUS "-------------------------------------------------------")
    else()

        message(WARNING " [Config] Template ${CONFIG_TEMPLATE} not found! Build may fail.")
    endif()
else()
    message(STATUS " [Config] Found local config: ${CONFIG_FILE}")
endif()


# --- Find External Packages (at the top level) ---
find_package(libssh REQUIRED)

find_package(OpenSSL REQUIRED)

find_package(Boost 1.83 REQUIRED COMPONENTS url system)

# --- Global Compile Flags ---
add_compile_options(
    -Wall -Wextra -Wpedantic -Wno-unused-parameter -Wunused
    -Wunused-function -Wunused-variable -Wunused-local-typedefs
    -Werror -pthread
)

# --- Sanitizer builds (opt-in: -DSANITIZER=asan|tsan) ---
# [Co-developed with claude code -- Adam]
# No-op unless SANITIZER is defined, so the ordinary build is untouched. Included here rather than
# lower down because it edits CMAKE_CXX_FLAGS, which must be set before any target is defined.
include(cmake/sanitizer-flags.cmake)

# --- SPDLOG Active Level ---
if(NOT DEFINED SPDLOG_ACTIVE_LEVEL)
    set(SPDLOG_ACTIVE_LEVEL "SPDLOG_LEVEL_TRACE" CACHE STRING "spdlog active level")
endif()
add_compile_definitions(SPDLOG_ACTIVE_LEVEL=${SPDLOG_ACTIVE_LEVEL})

# --- Global Include Directories ---
include_directories(
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/libs"
)

# --- Build Type Specific Flags ---
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0 -DDEBUG_BUILD")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")

# --- Output Directories ---
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# --- Add Subdirectories (Modules/Libraries) ---
add_subdirectory(src/utils)
add_subdirectory(src/event_system)
add_subdirectory(src/ndt_core/collection)
add_subdirectory(src/ndt_core/routing_management)
add_subdirectory(src/ndt_core/data_management)
add_subdirectory(src/ndt_core/event_handling)
add_subdirectory(src/ndt_core/power_management)
add_subdirectory(src/ndt_core/application_management)
add_subdirectory(src/ndt_core/intent_translator)
add_subdirectory(src/ndt_core/http)

# --- Main Executable ---
add_executable(ndtwin_kernel src/main.cpp)

# --- Link Libraries to Main Executable ---
# This is the crucial part. We link our internal static libraries FIRST,
# and then we link the external libssh library that they depend on.
target_link_libraries(ndtwin_kernel PRIVATE
    # Your internal libraries
    UtilsLib
    EventSystemLib
    NdtCore_CollectionLib
    NdtCore_RoutingManagementLib
    NdtCore_DataManagementLib
    NdtCore_EventHandlingLib
    NdtCore_PowerManagementLib
    NdtCore_ApplicationLib
    NdtCore_HttpLib
    NdtCore_IntentTranslatorLib
    # The external library that provides the symbols for ssh_new, etc.
    # We use the direct library name 'ssh', which CMake turns into '-lssh' for the linker.
    # This is the most reliable method and bypasses variable expansion issues.
    ssh
    OpenSSL::Crypto
    OpenSSL::SSL
    Boost::system
    Boost::url
)

# --- Unit Testing ---
enable_testing()
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/03597a01ee50ed33e9dfd640b249b4be3799d395.zip
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

# [Co-developed with claude code -- Adam]
# Build googletest without this project's -Werror/-Wpedantic. add_compile_options()
# above applies at directory scope and would otherwise propagate into the fetched
# third-party sources, so a compiler upgrade could break the build on warnings we
# do not own. Restore our flags immediately afterwards.
get_directory_property(NDTWIN_PROJECT_COMPILE_OPTIONS COMPILE_OPTIONS)
set_directory_properties(PROPERTIES COMPILE_OPTIONS "")
FetchContent_MakeAvailable(googletest)
set_directory_properties(PROPERTIES COMPILE_OPTIONS "${NDTWIN_PROJECT_COMPILE_OPTIONS}")

add_subdirectory(tests)
