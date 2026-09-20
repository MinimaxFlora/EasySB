#!/usr/bin/env bash
# 静态特性检查 / Static feature checks
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
# shellcheck source=helpers.sh
. "${DIR}/helpers.sh"

DIST="${ROOT}/dist/easysb.sh"

printf '\n[features]\n'

# 入口与界面
for fn in print_banner select_language main_menu usage; do
  assert_contains "$DIST" "${fn}()" "function ${fn}"
done

# 菜单结构
for fn in kernel_menu node_manage_menu domain_menu subscribe_menu service_menu; do
  assert_contains "$DIST" "${fn}()" "menu ${fn}"
done

# 节点管理
for fn in node_dashboard node_protocol_select node_deploy node_params_menu ports_menu sni_menu installed_core_channel core_switch core_update_current; do
  assert_contains "$DIST" "${fn}()" "node function ${fn}"
done

# 五协议
for tag in anytls hysteria2 tuic vmess-ws-tls vless-reality; do
  assert_contains "$DIST" "\"tag\": \"${tag}\"" "protocol ${tag}"
done

# 内核三操作
for fn in install_core uninstall_core replace_core fetch_core_releases; do
  assert_contains "$DIST" "${fn}()" "core function ${fn}"
done

# 证书
for fn in issue_cert list_certs switch_cert resolve_active_cert collect_cert_domains; do
  assert_contains "$DIST" "${fn}()" "cert function ${fn}"
done

# 订阅与分享链接
for fn in generate_subscription generate_share_links subscription_url print_qr; do
  assert_contains "$DIST" "${fn}()" "subscribe function ${fn}"
done
assert_contains "$DIST" 'tun-fakeip.json' 'subscription template reference'

# 防火墙端口跳跃
for fn in configure_firewall remove_firewall write_firewall_unit remove_firewall_unit; do
  assert_contains "$DIST" "${fn}()" "firewall function ${fn}"
done
assert_contains "$DIST" 'iptables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$to"' 'iptables DNAT redirect'
assert_contains "$DIST" 'nft add table ip nat' 'nft ip nat table'
assert_contains "$DIST" 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; }' 'nft nat prerouting chain'
assert_contains "$DIST" 'nft add rule ip nat prerouting udp dport "${start}-${end}" redirect to :"$to"' 'nft DNAT redirect'

# 服务与快捷命令
for fn in write_service_unit service_start service_stop service_restart create_shortcut self_update write_nginx_site; do
  assert_contains "$DIST" "${fn}()" "service function ${fn}"
done

# 官方内核源
assert_contains "$DIST" 'SagerNet/sing-box' 'official core source'

# 不应出现旧协议与占位敏感信息
for legacy in 'ShadowTLS' 'naive' 'Trojan' 'Argo' 'WARP'; do
  assert_not_contains "$DIST" "$legacy" "no legacy ${legacy}"
done
assert_not_contains "$DIST" 'us.kejizero.xyz' 'no hardcoded example domain'
assert_not_contains "$DIST" 'MCAI_LLM' 'no platform LLM key reference'

summary
