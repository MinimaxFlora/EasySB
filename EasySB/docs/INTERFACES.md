# EasySB 脚本集成契约（INTERFACES）

本文件是所有模块之间的**唯一契约**。任何模块只能调用这里列出的公共函数，不得自行发明名字。
并行开发（子代理 / 后续会话）按名字实现，契约审计脚本（`tests/audit.sh`）按名字检查。

## 0. 硬性规则（违反即缺陷）

1. **禁止下载即执行**：任何位置的更新都必须 下载 → 校验（`bash -n` / sha256）→ 备份 → 原子替换 → 保留回滚。
2. **禁止 `sed -i` 按行号改配置**：配置一律由 `jq` 从 state 数据模型重新生成。
3. **禁止清空防火墙表**：不得 `ufw disable`、`iptables -F`、`nft flush ruleset`、关闭 firewalld/SELinux；
   只能增删**本工具自己打标签**的规则，且卸载时必须全部回收（含端口跳跃的重定向规则）。
4. **禁止静默覆盖 `/etc/resolv.conf`**（本工具不改 DNS 系统设置）。
5. **输入校验只返回状态，绝不 `exit`**：UI 能调用的函数里用 `error "…"; return 1`；`die` 只用于
   不可恢复的错误（state 文件损坏、缺依赖）。测试方式：在子 shell 里调用，必须仍能打印 `RC=$?`。
6. **所有绝对路径走 ROOT 前缀变量**（`ESB_ROOT` 为空时即真实路径），所有**系统变更类命令**走 `run_gate`。
7. **密钥/私钥/uuid/密码不得出现在命令行参数里**（进程列表可见），不得明文打印（`mask_secret` 掩码）。
8. **非 TTY 下无颜色、无 spinner、无光标控制、无动画 sleep**。
9. 生成配置必须 `omitempty` 语义：不用的可选键**整个不输出**（空数组也是字段）。
10. 每个交互函数都必须能在 stdin 被管道喂入答案的情况下工作（非交互式自动化）。

## 1. 路径变量（由 `00-core.sh` / `10-detect.sh` 在 init 时导出）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ESB_ROOT` | 空 | 沙箱前缀；为空时全部是真实绝对路径 |
| `ESB_DIR` | `${ESB_ROOT}/etc/easysb` | 工具自身状态目录 |
| `ESB_STATE` | `$ESB_DIR/state.json` | 唯一状态源（JSON） |
| `ESB_LOG` | `$ESB_DIR/easysb.log` | 日志文件 |
| `ESB_CONF_DIR` | `${ESB_ROOT}/etc/sing-box` | sing-box 配置目录（与上游 .deb 一致） |
| `ESB_CONFIG` | `$ESB_CONF_DIR/config.json` | 服务端配置 |
| `ESB_CERT_DIR` | `$ESB_CONF_DIR/certs` | 证书安装目录 |
| `ESB_CLIENT_DIR` | `$ESB_DIR/client` | 客户端产物目录 |
| `ESB_SECRET_DIR` | `$ESB_DIR/secrets` | 600 权限的密钥目录（acme 账号、DNS API 凭据） |
| `ESB_BIN` | `${ESB_ROOT}/usr/bin/sing-box` | 内核二进制 |
| `ESB_UNIT_DIR` | `${ESB_ROOT}/usr/lib/systemd/system` | systemd unit 目录（Debian 用 `/etc/systemd/system`） |
| `ESB_STATE_DIR` | `${ESB_ROOT}/var/lib/sing-box` | 内核工作目录 |
| `ESB_BACKUP_DIR` | `${ESB_ROOT}/var/backups/easysb` | 备份目录 |
| `ESB_WEB_ROOT` | `${ESB_ROOT}/var/www/easysb` | 伪装站点根目录 |
| `ESB_NGINX_CONF` | `${ESB_ROOT}/etc/nginx/conf.d/easysb.conf` | 伪装站点 nginx 配置 |
| `ESB_TMP` | `${TMPDIR:-/tmp}/easysb.$$` | 临时目录（`esb_tmp_init` 创建） |

