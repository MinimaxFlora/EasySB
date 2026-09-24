# Core builds with the V2Ray API

The panel has two possible sources for the sing-box core, and they differ in one build
tag.

## Why a second source exists

Per-account traffic accounting reads `experimental.v2ray_api` over gRPC (see
`docs/user-management.md`, decision D7). That API is behind the `with_v2ray_api` build
tag, which upstream leaves **out** of its official releases: `sing-box check` refuses a
whole config that names an API the binary was not built with, so a deployment on an
official core carries no stats block and the panel says so in the deploy log. Installed
traffic quotas still work, they are just never filled from real usage.

## The two sources

| Source | Where it comes from | Traffic counters |
| :-- | :-- | :-- |
| Upstream | `SagerNet/sing-box` releases, `sing-box-<ver>-linux-<arch>.tar.gz` | no |
| Rebuilt | this repository's `singbox-stable` / `singbox-alpha` releases, same file names | yes |

`SagerNet/sing-box` publishes the newest non-prerelease tag as a normal release and the
newest `alpha`/`beta`/`rc` tag as a *prerelease*; the panel calls them the stable and the
alpha channel, and so does the rebuild.

## How the rebuilt core is produced

`.github/workflows/singbox-v2ray-api.yml` checks out the upstream tag, builds
`./cmd/sing-box` with upstream's own tag list (`release/DEFAULT_BUILD_TAGS` from the
source it just checked out) plus `with_v2ray_api`, and publishes the archive under the
same name the official release uses:

```
sing-box-<version>-linux-<arch>.tar.gz
```

The tag list is read from the checked-out source rather than copied here, so a release
that adds or drops a tag stays in step. `with_purego` is added for amd64 and arm64, which
is what the official archives of those architectures carry. The version is injected the
way upstream does it (`-X github.com/sagernet/sing-box/constant.Version=<version>`), and
`sing-box version` prints the tags it was built with — that line is what the panel reads
to decide whether a core may carry the stats block (`core.SupportsV2RayStats`).

Two rolling releases hold the results, one per channel, each with a `version.ini` stamp:

```ini
[singbox]
channel=stable
version=1.14.2
tag=v1.14.2
upstream=SagerNet/sing-box
arches=amd64,arm64,armv7,armv6,386,riscv64,s390x
build_tags=with_gvisor,...,with_v2ray_api
```

A channel is only rebuilt when upstream moved, so the daily run is usually a no-op;
`workflow_dispatch` takes `channels` (both/stable/alpha) and `force`.

## Adding an architecture

`ARCHES` in the workflow, the `case` that maps an architecture to `GOARCH`/`GOARM`, and
`core.ArchFromUname` in the panel have to agree: the asset name is built from the same
string the panel derives from `uname -m`.
