# ------------------------------------------------------------------------------
# 十四、服务端基础配置生成 / Base server configuration generation
# ------------------------------------------------------------------------------
# 生成 sing-box 基础配置
generate_sing_box_base_conf() {
  # 生成 log 配置
  cat > ${WORK_DIR}/conf/00_log.json << EOF
{
    "log":{
        "disabled":false,
        "level":"error",
        "output":"${WORK_DIR}/logs/box.log",
        "timestamp":true
    }
}
EOF

  # 生成 outbound 配置
  cat > ${WORK_DIR}/conf/01_outbounds.json << EOF
{
    "outbounds":[
        {
            "type":"direct",
            "tag":"direct"${BIND_INTERFACE:+,
            "bind_interface":"${BIND_INTERFACE}"}
        }
    ]
}
EOF

  # 生成 endpoint 配置：仅在支持 TUN 时生成 wireguard warp-ep 出站。
  # 无 TUN（Hax / OpenVZ / 部分容器）无法创建 wireguard 出站，跳过注册与生成，避免 sing-box 启动失败。
  if [ "$IS_TUN" = 'is_tun' ]; then
    # 优先复用安装期后台预注册的缓存，否则在线注册；均失败回退共享账户
    if [ -s $TEMP_DIR/warp_account.json ] && warp_account_register "$(< "$TEMP_DIR/warp_account.json")"; then
      rm -f "$TEMP_DIR/warp_account.json"
    elif ! warp_account_register; then
      WARP_ADDRESS6="2606:4700:110:8a36:df92:102a:9602:fa18"
      WARP_PRIVATE_KEY="YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY="
      WARP_RESERVED[1]=78
      WARP_RESERVED[2]=135
      WARP_RESERVED[3]=76
    fi

    cat > ${WORK_DIR}/conf/02_endpoints.json << EOF
{
    "endpoints":[
        {
            "type":"wireguard",
            "tag":"warp-ep",
            "mtu":1400,
            "address":[
                "172.16.0.2/32",
                "${WARP_ADDRESS6}/128"
            ],
            "private_key":"${WARP_PRIVATE_KEY}",
            "peers": [
              {
                "address": "engage.cloudflareclient.com",
                "port":2408,
                "public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "allowed_ips": [
                  "0.0.0.0/0",
                  "::/0"
                ],
                "reserved":[
                    ${WARP_RESERVED[1]},
                    ${WARP_RESERVED[2]},
                    ${WARP_RESERVED[3]}
                ]
              }
            ]
        }
    ]
}
EOF
  fi

  # 生成 route 配置。OpenAI 分流依赖 warp-ep 出站，仅在支持 TUN 时添加
  # geosite-openai 规则集与分流规则；无 TUN 时保留通用 sniff / resolve 规则即可
  local OPENAI_RULE_SET OPENAI_RULES
  if [ "$IS_TUN" = 'is_tun' ]; then
    OPENAI_RULE_SET='[
            {
                "tag":"geosite-openai",
                "type":"remote",
                "format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
            }
        ]'
    OPENAI_RULES=",
            {
                \"action\": \"resolve\",
                \"domain\":[
                    \"api.openai.com\"
                ],
                \"strategy\": \"prefer_ipv4\"
            },
            {
                \"action\": \"resolve\",
                \"rule_set\":[
                    \"geosite-openai\"
                ],
                \"strategy\": \"prefer_ipv6\"
            },
            {
                \"domain\":[
                    \"api.openai.com\"
                ],
                \"rule_set\":[
                    \"geosite-openai\"
                ],
                \"outbound\":\"${CHATGPT_OUT:-direct}\"
            }"
  else
    OPENAI_RULE_SET='[]'
    OPENAI_RULES=''
  fi

  cat > ${WORK_DIR}/conf/03_route.json << EOF
{
    "route":{
        "default_http_client": "http-client-direct",
        "rule_set":${OPENAI_RULE_SET},
        "rules":[
            {
                "action": "sniff"
            }${OPENAI_RULES}
        ]
    }
}
EOF

  # 生成缓存文件 + clash_api 流量统计。clash_api 是官方二进制默认编译功能
  # （with_clash_api 在 DEFAULT_BUILD_TAGS 中），无版本门控；无需枚举
  # inbound/outbound tag（clash_api 默认统计所有流量）。
  # 新装场景（generate_sing_box_base_conf 由 sing-box_json 首次调用）inbound 尚未生成
  # 也不影响 clash_api 注入，此处统一直接写入。
  CLASH_API_PORT=$(find_free_api_port)
  cat > ${WORK_DIR}/conf/04_experimental.json << EOF
{
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "${WORK_DIR}/cache.db"
        },
        "clash_api": {
            "external_controller": "127.0.0.1:${CLASH_API_PORT}"
        }
    }
}
EOF

  # 生成 dns 配置文件
  cat > ${WORK_DIR}/conf/05_dns.json << EOF
{
    "dns":{
        "servers":[
            {
                "type":"local",
                "prefer_go": ${IS_PREFER_GO}
            }
        ],
        "strategy": "${STRATEGY}"
    }
}
EOF

  # 内建的 NTP 客户端服务配置文件，这对于无法进行时间同步的环境很有用
  cat > ${WORK_DIR}/conf/06_ntp.json << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

  # 专门给 sing-box 内部组件发 HTTP 请求用，比如这些场景会用到它：下载远程 rule_set：.srs 规则文件，ACME 申请证书，Cloudflare Origin CA 证书提供器，DERP / Tailscale 相关 HTTP 请求
  cat > ${WORK_DIR}/conf/07_http_clients.json << EOF
{
    "http_clients": [
        {
            "tag": "http-client-direct"
        }
    ]
}
EOF
}

