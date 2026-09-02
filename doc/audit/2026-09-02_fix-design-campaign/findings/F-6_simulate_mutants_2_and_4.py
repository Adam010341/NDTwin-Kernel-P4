"""Apply mutations 2 and 4 to a COPY of StaleTableCarryForward.hpp and check, without compiling,
that each mutant still READS the const local whose unused-ness broke run 1.

Run 1 failures (F-6_gate_run1.log:24,39):
    StaleTableCarryForward.hpp:226: error: unused variable 'staleSince'  [-Werror=unused-variable]
    StaleTableCarryForward.hpp:230: error: unused variable 'priorPolls'  [-Werror=unused-variable]

A read is what silences BOTH -Wunused-variable and -Wunused-but-set-variable, so the check is
"the identifier still appears somewhere other than its own declaration".

Run from the repo root.
"""
import pathlib
import re
import sys

HDR = pathlib.Path("include/ndt_core/power_management/StaleTableCarryForward.hpp")
src = HDR.read_text()

MUTANTS = [
    ("2. stale_since is never set",
     "        entry[kStaleSinceField] = staleSince;",
     "        entry[kStaleSinceField] = staleSince;\n"
     "        entry.erase(kStaleSinceField); // MUTANT: stale_since never reaches the consumer",
     "staleSince",
     "stale_since must be ABSENT from the carried entry"),
    ("4. stale_polls never accumulates",
     "        entry[kStalePollsField] = priorPolls + 1;",
     "        entry[kStalePollsField] = priorPolls; // MUTANT: assigned, never accumulated",
     "priorPolls",
     "stale_polls must stay at its prior value (0) forever"),
]

bad = 0
for label, anchor, repl, ident, intent in MUTANTS:
    print(f"=== {label} ===")
    if src.count(anchor) != 1:
        print(f"  BAD anchor occurs {src.count(anchor)}x"); bad += 1; continue
    mutated = src.replace(anchor, repl, 1)

    # Declaration line for the const local, then every other mention.
    decl = re.search(rf"^\s*const std::int64_t {ident} =", mutated, re.M)
    mentions = [m.start() for m in re.finditer(rf"\b{ident}\b", mutated)]
    reads = [p for p in mentions if not (decl and decl.start() <= p < decl.end())]
    # The initialiser of the declaration spans several lines; count only mentions AFTER the
    # statement's terminating semicolon as genuine reads.
    stmt_end = mutated.index(";", decl.start()) if decl else -1
    real_reads = [p for p in mentions if p > stmt_end]

    print(f"  intent : {intent}")
    print(f"  '{ident}' mentions: {len(mentions)}  reads after its declaration: {len(real_reads)}")
    if real_reads:
        print(f"  ok   still read -> neither -Wunused-variable nor -Wunused-but-set-variable fires")
    else:
        print(f"  BAD  no read after the declaration -- this is exactly what broke run 1")
        bad += 1

    start = mutated.index("        const std::int64_t staleSince")
    end = mutated.index("fresh.push_back", start)
    print("  --- mutated block ---")
    for line in mutated[start:end].rstrip().splitlines():
        print("   |" + line)
    print()

print("BOTH MUTANTS READ THEIR LOCAL" if not bad else f"{bad} PROBLEM(S)")
sys.exit(1 if bad else 0)
