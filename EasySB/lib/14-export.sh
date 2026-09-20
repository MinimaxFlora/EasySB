# ------------------------------------------------------------------------------
# 十六、节点导出、订阅与二维码 / Node export, subscription and QR code
# ------------------------------------------------------------------------------
export_list() {
  IS_INSTALL=$1

  check_install

  [ "$IS_INSTALL" != 'install' ] && fetch_nodes_value

  # IPv6 时的 IP 处理
  if [[ "$SERVER_IP" =~ : ]]; then
    SERVER_IP_1="[$SERVER_IP]"
    SERVER_IP_2="[[$SERVER_IP]]"
  else
    SERVER_IP_1="$SERVER_IP"
    SERVER_IP_2="$SERVER_IP"
  fi

  # 使用 Argo 时，获取临时隧道域名
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && [ "$IS_ARGO" = 'is_argo' ] && [ -z "$ARGO_DOMAIN" ] && [[ "${STATUS[1]}" = "$(text 28)" || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] && fetch_quicktunnel_domain

  # 如果使用 Json 或者 Token Argo，则使用加密的而且是固定的 Argo 隧道域名，否则使用 IP:PORT 的 http 服务
  [[ "$ARGO_TYPE" = 'is_token_argo' || "$ARGO_TYPE" = 'is_json_argo' ]] && SUBSCRIBE_ADDRESS="https://$ARGO_DOMAIN" || SUBSCRIBE_ADDRESS="http://${SERVER_IP_1}:${PORT_NGINX}"

  # v1.3.0 (2025.11.10)及之后 reality 使用 xtls-rprx-vision 流控替代多路复用 multiplex，但为了兼容旧版本已安装的客户端 URI，在这里作判断
  if [ -n "$PORT_XTLS_REALITY" ]; then
    local FLOW="$(awk -F '"' '/"flow"/{print $4}' ${WORK_DIR}/conf/*_${NODE_TAG[0]}_inbounds.json)"

    if [ "${FLOW}" = 'xtls-rprx-vision' ]; then
      local VISION_OR_MUX_SHADOWROCKET='xtls=2' && local VISION_FLOW='&flow=xtls-rprx-vision' && local VISION_OR_MUX_CLASH=', flow: xtls-rprx-vision' && local MULTIPLEX_PADDING_ENABLED='false' && local VISION_BRUTAL_ENABLED='false'
    else
      local VISION_OR_MUX_SHADOWROCKET='mux=1' && local MULTIPLEX_PADDING_ENABLED='true' && local VISION_BRUTAL_ENABLED="${IS_BRUTAL}"
    fi
  fi

  # 获取自签证书指纹。origin rules 或者 argo 回源的是由 Google Trust Services（谷歌信任服务）作为中间 CA（CN=WE1）签发，受信任的证书（非自签名）
  local SELF_SIGNED_FINGERPRINT_SHA256=$(openssl x509 -fingerprint -noout -sha256 -in ${WORK_DIR}/cert/cert.pem | awk -F '=' '{print $NF}')
  local SELF_SIGNED_FINGERPRINT_BASE64=$(openssl x509 -in ${WORK_DIR}/cert/cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64)

  local CERT_URL_1=$(awk '{printf "%s,", $0}' ${WORK_DIR}/cert/cert.pem | sed 's/ /%20/g; s/,$//') &&
  local CERT_URL_2=$(awk '{printf "%s\\r\\n", $0}' ${WORK_DIR}/cert/cert.pem)
  [ -s ${WORK_DIR}/cert/cert_200.pem ] &&
  local CERT_200_URL_1=$(awk '{printf "%s,", $0}' ${WORK_DIR}/cert/cert_200.pem | sed 's/,$//') &&
  local CERT_200_URL_2=$(awk '{printf "%s\\r\\n", $0}' ${WORK_DIR}/cert/cert_200.pem)

  # 从自签证书的 SAN 中读取当前使用的 SNI，优先取 SAN，退回到 CN
  local TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')

  # naive 协议的特殊处理
  if [ -n "$PORT_NAIVE" ]; then
    # 在 -n 查看节点时，如 cert_200.pem 过期 / 缺失 / SNI 不一致则自动更新
    ssl_certificate "$TLS_SERVER" naive_only

    # 读取 naive 自签证书并格式化为 JSON 字符串数组内容；多行/单行位置共用这一个变量
    local CERT200_JSON=$(awk 'BEGIN{sep=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s\"%s\"", sep, $0; sep=",\n"}' "${WORK_DIR}/cert/cert_200.pem")

    # 获取 naive 自签名证书的指纹
    local SELF_SIGNED_200_FINGERPRINT_SHA256=$(openssl x509 -fingerprint -noout -sha256 -in ${WORK_DIR}/cert/cert_200.pem | awk -F '=' '{print $NF}')
  fi

  # 生成各订阅文件
  # 生成 Clash proxy providers 订阅文件
  local CLASH_SUBSCRIBE='proxies:'

  [ -n "$PORT_XTLS_REALITY" ] && local CLASH_XTLS_REALITY="- {name: \"${NODE_NAME[11]} ${NODE_TAG[0]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_XTLS_REALITY}, uuid: ${UUID[11]}, network: tcp, udp: true, tls: true${VISION_OR_MUX_CLASH}, servername: ${TLS_SERVER}, client-fingerprint: ${FINGER_PRINT}, reality-opts: {public-key: ${REALITY_PUBLIC[11]}, short-id: \"\"}, smux: { enabled: ${MULTIPLEX_PADDING_ENABLED}, protocol: 'h2mux', padding: ${MULTIPLEX_PADDING_ENABLED}, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${VISION_BRUTAL_ENABLED}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_XTLS_REALITY
"
  if [ -n "$PORT_HYSTERIA2" ]; then
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && local CLASH_HOPPING=" ports: ${PORT_HOPPING_START}-${PORT_HOPPING_END}, hop-interval: 30,"
    local HY2_UP=${HY2_UP:-200}
    local HY2_DOWN=${HY2_DOWN:-1000}
    # 服务端忽略客户端带宽（BBR）时，各客户端订阅均不包含 up/down
    local HY2_CLASH_BW=" up: \"${HY2_UP} Mbps\", down: \"${HY2_DOWN} Mbps\","
    [ "$IS_HY2_IGNORE" = 'is_hy2_ignore' ] && HY2_CLASH_BW=""
    local CLASH_REALM_OPTS=""
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
      CLASH_REALM_OPTS=", realm-opts: {enable: true, server-url: \"https://realm.hy2.io\", token: public, realm-id: \"${HY2_REALM_ID}\", stun-servers: [turn.cloudflare.com:3478, stun.nextcloud.com:3478, stun.sip.us:3478, global.stun.twilio.com:3478]}"
    fi
    local CLASH_HYSTERIA2="- {name: \"${NODE_NAME[12]} ${NODE_TAG[1]}\", type: hysteria2, server: ${SERVER_IP}, port: ${PORT_HYSTERIA2},${CLASH_HOPPING}${HY2_CLASH_BW} password: ${UUID[12]}, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}${CLASH_REALM_OPTS}}" &&
    local CLASH_SUBSCRIBE+="
  $CLASH_HYSTERIA2
"
  fi

  [ -n "$PORT_TUIC" ] && local CLASH_TUIC="- {name: \"${NODE_NAME[13]} ${NODE_TAG[2]}\", type: tuic, server: ${SERVER_IP}, port: ${PORT_TUIC}, uuid: ${UUID[13]}, password: ${TUIC_PASSWORD}, alpn: [h3], reduce-rtt: true, request-timeout: 8000, udp-relay-mode: native, congestion-controller: $TUIC_CONGESTION_CONTROL, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}}" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TUIC
"
  [ -n "$PORT_SHADOWTLS" ] && local CLASH_SHADOWTLS="- {name: \"${NODE_NAME[14]} ${NODE_TAG[3]}\", type: ss, server: ${SERVER_IP}, port: ${PORT_SHADOWTLS}, cipher: $SHADOWTLS_METHOD, password: $SHADOWTLS_PASSWORD, plugin: shadow-tls, client-fingerprint: ${FINGER_PRINT}, plugin-opts: {host: ${TLS_SERVER}, password: \"${UUID[14]}\", version: 3}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWTLS
"

  [ -n "$PORT_SHADOWSOCKS" ] && local CLASH_SHADOWSOCKS="- {name: \"${NODE_NAME[15]} ${NODE_TAG[4]}\", type: ss, server: ${SERVER_IP}, port: $PORT_SHADOWSOCKS, cipher: ${SHADOWSOCKS_METHOD}, password: ${SHADOWSOCKS_PASSWORD}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_SHADOWSOCKS
"
  [ -n "$PORT_TROJAN" ] && local CLASH_TROJAN="- {name: \"${NODE_NAME[16]} ${NODE_TAG[5]}\", type: trojan, server: ${SERVER_IP}, port: $PORT_TROJAN, password: $TROJAN_PASSWORD, client-fingerprint: ${FINGER_PRINT}, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256}, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_TROJAN
"
  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_SERVER=$(format_uri_host "${CDN[17]}")
    if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local CLASH_VMESS_WS="- {name: \"${NODE_NAME[17]} ${NODE_TAG[6]}\", type: vmess, server: ${VMESS_CDN_SERVER}, port: ${VMESS_CDN_PORT}, uuid: ${UUID[17]}, udp: true, tls: false, alterId: 0, cipher: auto, network: ws, ws-opts: { path: \"/$VMESS_WS_PATH\", headers: {Host: $ARGO_DOMAIN} }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VMESS_WS
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && CLASH_SUBSCRIBE+="
  # $(text 94)
"
    else
      local CLASH_VMESS_WS="- {name: \"${NODE_NAME[17]} ${NODE_TAG[6]}\", type: vmess, server: ${VMESS_CDN_SERVER}, port: ${VMESS_CDN_PORT}, uuid: ${UUID[17]}, udp: true, tls: false, alterId: 0, cipher: auto, network: ws, ws-opts: { path: \"/$VMESS_WS_PATH\", headers: {Host: $VMESS_HOST_DOMAIN} }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && local TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && local TYPE_PORT_WS=$PORT_VMESS_WS &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VMESS_WS

  # $(text 52)
"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_SERVER=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local CLASH_VLESS_WS="- {name: \"${NODE_NAME[18]} ${NODE_TAG[7]}\", type: vless, server: ${VLESS_CDN_SERVER}, port: ${VLESS_CDN_PORT}, uuid: ${UUID[18]}, udp: true, tls: true, servername: $ARGO_DOMAIN, network: ws, skip-cert-verify: false, ws-opts: { path: \"/$VLESS_WS_PATH\", headers: {Host: $ARGO_DOMAIN}, max-early-data: 2560, early-data-header-name: Sec-WebSocket-Protocol }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VLESS_WS
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && CLASH_SUBSCRIBE+="
  # $(text 94)
"
    else
      local CLASH_VLESS_WS="- {name: \"${NODE_NAME[18]} ${NODE_TAG[7]}\", type: vless, server: ${VLESS_CDN_SERVER}, port: ${VLESS_CDN_PORT}, uuid: ${UUID[18]}, udp: true, tls: true, servername: $VLESS_HOST_DOMAIN, network: ws, skip-cert-verify: false, ws-opts: { path: \"/$VLESS_WS_PATH\", headers: {Host: $VLESS_HOST_DOMAIN}, max-early-data: 2560, early-data-header-name: Sec-WebSocket-Protocol }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && local TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && local TYPE_PORT_WS=$PORT_VLESS_WS &&
      local CLASH_SUBSCRIBE+="
  $CLASH_VLESS_WS

  # $(text 52)
"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local CLASH_H2_REALITY="- {name: \"${NODE_NAME[19]} ${NODE_TAG[8]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_H2_REALITY}, uuid: ${UUID[19]}, network: http, tls: true, servername: ${TLS_SERVER}, client-fingerprint: ${FINGER_PRINT}, reality-opts: { public-key: ${REALITY_PUBLIC[19]}, short-id: \"\" }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_H2_REALITY
"

  [ -n "$PORT_GRPC_REALITY" ] && local CLASH_GRPC_REALITY="- {name: \"${NODE_NAME[20]} ${NODE_TAG[9]}\", type: vless, server: ${SERVER_IP}, port: ${PORT_GRPC_REALITY}, uuid: ${UUID[20]}, network: grpc, tls: true, udp: true, flow: , client-fingerprint: ${FINGER_PRINT}, servername: ${TLS_SERVER}, grpc-opts: {  grpc-service-name: \"grpc\" }, reality-opts: { public-key: ${REALITY_PUBLIC[20]}, short-id: \"\" }, smux: { enabled: true, protocol: 'h2mux', padding: true, max-connections: '8', min-streams: '16', statistic: true, only-tcp: false }, brutal-opts: { enabled: ${IS_BRUTAL}, up: '1000 Mbps', down: '1000 Mbps' } }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_GRPC_REALITY
"

  [ -n "$PORT_ANYTLS" ] && local CLASH_ANYTLS="- {name: \"${NODE_NAME[21]} ${NODE_TAG[10]}\", type: anytls, server: ${SERVER_IP}, port: $PORT_ANYTLS, password: ${UUID[21]}, client-fingerprint: ${FINGER_PRINT}, udp: true, idle-session-check-interval: 30, idle-session-timeout: 30, sni: ${TLS_SERVER}, skip-cert-verify: false, fingerprint: ${SELF_SIGNED_FINGERPRINT_SHA256} }" &&
  local CLASH_SUBSCRIBE+="
  $CLASH_ANYTLS
"

  echo -n "${CLASH_SUBSCRIBE}" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' > ${WORK_DIR}/subscribe/proxies

  # 后台生成 clash 订阅配置文件
  {
    # 模板1 config.yaml: 使用 proxy providers
    cat ${TEMP_DIR}/config.yaml | sed "s#NODE_NAME#${NODE_NAME_CONFIRM}#g; s#PROXY_PROVIDERS_URL#$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/proxies#" > ${WORK_DIR}/subscribe/clash

    # 模板2 config-rule.yaml: 不使用 proxy providers，内嵌节点与规则
    CLASH2_PORT=("$PORT_XTLS_REALITY" "$PORT_HYSTERIA2" "$PORT_TUIC" "$PORT_SHADOWTLS" "$PORT_SHADOWSOCKS" "$PORT_TROJAN" "$PORT_VMESS_WS" "$PORT_VLESS_WS" "$PORT_GRPC_REALITY" "$PORT_ANYTLS")
    CLASH2_PROXY_INSERT=("$CLASH_XTLS_REALITY" "$CLASH_HYSTERIA2" "$CLASH_TUIC" "$CLASH_SHADOWTLS" "$CLASH_SHADOWSOCKS" "$CLASH_TROJAN" "$CLASH_VMESS_WS" "$CLASH_VLESS_WS" "$CLASH_GRPC_REALITY" "$CLASH_ANYTLS")
    CLASH2_PROXY_GROUPS_INSERT=("- ${NODE_NAME[11]} ${NODE_TAG[0]}" "- ${NODE_NAME[12]} ${NODE_TAG[1]}" "- ${NODE_NAME[13]} ${NODE_TAG[2]}" "- ${NODE_NAME[14]} ${NODE_TAG[3]}" "- ${NODE_NAME[15]} ${NODE_TAG[4]}" "- ${NODE_NAME[16]} ${NODE_TAG[5]}" "- ${NODE_NAME[17]} ${NODE_TAG[6]}" "- ${NODE_NAME[18]} ${NODE_TAG[7]}" "- ${NODE_NAME[20]} ${NODE_TAG[9]}" "- ${NODE_NAME[21]} ${NODE_TAG[10]}")

    CLASH2_YAML=$(cat ${TEMP_DIR}/config-rule.yaml)
    for x in ${!CLASH2_PORT[@]}; do
      [[ ${CLASH2_PORT[x]} =~ [0-9]+ ]] && { CLASH2_YAML=$(sed "/proxy-groups:/i\  ${CLASH2_PROXY_INSERT[x]}" <<< "$CLASH2_YAML"); CLASH2_YAML=$(sed -E "/- name: (♻️ 自动选择|📲 电报消息|💬 OpenAi|📹 油管视频|🎥 奈飞视频|📺 巴哈姆特|📺 哔哩哔哩|🌍 国外媒体|🌏 国内媒体|📢 谷歌FCM|Ⓜ️ 微软Bing|Ⓜ️ 微软云盘|Ⓜ️ 微软服务|🍎 苹果服务|🎮 游戏平台|🎶 网易音乐|🎯 全球直连)|^rules:$/i\      ${CLASH2_PROXY_GROUPS_INSERT[x]}" <<< "$CLASH2_YAML"); }
    done
    echo "$CLASH2_YAML" > ${WORK_DIR}/subscribe/clash2

    rm -f ${TEMP_DIR}/config.yaml ${TEMP_DIR}/config-rule.yaml
  } &>/dev/null

  # 生成 ShadowRocket 订阅配置文件
  [ -n "$PORT_XTLS_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID[11]}@${SERVER_IP_2}:${PORT_XTLS_REALITY}" | base64 -w0)?remarks=${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}&tls=1&peer=${TLS_SERVER}&${VISION_OR_MUX_SHADOWROCKET}&pbk=${REALITY_PUBLIC[11]}
"
  if [ -n "$PORT_HYSTERIA2" ]; then
    local SHADOWROCKET_PARAMS="peer=${TLS_SERVER}&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}&obfs=none"
    [ "$IS_HY2_IGNORE" != 'is_hy2_ignore' ] && SHADOWROCKET_PARAMS+="&upmbps=${HY2_UP}&downmbps=${HY2_DOWN}"
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && SHADOWROCKET_PARAMS+="&keepalive=30&mport=${PORT_HYSTERIA2},${PORT_HOPPING_START}-${PORT_HOPPING_END}"
    local SHADOWROCKET_SUBSCRIBE+="
hysteria2://${UUID[12]}@${SERVER_IP_1}:${PORT_HYSTERIA2}?${SHADOWROCKET_PARAMS}#${NODE_NAME[12]// /%20}%20${NODE_TAG[1]}
"
  fi
  [ -n "$PORT_TUIC" ] && local SHADOWROCKET_SUBSCRIBE+="
tuic://${TUIC_PASSWORD}:${UUID[13]}@${SERVER_IP_2}:${PORT_TUIC}?peer=${TLS_SERVER}&congestion_control=$TUIC_CONGESTION_CONTROL&udp_relay_mode=native&alpn=h3&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[13]// /%20}%20${NODE_TAG[2]}
"
  [ -n "$PORT_SHADOWTLS" ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "$SHADOWTLS_METHOD:$SHADOWTLS_PASSWORD@${SERVER_IP_2}:${PORT_SHADOWTLS}" | base64 -w0)?shadow-tls=$(echo -n "{\"version\":\"3\",\"host\":\"${TLS_SERVER}\",\"password\":\"${UUID[14]}\"}" | base64 -w0)#${NODE_NAME[14]// /%20}%20${NODE_TAG[3]}
"
  [ -n "$PORT_SHADOWSOCKS" ] && local SHADOWROCKET_SUBSCRIBE+="
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}@${SERVER_IP_2}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}
"
  [ -n "$PORT_TROJAN" ] && local SHADOWROCKET_SUBSCRIBE+="
trojan://${TROJAN_PASSWORD}@${SERVER_IP_1}:$PORT_TROJAN?peer=${TLS_SERVER}&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[16]// /%20}%20${NODE_TAG[5]}
"
  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "auto:${UUID[17]}@${VMESS_CDN_HOST}:${VMESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[17]// /%20}%20${NODE_TAG[6]}&obfsParam=$ARGO_DOMAIN&path=/$VMESS_WS_PATH&obfs=websocket&alterId=0
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && SHADOWROCKET_SUBSCRIBE+="
  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "auto:${UUID[17]}@${VMESS_CDN_HOST}:${VMESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[17]// /%20}%20${NODE_TAG[6]}&obfsParam=$VMESS_HOST_DOMAIN&path=/$VMESS_WS_PATH&obfs=websocket&alterId=0

# $(text 52)
"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n "auto:${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}&obfsParam=$ARGO_DOMAIN&path=/$VLESS_WS_PATH?ed=2560&obfs=websocket&tls=1&peer=$ARGO_DOMAIN
"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && SHADOWROCKET_SUBSCRIBE+="
  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n "auto:${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}" | base64 -w0)?remarks=${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}&obfsParam=$VLESS_HOST_DOMAIN&path=/$VLESS_WS_PATH?ed=2560&obfs=websocket&tls=1&peer=$VLESS_HOST_DOMAIN

# $(text 52)
"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
----------------------------
vless://$(echo -n auto:${UUID[19]}@${SERVER_IP_2}:${PORT_H2_REALITY} | base64 -w0)?remarks=${NODE_NAME[19]// /%20}%20${NODE_TAG[8]}&path=/&obfs=h2&tls=1&peer=${TLS_SERVER}&alpn=h2&mux=1&pbk=${REALITY_PUBLIC[19]}
"
  [ -n "$PORT_GRPC_REALITY" ] && local SHADOWROCKET_SUBSCRIBE+="
vless://$(echo -n "auto:${UUID[20]}@${SERVER_IP_2}:${PORT_GRPC_REALITY}" | base64 -w0)?remarks=${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}&path=grpc&obfs=grpc&tls=1&peer=${TLS_SERVER}&pbk=${REALITY_PUBLIC[20]}
"
  [ -n "$PORT_ANYTLS" ] && local SHADOWROCKET_SUBSCRIBE+="
anytls://${UUID[21]}@${SERVER_IP_1}:${PORT_ANYTLS}?peer=${TLS_SERVER}&udp=1&hpkp=${SELF_SIGNED_FINGERPRINT_SHA256}#${NODE_NAME[21]// /%20}%20${NODE_TAG[10]}
"
  [ -n "$PORT_NAIVE" ] && local SHADOWROCKET_SUBSCRIBE+="
http2://$(echo -n "${UUID[22]}:${UUID[22]}@${SERVER_IP_2}:${PORT_NAIVE}" | base64 -w0)?peer=${TLS_SERVER}&alpn=h2,http/1.1&padding=1&uot=2&hpkp=${SELF_SIGNED_200_FINGERPRINT_SHA256}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http2

http3://$(echo -n "${UUID[22]}:${UUID[22]}@${SERVER_IP_2}:${PORT_NAIVE}" | base64 -w0)?peer=${TLS_SERVER}&alpn=h3&padding=1&hpkp=${SELF_SIGNED_200_FINGERPRINT_SHA256}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http3
"
  echo -n "$SHADOWROCKET_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/shadowrocket

  # 生成 V2rayN 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[11]}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?encryption=none${VISION_FLOW}&security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC[11]}&type=tcp&headerType=none#${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}"

  if [ -n "$PORT_HYSTERIA2" ]; then
    # 各可选项统一以逗号结尾拼接，最后去除多余尾逗号，避免 BBR 模式下产生空字段/孤立逗号
    local V2RAYN_HY2_EXTRA=""
    [ "$IS_HY2_REALM" = 'is_hy2_realm' ] && V2RAYN_HY2_EXTRA+="\"Hy2RealmUrl\":\"realm://public@realm.hy2.io:443/${UUID[12]}?stun=stun.nextcloud.com:3478&stun=stun.sip.us:3478&stun=turn.cloudflare.com:3478&stun=global.stun.twilio.com:3478\","
    [ "$IS_HY2_IGNORE" != 'is_hy2_ignore' ] && V2RAYN_HY2_EXTRA+="\"UpMbps\":${HY2_UP:-200},\"DownMbps\":${HY2_DOWN:-1000},"
    [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]] && V2RAYN_HY2_EXTRA+="\"Ports\":\"${PORT_HOPPING_START}-${PORT_HOPPING_END}\",\"HopInterval\":\"30s\","
    V2RAYN_HY2_EXTRA=${V2RAYN_HY2_EXTRA%,}
    local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://hysteria2/$(echo -n "{\"ConfigType\":7,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[12]} ${NODE_TAG[1]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_HYSTERIA2},\"Password\":\"${UUID[12]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_URL_2}\",\"ProtoExtraObj\":{${V2RAYN_HY2_EXTRA}}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  fi

  [ -n "$PORT_TUIC" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://tuic/$(echo -n "{\"ConfigType\":8,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[13]} ${NODE_TAG[2]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_TUIC},\"Password\":\"${TUIC_PASSWORD}\",\"Username\":\"${UUID[13]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Alpn\":\"h3\",\"Cert\":\"${CERT_URL_2}\",\"ProtoExtraObj\":{\"CongestionControl\":\"bbr\"}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_SHADOWTLS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
{
    \"log\": {
        \"level\": \"warn\"
    },
    \"inbounds\": [
        {
            \"listen\": \"127.0.0.1\",
            \"listen_port\": ${PORT_SHADOWTLS},
            \"tag\": \"${PROTOCOL_LIST[3]}\",
            \"type\": \"mixed\"
        }
    ],
    \"outbounds\": [
        {
            \"detour\": \"shadowtls-out\",
            \"method\": \"$SHADOWTLS_METHOD\",
            \"password\": \"$SHADOWTLS_PASSWORD\",
            \"type\": \"shadowsocks\",
            \"udp_over_tcp\": false,
            \"multiplex\": {
              \"enabled\": true,
              \"protocol\": \"h2mux\",
              \"max_connections\": 8,
              \"min_streams\": 16,
              \"padding\": true
            }
        },
        {
            \"password\": \"${UUID[14]}\",
            \"server\": \"${SERVER_IP}\",
            \"server_port\": ${PORT_SHADOWTLS},
            \"tag\": \"shadowtls-out\",
            \"tls\": {
                \"enabled\": true,
                \"server_name\": \"${TLS_SERVER}\",
                \"utls\": {
                  \"enabled\": true,
                  \"fingerprint\": \"${FINGER_PRINT}\"
                }
            },
            \"type\": \"shadowtls\",
            \"version\": 3
        }
    ]
}"
  [ -n "$PORT_SHADOWSOCKS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}@${SERVER_IP_1}:$PORT_SHADOWSOCKS" | base64 -w0)#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}"

  [ -n "$PORT_TROJAN" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://trojan/$(echo -n "{\"ConfigType\":6,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[16]} ${NODE_TAG[5]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_TROJAN},\"Password\":\"${TROJAN_PASSWORD}\",\"Network\":\"raw\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

 if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local V2RAYN_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{ \"v\": \"2\", \"ps\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"add\": \"${VMESS_CDN_HOST}\", \"port\": \"${VMESS_CDN_PORT}\", \"id\": \"${UUID[17]}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"$ARGO_DOMAIN\", \"path\": \"/$VMESS_WS_PATH\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\" }" | base64 -w0)"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && V2RAYN_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local V2RAYN_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{ \"v\": \"2\", \"ps\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"add\": \"${VMESS_CDN_HOST}\", \"port\": \"${VMESS_CDN_PORT}\", \"id\": \"${UUID[17]}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"auto\", \"host\": \"$VMESS_HOST_DOMAIN\", \"path\": \"/$VMESS_WS_PATH\", \"tls\": \"\", \"sni\": \"\", \"alpn\": \"\" }" | base64 -w0)

