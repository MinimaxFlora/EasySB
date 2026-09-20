# ------------------------------------------------------------------------------
# 二十、脚本入口 / Entry point
# ------------------------------------------------------------------------------
check_cdn
statistics_of_run_times update easysb.sh 2>/dev/null

###### 为了给旧版本 04_experimental.json 补全 clash_api 配置并剥离 v2ray_api，将于 2026年12月31日移除
if [ -x "$WORK_DIR/jq" ] && [ -s "$WORK_DIR/conf/04_experimental.json" ] && [ -x "$WORK_DIR/sing-box" ] && [[ "$(date +%Y%m%d)" < "20261231" ]]; then
  # 旧版本 04_experimental.json 可能缺 clash_api、或含 v2ray_api（旧版脚本注入的）。
  # clash_api 是官方 release 二进制默认编译功能（with_clash_api），直接补全；
  # v2ray_api 官方 release 二进制默认不编译，残留会导致启动失败，必须剥离。
  if ! grep -q 'clash_api' "$WORK_DIR/conf/04_experimental.json" || grep -q 'v2ray_api' "$WORK_DIR/conf/04_experimental.json"; then
    API_PORT=$(find_free_api_port)
    if grep -q 'clash_api' "$WORK_DIR/conf/04_experimental.json"; then
      # 已有 clash_api（可能由新版脚本生成），仅剥离残留的 v2ray_api
      grep -v '^//' "$WORK_DIR/conf/04_experimental.json" | $WORK_DIR/jq 'del(.experimental.v2ray_api)' > "$TEMP_DIR/exp_clash_api_tmp.json" 2>/dev/null
    else
      # 缺失 clash_api，剥离 v2ray_api 并补全 clash_api
      grep -v '^//' "$WORK_DIR/conf/04_experimental.json" | $WORK_DIR/jq --arg ec "127.0.0.1:${API_PORT}" '
        del(.experimental.v2ray_api) | .experimental += {
          "clash_api": { "external_controller": $ec }
        }
      ' > "$TEMP_DIR/exp_clash_api_tmp.json" 2>/dev/null
    fi
    [ -s "$TEMP_DIR/exp_clash_api_tmp.json" ] && mv "$TEMP_DIR/exp_clash_api_tmp.json" "$WORK_DIR/conf/04_experimental.json" && {
      # 修改了 experimental 配置，用 SIGHUP 热加载使 API 监听生效（PID 不变，SSH 连接不断）。
      # 此处在 check_system_info() 之前（SYSTEM 未设置）且 select_language() 之前（L 未设置），
      # 注意：不能调用 cmd_systemctl reload——其成功分支会调用 info/text（nameref 依赖 L），
      # 与 Alpine 分支直接 kill -HUP 对称。前台同步执行确保信号送达（SIGHUP 不断连 SSH）。
      if [ -d /run/openrc ] || command -v rc-service >/dev/null 2>&1; then
        # Alpine：kill -HUP 主进程（与 cmd_systemctl reload 的 Alpine 分支一致）；PID 不存在时降级 restart。
        SB_PID=$(cat /var/run/sing-box.pid 2>/dev/null)
        if [ -n "$SB_PID" ] && kill -0 "$SB_PID" 2>/dev/null; then
          kill -HUP "$SB_PID" 2>/dev/null
        else
          rc-service sing-box restart >/dev/null 2>&1
        fi
      else
        # systemd 等：复刻 cmd_systemctl reload 的 systemd 分支（SIGHUP 热加载）；PID 不存在时降级 restart。
        SB_MAINPID=$(systemctl show -p MainPID sing-box 2>/dev/null | awk -F= '{print $2}')
        if [ -n "$SB_MAINPID" ] && [ "$SB_MAINPID" -gt 0 ] 2>/dev/null; then
          systemctl kill -s HUP sing-box >/dev/null 2>&1
        else
          systemctl restart sing-box >/dev/null 2>&1
        fi
        unset SB_MAINPID
      fi
    }
  fi
fi

###### 为了把原来的 nekobox 换成 Throne 做的处理，将于 2026年9月30日移除
if [ -s $WORK_DIR/nginx.conf ] && grep -q 'Neko|Throne' $WORK_DIR/nginx.conf; then
  sed -i 's@~\*Neko|Throne.*@~*Throne|Neko              /throne;         # 匹配 Throne / Neko 客户端@g' "$WORK_DIR/nginx.conf"
  [ -s $WORK_DIR/subscribe/neko ] && rm -f $WORK_DIR/subscribe/neko
  cmd_systemctl restart sing-box
  export_list >/dev/null 2>&1
fi

