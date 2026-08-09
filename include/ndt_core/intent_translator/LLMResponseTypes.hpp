#pragma once
#include <nlohmann/json.hpp>
#include <string>

using json = nlohmann::json;

namespace llmResponse
{

// =========================== state enumeration ===========================

enum State
{
    DISCUSSION,
    ANSWER,
    VALIDATION
};

inline constexpr const char*
stateToString(State s)
{
    switch (s)
    {
    case DISCUSSION:
        return "discussion";
    case ANSWER:
        return "answer";
    case VALIDATION:
        return "validation";
    default:
        return "Unknown";
    }
}

inline State
stateFromString(std::string s)
{
    if (s == "discussion")
    {
        return DISCUSSION;
    }
    if (s == "answer")
    {
        return ANSWER;
    }
    if (s == "validation")
    {
        return VALIDATION;
    }
    throw std::runtime_error("unknown state: " + std::string{s});
}

// =========================== task types enumeration ===========================

enum TaskType
{
    DISABLE_SWITCH,
    ENABLE_SWITCH,
    POWEROFF_SWITCH,
    POWERON_SWITCH,
    INSTALL_FLOW_ENTRY,
    MODIFY_FLOW_ENTRY,
    DELETE_FLOW_ENTRY,
    GET_TOP_K_FLOWS,
    GET_SWITCH_CPU_UTILIZATION,   // Display all CPU utlization   
    GET_TOTAL_POWER_CONSUMPTION,    // How much is the total power consumption?
    GET_A_SWITCH_CPU_UTILIZATION,   // What is the CPU utilization of switch s3?
    GET_A_SWITCH_POWER_CONSUMPTION, // How much is the power consumption of switch s4?
    GET_A_LINK_BANDWIDTH_UTILIZATION, // What is the bandwidth utilization of link s1 to s2?
    GET_TOP_K_CONGESTED_LINKS,      // Which links are the top-3 congested links?
    GET_TOP_K_BANDWIDTH_USERS,         // Which IP is using the most bandwidth?
    GET_PATH,                       // List switches on the path from h2 to h7?
    GET_ACTIVE_FLOW_COUNT,          // How many flows are in the network?
    GET_FLOW_ENTRY_COUNT,           // How many flow entries are in switch s5?
    GET_FLOW_ENTRIES,               // List all flow entries in switch s7?

    GET_NETWORK_TOPOLOGY,
    GET_ALL_HOSTS,
    BLOCK_HOST,
    GET_LINK_LATENCY,
    GET_PACKET_LOSS_RATE,
    GET_SWITCH_PORTS,
    REROUTE_FLOW,
    GET_SWITCH_MEMORY_UTILIZATION,
    GET_SWITCH_TEMPERATURE,
    SET_SWITCH_POWER_STATE,
    GET_PATH_SWITCH_COUNT,
    SET_DEVICE_NICKNAME,
    TOGGLE_HISTORICAL_LOGGING,
    GET_SWITCH_CAPABILITIES,
    INSTALL_GROUP_ENTRY,
    INSTALL_METER_ENTRY,

    GET_DEVICE_UPTIME,
    RESTART_DEVICE,
    BACKUP_CONFIGURATION,
    RESTORE_CONFIGURATION,
    PING_HOST,
    TRACEROUTE_HOST,
    GET_ARP_TABLE,
    GET_MAC_TABLE,
    SET_PORT_STATUS,
    GET_PORT_STATISTICS,
    GET_DEVICE_LOGS,
    CLEAR_DEVICE_LOGS,
    UPDATE_DEVICE_FIRMWARE,
    GET_DEVICE_HEALTH,
    MONITOR_REAL_TIME_TRAFFIC,

