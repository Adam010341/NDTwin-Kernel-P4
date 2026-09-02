#!/bin/bash
cat >> ~/BUGS.md << 'INNEREOF'

## Addendum to BUG-1: the hardcoded `/home/adam` assumption is not limited to `ndt up`
- **Feature:** `ndt apps nsr`, `ndt ntg`
- **Manual page/section:** same User Manual page, "The rest of the interface" table.
- **Exact steps:**
  ```
  bash -l -c "ndt apps nsr"     # after `git clone .../Network-State-Recorder` into ~ per its
                                 # own Installation Manual page, then symlinked to
                                 # ~/Desktop/Network-State-Recorder once the first attempt named
                                 # that exact path
  bash -l -c "ndt ntg"
  ```
- **Expected:** the manual's table just says these start the NSR reader / hand control to
  NTG's prompt; nothing suggests either depends on paths outside what their own Installation
  Manual pages tell you to create.
- **Observed (verbatim):**
  ```
  $ ndt apps nsr
    XX  NSR not found at /home/ndt/Desktop/Network-State-Recorder
  ```
  -- correctly non-zero exit (1, verified directly, not through a pipe). After symlinking
  `~/Network-State-Recorder` (where its own Installation Manual page's `cd ~ && git clone ...`
  actually puts it) to the path above:
  ```
    XX  nsr exited immediately -- see .test_run/logs/app_nsr.log
    nohup: failed to run command '/home/ndt/miniconda3/envs/ntg-env/bin/python': No such file
    or directory
  ```
  So `ndt apps nsr` wants a **conda** environment at `~/miniconda3/envs/ntg-env`, but NTG's own
  Installation Manual page (which I followed literally) builds a plain **venv** at `~/ntg-env`
  with `python3 -m venv --system-site-packages ~/ntg-env` -- conda is never mentioned on that
  page at all. Separately:
  ```
  $ ndt ntg
    XX  not found: /home/adam/Network-Traffic-Generator/setting/Mininet.yaml
  ```
  the same `/home/adam` (not this machine's `/home/ndt`) assumption BUG-1 already found in
  `ndtwin-lab`, this time surfacing directly from `ndt` itself rather than through the root
  helper.
- **Reproduced:** each shown once; not repeated a second time for the same reason as BUG-1's
  root cause (a hardcoded string compared against this machine's actual paths -- deterministic,
  not timing-sensitive).
- **Severity (my guess):** Low-medium, same family as BUG-1 -- both are honestly and clearly
  reported (`XX ...`, non-zero exit, no silent success), so a reader is not misled, just
  blocked. I did not chase a fix: the manual gives no path-override instructions for `ndt
  apps`/`ndt ntg`, and inventing a `~/miniconda3/envs/ntg-env` conda environment purely to
  satisfy an undocumented internal expectation would be exactly the kind of unsupported
  workaround this test is supposed to flag rather than quietly perform.
INNEREOF
echo APPENDED
