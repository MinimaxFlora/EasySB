# EasySB Engineering Docs

This directory is the fast path for other agents and contributors to understand
EasySB without reading the whole tree. Keep it short, factual, and current.

| Document | What it answers |
| :--- | :--- |
| [architecture.md](architecture.md) | Where the code lives, what each module owns, how data flows |
| [design.md](design.md) | Why the project is shaped this way |
| [user-management.md](user-management.md) | Accounts, the subscription service and usage accounting (the v4 model) |
| [conventions.md](conventions.md) | Naming, versioning, commit, and release preferences |
| [pitfalls.md](pitfalls.md) | Traps already hit and how to avoid them |

Start with `README.md` (English) or `README_ZH.md` (Chinese) for the user-facing
view, then come here for implementation detail.

## One-paragraph summary

EasySB is a single static Go binary that deploys and operates a five-protocol
sing-box server on Linux. It replaces the legacy bash implementation with a
full-screen bubbletea TUI. Persistent state lives in
`/etc/sing-box/easysb.conf`, accounts live in
`/etc/sing-box/easysb-users.json`, readable config samples live under
`templates/`, and releases are published by cross-compiling in GitHub Actions
under the tag `v<VERSION>`.
