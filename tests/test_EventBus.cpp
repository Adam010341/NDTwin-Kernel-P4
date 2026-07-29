/**
 * Tests for EventBus, focused on reentrancy.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The bus had zero subscribers for the whole life of the project -- `registerHandler()` was
 * called nowhere -- so `emit()` was a no-op and its reentrancy bug was unreachable. Phase 6 is
 * where handlers get wired up, which is what makes these worth having now.
 *
 * The reentrant cases below would *hang* rather than fail against the old implementation, so
 * each runs on a detached thread with a bounded wait. A test that deadlocks the suite is worse
 * than no test: it gives no signal and blocks everything after it.
 *
 * Measured against the pre-fix code, to be precise about what each case proves:
 *
 *  - `AHandlerMayRegisterAnotherHandler` fails deterministically. It is a genuine lock upgrade
 *    on one thread, so it can only deadlock.
 *  - The nested-`emit` cases *passed* even while broken. Taking a second `shared_lock` on the
 *    same thread is undefined by the standard but glibc happens to allow it when no writer is
 *    queued. They are therefore guards against a latent hazard rather than reproductions of a
 *    failure -- which is exactly why the bug survived unnoticed, and why the fix is worth having
 *    even though only one test turns red without it.
 */

#include <atomic>
#include <chrono>
#include <future>
#include <memory>
#include <thread>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "event_system/EventBus.hpp"

namespace
{

/// Long enough that a slow machine does not report a false deadlock, short enough that a real
/// one does not stall the suite.
constexpr auto kDeadlockTimeout = std::chrono::seconds(5);

/// Runs `body(bus)` on a detached thread and reports whether it finished in time.
///
/// Two details are deliberate, both learned by getting them wrong:
///
///  - **Detached thread, not std::async.** `std::async`'s future *joins in its destructor*, so
///    an abandoned deadlocked task hangs the process anyway -- verified: reverting the fix with
///    an async-based helper hung the whole test binary instead of failing one test. A promise
///    plus a detached thread is genuinely abandonable.
///  - **The bus is heap-allocated and leaked on timeout.** A deadlocked thread cannot be joined
///    or killed, so it outlives the test; letting it hold a reference to a destroyed stack
///    object would be use-after-free. It is deleted on the success path, which is the only path
///    that runs when the code is correct.
template <typename F>
[[nodiscard]] bool
runsWithoutDeadlock(F body)
{
    auto* bus = new EventBus();
    auto done = std::make_shared<std::promise<void>>();
    auto fut = done->get_future();

    std::thread([bus, done, body]() mutable {
        // Catch everything: an exception escaping a thread's entry point calls std::terminate,
        // which would abort the whole test binary instead of failing one case. The promise is
        // still satisfied so the waiter sees "finished" rather than timing out, and the
        // assertion in the test body is what reports the actual problem.
        try
        {
            body(*bus);
        }
        catch (...)
        {
        }
        done->set_value();
    }).detach();

    const bool finished = fut.wait_for(kDeadlockTimeout) == std::future_status::ready;
    if (finished)
    {
        delete bus;
    }
    return finished;
}

Event anEvent(EventType type = EventType::SwitchEntered)
{
    return Event{.type = type, .payload = {}};
}

} // namespace

TEST(EventBusTest, EmitWithNoHandlersDoesNothing)
{
    EventBus bus;
    EXPECT_NO_FATAL_FAILURE(bus.emit(anEvent()));
}

TEST(EventBusTest, DeliversToEveryHandlerForThatType)
{
    EventBus bus;
    int a = 0, b = 0;
    bus.registerHandler(EventType::SwitchEntered, [&](const Event&) { ++a; });
    bus.registerHandler(EventType::SwitchEntered, [&](const Event&) { ++b; });

    bus.emit(anEvent(EventType::SwitchEntered));

    EXPECT_EQ(a, 1);
    EXPECT_EQ(b, 1);
}

TEST(EventBusTest, DoesNotDeliverToHandlersForOtherTypes)
{
    EventBus bus;
    int switchEntered = 0, linkFailure = 0;
    bus.registerHandler(EventType::SwitchEntered, [&](const Event&) { ++switchEntered; });
    bus.registerHandler(EventType::LinkFailureDetected, [&](const Event&) { ++linkFailure; });

    bus.emit(anEvent(EventType::LinkFailureDetected));

    EXPECT_EQ(switchEntered, 0);
    EXPECT_EQ(linkFailure, 1);
}

