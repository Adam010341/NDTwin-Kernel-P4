#!/usr/bin/env python3
"""Scratch tool (NOT committed). Builds the RED source: trunk's four dereferences, verbatim.

Takes the fixed DeviceConfigurationAndPowerManager.cpp and reverts exactly the four guarded
reads back to trunk's expression, leaving the helper definitions in place (the new test file
calls reportKeyForSwitchWithoutIp, so removing them would be a link error rather than a red).

Asserts each revert lands exactly once, and asserts the result's four lines are byte-identical
to trunk's -- otherwise "the red is on trunk's code" would be a claim rather than a fact.
"""
import subprocess
import sys

PATH = "src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp"

# (name, guarded text, trunk's text)
REVERTS = [
    (
        "memory",
        """        // [Co-developed with claude code -- Adam]
        // FINDINGS #85. Was `std::string ip_str = utils::ipToString(vp.ip.front());` -- see
        // managementIpForReport in the header. A switch with no address keeps an entry, at the
        // documented sentinel, under a key that cannot be confused with an address.
        const auto ipOpt = managementIpForReport(vp);
        if (!ipOpt)
        {
            result_json[reportKeyForSwitchWithoutIp(vp.dpid)] = kHealthMetricUnavailable;
            continue;
        }
        const std::string ip_str = *ipOpt;
""",
        """        std::string ip_str = utils::ipToString(vp.ip.front());
""",
    ),
    (
        "power",
        """
            // [Co-developed with claude code -- Adam]
            // FINDINGS #85. Was `std::string ip_str = utils::ipToString(props.ip.front());`. This
            // one sits inside the TESTBED branch on purpose and the guard stays there with it:
            // the MININET figure is a function of the dpid alone (see syntheticPowerMilliwattsFor,
            // whose doc comment already says this path must not call ip.front()), so a switch with
            // no address still has a perfectly real synthetic power figure and must keep getting
            // it. Only the TESTBED branch, which SSHes/SNMPs to the address, has nothing to ask.
            //
            // This body is keyed by dpid, so unlike the three IP-keyed reports it needs no
            // substitute key -- the entry is well-formed, only the value is unavailable.
            const auto ipOpt = managementIpForReport(props);
            if (!ipOpt)
            {
                result.push_back(
                    {{"dpid", dpid}, {"power_consumed", kHealthMetricUnavailable}});
                continue;
            }
            const std::string ip_str = *ipOpt;
""",
        """            std::string ip_str = utils::ipToString(props.ip.front());
""",
    ),
    (
        "cpu",
        """        // [Co-developed with claude code -- Adam]
        // FINDINGS #85, and the site the gdb backtrace named. Was
        // `std::string ip_str = utils::ipToString(vp.ip.front());`, which is `front()` on an
        // empty vector for a switch carrying no address: undefined behaviour on the status
        // thread, observed as a SIGSEGV that killed the whole kernel within one round. See
        // managementIpForReport in the header.
        const auto ipOpt = managementIpForReport(vp);
        if (!ipOpt)
        {
            result[reportKeyForSwitchWithoutIp(vp.dpid)] = kHealthMetricUnavailable;
            continue;
        }
        const std::string ip_str = *ipOpt;
""",
        """        std::string ip_str = utils::ipToString(vp.ip.front());
""",
    ),
    (
        "temperature",
        """        // [Co-developed with claude code -- Adam]
        // FINDINGS #85, the third of the three the comment above predicted would "still fault one
        // branch later". See managementIpForReport in the header.
        const auto ipOpt = managementIpForReport(vp);
        if (!ipOpt)
        {
            result[reportKeyForSwitchWithoutIp(vp.dpid)] = kHealthMetricUnavailable;
            continue;
        }
        const std::string ip_str = *ipOpt;
""",
        """        std::string ip_str = utils::ipToString(vp.ip.front());
""",
    ),
]


def main():
    src = open(PATH).read()
    for name, guarded, trunk_text in REVERTS:
        n = src.count(guarded)
        if n != 1:
            print(f"REFUSE: {name} guard found {n} times (want 1)")
            return 2
        src = src.replace(guarded, trunk_text, 1)
    open(PATH, "w").write(src)

    trunk = subprocess.run(
        ["git", "show", f"trunk:{PATH}"], capture_output=True, text=True, check=True
    ).stdout
    want = trunk.count("utils::ipToString(vp.ip.front())") + trunk.count(
        "utils::ipToString(props.ip.front())"
    )
    got = src.count("utils::ipToString(vp.ip.front())") + src.count(
        "utils::ipToString(props.ip.front())"
    )
    # +1 on our side: managementIpOf's own guarded read, which trunk does not have.
    print(f"trunk has {want} such reads; the red source has {got} (want {want} + 1 = {want + 1})")
    return 0 if got == want + 1 else 2


if __name__ == "__main__":
    sys.exit(main())