# $(text 52)"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$VLESS_WS_PATH%3Fed%3D2560#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && V2RAYN_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?encryption=none&security=tls&sni=$VLESS_HOST_DOMAIN&type=ws&host=$VLESS_HOST_DOMAIN&path=%2F$VLESS_WS_PATH%3Fed%3D2560#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}

# $(text 52)"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://vless/$(echo -n "{\"ConfigType\":5,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[19]} ${NODE_TAG[8]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_H2_REALITY},\"Password\":\"${UUID[19]}\",\"Network\":\"raw\",\"StreamSecurity\":\"reality\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Fingerprint\":\"${FINGER_PRINT}\",\"PublicKey\":\"${REALITY_PUBLIC[19]}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_GRPC_REALITY" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
vless://${UUID[20]}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?encryption=none&security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC[20]}&type=grpc&serviceName=grpc&mode=gun#${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}"

  [ -n "$PORT_ANYTLS" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://anytls/$(echo -n "{\"ConfigType\":11,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[21]} ${NODE_TAG[10]}\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_ANYTLS},\"Password\":\"${UUID[21]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Fingerprint\":\"${FINGER_PRINT}\",\"Cert\":\"${CERT_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  [ -n "$PORT_NAIVE" ] && local V2RAYN_SUBSCRIBE+="
----------------------------
v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[22]} ${NODE_TAG[11]} http2\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_NAIVE},\"Password\":\"${UUID[22]}\",\"Username\":\"${UUID[22]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_200_URL_2}\"}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
----------------------------
v2rayn://naive/$(echo -n "{\"ConfigType\":12,\"CoreType\":24,\"ConfigVersion\":4,\"Remarks\":\"${NODE_NAME[22]} ${NODE_TAG[11]} quic\",\"Address\":\"${SERVER_IP}\",\"Port\":${PORT_NAIVE},\"Password\":\"${UUID[22]}\",\"Username\":\"${UUID[22]}\",\"StreamSecurity\":\"tls\",\"AllowInsecure\":\"false\",\"Sni\":\"${TLS_SERVER}\",\"Cert\":\"${CERT_200_URL_2}\",\"ProtoExtraObj\":{\"CongestionControl\":\"bbr\",\"NaiveQuic\":true}}" | base64 -w0 | tr '+/' '-_' | tr -d '=')"

  echo -n "$V2RAYN_SUBSCRIBE" | sed '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/d' | sed -E '/^[ ]*#|^[ ]+|^\{|^\}/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/v2rayn

  # 生成 Throne 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[11]}@${SERVER_IP_1}:${PORT_XTLS_REALITY}?security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC[11]}&type=tcp${VISION_FLOW}&encryption=none#${NODE_NAME[11]// /%20}%20${NODE_TAG[0]}"

  if [ -n "$PORT_HYSTERIA2" ]; then
    local THRONE_PARAMS="allowInsecure=false&alpn&security=tls&sni=${TLS_SERVER}"
    [ "$IS_HY2_IGNORE" != 'is_hy2_ignore' ] && THRONE_PARAMS+="&upmbps=${HY2_UP}&downmbps=${HY2_DOWN}"
    THRONE_PARAMS+="&security=tls&tls_certificate=${CERT_URL_1}"
    if [[ -n "$PORT_HOPPING_START" && -n "$PORT_HOPPING_END" ]]; then
      THRONE_PARAMS+="&mport=${PORT_HOPPING_START}-${PORT_HOPPING_END}&hop_interval=30s"
    fi
    local THRONE_SUBSCRIBE+="
