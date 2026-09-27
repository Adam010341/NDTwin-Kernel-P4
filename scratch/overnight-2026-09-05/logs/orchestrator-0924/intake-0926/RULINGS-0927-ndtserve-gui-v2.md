# ndt serve GUI v2 — Adam's feedback and rulings (2026-09-27 ~21:1x, interactive form)

[Co-developed with claude code -- Adam]

Adam used the page at trunk f186ce98. Adam wrote these 8 points; the orchestrator translated them from his Chinese and accepted all 8:

1. Too many long ids; the page is cluttered. ⇒ Show short ids (8 chars). Hover shows the whole id; a click copies it.
2. All sections (A. Lab, B. Lab actions, ...) sit on one page, so the user keeps scrolling. ⇒ Tabs: 實驗室 / 操作 / Apps / 工作紀錄 / 驗證格.
3. No button that opens Web-GUI. ⇒ A top-bar button, default `http://localhost:3000` (Web-GUI's Docker port on this machine), configurable.
4. Cells and walks have no explanation. ⇒ Add a one-line explanation per section and per cell.
5. The UI mixes Chinese and English. ⇒ All UI strings go in one string table; Chinese is the default. English is a second table, added at release; switching needs no code change.
6. Need a button that opens the ndt serve user manual. ⇒ Write a new CHINESE user manual (not the English API README) and open it from a button.
7. "Read ndt apps status" and "Refresh" should refresh on a timer. ⇒ See ruling R2.
8. The meaning of the old / new / run / walk buttons is unclear. ⇒ Rename the buttons and explain them:
   - old = the pre-fix record, which should be red;
   - new = the first green on the night of the fix;
   - run = run the cell now on the lab, with a claim when the cell needs the lab;
   - walk = the guided sequence old → new → claim → run → compare → your verdict.

## Rulings (form, both recommended options)

- **R1 — stack**: rebuild the page with Web-GUI's stack (React + Vite + Tailwind + TypeScript + i18next), copying Web-GUI's components and style, and keep it INSIDE ndt serve.
  - The built static files are served by ndt serve on 127.0.0.1, the same origin, with CSP 'self'. The security red lines are unchanged: loopback only, no CORS, the one-time URL fragment traded for a token.
  - Node is needed only to build, never to use; the built files are committed.
  - The existing page tests are rewritten.
  - ~/Web-GUI is NOT modified. It is reference material only. Both repos are Apache-2.0.
  - Ruling H (09-27: the GUI is served by ndt serve itself) stands.
- **R2 — auto-refresh**: every 10 s, paused while `measuring` is not `nothing` and while the page is hidden. The screen shows the paused state ("已暫停（量測中）"), and a manual refresh stays available.
  - This REPLACES the orchestrator's 09-27 scope ruling "manual refresh only".
  - The load concern behind that ruling is handled by the pause, not by dropping the timer.

## R3 — topology and traffic (form, 2026-09-27 ~21:3x; Adam chose the non-recommended third option)

The question was whether the new ndt serve should also show topology and traffic. Adam chose: **in the long term, merge ndt serve and Web-GUI into ONE app.**

- This version (v2) is unchanged. Topology and traffic stay in Web-GUI; the page has a button that opens it.
- v2 must be BUILT TO MOVE:
  - same stack and versions as Web-GUI;
  - an API client isolated behind one module with a configurable base;
  - i18n keys namespaced (e.g. `ndtServe.*`), so they can sit in Web-GUI's message files;
  - Tailwind config compatible with Web-GUI's;
  - no dependence on being served at `/`.
- The merge itself is a separate design question, not scheduled. It must first resolve the conflict between Web-GUI's exposure and ndt serve's security:
  - Web-GUI listens on 0.0.0.0:3000 in Docker and is reachable from the network.
  - ndt serve's lab actions are loopback-only, have no CORS, and use a one-time token.
  - Candidate answers: Web-GUI local-only, a login, or a proxy with its own auth.
  - The merge would also touch the public ndtwin-lab/Web-GUI repo, so it needs a PR and other people's review.
