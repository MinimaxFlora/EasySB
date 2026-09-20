# ------------------------------------------------------------------------------
# 十八、版本维护与卸载 / Version maintenance and uninstall
# ------------------------------------------------------------------------------
# 卸载 sing-box 全家桶
uninstall() {
  if [ -d ${WORK_DIR} ]; then
    [ -s ${ARGO_DAEMON_FILE} ] && cmd_systemctl disable argo &>/dev/null
    [ -s ${SINGBOX_DAEMON_FILE} ] && cmd_systemctl disable sing-box &>/dev/null
    nginx_stop
    sleep 1
    [[ -s ${WORK_DIR}/nginx.conf && "$(ps -ef | grep -c '[n]ginx')" = 0 ]] && reading "\n $(text 83) " REMOVE_NGINX
    [ "${REMOVE_NGINX,,}" = 'y' ] && ${PACKAGE_UNINSTALL[int]} nginx >/dev/null 2>&1
    purge_service_firewall_rules
    del_port_hopping_nat >/dev/null 2>&1 || true
    rm -rf ${WORK_DIR} ${TEMP_DIR} ${ARGO_DAEMON_FILE} ${SINGBOX_DAEMON_FILE} /usr/bin/sb
    info "\n $(text 16) \n"
  else
    error "\n $(text 15) \n"
  fi
}


# Sing-box 的最新版本
version() {
  # 获取需要下载的 sing-box 版本
  local ONLINE=$(get_sing_box_version)

  grep -q '.' <<< "$ONLINE" || error " $(text 100) \n"
  local LOCAL=$(${WORK_DIR}/sing-box version | awk '/version/{print $NF}')
  info "\n $(text 40) "
  [[ -n "$ONLINE" && "$ONLINE" != "$LOCAL" ]] && reading "\n $(text 9) " UPDATE || info " $(text 41) "

  if [ "${UPDATE,,}" = 'y' ]; then
    check_system_info
    # 先下载到临时文件并校验完整性，避免中断导致损坏的压缩包直接喂给 tar 报错；失败自动重试（第2次起去掉代理直连）
    # 直接使用文件路径，仅保留 URL 切换变量、循环计数变量
    local SB_UP_URL UP_TRY
    for UP_TRY in 1 2 3; do
      rm -f "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
      SB_UP_URL="${GH_PROXY}${PROJECT_SING_BOX_RELEASE}/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz"
      [ "$UP_TRY" -ge 2 ] && SB_UP_URL="${PROJECT_SING_BOX_RELEASE}/download/v$ONLINE/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz"
      wget --no-check-certificate --continue --tries=2 --timeout=10 -qO "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" "$SB_UP_URL" 2>/dev/null || { sleep 3; continue; }
      [ -s "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" ] || { sleep 3; continue; }
      tar xz -C "$TEMP_DIR" -f "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz" "sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box" 2>/dev/null || { sleep 3; continue; }
      [ -s "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box" ] || { sleep 3; continue; }
      rm -f "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz"
      break
    done

    [ -s "$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box" ] || error "\n $(text 42) \n"
    if ! $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box check -C ${WORK_DIR}/conf >/dev/null; then
      warning "\n $(text 54) " && reading "\n $(text 111) " UPDATE_CONFIG
      [ "${UPDATE_CONFIG,,}" = 'n' ] && exit 1

      # 设置基础配置参数 dns.servers.prefer_go 和 dns.strategy
      local STRATEGY=$(awk -F '"' '/ipv4_only|ipv6_only|prefer_ipv4|prefer_ipv6/ && FILENAME !~ /03_route\.json/{print $(NF-1); exit}' ${WORK_DIR}/conf/0*.json)
      STRATEGY=${STRATEGY:-prefer_ipv4}
      command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved && local IS_PREFER_GO=false || local IS_PREFER_GO=true

      # 备份旧基础配置
      for i in $(ls ${WORK_DIR}/conf/0*); do
        cp $i ${i}.bak
      done
      generate_sing_box_base_conf

      if ! $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box check -C ${WORK_DIR}/conf >/dev/null; then
        for i in $(ls ${WORK_DIR}/conf/0*.bak); do
          mv $i ${i%%.bak}
        done
        error "\n $(text 101) \n"
      fi
    fi

    cmd_systemctl disable sing-box

    # 备份旧版本
    cp ${WORK_DIR}/sing-box ${WORK_DIR}/sing-box.bak
    hint "\n $(text 102) \n"

    # 安装新版本
    chmod +x $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box && mv $TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH/sing-box ${WORK_DIR}/sing-box
    cmd_systemctl enable sing-box
    sleep 2

    # 检查新版本是否成功运行
    if cmd_systemctl status sing-box &>/dev/null; then
      # 新版本运行成功，删除备份
      rm -f ${WORK_DIR}/sing-box.bak ${WORK_DIR}/conf/*.bak
      info "\n $(text 103) \n"
    else
      # 新版本运行失败，恢复旧版本
      warning "\n $(text 104) \n"
      mv ${WORK_DIR}/sing-box.bak ${WORK_DIR}/sing-box
      rm -f ${WORK_DIR}/conf/*.bak
      cmd_systemctl enable sing-box
      sleep 2

      cmd_systemctl status sing-box &>/dev/null && info "\n $(text 105) \n" || error "\n $(text 106) \n"
    fi
  fi
}

