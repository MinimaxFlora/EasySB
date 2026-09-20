# EasySB 功能对照表

上游项目：`https://github.com/fscarmen/sing-box`（参考实现）
本项目脚本：`EasySB/lib/` 模块合成 `EasySB/dist/easysb.sh`

对照原则：功能与交互选项与上游一致，仅调整项目归属信息与远端资源地址。

## 协议

| 代号 | 协议 | 上游 | 本项目 |
| :--- | :--- | :--- | :--- |
| `b` | VLESS + Reality | 支持 | 支持 |
| `c` | Hysteria2 | 支持 | 支持 |
| `d` | Tuic V5 | 支持 | 支持 |
| `e` | ShadowTLS | 支持 | 支持 |
| `f` | Shadowsocks | 支持 | 支持 |
| `g` | Trojan | 支持 | 支持 |
| `h` | VMess + WebSocket | 支持 | 支持 |
| `i` | VLESS + WebSocket + TLS | 支持 | 支持 |
| `j` | VLESS + H2 + Reality | 支持 | 支持 |
| `k` | VLESS + gRPC + Reality | 支持 | 支持 |
| `l` | AnyTLS | 支持 | 支持 |
| `m` | NaiveProxy | 支持 | 支持 |

协议清单与标签定义在 `lib/00-header.sh` 的 `PROTOCOL_LIST`、`NODE_TAG`；
服务端配置渲染在 `lib/12-baseconf.sh`；协议增删在 `lib/15-protocols.sh`。

## 命令行参数

| 参数 | 功能 | 实现模块 |
| :--- | :--- | :--- |
| `-c` / `-e` | 中文 / 英文 | `lib/03-detect.sh`、`lib/18-entry.sh` |
| `-l` / `-k` | 快速安装（中文 / 英文） | `lib/17-menu.sh`、`lib/18-entry.sh` |
| `-u` | 卸载 | `lib/16-maintenance.sh` |
| `-n` | 显示节点信息 | `lib/14-export.sh` |
| `-d` | 修改配置 | `lib/05-config.sh` |
| `-s` | 停止 / 开启 Sing-box 服务 | `lib/17-menu.sh`、`lib/09-system.sh` |
| `-a` | 停止 / 开启 Argo 服务 | `lib/17-menu.sh`、`lib/06-argo.sh` |
| `-t` | 更换 Argo 隧道 | `lib/06-argo.sh` |
| `-v` | 同步 sing-box 至最新版本 | `lib/16-maintenance.sh` |
| `-b` | 升级内核、安装 BBR、DD 脚本 | `lib/17-menu.sh` |
| `-r` | 添加 / 删除协议 | `lib/15-protocols.sh` |

## 无交互安装参数

| 参数 | 说明 | 实现模块 |
| :--- | :--- | :--- |
| `--LANGUAGE` | 语言 | `lib/18-entry.sh` |
| `--CHOOSE_PROTOCOLS` | 协议组合，`a` 为全部 | `lib/18-entry.sh` |
| `--START_PORT` | 起始端口 | `lib/10-ports.sh` |
| `--PORT_NGINX` | Nginx 端口 | `lib/10-ports.sh` |
| `--SERVER_IP` | 服务器地址 | `lib/18-entry.sh` |
| `--VMESS_HOST_DOMAIN` | VMess 域名 | `lib/12-baseconf.sh` |
| `--VLESS_HOST_DOMAIN` | VLESS 域名 | `lib/12-baseconf.sh` |
| `--CDN` | 优选域名 | `lib/04-input.sh` |
| `--UUID_CONFIRM` | UUID | `lib/04-input.sh` |
| `--NODE_NAME_CONFIRM` | 节点名 | `lib/04-input.sh` |
| `--SUBSCRIBE` | 订阅开关 | `lib/14-export.sh` |
| `--ARGO` | Argo 开关 | `lib/06-argo.sh` |
| `--ARGO_DOMAIN` / `--ARGO_AUTH` | Argo 域名与认证 | `lib/06-argo.sh` |
| `--HY2_PORT_HOPPING_RANGE` | 端口跳跃范围 | `lib/10-ports.sh` |
| `--HY2_REALM` / `--HY2_WARP` | Hysteria2 Realm 与 WARP 打洞 | `lib/08-warp.sh` |
| `--REALITY_PRIVATE` | Reality 私钥 | `lib/04-input.sh` |
| `--BIND_INTERFACE` | 指定网络出口 | `lib/05-config.sh` |

配置模板见 `EasySB/config.conf`。

## 安装后菜单

| 选项 | 功能 | 实现模块 |
| :--- | :--- | :--- |
| `1` | 查看节点信息 | `lib/14-export.sh` |
| `2` | 开启 / 停止 Sing-box 服务 | `lib/09-system.sh` |
| `3` | 开启 / 停止 Argo 服务 | `lib/06-argo.sh` |
| `4` | 更换 Argo 隧道 | `lib/06-argo.sh` |
| `5` | 修改节点配置 | `lib/05-config.sh` |
| `6` | 同步 sing-box 至最新版本 | `lib/16-maintenance.sh` |
| `7` | 升级内核 / BBR / DD | 第三方脚本 |
| `8` | 添加 / 删除协议 | `lib/15-protocols.sh` |
| `9` | 卸载 | `lib/16-maintenance.sh` |
| `10` | 安装 ArgoX 脚本 | 第三方脚本 |
| `11` | 安装 sba 脚本 | 第三方脚本 |
| `12` | Hysteria2 端口跳跃脚本 | 第三方脚本 |

## 能力清单

| 能力 | 实现模块 |
| :--- | :--- |
| CDN 反代自动探测与切换 | `lib/03-detect.sh` |
| Argo 隧道（Token / JSON / API / 临时隧道） | `lib/06-argo.sh` |
| Nginx 伪装站点与订阅站点 | `lib/11-firewall.sh`、`lib/14-export.sh` |
| 节点导出、分享链接、二维码 | `lib/14-export.sh` |
| 多客户端订阅（Base64 / 链接 / sing-box / Mihomo） | `lib/14-export.sh` |
| WARP 账户注册与更换 | `lib/08-warp.sh` |
| Hysteria2 Realm 与 WARP 打洞 | `lib/08-warp.sh` |
| 端口跳跃与 NAT 规则 | `lib/10-ports.sh` |
| 防火墙规则（UFW / firewalld / iptables） | `lib/11-firewall.sh` |
| 自定义路由规则管理 | `lib/07-route.sh` |
| 服务管理（systemd / OpenRC） | `lib/09-system.sh` |
| 运行状态、流量统计与内存占用 | `lib/09-system.sh`、`lib/14-export.sh` |
| 内核与脚本自更新 | `lib/16-maintenance.sh` |
| 中英文双语界面 | `lib/01-i18n.sh` |

## 本项目的差异

| 项目 | 上游 | 本项目 |
| :--- | :--- | :--- |
| 脚本来源 | `fscarmen/sing-box` | `MinimaxFlora/EasySB` Releases |
| 内核来源 | `SagerNet/sing-box` Releases | 本仓库 Releases（由 `build-release.yml` 编译） |
| 强制版本文件 | 上游仓库 | `EasySB/force_version` |
| 运行次数统计 | 上游统计接口 | 默认关闭，可由 `STATISTICS_API` 接入自建服务 |
| 源码组织 | 单文件 | `EasySB/lib/` 19 个模块 + `build.sh` 合成 |
| 校验方式 | 无 | `EasySB/tests/` 五类测试 + CI |
| 协议与选项 | 12 协议 | 保持一致 |
