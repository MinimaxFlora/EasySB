# 需求 → 实现 映射表（FEATURE MAP）

本表是"没有漏掉任何需求"的证明。每一项需求对应到具体模块、菜单入口和测试用例。
（对应 `linux-vps-script-tooling` 技能的流程第 1 步：先写功能映射，再写代码。）

## 一、用户原始需求

| # | 需求 | 实现位置 | 菜单入口 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 一键脚本，用户在 VPS 上部署 AnyTLS / Hysteria2 / VLESS-Vision-REALITY / VMess-WebSocket-TLS / TUIC | `lib/40-render.sh`（服务端 inbound + 客户端 outbound）、`lib/90-ui.sh::ui_deploy_wizard` | 主菜单 `1`；`easysb.sh install` | `tests/cases/render.sh` |
| 2 | 可选自己需要的节点（多选，默认 all 五个） | `lib/90-ui.sh::ui_prompt_protocols`（`ask_multi`，五项默认 `on`；输入 `all` / `1,3` / `none`） | 向导第二步 | `tests/cases/core.sh`（ask_multi 解析）+ `render.sh` |
| 3 | 强制域名部署（五个协议都能用域名，更安全） | `lib/90-ui.sh::ui_prompt_domain`（必填、格式校验、解析指向本机校验、失败要二次确认） | 向导第一步 | `tests/cases/core.sh`（validate_domain） |
| 4 | 加入 ACME 证书申请 | `lib/30-certs.sh`（acme.sh：standalone / webroot / DNS API 三种方式） | 证书管理 `1`；向导第六步 | `tests/cases/certs.sh` |
| 5 | 证书管理：列出已申请证书、申请、应用、删除 | `lib/30-certs.sh` + `lib/90-ui.sh::ui_cert_menu`（1 申请 / 2 列表 / 3 应用 / 4 删除 / 5 续期 / 6 详情 / 7 续期后自动重载） | 主菜单 `4` | `tests/cases/certs.sh` |
| 6 | 用户可选择把哪张证书"应用"给 sing-box | `cert_use <domain>` → 写 `state.cert.*` → `apply_change`（渲染→`sing-box check`→重启→失败回滚） | 证书管理 `3` | `tests/cases/certs.sh` + `state.sh`（回滚） |
| 7 | 安装 sing-box，下载地址用本仓库 releases | `lib/50-singbox.sh::sb_install`（`https://github.com/MinimaxFlora/EasySB/releases/download/v<ver>/sing-box-<ver>-<arch>.tar.gz`） | 向导第四步；更新 `3` | `tests/real-parser.sh`（真实二进制）+ 沙箱 |
| 8 | 显示当前版本与项目最新版本 | `sb_version` / `sb_latest_version` / `script_latest_version`，在 `ui_update_menu` 与状态页展示 | 主菜单 `7`、`2` | `tests/cases/state.sh`、`real-parser.sh` |
| 9 | 支持更新 sing-box 内核 | `sb_update`（版本比较→下载→sha256 校验→备份→原子替换→配置校验→重启） | 更新 `1` | 沙箱 + 真机验收 |
| 10 | 支持更新脚本自身 | `script_update`（拉取 `dist/easysb.sh`→`bash -n`→备份→原子替换） | 更新 `2` | 沙箱 + 真机验收 |
| 11 | 脚本放在项目根目录的 `EasySB/` 下 | `EasySB/{easysb.sh,lib/,build.sh,dist/,tests/,docs/,tools/,VERSION}` | — | `tests/audit.sh` |
| 12 | 一个"部署伪装站点"的选项 | `lib/70-web.sh`（nginx：博客 / 企业官网 / 空白页 / 自定义 HTML / 反向代理到真实站点，同时充当 ACME webroot） | 向导第三步；主菜单 `5` | `tests/cases/web.sh` |
| 13 | 节点链接的生成与输出 | `render_links` / `client_link_for`（vless / vmess / hysteria2 / tuic / anytls 五种 URI，含 host/SNI/pbk/sid/端口跳跃等全部参数）+ `ui_show_links`、单节点二维码、`$ESB_CLIENT_DIR/links.txt` | 主菜单 `6` → `1`/`2` | `tests/cases/subscribe.sh`、`render.sh` |
| 14 | 订阅链接（一键导入全部节点） | `lib/80-subscribe.sh`：Base64 通用订阅（v2rayN/Shadowrocket/NekoBox）、纯文本链接、sing-box JSON、Mihomo/Clash YAML；订阅站点复用伪装站点（HTTPS）或独立 nginx 站点；token 路径鉴权、可重置、可二维码 | 主菜单 `6` → `3`；向导第八步 | `tests/cases/subscribe.sh` + `tests/real-parser.sh`（订阅里的 sing-box JSON 也要能过真实内核校验） |

