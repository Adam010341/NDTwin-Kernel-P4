/**
 * Tests that utils::ipToString is correct under concurrency.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Read this before trusting the concurrency test below: it does NOT distinguish inet_ntop from
 * inet_ntoa. An audit reported that ipToString's old inet_ntoa returned a pointer into one static
 * buffer shared by the whole process, so threads would overwrite each other's addresses -- and the
 * header's own @warning agreed. This test was written to pin that. It passes against inet_ntoa
 * unchanged, verified by putting inet_ntoa back: on glibc 2.39 the buffer is thread-local, so each
 * thread gets its own and the described race cannot occur. A small C program confirms it -- the
 * main thread's buffer pointer differs from a spawned thread's.
 *
 * So what this file actually establishes is that the conversion is correct, in both overloads,
 * under eight threads and 160,000 concurrent conversions. That is worth having for 62 call sites
 * spread across threads. It is not a regression test for a race that was never live here.
 */

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "utils/Utils.hpp"

namespace
{

/// Builds the network-order (in_addr::s_addr) value for a.b.c.d, the form ipToString expects.
uint32_t
addr(uint8_t a, uint8_t b, uint8_t c, uint8_t d)
{
    return static_cast<uint32_t>(a) | (static_cast<uint32_t>(b) << 8) |
           (static_cast<uint32_t>(c) << 16) | (static_cast<uint32_t>(d) << 24);
}

} // namespace

TEST(IpToStringTest, ConvertsKnownAddresses)
{
    EXPECT_EQ(utils::ipToString(addr(10, 0, 0, 1)), "10.0.0.1");
    EXPECT_EQ(utils::ipToString(addr(192, 168, 123, 11)), "192.168.123.11");
    EXPECT_EQ(utils::ipToString(addr(0, 0, 0, 0)), "0.0.0.0");
    EXPECT_EQ(utils::ipToString(addr(255, 255, 255, 255)), "255.255.255.255");
}

TEST(IpToStringTest, ConcurrentCallersEachGetTheirOwnAnswer)
{
    // Each thread converts one address it owns, repeatedly, and must never observe another
    // thread's string. See the file header for why this passes against inet_ntoa too.
    constexpr int kThreads = 8;
    constexpr int kIterations = 20000;

    std::vector<std::thread> threads;
    std::atomic<int> mismatches{0};
    std::atomic<bool> go{false};

    for (int t = 0; t < kThreads; ++t)
    {
        threads.emplace_back([t, &mismatches, &go] {
            const uint32_t mine = addr(10, 0, 0, static_cast<uint8_t>(t + 1));
            const std::string expected = "10.0.0." + std::to_string(t + 1);

            // Start together, so the calls actually overlap rather than being serialised by
            // thread-creation latency.
            while (!go.load(std::memory_order_acquire))
            {
                std::this_thread::yield();
            }

            for (int i = 0; i < kIterations; ++i)
            {
                if (utils::ipToString(mine) != expected)
                {
                    mismatches.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }

    go.store(true, std::memory_order_release);
    for (auto& th : threads)
    {
        th.join();
    }

    EXPECT_EQ(mismatches.load(), 0)
        << "a caller received another thread's address: " << mismatches.load() << " of "
        << kThreads * kIterations << " conversions";
}

TEST(IpToStringTest, TheVectorOverloadIsAlsoSafeAndPreservesOrder)
{
    // It used to hold its own copy of the inet_ntoa call; now it delegates, so this pins both the
    // delegation and the ordering the callers rely on.
    const std::vector<uint32_t> ips = {addr(10, 0, 0, 1), addr(10, 0, 0, 97), addr(192, 168, 1, 1)};

    constexpr int kThreads = 4;
    std::vector<std::thread> threads;
    std::atomic<int> mismatches{0};

    for (int t = 0; t < kThreads; ++t)
    {
        threads.emplace_back([&ips, &mismatches] {
            const std::vector<std::string> expected = {"10.0.0.1", "10.0.0.97", "192.168.1.1"};
            for (int i = 0; i < 5000; ++i)
            {
                if (utils::ipToString(ips) != expected)
                {
                    mismatches.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }
    for (auto& th : threads)
    {
        th.join();
    }

    EXPECT_EQ(mismatches.load(), 0);
}

TEST(IpToStringTest, RoundTripsThroughIpStringToUint32)
{
    // The two are used as a pair all over the codebase; a mismatch in byte order between them
    // would corrupt every lookup keyed on an address.
    const std::vector<std::string> texts = {"10.0.0.1", "10.0.0.97", "192.168.123.20",
                                            "127.0.0.1"};
    for (const std::string& text : texts)
    {
        EXPECT_EQ(utils::ipToString(utils::ipStringToUint32(text)), text) << text;
    }
}
