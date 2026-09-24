# ndt serve — a local HTTP API over `ndt`

[Co-developed with claude code -- Adam]

First cut (TICKET-ndt-serve, 09-24): backend only, one user, `127.0.0.1` only, no login.
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
bash tests/shell/mutate_ndt_serve.sh          # 42 named mutations, each must redden its case
```
