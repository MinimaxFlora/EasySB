# AGENTS.md

Guidance for AI agents working in this repository.

## What this is

EasySB is a single static Go binary that deploys and operates a five-protocol
sing-box server on Linux, with a full-screen bubbletea TUI. It replaces a
legacy bash implementation. The entry point is `main.go`; the module is
`github.com/MinimaxFlora/EasySB` and requires Go 1.27.1.

Read `docs/` first, then the package you need:

- `docs/architecture.md` - layout, runtime paths, package responsibilities
- `docs/design.md` - the decisions behind the shape of the code
- `docs/conventions.md` - naming, language, versioning, commit and release rules
- `docs/pitfalls.md` - known traps and how to avoid them

## Commands

```bash
go build -o easysb .
go vet ./...
go test ./...
gofmt -l .
```

Render one TUI frame without a TTY (good for layout checks):

```bash
./easysb --render --width 100 --height 40
```

## Rules that are easy to get wrong

- The release tag is always `v<VERSION>`. Derive it; never hardcode it in a
  second place. `install.sh`, the workflow, and `internal/update` share it.
- Keep `/etc/sing-box/easysb.conf` compatible with the legacy shell tool. Add
  keys, do not rename or repurpose them.
- Every user-facing string goes through `internal/i18n` for both `C` and `E`.
- Directories and paths are lowercase ASCII. `templates/` subdirectories are
  lowercase.
- The runtime subscription template is embedded from
  `internal/subscribe/tun-fakeip.json`; `templates/config/tun-fakeip.json` is the
  readable mirror. Keep them in sync.
- `README.md` is English; `README_ZH.md` is Chinese. Update both.
- Use conventional commit subjects (`type(scope): subject`) and no co-author
  trailers.
