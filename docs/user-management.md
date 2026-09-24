# User Management and the Subscription Service

This document records the v4 design that replaces the node-wide credential and
the static nginx subscription site with a per-user model served by a built-in
HTTP service. It is the reference for the implementation branch
`feature/user-management`.

## Problem

Until v3 every deployment had exactly one identity: a single node `UUID` and
`PASSWORD`, written into the `users` array of every enabled inbound
(`internal/config/config.go`). Subscriptions were three files rendered once
(`subscribe.json`, `mihomo.yaml`, `v2ray.txt`) and published by nginx through
exact-match locations keyed by the node UUID
(`internal/nginx/nginx.go`). That model cannot express:

- per-person traffic quotas or expiry dates,
- revoking one person without rotating the credential for everybody,
- traffic information in the subscription, the way an airport (机场) link
  carries it,
- one subscription URL that adapts to the requesting client instead of three
  addresses the user has to choose between.

## Scope

In scope: per-user credentials, quotas, expiry, protocol selection, one
adaptive subscription URL, a built-in subscription service, usage accounting
with automatic suspension, and the TUI that manages all of it.

Out of scope, deliberately:

- **Per-user speed limits and device/IP limits.** sing-box has no per-user rate
  control for these protocols, and `common/trafficcontrol` is a connection
  tracker for the Clash API, not a limiter. hysteria2 and tuic expose only
  node-wide `up_mbps` / `down_mbps`.
- **A web panel.** The bubbletea TUI stays the management surface; the new HTTP
  service serves subscriptions only.
- **Migration from a v3 deployment.** A fresh deployment is assumed; leftover
  nginx fragments or static subscription files are not removed automatically.

## Decisions

