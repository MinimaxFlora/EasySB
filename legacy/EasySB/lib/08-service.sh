# ------------------------------------------------------------------------------
# 八、服务与 Web 托管 / Services and web hosting
# ------------------------------------------------------------------------------
# systemd / OpenRC 双支持；nginx 仅作为订阅文件的轻量静态服务器。
# ------------------------------------------------------------------------------

SERVICE_UNIT_FILE=''

service_unit_path() {
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    SERVICE_UNIT_FILE='/etc/systemd/system/sing-box.service'
  else
    SERVICE_UNIT_FILE='/etc/init.d/sing-box'
  fi
}

write_service_unit() {
  service_unit_path
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    cat > "$SERVICE_UNIT_FILE" <<EOF
[Unit]
Description=sing-box service (EasySB)
Documentation=${PROJECT_HOME}
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${CORE_BIN} run -c ${CONFIG_JSON}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    cat > "$SERVICE_UNIT_FILE" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service (EasySB)"
command="${CORE_BIN}"
command_args="run -c ${CONFIG_JSON}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
EOF
    chmod +x "$SERVICE_UNIT_FILE"
  fi
}

remove_service_unit() {
  service_unit_path
  rm -f "$SERVICE_UNIT_FILE"
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

_svc() {
  local action="$1" svc="$2"
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl "$action" "$svc" >/dev/null 2>&1
  else
    rc-service "$svc" "$action" >/dev/null 2>&1
  fi
}

_svc_enable() {
  local svc="$1"
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl enable "$svc" >/dev/null 2>&1
  else
    rc-update add "$svc" default >/dev/null 2>&1
  fi
}

_svc_disable() {
  local svc="$1"
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl disable "$svc" >/dev/null 2>&1
  else
    rc-update del "$svc" default >/dev/null 2>&1
  fi
}

_svc_active() {
  local svc="$1"
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl is-active --quiet "$svc"
  else
    rc-service "$svc" status >/dev/null 2>&1
  fi
}

service_start()   { _svc start sing-box;   [ "$1" = 'quiet' ] || log_ok "$(text svc_running)"; }
service_stop()    { _svc stop sing-box;    [ "$1" = 'quiet' ] || log_ok "$(text svc_stopped)"; }
service_restart() { _svc restart sing-box; [ "$1" = 'quiet' ] || log_ok "$(text svc_running)"; }
service_enable()  { _svc_enable sing-box;  [ "$1" = 'quiet' ] || log_ok "$(text svc_enabled)"; }
service_disable() { _svc_disable sing-box; [ "$1" = 'quiet' ] || log_ok "$(text svc_disabled)"; }

service_status() {
  if ! core_installed; then
    log_warn "$(text svc_not_installed)"; return 1
  fi
  if _svc_active sing-box; then
    log_ok "$(text svc_running)"
  else
    log_warn "$(text svc_stopped)"
  fi
}

service_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    log_step "$(text svc_title)"
    printf '  [1] %s\n' "$(text svc_start)"
    printf '  [2] %s\n' "$(text svc_stop)"
    printf '  [3] %s\n' "$(text svc_restart)"
    printf '  [4] %s\n' "$(text svc_status)"
    printf '  [5] %s\n' "$(text svc_enable)"
    printf '  [6] %s\n' "$(text svc_disable)"
    printf '  [0] %s\n' "$(text back)"
    printf '%s [0-6]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) service_start ;;
      2) service_stop ;;
      3) service_restart ;;
      4) service_status ;;
      5) service_enable ;;
      6) service_disable ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
    pause_enter
  done
}

# ------------------------------------------------------------------------------
# nginx 静态托管 / nginx static hosting
# ------------------------------------------------------------------------------
NGINX_CONF=''

nginx_conf_dir() {
  if [ -d /etc/nginx/conf.d ]; then
    printf '%s' '/etc/nginx/conf.d'
  elif [ -d /etc/nginx/http.d ]; then
    printf '%s' '/etc/nginx/http.d'
  else
    printf '%s' '/etc/nginx/conf.d'
  fi
}

