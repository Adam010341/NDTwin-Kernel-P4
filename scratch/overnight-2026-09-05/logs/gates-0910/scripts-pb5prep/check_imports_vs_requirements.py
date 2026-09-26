"""Is every third-party package that p4_proxy and tools/p4_exercise IMPORT listed in requirements.txt?

Worker REQ, round 2 (judge finding #1). check_pins_vs_venv.py compares the lines a requirements
file HAS with a venv; it cannot see a line that is missing. starlette was exactly that: imported
directly (proxy_agent/api_routes.py:3 and two tests) but reaching the venv only as fastapi's
dependency, so a fresh install floated it 1.3.1 -> 1.7.0. This check walks the imports instead.

  <tested venv>/bin/python check_imports_vs_requirements.py <repo root> <requirements.txt>

  * Every .py under p4_proxy/ (venv/ excluded) and tools/p4_exercise/ is parsed with ast; every
    absolute `import x` / `from x import y` is collected, at any depth (function bodies and
    try-blocks included -- a lazy import is still an import).
  * stdlib = sys.stdlib_module_names. local = a module or package of that name exists anywhere
    under p4_proxy/ or tools/ (these scripts put their own directories on sys.path). A directory
    WITHOUT __init__.py is only a namespace portion, and a regular package of the same name
    anywhere on sys.path wins over it (PEP 420) -- so such a name counts as local only when no
    installed distribution provides it and no exclusion names it. That is what keeps
    p4_proxy/mininet/ (no __init__.py) from hiding the real `mininet` package.
  * Everything else is mapped to the distribution that provides it IN THE RUNNING INTERPRETER, by
    the distributions' own file lists (importlib.metadata; nothing third-party is imported). The
    deepest path prefix wins, so google.protobuf -> protobuf and google.rpc -> googleapis-common-protos.
  * RED if a distribution is imported and not named in the file (MISSING), or an import resolves to
    nothing installed and no declared exclusion covers that exact file (UNRESOLVED).
  * EXCLUSIONS are per (module, file) with a reason: an exclusion never covers a file it does not
    name, so the same module imported from somewhere new is red again.

[Co-developed with claude code -- Adam]
"""
import ast
import importlib.metadata as md
import os
import re
import sys

repo, req_path = os.path.abspath(sys.argv[1]), sys.argv[2]
SCAN = ["p4_proxy", "tools/p4_exercise"]
LOCAL_ROOTS = ["p4_proxy", "tools"]

# module -> (files it may be imported from, why that file does not run under p4_proxy/venv)
EXCLUSIONS = {
    "mininet": ({"p4_proxy/mininet/p4_testbed_topo.py", "p4_proxy/mininet/ntg_bmv2_topo.py"},
                "the topology bridge: run as root by ndtwin-lab with NTG_PY "
                "(=/home/adam/miniconda3/envs/ntg-env/bin/python, ndtwin-lab:99,564,581), not the proxy venv"),
    "network_traffic_generator": ({"p4_proxy/mininet/ntg_bmv2_topo.py"}, "same file, same interpreter (NTG_PY)"),
    "nornir": ({"p4_proxy/mininet/ntg_bmv2_topo.py"}, "same file, same interpreter (NTG_PY)"),
    "p4runtime_lib": ({"tools/p4_exercise/run_external_controller.py",
                       "tools/p4_exercise/tests/fixtures/p4runtime/mycontroller.py"},
                      "the p4lang tutorials' utils/ library, put on sys.path at run time "
                      "(run_external_controller.py:116-175); not a PyPI package"),
}


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def skip_dir(d):
    return d in ("venv", "__pycache__") or d.startswith(".")


# --- collect imports ------------------------------------------------------------------------------
imports = {}   # dotted module -> set(files)
for root in SCAN:
    for dp, dn, fn in os.walk(os.path.join(repo, root)):
        dn[:] = sorted(d for d in dn if not skip_dir(d))
        for f in sorted(fn):
            if not f.endswith(".py"):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, repo)
            tree = ast.parse(open(p, encoding="utf-8").read(), filename=rel)
            for n in ast.walk(tree):
                if isinstance(n, ast.Import):
                    for a in n.names:
                        imports.setdefault(a.name, set()).add(rel)
                elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                    imports.setdefault(n.module, set()).add(rel)

