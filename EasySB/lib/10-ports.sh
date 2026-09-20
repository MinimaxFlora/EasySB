# ------------------------------------------------------------------------------
# 十二、端口编排与端口跳跃 / Port planning and port hopping
# ------------------------------------------------------------------------------
# 添加端口跳跃
add_port_hopping_nat() {
  local PORT_HOPPING_START=$1
  local PORT_HOPPING_END=$2
  local PORT_HOPPING_TARGET=$3
  local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
  local FW_BACKEND
  local FW_CHECK=() FW_INSTALL=() FW_TO_INSTALL=()

  FW_BACKEND=$(check_port_hopping_firewall)

  case "$FW_BACKEND" in
    ufw )
      info "\n $(text 144) \n"
      ;;
    alpine-iptables )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      ;;
    firewalld )
      command -v firewall-cmd >/dev/null 2>&1 || FW_TO_INSTALL+=("firewalld")
      ;;
    * )
      command -v iptables >/dev/null 2>&1 || FW_TO_INSTALL+=("iptables")
      if ! command -v netfilter-persistent >/dev/null 2>&1 ||
         ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        FW_TO_INSTALL+=("iptables-persistent")
      fi
      ;;
  esac

  if [ "${#FW_TO_INSTALL[@]}" -gt 0 ]; then
    FW_TO_INSTALL=($(printf "%s\n" "${FW_TO_INSTALL[@]}" | sort -u))
    info "\n $(text 7) $(sed "s/ /,&/g" <<< "${FW_TO_INSTALL[*]}") \n"
    [ "$SYSTEM" != 'CentOS' ] && ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} "${FW_TO_INSTALL[@]}" >/dev/null 2>&1
  fi

  if [ "$FW_BACKEND" = 'firewalld' ]; then
    [ "$(systemctl is-active firewalld 2>/dev/null)" != 'active' ] && cmd_systemctl enable firewalld >/dev/null 2>&1
    [ "$(firewall-cmd --zone=public --get-target 2>/dev/null)" != 'ACCEPT' ] && firewall-cmd --zone=public --set-target=ACCEPT --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi

  if [ "$FW_BACKEND" = 'ufw' ]; then
    add_port_hopping_ufw_rules "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$PORT_HOPPING_TARGET" || warning "\n $(text 146) \n"

  elif [ "$SYSTEM" = 'Alpine' ]; then
    # 添加防火墙规则
    iptables  --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null

    # 将 iptables, ip6tables 添加到默认运行级别
    rc-update show default | grep -q 'iptables'  || rc-update add iptables  >/dev/null 2>&1
    rc-update show default | grep -q 'ip6tables' || rc-update add ip6tables >/dev/null 2>&1
    rc-update show default | grep -q 'iptables' && rc-update show default | grep -q 'ip6tables' || warning "\n $(text 96) \n"

    # 保存当前的 iptables, ip6tables 规则集，以便在开机时恢复
    rc-service iptables  save >/dev/null 2>&1
    rc-service ip6tables save >/dev/null 2>&1

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    if [ "$(firewall-cmd --zone=public --query-masquerade --permanent 2>/dev/null)" != 'yes' ]; then
      firewall-cmd --zone=public --add-masquerade --permanent >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      [ "$(firewall-cmd --zone=public --query-masquerade --permanent 2>/dev/null)" = 'yes' ] && info "\n firewalld masquerade $(text 28) $(text 37) \n" || warning "\n firewalld masquerade $(text 28) $(text 38) \n"
    fi

    # 添加防火墙规则
    firewall-cmd --zone=public --add-forward-port=port=${PORT_HOPPING_START}-${PORT_HOPPING_END}:proto=udp:toport=${PORT_HOPPING_TARGET} --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

  else
    # 添加防火墙规则
    iptables  --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -A PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null

    # 保存当前的 iptables, ip6tables 规则集，以便在开机时恢复
    [ "$(systemctl is-active netfilter-persistent)" != 'active' ] && warning "\n $(text 96) \n" || netfilter-persistent save 2>/dev/null
  fi
}

# 删除端口跳跃
del_port_hopping_nat() {
  local FW_BACKEND
  FW_BACKEND=$(check_port_hopping_firewall)

  check_port_hopping_nat
  [ -z "$PORT_HOPPING_START" ] && return

  if [ "$FW_BACKEND" = 'ufw' ]; then
    del_port_hopping_ufw_rules || warning "\n $(text 146) \n"

  elif [ "$SYSTEM" = 'Alpine' ]; then
    local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
    iptables  --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    rc-service iptables  save >/dev/null 2>&1
    rc-service ip6tables save >/dev/null 2>&1

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    firewall-cmd --zone=public --permanent --remove-forward-port=port=${PORT_HOPPING_START}-${PORT_HOPPING_END}:proto=udp:toport=${PORT_HOPPING_TARGET} >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

  else
    local COMMENT="NAT ${PORT_HOPPING_START}:${PORT_HOPPING_END} to ${PORT_HOPPING_TARGET} (Sing-box Family Bucket)"
    iptables  --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    ip6tables --table nat -D PREROUTING -p udp --dport ${PORT_HOPPING_START}:${PORT_HOPPING_END} -m comment --comment "$COMMENT" -j DNAT --to-destination :${PORT_HOPPING_TARGET} 2>/dev/null
    [ "$(systemctl is-active netfilter-persistent)" = 'active' ] && netfilter-persistent save 2>/dev/null
  fi
}

