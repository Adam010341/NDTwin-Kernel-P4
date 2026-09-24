# ndt serve — a local HTTP API over `ndt`

[Co-developed with claude code -- Adam]

First cut (TICKET-ndt-serve, 09-24): backend only, one user, `127.0.0.1` only, no login. Second
ticket (Adam, 09-24 21:4x): the live_cells grid and a guided walk through one cell.
Standard-library Python; nothing to install.

## Start

```bash
ndt serve --owner adam                    # the ndt verb: drives the ndt of its own tree
python3 tools/ndt_serve/serve.py --owner adam --ndt ~/.local/bin/ndt   # from a worktree
```

It prints where it listens, which `ndt` it drives (with its sha256), and where the token is.
Options: `--port` (default 8765, `0` = any free port), `--ndt` (default `~/.local/bin/ndt` —
the main checkout's, the only tree `sudo ndtwin-lab` acts in), `--state-dir` (jobs; default
`~/.local/state/ndt-serve`), `--token-file` (default `~/.config/ndt-serve/token`), `--app-root`
(where `up --app` packages may live; default `<repo>/.test_run/packages`), `--read-timeout`.

Every `NDT_*` variable of the shell that starts it is dropped, and every `ndt` call carries
`NDT_OWNER=<owner>`. Stop it with Ctrl-C or SIGTERM; running jobs are not affected.

## The API (`/api/v1/`)

Every path outside `/api/` is reserved for the Web-GUI's static files (next cut) and answers 404.

| method | path | what runs | answer |
|---|---|---|---|
| GET | `/health` | nothing | owner, the ndt path and sha256, app list, whether a job holds the slot |
| GET | `/status` | `ndt status` | rc, `rc_class`, `meaning`, full stdout/stderr |
| GET | `/status?check=1` | `ndt status --check` | same; this one is a verdict (0/1/3) |
| GET | `/apps` | `ndt apps status` | same, plus the app names ndt knows |
| GET | `/jobs[?limit=N]` | nothing | the last jobs, newest first |
| GET | `/jobs/<id>[?wait=S]` | nothing | one job; `wait` blocks up to S s (≤600) while it runs |
| GET | `/jobs/<id>/log/stdout\|stderr[?offset=&limit=]` | nothing | the raw bytes; `X-NDT-Log-Next-Offset` for polling |
| POST | `/claim` `{"minutes":1..240,"note":"..."}` | `ndt claim M [note]` | 202 + job |
| POST | `/release` `{}` | `ndt release` | 202 + job |
| POST | `/up` `{"plane":"ovs"\|"p4","hosts":4\|128}` or `{"plane":"p4","app":"<dir>"}` | `ndt up ovs` / `up 4` / `up p4 [N]` / `up p4 --app <realpath>` | 202 + job |
| POST | `/down` `{}` | `ndt down` (never `--deep`, never `--force`) | 202 + job |
| POST | `/apps/<name>/start` `{}` | `ndt apps <name>` | 202 + job |
| POST | `/apps/<name>/stop` `{}` | `ndt apps stop <name>` | 202 + job |

A POST changes the lab, so it is a **job**: it returns at once with a job id, and only one job
may run at a time (409 `busy` names the one that does). A job runs under a detached runner and
keeps running if the server dies; a restarted server finds it again from disk.

**Every POST needs:** the token in `X-NDT-Token`, `Content-Type: application/json`, and — if the
client sends an `Origin` — this server's own origin. The Host header must be
`127.0.0.1:<port>` or `localhost:<port>`. No CORS header is ever sent.

### curl

```bash
H='Host: 127.0.0.1:8765'; U=http://127.0.0.1:8765/api/v1
T="X-NDT-Token: $(cat ~/.config/ndt-serve/token)"; J='Content-Type: application/json'

curl -s -H "$H" $U/status | jq -r .stdout
curl -s -H "$H" -H "$T" -H "$J" -d '{"minutes":30,"note":"trying ndt serve"}' $U/claim
curl -s -H "$H" -H "$T" -H "$J" -d '{"plane":"ovs","hosts":4}' $U/up      # -> {"job":{"id":...}}
curl -s -H "$H" "$U/jobs/<id>?wait=300" | jq '.job | {state, rc, rc_class, meaning}'
curl -s -H "$H" $U/jobs/<id>/log/stdout
curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/apps/nsr/start
curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/down
curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/release
```

### The live_cells grid and the guided walk

