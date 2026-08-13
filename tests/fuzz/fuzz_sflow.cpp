/**
 * libFuzzer harness for the sFlow datagram parser.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `handlePacket(char*, size_t)` is the process's most exposed input surface: anything that can
 * send UDP to :6343 reaches it, and it has produced a heap-buffer-overflow before (found by
 * ASan, fixed with bounds checks and 17 hand-written malformed cases). Hand-written cases cover
 * the malformations someone thought of; this covers the ones nobody did.
 *
 * The oracle is *clean rejection*, not silence. The parser has an explicit refusal path --
 * reportMalformedDatagram -- so any input either parses or is counted as malformed. A crash,
 * a sanitizer report, or a hang is the finding. Nothing here asserts on the parse result: the
 * bug class being hunted is memory safety, and a wrong-but-safe parse is test_SFlowParsing's
 * business.
 *
 * Build (clang only; libFuzzer ships with it, so nothing to install):
 *
 *     cmake -S . -B build-fuzz -DCMAKE_BUILD_TYPE=Debug -DFUZZING=ON \
 *           -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_C_COMPILER=clang \
 *           -DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations
 *     cmake --build build-fuzz -j"$(nproc)"
 *     ./build-fuzz/bin/fuzz_sflow tests/fixtures -max_total_time=60
 *
 * tests/fixtures holds 31 real captures, several already malformed, so the corpus starts on
 * the far side of the header checks instead of teaching the fuzzer the sFlow version field.
 *
 * Prove the harness before trusting a clean run: comment out a bounds check in the parser and
 * confirm this finds it within seconds. A fuzzer wired to nothing is green forever.
 */

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"

namespace
{

/// Same shape as test_SFlowParsing.cpp's TestableCollector: the collaborators are stored but
/// not used by the parsing path, so they stay minimal and the constructor stays cheap.
class FuzzableCollector : public sflow::FlowLinkUsageCollector
{
  public:
    FuzzableCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                      std::shared_ptr<EventBus> bus,
                      std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        static_cast<int>(utils::DeploymentMode::MININET),
                                        std::move(classifier))
    {
    }

    using sflow::FlowLinkUsageCollector::handlePacket;
};

std::unique_ptr<FuzzableCollector> makeCollector()
{
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            bus,
                                                            utils::DeploymentMode::MININET);
    return std::make_unique<FuzzableCollector>(monitor, bus,
                                               std::make_shared<ndtClassifier::Classifier>());
}

/// Every accepted datagram adds to the flow table, so a long campaign on one collector grows
/// without bound and libFuzzer reports the growth as an OOM in the parser. Recycling keeps the
/// run honest about memory while still letting consecutive inputs share state -- which is where
/// the accumulate-then-parse bugs live.
constexpr int kInputsPerCollector = 512;

/// A raw pointer, and the last one is deliberately never deleted.
///
/// ~FlowLinkUsageCollector calls stop(), which touches the logger. A collector destroyed during
/// static destruction therefore reaches a spdlog registry that may already be gone -- observed
/// as a heap-use-after-free at exit on *every* input, including valid ones, which reads like a
/// parser finding and is not one. Production does not have this shape: main.cpp holds the
/// collector as a local and calls stop() explicitly before returning (main.cpp:331, :425).
/// LeakSanitizer stays quiet because this global still points at the object, so it is reachable
/// rather than leaked. Collectors replaced mid-run are deleted normally -- the logger is alive
/// then.
FuzzableCollector* g_collector = nullptr;
int g_inputs = 0;

} // namespace

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    // The parser logs, and Logger::instance() is null until init runs -- logging without it
    // segfaults, which would read as a finding on the very first input.
    LogConfig cfg;
    cfg.level = spdlog::level::off;
    Logger::init(cfg);
    g_collector = makeCollector().release();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (++g_inputs >= kInputsPerCollector)
    {
        delete g_collector;
        g_collector = makeCollector().release();
        g_inputs = 0;
    }
    // handlePacket takes char* and may write into the buffer while parsing, so it gets its own
    // copy rather than casting away const from libFuzzer's memory.
    std::vector<char> buffer(data, data + size);
    g_collector->handlePacket(buffer.data(), size);
    return 0;
}
