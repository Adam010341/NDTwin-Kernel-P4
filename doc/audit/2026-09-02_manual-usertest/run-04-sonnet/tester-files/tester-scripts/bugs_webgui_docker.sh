#!/bin/bash
cat >> ~/BUGS.md << 'EOF'

## Minor doc slip: Web GUI's Docker-install block chmods a file it never creates
- **Feature:** Web GUI installation, Step 2 ("Install Docker")
- **Manual page/section:** Installation Manual > NDTwin Tool > Web GUI > "Add Docker official
  GPG key".
- **Exact steps (verbatim):**
  ```
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  ```
- **Expected:** all three lines succeed; the `.asc` file the third line names implies the
  second line was supposed to produce it.
- **Observed:** the second line writes `docker.gpg` (the name every later step in the same
  page actually references, e.g. `signed-by=/etc/apt/keyrings/docker.gpg`), so
  `chmod a+r .../docker.asc` fails: `chmod: cannot access '/etc/apt/keyrings/docker.asc': No
  such file or directory` (exit 1). Harmless here only because `gpg --dearmor -o` already
  wrote `docker.gpg` as `644 root:root` (world-readable) by default -- confirmed with `stat`
  before and after the failed chmod, no change either way -- so apt could read the keyring
  regardless and the rest of the install (`docker --version` -> `Docker version 29.7.2`;
  `docker compose version` -> `Docker Compose version v5.5.0`) succeeded. On a system where
  the default `umask` made the dearmored key non-world-readable, this typo would not be
  harmless.
- **Also noticed in the same section:** `sudo groupadd docker`, run (per the manual's own
  order) *after* `apt install docker-ce ...`, always reports `groupadd: group 'docker'
  already exists` on a stock Ubuntu 24.04 install, because the `docker-ce` package itself
  creates that group during its postinst. Not a failure that blocks anything (the following
  `usermod -aG docker $USER` still succeeds), just a step that -- in this order -- can never
  do the thing its own name says.
- **Severity (my guess):** Cosmetic. Neither slip stopped the install; recording them because
  a reader who *does* check each command's exit status (as this whole test is about doing)
  would see two unexplained non-zero exits in a section that otherwise reads as "just run
  these."
EOF
echo APPENDED
