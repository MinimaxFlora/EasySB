# The core inside the panel

`github.com/sagernet/sing-box` is a requirement of this module. The core is not a file
any more: the version is a line in `go.mod`, the node is this binary started in node mode,
and nothing downloads, installs, unpacks or switches a core binary on the host.

```
go.mod                       github.com/sagernet/sing-box v1.14.2
internal/sbcore              the engine: run, check, version, build capability
/etc/systemd/system/sing-box.service
                             ExecStart=/usr/local/bin/easysb core run -c /etc/sing-box/config.json
easysb core run -c <config>  the node
easysb core check -c <config>  the same engine, building and closing the config
easysb core version          the release this binary carries, and its capability
```

`internal/sbcore.Run` builds the configuration with the library that would serve it,
starts the instance and blocks until the service manager ends the process; `Check` is the
same build without `Start`, which is what the deploy path runs before restarting the node.
Both go through `include.Context`, the registry set the upstream command line uses, so a
configuration the panel accepts is one `sing-box` itself accepts.

## The tag set, defined once

Build tags decide what the binary can express, so they are part of the product, not a
build detail. They live in `release/TAGS` — one line, read by
`.github/workflows/easysb-go-release.yml` and by `install.sh` when it builds from source:

```
with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_naive_outbound,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,with_v2ray_api
```

That is upstream's own `release/DEFAULT_BUILD_TAGS` plus one tag of our own,
`with_v2ray_api`. The list is the same one the previous release shipped its downloaded
cores with, so the feature set of a node is unchanged by moving the core inside.

**`with_v2ray_api` is the tag that matters.** It is the only way sing-box counts bytes per
account, which is what the traffic columns of 账号与流量 read. A tag cannot be probed at run
time — it is compiled in or it is not — so the capability is a file pair rather than a
runtime check:

| File | Tag | `sbcore.StatsCapable()` |
| :-- | :-- | :-- |
| `internal/sbcore/stats_on.go` | `with_v2ray_api` | `true` |
| `internal/sbcore/stats_off.go` | `!with_v2ray_api` | `false` |

The deploy path asks it before writing `experimental.v2ray_api`: the core refuses a whole
configuration that names an API it does not have (`v2ray api is not included in this
build`), so a build without the tag must leave the block out. Such a build still deploys a
working node — the panel says so in the deploy log and the accounting loop skips sampling
instead of reporting a dead socket every interval. The release builds always carry the tag;
only a developer build without `-tags` does not.

**`with_quic` is the other tag that shows up as a sentence from the core.** Hysteria2 and
TUIC are QUIC protocols, so a build without that tag refuses any configuration carrying
one (`QUIC is not included in this build, rebuild with -tags with_quic`) — the deploy path
logs the core's own words and stops, which is the honest failure but not a working node.
`release/TAGS` carries it, so this only affects a hand-rolled build; `internal/deploy`'s
tests are split the same way, with the five-protocol document behind `with_quic` and a
three-protocol one that every build accepts (`deploy_quic_test.go`).

## What an operator sees

There is no 内核管理 section: a panel cannot manage a core that ships inside it. The
version lives where the panel's own version lives (the system card and the version line on
every page), and it reads

```
1.14.2 · 带流量统计
```

where `带流量统计` / `无流量统计` is `StatsCapable()` — the same fact the deploy path uses,
so the label cannot disagree with what the node does. The menu entry that used to open
内核管理 now opens 服务解锁状态, which answers a question a VPS operator actually has: which
services this IP can use.

`internal/sbcore.Version` prefers the release stamp
(`-X github.com/sagernet/sing-box/constant.Version=…`) and falls back to the module
version of the requirement, which is why a local build reports the same number as the
released one.

## The rebuild workflow (legacy)

`.github/workflows/singbox-v2ray-api.yml` rebuilds upstream sing-box with `with_v2ray_api`
and publishes the archives as the rolling releases `singbox-stable` / `singbox-alpha`. It
existed to feed 内核管理, which no longer consumes anything: the panel compiles the core in
and takes the sing-box version from `go.mod`. The workflow, its `prune` job and
`scripts/build_singbox_v2ray_api.sh` are therefore unused by the panel and are kept only
until a decision is made about the channel they maintain. Removing them changes nothing in
the binary.
