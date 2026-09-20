# ------------------------------------------------------------------------------
# 六、节点管理与服务端配置 / Node management and server config
# ------------------------------------------------------------------------------
# 生成 /etc/sing-box/config.json，结构与项目模板一致：
#   inbounds: AnyTLS / Hysteria2 / TUIC / VLESS-Vision-Reality / VMess-WS-TLS
#   outbounds: direct
# ------------------------------------------------------------------------------

ACTIVE_FULLCHAIN=''
ACTIVE_KEY=''

# 解析当前生效证书，无证书时用自签占位 / Resolve active cert, fallback self-signed
resolve_active_cert() {
  ACTIVE_FULLCHAIN=''; ACTIVE_KEY=''
  if [ -n "$CERT_DOMAIN" ] && cert_paths "$CERT_DOMAIN"; then
    ACTIVE_FULLCHAIN="$CERT_FULLCHAIN"
    ACTIVE_KEY="$CERT_KEYFILE"
    return 0
  fi
  mkdir -p "$WORK_DIR/cert"
  if [ ! -s "$WORK_DIR/cert/fullchain.cer" ] || [ ! -s "$WORK_DIR/cert/private.key" ]; then
    gen_self_signed "$WORK_DIR/cert/fullchain.cer" "$WORK_DIR/cert/private.key" "${DOMAIN:-easysb.local}" >/dev/null 2>&1 || true
  fi
  ACTIVE_FULLCHAIN="$WORK_DIR/cert/fullchain.cer"
  ACTIVE_KEY="$WORK_DIR/cert/private.key"
  [ -s "$ACTIVE_FULLCHAIN" ] && [ -s "$ACTIVE_KEY" ]
}

# 协议启用状态辅助 / Protocol enabled helpers
proto_enabled() {
  case "$1" in
    anytls)         [ "$IS_ANYTLS" = 'true' ] ;;
    hysteria2)      [ "$IS_HYSTERIA2" = 'true' ] ;;
    tuic)           [ "$IS_TUIC" = 'true' ] ;;
    vless-reality)  [ "$IS_VLESS_REALITY" = 'true' ] ;;
    vmess-ws-tls)   [ "$IS_VMESS_WS_TLS" = 'true' ] ;;
    *) return 1 ;;
  esac
}

set_proto_enabled() {
  case "$1" in
    anytls)        IS_ANYTLS="$2" ;;
    hysteria2)     IS_HYSTERIA2="$2" ;;
    tuic)          IS_TUIC="$2" ;;
    vless-reality) IS_VLESS_REALITY="$2" ;;
    vmess-ws-tls)  IS_VMESS_WS_TLS="$2" ;;
  esac
}

port_var_name() {
  case "$1" in
    anytls)        printf 'PORT_ANYTLS' ;;
    hysteria2)     printf 'PORT_HYSTERIA2' ;;
    tuic)          printf 'PORT_TUIC' ;;
    vless-reality) printf 'PORT_VLESS_REALITY' ;;
    vmess-ws-tls)  printf 'PORT_VMESS_WS_TLS' ;;
  esac
}

node_any_enabled() {
  proto_enabled anytls || proto_enabled hysteria2 || proto_enabled tuic \
    || proto_enabled vless-reality || proto_enabled vmess-ws-tls
}

# 除 Reality 外都需要域名 / Everything except Reality needs a domain
node_needs_domain() {
  proto_enabled anytls || proto_enabled hysteria2 || proto_enabled tuic || proto_enabled vmess-ws-tls
}

# ------------------------------------------------------------------------------
# 节点面板 / Node dashboard
# ------------------------------------------------------------------------------
node_ports_summary() {
  local out=''
  proto_enabled anytls        && out="${out}AnyTLS:${PORT_ANYTLS} "
  proto_enabled hysteria2     && out="${out}Hysteria2:${PORT_HYSTERIA2} "
  proto_enabled tuic          && out="${out}TUIC:${PORT_TUIC} "
  proto_enabled vless-reality && out="${out}Reality:${PORT_VLESS_REALITY} "
  proto_enabled vmess-ws-tls  && out="${out}VMess:${PORT_VMESS_WS_TLS} "
  printf '%s' "${out% }"
}

