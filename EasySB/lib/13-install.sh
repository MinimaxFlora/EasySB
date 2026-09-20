# ------------------------------------------------------------------------------
# 十五、安装主流程 / Installation pipeline
# ------------------------------------------------------------------------------
# 安装 sing-box 全家桶
install_sing-box() {
  sing-box_variables
  if [ -n "$PORT_NGINX" ] && ! command -v nginx >/dev/null 2>&1; then
    info "\n $(text 7) nginx \n"
    ${PACKAGE_UPDATE[int]} >/dev/null 2>&1
    ${PACKAGE_INSTALL[int]} nginx >/dev/null 2>&1
    cmd_systemctl disable nginx
  fi
  [ ! -d ${WORK_DIR}/logs ] && mkdir -p ${WORK_DIR}/logs
  [ ! -d ${TEMP_DIR} ] && mkdir -p $TEMP_DIR
  ssl_certificate $TLS_SERVER_DEFAULT
  hint "\n $(text 2) " && wait
  sing-box_json
  echo "${L^^}" > ${WORK_DIR}/language
  cp $TEMP_DIR/sing-box $TEMP_DIR/jq ${WORK_DIR}
  [ -x $TEMP_DIR/qrencode ] && cp $TEMP_DIR/qrencode ${WORK_DIR}

  # 生成 Argo systemd 配置文件，并复制 cloudflared 可执行二进制文件
  cp $TEMP_DIR/cloudflared ${WORK_DIR}
  [ -n "$ARGO_RUNS" ] && argo_systemd

  # 如果是 Json Argo，把配置文件复制到工作目录
  [ -n "$ARGO_JSON" ] && cp $TEMP_DIR/tunnel.* ${WORK_DIR}

  # 生成 Nginx 配置文件（先于守护文件，确保 ExecStartPre / start_pre 与最终状态一致）
  [ -n "$PORT_NGINX" ] && export_nginx_conf_file

  # 生成 sing-box systemd 配置文件
  sing-box_systemd

  # 系统启动 sing-box 服务
  cmd_systemctl enable sing-box

  # 等待服务启动
  sleep 2

  # 处理防火墙相关端口
  sync_firewall_rules

  # 检查服务是否成功启动
  if cmd_systemctl status sing-box &>/dev/null; then
    STATUS[0]=$(text 28)
    info "\n Sing-box $(text 28) $(text 37) \n"
  else
    STATUS[0]=$(text 27)
    error "\n Sing-box $(text 27) $(text 38) \n"
    # 如果启动失败，再尝试重启
    cmd_systemctl restart sing-box
  fi

  # 如果配置了 Argo，也启动 Argo 服务
  if [ -s ${ARGO_DAEMON_FILE} ]; then
    cmd_systemctl enable argo

    sleep 2

    # 检查 Argo 服务是否成功启动
    if cmd_systemctl status argo &>/dev/null; then
      STATUS[1]=$(text 28)
      info "\n Argo $(text 28) $(text 37) \n"
    else
      STATUS[1]=$(text 27)
      error "\n Argo $(text 27) $(text 38) \n"
      # 如果启动失败，再尝试重启
      cmd_systemctl restart argo
    fi
  fi
}

