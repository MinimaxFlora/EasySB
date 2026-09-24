# Pitfalls and Lessons

Traps already hit in this repository. Each entry names the symptom and the fix.

## Release and CI

- **Force push does not raise an Actions run.** After rewriting history, the
  `push` workflow may not start even though the branch moved. Trigger it with a
  normal follow-up commit and push. The release assets come from that run.
- **A rewrite can orphan an old release.** Rewriting the commit that a release
  tag pointed at can make the old tag/release unreachable (it starts returning
  404). Re-publish under the current tag scheme.
- **armv7 naming.** Go spells armv7 as `GOARCH=arm` with `GOARM=7`, but the
  published asset keeps the name `armv7`. Keep the matrix mapping explicit.
- **Older runs overwriting newer assets.** The workflow uses a `concurrency`
  group with `cancel-in-progress` so a stale build cannot publish over a fresher
  one.
- **`make_latest: false`.** The Go release is intentionally not marked latest;
  do not flip this without deciding how it interacts with core releases.

## Version and identity

- **`/etc/os-release` shadows `VERSION`.** In the legacy shell, sourcing
  `/etc/os-release` overwrote the script version variable. The Go build reads a
  dedicated `VERSION` file and falls back to the injected `main.version`. Keep
  those two in step.
- **One tag scheme.** `install.sh`, the workflow, and `internal/update` must all
  derive `v<VERSION>`. A hardcoded tag in one place silently breaks downloads.

## sing-box integration

- **QR payloads differ per client.** sing-box needs its deep link
  (`sing-box://import-remote-profile?url=...`, `subscribe.ImportScheme`); a bare
  URL is not recognized and this is what broke sing-box QR scanning before.
  Clash-family clients are the opposite: their scanners feed the decoded text to
  an HTTP client, so mihomo (and v2rayN) must carry the plain endpoint URL. A
  `clash://install-config?url=...` link only works as an OS deep link, never from
  a scanned QR.
- **AnyTLS and Hysteria2 URIs need a slash before the query.** Emitting
  `anytls://pass@host:port?query` makes clients reject the link; the spec form is
  `anytls://pass@host:port/?query`. Credentials must also be percent-encoded
  (`url.User` / `url.UserPassword`), otherwise an `@` or `/` in a generated
  password truncates the URI. Generated passwords avoid the problem by staying
  alphanumeric (`secret.Password`, alphabet `[A-Za-z0-9]`), the intersection
  every target parser accepts. OpenWrt's homeproxy drops userinfo containing a
  `%`, so a standard base64 password (`+`/`/`/`=`) silently loses the password;
  staying alphanumeric avoids that.
- **Share links keep the canonical UUID.** Emitting the 32 character hyphen-less
  form makes homeproxy flag the node as an invalid UUID through its LuCI `uuid`
  validation, even though sing-box's gofrs parser accepts it. Keep the
  hyphenated form in every share link.
- **The Base64 document is the universal format.** v2rayN reads it directly;
  passwall, passwall2 and homeproxy base64-decode it first. No separate "base"
  format is needed. `luci-app-nikki` runs the mihomo core and validates for a
  top-level `proxies` key, so it needs the mihomo YAML profile — which the one
  `/sub/<token>` endpoint serves once it sees a Clash-family User-Agent.
- **Template actions in comments are still expanded.** `text/template` executes
  `{{ ... }}` even inside YAML/JSON comments. A `{{ .Proxies }}` in a mihomo
  header comment injects uncommented proxy entries above the document root and
  makes the profile unparseable. Keep actions out of comments.
- **`releases.atom` tags omit the `v` prefix.** `core.normalizeTag` re-adds it;
  do not compare raw tags.
- **Downloads assume direct GitHub access.** Deployment targets are overseas,
  so core and binary downloads go straight to `github.com`. Mirror prefixes were
  removed on purpose; do not reintroduce them to work around a local network
  problem.
- **Comments are invalid JSON.** `templates/` files are JSONC for humans. Strip
  comments before handing anything to `sing-box check`.

## Subscription service

- **A client that cannot parse the profile must not receive one.** Refusing an
  expired or over-quota account with `403` and a plain-text reason keeps a
  half-valid profile out of a client: an empty `proxies` list is rejected by the
  Clash-family parsers, and an empty sing-box profile fails to parse outright.
- **The URL and the listener agree on the scheme.** Both ask
  `cert.Usable(DOMAIN)`, which requires a real acme.sh pair. Publishing an
  `https://` URL for a listener that fell back to HTTP (no certificate, or only
  the self-signed one, which clients reject) breaks every import.
- **The core user name is the subscription token.** The V2Ray counter key is
  `user>>><name>>>traffic>>>…`, so the name is also a `QueryStats` regex
  pattern: a token is ASCII by construction and survives a rename, while a display
  name may be Chinese or contain regex metacharacters. The inbound `users` arrays
  and `stats.users` must always come from the same predicate
  (`user.Store.Routable`), or an account is authenticated but never counted.
- **Counters are deltas, never absolutes.** The counters live in the running core
  and reset on restart, so the accounting loop persists differences and clamps a
  negative delta to zero.

## Certificates

- **acme.sh must be installed with `--nocron`.** `get.acme.sh` (the wrapper the
  project used first) always reaches for a crontab, and on a minimal image
  without cron it stops at `Pre-check failed, cannot install` while printing a
  China-mirror wiki link as the last line, so the real reason is hidden. The
  project downloads the release script and runs
  `./acme.sh --install --nocron --noprofile --home <dir>` from the directory it
  was downloaded into; acme.sh copies `acme.sh` from the working directory, so
  invoking it from anywhere else fails with `cannot stat 'acme.sh'`.
