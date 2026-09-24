"""The live_cells regression grid, as ndt serve shows it: list, red, green, run, and a guided walk.

[Co-developed with claude code -- Adam]

Adam's ruling (09-24 21:4x): open the 11 live_cells in ndt serve, plus a guided mode -- the
service does one step, says where to look, he presses next, and HE calls red or green. Why, in
his words: so he can see and verify the AI's work with his own eyes quickly, "這樣我才不會心虛".

Everything here reads the grid's OWN files and runs its OWN scripts, from the tree of the ndt
this server drives (the main checkout, live):

    tools/test_workflow/live_cells/run_cells.sh --list      which cells exist (the whitelist)
    tools/test_workflow/live_cells/<cell>.sh judge <dir>    a PURE function of a raw directory
    tools/test_workflow/live_cells/CELLS.md                 each cell's expected verdict, source
    tests/fixtures/live_cells/<cell>/old/                   the pre-fix raw: judge must FAIL
    tests/fixtures/live_cells/<cell>/new/                   the first fixed raw: judge must PASS

🔴 Nothing here judges a cell. The verdict is the `CELL:` line the cell's own judge prints, and
the per-assertion rows are its `ASSERT` lines, parsed and passed through. What this module adds is
presentation: which raw file an assertion read (so the page can open it), and which assertions
were red on old/ and are green now.

Reading old/ and new/ runs only `judge`, which by the grid's own contract "touches no lab, no
network, no clock and no git" -- so those are GETs. Running a cell drives the lab, so it is a job.
"""
import json
import os
import re
import secrets
import subprocess
import threading
import time

CELL_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,79}$")
ASSERT_RE = re.compile(r"^ASSERT (ok  |FAIL) (\S+)\s*(.*)$")
VERDICT_RE = re.compile(r"^CELL: (PASS|FAIL|SKIP) (\S+) (.*)$")
# the raw file an assertion names, from _cell_lib.sh's own detail sentences
_FILE_IN_DETAIL = [re.compile(r"^no such raw file: (\S+)$"),
                   re.compile(r"^(\S+) (?:present|is missing or empty|contains it|does not contain|"
                              r"still contains|matches|does not match)")]
GAP_NOTE = ("A failing assertion on old/ is not automatically the finding: some old/ directories are "
            "thinner than the cell's raw layout, and an assertion that fails with 'no such raw file' "
            "may be a fixture gap, not evidence. PROVENANCE.md names the ones that carry the finding "
            "(tests/fixtures/live_cells/README.md, rule 2).")


class CellError(Exception):
    pass


def parse_judge(text):
    """ASSERT rows and the CELL: verdict, exactly as the cell's judge printed them."""
    asserts, verdict, skip = [], None, None
    for line in text.splitlines():
        m = ASSERT_RE.match(line)
        if m:
            detail = m.group(3).strip()
            f = None
            for pat in _FILE_IN_DETAIL:
                fm = pat.match(detail)
                if fm:
                    f = fm.group(1)
                    break
            asserts.append({"ok": m.group(1).strip() == "ok", "id": m.group(2), "detail": detail, "file": f})
            continue
        m = VERDICT_RE.match(line)
        if m:
            verdict = {"state": m.group(1), "name": m.group(2), "rest": m.group(3), "line": line}
        elif line.startswith("SKIP: "):
            skip = line[len("SKIP: "):]
    return {"asserts": asserts, "verdict": verdict, "skip": skip}


def parse_cells_md(path):
    """name -> {source, fix, expected, fixture} from CELLS.md's table. Text shown to Adam, never
    used to decide anything."""
    out = {}
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return out
    for line in lines:
        if not line.startswith("| `"):
            continue
        cols = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cols) < 7:
            continue
        name = cols[0].strip("`")
        if CELL_NAME_RE.match(name):
            out[name] = {"source": cols[3], "fix": cols[4], "expected": cols[5], "fixture": cols[6]}
    return out


