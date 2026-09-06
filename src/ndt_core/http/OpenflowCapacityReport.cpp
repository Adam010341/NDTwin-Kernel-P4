// [Co-developed with claude code -- Adam]
//
// W17: the numbers GET /ndt/get_openflow_capacity serves, each with the provenance that makes it
// worth serving. The reasoning is in the header; this file is the mechanism.
//
// It is a separate translation unit from HttpSession.cpp on purpose. HttpSession.cpp costs about
// 1.6 GB and a hundred CPU-seconds to compile on this laptop, and the mutation gate
// (tests/shell/mutate_capacity_reads_running_artifact.sh) rebuilds the code it mutates once per
// mutation -- ten rebuilds of HttpSession.cpp is how a gate becomes a thing nobody runs.

#include "ndt_core/http/OpenflowCapacityReport.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>

namespace ofcapacity
{

const char* const kFlowEntryTable = "MyIngress.ipv4_lpm";
const char* const kFiveTupleTable = "MyIngress.flow_5tuple";

std::vector<std::string>
splitNulSeparated(const std::string& raw)
{
    std::vector<std::string> out;
    std::string current;
    for (const char c : raw)
    {
        if (c == '\0')
        {
            if (!current.empty())
            {
                out.push_back(current);
            }
            current.clear();
            continue;
        }
        current.push_back(c);
    }
    if (!current.empty())
    {
        out.push_back(current);
    }
    return out;
}

// Matched on the basename prefix so that `simple_switch`, `simple_switch_grpc` and a locally
// built /usr/local/bmv2-fast/bin/simple_switch_grpc -- which is what `ndt status` reports on this
// laptop -- all count, and so that no full path has to be guessed.
bool
isBmv2Argv0(const std::string& argv0)
{
    const std::string base = std::filesystem::path(argv0).filename().string();
    return base.rfind("simple_switch", 0) == 0;
}

// The last argv element ending in `.json`. bmv2 takes the compiled pipeline as its final
// positional argument; any other .json on that command line would have to be an option value, so
// "last" is the rule -- the same one the 2026-09-06 §X2 measurement used when it read the argv of
// the live fabric and found .../p4_src/build/ndtwin_switch.json there.
std::optional<std::string>
pipelineJsonInArgv(const std::vector<std::string>& argv)
{
    if (argv.empty() || !isBmv2Argv0(argv.front()))
    {
        return std::nullopt;
    }
    for (auto it = argv.rbegin(); it != argv.rend(); ++it)
    {
        if (it->size() > 5 && it->compare(it->size() - 5, 5, ".json") == 0)
        {
            return *it;
        }
    }
    return std::nullopt;
}

ArtifactSource
locateRunningPipeline(const std::string& procRoot, const std::string& fallbackPath)
{
    ArtifactSource src;
    std::vector<std::string> found;
    std::vector<std::string> pids;

    std::error_code ec;
    try
    {
        // Processes come and go while this walks, so every step is written to tolerate one
        // vanishing: a bad `procRoot` leaves the iterator equal to end(), an unreadable
        // `cmdline` is skipped, and an increment that trips over a process exiting mid-walk is
        // caught below. What is found is reported; a scan that failed halfway is not allowed to
        // fail the endpoint.
        for (std::filesystem::directory_iterator it(procRoot, ec), last; it != last; ++it)
        {
            const std::string name = it->path().filename().string();
            if (name.empty() || !std::all_of(name.begin(), name.end(), [](unsigned char c) {
                    return std::isdigit(c) != 0;
                }))
            {
                continue;
            }

            std::ifstream in(it->path() / "cmdline", std::ios::binary);
            if (!in)
            {
                continue;
            }
            const std::string raw((std::istreambuf_iterator<char>(in)),
                                  std::istreambuf_iterator<char>());
            const auto pipeline = pipelineJsonInArgv(splitNulSeparated(raw));
            if (!pipeline.has_value())
            {
                continue;
            }
            if (std::find(found.begin(), found.end(), *pipeline) == found.end())
            {
                found.push_back(*pipeline);
                pids.push_back(name);
            }
        }
    }
    catch (const std::filesystem::filesystem_error&)
    {
    }

    if (!found.empty())
    {
        // Sorted, so the answer does not depend on readdir order: two identical fabrics must not
        // report different `source`s, and a disagreement must not change which artifact is named
        // depending on which switch the kernel happened to see first.
        std::vector<std::size_t> order(found.size());
        for (std::size_t i = 0; i < order.size(); ++i)
        {
            order[i] = i;
        }
        std::sort(order.begin(), order.end(), [&found](std::size_t a, std::size_t b) {
            return found[a] < found[b];
        });

        src.path = found[order.front()];
        src.how = "argv of a running bmv2 switch (pid " + pids[order.front()] + ")";
        for (std::size_t i = 1; i < order.size(); ++i)
        {
            src.disagreeing.push_back(found[order[i]]);
        }
        return src;
    }

    if (!fallbackPath.empty() && std::filesystem::exists(fallbackPath, ec))
    {
        src.path = fallbackPath;
        src.how = "build artifact -- no running bmv2 switch names a pipeline on its command "
                  "line, so this is what a switch would load, not what one has loaded";
    }
    return src;
}

std::map<std::string, long long>
pipelineTableSizes(const nlohmann::json& artifact)
{
    std::map<std::string, long long> sizes;
    if (!artifact.is_object() || !artifact.contains("pipelines") ||
        !artifact.at("pipelines").is_array())
    {
        return sizes;
    }
    for (const auto& pipeline : artifact.at("pipelines"))
    {
        if (!pipeline.is_object() || !pipeline.contains("tables") ||
            !pipeline.at("tables").is_array())
        {
            continue;
        }
        for (const auto& table : pipeline.at("tables"))
        {
            if (!table.is_object() || !table.contains("name") || !table.at("name").is_string() ||
                !table.contains("max_size") || !table.at("max_size").is_number_integer())
            {
                continue;
            }
            sizes[table.at("name").get<std::string>()] = table.at("max_size").get<long long>();
        }
    }
    return sizes;
}

// The view is `[{dpid, flows:{"<dpid>":[...]}}]`. On the P4 plane every row arrives with
// `table_id: 0` whatever P4 table it came from (ryu_flow_stats.py:158): the proxy reads every
// table in one P4Runtime Read and the table name does not survive the conversion to Ryu's shape.
// So this is the switch's total across all its tables, not one table's -- which is why the
// response says so in `note` instead of letting the caller assume otherwise.
std::map<uint64_t, long long>
rowsPerDpid(const nlohmann::json& tables)
{
    std::map<uint64_t, long long> rows;
    if (!tables.is_array())
    {
        return rows;
    }
    for (const auto& sw : tables)
    {
        if (!sw.is_object() || !sw.contains("dpid") || !sw.at("dpid").is_number())
        {
            continue;
        }
        const uint64_t dpid = sw.at("dpid").get<uint64_t>();
        long long count = 0;
        if (sw.contains("flows") && sw.at("flows").is_object())
        {
            for (const auto& table : sw.at("flows").items())
            {
                if (table.value().is_array())
                {
                    count += static_cast<long long>(table.value().size());
                }
            }
        }
        rows[dpid] = count;
    }
    return rows;
}

nlohmann::json
buildBmv2Plane(const std::vector<uint64_t>& dpids,
               const ArtifactSource& src,
               const nlohmann::json& artifact,
               const std::map<uint64_t, long long>& rows)
{
    nlohmann::json plane;
    plane["plane"] = "bmv2";
    plane["flow_entry_table"] = kFlowEntryTable;

    const auto sizes = pipelineTableSizes(artifact);
    const auto flowTable = sizes.find(kFlowEntryTable);
    const bool haveMax = flowTable != sizes.end();

    if (src.path.empty())
    {
        plane["source"] = nullptr;
        plane["source_kind"] = nullptr;
        plane["why"] = "no bmv2 pipeline artifact could be located: no running simple_switch "
                       "process names one on its command line, and the build artifact is not "
                       "readable from the kernel's working directory";
    }
    else
    {
        plane["source"] = src.path + " max_size";
        plane["source_kind"] = src.how;
        if (!src.disagreeing.empty())
        {
            plane["source_disagreement"] = src.disagreeing;
            plane["why"] = "running bmv2 switches have loaded more than one pipeline artifact, so "
                           "the fabric is not uniform; the numbers below describe " +
                           src.path + " only";
        }
        else if (!haveMax)
        {
            plane["why"] = "the artifact at " + src.path + " declares no table named " +
                           std::string(kFlowEntryTable) +
                           ", so this kernel cannot say what it holds: the pipeline was renamed, "
                           "or it is not the one the P4 proxy writes into";
        }
    }

    nlohmann::json tables = nlohmann::json::array();
    for (const char* name : {kFlowEntryTable, kFiveTupleTable})
    {
        const auto found = sizes.find(name);
        tables.push_back(
            nlohmann::json{{"name", name},
                           {"max_entries", found == sizes.end() ? nlohmann::json(nullptr)
                                                                : nlohmann::json(found->second)}});
    }
    plane["tables"] = tables;
    plane["max_entries"] = haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);

