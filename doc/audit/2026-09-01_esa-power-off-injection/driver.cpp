// Driver for the ESA power-off injection round.
//
// [Co-developed with claude code -- Adam]
//
// WHAT THIS COMPILES
//
// It compiles /home/adam/Energy-Saving-App/src/app/energy_saving_app.cpp *verbatim*.
// That file is not edited, patched, or copied -- it is #included.  The only alteration
// is that its `main` is renamed by the preprocessor so this translation unit can supply
// its own entry point.  Every header the shipped file uses is included FIRST, above the
// #define, so the rename cannot reach into any header: by the time the shipped file's own
// #includes run, the include guards have already fired and they expand to nothing.
//
// WHY AN #include AND NOT A LINK
//
// The three pieces of state `setSwitchesPowerState` reads --
//   caseID2SwitchesDpidToPowerOff, caseID2SwitchesDpidToPowerOn, dpid2IP
// -- are declared `static` at file scope (energy_saving_app.cpp:48-50), i.e. internal
// linkage.  A separate driver TU cannot name them.  Being inside the TU is the only way
// to set up the call without editing the shipped source, which is the thing we must not do.
//
// WHAT THIS DOES *NOT* RUN
//
// Not the shipped `energy_saving_app` binary, and not the decision logic upstream of
// setSwitchesPowerState (which case to pick, which switches to turn off).  It enters at
// setSwitchesPowerState with the state that logic would have produced.  The reply-handling
// under test is entirely inside setSwitchesPowerState and the http.cpp function it calls,
// both of which are the shipped source, reached over a real TCP socket.

// ---- every include the shipped TU uses, pulled in before `main` is poisoned ----
#include "app/http.hpp"
#include "app/settings.hpp"
#include "app/types.hpp"
#include "common/GraphTypes.hpp"
#include "common/types.hpp"
#include "utils/Logger.hpp"
#include "utils/common.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/version.hpp>
#include <boost/graph/biconnected_components.hpp>
#include <boost/graph/filtered_graph.hpp>
#include <boost/graph/graph_utility.hpp>
#include <boost/graph/undirected_graph.hpp>
#include <boost/stacktrace.hpp>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <openssl/sha.h>
#include <optional>
#include <semaphore>
#include <string>
#include <thread>
#include <unordered_set>
#include <spdlog/fmt/ranges.h>

#define main esa_shipped_main_not_called_here
#include "/home/adam/Energy-Saving-App/src/app/energy_saving_app.cpp"
#undef main

// -----------------------------------------------------------------------------

namespace
{
// 10.0.0.1 and 10.0.0.2 -- the two switches this round turns off.
constexpr uint32_t kIpSwitch1 = 0x0A000001u;
constexpr uint32_t kIpSwitch2 = 0x0A000002u;
constexpr const char* kCaseId = "case1";
} // namespace

int
main(int argc, char* argv[])
{
    auto cfg = Logger::parse_cli_args(argc, argv);
    Logger::init(cfg);

    // Stand in for what the decision logic would have produced: one case, two switches to
    // power OFF, none to power ON.  Empty power-ON set is deliberate -- it makes
    // wait_until_powered_on_switches_are_up return on its first poll (nothing to wait for)
    // instead of blocking for its 360 s budget, so the arm reaches the power-OFF loop.
    // It also isolates the OFF side, which is the side under test.
    dpid2IP[1] = kIpSwitch1;
    dpid2IP[2] = kIpSwitch2;
    caseID2SwitchesDpidToPowerOff[kCaseId] = std::unordered_set<uint64_t>{1, 2};
    caseID2SwitchesDpidToPowerOn[kCaseId] = std::unordered_set<uint64_t>{};

    // DRIVER_POWERON_DPID exists for the discriminating-power control arm, not for the
    // injection arms.  Naming a dpid the graph fixture never reports as up makes the
    // power-ON guard time out and take its `if (!waiting_result) return;` branch, so the
    // completion line is NOT printed.  Without that arm, "the injection arms printed the
    // completion line" is compatible with "this driver always prints it".
    if (const char* onDpid = std::getenv("DRIVER_POWERON_DPID"))
    {
        const uint64_t dpid = std::strtoull(onDpid, nullptr, 10);
        dpid2IP[dpid] = 0x0A0000FFu;
        caseID2SwitchesDpidToPowerOn[kCaseId] = std::unordered_set<uint64_t>{dpid};
        std::cout << "DRIVER-MODE: power-on guard control, waiting on dpid " << dpid << std::endl;
    }

    // Sentinels are the driver's own, deliberately worded so they cannot be confused with
    // the app's "Power On/Off Task Complete" -- that line is the finding, and the
    // instrument must not be able to produce it.
    std::cout << "DRIVER-ENTER: calling shipped setSwitchesPowerState(" << kCaseId << ")"
              << std::endl;

    setSwitchesPowerState(kCaseId, std::vector<sflow::FlowDiff>{});

    std::cout << "DRIVER-RETURN: shipped setSwitchesPowerState returned normally" << std::endl;
    return 0;
}