TEST(EventBusTest, HandlerCarriesThePayload)
{
    EventBus bus;
    std::string seen;
    bus.registerHandler(EventType::SwitchEntered, [&](const Event& e) {
        seen = std::any_cast<std::string>(e.payload);
    });

    bus.emit(Event{.type = EventType::SwitchEntered, .payload = std::string("dpid-7")});

    EXPECT_EQ(seen, "dpid-7");
}

TEST(EventBusTest, AHandlerMayRegisterAnotherHandler)
{
    // Guaranteed self-deadlock before the fix: registerHandler() waits for the unique_lock,
    // which waits for the shared_lock emit() was still holding, which waits for this handler.
    auto added = std::make_shared<std::atomic<int>>(0);

    ASSERT_TRUE(runsWithoutDeadlock([added](EventBus& bus) {
        bus.registerHandler(EventType::SwitchEntered, [&bus, added](const Event&) {
            bus.registerHandler(EventType::SwitchExited,
                                [added](const Event&) { ++*added; });
        });
        bus.emit(anEvent(EventType::SwitchEntered));
        // The handler registered during dispatch must work afterwards.
        bus.emit(anEvent(EventType::SwitchExited));
    })) << "emit() deadlocked while a handler registered another handler";

    EXPECT_EQ(added->load(), 1);
}

TEST(EventBusTest, AHandlerMayEmitAnotherEvent)
{
    // One event triggering another is ordinary pub/sub, and is what Phase 6 will do (a switch
    // entering leads to a topology refresh). Nested shared_lock on one thread is not permitted
    // by the standard and blocks under writer contention.
    auto inner = std::make_shared<std::atomic<int>>(0);

    ASSERT_TRUE(runsWithoutDeadlock([inner](EventBus& bus) {
        bus.registerHandler(EventType::SwitchExited, [inner](const Event&) { ++*inner; });
        bus.registerHandler(EventType::SwitchEntered, [&bus](const Event&) {
            bus.emit(anEvent(EventType::SwitchExited));
        });
        bus.emit(anEvent(EventType::SwitchEntered));
    })) << "emit() deadlocked while a handler emitted another event";

    EXPECT_EQ(inner->load(), 1);
}

TEST(EventBusTest, AHandlerMayEmitTheSameEventTypeWithoutInfiniteRecursion)
{
    // Re-entering the *same* type is the nastiest shape, because the handler list being
    // iterated is the one it re-enters. The copy makes this terminate as long as the handler
    // stops itself; assert it does not deadlock or explode.
    auto depth = std::make_shared<std::atomic<int>>(0);

    ASSERT_TRUE(runsWithoutDeadlock([depth](EventBus& bus) {
        bus.registerHandler(EventType::SwitchEntered, [&bus, depth](const Event& e) {
            if (depth->fetch_add(1) < 3)
            {
                bus.emit(e);
            }
        });
        bus.emit(anEvent(EventType::SwitchEntered));
    })) << "emit() deadlocked on same-type reentrancy";

    EXPECT_EQ(depth->load(), 4) << "expected the initial call plus three nested ones";
}

TEST(EventBusTest, ConcurrentEmitAndRegisterDoNotDeadlock)
{
    // A writer queued behind readers is exactly the contention that turns the nested-read case
    // from "usually works" into a deadlock, so exercise it directly.
    auto calls = std::make_shared<std::atomic<int>>(0);

    ASSERT_TRUE(runsWithoutDeadlock([calls](EventBus& bus) {
        bus.registerHandler(EventType::SwitchEntered, [calls](const Event&) { ++*calls; });
        std::vector<std::future<void>> tasks;
        for (int i = 0; i < 4; ++i)
        {
            tasks.push_back(std::async(std::launch::async, [&] {
                for (int j = 0; j < 200; ++j)
                {
                    bus.emit(anEvent(EventType::SwitchEntered));
                }
            }));
            tasks.push_back(std::async(std::launch::async, [&] {
                for (int j = 0; j < 50; ++j)
                {
                    bus.registerHandler(EventType::SwitchExited, [](const Event&) {});
                }
            }));
        }
        for (auto& t : tasks)
        {
            t.get();
        }
    })) << "concurrent emit/registerHandler deadlocked";

    EXPECT_GE(calls->load(), 800);
}
