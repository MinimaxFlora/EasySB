#!/usr/bin/env bash
# =============================================================================
# EasySB — 单文件一键部署脚本（入口）
#   bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/EasySB/master/EasySB/dist/easysb.sh)
#   或：wget -O easysb.sh <同上 URL> && bash easysb.sh
# 功能：一键部署 sing-box（AnyTLS / Hysteria2 / VLESS-Vision-REALITY /
#       VMess-WebSocket-TLS / TUIC），强制域名部署 + ACME 证书管理 +
#       伪装站点 + 内核与脚本更新。
# =============================================================================
set -u

ESB_SCRIPT_VERSION="1.0.0"
ESB_SELF="${BASH_SOURCE[0]:-}"
ESB_SCRIPT_DIR=""
if [ -n "$ESB_SELF" ] && [ -f "$ESB_SELF" ]; then
  ESB_SCRIPT_DIR="$(cd "$(dirname "$ESB_SELF")" 2>/dev/null && pwd || true)"
fi

# ---------------------------------------------------------------------------
# 路径模型：全部挂在 ESB_ROOT 之下（为空即真实绝对路径，沙箱测试时可前缀）
# ---------------------------------------------------------------------------
ESB_ROOT="${ESB_ROOT:-}"
ESB_DIR="${ESB_ROOT}/etc/easysb"
ESB_STATE="${ESB_DIR}/state.json"
ESB_LOG="${ESB_DIR}/easysb.log"
ESB_SECRET_DIR="${ESB_DIR}/secrets"
ESB_CLIENT_DIR="${ESB_DIR}/client"
ESB_CONF_DIR="${ESB_ROOT}/etc/sing-box"
ESB_CONFIG="${ESB_CONF_DIR}/config.json"
ESB_CERT_DIR="${ESB_CONF_DIR}/certs"
ESB_BIN="${ESB_ROOT}/usr/bin/sing-box"
ESB_UNIT_DIR="${ESB_ROOT}/usr/lib/systemd/system"
ESB_STATE_DIR="${ESB_ROOT}/var/lib/sing-box"
ESB_BACKUP_DIR="${ESB_ROOT}/var/backups/easysb"
ESB_WEB_ROOT="${ESB_ROOT}/var/www/easysb"
ESB_NGINX_CONF="${ESB_ROOT}/etc/nginx/conf.d/easysb.conf"
ESB_LOCK_DIR=""

usage() {
  cat <<'EOF'
EasySB —— sing-box 一键部署管理脚本

用法：
  easysb.sh                 进入交互式管理面板（推荐）
  easysb.sh install         直接进入部署向导
  easysb.sh status          查看运行状态
  easysb.sh uninstall       卸载
  easysb.sh --version       显示脚本版本
  easysb.sh --help          显示帮助

环境变量：
  ESB_ROOT=<dir>            沙箱根目录（测试用，正常使用不要设置）
  ESB_GATE=1                预演模式：所有系统变更只记录不执行（--dry-run）
  ESB_OFFLINE=1             离线：不发起任何下载
  ESB_NO_COLOR=1            禁用颜色
  ESB_ASSUME_YES=1          非交互模式下所有确认按默认值通过

支持协议：VLESS-Vision-REALITY / VMess-WebSocket-TLS /
          Hysteria2 / TUIC v5 / AnyTLS（可多选，默认全部）
内核与脚本更新来源：https://github.com/MinimaxFlora/EasySB
EOF
}

# ---------------------------------------------------------------------------
# 模块加载（单文件版由 build.sh 内联，不再走这里）
# ---------------------------------------------------------------------------
# >>> EASYSB_LIB_SOURCE_BEGIN
if [ -n "$ESB_SCRIPT_DIR" ] && [ -d "${ESB_SCRIPT_DIR}/lib" ]; then
  for _esb_lib in "${ESB_SCRIPT_DIR}"/lib/*.sh; do
    [ -r "$_esb_lib" ] || continue
    # shellcheck disable=SC1090
    . "$_esb_lib"
  done
fi
# <<< EASYSB_LIB_SOURCE_END

# 路径模型兜底（模块被单独 source 时也能工作；幂等，不覆盖入口已定义的值）
esb_paths_init

# ---------------------------------------------------------------------------
# 初始化
# ---------------------------------------------------------------------------
esb_init() {
  local _esb_init_arg
  for _esb_init_arg in "$@"; do
    case "$_esb_init_arg" in
      --no-color) ESB_NO_COLOR=1 ;;
    esac
  done
  esb_color_init
  esb_tmp_init || die "无法创建临时目录"
  state_init || die "无法初始化状态目录 $ESB_DIR"
  esb_log_open
  esb_log_raw "==== EasySB v${ESB_SCRIPT_VERSION} 启动（参数：$*）===="
  return 0
}

esb_cleanup() {
  esb_tmp_clean
  esb_unlock
  return 0
}

esb_require_root() {
  if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && [ "${ESB_ROOT}" = "" ]; then
    die "请以 root 身份运行（sudo -i 后再执行）"
  fi
  return 0
}

esb_stdin_from_tty() {
  # curl | bash 场景下 stdin 是管道，交互会失效；有 /dev/tty 就切回去
  if [ ! -t 0 ] && [ -c /dev/tty ]; then
    exec </dev/tty 2>/dev/null || true
  fi
  return 0
}

esb_main() {
  local _esb_main_cmd=""
  case "${1:-}" in
    --version|-V|version)
      printf 'EasySB v%s\n' "$ESB_SCRIPT_VERSION"
      return 0
      ;;
    --help|-h|help)
      usage
      return 0
      ;;
    --dry-run)
      ESB_GATE=1
      export ESB_GATE
      ESB_GATE_LOG="${ESB_GATE_LOG:-${TMPDIR:-/tmp}/easysb-dryrun.log}"
      export ESB_GATE_LOG
      shift
      _esb_main_cmd="${1:-}"
      ;;
    *) _esb_main_cmd="${1:-}" ;;
  esac

  esb_stdin_from_tty
  esb_init "$@"
  esb_log_raw "系统：$(uname -a 2>/dev/null)"
  trap 'esb_cleanup' EXIT

  case "$_esb_main_cmd" in
    install|deploy)
      esb_require_root
      deps_check || exit 1
      esb_lock || exit 1
      detect_all
      ui_deploy_wizard
      return $?
      ;;
    status)
      esb_lock || true
      detect_all
      ui_status_menu
      return 0
      ;;
    uninstall|remove)
      esb_require_root
      esb_lock || exit 1
      detect_all
      ui_uninstall
      return 0
      ;;
    update)
      esb_require_root
      esb_lock || exit 1
      detect_all
      ui_update_menu
      return 0
      ;;
    '')
      esb_require_root
      deps_check || exit 1
      esb_lock || exit 1
      detect_all
      if [ "${ESB_GATE:-0}" = "1" ]; then
        log_warn "预演模式（--dry-run）：所有系统变更只会被记录，不会真正执行"
      fi
      ui_main
      return 0
      ;;
    *)
      log_err "未知参数：$1"
      usage
      return 2
      ;;
  esac
}

# 供测试脚本以 `ESB_NO_MAIN=1 . easysb.sh` 的方式复用"路径模型 + 模块加载"
if [ "${ESB_NO_MAIN:-0}" != "1" ]; then
  esb_main "$@"
fi
