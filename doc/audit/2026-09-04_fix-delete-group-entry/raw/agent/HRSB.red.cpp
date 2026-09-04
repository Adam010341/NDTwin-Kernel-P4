// [Co-developed with claude code -- Adam]
#include "ndt_core/routing_management/HttpRoutingStrategyBase.hpp"

#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <chrono>
#include <sstream>
#include <string>
#include <thread>

using json = nlohmann::json;

namespace
{

/// What curl's stdout told us.
///
/// [Co-developed with claude code -- Adam]
/// `statusLinePresent` is new, and it is the fix for doc/KNOWN-ISSUES.md B-2b's misattribution.
/// The old version returned `{output, 0}` for two situations that mean opposite things:
///   - curl ran, could not connect, and wrote `000` -- the component really is unreachable;
///   - curl produced nothing at all -- it never ran, so nothing was ever asked of the component.
/// Collapsing both to status 0 is what let a broken command line be reported as a dead controller.
/// -w '\n%{http_code}' is written by curl on every completed invocation, connection failures
/// included, so its absence is a reliable signal that curl itself did not run.
struct CurlOutput
{
    std::string body;
    int httpStatus = 0;
    bool statusLinePresent = false;
};

CurlOutput
splitBodyAndStatus(const std::string& output)
{
    const auto lastNewline = output.find_last_of('\n');
    if (lastNewline == std::string::npos)
    {
        // No status line: curl itself failed to run, or produced nothing.
        return {output, 0, false};
    }

    const std::string statusText = output.substr(lastNewline + 1);
    const std::string body = output.substr(0, lastNewline);

    int status = 0;
    try
    {
        status = std::stoi(statusText);
    }
    catch (const std::exception&)
    {
        // Trailing line was not a number, so treat it as part of the body.
        return {output, 0, false};
    }
    return {body, status, true};
}

/// Trims to a length that is useful in a log line without dumping a whole response.
std::string
briefly(const std::string& text, size_t limit = 200)
{
    std::string out = text;
    // Collapse newlines so a multi-line error body stays on one log line.
    for (char& c : out)
    {
        if (c == '\n' || c == '\r')
        {
            c = ' ';
        }
    }
    if (out.size() > limit)
    {
        out.resize(limit);
        out += "...";
    }
    return out;
}

} // namespace

utils::CommandOutcome
HttpRoutingStrategyBase::executeArgv(const std::vector<std::string>& argv)
{
    return utils::execArgv(argv);
}

