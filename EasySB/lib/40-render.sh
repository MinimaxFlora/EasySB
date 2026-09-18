#!/usr/bin/env bash
# =============================================================================
# EasySB — 40-render.sh
# 配置渲染：服务端 inbound / 客户端配置 / 分享链接，全部由 jq 从 state 生成
# 依赖：00-core.sh, 20-state.sh
# =============================================================================
# shellcheck shell=bash

# AnyTLS 默认填充方案（与仓库 AnyTLS/config_server.json 一致）
ESB_ANYTLS_PADDING='["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"]'

# ---------------------------------------------------------------------------
# 服务端 inbound
# ---------------------------------------------------------------------------
_render_inbound_vless() {
  jq -n --argjson port "$(proto_port vless-vision-reality)" \
        --arg uuid "$(secret_get vless_uuid)" \
        --arg sni "$(state_get .reality.server_name)" \
        --arg hs "$(state_get .reality.handshake_server)" \
        --argjson hsport "$(state_get .reality.handshake_port)" \
        --arg pk "$(state_get .reality.private_key)" \
        --arg sid "$(state_get .reality.short_id)" '
    {type:"vless", tag:"vless-vision-reality", listen:"::", listen_port:$port,
     users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
     tls:{enabled:true, server_name:$sni,
          reality:{enabled:true,
                   handshake:{server:$hs, server_port:$hsport},
                   private_key:$pk, short_id:[$sid]}}}'
}

_render_inbound_vmess() {
  jq -n --argjson port "$(proto_port vmess-ws-tls)" \
        --arg uuid "$(secret_get vmess_uuid)" \
        --arg path "$(state_get '.protocols["vmess-ws-tls"].path')" \
        --argjson early "$(state_get '.protocols["vmess-ws-tls"].early_data')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    ({type:"vmess", tag:"vmess-ws-tls", listen:"::", listen_port:$port,
      users:[{uuid:$uuid, alterId:0}],
      multiplex:{enabled:true, padding:false},
      transport:({type:"ws", path:$path} + (if $early then
                   {max_early_data:2048, early_data_header_name:"Sec-WebSocket-Protocol"} else {} end))}
     + {tls:{enabled:true, certificate_path:$crt, key_path:$key}})'
}

_render_inbound_anytls() {
  jq -n --argjson port "$(proto_port anytls)" \
        --arg pw "$(secret_get anytls_password)" \
        --argjson pad "$(state_get '.protocols.anytls.padding')" \
        --argjson padding "$ESB_ANYTLS_PADDING" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    ({type:"anytls", tag:"anytls", listen:"::", listen_port:$port,
      users:[{name:"easysb", password:$pw}],
      tls:{enabled:true, certificate_path:$crt, key_path:$key,
           alpn:["h3","h2","http/1.1"]}}
     + (if $pad then {padding_scheme:$padding} else {} end))'
}

_render_inbound_hysteria2() {
  jq -n --argjson port "$(proto_port hysteria2)" \
        --arg pw "$(secret_get hysteria2_password)" \
        --argjson up "$(state_get '.protocols.hysteria2.up_mbps')" \
        --argjson down "$(state_get '.protocols.hysteria2.down_mbps')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    {type:"hysteria2", tag:"hysteria2", listen:"::", listen_port:$port,
     up_mbps:$up, down_mbps:$down,
     users:[{name:"easysb", password:$pw}],
     tls:{enabled:true, alpn:["h3"], certificate_path:$crt, key_path:$key}}'
}

_render_inbound_tuic() {
  jq -n --argjson port "$(proto_port tuic)" \
        --arg uuid "$(secret_get tuic_uuid)" \
        --arg pw "$(secret_get tuic_password)" \
        --arg cc "$(state_get '.protocols.tuic.congestion_control')" \
        --argjson zrtt "$(state_get '.protocols.tuic.zero_rtt')" \
        --arg crt "$(state_get .cert.crt)" --arg key "$(state_get .cert.key)" '
    {type:"tuic", tag:"tuic", listen:"::", listen_port:$port,
     users:[{uuid:$uuid, password:$pw}],
     congestion_control:$cc, auth_timeout:"3s", zero_rtt_handshake:$zrtt, heartbeat:"10s",
     tls:{enabled:true, alpn:["h3"], certificate_path:$crt, key_path:$key}}'
}

