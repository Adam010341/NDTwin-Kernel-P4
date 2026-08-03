/**
 * Initialises the logger once per test process, for every suite.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `Logger::instance()` returns a null shared_ptr until `Logger::init` runs, and spdlog dereferences
 * it inside `should_log` -- so any test that reaches a log statement in the code under test
 * segfaults inside spdlog rather than failing in the thing it was checking. That includes disabled
 * levels: a TRACE or DEBUG call still evaluates `Logger::instance()`, because it is an ordinary
 * function argument.
 *
 * Until now every suite did this for itself in `SetUpTestSuite`, which works but has to be
 * remembered. It was not remembered for `test_OvsPowerStrategy.cpp`, and the result was three
 * SEGFAULTs that appear **only under ctest** -- ctest gives each test its own process, so a test
 * that logs passes when run alongside a suite that happens to initialise the logger first, and
 * crashes when run alone. `./build/bin/test_routing_strategy` was green while `ctest` was red on the
 * same commit, and the green one is what got reported.
 *
 * This is the second time this hazard has cost something. The first was the opposite failure: two
 * fixtures both called `Logger::init` and the second threw `logger with name 'netdt' already
 * exists`, which SKIPPED an entire suite whose assertions happened to codify a bug as intended
 * behaviour -- and ctest hid that one, because one process per test meant the throw never happened.
 *
 * A global environment removes the footgun rather than documenting it: it runs in every process
 * before any test, so a new test file cannot forget. The per-suite `SetUpTestSuite` calls are left
 * in place -- `Logger::init` is idempotent, and they document the dependency at the point where it
 * matters.
 */

#include <gtest/gtest.h>

#include "utils/Logger.hpp"

namespace
{

class LoggerEnvironment : public ::testing::Environment
{
  public:
    void SetUp() override
    {
        LogConfig cfg;
        // `off` rather than a real level, and deliberately: spdlog still evaluates the arguments of
        // a disabled call, so this is the production-like condition that used to crash, and it keeps
        // test output readable.
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

// Registered before main() runs. gtest_main provides main(), so there is no other hook.
const auto* const kRegistered = ::testing::AddGlobalTestEnvironment(new LoggerEnvironment);

} // namespace
