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
- `docs/user-management.md` - accounts, the subscription service and usage accounting
- `docs/conventions.md` - naming, language, versioning, commit and release rules
- `docs/pitfalls.md` - known traps and how to avoid them

## Commands

```bash
go build -o easysb .
go vet ./...
go test ./...
gofmt -l .
```

The core is compiled into the panel from this module's `go.mod`. Build with the
release's tag set, otherwise the binary has no QUIC inbounds and cannot serve the
counters:

```bash
go build -tags "with_quic,with_grpc,with_utls,with_v2ray_api" -o easysb .
```

`easysb core run -c <config>` is the node (the service unit runs it), `core check`
validates a config, `core version` prints what the binary carries.

Render one TUI frame without a TTY (good for layout checks):

```bash
./easysb --render --width 100 --height 40
```

## Rules that are easy to get wrong

- The release tag is always `v<VERSION>`. Derive it; never hardcode it in a
  second place. `install.sh`, the workflow, and `internal/update` share it.
- The core is not a file. `internal/sbcore` drives the sing-box library in-process,
  and the node unit runs the panel (`easysb core run -c /etc/sing-box/config.json`).
  Do not reintroduce a downloaded or switched core binary: the sing-box version is a
  `go.mod` requirement, and it moves only with a panel release.
- Build tags are part of the product: `with_v2ray_api` is what makes per-account
  counters possible at all, so the deploy path may only write the `experimental.v2ray_api`
  block when `core.SupportsV2RayStats` says the build carries it.
- Keep `/etc/sing-box/easysb.conf` compatible with the legacy shell tool. Add
  keys, do not rename or repurpose them. The one exception is a key that
  described a component which no longer exists (v4 dropped `SUB_PORT` and
  `SUB_PATH` with the nginx site); removing such a key is part of the same
  change that removes the component, and the docs change with it.
- The account store `/etc/sing-box/easysb-users.json` is the only source of
  credentials. The core user name is the account token, and the inbound `users`
  arrays and `stats.users` must both come from `user.Store.Routable`, or an
  account is authenticated but never counted.
- Every user-facing string goes through `internal/i18n` for both `C` and `E`.
- Directories and paths are lowercase ASCII. `templates/` subdirectories are
  lowercase.
- The runtime subscription templates are embedded from `internal/subscribe/`
  (`tun-fakeip.json`, `mihomo.yaml`); `templates/config/` holds the readable
  mirrors. Keep each pair in sync.
- `README.md` is English; `README_ZH.md` is Chinese. Update both.
- Use conventional commit subjects (`type(scope): subject`) and no co-author
  trailers.
