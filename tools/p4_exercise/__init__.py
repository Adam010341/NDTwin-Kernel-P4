"""Tools that turn a p4lang-tutorials exercise into an NDTwin P4 app package.

[Co-developed with claude code -- Adam]

Three entry points, all pure-python, none of them needing root and none of them touching a
running fabric:

  * ``convert.py``  -- tutorials ``topology.json`` (+ its ``sX-runtime.json``) -> a package
                       directory holding ``package.json`` and an NDTwin topology model.
  * ``preflight.py`` -- reads a package back and says, item by item, whether the fabric would
                       be able to use it. Run before ``ndt up p4 --app``, not after.
  * ``run_external_controller.py`` -- runs an exercise's own controller against NDTwin's gRPC
                       port block by rewriting the addresses it hard-codes.

Deliberately NOT importable from the proxy: these tools read ``p4_proxy/mininet`` (to check a
generated model with the same reader the fabric uses) and never the other way round.
"""
