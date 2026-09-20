<div align="center">

# EasySB

**5-in-1 sing-box deployment script · readable config templates · one-click core management**

[![sing-box](https://img.shields.io/badge/sing--box-%E2%89%A5%201.12.0-3B82F6?style=for-the-badge&logo=go&logoColor=white)](https://sing-box.sagernet.org/)
![License](https://img.shields.io/badge/License-GPL--3.0-22C55E?style=for-the-badge)
[![Protocols](https://img.shields.io/badge/Protocols-5-8B5CF6?style=for-the-badge)](#supported-protocols)
[![Platform](https://img.shields.io/badge/Platform-Linux-F59E0B?style=for-the-badge)](#quick-start)

[简体中文](README.md) | **English**

<sub>AnyTLS · Hysteria2 · TUIC v5 · VMess + WebSocket + TLS · VLESS + Vision + Reality · Certificates · Subscription · Port hopping</sub>

</div>

---

## Table of Contents

- [Introduction](#introduction)
- [Repository Layout](#repository-layout)
- [Supported Protocols](#supported-protocols)
- [Quick Start](#quick-start)
- [Capabilities](#capabilities)
- [Interactive Menu](#interactive-menu)
- [Command Line](#command-line)
- [Non-interactive Install](#non-interactive-install)
- [Config Templates](#config-templates)
- [Subscription](#subscription)
- [Firewall and Port Hopping](#firewall-and-port-hopping)
- [Core Management](#core-management)
- [Developers: Build and Test](#developers-build-and-test)
- [Security Notes](#security-notes)
- [License](#license)

---

## Introduction

EasySB is a 5-in-1 sing-box deployment script for Linux VPS. It brings protocol deployment, certificate issuance, core version management and subscription generation into one interactive menu.

- **Script**: `EasySB/` is the source, composed into a single `easysb.sh` at runtime. After installation the `sb` shortcut opens the menu.
- **Templates**: `Templates/` and the five protocol directories ship readable JSONC samples. Use the templates on their own, or let the script deploy them.
- **Core**: the sing-box binary comes from the official [SagerNet/sing-box](https://github.com/SagerNet/sing-box) releases. Stable and alpha builds can be installed, replaced or removed at any time.

- Homepage: https://github.com/MinimaxFlora/EasySB
- Core source: https://github.com/SagerNet/sing-box
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security: [SECURITY.md](SECURITY.md)

---

## Repository Layout

```text
.
├── EasySB/                       # One-click deployment script
│   ├── lib/                      # Source modules, order equals composition order (12)
│   ├── tests/                    # Test suite (build / text / static / lint)
│   ├── build.sh                  # Compose the single-file release and check syntax
│   ├── config.conf               # Non-interactive install template
│   └── dist/                     # Build output, git-ignored, published to Releases only
├── Templates/                    # Client subscription and global proxy templates
│   ├── config.yaml               # Clash / Mihomo subscription
│   ├── config-rule.yaml          # Clash / Mihomo subscription
│   ├── config.json               # sing-box SFM / SFA / SFI subscription
│   └── tun-fakeip.json           # TUN global proxy + FakeIP template
├── AnyTLS/                       # Protocol config template
├── Hysteria2/                    # Protocol config template
├── Tuic/                         # Protocol config template
├── VMess-WebSocket-TLS/          # Protocol config template
├── VLESS-Vision-Reality/         # Protocol config template
├── Release/                      # Official sing-box packaging files (systemd / completion / scripts)
└── .github/                      # CI workflows and community health files
```

`EasySB/lib/` is split by responsibility; the file number is the composition order:

| Module | Responsibility |
| :--- | :--- |
| `00-header.sh` | Constants, script version, remote endpoints, banner |
| `01-i18n.sh` | Chinese and English text table |
| `02-utils.sh` | Colored output, read wrappers, port input, state I/O |
| `03-detect.sh` | System, architecture, network and dependency detection |
| `04-core.sh` | Core install / uninstall / replace, official version lookup |
| `05-cert.sh` | acme.sh certificate issue, list, switch, remove |
| `06-protocols.sh` | Protocol parameters, server config generation, protocol add/remove |
| `07-firewall.sh` | Port-hopping DNAT rules and boot restore unit |
| `08-service.sh` | Service unit, shortcut, self-update, nginx static site |
| `09-subscribe.sh` | Subscription generation, share links, QR codes |
| `10-menu.sh` | Version panel, main menu, uninstall |
| `11-entry.sh` | Script entry point (must be last) |

---

## Supported Protocols

| Protocol | Transport | Default port | Highlights |
| :--- | :--- | :--- | :--- |
| AnyTLS | TCP + TLS | 8000 | Multi-stage Padding Scheme against traffic fingerprinting |
| Hysteria2 | QUIC / UDP | 8001 | Excellent on lossy networks, supports port hopping |
| TUIC v5 | QUIC / UDP | 8002 | 0-RTT handshake, `native` UDP relay, low latency |
| VLESS + Vision + Reality | TCP | 8003 | Certificate-free disguise, borrows `apple.com` by default |
| VMess + WebSocket + TLS | WS over TLS | 8004 | CDN and reverse-proxy friendly, standard TLS |

Ports are prompted one by one: Enter takes the default, `r` picks a random port, a number sets it manually. Conflicts with another protocol are rejected and re-prompted. Every protocol except VLESS + Reality requires a domain that already resolves to this host plus a valid certificate.

---

## Quick Start

First install (the script detects the system, installs dependencies and walks you through protocol selection):

```bash
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh)
```

After installation, the shortcut opens the menu:

```bash
sb
```

Preset the language before entering the menu:

```bash
# Simplified Chinese
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) --language C

# English
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) --language E
```

Supports Debian / Ubuntu (systemd) and Alpine (OpenRC); run as root.

---

## Capabilities

| Capability | Description |
| :--- | :--- |
| 5-in-1 deployment | One shared UUID and password, generated at install; ports allocated one by one |
| Core management | Install, replace or remove stable and alpha builds; replace keeps the existing config |
| Version panel | Script version, local core, stable and alpha versions on top of the menu with update markers |
| Certificates | acme.sh `--standalone` issue and renew, list, switch active, remove; handles 80 / 443 occupancy |
| Subscription | Renders `Templates/tun-fakeip.json`, outputs files, QR codes and share links, hosted by nginx |
| Port hopping | Hysteria2 defaults to `2080:3000`, auto-applies iptables / nftables DNAT and a boot restore unit |
| Service control | Start, stop, restart, status and enable-on-boot |
| Self-update | Pulls the latest script from this repository and replaces it after validation |
| Bilingual | Language picked on first screen, consistent Chinese and English throughout |

---

## Interactive Menu

```text
[1] Install / switch sing-box core (stable / alpha)
[2] Uninstall sing-box core
[3] Replace sing-box core (keep config)
[4] Certificate management (acme.sh)
[5] Subscription management (sing-box / share links / QR)
[6] Protocol parameters (ports / password / UUID)
[7] Service management (start / stop / restart / status)
[8] Versions and updates
[9] Fully uninstall EasySB
[0] Exit
```

Files: server config `/etc/sing-box/config.json`, state `/etc/sing-box/easysb.conf`, shortcut `/usr/bin/sb`.

---

## Command Line

| Flag | Description |
| :--- | :--- |
| `--language C\|E` | Preset the language, then open the menu |
| `--install stable\|alpha` | Install the given core channel and deploy protocols |
| `--replace stable\|alpha` | Swap the core binary, keep the existing config |
| `--uninstall` | Remove the core |
| `--config FILE` | Read `config.conf` and install non-interactively |
| `--apply-firewall` | Restore port-hopping rules only, used by the boot unit |
| `--version` | Print the script version |
| `--help` | Print usage |

---

## Non-interactive Install

`EasySB/config.conf` is a KV template. Every variable is optional and falls back to a built-in default:

```bash
bash easysb.sh --config config.conf
```

Main fields:

| Field | Description |
| :--- | :--- |
| `LANGUAGE` | `C` Simplified Chinese, `E` English |
| `CORE_CHANNEL` | `stable` or `alpha` |
| `SERVER_IP` | Public address, auto-detected if empty |
| `DOMAIN` / `CERT_DOMAIN` | Certificate domain, self-signed placeholder if empty |
| `UUID` / `PASSWORD` | Shared credentials, auto-generated if empty |
| `IS_ANYTLS` and four more | Per-protocol switches |
| `PORT_ANYTLS` and four more | Per-protocol ports |
| `HY2_HOP_RANGE` | Hysteria2 port-hopping range |
| `REALITY_SNI` / `REALITY_PRIVATE` etc. | Reality handshake domain and keypair, auto-generated if empty |
| `SUB_PORT` / `SUB_PATH` | Subscription port and path |

---

## Config Templates

| Directory | Protocol | Transport | Disguise / encryption | Highlights |
| :--- | :--- | :--- | :--- | :--- |
| `AnyTLS/` | AnyTLS | TCP | TLS | Multi-stage Padding Scheme |
| `Hysteria2/` | Hysteria 2 | QUIC / UDP | TLS (ALPN `h3`) | Port hopping, strong on lossy links |
| `Tuic/` | TUIC | QUIC / UDP | TLS (ALPN `h3`) | 0-RTT handshake, `native` UDP relay |
| `VMess-WebSocket-TLS/` | VMess | WebSocket over TLS | TLS | CDN friendly, Early Data |
| `VLESS-Vision-Reality/` | VLESS + Vision | TCP | REALITY (no cert) | `xtls-rprx-vision`, active-probing resistant |
| `Templates/tun-fakeip.json` | TUN + FakeIP | System-wide | — | Rule routing, DNS split, URLTest |

UUIDs, passwords, REALITY private keys and certificate paths in the templates are samples. Replace them before deployment and keep server and client in sync. Validate syntax with the core:

```bash
sing-box check -c VLESS-Vision-Reality/config_server.json
```

---

## Subscription

The subscription is rendered from `Templates/tun-fakeip.json` and delivered in three ways:

1. A local file under `/etc/sing-box/subscribe/`.
2. A terminal QR code, scannable once `qrencode` is installed.
3. Five share-link schemes covering mainstream clients.

It is also hosted by nginx as a lightweight static site on port `8443` at path `/subscribe`, that is `https://domain:8443/subscribe`. sing-box listens for WebSocket directly; nginx only serves static files and never reverse-proxies.

---

## Firewall and Port Hopping

Hysteria2 port hopping applies standard NAT rules to a UDP port range:

```bash
# iptables
iptables -t nat -A PREROUTING -p udp --dport 2080:3000 -j REDIRECT --to-ports 8001

# nftables
nft add table ip nat
nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; }'
nft add rule ip nat prerouting udp dport 2080-3000 redirect to :8001
```

NAT rules do not survive a reboot, so the script creates a boot restore unit:

- systemd: `easysb-firewall.service` (oneshot, starts before `sing-box.service`).
- OpenRC: `/etc/init.d/easysb-firewall`.

The unit restores rules via `bash /etc/sing-box/easysb.sh --apply-firewall`. It is not created when Hysteria2 port hopping is disabled.

---

## Core Management

| Item | Description |
| :--- | :--- |
| Core source | Official `SagerNet/sing-box` releases; the script downloads official assets directly |
| Stable | Official latest release |
| Alpha | Official prerelease |
| Install | Downloads and verifies for the architecture, writes `/etc/sing-box/sing-box` |
| Replace | Swaps the binary only, keeps `/etc/sing-box/config.json` |
| Uninstall | Stops the service and removes the core |
| Script release | `.github/workflows/easysb-release.yml` builds, tests and publishes `EasySB/dist/easysb.sh` under the fixed `easysb` tag |

---

## Developers: Build and Test

`EasySB/lib/` is the single source; `dist/` is generated and not committed:

```bash
# Compose the release script
bash EasySB/build.sh

# Check only, write nothing
bash EasySB/build.sh --check

# Run the full test suite
bash EasySB/tests/run-tests.sh
```

---

## Security Notes

> UUIDs, passwords, REALITY private keys and certificate paths in this repository are samples. Using them in production is equivalent to having no protection.

- Regenerate every key and UUID before deployment, and keep server and client strictly in sync.
- A REALITY private key belongs on the server only. Never commit it to a public repository.
- Use a real domain and a valid certificate for certificate-based protocols, and tighten certificate file permissions to `600`.
- Follow local laws and use this project only in network environments you are authorized to operate.

Report security issues privately as described in [SECURITY.md](SECURITY.md) instead of opening a public issue.

---

## License

This project is licensed under **GPL-3.0**. See [LICENSE](LICENSE) for the full text.

Copyright (C) 2026 MinimaxFlora. Redistribution and modification must continue to follow GPL-3.0.

<div align="center">

**Built for sing-box · 5-in-1 deployment, straight from the menu.**

GPL-3.0 License © [MinimaxFlora](https://github.com/MinimaxFlora)

</div>