render_inbound() {
  case "$1" in
    vless-vision-reality) _render_inbound_vless ;;
    vmess-ws-tls)         _render_inbound_vmess ;;
    anytls)               _render_inbound_anytls ;;
    hysteria2)            _render_inbound_hysteria2 ;;
    tuic)                 _render_inbound_tuic ;;
    *) error "未知协议：$1"; return 1 ;;
  esac
}

# 需要证书但还没应用证书时返回 1
render_cert_ready() {
  local _rcr_p _rcr_need=0
  for _rcr_p in $(proto_enabled_list); do
    if proto_needs_cert "$_rcr_p"; then _rcr_need=1; break; fi
  done
  [ "$_rcr_need" = "0" ] && return 0
  local _rcr_crt _rcr_key
  _rcr_crt="$(state_get .cert.crt)"
  _rcr_key="$(state_get .cert.key)"
  [ -f "$_rcr_crt" ] && [ -f "$_rcr_key" ]
}

# ---------------------------------------------------------------------------
# 服务端配置
# ---------------------------------------------------------------------------
render_config() {
  jq_ok || { error "缺少 jq"; return 1; }
  local _rc_list _rc_p _rc_level
  _rc_list="$(proto_enabled_list)"
  if [ -z "$_rc_list" ]; then error "尚未启用任何协议，无法生成配置"; return 1; fi
  if ! render_cert_ready; then
    error "已启用需要证书的协议，但尚未应用证书（请先在【证书管理】中申请并应用证书）"
    return 1
  fi

  mkdir -p "$ESB_CONF_DIR" || { error "无法创建配置目录 $ESB_CONF_DIR"; return 1; }

  local _rc_jsonl="${ESB_TMP}/inbounds.jsonl"
  : >"$_rc_jsonl" || return 1
  for _rc_p in $_rc_list; do
    if ! render_inbound "$_rc_p" >>"$_rc_jsonl"; then
      error "渲染协议 $_rc_p 的 inbound 失败"
      return 1
    fi
    printf '\n' >>"$_rc_jsonl"
  done

  _rc_level="$(state_get .log_level)"; [ -n "$_rc_level" ] || _rc_level="warn"
  local _rc_out="${ESB_CONFIG}.tmp.$$"
  if ! jq -s --arg level "$_rc_level" '
        {log:{level:$level, timestamp:true},
         inbounds:.,
         outbounds:[{type:"direct", tag:"direct"}]}' <"$_rc_jsonl" >"$_rc_out"; then
    rm -f "$_rc_out"
    error "生成服务端配置失败（jq）"
    return 1
  fi
  chmod 600 "$_rc_out" 2>/dev/null || true
  mv -f "$_rc_out" "$ESB_CONFIG" || { rm -f "$_rc_out"; error "写入 $ESB_CONFIG 失败"; return 1; }
  # 服务以 sing-box 用户运行，而配置是 root 写的：这里立刻修正属主/权限
  if command -v sb_fix_perms >/dev/null 2>&1; then sb_fix_perms >/dev/null 2>&1 || true; fi
  log_debug "服务端配置已生成：$ESB_CONFIG（协议：$_rc_list）"
  return 0
}

# ---------------------------------------------------------------------------
# 客户端 outbound
# ---------------------------------------------------------------------------
_client_server()   { local _cs_d; _cs_d="$(state_get .domain)"; printf '%s\n' "$_cs_d"; }

_render_outbound_vless() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port vless-vision-reality)" \
        --arg uuid "$(secret_get vless_uuid)" \
        --arg sni "$(state_get .reality.server_name)" \
        --arg pbk "$(state_get .reality.public_key)" \
        --arg sid "$(state_get .reality.short_id)" '
    {type:"vless", tag:"vless-vision-reality", server:$server, server_port:$port,
     uuid:$uuid, flow:"xtls-rprx-vision", packet_encoding:"xudp",
     tls:{enabled:true, server_name:$sni,
          utls:{enabled:true, fingerprint:"chrome"},
          reality:{enabled:true, public_key:$pbk, short_id:$sid}}}'
}