OpResult
HttpRoutingStrategyBase::post(const std::string& path, const json& body, const char* operation)
{
    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-2b. This was one std::ostringstream producing a shell command line,
    // with body.dump() interpolated between two single quotes. json::dump() escapes what JSON
    // needs escaped, and `'` is not a JSON metacharacter, so it went through untouched: a match
    // value containing a quote ended the quoting and everything after it was read by /bin/sh as
    // commands. Since the northbound API listens on 0.0.0.0:8000 with no authentication and match
    // values come straight from it, that was remote command execution, not a formatting bug.
    //
    // An argument vector has no such reading. Each element is one argument to execvp, so a quote,
    // a semicolon, a newline, `$(...)` and a backtick are all just bytes inside the body. Note
    // this is not "escaping done right" -- there is no character table here to get wrong, which is
    // the property that makes it a fix rather than a patch. -w still asks for the status on its
    // own line; --max-time still bounds a hung controller.
    //
    // The one subtlety worth stating: "\\n%{http_code}" keeps its backslash-n. The shell used to
    // strip the single quotes and hand curl a literal backslash followed by 'n', which curl itself
    // turns into a newline. Passing an actual newline here instead would change curl's output
    // shape and break splitBodyAndStatus.
    const std::vector<std::string> argv = {"curl",
                                           "-s",
                                           "-w",
                                           "\\n%{http_code}",
                                           "--max-time",
                                           std::to_string(REQUEST_TIMEOUT_SECONDS),
                                           "-X",
                                           "POST",
                                           "http://" + apiUrl() + path,
                                           "-H",
                                           "Content-Type: application/json",
                                           "-d",
                                           body.dump()};

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "execArgv: {}", utils::describeArgv(argv));

    const utils::CommandOutcome outcome = executeArgv(argv);
    const CurlOutput curl = splitBodyAndStatus(outcome.output);

    // [Co-developed with claude code -- Adam]
    // The honesty half of B-2b, and the half that is not fixed by removing the shell. Whenever the
    // request did not leave this host, the verdict must name this host. It used to name the
    // component -- "no response from <component> at <url> within 5s" -- for causes the component
    // had no part in, and round 4 measured that a genuinely dead controller produced that exact
    // sentence, so the log could not tell the two apart. Naming the local cause is what makes the
    // message actionable; the status code (500, not 502) is what makes it actionable to a program.
    if (!outcome.ran)
    {
        auto result = OpResult::notSent(
            std::string("this kernel could not run curl, so the ") + describe() + " at " +
            apiUrl() + " was never asked: " + utils::describeCommandStatus(outcome.status));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return result;
    }

    if (!curl.statusLinePresent)
    {
        // curl writes the -w line on every completed invocation, connection failures included, so
        // its absence means curl did not complete. Exit 127 is the common cause (not installed).
        auto result = OpResult::notSent(
            std::string("curl produced no status line, so the ") + describe() + " at " + apiUrl() +
            " was never asked: " + utils::describeCommandStatus(outcome.status, "curl"));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return result;
    }

    const std::string& responseBody = curl.body;
    const int status = curl.httpStatus;

    if (status == 0)
    {
        // Now unambiguous: curl ran, reported %{http_code} == 000, and that means it really could
        // not get an answer. This sentence has earned the right to name the component.
        auto result = OpResult::unreachable(
            std::string("no response from ") + describe() + " at " + apiUrl() +
            " within " + std::to_string(REQUEST_TIMEOUT_SECONDS) + "s");
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    if (status < 200 || status >= 300)
    {
        auto result = OpResult::failure(
            status,
            std::string(describe()) + " returned HTTP " + std::to_string(status) +
                (responseBody.empty() ? "" : ": " + briefly(responseBody)));
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    // Some proxies answer 200 with {"status":"error"} in the body. Ryu does not, but the P4
    // proxy agent does, so a 2xx alone is not proof of success.
    if (!responseBody.empty())
    {
        try
        {
            const auto parsed = json::parse(responseBody);
            if (parsed.is_object() && parsed.contains("status") &&
                parsed["status"].is_string() &&
                parsed["status"].get<std::string>() == "error")
            {
                auto result = OpResult::failure(
                    status,
                    std::string(describe()) + " reported an error in a " +
                        std::to_string(status) + " response: " + briefly(responseBody));
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "{} failed: {}",
                                   operation,
                                   result.message);
                return result;
            }
        }
        catch (const json::exception&)
        {
            // Not JSON. Ryu's success replies are not always JSON, so this is not an error.
        }
    }

    return OpResult::success(status);
}