# --- local names ----------------------------------------------------------------------------------
local, namespace_local = set(), set()
for root in LOCAL_ROOTS:
    for dp, dn, fn in os.walk(os.path.join(repo, root)):
        dn[:] = [d for d in dn if not skip_dir(d)]
        for f in fn:
            if f.endswith(".py"):
                local.add(f[:-3])
        for d in dn:
            entries = os.listdir(os.path.join(dp, d))
            if "__init__.py" in entries:
                local.add(d)
            elif any(x.endswith(".py") for x in entries):
                namespace_local.add(d)

# --- installed distributions: path prefix -> distribution -----------------------------------------
prefix_to_dist = {}   # ("google","protobuf") / ("grpc",) -> set(dist names)
for dist in md.distributions():
    name = dist.metadata["Name"]
    for f in dist.files or []:
        parts = f.parts
        if not parts or parts[0].endswith((".dist-info", ".egg-info", ".data")) or parts[0] == "..":
            continue
        for depth in (1, 2):
            if len(parts) > depth or (len(parts) == depth and parts[-1].endswith(".py")):
                key = tuple(p[:-3] if p.endswith(".py") else p for p in parts[:depth])
                prefix_to_dist.setdefault(key, set()).add(name)


def resolve(mod):
    parts = tuple(mod.split("."))
    for depth in (2, 1):
        if len(parts) >= depth and parts[:depth] in prefix_to_dist:
            d = prefix_to_dist[parts[:depth]]
            if len(d) == 1:
                return next(iter(d))
    return None


listed = {}
for raw in open(req_path, encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if line:
        listed[norm(re.match(r"^([A-Za-z0-9_.\-]+)", line).group(1))] = line

# --- verdicts -------------------------------------------------------------------------------------
print(f"# interpreter {sys.executable}  prefix {sys.prefix}  python {sys.version.split()[0]}")
print(f"# requirements {os.path.abspath(req_path)}")
print(f"# scanned: {', '.join(SCAN)} under {repo}; {len(imports)} distinct absolute imports")
by_dist, red, excluded_used = {}, 0, set()
for mod in sorted(imports):
    top = mod.split(".")[0]
    if top in sys.stdlib_module_names or top == "__future__" or top in local:
        continue
    if top in namespace_local and top not in EXCLUSIONS and (top,) not in prefix_to_dist:
        continue
    dist = resolve(mod)
    files = imports[mod]
    if dist is None:
        ex = EXCLUSIONS.get(top)
        uncovered = sorted(files - ex[0]) if ex else sorted(files)
        if ex and not uncovered:
            excluded_used.add(top)
            print(f"EXCLUDED     {mod:36s} {sorted(files)} -- {ex[1]}")
        else:
            red += 1
            print(f"UNRESOLVED   {mod:36s} nothing installed provides it; not excused for {uncovered}")
        continue
    by_dist.setdefault(dist, {}).setdefault(mod, set()).update(files)

for dist in sorted(by_dist, key=norm):
    mods = by_dist[dist]
    files = sorted(set().union(*mods.values()))
    ok = norm(dist) in listed
    red += not ok
    print(f"{'LISTED ' if ok else 'MISSING'}      {dist:26s} "
          f"{'(' + listed[norm(dist)] + ')' if ok else 'imported but NOT in the file'}")
    for m in sorted(mods):
        print(f"               {m:40s} {len(mods[m])} file(s): {', '.join(sorted(mods[m]))}")

imported = {norm(d) for d in by_dist}
for n, line in sorted(listed.items()):
    if n not in imported:
        print(f"INFO         listed, not imported directly by the scanned code: {line}")
for top in sorted(set(EXCLUSIONS) - excluded_used):
    print(f"INFO         exclusion '{top}' matched nothing (stale?)")
collide = sorted(n for n in local | namespace_local if (n,) in prefix_to_dist or n in EXCLUSIONS)
if collide:
    print(f"INFO         local names that an installed distribution or an exclusion also claims: {collide}")
print(f"RESULT: {'GREEN' if red == 0 else 'RED'} ({red} problem(s))")
sys.exit(1 if red else 0)
