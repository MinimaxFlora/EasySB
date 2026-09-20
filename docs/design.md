# Design Principles

These are the decisions that shape the codebase. When a change conflicts with
one of them, treat the change as a design discussion rather than a local edit.

## Single static binary

Everything except the sing-box core and acme.sh is compiled in. There is no
runtime package manager call on the hot path and no script interpreter needed.
The binary is invoked as `sb` after `install.sh` links it.

## Legacy-compatible state

`/etc/sing-box/easysb.conf` keeps the KV layout of the old bash tool. A Go build
and a shell build can inspect the same deployment. Do not change existing keys;
add new ones instead.

## Templates are readable first

`templates/` holds JSONC that a human can read and copy. Comments are allowed
there even though sing-box itself would reject them; the tool strips comments
when it renders a real config. The subscription template that ships inside the
binary is `internal/subscribe/tun-fakeip.json`; `templates/config/tun-fakeip.json`
is the readable mirror.

## Bilingual by construction

Every user-facing string flows through `internal/i18n`. The language is a
`Lang` value (`C` or `E`), never a global boolean. `L` toggles at runtime. New
strings must be added to the table for both languages in the same commit.

## Version is data, not code

`VERSION` is the single source of truth. The release workflow reads it, injects
`main.version` with `-ldflags -X`, and publishes under the tag `v<VERSION>`.
`install.sh` derives `RELEASE_TAG="v${VERSION}"`, and `internal/update` derives
the same tag from the remote version. Never hardcode a release tag in more than
one place.

## Non-interactive entry points

Anything a boot unit needs must be reachable without a TTY. `--apply-firewall`
is the model case: it loads state, applies rules, writes the unit, and exits.
The TUI calls the same package functions.

## Dark, quiet terminal UI

The palette is dark with cyan as the primary accent. The UI uses the alternate
screen, one border, and one accent per state (ok / warn / error). Spacing is
explicit: dividers and menu items each get exactly one blank line, and the
dashboard drops low-priority panels before it overflows a short terminal.

## Fail soft on the network

Core downloads walk a proxy fallback chain (`""`, `ghfast.top`, `gh-proxy.com`)
and release tag parsing tolerates a missing `v` prefix. A single network failure
should degrade to the next mirror rather than abort the flow.
