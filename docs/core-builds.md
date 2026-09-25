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

The panel installs from the author source by default: `core.FetchPreferred` reads the
channel's `version.ini` stamp and builds the download from it, falling back to the official
release for a channel this repository has not published yet (`core.FetchBuildRelease` fails,
`fetchUpstream` answers). `install.sh` installs the author source's stable build through
`easysb --install-core --core-if-missing`, so a one-click install comes with a core and the
first launch of the panel can deploy a node straight away; a host that already has a core is
left untouched, because replacing the core of a running node is the operator's call, made in
the panel. 「内核管理 → 切换内核」 lists the four channel/source combinations
(正式版/测试版 × 作者源/官方源) and marks the one installed, so taking the official build and
coming back are both one selection; 「更新内核」 refreshes the version of what is installed and
keeps its source. The file names are
identical in both sources, so this is a source switch and not a second download path.

Which source is installed is shown, not remembered: the core page's 看板 carries a 内核来源
row (作者源 / 官方源, with whether the binary can count traffic appended) and the version line
on every page names the source too. The recorded source (`CORE_SOURCE` in the state) is used
when the panel performed the install; otherwise it is read off the binary's build tags
(`with_v2ray_api` present means the author source), which also covers an install made before
the record existed.

**A source switch changes what the core can express, so the config is regenerated with it.**
A config naming an API the installed binary was not built with is rejected whole and the node
never starts — and a config that omits the API a capable binary does carry would count
nothing. Either way the kernel action re-renders the config through the deploy path
(`configMatchesCore` decides) instead of starting a node that cannot come up. Without that,
switching to the official core left the node down until someone redeployed by hand.

## How the rebuilt core is produced

`.github/workflows/singbox-v2ray-api.yml` checks out the upstream tag, builds
`./cmd/sing-box` with upstream's own tag list (`release/DEFAULT_BUILD_TAGS` from the
source it just checked out) plus `with_v2ray_api`, and publishes the archive under the
same name the official release uses:

```
sing-box-<version>-linux-<arch>.tar.gz
```

The tag list is read from the checked-out source rather than copied here, so a release
that adds or drops a tag stays in step — but which list is read depends on the
architecture, and that is not cosmetic:

| Architecture | Tag list | Extra |
| :-- | :-- | :-- |
| amd64, arm64 | `release/DEFAULT_BUILD_TAGS` | `with_purego` |
| 386, armv7, armv6, riscv64, s390x | `release/DEFAULT_BUILD_TAGS_OTHERS` | — |

`DEFAULT_BUILD_TAGS` carries `with_naive_outbound`, which needs the Chromium/cronet
toolchain that upstream sets up for its amd64 and arm64 jobs only; building the small
architectures from that list fails outright. `with_purego` is amd64/arm64 only. Both
lists are upstream's, from the source that was just checked out, so a release that adds
or drops a tag stays in step. The version is injected the way upstream does it
(`-X github.com/sagernet/sing-box/constant.Version=<version>`), and `sing-box version`
prints the tags it was built with — that line is what the panel reads to decide whether a
core may carry the stats block (`core.SupportsV2RayStats`).

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
`workflow_dispatch` takes `channels` (both/stable/alpha), `force`, and `keep_generations`.

A channel is only marked done when **both** its stamp matches the upstream version **and**
its archive count matches the architecture count: a run that dies half way leaves a release
whose stamp already names the new version while architectures are missing, and a stamp-only
check would skip that channel forever.

## Retention: two releases forever, one version's archives inside

The fixed channel tags are what keeps the release list at two entries however many upstream
versions pass. The archives inside them still pile up, because their names carry the version
they were built from (`sing-box-1.14.2-linux-amd64.tar.gz`) and a new upstream release adds a
set beside the old one instead of replacing it — after a year each channel would hold hundreds
of files.

`scripts/prune_release_assets.py`, run by the workflow's `prune` job on every run (including
the runs that rebuild nothing, which is exactly when nothing else would tidy up), deletes
every set the channel no longer offers and leaves one version per channel: 7 archives + 7
checksums + `version.ini` = 15 assets. `keep_generations` changes that — `2` keeps the
previous version as well, `0` keeps everything and never prunes. `version.ini` is never
touched: it is the stamp the panel reads, not an archive.

The delete path only has work to do when a stale version exists, so the rules are testable
without GitHub: `--assets-file` takes a JSON list of asset names and `--dry-run` prints the
decisions.

## Adding an architecture

`ARCHES` in the workflow, the `case` that maps an architecture to `GOARCH`/`GOARM`, and
`core.ArchFromUname` in the panel have to agree: the asset name is built from the same
string the panel derives from `uname -m`.
