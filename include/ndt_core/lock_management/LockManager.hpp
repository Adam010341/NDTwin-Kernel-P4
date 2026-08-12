#pragma once
#include <chrono>
#include <mutex>
#include <string>
#include <unordered_map>
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
     */
    LockType stringToLockType(const std::string& str) {
        if (str == "routing_lock") return LockType::Routing;
        if (str == "graph_lock")   return LockType::Graph;
        if (str == "power_lock")   return LockType::Power;
        return LockType::Unknown;
    }

  public:
    /**
     * @brief Check if the provided lock type string is valid.
     */
    bool isValidType(const std::string& typeStr) {
        return stringToLockType(typeStr) != LockType::Unknown;
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