#!/usr/bin/env python3
"""Review a pull request's diff with Claude and write the review as Markdown.

[Co-developed with claude code -- Adam]

    tools/pr_review/review.py --base <sha> --head <sha> --title "<PR title>" --out review.md

The workflow in .github/workflows/pr-review.yml runs this on every PR and posts the result as a
PR review, so anyone working on the branch (people or agents) reads it with
`gh pr view <N> --comments`.

One API call over the whole diff, no tools. The model never runs anything on the runner, and the
cost of a run is the diff's size, nothing more. A diff over MAX_DIFF_CHARS is not cut down: the
review says it was skipped, because a review of half a change reads like a review of all of it.
"""
import argparse
import os
import subprocess
import sys

import anthropic

MODEL = os.environ.get("REVIEW_MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("REVIEW_EFFORT", "high")

#: About 100k tokens. At Opus 5.5 input prices that keeps one run well under a dollar.
MAX_DIFF_CHARS = 400_000

#: Per million tokens, for the cost line under the review. Unknown models print tokens only.
PRICES = {
    "claude-opus-5-5": (4.00, 20.00),
    "claude-sonnet-5-5": (2.00, 10.00),
    "claude-haiku-5-5": (0.10, 0.50),
}

SYSTEM = """You review pull requests for NDTwin-Kernel-P4, a network digital twin: a C++ kernel \
(CMake, Boost, spdlog, nlohmann/json) that talks to OVS or to P4 bmv2 switches through a Python \
proxy, plus Python and shell tooling for Mininet labs and tests.

Report only problems a maintainer would want fixed before merging:
- bugs: wrong logic, off-by-one, unchecked errors, races, leaks, undefined behaviour
- tests that cannot fail, or that no longer test what their name says
- docs, README or comments that now disagree with the code in this diff
- anything that would break the build or CI

Skip style, naming and formatting unless they hide a bug. Do not praise, do not summarise the \
change back. For each finding give `path:line`, one sentence on what is wrong, and one on the \
concrete failure it causes. Order findings by severity. If you are unsure, say so in the finding \
rather than leaving it out. If you find nothing worth fixing, reply with exactly: No issues found."""


def git_diff(base, head):
    # Three dots: what the PR adds on top of the merge base, not what main gained meanwhile.
    return subprocess.run(
        ["git", "diff", "--no-color", "--find-renames", f"{base}...{head}"],
        check=True, capture_output=True, text=True,
    ).stdout


def cost_line(usage):
    tokens_in = usage.input_tokens + (usage.cache_read_input_tokens or 0) \
        + (usage.cache_creation_input_tokens or 0)
    line = f"{MODEL}, {tokens_in:,} tokens in, {usage.output_tokens:,} out"
    if MODEL in PRICES:
        p_in, p_out = PRICES[MODEL]
        line += f", about ${(tokens_in * p_in + usage.output_tokens * p_out) / 1e6:.2f}"
    return line


def review(title, diff):
    client = anthropic.Anthropic()
    with client.beta.messages.stream(
        model=MODEL,
        max_tokens=64000,
        system=SYSTEM,
        output_config={"effort": EFFORT},
        # A safety-classifier decline reruns on a fallback model instead of failing the job.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        messages=[{
            "role": "user",
            "content": f"Pull request: {title}\n\n<diff>\n{diff}\n</diff>",
        }],
    ) as stream:
        message = stream.get_final_message()

    if message.stop_reason == "refusal":
        return "The review model declined this diff, so it was not reviewed.", message
    text = "".join(b.text for b in message.content if b.type == "text").strip()
    if message.stop_reason == "max_tokens":
        text += "\n\n(The review hit its output limit and is cut short.)"
    return text, message


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--dry-run", action="store_true",
                    help="print the diff size and stop before calling the API")
    args = ap.parse_args()

    diff = git_diff(args.base, args.head)
    print(f"diff: {len(diff):,} chars", file=sys.stderr)

    if not diff.strip():
        body = "Nothing to review: the diff is empty."
    elif len(diff) > MAX_DIFF_CHARS:
        body = (f"Not reviewed: the diff is {len(diff):,} characters, over the "
                f"{MAX_DIFF_CHARS:,} limit. Split the PR or review it by hand.")
    elif args.dry_run:
        return 0
    else:
        text, message = review(args.title, diff)
        body = f"{text}\n\n<sub>Automated review by {cost_line(message.usage)}.</sub>"

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(body + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
