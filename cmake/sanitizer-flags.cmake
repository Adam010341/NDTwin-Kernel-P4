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

# -fuse-ld=gold, and this is a memory decision rather than a speed one.
#
# On 2026-09-05 the ASan test binary could not be linked at all on this laptop: the default BFD ld
# wanted more than the build guard's MemoryMax=4G and the link was killed with exit 137, after the
# 110 compile steps before it had succeeded. Relinking the same objects with gold took 19 seconds.
# Raising the cap is the wrong fix -- the cap is what keeps oomd from picking the user's own
# application as its victim (tools/build_guard/README.md, 2026-09-03 entry). Sanitizer builds are
# where this bites because -g plus the instrumentation makes the input to the link several times
# the ordinary size, so both asan and tsan get it.
#
# GNU only: this was measured against g++, and clang resolves -fuse-ld= against a different default.
# If gold is not installed we keep the default linker and say so, loudly, because the failure it
# produces does not name its own cause -- an OOM-killed link reports exit 137 and nothing else.
set(NDTWIN_SAN_LD "")
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    find_program(NDTWIN_LD_GOLD ld.gold)
    if(NDTWIN_LD_GOLD)
        set(NDTWIN_SAN_LD "-fuse-ld=gold")
    endif()
endif()
if(NDTWIN_SAN_LD STREQUAL "")
    message(WARNING
        "Sanitizer build will link with the default linker: "
        "compiler is '${CMAKE_CXX_COMPILER_ID}' (gold is selected for GNU only) and "
        "ld.gold was ${NDTWIN_LD_GOLD}. This is supported, but on a memory-capped build "
        "(tools/build_guard/guarded_build.sh, MemoryMax 4G by default) the link step may be "
        "killed with exit 137 and no diagnostic. Raise MEM_MAX for that run, or install gold.")
endif()

# -O1: enough for the interceptors to inline, not enough to make a trace unreadable. O0 makes ASan
# very slow; O2+ starts folding away the frames you need.
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${NDTWIN_SAN_COMMON} ${NDTWIN_SAN_FLAGS} ${NDTWIN_SAN_WARNINGS} -O1")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${NDTWIN_SAN_FLAGS} ${NDTWIN_SAN_LD}")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${NDTWIN_SAN_FLAGS} ${NDTWIN_SAN_LD}")

message(STATUS "Sanitizer build: ${SANITIZER} (${NDTWIN_SAN_FLAGS})")
if(NOT NDTWIN_SAN_LD STREQUAL "")
    message(STATUS "Sanitizer link: ${NDTWIN_SAN_LD} (${NDTWIN_LD_GOLD})")
endif()
