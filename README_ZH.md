<div align="center">

<img src="assets/easysb-banner-zh.webp" alt="EasySB" width="950">

**sing-box 五合一部署脚本 · 配置模板开箱可读 · 内核版本一键管理**

[![sing-box](https://img.shields.io/badge/sing--box-%E2%89%A5%201.12.0-3B82F6?style=for-the-badge&logo=go&logoColor=white)](https://sing-box.sagernet.org/)
![License](https://img.shields.io/badge/License-GPL--3.0-22C55E?style=for-the-badge)
[![Protocols](https://img.shields.io/badge/Protocols-5-8B5CF6?style=for-the-badge)](#easysb-支持协议)
[![Platform](https://img.shields.io/badge/Platform-Linux-F59E0B?style=for-the-badge)](#快速开始)

**简体中文** | [English](README.md)

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

- **Go 版（当前主实现）**：根目录 Go module，基于 bubbletea / bubbles / lipgloss 的深色仪表盘 TUI，编译为单一静态二进制并以 `sb` 呼出。
- **模板**：`templates/` 存放五个协议的 JSONC 配置样例与订阅模板，既可以只用模板，也可以交给程序自动落地。
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
├── main.go                       # Go 入口（TUI 主程序）
├── install.sh                    # 一键安装脚本（依赖 / 二进制 / Nerd Font）
├── VERSION                       # 发布 tag 的唯一来源
├── AGENTS.md                     # 面向 AI Agent 与协作者的说明
├── go.mod                        # Go module 定义
├── internal/                     # Go 实现，包职责见 docs/architecture.md
├── templates/                    # 订阅与协议配置模板
│   ├── config/
│   │   ├── tun-fakeip.json       # sing-box TUN + FakeIP 订阅模板
│   │   └── mihomo.yaml           # mihomo / Clash Meta 配置（可读镜像）
│   ├── anytls/                   # AnyTLS 协议客户端 / 服务端样例
│   ├── hysteria2/                # Hysteria2 协议客户端 / 服务端样例
│   ├── tuic/                     # TUIC 协议客户端 / 服务端样例
│   ├── vmess-websocket-tls/      # VMess + WebSocket + TLS 样例
│   └── vless-vision-reality/     # VLESS + Vision + Reality 样例
├── assets/                       # README 横幅
├── docs/                         # 面向 Agent 与协作者的工程文档
└── .github/                      # CI 工作流与社区健康文件
```

`templates/` 下的协议样例为可直接阅读的 JSONC，去注释后即可作为 sing-box 服务端 / 客户端配置使用。

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

Go 版（当前主实现）一键安装：脚本会检测系统与架构，补全运行依赖，优先下载预编译二进制（回退源码构建），并在本地图形环境安装 Nerd Font：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/install.sh)
```

安装完成后以快捷指令 `sb` 启动深色仪表盘。

再次运行只需输入快捷指令：

```bash
sb
```

预设语言后进入菜单：

```bash
# 简体中文
sb --language C

# English
sb --language E
```

支持 Debian / Ubuntu（systemd）与 Alpine（OpenRC）；需要 root 权限运行。

---

## EasySB 能力

| 能力 | 说明 |
| :--- | :--- |
| 五协议部署 | 五协议共享一个 UUID 与一个密码，安装时统一生成，端口逐一编排 |
| 内核版本管理 | 正式版 stable 与 alpha 内测版随时安装、替换、卸载，替换保留现有配置 |
| 版本面板 | 菜单顶部常驻脚本版本、本地内核、正式版与 alpha 版，并标注可更新状态 |
| 设备面板 | 本机 IPv4/IPv6、交换空间、运行时间、CPU 核心数与负载、内存、磁盘、主机、内核、系统与时区 |
| 复制与鼠标 | 任务页按 `C` 将日志复制到系统剪贴板（OSC52），按 `M` 释放鼠标以拖拽选择文本 |
| 证书管理 | acme.sh `--standalone` 申请与续期，支持列表、切换激活、删除，自动处理 80 / 443 占用 |
| 订阅生成 | 渲染 `templates/config/tun-fakeip.json`（sing-box）与 `templates/config/mihomo.yaml`（mihomo），输出订阅文件、二维码与分享链接，nginx 静态托管 |
| 端口跳跃 | Hysteria2 默认 `2080:3000`，自动下发 iptables / nftables DNAT，并生成开机恢复单元 |
| 服务管理 | 启动、停止、重启、查看状态与开机自启 |
| 脚本自更新 | 从本仓库拉取最新脚本，校验通过后替换 |
| 中英双语 | 启动首屏选择语言，全流程界面一致 |

---

## 交互菜单

```text
主菜单
├── 内核管理     安装正式版 / 测试版、切换内核、更新当前通道
├── 节点管理     一键部署、启用协议、参数设置（UUID / 密码 / 端口跳跃 / 端口 / 偷用域名 / Reality 密钥）
├── 域名管理     申请 / 续期、查看、切换激活、删除证书
├── 订阅管理     重新生成、订阅链接、订阅二维码、各协议分享链接
├── 服务管理     启动 / 停止 / 重启 / 状态 / 开机自启、端口跳跃规则
├── 版本更新     拉取最新 EasySB 发行版
└── 卸载脚本     完整卸载 EasySB
```

对应文件：服务端配置 `/etc/sing-box/config.json`，状态 `/etc/sing-box/easysb.conf`，快捷指令 `/usr/local/bin/sb`。

---

## 命令参数

| 参数 | 说明 |
| :--- | :--- |
| `--language C\|E` | 预设界面语言后进入菜单 |
| `--icons on\|off` | 覆盖 Nerd Font 图标检测结果 |
| `--theme auto\|dark\|light` | 覆盖终端背景检测（默认 `auto`，亮色终端自动换用浅色配色） |
| `--apply-firewall` | 仅恢复端口跳跃规则，供开机单元调用 |
| `--render --width N --height N` | 渲染一次仪表盘后退出（调试用） |
| `--version` | 显示版本与构建短哈希 |
| `--help` | 显示用法 |

---

## 配置模板

| 目录 | 协议 | 承载层 | 伪装 / 加密 | 关键能力 |
| :--- | :--- | :--- | :--- | :--- |
| `templates/anytls/` | AnyTLS | TCP | 证书 TLS | Padding Scheme 多阶段填充 |
| `templates/hysteria2/` | Hysteria 2 | QUIC / UDP | TLS（ALPN `h3`） | 端口跳跃、弱网表现优秀 |
| `templates/tuic/` | TUIC | QUIC / UDP | TLS（ALPN `h3`） | 0-RTT 握手、`native` UDP 转发 |
| `templates/vmess-websocket-tls/` | VMess | WebSocket over TLS | 证书 TLS | 可穿 CDN、Early Data |
| `templates/vless-vision-reality/` | VLESS + Vision | TCP | REALITY（免证书） | `xtls-rprx-vision`、抗主动探测 |
| `templates/config/tun-fakeip.json` | TUN + FakeIP | 系统全局 | — | 规则分流、DNS 拆分、URLTest 自动测速 |
| `templates/config/mihomo.yaml` | mihomo / Clash Meta | 系统全局 | — | 完整客户端配置：节点、策略组、DNS、规则 |

模板中的 UUID、密码、REALITY 私钥与证书路径全部是示例值，部署前必须替换，且服务端与客户端保持一致。可先用内核校验语法：

```bash
sing-box check -c templates/vless-vision-reality/config_server.json
```

---

## 订阅

订阅分别基于 `templates/config/tun-fakeip.json`（sing-box）与 `templates/config/mihomo.yaml`（mihomo / Clash Meta）渲染，生成后通过三种方式交付：

1. 本地订阅文件，位于 `/etc/sing-box/subscribe/`。
2. 终端二维码，安装 `qrencode` 后可直接扫码导入。
3. 五类分享链接，覆盖主流客户端。

同时由 nginx 以轻量静态站点形式托管，默认端口 `8443`。旧路径 `/subscribe` 提供 sing-box JSON 配置，各客户端另有带 UUID token 的独立端点：

| 客户端 | 订阅端点 | 内容 |
| :--- | :--- | :--- |
| sing-box（SFM / SFA / SFI） | `/singbox/<uuid>` | JSON 配置 |
| mihomo / Clash Meta / luci-app-nikki | `/mihomo/<uuid>` | 完整 YAML 配置 |
| v2rayN / passwall / passwall2 / homeproxy | `/v2ray/<uuid>` | Base64 分享链接文档 |

`/v2ray/<uuid>` 文档即通用格式。v2rayN 可直接导入，OpenWrt 上的 `passwall`、`passwall2`、`homeproxy` 也会先对同一份文档做 Base64 解码再逐行解析，一个端点即可覆盖。`luci-app-nikki` 使用 mihomo 内核，订阅必须含顶层 `proxies`，因此走 `/mihomo/<uuid>` 这份 YAML 配置。

所有分享链接都保留标准的带连字符 UUID。`homeproxy` 会用 LuCI 的 `uuid` 校验节点，32 位无连字符形式会被判为无效，因此不能输出紧凑形式。

UUID 即访问 token，请将订阅地址视为机密。sing-box 二维码会包装为 `sing-box://import-remote-profile?url=...` 以便扫码导入；mihomo 与 v2rayN 二维码使用纯订阅地址，因为 Clash 系客户端扫码后会把内容直接当作订阅 URL 抓取（`clash://install-config?url=...` 仅在浏览器点击深链时有效）。sing-box 直接监听 WebSocket，nginx 只负责静态文件，不做反向代理。

mihomo 配置对齐完整桌面方案：`external-controller` 监听 `0.0.0.0:9090` 并带 `secret`，通过 `external-ui-url` 加载 Zashboard 面板，DNS 使用 fake-ip 与 `fake-ip-filter`，策略组包含 `load-balance` / `url-test` / `select`，分流规则包含 `GEOSITE` / `GEOIP`。请仅在局域网内可信设备上导入。

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

单元通过 `easysb --apply-firewall` 恢复规则，不使用 Hysteria2 端口跳跃时不会创建该单元。

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
| 程序发行 | `.github/workflows/easysb-go-release.yml` 交叉编译各平台二进制，以 tag `v<VERSION>`（当前 `v3.0.0`）发布 |

---

## 开发者：构建与测试

Go 版（主实现，需要 Go 1.27.1，`go.mod` 已声明 `go 1.27.1`，启用 `GOTOOLCHAIN=auto` 时会自动获取该工具链）。`internal/tui/` 是 TUI 主界面与交互逻辑，`internal/` 下其余包各自负责内核、证书、服务、订阅、防火墙等模块，包职责见 `docs/architecture.md`：

```bash
# 编译二进制
go build -o easysb .

# 运行测试
go test ./...

# 无交互渲染一次仪表盘（用于预览 / 截图 / 排错）
./easysb --render --width 100 --height 34

# 切换语言、图标模式与配色
./easysb --language E --icons off --theme dark
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
