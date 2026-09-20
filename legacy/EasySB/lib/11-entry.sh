# ------------------------------------------------------------------------------
# 十一、入口 / Entry point
# ------------------------------------------------------------------------------
#  用法 / Usage:
#    bash easysb.sh                     交互式菜单
#    bash easysb.sh --language C|E      预设语言
#    bash easysb.sh --install stable|alpha
#    bash easysb.sh --replace stable|alpha
#    bash easysb.sh --uninstall
#    bash easysb.sh --config FILE       读取配置后无交互安装
#    bash easysb.sh --version | --help
# ------------------------------------------------------------------------------

ACTION=''
CHANNEL_ARG=''
CONFIG_FILE=''
PRESET_LANG=''

_set_lang() {
  case "${1,,}" in
    c*|zh*) PRESET_LANG='C' ;;
    e*|en*) PRESET_LANG='E' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  _arg="${1}"
  _key="${_arg%%=*}"
  _val="${_arg#*=}"
  [ "$_key" = "$_arg" ] && _val=''
  case "$_key" in
    --language|-l) [ -n "$_val" ] || { shift; _val="${1:-}"; }; _set_lang "$_val" ;;
    --install)     [ -n "$_val" ] || { shift; _val="${1:-}"; }; ACTION='install'; CHANNEL_ARG="${_val,,}" ;;
    --replace)     [ -n "$_val" ] || { shift; _val="${1:-}"; }; ACTION='replace'; CHANNEL_ARG="${_val,,}" ;;
    --uninstall)   ACTION='uninstall' ;;
    --apply-firewall) ACTION='firewall' ;;
    --config)      [ -n "$_val" ] || { shift; _val="${1:-}"; }; CONFIG_FILE="$_val" ;;
    --help|-h)     usage; exit 0 ;;
    --version|-v)  printf 'EasySB %s\n' "$SCRIPT_VERSION"; exit 0 ;;
    *)             log_error "$(text unknown_arg): ${_arg}"; usage; exit 1 ;;
  esac
  shift
done
unset _arg _key _val

# 开机恢复端口跳跃规则，快速路径，不加载依赖 / Boot fast path
if [ "$ACTION" = 'firewall' ]; then
  check_root
  load_state
  fw_detect
  configure_firewall
  exit 0
fi

check_root

if [ -n "$PRESET_LANG" ]; then
  L="$PRESET_LANG"; export L
else
  select_language
fi

clear 2>/dev/null || true
print_banner

check_system_info
check_arch
check_dependencies

load_state
mkdir -p "$WORK_DIR" "$SUBSCRIBE_DIR"

# 非交互配置 / Non-interactive config
if [ -n "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  [ -n "${LANGUAGE:-}" ] && { L="${LANGUAGE^^}"; export L; }
fi

[ -n "$CHANNEL_ARG" ] && CORE_CHANNEL="$CHANNEL_ARG"
[ -z "$SERVER_IP" ] && SERVER_IP="$(detect_server_ip 2>/dev/null || true)"

create_shortcut >/dev/null 2>&1 || true
install_self_copy >/dev/null 2>&1 || true

# 非交互动作 / Non-interactive actions
case "$ACTION" in
  install)
    CORE_CHANNEL="${CORE_CHANNEL:-$CORE_CHANNEL_DEFAULT}"
    install_core
    build_server_config
    verify_config
    write_service_unit
    service_enable quiet
    configure_firewall
    write_firewall_unit
    [ -n "$DOMAIN" ] && write_nginx_site
    generate_subscription
    service_restart quiet
    save_state
    exit 0
    ;;
  replace)
    replace_core
    save_state
    exit 0
    ;;
  uninstall)
    uninstall_core
    save_state
    exit 0
    ;;
esac

# 首次运行且未安装内核：引导安装 / First-run guidance
if ! core_installed; then
  log_info "$(text kernel_none)"
  if confirm "$(text menu_kernel)?"; then
    CORE_CHANNEL="${CORE_CHANNEL:-$CORE_CHANNEL_DEFAULT}"
    install_core
    save_state
  fi
fi

main_menu