    nlohmann::json perSwitch = nlohmann::json::array();
    for (const uint64_t dpid : dpids)
    {
        nlohmann::json one;
        one["dpid"] = dpid;
        one["max_entries"] = haveMax ? nlohmann::json(flowTable->second) : nlohmann::json(nullptr);

        const auto row = rows.find(dpid);
        if (row == rows.end())
        {
            // Unknown, not zero. A switch nothing has polled yet and a switch with an empty table
            // are different facts, and answering "all 1024 are free" for the first is the same
            // species of confident wrong number this whole endpoint was rewritten to stop making.
            one["in_use"] = nullptr;
            one["available"] = nullptr;
            one["why"] = "this switch has no entry in get_switch_openflow_table_entries yet, so "
                         "its occupancy is unknown -- not zero";
        }
        else
        {
            one["in_use"] = row->second;
            one["available"] = haveMax ? nlohmann::json(flowTable->second - row->second)
                                       : nlohmann::json(nullptr);
        }
        perSwitch.push_back(std::move(one));
    }
    plane["per_switch"] = perSwitch;

    plane["note"] =
        "max_entries is the compiled pipeline's own max_size for " + std::string(kFlowEntryTable) +
        ", read from the artifact named in source. in_use is how many rows that switch reports to "
        "get_switch_openflow_table_entries across every table it holds -- a P4 row carries no "
        "table name by the time it reaches the kernel -- and it includes the fabric's own host "
        "routes, one /32 per host (128 of them at the 128-host scale, measured 2026-09-06), which "
        "is why a freshly booted switch is not at 0. available is max_entries - in_use and is "
        "therefore a lower bound on what " +
        std::string(kFlowEntryTable) +
        " will still accept. Past it, bmv2 answers StatusCode.UNKNOWN with empty details and the "
        "P4 proxy relays {\"status\":\"error\"} under HTTP 200.";