# 传参
[[ "${*^^}" =~ '-E'|'-K' ]] && L=E
[[ "${*^^}" =~ '-C'|'-B'|'-L' ]] && L=C
# 支持在 select_language 前识别 --LANGUAGE，避免 KV 无交互安装仍弹出语言选择。
for ((PARAM_I=1; PARAM_I<=$#; PARAM_I++)); do
  eval "PARAM_V=\${${PARAM_I}}"
  case "${PARAM_V^^}" in
    --LANGUAGE )
      PARAM_N=$((PARAM_I+1))
      eval "PARAM_LANG=\${${PARAM_N}}"
      [[ "${PARAM_LANG^^}" =~ ^C ]] && L=C || L=E
      ;;
    --LANGUAGE=* )
      PARAM_LANG="${PARAM_V#*=}"
      [[ "${PARAM_LANG^^}" =~ ^C ]] && L=C || L=E
      ;;
  esac
done
unset PARAM_I PARAM_V PARAM_N PARAM_LANG

# 获取 -F 参数的值
CONFIG_FILE=$(awk '-F[ =]' 'tolower($1) ~ /^-f$/{print $2}' <<< "$*")
if [[ -n "$CONFIG_FILE" && -s "$CONFIG_FILE" ]]; then
  NONINTERACTIVE_INSTALL=noninteractive_install
  . $CONFIG_FILE
  L=${LANGUAGE^^}
  [ "$ARGO" = 'true' ] && IS_ARGO=is_argo || IS_ARGO=no_argo
  [ "$SUBSCRIBE" = 'true' ] && IS_SUB=is_sub || IS_SUB=no_sub
fi

check_root
select_language
check_system_info
check_brutal

# 可以是 Key Value 或者 Key=Value 的形式。传参时，
# 传参处理1: 把所有的 = 变为空格，但保留 =" ，因为 Json TunnelSecret 是 =" 结尾的，如 {"AccountTag":"9cc9e3e4d8f29d2a02e297f14f20513a","TunnelSecret":"6AYfKBOoNlPiTAuWg64ZwujsNuERpWLm6pPJ2qpN8PM=","TunnelID":"1ac55430-f4dc-47d5-a850-bdce824c4101"}
# 传参处理2: 去掉 sudo cloudflared service install ，以方便用户输入 Token 并能正确读取真正的以 ey 开头的 Value
ALL_PARAMETER=($(sed -E 's/(-c|-e|-f|-C|-E|-F) //; s/=([^"])/ \1/g; s/sudo cloudflared service install //' <<< $*))
# KV 参数安装：只要指定 --CHOOSE_PROTOCOLS，就认为用户要无交互安装。
# 其余参数允许缺省，脚本会按交互模式默认值自动补齐。
[[ "${ALL_PARAMETER[@]^^}" == *"--CHOOSE_PROTOCOLS"* ]] && NONINTERACTIVE_INSTALL=noninteractive_install

