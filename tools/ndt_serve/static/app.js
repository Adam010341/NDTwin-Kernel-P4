// ndt serve: the page (GUI cut, Adam's Q2/Q3 rulings 09-27; doc/audit/2026-09-27_ndt-serve-gui/SCOPE.md).
// [Co-developed with claude code -- Adam]
//
// What this file may do, and what tests/python/test_ndt_serve_gui.py (PageLint, and the headless
// Chrome cases in tests/browser/) holds it to:
//
//   * The token lives in ONE variable of this closure. It is never put in storage, a cookie, the
//     DOM or a URL; the URL carries a one-time key, which is wiped from the address bar before
//     anything else runs and traded for the token (POST /session).
//   * fetch() is called in one place, call(), and the token header is set there and nowhere else.
//   * Every write is post(), and post() is called only from confirmThen(): a fresh GET /lab, the
//     server's own dry run of the write, and a dialog Adam confirms. Loading the page writes nothing.
//   * ndt's text is shown with textContent and never parsed. What the page decides on are fields
//     the server computed: rc_class, state, busy, claim_is_yours, measuring_is_nothing, declared,
//     confirm, needs_own_claim, writes_shared_state, requires, a walk's current/blocked/done.
//     There is no rc table here and no argv is built here.
//   * Refresh is manual: every refresh runs one plain `ndt status`, and a periodic one would be an
//     invisible load source during a measurement (orchestrator's ruling 6, 09-27). The one thing
//     that repeats is the log of a job Adam opened, while it runs -- file reads, no ndt -- and it
//     stops when the job ends, when its view is closed, and while the page is hidden (the
//     orchestrator's condition on that, 09-27 15:4x).
"use strict";
(function () {
  const API = "/api/v1";
  let token = null;        // the only copy the page has
  let meta = null;
  let dialogGen = 0;
  let watching = null;     // the opening of the job view whose log is being followed
  let walkOpen = null;     // the walk shown in section E

  const $ = (id) => document.getElementById(id);

  // --- the only way out of this page ---------------------------------------------------------
  async function call(method, path, body) {
    const headers = {};
    if (token !== null) headers["X-NDT-Token"] = token;
    const init = {method: method, headers: headers, cache: "no-store", credentials: "omit", redirect: "error"};
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    let r;
    try {
      r = await fetch(path, init);
    } catch (e) {
      return {status: 0, json: null, text: String(e), headers: new Headers()};
    }
    const text = await r.text();
    let json = null;
    if ((r.headers.get("Content-Type") || "").startsWith("application/json")) {
      try { json = JSON.parse(text); } catch (e) { json = null; }
    }
    return {status: r.status, json: json, text: text, headers: r.headers};
  }

  function get(path) {
    return call("GET", path);
  }

  function post(path, body) {
    return call("POST", path, body);
  }

  // --- small helpers: every piece of text goes in as text ------------------------------------
  function el(tag, text, cls) {
    const e = document.createElement(tag);
    if (text !== undefined && text !== null) e.textContent = String(text);
    if (cls) e.className = cls;
    return e;
  }

  function button(label, onclick) {
    const b = el("button", label);
    b.type = "button";
    b.addEventListener("click", onclick);
    return b;
  }

  function setText(id, text) {
    $(id).textContent = text === null || text === undefined ? "" : String(text);
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function rcBadge(rcClass) {
    return el("span", rcClass, "rc rc-" + String(rcClass).replace(/[^a-z-]/g, ""));
  }

  function stateBadge(state) {
    return el("span", state, "state state-" + String(state).replace(/[^a-z-]/g, ""));
  }

  function errText(r) {
    if (r.status === 0) return "no answer: " + r.text;
    if (r.json && r.json.error) return r.status + " " + r.json.error + (r.json.note ? " -- " + r.json.note : "");
    return r.status + " " + r.text.slice(0, 300);
  }

  function answer(id, r) {
    const p = $(id);
    clear(p);
    if (r.status >= 200 && r.status < 300) {
      p.className = "answer";
      p.textContent = r.status + (r.json && r.json.job ? " -- job " + r.json.job.id + " started" : "");
    } else {
      p.className = "answer warn";
      p.textContent = errText(r);
    }
  }

  function hook(name, value) {
    // test hooks (tests/browser): never the token, never the key
    document.body.dataset[name] = value;
  }

  function storageHook() {
    hook("storage", JSON.stringify({local: localStorage.length, session: sessionStorage.length,
                                    cookie: document.cookie}));
  }

  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

  function whileHidden() {
    // resolves at once on a shown page; on a hidden one, when it is shown again
    if (document.visibilityState !== "hidden") return Promise.resolve();
    return new Promise((ok) => {
      const shown = () => {
        if (document.visibilityState === "hidden") return;
        document.removeEventListener("visibilitychange", shown);
        ok();
      };
      document.addEventListener("visibilitychange", shown);
    });
  }

  // --- the session (SCOPE section 3) ---------------------------------------------------------
  async function openSession() {
    const m = /^#k=([A-Za-z0-9_-]{16,64})$/.exec(location.hash);
    history.replaceState(null, "", location.pathname + location.search);   // the key leaves the address bar first
    hook("href", location.href);
    if (!m) {
      setText("session", "no key in this URL: run 'ndt serve url' and open the URL it prints");
      $("session").className = "warn";
      hook("session", "no-key");
      return false;
    }
    const r = await call("POST", API + "/session", {nonce: m[1]});
    if (r.status !== 200 || !r.json || typeof r.json.token !== "string") {
      setText("session", "the key was refused (" + errText(r) + "): run 'ndt serve url' for a new one");
      $("session").className = "warn";
      hook("session", "refused");
      return false;
    }
    token = r.json.token;
    setText("session", "session open -- reloading this page ends it");
    $("session").className = "muted";
    hook("session", "ok");
    return true;
  }

  // --- A. lab --------------------------------------------------------------------------------
  function busyText(busy) {
    return busy ? "held by job " + busy.id + " (" + busy.kind + ", " + busy.state + ")" : "free";
  }

  async function loadLab() {
    const [lab, health] = await Promise.all([get(API + "/lab"), get(API + "/health")]);
    if (health.status === 200 && health.json.ndt_drift) {
      $("drift").hidden = false;
      setText("drift", "ndt changed since this server started (ndt_drift): every call still runs " +
              health.json.ndt_realpath + " as it was -- restart ndt serve to drive the new one");
    } else {
      $("drift").hidden = true;
    }
    if (lab.status !== 200) {
      setText("lab-claim", "");
      setText("lab-measuring", "");
      setText("lab-yours", "the lab could not be read: " + errText(lab));
      $("lab-yours").className = "warn";
      return;
    }
    const j = lab.json;
    setText("lab-claim", j.claim === null ? "(no claim row)" : j.claim);
    setText("lab-yours", j.claim_is_yours ? "yours" : "not yours");
    $("lab-yours").className = j.claim_is_yours ? "ok" : "warn";
    setText("lab-measuring", j.measuring === null ? "(no measuring row)" : j.measuring);
    $("lab-measuring").className = j.measuring_is_nothing ? "" : "warn";
    $("lab-declared-row").hidden = j.declared === null;
    setText("lab-declared", j.declared);
    setText("lab-busy", busyText(j.busy));
    setText("lab-read", "read " + j.read.id + " at " + new Date().toLocaleTimeString() + ", rc " + j.rc + " (" + j.rc_class + ")");
    setText("lab-out", j.stdout + (j.stderr ? "\n--- stderr ---\n" + j.stderr : ""));
  }

  // --- the one door every write goes through (SCOPE section 2) -------------------------------
  //   a = {title, path, body, word, preview, shared, sharedInBody, then}
  async function confirmThen(a) {
    const gen = ++dialogGen;
    const d = $("confirm");
    const go = $("c-go");
    setText("c-title", a.title);
    setText("c-state", "reading the lab (plain ndt status)" + (a.preview ? " and asking the server for the argv..." : "..."));
    for (const id of ["c-claim", "c-measuring", "c-declared", "c-busy", "c-note"]) setText(id, "");
    clear($("c-argv"));
    clear($("c-blockers"));
    $("c-declared-row").hidden = true;
    $("c-shared-row").hidden = true;
    $("c-typed-row").hidden = true;
    $("c-shared").checked = false;
    $("c-typed").value = "";
    go.disabled = true;
    go.onclick = null;
    if (!d.open) d.showModal();
    $("c-cancel").focus();

    const lab = await get(API + "/lab");
    const dry = a.preview ? await post(a.path, Object.assign({}, a.body, {dry_run: true})) : null;
    if (gen !== dialogGen || !d.open) return;   // cancelled, or another dialog took over

    const blockers = [];
    const L = lab.status === 200 ? lab.json : null;
    const D = dry && dry.status === 200 ? dry.json : null;
    setText("c-state", "");
    if (L) {
      setText("c-claim", L.claim === null ? "(no claim row)" : L.claim);
      $("c-claim").className = L.claim_is_yours ? "ok" : "warn";
      setText("c-measuring", L.measuring === null ? "(no measuring row)" : L.measuring);
      $("c-measuring").className = L.measuring_is_nothing ? "" : "warn";
      $("c-declared-row").hidden = L.declared === null;
      setText("c-declared", L.declared);
      setText("c-busy", busyText(L.busy));
    } else {
      blockers.push("the lab could not be read: " + errText(lab));
    }
    if (a.preview) {
      if (D) {
        if (D.argv === null) $("c-argv").append(el("span", "no ndt job (" + D.kind + "): see the note below", "muted"));
        for (const arg of D.argv || []) $("c-argv").append(el("code", arg, "arg"), " ");
        setText("c-note", D.note);
        if (D.needs_own_claim && !(L && L.claim_is_yours)) blockers.push("claim first: the claim is not yours");
      } else {
        blockers.push("the server refused this request: " + errText(dry));
      }
    } else {
      $("c-argv").append(el("span", "no ndt command: " + a.effect, "muted"));
    }
    const shared = (D && D.writes_shared_state) || a.shared || null;
    if (shared) {
      $("c-shared-row").hidden = false;
      setText("c-shared-text", a.sharedInBody ? "I know this rewrites shared state: " + shared
                                                : "this step writes shared state (confirmed when the walk was started): " + shared);
      $("c-shared").disabled = !a.sharedInBody;
      $("c-shared").checked = !a.sharedInBody;
    }
    // typed: the server says so for this write, or anything is measuring or declared
    const typed = (D && D.confirm === "typed") || !(L && L.measuring_is_nothing) || (L && L.declared !== null);
    if (typed) {
      $("c-typed-row").hidden = false;
      setText("c-word", a.word);
    }
    for (const b of blockers) $("c-blockers").append(el("li", b));

    const ready = () => blockers.length === 0 && (!typed || $("c-typed").value === a.word) &&
                        (!shared || $("c-shared").checked);
    const update = () => { go.disabled = !ready(); };
    $("c-typed").oninput = update;
    $("c-shared").onchange = update;
    update();
    go.onclick = async () => {
      if (!ready()) return;
      go.disabled = true;   // once: a second click finds it disabled (and the slot would 409)
      const body = Object.assign({}, a.body);
      if (shared && a.sharedInBody) body.confirm_shared_state_write = true;
      const r = await post(a.path, body);
      if (gen === dialogGen) d.close();
      a.then(r);
    };
  }

  // --- B. lab actions ------------------------------------------------------------------------
  function fillUpHosts() {
    const sel = $("up-hosts");
    clear(sel);
    for (const h of meta.up_hosts[$("up-plane").value] || []) {
      const o = el("option", h === null ? "(ndt's default)" : String(h));
      o.value = h === null ? "" : String(h);
      sel.append(o);
    }
  }

  function jobStarted(answerId) {
    return (r) => {
      answer(answerId, r);
      loadJobs();
      if (r.status === 202 && r.json && r.json.job) openJob(r.json.job.id);
    };
  }

  function setupActions() {
    $("claim-min").value = meta.default_claim_minutes;
    $("claim-min").max = meta.max_claim_minutes;
    $("claim-note").maxLength = meta.max_note_chars;
    const plane = $("up-plane");
    clear(plane);
    for (const p of Object.keys(meta.up_hosts)) {
      const o = el("option", p);
      o.value = p;
      plane.append(o);
    }
    plane.addEventListener("change", fillUpHosts);
    fillUpHosts();
    $("do-claim").addEventListener("click", () => {
      const body = {minutes: Number($("claim-min").value)};
      if ($("claim-note").value) body.note = $("claim-note").value;
      confirmThen({title: "claim the lab", path: API + "/claim", body: body, word: "claim", preview: true,
                   then: jobStarted("actions-answer")});
    });
    $("do-release").addEventListener("click", () => confirmThen({
      title: "release the lab", path: API + "/release", body: {}, word: "release", preview: true,
      then: jobStarted("actions-answer")}));
    $("do-up").addEventListener("click", () => {
      const body = {plane: $("up-plane").value};
      if ($("up-hosts").value !== "") body.hosts = Number($("up-hosts").value);
      confirmThen({title: "bring the fabric up", path: API + "/up", body: body, word: "up", preview: true,
                   then: jobStarted("actions-answer")});
    });
    $("do-down").addEventListener("click", () => confirmThen({
      title: "tear the fabric down", path: API + "/down", body: {}, word: "down", preview: true,
      then: jobStarted("actions-answer")}));
  }

  // --- C. apps -------------------------------------------------------------------------------
  function renderApps() {
    const t = $("apps-table");
    clear(t);
    for (const name of meta.apps) {
      const tr = el("tr");
      tr.append(el("td", name));
      for (const action of ["start", "stop"]) {
        const td = el("td");
        td.append(button(action, () => confirmThen({
          title: action + " " + name, path: API + "/apps/" + encodeURIComponent(name) + "/" + action, body: {},
          word: action, preview: true, then: jobStarted("apps-answer")})));
        tr.append(td);
      }
      t.append(tr);
    }
  }

  async function loadApps() {
    const r = await get(API + "/apps");
    $("apps-out").hidden = false;
    setText("apps-out", r.status === 200 ? r.json.stdout + (r.json.stderr ? "\n--- stderr ---\n" + r.json.stderr : "")
                                         : errText(r));
  }

  // --- D. jobs -------------------------------------------------------------------------------
  async function loadJobs() {
    const r = await get(API + "/jobs");
    const t = $("jobs-table");
    clear(t);
    if (r.status !== 200) {
      const tr = el("tr");
      tr.append(el("td", errText(r), "warn"));
      t.append(tr);
      return;
    }
    const head = el("tr");
    for (const h of ["id", "kind", "state", "rc", "rc_class", "meaning", "argv"]) head.append(el("th", h));
    t.append(head);
    for (const j of r.json.jobs) {
      const tr = el("tr");
      const idc = el("td");
      idc.append(button(j.id, () => openJob(j.id)));
      tr.append(idc, el("td", j.kind), el("td"), el("td", j.rc), el("td"), el("td", j.meaning),
                el("td", (j.argv || []).slice(1).join(" "), "mono"));
      tr.children[2].append(stateBadge(j.state));
      tr.children[4].append(rcBadge(j.rc_class));
      t.append(tr);
    }
  }

  function renderJob(j) {
    const rows = $("job-rows");
    clear(rows);
    const add = (k, v) => {
      const tr = el("tr");
      const td = el("td");
      if (v instanceof Node) td.append(v); else td.textContent = v === null || v === undefined ? "" : String(v);
      tr.append(el("th", k), td);
      rows.append(tr);
    };
    add("kind", j.kind);
    add("state", stateBadge(j.state));
    add("rc", j.rc);
    add("rc_class", rcBadge(j.rc_class));
    add("meaning", j.meaning);
    add("argv", (j.argv || []).join(" "));
    if (j.cell_verdict) add("cell verdict", j.cell_verdict.line);
  }

  async function openJob(id) {
    const mine = {};   // this opening: closing the view, or opening a job again, replaces it
    watching = mine;
    $("job").hidden = false;
    setText("job-id", id);
    setText("job-stdout", "");
    setText("job-stderr", "");
    const off = {stdout: 0, stderr: 0};
    for (;;) {
      const r = await get(API + "/jobs/" + encodeURIComponent(id));
      if (watching !== mine) return;
      if (r.status !== 200) {
        setText("job-stderr", errText(r));
        return;
      }
      renderJob(r.json.job);
      for (const s of ["stdout", "stderr"]) {
        const lr = await get(API + "/jobs/" + encodeURIComponent(id) + "/log/" + s + "?offset=" + off[s]);
        if (watching !== mine) return;
        if (lr.status === 200) {
          $("job-" + s).append(document.createTextNode(lr.text));
          off[s] = Number(lr.headers.get("X-NDT-Log-Next-Offset") || off[s]);
        }
      }
      if (r.json.job.state !== "running") {
        loadJobs();
        if (walkOpen) openWalk(walkOpen);
        return;
      }
      await sleep(2000);
      await whileHidden();
      if (watching !== mine) return;
    }
  }

  function closeJob() {
    watching = null;   // the loop above returns at its next look
    $("job").hidden = true;
  }

  // --- E. cells and walks --------------------------------------------------------------------
  async function loadCells() {
    const r = await get(API + "/cells");
    const t = $("cells-table");
    clear(t);
    if (r.status !== 200) {
      answer("cells-answer", r);
      return;
    }
    const head = el("tr");
    for (const h of ["cell", "requires", "expected (CELLS.md)", ""]) head.append(el("th", h));
    t.append(head);
    for (const c of r.json.cells) {
      const tr = el("tr");
      const name = el("td");
      name.append(el("code", c.name));
      if (c.writes_shared_state) name.append(el("div", "writes shared state: " + c.writes_shared_state, "warn small"));
      const acts = el("td");
      if (c.old) acts.append(button("old/", () => openFixture(c.name, "old")));
      if (c.new) acts.append(button("new/", () => openFixture(c.name, "new")));
      acts.append(button("run", () => confirmThen({
        title: "run the cell " + c.name, path: API + "/cells/" + encodeURIComponent(c.name) + "/run", body: {},
        word: "run", preview: true, sharedInBody: true, then: jobStarted("cells-answer")})));
      acts.append(button("walk", () => confirmThen({
        title: "start a guided walk through " + c.name, path: API + "/cells/" + encodeURIComponent(c.name) + "/guided",
        body: {}, word: "walk", preview: false, shared: c.writes_shared_state, sharedInBody: true,
        effect: "records a walk; nothing runs until you press Next step",
        then: (w) => { answer("cells-answer", w); if (w.status === 201) { loadWalks(); openWalk(w.json.walk.id); } }})));
      tr.append(name, el("td", c.requires), el("td", c.expected || ""), acts);
      t.append(tr);
    }
  }

  async function openFixture(cell, which) {
    const base = API + "/cells/" + encodeURIComponent(cell) + "/" + which;
    const r = await get(base);
    $("fixture").hidden = false;
    $("fixture-raw").hidden = true;
    setText("fixture-title", cell + " -- " + which + "/");
    const t = $("fixture-asserts");
    const rows = $("fixture-rows");
    clear(t);
    clear(rows);
    if (r.status !== 200) {
      setText("fixture-verdict", errText(r));
      return;
    }
    const j = r.json;
    setText("fixture-verdict", j.verdict ? j.verdict.line : "(no CELL: line)" + (j.timed_out ? " -- the judge timed out" : ""));
    for (const a of j.asserts) {
      const tr = el("tr");
      tr.append(el("td", a.ok ? "ok" : "FAIL", a.ok ? "ok" : "bad"), el("td", a.id, "mono"), el("td", a.detail));
      t.append(tr);
    }
    const add = (k, v) => { const tr = el("tr"); tr.append(el("th", k), el("td", v)); rows.append(tr); };
    add("failing", (j.failing || []).join(" "));
    if (which === "old") {
      add("expected_fails", (j.expected_fails || []).join(" "));
      add("failing = expected", j.failing_matches_expected ? "yes" : "NO");
      add("provenance", j.provenance || "");
      add("note", j.gap_note || "");
    }
    const files = el("td");
    for (const f of j.files || []) {
      files.append(button(f, async () => {
        const fr = await get(base + "/raw/" + encodeURIComponent(f));
        $("fixture-raw").hidden = false;
        setText("fixture-raw", fr.status === 200 ? fr.text : errText(fr));
      }), " ");
    }
    const tr = el("tr");
    tr.append(el("th", "raw files"), files);
    rows.append(tr);
  }

  async function loadWalks() {
    const r = await get(API + "/guided");
    const t = $("walks-table");
    clear(t);
    if (r.status !== 200) {
      const tr = el("tr");
      tr.append(el("td", errText(r), "warn"));
      t.append(tr);
      return;
    }
    if (!r.json.walks.length) return;
    const head = el("tr");
    for (const h of ["walk", "cell", "current", "done", "verdict"]) head.append(el("th", h));
    t.append(head);
    for (const w of r.json.walks) {
      const tr = el("tr");
      const idc = el("td");
      idc.append(button(w.id, () => openWalk(w.id)));
      tr.append(idc, el("td", w.cell), el("td", w.current), el("td", w.done ? "yes" : ""),
                el("td", w.verdict ? w.verdict.verdict : ""));
      t.append(tr);
    }
  }

  async function openWalk(gid) {
    walkOpen = gid;
    const r = await get(API + "/guided/" + encodeURIComponent(gid));
    $("walk").hidden = false;
    setText("walk-id", gid);
    const ol = $("walk-steps");
    clear(ol);
    if (r.status !== 200) {
      answer("walk-answer", r);
      return;
    }
    const w = r.json.walk;
    setText("walk-cell", w.cell + (w.aborted ? " (aborted)" : "") + (w.done ? " (done)" : ""));
    $("walk-blocked").hidden = !w.blocked;
    setText("walk-blocked", w.blocked ? "blocked: " + w.blocked : "");
    w.steps.forEach((st, i) => {
      const li = el("li", null, i === w.current ? "current" : "");
      const title = el("div");
      title.append(stateBadge(st.state), " ", el("strong", st.step), " ", el("span", st.title));
      li.append(title, el("div", st.look_at, "small"));
      if (st.result) {
        const det = el("details");
        det.append(el("summary", "result"), el("pre", JSON.stringify(st.result, null, 1)));
        li.append(det);
      }
      if (st.job) li.append(button("job " + st.job, () => openJob(st.job)));
      ol.append(li);
    });
    const cur = w.current === null ? null : w.steps[w.current];
    const atVerdict = cur !== null && cur.step === "verdict" && !w.aborted;
    $("walk-verdict").hidden = !atVerdict;
    $("walk-next").disabled = w.done || !!w.aborted || atVerdict || (cur !== null && cur.state === "running");
    $("walk-abort").disabled = w.done || !!w.aborted;
  }

  function setupWalkButtons() {
    const path = (tail) => API + "/guided/" + encodeURIComponent(walkOpen) + tail;
    const after = (r) => { answer("walk-answer", r); openWalk(walkOpen); loadJobs();
                           if (r.status === 200 && r.json && r.json.walk) {
                             const cur = r.json.walk.steps[r.json.walk.current];
                             if (cur && cur.job && cur.state === "running") openJob(cur.job);
                           } };
    $("walk-next").addEventListener("click", () => confirmThen({
      title: "walk " + walkOpen + ": the next step", path: path("/next"), body: {}, word: "next",
      preview: true, sharedInBody: false, then: after}));
    $("walk-abort").addEventListener("click", () => confirmThen({
      title: "abort walk " + walkOpen, path: path("/abort"), body: {}, word: "abort", preview: false,
      effect: "marks the walk aborted; a claim it took is NOT released", then: after}));
    for (const v of ["green", "red"]) {
      $("walk-" + v).addEventListener("click", () => confirmThen({
        title: "walk " + walkOpen + ": your verdict is " + v, path: path("/verdict"),
        body: {verdict: v, note: $("walk-note").value}, word: v, preview: false,
        effect: "records your verdict in the walk", then: after}));
    }
  }

  // --- start ---------------------------------------------------------------------------------
  async function refreshAll() {
    await Promise.all([loadLab(), loadJobs()]);
  }

  async function start() {
    storageHook();
    $("c-go").addEventListener("keydown", (e) => { if (e.key === "Enter") e.preventDefault(); });
    $("c-cancel").addEventListener("click", () => { dialogGen++; $("confirm").close(); });
    $("confirm").addEventListener("close", () => { dialogGen++; });
    if (!(await openSession())) {
      storageHook();
      hook("loaded", "no-session");
      return;
    }
    const m = await get(API + "/meta");
    if (m.status !== 200) {
      setText("session", "GET /meta: " + errText(m));
      hook("loaded", "no-meta");
      return;
    }
    meta = m.json;
    setText("who", "owner " + meta.owner);
    setupActions();
    renderApps();
    setupWalkButtons();
    $("refresh").disabled = false;
    $("refresh").addEventListener("click", refreshAll);
    $("apps-load").addEventListener("click", loadApps);
    $("jobs-load").addEventListener("click", loadJobs);
    $("job-close").addEventListener("click", closeJob);
    $("cells-load").addEventListener("click", loadCells);
    $("walks-load").addEventListener("click", loadWalks);
    await refreshAll();
    storageHook();
    hook("loaded", "yes");
  }

  document.addEventListener("DOMContentLoaded", start);
})();
