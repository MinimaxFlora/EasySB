# 变更记录

本文件记录 EasySB 项目的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

程序的版本号与构建提交在编译期注入，内核版本独立于程序版本，由官方 `SagerNet/sing-box` Releases 提供。

## [4.0.0] - 2026-09-24

### 重大变更

- 账号化：移除节点级 `UUID` 与 `密码`，改为 `/etc/sing-box/easysb-users.json` 中的多账号模型。每个账号拥有各协议独立凭据、流量限额、有效期、可用协议与启用开关；停用、过期、超额账号会自动从内核配置中移除，恢复后自动加回。客户端需要按账号重新导入订阅。
- 订阅改为内置服务：删除 `internal/nginx` 与静态订阅目录 `/etc/sing-box/subscribe/`，由 `easysb --serve`（`easysb.service`）在 `SUB_SERVE_PORT`（默认 `8443`）上提供唯一端点 `/sub/<令牌>`，按 User-Agent 返回 sing-box JSON、mihomo YAML 或 Base64 分享链接文档。旧端点 `/subscribe`、`/singbox/<uuid>`、`/mihomo/<uuid>`、`/v2ray/<uuid>` 不再提供。
- 流量统计与自动处置：订阅服务每 `SUB_SYNC_SECONDS`（默认 `300`）秒读取内核 `StatsService` 计数并累加到账号，跨过限额或到期时重启内核生效；响应头 `Subscription-Userinfo` 向客户端上报已用流量、限额与到期时间。
- 状态键变更：新增 `SUB_SERVE_PORT`、`SUB_SYNC_SECONDS`，移除 `SUB_PORT`、`SUB_PATH`；菜单新增「账号与流量」，「订阅管理」改为订阅端点与服务管理。
- 订阅地址的 TLS 判定统一走 `cert.Usable`：只有存在真实证书时才以 HTTPS 提供服务并输出 `https://` 地址，否则明文 HTTP 并在面板提示，避免客户端拿到与监听协议不符的地址。

### 新增

- 设备信息面板扩充：本机 IPv4 与 IPv6 分列显示，新增运行时间、CPU 型号与核心数、系统负载、内存与磁盘占用。
- 任务/二维码页新增复制与鼠标控制：按 `C` 通过 OSC52 将整段日志复制到系统剪贴板，按 `M` 释放鼠标以便拖拽选择文本。
- 新增 `--theme auto|dark|light`（环境变量 `EASYSB_THEME`）：启动时自动探测终端背景色，亮色背景自动切换为浅色配色，也可手动强制指定，避免在白色终端下界面几乎不可读。
- 订阅支持多客户端：mihomo / Clash Meta 完整配置（`mihomo.yaml`）与 v2rayN 分享链接文档由同一个 `/sub/<令牌>` 端点按 User-Agent 提供，可用 `?client=` 强制指定格式。
- 适配 OpenWrt 客户端：`passwall`、`passwall2`、`homeproxy` 使用 Base64 分享链接文档；`luci-app-nikki` 使用 mihomo 内核，订阅需要含顶层 `proxies`，因此返回 mihomo YAML 配置。
- 订阅二维码按客户端分别生成导入链接：sing-box 使用 `sing-box://import-remote-profile?url=`，mihomo 与 v2rayN 使用纯订阅地址（Clash 系客户端的扫码导入会把二维码内容直接当作订阅 URL 抓取，`clash://install-config?url=` 仅适用于系统级深链点击）。
- 新增 `templates/config/mihomo.yaml` 可读样例，与内嵌模板 `internal/subscribe/mihomo.yaml` 保持同步。
- mihomo 配置对齐完整桌面方案：新增 `external-controller`（`0.0.0.0:9090`）、`secret`、`external-ui`、`external-ui-url`（Zashboard）、`unified-delay`，补全 fake-ip DNS 与 `fake-ip-filter`，策略组改为 `负载均衡` / `自动选择` / `🌍选择代理节点`，规则新增 `GEOIP,LAN,DIRECT` 与 `GEOSITE,CN,DIRECT`。

### 修复

- 修复生成的 sing-box 订阅 JSON 被编码为字母序的问题：现在保留模板中的顶层分区顺序与节点内参数顺序，与 `templates/config/tun-fakeip.json` 可读样例一致。
- 修复任务页启用鼠标捕获后无法用鼠标选中并复制订阅链接的问题：现可用 `C` 直接复制，或按 `M` 释放鼠标后原生选择。
- 修复公网 IP 探测在双栈主机上返回 IPv6 的问题：探测端点改为优先使用仅 IPv4 的接口。
- 修复 OpenWrt 客户端订阅后节点丢失密码：homeproxy 会丢弃含百分号转义的 userinfo，标准 Base64 密码（`+` `/` `=`）会静默丢失密码。生成密码现改为纯字母数字（22 字符），v2rayN、passwall、passwall2 与 homeproxy 均可正常读取。
- 修复部分解析器读取 VMess 节点加密方式为空的问题：分享链接在 `scy` 之外同时写出 `security`，兼容只读 `security` 的解析器。
- 修复 homeproxy 报「请输入有效 uuid」：VLESS 分享链接保持带连字符的标准 UUID，不再输出 32 位紧凑形式（homeproxy 会用 LuCI 的 `uuid` 校验节点）。
- 订阅界面按插件列出兼容客户端：mihomo YAML 面向 mihomo / Clash Meta / luci-app-nikki，Base64 文档面向 v2rayN / passwall / passwall2 / homeproxy，并分别说明两种格式。
- 修复主菜单选中行光标长度随行内描述长短变化的问题：选中条现在统一填充到面板内宽。
- 修复分享链接生成失败：AnyTLS 与 Hysteria2 URI 在查询串前缺少 `/`，且密码未做百分号编码，导致客户端拒绝导入。
- 修复 mihomo 二维码无法被 FlClash 等 Clash 系客户端识别：二维码改为纯订阅地址，不再包装 `clash://install-config?url=`。
- 修复任务/二维码页无法用鼠标滚轮滚动：仅在任务页开启鼠标上报，并将滚轮与 ↑/↓ 的滚动步长统一为 3 行，同时支持 PgUp/PgDn 翻页。
- 修复主菜单选中态只高亮标签、描述仍为暗色的问题：选中行现在整行高亮（含描述），子菜单与返回行同样处理。
- 修复二级菜单中按 `q` 只返回上一级的问题：`q` 现在任意层级都直接退出，返回上一级使用 `Esc` / 左方向键 / 返回行。

### 变更

- 设备面板用「交换空间」替换「公网 IP」，CPU 仅显示核心数，系统仅显示发行版名称，面板更精简。
- 运行概况首行改为「服务 / 节点」，版本与内核下移到第二行，常用状态更靠前。
- 二级菜单每项后补上功能概述，与主菜单的展示风格保持一致。
- 任务页按键提示去掉 `PgUp/PgDn 翻页` 文案，翻页快捷键仍可用。
- 生成密码由标准 Base64（24 字符，可能含 `+` `/` `=`）改为 URL-safe Base64，再改为纯字母数字（22 字符），兼容 v2rayN、passwall、passwall2 与 homeproxy。旧实例的密码若含 `+` `/` `=` `-` `_`，部分客户端仍会丢失密码，需重新生成密码或重新部署后生效。
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
