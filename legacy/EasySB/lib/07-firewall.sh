# ------------------------------------------------------------------------------
# 七、防火墙与端口跳跃 / Firewall and port hopping
# ------------------------------------------------------------------------------
# Hysteria2 端口跳跃：把 起始:结束 的 UDP 端口重定向到实际监听端口。
#
# iptables:
#   iptables -t nat -A PREROUTING -p udp --dport 2080:3000 -j REDIRECT --to-ports 8001
#
# nftables:
#   nft add table ip nat
#   nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; }'
#   nft add rule ip nat prerouting udp dport 2080-3000 redirect to :8001
#
# 优先 iptables，其次 nftables；规则按内容判重，重复执行不会叠加。
# ------------------------------------------------------------------------------

FW_STATE_DIR="${WORK_DIR}/firewall"
FW_BACKEND=''

fw_detect() {
  if have_cmd iptables; then
    FW_BACKEND='iptables'
  elif have_cmd nft; then
    FW_BACKEND='nft'
  else
    FW_BACKEND='none'
  fi
  mkdir -p "$FW_STATE_DIR"
}

# ------------------------------------------------------------------------------
# iptables
# ------------------------------------------------------------------------------
_fw_iptables_add() {
  local start="$1" end="$2" to="$3"
  iptables -t nat -C PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$to" >/dev/null 2>&1 && return 0
  iptables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$to" >/dev/null 2>&1
}

_fw_iptables_del() {
  local start="$1" end="$2" to="$3"
  while iptables -t nat -C PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$to" >/dev/null 2>&1; do
    iptables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$to" >/dev/null 2>&1 || break
  done
}

# ------------------------------------------------------------------------------
# nftables（标准 ip nat 表）
# ------------------------------------------------------------------------------
_fw_nft_ensure() {
  nft list table ip nat >/dev/null 2>&1 || nft add table ip nat >/dev/null 2>&1
  if ! nft list chain ip nat prerouting >/dev/null 2>&1; then
    nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; }' >/dev/null 2>&1
  fi
}

_fw_nft_add() {
  local start="$1" end="$2" to="$3"
  _fw_nft_ensure
  nft list chain ip nat prerouting 2>/dev/null | grep -qE "udp dport ${start}-${end} redirect to :${to}([[:space:]]|$)" && return 0
  nft add rule ip nat prerouting udp dport "${start}-${end}" redirect to :"$to" >/dev/null 2>&1
}

_fw_nft_del() {
  local start="$1" end="$2" to="$3" handle
  nft list chain ip nat prerouting >/dev/null 2>&1 || return 0
  while read -r handle; do
    [ -n "$handle" ] && nft delete rule ip nat prerouting handle "$handle" >/dev/null 2>&1
  done < <(nft -a list chain ip nat prerouting 2>/dev/null | awk -v pat="udp dport ${start}-${end} redirect to :${to}" 'index($0,pat){print $NF}')
}

# ------------------------------------------------------------------------------
# 放行协议端口 / Open protocol ports with ufw or firewalld when present
# ------------------------------------------------------------------------------
fw_open_ports() {
  local ports_tcp=() ports_udp=() p
  proto_enabled anytls        && ports_tcp+=("$PORT_ANYTLS")
  proto_enabled tuic          && ports_udp+=("$PORT_TUIC")
  proto_enabled vless-reality && ports_tcp+=("$PORT_VLESS_REALITY")
  proto_enabled vmess-ws-tls  && ports_tcp+=("$PORT_VMESS_WS_TLS")
  proto_enabled hysteria2     && ports_udp+=("$PORT_HYSTERIA2")
  [ -n "$SUB_PORT" ] && ports_tcp+=("$SUB_PORT")

  if have_cmd ufw; then
    for p in "${ports_tcp[@]}"; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
    for p in "${ports_udp[@]}"; do ufw allow "$p"/udp >/dev/null 2>&1 || true; done
  elif have_cmd firewall-cmd; then
    for p in "${ports_tcp[@]}"; do firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 || true; done
    for p in "${ports_udp[@]}"; do firewall-cmd --permanent --add-port="$p"/udp >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

configure_firewall() {
  log_step "$(text fw_configuring)"
  fw_detect
  if [ "$FW_BACKEND" = 'none' ]; then
    log_warn "$(text fw_none)"
    return 0
  fi
  if proto_enabled hysteria2; then
    local start="${HY2_HOP_RANGE%:*}" end="${HY2_HOP_RANGE#*:}"
    if [ "$FW_BACKEND" = 'iptables' ]; then
      _fw_iptables_add "$start" "$end" "$PORT_HYSTERIA2" && log_ok "$(text fw_added)"
    else
      _fw_nft_add "$start" "$end" "$PORT_HYSTERIA2" && log_ok "$(text fw_added)"
    fi
  fi
  fw_open_ports
}

remove_firewall() {
  fw_detect
  if proto_enabled hysteria2; then
    local start="${HY2_HOP_RANGE%:*}" end="${HY2_HOP_RANGE#*:}"
    if [ "$FW_BACKEND" = 'iptables' ]; then
      _fw_iptables_del "$start" "$end" "$PORT_HYSTERIA2"
    elif [ "$FW_BACKEND" = 'nft' ]; then
      _fw_nft_del "$start" "$end" "$PORT_HYSTERIA2"
    fi
    log_ok "$(text fw_removed)"
  fi
}

# ------------------------------------------------------------------------------
# 开机自动恢复规则 / Persist rules across reboot
# ------------------------------------------------------------------------------
FW_UNIT_NAME='easysb-firewall'
FW_UNIT_FILE=''

write_firewall_unit() {
  proto_enabled hysteria2 || return 0
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    FW_UNIT_FILE="/etc/systemd/system/${FW_UNIT_NAME}.service"
    cat > "$FW_UNIT_FILE" <<EOF
[Unit]
Description=EasySB Hysteria2 port-hopping firewall rules
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash ${WORK_DIR}/easysb.sh --apply-firewall

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "${FW_UNIT_NAME}.service" >/dev/null 2>&1 || true
  else
    FW_UNIT_FILE="/etc/init.d/${FW_UNIT_NAME}"
    cat > "$FW_UNIT_FILE" <<EOF
#!/sbin/openrc-run
name="${FW_UNIT_NAME}"
description="EasySB Hysteria2 port-hopping firewall rules"
depend() { after net; before sing-box; }

start() {
  ebegin "Applying EasySB port-hopping rules"
  bash ${WORK_DIR}/easysb.sh --apply-firewall >/dev/null 2>&1
  eend \$?
}
EOF
    chmod +x "$FW_UNIT_FILE"
    rc-update add "$FW_UNIT_NAME" default >/dev/null 2>&1 || true
  fi
}

remove_firewall_unit() {
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl disable "${FW_UNIT_NAME}.service" >/dev/null 2>&1 || true
  else
    rc-update del "$FW_UNIT_NAME" default >/dev/null 2>&1 || true
  fi
  rm -f "/etc/systemd/system/${FW_UNIT_NAME}.service" "/etc/init.d/${FW_UNIT_NAME}"
}