- **Without a crontab nothing renews.** Installing with `--nocron` moves the
  responsibility to `easysb-acme.timer` (or the OpenRC script), which runs
  `easysb --renew-certs`. Certificates that are renewed but not reloaded are
  still the old ones in a running core: `--renew-certs` restarts sing-box and the
  subscription service for that reason. If issuance ever moves off `--nocron`,
  the timer must be removed in the same change or renewals happen twice.
- **The acme.sh directory is not `$HOME/.acme.sh` until proven.** The install
  script, sudo and the systemd units each supply a different `HOME`, so
  `cert.ACMEDir()` probes for an installation and every acme.sh call passes
  `--home`, which is what makes the write location and the read location the same.
- **`--standalone` needs socat or python**, and it needs port 80 free: the
  installer depends on socat, and `cert.CheckPort80()` runs after the core is
  stopped, because a running core is usually what holds the port. Both checks
  happen before an ACME attempt is spent. Debian 13 minimal images ship socat and
  python3 but no cron and no crontab, which is the combination that made the
  wrapper script unusable there.
- **A failing challenge usually means DNS, not acme.sh.** A domain behind a CDN
  (or the Cloudflare orange cloud) answers HTTP-01 from the CDN and never reaches
  the host, which shows up as `Verify error` in acme.sh output. The preflight
  report compares the resolved addresses with the host's public IP and says so;
  `EASYSB_ACME_STAGING=1` lets the whole flow be tried without consuming the
  Let's Encrypt rate limit.
- **A stale A record next to a correct one also fails the order.** Let's Encrypt
  validates the challenge against *every* address a domain resolves to, so a
  leftover record pointing at a host that no longer answers fails the issuance
  even though this server answers correctly. The error names the address
  (`During secondary validation: <ip>: … Connection refused`), which reads like a
  server fault; `Report.Others()` warns before the attempt and
  `cert.StrayAddress()` names the record afterwards. Check with the zone's own
  nameservers before doubting the box: `nslookup -type=A <name> <ns>` gives the
  authoritative answer, and a name that resolves to two addresses has two records
  (a wildcard would also have answered for a random subdomain, and a CDN proxy
  would have answered with the CDN's addresses).
- **The CA must be pinned, not inherited.** acme.sh's default CA is ZeroSSL (it
  used to be Let's Encrypt), so leaving `--server` out makes the signing CA depend
  on the installed acme.sh version and splits it from the staging switch, which
  points at Let's Encrypt's test endpoint. `issueArgs()` always passes
  `--server letsencrypt` (`letsencrypt_test` when staging). The CA is recorded per
  domain in `<domain>_ecc/<domain>.conf` as `Le_API`, so a pinned flag only
  affects new issuances; an existing certificate keeps renewing from its own CA
  until it is removed and reissued.
- **`acme.sh --remove` unregisters but does not delete.** It prints `The key and
  cert files are in <dir>` and leaves them there, so reissuing immediately fails
  with `Error creating domain key` until the `_ecc` directory is deleted. Remove
  both when replacing a certificate.
- **Reissuing a valid certificate is not a failure.** acme.sh exits non-zero with
  `Domains not changed. | Skipping. Next renewal time is: …`, which `errorDetail()`
  would otherwise report as a broken issuance to someone who simply clicked the
  button twice. `Issue()` recognises that sentence and returns success.

## State and templates

- **Two subscription templates.** Runtime uses the embedded
  `internal/subscribe/tun-fakeip.json`; `templates/config/tun-fakeip.json` is the
  readable mirror. Editing only one causes drift. The same applies to the mihomo
  template pair `internal/subscribe/mihomo.yaml` and
  `templates/config/mihomo.yaml`.
- **Do not rename state keys.** `easysb.conf` stays compatible with the legacy
  shell tool; add keys, never repurpose them.
- **Renaming a directory touches docs and GitHub metadata.** A folder rename
  must update `README.md`, `README_ZH.md`, `CHANGELOG.md`, `.github/CODEOWNERS`,
  and `.github/PULL_REQUEST_TEMPLATE.md`.

## Toolchain

- **Go 1.27.1.** `go.mod` pins the toolchain. With `GOTOOLCHAIN=auto`, Go
  downloads it automatically; CI uses `go-version-file: go.mod`. Do not lower
  the version casually.
- **Charm v2 uses vanity import paths** (`charm.land/*`), not the old
  `github.com/charmbracelet/*` module paths. Follow the existing imports.

## Terminal and tests

- **Interactive behavior needs a PTY.** For one-shot frame checks use
  `--render --width W --height H`, which prints a single frame without a TTY.
  Use it to catch overflow and alignment regressions.
- **Icons assume a Unicode terminal, not a patched font.** The default palette is
  a set of single-column geometric glyphs that ordinary monospace fonts already
  ship; `--icons ascii` (or `EASYSB_ICONS=ascii`) covers terminals without
  Unicode. Never make layout depend on a glyph being wider than one column.
- **Mouse reporting steals click-drag selection.** While the task/QR screen
  enables `MouseModeCellMotion` for wheel scrolling, the terminal stops
  selecting text on drag, so users cannot copy a subscription URL the usual way.
  The screen therefore offers `C` (OSC52 clipboard copy of the whole log) and
  `M` (release the mouse, restoring native selection). If you add mouse capture
  anywhere else, provide the same escape hatch.
- **After `git filter-branch`, `refs/original/*` remains.** It is a local backup
  of the pre-rewrite refs. Leave it or clean it deliberately; do not push it.
