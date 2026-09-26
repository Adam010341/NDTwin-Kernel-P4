"""Flatten a JSON capture into sorted path=value lines, masking fields that are readings of WHEN
(timestamps, ages, per-boot ids). Masked values are printed as <masked> so the KEY set is still
compared. [Co-developed with claude code -- Adam]"""
import json, re, sys
VOLATILE = re.compile(r"(_at$|_age_s$|^boot_id$|^table_generation$|^boot_at$|_ts$|^timestamp$|"
                      r"^last_.*|^uptime.*|_time$|^time$|^epoch$|^now$|^generated$)")
def walk(p, v, out):
    if isinstance(v, dict):
        for k in sorted(v):
            walk(p + "." + str(k), v[k], out)
    elif isinstance(v, list):
        # lists of dicts with an id-ish key are keyed by it, else by index after sorting reprs
        if v and all(isinstance(x, dict) for x in v):
            key = next((k for k in ("dpid", "id", "name", "ip", "mac", "src", "device_id") if all(k in x for x in v)), None)
            if key:
                for x in sorted(v, key=lambda x: json.dumps(x.get(key), sort_keys=True)):
                    walk(p + "[%s=%s]" % (key, x.get(key)), x, out)
                return
            for i, x in enumerate(sorted(v, key=lambda x: json.dumps(x, sort_keys=True))):
                walk(p + "[#%d]" % i, x, out)
            return
        out.append("%s = %s" % (p, json.dumps(sorted(v, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True)))
    else:
        leaf = p.rsplit(".", 1)[-1]
        out.append("%s = %s" % (p, "<masked>" if VOLATILE.search(leaf) else json.dumps(v)))
out = []
walk("", json.load(open(sys.argv[1])), out)
print("\n".join(sorted(out)))