_render_outbound_vmess() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port vmess-ws-tls)" \
        --arg uuid "$(secret_get vmess_uuid)" \
        --arg path "$(state_get '.protocols["vmess-ws-tls"].path')" '
    {type:"vmess", tag:"vmess-ws-tls", server:$server, server_port:$port, uuid:$uuid,
     security:"auto", alter_id:0, global_padding:false, authenticated_length:true,
     packet_encoding:"packetaddr",
     tls:{enabled:true, server_name:$server,
          utls:{enabled:true, fingerprint:"chrome"}},
     multiplex:{enabled:true, protocol:"smux", max_connections:4, min_streams:4,
                max_streams:0, padding:false},
     transport:{type:"ws", path:$path, max_early_data:2048,
                early_data_header_name:"Sec-WebSocket-Protocol"}}'
}

_render_outbound_anytls() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port anytls)" \
        --arg pw "$(secret_get anytls_password)" '
    {type:"anytls", tag:"anytls", server:$server, server_port:$port, password:$pw,
     idle_session_check_interval:"30s", idle_session_timeout:"30s", min_idle_session:5,
     tls:{enabled:true, server_name:$server, alpn:["h3","h2","http/1.1"],
          utls:{enabled:true, fingerprint:"chrome"}}}'
}

_render_outbound_hysteria2() {
  local _roh_hop_enabled _roh_range _roh_interval _roh_range_colon
  _roh_hop_enabled="$(state_get '.protocols.hysteria2.hop.enabled')"
  if [ "$_roh_hop_enabled" = "true" ]; then
    _roh_range="$(state_get '.protocols.hysteria2.hop.range')"
    _roh_interval="$(state_get '.protocols.hysteria2.hop.interval')"
  else
    _roh_range=""; _roh_interval=""
  fi
  # 关键：sing-box 的 server_ports 要冒号分隔（"2080:3000"），带"-"会被
  # `sing-box check` 判为 "bad port range"（nft 用 "-"，iptables 用 ":"，
  # 这里是第三种写法，state 里统一保存 "a-b" 形式再按需转换）。
  _roh_range_colon="$(printf '%s' "$_roh_range" | tr '-' ':')"
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port hysteria2)" \
        --arg pw "$(secret_get hysteria2_password)" \
        --arg hop "$_roh_range_colon" --arg hopint "$_roh_interval" '
    ({type:"hysteria2", tag:"hysteria2", server:$server, server_port:$port,
      up_mbps:20, down_mbps:100, password:$pw,
      tls:{enabled:true, server_name:$server, alpn:["h3"]}}
     + (if $hop != "" then {server_ports:[$hop], hop_interval:$hopint} else {} end))'
}

_render_outbound_tuic() {
  jq -n --arg server "$(_client_server)" --argjson port "$(proto_port tuic)" \
        --arg uuid "$(secret_get tuic_uuid)" --arg pw "$(secret_get tuic_password)" \
        --arg cc "$(state_get '.protocols.tuic.congestion_control')" '
    {type:"tuic", tag:"tuic", server:$server, server_port:$port, uuid:$uuid, password:$pw,
     congestion_control:$cc, udp_relay_mode:"native", udp_over_stream:false,
     zero_rtt_handshake:false, heartbeat:"10s", network:"tcp",
     tls:{enabled:true, server_name:$server, alpn:["h3"]}}'
}

render_outbound() {
  case "$1" in
    vless-vision-reality) _render_outbound_vless ;;
    vmess-ws-tls)         _render_outbound_vmess ;;
    anytls)               _render_outbound_anytls ;;
    hysteria2)            _render_outbound_hysteria2 ;;
    tuic)                 _render_outbound_tuic ;;
    *) error "未知协议：$1"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 客户端配置
# ---------------------------------------------------------------------------
render_client_proto() {
  local _rcp_proto="$1" _rcp_out="${ESB_CLIENT_DIR}/$1.json" _rcp_tmp
  mkdir -p "$ESB_CLIENT_DIR" || return 1
  _rcp_tmp="${_rcp_out}.tmp.$$"
  # 与仓库模板一一对应：mixed 入站 10000 + 该协议的单条 outbound
  if ! render_outbound "$_rcp_proto" | jq '{log:{level:"warn", timestamp:true},
        inbounds:[{type:"mixed", listen:"::", listen_port:10000}],
        outbounds:[.]}' >"$_rcp_tmp"; then
    rm -f "$_rcp_tmp"
    error "渲染客户端配置失败：$_rcp_proto"
    return 1
  fi
  chmod 600 "$_rcp_tmp" 2>/dev/null || true
  mv -f "$_rcp_tmp" "$_rcp_out" || { rm -f "$_rcp_tmp"; return 1; }
  return 0
}

