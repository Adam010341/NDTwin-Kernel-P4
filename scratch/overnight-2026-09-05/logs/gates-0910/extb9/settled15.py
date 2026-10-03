"""settled() of the given external_evidence.py on every p4runtime/solution round in the main checkout's runs/.
Frozen rounds (in external_survey_34.tsv): the verdict and the reason. 2026-10-02's three: settled / UNREADABLE only.
Nothing else of today's rounds is printed or computed beyond what settled() reads."""
import glob, importlib.util, os, sys
tool = sys.argv[1]
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(tool))
spec = importlib.util.spec_from_file_location("ee_under_test", tool)
ev = importlib.util.module_from_spec(spec); spec.loader.exec_module(ev)
R = "/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs"
frozen = {l.split("\t")[1] for l in open(sys.argv[2]) if l.startswith("p4runtime/solution\t")}
for rep in sorted(glob.glob(R + "/*_p4runtime_solution_ndtwin.md")):
    stamp = os.path.basename(rep)[:18]
    rel = "runs/" + os.path.basename(rep)
    e = dict(ev.controller_evidence(ev.controller_log(rep)), **ev.report_evidence(rep))
    try:
        ev.settled(("p4runtime", "solution"), e); v, why = "settled", ""
    except ev.Unreadable as exc:
        v, why = "UNREADABLE", str(exc).split("the block before it, and ", 1)[-1]
    if rel in frozen:
        print(f"{stamp}\tfrozen\t{v}\t{why}")
    else:
        print(f"{stamp}\ttoday\t{v}")
