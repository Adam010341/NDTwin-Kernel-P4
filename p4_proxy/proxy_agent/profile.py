"""Which app package this proxy process is serving. One answer, decided once, at import.

[Co-developed with claude code -- Adam]

`mininet/app_package.py` knows how to read a package; this module is the proxy's single entry
to it. Two reasons it is its own file rather than three lines in `main.py`:

  * `main.py` builds its host table and its switch list at IMPORT time, and both of those now
    depend on the package. A decision made inside a function they call would be made twice, and
    two reads of a file an operator can edit are two chances to disagree.
  * the decision has to be announced. A proxy running somebody's package while printing nothing
    is the failure shape this whole feature is meant to remove, so the answer is printed on the
    line after it is taken, before any switch is dialled.

The decision is cached in `_CURRENT`. `reload()` exists for tests -- an import-time decision is
otherwise unreachable from a test that wants to see the other branch, and "we could not test the
package branch" is how the package branch ships broken.
"""
from __future__ import annotations

import os
import sys

# [Co-developed with claude code -- Adam]
# Same insert main.py makes for grpc_ports, and for the same reason: app_package is shared with
# the Mininet topology script, which lives in mininet/ and is launched as a script from there.
# One copy of the reader, two very different processes. This runs before main.py's own insert
# because main.py imports this module while building its host table.
_MININET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet")
if _MININET_DIR not in sys.path:
    sys.path.insert(0, _MININET_DIR)

import app_package  # noqa: E402
from app_package import AppPackageError, Package  # noqa: E402,F401 -- re-exported for callers

_CURRENT = None


def _announce(package):
    print(f"[Proxy Agent] app package: {package.dir or 'baseline'}"
          f" (mode {package.mode}, election_id {package.election_id[0]},{package.election_id[1]})")


def reload(knob_path=None, announce=True) -> Package:
    """Re-read the knob and replace the cached decision. Returns the new one.

    The proxy never calls this: its package is whatever was on disk when it started, because a
    package that changed halfway through a run would leave half the fabric built from each.
    Tests call it, and so does anything that wants the other branch on purpose.
    """
    global _CURRENT
    _CURRENT = app_package.current(knob_path)
    if announce:
        _announce(_CURRENT)
    return _CURRENT


def current() -> Package:
    """The package this process is serving. Decided at import; never re-read."""
    if _CURRENT is None:
        return reload()
    return _CURRENT


# Decided here, at import, and announced. A failure to read the knob or the package it names
# propagates out of this import and the proxy does not start -- which is the intended outcome:
# starting on the baseline fabric because somebody's package would not parse is exactly the
# silent substitution that makes a P4 exercise report zero instead of reporting an error.
reload()

# [Co-developed with claude code -- Adam]