node_dashboard() {
  ui_panel "$(text node_title)"
  ui_frame_field "$(text node_domain)"    "${DOMAIN:-$(text not_set)}"
  ui_frame_field "$(text node_password)"  "${PASSWORD:-$(text not_set)}"
  ui_frame_field "$(text node_uuid)"      "${UUID:-$(text not_set)}"
  if proto_enabled hysteria2; then
    ui_frame_field "$(text node_hop)"     "${HY2_HOP_RANGE:-$(text not_set)}"
  fi
  if proto_enabled vless-reality; then
    ui_frame_field "$(text node_privkey)" "${REALITY_PRIVATE:-$(text not_set)}"
    ui_frame_field "$(text node_shortid)" "${REALITY_SHORT_ID:-$(text not_set)}"
  fi
  ui_frame_field "$(text node_ports)"     "$(node_ports_summary)"
  if [ "$NODE_DEPLOYED" = 'yes' ]; then
    ui_frame_field "$(text node_status)"  "$(printf '%s%s%s' "$C_GREEN" "$(text node_deployed)" "$C_RESET")"
  else
    ui_frame_field "$(text node_status)"  "$(printf '%s%s%s' "$C_YELLOW" "$(text node_not_deployed)" "$C_RESET")"
  fi
}

# ------------------------------------------------------------------------------
# 协议多选 / Protocol multi-select (default: all)
# ------------------------------------------------------------------------------
node_protocol_select() {
  local i key mark line=""
  printf '\n%s\n' "$(text node_select_protos)"
  for i in "${!PROTOCOL_KEYS[@]}"; do
    key="${PROTOCOL_KEYS[$i]}"
    proto_enabled "$key" && mark='x' || mark=' '
    printf '   %b%d)%b [%s] %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "$mark" "${PROTOCOL_LABEL[$key]}"
  done
  printf '%s: ' "$(text select_prompt)"
  read -r line
  [ -z "$line" ] && line='1,2,3,4,5'
  case "${line,,}" in all|a) line='1,2,3,4,5' ;; esac
  line="${line//,/ }"
  for key in "${PROTOCOL_KEYS[@]}"; do set_proto_enabled "$key" false; done
  local tok idx
  for tok in $line; do
    [[ "$tok" =~ ^[0-9]+$ ]] || continue
    idx=$((tok-1))
    key="${PROTOCOL_KEYS[$idx]:-}"
    [ -n "$key" ] && set_proto_enabled "$key" true
  done
}

# 确保 Reality 密钥与 short_id / Ensure Reality keypair and short_id
node_ensure_reality() {
  if proto_enabled vless-reality; then
    if [ -z "$REALITY_PRIVATE" ] || [ -z "$REALITY_PUBLIC" ]; then
      if core_reality_keypair; then
        log_info "$(text param_key_gen)"
      else
        log_warn "$(text param_install_core_first)"
      fi
    fi
    [ -z "$REALITY_SHORT_ID" ] && REALITY_SHORT_ID="$(rand_short_id)"
  fi
}

# ------------------------------------------------------------------------------
# 一键部署 / One-click deploy
# ------------------------------------------------------------------------------
node_deploy() {
  core_installed || { log_warn "$(text node_need_core)"; return 1; }
  [ -n "$UUID" ] || UUID="$(core_generate_uuid)"
  [ -n "$PASSWORD" ] || PASSWORD="$(rand_password)"

  node_protocol_select
  if ! node_any_enabled; then
    log_warn "$(text node_all_disabled)"; return 1
  fi
  node_ensure_reality

  [ -z "$DOMAIN" ] && [ -n "$CERT_DOMAIN" ] && DOMAIN="$CERT_DOMAIN"
  if node_needs_domain && [ -z "$DOMAIN" ]; then
    log_warn "$(text node_need_domain)"; return 1
  fi

  save_state
  log_info "$(text node_deploying)"
  build_server_config
  verify_config
  write_service_unit
  service_enable quiet
  service_restart quiet
  configure_firewall
  write_firewall_unit
  NODE_DEPLOYED='yes'
  save_state
  log_ok "$(text node_deploy_done)"
  return 0
}