render_client_all() {
  local _rca_out="${ESB_CLIENT_DIR}/all.json" _rca_tmp="${ESB_CLIENT_DIR}/all.json.tmp.$$"
  local _rca_jsonl="${ESB_TMP}/outbounds.jsonl" _rca_p
  mkdir -p "$ESB_CLIENT_DIR" || return 1
  : >"$_rca_jsonl" || return 1
  for _rca_p in $(proto_enabled_list); do
    render_outbound "$_rca_p" >>"$_rca_jsonl" || { error "渲染客户端 outbound 失败：$_rca_p"; return 1; }
    printf '\n' >>"$_rca_jsonl"
  done
  if ! jq -s '{log:{level:"warn", timestamp:true},
               inbounds:[{type:"mixed", listen:"::", listen_port:10000}],
               outbounds:(. + [{type:"direct", tag:"direct"}])}' <"$_rca_jsonl" >"$_rca_tmp"; then
    rm -f "$_rca_tmp"; error "生成 all.json 失败"; return 1
  fi
  chmod 600 "$_rca_tmp" 2>/dev/null || true
  mv -f "$_rca_tmp" "$_rca_out" || { rm -f "$_rca_tmp"; return 1; }
  return 0
}

render_clients() {
  local _rcl_p _rcl_fail=0
  for _rcl_p in $(proto_enabled_list); do
    render_client_proto "$_rcl_p" || _rcl_fail=1
  done
  render_client_all || _rcl_fail=1
  [ "$_rcl_fail" = "0" ] || { error "部分客户端配置生成失败"; return 1; }
  log_ok "客户端配置已生成于：$ESB_CLIENT_DIR"
  return 0
}

# ---------------------------------------------------------------------------
# 分享链接
# ---------------------------------------------------------------------------
url_encode() { printf '%s' "${1-}" | jq -sRr @uri; }

link_vless() {
  local _lv_server _lv_port _lv_uuid _lv_sni _lv_pbk _lv_sid _lv_name
  _lv_server="$(_client_server)"; _lv_port="$(proto_port vless-vision-reality)"
  _lv_uuid="$(secret_get vless_uuid)"; _lv_sni="$(state_get .reality.server_name)"
  _lv_pbk="$(state_get .reality.public_key)"; _lv_sid="$(state_get .reality.short_id)"
  _lv_name="$(url_encode "EasySB-VLESS-Reality-${_lv_server}")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$_lv_uuid" "$_lv_server" "$_lv_port" "$(url_encode "$_lv_sni")" "$(url_encode "$_lv_pbk")" "$_lv_sid" "$_lv_name"
  return 0
}

link_vmess() {
  local _lm_server _lm_port _lm_uuid _lm_path _lm_ps _lm_json
  _lm_server="$(_client_server)"; _lm_port="$(proto_port vmess-ws-tls)"
  _lm_uuid="$(secret_get vmess_uuid)"; _lm_path="$(state_get '.protocols["vmess-ws-tls"].path')"
  _lm_ps="EasySB-VMess-WS-TLS-${_lm_server}"
  _lm_json="$(jq -nc --arg v "2" --arg ps "$_lm_ps" --arg add "$_lm_server" \
      --argjson port "$_lm_port" --arg id "$_lm_uuid" --arg host "$_lm_server" \
      --arg path "$_lm_path" '
      {v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
       net:"ws", type:"none", host:$host, path:$path, tls:"tls",
       sni:$add, alpn:"h2,http/1.1", fp:"chrome"}')"
  printf 'vmess://%s\n' "$(printf '%s' "$_lm_json" | base64 | tr -d '\n')"
  return 0
}

