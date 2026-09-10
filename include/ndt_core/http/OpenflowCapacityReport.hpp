// [Co-developed with claude code -- Adam]
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

/**
 * @brief What GET /ndt/get_openflow_capacity answers, and where each number came from.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ### Why this exists (W17)
 *
 * The endpoint used to serve `doc/2026-01-02_OpenflowCapacity.json` verbatim: three switch
 * brands -- OVS 1000000, BrocadeICX7250 3072, HPE5520 65535 -- and not one word about the data
 * plane this deployment actually runs. Measured 2026-09-06
 * (`scratch/overnight-2026-09-05/rounds/06-X-experiments.md` §X2, on the live 10-switch bmv2
 * fabric): a bmv2 switch takes **1024** entries in `MyIngress.ipv4_lpm`, and the fabric's own
 * host routes already hold one per host, so at the 128-host scale a caller gets **896** -- the
 * same 896 whether it installs one entry every 50 ms for fifteen minutes or 2000 at once, which
 * is how that round established the number is a table ceiling and not a rate limit. The smallest
 * figure the catalogue offered was 3072, **3.4x** the truth, and anyone planning against it hits
 * the wall at 896, where bmv2 answers `StatusCode.UNKNOWN` with empty details and the proxy can
 * only relay `{"status":"error"}` under HTTP 200.
 *
 * ### The rule everything here is built on
 *
 * **A capacity number is only worth serving if it names its own provenance**, so every block
 * carries `source`. The catalogue rows say `vendor table`: nobody measured them on this
 * deployment, and serving them as if somebody had is the defect one level up. The bmv2 block
 * reads `max_size` out of the compiled pipeline **a running `simple_switch*` process has
 * loaded**, located through that process's own argv -- so editing `size = 1024;` in
 * `ndtwin_switch.p4` and recompiling moves the number this endpoint reports without a line of
 * C++ changing. When no switch is running, the build artifact is read instead and `source_kind`
 * says so in those words: "what a switch would load" is a different claim from "what a switch
 * has loaded", and the difference is the caller's to weigh, not ours to hide.
 *
 * Nothing here falls back to a literal. An artifact that cannot be read, or that has no table by
 * the name the proxy writes into, yields `max_entries: null` and a `why` -- because a plausible
 * wrong number is exactly the failure this endpoint already had.
 */
namespace ofcapacity
{

/// The table `p4_client.py` inserts, modifies and deletes flow entries in (`p4_client.py:846`,
/// `:926`, `:975`). A name, not a size: the size is always read from the artifact.
extern const char* const kFlowEntryTable;

/// The table the 5-tuple path uses (`p4_client.py:729`), reported alongside with the same
/// provenance because a caller that installs 5-tuple rules is spending a second budget.
extern const char* const kFiveTupleTable;

/// Where a pipeline artifact was found, and how.
struct ArtifactSource
{
    /// The path that was read. Empty when nothing was found.
    std::string path;
    /// Human-readable provenance, served as `source_kind`.
    std::string how;
    /// Artifacts other running switches had loaded, when they disagreed with `path`. Non-empty
    /// means half the fabric is running a different pipeline from the other half.
    std::vector<std::string> disagreeing;
};

/// argv of one process as `/proc/<pid>/cmdline` stores it: NUL-separated, usually NUL-terminated.
std::vector<std::string> splitNulSeparated(const std::string& raw);

/// True when argv[0] names a bmv2 switch binary.
bool isBmv2Argv0(const std::string& argv0);

/// The pipeline JSON in one argv, or nullopt when this is not a bmv2 switch.
std::optional<std::string> pipelineJsonInArgv(const std::vector<std::string>& argv);

/**
 * @brief Find the pipeline artifact a running bmv2 has loaded.
 *
 * @param procRoot     `/proc` in production, a fixture tree under test. Reading `cmdline` is the
 *                     whole interaction: nothing here signals, stops or otherwise touches a
 *                     process.
 * @param fallbackPath Read only when no running switch was found. May be empty.
 * @return An `ArtifactSource` whose `path` is empty when there is neither.
 */
ArtifactSource locateRunningPipeline(const std::string& procRoot,
                                     const std::string& fallbackPath);

/// `max_size` per table name, over every pipeline in a bmv2 JSON artifact.
std::map<std::string, long long> pipelineTableSizes(const nlohmann::json& artifact);

/// Rows per dpid in the `get_switch_openflow_table_entries` view.
std::map<uint64_t, long long> rowsPerDpid(const nlohmann::json& tables);

/// The bmv2 half of the response. `artifact` may be null when it could not be read.
nlohmann::json buildBmv2Plane(const std::vector<uint64_t>& dpids,
                              const ArtifactSource& src,
                              const nlohmann::json& artifact,
                              const std::map<uint64_t, long long>& rows);

/// The whole response: the catalogue with each brand tagged `source`, plus the bmv2 plane when
/// the loaded topology has bmv2 switches.
nlohmann::json buildCapacityReport(nlohmann::json vendorCatalogue,
                                   const std::vector<uint64_t>& bmv2Dpids,
                                   const ArtifactSource& src,
                                   const nlohmann::json& artifact,
                                   const nlohmann::json& tableView);

/// Everything the report needs from the filesystem, in one place so a test can point it
/// somewhere else. The defaults are relative to the kernel's working directory (`build/`), which
/// is where every other path in HttpSession is anchored.
struct CapacitySources
{
    std::string vendorCataloguePath = "../doc/2026-01-02_OpenflowCapacity.json";
    std::string procRoot = "/proc";
    std::string pipelineFallback = "../p4_proxy/p4_src/build/ndtwin_switch.json";
};

/// What `readCapacityReport` managed to read. The report itself says the same things in JSON;
/// this exists because the kernel log is where an operator looks when a response comes back thin,
/// and it reports the actual result of the open rather than a second guess at it.
struct ReadOutcome
{
    bool vendorCatalogueRead = false;
    bool pipelineArtifactRead = false;
};

/// Reads the two files and builds the report. `tableView` and `bmv2Dpids` come from the caller's
/// collaborators, which this layer deliberately does not know about.
nlohmann::json readCapacityReport(const CapacitySources& sources,
                                  const std::vector<uint64_t>& bmv2Dpids,
                                  const nlohmann::json& tableView,
                                  ReadOutcome* outcome = nullptr);

} // namespace ofcapacity
