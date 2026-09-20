<div align="center">

# EasySB

**sing-box 五合一部署脚本 · 配置模板开箱可读 · 内核版本一键管理**

[![sing-box](https://img.shields.io/badge/sing--box-%E2%89%A5%201.12.0-3B82F6?style=for-the-badge&logo=go&logoColor=white)](https://sing-box.sagernet.org/)
![License](https://img.shields.io/badge/License-GPL--3.0-22C55E?style=for-the-badge)
[![Protocols](https://img.shields.io/badge/Protocols-5-8B5CF6?style=for-the-badge)](#easysb-支持协议)
[![Platform](https://img.shields.io/badge/Platform-Linux-F59E0B?style=for-the-badge)](#快速开始)

**简体中文** | [English](README_EN.md)

<sub>AnyTLS · Hysteria2 · TUIC v5 · VMess + WebSocket + TLS · VLESS + Vision + Reality · 证书 · 订阅 · 端口跳跃</sub>

</div>

---

## 目录

- [项目简介](#项目简介)
- [仓库结构](#仓库结构)
- [支持的协议](#支持的协议)
- [快速开始](#快速开始)
- [EasySB 能力](#easysb-能力)
- [交互菜单](#交互菜单)
- [命令参数](#命令参数)
- [无交互安装](#无交互安装)
- [配置模板](#配置模板)
- [订阅](#订阅)
- [防火墙与端口跳跃](#防火墙与端口跳跃)
- [内核管理](#内核管理)
- [开发者：构建与测试](#开发者构建与测试)
- [安全须知](#安全须知)
- [开源协议](#开源协议)

---

## 项目简介

EasySB 是一个面向 Linux VPS 的 sing-box 五合一部署脚本，把协议部署、证书申请、内核版本管理、订阅生成统一到一套交互式菜单里。

- **脚本**：`EasySB/` 是脚本源码，运行时合成单文件 `easysb.sh`，安装后可直接用 `sb` 呼出菜单。
- **模板**：`Templates/` 与五个协议目录提供可直接阅读的 JSONC 配置样例，既可以只用模板，也可以交给脚本自动落地。
- **内核**：sing-box 内核取自官方 [SagerNet/sing-box](https://github.com/SagerNet/sing-box) Releases，正式版与 alpha 内测版可随时切换、替换、卸载。

- 项目地址：https://github.com/MinimaxFlora/EasySB
- 内核来源：https://github.com/SagerNet/sing-box
- 变更记录：[CHANGELOG.md](CHANGELOG.md)
- 贡献指南：[CONTRIBUTING.md](CONTRIBUTING.md)
- 安全策略：[SECURITY.md](SECURITY.md)

---

## 仓库结构

```text
.
├── EasySB/                       # 一键部署脚本
│   ├── lib/                      # 源码模块，编号顺序即合成顺序（12 个）
│   ├── tests/                    # 测试套件（构建 / 文案 / 静态 / lint）
│   ├── build.sh                  # 模块合成单文件 + 语法校验
│   ├── config.conf               # 无交互安装配置模板
│   └── dist/                     # 构建产物，git 忽略，仅发布到 Releases
├── Templates/                    # 客户端订阅与全局代理模板
│   ├── config.yaml               # Clash / Mihomo 订阅
│   ├── config-rule.yaml          # Clash / Mihomo 订阅
│   ├── config.json               # sing-box SFM / SFA / SFI 订阅
│   └── tun-fakeip.json           # TUN 全局代理 + FakeIP 模板
├── AnyTLS/                       # 协议配置模板
├── Hysteria2/                    # 协议配置模板
├── Tuic/                         # 协议配置模板
├── VMess-WebSocket-TLS/          # 协议配置模板
├── VLESS-Vision-Reality/         # 协议配置模板
├── Release/                      # sing-box 官方打包文件（systemd / shell 补全 / 打包脚本）
└── .github/                      # CI 工作流与社区健康文件
```

`EasySB/lib/` 按功能拆分，文件编号即合成顺序：

| 模块 | 职责 |
| :--- | :--- |
| `00-header.sh` | 项目常量、脚本版本、远端地址、版本横幅 |
| `01-i18n.sh` | 中英文文案表 |
| `02-utils.sh` | 彩色输出、read 封装、端口输入、状态读写 |
| `03-detect.sh` | 系统、架构、网络与依赖检测 |
| `04-core.sh` | 内核安装 / 卸载 / 替换、官方版本查询 |
| `05-cert.sh` | acme.sh 证书申请、列表、切换、删除 |
| `06-protocols.sh` | 协议参数、服务端配置生成、协议增删 |
| `07-firewall.sh` | 端口跳跃 DNAT 规则与开机恢复单元 |
| `08-service.sh` | 服务单元、快捷指令、自更新、nginx 静态站点 |
| `09-subscribe.sh` | 订阅生成、分享链接、二维码 |
| `10-menu.sh` | 版本面板、主菜单、卸载 |
| `11-entry.sh` | 脚本入口（必须最后） |

---

## 支持的协议

| 协议 | 承载 | 默认端口 | 特点 |
| :--- | :--- | :--- | :--- |
| AnyTLS | TCP + TLS | 8000 | Padding Scheme 多阶段填充，对抗流量指纹 |
| Hysteria2 | QUIC / UDP | 8001 | 弱网与高丢包场景表现优秀，支持端口跳跃 |
| TUIC v5 | QUIC / UDP | 8002 | 0-RTT 握手，`native` UDP 转发，低延迟 |
| VLESS + Vision + Reality | TCP | 8003 | 免证书伪装，默认偷用 `apple.com`，抗主动探测 |
| VMess + WebSocket + TLS | WS over TLS | 8004 | 可穿 CDN 与反向代理，基于标准 TLS |

端口在安装时逐一询问：回车取默认值，输入 `r` 随机，输入数字手动指定；与其他协议冲突时会提示重新设置。除 VLESS + Reality 外的协议都需要一个已解析到本机的域名与有效证书。

---

## 快速开始

首次安装（脚本会自动识别系统、补全依赖并引导你选择协议）：

```bash
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh)
```

安装完成后，再次运行只需输入快捷指令：

```bash
sb
```

预设语言后进入菜单：

```bash
# 简体中文
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) --language C

# English
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) --language E
```

支持 Debian / Ubuntu（systemd）与 Alpine（OpenRC）；需要 root 权限运行。

---

## EasySB 能力

| 能力 | 说明 |
| :--- | :--- |
| 五协议部署 | 五协议共享一个 UUID 与一个密码，安装时统一生成，端口逐一编排 |
| 内核版本管理 | 正式版 stable 与 alpha 内测版随时安装、替换、卸载，替换保留现有配置 |
| 版本面板 | 菜单顶部常驻脚本版本、本地内核、正式版与 alpha 版，并标注可更新状态 |
| 证书管理 | acme.sh `--standalone` 申请与续期，支持列表、切换激活、删除，自动处理 80 / 443 占用 |
| 订阅生成 | 渲染 `Templates/tun-fakeip.json`，输出订阅文件、二维码与分享链接，nginx 静态托管 |
| 端口跳跃 | Hysteria2 默认 `2080:3000`，自动下发 iptables / nftables DNAT，并生成开机恢复单元 |
| 服务管理 | 启动、停止、重启、查看状态与开机自启 |
| 脚本自更新 | 从本仓库拉取最新脚本，校验通过后替换 |
| 中英双语 | 启动首屏选择语言，全流程界面一致 |

---

## 交互菜单

```text
[1] 安装 / 切换 sing-box 内核（正式版 / alpha）
[2] 卸载 sing-box 内核
[3] 替换 sing-box 内核（保留配置）
[4] 域名证书管理（acme.sh）
[5] 订阅管理（sing-box / 分享链接 / 二维码）
[6] 协议参数配置（端口 / 密码 / UUID）
[7] 服务管理（启动 / 停止 / 重启 / 状态）
[8] 查看版本与更新
[9] 完全卸载 EasySB
[0] 退出脚本
```

对应文件：服务端配置 `/etc/sing-box/config.json`，状态 `/etc/sing-box/easysb.conf`，快捷指令 `/usr/bin/sb`。

---

## 命令参数

| 参数 | 说明 |
| :--- | :--- |
| `--language C\|E` | 预设语言后进入菜单 |
| `--install stable\|alpha` | 安装指定通道内核并部署协议 |
| `--replace stable\|alpha` | 替换内核二进制，保留现有配置 |
| `--uninstall` | 卸载内核 |
| `--config FILE` | 读取 `config.conf` 后无交互安装 |
| `--apply-firewall` | 仅恢复端口跳跃规则，供开机单元调用 |
| `--version` | 显示脚本版本 |
| `--help` | 显示用法 |

---

## 无交互安装

`EasySB/config.conf` 是 KV 配置模板，所有变量均可选，缺省时使用内置默认值：

```bash
bash easysb.sh --config config.conf
```

主要字段：

| 字段 | 说明 |
| :--- | :--- |
| `LANGUAGE` | `C` 简体中文，`E` English |
| `CORE_CHANNEL` | `stable` 或 `alpha` |
| `SERVER_IP` | 公网地址，留空自动探测 |
| `DOMAIN` / `CERT_DOMAIN` | 证书域名，留空使用自签占位证书 |
| `UUID` / `PASSWORD` | 共享凭据，留空自动生成 |
| `IS_ANYTLS` 等五项 | 各协议开关 |
| `PORT_ANYTLS` 等五项 | 各协议端口 |
| `HY2_HOP_RANGE` | Hysteria2 端口跳跃范围 |
| `REALITY_SNI` / `REALITY_PRIVATE` 等 | Reality 偷用域名与密钥，留空自动生成 |
| `SUB_PORT` / `SUB_PATH` | 订阅端口与路径 |

---

## 配置模板

| 目录 | 协议 | 承载层 | 伪装 / 加密 | 关键能力 |
| :--- | :--- | :--- | :--- | :--- |
| `AnyTLS/` | AnyTLS | TCP | 证书 TLS | Padding Scheme 多阶段填充 |
| `Hysteria2/` | Hysteria 2 | QUIC / UDP | TLS（ALPN `h3`） | 端口跳跃、弱网表现优秀 |
| `Tuic/` | TUIC | QUIC / UDP | TLS（ALPN `h3`） | 0-RTT 握手、`native` UDP 转发 |
| `VMess-WebSocket-TLS/` | VMess | WebSocket over TLS | 证书 TLS | 可穿 CDN、Early Data |
| `VLESS-Vision-Reality/` | VLESS + Vision | TCP | REALITY（免证书） | `xtls-rprx-vision`、抗主动探测 |
| `Templates/tun-fakeip.json` | TUN + FakeIP | 系统全局 | — | 规则分流、DNS 拆分、URLTest 自动测速 |

模板中的 UUID、密码、REALITY 私钥与证书路径全部是示例值，部署前必须替换，且服务端与客户端保持一致。可先用内核校验语法：

```bash
sing-box check -c VLESS-Vision-Reality/config_server.json
```

---

## 订阅

订阅基于 `Templates/tun-fakeip.json` 渲染，生成后通过三种方式交付：

1. 本地订阅文件，位于 `/etc/sing-box/subscribe/`。
2. 终端二维码，安装 `qrencode` 后可直接扫码导入。
3. 五类分享链接，覆盖主流客户端。

同时由 nginx 以轻量静态站点形式托管，默认端口 `8443`、路径 `/subscribe`，即 `https://域名:8443/subscribe`。sing-box 直接监听 WebSocket，nginx 只负责静态文件，不做反向代理。

---

## 防火墙与端口跳跃

Hysteria2 端口跳跃使用标准 NAT 规则，对 UDP 端口区间做 DNAT：

```bash
# iptables
iptables -t nat -A PREROUTING -p udp --dport 2080:3000 -j REDIRECT --to-ports 8001

# nftables
nft add table ip nat
nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; }'
nft add rule ip nat prerouting udp dport 2080-3000 redirect to :8001
```

NAT 规则重启即失效，因此脚本会生成开机恢复单元：

- systemd：`easysb-firewall.service`（oneshot，早于 `sing-box.service`）。
- OpenRC：`/etc/init.d/easysb-firewall`。

单元通过 `bash /etc/sing-box/easysb.sh --apply-firewall` 恢复规则，不使用 Hysteria2 端口跳跃时不会创建该单元。

---

## 内核管理

| 环节 | 说明 |
| :--- | :--- |
| 内核来源 | 官方 `SagerNet/sing-box` Releases，脚本直接下载官方资产 |
| 正式版 | 官方 latest release |
| 内测版 | 官方 prerelease |
| 安装 | 按架构下载并校验，写入 `/etc/sing-box/sing-box` |
| 替换 | 只更换二进制，保留 `/etc/sing-box/config.json` |
| 卸载 | 停止服务并移除内核 |
| 脚本发行 | `.github/workflows/easysb-release.yml` 运行构建与测试，以固定 tag `easysb` 发布 `EasySB/dist/easysb.sh` |

---

## 开发者：构建与测试

`EasySB/lib/` 是唯一脚本源，`dist/` 由构建生成，不提交到仓库：

```bash
# 合成发行脚本
bash EasySB/build.sh

# 只做校验，不写文件
bash EasySB/build.sh --check

# 运行全部测试
bash EasySB/tests/run-tests.sh
```

---

## 安全须知

> 仓库中的 UUID、密码、REALITY 私钥、证书路径等全部为示例值，直接用于生产环境等同于无防护。

- 部署前务必重新生成全部密钥与 UUID，并保证服务端与客户端严格一致。
- REALITY 私钥仅存于服务端，切勿提交至任何公开仓库。
- 证书类协议请使用真实域名与有效证书，并将证书文件权限收紧至 `600`。
- 请遵守所在地区的法律法规，仅在合法授权的网络环境中使用本项目。

发现安全问题请按 [SECURITY.md](SECURITY.md) 中的方式私下报告，不要直接开公开 Issue。

---

## 开源协议

本项目遵循 **GPL-3.0**，完整协议文本见 [LICENSE](LICENSE)。

Copyright (C) 2026 MinimaxFlora。分发与二次修改需继续遵循 GPL-3.0。

<div align="center">

**Built for sing-box · 五合一部署，菜单直达。**

GPL-3.0 License © [MinimaxFlora](https://github.com/MinimaxFlora)

</div>
