#!/usr/bin/env bash
# Replay fix/p4proxy-protobuf5-0926 (580767a8..5bb5f1fa) onto the same base with identical trees,
# authors and author dates; only b5f14624's subject line changes (Adam's ruling I, 2026-09-27:
# "reword the subject, then merge"). Writes objects and one new branch ref, nothing else.
# [Co-developed with claude code -- Adam]
set -euo pipefail
BASE=580767a8a; HEAD_OLD=5bb5f1fa
BASE=$(git rev-parse 580767a8); HEAD_OLD=$(git rev-parse 5bb5f1fa)
[[ -z "$(git rev-list --merges $BASE..$HEAD_OLD)" ]] || { echo "REFUSE: merges in range"; exit 2; }
prev=$BASE
for c in $(git rev-list --reverse $BASE..$HEAD_OLD); do
  msg=$(git log -1 --format=%B $c)
  if [[ $c == b5f14624* ]]; then
    old_subj=$(git log -1 --format=%s $c)
    new_subj="protobuf 5.29.6 for the P4 proxy, with p4runtime's generated modules regenerated at install"
    msg="$new_subj${msg#"$old_subj"}

Subject reworded on 2026-09-27 under Adam's ruling I (merge; acceptance is a live 01 and 06 on the
development machine's p4_proxy/venv after its migration, the old venv kept for a one-step rollback).
It read: \"$old_subj\". The manual's P4 path clones NDTwin-Kernel-P4-public, which this merge does
not change; its text is drafted for Adam, to change when that repo is synced."
  fi
  new=$(GIT_AUTHOR_NAME="$(git log -1 --format=%an $c)" GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae $c)" \
        GIT_AUTHOR_DATE="$(git log -1 --format=%aI $c)" git commit-tree "$c^{tree}" -p "$prev" -m "$msg")
  echo "$c -> $new $(git log -1 --format=%s $new | cut -c1-70)"
  prev=$new
done
[[ "$(git rev-parse "$prev^{tree}")" == "$(git rev-parse "$HEAD_OLD^{tree}")" ]] && echo "tree identical: $(git rev-parse "$prev^{tree}")"
git branch fix/p4proxy-protobuf5-0927 "$prev" && echo "branch fix/p4proxy-protobuf5-0927 = $prev"