class Grid:
    def __init__(self, repo, env, timeout=60):
        self.repo = repo
        self.dir = os.path.join(repo, "tools", "test_workflow", "live_cells")
        self.runner = os.path.join(self.dir, "run_cells.sh")
        self.fixtures = os.path.join(repo, "tests", "fixtures", "live_cells")
        self.env = dict(env)
        self.env["NDT_ROOT"] = repo
        self.timeout = timeout

    def available(self):
        return os.access(self.runner, os.X_OK)

    def _run(self, argv):
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, env=self.env,
                           cwd=self.repo, timeout=self.timeout, start_new_session=True)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    def list(self):
        """The grid's own list (run_cells.sh --list), enriched with CELLS.md and the fixtures."""
        if not self.available():
            raise CellError("no live_cells grid at %s" % self.dir)
        rc, out, err = self._run([self.runner, "--list"])
        if rc != 0:
            raise CellError("run_cells.sh --list exited %d: %s" % (rc, err.strip()))
        md = parse_cells_md(os.path.join(self.dir, "CELLS.md"))
        cells = []
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) != 3 or not CELL_NAME_RE.match(parts[0]):
                continue
            name, tag, req = parts
            row = {"name": name, "tag": tag, "requires": req,
                   "old": os.path.isdir(os.path.join(self.fixtures, name, "old")),
                   "new": os.path.isdir(os.path.join(self.fixtures, name, "new"))}
            row.update(md.get(name, {}))
            cells.append(row)
        return cells

    def get(self, name):
        """The cell, if the grid itself lists it. The whitelist is run_cells.sh --list."""
        if not isinstance(name, str) or not CELL_NAME_RE.match(name):
            raise KeyError(name)
        for c in self.list():
            if c["name"] == name:
                return c
        raise KeyError(name)

    def fixture_dir(self, name, which):
        if which not in ("old", "new"):
            raise KeyError(which)
        self.get(name)
        d = os.path.join(self.fixtures, name, which)
        if not os.path.isdir(d):
            raise KeyError("%s/%s" % (name, which))
        return d

    def judge_fixture(self, name, which):
        """`<cell>.sh judge <fixture>` -- read-only by the grid's contract -- and what it said."""
        d = self.fixture_dir(name, which)
        argv = [os.path.join(self.dir, name + ".sh"), "judge", d]
        rc, out, err = self._run(argv)
        res = parse_judge(out)
        res.update({"argv": argv, "rc": rc, "stdout": out, "stderr": err, "fixture": which,
                    "dir": os.path.relpath(d, self.repo), "files": sorted(os.listdir(d))})
        failing = sorted(a["id"] for a in res["asserts"] if not a["ok"])
        res["failing"] = failing
        if which == "old":
            expected = _read_lines(os.path.join(d, "EXPECTED-FAILS"))
            res["expected_fails"] = expected
            res["failing_matches_expected"] = (expected is not None and sorted(expected) == failing)
            res["provenance"] = _read_text(os.path.join(d, "PROVENANCE.md"))
            res["gap_note"] = GAP_NOTE
        return res

    def run_argv(self, name, raw_root):
        self.get(name)
        return [self.runner, "--cell", name, "--raw-root", raw_root]

    def run_result(self, name, raw_root):
        """What the cell's judge printed in a run's raw directory (run_cells.sh writes judge.txt)."""
        hits = sorted(p for p in _walk(raw_root) if p.endswith(os.sep + name + os.sep + "judge.txt"))
        if not hits:
            return None
        text = _read_text(hits[-1]) or ""
        res = parse_judge(text)
        res["raw_dir"] = os.path.dirname(hits[-1])
        res["files"] = sorted(os.listdir(res["raw_dir"]))
        return res


def compare(old, now):
    """Per assertion: red on old/, and what it is now. Presentation only -- the verdict is the
    CELL: line."""
    old_by = {a["id"]: a for a in (old or {}).get("asserts", [])}
    rows = []
    for a in (now or {}).get("asserts", []):
        o = old_by.get(a["id"])
        rows.append({"id": a["id"], "old": None if o is None else ("ok" if o["ok"] else "FAIL"),
                     "now": "ok" if a["ok"] else "FAIL", "detail_now": a["detail"],
                     "detail_old": None if o is None else o["detail"], "file": a["file"],
                     "red_to_green": bool(o is not None and not o["ok"] and a["ok"]),
                     "still_red": not a["ok"]})
    return rows


def safe_file(root, rel):
    """A file under root, by a relative path that cannot leave it."""
    if not isinstance(rel, str) or not rel or rel.startswith("/") or "\x00" in rel:
        raise KeyError(rel)
    root_real = os.path.realpath(root)
    p = os.path.realpath(os.path.join(root_real, rel))
    if os.path.commonpath([root_real, p]) != root_real or not os.path.isfile(p):
        raise KeyError(rel)
    return p


def _walk(root):
    for base, _dirs, files in os.walk(root):
        for f in files:
            yield os.path.join(base, f)


