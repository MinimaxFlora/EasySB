# ------------------------------------------------------------------------------
# 十、WARP 与 Hysteria2 Realm / WARP account and Hysteria2 Realm
# ------------------------------------------------------------------------------
# ===================== 更换 WARP 账户 START =====================

# 获取 WARP 账户并解析到全局变量 WARP_ADDRESS6 / WARP_PRIVATE_KEY / WARP_RESERVED[1..3]
# $1 为空则在线注册；非空则直接解析该 JSON（如安装期后台预注册的缓存）
# 返回 0 成功 / 1 失败（接口无 id 或解析字段缺失），失败时调用方自行兜底
warp_account_register() {
  local WARP_ACCOUNT="$1"
  [ -n "$WARP_ACCOUNT" ] || WARP_ACCOUNT=$(timeout 15 bash <(wget -qO- --timeout=5 --tries=1 "https://gitlab.com/fscarmen/warp/-/raw/main/api.sh") --register)

  grep -q '"id"' <<< "$WARP_ACCOUNT" || return 1

  WARP_ADDRESS6=$(awk -F'"' '/"v6":/ && $4 !~ /^\[/ {print $4}' <<< "$WARP_ACCOUNT")
  WARP_PRIVATE_KEY=$(awk -F'"' '/"private_key"/{print $4}' <<< "$WARP_ACCOUNT")
  WARP_RESERVED[1]=$(awk '/"reserved":/ {getline; gsub(/[^0-9]/, ""); print}' <<< "$WARP_ACCOUNT")
  WARP_RESERVED[2]=$(awk '/"reserved":/ {getline; getline; gsub(/[^0-9]/, ""); print}' <<< "$WARP_ACCOUNT")
  WARP_RESERVED[3]=$(awk '/"reserved":/ {getline; getline; getline; gsub(/[^0-9]/, ""); print}' <<< "$WARP_ACCOUNT")

  if [ -z "$WARP_ADDRESS6" ] || [ -z "$WARP_PRIVATE_KEY" ] || [ -z "${WARP_RESERVED[1]}" ] || [ -z "${WARP_RESERVED[2]}" ] || [ -z "${WARP_RESERVED[3]}" ]; then
    unset WARP_ADDRESS6 WARP_PRIVATE_KEY WARP_RESERVED
    return 1
  fi
  return 0
}

# 更换 WARP 账户：二级菜单（重新注册 / 手动输入）
change_warp_account() {
  local WARP_ACCOUNT_CHOICE
  while true; do
    hint "\n $(text 175) \n"
    reading " $(text 24) " WARP_ACCOUNT_CHOICE

    case "$WARP_ACCOUNT_CHOICE" in
      1 ) change_warp_account_register ;;
      2 ) change_warp_account_manual ;;
      0 ) return ;;
      * ) info " $(text 135) " ;;
    esac
  done
}

# 方式1：重新注册免费账户
change_warp_account_register() {
  if ! warp_account_register; then
    warning "\n $(text 176) \n"
    return
  fi

  change_warp_account_apply "$WARP_ADDRESS6" "$WARP_PRIVATE_KEY" "${WARP_RESERVED[1]}" "${WARP_RESERVED[2]}" "${WARP_RESERVED[3]}"
}

# 方式2：手动输入账户信息（IPv6 / Private Key / Reserved）
change_warp_account_manual() {
  local ADDRESS6 PRIVATE_KEY RESERVED_INPUT R1 R2 R3 RESERVED_ERROR_TIME=5

  # 第 1 步：IPv6 地址（校验含冒号）
  while true; do
    reading "\n $(text 177) " ADDRESS6
    [[ "$ADDRESS6" =~ : ]] && break
    warning " $(text 133) "
  done

  # 第 2 步：Private Key（43 位 base64 字符 + 结尾 =）
  while true; do
    reading " $(text 178) " PRIVATE_KEY
    [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9+/_-]{43}=$ ]] && break
    warning " $(text 184) "
  done

  # 第 3 步：Reserved（先读取一次，再进入校验循环；捕获组提取 3 组连续数字，错误计数复用 UUID_ERROR_TIME 风格）
  reading " $(text 179) " RESERVED_INPUT
  until [[ "$RESERVED_INPUT" =~ ([0-9]+)[^0-9]*([0-9]+)[^0-9]*([0-9]+) ]] || [ "$RESERVED_ERROR_TIME" = 0 ]; do
    (( RESERVED_ERROR_TIME-- )) || true
    [ "$RESERVED_ERROR_TIME" = 0 ] && { warning "\n $(text 180) \n"; return; }
    warning " $(text 180) "
    reading " $(text 179) " RESERVED_INPUT
  done
  R1="${BASH_REMATCH[1]}"; R2="${BASH_REMATCH[2]}"; R3="${BASH_REMATCH[3]}"

  change_warp_account_apply "$ADDRESS6" "$PRIVATE_KEY" "$R1" "$R2" "$R3"
}