ensure_nginx() {
  if ! have_cmd nginx; then
    log_info "$(text svc_nginx_install)"
    pkg_install nginx >/dev/null 2>&1 || true
  fi
  have_cmd nginx
}

service_nginx() {
  local action="$1" svc='nginx'
  if [ "$SERVICE_MGR" = 'systemd' ]; then
    systemctl "$action" nginx >/dev/null 2>&1
  else
    rc-service nginx "$action" >/dev/null 2>&1
  fi
}

# 生成订阅站点配置 / Write the subscription site config
write_nginx_site() {
  ensure_nginx || { log_warn 'nginx unavailable'; return 1; }
  local dir; dir="$(nginx_conf_dir)"
  NGINX_CONF="${dir}/easysb-sub.conf"
  local listen_scheme='http'
  if resolve_active_cert && [ -n "$DOMAIN" ]; then
    listen_scheme='ssl'
  fi
  if [ -z "$SUB_PORT" ]; then SUB_PORT="$SUB_PORT_DEFAULT"; fi
  if [ -z "$SUB_PATH" ]; then SUB_PATH="$SUB_PATH_DEFAULT"; fi

  if [ "$listen_scheme" = 'ssl' ]; then
    cat > "$NGINX_CONF" <<EOF
server {
    listen ${SUB_PORT} ssl;
    listen [::]:${SUB_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${ACTIVE_FULLCHAIN};
    ssl_certificate_key ${ACTIVE_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;

    location ${SUB_PATH} {
        alias ${SUBSCRIBE_DIR}/subscribe.json;
        default_type application/json;
        add_header Cache-Control no-store;
    }

    location / {
        return 404;
    }
}
EOF
  else
    cat > "$NGINX_CONF" <<EOF
server {
    listen ${SUB_PORT};
    listen [::]:${SUB_PORT};
    server_name _;

    location ${SUB_PATH} {
        alias ${SUBSCRIBE_DIR}/subscribe.json;
        default_type application/json;
        add_header Cache-Control no-store;
    }

    location / {
        return 404;
    }
}
EOF
  fi
  nginx -t >/dev/null 2>&1 && service_nginx restart && log_ok "$(text svc_nginx_ok)"
}

remove_nginx_site() {
  local dir; dir="$(nginx_conf_dir)"
  rm -f "${dir}/easysb-sub.conf"
  service_nginx restart >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 快捷命令与自更新 / Shortcut and self-update
# ------------------------------------------------------------------------------
create_shortcut() {
  cat > "$SHORTCUT" <<EOF
#!/usr/bin/env bash
if [ -s "${WORK_DIR}/easysb.sh" ]; then
  exec bash "${WORK_DIR}/easysb.sh" "\$@"
fi
exec bash <(curl -fsSL "${SCRIPT_URL}") "\$@"
EOF
  chmod +x "$SHORTCUT" 2>/dev/null || true
  log_info "$(text shortcut_created): sb"
}

install_self_copy() {
  local src="${BASH_SOURCE[0]:-}" out="${WORK_DIR}/easysb.sh"
  mkdir -p "$WORK_DIR"
  if [ -n "$src" ] && [ -f "$src" ] && [ -s "$src" ]; then
    cp -f "$src" "$out" 2>/dev/null && return 0
  fi
  # 进程替换安装时回退到 release 下载 / Fallback to release asset
  download "$SCRIPT_URL" "$out" >/dev/null 2>&1 || true
}

self_update() {
  log_step "$(text script_update)"
  local out="$TEMP_DIR/easysb.sh" remote_ver=''
  if download "$SCRIPT_URL" "$out" && [ -s "$out" ]; then
    remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$out" | cut -d"'" -f2)"
    if [ -n "$remote_ver" ] && [ "${remote_ver:0:1}" != '@' ] && [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
      log_ok "$(text script_uptodate): ${SCRIPT_VERSION}"
      return 0
    fi
    install -m 0755 "$out" "$WORK_DIR/easysb.sh"
    log_ok "$(text script_updated): ${remote_ver:-unknown}"
  else
    log_error "$(text script_failed)"
  fi
}