    REQUEST_UI_FORM,
};

inline constexpr const char*
taskTypeToString(TaskType t)
{
    switch (t)
    {
    case DISABLE_SWITCH:
        return "DisableSwitch";
    case ENABLE_SWITCH:
        return "EnableSwitch";
    case POWEROFF_SWITCH:
        return "PowerOffSwitch";
    case POWERON_SWITCH:
        return "PowerOnSwitch";
    case INSTALL_FLOW_ENTRY:
        return "InstallFlowEntry";
    case MODIFY_FLOW_ENTRY:
        return "ModifyFlowEntry";
    case DELETE_FLOW_ENTRY:
        return "DeleteFlowEntry";
    case GET_TOP_K_FLOWS:
        return "GetTopKFlows";
    case GET_SWITCH_CPU_UTILIZATION:
        return "GetSwitchCpuUtilization";
    case GET_TOTAL_POWER_CONSUMPTION: 
        return "GetTotalPowerConsumption";
    case GET_A_SWITCH_CPU_UTILIZATION:
        return "GetASwitchCpuUtilization";
    case GET_A_SWITCH_POWER_CONSUMPTION:
        return "GetASwitchPowerConsumption";
    case GET_A_LINK_BANDWIDTH_UTILIZATION:
        return "GetALinkBandwidthUtilization";
    case GET_TOP_K_CONGESTED_LINKS:
        return "GetTopKCongestedLinks";
    case GET_TOP_K_BANDWIDTH_USERS:
        return "GetTopKBandwidthUsers";
    case GET_PATH:
        return "GetPath";
    case GET_ACTIVE_FLOW_COUNT:
        return "GetActiveFlowCount";
    case GET_FLOW_ENTRY_COUNT:
        return "GetFlowEntryCount";
    case GET_FLOW_ENTRIES:
        return "GetFlowEntries";


    case GET_NETWORK_TOPOLOGY:
        return "GetNetworkTopology";
    case GET_ALL_HOSTS:
        return "GetAllHosts";
    case BLOCK_HOST:
        return "BlockHost";
    case GET_LINK_LATENCY:
        return "GetLinkLatency";
    case GET_PACKET_LOSS_RATE:
        return "GetPacketLossRate";
    case GET_SWITCH_PORTS:
        return "GetSwitchPorts";
    case REROUTE_FLOW:
        return "RerouteFlow";
    case GET_SWITCH_MEMORY_UTILIZATION:
        return "GetSwitchMemoryUtilization";
    case GET_SWITCH_TEMPERATURE:
        return "GetSwitchTemperature";
    case SET_SWITCH_POWER_STATE:
        return "SetSwitchPowerState";
    case GET_PATH_SWITCH_COUNT:
        return "GetPathSwitchCount";
    case SET_DEVICE_NICKNAME:
        return "SetDeviceNickname";
    case TOGGLE_HISTORICAL_LOGGING:
        return "ToggleHistoricalLogging";
    case GET_SWITCH_CAPABILITIES:
        return "GetSwitchCapabilities";
    case INSTALL_GROUP_ENTRY:
        return "InstallGroupEntry";
    case INSTALL_METER_ENTRY:
        return "InstallMeterEntry";


    case GET_DEVICE_UPTIME:
        return "GetDeviceUptime";
    case RESTART_DEVICE:
        return "RestartDevice";
    case BACKUP_CONFIGURATION:
        return "BackupConfiguration";
    case RESTORE_CONFIGURATION:
        return "RestoreConfiguration";
    case PING_HOST:
        return "PingHost";
    case TRACEROUTE_HOST:
        return "TracerouteHost";
    case GET_ARP_TABLE:
        return "GetArpTable";
    case GET_MAC_TABLE:
        return "GetMacTable";
    case SET_PORT_STATUS:
        return "SetPortStatus";
    case GET_PORT_STATISTICS:
        return "GetPortStatistics";
    case GET_DEVICE_LOGS:
        return "GetDeviceLogs";
    case CLEAR_DEVICE_LOGS:
        return "ClearDeviceLogs";
    case UPDATE_DEVICE_FIRMWARE:
        return "UpdateDeviceFirmware";
    case GET_DEVICE_HEALTH:
        return "GetDeviceHealth";
    case MONITOR_REAL_TIME_TRAFFIC:
        return "MonitorRealTimeTraffic";
    case REQUEST_UI_FORM: 
        return "RequestUIForm";


    default:
        return "Unknown";
    }
}

inline TaskType
taskTypeFromString(std::string s)
{
    if (s == "DisableSwitch")
    {
        return DISABLE_SWITCH;
    }
    if (s == "EnableSwitch")
    {
        return ENABLE_SWITCH;
    }
    if (s == "PowerOffSwitch")
    {
        return POWEROFF_SWITCH;
    }
    if (s == "PowerOnSwitch")
    {
        return POWERON_SWITCH;
    }
    if (s == "InstallFlowEntry")
    {
        return INSTALL_FLOW_ENTRY;
    }
    if (s == "ModifyFlowEntry")
    {
        return MODIFY_FLOW_ENTRY;
    }
    if (s == "DeleteFlowEntry")
    {
        return DELETE_FLOW_ENTRY;
    }
    if (s == "GetTopKFlows")
    {
        return GET_TOP_K_FLOWS;
    }
    if (s == "GetSwitchCpuUtilization")
    {
        return GET_SWITCH_CPU_UTILIZATION;
    }
    if (s == "GetTotalPowerConsumption") 
    {
        return GET_TOTAL_POWER_CONSUMPTION;
    }
    if (s == "GetASwitchCpuUtilization")
    {
        return GET_A_SWITCH_CPU_UTILIZATION;
    }
    if (s == "GetASwitchPowerConsumption")
    {
        return GET_A_SWITCH_POWER_CONSUMPTION;
    }
    if (s == "GetALinkBandwidthUtilization")
    {
        return GET_A_LINK_BANDWIDTH_UTILIZATION;
    }
    if (s == "GetTopKCongestedLinks")
    {
        return GET_TOP_K_CONGESTED_LINKS;
    }
    if (s == "GetTopKBandwidthUsers")
    {
        return GET_TOP_K_BANDWIDTH_USERS;
    }
    if (s == "GetPath")
    {
        return GET_PATH;
    }
    if (s == "GetActiveFlowCount")
    {
        return GET_ACTIVE_FLOW_COUNT;
    }
    if (s == "GetFlowEntryCount")
    {
        return GET_FLOW_ENTRY_COUNT;
    }
    if (s == "GetFlowEntries")
    {
        return GET_FLOW_ENTRIES;
    }
    if (s == "GetNetworkTopology")
    {
        return GET_NETWORK_TOPOLOGY;
    }
    if (s == "GetAllHosts")
    {
        return GET_ALL_HOSTS;
    }
    if (s == "BlockHost")
    {
        return BLOCK_HOST;
    }
    if (s == "GetLinkLatency")
    {
        return GET_LINK_LATENCY;
    }
    if (s == "GetPacketLossRate")
    {
        return GET_PACKET_LOSS_RATE;
    }
    if (s == "GetSwitchPorts")
    {
        return GET_SWITCH_PORTS;
    }
    if (s == "RerouteFlow")
    {
        return REROUTE_FLOW;
    }
    if (s == "GetSwitchMemoryUtilization")
    {
        return GET_SWITCH_MEMORY_UTILIZATION;
    }
    if (s == "GetSwitchTemperature")
    {
        return GET_SWITCH_TEMPERATURE;
    }
    if (s == "SetSwitchPowerState")
    {
        return SET_SWITCH_POWER_STATE;
    }
    if (s == "GetPathSwitchCount")
    {
        return GET_PATH_SWITCH_COUNT;
    }
    if (s == "SetDeviceNickname")
    {
        return SET_DEVICE_NICKNAME;
    }
    if (s == "ToggleHistoricalLogging")
    {
        return TOGGLE_HISTORICAL_LOGGING;
    }
    if (s == "GetSwitchCapabilities")
    {
        return GET_SWITCH_CAPABILITIES;
    }
    if (s == "InstallGroupEntry")
    {
        return INSTALL_GROUP_ENTRY;
    }
    if (s == "InstallMeterEntry")
    {
        return INSTALL_METER_ENTRY;
    }


    if (s == "GetDeviceUptime")
    {
        return GET_DEVICE_UPTIME;
    }
    if (s == "RestartDevice")
    {
        return RESTART_DEVICE;
    }
    if (s == "BackupConfiguration")
    {
        return BACKUP_CONFIGURATION;
    }
    if (s == "RestoreConfiguration")
    {
        return RESTORE_CONFIGURATION;
    }
    if (s == "PingHost")
    {
        return PING_HOST;
    }
    if (s == "TracerouteHost")
    {
        return TRACEROUTE_HOST;
    }
    if (s == "GetArpTable")
    {
        return GET_ARP_TABLE;
    }
    if (s == "GetMacTable")
    {
        return GET_MAC_TABLE;
    }
    if (s == "SetPortStatus")
    {
        return SET_PORT_STATUS;
    }
    if (s == "GetPortStatistics")
    {
        return GET_PORT_STATISTICS;
    }
    if (s == "GetDeviceLogs")
    {
        return GET_DEVICE_LOGS;
    }
    if (s == "ClearDeviceLogs")
    {
        return CLEAR_DEVICE_LOGS;
    }
    if (s == "UpdateDeviceFirmware")
    {
        return UPDATE_DEVICE_FIRMWARE;
    }
    if (s == "GetDeviceHealth")
    {
        return GET_DEVICE_HEALTH;
    }
    if (s == "MonitorRealTimeTraffic")
    {
        return MONITOR_REAL_TIME_TRAFFIC;
    }
    if (s == "RequestUIForm"){
        return REQUEST_UI_FORM;
    } 

    // TODO: switch this to error log
    throw std::runtime_error("unknown task type: " + std::string{s});
}

// ============================= LLMResponse (parent) =============================

class LLMResponse
{
  public:
    virtual ~LLMResponse() = default;
    State state;
};

inline void
llmResponse_to_json(json& j, const LLMResponse& r)
{
    j["state"] = stateToString(r.state);
}

inline void
llmResponse_from_json(const json& j, LLMResponse& r)
{
    r.state = stateFromString(j.at("state").get<std::string>());
}

// ============================= TASK (parent) =====================================

class Task
{
  public:
    TaskType type;
    uint16_t order;
    std::string result = "";
    virtual ~Task() = default;
};

inline void
task_to_json(json& j, const Task& t)
{
    j["type"] = taskTypeToString(t.type);
    j["order"] = t.order;
    j["result"] = t.result;
}

inline void
task_from_json(const json& j, Task& t)
{
    t.type = taskTypeFromString(j.at("type").get<std::string>());
    t.order = j.at("order").get<uint16_t>();
    t.result = "";
}

// ================================ DISABLE_SWITCH ================================

class DisableSwitchTask : public Task
{
  public:
    DisableSwitchTask()
    {
        type = DISABLE_SWITCH;
    }

    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const DisableSwitchTask& task)
{
    j = nlohmann::json{{"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, DisableSwitchTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================ ENABLE_SWITCH =================================

class EnableSwitchTask : public Task
{
  public:
    EnableSwitchTask()
    {
        type = ENABLE_SWITCH;
    }

    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const EnableSwitchTask& task)
{
    j = nlohmann::json{{"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, EnableSwitchTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================ POWER_OFF_SWITCH ================================

class PowerOffSwitchTask : public Task
{
  public:
    PowerOffSwitchTask()
    {
        type = POWEROFF_SWITCH;
    }

    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const PowerOffSwitchTask& task)
{
    j = nlohmann::json{{"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, PowerOffSwitchTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================ POWER_ON_SWITCH =================================

class PowerOnSwitchTask : public Task
{
  public:
    PowerOnSwitchTask()
    {
        type = POWERON_SWITCH;
    }

    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const PowerOnSwitchTask& task)
{
    j = nlohmann::json{{"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, PowerOnSwitchTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================ INSTALL_FLOW_ENTRY ================================

class InstallFlowEntryTask : public Task
{
  public:
    InstallFlowEntryTask()
    {
        type = INSTALL_FLOW_ENTRY;
    }

    std::string deviceName;
    uint16_t priority;
    json match;
    std::string actionType; // can only be OUTPUT or DROP
    int actionOutPort;      // -1 means no output port specified
};

inline void
to_json(nlohmann::json& j, const InstallFlowEntryTask& task)
{
    nlohmann::json action = nlohmann::json::array();
    if (task.actionType != "")
    {
        action.push_back({
            {"type", task.actionType},
            {"port", task.actionOutPort}
        });
    }
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"priority", task.priority},
          {"match", task.match},
          {"actions", action}
        }}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, InstallFlowEntryTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.priority = j.at("parameters").at("priority").get<uint16_t>();
    task.match = j.at("parameters").at("match");
    if (!j.at("parameters").at("actions").empty())
    {
        task.actionType = j.at("parameters").at("actions")[0].at("type").get<std::string>();
        task.actionOutPort = j.at("parameters").at("actions")[0].at("port");
    }
    else
    {
        task.actionType = "";
        task.actionOutPort = -1;
    }
    task_from_json(j, task);
}

// ================================ MODIFY_FLOW_ENTRY ================================

class ModifyFlowEntryTask : public Task
{
  public:
    ModifyFlowEntryTask()
    {
        // [Co-developed with claude code -- Adam]
        // Was INSTALL_FLOW_ENTRY, so every modify task announced itself as an install. The two are
        // distinct enum values and the dispatch reads this field, so a modify requested by the
        // intent translator was carried out as an install -- which for an existing rule means a
        // second entry rather than a changed one, the same "should replace, can only add" shape
        // that has now appeared four times in this codebase.
        type = MODIFY_FLOW_ENTRY;
    }

    std::string deviceName;
    uint16_t priority;
    json match;
    std::string actionType; // can only be FORWARD or DROP
    int actionOutPort;      // -1 means no output port specified
};

inline void
to_json(nlohmann::json& j, const ModifyFlowEntryTask& task)
{
    nlohmann::json action = nlohmann::json::array();
    if (task.actionType != "")
    {
        action.push_back({
            {"type", task.actionType},
            {"port", task.actionOutPort}
        });
    }
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"priority", task.priority},
          {"match", task.match},
          {"actions", action}
        }}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, ModifyFlowEntryTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.priority = j.at("parameters").at("priority").get<uint16_t>();
    task.match = j.at("parameters").at("match");
    if (!j.at("parameters").at("actions").empty())
    {
        task.actionType = j.at("parameters").at("actions")[0].at("type").get<std::string>();
        task.actionOutPort = j.at("parameters").at("actions")[0].at("port");
    }
    else
    {
        task.actionType = "";
        task.actionOutPort = -1;
    }
    task_from_json(j, task);
}

// ================================ DELETE_FLOW_ENTRY ================================

class DeleteFlowEntryTask : public Task
{
  public:
    DeleteFlowEntryTask()
    {
        type = DELETE_FLOW_ENTRY;
    }

    std::string deviceName;
    json match;
};

inline void
to_json(nlohmann::json& j, const DeleteFlowEntryTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"match", task.match}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, DeleteFlowEntryTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.match = j.at("parameters").at("match");
    task_from_json(j, task);
}

// ================================ GET_TOP_K_FLOWS ==================================

class GetTopKFlowsTask : public Task
{
  public:
    GetTopKFlowsTask()
    {
        type = GET_TOP_K_FLOWS;
    }

    int k;
};

inline void
to_json(nlohmann::json& j, const GetTopKFlowsTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"k", task.k}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetTopKFlowsTask& task)
{
    task.k = j.at("parameters").at("k").get<int>();
    task_from_json(j, task);
}

// ========================= GET_SWITCH_CPU_UTILIZATION ==============================

class GetSwitchCpuUtilizationTask : public Task
{
  public:
    GetSwitchCpuUtilizationTask()
    {
        type = GET_SWITCH_CPU_UTILIZATION;
    }
};

inline void
to_json(nlohmann::json& j, const GetSwitchCpuUtilizationTask& task)
{
    j = nlohmann::json{
        {"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetSwitchCpuUtilizationTask& task)
{
    task_from_json(j, task);
}

// ========================= GET_TOTAL_POWER_CONSUMPTION ==============================
class GetTotalPowerConsumptionTask : public Task
{
  public:
    GetTotalPowerConsumptionTask()
    {
        type = GET_TOTAL_POWER_CONSUMPTION;
    }
};

inline void
to_json(nlohmann::json& j, const GetTotalPowerConsumptionTask& task)
{
    j = nlohmann::json{
        {"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetTotalPowerConsumptionTask& task)
{
    task_from_json(j, task);
}

// ========================= GET_A_SWITCH_CPU_UTLIZATION_TASK ==============================

class GetASwitchCpuUtilizationTask : public Task
{
  public:
    GetASwitchCpuUtilizationTask()
    {
        type = GET_A_SWITCH_CPU_UTILIZATION;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetASwitchCpuUtilizationTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetASwitchCpuUtilizationTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ========================= GET_A_SWITCH_POWER_CONSUMPTION ==============================
class GetASwitchPowerConsumptionTask : public Task
{
  public:
    GetASwitchPowerConsumptionTask()
    {
        type = GET_A_SWITCH_POWER_CONSUMPTION;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetASwitchPowerConsumptionTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetASwitchPowerConsumptionTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ========================= GET_A_LINK_BANDWIDTH_UTILIZATION ==============================
class GetALinkBandwidthUtilizationTask : public Task
{
  public:
    GetALinkBandwidthUtilizationTask()
    {
        type = GET_A_LINK_BANDWIDTH_UTILIZATION;
    }
    std::string srcDeviceName;
    std::string dstDeviceName;
};

inline void
to_json(nlohmann::json& j, const GetALinkBandwidthUtilizationTask& task)
{
    j = nlohmann::json{
        {"parameters", {
            {"src", task.srcDeviceName},
            {"dst", task.dstDeviceName}
        }}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetALinkBandwidthUtilizationTask& task)
{
    task.srcDeviceName = j.at("parameters").at("src").get<std::string>();
    task.dstDeviceName = j.at("parameters").at("dst").get<std::string>();
    task_from_json(j, task);
}

// ========================= GET_TOP_K_CONGESTED_LINKS ==============================
class GetTopKCongestedLinksTask : public Task
{
  public:
    GetTopKCongestedLinksTask()
    {
        type = GET_TOP_K_CONGESTED_LINKS;
    }
    int k;
};

inline void
to_json(nlohmann::json& j, const GetTopKCongestedLinksTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"k", task.k}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetTopKCongestedLinksTask& task)
{
    task.k = j.at("parameters").at("k").get<int>();
    task_from_json(j, task);
}

// ========================= GET_TOP_K_BANDWIDTH_USERS ==============================
class GetTopKBandwidthUsersTask : public Task
{
  public:
    GetTopKBandwidthUsersTask()
    {
        type = GET_TOP_K_BANDWIDTH_USERS;
    }
    int k;
};

inline void
to_json(nlohmann::json& j, const GetTopKBandwidthUsersTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"k", task.k}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetTopKBandwidthUsersTask& task)
{
    task.k = j.at("parameters").at("k").get<int>();
    task_from_json(j, task);
}

// ========================= GET_PATH ==============================
class GetPathTask : public Task
{
  public:
    GetPathTask()
    {
        type = GET_PATH;
    }
    std::string srcHostName;
    std::string dstHostName;
};

inline void
to_json(nlohmann::json& j, const GetPathTask& task)
{
    j = nlohmann::json{
        {"parameters", {
            {"src", task.srcHostName},
            {"dst", task.dstHostName}
        }}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetPathTask& task)
{
    task.srcHostName = j.at("parameters").at("src").get<std::string>();
    task.dstHostName = j.at("parameters").at("dst").get<std::string>();
    task_from_json(j, task);
}

// ========================= GET_ACTIVE_FLOW_COUNT ==============================
class GetActiveFlowCountTask : public Task
{
  public:
    GetActiveFlowCountTask()
    {
        type = GET_ACTIVE_FLOW_COUNT;
    }
};

inline void
to_json(nlohmann::json& j, const GetActiveFlowCountTask& task)
{
    j = nlohmann::json{
        {"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetActiveFlowCountTask& task)
{
    task_from_json(j, task);
}

// ========================= GET_FLOW_ENTRY_COUNT ==============================
class GetFlowEntryCountTask : public Task
{
  public:
    GetFlowEntryCountTask()
    {
        type = GET_FLOW_ENTRY_COUNT;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetFlowEntryCountTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetFlowEntryCountTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ========================= GET_FLOW_ENTRIES ==============================
class GetFlowEntriesTask : public Task
{
  public:
    GetFlowEntriesTask()
    {
        type = GET_FLOW_ENTRIES;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetFlowEntriesTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetFlowEntriesTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ============================= GET_NETWORK_TOPOLOGY ==============================
class GetNetworkTopologyTask : public Task
{
  public:
    GetNetworkTopologyTask()
    {
        type = GET_NETWORK_TOPOLOGY;
    }
};

inline void
to_json(nlohmann::json& j, const GetNetworkTopologyTask& task)
{
    j = nlohmann::json{{"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetNetworkTopologyTask& task)
{
    task_from_json(j, task);
}

// ================================ GET_ALL_HOSTS ==================================
class GetAllHostsTask : public Task
{
  public:
    GetAllHostsTask()
    {
        type = GET_ALL_HOSTS;
    }
};

inline void
to_json(nlohmann::json& j, const GetAllHostsTask& task)
{
    j = nlohmann::json{{"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetAllHostsTask& task)
{
    task_from_json(j, task);
}

// ================================== BLOCK_HOST ===================================
class BlockHostTask : public Task
{
  public:
    BlockHostTask()
    {
        type = BLOCK_HOST;
    }
    std::string host_id;
};

inline void
to_json(nlohmann::json& j, const BlockHostTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"host_id", task.host_id}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, BlockHostTask& task)
{
    task.host_id = j.at("parameters").at("host_id").get<std::string>();
    task_from_json(j, task);
}

// =============================== GET_LINK_LATENCY ================================
class GetLinkLatencyTask : public Task
{
  public:
    GetLinkLatencyTask()
    {
        type = GET_LINK_LATENCY;
    }
    std::string src;
    std::string dst;
};

inline void
to_json(nlohmann::json& j, const GetLinkLatencyTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"src", task.src},
          {"dst", task.dst}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetLinkLatencyTask& task)
{
    task.src = j.at("parameters").at("src").get<std::string>();
    task.dst = j.at("parameters").at("dst").get<std::string>();
    task_from_json(j, task);
}

// ============================= GET_PACKET_LOSS_RATE ==============================
class GetPacketLossRateTask : public Task
{
  public:
    GetPacketLossRateTask()
    {
        type = GET_PACKET_LOSS_RATE;
    }
    std::string src;
    std::string dst;
};

inline void
to_json(nlohmann::json& j, const GetPacketLossRateTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"src", task.src},
          {"dst", task.dst}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetPacketLossRateTask& task)
{
    task.src = j.at("parameters").at("src").get<std::string>();
    task.dst = j.at("parameters").at("dst").get<std::string>();
    task_from_json(j, task);
}

// =============================== GET_SWITCH_PORTS ================================
class GetSwitchPortsTask : public Task
{
  public:
    GetSwitchPortsTask()
    {
        type = GET_SWITCH_PORTS;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetSwitchPortsTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetSwitchPortsTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================= REROUTE_FLOW ==================================
class RerouteFlowTask : public Task
{
  public:
    RerouteFlowTask()
    {
        type = REROUTE_FLOW;
    }
    nlohmann::json match;
    std::vector<std::string> newPath;
};

inline void
to_json(nlohmann::json& j, const RerouteFlowTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"match", task.match},
          {"new_path", task.newPath}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, RerouteFlowTask& task)
{
    task.match = j.at("parameters").at("match");
    task.newPath = j.at("parameters").at("new_path").get<std::vector<std::string>>();
    task_from_json(j, task);
}

// ======================= GET_SWITCH_MEMORY_UTILIZATION ===========================
class GetSwitchMemoryUtilizationTask : public Task
{
  public:
    GetSwitchMemoryUtilizationTask()
    {
        type = GET_SWITCH_MEMORY_UTILIZATION;
    }
};

inline void
to_json(nlohmann::json& j, const GetSwitchMemoryUtilizationTask& task)
{
    j = nlohmann::json{{"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetSwitchMemoryUtilizationTask& task)
{
    task_from_json(j, task);
}

// =========================== GET_SWITCH_TEMPERATURE ==============================
class GetSwitchTemperatureTask : public Task
{
  public:
    GetSwitchTemperatureTask()
    {
        type = GET_SWITCH_TEMPERATURE;
    }
};

inline void
to_json(nlohmann::json& j, const GetSwitchTemperatureTask& task)
{
    j = nlohmann::json{{"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetSwitchTemperatureTask& task)
{
    task_from_json(j, task);
}

// ============================ SET_SWITCH_POWER_STATE =============================
class SetSwitchPowerStateTask : public Task
{
  public:
    SetSwitchPowerStateTask()
    {
        type = SET_SWITCH_POWER_STATE;
    }
    std::string deviceName;
    std::string state;
};

inline void
to_json(nlohmann::json& j, const SetSwitchPowerStateTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"state", task.state}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, SetSwitchPowerStateTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.state = j.at("parameters").at("state").get<std::string>();
    task_from_json(j, task);
}

// ============================ GET_PATH_SWITCH_COUNT ==============================
class GetPathSwitchCountTask : public Task
{
  public:
    GetPathSwitchCountTask()
    {
        type = GET_PATH_SWITCH_COUNT;
    }
    std::string src;
    std::string dst;
};

inline void
to_json(nlohmann::json& j, const GetPathSwitchCountTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"src", task.src},
          {"dst", task.dst}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetPathSwitchCountTask& task)
{
    task.src = j.at("parameters").at("src").get<std::string>();
    task.dst = j.at("parameters").at("dst").get<std::string>();
    task_from_json(j, task);
}

// ============================== SET_DEVICE_NICKNAME ==============================
class SetDeviceNicknameTask : public Task
{
  public:
    SetDeviceNicknameTask()
    {
        type = SET_DEVICE_NICKNAME;
    }
    std::string deviceName;
    std::string nickname;
};

inline void
to_json(nlohmann::json& j, const SetDeviceNicknameTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"nickname", task.nickname}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, SetDeviceNicknameTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.nickname = j.at("parameters").at("nickname").get<std::string>();
    task_from_json(j, task);
}

// ========================== TOGGLE_HISTORICAL_LOGGING ============================
class ToggleHistoricalLoggingTask : public Task
{
  public:
    ToggleHistoricalLoggingTask()
    {
        type = TOGGLE_HISTORICAL_LOGGING;
    }
    std::string state;
};

inline void
to_json(nlohmann::json& j, const ToggleHistoricalLoggingTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"state", task.state}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, ToggleHistoricalLoggingTask& task)
{
    task.state = j.at("parameters").at("state").get<std::string>();
    task_from_json(j, task);
}

// =========================== GET_SWITCH_CAPABILITIES =============================
class GetSwitchCapabilitiesTask : public Task
{
  public:
    GetSwitchCapabilitiesTask()
    {
        type = GET_SWITCH_CAPABILITIES;
    }
};

inline void
to_json(nlohmann::json& j, const GetSwitchCapabilitiesTask& task)
{
    j = nlohmann::json{{"parameters", {}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetSwitchCapabilitiesTask& task)
{
    task_from_json(j, task);
}

// ============================= INSTALL_GROUP_ENTRY ===============================
class InstallGroupEntryTask : public Task
{
  public:
    InstallGroupEntryTask()
    {
        type = INSTALL_GROUP_ENTRY;
    }
    std::string deviceName;
    std::string group_type;
    int group_id;
    nlohmann::json buckets;
};

inline void
to_json(nlohmann::json& j, const InstallGroupEntryTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"group_type", task.group_type},
          {"group_id", task.group_id},
          {"buckets", task.buckets}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, InstallGroupEntryTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.group_type = j.at("parameters").at("group_type").get<std::string>();
    task.group_id = j.at("parameters").at("group_id").get<int>();
    task.buckets = j.at("parameters").at("buckets");
    task_from_json(j, task);
}

// ============================== INSTALL_METER_ENTRY ==============================
class InstallMeterEntryTask : public Task
{
  public:
    InstallMeterEntryTask()
    {
        type = INSTALL_METER_ENTRY;
    }
    std::string deviceName;
    int meter_id;
    std::vector<std::string> flags;
    nlohmann::json bands;
};

inline void
to_json(nlohmann::json& j, const InstallMeterEntryTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"meter_id", task.meter_id},
          {"flags", task.flags},
          {"bands", task.bands}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, InstallMeterEntryTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.meter_id = j.at("parameters").at("meter_id").get<int>();
    task.flags = j.at("parameters").at("flags").get<std::vector<std::string>>();
    task.bands = j.at("parameters").at("bands");
    task_from_json(j, task);
}
// ============================= GET_DEVICE_UPTIME ===============================
class GetDeviceUptimeTask : public Task
{
  public:
    GetDeviceUptimeTask()
    {
        type = GET_DEVICE_UPTIME;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetDeviceUptimeTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetDeviceUptimeTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// =============================== RESTART_DEVICE ================================
class RestartDeviceTask : public Task
{
  public:
    RestartDeviceTask()
    {
        type = RESTART_DEVICE;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const RestartDeviceTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, RestartDeviceTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// =========================== BACKUP_CONFIGURATION ============================
class BackupConfigurationTask : public Task
{
  public:
    BackupConfigurationTask()
    {
        type = BACKUP_CONFIGURATION;
    }
    std::string deviceName;
    std::string backupPath;
};

inline void
to_json(nlohmann::json& j, const BackupConfigurationTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName}, {"backup_path", task.backupPath}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, BackupConfigurationTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.backupPath = j.at("parameters").at("backup_path").get<std::string>();
    task_from_json(j, task);
}

// =========================== RESTORE_CONFIGURATION ===========================
class RestoreConfigurationTask : public Task
{
  public:
    RestoreConfigurationTask()
    {
        type = RESTORE_CONFIGURATION;
    }
    std::string deviceName;
    std::string restorePath;
};

inline void
to_json(nlohmann::json& j, const RestoreConfigurationTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"restore_path", task.restorePath}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, RestoreConfigurationTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.restorePath = j.at("parameters").at("restore_path").get<std::string>();
    task_from_json(j, task);
}

// ================================== PING_HOST ==================================
class PingHostTask : public Task
{
  public:
    PingHostTask()
    {
        type = PING_HOST;
    }
    std::string host;
    int count = 4; // Default ping count
};

inline void
to_json(nlohmann::json& j, const PingHostTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"host", task.host}, {"count", task.count}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, PingHostTask& task)
{
    task.host = j.at("parameters").at("host").get<std::string>();
    task.count = j.at("parameters").value("count", 4);
    task_from_json(j, task);
}

// =============================== TRACEROUTE_HOST ===============================
class TracerouteHostTask : public Task
{
  public:
    TracerouteHostTask()
    {
        type = TRACEROUTE_HOST;
    }
    std::string host;
};

inline void
to_json(nlohmann::json& j, const TracerouteHostTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"host", task.host}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, TracerouteHostTask& task)
{
    task.host = j.at("parameters").at("host").get<std::string>();
    task_from_json(j, task);
}

// ================================ GET_ARP_TABLE ================================
class GetArpTableTask : public Task
{
  public:
    GetArpTableTask()
    {
        type = GET_ARP_TABLE;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetArpTableTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetArpTableTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ================================ GET_MAC_TABLE ================================
class GetMacTableTask : public Task
{
  public:
    GetMacTableTask()
    {
        type = GET_MAC_TABLE;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetMacTableTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetMacTableTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// =============================== SET_PORT_STATUS ===============================
class SetPortStatusTask : public Task
{
  public:
    SetPortStatusTask()
    {
        type = SET_PORT_STATUS;
    }
    std::string deviceName;
    int portId;
    std::string status; // e.g., "UP", "DOWN"
};

inline void
to_json(nlohmann::json& j, const SetPortStatusTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"port_id", task.portId},
          {"status", task.status}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, SetPortStatusTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.portId = j.at("parameters").at("port_id").get<int>();
    task.status = j.at("parameters").at("status").get<std::string>();
    task_from_json(j, task);
}

// ============================= GET_PORT_STATISTICS =============================
class GetPortStatisticsTask : public Task
{
  public:
    GetPortStatisticsTask()
    {
        type = GET_PORT_STATISTICS;
    }
    std::string deviceName;
    int portId;
};

inline void
to_json(nlohmann::json& j, const GetPortStatisticsTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName}, {"port_id", task.portId}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetPortStatisticsTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.portId = j.at("parameters").at("port_id").get<int>();
    task_from_json(j, task);
}

// =============================== GET_DEVICE_LOGS ===============================
class GetDeviceLogsTask : public Task
{
  public:
    GetDeviceLogsTask()
    {
        type = GET_DEVICE_LOGS;
    }
    std::string deviceName;
    int lineCount = 100; // Default number of log lines
};

inline void
to_json(nlohmann::json& j, const GetDeviceLogsTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName}, {"line_count", task.lineCount}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetDeviceLogsTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.lineCount = j.at("parameters").value("line_count", 100);
    task_from_json(j, task);
}

// ============================== CLEAR_DEVICE_LOGS ==============================
class ClearDeviceLogsTask : public Task
{
  public:
    ClearDeviceLogsTask()
    {
        type = CLEAR_DEVICE_LOGS;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const ClearDeviceLogsTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, ClearDeviceLogsTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ============================ UPDATE_DEVICE_FIRMWARE ===========================
class UpdateDeviceFirmwareTask : public Task
{
  public:
    UpdateDeviceFirmwareTask()
    {
        type = UPDATE_DEVICE_FIRMWARE;
    }
    std::string deviceName;
    std::string firmwarePath;
};

inline void
to_json(nlohmann::json& j, const UpdateDeviceFirmwareTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"firmware_path", task.firmwarePath}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, UpdateDeviceFirmwareTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.firmwarePath =
        j.at("parameters").at("firmware_path").get<std::string>();
    task_from_json(j, task);
}

// ============================== GET_DEVICE_HEALTH ==============================
class GetDeviceHealthTask : public Task
{
  public:
    GetDeviceHealthTask()
    {
        type = GET_DEVICE_HEALTH;
    }
    std::string deviceName;
};

inline void
to_json(nlohmann::json& j, const GetDeviceHealthTask& task)
{
    j = nlohmann::json{
        {"parameters", {{"device_name", task.deviceName}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, GetDeviceHealthTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task_from_json(j, task);
}

// ========================== MONITOR_REAL_TIME_TRAFFIC ==========================
class MonitorRealTimeTrafficTask : public Task
{
  public:
    MonitorRealTimeTrafficTask()
    {
        type = MONITOR_REAL_TIME_TRAFFIC;
    }
    std::string deviceName;
    int portId;
    int durationSeconds = 10;
};

inline void
to_json(nlohmann::json& j, const MonitorRealTimeTrafficTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"port_id", task.portId},
          {"duration_seconds", task.durationSeconds}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, MonitorRealTimeTrafficTask& task)
{
    task.deviceName = j.at("parameters").at("device_name").get<std::string>();
    task.portId = j.at("parameters").at("port_id").get<int>();
    task.durationSeconds =
        j.at("parameters").value("duration_seconds", 10);
    task_from_json(j, task);
}

//========================== REQUEST_UI_FORM ==========================
class RequestUIFormTask : public Task
{
  public:
    RequestUIFormTask()
    {
        type = REQUEST_UI_FORM;
    }
    std::string deviceName;
    std::string formType; // e.g., "install_flow", "delete_flow", "modify_flow"
};

inline void
to_json(nlohmann::json& j, const RequestUIFormTask& task)
{
    j = nlohmann::json{
        {"parameters",
         {{"device_name", task.deviceName},
          {"form_type", task.formType}}}};
    task_to_json(j, task);
}

inline void
from_json(const nlohmann::json& j, RequestUIFormTask& task)
{

    task.deviceName = j.at("parameters").value("device_name", ""); 
    task.formType = j.at("parameters").at("form_type").get<std::string>();
    task_from_json(j, task);
}

// ====================== serilalizer and deserializer for Task ======================

inline void
to_json(nlohmann::json& j, const std::unique_ptr<Task>& p)
{
    if (!p)
    {
        j = nullptr;
        return;
    }
    switch (p->type)
    {
    case DISABLE_SWITCH:
        j = static_cast<const DisableSwitchTask&>(*p);
        break;
    case ENABLE_SWITCH:
        j = static_cast<const EnableSwitchTask&>(*p);
        break;
    case POWEROFF_SWITCH:
        j = static_cast<const PowerOffSwitchTask&>(*p);
        break;
    case POWERON_SWITCH:
        j = static_cast<const PowerOnSwitchTask&>(*p);
        break;
    case INSTALL_FLOW_ENTRY:
        j = static_cast<const InstallFlowEntryTask&>(*p);
        break;
    case MODIFY_FLOW_ENTRY:
        j = static_cast<const ModifyFlowEntryTask&>(*p);
        break;
    case DELETE_FLOW_ENTRY:
        j = static_cast<const DeleteFlowEntryTask&>(*p);
        break;
    case GET_TOP_K_FLOWS:
        j = static_cast<const GetTopKFlowsTask&>(*p);
        break;
    case GET_SWITCH_CPU_UTILIZATION:
        j = static_cast<const GetSwitchCpuUtilizationTask&>(*p);
        break;
    case GET_TOTAL_POWER_CONSUMPTION: 
        j = static_cast<const GetTotalPowerConsumptionTask&>(*p);
        break;
    case GET_A_SWITCH_CPU_UTILIZATION:
        j = static_cast<const GetASwitchCpuUtilizationTask&>(*p);
        break;
    case GET_A_SWITCH_POWER_CONSUMPTION:
        j = static_cast<const GetASwitchPowerConsumptionTask&>(*p);
        break;
    case GET_A_LINK_BANDWIDTH_UTILIZATION:
        j = static_cast<const GetALinkBandwidthUtilizationTask&>(*p);
        break;
    case GET_TOP_K_CONGESTED_LINKS:
        j = static_cast<const GetTopKCongestedLinksTask&>(*p);
        break;
    case GET_TOP_K_BANDWIDTH_USERS:
        j = static_cast<const GetTopKBandwidthUsersTask&>(*p);
        break;
    case GET_PATH:
        j = static_cast<const GetPathTask&>(*p);
        break;
    case GET_ACTIVE_FLOW_COUNT:
        j = static_cast<const GetActiveFlowCountTask&>(*p);
        break;
    case GET_FLOW_ENTRY_COUNT:
        j = static_cast<const GetFlowEntryCountTask&>(*p);
        break;
    case GET_FLOW_ENTRIES:
        j = static_cast<const GetFlowEntriesTask&>(*p);
        break;
        
    case GET_NETWORK_TOPOLOGY:
        j = static_cast<const GetNetworkTopologyTask&>(*p);
        break;
    case GET_ALL_HOSTS:
        j = static_cast<const GetAllHostsTask&>(*p);
        break;
    case BLOCK_HOST:
        j = static_cast<const BlockHostTask&>(*p);
        break;
    case GET_LINK_LATENCY:
        j = static_cast<const GetLinkLatencyTask&>(*p);
        break;
    case GET_PACKET_LOSS_RATE:
        j = static_cast<const GetPacketLossRateTask&>(*p);
        break;
    case GET_SWITCH_PORTS:
        j = static_cast<const GetSwitchPortsTask&>(*p);
        break;
    case REROUTE_FLOW:
        j = static_cast<const RerouteFlowTask&>(*p);
        break;
    case GET_SWITCH_MEMORY_UTILIZATION:
        j = static_cast<const GetSwitchMemoryUtilizationTask&>(*p);
        break;
    case GET_SWITCH_TEMPERATURE:
        j = static_cast<const GetSwitchTemperatureTask&>(*p);
        break;
    case SET_SWITCH_POWER_STATE:
        j = static_cast<const SetSwitchPowerStateTask&>(*p);
        break;
    case GET_PATH_SWITCH_COUNT:
        j = static_cast<const GetPathSwitchCountTask&>(*p);
        break;
    case SET_DEVICE_NICKNAME:
        j = static_cast<const SetDeviceNicknameTask&>(*p);
        break;
    case TOGGLE_HISTORICAL_LOGGING:
        j = static_cast<const ToggleHistoricalLoggingTask&>(*p);
        break;
    case GET_SWITCH_CAPABILITIES:
        j = static_cast<const GetSwitchCapabilitiesTask&>(*p);
        break;
    case INSTALL_GROUP_ENTRY:
        j = static_cast<const InstallGroupEntryTask&>(*p);
        break;
    case INSTALL_METER_ENTRY:
        j = static_cast<const InstallMeterEntryTask&>(*p);
        break;
    
        
    case GET_DEVICE_UPTIME:
        j = static_cast<const GetDeviceUptimeTask&>(*p);
        break;
    case RESTART_DEVICE:
        j = static_cast<const RestartDeviceTask&>(*p);
        break;
    case BACKUP_CONFIGURATION:
        j = static_cast<const BackupConfigurationTask&>(*p);
        break;
    case RESTORE_CONFIGURATION:
        j = static_cast<const RestoreConfigurationTask&>(*p);
        break;
    case PING_HOST:
        j = static_cast<const PingHostTask&>(*p);
        break;
    case TRACEROUTE_HOST:
        j = static_cast<const TracerouteHostTask&>(*p);
        break;
    case GET_ARP_TABLE:
        j = static_cast<const GetArpTableTask&>(*p);
        break;
    case GET_MAC_TABLE:
        j = static_cast<const GetMacTableTask&>(*p);
        break;
    case SET_PORT_STATUS:
        j = static_cast<const SetPortStatusTask&>(*p);
        break;
    case GET_PORT_STATISTICS:
        j = static_cast<const GetPortStatisticsTask&>(*p);
        break;
    case GET_DEVICE_LOGS:
        j = static_cast<const GetDeviceLogsTask&>(*p);
        break;
    case CLEAR_DEVICE_LOGS:
        j = static_cast<const ClearDeviceLogsTask&>(*p);
        break;
    case UPDATE_DEVICE_FIRMWARE:
        j = static_cast<const UpdateDeviceFirmwareTask&>(*p);
        break;
    case GET_DEVICE_HEALTH:
        j = static_cast<const GetDeviceHealthTask&>(*p);
        break;
    case MONITOR_REAL_TIME_TRAFFIC:
        j = static_cast<const MonitorRealTimeTrafficTask&>(*p);
        break;
    case REQUEST_UI_FORM:
        j = static_cast<const RequestUIFormTask&>(*p);
        break;
    }
}

template <class T>
std::unique_ptr<Task>
make_from_json(const json& j)
{
    auto ptr = std::make_unique<T>();
    from_json(j, *ptr);
    return ptr;
}

inline void
from_json(const json& j, std::unique_ptr<Task>& p)
{
    switch (taskTypeFromString(j.at("type").get<std::string>()))
    {
    case DISABLE_SWITCH:
        p = make_from_json<DisableSwitchTask>(j);
        break;
    case ENABLE_SWITCH:
        p = make_from_json<EnableSwitchTask>(j);
        break;
    case POWEROFF_SWITCH:
        p = make_from_json<PowerOffSwitchTask>(j);
        break;
    case POWERON_SWITCH:
        p = make_from_json<PowerOnSwitchTask>(j);
        break;
    case INSTALL_FLOW_ENTRY:
        p = make_from_json<InstallFlowEntryTask>(j);
        break;
    case MODIFY_FLOW_ENTRY:
        p = make_from_json<ModifyFlowEntryTask>(j);
        break;
    case DELETE_FLOW_ENTRY:
        p = make_from_json<DeleteFlowEntryTask>(j);
        break;
    case GET_TOP_K_FLOWS:
        p = make_from_json<GetTopKFlowsTask>(j);
        break;
    case GET_SWITCH_CPU_UTILIZATION:
        p = make_from_json<GetSwitchCpuUtilizationTask>(j);
        break;
    case GET_TOTAL_POWER_CONSUMPTION:
        p = make_from_json<GetTotalPowerConsumptionTask>(j);
        break;
    case GET_A_SWITCH_CPU_UTILIZATION:
        p = make_from_json<GetASwitchCpuUtilizationTask>(j);
        break;
    case GET_A_SWITCH_POWER_CONSUMPTION:
        p = make_from_json<GetASwitchPowerConsumptionTask>(j);
        break;
    case GET_A_LINK_BANDWIDTH_UTILIZATION:
        p = make_from_json<GetALinkBandwidthUtilizationTask>(j);
        break;
    case GET_TOP_K_CONGESTED_LINKS:
        p = make_from_json<GetTopKCongestedLinksTask>(j);
        break;
    case GET_TOP_K_BANDWIDTH_USERS:
        p = make_from_json<GetTopKBandwidthUsersTask>(j);
        break;
    case GET_PATH:
        p = make_from_json<GetPathTask>(j);
        break;
    case GET_ACTIVE_FLOW_COUNT:
        p = make_from_json<GetActiveFlowCountTask>(j);
        break;
    case GET_FLOW_ENTRY_COUNT:
        p = make_from_json<GetFlowEntryCountTask>(j);
        break;
    case GET_FLOW_ENTRIES:
        p = make_from_json<GetFlowEntriesTask>(j);
        break;


    case GET_NETWORK_TOPOLOGY:
        p = make_from_json<GetNetworkTopologyTask>(j);
        break;
    case GET_ALL_HOSTS:
        p = make_from_json<GetAllHostsTask>(j);
        break;
    case BLOCK_HOST:
        p = make_from_json<BlockHostTask>(j);
        break;
    case GET_LINK_LATENCY:
        p = make_from_json<GetLinkLatencyTask>(j);
        break;
    case GET_PACKET_LOSS_RATE:
        p = make_from_json<GetPacketLossRateTask>(j);
        break;
    case GET_SWITCH_PORTS:
        p = make_from_json<GetSwitchPortsTask>(j);
        break;
    case REROUTE_FLOW:
        p = make_from_json<RerouteFlowTask>(j);
        break;
    case GET_SWITCH_MEMORY_UTILIZATION:
        p = make_from_json<GetSwitchMemoryUtilizationTask>(j);
        break;
    case GET_SWITCH_TEMPERATURE:
        p = make_from_json<GetSwitchTemperatureTask>(j);
        break;
    case SET_SWITCH_POWER_STATE:
        p = make_from_json<SetSwitchPowerStateTask>(j);
        break;
    case GET_PATH_SWITCH_COUNT:
        p = make_from_json<GetPathSwitchCountTask>(j);
        break;
    case SET_DEVICE_NICKNAME:
        p = make_from_json<SetDeviceNicknameTask>(j);
        break;
    case TOGGLE_HISTORICAL_LOGGING:
        p = make_from_json<ToggleHistoricalLoggingTask>(j);
        break;
    case GET_SWITCH_CAPABILITIES:
        p = make_from_json<GetSwitchCapabilitiesTask>(j);
        break;
    case INSTALL_GROUP_ENTRY:
        p = make_from_json<InstallGroupEntryTask>(j);
        break;
    case INSTALL_METER_ENTRY:    
        p = make_from_json<InstallMeterEntryTask>(j);
        break;


        
    case GET_DEVICE_UPTIME:
        p = make_from_json<GetDeviceUptimeTask>(j);
        break;
    case RESTART_DEVICE:
        p = make_from_json<RestartDeviceTask>(j);
        break;
    case BACKUP_CONFIGURATION:
        p = make_from_json<BackupConfigurationTask>(j);
        break;
    case RESTORE_CONFIGURATION:
        p = make_from_json<RestoreConfigurationTask>(j);
        break;
    case PING_HOST:
        p = make_from_json<PingHostTask>(j);
        break;
    case TRACEROUTE_HOST:
        p = make_from_json<TracerouteHostTask>(j);
        break;
    case GET_ARP_TABLE:
        p = make_from_json<GetArpTableTask>(j);
        break;
    case GET_MAC_TABLE:
        p = make_from_json<GetMacTableTask>(j);
        break;
    case SET_PORT_STATUS:
        p = make_from_json<SetPortStatusTask>(j);
        break;
    case GET_PORT_STATISTICS:
        p = make_from_json<GetPortStatisticsTask>(j);
        break;
    case GET_DEVICE_LOGS:
        p = make_from_json<GetDeviceLogsTask>(j);
        break;
    case CLEAR_DEVICE_LOGS:
        p = make_from_json<ClearDeviceLogsTask>(j);
        break;
    case UPDATE_DEVICE_FIRMWARE:
        p = make_from_json<UpdateDeviceFirmwareTask>(j);
        break;
    case GET_DEVICE_HEALTH:
        p = make_from_json<GetDeviceHealthTask>(j);
        break;
    case MONITOR_REAL_TIME_TRAFFIC:
        p = make_from_json<MonitorRealTimeTrafficTask>(j);
        break;
    case REQUEST_UI_FORM:
        p = make_from_json<RequestUIFormTask>(j);
        break;
    default:
        throw std::runtime_error("unknown Task type");
    }
}

// ================================ ANSWER ========================================

class Answer : public LLMResponse
{
  public:
    std::string explanation;
    bool valid;
    std::vector<std::unique_ptr<Task>> tasks;
};

inline void
to_json(nlohmann::json& j, const Answer& ans)
{
    j = nlohmann::json{
        {"explanation", ans.explanation},
        {"valid", ans.valid}
    };
    if (ans.valid)
    {
        j["tasks"] = ans.tasks;
    }
    llmResponse_to_json(j, ans);
}

inline void
from_json(const nlohmann::json& j, Answer& ans)
{
    ans.explanation = j.at("explanation").get<std::string>();
    ans.valid = j.at("valid").get<int>();

    // [Co-developed with claude code -- Adam]
    // Cleared before the loop, not only on the invalid branch. Deserialising into an Answer that
    // already held tasks used to *append*, so parsing a second response left the first response's
    // tasks in front of it and the kernel executed both -- the fourth instance in this codebase of
    // "should replace, can only add". The invalid branch cleared correctly, which is why the bug
    // only showed on the path that matters.
    ans.tasks.clear();

    if (ans.valid)
    {
        // A response claiming to be valid must actually carry tasks. `tasks: null` iterates as
        // empty in nlohmann, so `valid: true` with a null or absent tasks array used to be
        // accepted as a well-formed answer that simply did nothing -- indistinguishable, to every
        // caller, from a request the translator had genuinely satisfied.
        // `j.at()` throws json::out_of_range when the key is absent, and the type check below
        // throws json::type_error -- both are json::exception, which HttpSession::buildResponse
        // maps to 400. Throwing std::runtime_error here instead would land in the std::exception
        // catch and answer 500, turning a malformed upstream reply into "the kernel is broken".
        // That is the exact conflation removed from the wire earlier today, and the first version
        // of this fix reintroduced it -- caught by an existing test that asserts the exception
        // type rather than just that something was thrown.
        const auto& tasksJson = j.at("tasks");
        if (!tasksJson.is_array())
        {
            throw nlohmann::json::type_error::create(
                302,
                std::string("Answer claims valid but \"tasks\" is ") + tasksJson.type_name() +
                    ", not an array",
                &tasksJson);
        }

        for (const auto& taskJson : tasksJson)
        {
            std::unique_ptr<Task> task;
            from_json(taskJson, task);
            ans.tasks.push_back(std::move(task));
        }
    }
    llmResponse_from_json(j, ans);
}

// ================================ DISCUSSION =====================================

class Discussion : public LLMResponse
{
  public:
    std::string prompt;
};

inline void
to_json(nlohmann::json& j, const Discussion& d)
{
    j = nlohmann::json{{"prompt", d.prompt}};
    llmResponse_to_json(j, d);
}

inline void
from_json(const nlohmann::json& j, Discussion& d)
{
    d.prompt = j.at("prompt").get<std::string>();
    llmResponse_from_json(j, d);
}

// ================================ VALIDATION =====================================

class Validation : public LLMResponse
{
  public:
    std::string errorMsg;
};

inline void
to_json(nlohmann::json& j, const Validation& v)
{
    j = nlohmann::json{{"error", v.errorMsg}};
    llmResponse_to_json(j, v);
}

inline void
from_json(const nlohmann::json& j, Validation& v)
{
    v.errorMsg = j.at("error").get<std::string>();
    llmResponse_from_json(j, v);
}

// ===================== serilalizer and deserializer for LLMResponse =====================

template <class T>
std::unique_ptr<LLMResponse>
make_llm_from_json(const json& j)
{
    auto ptr = std::make_unique<T>();
    from_json(j, *ptr);
    return ptr;
}

inline void
to_json(json& j, const std::unique_ptr<LLMResponse>& p)
{
    if (!p)
    {
        j = nullptr;
        return;
    }

    switch (p->state)
    {
    case DISCUSSION:
        to_json(j, static_cast<const Discussion&>(*p));
        break;
    case ANSWER:
        to_json(j, static_cast<const Answer&>(*p));
        break;
    case VALIDATION:
        to_json(j, static_cast<const Validation&>(*p));
        break;
    default:
        throw std::runtime_error("unknown LLMResponse state");
    }
}

inline void
from_json(const json& j, std::unique_ptr<LLMResponse>& p)
{
    switch (stateFromString(j.at("state").get<std::string>()))
    {
    case DISCUSSION:
        p = make_llm_from_json<Discussion>(j);
        break;
    case ANSWER:
        p = make_llm_from_json<Answer>(j);
        break;
    case VALIDATION:
        p = make_llm_from_json<Validation>(j);
        break;
    default:
        throw std::runtime_error("unknown LLMResponse state");
    }
}

} // namespace llmResponse