沙箱环境变量：`ESB_GATE=1`（变更命令不执行、追加到 `ESB_GATE_LOG`）、`ESB_GATE_LOG=<file>`、
`ESB_TEST_WORK=<dir>`、`ESB_NO_COLOR=1`、`ESB_ASSUME_YES=1`（全部确认默认 yes）、
`ESB_OFFLINE=1`（不联网）、`ESB_SYS_DIR=<dir>`（override 系统目录探测结果）。

## 2. 基础层 API（`00-core.sh`）

```
esb_color_init                       # 设置 C_* 颜色变量与 ESB_TTY
log_info/log_ok/log_warn/log_err/log_debug <msg...>
die <msg...>                         # 打印错误并 exit 1
error <msg...>                       # 打印错误并 return 1
ui_hr / ui_title <text> / ui_kv <k> <v> / ui_blank / pause
ask_input   <outvar> <prompt> [default]        # 读一行，outvar 得到结果（EOF 时置位 ESB_INPUT_EOF）
esb_input_exhausted                            # 0=stdin 已耗尽；重试循环必须据此退出，避免刷屏死循环
ask_secret  <outvar> <prompt>                  # 关闭回显读取
ask_yesno   <prompt> [y|n]                     # 0=yes 1=no
ask_single  <outvar> <prompt> <"key|label" ...> # 单选，outvar 得到 key
ask_multi   <outvar> <prompt> <"key|label|on|off" ...>  # 多选，outvar 得到 "k1 k2"
# ⚠ ask_single / ask_multi 的选项必须逐个传参（`"${arr[@]}"`）：标签里带空格时，
#   先拼成字符串再展开会被词分割成乱码菜单（协议标签就是"VLESS + Vision"这种）。
validate_domain <s> / validate_port <s> / validate_port_range <s>   # 只返回状态
esb_lock / esb_unlock
run_gate <描述> <cmd...>              # 系统变更命令唯一入口
esb_tmp_init / esb_tmp_clean
jq_ok                                 # jq 是否可用
json_write <file> [mode]              # stdin → 原子写入
mask_secret <s>
gen_uuid / gen_secret <bytes> / gen_hex <n> / reality_keypair   # reality_keypair 输出 "私钥 公钥"
trim / esb_now / esb_ts
esb_confirm_or_die <prompt>           # 危险操作确认（非 TTY 且 ESB_ASSUME_YES=1 时自动通过）
http_get <url> <outfile>              # curl 下载（尊重 ESB_OFFLINE / 代理变量）
http_json <url>                       # 取 JSON 到 stdout
sha256_of <file>
cmd_exists <cmd...>
```

## 3. 环境探测（`10-detect.sh`）

```
detect_all                     # 一次性填充 ESB_OS / ESB_OS_ID / ESB_OS_VER / ESB_ARCH / ESB_PKG / ESB_INIT / ESB_VIRT
os_pkg_install <pkg...>        # 按发行版调用 apt/dnf/yum/apk（走 run_gate）
deps_check                     # 必需依赖检查（jq/curl/openssl/tar），缺失则列出并 offer install
deps_install <pkg...>
detect_public_ip               # 输出公网 IPv4（失败输出空）
detect_local_ips               # 输出本机所有 IPv4，空格分隔
domain_resolves_to <domain>    # 0=解析到本机, 1=解析但不同, 2=不解析
port_in_use <port> <tcp|udp>   # 0=被占用
os_arch_to_asset <arch>        # 输出 releases 资产后缀（如 linux-amd64）
service_mgr <name> <start|stop|restart|status|enable|disable|reload>   # systemd/openrc 兼容层
```

## 4. 状态与变更路径（`20-state.sh`）

state.json 结构见 `docs/STATE.md`（由 `state_init` 生成默认值）。