# 查端口跳跃的 dnat 端口
check_port_hopping_nat() {
  local FW_BACKEND
  FW_BACKEND=$(check_port_hopping_firewall)

  unset PORT_HOPPING_START PORT_HOPPING_END HY2_PORT_HOPPING_RANGE
  PORT_HOPPING_TARGET=$(awk -F '[:,]' '/"listen_port"/{print $2; exit}' ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json 2>/dev/null | tr -d ' ')

  if [ "$FW_BACKEND" = 'ufw' ]; then
    check_port_hopping_ufw_rules

  elif [ "$SYSTEM" = 'Alpine' ]; then
    local IPTABLES_PREROUTING_LIST=$(iptables --table nat --list-rules PREROUTING 2>/dev/null | grep 'Sing-box Family Bucket')
    [ -n "$IPTABLES_PREROUTING_LIST" ] && \
      HY2_PORT_HOPPING_RANGE=$(awk '{for (i=1; i<=NF; i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST") && \
      PORT_HOPPING_TARGET=$(awk '{for (i=1; i<=NF; i++) if ($i=="--to-destination") {gsub(/^:/,"",$(i+1)); print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST")
    [ -n "$HY2_PORT_HOPPING_RANGE" ] && PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*} && PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}

  elif command -v firewall-cmd >/dev/null 2>&1 || [ "$SYSTEM" = 'CentOS' ]; then
    local FIREWALL_LIST=$(firewall-cmd --zone=public --list-forward-ports --permanent 2>/dev/null | grep "toport=${PORT_HOPPING_TARGET}")
    [ -n "$FIREWALL_LIST" ] && \
      PORT_HOPPING_START=$(sed "s/.*port=\([0-9]\+\)-.*/\1/" <<< "$FIREWALL_LIST") && \
      PORT_HOPPING_END=$(sed "s/.*port=${PORT_HOPPING_START}-\([0-9]\+\):.*/\1/" <<< "$FIREWALL_LIST") && \
      PORT_HOPPING_TARGET=$(sed "s/.*toport=\([0-9]\+\).*/\1/" <<< "$FIREWALL_LIST")

  else
    local IPTABLES_PREROUTING_LIST=$(iptables --table nat --list-rules PREROUTING 2>/dev/null | grep 'Sing-box Family Bucket')
    [ -n "$IPTABLES_PREROUTING_LIST" ] && \
      HY2_PORT_HOPPING_RANGE=$(awk '{for (i=1; i<=NF; i++) if ($i=="--dport") {print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST") && \
      PORT_HOPPING_TARGET=$(awk '{for (i=1; i<=NF; i++) if ($i=="--to-destination") {gsub(/^:/,"",$(i+1)); print $(i+1); exit}}' <<< "$IPTABLES_PREROUTING_LIST")
    [ -n "$HY2_PORT_HOPPING_RANGE" ] && PORT_HOPPING_START=${HY2_PORT_HOPPING_RANGE%:*} && PORT_HOPPING_END=${HY2_PORT_HOPPING_RANGE#*:}
  fi

  [ -n "$PORT_HOPPING_START" ] && [ -n "$PORT_HOPPING_END" ] && HY2_PORT_HOPPING_RANGE="${PORT_HOPPING_START}:${PORT_HOPPING_END}"
}

# 检测 IPv4 IPv6 信息
check_system_ip() {
  [ "$L" = 'C' ] && local IS_CHINESE='?lang=zh-CN'
  local DEFAULT_LOCAL_INTERFACE4=$(ip -4 route show default | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  local DEFAULT_LOCAL_INTERFACE6=$(ip -6 route show default | awk '/default/ {for (i=0; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
  if [ -n ""${DEFAULT_LOCAL_INTERFACE4}${DEFAULT_LOCAL_INTERFACE6}"" ]; then
    local DEFAULT_LOCAL_IP4=$(ip -4 addr show $DEFAULT_LOCAL_INTERFACE4 | sed -n 's#.*inet \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
    local DEFAULT_LOCAL_IP6=$(ip -6 addr show $DEFAULT_LOCAL_INTERFACE6 | sed -n 's#.*inet6 \([^/]\+\)/[0-9]\+.*global.*#\1#gp')
    [ -n "$DEFAULT_LOCAL_IP4" ] && local BIND_ADDRESS4="--bind-address=$DEFAULT_LOCAL_IP4"
    [ -n "$DEFAULT_LOCAL_IP6" ] && local BIND_ADDRESS6="--bind-address=$DEFAULT_LOCAL_IP6"
  fi

  # 并行检测 IPv4 和 IPv6 信息
  {
    local CHECK_IP4=$(wget $BIND_ADDRESS4 -4 -qO- --no-check-certificate --tries=2 --timeout=2 https://ip.cloudflare.now.cc${IS_CHINESE})
    grep -q '.' <<< "$CHECK_IP4" && echo "$CHECK_IP4" > $TEMP_DIR/ip4.json
  }&

  {
    local CHECK_IP6=$(wget $BIND_ADDRESS6 -6 -qO- --no-check-certificate --tries=2 --timeout=2 https://ip.cloudflare.now.cc${IS_CHINESE})
    grep -q '.' <<< "$CHECK_IP6" && echo "$CHECK_IP6" > $TEMP_DIR/ip6.json
  }&

  wait

  [ -s $TEMP_DIR/ip4.json ] &&
  local IP4_JSON=$(cat $TEMP_DIR/ip4.json) &&
  WAN4=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP4_JSON") &&
  COUNTRY4=$(awk -F '"' '/"country"/{print $4}' <<< "$IP4_JSON") &&
  EMOJI4=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP4_JSON") &&
  ASNORG4=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP4_JSON") &&
  rm -f $TEMP_DIR/ip4.json

  [ -s $TEMP_DIR/ip6.json ] &&
  local IP6_JSON=$(cat $TEMP_DIR/ip6.json) &&
  WAN6=$(awk -F '"' '/"ip"/{print $4}' <<< "$IP6_JSON") &&
  COUNTRY6=$(awk -F '"' '/"country"/{print $4}' <<< "$IP6_JSON") &&
  EMOJI6=$(awk -F '"' '/"emoji"/{print $4}' <<< "$IP6_JSON") &&
  ASNORG6=$(awk -F '"' '/"isp"/{print $4}' <<< "$IP6_JSON") &&
  rm -f $TEMP_DIR/ip6.json
}

# 输入起始 port 函数
input_start_port() {
  local NUM=$1
  local PORT_ERROR_TIME=6
  while true; do
    [ "$PORT_ERROR_TIME" -lt 6 ] && unset IN_USED START_PORT
    (( PORT_ERROR_TIME-- )) || true
    if [ "$PORT_ERROR_TIME" = 0 ]; then
      error "\n $(text 3) \n"
    else
      [ -z "$START_PORT" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 11) " START_PORT
    fi
    START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
    if [[ "$START_PORT" =~ ^[1-9][0-9]{2,4}$ && "$START_PORT" -ge "$MIN_PORT" && "$START_PORT" -le "$MAX_PORT" ]]; then
      for port in $(eval echo {$START_PORT..$[START_PORT+NUM-1]}); do
        is_port_in_use "$port" && IN_USED+=("$port")
      done
      [ "${#IN_USED[*]}" -eq 0 ] && break || warning "\n $(text 44) \n"
    fi
  done
}

# 段数 >4 时只显示前 4 段，末尾追加 "等 N 个"（N = 未显示的端口总数）
format_ports_display() {
  local -a PORTS=("$@") SEGS=()
  local -i TOTAL=0 i a b
  local PREV='' SEG_START='' OUT=''
  [ "${#PORTS[@]}" -eq 0 ] && { echo; return; }
  PORTS=($(printf '%s\n' "${PORTS[@]}" | sort -n | uniq))
  TOTAL=${#PORTS[@]}
  SEG_START=${PORTS[0]}
  PREV=${PORTS[0]}
  for ((i=1; i<TOTAL; i++)); do
    if [ $((PREV + 1)) -eq ${PORTS[i]} ]; then
      PREV=${PORTS[i]}
    else
      SEGS+=("$SEG_START $PREV")
      SEG_START=${PORTS[i]}
      PREV=${PORTS[i]}
    fi
  done
  SEGS+=("$SEG_START $PREV")
  if [ "${#SEGS[@]}" -eq 1 ]; then
    read -r a b <<< "${SEGS[0]}"
    [ "$a" -eq "$b" ] && OUT="$a" || OUT="${a} - ${b}"
    if [ "$TOTAL" -gt 6 ]; then
      [ "$L" = 'C' ] && OUT="${OUT}，共 ${TOTAL} 个" || OUT="${OUT}, ${TOTAL} in total"
    fi
  elif [ "${#SEGS[@]}" -le 4 ]; then
    local -a PARTS=()
    for s in "${SEGS[@]}"; do
      read -r a b <<< "$s"
      [ "$a" -eq "$b" ] && PARTS+=("$a") || PARTS+=("${a} - ${b}")
    done
    OUT="${PARTS[0]}"
    for s in "${PARTS[@]:1}"; do OUT="${OUT}, ${s}"; done
  else
    local -a PARTS=()
    local -i SHOWN=0
    for ((i=0; i<4; i++)); do
      read -r a b <<< "${SEGS[i]}"
      SHOWN=$(( SHOWN + b - a + 1 ))
      [ "$a" -eq "$b" ] && PARTS+=("$a") || PARTS+=("${a} - ${b}")
    done
    OUT="${PARTS[0]}"
    for s in "${PARTS[@]:1}"; do OUT="${OUT}, ${s}"; done
    if [ "$L" = 'C' ]; then
      OUT="${OUT} ... 等 $(( TOTAL - SHOWN )) 个"
    else
      OUT="${OUT} ... $(( TOTAL - SHOWN )) more"
    fi
  fi
  echo "$OUT"
}

# -d 菜单：监听端口 → 方式选择（1. 修改开始端口，默认 / 2. 各协议独立端口）
change_port_mode() {
  local PORTS_MODE='' MODE_ERROR=6
  while true; do
    hint "\n $(text 161) "
    reading "\n $(text 24) " PORTS_MODE
    case "${PORTS_MODE:-1}" in
      1 ) change_start_port; return ;;
      2 ) change_independent_port; return ;;
      * ) (( MODE_ERROR-- )) || true
          [ "$MODE_ERROR" = 0 ] && error "\n $(text 3) \n"
          warning " $(text 143) " ;;
    esac
  done
}

# 读取 hysteria2 当前监听端口（未安装时输出为空）
get_hy2_port() {
  ls ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json >/dev/null 2>&1 || return
  awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/,"",$2); print $2; exit}' ${WORK_DIR}/conf/*${NODE_TAG[1]}_inbounds.json 2>/dev/null
}

# 端口应用后的通用后处理（方式 1 / 2 共用）：联动刷新 + 热加载 + hy2 端口跳跃目标重建
apply_ports_post() {
  local HY2_OLD="$1" HY2_NEW="$2"
  fetch_nodes_value
  # nginx 反代端口同步：nginx.conf 存在则重建并热加载（proxy_pass 必须跟随 WS 端口变化，
  # 不依赖 PORT_NGINX 是否已被 IS_SUB/IS_ARGO 分支读入）
  if [ -s "${WORK_DIR}/nginx.conf" ]; then
    [ -z "$PORT_NGINX" ] && PORT_NGINX=$(awk '/listen/{print $2; exit}' ${WORK_DIR}/nginx.conf | tr -d ';')
    # 现有 nginx.conf 已含本地 WS 反代时强制按 is_argo 重建，
    # 避免 IS_ARGO 标志缺失/失效时导出配置丢失 WS 反代（端口变化后必须跟随）
    local _ARGO_BAK="${IS_ARGO-}"
    grep -q 'proxy_pass.*127.0.0.1' "${WORK_DIR}/nginx.conf" 2>/dev/null && IS_ARGO=is_argo
    export_nginx_conf_file
    IS_ARGO="$_ARGO_BAK"
  fi
  nginx_sync
  cmd_systemctl reload sing-box
  [ -n "$ARGO_DOMAIN" ] && export_argo_json_file
  # Hysteria2 端口跳跃目标同步（hy2 端口变化且跳跃已启用时，显式重建 dnat 目标）
  if [ -n "$HY2_OLD" ] && [ -n "$HY2_NEW" ] && [ "$HY2_OLD" != "$HY2_NEW" ]; then
    check_port_hopping_nat
    if [ -n "$PORT_HOPPING_START" ] && [ -n "$PORT_HOPPING_END" ]; then
      del_port_hopping_nat
      (add_port_hopping_nat "$PORT_HOPPING_START" "$PORT_HOPPING_END" "$HY2_NEW") >/dev/null 2>&1
    fi
  fi
  sync_firewall_rules
  sleep 2
  export_list
  # 显示新端口列表
  local PORTS=$(format_ports_display $(awk -F ':|,' '/"listen_port"/{print $2}' ${WORK_DIR}/conf/*_inbounds.json 2>/dev/null))
  [ -n "$PORTS" ] && hint " $(text 164) "
  info " $(text 170) "
}

# 方式 1：修改开始端口（各协议按顺序占用，现有逻辑 + 预览确认 + hy2 跳跃联动）
change_start_port() {
  local OLD_PORTS OLD_START_PORT OLD_CONSECUTIVE_PORTS
  local _STEP_NUM_BAK="${STEP_NUM-}" _TOTAL_STEPS_BAK="${TOTAL_STEPS-}"
  OLD_PORTS=$(awk -F ':|,' '/listen_port/{print $2}' ${WORK_DIR}/conf/*)
  OLD_START_PORT=$(awk 'NR == 1 { min = $0 } { if ($0 < min) min = $0; count++ } END {print min}' <<< "$OLD_PORTS")
  OLD_CONSECUTIVE_PORTS=$(awk 'END { print NR }' <<< "$OLD_PORTS")
  local HY2_OLD=$(get_hy2_port)
  unset STEP_NUM TOTAL_STEPS
  input_start_port $OLD_CONSECUTIVE_PORTS
  STEP_NUM="$_STEP_NUM_BAK"
  TOTAL_STEPS="$_TOTAL_STEPS_BAK"
  [ "$START_PORT" = "$OLD_START_PORT" ] && { info " $(text 135) "; return; }
  # 预览确认（方式 1 / 方式 2 同一套确认交互）
  local NUM="$OLD_CONSECUTIVE_PORTS" OLD_START="$OLD_START_PORT" NEW_START="$START_PORT" NEW_END=$((START_PORT + OLD_CONSECUTIVE_PORTS - 1))
  hint "\n $(text 173) "
  reading "\n $(text 168) " PORTS_CONFIRM
  [ "${PORTS_CONFIRM,,}" != 'y' ] && { info " $(text 135) "; return; }
  for ((a=0; a<$OLD_CONSECUTIVE_PORTS; a++)) do
    [ -s ${WORK_DIR}/conf/${CONF_FILES[a]} ] && sed -i "s/\(.*listen_port.*:\)$((OLD_START_PORT+a))/\1$((START_PORT+a))/" ${WORK_DIR}/conf/*
  done
  apply_ports_post "$HY2_OLD" "$(get_hy2_port)"
}

# 方式 2：各协议独立端口（多选协议 → 逐项询问端口 → 校验 → 预览确认 → 应用）
change_independent_port() {
  local -a LETTERS=() PROTOS=() PORTS=() PROTO_IDX=()
  local -A OWNER=()
  local -i i j
  local letter proto port
  for ((i=0; i<${#PROTOCOL_LIST[@]}; i++)); do
    local -a FILES=(${WORK_DIR}/conf/*${NODE_TAG[i]}_inbounds.json)
    [ -s "${FILES[0]}" ] || continue
    port=$(awk -F '[:,]' '/"listen_port"/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${FILES[0]}")
    [ -n "$port" ] || continue
    letter=$(asc $((i+98)))
    LETTERS+=("$letter"); PROTOS+=("${PROTOCOL_LIST[i]}"); PORTS+=("$port"); PROTO_IDX+=("$i")
    OWNER[$port]="${PROTOCOL_LIST[i]}"
  done
  [ "${#LETTERS[@]}" -eq 0 ] && { info " $(text 135) "; return; }

  # 多选需要修改端口的协议（a = 全部，b.. = 逐协议，留空 = 不修改，顺序 = 输入顺序）
  local MAX_LETTER=$(asc $(( ${#PROTOCOL_LIST[@]} + 97 )))
  local CHOOSE='' SELECTED=()
  hint "\n $(text 162) "
  for ((i=0; i<${#LETTERS[@]}; i++)); do
    local LETTER="${LETTERS[i]}" PROTO="${PROTOS[i]}" PORT="${PORTS[i]}"
    hint " $(text 172) "
  done
  reading "\n $(text 24) " CHOOSE
  if [ -z "$CHOOSE" ]; then
    info " $(text 135) "
    return
  fi
  if [[ "${CHOOSE,,}" =~ ^[aA]$ ]]; then
    SELECTED=("${LETTERS[@]}")
  else
    local FILTERED=$(grep -o . <<< "${CHOOSE,,}" | sed "/[^b-$MAX_LETTER]/d" | awk '!seen[$0]++' | tr -d '\n')
    local TMP=() ch
    while IFS= read -r -n1 ch; do
      [ -n "$ch" ] && [[ " ${LETTERS[*]} " =~ " $ch " ]] && TMP+=("$ch")
    done <<< "$FILTERED"
    SELECTED=("${TMP[@]}")
  fi
  [ "${#SELECTED[@]}" -eq 0 ] && { info " $(text 135) "; return; }

  # 逐协议询问新端口（留空 = 不变；校验：数字范围 / 与他协议重复 / 系统占用，错误即时提示，上限 6 次）
  local -a CHG_LETTERS=() CHG_OLDS=() CHG_NEWS=()
  local chg_letter proto oldport newport conflict new_port err_time
  for ((j=0; j<${#SELECTED[@]}; j++)); do
    chg_letter="${SELECTED[j]}"
    for ((i=0; i<${#LETTERS[@]}; i++)); do
      [ "${LETTERS[i]}" = "$chg_letter" ] && break
    done
    proto="${PROTOS[i]}"; oldport="${PORTS[i]}"
    new_port=''
    err_time=6
    while true; do
      local PROTO="$proto" PORT="$oldport"
      reading " $(text 163) " new_port
      if [ -z "$new_port" ]; then
        newport="$oldport"; break
      fi
      if [[ "$new_port" =~ ^[1-9][0-9]{2,4}$ && "$new_port" -ge "$MIN_PORT" && "$new_port" -le "$MAX_PORT" ]]; then
        conflict="${OWNER[$new_port]-}"
        if [ -n "$conflict" ] && [ "$conflict" != "$proto" ]; then
          local PORT="$new_port" PROTO="$conflict"
          warning " $(text 171) "
          (( err_time-- )) || true
          [ "$err_time" = 0 ] && error "\n $(text 3) \n"
          continue
        fi
        if [ "$new_port" != "$oldport" ] && is_port_in_use "$new_port"; then
          local PORT="$new_port"
          warning " $(text 166) "
          (( err_time-- )) || true
          [ "$err_time" = 0 ] && error "\n $(text 3) \n"
          continue
        fi
        newport="$new_port"; break
      else
        local PORT="$new_port"
        warning " $(text 166) "
        (( err_time-- )) || true
        [ "$err_time" = 0 ] && error "\n $(text 3) \n"
      fi
    done
    [ "$newport" != "$oldport" ] && { unset "OWNER[$oldport]"; OWNER[$newport]="$proto"; }
    [ "$newport" != "$oldport" ] && { CHG_LETTERS+=("$chg_letter"); CHG_OLDS+=("$oldport"); CHG_NEWS+=("$newport"); }
  done

  [ "${#CHG_LETTERS[@]}" -eq 0 ] && { info " $(text 165) "; return; }

  # 变更预览（只列变更项）与确认
  hint "\n $(text 167) "
  for ((j=0; j<${#CHG_LETTERS[@]}; j++)); do
    for ((i=0; i<${#LETTERS[@]}; i++)); do
      [ "${LETTERS[i]}" = "${CHG_LETTERS[j]}" ] && break
    done
    local PROTO="${PROTOS[i]}" OLD="${CHG_OLDS[j]}" NEW="${CHG_NEWS[j]}"
    hint " $(text 169) "
  done
  reading " $(text 168) " PORTS_CONFIRM
  [ "${PORTS_CONFIRM,,}" != 'y' ] && { info " $(text 135) "; return; }

  # 应用（按协议文件替换，避免端口号在其他字段重复出现时误伤）
  local HY2_OLD=$(get_hy2_port)
  for ((j=0; j<${#CHG_LETTERS[@]}; j++)); do
    for ((i=0; i<${#LETTERS[@]}; i++)); do
      [ "${LETTERS[i]}" = "${CHG_LETTERS[j]}" ] && break
    done
    sed -i "/\"listen_port\"/s/[0-9]\+/${CHG_NEWS[j]}/" ${WORK_DIR}/conf/*${NODE_TAG[PROTO_IDX[i]]}_inbounds.json
  done
  apply_ports_post "$HY2_OLD" "$(get_hy2_port)"
}

# 定义 Sing-box 变量
sing-box_variables() {
  STEP_NUM=0
  # 预先用全选协议计算最大总步骤数，用于协议选择提示时显示 (1/?)
  local SAVED_PROTOCOLS=("${INSTALL_PROTOCOLS[@]}")
  INSTALL_PROTOCOLS=(b c d e f g h i j k l m)
  calc_install_steps
  INSTALL_PROTOCOLS=("${SAVED_PROTOCOLS[@]}")

  if grep -qi 'cloudflare' <<< "$ASNORG4$ASNORG6"; then
    if grep -qi 'cloudflare' <<< "$ASNORG6" && [ -n "$WAN4" ] && ! grep -qi 'cloudflare' <<< "$ASNORG4"; then
      SERVER_IP_DEFAULT=$WAN4
    elif grep -qi 'cloudflare' <<< "$ASNORG4" && [ -n "$WAN6" ] && ! grep -qi 'cloudflare' <<< "$ASNORG6"; then
      SERVER_IP_DEFAULT=$WAN6
    else
      # 双栈均为 Cloudflare（或唯一出口为 CF），无法自动反选真实出口，需交互确认
      SERVER_IP_DEFAULT="${SERVER_IP_DEFAULT:-${WAN4:-$WAN6}}"
      local a=6
      until [ -n "$SERVER_IP" ] && is_valid_server_addr "$SERVER_IP"; do
        ((a--)) || true
        [ "$a" = 0 ] && error "\n $(text 3) \n"
        reading "\n (${STEP_NUM}/${TOTAL_STEPS:-?}) $(text 10) " SERVER_IP
        [ -z "$SERVER_IP" ] && SERVER_IP="$SERVER_IP_DEFAULT"
      done
    fi
  elif [ -n "$WAN4" ]; then
    SERVER_IP_DEFAULT=$WAN4
  elif [ -n "$WAN6" ]; then
    SERVER_IP_DEFAULT=$WAN6
  fi

  # 选择安装的协议，由于选项 a 为全部协议，所以选项数不是从 a 开始，而是从 b 开始，处理输入：把大写全部变为小写，把不符合的选项去掉，把重复的选项合并
  MAX_CHOOSE_PROTOCOLS=$(asc $(( CONSECUTIVE_PORTS+96+1 )))
  (( STEP_NUM++ )) || true
  if [ -z "$CHOOSE_PROTOCOLS" ]; then
    hint "\n (${STEP_NUM}/${TOTAL_STEPS:-?}) $(text 49) "
    for e in "${!PROTOCOL_LIST[@]}"; do
      hint " $(asc $(( e+98 ))). ${PROTOCOL_LIST[e]} "
    done
    reading "\n $(text 24) " CHOOSE_PROTOCOLS
  fi

  # 对选择协议的输入处理逻辑：先把所有的大写转为小写，并把所有没有去选项剔除掉，最后按输入的次序排序。如果选项为 a(all) 和其他选项并存，将会忽略 a，如 abc 则会处理为 bc
  [[ ! "${CHOOSE_PROTOCOLS,,}" =~ [b-$MAX_CHOOSE_PROTOCOLS] ]] && INSTALL_PROTOCOLS=($(eval echo {b..$MAX_CHOOSE_PROTOCOLS})) || INSTALL_PROTOCOLS=($(grep -o . <<< "$CHOOSE_PROTOCOLS" | sed "/[^b-$MAX_CHOOSE_PROTOCOLS]/d" | awk '!seen[$0]++'))

  # 协议已确定，按实际选择重新计算总步骤数
  calc_install_steps

  # 显示选择协议及其次序，输入开始端口号
  if [ -z "$START_PORT" ]; then
    (( STEP_NUM++ )) || true
    hint "\n $(text 60) "
    for w in "${!INSTALL_PROTOCOLS[@]}"; do
      [ "$w" -ge 9 ] && hint " $(( w+1 )). ${PROTOCOL_LIST[$(($(asc ${INSTALL_PROTOCOLS[w]}) - 98))]} " || hint " $(( w+1 )) . ${PROTOCOL_LIST[$(($(asc ${INSTALL_PROTOCOLS[w]}) - 98))]} "
    done
    input_start_port ${#INSTALL_PROTOCOLS[@]}
  fi

  # 输出模式选择，输入用于订阅的 Nginx 服务端口号， 后台根据选择安装依赖
  if [[ "$IS_SUB" = 'is_sub' || "$IS_ARGO" = 'is_argo' ]]; then
    (( STEP_NUM++ )) || true
    input_nginx_port
  fi

  # 输入服务器 IP,默认为检测到的服务器 IP，如果全部为空，则提示并退出脚本
  if [ "$IS_FAST_INSTALL" = 'is_fast_install' ]; then
    grep -q '^$' <<< "$SERVER_IP" && SERVER_IP="$SERVER_IP_DEFAULT"
  fi
  if [ -z "$SERVER_IP" ]; then
    if [[ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' || "$IS_FAST_INSTALL" = 'is_fast_install' ]]; then
      SERVER_IP="$SERVER_IP_DEFAULT"
    else
      (( STEP_NUM++ )) || true
      local IP_ERROR_TIME=6
      while true; do
        reading "\n (${STEP_NUM}/${TOTAL_STEPS}) $(text 10) " SERVER_IP
        [ -z "$SERVER_IP" ] && break
        is_valid_server_addr "$SERVER_IP" && break
        (( IP_ERROR_TIME-- )) || true
        [ "$IP_ERROR_TIME" = 0 ] && error "\n $(text 3) \n"
        warning " $(text 133) "
      done
    fi
  fi
  SERVER_IP=${SERVER_IP:-"$SERVER_IP_DEFAULT"} && WS_SERVER_IP_SHOW=$SERVER_IP
  [ -z "$SERVER_IP" ] && error " $(text 47) "

  # 根据 IPv4 和 IPv6 的网络状态，使不同的 DNS 策略
  command -v ping >/dev/null 2>&1 && for i in {1..3}; do
    ping -c 1 -W 1 "151.101.1.91" &>/dev/null && local IS_IPV4=is_ipv4 && break
  done

  if command -v ping6 >/dev/null 2>&1; then
    for i in {1..3}; do
      ping6 -c 1 -W 1 "2a04:4e42:200::347" &>/dev/null && local IS_IPV6=is_ipv6 && break
    done
  elif command -v ping >/dev/null 2>&1; then
    for i in {1..3}; do
      ping -c 1 -W 1 "2a04:4e42:200::347" &>/dev/null && local IS_IPV6=is_ipv6 && break
    done
  fi

  case "${IS_IPV4}@${IS_IPV6}" in
    is_ipv4@is_ipv6)
      STRATEGY=prefer_ipv4
      ;;
    is_ipv4@)
      STRATEGY=ipv4_only
      ;;
    @is_ipv6)
      STRATEGY=ipv6_only
      ;;
    *)
      STRATEGY=prefer_ipv4
      ;;
  esac

  # 检测是否解锁 chatGPT：按服务器地址类型决定检测栈；域名（NAT 动态地址）交由 wget 按系统默认解析，避免域名被误判为 IPv6 栈
  # 仅支持 TUN 时才有 warp-ep 出站与 ChatGPT 分流路由；无 TUN 时 OpenAI 直连，无需探测，也不设置 CHATGPT_OUT
  if [ "$IS_TUN" = 'is_tun' ]; then
    CHATGPT_OUT='warp-ep'
    if [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      local CHATGPT_STACK='-4'
    elif [[ "$SERVER_IP" =~ ^[0-9a-fA-F:]+$ && "$SERVER_IP" =~ : ]]; then
      local CHATGPT_STACK='-6'
    else
      local CHATGPT_STACK=''
    fi
    [ "$(check_chatgpt $CHATGPT_STACK)" = 'unlock' ] && CHATGPT_OUT=direct
  fi

  # 如果选择有 b j k 这些 reality 协议，自定义 reality 公私钥，如果没有则自动生成
  if [ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' ] && [[ "${INSTALL_PROTOCOLS[@]}" =~ 'b'|'j'|'k' ]]; then
    (( STEP_NUM++ )) || true
    input_reality_key
  fi

  # 如选择有 c. hysteria2 时，先选择 Realm / WARP，再选择是否使用端口跳跃。
  # 这三项属于 Hysteria2 子选项，不计入安装总步骤，也不显示步骤编号。
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ 'c' ]]; then
    # Realm 与端口跳跃互斥：仅交互式安装提示；快速 / 非交互安装默认不使用 Realm，无需提示
    [[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' && "$IS_FAST_INSTALL" != 'is_fast_install' ]] && hint "\n $(text 186) \n"
    input_hy2_realm
    local _SAVED_TOTAL_STEPS="$TOTAL_STEPS"
    TOTAL_STEPS=''
    [ "$IS_HY2_REALM" != 'is_hy2_realm' ] && input_hopping_port
    TOTAL_STEPS="$_SAVED_TOTAL_STEPS"
  fi

  # 如选择有 h. vmess + ws 或 i. vless + ws 时，先检测是否有支持的 http 端口可用，如有则要求输入域名和 cdn
  if [[ "${INSTALL_PROTOCOLS[@]}" =~ 'h' ]]; then
    if [ "$IS_ARGO" = 'is_argo' ]; then
      if [ "$ARGO_READY" != 'argo_ready' ]; then
        (( STEP_NUM++ )) || true
        input_argo_auth is_install
      fi
      local ARGO_READY=argo_ready
    else
      local DOMAIN_ERROR_TIME=5
      until [ -n "$VMESS_HOST_DOMAIN" ]; do
        (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VMESS && reading "\n $(text 50) " VMESS_HOST_DOMAIN || error "\n $(text 3) \n"
      done
    fi
  fi

  if [[ "${INSTALL_PROTOCOLS[@]}" =~ 'i' ]]; then
    if [ "$IS_ARGO" = 'is_argo' ]; then
      if [ "$ARGO_READY" != 'argo_ready' ]; then
        (( STEP_NUM++ )) || true
        input_argo_auth is_install
      fi
      local ARGO_READY=argo_ready
    else
      local DOMAIN_ERROR_TIME=5
      until [ -n "$VLESS_HOST_DOMAIN" ]; do
        (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && TYPE=VLESS && reading "\n $(text 50) " VLESS_HOST_DOMAIN || error "\n $(text 3) \n"
      done
    fi
  fi

  # 选择或者输入 cdn
  if [[ -z "$CDN" && -n "${VMESS_HOST_DOMAIN}${VLESS_HOST_DOMAIN}${ARGO_READY}" ]]; then
    (( STEP_NUM++ )) || true
    input_cdn
  fi

  # 确认 UUID
  input_uuid

  # 输入节点名，以系统的 hostname 作为默认
  input_node_name
}

