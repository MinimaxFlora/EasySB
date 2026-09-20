# ------------------------------------------------------------------------------
# 九、订阅生成 / Subscription builder
# ------------------------------------------------------------------------------
# 以项目模板 Templates/tun-fakeip.json 为基础，注入本地节点参数，生成
# /etc/sing-box/subscribe/subscribe.json（sing-box 客户端订阅）。
# 同时输出订阅链接、终端二维码与五种协议的分享链接。
# ------------------------------------------------------------------------------

SUBSCRIBE_FILE="${SUBSCRIBE_DIR}/subscribe.json"
SHARE_FILE="${SUBSCRIBE_DIR}/share-links.txt"

list_enabled_tags() {
  local t=()
  proto_enabled anytls        && t+=('anytls')
  proto_enabled hysteria2     && t+=('hysteria2')
  proto_enabled tuic          && t+=('tuic')
  proto_enabled vmess-ws-tls  && t+=('vmess-ws-tls')
  proto_enabled vless-reality && t+=('vless-vision-reality')
  printf '%s\n' "${t[@]}"
}

# 去除 JSON 中的 // 注释（不破坏字符串内的 URL）/ Strip JSONC line comments
strip_jsonc() {
  awk '
  {
    out=""; inq=0; i=1; n=length($0);
    while (i<=n) {
      c=substr($0,i,1);
      if (c=="\"") { inq=1-inq; out=out c; i++; continue }
      if (inq==0 && c=="/" && substr($0,i+1,1)=="/") { break }
      out=out c; i++;
    }
    print out;
  }' "$1"
}

# 找到订阅模板：优先本地仓库，其次远端 / Locate the subscription template
_loc_template() {
  local candidates=(
    "$(dirname "${BASH_SOURCE[0]:-$0}")/../../Templates/tun-fakeip.json"
    "./Templates/tun-fakeip.json"
    "${WORK_DIR}/tun-fakeip.json"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -s "$c" ] && { printf '%s' "$c"; return 0; }
  done
  local out="$TEMP_DIR/tun-fakeip.json"
  if download "$SUBSCRIBE_TEMPLATE_URL" "$out" && [ -s "$out" ]; then
    printf '%s' "$out"; return 0
  fi
  return 1
}

sub_server_host() {
  if [ -n "$DOMAIN" ]; then
    printf '%s' "$DOMAIN"
  else
    printf '%s' "${SERVER_IP:-$(detect_server_ip)}"
  fi
}

generate_subscription() {
  log_step "$(text sub_regen)"
  mkdir -p "$SUBSCRIBE_DIR"
  local template clean
  template="$(_loc_template)" || { log_error 'template not found'; return 1; }
  clean="$TEMP_DIR/tun-fakeip.clean.json"
  strip_jsonc "$template" > "$clean"

  local host sni rsni tags_json
  host="$(sub_server_host)"
  sni="$host"
  rsni="${REALITY_SNI:-$REALITY_SNI_DEFAULT}"
  [ -z "$host" ] && { log_error 'no server address'; return 1; }

  tags_json="$(list_enabled_tags | jq -R . | jq -s .)"

  if ! have_cmd jq; then
    log_error 'jq required'; return 1
  fi

  jq --arg server "$host" --arg sni "$sni" --arg rsni "$rsni" \
     --arg uuid "$UUID" --arg pw "$PASSWORD" \
     --arg pub "$REALITY_PUBLIC" --arg sid "$REALITY_SHORT_ID" \
     --arg hop "$HY2_HOP_RANGE" \
     --argjson pa "$PORT_ANYTLS" --argjson pt "$PORT_TUIC" \
     --argjson pr "$PORT_VLESS_REALITY" --argjson pv "$PORT_VMESS_WS_TLS" \
     --argjson tags "$tags_json" '
    .outbounds |= map(
      if .tag=="anytls" then .server=$server | .server_port=$pa | .password=$pw | .tls.server_name=$sni
      elif .tag=="hysteria2" then .server=$server | .server_ports=[$hop] | .password=$pw | .tls.server_name=$sni
      elif .tag=="tuic" then .server=$server | .server_port=$pt | .uuid=$uuid | .password=$pw | .tls.server_name=$sni
      elif .tag=="vmess-ws-tls" then .server=$server | .server_port=$pv | .uuid=$uuid | .tls.server_name=$sni
      elif .tag=="vless-vision-reality" then .server=$server | .server_port=$pr | .uuid=$uuid | .tls.server_name=$rsni | .tls.reality.public_key=$pub | .tls.reality.short_id=$sid
      else . end
    )
    | .outbounds |= map(select(.tag as $t | ($t=="proxy") or ($t=="auto") or ($t=="direct") or (($tags|index($t)) != null)))
    | (.outbounds[] | select(.tag=="proxy").outbounds) = (["auto"] + $tags)
    | (.outbounds[] | select(.tag=="auto").outbounds) = $tags
  ' "$clean" > "$SUBSCRIBE_FILE" 2>/dev/null

  if [ ! -s "$SUBSCRIBE_FILE" ]; then
    log_error 'subscription generation failed'; return 1
  fi
  generate_share_links > "$SHARE_FILE" 2>/dev/null || true
  log_ok "$(text sub_generated): ${SUBSCRIBE_FILE}"
  return 0
}

