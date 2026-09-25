# The core the panel is built with

EasySB does not install a sing-box binary. It **is** a sing-box build: the module requires
`github.com/sagernet/sing-box`, and `internal/sbcore` drives the library in-process. The node
the panel deploys runs as

```
/usr/local/bin/easysb core run -c /etc/sing-box/config.json
```

which is what `sing-box.service` / the OpenRC unit now executes (see `internal/service`). There
is no second executable, nothing to download at install time, and nothing to keep in sync with
a config that was rendered for a different build.

## The pieces

| Piece | What it does |
| :-- | :-- |
| `go.mod` | pins the sing-box version. This is *the* core version — bumping it is how the panel moves to a newer sing-box |
| `go build -tags …` | picks the feature set. The release workflow passes `with_quic,with_grpc,with_utls,with_v2ray_api` |
| `-X github.com/sagernet/sing-box/constant.Version=<version>` | the release workflow reads the requirement out of the module graph (`go list -m`) and injects it, the way upstream does. A plain `go build` falls back to the module version, which is what `internal/sbcore` reads from the build info |
| `internal/sbcore` | `Check` (build a box and close it), `Run` (start and block until the context is done), `RealityKeypair`, `Version`, `StatsAvailable` |
| `easysb core …` | the three roles from a shell: `run`, `check`, `version` |

## Why these tags

* `with_quic` — Hysteria2 and TUIC are QUIC inbounds.
* `with_grpc` + `with_v2ray_api` — the per-account counters read `experimental.v2ray_api` over
  gRPC. Without the second tag sing-box refuses a config naming that API **whole**, which is why
  the panel's deploy path asks `core.SupportsV2RayStats` before writing the block. Upstream leaves
  the tag out of its official releases; here the panel builds its own core, so it is always on and
  the panel says so on its Core page.
* `with_utls` — the TLS/uTLS plumbing the Reality and TLS inbounds use.

Deliberately **not** included: `with_naive_outbound` (needs the Chromium/cronet toolchain, and no
server inbound uses that outbound), `with_gvisor` (TUN), `with_tailscale` and the other
client-side endpoints. They are what would otherwise need a special CI toolchain; leaving them
out is what keeps `go build` plain Go for every architecture in the release matrix.

## What this replaced

Two earlier designs are gone with this change, and so is the machinery they needed:

* the panel downloading a core from `SagerNet/sing-box` releases, and
* the panel shipping cores **rebuilt from upstream source with `with_v2ray_api`** in this
  repository's own `singbox-stable` / `singbox-alpha` releases (`.github/workflows/singbox-v2ray-api.yml`,
  `scripts/prune_release_assets.py`), which existed only because the official builds cannot count
  traffic.

`internal/kernel` — the one install path those used, with the channel × source combinations — is
gone as well, together with the panel's Core management menu: with the core compiled in, there is
no combination to choose and no binary to swap. The Core page is now a reading.

## Cost and consequence

* **Size**: the release binary is about 60 MB for linux/amd64 (40 MB stripped), against 16 MB
  before. Every architecture in the matrix carries the whole library.
* **Coupling**: the node's core version moves only when the panel does. That is the deliberate
  trade for "installs nothing": a new sing-box is a `go.mod` bump plus a panel release, so
  `VERSION` and the sing-box requirement travel together.
* **Build time**: every CI job now compiles sing-box's tree. It is plain Go — no cgo, no Chromium,
  no `-checklinkname=0` — which is why the matrix stays affordable.
