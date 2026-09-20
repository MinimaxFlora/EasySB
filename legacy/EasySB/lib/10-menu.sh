# ------------------------------------------------------------------------------
# 十、主菜单与卸载 / Main menu and uninstall
# ------------------------------------------------------------------------------

REMOTE_CHECKED=''
REMOTE_OK=''

check_remote_versions() {
  if [ -n "$REMOTE_CHECKED" ]; then return 0; fi
  REMOTE_CHECKED='1'
  if fetch_core_releases; then
    REMOTE_OK='1'
  else
    REMOTE_OK=''
    log_warn "$(text ver_offline)"
  fi
}

# 版本面板：脚本 / 本地内核 / 最新正式版 / 最新 alpha
show_versions() {
  check_remote_versions
  local lc cur stable alpha
  lc="$(local_core_version 2>/dev/null || true)"
  if [ -n "$lc" ]; then
    cur="${lc}  [$(channel_label "$(installed_core_channel)")]"
  else
    cur="$(text ver_not_installed)"
  fi
  stable="${CORE_STABLE_VERSION:-$(text ver_not_installed)}"
  alpha="${CORE_ALPHA_VERSION:-$(text ver_not_installed)}"

  printf '  %b%-14s%b: %s\n' "$C_BLUE" "$(text ver_script)" "$C_RESET" "$SCRIPT_VERSION"
  printf '  %b%-14s%b: %s\n' "$C_BLUE" "$(text ver_local_core)" "$C_RESET" "$cur"
  printf '  %b%-14s%b: %s%s\n' "$C_BLUE" "$(text ver_stable)" "$C_RESET" "$stable" "$(_ver_marker "$stable" "$lc" stable)"
  printf '  %b%-14s%b: %s%s\n' "$C_BLUE" "$(text ver_alpha)" "$C_RESET" "$alpha" "$(_ver_marker "$alpha" "$lc" alpha)"
}

# 版本比较：a 是否比 b 新 / is a newer than b
ver_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# 远程版本相对本地的提示（同通道才提示）/ Marker for a remote version vs local
_ver_marker() {
  local remote="$1" local_v="$2" channel="$3"
  [ -z "$local_v" ] && return 0
  [[ "$remote" =~ ^[0-9] ]] || return 0
  [ "$(installed_core_channel)" = "$channel" ] || return 0
  if [ "$remote" = "$local_v" ]; then
    printf ' (%s)' "$(text ver_latest)"
  elif ver_gt "$remote" "$local_v"; then
    printf ' (%s)' "$(text ver_update)"
  fi
}

backup_config() {
  local stamp archive
  stamp="$(date '+%Y%m%d-%H%M%S')"
  archive="${BACKUP_DIR}/easysb-backup-${stamp}.tar.gz"
  if [ -d "$WORK_DIR" ]; then
    tar -czf "$archive" -C "$(dirname "$WORK_DIR")" "$(basename "$WORK_DIR")" >/dev/null 2>&1 || true
    [ -s "$archive" ] && log_ok "$(text script_backup_ok): ${archive}"
  fi
}

full_uninstall() {
  log_step "$(text uninstall_title)"
  confirm "$(text uninstall_confirm)" N || { log_warn "$(text cancelled)"; return 1; }
  backup_config
  service_stop quiet
  service_disable quiet
  remove_firewall
  remove_firewall_unit
  remove_service_unit
  remove_nginx_site
  rm -f "$SHORTCUT"
  rm -rf "$WORK_DIR"
  log_ok "$(text uninstall_done)"
  log_info "$(text uninstall_keep_certs)"
  return 0
}

main_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    print_banner
    show_versions
    printf '\n  %b%s%b\n' "$C_BOLD$C_MAGENTA" "$(text menu_main)" "$C_RESET"
    ui_item 1 "$(text menu_kernel)"
    ui_item 2 "$(text menu_node)"
    ui_item 3 "$(text menu_domain)"
    ui_item 4 "$(text menu_subscribe)"
    ui_item 5 "$(text menu_service)"
    ui_item 6 "$(text menu_script_update)"
    ui_item 7 "$(text menu_uninstall)"
    ui_item 0 "$(text exit)"
    printf '%s [0-7]: ' "$(text select_prompt)"
    read -r choice
    case "$choice" in
      1) kernel_menu ;;
      2) node_manage_menu ;;
      3) domain_menu ;;
      4) subscribe_menu ;;
      5) service_menu ;;
      6) self_update; pause_enter ;;
      7) full_uninstall; [ -d "$WORK_DIR" ] || return 0 ;;
      0|'') return 0 ;;
      *) log_warn "$(text invalid)" ;;
    esac
  done
}

usage() {
  cat <<EOF
$(text usage):
  bash easysb.sh                 # 交互式菜单 / interactive menu
  bash easysb.sh --language C|E  # 预设语言 / preset language
  bash easysb.sh --install stable|alpha
  bash easysb.sh --replace stable|alpha
  bash easysb.sh --uninstall
  bash easysb.sh --config FILE   # 非交互安装 / non-interactive install
  bash easysb.sh --apply-firewall
  bash easysb.sh --version       # 显示版本 / show version
  bash easysb.sh --help          # 显示帮助 / show help
EOF
}