    return plane;
}

nlohmann::json
buildCapacityReport(nlohmann::json vendorCatalogue,
                    const std::vector<uint64_t>& bmv2Dpids,
                    const ArtifactSource& src,
                    const nlohmann::json& artifact,
                    const nlohmann::json& tableView)
{
    if (!vendorCatalogue.is_object())
    {
        vendorCatalogue = nlohmann::json::object();
    }

    // The catalogue keys stay exactly where they were -- OVS, BrocadeICX7250, HPE5520 at the top
    // level -- because that is what the developer manual documents and what the website mirror
    // shows. Only `source` is added, and only to say that nobody measured them here.
    for (auto& brand : vendorCatalogue.items())
    {
        if (brand.value().is_object())
        {
            brand.value()["source"] = "vendor table";
        }
    }

    // `bmv2` sits beside the brands rather than under a second nesting level, because to a
    // caller asking "what can this switch hold" it IS a switch family. A catalogue that grew its
    // own "bmv2" key would be overwritten here, and that is the right way round -- a figure read
    // off the running pipeline beats a figure somebody typed -- but it would be silent, so it is
    // written down here rather than discovered later.
    if (!bmv2Dpids.empty())
    {
        vendorCatalogue["bmv2"] = buildBmv2Plane(bmv2Dpids, src, artifact, rowsPerDpid(tableView));
    }
    return vendorCatalogue;
}

nlohmann::json
readCapacityReport(const CapacitySources& sources,
                   const std::vector<uint64_t>& bmv2Dpids,
                   const nlohmann::json& tableView,
                   ReadOutcome* outcome)
{
    ReadOutcome result;

    nlohmann::json catalogue = nlohmann::json::object();
    {
        std::ifstream file(sources.vendorCataloguePath);
        if (file)
        {
            try
            {
                file >> catalogue;
                result.vendorCatalogueRead = true;
            }
            catch (const nlohmann::json::exception&)
            {
                catalogue = nlohmann::json::object();
            }
        }
    }

    ArtifactSource src;
    nlohmann::json artifact; // null unless it parses
    if (!bmv2Dpids.empty())
    {
        // Only looked for when the topology actually has bmv2 switches: on an OVS-only
        // deployment, walking /proc to answer a question nobody asked is cost with no claim
        // behind it.
        src = locateRunningPipeline(sources.procRoot, sources.pipelineFallback);
        if (!src.path.empty())
        {
            std::ifstream in(src.path);
            if (in)
            {
                try
                {
                    in >> artifact;
                    result.pipelineArtifactRead = true;
                }
                catch (const nlohmann::json::exception&)
                {
                    artifact = nlohmann::json();
                }
            }
        }
    }

    if (outcome != nullptr)
    {
        *outcome = result;
    }
    return buildCapacityReport(std::move(catalogue), bmv2Dpids, src, artifact, tableView);
}

} // namespace ofcapacity