# 五种协议的分享链接 / Share links for all five protocols
generate_share_links() {
  local host sni name
  host="$(sub_server_host)"
  sni="$host"
  name='EasySB'

  if proto_enabled anytls; then
    printf 'anytls://%s@%s:%s?insecure=0&sni=%s#%s-AnyTLS\n' \
      "$PASSWORD" "$host" "$PORT_ANYTLS" "$sni" "$name"
  fi
  if proto_enabled hysteria2; then
    printf 'hysteria2://%s@%s:%s?sni=%s&insecure=0#%s-Hysteria2\n' \
      "$PASSWORD" "$host" "$PORT_HYSTERIA2" "$sni" "$name"
    printf '# Hysteria2 端口跳跃范围 / port hopping: %s\n' "$HY2_HOP_RANGE"
  fi
  if proto_enabled tuic; then
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&udp_relay_mode=native#%s-TUIC\n' \
      "$UUID" "$PASSWORD" "$host" "$PORT_TUIC" "$sni" "$name"
  fi
  if proto_enabled vmess-ws-tls; then
    local vmess_json
    vmess_json="$(jq -cn --arg ps "$name-VMess" --arg add "$host" --argjson port "$PORT_VMESS_WS_TLS" \
      --arg id "$UUID" --arg host "$sni" --arg path '/vmess' \
      '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
    printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64 | tr -d '\n')"
  fi
  if proto_enabled vless-reality; then
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-VLESS-Reality\n' \
      "$UUID" "$host" "$PORT_VLESS_REALITY" "${REALITY_SNI:-$REALITY_SNI_DEFAULT}" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$name"
  fi
}

# 订阅链接 / Subscription URL
subscription_url() {
  local host scheme='http'
  host="$(sub_server_host)"
  if [ -n "$DOMAIN" ] && resolve_active_cert; then
    scheme='https'
  fi
  printf '%s://%s:%s%s' "$scheme" "$host" "${SUB_PORT:-$SUB_PORT_DEFAULT}" "${SUB_PATH:-$SUB_PATH_DEFAULT}"
}

# 订阅二维码载荷 / QR payload for the sing-box client
# 直接编码裸订阅地址时 sing-box 客户端无法识别；必须使用 import-remote-profile
# 深层链接，并对订阅地址做 URL 编码。
# A bare subscription URL is not recognized by the sing-box client; encode the
# import-remote-profile deep link with the subscription URL percent-encoded.
qr_payload() {
  local url="$1" enc
  if have_cmd jq; then
    enc="$(jq -rn --arg u "$url" '$u|@uri')"
  elif have_cmd python3; then
    enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$url")"
  else
    enc="$url"
  fi
  printf 'sing-box://import-remote-profile?url=%s' "$enc"
}

print_qr() {
  local url="$1" payload
  payload="$(qr_payload "$url")"
  if have_cmd qrencode; then
    qrencode -t ANSIUTF8 "$payload"
  else
    log_warn "$(text sub_no_qrencode)"
  fi
}

show_share_links() {
  printf '\n%s\n' "$(text sub_links)"
  if [ -s "$SHARE_FILE" ]; then
    cat "$SHARE_FILE"
  else
    generate_share_links
  fi
}

subscribe_menu() {
  local choice url
  while true; do
    clear 2>/dev/null || true
    log_step "$(text sub_title)"
    url="$(subscription_url)"
    printf '  %s: %s\n\n' "$(text sub_url)" "$url"
    printf '  [1] %s\n' "$(text sub_regen)"
    printf '  [2] %s\n' "$(text sub_url)"
    printf '  [3] %s\n' "$(text sub_qr)"
    printf '  [4] %s\n' "$(text sub_links)"
    printf '  [0] %s\n' "$(text back)"
    printf '%s [0-4]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1)
        [ -s "$CONFIG_JSON" ] || { log_warn "$(text sub_need_deploy)"; pause_enter; continue; }
        generate_subscription
        write_nginx_site
        pause_enter
        ;;
      2)
        printf '%s\n' "$url"
        pause_enter
        ;;
      3)
        print_qr "$url"
        pause_enter
        ;;
      4)
        show_share_links
        pause_enter
        ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}