# 生成 sing-box 配置文件
sing-box_json() {
  local IS_CHANGE=$1
  mkdir -p ${WORK_DIR}/conf ${WORK_DIR}/logs ${WORK_DIR}/subscribe

  # 判断是否为新安装，不为 change 就是新安装
  if [ "$IS_CHANGE" = 'change' ]; then
    # 判断 sing-box 主程序所在路径
    DIR=${WORK_DIR}
  else
    DIR=$TEMP_DIR
    generate_sing_box_base_conf
  fi

  # 生成 Reality 公私钥，第一次安装的时候，如有指定的私钥，则使用该私钥及生成对应的公钥；如没有指定私钥则使用新生成的；添加协议的时，使用相应数组里的第一个非空值，如全空则像第一次安装那样使用新生成的
  generate_reality_keypair() {
    [ "$1" = 'convert_error' ] && hint " $(text 116) "
    REALITY_KEYPAIR=$($DIR/sing-box generate reality-keypair) && REALITY_PRIVATE=$(awk '/PrivateKey/{print $NF}' <<< "$REALITY_KEYPAIR") && REALITY_PUBLIC=$(awk '/PublicKey/{print $NF}' <<< "$REALITY_KEYPAIR")
  }

  if [[ "${#REALITY_PRIVATE}" = 43 && "${#REALITY_PUBLIC}" = 0 ]]; then
    if command -v xxd >/dev/null 2>&1; then
      until [ -n "$REALITY_PUBLIC" ]; do
        # convert base64url -> base64 (standard), add padding
        local B64=$(printf '%s' "$REALITY_PRIVATE" | tr '_-' '/+')
        local MOD=$(( ${#B64} % 4 ))
        if [ $MOD -eq 2 ]; then
          B64="${B64}=="
        elif [ $MOD -eq 3 ]; then
          B64="${B64}="
        elif [ $MOD -eq 1 ]; then
          generate_reality_keypair convert_error
          continue
        fi

        # decode to raw 32 bytes
        echo "$B64" | base64 -d > $TEMP_DIR/_X25519_PRIV_RAW || { generate_reality_keypair convert_error; continue; }

        local PRIV_LEN=$(stat -c%s $TEMP_DIR/_X25519_PRIV_RAW 2>/dev/null || stat -f%z $TEMP_DIR/_X25519_PRIV_RAW)
        [ "$PRIV_LEN" -ne 32 ] && { generate_reality_keypair convert_error; continue; }

        # DER prefix for PKCS#8 private key with OID 1.3.101.110 (X25519)
        # Hex: 30 2e 02 01 00 30 05 06 03 2b 65 6e 04 22 04 20
        local PREFIX_HEX="302e020100300506032b656e04220420"

        # append raw private key hex and create DER
        local PRIV_HEX=$(xxd -p -c 256 $TEMP_DIR/_X25519_PRIV_RAW | tr -d '\n')
        printf "%s%s" "$PREFIX_HEX" "$PRIV_HEX" | xxd -r -p > $TEMP_DIR/_X25519_PRIV_DER

        # convert DER PKCS8 -> PEM private key
        openssl pkcs8 -inform DER -in $TEMP_DIR/_X25519_PRIV_DER -nocrypt -out $TEMP_DIR/_X25519_PRIV_PEM 2>/dev/null

        # extract public key in DER
        openssl pkey -in $TEMP_DIR/_X25519_PRIV_PEM -pubout -outform DER > $TEMP_DIR/_X25519_PUB_DER 2>/dev/null

        # last 32 bytes are the raw public key
        tail -c 32 $TEMP_DIR/_X25519_PUB_DER > $TEMP_DIR/_X25519_PUB_RAW

        # encode to base64url (no padding)
        REALITY_PUBLIC=$(base64 -w0 $TEMP_DIR/_X25519_PUB_RAW | tr '+/' '-_' | sed -E 's/=+$//')
      done
    else
      REALITY_PUBLIC=$(wget --no-check-certificate -qO- --tries=3 --timeout=2 https://realitykey.cloudflare.now.cc/?privateKey=$REALITY_PRIVATE | awk -F '"' '/publicKey/{print $4}')
    fi
  elif [[ "${#REALITY_PRIVATE[@]}" = 0 && "${#REALITY_PUBLIC[@]}" = 0 ]]; then
    generate_reality_keypair new_keypair
  else
    REALITY_PRIVATE=$(awk '{print $1}' <<< "${REALITY_PRIVATE[@]}") && REALITY_PUBLIC=$(awk '{print $1}' <<< "${REALITY_PUBLIC[@]}")
  fi

  # 获取自签名证书的域名
  TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in ${WORK_DIR}/cert/cert.pem 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/, "", $2); print $2}')

  # naive 在 -r 新增协议时，如 cert_200.pem 过期 / 缺失 / SNI 不一致则自动更新
  [[ "${INSTALL_PROTOCOLS[@]}" =~ 'm' ]] && ssl_certificate "$TLS_SERVER" naive_only

  # 生成 2022-blake3-aes-128-gcm 的 password
  local SIP022_PASSWORD=${SIP022_PASSWORD:-"$(openssl rand -base64 16)"}

  # 第1个协议为 b  (a为全部)，生成 XTLS + Reality 配置
  CHECK_PROTOCOLS=b
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_XTLS_REALITY" ] && PORT_XTLS_REALITY=$(( START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}") ))
    NODE_NAME[11]=${NODE_NAME[11]:-"$NODE_NAME_CONFIRM"} && UUID[11]=${UUID[11]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[11]=${REALITY_PRIVATE[11]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[11]=${REALITY_PUBLIC[11]:-"$REALITY_PUBLIC"} &&
    cat > ${WORK_DIR}/conf/11_${NODE_TAG[0]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[11]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[11]} ${NODE_TAG[0]}",
            "listen":"::",
            "listen_port":$PORT_XTLS_REALITY,
            "users":[
                {
                    "uuid":"${UUID[11]}",
                    "flow":"xtls-rprx-vision"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[11]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "multiplex":{
                "enabled":false,
                "padding":false,
                "brutal":{
                    "enabled":false,
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Hysteria2 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_HYSTERIA2" ] && PORT_HYSTERIA2=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    [ "$IS_HOPPING" = 'is_hopping' ] && add_port_hopping_nat $PORT_HOPPING_START $PORT_HOPPING_END $PORT_HYSTERIA2
    NODE_NAME[12]=${NODE_NAME[12]:-"$NODE_NAME_CONFIRM"} && UUID[12]=${UUID[12]:-"$UUID_CONFIRM"}
    HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]}}"
    # 保留已开启的 ignore_client_bandwidth，避免重装/改协议被模板冲回默认
    local HY2_IGNORE_GEN=false
    [ -s ${WORK_DIR}/conf/12_${NODE_TAG[1]}_inbounds.json ] && HY2_IGNORE_GEN=$(jq_exec -r '.inbounds[]? | select(.type == "hysteria2") | .ignore_client_bandwidth // false' ${WORK_DIR}/conf/12_${NODE_TAG[1]}_inbounds.json 2>/dev/null)
    [ "$HY2_IGNORE_GEN" = 'true' ] || HY2_IGNORE_GEN=false
    local HY2_REALM_CONFIG=""
    if [ "$IS_HY2_REALM" = 'is_hy2_realm' ]; then
      HY2_REALM_CONFIG=$(cat <<EOF_REALM
,
            "realm":{
                "server_url":"https://realm.hy2.io",
                "token":"public",
                "realm_id":"${HY2_REALM_ID}",
                "stun_servers":[
                    "turn.cloudflare.com:3478",
                    "stun.nextcloud.com:3478",
                    "stun.sip.us:3478",
                    "global.stun.twilio.com:3478"
                ]
            }
EOF_REALM
)
    fi
    cat > ${WORK_DIR}/conf/12_${NODE_TAG[1]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"hysteria2",
            "tag":"${NODE_NAME[12]} ${NODE_TAG[1]}",
            "listen":"::",
            "listen_port":$PORT_HYSTERIA2,
            "users":[
                {
                    "password":"${UUID[12]}"
                }
            ],
            "ignore_client_bandwidth":${HY2_IGNORE_GEN}${HY2_REALM_CONFIG},
            "tls":{
                "enabled":true,
                "alpn":[
                    "h3"
                ],
                "min_version":"1.3",
                "max_version":"1.3",
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
    [ "$IS_HY2_WARP" = 'is_hy2_warp' ] && sync_hy2_warp_route enable || sync_hy2_warp_route disable
  fi

  # 生成 Tuic V5 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_TUIC" ] && PORT_TUIC=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[13]=${NODE_NAME[13]:-"$NODE_NAME_CONFIRM"} && UUID[13]=${UUID[13]:-"$UUID_CONFIRM"} && TUIC_PASSWORD=${TUIC_PASSWORD:-"$UUID_CONFIRM"} && TUIC_CONGESTION_CONTROL=${TUIC_CONGESTION_CONTROL:-"bbr"}
    cat > ${WORK_DIR}/conf/13_${NODE_TAG[2]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"tuic",
            "tag":"${NODE_NAME[13]} ${NODE_TAG[2]}",
            "listen":"::",
            "listen_port":$PORT_TUIC,
            "users":[
                {
                    "uuid":"${UUID[13]}",
                    "password":"$TUIC_PASSWORD"
                }
            ],
            "congestion_control": "$TUIC_CONGESTION_CONTROL",
            "zero_rtt_handshake": false,
            "tls":{
                "enabled":true,
                "alpn":[
                    "h3"
                ],
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi

  # 生成 ShadowTLS V5 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_SHADOWTLS" ] && PORT_SHADOWTLS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[14]=${NODE_NAME[14]:-"$NODE_NAME_CONFIRM"} && UUID[14]=${UUID[14]:-"$UUID_CONFIRM"} && SHADOWTLS_PASSWORD=${SHADOWTLS_PASSWORD:-"$SIP022_PASSWORD"} && SHADOWTLS_METHOD=${SHADOWTLS_METHOD:-"2022-blake3-aes-128-gcm"}

    cat > ${WORK_DIR}/conf/14_${NODE_TAG[3]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowtls",
            "tag":"${NODE_NAME[14]} ${NODE_TAG[3]}",
            "listen":"::",
            "listen_port":$PORT_SHADOWTLS,
            "detour":"shadowtls-in",
            "version":3,
            "users":[
                {
                    "password":"${UUID[14]}"
                }
            ],
            "handshake":{
                "server":"${TLS_SERVER}",
                "server_port":443
            },
            "strict_mode":true
        },
        {
            "type":"shadowsocks",
            "tag":"shadowtls-in",
            "listen":"127.0.0.1",
            "network":"tcp",
            "method":"$SHADOWTLS_METHOD",
            "password":"$SHADOWTLS_PASSWORD",
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Shadowsocks 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_SHADOWSOCKS" ] && PORT_SHADOWSOCKS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[15]=${NODE_NAME[15]:-"$NODE_NAME_CONFIRM"} && SHADOWSOCKS_PASSWORD=${SHADOWSOCKS_PASSWORD:-"$SIP022_PASSWORD"} && SHADOWSOCKS_METHOD=${SHADOWSOCKS_METHOD:-"2022-blake3-aes-128-gcm"}
    cat > ${WORK_DIR}/conf/15_${NODE_TAG[4]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"shadowsocks",
            "tag":"${NODE_NAME[15]} ${NODE_TAG[4]}",
            "listen":"::",
            "listen_port":$PORT_SHADOWSOCKS,
            "method":"${SHADOWSOCKS_METHOD}",
            "password":"${SHADOWSOCKS_PASSWORD}",
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 Trojan 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_TROJAN" ] && PORT_TROJAN=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[16]=${NODE_NAME[16]:-"$NODE_NAME_CONFIRM"} && TROJAN_PASSWORD=${TROJAN_PASSWORD:-"$UUID_CONFIRM"}
    cat > ${WORK_DIR}/conf/16_${NODE_TAG[5]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"trojan",
            "tag":"${NODE_NAME[16]} ${NODE_TAG[5]}",
            "listen":"::",
            "listen_port":$PORT_TROJAN,
            "users":[
                {
                    "password":"$TROJAN_PASSWORD"
                }
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 vmess + ws 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_VMESS_WS" ] && PORT_VMESS_WS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[17]=${NODE_NAME[17]:-"$NODE_NAME_CONFIRM"} && UUID[17]=${UUID[17]:-"$UUID_CONFIRM"} && WS_SERVER_IP[17]=${WS_SERVER_IP[17]:-"$SERVER_IP"} && CDN[17]=${CDN[17]:-"$CDN"} && CDN_PORT[17]=${CDN_PORT[17]:-${CDN_PORT:-80}} && VMESS_WS_PATH=${VMESS_WS_PATH:-"${UUID[17]}-vmess"}
    cat > ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json << EOF
//  "WS_SERVER_IP_SHOW": "${WS_SERVER_IP[17]}"
//  "VMESS_HOST_DOMAIN": "${VMESS_HOST_DOMAIN}${ARGO_DOMAIN}"
//  "CDN": "${CDN[17]}"
//  "CDN_PORT": "${CDN_PORT[17]}"
{
    "inbounds":[
        {
            "type":"vmess",
            "tag":"${NODE_NAME[17]} ${NODE_TAG[6]}",
            "listen":"::",
            "listen_port":$PORT_VMESS_WS,
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "uuid":"${UUID[17]}",
                    "alterId":0
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/$VMESS_WS_PATH",
                "max_early_data":2560,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 vless + ws + tls 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_VLESS_WS" ] && PORT_VLESS_WS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[18]=${NODE_NAME[18]:-"$NODE_NAME_CONFIRM"} && UUID[18]=${UUID[18]:-"$UUID_CONFIRM"} && WS_SERVER_IP[18]=${WS_SERVER_IP[18]:-"$SERVER_IP"} && CDN[18]=${CDN[18]:-"$CDN"} && CDN_PORT[18]=${CDN_PORT[18]:-${CDN_PORT:-443}} && VLESS_WS_PATH=${VLESS_WS_PATH:-"${UUID[18]}-vless"}
    cat > ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json << EOF
//  "WS_SERVER_IP_SHOW": "${WS_SERVER_IP[18]}"
//  "CDN": "${CDN[18]}"
//  "CDN_PORT": "${CDN_PORT[18]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[18]} ${NODE_TAG[7]}",
            "listen":"::",
            "listen_port":$PORT_VLESS_WS,
            "tcp_fast_open":false,
            "proxy_protocol":false,
            "users":[
                {
                    "name":"sing-box",
                    "uuid":"${UUID[18]}"
                }
            ],
            "transport":{
                "type":"ws",
                "path":"/$VLESS_WS_PATH",
                "max_early_data":2560,
                "early_data_header_name":"Sec-WebSocket-Protocol"
            },
            "tls":{
                "enabled":true,
                "server_name":"${VLESS_HOST_DOMAIN}${ARGO_DOMAIN}",
                "min_version":"1.3",
                "max_version":"1.3",
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 H2 + Reality 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_H2_REALITY" ] && PORT_H2_REALITY=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[19]=${NODE_NAME[19]:-"$NODE_NAME_CONFIRM"} && UUID[19]=${UUID[19]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[19]=${REALITY_PRIVATE[19]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[19]=${REALITY_PUBLIC[19]:-"$REALITY_PUBLIC"}
    cat > ${WORK_DIR}/conf/19_${NODE_TAG[8]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[19]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[19]} ${NODE_TAG[8]}",
            "listen":"::",
            "listen_port":$PORT_H2_REALITY,
            "users":[
                {
                    "uuid":"${UUID[19]}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[19]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport":{
                "type": "http"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 gRPC + Reality 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_GRPC_REALITY" ] && PORT_GRPC_REALITY=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[20]=${NODE_NAME[20]:-"$NODE_NAME_CONFIRM"} && UUID[20]=${UUID[20]:-"$UUID_CONFIRM"} && REALITY_PRIVATE[20]=${REALITY_PRIVATE[20]:-"$REALITY_PRIVATE"} && REALITY_PUBLIC[20]=${REALITY_PUBLIC[20]:-"$REALITY_PUBLIC"}
    cat > ${WORK_DIR}/conf/20_${NODE_TAG[9]}_inbounds.json << EOF
//  "public_key":"${REALITY_PUBLIC[20]}"
{
    "inbounds":[
        {
            "type":"vless",
            "tag":"${NODE_NAME[20]} ${NODE_TAG[9]}",
            "listen":"::",
            "listen_port":$PORT_GRPC_REALITY,
            "users":[
                {
                    "uuid":"${UUID[20]}"
                }
            ],
            "tls":{
                "enabled":true,
                "server_name":"${TLS_SERVER}",
                "reality":{
                    "enabled":true,
                    "handshake":{
                        "server":"${TLS_SERVER}",
                        "server_port":443
                    },
                    "private_key":"${REALITY_PRIVATE[20]}",
                    "short_id":[
                        ""
                    ]
                }
            },
            "transport":{
                "type": "grpc",
                "service_name": "grpc"
            },
            "multiplex":{
                "enabled":true,
                "padding":true,
                "brutal":{
                    "enabled":${IS_BRUTAL},
                    "up_mbps":1000,
                    "down_mbps":1000
                }
            }
        }
    ]
}
EOF
  fi

  # 生成 anytls 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_ANYTLS" ] && PORT_ANYTLS=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[21]=${NODE_NAME[21]:-"$NODE_NAME_CONFIRM"} && UUID[21]=${UUID[21]:-"$UUID_CONFIRM"}

    cat > ${WORK_DIR}/conf/21_${NODE_TAG[10]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"anytls",
            "tag":"${NODE_NAME[21]} ${NODE_TAG[10]}",
            "listen":"::",
            "listen_port":$PORT_ANYTLS,
            "users":[
                {
                    "password":"${UUID[21]}"
                }
            ],
            "padding_scheme":[],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi

  # 生成 naive 配置
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    [ -z "$PORT_NAIVE" ] && PORT_NAIVE=$[START_PORT+$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")]
    NODE_NAME[22]=${NODE_NAME[22]:-"$NODE_NAME_CONFIRM"} && UUID[22]=${UUID[22]:-"$UUID_CONFIRM"}

    cat > ${WORK_DIR}/conf/22_${NODE_TAG[11]}_inbounds.json << EOF
{
    "inbounds":[
        {
            "type":"naive",
            "tag":"${NODE_NAME[22]} ${NODE_TAG[11]}",
            "listen":"::",
            "listen_port":$PORT_NAIVE,
            "users":[
                {
                    "username":"${UUID[22]}",
                    "password":"${UUID[22]}"
                }
            ],
            "tls":{
                "enabled":true,
                "certificate_path":"${WORK_DIR}/cert/cert_200.pem",
                "key_path":"${WORK_DIR}/cert/private.key"
            }
        }
    ]
}
EOF
  fi
}

# Sing-box 生成守护进程文件
sing-box_systemd() {
  if [ "$SYSTEM" = 'Alpine' ]; then
    local OPENRC_SERVICE="#!/sbin/openrc-run

name=\"sing-box\"
description=\"sing-box service\"
command=\"${WORK_DIR}/sing-box\"
command_args=\"run -C ${WORK_DIR}/conf\"
pidfile=\"/var/run/\${RC_SVCNAME}.pid\"
command_background=\"yes\"
output_log=\"${WORK_DIR}/logs/sing-box.log\"
error_log=\"${WORK_DIR}/logs/sing-box.log\"

depend() {
    need net
    after net"

    # 添加 reload 函数，支持 SIGHUP 热更
    OPENRC_SERVICE+="
}

reload() {
    ebegin \"Reloading \${RC_SVCNAME}\"
    start-stop-daemon --signal HUP --pidfile \$pidfile
    eend \$? \"Failed to reload \${RC_SVCNAME}\"
}

start_pre() {
    # 确保日志目录和PID目录存在并有正确权限
    mkdir -p ${WORK_DIR}/logs
    mkdir -p /var/run
    chmod 755 /var/run"

    # 存在 nginx.conf 时自管 nginx（与 xray 守护一致）：已运行则跳过，未运行才启动，失败不阻塞服务启动
    [ -s ${WORK_DIR}/nginx.conf ] && OPENRC_SERVICE+="
    if command -v /usr/sbin/nginx >/dev/null 2>&1 && ! ps -eo pid,args | grep -q \"[n]ginx.*${WORK_DIR}/nginx.conf\"; then
        /usr/sbin/nginx -c ${WORK_DIR}/nginx.conf
    fi"

    OPENRC_SERVICE+="
    # 确保 PID 文件不存在，避免启动失败
    rm -f \$pidfile
}"

    # 添加 stop_post 函数，用于在服务停止后清理 nginx。
    # 无论是否有 nginx 都始终生成，避免 stop() 调用未定义函数导致 command not found 误报。
    OPENRC_SERVICE+="

stop_post() {
    # 仅在存在 nginx.conf 时才尝试干净地停止 nginx；无 nginx 场景直接返回成功
    if [ -s ${WORK_DIR}/nginx.conf ] && command -v /usr/sbin/nginx >/dev/null 2>&1; then
        /usr/sbin/nginx -s quit -c ${WORK_DIR}/nginx.conf 2>/dev/null
        sleep 1 # 等待优雅关闭
        # 如果仍运行，用 SIGKILL
        local NGINX_MASTER=\$(ps -eo pid,args | grep \"nginx: master process.*${WORK_DIR}/nginx.conf\" | awk '{print \$1; exit}')
        if [ -n \"\$NGINX_MASTER\" ]; then
            kill -KILL \$NGINX_MASTER 2>/dev/null
        fi
    fi
    # 显式返回成功，避免 OpenRC 将 stop 流程误判为失败
    return 0
}

stop() {
    ebegin \"Stopping \${RC_SVCNAME}\"
    # pidfile 优先，进程名兜底——兼容 pidfile 残留指向已死进程的场景（无进程可杀时不误报）
    start-stop-daemon --stop --pidfile \$pidfile --retry 5 2>/dev/null \\
      || start-stop-daemon --stop --name sing-box --retry 5 2>/dev/null \\
      || true
    # 清理残留 pidfile 与已启动标记，避免后续 status 误报 started
    rm -f \$pidfile /run/started/\${RC_SVCNAME} 2>/dev/null
    eend 0

    # 然后运行 post 清理
    stop_post
}"

    echo "$OPENRC_SERVICE" > ${SINGBOX_DAEMON_FILE}
    chmod +x ${SINGBOX_DAEMON_FILE}
  else
    # 原有的 systemd 服务创建代码
    SING_BOX_SERVICE="[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
WorkingDirectory=${WORK_DIR}
"
    # 存在 nginx.conf 时用 ExecStartPre 管理 nginx（含 CentOS7）：已在运行则 reload 最新配置，未运行则启动
    [[ -s "${WORK_DIR}/nginx.conf" ]] && SING_BOX_SERVICE+="ExecStartPre=/bin/bash -c 'nginx -c ${WORK_DIR}/nginx.conf -s reload 2>/dev/null || nginx -c ${WORK_DIR}/nginx.conf'
"
    SING_BOX_SERVICE+="ExecStart=${WORK_DIR}/sing-box run -C ${WORK_DIR}/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target"

    echo "$SING_BOX_SERVICE" > ${SINGBOX_DAEMON_FILE}
    systemctl daemon-reload
  fi
}

# Argo 生成守护进程文件
argo_systemd() {
  if [ "$SYSTEM" = 'Alpine' ]; then
    # 分离命令和参数
    local COMMAND="${ARGO_RUNS%% --*}"   # 提取命令部分（包括 cloudflared tunnel）
    local ARGS="${ARGO_RUNS#$COMMAND }"  # 提取参数部分

    cat > ${ARGO_DAEMON_FILE} << EOF
#!/sbin/openrc-run

name="argo"
description="Cloudflare Tunnel service"
command="${COMMAND}"
command_args="${ARGS}"
pidfile="/var/run/\${RC_SVCNAME}.pid"
command_background="yes"
output_log="${WORK_DIR}/logs/argo.log"
error_log="${WORK_DIR}/logs/argo.log"

depend() {
    need net
    after net
}

start_pre() {
    # 确保日志目录和PID目录存在并有正确权限
    mkdir -p ${WORK_DIR}/logs
    mkdir -p /var/run
    chmod 755 /var/run

    # 确保 PID 文件不存在，避免启动失败
    rm -f \$pidfile
}
EOF
    chmod +x ${ARGO_DAEMON_FILE}
  else
    # 原有的 systemd 服务创建代码
    cat > ${ARGO_DAEMON_FILE} << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORK_DIR
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${ARGO_RUNS}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
}

# 获取原有各协议的参数，先清空所有的 key-value
fetch_nodes_value() {
  unset NODE_NAME PORT_XTLS_REALITY UUID TLS_SERVER REALITY_PRIVATE REALITY_PUBLIC PORT_HYSTERIA2 HY2_REALM_ID IS_HY2_REALM IS_HY2_IGNORE IS_HY2_WARP PORT_TUIC TUIC_PASSWORD TUIC_CONGESTION_CONTROL PORT_SHADOWTLS SHADOWTLS_PASSWORD SHADOWSOCKS_METHOD PORT_SHADOWSOCKS PORT_TROJAN TROJAN_PASSWORD PORT_VMESS_WS VMESS_WS_PATH WS_SERVER_IP WS_SERVER_IP_SHOW VMESS_HOST_DOMAIN CDN CDN_PORT PORT_VLESS_WS VLESS_WS_PATH VLESS_HOST_DOMAIN PORT_H2_REALITY PORT_GRPC_REALITY ARGO_DOMAIN PORT_ANYTLS PORT_NAIVE SELF_SIGNED_FINGERPRINT_SHA256 SELF_SIGNED_FINGERPRINT_BASE64

  # 获取公共数据
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && SERVER_IP=$(awk -F '"' '/"WS_SERVER_IP_SHOW"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) || SERVER_IP=$([ -s ${WORK_DIR}/list ] && grep -A1 '"tag"' ${WORK_DIR}/list | sed -E '/-ws(-tls)*",$/{N;d}' | awk -F '"' '/"server"/{count++; if (count == 1) {print $4; exit}}')
  EXISTED_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null)
  START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$EXISTED_PORTS")
  [[ -z "$NODE_NAME_CONFIRM" && -s ${WORK_DIR}/subscribe/clash ]] && NODE_NAME_CONFIRM=$(awk -F "'" '/u: &u/{print $2; exit}' ${WORK_DIR}/subscribe/clash)

  # 如有 Argo，获取 Argo Tunnel
  [[ ${STATUS[1]} =~ $(status_on_off_regex) ]] && grep -q '\--url' ${ARGO_DAEMON_FILE} && { cmd_systemctl enable argo; sleep 2 && cmd_systemctl status argo &>/dev/null && fetch_quicktunnel_domain; }

  # 获取 UUID_CONFIRM（从 JSON 配置文件读取，不依赖 nginx）
  # 如 UUID_CONFIRM 已有值（例如上层已交互输入），跳过 JSON 读取，避免重复弹窗
  [ -z "$UUID_CONFIRM" ] && UUID_CONFIRM=$(awk -F '"' '/"uuid"[[:space:]]*:[[:space:]]*"/ || /"id"[[:space:]]*:[[:space:]]*"/ {print $4; exit}' ${WORK_DIR}/conf/1*.json 2>/dev/null)
  # JSON 中提取不到时，尝试从 nginx.conf 提取订阅 / WS 路径段（订阅开启 / 关闭时 nginx.conf 一定含有 UUID；
  # 用 sed 抓路径段而非 match 量词正则，兼容 BusyBox / mawk）
  [ -z "$UUID_CONFIRM" ] && [ -s "${WORK_DIR}/nginx.conf" ] && \
    UUID_CONFIRM=$(sed -n 's#.*location ~ \^/\([^/]*\)/auto.*#\1#p; s#.*location /\([^/]*\)-vmess.*#\1#p; s#.*location /\([^/]*\)-vless.*#\1#p' ${WORK_DIR}/nginx.conf 2>/dev/null | sed -n '1p')
  # 提取不到时，仅在安装相关流程走交互式输入；其余只读流程（如 sb -n 查看节点信息）用随机 UUID 兜底，避免无谓弹窗
  # 说明：仅安装 shadowsocks / trojan / anytls / naive 等"凭证非 UUID 格式"协议时，以上提取必然为空，
  #       此时导出节点信息不需要 UUID，不应阻塞用户交互
  if [ -z "$UUID_CONFIRM" ]; then
    if [ "$IS_INSTALL" = 'install' ] || [ "$IS_FAST_INSTALL" = 'is_fast_install' ] || [ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]; then
      input_uuid
    else
      UUID_CONFIRM=$(cat /proc/sys/kernel/random/uuid)
    fi
  fi
  # 获取 Nginx 端口（首次开启订阅时 nginx.conf 尚未创建，静默跳过）
  [[ "${IS_SUB}" = 'is_sub' || "${IS_ARGO}" = 'is_argo' ]] && [ -s "${WORK_DIR}/nginx.conf" ] &&
  PORT_NGINX=$(awk '/listen/{print $2; exit}' ${WORK_DIR}/nginx.conf)

  # 获取 XTLS + Reality key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[0]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[0]}_inbounds.json) && NODE_NAME[11]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[0]}.*/\1/p" <<< "$JSON") && PORT_XTLS_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[11]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && REALITY_PRIVATE[11]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON") && REALITY_PUBLIC[11]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")

  # 获取 Hysteria2 key-value
  if [ -s ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json ]; then
    local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json)
    NODE_NAME[12]=$(awk -F '"' -v suffix=" ${NODE_TAG[1]}" '/"tag"[[:space:]]*:/ {v=$4; sub(suffix"$", "", v); print v; exit}' <<< "$JSON")
    PORT_HYSTERIA2=$(awk -F ':' '/"listen_port"[[:space:]]*:/ {gsub(/[[:space:],]/, "", $2); print $2; exit}' <<< "$JSON")
    UUID[12]=$(awk -F '"' '/"password"[[:space:]]*:/ {count++; if (count == 1) {print $4; exit}}' <<< "$JSON")
    HY2_UP=${HY2_UP:-"$([ -s $WORK_DIR/list ] && sed -n '/type: hysteria2/ s/.*,[ ]*up:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/list)"}
    HY2_DOWN=${HY2_DOWN:-"$([ -s $WORK_DIR/list ] && sed -n '/type: hysteria2/ s/.*,[ ]*down:[ ]*"\([0-9]\+\)[ ]*Mbps.*/\1/gp' $WORK_DIR/list)"}
    if grep -q '"ignore_client_bandwidth"[[:space:]]*:[[:space:]]*true' <<< "$JSON"; then
      IS_HY2_IGNORE=is_hy2_ignore
    else
      unset IS_HY2_IGNORE
    fi
    if grep -q '"realm"[[:space:]]*:' <<< "$JSON"; then
      IS_HY2_REALM=is_hy2_realm
      HY2_REALM_ID=$(awk -F '"' '/"realm_id"[[:space:]]*:/{print $4; exit}' <<< "$JSON")
      HY2_REALM_ID=${HY2_REALM_ID:-${UUID[12]}}
    fi
    if [ -s ${WORK_DIR}/conf/03_route.json ] && [ -n "${NODE_NAME[12]}" ] && grep -q '"outbound"[[:space:]]*:[[:space:]]*"warp-ep"' ${WORK_DIR}/conf/03_route.json && grep -q "${NODE_NAME[12]} ${NODE_TAG[1]}" ${WORK_DIR}/conf/03_route.json; then
      IS_HY2_WARP=is_hy2_warp
    fi
    check_port_hopping_nat
  fi

  # 获取 Tuic V5 key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[2]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[2]}_inbounds.json) && NODE_NAME[13]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[2]}.*/\1/p" <<< "$JSON") && PORT_TUIC=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[13]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && TUIC_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON") && TUIC_CONGESTION_CONTROL=$(awk -F '"' '/"congestion_control"/{print $4}' <<< "$JSON")

  # 获取 ShadowTLS key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[3]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[3]}_inbounds.json) && NODE_NAME[14]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[3]}.*/\1/p" <<< "$JSON") && PORT_SHADOWTLS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[14]=$(awk -F '"' '/"password"/{count++; if (count == 1) {print $4; exit}}' <<< "$JSON") && SHADOWTLS_PASSWORD=$(awk -F '"' '/"password"/{count++; if (count == 2) {print $4; exit}}' <<< "$JSON") && SHADOWTLS_METHOD=$(awk -F '"' '/"method"/{print $4}' <<< "$JSON")

  # 获取 Shadowsocks key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[4]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[4]}_inbounds.json) && NODE_NAME[15]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[4]}.*/\1/p" <<< "$JSON") && PORT_SHADOWSOCKS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && SHADOWSOCKS_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON") && SHADOWSOCKS_METHOD=$(awk -F '"' '/"method"/{print $4}' <<< "$JSON")

  # 获取 Trojan key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[5]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[5]}_inbounds.json) && NODE_NAME[16]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[5]}.*/\1/p" <<< "$JSON") && PORT_TROJAN=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && TROJAN_PASSWORD=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")

  # 获取 vmess + ws key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[6]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[6]}_inbounds.json) && NODE_NAME[17]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[6]}.*/\1/p" <<< "$JSON") && PORT_VMESS_WS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[17]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && VMESS_WS_PATH=$(sed -n 's#.*"path":"/\(.*\)",#\1#p' <<< "$JSON") && WS_SERVER_IP[17]=$(awk  -F '"' '/"WS_SERVER_IP_SHOW"/{print $4}' <<< "$JSON") && CDN[17]=$(awk  -F '"' '/"CDN"/{print $4}' <<< "$JSON") && CDN_PORT[17]=$(awk  -F '"' '/"CDN_PORT"/{print $4}' <<< "$JSON") && [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] && ARGO_DOMAIN=$(awk  -F '"' '/"VMESS_HOST_DOMAIN"/{print $4}' <<< "$JSON") || VMESS_HOST_DOMAIN=$(awk  -F '"' '/"VMESS_HOST_DOMAIN"/{print $4}' <<< "$JSON")

  # 获取 vless + ws + tls key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[7]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[7]}_inbounds.json) && NODE_NAME[18]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[7]}.*/\1/p" <<< "$JSON") && PORT_VLESS_WS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[18]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && VLESS_WS_PATH=$(sed -n 's#.*"path":"/\(.*\)",#\1#p' <<< "$JSON") && WS_SERVER_IP[18]=$(awk  -F '"' '/"WS_SERVER_IP_SHOW"/{print $4}' <<< "$JSON") && CDN[18]=$(awk  -F '"' '/"CDN"/{print $4}' <<< "$JSON") && [[ "${STATUS[1]}" =~ $(status_on_off_regex) ]] && CDN_PORT[18]=$(awk  -F '"' '/"CDN_PORT"/{print $4}' <<< "$JSON") && ARGO_DOMAIN=$(awk -F '"' '/"server_name"/{print $4}' <<< "$JSON") || VLESS_HOST_DOMAIN=$(awk -F '"' '/"server_name"/{print $4}' <<< "$JSON")

  # 获取 H2 + Reality key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[8]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[8]}_inbounds.json) && NODE_NAME[19]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[8]}.*/\1/p" <<< "$JSON") && PORT_H2_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[19]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && REALITY_PRIVATE[19]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON") && REALITY_PUBLIC[19]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")

  # 获取 gRPC + Reality key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[9]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[9]}_inbounds.json) && NODE_NAME[20]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[9]}.*/\1/p" <<< "$JSON") && PORT_GRPC_REALITY=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[20]=$(awk -F '"' '/"uuid"/{print $4}' <<< "$JSON") && REALITY_PRIVATE[20]=$(awk -F '"' '/"private_key"/{print $4}' <<< "$JSON") && REALITY_PUBLIC[20]=$(awk -F '"' '/"public_key"/{print $4}' <<< "$JSON")

  # 获取 anytls key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[10]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[10]}_inbounds.json) && NODE_NAME[21]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[10]}.*/\1/p" <<< "$JSON") && PORT_ANYTLS=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[21]=$(awk -F '"' '/"password"/{print $4}' <<< "$JSON")

  # 获取 naive key-value
  [ -s ${WORK_DIR}/conf/*_${NODE_TAG[11]}_inbounds.json ] && local JSON=$(cat ${WORK_DIR}/conf/*_${NODE_TAG[11]}_inbounds.json) && NODE_NAME[22]=$(sed -n "s/.*\"tag\":\"\(.*\) ${NODE_TAG[11]}.*/\1/p" <<< "$JSON") && PORT_NAIVE=$(sed -n 's/.*"listen_port":\([0-9]\+\),/\1/gp' <<< "$JSON") && UUID[22]=$(awk -F '"' '/"username"/{print $4; exit}' <<< "$JSON")

  # 兜底：极早期版本 04_experimental.json 无 clash_api（cache_file-only），补全注入。
  # 同时剥离可能残留的 v2ray_api（官方 release 二进制默认不编译该功能，
  # 若旧版脚本已注入会在启动时报 "v2ray api is not included in this build"）。
  # 升级/change 场景 generate_sing_box_base_conf 已统一写入 clash_api，这里无需重复。
  if ! grep -q 'clash_api' ${WORK_DIR}/conf/04_experimental.json 2>/dev/null; then
    CLASH_API_PORT=$(find_free_api_port)
    local EXP_JSON=$(cat ${WORK_DIR}/conf/04_experimental.json)
    printf '%s\n' "$EXP_JSON" | "$DIR/jq" 'del(.experimental.v2ray_api) | .experimental += {
      "clash_api": {
        "external_controller": "127.0.0.1:'"$CLASH_API_PORT"'"
      }
    }' > ${WORK_DIR}/conf/04_experimental.json
    # 补全后立即热加载（SIGHUP）使 clash_api 监听马上生效；
    # 前台同步执行确保信号送达（SIGHUP reload 不断连 SSH）；仅当 sing-box 运行中才 reload
    if ps -eo pid,args | grep -q '[s]ing-box run'; then
      cmd_systemctl reload sing-box
    fi
  fi
}

# 获取 Argo 临时隧道域名
fetch_quicktunnel_domain() {
  unset CLOUDFLARED_PID METRICS_ADDRESS ARGO_DOMAIN
  local QUICKTUNNEL_ERROR_TIME=20
  until [ -n "$ARGO_DOMAIN" ]; do
    local CLOUDFLARED_PID=$(ps -eo pid,args | awk -v work_dir="$WORK_DIR" '$0~(work_dir"/cloudflared"){print $1;exit}')
    [[ -z "$METRICS_ADDRESS" && "$CLOUDFLARED_PID" =~ ^[0-9]+$ ]] && local METRICS_ADDRESS=$(ss -nltp | grep "pid=$CLOUDFLARED_PID" | awk '{print $4}')
    [ -n "$METRICS_ADDRESS" ] && ARGO_DOMAIN=$(wget -qO- http://$METRICS_ADDRESS/quicktunnel | awk -F '"' '{print $4}')
    if [[ ! "$ARGO_DOMAIN" =~ trycloudflare\.com$ ]]; then
      (( QUICKTUNNEL_ERROR_TIME-- )) || true
      [ "$QUICKTUNNEL_ERROR_TIME" = '0' ] && error " $(text 93) "
      sleep 2
    else
      break
    fi
  done

  # 把临时隧道写到 Sing-box 相应的 ws inbounds 文件
  [ -s ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json ] && sed -i "s/VMESS_HOST_DOMAIN.*/VMESS_HOST_DOMAIN\": \"$ARGO_DOMAIN\"/" ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json
  [ -s ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json ] && sed -i "s/\"server_name\":.*/\"server_name\": \"$ARGO_DOMAIN\",/" ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json
}

