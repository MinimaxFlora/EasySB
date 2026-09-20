# ------------------------------------------------------------------------------
# 七、配置生成与变更 / Configuration generation and editing
# ------------------------------------------------------------------------------
# 更换优选域名 / reality SNI / 节点名 / UUID
change_config() {
  [ ! -d "${WORK_DIR}" ] && error " $(text 107) "

  local MENU_IDX=() MENU_KEY=() MENU_VAL=()

  # 优选 CDN
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && local CDN_NOW=$(awk -F '"' '/"CDN"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) && MENU_IDX+=(128) && MENU_KEY+=(cdn) && MENU_VAL+=("$CDN_NOW")

  # Reality SNI
  ls ${WORK_DIR}/conf/*reality_inbounds.json >/dev/null 2>&1 && local SNI_NOW=$(awk 'match($0, /"server_name"[[:space:]]*:[[:space:]]*"[^"]+"/){gsub(/.*: *"/,""); gsub(/".*/,""); print; exit}' ${WORK_DIR}/conf/*reality_inbounds.json) && MENU_IDX+=(129) && MENU_KEY+=(sni) && MENU_VAL+=("$SNI_NOW")

  # 监听端口
  local PORTS_NOW=$(awk -F ':|,' '/"listen_port"/{print $2}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null)
  if [ -n "$PORTS_NOW" ]; then
    MENU_IDX+=(30) && MENU_KEY+=(ports) && MENU_VAL+=("$(format_ports_display ${PORTS_NOW})")
  fi

  # 节点名
  local NAME_NOW=$(awk '/"tag"/{gsub(/^.*"tag": *"/,""); gsub(/".*/,""); sub(/ [^ ]*$/,""); print; exit}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null)
  [ -n "$NAME_NOW" ] && MENU_IDX+=(130) && MENU_KEY+=(name) && MENU_VAL+=("$NAME_NOW")

  # UUID / Password
  local UUID_NOW="$(awk -F'"' '/"uuid"[[:space:]]*:[[:space:]]*"/ || /"id"[[:space:]]*:[[:space:]]*"/ {print $4; exit}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null)"
  [ -n "$UUID_NOW" ] && MENU_IDX+=(131) && MENU_KEY+=(uuid) && MENU_VAL+=("$UUID_NOW")

  # 服务器 IP
  ls ${WORK_DIR}/conf/*-ws*inbounds.json >/dev/null 2>&1 && local SERVER_IP_NOW=$(awk -F '"' '/"WS_SERVER_IP_SHOW"/{print $4; exit}' ${WORK_DIR}/conf/*-ws*inbounds.json) || local SERVER_IP_NOW=$([ -s ${WORK_DIR}/list ] && grep -A1 '"tag"' ${WORK_DIR}/list | sed -E '/-ws(-tls)*",$/{N;d}' | awk -F '"' '/"server"/{count++; if (count == 1) {print $4; exit}}')
  [ -n "$SERVER_IP_NOW" ] && MENU_IDX+=(132) && MENU_KEY+=(serverip) && MENU_VAL+=("$SERVER_IP_NOW")

  # 从 sing-box 格式的 list 中提取 client-fingerprint，取第一个匹配值；无 list（未开启订阅）时默认 chrome
  local FP_NOW=chrome
  [ -s ${WORK_DIR}/list ] && FP_NOW=$(awk -F '"' '/"fingerprint"/{print $4; exit}' ${WORK_DIR}/list)
  [ -n "$FP_NOW" ] || FP_NOW=chrome
  [ -n "$FP_NOW" ] && MENU_IDX+=(48) && MENU_KEY+=(fingerprint) && MENU_VAL+=("$FP_NOW")

  # 指定网络出口
  local BIND_IFACE_NOW=$(awk -F '"' '/"bind_interface"[[:space:]]*:[[:space:]]*"/{print $4}' "${WORK_DIR}/conf/01_outbounds.json" 2>/dev/null)
  MENU_IDX+=(67) && MENU_KEY+=(bindinterface) && MENU_VAL+=("${BIND_IFACE_NOW:-default}")

  # 订阅开关（基于 nginx.conf 文件内容检测）
  if [ -s "${WORK_DIR}/nginx.conf" ] && \
     grep -qE 'location ~ \^/[^/]+/auto \{' "${WORK_DIR}/nginx.conf" 2>/dev/null; then
    MENU_IDX+=(109) && MENU_KEY+=(subscribe) && MENU_VAL+=("$(text 109)")
  else
    MENU_IDX+=(108) && MENU_KEY+=(subscribe) && MENU_VAL+=("$(text 108)")
  fi

  # Hysteria2 带宽和端口跳跃（仅在 Hysteria2 已安装时显示）
  if ls ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1; then
    local HY2_LINE=''
    [ -s ${WORK_DIR}/subscribe/proxies ] && HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    # 读取服务端 ignore_client_bandwidth 当前值：true 时服务端忽略客户端带宽、双端使用 BBR，订阅不再下发 up/down
    local HY2_CONF_NOW=$(ls ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json 2>/dev/null | sed -n '1p')
    local HY2_IGNORE_NOW=false
    [ -s "$HY2_CONF_NOW" ] && HY2_IGNORE_NOW=$(jq_exec -r '.inbounds[]? | select(.type == "hysteria2") | .ignore_client_bandwidth // false' "$HY2_CONF_NOW" 2>/dev/null)
    if [ "$HY2_IGNORE_NOW" = 'true' ]; then
      IS_HY2_IGNORE=is_hy2_ignore
      MENU_IDX+=(187)
    else
      unset IS_HY2_IGNORE
      MENU_IDX+=(188)
    fi
    MENU_KEY+=(hy2cc) && MENU_VAL+=("")

    # 服务端已忽略客户端带宽时，订阅不含 up/down，带宽修改项无意义，隐藏
    if [ "$IS_HY2_IGNORE" != 'is_hy2_ignore' ]; then
    if [[ "$HY2_LINE" =~ up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_UP_NOW="${BASH_REMATCH[1]}"
      HY2_DOWN_NOW="${BASH_REMATCH[2]}"
    elif [[ "$HY2_LINE" =~ down:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\".*up:[[:space:]]*\"([0-9]+)[[:space:]]*Mbps\" ]]; then
      HY2_DOWN_NOW="${BASH_REMATCH[1]}"
      HY2_UP_NOW="${BASH_REMATCH[2]}"
    fi
    HY2_UP_NOW=${HY2_UP_NOW:-200}
    HY2_DOWN_NOW=${HY2_DOWN_NOW:-1000}

    MENU_IDX+=(140) && MENU_KEY+=(hy2bw) && MENU_VAL+=("${HY2_UP_NOW}/${HY2_DOWN_NOW}")
    fi

    if grep -q 'realm-opts' <<< "$HY2_LINE"; then
      local HY2_REALM_ACTION="$(text 63)"
      MENU_IDX+=(63)
    else
      local HY2_REALM_ACTION="$(text 65)"
      MENU_IDX+=(65)
    fi
    MENU_KEY+=(hy2realm) && MENU_VAL+=("${HY2_REALM_ACTION}")

    check_port_hopping_nat
    MENU_IDX+=(139) && MENU_KEY+=(hy2hopping) && MENU_VAL+=("${HY2_PORT_HOPPING_RANGE}")
  fi

  # 自定义路由规则（仅支持 TUN 且 warp-ep 出站存在时显示；无 TUN 时无该出站，隐藏入口）
  [ "$IS_TUN" = 'is_tun' ] && grep -q '"warp-ep"' ${WORK_DIR}/conf/02_endpoints.json 2>/dev/null && {
    CUSTOM_ROUTE_COUNT=$(custom_route_count)
    MENU_IDX+=(150) && MENU_KEY+=(customroute) && MENU_VAL+=("${CUSTOM_ROUTE_COUNT}")
    MENU_IDX+=(174) && MENU_KEY+=(warpaccount) && MENU_VAL+=("")
  }

  [ "${#MENU_IDX[@]}" -eq 0 ] && error " $(text 107) "

  # 显示动态菜单
  hint "\n $(text 127)\n"
  for MENU_INDEX in "${!MENU_IDX[@]}"; do
    local VAL_ITEM="${MENU_VAL[MENU_INDEX]}"
    local RAW_ITEM
    eval "RAW_ITEM=\"\${${L}[${MENU_IDX[MENU_INDEX]}]}\""
    eval "hint \" $(printf '%2d' $(( MENU_INDEX+1 ))). ${RAW_ITEM}\""
  done
  hint ""
  reading " $(text 24) " CHOOSE_NODE_INFO

  if ! [[ "$CHOOSE_NODE_INFO" =~ ^[0-9]+$ ]] || \
     [ "$CHOOSE_NODE_INFO" -lt 1 ] || \
     [ "$CHOOSE_NODE_INFO" -gt "${#MENU_IDX[@]}" ]; then
    info " $(text 135) " && return
  fi

  local IDX=$(( CHOOSE_NODE_INFO - 1 ))
  local KEY="${MENU_KEY[IDX]}"
  local OLD="${MENU_VAL[IDX]}"

  # 特殊操作路由（不走通用替换逻辑）
  if  [ "$KEY" = "cdn" ]; then
    input_cdn
    ls ${WORK_DIR}/conf/*vmess-ws*inbounds.json >/dev/null 2>&1 && sed -i "s|CDN\": \".*\"|CDN\": \"${CDN}\"|g; s|CDN_PORT\": \".*\"|CDN_PORT\": \"${CDN_PORT[17]}\"|g" ${WORK_DIR}/conf/*vmess-ws*inbounds.json 2>/dev/null

    ls ${WORK_DIR}/conf/*vless-ws*inbounds.json >/dev/null 2>&1 && sed -i "s|CDN\": \".*\"|CDN\": \"${CDN}\"|g; s|CDN_PORT\": \".*\"|CDN_PORT\": \"${CDN_PORT[18]}\"|g" ${WORK_DIR}/conf/*vless-ws*inbounds.json 2>/dev/null

    export_list
    return
  elif [ "$KEY" = "ports" ]; then
    change_port_mode
    return
  elif [ "$KEY" = "hy2bw" ]; then
    # 修改 Hysteria2 带宽
    local HY2_UP HY2_DOWN
    while true; do
      reading " $(text 141) " HY2_UP
      [[ "$HY2_UP" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 143) "
    done
    while true; do
      reading " $(text 142) " HY2_DOWN
      [[ "$HY2_DOWN" =~ ^[1-9][0-9]*$ ]] && break
      warning " $(text 143) "
    done
    [ -s ${WORK_DIR}/subscribe/proxies ] && sed -i -E "s/(up: \")([0-9]+)( Mbps\")/\1${HY2_UP}\3/g; s/(down: \")([0-9]+)( Mbps\")/\1${HY2_DOWN}\3/g" ${WORK_DIR}/subscribe/proxies
    hint " $(text 112) "
    export_list
    return
  elif [ "$KEY" = "hy2cc" ]; then
    # 切换 Hysteria2 服务端 ignore_client_bandwidth：true = 忽略客户端带宽、双端 BBR，订阅不含 up/down
    local HY2_CONF_NOW=$(ls ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json 2>/dev/null | sed -n '1p')
    if [ -s "$HY2_CONF_NOW" ]; then
      local TMP_FILE="${HY2_CONF_NOW}.tmp"
      local HY2_IGNORE_NOW=$(jq_exec -r '.inbounds[]? | select(.type == "hysteria2") | .ignore_client_bandwidth // false' "$HY2_CONF_NOW" 2>/dev/null)
      if [ "$HY2_IGNORE_NOW" = 'true' ]; then
        # 已开启 -> 关闭：订阅将重新包含 up/down，复用 hy2bw 的输入文案询问
        local HY2_UP HY2_DOWN
        while true; do
          reading " $(text 141) " HY2_UP
          [[ "$HY2_UP" =~ ^[1-9][0-9]*$ ]] && break
          warning " $(text 143) "
        done
        while true; do
          reading " $(text 142) " HY2_DOWN
          [[ "$HY2_DOWN" =~ ^[1-9][0-9]*$ ]] && break
          warning " $(text 143) "
        done
        jq_exec '.inbounds |= map(if .type == "hysteria2" then .ignore_client_bandwidth = false else . end)' "$HY2_CONF_NOW" > "$TMP_FILE" && mv "$TMP_FILE" "$HY2_CONF_NOW"
        unset IS_HY2_IGNORE
        hint " $(text 190) "
      else
        # 已关闭 -> 开启：服务端忽略客户端带宽，客户端订阅不再下发 up/down
        jq_exec '.inbounds |= map(if .type == "hysteria2" then .ignore_client_bandwidth = true else . end)' "$HY2_CONF_NOW" > "$TMP_FILE" && mv "$TMP_FILE" "$HY2_CONF_NOW"
        IS_HY2_IGNORE=is_hy2_ignore
        hint " $(text 189) "
      fi
      cmd_systemctl reload sing-box
      export_list
    fi
    return
  elif [ "$KEY" = "hy2realm" ]; then
    # 添加 / 删除 Hysteria2 Realm；菜单已明确显示开启/关闭动作，这里不再二次确认 Realm 本身
    # 判断依据与菜单显示一致：检查 subscribe/proxies 中是否有 realm-opts
    local HY2_LINE=''
    [ -s ${WORK_DIR}/subscribe/proxies ] && HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    if grep -q 'realm-opts' <<< "$HY2_LINE"; then
      # 已开启 → 直接关闭，不需要二次确认
      set_hy2_realm_config disable
      sync_hy2_warp_route disable
    else
      # 未开启 → 获取配置后开启，询问 WARP 辅助打洞
      fetch_nodes_value
      # Realm 与端口跳跃互斥：端口跳跃已开启时需确认，确认后先关闭端口跳跃
      check_port_hopping_nat
      if [ -n "$PORT_HOPPING_START" ] && [ -n "$PORT_HOPPING_END" ]; then
        local HY2_CONFIRM
        reading "\n $(text 110) " HY2_CONFIRM
        [[ "${HY2_CONFIRM,,}" =~ ^(y|yes)$ ]] || return
        del_port_hopping_nat
        unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
      fi
      IS_HY2_REALM=is_hy2_realm
      HY2_REALM_ID="${HY2_REALM_ID:-${UUID[12]:-${UUID_CONFIRM}}}"
      input_hy2_warp
      set_hy2_realm_config enable
      [ "$IS_HY2_WARP" = 'is_hy2_warp' ] && sync_hy2_warp_route enable || sync_hy2_warp_route disable
    fi
    cmd_systemctl reload sing-box
    export_list
    return
  elif [ "$KEY" = "hy2hopping" ]; then
    # 修改 Hysteria2 端口跳跃
    check_port_hopping_nat
    local OLD_START="$PORT_HOPPING_START" OLD_END="$PORT_HOPPING_END"
    # Realm 与端口跳跃互斥：Realm 已开启时先确认，确认后才进入端口跳跃流程
    local HY2_LINE=''
    [ -s ${WORK_DIR}/subscribe/proxies ] && HY2_LINE=$(grep 'type: hysteria2' ${WORK_DIR}/subscribe/proxies)
    if grep -q 'realm-opts' <<< "$HY2_LINE"; then
      local HY2_CONFIRM
      reading "\n $(text 183) " HY2_CONFIRM
      [[ "${HY2_CONFIRM,,}" =~ ^(y|yes)$ ]] || return
      set_hy2_realm_config disable
      sync_hy2_warp_route disable
    fi
    hint "\n $(text 97) \n"

    local HOPPING_ERROR_TIME=6
    local NEW_RANGE=""
    until [ -n "$IS_HOPPING_SET" ]; do
      if [ -z "$NEW_RANGE" ]; then
        (( HOPPING_ERROR_TIME-- )) || true
        case "$HOPPING_ERROR_TIME" in
          0 ) error "\n $(text 3) \n" ;;
          5 ) reading " $(text 98) " NEW_RANGE ;;
          * ) reading " $(text 98) " NEW_RANGE ;;
        esac
      fi

      # 预处理：将所有分隔符统一为冒号，过滤非法字符
      NEW_RANGE=$(sed 's/[-－—：]/:/g' <<< "$NEW_RANGE" | tr -cd '0-9:')

      if [[ -z "$NEW_RANGE" || "${NEW_RANGE,,}" =~ ^(n|no)$ ]]; then
        # 禁用端口跳跃
        [ -n "$OLD_START" ] && [ -n "$OLD_END" ] && del_port_hopping_nat
        unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
        IS_HOPPING_SET=true
      elif [[ "$NEW_RANGE" =~ ^[0-9]{4,5}:[0-9]{4,5}$ ]]; then
        local NEW_START=${NEW_RANGE%:*} NEW_END=${NEW_RANGE#*:}
        if [[ "$NEW_START" -lt "$NEW_END" && "$NEW_START" -ge "$MIN_HOPPING_PORT" && "$NEW_END" -le "$MAX_HOPPING_PORT" ]]; then
          # 删除旧规则，添加新规则
          [ -n "$OLD_START" ] && [ -n "$OLD_END" ] && del_port_hopping_nat
          PORT_HOPPING_START=$NEW_START
          PORT_HOPPING_END=$NEW_END
          HY2_PORT_HOPPING_RANGE="$NEW_RANGE"
          local HOPPING_TARGET="$PORT_HOPPING_TARGET"
          [ -z "$HOPPING_TARGET" ] && HOPPING_TARGET=$(awk -F '[:,]' '/"listen_port"/{print $2; exit}' ${WORK_DIR}/conf/*_${NODE_TAG[1]}_inbounds.json 2>/dev/null | tr -d ' ')
          # 静默添加端口跳跃规则，不显示 UFW 检测和成功提示
          (add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$HOPPING_TARGET") >/dev/null 2>&1
          IS_HOPPING_SET=true
        else
          warning "\n $(text 36) " && unset NEW_RANGE
        fi
      else
        warning "\n $(text 36) " && unset NEW_RANGE
      fi
    done

    export_list
    return
  elif [ "$KEY" = "customroute" ]; then
    custom_route_menu
    return
  elif [ "$KEY" = "warpaccount" ]; then
    change_warp_account
    return
  elif [ "$KEY" = "fingerprint" ]; then
    # 修改客户端指纹
    hint "\n $(text 51) \n" && reading " $(text 24) " FP_CHOICE
    case "$FP_CHOICE" in
      ""|1) NEW_VAL="chrome" ;;
      2 ) NEW_VAL="firefox" ;;
      * ) NEW_VAL="$FP_CHOICE" ;;
    esac
    [[ ! "${NEW_VAL,,}" =~ ^[0-9a-z]+$ ]] && error " $(text 56) " || FINGER_PRINT="$NEW_VAL"
    export_list
    return
  elif [ "$KEY" = "bindinterface" ]; then
    # 指定网络出口 — 获取系统接口列表 + 选择 + 更新 JSON
    local IFACE_LIST=() CHOOSE_BIND IDX=2 TMP_FILE="${WORK_DIR}/conf/01_outbounds.json.tmp"

    if command -v ip >/dev/null 2>&1; then
      while read -r _ iface; do
        iface="${iface%%:*}"
        iface="${iface%%@*}"
        [ "$iface" != "lo" ] && IFACE_LIST+=("$iface")
      done < <(ip -o link show up 2>/dev/null)
    elif command -v ifconfig >/dev/null 2>&1; then
      while read -r iface _; do
        iface="${iface%%:}"
        [ "$iface" != "lo" ] && IFACE_LIST+=("$iface")
      done < <(ifconfig -a 2>/dev/null | awk '/^[a-zA-Z]/')
    else
      for IFACE_ITEM in /sys/class/net/*; do
        IFACE_ITEM="${IFACE_ITEM##*/}"
        [ "$IFACE_ITEM" != "lo" ] && IFACE_LIST+=("$IFACE_ITEM")
      done
    fi
    mapfile -t IFACE_LIST < <(printf '%s\n' "${IFACE_LIST[@]}" | sort -u)
    [ "${#IFACE_LIST[@]}" -eq 0 ] && warning " $(text 84) " && return

    hint "\n $(text 77) \n"
    hint " $(text 78) "
    for IFACE_ITEM in "${IFACE_LIST[@]}"; do
      hint " $IDX. $IFACE_ITEM"
      ((IDX++))
    done
    hint " 0. $(text 35)"
    hint ""
    reading " $(text 24) " CHOOSE_BIND

    if [[ "$CHOOSE_BIND" == "1" || "${CHOOSE_BIND,,}" == "default" ]]; then
      jq_exec '.outbounds |= map(if .tag == "direct" then del(.bind_interface) else . end)' \
        "${WORK_DIR}/conf/01_outbounds.json" > "$TMP_FILE" && mv "$TMP_FILE" "${WORK_DIR}/conf/01_outbounds.json"
      info " $(text 84) $(text 78 | sed 's/^1\. //')"
    elif [[ "$CHOOSE_BIND" =~ ^[0-9]+$ ]] && [ "$CHOOSE_BIND" -ge 2 ] && [ "$CHOOSE_BIND" -le "$((IDX - 1))" ]; then
      local SELECTED_IF="${IFACE_LIST[$((CHOOSE_BIND - 2))]}"
      jq_exec --arg iface "$SELECTED_IF" '.outbounds |= map(if .tag == "direct" then .bind_interface = $iface else . end)' \
        "${WORK_DIR}/conf/01_outbounds.json" > "$TMP_FILE" && mv "$TMP_FILE" "${WORK_DIR}/conf/01_outbounds.json"
      info " $(text 84) $SELECTED_IF"
    elif [ "$CHOOSE_BIND" == "0" ]; then
      return
    else
      warning " Invalid selection " && return
    fi

    cmd_systemctl reload sing-box
    export_list
    return
  elif [ "$KEY" = "subscribe" ]; then
    # 订阅开关 — 检测 nginx.conf 中是否存在订阅分发 location 块
    if grep -qE 'location ~ \^/[^/]+/auto \{' "${WORK_DIR}/nginx.conf" 2>/dev/null; then
      # 已开启 → 关闭订阅
      info "\n $(text 109) "
      # 检测 Argo 真实状态（Alpine 和 systemd 通用：检查守护进程文件是否存在）
      [ -s ${ARGO_DAEMON_FILE} ] && IS_ARGO=is_argo || IS_ARGO=no_argo
      # 从旧 nginx.conf 读取 PORT_NGINX（确定文件存在，无需条件判断）
      PORT_NGINX=$(awk '/listen/{print $2; exit}' ${WORK_DIR}/nginx.conf)
      IS_SUB=no_sub
      fetch_nodes_value
      # 判断是否还需要 nginx：有 WS 协议且 Argo 反代
      if { [ -n "$PORT_VMESS_WS" ] || [ -n "$PORT_VLESS_WS" ]; } && [ "$IS_ARGO" = 'is_argo' ]; then
        export_nginx_conf_file
      else
        nginx_stop
        rm -f ${WORK_DIR}/nginx.conf
        unset PORT_NGINX
      fi
      # 重新生成守护文件并同步 nginx（systemd ExecStartPre / OpenRC start_pre 与最终状态一致）
      sing-box_systemd
      nginx_sync
      /bin/rm -f ${WORK_DIR}/subscribe/qr
      export_list
      info " $(text 112) "
    else
      # 未开启 → 开启订阅
      info "\n $(text 108) "
      IS_SUB=is_sub
      # 确保 nginx 已安装
      if ! command -v nginx >/dev/null 2>&1; then
        info "\n $(text 7) nginx"
        ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
      fi
      check_arch
      [ ! -e "${WORK_DIR}/qrencode" ] && \
        wget --no-check-certificate --continue --tries=2 --timeout=10 -qO ${WORK_DIR}/qrencode \
          ${GH_PROXY}https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$QRENCODE_ARCH 2>/dev/null \
          && chmod +x ${WORK_DIR}/qrencode
      fetch_nodes_value
      [ -z "$PORT_NGINX" ] && input_nginx_port
      export_nginx_conf_file
      # 重新生成守护文件并同步 nginx（含 Alpine / CentOS7，重启后 nginx 随服务拉起）
      sing-box_systemd
      nginx_sync
      export_list
      info " $(text 112) "
    fi
    return
  fi

  hint ""
  [ -z "$NEW_VAL" ] && reading " $(text 134) " NEW_VAL
  [ -z "$NEW_VAL" ] && info " $(text 135) " && return

  # 各 key 的校验
  if [ "$KEY" = "uuid" ]; then
    [[ ! "${NEW_VAL,,}" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] && error " $(text 4) "
  elif [ "$KEY" = "sni" ]; then
    ssl_certificate "$NEW_VAL"
  elif [ "$KEY" = "serverip" ]; then
    is_valid_server_addr "$NEW_VAL" || error " $(text 133) "
  fi

  # 批量替换，更换服务IP和指纹不需重启服务
  if [[ "$KEY" =~ ^(serverip|cdn)$ ]]; then
    # IP 在配置里出现的形式有多种，逐一替换
    find ${WORK_DIR} -type f | xargs -P 50 sed -i -e "s|\"server\": \"${OLD}\"|\"server\": \"${NEW_VAL}\"|g; s|\"WS_SERVER_IP_SHOW\": \"${OLD}\"|\"WS_SERVER_IP_SHOW\": \"${NEW_VAL}\"|g" 2>/dev/null

    # 同时更新 subscribe/list 等文本文件中可能出现的裸 IP
    find ${WORK_DIR}/subscribe -type f 2>/dev/null | xargs -P 50 sed -i "s|${OLD}|${NEW_VAL}|g" 2>/dev/null
  else
    find ${WORK_DIR} -type f | xargs -P 50 sed -i "s|${OLD}|${NEW_VAL}|g" 2>/dev/null
    [[ ! "$KEY" =~ ^(fingerprint)$ ]] && cmd_systemctl reload sing-box
  fi
  export_list
}

