#pragma once
#include <chrono>
#include <mutex>
#include <string>
#include <unordered_map>
#include <nlohmann/json.hpp>
#include "utils/Logger.hpp"

// Define available lock types using an Enum Class for type safety
enum class LockType {
    Routing,
    Graph,
    Power,
    Unknown // Used to indicate an invalid string input
};

// Structure to hold the state of a single lock
struct LockState {
    bool isLocked = false;
    std::chrono::steady_clock::time_point expiryTime;
};

class LockManager
{
  public:
    // --- Constants for Default Values (Single Source of Truth) ---
    static constexpr int DEFAULT_TTL_SECONDS = 5;
    static constexpr const char* DEFAULT_LOCK_TYPE_STR = "routing_lock";

  private:
    std::mutex m_mutex; 
    // Using Enum as the key for the map is more efficient than using strings
    std::unordered_map<LockType, LockState> m_locks;

    /**
     * @brief Helper function to convert string input to LockType enum.
     * This enforces the naming convention (routing_lock, graph_lock, power_lock).
     *
     * static because it reads no member state, and because parseRequest() below needs it
     * before any LockManager exists. [Co-developed with claude code -- Adam]
     */
    static LockType stringToLockType(const std::string& str) {
        if (str == "routing_lock") return LockType::Routing;
        if (str == "graph_lock")   return LockType::Graph;
        if (str == "power_lock")   return LockType::Power;
        return LockType::Unknown;
    }

  public:
    /**
     * @brief Check if the provided lock type string is valid.
     */
    static bool isValidType(const std::string& typeStr) {
        return stringToLockType(typeStr) != LockType::Unknown;
    }

    /**
     * @brief Why a lock request was refused, kept distinct because they need different answers.
     * [Co-developed with claude code -- Adam]
     */
    enum class RequestError {
        None,
        MalformedBody,   // the body is not JSON at all
        MissingType,     // valid JSON, no "type" field
        InvalidType      // "type" present but not one of the three locks
    };

    /**
     * @brief Parse an /ndt/acquire_lock body into a decision, WITHOUT acquiring anything.
     *
     * [Co-developed with claude code -- Adam]
     * This exists because the endpoint used to answer three different questions with one
     * behaviour: a malformed body, a body with no "type", and a body naming a lock that does
     * not exist all ended up acquiring `routing_lock` on the caller's behalf -- the real lock
     * that serialises writes to the network. The handler's `catch (...)` swallowed the parse
     * error and fell through with the defaults still in place, so "your JSON was rubbish" and
     * "you asked for routing_lock" were indistinguishable to the code and to the caller.
     *
     * Nothing is defaulted here. A caller that wants routing_lock has to say so, which both
     * in-tree consumers already do (Energy-Saving-App http.cpp:425 and
     * Traffic-Engineering-App:71 both send an explicit "type"), so refusing the implicit case
     * breaks no existing caller.
     *
     * `ttl` still defaults: it is a duration, not a target, and getting it wrong cannot make a
     * request act on something other than what it named.
     */
    struct LockRequest {
        bool ok = false;
        std::string type;
        int ttl = DEFAULT_TTL_SECONDS;
        RequestError error = RequestError::None;
        std::string requestedType;   // what the caller actually sent, for the error message
    };

    static LockRequest parseRequest(const std::string& body)
    {
        LockRequest out;
        nlohmann::json parsed;
        try {
            parsed = nlohmann::json::parse(body);
        } catch (...) {
            out.error = RequestError::MalformedBody;
            return out;
        }
        if (!parsed.is_object() || !parsed.contains("type") || !parsed["type"].is_string()) {
            out.error = RequestError::MissingType;
            return out;
        }
        out.requestedType = parsed["type"].get<std::string>();
        if (!isValidType(out.requestedType)) {
            out.error = RequestError::InvalidType;
            return out;
        }
        if (parsed.contains("ttl") && parsed["ttl"].is_number_integer()) {
            out.ttl = parsed["ttl"].get<int>();
        }
        out.type = out.requestedType;
        out.ok = true;
        return out;
    }

    /**
     * @brief Attempt to acquire a lock.
     * @param lockNameStr The string name of the lock (e.g., "routing_lock").
     * @param ttlSeconds Time-To-Live in seconds.
     * @return true if acquired successfully, false if busy or invalid name.
     */
    bool acquireLock(const std::string& lockNameStr, int ttlSeconds)
    {
        // 1. Convert string to Enum
        LockType type = stringToLockType(lockNameStr);

        // 2. Validation: Reject unknown lock types
        if (type == LockType::Unknown) {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid lock type requested: {}", lockNameStr);
            return false; 
        }

        std::lock_guard<std::mutex> lock(m_mutex);
        
        // 3. Access lock state using the Enum key
        LockState& state = m_locks[type];
        auto now = std::chrono::steady_clock::now();

        // 4. Check if it is currently locked and has not expired
        if (state.isLocked && now < state.expiryTime)
        {
            return false; // Lock is held by someone else
        }

        // 5. Acquire the lock
        state.isLocked = true;
        state.expiryTime = now + std::chrono::seconds(ttlSeconds);
        return true;
    }

    /**
     * @brief Release a lock.
     *
     * @return true if a *held* lock of a *valid* type was released; false otherwise.
     *
     * [Co-developed with claude code -- Adam]
     * This used to return void and bare-return on an unknown type, so releasing a lock nobody
     * held and releasing a lock whose type does not exist were both silent no-ops -- and
     * /ndt/release_lock, having nothing to test, answered 200 "released" to each. An app that
     * typoed its release believed the lock was free while the real lock stayed held until TTL
     * expiry, blocking every other acquire with no error anywhere.
     *
     * The sibling renew() already returns bool and distinguishes exactly these three cases, so
     * this is the shape the class had settled on; only unlock had not been given it.
     */
    bool unlock(const std::string& lockNameStr)
    {
        LockType type = stringToLockType(lockNameStr);
        if (type == LockType::Unknown) {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid lock type released: {}", lockNameStr);
            return false;
        }

        std::lock_guard<std::mutex> lock(m_mutex);
        const auto it = m_locks.find(type);
        if (it == m_locks.end() || !it->second.isLocked) {
            return false;
        }
        it->second.isLocked = false;
        return true;
    }

    /**
     * @brief Renew the TTL of a lock.
     */
    bool renew(const std::string& lockNameStr, int ttlSeconds)
    {
        LockType type = stringToLockType(lockNameStr);
        if (type == LockType::Unknown) return false;

        std::lock_guard<std::mutex> lock(m_mutex);
        
        // Cannot renew if the lock entry doesn't exist or is not currently locked
        if (m_locks.find(type) == m_locks.end() || !m_locks[type].isLocked) {
            return false;
        }

        // Extend the expiry time
        m_locks[type].expiryTime = std::chrono::steady_clock::now() + std::chrono::seconds(ttlSeconds);
        return true;
    }
};