# ------------------------------------------------------------------------------
# 十九、交互菜单与脚本入口 / Interactive menu and script entry
# ------------------------------------------------------------------------------
# 判断当前 Sing-box 的运行状态，并对应的给菜单和动作赋值
menu_setting() {
  if [[ "${STATUS[0]}" =~ $(status_on_off_regex) ]]; then
    OPTION[1]="1 .  $(text 29)"
    [ "${STATUS[0]}" = "$(text 28)" ] && OPTION[2]="2 .  $(text 27) Sing-box (sb -s)" || OPTION[2]="2 .  $(text 28) Sing-box (sb -s)"
    [ "${STATUS[1]}" = "$(text 28)" ] && OPTION[3]="3 .  $(text 27) Argo (sb -a)" || OPTION[3]="3 .  $(text 28) Argo (sb -a)"
    OPTION[4]="4 .  $(text 92)"
    OPTION[5]="5 .  $(text 121)"
    OPTION[6]="6 .  $(text 31)"
    OPTION[7]="7 .  $(text 32)"
    OPTION[8]="8 .  $(text 62)"
    OPTION[9]="9 .  $(text 33)"
    OPTION[10]="10.  $(text 59)"
    OPTION[11]="11.  $(text 69)"
    OPTION[12]="12.  $(text 76)"

    ACTION[1]() { export_list; exit 0; }

    [ "${STATUS[0]}" = "$(text 28)" ] &&
    ACTION[2]() {
      cmd_systemctl disable sing-box
      cmd_systemctl status sing-box &>/dev/null && error "\n Sing-box $(text 27) $(text 38) \n" || info "\n Sing-box $(text 27) $(text 37) \n"
    } ||
    ACTION[2]() {
      cmd_systemctl enable sing-box
      sleep 2
      cmd_systemctl status sing-box &>/dev/null && info "\n Sing-box $(text 28) $(text 37) \n" || error "\n Sing-box $(text 28) $(text 38) \n"
    }

    [ "${STATUS[1]}" = "$(text 28)" ] &&
    ACTION[3]() {
      cmd_systemctl disable argo
      cmd_systemctl status argo &>/dev/null && error "\n Argo $(text 27) $(text 38) \n" || info "\n Argo $(text 27) $(text 37) \n"
    } ||
    ACTION[3]() {
      cmd_systemctl enable argo
      sleep 2
      cmd_systemctl status argo &>/dev/null &&  info "\n Argo $(text 28) $(text 37) \n" || error "\n Argo $(text 28) $(text 38) \n"
      grep -qs '\--url' ${ARGO_DAEMON_FILE} && fetch_quicktunnel_domain && export_list
    }

    ACTION[4]() { change_argo; exit; }
    ACTION[5]() { change_config; exit; }
    ACTION[6]() { version; exit; }
    ACTION[7]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit; }
    ACTION[8]() { change_protocols; exit; }
    ACTION[9]() { uninstall; exit; }
    ACTION[10]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) -$L; exit; }
    ACTION[11]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/sba/main/sba.sh) -$L; exit; }
    ACTION[12]() { bash <(wget --no-check-certificate -qO- https://tcp.hy2.sh/); exit; }
  else
    OPTION[1]="1.  $(text 115)"
    OPTION[2]="2.  $(text 34) + Argo + $(text 80) $(text 89)"
    OPTION[3]="3.  $(text 34) + Argo $(text 89)"
    OPTION[4]="4.  $(text 34) + $(text 80) $(text 89)"
    OPTION[5]="5.  $(text 34)"
    OPTION[6]="6.  $(text 32)"
    OPTION[7]="7.  $(text 59)"
    OPTION[8]="8.  $(text 69)"
    OPTION[9]="9.  $(text 76)"

    ACTION[1]() { IS_FAST_INSTALL='is_fast_install'; CHOOSE_PROTOCOLS=${CHOOSE_PROTOCOLS:-'a'}; START_PORT=${START_PORT:-"$START_PORT_DEFAULT"}; CDN=${CDN:-"${CDN_DOMAIN[0]}"}; IS_SUB='is_sub'; IS_ARGO='is_argo'; install_sing-box; export_list install; create_shortcut; exit; }
    ACTION[2]() { IS_SUB=is_sub; IS_ARGO=is_argo; install_sing-box; export_list install; create_shortcut; exit; }
    ACTION[3]() { IS_SUB=no_sub; IS_ARGO=is_argo; install_sing-box; export_list install; create_shortcut; exit; }
    ACTION[4]() { IS_SUB=is_sub; IS_ARGO=no_argo; install_sing-box; export_list install; create_shortcut; exit; }
    ACTION[5]() { install_sing-box; export_list install; create_shortcut; exit; }
    ACTION[6]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh); exit; }
    ACTION[7]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/argox/main/argox.sh) -$L; exit; }
    ACTION[8]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://raw.githubusercontent.com/fscarmen/sba/main/sba.sh) -$L; exit; }
    ACTION[9]() { bash <(wget --no-check-certificate -qO- ${GH_PROXY}https://tcp.hy2.sh/); exit; }
  fi

  [ "${#OPTION[@]}" -ge '10' ] && OPTION[0]="0 .  $(text 35)" || OPTION[0]="0.  $(text 35)"
  ACTION[0]() { exit; }
}

menu() {
  clear
  echo -e "======================================================================================================================\n"
  info " $(text 17): $VERSION\n $(text 18): $(text 1)\n $(text 19):\n\t $(text 20): $SYS\n\t $(text 21): $(uname -r)\n\t $(text 22): $SING_BOX_ARCH\n\t $(text 23): $VIRT "
  info "\t IPv4: $WAN4 $WARPSTATUS4 $COUNTRY4  $ASNORG4 "
  info "\t IPv6: $WAN6 $WARPSTATUS6 $COUNTRY6  $ASNORG6 "
  # 对齐显示：中文双宽字符按字符数补空格，英文按最长状态词 "Not install"(11字符) 定宽
  _sv() {
    local s="$1"
    if [ "$L" = 'C' ]; then
      [ "${#s}" -le 2 ] && printf '%s  ' "$s" || printf '%s' "$s"
    else
      printf '%-11s' "$s"
    fi
  }
  local SBV; printf -v SBV '%-26s' "$SING_BOX_VERSION"
  local AV;  printf -v AV  '%-26s' "$ARGO_VERSION"
  local NV;  printf -v NV  '%-26s' "$NGINX_VERSION"
  # === 计算 Sing-box 行流量（仅数据可用时显示；流量为 0 时显示 0 B） ===
  # downloadTotal / uploadTotal 为 clash_api 提供的进程生命周期累计值
  local SB_TRAFFIC=""
  if ensure_stats_data 2>/dev/null; then
    local IN_SUM OUT_SUM
    IN_SUM=$(echo "$STATS_JSON" | $WORK_DIR/jq '.downloadTotal // 0' 2>/dev/null)
    OUT_SUM=$(echo "$STATS_JSON" | $WORK_DIR/jq '.uploadTotal // 0' 2>/dev/null)
    SB_TRAFFIC="  ⬇$(format_traffic $IN_SUM) ⬆$(format_traffic $OUT_SUM)"
  fi
  # === 结束 ===
  info "\t Sing-box: $(_sv "${STATUS[0]}")  ${SBV}${SING_BOX_MEMORY_USAGE}${SB_TRAFFIC}"
  info "\t Argo:     $(_sv "${STATUS[1]}")  ${AV}${ARGO_MEMORY_USAGE}"
  info "\t Nginx:    $(_sv "${STATUS[2]}")  ${NV}${NGINX_MEMORY_USAGE}"
  echo -e "\n======================================================================================================================\n"
  for ((b=1;b<=${#OPTION[*]};b++)); do [ "$b" = "${#OPTION[*]}" ] && hint " ${OPTION[0]} " || hint " ${OPTION[b]} "; done
  reading "\n $(text 24) " CHOOSE

  # 输入必须是数字且少于等于最大可选项
  if grep -qE "^[0-9]{1,2}$" <<< "$CHOOSE" && [ "$CHOOSE" -lt "${#OPTION[*]}" ]; then
    ACTION[$CHOOSE]
  else
    warning " $(text 36) [0-$((${#OPTION[*]}-1))] " && sleep 1 && menu
  fi
}

