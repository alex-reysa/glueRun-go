# Security Policy

singular runs repo-configured shell commands and launches local coding agents in
git worktrees. Treat a repo's `singular.config.json`, `singular.config.sh`, task
files, and opt-in modules as executable trust boundaries.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. If private
reporting is unavailable, open a minimal public issue asking for a private
channel and do not include exploit details, credentials, or proof-of-concept
payloads in the public issue.

## Handling credentials

Do not commit credentials, `.env` files, `.singular-state/`, `.worktrees/`,
`.singular-evidence/`, or generated run artifacts. Runtime operator overrides and
secrets belong in `.singular-state/config.local.sh`, which is gitignored by the
scaffold.