// [Co-developed with claude code -- Adam] F-13.
std::pair<OpResult, std::string>
HttpRoutingStrategyBase::get(const std::string& path, const char* operation)
{
    // [Co-developed with claude code -- Adam]
    // F-13 wrote this as one std::ostringstream handed to executeCommand(); doc/KNOWN-ISSUES.md
    // B-2b removed that seam in favour of an argument vector handed to execvp. get() is "the read
    // half of post()", so it is built and read exactly the way post() now is: no command line is
    // constructed, and a request that never left this host says so instead of naming the far end.
    const std::vector<std::string> argv = {"curl",
                                           "-s",
                                           "-w",
                                           "\\n%{http_code}",
                                           "--max-time",
                                           std::to_string(REQUEST_TIMEOUT_SECONDS),
                                           "-X",
                                           "GET",
                                           "http://" + apiUrl() + path};

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "execArgv: {}", utils::describeArgv(argv));

    const utils::CommandOutcome outcome = executeArgv(argv);
    const CurlOutput curl = splitBodyAndStatus(outcome.output);

    if (!outcome.ran)
    {
        auto result = OpResult::notSent(
            std::string("this kernel could not run curl, so the ") + describe() + " at " +
            apiUrl() + " was never asked: " + utils::describeCommandStatus(outcome.status));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return {result, curl.body};
    }

    if (!curl.statusLinePresent)
    {
        auto result = OpResult::notSent(
            std::string("curl produced no status line, so the ") + describe() + " at " + apiUrl() +
            " was never asked: " + utils::describeCommandStatus(outcome.status, "curl"));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return {result, curl.body};
    }

    const std::string& responseBody = curl.body;
    const int status = curl.httpStatus;

    if (status == 0)
    {
        auto result = OpResult::unreachable(
            std::string("no response from ") + describe() + " at " + apiUrl() + " within " +
            std::to_string(REQUEST_TIMEOUT_SECONDS) + "s");
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return {result, responseBody};
    }

    if (status < 200 || status >= 300)
    {
        auto result = OpResult::failure(status,
                                        std::string(describe()) + " returned HTTP " +
                                            std::to_string(status) +
                                            (responseBody.empty() ? ""
                                                                  : ": " + briefly(responseBody)));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return {result, responseBody};
    }

    return {OpResult::success(status), responseBody};
}

// --- flow entries -----------------------------------------------------------------

OpResult
HttpRoutingStrategyBase::deleteAnEntry(uint64_t dpid, const json& match, int priority)
{
    json body;
    body["dpid"] = dpid;
    body["match"] = match;

    // A priority of -1 means "delete anything matching", which is the non-strict route.
    // With a priority the strict route removes only the exact entry.
    if (priority == -1)
    {
        return post("/stats/flowentry/delete", body, "delete flow entry (non-strict)");
    }

    body["priority"] = priority;
    return post("/stats/flowentry/delete_strict", body, "delete flow entry (strict)");
}

OpResult
HttpRoutingStrategyBase::installAnEntry(uint64_t dpid,
                                        int priority,
                                        const json& match,
                                        const json& action,
                                        int idleTimeout)
{
    json body;
    body["dpid"] = dpid;
    body["priority"] = priority;
    body["match"] = match;
    body["actions"] = action;
    // -1 is the sentinel for "no timeout"; 0 means the same thing to Ryu but is also the
    // declared default, so both are treated as "omit the field".
    if (idleTimeout != -1 && idleTimeout != 0)
    {
        body["idle_timeout"] = idleTimeout;
    }

    return post("/stats/flowentry/add", body, "install flow entry");
}

OpResult
HttpRoutingStrategyBase::modifyAnEntry(uint64_t dpid,
                                       int priority,
                                       const json& match,
                                       const json& action)
{
    json body;
    body["dpid"] = dpid;
    body["match"] = match;
    body["actions"] = action;

    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md A-4e. This function used to set body["priority"] and then post to the
    // non-strict route -- the two lines contradicting each other, forty lines below a delete that
    // gets the same decision right. OFPFC_MODIFY does not compare priority, so the field was
    // carried all the way to the controller and ignored, and the modify landed on whichever entry
    // matched first. Measured on a live fabric: a request naming the caller's own priority-100
    // rule edited the router's priority-10 rule instead (same entry, confirmed by its unchanged
    // duration/n_packets), moved 32 MB of traffic onto the wrong port, and the damage outlived
    // deleting the caller's rule -- because the caller's rule had never been the one edited.
    //
    // The rule is now the same one deleteAnEntry has always used: a priority names an entry, so a
    // request that supplies one gets the strict route and can only ever touch that entry.
    //
    // The -1 branch is the caller who did not name an entry. Nothing in the kernel produces -1 for
    // a modify today (HttpSession::makeModifyJob defaults an absent priority to 0, unlike
    // makeDeleteJob which defaults to -1), so this is the symmetry with delete rather than a live
    // path -- and it is deliberately not "fixed" by changing that default, because FlowJob.hpp
    // records that `ad49347` aligned the flow-table cache with the dispatcher on absent-means-0
    // and de-aligning them again is a second defect, not a fix. An omitted priority therefore
    // still reaches here as 0 and now goes strict, which is safe in a way the old code was not:
    // strict compares the caller's own match as well, so priority 0 with a non-empty match hits
    // the caller's entry or nothing, where non-strict hit anybody's.
    if (priority == -1)
    {
        return post("/stats/flowentry/modify", body, "modify flow entry (non-strict)");
    }

    body["priority"] = priority;
    return post(strictModifyPath(), body, "modify flow entry (strict)");
}