----------------------------
hysteria2://${UUID[12]}@${SERVER_IP_1}:${PORT_HYSTERIA2}?${THRONE_PARAMS}#${NODE_NAME[12]// /%20}%20${NODE_TAG[1]}"
  fi

  [ -n "$PORT_TUIC" ] && local THRONE_SUBSCRIBE+="
----------------------------
tuic://${TUIC_PASSWORD}:${UUID[13]}@${SERVER_IP_1}:${PORT_TUIC}?congestion_control=$TUIC_CONGESTION_CONTROL&alpn=h3&sni=${TLS_SERVER}&udp_relay_mode=native&allow_insecure=0&security=tls&tls_certificate=${CERT_URL_1}#${NODE_NAME[13]// /%20}%20${NODE_TAG[2]}"
  [ -n "$PORT_SHADOWTLS" ] && local THRONE_SUBSCRIBE+="
----------------------------
shadowtls://:${UUID[14]}@${SERVER_IP_1}:${PORT_SHADOWTLS}?version=3&security=tls&sni=${TLS_SERVER}&fp=chrome#1-tls-not-use

ss://${SHADOWTLS_METHOD}:${SHADOWTLS_PASSWORD}@127.0.0.1:0#2-ss-not-use"

  [ -n "$PORT_SHADOWSOCKS" ] && local THRONE_SUBSCRIBE+="
