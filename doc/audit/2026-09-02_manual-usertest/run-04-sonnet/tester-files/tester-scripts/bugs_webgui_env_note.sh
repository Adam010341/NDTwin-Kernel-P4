#!/bin/bash
cat >> ~/BUGS.md << 'INNEREOF'

## Note: Web GUI's .env names a GitHub token the Installation Manual never mentions
Reading the generated `.env` (from `.env.example`) for unrelated reasons, its last field is
`VITE_GITHUB_TOKEN` ("Required only if using LLM features that need GitHub API access"). The
Installation Manual's Web GUI page never mentions this variable, and the User Manual's
"NDTwin Assistant" feature description (natural-language prompts for congested links, heavy
flows, flow-entry install/modify/delete) does not say it depends on a GitHub token either --
if anything, "LLM" plus the Kernel's own `--ai`/`OPENAI_API_KEY` elsewhere in this project
would suggest OpenAI, not GitHub. Not tested further (D3/BUG-5 blocks the frontend from
building at all, so the Assistant feature was never reachable), recording only because a
reader who does get the frontend to build would hit an undocumented credential requirement
for that one feature.
INNEREOF
echo APPENDED