# 传参处理，无交互快速安装参数
for z in ${!ALL_PARAMETER[@]}; do
  case "${ALL_PARAMETER[z]^^}" in
    -K|-L )
      ((z++))
      IS_FAST_INSTALL=is_fast_install
      ;;
    -S )
      check_install
      if [ "${STATUS[0]}" = "$(text 26)" ]; then
        error "\n Sing-box $(text 26) \n"
      elif [ "${STATUS[0]}" = "$(text 28)" ]; then
        cmd_systemctl disable sing-box
        cmd_systemctl status sing-box &>/dev/null && error "\n Sing-box $(text 27) $(text 38) \n" || info "\n Sing-box $(text 27) $(text 37) \n"
      elif [ "${STATUS[0]}" = "$(text 27)" ]; then
        cmd_systemctl enable sing-box
        sleep 2
        cmd_systemctl status sing-box &>/dev/null && info "\n Sing-box $(text 28) $(text 37) \n" || error "\n Sing-box $(text 28) $(text 38) \n"
      fi
      exit 0
      ;;
    -A )
      check_install
      if [ "${STATUS[1]}" = "$(text 26)" ]; then
        error "\n Argo $(text 26) "
      elif [ "${STATUS[1]}" = "$(text 28)" ]; then
        cmd_systemctl disable argo
        cmd_systemctl status argo &>/dev/null && error "\n Argo $(text 27) $(text 38) \n" || info "\n Argo $(text 27) $(text 37) \n"
      elif [ "${STATUS[1]}" = "$(text 27)" ]; then
        cmd_systemctl enable argo
        sleep 2
        cmd_systemctl status argo &>/dev/null && info "\n Argo $(text 28) $(text 37) \n" || error "\n Argo $(text 28) $(text 38) \n"
        grep -qs '\--url' ${ARGO_DAEMON_FILE} && fetch_quicktunnel_domain && export_list
      fi
      exit 0
      ;;
    -T )
      change_argo; exit 0
      ;;
    -D )
      change_config; exit 0
      ;;
    -U )
      check_install; uninstall; exit 0
      ;;
    -N )
      [ ! -s ${WORK_DIR}/list ] && error " Sing-box $(text 26) "; export_list; exit 0
      ;;
    -V )
      check_system_info; check_arch; version; exit 0
      ;;
    -B )
      bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit
      ;;
    -R )
      change_protocols; exit 0
      ;;
    --LANGUAGE )
      ((z++)); [[ "${ALL_PARAMETER[z]^^}" =~ ^C ]] && LANGUAGE=C || LANGUAGE=E
      ;;
    --CHOOSE_PROTOCOLS )
      ((z++)); CHOOSE_PROTOCOLS=${ALL_PARAMETER[z]}
      ;;
    --START_PORT )
      ((z++)); START_PORT=${ALL_PARAMETER[z]}
      ;;
    --PORT_NGINX )
      ((z++)); PORT_NGINX=${ALL_PARAMETER[z]}
      ;;
    --SERVER_IP )
      ((z++)); SERVER_IP=${ALL_PARAMETER[z]}
      ;;
    --VMESS_HOST_DOMAIN )
      ((z++)); VMESS_HOST_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --VLESS_HOST_DOMAIN )
      ((z++)); VLESS_HOST_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --CDN )
      ((z++)); CDN=${ALL_PARAMETER[z]}
      ;;
    --UUID_CONFIRM )
      ((z++)); UUID_CONFIRM=${ALL_PARAMETER[z]}
      ;;
    --NODE_NAME_CONFIRM )
      ((z++))
      for ((z=$z; z<${#ALL_PARAMETER[@]}; z++)); do
        [[ ! "${ALL_PARAMETER[z]}" =~ ^- ]] && NODE_NAME_ARRAY+=(${ALL_PARAMETER[z]}) || break
      done
      NODE_NAME_CONFIRM=${NODE_NAME_ARRAY[@]}
      ;;
    --SUBSCRIBE )
      ((z++)); [ "${ALL_PARAMETER[z]}" = 'true' ] && IS_SUB=is_sub
      ;;
    --ARGO )
      ((z++)); [ "${ALL_PARAMETER[z]}" = 'true' ] && IS_ARGO=is_argo
      ;;
    --ARGO_DOMAIN )
      ((z++)); ARGO_DOMAIN=${ALL_PARAMETER[z]}
      ;;
    --ARGO_AUTH )
      ((z++)); ARGO_AUTH=${ALL_PARAMETER[z]}
      ;;
    --HY2_PORT_HOPPING_RANGE )
      ((z++)); [[ "${ALL_PARAMETER[z]//:/-}" =~ ^[1-6][0-9]{4}-[1-6][0-9]{4}$ ]] && HY2_PORT_HOPPING_RANGE=${ALL_PARAMETER[z]//-/:} && PORT_HOPPING_START=${ALL_PARAMETER[z]%:*} && PORT_HOPPING_END=${ALL_PARAMETER[z]#*:}
      [[ "$PORT_HOPPING_START" < "$PORT_HOPPING_END" && "$PORT_HOPPING_START" -ge "$MIN_HOPPING_PORT" && "$PORT_HOPPING_END" -le "$MAX_HOPPING_PORT" ]] && IS_HOPPING=is_hopping
      ;;
    --HY2_REALM|--REALM )
      ((z++)); [[ "${ALL_PARAMETER[z],,}" =~ ^(true|1|y|yes)$ ]] && IS_HY2_REALM=is_hy2_realm
      ;;
    --HY2_WARP|--REALM_WARP|--WARP_REALM )
      ((z++)); [[ "${ALL_PARAMETER[z],,}" =~ ^(true|1|y|yes)$ ]] && IS_HY2_WARP=is_hy2_warp && IS_HY2_REALM=is_hy2_realm
      ;;
    --BIND_INTERFACE )
      ((z++)); BIND_INTERFACE=${ALL_PARAMETER[z]}
      [[ "${BIND_INTERFACE,,}" = "default" ]] && unset BIND_INTERFACE
      ;;
    --REALITY_PRIVATE )
      ((z++)); REALITY_PRIVATE=${ALL_PARAMETER[z]}
      ;;
  esac
done

check_arch
check_dependencies
check_system_ip
check_install
if [ "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]; then
  # 预设默认值，允许只传 --CHOOSE_PROTOCOLS 进行最小无交互安装。
  CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}
  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  CDN=${CDN:-"${CDN_DOMAIN[0]}"}
  IS_SUB=${IS_SUB:-'no_sub'}
  IS_ARGO=${IS_ARGO:-'no_argo'}
  IS_HOPPING=${IS_HOPPING:-'no_hopping'}

  install_sing-box
  export_list install
  create_shortcut
elif [ "$IS_FAST_INSTALL" = 'is_fast_install' ]; then
  # 预设默认值
  CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}
  START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}
  CDN=${CDN:-"${CDN_DOMAIN[0]}"}
  IS_SUB='is_sub'
  IS_ARGO='is_argo'
  [[ "$HY2_PORT_HOPPING_RANGE" =~ ^[0-9]+:[0-9]+$ ]] && IS_HOPPING='is_hopping' || IS_HOPPING='no_hopping'

  install_sing-box
  export_list install
  create_shortcut
else
  menu_setting
  menu
fi
