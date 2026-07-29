#pragma once

#include <any>           // for any
#include <functional>    // for function
#include <mutex>         // for unique_lock
#include <shared_mutex>  // for shared_lock, shared_mutex
#include <unordered_map> // for unordered_map, operator==, _Node_const_iter...
#include <utility>       // for move, pair
#include <vector>        // for vector

// Define supported event types
enum class EventType
{
    FlowAdded,            // 1. A new flow is added (triggered by Ryu request)
    LinkFailureDetected,  // 2. A link failure has been detected in the topology (triggered by Ryu
                          // request)
    IdleFlowPurged,       // 3. An idle flow has been removed
    LinkRecoveryDetected, // 4. A link recovery has been detected in the topology (triggered by Ryu
                          // request)
    SwitchEntered,
    SwitchExited
};

// Event structure containing type and payload
struct Event
{
    EventType type;
    std::any payload; // Can hold any payload data, e.g., PacketInPayload
};

class EventBus
{
  public:
    using Handler = std::function<void(const Event&)>;

    // Register a handler for a specific event type
    void registerHandler(EventType type, Handler handler)
    {
        std::unique_lock lock(m_mutex);
        m_handlers[type].push_back(std::move(handler));
    }

    /** @brief Emit an event, calling every handler registered for its type synchronously.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Handlers are copied out under the lock and invoked after releasing it. That ordering is
     * the point, not an optimisation: `std::shared_mutex` is not reentrant, so invoking
     * handlers while still holding the lock deadlocks as soon as a handler touches the bus.
     *
     *  - A handler calling `registerHandler()` is a *guaranteed* self-deadlock: it waits for
     *    the `unique_lock`, which waits for this `shared_lock`, which waits for the handler.
     *  - A handler calling `emit()` again takes a nested `shared_lock` on the same thread.
     *    The standard does not permit that, and in practice most rwlock implementations block
     *    new readers once a writer is queued, so it deadlocks under contention.
     *
     * Both are easy to hit once anything subscribes -- an event triggering another event is
     * ordinary pub/sub -- so the copy is cheap insurance. Handlers therefore see the handler
     * set as it was when emit() began; a handler registered during dispatch is not called for
     * the in-flight event.
     */
    void emit(const Event& event) const
    {
        std::vector<Handler> handlers;
        {
            std::shared_lock lock(m_mutex);
            auto it = m_handlers.find(event.type);
            if (it == m_handlers.end())
            {
                return;
            }
            handlers = it->second;
        }
        for (const auto& handler : handlers)
        {
            handler(event);
        }
    }

  private:
    mutable std::shared_mutex m_mutex;
    std::unordered_map<EventType, std::vector<Handler>> m_handlers;
};