```
state_init                      # 不存在则创建默认状态（幂等）
state_load                      # 读取并校验；损坏则 die
state_save                      # 原子写入（600）
state_get <jq-path>             # 如 .domain（不存在输出空）
state_get_raw <jq-filter>
state_set <jq-path> <json>      # 值按 JSON 解析（字符串需自带引号可用 state_set_str）
state_set_str <jq-path> <string>
state_has <jq-path>             # 0=存在且非 null
proto_enabled <proto>           # 0=启用
proto_enabled_list              # 输出已启用协议 key（空格分隔）
proto_port <proto>              # 输出端口
state_proto_set <proto> <json-object>
apply_change <描述>             # 备份 → render_config → sb_check_config → 重启 → resync；失败自动回滚并 return 1
esb_backup <name> / esb_restore_latest / esb_backup_list
secret_get <key> / secret_set <key> <value>
```

协议 key 常量（固定，不得更改）：`vless-vision-reality`、`vmess-ws-tls`、`anytls`、`hysteria2`、`tuic`。

## 5. 配置渲染（`40-render.sh`，全部用 jq 生成）

```
render_config                  # 生成服务端 $ESB_CONFIG（只含已启用协议的 inbound），0/1
render_client_all              # $ESB_CLIENT_DIR/all.json
render_client_proto <proto>    # $ESB_CLIENT_DIR/<proto>.json
render_clients                 # 遍历已启用协议 + all.json
render_links                   # stdout 输出全部分享链接（每行一条）
link_vless / link_vmess / link_hysteria2 / link_tuic / link_anytls   # stdout 单条链接
render_summary                 # stdout 人类可读摘要（端口/协议/域名）
```

## 6. 内核管理（`50-singbox.sh`）

```
sb_installed                  # 0=已安装
sb_version                    # 输出已安装版本号（如 1.14.1），未安装输出空
sb_latest_version             # 输出仓库最新 tag 版本号（去 v），失败输出空
sb_asset_url <version> <archasset>   # 组装下载 URL（走本仓库 releases）
sb_install <version|latest>   # 下载→sha256 校验→解压→原子替换→安装 unit/用户/目录；失败 return 1
sb_update                     # 比较版本后更新到最新；已最新则提示
sb_check_config [file]        # 用真实二进制校验配置（默认 $ESB_CONFIG）
probe_capabilities            # 两个控制探针 + 关键字段探针，结果写入 $ESB_DIR/capabilities.json
unit_install / unit_remove
sb_fix_perms                  # 配置/证书的属主与权限（root:sing-box 640/750），服务以 sing-box 用户运行
sb_service <start|stop|restart|status|enable|disable|reload>
sb_status_line                # stdout：运行状态/版本/端口
sb_uninstall                  # 卸载内核与配置（保留备份），不删用户数据目录之外的东西
script_latest_version         # 仓库中 EasySB/VERSION 的版本号
script_update                 # 自更新：下载 dist/easysb.sh → bash -n 校验 → 原子替换 → 提示重启脚本
```

## 7. 证书（`30-certs.sh`）

```
cert_tool_installed            # 0=acme.sh 已就绪
cert_tool_install              # 安装 acme.sh（走 run_gate；失败 return 1）
cert_list                      # stdout TSV：域名<TAB>crt<TAB>key<TAB>剩余天数<TAB>来源<TAB>是否已应用(1/0)
cert_apply <domain> <mode>     # mode: standalone|webroot|dns:<provider>；成功后写入证书注册表
cert_use <domain>              # 把某证书应用到 sing-box（写 .cert 并触发 apply_change）
cert_delete <domain> [--force] # 删除证书与 acme 记录；被使用中且无 --force 时 return 1
cert_renew <domain> / cert_renew_all
cert_detail <domain>           # stdout：主体/SAN/颁发者/生效/过期
cert_self_signed <domain>      # 仅测试/兜底用：本地自签并注册
cert_reloadcmd_setup           # 让 acme.sh 续期成功后自动重载 sing-box
cert_expiring_days <domain>    # 输出剩余天数（整数，失败输出 -1）
cert_acme_home                 # 输出 acme.sh 安装目录
```

证书注册表：`$ESB_DIR/certs.json`（由 `20-state.sh` 的 `state_get_raw` 姊妹函数 `registry_get/set` 读写，
见 `30-certs.sh` 头部的 `registry_*` 实现）。

## 8. 防火墙（`60-firewall.sh`）

