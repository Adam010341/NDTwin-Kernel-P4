/**
 * Tests for the synthetic power figure MININET mode reports for a simulated switch.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Mininet and bmv2 have no PSU to read, so this number has always been made up. It was made up
 * badly: `uniform_int_distribution<uint64_t>(0, UINT64_MAX >> 4)`, uniform over [0, 2^60), which
 * reported values like 193112054821787525 mW -- 1.9x10^14 watts -- and re-rolled on every poll, so
 * it also jumped by seventeen orders of magnitude between one tick and the next.
 *
 * "It is only a demo value" undersells it: the Energy-Saving application consumes this figure, so
 * every decision it reached was made on noise. There were also two independent copies of the RNG
 * (one in fetchPowerReportInternal, one in getSingleSwitchPowerReport), so the REST report and
 * the Intent Translator disagreed about the same switch at the same instant.
 */

#include <algorithm>
#include <set>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

namespace
{

/// Same test seam as LivenessProbe in test_OvsLiveness.cpp: reaches the policy without
/// constructing the manager, which would need a topology monitor and background threads.
class PowerProbe : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::syntheticPowerMilliwattsFor;
};

/// The dpids the 10-switch Mininet topologies actually use.
const std::vector<uint64_t> kSwitchDpids = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};

constexpr uint64_t kOneWattInMilliwatts = 1000;

} // namespace

TEST(SyntheticPowerTest, IsAPlausibleWattageForEveryTopologySwitch)
{
    // The regression. A switch draws tens to low hundreds of watts; the old code could report
    // 1.9x10^14 W. Asserting a plausible band is the whole point -- an exact value would just
    // pin the hash function.
    for (uint64_t dpid : kSwitchDpids)
    {
        const uint64_t mW = PowerProbe::syntheticPowerMilliwattsFor(dpid);
        const uint64_t watts = mW / kOneWattInMilliwatts;
        EXPECT_GE(watts, 30u) << "dpid " << dpid << " draws implausibly little";
        EXPECT_LE(watts, 150u) << "dpid " << dpid << " draws implausibly much: " << mW << " mW";
    }
}

TEST(SyntheticPowerTest, NeverReportsAnAstronomicalValue)
{
    // Stated as its own assertion because this is the symptom that was actually observed, and it
    // must fail loudly if someone reaches for an RNG again. 1 MW is far above any switch and far
    // below what the bug produced, so it separates the two unambiguously.
    constexpr uint64_t kOneMegawattInMilliwatts = 1'000'000'000;
    for (uint64_t dpid : kSwitchDpids)
    {
        EXPECT_LT(PowerProbe::syntheticPowerMilliwattsFor(dpid), kOneMegawattInMilliwatts)
            << "dpid " << dpid;
    }
}

TEST(SyntheticPowerTest, IsStableAcrossPollsForTheSameSwitch)
{
    // The status worker polls every few seconds and the Energy-Saving application compares
    // readings over time. A value that is re-rolled each poll makes any comparison meaningless,
    // which is what the old RNG did. The useful signal is a switch dropping to 0 when powered
    // off -- handled by the caller's !isUp branch -- not per-tick jitter.
    const uint64_t first = PowerProbe::syntheticPowerMilliwattsFor(1);
    for (int poll = 0; poll < 50; ++poll)
    {
        EXPECT_EQ(PowerProbe::syntheticPowerMilliwattsFor(1), first) << "changed on poll " << poll;
    }
}

TEST(SyntheticPowerTest, SwitchesAreSpreadAcrossTheBandNotBunchedAtOneEnd)
{
    // This assertion earned its strictness. An earlier version only required the ten values to be
    // *distinct*, which a seed of `std::hash<uint64_t>{}(dpid)` satisfied -- identity on libstdc++,
    // so the switches reported 30001, 30002, ... 30010 mW: ten distinct numbers that are all
    // 30.0 W. The test passed and the feature was useless. Distinctness in milliwatts is not the
    // property worth pinning; being spread out at a resolution anyone would notice is.
    std::set<uint64_t> distinctWatts;
    uint64_t lowest = UINT64_MAX;
    uint64_t highest = 0;
    for (uint64_t dpid : kSwitchDpids)
    {
        const uint64_t watts = PowerProbe::syntheticPowerMilliwattsFor(dpid) / kOneWattInMilliwatts;
        distinctWatts.insert(watts);
        lowest = std::min(lowest, watts);
        highest = std::max(highest, watts);
    }

    EXPECT_EQ(distinctWatts.size(), kSwitchDpids.size())
        << "the ten switches must differ by whole watts, not by milliwatts";
    EXPECT_GE(highest - lowest, 30u)
        << "the ten draws span only " << highest - lowest << " W (" << lowest << ".." << highest
        << "), which is bunched at one end of a 30-150 W band";
}

TEST(SyntheticPowerTest, AnUnexpectedDpidStillYieldsSomethingPlausible)
{
    // dpid 0 is what an unparsed or defaulted field leaves behind, and the Intent Translator
    // reaches getSingleSwitchPowerReport with whatever the graph holds. No seed may escape the
    // band -- a plausibility guarantee that holds only for the topology's ten dpids would be a
    // guarantee about the test data, not about the function.
    for (uint64_t dpid : {uint64_t{0}, uint64_t{999}, ~uint64_t{0}})
    {
        const uint64_t mW = PowerProbe::syntheticPowerMilliwattsFor(dpid);
        EXPECT_GE(mW, 30 * kOneWattInMilliwatts) << "dpid " << dpid;
        EXPECT_LE(mW, 150 * kOneWattInMilliwatts) << "dpid " << dpid;
    }
}