/** @brief The route that modifies exactly the named entry. See the header for why this is virtual.
 *
 * [Co-developed with claude code -- Adam]
 */
const char*
HttpRoutingStrategyBase::strictModifyPath() const
{
    return "/stats/flowentry/modify_strict";
}

// --- group and meter entries -------------------------------------------------------
//
// [Co-developed with claude code -- Adam] doc/KNOWN-ISSUES.md F-13.
//
// All six of these used to be a bare `post`, and every one of them answered 200 for an entry
// that did not exist. The 200 was not invented here -- it was relayed, and relayed faithfully,
// which is why the earlier fix that made the kernel stop discarding OpResult did not change what
// a caller saw. The reason is two layers down and neither layer is lying:
//
//   1. Ryu's ofctl_rest turns the request into an OFPGroupMod/OFPMeterMod and calls
//      `ofctl_utils.send_msg(dp, group_mod, LOG)` -- no barrier, no reply awaited
//      (ryu/lib/ofctl_v1_3.py:1151, :1118). Its `command_method` wrapper then answers
//      `Response(status=200)` with an EMPTY BODY as soon as the method returns
//      (ryu/app/ofctl_rest.py:275-277). The switch has not seen the message yet.
//
//   2. `post` above judges a reply failed only on a non-2xx status or a body containing
//      {"status":"error"}. An empty 200 has neither, so it is a success. Correctly so: there
//      is nothing in that reply to judge.
//
// What the switch does afterwards, per OpenFlow 1.3 (the error codes are in
// ryu/ofproto/ofproto_v1_3.py at the lines named):
//
//   * OFPGC_MODIFY / OFPMC_MODIFY on an id that is not there -> OFPGMFC_UNKNOWN_GROUP (:1032)
//     or OFPMMFC_UNKNOWN_METER (:1081): a real error, delivered asynchronously as an
//     OFPT_ERROR that ofctl_rest never correlates back to the REST request. Nobody sees it.
//   * OFPGC_ADD / OFPMC_ADD on an id that IS there -> OFPGMFC_GROUP_EXISTS (:1020) or
//     OFPMMFC_METER_EXISTS (:1077). Same fate. So the F-13 row's "modify/delete" understates
//     it: add-on-existing is wrong in the same way and in the more dangerous direction, since
//     the caller believes it owns buckets that belong to somebody else.
//   * OFPGC_DELETE / OFPMC_DELETE on an id that is not there -> *no error at all*. The spec
//     makes it a silent no-op at the switch. So for delete there is no asynchronous truth to
//     go and read even in principle: a pre-check is the ONLY way to tell "deleted" from
//     "there was nothing to delete".
//
// Hence the shape of the fix: ask first. `guardedMod` reads the entry's existence out of the
// switch through Ryu's stats routes -- which, unlike the mod routes, do wait for the switch's
// multipart reply (ryu/app/ofctl_rest.py:215-219, via `send_stats_request`) -- and refuses the
// operations whose precondition does not hold.
//
// ⚠️ THIS NARROWS THE WINDOW; IT DOES NOT CLOSE IT. Between the check and the mod another
// writer can create or remove the entry, and then the kernel reports the outcome it verified
// rather than the one that happened. The residual cases are enumerated in the fix-design note
// for F-13. A pre-check turns "always wrong for this input" into "wrong only if someone else
// writes the same id inside one RTT"; the honest end state also needs a post-check, which is a
// second round trip and a separate decision.