## 二、为让上面这些真正可用而必须补上的

| 能力 | 实现 | 理由 |
| --- | --- | --- |
| 服务端配置文件生成（协议 → inbound） | `render_config`（jq 从 state 生成，绝不 `sed -i`） | 五个协议共存需要端口/证书编排 |
| 客户端配置模板 + 分享链接 | `render_client_proto` / `render_client_all` / `render_links` | 用户要"服务端和客户端的模板" |
| 统一的端口编排与冲突检查 | 默认端口表（`docs/STATE.md`）+ `ui_check_ports` | 五个协议默认都想用 443，必须编排 |
| Hysteria2 端口跳跃（服务端 DNAT + 客户端 `server_ports`） | `fw_hop_apply` / `fw_hop_clear` + `_render_outbound_hysteria2` | 仓库模板里就有端口跳跃，是它的核心卖点 |
| 防火墙端口放行与卸载回收 | `lib/60-firewall.sh` | 一键部署必须放行端口，卸载必须回收（含跳跃规则） |
| 配置变更安全路径（备份→校验→重启→回滚） | `apply_change` | 远程机器上写坏配置 = 失联 |
| 变更预演（`--dry-run`）与沙箱门禁 | `run_gate` + `tests/` | 开发机不是 Linux，需要可测 |
| 内核能力探测（控制探针 + 字段探针） | `probe_capabilities` | 跨版本字段增删（`sniff` 被移除、AnyTLS 1.12 才有等） |
| 依赖检查与自动安装 | `deps_check` / `os_pkg_install` | 缺 jq/curl 时不能"莫名其妙退出" |

## 三、与仓库模板的对应关系（字段形状以模板为准）

| 协议 | 服务端来源 | 客户端来源 | 说明 |
| --- | --- | --- | --- |
| VLESS-Vision-REALITY | `VLESS-Vision-Reality/config_server.json` | `VLESS-Vision-Reality/config_client.json` | `flow=xtls-rprx-vision`、`reality.handshake`、`short_id`、客户端 `utls.fingerprint=chrome`、`packet_encoding=xudp` |
| VMess-WebSocket-TLS | `VMess-WebSocket-TLS/config_server.json` | `VMess-WebSocket-TLS/config_client.json` | `alterId: 0`、`transport.type=ws` + `max_early_data` + `early_data_header_name`、客户端 Mux(smux) |
| Hysteria2 | `Hysteria2/config_server.json` | `Hysteria2/config_client.json` | `alpn=["h3"]`、`up/down_mbps`、端口跳跃（`server_ports` + `hop_interval`） |
| TUIC | `Tuic/config_server.json` | `Tuic/config_client.json` | `congestion_control=bbr`、`auth_timeout`、`zero_rtt_handshake`、`heartbeat`、`udp_relay_mode=native` |
| AnyTLS | `AnyTLS/config_server.json` | `AnyTLS/config_client.json` | `padding_scheme`（默认与模板一致）、`idle_session_*`、`min_idle_session`、ALPN `h3,h2,http/1.1` |

## 四、已知差异（有意为之）

1. **服务端配置是"合并"的**：仓库模板一个协议一份配置、都监听 443；本脚本把所选协议的 inbound 合并进一份 `config.json` 并编排到互不冲突的端口（TCP 与 UDP 可共用端口号）。
2. **证书路径**：模板写死 `/root/fullchain.cer`、`/root/private.key`；本脚本统一安装到 `/etc/sing-box/certs/`（权限 640，属主 sing-box），支持多张证书并存与切换。
3. **服务端加了 `log` 段**（默认 `warn`）：远程排障必需；可用 `state.log_level` 调整。
4. **客户端多出 `all.json`**：所有已启用协议合成一份客户端配置（mixed 入站 10000 + 每个协议一条 outbound），单协议配置仍与模板一一对应。
5. **客户端 TUIC 保留模板里的 `network: "tcp"`**：用 1.12.0 / 1.13.0 / 1.14.1 三个真实二进制实测该字段合法（早前怀疑它被拒绝，实测不成立），因此按模板原样输出。
