# 真机验证记录（Debian 12 · 2026-09-18）

在用户提供的测试机（154.201.92.245，Debian GNU/Linux 12 (bookworm)，x86_64，2C/4G，
域名 `us.kejizero.xyz` 已解析到该机）上，用 `dist/easysb.sh` 完整跑了一遍
"部署 → 验收 → 证书操作 → 更新检查 → 卸载 → 重新部署"。

## 结果一览

| 步骤 | 结果 |
| --- | --- |
| 部署向导（五协议全选 + 博客伪装站点 + webroot 申请证书 + 端口跳跃 + 订阅） | 成功；sing-box v1.14.1（本仓库 releases）安装并启动 |
| `tests/acceptance.sh` | **36 通过 / 0 失败 / 0 跳过** |
| 伪装站点（`http://us.kejizero.xyz/`） | HTTP 200，2762 字节，标题「云间笔记 · 个人博客」 |
| ACME 挑战目录（`/.well-known/acme-challenge/`） | 公网可达（HTTP 200）→ 续期可用 |
| 订阅 `base64` / `links.txt` / `singbox.json` / `mihomo.yaml` | 全部 200；base64 解码出 5 条节点；Mihomo YAML 可被真实 YAML 解析器加载（5 节点 / 2 策略组 / 4 规则） |
| 客户端端到端（Windows 上真实 sing-box 1.14.1 客户端） | VMess-WS-TLS ✓、AnyTLS ✓、**Hysteria2 + 端口跳跃 ✓**、TUIC ✓，出口 IP 均回到 154.201.92.245；VLESS-REALITY 走干净链路（SSH 隧道）同样 ✓ |
| 证书操作 | `cert_list`（域名/路径/剩余 88 天/acme:webroot/已应用=1）、`cert_detail`（Let's Encrypt，SAN 正确）、`cert_delete`（使用中拒绝删除）、`cert_renew`（未到时间 → 明确提示无需续期）、`cert_use`（写配置 → `sing-box check` → 重启，服务在 15:31:10 真实重启） |
| 更新检查 | `sb_version` 1.14.1 = `sb_latest_version` 1.14.1；`sb_update` 提示已是最新；`script_update` 在 master 尚无该文件时优雅报错（合并后即可用） |
| 防火墙 | nftables 后端；6 条带 `EasySB` 注释的规则 + 端口跳跃 REDIRECT；`fw_status` 输出正确 |
| 卸载 | nft 表 `inet easysb` 被完整回收、服务单元移除、内核卸载（保留备份）、协议端口不再监听、`state` 与客户端配置保留 |
| 重新部署 | 复用原密钥与证书，30 秒内恢复可用，`acceptance` 再次 36/36 |

## 真机暴露并修掉的缺陷（沙箱与真实内核校验都没发现的）

1. **证书已存在时 `acme.sh --issue` 返回 2**（"Domains not changed. Skipping."）
   → 旧逻辑判为失败并中止整个向导。修复：识别为"复用已有证书"继续部署，
   另加 `ESB_CERT_FORCE=1` 才强制重签。（提交 `ab93bba`）
2. **`cert_renew` 无条件 `--force`** → 对刚签发 3 天的证书强续被 CA 拒绝，
   白耗 Let's Encrypt 频率额度。修复：默认不强制；未到续期时间返回 0 并提示。（提交 `006bc36`）
3. **`service_mgr` 依赖 `detect_all` 先跑过** → 库被单独 source 时误判"本机没有服务管理器"，
   让一次正常的证书应用被 `apply_change` 判失败并回滚（回滚本身正确，服务与配置完好）。（提交 `8331296`）
4. **`ESB_TMP` 未兜底** → 单独 source 时 `render`/`script_update`/`cert_use` 在 `set -u` 下报
   "unbound variable"。修复：`esb_paths_init` 一并初始化临时目录。（提交 `006bc36`）

## 测试环境相关的干扰（不是产品缺陷）

- 测试机 80 端口原本被一个手工起的 `busybox httpd` 占用，测试前已停止（备份与说明见下）。
- 测试机已有一份 sing-box `.deb` 安装与 `/etc/sing-box/config.json`，脚本会覆盖，
  已备份到 `/root/easysb-test-backup/`；另有既存 `/root/.acme.sh`（v3.1.5）账号被复用。
- 测试机自带 Clash 代理：从该机直连 REALITY 节点时，客户端 SNI 是 `www.microsoft.com`，
  被本机代理按 SNI 劫持后 `reality verification failed`（服务端日志里根本没有来自该机的
  失败连接，只有扫描器的）。换成 SSH 隧道这条干净链路后 REALITY 正常。
  **结论：本地代理会破坏 REALITY 的握手，换网络环境或用非 REALITY 节点即可。**

## 仍未覆盖

- 本机没有测试：firewalld / ufw 后端、Alpine(RHEL 系的 http.d 路径)、ARM 架构、
  ACME 的 DNS API 模式（需要真实 DNS 服务商凭据）、证书真实到期续期（88 天后）。