```
fw_backend                     # ufw|firewalld|nftables|iptables|none
fw_open <port> <tcp|udp>       # 只添加带 EasySB 标签的规则
fw_close <port> <tcp|udp>
fw_apply_all                   # 依据 state 打开全部所需端口（含伪装站点 80/443）
fw_revert_all                  # 关闭本工具添加过的全部规则（卸载时调用）
fw_hop_apply <range> <to_port> # 端口跳跃 DNAT 重定向（UDP）
fw_hop_clear                   # 清除端口跳跃规则
fw_status                      # stdout 人类可读的防火墙与规则摘要
```

## 9. 伪装站点（`70-web.sh`）

```
web_templates                  # stdout TSV：key<TAB>名称
web_installed                  # 0=nginx 已安装
web_install                    # 安装 nginx（run_gate）
web_deploy <template-key>      # 部署/更新站点（生成 nginx conf，不碰其它站点配置）
web_disable                    # 关闭站点（删除本工具的 conf 与 root，保留证书）
web_status                     # stdout 摘要
web_acme_webroot               # stdout webroot 路径（acme webroot 模式用）
web_apply_cert                 # 把已应用证书写入 nginx 配置（443），无证书则只留 80
web_reload                     # nginx -t + reload
web_port_free <port>           # 0=端口可用（未被本工具自己的服务占用除外）
```

## 10. 节点链接与订阅（`80-subscribe.sh`）

```
sub_token                      # stdout 当前订阅 token（不存在则生成并写入 state）
sub_token_regen                # 重新生成 token（旧地址立即失效）
sub_url                        # stdout 主订阅地址（通用 Base64 订阅）
sub_url_list                   # stdout TSV：格式<TAB>地址（base64/links/singbox/mihomo）
sub_formats                    # stdout TSV：key<TAB>说明
sub_links_text                 # stdout 纯文本节点链接（每行一条）
sub_links_base64               # stdout Base64 节点列表（通用订阅格式）
sub_mihomo_yaml                # stdout Mihomo/Clash 配置（YAML）
sub_singbox_json               # stdout sing-box 客户端配置（JSON）
sub_dir                        # stdout 订阅文件目录（token 目录）
sub_write_files                # 生成全部订阅文件到 sub_dir（644）
sub_enable                     # 生成订阅 + 必要时部署独立订阅站点 + 放行端口
sub_disable                    # 关闭订阅（保留文件）
sub_status                     # stdout 人类可读摘要
sub_refresh                    # 配置变更后静默刷新订阅内容
sub_site_deploy / sub_site_remove   # 独立订阅站点（nginx，独立 conf，端口 .sub.port）
sub_use_site                   # 0=复用伪装站点（TLS），1=使用独立订阅站点
```

订阅文件（`sub_dir` 下）：`sub`（Base64 通用订阅）、`links.txt`、`singbox.json`、`mihomo.yaml`、
`info.txt`。state 里的 `.sub = {enabled, token, serve_via_site, port, root, name}`。

## 11. UI 层（`90-ui.sh`）

```
ui_main                 # 主菜单循环
ui_deploy_wizard        # 部署向导（协议多选，默认全选；域名强制；证书；伪装站点；内核；订阅；防火墙）
ui_status_menu
ui_cert_menu            # 证书管理子菜单（列表/申请/应用/删除/续期）
ui_web_menu             # 伪装站点子菜单
ui_update_menu          # 更新（内核 / 脚本）
ui_clients_menu         # 客户端配置、节点链接、订阅入口
ui_sub_menu             # 订阅子菜单（生成/地址/二维码/换 token/独立站点）
ui_show_links / ui_show_qr
ui_uninstall
```

## 12. 入口（`easysb.sh`）与打包（`build.sh`）

入口 `easySB/easysb.sh` 支持：`--version`、`--help`、`install`、`status`、`uninstall`、
`--no-color`、`--dry-run`（= `ESB_GATE=1`）。所有模块通过 `lib/` 里的 `source` 加载（单文件版由 `build.sh` 内联）。

`build.sh` 输出 `dist/easysb.sh`（唯一允许 `curl | bash` 的文件）+ `dist/SHA256SUMS`，
`dist/easysb.sh --version` 必须可运行。