namespace
{

/// Reads @p field as an integer id. False when it is absent or is not an integer -- Ryu also
/// accepts names like "ALL" there, and a name is not something this file can look up.
bool
readEntryId(const json& j, const char* field, long long& out)
{
    if (!j.contains(field))
    {
        // Ryu defaults an absent group_id/meter_id to 0 (ofctl_v1_3.py:1132, :1092), so an
        // absent field genuinely names entry 0 rather than being unaddressable.
        out = 0;
        return true;
    }
    if (!j.at(field).is_number_integer())
    {
        return false;
    }
    out = j.at(field).get<long long>();
    return true;
}

/// ⚠️ `is_number_integer()`, not `is_number_unsigned()`. nlohmann stores a value built from a C++
/// `int` as number_INTEGER even when it is positive, and only a value parsed off the wire as a
/// positive literal becomes number_unsigned. Testing for unsigned would therefore answer
/// "unreadable dpid" for half the payloads that reach here and silently downgrade every
/// existence check to Unknown -- a guard that stops guarding, in the one way no assertion about
/// the refusal path would notice. FlowRoutingManager::dispatchByPayloadDpid already reads the
/// same field with .get<uint64_t>(), which accepts both, so this matches it.
bool
readDpid(const json& j, uint64_t& out)
{
    if (!j.contains("dpid") || !j.at("dpid").is_number_integer())
    {
        return false;
    }
    if (j.at("dpid").is_number_integer() && !j.at("dpid").is_number_unsigned() &&
        j.at("dpid").get<long long>() < 0)
    {
        return false;
    }
    out = j.at("dpid").get<uint64_t>();
    return true;
}

} // namespace

HttpRoutingStrategyBase::Existence
HttpRoutingStrategyBase::entryExists(EntryKind kind, uint64_t dpid, long long id)
{
    // ⚠️ /stats/groupdesc/<dpid>/<group_id> exists as a route but IGNORES the group_id on
    // OpenFlow 1.3: ofctl_rest.py:400-401 only forwards it from OF1.5 on, and
    // ofctl_v1_3.get_group_desc (:968) takes no id parameter at all. So the group query asks
    // for the whole list and filters here. The meter query does filter server-side
    // (get_meter_config passes meter_id into OFPMeterConfigStatsRequest, :796), but is read the
    // same way so that one code path covers both and neither can drift.
    const std::string path = (kind == EntryKind::Group)
                                 ? "/stats/groupdesc/" + std::to_string(dpid)
                                 : "/stats/meterconfig/" + std::to_string(dpid) + "/" +
                                       std::to_string(id);
    const char* idField = (kind == EntryKind::Group) ? "group_id" : "meter_id";

    const auto [result, body] = get(path, "check whether the entry exists");
    if (!result.ok)
    {
        return Existence::Unknown;
    }

    // Every early return below is Unknown, never Absent. Absent is the answer that produces a
    // 404, and a shape this code does not recognise is not evidence that the entry is missing.
    json parsed;
    try
    {
        parsed = json::parse(body);
    }
    catch (const json::exception&)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "existence check for dpid {} returned unparseable JSON: {}",
                           dpid,
                           briefly(body));
        return Existence::Unknown;
    }

    // Ryu wraps every stats reply as {"<dpid in decimal>": [ ... ]} (ofctl_utils.wrap_dpid_dict).
    const std::string key = std::to_string(dpid);
    if (!parsed.is_object() || !parsed.contains(key) || !parsed.at(key).is_array())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "existence check for dpid {} returned an unexpected shape: {}",
                           dpid,
                           briefly(body));
        return Existence::Unknown;
    }

    for (const auto& entry : parsed.at(key))
    {
        if (entry.is_object() && entry.contains(idField) && entry.at(idField).is_number_integer() &&
            entry.at(idField).get<long long>() == id)
        {
            return Existence::Present;
        }
    }
    return Existence::Absent;
}

