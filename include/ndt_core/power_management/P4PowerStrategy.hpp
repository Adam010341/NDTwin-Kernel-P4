// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- Phase 7: real operations via the manifest helper.
#pragma once

#include "ndt_core/power_management/IPowerStrategy.hpp"

#include <chrono>
#include <map>
#include <mutex>
#include <optional>

class P4PowerStrategy : public IPowerStrategy
{
public:
    P4PowerStrategy() = default;
    virtual ~P4PowerStrategy() = default;

    OpResult powerOn(Graph::vertex_descriptor node, const std::string& swName, uint64_t dpid, TopologyAndFlowMonitor* topoMonitor) override;
    OpResult powerOff(Graph::vertex_descriptor node, const std::string& swName, TopologyAndFlowMonitor* topoMonitor) override;

    const char* describe() const override { return "P4/bmv2"; }

    /// Offers one liveness "this switch is serving" verdict to the distrust bookkeeping, and
    /// answers whether the verdict is entitled to move the graph.
    ///
    /// @param swName    the switch the verdict is about.
    /// @param observedAt when the PROBE BEHIND the verdict was taken -- not when it was read.
    ///        nullopt when the payload did not say.
    /// @return true when the verdict may be written, and the distrust window (if any) has just
    ///         been closed by it; false when the verdict rests on a reading of the past.
    ///
    /// [Co-developed with claude code -- Adam] -- FINDINGS #80.
    /// The parameter is the probe's own time because that is the whole distinction. The proxy
    /// caches `probe_ok` and serves it with a `probe_age_s`; a kill does not invalidate the
    /// cache, so the first Up after a kill is routinely a probe from before it. Reading the
    /// verdict at "now" would date every reading to the moment it was collected, which is
    /// exactly how a stale cache launders itself into current evidence.
    ///
    /// Not a query: it also RECORDS. A verdict that postdates the kill is the event the window
    /// was waiting for, and having the same call both judge and close it is what stops the two
    /// drifting apart.
    ///
    /// A switch this strategy has not stopped has no record, so every verdict about it is
    /// accepted -- including an untimed one. Nothing is being distrusted, so there is nothing
    /// for a timestamp to settle, and refusing here would stop the 1 Hz worker writing up for
    /// the whole fabric.
    bool acceptLivenessUp(const std::string& swName,
                          std::optional<std::chrono::steady_clock::time_point> observedAt);

protected:
    /// The shell seam, and the whole test surface: both power operations are command
    /// sequences, so a subclass that records commands instead of running them can assert
    /// what would have been executed. Returns whether the command exited 0 -- it was void
    /// once, which is how a failed power action reported success.
    virtual bool executeSystemCommand(const std::string& cmd);

    /// [Co-developed with claude code -- Adam]
    /// The clock seam. Exists so a test can age a power-off past the distrust window below
    /// without sleeping through it; production has exactly one implementation.
    virtual std::chrono::steady_clock::time_point now() const;

    /// 🔴 THERE IS NO TIME CONSTANT HERE ANY MORE. FINDINGS #80.
    ///
    /// [Co-developed with claude code -- Adam]
    /// This used to be `kPostPowerOffDistrustWindow{15}`, and its own derivation is what
    /// retired it: "after the kill the 1 Hz worker answers Up from the proxy's still-cached
    /// `probe_ok`, then Unknown until the last LLDP beacon ages past kLldpFreshSeconds (12s),
    /// so the graph can carry a wrong `isUp` for at most 12s plus a tick; 15s is that bound
    /// with margin." Every clause of that is a claim about an OBSERVATION going stale -- and a
    /// timer cannot know whether an observation has been refreshed. It can only assume.
    ///
    /// What the assumption bought, measured on the live fabric (FIX-POLL-RESURRECT §3.3.2,
    /// 18 of 18 trials): `is_up` went 0->1 within 0.3-1.5s of every kill and held for 8-13s.
    /// The window covered that interval by outlasting it. At t+15s it stood down whether or not
    /// anything had looked at the switch since -- so a fabric whose proxy had stopped probing
    /// altogether got its graph trusted again on schedule, with no evidence at all.
    ///
    /// The bound is now EVIDENCE: the window opens when this strategy confirms a stop, and
    /// closes only when something observes the switch serving AFTERWARDS -- the helper's own
    /// `on` exiting 0, or a liveness probe TAKEN AFTER THE KILL round-tripping (acceptLivenessUp
    /// below). A probe taken before the kill and delivered after it is the stale cache itself
    /// and closes nothing.
    ///
    /// No upper bound was kept, and that is a decision rather than an omission. An upper bound
    /// is precisely the mechanism this replaces: its only effect is to declare the graph
    /// trustworthy in the one situation where nothing has corroborated it. The failure mode of
    /// having none is bounded and loud -- a power-on for a switch nobody ever observed again
    /// runs the helper, and if the process is in fact alive the helper refuses to start a second
    /// instance and returns 500. That is the direction this file already chose (see powerOn's
    /// note on out-of-band restarts): a loud wrong answer in place of a silent one.

private:
    /// True while this strategy has stopped @p swName and nothing has observed it serving since,
    /// so the graph's `reachable` for it is still the pre-kill reading.
    ///
    /// [Co-developed with claude code -- Adam]
    /// The name is kept -- there is still a window, and powerOn's guard still reads exactly this
    /// call -- but what closes it is an observation, not a clock. See the note where the time
    /// constant used to be.
    bool poweredOffWithinDistrustWindow(const std::string& swName) const;

    /// Opens the distrust window for @p swName; called only where a stop was confirmed.
    void notePowerOff(const std::string& swName);

    /// Closes it again, once a real process is running under that name.
    void clearPowerOffRecord(const std::string& swName);

    /// Switch name -> when this strategy last confirmed that switch stopped.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Keyed by name, not by vertex descriptor: descriptors are indices into a graph that is
    /// rebuilt when the topology changes, so a stale entry could come to name a different
    /// switch. The name is what both power calls are handed, and it does not get recycled.
    ///
    /// Guarded because this is the first state the strategy has ever held: powerOn and powerOff
    /// are reached from HTTP session threads, and one process-wide strategy object serves all of
    /// them (DeviceConfigurationAndPowerManager::m_p4PowerStrategy).
    mutable std::mutex m_lastPowerOffMutex;
    std::map<std::string, std::chrono::steady_clock::time_point> m_lastPowerOffAt;
};
