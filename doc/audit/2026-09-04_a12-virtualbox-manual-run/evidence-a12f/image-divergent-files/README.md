# The five files where the image diverges from the commit its PROVENANCE.txt names

These are copies **taken off the published P4/BMv2 demo image**, not from this repository.
They are the evidence behind **D18**: `PROVENANCE.txt` states the tree is
`20cd80b62948e316646dd24f302f5278fee544ee` minus `doc/`, and 400 of the 405 tracked files
outside `doc/` hash identically -- these five do not.

| file | on the image | in `20cd80b` |
| :--- | :--- | :--- |
| `intelligent_router.py` | 724 lines, `sha256 c994bf5c…`, hardcodes `/home/tester/…` | 2084 lines, `sha256 1a3937bb…` |
| `p4_proxy/proxy_agent/main.py` | 405 lines | 358 lines |
| `testbed_topo.py` | 240 lines | 257 lines |
| `p4_proxy/mininet/host_count_override` | `4` | `128` |
| `p4_proxy/mininet/bmv2_binary_override` | bare path, comments stripped | same path with its rationale |

`intelligent_router.py` here is the copy that carries D13: the one-shot flag is set on the line
immediately before the install call. The version in `20cd80b` has not had that shape since
`2c81b26b` (2026-07-31).

To reproduce the comparison:

```bash
git ls-tree -r 20cd80b | grep -v $'\t'doc/ | awk '{print $3"  "substr($0,index($0,$4))}' > tree.txt
# on the image, where git 2.43 is installed but .git is not:
while read -r sha path; do
  h=$(git hash-object "$KERNEL/$path"); [ "$h" = "$sha" ] || echo "DIFFER $path"
done < tree.txt
```

⚠️ These were rescued from a session scratchpad, which does not survive the session. They are
here because nothing else holds them.

[Co-developed with claude code -- Adam]