// [Co-developed with claude code -- Adam] Finding #1. RED-RUN STUB: the seam only.
void
HttpRoutingStrategyBase::pauseBeforeReVerify()
{
    std::this_thread::sleep_for(std::chrono::milliseconds(VERIFY_PAUSE_MS));
}

OpResult
HttpRoutingStrategyBase::guardedMod(const json& j,
                                    EntryKind kind,
                                    EntryOp op,
                                    const std::string& path,
                                    const char* operation)
{
    const char* noun = (kind == EntryKind::Group) ? "group" : "meter";
    const char* idField = (kind == EntryKind::Group) ? "group_id" : "meter_id";

    uint64_t dpid = 0;
    long long id = 0;
    const bool addressable = readDpid(j, dpid) && readEntryId(j, idField, id);

    const Existence before = addressable ? entryExists(kind, dpid, id) : Existence::Unknown;
    const std::string named =
        std::string(noun) + " " + std::to_string(id) + " on dpid " + std::to_string(dpid);

    if (op == EntryOp::Add && before == Existence::Present)
    {
        // The switch would answer OFPGMFC_GROUP_EXISTS / OFPMMFC_METER_EXISTS and keep the
        // entry it already has. 409 rather than 400: the request is well formed, the state is
        // not what it assumed, and a caller that deletes first can retry it unchanged.
        auto result = OpResult::failure(409, named + " already exists; ADD would be rejected "
                                                     "by the switch and the existing entry kept")
                          .withOutcome(std::string("no_change_") + noun + "_exists");
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} refused: {}", operation, result.message);
        return result;
    }

    if (op != EntryOp::Add && before == Existence::Absent)
    {
        // 404 shares its status with "no routing strategy for dpid", which is a different
        // not-found; the outcome field is what tells the two apart in the body.
        auto result =
            OpResult::failure(404, "no such " + named + "; nothing was " +
                                       (op == EntryOp::Delete ? "deleted" : "modified"))
                .withOutcome(std::string("no_such_") + noun);
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} refused: {}", operation, result.message);
        return result;
    }

    OpResult result = post(path, j, operation);
    if (!result.ok)
    {
        return result;
    }

    // Ryu's 200 means "forwarded", so the outcome has to say which of the two success stories
    // this is: the precondition was checked and held, or it could not be checked at all.
    if (before == Existence::Unknown)
    {
        return result.withOutcome("unverified");
    }
    switch (op)
    {
    case EntryOp::Add:
        return result.withOutcome("installed");
    case EntryOp::Modify:
        return result.withOutcome("modified");
    case EntryOp::Delete:
        return result.withOutcome("deleted");
    }
    return result;
}

OpResult
HttpRoutingStrategyBase::installAGroupEntry(const json& j)
{
    return guardedMod(j, EntryKind::Group, EntryOp::Add, "/stats/groupentry/add",
                      "install group entry");
}

OpResult
HttpRoutingStrategyBase::deleteAGroupEntry(const json& j)
{
    return guardedMod(j, EntryKind::Group, EntryOp::Delete, "/stats/groupentry/delete",
                      "delete group entry");
}

OpResult
HttpRoutingStrategyBase::modifyAGroupEntry(const json& j)
{
    return guardedMod(j, EntryKind::Group, EntryOp::Modify, "/stats/groupentry/modify",
                      "modify group entry");
}

OpResult
HttpRoutingStrategyBase::installAMeterEntry(const json& j)
{
    return guardedMod(j, EntryKind::Meter, EntryOp::Add, "/stats/meterentry/add",
                      "install meter entry");
}

OpResult
HttpRoutingStrategyBase::deleteAMeterEntry(const json& j)
{
    return guardedMod(j, EntryKind::Meter, EntryOp::Delete, "/stats/meterentry/delete",
                      "delete meter entry");
}

OpResult
HttpRoutingStrategyBase::modifyAMeterEntry(const json& j)
{
    return guardedMod(j, EntryKind::Meter, EntryOp::Modify, "/stats/meterentry/modify",
                      "modify meter entry");
}