Adam's ruling (09-24 21:4x): the regression cells in `tools/test_workflow/live_cells/`, opened so
he can see a fix's red and green for himself. Everything is read from the tree of the ndt the
server drives; the cells are what `run_cells.sh --list` prints.

| method | path | what runs | answer |
|---|---|---|---|
| GET | `/cells` | `run_cells.sh --list` | the 11 cells, with CELLS.md's expected verdict and which fixtures exist |
| GET | `/cells/<name>` | same | one cell |
| GET | `/cells/<name>/old` | `<cell>.sh judge tests/fixtures/live_cells/<name>/old` | the **pre-fix red**: ASSERT rows, the CELL: line, whether the failing set equals `EXPECTED-FAILS`, `PROVENANCE.md` |
| GET | `/cells/<name>/new` | the same over `new/` | the first **green**, as it was the night of the fix |
| GET | `/cells/<name>/old/raw/<file>` | nothing | a raw file of the fixture (cannot leave it) |
| POST | `/cells/<name>/run` `{}` | `run_cells.sh --cell <name> --raw-root <state>/cells-raw/…` | 202 + job, in the one slot. **Claim first** for a cell that needs the lab |
| GET | `/cells/<name>/runs/<job>` | nothing | that run's ASSERT rows, and per row: red on old/, and now |
| GET | `/jobs/<job>/raw/<path>` | nothing | a raw file of a run (cannot leave its raw root) |
| POST | `/cells/<name>/guided` `{}` | nothing | 201 + a walk |
| GET | `/guided`, `/guided/<id>` | nothing | the walks; a walk's state is derived, a GET writes nothing |
| POST | `/guided/<id>/next` `{}` | the current step | the walk, one step further (or the same step again, if it was blocked) |
| POST | `/guided/<id>/verdict` `{"verdict":"green"\|"red","note":"..."}` | nothing | Adam's call; `next` refuses to make it |
| POST | `/guided/<id>/abort` `{}` | nothing | stops the walk, and says whether its claim is still held |

A run's `rc` is run_cells.sh's: 0 is PASS **or SKIP**, so the job carries `cell_verdict` (the
cell's own CELL: line) and `rc_class` `pass` / `skip`; 1 is `fail`; 2 is `harness` -- the harness
could not run, or the restore after the cell failed and **the lab is not restored**.

A walk, for a cell that needs the lab: `old → new → status → claim → run → release → compare →
verdict` (no status/claim/release for a `requires none` cell; no `new` where there is no new/).
Every step says where to look and what green looks like. The lab is given back right after the
run -- judging reads the raw, not the lab. A step that did not come out **blocks** the walk: a
refused claim never leads to a run, a failed restore never leads to a release. The verdict is
Adam's.

```bash
G=$(curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/cells/up_target_names_a_readable_model/guided | jq -r .walk.id)
curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/guided/$G/next | jq '.walk.steps[.walk.current]'   # repeat
curl -s -H "$H" "$U/guided/$G" | jq '.walk.steps[] | {step, state, look_at}'
curl -s -H "$H" -H "$T" -H "$J" -d '{"verdict":"green","note":"h4nl_* all flipped"}' $U/guided/$G/verdict
```

## Reading an answer

`rc` is always the integer `ndt` exited with. `rc_class` and `meaning` are a per-verb reading
of it, copied from `ndt help` (trunk `fd7382a3`):

| rc_class | means |
|---|---|
| `ok` | the verb did what it says and verified it |
| `report` | plain `ndt status`: a report was printed and **nothing was judged** |
| `dirty` | ndt looked and did not like what it found (`up`/`down` rc 1) |
| `refused` | a guard said no and **nothing was done** (`up`/`down` rc 5, `claim`/`release` rc 1) |
| `nothing` | there was nothing to act on (`down` rc 3, `status --check` rc 3, `apps stop` rc 2) |
| `usage` / `failed` / `signal` / `timeout` | as named |
| `unknown` | an rc this table does not have, or a job whose rc was never recorded |

`refused` and `dirty` are never folded together: they are different questions (ndt help,
"1 AND 5 ARE DIFFERENT QUESTIONS").

Job `state`: `running`, `finished`, `orphaned` (the runner died, `ndt` is still running — it
still holds the slot), `lost` (it ended and nobody recorded its rc).

## Tests

```bash
python3 tests/python/test_ndt_serve.py        # 51 cases against a stub ndt, no lab
python3 tests/python/test_ndt_serve_cells.py  # 25 cases against a stub grid, no lab
bash tests/shell/mutate_ndt_serve.sh          # 58 named mutations, each must redden its case
```
