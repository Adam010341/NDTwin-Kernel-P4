# Sanitizer build flags, selected with -DSANITIZER=asan|tsan.
#
# [Co-developed with claude code -- Adam]
#
#   cmake -S . -B build-asan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=asan
#   cmake --build build-asan -j"$(nproc)"
#   cmake -S . -B build-tsan -DCMAKE_BUILD_TYPE=Debug -DSANITIZER=tsan
#   cmake --build build-tsan -j"$(nproc)"
#
# ASan/UBSan and TSan cannot coexist in one binary, hence separate build directories. Never build
# into build/ -- the ordinary build is what everything else in tools/ expects to find there.
#
# The flags go into CMAKE_CXX_FLAGS rather than add_compile_options(), and that is not a style
# choice. add_compile_options() sets a directory property, and the top-level CMakeLists deliberately
# saves, clears and restores COMPILE_OPTIONS around FetchContent_MakeAvailable(googletest) so this
# project's -Werror does not break on third-party warnings. Sanitizer flags added that way would be
# stripped from googletest too, leaving instrumented test code linked against an uninstrumented
# framework -- which for ASan produces container-overflow false positives on std::vector crossing
# that boundary, and for TSan silently loses the framework's own synchronisation. CMAKE_CXX_FLAGS is
# not a directory property, so it survives that block and instruments everything.

if(NOT DEFINED SANITIZER)
    return()
endif()

# Frame pointers: without them the stack traces name the wrong functions, which is most of a
# sanitizer's value.
set(NDTWIN_SAN_COMMON "-fno-omit-frame-pointer -g")
set(NDTWIN_SAN_WARNINGS "")

if(SANITIZER STREQUAL "asan")
    # -fno-sanitize-recover=all so a UB report aborts. UBSan's default is to print and continue,
    # which in a test binary means the suite still exits 0 and the run looks clean.
    set(NDTWIN_SAN_FLAGS "-fsanitize=address,undefined -fno-sanitize-recover=all")
elseif(SANITIZER STREQUAL "tsan")
    set(NDTWIN_SAN_FLAGS "-fsanitize=thread")

    # -Wno-error=tsan, and the reason matters more than the flag.
    #
    # GCC's -Wtsan fires on std::atomic_thread_fence, which TSan cannot model. The call is not ours:
    # it is inside Boost.Asio (detail/std_fenced_block.hpp, used by the io_context this project runs
    # across hardware_concurrency() threads), so there is nothing to fix and -Werror simply makes a
    # TSan build impossible -- the first attempt failed here, in LLMAgent.cpp, via <memory>.
    #
    # Keep the warning visible rather than switching it off, because it states a real limitation:
    # **TSan cannot see synchronisation performed through those fences.** Asio establishes
    # happens-before relationships with them, so a TSan report implicating Asio's internals, or two
    # handlers on the same io_context, may be a false positive -- it is not evidence of a race on its
    # own. Reports about this project's own mutexes and atomics are unaffected.
    set(NDTWIN_SAN_WARNINGS "-Wno-error=tsan")
else()
    message(FATAL_ERROR "Unknown SANITIZER='${SANITIZER}'. Use asan or tsan.")
endif()

# -O1: enough for the interceptors to inline, not enough to make a trace unreadable. O0 makes ASan
# very slow; O2+ starts folding away the frames you need.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${NDTWIN_SAN_COMMON} ${NDTWIN_SAN_FLAGS} ${NDTWIN_SAN_WARNINGS} -O1")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${NDTWIN_SAN_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${NDTWIN_SAN_FLAGS}")

message(STATUS "Sanitizer build: ${SANITIZER} (${NDTWIN_SAN_FLAGS})")
