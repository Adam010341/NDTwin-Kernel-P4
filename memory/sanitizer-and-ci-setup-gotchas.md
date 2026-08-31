---
name: sanitizer-and-ci-setup-gotchas
description: "NDTwin-Kernel has ASan/TSan builds and CI as of 2026-08-09. Four setup facts that cost a build each to discover: CMAKE_CXX_FLAGS not add_compile_options, -Wno-error=tsan, setarch -R, PRE_TEST discovery"
metadata: 
  node_type: memory
  type: reference
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-09T07:51:33.189Z
---

`cmake/sanitizer-flags.cmake` gives `-DSANITIZER=asan|tsan`, and `.github/workflows/ci.yml` runs GCC build+tests, ASan+UBSan, TSan and a clang build. Four things had to be discovered by building; a plan written from reading the code had none of them.

1. **Sanitizer flags must go in `CMAKE_CXX_FLAGS`, not `add_compile_options()`.** The top-level `CMakeLists.txt` saves, clears and restores directory `COMPILE_OPTIONS` around `FetchContent_MakeAvailable(googletest)` so this project's `-Werror` does not trip on third-party warnings — and a directory property is stripped there too, leaving instrumented tests linked against an uninstrumented framework.

2. **TSan needs `-Wno-error=tsan`.** GCC's `-Wtsan` fires on `std::atomic_thread_fence` inside Boost.Asio's `std_fenced_block`, and `-Werror` makes a TSan build outright impossible. Keep the warning visible, because it states a real limitation: **TSan cannot see synchronisation done through those fences**, so a report implicating Asio's internals or two handlers on one `io_context` is not evidence of a race by itself.

3. **TSan needs `setarch "$(uname -m)" -R` at run time** — otherwise `FATAL: ThreadSanitizer: unexpected memory mapping` before `main`, the usual ASLR-entropy failure on current kernels.

4. **`-DCMAKE_GTEST_DISCOVER_TESTS_DISCOVERY_MODE=PRE_TEST`**, because `gtest_discover_tests` runs the binary *during the build*, and under a sanitizer that failure aborts the link instead of reporting a test failure.

clang also needs `-Wno-error=deprecated-declarations` (`std::aligned_storage` inside Boost.Beast; being a system header does not suppress it because the template is instantiated from our code).

**What this bought, in one run each.** TSan: a real `heap-use-after-free` — `dynamic_cast<Answer*>(parseReply(x).get())`, a temporary `unique_ptr` destroyed at the end of the full-expression, passing on every ordinary run because the freed bytes still held the old value. clang: `-Wunused-private-field` (GCC has no equivalent) found `FlowDispatcher`'s `fencePerBurst` — accepted, stored, documented as guaranteeing ordering, never read. **Dead code is inert; a false affordance is load-bearing in someone's head.**

**How to apply.** Both sanitizers and both compilers are clean over the 394 C++ tests — treat a new report as real. But note the scope: the unit tests do not start the HTTP server, the sFlow workers or `pingWorker`, so this covers only the concurrency the tests exercise. Running `build-tsan/bin/ndtwin_kernel` against the live stack is still undone. CI catches build breaks, test regressions and silently all-skipped files; **it cannot catch a false test** — that stays the mutation gate's job. Related: [[mutation-gate-for-tests]], [[live-runs-find-what-tests-cannot]].