# 替换 02_endpoints.json + sing-box check + SIGHUP 热更 + 结果提示
change_warp_account_apply() {
  local ADDRESS6="$1" PRIVATE_KEY="$2" R1="$3" R2="$4" R3="$5"
  local WARP_ENDPOINT_FILE="${WORK_DIR}/conf/02_endpoints.json"
  local SB_PID_BEFORE SB_PID_AFTER

  [ -s "$WARP_ENDPOINT_FILE" ] || return 1

  cp "$WARP_ENDPOINT_FILE" "$WARP_ENDPOINT_FILE.bak"

  sed -i "s|\"private_key\":[ ]*\".*\"|\"private_key\":\"${PRIVATE_KEY}\"|" "$WARP_ENDPOINT_FILE"
  sed -i -E "s|\"([0-9a-fA-F:]+)/128\"|\"${ADDRESS6}/128\"|" "$WARP_ENDPOINT_FILE"
  # reserved 为多行数组，sed 单行正则无法覆盖，用 jq 原子更新（失败不落盘）
  jq_exec --argjson res "[${R1},${R2},${R3}]" \
    '(.endpoints[] | select(.tag == "warp-ep") | .peers[].reserved) = $res' \
    "$WARP_ENDPOINT_FILE" > "${WARP_ENDPOINT_FILE}.tmp" 2>/dev/null && mv "${WARP_ENDPOINT_FILE}.tmp" "$WARP_ENDPOINT_FILE"

  hint "\n $(text 181) \n"

  if ${WORK_DIR}/sing-box check -C ${WORK_DIR}/conf >/dev/null 2>&1; then
    # 热更（SIGHUP，PID 不变）；记录热更前后 PID 判断服务是否存活
    if [ "$SYSTEM" = 'Alpine' ]; then
      SB_PID_BEFORE=$(cat /var/run/sing-box.pid 2>/dev/null)
    else
      SB_PID_BEFORE=$(systemctl show -p MainPID sing-box 2>/dev/null | awk -F= '{print $2}')
    fi
    cmd_systemctl reload sing-box >/dev/null 2>&1
    sleep 1
    if [ "$SYSTEM" = 'Alpine' ]; then
      SB_PID_AFTER=$(cat /var/run/sing-box.pid 2>/dev/null)
    else
      SB_PID_AFTER=$(systemctl show -p MainPID sing-box 2>/dev/null | awk -F= '{print $2}')
    fi
    if [ -n "$SB_PID_AFTER" ] && [ "$SB_PID_AFTER" != '0' ]; then
      rm -f "$WARP_ENDPOINT_FILE.bak"
      info "\n $(text 182) $(text 37) \n"
      info " $(text 185) "
      exit 0
    else
      mv -f "$WARP_ENDPOINT_FILE.bak" "$WARP_ENDPOINT_FILE"
      warning "\n $(text 182) $(text 38) \n"
    fi
  else
    mv -f "$WARP_ENDPOINT_FILE.bak" "$WARP_ENDPOINT_FILE"
    warning "\n $(text 182) $(text 38) \n"
  fi
}

# ===================== 更换 WARP 账户 END =====================