# ------------------------------------------------------------------------------
# 参数设置 / Parameters
# ------------------------------------------------------------------------------
ports_menu() {
  local choice i key var cur used tok
  while true; do
    clear 2>/dev/null || true
    ui_panel "$(text param_ports)"
    for i in "${!PROTOCOL_KEYS[@]}"; do
      key="${PROTOCOL_KEYS[$i]}"
      var="$(port_var_name "$key")"
      printf '   %b%d)%b %-20s : %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${PROTOCOL_LABEL[$key]}" "${!var}"
    done
    ui_item 0 "$(text back)"
    printf '%s [0-5]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      [1-5])
        key="${PROTOCOL_KEYS[$((choice-1))]}"
        var="$(port_var_name "$key")"
        cur="${!var}"
        used=()
        for tok in "${PROTOCOL_KEYS[@]}"; do
          [ "$tok" = "$key" ] && continue
          local tv; tv="$(port_var_name "$tok")"
          used+=("${!tv}")
        done
        ask_port param_port_prompt "$cur" "$var" "${used[@]}" && save_state
        pause_enter
        ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}

sni_menu() {
  local choice i preset custom
  ui_panel "$(text param_sni)"
  for i in "${!REALITY_SNI_PRESETS[@]}"; do
    printf '   %b%d)%b %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${REALITY_SNI_PRESETS[$i]}"
  done
  printf '   %b0)%b %s\n' "$C_GREEN" "$C_RESET" "$(text param_sni_custom)"
  printf '%s [0-%d]: ' "$(text param_sni_preset)" "${#REALITY_SNI_PRESETS[@]}"
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#REALITY_SNI_PRESETS[@]}" ]; then
    REALITY_SNI="${REALITY_SNI_PRESETS[$((choice-1))]}"
  else
    custom="$(read_default "$(printf "$(text param_sni_prompt)" "${REALITY_SNI:-$REALITY_SNI_DEFAULT}")" "${REALITY_SNI:-$REALITY_SNI_DEFAULT}")"
    REALITY_SNI="${custom:-$REALITY_SNI_DEFAULT}"
  fi
  save_state
  log_ok "$(text node_params_saved)"
}

node_params_menu() {
  local choice range s e
  while true; do
    clear 2>/dev/null || true
    node_dashboard
    printf '\n'
    ui_item 1 "$(text param_uuid)"
    ui_item 2 "$(text param_password)"
    ui_item 3 "$(text param_hop)"
    ui_item 4 "$(text param_ports)"
    ui_item 5 "$(text param_sni)"
    ui_item 6 "$(text param_privkey)"
    ui_item 7 "$(text param_shortid)"
    ui_item 0 "$(text back)"
    printf '%s [0-7]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) ask_secret param_uuid_prompt uuid UUID; save_state; pause_enter ;;
      2) ask_secret param_pw_prompt password PASSWORD; save_state; pause_enter ;;
      3)
        range="$(read_default "$(printf "$(text param_hop_prompt)" "$HY2_HOP_RANGE_DEFAULT")" "${HY2_HOP_RANGE:-$HY2_HOP_RANGE_DEFAULT}")"
        if [[ "$range" =~ ^[0-9]+:[0-9]+$ ]]; then
          s="${range%:*}"; e="${range#*:}"
          if [ "$s" -lt "$e" ] && [ "$s" -ge "$MIN_HOPPING_LOWER" ] && [ "$e" -le "$MAX_HOPPING_PORT" ]; then
            HY2_HOP_RANGE="$range"
          else
            log_warn "$(text param_invalid_range)"; HY2_HOP_RANGE="$HY2_HOP_RANGE_DEFAULT"
          fi
        else
          log_warn "$(text param_invalid_range)"; HY2_HOP_RANGE="$HY2_HOP_RANGE_DEFAULT"
        fi
        save_state; pause_enter
        ;;
      4) ports_menu ;;
      5) sni_menu; pause_enter ;;
      6)
        if core_reality_keypair; then log_ok "$(text param_regen_privkey)"; else log_warn "$(text param_install_core_first)"; fi
        save_state; pause_enter
        ;;
      7) REALITY_SHORT_ID="$(rand_short_id)"; save_state; log_ok "$(text param_regen_shortid)"; pause_enter ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# 节点管理菜单 / Node menu
# ------------------------------------------------------------------------------
node_manage_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    node_dashboard
    printf '\n'
    ui_item 1 "$(text node_deploy)"
    ui_item 2 "$(text node_params)"
    ui_item 0 "$(text back)"
    printf '%s [0-2]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) node_deploy; pause_enter ;;
      2) node_params_menu ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# 组装 inbounds 片段 / Build one inbound JSON block
