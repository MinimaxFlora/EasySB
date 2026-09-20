# ------------------------------------------------------------------------------
# 十七、协议增删 / Protocol add and remove
# ------------------------------------------------------------------------------
# 增加或删除协议
change_protocols() {
  check_install
  [ "${STATUS[0]}" = "$(text 26)" ] && error "\n Sing-box $(text 26) "

  # 检查服务器 IP
  check_system_ip

  # 查找已安装的协议，并遍历其在所有协议列表中的名称，获取协议名后存放在 EXISTED_PROTOCOLS; 没有的协议存放在 NOT_EXISTED_PROTOCOLS
  INSTALLED_PROTOCOLS_LIST=$(awk -F '"' '/"tag":/{print $4}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null | grep -v 'shadowtls-in' | awk '{print $NF}')
  for f in ${!NODE_TAG[@]}; do [[ $INSTALLED_PROTOCOLS_LIST =~ "${NODE_TAG[f]}" ]] && EXISTED_PROTOCOLS+=("${PROTOCOL_LIST[f]}") || NOT_EXISTED_PROTOCOLS+=("${PROTOCOL_LIST[f]}"); done

  # 已安装协议为空时不交互删除，直接进入添加
  if [ "${#EXISTED_PROTOCOLS[@]}" -gt 0 ]; then
    # 列出已安装协议（保持原有样式，仅显示协议名；F2 流量显示已移除，见需求文档 3.3 节）
    hint "\n $(text 136) (${#EXISTED_PROTOCOLS[@]})"
    for h in "${!EXISTED_PROTOCOLS[@]}"; do
      hint " $(asc $(( h+97 ))). ${EXISTED_PROTOCOLS[h]} "
    done

    # 从已安装的协议中选择需要删除的协议名，并存放在 REMOVE_PROTOCOLS，把保存的协议的协议存放在 KEEP_PROTOCOLS
    reading "\n $(text 64) " REMOVE_SELECT
    # 统一为小写，去掉重复选项，处理不在可选列表里的选项，把特殊符号处理
    REMOVE_SELECT=$(sed "s/[^a-$(asc $(( ${#EXISTED_PROTOCOLS[@]} + 96 )))]//g" <<< "${REMOVE_SELECT,,}" | grep -o . | awk '!seen[$0]++' | tr -d '\n')

    for ((j=0; j<${#REMOVE_SELECT}; j++)); do
      REMOVE_PROTOCOLS+=("${EXISTED_PROTOCOLS[$(( $(asc "$(awk "NR==$[j+1] {print}" <<< "$(grep -o . <<< "$REMOVE_SELECT")")") - 97 ))]}")
    done

    for k in "${EXISTED_PROTOCOLS[@]}"; do
      [[ ! "${REMOVE_PROTOCOLS[@]}" =~ "$k" ]] && KEEP_PROTOCOLS+=("$k")
    done
  fi

  # 如有未安装的协议，列表显示并选择安装，把增加的协议存在放在 ADD_PROTOCOLS
  if [ "${#NOT_EXISTED_PROTOCOLS[@]}" -gt 0 ]; then
    hint "\n $(text 137) (${#NOT_EXISTED_PROTOCOLS[@]}) "
    for i in "${!NOT_EXISTED_PROTOCOLS[@]}"; do
      hint " $(asc $(( i+97 ))). ${NOT_EXISTED_PROTOCOLS[i]} "
    done
    reading "\n $(text 66) " ADD_SELECT
    # 统一为小写，去掉重复选项，处理不在可选列表里的选项，把特殊符号处理
    ADD_SELECT=$(sed "s/[^a-$(asc $(( ${#NOT_EXISTED_PROTOCOLS[@]} + 96 )))]//g" <<< "${ADD_SELECT,,}" | grep -o . | awk '!seen[$0]++' | tr -d '\n')

    for ((l=0; l<${#ADD_SELECT}; l++)); do
      ADD_PROTOCOLS+=("${NOT_EXISTED_PROTOCOLS[$(( $(asc "$(awk "NR==$[l+1] {print}" <<< "$(grep -o . <<< "$ADD_SELECT")")") - 97 ))]}")
    done
  fi

  # 重新安装 = 保留 + 新增；数量可为 0（协议全删后仅保留基础配置）
  REINSTALL_PROTOCOLS=("${KEEP_PROTOCOLS[@]}" "${ADD_PROTOCOLS[@]}")

  # 显示重新安装的协议列表，并确认是否正确
  hint "\n $(text 138) (${#REINSTALL_PROTOCOLS[@]}) "
  [ "${#KEEP_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 74) (${#KEEP_PROTOCOLS[@]}) "
  for r in "${!KEEP_PROTOCOLS[@]}"; do
    hint " $[r+1]. ${KEEP_PROTOCOLS[r]} "
  done

  [ "${#ADD_PROTOCOLS[@]}" -gt 0 ] && hint "\n $(text 75) (${#ADD_PROTOCOLS[@]}) "
  for r in "${!ADD_PROTOCOLS[@]}"; do
    hint " $[r+1]. ${ADD_PROTOCOLS[r]} "
  done

  reading "\n $(text 68) " CONFIRM
  [ "${CONFIRM,,}" = 'n' ] && exit 0

  # 把确认安装的协议遍历所有协议列表的数组，找出其下标并变为英文小写的形式
  for m in "${!REINSTALL_PROTOCOLS[@]}"; do
    for n in "${!PROTOCOL_LIST[@]}"; do
      if [ "${REINSTALL_PROTOCOLS[m]}" = "${PROTOCOL_LIST[n]}" ]; then
        INSTALL_PROTOCOLS+=($(asc $[n+98]))
      fi
    done
  done

  # 获取各节点信息
  fetch_nodes_value

  for v in "${NODE_NAME[@]}"; do
    [ -n "$v" ] && NODE_NAME_CONFIRM="$v" && break
  done

  # 无既有协议（0 协议或全部删除后重新添加）时，像新安装一样询问节点名称；已有节点名称则沿用
  if [ "${#REINSTALL_PROTOCOLS[@]}" -gt 0 ] && [ "${#KEEP_PROTOCOLS[@]}" -eq 0 ]; then
    unset NODE_NAME_CONFIRM
    input_node_name
  fi

  [ "${#WS_SERVER_IP[@]}" -gt 0 ] && WS_SERVER_IP_SHOW=$(awk '{print $1}' <<< "${WS_SERVER_IP[@]}") && CDN=$(awk '{print $1}' <<< "${CDN[@]}")

  # 寻找待删除协议的 inbound 文件名
  for o in "${REMOVE_PROTOCOLS[@]}"; do
    for s in ${!PROTOCOL_LIST[@]}; do
      [ "$o" = "${PROTOCOL_LIST[s]}" ] && REMOVE_FILE+=("${NODE_TAG[s]}_inbounds.json")
    done
  done

  # 如有需要，删除 hysteria2 跳跃端口，待后面添加回来
  [ "$IS_HOPPING" = 'is_hopping' ] && del_port_hopping_nat

  # 删除不需要的协议配置文件
  [ "${#REMOVE_FILE[@]}" -gt 0 ] && for t in "${REMOVE_FILE[@]}"; do
    rm -f ${WORK_DIR}/conf/*${t}
  done

  # 寻找已存在协议中原有的端口号
  for p in "${KEEP_PROTOCOLS[@]}"; do
    for u in "${!PROTOCOL_LIST[@]}"; do
      [ "$p" = "${PROTOCOL_LIST[u]}" ] && KEEP_PORTS+=("$(awk -F '[:,]' '/listen_port/{print $2}' ${WORK_DIR}/conf/*${NODE_TAG[u]}_inbounds.json)")
    done
  done

  # 根据全部协议，找到空余的端口号
  for q in "${!REINSTALL_PROTOCOLS[@]}"; do
    [[ ! ${KEEP_PORTS[@]} =~ $[START_PORT + q] ]] && ADD_PORTS+=($[START_PORT + q])
  done

  # 所有协议的端口号
  REINSTALL_PORTS=(${KEEP_PORTS[@]} ${ADD_PORTS[@]})

  CHECK_PROTOCOLS=b
  # 获取 Reality 端口
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_XTLS_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_XTLS_REALITY
  fi

  # 获取 Hysteria2 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_HYSTERIA2=${REINSTALL_PORTS[POSITION]}
    if [[ " ${ADD_PROTOCOLS[*]} " =~ " ${PROTOCOL_LIST[1]} " ]] && [ -z "$IS_HY2_REALM" ]; then
      input_hy2_realm
    fi
    [ -z "${PORT_HOPPING_START}${PORT_HOPPING_END}" ] && [ "$IS_HY2_REALM" != 'is_hy2_realm' ] && input_hopping_port
  else
    unset PORT_HYSTERIA2 IS_HY2_REALM IS_HY2_WARP HY2_REALM_ID
  fi

  # 获取 Tuic V5 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_TUIC=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_TUIC
  fi

  # 获取 ShadowTLS 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_SHADOWTLS=${REINSTALL_PORTS[POSITION]}
  fi

  # 获取 Shadowsocks 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_SHADOWSOCKS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_SHADOWSOCKS
  fi

  # 获取 Trojan 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_TROJAN=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_TROJAN
  fi

  # 获取 ws 的 argo 或者 origin 状态
  if [ -s ${ARGO_DAEMON_FILE} ]; then
    local ARGO_ORIGIN_RULES_STATUS=is_argo
    [ "$SYSTEM" = 'Alpine' ] && ARGO_RUNS="$(sed -n 's/command="\(.*\)"/\1/gp' $ARGO_DAEMON_FILE) $(sed -n 's/command_args="\(.*\)"/\1/gp' $ARGO_DAEMON_FILE)" || ARGO_RUNS=$(sed -n "s/^ExecStart=\(.*\)/\1/gp" ${ARGO_DAEMON_FILE})
  elif ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1; then
    local ARGO_ORIGIN_RULES_STATUS=is_origin
  else
    local ARGO_ORIGIN_RULES_STATUS=no_argo_no_origin
  fi

  # 获取 vmess + ws 配置信息
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    local DOMAIN_ERROR_TIME=5
    if [[ "$ARGO_READY" != 'argo_ready' || "$ORIGIN_READY" != 'origin_ready' ]]; then
      if [ "$ARGO_ORIGIN_RULES_STATUS" = 'is_origin' ]; then
        until [ -n "$VMESS_HOST_DOMAIN" ]; do
          (( DOMAIN_ERROR_TIME-- )) || true
          [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
        done
      elif [ "$ARGO_ORIGIN_RULES_STATUS" = 'no_argo_no_origin' ]; then
        [ -z "$ARGO_OR_ORIGIN_RULES" ] && hint "\n $(text 57) " && reading "\n $(text 24) " ARGO_OR_ORIGIN_RULES
        [ "$ARGO_OR_ORIGIN_RULES" != '2' ] && ARGO_OR_ORIGIN_RULES=1 && IS_ARGO=is_argo || IS_ARGO=no_argo
        if [ "$IS_ARGO" = 'is_argo' ]; then
          # 如果原来没有 nginx 配置，需要获取 nginx 端口信息
          [ -z "$PORT_NGINX"  ] && input_nginx_port
          until [ -n "$ARGO_RUNS" ]; do
            input_argo_auth is_add_protocols
            [ -n "$ARGO_RUNS" ] && local ARGO_READY=argo_ready && break
          done
        else
          until [ -n "$VMESS_HOST_DOMAIN" ]; do
            (( DOMAIN_ERROR_TIME-- )) || true
            [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
          done
          local ORIGIN_READY=origin_ready
        fi
      fi
    fi
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_VMESS_WS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_VMESS_WS
  fi

  # 获取 vless + ws + tls 配置信息
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    local DOMAIN_ERROR_TIME=5
    if [[ "$ARGO_READY" != 'argo_ready' || "$ORIGIN_READY" != 'origin_ready' ]]; then
      if [ "$ARGO_ORIGIN_RULES_STATUS" = 'is_origin' ]; then
        until [ -n "$VLESS_HOST_DOMAIN" ]; do
          (( DOMAIN_ERROR_TIME-- )) || true
          [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text   3) \n"
        done
      elif [ "$ARGO_ORIGIN_RULES_STATUS" = 'no_argo_no_origin' ]; then
        [ -z "$ARGO_OR_ORIGIN_RULES" ] && hint "\n $(text 57) " && reading "\n $(text 24) " ARGO_OR_ORIGIN_RULES
        [ "$ARGO_OR_ORIGIN_RULES" != '2' ] && ARGO_OR_ORIGIN_RULES=1 && IS_ARGO=is_argo || IS_ARGO=no_argo
        if [ "$IS_ARGO" = 'is_argo' ]; then
           # 如果原来没有 nginx 配置，需要获取 nginx 端口信息
          [ -z "$PORT_NGINX"  ] && input_nginx_port
          until [ -n "$ARGO_RUNS" ]; do
            [ "$ARGO_READY" != 'argo_ready' ] && input_argo_auth is_add_protocols
            [ -n "$ARGO_RUNS" ] && local ARGO_READY=argo_ready && break
          done
        else
          until [ -n "$VLESS_HOST_DOMAIN" ]; do
            (( DOMAIN_ERROR_TIME-- )) || true
            [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text   3) \n"
          done
          local ORIGIN_READY=origin_ready
        fi
      fi
    fi
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_VLESS_WS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_VLESS_WS
  fi

  # 如之前没有 ws，现新增的 ws，则确认服务器 IP 和输入 cdn
  if [[ "${#CDN[@]}" = '0' && ( "$ARGO_READY" = 'argo_ready' || "$ORIGIN_READY" = 'origin_ready' ) ]]; then
    if grep -qi 'cloudflare' <<< "$ASNORG4$ASNORG6"; then
      if grep -qi 'cloudflare' <<< "$ASNORG6" && [ -n "$WAN4" ] && ! grep -qi 'cloudflare' <<< "$ASNORG4"; then
        SERVER_IP_DEFAULT=$WAN4
      elif grep -qi 'cloudflare' <<< "$ASNORG4" && [ -n "$WAN6" ] && ! grep -qi 'cloudflare' <<< "$ASNORG6"; then
        SERVER_IP_DEFAULT=$WAN6
      else
        local a=6
        until [ -n "$SERVER_IP" ]; do
          ((a--)) || true
          [ "$a" = 0 ] && error "\n $(text 3) \n"
          reading "\n $(text 46) " SERVER_IP
        done
      fi
    elif [ -n "$WAN4" ]; then
      SERVER_IP_DEFAULT=$WAN4
    elif [ -n "$WAN6" ]; then
      SERVER_IP_DEFAULT=$WAN6
    fi

    # 输入服务器 IP,默认为检测到的服务器 IP，如果全部为空，则提示并退出脚本
    [ -z "$SERVER_IP" ] && reading "\n $(text 10) " SERVER_IP
    SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"} && WS_SERVER_IP_SHOW=$SERVER_IP
    [ -z "$SERVER_IP" ] && error " $(text 47) "

    input_cdn
  fi

  # 获取 H2 + Reality 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_H2_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_H2_REALITY
  fi

  # 获取 gRPC + Reality 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_GRPC_REALITY=${REINSTALL_PORTS[POSITION]}
    NEED_PRIVATE_KEY='need_private_key'
  else
    unset PORT_GRPC_REALITY
  fi

  # 如之前没有 Reality，现新增的 reality，则确认 privateKey
  [[ "${#REALITY_PRIVATE[@]}" = 0 && "${NEED_PRIVATE_KEY}" = 'need_private_key' ]] && input_reality_key

  # 让 ShadowTLS 和 shadowsocks 密码相同
  if [[ -n "$SHADOWTLS_PASSWORD" && -z "$SHADOWSOCKS_PASSWORD" ]]; then
    SIP022_PASSWORD=$SHADOWTLS_PASSWORD
  elif [[ -z "$SHADOWTLS_PASSWORD" && -n "$SHADOWSOCKS_PASSWORD" ]]; then
    SIP022_PASSWORD=$SHADOWSOCKS_PASSWORD
  fi

  # 获取 anytls 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_ANYTLS=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_ANYTLS
  fi

  # 获取 naive 端口
  CHECK_PROTOCOLS=$(asc "$CHECK_PROTOCOLS" ++)
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ "$CHECK_PROTOCOLS" ]]; then
    POSITION=$(awk -v target=$CHECK_PROTOCOLS '{ for(i=1; i<=NF; i++) if($i == target) { print i-1; break } }' <<< "${INSTALL_PROTOCOLS[*]}")
    PORT_NAIVE=${REINSTALL_PORTS[POSITION]}
  else
    unset PORT_NAIVE
  fi

  # 生成各协议的 json 文件
  sing-box_json change

  # 无 ws 协议且无订阅时清理 nginx：先于守护文件生成，确保 ExecStartPre / start_pre 与最终状态一致
  if ! ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && [[ -s ${WORK_DIR}/nginx.conf && "$IS_SUB" = 'no_sub' ]]; then
    nginx_stop
    rm -f ${WORK_DIR}/nginx.conf
    unset PORT_NGINX
  fi

  # 生成 Nginx 配置文件（按最终状态）
  [ -n "$PORT_NGINX" ] && export_nginx_conf_file

  # 重新生成 Sing-box 守护进程文件
  sing-box_systemd

  # 如有需要，安装和删除 Argo 服务
  if ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1; then
    if [[ "$ARGO_OR_ORIGIN_RULES" != '2' && "$ARGO_ORIGIN_RULES_STATUS" != 'is_origin' && ! -s ${ARGO_DAEMON_FILE} ]]; then
      argo_systemd
      cmd_systemctl enable argo >/dev/null 2>&1
    fi
  elif [ -s ${ARGO_DAEMON_FILE} ]; then
    # 无 ws 协议：固定隧道（token/json）保留 argo；临时隧道删除
    if [[ "$ARGO_TYPE" != 'is_token_argo' && "$ARGO_TYPE" != 'is_json_argo' ]]; then
      cmd_systemctl disable argo >/dev/null 2>&1
      rm -f ${ARGO_DAEMON_FILE}
      [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.*
    fi
  fi

  # 热更 sing-box（SIGHUP 重新加载配置，PID 不变）
  cmd_systemctl reload sing-box

  # 同步 nginx 进程：需要则启动/热重载，不需要则停止
  nginx_sync

  # 打开防火墙相关端口
  sync_firewall_rules

  # 等待服务启动
  sleep 3

  # 再次检测状态，运行 sing-box
  check_install

  # 导出节点和订阅服务信息
  export_list
}

