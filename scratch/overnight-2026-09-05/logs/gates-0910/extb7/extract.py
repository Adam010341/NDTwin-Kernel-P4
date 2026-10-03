# extract.py <README> <out dir> -- the fenced code of steps 0, 2 and 6 of "合併前的比對", verbatim
import re, sys, os
s = open(sys.argv[1]).read().splitlines()
out = sys.argv[2]
heads = {"0": "0. **凍結", "2": "2. **merge B", "6": "6. **"}
for k, h in heads.items():
    i = next(n for n, l in enumerate(s) if l.startswith(h))
    a = next(n for n in range(i, len(s)) if s[n].strip().startswith("```"))
    b = next(n for n in range(a + 1, len(s)) if s[n].strip().startswith("```"))
    body = "\n".join(l[3:] if l.startswith("   ") else l for l in s[a + 1:b])
    open(os.path.join(out, f"step{k}.sh"), "w").write(body + "\n")
print("extracted 0 2 6 from", sys.argv[1])
