<div align="center">

# EasySB

**sing-box 一键部署脚本 · 覆盖主流抗封锁协议 · 交互选项与原项目完全对齐**

[![sing-box](https://img.shields.io/badge/sing--box-%E2%89%A5%201.12.0-3B82F6?style=for-the-badge&logo=go&logoColor=white)](https://sing-box.sagernet.org/)
![License](https://img.shields.io/badge/License-GPL--3.0-22C55E?style=for-the-badge)

</div>

---

## 项目简介

EasySB 是 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 的重构版本，功能、菜单与交互选项与原项目完全一致，只是重新梳理了远端资源地址、常量定义与代码分段，并把内核与脚本发行版收敛到本仓库。

- 项目地址：https://github.com/MinimaxFlora/EasySB
- 参考项目：https://github.com/fscarmen/sing-box
- 脚本源码：`EasySB/lib/*.sh`（按功能拆分模块）
- 构建脚本：`EasySB/build.sh`（把模块合成单文件）
- 测试套件：`EasySB/tests/`（构建、文案、静态、lint 四类校验）
- 发行脚本：`EasySB/dist/easysb.sh`（由 Actions 生成，仓库不提交 `dist`，仅发布到 Releases）

## 源码结构

模块化只发生在源码层面：运行期只下载一个文件，所以仍由 `build.sh` 合成单文件发行版。

```text
EasySB/
├── lib/                  # 源码模块，编号顺序即合成顺序
│   ├── 00-header.sh          # 项目常量、脚本版本、全局默认值
│   ├── 01-i18n.sh            # 中英文文案表
│   ├── 02-utils.sh           # 彩色输出、read 封装、文案取值
│   ├── 03-detect.sh          # CDN 探测、系统与网络信息
│   ├── 04-input.sh           # 交互输入与校验
│   ├── 05-config.sh          # 配置生成与在线修改
│   ├── 06-argo.sh            # Argo 隧道
│   ├── 07-route.sh           # 自定义路由规则
│   ├── 08-warp.sh            # WARP 账户与 Hysteria2 Realm
│   ├── 09-system.sh          # 系统检测、服务管理、安装状态
│   ├── 10-ports.sh           # 端口编排与端口跳跃
│   ├── 11-firewall.sh        # 依赖与防火墙
│   ├── 12-baseconf.sh        # 服务端基础配置生成
│   ├── 13-install.sh         # 安装主流程
│   ├── 14-export.sh          # 节点导出、订阅、二维码
│   ├── 15-protocols.sh       # 协议增删
│   ├── 16-maintenance.sh     # 版本维护与卸载
│   ├── 17-menu.sh            # 交互菜单
│   └── 18-entry.sh           # 脚本入口（必须最后）
├── tests/                # 测试套件
├── Templates/            # 客户端订阅模板
│   ├── config.yaml       # Clash / Mihomo（proxy-providers 形式）
│   ├── config-rule.yaml  # Clash / Mihomo（内嵌节点与规则）
│   ├── config.json       # sing-box SFM / SFA / SFI
│   └── tun-fakeip.json   # TUN fake-ip 配置模板
├── build.sh              # 模块合成 + 语法校验
├── config.conf           # 无交互安装配置模板
├── force_version         # 内核强制版本文件
└── dist/                 # 构建产物，git 忽略
```

```bash
# 合成发行脚本 / Build the release script
bash EasySB/build.sh

# 只做校验，不写文件 / Check only
bash EasySB/build.sh --check

# 运行全部测试 / Run all tests
bash EasySB/tests/run-tests.sh
```

## 快速开始

```bash
# 首次安装 / First install
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh)

# 安装后再次运行 / Run again after install
sb
```

## 支持的协议

`a` 为全部协议，也可用 `b`-`m` 自由组合：

| 代号 | 协议 |
| :--- | :--- |
| `b` | VLESS + Reality |
| `c` | Hysteria2 |
| `d` | Tuic V5 |
| `e` | ShadowTLS |
| `f` | Shadowsocks |
| `g` | Trojan |
| `h` | VMess + WebSocket |
| `i` | VLESS + WebSocket + TLS |
| `j` | VLESS + H2 + Reality |
| `k` | VLESS + gRPC + Reality |
| `l` | AnyTLS |
| `m` | NaiveProxy |

## 命令参数

| 参数 | 说明 |
| :--- | :--- |
| `-c` / `-e` | 中文 / English |
| `-l` / `-k` | 快速安装（中文 / English），自动补全全部参数 |
| `-u` | 卸载 |
| `-n` | 显示节点信息 |
| `-d` | 修改配置 |
| `-s` | 停止 / 开启 Sing-box 服务 |
| `-a` | 停止 / 开启 Argo Tunnel 服务 |
| `-t` | 更换 Argo 隧道 |
| `-v` | 同步 sing-box 至最新版本 |
| `-b` | 升级内核、安装 BBR、DD 脚本 |
| `-r` | 添加 / 删除协议 |

## 无交互安装

`EasySB/config.conf` 为 KV 配置模板，改完直接执行：

```bash
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) -f config.conf
```

也支持 KV 传参，例如：

```bash
bash <(curl -fsSL https://github.com/MinimaxFlora/EasySB/releases/download/easysb/easysb.sh) \
  --LANGUAGE c \
  --CHOOSE_PROTOCOLS a \
  --START_PORT 8881 \
  --SERVER_IP 123.123.123.123 \
  --CDN skk.moe \
  --UUID_CONFIRM 20f7fca4-86e5-4ddf-9eed-24142073d197 \
  --SUBSCRIBE=true \
  --ARGO=true \
  --NODE_NAME_CONFIRM bucket
```

可用的 KV 参数与 `config.conf` 一一对应。

## 内核与发行流程

| 环节 | 位置 | 说明 |
| :--- | :--- | :--- |
| 内核编译 | `.github/workflows/build-release.yml` | 编译 sing-box 多架构二进制并发布到 Releases |
| 脚本源码 | `EasySB/lib/*.sh` | 唯一脚本源，带完整中文注释 |
| 脚本发行 | `.github/workflows/easysb-release.yml` | 运行 `build.sh` 与测试套件，通过后以 `easysb` 标签发布 `dist/easysb.sh` |

脚本内的 sing-box 下载地址、强制版本文件、脚本自身地址均指向本仓库的 Releases。

## 开源协议

本项目基于 [fscarmen/sing-box](https://github.com/fscarmen/sing-box) 重构，遵循 **GPL-3.0** 协议，完整协议文本见 `EasySB/LICENSE`。

原始项目版权归 fscarmen 所有，重构部分版权归 MinimaxFlora 所有。分发与二次修改需继续遵循 GPL-3.0。