| # | Decision | Rationale | Rejected |
| :-- | :--- | :--- | :--- |
| D1 | Every user owns **independent credentials per protocol**. | Isolation is real: revoking one user does not touch the others. | One credential set reused across protocols (simpler UI, but one protocol's leak exposes the rest); a node-wide credential (no isolation at all). |
| D2 | Subscriptions are served by a **built-in HTTP service**, and `internal/nginx` is deleted. | The endpoint must branch on User-Agent, emit per-user response headers, and count traffic; static files cannot. Removing nginx also removes a package install, a config fragment and its reload path. | nginx statics plus a sync timer (a reload per cycle, files per user per format, no real UA negotiation); keeping nginx in front of the service (a second moving part for no benefit). |
| D3 | The service **terminates TLS itself**, reusing `cert.ResolveActive`. | The certificate paths the deploy path already resolves are enough; no proxy layer. | nginx terminating TLS; a loopback-only listener that expects an external reverse proxy (no longer one-click). |
| D4 | One subscription URL per user: `/sub/<token>`, content negotiated from the User-Agent. | Users cannot pick the wrong link; the same URL works in sing-box, mihomo, Clash Orbit and v2rayN. | Per-client paths (`/sub/<token>/mihomo`) as the primary form. |
| D5 | The URL token is a **random short id**, unrelated to the user's UUIDs. | Rotation and revocation are independent of the credentials inside the document. | Reusing the VLESS UUID as the token. |
| D6 | Quota and expiry are enforced by **rewriting `config.json` and restarting the core**. | sing-box exposes `StatsService` only; there is no runtime handler to add or remove users. | Leaving exceeded users in the config (they keep working). |
| D7 | Usage is read from **`experimental.v2ray_api` StatsService over gRPC**. | The only supported per-user counter source; `stats.users` is the documented whitelist. | Scraping core logs; Clash API connection tracking (no cumulative totals). |
| D8 | Quota resets on the **natural month**; expiry **disables** the user. | Matches the monthly plan habit; data is kept so renewing restores access. | Rolling N-day windows; deleting expired users. |
| D9 | A disabled, expired or over-quota user gets **403 with a plain-text reason**, and still receives the `Subscription-Userinfo` header. | The client can show "used up" or "expired" while never receiving a half-valid profile (an empty `proxies` list is rejected by Clash-family parsers and an empty sing-box profile fails to parse). | Serving an empty node list; serving the full profile and letting connections time out. |
| D10 | Nodes are named `EasySB-<user name>`. | Distinguishes users and protocols inside a client. | A fixed `EasySB` name. |
| D11 | The top-level menu entry `订阅管理` becomes `用户管理`. | The feature is no longer about subscription files. | Keeping both entries. |
| D12 | New state keys replace the old ones: `SUB_SERVE_PORT`, `SUB_SYNC_SECONDS` are added, `SUB_PORT` and `SUB_PATH` are removed. | The old keys described an nginx static site; keeping unread keys in the file is dead weight. | Keeping them for legacy readers. |

## Data model

### State keys

`/etc/sing-box/easysb.conf` gains:

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `SUB_SERVE_PORT` | `8443` | Port the built-in subscription service listens on. |
| `SUB_SYNC_SECONDS` | `300` | Usage accounting interval, in seconds. |

`SUB_PORT` and `SUB_PATH` are dropped. `DOMAIN`, `CERT_DOMAIN`, `SERVER_IP`,
ports, hop range, Reality parameters and `NODE_DEPLOYED` keep their meaning.

### User store

`/etc/sing-box/easysb-users.json`, mode `0600`, written atomically
(`*.tmp` plus rename) like the state file:

```json
{
  "version": 1,
  "users": [
    {
      "name": "alice",
      "remark": "phone",
      "token": "k7m2p9q4rt3xz8",
      "enabled": true,
      "protocols": ["anytls", "hysteria2"],
      "credentials": {
        "anytls": { "password": "…" },
        "hysteria2": { "password": "…" }
      },
      "quota_bytes": 107374182400,
      "used_bytes": 0,
      "upload_bytes": 0,
      "download_bytes": 0,
      "created_at": "2026-09-24T11:00:00Z",
      "expire_at": "2026-10-24T00:00:00Z",
      "last_reset": "2026-09-01T00:00:00Z",
      "applied": true
    }
  ]
}
```

- `quota_bytes: 0` means unlimited, `expire_at` zero means never.
- `credentials` is keyed by protocol key (`state.Keys`) and holds only the
  fields that protocol needs: `uuid` for `vless-reality` and `vmess-ws-tls`,
  `password` for `anytls` and `hysteria2`, both for `tuic`.
- Credentials are generated when a protocol is selected and are **kept** when it
  is deselected, so re-selecting never invalidates a client import.
- `applied` records whether the user is currently present in the rendered core
  config. The accounting loop only rewrites the config and restarts the core on
  a transition, never on every cycle.
- Status is derived, never stored: `disabled` (admin switch off), `expired`
  (`expire_at` passed), `over-quota` (`used_bytes >= quota_bytes`), else
  `active`.

### Mapping a user onto sing-box

- The **core user name is the token**, not the display name. The V2Ray counter
  key is `user>>><name>>>traffic>>>…`, so the name is both the aggregation key
  and a value that must survive being used as a `QueryStats` regex pattern. A
  random ASCII token is unique by construction and stable across renames, while
  a display name may be Chinese or contain regex metacharacters.
- Every enabled inbound receives a `users` entry for each user that selected
  that protocol, is enabled, is not expired and is not over quota. The same
  name in several inbounds aggregates into one counter set.
- `experimental.v2ray_api` is added automatically:

  ```json
  {
    "listen": "127.0.0.1:10085",
    "stats": { "enabled": true, "users": ["<token>", "…"] }
  }
  ```

  Only names listed in `stats.users` are counted, so the list is rebuilt with
  the same predicate as the inbound `users` arrays.

## Subscription service

`easysb --serve` runs the HTTP service and the accounting loop in one process,
installed as `easysb.service` (systemd) or an OpenRC init script through
`internal/service`.

| Request | Behaviour |
| :--- | :--- |
| `/sub/<token>` | Content selected by User-Agent, plus the response headers below. |
| unknown token | `404` |
| disabled / expired / over-quota token | `403` with a plain-text reason, headers still present |
| any other path | `404` |

User-Agent mapping (normalised to lowercase, first match wins):

| Match | Format | Content type |
| :--- | :--- | :--- |
| `sing-box`, `sfa`, `sfm`, `sfi` | sing-box JSON profile | `application/json` |
| `clash`, `mihomo`, `verge`, `orbit`, `flclash`, `stash`, `quantumult`, `shadowrocket` | mihomo YAML profile | `text/yaml; charset=utf-8` |
| `v2ray`, `passwall`, `homeproxy`, `quantumult%20x`, `loon` | Base64 share-link document | `text/plain; charset=utf-8` |
| anything else (browsers, `curl`, empty) | Base64 share-link document | `text/plain; charset=utf-8` |

Response headers on every `/sub/<token>` response:

```
Subscription-Userinfo: upload=<bytes>; download=<bytes>; total=<bytes>; expire=<unix seconds>
profile-update-interval: 24
Content-Disposition: attachment; filename*=UTF-8''<user name>
Cache-Control: no-store
```

`total=0` means unlimited and `expire=0` never, which is what Clash Orbit,
Clash Verge Rev and v2rayN already understand. The document body stays
byte-compatible with what the v3 templates produced, so no client needs a new
parser.

TLS: when `DOMAIN` is set and `cert.ResolveActive` resolves a pair, the service
listens with that certificate; otherwise it serves plaintext HTTP and the panel
shows a warning, because a plaintext document carries the user's credentials.

## Accounting and enforcement

1. Every `SUB_SYNC_SECONDS`, the loop calls
   `v2ray.core.app.stats.command.StatsService/QueryStats` with a pattern
   covering all users and `reset=true`, then adds each delta to the stored
   counters.
2. The counters live in the running core and **reset to zero when the core
   restarts**, so deltas — never absolute values — are persisted.
3. `last_reset` moving to a new month zeroes `used_bytes`, `upload_bytes` and
   `download_bytes`.
4. A user that becomes disabled, expired or over quota is removed from the
   rendered config (`applied: false`) and the core is restarted, after
   `sing-box check` accepts the new file. Recovery — renewal, quota reset,
   re-enabling — applies in reverse.
5. "Reset traffic" in the panel only zeroes the stored counters; the core
   counters are reset by the next `QueryStats(reset=true)` call.

The visible cost of D6 is a sub-second core restart at the moment a user crosses
a threshold, not on every cycle.

## TUI

```
用户管理
├── 用户列表        # bubbles table: 用户名 · 状态 · 用量/配额 · 到期 · 协议 · 令牌
└── 新建用户
```

List keys: `↑/↓` move, `/` filter, `N` new, `Enter` edit, `D` delete,
`Space` enable/disable, `R` reset traffic, `C` copy subscription URL, `Q` QR
code, `Esc` back. The user detail screen shows the subscription URL, a QR code
per client format and the per-protocol share links for that user only.

`节点参数` loses its `UUID` and `密码` entries. The deploy flow ends by
requiring the first user, because after deployment there is nothing to connect
with until one exists.

## Verified sing-box behaviour

Facts checked against the sing-box `testing` branch source, not assumed:

| Fact | Evidence |
| :--- | :--- |
| All five protocols mark the connection with the user | `metadata.User` is set in `protocol/{vless,vmess,anytls,hysteria2,tuic}/inbound.go` |
| User counters are named and aggregated per name | `experimental/v2rayapi/stats.go` — `user>>>` + user + `>>>traffic>>>uplink/downlink` |
| Only whitelisted users are counted | `StatsService` keeps `s.users` from `stats.users` and skips other names |
| The gRPC service name | `StatsService_ServiceDesc.ServiceName = "v2ray.core.app.stats.command.StatsService"` |
| Counters are in-process atomics | `bufio.NewInt64CounterConn` around each connection; a restart clears them |
| VLESS and VMess fall back to the user index when `name` is empty | `F.ToString(userIndex)` — hence every user must carry a name |
| No per-user rate limiting exists | `common/trafficcontrol` only tracks connections for the Clash API |

## Packages

| Package | Change |
| :--- | :--- |
| `internal/user` | new: user model, store, credential generation, quota/expiry evaluation |
| `internal/subd` | new: subscription HTTP service, TLS, User-Agent negotiation, response headers |
| `internal/stats` | new: minimal gRPC client for StatsService, accounting loop, enforcement |
| `internal/nginx` | deleted |
| `internal/subscribe` | keeps share links and profile rendering, now parameterised by a user |
| `internal/config` | renders multi-user inbounds and the `v2ray_api` block |
| `internal/state` | adds `SUB_SERVE_PORT`, `SUB_SYNC_SECONDS`, drops `SUB_PORT`, `SUB_PATH` |
| `internal/tui` | user list, user form, per-user links and QR, menu rename, deploy flow |
| `internal/service` | installs and controls `easysb.service` in addition to `sing-box.service` |
| `internal/uninstall` | removes the subscription service, user store and unit |
| `internal/i18n` | new strings in both languages |

## Risks

- **A restart is the only enforcement tool.** A threshold crossing disconnects
  every user of the node for a moment. The loop batches transitions per cycle to
  keep this rare.
- **A missing name is a silent zero.** If a user is not in `stats.users`, or an
  inbound omits `metadata.User`, the counter simply never moves. Tests must
  assert the two lists are built from one predicate.
- **The User-Agent table drifts.** A new client that sends an unexpected string
  lands in the Base64 fallback, which most clients still accept.
- **Port collision.** A machine that still runs the old nginx on
  `SUB_SERVE_PORT` will fail to start the service; the error message names the
  port.
- **`SUB_PORT` removal contradicts `docs/design.md`.** The "legacy-compatible
  state" rule was written for the shell tool handover and is narrowed by this
  change; `docs/design.md`, `AGENTS.md` and `docs/pitfalls.md` are updated in
  the same branch.

## Follow-ups

- Per-protocol usage breakdown (a second counter set keyed `name@protocol`).
- A `profile-web-page-url` header once the project has a page to point at.
- Optional web panel on top of the same service.
