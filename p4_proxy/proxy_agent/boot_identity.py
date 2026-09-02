"""
Which proxy process is answering.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES A-4c. A proxy restart re-pushes the pipeline to every switch
(`main.startup` -> `P4RuntimeClient.set_forwarding_pipeline_config`), and a
VERIFY_AND_COMMIT push wipes every table entry -- measured live 2026-08-16, see
`p4_client.write_clone_session`'s docstring. bmv2 is never restarted, so from the outside
nothing happened: the process kept running, the port stayed open, the graph stayed at
40/40 edges. `install_initial_routes` then refills the bring-up shortest paths, so the
tables are not even empty afterwards. What is gone is every rule installed *since*
bring-up, and the twin has nothing left to compare against -- the kernel has no intent
store at all (`FlowRoutingManager` keeps no installed-entry map; `DispatchOutcomeLog`
discards a successful job's actions; `m_cachedOpenFlowTables` is replaced wholesale every
~10 s by the poll), so there is no statement anywhere that rule X was ever requested.

This module is the smallest thing that makes the event *sayable*. It does not restore
anything and deliberately does not try to: a reader that cannot detect the wipe cannot
audit a recovery either, so honesty has to land first.

Why a module-level constant rather than something startup() mints: the identity must be
the same for every reader and must not depend on startup having been reached. A proxy that
crashed halfway through startup and was restarted is exactly the case where a reader most
needs to know it is talking to a different process.

Why this is not enough on its own, and what pairs with it: the destructive act is a
pipeline commit against ONE switch, and `POST /p4/readopt/{dpid}` does that without any
restart (topology_manager.readopt_switch). A process-level id cannot see that, so each
client also carries a per-switch `table_generation` token that changes on every commit.
The reader's question is "(boot_id, table_generation) -- either one different from what I
last saw?", and either difference means "assume everything you installed on that switch is
gone".
"""

from __future__ import annotations

import time
import uuid

#: Identifies this proxy process. Regenerated on every start, never during a run.
#:
#: A reader that sees a different value than last poll is talking to a process whose
#: `TopologyManager._installed_routes` was rebuilt from scratch (topology_manager.py builds
#: it as a plain dict in __init__ with no persistence), so everything the proxy says about
#: which rules exist is derived from what *this* process re-installed.
BOOT_ID: str = uuid.uuid4().hex

#: Wall clock at import, so a reader can put an age on the restart without aligning clocks.
#: Wall clock rather than monotonic precisely because it is meant to cross a process
#: boundary -- a monotonic value from another process means nothing here.
BOOT_AT: float = time.time()


def new_table_generation() -> str:
    """
    A token for one switch's table lifetime, valid until the next pipeline commit wipes it.

    Opaque and compared only for equality. It is deliberately not a counter: `readopt`
    replaces a switch's client object, so a counter living on the client restarts at zero
    and a reader watching for "the number went up" would see it go *down* on the one path
    that wipes a table without a proxy restart. A token has no direction to get wrong.
    """
    return uuid.uuid4().hex