----------------------------
ss://$(echo -n "${SHADOWSOCKS_METHOD}:${SHADOWSOCKS_PASSWORD}" | base64 -w0)@${SERVER_IP_1}:$PORT_SHADOWSOCKS#${NODE_NAME[15]// /%20}%20${NODE_TAG[4]}"

  [ -n "$PORT_TROJAN" ] && local THRONE_SUBSCRIBE+="
----------------------------
trojan://${TROJAN_PASSWORD}@${SERVER_IP_1}:$PORT_TROJAN?security=tls&sni=${TLS_SERVER}&allowInsecure=0&tls_certificate=${CERT_URL_1}&fp=${FINGER_PRINT}&type=tcp#${NODE_NAME[16]// /%20}%20${NODE_TAG[5]}"

  if [ -n "$PORT_VMESS_WS" ]; then
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      THRONE_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{\"add\":\"${CDN[17]}\",\"aid\":\"0\",\"host\":\"$ARGO_DOMAIN\",\"id\":\"${UUID[17]}\",\"net\":\"ws\",\"path\":\"/$VMESS_WS_PATH\",\"port\":\"80\",\"ps\":\"${NODE_NAME[17]} ${NODE_TAG[6]}\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0)"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && THRONE_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} && TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VMESS_WS && local THRONE_SUBSCRIBE+="
----------------------------
vmess://$(echo -n "{\"add\":\"${CDN[17]}\",\"aid\":\"0\",\"host\":\"$VMESS_HOST_DOMAIN\",\"id\":\"${UUID[17]}\",\"net\":\"ws\",\"path\":\"/$VMESS_WS_PATH\",\"port\":\"80\",\"ps\":\"${NODE_NAME[17]} ${NODE_TAG[6]}\",\"scy\":\"auto\",\"sni\":\"\",\"tls\":\"\",\"type\":\"\",\"v\":\"2\"}" | base64 -w0)

