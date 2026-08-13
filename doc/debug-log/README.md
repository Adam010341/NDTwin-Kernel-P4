# doc/debug-log

[Co-developed with claude code -- Adam]

Where log excerpts get pasted while investigating something. Kept deliberately, and kept empty:
git cannot store an empty directory, so `.gitkeep` holds the path open.

This is not decoration. Two places in the source cite this directory as an established habit, and
one of them is a *reason for a test*:

- `src/ndt_core/intent_translator/LLMAgent.cpp:32` — the argument for never letting an API key
  reach the log is partly that log excerpts from this project routinely end up pasted into
  `doc/debug-log/` and into handoff documents, i.e. somewhere much less guarded than the log file.
- `tests/test_ApiKeyNotLogged.cpp:13` — the test that enforces it, citing the same reason.

Delete the directory and those two comments start describing a convention that no longer exists,
which is how a test loses the explanation for why it is worth keeping.

Contents are not committed — paste what you need while debugging, and clean up after.
