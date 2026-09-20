# 变更记录

本文件记录 EasySB 项目的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

程序的版本号与构建提交在编译期注入，内核版本独立于程序版本，由官方 `SagerNet/sing-box` Releases 提供。

## [Unreleased]

### 新增

- 订阅支持多客户端：新增 mihomo / Clash Meta 完整配置（`mihomo.yaml`）与 v2rayN 分享链接文档（`v2ray.txt`），nginx 分别以 `/singbox/<uuid>`、`/mihomo/<uuid>`、`/v2ray/<uuid>` 端点提供，旧 `/subscribe` 路径保留。
- 订阅二维码按客户端分别生成导入链接：sing-box 使用 `sing-box://import-remote-profile?url=`，mihomo 使用 `clash://install-config?url=`，v2rayN 使用纯订阅地址。
- 新增 `templates/config/mihomo.yaml` 可读样例，与内嵌模板 `internal/subscribe/mihomo.yaml` 保持同步。
- mihomo 配置对齐完整桌面方案：新增 `external-controller`（`0.0.0.0:9090`）、`secret`、`external-ui`、`external-ui-url`（Zashboard）、`unified-delay`，补全 fake-ip DNS 与 `fake-ip-filter`，策略组改为 `负载均衡` / `自动选择` / `🌍选择代理节点`，规则新增 `GEOIP,LAN,DIRECT` 与 `GEOSITE,CN,DIRECT`。

### 修复

- 修复分享链接生成失败：AnyTLS 与 Hysteria2 URI 在查询串前缺少 `/`，且密码未做百分号编码，导致客户端拒绝导入。

### 变更

- 目录名统一小写：`Templates/` → `templates/`，子目录改为 `anytls`、`hysteria2`、`tuic`、`vmess-websocket-tls`、`vless-vision-reality`、`config`。
- README 主文档改为英文 `README.md`，中文版迁移到 `README_ZH.md`。
- 新增 `docs/` 面向其他 Agent 与协作者的工程文档，并在根目录提供 `AGENTS.md` 索引。

## [v3.0.0] - 2026-09-20

### 新增

- 全量 Go 重写：移除 bash 实现，基于 bubbletea / bubbles / lipgloss 的深色全屏仪表盘 TUI，编译为单一静态二进制，以 `sb` 呼出。
- 目录重组：五个协议样例与订阅模板统一归入 `Templates/`，订阅模板移至 `Templates/Config/tun-fakeip.json`；内核管理改为安装 stable / 安装 alpha / 通道切换 / 更新当前通道。
- 命令参数改为 Go flag：`--language`、`--icons`、`--apply-firewall`、`--render`、`--version`、`--help`。
- 仪表盘改为多卡片布局：新增设备信息、节点信息卡片，按键提示独立成框，菜单项以图标展示。
- 发行流程改为 `.github/workflows/easysb-go-release.yml` 交叉编译多平台二进制，以版本 tag `v3.0.0` 发布，并在 `--version` 中输出构建短哈希以便核验。

### 变更

- 版本号与构建提交由编译期注入（`main.version` / `main.commit`），取代 `EasySB/VERSION` 文件。

### 移除

- 移除 `legacy/EasySB/` bash 源码、`tests/`、`build.sh`、`config.conf` 非交互安装模板与旧 bash 发布工作流。

## [v2.1.0] - 2026-09-20

### 新增

- 主菜单改为七项：内核管理、节点管理、域名管理、订阅管理、服务管理、脚本更新、卸载脚本。
- 节点管理：面板展示域名 / 密码 / UUID / 端口跳跃 / Reality 密钥与 short_id / 端口；一键部署支持五协议多选（回车全选）；参数设置含 Reality 偷用域名预设。
- 内核管理：正式版 / alpha 切换保留配置，「更新内核」只更新当前通道。
- 本地一言库（中英随语言），Banner 改为左侧竖线开框（右侧不闭合）。

### 变更

- 脚本版本改为读取 `EasySB/VERSION`，修复 `/etc/os-release` 的 `VERSION` 覆盖脚本版本的问题。
- 证书申请增加 `--force`，重复申请 / 续期不再因已有域名密钥失败；激活证书后自动应用到节点配置。
- 卸载保留 acme 证书，配置备份到 `/root`。
- 订阅改为手动触发生成。

## [v2.0.0] - 2026-09-20

### 新增

- 脚本整体重写为五合一部署器：AnyTLS、Hysteria2、TUIC v5、VMess + WebSocket + TLS、VLESS + Vision + Reality。
- 内核来源切换为官方 `SagerNet/sing-box` Releases，正式版取 latest release，内测版取 prerelease，支持安装、卸载、替换（保留配置）。
- 菜单顶部常驻版本面板：脚本版本、本地内核、正式版、alpha 版，并标注「可更新 / 已是最新」。
- 证书管理：基于 acme.sh `--standalone` 申请与续期，支持列出证书、切换激活证书、删除证书；申请前检测 80 / 443 占用并可临时停止占用服务。
- 协议参数：五协议共享一个 UUID 与一个密码，均支持回车自动生成；Reality 密钥对自动生成，偷用域名默认 `apple.com`。
- Hysteria2 端口跳跃：默认范围 `2080:3000`，自动下发 iptables / nftables DNAT 规则，并生成开机恢复单元（systemd `easysb-firewall.service` / OpenRC）。
- 订阅管理：基于 `Templates/tun-fakeip.json` 渲染，输出本地订阅文件、终端二维码与五类分享链接；由 nginx 以静态站点形式提供 `https://域名:端口/subscribe`。
- 非交互安装：`EasySB/config.conf` KV 模板配合 `--config`，另支持 `--install`、`--replace`、`--uninstall`、`--apply-firewall` 等参数。
- Alpine / OpenRC 与 Debian / Ubuntu / systemd 双平台支持。

### 变更

- `EasySB/lib/` 模块重组为 12 个文件（`00-header.sh` 到 `11-entry.sh`），职责按内核、证书、协议、防火墙、服务、订阅、菜单划分。
- 语言选择前置为启动首屏，选定后进入主菜单；中英双语全流程一致。
- 订阅模板全部取自本仓库 `Templates/`，远端只依赖本仓库与官方内核仓库。
- 包安装、下载、端口提示统一为非交互与可默认执行的方式。

### 移除

- 不再支持 Argo 隧道、WARP、ShadowTLS、Shadowsocks、Trojan、NaiveProxy 等旧协议与旧菜单项。
- 不再自行编译内核，内核统一取自官方 Releases。

## [v1.3.25] - 2026-09-18

### 新增

- `Templates/config-rule.yaml`：Clash / Mihomo 订阅模板，内嵌节点与分流规则，不依赖 `proxy-providers`。
- `EasySB/lib/` 模块化源码，`EasySB/build.sh` 按编号合成单文件发行版。
- `EasySB/tests/` 测试套件，覆盖构建、文案、静态断言与 lint；`.github/workflows/easysb-release.yml` 在 CI 中执行。

### 变更

- 订阅模板来源改为本仓库 `Templates/`。
  - `Templates/config.yaml`：Clash / Mihomo 订阅，使用 `proxy-providers`。
  - `Templates/config-rule.yaml`：Clash / Mihomo 订阅，自包含形式。
  - `Templates/config.json`：sing-box SFM / SFA / SFI 订阅。
- 内核版本解析只接受 `x.y.z` 正式版标签，过滤预发布标签与脚本自身的 `easysb` 发布标签。
