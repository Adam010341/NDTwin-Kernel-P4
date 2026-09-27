# ndt serve — a local HTTP API over `ndt`

[Co-developed with claude code -- Adam]

First cut (TICKET-ndt-serve, 09-24): backend only, one user, `127.0.0.1` only, no login. Second
ticket (Adam, 09-24 21:4x): the live_cells grid and a guided walk through one cell. GUI cut
(Adam's Q2/Q3 rulings, 09-27): the page at `/` -- see "The page" below.
Standard-library Python and one static page; nothing to install.

## Start

```bash
ndt serve --owner adam                    # the ndt verb: drives the ndt of its own tree
python3 tools/ndt_serve/serve.py --owner adam --ndt ~/.local/bin/ndt   # from a worktree
```

It prints where it listens, which `ndt` it drives (with its sha256), where the token is, and the
page's one-time URL -- or, when stdout is not a terminal, the 0600 file it wrote that URL to.
Options: `--port` (default 8765, `0` = any free port), `--ndt` (default `~/.local/bin/ndt` —
the main checkout's, the only tree `sudo ndtwin-lab` acts in), `--state-dir` (jobs; default
`~/.local/state/ndt-serve`), `--token-file` (default `~/.config/ndt-serve/token`), `--app-root`
(where `up --app` packages may live; default `<repo>/.test_run/packages`), `--read-timeout`
(a read-only ndt call, default 60 s), `--read-queue-wait` (how long a third read waits for one of
the two read slots before 503, default 30 s), `--max-connections` (default 32; more get an
immediate 503), `--max-waiters` (`?wait=` long-polls at once, default 4), `--nonce-ttl` (how long
a one-time page URL stays good, default 600 s).

Every job and every read runs the file `--ndt` resolved to **when the server started**;
`/health` reports `ndt_drift` if the symlink has been re-pointed or the file edited since.

Every `NDT_*` variable of the shell that starts it is dropped, and every `ndt` call carries
`NDT_OWNER=<owner>`. Stop it with Ctrl-C or SIGTERM; running jobs are not affected.

## The API (`/api/v1/`)

Outside `/api/v1/` there is only the page: `/`, `/app.js` and `/app.css`. Every other path
answers 404.

| method | path | what runs | answer |
|---|---|---|---|
| GET | `/health` | nothing | owner, the ndt path and sha256 (and `ndt_drift`), app list, whether a job holds the slot. **The one route that needs no token** |
| GET | `/status` | `ndt status` | rc, `rc_class`, `meaning`, stdout/stderr decoded, and a `read` id whose bytes are kept |
| GET | `/status?check=1` | `ndt status --check` | same; this one is a verdict (0/1/3) |
| GET | `/apps` | `ndt apps status` | same, plus the app names ndt knows |
| GET | `/jobs[?limit=N]` | nothing | the last jobs, newest first |
| GET | `/jobs/<id>[?wait=S]` | nothing | one job; `wait` blocks up to S s (≤300) while it runs |
| GET | `/jobs/<id>/log/stdout\|stderr[?offset=&limit=]` | nothing | the raw bytes; `X-NDT-Log-Next-Offset` for polling |
| GET | `/reads/<id>/log/stdout\|stderr` | nothing | a read's output, byte for byte (the last 500 reads are kept) |
| POST | `/claim` `{"minutes":1..240,"note":"..."}` | `ndt claim M [note]` | 202 + job |
| POST | `/release` `{}` | `ndt release` | 202 + job |
| POST | `/up` `{"plane":"ovs"\|"p4","hosts":4\|128}` or `{"plane":"p4","app":"<dir>"}` | `ndt up ovs` / `up 4` / `up p4 [N]` / `up p4 --app <realpath>` | 202 + job |
| POST | `/down` `{}` | `ndt down` (never `--deep`, never `--force`) | 202 + job |
| POST | `/apps/<name>/start` `{}` | `ndt apps <name>` | 202 + job |
| POST | `/apps/<name>/stop` `{}` | `ndt apps stop <name>` | 202 + job |
| GET | `/lab` | `ndt status` (plain) | the read, plus the `claim`, `measuring` and `declared` rows verbatim, `claim_is_yours` (ndt's own-claim form, whole), `measuring_is_nothing`, and `busy` (the job holding the slot). What the page confirms every write against |
| GET | `/meta` | nothing | the server's own tables: `up_hosts`, `max_claim_minutes`, `default_claim_minutes`, `max_note_chars`, `apps`, `owner` |
| POST | `/session` `{"nonce":"<key>"}` | nothing | the token, for a one-time key. **No token**; the `Origin` is required and must be this very origin (`http://` + the Host). A key is good once, for `--nonce-ttl` s, and only among the 8 newest |
| POST | `/session/new` `{}` | nothing | 201 + a new one-time page URL (`ndt serve url` calls this) |

**`{"dry_run": true}`** on `/up`, `/down`, `/claim`, `/release`, `/apps/<n>/start|stop`,
`/cells/<n>/run` and `/guided/<id>/next` answers 200 with the argv that write would run, its
`kind`, and how hard the page asks for a confirmation (`confirm`: `typed` or `plain`;
`needs_own_claim`) -- and runs, spawns and makes nothing. It is the only place the page gets an
argv from. Every other POST refuses the field.

A POST changes the lab, so it is a **job**: it returns at once with a job id, and only one job
may run at a time (409 `busy` names the one that does). A job runs under a detached runner and
keeps running if the server dies; a restarted server finds it again from disk.

**Every request but `GET /health` needs** the token in `X-NDT-Token` and -- if the client sends
an `Origin` -- this server's own origin; a POST also needs `Content-Type: application/json`.
The Host header must be `127.0.0.1:<port>` or `localhost:<port>`. No CORS header is ever sent.
Reads are gated too because a read is not side-effect free: `ndt status --check` POSTs three
lock probes to the kernel (ndt:9416-9431), and without the token any page in the browser could
start one with an `<img>` (judge 09-24, finding 1).

Two read-only ndt calls run at a time; a third waits up to `--read-queue-wait` seconds and then
gets 503. A read that runs past `--read-timeout` has its process group killed and answers
`rc_class: timeout`.

### curl

```bash
H='Host: 127.0.0.1:8765'; U=http://127.0.0.1:8765/api/v1
T="X-NDT-Token: $(cat ~/.config/ndt-serve/token)"; J='Content-Type: application/json'

curl -s -H "$H" -H "$T" $U/status | jq -r .stdout
curl -s -H "$H" -H "$T" -H "$J" -d '{"minutes":30,"note":"trying ndt serve"}' $U/claim
curl -s -H "$H" -H "$T" -H "$J" -d '{"plane":"ovs","hosts":4}' $U/up      # -> {"job":{"id":...}}
curl -s -H "$H" -H "$T" "$U/jobs/<id>?wait=300" | jq '.job | {state, rc, rc_class, meaning}'
curl -s -H "$H" -H "$T" $U/jobs/<id>/log/stdout
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
| POST | `/cells/<name>/run` `{}` | `run_cells.sh --cell <name> --raw-root <state>/cells-raw/…` | 202 + job, in the one slot. A cell that needs the lab runs **only under your own claim**: inside the slot, `ndt status`'s claim line must be ndt's own form, whole -- `yours -- <n>m left (until HH:MM:SS)` -- else 409 `claim` (a foreign owner named `yours-x` is foreign; one named exactly `yours` ndt itself prints as yours). A claim that could not be read -- no read slot within `--read-queue-wait`, or `ndt status` stopped at `--read-timeout` -- is also 409 `claim`, and the note says which. A cell that writes shared state (`writes_shared_state` in `/cells`) needs `{"confirm_shared_state_write": true}`, else 400 |
| GET | `/cells/<name>/runs/<job>` | nothing | that run's ASSERT rows, and per row: red on old/, and now |
| GET | `/jobs/<job>/raw/<path>` | nothing | a raw file of a run (cannot leave its raw root) |
| POST | `/cells/<name>/guided` `{}` | nothing | 201 + a walk (a shared-state cell needs the same confirmation field) |
| GET | `/guided`, `/guided/<id>` | nothing | the walks; a walk's state is derived, a GET writes nothing |
| POST | `/guided/<id>/next` `{}` | the current step | the walk, one step further (or the same step again, if it was blocked) |
| POST | `/guided/<id>/verdict` `{"verdict":"green"\|"red","note":"..."}` | nothing | Adam's call; `next` refuses to make it |
| POST | `/guided/<id>/abort` `{}` | nothing | stops the walk, and says whether its claim is still held |

A run's `rc` is run_cells.sh's: 0 is PASS **or SKIP**, so the job carries `cell_verdict` (the
cell's own CELL: line) and `rc_class` `pass` / `skip`; 1 is `fail`; 2 is `harness` -- the harness
could not run, or the restore after the cell failed and **the lab is not restored**.

A walk, for a cell that needs the lab: `old → new → status → claim → run → release → compare →
verdict` (no status/claim/release for a `requires none` cell; no `new` where there is no new/).
Every step says where to look and what green looks like. The run step reads the claim again
inside the slot (another tab's walk may have released it). The lab is given back right after the
run -- judging reads the raw, not the lab. The walk's claim and release are the OWNER's: a walk
opened while you already hold the lab re-claims it and releases it at the end (next cut). A step that did not come out **blocks** the walk: a
refused claim never leads to a run, a failed restore never leads to a release. The verdict is
Adam's.

```bash
G=$(curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/cells/up_target_names_a_readable_model/guided | jq -r .walk.id)
curl -s -H "$H" -H "$T" -H "$J" -d '{}' $U/guided/$G/next | jq '.walk.steps[.walk.current]'   # repeat
curl -s -H "$H" -H "$T" "$U/guided/$G" | jq '.walk.steps[] | {step, state, look_at}'
curl -s -H "$H" -H "$T" -H "$J" -d '{"verdict":"green","note":"h4nl_* all flipped"}' $U/guided/$G/verdict
```

## The page

`http://127.0.0.1:<port>/`, served by the server itself (Adam's Q2 ruling, 09-27): three fixed
files from `tools/ndt_serve/static/`, read once at start, served with no token and running
nothing. Every answer carries a Content-Security-Policy that allows no inline script, no other
origin and no frame.

**Getting in** (Q3): the URL the server starts with carries a ONE-TIME key in its `#fragment`
-- never the token. The page wipes the fragment from the address bar first, then trades the key
for the token (`POST /session`) and keeps the token in memory only: not in storage, a cookie or
the page. Reloading the page ends the session; for a new URL:

```bash
ndt serve url          # or: python3 tools/ndt_serve/serve.py url [--token-file F]
```

It reads the token file and `serve.json` beside it, and sends the token only after checking that
the pid `serve.json` names is the process listening on its port.

**What it shows**: A. the lab (`/lab`, the claim and measuring rows verbatim, the whole
`ndt status`, the `ndt_drift` warning); B. claim / release / up / down; C. the apps; D. the jobs,
with a live log while one you opened runs -- re-read every 2 s from its file, never by running
ndt, and stopped when the job ends, when you close the view, and while the page is hidden; E. the
cells, old/ and new/, runs and walks.
**Refresh is manual**: every refresh runs one plain `ndt status`, and a periodic one would be an
invisible load during a measurement.

**Every write goes through one dialog**: it reads `/lab` again, asks the server for the argv
(`dry_run`), and shows the argv, the claim row and the measuring row. Cancel has the focus, Enter
does not confirm, and Confirm works once. `up`, `down` and a cell that needs the lab ask for a
typed word, and so does every write while measuring is not `nothing`. Where the server says a
write needs your claim, Confirm stays off with "claim first" until the claim is yours. All of this
is a guard in the page -- ndt and this server still decide.

## Reading an answer

`rc` is always the integer `ndt` exited with. `rc_class` and `meaning` are a per-verb reading
of it. For `up`, `down` and `status --check` it is taken from `ndt help`; for plain `status`,
`claim`, `release` and the `apps` verbs `ndt help` says nothing, and the table was read from
ndt's code -- `verbs.RC_SOURCE` names the lines, and a test holds both kinds to the real ndt:

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
python3 tests/python/test_ndt_serve.py        # 74 cases against a stub ndt (RcProvenance reads the real ndt), no lab
python3 tests/python/test_ndt_serve_cells.py  # 35 cases against a stub grid, no lab
python3 tests/python/test_ndt_serve_gui.py    # 37 cases: the page's server side, and a lint of app.js / index.html
bash tests/shell/mutate_ndt_serve.sh          # 144 named mutations (the G series is the GUI cut), each must redden its case
# the page in a real browser: headless Chrome, only under the build guard (it skips elsewhere)
JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh python3 tests/browser/test_ndt_serve_page.py
JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh bash tests/shell/mutate_ndt_serve_page.sh
```
