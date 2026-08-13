"""
Which /ndt/* endpoints each workspace component actually depends on.

Measured, not guessed: produced by grepping every component's source for /ndt/ URLs
(see doc/2026-07-27_testing_workflow.md for the resulting table). This is what makes L3 possible --
when the kernel changes an endpoint we can say exactly which components break, instead
of launching all seven and eyeballing them.

KERNEL_ENDPOINTS is the kernel's real dispatch table, transcribed from the
if/else-if chain in src/ndt_core/http/HttpSession.cpp. The method matters: the kernel
matches on (method, target) together, so a GET to a POST-only endpoint falls through to
404 and would look like a missing endpoint.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import os

# endpoint name -> HTTP method the kernel accepts.
# Transcribed from HttpSession.cpp; keep in sync when endpoints are added.
KERNEL_ENDPOINTS = {
    "link_failure_detected": "POST",
    "link_recovery_detected": "POST",
    "get_graph_data": "GET",
    "get_detected_flow_data": "GET",
    "get_detected_top_k_flow_data": "GET",
    "get_switch_openflow_table_entries": "GET",
    "get_power_report": "GET",
    "get_switches_power_state": "GET",
    "set_switches_power_state": "POST",
    "install_flow_entry": "POST",
    "delete_flow_entry": "POST",
    "modify_flow_entry": "POST",
    "install_group_entry": "POST",
    "delete_group_entry": "POST",
    "modify_group_entry": "POST",
    "install_meter_entry": "POST",
    "delete_meter_entry": "POST",
    "modify_meter_entry": "POST",
    "install_flow_entries_modify_flow_entries_and_delete_flow_entries": "POST",
    "get_cpu_utilization": "GET",
    "get_memory_utilization": "GET",
    "inform_switch_entered": "GET",
    "modify_device_name": "POST",
    "received_a_simulation_case": "POST",
    "simulation_completed": "POST",
    "get_static_topology_json": "GET",
    "inform_all_destination_paths": "POST",
    "app_register": "POST",
    "intent_translator/text": "POST",
    "get_nickname": "GET",
    "modify_nickname": "POST",
    "get_temperature": "GET",
    "get_path_switch_count": "GET",
    "get_openflow_capacity": "GET",
    "historical_logging": "POST",
    "get_average_link_usage": "GET",
    "get_total_input_traffic_load_passing_a_switch": "POST",
    "get_num_of_flows_passing_a_switch": "POST",
    "acquire_lock": "POST",
    "renew_lock": "POST",
    "release_lock": "POST",
}


# Endpoints a component calls that the kernel does not implement, acknowledged here with
# a reason. Same principle as the log and baseline allowlists: a known gap is recorded so
# that a NEW one fails the check instead of being lost among the ones already tolerated.
# Removing the call or implementing the endpoint should also delete the entry.
KNOWN_MISSING_ENDPOINTS = {
    "disable_switch": (
        "Energy-Saving-App has a disable_switch() that POSTs /ndt/disable_switch "
        "(src/app/http.cpp:269) and the kernel has never registered it, so MISSING is "
        "correct. But that function has ZERO call sites -- it is dead code, and the live "
        "energy-saving path uses /ndt/set_switches_power_state (2 call sites, verified "
        "200). So this does NOT mean energy saving has never switched anything off; an "
        "earlier note here said that and it was wrong. Fix by deleting the dead function "
        "or implementing the endpoint. [Co-developed with claude code -- Adam]"
    ),
}


# Directory holding the sibling component repos. Previously these were hardcoded to
# /home/adam/..., which broke on any other checkout.
#
# Discovered rather than assumed at a fixed depth: the kernel repo is not necessarily a
# direct sibling of the others (here it sits in Desktop/ while they are one level up), so
# counting dirname() calls is wrong on some layouts and right on others by luck. This walks
# up from the kernel repo looking for a directory that actually contains a known component,
# and NDTWIN_WORKSPACE_ROOT overrides it outright.
_KERNEL_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_MARKER_COMPONENT = "Energy-Saving-App"


def _discover_workspace_root() -> str:
    override = os.environ.get("NDTWIN_WORKSPACE_ROOT")
    if override:
        return override

    current = os.path.dirname(_KERNEL_REPO)
    for _ in range(4):  # a few levels is plenty; avoids walking to /
        if os.path.isdir(os.path.join(current, _MARKER_COMPONENT)):
            return current
        parent = os.path.dirname(current)
        if parent == current:  # reached the filesystem root
            break
        current = parent

    # Nothing found: fall back to the kernel's parent. The paths will not exist, which L0
    # and L3 report as such rather than pretending the components are present.
    return os.path.dirname(_KERNEL_REPO)


WORKSPACE_ROOT = _discover_workspace_root()


def component_path(repo_name: str) -> str:
    """Path to a sibling component repo, honouring NDTWIN_WORKSPACE_ROOT."""
    return os.path.join(WORKSPACE_ROOT, repo_name)


class Component:
    def __init__(self, name, path, language, endpoints, writes, launch_note=""):
        self.name = name
        self.path = path
        self.language = language
        self.endpoints = endpoints
        self.writes = writes            # does it change network state?
        self.launch_note = launch_note

    def unknown_endpoints(self) -> list[str]:
        """Endpoints this component calls that the kernel does not implement."""
        return [e for e in self.endpoints if e not in KERNEL_ENDPOINTS]


COMPONENTS = [
    Component(
        "Energy-Saving-App", component_path("Energy-Saving-App"), "C++",
        [
            "get_graph_data",
            "get_detected_flow_data",
            "get_switch_openflow_table_entries",
            "get_average_link_usage",
            "install_flow_entry",
            "modify_flow_entry",
            "delete_flow_entry",
            "install_flow_entries_modify_flow_entries_and_delete_flow_entries",
            "set_switches_power_state",
            "acquire_lock",
            "release_lock",
            "app_register",
            "received_a_simulation_case",
            # Called from src/app/http.cpp:269. The kernel has no such endpoint, so this
            # has always been returning 404 with the app swallowing the error.
            "disable_switch",
        ],
        writes=True,
        launch_note="needs Simulation-Platform-Manager running for simulation cases",
    ),
    Component(
        "Traffic-Engineering-App", component_path("Traffic-Engineering-App"), "Python",
        ["get_graph_data", "get_detected_flow_data", "install_flow_entry",
         "acquire_lock", "release_lock"],
        writes=True,
        launch_note="conda env te-env",
    ),
    Component(
        "Web-GUI", component_path("Web-GUI"), "React + Node + Postgres (Docker)",
        ["get_graph_data", "get_detected_flow_data", "get_detected_top_k_flow_data",
         "get_switch_openflow_table_entries", "get_cpu_utilization",
         "get_memory_utilization", "get_temperature", "get_nickname",
         "modify_nickname", "modify_device_name",
         "install_flow_entries_modify_flow_entries_and_delete_flow_entries",
         "intent_translator/text"],
        writes=True,
        launch_note="docker compose; needs NDT_API_BASE_URL pointing at the kernel",
    ),
    Component(
        "Network-Traffic-Visualizer", component_path("Network-Traffic-Visualizer"),
        "JavaFX (JDK 21)",
        ["get_graph_data", "get_detected_flow_data", "get_detected_top_k_flow_data",
         "get_cpu_utilization", "get_memory_utilization"],
        writes=False,
        launch_note="needs a display; config.properties sets ndt.api.url",
    ),
    Component(
        "Network-State-Recorder", component_path("Network-State-Recorder"), "Python",
        ["get_graph_data", "get_detected_flow_data"],
        writes=False,
        launch_note="conda env ntg-env; writes zipped JSON snapshots",
    ),
    Component(
        "Network-Traffic-Generator", component_path("Network-Traffic-Generator"), "Python",
        ["get_graph_data", "get_path_switch_count"],
        writes=False,
        launch_note="conda env ntg-env; generates real traffic inside Mininet",
    ),
    Component(
        "Simulation-Platform-Manager", component_path("Simulation-Platform-Manager"), "C++",
        ["app_register", "received_a_simulation_case", "simulation_completed"],
        writes=False,
        launch_note="shares files with apps over NFS",
    ),
]


def scan_kernel_dispatch(http_session_cpp: str) -> dict[str, str]:
    """
    Parse the real dispatch table out of HttpSession.cpp.

    KERNEL_ENDPOINTS above is hand-transcribed, so it rots the moment someone adds an
    endpoint. This reads the source directly, letting check_dispatch_drift() prove the
    two still agree instead of trusting that they do.

    Matches both spellings used in the chain:
        method == http::verb::get && target == "/ndt/x"
        method == http::verb::post && target.starts_with("/ndt/x")

    [Co-developed with claude code -- Adam]
    """
    import re

    with open(http_session_cpp, encoding="utf-8") as fh:
        src = fh.read()

    pattern = re.compile(
        r"http::verb::(?P<verb>get|post|put|delete_|patch)\s*&&\s*"
        r"target(?:_path)?\s*(?:==|\.starts_with\s*\()\s*"
        r'"(?P<path>/ndt/[^"]*)"',
        re.MULTILINE,
    )
    found: dict[str, str] = {}
    for m in pattern.finditer(src):
        verb = m.group("verb").rstrip("_").upper()
        name = m.group("path").removeprefix("/ndt/").rstrip("?").rstrip("/")
        found[name] = verb
    return found


def check_dispatch_drift(http_session_cpp: str) -> list[str]:
    """Returns human-readable drift messages; empty means the table is accurate."""
    try:
        actual = scan_kernel_dispatch(http_session_cpp)
    except OSError as exc:
        return [f"cannot read {http_session_cpp}: {exc}"]

    problems = []
    for name, verb in sorted(actual.items()):
        if name not in KERNEL_ENDPOINTS:
            consumers = endpoint_consumers().get(name)
            extra = f" (used by {', '.join(consumers)})" if consumers else ""
            problems.append(
                f"kernel registers {verb} /ndt/{name} but KERNEL_ENDPOINTS omits it{extra}")
        elif KERNEL_ENDPOINTS[name] != verb:
            problems.append(
                f"/ndt/{name}: kernel uses {verb}, KERNEL_ENDPOINTS says "
                f"{KERNEL_ENDPOINTS[name]} -- a probe with the wrong method gets a 404 "
                f"and looks like a missing endpoint")
    for name in sorted(KERNEL_ENDPOINTS):
        if name not in actual:
            problems.append(
                f"KERNEL_ENDPOINTS lists /ndt/{name} but the kernel no longer registers it")
    return problems


def endpoint_consumers() -> dict[str, list[str]]:
    """Reverse index: endpoint -> components that depend on it, most-used first."""
    index: dict[str, list[str]] = {}
    for comp in COMPONENTS:
        for ep in comp.endpoints:
            index.setdefault(ep, []).append(comp.name)
    return dict(sorted(index.items(), key=lambda kv: (-len(kv[1]), kv[0])))


def blast_radius(endpoint: str) -> list[str]:
    """Which components break if this endpoint breaks."""
    return endpoint_consumers().get(endpoint, [])