link_hysteria2() {
  local _lh_server _lh_port _lh_pw _lh_hop _lh_hopint _lh_name _lh_q
  _lh_server="$(_client_server)"; _lh_port="$(proto_port hysteria2)"
  _lh_pw="$(secret_get hysteria2_password)"
  _lh_hop=""; _lh_hopint=""
  if [ "$(state_get '.protocols.hysteria2.hop.enabled')" = "true" ]; then
    _lh_hop="$(state_get '.protocols.hysteria2.hop.range')"
    _lh_hopint="$(state_get '.protocols.hysteria2.hop.interval')"
  fi
  _lh_name="$(url_encode "EasySB-Hysteria2-${_lh_server}")"
  _lh_q="sni=${_lh_server}&insecure=0&alpn=h3"
  [ -n "$_lh_hop" ] && _lh_q="${_lh_q}&mport=$(url_encode "$_lh_hop")&hop_interval=${_lh_hopint}"
  printf 'hysteria2://%s@%s:%s?%s#%s\n' "$(url_encode "$_lh_pw")" "$_lh_server" "$_lh_port" "$_lh_q" "$_lh_name"
  return 0
}

link_tuic() {
  local _lt_server _lt_port _lt_uuid _lt_pw _lt_name
  _lt_server="$(_client_server)"; _lt_port="$(proto_port tuic)"
  _lt_uuid="$(secret_get tuic_uuid)"; _lt_pw="$(secret_get tuic_password)"
  _lt_name="$(url_encode "EasySB-TUIC-${_lt_server}")"
  printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=0#%s\n' \
    "$_lt_uuid" "$(url_encode "$_lt_pw")" "$_lt_server" "$_lt_port" "$_lt_server" "$_lt_name"
  return 0
}

link_anytls() {
  local _la_server _la_port _la_pw _la_name
  _la_server="$(_client_server)"; _la_port="$(proto_port anytls)"
  _la_pw="$(secret_get anytls_password)"
  _la_name="$(url_encode "EasySB-AnyTLS-${_la_server}")"
  printf 'anytls://%s@%s:%s?sni=%s&insecure=0&fp=chrome#%s\n' \
    "$(url_encode "$_la_pw")" "$_la_server" "$_la_port" "$_la_server" "$_la_name"
  return 0
}

render_links() {
  local _rl_p
  for _rl_p in $(proto_enabled_list); do
    case "$_rl_p" in
      vless-vision-reality) link_vless ;;
      vmess-ws-tls)         link_vmess ;;
      anytls)               link_anytls ;;
      hysteria2)            link_hysteria2 ;;
      tuic)                 link_tuic ;;
    esac
  done
  return 0
}

client_link_for() {
  case "$1" in
    vless-vision-reality) link_vless ;;
    vmess-ws-tls)         link_vmess ;;
    anytls)               link_anytls ;;
    hysteria2)            link_hysteria2 ;;
    tuic)                 link_tuic ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------
render_summary() {
  local _rs_p _rs_port _rs_trans
  ui_kv "部署域名" "$(state_get .domain)"
  ui_kv "公网 IP" "$(state_get .server_ip)"
  ui_kv "内核版本" "$(state_get .kernel.version)"
  local _rs_cert_domain; _rs_cert_domain="$(state_get .cert.domain)"
  if [ -n "$_rs_cert_domain" ]; then
    ui_kv "已应用证书" "${_rs_cert_domain}（剩余 $(cert_expiring_days "$_rs_cert_domain" 2>/dev/null || echo '?') 天）"
  else
    ui_kv "已应用证书" "无"
  fi
  printf '  %-18s\n' "协议列表"
  for _rs_p in $(proto_enabled_list); do
    _rs_port="$(proto_port "$_rs_p")"
    case "$_rs_p" in
      hysteria2|tuic) _rs_trans="UDP" ;;
      *) _rs_trans="TCP" ;;
    esac
    printf '      %s%-22s%s %s/%-6s %s\n' "$C_GREEN" "$_rs_p" "$C_RESET" "$_rs_trans" "$_rs_port" "$(proto_label "$_rs_p" | tr -d '\n')"
  done
  local _rs_web; _rs_web="$(state_get .web.enabled)"
  if [ "$_rs_web" = "true" ]; then
    ui_kv "伪装站点" "已开启（模板：$(state_get .web.template)，端口 $(state_get .web.http_port)）"
  else
    ui_kv "伪装站点" "未开启"
  fi
  return 0
}
