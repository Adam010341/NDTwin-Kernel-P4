"""
Point the table-entry journal at a temp directory before anything imports `proxy_agent.main`.

[Co-developed with claude code -- Adam]

`main` builds its `table_journals` AT IMPORT, from `NDTWIN_TABLE_JOURNAL_DIR` or, without it,
`p4_proxy/.run/table_entry_journal` -- the directory a running proxy on this machine replays at
its next start. Since the replay, `main.startup` writes a header into every switch's file (step
0, before the first push), so every startup test, and every POST through the route that `main`
wired, would otherwise write into the checkout's live journal: in a shared checkout, somebody's
fabric's journal.

So every test module that imports `main` imports this module first. It sets the variable for the
whole process to a fresh temp directory, removed at exit, whatever the variable said before (a
test must never write a real journal, even one the caller's shell points at), and refuses loudly
when `main` was imported before it -- by then the journals already point wherever they point.
`tests/shell/check_no_stray_table_journal.sh` is the check that this is enough: it runs the whole
directory in one process and fails if `.run/table_entry_journal` changed.

Not named `test_*`: discovery must not collect it.
"""

import atexit
import os
import shutil
import sys
import tempfile

ENV_VAR = "NDTWIN_TABLE_JOURNAL_DIR"

if "proxy_agent.main" in sys.modules and not os.environ.get("NDTWIN_TEST_JOURNAL_ISOLATED"):
    raise RuntimeError(
        "proxy_agent.main was imported before tests/journal_isolation.py: its table-entry "
        "journals already point at %r. Import journal_isolation before main in every test module."
        % getattr(getattr(sys.modules["proxy_agent.main"], "table_journals", None),
                  "directory", None))

if not os.environ.get("NDTWIN_TEST_JOURNAL_ISOLATED"):
    DIRECTORY = tempfile.mkdtemp(prefix="ndt-test-table-journal-")
    os.environ[ENV_VAR] = DIRECTORY
    os.environ["NDTWIN_TEST_JOURNAL_ISOLATED"] = DIRECTORY
    atexit.register(shutil.rmtree, DIRECTORY, True)
else:
    DIRECTORY = os.environ["NDTWIN_TEST_JOURNAL_ISOLATED"]
