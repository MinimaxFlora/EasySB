# state.json 数据模型（唯一状态源）

由 `state_init` 生成，只通过 `state_set*` / `state_get*` 访问，只通过 `apply_change` 生效到运行中的服务。
文件权限 600，路径 `$ESB_DIR/state.json`。

```jsonc
{
  "schema": 1,
  "script_version": "1.0.0",          // 部署时使用的脚本版本
  "installed_at": "2026-09-18 13:00:00",
  "domain": "node.example.com",        // 强制域名部署（客户端地址 / TLS SNI）
  "email": "me@example.com",           // acme 注册邮箱
  "server_ip": "1.2.3.4",              // 探测到的公网 IP（仅参考）
  "kernel": {
    "version": "1.14.1",
    "arch_asset": "linux-amd64",
    "binary": "/usr/bin/sing-box",
    "installed_at": "",
    "checksum": "sha256:..."
  },
  "reality": {
    "private_key": "...",              // sing-box generate reality-keypair
    "public_key": "...",
    "short_id": "5b6966df",
    "handshake_server": "www.microsoft.com",  // 借用证书的真实站点
    "handshake_port": 443,
    "server_name": "www.microsoft.com"        // 客户端 SNI（= handshake_server）
  },
  "secrets": {
    "vless_uuid": "…", "vmess_uuid": "…", "tuic_uuid": "…",
    "tuic_password": "…", "hysteria2_password": "…", "anytls_password": "…"
  },
  "protocols": {
    "vless-vision-reality": {"enabled": true, "port": 443, "tag": "vless-vision-reality"},
    "vmess-ws-tls": {"enabled": true, "port": 8443, "path": "/vmess", "tag": "vmess-ws-tls", "early_data": true},
    "anytls": {"enabled": true, "port": 2096, "tag": "anytls", "padding": true},
    "hysteria2": {"enabled": true, "port": 443, "tag": "hysteria2", "up_mbps": 100, "down_mbps": 100,
                  "hop": {"enabled": false, "range": "20000-30000", "interval": "30s"}},
    "tuic": {"enabled": true, "port": 8443, "tag": "tuic", "congestion_control": "bbr"}
  },
  "cert": {"domain": "", "crt": "", "key": "", "source": "", "applied_at": ""},
  "web": {"enabled": false, "template": "blog", "root": "/var/www/easysb",
          "http_port": 80, "tls": false, "tls_port": 443, "proxy_target": ""},
  "sub": {"enabled": false, "token": "", "serve_via_site": true, "port": 8080,
          "root": "/var/www/easysb-sub", "name": "EasySB"},
  "firewall": {"backend": "none", "rules": ["443/tcp"], "hop": {"enabled": false, "range": "", "to_port": 0}},
  "backups": ["2026-09-18_130000_install"]
}
```

## 端口默认值（互不冲突）

| 协议 | 传输 | 默认端口 | 证书 |
| --- | --- | --- | --- |
| vless-vision-reality | TCP | 443 | 不需要（REALITY 借用真实站点） |
| vmess-ws-tls | TCP | 8443 | 需要 |
| anytls | TCP | 2096 | 需要 |
| hysteria2 | UDP | 443 | 需要 |
| tuic | UDP | 8443 | 需要 |
| 伪装站点 | TCP | 80（可选 443） | 443 与 vless-reality 冲突时自动只留 80 |

所有端口在 UI 中可改；改动走 `apply_change`（改 → 渲染 → `sing-box check` → 重启 → 失败回滚）。

## 端口跳跃（Hysteria2）

客户端 `server_ports` + 服务端 DNAT 重定向（`fw_hop_apply <range> <to_port>`），
规则打在**本工具自己的** nft table（`easysb`）/ iptables 链（`EASYSB_HOP`）里，卸载时随 `fw_hop_clear` 回收。
