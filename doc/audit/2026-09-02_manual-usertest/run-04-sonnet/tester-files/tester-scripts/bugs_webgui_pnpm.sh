#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## BUG-5: Web GUI's own deploy script cannot build the frontend image -- `pnpm` (unpinned) now refuses non-interactive installs
- **Feature:** Web GUI, Step 3 ("Execute Deployment Script")
- **Manual page/section:** Installation Manual > NDTwin Tool > Web GUI > "Starting
  Application Deployment" > Step 3.
- **Exact steps (verbatim):**
  ```
  git clone https://github.com/ndtwin-lab/Web-GUI.git
  cd Web-GUI
  cp .env.example .env
  # edited NDT_API_BASE_URL to http://127.0.0.1:8000, the running kernel from this same test
  sudo chmod +x web_gui_deploy.sh
  ./web_gui_deploy.sh
  ```
- **Expected (quoted):** "After deployment completes, you should see ... Frontend:
  http://localhost:3000 / Database: localhost:5433."
- **Observed (verbatim, trimmed):** the frontend image build fails outright, before any
  container starts:
  ```
  #17 [frontend builder 5/7] RUN pnpm install --frozen-lockfile
  #17 2.412 + vite 6.3.5
  #17 2.425 Error: ERR_PNPM_IGNORED_BUILDS
  #17 2.425   x installing dependencies
  #17 2.425   |-> Ignored build scripts: esbuild@0.25.5
  #17 2.425   help: Run "pnpm approve-builds" to pick which dependencies should be allowed
  #17 2.425         to run scripts.
  #17 ERROR: process "/bin/sh -c pnpm install --frozen-lockfile" did not complete successfully:
  exit code: 1
  target frontend: failed to solve: process "/bin/sh -c pnpm install --frozen-lockfile" did
  not complete successfully: exit code: 1
  Failed to start containers.
  ```
  The frontend Dockerfile installs pnpm with a bare `npm install -g pnpm` (visible a few lines
  earlier in the same build log: `RUN npm install -g pnpm`), which pulled **pnpm v12.3.0** on
  2026-09-02 -- no version is pinned anywhere I can see in the repo's own build steps. Recent
  pnpm refuses to run a dependency's install/build script during a `--frozen-lockfile` install
  unless it has been explicitly approved (normally via the interactive `pnpm approve-builds`),
  and a `docker build` has no interactive session to approve it in, so the install -- and the
  whole deploy script -- fails before a single container comes up. `docker-compose ps` /
  `curl localhost:3000` were therefore not reachable to test (Docker itself works: `docker
  --version` -> 29.7.2, `docker compose version` -> v5.5.0, both confirmed separately).
- **Reproduced on a second try?** Not re-run a second time: the failure is deterministic given
  today's pnpm release and an unpinned install line, not a flaky/timing issue, and re-running
  the identical script would rebuild from the same Dockerfile against the same current pnpm
  release.
- **My own workaround attempted:** none. The manual gives no indication this class of failure
  exists (contrast the Installation Manual's P4/BMv2 section, which explicitly discusses
  upstream version drift and pins a script version for exactly this reason) and I did not
  patch the Dockerfile to pin an older `pnpm` or add an approval flag -- that would be fixing
  the project rather than testing it as shipped.
- **Severity (my guess):** High for this specific tool on a from-scratch install today: the
  documented one-command deploy path (`./web_gui_deploy.sh`) cannot produce a running Web GUI
  at all, and there is no alternative deploy path documented on this page.
EOF
echo APPENDED
wc -l ~/BUGS.md
