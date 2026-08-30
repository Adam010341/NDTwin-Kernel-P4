# Tools pages — desk check, with the guest measurements that were cheap to take

2026-08-30 evening. Pages: User Manual → NDTwin Tools → **Network State Recorder**,
**Simulation Platform**, **NetworkTrafficGenerator(NTG)**; plus the Installation Manual's
NSR page, which the journey turns out to need.

**Status: desk check plus targeted measurements in the clean-room VM. The live runs are
harnessed (`vm/guest_nsr_journey.sh`, committed) and pending — the VM is compiling §6.7.**
Nothing below is a verdict on the software; every item is about the documents.

---

## The journey is nine blocks across two pages, not six across one

The dispatch scoped this as "the UM NSR page, 6 bash blocks". The page is not a journey:

```
front matter → Features Overview → Usage Guide → ./start_network_state_recorder.sh
```

No clone, no `cd`, no prerequisites, and **no link to an install page**. A reader arriving from
the site menu has nowhere to stand.

⚠️ **I nearly wrote "the NSR page has no installation steps anywhere on the site".** That is
false: `Installation Manual / NDTwin Tool / Network State Recoder.md` has them — `pip install`,
`git clone`, `chmod +x`. The real finding is narrower and more useful: **the usage page does not
link to the install page.** Checking whether a thing exists elsewhere before reporting its
absence is the two-stage criterion from `PRE-ROUND-R1-determination.md`, and it changed the
conclusion here.

## Measured in the guest, not inferred

| # | claim | measurement |
|---|---|---|
| **N-1** | NSR install: `pip install nornir loguru orjson requests` | 🔴 **`error: externally-managed-environment`** on Ubuntu 24.04 (PEP 668). The page's Requirements section names **no** virtualenv, and the Kernel manual **mandates** 24.04. **The first command a reader types does not work.** |
| **N-2** | NTG: `pip install --upgrade pip` / `pip install fastapi …` | same refusal, same reason |
| **N-3** | NTG block 7: `python network_traffic_generator.py` | 🔴 **`python` does not exist** in the clean guest — only `python3`, and `python-is-python3` is not installed |

### N-3 is an internal inconsistency, which is what makes it a defect rather than a nitpick

The same page writes block 2 as

```bash
sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py
```

— a **full interpreter path**, with a comment saying to use "the environment you set up in the
Installation Manual" — and then block 7 as a bare `python`. **No activation step is printed
between them.** So the page knows the interpreter is special and then stops saying so.

## Read from the pages, still to be confirmed live

**N-4 — the missing `cd`, twice, and it is the M-1 shape.**
NSR install prints `git clone …` and then `chmod +x start_network_state_recorder.sh …` with
nothing between them. The clone creates a directory; the `chmod` runs one level above it.
NTG prints `sudo -E bin/ndtwin_kernel …` with no `cd` either.
🔑 Same family as M-1: **a missing `cd` whose failure is quiet, followed by a command that
appears to work.**

**N-5 — both NSR status and stop instructions use `pgrep -f`.**

```bash
pgrep -f network_state_recorder.py                       # status
sudo kill -15 $(pgrep -f network_state_recorder.py)      # stop
```

`pgrep -f` matches **command lines**, so any shell whose own argv carries that string matches
too — `bash -c '…'`, an editor, another grep. In the status command that is a wrong answer; in
the stop command **it is a kill of the wrong process**, run under `sudo`. This project banned
`pgrep -f`/`pkill -f` for killing after seven incidents; the manual teaches it.
Two further edges: with no match the command becomes `sudo kill -15` with no argument, and with
several matches it kills all of them.

**N-6 — NTG's kernel command cannot complete unattended.**
`sudo -E bin/ndtwin_kernel --loglevel info` carries no `--mode` and no `--topology`, so the
kernel falls to its three interactive prompts. The Installation Manual's equivalent block was
corrected on 2026-08-29 to print the flag form for exactly this reason; **this page was not**.

**N-7 — `uvicorn … --port 8000` is the kernel's port.**
⚠️ Stated carefully, because my first reading was wrong and is withdrawn: this block sits under
*How to use NTG in Hardware*, whose prose says worker nodes run on **separate machines**, so it
is **not** a collision as written. But the port is the same one step 2 of the same numbered
sequence binds, and **nothing at the block says the worker must be on another host**. A reader
testing both locally — the obvious thing to do — gets a bind failure with no warning.

**N-8 — the page name is misspelled, in the title as well as the filename.**
`Network State Recoder.md`, and `title: Network State Recoder` in the front matter, in **both**
the User and Installation manuals. It is the site's page title and part of its URL.

## Checked and correct — recorded so this is not a one-sided list

* NSR install page names `NSR.yaml` and `setting/recorder_setting.yaml`; **both exist**.
* Its API Dependency table names `/ndt/get_detected_flow_data` and `/ndt/get_graph_data`;
  **both are real routes** and both answered `200` during T-6.
* All three files the UM page invokes exist and the two shell scripts are executable.
* Simulation Platform's single block uses `cd ~/Simulation-Platform-Manager` — an absolute
  target, stated, which is what the NSR page is missing.

## What is not covered yet

The live runs. `vm/guest_nsr_journey.sh` is committed and runs two passes — literal, then with
the documented defects worked around — so "the documentation is wrong" can be separated from
"the software does not work". It needs the §6.7 build to finish first, and pass 2 additionally
needs a kernel serving `/ndt/` inside the guest. NTG's page also requires **installing NTG**,
which is its own documentation under test.

[Co-developed with claude code -- Adam]
