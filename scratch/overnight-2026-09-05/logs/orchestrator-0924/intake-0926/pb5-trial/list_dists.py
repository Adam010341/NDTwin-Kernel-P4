import importlib.metadata as md
print("\n".join(sorted("%s==%s" % (d.metadata["Name"].lower(), d.version) for d in md.distributions())))
