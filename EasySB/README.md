# EasySB 一键部署脚本

> 基于本仓库（[MinimaxFlora/EasySB](https://github.com/MinimaxFlora/EasySB)）的 sing-box 一键部署与管理脚本。
> 一条命令把 **VLESS-Vision-REALITY / VMess-WebSocket-TLS / Hysteria2 / TUIC / AnyTLS** 中的任意组合
> （默认全部五个）部署到 Linux VPS，强制域名部署，自动申请 ACME 证书，可选部署伪装站点，
> 支持内核与脚本在线更新。

## 一键安装（在 VPS 上以 root 运行）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/EasySB/dist/easysb.sh)
```

如果终端不支持进程替换，或者你想先看一眼脚本再运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/EasySB/dist/easysb.sh
less easysb.sh      # 看过之后再执行
bash easysb.sh
```

> 前提：一台可以公网访问的 Linux VPS（Debian/Ubuntu/CentOS/Rocky/Alma/Fedora/Alpine 均可）、
> 一个**已经解析到这台机器**的域名、root 权限。

## 功能一览

| 菜单 | 能力 |
| --- | --- |
| 1. 一键部署 / 修改部署 | 协议多选（默认五个全选）→ 域名（强制）→ 端口编排 → 伪装站点 → 安装内核 → 生成密钥 → 证书 → 校验 → 启动 → 输出客户端配置 |
| 2. 运行状态 | 服务状态、内核版本、协议与端口、证书剩余天数、防火墙规则、伪装站点状态 |
| 3. 服务管理 | 启动 / 停止 / 重启 / 重载 / 实时日志 |
| 4. 证书管理 | 申请（standalone / webroot / DNS API）、列表（含剩余天数）、应用、删除、续期、详情、续期后自动重载 |
| 5. 伪装站点 | 部署 / 更换模板（博客 / 企业官网 / 空白页 / 自定义 HTML / 反向代理）、启用 HTTPS、关闭 |
| 6. 客户端配置与分享链接 | 全部节点链接、单节点二维码、**订阅链接**（生成 / 查看 / 二维码 / 换 token / 独立订阅站点）、客户端配置导出、关闭订阅 |
| 7. 更新 | sing-box 内核更新、脚本自更新、安装/切换指定内核版本（显示当前 vs 仓库最新） |
| 8. 卸载 | 停止服务、回收防火墙规则（含端口跳跃重定向）、关闭站点、卸载内核，保留状态与备份 |

## 默认端口编排

| 协议 | 传输 | 默认端口 | 证书 |
| --- | --- | --- | --- |
| VLESS + Vision + REALITY | TCP | 443 | 不需要（借用真实站点证书） |
| VMess + WebSocket + TLS | TCP | 8443 | 需要 |
| AnyTLS | TCP | 2096 | 需要 |
| Hysteria2 | UDP | 443 | 需要（+ 可选端口跳跃 20000-30000） |
| TUIC v5 | QUIC/UDP | 8443 | 需要 |
| 伪装站点 | TCP | 80（可选 443） | 可选 |

端口都可以在向导里改；TCP 443 与 UDP 443 不冲突（不同传输层协议）。

## 安装后目录（与被管理的服务）

| 路径 | 内容 |
| --- | --- |
| `/etc/easysb/state.json` | 唯一状态源（600），含密钥、协议、端口、证书、站点配置 |
| `/etc/easysb/client/*.json` | 客户端配置（每个协议一份 + `all.json` 合集） |
| `/etc/easysb/secrets/dns.env` | DNS API 凭据（600） |
| `/etc/easysb/easysb.log` | 操作日志 |
| `/etc/sing-box/config.json` | 服务端配置（由状态生成，权限 600） |
| `/etc/sing-box/certs/` | 已安装的证书 |
| `/var/backups/easysb/` | 每次变更前的备份、旧内核、旧脚本 |
| `/usr/bin/sing-box` | 内核（来自本仓库 releases） |
| `/var/www/easysb/` | 伪装站点根目录 |

服务由 systemd 管理（`systemctl status sing-box`），单元文件与本仓库 `.deb` 包保持一致
（`User=sing-box`、`-D /var/lib/sing-box -C /etc/sing-box`）。

## 安全设计

- **配置变更走一条路**：备份 → 用 `jq` 从状态重新生成 → `sing-box check` 校验 → 重启 → 失败自动回滚，
  绝不会出现"写坏的配置 + 重启 = 机器失联"。
- **下载即执行是禁止的**：所有下载（内核、脚本、acme.sh）都先落盘、校验（`bash -n` / sha256）
  再原子替换，旧文件留档回滚。
- **证书申请**支持 standalone / webroot / DNS API 三种模式；申请成功后自动写入证书目录并 600/640 收紧权限。
- **防火墙只增删自己打标签的规则**：不 flush 表、不关闭 ufw/firewalld/SELinux；卸载时把自己加过的规则
  （包括 Hysteria2 端口跳跃的 DNAT 重定向）全部回收。
- **密钥不出现在命令行**（进程列表看不到），输出一律掩码显示。

## 开发与测试

```bash
bash build.sh                     # 组装单文件 dist/easysb.sh（语法检查 + 版本一致性 + 冒烟测试）
bash tests/run_tests.sh --unit    # 沙箱测试套件（不需要 Linux）
bash tests/audit.sh               # 契约审计：公共函数是否齐全 + 违规模式扫描
bash tests/real-parser.sh         # 用真实 sing-box 二进制校验生成的配置
                                  #   默认取本仓库 releases 的最新 tag（本仓库编译的内核从 1.14 起）
                                  #   ESB_REALPARSER_EXTRA=1 时额外用官方旧版本做跨世代兼容性验证
bash tests/acceptance.sh          # 真机验收：在**已部署好的 VPS 上**跑，检查 systemd 服务、
                                  #   端口监听、伪装站点与订阅地址可访问、防火墙规则、证书、产物
```

文档：`docs/INTERFACES.md`（模块契约）、`docs/STATE.md`（状态模型）、
`docs/FEATURE-MAP.md`（需求→实现映射）、`docs/TESTING.md`（测试沙箱契约）。

## 常见问题

**Q：为什么强制域名？**
强制域名是为了证书与伪装：TLS 类协议（VMess-WS-TLS / Hysteria2 / TUIC / AnyTLS）需要域名才能签发证书，
REALITY 也需要域名做 SNI。用域名还能让流量看起来像正常 HTTPS 访问。

**Q：80 端口被占用了还能申请证书吗？**
可以。证书菜单里选 `DNS API` 方式，不需要 80 端口；或者先关掉占用 80 的程序再用 standalone。

**Q：五个协议都开，端口冲突吗？**
不会。脚本默认把 TCP/UDP 分开编排（详见上面的默认端口表），并在启动前做占用检查。

**Q：怎么只装其中一两个协议？**
部署向导第二步用 `1,3` 这样的序号选择，或输入 `none` 后再选；`all` 是全选。

**Q：更新失败会影响正在运行的服务吗？**
不会。内核与脚本更新都是"下载 → 校验 → 备份 → 原子替换"，失败时保留原文件；配置变更同样会回滚。

**Q：REALITY 节点连不上，日志写 `reality verification failed`？**
先换一个网络环境再试（例如手机热点），或者用非 REALITY 的节点（VMess-WS-TLS / AnyTLS / Hysteria2 / TUIC）。
常见原因是你本机开着代理（Clash / Mihomo 等），它按 SNI 把 `www.microsoft.com` 这条连接劫持走了 ——
REALITY 依赖握手目标站点的真实证书，被中间设备改写就会校验失败。服务端本身是好的，
可以用同一份客户端配置在服务器上"自己连自己"验证。

**Q：机器上原来就有 sing-box / acme.sh 怎么办？**
脚本会复用已有的 `/root/.acme.sh`（同一个 acme 账号），覆盖 `/etc/sing-box/config.json`
（覆盖前的配置会进 `/var/backups/easysb/`）；建议先自行备份，或用 `uninstall` 后回滚。
