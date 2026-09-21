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
  an HTTP client, so mihomo (and v2rayN) must carry the plain endpoint URL.
  `clash://install-config?url=...` (`subscribe.ClashImportScheme`) only works as
  an OS deep link, never from a scanned QR.
- **AnyTLS and Hysteria2 URIs need a slash before the query.** Emitting
  `anytls://pass@host:port?query` makes clients reject the link; the spec form is
  `anytls://pass@host:port/?query`. Credentials must also be percent-encoded
  (`url.User` / `url.UserPassword`), otherwise an `@` or `/` in a generated
  password truncates the URI. Generated passwords avoid the problem by staying
  alphanumeric (`secret.Password`, alphabet `[A-Za-z0-9]`), the intersection
  every target parser accepts. Two client behaviours set that alphabet: OpenWrt's
  homeproxy drops userinfo containing a `%`, so a standard base64 password
  (`+`/`/`/`=`) silently loses the password; `luci-app-ssr-plus` parses hysteria2
  userinfo with the bundled neturl, whose character class is only
  `[A-Za-z0-9+.]`, so URL-safe base64 (`-`/`_`) is dropped there instead.
- **VLESS share links carry a hyphen-less UUID.** `luci-app-ssr-plus` reads the
  vless userinfo through the same neturl, so a canonical UUID is dropped and the
  node ends up with an empty UUID. `subscribe.compactUUID` strips the hyphens;
  Xray, sing-box, mihomo and v2rayN parse the 32 character form to the same
  value. The sing-box JSON and mihomo YAML keep the canonical form.
- **`/v2ray/<uuid>` is the universal Base64 document.** v2rayN reads it
  directly; passwall, passwall2, homeproxy and luci-app-ssr-plus base64-decode
  it first. No separate "base" format is needed, only the per-client parsing
  fixes above.
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

## nginx site

- **`;` does not separate directives without whitespace.** Emitting
  `default_type text/yaml; charset=utf-8;` makes nginx parse `charset=utf-8` as
  the directive name and abort with `unknown directive "charset=utf-8"`. Quote
  the whole value instead: `default_type "text/yaml; charset=utf-8";`.
- **Surface the `[emerg]` line.** The last line of `nginx -t` output only says
  the test failed; report the first `[emerg]`/`[error]` line
  (`nginx.errorLine`) so the real cause is visible.

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
- **Icons assume a Nerd Font.** Users without one set `EASYSB_ICONS=0` or pass
  `--icons off`. Never make layout depend on icons being present.
- **Mouse reporting steals click-drag selection.** While the task/QR screen
  enables `MouseModeCellMotion` for wheel scrolling, the terminal stops
  selecting text on drag, so users cannot copy a subscription URL the usual way.
  The screen therefore offers `C` (OSC52 clipboard copy of the whole log) and
  `M` (release the mouse, restoring native selection). If you add mouse capture
  anywhere else, provide the same escape hatch.
- **After `git filter-branch`, `refs/original/*` remains.** It is a local backup
  of the pre-rewrite refs. Leave it or clean it deliberately; do not push it.