# $(text 52)"
    fi
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?security=tls&sni=$ARGO_DOMAIN&type=ws&path=/$VLESS_WS_PATH?ed%3D2560&host=$ARGO_DOMAIN&encryption=none#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && THRONE_SUBSCRIBE+="

  # $(text 94)
"
    else
      WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} && TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN && TYPE_PORT_WS=$PORT_VLESS_WS && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[18]}@${VLESS_CDN_HOST}:${VLESS_CDN_PORT}?security=tls&sni=$VLESS_HOST_DOMAIN&type=ws&path=/$VLESS_WS_PATH?ed%3D2560&host=$VLESS_HOST_DOMAIN&encryption=none#${NODE_NAME[18]// /%20}%20${NODE_TAG[7]}

# $(text 52)"
    fi
  fi

  [ -n "$PORT_H2_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[19]}@${SERVER_IP_1}:${PORT_H2_REALITY}?security=reality&sni=${TLS_SERVER}&alpn=h2&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC[19]// /%20}&type=http&encryption=none#${NODE_NAME[19]// /%20}%20${NODE_TAG[8]}"

  [ -n "$PORT_GRPC_REALITY" ] && local THRONE_SUBSCRIBE+="
----------------------------
vless://${UUID[20]}@${SERVER_IP_1}:${PORT_GRPC_REALITY}?security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC[20]// /%20}&type=grpc&serviceName=grpc&encryption=none#${NODE_NAME[20]// /%20}%20${NODE_TAG[9]}"

  [ -n "$PORT_ANYTLS" ] && local THRONE_SUBSCRIBE+="
----------------------------
anytls://${UUID[21]}@${SERVER_IP_1}:${PORT_ANYTLS}?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&insecure=0&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_URL_1}&fp=${FINGER_PRINT}#${NODE_NAME[21]// /%20}%20${NODE_TAG[10]}"

  [ -n "$PORT_NAIVE" ] && {
    local THRONE_SUBSCRIBE+="
----------------------------
naive+https://${UUID[22]}:${UUID[22]}@${SERVER_IP_1}:${PORT_NAIVE}?uot=1&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_200_URL_1}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20http2
----------------------------
naive+quic://${UUID[22]}:${UUID[22]}@${SERVER_IP_1}:${PORT_NAIVE}?congestion_control=bbr&security=tls&sni=${TLS_SERVER}&tls_certificate=${CERT_200_URL_1}#${NODE_NAME[22]// /%20}%20${NODE_TAG[11]}%20quic"
  }

  echo -n "$THRONE_SUBSCRIBE" | sed -E '/^[ ]*#|^--/d' | sed '/^$/d' | base64 -w0 > ${WORK_DIR}/subscribe/throne

  # 生成 Sing-box 订阅文件
  [ -n "$PORT_XTLS_REALITY" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[11]} ${NODE_TAG[0]}\", \"server\":\"${SERVER_IP}\", \"server_port\":${PORT_XTLS_REALITY}, \"uuid\":\"${UUID[11]}\", \"flow\":\"${FLOW}\", \"tls\":{ \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\":{ \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[11]}\", \"short_id\":\"\" } }, \"multiplex\": { \"enabled\": ${MULTIPLEX_PADDING_ENABLED}, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": ${MULTIPLEX_PADDING_ENABLED}, \"brutal\":{ \"enabled\":${VISION_BRUTAL_ENABLED}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[11]} ${NODE_TAG[0]}\","

  if [ -n "$PORT_HYSTERIA2" ]; then
    local HYSTERIA2_CONFIG=" { \"type\": \"hysteria2\", \"tag\": \"${NODE_NAME[12]} ${NODE_TAG[1]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_HYSTERIA2},"
    [ "$IS_HY2_IGNORE" != 'is_hy2_ignore' ] && HYSTERIA2_CONFIG+=" \"up_mbps\": ${HY2_UP}, \"down_mbps\": ${HY2_DOWN},"
    HYSTERIA2_CONFIG+=" \"password\": \"${UUID[12]}\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"alpn\": [ \"h3\" ] }"
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
      HYSTERIA2_CONFIG+=", \"realm\": { \"server_url\": \"https://realm.hy2.io\", \"token\": \"public\", \"realm_id\": \"${HY2_REALM_ID}\", \"stun_servers\": [ \"turn.cloudflare.com:3478\", \"stun.nextcloud.com:3478\", \"stun.sip.us:3478\", \"global.stun.twilio.com:3478\" ] }"
    fi
    HYSTERIA2_CONFIG+=" },"
    if [[ -n "${PORT_HOPPING_START}" && -n "${PORT_HOPPING_END}" ]]; then
      HYSTERIA2_CONFIG="${HYSTERIA2_CONFIG/\"server_port\": ${PORT_HYSTERIA2},/\"server_port\": ${PORT_HYSTERIA2}, \"server_ports\": [ \"${PORT_HOPPING_START}:${PORT_HOPPING_END}\" ], \"hop_interval\": \"30s\", \"hop_interval_max\": \"60s\",}"
    fi
    local OUTBOUND_REPLACE+="${HYSTERIA2_CONFIG}"
    local NODE_REPLACE+="\"${NODE_NAME[12]} ${NODE_TAG[1]}\","
  fi

  [ -n "$PORT_TUIC" ] &&
  local TUIC_INBOUND=" { \"type\": \"tuic\", \"tag\": \"${NODE_NAME[13]} ${NODE_TAG[2]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_TUIC}, \"uuid\": \"${UUID[13]}\", \"password\": \"${TUIC_PASSWORD}\", \"congestion_control\": \"$TUIC_CONGESTION_CONTROL\", \"udp_relay_mode\": \"native\", \"zero_rtt_handshake\": false, \"heartbeat\": \"10s\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"alpn\": [ \"h3\" ] } }," &&
  local OUTBOUND_REPLACE+="${TUIC_INBOUND}" &&
  local NODE_REPLACE+="\"${NODE_NAME[13]} ${NODE_TAG[2]}\","

  [ -n "$PORT_SHADOWTLS" ] &&
  local SHADOWTLS_INBOUND=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME[14]} ${NODE_TAG[3]}\", \"method\": \"$SHADOWTLS_METHOD\", \"password\": \"$SHADOWTLS_PASSWORD\", \"detour\": \"shadowtls-out\", \"udp_over_tcp\": false, \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }, { \"type\": \"shadowtls\", \"tag\": \"shadowtls-out\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_SHADOWTLS}, \"version\": 3, \"password\": \"${UUID[14]}\", \"tls\": { \"enabled\": true, \"server_name\": \"${TLS_SERVER}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"${FINGER_PRINT}\" } } }," &&
  local OUTBOUND_REPLACE+="${SHADOWTLS_INBOUND}" &&
  local NODE_REPLACE+="\"${NODE_NAME[14]} ${NODE_TAG[3]}\","

  [ -n "$PORT_SHADOWSOCKS" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"shadowsocks\", \"tag\": \"${NODE_NAME[15]} ${NODE_TAG[4]}\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_SHADOWSOCKS, \"method\": \"${SHADOWSOCKS_METHOD}\", \"password\": \"${SHADOWSOCKS_PASSWORD}\", \"multiplex\": { \"enabled\": true, \"protocol\": \"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[15]} ${NODE_TAG[4]}\","

  [ -n "$PORT_TROJAN" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"trojan\", \"tag\": \"${NODE_NAME[16]} ${NODE_TAG[5]}\", \"server\": \"${SERVER_IP}\", \"server_port\": $PORT_TROJAN, \"password\": \"$TROJAN_PASSWORD\", \"tls\": { \"enabled\": true, \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_connections\": 8, \"min_streams\": 16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[16]} ${NODE_TAG[5]}\","

  if [ -n "$PORT_VMESS_WS" ]; then
    local VMESS_CDN_PORT=${CDN_PORT[17]:-80}
    local VMESS_CDN_HOST=$(format_uri_host "${CDN[17]}")
     if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local OUTBOUND_REPLACE+=" { \"type\": \"vmess\", \"tag\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"server\":\"${VMESS_CDN_HOST}\", \"server_port\":${VMESS_CDN_PORT}, \"uuid\": \"${UUID[17]}\", \"security\": \"auto\", \"transport\": { \"type\":\"ws\", \"path\":\"/$VMESS_WS_PATH\", \"headers\": { \"Host\": \"$ARGO_DOMAIN\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && [ -z "$PROMPT" ] && local PROMPT="
  # $(text 94)"
    else
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[17]} &&
      local TYPE_HOST_DOMAIN=$VMESS_HOST_DOMAIN &&
      local TYPE_PORT_WS=$PORT_VMESS_WS &&
      local PROMPT+="
      # $(text 52)" &&
      local OUTBOUND_REPLACE+=" { \"type\": \"vmess\", \"tag\": \"${NODE_NAME[17]} ${NODE_TAG[6]}\", \"server\":\"${VMESS_CDN_HOST}\", \"server_port\":${VMESS_CDN_PORT}, \"uuid\":\"${UUID[17]}\", \"security\": \"auto\", \"transport\": { \"type\":\"ws\", \"path\":\"/$VMESS_WS_PATH\", \"headers\": { \"Host\": \"$VMESS_HOST_DOMAIN\" } }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
    fi
    local NODE_REPLACE+="\"${NODE_NAME[17]} ${NODE_TAG[6]}\","
  fi

  if [ -n "$PORT_VLESS_WS" ]; then
    local VLESS_CDN_PORT=${CDN_PORT[18]:-443}
    local VLESS_CDN_HOST=$(format_uri_host "${CDN[18]}")
    if [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] || [[ "$IS_ARGO" = 'is_argo' && "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]]; then
      local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[18]} ${NODE_TAG[7]}\", \"server\":\"${VLESS_CDN_HOST}\", \"server_port\":${VLESS_CDN_PORT}, \"uuid\": \"${UUID[18]}\", \"tls\": { \"enabled\":true, \"server_name\":\"$ARGO_DOMAIN\", \"insecure\": false, \"utls\": { \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/$VLESS_WS_PATH\", \"headers\": { \"Host\": \"$ARGO_DOMAIN\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
      [ "$ARGO_TYPE" = 'is_token_argo' ] && [ -z "$PROMPT" ] && local PROMPT="
  # $(text 94)"
    else
      local WS_SERVER_IP_SHOW=${WS_SERVER_IP[18]} &&
      local TYPE_HOST_DOMAIN=$VLESS_HOST_DOMAIN &&
      local TYPE_PORT_WS=$PORT_VLESS_WS &&
      local PROMPT+="
      # $(text 52)" &&
      local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[18]} ${NODE_TAG[7]}\", \"server\":\"${VLESS_CDN_HOST}\", \"server_port\":${VLESS_CDN_PORT}, \"uuid\": \"${UUID[18]}\",\"tls\": { \"enabled\":true, \"server_name\":\"$VLESS_HOST_DOMAIN\", \"insecure\": false, \"utls\": { \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" } }, \"transport\": { \"type\":\"ws\", \"path\":\"/$VLESS_WS_PATH\", \"headers\": { \"Host\": \"$VLESS_HOST_DOMAIN\" }, \"max_early_data\":2560, \"early_data_header_name\":\"Sec-WebSocket-Protocol\" }, \"multiplex\": { \"enabled\":true, \"protocol\":\"h2mux\", \"max_streams\":16, \"padding\": true, \"brutal\":{ \"enabled\":${IS_BRUTAL}, \"up_mbps\":1000, \"down_mbps\":1000 } } },"
    fi
    local NODE_REPLACE+="\"${NODE_NAME[18]} ${NODE_TAG[7]}\","
  fi

  [ -n "$PORT_H2_REALITY" ] &&
  local REALITY_H2_INBOUND=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[19]} ${NODE_TAG[8]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_H2_REALITY}, \"uuid\":\"${UUID[19]}\", \"tls\": { \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[19]}\", \"short_id\":\"\" } }, \"transport\": { \"type\": \"http\" } }," &&
  local REALITY_H2_NODE="\"${NODE_NAME[19]} ${NODE_TAG[8]}\"" &&
  local NODE_REPLACE+="${REALITY_H2_NODE}," &&
  local OUTBOUND_REPLACE+=" ${REALITY_H2_INBOUND}"

  [ -n "$PORT_GRPC_REALITY" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"vless\", \"tag\": \"${NODE_NAME[20]} ${NODE_TAG[9]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_GRPC_REALITY}, \"uuid\":\"${UUID[20]}\", \"tls\": { \"enabled\":true, \"server_name\":\"${TLS_SERVER}\", \"utls\": { \"enabled\":true, \"fingerprint\":\"${FINGER_PRINT}\" }, \"reality\":{ \"enabled\":true, \"public_key\":\"${REALITY_PUBLIC[20]}\", \"short_id\":\"\" } }, \"transport\": { \"type\": \"grpc\", \"service_name\": \"grpc\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[20]} ${NODE_TAG[9]}\","

  [ -n "$PORT_ANYTLS" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"anytls\", \"tag\": \"${NODE_NAME[21]} ${NODE_TAG[10]}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_ANYTLS}, \"password\": \"${UUID[21]}\", \"idle_session_check_interval\": \"30s\", \"idle_session_timeout\": \"30s\", \"min_idle_session\": 5, \"tls\": { \"enabled\": true, \"certificate_public_key_sha256\": [\"$SELF_SIGNED_FINGERPRINT_BASE64\"], \"server_name\": \"${TLS_SERVER}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"${FINGER_PRINT}\" } } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[21]} ${NODE_TAG[10]}\","

  [ -n "$PORT_NAIVE" ] &&
  local OUTBOUND_REPLACE+=" { \"type\": \"naive\", \"tag\": \"${NODE_NAME[22]} ${NODE_TAG[11]} http2\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_NAIVE}, \"username\": \"${UUID[22]}\", \"password\": \"${UUID[22]}\", \"udp_over_tcp\": true, \"quic\": false, \"tls\": { \"enabled\": true, \"certificate\": [$(tr -d '\n' <<< "$CERT200_JSON")], \"server_name\": \"${TLS_SERVER}\" } }, { \"type\": \"naive\", \"tag\": \"${NODE_NAME[22]} ${NODE_TAG[11]} quic\", \"server\": \"${SERVER_IP}\", \"server_port\": ${PORT_NAIVE}, \"username\": \"${UUID[22]}\", \"password\": \"${UUID[22]}\", \"udp_over_tcp\": false, \"quic\": true, \"quic_congestion_control\": \"bbr\", \"tls\": { \"enabled\": true, \"certificate\": [$(tr -d '\n' <<< "$CERT200_JSON")], \"server_name\": \"${TLS_SERVER}\" } }," &&
  local NODE_REPLACE+="\"${NODE_NAME[22]} ${NODE_TAG[11]} http2\",\"${NODE_NAME[22]} ${NODE_TAG[11]} quic\","

  {
    # 生成 sing-box SFM SFA SFI 订阅文件
    [ ! -s "$TEMP_DIR/config.json" ] && wget --no-check-certificate --continue --tries=2 --timeout=10 -qO "$TEMP_DIR/config.json" "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/config.json" 2>/dev/null
    cat $TEMP_DIR/config.json | sed "s#\"<OUTBOUND_REPLACE>\",#$OUTBOUND_REPLACE#; s#\"<NODE_REPLACE>\"#${NODE_REPLACE%,}#g" | ${WORK_DIR}/jq > ${WORK_DIR}/subscribe/sing-box
    rm -f $TEMP_DIR/config.json
  } &>/dev/null

  # 生成二维码 url 文件
  [ "$IS_SUB" = 'is_sub' ] && cat > ${WORK_DIR}/subscribe/qr << EOF
$(text 81):
$(text 82) 1:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

$(text 80) QRcode:
$(text 82) 1:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

$(text 82) 1:
$(${WORK_DIR}/qrencode "$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto")

$(text 82) 2:
$(${WORK_DIR}/qrencode "$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2")
EOF

  # 生成配置文件
  EXPORT_LIST_FILE="*******************************************
┌────────────────┐
│                │
│     $(warning "V2rayN")     │
│                │
└────────────────┘
$(info "${V2RAYN_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│  $(warning "ShadowRocket")  │
│                │
└────────────────┘
----------------------------
$(hint "${SHADOWROCKET_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│   $(warning "Clash Verge")  │
│                │
└────────────────┘
----------------------------

$(info "$(sed '1d' <<< "${CLASH_SUBSCRIBE}")")

*******************************************
┌────────────────┐
│                │
│     $(warning "Throne")     │
│                │
└────────────────┘
$(hint "${THRONE_SUBSCRIBE}")

*******************************************
┌────────────────┐
│                │
│    $(warning "Sing-box")    │
│                │
└────────────────┘
----------------------------

$(info "$(echo "{ \"outbounds\":[ ${OUTBOUND_REPLACE%,} ] }" | ${WORK_DIR}/jq)

${PROMPT}

 $(text 72)")
"

  [ "$IS_SUB" = 'is_sub' ] && EXPORT_LIST_FILE+="

*******************************************

$(hint "Index:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/

QR code:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/qr

V2rayN $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/v2rayn")

$(hint "Throne $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/throne")

$(hint "Clash $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/clash
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/clash2

SFI / SFA / SFM $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/sing-box

ShadowRocket $(text 80):
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/shadowrocket")

*******************************************

$(info " $(text 81):
$(text 82) 1:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2

 $(text 80) QRcode:
$(text 82) 1:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto

$(text 82) 2:
https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2")

$(hint "$(text 82) 1:")
$(${WORK_DIR}/qrencode $SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto)

$(hint "$(text 82) 2:")
$(${WORK_DIR}/qrencode $SUBSCRIBE_ADDRESS/${UUID_CONFIRM}/auto2)
"

  # === 流量统计块（仅 clash_api 可用时显示；流量为 0 时显示 0 B） ===
  # downloadTotal / uploadTotal 为 clash_api 提供的进程生命周期累计值
  STATS_JSON=''   # 每次调用 export_list 都是独立的用户请求，强制刷新获取实时数据
  if ensure_stats_data; then
    local IN_SUM OUT_SUM
    IN_SUM=$(echo "$STATS_JSON" | $WORK_DIR/jq '.downloadTotal // 0' 2>/dev/null)
    OUT_SUM=$(echo "$STATS_JSON" | $WORK_DIR/jq '.uploadTotal // 0' 2>/dev/null)
    EXPORT_LIST_FILE="${EXPORT_LIST_FILE}

*******************************************
┌────────────────┐
│                │
│  $(warning "Traffic Stats") │
│                │
└────────────────┘
---------------------------

$(info "⬇ Inbound  (total):  $(format_traffic $IN_SUM)")
$(hint "⬆ Outbound (total):  $(format_traffic $OUT_SUM)")
"
  fi
  # === 结束 ===

  # 生成并显示节点信息
  echo "$EXPORT_LIST_FILE" > ${WORK_DIR}/list
  cat ${WORK_DIR}/list

  # 显示脚本使用情况数据
  statistics_of_run_times get
}

# 创建快捷方式
create_shortcut() {
  cat > ${WORK_DIR}/sb.sh << EOF
#!/usr/bin/env bash

bash <(wget --no-check-certificate -qO- ${PROJECT_SCRIPT_URL}) \$@
EOF
  chmod +x ${WORK_DIR}/sb.sh
  ln -sf ${WORK_DIR}/sb.sh /usr/bin/sb
  [ -s /usr/bin/sb ] && info "\n $(text 71) "
}