# 输入 Reality 密钥
input_reality_key() {
  [[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' && "$IS_FAST_INSTALL" != 'is_fast_install' ]] && [ -z "$REALITY_PRIVATE" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 70) " REALITY_PRIVATE
  [ -z "$REALITY_PRIVATE" ] && unset REALITY_PRIVATE && return

  local PRIVATEKEY_ERROR_TIME=5
  until [[ "$REALITY_PRIVATE" =~ ^[A-Za-z0-9_-]{43}$ || -z "$REALITY_PRIVATE" ]]; do
    (( PRIVATEKEY_ERROR_TIME-- )) || true
    [ "$PRIVATEKEY_ERROR_TIME" = 0 ] && unset REALITY_PRIVATE && hint "\n $(text 113) \n" && break
    warning "\n $(text 114) "
    reading "\n $(text 70) " REALITY_PRIVATE
    # 即使 REALITY_PRIVATE 为空值，但 REALITY_PRIVATE 数组数量 ${REALITY_PRIVATE[@]} 为 1，影响后续的处理，所以要置空
    [ -z "$REALITY_PRIVATE" ] && unset REALITY_PRIVATE && break
  done
}

# 输入 Argo 域名和认证信息
input_argo_auth() {
  local IS_CHANGE_ARGO=$1
  [ -n "$IS_CHANGE_ARGO" ] && local EMPTY_ERROR_TIME=5
  local DOMAIN_ERROR_TIME=6

  # 处理可能输入的错误，去掉开头和结尾的空格，去掉最后的 :
  if [ "$IS_CHANGE_ARGO" = 'is_change_argo' ]; then
    until [ -n "$ARGO_DOMAIN" ]; do
      (( EMPTY_ERROR_TIME-- )) || true
      [ "$EMPTY_ERROR_TIME" = 0 ] && error "\n $(text 3) \n"
      reading "\n $(text 88) " ARGO_DOMAIN
      [ -n "$IS_CHANGE_ARGO" ] && ARGO_DOMAIN=$(sed 's/[ ]*//g; s/:[ ]*//' <<< "$ARGO_DOMAIN")
    done
  elif [[ "$NONINTERACTIVE_INSTALL" != 'noninteractive_install' && "$IS_FAST_INSTALL" != 'is_fast_install' ]]; then
    [ -z "$ARGO_DOMAIN" ] && reading "\n ${TOTAL_STEPS:+(${STEP_NUM}/${TOTAL_STEPS}) }$(text 87) " ARGO_DOMAIN
    ARGO_DOMAIN=$(sed 's/[ ]*//g; s/:[ ]*//' <<< "$ARGO_DOMAIN")
  fi

  if [[ ( -z "$ARGO_DOMAIN" || "$ARGO_DOMAIN" =~ trycloudflare\.com$ ) && ( "$IS_CHANGE_ARGO" = 'is_add_protocols' || "$IS_CHANGE_ARGO" = 'is_install' || "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ) ]]; then
    ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://localhost:$PORT_NGINX"
  elif [ -n "${ARGO_DOMAIN}" ]; then
    if [ -z "${ARGO_AUTH}" ]; then
      until [[ "$ARGO_AUTH" =~ TunnelSecret || "$ARGO_AUTH" =~ [A-Z0-9a-z=]{120,250}$ || "${#ARGO_AUTH}" =~ ^[3-6][0-9]$ ]]; do
        [ "$DOMAIN_ERROR_TIME" != 6 ] && warning "\n $(text 86) \n"
      (( DOMAIN_ERROR_TIME-- )) || true
        [ "$DOMAIN_ERROR_TIME" != 0 ] && hint "\n $(text 85) \n " && reading "\n $(text 118) " ARGO_AUTH || error "\n $(text 3) \n"
      done
    fi

    # 根据 ARGO_AUTH 的内容，自行判断是 Json， Token 还是 API 申请
    if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
      ARGO_TYPE=is_json_argo
      ARGO_JSON=${ARGO_AUTH//[ ]/}
      [ "$IS_CHANGE_ARGO" = 'is_install' ] && export_argo_json_file $TEMP_DIR || export_argo_json_file ${WORK_DIR}
      ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --config ${WORK_DIR}/tunnel.yml run"
    elif [[ "${ARGO_AUTH}" =~ [A-Z0-9a-z=]{120,250}$ ]]; then
      ARGO_TYPE=is_token_argo
      ARGO_TOKEN=$(awk '{print $NF}' <<< "$ARGO_AUTH")
      ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN}"
    elif [[ "${#ARGO_AUTH}" =~ ^[3-6][0-9]$ ]]; then
      hint "\n $(text 119) \n "
      create_argo_tunnel "${ARGO_AUTH}" "${ARGO_DOMAIN}" "${PORT_NGINX}"
      if [[ "$ARGO_JSON" =~ TunnelSecret ]]; then
        ARGO_TYPE=is_json_argo
        [ "$IS_CHANGE_ARGO" = 'is_install' ] && export_argo_json_file $TEMP_DIR || export_argo_json_file ${WORK_DIR}
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --config ${WORK_DIR}/tunnel.yml run"
      elif [[ "${#ARGO_TOKEN}" =~ ^[0-9]+$ && "${#ARGO_TOKEN}" -ge 120 && "${#ARGO_TOKEN}" -le 250 ]]; then
        ARGO_TYPE=is_token_argo
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN}"
      else
        # 创建隧道失败，回退到使用临时隧道
        hint "\n $(text 117) \n "
        unset ARGO_DOMAIN
        ARGO_RUNS="${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://localhost:$PORT_NGINX"
      fi
    fi
  fi
}

# 更换 Argo 隧道类型
change_argo() {
  check_install
  if [ "${STATUS[0]}" =  "$(text 26)" ]; then
    error "\n $(text 39) "
  elif [ "${STATUS[1]}" = "$(text 26)" ]; then
    error "\n $(text 61) "
  fi

  # 根据系统类型检查 Argo 服务配置
  local ARGO_CONFIG=$(grep -E '^(command_args=|ExecStart=)' ${ARGO_DAEMON_FILE})

  case "$ARGO_CONFIG" in
    *--config* )
      ARGO_TYPE='Json'
      ;;
    *--token* )
      ARGO_TYPE='Token'
      ;;
    * )
      ARGO_TYPE='Try'
      cmd_systemctl enable argo && sleep 2 && cmd_systemctl status argo &>/dev/null && fetch_quicktunnel_domain
  esac

  fetch_nodes_value
  hint "\n $(text 90) \n"
  unset ARGO_DOMAIN
  hint " $(text 91) \n" && reading " $(text 24) " CHANGE_TO

  case "$CHANGE_TO" in
    1 )
      cmd_systemctl disable argo
      [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.{json,yml}

      # 根据系统类型修改配置文件
      [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto --protocol http2 --no-autoupdate --url http://localhost:$PORT_NGINX\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://localhost:$PORT_NGINX@g" ${ARGO_DAEMON_FILE}
      ;;
    2 )
      [ -s ${WORK_DIR}/tunnel.json ] && rm -f ${WORK_DIR}/tunnel.{json,yml}
      input_argo_auth is_change_argo
      cmd_systemctl disable argo

      if [ -n "$ARGO_TOKEN" ]; then
        [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN}\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN}@g" ${ARGO_DAEMON_FILE}
      elif [ -n "$ARGO_JSON" ]; then
        [ "$SYSTEM" = 'Alpine' ] && sed -i "s@^command_args=.*@command_args=\"--edge-ip-version auto --protocol http2 --config ${WORK_DIR}/tunnel.yml run\"@g" ${ARGO_DAEMON_FILE} || sed -i "s@ExecStart=.*@ExecStart=${WORK_DIR}/cloudflared tunnel --edge-ip-version auto --protocol http2 --config ${WORK_DIR}/tunnel.yml run@g" ${ARGO_DAEMON_FILE}
      fi

      # 更新相关配置文件中的域名
      [ -s ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json ] && sed -i "s/VMESS_HOST_DOMAIN.*/VMESS_HOST_DOMAIN\": \"$ARGO_DOMAIN\"/" ${WORK_DIR}/conf/17_${NODE_TAG[6]}_inbounds.json
      [ -s ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json ] && sed -i "s/\"server_name\":.*/\"server_name\": \"$ARGO_DOMAIN\",/" ${WORK_DIR}/conf/18_${NODE_TAG[7]}_inbounds.json
      ;;
    * )
      exit 0
  esac

  # 启用 Argo 服务
  cmd_systemctl enable argo

  # 更新节点信息和配置
  fetch_nodes_value
  export_nginx_conf_file
  nginx_sync
  export_list
}

