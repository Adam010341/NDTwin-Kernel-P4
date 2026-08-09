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
 * thread gets its own and the described race cannot occur. The program that establishes that is
 * committed as tests/manual/inet_ntoa_buffer_is_thread_local.c -- it was described here as "a small
 * C program" while living only in /tmp, which made the one load-bearing claim in this comment the
 * one thing a reader could not check. Note the scope: thread-local since glibc 2.32. On a libc
 * without that guarantee the race is real again, and this test will not catch it, because it
 * exercises inet_ntop.
 *
 * So what this file actually establishes is that the conversion is correct, in both overloads,
 * under eight threads and 160,000 concurrent conversions. That is worth having for the call sites
 * spread across threads -- 62 of them at the time of writing, reproduce with:
 *
 *   grep -rn "ipToString(" src/ include/ --include='*.cpp' --include='*.hpp' \
 *     | grep -v '^include/utils/Utils.hpp' | wc -l
 *
 * (a bare number rots silently; the command that produced it does not). It is not a regression test
 * for a race that was never live here.
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

// --- tryMacToUint64 -----------------------------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// macToUint64 read six 2-digit fields at fixed offsets 0,3,6,9,12,15 and never looked at
// mac.size(). It relied on std::from_chars failing on whatever it happened to find, which is not
// validation. The measured consequence:
//
//     "00:11:22:33:44:5"   one digit short   ->   73588229125, reported as success
//
// from_chars parsed the lone `5`, stopped at the terminator, and said ec == errc(). A wrong MAC
// means the wrong host is looked up and nothing says so. Where it did fail it threw, and two HTTP
// handlers let that reach buildResponse's catch-all, answering 500 for a malformed client request.
//
// Not an out-of-bounds read, which is worth pinning because it looks like one: the loop touches
// index 16 at most, libstdc++ allocates size()+1, and its short-string buffer is 16 bytes. Checked
// under ASan rather than assumed. Found by agy-review 0115.

TEST(TryMacToUint64Test, AWellFormedMacParses)
{
    EXPECT_EQ(utils::tryMacToUint64("00:11:22:33:44:55").value_or(0), 0x001122334455ull);
    EXPECT_EQ(utils::tryMacToUint64("aa:bb:cc:dd:ee:ff").value_or(0), 0xaabbccddeeffull);
    EXPECT_EQ(utils::tryMacToUint64("AA:BB:CC:DD:EE:FF").value_or(0), 0xaabbccddeeffull)
        << "upper case hex must parse; Ryu emits lower but the API is not the only caller";
    EXPECT_EQ(utils::tryMacToUint64("00:00:00:00:00:00").value_or(1), 0ull);
    EXPECT_EQ(utils::tryMacToUint64("ff:ff:ff:ff:ff:ff").value_or(0), 0xffffffffffffull);
}

TEST(TryMacToUint64Test, TheDashSeparatorIsAcceptedToo)
{
    EXPECT_EQ(utils::tryMacToUint64("00-11-22-33-44-55").value_or(0), 0x001122334455ull);
}

TEST(TryMacToUint64Test, AMacOneDigitShortIsRefusedRatherThanSilentlyWrong)
{
    // The measured defect. The old code returned 73588229125 here.
    EXPECT_FALSE(utils::tryMacToUint64("00:11:22:33:44:5").has_value());
}

TEST(TryMacToUint64Test, AnythingThatIsNotExactlySeventeenCharactersIsRefused)
{
    for (const char* bad : {"",
                            "00",
                            "00:11:22:33:44",
                            "00:11:22:33:44:55:66",
                            "00:11:22:33:44:555",
                            " 00:11:22:33:44:55",
                            "00:11:22:33:44:55 "})
    {
        EXPECT_FALSE(utils::tryMacToUint64(bad).has_value()) << "accepted \"" << bad << "\"";
    }
}

TEST(TryMacToUint64Test, TheSeparatorsMustActuallyBeSeparators)
{
    // Right length, wrong shape. Without the separator check these parse as if the colons were
    // hex, because from_chars is happy to read the first two characters of each field.
    EXPECT_FALSE(utils::tryMacToUint64("001122334455:::::").has_value());
    EXPECT_FALSE(utils::tryMacToUint64("00x11x22x33x44x55").has_value());
}

TEST(TryMacToUint64Test, NonHexDigitsAreRefused)
{
    EXPECT_FALSE(utils::tryMacToUint64("gg:11:22:33:44:55").has_value());
    EXPECT_FALSE(utils::tryMacToUint64("00:11:22:33:44:gg").has_value());
    EXPECT_FALSE(utils::tryMacToUint64("0 :11:22:33:44:55").has_value());
}

TEST(TryMacToUint64Test, TheThrowingWrapperStillThrowsAndOnTheSameInputs)
{
    // macToUint64 delegates now, so every existing caller inherits the validation rather than only
    // the two HTTP handlers that were updated.
    EXPECT_EQ(utils::macToUint64("00:11:22:33:44:55"), 0x001122334455ull);
    EXPECT_THROW(utils::macToUint64("00:11:22:33:44:5"), std::invalid_argument);
    EXPECT_THROW(utils::macToUint64(""), std::invalid_argument);
}