def _read_text(p):
    try:
        with open(p, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _read_lines(p):
    t = _read_text(p)
    if t is None:
        return None
    return sorted(l.strip() for l in t.splitlines() if l.strip() and not l.startswith("#"))


# --- the guided walk ---------------------------------------------------------------------------
#
# One cell, up to eight steps, one at a time. The service does the step, says where to look and
# what green looks like, and stops. Adam presses next. The last step is his: he calls it.
#
# The lab is released right after the run, BEFORE the compare and the verdict: judging reads the
# raw the run left, not the lab, and a walk waiting on Adam must not hold a shared lab while it
# waits (the lab is shared with the orchestrator's acceptance rounds).
#
# A step that did not come out as it should BLOCKS the walk -- `next` then retries that step, and
# nothing after it runs. In particular a claim that was refused never leads to a run, and a run
# whose restore failed never leads to an automatic release: the lab is in a state he should see.

STEP_TITLES = {
    "old":     "修好之前的紅（old/，唯讀，不碰 lab）",
    "new":     "第一次修好時的綠（new/，唯讀，不碰 lab）",
    "status":  "看 lab 現在能不能用（ndt status，唯讀）",
    "claim":   "claim lab 30 分鐘",
    "run":     "現在重跑這一格：observe → judge → 還原",
    "compare": "修前 vs 現在，逐條對照",
    "verdict": "你的判定：紅還是綠",
    "release": "release lab",
}


def guided_steps(cell):
    lab = cell["requires"] != "none"
    steps = ["old"] + (["new"] if cell.get("new") else []) + (["status", "claim"] if lab else []) \
        + ["run"] + (["release"] if lab else []) + ["compare", "verdict"]
    return steps


def look_at(step, cell):
    exp = cell.get("expected") or "(CELLS.md has no row for this cell)"
    return {
        "old": ("看 FAIL 的那幾列：它們就是當時的缺陷。對照 expected_fails（人工審過的清單），"
                "兩邊應該一致。再讀 provenance：只寫著 'no such raw file' 的紅，可能只是 fixture 缺檔，不是證據。"),
        "new": "每一列都應該是 ok，最後一行是 CELL: PASS。這是修好當晚跑出來的，不是現在跑的。",
        "status": ("看 claim 那一行：必須是 none 或 yours。再看 measuring：必須是 nothing。"
                   "如果有別人的 claim，就停在這裡，不要按下一步。"),
        "claim": "rc 0 且 rc_class 為 ok，claim 才是你的。rc 1（refused）代表別人拿走了 lab，整個流程會停在這裡。",
        "run": ("看 verdict：CELL: PASS 就是綠。綠長什麼樣（CELLS.md）：" + exp +
                "。run_cells.sh 的 rc 2 代表還原失敗，lab 不乾淨；這種情況流程會停住，不會自動 release。"),
        "compare": "看 red_to_green 為 true 的那幾列：這幾條在 old/ 是 FAIL，現在是 ok。still_red 應該全部是 false。",
        "verdict": "由你決定。POST /api/v1/guided/<id>/verdict，body 為 {\"verdict\": \"green\" 或 \"red\", \"note\": \"...\"}。",
        "release": ("rc 0 就是還回去了。lab 在對照和判定之前就先還，"
                    "因為判定看的是這次 run 留下的 raw，不需要 lab；lab 是和 orchestrator 共用的。"),
    }[step]


class Guided:
    """Walks persisted as JSON, one file each, so a restarted server still has them."""

    def __init__(self, state_dir):
        self.root = os.path.join(state_dir, "guided")
        os.makedirs(self.root, mode=0o700, exist_ok=True)
        self.lock = threading.Lock()

    def _path(self, gid):
        if not re.fullmatch(r"g[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}", gid or ""):
            raise KeyError(gid)
        return os.path.join(self.root, gid + ".json")

    def create(self, cell):
        gid = "g" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(3)
        walk = {"id": gid, "cell": cell["name"], "requires": cell["requires"], "created_at": time.time(),
                "steps": [{"step": s, "title": STEP_TITLES[s], "look_at": look_at(s, cell),
                           "state": "pending", "result": None, "job": None}
                          for s in guided_steps(cell)],
                "current": 0, "blocked": None, "verdict": None, "done": False}
        self.save(walk)
        return walk

    def load(self, gid):
        p = self._path(gid)
        try:
            with open(p) as f:
                return json.load(f)
        except OSError:
            raise KeyError(gid)

    def save(self, walk):
        p = self._path(walk["id"])
        tmp = "%s.tmp.%d" % (p, os.getpid())
        with open(tmp, "w") as f:
            json.dump(walk, f, indent=1)
        os.replace(tmp, p)