# ------------------------------------------------------------------------------
_inbound_anytls() {
  cat <<EOF
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [
        { "name": "easysb", "password": "$(json_escape "$PASSWORD")" }
      ],
      "padding_scheme": [
        "stop=8",
        "0=30-30",
        "1=100-400",
        "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
        "3=9-9,500-1000",
        "4=500-1000",
        "5=500-1000",
        "6=500-1000",
        "7=500-1000"
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$(json_escape "$ACTIVE_FULLCHAIN")",
        "key_path": "$(json_escape "$ACTIVE_KEY")",
        "alpn": ["h3", "h2", "http/1.1"]
      }
    }
EOF
}

_inbound_hysteria2() {
  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": ${PORT_HYSTERIA2},
      "up_mbps": 100,
      "down_mbps": 20,
      "users": [
        { "name": "easysb", "password": "$(json_escape "$PASSWORD")" }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$(json_escape "$ACTIVE_FULLCHAIN")",
        "key_path": "$(json_escape "$ACTIVE_KEY")"
      }
    }
EOF
}

_inbound_tuic() {
  cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": ${PORT_TUIC},
      "users": [
        { "uuid": "$(json_escape "$UUID")", "password": "$(json_escape "$PASSWORD")" }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$(json_escape "$ACTIVE_FULLCHAIN")",
        "key_path": "$(json_escape "$ACTIVE_KEY")"
      }
    }
EOF
}

_inbound_vless_reality() {
  cat <<EOF
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${PORT_VLESS_REALITY},
      "users": [
        {
          "name": "easysb",
          "uuid": "$(json_escape "$UUID")",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$(json_escape "$REALITY_SNI")",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$(json_escape "$REALITY_SNI")",
            "server_port": 443
          },
          "private_key": "$(json_escape "$REALITY_PRIVATE")",
          "short_id": ["$(json_escape "$REALITY_SHORT_ID")"]
        }
      }
    }
EOF
}

_inbound_vmess_ws_tls() {
  cat <<EOF
    {
      "type": "vmess",
      "tag": "vmess-ws-tls",
      "listen": "::",
      "listen_port": ${PORT_VMESS_WS_TLS},
      "users": [
        { "name": "easysb", "uuid": "$(json_escape "$UUID")", "alterId": 0 }
      ],
      "multiplex": {
        "enabled": true,
        "padding": false
      },
      "transport": {
        "type": "ws",
        "path": "/vmess",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "tls": {
        "enabled": true,
        "certificate_path": "$(json_escape "$ACTIVE_FULLCHAIN")",
        "key_path": "$(json_escape "$ACTIVE_KEY")"
      }
    }
EOF
}

build_server_config() {
  resolve_active_cert || true
  local blocks=() b
  proto_enabled anytls        && blocks+=("$(_inbound_anytls)")
  proto_enabled hysteria2     && blocks+=("$(_inbound_hysteria2)")
  proto_enabled tuic          && blocks+=("$(_inbound_tuic)")
  proto_enabled vless-reality && blocks+=("$(_inbound_vless_reality)")
  proto_enabled vmess-ws-tls  && blocks+=("$(_inbound_vmess_ws_tls)")

  mkdir -p "$WORK_DIR"
  {
    printf '{\n'
    printf '  "log": {\n    "level": "info",\n    "timestamp": true\n  },\n'
    printf '  "inbounds": [\n'
    local i
    for i in "${!blocks[@]}"; do
      printf '%s' "${blocks[$i]}"
      if [ "$i" -lt "$((${#blocks[@]} - 1))" ]; then
        printf ',\n'
      else
        printf '\n'
      fi
    done
    printf '  ],\n'
    printf '  "outbounds": [\n'
    printf '    { "type": "direct", "tag": "direct" }\n'
    printf '  ]\n'
    printf '}\n'
  } > "$CONFIG_JSON"
  return 0
}

# 校验并给出结论 / Validate config and report
verify_config() {
  [ -x "$CORE_BIN" ] || return 0
  if core_config_check; then
    log_ok "$(text node_config_ok)"
  else
    log_error "$(text node_config_fail)"
  fi
}
