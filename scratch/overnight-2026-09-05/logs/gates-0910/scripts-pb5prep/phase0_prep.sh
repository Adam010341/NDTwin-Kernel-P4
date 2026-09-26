#!/usr/bin/env bash
# Worker pb5prep, phase 0: (a) main venv fingerprint BEFORE anything runs, (b) .gitignore red/green
# for p4_proxy/venv.*, (c) copy the two compiled P4 artefacts the suites need into the worktree.
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh

# (a) -------------------------------------------------------------------------------------------
f=$(new_log mainvenv_fingerprint_before "main p4_proxy/venv fingerprint (path size mtime), read-only") || exit 2
{ echo "fingerprint $(main_fp)"
  echo "newest: $(find "$MAIN_REPO/p4_proxy/venv" -type f -printf '%TY-%Tm-%Td+%TT %P\n' | sort | tail -1)"
  echo "files: $(find "$MAIN_REPO/p4_proxy/venv" -type f | wc -l)"
  echo "pyvenv.cfg:"; sed 's/^/  /' "$MAIN_REPO/p4_proxy/venv/pyvenv.cfg"
  echo "rc=0"; } >> "$f"
cat "$f"

# (b) -------------------------------------------------------------------------------------------
f=$(new_log gitignore_venv_parking_redgreen "git check-ignore on the parked-venv paths: .gitignore of $TRUNK (RED expected) vs HEAD (GREEN)") || exit 2
tmp=$(mktemp -d "$W/gi.XXXXXX")
rc=0
{
  git -C "$tmp" init -q
  paths=(p4_proxy/venv.protobuf3-20260926/bin/python p4_proxy/venv.protobuf3-20260926.freeze
         p4_proxy/venv.protobuf3-20260926.fingerprint p4_proxy/venv.failed-20260926120000/pyvenv.cfg
         p4_proxy/venv/bin/python)
  for rev in "$TRUNK" "$FULL"; do
      git -C "$WT" show "$rev:.gitignore" > "$tmp/.gitignore"
      echo "== .gitignore @ $rev"
      for p in "${paths[@]}"; do
          if m=$(git -C "$tmp" check-ignore -v --no-index "$p"); then echo "  IGNORED      $p   ($m)"
          else echo "  NOT IGNORED  $p"; fi
      done
  done
  echo "== control: no tracked file matches p4_proxy/venv.* at HEAD"
  n=$(git -C "$WT" ls-files 'p4_proxy/venv.*' | wc -l); echo "  tracked matches: $n"
  # verdict: at TRUNK the four parking paths must be NOT ignored, at HEAD all five ignored
  red=$(git -C "$WT" show "$TRUNK:.gitignore" > "$tmp/.gitignore"; for p in "${paths[@]:0:4}"; do git -C "$tmp" check-ignore -q --no-index "$p" && echo x; done | wc -l)
  green=$(git -C "$WT" show "$FULL:.gitignore" > "$tmp/.gitignore"; for p in "${paths[@]}"; do git -C "$tmp" check-ignore -q --no-index "$p" && echo x; done | wc -l)
  echo "RESULT trunk: $red of 4 parking paths ignored (want 0 = RED); HEAD: $green of 5 ignored (want 5 = GREEN); tracked matches $n (want 0)"
  [[ $red == 0 && $green == 5 && $n == 0 ]] || rc=1
} >> "$f" 2>&1
rm -rf "$tmp"
echo "rc=$rc" >> "$f"
cat "$f"

# (c) -------------------------------------------------------------------------------------------
f=$(new_log p4build_copy "copy of the main checkout's p4_proxy/p4_src/build (gitignored) into the worktree, cp -p") || exit 2
rc=0
{
  mkdir -p "$WT/p4_proxy/p4_src/build"
  for n in ndtwin_switch.json ndtwin_switch.p4info.txt; do
      cp -p "$MAIN_REPO/p4_proxy/p4_src/build/$n" "$WT/p4_proxy/p4_src/build/$n" || rc=1
      sha256sum "$MAIN_REPO/p4_proxy/p4_src/build/$n" "$WT/p4_proxy/p4_src/build/$n"
      cmp "$MAIN_REPO/p4_proxy/p4_src/build/$n" "$WT/p4_proxy/p4_src/build/$n" && echo "  cmp identical: $n" || rc=1
  done
  ls -la --time-style=full-iso "$MAIN_REPO/p4_proxy/p4_src/build/" "$WT/p4_proxy/p4_src/build/"
  git -C "$WT" check-ignore -v p4_proxy/p4_src/build/ndtwin_switch.json || rc=1
  echo "p4 source last commit: $(git -C "$WT" log -1 --format='%h %cI' -- p4_proxy/p4_src/ndtwin_switch.p4)"
} >> "$f" 2>&1
echo "rc=$rc" >> "$f"
cat "$f"
